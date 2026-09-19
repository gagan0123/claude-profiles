#!/usr/bin/env bash
#
# claude-profiles.sh
#
# Sets up two isolated Claude Code profiles (e.g. work + personal) on one
# machine that SHARE session transcripts, prompt history, checkpoints, skills
# and plugins, while keeping credentials completely separate.
#
# SAFETY MODEL
#   This script NEVER writes to, deletes from, or symlinks anything inside
#   your existing ~/.claude directory. It only reads from it. Your current
#   setup keeps working exactly as it does today, untouched, as a fallback.
#   Everything new lives in three new directories:
#
#     ~/.claude-<main>     new profile, inherits your current config + login
#     ~/.claude-<second>   new profile, logs in as the second account
#     ~/.claude-shared     the single copy of shared session data + skills
#
# Read README.md before running. Run `plan` first; it changes nothing.
#
# Requires bash 3.2+ (works with macOS's stock /bin/bash). macOS + Linux.
# NOT supported on Windows: see README.md "Windows" for why.
#
# Portability notes, so nobody "fixes" these into something that only works
# on one platform:
#   - readlink is used WITHOUT -f (macOS readlink lacks it before 12.3)
#   - du -sk / df -Pk / tar czf / cp -Rp / grep -F / sed -n are the POSIX
#     subset that GNU and BSD userlands agree on
#   - no arrays, no [[ ]], no ${var,,}, no mapfile: bash 3.2 has none of them
#   - tar takes several -C flags positionally in both GNU tar and bsdtar

set -euo pipefail

VERSION="1.1.0"

# ---------------------------------------------------------------- defaults --

MAIN="work"
SECOND="personal"
SOURCE="${HOME}/.claude"
SHARED="${HOME}/.claude-shared"
BACKUP_ROOT="${HOME}/.claude-backups"
SHARE_MODE="full"
DO_SHELL=0
DO_BACKUP=1
ASSUME_YES=0
CMD=""

# Which options were given explicitly on the command line. Anything not given
# explicitly falls back to the values recorded at apply time (see CONF_FILE),
# so `verify` and `rollback` do not need the flags repeated.
MAIN_SET=0; SECOND_SET=0; SHARE_SET=0; SOURCE_SET=0
CONF_LOADED=0
CONF_CLAUDE_VERSION=""

# Session data. "full" gives you cross-profile --resume and --continue.
# "safe" deliberately leaves transcripts and checkpoints per-profile so that
# one account's conversations never become readable under the other.
# Path list source of truth: https://code.claude.com/docs/en/claude-directory
DATA_FULL="projects history.jsonl file-history plans tasks paste-cache image-cache uploads session-env agent-memory"
DATA_SAFE="history.jsonl plans paste-cache"

# Personal config worth having identical in both profiles.
CONFIG_SHARED="skills commands agents workflows rules output-styles plugins"

# Config copied once into each profile, then free to diverge.
CONFIG_COPIED="settings.json CLAUDE.md keybindings.json themes"

# Deliberately NOT shared, ever:
#   .credentials.json  the whole point of the separation
#   .claude.json       holds the OAuth session and per-project trust
#   sessions/          live-session detection; sharing invites cross-cleanup
#   backups/           rolling copies of .claude.json, per profile by nature
PRIVATE=".credentials.json .claude.json sessions"

# ------------------------------------------------------------------- utils --

C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_YEL=$'\033[33m'; C_GRN=$'\033[32m'
  C_DIM=$'\033[2m';  C_OFF=$'\033[0m'
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s\n' "  $*"; }
ok()   { printf '%s\n' "  ${C_GRN}ok${C_OFF}   $*"; }
warn() { printf '%s\n' "  ${C_YEL}warn${C_OFF} $*" >&2; }
die()  { printf '%s\n' "${C_RED}error${C_OFF} $*" >&2; exit 1; }
hdr()  { printf '\n%s\n' "$*"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }

DRY=1
run() {
  if [ "$DRY" -eq 1 ]; then
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} $*"
  else
    "$@"
  fi
}

have_tty() {
  # True only if /dev/tty can actually be opened. Inside Claude Code's Bash
  # tool, CI, and most editors' task runners it cannot, and `read </dev/tty`
  # fails with "No such device or address".
  ( exec </dev/tty ) 2>/dev/null
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  if ! have_tty; then
    say ""
    warn "No terminal is available to answer: $1"
    warn "Re-run with --yes to skip confirmations. (This is expected when the"
    warn "script is driven from inside Claude Code or any non-interactive runner.)"
    return 1
  fi
  printf '\n%s ' "$1 [y/N]"
  read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

kb_h() {
  # kilobytes -> human readable, portable awk only
  awk -v k="${1:-0}" 'BEGIN {
    if (k >= 1048576) printf "%.1fG", k/1048576;
    else if (k >= 1024) printf "%.0fM", k/1024;
    else printf "%dK", k }'
}

dir_kb() {
  # size of a path in KB, 0 if unreadable/missing
  local s
  s=$(du -sk "$1" 2>/dev/null | cut -f1) || s=0
  printf '%s' "${s:-0}"
}

