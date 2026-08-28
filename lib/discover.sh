# shellcheck shell=bash
#
# discover.sh - locating project checkouts, and caching what we learned.
#
# Finding out where a checkout lives is the expensive part of a graft run, so we
# pay for it exactly once: a single filesystem walk fills an index that answers
# the `find` strategies of *every* target, and that index is cached between runs
# (docs/SPEC.md sections 3, 4.4 and 9.2).
#
# The index is held twice on purpose. DISC_ROWS is the escaped TSV that goes to
# and comes from the cache file; the DISC_PATH / DISC_ORIGIN / DISC_NORM /
# DISC_EPOCH arrays are the same rows decoded once per run. Every query reads
# the arrays. Decoding per query instead cost one shell loop for every
# (target, checkout) pair, which is quadratic in a machine full of repos.
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

# DISC_ROWS decoded. DISC_NORM holds the origin URL already put through
# disc__norm_url_into, because every origin match needs it and it never changes.
DISC_N=0
DISC_PATH=()
DISC_ORIGIN=()
DISC_NORM=()
DISC_EPOCH=()

DISC_ESC=''   # scratch output of disc__esc_into
DISC_UNESC='' # scratch output of disc__unesc_into
DISC_TRIM=''  # scratch output of disc__trim_to
DISC_URL=''   # scratch output of disc__norm_url_into
DISC_LIST=''  # candidate list under construction, see disc__add

DISC_MAX_DEPTH=8 # nesting limit for parent-of: / target: (cycle backstop)
DISC_NL='
'
DISC_TAB=$'\t'

# Defaults from SPEC 4.1, applied when config.sh reports nothing.
DISC_DEF_DEPTH=4
DISC_DEF_PRUNE='node_modules,vendor,target,.cache,Library,dist,build'

# --- small helpers -----------------------------------------------------------

disc__trim_to() {
	local s="$1"
	s=${s#"${s%%[![:space:]]*}"}
	DISC_TRIM=${s%"${s##*[![:space:]]}"}
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
	local s="$1" out='' head
	case "$s" in
	'-' | '')
		DISC_UNESC=''
		return 0
		;;
	esac
	while :; do
		head=${s%%\\*}
		out="$out$head"
		[ "$head" = "$s" ] && break
		s=${s#"$head"\\}
		case "$s" in
		t*) out="$out$DISC_TAB" ;;
		n*) out="$out$DISC_NL" ;;
		\\*) out="$out\\" ;;
		*)
			# An escape we never write: keep the backslash, consume nothing.
			out="$out\\"
			continue
			;;
		esac
		s=${s#?}
	done
	DISC_UNESC=$out
}

# Splitting a row is `IFS=$DISC_TAB read -r a b c <<<"$row"` everywhere below.
# Tab is IFS whitespace, so `read` would collapse a run of tabs and shift every
# field behind an empty one - but no field on disk is ever empty (SPEC 3.1
# writes "-" instead), so there is never a run of tabs to collapse.

# Append <item> to DISC_LIST unless it is already in it. A module global rather
# than a value returning function, because `out=$(disc__addline ...)` is a fork
# per candidate and the strategies below run once per target.
disc__add() {
	case "$DISC_NL$DISC_LIST$DISC_NL" in
	*"$DISC_NL$1$DISC_NL"*) return 0 ;;
	esac
	if [ -z "$DISC_LIST" ]; then
		DISC_LIST=$1
	else
		DISC_LIST="$DISC_LIST$DISC_NL$1"
	fi
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
# Only the readers documented in SPEC 9.1 are used - cfg_get, cfg_get_all,
# cfg_target_finds, cfg_target_verifies - so this module can be developed and
# tested without lib/config.sh being present. Section ids are never spelled out
# here: the target readers take the target name and own the encoding, so this
# module cannot guess it wrong.

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

# --- the index -----------------------------------------------------------------

# DISC_ROWS -> the four arrays every query reads. Called once per run, wherever
# DISC_ROWS is (re)filled.
disc__decode_rows() {
	local path origin epoch
	DISC_N=0
	DISC_PATH=() DISC_ORIGIN=() DISC_NORM=() DISC_EPOCH=()
	[ -n "$DISC_ROWS" ] || return 0
	while IFS="$DISC_TAB" read -r path origin epoch; do
		[ -n "$path" ] || continue
		disc__unesc_into "$path"
		DISC_PATH[DISC_N]=$DISC_UNESC
		disc__unesc_into "$origin"
		DISC_ORIGIN[DISC_N]=$DISC_UNESC
		disc__norm_url_into "$DISC_UNESC"
		DISC_NORM[DISC_N]=$DISC_URL
		disc__unesc_into "$epoch"
		DISC_EPOCH[DISC_N]=$DISC_UNESC
		DISC_N=$((DISC_N + 1))
	done <<<"$DISC_ROWS"
	return 0
}

