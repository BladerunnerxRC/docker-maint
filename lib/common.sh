#!/usr/bin/env bash
# Shared helpers for docker-maint CLI tools: colors, formatting, tables, checks.
# Source this file; do not execute it directly.

# shellcheck disable=SC2034  # palette + DM_VERSION are consumed by the sourcing scripts
[[ -n "${_DM_COMMON_LOADED:-}" ]] && return 0
_DM_COMMON_LOADED=1

DM_VERSION="1.0.0"

# Use a UTF-8 ctype when available so string lengths/truncation count characters.
if [[ "$(locale charmap 2>/dev/null)" != "UTF-8" ]] && locale -a 2>/dev/null | grep -qiE '^c\.utf-?8$'; then
  export LC_CTYPE=C.UTF-8
fi

# ── Colors ────────────────────────────────────────────────────────────────
# Disabled automatically when stdout is not a TTY, or when NO_COLOR is set.
# Force on with FORCE_COLOR=1.
dm_init_colors() {
  if [[ -n "${FORCE_COLOR:-}" ]] || { [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; }; then
    RESET=$'\e[0m'  BOLD=$'\e[1m'  DIM=$'\e[2m'  ITALIC=$'\e[3m'  ULINE=$'\e[4m'
    RED=$'\e[31m'   GREEN=$'\e[32m'  YELLOW=$'\e[33m'  BLUE=$'\e[34m'
    MAGENTA=$'\e[35m' CYAN=$'\e[36m' WHITE=$'\e[37m'   GREY=$'\e[90m'
    BRED=$'\e[91m'  BGREEN=$'\e[92m' BYELLOW=$'\e[93m' BBLUE=$'\e[94m'
    BMAGENTA=$'\e[95m' BCYAN=$'\e[96m'
  else
    RESET='' BOLD='' DIM='' ITALIC='' ULINE=''
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' WHITE='' GREY=''
    BRED='' BGREEN='' BYELLOW='' BBLUE='' BMAGENTA='' BCYAN=''
  fi
}
dm_init_colors

# ── Messages ──────────────────────────────────────────────────────────────
info()    { printf '%s ℹ %s %s\n' "${BLUE}${BOLD}" "${RESET}" "$*"; }
ok()      { printf '%s ✔ %s %s\n' "${GREEN}${BOLD}" "${RESET}" "$*"; }
warn()    { printf '%s ⚠ %s %s\n' "${YELLOW}${BOLD}" "${RESET}" "$*" >&2; }
err()     { printf '%s ✖ %s %s\n' "${RED}${BOLD}" "${RESET}" "$*" >&2; }
die()     { err "$*"; exit 1; }
step()    { printf '%s ➜ %s %s\n' "${CYAN}${BOLD}" "${RESET}" "$*"; }
muted()   { printf '%s%s%s\n' "${GREY}" "$*" "${RESET}"; }

# Terminal width (fallback 80, capped at 140 for readability).
term_width() {
  local w
  w=$(tput cols 2>/dev/null || echo 80)
  [[ "$w" =~ ^[0-9]+$ ]] || w=80
  (( w > 140 )) && w=140
  echo "$w"
}

# repeat CHAR COUNT
repeat() { local s; printf -v s '%*s' "$2" ''; printf '%s' "${s// /$1}"; }

# Visible length of a plain string in characters (UTF-8 aware, locale independent).
vislen() { local LC_ALL=C s="$1"; s="${s//[$'\x80'-$'\xbf']/}"; echo "${#s}"; }

# Big boxed banner:  banner "Title" "optional subtitle"
banner() {
  local w inner
  w=$(term_width); inner=$(( w - 2 ))
  printf '%s╭%s╮%s\n' "${CYAN}" "$(repeat '─' "$inner")" "${RESET}"
  _banner_line() {
    local text=" $1" pad
    pad=$(( inner - $(vislen "$text") )); (( pad < 0 )) && pad=0
    printf '%s│%s%s%s%*s%s│%s\n' "${CYAN}" "${RESET}" "$2" "$text" "$pad" '' "${CYAN}" "${RESET}"
  }
  _banner_line "$1" "${BOLD}"
  [[ -n "${2:-}" ]] && _banner_line "$2" "${GREY}"
  printf '%s╰%s╯%s\n' "${CYAN}" "$(repeat '─' "$inner")" "${RESET}"
}

# Section header:  section "Containers"
section() {
  local title="$1" w
  w=$(term_width)
  local pad=$(( w - $(vislen "$title") - 4 ))
  (( pad < 3 )) && pad=3
  printf '\n%s━━ %s%s%s %s%s\n' "${MAGENTA}" "${BOLD}" "$title" "${RESET}${MAGENTA}" "$(repeat '━' "$pad")" "${RESET}"
}

# Key/value line:  kv "Label" "value"
kv() { printf '  %s%-22s%s %s\n' "${GREY}" "$1" "${RESET}" "$2"; }

# ── Tables ────────────────────────────────────────────────────────────────
# Render TSV from stdin as an aligned table. First line is the header.
# Width is computed on text with ANSI codes stripped, so colored cells align.
#   printf 'A\tB\nx\ty\n' | table
table() {
  awk -F'\t' -v H="${BOLD}${ULINE}" -v R="${RESET}" -v SEP="  " '
    # strip ANSI codes and UTF-8 continuation bytes → visible chars (mawk & gawk)
    function vlen(s,  t) { t = s; gsub(/\033\[[0-9;]*m/, "", t); gsub(/[\200-\277]/, "", t); return length(t) }
    { for (i = 1; i <= NF; i++) { cell[NR, i] = $i; l = vlen($i); if (l > w[i]) w[i] = l }
      if (NF > nf) nf = NF; rows = NR }
    END {
      for (r = 1; r <= rows; r++) {
        line = "  "
        for (i = 1; i <= nf; i++) {
          c = cell[r, i]; pad = w[i] - vlen(c)
          if (r == 1) c = H c R
          line = line c (i < nf ? sprintf("%" pad "s", "") SEP : "")
        }
        print line
      }
    }'
}

# ── Formatting helpers ────────────────────────────────────────────────────
# Human-readable bytes:  human_bytes 123456789 → 117.7MiB
human_bytes() {
  awk -v b="${1:-0}" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " "); i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf (i == 1 ? "%d%s" : "%.1f%s"), b, u[i] }'
}

