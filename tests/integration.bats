#!/usr/bin/env bats
#
# integration.bats - the whole tool, driven the way a user drives it.
#
# Every other file in this suite sources lib/ and calls one function against
# stubs. That is what let four wiring bugs through a green run: bin/graft never
# initialised state, plan.sh split TSV with IFS, discover.sh never normalised
# scp-style remotes, and plan.sh threw ap_link's state away in a subshell. None
# of those are visible from inside a module.
#
# So this file has exactly one rule: it never sources anything from lib/. It
# builds a small machine on disk - project checkouts with real git remotes and a
# context repo - runs the real `$GRAFT` command against it, and looks at what is
# left on the filesystem afterwards. If two modules disagree about a contract,
# it shows up here and nowhere else.
#
# Tests that guard one of the four historical wiring bugs are named
# "regression: ...". Tests that describe behaviour the tool does not have yet
# reproduction still runs and the wanted end state stays written down.

# $status, $output and $lines are set by bats' `run`; shellcheck cannot see it.
# shellcheck disable=SC2154

# shellcheck source-path=SCRIPTDIR/..
load helpers/sandbox

setup() { gr_sandbox; }
teardown() { gr_sandbox_teardown; }

# --- building a world ---------------------------------------------------------

# world_init [ctx-dir-below-home] - physical HOME plus an empty context repo.
#
# Everything is compared against paths graft resolved, so the test side has to
# be resolved too: on a machine where $TMPDIR is itself a symlink, an unresolved
# HOME makes every path assertion in this file wrong.
world_init() {
	HOME=$(cd "$HOME" && pwd -P)
	export HOME
	export XDG_CACHE_HOME="$HOME/.cache"
	export XDG_STATE_HOME="$HOME/.local/state"
	export XDG_CONFIG_HOME="$HOME/.config"
	export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
	CTX="$HOME/${1:-ctx}"
	mkdir -p "$CTX"
	git -C "$CTX" init -q
}

# ctx_file <relative-path> [content] - one file in the context repo.
ctx_file() {
	mkdir -p "$(dirname -- "$CTX/$1")"
	printf '%s\n' "${2:-shared context}" >"$CTX/$1"
}

# world_basic - two checkouts found by their remote, one context repo.
#
# backend is cloned over https, frontend over scp-style ssh, and both are
# located by the same shape of origin: glob. That combination is the historical
# bug 3, so it is the default world rather than a special case.
world_basic() {
	world_init
	BACKEND="$HOME/work/backend"
	FRONTEND="$HOME/src/nest/frontend"
	mkrepo "$BACKEND" "https://git.example.com/acme/backend.git"
	mkrepo "$FRONTEND" "git@git.example.com:acme/frontend.git"
	ctx_file projects/backend/github/copilot-instructions.md '# backend'
	ctx_file projects/frontend/github/copilot-instructions.md '# frontend'
	ctx_file projects/frontend/claude/CLAUDE.md '# claude'
	ctx_file projects/frontend/cursor/00-project.mdc '# rules'
	ctx_file projects/frontend/AGENTS.md '# agents'
	writeconf "$CTX" <<-'CONF'
		[defaults]
		source_root = projects
		search_root = ~
		search_depth = 5
		link = github -> .github

		[target "backend"]
		description = the backend service
		find = origin:*/acme/backend

		[target "frontend"]
		description = the frontend app
		find = origin:*/acme/frontend
		link = claude -> .claude
		link = AGENTS.md -> AGENTS.md
		link = cursor -> .cursor/rules
	CONF
	cd "$CTX" || return 1
}

# --- looking at the result ----------------------------------------------------

# snapshot <checkout> - everything about a checkout graft is allowed to change:
# names, types, symlink targets, file contents, and the exclude file that lives
# inside .git. Two snapshots compare byte for byte or the run was not reversible.
snapshot() {
	local root="$1" p
	(
		cd "$root" || exit 1
		find . -path ./.git -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
			if [ -L "$p" ]; then
				printf 'L %s -> %s\n' "$p" "$(readlink -- "$p")"
			elif [ -d "$p" ]; then
				printf 'D %s\n' "$p"
			else
				printf 'F %s %s\n' "$p" "$(cksum <"$p")"
			fi
		done
	)
	if [ -f "$root/.git/info/exclude" ]; then
		printf 'X %s\n' "$(cksum <"$root/.git/info/exclude")"
	else
		printf 'X -\n'
	fi
}

# short <absolute-path> - how graft prints a path below $HOME (SPEC section 7).
# shellcheck disable=SC2088 # the tilde is display text, not a path to expand
short() { printf '~/%s' "${1#"$HOME"/}"; }

# exclude_block <checkout> - the lines of our delimited block, markers included.
exclude_block() {
	local f="$1/.git/info/exclude"
	[ -f "$f" ] || return 0
	sed -n '/^# graft: managed links (do not edit)$/,/^# graft: end$/p' "$f"
}

# count_lines <text> <basic-regex>
count_lines() {
	printf '%s\n' "$1" | grep -c "$2" || true
}

# count_backups <dest> - how many backups sit next to a destination.
count_backups() {
	local n=0 p
	for p in "$1".graft-backup*; do
		if [ -e "$p" ] || [ -L "$p" ]; then n=$((n + 1)); fi
	done
	printf '%s\n' "$n"
}

state_path() { find "$XDG_STATE_HOME/graft" -name links.tsv 2>/dev/null | head -1; }

# state_count - how many link records survived the process that wrote them.
state_count() {
	local f
	f=$(state_path)
	if [ -z "$f" ]; then
		printf '0\n'
		return 0
	fi
	grep -v '^#' "$f" | grep -c . || true
}

