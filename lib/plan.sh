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

# Candidates for targets that matched more than one checkout, as
# "<target>\t<path>" lines. Kept out of PLAN_DATA because a plan record is one
# line and this is a list.
PLAN_AMBIG=""

# Only `graft link` may ask which checkout to use. `status` and `--dry-run` are
# meant to be safe to run and safe to pipe: a preview that blocks on a question
# is neither.
PLAN_MAY_ASK=0

# status groups its lines by target and prefixes each group with the target's
# description. Everywhere else the (target) suffix on each line is enough.
PLAN_SHOW_DESC=0

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
plan_target_exists() {
	local want="$1" t
	while IFS= read -r t; do
		[ "$t" = "$want" ] && return 0
	done <<EOF
$(cfg_targets)
EOF
	return 1
}

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

# Offer the candidates as a numbered list. Returns the chosen path on stdout,
# or 1 when we must not choose (not a terminal, or the user declined).
plan_choose() {
	local t="$1" cand i=0 pick when origin
	[ "$PLAN_MAY_ASK" = 1 ] || return 1
	[ "$GRAFT_NO_INPUT" = 1 ] && return 1
	gr_tty || return 1
	printf '\n%s%s matches more than one checkout:%s\n' "$C_BOLD" "$t" "$C_RESET" >/dev/tty
	while IFS= read -r cand; do
		[ -n "$cand" ] || continue
		i=$((i + 1))
		when=$(git -C "$cand" log -1 --format=%cr 2>/dev/null) || when=""
		origin=$(disc_info "$cand" 2>/dev/null) || origin=""
		origin=${origin%%	*}
		printf '  %s) %s\n' "$i" "$(gr_clean "$(plan_short_path "$cand")")" >/dev/tty
		printf '     %s%s%s%s\n' "$C_DIM" "$(gr_clean "$origin")" \
			"$([ -n "$when" ] && printf ', last commit %s' "$when")" "$C_RESET" >/dev/tty
	done <<EOF
$(plan_ambig_for "$t")
EOF
	printf '  pick 1-%s, or anything else to skip: ' "$i" >/dev/tty
	IFS= read -r pick </dev/tty || return 1
	case "$pick" in
	'' | *[!0-9]*) return 1 ;;
	esac
	[ "$pick" -ge 1 ] && [ "$pick" -le "$i" ] || return 1
	i=0
	while IFS= read -r cand; do
		[ -n "$cand" ] || continue
		i=$((i + 1))
		if [ "$i" = "$pick" ]; then
			printf '%s\n' "$cand"
			return 0
		fi
	done <<EOF
$(plan_ambig_for "$t")
EOF
	return 1
}

plan_ambig_for() {
	local want="$1" line
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		case "$line" in
		"$want	"*) printf '%s\n' "${line#*	}" ;;
		esac
	done <<EOF
$PLAN_AMBIG
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
	local cand chosen n

	targets=$(plan_selected_targets) || return 2
	plan_apply_pins || return 2
	if [ "$GRAFT_RESCAN" = 1 ]; then
		disc_index_load --rescan || true
	else
		disc_index_load || true
	fi

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
			# Never pick one. Two clones of the same repo are not
			# interchangeable, and the wrong guess gets cached and then quietly
			# repeated on every later run.
			n=0
			while IFS= read -r cand; do
				[ -n "$cand" ] || continue
				n=$((n + 1))
				PLAN_AMBIG="$PLAN_AMBIG$t	$cand"$'\n'
			done <<EOF
