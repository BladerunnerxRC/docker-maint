# shellcheck shell=bash
# Shared helpers for the admin scripts. Source it, don't run it.

set -Eeuo pipefail

QUIET=${QUIET:-0}

log()  { [ "$QUIET" = 1 ] || printf '%s %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s %s\n' "$(date '+%F %T')" "⚠️  $*" >&2; }
die()  { printf '%s %s\n' "$(date '+%F %T')" "❌ $*" >&2; exit 1; }

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker CLI not found"
  docker info >/dev/null 2>&1 || die "cannot reach the Docker daemon (are you root / in the docker group?)"
}

# Print usage from the script's header comment block (lines starting with '# ').
usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$0"
  exit "${1:-0}"
}

# Names of running containers that mount the given volume.
containers_using_volume() {
  docker ps --filter "volume=$1" --format '{{.Names}}'
}