# --- JSON ---------------------------------------------------------------------

JSON_TOOL=''

json_tool() {
	if [ -z "$JSON_TOOL" ]; then
		if command -v jq >/dev/null 2>&1; then
			JSON_TOOL=jq
		elif command -v python3 >/dev/null 2>&1; then
			JSON_TOOL=python3
		else
			JSON_TOOL=none
		fi
	fi
	printf '%s' "$JSON_TOOL"
}

json_parses() {
	case "$(json_tool)" in
	jq) printf '%s\n' "$1" | jq -e . >/dev/null 2>&1 ;;
	python3) printf '%s\n' "$1" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1 ;;
	*) return 1 ;;
	esac
}

# json_field <line> <key> - value of one top-level key.
json_field() {
	case "$(json_tool)" in
	jq) printf '%s\n' "$1" | jq -r --arg k "$2" '.[$k] // empty' ;;
	python3) printf '%s\n' "$1" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))' "$2" ;;
	*) return 1 ;;
	esac
}

# assert_json_lines <text> - JSON Lines, SPEC section 7: one object per line and
# nothing else. A human sentence in this stream breaks every consumer of it.
assert_json_lines() {
	local line n=0
	if [ "$(json_tool)" = none ]; then
		skip "no jq and no python3 available to validate JSON"
	fi
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		n=$((n + 1))
		if ! json_parses "$line"; then
			printf 'line %s is not valid JSON: %s\nfull output:\n%s\n' "$n" "$line" "$1" >&2
			return 1
		fi
	done <<EOF
$1
EOF
	if [ "$n" = 0 ]; then
		printf 'expected JSON output, got nothing\n' >&2
		return 1
	fi
}

# =============================================================================
# the round trip
# =============================================================================

@test "round trip: check, dry-run, link, link again, status, unlink leave the checkout as it was" {
	world_basic
	# A real, untracked .github the user cares about: the round trip has to give
	# it back, not just remove our symlink.
	mkdir -p "$FRONTEND/.github"
	printf 'PRECIOUS\n' >"$FRONTEND/.github/keep.md"

	local before after before_git after_git
	before=$(snapshot "$FRONTEND")
	before_git=$(git -C "$FRONTEND" status --porcelain)

	run "$GRAFT" check
	assert_status 0
	assert_output_contains "in order"

	run "$GRAFT" link --dry-run
	assert_status 0
	assert_output_contains "$(short "$FRONTEND/.github")"

	run "$GRAFT" link --yes
	assert_status 0
	assert_symlink_to "$FRONTEND/.github" "$CTX/projects/frontend/github"
	assert_symlink_to "$BACKEND/.github" "$CTX/projects/backend/github"
	[ "$(cat "$FRONTEND/.github/copilot-instructions.md")" = "# frontend" ]

	run "$GRAFT" link
	assert_status 0

	run "$GRAFT" status
	assert_status 0

	run "$GRAFT" unlink
	assert_status 0

	# Byte for byte what we started with (invariant I8).
	assert_real_dir "$FRONTEND/.github"
	[ "$(cat "$FRONTEND/.github/keep.md")" = PRECIOUS ]
	[ "$(count_backups "$FRONTEND/.github")" = 0 ]
	[ "$(exclude_block "$FRONTEND")" = "" ]
	after=$(snapshot "$FRONTEND")
	after_git=$(git -C "$FRONTEND" status --porcelain)
	[ "$after" = "$before" ]
	[ "$after_git" = "$before_git" ]
}

@test "link --dry-run writes nothing to disk" {
	world_basic
	local before_fe before_be before_ctx

	before_fe=$(snapshot "$FRONTEND")
	before_be=$(snapshot "$BACKEND")
	before_ctx=$(snapshot "$CTX")

	run "$GRAFT" link --dry-run
	assert_status 0
	assert_output_contains "nothing will be changed"

	[ "$(snapshot "$FRONTEND")" = "$before_fe" ]
	[ "$(snapshot "$BACKEND")" = "$before_be" ]
	[ "$(snapshot "$CTX")" = "$before_ctx" ]
	# I6: a plan is not a side effect. No state file either.
	[ "$(state_count)" = 0 ]
}

@test "link is idempotent: one line, no second backup, no second exclude entry" {
	world_basic
	mkdir -p "$FRONTEND/.github"
	printf 'PRECIOUS\n' >"$FRONTEND/.github/keep.md"

	run "$GRAFT" link --yes
	assert_status 0
	[ "$(count_backups "$FRONTEND/.github")" = 1 ]
	local records
	records=$(state_count)

	run "$GRAFT" link
	assert_status 0
	# SPEC section 7: the idempotent run prints exactly one line.
	[ "${#lines[@]}" = 1 ]

	run "$GRAFT" link
	assert_status 0
	[ "${#lines[@]}" = 1 ]

	# I7: no second backup, no duplicated file line, no extra record.
	[ "$(count_backups "$FRONTEND/.github")" = 1 ]
	[ "$(count_lines "$(exclude_block "$FRONTEND")" '^\.github$')" = 1 ]
	[ "$(count_lines "$(exclude_block "$FRONTEND")" '^# graft: managed')" = 1 ]
	[ "$(state_count)" = "$records" ]
}

# =============================================================================
# the four wiring bugs
# =============================================================================

