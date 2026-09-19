#!/usr/bin/env bash
# End-to-end test of claude-profiles.sh against a throwaway fake HOME.
# Never touches the real ~/.claude. Runs on Linux and macOS (bash 3.2+).
#
#   tests/e2e.sh                      # tests ../claude-profiles.sh
#   tests/e2e.sh path/to/script.sh    # tests another copy
set -u
SCRIPT="${1:-$(cd "$(dirname "$0")/.." && pwd)/claude-profiles.sh}"
[ -f "$SCRIPT" ] || { echo "no such script: $SCRIPT" >&2; exit 2; }

# GNU stat and BSD stat disagree on everything; wrap the two calls we need.
if stat -c %a / >/dev/null 2>&1; then
  fmode()  { stat -c %a "$1"; }
  fmtime() { stat -c %Y "$1"; }
else
  fmode()  { stat -f %Lp "$1"; }
  fmtime() { stat -f %m "$1"; }
fi
# Fingerprint of a tree: name, mode, size, mtime (minute precision, which is
# what ls -l gives portably; tar stores whole seconds anyway).
snap() { (cd "$HOME" && find .claude .claude.json -exec ls -ld {} + | sort | cksum); }
T="$(mktemp -d "${TMPDIR:-/tmp}/cp-e2e.XXXXXX")"
export HOME="$T/home"
export SHELL=/bin/bash
unset CLAUDE_CONFIG_DIR
mkdir -p "$HOME"
pass=0; fail=0
check() { if eval "$2"; then pass=$((pass+1)); echo "PASS $1"; else fail=$((fail+1)); echo "FAIL $1"; fi; }

# --- fake source profile -----------------------------------------------------
C="$HOME/.claude"
mkdir -p "$C/projects/-fake-proj" "$C/file-history/s1" "$C/skills/x" "$C/sessions" "$C/plans" "$C/paste-cache"
printf '{"type":"user","msg":"hi"}\n' > "$C/projects/-fake-proj/s1.jsonl"
printf '{"display":"prompt one"}\n' > "$C/history.jsonl"
printf '#!/bin/sh\necho ok\n' > "$C/statusline.sh"; chmod +x "$C/statusline.sh"
printf '{"cleanupPeriodDays": 3650, "statusLine": {"command": "~/.claude/statusline.sh"}, "hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "$HOME/.claude/hooks/missing.sh"}]}]}}\n' > "$C/settings.json"
printf '# my claude md\n' > "$C/CLAUDE.md"
printf '{"claudeAiOauth":{"accessToken":"FAKE"}}\n' > "$C/.credentials.json"; chmod 600 "$C/.credentials.json"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"a@b"}}\n' > "$HOME/.claude.json"
touch -t 202501010000 "$C/projects/-fake-proj/s1.jsonl"      # old mtime, must survive copy
ln -s /nonexistent-target "$C/skills/dangling"                 # symlink inside source
printf 'export PATH=$PATH\n' > "$HOME/.bashrc"
before=$(snap)

echo "=== plan ==="
bash "$SCRIPT" plan > "$T/plan.out" 2>&1; rc=$?
check "plan exits 0" "[ $rc -eq 0 ]"
check "plan creates nothing" "[ ! -e $HOME/.claude-work ] && [ ! -e $HOME/.claude-shared ] && [ ! -e $HOME/.claude-backups ]"
check "plan never names ~/.claude as write target" "! grep 'would run:' $T/plan.out | awk '{print \$NF}' | grep -Eq '/\.claude(/|$)'"

echo "=== apply without --yes and no tty (Claude Code case) ==="
bash "$SCRIPT" apply --shell > "$T/apply-notty.out" 2>&1 </dev/null; rc=$?
check "apply aborts cleanly without tty" "[ $rc -ne 0 ] && grep -q -- '--yes' $T/apply-notty.out"
check "aborted apply created nothing" "[ ! -e $HOME/.claude-work ] && [ ! -e $HOME/.claude-shared ]"

echo "=== apply --yes --shell ==="
bash "$SCRIPT" apply --yes --shell > "$T/apply.out" 2>&1; rc=$?
check "apply exits 0" "[ $rc -eq 0 ]"
after=$(snap)
check "source profile byte-identical after apply" "[ '$before' = '$after' ]"
check "backup archive exists" "ls $HOME/.claude-backups/claude-*.tar.gz >/dev/null 2>&1"
check "backup dir 700 / archive 600" "[ \$(fmode $HOME/.claude-backups) = 700 ] && [ \$(fmode $HOME/.claude-backups/claude-*.tar.gz) = 600 ]"
check ".latest points at archive" "[ -f \"\$(cat $HOME/.claude-backups/.latest)\" ]"
check "backup contains .claude and .claude.json" "tar tzf $HOME/.claude-backups/claude-*.tar.gz | grep -q '^\.claude/settings.json' && tar tzf $HOME/.claude-backups/claude-*.tar.gz | grep -q '^\.claude\.json'"
check "shared projects copied" "[ -f $HOME/.claude-shared/projects/-fake-proj/s1.jsonl ]"
check "mtime preserved on copy" "[ \$(fmtime $HOME/.claude-shared/projects/-fake-proj/s1.jsonl) = \$(fmtime $C/projects/-fake-proj/s1.jsonl) ]"
check "no partial leftovers" "! ls -A $HOME/.claude-shared | grep -q partial"
check "work/projects is symlink to shared" "[ \"\$(readlink $HOME/.claude-work/projects)\" = $HOME/.claude-shared/projects ]"
check "personal/history.jsonl is symlink" "[ -L $HOME/.claude-personal/history.jsonl ]"
check "work has own credentials (real file, 600)" "[ -f $HOME/.claude-work/.credentials.json ] && [ ! -L $HOME/.claude-work/.credentials.json ] && [ \$(fmode $HOME/.claude-work/.credentials.json) = 600 ]"
check "work has copied .claude.json" "[ -f $HOME/.claude-work/.claude.json ] && grep -q hasCompletedOnboarding $HOME/.claude-work/.claude.json"
check "personal has NO credentials/.claude.json" "[ ! -e $HOME/.claude-personal/.credentials.json ] && [ ! -e $HOME/.claude-personal/.claude.json ]"
check "settings copied to both" "[ -f $HOME/.claude-work/settings.json ] && [ -f $HOME/.claude-personal/settings.json ]"
check "shared statusline.sh copied and executable" "[ -x $HOME/.claude-shared/statusline.sh ]"
check "work settings.json repointed to shared statusline" "grep -q '~/.claude-shared/statusline.sh' $HOME/.claude-work/settings.json && ! grep -q '~/.claude/statusline.sh' $HOME/.claude-work/settings.json"
check "personal settings.json repointed to shared statusline" "grep -q '~/.claude-shared/statusline.sh' $HOME/.claude-personal/settings.json && ! grep -q '~/.claude/statusline.sh' $HOME/.claude-personal/settings.json"
check "missing hook path left unchanged in work settings" "grep -q '\$HOME/.claude/hooks/missing.sh' $HOME/.claude-work/settings.json"
check "missing hook path left unchanged in personal settings" "grep -q '\$HOME/.claude/hooks/missing.sh' $HOME/.claude-personal/settings.json"
check "work settings.json still valid JSON" "python3 -m json.tool $HOME/.claude-work/settings.json >/dev/null"
check "personal settings.json still valid JSON" "python3 -m json.tool $HOME/.claude-personal/settings.json >/dev/null"
check "source settings.json still references the old path" "grep -q '~/.claude/statusline.sh' $C/settings.json"
check "conf recorded" "grep -q '^SHARE_MODE=full' $HOME/.claude-shared/.claude-profiles.conf"
check "snippet written" "grep -q '^claude-work()' $HOME/.claude-profiles.sh"
check "bashrc sources snippet once" "[ \$(grep -c 'claude-profiles.sh' $HOME/.bashrc) -eq 1 ]"

echo "=== snippet behaviour in bash ==="
out=$(bash -c ". $HOME/.claude-profiles.sh; claude --version" 2>&1); rc=$?
check "bare claude blocked" "[ $rc -ne 0 ] && printf '%s' \"$out\" | grep -q 'Pick a profile'"
mkdir -p "$T/bin"
cat > "$T/bin/claude" <<'STUB'
#!/bin/sh
if [ "$1" = "--version" ]; then
  echo "9.9.9 (Claude Code)"
  exit 0
fi
if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  creds="$CLAUDE_CONFIG_DIR/.credentials.json"
  if [ ! -f "$creds" ]; then
    echo '{"loggedIn": false, "authMethod": "none"}'
    exit 1
  fi
  # ACCT-<word> gives a distinct identity per profile, which the
  # three-profile section needs; the two fixed tokens below predate it.
  acct=$(sed -n 's/.*"accessToken":"ACCT-\([A-Za-z0-9]*\)".*/\1/p' "$creds")
  if [ -n "$acct" ]; then
    echo "{\"loggedIn\": true, \"authMethod\": \"claude.ai\", \"email\": \"$acct@example.com\", \"orgName\": \"Org $acct\", \"subscriptionType\": \"max\"}"
    exit 0
  fi
  if grep -q FAKE-WORK "$creds" 2>/dev/null; then
    echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "work@example.com", "orgName": "Work Org", "subscriptionType": "team"}'
    exit 0
  fi
  echo '{"loggedIn": true, "authMethod": "claude.ai", "email": "me@example.com", "orgName": "Personal", "subscriptionType": "max"}'
  exit 0
