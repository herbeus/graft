# shellcheck shell=bash
#
# config.sh - the INI subset parser and its schema validation (SPEC section 4).
#
# The config file is *data*. It is read with `read -r`, expanded with string
# operations only, and never handed to eval, source, a subshell or a command
# substitution (invariant I1). The only external commands used on config
# derived strings are grep(1) as a regex *validator* and sed(1) on the file
# itself when an error is rendered.
#
# bash 3.2: no associative arrays, so parsed data lives in newline separated
# TSV inside plain string variables and is queried by splitting on tabs
# (SPEC section 9).
#
# Section ids used in CFG_DATA and accepted by cfg_get/cfg_get_all - this is
# the one encoding, there is no second spelling:
#   defaults          for [defaults]
#   target:<name>     for [target "<name>"]
#   setup:<name>      for [setup "<name>"]
# Neither a target nor a setup name can contain a colon (SPEC 4.2), so the
# encoding is unambiguous and reversible. Callers that want a target's values
# use the named readers below (cfg_target_get, cfg_target_finds,
# cfg_target_verifies, cfg_target_links) and never have to build an id at all.

# --- constants ---------------------------------------------------------------

CFG_TAB=$'\t'
CFG_NL=$'\n'

CFG_SECTION_TYPES='defaults target setup'
CFG_KEYS_DEFAULTS='source_root search_root search_depth search_prune link backup backup_suffix git_exclude on_foreign_link require'
CFG_KEYS_TARGET='description source find verify link confirm backup git_exclude on_foreign_link require'
CFG_KEYS_SETUP='description run'
CFG_KEYS_REPEATABLE='link find verify search_root'
CFG_STRATEGIES='path env origin origin-re dir parent-of target'

# SPEC 4.3: graft never links over these, wherever they sit in a checkout.
CFG_DENY='.ssh .gnupg .aws .config/gh .netrc .bashrc .zshrc .profile .bash_profile .gitconfig'

# Exit statuses only carry 0..255, so the error count is reported capped.
CFG_ERROR_CAP=250

# --- module state ------------------------------------------------------------

CFG_FILE=''         # absolute path of graft.conf
CFG_CTX_ROOT=''     # absolute path of the context repo
CFG_SOURCE_ROOT=''  # absolute path of the source root
CFG_DATA=''         # section \t key \t value \t lineno
CFG_ERRORS=''       # lineno \t message \t hint
CFG_SECTIONS=''     # section \t lineno, headers in file order
CFG_PARSE_ERRORS='' # the lexical subset of CFG_ERRORS, so cfg_validate can rerun
CFG__LIST=''        # scratch used by the link list builder
CFG__SECTION_ID=''  # out parameter of cfg__parse_header
CFG__CUR_TARGET=''  # target whose find strategy is being validated

# Section id for keys below a header that did not parse. It cannot collide with
# a real id: a section type never contains a space.
CFG_BAD_SECTION='? broken'

# printenv reads the *environment*. An indirect expansion (${!name}) would
# happily hand a config file the parser's own local variables instead.
if command -v printenv >/dev/null 2>&1; then
	CFG_HAVE_PRINTENV=1
else
	CFG_HAVE_PRINTENV=0
fi

# --- tiny string helpers -----------------------------------------------------

# Word membership without arrays.
cfg__in_list() {
	case " $2 " in *" $1 "*) return 0 ;; esac
	return 1
}

