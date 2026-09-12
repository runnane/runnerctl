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
#   run_fn <function> <args...>    call one of runnerctl's own helpers (e.g.
#                                  fmt_dur) directly: sources the script with
#                                  RUNNERCTL_NO_MAIN=1, no config, no command;
#                                  sets OUT ERR RC, the log stays empty
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

expect_file() {
  _expect
  if [ ! -f "$WRITES$1" ]; then FAILS+=("nothing written to $1"); return 0; fi
  grep -Eq -- "$2" "$WRITES$1" || FAILS+=("$1 has no line matching /$2/")
}

expect_file_lacks() {
  _expect
  if [ ! -f "$WRITES$1" ]; then FAILS+=("nothing written to $1"); return 0; fi
  ! grep -Eq -- "$2" "$WRITES$1" || FAILS+=("$1 has a line matching /$2/")
}

expect_no_file() {
  _expect
  [ ! -e "$WRITES$1" ] || FAILS+=("$1 was written")
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
DROPIN_DIR="/etc/systemd/system"
DEPLOY_ENV="/etc/runnerctl/deploy.env"

case_status_table() {
  run status
  expect_rc 0
  expect_out '^IDX +RUNNER +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +RESTART +ENVFILE +WORKING-ON$'
  expect_out '^0 +example\.slot-1 +active/running +3d 4h +enabled +26\.0G +22\.0G +1\.0G +always +— +my-app:test \(12m\)$'
  expect_out '^1 +example\.slot-2 +active/running +41m +enabled '
  expect_out '^2 +example\.slot-3 +inactive/dead +6d +disabled +— +— +— +always +— +—$'
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
  expect_out '^1 +example\.slot-2 .*/etc/x \(ignore_errors=no\) +idle$'
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
# tests/stub.config); the worker-runtime read inside job_info is stubbed away
# with the rest of job_info and is NOT covered here.

case_status_since_active_slots() {
  run status
  expect_rc 0
  # active slots: SINCE is measured from ActiveEnterTimestampMonotonic
  expect_out '^0 +example\.slot-1 +active/running +3d 4h +enabled '
  expect_out '^1 +example\.slot-2 +active/running +41m +enabled '
}

case_status_since_inactive_slot_uses_inactive_enter() {
  run status
  expect_rc 0
  # slot-3 was last active 8d ago and went inactive 6d ago: an inactive slot
  # is measured from InactiveEnterTimestampMonotonic, so 6d, never 8d.
  expect_out '^2 +example\.slot-3 +inactive/dead +6d +disabled '
  expect_no_out '^2 +example\.slot-3 +inactive/dead +8d '
}

case_status_job_runtime_in_working_on() {
  run status
  expect_rc 0
  # the runtime rides inside the WORKING-ON cell; the column count is unchanged
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_out '^1 +example\.slot-2 .* idle$'
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
  expect_out '^2 +example\.slot-3 +inactive/dead +6d +disabled +— +— +— +always +— +—$'
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

# --- Summary ------------------------------------------------------------------
echo
echo "sim: $npass ok, $nxfail xfail (${XFAIL_KEYS# }), $nfail failed"
if [ "$nfail" -gt 0 ]; then
  printf '  FAIL %s\n' "${FAILED[@]}"
  exit 1
fi
