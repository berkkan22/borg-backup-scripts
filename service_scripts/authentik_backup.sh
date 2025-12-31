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
	printf '%s [AUTHENTIK] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[AUTHENTIK] [ERROR] $*" >&2
}

AUTHENTIK_DIR="${AUTHENTIK_DIR:-/home/berkkan/docker-services/authentik}"
AUTHENTIK_DB_CONTAINER="${AUTHENTIK_DB_CONTAINER:-authentik-postgresql}"

AUTHENTIK_DB_BACKUP_DIR="${AUTHENTIK_DB_BACKUP_DIR:-$ROOT_DIR/backups/authentik-db}"
mkdir -p "$AUTHENTIK_DB_BACKUP_DIR"

if [[ ! -d "$AUTHENTIK_DIR" ]]; then
	log "[INFO] Authentik directory not found on this host ($AUTHENTIK_DIR) – skipping Authentik backup"
	exit 0
fi

cd "$AUTHENTIK_DIR"

# If the Authentik stack is not running, skip backup
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] Authentik Docker stack is not running in $AUTHENTIK_DIR – skipping Authentik backup"
	exit 0
fi

log "[INFO] Authentik backup started"

# Use a constant dump filename; Borg keeps history, so we avoid
# creating a new dated dump file on every run.
DUMP_FILE="$AUTHENTIK_DB_BACKUP_DIR/authentik-db.sql.gz"

if ! docker exec "$AUTHENTIK_DB_CONTAINER" \
	sh -c 'DB_NAME="${POSTGRES_DB:-$POSTGRES_USER}"; pg_dump -U "$POSTGRES_USER" "$DB_NAME" | gzip -c' \
	>"$DUMP_FILE"; then
	error "Failed to create Authentik DB dump from container $AUTHENTIK_DB_CONTAINER"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

if [[ ! -s "$DUMP_FILE" ]]; then
	error "Authentik DB dump file is empty: $DUMP_FILE"
	rm -f "$DUMP_FILE" || true
	exit 1
fi

log "[INFO] Authentik DB dump created at $DUMP_FILE"
log "[INFO] Authentik backup ended"