claude_version() {
  # First whitespace-separated token of `claude --version`, e.g. "2.1.278"
  # from "2.1.278 (Claude Code)". "unknown" if claude is missing or the
  # command fails. Must never abort the script, even under set -e: every
  # failure path below is guarded by an explicit condition, not left to
  # propagate.
  local out first
  if command -v claude >/dev/null 2>&1; then
    out=$(claude --version 2>/dev/null) || out=""
  else
    out=""
  fi
  first=$(printf '%s\n' "$out" | awk '{print $1; exit}')
  if [ -n "$first" ]; then
    printf '%s' "$first"
  else
    printf '%s' "unknown"
  fi
}

same_path() {
  # True if two paths name the same directory (physical compare when both
  # exist, string compare otherwise).
  local a="$1" b="$2" pa pb
  [ "$a" = "$b" ] && return 0
  [ -d "$a" ] && [ -d "$b" ] || return 1
  pa=$(cd "$a" 2>/dev/null && pwd -P) || return 1
  pb=$(cd "$b" 2>/dev/null && pwd -P) || return 1
  [ "$pa" = "$pb" ]
}

valid_name() {
  case "$1" in
    "") return 1 ;;
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
  return 0
}

rc_file() {
  case "${SHELL##*/}" in
    zsh)  printf '%s' "${HOME}/.zshrc" ;;
    bash) if [ "$OS" = "macos" ]; then printf '%s' "${HOME}/.bash_profile"
          else printf '%s' "${HOME}/.bashrc"; fi ;;
    *)    printf '' ;;
  esac
}

usage() {
  cat <<EOF
claude-profiles.sh v${VERSION}

Usage: ./claude-profiles.sh <command> [options]

Commands:
  plan        Show exactly what apply would do. Changes nothing. Start here.
  apply       Create the profiles and shared directory.
  verify      Inspect the current state and report problems.
  rollback    Remove the profiles and shared dir created by this script.

Options:
  --main NAME       name of the profile that inherits your current login
                    (default: ${MAIN}, so ~/.claude-${MAIN})
  --second NAME     name of the second profile (default: ${SECOND})
  --share MODE      full | safe   (default: ${SHARE_MODE})
                      full = share transcripts, history, checkpoints, skills
                      safe = share plans/skills only, transcripts stay
                             per-profile. history.jsonl (every prompt you
                             typed) is still shared either way. See README.md.
  --source DIR      profile to seed from (default: ${SOURCE})
  --shell           append the launcher functions to your shell rc file
                    (without this, the snippet is written out for you to add)
  --no-backup       skip the tar backup (only sensible on a re-run of apply)
  --yes             skip confirmation prompts. REQUIRED when there is no
                    terminal to answer them, e.g. when run from Claude Code.
  -h, --help        this text

After a successful apply, --main/--second/--share/--source are remembered in
~/.claude-shared/.claude-profiles.conf, so verify and rollback do not need
them repeated. Explicit flags always win over the remembered values.

Examples:
  ./claude-profiles.sh plan
  ./claude-profiles.sh apply --shell
  ./claude-profiles.sh verify
EOF
}

# ------------------------------------------------------------------- parse --

[ $# -eq 0 ] && { usage; exit 0; }

case "${1:-}" in
  plan|apply|verify|rollback) CMD="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown command '${1}'. Try --help." ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --main)   MAIN="${2:?--main needs a name}";   MAIN_SET=1;   shift 2 ;;
    --second) SECOND="${2:?--second needs a name}"; SECOND_SET=1; shift 2 ;;
    --share)  SHARE_MODE="${2:?--share needs full or safe}"; SHARE_SET=1; shift 2 ;;
    --source) SOURCE="${2:?--source needs a path}"; SOURCE_SET=1; shift 2 ;;
    --shell)  DO_SHELL=1; shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --yes)    ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '${1}'. Try --help." ;;
  esac
done

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *) die "unsupported OS '$(uname -s)'. See README.md, section Windows." ;;
esac

# Remembered settings from a previous apply. Explicit flags override.
CONF_FILE="${SHARED}/.claude-profiles.conf"
if [ -f "$CONF_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      MAIN)       if [ "$MAIN_SET"   -eq 0 ]; then MAIN="$v";       fi ;;
      SECOND)     if [ "$SECOND_SET" -eq 0 ]; then SECOND="$v";     fi ;;
      SHARE_MODE) if [ "$SHARE_SET"  -eq 0 ]; then SHARE_MODE="$v"; fi ;;
      SOURCE)     if [ "$SOURCE_SET" -eq 0 ]; then SOURCE="$v";     fi ;;
      CLAUDE_VERSION) CONF_CLAUDE_VERSION="$v" ;;
    esac
  done < "$CONF_FILE"
  CONF_LOADED=1
fi

case "$SHARE_MODE" in
  full) SHARE_DATA="$DATA_FULL" ;;
  safe) SHARE_DATA="$DATA_SAFE" ;;
  *) die "--share must be 'full' or 'safe', got '${SHARE_MODE}'" ;;
esac

