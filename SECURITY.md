# Security Policy

## Reporting a vulnerability

Please report security issues through **private GitHub Security Advisories**:

<https://github.com/herbeus/graft/security/advisories/new>

If you cannot use that form, write to <k.tommy@gmail.com> instead.

Do not open a public issue for a vulnerability. You should get a first response
within seven days. If a fix is warranted, it ships in a patch release and the
advisory is published together with it; you are credited unless you ask not to
be.

This is a small, unfunded project. There is no bug bounty.

## What graft is allowed to do

This section is the actual security contract. It is short on purpose: a tool
that creates symlinks in other people's repositories has to be auditable in an
afternoon.

**graft writes exactly three kinds of thing, and nothing else:**

1. **Symlinks at configured destination names.** The destination is a path you
   named in `graft.conf`, relative to a discovered checkout. The link target is
   a path inside your context repo.
2. **One delimited block in `.git/info/exclude`** of a checkout it links into:

   ```
   # graft: managed links (do not edit)
   .github
   # graft: end
   ```

   This is a local, uncommitted file. graft never edits `.gitignore`, never
   edits `.git/config`, and never creates a commit.
3. **Backup renames.** An existing real file or directory at a destination is
   *moved* to a backup name next to it before the link is created. The path is
   recorded in the state file so `graft unlink` can move it back.

Everything else is out of bounds, enforced by these invariants (the full list is
in `docs/SPEC.md` section 1):

- **No code execution (I1).** graft never runs, sources or `eval`s anything that
  came from a context repo or from a config file. `[setup]` entries in
  `graft.conf` are *printed* as a reminder, never executed. If you clone an
  untrusted context repo, the worst its `graft.conf` can do is make graft create
  or refuse links - it cannot make graft run a script.
- **No network (I2).** graft opens no sockets. No `git fetch`, no `curl`, no
  update check, no telemetry. It works offline and behaves identically on an
  air-gapped machine.
- **Nothing of yours is deleted (I3).** On any path that came from your config,
  from discovery or from the state file, the only removal is `rm -- "$path"` on
  a path that has just been verified to be a symlink and to be ours. There is no
  `rm -r` anywhere, and no `rm` is ever called on a real file or directory.
  Your data is moved to a backup, never destroyed. graft does delete its own
  scratch - probe symlinks and the temp file behind every atomic write - and the
  table below lists every removal site there is.
- **Containment (I4).** Every link source must resolve to a path strictly inside
  the context repo, and every destination to a path strictly inside its target
  checkout. Resolution happens before the check, so a symlink cannot be used to
  escape either boundary.
- **Never over tracked files (I5).** If git tracks the destination, graft
  refuses, with no override flag.
- **No privilege escalation.** graft never calls `sudo`, `doas` or `su`, and
  never writes outside your home directory unless you configured a destination
  there yourself. `install.sh` links into `~/.local/bin` by default.

There is also a deny-list: a link destination may not be, or be inside, `.git`,
`.ssh`, `.gnupg`, `.aws`, `.config/gh`, `.netrc`, `.bashrc`, `.zshrc`,
`.profile`, `.bash_profile` or `.gitconfig`. This is defence in depth against a
typo or a hostile `graft.conf`, not the primary control - containment is.

## Threat model

**Assets.** Your source checkouts, your context repo, and your shell startup
files.

**Trust assumptions.** You trust the git repositories you have already cloned.
graft runs with your privileges and can therefore do anything you can do; the
invariants above are what keeps the set of things it *does* do small enough to
review.

### In scope

| Threat | Control |
|---|---|
| A hostile `graft.conf` in a context repo you cloned tries to run a command | I1: config values are data. There is no key whose value is executed. |
| A hostile `graft.conf` points a link at `~/.ssh/authorized_keys` or `~/.bashrc` | Deny-list plus containment: a destination is always relative to a checkout root and may not escape it. |
| A symlink in the context repo is used to make a "contained" source resolve outside it | I4: paths are resolved *before* the containment check. |
| Replacing a tracked directory produces a commit that deletes a team's files | I5: refused, no override. `graft adopt` is the supported way out. |
| A crafted path or origin URL contains terminal escape sequences | All config- and filesystem-derived strings are printed through a control-character filter. |
| A destination is a mountpoint or a foreign symlink | Classified and skipped; `--force` relaxes only the *foreign symlink* case, never I5 and never a backup. |
| An interrupted run leaves a half-created link | Links are created at a temporary name and `mv`'d into place, which is atomic. State writes are write-then-`mv` as well. |
| A stale or corrupted state file makes `unlink` remove the wrong thing | State is a hint, never the truth. `unlink` re-checks the filesystem before every step and only removes a path that is *currently* a symlink into the context repo. |

