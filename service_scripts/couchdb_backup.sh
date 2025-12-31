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
	printf '%s [COUCHDB] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[COUCHDB] [ERROR] $*" >&2
}

COUCHDB_DIR="${COUCHDB_DIR:-/home/berkkan/docker-services/couchdb}"
COUCHDB_CONTAINER="${COUCHDB_CONTAINER:-obsidian-couchdb-sync}"

COUCHDB_BACKUP_DIR="${COUCHDB_BACKUP_DIR:-$ROOT_DIR/backups/couchdb}"
mkdir -p "$COUCHDB_BACKUP_DIR"

if [[ ! -d "$COUCHDB_DIR" ]]; then
	log "[INFO] CouchDB directory not found on this host ($COUCHDB_DIR) – skipping CouchDB backup"
	exit 0
fi

cd "$COUCHDB_DIR"

# If the CouchDB stack is not running, skip backup
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] CouchDB Docker stack is not running in $COUCHDB_DIR – skipping CouchDB backup"
	exit 0
fi

log "[INFO] CouchDB backup started"

# Use a constant backup filename so Borg handles history; avoid
# creating a new dated archive on every run.
BACKUP_FILE="$COUCHDB_BACKUP_DIR/couchdb_files.tar.gz"

# For CouchDB, the primary persistent state is in the data and config directories.
# We create a tar.gz archive of these directories. This is usually sufficient
# when combined with your Borg backup of the same folders/volumes.
if ! tar -czf "$BACKUP_FILE" -C "$COUCHDB_DIR" data config; then
	error "Failed to create CouchDB files backup archive at $BACKUP_FILE"
	rm -f "$BACKUP_FILE" || true
	exit 1
fi

if [[ ! -s "$BACKUP_FILE" ]]; then
	error "CouchDB backup archive is empty: $BACKUP_FILE"
	rm -f "$BACKUP_FILE" || true
	exit 1
fi

log "[INFO] CouchDB files backup created at $BACKUP_FILE"
log "[INFO] CouchDB backup ended"