# Colorize a container state / health word.
color_state() {
  case "$1" in
    running|healthy|ok|OK|PASS|up|Up*)            printf '%s%s%s' "${GREEN}" "$1" "${RESET}" ;;
    starting|restarting|paused|created|WARN)      printf '%s%s%s' "${YELLOW}" "$1" "${RESET}" ;;
    exited|dead|unhealthy|removing|FAIL|down)     printf '%s%s%s' "${RED}" "$1" "${RESET}" ;;
    none|-|"")                                    printf '%s%s%s' "${GREY}" "${1:--}" "${RESET}" ;;
    *)                                            printf '%s' "$1" ;;
  esac
}

# Colorize a percentage against warn/crit thresholds:  color_pct 83.2 70 90
color_pct() {
  local v="${1%\%}" warn="${2:-70}" crit="${3:-90}" c="${GREEN}"
  if awk -v v="$v" -v t="$crit" 'BEGIN{exit !(v+0 >= t)}'; then c="${RED}${BOLD}"
  elif awk -v v="$v" -v t="$warn" 'BEGIN{exit !(v+0 >= t)}'; then c="${YELLOW}"; fi
  printf '%s%s%%%s' "$c" "$v" "${RESET}"
}

# Text progress bar:  bar 42 20 → [████████░░░░░░░░░░░░]
bar() {
  local pct="${1%.*}" width="${2:-20}" c="${GREEN}"
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  (( pct > 100 )) && pct=100
  (( pct >= 70 )) && c="${YELLOW}"
  (( pct >= 90 )) && c="${RED}"
  local fill=$(( pct * width / 100 ))
  printf '%s%s%s%s%s' "$c" "$(repeat '█' "$fill")" "${GREY}" "$(repeat '░' $(( width - fill )))" "${RESET}"
}

# Truncate to N chars with an ellipsis.
trunc() { local s="$1" n="${2:-30}"; (( ${#s} > n )) && s="${s:0:n-1}…"; printf '%s' "$s"; }

# Relative time from an RFC3339 timestamp:  ago 2024-01-01T00:00:00Z → 3d ago
ago() {
  local ts now d
  ts=$(date -d "$1" +%s 2>/dev/null) || { printf '%s' "-"; return; }
  now=$(date +%s); d=$(( now - ts ))
  if   (( d < 60 ));     then printf '%ds ago' "$d"
  elif (( d < 3600 ));   then printf '%dm ago' $(( d / 60 ))
  elif (( d < 86400 ));  then printf '%dh ago' $(( d / 3600 ))
  else                        printf '%dd ago' $(( d / 86400 )); fi
}

# ── Preconditions ─────────────────────────────────────────────────────────
need() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "Missing required command(s): ${missing[*]}"
}

need_docker() {
  need docker
  docker info >/dev/null 2>&1 || die "Cannot reach the Docker daemon. Is it running and do you have permission? (try sudo or the docker group)"
}

# Pick 'docker compose' (v2) or 'docker-compose' (v1).
compose_cmd() {
  if docker compose version >/dev/null 2>&1; then echo "docker compose"
  elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"
  else return 1; fi
}

# Ask yes/no; honors ASSUME_YES=1.
confirm() {
  [[ "${ASSUME_YES:-0}" == 1 ]] && return 0
  local reply
  read -r -p "$(printf '%s ? %s %s [y/N] ' "${YELLOW}${BOLD}" "${RESET}" "$1")" reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}
