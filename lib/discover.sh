# shellcheck shell=bash
#
# discover.sh - locating project checkouts, and caching what we learned.
#
# Finding out where a checkout lives is the expensive part of a graft run, so we
# pay for it exactly once: a single filesystem walk fills an index that answers
# the `find` strategies of *every* target, and that index is cached between runs
# (docs/SPEC.md sections 3, 4.4 and 9.2).
#
# Two rules shape everything below:
#   - No network (invariant I2). `git remote get-url` reads .git/config and
#     nothing else; there is no fetch and no ls-remote anywhere in this file.
#   - No execution of config data (invariant I1). Globs are matched with `case`,
#     regular expressions with `grep -E`. Never with eval.
#
# Depends on core.sh and on the cfg_* readers of config.sh.
# Must stay bash 3.2 compatible: no associative arrays, no mapfile.

# --- module state ------------------------------------------------------------

DISC_SCHEMA=1

DISC_INDEX=''     # path of the cache file backing DISC_ROWS
DISC_ROWS=''      # TSV rows, escaped, one per line: path \t origin \t epoch
DISC_CANDS=''     # candidate paths of the resolve in progress, one per line
DISC_STACK='|'    # targets currently being resolved, for the cycle guard
DISC_LOADED=0     # 1 once the index is in memory
DISC_FROM_CACHE=0 # 1 when the index was read from disk rather than scanned
DISC_REBUILT=0    # 1 once we have rescanned in this run (the retry budget)
DISC_STALE=0      # 1 when a cached row disagreed with the filesystem
DISC_WARNED_SCHEMA=0

DISC_ESC=''                   # scratch output of disc__esc_into
DISC_UNESC=''                 # scratch output of disc__unesc_into
DISC_P='' DISC_O='' DISC_E='' # scratch row fields of disc__row_into
DISC_URL=''                   # scratch output of disc__norm_url_into

DISC_MAX_DEPTH=8 # nesting limit for parent-of: / target: (cycle backstop)
DISC_NL='
'
DISC_TAB=$'\t'

# Defaults from SPEC 4.1, applied when config.sh reports nothing.
DISC_DEF_DEPTH=4
DISC_DEF_PRUNE='node_modules,vendor,target,.cache,Library,dist,build'

# --- small helpers -----------------------------------------------------------

