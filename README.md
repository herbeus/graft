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
✓ 5 links are up to date, nothing to do
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

The first run for a given config shows the plan and asks once. It does not print
the list a second time afterwards - it tells you what it ended up doing:

```
$ graft link
plan
  + ~/projects/web-app/.github  (web-app)
  + ~/projects/web-app/CLAUDE.md  (web-app)
  + ~/projects/web-app/.cursor/rules  (web-app)
  + ~/work/payments-api/.github  (api)
  + ~/work/payments-api/CLAUDE.md  (api)
apply 5 change(s)? [y/N] y

  ✓ 5 links in place

next steps (graft never runs these for you)
  install the local MCP servers (asks for your personal token)
      /home/you/context/projects/setup/install-mcp.sh
```

Every run after that, in your `git pull` habit or a shell alias:

```
$ graft
✓ 5 links are up to date, nothing to do
```

One line. A tool that is chatty when nothing happened trains you to stop reading
it, and then you miss the run that mattered. That one line is reserved for the
case where there is genuinely nothing left to say: no change, no conflict, no
skipped target.

As soon as anything does need doing, you get the whole picture again - what
changed, what was already right, and what needs a decision from you:

```
$ graft
  ~ ~/projects/web-app/.github  repointed  (web-app)
  ✓ ~/projects/web-app/CLAUDE.md  (web-app)
  ✓ ~/projects/web-app/.cursor/rules  (web-app)
  ✓ ~/work/payments-api/.github  (api)
  ! ~/work/payments-api/CLAUDE.md  tracked by git, refused  (api)
      git tracks this path, so a symlink here would commit a deletion.
      move it into the context repo instead: graft adopt /home/you/work/payments-api/CLAUDE.md --as api

1 changed, 3 already correct, 1 needs attention

next steps (graft never runs these for you)
  install the local MCP servers (asks for your personal token)
      /home/you/context/projects/setup/install-mcp.sh
```

That run exits 1: the tracked destination is still unresolved. The `[setup]`
reminder comes back on every run that did something, which is the point of it.

Undo it all, on this machine, at any time:

```sh
graft unlink        # links removed, backups moved back, exclude blocks gone
```

## Configuration

`graft.conf` lives in the root of your context repo, and it is meant to be
committed: there are no machine-specific paths in it.

```ini
[defaults]
source_root = projects
search_root = ~/projects
search_root = ~/work
search_depth = 3
link = github -> .github
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

That is the layout `graft init` scaffolds, and the one `examples/minimal/` uses:

```
context/                        your context repo
  graft.conf
  projects/                     source_root
    web-app/                    source dir of target "web-app"
      github/                   -> linked into the checkout as .github
      CLAUDE.md                 -> linked into the checkout as CLAUDE.md
      cursor-rules/             -> linked into the checkout as .cursor/rules
    api/
      github/
      CLAUDE.md
    setup/install-mcp.sh
```

Reading it back:

- `source_root = projects` - the shared content lives in `projects/` next to this
  file. Each target's source directory is `projects/<target-name>`, unless the
  target sets `source`. It is the context repo's own folder of per-target
  content and has nothing to do with where your checkouts live; that is
  `search_root`.
- `link = github -> .github` in `[defaults]` - every target links its own
  `github/` subdirectory in as `.github`. The left side is relative to the
  target's source directory, the right side to the checkout root. Targets add
  their own `link` lines, and a `link = !.cursor/rules` line drops an inherited
  one. (`.` on the left is legal too and means the whole source directory - but
  then every file in it lands in `.github`, including your `CLAUDE.md`.)
- `search_root` is repeatable; so are `link`, `find` and `verify`. Every other
  key may appear at most once per section, and repeating one is an error that
  names both line numbers.
- `find = origin:*github.com/OWNER/web-app` - this is the part that makes the
  file shareable. graft matches the *git remote URL*, so your colleague who
  keeps everything in `~/src/` needs no changes. Several `find` lines are tried
  in order, first success wins.
- `verify = package.json` - a candidate without that file is not this repo.
  Cheap insurance against a fork, an archive or a half-deleted clone.
- `[setup]` entries are **printed** after a successful run. graft never runs
  them. That is not an oversight, it is the point.

Four more keys are worth knowing about, because each changes what a run does:

- `description = ...` on a target is not decoration: `graft status` groups its
  output by target and prints this line above each group.
- `confirm = yes` on a target makes graft ask before it changes anything for
  that target - once per run, not once per link. Answer no and you get
  `- <target>: skipped on request`.
- `on_foreign_link = abort` (default `warn`). A destination that is already a
  symlink pointing outside your context repo is somebody's decision. `warn`
  reports it, leaves it alone and links everything else; `abort` refuses the
  entire run so that nothing is half-applied. `--force` overrides both, and
  moves the foreign link to a backup rather than deleting it.
- `backup_suffix = .graft-backup` in `[defaults]` names every backup graft
  makes. With `backup = suffix` you get `CLAUDE.md.graft-backup`; with
  `backup = timestamp` (the default) you get
  `CLAUDE.md.graft-backup.20260828T075903Z`. `backup = abort` refuses instead of
  moving anything aside. `graft unlink` finds the backups by that same suffix,
  so change it in `[defaults]` and leave it alone afterwards.

After a run that moved something aside, graft says where it went, because the
exclude block hides backups from `git status`:

```
your content that graft moved aside
  ~/work/payments-api/CLAUDE.md.graft-backup.20260828T080137Z
  graft unlink puts these back; they are hidden from git status until then
