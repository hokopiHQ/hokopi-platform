#!/usr/bin/env bash
set -euo pipefail

MODE="check"
TARGET_ENV="${TARGET_ENV:-}"

APP_USER="${APP_USER:-app}"
APP_DIR="${APP_DIR:-/var/www/app}"
KEYBOARD_LAYOUT="${KEYBOARD_LAYOUT:-fr}"
GITHUB_REPO="${GITHUB_REPOSITORY:-hokopiHQ/hokopi-webapp}"
REPO_KEY_NAME="${REPO_KEY_NAME:-id_rsa}"
DEPLOY_KEY_NAME="${DEPLOY_KEY_NAME:-id_rsa_app_deploy}"
SUDOERS_FILE="${SUDOERS_FILE:-/etc/sudoers.d/app-docker}"
GITHUB_BLANK_VALUE="${GITHUB_BLANK_VALUE:-__BLANK__}"

BACKUP_USER="${BACKUP_USER:-}"
BACKUP_SERVER="${BACKUP_SERVER:-}"
BACKUP_SFTP_PORT="23"
RESTIC_REMOTE_BASE_DIR="${RESTIC_REMOTE_BASE_DIR:-}"

CHANGES=0
WARNINGS=0
FAILURES=0

REQUIRED_GITHUB_SECRETS=(
  SSH_KEY
  BACKEND_JWT_SECRET
  BACKEND_DATABASE_URL
  BACKEND_POSTGRES_USER
  BACKEND_POSTGRES_PASSWORD
  BACKEND_POSTGRES_DB
  BACKEND_RESEND_API_KEY
  BACKEND_STRIPE_SECRET_KEY
  BACKEND_STRIPE_WEBHOOK_SECRET
  RESTIC_PASSWORD
)

REQUIRED_GITHUB_VARS=(
  SSH_USER
  SSH_SERVER
  BACKUP_USER
  BACKUP_SERVER
  BACKEND_MAIL_ENABLED
  APP_URL
  WEBSITE_URL
  WEBSITE_NOINDEX
  BACKEND_MAIL_FROM
  BACKEND_MAIL_REPLYTO
  FRONTEND_STRIPE_PUBLIC_KEY
)

OPTIONAL_GITHUB_VARS=(
  BACKUP_RETENTION_DAYS
  BACKUP_RETENTION_WEEKS
  BACKUP_RETENTION_MONTHS
)

usage() {
  cat <<'EOF'
Usage: environmentConfig.sh [check|run] [options]

Single idempotent environment configuration flow for HoKoPi servers.

Modes:
  check                 Report what is missing. Default. No server config change.
  run                   Apply missing server configuration and GitHub/Restic setup when possible.

Options:
  --env <name>          production | preprod. If omitted in a terminal, the script asks.
  --repo <owner/repo>   GitHub repo cloned by the deploy workflow. Default: hokopiHQ/hokopi-webapp
  --app-user <name>     Application user. Default: app
  --app-dir <path>      Application directory. Default: /var/www/app
  --keyboard <code>     Console keyboard layout. Default: fr
  -h, --help            Show this help.

Environment inputs used for GitHub variable values when present:
  SSH_SERVER
  BACKUP_USER
  BACKUP_SERVER
  BACKUP_RETENTION_DAYS
  BACKUP_RETENTION_WEEKS
  BACKUP_RETENTION_MONTHS
  BACKEND_MAIL_ENABLED
  BACKEND_MAIL_FROM
  BACKEND_MAIL_REPLYTO
  FRONTEND_STRIPE_PUBLIC_KEY

GitHub secrets checked by name only, except SSH_KEY which run can create:
  SSH_KEY
  BACKEND_JWT_SECRET
  BACKEND_DATABASE_URL
  BACKEND_POSTGRES_USER
  BACKEND_POSTGRES_PASSWORD
  BACKEND_POSTGRES_DB
  BACKEND_RESEND_API_KEY
  BACKEND_STRIPE_SECRET_KEY
  BACKEND_STRIPE_WEBHOOK_SECRET
  RESTIC_PASSWORD

Examples:
  sudo bash ./ops/environmentConfig.sh
  sudo bash ./ops/environmentConfig.sh check --env production
  sudo bash ./ops/environmentConfig.sh run --env production
  sudo GITHUB_REPOSITORY=hokopiHQ/hokopi-webapp SSH_SERVER=1.2.3.4 bash ./ops/environmentConfig.sh run --env production

Notes:
  - the script must be executed interactively as root, including check mode.
  - run installs gh automatically when missing; check reports it.
  - check and run start gh auth login when gh is installed but not authenticated.
  - Secret values are never printed.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    check|run)
      MODE="$1"
      shift
      ;;
    --env|--environment)
      TARGET_ENV="${2:-}"
      shift 2
      ;;
    --repo)
      GITHUB_REPO="${2:-}"
      shift 2
      ;;
    --app-user)
      APP_USER="${2:-}"
      shift 2
      ;;
    --app-dir)
      APP_DIR="${2:-}"
      shift 2
      ;;
    --keyboard)
      KEYBOARD_LAYOUT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${MODE}" != "check" && "${MODE}" != "run" ]]; then
  echo "Invalid mode: ${MODE}" >&2
  usage
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be executed as root, for example: sudo bash ./ops/environmentConfig.sh ${MODE} --env production" >&2
  exit 1