disc__trim() {
	local s="$1"
	s=${s#"${s%%[![:space:]]*}"}
	s=${s%"${s##*[![:space:]]}"}
	printf '%s' "$s"
}

# TSV escaping per SPEC 3.1. core's gr_tsv_escape is sed-based and therefore
# cannot see an embedded newline; a scanned path is exactly the place where one
# shows up, so we escape in the shell instead. Result: one record, one line.
disc__esc_into() {
	DISC_ESC=$1
	if [ -z "$DISC_ESC" ]; then
		DISC_ESC='-'
		return 0
	fi
	DISC_ESC=${DISC_ESC//\\/\\\\}
	DISC_ESC=${DISC_ESC//$'\t'/\\t}
	DISC_ESC=${DISC_ESC//$'\n'/\\n}
}

disc__esc() {
	disc__esc_into "$1"
	printf '%s' "$DISC_ESC"
}

# Left to right, so that a literal backslash before a "t" does not turn into a
# tab on the way back in. The "_into" form sets a variable instead of writing to
# stdout: it runs once per cached row, and a command substitution there would
# mean one fork per checkout on every single run.
disc__unesc_into() {
	local s="$1" out='' head bs=$'\\'
	case "$s" in
	'-' | '')
		DISC_UNESC=''
		return 0
		;;
	esac
	while [ -n "$s" ]; do
		case "$s" in
		"$bs$bs"*)
			out="$out$bs"
			s=${s#??}
			;;
		"${bs}t"*)
			out="$out$DISC_TAB"
			s=${s#??}
			;;
		"${bs}n"*)
			out="$out$DISC_NL"
			s=${s#??}
			;;
		"$bs"*)
			out="$out$bs"
			s=${s#?}
			;;
		*)
			head=${s%%"$bs"*}
			if [ "$head" = "$s" ]; then
				out="$out$s"
				s=''
			else
				out="$out$head"
				s=${s#"$head"}
			fi
			;;
		esac
	done
	DISC_UNESC=$out
}

disc__unesc() {
	disc__unesc_into "$1"
	printf '%s' "$DISC_UNESC"
}

# disc__row_into <row> - decode a cache row into DISC_P / DISC_O / DISC_E
# (path, origin URL, last commit epoch) without spawning anything.
disc__row_into() {
	local IFS=$'\t'
	set -f
	# shellcheck disable=SC2086 # deliberate splitting on IFS=tab
	set -- $1
	set +f
	disc__unesc_into "${1:-}"
	DISC_P=$DISC_UNESC
	disc__unesc_into "${2:-}"
	DISC_O=$DISC_UNESC
	disc__unesc_into "${3:-}"
	DISC_E=$DISC_UNESC
}

# disc__field <row> <n> - nth tab separated field. Fields are never empty on
# disk (an empty value is written as "-"), so IFS collapsing cannot bite.
disc__field() {
	local row="$1" n="$2"
	local IFS=$'\t'
	set -f
	# shellcheck disable=SC2086 # deliberate splitting on IFS=tab
	set -- $row
	set +f
	[ "$n" -le "$#" ] || return 1
	shift "$((n - 1))"
	printf '%s' "$1"
}

# disc__addline <list> <item> - append unless already present.
disc__addline() {
	local list="$1" item="$2"
	case "$DISC_NL$list$DISC_NL" in
	*"$DISC_NL$item$DISC_NL"*)
		printf '%s' "$list"
		return 0
		;;
	esac
	if [ -z "$list" ]; then
		printf '%s' "$item"
	else
		printf '%s%s%s' "$list" "$DISC_NL" "$item"
	fi
}

disc__count() {
	local n
	[ -n "$1" ] || {
		printf '0'
		return 0
	}
	n=$(printf '%s\n' "$1" | wc -l)
	printf '%s' "${n// /}"
}

# The origin URL as we compare it: trailing slash and ".git" suffix removed, so
# that git@host:acme/api.git and https://host/acme/api match the same pattern.
# Fork-free, because it runs once per indexed checkout.
disc__norm_url_into() {
	DISC_URL=${1%/}
	DISC_URL=${DISC_URL%.git}
	DISC_URL=${DISC_URL%/}
	# scp-style shorthand ([user@]host:path) is what most corporate setups use,
	# and it puts a colon exactly where every other URL form has a slash. Without
	# this, a pattern like */acme/api matches the https clone and silently misses
	# the ssh one - the single most confusing way this tool can fail.
	# A URL with a scheme keeps its colon: ssh://host:22/path is a port.
	case "$DISC_URL" in
	*://*) ;;
	*:*)
		disc__host=${DISC_URL%%:*}
		disc__path=${DISC_URL#*:}
		while :; do
			case "$disc__path" in
			/*) disc__path=${disc__path#/} ;;
			*) break ;;
			esac
		done
		DISC_URL="$disc__host/$disc__path"
		;;
	esac
}

disc__norm_url() {
	disc__norm_url_into "$1"
	printf '%s' "$DISC_URL"
}

# The only git call in this module, and it is local-only (invariant I2).
disc__origin_of() {
	local co="$1" u=''
	u=$(git -C "$co" remote get-url origin 2>/dev/null </dev/null) || u=''
	if [ -z "$u" ]; then
		u=$(git -C "$co" config --get remote.origin.url 2>/dev/null </dev/null) || u=''
	fi
	printf '%s' "$u"
}

# --- config access -----------------------------------------------------------
#
# Only the readers documented in SPEC 9.1 are used, so this module can be
# developed and tested without lib/config.sh being present.

disc__default() {
	local key="$1" fallback="$2" v
	v=$(cfg_get_all defaults "$key" 2>/dev/null | tail -n 1)
	[ -n "$v" ] || v="$fallback"
	printf '%s' "$v"
}

# `verify` is repeatable (SPEC 4.2) but has no dedicated reader in 9.1, so it is
# read straight from the target section. Both plausible spellings of a section
# name are asked for; the one that does not exist simply yields nothing.
disc__target_all() {
	local t="$1" key="$2" v
	v=$(cfg_get_all "target \"$t\"" "$key" 2>/dev/null)
	[ -n "$v" ] || v=$(cfg_get_all "target.$t" "$key" 2>/dev/null)
	printf '%s' "$v"
}

# --- cache location ----------------------------------------------------------

disc__conf_path() {
	if [ -n "${CFG_FILE:-}" ]; then
		gr_abspath "$CFG_FILE"
	else
		gr_abspath 'graft.conf'
	fi
}

disc_cache_dir() {
	printf '%s/%s\n' "$(gr_xdg_cache)" "$(gr_config_id "$(disc__conf_path)")"
}

disc_cache_file() { printf '%s/checkouts.tsv\n' "$(disc_cache_dir)"; }
disc_pins_file() { printf '%s/pins.tsv\n' "$(disc_cache_dir)"; }

# --- the scan ----------------------------------------------------------------

# disc_index_build - the single filesystem walk of the run.
#
# We match `.git` itself rather than testing every directory for one: that is a
# single find process instead of one `test` per directory, and it also picks up
# worktrees and submodules, where `.git` is a file (pitfall P3).
disc_index_build() {
	local roots root depth maxd prune name rows='' gitpath co origin epoch oldifs
	local -a prune_expr args

	depth=$(disc__default search_depth "$DISC_DEF_DEPTH")
	case "$depth" in
	'' | *[!0-9]*) depth=$DISC_DEF_DEPTH ;;
	esac
	[ "$depth" -ge 1 ] || depth=1
	[ "$depth" -le 10 ] || depth=10
	# search_depth counts checkout directories below the root; the `.git` we
	# look for sits one level deeper than the checkout it belongs to.
	maxd=$((depth + 1))

	prune=$(disc__default search_prune "$DISC_DEF_PRUNE")

	# Prune expression: every dotdir except .git (which the first clause has
	# already claimed), plus the configured names. Built once, used per root.
	prune_expr=('(' -name '.?*')
	oldifs=$IFS
	IFS=,
	set -f
	# shellcheck disable=SC2086 # deliberate splitting on IFS=,
	set -- $prune
	set +f
	IFS=$oldifs
	for name in "$@"; do
		name=$(disc__trim "$name")
		case "$name" in
		'' | '.' | '..' | */*) continue ;;
		esac
		prune_expr+=(-o -name "$name")
	done
	prune_expr+=(')' -prune)

	roots=$(cfg_get_all defaults search_root 2>/dev/null)
	[ -n "$roots" ] || roots="$HOME"

	while IFS= read -r root; do
		root=$(disc__trim "$root")
		[ -n "$root" ] || continue
		root=$(gr_abspath "$root")
		[ -d "$root" ] || continue
		# -H: command line arguments are followed, nothing below them is, so a
		# symlink loop under the root cannot make the walk run forever.
		args=(-H "$root" -maxdepth "$maxd" -name '.git' -prune -print0 -o -type d)
		args+=("${prune_expr[@]}")
		# -print0 / read -d '' because a path may contain a space, an umlaut or
		# even a newline, and one broken path must not shift every field after
		# it (pitfall P6).
		while IFS= read -r -d '' gitpath; do
			co=${gitpath%/.git}
			[ "$co" != "$gitpath" ] || continue
			[ -d "$co" ] || continue
			origin=$(disc__origin_of "$co")
			epoch=$(git -C "$co" log -1 --format=%ct 2>/dev/null </dev/null) || epoch=''
			disc__esc_into "$co"
			rows="$rows$DISC_ESC"
			disc__esc_into "$origin"
			rows="$rows$DISC_TAB$DISC_ESC"
			disc__esc_into "$epoch"
			rows="$rows$DISC_TAB$DISC_ESC$DISC_NL"
		done < <(find "${args[@]}" 2>/dev/null)
	done <<<"$roots"

	# Sorted so that two runs on the same machine produce the same file, and
	# deduplicated so that overlapping search_roots cost nothing.
	if [ -n "$rows" ]; then
		DISC_ROWS=$(printf '%s' "$rows" | LC_ALL=C sort -u)
	else
		DISC_ROWS=''
	fi

	disc__write_cache
	DISC_LOADED=1
	DISC_FROM_CACHE=0
	DISC_REBUILT=1
	return 0
}

disc__write_cache() {
	local f
	f=$(disc_cache_file)
	{
		printf '#graft-cache\t%s\t%s\n' "$DISC_SCHEMA" "$(disc__esc "$(disc__conf_path)")"
		printf '#path\torigin\tlast_commit_epoch\n'
		if [ -n "$DISC_ROWS" ]; then
			printf '%s\n' "$DISC_ROWS"
		fi
	} | gr_atomic_write "$f" || return 1
	DISC_INDEX=$f
}

# Returns 1 whenever the file on disk cannot be trusted; the caller rescans.
# A cache format is never allowed to stop the tool (SPEC 3.1).
disc__read_cache() {
	local f line n=0 kind ver conf rows=''
	f=$(disc_cache_file)
	[ -f "$f" ] || return 1
	while IFS= read -r line; do
		n=$((n + 1))
		if [ "$n" = 1 ]; then
			kind=$(disc__field "$line" 1)
			ver=$(disc__field "$line" 2)
			conf=$(disc__field "$line" 3)
			[ "$kind" = '#graft-cache' ] || return 1
			if [ "$ver" != "$DISC_SCHEMA" ]; then
				if [ "$DISC_WARNED_SCHEMA" != 1 ]; then
					gr_warn "discovery cache has schema $(gr_clean "$ver"), expected $DISC_SCHEMA - rebuilding"
					DISC_WARNED_SCHEMA=1
				fi
				return 1
			fi
			# gr_config_id collisions are harmless because the full config
			# path is stored here and checked (SPEC section 3).
			[ "$(disc__unesc "$conf")" = "$(disc__conf_path)" ] || return 1
			continue
		fi
		case "$line" in
		'#'*) continue ;;
		esac
		[ -n "$line" ] || continue
		rows="$rows$line$DISC_NL"
	done <"$f"
	DISC_ROWS=${rows%"$DISC_NL"}
	DISC_INDEX=$f
	return 0
}