fi
echo "CFG=${CLAUDE_CONFIG_DIR:-unset} ARGS=$*"
STUB
chmod +x "$T/bin/claude"
# From here on, every claude-profiles.sh invocation in this test sees the
# stub instead of any real claude binary that may also be on PATH. This
# keeps `verify`'s new Accounts section deterministic: the real binary run
# against a profile dir it has never launched creates .claude.json and
# backups/ there as a side effect (see claude-profiles.sh profile_auth()),
# which would corrupt the "launched but no .claude.json" scenario below.
PATH="$T/bin:$PATH"
out=$(PATH="$T/bin:$PATH" bash -c ". $HOME/.claude-profiles.sh; claude-work --resume x")
check "claude-work sets CLAUDE_CONFIG_DIR and passes args" "[ \"$out\" = 'CFG=$HOME/.claude-work ARGS=--resume x' ]"
out=$(PATH="$T/bin:$PATH" CLAUDE_CONFIG_DIR=/elsewhere bash -c ". $HOME/.claude-profiles.sh; claude mcp list")
check "bare claude passes through when CLAUDE_CONFIG_DIR set" "[ \"$out\" = 'CFG=/elsewhere ARGS=mcp list' ]"

echo "=== apply again (idempotent, --no-backup) ==="
n_before=$(ls "$HOME/.claude-backups"/*.tar.gz | wc -l)
bash "$SCRIPT" apply --yes --shell --no-backup > "$T/apply2.out" 2>&1; rc=$?
check "second apply exits 0" "[ $rc -eq 0 ]"
check "no second backup taken" "[ \$(ls $HOME/.claude-backups/*.tar.gz | wc -l) -eq $n_before ]"
check "bashrc still sources once" "[ \$(grep -c 'claude-profiles.sh' $HOME/.bashrc) -eq 1 ]"
check "second apply keeps existing" "grep -q 'keep   projects' $T/apply2.out"

echo "=== verify (no flags; conf drives it) ==="
bash "$SCRIPT" verify > "$T/verify1.out" 2>&1; rc=$?
check "verify before launch: only shell-independent checks, exit 0" "[ $rc -eq 0 ]"
check "verify warns about settings pointing at ~/.claude (missing hook only)" "grep -q 'references paths under' $T/verify1.out && grep -q 'hooks/missing.sh' $T/verify1.out"
# simulate: personal launched but .claude.json went to ~/.claude.json (bad version)
mkdir -p "$HOME/.claude-personal/sessions"; printf '{}' > "$HOME/.claude-personal/sessions/1234.json"
bash "$SCRIPT" verify > "$T/verify2.out" 2>&1; rc=$?
check "verify flags launched profile without .claude.json" "[ $rc -ne 0 ] && grep -q 'NOT isolated' $T/verify2.out"
printf '{}' > "$HOME/.claude-personal/.claude.json"
printf '{"cleanupPeriodDays": 7}' > "$HOME/.claude-personal/settings.json"
bash "$SCRIPT" verify > "$T/verify3.out" 2>&1; rc=$?
check "verify flags mismatched cleanupPeriodDays" "[ $rc -ne 0 ] && grep -q 'These differ' $T/verify3.out"
printf '{"cleanupPeriodDays": 3650}' > "$HOME/.claude-personal/settings.json"
rm "$HOME/.claude-work/.credentials.json"; ln -s "$HOME/.claude-personal/.credentials.json" "$HOME/.claude-work/.credentials.json"
bash "$SCRIPT" verify > "$T/verify4.out" 2>&1; rc=$?
check "verify flags symlinked credentials" "[ $rc -ne 0 ] && grep -q 'SYMLINK' $T/verify4.out"
rm "$HOME/.claude-work/.credentials.json"; cp "$C/.credentials.json" "$HOME/.claude-work/.credentials.json"
bash "$SCRIPT" verify > "$T/verify5.out" 2>&1; rc=$?
check "verify clean after fixes" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/verify5.out"

echo "=== verify: Accounts section ==="
# At this point: work has a real copy of the source's (FAKE, not FAKE-WORK)
# credentials, so the stub reports it logged in as me@example.com/Personal.
# personal has no .credentials.json at all yet, so the stub reports it
# logged out. Neither is a "problem" on its own.
PATH="$T/bin:$PATH" bash "$SCRIPT" verify > "$T/verify-acc1.out" 2>&1; rc=$?
check "accounts: single logged-in profile is not a problem" "[ $rc -eq 0 ]"
check "accounts: launched profile with copied source creds shows its email" "grep -q 'work: me@example.com (Personal, max)' $T/verify-acc1.out"
check "accounts: profile with no credentials yet reports not logged in" "grep -q 'personal: not logged in' $T/verify-acc1.out"

printf '{"claudeAiOauth":{"accessToken":"FAKE-WORK"}}\n' > "$HOME/.claude-personal/.credentials.json"
chmod 600 "$HOME/.claude-personal/.credentials.json"
PATH="$T/bin:$PATH" bash "$SCRIPT" verify > "$T/verify-acc2.out" 2>&1; rc=$?
check "accounts: two different accounts, exits 0" "[ $rc -eq 0 ]"
check "accounts: work email shown" "grep -q 'work: me@example.com (Personal, max)' $T/verify-acc2.out"
check "accounts: personal email shown" "grep -q 'personal: work@example.com (Work Org, team)' $T/verify-acc2.out"

cp "$HOME/.claude-work/.credentials.json" "$HOME/.claude-personal/.credentials.json"
PATH="$T/bin:$PATH" bash "$SCRIPT" verify > "$T/verify-acc3.out" 2>&1; rc=$?
check "accounts: same account in both profiles is flagged, exits non-zero" "[ $rc -ne 0 ] && grep -qi 'same account' $T/verify-acc3.out"

# Restore personal to its own distinct fake identity so it again differs
# from work's, keeping the rest of this suite (which expects clean verify
# runs below) unaffected by this deliberately-broken scenario.
printf '{"claudeAiOauth":{"accessToken":"FAKE-WORK"}}\n' > "$HOME/.claude-personal/.credentials.json"
chmod 600 "$HOME/.claude-personal/.credentials.json"

echo "=== Claude Code version tracking ==="
CONF="$HOME/.claude-shared/.claude-profiles.conf"
check "conf has a CLAUDE_VERSION line after apply" "grep -q '^CLAUDE_VERSION=' $CONF"
PATH="$T/bin:$PATH" bash "$SCRIPT" verify > "$T/verify-ver1.out" 2>&1; rc=$?
check "verify with claude stub on PATH exits 0" "[ $rc -eq 0 ]"
check "conf CLAUDE_VERSION now matches the stub's version" "grep -q '^CLAUDE_VERSION=9.9.9$' $CONF"
grep -v '^CLAUDE_VERSION=' "$CONF" > "$T/conf.tmp" && printf 'CLAUDE_VERSION=1.0.0\n' >> "$T/conf.tmp" && mv "$T/conf.tmp" "$CONF"
PATH="$T/bin:$PATH" bash "$SCRIPT" verify > "$T/verify-ver2.out" 2>&1; rc=$?
check "verify warns about version drift" "grep -qi 'versions differ' $T/verify-ver2.out"
check "version drift is not counted as a problem" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/verify-ver2.out"
check "conf CLAUDE_VERSION updated back to current after clean verify" "grep -q '^CLAUDE_VERSION=9.9.9$' $CONF"

echo "=== bad inputs ==="
bash "$SCRIPT" plan --main 'bad name' >/dev/null 2>&1; check "rejects name with space" "[ $? -ne 0 ]"
bash "$SCRIPT" plan --main x --second x >/dev/null 2>&1; check "rejects main == second" "[ $? -ne 0 ]"
bash "$SCRIPT" plan --source "$HOME/.claude-shared" >/dev/null 2>&1; check "rejects source == shared" "[ $? -ne 0 ]"
bash "$SCRIPT" plan --share nope >/dev/null 2>&1; check "rejects bad share mode" "[ $? -ne 0 ]"

echo "=== edge cases ==="

# -- 1. --source pointing at a directory other than ~/.claude ---------------
AS="$T/altsrc"
H1="$T/home_altsrc"
mkdir -p "$H1" "$AS/projects/-altproj"
printf '{"type":"user","msg":"altsrc session"}\n' > "$AS/projects/-altproj/s1.jsonl"
printf '{"cleanupPeriodDays": 30}\n' > "$AS/settings.json"
printf '{"claudeAiOauth":{"accessToken":"ALTSRC"}}\n' > "$AS/.credentials.json"
chmod 600 "$AS/.credentials.json"
HOME="$H1" bash "$SCRIPT" apply --yes --shell --source "$AS" > "$T/apply-altsrc.out" 2>&1; rc=$?
check "altsrc: apply exits 0" "[ $rc -eq 0 ]"
check "altsrc: backup archive lists altsrc/settings.json" "tar tzf $H1/.claude-backups/claude-*.tar.gz | grep -q '^altsrc/settings.json'"
check "altsrc: shared projects copy came from altsrc" "grep -q 'altsrc session' $H1/.claude-shared/projects/-altproj/s1.jsonl"
check "altsrc: main profile credentials came from altsrc" "grep -q ALTSRC $H1/.claude-work/.credentials.json"
check "altsrc: conf records SOURCE" "grep -qF 'SOURCE=$AS' $H1/.claude-shared/.claude-profiles.conf"
HOME="$H1" bash "$SCRIPT" verify > "$T/verify-altsrc.out" 2>&1; rc=$?
check "altsrc: verify exits 0" "[ $rc -eq 0 ]"

# -- 2. backup failure aborts before any change ------------------------------
H2="$T/home_backupfail"
mkdir -p "$H2/.claude"
printf '{"cleanupPeriodDays": 30}\n' > "$H2/.claude/settings.json"
printf 'orig-content\n' > "$H2/.bashrc"
: > "$H2/.claude-backups"   # a regular FILE where a directory must go: mkdir -p fails
HOME="$H2" bash "$SCRIPT" apply --yes > "$T/apply-backupfail.out" 2>&1; rc=$?
check "backup failure: apply exits non-zero" "[ $rc -ne 0 ]"
check "backup failure: no shared dir created" "[ ! -e $H2/.claude-shared ]"
check "backup failure: no work dir created" "[ ! -e $H2/.claude-work ]"
check "backup failure: no personal dir created" "[ ! -e $H2/.claude-personal ]"
check "backup failure: bashrc not modified" "[ \"\$(cat $H2/.bashrc)\" = 'orig-content' ]"

# -- 3. stale partial copy cleanup -------------------------------------------
H3="$T/home_stale"
mkdir -p "$H3/.claude/projects/-fake-proj"
printf '{"type":"user","msg":"hi3"}\n' > "$H3/.claude/projects/-fake-proj/s1.jsonl"
printf '{"cleanupPeriodDays": 30}\n' > "$H3/.claude/settings.json"
mkdir -p "$H3/.claude-shared/.projects.partial"
printf 'junk\n' > "$H3/.claude-shared/.projects.partial/junkfile"
HOME="$H3" bash "$SCRIPT" apply --yes > "$T/apply-stale.out" 2>&1; rc=$?
check "stale partial: apply exits 0" "[ $rc -eq 0 ]"
check "stale partial: output mentions stale partial" "grep -q 'stale partial' $T/apply-stale.out"
check "stale partial: .partial dir is gone" "[ ! -e $H3/.claude-shared/.projects.partial ]"
check "stale partial: real session file present in shared projects" "[ -f $H3/.claude-shared/projects/-fake-proj/s1.jsonl ]"

# -- 4. dangling shared link detection (main fixture) ------------------------
rm -rf "$HOME/.claude-shared/plans"
bash "$SCRIPT" verify > "$T/verify-dangling.out" 2>&1; rc=$?
check "dangling link: verify exits non-zero" "[ $rc -ne 0 ]"
check "dangling link: verify mentions dangling" "grep -q 'dangling' $T/verify-dangling.out"
mkdir -p "$HOME/.claude-shared/plans"
bash "$SCRIPT" verify > "$T/verify-dangling-fixed.out" 2>&1; rc=$?
check "dangling link: verify clean once target exists again" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/verify-dangling-fixed.out"

# -- 5. source-profile invariant: a symlink INSIDE the fake ~/.claude -------
# pointing into ~/.claude-shared. This writes into the FIXTURE's ~/.claude
# (never the real one) to prove verify catches the one thing the script
# itself must never do. "rules" is in SHARE_ALL and does not already exist
# under $C, so it does not collide with anything the fixture set up earlier.
# Creating and removing an entry bumps $C's own mtime, which the final
# fingerprint compares at minute precision; save and restore it (touch -r
# is in both GNU and BSD touch).
touch -r "$C" "$T/c-mtime.ref"
ln -s "$HOME/.claude-shared/rules" "$C/rules"
bash "$SCRIPT" verify > "$T/verify-srcinvariant.out" 2>&1; rc=$?
check "source invariant: verify exits non-zero" "[ $rc -ne 0 ]"
check "source invariant: verify mentions symlink INTO" "grep -qi 'symlink INTO' $T/verify-srcinvariant.out"
rm -f "$C/rules"; touch -r "$T/c-mtime.ref" "$C"
bash "$SCRIPT" verify > "$T/verify-srcinvariant-fixed.out" 2>&1; rc=$?
check "source invariant: verify clean after removing the stray symlink" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/verify-srcinvariant-fixed.out"

# -- 6. zsh: same three snippet behaviours the bash block checked -----------
if command -v zsh >/dev/null 2>&1; then
  zout=$(zsh -c ". $HOME/.claude-profiles.sh; claude --version" 2>&1); zrc=$?
  check "zsh: bare claude blocked" "[ $zrc -ne 0 ] && printf '%s' \"$zout\" | grep -q 'Pick a profile'"
  zout2=$(PATH="$T/bin:$PATH" zsh -c ". $HOME/.claude-profiles.sh; claude-work --resume x")
  check "zsh: claude-work sets CLAUDE_CONFIG_DIR and passes args" "[ \"$zout2\" = 'CFG=$HOME/.claude-work ARGS=--resume x' ]"
  zout3=$(PATH="$T/bin:$PATH" CLAUDE_CONFIG_DIR=/elsewhere zsh -c ". $HOME/.claude-profiles.sh; claude mcp list")
  check "zsh: bare claude passes through when CLAUDE_CONFIG_DIR set" "[ \"$zout3\" = 'CFG=/elsewhere ARGS=mcp list' ]"
else
  echo "SKIP zsh not installed"
fi

# rc file selection follows $SHELL's basename, not the shell tests/e2e.sh runs under.
H4="$T/home_zshrc"
mkdir -p "$H4/.claude"
printf '{"cleanupPeriodDays": 30}\n' > "$H4/.claude/settings.json"
HOME="$H4" SHELL=/bin/zsh bash "$SCRIPT" apply --yes --shell > "$T/apply-zshrc.out" 2>&1; rc=$?
check "SHELL=zsh: apply exits 0" "[ $rc -eq 0 ]"
check "SHELL=zsh: source line landed in .zshrc" "[ -f $H4/.zshrc ] && grep -qF '$H4/.claude-profiles.sh' $H4/.zshrc"
check "SHELL=zsh: .bashrc was not created" "[ ! -e $H4/.bashrc ]"

H5="$T/home_fishrc"
mkdir -p "$H5/.claude"
printf '{"cleanupPeriodDays": 30}\n' > "$H5/.claude/settings.json"
HOME="$H5" SHELL=/usr/bin/fish bash "$SCRIPT" apply --yes --shell > "$T/apply-fish.out" 2>&1; rc=$?
check "SHELL=fish: apply still exits 0" "[ $rc -eq 0 ]"
check "SHELL=fish: no rc file written" "[ ! -e $H5/.bashrc ] && [ ! -e $H5/.zshrc ]"
check "SHELL=fish: output tells user to add the line by hand" "grep -q 'Add this line to your rc file yourself' $T/apply-fish.out"

# -- 7. rollback refuses when --source names one of its own targets ---------
bash "$SCRIPT" rollback --yes --source "$HOME/.claude-shared" > "$T/rollback-badsource.out" 2>&1; rc=$?
check "rollback --source=shared: exits non-zero" "[ $rc -ne 0 ]"
check "rollback --source=shared: shared still exists" "[ -d $HOME/.claude-shared ]"
check "rollback --source=shared: work still exists (guard fires before any rm)" "[ -d $HOME/.claude-work ]"
check "rollback --source=shared: personal still exists (guard fires before any rm)" "[ -d $HOME/.claude-personal ]"

# -- 8. --main/--second name validation --------------------------------------
bash "$SCRIPT" plan --main 'a.b' >/dev/null 2>&1; check "rejects name with a dot" "[ $? -ne 0 ]"
bash "$SCRIPT" plan --main 'w-2' >/dev/null 2>&1; check "accepts name with hyphen and digits" "[ $? -eq 0 ]"

# -- 9. cleanupPeriodDays: differing whitespace must not cause a false mismatch
WORK_SETTINGS="$HOME/.claude-work/settings.json"
PERSONAL_SETTINGS="$HOME/.claude-personal/settings.json"
work_settings_orig=$(cat "$WORK_SETTINGS")
personal_settings_orig=$(cat "$PERSONAL_SETTINGS")
printf '{"cleanupPeriodDays" :  14}\n' > "$WORK_SETTINGS"
printf '{"cleanupPeriodDays":14}\n' > "$PERSONAL_SETTINGS"
bash "$SCRIPT" verify > "$T/verify-cleanup-ws.out" 2>&1; rc=$?
check "cleanupPeriodDays: differing whitespace, same value, no mismatch warning" "[ $rc -eq 0 ] && ! grep -q 'These differ' $T/verify-cleanup-ws.out"
printf '%s\n' "$work_settings_orig" > "$WORK_SETTINGS"
printf '%s\n' "$personal_settings_orig" > "$PERSONAL_SETTINGS"

echo "=== rollback --yes ==="
bash "$SCRIPT" rollback --yes > "$T/rollback.out" 2>&1; rc=$?
check "rollback exits 0" "[ $rc -eq 0 ]"
check "rollback warned about non-empty sessions" "grep -q 'sessions is not empty' $T/rollback.out"
check "profiles + shared + snippet gone" "[ ! -e $HOME/.claude-work ] && [ ! -e $HOME/.claude-personal ] && [ ! -e $HOME/.claude-shared ] && [ ! -e $HOME/.claude-profiles.sh ]"
after2=$(snap)
check "source profile still byte-identical after rollback" "[ '$before' = '$after2' ]"
check "backups untouched" "ls $HOME/.claude-backups/claude-*.tar.gz >/dev/null 2>&1"
check "bashrc has no claude-profiles reference after rollback" "! grep -q 'claude-profiles' $HOME/.bashrc"
check "bashrc still has its original PATH export line" "grep -qF 'export PATH=\$PATH' $HOME/.bashrc"
check "a backup of bashrc exists under .claude-backups" "ls $HOME/.claude-backups/.bashrc.before-rollback-* >/dev/null 2>&1"

echo "=== second rollback (no rc line left) does not fail ==="
bash "$SCRIPT" rollback --yes > "$T/rollback2.out" 2>&1; rc=$?
check "second rollback exits 0" "[ $rc -eq 0 ]"
check "second rollback reports nothing to remove from rc" "grep -qi 'no claude-profiles lines found' $T/rollback2.out"

echo "=== adopt: pre-existing second profile ==="
# The real-world case: the user tried CLAUDE_CONFIG_DIR by hand before finding
# this script, so ~/.claude-personal is already a complete, logged-in profile
# whose projects/ tree is part hand-copy of ~/.claude/projects and part
# sessions that exist nowhere else. The rollback above left a clean slate, so
# build that state here.
P="$HOME/.claude-personal"
mkdir -p "$P/projects/-fake-proj" "$P/projects/-other-proj" "$P/file-history/uniq-sess" "$P/skills/y"
printf '{"claudeAiOauth":{"accessToken":"FAKE-WORK"}}\n' > "$P/.credentials.json"
chmod 600 "$P/.credentials.json"
printf '{"hasCompletedOnboarding":true,"oauthAccount":{"emailAddress":"second@b"}}\n' > "$P/.claude.json"
# Same relative path as the source's session but different content: the shared
# copy (seeded from ~/.claude) must win, this one must not overwrite it.
printf '{"type":"user","msg":"PROFILE-COPY"}\n' > "$P/projects/-fake-proj/s1.jsonl"
# Exists nowhere else.
printf '{"type":"user","msg":"only-in-personal"}\n' > "$P/projects/-other-proj/u1.jsonl"
printf '{"checkpoint":"only-in-personal"}\n' > "$P/file-history/uniq-sess/1.json"
printf 'name: y\n' > "$P/skills/y/SKILL.md"
# Two copies of the line the source has (both must dedupe away against the
# shared copy), two unique timestamped lines written out of order, and one
# unique line with no timestamp at all.
{ printf '{"display":"prompt one"}\n'
  printf '{"display":"prompt one"}\n'
  printf '{"display":"p-two","timestamp":200}\n'
  printf '{"display":"p-one","timestamp":100}\n'
  printf '{"display":"p-no-timestamp"}\n'; } > "$P/history.jsonl"
cp "$P/.credentials.json" "$T/p-creds.before"
cp "$P/.claude.json" "$T/p-state.before"
n_tars=$(ls "$HOME/.claude-backups"/*.tar.gz 2>/dev/null | wc -l)
hist_sorted() {
  awk '{ ts = 0
         if (match($0, /"timestamp" *: *[0-9]+/)) {
           s = substr($0, RSTART, RLENGTH); sub(/^[^0-9]*/, "", s); ts = s + 0 }
         if (ts < prev) exit 1
         prev = ts }' "$1"
}
all_share_linked() {
  for p in projects history.jsonl file-history plans tasks paste-cache \
           image-cache uploads session-env agent-memory skills commands \
           agents workflows rules output-styles plugins; do
    [ -L "$1/$p" ] || return 1
  done
  return 0
}

