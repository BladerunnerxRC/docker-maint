#!/bin/bash
# docker-health.sh - one-shot health report for the Docker host.
#
# Flags containers that are unhealthy, restarting, exited with a non-zero
# code, or restarting too often, and warns when the Docker data disk is
# filling up. Exits 1 if anything needs attention, so it works as a cron /
# Home Assistant / Uptime Kuma check.
#
# Usage: docker-health.sh [-q] [-r RESTARTS] [-d DISK_PCT]
#   -q            quiet: print only problems
#   -r RESTARTS   restart count that counts as a problem (default 5)
#   -d DISK_PCT   disk usage % that counts as a problem (default 85)
#   -h            show this help

source "$(dirname "$0")/lib/common.sh"

MAX_RESTARTS=5
MAX_DISK_PCT=85
while getopts "qr:d:h" opt; do
  case $opt in
    q) QUIET=1 ;;
    r) MAX_RESTARTS=$OPTARG ;;
    d) MAX_DISK_PCT=$OPTARG ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

require_docker
problems=0
problem() { printf '❌ %s\n' "$*"; problems=$((problems + 1)); }

log "🩺 Docker health check on $(hostname)"

ids=$(docker ps -aq)
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086  # word splitting of ids is intended
  while IFS=$'\t' read -r name state health restarts code; do
    name=${name#/}
    case "$state/$health" in
      restarting/*) problem "$name is restarting (restart count $restarts)"; continue ;;
      */unhealthy)  problem "$name is unhealthy" ;;
      exited/*)
        if [ "$code" -ne 0 ]; then
          problem "$name exited with code $code"
        else
          log "ℹ️  $name exited cleanly (one-shot job?)"
        fi
        continue ;;
    esac
    if [ "$restarts" -ge "$MAX_RESTARTS" ]; then
      problem "$name has restarted $restarts times"
    fi
  done < <(docker inspect --format \
    '{{.Name}}{{"\t"}}{{.State.Status}}{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}{{"\t"}}{{.RestartCount}}{{"\t"}}{{.State.ExitCode}}' $ids)
fi

running=$(docker ps -q | wc -l)
total=$(printf '%s' "$ids" | grep -c . || true)
log "📦 $running of $total containers running"

root=$(docker info --format '{{.DockerRootDir}}')
if [ -d "$root" ]; then
  pct=$(df -P "$root" | awk 'NR==2 {sub("%","",$5); print $5}')
  if [ "$pct" -ge "$MAX_DISK_PCT" ]; then
    problem "Docker disk $root is ${pct}% full (limit ${MAX_DISK_PCT}%)"
  else
    log "💾 Docker disk $root is ${pct}% full"
  fi
fi

if [ "$QUIET" != 1 ]; then
  docker system df
fi

if [ "$problems" -gt 0 ]; then
  printf '%s problem(s) found\n' "$problems"
  exit 1
fi
log "✅ All good"