# disc_index_load [--rescan]
disc_index_load() {
	local line path
	DISC_INDEX=$(disc_cache_file)
	case "${1:-}" in
	--rescan)
		disc_index_build
		return
		;;
	esac
	if ! disc__read_cache; then
		disc_index_build
		return
	fi
	# A path in the cache that has vanished means the cache describes a machine
	# that no longer exists. Half a truth is worse than a rescan.
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		disc__row_into "$line"
		if [ ! -d "$DISC_P" ]; then
			disc_index_build
			return
		fi
	done <<<"$DISC_ROWS"
	DISC_LOADED=1
	DISC_FROM_CACHE=1
	return 0
}

disc__ensure_index() {
	[ "$DISC_LOADED" = 1 ] && return 0
	disc_index_load
}

# disc_info <path> - origin URL and last commit epoch of an indexed checkout,
# tab separated. bin/graft renders the ambiguity list from this.
disc_info() {
	local want="$1" line path
	disc__ensure_index
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		disc__row_into "$line"
		[ "$DISC_P" = "$want" ] || continue
		printf '%s\t%s\n' "$DISC_O" "$DISC_E"
		return 0
	done <<<"$DISC_ROWS"
	return 1
}

# --- pins --------------------------------------------------------------------
#
# A pin lives beside the index rather than inside it: rebuilding the index must
# never drop what the user told us explicitly with --path.

