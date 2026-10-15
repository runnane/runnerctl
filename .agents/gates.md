# Gates

`make gates` = `lint` + `example-drift` + `version-drift` + `smoke` + `sim` +
`migrate-test` + `install-test` + `upgrade-test`. All eight run without systemd
runner units, root or network, so they are green on any dev box and in CI.

**No test may escalate.** `migrate-test`, `install-test` and `upgrade-test` put
a fake `sudo` first on `PATH` that exits 97, so a code path that reaches for
`run_priv` under a caller-owned temp prefix fails the test instead of leaving a
root-owned file behind (which happened once, and needed a real `sudo rm` to
clean up). Keep that tripwire in any new test that exercises a writing command.

In `upgrade-test` that fake `sudo` is load-bearing twice over: it is also the
"sudo is not free" fixture, because `priv_is_free` probes with `sudo -n true`
and gets 97 back. So a case that means to test the refusal path gets it for
free, and a case that accidentally escalates fails loudly — which is how the
staging-directory bug in `priv_is_free` was caught (it checked the destination
file, while `install_file` also needs to write `$dir/.runnerctl.new.$$`).

## lint — shellcheck

Needs `shellcheck` on PATH (`pacman -S shellcheck`, `apt install shellcheck`,
or the static tarball from github.com/koalaman/shellcheck/releases). Point the
`SHELLCHECK` make variable at a non-PATH binary:
`make lint SHELLCHECK=/path/to/shellcheck`.

**Pinned version: shellcheck 0.11.0.** Lint at `-S style` is version-sensitive
(a new release can add or drop findings), so local and CI must agree. CI
installs the official static linux x86_64 tarball for v0.11.0 in
`.github/workflows/ci.yml`, verified against a SHA-256 written in the workflow
before it is unpacked (a mismatch fails the job); the runner is pinned to
`ubuntu-24.04` rather than `ubuntu-latest`. The checksum is of the bytes
downloaded on 2026-10-13 (trust on first use). To move to a newer shellcheck,
change the version and checksum together in the workflow, and bump the version
named here. Dependabot does not watch this pin: it only covers actions.

CI actions are pinned to full commit SHAs with the release as a trailing
comment (`uses: owner/repo@<sha> # vX.Y.Z`), never a floating tag. Dependabot
(`.github/dependabot.yml`, `github-actions`, weekly, `ci:` commit prefix)
opens the bump PRs; review the diff there rather than editing a SHA by hand.

Runs at `-S style` over `runnerctl`, `tests/run.sh` and `tests/stub.config`
(the stub has no shebang because it is sourced, so the set is linted with
`-s bash`), so info-level findings fail the gate. Fix the code rather than
adding `disable` directives; the existing directives are all SC1090 (sourcing
a path only known at runtime) and inherent to the design — the config file,
the legacy script `migrate` reads, and the config `migrate` just wrote.

## example-drift

`config.example` is a checked-in copy of `runnerctl config-example` so it is
browsable on GitHub. The script is the source of truth; after editing
`cmd_config_example`, regenerate with `./runnerctl config-example > config.example`.

## version-drift

`RUNNERCTL_VERSION` in the script must equal `"."` in
`.release-please-manifest.json`. release-please writes both in the release PR
— the script through the `# x-release-please-version` annotation on that line,
the manifest directly — so a mismatch means the annotation was moved or
removed and the tag would carry the wrong stamp. Fix by restoring the
annotation, never by editing either version by hand.

## smoke

Only exercises commands that need neither systemd nor sudo (`version`, `help`,
`profiles`, config loading, unknown-command exit code). Everything that touches
units is covered by `sim`.

**A checkout made under `umask 002` fails smoke locally**, with `config.example
is group-writable by group <gid>, not root — refusing to source it`. That is the
config-ownership guard working as intended on a file git checked out
group-writable; CI checks out under 022 and never sees it. Git tracks only the
executable bit, so `chmod -R g-w .` in the checkout or worktree fixes it without
a diff. That is not enough on its own: `sim` cases that write a config into a
`mktemp` directory (`apply --save`, `scale --save`, the `EVENTS_SEC` /
`DISK_*` status cases) inherit the same umask and fail with exit 1 for the same
reason. Run the whole gate as CI does — `umask 022 && make gates` — and do not
loosen the guard to get past it. Every rebase, checkout or pull rewrites the
files it touches under the shell's umask, so `chmod -R g-w .` again after each
one: a rebased `tests/stub.config` left group-writable fails nearly every `sim`
case with exit 1, which looks like a broken branch rather than a file mode.

## sim — stubbed systemd

`make sim` runs `tests/run.sh`: every command that touches the host (`apply`,
`scale`, `env-init`, `start/stop/restart`, `enable/disable`, `logs`,
`remove-limits`, `status`) is run with `RUNNERCTL_CONFIG=tests/stub.config`.
The config file is sourced after every function in the script is defined, so
the stub shadows `run_priv` (appends its argv to a log and does nothing),
`discover` (three fixed `actions.runner.example.slot-N.service` units), `prop`
(a fixed property table), `unit_props` (the batched per-unit table `status`
reads into an associative array — logged with a `probe:` prefix so cases can
count it without tripping the read-only/leak assertions), and the sources
`job_info` reads rather than `job_info` itself: `journal_job_lines` (the
Listener's `Running job:` / `completed with result:` lines per unit, also
`probe:`-logged; `RUNNERCTL_STUB_JOURNAL_ACCESS=0` makes it fail like
`journalctl --system` does for a user outside `systemd-journal`, which is
the only way that failure is detectable — plain `journalctl -u` answers an
empty journal and exit 0), `now_epoch`, and the `/proc` hooks
`cgroup_readable` / `proc_worker_pid` / `proc_job_env`;
`systemctl`, `journalctl` and `sudo` are shadowed too as a safety net, and a
case whose log shows one of them was reached directly fails. Cases assert on stdout, stderr, the exit code, the
ordered list of privileged calls and the content `tee`d to each path. Plain
bash, no framework — CI and a fresh worktree have nothing but shellcheck.

Two test-only hooks live in the script itself, neither user-facing nor in
the usage block: `RUNNERCTL_NO_MAIN=1` makes it define its functions and
return without running a command (`run_fn` in `tests/run.sh` sources it that
way to call `fmt_dur`, `journal_idle_info`, … directly), and
`watch --iterations N` stops the live loop after N redraws so the sim can
run it — with the stub's no-op `pause`, and `stdout_is_tty` answering
`RUNNERCTL_STUB_TTY=1`, twelve redraws take a fraction of a second. The
stub also shadows `term_cursor`, so tput's escape codes never reach the
captured frames.

