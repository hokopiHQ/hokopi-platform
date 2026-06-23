#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: syncRemoteDbToLocal.sh <user@host>
       syncRemoteDbToLocal.sh --exec <user@host>
       syncRemoteDbToLocal.sh --dump-only <user@host>
       syncRemoteDbToLocal.sh --exec --dump-only <user@host>

Dump remote PostgreSQL data over SSH and optionally load it into the local dev database.

Default behavior:
  - remote dump is executed from the remote postgres Docker service
  - dump format is plain SQL, data-only, excluding _prisma_migrations
  - local target is reset with Prisma migrations before import
  - local import is executed inside the local postgres Docker service
  - dry-run validates SSH and the required database endpoints before printing commands
  - local sanitization runs after import unless --dump-only is used

Environment overrides:
  REMOTE_COMPOSE_FILE                   (default: /var/www/app/docker/docker-compose.prod.yml)
  REMOTE_DB_SERVICE                     (default: postgres)
  REMOTE_SSH_OPTS                       (default: empty)

  LOCAL_COMPOSE_FILE                    (default: docker/docker-compose.dev.yml)
  LOCAL_DB_SERVICE                      (default: postgres)

  DUMP_PATH                             (default: temp file in /tmp)
  IMPORT_SQL_PATH                       (default: alongside dump path)
  SANITIZE_SQL_PATH                     (default: alongside dump path)
  KEEP_DUMP             0|1             (default: 0, forced to 1 with --dump-only)
  LOCAL_PASSWORD_HASH                   (default: Argon2id hash for "aaaaaa")

Behavior:
  - dry-run is the default
  - pass --exec to execute the sync for real
  - pass --dump-only to keep only the SQL dump and skip local reset/import/sanitization

Examples:
  ./ops/syncRemoteDbToLocal.sh user@server
  ./ops/syncRemoteDbToLocal.sh --exec user@server
  ./ops/syncRemoteDbToLocal.sh --dump-only user@server
  ./ops/syncRemoteDbToLocal.sh --exec --dump-only user@server
EOF
}

EXECUTE=0
DUMP_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exec)
      EXECUTE=1
      shift
      ;;
    --dump-only)
      DUMP_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option: $1"
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TARGET="$1"

REMOTE_COMPOSE_FILE="${REMOTE_COMPOSE_FILE:-/var/www/app/docker/docker-compose.prod.yml}"
REMOTE_DB_SERVICE="${REMOTE_DB_SERVICE:-postgres}"
REMOTE_SSH_OPTS="${REMOTE_SSH_OPTS:-}"

LOCAL_COMPOSE_FILE="${LOCAL_COMPOSE_FILE:-docker/docker-compose.dev.yml}"
LOCAL_DB_SERVICE="${LOCAL_DB_SERVICE:-postgres}"

DUMP_PATH="${DUMP_PATH:-}"
IMPORT_SQL_PATH="${IMPORT_SQL_PATH:-}"
SANITIZE_SQL_PATH="${SANITIZE_SQL_PATH:-}"
KEEP_DUMP="${KEEP_DUMP:-0}"
LOCAL_PASSWORD_HASH="${LOCAL_PASSWORD_HASH:-\$argon2id\$v=19\$m=19456,t=2,p=1\$WeE+Cl9VFxUdRJbiOR3ycg\$EDps9DOAipnbVqSBvQUHzIHNHZ9n59/2Zfbk56sSSDo}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BACKEND_DIR="${REPO_ROOT}/backend"
PRISMA_BIN="${BACKEND_DIR}/node_modules/.bin/prisma"

if [[ "${DUMP_ONLY}" == "1" ]]; then
  KEEP_DUMP=1
fi

make_temp_sql_path() {
  local prefix="$1"
  local tmp_path

  tmp_path="$(mktemp "/tmp/${prefix}.XXXXXX")"
  mv "${tmp_path}" "${tmp_path}.sql"
  printf '%s\n' "${tmp_path}.sql"
}

