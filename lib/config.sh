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
# bash 3.2: no associative arrays. Parsed data therefore lives in parallel
# *indexed* arrays plus a section table that records, for every section, which
# records belong to it. That index is what keeps the module linear: "every
# `link` of [target x]" is a walk over ten entries, not over the whole file.
# The earlier design kept one TSV string and re-scanned it for every question,
# which made `graft check` quadratic - 200 targets took 83s.
#
# Section ids used in the section table and accepted by cfg_get/cfg_get_all -
# this is the one encoding, there is no second spelling:
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

# The built-in defaults of SPEC 4.1/4.2, as one data row per key instead of a
# case arm per key. search_root is absent on purpose: its default is $HOME,
# which is not a constant.
CFG_DEFAULTS='source_root=. search_depth=4 search_prune=node_modules,vendor,target,.cache,Library,dist,build backup=timestamp backup_suffix=.graft-backup git_exclude=yes on_foreign_link=warn require=no confirm=no'

# Keys whose value must be one of a fixed set (SPEC 4.1). Same table shape, so
# the validator, the "allowed:" list in the message and the typo suggestion all
# read off this one line and can never drift apart.
CFG_ENUMS='backup=suffix,timestamp,abort git_exclude=yes,no require=yes,no confirm=yes,no on_foreign_link=warn,abort'

# SPEC 4.3: graft never links over these, wherever they sit in a checkout.
CFG_DENY='.ssh .gnupg .aws .config/gh .netrc .bashrc .zshrc .profile .bash_profile .gitconfig'

# Exit statuses only carry 0..255, so the error count is reported capped.
CFG_ERROR_CAP=250

# --- module state ------------------------------------------------------------

CFG_FILE=''         # absolute path of graft.conf
CFG_CTX_ROOT=''     # absolute path of the context repo
CFG_SOURCE_ROOT=''  # absolute path of the source root
CFG_DATA=''         # section \t key \t value \t lineno   (SPEC 9.1, rendered)
CFG_ERRORS=''       # lineno \t message \t hint
CFG_PARSE_ERRORS='' # the lexical subset of CFG_ERRORS, so cfg_validate can rerun

# Records: one entry per "key = value" line, in file order. Values are kept
# *unescaped* here; CFG_DATA is a rendering for humans and for SPEC 9.1 and is
# never read back, which is why this module needs no TSV decoder at all.
CFG_NREC=0
CFG_RSEC=() # index into the section table
CFG_RKEY=()
CFG_RVAL=()
CFG_RLN=()

# Sections, in file order, each with the list of record indices that belong to
# it. A list rather than a first/last range because a second [defaults] merges
# into the first (an INI reader is expected to do that), so a section's records
# are not necessarily contiguous. Indices are digits, so the unquoted `for r in
# ${CFG_SREC[si]}` below splits on space and can match no glob.
CFG_NSEC=0
CFG_SID=()
CFG_SLN=()
CFG_SREC=()
CFG_SDEF=-1 # index of [defaults], or -1 - the most asked for section by far

# The name to index map, and bash 3.2's missing associative array: every
# section id falls into one of CFG_HASH_N buckets, and a bucket holds the space
# separated indices of the sections in it. Looking a section up therefore walks
# a handful of entries rather than all of them (see the module header).
#
# The bucket comes from the length and the last two characters, because that is
# where section ids actually differ (api, web, proj001, proj002, ...). A bad
# guess only makes one bucket longer; it can never give a wrong answer, because
# the walk still compares the whole id.
CFG_HASH_N=251
CFG_SBUCK=()

# Scratch / out parameters. Assigning instead of printing keeps the hot paths
# and the whole error path free of subshells.
CFG__TRIM='' CFG__SUGGEST='' CFG__TVAL=''
CFG__KEYS='' CFG__LABEL=''
CFG__DEST='' CFG__KIND='' CFG__VAL='' CFG__BUCKET=0
CFG__SPEC='' CFG__SRC='' CFG__RAW=''
CFG__SI=-1 CFG__KI=-1 # section / record index found by the two seekers
CFG__SEEN=''          # per section "dest seen on line" list, see below
CFG__CUR_TARGET=''    # target whose find strategy is being validated

# Effective link list of cfg_target_links, built in place (see cfg__drop_dest).
CFG__LN=0
CFG__LSRC=()
CFG__LDEST=()

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

