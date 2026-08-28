#!/usr/bin/env bats
#
# apply.bats - the link half of lib/apply.sh.
#
# Covers every row of the classification table in docs/SPEC.md section 6 step 5
# and every pitfall in docs/pitfalls.md that can be triggered while linking.
# Tests that guard a documented pitfall carry the name given in that document.

# shellcheck source-path=SCRIPTDIR/..
load helpers/sandbox

setup() {
	gr_sandbox

	# shellcheck source=lib/core.sh
	. "$GRAFT_ROOT/lib/core.sh"
	# shellcheck source=lib/state.sh
	. "$GRAFT_ROOT/lib/state.sh"
	# shellcheck source=lib/apply.sh
	. "$GRAFT_ROOT/lib/apply.sh"
	gr_init_style

	# Physical paths: containment is decided on resolved paths, so the tests
	# must compare against resolved paths too.
	SANDBOX_P="$(pwd -P)"
	CTX="$SANDBOX_P/ctx"
	CO="$SANDBOX_P/proj"
	mkctx "$CTX"
	mkrepo "$CO"
	SRC="$CTX/projects/demo/github"
	printf '[defaults]\n' >"$CTX/graft.conf"

	st_load "$CTX/graft.conf"
	ap_set_context "$CTX"
	EXCLUDE="$CO/.git/info/exclude"
}

teardown() { gr_sandbox_teardown; }

# The one-word result of ap_link without its diagnostics on stderr.
result() { ap_link "$@" 2>/dev/null; }

# The usual call: target demo, timestamped backups, exclude on, warn on foreign.
link_github() { result demo "$CO" "$SRC" .github timestamp yes warn; }

# bsd_mv - put a `mv` without `-T` first in PATH, the way macOS ships one.
# Everything that is not `-T` is handed to the real mv, so only the probe and
# the path it selects change behaviour.
bsd_mv() {
	local bin="$SANDBOX_P/bsd-bin" real
	real=$(command -v mv)
	mkdir -p "$bin"
	cat >"$bin/mv" <<-SH
		#!/usr/bin/env bash
		for a in "\$@"; do
			case "\$a" in
			-*T*)
				printf 'mv: illegal option -- T\n' >&2
				exit 64
				;;
			--) break ;;
			esac
		done
		exec $real "\$@"
	SH
	chmod +x "$bin/mv"
	PATH="$bin:$PATH"
	hash -r
}

# --- section 6 step 5: the classification table ------------------------------

@test "classify: a destination that is not present is absent" {
	run ap_dest_state "$CO/.github" "$SRC" "$CTX"
	assert_status 0
	[ "$output" = absent ]
}

@test "classify: a symlink that resolves to the source is unchanged" {
	ln -s "$SRC" "$CO/.github"
	run ap_dest_state "$CO/.github" "$SRC" "$CTX"
	[ "$output" = unchanged ]
}

@test "classify: a symlink elsewhere inside the context repo is repair" {
	mkdir -p "$CTX/projects/other"
	ln -s "$CTX/projects/other" "$CO/.github"
	run ap_dest_state "$CO/.github" "$SRC" "$CTX"
	[ "$output" = repair ]
}

@test "classify: a dangling symlink pointing into the context repo is repair" {
	ln -s "$CTX/projects/gone/github" "$CO/.github"
	[ ! -e "$CO/.github" ]
	[ -L "$CO/.github" ]
	run ap_dest_state "$CO/.github" "$SRC" "$CTX"
	[ "$output" = repair ]
}

@test "classify: a symlink anywhere else is foreign" {
	mkdir -p "$SANDBOX_P/elsewhere"
	ln -s "$SANDBOX_P/elsewhere" "$CO/.github"
	run ap_dest_state "$CO/.github" "$SRC" "$CTX"
	[ "$output" = foreign ]
}

@test "classify: a real directory is backup-dir" {
	mkdir -p "$CO/.github"
	run ap_dest_state "$CO/.github" "$SRC" "$CTX"
	[ "$output" = backup-dir ]
}

