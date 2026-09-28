#!/usr/bin/env bash
#
# claude-profiles.sh
#
# Sets up any number of isolated Claude Code profiles (e.g. work + personal)
# on one machine that SHARE session transcripts, prompt history, checkpoints,
# skills and plugins, while keeping credentials completely separate.
#
# SAFETY MODEL
#   This script NEVER writes to, deletes from, or symlinks anything inside
#   your existing ~/.claude directory. It only reads from it. Your current
#   setup keeps working exactly as it does today, untouched, as a fallback.
#   The single exception is the `finalize` command, whose whole purpose is to
#   delete ~/.claude once you no longer want the duplicate; it runs eight
#   gates and a confirmation first, and never runs as part of plan or apply.
#   Everything new lives in one directory per profile, plus one shared one:
#
#     ~/.claude-<first>    new profile, inherits your current config + login
#     ~/.claude-<name>     one more per further profile, each a fresh login
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

VERSION="2.1.1"

# ---------------------------------------------------------------- defaults --

# The profile list is a space-separated string, not an array: bash 3.2 has no
# arrays worth the name. The FIRST entry is the profile that inherits the
# current login and app state; every other one starts empty. The conf file
# stores the same list comma-separated, which is also how --profiles takes it.
DEFAULT_PROFILES="work personal"
PROFILES="$DEFAULT_PROFILES"
SOURCE="${HOME}/.claude"
SHARED="${HOME}/.claude-shared"
BACKUP_ROOT="${HOME}/.claude-backups"
SHARE_MODE="full"
DO_SHELL=0
DO_BACKUP=1
ASSUME_YES=0
ADOPT=0
CMD=""
JSON=0
JSON_FILE=""
VERIFY_PROBLEMS=0

# One timestamp for the whole run, so an adopt archive and the .adopted-<stamp>
# directory it came from carry the same name.
RUN_STAMP="$(date +%Y%m%d-%H%M%S)"

# Names whose pre-existing data this run adopts, filled in by preflight().
ADOPTED_NAMES=""

# The positional argument of `add` / `remove`, read in the command case below.
CMD_ARG=""

# --settings NAME=PATH pairs, one space-separated string because bash 3.2 has
# no arrays and no associative arrays: "acme=/path/one clientx=/path/two".
# That is also why a path with whitespace in it is refused at parse time.
SETTINGS_PAIRS=""

# Where make_profile() copies CONFIG_COPIED from. Empty means $SOURCE; `add`
# points it at the first profile when finalize has already removed the source.
TEMPLATE_DIR=""

# Which options were given explicitly on the command line. Anything not given
# explicitly falls back to the values recorded at apply time (see CONF_FILE),
# so `verify` and `rollback` do not need the flags repeated.
PROFILES_SET=0; MAIN_SET=0; SECOND_SET=0; SHARE_SET=0; SOURCE_SET=0
PROFILES_ARG=""; MAIN_ARG=""; SECOND_ARG=""
CONF_LOADED=0
CONF_PROFILES=""
CONF_MAIN=""
CONF_SECOND=""
CONF_CLAUDE_VERSION=""
CONF_SOURCE=""
CONF_FINALIZED=""
CONF_ADOPTED=""

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

# With CLAUDE_CONFIG_DIR set, user-scope instructions come from the profile's
# own CLAUDE.md, and ~/.claude/CLAUDE.md is no longer "yours": it is just the
# .claude/CLAUDE.md of $HOME, an ancestor of every project under it, so it
# loads as project instructions on top of the profile's copy (and, counting
# as a project CLAUDE.md, stops a repo's AGENTS.md from loading). Every
# profile's settings.json gets this path in claudeMdExcludes. Always $HOME's,
# whatever --source says: that is the directory Claude Code walks up through.
ANCESTOR_MD="${HOME}/.claude/CLAUDE.md"

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

# Under --json, none of these print human text: say/hdr go silent, and
# info/ok/warn instead append to the JSON_FILE recorder (see json_add_item,
# defined just above do_verify) grouped under whatever hdr() named last. die()
# is deliberately untouched by JSON: an error always goes to stderr as text,
# JSON output or not.
say()  { [ "$JSON" -eq 1 ] && return 0; printf '%s\n' "$*"; }
info() { if [ "$JSON" -eq 1 ]; then json_add_item info "$*"; return 0; fi
         printf '%s\n' "  $*"; }
ok()   { if [ "$JSON" -eq 1 ]; then json_add_item ok "$*"; return 0; fi
         printf '%s\n' "  ${C_GRN}ok${C_OFF}   $*"; }
warn() { if [ "$JSON" -eq 1 ]; then json_add_item warn "$*"; return 0; fi
         printf '%s\n' "  ${C_YEL}warn${C_OFF} $*" >&2; }
die()  { printf '%s\n' "${C_RED}error${C_OFF} $*" >&2; exit 1; }
hdr()  { if [ "$JSON" -eq 1 ]; then json_add_section "$*"; return 0; fi
         printf '\n%s\n' "$*"; printf '%s\n' "$(printf '%*s' "${#1}" '' | tr ' ' '-')"; }

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

ask_profiles() {
  # Only ever reached from plan/apply, with a usable /dev/tty, no --profiles,
  # --main or --second, no conf file and no --yes: see the resolution block
  # below. Sets PROFILES. Reads /dev/tty like confirm() does, and dies rather
  # than looping if the terminal stops answering, so it still fails closed.
  local reply count name picked i

  say ""
  say "Each profile is a separate Claude Code login with its own credentials,"
  say "launched by its own claude-<name> command. They share transcripts,"
  say "history and skills. The FIRST profile keeps the login you are using"
  say "now; every other one starts empty and does a fresh browser login."
  printf '\n%s ' "Easy setup with $(profiles_english claude- and)? [Y/n]"
  read -r reply </dev/tty || die "could not read from the terminal. Pass --profiles NAME,NAME instead."
  case "$reply" in
    n|N|no|NO|No) ;;
    *) return 0 ;;
  esac

  count=""
  while :; do
    printf '%s ' "How many profiles? [2-9]"
    read -r count </dev/tty || die "could not read from the terminal. Pass --profiles NAME,NAME instead."
    case "$count" in
      [2-9]) break ;;
      *) say "  Enter a whole number from 2 to 9." ;;
    esac
  done

  say ""
  say "  The first name is the profile that keeps your current login."
  picked=""
  i=1
  while [ "$i" -le "$count" ]; do
    printf '%s ' "Name for profile ${i} (launcher will be claude-<name>):"
    read -r name </dev/tty || die "could not read from the terminal. Pass --profiles NAME,NAME instead."
    if ! valid_name "$name"; then
      say "  Letters, digits, '_' and '-' only. Try again."
      continue
    fi
    if in_list "$name" "$picked"; then
      say "  '${name}' is already taken. Try again."
      continue
    fi
    picked="${picked}${picked:+ }${name}"
    i=$((i+1))
  done
  PROFILES="$picked"
  say ""
  say "  Using: $(profiles_english claude- and)"
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

in_list() {
  local needle="$1" hay="$2" x
  for x in $hay; do
    if [ "$x" = "$needle" ]; then return 0; fi
  done
  return 1
}

# -------------------------------------------------------- the profile list --
#
# Everything below treats PROFILES as an ordered, space-separated list of
# names. There are no arrays in bash 3.2, so a directory is derived from a
# name rather than stored, and "the first profile" is a function, not a slot.

profile_dir() { printf '%s' "${HOME}/.claude-${1}"; }

first_profile() {
  local n
  for n in $PROFILES; do printf '%s' "$n"; return 0; done
}

profiles_csv() { printf '%s' "$PROFILES" | tr ' ' ','; }

profiles_count() { printf '%s' "$PROFILES" | wc -w | tr -d ' '; }

profiles_english() {
  # "claude-work or claude-personal", "claude-a, claude-b or claude-c".
  # $1 is a prefix put in front of every name (empty for bare names);
  # $2 is the final conjunction, "or" unless something else is asked for.
  local pre="${1:-}" conj="${2:-or}" n i=0 total out=""
  total=$(profiles_count)
  for n in $PROFILES; do
    i=$((i+1))
    if [ "$i" -eq 1 ]; then out="${pre}${n}"
    elif [ "$i" -eq "$total" ]; then out="${out} ${conj} ${pre}${n}"
    else out="${out}, ${pre}${n}"; fi
  done
  printf '%s' "$out"
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
  status      Fast, read-only daily summary: versions, which profile you are
              in, each profile's account, shared data size, backup count.
  verify      Inspect the current state and report problems.
  rollback    Remove the profiles and shared dir created by this script.
  add NAME[,NAME...]
              Add further profiles to a setup that already exists: create
              each directory the way apply creates a fresh profile, link the
              shared paths, record the names and rewrite the launchers.
  remove NAME Archive one profile's directory to ${BACKUP_ROOT}, delete it,
              drop the name and rewrite the launchers. The shared data and
              the other profiles are not touched.
  finalize    Delete the source profile (${SOURCE}) once the new setup has
              replaced it. IRREVERSIBLE: the only way back is the tar
              archive it takes first. Runs eight gates and asks to confirm.

Options:
  --profiles LIST   comma-separated profile names, at least two, e.g.
                    --profiles work,personal,clientx
                    (default: $(printf '%s' "$DEFAULT_PROFILES" | tr ' ' ','))
                    The FIRST name is the profile that inherits your current
                    login and app state, so ~/.claude-<first> takes over from
                    ${SOURCE}. Every other one starts empty and does a
                    fresh browser login. Names get the claude- prefix only in
                    the launcher functions and directory names.
  --main NAME       deprecated alias for the first entry of --profiles
  --second NAME     deprecated alias for the second entry of --profiles
                    Given together they mean --profiles NAME,NAME. Either one
                    alone replaces just that position. Neither may be combined
                    with --profiles.
  --share MODE      full | safe   (default: ${SHARE_MODE})
                      full = share transcripts, history, checkpoints, skills
                      safe = share plans/skills only, transcripts stay
                             per-profile. history.jsonl (every prompt you
                             typed) is still shared either way. See README.md.
  --source DIR      profile to seed from (default: ${SOURCE})
  --settings NAME=PATH
                    seed that one profile's settings.json from PATH instead
                    of the source's copy. Repeatable, one pair per profile.
                    Accepted by plan, apply and add. PATH must be a readable
                    regular file that at least starts with '{' and ends with
                    '}'; it is copied with cp -p and then goes through the
                    same statusLine/hook relocation as any other copy. A
                    profile that already has a settings.json keeps it, and
                    the flag is reported as ignored for that profile. The
                    path may not contain whitespace, and nothing about it is
                    recorded: it is a one-time seed, not a setting.
  --shell           append the launcher functions to your shell rc file
                    (without this, the snippet is written out for you to add)
  --adopt           merge data that is ALREADY in ~/.claude-<name> into the
                    shared copy instead of refusing to touch it. Archives the
                    whole profile directory to ${BACKUP_ROOT} first, copies in
                    only files the shared copy does not already have (never
                    overwrites), union-merges history.jsonl by timestamp, then
                    moves the originals to <profile>/.adopted-<stamp> and links
                    the paths. Credentials, .claude.json, settings.json and
                    anything else not shared are left untouched. See README.md,
                    "If a profile directory already exists".
  --no-backup       skip the tar backup (only sensible on a re-run of apply).
                    For finalize it does not skip the check: an existing,
                    readable archive named by ${BACKUP_ROOT}/.latest
                    is then required instead of a fresh one.
  --yes             skip confirmation prompts. REQUIRED when there is no
                    terminal to answer them, e.g. when run from Claude Code.
  --json            with 'status' or 'verify', print one JSON object to
                    stdout instead of the human-readable report. No colour,
                    no other output. Exit status is unchanged.
  -h, --help        this text

With none of --profiles/--main/--second and no conf file, plan and apply ask
at the terminal which profiles you want, offering the default pair. Without a
terminal, or with --yes, they take the default silently.

After a successful apply, --profiles/--share/--source are remembered in
~/.claude-shared/.claude-profiles.conf, so verify and rollback do not need
them repeated. Explicit flags always win over the remembered values.

Examples:
  ./claude-profiles.sh plan
  ./claude-profiles.sh apply --shell
  ./claude-profiles.sh apply --profiles work,personal,clientx --shell
  ./claude-profiles.sh verify
  ./claude-profiles.sh finalize      # weeks later, when you trust the setup
EOF
}

# ------------------------------------------------------------------- parse --

