# examples/minimal - a context repo you can actually run

This directory is a complete, working **context repo**: a `graft.conf` plus the
shared agent context it distributes. It is small enough to read in five minutes
and real enough to run.

```
examples/minimal/
  graft.conf                                   the whole configuration
  context/                                     source_root
    web-app/                                   -> linked into the web-app checkout
      copilot-instructions.md
      CLAUDE.md
      cursor-rules/00-project.mdc
      skills/release-checklist/SKILL.md
    api/                                       -> linked into the API checkout
      copilot-instructions.md
      CLAUDE.md
    workspace/                                 -> linked into the parent folder
      copilot-instructions.md
    setup/install-mcp.sh                       printed as a reminder, never run
```

With the inherited `link = . -> .github`, the `web-app` checkout ends up with:

```
web-app/.github        -> .../examples/minimal/context/web-app
web-app/CLAUDE.md      -> .../examples/minimal/context/web-app/CLAUDE.md
web-app/.cursor/rules  -> .../examples/minimal/context/web-app/cursor-rules
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

ls -l "$demo/projects/web-app"

graft -C "$demo/context/graft.conf" unlink --yes
rm -rf "$demo"
```

On macOS, `sed -i.bak` is what the line above uses because BSD `sed` requires a
suffix argument; the `.bak` file is discarded with the demo directory.

## What to notice

- **The paths in `graft.conf` are not machine paths.** `find = origin:...`
  matches the git remote URL, so the same committed config works for a
  colleague who keeps their checkouts somewhere else entirely.
- **`verify = package.json`** keeps a same-named fork, an archived copy or a
  half-deleted clone from being chosen.
- **`[setup "mcp-servers"]`** prints `context/setup/install-mcp.sh` after a
  successful run and stops there. Read the script, then run it yourself. graft
  never executes anything that arrived through a `git pull`.
- **`git_exclude = yes`** puts a marked block in each checkout's
  `.git/info/exclude`, so `.github` does not show up as untracked in every
  `git status`. It is a local file; nothing is committed to your repositories.
- **If a checkout already tracks `CLAUDE.md`**, graft refuses that one link and
  says so, rather than replacing a tracked file with a symlink. Use
  `graft adopt web-app/CLAUDE.md --as web-app` to move the real file into the
  context repo first.

## Making it yours

1. `git init` a new repository - this is your context repo.
2. Copy `graft.conf` into its root and copy `context/` next to it.
3. Replace `OWNER` in the `find = origin:` lines with your GitHub organisation,
   or swap in `gitlab.example.com/team/...`.
4. `graft check`, then `graft link --dry-run`, then `graft link`.
5. Commit it. Your colleague clones the repo, runs `graft link`, and has the
   same context on their machine, wherever their checkouts happen to live.