@test "regression: an scp-style ssh remote matches the same origin: pattern as an https remote" {
	world_init
	local repo="$HOME/work/api"
	mkrepo "$repo" "git@git.example.com:acme/api.git"
	ctx_file projects/api/github/copilot-instructions.md '# api'
	writeconf "$CTX" <<-'CONF'
		[defaults]
		source_root = projects
		search_root = ~
		link = github -> .github

		[target "api"]
		find = origin:*/acme/api
	CONF
	cd "$CTX" || return 1

	# scp-style shorthand puts a colon where every other form has a slash, so
	# without normalisation the glob */acme/api never matches this checkout.
	run "$GRAFT" link --yes
	assert_status 0
	assert_symlink_to "$repo/.github" "$CTX/projects/api/github"

	run "$GRAFT" unlink
	assert_status 0

	# The very same pattern, the very same checkout, cloned over https instead.
	git -C "$repo" remote set-url origin https://git.example.com/acme/api.git
	run "$GRAFT" link --yes
	assert_status 0
	assert_symlink_to "$repo/.github" "$CTX/projects/api/github"

	# And a bare ssh:// URL with a port, where the colon is not a path separator.
	run "$GRAFT" unlink
	assert_status 0
	git -C "$repo" remote set-url origin ssh://git@git.example.com:22/acme/api.git
	run "$GRAFT" link --yes
	assert_status 0
	assert_symlink_to "$repo/.github" "$CTX/projects/api/github"
}

@test "regression: state survives the process, one record per link created" {
	world_basic

	run "$GRAFT" link --yes
	assert_status 0

	# Five links: .github twice, .claude, AGENTS.md, .cursor/rules. A state
	# write that happened in a subshell leaves this file empty, and nothing
	# notices until the first unlink.
	[ "$(state_count)" = 5 ]

	local f
	f=$(state_path)
	[ -n "$f" ]
	grep -q "$FRONTEND/.claude" "$f"
	grep -q "$BACKEND/.github" "$f"

	# The proof that the records are usable in a *later* process.
	run "$GRAFT" unlink
	assert_status 0
	assert_output_contains "5 links removed"
	assert_not_exists "$FRONTEND/.claude"
	[ "$(state_count)" = 0 ]
}

@test "regression: a target without a checkout renders its own name and no empty path" {
	world_init
	mkrepo "$HOME/work/api" "https://git.example.com/acme/api.git"
	ctx_file projects/api/github/copilot-instructions.md '# api'
	ctx_file projects/ghost/github/copilot-instructions.md '# ghost'
	writeconf "$CTX" <<-'CONF'
		[defaults]
		source_root = projects
		search_root = ~
		link = github -> .github

		[target "api"]
		find = origin:*/acme/api

		[target "ghost"]
		find = origin:*/nowhere/ghost
	CONF
	cd "$CTX" || return 1

	# A record with empty fields is where "IFS=<tab>; set -- $rec" collapses the
	# empty columns and shifts every later field one to the left. The target
	# name then lands in the wrong column and the line reads as a path.
	run "$GRAFT" status
	assert_status 1
	assert_output_contains "ghost: no checkout found"
	assert_output_lacks "  ()"

	run "$GRAFT" status --json
	assert_status 1
	assert_json_lines "$output"

	local line
	line=$(printf '%s\n' "$output" | grep '"target":"ghost"')
	[ -n "$line" ]
	[ "$(json_field "$line" action)" = no-checkout ]
	[ "$(json_field "$line" dest)" = "" ]
	[ "$(json_field "$line" checkout)" = "" ]
	# The found target keeps its own fields in the meantime.
	line=$(printf '%s\n' "$output" | grep '"target":"api"')
	[ "$(json_field "$line" dest)" = "$HOME/work/api/.github" ]
	[ "$(json_field "$line" action)" = absent ]
}

# =============================================================================
# linking
# =============================================================================

@test "link: several links for one target land side by side" {
	world_basic

	run "$GRAFT" link --yes frontend
	assert_status 0
	assert_symlink_to "$FRONTEND/.github" "$CTX/projects/frontend/github"
	assert_symlink_to "$FRONTEND/.claude" "$CTX/projects/frontend/claude"
	assert_symlink_to "$FRONTEND/AGENTS.md" "$CTX/projects/frontend/AGENTS.md"
	[ "$(cat "$FRONTEND/AGENTS.md")" = "# agents" ]

	# One block, one entry each, and the backend was not touched by name.
	local block
	block=$(exclude_block "$FRONTEND")
	[ "$(count_lines "$block" '^# graft: managed')" = 1 ]
	[ "$(count_lines "$block" '^\.github$')" = 1 ]
	[ "$(count_lines "$block" '^\.claude$')" = 1 ]
	[ "$(count_lines "$block" '^AGENTS\.md$')" = 1 ]
	assert_not_exists "$BACKEND/.github"
}

@test "link: a multi-segment destination creates its parents and unlink removes them" {
	world_basic

	run "$GRAFT" link --yes frontend
	assert_status 0
	assert_real_dir "$FRONTEND/.cursor"
	assert_symlink_to "$FRONTEND/.cursor/rules" "$CTX/projects/frontend/cursor"
	[ "$(cat "$FRONTEND/.cursor/rules/00-project.mdc")" = "# rules" ]
	[ "$(count_lines "$(exclude_block "$FRONTEND")" '^\.cursor/rules$')" = 1 ]

	run "$GRAFT" unlink
	assert_status 0
	assert_not_exists "$FRONTEND/.cursor/rules"
	# The parent we made goes with it, but only because it is empty again.
	assert_not_exists "$FRONTEND/.cursor"
}