**Add a case for every behaviour change that touches units** — a new flag, a
changed call order, a new refusal. A case is a function calling `run <args>`
then `expect_*` helpers (listed at the top of `tests/run.sh`), registered at
the bottom with `t "<name>" <fn>`. A case with no assertions fails.

**xfail convention.** A case that documents a known bug is registered with
`xfail <ISSUE-KEY> "<name>" <fn>` instead of `t`. It prints `xfail` while it
fails, and the run FAILS if it starts passing — so the PR that fixes the issue
must flip the marker to `t` in the same change, and a fix can never land
unnoticed by the gate. Write the case to assert the *correct* behaviour, not
the current one.

Traps:

- **A shadowed function is asserted through its stub, so the stub's contract
  and the real one can diverge in silence.** Every case that goes through
  `tests/stub.config` tests the stub — so a bug in the real `discover`,
  `prop`, `unit_props` or a `/proc` hook is invisible to all of them, however
  many are green. GHR-48 is the worked example: the real `discover` returned
  1 on a host with no units (`systemctl list-unit-files` exits 1 when its
  glob matches nothing, and `pipefail` propagated it), which under `set -e`
  killed `provision` before its first `echo` — silent, exit 1, on the only
  host `provision` exists for. The stub's `RUNNERCTL_STUB_NO_UNITS=1` path
  returned empty and 0, so `case_provision_fresh_host_installs_and_registers`
  was green against a command that emitted nothing at all. **When you change
  a shadowed function, check the stub still models it, and cover the real one
  separately** — `run_fn` sources the script with no config, so `discover`
  stays real there, and a fake binary first on `PATH` (restore `PATH` in the
  case) pins what it does with a `systemctl` that fails.
- `tests/stub.config` must stay mode `0644`: `load_config` refuses a
  world-writable config, and the gate would fail on every case with the
  refusal message. `git` preserves the mode; a `chmod` on the checkout would
  not survive review.
- The stub answers `run_priv test -f <path>` from `RUNNERCTL_STUB_ENV_FILE_EXISTS`
  (default: the file is absent). Prefix a single `run` to flip it:
  `RUNNERCTL_STUB_ENV_FILE_EXISTS=1 run apply --profile deploy`.
- `tests/run.sh` runs under `set -e`, so a command substitution that exits
  non-zero inside an assignment — `FAILS+=("… $(diff a b)")`, `diff` exiting
  1 on a difference — aborts the whole run with no summary line and no
  `FAIL`, which reads as a pass if only the tail is checked. End such a
  substitution with `; true` (GHR-27 found this with a mutation check).
- Colour is off for the whole sim (`export NO_COLOR=1` at the top), because
  the stub's `RUNNERCTL_STUB_TTY=1` would otherwise make `--color auto`
  paint the `watch` frames. A case wanting colour passes `--color always`,
  or `NO_COLOR=''` (empty = unset) to exercise the auto decision.
- `status`'s header fragment after "Host: " comes from `host_line`, which the
  stub pins (GHR-34: `free -h`'s real rounding differed between the two runs
  the `--color always` case diffs, and flaked it). `status --json`'s `host`
  object comes from the separate `host_facts`, pinned the same way.
- **A watch frame fitted to a pinned height has no final newline** (GHR-73:
  `RUNNERCTL_STUB_LINES=N`, with `RUNNERCTL_STUB_SLOTS=4..9` to make the
  frame taller than it). So the next frame's home+clear prefix follows the
  status line on the SAME line, and `expect_out_count "$FRAME_PREFIX" N` —
  anchored to a line start — undercounts as soon as a status line is not
  empty. Split with `frames` and use `expect_frame_count` /
  `expect_frame_lines` / `expect_frame_line` instead, and never count the
  lines of a run's LAST frame: `"$(...)"` strips the newlines it ends in, an
  empty status line among them, so end the key string `-q` and assert on the
  frames before the tick's. A `%` in `RUNNERCTL_STUB_KEYS` is a real SIGWINCH
  sent from inside the key read. With the height unknown (the default, 0)
  nothing is fitted and every older case draws what it always drew.
- **`fleet watch` fetches each host in a background job (GHR-74), and the
  stub models the loop's poll step rather than sleeping through it.** While a
  fetch is out the loop's key read has `FW_POLL` (0.2) as its timeout; the
  stub's `tty_read_char` first waits — really, briefly — until every fetch
  has landed or belongs to a host the case made hang, then: a step in which
  something landed times out and consumes NO scripted key (so one frame per
  tick, as before), and only a step with nothing but hung hosts out reads
  `RUNNERCTL_STUB_KEYS`. A key logged `probe:tty_read_char 0.2 <char>` was
  therefore handled while a host was outstanding. The knobs:
  `RUNNERCTL_STUB_FLEET_HANG="host[:from-poll]"` (the table call blocks until
  its process is killed, 30 s at most; never use it with `--iterations`, which
  waits for the round), `RUNNERCTL_STUB_CLOCK=1` (every whole-second `pause`
  moves `now_epoch`, and a `-` read during a poll step jumps to the next tick,
  so an age can be pinned — set `TZ=UTC` for the `last seen` time), and a
  fourth field on `RUNNERCTL_STUB_FLEET_DELAY` (`host:secs:pattern:from-poll`).
  `RUNNERCTL_STUB_FLEET_DOWN` fails table calls only: a host that must also
  fail the reads an action key makes needs the delay's fourth field.
- **A case that signals the script inherits the gate's signal dispositions.**
  The stub's Ctrl-C is the byte Ctrl-C is, `$'\x03'` in `RUNNERCTL_STUB_KEYS`
  (it was `!` until GHR-75 made that a key `fleet watch` reads): a real SIGINT
  — but a gate started in the
  background (`make gates &`, or under a wrapper that does that) runs every
  case with SIGINT ignored, and bash cannot trap a signal that was ignored
  when it started. That case passed under a plain `make sim` and sat out
  its `RUN_TIMEOUT` under a backgrounded one. The stub now reads `SigIgn` and
  sends SIGTERM there instead (logged `probe:sigterm`, not `probe:sigint`), so
  check which of the two a log shows before claiming the SIGINT path ran.
