#!/usr/bin/env bash
# claude-profiles status line for Claude Code. Optional: nothing installs it
# unless you run `./claude-profiles.sh statusline`. See README.md, "Status
# line".
#
# One line, most important first:
#   [model · effort] profile RC | 📁 dir | 🌿 branch #PR | context | $cost |
#   5h left ↻ reset | 7d left ↻ reset | session name
#
# Claude Code pipes a JSON object to stdin on every refresh and shows the
# first line of stdout (https://code.claude.com/docs/en/statusline). Needs
# jq. Written for bash 3.2 and the BSD userland like claude-profiles.sh, so
# it runs from /bin/bash on macOS: no arrays, no mapfile, no [[ ]].
#
# A status line must always print something and never an error, so there is
# no set -e, every field has a default, and bad input degrades to a shorter
# line rather than a stack of "integer expression expected".
#
# Environment:
#   CLAUDE_CONFIG_DIR   set by the claude-<name> launchers; its basename
#                       names the profile (~/.claude-work -> work)
#   COLUMNS             set by Claude Code to the terminal width; segments
#                       are dropped, least useful first, until the line fits
#   CLAUDE_STATUSLINE_PROFILE_COLOR
#                       optional SGR code for the profile name, e.g. "1;34"
#                       or "1;38;5;208". Set it in a profile's settings.json
#                       "env" block to pick that profile's colour yourself;
#                       otherwise one is derived from the name.
#   NO_COLOR            any non-empty value turns colour off
set -u
LC_NUMERIC=C

ESC=$(printf '\033')
BEL=$(printf '\007')
if [ -n "${NO_COLOR:-}" ]; then
  C_RST=""; C_CYAN=""; C_GRN=""; C_YEL=""; C_RED=""; C_DIM=""
else
  C_RST="${ESC}[0m"; C_CYAN="${ESC}[36m"; C_GRN="${ESC}[32m"
  C_YEL="${ESC}[33m"; C_RED="${ESC}[31m"; C_DIM="${ESC}[2m"
fi

isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

# ------------------------------------------------------------------- input --

INPUT=$(cat 2>/dev/null)
if ! command -v jq >/dev/null 2>&1; then
  printf '%s\n' "[status line needs jq]"
  exit 0
fi

# One jq pass, one value per line, exactly fifteen lines whatever the input:
# s()/n() turn a missing field, a wrong type or an error into "". Strings lose
# their control characters, so a newline cannot shift the fields below and an
# escape sequence in a session name or path cannot reach the terminal. Cost
# is rounded to cents here because bash has no floating point.
FIELDS=$(printf '%s' "$INPUT" | jq -r '
  def clean: if type == "string"
             then (explode | map(select(. >= 32 and . != 127)) | implode)
             else "" end;
  def s(f): (try ([f][0]) catch null) | clean;
  def n(f): (try ([f][0]) catch null)
            | if type == "number" then (floor | tostring) else "" end;
  def cents(f): (try ([f][0]) catch null)
            | if type == "number" and . >= 0
              then ((. * 100 + 0.5) | floor) as $c
                   | "\(($c / 100) | floor).\($c % 100 | tostring
                                            | if length < 2 then "0" + . else . end)"
              else "" end;
  s(.model.display_name),
  s(.workspace.current_dir // .cwd),
  cents(.cost.total_cost_usd),
  n(.context_window.used_percentage),
  s(.effort.level),
  n(.rate_limits.five_hour.used_percentage),
  n(.rate_limits.seven_day.used_percentage),
  n(.rate_limits.five_hour.resets_at),
  n(.rate_limits.seven_day.resets_at),
  s(.session_id),
  s(.session_name),
  n(.pr.number),
  s(.pr.url),
  s(.pr.review_state),
  s(.worktree.branch)
' 2>/dev/null)

MODEL=""; DIR=""; COST=""; PCT=""; EFFORT=""; FIVE_USED=""; WEEK_USED=""
FIVE_RESET=""; WEEK_RESET=""; SESSION_ID=""; SESSION_NAME=""; PR_NUM=""
PR_URL=""; PR_STATE=""; WT_BRANCH=""
i=0
while IFS= read -r line; do
  i=$((i + 1))
  case $i in
    1) MODEL=$line ;;       2) DIR=$line ;;         3) COST=$line ;;
    4) PCT=$line ;;         5) EFFORT=$line ;;      6) FIVE_USED=$line ;;
    7) WEEK_USED=$line ;;   8) FIVE_RESET=$line ;;  9) WEEK_RESET=$line ;;
    10) SESSION_ID=$line ;; 11) SESSION_NAME=$line ;; 12) PR_NUM=$line ;;
    13) PR_URL=$line ;;     14) PR_STATE=$line ;;   15) WT_BRANCH=$line ;;
  esac
