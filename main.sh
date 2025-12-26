#!/usr/bin/bash

set -euo pipefail

# Load environment variables (including BORG_PASSPHRASE) from .env if present
ENV_FILE="$(dirname "$0")/.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -a
  . "$ENV_FILE"
  set +a
fi

# ---- config ----
PI_USERNAME="pi"
PI_IP="localhost"
BORG_REPO="/mnt/hdd/backups/24fire_private_server_repo" # change
# BORG_PASSPHRASE="change-me" # or use env / keyfile
LOGFILE="/home/berkkan/borg_backup_scripts/log/backup.log"
SERVICE_DIR="./service_scripts"
NEXTCLOUD_SCRIPT="${SERVICE_DIR}/nextcloud_backup.sh"

HOSTNAME="$(hostname -s)"
USER="$(echo "$USER")"
BACKUP_TIMESTAMP="$(date +%Y-%m-%d_%H-%M-%S)"
ARCHIVE="${HOSTNAME}-privat_server-${BACKUP_TIMESTAMP}"

export BORG_RSH="ssh -i /home/berkkan/.ssh/id_ed25519 -p 2222 -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o TCPKeepAlive=yes"
# Borg repo URL (used for create/prune)
REPO_URL="ssh://${PI_USERNAME}@localhost:2222${BORG_REPO}"
export BORG_PASSPHRASE="${BORG_PASSPHRASE-}"

# Ensure log directory exists
LOGDIR="$(dirname "$LOGFILE")"
mkdir -p "$LOGDIR"

log() {
  printf '%s %s\n' "$(date -Is)" "$*" | tee -a "$LOGFILE" >&2
}

notify() {
  # Replace with mail/Slack/etc.
  log "NOTIFY: $*"
}

ensure_repo() {
  # Check if Borg repo exists; if not, create it
  if borg list "$REPO_URL" >/dev/null 2>&1; then
    log "Borg repo exists: $REPO_URL"
  else
    log "ERROR: Borg repo not found: $REPO_URL"
    log "Please create it once with this command (on the backup server):"
    log "  borg init --encryption=repokey \"$BORG_REPO\""
    echo
    echo "Borg repository does not exist yet."
    echo "Create it on the Raspberry Pi with:" >&2
    echo "  ssh ${PI_USERNAME}@${PI_IP} 'borg init --encryption=repokey \"$BORG_REPO\"'" >&2
    exit 1
  fi
}

run_services() {
  for script in "${SERVICE_DIR}"/*.sh; do
    [ -x "$script" ] || continue
    # Nextcloud is handled specially (pre/post) in main()
    if [[ "$(basename "$script")" == "nextcloud_backup.sh" ]]; then
      continue
    fi
    log "Running service script: $(basename "$script")"
    if ! "$script"; then
      log "ERROR: service script failed: $(basename "$script")"
      notify "Backup FAILED in $(basename "$script")"
      return 1
    fi
  done
}

run_borg() {
  ensure_repo
  log "Creating Borg archive: ${ARCHIVE}"
  borg create --compression zlib --stats --progress \
    "${REPO_URL}::${ARCHIVE}" \
    /home/berkkan/borg_backup_scripts \
    /home/berkkan \
    /root \
    /etc \
    /var/spool/cron \
    /var/lib/docker/volumes \
    /opt/ \
    /home/github_action \
    --exclude '/home/berkkan/.cache' \
    --exclude '/home/berkkan/.zcompdump*' \
    --exclude '/home/berkkan/*.swp' \
    --exclude '/home/berkkan/.sudo_as_admin_successful' \
    --exclude '/home/berkkan/.npm' \
    --exclude '/home/berkkan/.dotnet' \
    --exclude '/home/berkkan/docker-services/nginx-proxy-manager/data.backup/logs' \
    --exclude '/home/berkkan/new_video_converter' \
    2>&1 | tee -a "$LOGFILE"

  # Optional retention: remove older archives for this host/purpose only
  log "Pruning old Borg backups..."
  borg prune \
     --keep-daily=7 --keep-weekly=4 --keep-monthly=6 --keep-yearly=1 \
    "$REPO_URL" \
    2>&1 | tee -a "$LOGFILE"

  log "Borg backup finished: ${ARCHIVE}"
  notify "Backup SUCCESS: ${ARCHIVE}"
}

main() {
  log "===== BACKUP START ${BACKUP_TIMESTAMP} ====="

  # Track whether Nextcloud maintenance was enabled successfully
  nextcloud_pre_ok=0

  # Run Nextcloud pre-backup (enable maintenance + DB dump) if script exists
  if [[ -x "$NEXTCLOUD_SCRIPT" ]]; then
    log "Running Nextcloud pre-backup script (maintenance ON + DB dump)..."
    if "$NEXTCLOUD_SCRIPT" pre >>"$LOGFILE" 2>&1; then
      nextcloud_pre_ok=1
    else
      log "ERROR: Nextcloud pre-backup failed"
      notify "Backup FAILED in nextcloud pre-backup"
      log "===== BACKUP END ${BACKUP_TIMESTAMP} (FAILED before Borg) ====="
      exit 1
    fi
  fi

  # Ensure maintenance mode is turned off after Borg (or on any failure)
  trap 'if [[ ${nextcloud_pre_ok:-0} -eq 1 ]] && [[ -x "'$NEXTCLOUD_SCRIPT'" ]]; then \
          log "Running Nextcloud post-backup script (maintenance OFF)..."; \
          if ! "'$NEXTCLOUD_SCRIPT'" post >>"$LOGFILE" 2>&1; then \
            log "ERROR: Nextcloud post-backup (maintenance OFF) failed"; \
          fi; \
        fi' EXIT

  if ! run_services; then
    log "Backup aborted due to service error"
    exit 1
  fi

  run_borg
  log "===== BACKUP END ${BACKUP_TIMESTAMP} ====="
}

main "$@"