$checkout
EOF
			if chosen=$(plan_choose "$t"); then
				checkout="$chosen"
				# The ambiguity is resolved. Without clearing rc the next
				# check still sees 2 and files the target as "no checkout".
				rc=0
				disc_pin "$t" "$chosen"
			else
				plan_record "$t" "" "" "" "" "ambiguous" "$n"
				continue
			fi
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
	tracked)
		gr_warn "$where  tracked by git, refused  ($t)"
		gr_hint "git tracks this path, so a symlink here would commit a deletion."
		gr_hint "move it into the context repo instead: graft adopt $dest_abs --as $t"
		;;
	mountpoint) gr_warn "$where  is a mount point, refused  ($t)" ;;
	missing-source) gr_warn "$t: source is missing: $(gr_clean "$3")" ;;
	no-checkout)
		if [ "$detail" = yes ]; then
			gr_warn "$t: no checkout found (required)"
		else
			gr_skip "$t: no checkout found"
		fi
		plan_explain_no_checkout "$t"
		;;
	ambiguous)
		gr_warn "$t: $detail checkouts match - graft will not pick one for you"
		plan_list_ambig "$t"
		gr_hint "choose one: graft --path $t=<directory>"
		;;
	*) gr_skip "$where  $action  ($t)" ;;
	esac
}

# The most common cause of "no checkout found" is a pattern that cannot match,
# so show the patterns rather than only the verdict.
plan_explain_no_checkout() {
	local t="$1" f
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		gr_hint "tried: $(gr_clean "$f")"
	done <<EOF
$(cfg_target_finds "$t")
EOF
	gr_hint "point at it directly: graft --path $t=<directory>"
}

plan_list_ambig() {
	local t="$1" cand
	while IFS= read -r cand; do
		[ -n "$cand" ] || continue
		gr_hint "$(gr_clean "$(plan_short_path "$cand")")"
	done <<EOF
$(plan_ambig_for "$t")
EOF
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
	foreign) [ "$GRAFT_FORCE" = 1 ] && return 0 ;;
	esac
	return 1
}

# Actions the user has to do something about.
plan_is_problem() {
	case "$1" in
	# With --force a foreign symlink is a change to make, not a problem to
	# report. Tracked paths stay a problem no matter what (invariant I5).
	foreign)
		[ "$GRAFT_FORCE" = 1 ] && return 1
		return 0
		;;
	tracked | mountpoint | missing-source | ambiguous) return 0 ;;
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
	local last_t="" desc
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		plan_unpack "$rec"
		if [ "$PLAN_SHOW_DESC" = 1 ] && [ "$GRAFT_JSON" != 1 ] && [ "$PF1" != "$last_t" ]; then
			last_t="$PF1"
			desc=$(cfg_target_get "$PF1" description "")
			[ -n "$desc" ] && gr_dim "$PF1 - $(gr_clean "$desc")"
		fi
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

# True when some target hit a foreign symlink and asked us to stop for it.
plan_foreign_aborts() {
	local rec t
	[ "$GRAFT_FORCE" = 1 ] && return 1
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		[ "$(plan_field "$rec" 6)" = foreign ] || continue
		t=$(plan_field "$rec" 1)
		[ "$(cfg_target_get "$t" on_foreign_link warn)" = abort ] && return 0
	done <<EOF
$PLAN_DATA
EOF
	return 1
}

# --- confirm = yes -----------------------------------------------------------
#
# Asked once per target, the first time that target would actually change
# something. Answered targets are remembered for the run so a target with four
# links does not ask four times.
PLAN_CONFIRMED=""

plan_target_allowed() {
	local t="$1" line
	[ "$(cfg_target_get "$t" confirm no)" = yes ] || return 0
	while IFS= read -r line; do
		case "$line" in
		"yes	$t") return 0 ;;
		"no	$t") return 1 ;;
		esac
	done <<EOF
$PLAN_CONFIRMED
EOF
	if gr_confirm "apply changes to target '$t'?"; then
		PLAN_CONFIRMED="$PLAN_CONFIRMED"'yes	'"$t"$'\n'
		return 0
	fi
	PLAN_CONFIRMED="$PLAN_CONFIRMED"'no	'"$t"$'\n'
	gr_skip "$t: skipped on request"
	return 1
}

plan_first_run() {
	[ ! -f "$(st_state_path "$CFG_FILE")" ]
}

