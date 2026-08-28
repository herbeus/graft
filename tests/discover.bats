#!/usr/bin/env bats
# shellcheck shell=bash
#
# discover.bats - checkout discovery and its cache (SPEC 4.4, 3, 9.2).
#
# lib/config.sh is deliberately NOT sourced here. Discovery only ever calls the
# readers named in the module contract, so stubbing them keeps this suite
# runnable, fast and independent of the INI parser. The stubs use the one
# section encoding config.sh documents - `target:<name>` - because that is the
# contract; there is no second spelling to be tolerant about.

# shellcheck source-path=SCRIPTDIR

bats_require_minimum_version 1.5.0

load helpers/sandbox

setup() {
	gr_sandbox
	# shellcheck source=../lib/core.sh
	. "$GRAFT_ROOT/lib/core.sh"
	# shellcheck source=../lib/discover.sh
	. "$GRAFT_ROOT/lib/discover.sh"
	gr_init_style

	fresh_run
	CFG_STUB=''
	CFG_FILE="$SANDBOX/ctx/graft.conf"
	mkdir -p "$SANDBOX/ctx"
	: >"$CFG_FILE"
	cfg_set defaults search_root "$SANDBOX/work"
	mkdir -p "$SANDBOX/work"
}

teardown() {
	gr_sandbox_teardown
}

# --- config stubs (signatures per SPEC 9.1) ----------------------------------

cfg_set() {
	CFG_STUB="${CFG_STUB}${1}"$'\t'"${2}"$'\t'"${3}"$'\n'
}

