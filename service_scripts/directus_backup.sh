#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional: load shared env from main backup dir
if [[ -f "$ROOT_DIR/.env" ]]; then
	# shellcheck disable=SC1090
	source "$ROOT_DIR/.env"
fi

# Use central backup log (same as other service scripts) but with Directus prefix
LOGFILE="${LOGFILE:-$ROOT_DIR/log/backup.log}"
mkdir -p "$(dirname "$LOGFILE")"

log() {
	printf '%s [DIRECTUS] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[DIRECTUS] [ERROR] $*" >&2
}

# Config (override via .env if needed)
DIRECTUS_DIR="${DIRECTUS_DIR:-/home/berkkan/docker-services/directus}"
DIRECTUS_DB_CONTAINER="${DIRECTUS_DB_CONTAINER:-directus-database-1}"

# Where to store DB dumps so Borg can back them up
DIRECTUS_DB_BACKUP_DIR="${DIRECTUS_DB_BACKUP_DIR:-$ROOT_DIR/backups/directus-db}"
mkdir -p "$DIRECTUS_DB_BACKUP_DIR"

if [[ ! -d "$DIRECTUS_DIR" ]]; then
	log "[INFO] Directus directory not found on this host ($DIRECTUS_DIR) – skipping Directus backup"
	exit 0
fi

cd "$DIRECTUS_DIR"

# Check that the Directus Docker stack is running; if not, skip
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] Directus Docker stack is not running in $DIRECTUS_DIR – skipping Directus backup"
	exit 0
fi

log "[INFO] Directus backup started"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
DUMP_FILE="$DIRECTUS_DB_BACKUP_DIR/directus-db_${TIMESTAMP}.sql.gz"

# Use POSTGRES_USER/POSTGRES_DB from the container environment
if ! docker exec "$DIRECTUS_DB_CONTAINER" \
	sh -c 'DB_NAME="${POSTGRES_DB:-$POSTGRES_USER}"; pg_dump -U "$POSTGRES_USER" "$DB_NAME" | gzip -c' \
	>"$DUMP_FILE"; then
	error "Failed to create Directus DB dump from container $DIRECTUS_DB_CONTAINER"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

if [[ ! -s "$DUMP_FILE" ]]; then
	error "Directus DB dump file is empty: $DUMP_FILE"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

log "[INFO] Directus DB dump created at $DUMP_FILE"
log "[INFO] Directus backup ended"
