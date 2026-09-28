#!/bin/bash
# container-log-scan.sh - count errors in container logs over a time window.
#
# Greps each running container's recent logs (stdout and stderr) for error
# patterns and prints a per-container count, worst first. -v also shows the
# last matching lines. Exits 1 if any container has matches.
#
# Usage: container-log-scan.sh [-s SINCE] [-p REGEX] [-v N] [CONTAINER...]
#   -s SINCE   how far back to look (default 24h; anything `docker logs --since` takes)
#   -p REGEX   case-insensitive extended regex
#              (default: error|fatal|panic|exception|traceback|out of memory|oomkilled)
#   -v N       show the last N matching lines per container
#   -h         show this help

source "$(dirname "$0")/lib/common.sh"

SINCE=24h SHOW=0
PATTERN='error|fatal|panic|exception|traceback|out of memory|oomkilled'
while getopts "s:p:v:h" opt; do
  case $opt in
    s) SINCE=$OPTARG ;;
    p) PATTERN=$OPTARG ;;
    v) SHOW=$OPTARG ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done
shift $((OPTIND - 1))

require_docker
if [ $# -gt 0 ]; then
  CONTAINERS=("$@")
else
  mapfile -t CONTAINERS < <(docker ps --format '{{.Names}}')
fi

results=()
for c in "${CONTAINERS[@]}"; do
  matches=$(docker logs --since "$SINCE" "$c" 2>&1 | grep -Ei -- "$PATTERN" || true)
  count=$(printf '%s' "$matches" | grep -c . || true)
  [ "$count" -gt 0 ] || continue
  results+=("$count	$c")
  if [ "$SHOW" -gt 0 ]; then
    echo "=== $c (last $SHOW of $count)"
    printf '%s\n' "$matches" | tail -n "$SHOW" | cut -c1-300
  fi
done

if [ ${#results[@]} -eq 0 ]; then
  log "✅ No matches in the last $SINCE across ${#CONTAINERS[@]} container(s)"
  exit 0
fi
echo "--- Matches in the last $SINCE"
printf '%s\n' "${results[@]}" | sort -rn | awk -F'\t' '{printf "%6d  %s\n", $1, $2}'
exit 1
