#!/bin/bash

# CONFIGURATION
VOLUMES=("comixed_data" "grafana_data" "jira_jira_data")
BACKUP_DIR="/mnt/nas_backups"
LOG_FILE="/var/log/docker_backup_$(date +%Y%m%d_%H%M%S).log"

exec > >(tee -a "$LOG_FILE") 2>&1

echo "🕒 Starting Docker volume backup at $(date)"

for VOL in "${VOLUMES[@]}"; do
  VOL_PATH="/var/lib/docker/volumes/${VOL}/_data"
  ARCHIVE="${BACKUP_DIR}/${VOL}_backup.tar.gz"

  echo "📦 Backing up $VOL to $ARCHIVE"
  tar -czf "$ARCHIVE" -C "$VOL_PATH" .
done

echo "✅ Backup complete. Logs saved to $LOG_FILE"
