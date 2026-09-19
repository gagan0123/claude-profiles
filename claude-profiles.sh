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

set -euo pipefail

VERSION="1.0.0"

# ---------------------------------------------------------------- defaults --

MAIN="work"
SECOND="personal"
SOURCE="${HOME}/.claude"
SHARED="${HOME}/.claude-shared"
BACKUP_ROOT="${HOME}/.claude-backups"
SHARE_MODE="full"
DO_SHELL=0
ASSUME_YES=0
CMD=""

# Session data. "full" gives you cross-profile --resume and --continue.
# "safe" deliberately leaves transcripts and checkpoints per-profile so that
# one account's conversations never become readable under the other.
DATA_FULL="projects history.jsonl file-history plans tasks paste-cache image-cache session-env"
DATA_SAFE="history.jsonl plans paste-cache"

# Personal config worth having identical in both profiles.
CONFIG_SHARED="skills commands agents workflows rules output-styles plugins"

# Config copied once into each profile, then free to diverge.
CONFIG_COPIED="settings.json CLAUDE.md keybindings.json themes"

# Deliberately NOT shared, ever:
#   .credentials.json  the whole point of the separation
#   .claude.json       holds the OAuth session and per-project trust
#   sessions/          live-session detection; sharing invites cross-cleanup

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

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  printf '\n%s ' "$1 [y/N]"
  read -r reply </dev/tty || reply=""
  case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
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
                      safe = share history/plans/skills only, transcripts stay
                             per-profile. Read README.md before choosing.
  --source DIR      profile to seed from (default: ${SOURCE})
  --shell           append the launcher functions to your shell rc file
                    (without this, the snippet is written out for you to add)
  --yes             skip confirmation prompts
  -h, --help        this text

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
    --main)   MAIN="${2:?--main needs a name}"; shift 2 ;;
    --second) SECOND="${2:?--second needs a name}"; shift 2 ;;
    --share)  SHARE_MODE="${2:?--share needs full or safe}"; shift 2 ;;
    --source) SOURCE="${2:?--source needs a path}"; shift 2 ;;
    --shell)  DO_SHELL=1; shift ;;
    --yes)    ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '${1}'. Try --help." ;;
  esac
done

case "$SHARE_MODE" in
  full) SHARE_DATA="$DATA_FULL" ;;
  safe) SHARE_DATA="$DATA_SAFE" ;;
  *) die "--share must be 'full' or 'safe', got '${SHARE_MODE}'" ;;
esac

[ "$MAIN" = "$SECOND" ] && die "--main and --second must differ"

MAIN_DIR="${HOME}/.claude-${MAIN}"
SECOND_DIR="${HOME}/.claude-${SECOND}"
SHARE_ALL="${SHARE_DATA} ${CONFIG_SHARED}"

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *) die "unsupported OS '$(uname -s)'. See README.md, section Windows." ;;
esac

# ---------------------------------------------------------------- preflight --

preflight() {
  hdr "Preflight"

  [ -d "$SOURCE" ] || die "source profile '${SOURCE}' does not exist.
       If you have never run Claude Code, run it once and log in first."
  ok "source profile found: ${SOURCE}"

  if command -v claude >/dev/null 2>&1; then
    ok "claude binary: $(command -v claude)"
  else
    warn "'claude' is not on PATH. The setup will still work, but you will"
    warn "need the binary before you can log the second account in."
  fi

  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    warn "CLAUDE_CONFIG_DIR is already set to '${CLAUDE_CONFIG_DIR}'."
    warn "Unset it or make sure it is not exported from your shell rc,"
    warn "or it will override the launcher functions this script writes."
  fi

  local d
  for d in "$MAIN_DIR" "$SECOND_DIR" "$SHARED"; do
    if [ -e "$d" ]; then
      warn "'${d}' already exists. apply is additive and will not delete it,"
      warn "but check 'verify' output afterwards."
    fi
  done

  if [ "$OS" = "macos" ]; then
    info "macOS: credentials live in the Keychain, not in the profile dir."
    info "The '${MAIN}' profile may still prompt for a browser login on first"
    info "launch. That is fine. Log in with the SAME account. Never /logout."
  fi

  local sz
  sz=$(du -sh "$SOURCE" 2>/dev/null | cut -f1 || echo "?")
  info "source profile size: ${sz} (a copy of the data is made, not a move)"
}