@test "link: a directory the user filled keeps its parent on unlink" {
	world_basic
	run "$GRAFT" link --yes frontend
	assert_status 0
	printf 'mine\n' >"$FRONTEND/.cursor/notes.md"

	run "$GRAFT" unlink
	assert_status 0
	assert_not_exists "$FRONTEND/.cursor/rules"
	assert_real_dir "$FRONTEND/.cursor"
	[ "$(cat "$FRONTEND/.cursor/notes.md")" = mine ]
}

@test "link: paths with spaces and umlauts in the checkout and in the context repo" {
	world_init "kontext repo/übung"
	local co="$HOME/mein projekt/äpfel"
	mkrepo "$co" "git@git.example.com:acme/äpfel.git"
	mkdir -p "$co/.github"
	printf 'PRECIOUS\n' >"$co/.github/keep.md"
	ctx_file projects/api/github/copilot-instructions.md '# api'
	ctx_file projects/api/claude/CLAUDE.md '# claude'
	writeconf "$CTX" <<-'CONF'
		[defaults]
		source_root = projects
		search_root = ~
		link = github -> .github

		[target "api"]
		find = origin:*/acme/äpfel
		link = claude -> .claude
	CONF
	cd "$CTX" || return 1

	local before
	before=$(snapshot "$co")

	run "$GRAFT" link --yes
	assert_status 0
	assert_symlink_to "$co/.github" "$CTX/projects/api/github"
	assert_symlink_to "$co/.claude" "$CTX/projects/api/claude"

	run "$GRAFT" status
	assert_status 0

	run "$GRAFT" unlink
	assert_status 0
	[ "$(snapshot "$co")" = "$before" ]
	[ "$(cat "$co/.github/keep.md")" = PRECIOUS ]
}

@test "graft without a command is graft link" {
	world_basic

	run "$GRAFT" --yes
	assert_status 0
	assert_symlink_to "$BACKEND/.github" "$CTX/projects/backend/github"
	assert_symlink_to "$FRONTEND/.claude" "$CTX/projects/frontend/claude"
}

@test "status writes nothing" {
	world_basic
	run "$GRAFT" link --yes
	assert_status 0

	local before_fe before_ctx
	before_fe=$(snapshot "$FRONTEND")
	before_ctx=$(snapshot "$CTX")

	run "$GRAFT" status
	assert_status 0
	assert_output_contains "context: $CTX"

	[ "$(snapshot "$FRONTEND")" = "$before_fe" ]
	[ "$(snapshot "$CTX")" = "$before_ctx" ]
}

# =============================================================================
# refusals - the things graft must not do
# =============================================================================

@test "I5: a destination tracked by git is refused, with and without --force" {
	world_basic
	mkdir -p "$FRONTEND/.github"
	printf 'workflow\n' >"$FRONTEND/.github/ci.yml"
	git -C "$FRONTEND" add -A
	git -C "$FRONTEND" commit -qm "add .github"

	local before
	before=$(snapshot "$FRONTEND")

	run "$GRAFT" link --yes --only .github frontend
	assert_status 1
	assert_output_contains "tracked by git"
	assert_real_dir "$FRONTEND/.github"
	[ "$(cat "$FRONTEND/.github/ci.yml")" = workflow ]

	# There is no override flag for I5, by design.
	run "$GRAFT" link --yes --force --only .github frontend
	assert_status 1
	assert_output_contains "tracked by git"
	assert_real_dir "$FRONTEND/.github"
	[ "$(count_backups "$FRONTEND/.github")" = 0 ]
	[ "$(snapshot "$FRONTEND")" = "$before" ]
}

@test "a foreign symlink at the destination is left untouched" {
	world_basic
	mkdir -p "$HOME/elsewhere"
	printf 'not ours\n' >"$HOME/elsewhere/other.md"
	ln -s "$HOME/elsewhere" "$FRONTEND/.github"

	run "$GRAFT" link --yes frontend
	assert_status 1
	assert_output_contains "foreign"
	assert_symlink_to "$FRONTEND/.github" "$HOME/elsewhere"
	[ "$(count_backups "$FRONTEND/.github")" = 0 ]
	[ -f "$HOME/elsewhere/other.md" ]
}

@test "--force replaces a foreign symlink and backs it up" {
	world_basic
	mkdir -p "$HOME/elsewhere"
	ln -s "$HOME/elsewhere" "$FRONTEND/.github"

	run "$GRAFT" link --yes --force frontend


	# SPEC 5.1: --force relaxes on_foreign_link, and never suppresses a backup.
	assert_status 0
	assert_symlink_to "$FRONTEND/.github" "$CTX/projects/frontend/github"
	[ "$(count_backups "$FRONTEND/.github")" = 1 ]
}

@test "a moved context repo: status explains the dangling links and link repairs them" {
	world_basic
	run "$GRAFT" link --yes frontend
	assert_status 0
	assert_symlink_to "$FRONTEND/.github" "$CTX/projects/frontend/github"

	cd "$HOME" || return 1
	mv "$CTX" "$HOME/ctx-moved"
	local moved="$HOME/ctx-moved"
	[ ! -e "$FRONTEND/.github/copilot-instructions.md" ]
	[ -L "$FRONTEND/.github" ]

	run "$GRAFT" --config "$moved/graft.conf" status


	assert_status 1
	assert_output_lacks "foreign"
	# graft abbreviates paths under $HOME for readability, so match that form.
	assert_output_contains "${FRONTEND#"$HOME"/}/.github"

	run "$GRAFT" --config "$moved/graft.conf" link --yes
	assert_status 0
	assert_symlink_to "$FRONTEND/.github" "$moved/projects/frontend/github"
	[ "$(cat "$FRONTEND/.github/copilot-instructions.md")" = "# frontend" ]
}

# =============================================================================
# exit codes - SPEC section 5.2, the part of the output that is public API
# =============================================================================