plan_cmd_link() {
	[ "$GRAFT_DRY_RUN" = 1 ] || PLAN_MAY_ASK=1
	plan_build || return "$GRAFT_EX_USAGE"
	plan_counts

	# "abort" has to mean something other than "warn", or it is a config key
	# that lies. warn reports the foreign link and links everything else;
	# abort refuses the whole run so nothing is half-applied.
	if plan_foreign_aborts; then
		plan_render
		gr_err "a foreign symlink is in the way and on_foreign_link = abort"
		gr_hint "resolve it, or set on_foreign_link = warn, or pass --force"
		return "$GRAFT_EX_DRIFT"
	fi

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
	# The silent one-liner is only honest when there is genuinely nothing left:
	# a skipped target is something the user should hear about exactly once,
	# not something to hide behind a green tick.
	if [ "$PLAN_N_CHANGE" = 0 ] && [ "$PLAN_N_PROBLEM" = 0 ] && [ "$PLAN_N_SKIP" = 0 ]; then
		if [ "$GRAFT_JSON" = 1 ]; then
			plan_render
			plan_summary_line "did"
		elif [ "$PLAN_N_OK" = 0 ]; then
			gr_warn "nothing to link: no target resolved to a checkout"
			gr_hint "check the find patterns in $(gr_clean "$CFG_FILE"), or run: graft status"
			return "$GRAFT_EX_DRIFT"
		else
			gr_say "$C_GREEN$G_OK$C_RESET $(gr_plural "$PLAN_N_OK" "link is" "links are") up to date, nothing to do"
		fi
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
	if [ "$PLAN_SHOWN" = 1 ] && [ "$GRAFT_JSON" != 1 ] && [ "$PLAN_R_DONE" -gt 0 ]; then
		gr_say ""
		gr_ok "$(gr_plural "$PLAN_R_DONE" "link in place" "links in place")"
		# The plan was shown instead of the per-link lines, so the backup
		# hint has not been printed yet - and this is the run that made them.
		plan_report_backups
	fi
	plan_summary_line "did"
	plan_print_setup_notes
	# A filesystem that cannot hold a symlink is not drift to reconcile, it is
	# an environment graft cannot work in - a different exit code, because the
	# fix is a different one.
	if [ "$PLAN_R_UNSUPPORTED" -gt 0 ]; then
		if [ "$PLAN_R_ENVKIND" = unwritable ]; then
			gr_hint "check the directory permissions, then run graft again"
		else
			gr_hint "graft needs POSIX symlinks; exFAT, some network mounts and"
			gr_hint "Windows without Developer Mode cannot provide them"
		fi
		return "$GRAFT_EX_ENV"
	fi
	# A link that failed while being applied is drift too. Reporting success
	# because the *plan* had no problems would be a lie about the disk.
	[ "$PLAN_R_FAILED" -gt 0 ] && return "$GRAFT_EX_DRIFT"
	[ "$PLAN_N_PROBLEM" -gt 0 ] && return "$GRAFT_EX_DRIFT"
	return 0
}

plan_execute() {
	local rec t checkout src dest_rel dest_abs action result
	local backup exclude foreign
	PLAN_R_DONE=0 PLAN_R_FAILED=0 PLAN_R_UNSUPPORTED=0 PLAN_R_ENVKIND=""
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

		plan_target_allowed "$t" || continue

		backup=$(cfg_target_get "$t" backup timestamp)
		exclude=$(cfg_target_get "$t" git_exclude yes)
		foreign=$(cfg_target_get "$t" on_foreign_link warn)
		[ "$GRAFT_FORCE" = 1 ] && foreign=force

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
			backed-up)
				gr_add "$(gr_clean "$(plan_short_path "$dest_abs")")  ($t)"
				gr_hint "your previous content is at $(gr_clean "$(plan_short_path "$(plan_backup_of "$dest_abs")")")"
				;;
			*) gr_skip "$(gr_clean "$(plan_short_path "$dest_abs")")  $result  ($t)" ;;
			esac
		elif [ "$AP_RESULT" = unsupported ] || [ "$AP_RESULT" = unwritable ]; then
			PLAN_R_UNSUPPORTED=$((PLAN_R_UNSUPPORTED + 1))
			PLAN_R_ENVKIND="$AP_RESULT"
		else
			PLAN_R_FAILED=$((PLAN_R_FAILED + 1))
			gr_warn "$(gr_clean "$(plan_short_path "$dest_abs")")  failed  ($t)"
		fi
	done <<EOF
