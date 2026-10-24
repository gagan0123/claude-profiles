# Rollback

Three levels. Use the mildest one that fixes your problem.

Your original `~/.claude` was never modified by the setup script, so in every
case below it is still there and still works.

**Unless you have run `finalize`.** That command deletes `~/.claude` on
purpose, and after it Levels 1 and 2 no longer give you the old profile back
because there is nothing left to fall back to. Level 3 is then the only way
back, and the archive to use is the one `finalize` took immediately before
deleting: `cat ~/.claude-backups/.latest` names it.

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

Deletes every `~/.claude-<name>` directory in the conf's `PROFILES` list,
plus `~/.claude-shared` and `~/.claude-profiles.sh`, and removes the
`# claude-profiles` marker and source line it added to your shell rc file
(`~/.zshrc`, `~/.bashrc`, or `~/.bash_profile` on macOS). Prompts before
doing it. Leaves `~/.claude`, `~/.claude.json` and your backups alone.

Before it edits the rc file, it copies the untouched version to
`~/.claude-backups/<rcfile>.before-rollback-<timestamp>` and prints that
path, so you can always get the line back. If the rc file has no
claude-profiles line to remove (already removed, or an unrecognised shell),
it says so and leaves the file alone; a second rollback run is a no-op here,
not an error.

It reads the profile names you chose from
`~/.claude-shared/.claude-profiles.conf`, so non-default names need no flags.
If that file is gone, pass `--profiles NAME,NAME,...` yourself. It refuses
to remove a directory that turns out to be the source profile.

If there is no terminal to answer the prompt (running it from Claude Code,
for instance) it stops and asks for `--yes`. It also warns if a profile's
`sessions/` directory is non-empty, which usually means a Claude Code session
is still running there. Quit it first.

On macOS the Keychain entries the profiles created stay behind. They are
harmless; delete them in Keychain Access (search for "Claude Code") if you
want a clean slate.

**If you ran `apply --adopt`**, rollback deletes the adopted profile
directory too, including the `.adopted-<timestamp>/` copies of the data that
was merged out of it. The way back to the profile exactly as it was before
adoption is the archive taken at the start of the adopt run:

```bash
ls -la ~/.claude-backups/claude-*-adopted-*.tar.gz
tar xzf ~/.claude-backups/claude-personal-adopted-<timestamp>.tar.gz -C "$HOME"
```

It holds the whole directory (credentials, `.claude.json`, transcripts and
all) as a path relative to your home directory, so `-C "$HOME"` puts it back
where it was. Move anything currently at that path aside first. Extract it
*before* rollback if you want to keep working with those sessions, or
afterwards to recover them.

**If `CLAUDE.md` is shared** (`CLAUDE_MD=shared` in the conf, or
`CLAUDE.md: shared` in `status`), the one real copy is
`~/.claude-shared/CLAUDE.md` and goes with that directory; the profiles'
entries are only links to it and rollback does not follow them. `~/.claude`
still has the file it was copied from. If the profiles ever had copies of
their own, those are in `~/.claude-backups/claude-md-<timestamp>.tar.gz`
(see "Undoing `claude-md shared`" below).

**In the hub layout** (README, "Hub layout") `~/.claude-shared` holds only
links into `~/.claude` (plus, with `CLAUDE_MD=shared`, the real
`CLAUDE.md` copy), so rollback removes the links and the shared data
stays in `~/.claude`. Shared paths that `apply` created there empty stay too.
If `~/.claude-shared` is itself one link to `~/.claude`, rollback refuses,
because it resolves to the source; remove that link yourself with
`rm ~/.claude-shared` (no `-r`, no trailing slash) and re-run rollback with
`--profiles NAME,NAME,...`, since the conf file it read lived in `~/.claude`
through that link and is no longer found.

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

## Undoing `statusline`

```bash
./claude-profiles.sh statusline --remove
```

Removes `statusLine` from every profile's `settings.json` that points at
`~/.claude-shared/claude-profiles-statusline.sh` and deletes that script.
Profiles on a status line of their own are left alone. If `--replace` took
one over, the previous `settings.json` is still at
`settings.json.pre-statusline-<timestamp>` next to it; copy its
`statusLine` back by hand if you want it. Level 2 needs none of this: it
deletes `~/.claude-shared` and the profiles, status line included.

