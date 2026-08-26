# shellcheck shell=bash
#
# plan.sh - turn configuration plus discovery into a plan, then execute it.
#
# Everything mutating goes through here, and everything here builds a complete
# plan before touching anything (invariant I6). That is what makes --dry-run
# trustworthy rather than a second, subtly different code path.

# PLAN_DATA holds one TSV record per intended action:
#   target \t checkout \t src \t dest_rel \t dest_abs \t action \t detail
PLAN_DATA=""

# Set once the plan has been displayed for confirmation, so that executing it
# reports outcomes instead of repeating the same list back at the user.
PLAN_SHOWN=0

# --- helpers -----------------------------------------------------------------

# Which targets this invocation is about: the ones named on the command line,
# or all of them. An unknown name is a usage error, not a silent no-op - a typo
# that quietly does nothing is how people conclude the tool is broken.
plan_selected_targets() {
	local all named t found
	all=$(cfg_targets)
	named=$(printf '%s' "$GRAFT_ARGS" | grep -v '^$' || true)
	if [ -z "$named" ]; then
		printf '%s\n' "$all"
		return 0
	fi
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		found=0
		while IFS= read -r a; do
			[ "$a" = "$t" ] && found=1
		done <<EOF
$all
EOF
		if [ "$found" = 0 ]; then
			gr_err "no target named '$(gr_clean "$t")' in $(gr_clean "$CFG_FILE")"
			gr_hint "configured targets: $(printf '%s' "$all" | tr '\n' ' ')"
			return 1
		fi
		printf '%s\n' "$t"
	done <<EOF
$named
EOF
}

# --only filters on the destination's basename, because that is the name people
# actually think in: "just the .claude links".
plan_only_matches() {
	local dest_rel="$1" base want
	[ -z "$GRAFT_ONLY" ] && return 0
	base=$(basename -- "$dest_rel")
	while IFS= read -r want; do
		[ -n "$want" ] || continue
		[ "$want" = "$base" ] && return 0
		[ "$want" = "$dest_rel" ] && return 0
	done <<EOF
$GRAFT_ONLY
EOF
	return 1
}

plan_apply_pins() {
	local pin name dir
	while IFS= read -r pin; do
		[ -n "$pin" ] || continue
		case "$pin" in
		*=*) ;;
		*)
			gr_err "--path expects NAME=DIR, got '$(gr_clean "$pin")'"
			return 1
			;;
		esac
		name="${pin%%=*}"
		dir=$(gr_abspath "${pin#*=}")
		if [ ! -d "$dir" ]; then
			gr_err "--path $(gr_clean "$name"): no such directory: $(gr_clean "$dir")"
			return 1
		fi
		disc_pin "$name" "$dir"
	done <<EOF
$GRAFT_PINS
EOF
}

plan_record() {
	PLAN_DATA="$PLAN_DATA$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7")"$'\n'
}

plan_field() { printf '%s' "$1" | cut -d"$(printf '\t')" -f"$2"; }

