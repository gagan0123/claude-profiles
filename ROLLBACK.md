# Rollback

Three levels. Use the mildest one that fixes your problem.

Your original `~/.claude` was never modified by the setup script, so in every
case below it is still there and still works.

---

## Level 1: stop using the new profiles

Nothing is deleted. Takes ten seconds. Do this first if you just want to get
back to a working state and think about it later.

Remove the source line from your shell rc file:

```bash
# in ~/.zshrc or ~/.bashrc, delete this line:
. "$HOME/.claude-profiles.sh"
```

Open a new terminal. Plain `claude` now works again and uses `~/.claude`,
exactly as it did before the setup. The new directories are still on disk,
doing nothing, and you can come back to them.

(Level 2 below removes this same line for you automatically, with a backup
of the rc file taken first. Use this level only if you want to do it by hand
without running the script.)

---

## Level 2: remove what the script created

```bash
./claude-profiles.sh rollback
```

Deletes `~/.claude-work`, `~/.claude-personal`, `~/.claude-shared` and
`~/.claude-profiles.sh`, and removes the `# claude-profiles` marker and
source line it added to your shell rc file (`~/.zshrc`, `~/.bashrc`, or
`~/.bash_profile` on macOS). Prompts before doing it. Leaves `~/.claude`,
`~/.claude.json` and your backups alone.

Before it edits the rc file, it copies the untouched version to
`~/.claude-backups/<rcfile>.before-rollback-<timestamp>` and prints that
path, so you can always get the line back. If the rc file has no
claude-profiles line to remove (already removed, or an unrecognised shell),
it says so and leaves the file alone; a second rollback run is a no-op here,
not an error.

It reads the profile names you chose from
`~/.claude-shared/.claude-profiles.conf`, so non-default names need no flags.
If that file is gone, pass `--main NAME --second NAME` yourself. It refuses
to remove a directory that turns out to be the source profile.

If there is no terminal to answer the prompt (running it from Claude Code,
for instance) it stops and asks for `--yes`. It also warns if a profile's
`sessions/` directory is non-empty, which usually means a Claude Code session
is still running there. Quit it first.

On macOS the Keychain entries the two profiles created stay behind. They are
harmless; delete them in Keychain Access (search for "Claude Code") if you
want a clean slate.

**Before you run this**: any conversation that happened *only* under the new
profiles lives in `~/.claude-shared/projects/` and will be deleted. If you
want those, copy them out first:

```bash
cp -R ~/.claude-shared/projects ~/claude-sessions-keep
```

The script edits the rc file itself now (see the backup path it prints), so
there is nothing left to remove by hand afterwards. Open a new terminal and
plain `claude` works again, using `~/.claude` exactly as before the setup.

---

## Level 3: restore from the backup archive

Only needed if something modified `~/.claude` despite the design, or you want
to return to a known-good snapshot from before the setup.

Find the archive:

```bash
ls -la ~/.claude-backups/
cat ~/.claude-backups/.latest
```

Restore it. Move the current directory aside rather than deleting it, so you
can still get at anything newer. Quit every Claude Code session first, since
a running one would keep writing into the directory you are moving.

```bash
mv ~/.claude ~/.claude.broken
mv ~/.claude.json ~/.claude.json.broken 2>/dev/null

tar xzf ~/.claude-backups/claude-<timestamp>.tar.gz -C "$HOME"

ls -la ~/.claude
```

The archive holds `.claude/` and `.claude.json` as paths relative to your
home directory, so `-C "$HOME"` puts them back exactly where they were. Check
with `tar tzf <archive> | head`. If you set up with `--source DIR` pointing
somewhere other than `~/.claude`, the archive holds `DIR`'s basename
relative to its parent directory instead; extract with `-C` set to that
parent.

Then log in again if needed:

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude" claude
```

Once you have confirmed the restore is good, delete `~/.claude.broken`.

---

## If you have lost access to an account

The setup script never logs anything out, so this should not happen from
running it. If it did happen some other way, the fix is a fresh login, not a
restore:

```bash
CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude
# and follow the browser login flow
```

Do not run `/logout` first while trying to recover. On current versions that
can revoke the refresh token for the account you are leaving, which makes the
situation worse rather than better.
