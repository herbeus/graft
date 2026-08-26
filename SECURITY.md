# Security Policy

## Reporting a vulnerability

Please report security issues through **private GitHub Security Advisories**:

<https://github.com/OWNER/graft/security/advisories/new>

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
- **Nothing is deleted (I3).** The only removal in the entire codebase is
  `rm -- "$path"` on a path that has just been verified to be a symlink. There
  is no `rm -r` anywhere. Your data is moved, never destroyed.
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

## Verifying this yourself

```sh
grep -rn 'eval\|source \|\. "\$' bin lib     # expect: no config-derived input
grep -rn 'rm ' bin lib                       # expect: one site, guarded by [ -L ]
grep -rn 'curl\|wget\|git fetch\|nc ' bin lib # expect: nothing
```

If one of those greps finds something the invariants do not allow, that is a bug
worth reporting, whether or not you can build an exploit out of it.

## Supported versions

The latest release on `main` receives fixes. There are no long-term support
branches while the project is at `0.x`.
