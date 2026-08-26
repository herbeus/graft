# shellcheck shell=bash
#
# apply.sh - the only module that changes a foreign directory.
#
# Everything here follows docs/SPEC.md section 6 and guards the six bugs in
# docs/pitfalls.md. Two rules dominate the code and explain most of its shape:
#
#   * nothing is ever deleted (I3). The single deletion site in this file is
#     `rm -- "$p"` guarded by `[ -L "$p" ]`. User data is moved to a backup.
#   * `-L` is asked before `-e` (P2), because a dangling symlink is not `-e`.
#
# Depends on core.sh and state.sh. Nothing here prints a headline or exits;
# every function returns a status and one machine-readable word.

AP_CTX_ROOT=''                   # resolved context repo, see ap_set_context
AP_BACKUP_SUFFIX='.graft-backup' # SPEC 4.1 backup_suffix
AP_SYMLINK_CACHE=''              # "<dir>\t<0|1>" lines, one probe per directory
AP_MV_T=''                       # '', 0 = mv -T works, 1 = it does not
AP_SEQ=0                         # makes temporary names unique within a run
AP_LAST_ERROR=''                 # why the last call returned "failed"
AP_TAB=$(printf '\t')

AP_EX_BEGIN='# graft: managed links (do not edit)'
AP_EX_END='# graft: end'

# Destinations we refuse to manage even if a config asks for it (SPEC 4.3).
# Checked again here and not only at config time, because apply.sh is the last
# place before the filesystem and a plan can be built by anything.
AP_DENY='.git .ssh .gnupg .aws .config/gh .netrc .bashrc .zshrc .profile .bash_profile .gitconfig'

# ap_set_context <ctx-root> - the context repo every source must live inside.
# Resolved once: containment (I4) is decided on physical paths so that a
# symlink cannot be used to step outside.
ap_set_context() {
	AP_CTX_ROOT=$(gr_realpath "$1") || return 1
	AP_CTX_ROOT=${AP_CTX_ROOT%/}
}

ap_context() { printf '%s\n' "${AP_CTX_ROOT:-${CFG_CTX_ROOT:-}}"; }

ap_fail() {
	AP_LAST_ERROR="$*"
	gr_err "$*"
}

# --- capability probes -------------------------------------------------------

