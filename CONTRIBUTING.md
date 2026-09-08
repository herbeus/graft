# Contributing to graft

Thanks for looking. This is a small tool with a deliberately small surface, and
the fastest way to get a change merged is to know where that surface ends.

## Scope: what graft will not become

These are settled decisions, not open questions. A pull request that adds one of
them will be declined, however good the code is - please open an issue first if
you think one of them should be reconsidered, so you do not write it for
nothing.

- **No content transformation.** graft does not convert `CLAUDE.md` into
  `.cursor/rules`, does not template, does not render, does not merge Markdown.
  Generating per-tool formats is [rulesync][] and [ruler][]'s job, and they do it
  well. graft moves the *result* onto your machines. See `docs/comparison.md`.
- **No code execution.** Nothing from a context repo or a config file is ever
  run, sourced or `eval`'d. `[setup]` entries are printed as a reminder, and
  that is the whole feature. This is invariant I1 and the main reason the tool
  is auditable.
- **No network access.** No `git fetch`, no `curl`, no update check, no
  telemetry, not behind a flag.
- **No `$HOME` dotfile management.** chezmoi, yadm and stow own that problem.
- **No native Windows support**, and no support for filesystems without
  symlinks. WSL is supported because WSL has symlinks.
- **No `ask:` discovery strategy.** Typing an unfamiliar path at a prompt with
  no tab completion is the interaction this tool exists to replace. When
  discovery finds nothing, graft prints the exact `--path NAME=DIR` invocation
  to run instead.

The full contract is `docs/SPEC.md`. If a change contradicts it, change the spec
in the same PR - and say so in the description.

## Development setup

You need `bash`, `git`, [shellcheck][], [shfmt][] and [bats-core][]. There is no
build step: `bin/graft` runs straight from the checkout.

```sh
git clone https://github.com/herbeus/graft.git
cd graft
make help          # list the targets
make check         # lint + format check + tests. This is exactly what CI runs.
```

Individual targets:

```sh
make lint          # shellcheck -s bash -S style
make fmt           # shfmt -w -bn (reformat in place)
make fmt-check     # shfmt -d -bn (fail if formatting is off)
make test          # bats tests/
bats tests/apply.bats --filter 'dangling'  # one file, one test
```

The suite is `tests/apply.bats`, `tests/config.bats`, `tests/discover.bats`,
`tests/unlink.bats` and `tests/integration.bats`. The last one drives the real
`bin/graft`; the others source `lib/` directly.

`make install` links `bin/graft` into `~/.local/bin`; `make uninstall` removes
it again. Both are wrappers around `./install.sh` and `./uninstall.sh`.

## The bash 3.2 rule

**Every shell file in this repository must run on bash 3.2.57.** macOS still
ships that as `/bin/bash`, and a tool people are supposed to run after every
`git pull` cannot fail on half the laptops in a team.

Concretely, do not use:

| Forbidden | Use instead |
|---|---|
| `declare -A` / associative arrays | newline-separated TSV in a string, queried with `grep`/`cut` (see `docs/SPEC.md` section 9) |
| `mapfile` / `readarray` | `while IFS= read -r line; do ... done <<EOF` |
| `${var^^}` / `${var,,}` | `tr '[:lower:]' '[:upper:]'` |
| `&>>` and `|&` | `>>file 2>&1` |
| `[[ $x =~ re ]]` with named or nested captures | `expr`, `sed`, `case`, or `BASH_REMATCH[1..9]` only |
| `printf -v arr[0]` | plain assignment |
| `local -n` (nameref) | pass the value, or print it |

This is checked in CI, but be clear about what that check is worth. The `bash32`
job does two static things in the `bash:3.2` image and no more:

1. `bash -n` on every shell file, with real bash 3.2.57 - so a 4.x-only
   *construct* cannot get merged;
2. a `grep` for the constructs `bash -n` still accepts and 3.2 then chokes on at
   runtime (`declare -A`, `local -A`, `mapfile`, `readarray`, `local -n`,
   `${x^^}`/`${x,,}`, `&>>`).

The **suite does not run** under bash 3.2 anywhere: the `bash:3.2` image has no
git, and graft without git has nothing to do. Runtime coverage comes from the
`test` job on ubuntu and macOS, which run whatever bash the runner ships. So a
3.2 *behaviour* difference that is not one of the constructs above can still
reach `main` - if you hit one, add it to the grep pattern in
`.github/workflows/ci.yml` in the same PR.

