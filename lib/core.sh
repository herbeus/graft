# shellcheck shell=bash
#
# core.sh - output, errors, path arithmetic and guards.
#
# Depends on nothing. Everything else depends on this.
# Must stay bash 3.2 compatible: no associative arrays, no mapfile, no ${x^^}.

# --- exit codes (public API, see docs/SPEC.md section 5.2) -------------------
GRAFT_EX_OK=0
GRAFT_EX_DRIFT=1
GRAFT_EX_USAGE=2
GRAFT_EX_UNCONFIRMED=3
GRAFT_EX_ENV=4

# --- runtime flags, set by bin/graft ----------------------------------------
GRAFT_QUIET=0
GRAFT_JSON=0
GRAFT_NO_INPUT=0
GRAFT_ASSUME_YES=0
GRAFT_DRY_RUN=0

# --- presentation ------------------------------------------------------------

# Defined up front, not in gr_init_style. Argument parsing runs before styling
# is decided, and it has to be able to report a bad option - under `set -u` an
# unset colour variable turns "unknown option" into an unbound-variable crash
# with the wrong exit code.
C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BOLD=''
G_OK='ok' G_ADD='+' G_FIX='~' G_BAD='!' G_SKIP='-'

# Colour is opt-out in three independent ways, because each is a real situation:
# a pipe, a user preference, and a terminal that lies about its capabilities.
gr_init_style() {
	C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BOLD=''
	if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${GRAFT_NO_COLOR:-0}" = 0 ]; then
		C_RESET=$(printf '\033[0m') C_DIM=$(printf '\033[2m')
		C_RED=$(printf '\033[31m') C_GREEN=$(printf '\033[32m')
		C_YELLOW=$(printf '\033[33m') C_BOLD=$(printf '\033[1m')
	fi
	# Glyphs degrade rather than turning into mojibake on a POSIX locale.
	case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
	*[Uu][Tt][Ff]*) G_OK='✓' G_ADD='+' G_FIX='~' G_BAD='!' G_SKIP='-' ;;
	*) G_OK='ok' G_ADD='+' G_FIX='~' G_BAD='!' G_SKIP='-' ;;
	esac
}

# Any string that came from a config file or a filesystem path is printed
# through this. A path is allowed to contain terminal escape sequences; a tool
# that echoes them back lets a repo you cloned repaint your terminal.
#
# A tab is not dropped but shown as \t, for two reasons. It is legal in a path
# and in a config value, so silently deleting it would misreport what is
# actually on disk. And several of graft's own records are tab-separated, so a
# tab that survives this function tears the record it is embedded in - a config
# value containing one used to split its own error message across two lines and
# strand the hint after it.
gr_clean() {
	local s
	s=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177')
	printf '%s' "${s//$'\t'/\\t}"
}

gr_say() { [ "$GRAFT_QUIET" = 1 ] || printf '%s\n' "$*"; }
gr_bold() { [ "$GRAFT_QUIET" = 1 ] || printf '%s%s%s\n' "$C_BOLD" "$*" "$C_RESET"; }
gr_dim() { [ "$GRAFT_QUIET" = 1 ] || printf '%s%s%s\n' "$C_DIM" "$*" "$C_RESET"; }
gr_ok() { [ "$GRAFT_QUIET" = 1 ] || printf '  %s%s%s %s\n' "$C_GREEN" "$G_OK" "$C_RESET" "$*"; }
gr_add() { [ "$GRAFT_QUIET" = 1 ] || printf '  %s%s%s %s\n' "$C_GREEN" "$G_ADD" "$C_RESET" "$*"; }
gr_fix() { [ "$GRAFT_QUIET" = 1 ] || printf '  %s%s%s %s\n' "$C_YELLOW" "$G_FIX" "$C_RESET" "$*"; }
gr_skip() { [ "$GRAFT_QUIET" = 1 ] || printf '  %s%s %s%s\n' "$C_DIM" "$G_SKIP" "$*" "$C_RESET"; }
gr_warn() { printf '  %s%s%s %s\n' "$C_YELLOW" "$G_BAD" "$C_RESET" "$*" >&2; }
gr_err() { printf '%sgraft: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }

# die <exit-code> <message...>
gr_die() {
	local code="$1"
	shift
	gr_err "$*"
	exit "$code"
}

# Hint lines are how the user gets from an error to a working command. Every
# failure path that a user can act on must emit one.
gr_hint() { printf '%s      %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }

# --- prompting ---------------------------------------------------------------

# Is there a human at a terminal we can talk to?
#
# Deliberately NOT `[ -t 0 ]`. Half of this program's work happens inside
# `while read ... done <<EOF` loops, and in there stdin is the here-document,
# so a prompt would read the loop's own data and `-t 0` would say "not a
# terminal" even with a user sitting right there. /dev/tty is the controlling
# terminal regardless of what stdin currently points at, and it is absent
# exactly where it should be: cron, CI, a pipeline.
gr_tty() { [ -r /dev/tty ] && [ -w /dev/tty ]; }

# gr_confirm <question> -> 0 = yes
# Non-interactive is never a silent yes: callers decide whether that means
# "skip" or "exit 3", but it never means "go ahead".
gr_confirm() {
	local q="$1" ans
	[ "$GRAFT_ASSUME_YES" = 1 ] && return 0
	[ "$GRAFT_NO_INPUT" = 1 ] && return 1
	gr_tty || return 1
	printf '%s [y/N] ' "$q" >/dev/tty
	IFS= read -r ans </dev/tty || return 1
	case "$ans" in [yYjJ] | [yY]es | [jJ]a) return 0 ;; *) return 1 ;; esac
}