fi

if [[ ! -t 0 || ! -t 1 ]]; then
  echo "This script must be executed from an interactive terminal." >&2
  exit 1
fi

if [[ -t 1 ]]; then
  BLUE=$'\033[1;34m'
  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'
  RED=$'\033[1;31m'
  RESET=$'\033[0m'
else
  BLUE=''
  GREEN=''
  YELLOW=''
  RED=''
  RESET=''
fi

info() {
  printf '%s\n' "${BLUE}==>${RESET} $*"
}

ok() {
  printf '%s\n' "${GREEN}OK${RESET}  $*"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf '%s\n' "${YELLOW}WARN${RESET} $*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf '%s\n' "${RED}FAIL${RESET} $*"
}

change() {
  CHANGES=$((CHANGES + 1))
  printf '%s\n' "${YELLOW}RUN${RESET} $*"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_cmd() {
  if [[ "${MODE}" == "check" ]]; then
    change "Would run: $*"
  else
    change "$*"
    "$@"
  fi
}

prompt_environment() {
  if [[ -n "${TARGET_ENV}" ]]; then
    return
  fi

  if [[ ! -t 0 ]]; then
    fail "Environment is required in non-interactive mode. Pass --env production or --env preprod."
    return
  fi

  printf '\nChoose target environment:\n'
  printf '  1) production\n'
  printf '  2) preprod\n'
  local answer
  read -r -p "Environment [1]: " answer
  case "${answer:-1}" in
    1|production)
      TARGET_ENV="production"
      ;;
    2|preprod)
      TARGET_ENV="preprod"
      ;;
    *)
      fail "Invalid environment choice: ${answer}"
      ;;
  esac
}

configure_environment_defaults() {
  if [[ "${TARGET_ENV}" != "production" && "${TARGET_ENV}" != "preprod" ]]; then
    fail "TARGET_ENV must be production or preprod. Got: ${TARGET_ENV:-empty}"
    return
  fi

  if [[ "${TARGET_ENV}" == "production" ]]; then
    EXPECTED_APP_URL="https://app.hokopi.com"
    EXPECTED_WEBSITE_URL="https://hokopi.com"
    EXPECTED_WEBSITE_NOINDEX="false"
    RESTIC_REMOTE_BASE_DIR="${RESTIC_REMOTE_BASE_DIR:-production}"
  else
    EXPECTED_APP_URL="https://app.beta.hokopi.com"
    EXPECTED_WEBSITE_URL="https://beta.hokopi.com"
    EXPECTED_WEBSITE_NOINDEX="true"
    RESTIC_REMOTE_BASE_DIR="${RESTIC_REMOTE_BASE_DIR:-preprod}"
  fi

  ok "Target environment: ${TARGET_ENV}"
  ok "GitHub repo: ${GITHUB_REPO}"
}

check_os() {
  info "Checking OS"
  if [[ ! -f /etc/os-release ]]; then
    fail "/etc/os-release not found."
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  if [[ "${ID:-}" == "ubuntu" ]]; then
    ok "Ubuntu ${VERSION_ID:-unknown} detected."
  else
    warn "Expected Ubuntu LTS. Detected ID=${ID:-unknown}, VERSION=${VERSION_ID:-unknown}."
  fi
}

check_privileges() {
  info "Checking privileges"
  ok "Running as root."
}

update_system() {
  info "Checking system update step"
  run_cmd apt-get update
  run_cmd apt-get upgrade -y
}

