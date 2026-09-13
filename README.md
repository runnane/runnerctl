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
curl -fsSL https://raw.githubusercontent.com/runnane/runnerctl/main/runnerctl | sudo bash -s -- install
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
curl -fsSL https://raw.githubusercontent.com/runnane/runnerctl/main/runnerctl -o runnerctl
less runnerctl && sudo bash runnerctl install
```

Requirements: bash 4+, systemd, `curl` (for `install`/`upgrade`), and `sudo`
for anything that writes under `/etc` or talks to `systemctl` (or run it as
root). Only `install` works when the script is read from a pipe; every other
command needs it installed.

## Usage

```
runnerctl [--config PATH] <command> [args]

runnerctl status [--json] [--watch|-w] [--interval N] [--once]
runnerctl watch  [--interval N]
runnerctl apply  [--profile NAME] [--max 26G] [--high 22G] \
                 [--restart-sec N] [--env-file PATH] [--restart] \
                 [--when-idle] [--timeout N] [<unit|slot-index|name> ...]
runnerctl scale N [--profile NAME] [--max 26G] [--high 22G] \
                  [--restart] [--when-idle] [--timeout N]
runnerctl env-init [--profile NAME] [--env-file PATH]
runnerctl start|stop|restart [--when-idle] [--timeout N] \
                             [<unit|slot-index|name> ...]
runnerctl drain [--timeout N] [<unit|slot-index|name> ...]
runnerctl enable|disable <unit|slot-index|name>
runnerctl logs [<unit|slot-index|name>] [-f|--follow] [-n N] \
               [--since WHEN] [-g PATTERN]
runnerctl remove-limits [<unit|slot-index|name> ...]
runnerctl health [--quiet] [--max-restarts N]
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
IDX RUNNER                 PROFILE  ACTIVE                              SINCE    ENABLED   MAX    HIGH   USED        RESTART  ENVFILE WORKING-ON
0   org.host-1             ci       active/running                     3d 4h    enabled   26.0G  22.0G  3.1G/24.9G  always   —       my-app:test (12m)
1   org.host-2             ci       active/running ↻3 (last: oom-kill)  2d 7h    enabled   26.0G  22.0G  128M        always   —       idle 2h31m (7 jobs)
2   org.host-3             deploy   inactive/dead                      6d       disabled  —      —      —           always   —       —
```

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
{"host":{"cores":16,"mem_total":64424509440,"mem_available":51539607552},
 "slots":[
  {"idx":0,"unit":"actions.runner.org.host-1.service","name":"org.host-1",
   "active":"active","sub":"running","enabled":"enabled",
   "memory_max":27917287424,"memory_high":23622320128,"memory_current":3328599552,"memory_peak":26743545600,
   "restart":"always","env_file":null,"since":1757622000,
   "restarts":0,"result":"success","last_restart_reason":null,"profile":"ci",
   "job":{"repo":"my-app","name":"test","since":1757707200},
   "idle_since":null,"jobs_completed":null,"working_on_access":"ok"}
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
"name", "since"}` while a job is in flight, any of the three null when
unknown, null when idle or stopped — `idle_since` and `jobs_completed`
(epoch second of the last completion and the count since the unit started,
0 and the unit's own start when nothing has finished yet; null while busy or
stopped), and `working_on_access`: `"ok"`, `"no-journal"` (only `/proc`
could be read, so `job` may be present but `idle_since` never is) or
`"no-access"` — the note under the table, per slot. `host` carries `cores`
(`nproc`) and `mem_total` / `mem_available` (bytes, from `/proc/meminfo`).
`--json` is one-shot and refuses `--watch`; poll it instead.
### Health checks for cron / uptime monitors: `health`

`runnerctl status` always exits 0, so nothing on the host can notice "slot
2 has been `inactive/dead` since Tuesday" without parsing the table. `health`
closes that: exit 0 with `ok: N slot(s) healthy` when every enabled slot is
`active`/`activating`/`reloading` and no slot has restarted `--max-restarts`
times (default 5) or more since its last manual start; otherwise one line
per problem on stdout and exit 1:

```
example.slot-2: enabled but inactive/dead since 3d
example.slot-1: 7 restarts since last start (oom-kill)
```

`--quiet` drops the output either way and keeps just the exit code, for a
cron line like:

```sh
runnerctl health --quiet || alert "runner pool unhealthy on $(hostname)"
```

A disabled, scaled-down slot is not a problem — only an *enabled* slot that
is not running counts. The restart count is systemd's `NRestarts`, which
resets on `systemctl start`/`restart`: it is restarts since the unit's last
manual start, not a rolling "in the last hour" window — there is no cheap
way to bucket it by wall-clock time without walking the journal for every
slot, so this reports what `systemctl show` already tracks. When a restart
count trips the threshold and the journal knows why the *last* one happened,
the reason (`oom-kill`, `exit-code N`, `signal NAME`) is appended, same as
the `ACTIVE` column in `status`. A host with no runner units at all still
gets the usual `no 'actions.runner.*.service' units found` error (exit 1,
not suppressed by `--quiet`).

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

### Profiles

Two profiles are built in so the tool is usable with no config at all:

| profile  | memory cap        | restart | EnvironmentFile             |
| -------- | ----------------- | ------- | --------------------------- |
| `ci`     | 26G max / 22G high| 10 s    | none                        |
| `deploy` | none              | 15 s    | `/etc/runnerctl/deploy.env` |

`ci` is a memory-capped build/test pool: a runaway job is contained to its own
cgroup and `Restart=always` brings the slot back. `deploy` is an uncapped,
long-lived runner whose secrets come from a root-owned file on the box rather
than from GitHub Actions secrets — the point being to shrink the blast radius
of a runner that can reach production.

Flags (`--max`, `--high`, `--restart-sec`, `--env-file`) override a profile's
values for one invocation.

Typical baselines:

```sh
# CI host: two active slots, capped
runnerctl scale 2 --max 26G --high 22G

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
runnerctl upgrade              # install the latest from main
runnerctl upgrade --ref v0.1.0 # pin a tag or branch
```

`upgrade` downloads the script from `UPGRADE_URL` (default: this repository's
`main`), checks that it parses and carries a `RUNNERCTL_VERSION`, and replaces
the installed file by rename — so a running invocation is unaffected. It will
not downgrade unless `--ref` is given, and it uses `sudo` only when the install
location is not writable. Point `UPGRADE_URL` at a fork or a mirror in the
config file to upgrade from somewhere else.

Versions are cut by [release-please](https://github.com/googleapis/release-please)
from the conventional-commit history: each merge to `main` refreshes a release
PR, and merging that PR bumps `RUNNERCTL_VERSION`, writes [`CHANGELOG.md`](CHANGELOG.md),
tags `vX.Y.Z` and publishes a GitHub release with the script attached. Between
releases `main` carries the next version's changes under the last version
number; `--ref vX.Y.Z` pins a released one.

### What it writes

One drop-in per runner unit, `/etc/systemd/system/<unit>.d/10-runnerctl.conf`:

```ini
# Managed by runnerctl (profile: ci) — DO NOT EDIT BY HAND.
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=10
MemoryHigh=22G
MemoryMax=26G
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