bash "$SCRIPT" apply --yes --shell > "$T/adopt-refuse.out" 2>&1; rc=$?
check "apply without --adopt refuses" "[ $rc -ne 0 ] && grep -q -- '--adopt' $T/adopt-refuse.out && grep -q 'already holds real data' $T/adopt-refuse.out"
check "refusal lists the paths concerned" "grep -q 'projects' $T/adopt-refuse.out && grep -q 'history.jsonl' $T/adopt-refuse.out && grep -q 'file-history' $T/adopt-refuse.out"
check "refused apply created nothing" "[ ! -e $HOME/.claude-shared ] && [ ! -e $HOME/.claude-work ]"
check "refused apply took no backup" "[ \$(ls $HOME/.claude-backups/*.tar.gz | wc -l) -eq $n_tars ]"

bash "$SCRIPT" plan > "$T/adopt-plan.out" 2>&1; rc=$?
check "plan without --adopt exits 0" "[ $rc -eq 0 ]"
check "plan without --adopt warns and still shows the whole plan" "grep -q 'already holds real data' $T/adopt-plan.out && grep -q -- '--adopt' $T/adopt-plan.out && grep -q 'Plan complete' $T/adopt-plan.out"
check "plan with existing data creates nothing" "[ ! -e $HOME/.claude-shared ] && [ ! -e $HOME/.claude-work ]"