valid_name "$MAIN"   || die "--main must be letters, digits, '_' or '-', got '${MAIN}'"
valid_name "$SECOND" || die "--second must be letters, digits, '_' or '-', got '${SECOND}'"
[ "$MAIN" = "$SECOND" ] && die "--main and --second must differ"

SOURCE="${SOURCE%/}"
MAIN_DIR="${HOME}/.claude-${MAIN}"
SECOND_DIR="${HOME}/.claude-${SECOND}"
SHARE_ALL="${SHARE_DATA} ${CONFIG_SHARED}"

for d in "$MAIN_DIR" "$SECOND_DIR" "$SHARED"; do
  if same_path "$SOURCE" "$d"; then
    die "source '${SOURCE}' is one of the directories this script manages. Refusing."
  fi
done

# The app-state file that belongs to SOURCE. With CLAUDE_CONFIG_DIR unset,
# Claude Code keeps it at ~/.claude.json, next to (not inside) ~/.claude.
# With CLAUDE_CONFIG_DIR set, it lives inside the config dir.
SRC_STATE=""
if [ -f "${SOURCE}/.claude.json" ]; then
  SRC_STATE="${SOURCE}/.claude.json"
elif same_path "$SOURCE" "${HOME}/.claude" && [ -f "${HOME}/.claude.json" ]; then
  SRC_STATE="${HOME}/.claude.json"
fi

SNIPPET_FILE="${HOME}/.claude-profiles.sh"

# ---------------------------------------------------------------- preflight --

preflight() {
  hdr "Preflight"

  [ -d "$SOURCE" ] || die "source profile '${SOURCE}' does not exist.
       If you have never run Claude Code, run it once and log in first."
  ok "source profile found: ${SOURCE}"

  if [ ! -e "${SOURCE}/settings.json" ] && [ ! -e "${SOURCE}/projects" ] \
     && [ ! -e "${SOURCE}/.credentials.json" ]; then
    warn "'${SOURCE}' has none of settings.json, projects/, .credentials.json."
    warn "Is it really a Claude Code config directory?"
  fi

  if [ -n "$SRC_STATE" ]; then
    ok "app state found: ${SRC_STATE}"
  else
    info "no .claude.json found for the source profile (fresh install?)"
  fi

  if command -v claude >/dev/null 2>&1; then
    ok "claude binary: $(command -v claude)"
  else
    warn "'claude' is not on PATH. The setup will still work, but you will"
    warn "need the binary before you can log the second account in."
  fi

  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    warn "CLAUDE_CONFIG_DIR is already set to '${CLAUDE_CONFIG_DIR}'."
    warn "If it is exported from your shell rc it will override the launcher"
    warn "functions this script writes. (Being set because you are running this"
    warn "from inside a claude-<profile> session is fine.)"
  fi

  if [ "$ASSUME_YES" -eq 0 ] && ! have_tty; then
    warn "no terminal available for confirmation prompts. 'apply' and"
    warn "'rollback' will stop at their prompt unless you pass --yes."
  fi

  local d
  for d in "$MAIN_DIR" "$SECOND_DIR" "$SHARED"; do
    if [ -e "$d" ]; then
      warn "'${d}' already exists. apply is additive and will not delete it,"
      warn "but check 'verify' output afterwards."
    fi
  done

  if [ "$OS" = "macos" ]; then
    info "macOS: credentials live in the Keychain, keyed to the config dir."
    info "The '${MAIN}' profile will prompt for a browser login on first"
    info "launch. That is fine. Log in with the SAME account. Never /logout."
  fi

  # Disk space: the shared data is copied, and the backup is a compressed
  # copy of the whole source. Budget for the worst case of both.
  local p need=0 src_kb have total
  for p in $SHARE_ALL; do
    [ -e "${SOURCE}/${p}" ] || continue
    [ -e "${SHARED}/${p}" ] && continue
    need=$((need + $(dir_kb "${SOURCE}/${p}")))
  done
  src_kb=$(dir_kb "$SOURCE")
  total=$need
  [ "$DO_BACKUP" -eq 1 ] && total=$((total + src_kb))
  have=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
  info "source profile size: $(kb_h "$src_kb")"
  info "disk: copy needs ~$(kb_h "$need"), backup up to $(kb_h "$src_kb"), free $(kb_h "$have")"
  if [ "${have:-0}" -lt "$total" ]; then
    warn "not enough free space for the copy plus the backup."
    if [ "$CMD" = "apply" ]; then
      die "free up space, or move the backup elsewhere, then re-run."
    fi
  fi
}

# ------------------------------------------------------------------ backup --