[ $# -eq 0 ] && { usage; exit 0; }

case "${1:-}" in
  plan|apply|status|verify|rollback|finalize) CMD="$1"; shift ;;
  add|remove)
    # These two take a positional the option loop below would reject as an
    # unknown option: `add NAME[,NAME...]`, `remove NAME`.
    CMD="$1"; shift
    case "${1:-}" in
      ""|-*) die "'${CMD}' needs a profile name, e.g. ./claude-profiles.sh ${CMD} clientx" ;;
    esac
    CMD_ARG="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
  *) die "unknown command '${1}'. Try --help." ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --profiles) PROFILES_ARG="${2:?--profiles needs a comma-separated list}"
                PROFILES_SET=1; shift 2 ;;
    --main)   MAIN_ARG="${2:?--main needs a name}";     MAIN_SET=1;   shift 2 ;;
    --second) SECOND_ARG="${2:?--second needs a name}"; SECOND_SET=1; shift 2 ;;
    --share)  SHARE_MODE="${2:?--share needs full or safe}"; SHARE_SET=1; shift 2 ;;
    --source) SOURCE="${2:?--source needs a path}"; SOURCE_SET=1; shift 2 ;;
    --settings)
      # NAME=PATH. The name and the file are checked later, against the
      # profile list this run is about (preflight, or do_add). What has to be
      # checked here, while the argument is still one shell word, is that the
      # path holds no whitespace: the pairs are carried in one space-separated
      # string, where a path with a space could not be told from the next pair.
      _sv="${2:?--settings needs NAME=PATH}"
      case "$CMD" in
        plan|apply|add) ;;
        *) die "--settings is only accepted by plan, apply and add, not '${CMD}'." ;;
      esac
      case "$_sv" in
        *[[:space:]]*) die "--settings does not support whitespace in a path: '${_sv}'.
       The pairs are held in one space-separated string, so a path with a
       space in it cannot be told from the next pair. Move the file, or point
       a symlink without spaces at it, and pass that." ;;
        *=*) ;;
        *) die "--settings takes NAME=PATH, got '${_sv}'" ;;
      esac
      SETTINGS_PAIRS="${SETTINGS_PAIRS}${SETTINGS_PAIRS:+ }${_sv}"
      unset _sv
      shift 2 ;;
    --shell)  DO_SHELL=1; shift ;;
    --adopt)  ADOPT=1; shift ;;
    --no-backup) DO_BACKUP=0; shift ;;
    --yes)    ASSUME_YES=1; shift ;;
    --json)   JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option '${1}'. Try --help." ;;
  esac
done

# --json (status, verify only): a single JSON object on stdout instead of the
# human-readable report. Force colour off regardless of [ -t 1 ], and open
# the recorder file that json_add_section/json_add_item (defined just above
# do_verify) append to; hdr/info/ok/warn route there instead of printing once
# JSON=1. Plain variable assignments only here, not a function call: this
# runs as top-level script code, before the functions further down the file
# (including json_add_item itself) have been defined.
if [ "$JSON" -eq 1 ]; then
  C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_OFF=""
  JSON_FILE="${TMPDIR:-/tmp}/.claude-profiles-json.$$"
  : > "$JSON_FILE"
  trap 'rm -f "$JSON_FILE"' EXIT
fi

case "$(uname -s)" in
  Darwin) OS="macos" ;;
  Linux)  OS="linux" ;;
  *) die "unsupported OS '$(uname -s)'. See README.md, section Windows." ;;
esac

# Remembered settings from a previous apply. Explicit flags override.
# PROFILES= is the current spelling; MAIN=/SECOND= is what versions up to
# 1.2.0 wrote, and is still read (as the first two positions) so an existing
# setup keeps working with no flags. write_conf() rewrites it as PROFILES=.
CONF_FILE="${SHARED}/.claude-profiles.conf"
if [ -f "$CONF_FILE" ]; then
  while IFS='=' read -r k v; do
    case "$k" in
      PROFILES)   CONF_PROFILES=$(printf '%s' "$v" | tr ',' ' ') ;;
      MAIN)       CONF_MAIN="$v" ;;
      SECOND)     CONF_SECOND="$v" ;;
      SHARE_MODE) if [ "$SHARE_SET"  -eq 0 ]; then SHARE_MODE="$v"; fi ;;
      SOURCE)     CONF_SOURCE="$v"
                  if [ "$SOURCE_SET" -eq 0 ]; then SOURCE="$v";     fi ;;
      CLAUDE_VERSION) CONF_CLAUDE_VERSION="$v" ;;
      FINALIZED)  CONF_FINALIZED="$v" ;;
      ADOPTED)    CONF_ADOPTED="$v" ;;
    esac
  done < "$CONF_FILE"
  CONF_LOADED=1
  if [ -z "$CONF_PROFILES" ]; then
    CONF_PROFILES="${CONF_MAIN}${CONF_MAIN:+ }${CONF_SECOND}"
    CONF_PROFILES="${CONF_PROFILES% }"
  fi
fi

case "$SHARE_MODE" in
  full) SHARE_DATA="$DATA_FULL" ;;
  safe) SHARE_DATA="$DATA_SAFE" ;;
  *) die "--share must be 'full' or 'safe', got '${SHARE_MODE}'" ;;
esac

# -- which profiles this run is about ----------------------------------------
# Precedence: --profiles, then --main/--second over whatever the conf file or
# the built-in default supplies, then the conf file, then the interactive
# question, then the default. The question is only asked when there is nothing
# else to go on AND a terminal to ask at: see ask_profiles().
if [ "$PROFILES_SET" -eq 1 ]; then
  if [ "$MAIN_SET" -eq 1 ] || [ "$SECOND_SET" -eq 1 ]; then
    die "--profiles cannot be combined with --main/--second. --main X --second Y
       is just the deprecated spelling of --profiles X,Y."
  fi
  # Split on commas only, so a name containing a space is still one token and
  # is rejected below instead of quietly becoming two profiles.
  _oifs="$IFS"; IFS=','; _pl=""
  for _n in $PROFILES_ARG; do
    valid_name "$_n" \
      || die "--profiles names must be letters, digits, '_' or '-', got '${_n}'"
    _pl="${_pl}${_pl:+ }${_n}"
  done
  IFS="$_oifs"
  PROFILES="$_pl"
  unset _oifs _pl _n
else
  PROFILES="${CONF_PROFILES:-$DEFAULT_PROFILES}"
  if [ "$MAIN_SET" -eq 1 ] || [ "$SECOND_SET" -eq 1 ]; then
    warn "--main/--second are deprecated; use --profiles NAME,NAME instead."
    if [ "$MAIN_SET" -eq 1 ]; then
      valid_name "$MAIN_ARG" \
        || die "--main must be letters, digits, '_' or '-', got '${MAIN_ARG}'"
    fi
    if [ "$SECOND_SET" -eq 1 ]; then
      valid_name "$SECOND_ARG" \
        || die "--second must be letters, digits, '_' or '-', got '${SECOND_ARG}'"
    fi
    if [ "$MAIN_SET" -eq 1 ] && [ "$SECOND_SET" -eq 1 ]; then
      # Both given: that is the whole list, exactly as --profiles X,Y.
      PROFILES="${MAIN_ARG} ${SECOND_ARG}"
    else
      # One given: it replaces just its own position in whatever list the
      # conf file or the default supplies, and the rest stand.
      _pl=""; _i=0
      for _n in $PROFILES; do
        _i=$((_i+1))
        if [ "$_i" -eq 1 ] && [ "$MAIN_SET"   -eq 1 ]; then _n="$MAIN_ARG";   fi
        if [ "$_i" -eq 2 ] && [ "$SECOND_SET" -eq 1 ]; then _n="$SECOND_ARG"; fi
        _pl="${_pl}${_pl:+ }${_n}"
      done
      if [ "$_i" -lt 2 ] && [ "$SECOND_SET" -eq 1 ]; then
        _pl="${_pl}${_pl:+ }${SECOND_ARG}"
      fi
      PROFILES="$_pl"
      unset _pl _i _n
    fi
  elif [ "$CONF_LOADED" -eq 0 ] && [ "$ASSUME_YES" -eq 0 ] \
       && { [ "$CMD" = "plan" ] || [ "$CMD" = "apply" ]; } && have_tty; then
    ask_profiles
  fi
fi

_seen=""
for _n in $PROFILES; do
  valid_name "$_n" || die "profile names must be letters, digits, '_' or '-', got '${_n}'"
  if in_list "$_n" "$_seen"; then
    die "profile names must all differ; '${_n}' is listed twice."
  fi
  _seen="${_seen}${_seen:+ }${_n}"
done
unset _seen _n
# plan and apply build a setup, and a setup of one profile would just be
# ~/.claude under another name. The other commands only inspect or edit a
# setup that already exists, and `remove` may legitimately take one down to a
# single profile, so they accept a one-name list rather than dying on the conf
# file that remove just wrote.
if [ "$CMD" = "plan" ] || [ "$CMD" = "apply" ]; then
  [ "$(profiles_count)" -ge 2 ] \
    || die "at least two profiles are needed, got '$(profiles_csv)'. One profile
       would just be ~/.claude under another name."
else
  [ "$(profiles_count)" -ge 1 ] \
    || die "no profile names to work with. Pass --profiles NAME,NAME."
fi

SOURCE="${SOURCE%/}"
SHARE_ALL="${SHARE_DATA} ${CONFIG_SHARED}"

for d in $PROFILES; do
  if same_path "$SOURCE" "$(profile_dir "$d")"; then
    die "source '${SOURCE}' is one of the directories this script manages. Refusing."
  fi
done
if same_path "$SOURCE" "$SHARED"; then
  die "source '${SOURCE}' is one of the directories this script manages. Refusing."
fi

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

  # Before anything is read, copied or archived: a bad --settings pair is a
  # typo in the command line, and plan and apply should both die on it here.
  settings_check "$PROFILES"

  if [ ! -d "$SOURCE" ]; then
    # After finalize the source is gone on purpose, and the generic "does not
    # exist" would send someone looking for a bug. Say what happened instead.
    if [ -n "$CONF_FINALIZED" ]; then
      die "source profile was removed by finalize on ${CONF_FINALIZED}; nothing to seed from.
       '${SOURCE}' no longer exists, which is what finalize is for. The
       profiles $(profiles_english "${HOME}/.claude-" and) are the setup now.
       To seed again, restore the archive first (ROLLBACK.md, Level 3), or
       pass --source pointing at a profile that still exists."
    fi
    die "source profile '${SOURCE}' does not exist.
       If you have never run Claude Code, run it once and log in first."
  fi
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

  local d name
  for name in $PROFILES; do
    d=$(profile_dir "$name")
    if [ -e "$d" ]; then
      warn "'${d}' already exists. apply is additive and will not delete it,"
      warn "but check 'verify' output afterwards."
    fi
  done
  if [ -e "$SHARED" ]; then
    warn "'${SHARED}' already exists. apply is additive and will not delete it,"
    warn "but check 'verify' output afterwards."
  fi

  # Data already sitting in a profile directory. This is the case where the
  # user tried CLAUDE_CONFIG_DIR by hand before finding this script, so
  # ~/.claude-<name> is a complete logged-in profile with transcripts that
  # exist nowhere else. make_profile() cannot link over that, so without
  # --adopt this is a hard stop for apply (and a warning for plan) rather
  # than a half-linked profile discovered afterwards.
  local plist any_real=0
  for name in $PROFILES; do
    plist=$(adopt_paths_for "$name")
    [ -n "$plist" ] || continue
    if [ "$any_real" -eq 0 ]; then say ""; any_real=1; fi
    warn "'$(profile_dir "$name")' already holds real data (not symlinks) at:"
    warn "  $(printf '%s' "$plist" | tr '\n' ' ')"
    if [ "$ADOPT" -eq 1 ]; then
      # Recorded in the conf file by write_conf(), which runs before the
      # merge itself, so the names are worked out here.
      ADOPTED_NAMES="${ADOPTED_NAMES}${ADOPTED_NAMES:+ }${name}"
    fi
  done
  if [ "$any_real" -eq 1 ]; then
    if [ "$ADOPT" -eq 1 ]; then
      info "--adopt given: each directory above is archived to ${BACKUP_ROOT}"
      info "first, then those paths are merged into ${SHARED} without ever"
      info "overwriting a file that is already there, and moved aside into"
      info "<profile>/.adopted-${RUN_STAMP}/ before the links are made."
    else
      warn "--adopt archives the profile directory to ${BACKUP_ROOT}, then merges"
      warn "those paths into ${SHARED}: files the shared copy does not have are"
      warn "copied in, nothing is ever overwritten, history.jsonl is union-merged"
      warn "by timestamp, and the originals move to <profile>/.adopted-<stamp>."
      warn "Credentials, .claude.json and settings.json are left exactly as they are."
      if [ "$CMD" = "apply" ]; then
        die "refusing to touch an existing profile directory. Re-run with --adopt
       to merge the data listed above, or move the directory aside first.
       Nothing has been created or backed up yet."
      fi
      warn "apply would stop here. Re-run plan/apply with --adopt to proceed."
    fi
  fi

  if [ "$OS" = "macos" ]; then
    info "macOS: credentials live in the Keychain, keyed to the config dir."
    info "The '$(first_profile)' profile will prompt for a browser login on first"
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
  if [ "$DO_BACKUP" -eq 1 ]; then total=$((total + src_kb)); fi
  # --adopt archives each pre-existing profile directory as well, and copies
  # whatever the shared dir is missing out of it. Budget for both at full size.
  if [ "$ADOPT" -eq 1 ]; then
    for name in $PROFILES; do
      if [ -n "$(adopt_paths_for "$name")" ]; then
        total=$((total + 2 * $(dir_kb "$(profile_dir "$name")")))
      fi
    done
  fi
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

