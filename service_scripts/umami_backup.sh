#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional: load shared env from main backup dir
if [[ -f "$ROOT_DIR/.env" ]]; then
	# shellcheck disable=SC1090
	source "$ROOT_DIR/.env"
fi

LOGFILE="${LOGFILE:-$ROOT_DIR/log/backup.log}"
mkdir -p "$(dirname "$LOGFILE")"

log() {
	printf '%s [UMAMI] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[UMAMI] [ERROR] $*" >&2
}

UMAMI_DIR="${UMAMI_DIR:-/home/berkkan/docker-services/umami}"
UMAMI_DB_CONTAINER="${UMAMI_DB_CONTAINER:-umami-db-1}"

UMAMI_DB_BACKUP_DIR="${UMAMI_DB_BACKUP_DIR:-$ROOT_DIR/backups/umami-db}"
mkdir -p "$UMAMI_DB_BACKUP_DIR"

if [[ ! -d "$UMAMI_DIR" ]]; then
	log "[INFO] Umami directory not found on this host ($UMAMI_DIR) – skipping Umami backup"
	exit 0
fi

cd "$UMAMI_DIR"

# If the Umami stack is not running, skip backup
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] Umami Docker stack is not running in $UMAMI_DIR – skipping Umami backup"
	exit 0
fi

log "[INFO] Umami backup started"

# Use a constant dump filename; Borg keeps history, so we avoid
# creating a new dated dump file on every run.
DUMP_FILE="$UMAMI_DB_BACKUP_DIR/umami-db.sql.gz"

if ! docker exec "$UMAMI_DB_CONTAINER" \
	sh -c 'DB_NAME="${POSTGRES_DB:-$POSTGRES_USER}"; pg_dump -U "$POSTGRES_USER" "$DB_NAME" | gzip -c' \
	>"$DUMP_FILE"; then
	error "Failed to create Umami DB dump from container $UMAMI_DB_CONTAINER"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

if [[ ! -s "$DUMP_FILE" ]]; then
	error "Umami DB dump file is empty: $DUMP_FILE"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

log "[INFO] Umami DB dump created at $DUMP_FILE"
log "[INFO] Umami backup ended"