@test "classify: a real file is backup-file" {
	printf 'x\n' >"$CO/AGENTS.md"
	run ap_dest_state "$CO/AGENTS.md" "$SRC" "$CTX"
	[ "$output" = backup-file ]
}

@test "classify: a mount point is a conflict and is never touched" {
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	# A real mount needs privileges; the decision function is stubbed so the
	# row is covered deterministically. The bind-mount test below does the
	# real thing wherever the kernel allows it.
	ap_is_mountpoint() { return 0; }

	run ap_dest_state "$CO/.github" "$SRC" "$CTX"
	[ "$output" = mountpoint ]

	run link_github
	assert_status 1
	[ "$output" = failed ]
	assert_real_dir "$CO/.github"
	[ -f "$CO/.github/keep.md" ]
}

@test "classify: a real bind mount is detected as a mount point" {
	command -v unshare >/dev/null 2>&1 || skip "unshare is not available"
	mkdir -p "$SANDBOX_P/mnt-src" "$CO/.github"
	cat >"$SANDBOX_P/probe.sh" <<'EOS'
. "$GRAFT_ROOT/lib/core.sh"
. "$GRAFT_ROOT/lib/apply.sh"
mount --bind "$MNT_SRC" "$MNT_DST" || exit 77
ap_dest_state "$MNT_DST" /nowhere /nowhere
EOS
	export MNT_SRC="$SANDBOX_P/mnt-src" MNT_DST="$CO/.github"
	run unshare -Urm --propagation private bash "$SANDBOX_P/probe.sh"
	[ "$status" -eq 0 ] || skip "unprivileged mount namespaces are unavailable"
	[ "$output" = mountpoint ]
}

# --- creating, repairing, backing up -----------------------------------------

@test "link: creates the symlink when nothing is there" {
	run link_github
	assert_status 0
	[ "$output" = created ]
	assert_symlink_to "$CO/.github" "$SRC"
	[ -f "$CO/.github/copilot-instructions.md" ]
}

@test "link: an already correct link is unchanged and writes no backup" {
	run link_github
	[ "$output" = created ]
	run link_github
	assert_status 0
	[ "$output" = unchanged ]
	run find "$CO" -maxdepth 1 -name "*$AP_BACKUP_SUFFIX*"
	[ -z "$output" ]
}

@test "link: repairs a link that points elsewhere in the context repo" {
	mkdir -p "$CTX/projects/other"
	ln -s "$CTX/projects/other" "$CO/.github"
	run link_github
	assert_status 0
	[ "$output" = repaired ]
	assert_symlink_to "$CO/.github" "$SRC"
	assert_real_dir "$CTX/projects/other"
}

@test "link: repairs a dangling symlink that points into the context repo" {
	# P2 - a dangling symlink is -L true and -e false. A classifier that asks
	# -e first calls it absent, and the following ln -s dies with File exists.
	ln -s "$CTX/projects/demo/gone" "$CO/.github"
	run link_github
	assert_status 0
	[ "$output" = repaired ]
	assert_symlink_to "$CO/.github" "$SRC"
}

@test "link: leaves a foreign symlink untouched and reports drift" {
	mkdir -p "$SANDBOX_P/elsewhere"
	ln -s "$SANDBOX_P/elsewhere" "$CO/.github"
	run link_github
	assert_status 1
	[ "$output" = skipped-foreign ]
	assert_symlink_to "$CO/.github" "$SANDBOX_P/elsewhere"
}

@test "link: backs up a real directory and every file in it survives" {
	mkdir -p "$CO/.github/workflows"
	printf 'on: push\n' >"$CO/.github/workflows/ci.yml"
	printf 'hello\n' >"$CO/.github/NOTES.md"

	run link_github
	assert_status 0
	[ "$output" = backed-up ]
	assert_symlink_to "$CO/.github" "$SRC"

	st_load
	local rec backup
	rec=$(st_by_dest "$CO/.github")
	backup=$(st_field "$rec" 7)
	assert_real_dir "$backup"
	[ "$(cat "$backup/workflows/ci.yml")" = "on: push" ]
	[ "$(cat "$backup/NOTES.md")" = hello ]
}

