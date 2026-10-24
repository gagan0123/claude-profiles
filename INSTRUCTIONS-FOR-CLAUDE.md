# Instructions for Claude Code

Paste the block below into Claude Code on the machine being set up, from the
directory containing this bundle. Everything after the line is addressed to
Claude, not to you.

---

You are setting up two or more Claude Code profiles on this machine so
separate accounts (work and personal, or one per client) can run side by
side, sharing session history. The
bundle in this directory contains `claude-profiles.sh`, `README.md` and
`ROLLBACK.md`.

Read `README.md` fully before you do anything. It contains the safety model
and the failure modes, and you need both.

## Non-negotiable rules

1. **Never run `/logout`, and never suggest it.** Current Claude Code versions
   can revoke the stored refresh token on logout, which would sign the user
   out of the account they are trying to preserve. The whole design avoids it.
2. **Never write to, delete from, or symlink anything inside `~/.claude`.** It
   is the fallback if this goes wrong. Read-only, always. The script's
   `finalize` command is the one exception, and you never run it unless the
   user asks for it by name in this conversation. Never `rm -rf ~/.claude`
   yourself under any circumstances, and never as a "cleanup" step. If the
   user also uses the Claude Desktop app, or `verify` or the banner reports
   the **hub layout** (`~/.claude-shared` linking back into `~/.claude`),
   `~/.claude` holds the only copy of the shared data: `finalize` refuses
   there, and you never suggest it. See the README's "Hub layout" section.
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
7. **Never run `statusline` unless the user asks for the status line.** It
   is optional and not part of the setup. It edits every profile's
   `settings.json`; `--replace` also overwrites a status line the user
   already has, so use it only when they say to replace theirs.
