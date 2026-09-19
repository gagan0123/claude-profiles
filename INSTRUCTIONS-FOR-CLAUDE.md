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
6. **Your Bash tool has no terminal.** The script's confirmation prompts
   cannot be answered from here; without `--yes` they stop with "No terminal
   is available". So `--yes` is how you pass on the user's approval, and it
   is only ever added *after* the user has approved that exact step in chat.

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
size of `~/.claude` (the script's preflight repeats this check with exact
numbers, and `apply` refuses to start if the copy plus backup cannot fit).

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
confirm out loud that `~/.claude` appears nowhere as a write target (only as
the *source* of `cp` commands). Quote the disk-space line. Get explicit
approval.

**Step 4. Apply.** Only after the approval in Step 3:

```bash
./claude-profiles.sh apply --share <their choice> --shell --yes
```

`--yes` is required because there is no terminal for the prompt (rule 6).
The script takes the backup first and reads it back before touching anything
else; if the backup step dies, nothing else has been created. Confirm the
archive path printed under `~/.claude-backups/` and tell the user. Note that
the run also wrote `~/.claude-shared/.claude-profiles.conf`, which is why
later commands need no flags.

If you are running inside a Claude Code session yourself, expect a `tar exit
1` warning: the transcript of this very session is being written while it is
archived. That is harmless and the script says so.

**Step 5. Hand back for the interactive part.** You cannot do this: it needs a
browser and a terminal the user controls. Give them these instructions:

- Open a new terminal.
- Run `claude-work`. On Linux it should already be signed in as the current
  account. On macOS it **will** ask for a login, because the Keychain entry
  is keyed to the config directory and none exists yet for `~/.claude-work`.
  Log in with the **same** account. It is a login, not a logout.
- Quit, run `claude-personal`, and log in with the **other** account.
- Come back here.

**Step 6. Verify.**

```bash
./claude-profiles.sh verify
```

No flags needed: it reads the names and sharing mode from
`~/.claude-shared/.claude-profiles.conf`. Read every warning. The section
that matters most is "Per-profile app state (.claude.json)". If it reports
that the **second** profile has been launched but has no `.claude.json`,
**stop**. That means this Claude Code version keeps OAuth state at
`~/.claude.json`, shared between both profiles, and the accounts are not
isolated. Point the user at the README section "If verify flags .claude.json"
and do not proceed. (The main profile received a copy of `.claude.json` at
setup, so its presence proves nothing; the second profile's does.)

The "Settings that still point at ~/.claude" section is informational:
`apply` already relocates a `statusLine` command or hook path under
`~/.claude` into `~/.claude-shared` and repoints the setting, so a
reference this section still flags means that script did not exist under
`~/.claude` at apply time (or was added since). Tell the user to re-run
`apply` (safe to repeat) or repoint the setting by hand.

Quote the "Accounts" section back to the user: it names which email each
launched profile is actually logged in as, which is the only real proof the
two profiles hold different accounts.

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
- that user-scope MCP servers and per-project trust carried over into the
  main profile but not the second, which needs them set up once
- whether `verify` warned about settings pointing at `~/.claude`, and what
  that means for deleting it later
- that IDE extensions do not see the shell functions and will use `~/.claude`
  unless `CLAUDE_CONFIG_DIR` is set in the IDE's own environment

## If something fails

Report the exact error and stop. Do not improvise a fix that involves deleting
directories, moving `~/.claude`, or editing the script's guards.
`ROLLBACK.md` has the undo procedure at three levels. Use the mildest one that
addresses the problem, and ask before running any of them. `rollback` needs
`--yes` from here for the same reason `apply` did; add it only after the user
has said yes to that specific rollback.