- **A guarded command's output goes through relays (GHR-91).** From the point
  `drain`, `start`/`stop`/`restart`, `apply` and `scale` arm their record,
  `caller_guard` sends stdout and stderr through a relay process each and
  ignores SIGHUP. Since GHR-137 the same is true of `upgrade` (and
  `--rollback`), `deprovision` (after its prompt), `kill`, `reap`,
  `enable`/`disable`, `remove-limits`, `env-init`, `compose-reap --apply` and
  `health --restart-stalled`. `provision`, `install`, `migrate` and
  `compose-reap-timer` are not guarded (GHR-153). That is why the GHR-131
  HUP/PIPE cases signal `compose-reap-timer remove`, not env-init: a case
  that wants an armed command which is not guarded has to pick one from that
  list. So a cut reader or a hangup no longer ends them, and
  `exit_run` waits for the relays before it writes the record. A case that
  closes the reader part-way uses `run_cut N` with `RUNNERCTL_STUB_CUT_AT=K`.
  The reader keeps N lines, closes its end, and only then touches
  `$WRITES/.cut`. The stub's K-th `pause` waits for that file
  (`probe:cut_seen K`), so every later write meets a closed reader at a known
  point. A command that never pauses (env-init, `disable`, `remove-limits`,
  `health --restart-stalled`, `compose-reap --apply`) is cut with
  `RUNNERCTL_STUB_CUT_ON=ERE` instead: the first `run_priv` or `compose_rm`
  line that matches waits the same way (`probe:cut_seen on`), after the
  call is logged and before it acts. N must be exactly the number of lines
  the command prints before that point. Fewer, and a write made before the
  guard meets the closed reader and ends the run unguarded. More, and the
  reader never closes and the wait gives up (`probe:cut_gave_up`). `upgrade`
  runs for real in `tests/upgrade-test.sh` (case 16), where a fake `mv`
  first on PATH is the cut point. `RC` is the command's own status, not the
  pipeline's. Without
  `RUNNERCTL_STUB_BUSY_POLLS`, the stub's slot-1 is busy for ever, so a
  `drain` case sits out the whole `WAIT_TIMEOUT` in polls. For a signal the
  command is meant to survive, `RUNNERCTL_STUB_BLOCK_SECS` shortens
  `RUNNERCTL_STUB_BLOCK`'s 30 s hang. `run_signalled` resets HUP to the
  default as well as INT and TERM.
- The `status --json` case (GHR-16) asserts the parsed JSON through
  `python3` (`expect_json`): where python3 is absent the case keeps its
  exit-code, shape and read-only assertions, prints a `skip` notice for the
  rest and still passes — it is not an xfail and never counts as a failure.
  ubuntu-latest has python3, so CI runs the full case.
- **Four characters of `RUNNERCTL_STUB_KEYS` are not keys** (GHR-75), so a
  case cannot type them — into `fleet watch`'s `/` filter, say: `-` is a tick,
  `%` a SIGWINCH and `$'\x03'` a SIGINT, and a newline is Enter (the real
  `read -n1` hands back an empty character for it). A text with a `-` in it
  reads as shorter text and extra ticks, and the tell is a `probe:ssh_run`
  count four higher than pinned per stray dash. A lone Escape is `$'\e-'`:
  `read_key` looks for the rest of a sequence with a second short read, which
  would otherwise swallow the next scripted key. A fifth since GHR-125:
  `$'\x01'` (`REL` in `tests/run.sh`) releases every held action (below).
