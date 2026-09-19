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

---

## Level 2: remove what the script created

```bash
./claude-profiles.sh rollback
```

Deletes `~/.claude-work`, `~/.claude-personal`, `~/.claude-shared` and
`~/.claude-profiles.sh`. Prompts before doing it. Leaves `~/.claude`,
`~/.claude.json` and your backups alone.

Use `--main NAME --second NAME` if you set up under non-default names, or it
will not find the right directories.

**Before you run this**: any conversation that happened *only* under the new
profiles lives in `~/.claude-shared/projects/` and will be deleted. If you
want those, copy them out first:

```bash
cp -R ~/.claude-shared/projects ~/claude-sessions-keep
```

Afterwards, remove the source line from your shell rc file by hand. The script
does not edit your rc file on the way out.

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
can still get at anything newer:

```bash
mv ~/.claude ~/.claude.broken
mv ~/.claude.json ~/.claude.json.broken 2>/dev/null

tar xzf ~/.claude-backups/claude-<timestamp>.tar.gz -C "$HOME"

ls -la ~/.claude
```

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