install_packages() {
  info "Checking base packages"
  local missing=()
  local package_name
  local packages=(
    ca-certificates
    console-setup
    curl
    git
    gnupg
    keyboard-configuration
    openssh-client
    restic
    sudo
  )

  for package_name in "${packages[@]}"; do
    if dpkg-query -W -f='${Status}' "${package_name}" 2>/dev/null | grep -q "install ok installed"; then
      ok "Package installed: ${package_name}"
    else
      warn "Package missing: ${package_name}"
      missing+=("${package_name}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    run_cmd apt-get install -y --no-install-recommends "${missing[@]}"
  fi
}

install_docker() {
  info "Checking Docker"
  if command_exists docker && docker compose version >/dev/null 2>&1; then
    ok "Docker is installed: $(docker --version 2>/dev/null || true)"
    ok "Docker Compose plugin is installed: $(docker compose version 2>/dev/null || true)"
    return
  fi

  warn "Docker CE or Docker Compose plugin is missing."

  if [[ ! -f /etc/os-release ]]; then
    fail "Cannot configure Docker apt repository without /etc/os-release."
    return
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  local distro_id="${ID:-ubuntu}"
  local codename="${VERSION_CODENAME:-}"
  local arch
  local repo_file="/etc/apt/sources.list.d/docker.list"

  if [[ -z "${codename}" ]]; then
    fail "Cannot determine VERSION_CODENAME for Docker apt repository."
    return
  fi

  arch="$(dpkg --print-architecture)"

  run_cmd install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    run_cmd curl -fsSL "https://download.docker.com/linux/${distro_id}/gpg" -o /etc/apt/keyrings/docker.asc
    run_cmd chmod a+r /etc/apt/keyrings/docker.asc
  else
    ok "Docker apt key already exists."
  fi

  local repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro_id} ${codename} stable"
  if [[ -f "${repo_file}" ]] && grep -qxF "${repo_line}" "${repo_file}"; then
    ok "Docker apt repository already configured."
  elif [[ "${MODE}" == "check" ]]; then
    change "Would write Docker apt repository to ${repo_file}"
  else
    change "Writing Docker apt repository to ${repo_file}"
    printf '%s\n' "${repo_line}" > "${repo_file}"
  fi

  run_cmd apt-get update
  run_cmd apt-get install -y --no-install-recommends docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_cmd systemctl enable docker
  run_cmd systemctl start docker
}

install_github_cli() {
  info "Checking GitHub CLI"
  if command_exists gh; then
    ok "gh is installed: $(gh --version 2>/dev/null | head -n 1 || true)"
    return
  fi

  warn "gh is missing."
  run_cmd install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/githubcli-archive-keyring.gpg ]]; then
    run_cmd curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    run_cmd chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  else
    ok "GitHub CLI apt key already exists."
  fi

  local repo_file="/etc/apt/sources.list.d/github-cli.list"
  local arch
  arch="$(dpkg --print-architecture)"
  local repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"

  if [[ -f "${repo_file}" ]] && grep -qxF "${repo_line}" "${repo_file}"; then
    ok "GitHub CLI apt repository already configured."
  elif [[ "${MODE}" == "check" ]]; then
    change "Would write GitHub CLI apt repository to ${repo_file}"
  else
    change "Writing GitHub CLI apt repository to ${repo_file}"
    printf '%s\n' "${repo_line}" > "${repo_file}"
  fi

  run_cmd apt-get update
  run_cmd apt-get install -y --no-install-recommends gh
}

ensure_github_auth() {
  info "Checking GitHub CLI authentication"

  if ! command_exists gh; then
    warn "gh is not available yet. GitHub authentication cannot be checked."
    return
  fi

  if gh auth status >/dev/null 2>&1; then
    ok "gh is authenticated."
    return
  fi

  change "Starting GitHub authentication"
  if gh auth login; then
    ok "gh authentication completed."
  else
    fail "gh auth login failed."
  fi
}

