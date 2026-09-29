#!/bin/bash
# reboot-safe.sh — Safe reboot for optiplex-docker
#
#   1. DRAIN   — drain the Swarm node and gracefully stop standalone containers
#   2. REBOOT  — sync disks and reboot
#   3. RESTORE — on next boot a one-shot systemd unit re-activates the node,
#                restarts the containers that were running, and health-checks
#
# Usage:
#   sudo ./reboot-safe.sh              # drain + reboot (prompts for confirmation)
#   sudo ./reboot-safe.sh -y           # no prompt
#   sudo ./reboot-safe.sh --dry-run    # show what would happen
#   sudo ./reboot-safe.sh --no-reboot  # drain only (maintenance without reboot)
#   sudo ./reboot-safe.sh post         # run restore phase manually

set -uo pipefail

# CONFIGURATION
HEALTH_URLS=(
  "http://localhost:7171"   # comixed
  "http://localhost:3000"   # grafana
  "http://localhost:8080"   # jira
)
STOP_TIMEOUT=60           # seconds per container for graceful stop
DRAIN_TIMEOUT=180         # seconds to wait for swarm tasks to leave the node
CONVERGE_TIMEOUT=600      # seconds to wait after boot for services/health
BLOCKING_CONTAINERS=("backup-job")  # refuse to reboot while these run
STATE_DIR="/var/lib/reboot-safe"
LOG_FILE="/var/log/reboot-safe.log"
UNIT_NAME="reboot-safe-post.service"
UNIT_FILE="/etc/systemd/system/${UNIT_NAME}"
SCRIPT_PATH="$(readlink -f "$0")"

ASSUME_YES=0
DRY_RUN=0
DO_REBOOT=1
PHASE="pre"

for arg in "$@"; do
  case "$arg" in
    -y|--yes)    ASSUME_YES=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --no-reboot) DO_REBOOT=0 ;;
    post)        PHASE="post" ;;
    -h|--help)   sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" -eq 0 ] || { echo "❌ Must run as root (sudo)." >&2; exit 1; }

exec > >(tee -a "$LOG_FILE") 2>&1