bash "$SCRIPT" plan --adopt > "$T/adopt-plan2.out" 2>&1; rc=$?
check "plan --adopt exits 0 and previews the merge counts" "[ $rc -eq 0 ] && grep -q 'merge  projects/' $T/adopt-plan2.out && grep -q 'unique line' $T/adopt-plan2.out"
check "plan --adopt changed nothing in the profile" "[ ! -L $P/projects ] && [ -f $P/projects/-other-proj/u1.jsonl ] && [ -z \"\$(ls -d $P/.adopted-* 2>/dev/null)\" ] && [ ! -e $HOME/.claude-shared ]"

bash "$SCRIPT" apply --adopt --yes --shell > "$T/adopt-apply.out" 2>&1; rc=$?
check "apply --adopt exits 0" "[ $rc -eq 0 ]"
after_adopt=$(snap)
check "source profile byte-identical after adopt" "[ '$before' = '$after_adopt' ]"
ADOPT_TAR=$(ls "$HOME/.claude-backups"/claude-personal-adopted-*.tar.gz 2>/dev/null | head -1)
check "adopt archive exists, mode 600" "[ -n '$ADOPT_TAR' ] && [ \$(fmode '$ADOPT_TAR') = 600 ]"
check "adopt archive lists the unique session" "tar tzf '$ADOPT_TAR' | grep -q 'projects/-other-proj/u1.jsonl'"
check "unique session merged into shared" "[ -f $HOME/.claude-shared/projects/-other-proj/u1.jsonl ] && grep -q only-in-personal $HOME/.claude-shared/projects/-other-proj/u1.jsonl"
check "unique file-history entry merged into shared" "[ -f $HOME/.claude-shared/file-history/uniq-sess/1.json ]"
check "unique skill merged into shared" "[ -f $HOME/.claude-shared/skills/y/SKILL.md ]"
check "overlapping session NOT overwritten (shared copy won)" "grep -q 'hi' $HOME/.claude-shared/projects/-fake-proj/s1.jsonl && ! grep -q PROFILE-COPY $HOME/.claude-shared/projects/-fake-proj/s1.jsonl"
check "merge reported copied and skipped separately" "grep -q 'merge  projects/: 1 copied in, 1 skipped' $T/adopt-apply.out"
check "shared history.jsonl has exactly the 4 unique lines" "[ \$(wc -l < $HOME/.claude-shared/history.jsonl | tr -d ' ') -eq 4 ]"
check "shared history timestamps are non-decreasing" "hist_sorted $HOME/.claude-shared/history.jsonl"
check "history keeps the untimestamped lines first, shared one leading" "[ \"\$(sed -n 1p $HOME/.claude-shared/history.jsonl)\" = '{\"display\":\"prompt one\"}' ] && [ \"\$(sed -n 2p $HOME/.claude-shared/history.jsonl)\" = '{\"display\":\"p-no-timestamp\"}' ]"
check "history sorted the profile's out-of-order timestamps" "[ \"\$(sed -n 3p $HOME/.claude-shared/history.jsonl)\" = '{\"display\":\"p-one\",\"timestamp\":100}' ] && [ \"\$(sed -n 4p $HOME/.claude-shared/history.jsonl)\" = '{\"display\":\"p-two\",\"timestamp\":200}' ]"
check "every shared path in the adopted profile is now a symlink" "all_share_linked $P"
check "adopted profile keeps its own real credentials, untouched" "[ -f $P/.credentials.json ] && [ ! -L $P/.credentials.json ] && cmp -s $P/.credentials.json $T/p-creds.before"
check "adopted profile keeps its own real .claude.json, untouched" "[ -f $P/.claude.json ] && [ ! -L $P/.claude.json ] && cmp -s $P/.claude.json $T/p-state.before"
check ".adopted-* dir holds the old projects tree and history" "ls -d $P/.adopted-*/projects/-other-proj/u1.jsonl >/dev/null 2>&1 && ls -d $P/.adopted-*/history.jsonl >/dev/null 2>&1"
check "conf records the adopted profile" "grep -q '^ADOPTED=personal$' $HOME/.claude-shared/.claude-profiles.conf"

bash "$SCRIPT" verify > "$T/adopt-verify.out" 2>&1; rc=$?
check "verify after adopt exits 0" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/adopt-verify.out"
check "verify lists the .adopted dir without calling it a problem" "grep -q '.adopted-' $T/adopt-verify.out && grep -q 'Delete it when you are happy' $T/adopt-verify.out"
check "verify shows both accounts" "grep -q 'work: me@example.com' $T/adopt-verify.out && grep -q 'personal: work@example.com' $T/adopt-verify.out"

bash "$SCRIPT" apply --adopt --yes --shell > "$T/adopt-apply2.out" 2>&1; rc=$?
check "second apply --adopt is a no-op, exits 0" "[ $rc -eq 0 ]"
check "second apply --adopt takes no second adopt archive" "[ \$(ls $HOME/.claude-backups/claude-personal-adopted-*.tar.gz | wc -l) -eq 1 ]"
check "second apply --adopt leaves the merged history alone" "[ \$(wc -l < $HOME/.claude-shared/history.jsonl | tr -d ' ') -eq 4 ]"
check "second apply --adopt keeps the ADOPTED record" "grep -q '^ADOPTED=personal$' $HOME/.claude-shared/.claude-profiles.conf"

bash "$SCRIPT" rollback --yes > "$T/adopt-rollback.out" 2>&1; rc=$?
check "rollback after adopt exits 0" "[ $rc -eq 0 ]"
check "rollback after adopt removed both profiles and the shared dir" "[ ! -e $HOME/.claude-work ] && [ ! -e $P ] && [ ! -e $HOME/.claude-shared ]"
check "the adopt archive survives rollback" "[ -f '$ADOPT_TAR' ]"