cfg_get_all() {
	local sec="$1" key="$2" line s rest k v
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		s=${line%%$'\t'*}
		rest=${line#*$'\t'}
		k=${rest%%$'\t'*}
		v=${rest#*$'\t'}
		[ "$s" = "$sec" ] || continue
		[ "$k" = "$key" ] || continue
		printf '%s\n' "$v"
	done <<<"$CFG_STUB"
}

# Last value wins, plus the caller's default when the key is absent.
cfg_get() {
	local v
	v=$(cfg_get_all "$1" "$2" | tail -n 1)
	if [ -n "$v" ]; then
		printf '%s\n' "$v"
	elif [ $# -ge 3 ]; then
		printf '%s\n' "$3"
	fi
}

cfg_target_get() {
	local t="$1" key="$2" def="${3:-}" v
	v=$(cfg_get_all "target:$t" "$key" | tail -n 1)
	[ -n "$v" ] || v=$(cfg_get_all defaults "$key" | tail -n 1)
	[ -n "$v" ] || v="$def"
	printf '%s\n' "$v"
}

cfg_target_finds() { cfg_get_all "target:$1" find; }

cfg_target_verifies() { cfg_get_all "target:$1" verify; }

# --- helpers -----------------------------------------------------------------

# fresh_run - reset the module state as if a new graft process had started.
fresh_run() {
	DISC_LOADED=0
	DISC_ROWS=''
	DISC_REBUILT=0
	DISC_FROM_CACHE=0
	DISC_STALE=0
	DISC_CANDS=''
	DISC_STACK='|'
}

# resolve <target> - run disc_resolve, keeping stderr out of the captured value.
resolve() {
	RC=0
	OUT=$(disc_resolve "$1" 2>/dev/null) || RC=$?
	return 0
}

rowcount() {
	if [ -z "$DISC_ROWS" ]; then printf '0'; else printf '%s\n' "$DISC_ROWS" | wc -l | tr -d ' '; fi
}

# --- origin URL normalisation ------------------------------------------------
#
# Every origin comparison goes through disc__norm_url_into first, so one glob
# has to fit both clone forms of the same repository. scp-style shorthand puts
# a colon where every other form has a slash; a URL with a scheme must keep its
# colon, because there it is a port.

@test "norm url: scp-style ssh shorthand becomes a slash path" {
	run disc__norm_url 'git@github.com:acme/api.git'
	assert_status 0
	[ "$output" = 'git@github.com/acme/api' ]
}

@test "norm url: an https URL only loses its .git and trailing slash" {
	run disc__norm_url 'https://github.com/acme/api.git'
	assert_status 0
	[ "$output" = 'https://github.com/acme/api' ]

	run disc__norm_url 'https://github.com/acme/api/'
	[ "$output" = 'https://github.com/acme/api' ]
}

@test "norm url: a port in ssh://host:22/path is not a shorthand colon" {
	run disc__norm_url 'ssh://git@host:22/acme/api.git'
	assert_status 0
	[ "$output" = 'ssh://git@host:22/acme/api' ]

	run disc__norm_url 'ssh://git@host/acme/api'
	[ "$output" = 'ssh://git@host/acme/api' ]
}

@test "norm url: scp-style with an absolute path does not double the slash" {
	run disc__norm_url 'git@host:/srv/git/acme/api.git'
	assert_status 0
	[ "$output" = 'git@host/srv/git/acme/api' ]
}

@test "norm url: a local path without a scheme is left alone" {
	run disc__norm_url '/home/me/repos/api'
	assert_status 0
	[ "$output" = '/home/me/repos/api' ]

	run disc__norm_url '/srv/git/api.git'
	[ "$output" = '/srv/git/api' ]
}

@test "find origin: */acme/api matches the ssh clone of the repo" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	cfg_set 'target:api' find 'origin:*/acme/api'

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api" ]
}

@test "find origin: the same */acme/api matches the https clone too" {
	mkrepo "$SANDBOX/work/api" "https://github.com/acme/api.git"
	cfg_set 'target:api' find 'origin:*/acme/api'

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api" ]
}

# --- the scan ----------------------------------------------------------------

@test "index: one scan records path, origin and last commit for every checkout" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/web" "https://github.com/acme/web"
	mkdir -p "$SANDBOX/work/plain"

	disc_index_build

	[ "$(rowcount)" -eq 2 ]
	[ -f "$DISC_INDEX" ]
	run head -n 2 "$DISC_INDEX"
	assert_output_contains '#graft-cache'
	assert_output_contains 'last_commit_epoch'

	run disc_info "$SANDBOX/work/api"
	assert_status 0
	assert_output_contains 'git@github.com:acme/api.git'
	# last commit epoch is a number, not a placeholder
	[ -n "$(printf '%s' "$output" | cut -f2)" ]
}

@test "index: prune keeps repos below node_modules out of the index" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/api/node_modules/dep" "git@github.com:other/dep.git"

	disc_index_build

	[ "$(rowcount)" -eq 1 ]
	case "$DISC_ROWS" in
	*node_modules*)
		printf 'node_modules leaked into the index:\n%s\n' "$DISC_ROWS" >&2
		return 1
		;;
	esac
}

@test "index: search_depth limits how deep a checkout may sit" {
	cfg_set defaults search_depth 2
	mkrepo "$SANDBOX/work/a/shallow" "git@github.com:acme/shallow.git"
	mkrepo "$SANDBOX/work/a/b/c/deep" "git@github.com:acme/deep.git"

	disc_index_build

	case "$DISC_ROWS" in
	*shallow*) ;;
	*)
		printf 'shallow checkout missing:\n%s\n' "$DISC_ROWS" >&2
		return 1
		;;
	esac
	case "$DISC_ROWS" in
	*deep*)
		printf 'maxdepth did not apply:\n%s\n' "$DISC_ROWS" >&2
		return 1
		;;
	esac
}

@test "index: paths with spaces and umlauts survive the scan" {
	mkrepo "$SANDBOX/work/mein projekt/über api" "git@github.com:acme/uber.git"
	cfg_set defaults search_depth 4

	disc_index_build

	cfg_set 'target:u' find 'origin:*acme/uber'
	resolve u
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/mein projekt/über api" ]
}

