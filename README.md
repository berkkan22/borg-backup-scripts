# Borg Backup Scripts

Short, practical overview of this backup setup.

---

## What This Does

- Creates Borg backups from this server to your Raspberry Pi.
- Dumps databases / data for several Docker services before Borg runs.
- Handles Nextcloud maintenance mode (on before backup, off after).
- Prunes old archives with a sensible retention policy.

Main script: [borg_backup_scripts/main.sh](borg_backup_scripts/main.sh)
Service scripts: [borg_backup_scripts/service_scripts](borg_backup_scripts/service_scripts)
Config: [borg_backup_scripts/.env](borg_backup_scripts/.env)
Logs: [borg_backup_scripts/log](borg_backup_scripts/log)

---

## Backup Flow (High-Level)

1. Load config and ensure log dir exists.
2. (If present) run Nextcloud pre-backup: enable maintenance + DB dump.
3. Run all other service backup scripts (Authentik, Budibase, etc.).
4. Run `borg create` for important paths on this host.
5. Run `borg prune` to clean up old archives.
6. Always run Nextcloud post-backup: disable maintenance.

If anything fails, the script logs the error and stops.

---

## Files & Structure

- [borg_backup_scripts/main.sh](borg_backup_scripts/main.sh)
  - Orchestrates everything; main entry point.
- [borg_backup_scripts/.env](borg_backup_scripts/.env)
  - Holds container names, backup dirs, DB credentials, `BORG_PASSPHRASE`.
  - Create it by copying [borg_backup_scripts/example.env](borg_backup_scripts/example.env) and adjusting all paths, passwords and container names.
- [borg_backup_scripts/example.env](borg_backup_scripts/example.env)
  - Template with example values; **do not** use in production without editing.
- [borg_backup_scripts/service_scripts](borg_backup_scripts/service_scripts)
  - One script per service (Authentik, Budibase, CouchDB, DBMS, Directus, Mealie, Nextcloud, Paperless, Umami, Warracker).
  - Each script should be executable and able to run standalone.
- [borg_backup_scripts/log/backup.log](borg_backup_scripts/log/backup.log)
  - Combined log from the backup script and Borg/prune output.

---

## What Gets Backed Up

Inside [borg_backup_scripts/main.sh](borg_backup_scripts/main.sh), `run_borg` runs roughly:

- `borg create --compression zlib --stats --progress ...` on:
  - `/home/berkkan/borg_backup_scripts` (this project)
  - `/home/berkkan`
  - `/root`
  - `/etc`
  - `/var/spool/cron`
  - `/var/lib/docker/volumes`
  - `/opt/`
  - `/home/github_action`

Key excludes (not in backup):

- `/home/berkkan/.cache`
- `/home/berkkan/.zcompdump*`
- `/home/berkkan/*.swp`
- `/home/berkkan/.sudo_as_admin_successful`
- `/home/berkkan/.npm`
- `/home/berkkan/.dotnet`
- `/home/berkkan/docker-services/nginx-proxy-manager/data.backup/logs`
- `/home/berkkan/new_video_converter`

**If you add/remove paths**, edit `run_borg` in [borg_backup_scripts/main.sh](borg_backup_scripts/main.sh).

---

## Borg Repository & SSH

Defined at the top of [borg_backup_scripts/main.sh](borg_backup_scripts/main.sh):

- `PI_USERNAME` / `PI_IP`
- `BORG_REPO` (path on the Pi, e.g. `/mnt/hdd/backups/24fire_private_server_repo`)
- `BORG_RSH` with SSH key and port
- `REPO_URL` built as `ssh://$PI_USERNAME@localhost:2222$BORG_REPO`

**You must:**

1. Have SSH key-based login working from this server to the Pi.
2. Have the Borg repo created on the Pi, for example:
   - `ssh pi@PI_IP 'borg init --encryption=repokey /mnt/hdd/backups/24fire_private_server_repo'`
3. Ensure `BORG_PASSPHRASE` is set (in `.env` or environment) and matches the repo.

The script checks the repo with `borg list` before running.

---

## Retention Policy (Pruning)

Prune command in [borg_backup_scripts/main.sh](borg_backup_scripts/main.sh):

- `borg prune --keep-daily=7 --keep-weekly=4 --keep-monthly=6 --keep-yearly=1` on the repo.

Meaning:

- Keep up to 7 daily backups (1 per day).
- Keep up to 4 weekly backups (1 per week).
- Keep up to 6 monthly backups (1 per month).
- Keep 1 yearly backup (1 per year).

Everything older that is not needed to satisfy these rules will be deleted.

If you want to change history length, adjust the numbers here.

---

## Logs & Troubleshooting

- Main log: [borg_backup_scripts/log/backup.log](borg_backup_scripts/log/backup.log)
  - Contains timestamps, service script output, Borg stats, prune output.
- All `log` messages go there (and to stderr).
- Borg output is piped via `tee -a` so you see it in console and in the log.

If a backup fails:

1. Check `backup.log` around the failure time.
2. Look for which service script or Borg command failed.
3. Run the failing service script by hand to debug.

Optional: you can also redirect cron output to a small separate `cron.log` if you want to capture top-level cron errors.

---

## Running Manually

From this directory:

```bash
/usr/bin/bash main.sh
```

Requirements:

- `borg` installed on this machine.
- SSH to the Pi working with the configured key.
- Docker services running for the service scripts that need them.

---

## Cron Setup (Daily Backup)

Example root crontab entry (daily at 01:03, with lock to avoid overlaps):

```cron
3 1 * * * flock -n /var/lock/borg_backup.lock /usr/bin/bash /home/berkkan/borg_backup_scripts/main.sh >> /home/berkkan/borg_backup_scripts/log/cron.log 2>&1
```

- `flock -n /var/lock/borg_backup.lock` ensures only one backup runs at a time.
- Output from cron (including unexpected errors) goes to `cron.log`.
- Inside the script, detailed logs go to `backup.log`.

Edit root crontab:

```bash
sudo crontab -e
```

Then paste the line above (adjust time/path if needed).

---

## Service Scripts

Folder: [borg_backup_scripts/service_scripts](borg_backup_scripts/service_scripts)

- Each `*_backup.sh` is responsible for its own DB dumps / file copies.
- `main.sh` runs them all (except Nextcloud which is handled specially with `pre`/`post`).
- Configuration (paths, container names, credentials) lives in [borg_backup_scripts/.env](borg_backup_scripts/.env).

When adding/changing a service script:

1. Make the script executable: `chmod +x service_scripts/your_service_backup.sh`.
2. Source `.env` inside the script if it needs those variables.
3. Test it alone before running the full backup.

---

## Things to Double-Check

Before relying on this in production:

- SSH key & port in `BORG_RSH` are correct and working.
- Borg repo exists on the Pi and `borg list` works.
- `.env` values (container names, DB names/passwords, backup dirs) are correct.
- Nextcloud maintenance mode on/off works via `nextcloud_backup.sh`.
- Enough free space on the backup disk for your expected data size.

Once these are OK, the daily cron job should run with minimal manual work.