$PLAN_DATA
EOF
	st_save
}

# The backup path recorded for a destination, or empty. Read back from the
# state rather than plumbed out of ap_link, because that is where unlink will
# look for it too - one source of truth for where the user's data went.
plan_backup_of() {
	local rec
	rec=$(st_by_dest "$1" 2>/dev/null) || return 0
	st_field "$rec" 7
}

# Backups are excluded from git status so they do not become commit noise, so
# the tool has to be the one that remembers them out loud.
plan_report_backups() {
	local rec b n=0
	[ "$GRAFT_JSON" = 1 ] && return 0
	while IFS= read -r rec; do
		[ -n "$rec" ] || continue
		b=$(st_field "$rec" 7)
		[ -n "$b" ] || continue
		{ [ -e "$b" ] || [ -L "$b" ]; } || continue
		[ "$n" = 0 ] && gr_say "" && gr_bold "your content that graft moved aside"
		n=$((n + 1))
		gr_say "  $(gr_clean "$(plan_short_path "$b")")"
	done <<EOF
$(st_records)
EOF
	[ "$n" = 0 ] && return 0
	gr_dim "  graft unlink puts these back; they are hidden from git status until then"
	return 0
}

plan_summary_line() {
	local verb="$1"
	[ "$GRAFT_JSON" = 1 ] && {
		printf '{"summary":{"changed":%s,"unchanged":%s,"problems":%s,"skipped":%s}}\n' \
			"$PLAN_N_CHANGE" "$PLAN_N_OK" "$PLAN_N_PROBLEM" "$PLAN_N_SKIP"
		return 0
	}
	# Only speak up when there is something to say, and then count everything -
	# a line that reports one problem while three lines above it show three is
	# worse than no line at all.
	if [ "$PLAN_N_PROBLEM" -gt 0 ] || [ "$PLAN_N_SKIP" -gt 0 ]; then
		gr_say ""
		local parts=""
		if [ "$PLAN_N_CHANGE" -gt 0 ]; then
			parts=$(gr_plural "$PLAN_N_CHANGE" "change $verb" "changes $verb")
		fi
		if [ "$PLAN_N_OK" -gt 0 ]; then
			parts="${parts:+$parts, }$PLAN_N_OK already correct"
		fi
		if [ "$PLAN_N_PROBLEM" -gt 0 ]; then
			parts="${parts:+$parts, }$(gr_plural "$PLAN_N_PROBLEM" needs need) attention"
		fi
		if [ "$PLAN_N_SKIP" -gt 0 ]; then
			parts="${parts:+$parts, }$PLAN_N_SKIP skipped"
		fi
		gr_say "$parts"
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
	PLAN_SHOW_DESC=1
	plan_build || return "$GRAFT_EX_USAGE"
	plan_counts
	if [ "$GRAFT_JSON" != 1 ]; then
		gr_bold "context: $(gr_clean "$CFG_CTX_ROOT")"
	fi
	plan_render
	plan_report_backups
	plan_summary_line "pending"
	[ "$PLAN_N_PROBLEM" -gt 0 ] && return "$GRAFT_EX_DRIFT"
	[ "$PLAN_N_CHANGE" -gt 0 ] && return "$GRAFT_EX_DRIFT"
	return 0
}

