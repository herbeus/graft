#!/usr/bin/env bats
#
# config.bats - the INI subset parser and its validation (docs/SPEC.md 4, 9.1).
#
# bin/graft does not exist yet, so these tests source lib/ directly.
#
# shellcheck disable=SC2154 # $status/$output are set by bats' `run`
# shellcheck disable=SC2016 # expectations quote ${...} on purpose, as data
# shellcheck disable=SC2030,SC2031 # bats runs each @test in its own subshell

load helpers/sandbox

setup() {
	gr_sandbox
	# shellcheck source=lib/core.sh
	. "$GRAFT_ROOT/lib/core.sh"
	# shellcheck source=lib/config.sh
	. "$GRAFT_ROOT/lib/config.sh"
	gr_init_style
	CTX="$SANDBOX/ctx"
	mkctx "$CTX"
}

teardown() {
	gr_sandbox_teardown
}

# conf - write graft.conf from stdin and load it. Leaves $rc plus every CFG_*.
# Not run through bats' `run`, which would parse in a subshell and throw the
# parsed state away.
conf() {
	writeconf "$CTX"
	rc=0
	cfg_load "$CTX/graft.conf" || rc=$?
}

# assert_error <substring> - somewhere in the rendered error report.
assert_error() {
	local report
	report=$(cfg_print_errors 2>&1)
	case "$report" in
	*"$1"*) ;;
	*)
		printf 'expected an error containing: %s\ngot:\n%s\n' "$1" "$report" >&2
		return 1
		;;
	esac
}

# Wrappers so that a big config can be driven through bats' `run`, which is the
# only way to switch off its per command tracing.
load_only() {
	cfg_load "$CTX/graft.conf"
}

load_and_validate() {
	cfg_load "$CTX/graft.conf" || :
	cfg_validate
}

assert_no_errors() {
	if [ -n "$CFG_ERRORS" ]; then
		printf 'expected a clean config, got:\n%s\n' "$(cfg_print_errors 2>&1)" >&2
		return 1
	fi
}

# --- happy path --------------------------------------------------------------

@test "config: a minimal config parses and sets the roots" {
	conf <<-'EOF'
		[target "demo"]
		find = origin:*/demo.git
	EOF
	assert_no_errors
	[ "$rc" -eq 0 ]
	[ "$CFG_FILE" = "$CTX/graft.conf" ]
	[ "$CFG_CTX_ROOT" = "$CTX" ]
	[ "$CFG_SOURCE_ROOT" = "$CTX" ]
	run cfg_targets
	[ "$output" = "demo" ]
}

@test "config: a complex config keeps sections, order and inheritance" {
	conf <<-'EOF'
		# shared context for the whole team
		[defaults]
		source_root = projects
		search_root = ~/code
		search_depth = 2
		search_prune = node_modules,dist
		backup = suffix
		link = github -> .github

		[target "demo"]
		description = the demo checkout
		find = origin:*/demo.git
		find = dir:*/demo
		verify = .git
		link = github/copilot-instructions.md -> .cursor/rules/main.md
		backup = abort

		[target "other"]
		source = demo
		find = target:demo

		[setup "hooks"]
		description = install the git hooks
		run = scripts/hooks.sh
	EOF
	assert_no_errors
	[ "$CFG_SOURCE_ROOT" = "$CTX/projects" ]

	run cfg_targets
	[ "${lines[0]}" = "demo" ]
	[ "${lines[1]}" = "other" ]

	run cfg_setups
	[ "$output" = "hooks	install the git hooks	scripts/hooks.sh" ]

	# target value wins, [defaults] fills in, built-in default is last
	run cfg_target_get demo backup
	[ "$output" = "abort" ]
	run cfg_target_get other backup
	[ "$output" = "suffix" ]
	run cfg_target_get other git_exclude
	[ "$output" = "yes" ]
	run cfg_target_get other on_foreign_link
	[ "$output" = "warn" ]

	run cfg_get defaults search_depth
	[ "$output" = "2" ]
}