# Unpack a plan record into PF1..PF7.
#
# We do NOT use `IFS=<tab>; set -- $rec` for this. Tab belongs to IFS's
# whitespace class, so runs of tabs collapse and every empty field silently
# disappears - a record for a target with no checkout arrives with its fields
# shifted left. Parameter expansion has no such rule, and costs no forks.
plan_unpack() {
	local rec="$1" t
	t=$(printf '\t')
	PF1=${rec%%"$t"*} rec=${rec#*"$t"}
	PF2=${rec%%"$t"*} rec=${rec#*"$t"}
	PF3=${rec%%"$t"*} rec=${rec#*"$t"}
	PF4=${rec%%"$t"*} rec=${rec#*"$t"}
	PF5=${rec%%"$t"*} rec=${rec#*"$t"}
	PF6=${rec%%"$t"*} rec=${rec#*"$t"}
	PF7=$rec
}

# --- building -----------------------------------------------------------------

plan_build() {
	PLAN_DATA=""
	local targets t checkout rc spec src dest_rel dest_abs action detail

	targets=$(plan_selected_targets) || return 2
	plan_apply_pins || return 2
	disc_index_load || true

	while IFS= read -r t; do
		[ -n "$t" ] || continue

		checkout=""
		detail=""
		if checkout=$(disc_resolve "$t" 2>/dev/null); then
			rc=0
		else
			rc=$?
		fi
		if [ "$rc" -eq 2 ]; then
			plan_record "$t" "" "" "" "" "ambiguous" \
				"$(printf '%s' "$checkout" | tr '\n' ' ')"
			continue
		fi
		if [ "$rc" -ne 0 ] || [ -z "$checkout" ]; then
			plan_record "$t" "" "" "" "" "no-checkout" \
				"$(cfg_target_get "$t" require no)"
			continue
		fi

		while IFS= read -r spec; do
			[ -n "$spec" ] || continue
			src=${spec%%	*}
			dest_rel=${spec#*	}
			plan_only_matches "$dest_rel" || continue
			dest_abs="$checkout/$dest_rel"

			if [ ! -e "$src" ] && [ ! -L "$src" ]; then
				plan_record "$t" "$checkout" "$src" "$dest_rel" "$dest_abs" \
					"missing-source" ""
				continue
			fi
			if ap_is_tracked "$checkout" "$dest_rel"; then
				plan_record "$t" "$checkout" "$src" "$dest_rel" "$dest_abs" \
					"tracked" ""
				continue
			fi
			action=$(ap_dest_state "$dest_abs" "$src" "$CFG_CTX_ROOT")
			plan_record "$t" "$checkout" "$src" "$dest_rel" "$dest_abs" \
				"$action" ""
		done <<EOF
$(cfg_target_links "$t")
EOF
	done <<EOF
$targets
EOF
	return 0
}

# --- rendering ----------------------------------------------------------------

# One line per action. The destination is shown relative to $HOME because that
# is how people recognise their own checkouts, and the full path is available in
# --json for anything that needs to consume it.
plan_short_path() {
	# The tilde here is literal display text, not a path to be expanded.
	# shellcheck disable=SC2088
	case "$1" in
	"$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
	*) printf '%s' "$1" ;;
	esac
}

plan_render_line() {
	local t="$1" dest_abs="$5" action="$6" detail="$7" dest_rel="$4" where
	where=$(gr_clean "$(plan_short_path "$dest_abs")")
	case "$action" in
	absent) gr_add "$where  ($t)" ;;
	unchanged) gr_ok "$where  ($t)" ;;
	repair) gr_fix "$where  repointed  ($t)" ;;
	backup-dir) gr_add "$where  existing directory backed up  ($t)" ;;
	backup-file) gr_add "$where  existing file backed up  ($t)" ;;
	foreign) gr_warn "$where  foreign symlink, left alone  ($t)" ;;
	tracked) gr_warn "$where  tracked by git, refused  ($t)" ;;
	mountpoint) gr_warn "$where  is a mount point, refused  ($t)" ;;
	missing-source) gr_warn "$t: source is missing: $(gr_clean "$3")" ;;
	no-checkout)
		if [ "$detail" = yes ]; then
			gr_warn "$t: no checkout found (required)"
		else
			gr_skip "$t: no checkout found"
		fi
		;;
	ambiguous) gr_warn "$t: several checkouts match: $(gr_clean "$detail")" ;;
	*) gr_skip "$where  $action  ($t)" ;;
	esac
}

plan_render_json_line() {
	printf '{"target":"%s","checkout":"%s","source":"%s","dest":"%s","action":"%s","detail":"%s"}\n' \
		"$(gr_json_escape "$1")" "$(gr_json_escape "$2")" "$(gr_json_escape "$3")" \
		"$(gr_json_escape "$5")" "$(gr_json_escape "$6")" "$(gr_json_escape "$7")"
}

# Actions that would change something on disk.
plan_is_change() {
	case "$1" in
	absent | repair | backup-dir | backup-file) return 0 ;;
	esac
	return 1
}

# Actions the user has to do something about.
plan_is_problem() {
	case "$1" in
	foreign | tracked | mountpoint | missing-source | ambiguous) return 0 ;;
	no-checkout) [ "$2" = yes ] && return 0 ;;
	esac
	return 1
}