archive_tree() {
  # $1 = archive path; the rest are tar operands (positional -C pairs, which
  # both GNU tar and bsdtar accept). Creates BACKUP_ROOT as mode 700, writes
  # the archive under umask 077 because it contains credentials, and reads it
  # back with tar tzf before declaring success. Honours DRY.
  #
  # Returns 0 on success, 90 if the archive does not read back, otherwise
  # tar's exit status. The caller words the fatal message, because "backup"
  # and "adopt archive" fail for different reasons and at different points.
  local archive="$1"; shift
  if [ "$DRY" -eq 1 ]; then
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} mkdir -p ${BACKUP_ROOT} && chmod 700 ${BACKUP_ROOT}"
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} (umask 077; tar czf ${archive} $*)"
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} tar tzf ${archive} >/dev/null   # read-back check"
    return 0
  fi

  mkdir -p "$BACKUP_ROOT"
  chmod 700 "$BACKUP_ROOT"

  local st=0
  ( umask 077; tar czf "$archive" "$@" ) 2>"${archive}.log" || st=$?

  if [ "$st" -ne 0 ]; then
    if [ "$st" -eq 1 ] && [ -s "$archive" ]; then
      warn "tar exit 1: some files changed or were unreadable while archiving."
      warn "Usual cause: a Claude Code session is running. Details: ${archive}.log"
    else
      return "$st"
    fi
  fi

  tar tzf "$archive" >/dev/null 2>&1 || return 90
  [ -s "${archive}.log" ] || rm -f "${archive}.log"
  return 0
}

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

  st=0
  if [ -n "$SRC_STATE" ]; then
    archive_tree "$archive" -C "$parent" "$base" \
      -C "$(dirname "$SRC_STATE")" "$(basename "$SRC_STATE")" || st=$?
  else
    archive_tree "$archive" -C "$parent" "$base" || st=$?
  fi

  if [ "$st" -eq 90 ]; then
    die "backup archive does not read back cleanly: ${archive}. Not continuing."
  elif [ "$st" -ne 0 ]; then
    die "backup FAILED (tar exit ${st}). See ${archive}.log. Nothing else was changed."
  fi

  if [ "$DRY" -eq 1 ]; then
    return 0
  fi

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

adopted_value() {
  # The ADOPTED= line for the conf file: whatever a previous apply recorded,
  # plus whatever this run adopted, comma separated and deduped. A later
  # re-apply that adopts nothing must not erase the earlier record.
  local out="$CONF_ADOPTED" n
  for n in $ADOPTED_NAMES; do
    case ",${out}," in
      *",${n},"*) ;;
      *) if [ -n "$out" ]; then out="${out},${n}"; else out="$n"; fi ;;
    esac
  done
  printf '%s' "$out"
}

write_conf() {
  if [ "$DRY" -eq 1 ]; then
    info "would record PROFILES/SHARE_MODE/SOURCE/CLAUDE_VERSION/ADOPTED in ${CONF_FILE}"
    return 0
  fi
  # PROFILES= replaces the MAIN=/SECOND= pair older versions wrote; the
  # loader still understands those, and this rewrite drops them.
  {
    printf 'VERSION=%s\n'    "$VERSION"
    printf 'PROFILES=%s\n'   "$(profiles_csv)"
    printf 'SHARE_MODE=%s\n' "$SHARE_MODE"
    printf 'SOURCE=%s\n'     "$SOURCE"
    printf 'CLAUDE_VERSION=%s\n' "$(claude_version)"
    printf 'ADOPTED=%s\n'    "$(adopted_value)"
  } > "$CONF_FILE"
  ok "recorded settings in ${CONF_FILE}"
}

# ------------------------------------------------------- settings scripts --

find_old_claude_paths() {
  # Print every occurrence in $1 of ~/.claude/<rel>, $HOME/.claude/<rel>, or
  # the literal $HOME path + /.claude/<rel>, one per line, deduped. <rel>
  # ends at the next '"', whitespace, or end of the match: conservative on
  # purpose. grep -oE only -- -P is not portable, -E is (GNU and BSD grep).
  local file="$1" home_esc excl p1 p2 p3
  [ -f "$file" ] || return 0
  home_esc=$(printf '%s' "$HOME" | sed 's/[.[\^$*+?(){}|]/\\&/g')
  excl='[^"[:space:]]+'
  # Literal patterns on purpose, same three spellings as refs_old_profile.
  # shellcheck disable=SC2088
  p1='~/\.claude/'"$excl"
  # shellcheck disable=SC2016
  p2='\$HOME/\.claude/'"$excl"
  p3="$home_esc"'/\.claude/'"$excl"
  # ~/.claude/CLAUDE.md is dropped from the list: in settings.json it is the
  # claudeMdExcludes entry (see ANCESTOR_MD), which names the file so that it
  # is NOT read. Relocating it would silently break the exclusion, and once
  # finalize deletes it the pattern just matches nothing.
  { grep -oE "$p1" "$file" 2>/dev/null || true
    grep -oE "$p2" "$file" 2>/dev/null || true
    grep -oE "$p3" "$file" 2>/dev/null || true
  } | { grep -v '/\.claude/CLAUDE\.md$' || true; } | sort -u
}

relocate_settings_scripts() {
  # A statusLine command or hook path copied verbatim from $SOURCE's
  # settings.json keeps pointing at $SOURCE, which breaks the day it is
  # deleted. Copy the referenced script into $SHARED once, and repoint the
  # profile's own settings.json at ~/.claude-shared/<rel>. $SOURCE is only
  # ever read here; only the profile's copy of settings.json is rewritten.
  local dir="$1" target scan_from candidates
  target="${dir}/settings.json"
  scan_from="$target"
  if [ ! -f "$target" ]; then
    # plan: run() never actually copies settings.json into $dir, so preview
    # against SOURCE's copy instead -- it is what apply would have copied.
    [ -f "${SOURCE}/settings.json" ] || return 0
    scan_from="${SOURCE}/settings.json"
  fi

  candidates=$(find_old_claude_paths "$scan_from")
  [ -n "$candidates" ] || return 0

  # Prefixes held in variables: a quoted literal inside ${c#...} is parsed
  # differently by bash 3.2 and 4.3+, a variable is not.
  local c rel src_file dest_file new_path tmp_settings
  # shellcheck disable=SC2088,SC2016
  local pre_tilde='~/.claude/' pre_var='$HOME/.claude/' pre_lit="${HOME}/.claude/"
  for c in $candidates; do
    case "$c" in
      "$pre_tilde"*) rel="${c#"$pre_tilde"}" ;;
      "$pre_var"*)   rel="${c#"$pre_var"}" ;;
      "$pre_lit"*)   rel="${c#"$pre_lit"}" ;;
      *) continue ;;
    esac
    [ -n "$rel" ] || continue

    src_file="${SOURCE}/${rel}"
    dest_file="${SHARED}/${rel}"
    # shellcheck disable=SC2088
    new_path="~/.claude-shared/${rel}"

    if [ ! -f "$src_file" ]; then
      if [ -d "$src_file" ]; then
        warn "'${c}' in ${target} points at a directory (${src_file}), not a"
        warn "script. Left as is."
      else
        warn "'${c}' in ${target} has no file at ${src_file}. Left as is:"
        warn "the script did not exist under ${SOURCE} to relocate."
      fi
      continue
    fi

    if [ -e "$dest_file" ]; then
      info "keep   ${rel} (already in ${SHARED})"
    else
      info "copy   ${rel} <- ${src_file}"
      run mkdir -p "$(dirname "$dest_file")"
      run cp -p "$src_file" "$dest_file"
    fi

    if [ "$DRY" -eq 1 ]; then
      printf '%s\n' "  ${C_DIM}would run:${C_OFF} rewrite ${target}: '${c}' -> '${new_path}'"
    else
      tmp_settings="$(dirname "$target")/.$(basename "$target").reloc.$$"
      awk -v old="$c" -v new="$new_path" '
        {
          line = $0
          out = ""
          oldlen = length(old)
          while ((i = index(line, old)) > 0) {
            out = out substr(line, 1, i - 1) new
            line = substr(line, i + oldlen)
          }
          print out line
        }
      ' "$target" > "$tmp_settings"
      mv "$tmp_settings" "$target"
      info "rewrite ${target}: '${c}' -> '${new_path}'"
    fi
  done
}

exclude_ancestor_claude_md() {
  # Add ANCESTOR_MD to claudeMdExcludes in the profile's own settings.json,
  # creating the file if the profile has none. No JSON parser: the key goes
  # in straight after the first '{'. A file that already names the path is
  # left alone; one with a claudeMdExcludes of its own is not merged into,
  # because editing a JSON array with awk is how files get broken. It is
  # reported instead, and verify keeps reporting it.
  local dir="$1" target squashed tmp
  target="${dir}/settings.json"
  if [ "$DRY" -eq 1 ]; then
    # plan: nothing was copied, so look at what apply would have copied.
    [ -f "$target" ] || target="${SOURCE}/settings.json"
    if [ -f "$target" ] && grep -qF "\"${ANCESTOR_MD}\"" "$target"; then
      info "keep   claudeMdExcludes (already lists ${ANCESTOR_MD})"
    else
      printf '%s\n' "  ${C_DIM}would run:${C_OFF} add ${ANCESTOR_MD} to claudeMdExcludes in ${dir}/settings.json"
    fi
    return 0
  fi

  if [ ! -f "$target" ]; then
    printf '{\n  "claudeMdExcludes": ["%s"]\n}\n' "$ANCESTOR_MD" > "$target"
    info "create settings.json with claudeMdExcludes: ${ANCESTOR_MD}"
    return 0
  fi
  if grep -qF "\"${ANCESTOR_MD}\"" "$target"; then
    info "keep   claudeMdExcludes (already lists ${ANCESTOR_MD})"
    return 0
  fi
  if grep -qF '"claudeMdExcludes"' "$target"; then
    warn "${target} has its own claudeMdExcludes, which does not list"
    warn "${ANCESTOR_MD}. Add that path to the array by hand, or Claude Code"
    warn "loads it as project instructions in every project under ${HOME}."
    return 0
  fi
  squashed=$(tr -d '[:space:]' < "$target")
  case "$squashed" in
    "{}") printf '{\n  "claudeMdExcludes": ["%s"]\n}\n' "$ANCESTOR_MD" > "$target" ;;
    "{"*"}")
      tmp="$(dirname "$target")/.$(basename "$target").md.$$"
      # ENVIRON, not -v: awk -v would interpret backslashes in the path.
      ANCESTOR_MD="$ANCESTOR_MD" awk '
        !done && (i = index($0, "{")) > 0 {
          print substr($0, 1, i)
          print "  \"claudeMdExcludes\": [\"" ENVIRON["ANCESTOR_MD"] "\"],"
          rest = substr($0, i + 1)
          if (rest ~ /[^[:space:]]/) print rest
          done = 1
          next
        }
        { print }
      ' "$target" > "$tmp"
      mv "$tmp" "$target"
      ;;
    *)
      warn "${target} does not look like a JSON object; claudeMdExcludes not"
      warn "added. Add \"claudeMdExcludes\": [\"${ANCESTOR_MD}\"] by hand."
      return 0
      ;;
  esac
  info "add    claudeMdExcludes: ${ANCESTOR_MD} (so it is not loaded as"
  info "       project instructions in every project under ${HOME})"
}

# ------------------------------------------------------------------ adopt --
#
# The case this exists for: the user set CLAUDE_CONFIG_DIR by hand before
# finding this script, so ~/.claude-<name> is already a complete, logged-in
# profile. Its projects/ tree is part hand-copy of ~/.claude/projects and part
# sessions that exist nowhere else; its history.jsonl is a union of copied and
# new lines. make_profile() will not link over real data, so --adopt merges it
# into the shared copy first. The rule throughout is that the shared copy wins:
# nothing already in ${SHARED} is ever overwritten, and the profile's originals
# are archived AND moved aside rather than deleted.

profile_real_share_paths() {
  # Print each SHARE_ALL path that exists inside $1 as real (non-symlink)
  # data, one per line. Nothing else in the profile directory is listed:
  # .credentials.json, .claude.json, settings.json, sessions/ and friends are
  # none of adopt's business.
  local dir="$1" p
  if [ -d "$dir" ]; then
    for p in $SHARE_ALL; do
      if [ ! -L "${dir}/${p}" ] && [ -e "${dir}/${p}" ]; then
        printf '%s\n' "$p"
      fi
    done
  fi
  return 0
}

