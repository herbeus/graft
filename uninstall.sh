#!/usr/bin/env bash
#
# uninstall.sh - undo install.sh.
#
# It removes exactly two things:
#   1. the <prefix>/graft symlink, and only if it is a symlink into a graft
#      checkout - never a real file, never a directory;
#   2. the marked "# >>> graft >>>" block from every shell rc file we know how
#      to write, leaving the rest of the file byte-for-byte alone.
#
# It does NOT touch the links graft itself created in your project checkouts,
# and it does not delete your state. Run `graft unlink` first if you want that.
#
# Must stay bash 3.2 compatible.
set -eu

VERSION=0.1.0
BLOCK_BEGIN='# >>> graft >>>'
BLOCK_END='# <<< graft <<<'

PREFIX=''
DRY_RUN=0
QUIET=0

# --- output ------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$(printf '\033[0m')
	C_DIM=$(printf '\033[2m')
	C_RED=$(printf '\033[31m')
	C_GREEN=$(printf '\033[32m')
	C_YELLOW=$(printf '\033[33m')
	C_BOLD=$(printf '\033[1m')
else
	C_RESET='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BOLD=''
fi

say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*"; }
ok() { [ "$QUIET" = 1 ] || printf '  %s-%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { [ "$QUIET" = 1 ] || printf '  %s-%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
	printf '%suninstall.sh: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2
	exit 1
}

usage() {
	cat <<'EOF'
uninstall.sh - remove the graft symlink and the PATH block install.sh wrote

USAGE
  ./uninstall.sh [OPTIONS]

OPTIONS
      --prefix DIR    look for the symlink in DIR (default: $GRAFT_PREFIX,
                      else $XDG_BIN_HOME, else ~/.local/bin)
  -n, --dry-run       show what would happen, change nothing
  -q, --quiet         only print warnings and errors
  -h, --help          this text

WHAT IS NOT REMOVED
  * the symlinks graft created in your project checkouts - run `graft unlink`
    before uninstalling if you want those gone
  * your state and cache directories (their paths are printed at the end)
  * this checkout itself
EOF
}

# --- argument parsing --------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
	--prefix)
		[ $# -ge 2 ] || die "--prefix needs a directory"
		PREFIX="$2"
		shift 2
		;;
	--prefix=*)
		PREFIX="${1#--prefix=}"
		shift
		;;
	-n | --dry-run)
		DRY_RUN=1
		shift
		;;
	-q | --quiet)
		QUIET=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	-V | --version)
		printf 'graft uninstall.sh %s\n' "$VERSION"
		exit 0
		;;
	--)
		shift
		break
		;;
	-*) die "unknown option: $1 (try --help)" ;;
	*) die "unexpected argument: $1 (try --help)" ;;
	esac
done

if [ -z "$PREFIX" ]; then
	PREFIX="${GRAFT_PREFIX:-${XDG_BIN_HOME:-$HOME/.local/bin}}"
fi
# A literal tilde in a quoted string never expands, so do it by hand. The
# pattern is built from a variable to keep shellcheck from warning about the
# very thing this code exists to handle.
tilde='~'
case "$PREFIX" in
"$tilde") PREFIX="$HOME" ;;
"$tilde"/*) PREFIX="$HOME/${PREFIX#*/}" ;;
esac
PREFIX="${PREFIX%/}"
[ -n "$PREFIX" ] || die "empty prefix"
DST="$PREFIX/graft"

say "${C_BOLD}graft${C_RESET} - uninstalling"

# --- the symlink -------------------------------------------------------------

# -L is asked before -e: a symlink into a checkout that has since been deleted
# is dangling, which makes -e false while it very much still needs removing.
if [ -L "$DST" ]; then
	target=$(readlink "$DST")
	case "$target" in
	*/bin/graft | bin/graft)
		if [ "$DRY_RUN" = 1 ]; then
			info "would remove $DST -> $target"
		else
			# The only removal this script performs, and only on a symlink.
			# No -r, no -f, no trailing slash. See docs/pitfalls.md P5.
			rm -- "$DST"
			ok "removed $DST"
		fi
		;;
	*)
		warn "$DST is a symlink to $target, which is not a graft checkout - left alone"
		;;
	esac
elif [ -e "$DST" ]; then
	warn "$DST exists but is not a symlink - left alone (uninstall.sh never deletes real files)"
else
	info "$DST (not installed)"
fi

# --- the PATH block ----------------------------------------------------------

# strip_block <file> -> 0 if a block was found (and removed), 1 if not
strip_block() {
	local file="$1" tmp
	[ -f "$file" ] || return 1
	grep -qxF "$BLOCK_BEGIN" -- "$file" 2>/dev/null || return 1
	if [ "$DRY_RUN" = 1 ]; then
		return 0
	fi
	tmp="$file.graft-tmp.$$"
	# Drop the marked block, and one blank line directly above it if we put it
	# there, so repeated install/uninstall cycles do not grow the file.
	awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
		$0 == b { if (blank) blank = 0; skip = 1; next }
		skip == 1 { if ($0 == e) skip = 0; next }
		blank == 1 { print ""; blank = 0 }
		$0 == "" { blank = 1; next }
		{ print }
		END { if (blank) print "" }
	' "$file" >"$tmp"
	mv -f -- "$tmp" "$file"
	return 0
}

# Every file install.sh could have written to, regardless of which shell was
# current back then - a person who switched from bash to fish in between should
# still end up with a clean machine.
found_block=0
for rc in \
	"$HOME/.bashrc" \
	"$HOME/.bash_profile" \
	"$HOME/.profile" \
	"${ZDOTDIR:-$HOME}/.zshrc" \
	"${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish"; do
	if strip_block "$rc"; then
		found_block=1
		if [ "$DRY_RUN" = 1 ]; then
			info "would remove the graft block from $rc"
		else
			ok "removed the graft block from $rc"
		fi
	fi
done
[ "$found_block" = 1 ] || info "no PATH block to remove"

# --- what stays --------------------------------------------------------------

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/graft"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/graft"

say ""
if [ "$DRY_RUN" = 1 ]; then
	say "Dry run - nothing was changed."
else
	say "Done."
fi
say ""
say "Left in place on purpose:"
if [ -d "$state_dir" ]; then
	say "  $state_dir  (which links graft made, and where your backups went)"
	say "     -> run 'graft unlink' from your context repo before deleting it"
else
	info "no state directory"
fi
if [ -d "$cache_dir" ]; then
	say "  $cache_dir  (discovery cache, safe to delete any time)"
fi