```

`docs/SPEC.md` section 4 is the full reference. A complete, runnable example is
in [`examples/minimal/`](examples/minimal/).

## Commands

```
graft [link] [<target>...]   create and repair the configured links
graft status [<target>...]   show what is linked, drifted or missing
graft check                  validate graft.conf, touch nothing
graft unlink [<target>...]   remove our links and restore backups
graft adopt <dir> --as NAME  take an existing dir into the context repo
graft init                   write a starter graft.conf
graft help | version
```

`graft status` never writes. It groups its lines by target and puts each
target's `description` above its group, which is the one place that key earns
its keep:

```
$ graft status
context: /home/you/context
web-app - customer-facing frontend
  ✓ ~/projects/web-app/.github  (web-app)
  ✓ ~/projects/web-app/CLAUDE.md  (web-app)
  ✓ ~/projects/web-app/.cursor/rules  (web-app)
api - payments API
  ✓ ~/work/payments-api/.github  (api)
  ! ~/work/payments-api/CLAUDE.md  tracked by git, refused  (api)
      git tracks this path, so a symlink here would commit a deletion.
      move it into the context repo instead: graft adopt /home/you/work/payments-api/CLAUDE.md --as api

4 already correct, 1 needs attention
```

Useful flags: `-n/--dry-run`, `-y/--yes`, `--path NAME=DIR` (pin a checkout
graft could not find), `--rescan` (ignore the discovery cache), `--only NAME`
(one destination, by its basename - it applies to `unlink` too), `--force`
(replace foreign symlinks, never tracked files), `--json` (JSON Lines, for
scripts), `-q`, `--no-color`.

`graft unlink` is symmetrical with the rest: `--dry-run` prints
`- would remove <path>` lines and a `N links would be removed` summary without
touching anything, `--only` restricts it to one destination name, and it works
even when the state file is gone. In that case it falls back to what it can
still recognise on disk - a symlink in a resolved checkout that points into your
context repo - and says so:

```
$ graft unlink
  ✓ ~/projects/web-app/.github  link removed (no state, matched by target)
1 link removed
```

That fallback still restores a backup, but only when exactly one candidate next
to the destination carries the configured `backup_suffix`. Two candidates, or
one with a different suffix, and it removes the link and leaves them alone -
guessing there would move a stranger's directory onto a path you are still
using.

Three environment variables, all of which have a flag equivalent:

| variable | effect |
|---|---|
| `GRAFT_CONFIG` | path to `graft.conf`, same as `--config`. `-C` wins over it. |
| `NO_COLOR` | any value disables ANSI colour, same as `--no-color` |
| `CI` | any value implies `--no-input`, so a run that would need a question exits 3 instead of hanging |

Exit codes are part of the public API, so `graft status` works in a shell
condition:

| code | meaning |
|---|---|
| 0 | success, desired state reached |
| 1 | drift or conflict remains - and that includes a link that failed while being applied |
| 2 | usage error or invalid config |
| 3 | changes required but not confirmed (non-interactive without `--yes`) |
| 4 | the environment cannot support graft |
| 130 | interrupted (`Ctrl-C`) |

Exit 4 means "do not bother re-running until you have changed something outside
graft", and it has exactly four causes: a destination directory on a filesystem
that cannot hold symlinks, a destination directory graft is not allowed to write
in, an `adopt` whose copy or move failed on I/O, and a broken installation where
`bin/graft` cannot find its own `lib/`. graft probes the two filesystem cases
per directory, before it creates anything, and tells them apart on purpose -
they send you off to fix two completely different things:

```
$ graft link --yes
plan
  + ~/mnt/exfat/repo/.github  (media)
graft: the filesystem at /home/you/mnt/exfat/repo does not support symlinks
      graft needs POSIX symlinks; exFAT, some network mounts and
      Windows without Developer Mode cannot provide them
```

```
$ graft link --yes
plan
  + ~/srv/shared/repo/.github  (shared)
graft: cannot write in /home/you/srv/shared/repo
      check the directory permissions, then run graft again
```

Everything else that goes wrong on disk is drift, not environment: a link that
fails for any other reason is reported as `failed` and makes the run exit 1.

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
matching checkouts, and there is no `ask:` strategy: typing an unfamiliar path at
a prompt with no tab completion is the worst interaction in the tool this
replaces.

Several checkouts match, at a terminal, during `graft link`: a numbered list with
each candidate's origin URL and how long ago it was last committed to.

```
web-app matches more than one checkout:
  1) ~/projects/a/web-app
     https://github.com/OWNER/web-app.git, last commit 11 seconds ago
  2) ~/projects/b/web-app
     https://github.com/OWNER/web-app.git, last commit 11 seconds ago
  pick 1-2, or anything else to skip:
```

Anything that is not one of the offered numbers skips the target. The choice is
remembered in the cache, exactly as if you had passed `--path`. Only `graft link`
asks: `status` and `--dry-run` are meant to be safe to pipe, and a preview that
blocks on a question is not. Everywhere else - and in `link` under `--json`,
`--no-input`, `CI` or a pipe - you get the list and the command instead, and
exit 1:

```
  ! web-app: 2 checkouts match - graft will not pick one for you
      ~/projects/a/web-app
      ~/projects/b/web-app
      choose one: graft --path web-app=<directory>
```

Nothing matches: graft names every strategy it tried, in the order it tried
them, because a pattern that cannot match is the usual cause. Then it hands you
the command to pin the checkout, which is remembered in the cache:

```
  - gone: no checkout found
      tried: origin:*/never-here
      tried: dir:/home/you/projects/nowhere
      point at it directly: graft --path gone=<directory>
```

`graft status` is where that list always appears. `graft link` counts the target
as skipped and shows the count, but leaves the diagnosis to `status`. A target
with `require = yes` is a problem rather than a skip, and makes the run exit 1.

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

**I3 - It never deletes your data.** On any path that came from your
configuration, from discovery or from the state file, the only removal graft
performs is `rm -- "$path"` on a path it has just checked is a symlink and knows
is ours. There is no `rm -r` anywhere. An existing real file or directory at a
destination is *moved* to a backup and recorded, so `graft unlink` can move it
back. The one thing graft does delete outright is its own scratch: the probe
symlinks it creates to test a filesystem, and the temporary file every atomic
write goes through - all in a directory it is already writing to, under a name it
chose moments earlier. `SECURITY.md` lists every removal site.

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
supported route. What it does depends on whether git is tracking the thing, and
the difference matters:

**Tracked - it is copied, and your repository is not touched at all.** graft
writes a copy into the context repo, leaves the original exactly where it is,
and prints the three git commands that finish the job:

```
$ graft adopt ~/work/payments-api/CLAUDE.md --as api
plan
  copy ~/work/payments-api/CLAUDE.md
    to ~/context/projects/api/CLAUDE.md
  leave the original alone - it is tracked, so only git may remove it
adopt CLAUDE.md into target 'api'? [y/N] y
  ✓ copied into the context repo (your repo is untouched)

three steps to finish, in this order
  1. commit it here:
       git -C /home/you/context add projects/api/CLAUDE.md && git -C /home/you/context commit -m "adopt api/CLAUDE.md"
  2. stop tracking it over there - git removes it, graft never does:
       git -C /home/you/work/payments-api rm -r --cached -- CLAUDE.md
       git -C /home/you/work/payments-api commit -m "move CLAUDE.md into the shared context repo"
  3. then: graft link api
```

`git status` in the project repo is clean afterwards. This is not timidity: a
move would stage the deletion of tracked files graft does not own, in a
repository it was invited into, and no `graft unlink` could ever hand them back
- only a `git checkout` could. So graft copies, and leaves the deletion to git
and to you, as an explicit, reviewable commit. That is also why step 2 comes
after step 1: until the content is committed in the context repo, it exists in
only one place.

**Untracked - it is moved and linked back in one step**, because there is no
deletion for anyone to commit:

```
$ graft adopt ~/projects/web-app/.github --as web-app
plan
  move ~/projects/web-app/.github
    to ~/context/projects/web-app/github
  then link it back
adopt .github into target 'web-app'? [y/N] y
  ✓ moved into the context repo
  ✓ linked back: ~/projects/web-app/.github

commit it in the context repo, then your colleagues get it too:
  git -C /home/you/context add projects/web-app/github && git -C /home/you/context commit -m "adopt web-app/.github"
```

`adopt` does not invent a layout. It refuses, with exit code 2 and a copyable
snippet, unless your `graft.conf` already answers both questions:

- the `[target]` you named exists, and
- one of its `link` rules has this exact destination. That rule is what decides
  where in the context repo the content lands - `link = github -> .github` puts
  `.github` at `projects/<target>/github`, and nowhere else.

It also refuses if that source path is already occupied
(`already present in the context repo` - merging two versions is your call), if
the path is already a symlink, or if it is not inside a git checkout at all.
`--dry-run` prints the plan and stops.

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

    .ruler/*.md                         projects/web-app/github/
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

- **bash 3.2 or newer.** macOS still ships 3.2 as `/bin/bash`. CI parses every
  shell file with a real bash 3.2.57 and rejects bash 4+ syntax, and runs the
  full test suite on macOS, so a stock Mac works with nothing installed.
- **git**, any version from the last decade.
- **A filesystem with POSIX symlinks.** graft probes for symlink support once
  per directory it is about to link into, names the directory in the error, and
  exits 4 - separately from "I am not allowed to write here", which is the other
  thing that probe can discover.
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