adopt_paths_for() {
  # The adopt list belonging to a profile NAME. Computed on demand rather
  # than stored per name, because bash 3.2 has no associative arrays and the
  # answer is only ever a handful of [ -e ] tests. Callers read it before
  # do_adopt has moved anything, so recomputing gives the same answer the
  # preflight printed; afterwards the paths are gone and it is empty, which
  # is what make_profile wants to see.
  profile_real_share_paths "$(profile_dir "$1")"
}

merge_tree() {
  # Copy every file under $1 that does not already exist at the same relative
  # path under $2 (the reference) into $3 (the destination). Reference and
  # destination differ only in plan mode, where ${SHARED}/<p> does not exist
  # yet and the source profile's copy is what seed_shared would have put
  # there. $4 is the path name, for reporting.
  #
  # Portability: `cp -Rpn` exists on GNU and BSD cp but reports nothing about
  # what it skipped (and BSD cp -n exits 1 on a skip), so the skip/copy counts
  # would be a guess. find + an explicit [ -e ] guard per file gives exact
  # counts and the same no-clobber guarantee on both. -Rp keeps mtimes, which
  # Claude Code sorts --resume by, and copies a symlink as a symlink.
  local src="$1" ref="$2" dst="$3" p="$4"
  local rel copied=0 skipped=0
  while IFS= read -r rel; do
    rel="${rel#./}"
    if [ -z "$rel" ]; then continue; fi
    if [ -e "${ref}/${rel}" ] || [ -L "${ref}/${rel}" ]; then
      skipped=$((skipped+1))
      continue
    fi
    copied=$((copied+1))
    # Explicitly branched on DRY rather than routed through run(), because a
    # per-file "would run:" line would be thousands of lines of plan output.
    if [ "$DRY" -eq 0 ]; then
      mkdir -p "$(dirname "${dst}/${rel}")"
      cp -Rp "${src}/${rel}" "${dst}/${rel}"
    fi
  done < <(cd "$src" && find . ! -type d -print)

  if [ "$DRY" -eq 1 ]; then
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} cp -Rp, per file, no overwrite: ${copied} file(s) from ${src} into ${dst}"
  fi
  info "merge  ${p}/: ${copied} copied in, ${skipped} skipped (already in ${SHARED})"
}

jsonl_union() {
  # Print the union of the lines of $1 (may be absent) and $2: exact duplicate
  # lines dropped, ordered by the numeric "timestamp" field. Lines without one
  # get 0 and therefore sort first. sort -s (GNU and BSD) is stable, so inside
  # one timestamp the input order survives, and $1 is read first, so the
  # shared file's existing order is preserved.
  #
  # awk prefixes each line with the timestamp and a tab; cut -f2- strips it
  # again. cut is used rather than sed because BSD sed does not understand \t
  # in a pattern.
  local a="$1" b="$2"
  # The $0 / $2 inside are awk's fields, not the shell's: single quotes are
  # required here, not a mistake. Held in a variable because the two awk
  # invocations below (one file or two) must run the identical program.
  # shellcheck disable=SC2016
  local prog='
    !seen[$0]++ {
      ts = 0
      if (match($0, /"timestamp" *: *[0-9]+/)) {
        s = substr($0, RSTART, RLENGTH)
        sub(/^[^0-9]*/, "", s)
        ts = s + 0
      }
      printf "%s\t%s\n", ts, $0
    }'
  if [ -f "$a" ]; then
    awk "$prog" "$a" "$b"
  else
    awk "$prog" "$b"
  fi | sort -n -k1,1 -s | cut -f2-
}

merge_jsonl() {
  # $1 = the profile's file, $2 = reference (shared file, or what seed would
  # have made it in plan mode), $3 = the shared file to write, $4 = path name.
  local src="$1" ref="$2" dst="$3" p="$4"
  local a=0 b n tmp
  if [ -f "$ref" ]; then a=$(wc -l < "$ref" | tr -d ' '); fi
  b=$(wc -l < "$src" | tr -d ' ')

  if [ "$DRY" -eq 1 ]; then
    n=$(jsonl_union "$ref" "$src" | wc -l | tr -d ' ')
    printf '%s\n' "  ${C_DIM}would run:${C_OFF} union-merge ${src} into ${dst}, deduped and sorted by timestamp"
  else
    # Temp file in $SHARED so the rename is on one filesystem and atomic.
    tmp="${SHARED}/.${p}.merge.$$"
    jsonl_union "$ref" "$src" > "$tmp"
    n=$(wc -l < "$tmp" | tr -d ' ')
    mv "$tmp" "$dst"
  fi
  info "merge  ${p}: ${a} shared + ${b} in profile -> ${n} unique line(s)"
}

do_adopt() {
  # $1 = profile dir, $2 = profile name, $3 = its adopt list (newline
  # separated). Runs after seed_shared (so ${SHARED}/<p> exists) and before
  # make_profile for the same directory.
  local dir="$1" label="$2" paths="$3"
  if [ "$ADOPT" -eq 0 ] || [ -z "$paths" ]; then return 0; fi

  hdr "Adopt existing data: ${dir}"

  local archive parent base st=0
  archive="${BACKUP_ROOT}/claude-${label}-adopted-${RUN_STAMP}.tar.gz"
  parent=$(dirname "$dir")
  base=$(basename "$dir")
  info "archive:  ${archive}"
  info "contents: ${dir} (the whole directory, before anything is merged)"
  info "mode 600, in a mode 700 directory: the archive contains credentials"
  archive_tree "$archive" -C "$parent" "$base" || st=$?
  if [ "$st" -eq 90 ]; then
    die "adopt archive does not read back cleanly: ${archive}. Nothing merged."
  elif [ "$st" -ne 0 ]; then
    die "adopt archive FAILED (tar exit ${st}). See ${archive}.log. Nothing merged."
  fi
  if [ "$DRY" -eq 0 ]; then
    ok "adopt archive written and read back ($(du -sh "$archive" | cut -f1))"
  fi

  local p src dst ref aside
  aside="${dir}/.adopted-${RUN_STAMP}"
  for p in $paths; do
    src="${dir}/${p}"
    dst="${SHARED}/${p}"
    ref="$dst"
    if [ ! -e "$ref" ] && [ "$DRY" -eq 1 ] && [ -e "${SOURCE}/${p}" ]; then
      # plan: seed_shared has not run for real, so compare against what it
      # would have copied in. Read-only either way.
      ref="${SOURCE}/${p}"
    fi

    if [ -d "$src" ]; then
      if [ -e "$ref" ] && [ ! -d "$ref" ]; then
        warn "'${p}' is a directory in ${dir} but a file in ${SHARED}."
        warn "Not merged; the whole directory is set aside below instead."
      else
        merge_tree "$src" "$ref" "$dst" "$p"
      fi
    else
      case "$p" in
        *.jsonl)
          if [ -e "$ref" ] && [ ! -f "$ref" ]; then
            warn "'${p}' is a file in ${dir} but not a file in ${SHARED}."
            warn "Not merged; set aside below instead."
          else
            merge_jsonl "$src" "$ref" "$dst" "$p"
          fi ;;
        *)
          info "keep   ${p} (the shared copy wins; the profile's file is only"
          info "       set aside, never merged: it is not a transcript store)" ;;
      esac
    fi

    run mkdir -p "$aside"
    run mv "$src" "${aside}/${p}"
  done

  info "originals moved to ${aside}/ (also in ${archive})"
}

# ---------------------------------------------------------------- profiles --

make_profile() {
  local dir="$1" label="$2" inherit="$3"

  hdr "Profile: ${dir}"
  run mkdir -p "$dir"

  # TEMPLATE_DIR is only set by `add` after finalize, when there is no source
  # left to copy settings.json and CLAUDE.md from and the first profile is the
  # nearest thing to one. Everywhere else the source is the template, as it
  # always was, and it is still only read.
  local p src seed tmpl
  tmpl="${TEMPLATE_DIR:-$SOURCE}"
  for p in $CONFIG_COPIED; do
    src="${tmpl}/${p}"
    seed=""
    if [ "$p" = "settings.json" ]; then seed=$(settings_for "$label"); fi
    if [ -e "${dir}/${p}" ]; then
      if [ -n "$seed" ]; then
        # Idempotence wins: --settings seeds a profile, it does not overwrite
        # one. Saying so is the point, or a re-apply would look like it took.
        info "keep   ${p} (already present; --settings ${seed} ignored for '${label}')"
      else
        info "keep   ${p} (already present)"
      fi
    elif [ -n "$seed" ]; then
      info "copy   ${p} <- ${seed} (--settings)"
      run cp -p "$seed" "${dir}/${p}"
    elif [ -e "$src" ]; then
      info "copy   ${p}"
      run cp -Rp "$src" "${dir}/${p}"
    fi
  done

  relocate_settings_scripts "$dir"
  exclude_ancestor_claude_md "$dir"

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
      # In plan mode with --adopt the data is still there, because do_adopt
      # only printed what it would move. Say what apply would do instead of
      # the refusal, which would be wrong.
      if [ "$DRY" -eq 1 ] && [ "$ADOPT" -eq 1 ] && in_list "$p" "$(adopt_paths_for "$label")"; then
        info "link   ${p} -> ${SHARED}/${p} (once adopt has moved the existing data aside)"
      else
        warn "'${dir}/${p}' exists and is NOT a symlink."
        warn "Refusing to replace real data. Move it aside, or re-run with"
        warn "--adopt to merge it into ${SHARED} first."
      fi
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

  # One function per profile, built up first: a heredoc cannot loop.
  local body funcs="" n
  for n in $PROFILES; do
    funcs="${funcs}claude-${n}() {
  CLAUDE_CONFIG_DIR=\"$(profile_dir "$n")\" command claude \"\$@\"
}

