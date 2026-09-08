# examples/minimal - a context repo you can actually run

This directory is a complete, working **context repo**: a `graft.conf` plus the
shared agent context it distributes. It is small enough to read in five minutes
and real enough to run.

It uses the same layout `graft init` scaffolds - `source_root = projects` and an
inherited `link = github -> .github` - so what you read here is what a fresh
`graft init` gives you.

```
examples/minimal/
  graft.conf                                   the whole configuration
  projects/                                    source_root
    web-app/                                   source dir of target "web-app"
      github/                                  -> linked in as .github
        copilot-instructions.md
        skills/release-checklist/SKILL.md
      CLAUDE.md                                -> linked in as CLAUDE.md
      cursor-rules/00-project.mdc              -> linked in as .cursor/rules
    api/                                       source dir of target "api"
      github/copilot-instructions.md
      CLAUDE.md
    workspace/                                 the parent folder of the checkouts
      github/copilot-instructions.md
    setup/install-mcp.sh                       printed as a reminder, never run
```

`projects/` here is the *context* repo's own folder of per-target content. It has
nothing to do with where your checkouts live on disk - that is `search_root`,
which this example sets to `~/projects` and the walkthrough below overrides.

With the inherited `link = github -> .github`, the `web-app` checkout ends up
with:

```
web-app/.github        -> .../examples/minimal/projects/web-app/github
web-app/CLAUDE.md      -> .../examples/minimal/projects/web-app/CLAUDE.md
web-app/.cursor/rules  -> .../examples/minimal/projects/web-app/cursor-rules
```

Three symlinks. No copies, no generated files, nothing to keep in sync.

## Try it on throwaway repositories

This creates two fake checkouts in a temporary directory, points the example at
them, and cleans up after itself. It touches nothing outside `$demo`.

```sh
demo=$(mktemp -d)
mkdir -p "$demo/projects/web-app" "$demo/projects/payments-api"

git -C "$demo/projects/web-app" init -q
echo '{}' >"$demo/projects/web-app/package.json"
git -C "$demo/projects/web-app" remote add origin https://github.com/OWNER/web-app.git

git -C "$demo/projects/payments-api" init -q
echo 'module payments' >"$demo/projects/payments-api/go.mod"
git -C "$demo/projects/payments-api" remote add origin https://github.com/OWNER/payments-api.git

# Copy the example so the demo edits do not touch this repository.
cp -R examples/minimal "$demo/context"
sed -i.bak "s|~/projects|$demo/projects|" "$demo/context/graft.conf"

graft -C "$demo/context/graft.conf" check
graft -C "$demo/context/graft.conf" link --yes
graft -C "$demo/context/graft.conf" status
graft -C "$demo/context/graft.conf" link            # the idempotent second run

# `ls -l` would hide two of the three links, because they start with a dot.
find "$demo/projects" -maxdepth 3 -type l | sort

graft -C "$demo/context/graft.conf" unlink --yes
rm -rf "$demo"
```

On macOS, `sed -i.bak` is what the line above uses because BSD `sed` requires a
suffix argument; the `.bak` file is discarded with the demo directory.

That run, with `$demo` shown as `/tmp/demo`, prints:

```
$ graft -C "$demo/context/graft.conf" check
graft.conf: /tmp/demo/context/graft.conf
  ✓ syntax, schema and sources are all in order
  3 targets, 1 setup note

$ graft -C "$demo/context/graft.conf" link --yes
plan
  + /tmp/demo/projects/web-app/.github  (web-app)
  + /tmp/demo/projects/web-app/CLAUDE.md  (web-app)
  + /tmp/demo/projects/web-app/.cursor/rules  (web-app)
  + /tmp/demo/projects/payments-api/.github  (api)
  + /tmp/demo/projects/payments-api/CLAUDE.md  (api)
  + /tmp/demo/projects/.github  (workspace)

  ✓ 6 links in place

next steps (graft never runs these for you)
  install the local MCP servers (asks for your personal token)
      /tmp/demo/context/projects/setup/install-mcp.sh

$ graft -C "$demo/context/graft.conf" status
context: /tmp/demo/context
web-app - customer-facing frontend
  ✓ /tmp/demo/projects/web-app/.github  (web-app)
  ✓ /tmp/demo/projects/web-app/CLAUDE.md  (web-app)
  ✓ /tmp/demo/projects/web-app/.cursor/rules  (web-app)
api - payments API
  ✓ /tmp/demo/projects/payments-api/.github  (api)
  ✓ /tmp/demo/projects/payments-api/CLAUDE.md  (api)
workspace - the parent folder that holds every checkout, for editor-wide rules
  ✓ /tmp/demo/projects/.github  (workspace)

$ graft -C "$demo/context/graft.conf" link
✓ 6 links are up to date, nothing to do

$ find "$demo/projects" -maxdepth 3 -type l | sort
/tmp/demo/projects/.github
/tmp/demo/projects/payments-api/.github
/tmp/demo/projects/payments-api/CLAUDE.md
/tmp/demo/projects/web-app/.cursor/rules
/tmp/demo/projects/web-app/.github
/tmp/demo/projects/web-app/CLAUDE.md

$ graft -C "$demo/context/graft.conf" unlink --yes
  ✓ /tmp/demo/projects/web-app/.github  link removed
  ✓ /tmp/demo/projects/web-app/CLAUDE.md  link removed
  ✓ /tmp/demo/projects/web-app/.cursor/rules  link removed
  ✓ /tmp/demo/projects/payments-api/.github  link removed
  ✓ /tmp/demo/projects/payments-api/CLAUDE.md  link removed
  ✓ /tmp/demo/projects/.github  link removed
6 links removed
```