done <<EOF
$FIELDS
EOF

[ -n "$MODEL" ] || MODEL="?"
[ -n "$COST" ] || COST="0.00"
isnum "$PCT" || PCT=0
[ "$PCT" -gt 100 ] && PCT=100

# ---------------------------------------------------------------- profile --

# The claude-<name> launchers set CLAUDE_CONFIG_DIR=~/.claude-<name> and the
# status line inherits it. Unset means the old default, ~/.claude.
CONFIG_DIR=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CONFIG_DIR=${CONFIG_DIR%/}
PROFILE=${CONFIG_DIR##*/}
case "$PROFILE" in
  .claude)   PROFILE="default" ;;
  .claude-*) PROFILE=${PROFILE#.claude-} ;;
esac
PROFILE=$(printf '%s' "$PROFILE" | tr -d '[:cntrl:]')

# Colour: the override if it is a plain SGR code, else one of six picked by
# a checksum of the name, so a given profile always gets the same colour on
# every machine. None of the six is the green/yellow/red used for warnings.
PCOL=${CLAUDE_STATUSLINE_PROFILE_COLOR:-}
case "$PCOL" in
  ''|*[!0-9\;]*)
    set -- 1\;38\;5\;39 1\;38\;5\;170 1\;38\;5\;208 1\;38\;5\;141 1\;38\;5\;44 1\;38\;5\;213
    sum=$(printf '%s' "$PROFILE" | cksum | cut -d ' ' -f 1)
    shift $((sum % 6))
    PCOL=$1
    ;;
esac
C_PROF=""
[ -n "$C_RST" ] && C_PROF="${ESC}[${PCOL}m"

# ---------------------------------------------------------- remote control --