# Trimming happens once per line and per field, so the fork free variant that
# assigns CFG__TRIM is the one the parser uses.
cfg__trim_to() {
	local s="$1"
	s=${s#"${s%%[![:space:]]*}"}
	CFG__TRIM=${s%"${s##*[![:space:]]}"}
}

cfg__trim() {
	cfg__trim_to "$1"
	printf '%s' "$CFG__TRIM"
}

# Tab is the field separator of CFG_DATA, so it has to survive as an escape.
# Newlines cannot occur: the parser is line based.
cfg__esc() {
	local s="$1"
	s=${s//\\/\\\\}
	s=${s//"$CFG_TAB"/\\t}
	printf '%s' "$s"
}

# Left to right, so that a literal "\\t" decodes to backslash + t and not to a
# tab. Reversing the two substitutions instead would be subtly wrong.
cfg__unesc() {
	local s="$1" out='' head rest
	while [ -n "$s" ]; do
		case "$s" in
		*\\*) ;;
		*)
			out="$out$s"
			break
			;;
		esac
		head=${s%%\\*}
		rest=${s#*\\}
		out="$out$head"
		case "$rest" in
		t*)
			out="$out$CFG_TAB"
			s=${rest#?}
			;;
		\\*)
			out="$out\\"
			s=${rest#?}
			;;
		*)
			out="$out\\"
			s=$rest
			;;
		esac
	done
	printf '%s' "$out"
}

# Split a four field CFG_DATA record into CFG__F1..CFG__F4. Neither `read` nor
# cut(1) can do this: tab counts as IFS whitespace, so `IFS=$'\t' read`
# silently collapses an empty value and shifts every field behind it, and a
# command substitution per field costs a fork per field per record.
cfg__unpack() {
	local rec="$1"
	CFG__F1=${rec%%"$CFG_TAB"*}
	rec=${rec#*"$CFG_TAB"}
	CFG__F2=${rec%%"$CFG_TAB"*}
	rec=${rec#*"$CFG_TAB"}
	CFG__F3=${rec%%"$CFG_TAB"*}
	CFG__F4=${rec#*"$CFG_TAB"}
	case "$CFG__F3" in
	*\\*) CFG__F3=$(cfg__unesc "$CFG__F3") ;;
	esac
}

# Field n (1..4) of a tab separated record, for the short records that are not
# on a hot path.
cfg__field() {
	local rec="$1" n="$2"
	while [ "$n" -gt 1 ]; do
		case "$rec" in
		*"$CFG_TAB"*) rec=${rec#*"$CFG_TAB"} ;;
		*)
			printf ''
			return 0
			;;
		esac
		n=$((n - 1))
	done
	printf '%s' "${rec%%"$CFG_TAB"*}"
}

# --- typo heuristic ----------------------------------------------------------

# True when one edit (insert, delete, substitute) or one transposition of two
# adjacent characters turns $1 into $2. That is all a keyword typo ever is, and
# it keeps the whole thing to a single pass instead of a distance matrix.
cfg__near() {
	local a="$1" b="$2" la lb i
	[ "$a" = "$b" ] && return 0
	la=${#a}
	lb=${#b}
	case $((la - lb)) in
	0 | 1 | -1) ;;
	*) return 1 ;;
	esac
	i=0
	while [ "$i" -lt "$la" ] && [ "$i" -lt "$lb" ] && [ "${a:i:1}" = "${b:i:1}" ]; do
		i=$((i + 1))
	done
	if [ "$la" -eq "$lb" ]; then
		[ "${a:i+1}" = "${b:i+1}" ] && return 0
		if [ "${a:i:1}" = "${b:i+1:1}" ] && [ "${a:i+1:1}" = "${b:i:1}" ]; then
			[ "${a:i+2}" = "${b:i+2}" ] && return 0
		fi
		return 1
	fi
	if [ "$la" -gt "$lb" ]; then
		[ "${a:i+1}" = "${b:i}" ] && return 0
	else
		[ "${a:i}" = "${b:i+1}" ] && return 0
	fi
	return 1
}

# cfg__suggest_to <word> <candidates...> -> CFG__SUGGEST, either the empty
# string or " Did you mean 'x'?". Assigning instead of printing keeps the whole
# error path free of subshells, which matters on a config full of typos.
cfg__suggest_to() {
	local word="$1" cand
	shift
	CFG__SUGGEST=''
	for cand in "$@"; do
		if cfg__near "$word" "$cand"; then
			CFG__SUGGEST=" Did you mean '$cand'?"
			return 0
		fi
	done
	return 0
}

cfg__suggest() {
	cfg__suggest_to "$@"
	printf '%s' "$CFG__SUGGEST"
}

# Control characters in a message would let a cloned repo repaint the terminal.
# gr_clean forks, so it is only called when there is something to strip.
cfg__clean_to() {
	case "$1" in
	*[[:cntrl:]]*) CFG__CLEAN=$(gr_clean "$1") ;;
	*) CFG__CLEAN="$1" ;;
	esac
}

# --- expansion ---------------------------------------------------------------

cfg__env_get() {
	local name="$1"
	if [ "$CFG_HAVE_PRINTENV" = 1 ]; then
		printenv "$name" 2>/dev/null || :
	else
		# The name is already known to match [A-Za-z_][A-Za-z0-9_]*, so it
		# cannot carry a sed metacharacter into the script.
		env | sed -n "s/^$name=//p" | sed -n 1p
	fi
}

# A leading ~/ (or a bare ~) becomes $HOME. Only leading, per SPEC 4: a tilde in
# the middle of a path is a literal character on every filesystem we support.
cfg__expand_tilde() {
	local s="$1"
	# shellcheck disable=SC2088 # the tilde is data that we expand ourselves
	case "$s" in
	'~') printf '%s' "$HOME" ;;
	'~/'*) printf '%s' "$HOME/${s#'~/'}" ;;
	*) printf '%s' "$s" ;;
	esac
}

# ${NAME} -> the environment variable NAME. Pure string surgery: no eval, no
# indirect expansion, no subshell that could run what the file contains.
# Anything that is not a well formed ${[A-Za-z_][A-Za-z0-9_]*} stays literal;
# an undefined variable becomes empty so the strategy fails softly (SPEC 4).
# shellcheck disable=SC2016 # "${" is a literal to be found, not an expansion
cfg__expand_vars() {
	local s="$1" out='' pre rest name
	while :; do
		case "$s" in
		*'${'*) ;;
		*)
			out="$out$s"
			break
			;;
		esac
		pre=${s%%'${'*}
		rest=${s#*'${'}
		case "$rest" in
		*'}'*) ;;
		*)
			out="$out$pre\${$rest"
			break
			;;
		esac
		name=${rest%%'}'*}
		case "$name" in
		'' | [!A-Za-z_]* | *[!A-Za-z0-9_]*) out="$out$pre\${$name}" ;;
		*) out="$out$pre$(cfg__env_get "$name")" ;;
		esac
		s=${rest#*'}'}
	done
	printf '%s' "$out"
}

# Expansion inside a find value, recursing through parent-of. Only path: and
# env: arguments are expanded, exactly as SPEC 4 allows.
cfg__expand_find() {
	local v="$1" depth="${2:-0}" strat arg
	case "$v" in
	*:*) ;;
	*)
		printf '%s' "$v"
		return 0
		;;
	esac
	[ "$depth" -ge 5 ] && {
		printf '%s' "$v"
		return 0
	}
	strat=${v%%:*}
	arg=${v#*:}
	case "$strat" in
	path) arg=$(cfg__expand_tilde "$(cfg__expand_vars "$arg")") ;;
	env) arg=$(cfg__expand_vars "$arg") ;;
	parent-of) arg=$(cfg__expand_find "$arg" $((depth + 1))) ;;
	esac
	printf '%s:%s' "$strat" "$arg"
}

cfg__expand_value() {
	local key="$1" v="$2"
	case "$key" in
	find) cfg__expand_find "$v" ;;
	search_root) cfg__expand_tilde "$(cfg__expand_vars "$v")" ;;
	*) cfg__expand_tilde "$v" ;;
	esac
}

# --- error collection --------------------------------------------------------

