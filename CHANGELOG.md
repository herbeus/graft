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

- `graft link` - reconcile the configured links: create what is missing, repair
  what drifted, leave what is already correct untouched. Bare `graft` is the
  same command.
- `graft status` - report what is linked, drifted, conflicting or missing,
  without writing anything.
- `graft check` - validate `graft.conf` and report every problem at once, with
  line numbers, without touching the filesystem.
- `graft unlink` - remove the links graft created and move backups back.
- `graft adopt <dir> --as <target>` - move an existing directory into the
  context repo and link it back into place, the supported way out of "this path
  is already tracked by git".
- `graft init` - write a starter `graft.conf`.
- Checkout discovery by git remote URL (`origin:`, `origin-re:`), by directory
  glob (`dir:`), by explicit path (`path:`), by environment variable (`env:`),
  and derived (`parent-of:`, `target:`), with a disposable cache under
  `$XDG_CACHE_HOME/graft`.
- `graft.conf` INI format with `[defaults]`, `[target "name"]` and
  `[setup "name"]` sections, inherited `link` specs and `!dest` removals.
- Backups of pre-existing real files and directories (`timestamp`, `suffix` or
  `abort` policy) - graft moves them aside, it never deletes them.
- A managed, delimited block in `.git/info/exclude`, added through
  `git rev-parse --git-common-dir` so worktrees and submodules work, and removed
  again on `unlink`.
- Refusal to link over a path that git tracks, with no override flag
  (invariant I5) - the failure mode it prevents is a commit that deletes a
  team's CI workflows.
- `--dry-run` on every mutating command, and `--json` (JSON Lines) output for
  scripts.
- Persistent state under `$XDG_STATE_HOME/graft`, recording every side effect on
  a foreign checkout so that `unlink` can undo it.
- `install.sh` / `uninstall.sh`: one symlink into `~/.local/bin`, no sudo, and
  an optional marked PATH block that the uninstaller removes again.
- Test suite (bats-core) that runs entirely inside a sandboxed `$HOME`, plus CI
  on Linux, macOS and bash 3.2.

[Unreleased]: https://github.com/OWNER/graft/commits/main