@test "config: repeatable keys keep their order, the rest is last-wins" {
	conf <<-'EOF'
		[defaults]
		backup = suffix
		backup_suffix = .one
		backup_suffix = .two

		[target "demo"]
		find = env:DEMO_DIR
		find = origin:*/demo.git
		find = dir:*/demo
		verify = .git
		verify = package.json
	EOF
	# backup_suffix is not repeatable, so this config is invalid ...
	assert_error "may appear only once per section"
	# ... but the accessors still answer in file order.
	run cfg_target_finds demo
	[ "${lines[0]}" = "env:DEMO_DIR" ]
	[ "${lines[1]}" = "origin:*/demo.git" ]
	[ "${lines[2]}" = "dir:*/demo" ]
	run cfg_get_all "target:demo" verify
	[ "${lines[0]}" = ".git" ]
	[ "${lines[1]}" = "package.json" ]
	run cfg_get defaults backup_suffix
	[ "$output" = ".two" ]
}

@test "config: cfg_find_conf walks up, and gives up at the root" {
	writeconf "$CTX" <<-'EOF'
		[defaults]
	EOF
	mkdir -p "$CTX/a/b/c"
	run cfg_find_conf "$CTX/a/b/c"
	assert_status 0
	[ "$output" = "$CTX/graft.conf" ]

	mkdir -p "$SANDBOX/elsewhere"
	run cfg_find_conf "$SANDBOX/elsewhere"
	assert_status 1
	[ -z "$output" ]
}

@test "config: a section has exactly one id, and nothing else addresses it" {
	conf <<-'EOF'
		[target "demo"]
		description = the demo checkout
		find = origin:*/demo.git
		verify = .git
		verify = package.json

		[setup "hooks"]
		run = scripts/hooks.sh
	EOF
	assert_no_errors
	# the documented encoding (SPEC 9.1): defaults, target:<name>, setup:<name>
	run cfg_get "target:demo" description
	[ "$output" = "the demo checkout" ]
	run cfg_get_all "target:demo" find
	[ "$output" = "origin:*/demo.git" ]
	run cfg_get "setup:hooks" run
	[ "$output" = "scripts/hooks.sh" ]
	# no second spelling is tolerated - callers use the named readers instead
	run cfg_get 'target "demo"' description
	[ -z "$output" ]
	run cfg_get_all "target.demo" find
	[ -z "$output" ]
}

@test "config: cfg_target_verifies reads verify by target name, in order" {
	conf <<-'EOF'
		[target "demo"]
		find = origin:*/demo.git
		verify = .git
		verify = package.json

		[target "bare"]
		find = origin:*/bare.git
	EOF
	assert_no_errors
	run cfg_target_verifies demo
	[ "${#lines[@]}" -eq 2 ]
	[ "${lines[0]}" = ".git" ]
	[ "${lines[1]}" = "package.json" ]
	# a target without a verify key yields nothing, not an error
	run cfg_target_verifies bare
	assert_status 0
	[ -z "$output" ]
	run cfg_target_verifies nosuchtarget
	assert_status 0
	[ -z "$output" ]
}

# --- lexical errors ----------------------------------------------------------

@test "config: an unknown key is reported with a typo suggestion" {
	conf <<-'EOF'
		[target "demo"]
		linkk = github -> .github
	EOF
	[ "$rc" -eq 2 ]
	assert_error "graft.conf:2: unknown key 'linkk' in section [target \"demo\"]"
	assert_error "Did you mean 'link'?"
}

@test "config: an unknown section type is reported with a typo suggestion" {
	conf <<-'EOF'
		[targets "demo"]
		find = origin:*/demo.git
	EOF
	[ "$rc" -eq 2 ]
	assert_error "graft.conf:1: unknown section type 'targets'"
	assert_error "Did you mean 'target'?"
	# the keys below a broken header are swallowed, not blamed twice
	run cfg_print_errors
	[ "$(printf '%s\n' "$output" | grep -c 'graft.conf:')" -eq 1 ]
}