do_backup() {
  hdr "Backup"
  if [ "$DO_BACKUP" -eq 0 ]; then
    info "skipped (--no-backup)"
    return 0
  fi

  local stamp archive parent base st
  stamp="$(date +%Y%m%d-%H%M%S)"
  archive="${BACKUP_ROOT}/claude-${stamp}.tar.gz"
  parent=$(dirname "$SOURCE")
  base=$(basename "$SOURCE")

  info "archive:  ${archive}"
  info "contents: ${SOURCE}${SRC_STATE:+ and ${SRC_STATE}}"
  info "mode 600, in a mode 700 directory: the archive contains credentials"

  if [ "$DRY" -eq 1 ]; then
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} mkdir -p ${BACKUP_ROOT} && chmod 700 ${BACKUP_ROOT}"
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} (umask 077; tar czf ${archive} -C ${parent} ${base}${SRC_STATE:+ -C $(dirname "$SRC_STATE") $(basename "$SRC_STATE")})"
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} tar tzf ${archive} >/dev/null   # read-back check"
    return 0
  fi

  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"

  st=0
  (
    umask 077
    if [ -n "$SRC_STATE" ]; then
      tar czf "$archive" -C "$parent" "$base" \
        -C "$(dirname "$SRC_STATE")" "$(basename "$SRC_STATE")"
    else
      tar czf "$archive" -C "$parent" "$base"
    fi
  ) 2>"${archive}.log" || st=$?

  if [ "$st" -ne 0 ]; then
    if [ "$st" -eq 1 ] && [ -s "$archive" ]; then
      warn "tar exit 1: some files changed or were unreadable while archiving."
      warn "Usual cause: a Claude Code session is running. Details: ${archive}.log"
    else
      die "backup FAILED (tar exit ${st}). See ${archive}.log. Nothing else was changed."
    fi
  fi

  tar tzf "$archive" >/dev/null 2>&1 \
    || die "backup archive does not read back cleanly: ${archive}. Not continuing."

  [ -s "${archive}.log" ] || rm -f "${archive}.log"
  ok "backup written and read back ($(du -sh "$archive" | cut -f1))"
  printf '%s\n' "$archive" > "${BACKUP_ROOT}/.latest"
}

# ------------------------------------------------------------------ shared --

seed_shared() {
  hdr "Shared directory: ${SHARED}"
  run mkdir -p "$SHARED"

  local p src tmp
  for p in $SHARE_ALL; do
    src="${SOURCE}/${p}"
    tmp="${SHARED}/.${p}.partial"
    if [ -e "${SHARED}/${p}" ]; then
      info "keep   ${p} (already in shared dir, left alone)"
      continue
    fi
    if [ -e "$tmp" ]; then
      info "clean  ${p} (stale partial copy from an interrupted run)"
      run rm -rf "$tmp"
    fi
    if [ -e "$src" ]; then
      # Copy to a temp name and rename on completion, so an interrupted
      # copy never masquerades as a finished one on the next run.
      # -p keeps mtimes: Claude Code orders --resume and runs the
      # retention sweep by file age.
      info "seed   ${p} <- ${src}"
      run cp -Rp "$src" "$tmp"
      run mv "$tmp" "${SHARED}/${p}"
    else
      case "$p" in
        *.jsonl) info "create ${p} (empty, source had none)"
                 run touch "${SHARED}/${p}" ;;
        *)       info "create ${p}/ (empty, source had none)"
                 run mkdir -p "${SHARED}/${p}" ;;
      esac
    fi
  done
}

write_conf() {
  if [ "$DRY" -eq 1 ]; then
    info "would record MAIN/SECOND/SHARE_MODE/SOURCE/CLAUDE_VERSION in ${CONF_FILE}"
    return 0
  fi
  {
    printf 'VERSION=%s\n'    "$VERSION"
    printf 'MAIN=%s\n'       "$MAIN"
    printf 'SECOND=%s\n'     "$SECOND"
    printf 'SHARE_MODE=%s\n' "$SHARE_MODE"
    printf 'SOURCE=%s\n'     "$SOURCE"
    printf 'CLAUDE_VERSION=%s\n' "$(claude_version)"
  } > "$CONF_FILE"
  ok "recorded settings in ${CONF_FILE}"
}

# ---------------------------------------------------------------- profiles --

make_profile() {
  local dir="$1" label="$2" inherit="$3"

  hdr "Profile: ${dir}"
  run mkdir -p "$dir"

  local p src
  for p in $CONFIG_COPIED; do
    src="${SOURCE}/${p}"
    if [ -e "${dir}/${p}" ]; then
      info "keep   ${p} (already present)"
    elif [ -e "$src" ]; then
      info "copy   ${p}"
      run cp -Rp "$src" "${dir}/${p}"
    fi
  done

  if [ "$inherit" = "yes" ]; then
    if [ -f "${dir}/.credentials.json" ]; then
      info "keep   .credentials.json (already present)"
    elif [ -f "${SOURCE}/.credentials.json" ]; then
      info "copy   .credentials.json  (so '${label}' stays logged in as your"
      info "       current account and you never have to run /logout)"
      run cp -p "${SOURCE}/.credentials.json" "${dir}/.credentials.json"
      run chmod 600 "${dir}/.credentials.json"
    else
      info "no .credentials.json in source (expected on macOS: Keychain)"
    fi

    if [ -f "${dir}/.claude.json" ]; then
      info "keep   .claude.json (already present)"
    elif [ -n "$SRC_STATE" ]; then
      info "copy   .claude.json <- ${SRC_STATE}"
      info "       (onboarding state, project trust, user-scope MCP servers,"
      info "       account info: '${label}' picks up where ${SOURCE} left off)"
      run cp -p "$SRC_STATE" "${dir}/.claude.json"
    fi
  else
    info "no credentials or app state copied: '${label}' starts empty and"
    info "       will do a fresh browser login"
  fi

  for p in $SHARE_ALL; do
    if [ -L "${dir}/${p}" ]; then
      info "link   ${p} (already linked)"
      continue
    fi
    if [ -e "${dir}/${p}" ]; then
      warn "'${dir}/${p}' exists and is NOT a symlink."
      warn "Refusing to replace real data. Move it aside, then re-run apply."
      continue
    fi
    info "link   ${p} -> ${SHARED}/${p}"
    run ln -s "${SHARED}/${p}" "${dir}/${p}"
  done
}

