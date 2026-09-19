# Instructions for Claude Code

Paste the block below into Claude Code on the machine being set up, from the
directory containing this bundle. Everything after the line is addressed to
Claude, not to you.

---

You are setting up two Claude Code profiles on this machine so a work account
and a personal account can run side by side, sharing session history. The
bundle in this directory contains `claude-profiles.sh`, `README.md` and
`ROLLBACK.md`.

Read `README.md` fully before you do anything. It contains the safety model
and the failure modes, and you need both.

## Non-negotiable rules

1. **Never run `/logout`, and never suggest it.** Current Claude Code versions
   can revoke the stored refresh token on logout, which would sign the user
   out of the account they are trying to preserve. The whole design avoids it.
2. **Never write to, delete from, or symlink anything inside `~/.claude`.** It
   is the fallback if this goes wrong. Read-only, always.
3. **Never make `.credentials.json` or `.claude.json` a symlink.** Those two
   files being real and separate per profile is what isolates the accounts.
4. **Do not modify `claude-profiles.sh` to work around a failure.** If it
   refuses to do something, it is refusing on purpose. Report the refusal to
   the user and ask, rather than editing the guard away.
5. **Stop and ask before any destructive step**, including `rollback`.

## Procedure

**Step 1. Gather context.** Report back before proceeding:

```bash
uname -s
command -v claude && claude --version
du -sh ~/.claude 2>/dev/null
ls -la ~/.claude 2>/dev/null | head -30
ls -la ~/.claude.json 2>/dev/null
echo "CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR:-<unset>}"
echo "SHELL=$SHELL"
df -h ~ | tail -1
```

Flag it if: the OS is not Darwin or Linux; `~/.claude` does not exist;
`CLAUDE_CONFIG_DIR` is already set; or free disk space is less than twice the
size of `~/.claude`.

**Step 2. Confirm the sharing mode.** Ask the user to pick `full` or `safe`
and summarise the trade-off from the README's "Choose your sharing mode"
section in two sentences. `full` shares transcripts and gives cross-account
`--resume`; `safe` keeps transcripts per-account for confidentiality reasons.
Do not pick for them.

**Step 3. Dry run.**

```bash
chmod +x ./claude-profiles.sh
./claude-profiles.sh plan --share <their choice>
```

Show the user the output. Summarise in plain language what will be created and
confirm out loud that `~/.claude` appears nowhere as a write target. Get
explicit approval.

**Step 4. Apply.**

```bash
./claude-profiles.sh apply --share <their choice> --shell
```

Confirm the backup archive was written under `~/.claude-backups/` and tell the
user its path.

**Step 5. Hand back for the interactive part.** You cannot do this: it needs a
browser and a terminal the user controls. Give them these instructions:

- Open a new terminal.
- Run `claude-work`. It should already be signed in as the current account.
  If it asks for a login, log in with the **same** account. That is expected
  on macOS, where credentials are in the Keychain rather than in a file.
- Quit, run `claude-personal`, and log in with the **other** account.
- Come back here.

**Step 6. Verify.**

```bash
./claude-profiles.sh verify
```

Read every warning. The section that matters most is "Per-profile app state
(.claude.json)". If it reports that a launched profile has no `.claude.json`,
**stop**. That means this Claude Code version keeps OAuth state at
`~/.claude.json`, shared between both profiles, and the accounts are not
isolated. Point the user at the README section "If verify flags .claude.json"
and do not proceed.

**Step 7. Prove the sharing works.** In a project directory the user has used
before, have them run `claude-work`, send one message, quit, then run
`claude-personal --resume` in the same directory. The session from the work
profile should be listed. If it is not, check that
`~/.claude-personal/projects` is a symlink pointing at
`~/.claude-shared/projects`.

**Step 8. Report.** Tell the user, concisely:

- the backup path
- which profile holds which account
- the two launcher commands
- that `~/.claude` is untouched and can be deleted later to reclaim space
- the two live traps: keep `cleanupPeriodDays` identical in both
  `settings.json` files, and never resume the same session in both profiles
  at once
- that user-scope MCP servers and per-project trust do not carry over and will
  need setting up once in the second profile

## If something fails

Report the exact error and stop. Do not improvise a fix that involves deleting
directories, moving `~/.claude`, or editing the script's guards.
`ROLLBACK.md` has the undo procedure at three levels. Use the mildest one that
addresses the problem, and ask before running any of them.
