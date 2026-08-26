<!-- Replace OWNER with your GitHub account or organisation before publishing. -->

# graft

**One shared directory of AI-agent context, linked into every repository you
work on - found by git remote URL, not by hardcoded path.**

[![CI](https://github.com/OWNER/graft/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/graft/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: bash 3.2+](https://img.shields.io/badge/shell-bash%203.2%2B-lightgrey.svg)](#requirements)
[![Dependencies: none](https://img.shields.io/badge/dependencies-none-brightgreen.svg)](#requirements)

```sh
graft link
```

```
  ✓ 7 links up to date, nothing to do
```

---

## Why

You have written a good set of instructions for your coding agents: house rules,
a review checklist, three skills, an `AGENTS.md`, the MCP setup. It lives in
`~/context`, and it is genuinely useful.

Now put it in the eleven repositories you work in.

You copy `.github/` into each one. Two weeks later you fix a rule in one repo
and forget the other ten. You write a `for` loop with `ln -sfn`, and it works
until a colleague clones the API repo into `~/work/` instead of `~/projects/`.
You commit the shared directory into one repo by mistake and the diff deletes
someone's CI workflow. You leave the team and there is no clean way to take your
symlinks back out again.

The awkward part is not creating a symlink. It is:

- **knowing where the checkout is.** Paths differ per person and per machine.
  A committed config full of `/home/thomas/projects/...` helps nobody.
- **not breaking the repository.** If `.github/` is already tracked by git,
  replacing it with a symlink produces a commit that deletes every file in it.
  `.git/info/exclude` provably does not save you: it does not apply to tracked
  paths.
- **getting your data back.** An existing `CLAUDE.md` must be moved aside, not
  overwritten, and it must come back when you unlink.
- **being safe to share.** A context repo travels between people. A tool that
  runs scripts out of it is a tool nobody should clone from a colleague.

graft is a single dependency-free bash program that does those four things and
nothing else.

## Quickstart

```sh
git clone https://github.com/OWNER/graft.git ~/.local/share/graft
~/.local/share/graft/install.sh          # one symlink into ~/.local/bin, no sudo

cd ~/context                             # your repo of shared agent context
graft init                               # writes a starter graft.conf
$EDITOR graft.conf                       # name your repos - see below
graft check                              # validate before touching anything
graft link
```

A first run always shows the plan and asks:

```
$ graft link
plan
  + ~/projects/web-app/.github  (web-app)
  + ~/projects/web-app/CLAUDE.md  (web-app)
  + ~/projects/web-app/.cursor/rules  (web-app)
  + ~/work/payments-api/.github  (api)
  + ~/work/payments-api/CLAUDE.md  (api)
apply 5 change(s)? [y/N] y
  + ~/projects/web-app/.github  (web-app)
  + ~/projects/web-app/CLAUDE.md  (web-app)
  + ~/projects/web-app/.cursor/rules  (web-app)
  + ~/work/payments-api/.github  (api)
  + ~/work/payments-api/CLAUDE.md  (api)

next steps (graft never runs these for you)
  install the local MCP servers (asks for your personal token)
      /home/you/context/context/setup/install-mcp.sh
```

Every run after that, in your `git pull` habit or a shell alias:

```
$ graft
  ✓ 5 links up to date, nothing to do
```

One line. A tool that is chatty when nothing happened trains you to stop reading
it, and then you miss the run that mattered.

When something has drifted, that is the only thing you hear about:

```
$ graft
  ~ ~/projects/web-app/.github  repointed  (web-app)
  ! ~/work/payments-api/CLAUDE.md  tracked by git, refused  (api)

1 did change, 3 already correct, 1 need attention
```

Undo it all, on this machine, at any time:

```sh
graft unlink        # links removed, backups moved back, exclude blocks gone
```

## Configuration

`graft.conf` lives in the root of your context repo, and it is meant to be
committed: there are no machine-specific paths in it.

```ini
[defaults]
source_root = context
search_root = ~/projects
search_depth = 3
link = . -> .github
backup = timestamp
git_exclude = yes

[target "web-app"]
description = customer-facing frontend
find = origin:*github.com/OWNER/web-app
find = dir:~/projects/web-app
verify = package.json
link = CLAUDE.md -> CLAUDE.md
link = cursor-rules -> .cursor/rules

[target "api"]
description = payments API
source = api
find = origin:*github.com/OWNER/payments-api
verify = go.mod
link = CLAUDE.md -> CLAUDE.md

[setup "mcp-servers"]
description = install the local MCP servers (asks for your personal token)
run = setup/install-mcp.sh
```

Reading it back:

- `source_root = context` - the shared content lives in `context/` next to this
  file. Each target's source directory is `context/<target-name>`, unless the
  target sets `source`.
- `link = . -> .github` in `[defaults]` - every target links its whole source
  directory in as `.github`. The left side is relative to the source directory,
  the right side to the checkout root; `.` means the whole directory. Targets
  add their own `link` lines, and a `link = !.cursor/rules` line drops an
  inherited one.
- `find = origin:*github.com/OWNER/web-app` - this is the part that makes the
  file shareable. graft matches the *git remote URL*, so your colleague who
  keeps everything in `~/src/` needs no changes. Several `find` lines are tried
  in order, first success wins.
- `verify = package.json` - a candidate without that file is not this repo.
  Cheap insurance against a fork, an archive or a half-deleted clone.
- `[setup]` entries are **printed** after a successful run. graft never runs
  them. That is not an oversight, it is the point.

`docs/SPEC.md` section 4 is the full reference. A complete, runnable example is
in [`examples/minimal/`](examples/minimal/).

## Commands

```
graft [link] [<target>...]   create and repair the configured links
graft status [<target>...]   show what is linked, drifted or missing
graft check                  validate graft.conf, touch nothing
graft unlink [<target>...]   remove our links and restore backups
graft adopt <dir> --as NAME  move an existing dir into the context repo
graft init                   write a starter graft.conf
graft help | version
```

Useful flags: `-n/--dry-run`, `-y/--yes`, `--path NAME=DIR` (pin a checkout
graft could not find), `--rescan` (ignore the discovery cache), `--only NAME`
(one destination), `--json` (JSON Lines, for scripts), `-q`, `--no-color`.

Exit codes are part of the public API, so `graft status` works in a shell
condition:

| code | meaning |
|---|---|
| 0 | success, desired state reached |
| 1 | drift or conflict remains |
| 2 | usage error or invalid config |
| 3 | changes required but not confirmed (non-interactive without `--yes`) |
| 4 | environment cannot support graft (no symlinks) |

## How discovery works

Once per run, graft walks your `search_root`s to `search_depth`, pruning
`node_modules` and friends and every dotdir except `.git`, and builds one index
of `path | origin URL | last commit date`. That index is cached under
`$XDG_CACHE_HOME/graft/` and is entirely disposable - delete it whenever
discovery looks wrong.

Each target then resolves against that index with its `find` strategies, in
order, first success wins:

| strategy | argument | example |
|---|---|---|
| `origin` | glob against the remote URL | `origin:*github.com/OWNER/web-app` |
| `origin-re` | POSIX regex, for what globs cannot say | `origin-re:.*/(web\|www)-app$` |
| `dir` | glob against directory paths | `dir:~/projects/web-app` |
| `path` | an explicit path, no search | `path:${WORK}/api` |
| `env` | an environment variable holding a path | `env:API_CHECKOUT` |
| `parent-of` | the dirname of another strategy's result | `parent-of:target:web-app` |
| `target` | wherever another target resolved to | `target:web-app` |

Then every `verify` path of the target must exist in the candidate, or it is
rejected.

Two things graft will not do here. It never **auto-picks** between several
matching checkouts - interactively it lists them with their origin URL and last
commit date and asks; non-interactively it skips and exits 1. And there is no
`ask:` strategy: typing an unfamiliar path at a prompt with no tab completion is
the worst interaction in the tool this replaces. When nothing matches, graft
says so and hands you the exact command to pin it instead of prompting:
`graft --path api=/path/to/checkout`, which is remembered in the cache.

## What graft never does

These are invariants, not settings. There is no flag for any of them, and a
change that breaks one is a bug, not a feature request.

**I1 - It never executes anything from your context repo or config.** No `eval`,
no `source`, no `sh -c` on a config-derived string. `[setup]` entries are
printed for you to read and run yourself. This is what makes a context repo safe
to clone from a colleague: the worst a hostile `graft.conf` can do is make graft
create or refuse a symlink.

**I2 - It never touches the network.** No `git fetch`, no `curl`, no update
check, no telemetry. It behaves identically on an air-gapped machine.

**I3 - It never deletes your data.** The single removal site in the entire
codebase is `rm -- "$path"`, guarded by a check that the path is a symlink.
There is no `rm -r` anywhere. An existing real file or directory at a
destination is *moved* to a backup and recorded, so `graft unlink` can move it
back.

**I4 - It cannot escape the two directories it works in.** Every link source
must resolve inside the context repo, every destination inside its checkout, and
resolution happens *before* the check, so a symlink cannot be used to break out.
On top of that, a destination may never be `.git`, `.ssh`, `.gnupg`, `.aws`,
`.config/gh`, `.netrc` or your shell rc files.

**I5 - It never writes over a file that git tracks.** If the destination is
tracked, graft refuses and tells you. There is no `--force` for this, because
the failure it prevents is a commit that silently deletes a team's CI workflows.
`--force` exists, but it only relaxes the *foreign symlink* case.

Two more you will feel rather than read about: every mutating command builds a
complete plan and validates it before touching anything (`--dry-run` prints that
plan), and running any command twice produces the same state, the same exit
code, no second backup and no duplicated lines in any file.

There is a nice consequence of I5 that is worth stating out loud, because it is
the tool refusing to do the thing it exists for:

> **graft cannot graft its own repository.** This project has real, tracked
> workflows in `.github/`, so `graft link` refuses that destination and says so.
> Everyone who builds a tool like this eventually points it at itself, gets a
> commit that deletes their CI, and learns why. graft just says no instead.

If you genuinely want a tracked directory to become a link, `graft adopt` is the
supported route: it moves the real directory into the context repo, then links
it back, so the deletion is an explicit, reviewable commit that you make on
purpose.

## Do you even need this?

Very often: no. Be honest about your situation first.

**If you are one person with three checkouts that all live in `~/projects/`,
you do not need graft.** You need ten lines of Makefile, and here they are:

```make
CONTEXT := $(HOME)/context
REPOS   := $(HOME)/projects/web-app $(HOME)/projects/api $(HOME)/projects/docs

.PHONY: link
link:
	@for r in $(REPOS); do \
	  n=$$(basename $$r); \
	  ln -sfn $(CONTEXT)/$$n $$r/.github; \
	  grep -qxF .github $$r/.git/info/exclude 2>/dev/null \
	    || echo .github >> $$r/.git/info/exclude; \
	  echo "linked $$r/.github"; \
	done
```

That is a real, working solution. `ln -sfn` even avoids the classic bug where
`ln -s` onto an existing directory symlink puts the link *inside* the directory.
Use it. GNU Stow does the same job with fewer of your own bugs
(`stow -d ~/context -t ~/projects/web-app web-app`), and `docs/comparison.md`
compares both properly.

Here is where those ten lines start to hurt, in the order it usually happens:

1. **More than about five repositories.** `REPOS` becomes a list you maintain by
   hand and forget to update. Discovery by remote URL removes the list.
2. **More than one person.** The moment you want to *commit* the configuration
   so a colleague can use it, absolute paths are wrong. `~/projects/api` on your
   machine is `~/src/work/api` on theirs. This is the single biggest reason the
   Makefile stops scaling: it cannot be shared.
3. **More than one machine.** Same problem as more than one person, plus a
   laptop where the API repo genuinely is somewhere else.
4. **More than one agent tool.** One `.github` link becomes `.github` plus
   `CLAUDE.md` plus `.cursor/rules` plus `AGENTS.md`, per repo, with different
   subsets per repo. The `for` loop grows a `case`.
5. **The first time it eats something.** `ln -sfn` happily replaces a symlink
   that pointed somewhere you cared about, and it will fail confusingly on a
   real directory. There is no backup and no undo. When a repository already
   tracks `.github/`, the loop above creates a diff that deletes it and you find
   out in code review, if you are lucky.
6. **When you want it gone.** Uninstalling the Makefile approach means
   remembering every path you ever ran it against. `graft unlink` reads its own
   state file, verifies each path against the filesystem, restores your backups
   and removes the exclude blocks it wrote.

If none of 1-6 apply to you, close this tab and write the Makefile. That is a
sincere recommendation, and it is why `docs/comparison.md` exists.

## Works with AGENTS.md, rulesync and ruler

graft does not compete with the tools that generate agent config formats. It is
the other axis.

```
    rulesync / ruler                    graft
    one repo, many formats              one context, many checkouts

    .ruler/*.md                         context/web-app/
        |                                   |
        v  ruler apply                      v  graft link
    .github/copilot-instructions.md     ~/projects/web-app/.github
    .cursor/rules/                      ~/work/api/.github
    CLAUDE.md                           ~/src/docs-site/.github
```

[rulesync][] and [ruler][] take one canonical set of rules and emit the
per-agent files - Copilot, Cursor, Claude, Gemini and the rest - *inside one
repository*. graft takes a directory and puts it into *many checkouts on many
machines*. The pipeline that uses both is the obvious one: run `ruler apply` or
`rulesync generate` inside your context repo, commit the generated tree, then
`graft link` distributes it.

graft has no templating, no format conversion and no `--generate` flag, and it
never will. That is a scope decision, written down in `docs/SPEC.md` section 0,
so there is nothing to disagree about at the seam.

[AGENTS.md][] needs no generator at all - it is one file, and graft is happy to
be the thing that puts it, and its aliases, in every checkout:

```ini
link = AGENTS.md -> AGENTS.md
link = AGENTS.md -> CLAUDE.md
```

## Requirements

- **bash 3.2 or newer.** macOS still ships 3.2 as `/bin/bash`, and CI tests
  against it in a container, so a stock Mac works with nothing installed.
- **git**, any version from the last decade.
- **A filesystem with POSIX symlinks.** graft probes for symlink support once
  per checkout and exits 4 with a diagnosis if it is missing.
- Standard POSIX tools: `find`, `awk`, `sed`, `grep`, `cut`, `cksum`.
- **Linux, macOS or WSL.** Native Windows is not supported and is not planned:
  the whole tool is symlinks, and that story is different enough on Windows that
  pretending otherwise would help nobody. Under WSL it works normally - just
  keep your checkouts on the Linux filesystem, not under `/mnt/c`.

No runtime, no package manager, no daemon, nothing to compile, nothing
downloaded at runtime.

Install is one symlink:

```sh
./install.sh                      # ~/.local/bin/graft -> this checkout's bin/graft
./install.sh --prefix ~/bin       # somewhere else
./install.sh --modify-path        # also add a marked PATH block to your rc file
./uninstall.sh                    # removes the link and that block, nothing else
```

It is a symlink rather than a copy on purpose: `git pull` in the checkout
updates the CLI you are running. `install.sh` never uses `sudo` and never
edits a shell rc file unless you pass `--modify-path`, and then only as a block
between `# >>> graft >>>` and `# <<< graft <<<` that `uninstall.sh` removes
again, byte for byte.

## Contributing

Bug reports, and pull requests that stay inside the scope, are welcome. Read
[CONTRIBUTING.md](CONTRIBUTING.md) first - especially the list of things graft
will never do, and the bash 3.2 rule.

```sh
make check      # shellcheck + shfmt + the bats suite: exactly what CI runs
```

The internal contract is [`docs/SPEC.md`](docs/SPEC.md), the bugs this class of
tool always has are catalogued in [`docs/pitfalls.md`](docs/pitfalls.md), and
the security model is in [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).

[rulesync]: https://github.com/dyoshikawa/rulesync
[ruler]: https://github.com/intellectronica/ruler
[AGENTS.md]: https://agents.md
