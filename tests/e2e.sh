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

echo "=== safe mode + custom names, verify without flags ==="
bash "$SCRIPT" apply --yes --share safe --main corp --second home > "$T/apply-safe.out" 2>&1; rc=$?
check "safe apply exits 0" "[ $rc -eq 0 ]"
check "safe: projects NOT linked" "[ ! -e $HOME/.claude-corp/projects ] && [ ! -e $HOME/.claude-shared/projects ]"
check "safe: history linked" "[ -L $HOME/.claude-corp/history.jsonl ]"
bash "$SCRIPT" verify > "$T/verify-safe.out" 2>&1; rc=$?
check "verify w/o flags picks up safe+names from conf" "grep -q 'main=corp second=home share=safe' $T/verify-safe.out && ! grep -q 'projects is missing' $T/verify-safe.out"
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

echo
echo "passed=$pass failed=$fail   (outputs in $T)"
[ "$fail" -eq 0 ]