configure_keyboard() {
  info "Checking keyboard configuration"
  local keyboard_file="/etc/default/keyboard"
  local current_layout=""

  if [[ -f "${keyboard_file}" ]]; then
    current_layout="$(grep -E '^XKBLAYOUT=' "${keyboard_file}" 2>/dev/null | tail -n 1 | cut -d= -f2- | tr -d '"')"
  fi

  if [[ "${current_layout}" == "${KEYBOARD_LAYOUT}" ]]; then
    ok "Keyboard layout is ${KEYBOARD_LAYOUT}."
    return
  fi

  if [[ "${MODE}" == "check" ]]; then
    change "Would set keyboard layout to ${KEYBOARD_LAYOUT} in ${keyboard_file}"
    return
  fi

  change "Setting keyboard layout to ${KEYBOARD_LAYOUT}"
  cat > "${keyboard_file}" <<EOF
XKBMODEL="pc105"
XKBLAYOUT="${KEYBOARD_LAYOUT}"
XKBVARIANT=""
XKBOPTIONS=""

BACKSPACE="guess"
EOF

  if command_exists setupcon; then
    setupcon || warn "setupcon failed. Keyboard config should apply after reboot."
  else
    warn "setupcon not available. Keyboard config should apply after reboot."
  fi
}

user_home() {
  getent passwd "${APP_USER}" | cut -d: -f6
}

configure_app_user() {
  info "Checking application user and directory"
  if id "${APP_USER}" >/dev/null 2>&1; then
    ok "User exists: ${APP_USER}"
  else
    run_cmd adduser --disabled-password --gecos "" "${APP_USER}"
  fi

  if [[ -d "${APP_DIR}" ]]; then
    ok "Application directory exists: ${APP_DIR}"
  else
    run_cmd mkdir -p "${APP_DIR}"
  fi

  if id "${APP_USER}" >/dev/null 2>&1 && [[ -d "${APP_DIR}" ]]; then
    local current_owner
    current_owner="$(stat -c '%U:%G' "${APP_DIR}" 2>/dev/null || true)"
    if [[ "${current_owner}" == "${APP_USER}:${APP_USER}" ]]; then
      ok "${APP_DIR} owner is ${APP_USER}:${APP_USER}"
    else
      run_cmd chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"
    fi
  fi
}

configure_ssh_keys() {
  info "Checking SSH keys"
  if ! id "${APP_USER}" >/dev/null 2>&1; then
    warn "Cannot configure SSH keys until ${APP_USER} exists."
    return
  fi

  local home_dir
  home_dir="$(user_home)"
  local ssh_dir="${home_dir}/.ssh"
  local repo_key="${ssh_dir}/${REPO_KEY_NAME}"
  local deploy_key="${ssh_dir}/${DEPLOY_KEY_NAME}"
  local authorized_keys="${ssh_dir}/authorized_keys"

  if [[ -d "${ssh_dir}" ]]; then
    ok "SSH directory exists: ${ssh_dir}"
  else
    run_cmd install -d -m 700 -o "${APP_USER}" -g "${APP_USER}" "${ssh_dir}"
  fi

  if [[ -f "${repo_key}" && -f "${repo_key}.pub" ]]; then
    ok "Repository clone key exists: ${repo_key}"
  else
    run_cmd sudo -u "${APP_USER}" ssh-keygen -t rsa -b 4096 -f "${repo_key}" -N "" -q
  fi

  if [[ -f "${deploy_key}" && -f "${deploy_key}.pub" ]]; then
    ok "GitHub Actions deploy key exists: ${deploy_key}"
  else
    run_cmd sudo -u "${APP_USER}" ssh-keygen -t rsa -b 4096 -f "${deploy_key}" -N "" -q
  fi

  if [[ -f "${authorized_keys}" ]]; then
    ok "authorized_keys exists."
  elif [[ "${MODE}" == "check" ]]; then
    change "Would create ${authorized_keys}"
  else
    change "Creating ${authorized_keys}"
    install -m 600 -o "${APP_USER}" -g "${APP_USER}" /dev/null "${authorized_keys}"
  fi

  if [[ -f "${deploy_key}.pub" && -f "${authorized_keys}" ]] && grep -qxF "$(cat "${deploy_key}.pub")" "${authorized_keys}"; then
    ok "GitHub Actions public key is authorized for SSH login."
  elif [[ "${MODE}" == "check" ]]; then
    change "Would append ${deploy_key}.pub to ${authorized_keys}"
  else
    change "Authorizing GitHub Actions SSH key"
    cat "${deploy_key}.pub" >> "${authorized_keys}"
    chown "${APP_USER}:${APP_USER}" "${authorized_keys}"
    chmod 600 "${authorized_keys}"
  fi
}