@test "exit 3: non-interactive without --yes prints the plan and changes nothing" {
	world_basic

	run "$GRAFT" link --no-input
	assert_status 3
	assert_output_contains "$(short "$FRONTEND/.github")"
	assert_output_contains "--yes"
	assert_not_exists "$FRONTEND/.github"
	assert_not_exists "$BACKEND/.github"
	[ "$(state_count)" = 0 ]
}

@test "every configured target name is accepted on the command line" {
	world_basic

	# P8: `cfg_targets | grep -q` under `set -o pipefail` reports a successful
	# match as a failure whenever the producer still had output left to write,
	# so every target except the last one defined was rejected as unknown. bats
	# does not enable pipefail and bin/graft does, so only a test that runs the
	# real binary can see it - and it has to name a target that is not the last.
	run "$GRAFT" link --yes backend
	assert_status 0
	assert_symlink_to "$BACKEND/.github" "$CTX/projects/backend/github"

	run "$GRAFT" link --yes frontend
	assert_status 0
	assert_symlink_to "$FRONTEND/.claude" "$CTX/projects/frontend/claude"

	run "$GRAFT" status backend frontend
	assert_status 0
}

@test "exit 2: an unknown target on the command line" {
	world_basic

	run "$GRAFT" link nosuchtarget
	assert_status 2
	assert_output_contains "nosuchtarget"
	# The message has to name the targets that do exist, or the user is stuck.
	assert_output_contains "backend"
	assert_output_contains "frontend"
	assert_not_exists "$FRONTEND/.github"
}

@test "exit 2: a graft.conf that does not parse" {
	world_basic
	writeconf "$CTX" <<-'CONF'
		[defaults]
		source_root = projects
		link = github -> /etc/absolute

		[target "backend"]
		find = nosuchstrategy:whatever
	CONF

	run "$GRAFT" check
	assert_status 2
	assert_output_contains "graft.conf:"

	run "$GRAFT" link --yes
	assert_status 2
	assert_not_exists "$BACKEND/.github"
}

@test "exit 2: an unknown option" {
	world_basic

	run "$GRAFT" --bogus


	assert_status 2
	assert_output_contains "unknown option"
	assert_output_contains "--help"
}

@test "exit 1: require = yes turns a missing checkout into a problem" {
	world_basic
	ctx_file projects/mobile/github/copilot-instructions.md '# mobile'
	cat >>"$CTX/graft.conf" <<-'CONF'

		[target "mobile"]
		find = origin:*/acme/mobile
		require = yes
	CONF

	run "$GRAFT" link --yes
	assert_status 1
	assert_output_contains "mobile"
	assert_output_contains "required"
	# The targets that could be linked still were.
	assert_symlink_to "$BACKEND/.github" "$CTX/projects/backend/github"
}

@test "exit 4: bin/graft without its lib" {
	world_basic
	mkdir -p "$HOME/broken/bin"
	cp "$GRAFT" "$HOME/broken/bin/graft"

	run "$HOME/broken/bin/graft" version
	assert_status 4
	assert_output_contains "lib"
}

# =============================================================================
# flags
# =============================================================================

@test "--json: every line of link --dry-run and of status is one JSON object" {
	world_basic

	run "$GRAFT" link --dry-run --json
	assert_status 0
	assert_json_lines "$output"
	assert_output_contains '"summary"'
	assert_output_contains '"action":"absent"'

	run "$GRAFT" link --yes --json
	assert_status 0
	assert_json_lines "$output"

	run "$GRAFT" status --json
	assert_status 0
	assert_json_lines "$output"
	assert_output_contains '"action":"unchanged"'
	# --json implies --no-input, so it never blocks on a prompt.
	assert_output_lacks "[y/N]"
}

@test "--json: the idempotent run stays machine-readable" {
	world_basic
	run "$GRAFT" link --yes
	assert_status 0

	run "$GRAFT" link --json
	assert_status 0


	assert_json_lines "$output"
	assert_output_contains '"summary"'
}

@test "--json: unlink reports in JSON too" {
	world_basic
	run "$GRAFT" link --yes
	assert_status 0

	run "$GRAFT" unlink --json
	assert_status 0


	assert_json_lines "$output"
}

@test "--only limits the run to the matching destination" {
	world_basic

	run "$GRAFT" link --yes --only .claude
	assert_status 0
	assert_symlink_to "$FRONTEND/.claude" "$CTX/projects/frontend/claude"
	assert_not_exists "$FRONTEND/.github"
	assert_not_exists "$BACKEND/.github"
	assert_not_exists "$FRONTEND/AGENTS.md"
	[ "$(state_count)" = 1 ]

	# Without the filter the rest follows.
	run "$GRAFT" link --yes
	assert_status 0
	assert_symlink_to "$FRONTEND/.github" "$CTX/projects/frontend/github"
	[ "$(state_count)" = 5 ]
}

@test "--path pins a target discovery cannot find, and the pin survives the run" {
	world_basic
	local tools="$HOME/elsewhere/tools"
	mkrepo "$tools" ""
	ctx_file projects/tools/github/copilot-instructions.md '# tools'
	cat >>"$CTX/graft.conf" <<-'CONF'

		[target "tools"]
		find = origin:*/acme/tools-does-not-exist
	CONF

	run "$GRAFT" status tools
	assert_status 0
	assert_output_contains "tools: no checkout found"
	assert_not_exists "$tools/.github"

	run "$GRAFT" link --yes --path "tools=$tools" tools
	assert_status 0
	assert_symlink_to "$tools/.github" "$CTX/projects/tools/github"

	# SPEC 5.1: --path pins for this run *and caches it*.
	run "$GRAFT" status tools
	assert_status 0
	assert_output_contains "$(short "$tools/.github")"

	run "$GRAFT" link --yes --path "tools=/no/such/directory" tools
	assert_status 2
	assert_output_contains "no such directory"
}

