#!/bin/bash
# docker-cleanup.sh - reclaim disk space safely.
#
# Dry run by default: shows what would be removed and how much space is
# reclaimable. With -y it prunes stopped containers, unused networks,
# dangling images and build cache older than AGE. Named volumes are never
# touched; -v adds anonymous volumes, -a adds all unused images (not just
# dangling ones). Anything labelled docker-maint.keep=true is skipped.
#
# Usage: docker-cleanup.sh [-y] [-a] [-v] [-t AGE]
#   -y       actually delete (default is a dry run)
#   -a       also remove unused (not just dangling) images
#   -v       also remove unused anonymous volumes
#   -t AGE   only prune things older than AGE (default 24h, e.g. 72h, 168h)
#   -h       show this help

source "$(dirname "$0")/lib/common.sh"

APPLY=0 ALL_IMAGES=0 VOLUMES=0 AGE=24h
while getopts "yavt:h" opt; do
  case $opt in
    y) APPLY=1 ;;
    a) ALL_IMAGES=1 ;;
    v) VOLUMES=1 ;;
    t) AGE=$OPTARG ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

require_docker
KEEP='label!=docker-maint.keep=true'

if [ "$APPLY" != 1 ]; then
  log "🔎 Dry run (use -y to delete). Candidates:"
  echo "--- Stopped containers"
  docker ps -a --filter status=exited --filter status=created --filter status=dead \
    --format '  {{.Names}}  ({{.Status}}, {{.Image}}){{if eq (.Label "docker-maint.keep") "true"}}  [kept]{{end}}'
  echo "--- Dangling images"
  docker images --filter dangling=true --format '  {{.ID}}  {{.Size}}  created {{.CreatedSince}}'
  if [ "$VOLUMES" = 1 ]; then
    echo "--- Unused anonymous volumes"
    docker volume ls -q --filter dangling=true | grep -E '^[0-9a-f]{64}$' | sed 's/^/  /' || true
  fi
  echo "--- Reclaimable space"
  docker system df
  exit 0
fi

log "🧹 Pruning resources older than $AGE"
docker container prune -f --filter "until=$AGE" --filter "$KEEP"
docker network prune -f --filter "until=$AGE" --filter "$KEEP"
if [ "$ALL_IMAGES" = 1 ]; then
  docker image prune -af --filter "until=$AGE" --filter "$KEEP"
else
  docker image prune -f --filter "until=$AGE" --filter "$KEEP"
fi
docker builder prune -f --filter "until=$AGE"
if [ "$VOLUMES" = 1 ]; then
  docker volume prune -f --filter "$KEEP"
fi
docker system df
log "✅ Cleanup complete"
