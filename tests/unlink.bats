#!/usr/bin/env bats
#
# unlink.bats - the reversal half of lib/apply.sh, plus lib/state.sh.
#
# `unlink` is the command that has to be trustworthy when everything else went
# wrong, so most of these tests describe a filesystem that disagrees with the
# recorded state and check that the filesystem wins.

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

result() { ap_link "$@" 2>/dev/null; }
link_github() { result demo "$CO" "$SRC" .github timestamp yes warn; }

# The one-word result without the diagnostics `run` would otherwise fold in.
quiet() { "$@" 2>/dev/null; }

# unlink_github - what `graft unlink` does for $CO/.github: look the record up,
# reverse it, and treat "no record at all" as nothing left to do.
unlink_github() {
	st_load
	local rec
	if ! rec=$(st_by_dest "$CO/.github"); then
		printf 'already-gone\n'
		return 0
	fi
	ap_unlink_record "$rec" 2>/dev/null
}

# --- the happy path ----------------------------------------------------------

@test "unlink: removes our symlink and forgets the record" {
	link_github
	assert_symlink_to "$CO/.github" "$SRC"

	run unlink_github
	assert_status 0
	[ "$output" = removed ]
	assert_not_exists "$CO/.github"

	st_load
	run st_by_dest "$CO/.github"
	assert_status 1
	assert_real_dir "$SRC"
}

@test "unlink: restores a backup" {
	mkdir -p "$CO/.github/workflows"
	printf 'on: push\n' >"$CO/.github/workflows/ci.yml"
	link_github

	st_load
	local backup
	backup=$(st_field "$(st_by_dest "$CO/.github")" 7)
	[ -d "$backup" ]

	run unlink_github
	assert_status 0
	[ "$output" = restored ]
	assert_real_dir "$CO/.github"
	[ "$(cat "$CO/.github/workflows/ci.yml")" = "on: push" ]
	assert_not_exists "$backup"
}

@test "unlink: never deletes a real directory, only our symlink" {
	# P5 - `rm -rf link/` follows the symlink and empties the target. graft
	# never calls rm -r at all, and only ever unlinks a path that is -L.
	link_github
	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")

	# The user replaced our link with a directory of their own.
	[ -L "$CO/.github" ] && rm -- "$CO/.github"
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"

	run ap_unlink_record "$rec"
	assert_status 1
	[ "$status" -eq 1 ]
	assert_real_dir "$CO/.github"
	[ "$(cat "$CO/.github/keep.md")" = mine ]
	# and the shared context survived, which is what P5 is really about
	[ -f "$SRC/copilot-instructions.md" ]
}

@test "unlink: leaves a symlink that points outside the context repo alone" {
	link_github
	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")

	mkdir -p "$SANDBOX_P/elsewhere"
	[ -L "$CO/.github" ] && rm -- "$CO/.github"
	ln -s "$SANDBOX_P/elsewhere" "$CO/.github"

	run ap_unlink_record "$rec"
	assert_status 1
	assert_symlink_to "$CO/.github" "$SANDBOX_P/elsewhere"
	assert_real_dir "$SANDBOX_P/elsewhere"
}

@test "unlink: removes only our exclude block and keeps user lines" {
	printf '# my own excludes\nbuild/\n*.log\n' >"$EXCLUDE"
	link_github
	run ap_exclude_has "$EXCLUDE" .github
	assert_status 0

	run unlink_github
	assert_status 0

	run cat "$EXCLUDE"
	assert_output_contains '# my own excludes'
	assert_output_contains 'build/'
	assert_output_contains '*.log'
	assert_output_lacks 'graft'
	assert_output_lacks '.github'
}