echo "=== three profiles ==="
# Everything above uses the default pair, so two could still be special by
# accident. This section builds a three-profile setup in a fake HOME of its
# own and checks each place that used to name MAIN and SECOND: the profile
# directories, who inherits the login, the links, the snippet, the conf file,
# the Accounts pairing and rollback.
H6="$T/home_three"
mkdir -p "$H6/.claude/projects/-three-proj" "$H6/.claude/skills/x" "$H6/.claude/plans"
printf '{"type":"user","msg":"three"}\n' > "$H6/.claude/projects/-three-proj/s1.jsonl"
printf '{"display":"prompt three"}\n' > "$H6/.claude/history.jsonl"
printf '{"cleanupPeriodDays": 3650}\n' > "$H6/.claude/settings.json"
printf 'name: x\n' > "$H6/.claude/skills/x/SKILL.md"
printf '{"claudeAiOauth":{"accessToken":"ACCT-first"}}\n' > "$H6/.claude/.credentials.json"
chmod 600 "$H6/.claude/.credentials.json"
printf '{"hasCompletedOnboarding":true}\n' > "$H6/.claude.json"

HOME="$H6" bash "$SCRIPT" apply --yes --shell --profiles home,acme,globex > "$T/three-apply.out" 2>&1; rc=$?
check "three: apply exits 0" "[ $rc -eq 0 ]"
check "three: all three profile dirs exist" "[ -d $H6/.claude-home ] && [ -d $H6/.claude-acme ] && [ -d $H6/.claude-globex ]"
check "three: only the first profile inherits the credentials" "[ -f $H6/.claude-home/.credentials.json ] && [ ! -e $H6/.claude-acme/.credentials.json ] && [ ! -e $H6/.claude-globex/.credentials.json ]"
check "three: only the first profile inherits .claude.json" "[ -f $H6/.claude-home/.claude.json ] && [ ! -e $H6/.claude-acme/.claude.json ] && [ ! -e $H6/.claude-globex/.claude.json ]"
check "three: every profile has all 17 shared links" "all_share_linked $H6/.claude-home && all_share_linked $H6/.claude-acme && all_share_linked $H6/.claude-globex"
check "three: a later profile's link points at the one shared copy" "[ \"\$(readlink $H6/.claude-globex/projects)\" = $H6/.claude-shared/projects ]"
check "three: snippet defines one launcher per profile" "grep -q '^claude-home()' $H6/.claude-profiles.sh && grep -q '^claude-acme()' $H6/.claude-profiles.sh && grep -q '^claude-globex()' $H6/.claude-profiles.sh"
check "three: guard lists all three launchers" "grep -qF 'Pick a profile: claude-home, claude-acme or claude-globex' $H6/.claude-profiles.sh"
check "three: header comment names each profile" "grep -qF 'Launchers defined here: claude-home, claude-acme and claude-globex' $H6/.claude-profiles.sh"
out=$(bash -c ". $H6/.claude-profiles.sh; claude-globex mcp list")
check "three: the third launcher points at its own config dir" "[ \"$out\" = 'CFG=$H6/.claude-globex ARGS=mcp list' ]"
CONF6="$H6/.claude-shared/.claude-profiles.conf"
check "three: conf records the list comma-separated" "grep -q '^PROFILES=home,acme,globex\$' $CONF6"
check "three: conf no longer carries MAIN=/SECOND=" "! grep -q '^MAIN=' $CONF6 && ! grep -q '^SECOND=' $CONF6"

# Accounts: give the two fresh profiles logins of their own. Each needs a
# .claude.json too, or profile_launched() skips it (and rightly so).
printf '{"claudeAiOauth":{"accessToken":"ACCT-acme"}}\n' > "$H6/.claude-acme/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"ACCT-globex"}}\n' > "$H6/.claude-globex/.credentials.json"
chmod 600 "$H6/.claude-acme/.credentials.json" "$H6/.claude-globex/.credentials.json"
printf '{}' > "$H6/.claude-acme/.claude.json"
printf '{}' > "$H6/.claude-globex/.claude.json"
HOME="$H6" bash "$SCRIPT" verify > "$T/three-verify.out" 2>&1; rc=$?
check "three: verify with three distinct accounts exits 0" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/three-verify.out"
check "three: verify reports every profile's account" "grep -q 'home: first@example.com' $T/three-verify.out && grep -q 'acme: acme@example.com' $T/three-verify.out && grep -q 'globex: globex@example.com' $T/three-verify.out"
check "three: verify reports retention for every profile" "grep -q 'home: cleanupPeriodDays=3650' $T/three-verify.out && grep -q 'globex: cleanupPeriodDays=3650' $T/three-verify.out"

# Any PAIR sharing an account is a problem, not just the first two.
cp "$H6/.claude-acme/.credentials.json" "$H6/.claude-globex/.credentials.json"
HOME="$H6" bash "$SCRIPT" verify > "$T/three-verify-dup.out" 2>&1; rc=$?
check "three: a same-account pair among three profiles is flagged" "[ $rc -ne 0 ] && grep -qi 'same account' $T/three-verify-dup.out"
check "three: the warning names the pair, not the first two" "grep -q 'acme and globex are both logged in' $T/three-verify-dup.out"
printf '{"claudeAiOauth":{"accessToken":"ACCT-globex"}}\n' > "$H6/.claude-globex/.credentials.json"
chmod 600 "$H6/.claude-globex/.credentials.json"

# Retention has to agree across ALL of them, not just a pair.
printf '{"cleanupPeriodDays": 7}\n' > "$H6/.claude-globex/settings.json"
HOME="$H6" bash "$SCRIPT" verify > "$T/three-verify-ret.out" 2>&1; rc=$?
check "three: one odd cleanupPeriodDays out of three is flagged and named" "[ $rc -ne 0 ] && grep -q 'These differ: globex' $T/three-verify-ret.out"
printf '{"cleanupPeriodDays": 3650}\n' > "$H6/.claude-globex/settings.json"

# The deprecated aliases, against a conf that holds three names.
HOME="$H6" bash "$SCRIPT" plan --main a --second b > "$T/three-dep.out" 2>&1; rc=$?
check "deprecated --main/--second still work" "[ $rc -eq 0 ] && grep -qi 'deprecated' $T/three-dep.out"
check "deprecated --main X --second Y means exactly --profiles X,Y" "grep -qF 'a (inherits current login), b' $T/three-dep.out && ! grep -q 'claude-globex' $T/three-dep.out"
HOME="$H6" bash "$SCRIPT" plan --main solo > "$T/three-main-only.out" 2>&1; rc=$?
check "deprecated --main alone replaces only the first position" "[ $rc -eq 0 ] && grep -qF 'solo (inherits current login), acme, globex' $T/three-main-only.out"

HOME="$H6" bash "$SCRIPT" plan --profiles onlyone >/dev/null 2>&1; check "rejects a one-name --profiles" "[ $? -ne 0 ]"
HOME="$H6" bash "$SCRIPT" plan --profiles a,a >/dev/null 2>&1; check "rejects duplicate names in --profiles" "[ $? -ne 0 ]"
HOME="$H6" bash "$SCRIPT" plan --profiles 'a,bad name' >/dev/null 2>&1; check "rejects a --profiles name with a space" "[ $? -ne 0 ]"
HOME="$H6" bash "$SCRIPT" plan --profiles a,b --main c >/dev/null 2>&1; check "rejects --profiles combined with --main" "[ $? -ne 0 ]"
HOME="$H6" bash "$SCRIPT" plan --source "$H6/.claude-globex" >/dev/null 2>&1; check "rejects a source that is the LAST profile's own dir" "[ $? -ne 0 ]"

HOME="$H6" bash "$SCRIPT" rollback --yes > "$T/three-rollback.out" 2>&1; rc=$?
check "three: rollback exits 0" "[ $rc -eq 0 ]"
check "three: rollback lists every profile dir" "grep -qF '$H6/.claude-acme' $T/three-rollback.out"
check "three: rollback removed all three profiles and the shared dir" "[ ! -e $H6/.claude-home ] && [ ! -e $H6/.claude-acme ] && [ ! -e $H6/.claude-globex ] && [ ! -e $H6/.claude-shared ]"

# A conf file written by an older version: MAIN=/SECOND= must still drive the
# run, which is what keeps an existing setup working with no flags.
H7="$T/home_oldconf"
mkdir -p "$H7/.claude" "$H7/.claude-shared"
printf '{"cleanupPeriodDays": 30}\n' > "$H7/.claude/settings.json"
{ printf 'VERSION=1.2.0\nMAIN=x\nSECOND=y\nSHARE_MODE=full\n'
  printf 'SOURCE=%s\n' "$H7/.claude"; } > "$H7/.claude-shared/.claude-profiles.conf"
HOME="$H7" bash "$SCRIPT" verify > "$T/oldconf-verify.out" 2>&1
check "old conf: MAIN=/SECOND= is read as the profile list" "grep -qF 'x (inherits current login), y' $T/oldconf-verify.out && grep -q 'profiles=x,y' $T/oldconf-verify.out"

# No flags, no conf, no terminal: the question must never be asked, and the
# default pair is used silently. Skipped when the suite itself is run from a
# terminal, because the child could then open /dev/tty and legitimately ask.
H8="$T/home_notty"
mkdir -p "$H8/.claude"
printf '{"cleanupPeriodDays": 30}\n' > "$H8/.claude/settings.json"
if ( exec </dev/tty ) 2>/dev/null; then
  echo "SKIP no-tty prompt check (this run has a controlling terminal)"
else
  HOME="$H8" bash "$SCRIPT" plan </dev/null > "$T/notty-plan.out" 2>&1; rc=$?
  check "no flags, no conf, no tty: plan does not ask and takes work,personal" "[ $rc -eq 0 ] && grep -qF 'work (inherits current login), personal' $T/notty-plan.out && ! grep -qi 'Easy setup' $T/notty-plan.out"
  check "no flags, no conf, no tty: plan still created nothing" "[ ! -e $H8/.claude-shared ] && [ ! -e $H8/.claude-work ]"
fi
HOME="$H8" bash "$SCRIPT" plan --yes > "$T/notty-plan-yes.out" 2>&1; rc=$?
check "--yes never asks, whatever the terminal, and takes work,personal" "[ $rc -eq 0 ] && grep -qF 'work (inherits current login), personal' $T/notty-plan-yes.out && ! grep -qi 'Easy setup' $T/notty-plan-yes.out"