"
  done

  body=$(cat <<EOF
# ---8<--- claude-profiles v${VERSION} ---8<---
# Generated by claude-profiles.sh. Safe to edit. Sourced by bash and zsh.
# Each launcher points Claude Code at its own config directory, which holds
# that profile's credentials and app state.
# Launchers defined here: $(profiles_english claude- and)

${funcs}# Guard rail: bare 'claude' would silently use ~/.claude, the untouched
# pre-migration profile. Force an explicit choice, EXCEPT when a profile has
# already been chosen via CLAUDE_CONFIG_DIR. That exception is what lets
# 'claude --version', 'claude mcp ...' and similar work inside a session
# started with $(profiles_english claude-), since the session's shell
# inherits the variable.
claude() {
  if [ -n "\${CLAUDE_CONFIG_DIR:-}" ]; then
    command claude "\$@"
    return
  fi
  printf '%s\n' "Pick a profile: $(profiles_english claude-)" >&2
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

json_str() {
  # $1 = key. Reads JSON text from STDIN. Crude but dependency-free, same
  # spirit as json_num(): strip newlines/tabs, then a basic-regex sed
  # capture of whatever sits between the quotes after "key":. Falls back
  # to a bare (unquoted) token up to the next comma or closing brace, for
  # a value like loggedIn's true/false that is not itself quoted. Not a
  # real JSON parser: no escaped quotes, no nested objects. Prints "unset"
  # when the key is absent. Reads stdin into a variable once because the
  # fallback needs a second pass over the same text.
  local key="$1" content v
  content=$(tr -d '\n\t')
  v=$(printf '%s' "$content" | sed -n "s/.*\"$key\": *\"\([^\"]*\)\".*/\1/p")
  if [ -z "$v" ]; then
    v=$(printf '%s' "$content" | sed -n "s/.*\"$key\": *\([^,}]*\)[,}].*/\1/p")
  fi
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "unset"
}

profile_auth() {
  # $1 = profile dir. Prints one line: loggedIn<TAB>email<TAB>orgName<TAB>
  # subscriptionType, read from `claude auth status --json` run against
  # that profile's CLAUDE_CONFIG_DIR. Prints "no-binary" instead if the
  # claude binary is not on PATH. Caller (do_verify) is responsible for
  # only calling this when profile_launched() is already true: running
  # auth status against a never-launched config dir creates .claude.json
  # and backups/ inside it, which would be a verify-time write.
  local dir="$1" out=""
  if ! command -v claude >/dev/null 2>&1; then
    printf '%s\n' "no-binary"
    return 0
  fi
  # A logged-out profile exits 1; that must not trip set -e here, and we
  # still want whatever JSON it printed on the way out.
  out=$(CLAUDE_CONFIG_DIR="$dir" claude auth status --json 2>/dev/null) || true
  printf '%s\t%s\t%s\t%s\n' \
    "$(printf '%s' "$out" | json_str loggedIn)" \
    "$(printf '%s' "$out" | json_str email)" \
    "$(printf '%s' "$out" | json_str orgName)" \
    "$(printf '%s' "$out" | json_str subscriptionType)"
}

points_into_new_setup() {
  # True if $1 is a path inside the shared directory or any profile
  # directory. Used to catch a symlink in SOURCE that points at the new
  # setup, which this script never creates.
  local t="$1" n
  case "$t" in "${SHARED}"/*) return 0 ;; esac
  for n in $PROFILES; do
    case "$t" in "$(profile_dir "$n")"/*) return 0 ;; esac
  done
  return 1
}

name_for_email() {
  # $1 = an email, $2 = a flat "email name email name ..." list. Prints the
  # name recorded for that email, or nothing.
  local want="$1" tok cur="" want_name=0
  for tok in $2; do
    if [ "$want_name" -eq 0 ]; then
      cur="$tok"; want_name=1
    else
      if [ "$cur" = "$want" ]; then printf '%s' "$tok"; return 0; fi
      want_name=0
    fi
  done
  return 0
}

refs_old_profile() {
  # Does a settings file point at absolute paths under ~/.claude ? Same list
  # as find_old_claude_paths, so the claudeMdExcludes entry does not count.
  [ -f "$1" ] || return 1
  [ -n "$(find_old_claude_paths "$1")" ]
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

# -------------------------------------------------------------- json output --
#
# Used only by `status --json` and `verify --json`. hdr()/info()/ok()/warn()
# (defined at the top of the file) already route to json_add_section/
# json_add_item instead of printing once JSON=1; do_status() also reads its
# own local variables directly to build its JSON object, since its shape is a
# handful of fixed fields rather than the section/item list verify uses.

json_esc() {
  # Escapes backslash, double quote, tab and newline so $1 can sit inside a
  # JSON string. Nothing else in these strings is exotic (paths, emails, org
  # names, our own messages) so nothing else is escaped. The N;$!ba loop
  # joins multi-line input first, so an embedded real newline (not just the
  # \n two-character escape already handled by the tab rule above) becomes
  # a literal \n instead of breaking the one-object-per-line JSON output.
  # awk rather than sed: BSD sed does not understand \t in a pattern, and
  # the tab and newline here must be matched literally on both userlands.
  printf '%s' "$1" | awk 'BEGIN { ORS = "" }
    { gsub(/\\/, "\\\\"); gsub(/"/, "\\\""); gsub(/\t/, "\\t")
      if (NR > 1) printf "\\n"
      printf "%s", $0 }'
}

json_add_section() {
  # $1 = section name. Starts a new group that json_add_item() below appends
  # to until the next json_add_section call. JSON_FILE is opened once, at
  # option-parsing time, only when --json was given.
  [ "$JSON" -eq 1 ] || return 0
  printf 'S\t%s\n' "$(json_esc "$1")" >> "$JSON_FILE"
}

json_add_item() {
  # $1 = level (ok|warn|info), $2 = text.
  [ "$JSON" -eq 1 ] || return 0
  printf 'I\t%s\t%s\n' "$1" "$(json_esc "$2")" >> "$JSON_FILE"
}

json_sections_json() {
  # Renders JSON_FILE's S/I lines (both already json_esc()-escaped) as
  # verify --json's "sections" array. One pass, no arrays needed: awk prints
  # punctuation as each line streams past rather than building the tree in
  # memory first.
  awk -F'\t' '
    BEGIN { printf "[" }
    $1 == "S" {
      if (nsec > 0) { printf "]}," }
      nsec++
      printf "{\"name\":\"%s\",\"items\":[", $2
      nitem = 0
      next
    }
    $1 == "I" {
      if (nsec == 0) next
      if (nitem > 0) { printf "," }
      nitem++
      printf "{\"level\":\"%s\",\"text\":\"%s\"}", $2, $3
      next
    }
    END {
      if (nsec > 0) { printf "]}" }
      printf "]"
    }
  ' "$JSON_FILE"
}

json_emit_verify() {
  # Called from the dispatcher after do_verify() returns, using the section/
  # item trail it left in JSON_FILE and the problem count it left in
  # VERIFY_PROBLEMS. Exit status is decided by the dispatcher, from the same
  # do_verify() call, not from this function.
  local ok_bool="true"
  [ "$VERIFY_PROBLEMS" -eq 0 ] || ok_bool="false"
  printf '{"command":"verify","version":"%s","problems":%s,"ok":%s,"sections":%s}\n' \
    "$(json_esc "$VERSION")" "$VERIFY_PROBLEMS" "$ok_bool" "$(json_sections_json)"
}

do_verify() {
  local problems=0
  local cur
  cur=$(claude_version)

  hdr "Directories"
  local d name dirs=""
  for name in $PROFILES; do
    dirs="${dirs} $(profile_dir "$name")"
  done
  for d in "$SOURCE" $dirs "$SHARED"; do
    if [ -d "$d" ]; then
      ok "$d"
    elif [ "$d" = "$SOURCE" ] && [ -n "$CONF_FINALIZED" ]; then
      # Gone on purpose. Not a problem, and not "missing".
      ok "${d}  (removed by finalize on ${CONF_FINALIZED})"
    else
      warn "missing: $d"; problems=$((problems+1))
    fi
  done
  if [ "$CONF_LOADED" -eq 1 ]; then
    ok "settings read from ${CONF_FILE} (profiles=$(profiles_csv) share=${SHARE_MODE})"
  else
    info "no ${CONF_FILE}; checking against defaults/flags (profiles=$(profiles_csv) share=${SHARE_MODE})"
  fi

  hdr "Source profile untouched"
  local p touched=0
  if [ -n "$CONF_FINALIZED" ] && [ ! -d "$SOURCE" ]; then
    info "skipped: ${SOURCE} was removed by finalize on ${CONF_FINALIZED}."
    info "There is no source profile left to leave untouched."
  else
    for p in $SHARE_ALL $PRIVATE; do
      if [ -L "${SOURCE}/${p}" ] && points_into_new_setup "$(readlink "${SOURCE}/${p}")"; then
        warn "${SOURCE}/${p} is a symlink INTO the new setup. The script never does this."
        touched=1
      fi
    done
    if [ "$touched" -eq 0 ]; then ok "nothing in ${SOURCE} points at the new directories"
    else problems=$((problems+1)); fi
  fi

  hdr "Shared links"
  local dir
  for name in $PROFILES; do
    dir=$(profile_dir "$name")
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

  hdr "Adopted data"
  # A .adopted-<stamp> directory is what --adopt left behind: the profile's
  # own copies of the shared paths, after their contents were merged into
  # ${SHARED}. It is not a fault, and nothing above should be read as one.
  local ad any_adopted=0
  if [ -n "$CONF_ADOPTED" ]; then
    info "conf records --adopt was used for: ${CONF_ADOPTED}"
    any_adopted=1
  fi
  for name in $PROFILES; do
    dir=$(profile_dir "$name")
    [ -d "$dir" ] || continue
    for ad in "${dir}"/.adopted-*; do
      if [ -d "$ad" ]; then
        info "${ad}"
        info "  the profile's pre-adopt copies, already merged into ${SHARED}."
        info "  Not a problem. Delete it when you are happy (the same data is"
        info "  also in the claude-*-adopted-*.tar.gz archive in ${BACKUP_ROOT})."
        any_adopted=1
      fi
    done
  done
  if [ "$any_adopted" -eq 0 ]; then
    info "none (no profile directory held data that had to be adopted)"
  fi

  hdr "Credential isolation"
  for name in $PROFILES; do
    dir=$(profile_dir "$name")
    [ -d "$dir" ] || continue
    for p in $PRIVATE; do
      if [ -L "${dir}/${p}" ]; then
        warn "$(basename "$dir")/${p} is a SYMLINK. It must be a real, per-profile"
        warn "file or directory or the profiles are not isolated."
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

  hdr "Accounts"
  if ! command -v claude >/dev/null 2>&1; then
    info "'claude' is not on PATH; skipping account checks (cannot ask which account each profile holds)."
  else
    # "email name email name ..." for every profile seen logged in so far.
    # Each new profile is compared against that, so ANY pair sharing an
    # account is reported, not just the first two. No arrays: emails cannot
    # contain a space, so a flat list splits unambiguously.
    local seen="" clash line logged email org sub
    for name in $PROFILES; do
      dir=$(profile_dir "$name")
      [ -d "$dir" ] || continue
      if ! profile_launched "$dir"; then
        info "${name}: not launched yet, skipping (checking would create its .claude.json)"
        continue
      fi
      line=$(profile_auth "$dir")
      logged=$(printf '%s' "$line" | cut -f1)
      email=$(printf '%s' "$line" | cut -f2)
      org=$(printf '%s' "$line" | cut -f3)
      sub=$(printf '%s' "$line" | cut -f4)
      if [ "$logged" != "true" ]; then
        warn "${name}: not logged in"
        continue
      fi
      ok "${name}: ${email} (${org}, ${sub})"
      # An absent email reads as "unset" for every profile alike, which is
      # not evidence of a shared account.
      [ "$email" = "unset" ] && continue
      clash=$(name_for_email "$email" "$seen")
      if [ -n "$clash" ]; then
        warn "${clash} and ${name} are both logged in as the same account (${email})."
        warn "That defeats the purpose of separate profiles."
        problems=$((problems+1))
      else
        seen="${seen}${seen:+ }${email} ${name}"
      fi
    done
  fi

  hdr "Per-profile app state (.claude.json)"
  info "With CLAUDE_CONFIG_DIR set, Claude Code keeps this inside the profile"
  info "dir. If a launched profile has none there, that version fell back to"
  # shellcheck disable=SC2088
  info "~/.claude.json, which every profile would share: NOT isolated."
  for name in $PROFILES; do
    dir=$(profile_dir "$name")
    [ -d "$dir" ] || continue
    if [ -f "${dir}/.claude.json" ]; then
      ok "$(basename "$dir")/.claude.json present (good: state is per-profile)"
    elif profile_launched "$dir"; then
      warn "$(basename "$dir") has been launched but has no .claude.json."
      warn "Your Claude Code version keeps that state at ~/.claude.json instead,"
      warn "which every profile shares. The accounts are NOT isolated."
      warn "Stop here and read README.md, section 'If verify flags .claude.json'."
      problems=$((problems+1))
    else
      info "$(basename "$dir"): not launched yet, nothing to check"
    fi
  done
  # shellcheck disable=SC2088
  [ -f "${HOME}/.claude.json" ] && info "~/.claude.json also exists (old profile's state, expected)"

  hdr "Retention settings"
  # Every profile sweeps the same shared directories, so all of them have to
  # agree, not just the first two. The first profile's value is the reference
  # only because something has to be; the warning names the odd ones out.
  local v ref="" reported="" odd=""
  for name in $PROFILES; do
    v=$(json_num "$(profile_dir "$name")/settings.json" cleanupPeriodDays)
    reported="${reported}${reported:+   }${name}: cleanupPeriodDays=${v}"
    if [ -z "$ref" ]; then
      ref="$v"
    elif [ "$v" != "$ref" ]; then
      odd="${odd}${odd:+ }${name}"
    fi
  done
  info "$reported"
  if [ -n "$odd" ]; then
    warn "These differ: ${odd} (measured against $(first_profile)'s ${ref})."
    warn "Every profile sweeps the SAME shared directories, so the shortest"
    warn "period wins and will delete the others' data."
    warn "Set them to the same value in every settings.json."
    problems=$((problems+1))
  else
    ok "matching (or all unset, which is the 30-day default)"
  fi

  hdr "Ancestor CLAUDE.md"
  # See ANCESTOR_MD. Only a problem while the file exists; after finalize it
  # is gone and the pattern, if present, matches nothing.
  if [ -f "$ANCESTOR_MD" ]; then
    local unexcluded=""
    for name in $PROFILES; do
      grep -qF "\"${ANCESTOR_MD}\"" "$(profile_dir "$name")/settings.json" 2>/dev/null \
        || unexcluded="${unexcluded}${unexcluded:+ }${name}"
    done
    if [ -n "$unexcluded" ]; then
      warn "${ANCESTOR_MD} is not in claudeMdExcludes for: ${unexcluded}"
      warn "Those profiles load it as project instructions in every project"
      warn "under ${HOME}, on top of their own CLAUDE.md, and it stops a repo's"
      warn "AGENTS.md from loading. Re-run apply, or add the exact path to"
      warn "claudeMdExcludes in that settings.json by hand."
      problems=$((problems+1))
    else
      ok "every profile excludes ${ANCESTOR_MD}"
    fi
  else
    ok "no ${ANCESTOR_MD}, nothing to exclude"
  fi

  hdr "Settings that still point at ${SOURCE}"
  local refs=0 extra
  for name in $PROFILES; do
    dir=$(profile_dir "$name")
    if refs_old_profile "${dir}/settings.json"; then
      warn "$(basename "$dir")/settings.json references paths under ~/.claude/"
      warn "(statusLine command, hooks, or similar). apply relocates scripts"
      warn "like this into ${SHARED} automatically and repoints the setting;"
      warn "a reference still here means that script did not exist under"
      warn "${SOURCE} at apply time (or was added since). Re-run apply (it"
      warn "is idempotent), or fix the path in settings.json by hand."
      extra=$(find_old_claude_paths "${dir}/settings.json" | tr '\n' ' ')
      [ -n "$extra" ] && warn "still there: ${extra}"
      refs=1
    fi
  done
  if [ "$refs" -eq 0 ]; then
    if [ -n "$CONF_FINALIZED" ] && [ ! -d "$SOURCE" ]; then
      ok "none"
    else
      ok "none (so 'finalize' can remove ${SOURCE} when you are ready)"
    fi
  fi

  hdr "Shell"
  local rc
  rc=$(rc_file)
  if [ -f "$SNIPPET_FILE" ]; then
    ok "$SNIPPET_FILE"
    local missing=""
    for name in $PROFILES; do
      grep -q "^claude-${name}()" "$SNIPPET_FILE" \
        || missing="${missing}${missing:+ }claude-${name}"
    done
    if [ -n "$missing" ]; then
      warn "snippet does not define ${missing};"
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

  VERIFY_PROBLEMS="$problems"

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

# ------------------------------------------------------------------ status --
#
# The daily-use glance, as opposed to verify's health check: read-only, fast
# (never calls `claude auth status` on a profile that has never been
# launched, same rule as do_verify's Accounts section), and no "problems"
# logic. Exit status is 0 unless the conf file is missing.

do_status() {
  [ "$CONF_LOADED" -eq 1 ] \
    || die "no ${CONF_FILE}. 'status' only has something to report once you
       have run 'apply'. Run 'plan' first to preview what that would do."

  local cur name dir launcher is_first line l e o s marker
  local json_profiles="" current_profile_json="null"
  cur=$(claude_version)

  hdr "Versions"
  info "claude-profiles.sh : ${VERSION}"
  info "claude              : ${cur}"
  if [ -n "$CONF_CLAUDE_VERSION" ] && [ "$CONF_CLAUDE_VERSION" != "$cur" ]; then
    info "recorded at apply   : ${CONF_CLAUDE_VERSION} (differs from current)"
  fi

  hdr "You are in"
  local cur_desc="" cur_name=""
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    for name in $PROFILES; do
      if same_path "${CLAUDE_CONFIG_DIR}" "$(profile_dir "$name")"; then
        cur_name="$name"
        break
      fi
    done
    if [ -n "$cur_name" ]; then
      cur_desc="$cur_name"
    elif same_path "${CLAUDE_CONFIG_DIR}" "$SOURCE"; then
      # shellcheck disable=SC2088
      cur_desc="~/.claude (old profile)"
    else
      cur_desc="${CLAUDE_CONFIG_DIR}"
    fi
  else
    # shellcheck disable=SC2088
    cur_desc="~/.claude (old profile)"
  fi
  info "you are in: ${cur_desc}"
  [ -n "$cur_name" ] && current_profile_json="\"$(json_esc "$cur_name")\""

  hdr "Profiles"
  local have_claude=0
  command -v claude >/dev/null 2>&1 && have_claude=1
  for name in $PROFILES; do
    dir=$(profile_dir "$name")
    launcher="claude-${name}"
    if [ "$name" = "$(first_profile)" ]; then is_first=1; else is_first=0; fi
    marker=""
    [ "$is_first" -eq 1 ] && marker="  (first: inherits login)"

    local logged_json="null" email_json="null" org_json="null" plan_json="null" launched_json="false"
    if profile_launched "$dir"; then
      launched_json="true"
      if [ "$have_claude" -eq 1 ]; then
        line=$(profile_auth "$dir")
        l=$(printf '%s' "$line" | cut -f1)
        e=$(printf '%s' "$line" | cut -f2)
        o=$(printf '%s' "$line" | cut -f3)
        s=$(printf '%s' "$line" | cut -f4)
        if [ "$l" = "true" ]; then
          logged_json="true"
          [ "$e" != "unset" ] && email_json="\"$(json_esc "$e")\""
          [ "$o" != "unset" ] && org_json="\"$(json_esc "$o")\""
          [ "$s" != "unset" ] && plan_json="\"$(json_esc "$s")\""
          ok "${name} (${launcher}): ${e} (${o}, ${s})${marker}"
        else
          logged_json="false"
          info "${name} (${launcher}): not logged in${marker}"
        fi
      else
        info "${name} (${launcher}): launched, but 'claude' is not on PATH to check the account${marker}"
      fi
    else
      info "${name} (${launcher}): not launched yet${marker}"
    fi

    json_profiles="${json_profiles}${json_profiles:+,}"'{"name":"'"$(json_esc "$name")"'","dir":"'"$(json_esc "$dir")"'","launcher":"'"$(json_esc "$launcher")"'","first":'"$( [ "$is_first" -eq 1 ] && printf true || printf false )"',"launched":'"$launched_json"',"logged_in":'"$logged_json"',"email":'"$email_json"',"org":'"$org_json"',"plan":'"$plan_json"'}'
  done

  hdr "Shared data"
  local shared_kb proj_count trans_count
  shared_kb=$(dir_kb "$SHARED")
  if [ -d "${SHARED}/projects" ]; then
    proj_count=$(find "${SHARED}/projects" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
  else
    proj_count=0
  fi
  if [ -d "${SHARED}/projects" ]; then
    trans_count=$(find "${SHARED}/projects" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
  else
    trans_count=0
  fi
  info "size: $(kb_h "$shared_kb")   projects: ${proj_count}   transcripts: ${trans_count}   mode: ${SHARE_MODE}"

  hdr "Backups"
  local backup_count=0 backup_latest="" backup_latest_json="null"
  if [ -d "$BACKUP_ROOT" ]; then
    backup_count=$(find "$BACKUP_ROOT" -maxdepth 1 -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
  fi
  if [ -f "${BACKUP_ROOT}/.latest" ]; then
    backup_latest=$(basename "$(cat "${BACKUP_ROOT}/.latest" 2>/dev/null)" 2>/dev/null) || backup_latest=""
    [ -n "$backup_latest" ] && backup_latest_json="\"$(json_esc "$backup_latest")\""
  fi
  info "count: ${backup_count}   latest: ${backup_latest:-none}"

  local finalized_json="null" adopted_json="[]"
  if [ -n "$CONF_FINALIZED" ] || [ -n "$CONF_ADOPTED" ]; then
    hdr "Notes"
    if [ -n "$CONF_FINALIZED" ]; then
      info "finalized: ${CONF_FINALIZED} (${SOURCE} was removed)"
      finalized_json="\"$(json_esc "$CONF_FINALIZED")\""
    fi
    if [ -n "$CONF_ADOPTED" ]; then
      info "adopted: ${CONF_ADOPTED}"
      local a items="" oifs="$IFS"
      IFS=','
      for a in $CONF_ADOPTED; do
        items="${items}${items:+,}\"$(json_esc "$a")\""
      done
      IFS="$oifs"
      adopted_json="[${items}]"
    fi
  fi

  if [ "$JSON" -eq 1 ]; then
    printf '{"command":"status","version":"%s","claude_version":"%s","current_profile":%s,"profiles":[%s],"shared":{"dir":"%s","mode":"%s","size_kb":%s,"projects":%s,"transcripts":%s},"backups":{"count":%s,"latest":%s},"finalized":%s,"adopted":%s}\n' \
      "$(json_esc "$VERSION")" "$(json_esc "$cur")" "$current_profile_json" \
      "$json_profiles" \
      "$(json_esc "$SHARED")" "$(json_esc "$SHARE_MODE")" "$shared_kb" "$proj_count" "$trans_count" \
      "$backup_count" "$backup_latest_json" \
      "$finalized_json" "$adopted_json"
  fi
  return 0
}

# ---------------------------------------------------------------- rollback --

do_rollback() {
  hdr "Rollback"
  local name
  say "This removes ONLY what this script created:"
  for name in $PROFILES; do
    say "  $(profile_dir "$name")"
  done
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
  for name in $PROFILES; do
    d=$(profile_dir "$name")
    if [ -d "${d}/sessions" ] && [ -n "$(ls -A "${d}/sessions" 2>/dev/null)" ]; then
      warn "${d}/sessions is not empty: a Claude Code session may still be"
      warn "running in that profile. Quit it before continuing."
    fi
  done
  if [ "$OS" = "macos" ]; then
    info "macOS: the profiles' Keychain entries ('Claude Code-credentials…')"
    info "are not removed. Delete them in Keychain Access if you want."
  fi

  confirm "Remove everything listed above?" || { say "aborted"; return 0; }

  # The guard runs per directory, immediately before its own rm, so a source
  # that resolves to any one of them stops the whole command.
  for name in $PROFILES; do
    d=$(profile_dir "$name")
    same_path "$d" "$SOURCE" && die "refusing: '${d}' is the source profile"
  done
  same_path "$SHARED" "$SOURCE" && die "refusing: '${SHARED}' is the source profile"
  for name in $PROFILES; do
    d=$(profile_dir "$name")
    [ -d "$d" ] && { info "removing ${d}"; rm -rf "$d"; }
  done
  [ -d "$SHARED" ] && { info "removing ${SHARED}"; rm -rf "$SHARED"; }
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

# ------------------------------------------------- per-profile settings.json --
#
# `--settings NAME=PATH` seeds one profile's settings.json from a file of its
# own instead of the source's copy: the usual reason is a second account that
# needs a different model, statusLine or cleanupPeriodDays from day one.
# Nothing about it is recorded in the conf file, because it is a one-time
# seed and not a setting: after the copy the file is the profile's own, free
# to diverge like any other CONFIG_COPIED file.

settings_for() {
  # $1 = a profile name. Prints the path --settings gave for it, or nothing.
  # The prefix is held in a variable because a quoted literal inside ${x#...}
  # is parsed differently by bash 3.2 and 4.3+, as in relocate_settings_scripts.
  local want="$1" pair pre
  pre="${want}="
  for pair in $SETTINGS_PAIRS; do
    case "$pair" in
      "$pre"*) printf '%s' "${pair#"$pre"}"; return 0 ;;
    esac
  done
  return 0
}

settings_check() {
  # $1 = the names --settings may mention on this run (space separated).
  # Dies on an unknown name, a path that is not a readable regular file, or a
  # file that is not JSON at the crudest level. The whitespace rule is
  # enforced at parse time, where the argument is still one word.
  local names="$1" pair name path squashed pre
  [ -n "$SETTINGS_PAIRS" ] || return 0
  for pair in $SETTINGS_PAIRS; do
    name="${pair%%=*}"
    pre="${name}="
    path="${pair#"$pre"}"
    valid_name "$name" \
      || die "--settings names must be letters, digits, '_' or '-', got '${name}'"
    if ! in_list "$name" "$names"; then
      die "--settings names '${name}', which is not a profile this run is about.
       This run is about: $(printf '%s' "$names" | tr ' ' ',')."
    fi
    [ -n "$path" ] || die "--settings ${name}= has no path after the '='."
    [ -f "$path" ] || die "--settings ${name}=${path}: not a regular file."
    [ -r "$path" ] || die "--settings ${name}=${path}: not readable."
    # The crudest possible JSON check, on purpose: first non-space character
    # '{' and last '}'. There is no jq or python dependency in this script,
    # and a real parser written in awk would be worse than no parser at all.
    squashed=$(tr -d '[:space:]' < "$path")
    case "$squashed" in
      "{"*) ;;
      *) die "--settings ${name}=${path}: does not look like JSON. Its first
       non-space character is not '{'. (Not parsed further: this check is
       deliberately crude, it only catches the wrong file.)" ;;
    esac
    case "$squashed" in
      *"}") ;;
      *) die "--settings ${name}=${path}: does not look like JSON. Its last
       non-space character is not '}'." ;;
    esac
    ok "--settings ${name}: settings.json will be seeded from ${path}"
  done
}

# -------------------------------------------------- add / remove a profile --
#
# `apply` builds a whole setup at once. These two change the profile list of a
# setup that already exists. Both edit the conf file in place through
# rewrite_conf_key() rather than calling write_conf(), which knows only the
# keys apply writes and would drop FINALIZED= (and whatever a later version
# adds) on the floor.

rewrite_conf_key() {
  # Replace the "$1=" line of CONF_FILE with "$1=$2", keep every other line
  # exactly as it was, and append the key if it was not there at all.
  # Portable temp-file-then-mv in the same directory, the same shape as
  # record_conf_version(): sed -i is GNU-only.
  local key="$1" val="$2" tmp line wrote=0
  tmp="$(dirname "$CONF_FILE")/.$(basename "$CONF_FILE").tmp.$$"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "${key}="*) printf '%s=%s\n' "$key" "$val" >> "$tmp"; wrote=1 ;;
      *)          printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$CONF_FILE"
  [ "$wrote" -eq 1 ] || printf '%s=%s\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$CONF_FILE"
}

do_add() {
  # $1 = NAME[,NAME...]. Each new profile is created exactly as apply creates
  # a fresh, non-inheriting one: the CONFIG_COPIED files, then
  # relocate_settings_scripts, then one symlink per shared path. Credentials
  # and .claude.json are never copied, so every added profile starts logged
  # out and does its own browser login, which is the whole point of adding it.
  local arg="$1" new="" seen="" n d from csv oifs

  [ "$CONF_LOADED" -eq 1 ] \
    || die "no ${CONF_FILE}: there is no setup to add a profile to.
       Run 'apply' first; 'add' only extends what a recorded apply created."
  [ -d "$SHARED" ] \
    || die "${CONF_FILE} exists but '${SHARED}' does not. Run 'apply' first."

  # Split on commas only, exactly as --profiles does, so a name with a space
  # stays one token and is rejected below instead of becoming two profiles.
  # valid_name has to run inside this loop, while a name is still one field:
  # afterwards the names live in a space-separated string, where 'bad name'
  # would silently become the two profiles 'bad' and 'name'. in_list cannot
  # run here, because it splits its haystack on $IFS.
  oifs="$IFS"; IFS=','
  for n in $arg; do
    if ! valid_name "$n"; then
      IFS="$oifs"
      die "profile names must be letters, digits, '_' or '-', got '${n}'"
    fi
    new="${new}${new:+ }${n}"
  done
  IFS="$oifs"
  [ -n "$new" ] || die "'add' needs at least one name, got '${arg}'."

  for n in $new; do
    if in_list "$n" "$seen"; then
      die "'${n}' is listed twice in '${arg}'."
    fi
    if in_list "$n" "$PROFILES"; then
      die "'${n}' is already one of the profiles ($(profiles_csv)).
       Nothing to add. 'verify' shows the state of the ones you have."
    fi
    seen="${seen}${seen:+ }${n}"

    d=$(profile_dir "$n")
    if same_path "$d" "$SOURCE"; then
      die "refusing: '${d}' is the source profile '${SOURCE}'."
    fi
    if same_path "$d" "$SHARED"; then
      die "refusing: '${d}' is the shared directory '${SHARED}'."
    fi
    if [ -e "$d" ]; then
      [ -d "$d" ] || die "'${d}' exists and is not a directory. Move it aside first."
      if [ -n "$(profile_real_share_paths "$d")" ]; then
        die "'${d}' already holds real data (not symlinks) at:
       $(profile_real_share_paths "$d" | tr '\n' ' ')
       'add' creates a profile from scratch and will not link over that.
       Merging existing data into ${SHARED} is what --adopt is for:
         ./claude-profiles.sh apply --adopt --yes --profiles $(profiles_csv),${n}
       or move '${d}' aside and run 'add' again. Nothing has been changed."
      fi
      if [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
        die "'${d}' already exists and is not empty. 'add' creates a profile
       from scratch; move the directory aside and run it again."
      fi
    fi
  done

  hdr "Add profiles"
  from="$SOURCE"
  if [ ! -d "$from" ]; then
    # After finalize there is no source. The first profile is what apply
    # seeded from it, so it is the nearest thing to a template left.
    from=$(profile_dir "$(first_profile)")
    [ -d "$from" ] \
      || die "neither the source '${SOURCE}' nor the first profile '${from}'
       exists, so there is nothing to copy a settings.json from."
    info "source '${SOURCE}' is gone${CONF_FINALIZED:+ (finalize on ${CONF_FINALIZED})}, so"
    info "       settings.json, CLAUDE.md and the rest of the copied config"
    info "       come from the first profile instead: ${from}"
  else
    info "config copied from ${SOURCE}, which is only ever read"
  fi
  TEMPLATE_DIR="$from"

  settings_check "$new"

  csv=$(printf '%s' "$new" | tr ' ' ',')
  say ""
  say "  adding ${csv} to $(profiles_csv):"
  for n in $new; do
    say "    $(profile_dir "$n")     (claude-${n}, starts logged out)"
  done
  say "  ${SHARED} is only linked to, never copied again."
  say "  ${CONF_FILE} and ${SNIPPET_FILE} are rewritten to match."
  say "  ${SOURCE} is not touched."

  confirm "Create the profile(s) above?" || { say "aborted: nothing was changed."; return 1; }

  for n in $new; do
    make_profile "$(profile_dir "$n")" "$n" "no"
  done

  PROFILES="${PROFILES} ${new}"
  rewrite_conf_key PROFILES "$(profiles_csv)"
  ok "${CONF_FILE} now records PROFILES=$(profiles_csv)"

  write_snippet

  hdr "Next steps"
  say "  New launchers:"
  for n in $new; do
    say "    claude-${n}"
  done
  say ""
  say "  1. Open a NEW terminal, so the launcher functions load."
  say "  2. Run each new launcher and log in with its own account when the"
  say "     browser opens. Do NOT run /logout, in any profile, at any point."
  say "  3. Run:  ./claude-profiles.sh verify"
}

do_remove() {
  # $1 = NAME. Archives the whole profile directory (it holds credentials and
  # app state that exist nowhere else), deletes it, and drops the name from
  # the conf file and the launcher snippet. The shared data is deliberately
  # left alone: the other profiles are still using it, and the transcripts
  # written under this profile are in it.
  local name="$1" d archive parent base st=0 left="" ad="" tok n q oifs

  [ "$CONF_LOADED" -eq 1 ] \
    || die "no ${CONF_FILE}: there is no recorded setup to remove a profile
       from. Run 'apply' first."
  valid_name "$name" \
    || die "profile names must be letters, digits, '_' or '-', got '${name}'"
  in_list "$name" "$PROFILES" \
    || die "'${name}' is not one of the profiles ($(profiles_csv)). Nothing removed."
  [ "$(profiles_count)" -ge 2 ] \
    || die "'${name}' is the only profile left. Removing it would leave a
       setup with no profiles at all, which is 'rollback', not 'remove'."

  d=$(profile_dir "$name")
  archive="${BACKUP_ROOT}/claude-${name}-removed-${RUN_STAMP}.tar.gz"

  hdr "Remove profile: ${name}"
  say "  directory : ${d}"
  say "  archive   : ${archive}"
  say "  launcher  : claude-${name} (dropped from ${SNIPPET_FILE})"
  say ""
  say "  ${SHARED} is NOT touched: the transcripts, history and skills this"
  say "  profile used are shared, and the other profiles still use them."
  say "  ${SOURCE} is not touched either."
  warn "the profile's own credentials and .claude.json go with the directory."
  warn "They are in the archive, and nowhere else afterwards."

  if [ -d "${d}/sessions" ] && [ -n "$(ls -A "${d}/sessions" 2>/dev/null)" ]; then
    warn "${d}/sessions is not empty: Claude Code writes one file there per"
    warn "running session, so a session may still be live in this profile."
    die "refusing: quit that session, check ${d}/sessions is empty, then run
       remove again. Nothing was changed."
  fi

  q="Remove '${name}', archive and delete ${d}?"
  if [ "$name" = "$(first_profile)" ]; then
    warn "'${name}' is the FIRST profile: the one apply gave the login and app"
    warn "state copied from ${SOURCE}. Removing it leaves that login only in"
    warn "${SOURCE} (if it still exists) and in the archive below."
    q="'${name}' is the FIRST (inheriting) profile, the one carrying the login copied from ${SOURCE}. Remove it anyway, archive and delete ${d}?"
  fi
  confirm "$q" || { say "aborted: nothing was changed."; return 1; }

  if [ -d "$d" ]; then
    parent=$(dirname "$d")
    base=$(basename "$d")
    hdr "Archive"
    info "archive:  ${archive}"
    info "contents: ${d} (the whole directory, symlinks as symlinks)"
    info "mode 600, in a mode 700 directory: the archive contains credentials"
    archive_tree "$archive" -C "$parent" "$base" || st=$?
    if [ "$st" -eq 90 ]; then
      die "the archive does not read back cleanly: ${archive}. Nothing removed."
    elif [ "$st" -ne 0 ]; then
      die "the archive FAILED (tar exit ${st}). See ${archive}.log. Nothing removed."
    fi
    ok "archive written and read back ($(du -sh "$archive" | cut -f1))"
    same_path "$d" "$SOURCE" && die "refusing: '${d}' is the source profile"
    same_path "$d" "$SHARED" && die "refusing: '${d}' is the shared directory"
    info "removing ${d}"
    rm -rf "$d"
  else
    archive=""
    info "${d} does not exist; only the recorded list and the snippet change."
  fi

  for n in $PROFILES; do
    if [ "$n" != "$name" ]; then left="${left}${left:+ }${n}"; fi
  done
  PROFILES="$left"
  rewrite_conf_key PROFILES "$(profiles_csv)"
  if [ -n "$CONF_ADOPTED" ]; then
    # ADOPTED is a comma-separated list of names, so it is split on commas.
    oifs="$IFS"; IFS=','
    for tok in $CONF_ADOPTED; do
      if [ "$tok" != "$name" ]; then ad="${ad}${ad:+,}${tok}"; fi
    done
    IFS="$oifs"
    rewrite_conf_key ADOPTED "$ad"
  fi
  ok "${CONF_FILE} now records PROFILES=$(profiles_csv)"

  write_snippet

  hdr "Done"
  say "  '${name}' is gone, and ${SHARED} was not touched."
  if [ -n "$archive" ]; then
    say "  Its whole directory, credentials included, is in:"
    say "    ${archive}"
    say "  Extract it beside the others to put the profile back."
  fi
  say "  Remaining profiles: $(profiles_english claude- and)"
  say "  Open a new terminal, or re-source ${SNIPPET_FILE}, so the removed"
  say "  launcher stops being defined in shells that already loaded it."
}

# ---------------------------------------------------------------- finalize --

record_conf_finalized() {
  # Write FINALIZED=<stamp> into CONF_FILE, dropping any line already there so
  # a second finalize cannot leave two of them. Portable rewrite through a
  # temp file in the same directory, then mv: same shape as
  # record_conf_version(), because sed -i is GNU-only.
  local stamp="$1" tmp line
  tmp="$(dirname "$CONF_FILE")/.$(basename "$CONF_FILE").tmp.$$"
  : > "$tmp"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      FINALIZED=*) ;;
      *) printf '%s\n' "$line" >> "$tmp" ;;
    esac
  done < "$CONF_FILE"
  printf 'FINALIZED=%s\n' "$stamp" >> "$tmp"
  mv "$tmp" "$CONF_FILE"
}

do_finalize() {
  # The one command that deletes SOURCE. Every gate below is a refusal, in a
  # fixed order, and the confirmation is deliberately LAST: a run without
  # --yes prints every gate it passed and then stops, so it doubles as the
  # dry run that `plan` does not provide for this command.
  local conf_src d vst stamp archive src_is_home entries name first

  hdr "Finalize"
  say "This is the only command in this script that deletes ${SOURCE}."
  say "It runs eight gates first and asks before the deletion itself."

  # -- gate 1: an apply was recorded, and this is the source it used --------
  hdr "Gate 1: recorded setup"
  if [ "$CONF_LOADED" -eq 0 ]; then
    die "no ${CONF_FILE}. finalize only removes a source profile that a
       recorded 'apply' seeded from, because that file is the only evidence
       the new setup exists and which source it came from. Nothing deleted."
  fi
  if [ -n "$CONF_FINALIZED" ] && [ ! -d "$SOURCE" ]; then
    die "already finalized: ${CONF_FILE} records FINALIZED=${CONF_FINALIZED}
       and '${SOURCE}' is gone. There is nothing to remove."
  fi
  if [ -n "$CONF_SOURCE" ]; then
    conf_src="${CONF_SOURCE%/}"
    if ! same_path "$conf_src" "$SOURCE"; then
      die "refusing: ${CONF_FILE} records SOURCE=${conf_src}, but finalize was
       about to remove '${SOURCE}'. Drop the --source flag, or fix the conf
       file, so the thing deleted is the thing the setup was seeded from."
    fi
    ok "gate 1: ${CONF_FILE} records SOURCE=${conf_src}, which is what would be removed"
  else
    if ! same_path "$SOURCE" "${HOME}/.claude"; then
      die "refusing: ${CONF_FILE} records no SOURCE, so finalize only accepts
       the default ~/.claude, not '${SOURCE}'."
    fi
    ok "gate 1: no SOURCE in the conf file; '${SOURCE}' is the default ~/.claude"
  fi
  [ -d "$SOURCE" ] || die "'${SOURCE}' is not a directory. There is nothing to remove."
  ok "gate 1: '${SOURCE}' exists and is a directory"

  src_is_home=0
  if same_path "$SOURCE" "${HOME}/.claude"; then src_is_home=1; fi

  # -- gate 2: not one of the directories this script created ---------------
  hdr "Gate 2: not one of the new directories"
  for name in $PROFILES; do
    d=$(profile_dir "$name")
    if same_path "$SOURCE" "$d"; then
      die "refusing: '${SOURCE}' resolves to '${d}', which this script created.
       finalize removes the OLD profile, never the new ones. If you want the
       new ones gone, that is 'rollback'."
    fi
  done
  if same_path "$SOURCE" "$SHARED"; then
    die "refusing: '${SOURCE}' resolves to '${SHARED}', which this script created.
       finalize removes the OLD profile, never the new ones. If you want the
       new ones gone, that is 'rollback'."
  fi
  ok "gate 2: '${SOURCE}' is none of $(profiles_english "${HOME}/.claude-" and), ${SHARED}"

  # -- gate 3: the new setup is actually healthy ----------------------------
  hdr "Gate 3: full verify"
  info "${SOURCE} is the fallback, so it only goes once the replacement is clean."
  vst=0
  do_verify || vst=$?
  if [ "$vst" -ne 0 ]; then
    die "verify reports problems (above). Not deleting '${SOURCE}': while the
       new setup is broken, the old profile is the thing you fall back to.
       Fix what verify flagged and run finalize again."
  fi
  hdr "Gate 3 result"
  ok "gate 3: verify passed with no problems"

  # -- gate 4: nothing still points into the source -------------------------
  hdr "Gate 4: no settings pointing into ${SOURCE}"
  for name in $PROFILES; do
    d=$(profile_dir "$name")
    if refs_old_profile "${d}/settings.json"; then
      warn "still pointing there: $(find_old_claude_paths "${d}/settings.json" | tr '\n' ' ')"
      die "${d}/settings.json still references paths under ~/.claude/.
       Deleting '${SOURCE}' would break that statusLine, hook or command.
       Re-run 'apply' (it relocates such scripts into ${SHARED} and repoints
       the setting), or fix the path by hand, then run finalize again."
    fi
  done
  ok "gate 4: no profile's settings.json references a path under ${SOURCE}"

  # -- gate 5: no live session on the old profile ---------------------------
  hdr "Gate 5: no session running on ${SOURCE}"
  entries=""
  if [ -d "${SOURCE}/sessions" ]; then
    # Same ls -A test do_rollback uses. No pipe: a session file name is
    # printed below through printf, not parsed here.
    entries=$(ls -A "${SOURCE}/sessions" 2>/dev/null) || entries=""
  fi
  if [ -n "$entries" ]; then
    warn "${SOURCE}/sessions is not empty:"
    printf '%s\n' "$entries" | sed 's/^/      /' >&2
    warn "Claude Code writes one file there per running session, so a session"
    warn "may still be live on the old profile. Deleting it under a running"
    warn "session loses that session's transcript."
    if [ -z "${CLAUDE_CONFIG_DIR:-}" ] || same_path "${CLAUDE_CONFIG_DIR:-}" "$SOURCE"; then
      warn ""
      warn "CLAUDE_CONFIG_DIR is '${CLAUDE_CONFIG_DIR:-unset}', so the terminal"
      warn "running this may itself be a Claude Code session on the old"
      warn "profile. Run finalize from a $(profiles_english claude-)"
      warn "session, or from a plain terminal after quitting that session."
    fi
    die "refusing: ${SOURCE}/sessions has entries. Quit the session, check
       that ${SOURCE}/sessions is empty, then run finalize again."
  fi
  ok "gate 5: ${SOURCE}/sessions is empty or absent (no live session there)"

  # -- gate 6: the profiles hold their own credentials ----------------------
  # Only the FIRST profile inherited the login and app state that deleting
  # SOURCE would otherwise take with it; the others were always meant to
  # start empty, so a missing credentials file there is not this gate's
  # business.
  first=$(first_profile)
  local first_dir
  first_dir=$(profile_dir "$first")
  hdr "Gate 6: the inheriting profile's own credentials"
  if [ -f "${first_dir}/.credentials.json" ]; then
    ok "gate 6: ${first_dir}/.credentials.json is a real file of its own"
  elif [ "$OS" = "macos" ]; then
    ok "gate 6: no ${first_dir}/.credentials.json, which is expected on macOS"
    info "(the Keychain entry is keyed to the config directory, so the profile"
    info " has its own login there rather than in a file)"
  else
    die "${first_dir} has no .credentials.json of its own. On Linux that means
       the '${first}' profile is not carrying the login you meant to keep, and
       '${SOURCE}' may be the only place it exists. Launch claude-${first} and
       log in (never /logout), or re-run 'apply', before finalize."
  fi
  if [ ! -f "${first_dir}/.claude.json" ]; then
    die "${first_dir}/.claude.json is missing: the '${first}' profile has no app
       state of its own (onboarding, project trust, user-scope MCP servers).
       Launch claude-${first} once, or re-run 'apply', before finalize."
  fi
  ok "gate 6: ${first_dir}/.claude.json is present"
  info "both are copies, so deleting ${SOURCE} cannot affect them. Checked"
  info "anyway: a missing one means the login is not in the new profile yet."

  # -- gate 7: a backup that reads back -------------------------------------
  hdr "Gate 7: backup"
  archive=""
  if [ "$DO_BACKUP" -eq 1 ]; then
    do_backup
    archive=$(cat "${BACKUP_ROOT}/.latest" 2>/dev/null || true)
    [ -n "$archive" ] && [ -f "$archive" ] \
      || die "the backup did not leave a readable archive named in ${BACKUP_ROOT}/.latest. Not deleting anything."
    ok "gate 7: fresh backup taken and read back: ${archive}"
  else
    info "--no-backup: requiring an archive that already exists instead."
    [ -f "${BACKUP_ROOT}/.latest" ] \
      || die "--no-backup given, but ${BACKUP_ROOT}/.latest does not exist, so
       there is no recorded archive to fall back to. Re-run without
       --no-backup and let finalize take one."
    archive=$(cat "${BACKUP_ROOT}/.latest")
    [ -n "$archive" ] && [ -f "$archive" ] \
      || die "--no-backup given, and ${BACKUP_ROOT}/.latest names '${archive}',
       which is not a file. Re-run without --no-backup."
    tar tzf "$archive" >/dev/null 2>&1 \
      || die "--no-backup given, and the archive named by .latest does not list
       cleanly: ${archive}. Re-run without --no-backup."
    stamp=$(basename "$archive" .tar.gz); stamp="${stamp#claude-}"
    ok "gate 7: existing archive lists cleanly: ${archive}"
    info "taken at ${stamp} (from its name), i.e. NOT during this run:"
    info "$(ls -l "$archive")"
    warn "anything written to ${SOURCE} since then is not in that archive."
  fi

  # -- gate 8: the summary, then the only confirmation ----------------------
  hdr "Gate 8: what finalize is about to delete"
  say ""
  say "  DELETE, permanently:"
  say "    ${SOURCE}   ($(du -sh "$SOURCE" 2>/dev/null | cut -f1) on disk)"
  if [ "$src_is_home" -eq 1 ] && [ -f "${HOME}/.claude.json" ]; then
    say "    ${HOME}/.claude.json   (its copy lives in ${first_dir}/.claude.json)"
  fi
  say ""
  say "  held in this archive, and nowhere else afterwards:"
  say "    ${archive}"
  say ""
  say "  stays, and is your setup from now on:"
  for name in $PROFILES; do
    say "    $(profile_dir "$name")     (claude-${name})"
  done
  say "    ${SHARED}"
  say "    ${BACKUP_ROOT}"
  say ""
  warn "This is the irreversible step. Everything above it was reversible;"
  warn "after it, the only way back to ${SOURCE} is extracting that archive"
  warn "(ROLLBACK.md, Level 3)."

  confirm "Delete ${SOURCE} permanently? There is no undo except the archive." \
    || { say ""; say "aborted: nothing was deleted. Every gate above passed,"; \
         say "so this run was its own dry run."; return 1; }

  # -- the deletion ---------------------------------------------------------
  hdr "Removing"
  info "rm -rf ${SOURCE}"
  rm -rf "$SOURCE"
  if [ "$src_is_home" -eq 1 ] && [ -f "${HOME}/.claude.json" ]; then
    info "rm -f ${HOME}/.claude.json"
    rm -f "${HOME}/.claude.json"
  fi
  stamp="$(date +%Y%m%d-%H%M%S)"
  record_conf_finalized "$stamp"
  ok "recorded FINALIZED=${stamp} in ${CONF_FILE}"

  hdr "Done"
  say "  ${SOURCE} is gone. $(profiles_english "${HOME}/.claude-" and) are the"
  say "  setup now; launch them with $(profiles_english claude- and) as before."
  say "  'verify' keeps working and now reports the source as removed."
  say ""
  say "  The only way back is the archive:"
  say "    ${archive}"
  say "  Extract it as described in ROLLBACK.md, Level 3, which is now the"
  say "  only rollback level that can restore the old profile."
}

# -------------------------------------------------------------------- main --

banner() {
  say ""
  say "claude-profiles v${VERSION}   os=${OS}  share=${SHARE_MODE}"
  [ "$CONF_LOADED" -eq 1 ] && say "  (profiles/mode/source remembered from ${CONF_FILE}; flags override)"
  if [ -n "$CONF_FINALIZED" ] && [ ! -d "$SOURCE" ]; then
    say "  source (removed by finalize on ${CONF_FINALIZED}) : ${SOURCE}"
  else
    say "  source (never modified) : ${SOURCE}"
  fi
  local n line="" i=0
  for n in $PROFILES; do
    i=$((i+1))
    if [ "$i" -eq 1 ]; then line="${n} (inherits current login)"
    else line="${line}, ${n}"; fi
  done
  say "  profiles                : ${line}"
  say "  profile dirs            : ${HOME}/.claude-<name>, one per name above"
  say "  shared data             : ${SHARED}"
}

build_profiles() {
  # Adopt-then-link, profile by profile, in the order the list gives. The
  # first name is the one that inherits the current login; every other one
  # starts empty.
  local name dir inherit=yes
  for name in $PROFILES; do
    dir=$(profile_dir "$name")
    do_adopt "$dir" "$name" "$(adopt_paths_for "$name")"
    make_profile "$dir" "$name" "$inherit"
    inherit=no
  done
}

case "$CMD" in
  plan)
    DRY=1
    banner
    preflight
    do_backup
    seed_shared
    write_conf
    build_profiles
    write_snippet
    hdr "Plan complete"
    info "Nothing was changed. Re-run with 'apply' to execute."
    ;;
  apply)
    DRY=0
    banner
    preflight
    say ""
    say "About to create the directories above. ${SOURCE} is only read."
    confirm "Proceed?" || { say "aborted"; exit 1; }
    do_backup
    seed_shared
    write_conf
    build_profiles
    write_snippet
    hdr "Next steps"
    FIRST_NAME=$(first_profile)
    say "  1. Open a NEW terminal (so the launcher functions load)."
    say "  2. Run:  claude-${FIRST_NAME}"
    say "     It should already be logged in as your current account."
    say "     If it asks you to log in, log in with the SAME account."
    say "     Do NOT run /logout, in any profile, at any point."
    say "  3. Quit, then run each of the others and log in with its own"
    say "     account when the browser opens:"
    SECOND_NAME=""
    for n in $PROFILES; do
      [ "$n" = "$FIRST_NAME" ] && continue
      [ -n "$SECOND_NAME" ] || SECOND_NAME="$n"
      say "       claude-${n}"
    done
    say "  4. Run:  ./claude-profiles.sh verify"
    say "     Pay attention to the .claude.json section."
    say "  5. Confirm sharing works: start a session in one profile, then"
    say "     run  claude-${SECOND_NAME} --resume  in the same project directory."
    say ""
    say "  ${SOURCE} is untouched and still works, and the shared data is a"
    say "  copy, so it is on disk twice until you remove it. When you are"
    say "  happy with the new setup, run:"
    say ""
    say "      ./claude-profiles.sh finalize"
    say ""
    say "  That is the supported way to delete ${SOURCE}: it re-runs verify,"
    say "  checks nothing still points into it and no session is running on"
    say "  it, takes a fresh backup, and then asks. Do not rm -rf it by hand."
    ;;
  status)
    banner
    do_status
    ;;
  verify)
    banner
    vst=0
    do_verify || vst=$?
    [ "$JSON" -eq 1 ] && json_emit_verify
    exit "$vst"
    ;;
  rollback)
    banner
    do_rollback
    ;;
  add)
    DRY=0
    banner
    do_add "$CMD_ARG"
    ;;
  remove)
    DRY=0
    banner
    do_remove "$CMD_ARG"
    ;;
  finalize)
    DRY=0
    banner
    do_finalize
    ;;
esac