# ------------------------------------------------------------------- shell --

write_snippet() {
  hdr "Launcher functions"
  info "file: ${SNIPPET_FILE}"

  local body
  body=$(cat <<EOF
# ---8<--- claude-profiles v${VERSION} ---8<---
# Generated by claude-profiles.sh. Safe to edit. Sourced by bash and zsh.
# Each launcher points Claude Code at its own config directory, which holds
# that profile's credentials and app state.

claude-${MAIN}() {
  CLAUDE_CONFIG_DIR="${MAIN_DIR}" command claude "\$@"
}

claude-${SECOND}() {
  CLAUDE_CONFIG_DIR="${SECOND_DIR}" command claude "\$@"
}

# Guard rail: bare 'claude' would silently use ~/.claude, the untouched
# pre-migration profile. Force an explicit choice, EXCEPT when a profile has
# already been chosen via CLAUDE_CONFIG_DIR. That exception is what lets
# 'claude --version', 'claude mcp ...' and similar work inside a session
# started with claude-${MAIN} or claude-${SECOND}, since the session's shell
# inherits the variable.
claude() {
  if [ -n "\${CLAUDE_CONFIG_DIR:-}" ]; then
    command claude "\$@"
    return
  fi
  printf '%s\n' "Pick a profile: claude-${MAIN} or claude-${SECOND}" >&2
  printf '%s\n' "(bare 'claude' would use ~/.claude, the old profile." >&2
  printf '%s\n' " Set CLAUDE_CONFIG_DIR yourself to override this guard.)" >&2
  return 1
}
# ---8<--- end claude-profiles ---8<---
EOF
)

  if [ "$DRY" -eq 1 ]; then
    printf '%s\n' "  ${C_DIM}would write:${C_OFF}"
    printf '%s\n' "$body" | sed 's/^/    /'
  else
    printf '%s\n' "$body" > "$SNIPPET_FILE"
    ok "written"
  fi

  local rc line
  rc=$(rc_file)
  line=". \"${SNIPPET_FILE}\""

  if [ -z "$rc" ]; then
    warn "unrecognised shell '${SHELL}'. Add this line to your rc file yourself:"
    warn "  ${line}"
    return 0
  fi

  if [ -f "$rc" ] && grep -qF "$SNIPPET_FILE" "$rc" 2>/dev/null; then
    ok "${rc} already sources it"
    return 0
  fi

  if [ "$DO_SHELL" -eq 1 ]; then
    if [ "$DRY" -eq 1 ]; then
      printf '%s\n' "  ${C_DIM}would append to ${rc}:${C_OFF} ${line}"
    else
      printf '\n# claude-profiles\n%s\n' "$line" >> "$rc"
      ok "appended source line to ${rc}"
    fi
  else
    say ""
    say "  Add this line to ${rc} yourself, then open a new terminal:"
    say ""
    say "      ${line}"
    say ""
    say "  (or re-run with --shell to have it appended for you)"
  fi
}

# ------------------------------------------------------------------ verify --

check_link() {
  local dir="$1" p="$2" want="${SHARED}/$2"
  if [ ! -L "${dir}/${p}" ]; then
    if [ -e "${dir}/${p}" ]; then
      warn "${dir}/${p} is real data, not a link to the shared copy"
    else
      warn "${dir}/${p} is missing"
    fi
    return 1
  fi
  local target
  target=$(readlink "${dir}/${p}")
  if [ "$target" != "$want" ]; then
    warn "${dir}/${p} points at '${target}', expected '${want}'"
    return 1
  fi
  if [ ! -e "${dir}/${p}" ]; then
    warn "${dir}/${p} is a dangling link: '${want}' does not exist"
    return 1
  fi
  return 0
}

profile_launched() {
  # Claude Code writes these on first run. If none exist, the profile has
  # never been launched and there is nothing meaningful to inspect yet.
  local dir="$1" m
  for m in .claude.json sessions shell-snapshots stats-cache.json cache debug backups statsig; do
    [ -e "${dir}/${m}" ] && return 0
  done
  return 1
}

json_num() {
  # $1 = file, $2 = key. Crude but dependency-free.
  [ -f "$1" ] || { printf '%s' "unset"; return; }
  local v
  v=$(tr -d ' \t\n' < "$1" | sed -n "s/.*\"$2\":\([0-9]*\).*/\1/p")
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "unset"
}

