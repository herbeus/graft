# graft - internal specification (contract for implementers)

Status: v0.1 design. This file is the authoritative contract between modules.
Change it in a PR *before* changing code that contradicts it.

Audience: contributors. Users read README.md instead.

---

## 0. What graft is

`graft` links a tree of shared AI-agent context (instructions, skills, agents,
`CLAUDE.md`, `AGENTS.md`, ...) from one *context repo* into many *project checkouts*,
as `.github/`, `.claude/`, `.cursor/` and friends.

Checkouts are located by their **git remote URL**, not by hardcoded path, so the
configuration is committable and shareable across a team.

Non-goals (say no to these in review):
- content transformation / format conversion (that is rulesync/ruler's job)
- executing anything from the context repo
- network access of any kind
- Windows without WSL, or filesystems without symlinks
- managing `$HOME` dotfiles (that is chezmoi/stow's job)

---

## 1. Hard invariants

These are not preferences. A change that breaks one of these is a bug.

- **I1 - No code execution.** graft never runs a script, hook or command that
  originates from the context repo or from any config file. No `eval`, no `source`
  of config/cache/state, no `sh -c` on config-derived strings.
- **I2 - No network.** graft never opens a socket. No `git fetch`, no `curl`.
- **I3 - Nothing of the user's is deleted.** On any path that came from
  configuration, discovery or state, the only removal graft performs is
  `rm -- "$path"` on a path that is a symlink (`[ -L ]`) *and* known to be
  ours. No `rm -r`, never a trailing slash, never on a directory. Existing user
  data is *moved* to a backup, never removed.
  The single exception is graft's own temporary files: a write that goes
  through `gr_atomic_write` removes the temp file it created moments earlier,
  under a name it chose, in a directory it owns. State that plainly, rather
  than claiming a `grep -c 'rm '` of 1 that the code does not support.
- **I4 - Containment.** Every link destination must resolve to a path strictly
  inside its target checkout. Every link source must resolve to a path strictly
  inside the context repo. Resolution happens *before* the check, so symlinks
  cannot be used to escape.
- **I5 - Never write over tracked files.** If the destination path is tracked by
  git, graft refuses. `.git/info/exclude` provably does not apply to tracked
  paths, so linking there produces a mass-deletion diff. There is no flag to
  override this.
- **I6 - Plan before act.** Every mutating command builds a complete plan, validates
  it, and only then executes. `--dry-run` prints the plan and touches nothing.
- **I7 - Idempotent.** Running any command twice in a row produces the same end
  state, the same exit code, no additional backups, and no duplicated file lines.
- **I8 - Reversible.** `graft unlink` restores what `graft link` changed:
  symlink removed, backup moved back, exclude block removed.
- **I9 - bash 3.2.** No associative arrays, no `mapfile`/`readarray`, no `${x^^}`,
  no `&>>`, no `[[ ... =~ ]]` capture groups via BASH_REMATCH beyond index 0..9,
  no `declare -A`, no `printf -v` with array subscripts.

---

## 2. Layout

```
bin/graft           CLI entry point, argument parsing, command dispatch
lib/core.sh         output, errors, path helpers, guards       (no deps)
lib/config.sh       INI parser, schema validation              (needs core)
lib/discover.sh     checkout discovery + cache                 (needs core, config)
lib/state.sh        on-disk state (what we created)            (needs core)
lib/plan.sh         builds the action plan from config+state   (needs all above)
lib/apply.sh        executes a plan: link, backup, exclude     (needs core, state)
tests/*.bats        bats-core suite
tests/helpers/      sandbox setup
```

`bin/graft` resolves its own real path (following symlinks, because `install.sh`
symlinks it into `~/.local/bin`) and sources `lib/*.sh` from the sibling `lib/`.

---

## 3. Files on disk

| Purpose | Path | Format |
|---|---|---|
| user config | `<context-repo>/graft.conf` | INI subset (section 4) |
| discovery cache | `${XDG_CACHE_HOME:-~/.cache}/graft/<confid>/checkouts.tsv` | TSV, disposable |
| state | `${XDG_STATE_HOME:-~/.local/state}/graft/<confid>/links.tsv` | TSV, NOT disposable |

`<confid>` is a short stable hash of the absolute path of `graft.conf`, so several
context repos on one machine never share state. Computed with `cksum` (present
everywhere) over the path string; collisions are harmless because the full path is
stored in the file header and verified on read.

Cache is a speed-up and may be deleted at any time. State records side effects on
*foreign* directories and must survive. Keeping them apart lets us tell users
"delete the cache if discovery looks wrong" without risking their backups.

### 3.1 TSV rules (both files)

- Line 1 is a header: `#graft-<kind>\t<schema-version>\t<config-path>`
- Line 2 is a column-name comment starting with `#`.
- Fields are tab-separated. Tab, newline and backslash inside values are escaped
  as `\t`, `\n`, `\\`. Empty field is written as `-`.
- Writes are atomic: write to `<file>.tmp.$$` in the same directory, then `mv`.
- Unknown schema version: warn once, ignore the file, rebuild. Never abort.
  A state format must never prevent the tool from starting.

### 3.2 state columns

```
target  checkout  dest  source  mode  created_utc  backup  exclude  made_dirs
```
- `mode`: always `symlink` in v0.1 (reserved for a future copy mode)
- `backup`: absolute path of the backup we created, or `-`
- `exclude`: `yes` if *we* added the exclude block, else `no`
- `made_dirs`: `:`-separated parent dirs we created and may remove on unlink, or `-`
  (known limitation: a directory name containing `:` splits this list. Accepted
  for v0.1 because such a name inside a repo is vanishingly rare; fix by moving
  to the same escaping the other fields use if it ever bites.)

---

## 4. Config format

INI subset, git-config flavour. Parsed by `lib/config.sh`, never executed.

```ini
[defaults]
key = value

[target "name"]
key = value

[setup "name"]
key = value
```

Lexical rules:
- Encoding UTF-8. `\r\n` tolerated (stripped).
- Blank lines and lines whose first non-space char is `#` or `;` are ignored.
- A section header is `[word]` or `[word "quoted name"]`. The quoted name may not
  contain `"`, `\`, `/`, or whitespace-only content.
- A key line is `key = value`. Key is `[a-z][a-z0-9_-]*`. Everything after the
  first `=` is the value, trimmed of surrounding whitespace. Values are literals:
  no quoting, no escapes, no interpolation, **except**:
  - a leading `~/` expands to `$HOME/`
  - `${NAME}` expands to the environment variable `NAME` (`[A-Za-z_][A-Za-z0-9_]*`
    only) and only inside `path:` / `env:` strategy arguments and `search_root`.
    Undefined variable expands to empty, which makes the strategy fail softly.
- Some keys are **repeatable**: `link`, `find`, `verify` and `search_root`.
  Order is preserved. Repeating a non-repeatable key is an error naming both
  line numbers.
- Comments are not allowed at end of a value line (a `#` inside a value is literal),
  because glob patterns legitimately contain `#`-free but confusing characters and
  a "sometimes a comment" rule is a footgun.

### 4.1 `[defaults]`

| key | values | default | meaning |
|---|---|---|---|
| `source_root` | rel. path | `.` | root of context sources, relative to graft.conf |
| `search_root` | path, repeatable | `~` | where to look for checkouts |
| `search_depth` | 1..10 | `4` | `find -maxdepth` |
| `search_prune` | comma list of dir names | `node_modules,vendor,target,.cache,Library,dist,build` | pruned during scan (all dotdirs except `.git` are pruned unconditionally) |
| `link` | see 4.3, repeatable | (none) | links inherited by every target |
| `backup` | `suffix`\|`timestamp`\|`abort` | `timestamp` | what to do with existing real files at dest |
| `backup_suffix` | string | `.graft-backup` | base suffix |
| `git_exclude` | `yes`\|`no` | `yes` | manage `.git/info/exclude` block |
| `on_foreign_link` | `warn`\|`abort` | `warn` | dest is a symlink pointing outside the context repo |
| `require` | `yes`\|`no` | `no` | missing checkout is an error rather than a skip |

### 4.2 `[target "name"]`

`name` matches `[A-Za-z0-9][A-Za-z0-9._-]*`, must be unique.

| key | rep. | meaning |
|---|---|---|
| `description` | no | one line, shown in status |
| `source` | no | path under `source_root`; default = target name |
| `find` | **yes** | discovery strategy, first success wins (4.4) |
| `verify` | yes | relative path that must exist in a candidate, else it is rejected |
| `link` | **yes** | link spec (4.3); adds to inherited defaults |
| `confirm` | no | `yes` = ask before linking this target |
| `backup`, `git_exclude`, `on_foreign_link`, `require` | no | override defaults |

### 4.3 `link` value syntax

```
link = <source-relative-path> -> <dest-relative-path>
link = !<dest-relative-path>            # remove an inherited link
```
- Left side is relative to the target's `source` directory. `.` means the whole
  source directory. It may be a file or a directory.
- Right side is relative to the checkout root. It may be multi-segment
  (`.cursor/rules`); missing parents are created and recorded in `made_dirs`.
- Validation (rejected at `check` time, before any filesystem write):
  - dest must not start with `/` or `~`, must not contain a `..` segment
  - dest must not be `.git` or start with `.git/`
  - dest must not be, or be inside: `.ssh`, `.gnupg`, `.aws`, `.config/gh`,
    `.netrc`, `.bashrc`, `.zshrc`, `.profile`, `.bash_profile`, `.gitconfig`
  - source must not contain a `..` segment and must resolve inside the context repo
  - two links in the same target must not share a dest

### 4.4 `find` strategies

Value is `<strategy>:<argument>`. Evaluated top to bottom; first success wins.

| strategy | argument | notes |
|---|---|---|
| `path` | absolute or `~`-path | no search, just check it exists |
| `env` | env var name | empty/unset = soft fail, not an error |
| `origin` | glob against the origin URL | `.git` suffix normalised away first |
| `origin-re` | POSIX ERE against the origin URL | for what globs cannot express |
| `dir` | glob against directory paths | exactly one match required |
| `parent-of` | another strategy | takes `dirname` of the inner result |
| `target` | another target's name | resolves to that target's checkout |

`ask:` is deliberately **not** a strategy. Typing a path without tab completion at
a prompt is the worst interaction in the tool this replaces. When nothing matches,
graft prints the exact `--path name=DIR` invocation instead.

Multiple candidates for one target: never auto-pick. Numbered list with each
candidate's origin URL and relative last-commit time (`git log -1 --format=%cr`),
offered **only** by `graft link`, only at a terminal, and not under `--dry-run`,
`--no-input`, `--json` or `CI` - `status` and previews must stay safe to pipe.
A choice is pinned in the cache exactly as `--path` would be. Everywhere else:
list the candidates, print the `--path` command, record the target as
`ambiguous`, exit 1.

Nothing matches: record `no-checkout` and print every `find` strategy that was
tried, in order, plus the `--path` command. `require = yes` makes that a problem
(exit 1); otherwise it is a skip.

### 4.5 `[setup "name"]`

| key | meaning |
|---|---|
| `description` | one line |
| `run` | path, relative to `source_root`, no `..`, no shell metacharacters |

graft **prints** these after a successful `link` as a reminder. It never executes
them. This is invariant I1 and a documented selling point, not an oversight.

---

## 5. Commands

```
graft [link] [<target>...] [flags]   reconcile: create/repair links
graft status [<target>...]           report only, never writes
graft check                          validate graft.conf, never touches the FS
graft unlink [<target>...]           remove our links, restore backups
graft adopt <dir> --as <target>      take an existing dir into the context repo
graft init                           scaffold graft.conf
graft version | help
```

Bare `graft` == `graft link`. The first `link` run for a given config (no state
file yet) shows the plan and asks once; it does not repeat the plan afterwards,
it prints `N links in place`. Later runs print per-link lines only when something
is not already correct; the single-line `N links are up to date, nothing to do`
is reserved for a run with no change, no problem and no skip. Non-interactive
without `--yes`: print plan, change nothing, exit 3.

A target with `confirm = yes` is asked about separately, once per target, the
first time that target would change something - the answer is remembered for the
rest of the run.

### 5.0 `adopt`

`adopt <path> --as <target>` is the only way out of a tracked destination, and
what it does depends on git:

- **tracked** -> `cp -R` into the context repo, the original untouched, then
  print the three steps that finish the job (commit here; `git rm -r --cached`
  plus a commit there; `graft link <target>`). It must not `mv`: that would stage
  the deletion of files graft does not own, in a repo it was invited into, and
  no `unlink` could restore them. Only git may remove them.
- **untracked** -> `mv` into the context repo, then `ap_link` it straight back,
  then print the one commit that shares it.

Preconditions, each an exit 2 with a copyable snippet rather than a guess:
the path exists and is not already a symlink; it is inside a git checkout; the
named `[target]` exists; one of that target's `link` rules has exactly this
destination (that rule, not `adopt`, decides where in the context repo the
content lands); and the resulting source path is still free. `--dry-run` prints
the plan and returns 0.

### 5.1 Global flags

```
-n, --dry-run     print plan, change nothing
-y, --yes         assume yes for every prompt
    --no-input    never prompt (implicit when stdin is not a TTY or CI is set)
-C, --config P    path to graft.conf (default: search $PWD upwards)
    --path N=DIR  pin target N to DIR for this run and cache it (repeatable)
    --rescan      ignore the discovery cache
    --only NAME   restrict to link specs whose dest basename is NAME
-q, --quiet       errors only
    --json        machine-readable output, implies --no-input
    --no-color    disable colour (also: NO_COLOR env, non-TTY)
-h, --help  -V, --version
```

`--force` exists only for `link` and only relaxes `on_foreign_link`. It never
relaxes I5 (tracked paths) and never suppresses backups.

### 5.2 Exit codes

| code | meaning |
|---|---|
| 0 | success, desired state reached |
| 1 | drift or conflict remains (foreign link, missing checkout with `require`) |
| 2 | usage error or invalid config |
| 3 | changes required but not confirmed (non-interactive without `--yes`) |
| 4 | environment cannot support graft (see below) |
| 130 | interrupted |

Exit 4 has exactly four causes, and nothing else may claim it:

- a destination's parent directory is on a filesystem that cannot hold symlinks
  (`ap_symlink_capable` returns 1, `ap_link` says `unsupported`);
- a destination's parent directory is not writable at all (`ap_symlink_capable`
  returns 2, `ap_link` says `unwritable`);
- `adopt` failed on I/O: `mkdir`, `cp -R` or `mv` returned non-zero;
- `bin/graft` cannot find its own `lib/` (checked before anything is sourced).

An unreadable or missing `graft.conf` is exit **2**, not 4 - `graft_need_config`
reports it as a usage error. Any other failure while applying a link is drift:
`plan_execute` counts it in `PLAN_R_FAILED` and the run exits 1.

Exit codes are part of the public API. Human-readable output is not.

---

## 6. The link algorithm

For one (target, link spec) pair. `SRC` = resolved source, `DST` = destination.

```
1.  resolve SRC; if missing -> error, no link is created
    (a dangling link is worse than no link: tools see .github and find nothing)
2.  containment checks I4 for SRC and DST; deny-list check
3.  if DST is tracked by git -> conflict "tracked", stop (I5, no override)
4.  probe symlink capability in dirname(DST), once per directory, cached for the
    run. Three outcomes, and the last two are told apart on purpose because they
    send the reader off to fix different things:
      symlinks work                     -> continue
      cannot create a symlink, but a
        plain file can be created here  -> "unsupported", exit 4
      cannot create anything here       -> "unwritable", exit 4
5.  classify DST, checking -L BEFORE -e (a dangling symlink is not -e):
      not present            -> CREATE
      symlink -> resolves to SRC              -> UNCHANGED
      symlink -> elsewhere inside context repo -> REPAIR
      symlink -> dangling, pointed into context repo -> REPAIR
      symlink -> anywhere else                -> FOREIGN (warn/abort)
      real dir / real file   -> BACKUP then CREATE
      mountpoint             -> conflict, never touch
6.  CREATE goes through a temporary name in the same directory, so the rename
    is atomic:
        ln -s -- SRC <parent>/.graft-link.$$.<n>
        mv -fT   -- <parent>/.graft-link.$$.<n> DST
    Two separate traps here, both verified (pitfalls P1 and P7):
      - a bare `ln -s` onto an existing directory symlink creates the link
        INSIDE the directory
      - so does `mv -f` without `-T`. `-T` is GNU-only, so probe for it once per
        run and fall back to "remove the symlink, then mv" where it is absent.
        That fallback is not atomic, but it never nests.
7.  BACKUP is `mv -- DST BACKUP`; never rm. Backup name must not already exist.
8.  git exclude: use `git rev-parse --git-common-dir` (`.git` is a FILE in
    worktrees and submodules). Order matters: ask "is the name already in a
    block WE wrote?" *before* asking `git check-ignore -q`. The other way round,
    the second run sees its own entry, concludes "already ignored", records
    `exclude=no`, and then unlink leaves the block behind forever.
    Write a delimited block, never bare lines:
        # graft: managed links (do not edit)
        .github
        # graft: end
9.  record everything in state
```

`unlink` reverses steps 9..6, verifying against the filesystem at every step
(state is a hint, never the truth): only remove `DST` if it is *currently* a
symlink resolving into the context repo. Remove the exclude block only if we
recorded `exclude=yes` and the block content still matches what we wrote.

---

## 7. Output

- Colour only when stdout is a TTY, `NO_COLOR` unset, `--no-color` absent.
- Status glyphs, with an ASCII fallback when `LC_ALL`/`LANG` is not UTF-8:
  `ok` green, `+` created, `~` repaired, `!` conflict, `-` skipped.
- Strings that originate from the config are printed with control characters
  stripped (terminal escape injection).
- The idempotent second run prints exactly one line. If a tool that runs after
  every `git pull` is chatty when nothing happened, people stop reading it, and
  then they miss the run that mattered.
- `--json`: one object per line for results plus a final summary object
  (JSON Lines), so it stays streamable and needs no in-memory document.

---

## 8. Testing

bats-core, vendored-free (CI clones a pinned tag). Every test runs in a sandbox:
`HOME`, `XDG_*` redirected into `mktemp -d`, `GIT_CONFIG_NOSYSTEM=1`,
`GIT_CONFIG_GLOBAL` inside the sandbox, `TZ=UTC`, `LC_ALL=C`.

A tool that scans `$HOME` and creates symlinks MUST cage its own test suite.
`tests/helpers/sandbox.bash` refuses to run if `$HOME` is not under `$BATS_TMPDIR`.

Required coverage, at minimum: every row of section 6 step 5, every invariant in
section 1, and the eight historical bugs P1-P8 in `docs/pitfalls.md`.

---

## 9. Module contracts

Function names are prefixed per module so that a reader of any call site knows
where to look: `gr_` core, `cfg_` config, `disc_` discovery, `st_` state,
`ap_` apply, `plan_` planning.

bash 3.2 has no associative arrays, so parsed data is held in **newline-separated
TSV held in a single string variable** and queried with `grep`/`cut`. This is
slower than a hash and completely adequate at our data sizes (tens of entries),
and it has the large advantage that any intermediate state can be printed.

### 9.1 lib/config.sh

```
cfg_load <conf-path>
    Parses the file. Sets, on success:
      CFG_FILE        absolute path of graft.conf
      CFG_CTX_ROOT    absolute path of the context repo (dirname of CFG_FILE)
      CFG_SOURCE_ROOT absolute path of the source root
      CFG_DATA        TSV: section \t key \t value \t lineno   (one per line)
      CFG_ERRORS      TSV: lineno \t message \t hint           (empty if valid)
    Returns 0 if the file parsed and validated, 2 otherwise. Never exits.

cfg_find_conf [start-dir]
    Walks up from start-dir (default $PWD) looking for graft.conf.
    Prints the path, or returns 1.

cfg_validate
    Fills CFG_ERRORS with every problem found (never stops at the first).
    Returns the number of errors, capped at 250.

cfg_print_errors
    Renders CFG_ERRORS as "graft.conf:LINE: message" plus an indented hint,
    with the offending source line quoted underneath.

Section ids are `defaults`, `target:<name>` and `setup:<name>` - one spelling,
no aliases. A name cannot contain a colon (4.2), so the encoding is reversible.

cfg_targets                       -> target names, one per line, config order
cfg_setups                        -> name \t description \t run
cfg_get <section> <key> [default] -> last value, or default
cfg_get_all <section> <key>       -> every value, one per line, in order
cfg_target_get <t> <key> [default]
    Target value, falling back to [defaults], falling back to the given default.
cfg_target_finds <t>              -> find strategies, one per line, in order
cfg_target_verifies <t>           -> verify paths, one per line, in order
cfg_target_links <t>
    Effective links after inheriting [defaults] and applying "!dest" removals.
    Output: source-abs \t dest-rel, one per line. Sources are NOT checked for
    existence here (that is a plan-time concern), but they ARE containment-checked.
```

### 9.2 lib/discover.sh

```
disc_index_build
    One single filesystem scan for the whole run. Walks every search_root to
    search_depth, pruning search_prune names and every dotdir except .git.
    Emits, for each git checkout found: path \t origin-url \t last-commit-epoch
    Written to the cache file. Sets DISC_INDEX to that path.

disc_index_load [--rescan]
    Uses the cache when it exists and every listed path still exists, otherwise
    rebuilds. --rescan always rebuilds. Sets DISC_INDEX.

disc_resolve <target>
    Walks cfg_target_finds in order, first success wins, then applies every
    `verify` of the target. Prints the checkout path on success.
    Returns 0 found, 1 not found, 2 ambiguous (several candidates).
    On ambiguity it prints all candidates, one per line, and lets the caller
    decide - never picks one itself.

disc_pin <target> <dir>     record a user-supplied path (--path) in the cache
disc_pinned <target>        print a pinned path, or return 1
```

Discovery never prompts. A missing checkout produces the exact `--path` command
the user should run, and nothing else.

### 9.3 lib/state.sh

```
st_load                     reads the state file into ST_DATA (TSV, see 3.2)
st_save                     atomic write of ST_DATA
st_add <target> <checkout> <dest> <source> <mode> <backup> <exclude> <made_dirs>
st_by_dest <dest>           print the record for a destination, or return 1
st_forget <dest>            drop the record for a destination
st_records [target]         all records, optionally filtered by target
st_prune                    drop records whose dest no longer exists
```

State is a hint, never the truth. Every consumer re-checks the filesystem before
acting on a record.

### 9.4 lib/apply.sh

```
ap_symlink_capable <dir>
    Probes by creating and removing a symlink in <dir>. Result cached per
    directory for the run. Returns 0 when symlinks work, 1 when the filesystem
    cannot hold one (a plain file still can be created), 2 when nothing can be
    written there at all.

ap_dest_state <dest> <src-resolved> <ctx-root>
    Classifies a destination without touching it. Prints exactly one word:
      absent unchanged repair foreign backup-dir backup-file mountpoint
    Asks -L before -e, always.

ap_is_tracked <checkout> <dest-rel>     0 if git tracks the path (invariant I5)
ap_git_common_dir <checkout>            prints the common git dir, or returns 1

ap_set_backup_suffix <suffix>    ap_backup_suffix
    The suffix used for backups, set once per run. A run-wide setting rather
    than an ap_link argument because unlink must find the same backup again and
    has no link record to carry it. Rejects an empty suffix or one with a "/".

ap_set_context <ctx-root>
    Sets the context repo root used by the containment checks (I4). Call once
    per run before ap_link. ap_link also accepts it as an optional 8th argument.

ap_link <target> <checkout> <src> <dest-rel> <backup-mode> <exclude> <foreign> [ctx]
    Performs one link according to docs/SPEC.md section 6 and records state.
    Prints one result word on stdout: created repaired unchanged backed-up
    skipped-foreign skipped-tracked unsupported unwritable failed
    The last three are the caller's cue for the exit code: unsupported and
    unwritable mean exit 4, failed means exit 1.

ap_unlink_record <record>
    Reverses one state record, verifying the filesystem at each step.
    Prints one of: removed restored already-gone kept-foreign failed

ap_unlink_dest <checkout> <dest-rel> [ctx]
    Stateless unlink, for when the state file was lost. Falls back to the
    heuristic "the symlink points into the context repo". Restores a backup only
    when exactly one unambiguous candidate exists - guessing here would move a
    stranger's directory onto a path the user is still using.

ap_exclude_add <checkout> <name>        idempotent, delimited block
ap_exclude_remove <checkout> <name>     only removes a block we wrote
```

### 9.5 lib/plan.sh and bin/graft

`plan.sh` turns config plus discovery into a list of intended actions and hands
it to `apply.sh`. `bin/graft` parses arguments, dispatches, and owns all
top-level output. Nothing below `bin/` prints a headline or calls `exit`.
