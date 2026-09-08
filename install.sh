#!/usr/bin/env bash
#
# install.sh - put `graft` on your PATH.
#
# It creates ONE symlink:
#
#     <prefix>/graft  ->  <this repo>/bin/graft
#
# A symlink, not a copy, so that `git pull` in this checkout updates the CLI
# you are running. Nothing is compiled, nothing is downloaded, and `sudo` is
# never used or asked for: the default prefix is inside your home directory.
#
# Usage:
#   ./install.sh [--prefix DIR] [--modify-path] [--force] [--dry-run] [-q] [-h]
#
# Prefix resolution (first one wins):
#   --prefix DIR, $GRAFT_PREFIX, $XDG_BIN_HOME, $HOME/.local/bin
#
# Must stay bash 3.2 compatible - macOS still ships bash 3.2 as /bin/bash.
set -eu

VERSION=0.1.0
BLOCK_BEGIN='# >>> graft >>>'
BLOCK_END='# <<< graft <<<'

PREFIX=''
MODIFY_PATH=0
FORCE=0
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
ok() { [ "$QUIET" = 1 ] || printf '  %s+%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info() { [ "$QUIET" = 1 ] || printf '  %s-%s %s\n' "$C_DIM" "$C_RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() {
	printf '%sinstall.sh: %s%s\n' "$C_RED" "$*" "$C_RESET" >&2
	exit 1
}

usage() {
	cat <<'EOF'
install.sh - link graft into a directory on your PATH

USAGE
  ./install.sh [OPTIONS]

OPTIONS
      --prefix DIR    install into DIR (default: $GRAFT_PREFIX, else
                      $XDG_BIN_HOME, else ~/.local/bin)
      --modify-path   append a marked, idempotent block to your shell rc file
                      if the prefix is not on PATH. Without this flag the exact
                      line to add is only printed, never written.
      --force         replace an existing `graft` symlink that points somewhere
                      other than this checkout
  -n, --dry-run       show what would happen, change nothing
  -q, --quiet         only print warnings and errors
  -h, --help          this text

NOTES
  * A symlink is created, not a copy: `git pull` here updates the CLI.
  * sudo is never used. If you want a system-wide install, choose a prefix you
    own, or run this script yourself as the owning user.
  * Undo everything with ./uninstall.sh
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
	--modify-path)
		MODIFY_PATH=1
		shift
		;;
	--force)
		FORCE=1
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
		printf 'graft install.sh %s\n' "$VERSION"
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

# --- locate the checkout -----------------------------------------------------