@test "link: backs up an empty directory" {
	mkdir -p "$CO/.github"
	run link_github
	[ "$output" = backed-up ]
	assert_symlink_to "$CO/.github" "$SRC"
	st_load
	assert_real_dir "$(st_field "$(st_by_dest "$CO/.github")" 7)"
}

@test "link: backs up a real file" {
	printf 'my own notes\n' >"$CO/AGENTS.md"
	run result demo "$CO" "$SRC/copilot-instructions.md" AGENTS.md timestamp yes warn
	assert_status 0
	[ "$output" = backed-up ]
	assert_symlink_to "$CO/AGENTS.md" "$SRC/copilot-instructions.md"
	st_load
	[ "$(cat "$(st_field "$(st_by_dest "$CO/AGENTS.md")" 7)")" = "my own notes" ]
}

# --- SPEC 4.1 backup_suffix --------------------------------------------------
#
# The key was parsed, validated and defaulted, and then nobody read it: the
# suffix was hardcoded here, so `backup_suffix = .MYSUFFIX` passed `graft check`
# and still produced `.github.graft-backup`. An accepted key that does nothing
# is worse than a rejected one, hence a test per direction.

@test "backup: the configured suffix is the name a new backup gets" {
	ap_set_backup_suffix .MYSUFFIX
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"

	run result demo "$CO" "$SRC" .github suffix yes warn
	assert_status 0
	[ "$output" = backed-up ]
	assert_symlink_to "$CO/.github" "$SRC"
	assert_real_dir "$CO/.github.MYSUFFIX"
	[ "$(cat "$CO/.github.MYSUFFIX/keep.md")" = mine ]
	assert_not_exists "$CO/.github.graft-backup"

	st_load
	[ "$(st_field "$(st_by_dest "$CO/.github")" 7)" = "$CO/.github.MYSUFFIX" ]
}

@test "backup: the configured suffix carries the timestamp mode too" {
	ap_set_backup_suffix .keepme
	mkdir -p "$CO/.github"

	run link_github
	assert_status 0
	[ "$output" = backed-up ]
	st_load
	local backup
	backup=$(st_field "$(st_by_dest "$CO/.github")" 7)
	case "$backup" in
	"$CO/.github.keepme."*) ;;
	*)
		printf 'backup ignored the suffix: %s\n' "$backup" >&2
		return 1
		;;
	esac
	assert_real_dir "$backup"
}

@test "backup: the default suffix stays .graft-backup" {
	[ "$(ap_backup_suffix)" = .graft-backup ]
	mkdir -p "$CO/.github"

	run result demo "$CO" "$SRC" .github suffix yes warn
	assert_status 0
	[ "$output" = backed-up ]
	assert_real_dir "$CO/.github.graft-backup"
}

@test "backup: a suffix with a slash, or an empty one, is refused" {
	run ap_set_backup_suffix 'sub/dir'
	assert_status 1
	run ap_set_backup_suffix ''
	assert_status 1

	# A rejected value must not have replaced the one in use.
	ap_set_backup_suffix 'sub/dir' || :
	[ "$(ap_backup_suffix)" = .graft-backup ]
}

@test "link: does not create a link inside an existing directory symlink" {
	# P1 - `ln -s src dirlink` puts the link INSIDE the directory, and plain
	# `mv new dirlink` does exactly the same. The destination must be replaced,
	# not entered.
	mkdir -p "$CTX/projects/other"
	ln -s "$CTX/projects/other" "$CO/.github"

	run link_github
	assert_status 0
	assert_symlink_to "$CO/.github" "$SRC"
	run find "$CTX/projects/other" -mindepth 1
	[ -z "$output" ]
	assert_not_exists "$SRC/github"
	assert_not_exists "$SRC/.github"
}