# disc_pin <target> <dir>
disc_pin() {
	local t="$1" dir="$2" f line out='' key
	[ -n "$t" ] || return 1
	dir=$(gr_abspath "$dir")
	[ -d "$dir" ] || return 1
	f=$(disc_pins_file)
	if [ -f "$f" ]; then
		while IFS= read -r line; do
			case "$line" in
			'#'*) continue ;;
			esac
			[ -n "$line" ] || continue
			key=$(disc__unesc "$(disc__field "$line" 1)")
			[ "$key" != "$t" ] || continue
			out="$out$line$DISC_NL"
		done <"$f"
	fi
	out="$out$(disc__esc "$t")$DISC_TAB$(disc__esc "$dir")$DISC_NL"
	{
		printf '#graft-pins\t%s\t%s\n' "$DISC_SCHEMA" "$(disc__esc "$(disc__conf_path)")"
		printf '#target\tpath\n'
		printf '%s' "$out"
	} | gr_atomic_write "$f"
}

# disc_pinned <target> - print the pinned path, or return 1.
disc_pinned() {
	local t="$1" f line n=0 key path
	f=$(disc_pins_file)
	[ -f "$f" ] || return 1
	while IFS= read -r line; do
		n=$((n + 1))
		if [ "$n" = 1 ]; then
			[ "$(disc__field "$line" 1)" = '#graft-pins' ] || return 1
			[ "$(disc__field "$line" 2)" = "$DISC_SCHEMA" ] || return 1
			continue
		fi
		case "$line" in
		'#'*) continue ;;
		esac
		[ -n "$line" ] || continue
		key=$(disc__unesc "$(disc__field "$line" 1)")
		[ "$key" = "$t" ] || continue
		path=$(disc__unesc "$(disc__field "$line" 2)")
		# A pin that points at nothing is not an answer.
		[ -d "$path" ] || return 1
		printf '%s\n' "$path"
		return 0
	done <"$f"
	return 1
}

