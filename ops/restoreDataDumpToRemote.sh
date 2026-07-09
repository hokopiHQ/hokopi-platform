#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: restoreDataDumpToRemote.sh --dump <path> <user@host>
       restoreDataDumpToRemote.sh --exec --dump <path> <user@host>

Restore a data-only PostgreSQL SQL dump into a remote Dockerized database over SSH.

Default behavior:
  - dry-run validates the dump file, SSH, and remote PostgreSQL access
  - restore is destructive and idempotent: all public tables except _prisma_migrations
    are truncated before replaying the dump
  - seed/reference rows from beta are restored from the dump, preserving their IDs
  - Stripe/provider external identifiers are neutralized after import by default
  - interactive confirmation is required with --exec

Environment overrides:
  REMOTE_COMPOSE_FILE                   (default: /var/www/app/docker/docker-compose.prod.yml)
  REMOTE_DB_SERVICE                     (default: postgres)
  REMOTE_SSH_OPTS                       (default: empty)
  RESTORE_SQL_PATH                      (default: temp file in /tmp)
  KEEP_RESTORE_SQL       0|1            (default: 0)

Options:
  --exec                               Execute the remote restore. Without it, dry-run only.
  --dump <path>                        Data-only SQL dump to restore.
  --preserve-stripe-provider-data      Do not clear Stripe/provider identifiers after import.
  -h, --help                           Show this help.

Examples:
  ./ops/restoreDataDumpToRemote.sh --dump /tmp/beta-data.sql user@prod-server
  ./ops/restoreDataDumpToRemote.sh --exec --dump /tmp/beta-data.sql user@prod-server
EOF
}

EXECUTE=0
DUMP_PATH=""
PRESERVE_STRIPE_PROVIDER_DATA=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --exec)
      EXECUTE=1
      shift
      ;;
    --dump)
      DUMP_PATH="${2:-}"
      shift 2
      ;;
    --preserve-stripe-provider-data)
      PRESERVE_STRIPE_PROVIDER_DATA=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      break
      ;;
  esac
done