# --- path arithmetic ---------------------------------------------------------
#
# We do not use realpath(1) or readlink -f: neither is portable to macOS's base
# system, and this tool must run on a stock machine.

# Lexical normalisation. No filesystem access, so it also works on paths that do
# not exist yet - which is exactly the case when validating a config.
gr_normpath() {
	local p="$1" out='' seg abs=0
	case "$p" in /*) abs=1 ;; esac
	local IFS='/'
	set -f
	# shellcheck disable=SC2086 # deliberate word splitting on IFS=/
	set -- $p
	set +f
	for seg in "$@"; do
		case "$seg" in
		'' | '.') ;;
		'..') out="${out%/*}" ;;
		*) out="$out/$seg" ;;
		esac
	done
	if [ "$abs" = 1 ]; then
		printf '%s\n' "${out:-/}"
	else
		printf '%s\n' "${out#/}"
	fi
}

# Absolute + lexically normalised. Does not follow symlinks and does not require
# the path to exist.
gr_abspath() {
	local p="$1"
	# A leading tilde is expanded here on purpose: config files are read as
	# data, so the shell never gets a chance to do it for us.
	# shellcheck disable=SC2088 # the tilde in these patterns is meant literally
	case "$p" in
	/*) ;;
	'~') p="$HOME" ;;
	'~/'*) p="$HOME/${p#'~/'}" ;;
	*) p="$PWD/$p" ;;
	esac
	gr_normpath "$p"
}

# Fully resolved physical path: follows every symlink in the chain.
# Fails (returns 1) if the path does not exist.
gr_realpath() {
	local p n=0 link dir base
	p=$(gr_abspath "$1")
	while [ "$n" -lt 40 ]; do
		[ -L "$p" ] || break
		link=$(readlink -- "$p") || return 1
		case "$link" in
		/*) p="$link" ;;
		*) p="$(dirname -- "$p")/$link" ;;
		esac
		p=$(gr_normpath "$p")
		n=$((n + 1))
	done
	[ "$n" -lt 40 ] || return 1
	if [ -d "$p" ]; then
		(cd -P -- "$p" 2>/dev/null && pwd -P)
		return
	fi
	[ -e "$p" ] || return 1
	dir=$(dirname -- "$p")
	base=$(basename -- "$p")
	dir=$(cd -P -- "$dir" 2>/dev/null && pwd -P) || return 1
	printf '%s/%s\n' "${dir%/}" "$base"
}

# Where a symlink points, as an absolute lexical path. Works on dangling links -
# that is the whole point, because a dangling link into our own context repo is
# repairable and one pointing elsewhere is not ours to touch.
gr_link_target() {
	local p="$1" t
	[ -L "$p" ] || return 1
	t=$(readlink -- "$p") || return 1
	case "$t" in
	/*) gr_normpath "$t" ;;
	*) gr_normpath "$(dirname -- "$p")/$t" ;;
	esac
}

# gr_is_inside <child> <parent> -> 0 if child is parent or lies under it.
# Both arguments must already be absolute and normalised. The trailing slash on
# the comparison is what stops /home/user-evil from counting as inside /home/user.
gr_is_inside() {
	local child="$1" parent="${2%/}"
	[ "$child" = "$parent" ] && return 0
	case "$child" in "$parent"/*) return 0 ;; esac
	return 1
}

# gr_has_dotdot <path> -> 0 if any segment is ".."
gr_has_dotdot() {
	case "/$1/" in */../*) return 0 ;; esac
	return 1
}

# --- tsv encoding ------------------------------------------------------------
# A half-written TSV line loses one record. A half-written JSON document is
# unreadable. That is the whole reason the state files are TSV.

gr_tsv_escape() {
	if [ -z "$1" ]; then printf -- '-'; else
		printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/	/\\t/g'
	fi
}

gr_tsv_unescape() {
	case "$1" in -) printf '' ;; *) printf '%s' "$1" | sed -e 's/\\t/	/g' -e 's/\\\\/\\/g' ;; esac
}

gr_json_escape() {
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g' | tr -d '\000-\037'
}

# --- atomic file writes ------------------------------------------------------

# gr_atomic_write <dest> ; content on stdin
# Temp file lives in the destination directory so that mv is a rename, not a
# copy across filesystems - a rename cannot leave a truncated file behind.
gr_atomic_write() {
	local dest="$1" dir tmp
	dir=$(dirname -- "$dest")
	mkdir -p -- "$dir" || return 1
	tmp="$dir/.graft.tmp.$$"
	cat >"$tmp" || {
		rm -f -- "$tmp"
		return 1
	}
	mv -f -- "$tmp" "$dest"
}

# --- misc --------------------------------------------------------------------

gr_have() { command -v "$1" >/dev/null 2>&1; }

# "1 targets" reads like a bug report about the tool that printed it.
gr_plural() {
	if [ "$1" = 1 ]; then printf '%s %s' "$1" "$2"; else printf '%s %s' "$1" "$3"; fi
}

# Stable short id for a config path, so two context repos on one machine never
# share cache or state. cksum is in POSIX; sha256sum is not on macOS.
gr_config_id() {
	printf '%s' "$1" | cksum | tr -d ' \t' | cut -c1-12
}

gr_xdg_cache() { printf '%s/graft\n' "${XDG_CACHE_HOME:-$HOME/.cache}"; }
gr_xdg_state() { printf '%s/graft\n' "${XDG_STATE_HOME:-$HOME/.local/state}"; }

gr_utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
