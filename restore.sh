#!/bin/bash

# CONFIGURATION
VOLUMES=("comixed_data" "grafana_data" "jira_jira_data")
STACK_NAMES=("comixed" "grafana" "jira")
HEALTH_URLS=(
  "http://localhost:7171"
  "http://localhost:3000"
  "http://localhost:8080"
)
BACKUP_DIR="/mnt/nas_backups"
STACK_DIR="/opt/stacks"
LOG_FILE="/var/log/docker_restore_$(date +%Y%m%d_%H%M%S).log"
MAX_RETRIES=20
SLEEP_INTERVAL=10

exec > >(tee -a "$LOG_FILE") 2>&1

echo "🕒 Starting Docker volume restore at $(date)"

for i in "${!VOLUMES[@]}"; do
  VOL="${VOLUMES[$i]}"
  STACK="${STACK_NAMES[$i]}"
  HEALTH="${HEALTH_URLS[$i]}"
  VOL_PATH="/var/lib/docker/volumes/${VOL}/_data"
  ARCHIVE="${BACKUP_DIR}/${VOL}_backup.tar.gz"
  STACK_FILE="${STACK_DIR}/${STACK}-stack.yml"

  echo "📁 Checking backup archive for $VOL..."
  if [ ! -f "$ARCHIVE" ]; then
    echo "❌ Backup archive missing: $ARCHIVE"
    continue
  fi

  echo "🔧 Ensuring volume exists..."
  if [ ! -d "$VOL_PATH" ]; then
    docker volume create "$VOL"
    mkdir -p "$VOL_PATH"
  fi

  echo "🧼 Cleaning volume $VOL..."
  rm -rf "${VOL_PATH:?}"/*

  echo "📦 Restoring $VOL from $ARCHIVE..."
  tar -xzf "$ARCHIVE" -C "$VOL_PATH"

  echo "🚀 Redeploying stack: $STACK"
  docker rm -f "$STACK" 2>/dev/null
  docker stack deploy -c "$STACK_FILE" "$STACK"

  echo "⏳ Waiting for $STACK to become healthy..."
  for ((j=1; j<=MAX_RETRIES; j++)); do
    sleep "$SLEEP_INTERVAL"
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$HEALTH")
    if [ "$STATUS" -eq 200 ]; then
      echo "✅ $STACK is healthy at $HEALTH"
      break
    else
      echo "⏳ Attempt $j/$MAX_RETRIES: $STACK not ready (HTTP $STATUS)"
    fi
  done

  if [ "$STATUS" -ne 200 ]; then
    echo "❌ $STACK failed healthcheck after $((MAX_RETRIES * SLEEP_INTERVAL)) seconds"
  fi
done

echo "🎉 Restore complete. Logs saved to $LOG_FILE"