if [[ -z "${DUMP_PATH}" ]]; then
  DUMP_PATH="$(make_temp_sql_path remote_db_dump)"
  CREATED_TEMP_DUMP=1
else
  CREATED_TEMP_DUMP=0
fi

if [[ -z "${SANITIZE_SQL_PATH}" ]]; then
  SANITIZE_SQL_PATH="${DUMP_PATH%.sql}.sanitize.sql"
  CREATED_TEMP_SANITIZE_SQL=1
else
  CREATED_TEMP_SANITIZE_SQL=0
fi

if [[ -z "${IMPORT_SQL_PATH}" ]]; then
  IMPORT_SQL_PATH="${DUMP_PATH%.sql}.import.sql"
  CREATED_TEMP_IMPORT_SQL=1
else
  CREATED_TEMP_IMPORT_SQL=0
fi

cleanup() {
  if [[ "${KEEP_DUMP}" != "1" && "${CREATED_TEMP_DUMP}" == "1" && -f "${DUMP_PATH}" ]]; then
    rm -f "${DUMP_PATH}"
  fi
  if [[ "${KEEP_DUMP}" != "1" && "${CREATED_TEMP_IMPORT_SQL}" == "1" && -f "${IMPORT_SQL_PATH}" ]]; then
    rm -f "${IMPORT_SQL_PATH}"
  fi
  if [[ "${KEEP_DUMP}" != "1" && "${CREATED_TEMP_SANITIZE_SQL}" == "1" && -f "${SANITIZE_SQL_PATH}" ]]; then
    rm -f "${SANITIZE_SQL_PATH}"
  fi
  rm -f "${DUMP_PATH}.stderr"
}
trap cleanup EXIT

if [[ -t 1 ]]; then
  COLOR_BLUE=$'\033[1;34m'
  COLOR_GREEN=$'\033[1;32m'
  COLOR_YELLOW=$'\033[1;33m'
  COLOR_RED=$'\033[1;31m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_BLUE=''
  COLOR_GREEN=''
  COLOR_YELLOW=''
  COLOR_RED=''
  COLOR_RESET=''
fi

print_info() {
  echo "${COLOR_BLUE}==>${COLOR_RESET} $1"
}

print_ok() {
  echo "${COLOR_GREEN}OK${COLOR_RESET}  $1"
}

print_warn() {
  echo "${COLOR_YELLOW}WARN${COLOR_RESET} $1"
}

print_error() {
  echo "${COLOR_RED}ERR${COLOR_RESET} $1"
}

parse_identity_value() {
  local payload="$1"
  local key="$2"
  printf '%s\n' "${payload}" | awk -F'=' -v key="${key}" '$1 == key { print substr($0, index($0, "=") + 1) }'
}

run_remote_check() {
  local remote_command="$1"
  local output

  if output="$("${SSH_COMMAND[@]}" "${remote_command}" 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi

  print_error "Remote check failed."
  echo "${output}"
  return 1
}

run_local_check() {
  local local_command="$1"
  local output

  if output="$(eval "${local_command}" 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi

  print_error "Local check failed."
  echo "${output}"
  return 1
}