@test "index: a newline inside a path is escaped, not a second record" {
	mkrepo "$SANDBOX/work/line"$'\n'"break" "git@github.com:acme/nl.git"

	disc_index_build

	[ "$(rowcount)" -eq 1 ]
	case "$DISC_ROWS" in
	*'\n'*) ;;
	*)
		printf 'newline was not escaped:\n%s\n' "$DISC_ROWS" >&2
		return 1
		;;
	esac

	# and it decodes back to the real path when the cache is read again
	fresh_run
	disc_index_load
	[ "$DISC_FROM_CACHE" -eq 1 ]
	run disc_info "$SANDBOX/work/line"$'\n'"break"
	assert_status 0
	assert_output_contains 'git@github.com:acme/nl.git'
}

@test "index: every search_root is walked by the same single scan" {
	mkdir -p "$SANDBOX/other"
	cfg_set defaults search_root "$SANDBOX/other"
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/other/web" "git@github.com:acme/web.git"

	disc_index_build

	[ "$(rowcount)" -eq 2 ]
	run disc_info "$SANDBOX/other/web"
	assert_status 0
}

@test "index: a resolve answered from the cache does not rescan" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	cfg_set 'target:api' find 'origin:*acme/api'
	disc_index_build

	fresh_run
	disc_index_load
	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api" ]
	# the scan budget of a run is one, and a hit must not spend it
	[ "$DISC_REBUILT" -eq 0 ]
}

# --- strategies --------------------------------------------------------------

@test "find path: takes the directory as given" {
	mkdir -p "$SANDBOX/elsewhere/api"
	cfg_set 'target:api' find "path:$SANDBOX/elsewhere/api"

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/elsewhere/api" ]
}

@test "find env: an unset variable fails softly and the next strategy wins" {
	unset GRAFT_TEST_DIR
	mkdir -p "$SANDBOX/work/fallback"
	cfg_set 'target:api' find 'env:GRAFT_TEST_DIR'
	cfg_set 'target:api' find "path:$SANDBOX/work/fallback"

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/fallback" ]
}

@test "find env: a set variable resolves to its directory" {
	mkdir -p "$SANDBOX/work/from-env"
	export GRAFT_TEST_DIR="$SANDBOX/work/from-env"
	cfg_set 'target:api' find 'env:GRAFT_TEST_DIR'

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/from-env" ]
}

@test "find origin: glob matches after the .git suffix is normalised away" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	cfg_set 'target:api' find 'origin:*github.com[:/]acme/api'

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api" ]
}

@test "find origin: one glob matches both the ssh and the https remote form" {
	mkrepo "$SANDBOX/work/ssh-one" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/https-one" "https://github.com/acme/api"
	cfg_set 'target:a' find 'origin:*github.com[:/]acme/api'

	resolve a
	# both checkouts are the same repository - that is ambiguity, not a pick
	[ "$RC" -eq 2 ]
	assert_line_present "$SANDBOX/work/ssh-one"
	assert_line_present "$SANDBOX/work/https-one"
}

@test "find origin-re: an ERE matches what a glob cannot express" {
	mkrepo "$SANDBOX/work/api" "https://gitlab.example.com/team/api-service.git"
	cfg_set 'target:api' find 'origin-re:^https://gitlab\.example\.com/team/api-(service|gateway)$'

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api" ]
}

@test "find dir: a path glob selects exactly one checkout" {
	mkrepo "$SANDBOX/work/acme/api" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/acme/web" "git@github.com:acme/web.git"
	cfg_set 'target:api' find "dir:$SANDBOX/work/*/api"

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/acme/api" ]
}

@test "find parent-of: resolves to the directory above the inner result" {
	mkrepo "$SANDBOX/work/mono/services/api" "git@github.com:acme/api.git"
	cfg_set 'target:svc' find 'parent-of:origin:*acme/api'

	resolve svc
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/mono/services" ]
}

@test "find target: borrows another target's checkout" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	cfg_set 'target:api' find 'origin:*acme/api'
	cfg_set 'target:docs' find 'target:api'

	resolve docs
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api" ]
}

@test "find target: a cycle is refused instead of recursing forever" {
	cfg_set 'target:a' find 'target:b'
	cfg_set 'target:b' find 'target:a'

	run --separate-stderr disc_resolve a
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	case "$stderr" in
	*cycle*) ;;
	*)
		printf 'expected a cycle warning, got: %s\n' "$stderr" >&2
		return 1
		;;
	esac
}