8. **`remove` is destructive to that profile's own state**, even though it
   archives the directory first: it deletes `~/.claude-<name>`, drops the
   name from `PROFILES`, and regenerates the launcher snippet. Never run it
   unless the user names that specific profile in this conversation.

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
ls -d ~/.claude-* 2>/dev/null
grep -nE '^[[:space:]]*alias[[:space:]]+claude' ~/.bashrc ~/.zshrc ~/.bash_aliases ~/.bashrc.d/* ~/.zshrc.d/* 2>/dev/null
```

An existing `~/.claude-<name>` usually means a hand-made `CLAUDE_CONFIG_DIR`
setup, which Step 3 handles. An existing `alias claude...` line is left over
from that setup: tell the user it will shadow the new launcher and ask to
comment it out. If you keep a backup of a file under `~/.bashrc.d/`, put it
somewhere else, because every file in that directory is sourced.

Flag it if: the OS is not Darwin or Linux; `~/.claude` does not exist;
`CLAUDE_CONFIG_DIR` is already set; or free disk space is less than twice the
size of `~/.claude` (the script's preflight repeats this check with exact
numbers, and `apply` refuses to start if the copy plus backup cannot fit).

**Step 2. Confirm the profiles and the sharing mode.** Ask the user whether
the easy setup (`work`, `personal`) fits, or whether they want their own
list — for example, one profile per client. If they want a custom list,
collect the names and say back which one keeps the current login: it is
always the first name, and it is whichever account they are logged into
right now. Then ask them to pick `full` or `safe` and summarise the
trade-off from the README's "Choose your sharing mode" section in two
sentences. `full` shares transcripts and gives cross-account `--resume`;
`safe` keeps transcripts per-account for confidentiality reasons. Do not
pick either for them.

Then ask, once, whether their user-level `CLAUDE.md` should be **the same
file across every profile** or **free to differ** per profile. If
`~/.claude/CLAUDE.md` does not exist, skip the question and use `copied`.
Otherwise summarise the README's "One CLAUDE.md or one per profile" in two
sentences: `shared` keeps one file at `~/.claude-shared/CLAUDE.md` that
every profile links to, so a fact fixed in one profile is fixed in all;
`copied` gives each profile its own copy, which is right when the profiles
want different instructions, and is what happened silently before this
option existed. Their answer becomes `--claude-md shared` or
`--claude-md copied` on every `plan` and `apply` below. Do not pick for
them, and do not change the choice later by re-running `apply` with the
other flag: the script refuses that, and the `claude-md` command is the
supported way to switch (only when the user asks for it, since it
rewrites every profile's `CLAUDE.md` after archiving the copies).

**Step 3. Dry run.**

```bash
chmod +x ./claude-profiles.sh
./claude-profiles.sh plan --profiles <their list> --share <their choice> --claude-md <their choice>
```

Always pass `--profiles` explicitly, even for the easy setup (`work,personal`):
the interactive prompt the script would otherwise show cannot be answered
from your Bash tool, which has no terminal.

Show the user the output. Summarise in plain language what will be created and
confirm out loud that `~/.claude` appears nowhere as a write target (only as
the *source* of `cp` commands). Quote the disk-space line. Get explicit
approval.

**If `plan` warns that a profile directory "already holds real data"**, stop
and deal with that before anything else. It means `~/.claude-<name>` already
exists as a real profile, usually because the user tried `CLAUDE_CONFIG_DIR`
by hand before finding this script, and `apply` will refuse to run at all
until it is resolved. Show the user the exact list of paths the warning
printed. Explain, in two sentences: `--adopt` first archives that whole
directory to `~/.claude-backups/claude-<name>-adopted-<stamp>.tar.gz`, then
copies into `~/.claude-shared` only the files it does not already have
(never overwriting one, union-merging `history.jsonl` by timestamp) and
moves the originals into `~/.claude-<name>/.adopted-<stamp>/` before
linking; the profile's credentials, `.claude.json` and settings are left
exactly as they are. Their alternative is to move the directory aside
themselves and merge by hand later. Re-run `plan --adopt` so they can see
the copied/skipped counts, get explicit approval for adopting, and only then
add `--adopt` to the Step 4 command. Do not add it on your own initiative.
If the user wants the adopted profile to log in fresh rather than keep the
account it holds, then after Step 4 move its `.credentials.json` into the
`.adopted-<stamp>/` directory `apply` created. Move it; never delete it, and
never `/logout`.

**Step 4. Apply.** Only after the approval in Step 3:

```bash
./claude-profiles.sh apply --profiles <their list> --share <their choice> --claude-md <their choice> --shell --yes
```

Add `--adopt` to that command if, and only if, Step 3 turned up pre-existing
profile data and the user approved adopting it.

`--yes` is required because there is no terminal for the prompt (rule 6).
If your permission mode refuses to run the command, do not look for another
way to run it: give the user the exact command to run with the `!` prefix,
and wait for its output before continuing.
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
- Run the launcher for the first profile named (`claude-work` in the easy
  setup). On Linux it should already be signed in as the current account. On
  macOS it **will** ask for a login, because the Keychain entry is keyed to
  the config directory and none exists yet for that profile. Log in with the
  **same** account. It is a login, not a logout.
- Quit, then for each remaining profile in turn: run its launcher
  (`claude-personal`, then any further `claude-<name>`) and log in with that
  profile's own account. Quit before moving to the next one.
- Come back here.

**Step 6. Verify.**

```bash
./claude-profiles.sh verify
```

No flags needed: it reads the names and sharing mode from
`~/.claude-shared/.claude-profiles.conf`. Read every warning. The section
that matters most is "Per-profile app state (.claude.json)". If it reports
that a **fresh** profile (any but the first) has been launched but has no
`.claude.json`, **stop**. That means this Claude Code version keeps OAuth
state at `~/.claude.json`, shared by every profile, and the accounts are not
isolated. Point the user at the README section "If verify flags .claude.json"
and do not proceed. (The first profile received a copy of `.claude.json` at
setup, so its presence proves nothing; a fresh profile's does.)

The "Settings that still point at ~/.claude" section is informational:
`apply` already relocates a `statusLine` command or hook path under
`~/.claude` into `~/.claude-shared` and repoints the setting, so a
reference this section still flags means that script did not exist under
`~/.claude` at apply time (or was added since). Tell the user to re-run
`apply` (safe to repeat) or repoint the setting by hand. The
`claudeMdExcludes` entry naming `~/.claude/CLAUDE.md` is deliberately not
counted as such a reference.

If the "Ancestor CLAUDE.md" section warns, a profile's `settings.json` does
not list `~/.claude/CLAUDE.md` in `claudeMdExcludes`, so that file loads as
project instructions in every project under the home directory. Re-run
`apply`, which adds it; if the warning stays because the profile already
had its own `claudeMdExcludes`, tell the user to add the exact path that
the warning prints to that array by hand.

The "CLAUDE.md" section checks the choice from Step 2 against what is on
disk: with `shared`, that `~/.claude-shared/CLAUDE.md` is a real file and
every profile's `CLAUDE.md` is a link to it; with `copied`, that each is a
real file. A broken or wrong-target link is a problem; a stray real copy in
shared mode is only a warning, and the fix it names (`claude-md shared`)
is a mutating command, so report it and ask rather than run it.

Quote the "Accounts" section back to the user: it names which email and
organization each launched profile is actually logged in as, which is the
only real proof that no two profiles hold the same account. The same email
in two different organizations is two accounts and is not flagged.

**Step 7. Prove the sharing works.** In a project directory the user has used
before, have them run `claude-work`, send one message, quit, then run
`claude-personal --resume` in the same directory. The session from the work
profile should be listed. If it is not, check that
`~/.claude-personal/projects` is a symlink pointing at
`~/.claude-shared/projects`.

**Step 8. Report.** Tell the user, concisely:

- the backup path
- which profile holds which account, for each profile set up
- every launcher command
- that `~/.claude` is untouched; later, `./claude-profiles.sh finalize`
  removes it safely (it re-runs verify, checks nothing still points into it
  and no session is running on it, and takes a backup first); never
  `rm -rf` it
- the two live traps: keep `cleanupPeriodDays` identical in both
  `settings.json` files, and never resume the same session in two profiles
  at once
- which `CLAUDE.md` mode they chose, and what it means day to day: with
  `shared`, editing `CLAUDE.md` in any profile edits the one file all of
  them read; with `copied`, each profile's copy is its own and a change
  has to be made in each
- that user-scope MCP servers and per-project trust carried over into the
  main profile but not the second, which needs them set up once
- whether `verify` warned about settings pointing at `~/.claude`, and that
  `finalize` will refuse while such a reference is still there
- that IDE extensions do not see the shell functions and will use `~/.claude`
  unless `CLAUDE_CONFIG_DIR` is set in the IDE's own environment
- how to add a profile later: `./claude-profiles.sh add <name> --yes` after
  the user approves
- that they can run `status` any time for a glance

## If something fails

Report the exact error and stop. Do not improvise a fix that involves deleting
directories, moving `~/.claude`, or editing the script's guards.
`ROLLBACK.md` has the undo procedure at three levels. Use the mildest one that
addresses the problem, and ask before running any of them. `rollback` needs
`--yes` from here for the same reason `apply` did; add it only after the user
has said yes to that specific rollback.