@test "link: a real mv without -T replaces a directory symlink without nesting" {
	# The same as the test above, but with the fallback selected by the probe
	# instead of by hand - which is what a macOS run does, and what the broken
	# probe made every run do without anybody noticing (P7).
	bsd_mv
	mkdir -p "$CTX/projects/other"
	ln -s "$CTX/projects/other" "$CO/.github"
	AP_MV_T=''

	run link_github
	assert_status 0
	[ "$output" = repaired ]
	assert_symlink_to "$CO/.github" "$SRC"
	run find "$CTX/projects/other" -mindepth 1
	[ -z "$output" ]
}

@test "link: the mv -T fallback replaces a directory symlink without nesting" {
	# BSD mv has no -T, so the fallback is the only path on macOS. It must
	# not nest either (P1), which is what forcing the probe result checks.
	mkdir -p "$CTX/projects/other"
	ln -s "$CTX/projects/other" "$CO/.github"
	AP_MV_T=1

	run link_github
	assert_status 0
	[ "$output" = repaired ]
	assert_symlink_to "$CO/.github" "$SRC"
	run find "$CTX/projects/other" -mindepth 1
	[ -z "$output" ]
}

@test "link: refuses when the checkout is the context repo itself" {
	run result demo "$CTX" "$SRC" .github timestamp yes warn
	assert_status 1
	[ "$output" = failed ]
	assert_not_exists "$CTX/.github"
}

@test "link: refuses a missing source and leaves no dangling link" {
	run result demo "$CO" "$CTX/projects/demo/nothing-here" .github timestamp yes warn
	assert_status 1
	[ "$output" = failed ]
	assert_not_exists "$CO/.github"
}

@test "link: refuses when the source lies inside the target checkout" {
	mkdir -p "$CO/shared/github"
	run result demo "$CO" "$CO/shared/github" .github timestamp yes warn
	assert_status 1
	[ "$output" = failed ]
	assert_not_exists "$CO/.github"
}

@test "link: refuses a destination that escapes the checkout" {
	run result demo "$CO" "$SRC" ../evil timestamp yes warn
	assert_status 1
	[ "$output" = failed ]
	assert_not_exists "$SANDBOX_P/evil"
}

@test "link: refuses a destination on the deny list" {
	for bad in .ssh .ssh/config .gnupg .aws .config/gh .netrc .bashrc .gitconfig; do
		run result demo "$CO" "$SRC" "$bad" timestamp yes warn
		assert_status 1
		[ "$output" = failed ]
		assert_not_exists "$CO/$bad"
	done
}

@test "link: refuses to manage .git itself" {
	run result demo "$CO" "$SRC" .git timestamp yes warn
	assert_status 1
	[ "$output" = failed ]
	assert_real_dir "$CO/.git"
}

@test "link: refuses a parent directory that is a symlink" {
	mkdir -p "$SANDBOX_P/elsewhere"
	ln -s "$SANDBOX_P/elsewhere" "$CO/.cursor"
	run result demo "$CO" "$SRC" .cursor/rules timestamp yes warn
	assert_status 1
	[ "$output" = failed ]
	assert_not_exists "$SANDBOX_P/elsewhere/rules"
}

@test "link: backup=abort refuses and changes nothing" {
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	run result demo "$CO" "$SRC" .github abort yes warn
	assert_status 1
	[ "$output" = failed ]
	assert_real_dir "$CO/.github"
	[ -f "$CO/.github/keep.md" ]
}

