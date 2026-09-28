# claude-profiles

Two or more Claude Code accounts on one machine, sharing sessions.

Run a work account and a personal account side by side on the same machine,
both logged in at once, sharing session transcripts, prompt history,
checkpoints, skills and plugins. The same script scales past two: if you work
for several clients under a separate Claude account each, set up one named
profile per client and all of them share that history together.

Contents of this bundle:

| File | What it is |
|---|---|
| `claude-profiles.sh` | The setup script. Has `plan`, `apply` (with `--adopt`), `verify`, `rollback`, `finalize`, `add`, `remove`, `status` and `statusline` modes. |
| `statusline.sh` | An optional Claude Code status line that shows which profile a session is in. Installed only by `./claude-profiles.sh statusline`, never by `apply`. |
| `README.md` | This file. Read it before running anything. |
| `INSTRUCTIONS-FOR-CLAUDE.md` | Paste this into Claude Code on the target machine and let it drive. |
| `ROLLBACK.md` | How to undo, at three levels of severity. |
| `tests/e2e.sh` | End-to-end test against a throwaway fake home. Never touches the real `~/.claude`. |
| `AGENTS.md` | For anyone changing the script: invariants, portability rules, how to test. |
| `LICENSE` | GPL-2.0-or-later. |

macOS and Linux only. See [Windows](#windows) below.

---

## Install

The supported way to get this script is to clone the repository or download
the release tarball, then either run it from the checkout — what the quick
start below does — or copy `claude-profiles.sh` onto a directory on your
`PATH`, such as `~/.local/bin/`:

```bash
install -m 755 claude-profiles.sh ~/.local/bin/
```

There is no curl-pipe-sh installer, on purpose: this script handles
credentials, and you should read it before you run it, not pipe it straight
into `bash` from a URL.

Releases are tagged `vX.Y.Z` on GitHub
(<https://github.com/gagan0123/claude-profiles/releases>). `verify` records
which version of the script produced the setup and warns when the installed
Claude Code version has moved on since the last `apply`.

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

# weeks later, once you trust the new setup and want the space back:
./claude-profiles.sh finalize        # the only supported way to delete ~/.claude
```

### Several clients

More than two accounts works the same way. Name every profile explicitly;
the first name keeps your current login, every other one gets its own
browser login:

```bash
./claude-profiles.sh plan    --profiles personal,acme,globex
./claude-profiles.sh apply   --profiles personal,acme,globex --shell --share full
```

Launchers: `claude-personal` (already logged in), `claude-acme` and
`claude-globex` (each a fresh browser login).

Running `plan` or `apply` with no `--profiles` flag from a real terminal, no
conf file yet and no `--yes`, asks interactively instead of silently
defaulting: "Easy setup with claude-work and claude-personal? [Y/n]", and on
`n` asks how many profiles and a name for each. Pass `--profiles` (or
`--yes`) to skip the prompt, which is what any non-interactive run must do.

Useful options:

```
--profiles LIST  comma-separated profile names, at least two (default:
                 work,personal); the first inherits your current login,
                 every other one starts empty and logs in via the browser
--share full     share transcripts too (default)
--share safe     do NOT share transcripts, see below
--source DIR     seed from a profile other than ~/.claude
--shell          append the source line to your .zshrc / .bashrc for you
--no-backup      skip the tar archive (only sensible on a re-run of apply; for
                 finalize it requires an existing one instead of skipping)
--yes            skip confirmations; required when no terminal can answer them
--settings NAME=PATH  use PATH as that profile's settings.json instead of
                 copying from ~/.claude (repeatable; full replacement, not a
                 merge -- see "Day to day" below)
--json           machine-readable output, for `status` and `verify` only
```

`--main NAME` and `--second NAME` still work, as deprecated aliases for
`--profiles NAME,NAME`; using either prints a deprecation notice, and
combining them with `--profiles` is an error.

`--profiles` (recorded as `PROFILES=name,name,...`), `--share` and `--source`
are remembered in `~/.claude-shared/.claude-profiles.conf` after `apply`, so
`verify` and `rollback` use the same values without you repeating them.
Explicit flags always win.

---

## Day to day

Once the setup exists, most sessions only need `status`, and occasionally
`add`, `remove`, or `--json` for scripting against the other two.

### `status`

```bash
./claude-profiles.sh status
```

Read-only: it changes nothing and always exits 0, so it is safe to run
anywhere, including from a prompt or status-bar script. It prints the
script's own version and the installed Claude Code version, names which
profile (if any) the current terminal is running under, then gives one line
per profile with its logged-in account, the shared-data size and file counts
it sees, and finally a note on backups on disk and whether the setup has
been finalized or holds any adopted profiles. Run it for a daily glance
instead of the fuller `verify`.

### `add` and `remove`

```bash
./claude-profiles.sh add acme --yes
```

Creates `~/.claude-acme` with its own fresh browser login, copies
`settings.json` and `CLAUDE.md` from `~/.claude` if it still exists (or from
the first profile in `PROFILES` if it does not -- see "Things that will
surprise you" below), links it into the shared data, appends `acme` to
`PROFILES` in the conf file, and regenerates the launcher snippet so
`claude-acme` exists in a new shell. `add` also takes a comma-separated list
to create several profiles in one call, and `--settings acme=PATH` to seed
that profile's `settings.json` from somewhere other than the copy. It
refuses a name already in `PROFILES`, and refuses a directory that already
holds real data -- that is what `apply --adopt` is for, not `add`. Like
every command that changes something, it fails closed without `--yes` when
there is no terminal to confirm.

```bash
./claude-profiles.sh remove acme
```

Archives the whole `~/.claude-acme` to
`~/.claude-backups/claude-acme-removed-<timestamp>.tar.gz`, deletes the
directory, drops `acme` from `PROFILES`, and regenerates the launcher
snippet. It leaves `~/.claude-shared` untouched -- see "Things that will
surprise you" for what that means for the removed profile's transcripts. It
refuses an unknown name, refuses if that profile's `sessions/` is non-empty
(a session may still be running there), and refuses to remove the last
remaining profile. Removing the first, login-inheriting profile is allowed
but prints a warning, since it is the profile every later `add` seeds from.
Asks for confirmation; needs `--yes` without a terminal.

### `--settings NAME=PATH`

Repeatable, on `plan`, `apply` and `add`. It is a full replacement for that
profile's `settings.json`, not a merge with the copy from `~/.claude`: to
change only a few keys, start from a copy of your own `settings.json` and
edit those keys, rather than writing a settings file from scratch.

```bash
cp ~/.claude/settings.json .tmp/acme-settings.json
# edit .tmp/acme-settings.json: change model, effortLevel, env as needed
./claude-profiles.sh apply --profiles work,personal,acme \
  --settings acme=.tmp/acme-settings.json --yes
```

It is ignored for a profile that already has a `settings.json` -- re-running
`apply` never overwrites one -- is not recorded in the conf file, and does
not support a path containing spaces.

### `statusline` (optional)

```bash
./claude-profiles.sh statusline
```

Nothing else in the setup installs this; run it only if you want it. It
copies `statusline.sh` from the checkout to
`~/.claude-shared/claude-profiles-statusline.sh` and sets `statusLine` in
every profile's own `settings.json` to run it. `~/.claude` is not touched.
It needs [`jq`](https://jqlang.org), both for that edit and at run time, and
asks for confirmation (`--yes` without a terminal). The line looks like:

```
[Opus · high] 👤 work 📡 | 📁 claude-profiles | 🌿 main #42 | ███████▎░░ 73% | $12.35 | 5h 62% left ↻ 1h6m | 7d 60% left ↻ 3d11h | session name
```

- **Profile**, from `CLAUDE_CONFIG_DIR` (`~/.claude-work` shows `work`,
  unset shows `default`), in a colour derived from the name so each profile
  always looks the same. To choose the colour yourself, set
  `CLAUDE_STATUSLINE_PROFILE_COLOR` to an SGR code such as `1;34` in that
  profile's `settings.json` `env` block.
- **Remote Control**: 📡 when connected, 📴 when not. The JSON Claude Code
  sends the status line has no field for it, so this reads the session's
  own file under `<profile>/sessions/`, which gains a `bridgeSessionId`
  while Remote Control is connected. That file is not documented and may
  change in a later Claude Code version; if it does, this shows 📴 rather
  than failing. Toggling Remote Control is not one of the events that
  re-run a status line, so the command also sets `refreshInterval` to 5
  seconds; without it the icon only changes on your next message. A
  `refreshInterval` you set yourself is kept.
- **Branch**, read from the directory the session is in, and the open PR's
  number as a clickable link (OSC 8) when the branch has one, coloured by
  review state.
- **Context**, **5h** and **7d** go green, then yellow from 70% used, then
  red with a `!` from 90%, so all three warn the same way before a limit
  hits. Cost is always shown; the docs say it is estimated at list price,
  so on a subscription it is a measure of usage, not a bill.
- **Session name**, when there is room.

On a narrow terminal it drops things, least useful first: session name,
reset countdowns, the context bar, the icons, then the directory, the
effort level and the branch. Model, profile, Remote Control, context %,
cost and the quota figures always stay. Colour is off with `NO_COLOR` set.

A profile that already has a `statusLine` of its own is left alone and
named; `--replace` takes it over after copying that `settings.json` to
`settings.json.pre-statusline-<timestamp>`. jq rewrites each file it edits
with its own formatting. Re-run the command after pulling a newer
checkout to update the installed copy, and after `add`, since a new
profile does not get it automatically. `--remove` takes the setting out of
every profile that uses it and deletes the installed script.

### `--json`

```bash
./claude-profiles.sh status --json
```

Available on both `status` and `verify`. Prints one JSON object to stdout in
place of the human-readable report, with no colour codes, and keeps the same
exit status as the plain form (so `verify --json` still exits nonzero when a
check fails). Meant for a status bar, a prompt segment, or any script that
wants to check profile health without parsing prose.

---

## How it works

Claude Code reads its credentials, settings and session data from one
directory, `~/.claude` by default. The `CLAUDE_CONFIG_DIR` environment
variable points it somewhere else. Several directories means several
independent logins that can run at the same time in different terminals.

By itself that also splits your session history across profiles, which is
not what we want. So the data directories inside each profile are symlinked
at a single shared location.

```
~/.claude              your existing setup. NEVER MODIFIED. Still works.

~/.claude-work         profile 1
  .credentials.json      real file, copied from ~/.claude (Linux) so it is
                         already logged in; on macOS the Keychain holds it
  .claude.json           real file, copied from ~/.claude.json: onboarding
                         done, project trust, user-scope MCP servers
  settings.json          real file, copied from ~/.claude at setup, plus a
                         claudeMdExcludes entry for ~/.claude/CLAUDE.md
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

A third profile, and any further one, looks exactly like profile 2 above:
its own fresh-login `.credentials.json`, its own `.claude.json`, and the same
symlinks into `~/.claude-shared`.

Launch with `claude-<name>` for each profile you set up: `claude-work` and
`claude-personal` in the easy setup, one more launcher per further name.
Bare `claude` is deliberately shadowed with an error that lists every
launcher, so you cannot drift back onto the old profile by muscle memory.
The shadow steps aside when `CLAUDE_CONFIG_DIR` is already set, which is what
makes `claude --version`, `claude mcp add` and friends keep working *inside*
a session started with `claude-work` (the session's shell inherits the
variable).

---

## The safety model

The thing most likely to go wrong here is losing the login on your main
account. The script is built around avoiding that:

1. **`~/.claude` is only ever read.** Nothing is moved, deleted, or replaced
   with a symlink inside it. If the whole setup turns out to be a mistake,
   delete the three new directories and your original profile is exactly as
   it was. The one exception is `finalize`, which exists to delete it, on
   your explicit command, after every gate below passes.
2. **A tar backup of `~/.claude` and `~/.claude.json` is taken first**, into
   `~/.claude-backups/`, before anything is created. The archive is read back
   before the script continues; if tar fails outright, nothing else happens.
   The directory is mode 700 and the archive mode 600, because the archive
   contains your credentials.
3. **You never run `/logout`.** The profile that inherited your login gets a
   copy of the existing credentials so it is already signed in. Every other,
   fresh profile does its own browser login. This matters: current Claude
   Code versions can revoke the stored refresh token when you log out, which
   would kick you out of the account you were trying to keep.
4. **`plan` is a real dry run.** It prints every command it would execute and
   changes nothing. Run it first, read it, then run `apply`.
5. **`apply` refuses to clobber.** If a path where a symlink should go already
   holds real data, it warns and skips rather than deleting. When a whole
   profile directory turns out to be real data, `apply` stops in preflight,
   before the backup and before anything is created, and tells you to re-run
   with `--adopt` (which archives that directory first and merges its data
   into the shared copy without overwriting anything) or to move the
   directory aside. See "If a profile directory already exists" below.
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
twice until `~/.claude` goes. `plan` prints the sizes. Once you have used the
new setup for a week and are happy, run `./claude-profiles.sh finalize` to
reclaim the space. Do not `rm -rf ~/.claude` by hand: see
[When you are done: finalize](#when-you-are-done-finalize) for what that
would take out with it.

---

## If a profile directory already exists

Plenty of people find this script *after* trying `CLAUDE_CONFIG_DIR` by hand.
Then `~/.claude-work` or `~/.claude-personal` is not an empty slot: it is a
complete, logged-in profile with its own `.credentials.json` and
`.claude.json`, a `projects/` tree that is part hand-copy of
`~/.claude/projects` and part sessions that exist nowhere else, its own
`history.jsonl`, `file-history/`, `skills/` and so on.

**By default `apply` refuses to run at all in that situation.** It stops in
preflight -- before the backup, before anything is created -- lists the paths
that hold real data, and exits. `plan` prints the same list as a warning and
then shows you the rest of the plan anyway, so you can see the whole picture
before deciding. Linking over that data is the one thing that would actually
lose conversations, so the refusal is deliberate and is not a bug.

You have two ways forward. Either move the directory aside yourself
(`mv ~/.claude-personal ~/.claude-personal.old`) and re-run, which gives you
a clean profile and leaves you to merge the old sessions by hand, or:

```bash
./claude-profiles.sh plan  --adopt          # read this first
./claude-profiles.sh apply --adopt
```

`--adopt` merges the existing profile into the shared copy, in this order,
per profile directory:

1. **Archives the whole directory first**, to
   `~/.claude-backups/claude-<profile>-adopted-<timestamp>.tar.gz`, with the
   same discipline as the main backup: mode 700 directory, mode 600 archive
   (it contains credentials), and a `tar tzf` read-back before anything else
   happens. If that archive cannot be written or cannot be read back, the run
   dies there and nothing is merged.
2. **Copies in only what is missing.** For each shared directory
   (`projects/`, `file-history/`, `skills/`, ...) every file that does not
   already exist at the same relative path under `~/.claude-shared/` is
   copied in with its mtime intact. A file that is already there is never
   overwritten -- the shared copy always wins -- and the run prints both
   counts, copied and skipped.
3. **Union-merges `history.jsonl`**: the lines of the shared file plus the
   lines of the profile's file, exact duplicates dropped, ordered by the
   numeric `timestamp` field (lines without one keep their relative order and
   sort first). Line counts before and after are printed.
4. **Moves the originals aside** into `~/.claude-<profile>/.adopted-<stamp>/`
   and only then creates the symlink. Nothing is deleted at any point: the
   data is in the archive *and* in `.adopted-<stamp>/`. `verify` lists those
   directories and tells you to delete them once you are happy.
5. **Leaves everything that is not shared exactly where it is.**
   `.credentials.json`, `.claude.json`, `sessions/`, `shell-snapshots/` and
   the rest are untouched, so the profile stays logged in as whichever
   account it already holds. In particular, a `~/.claude-<main>` that already
   has credentials keeps them; they are never overwritten from `~/.claude`.

`plan --adopt` computes and prints the same copy, skip and line counts by
reading, and writes nothing. The profile name is recorded as
`ADOPTED=<name>` in `~/.claude-shared/.claude-profiles.conf`, which is what
`verify` reports later.

---

## Choose your sharing mode before you run this

This is the one decision worth thinking about rather than accepting the
default.

**`--share full`** (default) shares these paths:

| Path | Effect of sharing |
|---|---|
| `projects/` | Transcripts and auto-memory. This is what makes `--resume` and `--continue` work across every account. |
| `file-history/` | Checkpoint restore works across every profile. |
| `history.jsonl` | Up-arrow prompt recall is one list. |
| `plans/`, `tasks/`, `paste-cache/`, `image-cache/`, `uploads/`, `session-env/` | A resumed session has its task list, pasted text, images and attachments intact. |
| `agent-memory/` | Subagents declared with `memory: user` keep one memory across every account. |
| `skills/`, `commands/`, `agents/`, `workflows/`, `rules/`, `output-styles/`, `plugins/` | Configure once, works in every profile. |

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
| `.claude.json` | Holds the OAuth session, per-project trust decisions, and user-scope MCP servers. Sharing it would share the login. The profile that inherited your login gets a *copy* of `~/.claude.json` so it inherits trust decisions and MCP servers; every other, fresh profile starts empty. |
| `sessions/` | One file per running session, used for live-session detection and crash cleanup. Sharing it lets one profile clean up the other's running session. |
| `backups/` | Rolling copies of that profile's own `.claude.json`. Meaningless if shared. |
| `settings.json`, `CLAUDE.md` | Copied once into each profile, then free to diverge. Your work profile may have org-specific permissions or env you do not want in personal. |

`verify` checks that `.credentials.json`, `.claude.json` and `sessions/` are
real files or directories in each profile, never symlinks, and that nothing
inside `~/.claude` points at the new directories. It also asks the binary
itself, via `claude auth status --json`, which account each launched
profile is logged into, and refuses to pass if any two profiles report the
same account.

---

## Things that will surprise you

**Trust prompts appear again in every fresh profile.** Per-project trust
lives in `.claude.json`, which is per profile. The profile that inherited
your login inherits a copy of yours, so it behaves as before. The first time
you open a given project in any other profile you get the trust dialog
again, even though the transcripts are already sitting there. Answer it once
per project, per profile.

**User-scope MCP servers do not carry over to a fresh profile.** They also
live in `.claude.json`. Add them again there with
`claude-personal mcp add --scope user` (or whichever launcher), or move the
ones you can into a project-level `.mcp.json` at the repo root, which every
profile reads.

**Settings that point back at `~/.claude` by absolute path.** A `statusLine`
command such as `~/.claude/statusline.sh`, or a hook script kept under
`~/.claude/hooks/`, would otherwise be copied into every profile's
`settings.json` *still pointing at `~/.claude`*, which only works as long as
`~/.claude` exists. `apply` fixes this itself: it copies any script that
`settings.json` points at under `~/.claude/`, `$HOME/.claude/`, or your
literal home path into `~/.claude-shared/`, then rewrites the setting in
each profile's own `settings.json` to `~/.claude-shared/<path>`. It is
idempotent and never touches `~/.claude` itself. `verify` reports anything
it could not relocate this way -- normally a script that did not exist
under `~/.claude` at apply time, or was added since. Re-run `apply` (safe
to repeat) or fix the path in `settings.json` by hand.

**`~/.claude/CLAUDE.md` would otherwise load in every project, as project
instructions.** With `CLAUDE_CONFIG_DIR` set, your user-level instructions
come from the profile's own `CLAUDE.md`. The old `~/.claude/CLAUDE.md` is
then no longer your user file, just a `.claude/CLAUDE.md` in `$HOME`, and
the memory docs say Claude Code "loads `CLAUDE.md` and `CLAUDE.local.md`
from your current working directory and every directory above it", which
includes `./.claude/CLAUDE.md`. So in any project under your home directory
the old file loads on top of the profile's copy: the same instructions
twice while the two are identical, stale ones once they drift. It also
counts as a project `CLAUDE.md`, and by default a repository's `AGENTS.md`
is only read when there is none "in your working directory or above it", so
`AGENTS.md` silently stops loading. `apply` and `add` therefore add the
absolute path to `claudeMdExcludes` in each profile's own `settings.json`
(creating the file if the profile has none; `~/.claude` itself is never
touched). A profile that already has its own `claudeMdExcludes` is not
edited: add the path to that array by hand. `verify` checks every profile
while the file exists. The entry names a path under `~/.claude` on purpose,
so it is not relocated and does not count as a reference that blocks
`finalize`; after `finalize` it matches nothing and is harmless.

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

**`cleanupPeriodDays` must match across all profiles.** The retention sweep
runs per profile but operates on the same shared `projects/` directory. If
one profile is set to 7 days and another is on the 30-day default, the
7-day profile will silently delete the other profiles' transcripts. `verify`
checks this and complains if any profile differs. Same trap applies to
`claude project purge`: run it in any profile and it wipes the shared copy.

**`add` after `finalize` seeds from the first profile, not from `~/.claude`.**
Once `~/.claude` is gone there is nothing at the old location to copy
`settings.json` and `CLAUDE.md` from, so a later
`./claude-profiles.sh add newclient` copies them from whichever profile is
listed first in `PROFILES` instead. Edit the new profile's `settings.json`
by hand afterwards if the first profile's settings do not fit the new one,
or pass `--settings newclient=PATH` on the same `add` command to do it in
one step.

**`remove` does not delete the removed profile's shared transcripts.** Only
the profile directory itself is archived and deleted; `projects/` and the
rest of `~/.claude-shared` are untouched, so a former client's sessions stay
in the shared copy and stay resumable by every remaining profile with
`--resume` or `--continue`. If that is not what you want once a client
relationship ends, either delete that project's directory under
`~/.claude-shared/projects` by hand, or use `--share safe` from the start so
transcripts were never pooled in the first place.

**Do not resume the same session from more than one profile at once.**
Different sessions in the same project directory are fine. The same
`.jsonl` open in two processes means two writers appending to one file, and
you will corrupt it. Nothing warns you.

**On macOS, credentials live in the Keychain, not in a file.** The Keychain
entry is keyed to the config directory (the authentication docs: "keys the
macOS Keychain entry to that directory too, so a session with a different
`CLAUDE_CONFIG_DIR` reads a different entry"). So the profile that inherited
your login *will* prompt for a browser login on first launch, because there
is no entry for `~/.claude-work` yet. That is fine. Log in with the *same*
account. It is a login, not a logout, and revokes nothing. The exception is
a Mac where the Keychain was locked at login time (typical over SSH): Claude
Code then falls
back to `.credentials.json` in the config dir, the script copies that file,
and no prompt appears. `verify` prints how many `Claude Code` Keychain
entries exist so you can see that each profile got its own.

---

## When you are done: finalize

Everything up to here keeps `~/.claude` as the fallback, which means the
transcripts are on disk twice. When you no longer want the duplicate:

```bash
./claude-profiles.sh finalize
```

This is the one command in the script whose purpose is to delete
`~/.claude`, and the only supported way to do it. A hand-run
`rm -rf ~/.claude` is a genuinely bad idea: it can delete the transcript of
a session that is still running, remove a `statusLine` or hook script that
every new profile still points at, or run from a terminal that *is itself* a
Claude Code session on the old profile.

`finalize` checks all of that first. Eight gates, in this order, each one a
refusal with a specific message:

1. **A recorded setup exists.** `~/.claude-shared/.claude-profiles.conf` must
   be there, and the `SOURCE` it recorded must be the directory about to be
   deleted. Without `--source` that is `~/.claude`. If the source is already
   gone it says so and stops.
2. **The target is not one of the new directories.** It refuses if the source
   resolves to any profile or the shared directory. Removing those is
   `rollback`, not `finalize`.
3. **A full `verify` passes.** The old profile is the fallback, so it only
   goes once the thing replacing it is provably healthy. Any problem `verify`
   reports stops finalize, and it prints that verify passed when it does.
4. **No `settings.json` still points into the source.** If any profile has
   a `statusLine`, hook or command under `~/.claude/`, deleting the directory
   would break it. It names the file and tells you to re-run `apply` (which
   relocates such scripts into `~/.claude-shared`) or fix the path by hand.
5. **No session is running on the old profile.** `~/.claude/sessions/` must be
   empty. If it is not, and `CLAUDE_CONFIG_DIR` is unset or points at the
   source, it says explicitly that the terminal you are running this from may
   itself be a Claude Code session on the old profile, and that finalize has
   to be run from a `claude-<profile>` session or a plain terminal after
   quitting it.
6. **The profiles hold their own credentials.** The profile that inherited
   your login must have its own `.credentials.json` (or be on macOS, where
   the Keychain holds it) and its own `.claude.json`. These are copies and
   deleting the source cannot touch them, but a missing one means the login
   you meant to keep never made
   it into the new profile and the source is still the only place it exists.
7. **A backup exists and reads back.** It takes a fresh `tar` archive of
   `~/.claude` and `~/.claude.json` and reads it back, exactly as `apply`
   does. With `--no-backup` it instead requires that
   `~/.claude-backups/.latest` names an archive that still exists and lists
   cleanly, prints when that archive was taken, and warns that anything
   written since is not in it.
8. **The summary, then the confirmation.** It prints what will be deleted and
   how large it is, which archive now holds the only copy, and which
   directories stay. Only then does it ask, and the prompt fails closed:
   without a terminal you need `--yes`.

Because the confirmation is last, **a run without `--yes` is its own dry
run**: every gate is checked and printed, and then it stops without deleting
anything. That is why `plan` has no finalize mode.

What it deletes: `~/.claude`, and `~/.claude.json` when the source is the
default `~/.claude` (its copy lives in `~/.claude-<main>/.claude.json` and in
the archive). Nothing else. It then appends `FINALIZED=<timestamp>` to the
conf file.

Afterwards `verify` keeps working and reports the source as "removed by
finalize on \<timestamp\>" rather than missing, and skips the "Source profile
untouched" section. `plan` and `apply` refuse with "source profile was
removed by finalize; nothing to seed from" instead of a confusing "does not
exist". The way back is [`ROLLBACK.md`](ROLLBACK.md) Level 3, extracting the
archive finalize took.

---

## If verify flags `.claude.json`

`verify` checks that each profile has its own `.claude.json` *after* you have
launched it once. The profile that inherited your login gets a copy at
setup, so the check that matters is on every fresh profile: if one has been
launched and still has no `.claude.json` inside it, your Claude Code version
is keeping that state at `~/.claude.json` instead, outside the config
directory. Profiles then share OAuth state and the isolation does not hold.

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

Native Windows is not supported by this script, and the shell approach alone
is not sufficient there: Claude Code keeps global state in `~/.claude.json`
outside the config directory even on Windows, so multiple simultaneous
instances sharing one real `%USERPROFILE%` step on each other regardless of
`CLAUDE_CONFIG_DIR`. You would need separate `USERPROFILE` values per
instance, which this script does not set up.

**WSL 2 is a different case.** It is a full Linux userland with its own home
directory, and by inspection this script should run there unchanged, against
a Linux `~/.claude` exactly as on native Linux. Nobody has yet run
`tests/e2e.sh` inside WSL, so treat what follows as read from the docs, not
verified.

- Claude Code installed inside WSL is an ordinary Linux install, not a
  Windows one: the native installer's "macOS, Linux, WSL" tab uses the same
  `curl -fsSL https://claude.ai/install.sh | bash`, and "you install and
  launch `claude` inside the WSL terminal, not from PowerShell or CMD."
  <https://code.claude.com/docs/en/setup#set-up-on-windows>
- Its `~/.claude` therefore lives under the WSL distribution's own
  `/home/<user>`, not under `%USERPROFILE%`. The docs' Windows-path note --
  "On Windows, `~/.claude` resolves to `%USERPROFILE%\.claude`" -- is on the
  same page but describes the native-Windows install; WSL's `~` is the Linux
  home as on any other Linux box.
  <https://code.claude.com/docs/en/claude-directory>
- Credentials are the Linux file-based kind, not the Keychain: "On Linux,
  credentials are stored in `~/.claude/.credentials.json` with file mode
  `0600`" is the line that applies inside WSL, not the Windows or macOS
  lines on the same page.
  <https://code.claude.com/docs/en/authentication#credential-management>
- Browser login under WSL2 commonly needs the terminal paste-code fallback:
  "If your browser shows a login code instead of redirecting back after you
  sign in, paste it into the terminal at the `Paste code here if prompted`
  prompt. This happens when the browser can't reach Claude Code's local
  callback server, which is common in WSL2, SSH sessions, and containers."
  <https://code.claude.com/docs/en/authentication#log-in-to-claude-code>
  The browser that opens is the Windows one, through WSL's default-browser
  interop; that is WSL behaviour rather than anything the Claude Code docs
  state.
- The Windows-native Claude Code install (`%USERPROFILE%\.claude`) is a
  wholly separate install from the one inside WSL, with its own `~/.claude`
  and its own credentials. It is **not covered** by this script. Do not mix
  the two: a `claude-work` launcher created from a WSL terminal has no
  relationship to a native `claude` run from PowerShell or CMD on the same
  machine.

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
- [Manage Claude's memory](https://code.claude.com/docs/en/memory) — CLAUDE.md is loaded from every directory above the working directory, `claudeMdExcludes` skips files by absolute path or glob, and when `AGENTS.md` is read instead of `CLAUDE.md`
- [Issue #33430](https://github.com/anthropics/claude-code/issues/33430) — `CLAUDE_CONFIG_DIR` is undocumented; track it for changes

---

## License

GPL-2.0-or-later. Copyright 2026 Gagan Deep Singh. The full licence text is in [`LICENSE`](LICENSE).