# Resolve our own directory even when install.sh itself is reached via a symlink.
self="$0"
while [ -L "$self" ]; do
	link=$(readlink "$self")
	case "$link" in
	/*) self="$link" ;;
	*) self="$(dirname "$self")/$link" ;;
	esac
done
REPO=$(cd -P -- "$(dirname -- "$self")" && pwd)
SRC="$REPO/bin/graft"

if [ ! -f "$SRC" ]; then
	die "$SRC does not exist.

install.sh must run from inside a graft checkout, next to bin/graft.
If you copied this script somewhere on its own, clone the repository instead:

    git clone https://github.com/herbeus/graft.git
    cd graft && ./install.sh"
fi
[ -x "$SRC" ] || die "$SRC is not executable. Run: chmod +x '$SRC'"

# --- prefix ------------------------------------------------------------------

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
case "$PREFIX" in
/*) ;;
*) PREFIX="$(pwd)/$PREFIX" ;;
esac
DST="$PREFIX/graft"

say "${C_BOLD}graft${C_RESET} - linking $SRC"
say "  into $PREFIX"

# --- create the symlink ------------------------------------------------------

link_needed=1
if [ -L "$DST" ]; then
	# -L before -e, always: a dangling symlink is -L true and -e false.
	current=$(readlink "$DST")
	current_abs="$current"
	case "$current_abs" in
	/*) ;;
	*) current_abs="$PREFIX/$current_abs" ;;
	esac
	if [ "$current_abs" = "$SRC" ]; then
		link_needed=0
	elif [ "$FORCE" = 1 ]; then
		warn "replacing existing symlink $DST -> $current"
	else
		die "$DST already exists and points to:

    $current

That is not this checkout. Re-run with --force to repoint it, choose another
--prefix, or remove it yourself."
	fi
elif [ -e "$DST" ]; then
	die "$DST exists and is not a symlink.

install.sh never overwrites a real file. Move it out of the way, or pick a
different --prefix."
fi

if [ "$link_needed" = 0 ]; then
	ok "$DST (already linked)"
elif [ "$DRY_RUN" = 1 ]; then
	info "would create $DST -> $SRC"
else
	mkdir -p -- "$PREFIX"
	# Create at a temporary name and mv over the destination. `ln -s` onto an
	# existing directory symlink would create the link INSIDE that directory,
	# and `ln -sfn` is not atomic. See docs/pitfalls.md P1.
	tmp="$DST.install-tmp.$$"
	ln -s -- "$SRC" "$tmp"
	mv -f -- "$tmp" "$DST"
	ok "$DST -> $SRC"
fi

# --- PATH --------------------------------------------------------------------

# True if $PREFIX is already an element of $PATH, comparing both the literal
# string and the physical path (so ~/.local/bin matching /home/x/.local/bin
# through a symlinked home still counts).
prefix_on_path() {
	local entry phys prefix_phys
	prefix_phys=$(cd -P -- "$PREFIX" 2>/dev/null && pwd) || prefix_phys="$PREFIX"
	local saved_ifs="$IFS"
	IFS=:
	for entry in $PATH; do
		[ -n "$entry" ] || continue
		entry="${entry%/}"
		if [ "$entry" = "$PREFIX" ]; then
			IFS="$saved_ifs"
			return 0
		fi
		phys=$(cd -P -- "$entry" 2>/dev/null && pwd) || continue
		if [ "$phys" = "$prefix_phys" ]; then
			IFS="$saved_ifs"
			return 0
		fi
	done
	IFS="$saved_ifs"
	return 1
}

# Quote a value for single-quoted POSIX shell (and fish) syntax.
sq() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# rc_file <shell-name> -> prints the file we would edit for that shell
rc_file() {
	case "$1" in
	fish) printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/fish/config.fish" ;;
	zsh) printf '%s\n' "${ZDOTDIR:-$HOME}/.zshrc" ;;
	bash)
		# A macOS Terminal window starts a *login* shell, which reads
		# .bash_profile and not .bashrc.
		if [ "$(uname -s 2>/dev/null || echo unknown)" = Darwin ]; then
			printf '%s\n' "$HOME/.bash_profile"
		else
			printf '%s\n' "$HOME/.bashrc"
		fi
		;;
	*) printf '%s\n' "$HOME/.profile" ;;
	esac
}

# path_line <shell-name> -> prints the line that puts $PREFIX on PATH
path_line() {
	if [ "$1" = fish ]; then
		printf 'fish_add_path %s\n' "$(sq "$PREFIX")"
	else
		# $PATH must stay unexpanded: it is the rc file's job to expand it.
		# shellcheck disable=SC2016
		printf 'export PATH=%s:"$PATH"\n' "$(sq "$PREFIX")"
	fi
}

# write_block <file> <line> - idempotent: an existing graft block is replaced,
# never appended to, so running install.sh twice leaves exactly one block.
write_block() {
	local file="$1" line="$2" dir tmp
	dir=$(dirname -- "$file")
	mkdir -p -- "$dir"
	tmp="$file.graft-tmp.$$"
	if [ -f "$file" ]; then
		# Pass 1 drops any block we wrote before; pass 2 drops trailing blank
		# lines, so install/uninstall cycles cannot slowly grow the file.
		awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
			$0 == b { skip = 1 }
			skip != 1 { print }
			$0 == e { skip = 0 }
		' "$file" | awk '
			/^[ \t]*$/ { blanks++; next }
			{ while (blanks-- > 0) print ""; blanks = 0; print }
		' >"$tmp"
	else
		: >"$tmp"
	fi
	# Exactly one blank line between the previous content and our block.
	if [ -s "$tmp" ]; then
		printf '\n' >>"$tmp"
	fi
	{
		printf '%s\n' "$BLOCK_BEGIN"
		printf '%s\n' "# Added by graft install.sh. Remove with: uninstall.sh"
		printf '%s\n' "$line"
		printf '%s\n' "$BLOCK_END"
	} >>"$tmp"
	mv -f -- "$tmp" "$file"
}

shell_name=$(basename -- "${SHELL:-sh}")
rc=$(rc_file "$shell_name")
line=$(path_line "$shell_name")

if prefix_on_path; then
	ok "$PREFIX is on your PATH"
elif [ "$MODIFY_PATH" = 1 ]; then
	if [ "$DRY_RUN" = 1 ]; then
		info "would add a marked block to $rc:"
		say "      $line"
	else
		write_block "$rc" "$line"
		ok "added a marked block to $rc"
		info "open a new shell, or run: . '$rc'"
	fi
else
	warn "$PREFIX is not on your PATH"
	say ""
	say "  Add this line to ${C_BOLD}$rc${C_RESET}:"
	say ""
	say "      $line"
	say ""
	if [ "$shell_name" = fish ]; then
		say "  (or run ${C_BOLD}$line${C_RESET} once - fish remembers it)"
		say ""
	fi
	say "  Or re-run with ${C_BOLD}--modify-path${C_RESET} and this script will do it,"
	say "  as a marked block that ./uninstall.sh removes again."
	say ""
fi

# --- next steps --------------------------------------------------------------

say ""
if [ "$DRY_RUN" = 1 ]; then
	say "Dry run - nothing was changed."
else
	say "Done. Next:"
	say "  graft --version"
	say "  cd <your-context-repo> && graft init"
fi