echo "=== add, remove, settings ==="
# Three things this section is about, in one fake HOME of its own so that the
# sections after it keep working against the main fixture:
#   --settings NAME=PATH   seeding one profile's settings.json from a file
#   add NAME[,NAME...]     extending a setup that already exists
#   remove NAME            archiving one profile away again
H9="$T/home_addremove"
mkdir -p "$H9/.claude/projects/-ar-proj" "$H9/.claude/skills/x" "$H9/.claude/plans"
printf '{"type":"user","msg":"ar"}\n' > "$H9/.claude/projects/-ar-proj/s1.jsonl"
printf '{"display":"prompt ar"}\n' > "$H9/.claude/history.jsonl"
printf '{"cleanupPeriodDays": 3650}\n' > "$H9/.claude/settings.json"
printf '# ar claude md\n' > "$H9/.claude/CLAUDE.md"
printf 'name: x\n' > "$H9/.claude/skills/x/SKILL.md"
printf '{"claudeAiOauth":{"accessToken":"ACCT-first"}}\n' > "$H9/.claude/.credentials.json"
chmod 600 "$H9/.claude/.credentials.json"
printf '{"hasCompletedOnboarding":true}\n' > "$H9/.claude.json"
# The seed file, and the two shapes that must be refused. cleanupPeriodDays
# matches the source's, or verify would (rightly) flag the mismatch later.
SEED="$T/acme-settings.json"
printf '{"cleanupPeriodDays": 3650, "model": "opus"}\n' > "$SEED"
printf 'cleanupPeriodDays = 3650\n' > "$T/not-json.txt"
mkdir -p "$T/has space"
printf '{"cleanupPeriodDays": 3650}\n' > "$T/has space/s.json"

HOME="$H9" bash "$SCRIPT" apply --yes --shell --profiles home,acme --settings "nosuch=$SEED" > "$T/ar-badname.out" 2>&1; rc=$?
check "settings: a name outside this run's profile list is rejected" "[ $rc -ne 0 ] && grep -q nosuch $T/ar-badname.out"
check "settings: the rejected run created nothing" "[ ! -e $H9/.claude-shared ] && [ ! -e $H9/.claude-home ] && [ ! -e $H9/.claude-backups ]"
HOME="$H9" bash "$SCRIPT" apply --yes --shell --profiles home,acme --settings "acme=$T/not-json.txt" > "$T/ar-badjson.out" 2>&1; rc=$?
check "settings: a file that is not crudely JSON is rejected" "[ $rc -ne 0 ] && grep -qi 'does not look like JSON' $T/ar-badjson.out"
HOME="$H9" bash "$SCRIPT" apply --yes --shell --profiles home,acme --settings "acme=$T/has space/s.json" > "$T/ar-space.out" 2>&1; rc=$?
check "settings: a path containing a space is rejected" "[ $rc -ne 0 ] && grep -qi whitespace $T/ar-space.out"
HOME="$H9" bash "$SCRIPT" apply --yes --shell --profiles home,acme --settings "acme=$T/no-such-file.json" > "$T/ar-nofile.out" 2>&1; rc=$?
check "settings: a path that is not a regular file is rejected" "[ $rc -ne 0 ] && grep -q 'not a regular file' $T/ar-nofile.out"
HOME="$H9" bash "$SCRIPT" verify --settings "acme=$SEED" > "$T/ar-verify-settings.out" 2>&1; rc=$?
check "settings: verify does not accept --settings" "[ $rc -ne 0 ] && grep -q 'only accepted by plan, apply and add' $T/ar-verify-settings.out"

HOME="$H9" bash "$SCRIPT" plan --profiles home,acme --settings "acme=$SEED" > "$T/ar-plan.out" 2>&1; rc=$?
check "settings: plan exits 0 and names the seed file" "[ $rc -eq 0 ] && grep -qF 'copy   settings.json <- $SEED (--settings)' $T/ar-plan.out"
check "settings: plan created nothing" "[ ! -e $H9/.claude-shared ] && [ ! -e $H9/.claude-acme ]"

HOME="$H9" bash "$SCRIPT" apply --yes --shell --profiles home,acme --settings "acme=$SEED" > "$T/ar-apply.out" 2>&1; rc=$?
check "settings: apply exits 0" "[ $rc -eq 0 ]"
check "settings: acme's settings.json is the --settings file" "grep -q opus $H9/.claude-acme/settings.json"
check "settings: home's settings.json came from the source, not the seed" "! grep -q opus $H9/.claude-home/settings.json && grep -q 3650 $H9/.claude-home/settings.json"
check "settings: nothing about the seed is recorded in the conf" "! grep -q -- '--settings' $H9/.claude-shared/.claude-profiles.conf && ! grep -qF '$SEED' $H9/.claude-shared/.claude-profiles.conf"
printf '{"cleanupPeriodDays": 3650, "model": "sonnet"}\n' > "$T/acme-settings2.json"
HOME="$H9" bash "$SCRIPT" apply --yes --shell --no-backup --settings "acme=$T/acme-settings2.json" > "$T/ar-apply2.out" 2>&1; rc=$?
check "settings: a re-apply keeps the existing settings.json and says it ignored the flag" "[ $rc -eq 0 ] && grep -q 'ignored' $T/ar-apply2.out && grep -q opus $H9/.claude-acme/settings.json"

HOME="$H9" bash "$SCRIPT" add globex --yes > "$T/ar-add.out" 2>&1; rc=$?
check "add: exits 0" "[ $rc -eq 0 ]"
check "add: the directory exists with the copied config" "[ -d $H9/.claude-globex ] && [ -f $H9/.claude-globex/settings.json ] && [ -f $H9/.claude-globex/CLAUDE.md ]"
check "add: every shared path in the new profile is a symlink" "all_share_linked $H9/.claude-globex"
check "add: the links point at the one shared copy" "[ \"\$(readlink $H9/.claude-globex/projects)\" = $H9/.claude-shared/projects ]"
check "add: no credentials and no app state were copied" "[ ! -e $H9/.claude-globex/.credentials.json ] && [ ! -e $H9/.claude-globex/.claude.json ]"
check "add: conf records the extended list" "grep -q '^PROFILES=home,acme,globex\$' $H9/.claude-shared/.claude-profiles.conf"
check "add: conf keeps the other recorded lines" "grep -q '^SHARE_MODE=full\$' $H9/.claude-shared/.claude-profiles.conf && grep -qF 'SOURCE=$H9/.claude' $H9/.claude-shared/.claude-profiles.conf"
check "add: snippet defines the new launcher beside the old ones" "grep -q '^claude-globex()' $H9/.claude-profiles.sh && grep -q '^claude-home()' $H9/.claude-profiles.sh"
check "add: bashrc still sources the snippet exactly once" "[ \$(grep -c 'claude-profiles.sh' $H9/.bashrc) -eq 1 ]"
check "add: prints the new launcher and the login instruction" "grep -q 'claude-globex' $T/ar-add.out && grep -qi 'log in with its own account' $T/ar-add.out"
out=$(bash -c ". $H9/.claude-profiles.sh; claude-globex mcp list")
check "add: the new launcher points at its own config dir" "[ \"$out\" = 'CFG=$H9/.claude-globex ARGS=mcp list' ]"

# verify has to pass with the added profile in the list. Both fresh profiles
# need a login of their own and a .claude.json, exactly as the three-profile
# section arranges it.
printf '{"claudeAiOauth":{"accessToken":"ACCT-acme"}}\n' > "$H9/.claude-acme/.credentials.json"
printf '{"claudeAiOauth":{"accessToken":"ACCT-globex"}}\n' > "$H9/.claude-globex/.credentials.json"
chmod 600 "$H9/.claude-acme/.credentials.json" "$H9/.claude-globex/.credentials.json"
printf '{}' > "$H9/.claude-acme/.claude.json"
printf '{}' > "$H9/.claude-globex/.claude.json"
HOME="$H9" bash "$SCRIPT" verify > "$T/ar-verify.out" 2>&1; rc=$?
check "add: verify exits 0 with the added profile" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/ar-verify.out"
check "add: verify checks the added profile's account and snippet" "grep -q 'globex: globex@example.com' $T/ar-verify.out && ! grep -q 'does not define' $T/ar-verify.out"

HOME="$H9" bash "$SCRIPT" add acme --yes > "$T/ar-add-dup.out" 2>&1; rc=$?
check "add: a name already in the list is rejected" "[ $rc -ne 0 ] && grep -q 'already one of the profiles' $T/ar-add-dup.out"
mkdir -p "$H9/.claude-priorx/projects/-p"
printf '{"type":"user","msg":"prior"}\n' > "$H9/.claude-priorx/projects/-p/s.jsonl"
HOME="$H9" bash "$SCRIPT" add priorx --yes > "$T/ar-add-real.out" 2>&1; rc=$?
check "add: a directory holding real data is rejected and points at --adopt" "[ $rc -ne 0 ] && grep -q 'already holds real data' $T/ar-add-real.out && grep -q -- '--adopt' $T/ar-add-real.out"
check "add: the rejected name never reached the conf" "! grep -q priorx $H9/.claude-shared/.claude-profiles.conf"
check "add: the pre-existing directory was left exactly as it was" "[ -f $H9/.claude-priorx/projects/-p/s.jsonl ] && [ ! -L $H9/.claude-priorx/projects ]"
HOME="$H9" bash "$SCRIPT" add 'bad name' --yes >/dev/null 2>&1; check "add: rejects a name with a space" "[ $? -ne 0 ]"
HOME="$H9" bash "$SCRIPT" add >/dev/null 2>&1; check "add: rejects a missing name" "[ $? -ne 0 ]"
HOME="$H8" bash "$SCRIPT" add extra --yes > "$T/ar-add-noconf.out" 2>&1; rc=$?
check "add: refuses when there is no conf file" "[ $rc -ne 0 ] && grep -qi 'run .apply. first' $T/ar-add-noconf.out"
HOME="$H8" bash "$SCRIPT" remove extra --yes >/dev/null 2>&1; check "remove: refuses when there is no conf file" "[ $? -ne 0 ]"

