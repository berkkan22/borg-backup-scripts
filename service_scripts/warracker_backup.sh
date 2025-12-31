#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ -f "$ROOT_DIR/.env" ]]; then
	# shellcheck disable=SC1090
	source "$ROOT_DIR/.env"
fi

LOGFILE="${LOGFILE:-$ROOT_DIR/log/backup.log}"
mkdir -p "$(dirname "$LOGFILE")"

log() {
	printf '%s [WARRACKER] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[WARRACKER] [ERROR] $*" >&2
}

WARRACKER_DIR="${WARRACKER_DIR:-/home/berkkan/docker-services/warracker}"
WARRACKER_DB_CONTAINER="${WARRACKER_DB_CONTAINER:-warracker-warrackerdb-1}"

WARRACKER_DB_BACKUP_DIR="${WARRACKER_DB_BACKUP_DIR:-$ROOT_DIR/backups/warracker-db}"
mkdir -p "$WARRACKER_DB_BACKUP_DIR"

if [[ ! -d "$WARRACKER_DIR" ]]; then
	log "[INFO] Warracker directory not found on this host ($WARRACKER_DIR) – skipping Warracker backup"
	exit 0
fi

cd "$WARRACKER_DIR"

# If the Warracker stack is not running, skip backup
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] Warracker Docker stack is not running in $WARRACKER_DIR – skipping Warracker backup"
	exit 0
fi

log "[INFO] Warracker backup started"

# Use a constant dump filename; Borg keeps history, so we avoid
# creating a new dated dump file on every run.
DUMP_FILE="$WARRACKER_DB_BACKUP_DIR/warracker-db.sql.gz"

if ! docker exec "$WARRACKER_DB_CONTAINER" \
	sh -c 'DB_NAME="${POSTGRES_DB:-$POSTGRES_USER}"; pg_dump -U "$POSTGRES_USER" "$DB_NAME" | gzip -c' \
	>"$DUMP_FILE"; then
	error "Failed to create Warracker DB dump from container $WARRACKER_DB_CONTAINER"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

if [[ ! -s "$DUMP_FILE" ]]; then
	error "Warracker DB dump file is empty: $DUMP_FILE"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

log "[INFO] Warracker DB dump created at $DUMP_FILE"
log "[INFO] Warracker backup ended"
