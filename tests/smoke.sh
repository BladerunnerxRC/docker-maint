#!/usr/bin/env bash
# End-to-end smoke test for the dm toolkit against a live Docker daemon.
# Creates its own throwaway containers/volumes (prefix dmtest-) and removes them afterwards.
#   tests/smoke.sh            run everything
#   KEEP=1 tests/smoke.sh     leave test resources behind for inspection
set -euo pipefail
ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
BIN="$ROOT/bin"
HELPER="${DM_HELPER_IMAGE:-busybox:1.37}"
export DM_HELPER_IMAGE="$HELPER" ASSUME_YES=1
WORK=$(mktemp -d)
PASS=0 FAIL=0

cleanup() {
  [[ "${KEEP:-0}" == 1 ]] && { warn "KEEP=1 — leaving resources and $WORK"; return; }
  docker ps -aq --filter name=dmtest- | xargs -r docker rm -f >/dev/null 2>&1 || true
  docker volume ls -q --filter name=dmtest- | xargs -r docker volume rm -f >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

check() {  # check "description" command...
  local desc="$1"; shift
  local out
  if out=$("$@" 2>&1); then printf '  %s✔%s %s\n' "$GREEN" "$RESET" "$desc"; PASS=$((PASS + 1))
  else printf '  %s✖%s %s\n' "$RED$BOLD" "$RESET" "$desc"; sed "s/^/      ${GREY}│${RESET} /" <<<"$out" | tail -15; FAIL=$((FAIL + 1)); fi
}
expect_rc() { local want="$1"; shift; local rc=0; "$@" >/dev/null 2>&1 || rc=$?; [[ "$rc" == "$want" ]] || { echo "expected rc=$want, got rc=$rc"; return 1; }; }

dm_lists_all() {
  local out f
  out=$(env -u FORCE_COLOR NO_COLOR=1 "$BIN/dm")
  for f in "$BIN"/dm-*; do grep -q "^  ${f##*/dm-} " <<<"$out" || { echo "missing: ${f##*/dm-}"; return 1; }; done
}

need_docker; need jq
banner "dm toolkit smoke test" "docker $(docker version -f '{{.Server.Version}}') · helper $HELPER"
docker image inspect "$HELPER" >/dev/null 2>&1 || docker pull -q "$HELPER" >/dev/null

section "Static"
check "bash -n on all scripts"            bash -n "$ROOT"/lib/common.sh "$BIN"/* "$ROOT"/backup.sh "$ROOT"/restore.sh
for c in "$BIN"/dm-*; do check "$(basename "$c") --help" "$c" --help; done
check "dm lists every dm-* command"       dm_lists_all

section "Fixtures"
docker volume create dmtest-data >/dev/null
docker run --rm -v dmtest-data:/d "$HELPER" sh -c 'echo original > /d/file.txt; mkdir -p /d/sub; echo x > /d/sub/f; chown 101:101 /d/sub/f'
docker run -d --name dmtest-app --label docker-maint.backup=true --label docker-maint.backup.stop=true \
  --health-cmd 'true' --health-interval 2s -v dmtest-data:/data "$HELPER" sleep 600 >/dev/null
docker run -d --name dmtest-skip --label docker-maint.backup=false -v dmtest-skipped:/data "$HELPER" sleep 600 >/dev/null
docker run -d --name dmtest-sick --health-cmd 'false' --health-interval 1s --health-retries 1 "$HELPER" sleep 600 >/dev/null
sleep 4
ok "containers and volumes created"

section "Admin & monitoring"
check "dm-status"                         "$BIN/dm-status" -a
check "dm-images"                         "$BIN/dm-images"
check "dm-cleanup dry run"                "$BIN/dm-cleanup"
check "dm-health flags unhealthy (rc=2)"  expect_rc 2 "$BIN/dm-health" -q
check "dm-health --json is valid JSON"    bash -c "'$BIN/dm-health' -j | jq -e 'map(select(.name == \"dmtest-sick\" and .verdict == \"FAIL\")) | length == 1'"
check "dm-monitor --once"                 "$BIN/dm-monitor" --once dmtest
check "dm-logs scan"                      "$BIN/dm-logs" scan -s 1h dmtest-app
check "dm-doc renders markdown"           bash -c "'$BIN/dm-doc' --stdout | grep -q '^## Containers'"

section "Compose"
check "compose-extract output validates"  bash -c "'$BIN/dm-compose-extract' -o '$WORK/x/compose.yaml' dmtest-app && docker compose -f '$WORK/x/compose.yaml' config -q"
check "compose-new (postgres) validates"  "$BIN/dm-compose-new" -d "$WORK" -t postgres dmtestdb
check "compose-lint on generated stack"   "$BIN/dm-compose-lint" "$WORK/dmtestdb"
check "compose-lint on repo files"        "$BIN/dm-compose-lint" -q "$ROOT"

section "Backup & restore"
check "dm-backup --label"                 "$BIN/dm-backup" -d "$WORK/bk" --label
check "labelled volume archived"          test -f "$(ls -d "$WORK"/bk/*/ | tail -1)dmtest-data.tar.gz"
check "backup=false volume skipped"       bash -c "! ls '$WORK'/bk/*/dmtest-skipped.tar.gz 2>/dev/null"
check "container restarted after backup"  bash -c "[[ \$(docker inspect -f '{{.State.Running}}' dmtest-app) == true ]]"
docker run --rm -v dmtest-data:/d "$HELPER" sh -c 'echo CORRUPT > /d/file.txt; rm -rf /d/sub; touch /d/junk'
check "dm-restore run"                    "$BIN/dm-restore" -d "$WORK/bk" -y -t 60
check "content restored"                  bash -c "[[ \$(docker run --rm -v dmtest-data:/v:ro '$HELPER' cat /v/file.txt) == original ]]"
check "stray files removed"               bash -c "! docker run --rm -v dmtest-data:/v:ro '$HELPER' test -e /v/junk"
check "ownership preserved"               bash -c "[[ \$(docker run --rm -v dmtest-data:/v:ro '$HELPER' stat -c %u /v/sub/f) == 101 ]]"
check "restore --as new volume"           "$BIN/dm-restore" -d "$WORK/bk" --as dmtest-copy -y dmtest-data
check "copy has content"                  bash -c "[[ \$(docker run --rm -v dmtest-copy:/v:ro '$HELPER' cat /v/file.txt) == original ]]"
f="$(ls -d "$WORK"/bk/*/ | tail -1)dmtest-data.tar.gz"
printf 'x' >>"$f"
check "corrupt archive rejected"          expect_rc 1 "$BIN/dm-restore" -d "$WORK/bk" -y

section "Result"
printf '  %s✔ %d passed%s   %s✖ %d failed%s\n\n' "$GREEN" "$PASS" "$RESET" "$RED$BOLD" "$FAIL" "$RESET"
(( FAIL == 0 ))
