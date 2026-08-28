# graft and the tools it is not

The problem graft solves - *one directory of shared agent context, linked into
many project checkouts that live at different paths on different machines* - sits
between three well-populated categories: dotfile managers, git's own vendoring
mechanisms, and the new generation of AI-rules generators. Most of the time one
of those is the better answer. This page tries to say honestly when.

If you disagree with an assessment here, please open an issue. Several of these
tools move fast, and a comparison page that quietly rots is worse than none.

## At a glance

| Tool | What it actually does | Finds the destination for you | Refuses to clobber tracked files | Reversible | Executes code from its config |
|---|---|---|---|---|---|
| **graft** | symlinks a context repo into N project checkouts | yes, by git remote URL | yes, no override | `graft unlink` restores backups | never |
| **GNU Stow** | symlink farm from a package dir into one target dir | no, `-t` is yours to supply | no | `stow -D` | no |
| **dotbot** | YAML plan of links and shell steps, run from a repo | no, paths are literal | no | no built-in undo | yes, by design (`shell:`) |
| **chezmoi** | renders a source state (templates, secrets) into `$HOME` | no, `$HOME` is the target | n/a - different domain | `chezmoi forget` / re-apply | yes (`run_` scripts, templates) |
| **yadm** | git with `$HOME` as the work tree, plus per-host alternates | no | n/a | git-native | yes (bootstrap) |
| **rcm** | tag- and host-aware symlinks from `~/.dotfiles` into `$HOME` | no | n/a | `rcdn` | hooks only |
| **vcsh** | many git repos sharing `$HOME` as one work tree | no | n/a | git-native | no |
| **git submodule** | a pinned checkout of another repo *inside* your repo | n/a - you commit the path | n/a - it is tracked | `git rm` | no |
| **git subtree** | copies another repo's content into your history | n/a | n/a - it is tracked | revert the merge | no |
| **core.hooksPath** | points git hooks at a shared directory | no | n/a | unset the config | it runs hooks, that is the point |
| **ghq** | clones repos into a predictable path layout | it *creates* predictability instead | n/a | delete the clone | no |
| **rulesync / ruler** | generates per-agent config files from one source | n/a - single repo | overwrites what it generates | regenerate or delete | no (they write files) |

The two columns that matter most for the specific job are the middle ones.
Everything in this table can create a symlink. Almost nothing else in it can
answer "where is the `payments-api` checkout on *this* machine?" without being
told, or refuse to turn a git-tracked `.github/` into a symlink.

---

## Dotfile managers

### GNU Stow

`stow` is the closest relative and the best-engineered tool on this list.
`stow -d ~/dotfiles -t ~ vim` symlinks the contents of `~/dotfiles/vim` into `~`,
folding directories where it can, and `stow -D` takes it back out. It has been
correct for thirty years.

**Where it wins:** if your destinations are fixed and few, stow plus a Makefile
is less software than graft and does the mechanical part better. `stow --adopt`
even moves an existing real file into the package for you - note that this is
*not* what `graft adopt` does with a file git tracks: graft copies that one and
leaves the deletion to a git commit you make yourself.

**Where it stops:** stow's target is an argument. It has no idea what a git
checkout is, so it cannot find one by remote URL, cannot check whether a
destination is tracked by git, and cannot manage `.git/info/exclude`. It also
thinks in *packages of files to be merged into one tree*, whereas the common
case here is *one directory linked as one name* (`.github`), which is stow's
"tree folding" behaviour arriving by accident rather than by request.

**Verdict:** for one person with three checkouts at stable paths, use stow. The
README of this project shows the ten-line Makefile that does it.

### dotbot

A Python bootstrapper: you commit `install.conf.yaml` next to your dotfiles,
listing `link:` entries and `shell:` commands, and vendor `dotbot` itself as a
submodule so `./install` works on a fresh machine. Idempotent, small,
well-documented, and its `create`/`relink`/`force` options cover the awkward
cases.