@test "find: the first strategy that matches wins over later ones" {
	mkdir -p "$SANDBOX/work/first" "$SANDBOX/work/second"
	cfg_set 'target:api' find "path:$SANDBOX/work/first"
	cfg_set 'target:api' find "path:$SANDBOX/work/second"

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/first" ]
}

# --- verify, ambiguity, absence ----------------------------------------------

@test "verify: narrows two candidates down to the one that carries the marker" {
	mkrepo "$SANDBOX/work/api-a" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/api-b" "git@github.com:acme/api.git"
	mkdir -p "$SANDBOX/work/api-b/src"
	printf 'x\n' >"$SANDBOX/work/api-b/pom.xml"
	cfg_set 'target:api' find 'origin:*acme/api'
	cfg_set 'target:api' verify 'pom.xml'
	cfg_set 'target:api' verify 'src'

	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api-b" ]
}

@test "verify: rejecting the only candidate is a miss, not a match" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	cfg_set 'target:api' find 'origin:*acme/api'
	cfg_set 'target:api' verify 'pom.xml'

	resolve api
	[ "$RC" -eq 1 ]
	[ -z "$OUT" ]
}

@test "ambiguity: several candidates are all printed and nothing is picked" {
	mkrepo "$SANDBOX/work/one" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/two" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/three" "git@github.com:acme/api.git"
	cfg_set 'target:api' find 'origin:*acme/api'

	resolve api
	[ "$RC" -eq 2 ]
	[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 3 ]
	assert_line_present "$SANDBOX/work/one"
	assert_line_present "$SANDBOX/work/two"
	assert_line_present "$SANDBOX/work/three"
}

@test "absence: no strategy matches and nothing is printed" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	cfg_set 'target:gone' find 'origin:*acme/nothing-here'

	resolve gone
	[ "$RC" -eq 1 ]
	[ -z "$OUT" ]
}

# --- cache -------------------------------------------------------------------

@test "cache: a second load reuses the file instead of scanning again" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	disc_index_build
	[ "$(rowcount)" -eq 1 ]

	# a checkout that appeared after the scan is invisible to a cached load
	mkrepo "$SANDBOX/work/late" "git@github.com:acme/late.git"
	fresh_run
	disc_index_load

	[ "$DISC_FROM_CACHE" -eq 1 ]
	[ "$(rowcount)" -eq 1 ]
}

@test "cache: a cached path that has vanished forces a rebuild" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	mkrepo "$SANDBOX/work/old" "git@github.com:acme/old.git"
	disc_index_build
	[ "$(rowcount)" -eq 2 ]

	rm -rf "$SANDBOX/work/old"
	fresh_run
	disc_index_load

	[ "$DISC_FROM_CACHE" -eq 0 ]
	[ "$(rowcount)" -eq 1 ]
	case "$DISC_ROWS" in
	*'/old'*)
		printf 'stale row survived:\n%s\n' "$DISC_ROWS" >&2
		return 1
		;;
	esac
}

@test "cache: a changed origin URL invalidates the row instead of misleading" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	disc_index_build
	git -C "$SANDBOX/work/api" remote set-url origin "git@github.com:acme/renamed.git"

	# reload from the cache, which still claims the old URL
	fresh_run
	disc_index_load
	[ "$DISC_FROM_CACHE" -eq 1 ]

	cfg_set 'target:old' find 'origin:*acme/api'
	resolve old
	[ "$RC" -eq 1 ]
	[ -z "$OUT" ]

	# and the rescan it triggered makes the new URL resolvable right away
	cfg_set 'target:new' find 'origin:*acme/renamed'
	resolve new
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/api" ]
}

@test "cache: --rescan ignores the cache file" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	disc_index_build
	mkrepo "$SANDBOX/work/late" "git@github.com:acme/late.git"

	fresh_run
	disc_index_load --rescan

	[ "$DISC_FROM_CACHE" -eq 0 ]
	[ "$(rowcount)" -eq 2 ]
}