@test "unlink: keeps the block while another destination still uses it" {
	link_github
	result demo "$CO" "$SRC" AGENTS.md timestamp yes warn

	st_load
	run ap_unlink_record "$(st_by_dest "$CO/AGENTS.md")"
	assert_status 0

	run ap_exclude_has "$EXCLUDE" .github
	assert_status 0
	run ap_exclude_has "$EXCLUDE" AGENTS.md
	assert_status 1
	run grep -c 'graft: managed links' "$EXCLUDE"
	[ "$output" = 1 ]
}

@test "unlink: does not touch an exclude entry we did not write" {
	printf '.github\n' >"$EXCLUDE"
	link_github
	# check-ignore already covered the name, so we recorded exclude=no.
	st_load
	[ "$(st_field "$(st_by_dest "$CO/.github")" 8)" = no ]

	run unlink_github
	assert_status 0
	run cat "$EXCLUDE"
	assert_output_contains '.github'
}

@test "unlink: is idempotent" {
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	local before
	before=$(ls -A "$CO")
	link_github

	run unlink_github
	assert_status 0
	[ "$output" = restored ]

	# I7: the second run reaches the same end state with the same exit code.
	run unlink_github
	assert_status 0
	[ "$output" = already-gone ]
	[ "$(ls -A "$CO")" = "$before" ]
	assert_real_dir "$CO/.github"
	[ "$(cat "$CO/.github/keep.md")" = mine ]
}

@test "unlink: replaying a record over restored content refuses to act" {
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	link_github
	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")

	run quiet ap_unlink_record "$rec"
	assert_status 0
	[ "$output" = restored ]

	# The very same record a second time now finds a real directory. State is
	# a hint; the filesystem decides, and a real directory is never touched.
	run quiet ap_unlink_record "$rec"
	assert_status 1
	[ "$output" = kept-foreign ]
	[ "$(cat "$CO/.github/keep.md")" = mine ]
}

@test "unlink: a stale record whose destination is gone changes nothing" {
	link_github
	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")
	[ -L "$CO/.github" ] && rm -- "$CO/.github"

	run ap_unlink_record "$rec"
	assert_status 0
	[ "$output" = already-gone ]
	assert_not_exists "$CO/.github"

	st_load
	run st_by_dest "$CO/.github"
	assert_status 1
}

@test "unlink: a record pointing at a checkout that no longer exists is harmless" {
	link_github
	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")
	mv -- "$CO" "$SANDBOX_P/moved"

	run ap_unlink_record "$rec"
	assert_status 0
	[ "$output" = already-gone ]
	[ -d "$SANDBOX_P/moved" ]
}

@test "unlink: removes the parent directories it created" {
	result demo "$CO" "$SRC" .cursor/rules timestamp yes warn
	assert_real_dir "$CO/.cursor"

	st_load
	run ap_unlink_record "$(st_by_dest "$CO/.cursor/rules")"
	assert_status 0
	assert_not_exists "$CO/.cursor/rules"
	assert_not_exists "$CO/.cursor"
}

@test "unlink: keeps a created parent directory the user has since filled" {
	result demo "$CO" "$SRC" .cursor/rules timestamp yes warn
	printf 'mine\n' >"$CO/.cursor/notes.md"

	st_load
	run ap_unlink_record "$(st_by_dest "$CO/.cursor/rules")"
	assert_status 0
	assert_not_exists "$CO/.cursor/rules"
	assert_real_dir "$CO/.cursor"
	[ "$(cat "$CO/.cursor/notes.md")" = mine ]
}

@test "unlink: handles paths containing spaces, umlauts and dollar signs" {
	local co="$SANDBOX_P/My Projects/prüfung \$HOME"
	local src="$CTX/projects/mit leerzeichen/ünd \$zeichen"
	mkrepo "$co"
	mkdir -p "$src"
	printf 'ok\n' >"$src/f.md"
	mkdir -p "$co/.github dir"
	printf 'mine\n' >"$co/.github dir/keep.md"

	run result "demo x" "$co" "$src" ".github dir" timestamp yes warn
	[ "$output" = backed-up ]

	st_load
	run ap_unlink_record "$(st_by_dest "$co/.github dir")"
	assert_status 0
	[ "$output" = restored ]
	assert_real_dir "$co/.github dir"
	[ "$(cat "$co/.github dir/keep.md")" = mine ]
}