---

## Undoing `claude-md shared`

`claude-md shared` archives every profile's real `CLAUDE.md` before
replacing it with a link, to
`~/.claude-backups/claude-md-<timestamp>.tar.gz`, as paths relative to your
home directory (`.claude-work/CLAUDE.md`, `.claude-personal/CLAUDE.md`,
...). Only profiles that still had a real copy are in it; one that was
already a link was skipped and is not.

The mild way back is the command's own opposite:

```bash
./claude-profiles.sh claude-md copied
```

That replaces each link with a copy of the *shared* text, which is the
promoted copy, not what each profile had before. If the copies differed and
you want each profile's own text back, extract the archive instead. Quit
every Claude Code session first:

```bash
ls -la ~/.claude-backups/claude-md-*.tar.gz
tar tzf ~/.claude-backups/claude-md-<timestamp>.tar.gz        # see what is in it
./claude-profiles.sh claude-md copied --yes                     # links become copies, conf says copied
tar xzf ~/.claude-backups/claude-md-<timestamp>.tar.gz -C "$HOME"   # the old texts over those copies
./claude-profiles.sh verify
```

Run `claude-md copied` *before* the `tar xzf`: extracting straight over a
symlink would write through the link into `~/.claude-shared/CLAUDE.md`
rather than replace the link, and the conf would still say `shared`. To
restore just one profile's text, add its path to the `tar xzf` line, for
example `.claude-work/CLAUDE.md`. `~/.claude-shared/CLAUDE.md` is left
behind in either case and is harmless; delete it by hand if you want.
`~/.claude` was not involved at any point.

---

## Undoing `remove`

`remove` archives the whole profile directory before deleting it, to
`~/.claude-backups/claude-<name>-removed-<timestamp>.tar.gz`.

**`add` is not the way back.** Running `./claude-profiles.sh add <name>`
again creates a *fresh* profile with a fresh browser login; it does not know
about the archive and will not restore the old credentials, trust decisions
or anything else that lived in the removed directory.

Instead, extract the archive and re-merge the profile:

```bash
ls -la ~/.claude-backups/claude-<name>-removed-*.tar.gz
tar xzf ~/.claude-backups/claude-<name>-removed-<timestamp>.tar.gz -C "$HOME"
```

That puts `~/.claude-<name>` back exactly as it was at removal, as a path
relative to your home directory. From there, two options:

- If the shared copy in `~/.claude-shared` already has everything this
  profile ever wrote (the common case, since `remove` never touches shared
  data -- see the README's "Things that will surprise you"), simply add the
  name back to the conf and re-run `apply` with the full profile list
  including it, so it is re-linked and the launcher snippet regenerated:

  ```bash
  ./claude-profiles.sh apply --profiles work,personal,<name> --yes
  ```

- If you are not sure, or the directory held data that never made it into
  the shared copy, run it through `--adopt` instead so anything missing is
  merged in rather than assumed to already be there:

  ```bash
  ./claude-profiles.sh plan  --adopt --profiles work,personal,<name>
  ./claude-profiles.sh apply --adopt --profiles work,personal,<name> --yes
  ```

Either way the extracted directory's own `.credentials.json` and
`.claude.json` are left alone, so the restored profile keeps whichever
account it was logged into before it was removed.

---

## Level 3: restore from the backup archive

Only needed if something modified `~/.claude` despite the design, you want to
return to a known-good snapshot from before the setup, or you ran `finalize`
and want the old profile back.

**After `finalize`, this is the only level that does anything**, and the
archive to use is the one finalize took as its seventh gate, immediately
before deleting: it is the newest one, and `~/.claude-backups/.latest` names
it. `verify` and the conf file's `FINALIZED=` line tell you when that was.
Note that `finalize` also deleted `~/.claude.json`; the archive holds it too,
so the `tar xzf` below restores both.

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

After `finalize` there is nothing to move aside, so skip the two `mv` lines
and go straight to `tar xzf`.

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