# Trimming happens once per line and per field, so it assigns rather than
# prints: a command substitution here is a fork per config line.
cfg__trim_to() {
	local s="$1"
	s=${s#"${s%%[![:space:]]*}"}
	CFG__TRIM=${s%"${s##*[![:space:]]}"}
}

# Value for <key> in a "key=value key=value ..." table, in CFG__TVAL.
cfg__table_get() {
	local key="$1" entry
	CFG__TVAL=''
	# shellcheck disable=SC2086 # the table is a fixed word list, split on space
	for entry in $2; do
		case "$entry" in
		"$key"=*)
			CFG__TVAL=${entry#*=}
			return 0
			;;
		esac
	done
	return 1
}

# --- typo heuristic ----------------------------------------------------------

# True when one edit - insert, delete, substitute, or a swap of two adjacent
# characters - turns $1 into $2. That is all a keyword typo ever is.
#
# Strip the common prefix and the common suffix; what is left is the edit
# itself, and a single edit leaves at most one character on each side (two, and
# mirrored, for a swap). One pass, no distance matrix.
cfg__near() {
	local a="$1" b="$2" la=${#1} lb=${#2} i=0 j=0 ra rb
	[ "$a" = "$b" ] && return 0
	case $((la - lb)) in
	0 | 1 | -1) ;;
	*) return 1 ;;
	esac
	while [ "$i" -lt "$la" ] && [ "$i" -lt "$lb" ] && [ "${a:i:1}" = "${b:i:1}" ]; do
		i=$((i + 1))
	done
	while [ $((i + j)) -lt "$la" ] && [ $((i + j)) -lt "$lb" ] \
		&& [ "${a:la-j-1:1}" = "${b:lb-j-1:1}" ]; do
		j=$((j + 1))
	done
	ra=${a:i:la-i-j}
	rb=${b:i:lb-i-j}
	case "${#ra},${#rb}" in
	0,1 | 1,0 | 1,1) return 0 ;;
	2,2) [ "$ra" = "${rb:1:1}${rb:0:1}" ] && return 0 ;;
	esac
	return 1
}

# cfg__suggest_to <word> <candidates...> -> CFG__SUGGEST, either the empty
# string or " Did you mean 'x'?".
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
	local s="$1" out='' pre rest name var
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
		*)
			var=$(cfg__env_get "$name")
			# An unset variable keeps its ${NAME} spelling rather than
			# vanishing. Two reasons. `find = path:${WORK}` would otherwise
			# collapse to `path:` - an empty argument, which validation
			# rightly calls a broken line, so a committed config blew up for
			# every colleague who did not happen to export WORK. And the
			# leftover text is what the "tried: ..." diagnostic then shows,
			# which names the variable instead of printing a blank.
			if [ -n "$var" ]; then
				out="$out$pre$var"
			else
				out="$out$pre\${$name}"
			fi
			;;
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

# Checks run in phases, so the messages have to be put back into file order
# before a human sees them. -s keeps two problems on one line in the order they
# were found.
cfg__sort_errors() {
	local sorted
	[ -n "$CFG_ERRORS" ] || return 0
	sorted=$(printf '%s' "$CFG_ERRORS" | sort -s -n -k1,1)
	CFG_ERRORS="$sorted$CFG_NL"
}

# --- the record and section tables -------------------------------------------

cfg__add_section() {
	CFG_SID[CFG_NSEC]=$1
	CFG_SLN[CFG_NSEC]=$2
	CFG_SREC[CFG_NSEC]=''
	cfg__bucket_to "$1"
	CFG_SBUCK[CFG__BUCKET]="${CFG_SBUCK[CFG__BUCKET]:-} $CFG_NSEC"
	CFG__SI=$CFG_NSEC
	[ "$1" = defaults ] && CFG_SDEF=$CFG_NSEC
	CFG_NSEC=$((CFG_NSEC + 1))
	return 0
}

cfg__add_record() {
	local si="$1"
	CFG_RSEC[CFG_NREC]=$si
	CFG_RKEY[CFG_NREC]=$2
	CFG_RVAL[CFG_NREC]=$3
	CFG_RLN[CFG_NREC]=$4
	CFG_SREC[si]="${CFG_SREC[si]} $CFG_NREC"
	CFG_NREC=$((CFG_NREC + 1))
}