# The JSON input has no Remote Control field. Each live Claude Code process
# keeps <config dir>/sessions/<pid>.json, which carries a bridgeSessionId
# while Remote Control is connected. That file is undocumented, so this may
# stop working after an upgrade; it then shows offline, never an error.
RC_ON=0
if [ -n "$SESSION_ID" ] && [ -d "${CONFIG_DIR}/sessions" ]; then
  sess=$(grep -lF "\"sessionId\":\"${SESSION_ID}\"" "${CONFIG_DIR}"/sessions/*.json 2>/dev/null | head -n 1)
  if [ -n "$sess" ] && grep -qF '"bridgeSessionId"' "$sess" 2>/dev/null; then
    RC_ON=1
  fi
fi

# ------------------------------------------------------------------ branch --

# Read from the directory Claude Code is in, not from wherever this script
# happened to start. --no-optional-locks: a status line must never contend
# for the index lock with a git command the session is running.
BRANCH=""
if [ -n "$DIR" ] && [ -d "$DIR" ]; then
  BRANCH=$(git -C "$DIR" --no-optional-locks branch --show-current 2>/dev/null)
  if [ -z "$BRANCH" ]; then
    # Detached HEAD: the short hash says more than nothing.
    BRANCH=$(git -C "$DIR" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  fi
fi
[ -n "$BRANCH" ] || BRANCH=$WT_BRANCH
BRANCH=$(printf '%s' "$BRANCH" | tr -d '[:cntrl:]')

# PR link: OSC 8, which terminals without support show as plain text. Only
# an http(s) URL is linked.
case "$PR_URL" in http://*|https://*) ;; *) PR_URL="" ;; esac
isnum "$PR_NUM" || PR_NUM=""
case "$PR_STATE" in
  approved)          C_PR=$C_GRN ;;
  changes_requested) C_PR=$C_RED ;;
  draft)             C_PR=$C_DIM ;;
  *)                 C_PR="" ;;
esac

# --------------------------------------------------------------- helpers --

NOW=$(date +%s)

fmt_rel() {  # $1 = future epoch -> "8m" / "1h12m" / "3d4h"
  local secs d h m
  isnum "$1" || return 0
  secs=$(( $1 - NOW ))
  [ "$secs" -lt 0 ] && secs=0
  d=$((secs / 86400)); h=$(((secs % 86400) / 3600)); m=$(((secs % 3600) / 60))
  if [ "$d" -gt 0 ]; then printf '%s' "${d}d${h}h"
  elif [ "$h" -gt 0 ]; then printf '%s' "${h}h${m}m"
  else printf '%s' "${m}m"; fi
}

make_bar() {  # $1 = percent -> 10 cells, eighth-block resolution (~1.25%/step)
  local pct=$1 cells=10 eighths full part i=0 bar=""
  eighths=$(( (pct * cells * 8 + 50) / 100 ))
  full=$(( eighths / 8 )); part=$(( eighths % 8 ))
  while [ "$i" -lt "$full" ]; do bar="${bar}█"; i=$((i + 1)); done
  if [ "$part" -gt 0 ] && [ "$full" -lt "$cells" ]; then
    case $part in
      1) bar="${bar}▏" ;; 2) bar="${bar}▎" ;; 3) bar="${bar}▍" ;; 4) bar="${bar}▌" ;;
      5) bar="${bar}▋" ;; 6) bar="${bar}▊" ;; 7) bar="${bar}▉" ;;
    esac
    i=$((i + 1))
  fi
  while [ "$i" -lt "$cells" ]; do bar="${bar}░"; i=$((i + 1)); done
  printf '%s' "$bar"
}

# Colour for a percentage already used: green, yellow from 70%, red from 90%.
# The same thresholds for context and for both quota windows, so one glance
# reads them all the same way. Red also gets a "!" so it survives NO_COLOR.
used_color() {
  if [ "$1" -ge 90 ]; then printf '%s' "$C_RED"
  elif [ "$1" -ge 70 ]; then printf '%s' "$C_YEL"
  else printf '%s' "$C_GRN"; fi
}
warn_mark() { [ "$1" -ge 90 ] && printf '!'; return 0; }

# Terminal columns a plain string takes: one per code point (UTF-8 bytes
# that are not continuation bytes), plus one for each 4-byte character,
# which here means an emoji and is two columns wide. LC_ALL=C so tr counts
# bytes on every platform.
vis_width() {
  local cp wide
  cp=$(printf '%s' "$1" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')
  wide=$(printf '%s' "$1" | LC_ALL=C tr -cd '\360' | wc -c | tr -d ' ')
  printf '%s' $((cp + wide))
}

trunc() {  # $1 = text, $2 = max characters; appends … when cut
  if [ "${#1}" -gt "$2" ]; then printf '%s…' "${1:0:$(($2 - 1))}"
  else printf '%s' "$1"; fi
}

# ----------------------------------------------------------------- render --

# Build the line at detail level $1: 0 is everything, each step drops or
# shortens one more thing, least useful first. Sets OUT (with colour) and
# PLAIN (without, to measure).
OUT=""; PLAIN=""
seg() {  # $1 = coloured text, $2 = same text without escapes
  if [ -n "$PLAIN" ]; then OUT="${OUT} | "; PLAIN="${PLAIN} | "; fi
  OUT="${OUT}$1"; PLAIN="${PLAIN}$2"
}

render() {
  local lvl=$1 t p b col left mark rel
  OUT=""; PLAIN=""

  # model · effort, profile, remote control: always shown.
  t="$MODEL"
  [ -n "$EFFORT" ] && [ "$lvl" -lt 7 ] && t="${t} · ${EFFORT}"
  if [ "$RC_ON" -eq 1 ]; then rel="📡"; else rel="📴"; fi
  p="👤 "
  [ "$lvl" -ge 4 ] && p=""
  seg "${C_CYAN}[${t}]${C_RST} ${p}${C_PROF}${PROFILE}${C_RST} ${rel}" \
      "[${t}] ${p}${PROFILE} ${rel}"

  # directory
  if [ -n "$DIR" ] && [ "$lvl" -lt 6 ]; then
    t=${DIR##*/}; [ -n "$t" ] || t="/"
    p="📁 "; [ "$lvl" -ge 4 ] && p=""
    seg "${p}${t}" "${p}${t}"
  fi

  # branch and PR
  b=$BRANCH
  [ "$lvl" -ge 5 ] && b=$(trunc "$b" 20)
  [ "$lvl" -ge 8 ] && b=""
  t=""; p=""
  if [ -n "$b" ]; then
    if [ "$lvl" -ge 4 ]; then t="$b"; else t="🌿 $b"; fi
    p="$t"
  fi
  if [ -n "$PR_NUM" ]; then
    [ -n "$t" ] && { t="${t} "; p="${p} "; }
    if [ -n "$PR_URL" ]; then
      t="${t}${ESC}]8;;${PR_URL}${BEL}${C_PR}#${PR_NUM}${C_RST}${ESC}]8;;${BEL}"
    else
      t="${t}${C_PR}#${PR_NUM}${C_RST}"
    fi
    p="${p}#${PR_NUM}"
  fi
  [ -n "$p" ] && seg "$t" "$p"

  # context window
  col=$(used_color "$PCT"); mark=$(warn_mark "$PCT")
  if [ "$lvl" -lt 3 ]; then
    b=$(make_bar "$PCT")
    seg "${col}${b}${C_RST} ${col}${mark}${PCT}%${C_RST}" "${b} ${mark}${PCT}%"
  else
    seg "ctx ${col}${mark}${PCT}%${C_RST}" "ctx ${mark}${PCT}%"
  fi

  # cost
  seg "${C_YEL}\$${COST}${C_RST}" "\$${COST}"

  # 5h and 7d windows, shown as what is left. Claude.ai plans only, and only
  # after the first API response; absent otherwise.
  for w in 5h 7d; do
    if [ "$w" = "5h" ]; then t=$FIVE_USED; rel=$FIVE_RESET; else t=$WEEK_USED; rel=$WEEK_RESET; fi
    isnum "$t" || continue
    [ "$t" -gt 100 ] && t=100
    left=$((100 - t))
    col=$(used_color "$t"); mark=$(warn_mark "$t")
    b="${left}%"; [ "$lvl" -lt 3 ] && b="${left}% left"
    if [ "$lvl" -lt 2 ] && isnum "$rel"; then rel=" ↻ $(fmt_rel "$rel")"; else rel=""; fi
    seg "${C_CYAN}${w}${C_RST} ${col}${mark}${b}${C_RST}${rel}" "${w} ${mark}${b}${rel}"
  done

  # session name, only when there is room for it
  if [ -n "$SESSION_NAME" ] && [ "$lvl" -lt 1 ]; then
    t=$(trunc "$SESSION_NAME" 32)
    seg "${C_DIM}${t}${C_RST}" "$t"
  fi
}

MAX=0
if isnum "${COLUMNS:-}"; then MAX=$((COLUMNS - 2)); fi
lvl=0
render 0
if [ "$MAX" -gt 0 ]; then
  while [ "$lvl" -lt 8 ] && [ "$(vis_width "$PLAIN")" -gt "$MAX" ]; do
    lvl=$((lvl + 1))
    render "$lvl"
  done
fi
printf '%s\n' "$OUT"