build_remote_dump_command() {
  printf "%q " sudo docker compose -f "${REMOTE_COMPOSE_FILE}" exec -T "${REMOTE_DB_SERVICE}" sh -lc \
    'pg_dump --data-only --no-owner --no-privileges --exclude-table=_prisma_migrations -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

build_remote_identity_command() {
  printf "%q " sudo docker compose -f "${REMOTE_COMPOSE_FILE}" exec -T "${REMOTE_DB_SERVICE}" sh -lc \
    'printf "db=%s\n" "$POSTGRES_DB"'
}

build_local_import_command() {
  printf "%q " docker compose -f "${LOCAL_COMPOSE_FILE}" exec -T "${LOCAL_DB_SERVICE}" sh -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

build_local_prisma_reset_command() {
  local shell_command
  printf -v shell_command 'cd %q && %q migrate reset --force --skip-seed --schema prisma/schema.prisma' \
    "${BACKEND_DIR}" "${PRISMA_BIN}"
  printf "%q " bash -lc "${shell_command}"
}

build_local_identity_command() {
  printf "%q " docker compose -f "${LOCAL_COMPOSE_FILE}" exec -T "${LOCAL_DB_SERVICE}" sh -lc \
    'printf "db=%s\n" "$POSTGRES_DB"'
}

build_local_sanitization_command() {
  printf "%q " docker compose -f "${LOCAL_COMPOSE_FILE}" exec -T "${LOCAL_DB_SERVICE}" sh -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

normalize_import_dump() {
  local source_path="$1"
  local target_path="$2"

  {
    cat <<'SQL'
BEGIN;
SET LOCAL session_replication_role = replica;
SQL

    awk '
    BEGIN {
      in_user_copy = 0
      in_unit_copy = 0
      in_pack_type_copy = 0

      bootstrap_pack_types["BIN"] = 1
      bootstrap_pack_types["BLOCK"] = 1
      bootstrap_pack_types["BOTTLE"] = 1
      bootstrap_pack_types["BRICK"] = 1
      bootstrap_pack_types["BOX"] = 1
      bootstrap_pack_types["BUCKET"] = 1
      bootstrap_pack_types["CAN"] = 1
      bootstrap_pack_types["CANISTER"] = 1
      bootstrap_pack_types["CARTON"] = 1
      bootstrap_pack_types["CRATE"] = 1
      bootstrap_pack_types["CASE"] = 1
      bootstrap_pack_types["JAR"] = 1
      bootstrap_pack_types["MULTIPACK"] = 1
      bootstrap_pack_types["NET"] = 1
      bootstrap_pack_types["PALLET"] = 1
      bootstrap_pack_types["POUCH"] = 1
      bootstrap_pack_types["BAG"] = 1
      bootstrap_pack_types["TRAY"] = 1
      bootstrap_pack_types["UNIT"] = 1
    }
    /^COPY public\."User" \(.*\) FROM stdin;$/ || /^COPY "User" \(.*\) FROM stdin;$/ {
      in_user_copy = 1
      print
      next
    }
    /^COPY public\."Unit" \(.*\) FROM stdin;$/ || /^COPY "Unit" \(.*\) FROM stdin;$/ {
      in_unit_copy = 1
      print
      next
    }
    /^COPY public\."MercurialePackType" \(.*\) FROM stdin;$/ || /^COPY "MercurialePackType" \(.*\) FROM stdin;$/ {
      in_pack_type_copy = 1
      print
      next
    }
    in_user_copy && $0 == "\\." {
      in_user_copy = 0
      print
      next
    }
    in_unit_copy && $0 == "\\." {
      in_unit_copy = 0
      print
      next
    }
    in_pack_type_copy && $0 == "\\." {
      in_pack_type_copy = 0
      print
      next
    }
    in_user_copy && $1 == "00000000-0000-0000-0000-000000000001" && $2 == "system@local" {
      next
    }
    in_unit_copy && ($1 == "uu" || $1 == "uc") {
      next
    }
    in_pack_type_copy && bootstrap_pack_types[$1] {
      next
    }
    {
      print
    }
    ' "${source_path}"

    cat <<'SQL'
SET LOCAL session_replication_role = origin;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public."MercurialeItem" item
    LEFT JOIN public."MercurialeItemNode" node
      ON node."id" = item."pricingNodeId"
      AND node."mercurialeItemId" = item."id"
    WHERE item."pricingNodeId" IS NOT NULL
      AND node."id" IS NULL
  ) THEN
    RAISE EXCEPTION 'Imported MercurialeItem pricing nodes are inconsistent';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public."MercurialeItemNode" node
    LEFT JOIN public."MercurialeItem" item
      ON item."id" = node."mercurialeItemId"
    WHERE item."id" IS NULL
  ) THEN
    RAISE EXCEPTION 'Imported MercurialeItemNode rows contain orphan items';
  END IF;
END
$$;

COMMIT;
SQL
  } > "${target_path}"
}

write_local_sanitization_sql() {
  cat > "${SANITIZE_SQL_PATH}" <<EOF
BEGIN;

-- ---------------------------------------------------------------------------
-- Section 1: local authentication reset
-- Reset all user passwords to the shared local test hash and revoke live JWTs.
-- ---------------------------------------------------------------------------
UPDATE "User"
SET
  "password" = '${LOCAL_PASSWORD_HASH}',
  "authVersion" = "authVersion" + 1,
  "updatedAt" = NOW();

-- ---------------------------------------------------------------------------
-- Section 2: local email domain rewrite
-- Keep the local part intact, replace external domains with @dev.local.
-- Preserve the technical system account as-is.
-- ---------------------------------------------------------------------------
UPDATE "User"
SET
  "email" = split_part("email", '@', 1) || '@dev.local',
  "updatedAt" = NOW()
WHERE "email" LIKE '%@%'
  AND "email" <> 'system@local';

UPDATE "UserInvitation"
SET
  "email" = split_part("email", '@', 1) || '@dev.local',
  "updatedAt" = NOW()
WHERE "email" LIKE '%@%';

-- ---------------------------------------------------------------------------
-- Section 3: reset password flows
-- Remove any live password reset token imported from prod.
-- ---------------------------------------------------------------------------
DELETE FROM "PasswordResetToken";

-- ---------------------------------------------------------------------------
-- Section 4: sanitize invitation flows
-- Keep history, but revoke pending invitations and invalidate their tokens.
-- ---------------------------------------------------------------------------
UPDATE "UserInvitation"
SET
  "tokenHash" = md5("id"::text || ':local_invitation'),
  "status" = CASE
    WHEN "status" = 'PENDING' THEN 'REVOKED'::"InvitationStatus"
    ELSE "status"
  END,
  "revokedAt" = CASE
    WHEN "status" = 'PENDING' AND "revokedAt" IS NULL THEN NOW()
    ELSE "revokedAt"
  END,
  "updatedAt" = NOW();

-- ---------------------------------------------------------------------------
-- Section 5: sanitize billing and payment provider identifiers
-- Keep provider/status context, remove reusable external identifiers.
-- ---------------------------------------------------------------------------
UPDATE "PaymentAttempt"
SET
  "providerCheckoutSessionId" = NULL,
  "providerPaymentIntentId" = NULL,
  "providerCustomerId" = NULL,
  "updatedAt" = NOW();

UPDATE "Organization"
SET
  "providerCustomerId" = NULL,
  "updatedAt" = NOW()
WHERE "providerCustomerId" IS NOT NULL;

UPDATE "Subscription"
SET
  "providerSubscriptionId" = NULL,
  "providerPaymentId" = NULL,
  "updatedAt" = NOW()
WHERE "providerSubscriptionId" IS NOT NULL
   OR "providerPaymentId" IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Section 6: purge provider webhook history
-- Prevent local replay or confusion with real external webhook deliveries.
-- ---------------------------------------------------------------------------
DELETE FROM "ProviderWebhookEvent";

-- ---------------------------------------------------------------------------
-- Section 7: purge derived notification queue
-- Notifications are derived from events and not useful after prod import.
-- ---------------------------------------------------------------------------
DELETE FROM "Notification";

COMMIT;
EOF
}

REMOTE_DUMP_COMMAND="$(build_remote_dump_command)"
REMOTE_IDENTITY_COMMAND="$(build_remote_identity_command)"
LOCAL_IMPORT_COMMAND="$(build_local_import_command)"
LOCAL_PRISMA_RESET_COMMAND="$(build_local_prisma_reset_command)"
LOCAL_IDENTITY_COMMAND="$(build_local_identity_command)"
LOCAL_SANITIZATION_COMMAND="$(build_local_sanitization_command)"
SSH_COMMAND=(ssh)

if [[ -n "${REMOTE_SSH_OPTS}" ]]; then
  # shellcheck disable=SC2206
  SSH_EXTRA_OPTS=(${REMOTE_SSH_OPTS})
  SSH_COMMAND+=("${SSH_EXTRA_OPTS[@]}")
fi

SSH_COMMAND+=("${TARGET}")

print_info "Remote source : ${TARGET}"
print_info "Remote service: ${REMOTE_DB_SERVICE}"
print_info "Local service : ${LOCAL_DB_SERVICE}"
print_info "Dump file     : ${DUMP_PATH}"
print_info "Import SQL    : ${IMPORT_SQL_PATH}"
print_info "Sanitize SQL  : ${SANITIZE_SQL_PATH}"
print_info "Mode          : $([[ "${EXECUTE}" == "1" ]] && echo "execute" || echo "dry-run")"
print_info "Dump only     : $([[ "${DUMP_ONLY}" == "1" ]] && echo "yes" || echo "no")"

LOCAL_HOSTNAME="$(hostname)"

if [[ "${EXECUTE}" != "1" ]]; then
  print_info "Testing SSH connectivity"
  run_remote_check "echo 'SSH connection OK'" >/dev/null
  print_ok "SSH connectivity"

  REMOTE_HOSTNAME="$(run_remote_check "hostname")"
  print_ok "Remote host resolved: ${REMOTE_HOSTNAME}"

  print_info "Testing remote postgres container access"
  run_remote_check "$(printf "%q " sudo docker compose -f "${REMOTE_COMPOSE_FILE}" exec -T "${REMOTE_DB_SERVICE}" sh -lc 'command -v pg_dump >/dev/null && pg_dump --version && pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"')" >/dev/null
  print_ok "Remote postgres access"

  REMOTE_IDENTITY="$(run_remote_check "${REMOTE_IDENTITY_COMMAND}")"
  REMOTE_DB_NAME="$(parse_identity_value "${REMOTE_IDENTITY}" db)"
  print_ok "Remote database resolved: ${REMOTE_DB_NAME}"

  if [[ "${DUMP_ONLY}" != "1" ]]; then
    print_info "Testing local Prisma reset command"
    if [[ ! -x "${PRISMA_BIN}" ]]; then
      print_error "Local Prisma CLI not found: ${PRISMA_BIN}"
      exit 1
    fi
    print_ok "Local Prisma CLI available"

    print_info "Testing local postgres container access"
    run_local_check "$(printf "%q " docker compose -f "${LOCAL_COMPOSE_FILE}" exec -T "${LOCAL_DB_SERVICE}" sh -lc 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \"SELECT 1;\"')" >/dev/null
    print_ok "Local postgres access"

    LOCAL_IDENTITY="$(run_local_check "${LOCAL_IDENTITY_COMMAND}")"
    LOCAL_DB_NAME="$(parse_identity_value "${LOCAL_IDENTITY}" db)"
    print_ok "Local database resolved: ${LOCAL_DB_NAME}"
  fi

  echo
  print_warn "Dry-run only. Commands were not executed."
  echo
  echo "Source"
  echo "  SSH target : ${TARGET}"
  echo "  Host       : ${REMOTE_HOSTNAME:-unknown}"
  echo "  DB service : ${REMOTE_DB_SERVICE}"
  echo "  DB name    : ${REMOTE_DB_NAME:-unknown}"
  echo
  echo "Target"
  echo "  Host       : ${LOCAL_HOSTNAME:-unknown}"
  echo "  Dump file  : ${DUMP_PATH}"
  if [[ "${DUMP_ONLY}" == "1" ]]; then
    echo "  Action     : keep local dump only"
  else
    echo "  Import SQL : ${IMPORT_SQL_PATH}"
    echo "  Reset      : prisma migrate reset --force --skip-seed"
    echo "  DB service : ${LOCAL_DB_SERVICE}"
    echo "  DB name    : ${LOCAL_DB_NAME:-unknown}"
    echo "  Overwrite  : import prod-like data into schema rebuilt from local migrations"
    echo "  Sanitize   : ${SANITIZE_SQL_PATH}"
  fi
  echo
  echo "Remote dump command:"
  printf '  %q ' "${SSH_COMMAND[@]}"
  printf "%s\n" "${REMOTE_DUMP_COMMAND}"
  if [[ "${DUMP_ONLY}" != "1" ]]; then
    echo
    echo "Local Prisma reset command:"
    printf "  %s\n" "${LOCAL_PRISMA_RESET_COMMAND}"
    echo
    echo "Import dump normalization:"
    echo "  - Section A: remove the bootstrap system user row already created by local migrations"
    echo "  - Section B: remove bootstrap units uu/uc already created by local migrations"
    echo "  - Section C: remove initial pack types already created by local migrations"
    echo "  - Section D: restore inside one transaction with FK triggers temporarily disabled"
    echo "  - Section E: validate MercurialeItem pricing-node integrity before commit"
    echo
    echo "Local import command:"
    printf "  %s < %q\n" "${LOCAL_IMPORT_COMMAND}" "${IMPORT_SQL_PATH}"
    echo
    echo "Local sanitization:"
    echo "  - Section 1: reset all user passwords to LOCAL_PASSWORD_HASH"
    echo "  - Section 2: rewrite email domains to @dev.local"
    echo "  - Section 3: delete password reset tokens"
    echo "  - Section 4: keep invitation history but revoke pending invitations"
    echo "  - Section 5: clear external Stripe identifiers while keeping context"
    echo "  - Section 6: purge provider webhook history"
    echo "  - Section 7: purge notifications"
  fi
  exit 0
fi

print_info "Resolving remote database target"
REMOTE_HOSTNAME="$(run_remote_check "hostname")"
print_ok "Remote host resolved: ${REMOTE_HOSTNAME}"
REMOTE_IDENTITY="$(run_remote_check "${REMOTE_IDENTITY_COMMAND}")"
REMOTE_DB_NAME="$(parse_identity_value "${REMOTE_IDENTITY}" db)"
print_ok "Remote database resolved: ${REMOTE_DB_NAME}"

if [[ "${DUMP_ONLY}" != "1" ]]; then
  print_info "Resolving local database target"
  LOCAL_IDENTITY="$(run_local_check "${LOCAL_IDENTITY_COMMAND}")"
  LOCAL_DB_NAME="$(parse_identity_value "${LOCAL_IDENTITY}" db)"
  print_ok "Local database resolved: ${LOCAL_DB_NAME}"
  if [[ ! -x "${PRISMA_BIN}" ]]; then
    print_error "Local Prisma CLI not found: ${PRISMA_BIN}"
    exit 1
  fi
fi

echo
print_warn "Execution summary"
echo "Source"
echo "  SSH target : ${TARGET}"
echo "  Host       : ${REMOTE_HOSTNAME:-unknown}"
echo "  DB service : ${REMOTE_DB_SERVICE}"
echo "  DB name    : ${REMOTE_DB_NAME:-unknown}"
echo
if [[ "${DUMP_ONLY}" == "1" ]]; then
  echo "Target"
  echo "  Host       : ${LOCAL_HOSTNAME:-unknown}"
  echo "  Dump file  : ${DUMP_PATH}"
  echo "  Action     : keep local dump only"
else
  echo "Target"
  echo "  Host       : ${LOCAL_HOSTNAME:-unknown}"
  echo "  Import SQL : ${IMPORT_SQL_PATH}"
  echo "  Reset      : prisma migrate reset --force --skip-seed"
  echo "  DB service : ${LOCAL_DB_SERVICE}"
  echo "  DB name    : ${LOCAL_DB_NAME:-unknown}"
  echo "  Overwrite  : import prod-like data into schema rebuilt from local migrations"
  echo "  Sanitize   : ${SANITIZE_SQL_PATH}"
fi
echo

if [[ ! -t 0 ]]; then
  print_error "Interactive confirmation is required for --exec."
  exit 1
fi

read -r -p "Type 'y' to continue: " EXEC_CONFIRMATION
if [[ "${EXEC_CONFIRMATION}" != "y" ]]; then
  print_warn "Execution aborted."
  exit 1
fi

print_info "Creating remote dump"
if "${SSH_COMMAND[@]}" "${REMOTE_DUMP_COMMAND}" > "${DUMP_PATH}" 2>"${DUMP_PATH}.stderr"; then
  rm -f "${DUMP_PATH}.stderr"
  print_ok "Remote dump created"
else
  print_error "Remote dump failed."
  cat "${DUMP_PATH}.stderr"
  rm -f "${DUMP_PATH}.stderr"
  exit 1
fi

if [[ ! -s "${DUMP_PATH}" ]]; then
  print_error "Dump file is empty: ${DUMP_PATH}"
  exit 1
fi

if [[ "${DUMP_ONLY}" == "1" ]]; then
  print_ok "Dump-only mode completed"
  print_info "Dump file kept at ${DUMP_PATH}"
  exit 0
fi

print_info "Resetting local target with Prisma migrations"
if eval "${LOCAL_PRISMA_RESET_COMMAND}" 2>"${DUMP_PATH}.stderr"; then
  rm -f "${DUMP_PATH}.stderr"
  print_ok "Local target reset from migrations"
else
  print_error "Local Prisma reset failed."
  cat "${DUMP_PATH}.stderr"
  rm -f "${DUMP_PATH}.stderr"
  exit 1
fi

print_info "Normalizing import dump for bootstrap rows and cyclic foreign keys"
if normalize_import_dump "${DUMP_PATH}" "${IMPORT_SQL_PATH}" 2>"${DUMP_PATH}.stderr"; then
  if command -v rg >/dev/null 2>&1; then
    if rg -n '^00000000-0000-0000-0000-000000000001\tsystem@local\t' "${IMPORT_SQL_PATH}" >/dev/null; then
      print_error "Import dump normalization failed: bootstrap system user row is still present."
      cat "${DUMP_PATH}.stderr"
      rm -f "${DUMP_PATH}.stderr"
      exit 1
    fi
  elif grep -n $'^00000000-0000-0000-0000-000000000001\tsystem@local\t' "${IMPORT_SQL_PATH}" >/dev/null; then
    print_error "Import dump normalization failed: bootstrap system user row is still present."
    cat "${DUMP_PATH}.stderr"
    rm -f "${DUMP_PATH}.stderr"
    exit 1
  fi
  rm -f "${DUMP_PATH}.stderr"
  print_ok "Import dump normalized"
else
  print_error "Import dump normalization failed."
  cat "${DUMP_PATH}.stderr"
  rm -f "${DUMP_PATH}.stderr"
  exit 1
fi

print_info "Loading dump into local database"
if eval "${LOCAL_IMPORT_COMMAND}" < "${IMPORT_SQL_PATH}" 2>"${DUMP_PATH}.stderr"; then
  rm -f "${DUMP_PATH}.stderr"
  print_ok "Local database loaded"
else
  print_error "Local import failed."
  cat "${DUMP_PATH}.stderr"
  rm -f "${DUMP_PATH}.stderr"
  exit 1
fi

write_local_sanitization_sql

print_info "Running local sanitization"
if eval "${LOCAL_SANITIZATION_COMMAND}" < "${SANITIZE_SQL_PATH}" 2>"${DUMP_PATH}.stderr"; then
  rm -f "${DUMP_PATH}.stderr"
  print_ok "Local sanitization completed"
else
  print_error "Local sanitization failed."
  cat "${DUMP_PATH}.stderr"
  rm -f "${DUMP_PATH}.stderr"
  exit 1
fi

print_ok "Remote database imported and sanitized locally"

if [[ "${KEEP_DUMP}" == "1" ]]; then
  print_info "Dump file kept at ${DUMP_PATH}"
  print_info "Import SQL kept at ${IMPORT_SQL_PATH}"
  print_info "Sanitization SQL kept at ${SANITIZE_SQL_PATH}"
fi