# disc_index_build - the single filesystem walk of the run.
#
# We match `.git` itself rather than testing every directory for one: that is a
# single find process instead of one `test` per directory, and it also picks up
# worktrees and submodules, where `.git` is a file (pitfall P3).
disc_index_build() {
	local roots root depth maxd prune name rows='' gitpath co origin epoch oldifs
	local -a prune_expr args

	depth=$(cfg_get defaults search_depth "$DISC_DEF_DEPTH" 2>/dev/null)
	case "$depth" in
	'' | *[!0-9]*) depth=$DISC_DEF_DEPTH ;;
	esac
	[ "$depth" -ge 1 ] || depth=1
	[ "$depth" -le 10 ] || depth=10
	# search_depth counts checkout directories below the root; the `.git` we
	# look for sits one level deeper than the checkout it belongs to.
	maxd=$((depth + 1))

	prune=$(cfg_get defaults search_prune "$DISC_DEF_PRUNE" 2>/dev/null)

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
		disc__trim_to "$name"
		case "$DISC_TRIM" in
		'' | '.' | '..' | */*) continue ;;
		esac
		prune_expr+=(-o -name "$DISC_TRIM")
	done
	prune_expr+=(')' -prune)

	roots=$(cfg_get_all defaults search_root 2>/dev/null)
	[ -n "$roots" ] || roots="$HOME"

	while IFS= read -r root; do
		disc__trim_to "$root"
		[ -n "$DISC_TRIM" ] || continue
		root=$(gr_abspath "$DISC_TRIM")
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

	disc__decode_rows
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
			IFS="$DISC_TAB" read -r kind ver conf <<<"$line"
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
			disc__unesc_into "$conf"
			[ "$DISC_UNESC" = "$(disc__conf_path)" ] || return 1
			continue
		fi
		case "$line" in
		'#'*) continue ;;
		esac
		[ -n "$line" ] || continue
		rows="$rows$line$DISC_NL"
	done <"$f"
	DISC_ROWS=${rows%"$DISC_NL"}
	disc__decode_rows
	DISC_INDEX=$f
	return 0
}

# disc_index_load [--rescan]
disc_index_load() {
	local i=0
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
	while [ "$i" -lt "$DISC_N" ]; do
		if [ ! -d "${DISC_PATH[i]}" ]; then
			disc_index_build
			return
		fi
		i=$((i + 1))
	done
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
	local want="$1" i=0
	disc__ensure_index
	while [ "$i" -lt "$DISC_N" ]; do
		if [ "${DISC_PATH[i]}" = "$want" ]; then
			printf '%s\t%s\n' "${DISC_ORIGIN[i]}" "${DISC_EPOCH[i]}"
			return 0
		fi
		i=$((i + 1))
	done
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
			IFS="$DISC_TAB" read -r key _ <<<"$line"
			disc__unesc_into "$key"
			[ "$DISC_UNESC" != "$t" ] || continue
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
		IFS="$DISC_TAB" read -r key path _ <<<"$line"
		if [ "$n" = 1 ]; then
			[ "$key" = '#graft-pins' ] || return 1
			[ "$path" = "$DISC_SCHEMA" ] || return 1
			continue
		fi
		case "$line" in
		'#'* | '') continue ;;
		esac
		disc__unesc_into "$key"
		[ "$DISC_UNESC" = "$t" ] || continue
		disc__unesc_into "$path"
		# A pin that points at nothing is not an answer.
		[ -d "$DISC_UNESC" ] || return 1
		printf '%s\n' "$DISC_UNESC"
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
	# From the ENVIRONMENT, not from the shell's variables. `${!name}` executes
	# nothing, but it cannot tell an exported variable from one of graft's own
	# locals - so `find = env:CFG_CTX_ROOT` in a config file you cloned from a
	# colleague resolved to the context repo itself. A config may read the
	# environment; it does not get to read the program.
	val=$(printenv -- "$name" 2>/dev/null) || val=
	# Unset or empty is a soft failure, not an error (SPEC 4.4).
	[ -n "$val" ] || return 1
	p=$(gr_abspath "$val")
	[ -d "$p" ] || return 1
	DISC_CANDS=$p
}

# disc__by_origin <glob|re> <pattern>
disc__by_origin() {
	local mode="$1" pat="$2" i=0 url path
	[ -n "$pat" ] || return 1
	disc__ensure_index
	DISC_LIST=''
	while [ "$i" -lt "$DISC_N" ]; do
		url=${DISC_NORM[i]}
		path=${DISC_PATH[i]}
		i=$((i + 1))
		[ -n "$url" ] || continue
		if [ "$mode" = glob ]; then
			# shellcheck disable=SC2254 # the config value IS the glob; matched
			# by case, never by eval
			case "$url" in
			$pat) ;;
			*) continue ;;
			esac
		else
			# A here-string, not a pipe. `cmd | grep -q` under `set -o pipefail`
			# is a trap: grep closes the pipe on its first match, the writer
			# dies of SIGPIPE, and pipefail turns that match into a failure.
			grep -qE -e "$pat" <<<"$url" 2>/dev/null || continue
		fi
		# The cached URL is a claim about a checkout, so we check it before we
		# act on it. If it no longer holds, the row is dropped and the run gets
		# one rescan - a cache is allowed to be empty, never to be wrong.
		disc__norm_url_into "$(disc__origin_of "$path")"
		if [ "$DISC_URL" != "$url" ]; then
			DISC_STALE=1
			continue
		fi
		disc__add "$path"
	done
	DISC_CANDS=$DISC_LIST
	[ -n "$DISC_CANDS" ]
}

disc__by_dir() {
	local pat="$1" i=0 p
	[ -n "$pat" ] || return 1
	# shellcheck disable=SC2088 # the tilde is meant literally here
	case "$pat" in
	'~') pat="$HOME" ;;
	'~/'*) pat="$HOME/${pat#'~/'}" ;;
	esac
	disc__ensure_index
	DISC_LIST=''
	while [ "$i" -lt "$DISC_N" ]; do
		# shellcheck disable=SC2254 # see disc__by_origin
		case "${DISC_PATH[i]}" in
		$pat) disc__add "${DISC_PATH[i]}" ;;
		esac
		i=$((i + 1))
	done
	if [ -z "$DISC_LIST" ]; then
		# The glob may name a directory outside every search_root. Pathname
		# expansion answers that without a second walk. IFS is emptied so that
		# a pattern containing a space stays one word.
		local IFS=''
		# shellcheck disable=SC2086 # unquoted on purpose: this is the glob
		for p in $pat; do
			[ -d "$p" ] || continue
			disc__add "$p"
		done
	fi
	DISC_CANDS=$DISC_LIST
	[ -n "$DISC_CANDS" ]
}

# disc__candidates <find-spec> <depth>
disc__candidates() {
	local spec="$1" depth="$2" strat arg inner p
	DISC_CANDS=''
	if [ "$depth" -gt "$DISC_MAX_DEPTH" ]; then
		gr_warn "find nesting too deep at '$(gr_clean "$spec")'"
		return 1
	fi
	case "$spec" in
	*:*)
		disc__trim_to "${spec%%:*}"
		strat=$DISC_TRIM
		disc__trim_to "${spec#*:}"
		arg=$DISC_TRIM
		;;
	*)
		gr_warn "find without a strategy: '$(gr_clean "$spec")'"
		return 1
		;;
	esac
	case "$strat" in
	path) disc__by_path "$arg" || return 1 ;;
	env) disc__by_env "$arg" || return 1 ;;
	origin) disc__by_origin glob "$arg" || return 1 ;;
	origin-re) disc__by_origin re "$arg" || return 1 ;;
	dir) disc__by_dir "$arg" || return 1 ;;
	parent-of)
		disc__candidates "$arg" "$((depth + 1))" || return 1
		inner=$DISC_CANDS
		DISC_LIST=''
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			p=$(dirname -- "$p")
			[ -d "$p" ] || continue
			disc__add "$p"
		done <<<"$inner"
		DISC_CANDS=$DISC_LIST
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
	verifies=$(cfg_target_verifies "$t" 2>/dev/null)
	if [ -z "$verifies" ]; then
		printf '%s' "$cands"
		return 0
	fi
	while IFS= read -r path; do
		[ -n "$path" ] || continue
		ok=1
		while IFS= read -r v; do
			disc__trim_to "$v"
			[ -n "$DISC_TRIM" ] || continue
			[ -e "$path/$DISC_TRIM" ] || {
				ok=0
				break
			}
		done <<<"$verifies"
		[ "$ok" = 1 ] || continue
		if [ -z "$out" ]; then out="$path"; else out="$out$DISC_NL$path"; fi
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
		disc__trim_to "$line"
		[ -n "$DISC_TRIM" ] || continue
		disc__candidates "$DISC_TRIM" "$depth" || continue
		filtered=$(disc__verify_filter "$t" "$DISC_CANDS")
		# A strategy whose candidates all fail `verify` has not matched; the
		# next strategy gets its turn.
		[ -n "$filtered" ] || continue
		DISC_CANDS=$filtered
		# One candidate means one line, because the list is built without a
		# trailing newline.
		case "$filtered" in
		*"$DISC_NL"*) rc=2 ;;
		*) rc=0 ;;
		esac
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