cfg__error() {
	CFG_ERRORS="$CFG_ERRORS$1$CFG_TAB$2$CFG_TAB$3$CFG_NL"
}

cfg__error_count() {
	local rec n=0
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		n=$((n + 1))
	done <<<"$CFG_ERRORS"
	printf '%s' "$n"
}

# Checks run in phases, so the messages have to be put back into file order
# before a human sees them.
cfg__sort_errors() {
	local sorted
	[ -n "$CFG_ERRORS" ] || return 0
	sorted=$(printf '%s' "$CFG_ERRORS" | sort -s -n -k1,1)
	CFG_ERRORS="$sorted$CFG_NL"
}

# --- data access -------------------------------------------------------------

# <section> is a section id as encoded above: `defaults`, `target:<name>` or
# `setup:<name>`. Anything else simply matches no record.
cfg_get_all() {
	local section="$1" key="$2" rec out=''
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		cfg__unpack "$rec"
		[ "$CFG__F1" = "$section" ] || continue
		[ "$CFG__F2" = "$key" ] || continue
		out="$out$CFG__F3$CFG_NL"
	done <<<"$CFG_DATA"
	printf '%s' "$out"
}

cfg__has() {
	local section="$1" key="$2" rec
	while IFS= read -r rec; do
		case "$rec" in
		"$section$CFG_TAB$key$CFG_TAB"*) return 0 ;;
		esac
	done <<<"$CFG_DATA"
	return 1
}

# Line number of the first occurrence of section+key, or nothing.
cfg__first_lineno() {
	local section="$1" key="$2" rec
	while IFS= read -r rec; do
		case "$rec" in
		"$section$CFG_TAB$key$CFG_TAB"*)
			printf '%s' "${rec##*"$CFG_TAB"}"
			return 0
			;;
		esac
	done <<<"$CFG_DATA"
	return 1
}

# Last value wins, which is what an INI reader is expected to do.
cfg_get() {
	local section="$1" key="$2" all
	if cfg__has "$section" "$key"; then
		all=$(cfg_get_all "$section" "$key")
		printf '%s\n' "$all" | tail -n 1
		return 0
	fi
	if [ $# -ge 3 ]; then printf '%s\n' "$3"; fi
	return 0
}

# The built-in defaults of SPEC 4.1, so that callers do not have to carry them.
cfg_default() {
	case "$1" in
	source_root) printf '.\n' ;;
	search_root) printf '%s\n' "$HOME" ;;
	search_depth) printf '4\n' ;;
	search_prune) printf 'node_modules,vendor,target,.cache,Library,dist,build\n' ;;
	backup) printf 'timestamp\n' ;;
	backup_suffix) printf '.graft-backup\n' ;;
	git_exclude) printf 'yes\n' ;;
	on_foreign_link) printf 'warn\n' ;;
	require) printf 'no\n' ;;
	confirm) printf 'no\n' ;;
	*) printf '' ;;
	esac
}

cfg_target_get() {
	local t="$1" key="$2"
	if cfg__has "target:$t" "$key"; then
		cfg_get "target:$t" "$key"
		return 0
	fi
	if cfg__has defaults "$key"; then
		cfg_get defaults "$key"
		return 0
	fi
	if [ $# -ge 3 ]; then
		printf '%s\n' "$3"
	else
		cfg_default "$key"
	fi
}

cfg_targets() {
	local rec name
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		name=$(cfg__field "$rec" 1)
		case "$name" in
		target:*) printf '%s\n' "${name#target:}" ;;
		esac
	done <<<"$CFG_SECTIONS"
}

cfg_setups() {
	local rec name
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		name=$(cfg__field "$rec" 1)
		case "$name" in
		setup:*)
			printf '%s\t%s\t%s\n' "${name#setup:}" \
				"$(cfg_get "$name" description '')" "$(cfg_get "$name" run '')"
			;;
		esac
	done <<<"$CFG_SECTIONS"
}

cfg_target_finds() {
	cfg_get_all "target:$1" find
}

# Every `verify` of a target, one per line, in config order (SPEC 4.2). Callers
# outside this module read the target section through here rather than spelling
# a section id themselves.
cfg_target_verifies() {
	cfg_get_all "target:$1" verify
}

# True when <name> is a declared [target "<name>"]. Deliberately not
# `cfg_targets | grep -q`: grep -q closes the pipe on the first match, which
# under `set -o pipefail` turns a *hit* into a non-zero pipeline (SIGPIPE) for
# every target that is not the last one listed.
cfg__is_target() {
	local want="$1" rec
	while IFS= read -r rec; do
		case "$rec" in
		"target:$want$CFG_TAB"*) return 0 ;;
		esac
	done <<<"$CFG_SECTIONS"
	return 1
}

# --- path rules --------------------------------------------------------------

# Strip "./" prefixes, collapse repeated slashes and drop trailing slashes, so
# that ".github/", "./.github" and ".github" all compare equal - to each other
# and, more importantly, to the deny list.
#
# The repeated-slash case is not cosmetic. Without it ".config//gh" sails past a
# deny entry of ".config/gh" while ".config/gh" is refused, which is a deny list
# that only stops people who were not trying. "..", by contrast, is deliberately
# left alone here: it is rejected outright a step later, and collapsing it first
# would hide the very thing that check is looking for.
cfg__norm_dest() {
	local d="$1"
	# Slashes are collapsed first. The other order turns ".//x" into "/x",
	# which then reads as an absolute path - still refused, but with a message
	# that sends the reader looking for a leading slash they never wrote.
	while :; do
		case "$d" in
		*//*) d=${d//\/\///} ;;
		*/./*) d=${d//\/.\///} ;;
		*) break ;;
		esac
	done
	while :; do
		case "$d" in
		'./'*) d=${d#./} ;;
		*) break ;;
		esac
	done
	while :; do
		case "$d" in
		*/.) d=${d%/.} ;;
		*/) d=${d%/} ;;
		*) break ;;
		esac
	done
	printf '%s' "$d"
}

