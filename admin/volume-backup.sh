#!/bin/bash
# volume-backup.sh - back up named Docker volumes to timestamped archives.
#
# Each volume is archived by a throwaway Alpine container, so this works from
# the host or from a Portainer stack as long as the Docker socket is available.
# Archives are written as <volume>_YYYYmmdd-HHMMSS.tar.gz, checked with
# gzip -t, and only the newest KEEP archives per volume are kept.
# Use -s for databases: containers using the volume are stopped during the
# backup and started again afterwards (even if the backup fails).
#
# Usage: volume-backup.sh -d DEST [-k KEEP] [-s] [-A] VOLUME...
#   -d DEST   directory to write archives to (e.g. an NFS mount)
#   -k KEEP   archives to keep per volume (default 7)
#   -s        stop containers using the volume while it is backed up
#   -A        back up every named volume instead of listing them
#   -h        show this help

source "$(dirname "$0")/lib/common.sh"

DEST="" KEEP=7 STOP=0 ALL=0
HELPER_IMAGE=${HELPER_IMAGE:-alpine:3}
while getopts "d:k:sAh" opt; do
  case $opt in
    d) DEST=$OPTARG ;;
    k) KEEP=$OPTARG ;;
    s) STOP=1 ;;
    A) ALL=1 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done
shift $((OPTIND - 1))

[ -n "$DEST" ] || usage 2
[ "$KEEP" -ge 1 ] 2>/dev/null || die "-k must be a positive number"
require_docker
mkdir -p "$DEST"
DEST=$(cd "$DEST" && pwd)

if [ "$ALL" = 1 ]; then
  # Anonymous volumes have 64-hex-char names; skip them.
  mapfile -t VOLUMES < <(docker volume ls -q | grep -Ev '^[0-9a-f]{64}$' || true)
else
  VOLUMES=("$@")
fi
[ ${#VOLUMES[@]} -gt 0 ] || die "no volumes given (list them or use -A)"

stopped=()
restart_stopped() {
  if [ ${#stopped[@]} -gt 0 ]; then
    log "▶️  Starting ${stopped[*]}"
    docker start "${stopped[@]}" >/dev/null || warn "could not restart: ${stopped[*]}"
    stopped=()
  fi
}
trap restart_stopped EXIT

failed=0
ts=$(date +%Y%m%d-%H%M%S)
for vol in "${VOLUMES[@]}"; do
  if ! docker volume inspect "$vol" >/dev/null 2>&1; then
    warn "volume $vol does not exist"; failed=1; continue
  fi
  archive="${vol}_${ts}.tar.gz"

  if [ "$STOP" = 1 ]; then
    mapfile -t stopped < <(containers_using_volume "$vol")
    if [ ${#stopped[@]} -gt 0 ]; then
      log "⏸️  Stopping ${stopped[*]}"
      docker stop "${stopped[@]}" >/dev/null
    fi
  fi

  log "📦 Backing up $vol -> $DEST/$archive"
  if docker run --rm --network none \
      -v "$vol":/src:ro -v "$DEST":/dst "$HELPER_IMAGE" \
      sh -c 'tar -czf "/dst/$1.partial" -C /src . && mv "/dst/$1.partial" "/dst/$1"' _ "$archive" \
    && gzip -t "$DEST/$archive"; then
    log "✅ $vol: $(du -h "$DEST/$archive" | cut -f1)"
  else
    warn "backup of $vol failed"; failed=1
    rm -f "$DEST/$archive" "$DEST/$archive.partial"
  fi
  restart_stopped

  # Retention: timestamps sort by name, oldest first. The timestamp glob
  # stops "app" from matching "app_data" archives.
  shopt -s nullglob
  archives=("$DEST/${vol}"_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tar.gz)
  shopt -u nullglob
  excess=$((${#archives[@]} - KEEP))
  if [ "$excess" -gt 0 ]; then
    log "🗑️  Removing $excess old archive(s) of $vol"
    rm -f "${archives[@]:0:excess}"
  fi
done

if [ "$failed" = 0 ]; then
  log "🎉 Backup complete"
else
  warn "backup finished with errors"
fi
exit "$failed"