# --- strategies --------------------------------------------------------------
#
# Every strategy fills DISC_CANDS and returns 0 when it produced at least one
# candidate. They write to a global instead of stdout on purpose: a command
# substitution is a subshell, and the staleness flag set while matching has to
# survive back into disc_resolve.

disc__by_path() {
	local p
	[ -n "$1" ] || return 1
	p=$(gr_abspath "$1")
	[ -d "$p" ] || return 1
	DISC_CANDS=$p
}

disc__by_env() {
	local name="$1" val p
	case "$name" in
	'' | [0-9]* | *[!A-Za-z0-9_]*)
		gr_warn "find env: expects a variable name, got '$(gr_clean "$name")'"
		return 1
		;;
	esac
	# Indirect expansion, not eval: the value is data and is never executed.
	val=${!name:-}
	# Unset or empty is a soft failure, not an error (SPEC 4.4).
	[ -n "$val" ] || return 1
	p=$(gr_abspath "$val")
	[ -d "$p" ] || return 1
	DISC_CANDS=$p
}

# disc__by_origin <glob|re> <pattern>
disc__by_origin() {
	local mode="$1" pat="$2" line url path out=''
	[ -n "$pat" ] || return 1
	disc__ensure_index
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		disc__row_into "$line"
		[ -n "$DISC_O" ] || continue
		disc__norm_url_into "$DISC_O"
		url=$DISC_URL
		if [ "$mode" = glob ]; then
			# shellcheck disable=SC2254 # the config value IS the glob; matched
			# by case, never by eval
			case "$url" in
			$pat) ;;
			*) continue ;;
			esac
		else
			printf '%s\n' "$url" | grep -qE -e "$pat" 2>/dev/null || continue
		fi
		path=$DISC_P
		# The cached URL is a claim about a checkout, so we check it before we
		# act on it. If it no longer holds, the row is dropped and the run gets
		# one rescan - a cache is allowed to be empty, never to be wrong.
		disc__norm_url_into "$(disc__origin_of "$path")"
		if [ "$DISC_URL" != "$url" ]; then
			DISC_STALE=1
			continue
		fi
		out=$(disc__addline "$out" "$path")
	done <<<"$DISC_ROWS"
	DISC_CANDS=$out
	[ -n "$out" ]
}

disc__by_dir() {
	local pat="$1" line path out='' p
	[ -n "$pat" ] || return 1
	# shellcheck disable=SC2088 # the tilde is meant literally here
	case "$pat" in
	'~') pat="$HOME" ;;
	'~/'*) pat="$HOME/${pat#'~/'}" ;;
	esac
	disc__ensure_index
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		disc__row_into "$line"
		path=$DISC_P
		# shellcheck disable=SC2254 # see disc__by_origin
		case "$path" in
		$pat) out=$(disc__addline "$out" "$path") ;;
		esac
	done <<<"$DISC_ROWS"
	if [ -z "$out" ]; then
		# The glob may name a directory outside every search_root. Pathname
		# expansion answers that without a second walk. IFS is emptied so that
		# a pattern containing a space stays one word.
		local IFS=''
		# shellcheck disable=SC2086 # unquoted on purpose: this is the glob
		for p in $pat; do
			[ -d "$p" ] || continue
			out=$(disc__addline "$out" "$p")
		done
	fi
	DISC_CANDS=$out
	[ -n "$out" ]
}

# disc__candidates <find-spec> <depth>
disc__candidates() {
	local spec="$1" depth="$2" strat arg inner p out=''
	DISC_CANDS=''
	if [ "$depth" -gt "$DISC_MAX_DEPTH" ]; then
		gr_warn "find nesting too deep at '$(gr_clean "$spec")'"
		return 1
	fi
	case "$spec" in
	*:*)
		strat=${spec%%:*}
		arg=${spec#*:}
		;;
	*)
		gr_warn "find without a strategy: '$(gr_clean "$spec")'"
		return 1
		;;
	esac
	strat=$(disc__trim "$strat")
	arg=$(disc__trim "$arg")
	case "$strat" in
	path) disc__by_path "$arg" || return 1 ;;
	env) disc__by_env "$arg" || return 1 ;;
	origin) disc__by_origin glob "$arg" || return 1 ;;
	origin-re) disc__by_origin re "$arg" || return 1 ;;
	dir) disc__by_dir "$arg" || return 1 ;;
	parent-of)
		disc__candidates "$arg" "$((depth + 1))" || return 1
		inner=$DISC_CANDS
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			p=$(dirname -- "$p")
			[ -d "$p" ] || continue
			out=$(disc__addline "$out" "$p")
		done <<<"$inner"
		DISC_CANDS=$out
		;;
	target)
		# Ambiguity inside the referenced target stays ambiguity here: the
		# caller counts the candidates, nobody picks one.
		disc__resolve_target "$arg" "$((depth + 1))" || :
		;;
	*)
		gr_warn "unknown find strategy: '$(gr_clean "$strat")'"
		return 1
		;;
	esac
	[ -n "$DISC_CANDS" ]
}