configure_sudoers() {
  info "Checking Docker sudoers policy"
  local docker_path="/usr/bin/docker"
  if command_exists docker; then
    docker_path="$(command -v docker)"
  fi

  local expected
  expected="$(cat <<EOF
Cmnd_Alias DOCKER_SAFE = \\
    ${docker_path} compose *, \\
    ${docker_path} exec *, \\
    ${docker_path} logs *, \\
    ${docker_path} start *, \\
    ${docker_path} stop *, \\
    ${docker_path} restart *, \\
    ${docker_path} inspect *, \\
    ${docker_path} ps

Cmnd_Alias DOCKER_CLEAN = \\
    ${docker_path} builder prune -f --filter until=24h, \\
    ${docker_path} image prune -f --filter until=24h --filter label!=keep

${APP_USER} ALL=(root) NOPASSWD: DOCKER_SAFE
${APP_USER} ALL=(root) NOPASSWD: DOCKER_CLEAN
EOF
)"

  if [[ -f "${SUDOERS_FILE}" ]] && diff -q <(printf '%s\n' "${expected}") "${SUDOERS_FILE}" >/dev/null 2>&1; then
    ok "Sudoers file is up to date: ${SUDOERS_FILE}"
  elif [[ "${MODE}" == "check" ]]; then
    change "Would write ${SUDOERS_FILE}"
  else
    change "Writing ${SUDOERS_FILE}"
    printf '%s\n' "${expected}" > "${SUDOERS_FILE}"
    chmod 440 "${SUDOERS_FILE}"
  fi

  if command_exists visudo && [[ -f "${SUDOERS_FILE}" ]]; then
    if visudo -cf "${SUDOERS_FILE}" >/dev/null 2>&1; then
      ok "Sudoers syntax is valid."
    else
      fail "Sudoers syntax is invalid: ${SUDOERS_FILE}"
    fi
  fi
}

env_value_for_var() {
  local name="$1"
  case "${name}" in
    SSH_USER)
      printf '%s\n' "${SSH_USER:-${APP_USER}}"
      ;;
    SSH_SERVER)
      printf '%s\n' "${SSH_SERVER:-}"
      ;;
    APP_URL)
      printf '%s\n' "${APP_URL:-${EXPECTED_APP_URL}}"
      ;;
    WEBSITE_URL)
      printf '%s\n' "${WEBSITE_URL:-${EXPECTED_WEBSITE_URL}}"
      ;;
    WEBSITE_NOINDEX)
      printf '%s\n' "${WEBSITE_NOINDEX:-${EXPECTED_WEBSITE_NOINDEX}}"
      ;;
    BACKUP_USER)
      printf '%s\n' "${BACKUP_USER:-}"
      ;;
    BACKUP_SERVER)
      printf '%s\n' "${BACKUP_SERVER:-}"
      ;;
    BACKUP_RETENTION_DAYS)
      printf '%s\n' "${BACKUP_RETENTION_DAYS:-}"
      ;;
    BACKUP_RETENTION_WEEKS)
      printf '%s\n' "${BACKUP_RETENTION_WEEKS:-}"
      ;;
    BACKUP_RETENTION_MONTHS)
      printf '%s\n' "${BACKUP_RETENTION_MONTHS:-}"
      ;;
    BACKEND_MAIL_ENABLED)
      printf '%s\n' "${BACKEND_MAIL_ENABLED:-false}"
      ;;
    BACKEND_MAIL_FROM)
      printf '%s\n' "${BACKEND_MAIL_FROM:-}"
      ;;
    BACKEND_MAIL_REPLYTO)
      printf '%s\n' "${BACKEND_MAIL_REPLYTO:-}"
      ;;
    FRONTEND_STRIPE_PUBLIC_KEY)
      printf '%s\n' "${FRONTEND_STRIPE_PUBLIC_KEY:-}"
      ;;
    *)
      printf '%s\n' ""
      ;;
  esac
}

github_is_ready() {
  if ! command_exists gh; then
    warn "gh is not available yet. GitHub configuration will be checked after installation and authentication."
    return 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    warn "gh is installed but not authenticated."
    return 1
  fi

  return 0
}

check_github_variable_value() {
  local name="$1"
  local value

  if value="$(gh variable get "${name}" --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" 2>/dev/null)"; then
    if [[ -z "${value}" ]]; then
      warn "Variable present but empty: ${name}"
    elif [[ "${value}" == "${GITHUB_BLANK_VALUE}" ]]; then
      warn "Variable present but uses placeholder ${GITHUB_BLANK_VALUE}: ${name}"
    else
      ok "Variable present: ${name}"
    fi
  else
    warn "Variable present but value could not be read: ${name}"
  fi
}

