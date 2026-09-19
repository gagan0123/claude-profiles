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

macOS and Linux only. See [Windows](#windows) below.

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
  .credentials.json      real file, its own login
  .claude.json           real file, its own OAuth state and project trust
  settings.json          real file, copied from ~/.claude at setup
  CLAUDE.md              real file, copied from ~/.claude at setup
  projects   ──┐         symlink
  history.jsonl┤         symlink
  skills       ┤         symlink
  ...          │
               │
~/.claude-personal      profile 2
  .credentials.json      real file, its own login
  .claude.json           real file, its own OAuth state and project trust
  projects   ──┤         symlink
  history.jsonl┤         symlink
  skills       ┤         symlink
  ...          │
               │
~/.claude-shared ◄──────┘  the single real copy of everything shared
```

Launch with `claude-work` or `claude-personal`. Bare `claude` is deliberately
shadowed with an error, so you cannot drift back onto the old profile by
muscle memory.

---

## The safety model

The thing most likely to go wrong here is losing the login on your main
account. The script is built around avoiding that:

1. **`~/.claude` is only ever read.** Nothing is moved, deleted, or replaced
   with a symlink inside it. If the whole setup turns out to be a mistake,
   delete the three new directories and your original profile is exactly as
   it was.
2. **A tar backup of `~/.claude` and `~/.claude.json` is taken first**, into
   `~/.claude-backups/`, before anything is created.
3. **You never run `/logout`.** The main profile gets a copy of the existing
   credentials so it is already signed in. Only the second, empty profile
   does a browser login. This matters: current Claude Code versions can
   revoke the stored refresh token when you log out, which would kick you out
   of the account you were trying to keep.
4. **`plan` is a real dry run.** It prints every command it would execute and
   changes nothing. Run it first, read it, then run `apply`.
5. **`apply` refuses to clobber.** If a path where a symlink should go already
   holds real data, it warns and skips rather than deleting.
6. **`apply` is idempotent.** Running it twice is safe.

Cost of this approach: the shared data is a *copy*, so transcripts are on disk
twice until you delete `~/.claude`. Check `du -sh ~/.claude` first. Once
you have used the new setup for a week and are happy, delete the old
directory and reclaim the space.

---

## Quick start

```bash
chmod +x claude-profiles.sh

./claude-profiles.sh plan            # read the output, change nothing
./claude-profiles.sh apply --shell   # do it, and wire up the shell rc file

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
--yes            skip confirmations
```

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
| `plans/`, `tasks/`, `paste-cache/`, `image-cache/`, `session-env/` | A resumed session has its todos, pasted text and images intact. |
| `skills/`, `commands/`, `agents/`, `workflows/`, `rules/`, `output-styles/`, `plugins/` | Configure once, works in both. |

**`--share safe`** shares only `history.jsonl`, `plans/`, `paste-cache/` and
the config directories. Transcripts and checkpoints stay per profile.

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
| `.claude.json` | Holds the OAuth session, per-project trust decisions, and user-scope MCP servers. Sharing it would share the login. |
| `sessions/` | One file per running session, used for live-session detection and crash cleanup. Sharing it lets one profile clean up the other's running session. |
| `settings.json`, `CLAUDE.md` | Copied once into each profile, then free to diverge. Your work profile may have org-specific permissions or env you do not want in personal. |

---

## Things that will surprise you

**Trust prompts appear twice.** Per-project trust lives in `.claude.json`,
which is per profile. The first time you open a given project in the second
profile you get the trust dialog again, even though the transcripts are
already sitting there. Answer it once per profile per project.

**User-scope MCP servers do not carry over.** They also live in
`.claude.json`. Add them again in the second profile with
`claude mcp add --scope user`, or move the ones you can into a project-level
`.mcp.json` at the repo root, which both profiles read.

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

**On macOS, credentials live in the Keychain, not in a file.** The main
profile may still prompt for a browser login on first launch even though the
script copied everything it could. That is fine. Log in with the *same*
account. It is a login, not a logout, and revokes nothing.

---

## If verify flags `.claude.json`

`verify` checks that each profile has its own `.claude.json` *after* you have
launched it once. If a profile has been launched and still has no
`.claude.json` inside it, your Claude Code version is keeping that state at
`~/.claude.json` instead, outside the config directory. Both profiles then
share OAuth state and the isolation does not hold.

This is the known failure mode on Windows and it is worth confirming rather
than assuming on any platform, because the behaviour has changed between
versions and `CLAUDE_CONFIG_DIR` is still not formally documented (see
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
- [Authentication](https://code.claude.com/docs/en/authentication)
- [Issue #33430](https://github.com/anthropics/claude-code/issues/33430) — `CLAUDE_CONFIG_DIR` is undocumented; track it for changes