# One word describing why a link destination is unusable, or "ok".
# SPEC 4.3, and this is the check invariant I4 leans on.
cfg__dest_kind() {
	local d entry
	d=$(cfg__norm_dest "$1")
	# A tab in a destination silently shifts the fields of the internal plan
	# record, which made --dry-run plan one path and link do nothing at all.
	# Control characters have no business in a path we are about to create.
	case "$d" in
	*"$CFG_TAB"*)
		printf 'control'
		return 0
		;;
	esac
	# shellcheck disable=SC2088 # a literal tilde is what we are looking for
	case "$d" in
	'')
		printf 'empty'
		return 0
		;;
	/*)
		printf 'absolute'
		return 0
		;;
	'~' | '~/'*)
		printf 'tilde'
		return 0
		;;
	esac
	if gr_has_dotdot "$d"; then
		printf 'dotdot'
		return 0
	fi
	if [ "$d" = '.' ]; then
		printf 'self'
		return 0
	fi
	case "$d" in
	'.git' | '.git/'*)
		printf 'git'
		return 0
		;;
	esac
	for entry in $CFG_DENY; do
		if [ "$d" = "$entry" ]; then
			printf 'deny:%s' "$entry"
			return 0
		fi
		case "$d" in
		"$entry"/*)
			printf 'deny:%s' "$entry"
			return 0
			;;
		esac
	done
	printf 'ok'
}

# Absolute source path of one link spec of one target.
cfg__link_source_abs() {
	local tsource="$1" src="$2"
	case "$src" in
	/*) gr_abspath "$src" ;;
	*) gr_abspath "$CFG_SOURCE_ROOT/$tsource/$src" ;;
	esac
}

# Resolve a config path that is documented as "relative to <base>".
cfg__resolve_rel() {
	local base="$1" v="$2"
	case "$v" in
	/*) gr_abspath "$v" ;;
	*) gr_abspath "$base/$v" ;;
	esac
}

cfg__has_meta() {
	local s="$1" c
	for c in ';' '&' '|' '<' '>' '$' '`' '(' ')' '{' '}' '[' ']' '*' '?' '!' '~' '#' "'" '"' \\ ' ' "$CFG_TAB"; do
		case "$s" in *"$c"*) return 0 ;; esac
	done
	return 1
}

# --- parser ------------------------------------------------------------------

cfg__add_data() {
	local v="$3"
	case "$v" in
	*\\* | *"$CFG_TAB"*) v=$(cfg__esc "$v") ;;
	esac
	CFG_DATA="$CFG_DATA$1$CFG_TAB$2$CFG_TAB$v$CFG_TAB$4$CFG_NL"
}

cfg__section_lineno() {
	local id="$1" rec
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		if [ "$(cfg__field "$rec" 1)" = "$id" ]; then
			cfg__field "$rec" 2
			return 0
		fi
	done <<<"$CFG_SECTIONS"
	return 1
}

# Sets CFG__SECTION_ID to the parsed section id, or to the empty string when
# the header is broken. It cannot print the id instead: a command substitution
# would run it in a subshell and every error it recorded would be lost.
cfg__parse_header() {
	local line="$1" lineno="$2" inner type rest name first id
	CFG__SECTION_ID=''
	case "$line" in
	*']') ;;
	*)
		cfg__error "$lineno" "malformed section header" \
			"write [defaults], [target \"name\"] or [setup \"name\"]"
		return 1
		;;
	esac
	inner=${line#\[}
	inner=${inner%\]}
	inner=$(cfg__trim "$inner")
	type=${inner%%[[:space:]]*}
	rest=$(cfg__trim "${inner#"$type"}")
	if ! cfg__in_list "$type" "$CFG_SECTION_TYPES"; then
		cfg__error "$lineno" "unknown section type '$(gr_clean "$type")'" \
			"known sections: defaults, target, setup.$(cfg__suggest "$type" defaults target setup)"
		return 1
	fi
	if [ "$type" = defaults ]; then
		if [ -n "$rest" ]; then
			cfg__error "$lineno" "section [defaults] takes no name" \
				"write [defaults] and move per project keys into [target \"name\"]"
			return 1
		fi
		CFG__SECTION_ID='defaults'
		return 0
	fi
	if [ -z "$rest" ]; then
		cfg__error "$lineno" "section [$type] requires a quoted name" \
			"write [$type \"name\"]"
		return 1
	fi
	case "$rest" in
	'"'*'"')
		name=${rest#\"}
		name=${name%\"}
		;;
	*)
		cfg__error "$lineno" "section name must be in double quotes" \
			"write [$type \"$(gr_clean "$rest")\"]"
		return 1
		;;
	esac
	case "$name" in
	*'"'* | *\\* | */*)
		cfg__error "$lineno" "invalid section name '$(gr_clean "$name")'" \
			'a section name must not contain a quote, a backslash or a slash'
		return 1
		;;
	esac
	if [ -z "$(cfg__trim "$name")" ]; then
		cfg__error "$lineno" "section name is blank" "write [$type \"name\"]"
		return 1
	fi
	first=${name%"${name#?}"}
	case "$first" in
	[A-Za-z0-9]) ;;
	*)
		cfg__error "$lineno" "invalid $type name '$(gr_clean "$name")'" \
			'names match [A-Za-z0-9][A-Za-z0-9._-]* - it must start with a letter or a digit'
		return 1
		;;
	esac
	case "$name" in
	*[!A-Za-z0-9._-]*)
		cfg__error "$lineno" "invalid $type name '$(gr_clean "$name")'" \
			'names match [A-Za-z0-9][A-Za-z0-9._-]* - drop every other character'
		return 1
		;;
	esac
	id="$type:$name"
	if first=$(cfg__section_lineno "$id"); then
		cfg__error "$lineno" \
			"duplicate $type name '$(gr_clean "$name")' (first defined on line $first)" \
			'rename one of the two sections, or merge their keys'
		return 1
	fi
	CFG__SECTION_ID="$id"
}