# CFG_DATA, the escaped TSV rendering SPEC 9.1 promises, built in one pass at
# the end of the parse. Deliberately not appended to per record: `s="$s..."`
# copies the whole accumulated string every time, which is quadratic in the
# number of records - and nothing in the tool reads the value back.
cfg__render_data() {
	local i=0 v
	# Neither a `case` nor a nested command substitution in here: bash 3.2
	# miscounts parentheses inside $( ), and this is the one place in the
	# module that would trip over it (invariant I9).
	CFG_DATA=$(
		while [ "$i" -lt "$CFG_NREC" ]; do
			v=${CFG_RVAL[i]}
			v=${v//\\/\\\\}
			v=${v//"$CFG_TAB"/\\t}
			printf '%s\t%s\t%s\t%s\n' \
				"${CFG_SID[CFG_RSEC[i]]}" "${CFG_RKEY[i]}" "$v" "${CFG_RLN[i]}"
			i=$((i + 1))
		done
	)
	# A command substitution eats trailing newlines; every record ends with one.
	[ -n "$CFG_DATA" ] && CFG_DATA="$CFG_DATA$CFG_NL"
	return 0
}

cfg__bucket_to() {
	local s="$1" n=${#1} a=0 b=0
	if [ "$n" -gt 0 ]; then printf -v a '%d' "'${s:n-1:1}"; fi
	if [ "$n" -gt 1 ]; then printf -v b '%d' "'${s:n-2:1}"; fi
	CFG__BUCKET=$(((a * 131 + b * 7 + n) % CFG_HASH_N))
}

# Index of section <id> in CFG__SI, or -1 and status 1.
cfg__sec_index() {
	local i
	cfg__bucket_to "$1"
	# shellcheck disable=SC2086 # a list of decimal indices, split on space
	for i in ${CFG_SBUCK[CFG__BUCKET]:-}; do
		if [ "${CFG_SID[i]}" = "$1" ]; then
			CFG__SI=$i
			return 0
		fi
	done
	CFG__SI=-1
	return 1
}

# First / last record index for <key> inside section <si>, in CFG__KI, or -1
# and status 1. Both walk that one section's records, never the whole file.
cfg__first_in() {
	local key="$2" i
	# shellcheck disable=SC2086 # a list of decimal indices, split on space
	for i in ${CFG_SREC[$1]}; do
		if [ "${CFG_RKEY[i]}" = "$key" ]; then
			CFG__KI=$i
			return 0
		fi
	done
	CFG__KI=-1
	return 1
}

cfg__last_in() {
	local key="$2" i
	CFG__KI=-1
	# shellcheck disable=SC2086 # a list of decimal indices, split on space
	for i in ${CFG_SREC[$1]}; do
		[ "${CFG_RKEY[i]}" = "$key" ] && CFG__KI=$i
	done
	[ "$CFG__KI" -ge 0 ]
}

# --- data access -------------------------------------------------------------

# <section> is a section id as encoded above: `defaults`, `target:<name>` or
# `setup:<name>`. Anything else simply matches no record.
cfg_get_all() {
	local key="$2" i
	cfg__sec_index "$1" || return 0
	# shellcheck disable=SC2086 # a list of decimal indices, split on space
	for i in ${CFG_SREC[CFG__SI]}; do
		[ "${CFG_RKEY[i]}" = "$key" ] && printf '%s\n' "${CFG_RVAL[i]}"
	done
	return 0
}

# Last value wins, which is what an INI reader is expected to do.
cfg_get() {
	if cfg__sec_index "$1" && cfg__last_in "$CFG__SI" "$2"; then
		printf '%s\n' "${CFG_RVAL[CFG__KI]}"
		return 0
	fi
	if [ $# -ge 3 ]; then printf '%s\n' "$3"; fi
	return 0
}

# The built-in defaults of SPEC 4.1, so that callers do not have to carry them.
cfg_default() {
	case "$1" in
	search_root) printf '%s\n' "$HOME" ;;
	*) cfg__table_get "$1" "$CFG_DEFAULTS" && printf '%s\n' "$CFG__TVAL" ;;
	esac
	return 0
}

# Value of <key> for section <si>, falling back to [defaults], in CFG__VAL.
# Status 1 means neither section had the key and CFG__VAL holds the fallback.
# This is cfg_target_get without the name lookup and without the fork, for the
# loops below that already know which section they are in.
cfg__inherited() {
	local si="$1" key="$2"
	if [ "$si" -ge 0 ] && cfg__last_in "$si" "$key"; then
		CFG__VAL=${CFG_RVAL[CFG__KI]}
		return 0
	fi
	if [ "$CFG_SDEF" -ge 0 ] && cfg__last_in "$CFG_SDEF" "$key"; then
		CFG__VAL=${CFG_RVAL[CFG__KI]}
		return 0
	fi
	CFG__VAL="$3"
	return 1
}

cfg_target_get() {
	local si=-1
	cfg__sec_index "target:$1" && si=$CFG__SI
	if cfg__inherited "$si" "$2" "${3:-}" || [ $# -ge 3 ]; then
		printf '%s\n' "$CFG__VAL"
		return 0
	fi
	cfg_default "$2"
}

cfg_targets() {
	local i=0
	while [ "$i" -lt "$CFG_NSEC" ]; do
		case "${CFG_SID[i]}" in
		target:*) printf '%s\n' "${CFG_SID[i]#target:}" ;;
		esac
		i=$((i + 1))
	done
}

cfg_setups() {
	local i=0 desc run
	while [ "$i" -lt "$CFG_NSEC" ]; do
		case "${CFG_SID[i]}" in
		setup:*)
			desc='' run=''
			cfg__last_in "$i" description && desc=${CFG_RVAL[CFG__KI]}
			cfg__last_in "$i" run && run=${CFG_RVAL[CFG__KI]}
			printf '%s\t%s\t%s\n' "${CFG_SID[i]#setup:}" "$desc" "$run"
			;;
		esac
		i=$((i + 1))
	done
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
# every target that is not the last one listed (pitfall P8).
cfg__is_target() {
	cfg__sec_index "target:$1"
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
#
# The arms are tried in this order until nothing matches any more. Slashes go
# first: the other order turns ".//x" into "/x", which then reads as an
# absolute path - still refused, but with a message that sends the reader
# looking for a leading slash they never wrote.
cfg__norm_dest_to() {
	local d="$1"
	while :; do
		case "$d" in
		*//*) d=${d//\/\///} ;;
		*/./*) d=${d//\/.\///} ;;
		'./'*) d=${d#./} ;;
		*/.) d=${d%/.} ;;
		*/) d=${d%/} ;;
		*) break ;;
		esac
	done
	CFG__DEST=$d
}