# add with the source gone is the after-finalize case: the first profile is
# the template. Moving ~/.claude aside is enough to reach that branch.
mv "$H9/.claude" "$H9/.claude.away"
HOME="$H9" bash "$SCRIPT" add late --yes > "$T/ar-add-nosource.out" 2>&1; rc=$?
check "add: works with the source gone, and says where the config came from" "[ $rc -eq 0 ] && grep -qF 'come from the first profile instead: $H9/.claude-home' $T/ar-add-nosource.out"
check "add: the seeded config is the first profile's, not the seed file's" "[ -f $H9/.claude-late/settings.json ] && ! grep -q opus $H9/.claude-late/settings.json && [ -f $H9/.claude-late/CLAUDE.md ]"
HOME="$H9" bash "$SCRIPT" remove late --yes > "$T/ar-rm-late.out" 2>&1; rc=$?
check "remove: the just-added profile goes again" "[ $rc -eq 0 ] && [ ! -e $H9/.claude-late ] && grep -q '^PROFILES=home,acme,globex\$' $H9/.claude-shared/.claude-profiles.conf"
mv "$H9/.claude.away" "$H9/.claude"

shared_files_before=$(find "$H9/.claude-shared/projects" -type f | wc -l | tr -d ' ')
HOME="$H9" bash "$SCRIPT" remove globex --yes > "$T/ar-rm.out" 2>&1; rc=$?
check "remove: exits 0" "[ $rc -eq 0 ]"
check "remove: the profile directory is gone" "[ ! -e $H9/.claude-globex ]"
RM_TAR=$(ls "$H9/.claude-backups"/claude-globex-removed-*.tar.gz 2>/dev/null | head -1)
check "remove: the archive exists, mode 600" "[ -n '$RM_TAR' ] && [ \$(fmode '$RM_TAR') = 600 ]"
check "remove: the archive lists the profile's settings.json" "tar tzf '$RM_TAR' | grep -q '^\.claude-globex/settings.json\$'"
check "remove: the archive path is printed" "grep -qF '$RM_TAR' $T/ar-rm.out"
check "remove: conf drops the name" "grep -q '^PROFILES=home,acme\$' $H9/.claude-shared/.claude-profiles.conf"
check "remove: snippet no longer defines that launcher" "! grep -q '^claude-globex()' $H9/.claude-profiles.sh && grep -q '^claude-acme()' $H9/.claude-profiles.sh"
check "remove: says the shared data is untouched, and it is" "grep -q 'NOT touched' $T/ar-rm.out && [ \$(find $H9/.claude-shared/projects -type f | wc -l | tr -d ' ') -eq $shared_files_before ] && [ -d $H9/.claude-shared ]"
HOME="$H9" bash "$SCRIPT" verify > "$T/ar-verify2.out" 2>&1; rc=$?
check "remove: verify is clean afterwards" "[ $rc -eq 0 ] && grep -q 'no problems found' $T/ar-verify2.out"

mkdir -p "$H9/.claude-acme/sessions"; printf '{}' > "$H9/.claude-acme/sessions/live.json"
HOME="$H9" bash "$SCRIPT" remove acme --yes > "$T/ar-rm-sessions.out" 2>&1; rc=$?
check "remove: refuses while the profile's sessions dir is not empty" "[ $rc -ne 0 ] && grep -q 'sessions is not empty' $T/ar-rm-sessions.out && [ -d $H9/.claude-acme ]"
rm -f "$H9/.claude-acme/sessions/live.json"
HOME="$H9" bash "$SCRIPT" remove nosuch --yes > "$T/ar-rm-nosuch.out" 2>&1; rc=$?
check "remove: refuses a name that is not in the list" "[ $rc -ne 0 ] && grep -q 'not one of the profiles' $T/ar-rm-nosuch.out"

# No --yes and no terminal: fails closed, exactly like apply. Skipped when the
# suite itself has a controlling terminal, because the child could then open
# /dev/tty and legitimately wait for an answer.
if ( exec </dev/tty ) 2>/dev/null; then
  echo "SKIP remove-without-yes check (this run has a controlling terminal)"
else
  HOME="$H9" bash "$SCRIPT" remove home </dev/null > "$T/ar-rm-notty.out" 2>&1; rc=$?
  check "remove without --yes and no tty exits non-zero" "[ $rc -ne 0 ] && grep -q -- '--yes' $T/ar-rm-notty.out"
  check "remove without --yes changed nothing" "[ -d $H9/.claude-home ] && grep -q '^PROFILES=home,acme\$' $H9/.claude-shared/.claude-profiles.conf && grep -q '^claude-home()' $H9/.claude-profiles.sh"
  check "remove: the question for the first profile says it is the inheriting one" "grep -q 'FIRST (inheriting) profile' $T/ar-rm-notty.out"
fi

HOME="$H9" bash "$SCRIPT" remove acme --yes > "$T/ar-rm-last1.out" 2>&1; rc=$?
check "remove: going from two profiles to one is allowed" "[ $rc -eq 0 ] && [ ! -e $H9/.claude-acme ] && grep -q '^PROFILES=home\$' $H9/.claude-shared/.claude-profiles.conf"
HOME="$H9" bash "$SCRIPT" remove home --yes > "$T/ar-rm-last2.out" 2>&1; rc=$?
check "remove: refuses to remove the only profile left" "[ $rc -ne 0 ] && grep -q 'only profile left' $T/ar-rm-last2.out && [ -d $H9/.claude-home ]"
HOME="$H9" bash "$SCRIPT" verify > "$T/ar-verify3.out" 2>&1; rc=$?
check "remove: verify still runs against a one-profile setup" "[ $rc -eq 0 ] && grep -q 'profiles=home ' $T/ar-verify3.out"

HOME="$H9" bash "$SCRIPT" rollback --yes > "$T/ar-rollback.out" 2>&1; rc=$?
check "add/remove: rollback cleans the one-profile setup up" "[ $rc -eq 0 ] && [ ! -e $H9/.claude-home ] && [ ! -e $H9/.claude-shared ] && [ ! -e $H9/.claude-profiles.sh ]"
check "add/remove: the remove archives survive rollback" "[ -f '$RM_TAR' ]"

echo "=== safe mode + custom names, verify without flags ==="
bash "$SCRIPT" apply --yes --share safe --main corp --second home > "$T/apply-safe.out" 2>&1; rc=$?
check "safe apply exits 0" "[ $rc -eq 0 ]"
check "safe: projects NOT linked" "[ ! -e $HOME/.claude-corp/projects ] && [ ! -e $HOME/.claude-shared/projects ]"
check "safe: history linked" "[ -L $HOME/.claude-corp/history.jsonl ]"
bash "$SCRIPT" verify > "$T/verify-safe.out" 2>&1; rc=$?
check "verify w/o flags picks up safe+names from conf" "grep -q 'profiles=corp,home share=safe' $T/verify-safe.out && ! grep -q 'projects is missing' $T/verify-safe.out"
# 'home' never inherited a login and has never been launched: the Accounts
# section must skip it rather than run `claude auth status`, which would
# create a .claude.json there as a side effect (see profile_auth() in
# claude-profiles.sh).
check "accounts: skips a not-yet-launched profile" "grep -q 'home: not launched yet, skipping' $T/verify-safe.out"
check "accounts: skip guard creates no .claude.json for it" "[ ! -e $HOME/.claude-home/.claude.json ]"
bash "$SCRIPT" rollback --yes > /dev/null 2>&1
check "rollback w/o flags removed custom-named dirs" "[ ! -e $HOME/.claude-corp ] && [ ! -e $HOME/.claude-home ]"

echo "=== restore from backup (ROLLBACK.md level 3) ==="
mv "$HOME/.claude" "$HOME/.claude.broken"; mv "$HOME/.claude.json" "$HOME/.claude.json.broken"
tar xzf "$(cat "$HOME/.claude-backups/.latest")" -C "$HOME"
after3=$(snap)
check "restored tree matches original (names, modes, sizes, mtimes)" "[ '$before' = '$after3' ]"