cfg__parse_key() {
	local line="$1" lineno="$2" section="$3" key value first
	[ "$section" = "$CFG_BAD_SECTION" ] && return 0
	case "$line" in
	*=*) ;;
	*)
		cfg__error "$lineno" 'not a section header and not a "key = value" line' \
			'write "key = value", or start the line with # to make it a comment'
		return 1
		;;
	esac
	cfg__trim_to "${line%%=*}"
	key="$CFG__TRIM"
	cfg__trim_to "${line#*=}"
	value="$CFG__TRIM"
	first=${key%"${key#?}"}
	case "$first" in
	[a-z]) ;;
	*)
		cfg__error "$lineno" "invalid key name '$(gr_clean "$key")'" \
			'keys are lower case and match [a-z][a-z0-9_-]*'
		return 1
		;;
	esac
	case "$key" in
	*[!a-z0-9_-]*)
		cfg__error "$lineno" "invalid key name '$(gr_clean "$key")'" \
			'keys are lower case and match [a-z][a-z0-9_-]*'
		return 1
		;;
	esac
	if [ -z "$section" ]; then
		cfg__error "$lineno" "key '$(gr_clean "$key")' sits outside any section" \
			'put it under [defaults], [target "name"] or [setup "name"]'
		return 1
	fi
	# Expansion is the only thing that ever rewrites a value, and it can only do
	# something when there is a tilde or a ${...} in it. The tilde is not
	# anchored here: in a find value it sits behind the strategy name.
	# shellcheck disable=SC2016 # "${" is a literal to be found, not an expansion
	case "$value" in
	*'~'* | *'${'*) value=$(cfg__expand_value "$key" "$value") ;;
	esac
	cfg__add_data "$section" "$key" "$value" "$lineno"
}

cfg__parse() {
	local file="$1" line lineno=0 section='' id
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		line=${line%$'\r'} # CRLF is tolerated, SPEC 4
		cfg__trim_to "$line"
		line="$CFG__TRIM"
		case "$line" in
		'' | '#'* | ';'*) continue ;;
		'['*)
			cfg__parse_header "$line" "$lineno" || :
			id="$CFG__SECTION_ID"
			if [ -n "$id" ]; then
				section="$id"
				CFG_SECTIONS="$CFG_SECTIONS$id$CFG_TAB$lineno$CFG_NL"
			else
				# The header was already reported. Swallow its keys instead of
				# blaming every one of them on the section above it.
				section="$CFG_BAD_SECTION"
			fi
			;;
		*) cfg__parse_key "$line" "$lineno" "$section" || : ;;
		esac
	done <"$file"
}

# --- validation --------------------------------------------------------------

cfg__keys_for_to() {
	case "$1" in
	defaults) CFG__KEYS="$CFG_KEYS_DEFAULTS" ;;
	target:*) CFG__KEYS="$CFG_KEYS_TARGET" ;;
	setup:*) CFG__KEYS="$CFG_KEYS_SETUP" ;;
	*) CFG__KEYS='' ;;
	esac
}

cfg__label_to() {
	case "$1" in
	defaults) CFG__LABEL='[defaults]' ;;
	target:*) CFG__LABEL="[target \"${1#target:}\"]" ;;
	setup:*) CFG__LABEL="[setup \"${1#setup:}\"]" ;;
	*) CFG__LABEL="$1" ;;
	esac
}

cfg__section_label() {
	cfg__label_to "$1"
	printf '%s' "$CFG__LABEL"
}

cfg__check_enum() {
	local lineno="$1" key="$2" value="$3"
	shift 3
	if cfg__in_list "$value" "$*"; then return 0; fi
	local list
	list=$(printf '%s, ' "$@")
	list=${list%, }
	cfg__error "$lineno" "invalid value '$(gr_clean "$value")' for '$key'" \
		"allowed: $list.$(cfg__suggest "$value" "$@")"
	return 1
}

