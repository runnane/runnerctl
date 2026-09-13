#!/usr/bin/env bash
# tests/run.sh — `make sim`: run runnerctl against tests/stub.config (systemd
# replaced by a log) and assert on stdout, stderr, the exit code, the ordered
# list of privileged calls, and the files that would have been written.
#
# Plain bash, no test framework: CI and a fresh worktree have nothing beyond
# the linter. Run directly (`bash tests/run.sh`) or via `make sim`.
#
# Adding a case: write a function that calls `run <args>` then one or more
# `expect_*`, and register it at the bottom with
#   t     "<name>" <fn>            a case that must pass
#   xfail <KEY> "<name>" <fn>      a case known red today, tracked by issue KEY
# An xfail case prints "xfail" while it fails and FAILS THE RUN if it starts
# passing, so the PR that fixes KEY has to flip it to `t` in the same change.
# A case with no expectations, or one whose log shows a call that bypassed
# the stub (a `direct:` line), fails regardless of the marker.
#
# Helpers (all patterns are `grep -E` regexes):
#   run <args...>                  run ./runnerctl <args> against the stub;
#                                  sets OUT ERR RC and the log/writes dir
#                                  (resets LOG and WRITES first)
#   run_keep <args...>             like `run`, but does not reset WRITES —
#                                  for a case that seeds the writes-mirror
#                                  tree (seed_dropin) before checking what a
#                                  read-only command (status) sees there.
#                                  LOG (and OUT/ERR/RC) are still reset.
#   run_fn <function> <args...>    call one of runnerctl's own helpers (e.g.
#                                  fmt_dur) directly: sources the script with
#                                  RUNNERCTL_NO_MAIN=1, no config, no command;
#                                  sets OUT ERR RC, the log stays empty
#   seed_dropin UNIT PROFILE       write a drop-in for UNIT into the
#                                  writes-mirror tree as if `apply --profile
#                                  PROFILE` had already run for it — for
#                                  status's PROFILE-column cases. Pair with
#                                  run_keep, since a plain `run` would wipe it.
#   expect_rc N                    exit code
#   expect_out P / expect_no_out P some stdout line matches / none does
#   expect_err P                   some stderr line matches
#   expect_log P / expect_no_log P some privileged call matches / none does
#   expect_log_count P N           exactly N privileged calls match
#   expect_log_order P1 P2 ...     matches occur in this order (subsequence)
#   expect_file PATH P             the file `tee`d to PATH exists and matches
#   expect_file_lacks PATH P       it exists and no line matches
#   expect_no_file PATH            nothing was written to PATH
# Env knobs for a single run: prefix it, e.g.
#   RUNNERCTL_STUB_ENV_FILE_EXISTS=1 run apply --profile deploy
#
# GHR-15: the stub points SYSTEMD_DIR at $RUNNERCTL_TEST_WRITES/etc/systemd/system
# (see tests/stub.config), so a plain read of a unit's drop-in (status's
# PROFILE column) and a run_priv-mediated write of one (apply/remove-limits)
# resolve to the same place — the writes-mirror tree — without a separate
# real-path-vs-mirror distinction. expect_file/expect_no_file/expect_file_lacks
# and DROPIN_DIR below account for that: a path already under $WRITES is used
# as-is instead of having $WRITES prepended again.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# Cell padding in `status` counts characters, which needs a UTF-8 locale for
# the `—` cells (GHR-21). Pin one where it exists so the run does not depend on
# the caller's LANG; a box without it keeps its own locale.
if locale -a 2>/dev/null | grep -qiE '^C\.utf-?8$'; then export LC_ALL=C.UTF-8; fi
RUNNERCTL="${RUNNERCTL:-./runnerctl}"
STUB="tests/stub.config"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/log"
WRITES="$TMP/writes"

# --- Harness state -----------------------------------------------------------
OUT="" ERR="" RC=0
FAILS=()       # failed expectations of the current case
ERRS=()        # harness errors of the current case (fail even under xfail)
NEXPECT=0      # expectations made by the current case
npass=0 nfail=0 nxfail=0
FAILED=()      # names of failed cases, for the summary
XFAIL_KEYS=""  # issue keys of the xfail cases that failed as expected