plan_counts() {
	PLAN_N_CHANGE=0 PLAN_N_OK=0 PLAN_N_PROBLEM=0 PLAN_N_SKIP=0
	local rec action detail
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		action=$(plan_field "$rec" 6)
		detail=$(plan_field "$rec" 7)
		if plan_is_change "$action"; then
			PLAN_N_CHANGE=$((PLAN_N_CHANGE + 1))
		elif [ "$action" = unchanged ]; then
			PLAN_N_OK=$((PLAN_N_OK + 1))
		elif plan_is_problem "$action" "$detail"; then
			PLAN_N_PROBLEM=$((PLAN_N_PROBLEM + 1))
		else
			PLAN_N_SKIP=$((PLAN_N_SKIP + 1))
		fi
	done <<EOF
$PLAN_DATA
EOF
}

plan_render() {
	local rec
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		plan_unpack "$rec"
		if [ "$GRAFT_JSON" = 1 ]; then
			plan_render_json_line "$PF1" "$PF2" "$PF3" "$PF4" "$PF5" "$PF6" "$PF7"
		else
			plan_render_line "$PF1" "$PF2" "$PF3" "$PF4" "$PF5" "$PF6" "$PF7"
		fi
	done <<EOF
$PLAN_DATA
EOF
}

# --- commands -----------------------------------------------------------------

plan_first_run() {
	[ ! -f "$(st_state_path "$CFG_FILE")" ]
}

plan_cmd_link() {
	plan_build || return "$GRAFT_EX_USAGE"
	plan_counts

	if [ "$GRAFT_DRY_RUN" = 1 ]; then
		[ "$GRAFT_JSON" = 1 ] || gr_bold "plan (nothing will be changed)"
		plan_render
		plan_summary_line "would"
		[ "$PLAN_N_PROBLEM" -gt 0 ] && return "$GRAFT_EX_DRIFT"
		return 0
	fi

	# Nothing to do is the common case after the first run, so it gets exactly
	# one line. A tool that is chatty when idle trains people to stop reading it,
	# and then they miss the run that mattered.
	if [ "$PLAN_N_CHANGE" = 0 ] && [ "$PLAN_N_PROBLEM" = 0 ]; then
		[ "$GRAFT_JSON" = 1 ] && plan_render
		gr_say "$C_GREEN$G_OK$C_RESET $PLAN_N_OK links up to date, nothing to do"
		return 0
	fi

	if [ "$PLAN_N_CHANGE" -gt 0 ] && plan_first_run; then
		[ "$GRAFT_JSON" = 1 ] || gr_bold "plan"
		plan_render
		PLAN_SHOWN=1
		if ! gr_confirm "apply $PLAN_N_CHANGE change(s)?"; then
			if [ "$GRAFT_NO_INPUT" = 1 ]; then
				gr_err "changes needed but not confirmed"
				gr_hint "re-run with --yes, or interactively"
				return "$GRAFT_EX_UNCONFIRMED"
			fi
			gr_say "aborted, nothing was changed"
			return "$GRAFT_EX_UNCONFIRMED"
		fi
	fi

	plan_execute
	plan_counts
	if [ "$PLAN_SHOWN" = 1 ] && [ "$GRAFT_JSON" != 1 ]; then
		gr_say ""
		gr_ok "$PLAN_R_DONE link(s) in place"
	fi
	plan_summary_line "did"
	plan_print_setup_notes
	[ "$PLAN_N_PROBLEM" -gt 0 ] && return "$GRAFT_EX_DRIFT"
	return 0
}

