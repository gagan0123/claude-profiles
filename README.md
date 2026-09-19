# Two Claude Code accounts on one machine, sharing sessions

Run a work account and a personal account side by side on the same machine,
both logged in at once, sharing session transcripts, prompt history,
checkpoints, skills and plugins.

Contents of this bundle:

| File | What it is |
|---|---|
| `claude-profiles.sh` | The setup script. Has `plan`, `apply`, `verify` and `rollback` modes. |
| `README.md` | This file. Read it before running anything. |
| `INSTRUCTIONS-FOR-CLAUDE.md` | Paste this into Claude Code on the target machine and let it drive. |
| `ROLLBACK.md` | How to undo, at three levels of severity. |
| `tests/e2e.sh` | End-to-end test against a throwaway fake home. Never touches the real `~/.claude`. |
| `AGENTS.md` | For anyone changing the script: invariants, portability rules, how to test. |
| `LICENSE` | GPL-2.0-or-later, the licence WordPress uses. |

macOS and Linux only. See [Windows](#windows) below.

---

## Quick start

Before running `apply`, make the one decision that matters: see
[Choose your sharing mode](#choose-your-sharing-mode-before-you-run-this).

```bash
chmod +x claude-profiles.sh

./claude-profiles.sh plan                    # read the output, change nothing
./claude-profiles.sh apply --shell --share full   # do it; --share safe is the alternative

# open a NEW terminal
claude-work                          # should already be logged in
# quit, then:
claude-personal                      # browser login, second account
# quit, then:
./claude-profiles.sh verify
```

Useful options:

```
--main NAME      name of the profile that inherits your current login (default: work)
--second NAME    name of the second profile (default: personal)
--share full     share transcripts too (default)
--share safe     do NOT share transcripts, see below
--source DIR     seed from a profile other than ~/.claude
--shell          append the source line to your .zshrc / .bashrc for you
--no-backup      skip the tar archive (only sensible on a re-run of apply)
--yes            skip confirmations; required when no terminal can answer them
```

`--main`, `--second`, `--share` and `--source` are remembered in
`~/.claude-shared/.claude-profiles.conf` after `apply`, so `verify` and
`rollback` use the same values without you repeating them. Explicit flags
always win.

---

## How it works

Claude Code reads its credentials, settings and session data from one
directory, `~/.claude` by default. The `CLAUDE_CONFIG_DIR` environment
variable points it somewhere else. Two directories means two independent
logins that can run at the same time in different terminals.

By itself that also splits your session history in two, which is not what we
want. So the data directories inside each profile are symlinked at a single
shared location.

```
~/.claude              your existing setup. NEVER MODIFIED. Still works.

~/.claude-work         profile 1
  .credentials.json      real file, copied from ~/.claude (Linux) so it is
                         already logged in; on macOS the Keychain holds it
  .claude.json           real file, copied from ~/.claude.json: onboarding
                         done, project trust, user-scope MCP servers
  settings.json          real file, copied from ~/.claude at setup
  CLAUDE.md              real file, copied from ~/.claude at setup
  projects   ──┐         symlink
  history.jsonl┤         symlink
  skills       ┤         symlink
  ...          │
               │
~/.claude-personal      profile 2
  .credentials.json      real file, written by its own browser login
  .claude.json           real file, created on first launch, own trust map
  projects   ──┤         symlink
  history.jsonl┤         symlink
  skills       ┤         symlink
  ...          │
               │
~/.claude-shared ◄──────┘  the single real copy of everything shared
  .claude-profiles.conf    records the names and sharing mode you chose, so
                           verify and rollback do not need the flags again
```

Launch with `claude-work` or `claude-personal`. Bare `claude` is deliberately
shadowed with an error, so you cannot drift back onto the old profile by
muscle memory. The shadow steps aside when `CLAUDE_CONFIG_DIR` is already
set, which is what makes `claude --version`, `claude mcp add` and friends
keep working *inside* a session started with `claude-work` (the session's
shell inherits the variable).

---

## The safety model

The thing most likely to go wrong here is losing the login on your main
account. The script is built around avoiding that:

1. **`~/.claude` is only ever read.** Nothing is moved, deleted, or replaced
   with a symlink inside it. If the whole setup turns out to be a mistake,
   delete the three new directories and your original profile is exactly as
   it was.
2. **A tar backup of `~/.claude` and `~/.claude.json` is taken first**, into
   `~/.claude-backups/`, before anything is created. The archive is read back
   before the script continues; if tar fails outright, nothing else happens.
   The directory is mode 700 and the archive mode 600, because the archive
   contains your credentials.
3. **You never run `/logout`.** The main profile gets a copy of the existing
   credentials so it is already signed in. Only the second, empty profile
   does a browser login. This matters: current Claude Code versions can
   revoke the stored refresh token when you log out, which would kick you out
   of the account you were trying to keep.
4. **`plan` is a real dry run.** It prints every command it would execute and
   changes nothing. Run it first, read it, then run `apply`.
5. **`apply` refuses to clobber.** If a path where a symlink should go already
   holds real data, it warns and skips rather than deleting.
6. **`apply` is idempotent.** Running it twice is safe. Each shared path is
   copied under a temporary name and renamed only when the copy completes, so
   an interrupted run (Ctrl-C, disk full) leaves nothing that a second run
   would mistake for finished data. Pass `--no-backup` on a re-run if you do
   not want a second archive.
7. **Confirmation prompts fail closed.** `apply` and `rollback` ask before
   doing anything. When there is no terminal to answer (inside Claude Code's
   Bash tool, CI, an editor task) they stop and tell you to pass `--yes`.
   Nothing is half-done.
8. **Preflight checks free disk space** against the size of the copy plus the
   backup, and `apply` refuses to start if it cannot fit.

Cost of this approach: the shared data is a *copy*, so transcripts are on disk
twice until you delete `~/.claude`. `plan` prints the sizes. Once you have
used the new setup for a week and are happy, delete the old directory and
reclaim the space, after checking the "settings that still point at
~/.claude" section of `verify` (see below).

---

## Choose your sharing mode before you run this

This is the one decision worth thinking about rather than accepting the
default.

**`--share full`** (default) shares these paths:

| Path | Effect of sharing |
|---|---|
| `projects/` | Transcripts and auto-memory. This is what makes `--resume` and `--continue` work across both accounts. |
| `file-history/` | Checkpoint restore works across both. |
| `history.jsonl` | Up-arrow prompt recall is one list. |
| `plans/`, `tasks/`, `paste-cache/`, `image-cache/`, `uploads/`, `session-env/` | A resumed session has its task list, pasted text, images and attachments intact. |
| `agent-memory/` | Subagents declared with `memory: user` keep one memory across both accounts. |
| `skills/`, `commands/`, `agents/`, `workflows/`, `rules/`, `output-styles/`, `plugins/` | Configure once, works in both. |

**`--share safe`** shares only `history.jsonl`, `plans/`, `paste-cache/` and
the config directories. Transcripts and checkpoints stay per profile.
**Safe mode still shares `history.jsonl`, which holds every prompt typed under
either account together with its project path, so a confidential prompt typed
under the work account is recallable with the up arrow under the personal
one.** Anyone who needs prompts kept apart must not use this script's
sharing at all.

The reason `safe` exists: transcripts are plaintext and unencrypted on disk,
and the Claude Code docs are explicit that anything passing through a tool
lands in them, including `.env` file contents and any credential a command
printed. Sharing `projects/` makes every work conversation readable and
resumable under the personal account, and resuming one sends that content to
Anthropic under the personal account's terms and retention rather than your
employer's. If the work account is a Team or Enterprise seat with a
compliance posture attached, that is a real problem and not a theoretical one.

`safe` costs you cross-account resume, which is probably the main thing you
wanted. It keeps the ergonomics. Pick deliberately.

Reference: <https://code.claude.com/docs/en/claude-directory> ("Plaintext
storage").

---

## What is deliberately NOT shared

| Path | Why not |
|---|---|
| `.credentials.json` | This is the entire point of the separation. If `verify` ever reports this as a symlink, the setup is broken. |
| `.claude.json` | Holds the OAuth session, per-project trust decisions, and user-scope MCP servers. Sharing it would share the login. The main profile gets a *copy* of `~/.claude.json` so it inherits trust decisions and MCP servers; the second profile starts empty. |
| `sessions/` | One file per running session, used for live-session detection and crash cleanup. Sharing it lets one profile clean up the other's running session. |
| `backups/` | Rolling copies of that profile's own `.claude.json`. Meaningless if shared. |
| `settings.json`, `CLAUDE.md` | Copied once into each profile, then free to diverge. Your work profile may have org-specific permissions or env you do not want in personal. |

`verify` checks that `.credentials.json`, `.claude.json` and `sessions/` are
real files or directories in each profile, never symlinks, and that nothing
inside `~/.claude` points at the new directories. It also asks the binary
itself, via `claude auth status --json`, which account each launched
profile is logged into, and refuses to pass if both profiles report the
same account.

---

## Things that will surprise you

**Trust prompts appear again in the second profile.** Per-project trust lives
in `.claude.json`, which is per profile. The main profile inherits a copy of
yours, so it behaves as before. The first time you open a given project in
the second profile you get the trust dialog again, even though the
transcripts are already sitting there. Answer it once per project.

**User-scope MCP servers do not carry over to the second profile.** They also
live in `.claude.json`. Add them again there with
`claude-personal mcp add --scope user`, or move the ones you can into a
project-level `.mcp.json` at the repo root, which both profiles read.

**Settings that point back at `~/.claude` by absolute path.** A `statusLine`
command such as `~/.claude/statusline.sh`, or a hook script kept under
`~/.claude/hooks/`, would otherwise be copied into both profiles'
`settings.json` *still pointing at `~/.claude`*, which only works as long as
`~/.claude` exists. `apply` fixes this itself: it copies any script that
`settings.json` points at under `~/.claude/`, `$HOME/.claude/`, or your
literal home path into `~/.claude-shared/`, then rewrites the setting in
each profile's own `settings.json` to `~/.claude-shared/<path>`. It is
idempotent and never touches `~/.claude` itself. `verify` reports anything
it could not relocate this way -- normally a script that did not exist
under `~/.claude` at apply time, or was added since. Re-run `apply` (safe
to repeat) or fix the path in `settings.json` by hand.

**IDE extensions do not know about profiles.** The VS Code and JetBrains
extensions launch and discover Claude Code without your shell functions, so
they use `~/.claude` (the old profile) unless `CLAUDE_CONFIG_DIR` is set in
the IDE's own environment. If you rely on `/ide` or the extension's launcher,
set that variable where the IDE reads it (for example the extension's
environment settings, or by launching the IDE from a terminal where it is
exported) and accept that one IDE window is tied to one profile.

**Re-run `verify` after Claude Code upgrades.** Everything here rests on
Claude Code following symlinks in its config dir and on `CLAUDE_CONFIG_DIR`
keeping `.claude.json` and credentials per directory. Both are documented
today (see references), but a future version that rewrites `history.jsonl`
through a temp file and rename would silently replace the link with a real
file. `verify` catches exactly that, so run it after an upgrade.

**`cleanupPeriodDays` must match in both profiles.** The retention sweep runs
per profile but operates on the same shared `projects/` directory. If work is
set to 7 days and personal is on the 30-day default, the work profile will
silently delete your personal transcripts. `verify` checks this and complains
if they differ. Same trap applies to `claude project purge`: run it in either
profile and it wipes the shared copy.

**Do not resume the same session from both profiles at once.** Different
sessions in the same project directory are fine. The same `.jsonl` open in two
processes means two writers appending to one file, and you will corrupt it.
Nothing warns you.

**On macOS, credentials live in the Keychain, not in a file.** The Keychain
entry is keyed to the config directory (the authentication docs: "keys the
macOS Keychain entry to that directory too, so a session with a different
`CLAUDE_CONFIG_DIR` reads a different entry"). So the main profile *will*
prompt for a browser login on first launch, because there is no entry for
`~/.claude-work` yet. That is fine. Log in with the *same* account. It is a
login, not a logout, and revokes nothing. The exception is a Mac where the
Keychain was locked at login time (typical over SSH): Claude Code then falls
back to `.credentials.json` in the config dir, the script copies that file,
and no prompt appears. `verify` prints how many `Claude Code` Keychain
entries exist so you can see that each profile got its own.

---

## If verify flags `.claude.json`

`verify` checks that each profile has its own `.claude.json` *after* you have
launched it once. The main profile gets a copy at setup, so the check that
matters is on the second profile: if it has been launched and still has no
`.claude.json` inside it, your Claude Code version is keeping that state at
`~/.claude.json` instead, outside the config directory. Both profiles then
share OAuth state and the isolation does not hold.

The docs for the `.claude` directory say that with `CLAUDE_CONFIG_DIR` set,
"every `~/.claude` path on this page lives under that directory instead",
and `.claude.json` is on that page, so on current versions this should not
happen on macOS or Linux. It is the known failure mode on Windows and it is
worth confirming rather than assuming, because the behaviour has changed
between versions (see
[anthropics/claude-code#33430](https://github.com/anthropics/claude-code/issues/33430)).

If you hit it, stop before logging the second account in, and fall back to
giving each profile its own `HOME`:

```bash
claude-work() {
  HOME="$HOME/.claude-homes/work" CLAUDE_CONFIG_DIR="$HOME/.claude-homes/work/.claude" command claude "$@"
}
```

That is heavier (it changes what `~` means for everything the session
touches, including git config and SSH) and is not what this script sets up.
Treat it as a last resort, and check whether a newer Claude Code version has
fixed the behaviour first.

---

## Windows

Not supported by this script, and the shell approach alone is not sufficient
there. Claude Code keeps global state in `~/.claude.json` outside the config
directory, so two simultaneous instances sharing one real home directory step
on each other regardless of `CLAUDE_CONFIG_DIR`. You need separate
`USERPROFILE` values per instance. WSL works fine and this script runs there.

---

## Policy note

Separating work and personal contexts, billing and credentials this way is a
normal and legitimate use. Rotating between accounts to get around usage
limits is not, and Anthropic treats the two differently. This setup is for the
former.

---

## References

- [Explore the .claude directory](https://code.claude.com/docs/en/claude-directory) — authoritative list of what every path holds, retention behaviour, plaintext storage warning
- [Environment variables](https://code.claude.com/docs/en/env-vars)
- [Authentication, "Credential management"](https://code.claude.com/docs/en/authentication#credential-management) — per-platform credential storage, and the statement that `CLAUDE_CONFIG_DIR` keys both the credentials file and the macOS Keychain entry
- [Retention (`cleanupPeriodDays`)](https://code.claude.com/docs/en/claude-directory) — which paths the age sweep deletes; note it covers `plans/` and `paste-cache/`, which are shared in both modes
- [Issue #33430](https://github.com/anthropics/claude-code/issues/33430) — `CLAUDE_CONFIG_DIR` is undocumented; track it for changes

---

## License

GPL-2.0-or-later, the licence WordPress uses. Copyright 2026 Gagan Deep
Singh. The full licence text is in [`LICENSE`](LICENSE).
