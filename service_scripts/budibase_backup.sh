#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional: load shared env from main backup dir
if [[ -f "$ROOT_DIR/.env" ]]; then
  # shellcheck disable=SC1090
  source "$ROOT_DIR/.env"
fi

# Use central backup log (same as main script) but with Budibase prefix
LOGFILE="${LOGFILE:-$ROOT_DIR/log/backup.log}"
mkdir -p "$(dirname "$LOGFILE")"

log() {
  printf '%s [BUDIBASE] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
  log "[ERROR] $*"
  echo "[BUDIBASE] [ERROR] $*" >&2
}

# Determine which user should run budi (non-root if invoked via sudo)
RUN_USER="${SUDO_USER:-$USER}"

# Explicit node and budi paths (so we don't depend on sudo/NVM PATH)
NODE_BIN="/home/berkkan/.nvm/versions/node/v20.19.6/bin/node"
BUDI_BIN="/home/berkkan/.nvm/versions/node/v20.19.6/bin/budi"

if [[ ! -x "$NODE_BIN" ]]; then
  error "node binary not executable at $NODE_BIN"
  exit 1
fi

if [[ ! -x "$BUDI_BIN" ]]; then
  error "budi binary not executable at $BUDI_BIN"
  exit 1
fi

# Directory where your Budibase docker-compose/.env live
BUDIBASE_DIR="${BUDIBASE_DIR:-/home/berkkan/docker-services/budibase}"
BUDIBASE_ENV_FILE="${BUDIBASE_ENV_FILE:-.env}"

# Directory where Budibase backup files will be stored
BUDIBASE_BACKUP_DIR="${BUDIBASE_BACKUP_DIR:-$ROOT_DIR/backups/budibase}"
mkdir -p "$BUDIBASE_BACKUP_DIR"

if [[ ! -d "$BUDIBASE_DIR" ]]; then
  log "[INFO] Budibase directory not found on this host ($BUDIBASE_DIR) – skipping Budibase backup"
  exit 0
fi

cd "$BUDIBASE_DIR"

if [[ ! -f "$BUDIBASE_ENV_FILE" ]]; then
  log "[INFO] Budibase env file not found on this host ($BUDIBASE_DIR/$BUDIBASE_ENV_FILE) – skipping Budibase backup"
  exit 0
fi

# If the Budibase Docker stack is not running, skip backup
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
  log "[INFO] Budibase Docker stack is not running in $BUDIBASE_DIR – skipping Budibase backup"
  exit 0
fi

log "[INFO] Budibase backup started"

# Log and verify budi version as the non-root user using explicit node/budi paths
if ! su - "$RUN_USER" -c "$NODE_BIN $BUDI_BIN --version" >>"$LOGFILE" 2>&1; then
  error "budi --version failed for user $RUN_USER using $NODE_BIN $BUDI_BIN"
  exit 1
fi

# Build target backup filename in central backup folder
TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
BACKUP_FILE="$BUDIBASE_BACKUP_DIR/budibase_${TIMESTAMP}.tar.gz"

# Run Budibase backup as RUN_USER with explicit node/budi paths; on failure, log and echo error, then exit non‑zero
if ! su - "$RUN_USER" -c "cd '$BUDIBASE_DIR' && $NODE_BIN $BUDI_BIN backups --export --env '$BUDIBASE_ENV_FILE'"; then
  error "Budibase backup command failed as user $RUN_USER ($NODE_BIN $BUDI_BIN backups --export --env $BUDIBASE_ENV_FILE)"
  exit 1
fi

# Find the newest .tar.gz produced by budi in the Budibase directory
NEW_TAR="$(ls -1t ./*.tar.gz 2>/dev/null | head -n1 || true)"

if [[ -z "$NEW_TAR" ]]; then
  error "Budibase backup finished but no .tar.gz file was found to move"
  exit 1
fi

if ! mv "$NEW_TAR" "$BACKUP_FILE"; then
  error "Failed to move Budibase backup archive '$NEW_TAR' to '$BACKUP_FILE'"
  exit 1
fi

# On success we only log, do not echo
log "[INFO] Budibase backup completed successfully: $BACKUP_FILE"
log "[INFO] Budibase backup ended"
