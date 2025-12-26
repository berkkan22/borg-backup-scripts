#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Optional: load shared env from main backup dir
if [[ -f "$ROOT_DIR/.env" ]]; then
	# shellcheck disable=SC1090
	source "$ROOT_DIR/.env"
fi

# Use central backup log (same as other service scripts) but with Nextcloud prefix
LOGFILE="${LOGFILE:-$ROOT_DIR/log/backup.log}"
mkdir -p "$(dirname "$LOGFILE")"

log() {
	printf '%s [NEXTCLOUD] %s\n' "$(date -Is)" "$*" >>"$LOGFILE"
}

error() {
	log "[ERROR] $*"
	echo "[NEXTCLOUD] [ERROR] $*" >&2
}

# Config (override via .env if needed)
NEXTCLOUD_DIR="${NEXTCLOUD_DIR:-/home/berkkan/docker-services/nextcloud}"
NEXTCLOUD_CONTAINER="${NEXTCLOUD_CONTAINER:-nextcloud-app-1}"
NEXTCLOUD_DB_CONTAINER="${NEXTCLOUD_DB_CONTAINER:-nextcloud-db-1}"
NEXTCLOUD_DB_USER="${NEXTCLOUD_DB_USER:-nextcloud}"
NEXTCLOUD_DB_PASSWORD="${NEXTCLOUD_DB_PASSWORD:-changeme}"
NEXTCLOUD_DB_NAME="${NEXTCLOUD_DB_NAME:-nextcloud}"

# Where to store DB dumps so Borg can back them up
NEXTCLOUD_DB_DUMP_DIR="${NEXTCLOUD_DB_DUMP_DIR:-$ROOT_DIR/backups/nextcloud-db}"
mkdir -p "$NEXTCLOUD_DB_DUMP_DIR"

if [[ ! -d "$NEXTCLOUD_DIR" ]]; then
	log "[INFO] Nextcloud directory not found on this host ($NEXTCLOUD_DIR) – skipping Nextcloud backup"
	exit 0
fi

require_var() {
	local name="$1"
	if [[ -z "${!name:-}" ]]; then
		error "Required variable $name is not set"
		exit 1
	fi
}

require_var NEXTCLOUD_CONTAINER
require_var NEXTCLOUD_DB_CONTAINER
require_var NEXTCLOUD_DB_USER
require_var NEXTCLOUD_DB_PASSWORD
require_var NEXTCLOUD_DB_NAME

enable_maintenance() {
	# In the official Nextcloud image, occ is a PHP script at /var/www/html/occ.
	# Run it as the web server user (www-data) via php.
	if ! docker exec "$NEXTCLOUD_CONTAINER" php /var/www/html/occ maintenance:mode --on >>"$LOGFILE" 2>&1; then
		error "Failed to enable Nextcloud maintenance mode on container $NEXTCLOUD_CONTAINER"
		exit 1
	fi
	log "[INFO] Nextcloud maintenance mode ENABLED"
}

disable_maintenance() {
	if ! docker exec "$NEXTCLOUD_CONTAINER" php /var/www/html/occ maintenance:mode --off >>"$LOGFILE" 2>&1; then
		error "Failed to disable Nextcloud maintenance mode on container $NEXTCLOUD_CONTAINER"
		exit 1
	fi
	log "[INFO] Nextcloud maintenance mode DISABLED"
}

dump_database() {
	local timestamp dump_file
	timestamp="$(date +%Y-%m-%d_%H-%M-%S)"
	dump_file="$NEXTCLOUD_DB_DUMP_DIR/nextcloud-db_${timestamp}.sql.gz"

	if ! docker exec "$NEXTCLOUD_DB_CONTAINER" \
		sh -c "mysqldump -u'$NEXTCLOUD_DB_USER' -p'$NEXTCLOUD_DB_PASSWORD' '$NEXTCLOUD_DB_NAME' | gzip -c" \
		>"$dump_file"; then
		error "Failed to create Nextcloud DB dump from container $NEXTCLOUD_DB_CONTAINER"
		rm -f "$dump_file" || true
		exit 1
	fi

	if [[ ! -s "$dump_file" ]]; then
		error "Nextcloud DB dump file is empty: $dump_file"
		rm -f "$dump_file" || true
		exit 1
	fi

	log "[INFO] Nextcloud DB dump created at $dump_file"
}

usage() {
	echo "Usage: $(basename "$0") {pre|post}" >&2
	echo "  pre  - enable maintenance mode and dump DB" >&2
	echo "  post - disable maintenance mode" >&2
}

main() {
	local action
	action="${1:-pre}"

	case "$action" in
	pre)
		log "[INFO] Nextcloud pre-backup: enabling maintenance and dumping DB"
		enable_maintenance
		dump_database
		log "[INFO] Nextcloud pre-backup completed"
		;;
	post)
		log "[INFO] Nextcloud post-backup: disabling maintenance"
		disable_maintenance
		log "[INFO] Nextcloud post-backup completed"
		;;
	*)
		usage
		return 1
		;;
	esac
}

main "$@"
