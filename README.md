# runnerctl

Manage self-hosted GitHub Actions runner slots on a Linux host from one
self-contained bash script.

Runners installed with GitHub's `svc.sh` are plain systemd services
(`actions.runner.<scope>.<name>.service`). `runnerctl` discovers them and applies
a role **profile** — memory caps, restart policy, an on-device
`EnvironmentFile` for secrets — as systemd drop-in overrides, so the generated
unit files are never hand-edited and the settings survive a runner reinstall.
It also reports what each slot is doing and scales the active pool up or down.

Nothing site-specific is in the script: hostnames, memory sizes for your boxes,
secret-file paths and templates live in an optional config file on each host.

## Install

One command, for a fresh host or one that already has any version of
`runnerctl` on it:

```sh
curl -fsSL https://github.com/runnane/runnerctl/releases/latest/download/runnerctl | sudo bash -s -- install
```

The script downloads itself, checks that the copy parses and carries a
version, and puts it at the existing install's location (or
`/usr/local/bin/runnerctl`) by staged copy and rename, so a running invocation
is unaffected. Then it runs the installed file's `version` — the proof comes
from the receiver. Rerunning it is the upgrade; it will not downgrade unless
you pin a version with `--ref vX.Y.Z`; identical bytes are a no-op.

If the existing file is an older, inline-configured `runnerctl` (no version
line), `install` runs [`migrate`](#migrating-from-an-inline-configured-runnerctl)
**first** and refuses to replace the old file if the migration does not
verify, so no site value is lost. `--no-migrate` skips that and keeps the old
file as `runnerctl.legacy`; `--dry-run` reports what would happen;
`--prefix DIR` picks the location.

Under `sudo` the invoking user's `PATH` is not consulted (`secure_path`), so a
copy living in their `~/.local/bin` or `~/bin` would go unnoticed. `install`
looks in those two directories of `$SUDO_USER`'s home (of `$HOME` otherwise)
when nothing is on `PATH`: a copy found there is migrated or version-checked
like any existing install, the new file still lands at `/usr/local/bin`, and
the old one is renamed `runnerctl.legacy` (pre-config) or `runnerctl.retired`
(versioned) so it cannot keep shadowing the new one. `--dry-run` shows the
found path and what would happen to it.

Prefer to read before you run? Same thing in two steps:

```sh
curl -fsSL https://github.com/runnane/runnerctl/releases/latest/download/runnerctl -o runnerctl
less runnerctl && sudo bash runnerctl install
```

Requirements: bash 4+, systemd, `curl` (for `install`/`upgrade`), and `sudo`
for anything that writes under `/etc` or talks to `systemctl` (or run it as
root). Only `install` works when the script is read from a pipe; every other
command needs it installed.

## Usage

```
runnerctl [--config PATH] <command> [args]

runnerctl status [--json] [--watch|-w] [--interval N] [--once] \
                 [--color auto|always|never] [--stall-after N]
runnerctl watch  [--interval N] [--color auto|always|never] [--stall-after N]
runnerctl apply  [--profile NAME] [--max 26G] [--high 25G] \
                 [--restart-sec N] [--env-file PATH] [--restart] \
                 [--when-idle] [--timeout N] [<unit|slot-index|name> ...]
runnerctl scale N [--profile NAME] [--max 26G] [--high 25G] \
                  [--restart] [--when-idle] [--timeout N]
runnerctl env-init [--profile NAME] [--env-file PATH]
runnerctl start|stop|restart [--when-idle] [--timeout N] \
                             [--if-stalled] [--stall-after N] \
                             [<unit|slot-index|name> ...]
runnerctl drain [--timeout N] [<unit|slot-index|name> ...]
runnerctl enable|disable <unit|slot-index|name>
runnerctl logs [<unit|slot-index|name>] [-f|--follow] [-n N] \
               [--since WHEN] [-g PATTERN]
runnerctl remove-limits [<unit|slot-index|name> ...]
runnerctl reap [--dry-run] [<unit|slot-index|name> ...]
runnerctl health [--quiet] [--max-restarts N] [--stall-after N] [--restart-stalled]
runnerctl profiles
runnerctl config-example
runnerctl migrate [--from PATH] [--output PATH] [--dry-run]
runnerctl install [--prefix DIR] [--ref <branch|tag>] [--no-migrate] [--dry-run]
runnerctl upgrade [--check] [--ref <branch|tag>]
runnerctl version
```

`status` shows each slot's state and how long it has been in it (`SINCE`),
which profile it carries (`PROFILE`, read from its drop-in — `—` if it has
none), memory cap/current/peak usage, restart policy, env file and the job it
is currently working on, with how long that job has been running — or, for
an idle slot, how long it has been idle and how many jobs it has finished
since it started:

```
runnerctl 0.7.0 — Host: 16 cores, 62Gi RAM, 48Gi available

IDX RUNNER                 PROFILE  ACTIVE                              SINCE    ENABLED   MAX    HIGH   USED        PRESS  RESTART  ENVFILE WORKING-ON
0   org.host-1             ci       active/running                     3d 4h    enabled   26.0G  25.0G  3.1G/24.9G  0.4%   always   —       my-app:test (12m)
1   org.host-2             ci       active/running ↻3 (last: oom-kill)  2d 7h    enabled   26.0G  25.0G  128M        0.0%   always   —       idle 2h31m (7 jobs)
2   org.host-3             deploy   inactive/dead                      6d       disabled  —      —      —           —      always   —       —
```

The header leads with the version of the `runnerctl` that is running — each
host only picks up a new one when `upgrade` runs, so on a fleet that is
otherwise only visible through a second command — then the host's cores and
memory.

`ACTIVE` folds in a restart count (`↻3`) when systemd has restarted the unit
since it was last started by hand (`NRestarts`, which `systemctl
start`/`restart` resets — the right scope for a crash loop
`StartLimitIntervalSec=0` deliberately never parks `failed`). When there have
been restarts and the *current* invocation's `Result` is `success` — so
nothing else here says why the last one happened — the journal is checked for
the reason and, when found, shown as `(last: oom-kill)`, `(last: exit-code
137)` or `(last: signal KILL)`; needs the same journal access as
`WORKING-ON`, and says nothing when it cannot be read or found. When the
current invocation's `Result` is itself not `success`, that is shown instead,
unparenthesised — e.g. `failed/failed ↻3 oom-kill`.

`USED` becomes `current/peak` (`3.1G/24.9G`) when the host's systemd reports
`MemoryPeak` (>= 254); on an older systemd, or a unit with memory accounting
off, it stays current-only, silently.

`PRESS` is the slot's memory pressure — the kernel's PSI `full avg10` from
the cgroup's `memory.pressure`: the share of the last ten seconds that
*every* task in the slot spent stalled waiting for memory. It is what
`MemoryPeak` cannot tell you: whether the job running now is working or
being throttled at `MemoryHigh`. Yellow from `PRESSURE_WARN_PCT` (config,
default 10), red from `PRESSURE_CRIT_PCT` (default 50), `—` where the
cgroup has no such file (a stopped slot, cgroup v1). A `STALLED` job with a
high `PRESS` is starved, not hung — raise the cap or fix the job rather than
restarting the slot. The cgroup's `memory.events` counters (`high`: times
`memory.high` throttled it, `max`: times it hit `memory.max`, `oom_kill`:
processes the OOM killer took, all since the unit started) are read at the
same time and reported in `--json` and in `health`'s line.

