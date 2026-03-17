#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") <user@host>"
  echo
  echo "Environment overrides:"
  echo "  LOCAL_PORT     (default: 15432)"
  echo "  REMOTE_HOST_DB (default: 127.0.0.1)"
  echo "  REMOTE_PORT_DB (default: 5432)"
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

TARGET="$1"
LOCAL_PORT="${LOCAL_PORT:-15432}"
REMOTE_HOST_DB="${REMOTE_HOST_DB:-127.0.0.1}"
REMOTE_PORT_DB="${REMOTE_PORT_DB:-5432}"

echo "Opening SSH tunnel to ${TARGET}..."
echo "Local endpoint : 127.0.0.1:${LOCAL_PORT}"
echo "Remote endpoint: ${REMOTE_HOST_DB}:${REMOTE_PORT_DB}"
echo "Press Ctrl-C to close the tunnel."

exec ssh -N -L "${LOCAL_PORT}:${REMOTE_HOST_DB}:${REMOTE_PORT_DB}" "${TARGET}"