plan_execute() {
	local rec t checkout src dest_rel dest_abs action result
	local backup exclude foreign
	PLAN_R_DONE=0 PLAN_R_FAILED=0
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		t=$(plan_field "$rec" 1)
		checkout=$(plan_field "$rec" 2)
		src=$(plan_field "$rec" 3)
		dest_rel=$(plan_field "$rec" 4)
		dest_abs=$(plan_field "$rec" 5)
		action=$(plan_field "$rec" 6)

		if plan_is_problem "$action" "$(plan_field "$rec" 7)"; then
			[ "$PLAN_SHOWN" = 1 ] || plan_render_line "$t" "$checkout" "$src" \
				"$dest_rel" "$dest_abs" "$action" "$(plan_field "$rec" 7)"
			continue
		fi
		plan_is_change "$action" || {
			if [ "$action" = unchanged ] && [ "$PLAN_SHOWN" = 0 ]; then
				gr_ok "$(gr_clean "$(plan_short_path "$dest_abs")")  ($t)"
			fi
			continue
		}

		backup=$(cfg_target_get "$t" backup timestamp)
		exclude=$(cfg_target_get "$t" git_exclude yes)
		foreign=$(cfg_target_get "$t" on_foreign_link warn)
		[ "$GRAFT_FORCE" = 1 ] && foreign=replace

		# Called directly, not through $(...): a command substitution would run
		# ap_link in a subshell and throw away every state record it writes.
		AP_RESULT=""
		if ap_link "$t" "$checkout" "$src" "$dest_rel" \
			"$backup" "$exclude" "$foreign" >/dev/null; then
			result="$AP_RESULT"
			PLAN_R_DONE=$((PLAN_R_DONE + 1))
			[ "$PLAN_SHOWN" = 1 ] && continue
			case "$result" in
			created) gr_add "$(gr_clean "$(plan_short_path "$dest_abs")")  ($t)" ;;
			repaired) gr_fix "$(gr_clean "$(plan_short_path "$dest_abs")")  repointed  ($t)" ;;
			backed-up) gr_add "$(gr_clean "$(plan_short_path "$dest_abs")")  existing content backed up  ($t)" ;;
			*) gr_skip "$(gr_clean "$(plan_short_path "$dest_abs")")  $result  ($t)" ;;
			esac
		else
			PLAN_R_FAILED=$((PLAN_R_FAILED + 1))
			gr_warn "$(gr_clean "$(plan_short_path "$dest_abs")")  failed  ($t)"
		fi
	done <<EOF
$PLAN_DATA
EOF
	st_save
}

plan_summary_line() {
	local verb="$1"
	[ "$GRAFT_JSON" = 1 ] && {
		printf '{"summary":{"changed":%s,"unchanged":%s,"problems":%s,"skipped":%s}}\n' \
			"$PLAN_N_CHANGE" "$PLAN_N_OK" "$PLAN_N_PROBLEM" "$PLAN_N_SKIP"
		return 0
	}
	if [ "$PLAN_N_PROBLEM" -gt 0 ]; then
		gr_say ""
		gr_say "$PLAN_N_CHANGE $verb change, $PLAN_N_OK already correct, $PLAN_N_PROBLEM need attention"
	fi
	return 0
}

# Setup notes are printed, never executed (invariant I1). The user reads the
# command and decides. graft does not get to run code that arrived by git pull.
plan_print_setup_notes() {
	local line name desc run
	[ "$GRAFT_JSON" = 1 ] && return 0
	line=$(cfg_setups)
	[ -n "$line" ] || return 0
	gr_say ""
	gr_bold "next steps (graft never runs these for you)"
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		name=$(printf '%s' "$line" | cut -f1)
		desc=$(printf '%s' "$line" | cut -f2)
		run=$(printf '%s' "$line" | cut -f3)
		gr_dim "  $(gr_clean "$desc")"
		gr_say "      $(gr_clean "$CFG_SOURCE_ROOT/$run")"
	done <<EOF
$(cfg_setups)
EOF
}

plan_cmd_status() {
	plan_build || return "$GRAFT_EX_USAGE"
	plan_counts
	if [ "$GRAFT_JSON" != 1 ]; then
		gr_bold "context: $(gr_clean "$CFG_CTX_ROOT")"
	fi
	plan_render
	plan_summary_line "pending"
	[ "$PLAN_N_PROBLEM" -gt 0 ] && return "$GRAFT_EX_DRIFT"
	[ "$PLAN_N_CHANGE" -gt 0 ] && return "$GRAFT_EX_DRIFT"
	return 0
}

plan_cmd_unlink() {
	local rec targets t where n=0
	targets=$(plan_selected_targets) || return "$GRAFT_EX_USAGE"
	st_load
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		while IFS= read -r rec; do
			[ -n "$rec" ] || continue
			if [ "$GRAFT_DRY_RUN" = 1 ]; then
				gr_skip "would remove $(gr_clean "$(plan_short_path "$(plan_field "$rec" 3)")")"
				n=$((n + 1))
				continue
			fi
			# Direct call, stdout discarded: same subshell trap as ap_link.
			AP_RESULT=""
			where=$(gr_clean "$(plan_short_path "$(plan_field "$rec" 3)")")
			if ap_unlink_record "$rec" >/dev/null; then
				case "$AP_RESULT" in
				restored)
					gr_ok "$where  link removed, backup restored"
					n=$((n + 1))
					;;
				removed)
					gr_ok "$where  link removed"
					n=$((n + 1))
					;;
				already-gone) gr_skip "$where  was already gone" ;;
				*) gr_skip "$where  $AP_RESULT" ;;
				esac
			else
				gr_warn "$where  left alone ($AP_RESULT)"
			fi
		done <<EOF