refs_old_profile() {
  # Does a settings file point at absolute paths under ~/.claude ?
  [ -f "$1" ] || return 1
  # Literal patterns on purpose: we are looking for these exact spellings.
  # shellcheck disable=SC2088,SC2016
  grep -qF '~/.claude/' "$1" 2>/dev/null && return 0
  # shellcheck disable=SC2016
  grep -qF '$HOME/.claude/' "$1" 2>/dev/null && return 0
  grep -qF "${HOME}/.claude/" "$1" 2>/dev/null && return 0
  return 1
}

record_conf_version() {
  # Rewrite just the CLAUDE_VERSION= line of CONF_FILE. Portable: no sed -i.
  # Build the new content in a temp file in the same directory, then mv.
  local newv="$1" tmp line wrote=0
  tmp="$(dirname "$CONF_FILE")/.$(basename "$CONF_FILE").tmp.$$"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      CLAUDE_VERSION=*) printf 'CLAUDE_VERSION=%s\n' "$newv" >> "$tmp"; wrote=1 ;;
      *)                printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$CONF_FILE"
  [ "$wrote" -eq 1 ] || printf 'CLAUDE_VERSION=%s\n' "$newv" >> "$tmp"
  mv "$tmp" "$CONF_FILE"
  ok "updated recorded Claude Code version to ${newv} in ${CONF_FILE}"
}