cfg__check_value() {
	local section="$1" key="$2" value="$3" lineno="$4" abs part rest
	case "$key" in
	source_root)
		abs=$(cfg__resolve_rel "$CFG_CTX_ROOT" "$value")
		if ! gr_is_inside "$abs" "$CFG_CTX_ROOT"; then
			cfg__error "$lineno" "source_root '$(gr_clean "$value")' resolves outside the context repo" \
				"it must stay inside $(gr_clean "$CFG_CTX_ROOT")"
		fi
		;;
	search_depth)
		case "$value" in
		'' | *[!0-9]*)
			cfg__error "$lineno" "invalid value '$(gr_clean "$value")' for 'search_depth'" \
				'write a whole number between 1 and 10'
			return 0
			;;
		esac
		if [ "$value" -lt 1 ] || [ "$value" -gt 10 ]; then
			cfg__error "$lineno" "search_depth $value is out of range" \
				'write a whole number between 1 and 10'
		fi
		;;
	search_prune)
		rest="$value"
		while :; do
			part=${rest%%,*}
			case "$part" in
			'' | */*)
				cfg__error "$lineno" "invalid entry in search_prune: '$(gr_clean "$part")'" \
					'write a comma separated list of plain directory names, without slashes'
				return 0
				;;
			esac
			case "$rest" in
			*,*) rest=${rest#*,} ;;
			*) break ;;
			esac
		done
		;;
	backup) cfg__check_enum "$lineno" backup "$value" suffix timestamp abort || : ;;
	git_exclude | require | confirm) cfg__check_enum "$lineno" "$key" "$value" yes no || : ;;
	on_foreign_link) cfg__check_enum "$lineno" on_foreign_link "$value" warn abort || : ;;
	backup_suffix)
		case "$value" in
		*/*) cfg__error "$lineno" "backup_suffix '$(gr_clean "$value")' must not contain a slash" \
			'it is appended to a file name, not a path' ;;
		esac
		;;
	source)
		abs=$(cfg__resolve_rel "$CFG_SOURCE_ROOT" "$value")
		if gr_has_dotdot "$value" || ! gr_is_inside "$abs" "$CFG_SOURCE_ROOT"; then
			cfg__error "$lineno" "source '$(gr_clean "$value")' resolves outside the source root" \
				"it must name a directory inside $(gr_clean "$CFG_SOURCE_ROOT")"
		fi
		;;
	verify)
		case "$value" in
		/* | '~'*)
			cfg__error "$lineno" "verify path '$(gr_clean "$value")' must be relative to the checkout" \
				'write a path like .git or package.json'
			return 0
			;;
		esac
		if gr_has_dotdot "$value"; then
			cfg__error "$lineno" "verify path '$(gr_clean "$value")' must not contain a '..' segment" \
				'write the path without ".."'
		fi
		;;
	run)
		case "$value" in
		/* | '~'*)
			cfg__error "$lineno" "run path '$(gr_clean "$value")' must be relative to source_root" \
				'write a path like scripts/bootstrap.sh'
			return 0
			;;
		esac
		if gr_has_dotdot "$value"; then
			cfg__error "$lineno" "run path '$(gr_clean "$value")' must not contain a '..' segment" \
				'write the path without ".."'
			return 0
		fi
		if cfg__has_meta "$value"; then
			cfg__error "$lineno" "run path '$(gr_clean "$value")' contains shell metacharacters or whitespace" \
				'graft only prints this path as a reminder - keep it a plain relative path'
		fi
		;;
	esac
	return 0
}

cfg__check_keys() {
	local rec section key value lineno allowed first
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		cfg__unpack "$rec"
		section="$CFG__F1" key="$CFG__F2" value="$CFG__F3" lineno="$CFG__F4"
		cfg__keys_for_to "$section"
		allowed="$CFG__KEYS"
		if ! cfg__in_list "$key" "$allowed"; then
			cfg__clean_to "$key"
			cfg__label_to "$section"
			# shellcheck disable=SC2086 # the key list is a plain word list
			cfg__suggest_to "$key" $allowed
			cfg__error "$lineno" \
				"unknown key '$CFG__CLEAN' in section $CFG__LABEL" \
				"known keys here: ${allowed// /, }.$CFG__SUGGEST"
			continue
		fi
		if ! cfg__in_list "$key" "$CFG_KEYS_REPEATABLE"; then
			first=$(cfg__first_lineno "$section" "$key")
			if [ "$first" != "$lineno" ]; then
				cfg__error "$lineno" \
					"key '$key' may appear only once per section (first used on line $first)" \
					'delete one of the two lines, or move it into its own section'
				continue
			fi
		fi
		if [ -z "$value" ]; then
			cfg__error "$lineno" "key '$key' needs a value" "write: $key = <value>"
			continue
		fi
		cfg__check_value "$section" "$key" "$value" "$lineno"
	done <<<"$CFG_DATA"
}

# One link spec, in the context of the section it was written in.
cfg__check_link() {
	local section="$1" value="$2" lineno="$3" src dest kind abs tsource
	case "$value" in
	'!'*)
		dest=$(cfg__trim "${value#\!}")
		if [ -z "$dest" ]; then
			cfg__error "$lineno" 'link removal names no destination' \
				'write: link = !<dest-path> to drop a link inherited from [defaults]'
		fi
		return 0
		;;
	esac
	case "$value" in
	*'->'*) ;;
	*)
		cfg__error "$lineno" "invalid link value '$(gr_clean "$value")'" \
			'write: link = <source-path> -> <dest-path>, or link = !<dest-path> to drop an inherited link'
		return 0
		;;
	esac
	src=$(cfg__trim "${value%%->*}")
	dest=$(cfg__trim "${value#*->}")
	if [ -z "$src" ]; then
		cfg__error "$lineno" 'link source side is empty' \
			'write: link = <source-path> -> <dest-path>, or "." for the whole source directory'
		return 0
	fi
	if [ -z "$dest" ]; then
		cfg__error "$lineno" 'link destination side is empty' \
			'write: link = <source-path> -> <dest-path>'
		return 0
	fi
	kind=$(cfg__dest_kind "$dest")
	case "$kind" in
	ok) ;;
	absolute)
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' must be relative to the checkout root" \
			'drop the leading "/" - graft only ever writes inside a checkout'
		;;
	tilde)
		# shellcheck disable=SC2016 # $HOME is part of the message text
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' must be relative to the checkout root" \
			'drop the leading "~" - managing $HOME is not what graft does'
		;;
	dotdot)
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' must not contain a '..' segment" \
			'write the path without ".." so it provably stays inside the checkout'
		;;
	self)
		cfg__error "$lineno" 'link destination "." would replace the checkout itself' \
			'name a path inside the checkout, for example .github'
		;;
	git)
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' would write into the git directory" \
			'graft refuses .git and everything below it'
		;;
	control)
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' contains a tab" \
			'write the destination as a plain path, without control characters'
		;;
	deny:*)
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' is on the deny list (${kind#deny:})" \
			"graft never links over ${CFG_DENY// /, }"
		;;
	esac
	if gr_has_dotdot "$src"; then
		cfg__error "$lineno" "link source '$(gr_clean "$src")' must not contain a '..' segment" \
			'sources are relative to the target source directory and must stay inside the context repo'
		return 0
	fi
	case "$section" in
	target:*)
		tsource=$(cfg_target_get "${section#target:}" source "${section#target:}")
		abs=$(cfg__link_source_abs "$tsource" "$src")
		if ! gr_is_inside "$abs" "$CFG_CTX_ROOT"; then
			cfg__error "$lineno" "link source '$(gr_clean "$src")' resolves outside the context repo" \
				"it must stay inside $(gr_clean "$CFG_CTX_ROOT")"
		fi
		;;
	*)
		# A [defaults] link is resolved per target, so only the lexical rule
		# can be checked here; each target's own "source" is checked as well.
		case "$src" in
		/*)
			cfg__error "$lineno" "link source '$(gr_clean "$src")' must be relative to the target source directory" \
				'drop the leading "/" - sources live inside the context repo'
			;;
		esac
		;;
	esac
	return 0
}

# Link syntax plus "two links in one section must not share a dest" (SPEC 4.3).
cfg__check_links() {
	local rec section value lineno dest seen='' d prev
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		case "$rec" in
		*"$CFG_TAB"link"$CFG_TAB"*) ;;
		*) continue ;;
		esac
		cfg__unpack "$rec"
		[ "$CFG__F2" = link ] || continue
		section="$CFG__F1" value="$CFG__F3" lineno="$CFG__F4"
		cfg__check_link "$section" "$value" "$lineno"
		case "$value" in
		'!'*) continue ;;
		*'->'*) ;;
		*) continue ;;
		esac
		dest=$(cfg__norm_dest "$(cfg__trim "${value#*->}")")
		[ -n "$dest" ] || continue
		prev=''
		while IFS= read -r d; do
			[ -n "$d" ] || continue
			case "$d" in
			"$section$CFG_TAB$dest$CFG_TAB"*) prev=${d##*"$CFG_TAB"} ;;
			esac
		done <<<"$seen"
		if [ -n "$prev" ]; then
			cfg__error "$lineno" \
				"duplicate link destination '$(gr_clean "$dest")' in $(cfg__section_label "$section") (first used on line $prev)" \
				'two links in one section cannot share a destination'
		else
			seen="$seen$section$CFG_TAB$dest$CFG_TAB$lineno$CFG_NL"
		fi
	done <<<"$CFG_DATA"
}

cfg__check_find() {
	local value="$1" lineno="$2" depth="$3" strat arg rc
	case "$value" in
	*:*) ;;
	*)
		cfg__error "$lineno" "invalid find value '$(gr_clean "$value")'" \
			"write: find = <strategy>:<argument>. Strategies: ${CFG_STRATEGIES// /, }"
		return 0
		;;
	esac
	strat=${value%%:*}
	arg=${value#*:}
	if [ "$strat" = ask ]; then
		cfg__error "$lineno" "find strategy 'ask' does not exist" \
			'graft never prompts for a path - pin one with: graft --path <target>=DIR'
		return 0
	fi
	if ! cfg__in_list "$strat" "$CFG_STRATEGIES"; then
		# shellcheck disable=SC2086 # the strategy list is a fixed word list
		cfg__error "$lineno" "unknown find strategy '$(gr_clean "$strat")'" \
			"known strategies: ${CFG_STRATEGIES// /, }.$(cfg__suggest "$strat" $CFG_STRATEGIES)"
		return 0
	fi
	if [ -z "$arg" ] && [ "$strat" != env ]; then
		cfg__error "$lineno" "find strategy '$strat' needs an argument" \
			"write: find = $strat:<argument>"
		return 0
	fi
	case "$strat" in
	path)
		case "$arg" in
		/*) ;;
		'')
			# An expanded ${VAR} that was empty: soft fail at discovery time.
			;;
		*)
			# shellcheck disable=SC2016 # ${VAR} is part of the message text
			cfg__error "$lineno" "find path argument '$(gr_clean "$arg")' is not absolute" \
				'write an absolute path, a ~/ path or a ${VAR} reference'
			;;
		esac
		;;
	env)
		case "$arg" in
		'') ;;
		[!A-Za-z_]* | *[!A-Za-z0-9_]*)
			cfg__error "$lineno" "find env argument '$(gr_clean "$arg")' is not a variable name" \
				'variable names match [A-Za-z_][A-Za-z0-9_]*'
			;;
		esac
		;;
	origin-re)
		printf 'x\n' | grep -E -e "$arg" >/dev/null 2>&1
		rc=$?
		if [ "$rc" -ge 2 ]; then
			cfg__error "$lineno" "invalid regular expression in find origin-re: '$(gr_clean "$arg")'" \
				'write a POSIX extended regular expression'
		fi
		;;
	parent-of)
		if [ "$depth" -ge 4 ]; then
			cfg__error "$lineno" 'find parent-of is nested too deeply' \
				'nest at most four strategies'
			return 0
		fi
		cfg__check_find "$arg" "$lineno" $((depth + 1))
		;;
	target)
		if [ "$arg" = "$CFG__CUR_TARGET" ]; then
			cfg__error "$lineno" "find target '$(gr_clean "$arg")' refers to its own target" \
				'point it at a different target'
			return 0
		fi
		if ! cfg__is_target "$arg"; then
			# shellcheck disable=SC2046 # the target list is a word list here
			cfg__error "$lineno" "find target '$(gr_clean "$arg")' is not a defined target" \
				"define [target \"$(gr_clean "$arg")\"] or fix the name.$(cfg__suggest "$arg" $(cfg_targets))"
		fi
		;;
	esac
	return 0
}

cfg__check_finds() {
	local rec section value lineno
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		case "$rec" in
		*"$CFG_TAB"find"$CFG_TAB"*) ;;
		*) continue ;;
		esac
		cfg__unpack "$rec"
		[ "$CFG__F2" = find ] || continue
		section="$CFG__F1" value="$CFG__F3" lineno="$CFG__F4"
		CFG__CUR_TARGET=${section#target:}
		cfg__check_find "$value" "$lineno" 0
		CFG__CUR_TARGET=''
	done <<<"$CFG_DATA"
}

# A [setup] without a run key can never be printed as a reminder, which is the
# only thing a setup is for.
cfg__check_setups() {
	local rec id lineno
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		id=$(cfg__field "$rec" 1)
		case "$id" in setup:*) ;; *) continue ;; esac
		lineno=$(cfg__field "$rec" 2)
		if ! cfg__has "$id" run; then
			cfg__error "$lineno" "section $(cfg__section_label "$id") has no 'run' key" \
				'add: run = <path relative to source_root>'
		fi
	done <<<"$CFG_SECTIONS"
}

cfg_validate() {
	local n
	CFG_ERRORS="$CFG_PARSE_ERRORS"
	cfg__check_keys
	cfg__check_links
	cfg__check_finds
	cfg__check_setups
	cfg__sort_errors
	n=$(cfg__error_count)
	[ "$n" -gt "$CFG_ERROR_CAP" ] && n="$CFG_ERROR_CAP"
	return "$n"
}

# --- loading -----------------------------------------------------------------

cfg_find_conf() {
	local dir
	dir=$(gr_abspath "${1:-$PWD}")
	while :; do
		if [ -f "$dir/graft.conf" ]; then
			printf '%s\n' "$dir/graft.conf"
			return 0
		fi
		if [ "$dir" = / ]; then
			return 1
		fi
		dir=$(dirname -- "$dir")
	done
}

cfg_load() {
	local path="$1" abs
	CFG_FILE='' CFG_CTX_ROOT='' CFG_SOURCE_ROOT=''
	CFG_DATA='' CFG_ERRORS='' CFG_SECTIONS='' CFG_PARSE_ERRORS=''
	abs=$(gr_abspath "$path")
	CFG_FILE="$abs"
	CFG_CTX_ROOT=$(dirname -- "$abs")
	CFG_SOURCE_ROOT="$CFG_CTX_ROOT"
	if [ ! -f "$abs" ] || [ ! -r "$abs" ]; then
		cfg__error 0 "cannot read config file: $(gr_clean "$abs")" \
			'create one with: graft init'
		CFG_PARSE_ERRORS="$CFG_ERRORS"
		return "$GRAFT_EX_USAGE"
	fi
	cfg__parse "$abs"
	CFG_PARSE_ERRORS="$CFG_ERRORS"
	CFG_SOURCE_ROOT=$(cfg__resolve_rel "$CFG_CTX_ROOT" "$(cfg_get defaults source_root .)")
	cfg_validate || :
	if [ -n "$CFG_ERRORS" ]; then
		return "$GRAFT_EX_USAGE"
	fi
	return 0
}

cfg_print_errors() {
	local rec lineno msg hint src
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		lineno=$(cfg__field "$rec" 1)
		msg=$(cfg__field "$rec" 2)
		hint=$(cfg__field "$rec" 3)
		if [ "$lineno" = 0 ]; then
			gr_err "$(gr_clean "$CFG_FILE"): $msg"
		else
			gr_err "$(gr_clean "$CFG_FILE"):$lineno: $msg"
		fi
		if [ -n "$hint" ]; then
			gr_hint "$hint"
		fi
		if [ "$lineno" != 0 ] && [ -r "$CFG_FILE" ]; then
			src=$(sed -n "${lineno}p" "$CFG_FILE" 2>/dev/null)
			if [ -n "$src" ]; then
				gr_hint "$lineno | $(gr_clean "${src%$'\r'}")"
			fi
		fi
	done <<<"$CFG_ERRORS"
}

# --- effective links ---------------------------------------------------------

# Drop every entry of CFG__LIST whose destination equals $1. Written as an
# in place filter on a module global because a command substitution would eat
# the trailing newline of the list on every single removal.
cfg__drop_dest() {
	local dest="$1" out='' rec
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		if [ "${rec#*"$CFG_TAB"}" != "$dest" ]; then
			out="$out$rec$CFG_NL"
		fi
	done <<<"$CFG__LIST"
	CFG__LIST="$out"
}

# Inherited [defaults] links first, then the target's own. A target link with
# the same destination replaces the inherited one (that is the point of
# inheriting), and "!dest" drops whatever is currently in the list.
# Sources are containment checked here; their existence is a plan time concern.
cfg_target_links() {
	local t="$1" spec src dest srcabs tsource all rc=0
	tsource=$(cfg_target_get "$t" source "$t")
	all=$(
		cfg_get_all defaults link
		cfg_get_all "target:$t" link
	)
	CFG__LIST=''
	while IFS= read -r spec; do
		[ -n "$spec" ] || continue
		case "$spec" in
		'!'*)
			cfg__drop_dest "$(cfg__norm_dest "$(cfg__trim "${spec#\!}")")"
			continue
			;;
		*'->'*) ;;
		*)
			rc=1
			continue
			;;
		esac
		src=$(cfg__trim "${spec%%->*}")
		dest=$(cfg__norm_dest "$(cfg__trim "${spec#*->}")")
		if [ -z "$src" ] || [ "$(cfg__dest_kind "$dest")" != ok ]; then
			rc=1
			continue
		fi
		if gr_has_dotdot "$src"; then
			rc=1
			continue
		fi
		srcabs=$(cfg__link_source_abs "$tsource" "$src")
		if ! gr_is_inside "$srcabs" "$CFG_CTX_ROOT"; then
			rc=1
			continue
		fi
		cfg__drop_dest "$dest"
		CFG__LIST="$CFG__LIST$srcabs$CFG_TAB$dest$CFG_NL"
	done <<<"$all"
	printf '%s' "$CFG__LIST"
	return "$rc"
}
