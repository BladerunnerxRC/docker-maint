#!/bin/bash
# volume-restore.sh - restore a volume-backup.sh archive into a Docker volume.
#
# Stops the containers using the volume, empties it (including dotfiles),
# extracts the archive and starts the containers again. The volume is
# created if it does not exist. Asks for confirmation unless -y is given.
#
# Usage: volume-restore.sh [-y] ARCHIVE VOLUME
#   -y   don't ask for confirmation
#   -h   show this help

source "$(dirname "$0")/lib/common.sh"

YES=0
HELPER_IMAGE=${HELPER_IMAGE:-alpine:3}
while getopts "yh" opt; do
  case $opt in
    y) YES=1 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 2 ] || usage 2

ARCHIVE=$1 VOL=$2
[ -f "$ARCHIVE" ] || die "archive not found: $ARCHIVE"
require_docker
gzip -t "$ARCHIVE" || die "archive is corrupt: $ARCHIVE"
dir=$(cd "$(dirname "$ARCHIVE")" && pwd)
file=$(basename "$ARCHIVE")

if [ "$YES" != 1 ]; then
  read -r -p "Replace ALL data in volume '$VOL' with $file? [y/N] " answer
  [[ $answer =~ ^[Yy]$ ]] || die "aborted"
fi

docker volume inspect "$VOL" >/dev/null 2>&1 || {
  log "🔧 Creating volume $VOL"
  docker volume create "$VOL" >/dev/null
}

mapfile -t users < <(containers_using_volume "$VOL")
if [ ${#users[@]} -gt 0 ]; then
  log "⏸️  Stopping ${users[*]}"
  docker stop "${users[@]}" >/dev/null
  trap 'log "▶️  Starting ${users[*]}"; docker start "${users[@]}" >/dev/null || warn "could not restart: ${users[*]}"' EXIT
fi

log "📦 Restoring $file into $VOL"
docker run --rm --network none \
  -v "$VOL":/dst -v "$dir":/src:ro "$HELPER_IMAGE" \
  sh -c 'find /dst -mindepth 1 -delete && tar -xzf "/src/$1" -C /dst' _ "$file"
log "✅ Restore complete"