@test "--rescan ignores the discovery cache" {
	world_basic
	run "$GRAFT" link --yes backend
	assert_status 0

	# A second checkout with the same origin appears after the cache was built.
	# From the cache the target still looks unambiguous; the truth on disk is
	# that graft must not pick one of the two by itself (SPEC 4.4).
	mkrepo "$HOME/work/backend-fork" "https://git.example.com/acme/backend.git"

	run "$GRAFT" status backend
	assert_status 0

	run "$GRAFT" status --rescan backend


	assert_status 1
	assert_output_contains "checkouts match"
	# and it must hand over the exact way to resolve it, not just complain
	assert_output_contains "graft --path backend="
	assert_output_contains "backend-fork"
}

# =============================================================================
# the other commands
# =============================================================================

@test "init writes a graft.conf that check accepts" {
	world_init
	mkdir -p "$HOME/fresh"
	cd "$HOME/fresh" || return 1

	run "$GRAFT" init
	assert_status 0
	[ -f "$HOME/fresh/graft.conf" ]

	run "$GRAFT" check
	assert_status 0
	assert_output_contains "in order"

	# Running it twice must not overwrite the file the user just edited.
	printf '\n# mine\n' >>"$HOME/fresh/graft.conf"
	local before
	before=$(cksum <"$HOME/fresh/graft.conf")
	run "$GRAFT" init
	assert_status 2
	[ "$(cksum <"$HOME/fresh/graft.conf")" = "$before" ]
}

@test "adopt refuses when the target has no link rule for that path" {
	world_basic
	mkdir -p "$FRONTEND/.vscode"
	printf '{"editor.formatOnSave": true}\n' >"$FRONTEND/.vscode/settings.json"

	# graft will not invent a layout. Where the content belongs is whatever the
	# target's own link rule says, and if there is none it says so.
	run "$GRAFT" adopt "$FRONTEND/.vscode" --as frontend --yes
	assert_status 2
	assert_output_contains "has no link rule"
	assert_output_contains "link = .vscode -> .vscode"
	# and it changed nothing
	assert_real_dir "$FRONTEND/.vscode"
	[ "$(cat "$FRONTEND/.vscode/settings.json")" = '{"editor.formatOnSave": true}' ]
}

@test "adopt moves an untracked directory in and links it back" {
	world_basic
	rm -rf "$FRONTEND/.github"
	mkdir -p "$FRONTEND/.github"
	printf 'house rules\n' >"$FRONTEND/.github/rules.md"
	rm -rf "$CTX/projects/frontend/github"

	run "$GRAFT" adopt "$FRONTEND/.github" --as frontend --yes
	assert_status 0

	# The promise printed in the plan is actually kept: it is a link now.
	assert_symlink_to "$FRONTEND/.github" "$CTX/projects/frontend/github"
	[ "$(cat "$FRONTEND/.github/rules.md")" = "house rules" ]
	[ -z "$(git -C "$FRONTEND" status --porcelain)" ]
}

@test "adopt copies a tracked directory and never stages a deletion" {
	# The dangerous case, and the reason adopt exists at all. Moving a tracked
	# directory out would stage the deletion of files graft does not own, and
	# no unlink could give them back - so a tracked path is copied, never moved.
	world_basic
	rm -rf "$FRONTEND/.github"
	mkdir -p "$FRONTEND/.github/workflows"
	printf 'name: ci\n' >"$FRONTEND/.github/workflows/ci.yml"
	git -C "$FRONTEND" add -A
	git -C "$FRONTEND" commit -qm "add ci"
	rm -rf "$CTX/projects/frontend/github"

	run "$GRAFT" adopt "$FRONTEND/.github" --as frontend --yes
	assert_status 0

	# the project repo is exactly as it was
	[ -z "$(git -C "$FRONTEND" status --porcelain)" ]
	assert_real_dir "$FRONTEND/.github"
	[ "$(cat "$FRONTEND/.github/workflows/ci.yml")" = "name: ci" ]
	# and the content arrived in the context repo
	[ "$(cat "$CTX/projects/frontend/github/workflows/ci.yml")" = "name: ci" ]
	# with git, not graft, named as the only thing that may remove it
	assert_output_contains "rm -r --cached"
}

@test "adopt refuses to overwrite content already in the context repo" {
	world_basic
	mkdir -p "$FRONTEND/.claude"
	printf 'newer\n' >"$FRONTEND/.claude/CLAUDE.md"

	run "$GRAFT" adopt "$FRONTEND/.claude" --as frontend --yes
	assert_status 2
	assert_output_contains "already present in the context repo"
	[ "$(cat "$FRONTEND/.claude/CLAUDE.md")" = newer ]
}

@test "unlink is stateless enough to survive a lost state file" {
	world_basic
	run "$GRAFT" link --yes frontend
	assert_status 0
	local before_target
	before_target=$(readlink "$FRONTEND/.github")

	rm -f "$(state_path)"

	run "$GRAFT" unlink
	assert_status 0
	# Without records graft has nothing to reverse, and it must not guess.
	# What it must never do is remove somebody else's data on the way.
	[ -L "$FRONTEND/.github" ] || [ ! -e "$FRONTEND/.github" ]
	if [ -L "$FRONTEND/.github" ]; then
		[ "$(readlink "$FRONTEND/.github")" = "$before_target" ]
	fi
	[ -f "$CTX/projects/frontend/github/copilot-instructions.md" ]
}