**Where it stops:** link destinations are literal paths. On a machine where the
API checkout lives somewhere else, the config is wrong and there is no
mechanism to discover the right path - you would template the YAML, and then
you are writing a discovery tool anyway. And `shell:` steps run on every
`./install`: that is a feature for a dotfiles bootstrapper and precisely the
thing graft refuses to have (invariant I1), because a context repo is something
you clone from a colleague.

**Verdict:** if every machine in your team puts checkouts in the same place,
dotbot's `link:` map is an honest, boring answer and you should probably use it.

### chezmoi

The most capable dotfile manager in existence: a source state in git, Go
templates for per-machine differences, `age`/GPG encryption for secrets, an
`apply` that diffs first, and support for scripts that run once. Manages `$HOME`.

**Where it stops:** the domain is `$HOME`, not "N sibling git checkouts".
chezmoi's default is to *copy* the rendered file to the target, which in a git
work tree means real files that git sees, not a symlink git can be told to
ignore. (`create_symlink` mode exists, and people do point chezmoi at paths
outside `$HOME`, but at that point you are fighting the model.) There is nothing
to discover a checkout by remote URL, and nothing that knows a destination is
tracked.

**Where it wins outright:** anything with per-machine variation or secrets.
graft has no templating and never will; if your context needs to differ by
machine, chezmoi's source state is the right shape, and you can point graft at
the directory chezmoi renders.

### yadm

Git with `$HOME` as the work tree, plus alternate files per host/OS/class and
transparent encryption. If you already think of your home directory as a
repository, yadm is an excellent fit.

**Where it stops:** same domain mismatch. yadm has no notion of "this other
repository over there". Also, tracking `$HOME` in git and then having a tool
symlink things *into* checkouts under `$HOME` interacts confusingly; keep the
two jobs apart.

### rcm

thoughtbot's `rcup`/`rcdn`/`mkrc`/`lsrc`: symlinks from `~/.dotfiles` into
`$HOME`, with a genuinely nice tag and host model (`rcup -t work`). The
tag idea is the closest thing on this list to graft's per-target link sets.

**Where it stops:** `$HOME` again, and destinations are derived from the source
layout rather than discovered.

*Uncertainty:* I have not tracked rcm's release activity recently and cannot
tell you whether it is actively maintained in 2026. Check before adopting it.

### vcsh

Several git repositories sharing `$HOME` as a work tree, by manipulating
`GIT_DIR`, usually driven by `mr`. Solves "many repos, one working tree" - a
genuinely different shape from graft's "one repo, many working trees", and an
elegant piece of work.

**Where it stops:** `$HOME`, no symlinks at all (that is its selling point), and
the whole design assumes the work tree is shared, which is the opposite of what
we need.

*Uncertainty:* same caveat as rcm - I am not current on its maintenance status.

---

## Git's own mechanisms

### git submodule

Add the context repo as a submodule of each project. This is the option most
teams try first, and it has real advantages: the content is *in* the repo, so it
works in CI, on Windows, and for anyone who clones - no extra tool at all, and
the version is pinned to a commit.

**Where it stops:**

- It requires a commit to every consumer repository. Often you do not own them,
  or you do not want to explain a `.github/` submodule to forty people.
- Updating means a commit in every repo, forever.
- `git clone` without `--recurse-submodules` gives an empty directory, and
  agent tooling reading an empty `.github/` fails in a confusing way.
- Nothing personal or machine-specific can live in it, because it is committed.

**Verdict:** if you own the repositories, want the context pinned per repo, and
need it present in CI, use a submodule. That is a better answer than graft, and
graft does not try to replace it. graft's case is the other one: content that is
*yours*, not the project's, and that should not appear in the project's history.

### git subtree

Copies the other repository's content into your history, so consumers need
nothing special. All of the submodule's CI and Windows advantages without the
`--recurse-submodules` footgun.

**Where it stops:** the content is duplicated into every repository and every
update is a merge in each one. It is also, again, a commit to repositories you
may not own. For content that changes weekly, the ceremony dominates.