if [[ $# -ne 1 || -z "${DUMP_PATH}" ]]; then
  usage
  exit 1
fi

TARGET="$1"

REMOTE_COMPOSE_FILE="${REMOTE_COMPOSE_FILE:-/var/www/app/docker/docker-compose.prod.yml}"
REMOTE_DB_SERVICE="${REMOTE_DB_SERVICE:-postgres}"
REMOTE_SSH_OPTS="${REMOTE_SSH_OPTS:-}"
RESTORE_SQL_PATH="${RESTORE_SQL_PATH:-}"
KEEP_RESTORE_SQL="${KEEP_RESTORE_SQL:-0}"

if [[ ! -f "${DUMP_PATH}" ]]; then
  echo "Error: dump file not found: ${DUMP_PATH}" >&2
  exit 1
fi

if [[ ! -s "${DUMP_PATH}" ]]; then
  echo "Error: dump file is empty: ${DUMP_PATH}" >&2
  exit 1
fi

make_temp_sql_path() {
  local prefix="$1"
  local tmp_path

  tmp_path="$(mktemp "/tmp/${prefix}.XXXXXX")"
  mv "${tmp_path}" "${tmp_path}.sql"
  printf '%s\n' "${tmp_path}.sql"
}

if [[ -z "${RESTORE_SQL_PATH}" ]]; then
  RESTORE_SQL_PATH="$(make_temp_sql_path restore_remote_db)"
  CREATED_TEMP_RESTORE_SQL=1
else
  CREATED_TEMP_RESTORE_SQL=0
fi

cleanup() {
  if [[ "${KEEP_RESTORE_SQL}" != "1" && "${CREATED_TEMP_RESTORE_SQL}" == "1" && -f "${RESTORE_SQL_PATH}" ]]; then
    rm -f "${RESTORE_SQL_PATH}"
  fi
  rm -f "${RESTORE_SQL_PATH}.stderr"
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

build_remote_identity_command() {
  printf "%q " sudo docker compose -f "${REMOTE_COMPOSE_FILE}" exec -T "${REMOTE_DB_SERVICE}" sh -lc \
    'printf "db=%s\n" "$POSTGRES_DB"'
}

build_remote_psql_command() {
  printf "%q " sudo docker compose -f "${REMOTE_COMPOSE_FILE}" exec -T "${REMOTE_DB_SERVICE}" sh -lc \
    'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

print_dump_stripe_summary() {
  awk '
    function is_null(value) {
      return value == "" || value == "\\N"
    }

    function reset_copy() {
      table = ""
      delete columns
      delete column_index
      column_count = 0
    }

    function strip_identifier(value) {
      gsub(/^public\./, "", value)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      return value
    }

    /^COPY / {
      reset_copy()
      header = $0
      sub(/^COPY /, "", header)
      split(header, header_parts, " \\(")
      table = strip_identifier(header_parts[1])
      columns_payload = header
      sub(/^[^(]*\(/, "", columns_payload)
      sub(/\) FROM stdin;$/, "", columns_payload)
      column_count = split(columns_payload, columns, ", ")
      for (i = 1; i <= column_count; i++) {
        gsub(/^"/, "", columns[i])
        gsub(/"$/, "", columns[i])
        column_index[columns[i]] = i
      }
      next
    }

    table != "" && $0 == "\\." {
      reset_copy()
      next
    }

    table != "" {
      split($0, fields, "\t")

      if (table == "Organization") {
        organization_rows++
        if ("providerCustomerId" in column_index && !is_null(fields[column_index["providerCustomerId"]])) {
          organization_provider_customer_ids++
        }
      }

      if (table == "Subscription") {
        subscription_rows++
        if ("providerSubscriptionId" in column_index && !is_null(fields[column_index["providerSubscriptionId"]])) {
          subscription_provider_subscription_ids++
        }
        if ("providerPaymentId" in column_index && !is_null(fields[column_index["providerPaymentId"]])) {
          subscription_provider_payment_ids++
        }
        if ("billingProvider" in column_index && !is_null(fields[column_index["billingProvider"]])) {
          subscription_billing_providers++
        }
        if ("providerStatus" in column_index && !is_null(fields[column_index["providerStatus"]])) {
          subscription_provider_statuses++
        }
      }

      if (table == "PaymentAttempt") {
        payment_attempt_rows++
        if ("providerCheckoutSessionId" in column_index && !is_null(fields[column_index["providerCheckoutSessionId"]])) {
          payment_attempt_checkout_session_ids++
        }
        if ("providerPaymentIntentId" in column_index && !is_null(fields[column_index["providerPaymentIntentId"]])) {
          payment_attempt_payment_intent_ids++
        }
        if ("providerCustomerId" in column_index && !is_null(fields[column_index["providerCustomerId"]])) {
          payment_attempt_customer_ids++
        }
      }

      if (table == "ProviderWebhookEvent") {
        provider_webhook_event_rows++
      }
    }

    END {
      printf "  Organization rows                       : %d\n", organization_rows + 0
      printf "  Organization.providerCustomerId set     : %d\n", organization_provider_customer_ids + 0
      printf "  Subscription rows                       : %d\n", subscription_rows + 0
      printf "  Subscription.providerSubscriptionId set : %d\n", subscription_provider_subscription_ids + 0
      printf "  Subscription.providerPaymentId set      : %d\n", subscription_provider_payment_ids + 0
      printf "  Subscription.billingProvider set        : %d\n", subscription_billing_providers + 0
      printf "  Subscription.providerStatus set         : %d\n", subscription_provider_statuses + 0
      printf "  PaymentAttempt rows                     : %d\n", payment_attempt_rows + 0
      printf "  PaymentAttempt checkout session IDs     : %d\n", payment_attempt_checkout_session_ids + 0
      printf "  PaymentAttempt payment intent IDs       : %d\n", payment_attempt_payment_intent_ids + 0
      printf "  PaymentAttempt customer IDs             : %d\n", payment_attempt_customer_ids + 0
      printf "  ProviderWebhookEvent rows               : %d\n", provider_webhook_event_rows + 0
    }
  ' "${DUMP_PATH}"
}

write_restore_sql() {
  {
    cat <<'SQL'
BEGIN;

SET LOCAL session_replication_role = replica;

DO $$
DECLARE
  tables_to_truncate text;
BEGIN
  SELECT string_agg(format('%I.%I', schemaname, tablename), ', ')
  INTO tables_to_truncate
  FROM pg_tables
  WHERE schemaname = 'public'
    AND tablename <> '_prisma_migrations';

  IF tables_to_truncate IS NOT NULL THEN
    EXECUTE 'TRUNCATE TABLE ' || tables_to_truncate || ' RESTART IDENTITY CASCADE';
  END IF;
END
$$;

SQL

    cat "${DUMP_PATH}"

    cat <<'SQL'

SET LOCAL session_replication_role = origin;
SQL

    if [[ "${PRESERVE_STRIPE_PROVIDER_DATA}" != "1" ]]; then
      cat <<'SQL'

-- Neutralize beta/test payment-provider identifiers before using the data in production.
-- Subscription rows and application plan/status context are preserved.
DO $$
BEGIN
  IF to_regclass('public."PaymentAttempt"') IS NOT NULL THEN
    UPDATE public."PaymentAttempt"
    SET
      "providerCheckoutSessionId" = NULL,
      "providerPaymentIntentId" = NULL,
      "providerCustomerId" = NULL,
      "updatedAt" = NOW();
  END IF;

  IF to_regclass('public."Organization"') IS NOT NULL THEN
    UPDATE public."Organization"
    SET
      "providerCustomerId" = NULL,
      "updatedAt" = NOW()
    WHERE "providerCustomerId" IS NOT NULL;
  END IF;

  IF to_regclass('public."Subscription"') IS NOT NULL THEN
    UPDATE public."Subscription"
    SET
      "providerSubscriptionId" = NULL,
      "providerPaymentId" = NULL,
      "updatedAt" = NOW()
    WHERE "providerSubscriptionId" IS NOT NULL
       OR "providerPaymentId" IS NOT NULL;
  END IF;

  IF to_regclass('public."ProviderWebhookEvent"') IS NOT NULL THEN
    DELETE FROM public."ProviderWebhookEvent";
  END IF;
END
$$;
SQL
    fi

    cat <<'SQL'

DO $$
DECLARE
  organization_provider_customer_ids integer := 0;
  subscription_provider_subscription_ids integer := 0;
  subscription_provider_payment_ids integer := 0;
  payment_attempt_provider_ids integer := 0;
  provider_webhook_events integer := 0;
BEGIN
  IF to_regclass('public."Organization"') IS NOT NULL THEN
    SELECT COUNT(*) INTO organization_provider_customer_ids
    FROM public."Organization"
    WHERE "providerCustomerId" IS NOT NULL;
  END IF;

  IF to_regclass('public."Subscription"') IS NOT NULL THEN
    SELECT COUNT(*) INTO subscription_provider_subscription_ids
    FROM public."Subscription"
    WHERE "providerSubscriptionId" IS NOT NULL;

    SELECT COUNT(*) INTO subscription_provider_payment_ids
    FROM public."Subscription"
    WHERE "providerPaymentId" IS NOT NULL;
  END IF;

  IF to_regclass('public."PaymentAttempt"') IS NOT NULL THEN
    SELECT COUNT(*) INTO payment_attempt_provider_ids
    FROM public."PaymentAttempt"
    WHERE "providerCheckoutSessionId" IS NOT NULL
       OR "providerPaymentIntentId" IS NOT NULL
       OR "providerCustomerId" IS NOT NULL;
  END IF;

  IF to_regclass('public."ProviderWebhookEvent"') IS NOT NULL THEN
    SELECT COUNT(*) INTO provider_webhook_events
    FROM public."ProviderWebhookEvent";
  END IF;

  RAISE NOTICE 'Stripe/provider identifiers after restore: Organization.providerCustomerId=%, Subscription.providerSubscriptionId=%, Subscription.providerPaymentId=%, PaymentAttempt provider IDs=%, ProviderWebhookEvent=%',
    organization_provider_customer_ids,
    subscription_provider_subscription_ids,
    subscription_provider_payment_ids,
    payment_attempt_provider_ids,
    provider_webhook_events;
END
$$;

COMMIT;
SQL
  } > "${RESTORE_SQL_PATH}"
}

SSH_COMMAND=(ssh)

if [[ -n "${REMOTE_SSH_OPTS}" ]]; then
  # shellcheck disable=SC2206
  SSH_EXTRA_OPTS=(${REMOTE_SSH_OPTS})
  SSH_COMMAND+=("${SSH_EXTRA_OPTS[@]}")
fi

SSH_COMMAND+=("${TARGET}")

REMOTE_IDENTITY_COMMAND="$(build_remote_identity_command)"
REMOTE_PSQL_COMMAND="$(build_remote_psql_command)"

print_info "Remote target : ${TARGET}"
print_info "Remote service: ${REMOTE_DB_SERVICE}"
print_info "Dump file     : ${DUMP_PATH}"
print_info "Restore SQL   : ${RESTORE_SQL_PATH}"
print_info "Mode          : $([[ "${EXECUTE}" == "1" ]] && echo "execute" || echo "dry-run")"
print_info "Stripe data   : $([[ "${PRESERVE_STRIPE_PROVIDER_DATA}" == "1" ]] && echo "preserve provider identifiers" || echo "neutralize provider identifiers")"

echo
print_warn "Stripe/provider data found in dump"
print_dump_stripe_summary

if [[ "${PRESERVE_STRIPE_PROVIDER_DATA}" != "1" ]]; then
  print_warn "Stripe/provider external identifiers will be cleared after import. Application subscriptions and plan assignments are kept."
else
  print_warn "Stripe/provider external identifiers will be preserved."
fi

if [[ "${EXECUTE}" != "1" ]]; then
  echo
  print_info "Testing SSH connectivity"
  run_remote_check "echo 'SSH connection OK'" >/dev/null
  print_ok "SSH connectivity"

  REMOTE_HOSTNAME="$(run_remote_check "hostname")"
  print_ok "Remote host resolved: ${REMOTE_HOSTNAME}"

  print_info "Testing remote postgres container access"
  run_remote_check "$(printf "%q " sudo docker compose -f "${REMOTE_COMPOSE_FILE}" exec -T "${REMOTE_DB_SERVICE}" sh -lc 'command -v psql >/dev/null && psql --version && pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"')" >/dev/null
  print_ok "Remote postgres access"

  REMOTE_IDENTITY="$(run_remote_check "${REMOTE_IDENTITY_COMMAND}")"
  REMOTE_DB_NAME="$(parse_identity_value "${REMOTE_IDENTITY}" db)"
  print_ok "Remote database resolved: ${REMOTE_DB_NAME}"

  write_restore_sql

  echo
  print_warn "Dry-run only. Remote data was not changed."
  echo
  echo "Restore plan"
  echo "  SSH target       : ${TARGET}"
  echo "  Host             : ${REMOTE_HOSTNAME:-unknown}"
  echo "  DB service       : ${REMOTE_DB_SERVICE}"
  echo "  DB name          : ${REMOTE_DB_NAME:-unknown}"
  echo "  Dump file        : ${DUMP_PATH}"
  echo "  Restore SQL      : ${RESTORE_SQL_PATH}"
  echo "  Destructive step : TRUNCATE every public table except _prisma_migrations"
  echo "  Seed data        : restored from beta dump with beta IDs"
  echo "  Import           : replay dump in one transaction"
  echo "  Stripe/provider  : $([[ "${PRESERVE_STRIPE_PROVIDER_DATA}" == "1" ]] && echo "preserve" || echo "neutralize external IDs")"
  echo
  echo "Remote restore command:"
  printf '  %q ' "${SSH_COMMAND[@]}"
  printf "%s < %q\n" "${REMOTE_PSQL_COMMAND}" "${RESTORE_SQL_PATH}"
  exit 0
fi

print_info "Resolving remote database target"
REMOTE_HOSTNAME="$(run_remote_check "hostname")"
print_ok "Remote host resolved: ${REMOTE_HOSTNAME}"
REMOTE_IDENTITY="$(run_remote_check "${REMOTE_IDENTITY_COMMAND}")"
REMOTE_DB_NAME="$(parse_identity_value "${REMOTE_IDENTITY}" db)"
print_ok "Remote database resolved: ${REMOTE_DB_NAME}"

write_restore_sql

echo
print_warn "Execution summary"
echo "Target"
echo "  SSH target       : ${TARGET}"
echo "  Host             : ${REMOTE_HOSTNAME:-unknown}"
echo "  DB service       : ${REMOTE_DB_SERVICE}"
echo "  DB name          : ${REMOTE_DB_NAME:-unknown}"
echo "  Dump file        : ${DUMP_PATH}"
echo "  Restore SQL      : ${RESTORE_SQL_PATH}"
echo "  Destructive step : TRUNCATE every public table except _prisma_migrations"
echo "  Seed data        : restored from beta dump with beta IDs"
echo "  Stripe/provider  : $([[ "${PRESERVE_STRIPE_PROVIDER_DATA}" == "1" ]] && echo "preserve external IDs" || echo "neutralize external IDs after import")"
echo

if [[ ! -t 0 ]]; then
  print_error "Interactive confirmation is required for --exec."
  exit 1
fi

read -r -p "Type 'RESTORE' to continue: " EXEC_CONFIRMATION
if [[ "${EXEC_CONFIRMATION}" != "RESTORE" ]]; then
  print_warn "Execution aborted."
  exit 1
fi

print_info "Restoring dump into remote database"
if "${SSH_COMMAND[@]}" "${REMOTE_PSQL_COMMAND}" < "${RESTORE_SQL_PATH}" 2>"${RESTORE_SQL_PATH}.stderr"; then
  rm -f "${RESTORE_SQL_PATH}.stderr"
  print_ok "Remote database restored"
else
  print_error "Remote restore failed."
  cat "${RESTORE_SQL_PATH}.stderr"
  rm -f "${RESTORE_SQL_PATH}.stderr"
  exit 1
fi
