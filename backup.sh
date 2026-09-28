#!/usr/bin/env bash
# backup.sh — compatibility wrapper around bin/dm-backup.
#
# Kept so existing cron / Portainer jobs keep working. New setups should call dm-backup directly
# (see README) and select volumes with the container label docker-maint.backup=true instead of
# the list below.
set -euo pipefail

# CONFIGURATION (leave VOLUMES empty to use labels: docker-maint.backup=true)
VOLUMES=("comixed_data" "grafana_data" "jira_jira_data")
BACKUP_DIR="${BACKUP_DIR:-/mnt/nas_backups}"
KEEP="${KEEP:-7}"
LOG_FILE="${LOG_FILE:-/var/log/docker_backup_$(date +%Y%m%d_%H%M%S).log}"

DM="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/bin/dm-backup"
[[ -x "$DM" ]] || { echo "dm-backup not found at $DM — deploy the whole docker-maint repo" >&2; exit 1; }

if (( ${#VOLUMES[@]} )); then set -- "${VOLUMES[@]}"; else set -- --label; fi
exec "$DM" --dest "$BACKUP_DIR" --keep "$KEEP" --log "$LOG_FILE" "$@"
