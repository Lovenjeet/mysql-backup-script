#!/usr/bin/env bash
#
# Daily MySQL backup -> Google Drive (via rclone)
#
# Usage: mysql_gdrive_backup.sh [/path/to/databases.json]
#
# Requirements (Ubuntu 18.04):
#   sudo apt install -y jq mysql-client gzip
#   curl https://rclone.org/install.sh | sudo bash
#   rclone config        # create a remote named "gdrive" (type: drive)
#
# MySQL credentials: put them in ~/.my.cnf of the user running this script
#   [client]
#   user=backup_user
#   password=secret
#   (chmod 600 ~/.my.cnf)
#
# databases.json format:
#   { "databases": ["db_one", "db_two"] }

set -o pipefail

# ---------- settings (override via environment) ----------
CONFIG_FILE="${1:-$(dirname "$(readlink -f "$0")")/databases.json}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/mysql}"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive}"             # name from `rclone config`
GDRIVE_FOLDER="${GDRIVE_FOLDER:-mysql-backups}"      # folder inside Google Drive
LOCAL_RETENTION_DAYS="${LOCAL_RETENTION_DAYS:-3}"     # only applies to files whose upload failed
REMOTE_RETENTION_DAYS="${REMOTE_RETENTION_DAYS:-30}"
LOG_FILE="${LOG_FILE:-/var/log/mysql_gdrive_backup.log}"
# ---------------------------------------------------------

DATE="$(date +%F_%H-%M-%S)"
FAILED=0

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }

# Prevent overlapping runs
exec 9>/tmp/mysql_gdrive_backup.lock
flock -n 9 || { log "Another backup is already running. Exiting."; exit 1; }

for cmd in jq mysqldump rclone gzip; do
  command -v "$cmd" >/dev/null 2>&1 || { log "ERROR: '$cmd' is not installed."; exit 1; }
done

[ -f "$CONFIG_FILE" ] || { log "ERROR: config file not found: $CONFIG_FILE"; exit 1; }

mapfile -t DATABASES < <(jq -r '.databases[]' "$CONFIG_FILE")
[ "${#DATABASES[@]}" -gt 0 ] || { log "ERROR: no databases listed in $CONFIG_FILE"; exit 1; }

mkdir -p "$BACKUP_DIR" || { log "ERROR: cannot create $BACKUP_DIR"; exit 1; }

log "Starting backup of ${#DATABASES[@]} database(s)"

for DB in "${DATABASES[@]}"; do
  FILE="$BACKUP_DIR/${DB}_${DATE}.sql.gz"
  log "Dumping '$DB' -> $FILE"

  ERR_FILE="$(mktemp)"
  if mysqldump --single-transaction --quick --no-tablespaces --routines --triggers --events "$DB" 2>"$ERR_FILE" | gzip > "$FILE"; then
    [ -s "$ERR_FILE" ] && log "mysqldump warning: $(cat "$ERR_FILE")"
    log "Uploading $(basename "$FILE") to ${RCLONE_REMOTE}:${GDRIVE_FOLDER}/${DB}/"
    if rclone copy "$FILE" "${RCLONE_REMOTE}:${GDRIVE_FOLDER}/${DB}/" >>"$LOG_FILE" 2>&1; then
      rm -f "$FILE"
      log "OK: $DB (uploaded, local copy deleted)"
    else
      log "ERROR: upload failed for $DB (local copy kept: $FILE)"; FAILED=1
    fi
  else
    log "ERROR: mysqldump failed for $DB: $(cat "$ERR_FILE")"; FAILED=1
    rm -f "$FILE"
  fi
  rm -f "$ERR_FILE"
done

# Cleanup old backups
find "$BACKUP_DIR" -name '*.sql.gz' -type f -mtime +"$LOCAL_RETENTION_DAYS" -delete
if rclone lsf "${RCLONE_REMOTE}:${GDRIVE_FOLDER}" >/dev/null 2>&1; then
  RCLONE_ERR="$(rclone delete "${RCLONE_REMOTE}:${GDRIVE_FOLDER}" --min-age "${REMOTE_RETENTION_DAYS}d" 2>&1)" \
    || log "WARN: remote cleanup failed: $RCLONE_ERR"
else
  log "WARN: cannot access ${RCLONE_REMOTE}:${GDRIVE_FOLDER} (folder missing or rclone remote not configured for user $(whoami))"
fi

if [ "$FAILED" -eq 0 ]; then
  log "Backup finished successfully"
else
  log "Backup finished WITH ERRORS"
fi
exit "$FAILED"