do_verify() {
  local problems=0
  local cur
  cur=$(claude_version)

  hdr "Directories"
  local d
  for d in "$SOURCE" "$MAIN_DIR" "$SECOND_DIR" "$SHARED"; do
    if [ -d "$d" ]; then ok "$d"; else warn "missing: $d"; problems=$((problems+1)); fi
  done
  if [ "$CONF_LOADED" -eq 1 ]; then
    ok "settings read from ${CONF_FILE} (main=${MAIN} second=${SECOND} share=${SHARE_MODE})"
  else
    info "no ${CONF_FILE}; checking against defaults/flags (main=${MAIN} second=${SECOND} share=${SHARE_MODE})"
  fi

  hdr "Source profile untouched"
  local p touched=0
  for p in $SHARE_ALL $PRIVATE; do
    if [ -L "${SOURCE}/${p}" ]; then
      case "$(readlink "${SOURCE}/${p}")" in
        "${SHARED}"/*|"${MAIN_DIR}"/*|"${SECOND_DIR}"/*)
          warn "${SOURCE}/${p} is a symlink INTO the new setup. The script never does this."
          touched=1 ;;
      esac
    fi
  done
  if [ "$touched" -eq 0 ]; then ok "nothing in ${SOURCE} points at the new directories"
  else problems=$((problems+1)); fi

  hdr "Shared links"
  local dir
  for dir in "$MAIN_DIR" "$SECOND_DIR"; do
    [ -d "$dir" ] || continue
    local bad=0
    for p in $SHARE_ALL; do
      check_link "$dir" "$p" || bad=$((bad+1))
    done
    if [ "$bad" -eq 0 ]; then
      ok "$(basename "$dir"): all $(printf '%s' "$SHARE_ALL" | wc -w | tr -d ' ') paths linked"
    else
      problems=$((problems+bad))
    fi
  done

  hdr "Credential isolation"
  for dir in "$MAIN_DIR" "$SECOND_DIR"; do
    [ -d "$dir" ] || continue
    for p in $PRIVATE; do
      if [ -L "${dir}/${p}" ]; then
        warn "$(basename "$dir")/${p} is a SYMLINK. It must be a real, per-profile"
        warn "file or directory or the two profiles are not isolated."
        problems=$((problems+1))
      fi
    done
    if [ -f "${dir}/.credentials.json" ]; then
      ok "$(basename "$dir"): own credentials file"
    else
      info "$(basename "$dir"): no credentials file (macOS Keychain, or not logged in yet)"
    fi
  done
  if [ "$OS" = "macos" ] && command -v security >/dev/null 2>&1; then
    local n
    n=$(security dump-keychain 2>/dev/null | grep -c '"svce"<blob>="Claude Code' || true)
    info "macOS Keychain entries starting 'Claude Code': ${n:-0}"
    info "(one per logged-in config dir, entries are keyed to CLAUDE_CONFIG_DIR;"
    info " ${SOURCE} may hold one as well if it was ever logged in via Keychain)"
  fi

  hdr "Per-profile app state (.claude.json)"
  info "With CLAUDE_CONFIG_DIR set, Claude Code keeps this inside the profile"
  info "dir. If a launched profile has none there, that version fell back to"
  # shellcheck disable=SC2088
  info "~/.claude.json, which both profiles would share: NOT isolated."
  for dir in "$MAIN_DIR" "$SECOND_DIR"; do
    [ -d "$dir" ] || continue
    if [ -f "${dir}/.claude.json" ]; then
      ok "$(basename "$dir")/.claude.json present (good: state is per-profile)"
    elif profile_launched "$dir"; then
      warn "$(basename "$dir") has been launched but has no .claude.json."
      warn "Your Claude Code version keeps that state at ~/.claude.json instead,"
      warn "which both profiles share. The accounts are NOT isolated."
      warn "Stop here and read README.md, section 'If verify flags .claude.json'."
      problems=$((problems+1))
    else
      info "$(basename "$dir"): not launched yet, nothing to check"
    fi
  done
  # shellcheck disable=SC2088
  [ -f "${HOME}/.claude.json" ] && info "~/.claude.json also exists (old profile's state, expected)"

  hdr "Retention settings"
  local a b
  a=$(json_num "${MAIN_DIR}/settings.json" cleanupPeriodDays)
  b=$(json_num "${SECOND_DIR}/settings.json" cleanupPeriodDays)
  info "${MAIN}: cleanupPeriodDays=${a}   ${SECOND}: cleanupPeriodDays=${b}"
  if [ "$a" != "$b" ]; then
    warn "These differ. Both profiles sweep the SAME shared directories,"
    warn "so the shorter period wins and will delete the other's data."
    warn "Set them to the same value in both settings.json files."
    problems=$((problems+1))
  else
    ok "matching (or both unset, which is the 30-day default)"
  fi

  hdr "Settings that still point at ${SOURCE}"
  local refs=0
  for dir in "$MAIN_DIR" "$SECOND_DIR"; do
    if refs_old_profile "${dir}/settings.json"; then
      warn "$(basename "$dir")/settings.json references paths under ~/.claude/"
      warn "(statusLine command, hooks, or similar). Those keep working only"
      warn "while ${SOURCE} exists. Repoint them before you delete it."
      refs=1
    fi
  done
  [ "$refs" -eq 0 ] && ok "none (safe to delete ${SOURCE} later, once you are happy)"

  hdr "Shell"
  local rc
  rc=$(rc_file)
  if [ -f "$SNIPPET_FILE" ]; then
    ok "$SNIPPET_FILE"
    if ! grep -q "^claude-${MAIN}()" "$SNIPPET_FILE" \
       || ! grep -q "^claude-${SECOND}()" "$SNIPPET_FILE"; then
      warn "snippet does not define claude-${MAIN} and claude-${SECOND};"
      warn "it was written for different names. Re-run apply to regenerate."
      problems=$((problems+1))
    fi
  else
    warn "missing: $SNIPPET_FILE"
    problems=$((problems+1))
  fi
  if [ -z "$rc" ]; then
    info "shell '${SHELL}' is not bash or zsh; cannot check whether it sources the snippet"
  elif [ -f "$rc" ] && grep -qF "$SNIPPET_FILE" "$rc" 2>/dev/null; then
    ok "${rc} sources the snippet (open a new terminal to pick it up)"
  else
    warn "${rc} does not source ${SNIPPET_FILE}. Add:  . \"${SNIPPET_FILE}\""
    problems=$((problems+1))
  fi

  hdr "Claude Code version"
  if [ "$CONF_LOADED" -eq 1 ]; then
    info "recorded at apply time : ${CONF_CLAUDE_VERSION:-unknown}"
    info "current                : ${cur}"
    if [ "${CONF_CLAUDE_VERSION:-}" != "$cur" ]; then
      warn "recorded and current Claude Code versions differ. The checks above"
      warn "just ran against the new version; this design depends on"
      warn "documented behaviour that can change between versions. Not a problem."
    else
      ok "matches the version recorded at apply time"
    fi
  else
    info "no ${CONF_FILE}; nothing recorded to compare against ${cur}"
  fi

  hdr "Result"
  if [ "$problems" -eq 0 ]; then
    ok "no problems found"
  else
    warn "${problems} problem(s) above"
    return 1
  fi

  if [ "$CONF_LOADED" -eq 1 ] && [ "${CONF_CLAUDE_VERSION:-}" != "$cur" ]; then
    record_conf_version "$cur"
  fi
}

# ---------------------------------------------------------------- rollback --

do_rollback() {
  hdr "Rollback"
  say "This removes ONLY what this script created:"
  say "  ${MAIN_DIR}"
  say "  ${SECOND_DIR}"
  say "  ${SHARED}"
  say "  ${SNIPPET_FILE}"
  say "  the source line it added to your shell rc file (backed up first)"
  say ""
  say "It does NOT touch ${SOURCE} or ~/.claude.json, which were never modified."
  say "Your backups in ${BACKUP_ROOT} are left in place."
  say ""
  warn "Any conversations you had ONLY under the new profiles live in"
  warn "${SHARED} and will be lost. Copy them out first if you want them."

  local d
  for d in "$MAIN_DIR" "$SECOND_DIR"; do
    if [ -d "${d}/sessions" ] && [ -n "$(ls -A "${d}/sessions" 2>/dev/null)" ]; then
      warn "${d}/sessions is not empty: a Claude Code session may still be"
      warn "running in that profile. Quit it before continuing."
    fi
  done
  if [ "$OS" = "macos" ]; then
    info "macOS: the profiles' Keychain entries ('Claude Code-credentials…')"
    info "are not removed. Delete them in Keychain Access if you want."
  fi

  confirm "Remove the five items above?" || { say "aborted"; return 0; }

  for d in "$MAIN_DIR" "$SECOND_DIR" "$SHARED"; do
    same_path "$d" "$SOURCE" && die "refusing: '${d}' is the source profile"
    [ -d "$d" ] && { info "removing ${d}"; rm -rf "$d"; }
  done
  [ -f "$SNIPPET_FILE" ] && { info "removing ${SNIPPET_FILE}"; rm -f "$SNIPPET_FILE"; }

  hdr "Shell rc file"
  local rc_summary="no shell rc file was touched"
  local rc src_line
  rc=$(rc_file)
  src_line=". \"${SNIPPET_FILE}\""
  if [ -z "$rc" ]; then
    info "shell '${SHELL}' is not bash or zsh; nothing to check. If you added"
    info "the source line by hand, remove it yourself."
  elif [ ! -f "$rc" ]; then
    info "no ${rc}; nothing to clean up"
    rc_summary="${rc} does not exist; nothing to clean up"
  else
    mkdir -p "$BACKUP_ROOT"
    chmod 700 "$BACKUP_ROOT"
    local stamp bkp
    stamp="$(date +%Y%m%d-%H%M%S)"
    bkp="${BACKUP_ROOT}/$(basename "$rc").before-rollback-${stamp}"
    cp -p "$rc" "$bkp"
    info "backed up ${rc} to ${bkp}"

    # Preserve the rc file's mode: cp -p onto the temp name first (mode
    # carries with the copy), then truncate and refill its content. The
    # redirection below only rewrites bytes, never the file's own mode.
    local tmp line removed=0 have_hold=0 hold=""
    tmp="$(dirname "$rc")/.$(basename "$rc").rollback.$$"
    cp -p "$rc" "$tmp"
    : > "$tmp"
    while IFS= read -r line || [ -n "$line" ]; do
      if [ "$line" = "$src_line" ]; then
        if [ "$have_hold" -eq 1 ]; then
          have_hold=0; hold=""
          removed=$((removed+2))
        else
          removed=$((removed+1))
        fi
        continue
      fi
      if [ "$have_hold" -eq 1 ]; then
        printf '%s\n' "$hold" >> "$tmp"
        have_hold=0
      fi
      if [ "$line" = "# claude-profiles" ]; then
        hold="$line"
        have_hold=1
        continue
      fi
      printf '%s\n' "$line" >> "$tmp"
    done < "$rc"
    if [ "$have_hold" -eq 1 ]; then
      # A bare marker was the last line of the file: the script wrote it,
      # so it goes too even though nothing followed it.
      removed=$((removed+1))
    fi

    if [ "$removed" -gt 0 ]; then
      mv "$tmp" "$rc"
      ok "removed ${removed} line(s) from ${rc}"
      rc_summary="removed the source line from ${rc} (backup: ${bkp})"
    else
      rm -f "$tmp"
      info "no claude-profiles lines found in ${rc}; left it alone"
      rc_summary="${rc} had no claude-profiles line to remove (backup: ${bkp})"
    fi
  fi

  say ""
  ok "done. ${rc_summary}."
  info "use plain 'claude' again, which uses ${SOURCE} as it always did."
}

# -------------------------------------------------------------------- main --

banner() {
  say ""
  say "claude-profiles v${VERSION}   os=${OS}  share=${SHARE_MODE}"
  [ "$CONF_LOADED" -eq 1 ] && say "  (names/mode/source remembered from ${CONF_FILE}; flags override)"
  say "  source (never modified) : ${SOURCE}"
  say "  main profile            : ${MAIN_DIR}   (inherits current login)"
  say "  second profile          : ${SECOND_DIR}   (fresh login)"
  say "  shared data             : ${SHARED}"
}

case "$CMD" in
  plan)
    DRY=1
    banner
    preflight
    do_backup
    seed_shared
    write_conf
    make_profile "$MAIN_DIR"   "$MAIN"   yes
    make_profile "$SECOND_DIR" "$SECOND" no
    write_snippet
    hdr "Plan complete"
    info "Nothing was changed. Re-run with 'apply' to execute."
    ;;
  apply)
    DRY=0
    banner
    preflight
    say ""
    say "About to create the three directories above. ${SOURCE} is only read."
    confirm "Proceed?" || { say "aborted"; exit 1; }
    do_backup
    seed_shared
    write_conf
    make_profile "$MAIN_DIR"   "$MAIN"   yes
    make_profile "$SECOND_DIR" "$SECOND" no
    write_snippet
    hdr "Next steps"
    say "  1. Open a NEW terminal (so the launcher functions load)."
    say "  2. Run:  claude-${MAIN}"
    say "     It should already be logged in as your current account."
    say "     If it asks you to log in, log in with the SAME account."
    say "     Do NOT run /logout, in any profile, at any point."
    say "  3. Quit, then run:  claude-${SECOND}"
    say "     Log in with the OTHER account when the browser opens."
    say "  4. Run:  ./claude-profiles.sh verify"
    say "     Pay attention to the .claude.json section."
    say "  5. Confirm sharing works: start a session in one profile, then"
    say "     run  claude-${SECOND} --resume  in the same project directory."
    say ""
    say "  ${SOURCE} is untouched and still works. Once you are happy with"
    say "  the new setup, you can delete it to reclaim the duplicated space"
    say "  (verify tells you if a settings file still points into it)."
    ;;
  verify)
    banner
    do_verify
    ;;
  rollback)
    banner
    do_rollback
    ;;
esac