@test "a target that resolves nowhere is reported, not ticked off as done" {
	# A green "nothing to do" for a configuration in which nothing resolved is
	# the single most misleading thing this tool could print.
	world_basic
	cat >>"$CTX/graft.conf" <<-'CONF'

		[target "ghost"]
		find = origin:*/acme/ghost-that-does-not-exist
	CONF
	run "$GRAFT" link --yes
	assert_output_contains "ghost"
	assert_output_lacks "nothing to do"
}

@test "a missing checkout says which patterns were tried and how to pin it" {
	world_basic
	cat >>"$CTX/graft.conf" <<-'CONF'

		[target "ghost"]
		find = origin:*/acme/nowhere
		find = env:GHOST_DIR
	CONF
	run "$GRAFT" status
	assert_output_contains "tried: origin:*/acme/nowhere"
	assert_output_contains "tried: env:GHOST_DIR"
	assert_output_contains "graft --path ghost="
}

@test "unlink honours --only instead of removing everything" {
	# --only is documented as a global flag. Ignoring it here meant someone who
	# asked for one link back lost all of them.
	world_basic
	run "$GRAFT" link --yes frontend
	assert_status 0
	run "$GRAFT" unlink --only .claude --yes
	assert_status 0
	[ ! -L "$FRONTEND/.claude" ]
	[ -L "$FRONTEND/.github" ]
}

@test "unlink --dry-run says would, and removes nothing" {
	world_basic
	run "$GRAFT" link --yes frontend
	run "$GRAFT" unlink --dry-run
	assert_status 0
	assert_output_contains "would"
	assert_output_lacks "links removed"
	[ -L "$FRONTEND/.github" ]
}

@test "unlink still works after the state file is lost" {
	# A rebuilt machine or a cleared XDG_STATE_HOME must not strand every link.
	world_basic
	run "$GRAFT" link --yes frontend
	assert_status 0
	rm -rf "$XDG_STATE_HOME/graft"

	run "$GRAFT" unlink --yes frontend
	assert_status 0
	assert_output_contains "link removed"
	[ ! -L "$FRONTEND/.github" ]
	[ ! -L "$FRONTEND/.claude" ]
	run grep -c graft "$FRONTEND/.git/info/exclude"
	[ "$output" = 0 ]
}

# --- config keys that were accepted but did nothing --------------------------
#
# A key the parser validates and the tool then ignores is the worst kind of
# documentation lie: the user gets a green tick for a setting that never ran.

@test "confirm = yes asks before touching that target and honours a no" {
	world_basic
	printf '\nconfirm = yes\n' >>"$CTX/graft.conf"
	# Non-interactive without --yes: the question cannot be asked, so the
	# target must be left alone rather than silently linked.
	run "$GRAFT" link frontend
	[ ! -L "$FRONTEND/.github" ]
}

@test "on_foreign_link = abort refuses the whole run, warn does not" {
	world_basic
	mkdir -p "$SANDBOX/elsewhere"
	ln -s "$SANDBOX/elsewhere" "$FRONTEND/.claude"

	printf '\non_foreign_link = warn\n' >>"$CTX/graft.conf"
	run "$GRAFT" link --yes frontend
	assert_status 1
	[ -L "$FRONTEND/.github" ] # the other links still went in

	rm -f "$FRONTEND/.github"
	rm -rf "$XDG_STATE_HOME/graft"
	sed -i.bak 's/^on_foreign_link = warn$/on_foreign_link = abort/' "$CTX/graft.conf"
	run "$GRAFT" link --yes frontend
	assert_status 1
	assert_output_contains "on_foreign_link = abort"
	[ ! -L "$FRONTEND/.github" ] # nothing was applied at all
}

@test "status shows each target's description" {
	world_basic
	run "$GRAFT" status
	assert_output_contains "the frontend app"
}

@test "backup_suffix is honoured end to end, including by unlink" {
	world_basic
	# into [defaults], not appended at the end where the last [target] block is
	sed -i.bak 's/^\[defaults\]$/[defaults]\nbackup_suffix = .MYSUFFIX/' "$CTX/graft.conf"
	mkdir -p "$FRONTEND/.github"
	printf 'precious\n' >"$FRONTEND/.github/keep.md"

	run "$GRAFT" link --yes frontend
	assert_status 0
	# the configured suffix, not the hardcoded default
	[ -z "$(find "$FRONTEND" -maxdepth 1 -name '.github.graft-backup*' -print -quit)" ]
	[ -n "$(find "$FRONTEND" -maxdepth 1 -name '.github.MYSUFFIX*' -print -quit)" ]

	# and unlink has to find that same backup again
	run "$GRAFT" unlink --yes frontend
	assert_status 0
	[ "$(cat "$FRONTEND/.github/keep.md")" = precious ]
}

@test "a backup stays out of git status but graft keeps telling you about it" {
	# The promise is that the project repo is left alone. A backup directory
	# sitting untracked in `git status` breaks that just as surely as the link
	# would - and eventually someone sweeps it into a `git add -A`.
	world_basic
	mkdir -p "$FRONTEND/.github"
	printf 'precious\n' >"$FRONTEND/.github/keep.md"

	run "$GRAFT" link --yes frontend
	assert_status 0
	# it was moved aside, and the run says where to
	assert_output_contains "moved aside"
	[ -z "$(git -C "$FRONTEND" status --porcelain)" ]

	# hidden, but not forgotten
	run "$GRAFT" status
	assert_output_contains "moved aside"
	assert_output_contains ".graft-backup"

	# and unlink takes both the link and the backup's exclude line back out
	run "$GRAFT" unlink --yes frontend
	assert_status 0
	[ "$(cat "$FRONTEND/.github/keep.md")" = precious ]
	run grep -c graft "$FRONTEND/.git/info/exclude"
	[ "$output" = 0 ]
}