# ap_symlink_capable <dir> - can we create a symlink in this directory?
# Probed once per directory (SPEC 9.4); an exFAT or SMB mount fails here rather
# than half-way through a run.
ap_symlink_capable() {
	local dir="${1%/}" line d rc probe
	while IFS= read -r line || [ -n "$line" ]; do
		[ -n "$line" ] || continue
		d=${line%"$AP_TAB"*}
		rc=${line##*"$AP_TAB"}
		[ "$d" = "$dir" ] && return "$rc"
	done <<EOF
$AP_SYMLINK_CACHE
EOF

	rc=1
	if [ -d "$dir" ]; then
		probe=$(ap_tmpname "$dir" probe)
		if ln -s -- .graft-probe "$probe" 2>/dev/null; then
			rc=0
			[ -L "$probe" ] && rm -- "$probe"
		fi
	fi
	AP_SYMLINK_CACHE="$AP_SYMLINK_CACHE$dir$AP_TAB$rc
"
	return "$rc"
}

# ap_tmpname <dir> <kind> - a name in <dir> that nothing else in this run uses.
ap_tmpname() {
	AP_SEQ=$((AP_SEQ + 1))
	printf '%s/.graft-%s.%s.%s\n' "${1%/}" "$2" "$$" "$AP_SEQ"
}

# ap_mv_no_target_dir <dir> - does `mv -T` exist here?
#
# It matters more than it looks: `mv -f -- new dest` follows dest when dest is a
# symlink to a directory and moves `new` INSIDE it - the same trap as P1, one
# command later. `mv -T` renames over the link itself and is atomic. Where it is
# missing (BSD mv) we fall back to removing the symlink first, which is not
# atomic but never nests.
ap_mv_no_target_dir() {
	local dir="${1:-.}" a b
	[ -n "$AP_MV_T" ] && return "$AP_MV_T"
	AP_MV_T=1
	[ -d "$dir" ] || return 1
	a=$(ap_tmpname "$dir" mvprobe)
	b=$(ap_tmpname "$dir" mvprobe)
	if ln -s -- .graft-probe "$a" 2>/dev/null; then
		if mv -f -T -- "$a" "$b" 2>/dev/null && [ -L "$b" ]; then
			AP_MV_T=0
		fi
		[ -L "$a" ] && rm -- "$a"
		[ -L "$b" ] && rm -- "$b"
	fi
	return "$AP_MV_T"
}

# --- classification ----------------------------------------------------------

# ap_is_mountpoint <dir> - conservative: "unknown" means "not a mountpoint".
#
# Being wrong in the other direction would be worse than useless, and a real
# mountpoint cannot be renamed anyway, so the backup step would fail loudly.
ap_is_mountpoint() {
	local d="${1%/}" rp m
	[ -d "$d" ] || return 1
	rp=$(gr_realpath "$d") || rp="$d"
	if gr_have mountpoint; then
		mountpoint -q -- "$d" && return 0
		return 1
	fi
	if m=$(stat -c '%m' -- "$d" 2>/dev/null) && [ -n "$m" ]; then
		[ "$m" = "$rp" ] && return 0
		return 1
	fi
	m=$(df -P -- "$d" 2>/dev/null | awk 'NR==2 { for (i = 1; i < 6; i++) $i = ""; sub(/^ +/, ""); print }')
	[ -n "$m" ] && [ "$m" = "$rp" ] && return 0
	return 1
}

# ap_dest_state <dest> <src-resolved> <ctx-root> - classify without touching.
# Prints exactly one of:
#   absent unchanged repair foreign backup-dir backup-file mountpoint
ap_dest_state() {
	local dest="${1%/}" src="$2" ctx="${3%/}" lex='' res=''

	# P2: -L first. A dangling symlink answers false to -e, and a classifier
	# that believes that will call `ln -s` on an existing path.
	if [ -L "$dest" ]; then
		lex=$(gr_link_target "$dest") || lex=''
		if [ -e "$dest" ]; then
			res=$(gr_realpath "$dest") || res=''
			if [ -n "$res" ] && [ "$res" = "$src" ]; then
				printf 'unchanged\n'
				return 0
			fi
			if [ -n "$res" ] && [ -n "$ctx" ] && gr_is_inside "$res" "$ctx"; then
				printf 'repair\n'
				return 0
			fi
		fi
		# Dangling, or resolving elsewhere: the link text still tells us
		# whether it was aimed at our context repo, and that is repairable.
		if [ -n "$lex" ] && [ -n "$ctx" ] && gr_is_inside "$lex" "$ctx"; then
			printf 'repair\n'
			return 0
		fi
		printf 'foreign\n'
		return 0
	fi

	if [ ! -e "$dest" ]; then
		printf 'absent\n'
		return 0
	fi
	if [ -d "$dest" ] && ap_is_mountpoint "$dest"; then
		printf 'mountpoint\n'
		return 0
	fi
	if [ -d "$dest" ]; then
		printf 'backup-dir\n'
	else
		printf 'backup-file\n'
	fi
	return 0
}

# ap_dest_denied <dest-rel> - 0 when this destination is off limits.
ap_dest_denied() {
	local d="${1#./}" n
	d=${d%/}
	# shellcheck disable=SC2086 # AP_DENY is a whitespace list on purpose
	for n in $AP_DENY; do
		[ "$d" = "$n" ] && return 0
		case "$d" in "$n"/*) return 0 ;; esac
	done
	return 1
}

# --- git ---------------------------------------------------------------------

# ap_git_common_dir <checkout> - the shared git dir, absolute.
#
# P3: in a worktree and in a submodule `.git` is a FILE containing a gitdir
# pointer, and the per-worktree git dir has no info/exclude that git reads.
# `rev-parse --git-common-dir` is the only correct answer, and it can come back
# relative to the checkout.
ap_git_common_dir() {
	local checkout="$1" d
	gr_have git || return 1
	[ -d "$checkout" ] || return 1
	d=$(git -C "$checkout" rev-parse --git-common-dir 2>/dev/null) || return 1
	[ -n "$d" ] || return 1
	case "$d" in /*) ;; *) d="$checkout/$d" ;; esac
	gr_abspath "$d"
}

# ap_repo_root <checkout> - the worktree root, but only if it IS the checkout.
#
# Returns 1 for a bare repository (it has no worktree) and for a directory that
# merely lies inside some other repository - writing our exclude block into a
# parent project's git dir would be a surprise nobody asked for.
ap_repo_root() {
	local checkout="$1" top co
	gr_have git || return 1
	[ -d "$checkout" ] || return 1
	top=$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) || return 1
	[ -n "$top" ] || return 1
	top=$(gr_realpath "$top") || return 1
	co=$(gr_realpath "$checkout") || return 1
	[ "$top" = "$co" ] || return 1
	printf '%s\n' "$top"
}

# ap_is_tracked <checkout> <dest-rel> - 0 when git tracks the path (I5).
#
# P4: `.git/info/exclude` provably does not apply to tracked paths, so linking
# over one produces a commit that deletes every file under it. There is no
# override flag, by design; `graft adopt` is the way out.
ap_is_tracked() {
	local checkout="$1" rel="${2#./}"
	rel=${rel%/}
	gr_have git || return 1
	[ -n "$rel" ] || return 1
	git -C "$checkout" ls-files --error-unmatch -- "$rel" >/dev/null 2>&1
}

# ap_exclude_file <checkout> - path of the exclude file we may manage, or 1.
ap_exclude_file() {
	local checkout="$1" gitdir
	ap_repo_root "$checkout" >/dev/null || return 1
	gitdir=$(ap_git_common_dir "$checkout") || return 1
	printf '%s/info/exclude\n' "$gitdir"
}

# ap_exclude_has <file> <name> - is <name> inside OUR block?
ap_exclude_has() {
	local f="$1" name="$2" line inblock=0
	[ -f "$f" ] || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		"$AP_EX_BEGIN")
			inblock=1
			continue
			;;
		"$AP_EX_END")
			inblock=0
			continue
			;;
		esac
		if [ "$inblock" = 1 ] && [ "$line" = "$name" ]; then
			return 0
		fi
	done <"$f"
	return 1
}

# ap_exclude_add <checkout> <name> - idempotent, delimited block (SPEC 6.8).
#
# Returns 0 when the name is covered by a block of ours (added now or earlier),
# 1 when we deliberately wrote nothing: no repository, a bare repository, or
# the name is already ignored by something the user controls.
#
# Order matters. Our own block is inspected BEFORE asking check-ignore,
# otherwise the second run sees the entry we wrote ourselves, concludes "already
# ignored", records exclude=no, and unlink leaves the block behind forever.
ap_exclude_add() {
	local checkout="$1" name="${2#./}" excl line content='' inblock=0 added=0
	name=${name%/}
	[ -n "$name" ] || return 1
	excl=$(ap_exclude_file "$checkout") || return 1

	ap_exclude_has "$excl" "$name" && return 0
	git -C "$checkout" check-ignore -q -- "$name" 2>/dev/null && return 1

	if [ -f "$excl" ]; then
		while IFS= read -r line || [ -n "$line" ]; do
			if [ "$inblock" = 1 ] && [ "$line" = "$AP_EX_END" ]; then
				content="$content$name
"
				added=1
				inblock=0
			elif [ "$line" = "$AP_EX_BEGIN" ]; then
				# A second opener before the closer means the block was
				# edited by hand. We do not know what it delimits any
				# more, so we write nothing at all.
				[ "$inblock" = 1 ] && return 1
				inblock=1
			fi
			content="$content$line
"
		done <"$excl"
		# An opener without a closer: same story.
		[ "$inblock" = 1 ] && return 1
	fi
	if [ "$added" = 0 ]; then
		content="$content$AP_EX_BEGIN
$name
$AP_EX_END
"
	fi
	mkdir -p -- "$(dirname -- "$excl")" || return 1
	printf '%s' "$content" | gr_atomic_write "$excl" || return 1
	return 0
}

# ap_exclude_remove <checkout> <name> - take one name out of our block.
#
# Only ever touches lines between our markers. When the block ends up empty the
# markers go too; user lines are copied through untouched. An unterminated block
# means someone edited the file by hand - we then change nothing at all.
ap_exclude_remove() {
	local checkout="$1" name="${2#./}" excl line content='' body='' inblock=0 hit=1
	name=${name%/}
	[ -n "$name" ] || return 1
	excl=$(ap_exclude_file "$checkout") || return 1
	[ -f "$excl" ] || return 1

	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$line" = "$AP_EX_BEGIN" ]; then
			# Nested openers mean a hand-edited file; leave it alone.
			[ "$inblock" = 1 ] && return 1
			inblock=1
			body=''
			continue
		fi
		if [ "$inblock" = 1 ] && [ "$line" = "$AP_EX_END" ]; then
			inblock=0
			if [ -n "$body" ]; then
				content="$content$AP_EX_BEGIN
$body$AP_EX_END
"
			fi
			continue
		fi
		if [ "$inblock" = 1 ]; then
			if [ "$line" = "$name" ]; then
				hit=0
				continue
			fi
			body="$body$line
"
			continue
		fi
		content="$content$line
"
	done <"$excl"

	[ "$inblock" = 1 ] && return 1
	[ "$hit" = 0 ] || return 1
	printf '%s' "$content" | gr_atomic_write "$excl" || return 1
	return 0
}

# --- backups and parents -----------------------------------------------------

# ap_backup_path <dest> <mode> - a name that does not exist yet (SPEC 6.7).
# A backup never overwrites an older backup; the counter guarantees that even
# two runs inside the same second stay apart.
ap_backup_path() {
	local dest="${1%/}" mode="$2" base cand n=0
	case "$mode" in
	timestamp) base="$dest$AP_BACKUP_SUFFIX.$(date -u +%Y%m%dT%H%M%SZ)" ;;
	*) base="$dest$AP_BACKUP_SUFFIX" ;;
	esac
	cand="$base"
	while [ -L "$cand" ] || [ -e "$cand" ]; do
		n=$((n + 1))
		[ "$n" -gt 999 ] && return 1
		cand="$base.$n"
	done
	printf '%s\n' "$cand"
}

# ap_make_parents <checkout> <dir> - create missing parents of a destination.
# Prints the ':'-separated list of directories we actually created, shallowest
# first, so unlink can rmdir them again in reverse.
ap_make_parents() {
	local root="${1%/}" dir="${2%/}" p missing='' list=''
	p="$dir"
	while [ "$p" != "$root" ] && gr_is_inside "$p" "$root"; do
		if [ -L "$p" ]; then
			# A symlinked parent would silently write into its target.
			return 1
		fi
		[ -d "$p" ] && break
		[ -e "$p" ] && return 1
		missing="$p
$missing"
		p=$(dirname -- "$p")
	done
	while IFS= read -r p || [ -n "$p" ]; do
		[ -n "$p" ] || continue
		mkdir -- "$p" 2>/dev/null || return 1
		list="$list${list:+:}$p"
	done <<EOF
$missing
EOF
	printf '%s\n' "$list"
}

# ap_split_colon <list> - one item per line. The IFS change is confined to this
# function so that no caller has to remember to restore it.
ap_split_colon() {
	local list="$1" item
	local IFS=':'
	set -f
	# shellcheck disable=SC2086 # deliberate splitting on ':'
	set -- $list
	set +f
	for item in "$@"; do
		[ -n "$item" ] && printf '%s\n' "$item"
	done
	return 0
}

# ap_merge_dirs <old-list> <new-list> - union of two ':'-separated lists.
ap_merge_dirs() {
	local out="$1" d
	while IFS= read -r d || [ -n "$d" ]; do
		[ -n "$d" ] || continue
		case ":$out:" in *":$d:"*) continue ;; esac
		out="$out${out:+:}$d"
	done <<EOF
$(ap_split_colon "$2")
EOF
	printf '%s\n' "$out"
}

# ap_rmdir_list <checkout> <list> - remove our created parents, deepest first.
# rmdir and never rm -r: a directory the user has since filled simply stays.
ap_rmdir_list() {
	local root="${1%/}" d rev=''
	[ -n "$2" ] || return 0
	while IFS= read -r d || [ -n "$d" ]; do
		[ -n "$d" ] || continue
		rev="$d
$rev"
	done <<EOF
$(ap_split_colon "$2")
EOF
	while IFS= read -r d || [ -n "$d" ]; do
		[ -n "$d" ] || continue
		[ -L "$d" ] && continue
		[ -d "$d" ] || continue
		[ "$d" = "$root" ] && continue
		gr_is_inside "$d" "$root" || continue
		rmdir -- "$d" 2>/dev/null || :
	done <<EOF
$rev
EOF
	return 0
}

# --- the atomic swap ---------------------------------------------------------

# ap_replace <tmp-link> <dest> - move our fresh link onto the destination.
#
# P1: `ln -s src dest` where dest is a symlink to a directory creates the link
# INSIDE that directory. So the link is always born under a temporary name and
# renamed over the destination - which is also how the swap becomes atomic.
# `mv` alone has the very same trap, hence -T where it exists.
ap_replace() {
	local tmp="${1%/}" dest="${2%/}"
	if ap_mv_no_target_dir "$(dirname -- "$dest")"; then
		mv -f -T -- "$tmp" "$dest"
		return
	fi
	# Fallback: the only thing we may unlink is a symlink (I3), and a real
	# destination has been moved to a backup long before we get here.
	if [ -L "$dest" ]; then
		rm -- "$dest"
	fi
	if [ -L "$dest" ] || [ -e "$dest" ]; then
		return 1
	fi
	mv -f -- "$tmp" "$dest"
}

# --- link --------------------------------------------------------------------

# ap_link <target> <checkout> <src> <dest-rel> <backup-mode> <exclude> <foreign> [ctx-root]
#
# One link, start to finish, per SPEC section 6. Prints exactly one of:
#   created repaired unchanged backed-up skipped-foreign skipped-tracked failed
# Returns 0 when the desired state is reached, 1 otherwise. Never exits.
ap_link() {
	local target="$1" checkout="$2" src="$3" rel="$4"
	local bmode="${5:-timestamp}" exclmode="${6:-yes}" foreign="${7:-warn}"
	local ctx="${8:-}"
	local src_res co_res dest parent state result backup='-' made=''

	AP_LAST_ERROR=''
	[ -n "$ctx" ] || ctx=$(ap_context)
	ctx=${ctx%/}

	# 1. the source must exist. A dangling link is worse than no link: every
	#    agent tool then sees .github and finds nothing inside it.
	if ! src_res=$(gr_realpath "$src"); then
		ap_fail "source does not exist: $(gr_clean "$src")"
		ap__say failed
		return 1
	fi
	if ! co_res=$(gr_realpath "$checkout") || [ ! -d "$co_res" ]; then
		ap_fail "checkout is not a directory: $(gr_clean "$checkout")"
		ap__say failed
		return 1
	fi
	if [ -z "$ctx" ]; then
		ap_fail "no context repo set - call ap_set_context first"
		ap__say failed
		return 1
	fi

	# 2. containment (I4) on resolved paths, plus the deny list.
	if [ "$src_res" = "$ctx" ] || ! gr_is_inside "$src_res" "$ctx"; then
		ap_fail "source escapes the context repo: $(gr_clean "$src")"
		ap__say failed
		return 1
	fi
	rel=${rel#./}
	rel=${rel%/}
	case "$rel" in
	'' | /* | '~'*)
		ap_fail "destination must be a relative path: $(gr_clean "$4")"
		ap__say failed
		return 1
		;;
	esac
	if gr_has_dotdot "$rel" || ap_dest_denied "$rel"; then
		ap_fail "refusing destination: $(gr_clean "$rel")"
		ap__say failed
		return 1
	fi
	dest=$(gr_abspath "$co_res/$rel")
	dest=${dest%/}
	if [ "$dest" = "$co_res" ] || ! gr_is_inside "$dest" "$co_res"; then
		ap_fail "destination escapes the checkout: $(gr_clean "$rel")"
		ap__say failed
		return 1
	fi
	# A checkout that is (or lives in) the context repo would make graft link
	# the context repo into itself, and the next run would follow that link.
	if [ "$co_res" = "$ctx" ] || gr_is_inside "$src_res" "$co_res" || gr_is_inside "$dest" "$ctx"; then
		ap_fail "circular link: source and destination are in the same repo"
		ap__say failed
		return 1
	fi

	# 3. tracked destinations are refused, with no override (I5, P4).
	if ap_is_tracked "$co_res" "$rel"; then
		ap__say skipped-tracked
		return 1
	fi

	# 5. classify (step 4, the symlink probe, needs the parent to exist and so
	#    happens further down).
	state=$(ap_dest_state "$dest" "$src_res" "$ctx")
	case "$state" in
	mountpoint)
		ap_fail "$(gr_clean "$dest") is a mount point - not touching it"
		ap__say failed
		return 1
		;;
	unchanged)
		ap_record "$target" "$co_res" "$dest" "$rel" "$src_res" '-' "$exclmode" ''
		ap__say unchanged
		return 0
		;;
	foreign)
		# warn and abort look identical from here: both leave the link
		# exactly as it is and report drift. Whether the run continues
		# afterwards is the caller's decision, not ours. Only --force
		# (passed through as "force") replaces it - and then it is moved
		# to a backup, because --force never suppresses backups.
		if [ "$foreign" != force ]; then
			ap__say skipped-foreign
			return 1
		fi
		;;
	esac

	parent=$(dirname -- "$dest")
	if ! made=$(ap_make_parents "$co_res" "$parent"); then
		ap_fail "cannot create parent directories for $(gr_clean "$rel")"
		ap__say failed
		return 1
	fi

	# 4. symlinks must actually work here.
	if ! ap_symlink_capable "$parent"; then
		ap_rmdir_list "$co_res" "$made"
		ap_fail "the filesystem at $(gr_clean "$parent") does not support symlinks"
		ap__say failed
		return 1
	fi

	# 7. move existing content aside. Never a delete, not even with --force:
	#    a foreign symlink is somebody's decision and is restorable.
	case "$state" in
	backup-dir | backup-file | foreign)
		if [ "$bmode" = abort ]; then
			ap_rmdir_list "$co_res" "$made"
			ap_fail "$(gr_clean "$dest") exists and backup=abort"
			ap__say failed
			return 1
		fi
		if ! backup=$(ap_backup_path "$dest" "$bmode") || ! mv -- "$dest" "$backup"; then
			ap_rmdir_list "$co_res" "$made"
			ap_fail "cannot back up $(gr_clean "$dest")"
			ap__say failed
			return 1
		fi
		result=backed-up
		;;
	repair) result=repaired ;;
	*) result=created ;;
	esac

	# 6. create at a temporary name, then rename over the destination.
	local tmp
	tmp=$(ap_tmpname "$parent" link)
	if ! ln -s -- "$src_res" "$tmp"; then
		ap_fail "cannot create a symlink in $(gr_clean "$parent")"
		ap__say failed
		return 1
	fi
	if ! ap_replace "$tmp" "$dest"; then
		[ -L "$tmp" ] && rm -- "$tmp"
		ap_fail "cannot place the link at $(gr_clean "$dest")"
		ap__say failed
		return 1
	fi

	# 8. + 9. exclude block and state.
	ap_record "$target" "$co_res" "$dest" "$rel" "$src_res" "$backup" "$exclmode" "$made"
	ap__say "$result"
	return 0
}

# ap__say <word> - report a result.
#
# The word goes to stdout (which is what the tests read) AND into AP_RESULT.
# Callers that also need ap_link's state changes must read AP_RESULT, because
# capturing stdout with $(...) runs ap_link in a subshell and every ST_DATA
# update it makes is discarded when that subshell exits. That bug is invisible
# until the first unlink, which then finds an empty state file.
ap__say() {
	AP_RESULT="$1"
	printf '%s\n' "$1"
}

# ap_record <target> <checkout> <dest> <rel> <src> <backup> <exclmode> <made>
#
# Adds the exclude entry and writes the state record, carrying over what an
# earlier run recorded. This is where idempotence is won: the second run finds
# its own exclude entry, makes no new backup, and rewrites one identical line.
ap_record() {
	local target="$1" checkout="$2" dest="$3" rel="$4" src="$5"
	local backup="$6" exclmode="$7" made="$8"
	local excl=no prev prev_backup='' prev_made=''

	if [ "$exclmode" = yes ] && ap_exclude_add "$checkout" "$rel"; then
		excl=yes
	fi

	[ -n "$ST_FILE" ] || return 0
	if prev=$(st_by_dest "$dest"); then
		prev_backup=$(st_field "$prev" 7)
		prev_made=$(st_field "$prev" 9)
		# An earlier run may have added the block; that ownership survives
		# even when this run had nothing left to write.
		[ "$excl" = no ] && [ "$(st_field "$prev" 8)" = yes ] && excl=yes
	fi
	# A backup made in this run wins; otherwise the older one is carried on, so
	# that a repeated run never loses the pointer to the user's original data.
	[ "$backup" = '-' ] && backup="$prev_backup"
	made=$(ap_merge_dirs "$prev_made" "$made")

	st_add "$target" "$checkout" "$dest" "$src" symlink "$backup" "$excl" "$made"
	st_save
}

# --- unlink ------------------------------------------------------------------

# ap_link_is_ours <dest> <recorded-src> <ctx-root>
#
# True when the symlink at <dest> either points exactly where we recorded, or
# points into the context repo at all. The second half is the fallback that
# keeps unlink working after the state file was deleted.
ap_link_is_ours() {
	local dest="${1%/}" src="$2" ctx="${3%/}" lex res
	[ -L "$dest" ] || return 1
	lex=$(gr_link_target "$dest") || lex=''
	res=$(gr_realpath "$dest") || res=''
	if [ -n "$src" ]; then
		[ "$lex" = "$src" ] && return 0
		[ -n "$res" ] && [ "$res" = "$src" ] && return 0
	fi
	if [ -n "$ctx" ]; then
		[ -n "$lex" ] && gr_is_inside "$lex" "$ctx" && return 0
		[ -n "$res" ] && gr_is_inside "$res" "$ctx" && return 0
	fi
	return 1
}

# ap_unlink_at <checkout> <dest> <src> <backup> <exclude> <made-dirs> [ctx-root]
#
# The whole reversal, driven by arguments rather than by a record, so that it
# also serves the stateless fallback. Prints one of:
#   removed restored already-gone kept-foreign failed
ap_unlink_at() {
	local checkout="${1%/}" dest="${2%/}" src="$3" backup="$4" excl="$5" made="$6"
	local ctx="${7:-}" rel removed=0 restored=0
	[ -n "$ctx" ] || ctx=$(ap_context)
	ctx=${ctx%/}
	AP_LAST_ERROR=''

	# P2 again: -L before -e, or a dangling link of ours looks absent.
	# P5: `${dest%/}` and never `rm -r`. A trailing slash here would follow the
	# link and take the context repo's own content with it.
	if [ -L "$dest" ]; then
		if ap_link_is_ours "$dest" "$src" "$ctx"; then
			if ! rm -- "$dest"; then
				ap_fail "cannot remove $(gr_clean "$dest")"
				printf 'failed\n'
				return 1
			fi
			removed=1
		else
			gr_warn "$(gr_clean "$dest") points outside the context repo - left alone"
			printf 'kept-foreign\n'
			return 1
		fi
	elif [ -e "$dest" ]; then
		gr_warn "$(gr_clean "$dest") is not a symlink any more - left alone"
		printf 'kept-foreign\n'
		return 1
	fi

	if [ -n "$backup" ] && { [ -L "$backup" ] || [ -e "$backup" ]; }; then
		if [ -L "$dest" ] || [ -e "$dest" ]; then
			gr_warn "not restoring $(gr_clean "$backup"): $(gr_clean "$dest") is in the way"
		elif mv -- "$backup" "$dest"; then
			restored=1
		else
			ap_fail "cannot restore $(gr_clean "$backup")"
			printf 'failed\n'
			return 1
		fi
	fi

	if [ "$excl" = yes ]; then
		rel=${dest#"$checkout"/}
		[ "$rel" != "$dest" ] && ap_exclude_remove "$checkout" "$rel" >/dev/null 2>&1
	fi

	ap_rmdir_list "$checkout" "$made"

	if [ "$restored" = 1 ]; then
		printf 'restored\n'
	elif [ "$removed" = 1 ]; then
		printf 'removed\n'
	else
		printf 'already-gone\n'
	fi
	return 0
}

# ap_unlink_record <record> - reverse one state record (SPEC 9.4).
# The record only ever supplies hints; every step is verified against the
# filesystem first. The record is dropped either way, because after this call
# nothing of ours is left at that destination.
ap_unlink_record() {
	local rec="$1" checkout dest src backup excl made out rc
	checkout=$(st_field "$rec" 2)
	dest=$(st_field "$rec" 3)
	src=$(st_field "$rec" 4)
	backup=$(st_field "$rec" 7)
	excl=$(st_field "$rec" 8)
	made=$(st_field "$rec" 9)

	out=$(ap_unlink_at "$checkout" "$dest" "$src" "$backup" "$excl" "$made")
	rc=$?
	ap__say "$out"
	if [ "$rc" = 0 ] && [ -n "$ST_FILE" ]; then
		st_forget "$dest" || :
		st_save
	fi
	return "$rc"
}

# ap_unlink_dest <checkout> <dest-rel> [ctx-root] - unlink without any state.
#
# Used when the state file is gone: the only thing we then know about a link is
# where it points, so "points into the context repo" becomes the whole test. A
# single obvious backup next to the destination is restored; anything more
# ambiguous is left for the user to sort out.
ap_unlink_dest() {
	local checkout="$1" rel="${2#./}" ctx="${3:-}" co dest backup='' cand n=0
	rel=${rel%/}
	[ -n "$rel" ] || return 1
	co=$(gr_realpath "$checkout") || return 1
	dest=$(gr_abspath "${co%/}/$rel")
	dest=${dest%/}

	for cand in "$dest$AP_BACKUP_SUFFIX"*; do
		{ [ -L "$cand" ] || [ -e "$cand" ]; } || continue
		backup="$cand"
		n=$((n + 1))
	done
	[ "$n" = 1 ] || backup=''

	ap_unlink_at "${co%/}" "$dest" '' "$backup" yes '' "$ctx"
}
