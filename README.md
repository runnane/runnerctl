# runnerctl

Manage self-hosted GitHub Actions runner slots on a Linux host from one
self-contained bash script.

Runners installed with GitHub's `svc.sh` are plain systemd services
(`actions.runner.<scope>.<name>.service`). `runnerctl` discovers them and applies
a role **profile** — memory caps, restart policy, an on-device
`EnvironmentFile` for secrets — as systemd drop-in overrides, so the generated
unit files are never hand-edited and the settings survive a runner reinstall.
It also reports what each slot is doing and scales the active pool up or down.

On a host that has no runners yet, [`provision`](#provisioning-runners) is what
creates those services in the first place — it installs and registers the
runners with GitHub, then the rest of the tool manages them.

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

## Provisioning runners

`install` installs **this script**. Nothing it does creates a runner — so on a
fresh box every other command used to stop at:

```
runnerctl: no 'actions.runner.*.service' units found on this host.
```

`provision N` is the step that was missing. It brings the host up to `N` runner
slots and hands over to `scale`/`apply`:

```sh
# A new CI box: two runners registered to an org, then capped and started
sudo runnerctl provision 2 --url https://github.com/your-org
sudo runnerctl scale 2 --max 26G --high 25G
```

What it does, per slot: fetches the [actions/runner](https://github.com/actions/runner)
release, **verifies the SHA-256 GitHub publishes with it**, unpacks a copy into
`/opt/actions-runner/<prefix>-<n>`, registers it with the runner's own
`config.sh --unattended`, and lets the runner's own `svc.sh install` write the
systemd unit. runnerctl never writes a unit file itself — the result is exactly
the units the rest of this tool already manages through drop-ins.

It is **idempotent against a target count**, like `scale`. `provision 4` on a
host with 2 slots adds two and leaves the existing ones untouched; `provision 2`
on a host with 4 changes nothing. It never deregisters a runner: removing one
from GitHub needs a removal token and is not automated.

### Credentials

The registration token can come from any of three places, checked in this order:

| how | when to use it |
| --- | --- |
| `--token <token>` | the token from **Settings → Actions → Runners → New self-hosted runner**. Valid one hour, registers any number of runners. Nothing long-lived touches the host. |
| `--pat <token>` or `$GITHUB_TOKEN` | a PAT that mints the registration token over the API. A classic PAT needs `repo` for a repo runner, `admin:org` for an org one. |
| the `gh` CLI | if `gh` is already logged in on the box, no flag at all. |

The PAT is handed to `curl` on **stdin**, through its own config format, so it
never appears in `/proc/<pid>/cmdline`. The *registration* token is passed to
`config.sh` as a command-line argument — that is GitHub's own documented
install, and it means the token is briefly visible in `ps` to other users on
the box. runnerctl itself never prints or stores it.

### Options worth knowing

- `--dry-run` — reads the release metadata and prints every step, changing
  nothing and needing no credentials.
- `--runner-version X.Y.Z` — pin the runner release; the default is the latest.
- `--sha256 SUM` / `--no-verify-checksum` — pin the digest by hand, or (last
  resort) install without one. A release whose checksum cannot be found is
  **refused** rather than trusted.
- `--labels a,b` — extra labels on top of the ones the runner sets for itself.
- `--name-prefix P` — runner names are `<prefix>-<n>`; the default prefix is the
  host's short name.
- `--runner-user U` / `--runner-root DIR` — the account the runners run as
  (default `github-runner`, created as a system user when missing) and where
  they live (default `/opt/actions-runner`). `config.sh` refuses to run as
  root, so the runner never does.
- `--url` — the org, repo or enterprise to register against. Set `RUNNER_URL`
  in the config file to stop repeating it on a host.

`runnerctl provision --help` lists all of them, and `runnerctl config-example`
shows the config-file defaults for every value except the credentials.

Provisioning is deliberately **excluded from `fleet`**: fanning it out would
copy a registration token to every host, and each host needs its own runner
names. Run it per host.

## Usage

```
runnerctl [--config PATH] <command> [args]

runnerctl provision N [--url URL] [--token TOK | --pat TOK] [--labels a,b] \
                      [--name-prefix P] [--runner-user U] [--runner-root DIR] \
                      [--runner-version X.Y.Z] [--sha256 SUM] [--replace] \
                      [--dry-run]
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
runnerctl kill [--dry-run] [--if-stalled] [--stall-after N] \
               [<unit|slot-index|name> ...]
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

The view is interactive, so a stalled or leaking slot can be dealt with from
the screen you are already looking at instead of leaving `watch`, reading
the IDX and typing a second command. `↑`/`↓` (or `j`/`k`) move a highlighted
cursor over the slot rows — it follows the slot's unit name, not its row
number, so a scaled pool does not move it — and a key acts on the selected
slot. Every action that changes something first shows a `y/n` line naming
the exact command it will run; `y` runs it (through `sudo`, like the
commands — the first one may prompt for a password), anything else cancels,
and the result becomes the status line under the legend:

| key | on the selected slot | runs |
| --- | --- | --- |
| `K` | kill the running job — the `STALLED` case. `SIGKILL` for the job's own processes, exactly as [`kill`](#killing-a-stalled-job-kill) does: the runner stays up and reports the job failed. Refused when no job is running; a slot wedged in its own stop, or one whose cgroup this user cannot read, is offered the unit kill instead | `kill -KILL <job pids>`, or `systemctl kill -s KILL <unit>` |
| `R` | restart the runner service — any active row; a warning line says so when a job is in flight | `systemctl restart <unit>` |
| `S` / `T` | stop / start the slot (stop carries the same warning while a job runs) | `systemctl stop\|start <unit>` |
| `P` | reap the `+N leaked` processes on an idle slot, exactly as `reap <IDX>` does | `kill -TERM …`, then `kill -KILL` for what survives |
| `L` | show `logs <slot> -n 50` in `$PAGER` (`less`; `q` returns to the table). No confirm — it changes nothing | `journalctl -u <unit> -n 50` |
| `q` | quit | |

The redraws keep coming at `--interval` while a confirm line is up, so the
table under it is current when you answer. On a terminal narrower than the
table the `MAX`, `HIGH` and `ENVFILE` columns are dropped, never
`WORKING-ON` — its `idle 2h31m (7 jobs)` is what tells you a slot is safe to
act on.

### Machine-readable output: `status --json`

`runnerctl status --json` prints the same facts as one JSON object, for a
host-inventory collector, a dashboard or an alerting cron that would
otherwise have to scrape the table's columns — whose set and widths change
with every new feature. Raw bytes and epoch seconds, not `26.0G` / `3d 4h`;
`null` wherever the table prints `—` (including `infinity` and `[not set]`
memory values); no `jq` needed to produce it, and the table and the JSON are
rendered from one collector, so they cannot disagree on a value:

```json
{"runnerctl":"0.7.0","host":{"name":"build-1","cores":16,"mem_total":64424509440,"mem_available":51539607552},
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
carries `name` (the host's own `hostname`, null when it cannot be read),
`cores`
(`nproc`) and `mem_total` / `mem_available` (bytes, from `/proc/meminfo`);
`runnerctl` is the version of the script that produced the object, for
inventorying a fleet.
`--json` is one-shot and refuses `--watch`; poll it instead.

`host.name` is what makes a saved payload self-describing — a file or a
monitoring record says which host produced it with no out-of-band label.
It is deliberately the host's *own* name rather than one a caller passes in:
where it disagrees with the alias something dialled to reach the box, that
disagreement is worth seeing.

Unlike the table, `--json` **never dies on a host with no runner units** — it
prints `"slots": []` and exits 0. A host drained to zero slots, or inventoried
before its runners are installed, is a legitimate state, and exiting non-zero
there would be indistinguishable from the host being unreachable. Typing
`runnerctl status` on such a box still gets the error, because that is
usually a wrong-box mistake rather than a fact worth recording.
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

### Restarting a stalled slot: `restart --if-stalled`

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

It restarts the whole unit rather than signalling the job's processes:
`Restart=always` brings the runner back in seconds and GitHub marks the job
failed. `stop --if-stalled` works the same way (the slot stays down); `start`
refuses the flag, and so does combining it with `--when-idle`. With nothing
stalled it prints `no stalled slot — nothing restarted.` and exits 0. A slot
whose journal cannot be read is a refusal, not a guess — run it with journal
access or as root.

**A restart is still a *graceful* stop, and a stalled step is precisely what
will not answer one** — see `kill` below for the case where it hangs.

### Killing a stalled job: `kill`

The unit GitHub's `svc.sh` installs carries `KillMode=process`,
`KillSignal=SIGTERM`, `TimeoutStopSec=5min`. So a `restart` signals only
`runsvc.sh`, which asks the Listener, which asks the Worker to cancel the
step — and a step that is genuinely wedged never answers. The unit sits in
`deactivating/stop-sigterm` for five minutes, systemd then kills the main
process only, and the job's processes are still in the cgroup. `status`
shows the slot mid-hang:

```
IDX RUNNER          PROFILE ACTIVE                    SINCE  ...  WORKING-ON
1   example.slot-2  ci      deactivating/stop-sigterm —      ...  my-app:build (49m)
```

`runnerctl kill [--dry-run] [--if-stalled] [--stall-after N] <slot> ...`
is the tool that actually ends the job. It `SIGKILL`s the job's own
processes — everything in the slot's cgroup that is not the Listener side of
the runner (`runsvc.sh`, `RunnerService.js`, `Runner.Listener`;
`RUNNER_LISTENER_PATTERN` extends that for an image that wraps the runner
differently) — and leaves the Listener alone, so it notices its Worker died,
reports the job failed to GitHub itself and takes work again in seconds. No
restart, no re-registration, and no other slot disturbed:

```
$ sudo runnerctl kill 1
example.slot-2: killed 2 process(es): 4100/Runner.Worker, 4101/node — the runner stayed up and reports the job failed
```

Three cases escalate to `systemctl kill -s KILL <unit>`, which signals every
process of the unit's cgroup whatever `KillMode` says, with `Restart=always`
bringing the slot back:

- the slot is already wedged in its own stop (`deactivating`) — there is
  nothing left to ask nicely;
- the cgroup cannot be read (neither root nor the runner user), so there are
  no pids to signal — systemd can do it without reading them;
- the Listener has not reported the job gone `KILL_GRACE_SEC` (config,
  default 10 s) after its Worker was killed — it is hung too. This is the
  case a plain `restart` cannot get out of at all.

`--dry-run` names what would go and sends nothing. A bare `kill` with no
target is refused — killing every slot's job at once is never what it means
— but `--if-stalled` (with `--stall-after N`, same rules as
`restart --if-stalled`) selects exactly the `STALLED` slots and then needs no
target:

```
$ sudo runnerctl kill --if-stalled
example.slot-1: not stalled (my-app:test (12m)) — skipped
example.slot-2: stalled — my-app:build, 1h49m, longer than 1h — killing
example.slot-2: killed 2 process(es): 4100/Runner.Worker, 4101/node — the runner stayed up and reports the job failed
kill done (1 stalled slot(s)).
```

### Several hosts from one place: `fleet status`

Everything above is one host. `fleet` runs the same tool from a central node
against every runner host in `FLEET_HOSTS`, over ssh:

```
$ runnerctl fleet status
HOST     IDX RUNNER          PROFILE  ACTIVE           SINCE  ENABLED  ...  WORKING-ON
build-1  0   org.build-1-a   ci       active/running   3d 4h  enabled  ...  my-app:test (12m)
build-1  1   org.build-1-b   ci       active/running   2d 7h  enabled  ...  idle 2h31m (7 jobs)
build-2  0   org.build-2-a   ci       active/running   6d     enabled  ...  my-app:lint (2m)
build-3  unreachable — ssh: connect to host build-3 port 22: No route to host
```

Set the inventory on the **central node only** — the runner hosts need no
fleet config, just `runnerctl` installed and an ssh login:

```bash
FLEET_HOSTS=(build-1 build-2 build-3)   # ssh aliases, or user@host
```

`runnerctl config-example` prints the whole block, including `FLEET_PARALLEL`
(how many hosts at once, default 8), `FLEET_TIMEOUT` (per-host seconds,
default 30), `FLEET_SSH_OPTS` and `FLEET_RUNNERCTL` (where the remote command
lives, if it is not on the ssh user's `PATH`).

**No privileges are needed for this.** `status` never asks for sudo, so an
ordinary unprivileged ssh login is enough; where the login cannot read the
journal, the per-slot `WORKING-ON` degrades exactly as it does locally rather
than failing.

**A host that does not answer is a row, never a fatal.** The other hosts still
report and the exit code is non-zero, so a monitor still notices. Three
outcomes are deliberately kept apart, because they call for different actions:

| row | meaning |
| --- | --- |
| `unreachable — …` | ssh could not reach the host. Nothing is known about it. |
| `timed out after Ns` | it did not answer inside `FLEET_TIMEOUT`. Nothing is known about it. |
| `remote exit N — …` | the host answered fine and its `runnerctl` exited non-zero. On a host with no runner units that is its own perfectly good message, not a fleet fault. |

When the hosts are not all on the same `runnerctl` version, a note says so
under the table — on a fleet that is otherwise invisible until something
behaves differently on one box.

`fleet status --json` gives one object with **each host's payload nested
unchanged**:

```json
{"fleet":[
  {"host_name":"build-1","reachable":true,"exit_code":0,"error":null,
   "status":{"runnerctl":"0.8.1","host":{"name":"build-1",…},"slots":[…]}},
  {"host_name":"build-3","reachable":false,"exit_code":255,
   "error":"unreachable — ssh: connect to host build-3 port 22: No route to host",
   "status":null}
]}
```

`host_name` is the alias the central node dialled; `status.host.name` is what
the host calls itself. They are separate on purpose — a disagreement between
them is worth seeing. `reachable` is false only for the two "nothing is known"
cases, so a remote error keeps it true.

Because each payload is nested rather than re-serialised, fleet mode needs no
JSON parser and `runnerctl` still depends on nothing beyond coreutils, awk,
systemd and curl.

**Fleet mode needs `runnerctl` installed on each host.** Piping the script over
ssh on every call would avoid that and remove version skew, but it pays a
transfer on every command to solve a problem a fleet-wide upgrade solves once,
and it would mean relaxing a deliberate refusal (`runnerctl` only accepts
`install` when read from a pipe). Keep the hosts levelled with `runnerctl
upgrade` instead.

#### One exit code for the fleet: `fleet health`

`health` is already the yes/no for cron and uptime monitors, but on a fleet it
is one cron entry and one monitor per host. `fleet health` reduces the whole
fan-out to a single exit code:

```
$ runnerctl fleet health
ok: 6 slot(s) healthy across 2 host(s)

$ runnerctl fleet health ; echo "exit $?"
build-1: example.slot-1: stalled — job my-app:test running 1h49m, longer than 1h (--stall-after 3600)
build-3: unreachable — ssh: connect to host build-3 port 22: No route to host
exit 1
```

Each problem keeps the wording the single-host command uses and gains its
host, so the format is the one you already read. `--quiet` drops the output
and keeps the exit code, for `runnerctl fleet health --quiet || alert`.

**A host that did not answer is a problem.** Exit 0 requires every host to
have been reached *and* reported healthy — a monitor that goes green because
a host dropped out of the fan-out is worse than no monitor at all.

`--max-restarts`, `--stall-after` and `--restart-stalled` are passed through
to each host. `--quiet` is not: the remote's output is where the problem lines
come from, so a quiet remote would leave nothing to report.

`--restart-stalled` restarts slots on the remote hosts, so it needs
passwordless sudo there. Without it the call fails fast and says so, per host
— it never hangs, because the fan-out runs ssh with `BatchMode=yes`.

#### Keeping the fleet on one version: `fleet upgrade`

A host only picks up a new `runnerctl` when `upgrade` runs on it, so a fleet
drifts quietly — it behaves two ways and nothing says so until something
misbehaves on one box. `fleet status` notices the drift; `fleet upgrade`
fixes it.

```
$ runnerctl fleet upgrade --check
build-1  0.8.1 -> 0.8.2  update available
build-2  0.8.2           up to date
build-3  —               unreachable — ssh: connect to host build-3 port 22: No route to host
3 host(s): 1 up to date, 1 would change, 1 unreachable or unclear

$ runnerctl fleet upgrade
build-1  0.8.1 -> 0.8.2  upgraded
build-2  0.8.2           up to date
2 host(s): 1 already level, 1 upgraded, 0 unreachable or unclear
```

`--check` writes nothing; it reports each host's installed and available
version and whether it would change. `--ref <branch|tag>` is passed through,
as it is for the single-host command.

**A host that fails is a reported row, never an abort.** A partly upgraded
fleet is the normal outcome of a flaky network, and which host is still
behind is exactly the thing you must not lose. The exit code is non-zero when
any host failed, so a cron job still notices.

An answer this does not recognise is shown verbatim rather than folded into
"up to date" — quietly reporting a host as level when it said something else
is what sends someone to the wrong box.

##### The sudo requirement

`upgrade` writes the installed script, which on a normal host needs root, so
**this is the first fan-out that needs passwordless sudo on each runner
host.** Grant it for the write only, e.g.:

```
# /etc/sudoers.d/runnerctl  (on each runner host)
# `upgrade` stages the new script beside the old one and swaps it in, so the
# write path is cp + chown + chmod + mv. Check the binary paths on your own
# distribution before pasting this — they are not the same everywhere.
%runnerctl ALL=(root) NOPASSWD: /usr/bin/cp, /usr/bin/chown, /usr/bin/chmod, /usr/bin/mv
```

Without it the call **fails fast and names the host** rather than hanging —
the fan-out runs ssh with `BatchMode=yes` precisely so a password prompt
cannot wedge it. Adjust paths and the group to your own hosts; nothing here
is site-specific on purpose.

If you would rather keep sudo out of it entirely, install `runnerctl`
somewhere the ssh user owns and point `FLEET_RUNNERCTL` at it — `upgrade`
writes directly when the destination is writable and never escalates.

#### Changing things: the mutating fan-out

`apply`, `scale`, `start`, `stop`, `restart`, `drain`, `kill`, `reap`,
`remove-limits`, `enable` and `disable` fan out too, with their own flags and
targets forwarded untouched:

```
$ runnerctl fleet restart --when-idle --host build-1 --host build-2
build-1: restart done.
build-2: restart done.
fleet restart: 2 host(s) ok, 0 failed
```

These differ from the read-only commands in three ways, all deliberate.

**One host at a time.** `FLEET_PARALLEL` is ignored for mutating commands.
Combined with the per-host `--when-idle` (one slot at a time *within* a host),
that bounds the blast radius to a single host at any moment. It is slow on a
large fleet; that is the right trade for something that can take CI capacity
down.

**`--host H`** narrows the target and is repeatable. It is validated against
`FLEET_HOSTS`, so a typo dies naming the host rather than silently doing
nothing.

**`stop`, `drain` and `disable` are refused fleet-wide** unless you pass
`--host H` or `--all-hosts`:

```
$ runnerctl fleet drain
runnerctl: 'fleet drain' across every host would take the whole pool's capacity
down at once — each host draining politely one slot at a time still lands them
all at zero together. Name the hosts with --host H (repeatable), or pass
--all-hosts if you do mean the entire fleet.
```

That refusal exists because per-host politeness **does not compose**. Every
host draining one slot at a time is still every host arriving at zero at
roughly the same moment. `restart` and `kill` are not gated — the unit comes
back — and nor are the commands that do not remove capacity.

Note that `--when-idle` stays *best-effort per host*, for the reason it always
was: between the idle check and the `systemctl` call the Listener can still
pick up a job, and the runner has no "stop accepting jobs" switch. A fleet
does not turn that into a fleet-wide guarantee — it gives you one such window
per host. For a guaranteed drain, change the runner's labels or disable it in
GitHub first.

##### sudo for the mutating commands

These run privileged commands on each host, so the ssh login needs
passwordless sudo for them. The set the fan-out actually uses:

```
# /etc/sudoers.d/runnerctl  (on each runner host)
# systemctl: start/stop/restart/enable/disable/daemon-reload
# mkdir + tee: write the managed drop-in;  rm: remove-limits
# kill: reap and kill;  test: the EnvironmentFile guard in apply/scale
# Check the binary paths on your own distribution before pasting this.
%runnerctl ALL=(root) NOPASSWD: /usr/bin/systemctl, /usr/bin/mkdir, \
    /usr/bin/tee, /usr/bin/rm, /usr/bin/kill, /usr/bin/test
```

Add the `upgrade` set from the previous section if you also run `fleet
upgrade`.

Without it the fan-out **fails fast and names the host**, with the remedy
appended to the row — it never hangs, because ssh runs with `BatchMode=yes`:

```
box-2: remote exit 1 — sudo: a password is required — the ssh login needs
passwordless sudo on that host; see the fleet section of the README for the
exact sudoers line
```

##### What does not fan out

- **`env-init` never will.** It writes an EnvironmentFile of secrets, and
  fanning it out means copying secrets over ssh. Run it on each host.
- **`watch`** is interactive and **`logs -f`** is streaming; both only make
  sense against one host. Each says so rather than reporting "unknown
  command".

##### Capacity budgets: `--max-unavailable` and `--min-available`

The controls above are blunt. These are graded — and they are **two different
flags because the operations have opposite dynamics**, which is the part worth
reading before reaching for one.

**`--max-unavailable N` — for `restart`, `apply`, `scale`.** A restarted slot
goes out and *comes back*, so the count of unavailable slots rises and falls
and a **ceiling** throttles the rate. This is the rolling-update shape:

```
$ runnerctl fleet restart --max-unavailable 1
build-1 slot 0: restart ok
build-1 slot 1: restart ok
build-2 slot 0: restart ok
fleet restart: 4 slot(s) done, 0 failed
```

It walks one slot at a time and **re-reads fleet state between slots**, so it
waits for the last one to come back before taking the next out. `N` may be a
percentage (`--max-unavailable 25%`), resolved against the fleet's total slots
and never rounded down to 0 — a budget of zero would block on the first slot
and look exactly like a hung fleet.

**`--min-available K` — for `stop`, `drain`, `disable`.** These take capacity
away and never give it back, so the unavailable count only ever *rises*. A
ceiling would take out N slots and then have nothing to wait for. What fits is
a **floor**:

```
$ runnerctl fleet drain --min-available 2 ; echo "exit $?"
build-1 slot 0: drain ok
build-1 slot 1: drain ok
fleet drain: 2 slot(s) done, 0 failed, 2 left running at the floor
left running to hold --min-available 2: build-2/0 build-2/1
exit 2
```

**Exit 2 means it deliberately did less than you asked** — neither success (0)
nor failure (1). A drain that silently stops short is worse than one that says
which slots it left running, and where.

Each flag is **refused on the commands it cannot help**, rather than accepted
and quietly ignored, and the two cannot be combined. Passing `--min-available`
counts as naming your scope, so it satisfies the `--all-hosts` gate on its own.

Both walk **one slot per remote call**, not one command per host: a budget is
a statement about slots, and a per-host call would take a whole host's worth
of capacity out in a single step whatever the number said.

A host that does not answer contributes no slots to the arithmetic — its
capacity is unknown, and guessing either way is worse than leaving it out. The
walk says up front how many hosts it could not count.

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