ssh_key_secret_value() {
  if ! id "${APP_USER}" >/dev/null 2>&1; then
    return
  fi

  local deploy_key
  deploy_key="$(user_home)/.ssh/${DEPLOY_KEY_NAME}"
  if [[ -f "${deploy_key}" ]]; then
    cat "${deploy_key}"
  fi
}

set_github_variable() {
  local name="$1"
  local value="$2"
  local value_file

  value_file="$(mktemp)"
  printf '%s' "${value}" > "${value_file}"
  if ! gh variable set "${name}" --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" < "${value_file}" >/dev/null; then
    rm -f "${value_file}"
    return 1
  fi
  rm -f "${value_file}"
}

set_github_secret() {
  local name="$1"
  local value="$2"
  local value_file

  value_file="$(mktemp)"
  printf '%s' "${value}" > "${value_file}"
  if ! gh secret set "${name}" --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" < "${value_file}" >/dev/null; then
    rm -f "${value_file}"
    return 1
  fi
  rm -f "${value_file}"
}

run_sftp_as_app() {
  local commands="$1"
  local target="$2"
  local batch_file

  batch_file="$(mktemp)"
  printf '%b' "${commands}" > "${batch_file}"
  chmod 644 "${batch_file}"

  if sudo -u "${APP_USER}" sftp -q -P "${BACKUP_SFTP_PORT}" -oBatchMode=yes -oConnectTimeout=10 -b "${batch_file}" "${target}" >/dev/null 2>&1; then
    rm -f "${batch_file}"
    return 0
  fi

  rm -f "${batch_file}"
  return 1
}

url_host() {
  local url="$1"
  local host

  host="${url#*://}"
  host="${host%%/*}"
  host="${host##*@}"
  host="${host%%:*}"
  printf '%s\n' "${host}"
}

github_variable_value_or_default() {
  local name="$1"
  local value=""

  if command_exists gh && gh auth status >/dev/null 2>&1 && value="$(gh variable get "${name}" --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" 2>/dev/null)"; then
    printf '%s\n' "${value}"
    return
  fi

  env_value_for_var "${name}"
}

current_server_ips() {
  if command_exists ip; then
    { ip -o -4 addr show scope global 2>/dev/null || true; } | awk '{split($4, a, "/"); print a[1]}'
    { ip -o -6 addr show scope global 2>/dev/null || true; } | awk '{split($4, a, "/"); print a[1]}'
  fi

  if command_exists curl; then
    curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true
    curl -6 -fsS --max-time 5 https://api64.ipify.org 2>/dev/null || true
  fi
}

check_dns_target() {
  local var_name="$1"
  local url="$2"
  local host
  local server_ips dns_ips server_ip

  if [[ -z "${url}" || "${url}" == "${GITHUB_BLANK_VALUE}" ]]; then
    fail "${var_name} is empty or ${GITHUB_BLANK_VALUE}. Cannot check DNS target."
    return
  fi

  host="$(url_host "${url}")"
  if [[ -z "${host}" || "${host}" == "${url}" ]]; then
    fail "${var_name} is not a valid URL with host: ${url}"
    return
  fi

  info "Checking ${var_name}: ${host}"

  server_ips="$(current_server_ips | sed '/^$/d' | sort -u || true)"
  if [[ -z "${server_ips}" ]]; then
    fail "Cannot determine current server IPs for DNS check."
    return
  fi

  if ! command_exists getent; then
    fail "getent is not available. Cannot resolve DNS for ${host}."
    return
  fi

  dns_ips="$({ getent ahosts "${host}" 2>/dev/null || true; } | awk '{print $1}' | sed '/^$/d' | sort -u)"
  if [[ -z "${dns_ips}" ]]; then
    fail "${var_name} host does not resolve: ${host}"
    return
  fi

  while IFS= read -r server_ip; do
    if grep -qxF "${server_ip}" <<< "${dns_ips}"; then
      ok "${var_name} DNS points to this server: ${host} -> ${server_ip}"
      return
    fi
  done <<< "${server_ips}"

  fail "${var_name} DNS does not point to this server: ${host}"
  warn "Current server IPs: $(tr '\n' ' ' <<< "${server_ips}" | sed 's/[[:space:]]*$//')"
  warn "${host} DNS IPs: $(tr '\n' ' ' <<< "${dns_ips}" | sed 's/[[:space:]]*$//')"
}

check_dns_targets() {
  info "Checking DNS targets"

  check_dns_target APP_URL "$(github_variable_value_or_default APP_URL)"
  check_dns_target WEBSITE_URL "$(github_variable_value_or_default WEBSITE_URL)"
}