### Out of scope

- **Anything the context repo can do once it is linked.** graft's job is to put
  a directory of instructions where your agent tooling will find it. Whether
  your AI agent then acts on those instructions is that agent's security
  boundary, not graft's. Review the context repo you link, the same way you
  review a dependency.
- **A hostile local user with write access to your home directory.** Someone who
  can edit `~/.local/state/graft/*/links.tsv` can also edit `~/.bashrc`.
- **Symlink races against an attacker who already has write access to a target
  checkout.** graft checks and then acts; on a single-user machine that is fine,
  and on a shared machine the attacker has better options than racing us.
- **Supply-chain integrity of git, awk, find and the rest of coreutils.**
- **Windows without WSL**, and filesystems without POSIX symlinks. Unsupported,
  not merely insecure.

## Every removal site

There are eight, and you can read all of them in an afternoon. This is the whole
list; `grep` for it yourself with the commands in the next section.

| site | what it removes | guard |
|---|---|---|
| `lib/apply.sh` `ap_symlink_capable` | the probe symlink it just created, to test whether the filesystem supports symlinks at all | `[ -L ]`, and the name is graft's own `.graft-probe.<pid>.<n>` |
| `lib/apply.sh` `ap_symlink_capable` | the probe *file* it just created, to tell "this filesystem has no symlinks" apart from "I may not write here" | the name is that same probe name plus `.w` |
| `lib/apply.sh` `ap_mv_no_target_dir` (two calls) | the two probe symlinks it just created, to test whether `mv -T` exists | `[ -L ]`, same naming |
| `lib/apply.sh` `ap_link` | the temporary link it just created, after the rename onto the destination failed | `[ -L ]`, same naming |
| `lib/apply.sh` `ap_replace` | the destination, on systems without `mv -T`, immediately before renaming the new link over it | `[ -L "$dest" ]` - a real file or directory has been moved to a backup long before this point |
| `lib/apply.sh` `ap_unlink_at` | the destination, during `graft unlink` | `[ -L "$dest" ]` **and** the link resolves into the context repo |
| `lib/core.sh` `gr_atomic_write` | its own temp file, when writing the state or cache file failed | the name is graft's own `.graft.tmp.<pid>`, in the directory it is writing to |

Six of the eight remove something graft itself created seconds earlier, under a
name it chose. The other two are the only places a *destination* can be removed,
and neither can touch a real file: `[ -L ]` is asked first, every time.

Empty directories graft created for a multi-segment destination are removed on
`unlink` with `rmdir`, which refuses on a non-empty directory - never `rm -r`.

## Verifying this yourself

```sh
# nothing is interpreted: no eval at all, and the only `.` lines are the six in
# bin/graft that source graft's own lib/*.sh by absolute path
grep -rn 'eval\|source \|\. "\$' bin lib

# every rm: expect nine lines - the eight sites in the table above, plus one
# gr_say in lib/plan.sh that *prints* a `git rm -r --cached` command for you to
# run yourself after `graft adopt`. graft never runs it.
grep -rnE '(^|[^[:alnum:]_./-])rm ' bin lib | grep -vE ':[0-9]+:[[:space:]]*#'

# graft never runs a recursive delete: expect two comments and that one printed
# git command, and no executable `rm -r` of its own
grep -rn 'rm -r' bin lib

# no network
grep -rn 'curl\|wget\|git fetch\|nc ' bin lib   # expect: nothing
```

If one of those greps finds something the invariants do not allow, that is a bug
worth reporting, whether or not you can build an exploit out of it.

## Supported versions

The latest release on `main` receives fixes. There are no long-term support
branches while the project is at `0.x`.