@test "config: an unterminated section header is reported" {
	conf <<-'EOF'
		[target "demo"
		find = origin:*/demo.git
	EOF
	assert_error "graft.conf:1: malformed section header"
	assert_error 'write [defaults], [target "name"] or [setup "name"]'
}

@test "config: a key outside any section is reported" {
	conf <<-'EOF'
		source_root = projects

		[defaults]
	EOF
	assert_error "graft.conf:1: key 'source_root' sits outside any section"
}

@test "config: a line that is neither a header nor key = value is reported" {
	conf <<-'EOF'
		[defaults]
		this line has no equals sign
	EOF
	assert_error 'graft.conf:2: not a section header and not a "key = value" line'
}

@test "config: an upper case key is rejected" {
	conf <<-'EOF'
		[defaults]
		Source_Root = projects
	EOF
	assert_error "graft.conf:2: invalid key name 'Source_Root'"
	assert_error 'keys are lower case'
}

@test "config: a repeated non-repeatable key names both lines" {
	conf <<-'EOF'
		[target "demo"]
		source = one
		find = origin:*/demo.git
		source = two
	EOF
	assert_error "graft.conf:4: key 'source' may appear only once per section (first used on line 2)"
}

@test "config: a duplicate target name names both lines" {
	conf <<-'EOF'
		[target "demo"]
		find = origin:*/demo.git

		[target "demo"]
		find = dir:*/demo
	EOF
	assert_error "graft.conf:4: duplicate target name 'demo' (first defined on line 1)"
	run cfg_targets
	[ "$output" = "demo" ]
}

@test "config: an invalid target name is rejected" {
	conf <<-'EOF'
		[target "demo project"]
		find = origin:*/demo.git
	EOF
	assert_error "invalid target name 'demo project'"
}

@test "config: a blank or slashed section name is rejected" {
	conf <<-'EOF'
		[target "a/b"]
		find = origin:*/demo.git
	EOF
	assert_error "invalid section name 'a/b'"
	assert_error 'must not contain a quote, a backslash or a slash'
}

# --- value domains -----------------------------------------------------------

@test "config: an invalid enum value is reported with a suggestion" {
	conf <<-'EOF'
		[defaults]
		backup = timstamp
		on_foreign_link = abrt
		require = maybe
	EOF
	assert_error "graft.conf:2: invalid value 'timstamp' for 'backup'"
	assert_error "allowed: suffix, timestamp, abort. Did you mean 'timestamp'?"
	assert_error "graft.conf:3: invalid value 'abrt' for 'on_foreign_link'"
	assert_error "Did you mean 'abort'?"
	assert_error "graft.conf:4: invalid value 'maybe' for 'require'"
}

@test "config: search_depth must be a whole number from 1 to 10" {
	conf <<-'EOF'
		[defaults]
		search_depth = 42

		[target "demo"]
		find = origin:*/demo.git
	EOF
	assert_error "graft.conf:2: search_depth 42 is out of range"
	assert_error 'write a whole number between 1 and 10'

	conf <<-'EOF'
		[defaults]
		search_depth = deep
	EOF
	assert_error "graft.conf:2: invalid value 'deep' for 'search_depth'"
}

@test "config: an empty value is reported with the key that needs one" {
	conf <<-'EOF'
		[target "demo"]
		description =
	EOF
	assert_error "graft.conf:2: key 'description' needs a value"
	assert_error 'write: description = <value>'
}

# --- link specs --------------------------------------------------------------

@test "config: a link without an arrow is reported" {
	conf <<-'EOF'
		[target "demo"]
		link = github .github
	EOF
	assert_error "graft.conf:2: invalid link value 'github .github'"
	assert_error 'write: link = <source-path> -> <dest-path>'
}

@test "config: an absolute link destination is refused" {
	conf <<-'EOF'
		[target "demo"]
		link = github -> /etc/profile.d
	EOF
	assert_error "link destination '/etc/profile.d' must be relative to the checkout root"
}

@test "config: a link destination with .. is refused" {
	conf <<-'EOF'
		[target "demo"]
		link = github -> ../../elsewhere
	EOF
	assert_error "link destination '../../elsewhere' must not contain a '..' segment"
}

@test "config: a link destination in ~ is refused" {
	conf <<-'EOF'
		[target "demo"]
		link = github -> ~/.github
	EOF
	assert_error "link destination '~/.github' must be relative to the checkout root"
}

@test "config: .git and everything below it is refused as a destination" {
	conf <<-'EOF'
		[target "demo"]
		link = github -> .git
		link = hooks -> .git/hooks
	EOF
	assert_error "graft.conf:2: link destination '.git' would write into the git directory"
	assert_error "graft.conf:3: link destination '.git/hooks' would write into the git directory"
}

@test "config: the deny list covers .ssh and friends" {
	conf <<-'EOF'
		[target "demo"]
		link = keys -> .ssh
		link = keys -> .ssh/config
		link = gh -> .config/gh
		link = rc -> .bashrc
	EOF
	assert_error "link destination '.ssh' is on the deny list (.ssh)"
	assert_error "link destination '.ssh/config' is on the deny list (.ssh)"
	assert_error "link destination '.config/gh' is on the deny list (.config/gh)"
	assert_error "link destination '.bashrc' is on the deny list (.bashrc)"
}

@test "config: repeated slashes do not sneak a destination past the deny list" {
	# ".config//gh" once passed while ".config/gh" was refused: the deny list
	# compared raw strings, so a second slash was all it took. A deny list that
	# only stops people who are not trying is not a deny list.
	# One entry per target: three spellings of the same path collapse to one
	# destination, and the duplicate-destination rule would mask the rest.
	conf <<-'EOF'
		[target "a"]
		link = gh -> .config//gh
		[target "b"]
		link = gh -> .config///gh
		[target "c"]
		link = keys -> .ssh//config
		[target "d"]
		link = h -> .//.config//gh
	EOF
	assert_error "link destination '.config//gh' is on the deny list (.config/gh)"
	assert_error "link destination '.config///gh' is on the deny list (.config/gh)"
	assert_error "link destination '.ssh//config' is on the deny list (.ssh)"
	assert_error "link destination './/.config//gh' is on the deny list (.config/gh)"
}

@test "config: repeated slashes in an ordinary destination stay allowed" {
	conf <<-'EOF'
		[target "demo"]
		link = github -> .github//sub
	EOF
	[ "$rc" = 0 ]
}

@test "config: a link source that escapes the context repo is refused" {
	conf <<-'EOF'
		[target "demo"]
		link = ../../etc -> .github
	EOF
	assert_error "link source '../../etc' must not contain a '..' segment"
	run cfg_target_links demo
	[ -z "$output" ]
}

@test "config: two links in one target may not share a destination" {
	conf <<-'EOF'
		[target "demo"]
		link = github -> .github
		link = other -> .github/
	EOF
	assert_error "graft.conf:3: duplicate link destination '.github' in [target \"demo\"] (first used on line 2)"
}

@test "config: cfg_target_links inherits defaults and resolves sources" {
	conf <<-'EOF'
		[defaults]
		source_root = projects
		link = github -> .github

		[target "demo"]
		link = github/copilot-instructions.md -> .cursor/rules/main.md
	EOF
	assert_no_errors
	run cfg_target_links demo
	assert_status 0
	[ "${lines[0]}" = "$CTX/projects/demo/github	.github" ]
	[ "${lines[1]}" = "$CTX/projects/demo/github/copilot-instructions.md	.cursor/rules/main.md" ]
}

@test "config: !dest removes an inherited link, a repeat overrides it" {
	conf <<-'EOF'
		[defaults]
		source_root = projects
		link = github -> .github
		link = agents -> .claude

		[target "demo"]
		link = !.claude

		[target "other"]
		source = demo
		link = agents -> .github
	EOF
	assert_no_errors
	run cfg_target_links demo
	[ "${#lines[@]}" -eq 1 ]
	[ "${lines[0]}" = "$CTX/projects/demo/github	.github" ]

	# .claude is inherited untouched, .github is replaced by the target's own
	run cfg_target_links other
	[ "${#lines[@]}" -eq 2 ]
	[ "${lines[0]}" = "$CTX/projects/demo/agents	.claude" ]
	[ "${lines[1]}" = "$CTX/projects/demo/agents	.github" ]
}

# --- find strategies ---------------------------------------------------------

@test "config: an unknown find strategy is reported with a suggestion" {
	conf <<-'EOF'
		[target "demo"]
		find = orgin:*/demo.git
	EOF
	assert_error "graft.conf:2: unknown find strategy 'orgin'"
	assert_error "Did you mean 'origin'?"
}

@test "config: ask: is refused with the --path invocation instead" {
	conf <<-'EOF'
		[target "demo"]
		find = ask:where is it
	EOF
	assert_error "find strategy 'ask' does not exist"
	assert_error 'graft --path <target>=DIR'
}

@test "config: find target: must name a defined target" {
	conf <<-'EOF'
		[target "demo"]
		find = origin:*/demo.git

		[target "other"]
		find = target:demoo
		find = parent-of:dir:*/nested
	EOF
	assert_error "graft.conf:5: find target 'demoo' is not a defined target"
	assert_error "Did you mean 'demo'?"
	run cfg_target_finds other
	[ "${lines[1]}" = "parent-of:dir:*/nested" ]
}

@test "config: find target: a valid reference is accepted under pipefail" {
	# Regression: bin/graft runs under `set -euo pipefail`. The membership test
	# used to be `cfg_targets | grep -qx`; grep -q closes the pipe on its first
	# match, cfg_targets dies of SIGPIPE, and pipefail turned that *hit* into a
	# failure - so every target that was not the last one listed was rejected
	# with "is not a defined target ... Did you mean '<that same name>'?".
	set -o pipefail
	conf <<-'EOF'
		[target "web-app"]
		find = origin:*/web-app

		[target "workspace"]
		find = parent-of:target:web-app
	EOF
	assert_no_errors
	[ "$rc" -eq 0 ]
}

@test "config: find target: every position in the target list is accepted" {
	set -o pipefail
	conf <<-'EOF'
		[target "first"]
		find = origin:*/first

		[target "middle"]
		find = origin:*/middle

		[target "last"]
		find = origin:*/last

		[target "user"]
		find = target:first
		find = target:middle
		find = target:last
	EOF
	assert_no_errors
	[ "$rc" -eq 0 ]
}

@test "config: parent-of accepts every inner strategy" {
	set -o pipefail
	export GRAFT_TEST_ROOT="$SANDBOX/checkouts"
	conf <<-'EOF'
		[target "web-app"]
		find = origin:*/web-app

		[target "workspace"]
		find = parent-of:origin:*/acme/api
		find = parent-of:origin-re:^https://host/acme/api$
		find = parent-of:path:${GRAFT_TEST_ROOT}/mono/services/api
		find = parent-of:env:GRAFT_TEST_DIR
		find = parent-of:dir:*/services/api
		find = parent-of:target:web-app
		find = parent-of:parent-of:origin:*/acme/api
	EOF
	assert_no_errors
	[ "$rc" -eq 0 ]
	run cfg_target_finds workspace
	[ "${#lines[@]}" -eq 7 ]
	# only path: and env: arguments expand, and they expand through parent-of
	[ "${lines[2]}" = "parent-of:path:$SANDBOX/checkouts/mono/services/api" ]
	[ "${lines[5]}" = "parent-of:target:web-app" ]
	[ "${lines[6]}" = "parent-of:parent-of:origin:*/acme/api" ]
}

@test "config: parent-of validates the inner strategy rather than trusting it" {
	set -o pipefail
	conf <<-'EOF'
		[target "demo"]
		find = origin:*/demo

		[target "workspace"]
		find = parent-of:orgin:*/demo
		find = parent-of:target:nosuch
		find = parent-of:path:relative/dir
		find = parent-of:
	EOF
	assert_error "unknown find strategy 'orgin'"
	assert_error "Did you mean 'origin'?"
	assert_error "find target 'nosuch' is not a defined target"
	assert_error "find path argument 'relative/dir' is not absolute"
	assert_error "find strategy 'parent-of' needs an argument"
}

@test "config: parent-of nested past the limit is refused with a reason" {
	set -o pipefail
	conf <<-'EOF'
		[target "demo"]
		find = parent-of:parent-of:parent-of:parent-of:parent-of:origin:*/demo
	EOF
	assert_error "find parent-of is nested too deeply"
	assert_error "nest at most four strategies"
}

@test "config: find target: naming its own target is refused" {
	set -o pipefail
	conf <<-'EOF'
		[target "demo"]
		find = target:demo
	EOF
	assert_error "find target 'demo' refers to its own target"
	assert_error 'point it at a different target'
}

@test "config: a broken origin-re is caught before discovery runs" {
	conf <<-'EOF'
		[target "demo"]
		find = origin-re:[unclosed
	EOF
	assert_error "invalid regular expression in find origin-re: '[unclosed'"
}

@test "config: a find path argument must be absolute" {
	conf <<-'EOF'
		[target "demo"]
		find = path:relative/dir
	EOF
	assert_error "find path argument 'relative/dir' is not absolute"
}

# --- expansion ---------------------------------------------------------------

@test "config: a leading ~ becomes \$HOME, \${VAR} only where SPEC 4 allows it" {
	export GRAFT_TEST_ROOT="$SANDBOX/checkouts"
	conf <<-'EOF'
		[defaults]
		search_root = ~/code
		search_root = ${GRAFT_TEST_ROOT}/team
		search_root = ${GRAFT_UNSET_VAR}/team

		[target "demo"]
		find = path:~/code/demo
		find = path:${GRAFT_TEST_ROOT}/demo
		find = env:DEMO_DIR
		find = origin:${GRAFT_TEST_ROOT}
	EOF
	assert_no_errors
	run cfg_get_all defaults search_root
	[ "${lines[0]}" = "$HOME/code" ]
	[ "${lines[1]}" = "$SANDBOX/checkouts/team" ]
	[ "${lines[2]}" = "/team" ]

	run cfg_target_finds demo
	[ "${lines[0]}" = "path:$HOME/code/demo" ]
	[ "${lines[1]}" = "path:$SANDBOX/checkouts/demo" ]
	[ "${lines[2]}" = "env:DEMO_DIR" ]
	# origin globs are matched against a URL, so nothing is expanded there
	[ "${lines[3]}" = 'origin:${GRAFT_TEST_ROOT}' ]
}

@test "config: \${VAR} stays literal inside a link value" {
	export GRAFT_TEST_ROOT="$SANDBOX/checkouts"
	conf <<-'EOF'
		[target "demo"]
		link = ${GRAFT_TEST_ROOT} -> .github
	EOF
	assert_no_errors
	run cfg_get "target:demo" link
	[ "$output" = '${GRAFT_TEST_ROOT} -> .github' ]
	run cfg_target_links demo
	[ "${lines[0]}" = "$CTX/demo/\${GRAFT_TEST_ROOT}	.github" ]
}

@test "config: I1 - nothing in the file is ever executed" {
	conf <<-'EOF'
		[target "demo"]
		description = $(touch pwned-sub) `touch pwned-tick` $((1+1)) ${HOME}
		find = origin:$(touch pwned-find)
		link = github -> .github
	EOF
	assert_no_errors
	assert_not_exists "$SANDBOX/pwned-sub"
	assert_not_exists "$SANDBOX/pwned-tick"
	assert_not_exists "$SANDBOX/pwned-find"
	assert_not_exists "$CTX/pwned-sub"
	run cfg_get "target:demo" description
	[ "$output" = '$(touch pwned-sub) `touch pwned-tick` $((1+1)) ${HOME}' ]
}

# --- lexical details ---------------------------------------------------------

@test "config: CRLF line endings are tolerated" {
	printf '[defaults]\r\nsource_root = projects\r\n\r\n[target "demo"]\r\nlink = github -> .github\r\n' \
		>"$CTX/graft.conf"
	rc=0
	cfg_load "$CTX/graft.conf" || rc=$?
	assert_no_errors
	[ "$rc" -eq 0 ]
	run cfg_get defaults source_root
	[ "$output" = "projects" ]
	run cfg_target_links demo
	[ "${lines[0]}" = "$CTX/projects/demo/github	.github" ]
}

@test "config: a tab or a backslash inside a value survives the TSV round trip" {
	# CFG_DATA is tab separated, so both characters have to be escaped and
	# decoded again in the right order.
	printf '[target "demo"]\ndescription = a\tb \\ c \\\\t d\n' >"$CTX/graft.conf"
	rc=0
	cfg_load "$CTX/graft.conf" || rc=$?
	assert_no_errors
	run cfg_get "target:demo" description
	[ "$output" = "$(printf 'a\tb \\ c \\\\t d')" ]
}

@test "config: a value keeps its spaces and its # (no trailing comments)" {
	conf <<-'EOF'
		[target "demo"]
		description =   two  spaces and a # hash
		link = github -> .github
	EOF
	assert_no_errors
	run cfg_get "target:demo" description
	[ "$output" = "two  spaces and a # hash" ]
}

@test "config: paths with spaces, umlauts and dollar signs survive (P6)" {
	local ctx="$SANDBOX/my ctx"
	mkdir -p "$ctx"
	CTX="$ctx"
	conf <<-'EOF'
		[defaults]
		source_root = quell verzeichnis

		[target "demo"]
		source = grüße $euro
		link = . -> .github
	EOF
	assert_no_errors
	run cfg_target_links demo
	[ "${lines[0]}" = "$ctx/quell verzeichnis/grüße \$euro	.github" ]
}

@test "config: comments and blank lines are ignored" {
	conf <<-'EOF'
		# a hash comment
		; a semicolon comment

		[defaults]
		  # indented comment
		source_root = projects
	EOF
	assert_no_errors
	run cfg_get defaults source_root
	[ "$output" = "projects" ]
}

# --- error collection --------------------------------------------------------

@test "config: every error is collected, not just the first" {
	conf <<-'EOF'
		[defaults]
		backup = nope
		search_depth = 0

		[target "demo"]
		link = github -> /absolute
		find = orgin:x
	EOF
	cfg_validate || n=$?
	[ "$n" -eq 4 ]
	assert_error "graft.conf:2:"
	assert_error "graft.conf:3:"
	assert_error "graft.conf:6:"
	assert_error "graft.conf:7:"
}

@test "config: the reported error count is capped at 250" {
	# One awk call, not a shell loop: bats traces every command in a test body.
	awk 'BEGIN { print "[defaults]"
		for (i = 1; i <= 260; i++) printf "bogus_key_%d = x\n", i }' >"$CTX/graft.conf"
	# Through `run`, which turns bats' per command tracing off for the call.
	run load_and_validate
	assert_status 250
	run load_only
	assert_status 2
}

@test "config: errors are rendered with line, hint and the offending line" {
	conf <<-'EOF'
		[defaults]
		backup = nope
	EOF
	run cfg_print_errors
	assert_output_contains "graft.conf:2: invalid value 'nope' for 'backup'"
	assert_output_contains "allowed: suffix, timestamp, abort"
	assert_output_contains "2 | backup = nope"
}

@test "config: a setup without run is reported, a complete one is listed" {
	conf <<-'EOF'
		[setup "hooks"]
		description = install the git hooks
	EOF
	assert_error "section [setup \"hooks\"] has no 'run' key"
	assert_error 'add: run = <path relative to source_root>'
}

@test "config: a run path with shell metacharacters is refused" {
	conf <<-'EOF'
		[setup "hooks"]
		run = scripts/hooks.sh; rm -rf /
	EOF
	assert_error "contains shell metacharacters or whitespace"
}

@test "config: source_root and source may not leave the context repo" {
	conf <<-'EOF'
		[defaults]
		source_root = ../outside

		[target "demo"]
		source = ../../etc
	EOF
	assert_error "source_root '../outside' resolves outside the context repo"
	assert_error "source '../../etc' resolves outside the source root"
}

@test "config: a missing config file returns 2 and never exits" {
	rc=0
	cfg_load "$CTX/does-not-exist.conf" || rc=$?
	[ "$rc" -eq 2 ]
	assert_error "cannot read config file:"
	assert_error 'create one with: graft init'
}

@test "config: a dot segment does not sneak a destination past the deny list" {
	conf <<-'EOF'
		[target "a"]
		link = gh -> .config/./gh
		[target "b"]
		link = k -> .ssh/./config
	EOF
	assert_error "link destination '.config/./gh' is on the deny list (.config/gh)"
	assert_error "link destination '.ssh/./config' is on the deny list (.ssh)"
}

@test "config: a tab in a link destination is refused" {
	# A tab shifted the fields of the internal plan record, so --dry-run planned
	# one path and link then did nothing at all.
	printf '[target "a"]\nlink = gh -> a\tb\n' >"$CTX/graft.conf"
	rc=0
	cfg_load "$CTX/graft.conf" || rc=$?
	[ "$rc" != 0 ]
	assert_error "contains a tab"
}