configure_github_environment() {
  info "Checking GitHub Environment"
  if ! github_is_ready; then
    return
  fi

  if gh api "repos/${GITHUB_REPO}/environments/${TARGET_ENV}" >/dev/null 2>&1; then
    ok "GitHub Environment exists: ${GITHUB_REPO}/${TARGET_ENV}"
  elif [[ "${MODE}" == "check" ]]; then
    change "Would create GitHub Environment: ${GITHUB_REPO}/${TARGET_ENV}"
  else
    change "Creating GitHub Environment: ${GITHUB_REPO}/${TARGET_ENV}"
    gh api -X PUT "repos/${GITHUB_REPO}/environments/${TARGET_ENV}" >/dev/null
  fi

  local vars_file secrets_file
  vars_file="$(mktemp)"
  secrets_file="$(mktemp)"

  if gh variable list --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" --json name --jq '.[].name' > "${vars_file}" 2>/dev/null; then
    :
  else
    warn "Cannot list GitHub variables for ${TARGET_ENV}."
    rm -f "${vars_file}" "${secrets_file}"
    return
  fi

  if gh secret list --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" --json name --jq '.[].name' > "${secrets_file}" 2>/dev/null; then
    :
  else
    warn "Cannot list GitHub secrets for ${TARGET_ENV}."
    rm -f "${vars_file}" "${secrets_file}"
    return
  fi

  local name value
  info "Checking GitHub Environment variables"
  for name in "${REQUIRED_GITHUB_VARS[@]}"; do
    if grep -qxF "${name}" "${vars_file}"; then
      check_github_variable_value "${name}"
      continue
    fi

    value="$(env_value_for_var "${name}")"
    if [[ -z "${value}" ]]; then
      warn "Variable missing and local value is empty: ${name}. Creating it with placeholder ${GITHUB_BLANK_VALUE}."
      value="${GITHUB_BLANK_VALUE}"
    fi

    if [[ "${MODE}" == "check" ]]; then
      change "Would create GitHub variable: ${name}"
    else
      change "Creating GitHub variable: ${name}"
      set_github_variable "${name}" "${value}"
    fi
  done

  info "Checking optional GitHub Environment variables"
  for name in "${OPTIONAL_GITHUB_VARS[@]}"; do
    if grep -qxF "${name}" "${vars_file}"; then
      check_github_variable_value "${name}"
      continue
    fi

    value="$(env_value_for_var "${name}")"
    if [[ -z "${value}" ]]; then
      ok "Optional variable absent, workflow fallback will apply: ${name}"
      continue
    fi

    if [[ "${MODE}" == "check" ]]; then
      change "Would create optional GitHub variable: ${name}"
    else
      change "Creating optional GitHub variable: ${name}"
      set_github_variable "${name}" "${value}"
    fi
  done

  info "Checking GitHub Environment secrets"
  for name in "${REQUIRED_GITHUB_SECRETS[@]}"; do
    if grep -qxF "${name}" "${secrets_file}"; then
      ok "Secret present: ${name}"
      continue
    fi

    if [[ "${name}" == "SSH_KEY" ]]; then
      value="$(ssh_key_secret_value)"
      if [[ -z "${value}" ]]; then
        warn "Secret missing: SSH_KEY. Cannot create it until the deploy private key exists for ${APP_USER}."
      elif [[ "${MODE}" == "check" ]]; then
        change "Would create GitHub secret: SSH_KEY"
      else
        change "Creating GitHub secret: SSH_KEY"
        set_github_secret SSH_KEY "${value}"
      fi
      continue
    fi

    warn "Secret missing: ${name}. Add it in GitHub UI; this script does not create this secret."
  done

  rm -f "${vars_file}" "${secrets_file}"
}