echo "=== finalize ==="
# The restore section above put ~/.claude back and rolled the profiles away,
# so build a working setup again before testing the command that deletes the
# source profile.
bash "$SCRIPT" apply --yes --shell > "$T/fin-apply.out" 2>&1; rc=$?
check "finalize: fresh apply exits 0" "[ $rc -eq 0 ]"
# finalize's gate 3 is a full verify, so the setup has to be genuinely clean
# first: both profiles launched, holding different accounts, agreeing on
# retention. Also drop the fixture's $HOME/.claude/hooks/missing.sh hook,
# which apply cannot relocate (no such file) and which would otherwise trip
# gate 4 in every case below; gate 4 is exercised deliberately further down.
mkdir -p "$HOME/.claude-work/sessions" "$HOME/.claude-personal/sessions"
printf '{}' > "$HOME/.claude-personal/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"FAKE-WORK"}}\n' > "$HOME/.claude-personal/.credentials.json"
chmod 600 "$HOME/.claude-personal/.credentials.json"
FIN_SET='{"cleanupPeriodDays": 3650, "statusLine": {"command": "~/.claude-shared/statusline.sh"}}'
printf '%s\n' "$FIN_SET" > "$HOME/.claude-work/settings.json"
printf '%s\n' "$FIN_SET" > "$HOME/.claude-personal/settings.json"
bash "$SCRIPT" verify > "$T/fin-verify0.out" 2>&1; rc=$?
check "finalize: baseline verify is clean" "[ $rc -eq 0 ]"
n_arch_fin=$(ls "$HOME/.claude-backups"/*.tar.gz | wc -l)

# Gate 8: the confirmation is last, so a run without --yes passes every gate
# and then stops. That is the dry run for this command.
bash "$SCRIPT" finalize > "$T/fin-notty.out" 2>&1 </dev/null; rc=$?
check "finalize without --yes and no tty aborts" "[ $rc -ne 0 ] && grep -q -- '--yes' $T/fin-notty.out"
check "finalize without --yes deleted nothing" "[ -d $HOME/.claude ] && [ -f $HOME/.claude.json ]"
check "finalize without --yes still printed every gate it passed" "grep -q 'gate 7' $T/fin-notty.out && grep -q 'Gate 8' $T/fin-notty.out"

# Gate 5: a file in the source's sessions/ means a session may be live there.
printf '{}' > "$HOME/.claude/sessions/live.json"
bash "$SCRIPT" finalize --yes > "$T/fin-sessions.out" 2>&1; rc=$?
check "finalize refuses while ~/.claude/sessions has an entry" "[ $rc -ne 0 ] && grep -q 'sessions' $T/fin-sessions.out"
check "finalize says the terminal may itself be a session on the old profile" "grep -q 'may itself be a Claude Code session' $T/fin-sessions.out"
check "finalize: source survives the sessions refusal" "[ -d $HOME/.claude ]"
rm -f "$HOME/.claude/sessions/live.json"

# Gate 4: a settings.json still pointing into the source.
printf '{"cleanupPeriodDays": 3650, "statusLine": {"command": "~/.claude/statusline.sh"}}\n' > "$HOME/.claude-personal/settings.json"
bash "$SCRIPT" finalize --yes > "$T/fin-refs.out" 2>&1; rc=$?
check "finalize refuses while a profile settings.json points into the source" "[ $rc -ne 0 ] && grep -qF '$HOME/.claude-personal/settings.json' $T/fin-refs.out"
check "finalize: source survives the settings refusal" "[ -d $HOME/.claude ]"
printf '%s\n' "$FIN_SET" > "$HOME/.claude-personal/settings.json"

# Gate 3: verify itself must be clean. Break one shared link to prove it.
rm "$HOME/.claude-work/plans"; mkdir "$HOME/.claude-work/plans"
bash "$SCRIPT" finalize --yes > "$T/fin-broken.out" 2>&1; rc=$?
check "finalize refuses when verify reports a problem" "[ $rc -ne 0 ] && grep -q 'verify reports problems' $T/fin-broken.out"
check "finalize: source survives the verify refusal" "[ -d $HOME/.claude ]"
rmdir "$HOME/.claude-work/plans"; ln -s "$HOME/.claude-shared/plans" "$HOME/.claude-work/plans"

# The real thing.
bash "$SCRIPT" finalize --yes > "$T/fin-ok.out" 2>&1; rc=$?
check "finalize --yes exits 0" "[ $rc -eq 0 ]"
check "finalize took a fresh backup of its own" "grep -q 'backup written and read back' $T/fin-ok.out"
check "source profile and ~/.claude.json are gone" "[ ! -e $HOME/.claude ] && [ ! -e $HOME/.claude.json ]"
check "profiles and shared dir are untouched" "[ -d $HOME/.claude-work ] && [ -d $HOME/.claude-personal ] && [ -d $HOME/.claude-shared ]"
check "finalize left a new archive behind" "[ \$(ls $HOME/.claude-backups/*.tar.gz | wc -l) -gt $n_arch_fin ]"
check ".latest names an existing archive holding the deleted tree" "[ -f \"\$(cat $HOME/.claude-backups/.latest)\" ] && tar tzf \"\$(cat $HOME/.claude-backups/.latest)\" | grep -q '^\.claude/settings.json'"
check "conf has exactly one FINALIZED line" "[ \$(grep -c '^FINALIZED=' $HOME/.claude-shared/.claude-profiles.conf) -eq 1 ]"

bash "$SCRIPT" verify > "$T/fin-verify1.out" 2>&1; rc=$?
check "verify after finalize exits 0" "[ $rc -eq 0 ]"
check "verify reports the source as removed by finalize, not missing" "grep -q 'removed by finalize' $T/fin-verify1.out && ! grep -q 'missing: $HOME/.claude\$' $T/fin-verify1.out"
check "verify skips the source-untouched section" "grep -qF 'skipped: $HOME/.claude was removed by finalize' $T/fin-verify1.out"
check "verify still runs the settings-reference section" "grep -q 'Settings that still point at' $T/fin-verify1.out"

bash "$SCRIPT" plan > "$T/fin-plan.out" 2>&1; rc=$?
check "plan after finalize dies with the finalize-specific message" "[ $rc -ne 0 ] && grep -q 'nothing to seed from' $T/fin-plan.out"

bash "$SCRIPT" finalize --yes > "$T/fin-again.out" 2>&1; rc=$?
check "second finalize exits non-zero" "[ $rc -ne 0 ] && grep -qi 'nothing to remove' $T/fin-again.out"
check "second finalize adds no second FINALIZED line" "[ \$(grep -c '^FINALIZED=' $HOME/.claude-shared/.claude-profiles.conf) -eq 1 ]"

echo "=== status and json ==="
# Reuses the state finalize left behind: ~/.claude gone (FINALIZED recorded
# in the conf), work and personal both launched with distinct fake accounts
# (work's copied source creds fall through the stub to me@example.com/
# Personal/max, personal's FAKE-WORK creds give work@example.com/Work Org/
# team), both settings.json agreeing on cleanupPeriodDays. That is exactly
# the clean baseline `verify` needs, so it also works as the clean case for
# `verify --json`.
bash "$SCRIPT" status > "$T/status1.out" 2>&1; rc=$?
check "status exits 0" "[ $rc -eq 0 ]"
check "status lists both profiles by name and launcher" "grep -q 'work (claude-work)' $T/status1.out && grep -q 'personal (claude-personal)' $T/status1.out"
check "status shows 'you are in'" "grep -q 'you are in:' $T/status1.out"

CLAUDE_CONFIG_DIR="$HOME/.claude-personal" bash "$SCRIPT" status > "$T/status-cfg.out" 2>&1; rc=$?
check "status with CLAUDE_CONFIG_DIR set names that profile" "[ $rc -eq 0 ] && grep -q 'you are in: personal' $T/status-cfg.out"

bash "$SCRIPT" status --json > "$T/status.json" 2>"$T/status-json.err"; rc=$?
check "status --json exits 0" "[ $rc -eq 0 ]"
check "status --json is valid JSON" "python3 -m json.tool $T/status.json >/dev/null"
check "status --json prints nothing but the JSON object (no banner, no colour)" "[ \$(wc -l < $T/status.json | tr -d ' ') -eq 1 ] && ! grep -qF \$'\\033[' $T/status.json"
check "status --json .profiles length equals the profile count" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d[\"profiles\"])==2 else 1)' $T/status.json"
check "status --json .profiles[0].first is true" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"profiles\"][0][\"first\"] is True else 1)' $T/status.json"
check "status --json .shared.mode is set" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d[\"shared\"][\"mode\"] else 1)' $T/status.json"

bash "$SCRIPT" verify > "$T/verify-json-clean.txt" 2>&1; trc=$?
bash "$SCRIPT" verify --json > "$T/verify-json-clean.json" 2>"$T/verify-json-clean.err"; jrc=$?
check "verify --json is valid JSON (clean)" "python3 -m json.tool $T/verify-json-clean.json >/dev/null"
check "verify --json .problems is an integer (clean)" "python3 -c 'import json,sys; v=json.load(open(sys.argv[1]))[\"problems\"]; sys.exit(0 if isinstance(v,int) else 1)' $T/verify-json-clean.json"
check "verify --json .sections is a non-empty array (clean)" "python3 -c 'import json,sys; s=json.load(open(sys.argv[1]))[\"sections\"]; sys.exit(0 if isinstance(s,list) and len(s)>0 else 1)' $T/verify-json-clean.json"
check "verify --json exit status matches the text run (clean)" "[ $jrc -eq $trc ]"
check "verify text output still says Result and no problems found (clean)" "grep -q 'Result' $T/verify-json-clean.txt && grep -q 'no problems found' $T/verify-json-clean.txt"

# Break something: a dangling shared link (same technique as the earlier
# "dangling shared link detection" edge case), then compare the JSON and text
# runs against each other on the broken state too.
rm "$HOME/.claude-work/plans"; mkdir "$HOME/.claude-work/plans"
bash "$SCRIPT" verify > "$T/verify-json-broken.txt" 2>&1; trc2=$?
bash "$SCRIPT" verify --json > "$T/verify-json-broken.json" 2>"$T/verify-json-broken.err"; jrc2=$?
check "verify --json .problems > 0 once broken" "[ \$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"problems\"])' $T/verify-json-broken.json) -gt 0 ]"
check "verify --json .ok is false once broken" "python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))[\"ok\"] is False else 1)' $T/verify-json-broken.json"
check "verify --json exit status is non-zero once broken" "[ $jrc2 -ne 0 ]"
check "verify --json exit status matches the text run (broken)" "[ $jrc2 -eq $trc2 ]"
rmdir "$HOME/.claude-work/plans"; ln -s "$HOME/.claude-shared/plans" "$HOME/.claude-work/plans"

H9="$T/home_status_noconf"
mkdir -p "$H9/.claude"
printf '{"cleanupPeriodDays": 30}\n' > "$H9/.claude/settings.json"
HOME="$H9" bash "$SCRIPT" status > "$T/status-noconf.out" 2>&1; rc=$?
check "status with no conf exits non-zero" "[ $rc -ne 0 ]"

echo
echo "passed=$pass failed=$fail   (outputs in $T)"
[ "$fail" -eq 0 ]