@test "exit 4: an environment graft cannot work in, with the matching reason" {
	# The spec always promised exit 4 for "environment cannot support graft",
	# but the code reported plain drift (1) - which sends the reader off to fix
	# their config instead of their filesystem.
	world_basic
	chmod 500 "$FRONTEND"

	run "$GRAFT" link --yes frontend
	chmod 700 "$FRONTEND"
	assert_status 4
	assert_output_contains "cannot write in"
	assert_output_contains "permissions"
	# no cheerful tick for a run that placed nothing
	assert_output_lacks "in place"
	# and no raw shell noise from the probe
	assert_output_lacks "Permission denied"
}

@test "shared fragments inside the context repo survive the link" {
	# A context repo commonly keeps one copy of a shared document and points at
	# it from several targets with a relative symlink. Those links resolve
	# against their real location, so they have to keep working when the tree
	# is reached through graft's own symlink - otherwise every project gets a
	# .github with a dead file in it.
	world_basic
	mkdir -p "$CTX/docs" "$CTX/projects/frontend/github/instructions"
	printf 'house rules\n' >"$CTX/docs/conventions.md"
	ln -s ../../../../docs/conventions.md \
		"$CTX/projects/frontend/github/instructions/conventions.md"

	run "$GRAFT" link --yes frontend
	assert_status 0
	[ "$(cat "$FRONTEND/.github/instructions/conventions.md")" = "house rules" ]
	# and a tool walking the tree finds it rather than a dangling entry
	run find -L "$FRONTEND/.github" -name conventions.md
	assert_output_contains "conventions.md"
}

@test "unlink restores the backup even after the context repo was moved" {
	# The state file is addressed by the path of graft.conf, so renaming or
	# moving the context repo starts a fresh state. The repoint run then
	# records no backup, and the old record - the only thing that knew where
	# the user's file went - is orphaned. unlink used to remove the link,
	# restore nothing, and report success.
	world_basic
	printf 'my important file\n' >"$FRONTEND/CLAUDE.md"
	run "$GRAFT" link --yes frontend
	assert_status 0

	mv "$CTX" "$SANDBOX/moved-ctx"
	run "$GRAFT" --config "$SANDBOX/moved-ctx/graft.conf" link --yes
	assert_status 0
	run "$GRAFT" --config "$SANDBOX/moved-ctx/graft.conf" unlink --yes
	assert_status 0

	[ "$(cat "$FRONTEND/CLAUDE.md")" = "my important file" ]
}

@test "a link removed from the config is removed from the checkout too" {
	# Reconciling a declared state with reality has to notice what was
	# withdrawn, not only what is new. Otherwise deleting a link line from a
	# shared context repo leaves the symlink and its exclude entry on every
	# colleague's machine for good, while link and status keep saying all is well.
	world_basic
	run "$GRAFT" link --yes frontend
	assert_status 0
	[ -L "$FRONTEND/.claude" ]

	sed -i.bak '/-> \.claude$/d' "$CTX/graft.conf"

	# status says so without touching anything
	run "$GRAFT" status
	assert_output_contains "no longer in the configuration"
	[ -L "$FRONTEND/.claude" ]

	# dry-run announces it and still changes nothing
	run "$GRAFT" link --dry-run
	assert_output_contains "no longer in the configuration"
	[ -L "$FRONTEND/.claude" ]

	# link cleans it up, exclude entry included
	run "$GRAFT" link --yes
	assert_status 0
	[ ! -L "$FRONTEND/.claude" ]
	[ -L "$FRONTEND/.github" ]
	run grep -c '^\.claude$' "$FRONTEND/.git/info/exclude"
	[ "$output" = 0 ]

	# and then it is quiet again
	run "$GRAFT" link
	assert_status 0
	assert_output_contains "nothing to do"
}

@test "--only narrows the plan without looking like a deletion" {
	# Everything outside the filter is absent from the plan. Treating that as
	# "withdrawn from the config" would make --only delete the rest.
	world_basic
	run "$GRAFT" link --yes frontend
	assert_status 0
	run "$GRAFT" link --yes --only .github
	assert_status 0
	[ -L "$FRONTEND/.claude" ]
	[ -L "$FRONTEND/.github" ]
}

@test "check reports a source that does not exist" {
	# Validating only the grammar is not much of a check: the commonest mistake
	# is a source directory that is not there, and a green tick for a config
	# whose links all point at nothing is worse than no check at all.
	world_basic
	rm -rf "$CTX/projects/frontend/github"

	run "$GRAFT" check
	assert_status 1
	assert_output_contains "source does not exist"
	assert_output_contains "projects/frontend/github"
}

@test "init scaffolds the layout it describes, and link explains the skip" {
	# The first run used to print a blank line and '1 skipped', exit 0, with no
	# diagnosis anywhere - the point at which people decide it is broken.
	mkdir -p "$HOME/fresh"
	cd "$HOME/fresh" || return 1

	run "$GRAFT" init
	assert_status 0
	[ -f "$HOME/fresh/projects/example/github/copilot-instructions.md" ]

	run "$GRAFT" check
	assert_status 0

	run "$GRAFT" link --yes
	assert_output_contains "no checkout found"
	assert_output_contains "tried:"
	assert_output_contains "--path example="
}
