# Pitfalls - the bugs this class of tool always has

Each of these was reproduced in a scratch directory before being written down.
Each has a named test in the suite. Do not "clean up" the code that guards them.

## P1 - `ln -s` without `-n` onto an existing directory symlink

```sh
mkdir -p a && ln -s a dirlink
ln -s /etc/hosts dirlink      # creates a/hosts, NOT dirlink
```
The link lands *inside* the target directory. Symptom in the wild: after the second
run, `projects/demo/github/github` appears inside the context repo.

Guard: never `ln -s` onto an existing path. Create at a temporary name and `mv -f`
over the destination. This is also atomic, which `ln -sfn` is not.

Test: `link: does not create a link inside an existing directory symlink`

## P2 - testing `-e` before `-L`

A dangling symlink is `-L` true and `-e` **false**. A classifier that asks `-e`
first files it under "does not exist", then `ln -s` fails with `File exists`, and
under `set -e` the whole run dies - leaving the remaining targets untouched.

Guard: `-L` is always the first question asked about a destination.

Test: `link: repairs a dangling symlink that points into the context repo`

## P3 - assuming `$repo/.git/info/exclude` exists

In a worktree and in a submodule, `.git` is a **file** containing `gitdir: ...`.
Appending to `$repo/.git/info/exclude` fails, or worse, creates a file named
`.git/info/exclude` in a directory that git does not read.

Guard: always `git rev-parse --git-common-dir`, and `mkdir -p "$dir/info"`.

Test: `git: uses the common git dir in a worktree where .git is a file`

## P4 - using `.git/info/exclude` on a path that is already tracked

`exclude` does not apply to tracked paths - verified: after adding `.github` to
`info/exclude`, `git ls-files` still lists `.github/f.md`. Replacing a tracked
directory with a symlink therefore produces a diff that deletes every file in it.
Someone commits that, and the team's CI workflows are gone.

Guard: `git ls-files --error-unmatch -- "$dest"` decides. If tracked, graft
refuses, with no override flag. `graft adopt` is the offered way out.

Test: `git: refuses to link over a path tracked by git`

## P5 - a destructive command with a trailing slash

```sh
ln -s real vlink
rm -rf vlink/        # deletes the CONTENTS of `real`
```
With a trailing slash the shell follows the symlink. In a tool whose sources live
in the context repo, this deletes the shared context for everyone.

Guard: graft never calls `rm -r` at all. The single deletion site is
`rm -- "$p"` after `[ -L "$p" ]`, with `p` normalised via `${p%/}`.

Test: `unlink: never deletes a real directory, only our symlink`

## P6 - unquoted path expansion

Everything works until someone clones into `~/My Projects/`. Then `mv` is called
with two unrelated arguments.

Guard: every expansion quoted, `IFS=` on every `read`, `find -print0` with
`read -r -d ''`, and `--` before every path argument. Enforced by shellcheck.

Test: `link: handles paths containing spaces, umlauts and dollar signs`

## P7 - `mv -f` nests just like `ln -s` does

The obvious fix for P1 is to create the link under a temporary name and rename it
over the destination. That rename has the same trap:

```sh
mkdir -p real && ln -s real dirlink
ln -s /etc/hosts tmplink
mv -f tmplink dirlink        # moves tmplink INTO real/, does not replace dirlink
```

So the guard against P1 reintroduces P1 one command later. `mv -T` refuses to
treat the destination as a directory, which is what we want - but `-T` is a GNU
extension and absent on macOS.

Guard: probe for `mv -T` once per run. Where it exists, `mv -fT`. Where it does
not, remove the symlink first and then `mv`. That fallback loses atomicity but
never nests, and a non-atomic window is a far smaller problem than a link
silently landing inside the shared context repo.

Test: `link: replacing a directory symlink does not nest (mv -T and fallback)`