`--yes` is what keeps the walkthrough non-interactive. Without it the first run
shows the plan and asks once, and the `workspace` target asks a second time,
because it sets `confirm = yes`.

## The tracked-file case, and `graft adopt`

Continue in the same `$demo` to see the one situation graft refuses outright.
Give the API checkout a `CLAUDE.md` of its own and commit it:

```sh
printf '# payments-api house rules\n' >"$demo/projects/payments-api/CLAUDE.md"
git -C "$demo/projects/payments-api" add CLAUDE.md
git -C "$demo/projects/payments-api" commit -qm 'add CLAUDE.md'

graft -C "$demo/context/graft.conf" link --yes
```

```
  + /tmp/demo/projects/web-app/.github  (web-app)
  + /tmp/demo/projects/web-app/CLAUDE.md  (web-app)
  + /tmp/demo/projects/web-app/.cursor/rules  (web-app)
  + /tmp/demo/projects/payments-api/.github  (api)
  ! /tmp/demo/projects/payments-api/CLAUDE.md  tracked by git, refused  (api)
      git tracks this path, so a symlink here would commit a deletion.
      move it into the context repo instead: graft adopt /tmp/demo/projects/payments-api/CLAUDE.md --as api
  + /tmp/demo/projects/.github  (workspace)

5 changed, 1 needs attention

next steps (graft never runs these for you)
  install the local MCP servers (asks for your personal token)
      /tmp/demo/context/projects/setup/install-mcp.sh
```

No `plan` header and no confirmation this time: the plan is shown and confirmed
only on the first run for a given config, and the walkthrough above already made
that run. Exit code 1: five links are in place and one destination needs a
decision from you.

`graft adopt` is that decision, and it needs the slot in the context repo to be
free. This example already ships `projects/api/CLAUDE.md`, so move it aside
first - otherwise adopt stops with `already present in the context repo` and
exit code 2, because merging two files is not something it will guess at:

```sh
mv "$demo/context/projects/api/CLAUDE.md" "$demo/context/projects/api/CLAUDE.md.orig"
graft -C "$demo/context/graft.conf" adopt \
    "$demo/projects/payments-api/CLAUDE.md" --as api --yes
```

```
plan
  copy /tmp/demo/projects/payments-api/CLAUDE.md
    to /tmp/demo/context/projects/api/CLAUDE.md
  leave the original alone - it is tracked, so only git may remove it
  ✓ copied into the context repo (your repo is untouched)

three steps to finish, in this order
  1. commit it here:
       git -C /tmp/demo/context add projects/api/CLAUDE.md && git -C /tmp/demo/context commit -m "adopt api/CLAUDE.md"
  2. stop tracking it over there - git removes it, graft never does:
       git -C /tmp/demo/projects/payments-api rm -r --cached -- CLAUDE.md
       git -C /tmp/demo/projects/payments-api commit -m "move CLAUDE.md into the shared context repo"
  3. then: graft link api
```

The tracked file was **copied**, not moved:

```sh
git -C "$demo/projects/payments-api" status --short -- CLAUDE.md   # prints nothing
```

graft will not stage the deletion of files it does not own, so the three git
commands are yours to run, in that order. Step 2 comes after step 1 on purpose:
until the copy is committed in the context repo, the content exists in only one
place.

## What to notice

- **The paths in `graft.conf` are not machine paths.** `find = origin:...`
  matches the git remote URL, so the same committed config works for a
  colleague who keeps their checkouts somewhere else entirely.
- **`verify = package.json`** keeps a same-named fork, an archived copy or a
  half-deleted clone from being chosen.
- **`[setup "mcp-servers"]`** prints `projects/setup/install-mcp.sh` after a
  successful run and stops there. Read the script, then run it yourself. graft
  never executes anything that arrived through a `git pull`.
- **`git_exclude = yes`** puts a marked block in each checkout's
  `.git/info/exclude`, so `.github` does not show up as untracked in every
  `git status`. It is a local file; nothing is committed to your repositories.
  `graft unlink` takes the block out again.
- **`confirm = yes` on the `workspace` target** makes graft ask before it touches
  that one, once per run rather than once per link. It is there because that
  target links into the *parent folder* of your checkouts, which is a directory
  people are more attached to than a repo.
- **`git_exclude = no` on the same target**, because that parent folder is
  usually not a git repo at all, so there is no exclude file to write to.

## Making it yours

1. `git init` a new repository - this is your context repo.
2. Copy `graft.conf` into its root and copy `projects/` next to it. Or run
   `graft init` there and put your content under `projects/<name>/github/`.
3. Replace `OWNER` in the `find = origin:` lines with your GitHub organisation,
   or swap in `gitlab.example.com/team/...`.
4. `graft check`, then `graft link --dry-run`, then `graft link`.
5. Commit it. Your colleague clones the repo, runs `graft link`, and has the
   same context on their machine, wherever their checkouts happen to live.