# ------------------------------------------------------------------ backup --

do_backup() {
  local stamp archive
  stamp="$(date +%Y%m%d-%H%M%S)"
  archive="${BACKUP_ROOT}/claude-${stamp}.tar.gz"

  hdr "Backup"
  info "archive: ${archive}"

  run mkdir -p "$BACKUP_ROOT"
  if [ "$DRY" -eq 1 ]; then
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} tar czf ${archive} ~/.claude ~/.claude.json"
  else
    tar czf "$archive" \
      -C "$HOME" \
      $( [ -d "${HOME}/.claude" ] && echo ".claude" ) \
      $( [ -f "${HOME}/.claude.json" ] && echo ".claude.json" ) \
      2>/dev/null || warn "tar reported errors (often harmless: sockets, live files)"
    [ -f "$archive" ] && ok "backup written ($(du -sh "$archive" | cut -f1))"
    printf '%s\n' "$archive" > "${BACKUP_ROOT}/.latest"
  fi
}

# ------------------------------------------------------------------ shared --

seed_shared() {
  hdr "Shared directory: ${SHARED}"
  run mkdir -p "$SHARED"

  local p src
  for p in $SHARE_ALL; do
    src="${SOURCE}/${p}"
    if [ -e "${SHARED}/${p}" ]; then
      info "keep   ${p} (already in shared dir, left alone)"
      continue
    fi
    if [ -e "$src" ]; then
      info "seed   ${p} <- ${src}"
      run cp -R "$src" "${SHARED}/${p}"
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

# ---------------------------------------------------------------- profiles --

make_profile() {
  local dir="$1" label="$2" want_creds="$3"

  hdr "Profile: ${dir}"
  run mkdir -p "$dir"

  local p src
  for p in $CONFIG_COPIED; do
    src="${SOURCE}/${p}"
    if [ -e "${dir}/${p}" ]; then
      info "keep   ${p} (already present)"
    elif [ -e "$src" ]; then
      info "copy   ${p}"
      run cp -R "$src" "${dir}/${p}"
    fi
  done

  if [ "$want_creds" = "yes" ] && [ -f "${SOURCE}/.credentials.json" ]; then
    if [ -f "${dir}/.credentials.json" ]; then
      info "keep   .credentials.json (already present)"
    else
      info "copy   .credentials.json  (so '${label}' stays logged in as your"
      info "       current account and you never have to run /logout)"
      run cp -p "${SOURCE}/.credentials.json" "${dir}/.credentials.json"
      run chmod 600 "${dir}/.credentials.json"
    fi
  elif [ "$want_creds" = "yes" ]; then
    info "no .credentials.json in source (expected on macOS: Keychain)"
  else
    info "no credentials copied: '${label}' will do a fresh browser login"
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

SNIPPET_FILE="${HOME}/.claude-profiles.sh"

write_snippet() {
  hdr "Launcher functions"
  info "file: ${SNIPPET_FILE}"

  local body
  body=$(cat <<EOF
# ---8<--- claude-profiles v${VERSION} ---8<---
# Generated by claude-profiles.sh. Safe to edit.
# Each function points Claude Code at its own credentials directory.

claude-${MAIN}() {
  CLAUDE_CONFIG_DIR="${MAIN_DIR}" command claude "\$@"
}

claude-${SECOND}() {
  CLAUDE_CONFIG_DIR="${SECOND_DIR}" command claude "\$@"
}

# Guard rail: bare 'claude' would use ~/.claude, which is your untouched
# pre-migration profile. Force an explicit choice instead.
claude() {
  printf '%s\n' "Pick a profile: claude-${MAIN} or claude-${SECOND}" >&2
  printf '%s\n' "(bare 'claude' uses ~/.claude, the old profile)" >&2
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

  local rc=""
  case "${SHELL##*/}" in
    zsh)  rc="${HOME}/.zshrc" ;;
    bash) [ "$OS" = "macos" ] && rc="${HOME}/.bash_profile" || rc="${HOME}/.bashrc" ;;
    *)    rc="" ;;
  esac

  local line=". \"${SNIPPET_FILE}\""

  if [ -z "$rc" ]; then
    warn "unrecognised shell '${SHELL}'. Add this line to your rc file yourself:"
    warn "  ${line}"
    return
  fi

  if [ -f "$rc" ] && grep -qF "$SNIPPET_FILE" "$rc" 2>/dev/null; then
    ok "${rc} already sources it"
    return
  fi

  if [ "$DO_SHELL" -eq 1 ]; then
    info "appending source line to ${rc}"
    run sh -c "printf '\n# claude-profiles\n%s\n' '${line}' >> '${rc}'"
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
  return 0
}

profile_launched() {
  # Claude Code writes these on first run. If none exist, the profile has
  # never been launched and there is nothing meaningful to inspect yet.
  local dir="$1" m
  for m in .claude.json sessions shell-snapshots stats-cache.json cache debug; do
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

do_verify() {
  local problems=0

  hdr "Directories"
  local d
  for d in "$SOURCE" "$MAIN_DIR" "$SECOND_DIR" "$SHARED"; do
    if [ -d "$d" ]; then ok "$d"; else warn "missing: $d"; problems=$((problems+1)); fi
  done

  hdr "Shared links"
  local dir p
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
    if [ -L "${dir}/.credentials.json" ]; then
      warn "$(basename "$dir")/.credentials.json is a SYMLINK. The two profiles"
      warn "share a login. Delete the link and log that profile in again."
      problems=$((problems+1))
    elif [ -f "${dir}/.credentials.json" ]; then
      ok "$(basename "$dir"): own credentials file"
    else
      info "$(basename "$dir"): no credentials file (macOS Keychain, or not logged in yet)"
    fi
  done

  hdr "Per-profile app state (.claude.json)"
  info "Claude Code may keep this at ~/.claude.json or inside the profile dir,"
  info "depending on version. If it is NOT inside each profile dir, the two"
  info "profiles share OAuth state and the isolation will not hold."
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
  [ -f "${HOME}/.claude.json" ] && info "~/.claude.json also exists (old profile's state)"

  hdr "Retention settings"
  local a b
  a=$(json_num "${MAIN_DIR}/settings.json" cleanupPeriodDays)
  b=$(json_num "${SECOND_DIR}/settings.json" cleanupPeriodDays)
  info "${MAIN}: cleanupPeriodDays=${a}   ${SECOND}: cleanupPeriodDays=${b}"
  if [ "$a" != "$b" ]; then
    warn "These differ. Both profiles sweep the SAME shared projects/ directory,"
    warn "so the shorter period wins and will delete the other's transcripts."
    warn "Set them to the same value in both settings.json files."
    problems=$((problems+1))
  else
    ok "matching (or both unset, which is the 30-day default)"
  fi

  hdr "Shell"
  if [ -f "$SNIPPET_FILE" ]; then ok "$SNIPPET_FILE"; else warn "missing: $SNIPPET_FILE"; fi
  if command -v "claude-${MAIN}" >/dev/null 2>&1; then
    ok "claude-${MAIN} is on PATH in this shell"
  else
    info "claude-${MAIN} not loaded in this shell (open a new terminal, or source the snippet)"
  fi

  hdr "Result"
  if [ "$problems" -eq 0 ]; then
    ok "no problems found"
  else
    warn "${problems} problem(s) above"
    return 1
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
  say ""
  say "It does NOT touch ${SOURCE} or ~/.claude.json, which were never modified."
  say "Your backups in ${BACKUP_ROOT} are left in place."
  say ""
  warn "Any conversations you had ONLY under the new profiles live in"
  warn "${SHARED} and will be lost. Copy them out first if you want them."

  confirm "Remove the four paths above?" || { say "aborted"; return 0; }

  local d
  for d in "$MAIN_DIR" "$SECOND_DIR" "$SHARED"; do
    [ -d "$d" ] && { info "removing ${d}"; rm -rf "$d"; }
  done
  [ -f "$SNIPPET_FILE" ] && { info "removing ${SNIPPET_FILE}"; rm -f "$SNIPPET_FILE"; }

  say ""
  ok "done. Remove the source line from your shell rc file by hand, then"
  info "use plain 'claude' again, which uses ${SOURCE} as it always did."
}

# -------------------------------------------------------------------- main --

banner() {
  say ""
  say "claude-profiles v${VERSION}   os=${OS}  share=${SHARE_MODE}"
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
    confirm "Proceed?" || { say "aborted"; exit 0; }
    do_backup
    seed_shared
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
    say "  the new setup, you can delete it to reclaim the duplicated space."
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