# --- Running runnerctl --------------------------------------------------------
run() {
  : >"$LOG"
  rm -rf "$WRITES"; mkdir -p "$WRITES"
  RC=0
  OUT="$(RUNNERCTL_CONFIG="$STUB" RUNNERCTL_TEST_LOG="$LOG" RUNNERCTL_TEST_WRITES="$WRITES" \
         "$RUNNERCTL" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# Like `run`, but does not reset WRITES first (LOG still is) — for a case
# that seeds the writes-mirror tree with seed_dropin before running a
# read-only command that reads it back (status's PROFILE column).
run_keep() {
  : >"$LOG"
  RC=0
  OUT="$(RUNNERCTL_CONFIG="$STUB" RUNNERCTL_TEST_LOG="$LOG" RUNNERCTL_TEST_WRITES="$WRITES" \
         "$RUNNERCTL" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# Write a drop-in for UNIT into the writes-mirror tree, first line rendered
# exactly as render_dropin would for PROFILE, so status's plain read (no
# run_priv) of $SYSTEMD_DIR/<unit>.d/$DROPIN_NAME finds it — bypasses
# apply/run_priv/tee entirely, since a case using this calls run_keep, not
# run (which would wipe it straight back out).
seed_dropin() {
  local u="$1" p="$2"
  local dir="$WRITES/etc/systemd/system/$u.d"
  mkdir -p "$dir"
  echo "# Managed by runnerctl (profile: $p) — DO NOT EDIT BY HAND." >"$dir/10-runnerctl.conf"
}

# Call a helper function of the script directly, for the ones no command
# exposes on their own (fmt_dur, ...). RUNNERCTL_NO_MAIN=1 makes the script
# define its functions and return instead of running main, so nothing is
# sourced from a config and nothing touches the host.
run_fn() {
  : >"$LOG"
  RC=0
  OUT="$(RUNNERCTL_NO_MAIN=1 bash -c '. "$0" && "$@"' "$RUNNERCTL" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# --- Expectations -------------------------------------------------------------
_expect() { NEXPECT=$((NEXPECT + 1)); }

expect_rc() {
  _expect
  [ "$RC" -eq "$1" ] || FAILS+=("exit code: want $1, got $RC")
}

expect_out() {
  _expect
  grep -Eq -- "$1" <<<"$OUT" || FAILS+=("stdout has no line matching /$1/")
}

expect_no_out() {
  _expect
  ! grep -Eq -- "$1" <<<"$OUT" || FAILS+=("stdout has a line matching /$1/")
}

expect_err() {
  _expect
  grep -Eq -- "$1" <<<"$ERR" || FAILS+=("stderr has no line matching /$1/")
}

expect_log() {
  _expect
  grep -Eq -- "$1" "$LOG" || FAILS+=("no privileged call matching /$1/")
}

expect_no_log() {
  _expect
  ! grep -Eq -- "$1" "$LOG" || FAILS+=("a privileged call matches /$1/")
}

expect_log_count() {
  _expect
  local n
  n="$(grep -Ec -- "$1" "$LOG" || true)"
  [ "$n" -eq "$2" ] || FAILS+=("privileged calls matching /$1/: want $2, got $n")
}

# Each pattern must match a log line strictly after the previous match.
expect_log_order() {
  _expect
  local line=0 p n
  for p in "$@"; do
    n="$(tail -n +"$((line + 1))" "$LOG" | grep -En -m1 -- "$p" | cut -d: -f1 || true)"
    if [ -z "$n" ]; then
      FAILS+=("privileged call order: /$p/ not found after line $line")
      return 0
    fi
    line=$((line + n))
  done
}

# The real path P is normally mirrored at $WRITES$P (`tee /etc/x` -> stdin
# stored at $WRITES/etc/x). SYSTEMD_DIR, though, is redirected by the stub to
# live inside $WRITES already (GHR-15) so a plain read and a run_priv write
# agree on one location — so a path already under $WRITES (e.g. built from
# DROPIN_DIR below) is used as-is instead of getting $WRITES prepended again.
_mirror_path() {
  case "$1" in
    "$WRITES"/*) printf '%s\n' "$1" ;;
    *)           printf '%s\n' "$WRITES$1" ;;
  esac
}

expect_file() {
  _expect
  local p; p="$(_mirror_path "$1")"
  if [ ! -f "$p" ]; then FAILS+=("nothing written to $1"); return 0; fi
  grep -Eq -- "$2" "$p" || FAILS+=("$1 has no line matching /$2/")
}

expect_file_lacks() {
  _expect
  local p; p="$(_mirror_path "$1")"
  if [ ! -f "$p" ]; then FAILS+=("nothing written to $1"); return 0; fi
  ! grep -Eq -- "$2" "$p" || FAILS+=("$1 has a line matching /$2/")
}

expect_no_file() {
  _expect
  local p; p="$(_mirror_path "$1")"
  [ ! -e "$p" ] || FAILS+=("$1 was written")
}

# --- Case runner --------------------------------------------------------------
_case() {
  local key="$1" name="$2" fn="$3"
  FAILS=(); ERRS=(); NEXPECT=0
  OUT=""; ERR=""; RC=0; : >"$LOG"
  "$fn"
  if grep -q '^direct:' "$LOG"; then
    ERRS+=("stub leak, a call bypassed run_priv: $(grep -m1 '^direct:' "$LOG")")
  fi
  [ "$NEXPECT" -gt 0 ] || ERRS+=("case makes no assertions")

  if [ ${#ERRS[@]} -gt 0 ]; then
    _report_fail "$name" "${ERRS[@]}" ${FAILS[@]+"${FAILS[@]}"}
  elif [ -z "$key" ]; then
    if [ ${#FAILS[@]} -eq 0 ]; then
      echo "ok    $name"; npass=$((npass + 1))
    else
      _report_fail "$name" "${FAILS[@]}"
    fi
  elif [ ${#FAILS[@]} -eq 0 ]; then
    _report_fail "$name" "XPASS: this 'xfail $key' case now passes — change it to 't' in tests/run.sh"
  else
    echo "xfail $name [$key]"
    nxfail=$((nxfail + 1)); XFAIL_KEYS="$XFAIL_KEYS $key"
  fi
}

_report_fail() {
  local name="$1"; shift
  echo "FAIL  $name"
  printf '      - %s\n' "$@"
  if [ -s "$LOG" ]; then
    echo "      privileged calls:"
    sed 's/^/        /' "$LOG"
  fi
  nfail=$((nfail + 1)); FAILED+=("$name")
}

t()     { _case "" "$@"; }
xfail() { _case "$1" "${@:2}"; }

# --- Cases --------------------------------------------------------------------
U1="actions.runner.example.slot-1.service"
U2="actions.runner.example.slot-2.service"
U3="actions.runner.example.slot-3.service"
# The stub redirects SYSTEMD_DIR under $WRITES (GHR-15) so apply/remove-limits'
# writes land where status's plain read looks for them; see _mirror_path above.
DROPIN_DIR="$WRITES/etc/systemd/system"
DEPLOY_ENV="/etc/runnerctl/deploy.env"

case_status_table() {
  run status
  expect_rc 0
  expect_out '^IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +RESTART +ENVFILE +WORKING-ON$'
  # slot-1 also carries MemoryPeak (GHR-8), so USED is current/peak.
  expect_out '^0 +example\.slot-1 +— +active/running +3d 4h +enabled +26\.0G +22\.0G +1\.0G/25\.0G +always +— +my-app:test \(12m\)$'
  # slot-2 has restarted (GHR-8): the ACTIVE cell carries ↻3 and the
  # journal-derived reason, so the plain "active/running" is followed by
  # that annotation before SINCE, not by spaces straight to 41m.
  expect_out '^1 +example\.slot-2 +— +active/running .* +41m +enabled '
  expect_out '^2 +example\.slot-3 +— +inactive/dead +6d +disabled +— +— +— +always +— +—$'
  expect_no_out '^3 '
  # status is read-only: no privileged call at all (the `probe:` lines below
  # are the stub logging its own unit_props hits, not a host mutation).
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

case_status_one_unit_props_call_per_slot() {
  run status
  expect_rc 0
  # One batched `unit_props` call per slot, not nine `prop` calls per slot.
  expect_log_count '^probe:unit_props ' 3
  expect_log_count '^probe:unit_props actions\.runner\.example\.slot-1\.service$' 1
  expect_log_count '^probe:unit_props actions\.runner\.example\.slot-2\.service$' 1
  expect_log_count '^probe:unit_props actions\.runner\.example\.slot-3\.service$' 1
}

case_status_envfile_value_with_embedded_equals() {
  run status
  expect_rc 0
  # unit_props's slot-2 EnvironmentFiles value itself contains '=' — the
  # ENVFILE column must carry the whole value, not just the part before it.
  expect_out '^1 +example\.slot-2 .*/etc/x \(ignore_errors=no\) +idle 2h31m \(2 jobs\)$'
}

case_apply_ci() {
  run apply
  expect_rc 0
  expect_out "^Applied profile 'ci': Restart=always RestartSec=10 MemoryMax=26G MemoryHigh=22G$"
  expect_out 'Config takes effect on next'
  expect_log_count "tee $DROPIN_DIR/$U1\\.d/10-runnerctl\\.conf" 1
  expect_log_count 'tee .*/10-runnerctl\.conf$' 3
  expect_log_order "mkdir -p $DROPIN_DIR/$U1\\.d" "tee .*/$U1\\.d/" "tee .*/$U2\\.d/" "tee .*/$U3\\.d/" '^systemctl daemon-reload$'
  expect_log_count '^systemctl daemon-reload$' 1
  expect_no_log '^systemctl restart'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryMax=26G$'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryHigh=22G$'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^RestartSec=10$'
  expect_file_lacks "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^EnvironmentFile='
}

case_apply_restart_flags() {
  run apply --restart --max 30G --high 28G --restart-sec 5
  expect_rc 0
  expect_out 'MemoryMax=30G MemoryHigh=28G'
  expect_out 'Restarted all runner slots'
  expect_log_order 'tee .*/10-runnerctl\.conf$' '^systemctl daemon-reload$' "^systemctl restart $U1\$" "^systemctl restart $U2\$" "^systemctl restart $U3\$"
  expect_log_count '^systemctl restart ' 3
  expect_file "$DROPIN_DIR/$U2.d/10-runnerctl.conf" '^MemoryMax=30G$'
  expect_file "$DROPIN_DIR/$U2.d/10-runnerctl.conf" '^RestartSec=5$'
}

case_apply_deploy_refuses_without_env_file() {
  run apply --profile deploy
  expect_rc 1
  expect_err "EnvironmentFile $DEPLOY_ENV missing"
  expect_err 'runnerctl env-init --profile deploy'
  expect_log "^test -f $DEPLOY_ENV\$"
  expect_no_log '^tee '
  expect_no_log '^systemctl'
}

case_apply_deploy_writes_with_env_file() {
  RUNNERCTL_STUB_ENV_FILE_EXISTS=1 run apply --profile deploy
  expect_rc 0
  expect_out "^Applied profile 'deploy': Restart=always RestartSec=15 EnvironmentFile=$DEPLOY_ENV\$"
  expect_log_order "^test -f $DEPLOY_ENV\$" "tee .*/$U1\\.d/" "tee .*/$U2\\.d/" "tee .*/$U3\\.d/" '^systemctl daemon-reload$'
  expect_file "$DROPIN_DIR/$U3.d/10-runnerctl.conf" "^EnvironmentFile=$DEPLOY_ENV\$"
  expect_file "$DROPIN_DIR/$U3.d/10-runnerctl.conf" '^# Managed by runnerctl \(profile: deploy\)'
  expect_file_lacks "$DROPIN_DIR/$U3.d/10-runnerctl.conf" '^Memory(Max|High)='
}

case_apply_unknown_profile() {
  run apply --profile nope
  expect_rc 1
  expect_err "unknown profile 'nope' \\(known: ci deploy\\)"
  expect_no_log '.'
}

# --- GHR-6: missing values on value flags, --flag=value, value validation ---
case_apply_max_missing_value() {
  run apply --max
  expect_rc 1
  expect_err '^runnerctl: --max needs a value$'
  expect_no_log '.'
}

case_apply_profile_equals_form_reaches_deploy() {
  run apply --profile=deploy
  expect_rc 1
  expect_err "EnvironmentFile $DEPLOY_ENV missing"
  expect_log "^test -f $DEPLOY_ENV\$"
  expect_no_log '^tee '
}

case_apply_max_and_restart_sec_equals_form() {
  run apply --max=30G --restart-sec=5
  expect_rc 0
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryMax=30G$'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^RestartSec=5$'
}

case_apply_max_invalid_value_rejected() {
  run apply --max lots
  expect_rc 1
  expect_err '^runnerctl: --max value .lots. is invalid'
  expect_no_log '.'
}

case_apply_restart_sec_invalid_value_rejected() {
  run apply --restart-sec soon
  expect_rc 1
  expect_err '^runnerctl: --restart-sec value .soon. is invalid'
  expect_no_log '.'
}

case_upgrade_ref_missing_value() {
  run upgrade --ref
  expect_rc 1
  expect_err '^runnerctl: --ref needs a value$'
  expect_no_log '.'
}

case_scale_2() {
  run scale 2
  expect_rc 0
  expect_out "^  \\[active\\] $U1\$"
  expect_out "^  \\[active\\] $U2\$"
  expect_out "^  \\[stopped\\] $U3\$"
  expect_out "^Scaled to 2 active runner\\(s\\), profile 'ci' @ MemoryMax=26G\\.\$"
  expect_out 'Config takes effect on next \(re\)start of already-running slots\. Run: runnerctl restart'
  expect_log_count 'tee .*/10-runnerctl\.conf$' 2
  expect_log "tee $DROPIN_DIR/$U1\\.d/10-runnerctl\\.conf\$"
  expect_log "tee $DROPIN_DIR/$U2\\.d/10-runnerctl\\.conf\$"
  expect_no_file "$DROPIN_DIR/$U3.d/10-runnerctl.conf"
  expect_log "^systemctl enable --now $U1\$"
  expect_log "^systemctl enable --now $U2\$"
  expect_log "^systemctl disable --now $U3\$"
  expect_log_count '^systemctl daemon-reload$' 1
  expect_no_log '^systemctl restart '
}

# GHR-5: enable --now runs per slot BEFORE the single daemon-reload, so the
# first start after a profile change runs with the previous drop-in.
case_scale_reloads_before_enable() {
  run scale 2
  expect_rc 0
  expect_log_order "tee .*/$U1\\.d/10-runnerctl\\.conf\$" "tee .*/$U2\\.d/10-runnerctl\\.conf\$" \
                   '^systemctl daemon-reload$' "^systemctl enable --now $U1\$" "^systemctl enable --now $U2\$"
}

# GHR-5: a slot that fails to enable/disable must be reported, not swallowed
# as "[active]" — and every slot must still be processed.
case_scale_start_failure_reported() {
  RUNNERCTL_STUB_FAIL_UNITS='slot-2' run scale 2
  expect_rc 1
  expect_out "^  \\[active\\] $U1\$"
  expect_out "^  \\[FAILED\\] $U2\$"
  expect_out "^  \\[stopped\\] $U3\$"
  expect_err '1 of 2 slot\(s\) failed'
  expect_log "^systemctl enable --now $U1\$"
  expect_log "^systemctl enable --now $U2\$"
  expect_log "^systemctl disable --now $U3\$"
  expect_no_out '^Scaled to'
}

# GHR-5: --restart restarts the slots that are now active, so the new caps
# take effect immediately, after (not instead of) the enable/disable loop.
case_scale_restart_flag_restarts_active_slots() {
  run scale 2 --restart
  expect_rc 0
  expect_log_order "^systemctl enable --now $U1\$" "^systemctl enable --now $U2\$" \
                   "^systemctl restart $U1\$" "^systemctl restart $U2\$"
  expect_log_count '^systemctl restart ' 2
  expect_no_log "^systemctl restart $U3\$"
  expect_out 'Restarted 2 active slot\(s\) \(config active now\)\.'
}

case_scale_zero_rejected() {
  run scale 0
  expect_rc 1
  expect_err '^runnerctl: N must be 1\.\.3$'
  expect_no_log '^tee '
  expect_no_log '^systemctl'
}

case_scale_non_integer_rejected() {
  run scale abc
  expect_rc 1
  expect_err '^runnerctl: N must be an integer$'
  expect_no_log '.'
}

case_scale_missing_n() {
  run scale
  expect_rc 1
  expect_err 'scale needs N'
  expect_no_log '.'
}

case_env_init_refuses_to_clobber() {
  RUNNERCTL_STUB_ENV_FILE_EXISTS=1 run env-init --profile deploy
  expect_rc 0
  expect_out "^$DEPLOY_ENV already exists — leaving it untouched"
  expect_log_count '.' 1          # only the existence probe
  expect_log "^test -f $DEPLOY_ENV\$"
  expect_no_file "$DEPLOY_ENV"
}

case_env_init_scaffolds() {
  run env-init --profile deploy
  expect_rc 0
  expect_out "^Scaffolded $DEPLOY_ENV \\(root:root, 600\\)\\.\$"
  expect_log_order "^test -f $DEPLOY_ENV\$" '^mkdir -p /etc/runnerctl$' "^tee $DEPLOY_ENV\$" \
                   "^chown root:root $DEPLOY_ENV\$" "^chmod 600 $DEPLOY_ENV\$"
  expect_file "$DEPLOY_ENV" '^# deploy runner — on-device secrets/config'
  expect_file "$DEPLOY_ENV" '^# KEY=value$'
}

case_env_init_ci_has_no_env_file() {
  run env-init
  expect_rc 1
  expect_err "profile 'ci' defines no EnvironmentFile"
  expect_no_log '.'
}

case_remove_limits() {
  run remove-limits
  expect_rc 0
  expect_out 'Removed managed drop-ins'
  expect_log_count '^rm -f ' 3
  expect_log_order "^rm -f $DROPIN_DIR/$U1\\.d/10-runnerctl\\.conf\$" "^rm -f $DROPIN_DIR/$U2\\.d/10-runnerctl\\.conf\$" \
                   "^rm -f $DROPIN_DIR/$U3\\.d/10-runnerctl\\.conf\$" '^systemctl daemon-reload$'
  expect_log_count '^systemctl daemon-reload$' 1
}

case_restart_by_index() {
  run restart 1
  expect_rc 0
  expect_out '^restart done\.$'
  expect_log_count '.' 1
  expect_log "^systemctl restart $U2\$"
}

case_stop_all() {
  run stop
  expect_rc 0
  expect_out '^stop done\.$'
  expect_log_order "^systemctl stop $U1\$" "^systemctl stop $U2\$" "^systemctl stop $U3\$"
  expect_log_count '.' 3
}

case_enable_by_unit_name() {
  run enable "$U3"
  expect_rc 0
  expect_log_count '.' 1
  expect_log "^systemctl enable --now $U3\$"
}

case_logs_by_index() {
  run logs 2
  expect_rc 0
  expect_log_count '.' 1
  expect_log "^journalctl -u $U3 -n 100 --no-pager\$"
}

# Callers resolve into a variable on its own line (GHR-19): a die inside
# "$(...)" only exits the subshell, so the guard must run in the main shell.
case_restart_out_of_range() {
  run restart 5
  expect_rc 1
  expect_err 'slot index 5 out of range \(0\.\.2\)'
  expect_no_out 'done\.'
  expect_no_log '^systemctl restart'
}

# --- GHR-9: resolve accepts the short RUNNER name and unambiguous
# prefixes/substrings of it as a target ---------------------------------------

# actions.runner.<arg>.service: the short name exactly as `status` prints it.
case_restart_by_short_name() {
  run restart example.slot-2
  expect_rc 0
  expect_out '^restart done\.$'
  expect_log_count '.' 1
  expect_log "^systemctl restart $U2\$"
}

# Substring match on the short name, unambiguous (only slot-3 contains it).
case_logs_by_substring() {
  run logs slot-3
  expect_rc 0
  expect_log_count '.' 1
  expect_log "^journalctl -u $U3 -n 100 --no-pager\$"
}

# The short name with ".service" appended: neither the literal unit name nor
# "<arg>.service" match this (that would double the suffix) — it resolves
# because the short name is a prefix of the arg, caught by the substring rule.
case_enable_by_short_name_with_service_suffix() {
  run enable example.slot-1.service
  expect_rc 0
  expect_log_count '.' 1
  expect_log "^systemctl enable --now $U1\$"
}

case_restart_ambiguous_target() {
  run restart slot
  expect_rc 1
  expect_err "ambiguous target 'slot' matches:"
  expect_no_out 'done\.'
  expect_no_log '^systemctl restart'
}

case_restart_no_match() {
  run restart nope
  expect_rc 1
  expect_err "no runner slot matches 'nope' \\(have: 0\\.\\.2, example\\.slot-1 example\\.slot-2 example\\.slot-3\\)"
  expect_no_out 'done\.'
  expect_no_log '^systemctl restart'
}

# --- GHR-1: status shows SINCE (time in state) and the running job's runtime --
# The stub pins now_mono at 10^12 µs and stamps each slot relative to it (see
# tests/stub.config). The WORKING-ON runtime here comes from the journal
# stamp (GHR-10): the stub finds no Runner.Worker pid, so the /proc age read
# (proc_worker_pid → proc_runtime) is NOT covered.

case_status_since_active_slots() {
  run status
  expect_rc 0
  # active slots: SINCE is measured from ActiveEnterTimestampMonotonic
  expect_out '^0 +example\.slot-1 +— +active/running +3d 4h +enabled '
  # slot-2 restarted (GHR-8): ACTIVE carries ↻3 (last: ...) before SINCE.
  expect_out '^1 +example\.slot-2 +— +active/running .* +41m +enabled '
}

case_status_since_inactive_slot_uses_inactive_enter() {
  run status
  expect_rc 0
  # slot-3 was last active 8d ago and went inactive 6d ago: an inactive slot
  # is measured from InactiveEnterTimestampMonotonic, so 6d, never 8d.
  expect_out '^2 +example\.slot-3 +— +inactive/dead +6d +disabled '
  expect_no_out '^2 +example\.slot-3 +inactive/dead +8d '
}

case_status_job_runtime_in_working_on() {
  run status
  expect_rc 0
  # the runtime rides inside the WORKING-ON cell; the column count is unchanged
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_out '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
  expect_out '^2 +example\.slot-3 .* —$'
  expect_no_out '^IDX .*RUNTIME'
}

case_fmt_dur_seconds()       { run_fn fmt_dur 5;      expect_rc 0; expect_out '^5s$'; }
case_fmt_dur_zero()          { run_fn fmt_dur 0;      expect_rc 0; expect_out '^0s$'; }
case_fmt_dur_minutes()       { run_fn fmt_dur 2460;   expect_rc 0; expect_out '^41m$'; }
case_fmt_dur_hours_minutes() { run_fn fmt_dur 11520;  expect_rc 0; expect_out '^3h12m$'; }
case_fmt_dur_whole_hours()   { run_fn fmt_dur 7200;   expect_rc 0; expect_out '^2h$'; }
case_fmt_dur_days_hours()    { run_fn fmt_dur 273600; expect_rc 0; expect_out '^3d 4h$'; }
case_fmt_dur_whole_days()    { run_fn fmt_dur 518400; expect_rc 0; expect_out '^6d$'; }
case_fmt_dur_empty()         { run_fn fmt_dur '';     expect_rc 0; expect_out '^—$'; }
case_fmt_dur_negative()      { run_fn fmt_dur -30;    expect_rc 0; expect_out '^—$'; }
case_fmt_dur_non_numeric()   { run_fn fmt_dur n/a;    expect_rc 0; expect_out '^—$'; }

case_since_state_never_entered() {
  # 0 / empty stamps mean the state was never entered: — rather than a huge age
  run_fn since_state inactive 0 0;   expect_rc 0; expect_out '^—$'
  run_fn since_state active '' '';   expect_rc 0; expect_out '^—$'
}

# --- GHR-12: logs gains -f/-n/--since/-g and defaults to all slots ----------

case_logs_all_slots_default() {
  run logs
  expect_rc 0
  expect_log_count '.' 1
  expect_log "^journalctl -u $U1 -u $U2 -u $U3 -n 100 --no-pager\$"
}

case_logs_follow_defaults_to_50() {
  run logs 1 -f
  expect_rc 0
  expect_log "^journalctl -u $U2 -n 50 -f --no-pager\$"
}

case_logs_lines_since_grep() {
  run logs 1 -n 20 --since '1 hour ago' -g 'Running job'
  expect_rc 0
  expect_log "^journalctl -u $U2 -n 20 --since 1 hour ago -g Running job --no-pager\$"
}

case_logs_lines_missing_value() {
  run logs 1 -n
  expect_rc 1
  expect_err '\-n needs a value'
  expect_no_log '.'
}

case_logs_unknown_flag() {
  run logs 1 --bogus
  expect_rc 1
  expect_err 'unknown option: --bogus'
  expect_no_log '.'
}

case_logs_no_match() {
  run logs nope
  expect_rc 1
  expect_err "no runner slot matches 'nope'"
  expect_no_log '.'
}

# --- GHR-21: `—` cells are padded by characters, so columns stay aligned -----
# A `—` is 3 bytes; printf's %-Ns padded it two short. Compare the character
# offset of the last column on a row full of `—` cells with the header's.
case_status_dash_cells_keep_columns_aligned() {
  run status
  expect_rc 0
  local header row hpos rpos
  header="$(grep -m1 '^IDX ' <<<"$OUT")"
  row="$(grep -m1 '^2 ' <<<"$OUT")"          # slot-3: MAX/HIGH/USED/ENVFILE/WORKING-ON are all —
  hpos="${header%%WORKING-ON*}"; hpos="${#hpos}"
  rpos="${row%—}"; rpos="${#rpos}"             # offset of the final — (WORKING-ON cell)
  _expect
  [ "$hpos" -eq "$rpos" ] || FAILS+=("WORKING-ON column: header at $hpos, slot-3 row at $rpos")
  expect_out '^2 +example\.slot-3 +— +inactive/dead +6d +disabled +— +— +— +always +— +—$'
}

# --- GHR-15: apply/remove-limits take targets; status shows the PROFILE ------
# each slot carries (read from its drop-in's first line, no run_priv).

case_apply_targeted_single_slot_with_profile() {
  RUNNERCTL_STUB_ENV_FILE_EXISTS=1 run apply --profile deploy 2
  expect_rc 0
  expect_out "^Applied profile 'deploy' to 1 slot\\(s\\): example\\.slot-3\$"
  expect_log_count "tee $DROPIN_DIR/$U3\\.d/10-runnerctl\\.conf" 1
  expect_log_count 'tee .*/10-runnerctl\.conf$' 1
  expect_log_count '^systemctl daemon-reload$' 1
  expect_no_log "tee $DROPIN_DIR/$U1\\.d/"
  expect_no_log "tee $DROPIN_DIR/$U2\\.d/"
  expect_file "$DROPIN_DIR/$U3.d/10-runnerctl.conf" "^EnvironmentFile=$DEPLOY_ENV\$"
  expect_no_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf"
  expect_no_file "$DROPIN_DIR/$U2.d/10-runnerctl.conf"
}

case_apply_targeted_multiple_by_index_and_name() {
  run apply 0 example.slot-2
  expect_rc 0
  expect_out "^Applied profile 'ci' to 2 slot\\(s\\): example\\.slot-1, example\\.slot-2\$"
  expect_log_count 'tee .*/10-runnerctl\.conf$' 2
  expect_log "tee $DROPIN_DIR/$U1\\.d/10-runnerctl\\.conf\$"
  expect_log "tee $DROPIN_DIR/$U2\\.d/10-runnerctl\\.conf\$"
  expect_no_log "tee $DROPIN_DIR/$U3\\.d/"
}

case_apply_target_no_match() {
  run apply nope
  expect_rc 1
  expect_err "no runner slot matches 'nope'"
  expect_no_log '.'
}

case_remove_limits_targeted() {
  run remove-limits 1
  expect_rc 0
  expect_log_order "^rm -f $DROPIN_DIR/$U2\\.d/10-runnerctl\\.conf\$" '^systemctl daemon-reload$'
  expect_log_count '^rm -f ' 1
  expect_no_log "rm -f $DROPIN_DIR/$U1\\.d/"
  expect_no_log "rm -f $DROPIN_DIR/$U3\\.d/"
  expect_out "^Removed drop-in for 1 slot\\(s\\): example\\.slot-2\\.\$"
}

case_scale_rejects_stray_argument() {
  run scale 2 extra
  expect_rc 1
  expect_err "^runnerctl: unexpected argument: extra\$"
  expect_no_log '.'
}

case_status_shows_profile_column() {
  run status   # establishes TMP/WRITES; nothing seeded yet on this call
  seed_dropin "$U1" ci
  seed_dropin "$U3" deploy
  # slot-2 gets no drop-in seeded, so its PROFILE cell stays —
  run_keep status
  expect_rc 0
  expect_out '^0 +example\.slot-1 +ci +active/running '
  expect_out '^1 +example\.slot-2 +— +active/running '
  expect_out '^2 +example\.slot-3 +deploy +inactive/dead '
}

# --- GHR-10: WORKING-ON from the journal; (no access) is not stopped ---------
# job_info is the real function here: the stub shadows only journal_job_lines
# (slot-1 `Running job: test` with no completion, slot-2 `build` completed),
# now_epoch (12 min after slot-1's line) and the /proc hooks (no cgroup
# readable, no worker pid, slot-1's environ names example/my-app). See
# tests/stub.config.

case_status_working_on_from_journal() {
  run status
  expect_rc 0
  # slot-1: job name from the journal, repo from /proc, runtime from the
  # journal stamp (the worker pid is not visible under the stub) — exact.
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\)$'
  # slot-2: its last job completed → idle, never `build`
  expect_out '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
  expect_no_out '^1 +example\.slot-2 .* build'
  # slot-3: no cgroup → —, and the journal is not even asked
  expect_out '^2 +example\.slot-3 .* —$'
  expect_no_out '\(starting\)'
  expect_no_out '^note: '
  # the journal hook gets the invocation id unit_props fetched, once per
  # running slot; nothing reaches journalctl directly (the stub would log
  # `direct:`, which fails the case on its own)
  expect_log_count '^probe:journal_job_lines ' 2
  expect_log '^probe:journal_job_lines actions\.runner\.example\.slot-1\.service 1111aaaa1111aaaa1111aaaa1111aaaa$'
  expect_log '^probe:journal_job_lines actions\.runner\.example\.slot-2\.service 2222bbbb2222bbbb2222bbbb2222bbbb$'
  expect_no_log '^probe:journal_job_lines actions\.runner\.example\.slot-3'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

case_status_no_access_is_not_stopped() {
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 run status
  expect_rc 0
  # journal unreadable → /proc fallback → cgroup unreadable → (no access),
  # distinct from the stopped slot's —
  expect_out '^0 +example\.slot-1 .* \(no access\)$'
  expect_out '^1 +example\.slot-2 .* \(no access\)$'
  expect_out '^2 +example\.slot-3 .* —$'
  expect_no_out '^0 +example\.slot-1 .* —$'
  # the hint: once, under the table, not in a row
  _expect
  local n
  n="$(grep -Ec '^note: WORKING-ON needs journal read access \(systemd-journal group\) or root$' <<<"$OUT" || true)"
  [ "$n" -eq 1 ] || FAILS+=("hint line: want exactly 1, got $n")
  expect_no_out '^[0-9] .*note:'
  # a failed journal read must not escalate: no sudo, no direct journalctl
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

# The parser alone, over a fixed transcript: two jobs, the first completed.
case_journal_running_job_last_uncompleted() {
  run_fn journal_running_job "$(printf '%s\n' \
    '1000000000.000000 runsvc.sh[1]: 2001-09-09 01:46:40Z: Running job: lint' \
    '1000000100.000000 runsvc.sh[1]: 2001-09-09 01:48:20Z: Job lint completed with result: Succeeded' \
    '1000000200.000000 runsvc.sh[1]: 2001-09-09 01:50:00Z: Running job: test (ubuntu, 3.12)')"
  expect_rc 0
  # name is everything after `Running job: ` (display names carry spaces and
  # parens), the stamp is the leading epoch second of THAT line
  expect_out $'^test \\(ubuntu, 3\\.12\\)\t1000000200$'
  expect_no_out '^lint'
}

case_journal_running_job_idle_after_completion() {
  run_fn journal_running_job "$(printf '%s\n' \
    '1000000000.000000 runsvc.sh[1]: 2001-09-09 01:46:40Z: Running job: lint' \
    '1000000100.000000 runsvc.sh[1]: 2001-09-09 01:48:20Z: Job lint completed with result: Failed')"
  expect_rc 0
  expect_no_out '.'
}

# --- GHR-11: --when-idle / drain wait for each slot before acting ------------
# The stub's `pause` is a no-op that logs `probe:pause N`; wait_idle counts
# its clock in POLL_SEC (5) steps per poll, so the poll count is what a case
# asserts. RUNNERCTL_STUB_BUSY_POLLS=N makes slot-1's journal report the job
# as running for the first N journal reads of the run and completed after.
# slot-2 is idle in the fixed picture, slot-3 is not running (—).

# Three busy polls, then slot-1 restarts; slot-2 (idle) and slot-3 (—) follow
# with no pause at all. The pool is rolled one slot at a time, in order.
case_restart_when_idle_waits_then_rolls() {
  RUNNERCTL_STUB_BUSY_POLLS=3 run restart --when-idle
  expect_rc 0
  expect_out '^waiting for example\.slot-1 \(my-app:test, 12m\) …$'
  expect_out '^restart done\.$'
  expect_log_count '^probe:pause 5$' 3
  expect_log_order '^probe:pause 5$' '^probe:pause 5$' '^probe:pause 5$' \
                   "^systemctl restart $U1\$" "^systemctl restart $U2\$" "^systemctl restart $U3\$"
  expect_log_count '^systemctl restart ' 3
  # slot-1 was polled four times (3 busy + the idle one); slot-2 once; slot-3
  # has no cgroup so its journal is never asked
  expect_log_count '^probe:journal_job_lines .*slot-1' 4
  expect_log_count '^probe:journal_job_lines .*slot-2' 1
  expect_no_log '^probe:journal_job_lines .*slot-3'
}

# Busy forever: polls at 0, 5 and 10 s (two pauses), then the timeout —
# nothing is stopped, the busy slot is named on stderr, exit 1.
case_stop_when_idle_times_out() {
  RUNNERCTL_STUB_BUSY_POLLS=99 run stop 0 --when-idle --timeout 10
  expect_rc 1
  expect_err '^runnerctl: timed out after 10s waiting for example\.slot-1 \(my-app:test, 12m\)$'
  expect_err '^  already stopped: none$'
  expect_err '^  busy or unreadable, not stopped: example\.slot-1$'
  expect_out '^waiting for example\.slot-1'
  expect_no_out '^stop done'
  expect_no_log '^systemctl stop '
  expect_log_count '^probe:pause 5$' 2
}

# A slot that went busy again mid-roll: slot-1 is done, slot-2 idle, so the
# summary must say what was already restarted and what was left queued.
case_restart_when_idle_timeout_reports_handled_and_queued() {
  # slot-1 stays busy; target order 1 (idle), 0 (busy), 2 (—): slot-2 is
  # restarted first, the wait on slot-1 times out, slot-3 is never touched
  RUNNERCTL_STUB_BUSY_POLLS=99 run restart 1 0 2 --when-idle --timeout=5
  expect_rc 1
  expect_log_order "^systemctl restart $U2\$" '^probe:pause 5$'
  expect_log_count '^systemctl restart ' 1
  expect_no_log "^systemctl restart $U1\$"
  expect_no_log "^systemctl restart $U3\$"
  expect_err '^  already restarted: example\.slot-2$'
  expect_err '^  busy or unreadable, not restarted: example\.slot-1$'
  expect_err '^  idle but not restarted \(queued after the busy one\): example\.slot-3$'
}

# drain = stop --when-idle: an idle slot is stopped at once, no pause.
case_drain_idle_slot_stops_immediately() {
  run drain 1
  expect_rc 0
  expect_out '^stop done\.$'
  expect_no_out '^waiting for'
  expect_no_log '^probe:pause '
  expect_log "^systemctl stop $U2\$"
  expect_log_count '^systemctl stop ' 1
}

# drain with no target stops every slot in order; --timeout is honoured.
case_drain_all_waits_for_busy_slot() {
  RUNNERCTL_STUB_BUSY_POLLS=1 run drain --timeout 60
  expect_rc 0
  expect_log_count '^probe:pause 5$' 1
  expect_log_order '^probe:pause 5$' "^systemctl stop $U1\$" "^systemctl stop $U2\$" "^systemctl stop $U3\$"
  expect_log_count '^systemctl stop ' 3
}

# (no access): idle cannot be proven and waiting cannot change that, so the
# command refuses at once — no pause, no systemctl, a journal-access hint.
case_restart_when_idle_no_access_refuses() {
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 run restart --when-idle
  expect_rc 1
  expect_err 'cannot tell whether example\.slot-1 is idle'
  expect_err 'journal read access \(systemd-journal group\) or root'
  expect_no_log '^probe:pause '
  expect_no_log '^systemctl restart '
  expect_no_out '^waiting for'
}

# apply --when-idle without --restart has nothing to wait for: die before
# any drop-in is written.
case_apply_when_idle_needs_restart() {
  run apply --when-idle
  expect_rc 1
  expect_err '--when-idle only applies to the restart'
  expect_no_log '.'
}

# apply --restart --when-idle: drop-ins and the reload happen first (they
# kill nothing), then each restart waits for its slot.
case_apply_restart_when_idle_waits_per_slot() {
  RUNNERCTL_STUB_BUSY_POLLS=2 run apply --restart --when-idle
  expect_rc 0
  expect_log_count 'tee .*/10-runnerctl\.conf$' 3
  expect_log_order '^systemctl daemon-reload$' '^probe:pause 5$' '^probe:pause 5$' \
                   "^systemctl restart $U1\$" "^systemctl restart $U2\$" "^systemctl restart $U3\$"
  expect_log_count '^probe:pause 5$' 2
  expect_out 'Restarted all runner slots \(config active now\)\.'
}

# scale 1 --when-idle: slot-1 stays (enable --now, never waited on); slot-2
# and slot-3 are stopped after an idle check each — slot-2 idle, slot-3 not
# running, so no pause — and GHR-5's write → reload → enable/disable order
# is unchanged.
case_scale_when_idle_checks_before_each_stop() {
  run scale 1 --when-idle
  expect_rc 0
  expect_log_order "tee .*/$U1\\.d/10-runnerctl\\.conf\$" '^systemctl daemon-reload$' \
                   "^systemctl enable --now $U1\$" \
                   "^probe:unit_props $U2\$" "^systemctl disable --now $U2\$" \
                   "^probe:unit_props $U3\$" "^systemctl disable --now $U3\$"
  expect_no_log '^probe:pause '
  expect_no_log "^probe:unit_props $U1\$"
  expect_out "^  \\[stopped\\] $U2\$"
  expect_out "^  \\[stopped\\] $U3\$"
  expect_out "^Scaled to 1 active runner\\(s\\)"
}

# scale 2 --when-idle --restart: the restart of the kept slots waits too.
case_scale_when_idle_restart_waits() {
  RUNNERCTL_STUB_BUSY_POLLS=2 run scale 2 --when-idle --restart
  expect_rc 0
  expect_log_order "^systemctl disable --now $U3\$" '^probe:pause 5$' '^probe:pause 5$' \
                   "^systemctl restart $U1\$" "^systemctl restart $U2\$"
  expect_log_count '^probe:pause 5$' 2
  expect_log_count '^systemctl restart ' 2
}

# (scale's stop side can only wait on slot-2/3, both idle in the fixture, and
# N>=1 always keeps slot-1 — so its timeout path is the shared wait_idle path
# the stop/restart cases above already drive.)

# --timeout must be an integer; start ignores --when-idle without complaint.
case_restart_timeout_not_integer() {
  run restart --timeout abc
  expect_rc 1
  expect_err "--timeout value 'abc' is invalid"
  expect_no_log '.'
}

case_restart_timeout_missing_value() {
  run restart 0 --timeout
  expect_rc 1
  expect_err '--timeout needs a value'
  expect_no_log '.'
}

case_start_ignores_when_idle() {
  run start --when-idle
  expect_rc 0
  expect_out '^start done\.$'
  expect_no_log '^probe:'
  expect_log_count '^systemctl start ' 3
}

# --- GHR-2: idle time and jobs-since-start inside the idle WORKING-ON cell ---
# Same journal fetch as GHR-10, read a second time by journal_idle_info: the
# stub's slot-2 completed `lint` and `build`, the last one 2h31m before the
# pinned now_epoch (see tests/stub.config). "no jobs yet" falls back to the
# active-enter stamp (slot-2: 41m, slot-1: 3d 4h — the SINCE column's clock).

case_status_idle_time_and_job_count() {
  run status
  expect_rc 0
  # slot-2: time since the last completion, count of completions — exact,
  # and plural
  expect_out '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
  expect_no_out '^1 +example\.slot-2 .* idle$'
  expect_no_out '\(1 job\)'
  # the running slot and the stopped one are untouched by it
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_out '^2 +example\.slot-3 .* —$'
  expect_no_out '^note: '
  # still ONE journal read per running slot: the idle info is parsed from
  # the same lines, not fetched again
  expect_log_count '^probe:journal_job_lines ' 2
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

case_status_idle_no_jobs_yet_since_active_enter() {
  RUNNERCTL_STUB_JOURNAL_EMPTY=1 run status
  expect_rc 0
  # a readable journal with no completion since the unit started: idle since
  # ActiveEnterTimestampMonotonic, said distinctly — slot-2 41m, slot-1 3d 4h
  expect_out '^1 +example\.slot-2 .* idle 41m \(no jobs yet\)$'
  expect_out '^0 +example\.slot-1 .* idle 3d 4h \(no jobs yet\)$'
  expect_out '^2 +example\.slot-3 .* —$'
  expect_no_out '\(0 jobs\)'
  # readable journal → no access hint
  expect_no_out '^note: '
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

case_status_idle_unknown_without_journal() {
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 RUNNERCTL_STUB_CGROUP_READABLE=1 run status
  expect_rc 0
  # journal unreadable, cgroup readable (root / the runner user): the
  # /proc-only reader sees slot-2 idle but cannot say for how long → `idle ?`,
  # never a bare `idle`, never a fabricated duration
  expect_out '^1 +example\.slot-2 .* idle \?$'
  expect_no_out '^1 +example\.slot-2 .* idle$'
  expect_no_out '^1 +example\.slot-2 .* idle [0-9]'
  # slot-1 is still identified from /proc (GITHUB_* environ), slot-3 stays —
  expect_out '^0 +example\.slot-1 .* my-app:test$'
  expect_out '^2 +example\.slot-3 .* —$'
  expect_no_out '\(no access\)'
  # `idle ?` earns the same one-line hint `(no access)` does, once
  _expect
  local n
  n="$(grep -Ec '^note: WORKING-ON needs journal read access \(systemd-journal group\) or root$' <<<"$OUT" || true)"
  [ "$n" -eq 1 ] || FAILS+=("hint line: want exactly 1, got $n")
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

# The idle parser alone, over a fixed transcript.
case_journal_idle_info_last_completion_and_count() {
  run_fn journal_idle_info "$(printf '%s\n' \
    '1000000000.000000 runsvc.sh[1]: 2001-09-09 01:46:40Z: Running job: lint' \
    '1000000100.000000 runsvc.sh[1]: 2001-09-09 01:48:20Z: Job lint completed with result: Failed' \
    '1000000200.000000 runsvc.sh[1]: 2001-09-09 01:50:00Z: Running job: test (ubuntu, 3.12)' \
    '1000000350.000000 runsvc.sh[1]: 2001-09-09 01:52:30Z: Job test (ubuntu, 3.12) completed with result: Succeeded')"
  expect_rc 0
  # the epoch second of the LAST completion (not the first, not a start
  # line), and the number of completions regardless of their result
  expect_out $'^1000000350\t2$'
  expect_no_out '^1000000100'
  expect_no_out '^1000000200'
}

case_journal_idle_info_none_completed() {
  run_fn journal_idle_info "$(printf '%s\n' \
    '1000000000.000000 runsvc.sh[1]: 2001-09-09 01:46:40Z: Running job: lint')"
  expect_rc 0
  expect_no_out '.'
  run_fn journal_idle_info ''
  expect_rc 0
  expect_no_out '.'
}

case_journal_idle_info_single_job_is_singular() {
  run_fn journal_idle_info "$(printf '%s\n' \
    '1000000000.000000 runsvc.sh[1]: 2001-09-09 01:46:40Z: Running job: lint' \
    '1000000100.000000 runsvc.sh[1]: 2001-09-09 01:48:20Z: Job lint completed with result: Canceled')"
  expect_rc 0
  expect_out $'^1000000100\t1$'
  # and the cell says `1 job`, not `1 jobs`: job_info with its two journal
  # sources overridden inline (the stub table has no one-job slot)
  run_fn eval 'journal_job_lines() { echo "1000000100.000000 x: Job lint completed with result: Canceled"; }
               now_epoch() { echo 1000000400; }
               job_info u.service /system.slice/u.service inv 0'
  expect_rc 0
  expect_out '^idle 5m \(1 job\)$'
}

# --- GHR-8: status shows restart count, last exit reason and peak memory ----
# The stub's slot-2 has NRestarts=3 with Result=success (unit_props) and
# journal_restart_reason stubbed to answer "oom-kill" for it only; slot-1 has
# NRestarts=0 but carries MemoryPeak (25.0G); slot-3 has neither. See
# tests/stub.config.

case_status_active_cell_shows_restart_count_and_reason() {
  run status
  expect_rc 0
  # exact ACTIVE cell: ActiveState/SubState, ↻N, and the journal's reason —
  # only reached because Result is success (nothing else says why already).
  expect_out '^1 +example\.slot-2 +— +active/running ↻3 \(last: oom-kill\) +41m '
}

case_status_no_restarts_keeps_active_cell_plain() {
  run status
  expect_rc 0
  # slot-1 has NRestarts=0: no ↻, no journal consulted, no annotation at all.
  expect_out '^0 +example\.slot-1 +— +active/running +3d 4h '
  expect_no_out '^0 +example\.slot-1 .*↻'
}

case_status_used_shows_current_over_peak_when_present() {
  run status
  expect_rc 0
  # slot-1 carries MemoryPeak: USED is current/peak, both `hbytes`-formatted.
  expect_out '^0 +example\.slot-1 .* +1\.0G/25\.0G +always '
}

case_status_used_stays_current_only_without_peak() {
  run status
  expect_rc 0
  # slot-2 has no MemoryPeak: USED is unchanged, current only, no slash.
  expect_out '^1 +example\.slot-2 .* +1\.0G +always '
  expect_no_out '^1 +example\.slot-2 .* +1\.0G/'
}

case_status_journal_restart_reason_consulted_once_and_only_for_restarted_slot() {
  run status
  expect_rc 0
  # one extra journalctl fork per slot, only when NRestarts > 0: slot-2 alone.
  expect_log_count '^probe:journal_restart_reason ' 1
  expect_log '^probe:journal_restart_reason actions\.runner\.example\.slot-2\.service$'
  expect_no_log '^probe:journal_restart_reason actions\.runner\.example\.slot-1'
  expect_no_log '^probe:journal_restart_reason actions\.runner\.example\.slot-3'
}

# The normaliser alone, over fixed journal lines (systemd's own strings, not
# yet verified against a host's journal — see journal_restart_reason).
case_journal_restart_reason_line_oom_kill() {
  run_fn journal_restart_reason_line \
    'Sep 12 10:00:00 host systemd[1]: actions.runner.example.slot-2.service: A process of this unit has been killed by the OOM killer.'
  expect_rc 0
  expect_out '^oom-kill$'
}

case_journal_restart_reason_line_exit_code() {
  run_fn journal_restart_reason_line \
    'Sep 12 10:00:00 host systemd[1]: actions.runner.example.slot-2.service: Main process exited, code=exited, status=137/n/a'
  expect_rc 0
  expect_out '^exit-code 137$'
}

case_journal_restart_reason_line_signal() {
  run_fn journal_restart_reason_line \
    'Sep 12 10:00:00 host systemd[1]: actions.runner.example.slot-2.service: Main process exited, code=killed, status=9/KILL'
  expect_rc 0
  expect_out '^signal KILL$'
}

case_journal_restart_reason_line_no_match() {
  run_fn journal_restart_reason_line \
    'Sep 12 10:00:00 host systemd[1]: actions.runner.example.slot-2.service: Started.'
  expect_rc 0
  expect_no_out '.'
}

# --- Registry -----------------------------------------------------------------
t "status: header and one row per discovered slot"                 case_status_table
t "status: one unit_props call per slot, not one per column"        case_status_one_unit_props_call_per_slot
t "status: EnvironmentFiles value with embedded '=' survives"       case_status_envfile_value_with_embedded_equals
t "apply: ci drop-in on every slot, then one daemon-reload"        case_apply_ci
t "apply --restart with flag overrides: restart after reload"      case_apply_restart_flags
t "apply --profile deploy: refuses without the env file"           case_apply_deploy_refuses_without_env_file
t "apply --profile deploy: writes EnvironmentFile drop-ins"        case_apply_deploy_writes_with_env_file
t "apply --profile nope: unknown profile"                          case_apply_unknown_profile
t "apply --max: missing value dies cleanly, no privileged call"    case_apply_max_missing_value
t "apply --profile=deploy: = form reaches the deploy profile"      case_apply_profile_equals_form_reaches_deploy
t "apply --max=30G --restart-sec=5: = form writes both values"     case_apply_max_and_restart_sec_equals_form
t "apply --max lots: invalid value rejected"                       case_apply_max_invalid_value_rejected
t "apply --restart-sec soon: invalid value rejected"               case_apply_restart_sec_invalid_value_rejected
t "upgrade --ref: missing value dies before any download"          case_upgrade_ref_missing_value
t "scale 2: two drop-ins, enable 1-2, disable 3, one reload"       case_scale_2
t "scale 2: daemon-reload before enable --now"                     case_scale_reloads_before_enable
t "scale 2: a failed slot is reported, not swallowed"              case_scale_start_failure_reported
t "scale 2 --restart: restarts the now-active slots"               case_scale_restart_flag_restarts_active_slots
t "scale 0: out of range"                                          case_scale_zero_rejected
t "scale abc: not an integer"                                      case_scale_non_integer_rejected
t "scale: N missing"                                               case_scale_missing_n
t "env-init: refuses to clobber an existing env file"              case_env_init_refuses_to_clobber
t "env-init: scaffolds root:root 600 from the template"            case_env_init_scaffolds
t "env-init: ci profile has no EnvironmentFile"                    case_env_init_ci_has_no_env_file
t "remove-limits: rm -f on every slot, then daemon-reload"         case_remove_limits
t "restart 1: slot index resolves to the second unit"              case_restart_by_index
t "stop: every slot in discovery order"                            case_stop_all
t "enable <unit>: full unit name passes through"                   case_enable_by_unit_name
t "logs 2: journalctl on the third unit"                           case_logs_by_index
t "restart 5: out of range exits 1 without a systemctl call"       case_restart_out_of_range
t "restart example.slot-2: short RUNNER name resolves"             case_restart_by_short_name
t "logs slot-3: unambiguous substring of the short name resolves"  case_logs_by_substring
t "enable example.slot-1.service: short name + suffix resolves"    case_enable_by_short_name_with_service_suffix
t "restart slot: ambiguous target, no systemctl call"               case_restart_ambiguous_target
t "restart nope: no match, no systemctl call"                       case_restart_no_match
t "status: SINCE of active slots from ActiveEnterTimestampMonotonic" case_status_since_active_slots
t "status: SINCE of an inactive slot from InactiveEnterTimestampMonotonic" case_status_since_inactive_slot_uses_inactive_enter
t "status: — cells keep the columns aligned (character padding)"     case_status_dash_cells_keep_columns_aligned
t "status: job runtime inside the WORKING-ON cell"                  case_status_job_runtime_in_working_on
t "status: WORKING-ON from the journal (running / idle / —)"        case_status_working_on_from_journal
t "status: (no access) is distinct from —, hint printed once"        case_status_no_access_is_not_stopped
t "journal_running_job: last Running job without a later completion" case_journal_running_job_last_uncompleted
t "journal_running_job: nothing once the last job completed"         case_journal_running_job_idle_after_completion
t "status: idle slot shows time since last completion and job count" case_status_idle_time_and_job_count
t "status: idle with no completion yet is measured from active-enter"  case_status_idle_no_jobs_yet_since_active_enter
t "status: idle ? without journal access, with the hint"              case_status_idle_unknown_without_journal
t "journal_idle_info: last completion stamp and count"                case_journal_idle_info_last_completion_and_count
t "journal_idle_info: nothing without a completion"                   case_journal_idle_info_none_completed
t "journal_idle_info / job_info: one completion reads '1 job'"        case_journal_idle_info_single_job_is_singular
t "fmt_dur 5: 5s"                                                   case_fmt_dur_seconds
t "fmt_dur 0: 0s"                                                   case_fmt_dur_zero
t "fmt_dur 2460: 41m"                                               case_fmt_dur_minutes
t "fmt_dur 11520: 3h12m"                                            case_fmt_dur_hours_minutes
t "fmt_dur 7200: 2h"                                                case_fmt_dur_whole_hours
t "fmt_dur 273600: 3d 4h"                                           case_fmt_dur_days_hours
t "fmt_dur 518400: 6d"                                              case_fmt_dur_whole_days
t "fmt_dur '': —"                                                   case_fmt_dur_empty
t "fmt_dur -30: —"                                                  case_fmt_dur_negative
t "fmt_dur n/a: —"                                                  case_fmt_dur_non_numeric
t "since_state: never-entered stamps give —"                        case_since_state_never_entered
t "logs: no target logs all discovered slots"                       case_logs_all_slots_default
t "logs 1 -f: follow defaults -n to 50"                              case_logs_follow_defaults_to_50
t "logs 1 -n 20 --since -g: all pass through to journalctl"        case_logs_lines_since_grep
t "logs 1 -n: missing value dies, no journalctl call"               case_logs_lines_missing_value
t "logs 1 --bogus: unknown option dies, no journalctl call"         case_logs_unknown_flag
t "logs nope: no match, no journalctl call"                          case_logs_no_match
t "apply --profile deploy 2: writes only slot-3's drop-in"          case_apply_targeted_single_slot_with_profile
t "apply 0 example.slot-2: index + short name, two drop-ins"        case_apply_targeted_multiple_by_index_and_name
t "apply nope: resolve error, no privileged call at all"            case_apply_target_no_match
t "remove-limits 1: rm -f on slot-2 only, then daemon-reload"       case_remove_limits_targeted
t "scale 2 extra: stray argument dies, no privileged call"          case_scale_rejects_stray_argument
t "status: PROFILE column reads each slot's seeded drop-in"         case_status_shows_profile_column
t "restart --when-idle: 3 busy polls, then slot-1, then 2 and 3"     case_restart_when_idle_waits_then_rolls
t "stop 0 --when-idle --timeout 10: times out, stops nothing"        case_stop_when_idle_times_out
t "restart 1 0 2 --when-idle: timeout lists done/busy/queued slots"  case_restart_when_idle_timeout_reports_handled_and_queued
t "drain 1: idle slot stops at once, no pause"                       case_drain_idle_slot_stops_immediately
t "drain --timeout 60: waits for slot-1, stops all in order"         case_drain_all_waits_for_busy_slot
t "restart --when-idle: (no access) refuses, no wait, no restart"    case_restart_when_idle_no_access_refuses
t "apply --when-idle: needs --restart, writes nothing"               case_apply_when_idle_needs_restart
t "apply --restart --when-idle: reload first, then wait per slot"    case_apply_restart_when_idle_waits_per_slot
t "scale 1 --when-idle: idle check before each disable, order kept"  case_scale_when_idle_checks_before_each_stop
t "scale 2 --when-idle --restart: restarts wait too"                 case_scale_when_idle_restart_waits
t "restart --timeout abc: not an integer"                            case_restart_timeout_not_integer
t "restart 0 --timeout: missing value"                               case_restart_timeout_missing_value
t "start --when-idle: flag ignored, no probes"                       case_start_ignores_when_idle

# --- GHR-8: restart count, last exit reason and peak memory in status -------
t "status: ACTIVE cell shows ↻N and the journal's last-restart reason" case_status_active_cell_shows_restart_count_and_reason
t "status: no restarts leaves ACTIVE plain, no ↻, no journal call"    case_status_no_restarts_keeps_active_cell_plain
t "status: USED is current/peak when MemoryPeak is present"           case_status_used_shows_current_over_peak_when_present
t "status: USED stays current-only without MemoryPeak"                case_status_used_stays_current_only_without_peak
t "status: journal_restart_reason asked once, only for the restarted slot" case_status_journal_restart_reason_consulted_once_and_only_for_restarted_slot
t "journal_restart_reason_line: OOM killer sentence -> oom-kill"      case_journal_restart_reason_line_oom_kill
t "journal_restart_reason_line: code=exited,status=137 -> exit-code 137" case_journal_restart_reason_line_exit_code
t "journal_restart_reason_line: code=killed,status=9/KILL -> signal KILL" case_journal_restart_reason_line_signal
t "journal_restart_reason_line: unrelated line -> nothing"            case_journal_restart_reason_line_no_match

# --- Summary ------------------------------------------------------------------
echo
echo "sim: $npass ok, $nxfail xfail (${XFAIL_KEYS# }), $nfail failed"
if [ "$nfail" -gt 0 ]; then
  printf '  FAIL %s\n' "${FAILED[@]}"
  exit 1
fi