# One word describing why a link destination is unusable, or "ok", in
# CFG__KIND. SPEC 4.3, and this is the check invariant I4 leans on.
# The order of the questions is load bearing: ".git/../x" must be reported as
# a "..", not as a write into the git directory.
cfg__dest_kind_to() {
	local d entry
	cfg__norm_dest_to "$1"
	d=$CFG__DEST
	CFG__KIND=ok
	# A tab in a destination silently shifts the fields of the internal plan
	# record, which made --dry-run plan one path and link do nothing at all.
	# Control characters have no business in a path we are about to create.
	# shellcheck disable=SC2088 # a literal tilde is what we are looking for
	case "$d" in
	*"$CFG_TAB"*) CFG__KIND=control ;;
	'') CFG__KIND=empty ;;
	/*) CFG__KIND=absolute ;;
	'~' | '~/'*) CFG__KIND=tilde ;;
	esac
	[ "$CFG__KIND" = ok ] || return 0
	if gr_has_dotdot "$d"; then
		CFG__KIND=dotdot
		return 0
	fi
	case "$d" in
	'.') CFG__KIND=self ;;
	'.git' | '.git/'*) CFG__KIND=git ;;
	esac
	[ "$CFG__KIND" = ok ] || return 0
	for entry in $CFG_DENY; do
		case "$d" in
		"$entry" | "$entry"/*)
			CFG__KIND="deny:$entry"
			return 0
			;;
		esac
	done
	return 0
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

# Adds the section and sets CFG__SI, or reports the problem and returns 1.
# It cannot print the id instead: a command substitution would run it in a
# subshell and every error it recorded would be lost.
cfg__parse_header() {
	local line="$1" lineno="$2" inner type rest name first
	case "$line" in
	*']') ;;
	*)
		cfg__error "$lineno" "malformed section header" \
			"write [defaults], [target \"name\"] or [setup \"name\"]"
		return 1
		;;
	esac
	inner=${line#\[}
	cfg__trim_to "${inner%\]}"
	inner="$CFG__TRIM"
	type=${inner%%[[:space:]]*}
	cfg__trim_to "${inner#"$type"}"
	rest="$CFG__TRIM"
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
		# A second [defaults] merges into the first, the way an INI reader is
		# expected to behave. Only *named* sections have to be unique (4.2).
		cfg__sec_index defaults || cfg__add_section defaults "$lineno"
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
	cfg__trim_to "$name"
	if [ -z "$CFG__TRIM" ]; then
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
	if cfg__sec_index "$type:$name"; then
		cfg__error "$lineno" \
			"duplicate $type name '$(gr_clean "$name")' (first defined on line ${CFG_SLN[CFG__SI]})" \
			'rename one of the two sections, or merge their keys'
		return 1
	fi
	cfg__add_section "$type:$name" "$lineno"
}

# <sec> is a section index, or -1 for "no section yet".
cfg__parse_key() {
	local line="$1" lineno="$2" sec="$3" key value first
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
	if [ "$sec" -lt 0 ]; then
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
	cfg__add_record "$sec" "$key" "$value" "$lineno"
}

cfg__parse() {
	local file="$1" line lineno=0 sec=-1
	while IFS= read -r line || [ -n "$line" ]; do
		lineno=$((lineno + 1))
		line=${line%$'\r'} # CRLF is tolerated, SPEC 4
		cfg__trim_to "$line"
		line="$CFG__TRIM"
		case "$line" in
		'' | '#'* | ';'*) continue ;;
		'['*)
			if cfg__parse_header "$line" "$lineno"; then
				sec=$CFG__SI
			else
				# The header was already reported. Swallow its keys instead of
				# blaming every one of them on the section above it.
				sec=-2
			fi
			;;
		*)
			[ "$sec" = -2 ] && continue
			cfg__parse_key "$line" "$lineno" "$sec" || :
			;;
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

# <allowed> is the comma separated value list from CFG_ENUMS.
cfg__check_enum() {
	local lineno="$1" key="$2" value="$3" allowed="${4//,/ }"
	cfg__in_list "$value" "$allowed" && return 0
	# shellcheck disable=SC2086 # the allowed list is a plain word list
	cfg__suggest_to "$value" $allowed
	cfg__error "$lineno" "invalid value '$(gr_clean "$value")' for '$key'" \
		"allowed: ${allowed// /, }.$CFG__SUGGEST"
	return 1
}

# The "relative to <base>, and no way out of it" rule that `verify` and `run`
# share (SPEC 4.2, 4.5). Returns 1 once it has reported something, so that the
# caller can stop looking at the value.
cfg__check_relpath() {
	local lineno="$1" what="$2" value="$3" base="$4" hint="$5"
	case "$value" in
	/* | '~'*)
		cfg__error "$lineno" "$what '$(gr_clean "$value")' must be relative to $base" "$hint"
		return 1
		;;
	esac
	if gr_has_dotdot "$value"; then
		cfg__error "$lineno" "$what '$(gr_clean "$value")' must not contain a '..' segment" \
			'write the path without ".."'
		return 1
	fi
	return 0
}

cfg__check_value() {
	local key="$2" value="$3" lineno="$4" abs part rest
	if cfg__table_get "$key" "$CFG_ENUMS"; then
		cfg__check_enum "$lineno" "$key" "$value" "$CFG__TVAL" || :
		return 0
	fi
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
		cfg__check_relpath "$lineno" 'verify path' "$value" 'the checkout' \
			'write a path like .git or package.json' || :
		;;
	run)
		cfg__check_relpath "$lineno" 'run path' "$value" 'source_root' \
			'write a path like scripts/bootstrap.sh' || return 0
		if cfg__has_meta "$value"; then
			cfg__error "$lineno" "run path '$(gr_clean "$value")' contains shell metacharacters or whitespace" \
				'graft only prints this path as a reminder - keep it a plain relative path'
		fi
		;;
	esac
	return 0
}

# One record of one section. Split out of the loop below so that "this value is
# already wrong, stop" is a `return` instead of a chain of nested ifs.
cfg__check_record() {
	local si="$1" i="$2" allowed="$3" key value lineno
	key=${CFG_RKEY[i]} value=${CFG_RVAL[i]} lineno=${CFG_RLN[i]}
	if ! cfg__in_list "$key" "$allowed"; then
		cfg__label_to "${CFG_SID[si]}"
		# shellcheck disable=SC2086 # the key list is a plain word list
		cfg__suggest_to "$key" $allowed
		cfg__error "$lineno" \
			"unknown key '$(gr_clean "$key")' in section $CFG__LABEL" \
			"known keys here: ${allowed// /, }.$CFG__SUGGEST"
		return 0
	fi
	if ! cfg__in_list "$key" "$CFG_KEYS_REPEATABLE"; then
		cfg__first_in "$si" "$key" || :
		if [ "$CFG__KI" != "$i" ]; then
			cfg__error "$lineno" \
				"key '$key' may appear only once per section (first used on line ${CFG_RLN[CFG__KI]})" \
				'delete one of the two lines, or move it into its own section'
			return 0
		fi
	fi
	if [ -z "$value" ]; then
		cfg__error "$lineno" "key '$key' needs a value" "write: $key = <value>"
		return 0
	fi
	cfg__check_value "${CFG_SID[si]}" "$key" "$value" "$lineno"
}

# Decompose one `link` value once, for the two readers that have to agree on
# what it means: cfg__check_link, which turns each verdict into a message, and
# cfg_target_links, which silently skips what is not usable. They used to split
# it each in their own way, which is a standing invitation to drift.
#   CFG__SPEC  remove | link | no-arrow | no-source | no-dest
#   CFG__SRC   left side, trimmed
#   CFG__RAW   right side, trimmed - what an error message quotes back
#   CFG__DEST  right side, normalised - what we compare and store
#   CFG__KIND  the verdict on CFG__DEST (see cfg__dest_kind_to)
cfg__split_link() {
	local value="$1"
	CFG__SRC='' CFG__RAW='' CFG__DEST='' CFG__KIND=ok
	case "$value" in
	'!'*)
		cfg__trim_to "${value#\!}"
		CFG__RAW="$CFG__TRIM"
		cfg__norm_dest_to "$CFG__TRIM"
		CFG__SPEC='remove'
		return 0
		;;
	*'->'*) ;;
	*)
		CFG__SPEC='no-arrow'
		return 0
		;;
	esac
	cfg__trim_to "${value%%->*}"
	CFG__SRC="$CFG__TRIM"
	cfg__trim_to "${value#*->}"
	CFG__RAW="$CFG__TRIM"
	CFG__SPEC='no-source'
	[ -n "$CFG__SRC" ] || return 0
	CFG__SPEC='no-dest'
	[ -n "$CFG__RAW" ] || return 0
	cfg__dest_kind_to "$CFG__RAW"
	CFG__SPEC='link'
	return 0
}

# One link spec. <tsource> is the target's effective `source` value, or the
# empty string in [defaults], where there is no single source directory yet.
cfg__check_link() {
	local si="$1" lineno="$3" tsource="$4" src dest prev abs reason='' hint=''
	cfg__split_link "$2"
	src="$CFG__SRC" dest="$CFG__RAW"
	case "$CFG__SPEC" in
	link) ;;
	remove)
		if [ -z "$dest" ]; then
			cfg__error "$lineno" 'link removal names no destination' \
				'write: link = !<dest-path> to drop a link inherited from [defaults]'
		fi
		return 0
		;;
	no-arrow)
		cfg__error "$lineno" "invalid link value '$(gr_clean "$2")'" \
			'write: link = <source-path> -> <dest-path>, or link = !<dest-path> to drop an inherited link'
		return 0
		;;
	no-source)
		cfg__error "$lineno" 'link source side is empty' \
			'write: link = <source-path> -> <dest-path>, or "." for the whole source directory'
		return 0
		;;
	no-dest)
		cfg__error "$lineno" 'link destination side is empty' \
			'write: link = <source-path> -> <dest-path>'
		return 0
		;;
	esac
	# One line per rejected kind: the pattern, why it is refused and what to do
	# instead. The two that do not fit the "link destination 'X' ..." shape get
	# their own arm below.
	# shellcheck disable=SC2016 # $HOME in the tilde hint is message text
	case "$CFG__KIND" in
	ok) ;;
	absolute) reason='must be relative to the checkout root' hint='drop the leading "/" - graft only ever writes inside a checkout' ;;
	tilde) reason='must be relative to the checkout root' hint='drop the leading "~" - managing $HOME is not what graft does' ;;
	dotdot) reason="must not contain a '..' segment" hint='write the path without ".." so it provably stays inside the checkout' ;;
	git) reason='would write into the git directory' hint='graft refuses .git and everything below it' ;;
	control) reason='contains a tab' hint='write the destination as a plain path, without control characters' ;;
	self)
		cfg__error "$lineno" 'link destination "." would replace the checkout itself' \
			'name a path inside the checkout, for example .github'
		;;
	deny:*)
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' is on the deny list (${CFG__KIND#deny:})" \
			"graft never links over ${CFG_DENY// /, }"
		;;
	esac
	if [ -n "$reason" ]; then
		cfg__error "$lineno" "link destination '$(gr_clean "$dest")' $reason" "$hint"
	fi
	if gr_has_dotdot "$src"; then
		cfg__error "$lineno" "link source '$(gr_clean "$src")' must not contain a '..' segment" \
			'sources are relative to the target source directory and must stay inside the context repo'
	else
		case "${CFG_SID[si]}" in
		target:*)
			abs=$(cfg__link_source_abs "$tsource" "$src")
			if ! gr_is_inside "$abs" "$CFG_CTX_ROOT"; then
				cfg__error "$lineno" "link source '$(gr_clean "$src")' resolves outside the context repo" \
					"it must stay inside $(gr_clean "$CFG_CTX_ROOT")"
			fi
			;;
		*)
			# A [defaults] link is resolved per target, so only the lexical
			# rule can be checked here; each target's own "source" is checked
			# as well.
			case "$src" in
			/*)
				cfg__error "$lineno" "link source '$(gr_clean "$src")' must be relative to the target source directory" \
					'drop the leading "/" - sources live inside the context repo'
				;;
			esac
			;;
		esac
	fi
	# "Two links in one section must not share a destination" (SPEC 4.3).
	# CFG__SEEN is a module global because the list has to survive back into
	# the loop in cfg__check_sections, which resets it once per section.
	dest="$CFG__DEST"
	[ -n "$dest" ] || return 0
	case "$CFG__SEEN" in
	*"$CFG_NL$dest$CFG_TAB"*)
		prev=${CFG__SEEN#*"$CFG_NL$dest$CFG_TAB"}
		prev=${prev%%"$CFG_NL"*}
		cfg__error "$lineno" \
			"duplicate link destination '$(gr_clean "$dest")' in $(cfg__section_label "${CFG_SID[si]}") (first used on line $prev)" \
			'two links in one section cannot share a destination'
		;;
	*) CFG__SEEN="$CFG__SEEN$dest$CFG_TAB$lineno$CFG_NL" ;;
	esac
	return 0
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
		# A ${VAR} that is still spelled out is a variable this machine does
		# not have. That is a fact about the machine, not a mistake in the
		# file - the same committed config has to work for the colleague who
		# does export it. It fails softly at discovery instead, and the
		# "tried: path:${VAR}" line names what was missing.
		# shellcheck disable=SC2016 # matching a literal ${, not expanding
		case "$arg" in
		/* | '' | *'${'*) ;;
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

# One pass over the parsed config: every section, then every record in it.
# This used to be four passes - keys, links, finds, setups - each with its own
# loop scaffolding and each one re-deriving which section it was looking at.
# Walking the data once means the section's label, its allowed keys, its
# effective `source` and its per section "destination already used" list are
# each worked out exactly once.
cfg__check_sections() {
	local si=0 i id allowed tsource
	while [ "$si" -lt "$CFG_NSEC" ]; do
		id=${CFG_SID[si]}
		cfg__keys_for_to "$id"
		allowed="$CFG__KEYS"
		tsource=''
		case "$id" in
		target:*)
			cfg__inherited "$si" source "${id#target:}" || :
			tsource="$CFG__VAL"
			;;
		setup:*)
			# A [setup] without a run key can never be printed as a reminder,
			# which is the only thing a setup is for.
			if ! cfg__last_in "$si" run; then
				cfg__error "${CFG_SLN[si]}" "section $(cfg__section_label "$id") has no 'run' key" \
					'add: run = <path relative to source_root>'
			fi
			;;
		esac
		# Reset per section: sharing a destination is only a conflict within
		# one section, and cfg__check_link is where that is reported.
		CFG__SEEN="$CFG_NL"
		# shellcheck disable=SC2086 # a list of decimal indices, split on space
		for i in ${CFG_SREC[si]}; do
			cfg__check_record "$si" "$i" "$allowed"
			case "${CFG_RKEY[i]}" in
			link)
				cfg__check_link "$si" "${CFG_RVAL[i]}" "${CFG_RLN[i]}" "$tsource"
				;;
			find)
				CFG__CUR_TARGET=${id#target:}
				cfg__check_find "${CFG_RVAL[i]}" "${CFG_RLN[i]}" 0
				CFG__CUR_TARGET=''
				;;
			esac
		done
		si=$((si + 1))
	done
}

cfg_validate() {
	local n=0
	CFG_ERRORS="$CFG_PARSE_ERRORS"
	cfg__check_sections
	cfg__sort_errors
	# grep -c reads its input to the end. A short circuiting consumer here
	# would be pitfall P8 all over again.
	[ -n "$CFG_ERRORS" ] && n=$(grep -c . <<<"$CFG_ERRORS")
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
	CFG_DATA='' CFG_ERRORS='' CFG_PARSE_ERRORS=''
	CFG_NREC=0 CFG_RSEC=() CFG_RKEY=() CFG_RVAL=() CFG_RLN=()
	CFG_NSEC=0 CFG_SID=() CFG_SLN=() CFG_SREC=() CFG_SBUCK=() CFG_SDEF=-1
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
	cfg__render_data
	CFG_PARSE_ERRORS="$CFG_ERRORS"
	CFG_SOURCE_ROOT=$(cfg__resolve_rel "$CFG_CTX_ROOT" "$(cfg_get defaults source_root .)")
	cfg_validate || :
	if [ -n "$CFG_ERRORS" ]; then
		return "$GRAFT_EX_USAGE"
	fi
	return 0
}

cfg_print_errors() {
	local rec lineno msg hint src rest
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		lineno=${rec%%"$CFG_TAB"*}
		rest=${rec#*"$CFG_TAB"}
		msg=${rest%%"$CFG_TAB"*}
		hint=${rest#*"$CFG_TAB"}
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

# Drop every entry of the link list whose destination equals $1. An in place
# filter over module globals rather than a value returning function, because a
# command substitution would run it in a subshell and throw the result away.
cfg__drop_dest() {
	local dest="$1" i=0 n=0
	while [ "$i" -lt "$CFG__LN" ]; do
		if [ "${CFG__LDEST[i]}" != "$dest" ]; then
			CFG__LSRC[n]=${CFG__LSRC[i]}
			CFG__LDEST[n]=${CFG__LDEST[i]}
			n=$((n + 1))
		fi
		i=$((i + 1))
	done
	CFG__LN=$n
}

# Inherited [defaults] links first, then the target's own. A target link with
# the same destination replaces the inherited one (that is the point of
# inheriting), and "!dest" drops whatever is currently in the list.
# Sources are containment checked here; their existence is a plan time concern.
cfg_target_links() {
	local t="$1" spec src dest srcabs tsource all rc=0 i=0 si=-1
	cfg__sec_index "target:$t" && si=$CFG__SI
	cfg__inherited "$si" source "$t" || :
	tsource="$CFG__VAL"
	all=$(
		cfg_get_all defaults link
		cfg_get_all "target:$t" link
	)
	CFG__LN=0
	while IFS= read -r spec; do
		[ -n "$spec" ] || continue
		cfg__split_link "$spec"
		case "$CFG__SPEC" in
		link) ;;
		remove)
			cfg__drop_dest "$CFG__DEST"
			continue
			;;
		*)
			rc=1
			continue
			;;
		esac
		src="$CFG__SRC" dest="$CFG__DEST"
		# Validation has already reported all of this; re-checking is what
		# keeps invariant I4 true even if a caller skipped cfg_validate.
		if [ "$CFG__KIND" != ok ] || gr_has_dotdot "$src"; then
			rc=1
			continue
		fi
		srcabs=$(cfg__link_source_abs "$tsource" "$src")
		if ! gr_is_inside "$srcabs" "$CFG_CTX_ROOT"; then
			rc=1
			continue
		fi
		cfg__drop_dest "$dest"
		CFG__LSRC[CFG__LN]=$srcabs
		CFG__LDEST[CFG__LN]=$dest
		CFG__LN=$((CFG__LN + 1))
	done <<<"$all"
	while [ "$i" -lt "$CFG__LN" ]; do
		printf '%s\t%s\n' "${CFG__LSRC[i]}" "${CFG__LDEST[i]}"
		i=$((i + 1))
	done
	return "$rc"
}