@test "link: --force replaces a foreign symlink and keeps it as a backup" {
	mkdir -p "$SANDBOX_P/elsewhere"
	ln -s "$SANDBOX_P/elsewhere" "$CO/.github"
	run result demo "$CO" "$SRC" .github timestamp yes force
	assert_status 0
	[ "$output" = backed-up ]
	assert_symlink_to "$CO/.github" "$SRC"
	st_load
	local backup
	backup=$(st_field "$(st_by_dest "$CO/.github")" 7)
	[ -L "$backup" ]
	assert_real_dir "$SANDBOX_P/elsewhere"
}

@test "link: a second backup gets a unique name and the first stays untouched" {
	mkdir -p "$CO/.github"
	printf 'first\n' >"$CO/.github/mark.md"
	run result demo "$CO" "$SRC" .github suffix yes warn
	[ "$output" = backed-up ]
	local first="$CO/.github$AP_BACKUP_SUFFIX"
	[ -f "$first/mark.md" ]

	# Somebody restores a real directory over the link and we link again.
	[ -L "$CO/.github" ] && rm -- "$CO/.github"
	mkdir -p "$CO/.github"
	printf 'second\n' >"$CO/.github/mark.md"
	run result demo "$CO" "$SRC" .github suffix yes warn
	[ "$output" = backed-up ]

	[ "$(cat "$first/mark.md")" = first ]
	[ "$(cat "$first.1/mark.md")" = second ]
}

@test "link: creates missing parent directories and records them in made_dirs" {
	run result demo "$CO" "$SRC" .cursor/rules timestamp yes warn
	assert_status 0
	[ "$output" = created ]
	assert_real_dir "$CO/.cursor"
	assert_symlink_to "$CO/.cursor/rules" "$SRC"
	st_load
	[ "$(st_field "$(st_by_dest "$CO/.cursor/rules")" 9)" = "$CO/.cursor" ]
}

@test "link: handles paths containing spaces, umlauts and dollar signs" {
	# P6 - everything works until someone clones into ~/My Projects.
	local co="$SANDBOX_P/My Projects/prüfung \$HOME"
	local src="$CTX/projects/mit leerzeichen/ünd \$zeichen"
	mkrepo "$co"
	mkdir -p "$src"
	printf 'ok\n' >"$src/f.md"

	run result "demo x" "$co" "$src" ".github dir" timestamp yes warn
	assert_status 0
	[ "$output" = created ]
	assert_symlink_to "$co/.github dir" "$src"
	[ "$(cat "$co/.github dir/f.md")" = ok ]

	st_load
	local rec
	rec=$(st_by_dest "$co/.github dir")
	[ "$(st_field "$rec" 4)" = "$src" ]
}

@test "link: is idempotent - second run adds no backup and no second state row" {
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"

	run link_github
	assert_status 0
	[ "$output" = backed-up ]
	st_load
	local first
	first=$(st_by_dest "$CO/.github")

	run link_github
	assert_status 0
	[ "$output" = unchanged ]

	st_load
	[ "$(st_records | wc -l)" -eq 1 ]
	[ "$(st_by_dest "$CO/.github")" = "$first" ]
	run find "$CO" -maxdepth 1 -name "*$AP_BACKUP_SUFFIX*"
	[ "$(printf '%s\n' "$output" | wc -l)" -eq 1 ]
}

@test "link: records the state row with source, backup and exclude columns" {
	mkdir -p "$CO/.github"
	run link_github
	[ "$output" = backed-up ]

	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")
	[ "$(st_field "$rec" 1)" = demo ]
	[ "$(st_field "$rec" 2)" = "$CO" ]
	[ "$(st_field "$rec" 3)" = "$CO/.github" ]
	[ "$(st_field "$rec" 4)" = "$SRC" ]
	[ "$(st_field "$rec" 5)" = symlink ]
	[ -n "$(st_field "$rec" 6)" ]
	[ -n "$(st_field "$rec" 7)" ]
	[ "$(st_field "$rec" 8)" = yes ]
}

# --- git ---------------------------------------------------------------------

