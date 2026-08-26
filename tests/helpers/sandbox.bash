# shellcheck shell=bash
#
# sandbox.bash - cage the test suite.
#
# graft scans directories and creates symlinks. A test suite for it that leaks
# into the developer's real $HOME is not a flaky test, it is data loss. Every
# test therefore runs with HOME and every XDG dir redirected into a temporary
# directory, and gr_sandbox refuses to continue if that redirection failed.

gr_sandbox() {
	GRAFT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	export GRAFT_ROOT
	GRAFT="$GRAFT_ROOT/bin/graft"
	export GRAFT

	SANDBOX="$(mktemp -d "${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}/graft.XXXXXX")"
	export SANDBOX

	export HOME="$SANDBOX/home"
	export XDG_CACHE_HOME="$HOME/.cache"
	export XDG_STATE_HOME="$HOME/.local/state"
	export XDG_CONFIG_HOME="$HOME/.config"
	mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_CONFIG_HOME"

	# The guard. If HOME is not inside the temp dir, something above went wrong
	# and the next line of any test could touch the real machine.
	case "$HOME" in
	"$SANDBOX"/*) ;;
	*)
		printf 'sandbox: HOME=%s escaped SANDBOX=%s - refusing to run\n' \
			"$HOME" "$SANDBOX" >&2
		exit 99
		;;
	esac

	# Keep git deterministic and away from the developer's identity and hooks.
	export GIT_CONFIG_NOSYSTEM=1
	export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
	git config --global user.email graft@example.invalid
	git config --global user.name "graft tests"
	git config --global init.defaultBranch main
	git config --global commit.gpgsign false
	git config --global core.hooksPath /dev/null

	export TZ=UTC LC_ALL=C NO_COLOR=1
	export GRAFT_NO_COLOR=1
	unset CI GRAFT_ASSUME_YES

	cd "$SANDBOX" || exit 99
}

gr_sandbox_teardown() {
	case "${SANDBOX:-}" in
	"${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-/tmp}}"/graft.*)
		chmod -R u+rwX "$SANDBOX" 2>/dev/null || true
		rm -rf -- "$SANDBOX"
		;;
	esac
}

# mkrepo <dir> [origin-url] - a real git repo with one commit.
mkrepo() {
	local dir="$1" origin="${2:-}"
	mkdir -p "$dir"
	git -C "$dir" init -q
	printf 'placeholder\n' >"$dir/README.md"
	git -C "$dir" add -A
	git -C "$dir" commit -qm "init"
	[ -n "$origin" ] && git -C "$dir" remote add origin "$origin"
	return 0
}

# mkctx <dir> - a context repo holding shared agent context.
mkctx() {
	local dir="$1"
	mkdir -p "$dir/projects/demo/github"
	printf '# demo instructions\n' >"$dir/projects/demo/github/copilot-instructions.md"
	git -C "$dir" init -q 2>/dev/null || true
	return 0
}

# writeconf <ctx-dir> ; body on stdin
writeconf() { cat >"$1/graft.conf"; }

# --- assertions --------------------------------------------------------------
#
# $status and $output are set by bats' `run`; shellcheck cannot see that.
# shellcheck disable=SC2154

assert_status() {
	if [ "$status" -ne "$1" ]; then
		printf 'expected exit %s, got %s\noutput:\n%s\n' "$1" "$status" "$output" >&2
		return 1
	fi
}

assert_output_contains() {
	case "$output" in
	*"$1"*) ;;
	*)
		printf 'expected output to contain: %s\ngot:\n%s\n' "$1" "$output" >&2
		return 1
		;;
	esac
}

assert_output_lacks() {
	case "$output" in
	*"$1"*)
		printf 'expected output NOT to contain: %s\ngot:\n%s\n' "$1" "$output" >&2
		return 1
		;;
	esac
}

assert_symlink_to() {
	local link="$1" want="$2" got
	if [ ! -L "$link" ]; then
		printf '%s is not a symlink\n' "$link" >&2
		return 1
	fi
	got="$(cd "$(dirname "$link")" && readlink "$(basename "$link")")"
	case "$got" in
	/*) ;;
	*) got="$(cd "$(dirname "$link")" && cd "$(dirname "$got")" && pwd)/$(basename "$got")" ;;
	esac
	if [ "$got" != "$want" ]; then
		printf 'symlink %s -> %s, expected -> %s\n' "$link" "$got" "$want" >&2
		return 1
	fi
}

assert_not_exists() {
	if [ -e "$1" ] || [ -L "$1" ]; then
		printf '%s exists but should not\n' "$1" >&2
		return 1
	fi
}

assert_real_dir() {
	if [ -L "$1" ] || [ ! -d "$1" ]; then
		printf '%s is not a real directory\n' "$1" >&2
		return 1
	fi
}
