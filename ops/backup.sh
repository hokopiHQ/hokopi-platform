#!/bin/bash

# Configuration
# ----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "${SCRIPT_DIR}/.env" ]; then
    echo "Error: ${SCRIPT_DIR}/.env file not found."
    exit 1
fi

# Source .env and export variables
set -a
source "${SCRIPT_DIR}/.env"
set +a

# Restic Configuration
# RESTIC_PASSWORD must be in .env or environment
export RESTIC_REPOSITORY="sftp:${BACKUP_USER}@${BACKUP_SERVER}:${REMOTE_BASE_DIR}/restic-repo"

# Retention Defaults
BACKUP_RETENTION_DAYS=${BACKUP_RETENTION_DAYS:-30}
BACKUP_RETENTION_WEEKS=${BACKUP_RETENTION_WEEKS:-52}
BACKUP_RETENTION_MONTHS=${BACKUP_RETENTION_MONTHS:-60}

DOCKER_COMPOSE_FILE="/var/www/app/docker/docker-compose.prod.yml"

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# 0. Pre-flight Checks & Setup
# ----------------------
if [ -z "$BACKUP_USER" ] || [ -z "$BACKUP_SERVER" ] || [ -z "$REMOTE_BASE_DIR" ] || [ -z "$RESTIC_PASSWORD" ]; then
    log "Error: BACKUP_USER, BACKUP_SERVER, REMOTE_BASE_DIR or RESTIC_PASSWORD are not set."
    exit 1
fi

# Check for Restic
if ! command -v restic &> /dev/null; then
    log "Error: 'restic' is not installed or not in PATH."
    log "Please install restic manually on the server (e.g. in /usr/local/bin or ~/.local/bin)."
    exit 1
fi

# 1. Initialize Repository (Idempotent)
# ----------------------
log "Checking repository status..."
if ! restic snapshots &> /dev/null; then
    log "Repository not initialized. Initializing now..."
    if restic init; then
        log "Repository initialized successfully."
    else
        log "Error: Failed to initialize repository."
        exit 1
    fi
else
    log "Repository already exists."
fi

# 2. Create Backup
# ----------------------
log "Starting backup..."

CONTAINER_ID=$(sudo docker compose -f "${DOCKER_COMPOSE_FILE}" ps -q postgres)
if [ -z "${CONTAINER_ID}" ]; then
    log "Error: Postgres container not found."
    exit 1
fi

# Stream pg_dump directly to restic
# --stdin-filename gives the "file" a name inside the backup snapshot
FILENAME="db_dump.sql"

if sudo docker exec "${CONTAINER_ID}" sh -c 'pg_dump -d "$POSTGRES_DB" -U "$POSTGRES_USER"' | \
   restic backup --stdin --stdin-filename "${FILENAME}" --tag "postgres"; then
    log "Backup created successfully (Snapshot file: ${FILENAME})."
else
    log "Error: Backup failed."
    exit 1
fi

# 3. Apply Retention Policy
# ----------------------
log "Applying retention policy..."
log "Keep: ${BACKUP_RETENTION_DAYS} daily, ${BACKUP_RETENTION_WEEKS} weekly, ${BACKUP_RETENTION_MONTHS} monthly."

if restic forget \
    --keep-daily "${BACKUP_RETENTION_DAYS}" \
    --keep-weekly "${BACKUP_RETENTION_WEEKS}" \
    --keep-monthly "${BACKUP_RETENTION_MONTHS}" \
    --prune; then
    log "Retention policy applied and repository pruned."
else
    log "Warning: Retention cleanup failed."
fi

log "Backup process finished."