@test "git: refuses to link over a path tracked by git" {
	# P4 - info/exclude does not apply to tracked paths, so a link over one
	# produces a commit that deletes every file underneath it.
	mkdir -p "$CO/.github"
	printf 'f\n' >"$CO/.github/f.md"
	git -C "$CO" add -A
	git -C "$CO" commit -qm "add .github"

	run ap_is_tracked "$CO" .github
	assert_status 0

	run link_github
	assert_status 1
	[ "$output" = skipped-tracked ]
	assert_real_dir "$CO/.github"
	[ -f "$CO/.github/f.md" ]
	run grep -c graft "$EXCLUDE"
	[ "$output" = 0 ]
}

@test "git: refuses a tracked path even with --force" {
	mkdir -p "$CO/.github"
	printf 'f\n' >"$CO/.github/f.md"
	git -C "$CO" add -A
	git -C "$CO" commit -qm "add .github"

	run result demo "$CO" "$SRC" .github timestamp yes force
	assert_status 1
	[ "$output" = skipped-tracked ]
	assert_real_dir "$CO/.github"
}

@test "git: uses the common git dir in a worktree where .git is a file" {
	# P3 - in a worktree .git is a FILE, so $repo/.git/info/exclude is wrong.
	git -C "$CO" worktree add -q "$SANDBOX_P/wt" -b feat
	[ -f "$SANDBOX_P/wt/.git" ]
	[ ! -d "$SANDBOX_P/wt/.git" ]

	run result demo "$SANDBOX_P/wt" "$SRC" .github timestamp yes warn
	assert_status 0
	[ "$output" = created ]
	assert_symlink_to "$SANDBOX_P/wt/.github" "$SRC"

	# The block belongs in the common dir, which is the main repo's .git.
	run grep -c '^\.github$' "$EXCLUDE"
	[ "$output" = 1 ]
	assert_not_exists "$SANDBOX_P/wt/.git/info"
	run git -C "$SANDBOX_P/wt" check-ignore -q -- .github
	assert_status 0
}

@test "git: uses the common git dir in a submodule where .git is a file" {
	mkrepo "$SANDBOX_P/sub"
	git -C "$CO" -c protocol.file.allow=always submodule add -q "$SANDBOX_P/sub" vendor/sub
	[ -f "$CO/vendor/sub/.git" ]

	run result demo "$CO/vendor/sub" "$SRC" .github timestamp yes warn
	assert_status 0
	[ "$output" = created ]
	local common
	common=$(ap_git_common_dir "$CO/vendor/sub")
	[ -d "$common" ]
	run grep -c '^\.github$' "$common/info/exclude"
	[ "$output" = 1 ]
}

@test "git: links without a git repository and skips the exclude" {
	mkdir -p "$SANDBOX_P/plain"
	run result demo "$SANDBOX_P/plain" "$SRC" .github timestamp yes warn
	assert_status 0
	[ "$output" = created ]
	assert_symlink_to "$SANDBOX_P/plain/.github" "$SRC"
	assert_not_exists "$SANDBOX_P/plain/.git"

	st_load
	[ "$(st_field "$(st_by_dest "$SANDBOX_P/plain/.github")" 8)" = no ]
}

@test "git: skips the exclude in a bare repository" {
	git init -q --bare "$SANDBOX_P/bare.git"
	run ap_exclude_add "$SANDBOX_P/bare.git" .github
	assert_status 1
	run result demo "$SANDBOX_P/bare.git" "$SRC" .github timestamp yes warn
	assert_status 0
	[ "$output" = created ]
	# git init writes a default info/exclude; it must stay as git left it.
	run grep -c graft "$SANDBOX_P/bare.git/info/exclude"
	[ "$output" = 0 ]
	st_load
	[ "$(st_field "$(st_by_dest "$SANDBOX_P/bare.git/.github")" 8)" = no ]
}