`SINCE` is measured from systemd's active-enter timestamp for a running slot
and from its inactive-enter timestamp for a stopped or failed one (`—` for a
slot that has never started).

`WORKING-ON` is read from the slot's journal — the runner's `Running job:` /
`completed with result:` lines — so it needs journal read access (the
`systemd-journal` group, or root); it is stable for the whole job, including
between steps and for container jobs. The repository prefix and the job
runtime (the age of the slot's `Runner.Worker`, spawned once per job) are
added from `/proc` when `status` runs as the runner's user or root;
otherwise the cell is the job name alone, timed from the journal line. An
idle slot shows the time since its last `completed with result:` line and
the number of jobs it has completed since the unit last started (`idle 2h31m
(7 jobs)`), or the time since the unit started when it has not finished one
yet (`idle 41m (no jobs yet)`) — the figure that says whether a pool is
oversized. A running slot whose journal cannot be read shows `(no access)`,
or `idle ?` when `/proc` is readable but the journal is not, with a one-line
hint under the table — `—` means only that the slot is not running.

A job that has been running for `STALL_SEC` seconds or more — `3600` (1 h)
by default: no job on a build pool legitimately runs that long, so past it
the runner is wedged, not slow — is flagged in the cell (`my-app:build
(1h33m) STALLED`) with one `note:` line under the table naming the
threshold. Raise `STALL_SEC` in the config for a pool with longer jobs (`0`
turns the flag off), or pass `--stall-after N` (seconds) for one run. Stall
detection needs the job's runtime, so it has the same access needs as the
runtime itself: the journal, or a visible `Runner.Worker`. What to do about
a stalled job is `restart --if-stalled`, below.

An idle slot whose cgroup still holds processes that are not the runner's
own — a dev server, a file watcher, a `node` child that ignored SIGTERM when
its step ended — shows them as `idle 2h31m (7 jobs) +3 leaked`, in yellow,
with a `note:` line under the table. They count against the slot's
`MemoryMax` until something kills them, and until now that something was
the next restart of the whole slot. Leaks are only counted while the slot is
idle (a running job's processes cannot be told from them) and only when
`status` can read the cgroup — root or the runner's user; the runner's own
tree (`runsvc.sh`, `RunnerService.js`, `Runner.Listener`/`Worker`/`PluginHost`)
is never counted, and `RUNNER_OWN_PATTERN` in the config extends that for an
image that wraps the runner differently. Containers a job starts with
docker live under the docker daemon's cgroup, not the slot's: neither the
memory cap nor this count sees them.

### Killing what a job left behind: `reap`

`runnerctl reap [--dry-run] [<slot> ...]` (default: every slot) kills exactly
the leaked processes of an idle slot and nothing else — `SIGTERM`, then
`REAP_GRACE_SEC` (config, default 5 s) later `SIGKILL` for whatever is still
there — so the Listener keeps running and the slot never leaves the pool:

```
$ sudo runnerctl reap
example.slot-1: busy (my-app:test, 12m) — skipped, a running job's processes are not leaks
example.slot-2: reaped 2 leaked process(es): 4242/node, 4243/esbuild — SIGKILL needed for pid 4243
example.slot-3: not running — nothing to reap
```

A busy slot is skipped, never signalled; `--dry-run` lists what would go.
It needs to see the cgroup (root or the runner user) and the journal to
know the slot is idle, and dies with a hint otherwise. For leaks that come
back every job, fix the workflow step; `reap` from cron is the stopgap.

### Colour

When stdout is a terminal the table is coloured by meaning, so a wedged or
throttled slot stands out of a `watch` at a glance: `ACTIVE` green while
running cleanly, yellow when active but restarted (or with a non-`success`
result, or still `activating`), red when not active; `ENABLED` dimmed for a
disabled slot; `USED` yellow from 90 % of `HIGH` and red once the slot has
reached it (it is being throttled); `WORKING-ON` dimmed while idle, green
while a job runs and bold red when `STALLED`; the `note:` lines yellow or
red. `--color auto` is the default — colour iff stdout is a tty and
`NO_COLOR` is unset or empty ([no-color.org](https://no-color.org)) —
`--color always` keeps it through a pipe (`| less -R`) and `--color never`
drops it. Padding counts visible characters, so a painted table and a plain
one line up identically; `status --json` and `health` are never coloured.

`apply` and `remove-limits` can be pointed at one or more slots instead of
every discovered one — `runnerctl apply --profile deploy 2` or `runnerctl
apply 0 example.slot-2` — which is what lets one host run a `ci` pool and a
`deploy` runner side by side without one profile clobbering the other's
drop-in. With no targets, both act on every slot, as before.

Slots are addressed by unit name, by the `IDX` column, or by the `RUNNER`
column's short name — an unambiguous prefix or substring of it also works
(e.g. `slot-1` for `example.slot-1`).

### Live view: `watch`

`runnerctl watch` (or `status --watch` / `status -w`) redraws the same table
in place every 2 seconds — `--interval N` for another whole number of
seconds — until Ctrl-C, with a header line carrying the host, the time of
the redraw and the interval. It is what you keep open while a `drain` or an
`apply --restart --when-idle` rolls through the pool, or while a capped slot
creeps up on its `MemoryHigh`. It is a native loop rather than procps
`watch`, which is not on every runner host and mangles the `—` cells: each
frame is rendered first and written in one go, so it does not flicker, and
the config is loaded once, not per tick. Everything is read live except the
journal-derived `WORKING-ON` cells, which are refreshed every tenth redraw to
keep the `journalctl` cost down — a job start or end shows up within
10 × interval seconds. It needs a terminal: with stdout redirected it exits 1
and points at `status`; `status --once` is the plain one-shot table.

### Machine-readable output: `status --json`

`runnerctl status --json` prints the same facts as one JSON object, for a
host-inventory collector, a dashboard or an alerting cron that would
otherwise have to scrape the table's columns — whose set and widths change
with every new feature. Raw bytes and epoch seconds, not `26.0G` / `3d 4h`;
`null` wherever the table prints `—` (including `infinity` and `[not set]`
memory values); no `jq` needed to produce it, and the table and the JSON are
rendered from one collector, so they cannot disagree on a value:

```json
{"runnerctl":"0.7.0","host":{"cores":16,"mem_total":64424509440,"mem_available":51539607552},
 "slots":[
  {"idx":0,"unit":"actions.runner.org.host-1.service","name":"org.host-1",
   "active":"active","sub":"running","enabled":"enabled",
   "memory_max":27917287424,"memory_high":23622320128,"memory_current":3328599552,"memory_peak":26743545600,
   "restart":"always","env_file":null,"since":1757622000,
   "restarts":0,"result":"success","last_restart_reason":null,"profile":"ci",
   "job":{"repo":"my-app","name":"test","since":1757707200,"stalled":false},
   "idle_since":null,"jobs_completed":null,"working_on_access":"ok","leaked_procs":null,
   "memory_events":{"high":4,"max":1,"oom_kill":0},
   "memory_pressure":{"full_avg10":0.41,"full_avg60":0.12,"full_total":9876543}}
]}
```

Keys, per slot: `idx`, `unit`, `name` (the `RUNNER` column), `active`,
`sub`, `enabled` (systemd's `ActiveState` / `SubState` / `UnitFileState`),
`memory_max`, `memory_high`, `memory_current`, `memory_peak` (bytes),
`restart` (the `Restart=` policy), `env_file` (the raw `EnvironmentFiles`
value), `since` (epoch second the slot entered its current state — what
`SINCE` counts from), `restarts` (`NRestarts`), `result` (the current
invocation's `Result`), `last_restart_reason` (`oom-kill` / `exit-code N` /
`signal NAME`, looked up under the same condition as the table's
`(last: …)`, null otherwise), `profile` (from the drop-in), `job` — `{"repo",
"name", "since", "stalled"}` while a job is in flight (`repo`, `name` and
`since` null when unknown; `stalled` true or false against `STALL_SEC` /
`--stall-after`, null when the runtime is unknown), null when idle or
stopped — `idle_since` and `jobs_completed`
(epoch second of the last completion and the count since the unit started,
0 and the unit's own start when nothing has finished yet; null while busy or
stopped), and `working_on_access`: `"ok"`, `"no-journal"` (only `/proc`
could be read, so `job` may be present but `idle_since` never is) or
`"no-access"` — the note under the table, per slot, and `leaked_procs`: how
many processes a finished job left in an idle slot's cgroup (the table's
`+N leaked`; `0` when none, null while busy or when the cgroup cannot be
read), `memory_events` (`{"high","max","oom_kill"}` from the cgroup's
`memory.events`, counts since the unit started) and `memory_pressure`
(`{"full_avg10","full_avg60","full_total"}` from `memory.pressure` —
percentages and total stall microseconds; the `PRESS` column is
`full_avg10`), each object null when the file could not be read. `host`
carries `cores`
(`nproc`) and `mem_total` / `mem_available` (bytes, from `/proc/meminfo`);
`runnerctl` is the version of the script that produced the object, for
inventorying a fleet.
`--json` is one-shot and refuses `--watch`; poll it instead.
### Health checks for cron / uptime monitors: `health`

`runnerctl status` always exits 0, so nothing on the host can notice "slot
2 has been `inactive/dead` since Tuesday" without parsing the table. `health`
closes that: exit 0 with `ok: N slot(s) healthy` when every enabled slot is
`active`/`activating`/`reloading`, no slot has restarted `--max-restarts`
times (default 5) or more since its last manual start, no job has been
running for `--stall-after` seconds (default `STALL_SEC`, 1 h) or more, no
idle slot has leaked processes, and no slot is under full memory pressure
of `PRESSURE_CRIT_PCT` (50 %) or more; otherwise one line per problem on
stdout and exit 1:

```
example.slot-2: enabled but inactive/dead since 3d
example.slot-1: 7 restarts since last start (oom-kill)
example.slot-3: stalled — job my-app:build running 1h33m, longer than 1h (--stall-after 3600)
example.slot-4: 2 leaked process(es) left by finished jobs (node, esbuild) — runnerctl reap 3
example.slot-5: under full memory pressure 63.2% (avg10, PRESSURE_CRIT_PCT=50) — throttled at MemoryHigh (4 times so far), see USED vs HIGH
```

`--quiet` drops the output either way and keeps just the exit code, for a
cron line like:

```sh
runnerctl health --quiet || alert "runner pool unhealthy on $(hostname)"
```

`--restart-stalled` makes `health` act on the one problem it can fix on its
own: a stalled slot is restarted on the spot (the same `systemctl restart`
as `restart --if-stalled`, so it needs root or sudo) and its line ends
`— restarted` (or `— restart FAILED`). The exit code is still 1, so a probe
records the event once; the next run is clean. Everything else `health`
does stays read-only. A root cron that self-heals the pool:

```sh
*/5 * * * *  runnerctl health --quiet --restart-stalled
```

A disabled, scaled-down slot is not a problem — only an *enabled* slot that
is not running counts. The restart count is systemd's `NRestarts`, which
resets on `systemctl start`/`restart`: it is restarts since the unit's last
manual start, not a rolling "in the last hour" window — there is no cheap
way to bucket it by wall-clock time without walking the journal for every
slot, so this reports what `systemctl show` already tracks. When a restart
count trips the threshold and the journal knows why the *last* one happened,
the reason (`oom-kill`, `exit-code N`, `signal NAME`) is appended, same as
the `ACTIVE` column in `status`. The stall check reads the same journal
`status` does, so a `health` run without journal access (or a visible
`Runner.Worker`) cannot see a stalled job — run it as root or in the
`systemd-journal` group. A host with no runner units at all still gets the
usual `no 'actions.runner.*.service' units found` error (exit 1, not
suppressed by `--quiet`).

### Graceful restart and stop: `--when-idle` and `drain`

A plain `restart`, `stop`, `apply --restart` or `scale` acts on every
targeted slot immediately, and a slot mid-job fails that job on GitHub with
"The runner has received a shutdown signal". `--when-idle` makes the same
commands wait for each slot's `WORKING-ON` to read `idle` (or `—`, not
running) before acting on it, one slot at a time, so the pool keeps capacity
while a profile is rolled out:

```sh
runnerctl apply --profile ci --max 24G --restart --when-idle   # roll the pool
runnerctl restart 0 --when-idle                                 # one slot
runnerctl scale 1 --when-idle                                   # stop slot 2+ once idle
runnerctl drain                       # = stop --when-idle: host maintenance
runnerctl drain example.slot-2 --timeout 600
```

While a slot is busy it prints `waiting for example.slot-1 (my-app:test,
12m) …` (again every minute) and polls every 5 seconds (`POLL_SEC` in the
config). `--timeout N` (seconds, default 1800, `WAIT_TIMEOUT` in the config)
gives up: the slot it was waiting on is left alone, nothing after it is
touched, the slots already handled stay handled, and the command exits 1
listing all three groups. Nothing is ever force-killed. `start` accepts
`--when-idle` and ignores it. A slot whose journal cannot be read (`status`
shows `(no access)`) cannot be proven idle, so `--when-idle` refuses at once
with the same hint `status` gives — run it with journal read access or as
root.

**Best-effort, not a guarantee.** Between the idle check and the `systemctl`
call the Listener can pick up a new job (the window is a few hundred
milliseconds), and the runner has no "stop accepting jobs" switch short of
the GitHub API or UI. For a guaranteed drain, first make GitHub stop routing
work to the runner — change its labels to ones no workflow requests, or
disable it in the organisation's runner settings — then `runnerctl drain`.

### Killing a stalled job: `restart --if-stalled`

`--when-idle` never force-kills, by design. `--if-stalled` is the opposite
tool for the opposite situation: `runnerctl restart --if-stalled
[--stall-after N] [<slot> ...]` acts on exactly the slots whose job is
`STALLED` (running `STALL_SEC` seconds or more — the same fact `status`
shows) and skips every other one with a line saying why:

```
$ runnerctl restart --if-stalled
example.slot-1: stalled — my-app:build, 1h33m, longer than 1h — restarting
example.slot-2: not stalled (idle 2h31m (7 jobs)) — skipped
example.slot-3: not running — skipped
restart done (1 stalled slot(s)).
```

It restarts the whole unit rather than signalling the job's processes: the
cgroup goes as one, `Restart=always` brings the runner back in seconds, and
GitHub marks the job failed — a partial kill would leave the Listener
believing it is still busy. `stop --if-stalled` works the same way (the slot
stays down); `start` refuses the flag, and so does combining it with
`--when-idle`. With nothing stalled it prints `no stalled slot — nothing
restarted.` and exits 0. A slot whose journal cannot be read is a refusal,
not a guess — run it with journal access or as root.

### Profiles

Two profiles are built in so the tool is usable with no config at all:

| profile  | memory cap        | restart | EnvironmentFile             |
| -------- | ----------------- | ------- | --------------------------- |
| `ci`     | 26G max / 25G high| 10 s    | none                        |
| `deploy` | none              | 15 s    | `/etc/runnerctl/deploy.env` |

`ci` is a memory-capped build/test pool: a runaway job is contained to its own
cgroup. What happens at the cap is deliberate: every drop-in sets
`OOMPolicy=continue`, so when the kernel OOM-kills the step that outgrew
`MemoryMax` only that step dies — it exits 137, the job fails with a readable
log, and Runner.Listener stays up. systemd's default (`stop`) would take the
whole unit down instead, `Restart=always` would bring it back, and GitHub
would report "runner lost communication" with no log — the `↻N (last:
oom-kill)` churn `status` shows on an older install. `MemorySwapMax=0` keeps
the cap firm (a capped job cannot swap out to stay under it and thrash), and
`MemoryHigh` sits 1G under the cap on purpose: `memory.high` throttles rather
than kills, and a build crawling in a wide throttle band for hours shows up as
a STALLED job, which is worse for CI than a fast failure. `Restart=always`
still brings a slot back from anything else. `deploy` is an uncapped,
long-lived runner whose secrets come from a root-owned file on the box rather
than from GitHub Actions secrets — the point being to shrink the blast radius
of a runner that can reach production.

Flags (`--max`, `--high`, `--restart-sec`, `--env-file`) override a profile's
values for one invocation.

Typical baselines:

```sh
# CI host: two active slots, capped
runnerctl scale 2 --max 26G --high 25G

# Deploy box: scaffold the secrets file, fill it in, then apply
runnerctl env-init --profile deploy
sudoedit /etc/runnerctl/deploy.env
runnerctl apply --profile deploy --restart
```

`apply` refuses to write a profile that names an `EnvironmentFile` which does
not exist yet, because the unit would then fail to start. `env-init` never
overwrites an existing file.

### Config file

`runnerctl` reads `/etc/runnerctl/config` if present (override with
`RUNNERCTL_CONFIG=` or `--config PATH`). It is plain bash and is sourced, so
the script enforces: owned by root or by the invoking user, not writable by
any other group (unless that group is gid 0), and not world-writable. It also
validates the config-settable knobs after sourcing — `DROPIN_NAME` must match
`^[A-Za-z0-9_-]+\.conf$`, `UNIT_GLOB` must be non-empty and contain no `/`, and
`DEFAULT_PROFILE` must match `^[A-Za-z0-9_]+$` — since a bad value here drives
privileged commands (`sudo rm`, `sudo tee`) built from it. Anything that fails
these checks is refused with the exact reason and the fix.

The config can set any default (`DROPIN_NAME`, `DEFAULT_PROFILE`, `UPGRADE_URL`,
`UNIT_GLOB`) and define profiles as functions. A `profile_<name>()` function
sets `PROFILE_DESC`, `MEM_MAX`, `MEM_HIGH`, `RESTART_SEC`, `ENV_FILE` and
optionally `ENV_TEMPLATE`; an `env_template_<name>()` function prints the
placeholder file that `env-init` writes. A config-defined profile shadows a
built-in of the same name, and new names become new profiles.

```sh
runnerctl config-example | sudo tee /etc/runnerctl/config   # then edit
runnerctl profiles                                          # see what resolved
```

[`config.example`](config.example) is the same output, checked in for browsing.
Keep real hostnames, paths and secret names in the config on the host; keep
the config out of any repository.

### Migrating from an inline-configured runnerctl

Earlier versions of this script carried the site values inline — the drop-in
name, each profile's memory caps and env-file path, the secrets template — and
had no config file or version. Overwriting such an install with the current
script would silently replace those values with the generic built-ins.
`migrate` lifts them out first:

```sh
runnerctl migrate --dry-run   # show the config it would write
runnerctl migrate             # write /etc/runnerctl/config
```

It reads the installed script (`--from PATH` for a copy elsewhere), turns each
inline profile into a `profile_<name>()` and the inline template into
`env_template_<name>()`, and keeps the old `DROPIN_NAME` so the new script goes
on managing the *same* drop-in file rather than adding a second one beside it.
It then reads the drop-ins live under `/etc/systemd/system/<unit>.d/`, and
where they disagree with the script — someone ran `apply --max 24G` once — the
**live** value wins and the difference is printed. Any other drop-in in the
same directory that sets the same keys is flagged.

The last step is the proof: for every unit it renders the drop-in from the
generated config and compares it with the live file (comments aside), and
exits non-zero listing the differences if any unit does not reproduce. It never
overwrites an existing config (it writes `config.migrated` beside it and shows
the diff), never reads the secrets file itself — only its path moves — and is
safe to run repeatedly.

### Self-upgrade

```sh
runnerctl upgrade --check      # report installed vs available
runnerctl upgrade              # install the latest tagged release
runnerctl upgrade --ref v0.1.0 # pin a specific release
runnerctl upgrade --ref main   # track main instead of tagged releases
```

`upgrade` downloads the script from `UPGRADE_URL` (default: this repository's
latest GitHub release asset), checks that it parses and carries a
`RUNNERCTL_VERSION`, and replaces the installed file by rename — so a running
invocation is unaffected. It will not downgrade unless `--ref` is given, and
it uses `sudo` only when the install location is not writable. `--ref
vX.Y.Z` pins that release's asset; `--ref <branch or commit>` (e.g. `main`)
fetches the raw file at that ref instead, for hosts that want to track it
ahead of a release. Point `UPGRADE_URL` at a fork or a mirror in the config
file to upgrade from somewhere else.

Versions are cut by [release-please](https://github.com/googleapis/release-please)
from the conventional-commit history: each merge to `main` refreshes a release
PR, and merging that PR bumps `RUNNERCTL_VERSION`, writes [`CHANGELOG.md`](CHANGELOG.md),
tags `vX.Y.Z` and publishes a GitHub release with the script attached. Hosts
on the default `UPGRADE_URL` only ever pick up a tagged release; `--ref main`
opts a host into the next version's changes under the last version's tag,
and `--ref vX.Y.Z` pins one explicitly.

### What it writes

One drop-in per runner unit, `/etc/systemd/system/<unit>.d/10-runnerctl.conf`:

```ini
# Managed by runnerctl (profile: ci) — DO NOT EDIT BY HAND.
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
OOMPolicy=continue
MemoryHigh=25G
MemoryMax=26G
MemorySwapMax=0
```

`remove-limits` deletes the managed drop-ins again. `scale` stops and disables
slots beyond `N` but never deregisters them from GitHub — that needs a removal
token and is irreversible, so it stays a manual step.

## Development

```sh
make gates   # shellcheck + config.example drift check + smoke + stubbed-systemd sim
make sim     # just the stubbed-systemd cases (tests/run.sh)
```

See [`.agents/gates.md`](.agents/gates.md) for what each gate covers and how
the stubbed-systemd harness exercises every systemd-touching command without
root (and how to add a case).

## License

[MIT](LICENSE)