@test "unlink: a full round trip leaves the checkout as it was" {
	printf '# mine\nbuild/\n' >"$EXCLUDE"
	mkdir -p "$CO/.github"
	printf 'f\n' >"$CO/.github/f.md"
	local before_ls before_excl
	before_ls=$(ls -A "$CO")
	before_excl=$(cat "$EXCLUDE")

	link_github
	run unlink_github
	assert_status 0

	[ "$(ls -A "$CO")" = "$before_ls" ]
	[ "$(cat "$EXCLUDE")" = "$before_excl" ]
	[ "$(cat "$CO/.github/f.md")" = f ]
}

# --- the stateless fallback --------------------------------------------------

@test "unlink: falls back to the context-repo heuristic when the state is gone" {
	link_github
	st_load
	rm -- "$ST_FILE"
	st_init "$CTX/graft.conf"

	run ap_unlink_dest "$CO" .github "$CTX"
	assert_status 0
	[ "$output" = removed ]
	assert_not_exists "$CO/.github"
	run ap_exclude_has "$EXCLUDE" .github
	assert_status 1
}

@test "unlink: the stateless fallback restores an unambiguous backup" {
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	link_github
	rm -- "$ST_FILE"
	st_init "$CTX/graft.conf"

	run ap_unlink_dest "$CO" .github "$CTX"
	assert_status 0
	[ "$output" = restored ]
	assert_real_dir "$CO/.github"
	[ "$(cat "$CO/.github/keep.md")" = mine ]
}

@test "unlink: a backup made under a configured suffix is restored from the record" {
	ap_set_backup_suffix .MYSUFFIX
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	quiet result demo "$CO" "$SRC" .github suffix yes warn >/dev/null
	assert_real_dir "$CO/.github.MYSUFFIX"

	run unlink_github
	assert_status 0
	[ "$output" = restored ]
	[ "$(cat "$CO/.github/keep.md")" = mine ]
	assert_not_exists "$CO/.github.MYSUFFIX"
}

@test "unlink: the stateless fallback finds a backup named with the configured suffix" {
	# Without state the suffix is the only thing that identifies a backup, so
	# ap_unlink_dest has to search for the very same one ap_link wrote.
	ap_set_backup_suffix .MYSUFFIX
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	quiet result demo "$CO" "$SRC" .github suffix yes warn >/dev/null
	rm -- "$ST_FILE"
	st_init "$CTX/graft.conf"

	run ap_unlink_dest "$CO" .github "$CTX"
	assert_status 0
	[ "$output" = restored ]
	assert_real_dir "$CO/.github"
	[ "$(cat "$CO/.github/keep.md")" = mine ]
}

@test "unlink: the stateless fallback leaves a backup with a different suffix alone" {
	# Somebody changed backup_suffix between the two runs. Guessing which of
	# the neighbouring directories was ours would move a stranger's data onto
	# a path the user is still using, so the link goes and the backup stays.
	ap_set_backup_suffix .MYSUFFIX
	mkdir -p "$CO/.github"
	printf 'mine\n' >"$CO/.github/keep.md"
	quiet result demo "$CO" "$SRC" .github suffix yes warn >/dev/null
	rm -- "$ST_FILE"
	st_init "$CTX/graft.conf"
	ap_set_backup_suffix .OTHER

	run ap_unlink_dest "$CO" .github "$CTX"
	assert_status 0
	[ "$output" = removed ]
	assert_not_exists "$CO/.github"
	assert_real_dir "$CO/.github.MYSUFFIX"
	[ "$(cat "$CO/.github.MYSUFFIX/keep.md")" = mine ]
}