### core.hooksPath (and `init.templateDir`)

`git config core.hooksPath ~/context/hooks` points one repository's hooks at a
shared directory; `git config --global init.templateDir ...` seeds new clones.
This is the standard way to share *hooks*, and graft does not compete with it.

**Where it stops:** hooks only. It says nothing about `CLAUDE.md`,
`.github/copilot-instructions.md`, skills or agent definitions. If your shared
context is entirely hooks, you do not need graft. If it is partly hooks, use
`core.hooksPath` for those and let graft handle the rest - they do not conflict.

### ghq

Clones every repository into `$GHQ_ROOT/github.com/owner/repo`. It does not
solve graft's problem; it *dissolves* part of it, by making checkout locations
predictable in the first place.

**Where it wins:** if your whole team uses ghq, then `ghq list -p` plus a
`for` loop and `ln -sfn` gets you most of graft's discovery for free, and a
`dir:` glob in `graft.conf` becomes trivial. Adopting ghq is a reasonable
alternative to adopting graft.

**Where it stops:** it only governs repos *you clone through it*. The checkout
someone cloned by hand two years ago, the worktree, the vendored copy in
`~/work/customer-x/` - those are exactly the ones graft's `origin:` matching
finds and a path convention does not.

---

## AI-rules generators: orthogonal, not competing

### rulesync and ruler

[rulesync][] (`dyoshikawa/rulesync`) and [ruler][] (`intellectronica/ruler`) both
solve the *format fan-out* problem: you write your rules once - in `.rulesync/`
or `.ruler/` - and the tool generates the per-agent files
(`.github/copilot-instructions.md`, `.cursor/rules/*`, `CLAUDE.md`,
`.gemini/...`, MCP configuration, and so on) from that single source. rulesync
additionally covers commands, subagents and ignore files; ruler leans on a
`ruler.toml` that says which agents to emit for.

These run **inside one repository** and turn one format into many.

graft runs **across machines** and puts one directory into many checkouts.

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

The axes are perpendicular, and the pipeline that uses both is the obvious one:
run `ruler apply` or `rulesync generate` **inside your context repo** to produce
the per-agent formats, commit the result, then let `graft link` place those
directories into every checkout on every machine. graft deliberately has no
templating, no format conversion and no `--generate` flag, so there is nothing
to disagree about at the seam.

If you only ever work in one repository, you do not need graft: use rulesync or
ruler alone. If you have one repository and forty machines, you do not need
them: use graft alone.

*Uncertainty:* both projects release frequently and the exact feature lists
above were checked in August 2026 against their READMEs. Treat the details as
indicative and the boundary - "they generate formats, we distribute trees" - as
the stable part.

### AGENTS.md

[AGENTS.md][] is a convention, not a tool: a single Markdown file at the repo
root that any agent can read. It reduces the fan-out problem rather than solving
it, and it is the reason many context repos now contain one canonical file plus
a couple of symlinks.

graft is happy to be the thing that creates those symlinks in every checkout:

```ini
link = AGENTS.md -> AGENTS.md
link = AGENTS.md -> CLAUDE.md
```

Two destinations, one source, no generated files, and both stay correct when you
edit the source once.

---

## When to pick which

- **One repository, several agent tools** -> rulesync or ruler. Not graft.
- **Several repositories you own, content that belongs to the project** -> git
  submodule or subtree. Not graft.
- **Your home directory** -> chezmoi, yadm, stow or rcm. Not graft.
- **Shared git hooks** -> `core.hooksPath`. Not graft.
- **Three checkouts, one person, stable paths** -> GNU Stow and a Makefile. The
  README shows exactly that Makefile. Not graft.
- **Content that is yours rather than the project's, in more than a handful of
  checkouts, on more than one machine, and it must be removable without a
  trace** -> that is the case graft was written for.

[rulesync]: https://github.com/dyoshikawa/rulesync
[ruler]: https://github.com/intellectronica/ruler
[AGENTS.md]: https://agents.md