- **A `fleet watch` action runs in the background (GHR-125), and the stub
  models it as it models a fetch.** The poll step counts each action job too:
  landed once its `rc` is written, still moving until then — so an action that
  answers at once lands in the first step after `y`, which consumes no key, and
  the frame count of every older action case is what it was. To keep one out,
  `RUNNERCTL_STUB_FLEET_HOLD="host…"`: its mutating call prints a progress
  line and then WAITS (`probe:remote_held`) until a `REL` in the keys
  (`probe:release`, which also waits for the jobs to end) or 10 s; it counts
  as hung, so the keys after it are read on the poll step
  (`probe:act_poll landed=0 held=1`, then `probe:tty_read_char 0.2 <c>`) —
  a key handled while the action ran. A TERM or HUP it gets is
  `probe:remote_signal HOST SIG`; its pids up to the central process are in
  `remote/<host>.held.pids` for `_ghr74_expect_dead`. In the sim the remote
  is a process under the job, so `q` (which reaps the job's tree) ends it too —
  assert the absence of `probe:remote_signal` only for Esc.
  `RUNNERCTL_STUB_FLEET_HOLD_HOSTILE=1` puts `STUB_HOSTILE` on the progress
  line, which nothing but the draw's `relay_safe` filters while the call runs.
  Since GHR-144 a confirmed `:` command is one more job counted the same way
  (`FW_CMD_PID`, its `rc` in `FW_TMP/cmd.job/`), held while ANY host it
  holds is held. Its paged output is printed after the frame it ended under
  and before the next frame prefix, so `frames` puts the pager's lines in
  the PREVIOUS frame — and the notice is the output's last line, so a
  "notice not in frame N" assertion matches the pager's copy. Order the end
  by the log (`probe:page`) instead.
- **A copy of the script handed to the sim through `$RUNNERCTL` has to be a
  file NAMED `runnerctl`** (GHR-78) — in a directory of its own, one per
  mutant. `case_compose_reap_timer_install_status_remove` pins the script's
  own path in the unit's `ExecStart=…/runnerctl compose-reap --apply`, so a
  copy called `runnerctl.pristine` or `m_a` turns that case red in every run,
  the unmutated control included, for a reason that has nothing to do with
  the mutation. Run the control first: it is what tells that apart.
- **The run a job belongs to (GHR-78) comes from `proc_job_env`, which the
  stub shadows.** `RUNNERCTL_STUB_RUN=1` gives slot-1 the run's variables and
  slot-2 an environment of its own — two busy slots of one repository, but
  only under the /proc-only reader (`RUNNERCTL_STUB_JOURNAL_ACCESS=0
  RUNNERCTL_STUB_CGROUP_READABLE=1`): the journal reader finds slot-2 idle and
  never asks. `RUNNERCTL_STUB_RUN_<NAME>` replaces one of slot-1's values. The
  hook's contract is one line per variable, so a value with a newline in it
  cannot be a stub case: the real reader is `proc_environ_job_vars FILE`,
  which `run_fn` calls on a NUL-separated fixture file.
- **`watch` remembers a job's run facts (GHR-102), and only `watch` does.**
  `ENV_MEMO_DIR` is a per-run directory (not `JOURNAL_MEMO_DIR`, which the
  journal TTL empties) holding what `job_env_facts` kept, keyed by unit,
  InvocationID and `JOB_SINCE` (2 s of slack: it is derived from an age).
  `RUNNERCTL_STUB_ENV_ONCE=1` makes slot-1's environment answer once per run.
  The new-job and term_safe cases call `job_facts` through `run_fn` with the
  `GHR102_HOOKS` string, because the stub's one fixed job start cannot give a
  second job. A one-shot `status` has no memo directory, so it forgets.
- **A remote's table in the fleet stub is `render_status` called directly, not
  `cmd_status`.** So a case about a fleet row does not exercise anything
  `cmd_status` decides before it renders — `STATUS_COLS` (GHR-78: the long
  WORKING-ON cell is a terminal's) is reset by the stub itself, as the stall
  threshold and the narrow table are. The gate on `stdout_is_tty` is pinned by
  the local `status` cases; the fleet-row assertion stays green without it.
- **`fleet watch`'s view keys go through `fleet_watch_view`, not
  `fleet_watch_rows`** (GHR-75): with a filter, a sort or a collapse on, the
  rows the cursor walks are the VIEW's. A case about an action key under a
  view has to make the view's row order differ from the frame's at the
  cursor's position (`b j`, `i`, `s j j` on two identical hosts do), or a
  cursor indexing the unfiltered frame acts on the right slot by accident.
  The stub's hosts are identical unless a knob says otherwise:
  `RUNNERCTL_STUB_FLEET_STALL="host…"` gives the named hosts a ten-minute
  stall threshold of their own, `RUNNERCTL_STUB_FLEET_FULL` full disks and
  journal events.

- **A host named `*hostile*` sends hostile bytes (GHR-101).** The stub answers
  for it as for any host, then appends `STUB_HOSTILE` — a screen clear, a
  window-title OSC and one SGR-painted word — to every non-empty line it
  writes, stdout and stderr, `--json` included; it composes with the other
  names (`hostile-unreachable`, `hostile-weird`). What a relay keeps of it is
  `HOSTILE_KEPT` in `tests/run.sh`, and `relay_want` derives a hostile host's
  expected lines from build-1's (same-width names). A frame's own prefix is
  `ESC [ H ESC [ 2 J`, so assert the rest is gone with
  `expect_no_hostile_rest`, never a bare `expect_no_out 2J`. The relay itself
  runs where an answer lands (`fleet_fanout_one`, `fleet_watch_fetch_one`,
  the watch's key reads), so a mutation that removes one `relay_file` call
  turns red every case reading through that intake point, each at its own
  assertion.
- **A detail pane (GHR-76) is asserted by frame, not by `expect_out`.** A pane
  frame has no cursor row, so with colour off it carries no escape sequence
  of its own: `expect_frame_plain N` holds the whole frame to "no control
  byte", which `expect_no_control_bytes` cannot do for a watch (the frame
  prefix and the table's cursor row are escapes). `frame_from N L` pins a pane
  without the clock in the header — from line 2 locally, line 3 in `fleet
  watch` (the summary is line 2). The version in a pane is `$(pane_ver)`,
  never a literal: release-please moves it. Two knobs exist for the pane
  alone: `RUNNERCTL_STUB_LEAK_COMM` (the comm of slot-2's first leaked
  process, for hostile text) and `RUNNERCTL_STUB_SCALED_AFTER=N` with
  `RUNNERCTL_STUB_CLOCK=1` (the LOCAL host loses slot-3 once the clock is N
  seconds on, which one tick of `watch --interval N` does). A payload no stub
  host sends — an older host's, a hostile one's — is a hand-written
  `FW_STATE/0.json` handed to `fleet_watch_pane_build` through `run_fn`, with
  `now_epoch` pinned in the same eval.
- **A fleet host line starts with the host's version cell (GHR-77)**:
  `build-1 v0.20.0 · Disk: …`, or the cell alone for a host with no Disk /
  events fragment whose version is not this node's. A stub host answers with
  the script's own version, which release-please moves, so a case matches a
  level host's line through `HV` (`v<version> · ` as an ERE, read from the
  script under test), never a literal — and `FLEET_INFO_RE`, which keeps the
  watch cursor off host lines, changes with the cell. The knobs:
  `RUNNERCTL_STUB_FLEET_VER="host:version …"` (one host answers as any
  version, a text that is no version included — no `*` or `?` in it, the list
  is word-split) and `RUNNERCTL_STUB_VERSION` (this node's version, and every
  host's the first knob does not name: the remote runs in a subshell of the
  central process).
- **A process's or a job's text on this host's own lines (GHR-100)** is drawn
  through `relay_safe … plain`, so an expected text has a sequence gone WHOLE
  (`my-app`, never `my[2J-app` — that is `term_safe` alone, and what a
  mutation back to it looks like). The comm lists are made safe where
  `job_leak_check` / `job_tree_check` collect them and are joined on
  `COMM_SEP` (0x1f), never on `,`. Knobs for hostile text beyond
  `RUNNERCTL_STUB_LEAK_COMM`: `RUNNERCTL_STUB_TREE_COMM` (the comm of `kill`'s
  step child, pid 4101), `RUNNERCTL_STUB_HOST_EVENTS=hostile` (an OOM line and
  a disk-full line whose process name and identifier carry sequences) and
  `RUNNERCTL_STUB_COMPOSE_STALE` (the `stale` compose project's label). A
  stalled job under the /proc-only reader needs a visible Runner.Worker for
  its age: `RUNNERCTL_STUB_COMPOSE_WORKER=1` (8000 s, 2h13m). The real
  `proc_leaked` is covered by one `run_fn` case over the run's own cgroup,
  with a copy of `sleep` named so its comm is hostile; it prints a `skip` where
  that cgroup cannot be read.

- **CPU and load (GHR-79) are stub hooks too, and their real readers take a
  FILE.** The stub shadows `cgroup_cpu_facts`, `host_loadavg`, `now_us` and
  `cpu_window_wait` (the one wait a one-shot table makes, logged
  `probe:cpu_window_wait MS` — not `pause`, which --when-idle's cases count).
  Unset, no slot has CPU accounting and no load is readable, so every CPU
  cell is `—`, nothing waits and the header has no `load` fragment — every
  case from before reads what it read. `RUNNERCTL_STUB_CPU="N:MILLICORES …"`
  gives slot-N a counter (a different base per slot, so a rate against the
  wrong slot's sample is visibly wrong), `RUNNERCTL_STUB_CPU_RESET=1` sends it
  backwards, `RUNNERCTL_STUB_LOAD="L1 L5 L15"` is /proc/loadavg and
  `RUNNERCTL_STUB_FLEET_NOCPU="host…"` makes a fleet host draw the table of a
  release from before the column. The sample clock moves only by
  `cpu_window_wait`, or by whole seconds under `RUNNERCTL_STUB_CLOCK=1`, and is
  kept per remote host. The real parsers — `loadavg_read`, `cpu_stat_usage`,
  `cpu_pressure_some` — are covered by `run_fn` over fixture files.
- **Nothing in a runner's directory runs as root (GHR-110).** `provision`
  writes the runner's unit itself (`render_runner_unit`, upstream's template
  read from actions/runner v2.338.0 — re-check it when a runner release
  changes `actions.runner.service.template` or `systemd.svc.sh.template`), and
  `runner_exec` / `runner_exec_with_token` refuse uid 0, so every runner
  script goes through `runuser -u <user> --`. `expect_no_root_exec_in_runner_dirs`
  holds a run's whole log to that: a privileged call naming
  `/opt/actions-runner/...` that is not `runuser` must be `mkdir -p`, `tar -C`,
  `chown -R` or `rm -rf --` of the directory. Match the runner's `svc.sh` with
  `$SVC_SH`, never a bare `svc\.sh`, which also matches `runsvc.sh` — the file
  the unit runs as the runner user. `RUNNERCTL_STUB_UNIT_USER` answers another
  `User=` for a deprovisioned unit (`root`, for the refusal). A real-helper
  case that wants a runner script actually run replaces `run_priv` with one
  that drops the `runuser -u <user> --` prefix; there is no root form to pick
  instead, and a mutant reaching the real `run_priv` would be a real sudo —
  so cases that call `runner_exec` go through `run_snippet` with the stub.

- **The runner root's trust check (GHR-121) is a stub hook too.**
  `runner_root_problem` answers "fine" in the stub, because no sim directory
  is root-owned — so a case through the stub tests the stub. The cases that
  matter set `RUNNERCTL_STUB_ROOT_REAL=1`, which runs the real helper (built
  on `root_exec_problem` via `dir_chain_problem`), and fake only `stat`'s uid
  and mode from a config of their own (`ghr121_config`, `GHR121_TABLE`); the
  stub's `root_exec_problem` is shadowed too, so that config restores the real
  one from `real_root_exec_problem`. A path the table does not list is root's,
  755. `deprovision` reads the root from the unit's `WorkingDirectory`, which
  the case config points at a real fixture directory (a missing component ends
  the walk, as it does for a root `mkdir -p` has yet to create). It asks the
  stubbed `runner_root_chain_problem` directly and, when the parent is
  untrusted, removes the slot with `runuser -u <user> -- rm -rf` instead of
  refusing (`GHR121_RM_FAIL=1` makes that rm fail). The real
  helper is also run unfaked over real directories: `/tmp` (sticky 1777) must
  be refused. `deprovision N` counts from 0 in the stub: `deprovision 1` is
  `example.slot-2`.
- **A root run of `install`/`upgrade` is `RUNNERCTL_STUB_AS_ROOT=1` (GHR-117).**
  `write_as` judges a directory only when the write is privileged, and as
  root `[ -w ]` is always true — so the script asks the `as_root` hook, which
  the stub answers no unless that knob is set. Under it every write of a judged
  directory goes through `run_priv`, which is what puts root's calls in the
  log. `install-test` and `upgrade-test` never run as root, so none of their
  cases reaches the trust check at all: the GHR-117 sim cases are its only
  coverage. They source `ghr117_overrides` after the stub (in the snippet, or
  in a config that sources the stub first — never a config that sources the
  stub a second time, which would capture the stub's `root_exec_problem` as
  the "real" one): the real `root_exec_problem`, `stat` faked from
  `GHR117_TABLE` like GHR-121's, and a `run_priv` that logs each call and then
  makes it for real as this user, dropping a `runuser -u USER --` prefix, and
  refuses any path outside the case directory. That `run_priv` replaces the
  stub's, so a whole `apply`/`scale` run under it would hand `systemctl
  daemon-reload` to the real binary: the GHR-135 `--save` cases build their
  config with `ghr135_config`, which keeps both and routes each call by
  whether its argv names the case directory (the config write is GHR-117's,
  the drop-ins and systemd calls stay the stub's). Their "no root call"
  assertion is `ghr135_root_call DIR`, not `GHR117_ROOT_CALL`, because the
  stub's drop-in `mkdir`/`tee` match the latter.
- **The record (GHR-88) never reaches the real journal or the real fleet
  log.** Three nets, because each covers a path the others miss: the stub
  shadows the record's hook `audit_logger` (each record is a
  `probe:audit <line>` in the case's log — pin the whole line with
  `expect_one_record`), shadows `logger` as a `direct:` safety net, and
  `tests/run.sh` puts a fake `logger` BINARY first on `PATH` for the whole
  sim, since the real hook runs it through `timeout`, which no shell function
  can shadow, and `run_fn` / `run_bare` get past the stub. That binary logs
  `direct:logger …` into the case's log (a failure) unless `FAKE_LOGGER=record`
  (argc and each argument to `$TMP/logger.calls`) or `FAKE_LOGGER=fail`;
  `RUNNERCTL_STUB_AUDIT=real` keeps the real hook so it is reached.
  `install-test`, `upgrade-test` and `migrate-test` pin `PATH` to
  `/usr/bin:/bin`, where the real `logger` lives, so each puts its own fake
  `logger` in its `nosudo` directory. The central node's `FLEET_LOG` is
  pointed into each run's writes tree by the stub (`$WRITES/fleet.log`);
  `RUNNERCTL_STUB_FLEET_LOG=default` leaves it empty for the default-path case,
  which points `HOME` at a temp dir — and `XDG_STATE_HOME` is a temp dir for
  the whole sim, so a run past the stub cannot append to `~/.local/state`.
  The first sim run of GHR-88, before the stub pointed it away, wrote 93
  lines to the developer's own `~/.local/state/runnerctl/fleet.log`.
- **`--origin` is logged on its own line, not in `probe:ssh_run`.** The fleet
  stub takes `--origin=…` off the command line where main would read it —
  the word after `FLEET_RUNNERCTL` (after `sudo -n` under `FLEET_SUDO=1`) —
  and logs `probe:ssh_origin HOST VALUE` before the call's `probe:ssh_run`,
  so every pinned `probe:ssh_run` line reads as before. Anywhere else it is
  left in place, where it breaks those pinned lines. A host named
  `*preorigin*` refuses it as main refuses an unknown command (exit 1, does
  nothing) — the older-host retry; the claim is `$ME@stub-host-1`.
- **`relay_safe` clobbers `BASH_REMATCH`** (it matches regexes of its own).
  Take every capture you need into a variable BEFORE calling it — the first
  `history` parser read the time after relaying the message and died
  `unbound variable` on the one record that carried an escape sequence.
- **`trap CMD EXIT` is a wrapper, not the builtin** (GHR-88): it keeps CMD in
  `EXIT_CMD` and installs `exit_run`, which writes the record first. A
  subshell inherits `EXIT_CMD` but not the trap, so `exit_run` runs CMD only
  in the process that set it (`EXIT_PID`). Code that needs the raw builtin
  says `builtin trap`.
- **INT and TERM through the `trap` wrapper are the record's too** (GHR-119).
  While a record is armed both run `audit_signal`, which writes `interrupted
  (SIGINT|SIGTERM)` and then either runs the command's own handler for that
  signal (kept by `sig_own` — `watch` and `fleet watch` trap both to `exit
  0`) or resets the disposition and re-raises at `$BASHPID`, so the process
  still dies BY the signal. `audit_finish` hands both back to the command's
  handler, or to the default. Every other signal is the builtin's. A shell's
  `$?` cannot tell a death by signal from `exit 130`, so the cases that pin
  it go through `run_signalled SIG group|pid BLOCK-ERE ARGS…`: a perl parent
  (reset INT/TERM to default first — the GHR-75 trap — then fork, `setsid`,
  exec) that waits for the stub's `RUNNERCTL_STUB_BLOCK` call (the
  `run_priv` whose argv matches it hangs in a foreground `sleep 30` after
  touching `$WRITES/.blocked`), signals the group or the pid alone, and reads
  WIFSIGNALED from a real `waitpid` — `expect_signalled N`. Signal the
  GROUP for an armed command: bash runs a trap only once the foreground
  step has ended, so a TERM to the pid alone would wait out the stub's 30 s
  sleep and read as `survived`. That deferral is also the observable a
  signal handler armed before the record changes, which is why the
  before-arming case signals the pid alone. Where perl is absent the cases
  print a `skip` and keep a weaker assertion; ubuntu has perl. A `run_fn`
  case about these handlers uses TERM only: its bash inherits the gate's
  ignored SIGINT under a backgrounded gate, so `trap … INT` is a silent
  no-op there — the first run of GHR-119's composition case was green under
  a plain `make sim` and red under `agent-gate-admit`, with `trap -p` showing
  `trap -- '' SIGINT`.
- **HUP and PIPE are the record's too, except under a caller guard**
  (GHR-131). Armed and not guarded, both run `audit_signal` exactly as INT
  and TERM do (`interrupted (SIGHUP|SIGPIPE)`, then death by the signal).
  `caller_guard` takes both back (`audit_sig_yield`): HUP stays the guard's
  ignore and is never handed back by `audit_sig_disarm`, PIPE goes back to
  the command's own. **An agent harness starts the gate with SIGPIPE
  ignored** (`SigIgn` bit 12 in `/proc/self/status`), so a `run_fn` case
  cannot trap PIPE at all — use `run_fn_sigdfl` (perl resets INT, TERM, HUP
  and PIPE before exec), and `run_signalled` resets PIPE too. The GHR-80
  stream-reader case therefore exercises its PIPE trap only where the gate's
  PIPE is at its default (CI); under an agent the trap is a silent no-op and
  the case is green by some other path out.
- **A space in `RUNNERCTL_STUB_KEYS` is a key (GHR-129)**: `fleet watch`'s
  mark. The real `IFS= read -rsn1` hands back `' '` for it, and so does the
  stub (logged `probe:tty_read_char 5 \ `). While any row is marked the table
  has a two-column gutter (`* ` or two spaces) in front of EVERY line, header
  included, so `fw_row` and any `^build-1 +…` pattern stop matching: a marks
  case writes its own `^\* build-1 …` / `^${REV}\* …` patterns. With no marks
  the frame is the one of before, which is what keeps every older case green.
- **`history`'s journal read is a hook** (`journal_history_lines N`): the
  stub answers it from `RUNNERCTL_STUB_HISTORY` (a file of journalctl
  short-iso-precise lines; a remote host's is `<file>.<host>` when it exists)
  and `RUNNERCTL_STUB_HISTORY_RC` fails it; the real reader is covered by
  `run_fn` over a fake `journalctl` on `PATH`. `-t`, never `-g`: with `-q`,
  `journalctl -t` that matches nothing exits 0 and prints nothing, so a
  non-zero exit is journalctl failing.

- **`fleet status --json --watch` (GHR-80) is `fleet watch`'s fetch with one
  call per tick, `status --json`** — so the stub's frame-poll knobs, which
  count and fail `status` TABLE calls only, do not reach it unless the case
  sets `RUNNERCTL_STUB_FLEET_JSON_POLLS=1` (then the `--json` call is the
  poll: `RUNNERCTL_STUB_FLEET_DOWN` and `_HANG` apply). The stream's waits go
  through the `stream_wait` hook, logged `probe:stream_wait S`: a poll step
  (S = `FW_POLL`) is modelled like `fleet watch`'s, and with
  `RUNNERCTL_STUB_CLOCK=1` a step with only hung hosts left jumps the clock to
  the end of the interval — so a stream with a hung host writes its envelope.
  Without the moving clock that stream never writes one: run it with
  `--iterations`, or set the clock. Each envelope is one LINE: assert with
  `expect_json_line N`, not `expect_json`. `duration_ms` is pinned per host
  with `RUNNERCTL_STUB_FLEET_MS="host:ms …"` (STUB_MS_ADD, which `now_ms`
  adds, per background job). `RUNNERCTL_STUB_FLEET_NOHEALTHJSON="host…"` is a
  host too old for `health --json`.
- **A `fleet upgrade --push` host (GHR-83) runs the script's REAL remote
  text.** A push call is one word of shell (`exec /bin/sh -c '…'`), not a
  runnerctl argv, so `ssh_run_body` hands it to `stub_push_remote`, which runs
  it with `/bin/sh` under `env -i` in `$WRITES/remote/<host>/` — `bin/` (its
  runnerctl, first on PATH), `tmp/` (its TMPDIR: assert it empty, the temp
  file is removed on every path), `etc/config` (empty, so the host's install
  never reads this box's `/etc/runnerctl/config`), `before` (its runnerctl as
  the case began) and `fake/`, whose `sudo` runs the REAL `install` of the file
  it is handed, as this user, with the host's `--config` and `--prefix` added,
  whose `logger` logs `probe:remote_push_logger`, and whose `curl` logs
  `probe:remote_push_curl` and fails — no host may download. That fake `sudo` refuses
  anything but `-n bash FILE` (`probe:remote_push_piped` for a `bash -s`,
  which would download). The stub's `ssh_run_stdin` keeps what a host
  received as `remote/<host>.received`. Hosts by name: `*absent*`,
  `*pushsame*`, `*ahead*` (9.9.9), else 0.0.1; `*mangle*` receives one byte
  changed, `*pushcorrupt*` installs other bytes than it was handed,
  `*nosudo*` refuses sudo. The host's own sha256 check and the central
  read-back BOTH catch wrong bytes, so a case about the host's check asserts
  the file in place is unchanged — the read-back alone cannot show that — and
  `newer` is pinned on what was SENT, since the host's `install` refuses a
  downgrade by itself too. `install-test` 3b pins the same `bash FILE
  install` shape outside the stub: the file is the source, nothing is
  downloaded (a fake `curl`), a pre-config script is migrated first.
- **`health`'s problems are kept as kind / slot / detail (GHR-80)**, and the
  prose line is rebuilt from them (`<slot>: <detail>`, `host: <detail>`);
  `host_problems` prints `KIND<TAB>TEXT`. A new problem goes through
  `health_add` with a kind, or `health --json` cannot report it.
- **`host.sudo_contract` (GHR-113) is a stub hook too, and the real reader is
  a `run_fn` case over files of its own.** The real `host_sudo_contract` reads
  `/etc/runnerctl/config`, which no sim case may touch, so the stub pins it
  (`narrow`; `RUNNERCTL_STUB_SUDOC` for the local run). Per fleet host:
  `RUNNERCTL_STUB_FLEET_SUDOC="host:value …"` (any text, no `*` or `?`; `-` is
  an empty answer, so `null`) and `RUNNERCTL_STUB_FLEET_NOSUDOC="host…"` for a
  host from before the key (the stub takes it out of the payload with `sed`).
  Everything is read from the `status --json` call the summary already makes
  (`fleet_sudo_state`), so a case about the note needs `RUNNERCTL_STUB_FLEET_SUDO=1`
  and a host that answered both calls. A case that checks "not named" must
  assert on `SUDO_CONTRACT` AND `root-equivalent`, since the host line and the
  note are two separate lines. A new `expect_*` helper defined further down
  `tests/run.sh` than the cases cannot be used by them: `t` runs a case where
  it is registered (`expect_no_control_bytes` is one such).

- **A fleet host's `compose-reap` and `compose-reap-timer` run the REAL
  commands (GHR-87)** over the one docker model, which every stub host shares:
  `RUNNERCTL_STUB_COMPOSE` / `_STANDALONE` are read once, when the stub is
  sourced, so they cannot differ per host. What can, by host name:
  `*nodocker*` (no docker on PATH), `*dockerdenied*` (the daemon refuses the
  login — `RUNNERCTL_STUB_DOCKER_DENIED=1`, the knob for a local run — unless
  the call came through `sudo -n`) and `*rootexecbad*` (the timer's
  root-exec refusal even under `RUNNERCTL_STUB_ROOT_EXEC_OK=1`). Each host's
  timer units live in `$WRITES/remote/<host>/etc/systemd/system` (that call's
  `SYSTEMD_DIR`); `RUNNERCTL_STUB_FLEET_TIMER="host…"` installs one there
  first. The stub's `systemctl` safety net answers exactly two read-only
  questions — `is-enabled` / `is-active runnerctl-compose-reap.timer` — as
  `probe:systemctl …` (`RUNNERCTL_STUB_TIMER_STATE="ENABLED ACTIVE"`); any
  other call is still `direct:`. The dry run's "changed nothing" claim is
  asserted as `GHR87_NOT_A_PROBE` in `tests/run.sh`: a log line that is not a
  `probe:` is a `run_priv` argv or the stub's `docker rm`. A local
  `compose-reap-timer status` (not `--brief`) reads its `list-timers` row
  through the `compose_reap_timer_listing` hook (GHR-146), which the stub
  answers with a fixed row, logged `probe:compose_reap_timer_listing`; a case
  may end on it.
- **The stub-leak check accumulates across a case's runs (GHR-146).** Every
  `run`/`run_keep`/`run_fn` resets the call log, so `_log_reset` first moves
  any `direct:` line the outgoing log holds into `$LOG.leaks`, and `_case`
  fails the case on a `direct:` line in either file. A later run can no longer
  hide an earlier leak. A new reset site writes `_log_reset`, not `: >"$LOG"`.
  A case that deliberately runs the real `audit_logger` (`run_fn`) needs
  `FAKE_LOGGER=record`, or the fake `logger` binary logs `direct:logger`.
- **A fleet table call is `status … --with-json` (GHR-90)**, the flag LAST on
  the line, and the summary's payload comes back in the same answer — so a
  host that takes the flag is never asked `status --json` by `fleet status`
  or a watch tick; a `status --json$` line in a watch log is an action key's
  read or the capacity floor's. The stub answers the flag with the real
  `render_status` under `STATUS_WITH_JSON`. `RUNNERCTL_STUB_FLEET_NOWITHJSON=
  "host…"` is a host from before it (refuses it as an unknown option, so it
  takes the old two-call path); `RUNNERCTL_STUB_FLEET_FLIP="host…"` flips that
  host's slot-1 to `inactive` on every second collection (counted in
  `remote/<host>.flip`), which is what tells one collection from two: a table
  and a payload from one collection agree on slot-1, two never do.

## migrate-test

`bash tests/migrate-test.sh`. Runs `runnerctl migrate` against
`tests/fixtures/runnerctl-legacy` — a sanitised copy of the pre-config script
the hosts ran, with generated placeholder values (public repo: keep it that
way) — using `tests/migrate.config`, which shadows `discover` and sets
`SYSTEMD_DIR=tests/fixtures/systemd` so the live-reconciliation and
render-check paths run against a fixture drop-in tree. The expected config is
`tests/expected/migrate.config` (the dated first line is excluded from the
comparison); regenerate it deliberately, after reading the diff, when the
generated format changes.

The fixture drop-ins were rendered by the legacy script's own `render_dropin`
(slot-1/2 `ci` at 24G/20G — deliberately different from the script's 26G/22G —
slot-3 `deploy`, plus a foreign `20-other.conf`), so the test exercises
"live wins", the foreign-drop-in warning, and the byte-identical render check.
Case 5 mutates a copy of the tree so two units of one profile disagree and
asserts the render check goes red.

`SYSTEMD_DIR` is a plain variable for exactly this reason; a config can
override it like any other default.

## install-test

`bash tests/install-test.sh`. Runs `runnerctl install --prefix <tmp>` through
its paths: fresh, idempotent rerun, legacy fixture (asserts `migrate` ran
*before* the file was replaced, by line order in the output), `--dry-run`,
`--no-migrate` (keeps `runnerctl.legacy`), a migrate that fails its render
check aborting the install with the old file intact, no-downgrade against a
copy stamped `9.9.9`, refusal to overwrite a non-runnerctl file, and the
piped form. The piped case is offline: a temp config sets
`UPGRADE_URL="file://$PWD/runnerctl"` and `cat runnerctl | bash -s -- --config
<that> install --prefix <tmp>` exercises the real download path through
`curl`'s `file://` support. `--ref`'s URL mapping (`resolve_url`) has its own
`sim` cases through `run_fn`; the actual `--ref` download here is not covered
(a real GitHub release or raw.githubusercontent.com fetch), so verify that
end-to-end path by hand.

## upgrade-test

`bash tests/upgrade-test.sh`. `upgrade` against a `file://` `UPGRADE_URL`, with
the fake-`sudo` tripwire above. Since GHR-84 every download is also checked
against a digest, and two things about the fixture follow:

- **A `file://` source's digest is the sibling `runnerctl.sha256`, and a
  missing one is that source's 404** (curl exits 37 with status `000`). The
  older cases point at the checkout itself, which carries no digest, so they
  install `not verified` — case 1 pins that line. A stray `runnerctl.sha256`
  left in the repo root (by running the release job's command by hand, say)
  would make every one of them verify against it and go red on a mismatch:
  delete it (`.gitignore` keeps it out of a commit, not out of the test).
- **The https rule is exercised through a fake `curl`** first on `PATH` for
  case 15 only, with `UPGRADE_URL` set to a release-asset URL of a generic
  `example` repo: it serves the checkout for any URL ending in `/runnerctl`
  and answers the digest URL as `FAKE_DIGEST` says (`404`, `503`, `timeout`,
  `file:PATH`), logging every URL to `FAKE_LOG`. `file://` cannot answer a 503
  or time out, and a 404 versus any other failure is exactly the distinction
  that decides between installing unverified and refusing.

Case 12 also pins the release job's digest command (`sha256sum runnerctl >
runnerctl.sha256`) and its upload line in `.github/workflows/ci.yml`, and
makes its digests with that command — so a change to the job that would
publish something `upgrade` cannot read turns this gate red.

## release

`release: release-please`. Nobody bumps `RUNNERCTL_VERSION` or writes
`CHANGELOG.md` in a feature PR, which is what keeps concurrent PRs from
conflicting on either. Instead the `release` job in `.github/workflows/ci.yml`
runs `googleapis/release-please-action` on every push to `main` once `gates`
is green (`release-please-config.json`, `.release-please-manifest.json`):

- it opens or force-refreshes one PR, `chore(main): release X.Y.Z`, on branch
  `release-please--branches--main`, computing the bump from the conventional
  commits since the last release: `feat:` → minor, `fix:`/`perf:` → patch,
  `BREAKING CHANGE` → minor while < 1.0 (`bump-minor-pre-major`). `chore:`,
  `docs:` and the rest do not bump on their own; `docs:` is listed in the
  changelog, the others are hidden. A commit with none of these is ignored.
  Squash-merge with a conventional title — the squash commit subject is what
  it parses;
- that PR changes exactly three things: the `RUNNERCTL_VERSION` line (through
  the annotation), `CHANGELOG.md`, and the manifest;
- merging it tags `vX.Y.Z`, publishes a GitHub release, and attaches the
  `runnerctl` file to it after asserting `runnerctl version` prints the tag —
  and, since GHR-84, `runnerctl.sha256` beside it, written from the same
  checked-out bytes with `sha256sum runnerctl > runnerctl.sha256`. `upgrade`
  verifies a release download against that file; a release without one
  installs `not verified`, and a digest that cannot be read for any reason
  other than a 404 refuses the upgrade.
  The attach step checks out **the tag**, not the run's own commit, and the
  job runs one at a time (`concurrency`, never cancelling a run in progress)
  — see the trap below;
- `bootstrap-sha` in the config is the commit carrying 0.3.1, the last
  hand-stamped version, so the first release PR only lists what came after
  it. It is inert once a `vX.Y.Z` tag from release-please exists.

Two things the automation cannot do for you:

- Who authors the release PR decides whether its gates start on their own.
  With the default `GITHUB_TOKEN` it is `github-actions[bot]`, and its
  `pull_request` runs are **not** suppressed — every refresh of the release
  branch creates one — but each is created `action_required` behind a
  "1 workflow awaiting approval" banner and runs only once someone clicks
  approve. The fork-PR approval policy does **not** release them: GHR-35
  moved it from `first_time_contributors` to
  `first_time_contributors_new_to_github` on 2026-09-13 on that theory, and
  runs created on 09-14, 09-24 and through October were still held (GHR-69;
  every green release-PR run in that window is `run_attempt: 2`, triggered by
  the human who approved it). Read the stuck ones with
  `gh api 'repos/runnane/runnerctl/actions/runs?status=action_required'`.

  The fix is the PR's identity, not a setting. The `release` job mints an
  installation token with `actions/create-github-app-token` when the
  repository variable `RELEASE_APP_ID` is set, using the secret
  `RELEASE_APP_PRIVATE_KEY`, and hands it to release-please; the PR is then
  authored by that app and its runs are ordinary. The app must be installed
  on this repository with **Contents** and **Pull requests** read and write —
  without Contents it cannot push the release branch or create the tag, and
  the job fails on `main` rather than falling back. The fallback to
  `GITHUB_TOKEN` applies only when the variable is absent.

  Whatever the release PR's checks show, the bumped script is also gated by
  the `push` run on `main` after the merge, which needs no approval and where
  a red `gates` blocks the tag (`release` needs `gates`).
- The repository setting *Settings → Actions → General → Workflow permissions
  → Allow GitHub Actions to create and approve pull requests* must be on, or
  the action fails with `GitHub Actions is not permitted to create or approve
  pull requests`.

**Trap — the run that creates a release is not necessarily the release
commit's (GHR-106).** release-please acts on the branch, so once the release PR
has merged, whichever `push` run reaches the release step first creates the tag
and the release and is the only run that gets `release_created: true`. On
2026-10-13 four merges landed within 23 seconds; the run for an *earlier*
commit created `v0.20.0`, checked out its own commit (still stamped 0.19.0),
failed the version assertion — correctly, it refused the wrong bytes — and
attached nothing. The later runs saw the release already created and skipped
the attach, so `v0.20.0` shipped with no asset and
`releases/latest/download/runnerctl`, the default `UPGRADE_URL`, answered 404.
The checkout now names `steps.release.outputs.tag_name`. Three things follow
for whoever merges:

- **After a release PR merges, read the release's assets**, not the run's
  colour: `gh release view vX.Y.Z --json assets --jq '.assets[].name'` must
  print `runnerctl` and `runnerctl.sha256`. A green run on the release commit
  proves nothing here — that run may not be the one that created the release.
- A release missing its asset is repaired by hand from the tag
  (`git show vX.Y.Z:runnerctl`, check `version`, `gh release upload`), never
  by re-running a job: no later run gets `release_created` for it again. The
  digest is repaired the same way and from the same bytes: `sha256sum
  runnerctl > runnerctl.sha256` beside the file taken from the tag, then
  upload both. A digest made from any other copy refuses every upgrade to
  that release.
- With the `concurrency` group, a release job that is still *waiting* when a
  newer push queues behind it is replaced by the newer one and shows as
  cancelled. That is expected and loses nothing: `gates` for that commit has
  already run, and the surviving job does the same work on the same branch.

`runnerctl upgrade` defaults to the latest tagged GitHub release, so hosts
only ever pick up released behaviour under its correct version stamp.
`--ref vX.Y.Z` pins a specific release; `--ref <branch>` (e.g. `main`) falls
back to fetching that ref's raw file for a host that wants to track main
ahead of a release, accepting that its version number then lags its bytes
between a feature merge and the release PR merge.