@test "git: writes no exclude entry when .gitignore already covers the name" {
	printf '.github\n' >"$CO/.gitignore"
	run link_github
	assert_status 0
	[ "$output" = created ]
	run grep -c graft "$EXCLUDE"
	[ "$output" = 0 ]
	st_load
	[ "$(st_field "$(st_by_dest "$CO/.github")" 8)" = no ]
}

@test "git: writes a delimited block and never a bare line" {
	printf '# my own excludes\nbuild/\n' >"$EXCLUDE"
	run link_github
	assert_status 0

	run cat "$EXCLUDE"
	assert_output_contains '# my own excludes'
	assert_output_contains 'build/'
	assert_output_contains '# graft: managed links (do not edit)'
	assert_output_contains '# graft: end'

	# The name must sit between the markers, not loose in the file.
	run ap_exclude_has "$EXCLUDE" .github
	assert_status 0
	run git -C "$CO" check-ignore -q -- .github
	assert_status 0
}

@test "git: a second destination joins the same block" {
	run link_github
	assert_status 0
	run result demo "$CO" "$SRC" AGENTS.md timestamp yes warn
	assert_status 0

	run grep -c 'graft: managed links' "$EXCLUDE"
	[ "$output" = 1 ]
	run ap_exclude_has "$EXCLUDE" .github
	assert_status 0
	run ap_exclude_has "$EXCLUDE" AGENTS.md
	assert_status 0
}

@test "git: the exclude entry is written exactly once across runs" {
	run link_github
	run link_github
	run link_github
	run grep -c '^\.github$' "$EXCLUDE"
	[ "$output" = 1 ]
	run grep -c 'graft: managed links' "$EXCLUDE"
	[ "$output" = 1 ]
	st_load
	[ "$(st_field "$(st_by_dest "$CO/.github")" 8)" = yes ]
}

@test "git: a hand-edited block is left alone instead of duplicated" {
	printf '%s\n.cursor\nbuild/\n' '# graft: managed links (do not edit)' >"$EXCLUDE"
	run ap_exclude_add "$CO" .github
	assert_status 1
	run grep -c 'graft: managed links' "$EXCLUDE"
	[ "$output" = 1 ]
	run grep -c '^\.github$' "$EXCLUDE"
	[ "$output" = 0 ]

	# The link itself still happens; only the exclude bookkeeping is skipped.
	run link_github
	assert_status 0
	[ "$output" = created ]
	st_load
	[ "$(st_field "$(st_by_dest "$CO/.github")" 8)" = no ]
}

@test "git: a multi-segment destination is excluded by its full path" {
	run result demo "$CO" "$SRC" .cursor/rules timestamp yes warn
	assert_status 0
	run ap_exclude_has "$EXCLUDE" .cursor/rules
	assert_status 0
	run git -C "$CO" check-ignore -q -- .cursor/rules
	assert_status 0
}

# --- probes ------------------------------------------------------------------

@test "probe: symlink capability is answered per directory and cached" {
	run ap_symlink_capable "$CO"
	assert_status 0
	ap_symlink_capable "$CO"
	case "$AP_SYMLINK_CACHE" in
	*"$CO"*) ;;
	*)
		printf 'cache miss: %s\n' "$AP_SYMLINK_CACHE" >&2
		return 1
		;;
	esac
	# The probe leaves nothing behind.
	run find "$CO" -maxdepth 1 -name '.graft-*'
	[ -z "$output" ]
}

@test "probe: it separates 'no symlinks here' from 'cannot write here'" {
	# Two causes that need two different fixes: one sends you to your
	# filesystem, the other to chmod. Reporting both as the same thing sends
	# half of the readers down the wrong path.
	run ap_symlink_capable "$CO/does-not-exist"
	assert_status 2 # nowhere to write at all

	mkdir -p "$CO/ro"
	chmod 500 "$CO/ro"
	run ap_symlink_capable "$CO/ro"
	chmod 700 "$CO/ro"
	assert_status 2 # write-protected, not a filesystem limitation

	run ap_symlink_capable "$CO"
	assert_status 0 # an ordinary directory on an ordinary filesystem
}

