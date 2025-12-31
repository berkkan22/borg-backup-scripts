#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional: load shared env from main backup dir
if [[ -f "$ROOT_DIR/.env" ]]; then
	# shellcheck disable=SC1090
	source "$ROOT_DIR/.env"
fi

# Use central backup log (same as main script) but with Paperless prefix
LOGFILE="${LOGFILE:-$ROOT_DIR/log/backup.log}"
mkdir -p "$(dirname "$LOGFILE")"

log() {
	printf '%s [PAPERLESS] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[PAPERLESS] [ERROR] $*" >&2
}

# Config (override via env if needed)
PAPERLESS_DIR="${PAPERLESS_DIR:-/home/berkkan/docker-services/paperless}"
PAPERLESS_DB_CONTAINER="${PAPERLESS_DB_CONTAINER:-paperless-db-1}"
PAPERLESS_WEBSERVER_CONTAINER="${PAPERLESS_WEBSERVER_CONTAINER:-paperless-webserver-1}"
PAPERLESS_DB_USER="${PAPERLESS_DB_USER:-paperless}"
PAPERLESS_DB_NAME="${PAPERLESS_DB_NAME:-paperless}"

# Where to store DB dumps and exported docs so Borg can back them up
PAPERLESS_BACKUP_DIR="${PAPERLESS_BACKUP_DIR:-$PAPERLESS_DIR/database_backups}"
mkdir -p "$PAPERLESS_BACKUP_DIR"

if [[ ! -d "$PAPERLESS_DIR" ]]; then
	log "[INFO] Paperless directory not found on this host ($PAPERLESS_DIR) – skipping Paperless backup"
	exit 0
fi

cd "$PAPERLESS_DIR"

# Check that the Paperless Docker stack is running; if not, skip
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] Paperless Docker stack is not running in $PAPERLESS_DIR – skipping Paperless backup"
	exit 0
fi

log "[INFO] Paperless backup started"

# 1) Create PostgreSQL dump from DB container. Use a constant dump
# filename; Borg keeps history, so we avoid creating a new dated
# dump file on every run.
DUMP_FILE="$PAPERLESS_BACKUP_DIR/paperless-db.sql.gz"

if ! docker exec "$PAPERLESS_DB_CONTAINER" \
	sh -c "pg_dump -U '$PAPERLESS_DB_USER' '$PAPERLESS_DB_NAME' | gzip -c" \
	>"$DUMP_FILE"; then
	error "Failed to create Paperless DB dump from container $PAPERLESS_DB_CONTAINER"
	exit 1
fi

if [[ ! -s "$DUMP_FILE" ]]; then
	error "Paperless DB dump file is empty: $DUMP_FILE"
	rm -f "$DUMP_FILE"
	exit 1
fi

log "[INFO] Paperless DB dump created at $DUMP_FILE"

# 2) Export Paperless documents using document_exporter in webserver container
EXPORT_DIR="$PAPERLESS_DIR/export"

if ! docker compose exec -T "$PAPERLESS_WEBSERVER_CONTAINER" document_exporter ../export >>"$LOGFILE" 2>&1; then
	error "document_exporter failed in container $PAPERLESS_WEBSERVER_CONTAINER"
	exit 1
fi

if [[ ! -d "$EXPORT_DIR" ]]; then
	error "Expected export directory not found after document_exporter: $EXPORT_DIR"
	exit 1
fi

log "[INFO] Paperless documents exported/updated in $EXPORT_DIR"
log "[INFO] Paperless backup ended"