# Reverse whatever we can still recognise as ours, using only what is on disk:
# a symlink whose target lies inside the context repo. Used when the state file
# was lost - a rebuilt machine, a cleared XDG_STATE_HOME, a different user.
plan_unlink_stateless() {
	local targets="$1" t checkout spec dest_rel
	PLAN_N_UNLINKED=0
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		checkout=$(disc_resolve "$t" 2>/dev/null) || continue
		[ -n "$checkout" ] || continue
		while IFS= read -r spec; do
			[ -n "$spec" ] || continue
			dest_rel=${spec#*	}
			plan_only_matches "$dest_rel" || continue
			[ -L "$checkout/$dest_rel" ] || continue
			if [ "$GRAFT_DRY_RUN" = 1 ]; then
				gr_skip "would remove $(gr_clean "$(plan_short_path "$checkout/$dest_rel")")"
				PLAN_N_UNLINKED=$((PLAN_N_UNLINKED + 1))
				continue
			fi
			AP_RESULT=""
			if ap_unlink_dest "$checkout" "$dest_rel" "$CFG_CTX_ROOT" >/dev/null; then
				case "$AP_RESULT" in
				removed | restored)
					gr_ok "$(gr_clean "$(plan_short_path "$checkout/$dest_rel")")  link removed (no state, matched by target)"
					PLAN_N_UNLINKED=$((PLAN_N_UNLINKED + 1))
					;;
				esac
			fi
		done <<EOF
$(cfg_target_links "$t")
EOF
	done <<EOF
$targets
EOF
}

plan_unlink_json() {
	printf '{"target":"%s","dest":"%s","result":"%s","status":"%s"}\n' \
		"$(gr_json_escape "$1")" "$(gr_json_escape "$2")" \
		"$(gr_json_escape "$3")" "$(gr_json_escape "$4")"
}

plan_cmd_unlink() {
	local rec targets t where dest n=0
	targets=$(plan_selected_targets) || return "$GRAFT_EX_USAGE"
	st_load
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		while IFS= read -r rec; do
			[ -n "$rec" ] || continue
			# --only is documented as a global flag. Ignoring it here meant a
			# user who asked for one link back lost every one of them.
			dest=$(plan_field "$rec" 3)
			plan_only_matches "${dest#"$(plan_field "$rec" 2)"/}" || continue
			if [ "$GRAFT_DRY_RUN" = 1 ]; then
				dest=$(plan_field "$rec" 3)
				if [ "$GRAFT_JSON" = 1 ]; then
					plan_unlink_json "$t" "$dest" would-remove ok
				else
					gr_skip "would remove $(gr_clean "$(plan_short_path "$dest")")"
				fi
				n=$((n + 1))
				continue
			fi
			# Direct call, stdout discarded: same subshell trap as ap_link.
			AP_RESULT=""
			dest=$(plan_field "$rec" 3)
			where=$(gr_clean "$(plan_short_path "$dest")")
			if ap_unlink_record "$rec" >/dev/null; then
				case "$AP_RESULT" in
				restored | removed) n=$((n + 1)) ;;
				esac
				if [ "$GRAFT_JSON" = 1 ]; then
					plan_unlink_json "$t" "$dest" "$AP_RESULT" ok
				else
					case "$AP_RESULT" in
					restored) gr_ok "$where  link removed, backup restored" ;;
					removed) gr_ok "$where  link removed" ;;
					already-gone) gr_skip "$where  was already gone" ;;
					*) gr_skip "$where  $AP_RESULT" ;;
					esac
				fi
			elif [ "$GRAFT_JSON" = 1 ]; then
				plan_unlink_json "$t" "$dest" "$AP_RESULT" kept
			else
				gr_warn "$where  left alone ($AP_RESULT)"
			fi
		done <<EOF
$(st_records "$t")
EOF
	done <<EOF