@test "probe: mv -T is detected where it really exists" {
	# Both probe names came out of $(ap_tmpname ...), whose AP_SEQ increment
	# dies with the command substitution - so they were IDENTICAL,
	# `mv -f -T -- X X` failed for that reason alone, and every machine on
	# earth looked like BSD. Guard the precondition first.
	local a b
	a=$(ap_tmpname "$CO" mvprobe-a)
	b=$(ap_tmpname "$CO" mvprobe-b)
	[ "$a" != "$b" ]

	# What this system can do, established without graft's own probe.
	local want=1
	ln -s target "$CO/.t-mv-a"
	if mv -f -T -- "$CO/.t-mv-a" "$CO/.t-mv-b" 2>/dev/null && [ -L "$CO/.t-mv-b" ]; then
		want=0
	fi
	if [ -L "$CO/.t-mv-a" ]; then rm -- "$CO/.t-mv-a"; fi
	if [ -L "$CO/.t-mv-b" ]; then rm -- "$CO/.t-mv-b"; fi

	AP_MV_T=''
	ap_mv_no_target_dir "$CO" || :
	[ "$AP_MV_T" = "$want" ]

	# On GNU coreutils that answer is not allowed to be "no -T".
	if mv --version 2>/dev/null | grep -q 'GNU coreutils'; then
		[ "$AP_MV_T" = 0 ]
	fi

	# And the probe cleans up after itself.
	run find "$CO" -maxdepth 1 -name '.graft-mvprobe*'
	[ -z "$output" ]
}

@test "probe: a mv without -T is reported as missing, not as present" {
	bsd_mv
	AP_MV_T=''
	ap_mv_no_target_dir "$CO" || :
	[ "$AP_MV_T" = 1 ]
	run find "$CO" -maxdepth 1 -name '.graft-mvprobe*'
	[ -z "$output" ]
}

# --- invariant I5 under git features that hide tracked files -----------------
#
# Both of these were found by an adversarial review: `git ls-files` in the outer
# repo answers "not tracked" for files that very much are, and graft then linked
# over them - the exact mass-deletion diff I5 exists to prevent.

@test "I5: a path tracked inside a submodule is refused, not overwritten" {
	local outer="$SANDBOX_P/outer" inner="$SANDBOX_P/inner"
	mkrepo "$inner"
	mkdir -p "$inner/docs"
	printf 'guide\n' >"$inner/docs/guide.md"
	git -C "$inner" add -A
	git -C "$inner" commit -qm docs
	mkrepo "$outer"
	git -c protocol.file.allow=always -C "$outer" submodule add -q "$inner" sub
	git -C "$outer" commit -qm "add submodule"

	# The parent repo only sees a gitlink, so it must ask the submodule itself.
	run ap_is_tracked "$outer" "sub/docs"
	[ "$status" -eq 0 ]
	[ -f "$outer/sub/docs/guide.md" ]
}

@test "I5: a tracked path whose name starts with a colon is refused" {
	local repo="$SANDBOX_P/magic"
	mkrepo "$repo"
	mkdir -p "$repo/:magic"
	printf 'x\n' >"$repo/:magic/f.md"
	git -C "$repo" add -A .
	git -C "$repo" commit -qm magic

	# Without GIT_LITERAL_PATHSPECS git reads the leading colon as pathspec
	# magic, matches nothing, and reports a tracked file as untracked.
	run ap_is_tracked "$repo" ":magic"
	[ "$status" -eq 0 ]
}

@test "deny list: a dot segment does not sneak a destination past it" {
	run ap_dest_denied ".config/./gh"
	[ "$status" -eq 0 ]
	run ap_dest_denied ".config//gh"
	[ "$status" -eq 0 ]
	run ap_dest_denied ".ssh/./config"
	[ "$status" -eq 0 ]
	run ap_dest_denied ".github/./sub"
	[ "$status" -ne 0 ]
}
