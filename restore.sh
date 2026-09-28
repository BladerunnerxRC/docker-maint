#!/usr/bin/env bash
# restore.sh — compatibility wrapper around bin/dm-restore.
#
#   ./restore.sh                 restore every volume from the latest dm-backup run
#   ./restore.sh VOLUME...       restore only these volumes
#
# Legacy flat archives written by the old backup.sh (<volume>_backup.tar.gz) are still
# supported: when no dm-backup run exists they are restored one by one with --file.
# Containers using a volume are stopped, restored, restarted and health-checked by dm-restore.
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/mnt/nas_backups}"
LOG_FILE="${LOG_FILE:-/var/log/docker_restore_$(date +%Y%m%d_%H%M%S).log}"
TIMEOUT="${TIMEOUT:-200}"            # was MAX_RETRIES × SLEEP_INTERVAL

DM="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bin/dm-restore"
[[ -x "$DM" ]] || { echo "dm-restore not found at $DM — deploy the whole docker-maint repo" >&2; exit 1; }

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

if find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -regextype posix-extended \
     -regex '.*/[0-9]{8}-[0-9]{6}' 2>/dev/null | grep -q .; then
  "$DM" --dest "$BACKUP_DIR" --timeout "$TIMEOUT" --up "$@"
else
  shopt -s nullglob
  archives=("$BACKUP_DIR"/*_backup.tar.gz)
  (( ${#archives[@]} )) || { echo "No backups found in $BACKUP_DIR" >&2; exit 1; }
  rc=0
  for a in "${archives[@]}"; do
    vol=$(basename "$a" _backup.tar.gz)
    if (( $# )) && [[ " $* " != *" $vol "* ]]; then continue; fi
    "$DM" --file "$a" --volume "$vol" --timeout "$TIMEOUT" || rc=1
  done
  exit "$rc"
fi