$targets
EOF
	# Without a state file there is nothing to iterate, and unlink would report
	# a cheerful "0 links removed" while every symlink stayed exactly where it
	# was. Fall back to asking the checkouts themselves.
	if [ "$n" = 0 ] && [ -z "$(st_records)" ]; then
		# Not `n=$(plan_unlink_stateless ...)`: a command substitution would
		# swallow its progress output and hand back the text instead of the
		# count. Third time this shape has bitten us - see plan_execute.
		PLAN_N_UNLINKED=0
		plan_unlink_stateless "$targets"
		n=$PLAN_N_UNLINKED
	fi
	[ "$GRAFT_DRY_RUN" = 1 ] || st_save
	if [ "$GRAFT_JSON" = 1 ]; then
		printf '{"summary":{"removed":%s,"dry_run":%s}}\n' "$n" "$GRAFT_DRY_RUN"
	elif [ "$GRAFT_DRY_RUN" = 1 ]; then
		gr_say "$(gr_plural "$n" "link would be removed" "links would be removed")"
	else
		gr_say "$(gr_plural "$n" "link removed" "links removed")"
	fi
	return 0
}

plan_cmd_adopt() {
	# adopt is the way out of the one state graft refuses to touch: a context
	# directory that is already committed to the project repo. It is therefore
	# the command that has to be the most careful, not the least.
	#
	# The rule that shapes everything below: a TRACKED directory is copied and
	# left in place. Moving it would stage a deletion of files graft does not
	# own, in a repo graft was invited into - and no `unlink` can give those
	# back. Only git may remove them, and only when the user says so.
	local dir name checkout rel src spec sp dp found tracked=1 line
	dir=""
	while IFS= read -r line; do
		[ -n "$line" ] || continue
		dir="$line"
		break
	done <<EOF
$GRAFT_ARGS
EOF
	name="$GRAFT_ADOPT_AS"
	[ -n "$dir" ] || gr_die "$GRAFT_EX_USAGE" "adopt needs a directory: graft adopt <dir> --as NAME"
	[ -n "$name" ] || gr_die "$GRAFT_EX_USAGE" "adopt needs --as NAME"
	dir=$(gr_abspath "$dir")
	dir=${dir%/}
	[ -e "$dir" ] || gr_die "$GRAFT_EX_USAGE" "no such path: $(gr_clean "$dir")"
	if [ -L "$dir" ]; then
		gr_err "$(gr_clean "$dir") is already a symlink"
		gr_hint "there is nothing to adopt - run: graft status"
		return "$GRAFT_EX_USAGE"
	fi

	checkout=$(git -C "$(dirname -- "$dir")" rev-parse --show-toplevel 2>/dev/null) || checkout=""
	if [ -z "$checkout" ]; then
		gr_err "$(gr_clean "$dir") is not inside a git checkout"
		gr_hint "adopt moves context out of a project repo; this path is not in one"
		return "$GRAFT_EX_USAGE"
	fi
	rel=${dir#"$checkout"/}

	if ! plan_target_exists "$name"; then
		gr_err "no target named '$(gr_clean "$name")' in $(gr_clean "$CFG_FILE")"
		gr_hint "add one first, then run adopt again:"
		gr_hint ""
		gr_hint "  [target \"$name\"]"
		gr_hint "  find = origin:*/$(basename -- "$checkout")"
		gr_hint "  link = $(basename -- "$rel") -> $rel"
		return "$GRAFT_EX_USAGE"
	fi

	# Where it belongs is not ours to invent: it is whatever the target's own
	# link rule already says. Guessing a layout here is how you end up with
	# .github/.github/workflows.
	found=""
	while IFS= read -r spec; do
		[ -n "$spec" ] || continue
		sp=${spec%%	*}
		dp=${spec#*	}
		if [ "$dp" = "$rel" ]; then
			found="$sp"
			break
		fi
	done <<EOF
$(cfg_target_links "$name")
EOF
	if [ -z "$found" ]; then
		gr_err "target '$(gr_clean "$name")' has no link rule for '$(gr_clean "$rel")'"
		gr_hint "add one to $(gr_clean "$CFG_FILE"), then run adopt again:"
		gr_hint ""
		gr_hint "  link = $(basename -- "$rel") -> $rel"
		return "$GRAFT_EX_USAGE"
	fi
	src="$found"
	if [ -e "$src" ] || [ -L "$src" ]; then
		gr_err "already present in the context repo: $(gr_clean "$src")"
		gr_hint "merge by hand, or pick a different link destination"
		return "$GRAFT_EX_USAGE"
	fi

	ap_is_tracked "$checkout" "$rel" || tracked=0

	gr_bold "plan"
	if [ "$tracked" = 1 ]; then
		gr_say "  copy $(gr_clean "$(plan_short_path "$dir")")"
		gr_say "    to $(gr_clean "$(plan_short_path "$src")")"
		gr_say "  leave the original alone - it is tracked, so only git may remove it"
	else
		gr_say "  move $(gr_clean "$(plan_short_path "$dir")")"
		gr_say "    to $(gr_clean "$(plan_short_path "$src")")"
		gr_say "  then link it back"
	fi
	[ "$GRAFT_DRY_RUN" = 1 ] && return 0
	gr_confirm "adopt $(basename -- "$rel") into target '$name'?" || {
		gr_say "aborted, nothing was changed"
		return "$GRAFT_EX_UNCONFIRMED"
	}

	mkdir -p -- "$(dirname -- "$src")" || {
		gr_err "cannot create $(gr_clean "$(dirname -- "$src")")"
		return "$GRAFT_EX_ENV"
	}

	if [ "$tracked" = 1 ]; then
		cp -R -- "$dir" "$src" || {
			gr_err "copy failed, nothing was changed"
			return "$GRAFT_EX_ENV"
		}
		gr_ok "copied into the context repo (your repo is untouched)"
		gr_say ""
		gr_bold "three steps to finish, in this order"
		gr_say "  1. commit it here:"
		gr_say "       git -C $(gr_clean "$CFG_CTX_ROOT") add $(gr_clean "${src#"$CFG_CTX_ROOT"/}") && git -C $(gr_clean "$CFG_CTX_ROOT") commit -m \"adopt $name/$rel\""
		gr_say "  2. stop tracking it over there - git removes it, graft never does:"
		gr_say "       git -C $(gr_clean "$checkout") rm -r --cached -- $(gr_clean "$rel")"
		gr_say "       git -C $(gr_clean "$checkout") commit -m \"move $rel into the shared context repo\""
		gr_say "  3. then: graft link $name"
		return 0
	fi

	mv -- "$dir" "$src" || {
		gr_err "move failed, nothing was changed"
		return "$GRAFT_EX_ENV"
	}
	gr_ok "moved into the context repo"
	AP_RESULT=""
	if ap_link "$name" "$checkout" "$src" "$rel" \
		"$(cfg_target_get "$name" backup timestamp)" \
		"$(cfg_target_get "$name" git_exclude yes)" \
		"$(cfg_target_get "$name" on_foreign_link warn)" >/dev/null; then
		st_save
		gr_ok "linked back: $(gr_clean "$(plan_short_path "$dir")")"
		gr_say ""
		gr_say "commit it in the context repo, then your colleagues get it too:"
		gr_say "  git -C $(gr_clean "$CFG_CTX_ROOT") add $(gr_clean "${src#"$CFG_CTX_ROOT"/}") && git -C $(gr_clean "$CFG_CTX_ROOT") commit -m \"adopt $name/$rel\""
		return 0
	fi
	# The move succeeded and the link did not: say so plainly and say where the
	# content is now. Silence here is how people lose track of their files.
	gr_err "moved, but could not create the link ($AP_RESULT)"
	gr_hint "your content is safe at $(gr_clean "$src")"
	gr_hint "move it back with: mv -- $(gr_clean "$src") $(gr_clean "$dir")"
	return "$GRAFT_EX_DRIFT"
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