# disc__verify_filter <target> <candidates> - drop candidates that do not carry
# every `verify` path of the target. Runs in a subshell (no globals to keep).
disc__verify_filter() {
	local t="$1" cands="$2" verifies path v ok out=''
	verifies=$(disc__target_all "$t" verify)
	if [ -z "$verifies" ]; then
		printf '%s' "$cands"
		return 0
	fi
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		ok=1
		while IFS= read -r v; do
			v=$(disc__trim "$v")
			[ -n "$v" ] || continue
			[ -e "$path/$v" ] || {
				ok=0
				break
			}
		done <<<"$verifies"
		[ "$ok" = 1 ] || continue
		out=$(disc__addline "$out" "$path")
	done <<<"$cands"
	printf '%s' "$out"
}

# disc__resolve_target <target> <depth> - fills DISC_CANDS.
# 0 = exactly one candidate, 1 = none, 2 = several.
disc__resolve_target() {
	local t="$1" depth="$2" finds line filtered pinned rc=1
	DISC_CANDS=''
	if [ "$depth" -gt "$DISC_MAX_DEPTH" ]; then
		gr_warn "find nesting too deep at target '$(gr_clean "$t")'"
		return 1
	fi
	case "$DISC_STACK" in
	*"|$t|"*)
		gr_warn "find cycle: target '$(gr_clean "$t")' resolves through itself"
		return 1
		;;
	esac
	DISC_STACK="$DISC_STACK$t|"

	# An explicit --path outranks every strategy; the user has answered the
	# question the strategies exist to ask.
	if pinned=$(disc_pinned "$t"); then
		DISC_STACK=${DISC_STACK%"$t|"}
		DISC_CANDS=$pinned
		return 0
	fi

	finds=$(cfg_target_finds "$t" 2>/dev/null)
	while IFS= read -r line; do
		line=$(disc__trim "$line")
		[ -n "$line" ] || continue
		disc__candidates "$line" "$depth" || continue
		filtered=$(disc__verify_filter "$t" "$DISC_CANDS")
		# A strategy whose candidates all fail `verify` has not matched; the
		# next strategy gets its turn.
		[ -n "$filtered" ] || continue
		DISC_CANDS=$filtered
		if [ "$(disc__count "$filtered")" = 1 ]; then rc=0; else rc=2; fi
		break
	done <<<"$finds"

	DISC_STACK=${DISC_STACK%"$t|"}
	[ "$rc" = 1 ] && DISC_CANDS=''
	return "$rc"
}

# disc_resolve <target> - print the checkout path.
# 0 found, 1 not found, 2 ambiguous (every candidate printed, one per line).
#
# Ambiguity is never resolved here. Picking the "obvious" candidate is how a
# tool ends up linking a shared context repo into somebody's fork.
disc_resolve() {
	local t="$1" rc
	DISC_STACK='|'
	DISC_STALE=0
	DISC_CANDS=''
	disc__ensure_index
	disc__resolve_target "$t" 0
	rc=$?
	# One rescan per run buys back correctness when the cache let us down:
	# either a row contradicted the filesystem, or nothing matched at all and
	# the index is simply older than the checkout we are looking for.
	if [ "$DISC_REBUILT" != 1 ] && [ "$DISC_FROM_CACHE" = 1 ] \
		&& { [ "$DISC_STALE" = 1 ] || [ "$rc" = 1 ]; }; then
		disc_index_build
		DISC_STACK='|'
		DISC_STALE=0
		DISC_CANDS=''
		disc__resolve_target "$t" 0
		rc=$?
	fi
	if [ -n "$DISC_CANDS" ]; then
		printf '%s\n' "$DISC_CANDS"
	fi
	return "$rc"
}
