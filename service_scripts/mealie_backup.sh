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
	printf '%s [MEALIE] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[MEALIE] [ERROR] $*" >&2
}

MEALIE_DIR="${MEALIE_DIR:-/home/berkkan/docker-services/mealie}"
MEALIE_DB_CONTAINER="${MEALIE_DB_CONTAINER:-mealie_postgres}"

MEALIE_DB_BACKUP_DIR="${MEALIE_DB_BACKUP_DIR:-$ROOT_DIR/backups/mealie-db}"
mkdir -p "$MEALIE_DB_BACKUP_DIR"

if [[ ! -d "$MEALIE_DIR" ]]; then
	log "[INFO] Mealie directory not found on this host ($MEALIE_DIR) – skipping Mealie backup"
	exit 0
fi

cd "$MEALIE_DIR"

# If the Mealie stack is not running, skip backup
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] Mealie Docker stack is not running in $MEALIE_DIR – skipping Mealie backup"
	exit 0
fi

log "[INFO] Mealie backup started"

# Use a constant dump filename; Borg keeps history, so we avoid
# creating a new dated dump file on every run.
DUMP_FILE="$MEALIE_DB_BACKUP_DIR/mealie-db.sql.gz"

# Determine DB name from POSTGRES_DB or POSTGRES_USER
if ! docker exec "$MEALIE_DB_CONTAINER" \
	sh -c 'DB_NAME="${POSTGRES_DB:-$POSTGRES_USER}"; pg_dump -U "$POSTGRES_USER" "$DB_NAME" | gzip -c' \
	>"$DUMP_FILE"; then
	error "Failed to create Mealie DB dump from container $MEALIE_DB_CONTAINER"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

if [[ ! -s "$DUMP_FILE" ]]; then
	error "Mealie DB dump file is empty: $DUMP_FILE"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

log "[INFO] Mealie DB dump created at $DUMP_FILE"
log "[INFO] Mealie backup ended"