@test "cache: an unknown schema version warns once and rebuilds" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	disc_index_build
	f="$(disc_cache_file)"
	printf '#graft-cache\t99\t%s\n#path\torigin\tepoch\n' "$CFG_FILE" >"$f"

	fresh_run
	run --separate-stderr disc_index_load
	[ "$status" -eq 0 ]
	case "$stderr" in
	*schema*) ;;
	*)
		printf 'expected a schema warning, got: %s\n' "$stderr" >&2
		return 1
		;;
	esac

	fresh_run
	disc_index_load
	[ "$(rowcount)" -eq 1 ]
}

# --- pins --------------------------------------------------------------------

@test "pin: disc_pin records a path that disc_pinned reads back" {
	mkdir -p "$SANDBOX/work/manual"

	run disc_pinned api
	assert_status 1

	disc_pin api "$SANDBOX/work/manual"
	run disc_pinned api
	assert_status 0
	[ "$output" = "$SANDBOX/work/manual" ]

	# rebuilding the index must not drop the pin
	disc_index_build
	run disc_pinned api
	assert_status 0
}

@test "pin: a pinned path outranks the find strategies" {
	mkrepo "$SANDBOX/work/api" "git@github.com:acme/api.git"
	mkdir -p "$SANDBOX/work/manual"
	cfg_set 'target:api' find 'origin:*acme/api'

	disc_pin api "$SANDBOX/work/manual"
	resolve api
	[ "$RC" -eq 0 ]
	[ "$OUT" = "$SANDBOX/work/manual" ]
}

@test "pin: a pin whose directory disappeared is not an answer" {
	mkdir -p "$SANDBOX/work/manual"
	disc_pin api "$SANDBOX/work/manual"
	rm -rf "$SANDBOX/work/manual"

	run disc_pinned api
	assert_status 1
}

@test "pin: disc_pin refuses a path that is not a directory" {
	run disc_pin api "$SANDBOX/work/nope"
	assert_status 1
}

# --- assertions used above ---------------------------------------------------

assert_line_present() {
	local want="$1" line
	while IFS= read -r line; do
		[ "$line" = "$want" ] && return 0
	done <<<"$OUT"
	printf 'expected a line %s in:\n%s\n' "$want" "$OUT" >&2
	return 1
}

@test "env: reads the environment, not graft's own variables" {
	# `${!name}` executes nothing, but it cannot tell an exported variable from
	# one of graft's locals - so `find = env:CFG_CTX_ROOT` in a config file you
	# cloned from a colleague resolved to the context repo itself.
	local secret="$SANDBOX/should-not-be-reachable"
	mkdir -p "$secret"
	# a shell variable that is deliberately NOT exported
	CFG_CTX_ROOT="$secret"

	run disc__by_env CFG_CTX_ROOT
	[ "$status" -ne 0 ]

	# a real environment variable still works
	mkdir -p "$SANDBOX/real"
	DISC_CANDS=""
	MY_CHECKOUT="$SANDBOX/real" disc__by_env MY_CHECKOUT
	[ "$DISC_CANDS" = "$SANDBOX/real" ]
}

@test "cache: a stale cache is rebuilt instead of believed" {
	# The cache remembers a scan, not a decision. Believed forever, it quietly
	# answers "one candidate" for a target that now has two - which contradicts
	# the one thing discovery promises: never to pick for you.
	mkrepo "$SANDBOX/work/one" "https://h/acme/api.git"
	disc_index_build
	[ "$DISC_N" -ge 1 ]

	# a second clone appears after the scan
	mkrepo "$SANDBOX/work/two" "https://h/acme/api.git"

	# a fresh cache is still trusted, which is the point of having one
	disc_index_load
	[ "$DISC_FROM_CACHE" = 1 ]

	# an old one is not
	local f
	f=$(disc_cache_file)
	sed -i.bak "1s/\t[0-9]*$/\t$(($(date +%s) - 7200))/" "$f"
	DISC_FROM_CACHE=0
	disc_index_load
	[ "$DISC_FROM_CACHE" != 1 ]
	[ "$DISC_N" -ge 2 ]
}
