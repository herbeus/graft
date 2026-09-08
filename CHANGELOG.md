# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

While the major version is `0`, the command-line surface may still change
between minor versions. Two things are treated as stable from `0.1.0` on and
will not change without a deprecation notice: the **exit codes** and the
**`graft.conf` format**.

## [Unreleased]

### Added

- `graft add [<dir>]` - append a `[target]` block for a checkout, derived from
  that checkout's own origin URL, so the pattern does not have to be written by
  hand. `--as` names the target, `--verify` overrides the guessed marker file,
  `--dry-run` prints the block instead of writing it. It only ever appends to
  `graft.conf`.

## [0.1.0] - 2026-09-08

The first version.

### Added

- `graft link` - reconcile the configured links: create what is missing, repair
  what drifted, leave what is already correct untouched. Bare `graft` is the
  same command.
- `graft status` - report what is linked, drifted, conflicting or missing,
  without writing anything.
- `graft check` - validate `graft.conf` and report every problem at once, with
  line numbers, without touching the filesystem.
- `graft unlink` - remove the links graft created and move backups back.
- `graft adopt <dir> --as <target>` - take an existing directory or file into the
  context repo, the supported way out of "this path is already tracked by git".
  An **untracked** path is moved in and linked back in one step. A **tracked**
  path is *copied* in and the original is left exactly where it is, together
  with the three git commands that finish the job (commit here,
  `git rm -r --cached` there, then `graft link`): moving it would stage the
  deletion of files graft does not own, in a repo it was invited into, and no
  `unlink` could give them back. `adopt` requires the `[target]` and a matching
  `link` rule to exist already, and refuses rather than inventing a layout.
- `graft init` - write a starter `graft.conf` for the layout
  `projects/<target>/github/`, which is what the README and
  `examples/minimal/` use throughout.
- Checkout discovery by git remote URL (`origin:`, `origin-re:`), by directory
  glob (`dir:`), by explicit path (`path:`), by environment variable (`env:`),
  and derived (`parent-of:`, `target:`), with a disposable cache under
  `$XDG_CACHE_HOME/graft`.
- `graft.conf` INI format with `[defaults]`, `[target "name"]` and
  `[setup "name"]` sections, inherited `link` specs and `!dest` removals.
- Backups of pre-existing real files and directories (`timestamp`, `suffix` or
  `abort` policy, named after `backup_suffix`) - graft moves them aside, it
  never deletes them, and it prints where they went at the end of a run.
- Per-target `confirm = yes` (ask once per target before changing anything),
  `on_foreign_link = warn|abort` (report a foreign symlink and carry on, or
  refuse the whole run), `require = yes` (a missing checkout is an error, not a
  skip), and a `description` that `graft status` groups its output by.
- A managed, delimited block in `.git/info/exclude`, added through
  `git rev-parse --git-common-dir` so worktrees and submodules work, and removed
  again on `unlink`.
- Refusal to link over a path that git tracks, with no override flag
  (invariant I5) - the failure mode it prevents is a commit that deletes a
  team's CI workflows.
- `--dry-run` on every mutating command, and `--json` (JSON Lines) output for
  scripts. `--only NAME` restricts a run to one destination name, on `unlink`
  as well as on `link`.
- `graft unlink` works without a state file: it falls back to the symlinks it
  can still recognise in each resolved checkout, and says that it did.
- `GRAFT_CONFIG`, `NO_COLOR` and `CI` as environment equivalents of
  `--config`, `--no-color` and `--no-input`.
- Persistent state under `$XDG_STATE_HOME/graft`, recording every side effect on
  a foreign checkout so that `unlink` can undo it.
- `install.sh` / `uninstall.sh`: one symlink into `~/.local/bin`, no sudo, and
  an optional marked PATH block that the uninstaller removes again.
- Test suite (bats-core) that runs entirely inside a sandboxed `$HOME`, plus CI
  on Linux, macOS and bash 3.2.

[Unreleased]: https://github.com/herbeus/graft/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/herbeus/graft/releases/tag/v0.1.0