`set -euo pipefail` is fine; `pipefail` exists in 3.2, and pitfall P8 in
`docs/pitfalls.md` is what it costs.

Other house rules that shellcheck cannot enforce for you:

- Quote every expansion. Put `--` before every path argument. Use
  `find -print0` with `read -r -d ''`.
- Ask `[ -L "$p" ]` **before** `[ -e "$p" ]`. A dangling symlink is `-L` true
  and `-e` false, and getting this backwards is pitfall P2.
- Never `ln -s` onto an existing path. Create at a temporary name and `mv -f`
  over it (pitfall P1).
- Function names carry their module prefix: `gr_` core, `cfg_` config, `disc_`
  discovery, `st_` state, `ap_` apply, `plan_` planning.
- Nothing below `bin/` prints a headline or calls `exit`.
- Comments explain *why*, not *what*. If a guard looks removable, the comment
  above it should say which bug it prevents.

Read `docs/pitfalls.md` before touching link creation, symlink classification or
anything near `rm`. Every entry there is a bug this class of tool always has,
each was reproduced before being written down, and each has a named test.

## Tests are not optional

Every behaviour change needs a test, and every bug fix needs a test that fails
before the fix.

- The suite is [bats-core][], in `tests/`.
- Every test runs in a sandbox: `HOME` and the `XDG_*` variables are redirected
  into `mktemp -d`, with `GIT_CONFIG_NOSYSTEM=1`, `TZ=UTC` and `LC_ALL=C`.
  `tests/helpers/sandbox.bash` **refuses to run** if `$HOME` is not under
  `$BATS_TMPDIR`. A tool that scans `$HOME` and creates symlinks must cage its
  own test suite; do not weaken that check to make a test easier to write.
- Name tests as behaviour, in the form used by the existing files:
  `link: repairs a dangling symlink that points into the context repo`.
- New invariant or new pitfall? Add the row to `docs/SPEC.md` or
  `docs/pitfalls.md` in the same PR as the test.

## Commits and pull requests

We use [Conventional Commits][cc]:

```
feat(discover): add origin-re strategy
fix(apply): ask -L before -e when classifying a destination
docs(readme): show a realistic second run
test(link): cover paths containing spaces
chore(ci): pin bats to v1.11.0
refactor(config): ...   perf(discover): ...   build: ...   ci: ...
```

- Scopes match the module: `core`, `config`, `discover`, `state`, `plan`,
  `apply`, `cli`, `install`, `ci`, `docs`.
- Subject line in the imperative, lower case, no trailing period, aim for 72
  characters.
- Breaking changes: `feat(config)!: ...` plus a `BREAKING CHANGE:` footer
  explaining the migration.
- The body says *why*. The diff already says what.

For the pull request itself: keep it to one topic, make sure `make check`
passes, and describe how you verified the change - "reproduced in a scratch
directory, then added test X" is the gold standard here.

## No CLA

There is none, and there will not be one. Contributions are accepted under the
MIT license of this repository; by opening a pull request you confirm you have
the right to contribute the code and are happy for it to be released under that
license. No copyright assignment, no sign-off ceremony.

## Releasing

Maintainers only. Releases are cut from `main`:

1. `make check` is green on `main`, and CI is green on Linux, macOS and bash 3.2.
2. Move the `## [Unreleased]` entries in `CHANGELOG.md` under a new
   `## [X.Y.Z] - YYYY-MM-DD` heading, and add the link reference at the bottom.
3. Bump `GRAFT_VERSION` in `bin/graft` and `VERSION` in `install.sh` and
   `uninstall.sh` to the same number.
4. Commit as `chore(release): X.Y.Z`.
5. Tag: `git tag -a vX.Y.Z -m 'graft X.Y.Z'` and push the tag.
6. Create the GitHub release, pasting the changelog section as the body. There
   is no build artefact to upload - the tarball GitHub generates is the release.
7. Smoke-test the published tag on a clean machine or container: clone, run
   `./install.sh --prefix "$(mktemp -d)"`, `graft --version`, `./uninstall.sh`.

Versioning while at `0.x`: the CLI surface may change in a minor release, but
the **exit codes** and the **`graft.conf` format** are treated as stable and get
a deprecation cycle.

[rulesync]: https://github.com/dyoshikawa/rulesync
[ruler]: https://github.com/intellectronica/ruler
[shellcheck]: https://www.shellcheck.net/
[shfmt]: https://github.com/mvdan/sh
[bats-core]: https://github.com/bats-core/bats-core
[cc]: https://www.conventionalcommits.org/en/v1.0.0/
