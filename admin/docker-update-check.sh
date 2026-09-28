#!/bin/bash
# docker-update-check.sh - find running containers whose image has a newer version.
#
# Pulls each running container's image tag and compares it with the image the
# container was started from. With -u it also redeploys the affected compose
# projects (pull + up -d). Portainer-managed stacks keep their compose files
# inside Portainer, so those are reported but must be redeployed there.
# Containers labelled docker-maint.no-update=true are skipped.
# Exits 1 if updates are available and were not applied.
#
# Usage: docker-update-check.sh [-u] [-q]
#   -u   apply updates to compose projects whose files are on this host
#   -q   quiet: print only containers with updates
#   -h   show this help

source "$(dirname "$0")/lib/common.sh"

APPLY=0
while getopts "uqh" opt; do
  case $opt in
    u) APPLY=1 ;;
    q) QUIET=1 ;;
    h) usage 0 ;;
    *) usage 2 ;;
  esac
done

require_docker

declare -A pulled=()      # image ref -> image ID after pull ("" if pull failed)
declare -A projects=()    # compose project -> "workdir|configfiles"
manual=()                 # outdated containers not managed by compose
outdated=0

# Fields are split on \x1f: tab is IFS whitespace, so empty labels would collapse.
while IFS=$'\x1f' read -r name ref current skip project workdir files; do
  name=${name#/}
  if [ "$skip" = true ]; then
    log "⏭️  $name skipped (docker-maint.no-update)"; continue
  fi
  case $ref in
    *@sha256:*|sha256:*) log "📌 $name is pinned to a digest, skipping"; continue ;;
  esac

  if [ -z "${pulled[$ref]+x}" ]; then
    if docker pull -q "$ref" >/dev/null 2>&1; then
      pulled[$ref]=$(docker image inspect --format '{{.Id}}' "$ref")
    else
      warn "could not pull $ref (private registry, local build, or offline?)"
      pulled[$ref]=""
    fi
  fi
  latest=${pulled[$ref]}
  [ -n "$latest" ] || continue

  if [ "$latest" = "$current" ]; then
    log "✅ $name ($ref) is up to date"
  else
    printf '⬆️  %s (%s) has an update%s\n' "$name" "$ref" "${project:+ [project: $project]}"
    outdated=$((outdated + 1))
    if [ -n "$project" ]; then
      projects[$project]="$workdir|$files"
    else
      manual+=("$name")
    fi
  fi
done < <(docker ps -q | xargs -r docker inspect --format \
  '{{.Name}}{{"\x1f"}}{{.Config.Image}}{{"\x1f"}}{{.Image}}{{"\x1f"}}{{index .Config.Labels "docker-maint.no-update"}}{{"\x1f"}}{{index .Config.Labels "com.docker.compose.project"}}{{"\x1f"}}{{index .Config.Labels "com.docker.compose.project.working_dir"}}{{"\x1f"}}{{index .Config.Labels "com.docker.compose.project.config_files"}}')

if [ "$outdated" -eq 0 ]; then
  log "🎉 Everything is up to date"; exit 0
fi
if [ "$APPLY" != 1 ]; then
  echo "$outdated container(s) have updates. Re-run with -u to apply them to compose projects."
  exit 1
fi

failed=0
if [ ${#manual[@]} -gt 0 ]; then
  warn "not managed by compose, recreate by hand: ${manual[*]}"
  failed=1
fi
for project in "${!projects[@]}"; do
  IFS='|' read -r workdir files <<<"${projects[$project]}"
  args=(-p "$project")
  missing=0
  IFS=',' read -ra cfgs <<<"$files"
  for f in "${cfgs[@]}"; do
    [ -f "$f" ] || missing=1
    args+=(-f "$f")
  done
  if [ "$missing" = 1 ] || [ ${#cfgs[@]} -eq 0 ]; then
    warn "$project: compose file not on this host (Portainer stack?), redeploy it from Portainer"
    failed=1; continue
  fi
  log "🚀 Updating $project"
  if ! (cd "$workdir" && docker compose "${args[@]}" pull -q && docker compose "${args[@]}" up -d); then
    warn "$project: update failed"; failed=1
  fi
done
exit "$failed"