$(st_records "$t")
EOF
	done <<EOF
$targets
EOF
	[ "$GRAFT_DRY_RUN" = 1 ] || st_save
	gr_say "$n link(s) removed"
	return 0
}

plan_cmd_adopt() {
	local dir name src
	dir=$(printf '%s' "$GRAFT_ARGS" | grep -v '^$' | head -1 || true)
	name="$GRAFT_ADOPT_AS"
	[ -n "$dir" ] || gr_die "$GRAFT_EX_USAGE" "adopt needs a directory: graft adopt <dir> --as NAME"
	[ -n "$name" ] || gr_die "$GRAFT_EX_USAGE" "adopt needs --as NAME"
	dir=$(gr_abspath "$dir")
	[ -e "$dir" ] || gr_die "$GRAFT_EX_USAGE" "no such path: $(gr_clean "$dir")"
	[ -L "$dir" ] && gr_die "$GRAFT_EX_USAGE" "$(gr_clean "$dir") is already a symlink"

	src="$CFG_SOURCE_ROOT/$name/$(basename -- "$dir")"
	[ -e "$src" ] && gr_die "$GRAFT_EX_USAGE" "already present in the context repo: $(gr_clean "$src")"

	gr_bold "plan"
	gr_say "  move $(gr_clean "$dir")"
	gr_say "    to $(gr_clean "$src")"
	gr_say "  then link it back"
	if [ "$GRAFT_DRY_RUN" = 1 ]; then return 0; fi
	gr_confirm "adopt $(basename -- "$dir") as target '$name'?" || {
		gr_say "aborted"
		return "$GRAFT_EX_UNCONFIRMED"
	}

	mkdir -p -- "$(dirname -- "$src")"
	mv -- "$dir" "$src"
	gr_ok "moved into the context repo"
	gr_say ""
	gr_bold "now do two things"
	gr_say "  1. add a target to $(gr_clean "$CFG_FILE"):"
	gr_say ""
	gr_say "     [target \"$name\"]"
	gr_say "     find = origin:*/$name"
	gr_say "     link = $(basename -- "$dir") -> $(basename -- "$dir")"
	gr_say ""
	gr_say "  2. commit it, then run: graft link"
	return 0
}

plan_cmd_init() {
	local conf="$PWD/graft.conf"
	if [ -e "$conf" ]; then
		gr_err "graft.conf already exists here"
		gr_hint "edit it, or run graft check to validate it"
		return "$GRAFT_EX_USAGE"
	fi
	cat >"$conf" <<'TEMPLATE'
# graft.conf - which shared context goes into which checkout.
#
# Checkouts are located by their git remote URL, not by path, so this file is
# safe to commit and share with the team. Run `graft check` after editing.

[defaults]
# Where the shared context lives, relative to this file.
source_root = projects

# Where to look for checkouts. Narrow this if your home directory is large.
search_root = ~
search_depth = 4

# Links every target inherits. Left of "->" is relative to the target's source
# directory, right of it is relative to the checkout root.
link = github -> .github

[target "example"]
description = replace this with a real project
# First strategy that matches wins. Others: path:, env:, origin-re:, dir:,
# parent-of:, target:
find = origin:*/example
# Extra links, on top of the inherited ones:
# link = claude -> .claude
# link = AGENTS.md -> AGENTS.md

# Reminders printed after a successful link. graft NEVER runs these.
# [setup "mcp"]
# description = install the team MCP servers (needs a personal token)
# run = mcp/install.sh
TEMPLATE
	gr_ok "wrote $(gr_clean "$conf")"
	gr_say ""
	gr_say "next: put your shared context under $(gr_clean "$PWD")/projects/<name>/github/,"
	gr_say "      edit the [target] block, then run: graft check && graft link --dry-run"
	return 0
}