@test "unlink: the stateless fallback refuses a foreign symlink" {
	mkdir -p "$SANDBOX_P/elsewhere"
	ln -s "$SANDBOX_P/elsewhere" "$CO/.github"

	run quiet ap_unlink_dest "$CO" .github "$CTX"
	assert_status 1
	[ "$output" = kept-foreign ]
	assert_symlink_to "$CO/.github" "$SANDBOX_P/elsewhere"
}

# --- state -------------------------------------------------------------------

@test "state: a record survives a save and load round trip" {
	st_add demo "$CO" "$CO/.github" "$SRC" symlink "$CO/.github.bak" yes "$CO/.cursor"
	st_save

	st_init "$CTX/graft.conf"
	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")
	[ "$(st_field "$rec" 1)" = demo ]
	[ "$(st_field "$rec" 7)" = "$CO/.github.bak" ]
	[ "$(st_field "$rec" 9)" = "$CO/.cursor" ]
}

@test "state: st_add replaces the record for the same destination" {
	st_add demo "$CO" "$CO/.github" "$SRC" symlink - no -
	st_add demo "$CO" "$CO/.github" "$SRC" symlink "$CO/b" yes -
	st_save
	st_load
	[ "$(st_records | wc -l)" -eq 1 ]
	[ "$(st_field "$(st_by_dest "$CO/.github")" 7)" = "$CO/b" ]
}

@test "state: an empty field round trips as empty, not as a dash" {
	st_add demo "$CO" "$CO/.github" "$SRC" symlink '' no ''
	st_save
	st_load
	local rec
	rec=$(st_by_dest "$CO/.github")
	[ -z "$(st_field "$rec" 7)" ]
	[ -z "$(st_field "$rec" 9)" ]
}

@test "state: st_records filters by target" {
	st_add demo "$CO" "$CO/.github" "$SRC" symlink - yes -
	st_add other "$CO" "$CO/.cursor" "$SRC" symlink - yes -
	[ "$(st_records | wc -l)" -eq 2 ]
	[ "$(st_records demo | wc -l)" -eq 1 ]
	[ "$(st_field "$(st_records other)" 3)" = "$CO/.cursor" ]
}

@test "state: st_prune drops records whose destination is gone" {
	link_github
	st_add ghost "$CO" "$CO/gone" "$SRC" symlink - no -
	st_prune
	[ "$(st_records | wc -l)" -eq 1 ]
	run st_by_dest "$CO/.github"
	assert_status 0
}

@test "state: st_prune keeps a dangling symlink, which is still ours" {
	ln -s "$CTX/projects/demo/gone" "$CO/.github"
	st_add demo "$CO" "$CO/.github" "$SRC" symlink - no -
	st_prune
	[ "$(st_records | wc -l)" -eq 1 ]
}

@test "state: an unknown schema version is ignored instead of fatal" {
	link_github
	st_load
	printf '#graft-state\t99\t%s\n' "$CTX/graft.conf" >"$ST_FILE"
	printf 'garbage\n' >>"$ST_FILE"

	run st_load
	assert_status 0
	st_load 2>/dev/null
	[ -z "$ST_DATA" ]
}

@test "state: a state file belonging to another config is ignored" {
	link_github
	st_load
	local rec
	rec=$(st_records)
	{
		printf '#graft-state\t1\t%s\n' "$SANDBOX_P/other/graft.conf"
		printf '%s\n' "$rec"
	} >"$ST_FILE"

	st_load 2>/dev/null
	[ -z "$ST_DATA" ]
}

@test "state: two configs never share a state file" {
	mkctx "$SANDBOX_P/ctx2"
	printf '[defaults]\n' >"$SANDBOX_P/ctx2/graft.conf"
	local a b
	a=$(st_state_path "$CTX/graft.conf")
	b=$(st_state_path "$SANDBOX_P/ctx2/graft.conf")
	[ "$a" != "$b" ]
	case "$a" in "$XDG_STATE_HOME"/graft/*) ;; *) return 1 ;; esac
}
