# shellcheck shell=bash
#
# state.sh - the on-disk record of what graft created on foreign directories.
#
# State is a *hint*, never the truth. Every consumer re-checks the filesystem
# before acting on a record; a record that disagrees with reality loses. What
# state buys us is knowing which backup belongs to which destination and which
# exclude block was ours - facts the filesystem cannot tell us afterwards.
#
# Depends on core.sh only. Must stay bash 3.2 compatible: the record set is a
# newline-separated TSV string, not an associative array.

# --- format ------------------------------------------------------------------
# Line 1  #graft-state <TAB> <schema> <TAB> <config-path>
# Line 2  column names, commented
# Line n  target checkout dest source mode created_utc backup exclude made_dirs
#
# `dest` is stored as an ABSOLUTE path. It is the primary key: one destination
# can only ever be owned by one link spec, and an absolute key stays unique
# across checkouts.

ST_KIND='#graft-state'
ST_SCHEMA=1
ST_COLUMNS='#target	checkout	dest	source	mode	created_utc	backup	exclude	made_dirs'

ST_FILE=''  # absolute path of the state file
ST_CONF=''  # absolute path of the graft.conf this state belongs to
ST_DATA=''  # records, one per line, each line terminated by a newline
ST_WARNED=0 # a broken state file warns once per run, never twice

# st_state_path <conf-path> - where the state for this config lives.
st_state_path() {
	local conf id
	conf=$(gr_abspath "$1")
	id=$(gr_config_id "$conf")
	printf '%s/%s/links.tsv\n' "$(gr_xdg_state)" "$id"
}

# st_init <conf-path> - point the module at a config without reading anything.
st_init() {
	ST_CONF=$(gr_abspath "$1")
	ST_FILE=$(st_state_path "$ST_CONF")
	ST_DATA=''
}

# st_load [conf-path] - read the state file into ST_DATA.
#
# A state file we cannot understand is ignored and rebuilt, never fatal: a
# format problem must not stop the tool from starting (SPEC 3.1).
st_load() {
	[ $# -gt 0 ] && st_init "$1"
	ST_DATA=''
	[ -n "$ST_FILE" ] || return 1
	[ -f "$ST_FILE" ] || return 0

	local header kind ver conf line
	IFS= read -r header <"$ST_FILE" || return 0
	kind=$(printf '%s\n' "$header" | cut -f1)
	ver=$(printf '%s\n' "$header" | cut -f2)
	conf=$(printf '%s\n' "$header" | cut -f3)

	if [ "$kind" != "$ST_KIND" ] || [ "$ver" != "$ST_SCHEMA" ]; then
		st_warn_once "unreadable state file, starting a fresh one: $(gr_clean "$ST_FILE")"
		return 0
	fi
	# The config id is a short hash, so a collision is possible. The full path
	# in the header is what actually decides ownership.
	if [ -n "$conf" ] && [ "$conf" != "$ST_CONF" ]; then
		st_warn_once "state file belongs to $(gr_clean "$conf"), ignoring it"
		return 0
	fi

	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in '#'* | '') continue ;; esac
		ST_DATA="$ST_DATA$line
"
	done <"$ST_FILE"
	return 0
}

st_warn_once() {
	[ "$ST_WARNED" = 1 ] && return 0
	ST_WARNED=1
	gr_warn "$*"
}

# st_save - atomic rewrite of the state file (SPEC 3.1).
st_save() {
	[ -n "$ST_FILE" ] || return 1
	{
		printf '%s\t%s\t%s\n' "$ST_KIND" "$ST_SCHEMA" "$ST_CONF"
		printf '%s\n' "$ST_COLUMNS"
		printf '%s' "$ST_DATA"
	} | gr_atomic_write "$ST_FILE"
}

# st_field <record> <column-number> - one decoded field of a record.
st_field() {
	local raw
	raw=$(printf '%s\n' "$1" | cut -f"$2")
	gr_tsv_unescape "$raw"
}

# st_add <target> <checkout> <dest> <source> <mode> <backup> <exclude> <made_dirs>
#
# Replaces any record for the same destination, which is what makes a second
# run add no second line (I7). The creation timestamp of the first record is
# carried over, so an idempotent run does not rewrite history.
st_add() {
	local target="$1" checkout="$2" dest="${3%/}" source="$4" mode="$5"
	local backup="$6" exclude="$7" made="$8"
	local prev created=''

	if prev=$(st_by_dest "$dest"); then
		created=$(st_field "$prev" 6)
	fi
	[ -n "$created" ] || created=$(gr_utc_now)
	st_forget "$dest" || :

	ST_DATA="$ST_DATA$(
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
			"$(gr_tsv_escape "$target")" \
			"$(gr_tsv_escape "$checkout")" \
			"$(gr_tsv_escape "$dest")" \
			"$(gr_tsv_escape "$source")" \
			"$(gr_tsv_escape "$mode")" \
			"$(gr_tsv_escape "$created")" \
			"$(gr_tsv_escape "$backup")" \
			"$(gr_tsv_escape "$exclude")" \
			"$(gr_tsv_escape "$made")"
	)
"
}

# st_by_dest <dest> - print the record for a destination, or return 1.
st_by_dest() {
	local want="${1%/}" line
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(st_field "$line" 3)" = "$want" ]; then
			printf '%s\n' "$line"
			return 0
		fi
	done <<EOF
$ST_DATA
EOF
	return 1
}

# st_forget <dest> - drop the record for a destination. 1 if there was none.
st_forget() {
	local want="${1%/}" line kept='' found=1
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ "$(st_field "$line" 3)" = "$want" ]; then
			found=0
			continue
		fi
		kept="$kept$line
"
	done <<EOF
$ST_DATA
EOF
	ST_DATA="$kept"
	return "$found"
}

# st_records [target] - every record, optionally filtered by target name.
st_records() {
	local want="${1:-}" line
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		if [ -n "$want" ] && [ "$(st_field "$line" 1)" != "$want" ]; then
			continue
		fi
		printf '%s\n' "$line"
	done <<EOF
$ST_DATA
EOF
}

# st_prune - drop records whose destination no longer exists.
#
# -L before -e: a dangling symlink is still a destination we own and must not
# be pruned away (P2). Always returns 0: "nothing to prune" is not a failure,
# and a caller running under set -e must not die of it.
st_prune() {
	local line kept='' dest
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		dest=$(st_field "$line" 3)
		if [ -L "$dest" ] || [ -e "$dest" ]; then
			kept="$kept$line
"
		fi
	done <<EOF
$ST_DATA
EOF
	ST_DATA="$kept"
	return 0
}