configure_github_deploy_key() {
  info "Checking GitHub repository Deploy Key"
  if ! github_is_ready; then
    return
  fi

  if ! id "${APP_USER}" >/dev/null 2>&1; then
    warn "Cannot configure GitHub Deploy Key until ${APP_USER} exists."
    return
  fi

  local repo_key pub_key pub_key_fingerprint keys_file
  repo_key="$(user_home)/.ssh/${REPO_KEY_NAME}.pub"
  if [[ ! -f "${repo_key}" ]]; then
    warn "Repository public key is missing: ${repo_key}"
    return
  fi

  pub_key="$(cat "${repo_key}")"
  pub_key_fingerprint="$(printf '%s\n' "${pub_key}" | cut -d ' ' -f1,2)"
  keys_file="$(mktemp)"

  if ! gh api "repos/${GITHUB_REPO}/keys" --jq '.[].key' > "${keys_file}" 2>/dev/null; then
    warn "Cannot list deploy keys for ${GITHUB_REPO}."
    rm -f "${keys_file}"
    return
  fi

  if grep -qF "${pub_key_fingerprint}" "${keys_file}"; then
    ok "Repository Deploy Key is already configured."
  elif [[ "${MODE}" == "check" ]]; then
    change "Would add read-only repository Deploy Key to ${GITHUB_REPO}"
  else
    change "Adding read-only repository Deploy Key to ${GITHUB_REPO}"
    gh api -X POST "repos/${GITHUB_REPO}/keys" -f title="${TARGET_ENV}-server-readonly" -f key="${pub_key}" -F read_only=true >/dev/null
  fi

  rm -f "${keys_file}"
}

configure_restic_remote() {
  info "Checking Restic remote repository"

  if ! github_is_ready; then
    return
  fi

  if ! command_exists sftp; then
    fail "sftp is not available. Cannot check remote Restic repository."
    return
  fi

  if ! id "${APP_USER}" >/dev/null 2>&1; then
    fail "User ${APP_USER} does not exist. Cannot test SFTP access as application user."
    return
  fi

  local backup_user backup_server
  if ! backup_user="$(gh variable get BACKUP_USER --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" 2>/dev/null)"; then
    fail "GitHub variable BACKUP_USER is missing. Cannot test SFTP access."
    return
  fi

  if ! backup_server="$(gh variable get BACKUP_SERVER --env "${TARGET_ENV}" --repo "${GITHUB_REPO}" 2>/dev/null)"; then
    fail "GitHub variable BACKUP_SERVER is missing. Cannot test SFTP access."
    return
  fi

  if [[ -z "${backup_user}" || "${backup_user}" == "${GITHUB_BLANK_VALUE}" ]]; then
    fail "GitHub variable BACKUP_USER is empty or ${GITHUB_BLANK_VALUE}. Cannot test SFTP access."
    return
  fi

  if [[ -z "${backup_server}" || "${backup_server}" == "${GITHUB_BLANK_VALUE}" ]]; then
    fail "GitHub variable BACKUP_SERVER is empty or ${GITHUB_BLANK_VALUE}. Cannot test SFTP access."
    return
  fi

  local target="${backup_user}@${backup_server}"
  local repo_dir="${RESTIC_REMOTE_BASE_DIR#/}"
  repo_dir="${repo_dir%/}/restic-repo"

  if run_sftp_as_app 'pwd\n' "${target}"; then
    ok "SFTP server is reachable as ${APP_USER}: ${target}:${BACKUP_SFTP_PORT}"
  else
    fail "SFTP server is not reachable as ${APP_USER} with GitHub BACKUP_USER/BACKUP_SERVER on port ${BACKUP_SFTP_PORT}: ${target}"
    return
  fi

  if run_sftp_as_app "cd ${repo_dir}"$'\n''pwd'$'\n' "${target}"; then
    ok "Remote Restic repository folder exists for ${APP_USER}: ${target}:${BACKUP_SFTP_PORT}${repo_dir}"
  else
    fail "Remote Restic repository folder is missing or inaccessible as ${APP_USER}: ${target}:${BACKUP_SFTP_PORT}${repo_dir}"
  fi

  ok "Expected RESTIC_REPOSITORY: sftp://${target}:${BACKUP_SFTP_PORT}/${repo_dir}"
}

print_summary() {
  printf '\n'
  info "Summary"
  printf 'Mode: %s\n' "${MODE}"
  printf 'Environment: %s\n' "${TARGET_ENV:-unknown}"
  printf 'Changes needed/executed: %s\n' "${CHANGES}"
  printf 'Warnings: %s\n' "${WARNINGS}"
  printf 'Failures: %s\n' "${FAILURES}"

  if [[ "${FAILURES}" -gt 0 ]]; then
    exit 1
  fi
}

main() {
  prompt_environment
  configure_environment_defaults

  check_os
  check_privileges
  update_system
  install_packages
  install_docker
  install_github_cli
  ensure_github_auth
  configure_keyboard
  configure_app_user
  configure_ssh_keys
  configure_sudoers
  configure_github_environment
  check_dns_targets
  configure_restic_remote
  configure_github_deploy_key
  print_summary
}

main "$@"
