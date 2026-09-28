# AGENTS.md

Guidance for any agent (or person) changing this repository. It is short on
purpose; the safety model in `README.md` is the actual specification.

Two different audiences use this repo, and they need different files:

- **Someone running the setup on their machine** pastes
  `INSTRUCTIONS-FOR-CLAUDE.md` into Claude Code. That file is a procedure for
  an *operator* agent and must stay self-contained. Do not put development
  notes in it.
- **Someone changing the script or docs** reads this file.

## What the script must never do

These are the invariants every change is measured against. Breaking one is a
bug even if every test passes.

1. **`~/.claude` (the `--source` profile) is read-only.** No writes, no
   deletes, no symlinks created inside it, no `mv`. The only allowed
   operations on it are `cp` *from* it, `tar` *of* it, and `du`/`ls`/`test`.
   `tests/e2e.sh` fingerprints the source tree before and after every command
   and fails if a byte, mode or mtime moved. Keep it that way.
   **The single sanctioned exception is the `finalize` command**, which
   deletes the source outright (and `~/.claude.json` when the source is the
   default) and is never reached from `plan`, `apply`, `verify` or
   `rollback`; it may only do so after eight ordered gates, each a `die`:
   the conf file records this exact source and it is still a directory; the
   source is not `MAIN_DIR`, `SECOND_DIR` or `SHARED`; a full `do_verify`
   returns clean; neither profile's `settings.json` still references paths
   under the source; `${SOURCE}/sessions` is empty (and it says so when the
   caller's own terminal may be that session); the first profile has its own
   `.credentials.json` (or macOS) and `.claude.json`; a fresh backup was
   taken and read back, or `--no-backup` found a `.latest` archive that
   lists cleanly; and a confirmation, last so that a run without `--yes` is
   its own dry run, after a summary of what goes and what stays. It then
   records `FINALIZED=<stamp>` in the conf file, which is what lets `verify`
   keep passing and what makes `plan`/`apply` refuse with a specific
   message. Adding a ninth gate is fine; removing one is a bug.
2. **`.credentials.json`, `.claude.json` and `sessions/` are per-profile real
   files, never symlinks, never shared.** The `PRIVATE` list in the script
   and the "Credential isolation" section of `verify` enforce this.
3. **Nothing logs anyone out.** The script never runs `claude`, never runs
   `/logout`, never deletes or rewrites a credentials file it did not just
   create by copying. The docs say `/logout` can revoke the refresh token;
   treat that as true.
4. **`plan` changes nothing.** Every filesystem write goes through `run`, or
   is explicitly branched on `DRY`. A new write that bypasses both is a bug.
5. **`apply` must be idempotent and interruptible.** Re-running must skip
   what exists; an interrupted copy must not look finished (that is why
   shared paths are copied to `.<name>.partial` and renamed). `--adopt` is
   the only path that changes a profile directory that existed before the
   run, and it always archives that whole directory to `~/.claude-backups`
   (written and read back) before it merges or moves anything, never
   overwrites a file already in the shared copy, and moves originals into
   `.adopted-<stamp>/` rather than deleting them.
6. **Prompts fail closed.** If there is no terminal, `confirm` returns false
   and says to pass `--yes`. Never fall back to "assume yes".
7. **The backup is taken and read back before anything else is created**,
   and lives in a mode-700 directory as a mode-600 file, because it contains
   credentials.

## Portability rules (the script runs on macOS and Linux)

The script targets **bash 3.2**, because that is what `/bin/bash` is on
macOS, and the **BSD userland**, because that is what macOS ships. Concretely:

- No arrays, no `[[ ]]`, no `${var,,}`, no `mapfile`, no `declare -A`, no
  `printf -v`, no `read -d`, no `+=` on strings you rely on. The profile
  list itself is carried as a single space-separated string (`PROFILES`),
  never an array, for the same reason: bash 3.2 has no arrays.
- `readlink` **without** `-f`. `realpath` does not exist on older macOS.
  Use `cd dir && pwd -P` to canonicalise.
- `stat` flags differ completely between GNU and BSD. The script does not
  use `stat` at all; `tests/e2e.sh` wraps it in `fmode`/`fmtime`.
- `du -sk`, `df -Pk`, `cp -Rp`, `tar czf`/`tzf`, `grep -qF`, `sed -n 's///p'`
  with basic regex, `awk` with `-v`, `cut -f`, `tr`, `wc -w | tr -d ' '`
  (BSD `wc` pads with spaces) are the agreed subset. Nothing else without
  checking the BSD man page.
- `tar` positional `-C` works in both GNU tar and bsdtar; that is how the
  backup adds `.claude.json` from a different directory.
- `date +%Y%m%d-%H%M%S` only. No `date -d`, no `date -r`.
- `ls --time-style`, `md5sum`, `timeout`, `mktemp --suffix` and `sed -i`
  without a suffix argument are all GNU-only. Do not add them.
- Shell rc detection is by `$SHELL` basename: zsh gets `.zshrc`, bash gets
  `.bash_profile` on macOS and `.bashrc` on Linux. Anything else gets a
  printed line to add by hand.
- The launcher snippet is sourced by **both bash and zsh**. Function names
  with hyphens (`claude-work`) are fine in both; keep the body POSIX-ish.

Run `shellcheck -s bash` on both scripts before committing. The
`# shellcheck disable=` comments in `claude-profiles.sh` cover literal
strings that must contain `~` and `$HOME` unexpanded, and awk programs held
in variables; do not add more without a comment saying why.

## How to test

```bash
tests/e2e.sh
```

It builds a fake `$HOME` under `$TMPDIR`, seeds a fake `~/.claude`, and runs
`plan`, an `apply` without a TTY (must abort), `apply --yes --shell`, the
launcher functions against a stub `claude` binary, a second `apply`,
`verify` in clean and deliberately broken states, bad-input rejection,
`rollback`, an `--adopt` run against a pre-existing fresh profile (refusal
without the flag, archive, no-overwrite merge, history union, `.adopted-*`),
a `--share safe` setup with custom names, a three-profile setup, a level-3
restore from the backup archive, and `finalize` (each gate's refusal, then
the real deletion and the state it leaves behind). It also covers `add`
(fresh profile creation, refusal on a name already in `PROFILES`, refusal
on a directory that already holds real data, conf and launcher snippet
updated) and `remove` (archive-then-delete, refusal on an unknown name, on
a non-empty `sessions/`, and on the last remaining profile, the warning on
removing the first profile, shared data left untouched), `--settings
NAME=PATH` on `plan`, `apply` and `add` (full-replacement copy, ignored
when the profile already has a `settings.json`), and the `status` and
`--json` output of both `status` and `verify` (shape of the JSON object,
same exit status as the plain form), and the `claudeMdExcludes` entry for
`~/.claude/CLAUDE.md` (added once, not relocated, not a `finalize` gate 4
reference, never merged into an existing array, flagged by `verify` when
missing). It never reads or writes the real
`~/.claude`.

Every behavioural change to the script needs a check in that file. If you
fix a bug, add the case that would have caught it first.

There is no CI. Run the test on both platforms if you can; at minimum run it
on the one you are on and say in the commit body which one that was.

## Facts the design depends on (verified 2026-09-20 against the docs)

Re-verify these when a change touches them, and update the README references
if the docs move.

- With `CLAUDE_CONFIG_DIR` set, *every* `~/.claude` path, including
  `.claude.json`, lives under that directory.
  <https://code.claude.com/docs/en/claude-directory>
- With `CLAUDE_CONFIG_DIR` set, `.credentials.json` lives there too, and on
  macOS the Keychain entry is keyed to that directory, so each profile gets
  its own login. On a Mac where the Keychain is locked (SSH), Claude Code
  falls back to the file.
  <https://code.claude.com/docs/en/authentication#credential-management>
- `cleanupPeriodDays` sweeps `projects/`, `file-history/`, `plans/`,
  `paste-cache/`, `image-cache/`, `uploads/`, `session-env/`, `tasks/`, so
  every profile must agree on it. `todos/` is legacy and not written.
- `/logout` "removes and revokes the credential", which is why the setup
  never asks anyone to log out.
- `CLAUDE.md` and `.claude/CLAUDE.md` load from the working directory and
  every directory above it, so with `CLAUDE_CONFIG_DIR` set,
  `~/.claude/CLAUDE.md` loads as a project file in every project under
  `$HOME` and, counting as a project `CLAUDE.md`, stops `AGENTS.md` from
  loading. `claudeMdExcludes` matches absolute paths and merges across
  settings layers; that is why every profile's `settings.json` carries the
  path (`ANCESTOR_MD`). Verified 2026-09-28 on Claude Code 2.1.283.
  <https://code.claude.com/docs/en/memory>

## Docs conventions

- `README.md` explains the design and the traps. `ROLLBACK.md` is the undo
  procedure. `INSTRUCTIONS-FOR-CLAUDE.md` is the operator script. A change
  to script behaviour usually touches all three; check each.
- Quote the docs when a claim rests on them, and link the page. Prefer "the
  docs say X" over "X is true".
- No emojis. No "generated by" lines. The history reads as the author's work.

## Commits

Conventional Commits with a body, always:

```
type(scope): imperative subject

Why the change was needed, what was decided, what was rejected. Say which
platform the tests ran on.
```

Types used here: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`. No
`Co-Authored-By` lines and no tool or model attribution anywhere in the
message, the PR, or the changelog. Write the message to a file under `.tmp/`
(gitignored) and commit with `git commit -F`, so multi-line bodies survive
terminals that mangle pasted heredocs.

**Releases:** bump `VERSION` in the script, commit
`chore: release vX.Y.Z`, tag `vX.Y.Z`, then `gh release create` with the
changelog since the previous tag. The tag and the `VERSION` string must
match -- that is what lets `verify` report the script's own version
correctly.
