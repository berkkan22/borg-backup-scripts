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
	printf '%s [DBMS] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[DBMS] [ERROR] $*" >&2
}

DBMS_DIR="${DBMS_DIR:-/home/berkkan/docker-services/dbms}"
DBMS_DB_CONTAINER="${DBMS_DB_CONTAINER:-dbms}"

DBMS_BACKUP_DIR="${DBMS_BACKUP_DIR:-$ROOT_DIR/backups/dbms-db}"
mkdir -p "$DBMS_BACKUP_DIR"

if [[ ! -d "$DBMS_DIR" ]]; then
	log "[INFO] DBMS directory not found on this host ($DBMS_DIR) – skipping DBMS backup"
	exit 0
fi

cd "$DBMS_DIR"

# If the DBMS stack is not running, skip backup
if ! docker compose ps --status=running --services 2>/dev/null | grep -q .; then
	log "[INFO] DBMS Docker stack is not running in $DBMS_DIR – skipping DBMS backup"
	exit 0
fi

log "[INFO] DBMS backup started"

TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
# Determine the Postgres superuser inside the container
POSTGRES_USER_IN_CONTAINER="$(docker exec "$DBMS_DB_CONTAINER" sh -c 'echo "$POSTGRES_USER"' 2>/dev/null || true)"

if [[ -z "$POSTGRES_USER_IN_CONTAINER" ]]; then
	error "Could not determine POSTGRES_USER inside container $DBMS_DB_CONTAINER"
	exit 1
fi

log "[INFO] DBMS detected Postgres user in container: $POSTGRES_USER_IN_CONTAINER"

# List all non-template databases and dump each one individually
DB_LIST="$(docker exec "$DBMS_DB_CONTAINER" psql -U "$POSTGRES_USER_IN_CONTAINER" -At -c "SELECT datname FROM pg_database WHERE datistemplate = false;" 2>/dev/null || true)"

if [[ -z "$DB_LIST" ]]; then
	error "No databases found to dump in container $DBMS_DB_CONTAINER"
	exit 1
fi

log "[INFO] DBMS will create individual dumps for databases: $DB_LIST"

for db in $DB_LIST; do
	PER_DB_FILE="$DBMS_BACKUP_DIR/dbms_${db}_${TIMESTAMP}.sql.gz"
	if ! docker exec "$DBMS_DB_CONTAINER" pg_dump -U "$POSTGRES_USER_IN_CONTAINER" "$db" | gzip -c >"$PER_DB_FILE"; then
		error "Failed to create DB dump for database '$db' from container $DBMS_DB_CONTAINER"
		rm -f "$PER_DB_FILE" || true
		exit 1
	fi

	if [[ ! -s "$PER_DB_FILE" ]]; then
		error "DBMS per-database dump file is empty for '$db': $PER_DB_FILE"
		rm -f "$PER_DB_FILE" || true
		exit 1
	fi

	log "[INFO] DBMS per-database dump created for '$db' at $PER_DB_FILE"
done

# Additionally, create a full cluster dump for disaster recovery
CLUSTER_DUMP_FILE="$DBMS_BACKUP_DIR/dbms-all_${TIMESTAMP}.sql.gz"

if ! docker exec "$DBMS_DB_CONTAINER" pg_dumpall -U "$POSTGRES_USER_IN_CONTAINER" | gzip -c >"$CLUSTER_DUMP_FILE"; then
	error "Failed to create DBMS cluster dump from container $DBMS_DB_CONTAINER"
	rm -f "$CLUSTER_DUMP_FILE" || true
	exit 1
fi

if [[ ! -s "$CLUSTER_DUMP_FILE" ]]; then
	error "DBMS cluster dump file is empty: $CLUSTER_DUMP_FILE"
	rm -f "$CLUSTER_DUMP_FILE" || true
	exit 1
fi

log "[INFO] DBMS cluster dump created at $CLUSTER_DUMP_FILE"
log "[INFO] DBMS backup ended"
