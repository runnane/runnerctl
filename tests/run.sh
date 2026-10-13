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
#                                  (resets LOG and WRITES first); killed
#                                  after RUN_TIMEOUT seconds (default 30)
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
#   expect_out_count P N           exactly N stdout lines match
#   expect_err P / expect_no_err P some stderr line matches / none does
#   expect_log P / expect_no_log P some privileged call matches / none does
#   expect_log_count P N           exactly N privileged calls match
#   expect_log_order P1 P2 ...     matches occur in this order (subsequence)
#   expect_file PATH P             the file `tee`d to PATH exists and matches
#   expect_file_lacks PATH P       it exists and no line matches
#   expect_no_file PATH            nothing was written to PATH
#   expect_json PY-EXPR            stdout parses as JSON and the Python
#                                  expression over `d` (the parsed object) is
#                                  true — needs python3; guard with
#                                  `$HAVE_PYTHON3` and `skip`
#   skip <notice>                  print a skip notice for a check this box
#                                  cannot run; not a failure, and NOT an
#                                  expectation — the case must still assert
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
# Colour off for every run (GHR-27): with RUNNERCTL_STUB_TTY=1 `--color auto`
# would otherwise paint the watch frames and the row regexes would stop
# matching. The colour cases pass `--color always`, or `NO_COLOR=` (empty =
# unset, per no-color.org) to exercise the auto decision.
export NO_COLOR=1
# `provision` falls back to $GITHUB_TOKEN as its PAT (GHR-45). A developer box
# usually has one exported, which would silently authenticate the stubbed API
# calls and make the "no credentials" cases pass for the wrong reason — so the
# run decides, not the caller's environment. A case that wants one sets it.
unset GITHUB_TOKEN
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
# Every run is bounded by RUN_TIMEOUT seconds (GHR-3): a command that never
# returns — a `watch` loop that lost its guard, with the stub's no-op pause —
# fails its case instead of hanging the gate.
RUN_TIMEOUT="${RUN_TIMEOUT:-30}"

run() {
  : >"$LOG"; rm -f "$LOG.cols" "$LOG.lines" "$LOG.clock"
  rm -rf "$WRITES"; mkdir -p "$WRITES"
  RC=0
  OUT="$(RUNNERCTL_CONFIG="$STUB" RUNNERCTL_TEST_LOG="$LOG" RUNNERCTL_TEST_WRITES="$WRITES" \
         timeout "$RUN_TIMEOUT" "$RUNNERCTL" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# Like `run`, but does not reset WRITES first (LOG still is) — for a case
# that seeds the writes-mirror tree with seed_dropin before running a
# read-only command that reads it back (status's PROFILE column).
run_keep() {
  : >"$LOG"; rm -f "$LOG.cols" "$LOG.lines" "$LOG.clock"
  RC=0
  OUT="$(RUNNERCTL_CONFIG="$STUB" RUNNERCTL_TEST_LOG="$LOG" RUNNERCTL_TEST_WRITES="$WRITES" \
         timeout "$RUN_TIMEOUT" "$RUNNERCTL" "$@" 2>"$TMP/err")" || RC=$?
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
  : >"$LOG"; rm -f "$LOG.cols" "$LOG.lines" "$LOG.clock"
  RC=0
  OUT="$(RUNNERCTL_NO_MAIN=1 bash -c '. "$0" && "$@"' "$RUNNERCTL" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# --- Running against a config of the case's own (GHR-58) ----------------------
# `--save` REWRITES the config it is handed, so the --save cases cannot use
# $STUB — they would rewrite a tracked file. Each builds a config of its own
# that sources the stub (so the systemd shadows are still in force) and points
# the run at that. Their assertions read that real file rather than the
# writes-mirror: a config the invoking user owns needs no run_priv, so it is
# written for real, which is the path an operator is on too.
save_config() { # PATH   (further config body on stdin)
  { echo ". $PWD/$STUB"; cat; } >"$1"
}

run_cfg() { # CONFIG-PATH ARGS...
  local cfg="$1"; shift
  : >"$LOG"; rm -f "$LOG.cols" "$LOG.lines" "$LOG.clock"
  rm -rf "$WRITES"; mkdir -p "$WRITES"
  RC=0
  OUT="$(RUNNERCTL_CONFIG="$cfg" RUNNERCTL_TEST_LOG="$LOG" RUNNERCTL_TEST_WRITES="$WRITES" \
         timeout "$RUN_TIMEOUT" "$RUNNERCTL" "$@" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# Source the script's functions plus the stub, then eval SNIPPET with
# CONFIG-PATH in force. The white-box hatch for a path no CLI run can reach:
# save_profile's create-the-config branch is one, because under the stub the
# config file IS the stub and therefore always exists, and a run with no
# config at all dies at require_runners long before the save.
run_snippet() { # CONFIG-PATH SNIPPET
  : >"$LOG"; rm -f "$LOG.cols" "$LOG.lines" "$LOG.clock"
  RC=0
  # shellcheck disable=SC2016  # the child expands $1/$2/$3, not this shell
  OUT="$(RUNNERCTL_NO_MAIN=1 RUNNERCTL_CONFIG="$1" RUNNERCTL_TEST_LOG="$LOG" RUNNERCTL_TEST_WRITES="$WRITES" \
         timeout "$RUN_TIMEOUT" bash -c '. "$1"; . "$2"; eval "$3"' bash "$RUNNERCTL" "$STUB" "$2" 2>"$TMP/err")" || RC=$?
  ERR="$(cat "$TMP/err")"
}

# expect_file and friends resolve through the writes-mirror; these take a real
# path, for the config files the --save cases write and read back.
expect_cfg() { # PATH PATTERN
  _expect
  grep -Eq -- "$2" "$1" 2>/dev/null || FAILS+=("$1 has no line matching /$2/")
}

expect_cfg_lacks() { # PATH PATTERN
  _expect
  ! grep -Eq -- "$2" "$1" 2>/dev/null || FAILS+=("$1 has a line matching /$2/")
}

expect_cfg_count() { # PATH PATTERN N
  _expect
  local n; n="$(grep -Ec -- "$2" "$1" 2>/dev/null || true)"
  [ "$n" -eq "$3" ] || FAILS+=("$1 lines matching /$2/: want $3, got $n")
}

expect_same_file() { # PATH PATH
  _expect
  cmp -s "$1" "$2" || FAILS+=("$1 differs from $2")
}

expect_no_path() { # PATH
  _expect
  [ ! -e "$1" ] || FAILS+=("$1 exists and should not")
}

expect_mode() { # PATH MODE
  _expect
  local m; m="$(stat -c '%a' "$1" 2>/dev/null || echo none)"
  [ "$m" = "$2" ] || FAILS+=("$1 mode: want $2, got $m")
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

expect_out_count() {
  _expect
  local n
  n="$(grep -Ec -- "$1" <<<"$OUT" || true)"
  [ "$n" -eq "$2" ] || FAILS+=("stdout lines matching /$1/: want $2, got $n")
}

expect_err() {
  _expect
  grep -Eq -- "$1" <<<"$ERR" || FAILS+=("stderr has no line matching /$1/")
}

# The negative of expect_err. Added for GHR-45, where the claim under test is
# that a credential reaches NEITHER stream — asserting only on stdout would
# pass a version that printed the token in an error message.
expect_no_err() {
  _expect
  ! grep -Eq -- "$1" <<<"$ERR" || FAILS+=("stderr has a line matching /$1/ and should not")
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

# GHR-16: assert on the parsed JSON in OUT — EXPR is a Python expression
# over `d`, the object json.load gave back, so a shape or value check reads
# as one line (`d["slots"][1]["restarts"] == 3`). A stdout that is not JSON
# fails the expectation with the parser's message. Needs python3: guard the
# case with HAVE_PYTHON3 and `skip` (below) where it may be absent.
HAVE_PYTHON3=false
command -v python3 >/dev/null 2>&1 && HAVE_PYTHON3=true
expect_json() {
  _expect
  local err
  # PYTHON_COLORS=0: python >= 3.13 colours its tracebacks, and the escape
  # codes would land in the failure report.
  err="$(PYTHON_COLORS=0 python3 -c 'import json,sys; d=json.load(sys.stdin); e=sys.argv[1]; assert eval(e), e' "$1" <<<"$OUT" 2>&1)" \
    || FAILS+=("json: $1 (${err##*$'\n'})")
}

# A notice that part of a case could not run on this box (an optional tool
# is missing). Not a failure and not an expectation — a case that skips must
# still assert something, or it fails as making no assertions.
skip() { echo "skip  $*"; }

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
  # GHR-32: the header leads with the version this script carries
  expect_out_count '^runnerctl [0-9]+\.[0-9]+\.[0-9]+ — Host: [0-9]+ cores, ' 1
  # GHR-34: host_line() is stubbed, so the fragment after "Host: " is exact,
  # not just shaped — this is what made the --color always diff case flake.
  # GHR-64: the stubbed root drive rides on the same line, and an empty
  # event window adds nothing to it.
  expect_out '^runnerctl [0-9]+\.[0-9]+\.[0-9]+ — Host: 16 cores, 64Gi RAM, 48Gi available — Disk: / \[docker,work\] 24% \(353\.9G free\)$'
  expect_out '^IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +PRESS +RESTART +ENVFILE +WORKING-ON$'
  # slot-1 also carries MemoryPeak (GHR-8), so USED is current/peak; PRESS
  # is — until the stub answers cgroup_memory_facts (GHR-31).
  expect_out '^0 +example\.slot-1 +— +active/running +3d 4h +enabled +26\.0G +22\.0G +1\.0G/25\.0G +— +always +— +my-app:test \(12m\)$'
  # slot-2 has restarted (GHR-8): the ACTIVE cell carries ↻3 and the
  # journal-derived reason, so the plain "active/running" is followed by
  # that annotation before SINCE, not by spaces straight to 41m.
  expect_out '^1 +example\.slot-2 +— +active/running .* +41m +enabled '
  expect_out '^2 +example\.slot-3 +— +inactive/dead +6d +disabled +— +— +— +— +always +— +—$'
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
  expect_out "^Applied profile 'ci': Restart=always RestartSec=10 OOMPolicy=continue MemoryMax=26G MemoryHigh=25G MemorySwapMax=0$"
  expect_out 'Config takes effect on next'
  expect_log_count "tee $DROPIN_DIR/$U1\\.d/10-runnerctl\\.conf" 1
  expect_log_count 'tee .*/10-runnerctl\.conf$' 3
  expect_log_order "mkdir -p $DROPIN_DIR/$U1\\.d" "tee .*/$U1\\.d/" "tee .*/$U2\\.d/" "tee .*/$U3\\.d/" '^systemctl daemon-reload$'
  expect_log_count '^systemctl daemon-reload$' 1
  expect_no_log '^systemctl restart'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryMax=26G$'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryHigh=25G$'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^RestartSec=10$'
  expect_file_lacks "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^EnvironmentFile='
  # GHR-28: a step's OOM must not take the unit down, and the cap is RAM-only
  # without a swap cap next to it
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^OOMPolicy=continue$'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemorySwapMax=0$'
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
  expect_out "^Applied profile 'deploy': Restart=always RestartSec=15 OOMPolicy=continue EnvironmentFile=$DEPLOY_ENV\$"
  expect_log_order "^test -f $DEPLOY_ENV\$" "tee .*/$U1\\.d/" "tee .*/$U2\\.d/" "tee .*/$U3\\.d/" '^systemctl daemon-reload$'
  expect_file "$DROPIN_DIR/$U3.d/10-runnerctl.conf" "^EnvironmentFile=$DEPLOY_ENV\$"
  expect_file "$DROPIN_DIR/$U3.d/10-runnerctl.conf" '^# Managed by runnerctl \(profile: deploy\)'
  expect_file_lacks "$DROPIN_DIR/$U3.d/10-runnerctl.conf" '^Memory(Max|High|SwapMax)='
  # GHR-28: the OOM policy is not a size — an uncapped profile gets it too
  expect_file "$DROPIN_DIR/$U3.d/10-runnerctl.conf" '^OOMPolicy=continue$'
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

case_resolve_url_no_ref_unchanged() {
  run_fn eval 'UPGRADE_URL="https://github.com/runnane/runnerctl/releases/latest/download/runnerctl"; resolve_url ""'
  expect_rc 0
  expect_out '^https://github\.com/runnane/runnerctl/releases/latest/download/runnerctl$'
}

case_resolve_url_release_version_ref() {
  run_fn eval 'UPGRADE_URL="https://github.com/runnane/runnerctl/releases/latest/download/runnerctl"; resolve_url v1.2.3'
  expect_rc 0
  expect_out '^https://github\.com/runnane/runnerctl/releases/download/v1\.2\.3/runnerctl$'
}

case_resolve_url_release_version_ref_normalised() {
  run_fn eval 'UPGRADE_URL="https://github.com/runnane/runnerctl/releases/latest/download/runnerctl"; resolve_url 1.2.3'
  expect_rc 0
  expect_out '^https://github\.com/runnane/runnerctl/releases/download/v1\.2\.3/runnerctl$'
}

case_resolve_url_release_branch_ref_falls_back_to_raw() {
  run_fn eval 'UPGRADE_URL="https://github.com/runnane/runnerctl/releases/latest/download/runnerctl"; resolve_url main'
  expect_rc 0
  expect_out '^https://raw\.githubusercontent\.com/runnane/runnerctl/main/runnerctl$'
}

case_resolve_url_raw_url_ref_replaces_segment() {
  run_fn eval 'UPGRADE_URL="https://raw.githubusercontent.com/runnane/runnerctl/main/runnerctl"; resolve_url v1.2.3'
  expect_rc 0
  expect_out '^https://raw\.githubusercontent\.com/runnane/runnerctl/v1\.2\.3/runnerctl$'
}

case_resolve_url_unsupported_url_dies() {
  run_fn eval 'UPGRADE_URL="https://example.com/mirror/runnerctl"; resolve_url v1.2.3'
  expect_rc 1
  expect_err '^runnerctl: --ref only works with a github\.com/<owner>/<repo>/releases/\.\.\. or raw\.githubusercontent\.com UPGRADE_URL \(have: https://example\.com/mirror/runnerctl\)$'
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
  expect_out '^2 +example\.slot-3 +— +inactive/dead +6d +disabled +— +— +— +— +always +— +—$'
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

# --- GHR-3: watch / status --watch redraws the table in place ----------------
# The stub's `stdout_is_tty` answers RUNNERCTL_STUB_TTY (default 0: the
# harness's stdout is a pipe), `term_cursor` only logs, and `pause` is the
# no-op from GHR-11 — so `--iterations N` (test-only) runs N redraws at once.
# Every frame is one printf: ESC[H ESC[2J, the header line, then the table.
FRAME_PREFIX=$'^\033\\[H\033\\[2J'

case_watch_interval_zero_rejected() {
  run watch --interval 0
  expect_rc 1
  expect_err "^runnerctl: --interval value '0' is invalid — want a whole number of seconds, at least 1$"
  expect_no_out '.'
  expect_no_log '^probe:(unit_props|term_cursor|pause)'
}

case_watch_interval_non_integer_rejected() {
  run watch --interval abc
  expect_rc 1
  expect_err "^runnerctl: --interval value 'abc' is invalid"
  expect_no_log '^probe:(unit_props|term_cursor|pause)'
}

# Not a terminal: refuse before touching the cursor or rendering anything,
# and point at the one-shot command.
case_watch_refuses_non_tty() {
  run watch
  expect_rc 1
  expect_err "^runnerctl: watch needs a terminal \(stdout is not a tty\); use 'runnerctl status'$"
  expect_no_out '.'
  expect_no_log '^probe:(unit_props|term_cursor|pause)'
}

# `status -w` (and --watch) is the alias: the non-tty refusal proves it
# reached the watch path instead of printing the table once.
case_status_w_is_the_watch_alias() {
  run status -w
  expect_rc 1
  expect_err '^runnerctl: watch needs a terminal'
  expect_no_out '^IDX '
  run status --watch
  expect_rc 1
  expect_err '^runnerctl: watch needs a terminal'
}

# --once is a plain status: the table once, no frame prefix, no pause.
case_status_once_is_plain_status() {
  run status --once
  expect_rc 0
  expect_out_count '^IDX +RUNNER +PROFILE ' 1
  expect_out '^0 +example\.slot-1 +— +active/running +3d 4h .* my-app:test \(12m\)$'
  expect_no_out "$FRAME_PREFIX"
  expect_no_out '^runnerctl watch —'
  expect_no_log '^probe:(term_cursor|pause)'
  # and journal reads are not memoised outside watch: one per running slot
  expect_log_count '^probe:journal_job_lines ' 2
}

# Three redraws: each frame starts with home+clear on the header line, the
# header names the interval, the table follows, and one pause of the
# interval separates the frames. The cursor is hidden first and restored
# on the way out.
case_watch_three_iterations_redraw_frames() {
  RUNNERCTL_STUB_TTY=1 run watch --iterations 3 --interval 1
  expect_rc 0
  expect_out_count "${FRAME_PREFIX}runnerctl watch — [^ ]+ — [0-9]{2}:[0-9]{2}:[0-9]{2} — every 1s \(Ctrl-C to quit\)$" 3
  expect_out_count "$FRAME_PREFIX" 3
  expect_out_count '^runnerctl watch —' 0
  expect_out_count '^IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +PRESS +RESTART +ENVFILE +WORKING-ON$' 3
  # every frame carries the version header too (GHR-32), with the same
  # pinned host_line() fragment as `status` on every redraw (GHR-34)
  expect_out_count '^runnerctl [0-9]+\.[0-9]+\.[0-9]+ — Host: ' 3
  expect_out_count '^runnerctl [0-9]+\.[0-9]+\.[0-9]+ — Host: 16 cores, 64Gi RAM, 48Gi available — Disk: / \[docker,work\] 24% \(353\.9G free\)$' 3
  # GHR-64: the host journal search is memoised like the per-slot one —
  # one scan for three frames inside JOURNAL_CACHE_TTL.
  expect_log_count '^probe:journal_host_events ' 1
  expect_out_count '^0 +example\.slot-1 .* my-app:test \(12m\)$' 3
  expect_log_count '^probe:pause 1$' 3
  expect_log_count '^probe:unit_props ' 9
  expect_log_order '^probe:term_cursor hide$' '^probe:pause 1$' '^probe:pause 1$' '^probe:pause 1$' '^probe:term_cursor show$'
  expect_log_count '^probe:term_cursor ' 2
  # read-only, like status: no privileged call at all
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

# The journal memo: 12 ticks read slot-1's journal twice (tick 0 and tick
# 10), while unit_props is fetched on every tick. The default interval is 2.
case_watch_journal_memo_refreshes_every_ten_ticks() {
  RUNNERCTL_STUB_TTY=1 run watch --iterations 12
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 12
  expect_out '— every 2s \(Ctrl-C to quit\)$'
  expect_log_count '^probe:pause 2$' 12
  expect_log_count '^probe:journal_job_lines .*slot-1' 2
  expect_log_count '^probe:journal_job_lines .*slot-2' 2
  expect_no_log '^probe:journal_job_lines .*slot-3'
  expect_log_count '^probe:unit_props .*slot-1' 12
  # the memoised cells are still rendered on every frame
  expect_out_count '^0 +example\.slot-1 .* my-app:test \(12m\)$' 12
  expect_out_count '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$' 12
}

# A memoised failure stays a failure until the next refresh: with the
# journal unreadable the /proc fallback runs on every tick from one read.
case_watch_memo_keeps_journal_failure() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_JOURNAL_ACCESS=0 run watch --iterations 3
  expect_rc 0
  expect_log_count '^probe:journal_job_lines .*slot-1' 1
  expect_out_count '^0 +example\.slot-1 .* \(no access\)$' 3
  expect_out_count '^note: WORKING-ON needs journal read access' 3
}

case_watch_unknown_option_rejected() {
  run watch --bogus
  expect_rc 1
  expect_err '^runnerctl: unknown option: --bogus$'
  run status --interval 5
  expect_rc 1
  expect_err '^runnerctl: unknown option: --interval$'
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
  expect_out '^0 +example\.slot-1 .* +1\.0G/25\.0G +— +always '
}

case_status_used_stays_current_only_without_peak() {
  run status
  expect_rc 0
  # slot-2 has no MemoryPeak: USED is unchanged, current only, no slash.
  expect_out '^1 +example\.slot-2 .* +1\.0G +— +always '
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

# --- GHR-16: status --json, the table's facts as one JSON object -------------
# Same stub tables as the table cases (tests/stub.config): slot-1 busy on
# `test` for my-app with MemoryPeak, slot-2 idle after two jobs with three
# restarts and an oom-kill reason, slot-3 stopped; host_facts pinned. The
# values are asserted through python3's parser where there is one (ubuntu-
# latest has it); without it the case keeps its exit-code, shape and
# read-only assertions and prints a skip notice for the rest.

case_status_json_parses_and_carries_the_slot_facts() {
  run status --json
  expect_rc 0
  expect_out '^\{"runnerctl":"[0-9]+\.[0-9]+\.[0-9]+","host":\{"name":"stub-host-1","cores":16,"mem_total":68719476736,"mem_available":51539607552,"disks":\[.*\],"events":\{.*\}\},$'
  expect_out '^ "slots":\[$'
  expect_out '^\]\}$'
  # read-only, like the table: no privileged call at all.
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
  # the note under the table is a per-slot field here, never a stray line.
  expect_no_out '^note:'
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: status --json parse assertions not run"; return 0; fi
  expect_json 'len(d["slots"]) == 3'
  expect_json '{k: v for k, v in d["host"].items() if k not in ("disks", "events")} == {"name": "stub-host-1", "cores": 16, "mem_total": 68719476736, "mem_available": 51539607552}'
  # GHR-32: the version the script carries, so a fleet can be inventoried
  expect_json 'isinstance(d["runnerctl"], str) and len(d["runnerctl"].split(".")) == 3 and all(x.isdigit() for x in d["runnerctl"].split("."))'
  expect_json '[s["idx"] for s in d["slots"]] == [0, 1, 2]'
  expect_json 'd["slots"][0]["unit"] == "actions.runner.example.slot-1.service" and d["slots"][0]["name"] == "example.slot-1"'
  # slot-1: raw bytes, not 26.0G; the running job with its journal stamp.
  expect_json 'd["slots"][0]["job"] == {"repo": "my-app", "name": "test", "since": 1000000000, "stalled": False}'
  expect_json 'd["slots"][0]["memory_max"] == 27917287424 and d["slots"][0]["memory_high"] == 23622320128'
  expect_json 'd["slots"][0]["memory_current"] == 1073741824 and d["slots"][0]["memory_peak"] == 26843545600'
  expect_json 'd["slots"][0]["env_file"] is None and d["slots"][0]["idle_since"] is None and d["slots"][0]["jobs_completed"] is None'
  expect_json 'd["slots"][0]["active"] == "active" and d["slots"][0]["sub"] == "running" and d["slots"][0]["enabled"] == "enabled"'
  expect_json 'd["slots"][0]["restart"] == "always" and d["slots"][0]["restarts"] == 0 and d["slots"][0]["result"] == "success"'
  expect_json 'd["slots"][0]["last_restart_reason"] is None and d["slots"][0]["profile"] is None'
  # SINCE as an epoch second: pinned now_epoch minus the 3d 4h (273600 s) the table shows.
  expect_json 'd["slots"][0]["since"] == 1000000720 - 273600'
  # slot-2: idle since its last completion, two jobs, restart facts, the raw EnvironmentFiles value.
  expect_json 'd["slots"][1]["job"] is None'
  expect_json 'isinstance(d["slots"][1]["idle_since"], int) and d["slots"][1]["idle_since"] == 999991660'
  expect_json 'd["slots"][1]["jobs_completed"] == 2'
  expect_json 'd["slots"][1]["restarts"] == 3 and d["slots"][1]["last_restart_reason"] == "oom-kill"'
  expect_json 'd["slots"][1]["env_file"] == "/etc/x (ignore_errors=no)"'
  expect_json 'd["slots"][1]["memory_peak"] is None'
  # slot-3: stopped — infinity / [not set] become null, since from the inactive-enter stamp.
  expect_json 'd["slots"][2]["active"] == "inactive" and d["slots"][2]["sub"] == "dead" and d["slots"][2]["enabled"] == "disabled"'
  expect_json 'd["slots"][2]["memory_max"] is None and d["slots"][2]["memory_high"] is None and d["slots"][2]["memory_current"] is None'
  expect_json 'd["slots"][2]["job"] is None and d["slots"][2]["idle_since"] is None and d["slots"][2]["jobs_completed"] is None'
  expect_json 'isinstance(d["slots"][2]["since"], int) and d["slots"][2]["since"] == 1000000720 - 518400'
  expect_json 'all(s["working_on_access"] == "ok" for s in d["slots"])'
}

# GHR-38: host.name is null, not an empty string or a missing key, when the
# host cannot say what it is called. A consumer testing `is None` must not
# have to also test for "".
case_status_json_host_name_null_when_unreadable() {
  RUNNERCTL_STUB_HOST_NAME='' run status --json
  expect_rc 0
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: host.name null assertion not run"; return 0; fi
  expect_json '"name" in d["host"] and d["host"]["name"] is None'
  # the rest of the host object is unaffected by the missing name
  expect_json 'd["host"]["cores"] == 16'
}

# GHR-38: a host with no runner units is a well-formed empty payload from
# --json and exit 0 — NOT the table's die. A fleet aggregator has to be able
# to tell "this host has no runners" from "this host did not answer", and an
# abort here makes those two indistinguishable.
case_status_json_no_units_is_empty_slots_not_a_die() {
  RUNNERCTL_STUB_NO_UNITS=1 run status --json
  expect_rc 0
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: empty-slots assertions not run"; return 0; fi
  expect_json 'd["slots"] == []'
  # still self-describing: the envelope is complete, only the slots are empty
  expect_json 'd["host"]["name"] == "stub-host-1" and d["host"]["cores"] == 16'
  expect_json 'isinstance(d["runnerctl"], str)'
}

# GHR-38, the other half: the TABLE still dies on a runner-less host. The
# --json change is deliberately scoped, because someone typing `status` on a
# box with no runners has usually typed it on the wrong box.
case_status_table_no_units_still_dies() {
  RUNNERCTL_STUB_NO_UNITS=1 run status
  expect_rc 1
  expect_err "no 'actions\.runner\.\*\.service' units found on this host\."
}

# Both renderers read one collector: the JSON makes exactly the fetches the
# table makes — one unit_props per slot, one journal fetch per running slot,
# one restart-reason lookup for the restarted slot — never a second one.
case_status_json_same_fetches_as_the_table() {
  run status --json
  expect_rc 0
  expect_log_count '^probe:unit_props ' 3
  expect_log_count '^probe:journal_job_lines ' 2
  expect_log_count '^probe:journal_job_lines actions\.runner\.example\.slot-1\.service ' 1
  expect_log_count '^probe:journal_job_lines actions\.runner\.example\.slot-2\.service ' 1
  expect_log_count '^probe:journal_restart_reason ' 1
}

# PROFILE from a seeded drop-in lands as a string, not — (GHR-15's read).
case_status_json_profile_from_dropin() {
  run status          # establishes TMP/WRITES
  seed_dropin "$U2" deploy
  run_keep status --json
  expect_rc 0
  expect_out '"name":"example.slot-2".*"profile":"deploy"'
  expect_out '"name":"example.slot-1".*"profile":null'
}

# The access states the table prints as (no access) / idle ? / a bare job
# name are one field per slot; the running job seen through /proc alone has
# no journal stamp, so its `since` is null.
case_status_json_working_on_access_states() {
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 run status --json
  expect_rc 0
  expect_no_out '^note:'
  expect_out '"name":"example.slot-1".*"job":null,"idle_since":null,"jobs_completed":null,"working_on_access":"no-access"'
  expect_out '"name":"example.slot-3".*"working_on_access":"ok"'
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 RUNNERCTL_STUB_CGROUP_READABLE=1 run status --json
  expect_rc 0
  # no worker pid visible → no runtime → stalled is unknowable, null
  expect_out '"name":"example.slot-1".*"job":\{"repo":"my-app","name":"test","since":null,"stalled":null\}.*"working_on_access":"no-journal"'
  expect_out '"name":"example.slot-2".*"job":null,"idle_since":null,"jobs_completed":null,"working_on_access":"no-journal"'
}

# idle (no jobs yet): idle_since is the unit's own start, jobs_completed 0.
case_status_json_idle_fresh_counts_from_unit_start() {
  RUNNERCTL_STUB_JOURNAL_EMPTY=1 run status --json
  expect_rc 0
  expect_out '"name":"example.slot-1".*"since":999727120,.*"job":null,"idle_since":999727120,"jobs_completed":0,"working_on_access":"ok"'
}

case_status_json_refuses_watch() {
  run status --json --watch
  expect_rc 1
  expect_err '^runnerctl: --json cannot be combined with --watch'
  expect_no_out '.'
  RUNNERCTL_STUB_TTY=1 run watch --json --iterations 1
  expect_rc 1
  expect_err '^runnerctl: --json cannot be combined with --watch'
  expect_no_out '.'
}

# The escaper alone: backslash and quote, a newline by name, another
# control character as \u00XX, and the empty string.
case_json_str_escapes() {
  run_fn json_str 'a"b\c'
  expect_rc 0
  expect_out '^"a\\"b\\\\c"$'
  run_fn json_str $'x\ny'
  expect_rc 0
  expect_out '^"x\\ny"$'
  run_fn json_str $'t\tab\x01'
  expect_rc 0
  expect_out '^"t\\tab\\u0001"$'
  run_fn json_str ''
  expect_rc 0
  expect_out '^""$'
}

# --- GHR-14: health command for cron/uptime probes --------------------------
# Default stub: slot-1 active/enabled (0 restarts), slot-2 active/enabled (3
# restarts, below the default threshold of 5), slot-3 inactive/disabled (a
# disabled slot down is not a problem) — so plain `health` is healthy.

case_health_default_stub_is_healthy() {
  run health
  expect_rc 0
  expect_out '^ok: 3 slot\(s\) healthy$'
  # Read-only: no privileged call of any kind reaches the stub's log.
  expect_no_log '^(systemctl|tee|rm|mkdir|chown|chmod|test) '
}

case_health_max_restarts_below_default_flags_slot2() {
  run health --max-restarts 3
  expect_rc 1
  expect_out '^example\.slot-2: 3 restarts since last start \(oom-kill\)$'
}

case_health_enabled_but_dead_slot_is_a_problem() {
  RUNNERCTL_STUB_SLOT3_ENABLED=1 run health
  expect_rc 1
  expect_out '^example\.slot-3: enabled but inactive/dead since 6d$'
}

case_health_quiet_suppresses_output_keeps_exit_code() {
  run health --quiet --max-restarts 3
  expect_rc 1
  expect_no_out '.'
}

case_health_unknown_option_dies() {
  run health --bogus
  expect_rc 1
  expect_err "unknown option: --bogus"
}

case_health_max_restarts_missing_value_dies() {
  run health --max-restarts
  expect_rc 1
  expect_err "needs a value"
}

# --- GHR-26: journal_job_lines filters with -g, not a -n tail window ---------
# The real journal_job_lines is stubbed under the sim, so the argv builder is
# what is asserted: `-g` carries the job-line pattern and there is no `-n`
# window for the Listener's other output to eat into.
case_journal_job_args_use_grep_not_a_window() {
  run_fn journal_job_args actions.runner.example.slot-1.service abc123
  expect_rc 0
  expect_out '^-g$'
  expect_out '^Running job: \|completed with result: $'
  expect_out '^_SYSTEMD_INVOCATION_ID=abc123$'
  expect_out '^--system$'
  expect_no_out '^-n$'
}

case_journal_job_args_without_invocation_id() {
  run_fn journal_job_args actions.runner.example.slot-1.service
  expect_rc 0
  expect_out '^-g$'
  expect_no_out '^_SYSTEMD_INVOCATION_ID='
}

# --- GHR-27: colour, and the stalled-job flag --------------------------------
# Colour is off for the whole run (NO_COLOR=1 above); slot-1's job has run
# 12 minutes on the pinned clock, so `--stall-after 600` flags it and the
# default (3600 since GHR-30) does not (the exact-row cases above guard the
# latter).
ESC=$'\033'
SGR="$ESC\[[0-9;]*m"

case_status_stall_after_flags_slot1() {
  run status --stall-after 600
  expect_rc 0
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\) STALLED$'
  expect_out '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
  expect_out '^2 +example\.slot-3 .* —$'
  expect_out_count '^note: STALLED = a job running longer than 10m \(STALL_SEC=600\); .runnerctl logs <IDX>. shows what it is doing, a high PRESS means it is memory-throttled rather than hung$' 1
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

case_status_stall_after_equals_form_and_boundary() {
  # 720 s is exactly the job's age: at the threshold counts as stalled
  run status --stall-after=720
  expect_rc 0
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\) STALLED$'
  # one second over the age: not stalled, no note
  run status --stall-after 721
  expect_rc 0
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_no_out 'STALLED'
}

case_status_stall_after_zero_disables() {
  run status --stall-after 0
  expect_rc 0
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_no_out 'STALLED'
}

case_status_stall_after_invalid_rejected() {
  run status --stall-after soon
  expect_rc 1
  expect_err "^runnerctl: --stall-after value 'soon' is invalid — want a whole number of seconds \(0 disables the stalled flag\)$"
  expect_no_out '.'
  run status --stall-after
  expect_rc 1
  expect_err 'needs a value'
}

case_status_json_stalled_field() {
  run status --stall-after 600 --json
  expect_rc 0
  expect_out '"name":"example.slot-1".*"job":\{"repo":"my-app","name":"test","since":1000000000,"stalled":true\}'
  expect_out '"name":"example.slot-2".*"job":null'
  expect_no_out 'STALLED'
  expect_no_out "$SGR"
}

case_health_stalled_job_is_a_problem() {
  run health --stall-after 600
  expect_rc 1
  expect_out '^example\.slot-1: stalled — job my-app:test running 12m, longer than 10m \(--stall-after 600\)$'
  expect_out_count '^example\.slot-' 1
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
  # the same threshold in = form, and --quiet keeps only the exit code
  run health --quiet --stall-after=600
  expect_rc 1
  expect_no_out '.'
}

case_health_default_threshold_ignores_a_12m_job() {
  run health
  expect_rc 0
  expect_out '^ok: 3 slot\(s\) healthy$'
  run health --stall-after 721
  expect_rc 0
  expect_out '^ok: 3 slot\(s\) healthy$'
}

case_health_reads_the_shared_collector() {
  run health
  expect_rc 0
  # one batched unit_props per slot, the journal for the two running slots,
  # the restart reason once (slot-2) — the table's fetches, no more
  expect_log_count '^probe:unit_props ' 3
  expect_log_count '^probe:journal_job_lines ' 2
  expect_log_count '^probe:journal_restart_reason ' 1
}

case_health_stall_after_invalid_rejected() {
  run health --stall-after 6h
  expect_rc 1
  expect_err "^runnerctl: --stall-after value '6h' is invalid"
  expect_no_out '.'
}

case_watch_stalled_marker_in_frames() {
  RUNNERCTL_STUB_TTY=1 run watch --iterations 2 --stall-after 600
  expect_rc 0
  expect_out_count '^0 +example\.slot-1 .* my-app:test \(12m\) STALLED$' 2
  expect_out_count '^note: STALLED = a job running longer than 10m' 2
}

# --color always paints; the plain text of every cell is unchanged and the
# columns still line up, because padding counts visible characters.
case_status_color_always_paints_by_meaning() {
  run status --color always --stall-after 600
  expect_rc 0
  # header bold; slot-1 ACTIVE green (no restarts); its stalled job bold red
  expect_out "^$ESC\[1mIDX +RUNNER .* WORKING-ON$ESC\[0m$"
  expect_out "^0 +example\.slot-1 +$ESC\[2m—$ESC\[0m +$ESC\[32mactive/running$ESC\[0m +3d 4h +enabled +26\.0G +22\.0G +1\.0G/25\.0G +— +always +— +$ESC\[1m$ESC\[31mmy-app:test \(12m\) STALLED$ESC\[0m$"
  # slot-2: restarted → yellow ACTIVE; idle → dim WORKING-ON
  expect_out "^1 +example\.slot-2 .* $ESC\[33mactive/running ↻3 \(last: oom-kill\)$ESC\[0m +41m +enabled .* $ESC\[2midle 2h31m \(2 jobs\)$ESC\[0m$"
  # slot-3: inactive → red ACTIVE, disabled → dim ENABLED, WORKING-ON — → dim
  expect_out "^2 +example\.slot-3 +$ESC\[2m—$ESC\[0m +$ESC\[31minactive/dead$ESC\[0m +6d +$ESC\[2mdisabled$ESC\[0m +— +— +— +— +always +— +$ESC\[2m—$ESC\[0m$"
  expect_out "^$ESC\[31mnote: STALLED = .*$ESC\[0m$"
  # the columns: with the SGR sequences stripped, the painted table is the
  # plain one byte for byte (the GHR-21 padding invariant, now under colour)
  _expect
  local painted
  painted="$(sed -E "s/$SGR//g" <<<"$OUT")"
  run status --color never --stall-after 600
  expect_rc 0
  # `; true`: diff exits 1 on a difference, and under set -e a failing
  # command substitution inside an assignment aborts the whole run silently
  [ "$painted" = "$OUT" ] || FAILS+=("--color always stripped of SGR differs from --color never: $(diff <(echo "$painted") <(echo "$OUT") | head -5; true)")
}

case_status_color_never_and_default_are_plain() {
  # a tty with NO_COLOR unset: auto paints
  NO_COLOR='' RUNNERCTL_STUB_TTY=1 run status
  expect_rc 0
  expect_out "$SGR"
  # the same tty with NO_COLOR set (the harness default): auto does not
  RUNNERCTL_STUB_TTY=1 run status
  expect_rc 0
  expect_no_out "$SGR"
  # no tty: auto does not, whatever NO_COLOR says
  NO_COLOR='' run status
  expect_rc 0
  expect_no_out "$SGR"
  # --color never beats a tty with NO_COLOR unset
  NO_COLOR='' RUNNERCTL_STUB_TTY=1 run status --color never
  expect_rc 0
  expect_no_out "$SGR"
  expect_out '^0 +example\.slot-1 +— +active/running +3d 4h +enabled +26\.0G +22\.0G +1\.0G/25\.0G +— +always +— +my-app:test \(12m\)$'
}

case_status_color_invalid_rejected() {
  run status --color sometimes
  expect_rc 1
  expect_err "^runnerctl: --color value 'sometimes' is invalid — want auto, always or never$"
  expect_no_out '.'
  run status --color
  expect_rc 1
  expect_err 'needs a value'
}

case_status_json_never_paints() {
  NO_COLOR='' RUNNERCTL_STUB_TTY=1 run status --json
  expect_rc 0
  expect_no_out "$SGR"
  run status --json --color always
  expect_rc 0
  expect_no_out "$SGR"
  expect_out '^ "slots":\[$'
}

case_health_never_paints() {
  NO_COLOR='' RUNNERCTL_STUB_TTY=1 run health --stall-after 600
  expect_rc 1
  expect_no_out "$SGR"
  expect_out '^example\.slot-1: stalled'
}

case_watch_color_always_paints_header_and_frames() {
  RUNNERCTL_STUB_TTY=1 run watch --iterations 2 --color=always
  expect_rc 0
  expect_out_count "${FRAME_PREFIX}$ESC\[1mrunnerctl watch — [^ ]+ — [0-9]{2}:[0-9]{2}:[0-9]{2} — every 2s \(Ctrl-C to quit\)$ESC\[0m$" 2
  expect_out_count "^0 +example\.slot-1 .* $ESC\[32mmy-app:test \(12m\)$ESC\[0m$" 2
  # `status --watch --color always` reaches the same loop with the option
  RUNNERCTL_STUB_TTY=1 run status --watch --color always --iterations 1
  expect_rc 0
  expect_out_count "^0 +example\.slot-1 .* $ESC\[32mmy-app:test \(12m\)$ESC\[0m$" 1
}

# The USED cell against MemoryHigh: 1.0G of 22G is plain; the stub cannot
# vary MemoryCurrent, so the colour rule is asserted on the helper itself.
case_status_used_color_thresholds() {
  run_fn eval 'color_setup always; status_used_color 1073741824 23622320128'   # 1G of 22G
  expect_rc 0
  expect_no_out '.'
  run_fn eval 'color_setup always; status_used_color 21260088115 23622320128'  # one byte under 90 %
  expect_rc 0
  expect_no_out '.'
  run_fn eval 'color_setup always; status_used_color 21260088116 23622320128'  # 90 %
  expect_rc 0
  expect_out "^$ESC\[33m$"
  run_fn eval 'color_setup always; status_used_color 23622320128 23622320128'  # at MemoryHigh
  expect_rc 0
  expect_out "^$ESC\[31m$"
  run_fn eval 'color_setup always; status_used_color 5 infinity'
  expect_rc 0
  expect_no_out '.'
}

# --- GHR-33: interactive watch -------------------------------------------------
# Without --iterations the loop is interactive: the stub's `tty_read_char`
# hands out RUNNERCTL_STUB_KEYS one character per read (`-` = a tick with
# no key; exhausted = ticks forever, so every case ends with `q`), `term_cols`
# answers RUNNERCTL_STUB_COLS (0 = unknown) and `page` is a logged `cat`.
# The cursor row is reverse video (ESC[7m … ESC[0m) whatever --color says;
# each frame ends with the legend and a status line (notice or confirm).
REV="$ESC\[7m"
LEGEND='^↑↓/jk select  K kill job  R restart  S stop  T start  P reap  L logs  q quit$'
SLOT1_UNIT='actions\.runner\.example\.slot-1\.service'
SLOT2_UNIT='actions\.runner\.example\.slot-2\.service'
SLOT3_UNIT='actions\.runner\.example\.slot-3\.service'

# The row a frame highlights: a slot row wrapped in reverse video.
cursor_row() { echo "^${REV}$1 +example\.slot-$2 .*$ESC\[0m$"; }

case_watch_keys_move_the_cursor() {
  # j, j, k, then an arrow down (ESC [ B) and an arrow up in the O form
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS=$'jjk\e[B\eOAq' run watch --interval 1
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 6
  expect_out_count "$LEGEND" 6
  # the header of every frame is the one from before (GHR-3 / GHR-32)
  expect_out_count "${FRAME_PREFIX}runnerctl watch — [^ ]+ — [0-9]{2}:[0-9]{2}:[0-9]{2} — every 1s \(Ctrl-C to quit\)$" 6
  expect_out_count '^runnerctl [0-9]+\.[0-9]+\.[0-9]+ — Host: ' 6
  # exactly one highlighted row per frame: slot-1, then 2, 3, 2, 3 and the
  # frame q was read from (2)
  expect_out_count "^${REV}[0-9]" 6
  expect_out_count "$(cursor_row 0 1)" 1
  expect_out_count "$(cursor_row 1 2)" 3
  expect_out_count "$(cursor_row 2 3)" 2
  # the unhighlighted rows are the plain ones `status` prints
  expect_out '^0 +example\.slot-1 +— +active/running +3d 4h .* my-app:test \(12m\)$'
  # the escape sequences went through the real parser, one char per read
  expect_log_order '^probe:tty_read_char 1 j$' '^probe:tty_read_char 1 j$' '^probe:tty_read_char 1 k$' \
                   "^probe:tty_read_char 1 \\\$'\\\\E'$" '^probe:tty_read_char 0\.05 \\\[$' '^probe:tty_read_char 0\.05 B$' \
                   "^probe:tty_read_char 1 \\\$'\\\\E'$" '^probe:tty_read_char 0\.05 O$' '^probe:tty_read_char 0\.05 A$' \
                   '^probe:tty_read_char 1 q$' '^probe:term_cursor show$'
  # a key redraws at once: no pause between these frames
  expect_no_log '^probe:pause '
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

# The cursor clamps at both ends and is keyed by the unit, so a tick (the
# interval passing with no key) redraws with the same row highlighted.
case_watch_cursor_clamps_and_survives_a_tick() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='kkjjjj--q' run watch
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 9
  expect_out_count "$(cursor_row 0 1)" 3
  expect_out_count "$(cursor_row 1 2)" 1
  expect_out_count "$(cursor_row 2 3)" 5
  expect_log_count '^probe:pause 2$' 2
  # a tick is a journal-memo tick: 2 ticks + tick 0 read the journal once
  expect_log_count '^probe:journal_job_lines .*slot-1' 1
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

# K on the busy slot: the confirm line names the exact command — the job's
# own pids, not a restart (GHR-36) — `y` runs it through run_priv with the
# cursor shown for a sudo prompt, and the result is the next frame's notice.
# The journal memo for the slot is dropped before the decision and again
# inside the wait, so both see current facts: BUSY_POLLS=3 is the Listener
# reporting the job failed on the first poll after its Worker was killed.
case_watch_K_kills_the_running_job_after_confirm() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_BUSY_POLLS=3 \
    RUNNERCTL_STUB_KEYS='Kyq' run watch
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 3
  expect_out_count "^Kill the job on example\.slot-1 \(my-app:test \(12m\)\)\? runs: kill -KILL 4100 4101 \(4100/Runner\.Worker, 4101/node\) — the runner stays up and reports it failed  \[y/n\]$" 1
  expect_out '^running: kill example\.slot-1$'
  expect_out_count '^example\.slot-1: killed 2 process\(es\): 4100/Runner\.Worker, 4101/node — the runner stayed up and reports the job failed$' 1
  expect_log_count '^kill -KILL 4100 4101$' 1
  expect_no_log '^systemctl '
  expect_log_order '^probe:term_cursor hide$' '^probe:tty_read_char 2 K$' '^probe:journal_job_lines .*slot-1' \
                   '^probe:proc_job_tree /system\.slice/actions\.runner\.example\.slot-1\.service$' \
                   '^probe:tty_read_char 2 y$' '^probe:term_cursor show$' '^kill -KILL 4100 4101$' \
                   '^probe:term_cursor hide$' '^probe:tty_read_char 2 q$' '^probe:term_cursor show$'
  # the cursor stayed on the slot
  expect_out_count "$(cursor_row 0 1)" 3
}

# K on a slot wedged in its own stop names the unit kill instead — the state
# a `systemctl restart` of a stalled job leaves behind, and the one thing
# that gets out of it.
case_watch_K_on_a_deactivating_slot_names_the_unit_kill() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_DEACTIVATING=1 \
    RUNNERCTL_STUB_KEYS='Kyq' run watch
  expect_rc 0
  expect_out_count "^example\.slot-1 is stuck stopping \(deactivating/stop-sigterm\) — SIGKILL the whole unit\? runs: systemctl kill -s KILL $SLOT1_UNIT  \[y/n\]$" 1
  expect_log_count "^systemctl kill -s KILL $SLOT1_UNIT\$" 1
  expect_no_log '^kill -KILL'
  expect_no_log '^systemctl restart'
}

# Anything but `y` at a confirm cancels it: nothing runs, the notice says so.
case_watch_confirm_n_runs_nothing() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Knq' run watch
  expect_rc 0
  expect_out_count '^Kill the job on example\.slot-1 ' 1
  expect_out_count '^cancelled — nothing run$' 1
  expect_no_out '^running:'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
  # `q` at a confirm is a cancel too, not a quit: a second one quits
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Kqq' run watch
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 3
  expect_out_count '^cancelled — nothing run$' 1
  expect_no_log '^systemctl '
}

# K needs a running job: the idle slot and the stopped one refuse with a
# notice and no confirm line; (no access) says why it cannot tell.
case_watch_K_refused_without_a_running_job() {
  # the `y` after each refusal is no confirm: it is an unbound key that
  # only clears the notice
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jKyjKyq' run watch
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 7
  expect_out_count '^example\.slot-2: no job running — nothing to kill$' 1
  expect_out_count '^example\.slot-3: not running — nothing to kill$' 1
  expect_no_out '^Kill the job'
  expect_no_out '\[y/n\]'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_JOURNAL_ACCESS=0 RUNNERCTL_STUB_KEYS='Kq' run watch
  expect_rc 0
  expect_out '^example\.slot-1: cannot tell whether a job is running — needs journal read access \(systemd-journal group\) or root$'
  expect_no_log '^systemctl '
}

# R on an active slot: confirm, and a warning line when a job is in flight
# (slot-1) but not on the idle slot-2; the stopped slot-3 refuses.
case_watch_R_restarts_with_a_warning_when_busy() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='RyjRyjRq' run watch
  expect_rc 0
  expect_out_count "^Restart example\.slot-1\? runs: systemctl restart $SLOT1_UNIT  \[y/n\]$" 1
  expect_out_count "^warning: a job is running \(my-app:test \(12m\)\) — it will be killed and GitHub marks it failed; runnerctl restart --when-idle waits for it instead$" 1
  expect_out_count "^Restart example\.slot-2\? runs: systemctl restart $SLOT2_UNIT  \[y/n\]$" 1
  expect_out_count '^warning:' 1
  expect_out_count '^example\.slot-3: not active \(inactive\) — T starts it$' 1
  expect_out_count '^example\.slot-1: restart done\.$' 1
  expect_out_count '^example\.slot-2: restart done\.$' 1
  expect_log_order "^systemctl restart $SLOT1_UNIT$" "^systemctl restart $SLOT2_UNIT$"
  expect_log_count '^systemctl ' 2
}

# S stops an active slot (warned when busy), T starts a stopped one; the
# no-op directions refuse.
case_watch_S_stops_and_T_starts() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='TSyjjSTyq' run watch
  expect_rc 0
  expect_out_count '^example\.slot-1: already active — R restarts it$' 1
  expect_out_count "^Stop example\.slot-1\? runs: systemctl stop $SLOT1_UNIT  \[y/n\]$" 1
  expect_out_count '^warning: a job is running \(my-app:test \(12m\)\) — it will be killed and GitHub marks it failed; runnerctl stop --when-idle waits for it instead$' 1
  expect_out_count '^example\.slot-1: stop done\.$' 1
  expect_out_count '^example\.slot-3: already stopped \(inactive\)$' 1
  expect_out_count "^Start example\.slot-3\? runs: systemctl start $SLOT3_UNIT  \[y/n\]$" 1
  expect_out_count '^example\.slot-3: start done\.$' 1
  expect_log_order "^systemctl stop $SLOT1_UNIT$" "^systemctl start $SLOT3_UNIT$"
  expect_log_count '^systemctl ' 2
}

# P reaps the idle slot's leaked processes through cmd_reap (TERM, grace,
# KILL for survivors); the busy slot and a slot without leaks refuse.
case_watch_P_reaps_leaked_processes() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 RUNNERCTL_STUB_SURVIVORS=4243 \
    RUNNERCTL_STUB_KEYS='PjPyq' run watch
  expect_rc 0
  expect_out_count "^example\.slot-1: busy \(my-app:test \(12m\)\) — a running job's processes are not leaks$" 1
  expect_out_count '^Reap 2 leaked process\(es\) on example\.slot-2 \(4242/node, 4243/esbuild\)\? runs: kill -TERM 4242 4243, then kill -KILL what is still alive after 5s  \[y/n\]$' 1
  expect_out "^running: reap example\.slot-2$"
  expect_out_count '^example\.slot-2: reaped 2 leaked process\(es\): 4242/node, 4243/esbuild — SIGKILL needed for pid 4243$' 1
  expect_log_order '^probe:term_cursor show$' '^kill -TERM 4242 4243$' '^probe:pause 5$' '^kill -KILL 4243$' '^probe:term_cursor hide$'
  expect_log_count '^kill ' 2
  expect_no_log '^systemctl '
  # no leaks shown: refused, nothing sent
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_KEYS='jPyq' run watch
  expect_rc 0
  expect_out_count '^example\.slot-2: no leaked processes shown — nothing to reap$' 1
  expect_no_out '\[y/n\]'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

# L pages `logs <slot> -n 50` at once (no confirm — it changes nothing),
# with the cursor shown for the pager and hidden again for the next frame.
case_watch_L_pages_the_slot_logs() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jLq' run watch
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 3
  expect_no_out '\[y/n\]'
  expect_log_count "^journalctl -u $SLOT2_UNIT -n 50 --no-pager$" 1
  expect_log_count '^journalctl ' 1
  # the pager and cmd_logs are the two ends of one pipeline, so only their
  # place between the cursor calls is ordered, not the two against each other
  expect_log_order '^probe:tty_read_char 2 L$' '^probe:term_cursor show$' "^journalctl -u $SLOT2_UNIT -n 50 --no-pager$" '^probe:term_cursor hide$' '^probe:tty_read_char 2 q$'
  expect_log_order '^probe:term_cursor show$' '^probe:page$' '^probe:term_cursor hide$'
  expect_log_count '^probe:page$' 1
  expect_no_log '^systemctl '
}

# q (or Q) quits with the cursor restored; a lone Escape is not a key.
case_watch_q_quits() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='q' run watch
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 1
  expect_out_count "$(cursor_row 0 1)" 1
  expect_log_order '^probe:term_cursor hide$' '^probe:tty_read_char 2 q$' '^probe:term_cursor show$'
  expect_log_count '^probe:term_cursor ' 2
  # ESC, then nothing within the follow-up read (the `-`): a lone Escape,
  # which is no key at all — one frame for it, then Q
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS=$'\e-Q' run watch
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 2
  expect_log_order "^probe:tty_read_char 2 \\\$'\\\\E'$" '^probe:tty_read_char 0\.05 none$' '^probe:pause 0\.05$' '^probe:tty_read_char 2 Q$'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

# --iterations N is the headless view of before: no key is read even with
# keys on offer, no cursor, no legend, nothing run.
case_watch_iterations_reads_no_keys() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Kyq' run watch --iterations 2
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 2
  expect_no_log '^probe:tty_read_char '
  expect_log_count '^probe:pause 2$' 2
  expect_no_out "$REV"
  expect_no_out "$LEGEND"
  expect_no_out '\[y/n\]'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

# Not a terminal: the refusal of before, and no key is read on the way out.
case_watch_non_tty_refusal_reads_no_keys() {
  RUNNERCTL_STUB_KEYS='Kyq' run watch
  expect_rc 1
  expect_err "^runnerctl: watch needs a terminal \(stdout is not a tty\); use 'runnerctl status'$"
  expect_no_out '.'
  expect_no_log '^probe:tty_read_char '
  expect_no_log '^systemctl '
}

# A terminal narrower than the table drops MAX, HIGH and ENVFILE — never
# WORKING-ON, whose idle duration is what an action is decided on — and a
# wide (or unknown-width) one keeps every column. `status` is untouched.
case_watch_narrow_terminal_drops_max_high_envfile() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_COLS=140 RUNNERCTL_STUB_KEYS='jq' run watch
  expect_rc 0
  expect_out_count '^IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +USED +PRESS +RESTART +WORKING-ON$' 2
  expect_no_out 'MAX|HIGH|ENVFILE'
  expect_out "^${REV}0 +example\.slot-1 +— +active/running +3d 4h +enabled +1\.0G/25\.0G +— +always +my-app:test \(12m\)$ESC\[0m$"
  expect_out '^1 +example\.slot-2 .* +always +idle 2h31m \(2 jobs\)$'
  expect_no_out '/etc/x'
  # the re-render happens once, on the transition: 3 + 3 fetches for the
  # first frame, 3 for the second
  expect_log_count '^probe:unit_props ' 9
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_COLS=300 RUNNERCTL_STUB_KEYS='q' run watch
  expect_rc 0
  expect_out '^IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +PRESS +RESTART +ENVFILE +WORKING-ON$'
  expect_out '^1 +example\.slot-2 .* /etc/x \(ignore_errors=no\) idle 2h31m \(2 jobs\)$'
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='q' run watch
  expect_rc 0
  expect_out '^IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +PRESS +RESTART +ENVFILE +WORKING-ON$'
  RUNNERCTL_STUB_COLS=80 run status
  expect_rc 0
  expect_out '^IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +PRESS +RESTART +ENVFILE +WORKING-ON$'
  expect_out '^1 +example\.slot-2 .* /etc/x \(ignore_errors=no\) idle 2h31m \(2 jobs\)$'
}

# --color always: the cursor's reverse video is re-applied after every
# reset a painted cell ends with, so the row stays highlighted end to end.
case_watch_color_always_keeps_the_cursor_row_highlighted() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='q' run watch --color always
  expect_rc 0
  expect_out "^${REV}0 +example\.slot-1 +$ESC\[2m—$ESC\[0m${REV} +$ESC\[32mactive/running$ESC\[0m${REV} .* $ESC\[32mmy-app:test \(12m\)$ESC\[0m${REV}$ESC\[0m$"
  expect_out "^1 +example\.slot-2 +$ESC\[2m—$ESC\[0m +$ESC\[33m"
  expect_out "^$ESC\[2m↑↓/jk select .* q quit$ESC\[0m$"
}

# --- Registry -----------------------------------------------------------------
# --- GHR-29: leaked processes on an idle slot, and `reap` --------------------
# The stub's slot-2 is idle (2h31m, 2 jobs); with the cgroup readable and
# RUNNERCTL_STUB_LEAKED=1 its proc_leaked answers 4242/node and 4243/esbuild.

case_status_leaked_suffix_and_note() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run status
  expect_rc 0
  expect_out '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\) \+2 leaked$'
  # the busy slot and the stopped one are never walked: leaks cannot be told
  # from a job's own processes, and a stopped unit has no cgroup
  expect_out '^0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_out '^2 +example\.slot-3 .* —$'
  expect_log_count '^probe:proc_leaked ' 1
  expect_log '^probe:proc_leaked /system\.slice/actions\.runner\.example\.slot-2\.service$'
  expect_out_count "^note: \+N leaked = processes a finished job left in the slot's cgroup, counting against MemoryMax; 'runnerctl reap <IDX>' kills them$" 1
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

case_status_no_leaks_no_suffix() {
  # readable cgroup, nothing leaked: the cell is untouched and there is no note
  RUNNERCTL_STUB_CGROUP_READABLE=1 run status
  expect_rc 0
  expect_out '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
  expect_no_out 'leaked'
  expect_log_count '^probe:proc_leaked ' 1
  # unreadable cgroup (the default reader): not even asked, nothing shown
  run status
  expect_rc 0
  expect_out '^1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
  expect_no_out 'leaked'
  expect_no_log '^probe:proc_leaked '
}

case_status_leaked_painted_yellow() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run status --color always
  expect_rc 0
  expect_out "^1 +example\.slot-2 .*$ESC\[33midle 2h31m \(2 jobs\) \+2 leaked$ESC\[0m$"
  expect_out "^$ESC\[33mnote: \+N leaked"
}

case_status_json_leaked_procs() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run status --json
  expect_rc 0
  expect_out '"name":"example.slot-2".*"jobs_completed":2,"working_on_access":"ok","leaked_procs":2,"memory_events"'
  expect_out '"name":"example.slot-1".*"leaked_procs":null,"memory_events"'
  expect_out '"name":"example.slot-3".*"leaked_procs":null,"memory_events"'
  # the default reader cannot see the cgroup: null, not 0
  run status --json
  expect_rc 0
  expect_out '"name":"example.slot-2".*"leaked_procs":null,"memory_events"'
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: status --json parse assertion not run"; return 0; fi
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run status --json
  expect_json '[s["leaked_procs"] for s in d["slots"]] == [None, 2, None]'
}

case_health_leaked_is_a_problem() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run health
  expect_rc 1
  expect_out '^example\.slot-2: 2 leaked process\(es\) left by finished jobs \(node, esbuild\) — runnerctl reap 1$'
  expect_out_count '^example\.slot-' 1
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
  RUNNERCTL_STUB_CGROUP_READABLE=1 run health
  expect_rc 0
  expect_out '^ok: 3 slot\(s\) healthy$'
}

case_reap_term_pause_kill_order() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 RUNNERCTL_STUB_SURVIVORS=4243 run reap
  expect_rc 0
  expect_out '^example\.slot-1: busy \(my-app:test, 12m\) — skipped, a running job.s processes are not leaks$'
  expect_out '^example\.slot-2: reaped 2 leaked process\(es\): 4242/node, 4243/esbuild — SIGKILL needed for pid 4243$'
  expect_out '^example\.slot-3: not running — nothing to reap$'
  expect_log_order '^kill -TERM 4242 4243$' '^probe:pause 5$' '^probe:pid_alive 4242$' '^probe:pid_alive 4243$' '^kill -KILL 4243$'
  expect_log_count '^kill ' 2
  expect_no_log '^systemctl '
}

case_reap_everything_dies_on_term() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run reap 1
  expect_rc 0
  expect_out '^example\.slot-2: reaped 2 leaked process\(es\): 4242/node, 4243/esbuild$'
  expect_no_out 'SIGKILL'
  expect_log_count '^kill -TERM 4242 4243$' 1
  expect_no_log '^kill -KILL'
  expect_out_count '^example\.slot-' 1
}

case_reap_dry_run_makes_no_call() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run reap --dry-run
  expect_rc 0
  expect_out '^example\.slot-2: would kill 2 leaked process\(es\): 4242/node, 4243/esbuild$'
  expect_no_log '^kill '
  expect_no_log '^probe:pause '
}

case_reap_busy_slot_is_skipped_not_killed() {
  # target the busy slot only: nothing must be sent, and the run is not a failure
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run reap 0
  expect_rc 0
  expect_out '^example\.slot-1: busy \(my-app:test, 12m\) — skipped'
  expect_no_log '^kill '
  expect_no_log '^probe:proc_leaked '
}

case_reap_nothing_to_reap() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 run reap 1
  expect_rc 0
  expect_out '^example\.slot-2: nothing to reap$'
  expect_no_log '^kill '
}

case_reap_unreadable_cgroup_dies() {
  run reap 1
  expect_rc 1
  expect_err "^runnerctl: example\.slot-2: cannot read the slot's processes — run reap as root or the runner user$"
  expect_no_log '^kill '
  # no journal either: the idle question itself cannot be answered
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 run reap 1
  expect_rc 1
  expect_err '^runnerctl: example\.slot-2: cannot tell whether the slot is idle — reap needs journal read access'
  expect_no_log '^kill '
}

case_reap_unknown_option_and_bad_target() {
  run reap --bogus
  expect_rc 1
  expect_err '^runnerctl: unknown option: --bogus$'
  run reap nope
  expect_rc 1
  expect_err "no runner slot matches 'nope'"
  expect_no_log '^kill '
}

# --- GHR-36: `kill` takes the job, not the runner ----------------------------
# The job's own processes get SIGKILL and the Listener is left alone, so it
# reports the job failed itself. RUNNERCTL_STUB_BUSY_POLLS=1 is that report
# arriving: slot-1's journal shows the job completed from the second read on.
case_kill_sigkills_the_job_tree_and_leaves_the_runner() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_BUSY_POLLS=1 run kill 0
  expect_rc 0
  expect_out '^example\.slot-1: killed 2 process\(es\): 4100/Runner\.Worker, 4101/node — the runner stayed up and reports the job failed$'
  expect_log_count '^kill -KILL 4100 4101$' 1
  expect_log_count '^kill ' 1
  # the whole point: no restart, and no systemctl at all
  expect_no_log '^systemctl '
  expect_log_order '^probe:proc_job_tree /system\.slice/actions\.runner\.example\.slot-1\.service$' \
                   '^kill -KILL 4100 4101$' '^probe:pause 5$'
}

# The Listener is wedged too: it never reports the job gone, so after
# KILL_GRACE_SEC the whole unit's cgroup is SIGKILLed instead. Without this
# escalation a `kill` on the worst case would report success and change
# nothing — which is the bug `restart` had.
case_kill_escalates_to_the_unit_when_the_job_survives() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 run kill 0
  expect_rc 0
  expect_out '^example\.slot-1: job still running 10s after SIGKILL — the runner is wedged too — killing the whole unit$'
  expect_out "^example\.slot-1: SIGKILLed the unit's cgroup — Restart=always brings the slot back$"
  expect_log_order '^kill -KILL 4100 4101$' '^probe:pause 5$' '^probe:pause 5$' \
                   "^systemctl kill -s KILL $SLOT1_UNIT\$"
  expect_log_count '^systemctl ' 1
  expect_no_log '^systemctl restart'
}

# A slot wedged in its own graceful stop — where `systemctl restart` of a
# stalled job sits for TimeoutStopSec — skips straight to the unit kill:
# there is nothing left to ask nicely.
case_kill_deactivating_slot_goes_straight_to_the_unit() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_DEACTIVATING=1 run kill 0
  expect_rc 0
  expect_out '^example\.slot-1: stuck stopping \(deactivating/stop-sigterm\) — a graceful stop it will not answer — killing the whole unit$'
  expect_log_count "^systemctl kill -s KILL $SLOT1_UNIT\$" 1
  expect_no_log '^kill -KILL'
  # the per-process walk is not even attempted
  expect_no_log '^probe:proc_job_tree '
}

# No readable cgroup (neither root nor the runner user): nothing to enumerate,
# so systemd does it — it can signal a cgroup this user cannot read.
case_kill_unreadable_cgroup_uses_systemd() {
  run kill 0
  expect_rc 0
  expect_out "^example\.slot-1: cannot read the slot's processes \(run as root or the runner user to kill just the job\) — killing the whole unit\$"
  expect_log_count "^systemctl kill -s KILL $SLOT1_UNIT\$" 1
  expect_no_log '^kill -KILL'
}

case_kill_dry_run_sends_nothing() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 run kill --dry-run 0
  expect_rc 0
  expect_out '^example\.slot-1: would kill 2 process\(es\): 4100/Runner\.Worker, 4101/node$'
  expect_no_log '^(kill|systemctl) '
  expect_no_log '^probe:pause '
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_DEACTIVATING=1 run kill --dry-run 0
  expect_rc 0
  expect_out "^example\.slot-1: stuck stopping \(deactivating/stop-sigterm\) — a graceful stop it will not answer — would run systemctl kill -s KILL $SLOT1_UNIT\$"
  expect_no_log '^(kill|systemctl) '
}

# No job, no kill — and nothing is sent for a slot that only looks busy.
case_kill_without_a_running_job_is_refused() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 run kill 1 2
  expect_rc 0
  expect_out '^example\.slot-2: no job running — nothing to kill$'
  expect_out '^example\.slot-3: not running — nothing to kill$'
  expect_no_log '^(kill|systemctl) '
  expect_no_log '^probe:proc_job_tree '
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 run kill 0
  expect_rc 1
  expect_err '^runnerctl: example\.slot-1: cannot tell whether a job is running — kill needs journal read access \(systemd-journal group\) or root$'
  expect_no_log '^(kill|systemctl) '
}

# A bare `kill` would take every slot's job at once: refuse it, and point at
# the flag that makes a no-target run mean something.
case_kill_needs_a_target() {
  run kill
  expect_rc 1
  expect_err '^runnerctl: kill needs a target \(a unit, slot index or name\) — or --if-stalled to take every stalled slot$'
  expect_no_log '^(kill|systemctl) '
  run kill --bogus
  expect_rc 1
  expect_err '^runnerctl: unknown option: --bogus$'
  run kill nope
  expect_rc 1
  expect_err "no runner slot matches 'nope'"
}

# --if-stalled selects exactly the STALLED slots, like restart --if-stalled,
# and the same threshold rules apply.
case_kill_if_stalled_takes_only_the_stalled_slot() {
  RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_BUSY_POLLS=1 run kill --if-stalled --stall-after 600
  expect_rc 0
  expect_out '^example\.slot-1: stalled — my-app:test, 12m, longer than 10m — killing$'
  expect_out '^example\.slot-2: not stalled \(idle 2h31m \(2 jobs\)\) — skipped$'
  expect_out '^example\.slot-3: not running — skipped$'
  expect_out '^kill done \(1 stalled slot\(s\)\)\.$'
  expect_log_count '^kill -KILL 4100 4101$' 1
  RUNNERCTL_STUB_CGROUP_READABLE=1 run kill --if-stalled
  expect_rc 0
  expect_out '^no stalled slot — nothing killed\.$'
  expect_no_log '^(kill|systemctl) '
  run kill --if-stalled --stall-after 0
  expect_rc 1
  expect_err '^runnerctl: --if-stalled needs a threshold: STALL_SEC is 0'
}

case_kill_grace_default_and_config_example() {
  run_fn eval "echo \$KILL_GRACE_SEC"
  expect_rc 0
  expect_out '^10$'
  run config-example
  expect_rc 0
  expect_out '^#KILL_GRACE_SEC="10"$'
  expect_out "^#RUNNER_LISTENER_PATTERN='runsvc\\\\.sh\|RunnerService\\\\.js\|Runner\\\\.Listener'\$"
}

# --- GHR-30: a 1 h default, and --if-stalled / --restart-stalled -------------
# slot-1's job is 12 minutes old on the pinned clock: `--stall-after 600`
# makes it STALLED, the default does not.
case_stall_sec_default_is_one_hour() {
  run_fn eval "echo \$STALL_SEC"
  expect_rc 0
  expect_out '^3600$'
  # and the config example documents the same default
  run config-example
  expect_out '^#STALL_SEC="3600"$'
}

case_restart_if_stalled_restarts_only_the_stalled_slot() {
  run restart --if-stalled --stall-after 600
  expect_rc 0
  expect_out '^example\.slot-1: stalled — my-app:test, 12m, longer than 10m — restarting$'
  expect_out '^example\.slot-2: not stalled \(idle 2h31m \(2 jobs\)\) — skipped$'
  expect_out '^example\.slot-3: not running — skipped$'
  expect_out '^restart done \(1 stalled slot\(s\)\)\.$'
  expect_log_count '^systemctl restart ' 1
  expect_log "^systemctl restart $U1\$"
  expect_no_log '^probe:pause '
}

case_restart_if_stalled_default_threshold_restarts_nothing() {
  run restart --if-stalled
  expect_rc 0
  expect_out '^example\.slot-1: not stalled \(my-app:test \(12m\)\) — skipped$'
  expect_out '^no stalled slot — nothing restarted\.$'
  expect_no_log '^systemctl '
}

case_stop_if_stalled_targets_and_equals_form() {
  run stop 0 2 --if-stalled --stall-after=600
  expect_rc 0
  expect_out '^example\.slot-1: stalled — my-app:test, 12m, longer than 10m — stopping$'
  expect_out '^example\.slot-3: not running — skipped$'
  expect_out '^stop done \(1 stalled slot\(s\)\)\.$'
  expect_log_count '^systemctl ' 1
  expect_log "^systemctl stop $U1\$"
  expect_no_out 'slot-2'
}

case_if_stalled_refuses_when_idle_start_and_zero_threshold() {
  run restart --if-stalled --when-idle
  expect_rc 1
  expect_err '^runnerctl: --if-stalled and --when-idle are exclusive'
  expect_no_log '^systemctl '
  run start --if-stalled
  expect_rc 1
  expect_err '^runnerctl: --if-stalled only applies to stop and restart$'
  expect_no_log '^systemctl '
  run restart --if-stalled --stall-after 0
  expect_rc 1
  expect_err '^runnerctl: --if-stalled needs a threshold: STALL_SEC is 0'
  expect_no_log '^systemctl '
}

case_if_stalled_no_access_dies_before_acting() {
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 run restart --if-stalled --stall-after 600
  expect_rc 1
  expect_err '^runnerctl: example\.slot-1: cannot tell whether its job is stalled — --if-stalled needs journal read access'
  expect_no_log '^systemctl '
}

case_health_restart_stalled_restarts_and_says_so() {
  run health --restart-stalled --stall-after 600
  expect_rc 1
  expect_out '^example\.slot-1: stalled — job my-app:test running 12m, longer than 10m \(--stall-after 600\) — restarted$'
  expect_out_count '^example\.slot-' 1
  expect_log_count '^systemctl restart ' 1
  expect_log "^systemctl restart $U1\$"
  # --quiet keeps the exit code and the restart, drops the line
  run health --quiet --restart-stalled --stall-after 600
  expect_rc 1
  expect_no_out '.'
  expect_log_count "^systemctl restart $U1\$" 1
}

case_health_restart_stalled_healthy_pool_touches_nothing() {
  run health --restart-stalled
  expect_rc 0
  expect_out '^ok: 3 slot\(s\) healthy$'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

case_health_restart_stalled_reports_a_failed_restart() {
  RUNNERCTL_STUB_FAIL_UNITS='slot-1' run health --restart-stalled --stall-after 600
  expect_rc 1
  expect_out '^example\.slot-1: stalled — .* — restart FAILED$'
  expect_log_count '^systemctl restart ' 1
}

case_health_without_restart_stalled_never_restarts() {
  run health --stall-after 600
  expect_rc 1
  expect_out '^example\.slot-1: stalled — .*\(--stall-after 600\)$'
  expect_no_out 'restarted'
  expect_no_log '^systemctl '
}

# --- GHR-31: memory pressure and memory.events per slot ----------------------
# RUNNERCTL_STUB_PRESSURE=1: slot-1 at 63.20 % full avg10 with 4 high events,
# slot-2 at 0.00 %, slot-3 has no cgroup so it is never asked with one.
case_status_press_column_from_the_stub() {
  RUNNERCTL_STUB_PRESSURE=1 run status
  expect_rc 0
  expect_out '^0 +example\.slot-1 .* +1\.0G/25\.0G +63\.2% +always '
  expect_out '^1 +example\.slot-2 .* +1\.0G +0\.0% +always '
  expect_out '^2 +example\.slot-3 .* +— +— +— +— +always '
  # one read per slot, from the same collector the table and --json share
  expect_log_count '^probe:cgroup_memory_facts ' 3
  expect_log '^probe:cgroup_memory_facts /system\.slice/actions\.runner\.example\.slot-1\.service$'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

case_status_press_painted_by_threshold() {
  RUNNERCTL_STUB_PRESSURE=1 run status --color always
  expect_rc 0
  expect_out "^0 +example\.slot-1 .* +1\.0G/25\.0G +$ESC\[31m63\.2%$ESC\[0m +always "
  expect_out "^1 +example\.slot-2 .* +1\.0G +0\.0% +always "
  expect_no_out "$ESC\[3[13]m0\.0%"
}

case_status_press_color_thresholds() {
  # plain under WARN, yellow from WARN (10), red from CRIT (50); the config
  # can move both — checked through the same helper the table uses
  run_fn eval 'color_setup always; status_press_color 9.99'
  expect_rc 0
  expect_no_out '.'
  run_fn eval 'color_setup always; status_press_color 10.00'
  expect_out "^$ESC\[33m$"
  run_fn eval 'color_setup always; status_press_color 50'
  expect_out "^$ESC\[31m$"
  run_fn eval 'PRESSURE_CRIT_PCT=70; color_setup always; status_press_color 63.2'
  expect_out "^$ESC\[33m$"
  run_fn eval 'color_setup always; status_press_color n/a'
  expect_no_out '.'
  run_fn status_press_cell 63.2
  expect_out '^63\.2%$'
  run_fn status_press_cell ''
  expect_out '^—$'
}

case_status_json_memory_events_and_pressure() {
  RUNNERCTL_STUB_PRESSURE=1 run status --json
  expect_rc 0
  expect_out '"name":"example.slot-1".*"memory_events":\{"high":4,"max":1,"oom_kill":0\},"memory_pressure":\{"full_avg10":63.20,"full_avg60":41.00,"full_total":123456789\}\}'
  expect_out '"name":"example.slot-2".*"memory_events":\{"high":0,"max":0,"oom_kill":0\},"memory_pressure":\{"full_avg10":0.00,"full_avg60":0.00,"full_total":0\}\}'
  expect_out '"name":"example.slot-3".*"memory_events":null,"memory_pressure":null\}'
  expect_no_out '%'
  # nothing readable (the default stub): both objects null on every slot
  run status --json
  expect_rc 0
  expect_out_count '"memory_events":null,"memory_pressure":null\}' 3
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: status --json parse assertion not run"; return 0; fi
  RUNNERCTL_STUB_PRESSURE=1 run status --json
  expect_json 'd["slots"][0]["memory_pressure"]["full_avg10"] == 63.2 and d["slots"][0]["memory_events"]["high"] == 4 and d["slots"][2]["memory_pressure"] is None'
}

case_health_pressure_over_crit_is_a_problem() {
  RUNNERCTL_STUB_PRESSURE=1 run health
  expect_rc 1
  expect_out '^example\.slot-1: under full memory pressure 63\.2% \(avg10, PRESSURE_CRIT_PCT=50\) — throttled at MemoryHigh \(4 times so far\), see USED vs HIGH$'
  expect_out_count '^example\.slot-' 1
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
  # at rest, or unreadable: fine
  run health
  expect_rc 0
  expect_out '^ok: 3 slot\(s\) healthy$'
}

case_health_stalled_line_says_throttled_when_under_pressure() {
  RUNNERCTL_STUB_PRESSURE=1 run health --stall-after 600
  expect_rc 1
  expect_out '^example\.slot-1: stalled — job my-app:test running 12m, longer than 10m \(--stall-after 600\) — under memory pressure 63\.2%, throttled rather than hung$'
  expect_out '^example\.slot-1: under full memory pressure 63\.2%'
  # without pressure the stalled line is as before
  run health --stall-after 600
  expect_rc 1
  expect_out '^example\.slot-1: stalled — job my-app:test running 12m, longer than 10m \(--stall-after 600\)$'
  expect_no_out 'memory pressure'
}

case_pressure_at_least_boundary_is_inclusive() {
  # the health rule fires AT the threshold, not one past it — and never on
  # an unknown value
  run_fn pressure_at_least 50 50
  expect_rc 0
  run_fn pressure_at_least 50.00 50
  expect_rc 0
  run_fn pressure_at_least 49.99 50
  expect_rc 1
  run_fn pressure_at_least '' 50
  expect_rc 1
  run_fn pressure_at_least n/a 50
  expect_rc 1
}

case_status_stalled_note_mentions_press() {
  run status --stall-after 600
  expect_rc 0
  expect_out_count '^note: STALLED = .*, a high PRESS means it is memory-throttled rather than hung$' 1
}

# --- GHR-39: fleet mode ------------------------------------------------------
# The fan-out goes through ssh_run for every host, the column header is
# printed once rather than per host, and each host's rows carry its name.
case_fleet_status_table_one_header_rows_per_host() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet status
  expect_rc 0
  expect_out_count '^HOST +IDX +RUNNER ' 1
  expect_out_count '^build-1 +[0-9]+ +example\.slot-' 3
  expect_out_count '^build-2 +[0-9]+ +example\.slot-' 3
  # one round trip per host, and nothing reached ssh itself
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 1
  expect_no_log '^direct:ssh '
  # the remote host's own runnerctl header is folded away, not repeated
  expect_no_out '^build-1 runnerctl '
}

# An unreachable host must never take the fan-out down with it: the other
# hosts still report, and the exit code still tells a monitor something broke.
case_fleet_status_unreachable_host_is_a_row_not_a_fatal() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" run fleet status
  expect_rc 1
  expect_out '^gw-unreachable +unreachable — ssh: connect to host gw-unreachable port 22: No route to host$'
  # the healthy host is unaffected
  expect_out_count '^build-1 +[0-9]+ +example\.slot-' 3
}

# The three ways a host can fail to produce a status are NOT the same thing,
# and flattening them is the bug this pins: only 124/255 mean "nothing is
# known about this host". A remote runnerctl that ran and exited non-zero
# reached the host fine — on a runner-less box that is its own good message.
case_fleet_status_tells_timeout_remote_error_and_unreachable_apart() {
  RUNNERCTL_STUB_FLEET_HOSTS="gw-unreachable slow-timeout box-norunners" run fleet status
  expect_rc 1
  expect_out '^gw-unreachable +unreachable — '
  expect_out '^slow-timeout +timed out after 30s$'
  expect_out "^box-norunners +remote exit 1 — runnerctl: no 'actions\\.runner\\.\\*\\.service' units found on this host\\.$"
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: reachable-flag assertions not run"; return 0; fi
  RUNNERCTL_STUB_FLEET_HOSTS="gw-unreachable slow-timeout box-norunners" run fleet status --json
  expect_json '[h["reachable"] for h in d["fleet"]] == [False, False, True]'
  expect_json '[h["exit_code"] for h in d["fleet"]] == [255, 124, 1]'
}

# GHR-50: the fan-out's own bootstrap failures — the faults that stand between
# a freshly configured FLEET_HOSTS and its first working table. Each was a row
# saying only "remote exit N", which is accurate and tells the reader nothing.
#
# These assertions pin the REMEDY, not the rc. The rc was already right and
# still sent a reader to the wrong host: 127 is a PATH fault and 126 is the
# 0700/0711 install, and re-running the installer only fixes one of them.
case_fleet_status_names_the_fix_for_a_host_that_cannot_run_runnerctl() {
  RUNNERCTL_STUB_FLEET_HOSTS="box-noinstall box-notexec box-multicall" run fleet status
  expect_rc 1
  # 127 on a bare name. Naming ~/.profile is the point: it is why a runnerctl
  # the same user runs by hand is invisible to a non-interactive ssh.
  expect_out '^box-noinstall +remote exit 127 — bash: line 1: runnerctl: command not found — runnerctl is not on that host'
  expect_out '^box-noinstall .*~/\.local/bin and ~/bin are not on it'
  expect_out '^box-noinstall .*set FLEET_RUNNERCTL to its absolute path'
  # 126 with a full path: installed, not executable by the ssh login. It must
  # NOT be told runnerctl is missing.
  expect_out '^box-notexec +remote exit 126 — bash: /usr/local/bin/runnerctl: Permission denied — runnerctl is installed on that host but the ssh login cannot execute it'
  expect_out "^box-notexec .*'sudo chmod 755' the path it names"
  expect_no_out '^box-notexec .*is not on that host'
  # A multicall dispatcher answering to the name is neither of the above.
  expect_out "^box-multicall +remote exit 1 — coreutils: unknown program 'runnerctl' — a multicall binary answered to that name"
  expect_no_out '^box-multicall .*chmod 755'
}

# The hint has to survive the envelope too: --json is what a monitor reads, and
# a remedy only the table carries is half a fix.
case_fleet_status_json_carries_the_bootstrap_remedy() {
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: bootstrap-hint envelope assertions not run"; return 0; fi
  RUNNERCTL_STUB_FLEET_HOSTS="box-noinstall box-notexec" run fleet status --json
  expect_json '[h["exit_code"] for h in d["fleet"]] == [127, 126]'
  # reachable stays true: the remote shell ran and said no, so this is not the
  # "nothing is known about this host" class that 124/255 mean.
  expect_json '[h["reachable"] for h in d["fleet"]] == [True, True]'
  expect_json '"FLEET_RUNNERCTL" in d["fleet"][0]["error"]'
  expect_json '"chmod 755" in d["fleet"][1]["error"]'
  expect_json '"chmod" not in d["fleet"][0]["error"]'
}

# fleet health renders through the same helper, and it is the surface a cron
# job reads: a monitor that fires with no remedy in the line wakes someone at
# 03:00 to re-derive this.
case_fleet_health_carries_the_bootstrap_remedy() {
  RUNNERCTL_STUB_FLEET_HOSTS="box-noinstall" run fleet health
  expect_rc 1
  expect_out '^box-noinstall: remote exit 127 — .*set FLEET_RUNNERCTL to its absolute path'
  expect_no_out '^ok: '
}

# The one ordering an rc alone cannot settle. A mutating fan-out runs the
# remote command under sudo, so a missing runnerctl arrives as `sudo:
# runnerctl: command not found` at rc 1 — both signatures on one line. It is a
# PATH fault; sending the reader to write a sudoers line fixes nothing.
case_fleet_a_sudo_wrapped_missing_runnerctl_is_a_path_fault_not_a_sudo_one() {
  RUNNERCTL_STUB_FLEET_HOSTS="box-sudowrap" run fleet status
  expect_rc 1
  expect_out '^box-sudowrap +remote exit 1 — .*runnerctl is not on that host'
  expect_no_out 'needs passwordless sudo'
}

case_fleet_status_version_skew_note() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" run fleet status
  expect_rc 0
  expect_out_count "^note: the hosts are not all on one runnerctl version .*run 'runnerctl upgrade' on the ones that lag$" 1
  # level fleet: no note at all
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet status
  expect_rc 0
  expect_no_out '^note: the hosts are not all on one runnerctl version'
}

# The envelope nests each host's payload UNCHANGED — that is what lets fleet
# mode work with no JSON parser on the central node, so it has to stay true.
case_fleet_status_json_nests_each_payload_unchanged() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 gw-unreachable" run fleet status --json
  expect_rc 1
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: fleet envelope assertions not run"; return 0; fi
  expect_json 'len(d["fleet"]) == 3'
  expect_json '[h["host_name"] for h in d["fleet"]] == ["build-1", "build-2", "gw-unreachable"]'
  # the nested object is the host's own status payload, slots and all
  expect_json 'len(d["fleet"][0]["status"]["slots"]) == 3'
  expect_json 'd["fleet"][0]["status"]["slots"][0]["name"] == "example.slot-1"'
  expect_json 'd["fleet"][0]["status"]["host"]["cores"] == 16'
  # GHR-38: the payload names the host itself, independently of the ssh alias
  expect_json 'd["fleet"][0]["status"]["host"]["name"] == "stub-host-1"'
  expect_json 'd["fleet"][0]["host_name"] != d["fleet"][0]["status"]["host"]["name"]'
  # a host that did not answer carries a null status, never a fabricated one
  expect_json 'd["fleet"][2]["status"] is None and d["fleet"][2]["reachable"] is False'
  expect_json 'd["fleet"][0]["error"] is None and "No route to host" in d["fleet"][2]["error"]'
}

# exit 0 + reachable + no error + no payload is the one combination a
# consumer cannot interpret, so a non-object answer says what went wrong.
case_fleet_status_json_rejects_a_non_object_payload() {
  RUNNERCTL_STUB_FLEET_HOSTS="ugly-garbage" run fleet status --json
  expect_rc 1
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: payload-sanity assertions not run"; return 0; fi
  expect_json 'd["fleet"][0]["status"] is None'
  expect_json 'd["fleet"][0]["exit_code"] == 0 and d["fleet"][0]["reachable"] is True'
  expect_json '"no JSON object on stdout" in d["fleet"][0]["error"]'
}

# GHR-57: `--stall-after` was accepted and silently dropped on the way to the
# remote — the STALLED marker is drawn wherever STALL_SEC is READ, which for
# a fleet is the remote host, never the central node. Mirrors
# case_fleet_watch_colour_comes_from_the_remote_and_notes_still_dedupe for the
# one-shot table. --color is deliberately NOT forwarded here (unlike watch):
# `fleet status` asks the remote for --color never and paints locally.
case_fleet_status_forwards_stall_after_to_the_remote_table() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet status --stall-after 600
  expect_rc 0
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never --stall-after 600$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never --stall-after 600$' 1
  expect_out_count '^build-1 +0 +example\.slot-1 .* my-app:test \(12m\) STALLED$' 1
  expect_out_count '^build-2 +0 +example\.slot-1 .* my-app:test \(12m\) STALLED$' 1
  # one deduped note for the fleet, not one per host
  expect_out_count '^note: STALLED = a job running longer than 10m \(STALL_SEC=600\)' 1
  expect_no_out '^build-[12] .*note: STALLED'
}

# The same threshold has to reach the --json fan-out too, or a consumer
# reading `job.stalled` after passing `--stall-after` is asking two questions
# instead of one (the issue's own reasoning for forwarding here as well).
case_fleet_status_json_forwards_stall_after_to_the_remote() {
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: fleet --json stall-after assertions not run"; return 0; fi
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet status --stall-after 600 --json
  expect_rc 0
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json --stall-after 600$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json --stall-after 600$' 1
  expect_json 'd["fleet"][0]["status"]["slots"][0]["job"]["stalled"] is True'
  expect_json 'd["fleet"][1]["status"]["slots"][0]["job"]["stalled"] is True'
}

case_fleet_unconfigured_says_so() {
  run fleet status
  expect_rc 1
  expect_err 'fleet mode is not configured — set FLEET_HOSTS='
  expect_no_log '^probe:ssh_run '
}

case_fleet_health_all_healthy_is_one_line_exit_zero() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet health
  expect_rc 0
  expect_out '^ok: 6 slot\(s\) healthy across 2 host\(s\)$'
  expect_out_count '^ok: ' 1
}

# A problem keeps the single-host wording and gains its host, so the format
# people already read survives the aggregation.
case_fleet_health_problem_is_attributed_to_its_host() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet health --stall-after 600
  expect_rc 1
  expect_out '^build-1: example\.slot-1: stalled — job my-app:test running 12m, longer than 10m \(--stall-after 600\)$'
  expect_out '^build-2: example\.slot-1: stalled — '
  expect_no_out '^ok: '
  # the flag really reached the hosts rather than being matched locally
  expect_log_count '^probe:ssh_run build-1 -- runnerctl health --stall-after 600$' 1
}

# THE assertion this command exists for: a host that did not answer can never
# produce a green fleet. A monitor going green because a host dropped out of
# the fan-out is worse than no monitor at all.
case_fleet_health_unreachable_host_is_a_problem_never_a_silent_pass() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" run fleet health
  expect_rc 1
  expect_out '^gw-unreachable: unreachable — ssh: connect to host gw-unreachable port 22: No route to host$'
  expect_no_out '^ok: '
  # a timeout is the same class of unknown, and says which it was
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-timeout" run fleet health
  expect_rc 1
  expect_out '^slow-timeout: timed out after 30s$'
  expect_no_out '^ok: '
}

# A runner-less host exits 1 with its message on STDERR, so it contributes no
# problem line of its own. Without the stderr fallback it would count as
# neither a problem nor an ok, and a fleet of one such host would exit 0 with
# the failure invisible.
case_fleet_health_remote_die_with_empty_stdout_is_still_a_problem() {
  RUNNERCTL_STUB_FLEET_HOSTS="box-norunners" run fleet health
  expect_rc 1
  expect_out "^box-norunners: remote exit 1 — runnerctl: no 'actions\\.runner\\.\\*\\.service' units found on this host\\.$"
  expect_no_out '^ok: '
}

case_fleet_health_quiet_keeps_the_exit_code() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" run fleet health --quiet
  expect_rc 1
  expect_no_out '.'
  # --quiet is local: forwarding it would silence the very output the
  # problem lines are read from
  expect_log_count '^probe:ssh_run build-1 -- runnerctl health$' 1
  expect_no_log 'runnerctl health.*--quiet'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet health --quiet
  expect_rc 0
  expect_no_out '.'
}

case_fleet_health_unknown_option_dies() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet health --bogus
  expect_rc 1
  expect_err 'unknown option: --bogus'
  expect_no_log '^probe:ssh_run '
  # a bad value fails once, before anything is dialled
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet health --max-restarts nope
  expect_rc 1
  expect_err "--max-restarts value 'nope' is invalid"
  expect_no_log '^probe:ssh_run '
}

case_fleet_upgrade_check_reports_each_host_and_counts() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver box-ahead" run fleet upgrade --check
  expect_rc 0
  expect_out '^build-1 +1\.0\.0 +up to date$'
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +update available$'
  expect_out '^box-ahead +9\.9\.9 -> 1\.0\.0 +ahead of the source — left alone$'
  expect_out '^3 host\(s\): 2 up to date, 1 would change, 0 unreachable or unclear$'
  expect_log_count '^probe:ssh_run build-1 -- runnerctl upgrade --check$' 1
  # --check writes nothing anywhere
  expect_no_log '^(systemctl|sudo|tee|rm|mkdir|chown|chmod) '
}

# GHR-52: upgrade gained placement lines (note:/relocated:/retired:), and
# fleet_upgrade_report classifies a host by grepping its stdout — treating
# anything it cannot classify as a FAILED host. So every added line is a chance
# to turn a healthy fan-out red, and this pins that it does not.
#
# It also pins the honest reporting of the half-done case: a host that retired
# its shadow but could not write the system copy must NOT read as `upgraded`.
case_fleet_upgrade_classifies_a_self_healing_host_not_as_unrecognised() {
  RUNNERCTL_STUB_FLEET_HOSTS="box-relocating box-retireonly" run fleet upgrade
  expect_rc 0
  expect_out '^box-relocating +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^box-retireonly +1\.0\.0 -> 9\.9\.9 +update available$'
  expect_no_out 'unrecognised'
  # 0 unclear is the assertion that matters: an unclassified host is counted
  # as bad and would fail the whole fan-out.
  expect_out '^2 host\(s\): 0 already level, 2 upgraded, 0 unreachable or unclear$'
}

case_fleet_upgrade_applies_and_says_what_changed() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" run fleet upgrade
  expect_rc 0
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^2 host\(s\): 1 already level, 1 upgraded, 0 unreachable or unclear$'
  # no --check reached the hosts this time
  expect_log_count '^probe:ssh_run build-2-oldver -- runnerctl upgrade$' 1
}

# A partly upgraded fleet is the normal outcome of a flaky network. Losing
# which host is still behind is the failure that matters, so a bad host is a
# row and the rest still upgrade.
case_fleet_upgrade_failed_host_is_a_row_not_an_abort() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver gw-unreachable slow-timeout" run fleet upgrade
  expect_rc 1
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^gw-unreachable +— +unreachable — '
  # GHR-81: an upgrade is a mutating call — its own budget, and a timeout that
  # says the host may have carried on rather than "nothing is known"
  expect_out "^slow-timeout +— +timed out after 900s — the command may still be running on that host; 'runnerctl fleet status' shows where it got to\$"
  expect_out '^3 host\(s\): 0 already level, 1 upgraded, 2 unreachable or unclear$'
}

# An answer the reporter does not recognise is SHOWN, never folded into "up
# to date" — a silent pass for a host that said something else is what sends
# someone to the wrong box.
case_fleet_upgrade_unrecognised_answer_is_shown_not_guessed() {
  RUNNERCTL_STUB_FLEET_HOSTS="node-weird" run fleet upgrade --check
  expect_rc 1
  expect_out '^node-weird +1\.0\.0 +unrecognised: something this tool has never said before$'
  # the ROW must not claim a state the host never reported (the summary line
  # legitimately contains the words "0 up to date")
  expect_no_out '^node-weird .*up to date'
  expect_out '^1 host\(s\): 0 up to date, 0 would change, 1 unreachable or unclear$'
}

case_fleet_upgrade_ref_is_forwarded_and_bad_option_dies() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet upgrade --ref v1.2.3
  expect_rc 0
  expect_log_count '^probe:ssh_run build-1 -- runnerctl upgrade --ref v1\.2\.3$' 1
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet upgrade --bogus
  expect_rc 1
  expect_err 'unknown option: --bogus'
  expect_no_log '^probe:ssh_run '
}

# --- GHR-82: targeted, staged and read back -----------------------------------
# The stub's upgrade hosts, by name: *oldver* writes and then answers 9.9.9;
# *shadowed* says it wrote and goes on answering 0.0.1; *writefail* answers
# --check and fails the write; *verifydown* writes and cannot be reached for
# the read-back; a plain name is already up to date.
#
# A WRITE is `-- runnerctl upgrade$` in the call log, a check `upgrade --check$`
# and a read-back `-- runnerctl version$` — three different lines, so each
# claim below is pinned on the call it is about.
case_fleet_upgrade_host_targets_only_those_hosts() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver build-3-oldver" run fleet upgrade --host build-2-oldver
  expect_rc 0
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^1 host\(s\): 0 already level, 1 upgraded, 0 unreachable or unclear$'
  expect_out '^1 host\(s\) on 9\.9\.9$'
  # its write and its read-back, and nothing to anyone else
  expect_log_count '^probe:ssh_run ' 2
  expect_no_log '^probe:ssh_run build-1 '
  expect_no_log '^probe:ssh_run build-3-oldver '
  expect_no_out '^build-(1|3-oldver) '
  # repeatable, and it narrows --check the same way
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver build-3-oldver" \
    run fleet upgrade --check --host build-1 --host=build-3-oldver
  expect_rc 0
  expect_log_count '^probe:ssh_run ' 2
  expect_no_log '^probe:ssh_run build-2-oldver '
  expect_out '^2 host\(s\): 1 up to date, 1 would change, 0 unreachable or unclear$'
  # FLEET_BUDGETS is indexed like FLEET_HOSTS: the narrowed host is index 0 of
  # the fan-out and index 1 of the config, and it must still get the mutating
  # budget for a write that takes longer than FLEET_TIMEOUT
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" RUNNERCTL_STUB_FLEET_DELAY="build-2-oldver:45:upgrade" \
    run fleet upgrade --host build-2-oldver
  expect_rc 0
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
}

case_fleet_upgrade_host_unknown_dies_before_dialling() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" run fleet upgrade --host typo-1
  expect_rc 1
  expect_err "--host 'typo-1' is not in FLEET_HOSTS \(configured: build-1 build-2-oldver\)"
  expect_no_log '^probe:ssh_run '
}

# THE READ-BACK. A host that printed `Upgraded` used to be `upgraded` on that
# sentence alone. box-shadowed prints it and then answers the old version
# through the fleet path — the home copy shadowing the system one — and that
# is a failed row and a non-zero exit, with the two versions named.
case_fleet_upgrade_read_back_mismatch_is_a_failed_row() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 box-shadowed build-3-oldver" run fleet upgrade
  expect_rc 1
  expect_out '^box-shadowed +0\.0\.1 -> 9\.9\.9 +wrote 9\.9\.9 but the fleet path still answers 0\.0\.1$'
  expect_no_out '^box-shadowed .* upgraded$'
  # the host beside it wrote for real, and the read-back says so
  expect_out '^build-3-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^3 host\(s\): 1 already level, 1 upgraded, 1 unreachable or unclear$'
  # the fleet's state is what the hosts ANSWER, not what they said they wrote
  expect_out '^not on one version — 1\.0\.0: build-1; 0\.0\.1: box-shadowed; 9\.9\.9: build-3-oldver$'
  # one read-back per host that wrote, after its write; none for a host that
  # did not write
  expect_log_count '^probe:ssh_run box-shadowed -- runnerctl version$' 1
  expect_log_count '^probe:ssh_run build-3-oldver -- runnerctl version$' 1
  expect_no_log '^probe:ssh_run build-1 -- runnerctl version'
  expect_log_order '^probe:ssh_run box-shadowed -- runnerctl upgrade$' '^probe:ssh_run box-shadowed -- runnerctl version$'
}

# A read-back that cannot reach the host is NOT a mismatch — nothing is known
# about what it runs — and is not a pass either. And it is a READ: it runs on
# FLEET_TIMEOUT (30 s), not on the 900 s the write was given. The delayed
# `version` below takes 45 s, so it times out on the read budget and would
# ANSWER on the mutating one.
case_fleet_upgrade_read_back_unanswered_is_its_own_failure_on_the_read_budget() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver build-3-oldver-verifydown" run fleet upgrade
  expect_rc 1
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^build-3-oldver-verifydown +0\.0\.1 -> 9\.9\.9 +wrote 9\.9\.9 but the read-back did not answer: unreachable — ssh: connect to host build-3-oldver-verifydown port 22: No route to host$'
  expect_no_out 'still answers'
  expect_out '^2 host\(s\): 0 already level, 1 upgraded, 1 unreachable or unclear$'
  expect_out '^not on one version — 9\.9\.9: build-2-oldver; unknown: build-3-oldver-verifydown$'
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver" RUNNERCTL_STUB_FLEET_DELAY="build-2-oldver:45:version" \
    run fleet upgrade
  expect_rc 1
  # no "may still be running": the call that timed out changed nothing
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +wrote 9\.9\.9 but the read-back did not answer: timed out after 30s$'
  expect_out '^not on one version — unknown: build-2-oldver$'
  # ...while the write itself still has the mutating budget
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver" RUNNERCTL_STUB_FLEET_DELAY="build-2-oldver:45:upgrade" \
    run fleet upgrade
  expect_rc 0
  expect_out '^1 host\(s\) on 9\.9\.9$'
}

# The negative control. --check dials each host exactly once, for `upgrade
# --check`: no write, and no read-back. The fleet is chosen so that a read-back
# aimed at "every host that answered" or at "every host that would change"
# would both have something to dial here.
case_fleet_upgrade_check_writes_nothing_and_reads_nothing_back() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver box-shadowed box-relocating" run fleet upgrade --check --ref v1.2.3
  expect_rc 0
  expect_log_count '^probe:ssh_run ' 4
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl upgrade --check --ref v1\.2\.3$' 4
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl version'
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl upgrade( --ref [^ ]+)?$'
  expect_out '^4 host\(s\): 1 up to date, 3 would change, 0 unreachable or unclear$'
  # the resulting-state line belongs to a write
  expect_no_out '^[0-9]+ host\(s\) on '
  expect_no_out '^not on one version'
  # the staging flags stage a write, so with --check they are refused rather
  # than silently ignored — before anything is dialled
  local f
  for f in --canary --serial --stop-on-failure; do
    RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" run fleet upgrade --check "$f"
    expect_rc 1
    expect_err 'stage a write, and --check writes nothing'
    expect_no_log '^probe:ssh_run '
  done
}

# --canary with no name: the first host that WOULD CHANGE, not the first host.
# build-1 is first and already up to date — upgrading it proves nothing about
# the release — so the canary is build-2-oldver: checked, written, read back,
# and only then is anyone else asked to write.
case_fleet_upgrade_canary_is_the_first_host_that_would_change() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver build-3-oldver" run fleet upgrade --canary
  expect_rc 0
  expect_out '^canary build-2-oldver: upgraded 0\.0\.1 -> 9\.9\.9 and the fleet path answers 9\.9\.9 — continuing with 2 other host\(s\)$'
  expect_out '^build-1 +1\.0\.0 +up to date$'
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^build-3-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^3 host\(s\): 1 already level, 2 upgraded, 0 unreachable or unclear$'
  # the check round asks everyone and writes nowhere; then the canary's write
  # and its read-back are both over before the next write is dialled
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl upgrade --check$' 3
  expect_log_order '^probe:ssh_run build-3-oldver -- runnerctl upgrade --check$' \
                   '^probe:ssh_run build-2-oldver -- runnerctl upgrade$' \
                   '^probe:ssh_run build-2-oldver -- runnerctl version$' \
                   '^probe:ssh_run_done build-2-oldver$' \
                   '^probe:ssh_run build-3-oldver -- runnerctl upgrade$'
  expect_log_order '^probe:ssh_run build-2-oldver -- runnerctl version$' \
                   '^probe:ssh_run_done build-2-oldver$' \
                   '^probe:ssh_run build-1 -- runnerctl upgrade$'
  # each host is written once
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl upgrade$' 3
  # --ref reaches the check round and the write alike
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" run fleet upgrade --canary --ref v1.2.3
  expect_rc 0
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl upgrade --check --ref v1\.2\.3$' 2
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl upgrade --ref v1\.2\.3$' 2
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl upgrade( --check)?$'
}

# A canary that does not end `upgraded` stops the run: no other host is
# dialled for the write. Twice — a canary whose write is refused, and one that
# wrote and failed its read-back, which is the failure only the read-back sees.
case_fleet_upgrade_failed_canary_touches_no_other_host() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 box-shadowed build-3-oldver" run fleet upgrade --canary
  expect_rc 1
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl upgrade$' 1
  expect_no_log '^probe:ssh_run build-3-oldver -- runnerctl upgrade$'
  expect_no_log '^probe:ssh_run build-1 -- runnerctl upgrade$'
  expect_out '^box-shadowed +0\.0\.1 -> 9\.9\.9 +wrote 9\.9\.9 but the fleet path still answers 0\.0\.1$'
  expect_out '^build-1 +1\.0\.0 +not attempted$'
  expect_out '^build-3-oldver +0\.0\.1 -> 9\.9\.9 +not attempted$'
  expect_out '^3 host\(s\): 0 already level, 0 upgraded, 1 unreachable or unclear, 2 not attempted$'
  expect_out '^canary box-shadowed did not end upgraded — not attempted: build-1 build-3-oldver$'
  expect_no_out 'continuing with'
  # what the check round read is still what those hosts run
  expect_out '^not on one version — 1\.0\.0: build-1; 0\.0\.1: box-shadowed build-3-oldver$'
  RUNNERCTL_STUB_FLEET_HOSTS="box-writefail build-3-oldver" run fleet upgrade --canary
  expect_rc 1
  expect_out '^box-writefail +— +remote exit 1 — sudo: a password is required — the ssh login needs passwordless sudo on that host'
  expect_no_log '^probe:ssh_run build-3-oldver -- runnerctl upgrade$'
  # a write that failed is not read back
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl version'
  expect_out '^canary box-writefail did not end upgraded — not attempted: build-3-oldver$'
  # ...and a canary that FAILS nothing and changes nothing stops it too. The
  # retire-only host answers the check `Update available.` and the write the
  # same way (it could not write the system copy): not a failed row, and not
  # a release tried on anything. A gate of "the canary did not fail" would
  # wave the fleet through on it.
  RUNNERCTL_STUB_FLEET_HOSTS="box-retireonly build-3-oldver" run fleet upgrade --canary
  expect_rc 1
  expect_out '^box-retireonly +1\.0\.0 -> 9\.9\.9 +update available$'
  expect_no_log '^probe:ssh_run build-3-oldver -- runnerctl upgrade$'
  expect_out '^build-3-oldver +0\.0\.1 -> 9\.9\.9 +not attempted$'
  expect_out '^canary box-retireonly did not end upgraded — not attempted: build-3-oldver$'
}

# --canary H names it. A named canary that would not change is refused before
# any write, naming the hosts that would; one that is not a target dies before
# anything is dialled; and when NO host would change there is nothing to try
# a release on, which is said rather than passed off as a successful canary.
case_fleet_upgrade_canary_named_and_nothing_to_canary() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver build-3-oldver" run fleet upgrade --canary build-3-oldver
  expect_rc 0
  expect_out '^canary build-3-oldver: upgraded 0\.0\.1 -> 9\.9\.9 and the fleet path answers 9\.9\.9 — continuing with 2 other host\(s\)$'
  expect_log_order '^probe:ssh_run build-3-oldver -- runnerctl upgrade$' \
                   '^probe:ssh_run build-3-oldver -- runnerctl version$' \
                   '^probe:ssh_run_done build-3-oldver$' \
                   '^probe:ssh_run build-2-oldver -- runnerctl upgrade$'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver build-3-oldver" run fleet upgrade --canary=build-1
  expect_rc 1
  expect_err "--canary 'build-1' would not change \(up to date\), so it proves nothing about this release — nothing was written\. Hosts that would change: build-2-oldver build-3-oldver$"
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl upgrade$'
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl version'
  # a canary outside the targets — unknown, or narrowed away by --host
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" run fleet upgrade --canary nope
  expect_rc 1
  expect_err "--canary 'nope' is not among the hosts this upgrade targets \(build-1 build-2-oldver\)"
  expect_no_log '^probe:ssh_run '
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver" run fleet upgrade --host build-1 --canary build-2-oldver
  expect_rc 1
  expect_err "--canary 'build-2-oldver' is not among the hosts this upgrade targets \(build-1\)"
  expect_no_log '^probe:ssh_run '
  # nobody would change
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 box-ahead" run fleet upgrade --canary
  expect_rc 0
  expect_out '^2 host\(s\): 2 up to date, 0 would change, 0 unreachable or unclear$'
  expect_out '^fleet upgrade --canary: no host would change, so there is nothing to try a release on — nothing was written$'
  expect_no_out '^canary '
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl upgrade$'
  expect_log_count '^probe:ssh_run ' 2
}

# --serial: one host at a time, each written AND read back before the next is
# dialled — asserted with the overlap detector, for the reason the mutating
# fan-out's own case gives. The default is still parallel, which is also what
# shows the detector can fire here. And --serial alone does not stop: the host
# after a failed one is still upgraded.
case_fleet_upgrade_serial_is_one_host_at_a_time_and_does_not_stop() {
  RUNNERCTL_STUB_DETECT_OVERLAP=1 RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver build-3-oldver build-4-oldver" \
    run fleet upgrade --serial
  expect_rc 0
  expect_no_log '^probe:ssh_run_overlap '
  expect_log_order '^probe:ssh_run build-2-oldver -- runnerctl upgrade$' \
                   '^probe:ssh_run build-2-oldver -- runnerctl version$' \
                   '^probe:ssh_run_done build-2-oldver$' \
                   '^probe:ssh_run build-3-oldver -- runnerctl upgrade$' \
                   '^probe:ssh_run build-3-oldver -- runnerctl version$' \
                   '^probe:ssh_run_done build-3-oldver$' \
                   '^probe:ssh_run build-4-oldver -- runnerctl upgrade$'
  expect_out '^3 host\(s\) on 9\.9\.9$'
  RUNNERCTL_STUB_DETECT_OVERLAP=1 RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver build-3-oldver build-4-oldver" \
    run fleet upgrade
  expect_rc 0
  expect_log '^probe:ssh_run_overlap '
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver box-shadowed build-4-oldver" run fleet upgrade --serial
  expect_rc 1
  expect_out '^build-4-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_no_out 'not attempted'
  expect_out '^3 host\(s\): 0 already level, 2 upgraded, 1 unreachable or unclear$'
}

# --stop-on-failure: the same walk, halted at the first failed row, with the
# hosts it did not attempt named. A failed READ-BACK halts it too — the write
# said it went fine.
case_fleet_upgrade_stop_on_failure_halts_and_names_the_rest() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver box-shadowed build-4-oldver build-5-oldver" \
    run fleet upgrade --stop-on-failure
  expect_rc 1
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  expect_out '^box-shadowed +0\.0\.1 -> 9\.9\.9 +wrote 9\.9\.9 but the fleet path still answers 0\.0\.1$'
  expect_out '^build-4-oldver +— +not attempted$'
  expect_out '^build-5-oldver +— +not attempted$'
  expect_no_log '^probe:ssh_run build-4-oldver '
  expect_no_log '^probe:ssh_run build-5-oldver '
  expect_out '^4 host\(s\): 0 already level, 1 upgraded, 1 unreachable or unclear, 2 not attempted$'
  expect_out '^stopped at box-shadowed — not attempted: build-4-oldver build-5-oldver$'
  expect_out '^not on one version — 9\.9\.9: build-2-oldver; 0\.0\.1: box-shadowed; unknown: build-4-oldver build-5-oldver$'
  # a write that fails halts it as well
  RUNNERCTL_STUB_FLEET_HOSTS="box-writefail build-4-oldver" run fleet upgrade --stop-on-failure
  expect_rc 1
  expect_no_log '^probe:ssh_run build-4-oldver '
  expect_out '^stopped at box-writefail — not attempted: build-4-oldver$'
  # nothing fails, nothing is skipped; and after a verified canary the rest
  # are walked the same way
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver box-shadowed build-4-oldver" \
    run fleet upgrade --canary --stop-on-failure
  expect_rc 1
  expect_out '^canary build-2-oldver: upgraded '
  expect_log_count '^probe:ssh_run build-1 -- runnerctl upgrade$' 1
  expect_no_log '^probe:ssh_run build-4-oldver -- runnerctl upgrade$'
  expect_out '^build-4-oldver +0\.0\.1 -> 9\.9\.9 +not attempted$'
  expect_out '^stopped at box-shadowed — not attempted: build-4-oldver$'
}

# The two parsers the read-back rests on, against lines the stub did not
# write: the real `version` command's output, and cmd_upgrade's sentence with
# the trailing path a relocation gives it. (tests/upgrade-test.sh 1b runs them
# over a real upgrade's captured output.)
case_fleet_upgrade_read_back_parsers() {
  "$RUNNERCTL" version >"$TMP/version.out"
  run_fn fleet_version_answer "$TMP/version.out"
  expect_rc 0
  expect_out '^[0-9]+\.[0-9]+\.[0-9]+$'
  expect_text "the version runnerctl version prints" "$(cut -d' ' -f2 "$TMP/version.out")" "$OUT"
  printf 'installed: 0.0.1 (/a b/runnerctl)\nnote: x\nUpgraded 0.0.1 -> 1.2.3 at /a b/runnerctl\n' >"$TMP/upgrade.out"
  run_fn fleet_upgrade_wrote "$TMP/upgrade.out"
  expect_rc 0
  expect_text "the version an Upgraded sentence names" "1.2.3" "$OUT"
  # neither invents an answer: a die on the remote, and a host that only
  # reported an update, name no version
  printf "runnerctl: unknown command 'version'\n" >"$TMP/version.out"
  run_fn fleet_version_answer "$TMP/version.out"
  expect_rc 0
  expect_text "a version answer that is not one" "" "$OUT"
  printf 'Update available. Run: runnerctl upgrade\n' >"$TMP/upgrade.out"
  run_fn fleet_upgrade_wrote "$TMP/upgrade.out"
  expect_rc 0
  expect_text "an output with no Upgraded sentence" "" "$OUT"
}

case_fleet_mutating_fans_out_and_forwards_flags() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet restart --when-idle --timeout 60
  expect_rc 0
  expect_out '^build-1: restart done\.$'
  expect_out '^build-2: restart done\.$'
  expect_out '^fleet restart: 2 host\(s\) ok, 0 failed$'
  # the remote command's own flags go through untouched
  expect_log_count '^probe:ssh_run build-1 -- runnerctl restart --when-idle --timeout 60$' 1
}

# Mutating commands go ONE HOST AT A TIME; read-only ones do not.
#
# This asserts it with the stub's overlap detector rather than with entry/exit
# ordering. Ordering alone does NOT discriminate: the stub is fast enough that
# parallel calls often fail to overlap, and the first version of this case
# passed against a deliberately parallel fan-out. The detector holds a lock
# for a window, so a parallel caller reliably collides and a serial one
# cannot.
#
# The `status` half is not decoration — it fires the detector, proving the
# detector can fire at all. Without it, "no overlap" would be consistent with
# a detector that never works.
case_fleet_mutating_is_serial_while_status_is_parallel() {
  RUNNERCTL_STUB_DETECT_OVERLAP=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 build-3" \
    run fleet restart
  expect_rc 0
  expect_no_log '^probe:ssh_run_overlap '
  expect_log_order '^probe:ssh_run build-1 -- ' '^probe:ssh_run_done build-1$' \
                   '^probe:ssh_run build-2 -- ' '^probe:ssh_run_done build-2$' \
                   '^probe:ssh_run build-3 -- ' '^probe:ssh_run_done build-3$'
  # the read-only path really is parallel, which is what shows the detector
  # is capable of firing
  RUNNERCTL_STUB_DETECT_OVERLAP=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 build-3" \
    run fleet status
  expect_rc 0
  expect_log '^probe:ssh_run_overlap '
}

case_fleet_host_targets_exactly_that_host() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 build-3" run fleet restart --host build-2
  expect_rc 0
  expect_out '^build-2: restart done\.$'
  expect_out '^fleet restart: 1 host\(s\) ok, 0 failed$'
  expect_log_count '^probe:ssh_run ' 1
  expect_no_log '^probe:ssh_run build-1 '
  expect_no_log '^probe:ssh_run build-3 '
  # repeatable
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 build-3" run fleet restart --host build-1 --host build-3
  expect_rc 0
  expect_log_count '^probe:ssh_run ' 2
  expect_no_log '^probe:ssh_run build-2 '
}

# A typo that silently targets nothing, on a command that stops runners, is
# worse than an error — so an unknown host dies BEFORE anything is dialled.
case_fleet_host_unknown_dies_before_dialling() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet restart --host typo-1
  expect_rc 1
  expect_err "--host 'typo-1' is not in FLEET_HOSTS \(configured: build-1 build-2\)"
  expect_no_log '^probe:ssh_run '
}

# The footgun this slice exists to prevent: per-host --when-idle politeness
# does not compose, so every host draining one slot at a time still lands the
# fleet at zero capacity together.
case_fleet_capacity_removal_refused_without_explicit_scope() {
  local c
  for c in stop drain disable; do
    RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet "$c"
    expect_rc 1
    expect_err "'fleet $c' across every host would take the whole pool's capacity down at once"
    expect_err 'Name the hosts with --host H \(repeatable\), or pass --all-hosts'
    expect_no_log '^probe:ssh_run '
  done
  # transient and non-capacity commands are NOT gated
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet restart
  expect_rc 0
  expect_log_count '^probe:ssh_run ' 2
}

case_fleet_capacity_removal_allowed_when_scoped_or_acknowledged() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet drain --host build-1
  expect_rc 0
  expect_out '^build-1: drain done\.$'
  # GHR-81: a drain waits per slot, so each targeted host is first asked how
  # many it has — one read, and still exactly one drain
  expect_log_count '^probe:ssh_run .* -- runnerctl drain$' 1
  expect_log_count '^probe:ssh_run ' 2
  expect_no_log '^probe:ssh_run build-2 '
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet drain --all-hosts
  expect_rc 0
  expect_out '^fleet drain: 2 host\(s\) ok, 0 failed$'
  expect_log_count '^probe:ssh_run .* -- runnerctl drain$' 2
}

# --- GHR-81: a mutating call has its own, much larger budget -------------------
# FLEET_TIMEOUT (30 s) is sized for a status read, and it used to govern every
# remote call. The stub models how long a call takes (RUNNERCTL_STUB_FLEET_DELAY)
# against the budget the caller gave it, so nothing here sleeps.
#
# The delay is the SAME 45 s on every call to the host in both halves — the
# slot-count read a drain makes first times out on it as well, and the drain
# is then budgeted for one slot — so the only thing that separates the half
# that succeeds from the half that times out is which budget the call was on.
case_fleet_drain_outlasts_the_read_only_budget() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_DELAY="build-1:45" \
    run fleet drain --host build-1
  expect_rc 0
  expect_out '^build-1: drain done\.$'
  expect_out '^fleet drain: 1 host\(s\) ok, 0 failed$'
  # no wait involved: FLEET_MUTATE_TIMEOUT on its own covers it too
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_DELAY="build-1:45" \
    run fleet restart --host build-1
  expect_rc 0
  expect_out '^build-1: restart done\.$'
  expect_no_log 'status --json'
  # the negative control: the read-only budget has NOT grown, and a read that
  # ran out says nothing about a command still running
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_DELAY="build-1:45" \
    run fleet status
  expect_rc 1
  expect_out '^build-1 +timed out after 30s$'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_DELAY="build-1:45" \
    run fleet health
  expect_rc 1
  expect_out '^build-1: timed out after 30s$'
}

# When a mutating call does run out, the row must not read as "nothing is
# known": `timeout` kills the local ssh, and the remote carries on. The budget
# in the message is the one the call was actually given, and it is exactly
# FLEET_MUTATE_TIMEOUT — one second less and the call completes.
case_fleet_mutating_timeout_says_it_may_still_be_running() {
  local cfg="$TMP/ghr81.config"
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_DELAY="build-1:900:restart" \
    run fleet restart
  expect_rc 1
  expect_out "^build-1: timed out after 900s — the command may still be running on that host; 'runnerctl fleet status' shows where it got to\$"
  expect_out '^build-2: restart done\.$'
  expect_out '^fleet restart: 1 host\(s\) ok, 1 failed$'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_DELAY="build-1:899:restart" \
    run fleet restart
  expect_rc 0
  expect_out '^fleet restart: 2 host\(s\) ok, 0 failed$'
  # the knob is a config setting like any other, validated before dialling
  save_config "$cfg" <<<'FLEET_MUTATE_TIMEOUT=120'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:119:restart" \
    run_cfg "$cfg" fleet restart
  expect_rc 0
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:120:restart" \
    run_cfg "$cfg" fleet restart
  expect_rc 1
  expect_out '^build-1: timed out after 120s — the command may still be running on that host; '
  save_config "$cfg" <<<'FLEET_MUTATE_TIMEOUT=0'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run_cfg "$cfg" fleet restart
  expect_rc 1
  expect_err "FLEET_MUTATE_TIMEOUT '0' set in .* is invalid — want a whole number of seconds, 1 or more"
  expect_no_log '^probe:ssh_run '
  rm -f "$cfg"
}

# --when-idle waits up to --timeout PER SLOT, one slot after another, so the
# budget is the host's slot count times the wait, plus the action's own
# budget. The stub's hosts have three slots: 3 x 60 + 900 = 1080.
case_fleet_when_idle_budget_is_the_wait_per_slot_plus_the_action() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:1079:restart" \
    run fleet restart --when-idle --timeout 60
  expect_rc 0
  expect_out '^build-1: restart done\.$'
  # the slot count is read first, read-only, and only because of the wait
  expect_log_order '^probe:ssh_run build-1 -- runnerctl status --json$' \
                   '^probe:ssh_run build-1 -- runnerctl restart --when-idle --timeout 60$'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:1080:restart" \
    run fleet restart --when-idle --timeout=60
  expect_rc 1
  expect_out '^build-1: timed out after 1080s — the command may still be running on that host; '
  # no --timeout: this node's WAIT_TIMEOUT (1800), and drain implies the wait
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:6299:drain" \
    run fleet drain --host build-1
  expect_rc 0
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:6300:drain" \
    run fleet drain --host build-1
  expect_rc 1
  expect_out '^build-1: timed out after 6300s — the command may still be running on that host; '
  # a host that does not answer the slot-count read is still asked to do the
  # work, budgeted as one slot: 1 x 60 + 900
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:45:status build-1:959:restart" \
    run fleet restart --when-idle --timeout 60
  expect_rc 0
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:45:status build-1:960:restart" \
    run fleet restart --when-idle --timeout 60
  expect_rc 1
  expect_out '^build-1: timed out after 960s — '
}

# The arithmetic on its own, through the real function.
case_fleet_mutate_budget_arithmetic() {
  run_fn fleet_mutate_budget restart 3
  expect_out '^900$'
  # --timeout without --when-idle bounds nothing on the remote, so adds nothing
  run_fn fleet_mutate_budget restart 3 --timeout 60
  expect_out '^900$'
  run_fn fleet_mutate_budget restart 3 --when-idle --timeout 60
  expect_out '^1080$'
  run_fn fleet_mutate_budget stop 2 --timeout=10 --when-idle
  expect_out '^920$'
  run_fn fleet_mutate_budget drain 3
  expect_out '^6300$'
  # a --timeout the remote will refuse falls back to WAIT_TIMEOUT
  run_fn fleet_mutate_budget restart 1 --when-idle --timeout nope
  expect_out '^2700$'
  expect_rc 0
}

# The budget walk makes one remote call per SLOT, so each gets one slot's
# budget — and the status re-reads between them stay on FLEET_TIMEOUT.
case_fleet_budget_walk_gives_each_slot_the_mutating_budget() {
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    RUNNERCTL_STUB_FLEET_DELAY="build-1:45:restart" run fleet restart --max-unavailable 1
  expect_rc 0
  expect_out '^build-1 slot 0: restart ok$'
  expect_out '^fleet restart: 4 slot\(s\) done, 0 failed$'
  # under --when-idle a slot's budget is its wait plus the action: 60 + 900
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    RUNNERCTL_STUB_FLEET_DELAY="build-1:959:restart" run fleet restart --max-unavailable 1 --when-idle --timeout 60
  expect_rc 0
  expect_out '^fleet restart: 4 slot\(s\) done, 0 failed$'
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    RUNNERCTL_STUB_FLEET_DELAY="build-1:960:restart" run fleet restart --max-unavailable 1 --when-idle --timeout 60
  expect_rc 1
  # not "(exit 124)": the slot is not known to have failed
  expect_out_count "^build-1 slot [01]: restart FAILED \\(timed out after 960s — the command may still be running on that host; 'runnerctl fleet status' shows where it got to\\)\$" 2
  expect_out '^build-2 slot 1: restart ok$'
  expect_out '^fleet restart: 2 slot\(s\) done, 2 failed$'
  # the negative control: a re-read that takes 45 s is still a host that did
  # not answer — the slot budget is lent to the slot action and nothing else
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    RUNNERCTL_STUB_FLEET_DELAY="build-1:45:status" run fleet restart --max-unavailable 1
  expect_out '^warning: 1 host\(s\) did not answer — the budget is being held over the 2 slot\(s\) that did$'
  expect_no_log '^probe:ssh_run build-1 -- runnerctl restart'
  # ...and that has to hold for a re-read made AFTER a slot action, which the
  # run above cannot show: its slow host is out before anything is acted on.
  # Here build-2 never answers a read in time, so the floor is held over
  # build-1's two slots alone: one drained, one left. Were the re-reads on
  # the long budget, build-2's would answer, its two slots would count as
  # available, and build-1 would be drained dry.
  #
  # What this does NOT separate, measured: the walk naming the slot budget
  # for its one call from the fan-out naming its own budget for every read.
  # Either alone keeps the re-reads short — a walk that left its slot budget
  # set stayed green here, because fleet_fanout_one overrode it — so this
  # goes red only when the fan-out itself lends a read the long budget.
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    RUNNERCTL_STUB_FLEET_DELAY="build-2:45:status" run fleet drain --min-available 1
  expect_rc 2
  expect_out '^fleet drain: 1 slot\(s\) done, 0 failed, 1 left running at the floor$'
  expect_out '^left running to hold --min-available 1: build-1/1$'
}

# `fleet watch`'s action keys, `fleet upgrade` and `fleet health
# --restart-stalled` are the other mutating callers of ssh_run.
case_fleet_other_mutating_callers_are_on_the_mutating_budget() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jRy-q' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    RUNNERCTL_STUB_FLEET_DELAY="build-1:45:restart" run fleet watch --color never
  expect_rc 0
  expect_out '^example\.slot-2 on build-1: restart done\.$'
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jRy-q' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    RUNNERCTL_STUB_FLEET_DELAY="build-1:900:restart" run fleet watch --color never
  expect_rc 0
  expect_out "^example\\.slot-2 on build-1: restart failed — timed out after 900s — the command may still be running on that host; 'runnerctl fleet status' shows where it got to\$"
  # upgrade: the remote's own download is allowed 30 s, which used to be the
  # whole budget around it
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver" RUNNERCTL_STUB_FLEET_DELAY="build-2-oldver:45:upgrade" \
    run fleet upgrade
  expect_rc 0
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 +upgraded$'
  # --check downloads too, so it is on the same budget — but it changes
  # nothing, so its timeout does not claim a command is still running
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver" RUNNERCTL_STUB_FLEET_DELAY="build-2-oldver:45:upgrade" \
    run fleet upgrade --check
  expect_out '^build-2-oldver +0\.0\.1 -> 9\.9\.9 '
  RUNNERCTL_STUB_FLEET_HOSTS="build-2-oldver" RUNNERCTL_STUB_FLEET_DELAY="build-2-oldver:900:upgrade" \
    run fleet upgrade --check
  expect_rc 1
  expect_out '^build-2-oldver +— +timed out after 900s$'
  # health: read-only until it is asked to restart what it finds
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:45:health" \
    run fleet health --restart-stalled
  expect_rc 0
  expect_no_out 'timed out'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_FLEET_DELAY="build-1:900:health" \
    run fleet health --restart-stalled
  expect_rc 1
  expect_out "^build-1: timed out after 900s — the command may still be running on that host; 'runnerctl fleet status' shows where it got to\$"
}

# Every case above goes through the stub's ssh_run, which MODELS `timeout`.
# This one runs the real ssh_run against a fake `ssh` that takes two seconds,
# so what is pinned is the real wrapper: it cuts a call off at FLEET_TIMEOUT,
# and at FLEET_CALL_TIMEOUT instead when the caller named one.
case_fleet_real_ssh_run_times_out_on_the_budget_of_the_call() {
  local d saved="$PATH"
  d="$(mktemp -d "$TMP/ghr81.XXXXXX")"
  mkdir "$d/bin"
  printf '#!/bin/sh\nsleep 2\necho "answered: $*"\n' >"$d/bin/ssh"
  chmod +x "$d/bin/ssh"
  PATH="$d/bin:$PATH"
  run_fn eval 'FLEET_TIMEOUT=1; ssh_run host-a runnerctl status'
  expect_rc 124
  expect_no_out 'answered'
  run_fn eval 'FLEET_TIMEOUT=1; FLEET_CALL_TIMEOUT=30 ssh_run host-a runnerctl restart'
  PATH="$saved"
  expect_rc 0
  expect_out '^answered: -o BatchMode=yes -o ConnectTimeout=10 -- host-a runnerctl restart$'
  rm -rf "$d"
}

# The most likely failure of a mutating fan-out, and the one BatchMode=yes
# turns into a report instead of a hang. `run` kills the case after
# RUN_TIMEOUT, so a regression that reintroduces the hang fails here rather
# than wedging the gate.
case_fleet_sudo_failure_is_a_named_row_with_the_remedy() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 box-nosudo" run fleet restart
  expect_rc 1
  expect_out '^box-nosudo: remote exit 1 — sudo: a password is required — the ssh login needs passwordless sudo on that host; see the fleet section of the README for the exact sudoers line$'
  # the healthy host still did its work, and the count is honest
  expect_out '^build-1: restart done\.$'
  expect_out '^fleet restart: 1 host\(s\) ok, 1 failed$'
}

# Not "unknown command": these are three different deliberate exclusions and
# the message says which, so nobody re-files them as missing features.
case_fleet_excluded_commands_say_why() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet env-init
  expect_rc 1
  expect_err 'fleet env-init is not supported and will not be: it writes an EnvironmentFile of secrets'
  expect_no_log '^probe:ssh_run '
  # `watch` used to be refused here alongside these two. It is a command now
  # (GHR-54), and `logs` is the only streaming one left — so the refusal
  # points at the fleet view rather than only at ssh: since GHR-55, at its
  # L key, which pages one slot's recent journal from its host.
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet logs
  expect_rc 1
  expect_err "fleet logs is not supported: logs streams from one journal"
  expect_err "In 'runnerctl fleet watch', L on a slot pages its recent journal from its host; or ssh to the host\.$"
  expect_no_log '^probe:ssh_run '
}

# --- GHR-54: fleet watch -------------------------------------------------------
# The frame prefix, the header and the legend. `fleet watch` reuses cmd_watch's
# loop shape, so the home+clear prefix is the same one the local watch's cases
# count; what differs is what is in the frame and what it cost to fetch.
# GHR-55: the local watch's legend — the same keys, now against a (host, slot)
FLEET_WATCH_LEGEND='^↑↓/jk select  K kill job  R restart  S stop  T start  P reap  L logs  q quit$'

# A terminal is required for the same reason `watch` needs one: the loop
# redraws in place. The refusal names the one-shot to use instead, and nothing
# is dialled before it — a refusal that has already opened six ssh sessions is
# not a refusal.
case_fleet_watch_refuses_non_tty() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet watch
  expect_rc 1
  expect_err "^runnerctl: fleet watch needs a terminal \(stdout is not a tty\); use 'runnerctl fleet status'\$"
  expect_no_out '.'
  expect_no_log '^probe:(ssh_run|ssh_control|term_cursor|pause)'
}

# The point of the command: N ticks are N fan-outs over ONE connection per
# host, opened once and closed once. `watch runnerctl fleet status` is N
# fan-outs over N x hosts fresh logins, which is what sshd throttles.
case_fleet_watch_polls_every_host_over_one_held_connection() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet watch --iterations 3 --interval 4 --color never
  expect_rc 0
  expect_out_count "${FRAME_PREFIX}runnerctl fleet watch — 2 host\(s\) — [0-9]{2}:[0-9]{2}:[0-9]{2} — every 4s \(q to quit\)\$" 3
  expect_out_count "$FRAME_PREFIX" 3
  # one HOST-prefixed table per frame, both hosts in each
  expect_out_count '^HOST +IDX +RUNNER +PROFILE .* WORKING-ON$' 3
  expect_out_count '^build-1 +0 +example\.slot-1 .* my-app:test \(12m\)$' 3
  expect_out_count '^build-2 +0 +example\.slot-1 .* my-app:test \(12m\)$' 3
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 3
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 3
  expect_log_count '^probe:pause 4$' 3
  # GHR-72: plus the summary's --json pass, once per host per tick
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json$' 3
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json$' 3
  expect_log_count '^probe:ssh_run ' 12
  # the session: master options on EVERY call (12: table and summary, two
  # hosts, three ticks), opened once, closed once
  # per host. ControlPersist comfortably exceeds the 4 s interval, or the gap
  # between two redraws would drop the connection the next redraw reuses.
  expect_log_count '^probe:ssh_control_opts -o ControlMaster=auto -o ControlPath=/.+/%C -o ControlPersist=64$' 12
  expect_log_count '^probe:ssh_control build-1 exit$' 1
  expect_log_count '^probe:ssh_control build-2 exit$' 1
  expect_log_order '^probe:term_cursor hide$' '^probe:pause 4$' '^probe:term_cursor show$' '^probe:ssh_control build-1 exit$'
  expect_log_count '^probe:term_cursor ' 2
  # read-only, and nothing reached `ssh` outside the two sanctioned paths
  expect_no_log '^direct:'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

# Colour comes from the REMOTE, which is the opposite of `fleet status`. The
# host that drew a cell is the only thing that knows it is STALLED, so the
# flag is forwarded and this end only paints the HOST column it added.
#
# Two things this proves that a plain run cannot: the column header keeps the
# remote's own bold after the local HOST cell closes its SGR, and a painted
# `note:` line is still recognised as a note — collected once for the whole
# fleet rather than printed as a slot row on each host.
case_fleet_watch_colour_comes_from_the_remote_and_notes_still_dedupe() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet watch --iterations 1 --color always --stall-after 600
  expect_rc 0
  # --stall-after is forwarded: STALLED is drawn at the far end or not at all
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color always --stall-after 600$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color always --stall-after 600$' 1
  expect_out_count "${FRAME_PREFIX}$ESC\[1mrunnerctl fleet watch — 2 host\(s\) — .* — every 5s \(q to quit\)$ESC\[0m\$" 1
  # HOST is ours and ends its bold; the remote's header follows with its own
  expect_out_count "^$ESC\[1mHOST   $ESC\[0m $ESC\[1mIDX +RUNNER .* WORKING-ON$ESC\[0m\$" 1
  # the remote painted the cells, both hosts
  expect_out_count "^build-1 +0 +example\.slot-1 .* $ESC\[1m$ESC\[31mmy-app:test \(12m\) STALLED$ESC\[0m\$" 1
  expect_out_count "^build-2 +0 +example\.slot-1 .* $ESC\[1m$ESC\[31mmy-app:test \(12m\) STALLED$ESC\[0m\$" 1
  # ONE note for the fleet, painted, not one per host and not a slot row
  expect_out_count "^$ESC\[31mnote: STALLED = a job running longer than 10m .*$ESC\[0m\$" 1
  expect_no_out '^build-[12] +.*note: STALLED'
}

# A host that does not answer is a row in EVERY frame. The loop must not stop
# on it: a watch that dies when one of six hosts reboots is worse than no
# watch, because the five that are fine stop being visible too.
case_fleet_watch_an_unreachable_host_stays_a_row_every_tick() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" \
    run fleet watch --iterations 2 --interval 1 --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 2
  expect_out_count '^gw-unreachable unreachable — ssh: connect to host gw-unreachable port 22: No route to host$' 2
  expect_out_count '^build-1 +0 +example\.slot-1 .* my-app:test \(12m\)$' 2
  # and it is still closed down cleanly: a host with no master is not an error
  expect_log_count '^probe:ssh_control gw-unreachable exit$' 1
}

# --host narrows the watch exactly as it narrows a mutating fan-out, and the
# header counts what is actually being watched. An unknown host dies before
# anything is dialled, reusing fleet_select_hosts' own refusal.
case_fleet_watch_host_narrows_the_fleet() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet watch --host build-2 --iterations 1 --color never
  expect_rc 0
  expect_out '— 1 host\(s\) —'
  expect_out_count '^build-2 +0 +example\.slot-1 ' 1
  expect_no_out '^build-1 '
  # the table and (GHR-72) the summary's --json pass, to build-2 alone
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json$' 1
  expect_log_count '^probe:ssh_run build-2 -- ' 2
  expect_no_log '^probe:ssh_run build-1 -- '
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet watch --host nope
  expect_rc 1
  expect_err "--host 'nope' is not in FLEET_HOSTS"
  expect_no_log '^probe:(ssh_run|ssh_control)'
}

# Interactive: the wait between redraws is a key read, so `q` quits at once
# rather than after the interval. Also pins the 5 s default, which is higher
# than the local watch's 2 s because every tick is a round trip per host.
case_fleet_watch_q_quits_and_the_default_interval_is_five() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='q' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 1
  expect_out '— every 5s \(q to quit\)$'
  expect_out "$FLEET_WATCH_LEGEND"
  expect_log_order '^probe:term_cursor hide$' '^probe:tty_read_char 5 q$' '^probe:term_cursor show$' '^probe:ssh_control build-1 exit$'
  # one fan-out: the table, and (GHR-72) the summary's --json pass
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 1
  expect_log_count '^probe:ssh_run build-1 -- ' 2
  # a key that is not q redraws rather than quitting: one more frame, then Q
  # ends it (uppercase counts too). GHR-55: a key redraws the frame in hand —
  # only a tick (the `-`) or an action that ran costs another fan-out
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='x-Q' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 3
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 2
  expect_log_count '^probe:ssh_run build-1 -- ' 4
}

# The control session itself, driven directly: opened it exists and carries
# the master options, closed it is gone. %C rather than %r@%h:%p is the
# load-bearing part — a unix socket path is capped near 104 bytes and ssh
# stops multiplexing SILENTLY past it, which would turn the poll back into
# the reconnect-per-tick this command exists to remove.
case_fleet_watch_control_session_opens_and_tears_down() {
  # SC2016 disabled deliberately, twice: the single quotes are the POINT.
  # run_fn hands this string to `bash -c` after sourcing the script, so the
  # $1 and $FLEET_SSH_CONTROL_DIR in it must reach THAT shell unexpanded —
  # expanding them here would substitute this harness's values instead.
  # shellcheck disable=SC2016
  run_fn eval '
    ssh_control() { echo "closed $1 $2"; }
    FLEET_HOSTS=(build-1 build-2)
    fleet_ssh_control_open 90
    printf "%s\n" "${FLEET_SSH_CONTROL_OPTS[@]}"
    test -d "$FLEET_SSH_CONTROL_DIR" && echo "dir-exists"
    case "$FLEET_SSH_CONTROL_DIR" in "") echo "dir-unset" ;; esac
    d="$FLEET_SSH_CONTROL_DIR"
    fleet_ssh_control_close
    test -d "$d" || echo "dir-gone"
    echo "opts-left=${#FLEET_SSH_CONTROL_OPTS[@]} dir-left=[$FLEET_SSH_CONTROL_DIR]"
  '
  expect_rc 0
  # printf one per element: `-o` and its value are separate argv words, which
  # is the whole reason this is an array and not a string
  expect_out_count '^-o$' 3
  expect_out '^ControlMaster=auto$'
  expect_out '^ControlPath=/.+/%C$'
  expect_out '^ControlPersist=90$'
  expect_out '^dir-exists$'
  expect_out '^closed build-1 exit$'
  expect_out '^closed build-2 exit$'
  expect_out '^dir-gone$'
  expect_out '^opts-left=0 dir-left=\[\]$'
  # closing a session that was never opened is a no-op, not a failure: the
  # EXIT trap runs whatever the loop got as far as
  # shellcheck disable=SC2016
  run_fn eval 'ssh_control() { echo "closed $1"; }; FLEET_HOSTS=(build-1); fleet_ssh_control_close; echo ok'
  expect_rc 0
  expect_out '^ok$'
  expect_no_out '^closed '
}

# The one thing every other case here CANNOT see. tests/stub.config shadows
# ssh_run wholesale, so no sim case ever runs its body — and a `fleet watch`
# that assembled perfect master options and then never put them on the ssh
# command line would poll exactly as badly as `watch runnerctl fleet status`,
# with every assertion above still green. (It did: the mutation that deleted
# the expansion from ssh_run left the whole suite passing.)
#
# So this drives the REAL ssh_run with `ssh` and `timeout` shadowed inside the
# eval, and reads the argv. It also pins the ORDER, which is a contract of its
# own: FLEET_SSH_OPTS comes LAST so a site can override the watch's sockets.
case_fleet_ssh_run_puts_the_session_options_on_the_ssh_command_line() {
  # shellcheck disable=SC2016
  run_fn eval '
    f="$(mktemp)"
    timeout() { shift; "$@"; }
    ssh() { printf "%s\n" "$*" >>"$f"; }
    FLEET_TIMEOUT=30
    FLEET_SSH_OPTS=(-o SiteOption=yes)
    ssh_run host-a runnerctl status
    fleet_ssh_control_open 90
    ssh_run host-a runnerctl status
    ssh_control host-a exit
    fleet_ssh_control_close
    cat "$f"
    rm -f "$f"
  '
  expect_rc 0
  # no session open: byte-for-byte what a one-shot fan-out sent before GHR-54
  expect_out '^-o BatchMode=yes -o ConnectTimeout=10 -o SiteOption=yes -- host-a runnerctl status$'
  # session open: the master options are ON the command line, ahead of the
  # site's own options
  expect_out '^-o BatchMode=yes -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/.+/%C -o ControlPersist=90 -o SiteOption=yes -- host-a runnerctl status$'
  # and the teardown is a control-socket operation carrying no remote command
  expect_out '^-o BatchMode=yes -o ControlMaster=auto -o ControlPath=/.+/%C -o ControlPersist=90 -O exit -- host-a$'
}

# Every other command leaves the control options EMPTY, so nothing but the
# watch pays for a socket directory — and a one-shot fan-out's ssh command
# line is byte-identical to what it was before GHR-54.
case_fleet_one_shot_commands_open_no_control_session() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet status
  expect_rc 0
  expect_no_log '^probe:ssh_control'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet health
  expect_rc 0
  expect_no_log '^probe:ssh_control'
}

# Option validation happens before anything is dialled, and the two numeric
# flags reject the same shapes the local watch rejects.
case_fleet_watch_bad_options_die_before_dialling() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet watch --interval 0
  expect_rc 1
  expect_err "--interval value '0' is invalid"
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet watch --interval abc
  expect_rc 1
  expect_err "--interval value 'abc' is invalid"
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet watch --bogus
  expect_rc 1
  expect_err 'unknown option: --bogus'
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet watch --color bogus
  expect_rc 1
  expect_err "--color value 'bogus' is invalid"
  # GHR-55: S's floor is a whole number of slots
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet watch --min-available 25%
  expect_rc 1
  expect_err "--min-available value '25%' is invalid — want a whole number of slots \(0 turns the floor off\)$"
  expect_no_log '^probe:(ssh_run|ssh_control)'
  # --interval=N, the =-form every other command takes
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --interval=7 --iterations=1 --color=never
  expect_rc 0
  expect_out '— every 7s \(q to quit\)$'
  # an unconfigured fleet is the manifest-shaped refusal, before the tty one
  run fleet watch
  expect_rc 1
  expect_err 'fleet mode is not configured — set FLEET_HOSTS='
}

# --- GHR-55: fleet watch action keys -------------------------------------------
# The cursor is a (host, slot) pair, highlighted on ONE frame line: every host
# has an example.slot-1, so a row matched by its RUNNER name would light up
# the same slot on every host. The stub's hosts each have three slots: slot-1
# active with a job, slot-2 active and idle, slot-3 inactive.
fw_row() { echo "^${REV}$1 +$2 +example\.slot-$3 .*$ESC\[0m\$"; }
FW2="build-1 build-2"

# j/k walk the pairs across host boundaries and clamp at both ends; a key
# redraws the frame in hand, so walking the cursor costs no fan-out at all.
case_fleet_watch_cursor_walks_host_slot_pairs() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='kjjjkjjjjjq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 11
  expect_out_count "$FLEET_WATCH_LEGEND" 11
  # exactly one highlighted line per frame, and never the same slot on the
  # other host: k (clamped) j j j k j j j j j (clamped)
  expect_out_count "^${REV}" 11
  expect_out_count "$(fw_row build-1 0 1)" 2
  expect_out_count "$(fw_row build-1 1 2)" 1
  expect_out_count "$(fw_row build-1 2 3)" 2
  expect_out_count "$(fw_row build-2 0 1)" 2
  expect_out_count "$(fw_row build-2 1 2)" 1
  expect_out_count "$(fw_row build-2 2 3)" 3
  expect_out_count '^build-2 +0 +example\.slot-1 .*my-app:test \(12m\)$' 9
  # eleven frames off ONE fan-out: the table and (GHR-72) the summary's
  # --json pass, each once per host
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 1
  expect_log_count '^probe:ssh_run build-1 -- ' 2
  expect_log_count '^probe:ssh_run build-2 -- ' 2
  expect_no_log '^direct:'
}

# A host that stops answering keeps its ROWS (GHR-74), so the cursor simply
# stays where it was: on build-2's slot-2, through the tick build-2 drops out
# of. The kept rows are walkable — j moves on to its slot-3 — and the age
# line above them is never a stop. The frame build-2 answers in again has the
# cursor still on that slot, not on its first and not back at the top.
#
# Before GHR-74 the host's rows were replaced by one error row and the cursor
# waited on that; a host with no rows to keep still is one, and a key on it
# still acts on nothing and dials nothing — which is now pinned by
# case_fleet_watch_first_frame_before_any_host_has_answered.
case_fleet_watch_cursor_survives_a_host_dropping_out() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jjjj-j-q' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DOWN="build-2:2" run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 8
  # frames 5 and 6 (before and through the tick it dropped out of), then 7
  # and 8 (the j onto its kept slot-3, and the tick it came back in)
  expect_out_count "$(fw_row build-2 1 2)" 2
  expect_out_count "$(fw_row build-2 2 3)" 2
  expect_out_count "$(fw_row build-2 0 1)" 1
  expect_out_count "$(fw_row build-1 0 1)" 1
  expect_out_count "^${REV}" 8
  # its rows are in every frame, the two it did not answer in included, under
  # the age line — which is never the cursor row, and there is no error row
  expect_out_count "^(${REV})?build-2 +0 +example\.slot-1 " 8
  expect_out_count '^build-2 +no answer for 0s — last seen [0-9]{2}:[0-9]{2}:[0-9]{2} — unreachable — ssh: connect to host build-2 port 22: No route to host$' 2
  expect_no_out "^${REV}build-2 +no answer"
  expect_no_out "^(${REV})?build-2 +unreachable"
  expect_no_out '\[y/n\]'
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 3
  # every --json call here is the summary's pass (GHR-72), one per tick to a
  # host that ANSWERED that tick — three for build-1, and two for build-2,
  # which is not asked again on the tick it was unreachable
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json$' 3
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json$' 2
  expect_log_count '^probe:ssh_run ' 11
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl (stop|start|restart|kill|reap|logs) '
  # The age line is not a stop. The run above cannot show that: its cursor is
  # already on one of build-2's slots, and the cursor's own pair is found
  # before any other row of that host is considered — so an age line that DID
  # count as a row changed nothing there (measured: that mutation ran green).
  # Here the cursor has to CROSS it: on build-2's first kept slot, k goes to
  # build-1's last slot, not onto the line between them.
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jjj-kq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DOWN="build-2:2" run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 6
  expect_out_count "^${REV}" 6
  expect_out_count "$(fw_row build-2 0 1)" 2
  expect_out_count "$(fw_row build-1 2 3)" 2
  expect_out_count '^build-2 +no answer for ' 2
  expect_no_out "^${REV}build-2 +no answer"
}

# A slot that goes away (the host scaled down) drops the cursor to THAT
# host's first slot — the local watch's "drop to the top", scoped to the host
# the operator was looking at.
case_fleet_watch_cursor_on_a_slot_that_scaled_away_stays_on_its_host() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jjjjj-q' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_SCALED="build-2:2" run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 7
  expect_out_count "$(fw_row build-2 2 3)" 1
  expect_out_count "$(fw_row build-2 0 1)" 2
  expect_out_count "$(fw_row build-1 0 1)" 1
  # the frame after the tick really has no slot-3 on build-2
  expect_out_count '^build-2 +2 +example\.slot-3 ' 5
}

# S on build-2's slot-1: the facts come from build-2 itself (status --json),
# the floor re-reads every watched host, the confirm names the exact remote
# command and what the stop leaves, and `y` runs it on build-2 ONLY. The frame
# after it is a fresh fan-out, so it shows build-2's slot-1 stopped and
# build-1's still running.
case_fleet_watch_S_stops_the_selected_pair_on_its_own_host() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jjjSyq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 6
  expect_out_count '^Stop example\.slot-1 on build-2\? runs on build-2: runnerctl stop example\.slot-1 — leaves 3 of 6 slot\(s\) active across the watched hosts  \[y/n\]$' 1
  expect_out_count '^warning: a job is running \(my-app:test \(12m\)\) — it will be killed and GitHub marks it failed; runnerctl stop --when-idle on the host waits for it instead$' 1
  expect_out_count '^running on build-2: runnerctl stop example\.slot-1$' 1
  expect_out_count '^example\.slot-1 on build-2: stop done\.$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl stop example\.slot-1$' 1
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl (stop|start|restart|kill|reap) ' 1
  expect_log_order '^probe:tty_read_char 5 S$' '^probe:ssh_run build-2 -- runnerctl status --json$' \
                   '^probe:ssh_run build-[12] -- runnerctl status --json$' '^probe:tty_read_char 5 y$' \
                   '^probe:ssh_run build-2 -- runnerctl stop example\.slot-1$' '^probe:ssh_run build-2 -- runnerctl status --color never$'
  # one facts read of build-2, plus the floor's read of both hosts — and
  # (GHR-72) the summary's pass to both, once per fan-out: the first frame's
  # and the one after the stop
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json$' 4
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json$' 3
  # and what the watch shows afterwards: the stop landed on build-2 alone,
  # with the cursor still on it
  expect_out_count "^${REV}build-2 +0 +example\.slot-1 +[^ ]+ +inactive/dead " 1
  expect_no_out '^build-1 +0 +example\.slot-1 +[^ ]+ +inactive/dead '
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 2
  expect_no_log '^direct:'
}

# The decision is made on facts read from the host AT THE KEY, not on the
# frame. The frame says slot-1 is running my-app:test; by the time K is
# pressed the host's journal says the job completed (BUSY_POLLS=1 answers
# busy to the frame's read and idle to every read after it) — so K refuses,
# where acting on the frame would have offered a kill. R quotes the job the
# host reports while it is still running.
case_fleet_watch_K_decides_on_facts_read_at_the_key() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_BUSY_POLLS=1 RUNNERCTL_STUB_KEYS='Kq' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "^${REV}build-1 +0 +example\\.slot-1 .*my-app:test \\(12m\\)$ESC\\[0m\$" 2
  expect_out_count '^example\.slot-1 on build-1: no job running — nothing to kill$' 1
  expect_no_out '\[y/n\]'
  # the facts read at the key, and (GHR-72) the first frame's summary pass
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json$' 2
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl kill '
  # with the job still running: the confirm quotes it, `y` kills on build-1
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='KyRnq' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "^Kill the job on example\.slot-1 on build-1 \(my-app:test \(12m\)\)\? runs on build-1: runnerctl kill example\.slot-1 — the job's processes; the runner stays up and reports it failed  \[y/n\]\$" 1
  expect_log_count '^probe:ssh_run build-1 -- runnerctl kill example\.slot-1$' 1
  expect_out_count '^example\.slot-1 on build-1: kill done\.$' 1
  expect_out_count '^Restart example\.slot-1 on build-1\? runs on build-1: runnerctl restart example\.slot-1  \[y/n\]$' 1
  expect_out_count '^warning: a job is running \(my-app:test \(12m\)\) — .* runnerctl restart --when-idle on the host waits for it instead$' 1
  expect_out_count '^cancelled — nothing run$' 1
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl restart '
  # a deactivating slot: the unit-kill confirm, from the host's own sub-state
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_DEACTIVATING=1 RUNNERCTL_STUB_KEYS='Knq' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count '^example\.slot-1 on build-1 is stuck stopping \(deactivating/stop-sigterm\) — SIGKILL the whole unit\? runs on build-1: runnerctl kill example\.slot-1  \[y/n\]$' 1
}

# The capacity floor, walked the way the issue fears: S, y on slot-1, then
# j, S on slot-2 — the host's last active slot. The second S re-reads the
# fleet, sees slot-1 already stopped, and refuses: nothing is dialled for it.
# The S pressed again on slot-1 in between is the hostile input for the facts
# read: only a read made AT that key knows the stop just landed — facts kept
# from the first S would still say active.
case_fleet_watch_S_walking_the_fleet_stops_at_the_floor() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='SySjSq' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count '^Stop example\.slot-1 on build-1\? runs on build-1: runnerctl stop example\.slot-1 — leaves 1 of 3 slot\(s\) active across the watched hosts  \[y/n\]$' 1
  expect_out_count '^example\.slot-1 on build-1: already stopped \(inactive\)$' 1
  expect_out_count "^example\.slot-2 on build-1: not stopped — it would leave 0 of 3 slot\(s\) active across the watched hosts, under --min-available 1; restart --min-available lower \(0 turns the floor off\), or run 'runnerctl stop example\.slot-2' on build-1\$" 1
  expect_log_count '^probe:ssh_run build-1 -- runnerctl stop ' 1
  expect_no_log '^probe:ssh_run build-1 -- runnerctl stop example\.slot-2'
  # --min-available 0 turns it off: the same walk stops both
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='SyjSyq' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never --min-available 0
  expect_rc 0
  expect_out_count '^Stop example\.slot-2 on build-1\? .* — leaves 0 of 3 slot\(s\) active across the watched hosts  \[y/n\]$' 1
  expect_log_count '^probe:ssh_run build-1 -- runnerctl stop ' 2
  # a higher floor refuses the first stop outright
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Sq' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never --min-available 2
  expect_rc 0
  expect_out_count '^example\.slot-1 on build-1: not stopped — it would leave 1 of 3 slot\(s\) active .* under --min-available 2; ' 1
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl stop '
  # a host that does not answer counts as nothing available, and says so
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Snq' RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count '^Stop example\.slot-1 on build-1\? .* — leaves 1 of 3 slot\(s\) active across the watched hosts, 1 host\(s\) not answering and not counted  \[y/n\]$' 1
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl stop '
}

# T starts a stopped slot, P reaps a slot's leaks — neither takes capacity
# away, so neither reads the fleet for a floor. The no-op directions refuse.
case_fleet_watch_T_starts_and_P_reaps_on_the_selected_host() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 \
    RUNNERCTL_STUB_KEYS='TjjjjjTyPkPyq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet watch --color never
  expect_rc 0
  expect_out_count '^example\.slot-1 on build-1: already active — R restarts it$' 1
  expect_out_count '^Start example\.slot-3 on build-2\? runs on build-2: runnerctl start example\.slot-3  \[y/n\]$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl start example\.slot-3$' 1
  expect_out_count '^example\.slot-3 on build-2: start done\.$' 1
  # the frame after the start shows it running on build-2, not on build-1
  expect_out "^${REV}build-2 +2 +example\.slot-3 +[^ ]+ +active/running "
  expect_no_out '^build-1 +2 +example\.slot-3 +[^ ]+ +active/running '
  expect_out_count '^example\.slot-3 on build-2: no leaked processes shown — nothing to reap$' 1
  expect_out_count "^Reap 2 leaked process\(es\) on example\.slot-2 on build-2\? runs on build-2: runnerctl reap example\.slot-2 — TERM, then KILL what is still alive after the grace  \[y/n\]\$" 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl reap example\.slot-2$' 1
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl (stop|start|restart|kill|reap) ' 2
  # T and P never read the fleet for a floor: the only --json reads of build-1
  # are the facts read for the T pressed on its own slot and (GHR-72) the
  # summary's pass, once per fan-out — the first frame, and after each of the
  # two actions that ran
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json$' 4
}

# L pages the selected slot's journal FROM ITS HOST through the local pager,
# at once (no confirm), with no fan-out; a host whose sudo refuses is a notice
# carrying the remedy, and the pager is never opened on nothing.
case_fleet_watch_L_pages_the_remote_journal() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jjjLq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 5
  expect_no_out '\[y/n\]'
  expect_log_count '^probe:ssh_run build-2 -- runnerctl logs example\.slot-1 -n 50$' 1
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl logs ' 1
  expect_out_count '^-- journal of example\.slot-1 on build-2 \(-n 50\) --$' 1
  expect_log_order '^probe:tty_read_char 5 L$' '^probe:term_cursor show$' '^probe:page$' '^probe:term_cursor hide$' '^probe:tty_read_char 5 q$'
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 1
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_NOSUDO=build-2 RUNNERCTL_STUB_KEYS='jjjLq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count '^example\.slot-1 on build-2: logs — remote exit 1 — sudo: a password is required — the ssh login needs passwordless sudo on that host; see the fleet section of the README for the exact sudoers line$' 1
  expect_no_log '^probe:page$'
}

# A remote action that fails is a notice with fleet_error_text's remedy, and
# the watch carries on; a host that cannot be read at the key acts on nothing.
case_fleet_watch_a_failed_action_is_a_notice_not_an_exit() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_NOSUDO=build-1 RUNNERCTL_STUB_KEYS='jRy-q' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --color never
  expect_rc 0
  expect_log_count '^probe:ssh_run build-1 -- runnerctl restart example\.slot-2$' 1
  # on the frame after the action, and still on the tick after that
  expect_out_count '^example\.slot-2 on build-1: restart failed — remote exit 1 — sudo: a password is required — the ssh login needs passwordless sudo on that host; see the fleet section of the README for the exact sudoers line$' 2
  # the watch went on: the tick after it fanned out again
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 3
  expect_log_order '^probe:tty_read_char 5 q$' '^probe:term_cursor show$' '^probe:ssh_control build-1 exit$'
}

# --- GHR-56: the narrow table, as a flag the fleet can forward -----------------
# The full and narrow column headers, with and without the fleet's HOST cell.
# MAX, HIGH and ENVFILE are the columns --narrow drops (STATUS_NARROW_DROP).
HDR_FULL='IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +MAX +HIGH +USED +PRESS +RESTART +ENVFILE +WORKING-ON$'
HDR_NARROW='IDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +USED +PRESS +RESTART +WORKING-ON$'

# `status --narrow` draws exactly the table the local watch narrows to, so a
# fleet has something to ask a remote for. It is a table shape: --json has no
# columns, and refuses it rather than accepting a flag that does nothing.
# `watch --narrow` (and `status --watch --narrow`) pins the narrow table even
# on a terminal wide enough for the full one.
case_status_narrow_drops_max_high_envfile() {
  run status --narrow
  expect_rc 0
  expect_out "^$HDR_NARROW"
  expect_no_out 'MAX|HIGH|ENVFILE|/etc/x'
  expect_out '^1 +example\.slot-2 .* +always +idle 2h31m \(2 jobs\)$'
  run status --narrow --json
  expect_rc 1
  expect_err '^runnerctl: --narrow cannot be combined with --json'
  expect_no_out '.'
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_COLS=300 run watch --narrow --iterations 2
  expect_rc 0
  expect_out_count "^$HDR_NARROW" 2
  expect_no_out 'MAX|HIGH|ENVFILE'
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_COLS=300 run status --watch --narrow --iterations 1
  expect_rc 0
  expect_out_count "^$HDR_NARROW" 1
}

# `fleet status --narrow` forwards the flag, and the narrow table is what
# ARRIVES — asserted on the rendered rows, not only on the argv, because the
# stub's remote acts on the flag rather than echoing it. Never narrowed by
# measuring (a one-shot is as likely piped as read), and refused with --json.
case_fleet_status_narrow_is_forwarded_and_arrives() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_COLS=80 run fleet status --narrow
  expect_rc 0
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never --narrow$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never --narrow$' 1
  expect_out_count "^HOST +$HDR_NARROW" 1
  expect_out '^build-2 +1 +example\.slot-2 .* +always +idle 2h31m \(2 jobs\)$'
  expect_no_out 'MAX|HIGH|ENVFILE|/etc/x'
  # no flag, no narrowing, however narrow the terminal
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_COLS=80 run fleet status
  expect_rc 0
  expect_out_count "^HOST +$HDR_FULL" 1
  expect_no_log ' --narrow'
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet status --narrow --json
  expect_rc 1
  expect_err '^runnerctl: --narrow cannot be combined with --json'
  expect_no_log '^probe:ssh_run'
}

# `fleet watch` measures the ASSEMBLED frame — HOST column included — and asks
# the remotes for the narrow table on the NEXT tick. 180 columns is between
# the two widths (narrow ~164 with HOST, full ~204), and less than the narrow
# width plus the 22-column margin: so the table narrows once and then STAYS
# narrow, where a watch without the hysteresis would put the columns back on
# the next tick and flip on every one after it.
# The LOCAL watch's hysteresis, on its own path through narrow_wanted (the
# fleet case above cannot see it). 170 columns is between the local table's
# widths (narrow 156, full 196) and under narrow + the 22-column margin, so
# once narrowed the table holds; a watch without the margin widens on the
# next frame and flips on every one after it. 300 then puts the columns back.
case_watch_narrow_holds_inside_the_margin() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_COLS=170 run watch --iterations 4 --color never
  expect_rc 0
  expect_out_count "^$HDR_NARROW" 4
  expect_no_out "^$HDR_FULL"
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_COLS=170,170,300 run watch --iterations 3 --color never
  expect_rc 0
  expect_out_count "^$HDR_NARROW" 2
  expect_out_count "^$HDR_FULL" 1
}

case_fleet_watch_narrows_on_the_next_tick_and_holds() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_COLS=180 \
    run fleet watch --iterations 4 --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 4
  # frame 1 is full-width (nothing measured yet), frames 2-4 narrow
  expect_out_count "^HOST +$HDR_FULL" 1
  expect_out_count "^HOST +$HDR_NARROW" 3
  expect_out_count '^build-1 +1 +example\.slot-2 .* +always +idle 2h31m \(2 jobs\)$' 3
  expect_out_count '^build-1 +1 +example\.slot-2 .* /etc/x \(ignore_errors=no\) idle 2h31m \(2 jobs\)$' 1
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 1
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never --narrow$' 3
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never --narrow$' 3
  # one table fan-out per tick: narrowing never costs a second round trip.
  # The other eight are the summary's --json pass (GHR-72), which is never
  # handed --narrow
  expect_log_count '^probe:ssh_run build-[12] -- runnerctl status --color ' 8
  expect_log_count '^probe:ssh_run build-[12] -- runnerctl status --json$' 8
  expect_log_count '^probe:ssh_run build-[12] -- ' 16
  # measured with colour on it is the same decision: SGR is stripped first
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_COLS=180 \
    run fleet watch --iterations 2 --color always
  expect_rc 0
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color always --narrow$' 1
  expect_out_count "^$ESC\[1mHOST +$ESC\[0m $ESC\[1mIDX +RUNNER +PROFILE +ACTIVE +SINCE +ENABLED +USED " 1
}

# And back: once the terminal is wide enough for the full table WITH the margin
# to spare, the next tick asks for it again. `--narrow` pins the narrow table
# whatever the width, and an unknown width (0) never narrows at all.
case_fleet_watch_widens_again_and_narrow_pins_it() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_COLS=150,150,300 \
    run fleet watch --iterations 4 --color never
  expect_rc 0
  expect_log_order '^probe:ssh_run build-1 -- runnerctl status --color never$' \
                   '^probe:ssh_run build-1 -- runnerctl status --color never --narrow$' \
                   '^probe:ssh_run build-1 -- runnerctl status --color never --narrow$' \
                   '^probe:ssh_run build-1 -- runnerctl status --color never$'
  expect_out_count "^HOST +$HDR_FULL" 2
  expect_out_count "^HOST +$HDR_NARROW" 2
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" RUNNERCTL_STUB_COLS=400 \
    run fleet watch --narrow --iterations 2 --color never
  expect_rc 0
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never --narrow$' 2
  expect_out_count "^HOST +$HDR_NARROW" 2
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet watch --iterations 2 --color never
  expect_rc 0
  expect_no_log ' --narrow'
}

# Version skew, the design point. A host older than --narrow refuses it like
# any unknown option (exit 1, `unknown option: --narrow`), which would make
# it a `remote exit 1` row. Instead it is asked again without the flag in the
# same fan-out — so it shows its full-width rows — and is remembered, so the
# rest of the watch sends it the plain call once per tick, not twice. Its
# column header is printed above its own rows, because the narrow one above
# would put every value after ENABLED under the wrong name. A host that fails
# rc 1 for any OTHER reason is not retried: it is a row, as before.
case_fleet_narrow_an_old_host_renders_full_width_not_an_error() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-oldver gw-norunners" \
    run fleet watch --narrow --iterations 3 --color never
  expect_rc 0
  expect_no_out 'unknown option'
  expect_out_count '^gw-oldver +1 +example\.slot-2 .* /etc/x \(ignore_errors=no\) idle 2h31m \(2 jobs\)$' 3
  expect_out_count '^build-1 +1 +example\.slot-2 .* +always +idle 2h31m \(2 jobs\)$' 3
  expect_out_count "^HOST +$HDR_NARROW" 3
  expect_out_count "^HOST +$HDR_FULL" 3
  expect_out_count '^gw-norunners +remote exit 1 — ' 3
  expect_out_count '^note: the hosts are not all on one runnerctl version' 3
  # asked with the flag ONCE, then without it for the rest of the session
  expect_log_count '^probe:ssh_run gw-oldver -- runnerctl status --color never --narrow$' 1
  expect_log_count '^probe:ssh_run gw-oldver -- runnerctl status --color never$' 3
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never --narrow$' 3
  expect_log_count '^probe:ssh_run gw-norunners -- ' 3
  # the one-shot takes the same path, and its exit code is not spoiled by it
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-oldver" run fleet status --narrow
  expect_rc 0
  expect_out '^gw-oldver +0 +example\.slot-1 .* 26\.0G +22\.0G .* my-app:test \(12m\)$'
  expect_out '^build-1 +0 +example\.slot-1 .* +enabled +1\.0G/25\.0G .* my-app:test \(12m\)$'
  expect_no_out 'remote exit'
  # with the flag, without it, and (GHR-72) the summary's --json pass
  expect_log_count '^probe:ssh_run gw-oldver -- runnerctl status --color never' 2
  expect_log_count '^probe:ssh_run gw-oldver -- runnerctl status --json$' 1
  expect_log_count '^probe:ssh_run gw-oldver -- ' 3
}

# --- GHR-44: capacity budgets ------------------------------------------------
# The assertion the whole issue exists for: the roll must RE-READ fleet state
# between slots rather than firing them off back to back. Asserted from the
# recorded call sequence — a status poll between two consecutive restarts —
# not from the end state, which looks identical either way.
case_fleet_max_unavailable_repolls_between_slots() {
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet restart --max-unavailable 1
  expect_rc 0
  expect_out '^build-1 slot 0: restart ok$'
  expect_out '^build-2 slot 1: restart ok$'
  expect_out '^fleet restart: 4 slot\(s\) done, 0 failed$'
  expect_log_order '^probe:ssh_run build-1 -- runnerctl restart 0$' \
                   '^probe:ssh_run build-1 -- runnerctl status --json$' \
                   '^probe:ssh_run build-1 -- runnerctl restart 1$'
  # one slot per remote call, never a whole host at once
  expect_no_log '^probe:ssh_run build-1 -- runnerctl restart$'
}

# GHR-59: FLEET_SLOTS_SKIPPED is set inside fleet_slots, and a caller that
# reads it through $(fleet_slots) runs the function in a subshell, losing the
# count the moment that subshell exits — so the warning below never fired and
# the budget was silently held over a partial fleet. Assert both halves: the
# warning line itself, and that the total (and everything the walk acts on)
# counts only the reachable host's slots.
case_fleet_budget_walk_warns_when_a_host_does_not_answer() {
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" \
    run fleet restart --max-unavailable 1
  expect_rc 0
  expect_out '^warning: 1 host\(s\) did not answer — the budget is being held over the 2 slot\(s\) that did$'
  expect_out '^build-1 slot 0: restart ok$'
  expect_out '^build-1 slot 1: restart ok$'
  expect_out '^fleet restart: 2 slot\(s\) done, 0 failed$'
  # the unreachable host's slots do not exist to the walk, so nothing is ever
  # dialled against it beyond the status polls that find it unreachable
  expect_no_log '^probe:ssh_run gw-unreachable -- runnerctl restart '
}

# A floor, not a ceiling: stop/drain/disable take capacity away and never give
# it back, so the budget that fits them stops the walk instead of throttling
# it, and says what it deliberately left running.
case_fleet_min_available_stops_at_the_floor() {
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet drain --min-available 2
  # 2 is neither success nor failure: it did less than asked, on purpose
  expect_rc 2
  expect_out '^fleet drain: 2 slot\(s\) done, 0 failed, 2 left running at the floor$'
  expect_out '^left running to hold --min-available 2: build-2/0 build-2/1$'
  # and it really stopped — the held-back slots were never dialled
  expect_no_log '^probe:ssh_run build-2 -- runnerctl drain '
}

# Offering a flag that would quietly do nothing is worse than refusing it.
case_fleet_budget_flags_refuse_the_wrong_command() {
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet drain --max-unavailable 1
  expect_rc 1
  expect_err "--max-unavailable applies to restart, apply and scale, not 'drain'"
  expect_no_log '^probe:ssh_run build-1 -- runnerctl drain '
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet restart --min-available 1
  expect_rc 1
  expect_err "--min-available applies to stop, drain and disable, not 'restart'"
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    run fleet restart --max-unavailable 1 --min-available 1
  expect_rc 1
  expect_err '--max-unavailable and --min-available cannot be combined'
}

# A budget of 0 would deadlock the roll on its first slot and look exactly
# like a hung fleet, so a percentage that rounds down to nothing clamps to 1.
case_fleet_percentage_budget_never_rounds_to_zero() {
  RUNNERCTL_STUB_FLEET_SLOTS=2 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet restart --max-unavailable 10%
  expect_rc 0
  expect_out '^fleet restart: 4 slot\(s\) done, 0 failed$'
  run_fn fleet_resolve_budget 10% 4
  expect_out '^1$'
  run_fn fleet_resolve_budget 50% 4
  expect_out '^2$'
  run_fn fleet_resolve_budget 3 99
  expect_out '^3$'
}

# The slot inventory is extracted from status --json with a sed, on the
# strength of render_status_json printing one line per slot. This case runs
# the walk against the REAL renderer rather than the budget fixture, so the
# two cannot drift apart unnoticed: if the emitter ever splits a slot across
# lines, or renames idx/active, this goes red.
case_fleet_slot_inventory_reads_the_real_json_emitter() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet restart --max-unavailable 9
  expect_rc 0
  # the stub host has three slots and the walk found all three, by index
  expect_log_count '^probe:ssh_run build-1 -- runnerctl restart [012]$' 3
  expect_out '^fleet restart: 3 slot\(s\) done, 0 failed$'
}

case_fleet_unknown_subcommand_dies() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet bogus
  expect_rc 1
  expect_err "unknown fleet command 'bogus'"
  expect_no_log '^probe:ssh_run '
}


# --- GHR-45: provision ---------------------------------------------------------
# The stub shadows the three network calls (tests/stub.config); everything else
# provision does is a host mutation and so is already in the call log.
PROV_URL="https://github.com/acme"
PROV_TOKEN="STUB-REG-TOKEN-DO-NOT-PRINT"

case_provision_fresh_host_installs_and_registers() {
  RUNNERCTL_STUB_NO_UNITS=1 run provision 2 --url "$PROV_URL" \
    --name-prefix slot --token "$PROV_TOKEN" --labels ci,linux
  expect_rc 0
  expect_out '^Host has 0 runner slot\(s\); target 2\.$'
  expect_out '^  scope:   org — https://github\.com/acme$'
  expect_out '^  new:     2 slot\(s\) — slot-1 slot-2$'
  expect_out '^  release: 2\.337\.0 \(actions-runner-linux-x64-2\.337\.0\.tar\.gz\)$'
  expect_out '^Provisioned 2 runner\(s\): slot-1 slot-2$'
  # The account is created before anything is unpacked into its directories.
  expect_log '^useradd --system --create-home .* github-runner$'
  # Per slot: unpack, own, register, install the unit, start it.
  expect_log '^mkdir -p /opt/actions-runner/slot-1$'
  expect_log '^tar -xzf .*/actions-runner-linux-x64-2\.337\.0\.tar\.gz -C /opt/actions-runner/slot-1$'
  expect_log '^chown -R github-runner:github-runner /opt/actions-runner/slot-1$'
  expect_log 'config\.sh --unattended --url https://github\.com/acme --token .* --name slot-1 --work _work --labels ci,linux$'
  expect_log 'config\.sh --unattended --url https://github\.com/acme --token .* --name slot-2 --work _work --labels ci,linux$'
  expect_log '/opt/actions-runner/slot-1 \./svc\.sh install github-runner$'
  expect_log '/opt/actions-runner/slot-2 \./svc\.sh start$'
  expect_log_order \
    '^useradd ' \
    '^mkdir -p /opt/actions-runner/slot-1$' \
    'slot-1 \./config\.sh ' \
    'slot-1 \./svc\.sh install ' \
    'slot-1 \./svc\.sh start$' \
    'slot-2 \./svc\.sh start$' \
    '^systemctl daemon-reload$'
  # config.sh must not run as root — it refuses to, and a root runner would let
  # any job rewrite the runner. svc.sh install must, since it writes the unit.
  expect_log '^runuser -u github-runner -- bash -c .* \./config\.sh '
  expect_no_log '^runuser -u root '
  # provision never writes a unit file itself: svc.sh owns that.
  expect_no_file "/etc/systemd/system/actions.runner.example.slot-1.service"
}

case_provision_is_idempotent_against_the_target_count() {
  # The stub host already has three slots.
  run provision 3 --url "$PROV_URL" --token "$PROV_TOKEN"
  expect_rc 0
  expect_out '^Host has 3 runner slot\(s\); target 3\.$'
  expect_out '^Nothing to provision\.'
  expect_no_log '^(mkdir|tar|useradd|chown) '
  expect_no_log 'config\.sh '
  expect_no_log '^api: '
  # Fewer than it has is equally a no-op: provision never deregisters.
  run provision 1 --url "$PROV_URL" --token "$PROV_TOKEN"
  expect_rc 0
  expect_out '^Nothing to provision\.'
  expect_no_log 'config\.sh '
}

case_provision_tops_an_existing_host_up() {
  # 3 -> 5 adds exactly two, and skips the names the existing units hold.
  run provision 5 --url "$PROV_URL" --name-prefix slot --token "$PROV_TOKEN"
  expect_rc 0
  expect_out '^  new:     2 slot\(s\) — slot-4 slot-5$'
  expect_out '^Provisioned 2 runner\(s\): slot-4 slot-5$'
  expect_log_count 'config\.sh --unattended ' 2
  expect_log 'config\.sh .* --name slot-4 '
  expect_log 'config\.sh .* --name slot-5 '
  # The slots that already exist are never touched.
  expect_no_log '/opt/actions-runner/slot-1'
  expect_no_log '/opt/actions-runner/slot-2'
  expect_no_log '/opt/actions-runner/slot-3'
}

case_provision_dry_run_changes_nothing() {
  RUNNERCTL_STUB_NO_UNITS=1 run provision 2 --url https://github.com/acme/app \
    --name-prefix slot --token "$PROV_TOKEN" --dry-run
  expect_rc 0
  expect_out '^  scope:   repo — https://github\.com/acme/app$'
  expect_out '^\(dry run — nothing downloaded, nothing changed\)$'
  expect_out '^would download: https://github\.com/actions/runner/releases/download/v2\.337\.0/'
  expect_out '^would register: slot-1 via config\.sh .* --token \*\*\* --name slot-1$'
  expect_out '^would install:  svc\.sh install github-runner   \(in /opt/actions-runner/slot-1\)$'
  # Reading the release metadata is allowed; changing the host is not.
  expect_log '^api: GET .*/releases/latest'
  expect_no_log '^fetch: '
  expect_no_log '^(mkdir|tar|chown|useradd|groupadd|systemctl) '
  expect_no_log 'config\.sh '
  expect_no_log '^api: POST '
}

case_provision_verifies_the_published_checksum() {
  # The tarball hashes to something other than what the release published.
  RUNNERCTL_STUB_NO_UNITS=1 RUNNERCTL_STUB_TARBALL_SHA=deadbeef \
    run provision 1 --url "$PROV_URL" --name-prefix slot --token "$PROV_TOKEN"
  expect_rc 1
  expect_err 'checksum mismatch for actions-runner-linux-x64-2\.337\.0\.tar\.gz'
  expect_err 'NOT installing\.'
  # Nothing was unpacked or registered from a tarball that failed the check.
  expect_no_log '^tar '
  expect_no_log 'config\.sh '
  # A release with no published checksum is refused rather than trusted...
  RUNNERCTL_STUB_NO_UNITS=1 RUNNERCTL_STUB_RELEASE_SHA='' \
    run provision 1 --url "$PROV_URL" --name-prefix slot --token "$PROV_TOKEN"
  expect_rc 1
  expect_err 'no published SHA-256 found for actions-runner-linux-x64-2\.337\.0\.tar\.gz'
  expect_no_log '^fetch: '
  # ...unless the operator says so explicitly, or pins one by hand.
  RUNNERCTL_STUB_NO_UNITS=1 RUNNERCTL_STUB_RELEASE_SHA='' \
    run provision 1 --url "$PROV_URL" --name-prefix slot --token "$PROV_TOKEN" --no-verify-checksum
  expect_rc 0
  expect_out '^  sha256:  NOT VERIFIED \(--no-verify-checksum\)$'
  expect_log 'config\.sh '
}

case_provision_sha256_pin_overrides_the_release() {
  local pin=70920811a4f8ad4328818682bca5c6469c1c942fab52448868071d0063816613
  RUNNERCTL_STUB_NO_UNITS=1 RUNNERCTL_STUB_RELEASE_SHA='' \
    run provision 1 --url "$PROV_URL" --name-prefix slot --token "$PROV_TOKEN" --sha256 "$pin"
  expect_rc 0
  expect_out '^  sha256:  70920811a4f8… \(from the release metadata\)$'
  expect_log 'config\.sh '
  # A pin that is not a SHA-256 is refused before anything is fetched.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" --token "$PROV_TOKEN" --sha256 nope
  expect_rc 1
  expect_err "--sha256 'nope' is invalid"
  expect_no_log '^fetch: '
}

case_provision_token_sources() {
  # --token is used as given: no token is minted.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" \
    --name-prefix slot --token "$PROV_TOKEN"
  expect_rc 0
  expect_no_log '^api: POST .*registration-token'
  # A PAT mints one, against the path the URL's scope decides.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" \
    --name-prefix slot --pat ghp_EXAMPLE_PAT
  expect_rc 0
  expect_log '^api: POST https://api\.github\.com/orgs/acme/actions/runners/registration-token \(authenticated\)$'
  expect_log 'config\.sh .* --token STUB-REGISTRATION-TOKEN '
  # $GITHUB_TOKEN is the same path without the flag.
  RUNNERCTL_STUB_NO_UNITS=1 GITHUB_TOKEN=ghp_FROM_THE_ENV \
    run provision 1 --url "$PROV_URL" --name-prefix slot
  expect_rc 0
  expect_log '^api: POST .*registration-token \(authenticated\)$'
  # With no token, no PAT and no gh, the refusal names all three ways.
  RUNNERCTL_STUB_NO_UNITS=1 RUNNERCTL_STUB_NO_GH=1 \
    run provision 1 --url "$PROV_URL" --name-prefix slot
  expect_rc 1
  expect_err 'no registration token: pass --token .*, or --pat/.GITHUB_TOKEN, or log in with the gh CLI'
  expect_no_log '^(mkdir|tar|useradd) '
  expect_no_log 'config\.sh '
}

case_provision_never_prints_the_token() {
  # config.sh takes the registration token in argv — that is GitHub's own
  # documented install and is why the log carries it. What runnerctl controls
  # is its OWN output, which must never carry it.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" \
    --name-prefix slot --token "$PROV_TOKEN"
  expect_rc 0
  expect_no_out "$PROV_TOKEN"
  expect_no_err "$PROV_TOKEN"
  # The PAT is stronger: it is passed to curl on stdin, so it reaches neither
  # the output nor argv — the stub asserts the latter by not logging it.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" \
    --name-prefix slot --pat ghp_EXAMPLE_PAT
  expect_rc 0
  expect_no_out 'ghp_EXAMPLE_PAT'
  expect_no_err 'ghp_EXAMPLE_PAT'
  expect_no_log 'ghp_EXAMPLE_PAT'
}

case_provision_scope_comes_from_the_url() {
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url https://github.com/acme \
    --name-prefix slot --pat p --dry-run
  expect_out '^  scope:   org — https://github\.com/acme$'
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url https://github.com/acme/app \
    --name-prefix slot --pat p --dry-run
  expect_out '^  scope:   repo — https://github\.com/acme/app$'
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url https://github.com/enterprises/acme \
    --name-prefix slot --pat p --dry-run
  expect_out '^  scope:   enterprise — https://github\.com/enterprises/acme$'
  # The minted-token path uses the scope's own API prefix.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url https://github.com/acme/app \
    --name-prefix slot --pat p
  expect_log '^api: POST https://api\.github\.com/repos/acme/app/actions/runners/registration-token'
  # Too many segments is a refusal, not a guess at which ones matter.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url https://github.com/a/b/c --token t
  expect_rc 1
  expect_err "--url 'https://github.com/a/b/c' is invalid"
  expect_no_log '^api: '
}

case_provision_pins_a_runner_version() {
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" --name-prefix slot \
    --token "$PROV_TOKEN" --runner-version 2.300.0 --no-verify-checksum
  expect_rc 0
  expect_log '^api: GET https://api\.github\.com/repos/actions/runner/releases/tags/v2\.300\.0'
  expect_out '^  release: 2\.300\.0 \(actions-runner-linux-x64-2\.300\.0\.tar\.gz\)$'
  expect_log '^fetch: https://github\.com/actions/runner/releases/download/v2\.300\.0/actions-runner-linux-x64-2\.300\.0\.tar\.gz'
  # A version that is not X.Y.Z never reaches the API.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" --token t --runner-version latest
  expect_rc 1
  expect_err "--runner-version 'latest' is invalid"
  expect_no_log '^api: '
}

case_provision_unreachable_api_is_explained() {
  RUNNERCTL_STUB_NO_UNITS=1 RUNNERCTL_STUB_API_FAIL='releases' \
    run provision 1 --url "$PROV_URL" --name-prefix slot --token "$PROV_TOKEN"
  expect_rc 1
  expect_err 'could not read the runner release metadata'
  expect_err 'pass --runner-version and --sha256 to work offline'
  expect_no_log '^fetch: '
  expect_no_log 'config\.sh '
  # A tag that does not exist says which one it asked for.
  RUNNERCTL_STUB_NO_UNITS=1 RUNNERCTL_STUB_API_FAIL='tags' \
    run provision 1 --url "$PROV_URL" --token t --runner-version 9.9.9
  expect_rc 1
  expect_err 'is v9\.9\.9 a real actions/runner release'
}

case_provision_refuses_a_bad_invocation() {
  run provision --url "$PROV_URL"
  expect_rc 1
  expect_err "provision needs N, e\.g\. 'provision 2 --url https://github\.com/<org>'"
  RUNNERCTL_STUB_NO_UNITS=1 run provision 0 --url "$PROV_URL" --token t
  expect_rc 1
  expect_err 'N must be 1\.\.64'
  RUNNERCTL_STUB_NO_UNITS=1 run provision 99 --url "$PROV_URL" --token t
  expect_rc 1
  expect_err 'N must be 1\.\.64'
  RUNNERCTL_STUB_NO_UNITS=1 run provision two --url "$PROV_URL" --token t
  expect_rc 1
  expect_err 'N must be an integer'
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --bogus
  expect_rc 1
  expect_err "unknown option: --bogus \('runnerctl provision --help' lists them\)"
  # No --url and no RUNNER_URL: the refusal says where the value can come from.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --token t
  expect_rc 1
  expect_err 'no --url and no RUNNER_URL'
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" --token t --runner-root rel/ative
  expect_rc 1
  expect_err "--runner-root 'rel/ative' is invalid"
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" --token t --work /absolute
  expect_rc 1
  expect_err "--work '/absolute' is invalid"
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" --token t --runner-user 0bad
  expect_rc 1
  expect_err "--runner-user '0bad' is invalid"
  # A value flag with nothing after it dies rather than eating the next one.
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url
  expect_rc 1
  expect_err '[-][-]url needs a value'
  # Every one of these refuses before touching the host or the network.
  expect_no_log '^(api:|fetch:|mkdir |tar |useradd |chown )'
}

case_provision_help_and_defaults() {
  run provision --help
  expect_rc 0
  expect_out '^Usage: runnerctl provision N \[options\]$'
  expect_out '^  --token TOKEN '
  expect_out '^  --pat TOKEN '
  expect_out '^  --no-verify-checksum '
  expect_no_log '^(api|fetch): '
  # The default name prefix is the host's short name, so runner lists stay
  # readable across boxes.
  local h; h="$(hostname -s 2>/dev/null || hostname)"
  RUNNERCTL_STUB_NO_UNITS=1 run provision 1 --url "$PROV_URL" --token t --dry-run
  expect_rc 0
  expect_out "^  names:   $h-<n>, arch x64\$"
  # The default runner user and root are the documented ones.
  expect_out '^would create:   github-runner \(if missing\), /opt/actions-runner/'
}

case_provision_is_named_when_a_host_has_no_runners() {
  # The error that sent a real operator looking for a command that did not
  # exist: every runner-requiring command now names the one that fixes it.
  RUNNERCTL_STUB_NO_UNITS=1 run scale 4 --max 30G --high 25G
  expect_rc 1
  expect_err "no 'actions\.runner\.\*\.service' units found on this host\."
  expect_err "runnerctl provision N --url https://github\.com/<org>"
  RUNNERCTL_STUB_NO_UNITS=1 run status
  expect_rc 1
  expect_err "runnerctl provision N --url"
}

case_provision_is_excluded_from_fleet() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet provision 2
  expect_rc 1
  expect_err 'fleet provision is not supported'
  expect_err 'copies a credential to every host'
  expect_no_log '^probe:ssh_run '
}

# --- GHR-46: deprovision -------------------------------------------------------
# The stub's fixed picture: slot-1 (index 0) is BUSY on my-app:test, slot-2
# (index 1) is idle, slot-3 (index 2) is stopped. The stub's `prop` answers
# WorkingDirectory=/opt/actions-runner/slot-N and User=github-runner, as the
# unit svc.sh writes would. The removal token goes to config.sh on stdin, which
# the stub writes to $WRITES/.config-remove-stdin and never to the log.
DEPROV_TOKEN="STUB-RM-TOKEN-DO-NOT-PRINT"
DEPROV_STDIN="$WRITES/.config-remove-stdin"
DEPROV_CHANGES='^(bash -c|runuser |rm |rmdir |systemctl )'

case_deprovision_removes_each_target_in_order() {
  # A slot index, a runner name, and the same slot again by its unit name:
  # two slots, the duplicate folded.
  run deprovision 1 slot-3 actions.runner.example.slot-2.service \
    --url "$PROV_URL" --pat ghp_EXAMPLE_PAT --yes
  expect_rc 0
  expect_out '^Deprovision 2 runner slot\(s\) — deregistered from GitHub and removed from this host:$'
  expect_out '^  example\.slot-2  \(/opt/actions-runner/slot-2, runs as github-runner\)$'
  expect_out '^Deprovisioned 2 runner slot\(s\): example\.slot-2 example\.slot-3$'
  # One removal token for the run, from the endpoint the --url scope decides.
  expect_log_count '^api: POST ' 1
  expect_log '^api: POST https://api\.github\.com/orgs/acme/actions/runners/remove-token \(authenticated\)$'
  expect_no_log 'registration-token'
  # Per slot, in the order the runner insists on: the service goes first
  # (config.sh refuses while it is installed), then GitHub, then the files.
  local s
  for s in 2 3; do
    expect_log "^bash -c .* runnerctl /opt/actions-runner/slot-$s \./svc\.sh stop\$"
    expect_log "^runuser -u github-runner -- bash -c .* runnerctl /opt/actions-runner/slot-$s \./config\.sh remove\$"
    expect_log "^rm -rf -- /opt/actions-runner/slot-$s\$"
    expect_log "^rm -f .*/actions\.runner\.example\.slot-$s\.service\.d/10-runnerctl\.conf\$"
  done
  expect_log_order \
    '^api: POST .*remove-token' \
    'slot-2 \./svc\.sh stop$' \
    'slot-2 \./svc\.sh uninstall$' \
    'slot-2 \./config\.sh remove$' \
    '^rm -rf -- /opt/actions-runner/slot-2$' \
    'slot-3 \./svc\.sh stop$' \
    'slot-3 \./svc\.sh uninstall$' \
    'slot-3 \./config\.sh remove$' \
    '^rm -rf -- /opt/actions-runner/slot-3$' \
    '^systemctl daemon-reload$'
  expect_log_count '\./config\.sh remove$' 2
  # svc.sh needs root; config.sh refuses root, so it runs as the unit's user.
  expect_no_log '^runuser .*svc\.sh'
  # The token was DELIVERED — once per slot, on stdin — not merely absent.
  expect_cfg "$DEPROV_STDIN" '^STUB-REMOVAL-TOKEN$'
  expect_cfg_count "$DEPROV_STDIN" '^STUB-REMOVAL-TOKEN$' 2
  # The busy slot was never a target and is never touched.
  expect_no_log 'slot-1'
}

case_deprovision_refuses_a_busy_slot() {
  # slot-1 (index 0) has a job in flight. Named alongside an idle slot, the
  # refusal still comes before EITHER is touched.
  run deprovision 1 0 --token "$DEPROV_TOKEN" --yes
  expect_rc 1
  expect_err '^runnerctl: refusing: a job is in flight on example\.slot-1 \(my-app:test, 12m\) — deprovisioning would kill it'
  expect_err 'Pass --when-idle to wait for each slot to finish\. Nothing was changed\.$'
  expect_no_log "$DEPROV_CHANGES"
  expect_no_log '^api: '
  expect_no_path "$DEPROV_STDIN"
  # A slot whose journal cannot be read cannot be proven idle: refused too.
  RUNNERCTL_STUB_JOURNAL_ACCESS=0 run deprovision 1 --token "$DEPROV_TOKEN" --yes
  expect_rc 1
  expect_err 'refusing: a job is in flight on example\.slot-2 \(cannot tell — needs journal read access or root\)'
  expect_no_log "$DEPROV_CHANGES"
}

case_deprovision_when_idle_waits_for_the_job() {
  # Two busy polls, then slot-1's job completes and it is removed.
  RUNNERCTL_STUB_BUSY_POLLS=2 run deprovision 0 --token "$DEPROV_TOKEN" --yes --when-idle
  expect_rc 0
  expect_out '^waiting for example\.slot-1 \(my-app:test, 12m\) …$'
  expect_log_count '^probe:pause 5$' 2
  expect_log_order '^probe:pause 5$' '^probe:pause 5$' 'slot-1 \./svc\.sh stop$' '^rm -rf -- /opt/actions-runner/slot-1$'
  expect_out '^Deprovisioned 1 runner slot\(s\): example\.slot-1$'
  # Busy for good: the wait times out, and nothing was stopped or removed.
  RUNNERCTL_STUB_BUSY_POLLS=99 run deprovision 0 --token "$DEPROV_TOKEN" --yes --when-idle --timeout 10
  expect_rc 1
  expect_err '^runnerctl: timed out after 10s waiting for example\.slot-1 \(my-app:test, 12m\)$'
  expect_err '^  busy or unreadable, not deprovisioned: example\.slot-1$'
  expect_no_log "$DEPROV_CHANGES"
}

case_deprovision_dry_run_changes_nothing() {
  # No --yes: a dry run needs no confirmation, and no terminal to ask on.
  run deprovision 1 2 --url https://github.com/acme/app --pat ghp_EXAMPLE_PAT --dry-run
  expect_rc 0
  expect_out '^\(dry run — no token minted, nothing changed\)$'
  expect_out '^would mint:  a removal token — POST https://api\.github\.com/repos/acme/app/actions/runners/remove-token \(repo\)$'
  expect_out '^would run:   cd /opt/actions-runner/slot-2 && \./svc\.sh stop$'
  expect_out '^would run:   cd /opt/actions-runner/slot-2 && \./svc\.sh uninstall$'
  expect_out '^would run:   cd /opt/actions-runner/slot-2 && ACTIONS_RUNNER_INPUT_TOKEN=\*\*\* \./config\.sh remove   \(as github-runner\)$'
  expect_out '^would run:   rm -rf -- /opt/actions-runner/slot-3$'
  expect_out '^would run:   systemctl daemon-reload$'
  expect_no_out '^Deprovisioned'
  expect_no_log "$DEPROV_CHANGES"
  expect_no_log '^api: '
  expect_no_path "$DEPROV_STDIN"
  # --yes alongside --dry-run: the confirm would no longer stop anything, so
  # this is the run where only the dry-run short-circuit stands between the
  # flags and a real removal.
  run deprovision 1 --token "$DEPROV_TOKEN" --yes --dry-run
  expect_rc 0
  expect_out '^\(dry run — no token minted, nothing changed\)$'
  expect_no_log "$DEPROV_CHANGES"
  expect_no_path "$DEPROV_STDIN"
  # --when-idle in a dry run says it would wait, and does not.
  run deprovision 0 --token "$DEPROV_TOKEN" --dry-run --when-idle
  expect_rc 0
  expect_out '^would wait:  until example\.slot-1 is idle \(--when-idle, up to 1800s\)$'
  expect_no_log '^probe:pause '
  expect_no_log "$DEPROV_CHANGES"
}

case_deprovision_never_prints_the_removal_token() {
  # A pasted removal token: not minted, delivered on stdin, and in none of
  # stdout, stderr or the argv log.
  run deprovision 1 --token "$DEPROV_TOKEN" --yes
  expect_rc 0
  expect_no_log '^api: '
  expect_cfg "$DEPROV_STDIN" "^$DEPROV_TOKEN\$"
  expect_no_out "$DEPROV_TOKEN"
  expect_no_err "$DEPROV_TOKEN"
  expect_no_log "$DEPROV_TOKEN"
  # The failing path too: the warning must not quote the credential.
  RUNNERCTL_STUB_CONFIG_REMOVE_FAIL=1 run deprovision 1 --token "$DEPROV_TOKEN" --yes
  expect_rc 0
  expect_no_out "$DEPROV_TOKEN"
  expect_no_err "$DEPROV_TOKEN"
  expect_no_log "$DEPROV_TOKEN"
  # A minted one, and the PAT that minted it: neither reaches any stream or
  # argv (the PAT goes to curl on stdin, the removal token to config.sh's).
  run deprovision 1 --url "$PROV_URL" --pat ghp_EXAMPLE_PAT --yes
  expect_rc 0
  expect_cfg "$DEPROV_STDIN" '^STUB-REMOVAL-TOKEN$'
  expect_no_log 'STUB-REMOVAL-TOKEN|ghp_EXAMPLE_PAT'
  expect_no_out 'STUB-REMOVAL-TOKEN|ghp_EXAMPLE_PAT'
  expect_no_err 'STUB-REMOVAL-TOKEN|ghp_EXAMPLE_PAT'
}

case_deprovision_already_deregistered_still_cleans_up() {
  # GitHub has already forgotten slot-2, so config.sh remove fails (the real
  # runner's DELETE 404s). The unit and directory are still removed.
  RUNNERCTL_STUB_CONFIG_REMOVE_FAIL=1 run deprovision 1 --token "$DEPROV_TOKEN" --yes
  expect_rc 0
  expect_err '^runnerctl: warning: example\.slot-2: config\.sh remove failed — GitHub may already have forgotten this runner\. Cleaning up locally anyway\.$'
  expect_log_order 'slot-2 \./svc\.sh uninstall$' 'slot-2 \./config\.sh remove$' '^rm -rf -- /opt/actions-runner/slot-2$' '^systemctl daemon-reload$'
  expect_out '^Deprovisioned 1 runner slot\(s\): example\.slot-2$'
  expect_out '^GitHub did not confirm removing: example\.slot-2\. If still listed under Settings -> Actions -> Runners, remove them there\.$'
  # --local-only never asks GitHub at all, and needs no credential.
  run deprovision 1 --local-only --yes
  expect_rc 0
  expect_out '^Deprovision 1 runner slot\(s\) — removed from this host only \(--local-only\):$'
  expect_no_log '^api: '
  expect_no_log 'config\.sh'
  expect_log '^rm -rf -- /opt/actions-runner/slot-2$'
  expect_out '^--local-only: still registered with GitHub \(offline\)\. Remove them under Settings -> Actions -> Runners\.$'
}

# A credential GitHub refuses is not a runner GitHub forgot: the mint fails
# before the first slot is touched, so nothing is stopped, uninstalled or
# deleted on the strength of a bad PAT.
case_deprovision_failed_mint_changes_nothing() {
  RUNNERCTL_STUB_API_FAIL='remove-token' \
    run deprovision 1 --url "$PROV_URL" --pat ghp_EXAMPLE_PAT --yes
  expect_rc 1
  expect_err 'could not mint a removal token for orgs/acme'
  expect_log '^api: POST .*/actions/runners/remove-token'
  expect_no_log "$DEPROV_CHANGES"
}

case_deprovision_confirms_unless_yes() {
  # No terminal and no --yes: refused, nothing touched, nothing minted.
  run deprovision 1 --url "$PROV_URL" --pat ghp_EXAMPLE_PAT
  expect_rc 1
  expect_err 'refusing to deprovision without confirmation: stdin is not a terminal\. Pass --yes to confirm, or --dry-run to see the commands\.$'
  expect_no_log "$DEPROV_CHANGES"
  expect_no_log '^api: '
  # A terminal answering anything but yes: refused the same way.
  RUNNERCTL_STUB_STDIN_TTY=1 run deprovision 1 --url "$PROV_URL" --pat ghp_EXAMPLE_PAT <<<"n"
  expect_rc 1
  expect_err 'This cannot be undone\. Deprovision example\.slot-2\? \[y/N\]'
  expect_err 'not confirmed — nothing was changed\.$'
  expect_no_log "$DEPROV_CHANGES"
  expect_no_log '^api: '
  # ...and a yes goes ahead.
  RUNNERCTL_STUB_STDIN_TTY=1 run deprovision 1 --url "$PROV_URL" --pat ghp_EXAMPLE_PAT <<<"y"
  expect_rc 0
  expect_log '^rm -rf -- /opt/actions-runner/slot-2$'
}

case_deprovision_refuses_a_bad_invocation() {
  # Bare: never "all".
  run deprovision --yes --token t
  expect_rc 1
  expect_err "deprovision needs an explicit target — a unit, slot index or runner name, e\.g\. 'deprovision 2'\. It never means 'all'"
  run deprovision 1 --bogus
  expect_rc 1
  expect_err "unknown option: --bogus \('runnerctl deprovision --help' lists them\)"
  run deprovision 9 --token t --yes
  expect_rc 1
  expect_err 'slot index 9 out of range'
  # A good target and a bad one: the bad one stops the run before the good
  # one is touched.
  run deprovision 1 nosuchslot --token t --yes
  expect_rc 1
  expect_err "no runner slot matches 'nosuchslot'"
  run deprovision 1 --yes
  expect_rc 1
  expect_err 'no --url and no RUNNER_URL'
  run deprovision 1 --url https://github.com/a/b/c --pat p --yes
  expect_rc 1
  expect_err "--url 'https://github.com/a/b/c' is invalid"
  run deprovision 1 --local-only --token t --yes
  expect_rc 1
  expect_err '--local-only does not talk to GitHub, so --token has nothing to do'
  run deprovision 1 --token
  expect_rc 1
  expect_err '[-][-]token needs a value'
  # The unit's WorkingDirectory is what gets `rm -rf`: refuse one that is
  # missing, or that is not a runner's tree.
  RUNNERCTL_STUB_NO_WORKDIR=1 run deprovision 1 --token t --yes
  expect_rc 1
  expect_err "example\.slot-2: its unit names no runner directory \(WorkingDirectory=''\)"
  RUNNERCTL_STUB_NOT_RUNNER_DIR=1 run deprovision 1 --token t --yes
  expect_rc 1
  expect_err 'example\.slot-2: /opt/actions-runner/slot-2 has no config\.sh and svc\.sh — refusing to delete a directory that is not a runner'
  # No credential anywhere: refused after the confirm but before any change.
  RUNNERCTL_STUB_NO_GH=1 run deprovision 1 --url "$PROV_URL" --yes
  expect_rc 1
  expect_err 'no removal token: pass --token <token from GitHub>, or --pat/.GITHUB_TOKEN, or log in with the gh CLI'
  # Every one of these refuses before touching the host.
  expect_no_log "$DEPROV_CHANGES"
}

case_deprovision_help() {
  run deprovision --help
  expect_rc 0
  expect_out '^Usage: runnerctl deprovision <unit\|slot-index\|name>\.\.\. \[options\]$'
  expect_out '^  --token TOKEN '
  expect_out '^  --local-only '
  expect_out '^  --when-idle '
  expect_out '^  --yes, -y '
  expect_out '^  --dry-run '
  expect_no_log "$DEPROV_CHANGES"
  # The top-level usage lists it too.
  run help
  expect_out '^  runnerctl deprovision <unit\|slot-index\|name>\.\.\. '
}

case_deprovision_is_named_where_removal_was_manual() {
  # scale's note used to say full deregistration was "not automated".
  run scale 2 --max 26G --high 25G
  expect_rc 0
  expect_out "^'runnerctl deprovision <slot>' — destructive and irreversible\.$"
  expect_no_out 'not automated'
  # ...and provision's no-op pointed at that note.
  run provision 1 --url "$PROV_URL" --token t
  expect_rc 0
  expect_out "^removing one for good is 'runnerctl deprovision <slot>'\.\)$"
}

case_deprovision_is_excluded_from_fleet() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet deprovision 1 --yes
  expect_rc 1
  expect_err 'fleet deprovision is not supported'
  expect_err 'a slot index or name means a different runner on each host'
  expect_no_log '^probe:ssh_run '
}

# The two host questions the stub answers, asked of the REAL functions (the
# GHR-48 lesson: a shadow's contract can drift from the real one). The real
# runner_exec_with_token is run with run_priv replaced by a plain exec and
# the root user (so no runuser), against a fake config.sh that reports what
# it was given: the token must arrive in its environment and not its argv.
case_deprovision_real_helpers() {
  local d="$TMP/ghr46-runner"
  rm -rf "$d"; mkdir -p "$d"
  run_fn runner_dir_is_runner "$d"
  expect_rc 1
  : >"$d/config.sh"
  run_fn runner_dir_is_runner "$d"
  expect_rc 1
  : >"$d/svc.sh"
  run_fn runner_dir_is_runner "$d"
  expect_rc 0
  cat >"$d/config.sh" <<'FAKE'
#!/usr/bin/env bash
echo "argv=$*"
echo "env=${ACTIONS_RUNNER_INPUT_TOKEN:-unset}"
echo "cwd=$PWD"
FAKE
  chmod +x "$d/config.sh"
  # The stub is sourced by run_snippet, so its logging run_priv is replaced
  # here by one that actually runs the command — as the invoking user, root
  # being the user argument only so no runuser is involved.
  run_snippet "$STUB" "run_priv() { \"\$@\"; }; runner_exec_with_token '$DEPROV_TOKEN' '$d' root ./config.sh remove"
  expect_rc 0
  expect_out '^argv=remove$'
  expect_out "^env=$DEPROV_TOKEN\$"
  expect_out "^cwd=$d\$"
}

# --- GHR-48: the REAL discover(), against a fake systemctl -------------------
# Every other case reaches discover through tests/stub.config, which SHADOWS
# it — so the stub's contract (no units = empty, exit 0) was asserted while
# the real function's diverged from it silently. `list-unit-files` exits 1
# when the glob matches nothing, `pipefail` made that discover's own status,
# and `provision`'s bare `have="$(discover | wc -l)"` therefore tripped
# `set -e` before its first echo: no output at all, exit 1, on exactly the
# bare host provision exists to fix. So these two go through run_fn (which
# sources the script with no config, leaving discover real) with a fake
# systemctl first on PATH.
_ghr48_fake_systemctl() {
  local dir="$TMP/ghr48-bin"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n%s\n' "$1" >"$dir/systemctl"
  chmod +x "$dir/systemctl"
  echo "$dir"
}

case_discover_no_matching_units_is_empty_not_a_failure() {
  local bin saved="$PATH"
  bin="$(_ghr48_fake_systemctl 'exit 1')"
  PATH="$bin:$PATH"
  run_fn discover
  PATH="$saved"
  expect_rc 0
  expect_out_count '.' 0
  expect_no_err '.'
}

case_discover_still_returns_the_units_when_systemctl_succeeds() {
  # Swallowing the status must not swallow the output: the units still come
  # back, and still only the first column — the rest is list-unit-files'
  # STATE/PRESET, which discover drops.
  local bin saved="$PATH"
  bin="$(_ghr48_fake_systemctl \
    'printf "%s enabled enabled\n" actions.runner.example.slot-10.service actions.runner.example.slot-2.service; exit 0')"
  PATH="$bin:$PATH"
  run_fn discover
  PATH="$saved"
  expect_rc 0
  expect_out_count '^actions\.runner\.example\.slot-(2|10)\.service$' 2
  expect_no_out ' enabled'
}

# --- GHR-58: apply/scale --save -----------------------------------------------
# The drop-in is durable; the OVERRIDE is not, until the profile goes back into
# the config. These cover the three outcomes (replace, append, refuse), the
# round trip that is the whole point, and the two things a green save could
# still have got wrong: a dropped ENV_TEMPLATE, which renders an identical
# drop-in, and a candidate installed before it was checked.

case_save_appends_when_the_config_names_no_such_profile() {
  local cfg="$TMP/save-append.config"
  save_config "$cfg" <<'BODY'
FLEET_HOSTS=(build-1 build-2)
profile_deploy() {
  PROFILE_DESC='Deploy'
  MEM_MAX=''
  MEM_HIGH=''
  RESTART_SEC='15'
  ENV_FILE='/etc/runnerctl/deploy.env'
}
BODY
  cp "$cfg" "$cfg.before"
  run_cfg "$cfg" apply --profile ci --max 30G --high infinity --save
  expect_rc 0
  expect_out "^Saved profile 'ci' to $cfg \(previous version: $cfg\.bak\)\.$"
  expect_out "^  verified: $cfg re-renders the drop-in just applied\.$"
  expect_cfg "$cfg" "^profile_ci\(\) \{$"
  expect_cfg "$cfg" "^  MEM_MAX='30G'$"
  expect_cfg "$cfg" "^  MEM_HIGH='infinity'$"
  # Everything that was already in the file is still in it.
  expect_cfg "$cfg" '^FLEET_HOSTS=\(build-1 build-2\)$'
  expect_cfg_count "$cfg" "^profile_deploy\(\) \{$" 1
  expect_cfg "$cfg" "^  ENV_FILE='/etc/runnerctl/deploy\.env'$"
  expect_same_file "$cfg.bak" "$cfg.before"
}

case_save_replaces_the_block_and_the_next_apply_reads_it_back() {
  local cfg="$TMP/save-replace.config"
  save_config "$cfg" <<'BODY'
profile_ci() {
  PROFILE_DESC='CI pool'
  MEM_MAX='30G'
  MEM_HIGH='26G'
  RESTART_SEC='10'
  ENV_FILE=''
}
profile_deploy() {
  PROFILE_DESC='Deploy'
  MEM_MAX=''
  MEM_HIGH=''
  RESTART_SEC='15'
  ENV_FILE='/etc/runnerctl/deploy.env'
}
BODY
  run_cfg "$cfg" apply --profile ci --high infinity --save
  expect_rc 0
  # Twice: the SECOND save is the one that would leave two definitions behind,
  # and the file is sourced top to bottom, so a duplicate would still "work".
  run_cfg "$cfg" apply --profile ci --high 29G --save
  expect_rc 0
  expect_cfg_count "$cfg" "^profile_ci\(\) \{$" 1
  expect_cfg "$cfg" "^  MEM_HIGH='29G'$"
  expect_cfg_lacks "$cfg" "^  MEM_HIGH='26G'$"
  expect_cfg "$cfg" "^  PROFILE_DESC='CI pool'$"
  expect_cfg_count "$cfg" "^profile_deploy\(\) \{$" 1
  # The claim of the whole feature: a later apply carrying NO flags renders
  # what was saved. The drop-in alone could never give you this — the next
  # config-driven apply would re-render MEM_HIGH from the old block.
  run_cfg "$cfg" apply --profile ci
  expect_rc 0
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryHigh=29G$'
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryMax=30G$'
}

case_save_keeps_a_profiles_env_template() {
  local cfg="$TMP/save-env-template.config"
  save_config "$cfg" <<'BODY'
profile_ci() {
  PROFILE_DESC='CI pool'
  MEM_MAX='30G'
  MEM_HIGH='26G'
  RESTART_SEC='10'
  ENV_FILE=''
  ENV_TEMPLATE='/etc/runnerctl/ci.env.example'
}
BODY
  run_cfg "$cfg" apply --profile ci --high infinity --save
  expect_rc 0
  # ENV_TEMPLATE is a profile knob render_dropin never reads, so losing it
  # renders an IDENTICAL drop-in and the save still verifies — env-init would
  # be the thing that broke, weeks later.
  expect_cfg "$cfg" "^  ENV_TEMPLATE='/etc/runnerctl/ci\.env\.example'$"
  expect_cfg "$cfg" "^  MEM_HIGH='infinity'$"
}

case_save_refuses_a_block_it_cannot_rewrite() {
  local cfg="$TMP/save-oneliner.config"
  save_config "$cfg" <<'BODY'
profile_ci() { MEM_MAX='30G'; MEM_HIGH='26G'; RESTART_SEC='10'; ENV_FILE=''; }
BODY
  cp "$cfg" "$cfg.before"
  run_cfg "$cfg" apply --profile ci --high infinity --save
  expect_rc 1
  expect_err 'defines profile_ci in a form this cannot rewrite'
  expect_err "want 'profile_ci\(\) \{' alone on its line"
  # The drop-ins still landed: the refusal is about the config, and the
  # applied change is on disk either way.
  expect_file "$DROPIN_DIR/$U1.d/10-runnerctl.conf" '^MemoryHigh=infinity$'
  expect_same_file "$cfg" "$cfg.before"
  expect_no_path "$cfg.bak"
}

case_save_refuses_two_definitions_of_one_profile() {
  local cfg="$TMP/save-twice.config"
  save_config "$cfg" <<'BODY'
profile_ci() {
  MEM_MAX='30G'
  MEM_HIGH='26G'
  RESTART_SEC='10'
  ENV_FILE=''
}
profile_ci() {
  MEM_MAX='20G'
  MEM_HIGH='19G'
  RESTART_SEC='10'
  ENV_FILE=''
}
BODY
  cp "$cfg" "$cfg.before"
  run_cfg "$cfg" apply --profile ci --high infinity --save
  expect_rc 1
  expect_err 'defines profile_ci more than once \(lines 2, 8\)'
  expect_same_file "$cfg" "$cfg.before"
  expect_no_path "$cfg.bak"
}

case_save_refuses_a_profile_with_logic_in_it() {
  local cfg="$TMP/save-logic.config"
  save_config "$cfg" <<'BODY'
profile_ci() {
  PROFILE_DESC='CI pool'
  case "$(hostname)" in big-*) MEM_MAX='60G' ;; *) MEM_MAX='30G' ;; esac
  MEM_HIGH='26G'
  RESTART_SEC='10'
  ENV_FILE=''
}
BODY
  cp "$cfg" "$cfg.before"
  run_cfg "$cfg" apply --profile ci --high infinity --save
  expect_rc 1
  # Flattening this to literal values would be silent, and the verify could
  # not see it: the flattened block renders the same drop-in on this host.
  expect_err 'holds more than the profile knobs \(line 4: '
  expect_same_file "$cfg" "$cfg.before"
}

case_save_creates_a_config_that_does_not_exist() {
  local cfg="$TMP/fresh-host/config"
  rm -rf "$TMP/fresh-host"
  run_snippet "$cfg" 'PROFILE=ci; load_profile; MEM_HIGH=infinity; save_profile apply'
  expect_rc 0
  expect_out "^Created $cfg with profile 'ci'\.$"
  expect_cfg "$cfg" '^# runnerctl config — created by .runnerctl apply --save. on [0-9]{4}-[0-9]{2}-[0-9]{2}\.$'
  expect_cfg "$cfg" "^profile_ci\(\) \{$"
  expect_cfg "$cfg" "^  MEM_MAX='26G'$"
  expect_cfg "$cfg" "^  MEM_HIGH='infinity'$"
  # load_config refuses a group- or world-writable config, so a save that
  # created one nobody can source would be worse than no save at all.
  expect_mode "$cfg" 644
}

case_save_refuses_a_candidate_that_would_not_re_render() {
  local cfg="$TMP/save-verify.config" shadow="$TMP/save-verify-shadow.sh"
  save_config "$cfg" <<'BODY'
profile_ci() {
  PROFILE_DESC='CI pool'
  MEM_MAX='30G'
  MEM_HIGH='26G'
  RESTART_SEC='10'
  ENV_FILE=''
}
BODY
  cp "$cfg" "$cfg.before"
  # The negative control for the verify step: a block renderer that writes a
  # value the applied profile does not have. Nothing a CLI run can do reaches
  # it, and that is the point — the check must refuse BEFORE the config is
  # touched, so a save that would not reproduce the drop-in costs nothing.
  cat >"$shadow" <<'BODY'
render_profile_block() {
  echo "profile_ci() {"
  echo "  PROFILE_DESC='CI pool'"
  echo "  MEM_MAX='1G'"
  echo "  MEM_HIGH='infinity'"
  echo "  RESTART_SEC='10'"
  echo "  ENV_FILE=''"
  echo "}"
}
BODY
  run_snippet "$cfg" ". $shadow; PROFILE=ci; load_profile; MEM_HIGH=infinity; save_profile apply"
  expect_rc 1
  expect_err 'does not re-render the drop-in just applied'
  expect_same_file "$cfg" "$cfg.before"
  expect_no_path "$cfg.bak"
}

case_apply_without_save_leaves_the_config_alone() {
  local cfg="$TMP/no-save.config"
  save_config "$cfg" </dev/null
  cp "$cfg" "$cfg.before"
  run_cfg "$cfg" apply --profile ci --high infinity
  expect_rc 0
  expect_out 'MemoryHigh=infinity'
  expect_no_out 'Saved profile'
  expect_same_file "$cfg" "$cfg.before"
  expect_no_path "$cfg.bak"
}

case_scale_save_writes_the_profile_it_scaled_with() {
  local cfg="$TMP/save-scale.config"
  save_config "$cfg" </dev/null
  run_cfg "$cfg" scale 2 --profile ci --max 40G --high infinity --save
  expect_rc 0
  expect_out "^Saved profile 'ci' to $cfg"
  expect_cfg "$cfg" "^  MEM_MAX='40G'$"
  expect_cfg "$cfg" "^  MEM_HIGH='infinity'$"
  expect_cfg "$cfg" "^  # Saved by \`runnerctl scale --save\` on [0-9]{4}-[0-9]{2}-[0-9]{2}\."
}

# --- compose-reap: compose stacks whose job is gone -----------------------------
# The fixture in tests/stub.config holds one project per verdict path; these
# pin each verdict, the removal order and scope, and the two refusals.
CR_DRY='^compose-reap: mode=dry-run projects=12 reap=5 keep=7 removed=0 failed=0 slots=3 standalone=0 images-removed=0 non-compose-running=4$'

case_compose_reap_dry_run_judges_every_project() {
  RUNNERCTL_STUB_COMPOSE=1 RUNNERCTL_STUB_COMPOSE_WORKER=1 run compose-reap
  expect_rc 0
  expect_out '^reap harness-123456 reason=gone:pid:123456 idle=120m containers=1 networks=1 volumes=0$'
  expect_out '^keep harness-4242 reason=live:pid:4242 '
  expect_out '^reap harness-777 reason=gone:pid:777 '
  expect_out '^keep slotone reason=live:slot '
  expect_out '^reap slottwo reason=gone:slot '
  expect_out '^reap stale reason=age idle=240m containers=1 networks=1 volumes=1$'
  expect_out '^keep young reason=young idle=60m '
  expect_out '^keep app-2 reason=young '
  expect_out '^keep fresh-1234 reason=grace idle=2m '
  expect_out '^keep pinned reason=label '
  expect_out '^reap netonly reason=age idle=300m containers=0 networks=1 volumes=0$'
  expect_out '^keep leftover reason=volume-only '
  expect_out "$CR_DRY"
  expect_no_log '^docker rm'
}

case_compose_reap_without_a_worker_the_slot_stack_is_gone() {
  # No Runner.Worker on slot-1 any more: the job that owned the stack ended.
  RUNNERCTL_STUB_COMPOSE=1 run compose-reap
  expect_rc 0
  expect_out '^reap slotone reason=gone:slot '
}

case_compose_reap_apply_removes_only_reaped_projects_in_order() {
  RUNNERCTL_STUB_COMPOSE=1 RUNNERCTL_STUB_COMPOSE_WORKER=1 run compose-reap --apply
  expect_rc 0
  expect_log_order '^docker rm container c-stale$' '^docker rm network n-stale$' '^docker rm volume v-stale$'
  expect_log_order '^docker rm container c-pidgone$' '^docker rm network n-pidgone$'
  expect_log_count '^docker rm ' 8
  expect_log '^docker rm network n-netonly$'
  expect_no_log '^docker rm .*(c-pidlive|c-slot1|c-young|c-app2|c-fresh|c-pinned|v-leftover)$'
  expect_no_log 'prune'
  expect_out '^compose-reap: mode=apply projects=12 reap=5 keep=7 removed=8 failed=0 '
}

case_compose_reap_apply_refuses_without_runner_units() {
  RUNNERCTL_STUB_COMPOSE=1 RUNNERCTL_STUB_NO_UNITS=1 run compose-reap --apply
  expect_rc 1
  expect_err 'refusing compose-reap --apply'
  expect_no_log '^docker rm'
  # A dry run still reports: it is how a dev box sees what --apply would do.
  RUNNERCTL_STUB_COMPOSE=1 RUNNERCTL_STUB_NO_UNITS=1 run compose-reap
  expect_rc 0
  expect_out 'mode=dry-run projects=12 .* slots=0 '
}

case_compose_reap_project_filter() {
  RUNNERCTL_STUB_COMPOSE=1 run compose-reap --apply --project stale
  expect_rc 0
  expect_out_count '^(reap|keep) ' 1
  expect_out '^reap stale reason=age '
  expect_log_count '^docker rm ' 3
}

case_compose_reap_age_and_grace_flags() {
  # --max-age-hours 1 makes the 2 h `app-2` old enough; --grace-minutes 1
  # stops sparing the 2-minute-old `fresh-1234`, whose pid is gone.
  RUNNERCTL_STUB_COMPOSE=1 run compose-reap --max-age-hours 1 --grace-minutes 1
  expect_rc 0
  expect_out '^reap app-2 reason=age '
  expect_out '^reap fresh-1234 reason=gone:pid:1234 '
}

case_compose_reap_a_failed_removal_fails_the_run() {
  RUNNERCTL_STUB_COMPOSE=1 RUNNERCTL_STUB_COMPOSE_WORKER=1 RUNNERCTL_STUB_COMPOSE_RM_FAIL=n-stale run compose-reap --apply
  expect_rc 1
  expect_log '^docker rm volume v-stale$'
  expect_out ' removed=7 failed=1 '
}

case_compose_reap_refuses_bad_input() {
  run compose-reap --max-age-hours 3h
  expect_rc 1
  expect_err 'max-age-hours must be a whole number'
  run compose-reap --grace-minutes
  expect_rc 1
  run compose-reap --bogus
  expect_rc 1
  expect_err 'unknown option for compose-reap: --bogus'
  RUNNERCTL_STUB_NO_DOCKER=1 run compose-reap
  expect_rc 1
  expect_err 'docker not found'
  expect_no_log '^docker rm'
}

case_compose_reap_empty_daemon() {
  run compose-reap --apply
  expect_rc 0
  expect_out '^compose-reap: mode=apply projects=0 reap=0 keep=0 removed=0 failed=0 slots=3 standalone=0 images-removed=0 non-compose-running=0$'
}

case_compose_reap_timer_refuses_a_user_writable_runnerctl() {
  run compose-reap-timer install
  expect_rc 1
  expect_err 'refusing to install a root timer .* not root'
  expect_no_log '^tee '
  expect_no_log '^systemctl'
}

case_compose_reap_timer_install_status_remove() {
  RUNNERCTL_STUB_ROOT_EXEC_OK=1 run compose-reap-timer install
  expect_rc 0
  expect_file /etc/systemd/system/runnerctl-compose-reap.service '^ExecStart=/.*/runnerctl compose-reap --apply$'
  expect_file /etc/systemd/system/runnerctl-compose-reap.service '^Requires=docker\.service$'
  expect_file /etc/systemd/system/runnerctl-compose-reap.timer '^OnCalendar=hourly$'
  expect_log_order '^tee .*runnerctl-compose-reap\.service$' '^tee .*runnerctl-compose-reap\.timer$' \
    '^systemctl daemon-reload$' '^systemctl enable --now runnerctl-compose-reap\.timer$'
  expect_out 'mode=dry-run'
  run compose-reap-timer remove
  expect_rc 0
  expect_log_order '^systemctl disable --now runnerctl-compose-reap\.timer$' \
    '^rm -f .*runnerctl-compose-reap\.service .*runnerctl-compose-reap\.timer$' '^systemctl daemon-reload$'
  run compose-reap-timer status
  expect_log '^journalctl -u runnerctl-compose-reap\.service -n 40 --no-pager$'
  run compose-reap-timer install extra
  expect_rc 1
  run compose-reap-timer frobnicate
  expect_rc 1
  expect_err "unknown compose-reap-timer command 'frobnicate'"
}

case_compose_reap_real_helpers() {
  # The stub shadows the docker hooks, so their real bodies are covered here.
  run_fn compose_epoch 2001-09-09T01:46:40.000000000Z
  expect_out '^1000000000$'
  run_fn compose_epoch '2001-09-09 01:46:40.64 +0000 UTC'
  expect_out '^1000000000$'
  run_fn compose_epoch 'not a date'
  expect_out '^0$'

  local d; d="$(mktemp -d)"
  run_fn runner_work_folder "$d"
  expect_out "^$d/_work\$"
  printf '{\n  "agentName": "x",\n  "workFolder": "/srv/work/"\n}\n' >"$d/.runner"
  run_fn runner_work_folder "$d"
  expect_out '^/srv/work$'

  : >"$d/self"; chmod 755 "$d/self"
  run_fn root_exec_problem "$d/self"
  expect_out "^$d/self is owned by uid $(id -u), not root\$"

  # compose_containers against a fake docker: ids from `ps`, then one inspect
  # with the project, keep-label and working-dir template fields in order.
  mkdir -p "$d/bin"
  cat >"$d/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  ps)      echo c1 ;;
  inspect) printf '%s\n' "$*" >"${0%/*}/../inspect.args"; echo 'proj-9000|c1|2001-09-09T01:46:40Z|2001-09-09T01:46:41Z|true|/w' ;;
esac
FAKE
  chmod 755 "$d/bin/docker"
  local saved="$PATH"
  PATH="$d/bin:$PATH"
  run_fn compose_containers
  PATH="$saved"
  expect_out '^proj-9000\|c1\|2001-09-09T01:46:40Z\|2001-09-09T01:46:41Z\|true\|/w$'
  _expect
  grep -q 'runnerctl.keep' "$d/inspect.args" || FAILS+=("inspect template does not ask for the keep label")
  grep -q 'com.docker.compose.project.working_dir' "$d/inspect.args" || FAILS+=("inspect template does not ask for the working dir")
  rm -rf "$d"
}

# --- compose-reap --standalone: containers with no compose label ----------------
case_compose_reap_standalone_is_opt_in() {
  RUNNERCTL_STUB_STANDALONE=1 run compose-reap --apply
  expect_rc 0
  expect_no_out '^(reap|keep) container '
  expect_no_log '^docker rm (container s-|image )'
  expect_out ' standalone=0 images-removed=0 '
}

case_compose_reap_standalone_dry_run_verdicts() {
  RUNNERCTL_STUB_STANDALONE=1 run compose-reap --standalone
  expect_rc 0
  expect_out '^reap container verify-old reason=age idle=1200m image=verify:1$'
  expect_out '^reap container verify-shared reason=age '
  expect_out '^keep container keeper reason=young '
  expect_out '^keep container svc-pinned reason=label '
  expect_out '^keep container just-started reason=grace idle=2m '
  expect_out '^keep container during-job reason=young '
  expect_out ' reap=2 keep=4 removed=0 failed=0 slots=3 standalone=6 images-removed=0 '
  expect_no_log '^docker rm'
  expect_no_log '^probe:image_in_use'
}

case_compose_reap_standalone_apply_removes_unused_images_only() {
  RUNNERCTL_STUB_STANDALONE=1 run compose-reap --standalone --apply
  expect_rc 0
  expect_log_order '^docker rm container s-old$' '^docker rm image sha-v1$'
  expect_log '^docker rm container s-shared$'
  expect_log '^probe:image_in_use sha-shared$'
  expect_no_log '^docker rm image sha-shared$'
  expect_no_log '^docker rm container s-(keeper|pinned|fresh|job)$'
  expect_out '^keep image verify:shared reason=in-use$'
  expect_out '^removed image verify:1$'
  expect_out ' removed=2 failed=0 slots=3 standalone=6 images-removed=1 '
}

case_compose_reap_standalone_kept_while_an_older_job_runs() {
  # during-job is ~67 min old; at --max-age-hours 1 it is old enough, unless a
  # job that started BEFORE it is still running — then it may be that job's.
  RUNNERCTL_STUB_STANDALONE=1 RUNNERCTL_STUB_COMPOSE_WORKER=1 run compose-reap --standalone --max-age-hours 1
  expect_rc 0
  expect_out '^keep container during-job reason=live:job '
  expect_out '^reap container verify-old reason=age '
  RUNNERCTL_STUB_STANDALONE=1 run compose-reap --standalone --max-age-hours 1
  expect_out '^reap container during-job reason=age '
}

case_compose_reap_standalone_from_config_and_project_filter() {
  local cfg="$TMP/standalone.config"
  save_config "$cfg" <<<'COMPOSE_REAP_STANDALONE="1"'
  RUNNERCTL_STUB_STANDALONE=1 run_cfg "$cfg" compose-reap --apply --project verify-old
  expect_rc 0
  expect_out_count '^(reap|keep) ' 1
  expect_log '^docker rm container s-old$'
  expect_log '^docker rm image sha-v1$'
  expect_no_log '^docker rm container s-shared$'
  save_config "$cfg" <<<'COMPOSE_REAP_STANDALONE="yes"'
  run_cfg "$cfg" compose-reap
  expect_rc 1
  expect_err "COMPOSE_REAP_STANDALONE 'yes'"
}

case_compose_reap_standalone_failed_image_removal_fails_the_run() {
  RUNNERCTL_STUB_STANDALONE=1 RUNNERCTL_STUB_IMAGE_RM_FAIL=sha-v1 run compose-reap --standalone --apply
  expect_rc 1
  expect_out '^failed image verify:1$'
  expect_out ' removed=2 failed=1 '
}

case_compose_reap_standalone_real_hook() {
  # compose_standalone against a fake docker: everything `ps -aq` lists minus
  # the compose-labelled ids, then one inspect with the keep label guarded.
  local d saved="$PATH"; d="$(mktemp -d)"
  mkdir -p "$d/bin"
  cat >"$d/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "ps -aq --no-trunc") printf 'aaa\nbbb\nccc\n' ;;
  "ps -aq --no-trunc --filter label=com.docker.compose.project") echo bbb ;;
  inspect*) printf '%s\n' "$*" >"${0%/*}/../inspect.args"; echo 'aaa|/x|sha-a|x:1|t|t|' ; echo 'ccc|/y|sha-c|y:1|t|t|' ;;
esac
FAKE
  chmod 755 "$d/bin/docker"
  PATH="$d/bin:$PATH"
  run_fn compose_standalone
  PATH="$saved"
  expect_out '^aaa\|/x\|sha-a\|x:1\|t\|t\|$'
  _expect
  grep -q ' aaa ccc$' "$d/inspect.args" || FAILS+=("inspect was not asked for exactly the non-compose ids (aaa ccc): $(cat "$d/inspect.args")")
  grep -q '{{with .Config.Labels}}' "$d/inspect.args" || FAILS+=("keep label read is not nil-guarded")
  rm -rf "$d"
}

case_compose_reap_in_usage() {
  run help
  expect_rc 0
  expect_out 'runnerctl compose-reap \[--apply\]'
  expect_out 'runnerctl compose-reap-timer install\|status\|remove'
  run bogus
  expect_err 'compose-reap compose-reap-timer'
}


# --- Host disks and journal events (GHR-64) ----------------------------------
case_status_host_disks_and_events() {
  RUNNERCTL_STUB_DISKS=full RUNNERCTL_STUB_HOST_EVENTS=events run status
  expect_rc 0
  # every fixed drive on the header line, a mount point with a space intact,
  # then the window's host-wide OOM kills (the cgroup one is not counted)
  expect_out '^runnerctl [0-9.]+ — Host: 16 cores, 64Gi RAM, 48Gi available — Disk: /var/lib/docker \[docker\] 96% \(37\.3G free\), /srv/runner work \[work\] 88% \(223\.5G free\) — last 1h: 2 OOM kills, 1 disk-full$'
  # the column header stays the third line — fleet status/watch index it
  [ "$(sed -n 3p <<<"$OUT")" = "$(grep -E '^IDX ' <<<"$OUT")" ] || FAILS+=("column header is not line 3")
  NEXPECT=$((NEXPECT + 1))
  # searched from now_epoch (1000000720) minus EVENTS_SEC (3600)
  expect_log_count '^probe:journal_host_events 999997120$' 1
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test) '
}

case_status_host_disks_color() {
  RUNNERCTL_STUB_DISKS=full RUNNERCTL_STUB_HOST_EVENTS=events run status --color always
  expect_rc 0
  expect_out $'— Disk: \e\\[31m/var/lib/docker \\[docker\\] 96% \\(37\\.3G free\\)\e\\[0m, \e\\[33m/srv/runner work \\[work\\] 88% \\(223\\.5G free\\)\e\\[0m — \e\\[31mlast 1h: 2 OOM kills, 1 disk-full\e\\[0m$'
  # GHR-67: a healthy partition is painted too — green, not left plain
  run status --color always
  expect_out $'— Disk: \e\\[32m/ \\[docker,work\\] 24% \\(353\\.9G free\\)\e\\[0m$'
}

# GHR-67: only what holds docker, the work folders and DISK_PATHS is watched.
# A LABEL=PATH entry is named by its label and shares a filesystem's row with
# whatever else is on it; a path that does not exist is skipped.
case_status_disk_paths_labelled() {
  local cfg="$TMP/disk-paths.config"
  save_config "$cfg" <<<"DISK_PATHS='cache=/srv/cache /missing/x /var/tmp'"
  RUNNERCTL_STUB_DISKS=full run_cfg "$cfg" status
  expect_rc 0
  expect_out '— Disk: /var/lib/docker \[docker\] 96% \(37\.3G free\), /srv/runner work \[work\] 88% \(223\.5G free\), / \[cache,/var/tmp\] 24% \(353\.9G free\)$'
  expect_no_out '/missing'
}

case_status_disk_falls_back_to_root() {
  local cfg="$TMP/disk-root.config"
  save_config "$cfg" <<<"DISK_DOCKER_DIR=/missing/docker"
  RUNNERCTL_STUB_NO_WORKDIR=1 run_cfg "$cfg" status
  expect_rc 0
  expect_out '— Disk: / \[root\] 24% \(353\.9G free\)$'
  # with the work folders known, docker missing just drops its role
  run_cfg "$cfg" status
  expect_out '— Disk: / \[work\] 24% \(353\.9G free\)$'
}

case_status_host_events_no_access() {
  RUNNERCTL_STUB_HOST_EVENTS=no-access run status
  expect_rc 0
  # an unreadable journal says nothing on the header rather than "0 events"
  expect_out '^runnerctl [0-9.]+ — Host: 16 cores, 64Gi RAM, 48Gi available — Disk: / \[docker,work\] 24% \(353\.9G free\)$'
}

case_status_host_events_off() {
  local cfg="$TMP/events-off.config"
  save_config "$cfg" <<<'EVENTS_SEC=0'
  RUNNERCTL_STUB_HOST_EVENTS=events run_cfg "$cfg" status
  expect_rc 0
  expect_out '— Disk: / \[docker,work\] 24% \(353\.9G free\)$'
  expect_no_log '^probe:journal_host_events '
}

case_status_disk_ignore() {
  local cfg="$TMP/disk-ignore.config"
  save_config "$cfg" <<<"DISK_IGNORE='^/var/lib/docker\$'"
  RUNNERCTL_STUB_DISKS=full run_cfg "$cfg" status
  expect_rc 0
  expect_out '— Disk: /srv/runner work \[work\] 88% \(223\.5G free\)$'
  expect_no_out '/var/lib/docker'
}

case_status_json_host_disks_events() {
  if ! $HAVE_PYTHON3; then skip "python3 not installed — host.disks/events not checked"; expect_rc 0; return; fi
  RUNNERCTL_STUB_DISKS=full RUNNERCTL_STUB_HOST_EVENTS=events run status --json
  expect_rc 0
  expect_json 'd["host"]["disks"][0] == {"mount": "/var/lib/docker", "device": "/dev/sdb1", "fstype": "xfs", "size": 1000000000000, "used": 960000000000, "avail": 40000000000, "use_pct": 96, "roles": ["docker"]}'
  # three slots' work folders on one drive are one entry, one role
  expect_json '[(x["mount"], x["roles"]) for x in d["host"]["disks"]] == [("/var/lib/docker", ["docker"]), ("/srv/runner work", ["work"])]'
  expect_json 'd["host"]["events"] == {"window": 3600, "oom_kills": 2, "cgroup_oom_kills": 1, "disk_full": 1, "last_oom": 1000000100, "last_oom_process": "cc1plus", "last_disk_full": 999999500, "last_disk_full_source": "dockerd"}'
}

case_status_json_host_events_null() {
  if ! $HAVE_PYTHON3; then skip "python3 not installed — host.events null not checked"; expect_rc 0; return; fi
  RUNNERCTL_STUB_HOST_EVENTS=no-access run status --json
  expect_rc 0
  expect_json 'd["host"]["events"] is None'
  expect_json '[x["roles"] for x in d["host"]["disks"]] == [["docker", "work"]]'
}

case_health_host_problems() {
  RUNNERCTL_STUB_DISKS=full RUNNERCTL_STUB_HOST_EVENTS=events run health --max-restarts 99
  expect_rc 1
  expect_out '^host: /var/lib/docker \[docker\] is 96% full \(37\.3G free, DISK_CRIT_PCT=95\)$'
  # 88 % is a warning on the header, not a health problem
  expect_no_out 'runner work'
  expect_out "^host: the kernel OOM-killed 2 process\(es\) host-wide in the last 1h \(last: cc1plus\) — "
  expect_out "^host: 1 'No space left on device' line\(s\) in the journal in the last 1h \(last from dockerd\)$"
  expect_out_count '^host: ' 3
  expect_no_out '^ok: '
}

case_health_host_ok() {
  # a quiet journal and a 24 % disk add nothing; an unreadable journal is
  # not a problem either (the slot-level journal note already covers access)
  RUNNERCTL_STUB_HOST_EVENTS=no-access run health --max-restarts 99
  expect_no_out '^host: '
  run health --max-restarts 99
  expect_no_out '^host: '
}

case_host_events_parse() {
  run_fn host_events_parse $'1.5 h kernel: Out of memory: Killed process 1 (a b) x\n2.0 h kernel: Memory cgroup out of memory: Killed process 2 (c)\n3.9 h runsvc.sh[7]: write: No space left on device\n4.0 h kernel: Out of memory: Kill process 3 (old) score 1'
  expect_rc 0
  expect_out $'^2\t1\t1\t4\told\t3\trunsvc\\.sh$'
  run_fn host_events_parse ''
  expect_out $'^0\t0\t0\t\t\t\t$'
}


# --- The fleet host line (GHR-66) ---------------------------------------------
# Each host's Disk: / events fragment (GHR-64) lands on one line of its own,
# above that host's slots — the remote header it was cut from is folded away.
# Line number of the first stdout line matching an ERE, 0 when none does.
first_line() { grep -nE -m1 "$1" <<<"$OUT" | cut -d: -f1 || echo 0; }

case_fleet_status_host_line_above_each_hosts_slots() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_FULL="build-2" run fleet status
  expect_rc 0
  expect_out_count '^build-1 +Disk: / \[docker,work\] 24% \(353\.9G free\)$' 1
  expect_out_count '^build-2 +Disk: /var/lib/docker \[docker\] 96% \(37\.3G free\), /srv/runner work \[work\] 88% \(223\.5G free\) — last 1h: 2 OOM kills, 1 disk-full$' 1
  # each host line sits between the previous host's slots and its own
  local h1 s1 h2 s2 last1
  h1="$(first_line '^build-1 +Disk: ')"; s1="$(first_line '^build-1 +0 ')"
  h2="$(first_line '^build-2 +Disk: ')"; s2="$(first_line '^build-2 +0 ')"
  last1="$(first_line '^build-1 +2 ')"
  NEXPECT=$((NEXPECT + 1))
  { [ "$h1" -gt 0 ] && [ "$h1" -lt "$s1" ] && [ "$last1" -lt "$h2" ] && [ "$h2" -lt "$s2" ]; } \
    || FAILS+=("host lines out of place: build-1 line $h1 slot0 $s1 slot2 $last1, build-2 line $h2 slot0 $s2")
  # the slot rows are untouched and `fleet status` stays plain
  expect_out_count '^build-[12] +[0-9]+ +example\.slot-' 6
  expect_no_out "$ESC"
  expect_no_out '^build-[12] runnerctl '
}

# `fleet status` asks for --color never and paints the host line itself
# (GHR-67), cell by cell, from the percentages; the rows stay plain.
case_fleet_status_host_line_painted_locally() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_FULL="build-2" run fleet status --color always
  expect_rc 0
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 1
  expect_out_count "^build-1 +Disk: $ESC\\[32m/ \\[docker,work\\] 24% \\(353\\.9G free\\)$ESC\\[0m\$" 1
  expect_out_count "^build-2 +Disk: $ESC\\[31m/var/lib/docker \\[docker\\] 96% \\(37\\.3G free\\)$ESC\\[0m, $ESC\\[33m/srv/runner work \\[work\\] 88% \\(223\\.5G free\\)$ESC\\[0m — $ESC\\[31mlast 1h: 2 OOM kills, 1 disk-full$ESC\\[0m\$" 1
  expect_no_out "^build-[12] +[0-9]+ .*$ESC"
}

case_fleet_status_old_host_gets_no_host_line() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-oldver" run fleet status
  expect_out_count '^build-1 +Disk: ' 1
  # a pre-0.16.0 header has no fragment: no line, and its rows still render
  # — not even its cores/RAM: only the 3 slot rows carry its name
  expect_out_count '^build-oldver ' 3
  expect_out_count '^build-oldver +[0-9]+ +example\.slot-' 3
}

case_fleet_watch_host_line_keeps_the_remote_colours() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_FULL="build-1" \
    run fleet watch --iterations 1 --color always
  expect_rc 0
  expect_out_count "^build-1 +Disk: $ESC\[31m/var/lib/docker \[docker\] 96% \(37\.3G free\)$ESC\[0m, $ESC\[33m/srv/runner work \[work\] 88% \(223\.5G free\)$ESC\[0m — $ESC\[31mlast 1h: 2 OOM kills, 1 disk-full$ESC\[0m\$" 1
  expect_out_count "^build-2 +Disk: $ESC\\[32m/ \[docker,work\] 24% \(353\.9G free\)$ESC\\[0m\$" 1
}

# The cursor walks slot rows only: j from build-1's last slot goes to build-2's
# first, over build-2's host line, and no frame highlights a host line.
case_fleet_watch_cursor_skips_host_lines() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jjjkq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 5
  expect_out_count '^build-[12] +Disk: ' 10
  expect_no_out "^${REV}build-[12] +Disk: "
  expect_out_count "^${REV}" 5
  expect_out_count "$(fw_row build-1 0 1)" 1
  expect_out_count "$(fw_row build-1 1 2)" 1
  expect_out_count "$(fw_row build-1 2 3)" 2
  expect_out_count "$(fw_row build-2 0 1)" 1
}

# A long host line is not a table row: the fleet watch measures its width
# with watch_table_width, which must count slot rows only.
case_fleet_watch_host_line_does_not_count_for_width() {
  local long; long="build-1 Disk: /$(printf 'x%.0s' {1..300}) 24% (1G free)"
  run_fn watch_table_width "$long"$'\n''build-1 0 example.slot-1 active' '[^ ]+ +'
  expect_rc 0
  expect_out '^31$'
}

# --- GHR-72: the fleet summary line ------------------------------------------
# Every expected line below is PINNED TEXT, not derived from another surface:
# the stub host has three slots — slot-1 running a job for 12m, slot-2 idle,
# slot-3 inactive and disabled — so the numbers are known before anything
# runs. The counts come from each host's real `status --json` (the stub
# renders it through render_status_json), never from the table.
SUM_OK='2/2 hosts answering · 6 slots: 2 busy, 2 idle, 2 disabled · capacity 2 free of 4'

# The last stdout line, compared as exact text (no regex to escape).
expect_last_line() { # TEXT
  _expect
  local got
  got="$(tail -n 1 <<<"$OUT")"
  [ "$got" = "$1" ] || FAILS+=("last stdout line: want '$1', got '$got'")
}
# How many frames carry TEXT as the line directly under the watch header.
expect_under_header() { # TEXT COUNT
  _expect
  local n
  n="$(grep -A1 -E 'runnerctl fleet watch — ' <<<"$OUT" | grep -cxF -- "$1"; true)"
  [ "$n" -eq "$2" ] || FAILS+=("frames with '$1' directly under the header: want $2, got $n")
}

# A healthy fleet is a SHORT line: nothing stalled, down or leaking, no disk
# or event segment, one version — and each of those segments is absent, not
# printed as a zero. It is the last line, after the rows.
case_fleet_summary_healthy_fleet_is_a_short_line() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet status
  expect_rc 0
  expect_last_line "$SUM_OK"
  expect_out_count ' hosts? answering' 1
  # its cost: one --json call per answering host on top of the table's
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json$' 1
  expect_log_count '^probe:ssh_run ' 4
  # and `fleet status --json` is untouched: no summary there (that is GHR-80)
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" run fleet status --json
  expect_rc 0
  expect_no_out ' answering'
  expect_log_count '^probe:ssh_run ' 2
}

# The stalled count. STALLED is decided on the host, against the threshold it
# was handed, so the summary's own call has to carry --stall-after too: the
# same job is `busy` without the flag and `STALLED` with it.
case_fleet_summary_counts_a_stalled_job() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet status --stall-after 600
  expect_rc 0
  expect_out '^build-1 +0 +example\.slot-1 .* my-app:test \(12m\) STALLED$'
  expect_last_line '1/1 host answering · 3 slots: 1 idle, 1 STALLED, 1 disabled · capacity 1 free of 2'
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json --stall-after 600$' 1
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet status
  expect_rc 0
  expect_last_line '1/1 host answering · 3 slots: 1 busy, 1 idle, 1 disabled · capacity 1 free of 2'
  # --narrow belongs to the table: the --json call must not be handed it
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet status --narrow --stall-after 600
  expect_rc 0
  expect_last_line '1/1 host answering · 3 slots: 1 idle, 1 STALLED, 1 disabled · capacity 1 free of 2'
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json --stall-after 600$' 1
  expect_no_log '^probe:ssh_run .* --json.* --narrow'
}

# A host that did not answer is in the host count and in NOTHING else: its
# slots are unknown, not down. Unreachable (255) and timed out (124) are not
# answering; a host whose runnerctl ran and exited 1 answered. None of the
# three is dialled a second time for the summary.
case_fleet_summary_unreachable_host_counts_as_a_host_only() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable gw-timeout gw-norunners" run fleet status
  expect_rc 1
  expect_last_line '2/4 hosts answering · 3 slots: 1 busy, 1 idle, 1 disabled · capacity 1 free of 2'
  expect_no_out '[0-9] down'
  expect_log_count '^probe:ssh_run gw-unreachable -- ' 1
  expect_log_count '^probe:ssh_run gw-timeout -- ' 1
  expect_log_count '^probe:ssh_run gw-norunners -- ' 1
  expect_log_count '^probe:ssh_run build-1 -- ' 2
  # nobody answering: the host count alone, and no slot arithmetic at all
  RUNNERCTL_STUB_FLEET_HOSTS="gw-unreachable" run fleet status
  expect_rc 1
  expect_last_line '0/1 host answering'
  expect_log_count '^probe:ssh_run ' 1
}

# Mixed versions: the count of distinct ones, after the skew note it sits
# under. A level fleet has no such segment (the healthy case pins that).
case_fleet_summary_counts_distinct_versions() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2-oldver build-3" run fleet status
  expect_rc 0
  expect_last_line '3/3 hosts answering · 9 slots: 3 busy, 3 idle, 3 disabled · capacity 3 free of 6 · 2 versions'
  expect_out_count '^note: the hosts are not all on one runnerctl version' 1
}

# The problem segments, each from a state the host really reports: a unit
# stopped by hand (enabled, not active) is `down` where slot-3 is `disabled`;
# an idle slot with processes left behind is leaking; a host with a partition
# past DISK_CRIT_PCT and one past DISK_WARN_PCT is counted ONCE, at its worst;
# OOM kills and disk-full lines in the window make it an event host.
case_fleet_summary_names_what_is_wrong() {
  mkdir -p "$WRITES/remote/build-1"
  echo inactive >"$WRITES/remote/build-1/example.slot-2"
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_FULL="build-2" \
    RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 run_keep fleet status
  expect_rc 0
  expect_out '^build-1 +1 +example\.slot-2 +[^ ]+ +inactive/dead '
  expect_last_line '2/2 hosts answering · 6 slots: 2 busy, 1 idle, 1 down, 2 disabled · 1 leaking · 1 host disk crit · 1 host OOM/disk-full · capacity 1 free of 3'
  rm -rf "$WRITES/remote"
  # with this node's DISK_CRIT_PCT raised past the 96 % partition, the same
  # host is a warning: the thresholds are the central node's, not the host's
  printf '. %q\nDISK_CRIT_PCT=97\n' "$PWD/$STUB" >"$TMP/warn.config"
  chmod 644 "$TMP/warn.config"
  STUB="$TMP/warn.config" RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_FULL="build-2" run fleet status
  expect_rc 0
  expect_last_line '2/2 hosts answering · 6 slots: 2 busy, 2 idle, 2 disabled · 1 host disk warn · 1 host OOM/disk-full · capacity 2 free of 4'
}

# Capacity is the one segment a zero does NOT remove: a fleet with no idle
# slot left is what the line exists to show. One host, its idle slot stopped.
case_fleet_summary_capacity_zero_is_still_shown() {
  mkdir -p "$WRITES/remote/build-1"
  echo inactive >"$WRITES/remote/build-1/example.slot-2"
  RUNNERCTL_STUB_FLEET_HOSTS="build-1" run_keep fleet status --color always
  expect_rc 0
  expect_last_line "1/1 host answering · 3 slots: ${ESC}[32m1 busy${ESC}[0m, ${ESC}[31m1 down${ESC}[0m, ${ESC}[2m1 disabled${ESC}[0m · ${ESC}[33mcapacity 0 free of 1${ESC}[0m"
  rm -rf "$WRITES/remote"
}

# Each segment in the colour the table uses for that state: the host count
# red when a host is missing, STALLED bold red, idle and disabled dim.
case_fleet_summary_is_painted_like_the_table() {
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" run fleet status --color always --stall-after 600
  expect_rc 1
  expect_last_line "${ESC}[31m1/2 hosts answering${ESC}[0m · 3 slots: ${ESC}[2m1 idle${ESC}[0m, ${ESC}[1m${ESC}[31m1 STALLED${ESC}[0m, ${ESC}[2m1 disabled${ESC}[0m · capacity 1 free of 2"
}

# The numbers are the ones `fleet status --json` carries for the same fleet:
# counted here from the envelope by python, and BOTH sides pinned to literals
# — two surfaces that merely agree could be wrong together.
case_fleet_summary_matches_fleet_status_json() {
  local knobs='build-1 build-2 gw-unreachable'
  RUNNERCTL_STUB_FLEET_HOSTS="$knobs" RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 \
    run fleet status --stall-after 600
  expect_rc 1
  expect_last_line '2/3 hosts answering · 6 slots: 2 idle, 2 STALLED, 2 disabled · 2 leaking · capacity 2 free of 4'
  RUNNERCTL_STUB_FLEET_HOSTS="$knobs" RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 \
    run fleet status --json --stall-after 600
  expect_rc 1
  if ! $HAVE_PYTHON3; then skip "python3 not on PATH: the envelope's own counts not run"; return 0; fi
  expect_json '[h["reachable"] for h in d["fleet"]] == [True, True, False]'
  expect_json 'sum(len(h["status"]["slots"]) for h in d["fleet"] if h["status"]) == 6'
  expect_json 'sum(1 for h in d["fleet"] if h["status"] for s in h["status"]["slots"] if s["active"] == "active" and s["job"] and s["job"]["stalled"]) == 2'
  expect_json 'sum(1 for h in d["fleet"] if h["status"] for s in h["status"]["slots"] if s["active"] == "active" and s["job"] is None) == 2'
  expect_json 'sum(1 for h in d["fleet"] if h["status"] for s in h["status"]["slots"] if s["active"] != "active" and s["enabled"] == "disabled") == 2'
  expect_json 'sum(1 for h in d["fleet"] if h["status"] for s in h["status"]["slots"] if (s["leaked_procs"] or 0) > 0) == 2'
}

# `fleet watch`: the same line, directly under the header in every frame —
# the --iterations loop and the interactive one — and it is not a row the
# cursor can stop on.
case_fleet_watch_summary_sits_under_the_header() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet watch --iterations 2 --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 2
  expect_under_header "$SUM_OK" 2
  expect_out_count ' hosts answering' 2
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='kq' RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" \
    run fleet watch --color never --stall-after 600
  expect_rc 0
  expect_under_header '2/2 hosts answering · 6 slots: 2 idle, 2 STALLED, 2 disabled · capacity 2 free of 4' 2
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json --stall-after 600$' 1
  expect_out_count "^${REV}" 2
  expect_no_out "^${REV}[0-9]+/"
  # a host that drops out of a tick leaves the count for that tick only
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2" RUNNERCTL_STUB_FLEET_DOWN="build-2:2" \
    run fleet watch --iterations 3 --color never
  expect_rc 0
  expect_under_header "$SUM_OK" 2
  expect_under_header '1/2 hosts answering · 3 slots: 1 busy, 1 idle, 1 disabled · capacity 1 free of 2' 1
}

# --- GHR-73: a frame that fits the terminal -----------------------------------
# The stub pins the height (RUNNERCTL_STUB_LINES, 0 = unknown) and can grow the
# pool (RUNNERCTL_STUB_SLOTS) so a frame is taller than it. Nine slots make the
# local watch's frame 16 lines: the header, the version/host line, a blank,
# the column header, nine rows, a blank, the legend and the status line. Seven
# of those are chrome, so a terminal of H rows has a window of H - 7.
#
# `frames` splits OUT on the home+clear prefix: FRAMES[1] is the first frame.
# A FITTED frame is written without a final newline, so its text is exactly
# its lines, and a frame drawn whole (unknown height, or a terminal too small
# to fit to) counts ONE MORE than it has, for the newline it ends in — which
# is how these cases tell the two apart. Never count a run's LAST frame:
# "$(...)" strips the newlines it ends in, and an empty status line is one of
# them. Every run below ends `-q` for that reason: the tick draws a frame
# nobody asserts on.
FRAMES=()
frames() {
  local rest="$OUT" sep=$'\033[H\033[2J'
  FRAMES=("${rest%%"$sep"*}")
  [[ "$rest" == *"$sep"* ]] || return 0
  rest="${rest#*"$sep"}"
  while [[ "$rest" == *"$sep"* ]]; do
    FRAMES+=("${rest%%"$sep"*}")
    rest="${rest#*"$sep"}"
  done
  FRAMES+=("$rest")
}
# How many frames the run drew. Not `expect_out_count "$FRAME_PREFIX"`: that
# pattern is anchored to a line start, and a fitted frame's status line has no
# newline between it and the next frame's prefix.
expect_frame_count() { # COUNT
  _expect
  [ $((${#FRAMES[@]} - 1)) -eq "$1" ] || FAILS+=("frames drawn: want $1, got $((${#FRAMES[@]} - 1))")
}
expect_frame_lines() { # N COUNT
  _expect
  local nl="${FRAMES[$1]-}" n
  nl="${nl//[!$'\n']/}"
  n=$((${#nl} + 1))
  [ "$n" -eq "$2" ] || FAILS+=("frame $1: want $2 lines, got $n")
}
expect_frame() { # N PATTERN
  _expect
  grep -Eq -- "$2" <<<"${FRAMES[$1]-}" || FAILS+=("frame $1 has no line matching /$2/")
}
expect_no_frame() { # N PATTERN
  _expect
  ! grep -Eq -- "$2" <<<"${FRAMES[$1]-}" || FAILS+=("frame $1 has a line matching /$2/")
}
# Line L of frame N against PATTERN: where a line is, not only that it exists.
expect_frame_line() { # N L PATTERN
  _expect
  local got
  got="$(sed -n "${2}p" <<<"${FRAMES[$1]-}")"
  grep -Eq -- "$3" <<<"$got" || FAILS+=("frame $1 line $2: want /$3/, got '$got'")
}
# Two texts, byte for byte. The report shows the first differing lines with
# the escape sequences made visible.
expect_text() { # LABEL WANT GOT
  _expect
  [ "$2" = "$3" ] || FAILS+=("$1 differs from the pinned text: $(diff <(cat -v <<<"$2") <(cat -v <<<"$3") | head -n 14; true)")
}
# TABLE with the line matching PATTERN in reverse video — the cursor row as
# the watches draw it where no cell in it is painted.
with_cursor() { # TABLE PATTERN
  local line
  while IFS= read -r line; do
    if [[ "$line" =~ $2 ]]; then printf '%s%s%s\n' "${ESC}[7m" "$line" "${ESC}[0m"; else printf '%s\n' "$line"; fi
  done <<<"$1"
}
# OUT with the clock in every watch header replaced, so two frames a second
# apart compare equal.
out_without_clock() {
  sed -E 's/^(.*runnerctl (fleet )?watch — .* — )[0-9]{2}:[0-9]{2}:[0-9]{2}( — every )/\1TIME\3/' <<<"$OUT"
}
# The two marker lines, whole: a count of hidden lines and the keys that page.
up_mark() { echo "^↑ $1 more  PgUp/g\$"; }
down_mark() { echo "^↓ $1 more  PgDn/G\$"; }
w_row() { echo "^$1 +example\.slot-$2 "; }

# Height 0 is "unknown", and unknown must be the frame of before, byte for
# byte. The expected text is PINNED here — prefix, header, blank line, legend,
# status line and the newline each frame ends in — around a table taken from
# the one-shot `status`, which never goes near the viewport. Two frames, not
# one: the newline that ends a frame is only observable where another frame
# follows it.
case_watch_unknown_height_draws_the_frame_of_before() {
  local table want sep=$'\033[H\033[2J' legend="${LEGEND#^}" hdr
  legend="${legend%\$}"
  hdr="runnerctl watch — ${HOSTNAME:-$(uname -n)} — TIME — every 1s (Ctrl-C to quit)"
  run status
  expect_rc 0
  table="$OUT"
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jq' run watch --interval 1
  expect_rc 0
  want="$(printf '%s%s\n%s\n\n%s\n\n%s%s\n%s\n\n%s' \
    "$sep" "$hdr" "$(with_cursor "$table" '^0 +example')" "$legend" \
    "$sep" "$hdr" "$(with_cursor "$table" '^1 +example')" "$legend")"
  expect_text "watch at unknown height" "$want" "$(out_without_clock)"
  # the height was asked for (the frame went through the viewport) and the
  # width, which only a known height needs, was asked for by watch_table alone
  expect_cfg "$LOG.lines" '^2$'
  expect_cfg "$LOG.cols" '^2$'
}

case_fleet_watch_unknown_height_draws_the_frame_of_before() {
  local table want sep=$'\033[H\033[2J' legend="${FLEET_WATCH_LEGEND#^}" hdr
  legend="${legend%\$}"
  hdr="runnerctl fleet watch — 2 host(s) — TIME — every 4s (q to quit)"
  RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet status --color never
  expect_rc 0
  expect_last_line "$SUM_OK"
  table="${OUT%$'\n'*}"
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never --interval 4
  expect_rc 0
  want="$(printf '%s%s\n%s\n%s\n\n%s\n\n%s%s\n%s\n%s\n\n%s' \
    "$sep" "$hdr" "$SUM_OK" "$(with_cursor "$table" '^build-1 +0 +example')" "$legend" \
    "$sep" "$hdr" "$SUM_OK" "$(with_cursor "$table" '^build-1 +1 +example')" "$legend")"
  expect_text "fleet watch at unknown height" "$want" "$(out_without_clock)"
}

# The acceptance case: a 16-line frame on an 11-row terminal is exactly 11
# lines, and what is cut is the middle. Line by line — header, version/host
# line, blank, column header, the window with the cursor row in it, the count
# of what is hidden, blank, legend, status line. K and n put a confirm and
# then a notice on the status line, which stays the LAST line of the frame.
case_watch_tall_frame_is_cut_to_the_terminal_height() {
  local f
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_SLOTS=9 RUNNERCTL_STUB_LINES=11 RUNNERCTL_STUB_KEYS='Kn-q' \
    run watch --interval 1
  expect_rc 0
  frames
  expect_frame_count 4
  for f in 1 2 3; do
    expect_frame_lines "$f" 11
    expect_frame_line "$f" 1 '^runnerctl watch — [^ ]+ — [0-9]{2}:[0-9]{2}:[0-9]{2} — every 1s \(Ctrl-C to quit\)$'
    expect_frame_line "$f" 2 '^runnerctl [0-9]+\.[0-9]+\.[0-9]+ — Host: '
    expect_frame_line "$f" 3 '^$'
    expect_frame_line "$f" 4 '^IDX +RUNNER +PROFILE .* WORKING-ON$'
    expect_frame_line "$f" 5 "$(cursor_row 0 1)"
    expect_frame_line "$f" 6 "$(w_row 1 2)"
    expect_frame_line "$f" 7 "$(w_row 2 3)"
    expect_frame_line "$f" 8 "$(down_mark 6)"
    expect_frame_line "$f" 9 '^$'
    expect_frame_line "$f" 10 "$LEGEND"
    expect_no_frame "$f" 'example\.slot-[4-9]'
    expect_no_frame "$f" '^↑ [0-9]'
  done
  expect_frame_line 1 11 '^$'
  expect_frame_line 2 11 "^Kill the job on example\.slot-1 \(.*\)\? .*runs: systemctl kill -s KILL $SLOT1_UNIT  \[y/n\]$"
  expect_frame_line 3 11 '^cancelled — nothing run$'
  expect_no_log '^(systemctl|journalctl|sudo|tee|rm|mkdir|chown|chmod|test|kill) '
}

# Every frame of a run: exactly HEIGHT lines, one cursor row, and the rows on
# screen plus the two counts add up to the pool — a marker that is off by one
# cannot hide behind a frame that happens to be the right length.
_ghr73_every_frame_accounts_for_the_pool() { # FRAMES HEIGHT POOL
  local f shown up down
  for ((f = 1; f <= $1; f++)); do
    expect_frame_lines "$f" "$2"
    _expect
    shown="$(grep -Ec 'example\.slot-[0-9]' <<<"${FRAMES[$f]-}"; true)"
    up="$(sed -n -E 's/^↑ ([0-9]+) more .*/\1/p' <<<"${FRAMES[$f]-}")"
    down="$(sed -n -E 's/^↓ ([0-9]+) more .*/\1/p' <<<"${FRAMES[$f]-}")"
    [ $((shown + ${up:-0} + ${down:-0})) -eq "$3" ] \
      || FAILS+=("frame $f: $shown rows shown + ${up:-0} above + ${down:-0} below is not the pool of $3")
    _expect
    [ "$(grep -c "^${ESC}\[7m" <<<"${FRAMES[$f]-}"; true)" -eq 1 ] || FAILS+=("frame $f: not exactly one cursor row")
  done
}

# The window follows the cursor. Three j's on a window of three rows: the
# first two stay inside it and nothing moves; the third crosses the bottom
# edge and the window scrolls by exactly as much as brings the row back, the
# counts saying what went where. Then the paging keys: G and g, PgDn twice
# and PgUp (a window less one line), and End / Home as their sequences.
case_watch_window_scrolls_with_the_cursor() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_SLOTS=9 RUNNERCTL_STUB_LINES=11 \
    RUNNERCTL_STUB_KEYS=$'jjjGg\e[6~\e[6~\e[5~\e[F\e[1~-q' run watch
  expect_rc 0
  frames
  expect_frame_count 12
  _ghr73_every_frame_accounts_for_the_pool 11 11 9
  # j, j: inside the window
  expect_frame_line 3 7 "$(cursor_row 2 3)"
  expect_frame_line 3 8 "$(down_mark 6)"
  expect_no_frame 3 '^↑ [0-9]'
  # j: past the bottom edge — slot-1 and slot-2 go above, slot-4 comes in
  expect_frame_line 4 5 "$(up_mark 2)"
  expect_frame_line 4 6 "$(w_row 2 3)"
  expect_frame_line 4 7 "$(cursor_row 3 4)"
  expect_frame_line 4 8 "$(down_mark 5)"
  # G: the last slot, nothing under it
  expect_frame_line 5 5 "$(up_mark 6)"
  expect_frame_line 5 6 "$(w_row 6 7)"
  expect_frame_line 5 7 "$(w_row 7 8)"
  expect_frame_line 5 8 "$(cursor_row 8 9)"
  expect_no_frame 5 '^↓ [0-9]'
  # g: back to the first, nothing above it
  expect_frame_line 6 5 "$(cursor_row 0 1)"
  expect_frame_line 6 8 "$(down_mark 6)"
  expect_no_frame 6 '^↑ [0-9]'
  # PgDn: two rows down (a window of three, less one) — still on screen
  expect_frame_line 7 7 "$(cursor_row 2 3)"
  expect_no_frame 7 '^↑ [0-9]'
  # PgDn again: slot-5, and the window has to move
  expect_frame_line 8 5 "$(up_mark 3)"
  expect_frame_line 8 6 "$(w_row 3 4)"
  expect_frame_line 8 7 "$(cursor_row 4 5)"
  expect_frame_line 8 8 "$(down_mark 4)"
  # PgUp: the window is two rows now, so one row up; nothing scrolls
  expect_frame_line 9 5 "$(up_mark 3)"
  expect_frame_line 9 6 "$(cursor_row 3 4)"
  expect_frame_line 9 8 "$(down_mark 4)"
  # End (ESC [ F) and Home (ESC [ 1 ~)
  expect_frame_line 10 8 "$(cursor_row 8 9)"
  expect_frame_line 11 5 "$(cursor_row 0 1)"
  # the `~` that ends a numbered sequence was read with it, not as a key
  expect_no_log '^probe:tty_read_char 2 \\~$'
  expect_log_count '^probe:tty_read_char 0\.05 \\~$' 4
}

# The notes under the table are below the last row, where the cursor cannot
# go — so the last row brings them into view, in both watches. TWO notes
# (STALLED and +N leaked), deliberately: a single trailing line is drawn in
# the row its `↓ 1 more` would have taken whether or not anything asked for
# it, so one note would be on screen with this wiring deleted.
case_watch_last_row_shows_the_notes_under_the_table() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 RUNNERCTL_STUB_SLOTS=9 \
    RUNNERCTL_STUB_LINES=11 RUNNERCTL_STUB_KEYS='G-q' run watch --stall-after 600
  expect_rc 0
  frames
  expect_frame_count 3
  # the top of the table says how much is under it: nine rows and two notes
  expect_frame_line 1 8 "$(down_mark 8)"
  expect_frame_lines 2 11
  expect_frame_line 2 5 "$(up_mark 8)"
  expect_frame_line 2 6 "$(cursor_row 8 9)"
  expect_frame_line 2 7 '^note: STALLED = '
  expect_frame_line 2 8 '^note: \+N leaked = '
  expect_frame_line 2 10 "$LEGEND"
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_CGROUP_READABLE=1 RUNNERCTL_STUB_LEAKED=1 RUNNERCTL_STUB_LINES=10 \
    RUNNERCTL_STUB_KEYS='G-q' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet watch --color never --stall-after 600
  expect_rc 0
  frames
  expect_frame_count 3
  expect_frame_lines 2 10
  expect_frame_line 2 4 "$(up_mark 7)"
  expect_frame_line 2 5 "$(fw_row build-2 2 3)"
  expect_frame_line 2 6 '^note: '
  expect_frame_line 2 7 '^note: '
  expect_frame_line 2 9 "$FLEET_WATCH_LEGEND"
}

# Heights around the frame's own 16 lines, one run each — a frame exactly as
# tall as the window is the size that hides an off-by-one, so the sizes on
# either side of each boundary are pinned too.
#   10  the smallest fitted: a window of 3 is two rows and a count
#    9  a window of 2 is under the minimum: drawn whole, as for unknown
#   15  one short: seven rows and `↓ 2 more`
#   16  fits exactly: everything, no marker, and NO final newline — on the
#       last row a newline would scroll the header off
#   17  room to spare: the same 16 lines, not padded
case_watch_heights_around_the_frame() {
  local h small
  _ghr73_at() { RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_SLOTS=9 RUNNERCTL_STUB_LINES="$1" RUNNERCTL_STUB_KEYS='-q' run watch; frames; }
  _ghr73_at 10
  expect_frame_lines 1 10
  expect_frame_line 1 5 "$(cursor_row 0 1)"
  expect_frame_line 1 6 "$(w_row 1 2)"
  expect_frame_line 1 7 "$(down_mark 7)"
  _ghr73_at 15
  expect_frame_lines 1 15
  expect_frame_line 1 11 "$(w_row 6 7)"
  expect_frame_line 1 12 "$(down_mark 2)"
  expect_frame_line 1 14 "$LEGEND"
  for h in 16 17; do
    _ghr73_at "$h"
    expect_frame_lines 1 16
    expect_frame_line 1 13 "$(w_row 8 9)"
    expect_frame_line 1 15 "$LEGEND"
    expect_no_frame 1 '^[↑↓] [0-9]+ more'
  done
  # too small to fit to: the whole frame and its newline, exactly what an
  # unknown height draws — compared with that run, and pinned by its shape
  _ghr73_at 9
  small="$(out_without_clock)"
  expect_frame_lines 1 17
  expect_frame_line 1 13 "$(w_row 8 9)"
  expect_no_frame 1 '^[↑↓] [0-9]+ more'
  _ghr73_at 0
  expect_frame_lines 1 17
  expect_text "watch on a 9-row terminal" "$(out_without_clock)" "$small"
}

# A resize while the loop waits for a key redraws AT ONCE: the stub's `%`
# sends this process a real SIGWINCH from inside the key read, where the trap
# is armed. The second frame is the first one's table cut for the new height
# — no tick passed, no key was read and nothing was fetched again — and the
# cursor is still restored once, on the way out.
case_watch_resize_redraws_the_frame_in_hand() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_SLOTS=9 RUNNERCTL_STUB_LINES=11,15 RUNNERCTL_STUB_KEYS='%-q' run watch
  expect_rc 0
  frames
  expect_frame_count 3
  expect_frame_lines 1 11
  expect_frame_line 1 8 "$(down_mark 6)"
  expect_frame_lines 2 15
  expect_frame_line 2 12 "$(down_mark 2)"
  expect_frame_line 2 5 "$(cursor_row 0 1)"
  expect_log_order '^probe:term_cursor hide$' '^probe:winch$' '^probe:pause 2$' '^probe:tty_read_char 2 q$' '^probe:term_cursor show$'
  expect_log_count '^probe:winch$' 1
  expect_log_count '^probe:pause ' 1
  expect_log_count '^probe:term_cursor ' 2
  # two fetches of nine slots: the first frame and the tick, not the resize
  expect_log_count '^probe:unit_props ' 18
}

# --iterations is the headless path and does not come through the viewport:
# a pinned height is never even asked for, and every row is drawn.
case_watch_iterations_ignores_the_height() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_SLOTS=9 RUNNERCTL_STUB_LINES=5 run watch --iterations 2
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 2
  expect_out_count '^[0-9] +example\.slot-[1-9] ' 18
  expect_no_out '^[↑↓] [0-9]+ more'
  expect_no_path "$LOG.lines"
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_LINES=5 RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --iterations 2 --color never
  expect_rc 0
  expect_out_count '^build-[12] +[0-9] +example\.slot-[1-3] ' 12
  expect_under_header "$SUM_OK" 2
  expect_no_out '^[↑↓] [0-9]+ more'
  expect_no_path "$LOG.lines"
}

# `fleet watch`, two hosts of three slots on a 10-row terminal: the 14-line
# frame is 10, with the header, the SUMMARY LINE directly under it (GHR-72 —
# fixed chrome here, not a table line that can scroll away) and the column
# header on top, and the legend and status line at the bottom. The window is
# over frame lines, so the counts include the hosts' Disk lines. A host line
# comes into view WITH its host's first slot: by itself going down (frame 4),
# and going up because the window gives a row to it (frame 7: k k from
# build-2's last slot leaves the cursor inside the window, which moves anyway).
case_fleet_watch_tall_frame_is_cut_and_scrolls() {
  local f
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_LINES=10 RUNNERCTL_STUB_KEYS=$'jjjGkkkg\e[6~\e[5~-q' \
    RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet watch --color never
  expect_rc 0
  expect_under_header "$SUM_OK" 12
  frames
  expect_frame_count 12
  for f in 1 2 3 4 5 6 7 8 9 10 11; do
    expect_frame_lines "$f" 10
    expect_frame_line "$f" 1 '^runnerctl fleet watch — 2 host\(s\) — [0-9]{2}:[0-9]{2}:[0-9]{2} — every 5s \(q to quit\)$'
    expect_frame_line "$f" 2 "^${SUM_OK}\$"
    expect_frame_line "$f" 3 '^HOST +IDX +RUNNER +PROFILE .* WORKING-ON$'
    expect_frame_line "$f" 8 '^$'
    expect_frame_line "$f" 9 "$FLEET_WATCH_LEGEND"
    expect_frame_line "$f" 10 '^$'
    _expect
    [ "$(grep -c "^${ESC}\[7m" <<<"${FRAMES[$f]}"; true)" -eq 1 ] || FAILS+=("frame $f: not exactly one cursor row")
  done
  # the top: build-1's host line, its first two slots, five lines below
  expect_frame_line 1 4 '^build-1 +Disk: '
  expect_frame_line 1 5 "$(fw_row build-1 0 1)"
  expect_frame_line 1 6 '^build-1 +1 +example\.slot-2 '
  expect_frame_line 1 7 "$(down_mark 5)"
  # j j: build-1's last slot crosses the edge
  expect_frame_line 3 4 "$(up_mark 2)"
  expect_frame_line 3 6 "$(fw_row build-1 2 3)"
  expect_frame_line 3 7 "$(down_mark 4)"
  # j: build-2's first slot, under its own host line
  expect_frame_line 4 4 "$(up_mark 4)"
  expect_frame_line 4 5 '^build-2 +Disk: '
  expect_frame_line 4 6 "$(fw_row build-2 0 1)"
  expect_frame_line 4 7 "$(down_mark 2)"
  # G: the last row of the fleet, nothing under it
  expect_frame_line 5 4 "$(up_mark 5)"
  expect_frame_line 5 7 "$(fw_row build-2 2 3)"
  expect_no_frame 5 '^↓ [0-9]'
  # k: inside the window, nothing moves
  expect_frame_line 6 4 "$(up_mark 5)"
  expect_frame_line 6 6 "$(fw_row build-2 1 2)"
  # k: build-2's first slot was already on screen — its host line joins it
  expect_frame_line 7 4 "$(up_mark 4)"
  expect_frame_line 7 5 '^build-2 +Disk: '
  expect_frame_line 7 6 "$(fw_row build-2 0 1)"
  expect_frame_line 7 7 "$(down_mark 2)"
  # k: up over the host line, onto build-1's last slot
  expect_frame_line 8 4 "$(up_mark 3)"
  expect_frame_line 8 5 "$(fw_row build-1 2 3)"
  expect_frame_line 8 6 '^build-2 +Disk: '
  expect_frame_line 8 7 "$(down_mark 3)"
  # g: the first row, and build-1's host line above it
  expect_frame_line 9 4 '^build-1 +Disk: '
  expect_frame_line 9 5 "$(fw_row build-1 0 1)"
  expect_no_frame 9 '^↑ [0-9]'
  # PgDn: a window of three lines less one — build-1's last slot
  expect_frame_line 10 4 "$(up_mark 2)"
  expect_frame_line 10 6 "$(fw_row build-1 2 3)"
  # PgUp: the window is two lines now, so one row up
  expect_frame_line 11 5 "$(fw_row build-1 1 2)"
  expect_frame_line 11 7 "$(down_mark 4)"
  # every one of those frames off the first fan-out; the tick is the second
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 2
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 2
}

# viewport_frame itself, on frames the stub cannot produce. Each expected
# frame is the whole text, pinned.
#   * A line longer than the terminal is the ROWS it wraps to: a 25-character
#     status line on 10 columns is three rows, so the window is two rows
#     smaller than the line count says and the frame is 10 lines on 12 rows.
#   * Rows that cannot be used — the next line needs three, one is left — are
#     blank lines above the legend, so it stays on the terminal's last rows.
#   * The cursor on the LAST row brings the notes under it into view (TAIL);
#     on any other row the window stops at the cursor.
#   * A cursor line taller than the window, or no room for a window at all:
#     not fitted, the frame comes back whole.
_ghr73_frame() { # HEIGHT COLS BODY STATUS CURSOR LEAD TAIL
  run_snippet "$STUB" "VIEW_TOP=${8:-0}; viewport_frame $1 $2 HEAD $(printf %q "$3") $(printf %q $'\nLEGEND\n'"$4") $5 $6 $7; printf '%s\n[%s %s %s]\n' \"\$VIEW_OUT\" \"\$VIEW_FITTED\" \"\$VIEW_PAGE\" \"\$VIEW_TOP\""
}
case_viewport_frame_counts_rows_not_lines() {
  local body=$'IDX X\n0 a\n1 b\n2 c\n3 d\n4 e\n5 f\n6 g\n7 h\n8 i\n9 j' long=xxxxxxxxxxxxxxxxxxxxxxxxx
  _ghr73_frame 12 10 "$body" "$long" 2 2 2
  expect_rc 0
  expect_text "a wrapped status line" $'HEAD\nIDX X\n0 a\n1 b\n2 c\n3 d\n↓ 6 more  PgDn/G\n\nLEGEND\n'"$long"$'\n[true 4 1]' "$OUT"
  # the same frame with the width unknown: every line is one row
  _ghr73_frame 12 0 "$body" "$long" 2 2 2
  expect_text "width unknown" $'HEAD\nIDX X\n0 a\n1 b\n2 c\n3 d\n4 e\n5 f\n↓ 4 more  PgDn/G\n\nLEGEND\n'"$long"$'\n[true 6 1]' "$OUT"
  # a three-row line that does not fit in the two rows left: one padding line
  _ghr73_frame 9 10 $'IDX X\n0 a\n1 b\n2 '"$long"$'\n3 d\n4 e' st 2 2 2
  expect_text "padding above the legend" $'HEAD\nIDX X\n0 a\n1 b\n↓ 3 more  PgDn/G\n\n\nLEGEND\nst\n[true 2 1]' "$OUT"
}
case_viewport_frame_brings_the_notes_in_with_the_last_row() {
  local body=$'IDX X\n0 a\n1 b\n2 c\n3 d\n4 e\n5 f\nnote: one\nnote: two'
  _ghr73_frame 9 0 "$body" st 7 7 1000000
  expect_rc 0
  expect_text "the last row and its notes" $'HEAD\nIDX X\n↑ 5 more  PgUp/g\n5 f\nnote: one\nnote: two\n\nLEGEND\nst\n[true 3 6]' "$OUT"
  # the benign twin, pinned so the case above keeps meaning something: the
  # same cursor line WITHOUT a tail stops at the cursor and leaves the notes
  _ghr73_frame 9 0 "$body" st 7 7 7
  expect_text "the same row with no tail" $'HEAD\nIDX X\n↑ 4 more  PgUp/g\n4 e\n5 f\n↓ 2 more  PgDn/G\n\nLEGEND\nst\n[true 2 5]' "$OUT"
  # nothing selected: the window stays where it was (VIEW_TOP 3)
  _ghr73_frame 9 0 "$body" st 0 0 0 3
  expect_text "no cursor" $'HEAD\nIDX X\n↑ 2 more  PgUp/g\n2 c\n3 d\n↓ 4 more  PgDn/G\n\nLEGEND\nst\n[true 2 3]' "$OUT"
  # A window left BELOW the cursor (VIEW_TOP 8, on the notes — a table that
  # shrank under it) comes back up to the cursor line. Four notes, so that
  # the window from the cursor's LEAD cannot reach the TAIL: wherever it can,
  # the LEAD step moves the window up as well and this pull is never the one
  # being tested — which is what every j/k/g case above is, and why deleting
  # the pull left all of them green.
  _ghr73_frame 9 0 "$body"$'\nnote: three\nnote: four' st 7 7 1000000 8
  expect_text "a window below the cursor" $'HEAD\nIDX X\n↑ 5 more  PgUp/g\n5 f\nnote: one\n↓ 3 more  PgDn/G\n\nLEGEND\nst\n[true 2 6]' "$OUT"
}
case_viewport_frame_too_small_is_drawn_whole() {
  local body=$'IDX X\n0 a\n1 b\n2 c\n3 d\n4 e' long=xxxxxxxxxxxxxxxxxxxxxxxxx
  # chrome 5 + window 2: under the minimum of 3
  _ghr73_frame 7 0 "$body" st 2 2 2
  expect_rc 0
  expect_text "window under the minimum" $'HEAD\n'"$body"$'\n\nLEGEND\nst\n[false 0 0]' "$OUT"
  # one row more and it is fitted: two lines and a count
  _ghr73_frame 8 0 "$body" st 2 2 2
  expect_text "window at the minimum" $'HEAD\nIDX X\n0 a\n1 b\n↓ 3 more  PgDn/G\n\nLEGEND\nst\n[true 2 1]' "$OUT"
  # a cursor line of three rows in a window of four, with a count on each side
  _ghr73_frame 9 10 $'IDX X\n0 a\n1 b\n2 '"$long"$'\n3 d\n4 e' st 4 4 4
  expect_text "cursor line taller than the window" $'HEAD\nIDX X\n0 a\n1 b\n2 '"$long"$'\n3 d\n4 e\n\nLEGEND\nst\n[false 0 0]' "$OUT"
}

# The paging keys through the REAL read_key, one character per read: every
# spelling of Home and End, a numbered sequence nobody binds (`other`), and
# the `~` each numbered one ends in read with it rather than left to arrive
# as a key of its own.
case_read_key_decodes_the_paging_keys() {
  RUNNERCTL_STUB_KEYS=$'\e[5~\e[6~\e[H\e[F\e[1~\e[4~\e[7~\e[8~\eOH\eOF\e[3~x' \
    run_snippet "$STUB" "while read_key 1; do echo \"\$KEY\"; done"
  expect_rc 0
  expect_text "decoded keys" $'pgup\npgdn\nhome\nend\nhome\nend\nhome\nend\nhome\nend\nother\nx' "$OUT"
}

# The REAL term_lines — every case above reads the height through the stub's.
# run_fn sources the script with no config, so the function is the script's
# own, against a fake tput first on PATH: a number is the height, and a tput
# that fails, answers something that is not a number, or is not there at all
# is 0 — unknown, which draws the frame whole.
_ghr73_fake_tput() { # NAME BODY
  local dir="$TMP/ghr73-$1"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$dir/tput"
  chmod +x "$dir/tput"
  echo "$dir"
}
case_term_lines_real_function_reads_tput() {
  local bin saved="$PATH" tool
  bin="$(_ghr73_fake_tput ok "case \"\$1\" in lines) echo 37 ;; cols) echo 120 ;; *) exit 2 ;; esac")"
  PATH="$bin:$PATH"
  run_fn term_lines
  PATH="$saved"
  expect_rc 0
  expect_text "tput lines" 37 "$OUT"
  bin="$(_ghr73_fake_tput fails 'echo "tput: no value for TERM" >&2; exit 2')"
  PATH="$bin:$PATH"
  run_fn term_lines
  PATH="$saved"
  expect_rc 0
  expect_text "a failing tput" 0 "$OUT"
  expect_no_err '.'
  bin="$(_ghr73_fake_tput garbage 'echo unknown')"
  PATH="$bin:$PATH"
  run_fn term_lines
  PATH="$saved"
  expect_text "a tput that answers no number" 0 "$OUT"
  # no tput at all: a PATH holding only what the harness itself needs
  bin="$TMP/ghr73-none"
  mkdir -p "$bin"
  for tool in bash cat rm; do ln -sf "$(command -v "$tool")" "$bin/$tool"; done
  PATH="$bin"
  run_fn term_lines
  PATH="$saved"
  expect_rc 0
  expect_text "no tput on PATH" 0 "$OUT"
}

# --- GHR-74: fleet watch fetches in the background -----------------------------
# Each host is fetched by a job of its own and the frame is assembled from what
# each host last returned. Three stub knobs carry these cases (tests/stub.config
# has the detail of each):
#   RUNNERCTL_STUB_FLEET_HANG   a host whose table call never returns — it
#                               blocks, really, until the process is killed
#   RUNNERCTL_STUB_CLOCK=1      the pinned clock moves with every `pause`, so
#                               an age is a number a case can pin
#   RUNNERCTL_STUB_FLEET_DELAY  its fourth field: slow from frame poll N on
# and the stub models the watch's poll step: a step waits until every fetch has
# landed or is hung, a step in which something landed consumes no key, and
# only a step with nothing but hung hosts out reads RUNNERCTL_STUB_KEYS — so a
# key logged with the poll step as its timeout (`probe:tty_read_char 0.2 j`)
# is a key handled WHILE A HOST WAS OUTSTANDING.
#
# Frame line numbers, for two hosts of three slots at unknown height: 1 the
# header, 2 the summary, 3 the column header, 4 build-1's Disk line, 5-7 its
# slots, 8 build-2's Disk line — or the age line over its kept rows — 9-11
# its slots.
SUM_ONE='1/2 hosts answering · 3 slots: 1 busy, 1 idle, 1 disabled · capacity 1 free of 2'

# The pids in PIDS are gone, within two seconds. Whatever is not gets killed
# here — by pid, the ones the hung call wrote down itself — so a failing run
# does not leave them spinning.
_ghr74_expect_dead() { # PIDS
  _expect
  local p n alive=""
  [ -n "$1" ] || FAILS+=("no pid was recorded for the hung call")
  for p in $1; do
    n=0
    while kill -0 "$p" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
    if kill -0 "$p" 2>/dev/null; then
      alive+=" $p"
      kill "$p" 2>/dev/null || true
    fi
  done
  [ -z "$alive" ] || FAILS+=("still running after the watch exited:$alive")
}
_ghr74_expect_empty() { # DIR
  _expect
  local left
  left="$(find "$1" -mindepth 1 -maxdepth 1 2>/dev/null | tr '\n' ' '; true)"
  [ -z "$left" ] || FAILS+=("left behind in the temp directory: $left")
}

# The acceptance case. slow-1 accepts its call and never answers. The frame
# with build-1's rows is drawn all the same — on the first poll step, with
# slow-1 as a row saying it has not answered yet — and j, pressed while
# slow-1 is still out, moves the cursor in the next frame. slow-1's call
# never does return: the watch is quit with it outstanding.
#
# RUN_TIMEOUT is short on purpose: a loop that waits for the slowest host
# again blocks on slow-1 until it is killed, and draws nothing.
case_fleet_watch_a_hung_host_holds_up_neither_the_frame_nor_a_key() {
  RUN_TIMEOUT=10 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='jq' RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-1" \
    RUNNERCTL_STUB_FLEET_HANG="slow-1" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 2
  # frame 1: build-1 whole, and counted; slow-1 a row, and not
  expect_frame_line 1 2 "^${SUM_ONE}\$"
  expect_frame 1 "$(fw_row build-1 0 1)"
  expect_frame 1 '^build-1 +1 +example\.slot-2 '
  expect_frame 1 '^build-1 +2 +example\.slot-3 '
  expect_frame 1 '^slow-1 +waiting for its first answer$'
  # frame 2: the key, handled with slow-1 still out
  expect_frame 2 "$(fw_row build-1 1 2)"
  expect_frame 2 '^slow-1 +waiting for its first answer$'
  expect_log_count '^probe:tty_read_char 0\.2 j$' 1
  expect_log_count '^probe:tty_read_char 0\.2 q$' 1
  # the step build-1 landed in read no key; the two after it did
  expect_log_order '^probe:fleet_poll landed=1 hung=1$' '^probe:fleet_poll landed=0 hung=1$' \
                   '^probe:tty_read_char 0\.2 j$' '^probe:fleet_poll landed=0 hung=1$' '^probe:tty_read_char 0\.2 q$'
  # slow-1 was dialled once, for its table, and that call never came back
  expect_log_count '^probe:ssh_run slow-1 -- runnerctl status --color never$' 1
  expect_log_count '^probe:ssh_run slow-1 -- ' 1
  expect_no_log '^probe:ssh_run_done slow-1$'
  expect_log_count '^probe:ssh_run build-1 -- ' 2
}

# Before any host has answered there is still a frame: nobody answering, each
# host a row that says so in its own words — `waiting`, not `unreachable`,
# which would be a claim nothing has tested yet. The cursor waits on the first
# of them, and a key there acts on nothing and dials nothing (the row is a
# host, not a slot).
case_fleet_watch_first_frame_before_any_host_has_answered() {
  RUN_TIMEOUT=10 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='-Sq' RUNNERCTL_STUB_FLEET_HOSTS="slow-1 slow-2" \
    RUNNERCTL_STUB_FLEET_HANG="slow-1 slow-2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 2
  expect_frame_line 1 2 '^0/2 hosts answering$'
  expect_frame_line 1 3 "^${REV}slow-1 +waiting for its first answer$ESC\[0m\$"
  expect_frame_line 1 4 '^slow-2 +waiting for its first answer$'
  expect_no_out 'unreachable|timed out|HOST +IDX'
  expect_frame 2 '^slow-1: not answering — no slot there to act on$'
  expect_no_out '\[y/n\]'
  # one call each, the table's; no facts read for the S
  expect_log_count '^probe:ssh_run ' 2
  expect_no_log ' --json'
}

# Nothing outlives the watch: not the fetch job of a host that never answered,
# not the call under it, not a file. Quit with q, and with Ctrl-C (the stub's
# ETX, $'\x03', is a real SIGINT, so the script's own INT and EXIT traps are
# what run — it was `!` until GHR-75 made that a key the watch reads);
# the hung call wrote its pid and its job's down, and both are gone. TMPDIR
# points every mktemp of the run at one directory, which is empty afterwards —
# the buffer of each host's last answer, the action keys' buffer and the ssh
# control directory. `--iterations` ending leaves it empty as well.
case_fleet_watch_exit_ends_its_fetches_and_removes_its_files() {
  local d="$TMP/ghr74-tmp" how
  for how in q $'\x03'; do
    rm -rf "$d"; mkdir -p "$d"
    TMPDIR="$d" RUN_TIMEOUT=10 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS="$how" RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-1" \
      RUNNERCTL_STUB_FLEET_HANG="slow-1" run fleet watch --color never
    expect_rc 0
    expect_cfg "$WRITES/remote/slow-1.hung.pids" '^[0-9]+ [0-9]+$'
    _ghr74_expect_dead "$(cat "$WRITES/remote/slow-1.hung.pids" 2>/dev/null; true)"
    _ghr74_expect_empty "$d"
    expect_no_log '^probe:ssh_run_done slow-1$'
    expect_log_order '^probe:term_cursor show$' '^probe:ssh_control build-1 exit$' '^probe:ssh_control slow-1 exit$'
  done
  # SIGINT, or SIGTERM where this run inherited SIGINT ignored (a backgrounded
  # gate) — the stub says which, and the watch answers both on one trap line
  expect_log_count '^probe:sig(int|term)$' 1
  rm -rf "$d"; mkdir -p "$d"
  TMPDIR="$d" RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 gw-unreachable" \
    run fleet watch --iterations 2 --color never
  expect_rc 0
  expect_out_count "$FRAME_PREFIX" 2
  _ghr74_expect_empty "$d"
  rm -rf "$d"
}

# The other acceptance case: a host that answered and then cannot be reached
# keeps its rows, under a line that says how old they are, when it was last
# seen and why — not one bare error row. build-2 is down for ticks 2 and 3 and
# back for tick 4; the clock moves 5 s a tick, from 01:58:40 UTC, and build-2
# was last seen at tick 1: 5 s ago at tick 2, 10 s ago at tick 3, the same
# instant both times. Tick 4 draws it as it was before, Disk line and all.
case_fleet_watch_a_host_that_stops_answering_keeps_its_rows_with_an_age() {
  local f
  TZ=UTC RUNNERCTL_STUB_CLOCK=1 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='---q' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DOWN="build-2:2,3" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 4
  for f in 1 4; do
    expect_frame_line "$f" 8 '^build-2 +Disk: '
    expect_no_frame "$f" 'no answer'
  done
  expect_frame_line 2 8 '^build-2 +no answer for 5s — last seen 01:58:40 — unreachable — ssh: connect to host build-2 port 22: No route to host$'
  expect_frame_line 3 8 '^build-2 +no answer for 10s — last seen 01:58:40 — unreachable — ssh: connect to host build-2 port 22: No route to host$'
  for f in 1 2 3 4; do
    expect_frame_line "$f" 9 '^build-2 +0 +example\.slot-1 .* my-app:test \(12m\)$'
    expect_frame_line "$f" 10 '^build-2 +1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
    expect_frame_line "$f" 11 '^build-2 +2 +example\.slot-3 '
    expect_frame_line "$f" 12 '^$'
  done
  expect_no_out '^build-2 +unreachable'
  expect_no_frame 2 '^build-2 +Disk: '
  # painted: the age line red, and each kept row dim as a whole with the
  # remote's own colours taken off — the STALLED it painted bold red at tick 1
  # is plain text inside the dim at tick 2
  TZ=UTC RUNNERCTL_STUB_CLOCK=1 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='-q' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DOWN="build-2:2" run fleet watch --color always --stall-after 600
  expect_rc 0
  frames
  expect_frame_count 2
  expect_frame_line 1 9 "^build-2 +0 +example\.slot-1 .*$ESC\[1m$ESC\[31mmy-app:test \(12m\) STALLED$ESC\[0m\$"
  expect_frame_line 2 8 "^build-2 +$ESC\[31mno answer for 5s — last seen 01:58:40 — unreachable — .*$ESC\[0m\$"
  expect_frame_line 2 9 "^$ESC\[2mbuild-2 +0 +example\.slot-1 [^$ESC]* my-app:test \(12m\) STALLED$ESC\[0m\$"
  expect_frame_line 2 10 "^$ESC\[2mbuild-2 +1 +example\.slot-2 [^$ESC]*$ESC\[0m\$"
}

# A call still out when the next tick comes due makes its host LATE — and not
# before. build-2 answers tick 1 and hangs from tick 2. In the frame of tick 2
# its rows are simply the newest there are (a call that has been out for less
# than an interval is not news), and it still counts. At tick 3 it has missed
# a whole interval: its rows are kept under their age, it is not asked a
# second time while the first call is out, and the summary stops counting it.
case_fleet_watch_a_call_still_out_at_the_next_tick_is_late() {
  TZ=UTC RUN_TIMEOUT=10 RUNNERCTL_STUB_CLOCK=1 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='--q' \
    RUNNERCTL_STUB_FLEET_HOSTS="$FW2" RUNNERCTL_STUB_FLEET_HANG="build-2:2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 3
  expect_frame_line 2 2 "^${SUM_OK}\$"
  expect_frame_line 2 8 '^build-2 +Disk: '
  expect_no_frame 2 'no answer'
  expect_frame_line 3 2 "^${SUM_ONE}\$"
  expect_frame_line 3 8 '^build-2 +no answer for 10s — last seen 01:58:40 — its call is still running$'
  expect_frame_line 3 9 '^build-2 +0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_frame_line 3 11 '^build-2 +2 +example\.slot-3 '
  # build-1 three ticks; build-2 two — the one that answered, the one still out
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --color never$' 3
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 2
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json$' 1
}

# PINNED SEPARATELY, because it is the claim the kept rows rest on: rows that
# are only being kept on screen are worth NOTHING to S's capacity floor. One
# run, both sides. While build-2 answers, a stop on build-1 leaves 3 of 6.
# From tick 2 build-2 answers nothing (every call to it runs out of time),
# its three rows are still in the frame — and the same stop now leaves 1 of 3,
# with one host not answering and not counted. A floor that read the frame, or
# the answers the frame was built from, would still say 3 of 6.
#
# Also what the floor's fan-out must NOT do to the session: the watch's one
# EXIT trap is still the one that runs on q, cursor first, then the masters.
case_fleet_watch_floor_counts_nothing_for_a_host_with_kept_rows() {
  RUNNERCTL_STUB_CLOCK=1 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Sn-Snq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DELAY="build-2:99:status:2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 6
  expect_frame 2 '^Stop example\.slot-1 on build-1\? runs on build-1: runnerctl stop example\.slot-1 — leaves 3 of 6 slot\(s\) active across the watched hosts  \[y/n\]$'
  expect_no_frame 2 'no answer'
  # frame 5: build-2's rows on screen, and not in the arithmetic
  expect_frame_line 5 8 '^build-2 +no answer for 5s — last seen [0-9]{2}:[0-9]{2}:[0-9]{2} — timed out after 10s$'
  expect_frame_line 5 9 '^build-2 +0 +example\.slot-1 .* my-app:test \(12m\)$'
  expect_frame_line 5 10 '^build-2 +1 +example\.slot-2 '
  expect_frame_line 5 11 '^build-2 +2 +example\.slot-3 '
  expect_frame 5 '^Stop example\.slot-1 on build-1\? runs on build-1: runnerctl stop example\.slot-1 — leaves 1 of 3 slot\(s\) active across the watched hosts, 1 host\(s\) not answering and not counted  \[y/n\]$'
  expect_no_frame 5 'leaves [0-9]+ of 6 '
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl stop '
  expect_log_order '^probe:tty_read_char 5 q$' '^probe:term_cursor show$' '^probe:ssh_control build-1 exit$' '^probe:ssh_control build-2 exit$'
  expect_log_count '^probe:term_cursor ' 2
}

# S pressed while a host's fetch is still out. The floor's fan-out waits for
# ITS OWN calls and nothing else: a bare `wait` there would also sit through
# slow-1's frame fetch, which never returns, and the key would be dead until
# the run was killed. (The stub hangs slow-1's table call only, so the floor's
# own --json read of it answers and its three slots count.)
case_fleet_watch_floor_does_not_wait_for_a_fetch_still_out() {
  RUN_TIMEOUT=10 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Snq' RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-1" \
    RUNNERCTL_STUB_FLEET_HANG="slow-1" run fleet watch --color never
  expect_rc 0
  expect_out_count '^Stop example\.slot-1 on build-1\? runs on build-1: runnerctl stop example\.slot-1 — leaves 3 of 6 slot\(s\) active across the watched hosts  \[y/n\]$' 1
  expect_out_count '^cancelled — nothing run$' 1
  expect_log_order '^probe:tty_read_char 0\.2 S$' '^probe:ssh_run slow-1 -- runnerctl status --json$' \
                   '^probe:tty_read_char 0\.2 n$' '^probe:tty_read_char 0\.2 q$'
  # two calls to slow-1 went out and one came back: the floor's
  expect_log_count '^probe:ssh_run slow-1 -- ' 2
  expect_log_count '^probe:ssh_run_done slow-1$' 1
}

# The summary line, the same rule: a host whose rows are kept is in the host
# count as NOT answering and in nothing else. Tick 2 has build-2's three rows
# in the frame and three slots in the summary. Nor is it dialled for the
# summary's --json on the tick it did not answer: two such calls to build-2
# over three ticks, three to build-1.
case_fleet_watch_summary_counts_nothing_for_a_host_with_kept_rows() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='--q' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DOWN="build-2:2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 3
  expect_frame_line 1 2 "^${SUM_OK}\$"
  expect_frame_line 2 2 "^${SUM_ONE}\$"
  expect_frame_line 2 9 '^build-2 +0 +example\.slot-1 '
  expect_frame_line 2 10 '^build-2 +1 +example\.slot-2 '
  expect_frame_line 2 11 '^build-2 +2 +example\.slot-3 '
  expect_frame_line 3 2 "^${SUM_OK}\$"
  expect_log_count '^probe:ssh_run build-1 -- runnerctl status --json$' 3
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --json$' 2
  expect_log_count '^probe:ssh_run build-2 -- runnerctl status --color never$' 3
  expect_log_count '^probe:ssh_run ' 11
}

# FLEET_WATCH_TIMEOUT: the watch's reads have a budget of their own, 10 s by
# default, and `fleet status` does not. slow-1 takes 15 s to answer anything —
# inside FLEET_TIMEOUT's 30, outside the watch's 10. So the watch times it out
# and says after how long, the one-shot gets its rows, and a watch whose
# budget is raised past 15 gets them too. S's floor reads on the same budget
# (slow-1 is not counted), and so does the facts read an action key makes: K
# on a row kept from a host that has since gone slow is told so, in 10 s.
case_fleet_watch_reads_are_on_their_own_budget() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-1" RUNNERCTL_STUB_FLEET_DELAY="slow-1:15" \
    run fleet watch --iterations 1 --color never
  expect_rc 0
  expect_out_count '^slow-1 +timed out after 10s$' 1
  expect_out_count '^build-1 +0 +example\.slot-1 ' 1
  expect_under_header "$SUM_ONE" 1
  RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-1" RUNNERCTL_STUB_FLEET_DELAY="slow-1:15" run fleet status
  expect_rc 0
  expect_out_count '^slow-1 +0 +example\.slot-1 ' 1
  expect_no_out 'timed out'
  printf '. %q\nFLEET_WATCH_TIMEOUT=20\n' "$PWD/$STUB" >"$TMP/ghr74.config"
  chmod 644 "$TMP/ghr74.config"
  STUB="$TMP/ghr74.config" RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-1" \
    RUNNERCTL_STUB_FLEET_DELAY="slow-1:15" run fleet watch --iterations 1 --color never
  expect_rc 0
  expect_out_count '^slow-1 +0 +example\.slot-1 ' 1
  expect_no_out 'timed out'
  printf '. %q\nFLEET_WATCH_TIMEOUT=0\n' "$PWD/$STUB" >"$TMP/ghr74.config"
  STUB="$TMP/ghr74.config" RUNNERCTL_STUB_FLEET_HOSTS="build-1" run fleet status
  expect_rc 1
  expect_err "^runnerctl: FLEET_WATCH_TIMEOUT '0' set in .* is invalid — want a whole number of seconds, 1 or more\$"
  expect_no_log '^probe:ssh_run'
  # the floor
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='Snq' RUNNERCTL_STUB_FLEET_HOSTS="build-1 slow-1" \
    RUNNERCTL_STUB_FLEET_DELAY="slow-1:15" run fleet watch --color never
  expect_rc 0
  expect_out_count '^Stop example\.slot-1 on build-1\? .* — leaves 1 of 3 slot\(s\) active across the watched hosts, 1 host\(s\) not answering and not counted  \[y/n\]$' 1
  # the facts read at a key, on a kept row
  RUNNERCTL_STUB_CLOCK=1 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='-Kq' RUNNERCTL_STUB_FLEET_HOSTS="build-1" \
    RUNNERCTL_STUB_FLEET_DELAY="build-1:15:status:2" run fleet watch --color never
  expect_rc 0
  expect_out "^${REV}build-1 +0 +example\.slot-1 .*$ESC\[0m\$"
  expect_out_count '^build-1 +no answer for 5s — last seen [0-9]{2}:[0-9]{2}:[0-9]{2} — timed out after 10s$' 2
  expect_out_count '^example\.slot-1 on build-1: could not read its current state — timed out after 10s$' 1
  expect_no_out '\[y/n\]'
  expect_no_log '^probe:ssh_run [^ ]+ -- runnerctl kill '
}

# FLEET_PARALLEL still caps the calls in flight, now that each host has a job
# of its own: with it at 1, three hosts are fetched one after another and the
# stub's overlap detector (a lock held for a window, see ssh_run_body) never
# trips. The twin run, at the default of 8, trips it — which is what makes the
# first one evidence rather than a detector that cannot fire.
case_fleet_watch_fetches_respect_fleet_parallel() {
  printf '. %q\nFLEET_PARALLEL=1\n' "$PWD/$STUB" >"$TMP/ghr74.config"
  chmod 644 "$TMP/ghr74.config"
  STUB="$TMP/ghr74.config" RUNNERCTL_STUB_DETECT_OVERLAP=1 RUNNERCTL_STUB_TTY=1 \
    RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 build-3" run fleet watch --iterations 1 --color never
  expect_rc 0
  expect_out_count '^build-[123] +0 +example\.slot-1 ' 3
  expect_log_count '^probe:ssh_run ' 6
  expect_no_log '^probe:ssh_run_overlap '
  RUNNERCTL_STUB_DETECT_OVERLAP=1 RUNNERCTL_STUB_TTY=1 \
    RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 build-3" run fleet watch --iterations 1 --color never
  expect_rc 0
  expect_log '^probe:ssh_run_overlap '
}

# now_ms — the clock the ticks are scheduled on — is shadowed by the stub (the
# pinned clock), so the real one is pinned here: thirteen digits, the instant
# date's seconds say it is, from bash's own clock and, with that taken away,
# from date. And ms_to_secs, which turns what is left of an interval into the
# timeout of the key read: whole seconds stay whole, which is what keeps that
# read's logged timeout the `5` it always was.
case_now_ms_real_function_is_epoch_milliseconds() {
  local s how
  for how in 'now_ms' 'unset EPOCHREALTIME; now_ms'; do
    s="$(date +%s)"
    run_fn eval "$how"
    expect_rc 0
    expect_out '^[0-9]{13}$'
    _expect
    if ! [[ "$OUT" =~ ^[0-9]{13}$ ]] || [ $((OUT / 1000 - s)) -lt 0 ] || [ $((OUT / 1000 - s)) -gt 2 ]; then
      FAILS+=("'$how' answered '$OUT', not the millisecond of epoch second $s")
    fi
  done
  run_fn eval 'ms_to_secs 5000; ms_to_secs 4412; ms_to_secs 200; ms_to_secs 60005'
  expect_rc 0
  expect_text "milliseconds as seconds" $'5\n4.412\n0.200\n60.005' "$OUT"
}

# Everything above runs the stub's ssh_run and the stub's model of the poll
# step. This one runs the REAL ssh_run — the real `timeout`, which puts itself
# and its command in a process group of their own — against a fake `ssh`, and
# drives the fetch functions directly:
#   * ok-1's answer is taken in whole (table, summary payload, both exit
#     statuses) while hang-1's call is still out, and nothing of hang-1's is
#     published;
#   * a round asked for by an action key while ok-1's call was already out
#     fetches ok-1 AGAIN once that call lands — what it brought back may
#     predate the action;
#   * fleet_watch_reap ends hang-1's job AND the ssh under its `timeout`,
#     which is not in the job's process group and would otherwise sit there
#     until the budget ran out.
case_fleet_watch_real_fetch_job_and_its_ssh_end_at_cleanup() {
  local d saved="$PATH"
  d="$(mktemp -d "$TMP/ghr74.XXXXXX")"
  mkdir "$d/bin"
  cat >"$d/bin/ssh" <<'EOF'
#!/bin/sh
# A fake remote. The host is the word after `--`; hang-* never answers.
echo "$*" >>"$GHR74_DIR/calls"
while [ "$1" != "--" ]; do shift; done
host="$2"
case "$host" in
  hang-*) echo "$$" >"$GHR74_DIR/ssh.pid"; exec sleep 30 ;;
esac
sleep 0.2
case "$*" in
  *--json*) printf '{"runnerctl":"1.0.0"}\n' ;;
  *)        printf 'runnerctl 1.0.0 — Host: x\n\nIDX RUNNER\n0 example.slot-1\n' ;;
esac
EOF
  chmod +x "$d/bin/ssh"
  PATH="$d/bin:$PATH"
  # shellcheck disable=SC2016
  GHR74_DIR="$d" run_fn eval '
    FLEET_HOSTS=(ok-1 hang-1) FLEET_BUDGETS=(20 20)
    FW_STATE="$(mktemp -d)" FW_PID=("" "") FW_AGAIN=("" "") FW_TABLE_ARGS=(status --color never)
    echo late >"$FW_STATE/0.rc"; echo late >"$FW_STATE/1.rc"
    fleet_watch_round tick
    fleet_watch_round refresh
    n=0
    while [ "$(grep -c -- "-- ok-1 runnerctl status --color" "$GHR74_DIR/calls"; true)" -lt 2 ] || [ -n "${FW_PID[0]}" ] || [ ! -s "$GHR74_DIR/ssh.pid" ]; do
      n=$((n + 1)); [ "$n" -lt 300 ] || break
      sleep 0.02
      fleet_watch_collect
    done
    echo "ok-1 rc=$(cat "$FW_STATE/0.rc") jrc=$(cat "$FW_STATE/0.jrc") rows=$(grep -c slot "$FW_STATE/0.out") json=$(cat "$FW_STATE/0.json") seen=$(grep -c . "$FW_STATE/0.seen")"
    echo "ok-1 table calls=$(grep -c -- "-- ok-1 runnerctl status --color" "$GHR74_DIR/calls")"
    echo "hang-1 rc=$(cat "$FW_STATE/1.rc") job=${FW_PID[1]:+out} published=$(ls "$FW_STATE" | grep -c "^1\.done"; true) seen=$(ls "$FW_STATE" | grep -c "^1\.seen"; true)"
    job="${FW_PID[1]}" ssh_pid="$(cat "$GHR74_DIR/ssh.pid")"
    if pid_alive "$ssh_pid" && pid_alive "$job"; then echo "both alive before"; fi
    fleet_watch_reap
    n=0
    while { pid_alive "$ssh_pid" || pid_alive "$job"; } && [ "$n" -lt 150 ]; do sleep 0.02; n=$((n + 1)); done
    if pid_alive "$ssh_pid"; then echo "ssh SURVIVED"; kill "$ssh_pid"; fi
    if pid_alive "$job"; then echo "job SURVIVED"; kill "$job"; fi
    echo "reaped job=[${FW_PID[1]}]"
    rm -rf "$FW_STATE"
  '
  PATH="$saved"
  expect_rc 0
  expect_out '^ok-1 rc=0 jrc=0 rows=1 json=\{"runnerctl":"1\.0\.0"\} seen=1$'
  expect_out '^ok-1 table calls=2$'
  expect_out '^hang-1 rc=late job=out published=0 seen=0$'
  expect_out '^both alive before$'
  expect_no_out 'SURVIVED'
  expect_out '^reaped job=\[\]$'
  # and what was dialled is the table call, on the real ssh command line
  expect_cfg "$d/calls" '^-o BatchMode=yes -o ConnectTimeout=10 -- hang-1 runnerctl status --color never$'
  expect_cfg_count "$d/calls" ' -- hang-1 ' 1
  rm -rf "$d"
}

# --- GHR-75: fleet watch views — filter, sort, collapse ------------------------
# The view keys choose what the frame shows and ask no host anything. The
# fixture is two hosts of three slots (slot-1 running my-app:test for 12m,
# slot-2 idle, slot-3 inactive and disabled), and RUNNERCTL_STUB_FLEET_STALL
# names the hosts whose OWN stall threshold is ten minutes — so build-2's
# slot-1 is STALLED while build-1's is merely busy, and one host of the fleet
# is healthy while the other is not.
#
# Frame line numbers at unknown height: 1 the header, 2 the summary, 3 the
# column header, the view from 4. Every probe:ssh_run count is PINNED: two
# hosts cost four calls a round (a table and a --json each), and a view key
# must not add one.
SUM_MIX='2/2 hosts answering · 6 slots: 1 busy, 2 idle, 1 STALLED, 2 disabled · capacity 2 free of 4'
V_ROW="^(${REV})?[^ ]+ +[0-9]+ +example\.slot-"
V_DISK='Disk: / \[docker,work\] 24% \(353\.9G free\)'
V_LEGEND="${FLEET_WATCH_LEGEND%\$}  a all  \? keys\$"
# The header of a frame, with the view it names after it (nothing for none).
view_hdr() { # VIEW-SUFFIX [HOSTS]
  echo "^runnerctl fleet watch — ${2:-2} host\(s\) — [0-9]{2}:[0-9]{2}:[0-9]{2} — every 5s \(q to quit\)$1\$"
}
expect_frame_count_of() { # N PATTERN COUNT
  _expect
  local n
  n="$(grep -Ec -- "$2" <<<"${FRAMES[$1]-}"; true)"
  [ "$n" -eq "$3" ] || FAILS+=("frame $1 lines matching /$2/: want $3, got $n")
}

# The acceptance case. `!` leaves the stalled slot, under its host's line, and
# nothing of the healthy host; the header names the view and the summary goes
# on describing the whole fleet. Frame 1, drawn before the key, has both
# hosts — so what frame 2 lacks is what the filter took, not what the fixture
# never had. `a` brings everything back, with the cursor still on the slot the
# filter moved it to. The `!` reached the script as a KEY (the stub used to
# take it for Ctrl-C), and no host was asked anything for either key.
case_fleet_watch_problems_view_hides_a_healthy_host_and_keeps_a_stalled_slot() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='!aq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_STALL="build-2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 3
  expect_frame_line 1 1 "$(view_hdr '')"
  expect_frame_count_of 1 "$V_ROW" 6
  expect_frame 1 "^build-1 +$V_DISK\$"
  expect_frame 1 "$FLEET_WATCH_LEGEND"
  expect_frame_line 2 1 "$(view_hdr ' — view: problems only')"
  expect_frame_line 2 2 "^${SUM_MIX}\$"
  expect_frame_line 2 3 '^HOST +IDX +RUNNER '
  expect_frame_line 2 4 "^build-2 +$V_DISK\$"
  expect_frame_line 2 5 "^${REV}build-2 +0 +example\.slot-1 .* my-app:test \(12m\) STALLED$ESC\[0m\$"
  expect_frame_line 2 6 '^note: STALLED = '
  expect_frame_count_of 2 "$V_ROW" 1
  expect_no_frame 2 "^(${REV})?build-1 "
  expect_frame 2 "$V_LEGEND"
  expect_frame_line 3 1 "$(view_hdr '')"
  expect_frame_line 3 2 "^${SUM_MIX}\$"
  expect_frame_count_of 3 "$V_ROW" 6
  expect_frame 3 "$(fw_row build-2 0 1)"
  expect_log_count '^probe:tty_read_char 5 \\!$' 1
  expect_no_log '^probe:sig'
  expect_log_count '^probe:ssh_run ' 4
  expect_no_log '^direct:'
}

# What else is a problem, and what a host that is not answering looks like
# under each filter. `--problems` is the same view from the first frame:
# build-2's disks are past both thresholds over healthy slots, so it is its
# host line ALONE; a host that cannot be reached is its error row; healthy
# build-1 is nowhere.
#
# Then a host that STOPS answering (build-2, down for ticks 2 and 3): under
# --problems a healthy fleet shows nothing but the hint, and at tick 2 build-2
# is there whole — its age line and all three kept rows, healthy as they were
# when last seen, because not answering is the problem. `b` filters kept rows
# by the state the host last reported, under their age line.
case_fleet_watch_problem_hosts_and_hosts_that_stopped_answering() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="build-1 build-2 gw-unreachable" RUNNERCTL_STUB_FLEET_FULL="build-2" \
    run fleet watch --problems --iterations 1 --color never
  expect_rc 0
  expect_out_count "${FRAME_PREFIX}runnerctl fleet watch — 3 host\(s\) — [0-9:]{8} — every 5s \(q to quit\) — view: problems only\$" 1
  expect_out_count '^2/3 hosts answering · 6 slots: 2 busy, 2 idle, 2 disabled · 1 host disk crit · 1 host OOM/disk-full · capacity 2 free of 4$' 1
  expect_out_count '^build-2 +Disk: /var/lib/docker \[docker\] 96% ' 1
  expect_out_count '^gw-unreachable +unreachable — ' 1
  expect_out_count '^HOST +IDX +RUNNER ' 1
  expect_no_out '^build-1 '
  expect_no_out 'example\.slot-'
  expect_no_out 'nothing matches'
  TZ=UTC RUNNERCTL_STUB_CLOCK=1 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='-bq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DOWN="build-2:2,3" run fleet watch --problems --color never
  expect_rc 0
  frames
  expect_frame_count 3
  expect_frame_line 1 2 "^${SUM_OK}\$"
  expect_frame_line 1 4 '^nothing matches — a shows all$'
  expect_frame_line 2 1 "$(view_hdr ' — view: problems only')"
  expect_frame_line 2 2 "^${SUM_ONE}\$"
  expect_frame_line 2 4 '^build-2 +no answer for 5s — last seen 01:58:40 — unreachable — ssh: connect to host build-2 port 22: No route to host$'
  expect_frame_line 2 5 "$(fw_row build-2 0 1)"
  expect_frame_line 2 6 '^build-2 +1 +example\.slot-2 .* idle 2h31m \(2 jobs\)$'
  expect_frame_line 2 7 '^build-2 +2 +example\.slot-3 '
  expect_frame_count_of 2 "$V_ROW" 3
  expect_no_frame 2 "^(${REV})?build-1 "
  expect_frame_line 3 1 "$(view_hdr ' — view: busy only')"
  expect_frame_line 3 4 "^build-1 +$V_DISK\$"
  expect_frame_line 3 5 '^build-1 +0 +example\.slot-1 '
  expect_frame_line 3 6 '^build-2 +no answer for 5s — '
  expect_frame_line 3 7 "$(fw_row build-2 0 1)"
  expect_frame_count_of 3 "$V_ROW" 2
  # the tick's round and nothing else: build-2 failed its table call at tick
  # 2 and is not asked for a payload
  expect_log_count '^probe:ssh_run ' 7
  # folded, a host that stopped answering is its age line and nothing else
  TZ=UTC RUNNERCTL_STUB_CLOCK=1 RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='-cq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_DOWN="build-2:2,3" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 3
  expect_frame_line 3 4 "^${REV}build-1 +3 slots: 1 busy, 1 idle, 1 disabled · $V_DISK$ESC\[0m\$"
  expect_frame_line 3 5 '^build-2 +no answer for 5s — last seen 01:58:40 — unreachable — '
  expect_frame_count_of 3 'example\.slot-' 0
}

# `c`: one line per host, with that host's own counts and what its Disk line
# says — and exactly one, however many lines the host had. A key on a folded
# host acts on nothing and reads nothing. Enter opens the host the cursor is
# on (and only it), and `c` there folds it again.
case_fleet_watch_collapse_is_one_line_per_host() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS=$'cKj\ncq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_STALL="build-2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 6
  expect_frame_line 2 1 "$(view_hdr ' — view: collapsed')"
  expect_frame_line 2 2 "^${SUM_MIX}\$"
  expect_frame_line 2 3 '^HOST +IDX +RUNNER '
  expect_frame_line 2 4 "^${REV}build-1 +3 slots: 1 busy, 1 idle, 1 disabled · $V_DISK$ESC\[0m\$"
  expect_frame_line 2 5 "^build-2 +3 slots: 1 idle, 1 STALLED, 1 disabled · $V_DISK\$"
  expect_frame_count_of 2 "^(${REV})?build-1 " 1
  expect_frame_count_of 2 "^(${REV})?build-2 " 1
  expect_no_frame 2 'example\.slot-'
  expect_frame 3 '^build-1: folded to one line — c or Enter opens it, then pick a slot$'
  expect_frame_line 4 5 "^${REV}build-2 +3 slots: "
  # Enter: build-2 open — its Disk line and three rows — build-1 still one line
  expect_frame_line 5 4 "^build-1 +3 slots: 1 busy, 1 idle, 1 disabled · "
  expect_frame_line 5 5 "^build-2 +$V_DISK\$"
  expect_frame_line 5 6 "$(fw_row build-2 0 1)"
  expect_frame_count_of 5 "$V_ROW" 3
  expect_frame_count_of 5 "^(${REV})?build-1 " 1
  # c on it: folded again
  expect_frame_line 6 5 "^${REV}build-2 +3 slots: "
  expect_frame_count_of 6 "^(${REV})?build-[12] " 2
  expect_log_count '^probe:tty_read_char 5 \$.\\n.$' 1
  expect_log_count '^probe:ssh_run ' 4
  expect_no_out '\[y/n\]'
}

# A view that shows nothing says so, and says the way out. Nothing is selected
# there, so a key acts on nothing; `a` puts the fleet back with the cursor
# where it was.
case_fleet_watch_an_empty_view_prints_the_hint() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='!Kaq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 4
  expect_frame_line 2 1 "$(view_hdr ' — view: problems only')"
  expect_frame_line 2 2 "^${SUM_OK}\$"
  expect_frame_line 2 3 '^HOST +IDX +RUNNER '
  expect_frame_line 2 4 '^nothing matches — a shows all$'
  expect_frame_count_of 2 "^${REV}" 0
  expect_frame_count_of 2 '^build-' 0
  expect_frame 3 '^no slot to act on$'
  expect_frame_line 4 1 "$(view_hdr '')"
  expect_frame_count_of 4 "$V_ROW" 6
  expect_frame 4 "$(fw_row build-1 0 1)"
  expect_log_count '^probe:ssh_run ' 4
}

# An action key under a view acts on the row the cursor is ON. Each run is
# hostile to a cursor that indexed the unfiltered frame instead: the row the
# view has at the cursor's position is not the row the fleet has there.
#   b j    busy only is build-1/slot-1, build-2/slot-1; the second row of the
#          FLEET is build-1/slot-2
#   i      idle only starts on build-1/slot-2; the first row of the fleet is
#          build-1/slot-1
#   s j j  longest job first is build-1/slot-1, build-2/slot-1, build-1/slot-2;
#          the third row of the fleet is build-1/slot-3
case_fleet_watch_an_action_key_under_a_view_acts_on_the_cursor_row() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='bjRyq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_line 3 1 "$(view_hdr ' — view: busy only')"
  expect_frame_line 3 7 "$(fw_row build-2 0 1)"
  expect_out_count '^Restart example\.slot-1 on build-2\? runs on build-2: runnerctl restart example\.slot-1  \[y/n\]$' 1
  expect_log_count '^probe:ssh_run build-2 -- runnerctl restart example\.slot-1$' 1
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl (stop|start|restart|kill|reap) ' 1
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='iRyq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_line 2 5 "$(fw_row build-1 1 2)"
  expect_out_count '^Restart example\.slot-2 on build-1\? runs on build-1: runnerctl restart example\.slot-2  \[y/n\]$' 1
  expect_log_count '^probe:ssh_run build-1 -- runnerctl restart example\.slot-2$' 1
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl (stop|start|restart|kill|reap) ' 1
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='sjjRyq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_line 4 6 "$(fw_row build-1 1 2)"
  expect_log_count '^probe:ssh_run build-1 -- runnerctl restart example\.slot-2$' 1
  expect_log_count '^probe:ssh_run [^ ]+ -- runnerctl (stop|start|restart|kill|reap) ' 1
}

# The summary and the views read ONE classification, and both sides are pinned
# to literals — two surfaces that merely agree could be wrong together. The
# summary says 1 busy, 2 idle, 1 STALLED, 2 disabled: so busy-only is the busy
# slot and the stalled one, idle-only the two idle ones, and each folded host
# carries its own share of those counts.
case_fleet_watch_views_count_what_the_summary_counts() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='bicq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    RUNNERCTL_STUB_FLEET_STALL="build-2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 4
  expect_under_header "$SUM_MIX" 4
  expect_frame_count_of 2 "$V_ROW" 2
  expect_frame_line 2 5 "$(fw_row build-1 0 1)"
  expect_frame_line 2 7 '^build-2 +0 +example\.slot-1 .* STALLED$'
  expect_frame_line 3 1 "$(view_hdr ' — view: idle only')"
  expect_frame_count_of 3 "$V_ROW" 2
  expect_frame_line 3 5 "$(fw_row build-1 1 2)"
  expect_frame_line 3 7 '^build-2 +1 +example\.slot-2 '
  expect_frame_line 4 1 "$(view_hdr ' — view: idle only · collapsed')"
  expect_frame_line 4 4 "^${REV}build-1 +3 slots: 1 busy, 1 idle, 1 disabled · "
  expect_frame_line 4 5 "^build-2 +3 slots: 1 idle, 1 STALLED, 1 disabled · "
  expect_log_count '^probe:ssh_run ' 4
}

# What a problem IS, pinned on the classifier itself — one `status --json`
# slot line per state the stub's fleet cannot be put in from outside. At
# MemoryHigh and at PRESSURE_CRIT_PCT (50) are problems, one byte and one
# hundredth below are not; a slot switched off on purpose is not, one that is
# merely not active is; a job that has not said its name yet is busy.
case_fleet_slot_classify_says_what_a_problem_is() {
  local f="$TMP/ghr75.slots" tail=',"idle_since":null,"jobs_completed":null,"working_on_access":"ok"'
  local up='"active":"active","sub":"running","enabled":"enabled"' job='"job":{"repo":"my-app","name":"test","since":500,"stalled":false}'
  {
    echo "  {\"idx\":0,\"unit\":\"u\",\"name\":\"busy\",$up,\"memory_high\":100,\"memory_current\":99,$job$tail,\"leaked_procs\":null,\"memory_pressure\":{\"full_avg10\":49.99,\"full_avg60\":1.00,\"full_total\":5}}"
    echo "  {\"idx\":1,\"unit\":\"u\",\"name\":\"stalled\",$up,\"memory_high\":100,\"memory_current\":1,${job/false/true}$tail,\"leaked_procs\":null,\"memory_pressure\":null}"
    echo "  {\"idx\":2,\"unit\":\"u\",\"name\":\"idle\",$up,\"memory_high\":null,\"memory_current\":null,\"job\":null$tail,\"leaked_procs\":0,\"memory_pressure\":null}"
    echo "  {\"idx\":3,\"unit\":\"u\",\"name\":\"leaky\",$up,\"memory_high\":100,\"memory_current\":1,\"job\":null$tail,\"leaked_procs\":2,\"memory_pressure\":null}"
    echo "  {\"idx\":4,\"unit\":\"u\",\"name\":\"at-high\",$up,\"memory_high\":100,\"memory_current\":100,$job$tail,\"leaked_procs\":null,\"memory_pressure\":{\"full_avg10\":0.00,\"full_avg60\":0.00,\"full_total\":0}}"
    echo "  {\"idx\":5,\"unit\":\"u\",\"name\":\"pressed\",$up,\"memory_high\":100,\"memory_current\":1,$job$tail,\"leaked_procs\":null,\"memory_pressure\":{\"full_avg10\":50.00,\"full_avg60\":1.00,\"full_total\":5}}"
    echo "  {\"idx\":6,\"unit\":\"u\",\"name\":\"off\",\"active\":\"inactive\",\"sub\":\"dead\",\"enabled\":\"disabled\",\"memory_high\":null,\"memory_current\":null,\"job\":null$tail,\"leaked_procs\":null,\"memory_pressure\":null}"
    echo "  {\"idx\":7,\"unit\":\"u\",\"name\":\"stopped\",\"active\":\"inactive\",\"sub\":\"dead\",\"enabled\":\"enabled\",\"memory_high\":null,\"memory_current\":null,\"job\":null$tail,\"leaked_procs\":null,\"memory_pressure\":null}"
    echo "  {\"idx\":8,\"unit\":\"u\",\"name\":\"restarting\",\"active\":\"activating\",\"sub\":\"auto-restart\",\"enabled\":\"enabled\",\"memory_high\":null,\"memory_current\":null,\"job\":null$tail,\"leaked_procs\":null,\"memory_pressure\":null}"
    echo "  {\"idx\":9,\"unit\":\"u\",\"name\":\"starting\",$up,\"memory_high\":100,\"memory_current\":1,\"job\":{\"repo\":null,\"name\":null,\"since\":null,\"stalled\":false}$tail,\"leaked_procs\":null,\"memory_pressure\":null}"
  } >"$f"
  # shellcheck disable=SC2016
  GHR75_F="$f" run_fn eval 'while IFS= read -r l; do fleet_slot_classify "$l"; echo "$SC_NAME state=$SC_STATE leaking=$SC_LEAKING problem=$SC_PROBLEM since=$SC_SINCE mem=$SC_MEM job=$SC_JOB"; done <"$GHR75_F"'
  expect_rc 0
  expect_text "the classification of each slot" "busy state=busy leaking=false problem=false since=500 mem=99 job=my-app:test
stalled state=stalled leaking=false problem=true since=500 mem=1 job=my-app:test
idle state=idle leaking=false problem=false since= mem= job=
leaky state=idle leaking=true problem=true since= mem=1 job=
at-high state=busy leaking=false problem=true since=500 mem=100 job=my-app:test
pressed state=busy leaking=false problem=true since=500 mem=1 job=my-app:test
off state=disabled leaking=false problem=false since= mem= job=
stopped state=down leaking=false problem=true since= mem= job=
restarting state=down leaking=false problem=true since= mem= job=
starting state=busy leaking=false problem=false since= mem=1 job=" "$OUT"
  rm -f "$f"
}

# `s` cycles config order → longest job first → most memory first → config.
# A sorted table is a flat list with the host lines under the rows; the stub's
# two hosts are identical, so the frames here show the SHAPE and that a tie
# keeps config order. `--sort` starts a watch in an order; a value it does not
# know dies before anything is dialled.
case_fleet_watch_sort_cycles_and_flattens_the_table() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='sssq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 4
  expect_frame_line 2 1 "$(view_hdr ' — view: longest job first')"
  expect_frame_line 2 3 '^HOST +IDX +RUNNER '
  expect_frame_line 2 4 "$(fw_row build-1 0 1)"
  expect_frame_line 2 5 '^build-2 +0 +example\.slot-1 '
  expect_frame_line 2 6 '^build-1 +1 +example\.slot-2 '
  expect_frame_line 2 7 '^build-1 +2 +example\.slot-3 '
  expect_frame_line 2 8 '^build-2 +1 +example\.slot-2 '
  expect_frame_line 2 9 '^build-2 +2 +example\.slot-3 '
  expect_frame_line 2 10 "^build-1 +$V_DISK\$"
  expect_frame_line 2 11 "^build-2 +$V_DISK\$"
  expect_frame_line 3 1 "$(view_hdr ' — view: most memory first')"
  expect_frame_line 3 4 "$(fw_row build-1 0 1)"
  expect_frame_line 3 5 '^build-1 +1 +example\.slot-2 '
  expect_frame_line 3 6 '^build-2 +0 +example\.slot-1 '
  expect_frame_line 3 7 '^build-2 +1 +example\.slot-2 '
  expect_frame_line 3 8 '^build-1 +2 +example\.slot-3 '
  expect_frame_line 3 9 '^build-2 +2 +example\.slot-3 '
  expect_frame_line 4 1 "$(view_hdr '')"
  expect_frame_line 4 4 "^build-1 +$V_DISK\$"
  expect_frame_line 4 8 "^build-2 +$V_DISK\$"
  expect_log_count '^probe:ssh_run ' 4
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet watch --sort job --iterations 1 --color never
  expect_rc 0
  expect_out_count "${FRAME_PREFIX}runnerctl fleet watch — 2 host\(s\) — [0-9:]{8} — every 5s \(q to quit\) — view: longest job first\$" 1
  expect_out_count '^build-[12] +0 +example\.slot-1 ' 2
  _expect
  [ "$(grep -n -E '^build-2 +0 +example' <<<"$OUT" | cut -d: -f1; true)" -lt "$(grep -n -E '^build-1 +1 +example' <<<"$OUT" | cut -d: -f1; true)" ] \
    || FAILS+=("--sort job: build-2's slot-1 is not above build-1's slot-2")
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet watch --sort=mem --problems --iterations 1 --color never
  expect_rc 0
  expect_out ' — view: problems only · most memory first$'
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet watch --sort age
  expect_rc 1
  expect_err "^runnerctl: --sort value 'age' is invalid — want config \(the hosts' own order\), job \(longest-running job first\) or mem \(most memory used first\)\$"
  expect_no_log '^probe:ssh_run '
}

# The ORDER, on facts that differ — which the stub's identical hosts cannot
# show. fleet_watch_view on a frame and two payloads written here: jobs
# started at 900 (a/young), 100 (b/old) and 500 (b/mid), and memory of 5, 50,
# none, 7 and 7. Longest job first is by start, the two without a job after in
# config order; most memory first puts the 7/7 tie in config order and the
# slot without accounting last. Config order is the frame untouched.
case_fleet_watch_sort_orders_by_the_hosts_own_facts() {
  local d="$TMP/ghr75-sort" s
  rm -rf "$d"; mkdir -p "$d"
  s() { # IDX NAME MEM JOB
    echo "  {\"idx\":$1,\"unit\":\"u\",\"name\":\"$2\",\"active\":\"active\",\"sub\":\"running\",\"enabled\":\"enabled\",\"memory_high\":null,\"memory_current\":$3,\"job\":$4,\"idle_since\":null,\"jobs_completed\":null,\"working_on_access\":\"ok\",\"leaked_procs\":null,\"memory_pressure\":null}"
  }
  {
    echo '{"runnerctl":"1.0.0","host":{"name":"a","disks":[],"events":{"oom_kills":0,"disk_full":0}},'
    s 0 young 5 '{"repo":"r","name":"j","since":900,"stalled":false}'
    s 1 fat-idle 50 null
    s 2 nomem null null
  } >"$d/0.json"
  {
    echo '{"runnerctl":"1.0.0","host":{"name":"b","disks":[],"events":{"oom_kills":0,"disk_full":0}},'
    s 0 old 7 '{"repo":"r","name":"j","since":100,"stalled":false}'
    s 1 mid 7 '{"repo":"r","name":"j","since":500,"stalled":false}'
  } >"$d/1.json"
  unset -f s
  # shellcheck disable=SC2016
  GHR75_DIR="$d" run_fn eval '
    color_setup never
    FLEET_HOSTS=(a b) FW_STATE="$GHR75_DIR"
    frame="HOST IDX RUNNER
a    Disk: / 10% (1.0G free)
a    0   young
a    1   fat-idle
a    2   nomem
b    0   old
b    1   mid
note: a note"
    for FW_SORT in config job mem; do
      FW_FACTS_OK=false
      fleet_watch_view "$frame"
      echo "== $FW_SORT"
      echo "$FW_VIEW"
      echo "rows:$(printf " %s" "${FW_ROWS[@]}" | tr "\t" ":")"
      echo "lines: ${FW_LINES[*]}"
    done
  '
  expect_rc 0
  expect_text "the three orders" "== config
HOST IDX RUNNER
a    Disk: / 10% (1.0G free)
a    0   young
a    1   fat-idle
a    2   nomem
b    0   old
b    1   mid
note: a note
rows: a:young a:fat-idle a:nomem b:old b:mid
lines: 3 4 5 6 7
== job
HOST IDX RUNNER
b    0   old
b    1   mid
a    0   young
a    1   fat-idle
a    2   nomem
a    Disk: / 10% (1.0G free)
note: a note
rows: b:old b:mid a:young a:fat-idle a:nomem
lines: 2 3 4 5 6
== mem
HOST IDX RUNNER
a    1   fat-idle
b    0   old
b    1   mid
a    0   young
a    2   nomem
a    Disk: / 10% (1.0G free)
note: a note
rows: a:fat-idle b:old b:mid a:young a:nomem
lines: 2 3 4 5 6" "$OUT"
  rm -rf "$d"
}

# `/`: the text filters as it is typed, on host, runner or repo:job, whatever
# its case. Each character arrives through the watch's own key read — the one
# with the interval as its timeout, logged below — so typing holds up neither
# a tick nor a resize; the status line shows the text and the way out. Enter
# keeps it and the header names it; Backspace takes a character; a `q` typed
# there is text; Esc puts back what was there before; and none of it asks a
# host anything.
#
# No text here has a `-` in it: in RUNNERCTL_STUB_KEYS that is a tick, not a
# character. So the runner is matched by its digit and the host by `2`.
case_fleet_watch_slash_filters_by_text_as_it_is_typed() {
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS=$'/3x\x7f\nq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 6
  # frame 2: the prompt, nothing typed, nothing hidden
  expect_frame_line 2 1 "$(view_hdr '')"
  expect_frame_count_of 2 "$V_ROW" 6
  expect_frame 2 '^filter: /_ — Enter keeps it, Esc cancels, an empty one matches everything$'
  # frame 3: `3`, already filtering — the two slot-3 rows
  expect_frame_line 3 1 "$(view_hdr ' — view: matching "3"')"
  expect_frame_count_of 3 "$V_ROW" 2
  expect_frame 3 '^filter: /3_ — '
  # frame 4: `3x` matches nothing; frame 5: Backspace, and they are back
  expect_frame_line 4 4 '^nothing matches — a shows all$'
  expect_frame 4 '^filter: /3x_ — '
  expect_frame_count_of 5 "$V_ROW" 2
  # frame 6: Enter — under their host lines, the prompt gone, the name kept
  expect_frame_line 6 1 "$(view_hdr ' — view: matching "3"')"
  expect_frame_line 6 4 "^build-1 +$V_DISK\$"
  expect_frame_line 6 5 "$(fw_row build-1 2 3)"
  expect_frame_line 6 6 "^build-2 +$V_DISK\$"
  expect_frame_line 6 7 '^build-2 +2 +example\.slot-3 '
  expect_no_frame 6 '^filter: '
  expect_log_count '^probe:tty_read_char 5 3$' 1
  expect_log_count '^probe:tty_read_char 5 ' 6
  expect_log_count '^probe:ssh_run ' 4
  # repo:job whatever its case; q is text; Esc puts the old text back; Ctrl-U
  # empties it; the host matches too, and the text is ANDed with b
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS=$'/APP:T\n/q\e-/\x152\nbq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 16
  expect_frame_line 8 1 "$(view_hdr ' — view: matching "APP:T"')"
  expect_frame_count_of 8 "$V_ROW" 2
  expect_frame_line 8 5 "$(fw_row build-1 0 1)"
  expect_frame_line 8 7 '^build-2 +0 +example\.slot-1 '
  expect_frame_line 10 1 "$(view_hdr ' — view: matching "APP:Tq"')"
  expect_frame_line 10 4 '^nothing matches — a shows all$'
  expect_frame_line 11 1 "$(view_hdr ' — view: matching "APP:T"')"
  expect_frame_count_of 11 "$V_ROW" 2
  expect_no_frame 11 '^filter: '
  expect_frame_line 13 1 "$(view_hdr '')"
  expect_frame_count_of 13 "$V_ROW" 6
  # `2`: all of build-2 by its host name, and build-1's slot-2 by its own
  expect_frame_line 15 1 "$(view_hdr ' — view: matching "2"')"
  expect_frame_count_of 15 "$V_ROW" 4
  expect_frame_count_of 15 "^(${REV})?build-2 +[0-9]+ +example" 3
  expect_frame_count_of 15 "^(${REV})?build-1 +1 +example\.slot-2 " 1
  expect_frame_line 16 1 "$(view_hdr ' — view: busy only · matching "2"')"
  expect_frame_count_of 16 "$V_ROW" 1
  expect_frame 16 '^(.\[7m)?build-2 +0 +example\.slot-1 '
  expect_log_count '^probe:ssh_run ' 4
}

# `?`: every key, where the table was, between the same header, summary and
# status line — and gone on any key, which is spent closing it: the `j` moves
# nothing and a `q` there does not quit. No host is asked anything.
case_fleet_watch_question_mark_lists_every_key() {
  local k
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_KEYS='?j?qq' RUNNERCTL_STUB_FLEET_HOSTS="$FW2" \
    run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 5
  for k in 2 4; do
    expect_frame_line "$k" 1 "$(view_hdr '')"
    expect_frame_line "$k" 2 "^${SUM_OK}\$"
    expect_frame_line "$k" 3 '^fleet watch — keys$'
    expect_frame "$k" '^any key closes this list$'
    expect_frame_count_of "$k" '^HOST +IDX|example\.slot-' 0
  done
  # a line per key, and the list short enough for a 24-row terminal: its 13
  # lines, the header, the summary and the three lines under it
  for k in '!' 'b i' '/' 'a' 's' 'c' 'K R S T P L' '\?' 'q' '↑ ↓ j k   PgUp PgDn   g G Home End'; do
    expect_frame 2 "^  $k   +[a-z]"
  done
  expect_frame_lines 2 19
  expect_frame 3 "$(fw_row build-1 0 1)"
  expect_frame 5 "$(fw_row build-1 0 1)"
  expect_frame_count_of 3 "$V_ROW" 6
  expect_log_count '^probe:ssh_run ' 4
}

# A view goes through the viewport like any frame (GHR-73): two hosts of nine
# slots, idle only — fourteen rows and two host lines on a ten-row terminal.
# Every frame is exactly ten lines with one cursor row in it, G and PgUp move
# over the rows the VIEW has, and the markers count the view's lines.
case_fleet_watch_a_view_is_fitted_and_paged_like_any_frame() {
  local f
  RUNNERCTL_STUB_TTY=1 RUNNERCTL_STUB_LINES=10 RUNNERCTL_STUB_SLOTS=9 RUNNERCTL_STUB_KEYS=$'iG\e[5~g-q' \
    RUNNERCTL_STUB_FLEET_HOSTS="$FW2" run fleet watch --color never
  expect_rc 0
  frames
  expect_frame_count 6
  for f in 2 3 4 5; do
    expect_frame_lines "$f" 10
    expect_frame_line "$f" 1 "$(view_hdr ' — view: idle only')"
    expect_frame_line "$f" 3 '^HOST +IDX +RUNNER '
    expect_frame_line "$f" 9 "$V_LEGEND"
    expect_frame_count_of "$f" "^${REV}" 1
    expect_frame_count_of "$f" 'my-app:test|example\.slot-3 ' 0
  done
  # i: the cursor's own slot is gone, so its host's first idle one
  expect_frame_line 2 4 "^build-1 +$V_DISK\$"
  expect_frame_line 2 5 "$(fw_row build-1 1 2)"
  expect_frame_line 2 7 "$(down_mark 13)"
  # G: the last row of the view
  expect_frame_line 3 4 "$(up_mark 13)"
  expect_frame_line 3 7 "$(fw_row build-2 8 9)"
  # PgUp, then g: back to the first
  expect_frame 4 "$(fw_row build-2 6 7)"
  expect_frame_line 5 5 "$(fw_row build-1 1 2)"
}

t "status: header and one row per discovered slot"                case_status_table
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
# GHR-58: --save writes the applied profile back into the config
t "apply --save: appends where the config names no such profile"   case_save_appends_when_the_config_names_no_such_profile
t "apply --save: replaces the block; a later apply reads it back"  case_save_replaces_the_block_and_the_next_apply_reads_it_back
t "apply --save: a profile's ENV_TEMPLATE survives the rewrite"    case_save_keeps_a_profiles_env_template
t "apply --save: refuses a block it cannot rewrite; drop-ins kept" case_save_refuses_a_block_it_cannot_rewrite
t "apply --save: refuses two definitions of one profile"           case_save_refuses_two_definitions_of_one_profile
t "apply --save: refuses a profile with logic in it"               case_save_refuses_a_profile_with_logic_in_it
t "apply --save: creates a config that does not exist yet, 644"    case_save_creates_a_config_that_does_not_exist
t "apply --save: a candidate that would not re-render is refused"  case_save_refuses_a_candidate_that_would_not_re_render
t "apply without --save: the config is not touched"                case_apply_without_save_leaves_the_config_alone
t "scale --save: saves the profile it scaled with"                 case_scale_save_writes_the_profile_it_scaled_with
t "upgrade --ref: missing value dies before any download"          case_upgrade_ref_missing_value
t "resolve_url: no ref leaves UPGRADE_URL unchanged"                case_resolve_url_no_ref_unchanged
t "resolve_url: release URL + vX.Y.Z maps to that release asset"    case_resolve_url_release_version_ref
t "resolve_url: release URL + X.Y.Z normalises to vX.Y.Z"           case_resolve_url_release_version_ref_normalised
t "resolve_url: release URL + branch ref falls back to raw URL"     case_resolve_url_release_branch_ref_falls_back_to_raw
t "resolve_url: raw URL + ref replaces the ref segment"              case_resolve_url_raw_url_ref_replaces_segment
t "resolve_url: unsupported UPGRADE_URL + ref dies"                  case_resolve_url_unsupported_url_dies
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
t "watch --interval 0: rejected, nothing rendered"                   case_watch_interval_zero_rejected
t "watch --interval abc: not an integer"                             case_watch_interval_non_integer_rejected
t "watch: refuses a non-tty stdout, points at status"                case_watch_refuses_non_tty
t "status -w / --watch: reach the watch path"                        case_status_w_is_the_watch_alias
t "status --once: plain status, journal not memoised"                case_status_once_is_plain_status
t "watch --iterations 3 --interval 1: three atomic frames, 3 pauses" case_watch_three_iterations_redraw_frames
t "watch --iterations 12: journal read at tick 0 and 10 only"         case_watch_journal_memo_refreshes_every_ten_ticks
t "watch: a memoised journal failure holds for the TTL"              case_watch_memo_keeps_journal_failure
t "watch --bogus / status --interval: unknown option"                case_watch_unknown_option_rejected

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

# --- GHR-16: status --json ---------------------------------------------------
t "status --json: parses, host + 3 slots with the raw facts"           case_status_json_parses_and_carries_the_slot_facts
t "status --json: host.name null when the host cannot be named"        case_status_json_host_name_null_when_unreadable
t "status: fixed drives and journal events on the header line"         case_status_host_disks_and_events
t "status --color always: a drive past WARN/CRIT and the events painted" case_status_host_disks_color
t "status: an unreadable journal adds no event count"                    case_status_host_events_no_access
t "status: EVENTS_SEC=0 turns the journal search off"                    case_status_host_events_off
t "status: DISK_IGNORE leaves a mount out"                               case_status_disk_ignore
t "status: DISK_PATHS labels, shares a row, skips a missing path"      case_status_disk_paths_labelled
t "status: / [root] when no watched path resolves"                       case_status_disk_falls_back_to_root
t "status --json: host.disks and host.events"                            case_status_json_host_disks_events
t "status --json: host.events null when the journal is unreadable"       case_status_json_host_events_null
t "health: a full drive, a host OOM kill and a disk-full line"           case_health_host_problems
t "health: a quiet host adds no problem"                                 case_health_host_ok
t "host_events_parse: global vs cgroup OOM, last process and source"     case_host_events_parse
t "status --json: no runner units is slots:[] and exit 0, not a die"   case_status_json_no_units_is_empty_slots_not_a_die
t "status: the table still dies on a host with no runner units"        case_status_table_no_units_still_dies
t "status --json: same unit_props / journal fetches as the table"      case_status_json_same_fetches_as_the_table
t "status --json: profile from a seeded drop-in"                       case_status_json_profile_from_dropin
t "status --json: working_on_access per slot, no note line"            case_status_json_working_on_access_states
t "status --json: idle with no jobs yet counts from the unit's start"  case_status_json_idle_fresh_counts_from_unit_start
t "status --json --watch / watch --json: refused"                      case_status_json_refuses_watch
t "json_str: escapes backslash, quote, newline, control chars"         case_json_str_escapes

# --- GHR-26: journal fetch filters with -g ------------------------------------
t "journal_job_args: -g with the job pattern, invocation scope, no -n"  case_journal_job_args_use_grep_not_a_window
t "journal_job_args: no invocation id -> no scope argument"             case_journal_job_args_without_invocation_id
t "status --stall-after 600: a 12m job is STALLED, note once"          case_status_stall_after_flags_slot1
t "status --stall-after: = form, and the threshold is inclusive"       case_status_stall_after_equals_form_and_boundary
t "status --stall-after 0: the flag is off"                            case_status_stall_after_zero_disables
t "status --stall-after soon: rejected, missing value dies"            case_status_stall_after_invalid_rejected
t "status --json: job.stalled true/false/null, never the marker"       case_status_json_stalled_field
t "health --stall-after 600: a stalled job is a problem, exit 1"       case_health_stalled_job_is_a_problem
t "health: the default threshold ignores a 12m job"                    case_health_default_threshold_ignores_a_12m_job
t "health: reads collect_slot — the table's fetches, no more"          case_health_reads_the_shared_collector
t "health --stall-after 6h: rejected"                                  case_health_stall_after_invalid_rejected
t "watch --stall-after 600: STALLED in every frame"                    case_watch_stalled_marker_in_frames
t "status --color always: cells painted by meaning, columns aligned"   case_status_color_always_paints_by_meaning
t "status --color: auto = tty and NO_COLOR unset; never wins"          case_status_color_never_and_default_are_plain
t "status --color sometimes: rejected, missing value dies"             case_status_color_invalid_rejected
t "status --json: never painted, even with --color always"             case_status_json_never_paints
t "health: never painted"                                              case_health_never_paints
t "watch --color=always: bold header, painted rows, via status -w too" case_watch_color_always_paints_header_and_frames
t "status_used_color: plain, yellow at 90 %, red at MemoryHigh"        case_status_used_color_thresholds

# --- GHR-14: health command for cron/uptime probes --------------------------
t "health: default stub is healthy, read-only, no privileged call"    case_health_default_stub_is_healthy
t "health --max-restarts 3: slot-2's 3 restarts trip it (oom-kill)"   case_health_max_restarts_below_default_flags_slot2
t "health: an enabled-but-dead slot is a problem"                      case_health_enabled_but_dead_slot_is_a_problem
t "health --quiet: no stdout either way, exit code kept"               case_health_quiet_suppresses_output_keeps_exit_code
t "health --bogus: unknown option dies"                                case_health_unknown_option_dies
t "health --max-restarts: missing value dies"                          case_health_max_restarts_missing_value_dies

# --- GHR-29: leaked processes and reap ---------------------------------------
t "status: idle slot with leaks shows +N leaked, note once, busy slot not walked" case_status_leaked_suffix_and_note
t "status: no leaks / unreadable cgroup: no suffix, no note"           case_status_no_leaks_no_suffix
t "status --color always: a leaking idle cell and its note are yellow" case_status_leaked_painted_yellow
t "status --json: leaked_procs 2 on the idle slot, null elsewhere"     case_status_json_leaked_procs
t "health: leaked processes are a problem naming the reap command"     case_health_leaked_is_a_problem
t "reap: TERM all, pause, KILL the survivor; busy and stopped slots skipped" case_reap_term_pause_kill_order
t "reap 1: no survivors, no SIGKILL"                                   case_reap_everything_dies_on_term
t "reap --dry-run: lists, sends nothing"                                case_reap_dry_run_makes_no_call
t "reap 0: a busy slot is skipped, never signalled"                     case_reap_busy_slot_is_skipped_not_killed
t "reap 1: clean slot says nothing to reap"                             case_reap_nothing_to_reap
t "reap 1: unreadable cgroup / no journal die with a hint"              case_reap_unreadable_cgroup_dies
t "reap --bogus / reap nope: rejected"                                  case_reap_unknown_option_and_bad_target

# --- GHR-36: kill the job, not the runner ------------------------------------
t "kill <slot>: SIGKILL the job tree, runner untouched, no systemctl"   case_kill_sigkills_the_job_tree_and_leaves_the_runner
t "kill: job survives the grace — escalates to systemctl kill -s KILL"  case_kill_escalates_to_the_unit_when_the_job_survives
t "kill: a deactivating slot goes straight to the unit kill"            case_kill_deactivating_slot_goes_straight_to_the_unit
t "kill: unreadable cgroup hands the unit to systemd"                   case_kill_unreadable_cgroup_uses_systemd
t "kill --dry-run: lists, sends nothing (both paths)"                   case_kill_dry_run_sends_nothing
t "kill: idle, stopped and no-journal slots refuse before acting"       case_kill_without_a_running_job_is_refused
t "kill: a bare kill needs a target; bad option and bad target"         case_kill_needs_a_target
t "kill --if-stalled: the stalled slot only, threshold rules"           case_kill_if_stalled_takes_only_the_stalled_slot
t "kill: KILL_GRACE_SEC default 10, both knobs in config-example"       case_kill_grace_default_and_config_example

# --- GHR-30: 1 h stall default, --if-stalled, health --restart-stalled -------
t "STALL_SEC defaults to 3600, config-example agrees"                   case_stall_sec_default_is_one_hour
t "restart --if-stalled --stall-after 600: slot-1 only, others skipped"  case_restart_if_stalled_restarts_only_the_stalled_slot
t "restart --if-stalled: default 1 h ignores a 12m job, no call"        case_restart_if_stalled_default_threshold_restarts_nothing
t "stop 0 2 --if-stalled --stall-after=600: stop slot-1 only"           case_stop_if_stalled_targets_and_equals_form
t "--if-stalled: refuses --when-idle, start, and a 0 threshold"         case_if_stalled_refuses_when_idle_start_and_zero_threshold
t "restart --if-stalled: (no access) dies before any call"              case_if_stalled_no_access_dies_before_acting
t "health --restart-stalled: restarts the stalled slot, says so, exit 1" case_health_restart_stalled_restarts_and_says_so
t "health --restart-stalled: healthy pool, no privileged call"          case_health_restart_stalled_healthy_pool_touches_nothing
t "health --restart-stalled: a failed restart is reported"              case_health_restart_stalled_reports_a_failed_restart
t "health --stall-after 600 alone: reports, never restarts"             case_health_without_restart_stalled_never_restarts

# --- GHR-31: memory pressure column, memory.events, health rule --------------
t "status: PRESS column from the cgroup's PSI, one read per slot"       case_status_press_column_from_the_stub
t "status --color always: PRESS red at 63 %, plain at 0 %"              case_status_press_painted_by_threshold
t "status_press_color / status_press_cell: thresholds and formatting"   case_status_press_color_thresholds
t "status --json: memory_events and memory_pressure objects, null when unreadable" case_status_json_memory_events_and_pressure
t "health: full memory pressure over PRESSURE_CRIT_PCT is a problem"    case_health_pressure_over_crit_is_a_problem
t "health: a stalled line under pressure says throttled, not hung"      case_health_stalled_line_says_throttled_when_under_pressure
t "pressure_at_least: inclusive at the threshold, never on unknown"   case_pressure_at_least_boundary_is_inclusive
t "status --stall-after 600: the STALLED note points at PRESS"          case_status_stalled_note_mentions_press

# --- GHR-33: interactive watch ------------------------------------------------
t "watch: j/k and the arrows move the cursor, a key redraws at once"     case_watch_keys_move_the_cursor
t "watch: the cursor clamps at both ends and survives a tick"           case_watch_cursor_clamps_and_survives_a_tick
t "watch: K, y — confirm names the job's pids, kills them, notice"       case_watch_K_kills_the_running_job_after_confirm
t "watch: K on a deactivating slot names systemctl kill -s KILL"        case_watch_K_on_a_deactivating_slot_names_the_unit_kill
t "watch: K, n — cancelled, nothing run; q at a confirm cancels too"    case_watch_confirm_n_runs_nothing
t "watch: K refused on an idle, stopped or (no access) row"             case_watch_K_refused_without_a_running_job
t "watch: R restarts, warning line only when a job is in flight"        case_watch_R_restarts_with_a_warning_when_busy
t "watch: S stops an active slot, T starts a stopped one, no-ops refuse" case_watch_S_stops_and_T_starts
t "watch: P reaps the idle slot's leaks via cmd_reap, refused elsewhere" case_watch_P_reaps_leaked_processes
t "watch: L pages logs <slot> -n 50, no confirm"                        case_watch_L_pages_the_slot_logs
t "watch: q/Q quits, cursor restored; a lone Escape is not a key"       case_watch_q_quits
t "watch --iterations: headless, reads no keys, no cursor, no legend"   case_watch_iterations_reads_no_keys
t "watch: the non-tty refusal reads no keys"                            case_watch_non_tty_refusal_reads_no_keys
t "watch: a narrow terminal drops MAX/HIGH/ENVFILE, never WORKING-ON"   case_watch_narrow_terminal_drops_max_high_envfile
t "watch --color always: the cursor row stays highlighted end to end"   case_watch_color_always_keeps_the_cursor_row_highlighted

# --- GHR-39: fleet mode -------------------------------------------------------
t "fleet status: one HOST-prefixed table, column header once"          case_fleet_status_table_one_header_rows_per_host
t "fleet status: an unreachable host is a row, the rest still report"  case_fleet_status_unreachable_host_is_a_row_not_a_fatal
t "fleet status: timeout, remote error and unreachable stay distinct"  case_fleet_status_tells_timeout_remote_error_and_unreachable_apart
t "fleet status: a version mismatch adds the skew note, level does not" case_fleet_status_version_skew_note
t "fleet status: a host that cannot run runnerctl is told how to fix it" case_fleet_status_names_the_fix_for_a_host_that_cannot_run_runnerctl
t "fleet status --json: the bootstrap remedy rides in the envelope"     case_fleet_status_json_carries_the_bootstrap_remedy
t "fleet health: a bootstrap failure carries its remedy too"            case_fleet_health_carries_the_bootstrap_remedy
t "fleet: a sudo-wrapped missing runnerctl reads as a PATH fault"       case_fleet_a_sudo_wrapped_missing_runnerctl_is_a_path_fault_not_a_sudo_one
t "fleet status --json: each host's payload nested unchanged"          case_fleet_status_json_nests_each_payload_unchanged
t "fleet status --json: exit 0 with no object is an explained error"   case_fleet_status_json_rejects_a_non_object_payload
t "fleet status: --stall-after is forwarded to the remote table"       case_fleet_status_forwards_stall_after_to_the_remote_table
t "fleet status --json: --stall-after is forwarded too"                case_fleet_status_json_forwards_stall_after_to_the_remote
t "fleet health: all healthy is one summary line, exit 0"              case_fleet_health_all_healthy_is_one_line_exit_zero
t "fleet health: a problem keeps its wording and gains its host"       case_fleet_health_problem_is_attributed_to_its_host
t "fleet health: an unreachable host is a problem, never a pass"       case_fleet_health_unreachable_host_is_a_problem_never_a_silent_pass
t "fleet health: a remote die with empty stdout is still a problem"    case_fleet_health_remote_die_with_empty_stdout_is_still_a_problem
t "fleet health --quiet: silent, exit code kept, not forwarded"        case_fleet_health_quiet_keeps_the_exit_code
t "fleet health: unknown option and bad value die before dialling"     case_fleet_health_unknown_option_dies
t "fleet upgrade --check: per-host versions and a count, writes nothing" case_fleet_upgrade_check_reports_each_host_and_counts
t "fleet upgrade: applies and says what changed"                       case_fleet_upgrade_applies_and_says_what_changed
t "fleet upgrade: a self-healing host is classified, not unrecognised" case_fleet_upgrade_classifies_a_self_healing_host_not_as_unrecognised
t "fleet upgrade: a failed host is a row, the rest still upgrade"      case_fleet_upgrade_failed_host_is_a_row_not_an_abort
t "fleet upgrade: an unrecognised answer is shown, not guessed at"     case_fleet_upgrade_unrecognised_answer_is_shown_not_guessed
t "fleet upgrade: --ref forwarded; unknown option dies before dialling" case_fleet_upgrade_ref_is_forwarded_and_bad_option_dies
t "fleet upgrade --host: only those hosts are dialled, repeatable"     case_fleet_upgrade_host_targets_only_those_hosts
t "fleet upgrade --host: an unknown host dies before dialling"         case_fleet_upgrade_host_unknown_dies_before_dialling
t "fleet upgrade: a read-back that answers the old version fails the row" case_fleet_upgrade_read_back_mismatch_is_a_failed_row
t "fleet upgrade: an unanswered read-back is its own failure, on FLEET_TIMEOUT" case_fleet_upgrade_read_back_unanswered_is_its_own_failure_on_the_read_budget
t "fleet upgrade --check: no write and no read-back; staging flags refused" case_fleet_upgrade_check_writes_nothing_and_reads_nothing_back
t "fleet upgrade --canary: the first host that would change goes first" case_fleet_upgrade_canary_is_the_first_host_that_would_change
t "fleet upgrade --canary: a failed canary, no other host is written"  case_fleet_upgrade_failed_canary_touches_no_other_host
t "fleet upgrade --canary H: named, refused if level; nothing to canary" case_fleet_upgrade_canary_named_and_nothing_to_canary
t "fleet upgrade --serial: one host at a time, and it does not stop"   case_fleet_upgrade_serial_is_one_host_at_a_time_and_does_not_stop
t "fleet upgrade --stop-on-failure: halts and names the hosts left"    case_fleet_upgrade_stop_on_failure_halts_and_names_the_rest
t "fleet upgrade: the read-back parsers on the real version line"      case_fleet_upgrade_read_back_parsers
t "fleet <mutating>: fans out and forwards the remote's own flags"     case_fleet_mutating_fans_out_and_forwards_flags
t "fleet <mutating>: serial one host at a time; status stays parallel" case_fleet_mutating_is_serial_while_status_is_parallel
t "fleet --host: targets exactly those hosts, repeatable"              case_fleet_host_targets_exactly_that_host
t "fleet --host: an unknown host dies before anything is dialled"      case_fleet_host_unknown_dies_before_dialling
t "fleet stop/drain/disable: refused fleet-wide without explicit scope" case_fleet_capacity_removal_refused_without_explicit_scope
t "fleet drain: allowed with --host or --all-hosts"                    case_fleet_capacity_removal_allowed_when_scoped_or_acknowledged
t "fleet drain: outlasts FLEET_TIMEOUT; status still times out (GHR-81)" case_fleet_drain_outlasts_the_read_only_budget
t "fleet <mutating>: a timeout says the host may still be running it"  case_fleet_mutating_timeout_says_it_may_still_be_running
t "fleet --when-idle: budget is the wait per slot plus the action"     case_fleet_when_idle_budget_is_the_wait_per_slot_plus_the_action
t "fleet <mutating>: the budget arithmetic"                            case_fleet_mutate_budget_arithmetic
t "fleet budget walk: each slot call is on the mutating budget"        case_fleet_budget_walk_gives_each_slot_the_mutating_budget
t "fleet watch keys, upgrade, health --restart-stalled: same budget"   case_fleet_other_mutating_callers_are_on_the_mutating_budget
t "fleet ssh_run: the real timeout wrapper honours the call's budget"  case_fleet_real_ssh_run_times_out_on_the_budget_of_the_call
t "fleet <mutating>: a sudo failure is a named row with the remedy"    case_fleet_sudo_failure_is_a_named_row_with_the_remedy
t "fleet env-init/logs: excluded, each saying why"                     case_fleet_excluded_commands_say_why
# --- GHR-44: capacity budgets -------------------------------------------------
t "fleet --max-unavailable: re-reads fleet state between slots"        case_fleet_max_unavailable_repolls_between_slots
t "fleet budget walk: warns when a host did not answer (GHR-59)"       case_fleet_budget_walk_warns_when_a_host_does_not_answer
t "fleet --min-available: stops at the floor, names what it left"      case_fleet_min_available_stops_at_the_floor
t "fleet budgets: each refuses the command it cannot help"             case_fleet_budget_flags_refuse_the_wrong_command
t "fleet budgets: a percentage never rounds to a deadlocking zero"     case_fleet_percentage_budget_never_rounds_to_zero
t "fleet budgets: the slot inventory reads the real --json emitter"    case_fleet_slot_inventory_reads_the_real_json_emitter
t "fleet: an unconfigured fleet says so and dials nothing"             case_fleet_unconfigured_says_so
t "fleet bogus: unknown subcommand dies, dials nothing"                case_fleet_unknown_subcommand_dies

# --- GHR-54: fleet watch -------------------------------------------------------
t "fleet watch: needs a terminal, dials nothing without one"           case_fleet_watch_refuses_non_tty
t "fleet watch: N ticks, one held connection per host"                 case_fleet_watch_polls_every_host_over_one_held_connection
t "fleet watch: the remote paints; a note still dedupes fleet-wide"    case_fleet_watch_colour_comes_from_the_remote_and_notes_still_dedupe
t "fleet watch: an unreachable host is a row in every frame"           case_fleet_watch_an_unreachable_host_stays_a_row_every_tick
t "fleet watch --host: narrows the watch; unknown host dies first"     case_fleet_watch_host_narrows_the_fleet
t "fleet watch: q quits at once, and the default interval is 5s"       case_fleet_watch_q_quits_and_the_default_interval_is_five
t "fleet watch: the control session opens, then tears itself down"     case_fleet_watch_control_session_opens_and_tears_down
t "fleet watch: the session options reach the real ssh command line"   case_fleet_ssh_run_puts_the_session_options_on_the_ssh_command_line
t "fleet one-shots: no control session, ssh line unchanged"            case_fleet_one_shot_commands_open_no_control_session
t "fleet watch: bad options die before anything is dialled"            case_fleet_watch_bad_options_die_before_dialling
t "status --narrow: drops MAX/HIGH/ENVFILE; refused with --json"      case_status_narrow_drops_max_high_envfile
t "fleet status --narrow: forwarded, and the narrow table arrives"     case_fleet_status_narrow_is_forwarded_and_arrives
t "watch: once narrowed, holds until the margin fits"                  case_watch_narrow_holds_inside_the_margin
t "fleet watch: a too-wide frame narrows next tick and stays narrow"   case_fleet_watch_narrows_on_the_next_tick_and_holds
t "fleet watch: widens again with room to spare; --narrow pins it"    case_fleet_watch_widens_again_and_narrow_pins_it
t "fleet --narrow: a host too old for it renders full-width, no error" case_fleet_narrow_an_old_host_renders_full_width_not_an_error
t "fleet watch: j/k walk (host, slot) pairs, clamp, and cost no fan-out" case_fleet_watch_cursor_walks_host_slot_pairs
t "fleet status: a host line above each host's slots, plain"             case_fleet_status_host_line_above_each_hosts_slots
t "fleet status --color always: the host line is painted locally"        case_fleet_status_host_line_painted_locally
t "fleet status: a host too old for the fragment gets no host line"       case_fleet_status_old_host_gets_no_host_line
t "fleet watch: the host line keeps the remote's colours"                 case_fleet_watch_host_line_keeps_the_remote_colours
t "fleet watch: the cursor skips host lines"                              case_fleet_watch_cursor_skips_host_lines
t "fleet watch: a host line does not count toward the table width"       case_fleet_watch_host_line_does_not_count_for_width
t "fleet summary: a healthy fleet is one short last line"                 case_fleet_summary_healthy_fleet_is_a_short_line
t "fleet summary: a stalled job is counted STALLED, not busy"             case_fleet_summary_counts_a_stalled_job
t "fleet summary: an unreachable host is a host, its slots are not down"  case_fleet_summary_unreachable_host_counts_as_a_host_only
t "fleet summary: mixed versions are counted"                             case_fleet_summary_counts_distinct_versions
t "fleet summary: down, leaking, disk and event segments"                 case_fleet_summary_names_what_is_wrong
t "fleet summary: capacity 0 free is still shown"                         case_fleet_summary_capacity_zero_is_still_shown
t "fleet summary: painted like the table"                                 case_fleet_summary_is_painted_like_the_table
t "fleet summary: the numbers are fleet status --json's"                  case_fleet_summary_matches_fleet_status_json
t "fleet watch: the summary sits under the header in every frame"         case_fleet_watch_summary_sits_under_the_header
t "fleet watch: a host dropping out keeps the cursor, which comes back" case_fleet_watch_cursor_survives_a_host_dropping_out
t "fleet watch: a slot scaled away drops the cursor to its host's first" case_fleet_watch_cursor_on_a_slot_that_scaled_away_stays_on_its_host
t "fleet watch: S, y stops the pair on its own host; the frame shows it" case_fleet_watch_S_stops_the_selected_pair_on_its_own_host
t "fleet watch: K decides on the host's facts read at the key"         case_fleet_watch_K_decides_on_facts_read_at_the_key
t "fleet watch: walking S down the fleet stops at --min-available"      case_fleet_watch_S_walking_the_fleet_stops_at_the_floor
t "fleet watch: T starts and P reaps on the selected host only"         case_fleet_watch_T_starts_and_P_reaps_on_the_selected_host
t "fleet watch: L pages the host's journal; a sudo refusal is a notice"  case_fleet_watch_L_pages_the_remote_journal
t "fleet watch: a failed remote action is a notice, the watch goes on"  case_fleet_watch_a_failed_action_is_a_notice_not_an_exit

# --- GHR-73: a frame that fits the terminal -----------------------------------
t "watch: unknown height (0) is the frame of before, byte for byte"       case_watch_unknown_height_draws_the_frame_of_before
t "fleet watch: unknown height (0) is the frame of before, byte for byte" case_fleet_watch_unknown_height_draws_the_frame_of_before
t "watch: a tall frame is cut to the height, chrome and cursor row kept"   case_watch_tall_frame_is_cut_to_the_terminal_height
t "watch: the window scrolls with the cursor; PgUp/PgDn, g/G, Home/End"   case_watch_window_scrolls_with_the_cursor
t "watch, fleet watch: the last row brings the notes under the table in"  case_watch_last_row_shows_the_notes_under_the_table
t "watch: heights around the frame — too small, one short, exact, spare"  case_watch_heights_around_the_frame
t "watch: a resize redraws the frame in hand at once (SIGWINCH)"           case_watch_resize_redraws_the_frame_in_hand
t "watch --iterations: headless, the height is never asked for"           case_watch_iterations_ignores_the_height
t "fleet watch: a tall frame keeps the summary; host lines scroll in"     case_fleet_watch_tall_frame_is_cut_and_scrolls
t "viewport: a wrapped line is the rows it takes; unused rows are padded"  case_viewport_frame_counts_rows_not_lines
t "viewport: the last row brings the notes under it into view"            case_viewport_frame_brings_the_notes_in_with_the_last_row
t "viewport: no room for a window, or for the cursor line — drawn whole"  case_viewport_frame_too_small_is_drawn_whole
t "read_key: PgUp/PgDn/Home/End in every spelling, the ~ read with them"  case_read_key_decodes_the_paging_keys
t "term_lines: the real one reads tput; failing, garbage or absent is 0"  case_term_lines_real_function_reads_tput

# --- GHR-74: fleet watch fetches in the background -----------------------------
t "fleet watch: a hung host holds up neither the frame nor a key"         case_fleet_watch_a_hung_host_holds_up_neither_the_frame_nor_a_key
t "fleet watch: the first frame, before any host has answered"            case_fleet_watch_first_frame_before_any_host_has_answered
t "fleet watch: q, Ctrl-C and --iterations leave no job and no file"      case_fleet_watch_exit_ends_its_fetches_and_removes_its_files
t "fleet watch: a host that stops answering keeps its rows, with an age"  case_fleet_watch_a_host_that_stops_answering_keeps_its_rows_with_an_age
t "fleet watch: a call still out at the next tick is late, not before"    case_fleet_watch_a_call_still_out_at_the_next_tick_is_late
t "fleet watch: S's floor counts nothing for a host with kept rows"       case_fleet_watch_floor_counts_nothing_for_a_host_with_kept_rows
t "fleet watch: S's floor does not wait for a fetch that is still out"    case_fleet_watch_floor_does_not_wait_for_a_fetch_still_out
t "fleet watch: the summary counts nothing for a host with kept rows"     case_fleet_watch_summary_counts_nothing_for_a_host_with_kept_rows
t "fleet watch: its reads are on FLEET_WATCH_TIMEOUT; fleet status is not" case_fleet_watch_reads_are_on_their_own_budget
t "fleet watch: the background fetches respect FLEET_PARALLEL"            case_fleet_watch_fetches_respect_fleet_parallel
t "now_ms: the real one is epoch milliseconds; ms_to_secs keeps 5 a 5"    case_now_ms_real_function_is_epoch_milliseconds
t "fleet watch: the real fetch job and the ssh under it end at cleanup"   case_fleet_watch_real_fetch_job_and_its_ssh_end_at_cleanup

# --- GHR-75: fleet watch views — filter, sort, collapse ------------------------
t "fleet watch: ! hides a healthy host and keeps a stalled slot"          case_fleet_watch_problems_view_hides_a_healthy_host_and_keeps_a_stalled_slot
t "fleet watch: ! keeps problem hosts, and one that stopped answering"    case_fleet_watch_problem_hosts_and_hosts_that_stopped_answering
t "fleet watch: c is one line per host; Enter or c opens the host"        case_fleet_watch_collapse_is_one_line_per_host
t "fleet watch: a view that shows nothing prints the hint"                case_fleet_watch_an_empty_view_prints_the_hint
t "fleet watch: an action key under a view acts on the cursor's row"      case_fleet_watch_an_action_key_under_a_view_acts_on_the_cursor_row
t "fleet watch: the views count what the summary counts"                  case_fleet_watch_views_count_what_the_summary_counts
t "fleet watch: what a problem slot is, on the classifier itself"         case_fleet_slot_classify_says_what_a_problem_is
t "fleet watch: s cycles the sort and flattens the table; --sort"         case_fleet_watch_sort_cycles_and_flattens_the_table
t "fleet watch: a sort orders by the hosts' own facts, ties in order"     case_fleet_watch_sort_orders_by_the_hosts_own_facts
t "fleet watch: / filters by text as it is typed; Esc, Backspace, Enter"  case_fleet_watch_slash_filters_by_text_as_it_is_typed
t "fleet watch: ? lists every key and closes on any"                      case_fleet_watch_question_mark_lists_every_key
t "fleet watch: a view is fitted to the terminal and paged like a frame"  case_fleet_watch_a_view_is_fitted_and_paged_like_any_frame


# --- GHR-45: provision --------------------------------------------------------
t "provision: fresh host installs, registers and starts every slot"    case_provision_fresh_host_installs_and_registers
t "provision N: already at or above N changes nothing"                 case_provision_is_idempotent_against_the_target_count
t "provision: tops an existing host up, skipping the names in use"     case_provision_tops_an_existing_host_up
t "provision --dry-run: reads the release, changes nothing"            case_provision_dry_run_changes_nothing
t "provision: a bad or missing published checksum stops the install"   case_provision_verifies_the_published_checksum
t "provision --sha256: pins the digest, and refuses a non-digest"      case_provision_sha256_pin_overrides_the_release
t "provision: --token, --pat, \$GITHUB_TOKEN, gh, and the refusal"      case_provision_token_sources
t "provision: the token never reaches stdout, stderr or the PAT argv"  case_provision_never_prints_the_token
t "provision: org/repo/enterprise scope comes from --url"              case_provision_scope_comes_from_the_url
t "provision --runner-version: pins the release, rejects a non-X.Y.Z"  case_provision_pins_a_runner_version
t "provision: an unreachable API or unknown tag is explained"          case_provision_unreachable_api_is_explained
t "provision: bad invocations refuse before touching host or network"  case_provision_refuses_a_bad_invocation
t "provision --help, and the default prefix/user/root"                 case_provision_help_and_defaults
t "no units on this host: every command names provision"               case_provision_is_named_when_a_host_has_no_runners
t "fleet provision: excluded, saying why"                              case_provision_is_excluded_from_fleet

# --- GHR-46: deprovision ------------------------------------------------------
t "deprovision: stop, uninstall, deregister, delete — per target"      case_deprovision_removes_each_target_in_order
t "deprovision: a busy or unreadable slot is refused, nothing touched" case_deprovision_refuses_a_busy_slot
t "deprovision --when-idle: waits for the job, or times out untouched" case_deprovision_when_idle_waits_for_the_job
t "deprovision --dry-run: prints the commands, mints and changes none" case_deprovision_dry_run_changes_nothing
t "deprovision: the removal token reaches no stream and no argv"       case_deprovision_never_prints_the_removal_token
t "deprovision: a runner GitHub forgot is still cleaned up locally"    case_deprovision_already_deregistered_still_cleans_up
t "deprovision: a refused removal-token mint changes nothing"       case_deprovision_failed_mint_changes_nothing
t "deprovision: y/N unless --yes; refused without a terminal"          case_deprovision_confirms_unless_yes
t "deprovision: bad invocations refuse before touching the host"       case_deprovision_refuses_a_bad_invocation
t "deprovision --help, and the top-level usage"                        case_deprovision_help
t "scale/provision notes point at deprovision, not 'not automated'"    case_deprovision_is_named_where_removal_was_manual
t "fleet deprovision: excluded, saying why"                            case_deprovision_is_excluded_from_fleet
t "deprovision: the real dir check and token hand-off"                 case_deprovision_real_helpers

# --- GHR-48: the real discover(), not the stub's stand-in -------------------
t "discover: no matching units is empty and exit 0, not a failure"     case_discover_no_matching_units_is_empty_not_a_failure
t "discover: units still come back, first column only"                 case_discover_still_returns_the_units_when_systemctl_succeeds

# --- compose-reap ---------------------------------------------------------------
t "compose-reap: one verdict per project, dry run removes nothing"     case_compose_reap_dry_run_judges_every_project
t "compose-reap: a slot whose worker is gone no longer owns its stack" case_compose_reap_without_a_worker_the_slot_stack_is_gone
t "compose-reap --apply: reaped projects only, containers->nets->vols" case_compose_reap_apply_removes_only_reaped_projects_in_order
t "compose-reap --apply: refused on a host with no runner units"       case_compose_reap_apply_refuses_without_runner_units
t "compose-reap --project: one project judged and removed"             case_compose_reap_project_filter
t "compose-reap: --max-age-hours and --grace-minutes move the line"    case_compose_reap_age_and_grace_flags
t "compose-reap: a failed removal is counted and fails the run"        case_compose_reap_a_failed_removal_fails_the_run
t "compose-reap: bad input and no docker refuse before any removal"    case_compose_reap_refuses_bad_input
t "compose-reap: an empty daemon is a clean summary"                   case_compose_reap_empty_daemon
t "compose-reap-timer: refuses to run a user-writable runnerctl"       case_compose_reap_timer_refuses_a_user_writable_runnerctl
t "compose-reap-timer: install, status and remove"                     case_compose_reap_timer_install_status_remove
t "compose-reap: the real epoch, work-folder, owner and docker hooks"  case_compose_reap_real_helpers
t "compose-reap: listed in the usage and the unknown-command list"     case_compose_reap_in_usage
t "compose-reap: standalone containers are untouched unless opted in" case_compose_reap_standalone_is_opt_in
t "compose-reap --standalone: one verdict per unlabelled container"   case_compose_reap_standalone_dry_run_verdicts
t "compose-reap --standalone --apply: an image goes only when unused" case_compose_reap_standalone_apply_removes_unused_images_only
t "compose-reap --standalone: kept while a job older than it runs"    case_compose_reap_standalone_kept_while_an_older_job_runs
t "compose-reap: COMPOSE_REAP_STANDALONE=1 opts in; --project; bad value" case_compose_reap_standalone_from_config_and_project_filter
t "compose-reap --standalone: a failed image removal fails the run"   case_compose_reap_standalone_failed_image_removal_fails_the_run
t "compose-reap: the real standalone hook lists only non-compose ids" case_compose_reap_standalone_real_hook

# --- Summary ------------------------------------------------------------------
echo
echo "sim: $npass ok, $nxfail xfail (${XFAIL_KEYS# }), $nfail failed"
if [ "$nfail" -gt 0 ]; then
  printf '  FAIL %s\n' "${FAILED[@]}"
  exit 1
fi