log()  { echo "[$(date '+%F %T')] $*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then log "DRY-RUN: $*"; else "$@"; fi; }
die()  { log "❌ $*"; exit 1; }

swarm_active() { [ "$(docker info -f '{{.Swarm.LocalNodeState}}' 2>/dev/null)" = "active" ]; }
node_id()      { docker info -f '{{.Swarm.NodeID}}'; }
swarm_task_count() {
  docker ps -q --filter label=com.docker.swarm.service.id | wc -l
}

# ---------------------------------------------------------------- PHASE 1+2
pre_reboot() {
  log "🕒 reboot-safe: pre-reboot phase on $(hostname)"

  docker info >/dev/null 2>&1 || die "Docker daemon is not responding."

  # Preflight: don't interrupt a backup or package install
  for c in "${BLOCKING_CONTAINERS[@]}"; do
    if docker ps --format '{{.Names}}' | grep -q -- "$c"; then
      die "'$c' is running. Try again when it finishes."
    fi
  done
  if pgrep -x "apt|apt-get|dpkg|unattended-upgr" >/dev/null; then
    die "apt/dpkg is running. Try again when it finishes."
  fi

  # Snapshot what's running now
  mkdir -p "$STATE_DIR"
  local standalone
  standalone=$(docker ps --format '{{.Names}}\t{{.Label "com.docker.swarm.service.id"}}' \
               | awk -F'\t' '$2=="" {print $1}')

  log "📋 Standalone containers running: $(echo "$standalone" | grep -c . || true)"
  echo "$standalone" | sed 's/^/     - /'
  if swarm_active; then
    log "📋 Swarm tasks on this node: $(swarm_task_count)"
  fi

  if [ "$ASSUME_YES" -ne 1 ] && [ "$DRY_RUN" -ne 1 ]; then
    local action="drain"; [ "$DO_REBOOT" -eq 1 ] && action="drain and REBOOT"
    read -r -p "Proceed to ${action} $(hostname)? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "Aborted by user."
  fi

  if [ "$DRY_RUN" -ne 1 ]; then
    echo "$standalone" > "$STATE_DIR/containers.txt"
    date '+%F %T' > "$STATE_DIR/drained_at"
  fi

  # 1. DRAIN — swarm
  if swarm_active; then
    local nid; nid=$(node_id)
    [ "$DRY_RUN" -ne 1 ] && echo "$nid" > "$STATE_DIR/swarm_node_id"
    log "🚰 Draining swarm node $nid"
    run docker node update --availability drain "$nid" >/dev/null \
      || die "Failed to drain node (is this a manager?)."

    if [ "$DRY_RUN" -ne 1 ]; then
      local waited=0
      while [ "$(swarm_task_count)" -gt 0 ] && [ "$waited" -lt "$DRAIN_TIMEOUT" ]; do
        sleep 5; waited=$((waited + 5))
        log "⏳ Waiting for $(swarm_task_count) swarm task(s) to stop (${waited}s)"
      done
      [ "$(swarm_task_count)" -gt 0 ] && log "⚠️  Swarm tasks still running after ${DRAIN_TIMEOUT}s; continuing."
    fi
  fi

  # 1. DRAIN — standalone containers (stop in reverse start order)
  if [ -n "$standalone" ]; then
    log "🛑 Stopping standalone containers (timeout ${STOP_TIMEOUT}s each)"
    # shellcheck disable=SC2086
    run docker stop -t "$STOP_TIMEOUT" $(echo "$standalone" | tac) >/dev/null
  fi

  # Arm the post-boot unit
  log "🔧 Installing $UNIT_NAME for post-boot restore"
  if [ "$DRY_RUN" -ne 1 ]; then
    cat > "$UNIT_FILE" <<EOF
[Unit]
Description=reboot-safe post-boot restore
After=docker.service network-online.target remote-fs.target
Wants=network-online.target
Requires=docker.service
ConditionPathExists=${STATE_DIR}/drained_at

[Service]
Type=oneshot
ExecStart=${SCRIPT_PATH} post
TimeoutStartSec=$((CONVERGE_TIMEOUT + 120))

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$UNIT_NAME" >/dev/null 2>&1
  fi

  if [ "$DO_REBOOT" -ne 1 ]; then
    log "✅ Drained. Run '$SCRIPT_PATH post' to bring everything back."
    return
  fi

  # 2. REBOOT
  log "💾 Syncing filesystems"
  run sync
  log "🔁 Rebooting now"
  run systemctl reboot
}

# ---------------------------------------------------------------- PHASE 3
post_reboot() {
  log "🕒 reboot-safe: post-boot restore on $(hostname)"
  local failures=0

  # Wait for docker
  local waited=0
  until docker info >/dev/null 2>&1; do
    [ "$waited" -ge 120 ] && die "Docker never came up."
    sleep 5; waited=$((waited + 5))
  done

  # Re-activate swarm node
  if swarm_active; then
    local nid; nid=$(cat "$STATE_DIR/swarm_node_id" 2>/dev/null || node_id)
    log "🔌 Setting swarm node $nid to active"
    docker node update --availability active "$nid" >/dev/null \
      || { log "❌ Failed to activate node"; failures=$((failures + 1)); }
  fi

  # Restart standalone containers that were running before
  if [ -s "$STATE_DIR/containers.txt" ]; then
    while read -r c; do
      [ -z "$c" ] && continue
      if [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != "true" ]; then
        log "▶️  Starting $c"
        docker start "$c" >/dev/null || { log "❌ Failed to start $c"; failures=$((failures + 1)); }
      fi
    done < "$STATE_DIR/containers.txt"
  fi

  # Wait for swarm services to converge (replicated N/N; ignore completed jobs)
  if swarm_active; then
    local deadline=$((SECONDS + CONVERGE_TIMEOUT)) pending
    while :; do
      pending=$(docker service ls --format '{{.Name}} {{.Replicas}}' \
                | grep -v completed \
                | awk '{split($2,r,"/"); if (r[1]!=r[2]) print $1" ("$2")"}')
      [ -z "$pending" ] && { log "✅ All swarm services converged"; break; }
      if [ "$SECONDS" -ge "$deadline" ]; then
        log "❌ Services not converged:"; echo "$pending" | sed 's/^/     - /'
        failures=$((failures + 1)); break
      fi
      sleep 10
    done
  fi

  # Health checks
  for url in "${HEALTH_URLS[@]}"; do
    local deadline=$((SECONDS + CONVERGE_TIMEOUT)) code
    while :; do
      code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$url")
      if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then log "✅ $url → HTTP $code"; break; fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        log "❌ $url unhealthy (HTTP $code)"; failures=$((failures + 1)); break
      fi
      sleep 10
    done
  done

  # Disarm
  systemctl disable "$UNIT_NAME" >/dev/null 2>&1
  rm -f "$UNIT_FILE" "$STATE_DIR/drained_at"
  systemctl daemon-reload

  if [ "$failures" -gt 0 ]; then
    log "⚠️  Restore finished with $failures problem(s). See $LOG_FILE"
    exit 1
  fi
  log "🎉 Restore complete — $(hostname) is healthy."
}

if [ "$PHASE" = "post" ]; then post_reboot; else pre_reboot; fi
