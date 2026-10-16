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

A write is several calls on names in one directory (stage, chmod, chown,
rename), and as root those calls are only safe where nobody else can write the
directory: whoever can swaps a name for a symlink between two calls, and the
next one acts on whatever it points at. So before its first write, `install`
(and `upgrade`) reads the chain of every directory it will write in — the
prefix, the config's, a home copy's — and, running as root:

| the directory's chain | what it does |
| --- | --- |
| root-owned, writable by root alone (`/usr/local/bin`, `/etc/runnerctl`) | writes as root, as always |
| one user's, not group- or world-writable, holding only that user's files (a home copy's `~/.local/bin` under `sudo`) | every call on a name there runs **as that user** (`runuser -u USER --`), with no `chown`: retiring a home copy as `.retired` or `.legacy`, an in-place `--prefix ~/bin`, its `.prev` |
| anything else — group- or world-writable, two owners, a file root or someone else owns in a user's directory | refuses before writing anything, naming the directory |

The refusal reads `refusing to install /srv/tools/runnerctl as root:
/srv/tools is group- or world-writable (mode 775) — …`, and the way on is to
move the copy to a directory only root can write, such as `/usr/local/bin`, or
to run the command as the user who owns that directory, without `sudo`. A run
that is not root and writes only where it already can is not judged at all.

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
`config.sh --unattended` (as the runner user), and writes the systemd unit
`svc.sh install` would have written — the runner's own unit template, byte for
byte, with the runner's name, directory and user filled in — then enables and
starts it. The result is exactly the units the rest of this tool already
manages through drop-ins, and the same file a host provisioned by hand with
`svc.sh` carries.

**Nothing in a runner's directory is ever run as root.** That directory is
owned by the runner user, which is the account every job runs as, so a script
there run as root would be a job's code run as root. runnerctl therefore does
not run the runner's `svc.sh` (which also sources `./env.sh`) at all: as root
it only creates, unpacks into, `chown`s and deletes the directory, writes the
root-owned unit (`0644 root:root`) and runs `systemctl`; and it unpacks and
`chown`s only a tree it has just created, inside a staging directory under
the runner root that only root can enter, which it then renames into place.
`--replace` does not unpack over a directory a runner already had (a job may
have left symlinks in it, and `tar` extracts through one): the old directory
is renamed aside and deleted, and nothing in it is kept. `config.sh`, and the
two files `svc.sh` would have put in the directory (`runsvc.sh` and the
`.service` marker), are run and written as the runner user. The unit runs
`runsvc.sh` as that user too (`User=`), with no `ExecStartPre`/`ExecStop` or
privileged `+`/`!` prefix. The template was read from actions/runner v2.338.0.
(`svc.sh` ran `restorecon` on SELinux hosts because it rendered the unit in the
runner's directory and moved it, which keeps the source's label; runnerctl
creates the file in `/etc/systemd/system` itself, so it is labelled like any
other file created there — not verified on an SELinux host.)

It is **idempotent against a target count**, like `scale`. `provision 4` on a
host with 2 slots adds two and leaves the existing ones untouched; `provision 2`
on a host with 4 changes nothing. It never deregisters a runner — that is
[`deprovision`](#removing-runners-deprovision).

### Credentials

The registration token can come from any of three places, checked in this order:

| how | when to use it |
| --- | --- |
| `--token <token>` | the token from **Settings → Actions → Runners → New self-hosted runner**. Valid one hour, registers any number of runners. Nothing long-lived touches the host. |
| `--pat <token>` or `$GITHUB_TOKEN` | a PAT that mints the registration token over the API. A classic PAT needs `repo` for a repo runner, `admin:org` for an org one. |
| the `gh` CLI | if `gh` is already logged in on the box, no flag at all. |

The PAT is handed to `curl` on **stdin**, through its own config format, so it
never appears in `/proc/<pid>/cmdline`. The *registration* token reaches
`config.sh` the same way the removal token does: through the runner's own
`ACTIONS_RUNNER_INPUT_TOKEN` environment variable, handed over on stdin, never
a command-line argument, so it never shows up in `ps`. runnerctl itself never
prints or stores it.

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
  root, so the runner never does. The root must be root's: `provision` refuses
  (before any change, and in a `--dry-run`) a runner root or a parent of it
  that is not owned by root or is group- or world-writable (a sticky `/tmp`
  included), and a root that is a symlink, because root does its file work
  inside it and whoever can write there can swap a slot under root's calls. The
  refusal names the directory and the fix (`chown root:root DIR; chmod 755
  DIR`). `deprovision` does not refuse a slot under such a parent (a classic
  `svc.sh` runner lives in its user's home): it removes the directory as the
  unit's user (`runuser -u <user> -- rm -rf`) instead of as root, says so, and
  shows it in a `--dry-run`; only a unit with no non-root user to remove it as
  is refused, and then nothing is changed.
- `--url` — the org, repo or enterprise to register against. Set `RUNNER_URL`
  in the config file to stop repeating it on a host.

`runnerctl provision --help` lists all of them, and `runnerctl config-example`
shows the config-file defaults for every value except the credentials.

Provisioning is deliberately **excluded from `fleet`**: fanning it out would
copy a registration token to every host, and each host needs its own runner
names. Run it per host.

### Removing runners: `deprovision`

`scale` stops a slot but leaves it registered with GitHub (it shows offline)
and on disk. `deprovision` removes it for good:

```sh
sudo runnerctl deprovision 3 --url https://github.com/your-org   # by slot index
sudo runnerctl deprovision host-4 --token <removal token> --yes    # by runner name
sudo runnerctl deprovision 2 3 --dry-run                           # print the commands only
```

Per slot, in the order the runner itself requires: what `svc.sh stop` and
`svc.sh uninstall` did — `systemctl stop`, `systemctl disable`, and the unit
file removed by name, which works the same on a unit `svc.sh` installed — then
the runner's `.service` marker is removed (the runner refuses to deregister
while it exists) and `config.sh remove` runs with a **removal token**, both as
the runner user; then the runner's directory — the unit's `WorkingDirectory`,
which must hold `config.sh` and `svc.sh` or the slot is refused — and
runnerctl's own drop-in are deleted. A unit whose `User=` is root is refused
unless `--local-only`, which runs none of the runner's own scripts.

It is **destructive and irreversible**, so:

- **Explicit targets only.** A unit, slot index or runner name, as for `stop`;
  a bare `deprovision` is a refusal, never "all".
- **y/N confirmation** unless `--yes` — and without a terminal to ask on, it
  refuses rather than assuming yes.
- **A slot with a job in flight is refused**, all targets checked before any is
  touched. `--when-idle` waits for each slot's job instead (bounded by
  `--timeout N`), as `drain` does.
- `--dry-run` prints the exact commands and mints no token.

The removal token comes from the same three places as the registration token
(`--token`, `--pat`/`$GITHUB_TOKEN`, or the `gh` CLI — minted from
`.../actions/runners/remove-token` for the scope `--url` or `RUNNER_URL`
names). It reaches `config.sh` through the runner's own
`ACTIONS_RUNNER_INPUT_TOKEN` environment variable on stdin, **not** its command
line, so it never shows up in `ps` (neither does the registration token).

A runner GitHub has **already forgotten** — removed in the UI, say — makes
`config.sh remove` fail. That is a warning, not a stop: the unit and directory
are still removed, and the summary names the runners GitHub did not confirm so
you can check **Settings → Actions → Runners**. `--local-only` skips GitHub
altogether (no credential needed) and leaves the runner listed there as offline.

Like `provision`, it is **excluded from `fleet`**: it takes a credential, and a
slot index or name means a different runner on every host.

## Usage

```
runnerctl [--config PATH] <command> [args]

runnerctl provision N [--url URL] [--token TOK | --pat TOK] [--labels a,b] \
                      [--name-prefix P] [--runner-user U] [--runner-root DIR] \
                      [--runner-version X.Y.Z] [--sha256 SUM] [--replace] \
                      [--dry-run]
runnerctl deprovision <unit|slot-index|name>... [--token TOK | --pat TOK] \
                      [--url URL] [--local-only] [--when-idle] [--timeout N] \
                      [--yes] [--dry-run]
runnerctl status [--json | --with-json] [--watch|-w] [--interval N] [--once] \
                 [--color auto|always|never] [--stall-after N] [--narrow]
runnerctl watch  [--interval N] [--color auto|always|never] [--stall-after N] \
                 [--narrow]
runnerctl apply  [--profile NAME] [--max 26G] [--high 25G] \
                 [--restart-sec N] [--env-file PATH] [--save] [--restart] \
                 [--when-idle] [--timeout N] [<unit|slot-index|name> ...]
runnerctl scale N [--profile NAME] [--max 26G] [--high 25G] [--save] \
                  [--restart] [--when-idle] [--timeout N]
runnerctl env-init [--profile NAME] [--env-file PATH]
runnerctl start|stop|restart [--when-idle] [--timeout N] \
                             [--if-stalled] [--stall-after N] \
                             [<unit|slot-index|name> ...]
runnerctl drain [--timeout N] [<unit|slot-index|name> ...]
runnerctl enable|disable <unit|slot-index|name> [<unit|slot-index|name> ...]
runnerctl logs [<unit|slot-index|name>] [-f|--follow] [-n N] \
               [--since WHEN] [-g PATTERN]
runnerctl remove-limits [<unit|slot-index|name> ...]
runnerctl reap [--dry-run] [<unit|slot-index|name> ...]
runnerctl kill [--dry-run] [--if-stalled] [--stall-after N] \
               [<unit|slot-index|name> ...]
runnerctl compose-reap [--apply] [--standalone] [--project NAME] \
                       [--max-age-hours N] [--grace-minutes N]
runnerctl compose-reap-timer install|status [--brief]|remove
runnerctl fleet compose-reap [--host H]... [--apply] [--standalone] \
                             [--project NAME] [--max-age-hours N] [--grace-minutes N]
runnerctl fleet compose-reap-timer status|install|remove [--host H]...
runnerctl health [--quiet|--json] [--max-restarts N] [--stall-after N] [--restart-stalled]
runnerctl profiles
runnerctl config-example
runnerctl migrate [--from PATH] [--output PATH] [--dry-run]
runnerctl install [--prefix DIR] [--ref <branch|tag>] [--no-migrate] [--dry-run]
runnerctl upgrade [--check] [--ref <branch|tag>] [--sha256 SUM] [--prefix DIR] \
                  [--no-relocate]
runnerctl upgrade --rollback
runnerctl version
```

`status` shows each slot's state and how long it has been in it (`SINCE`),
which profile it carries (`PROFILE`, read from its drop-in — `—` if it has
none), memory cap/current/peak usage, restart policy, env file and the job it
is currently working on, with how long that job has been running — or, for
an idle slot, how long it has been idle and how many jobs it has finished
since it started:

```
runnerctl 0.7.0 — Host: 16 cores, 62Gi RAM, 48Gi available — load 9.4/16 — Disk: /var/lib/docker [docker] 96% (37.3G free), /srv/runners [work] 41% (602.4G free) — last 1h: 1 OOM kill

IDX RUNNER                 PROFILE  ACTIVE                              SINCE    ENABLED   MAX    HIGH   USED        PRESS  CPU   RESTART  ENVFILE WORKING-ON
0   org.host-1             ci       active/running                     3d 4h    enabled   26.0G  25.0G  3.1G/24.9G  0.4%   7.8   always   —       my-app:test (12m)
1   org.host-2             ci       active/running ↻3 (last: oom-kill)  2d 7h    enabled   26.0G  25.0G  128M        0.0%   0.0   always   —       idle 2h31m (7 jobs)
2   org.host-3             deploy   inactive/dead                      6d       disabled  —      —      —           —      —     always   —       —
```

The header leads with the version of the `runnerctl` that is running — each
host only picks up a new one when `upgrade` runs, so on a fleet that is
otherwise only visible through a second command — then the host's cores and
memory.

`load 9.4/16` is the host's 1-minute load average against its core count —
the quickest read of which box is overcommitted. Green below
`LOAD_WARN_RATIO` (config, default `1.0`: load equal to the cores), yellow
from it, red from `LOAD_CRIT_RATIO` (default `2.0`); both are ratios of load
to cores with at most two decimals, compared as whole hundredths rather than
by floating point. Left out when `/proc/loadavg` cannot be read. It is
informational: `health` does not treat load as a problem; `fleet`'s summary
line counts the hosts at `LOAD_CRIT_RATIO` as `N hosts overloaded`.

`Disk:` lists the filesystems a build pool fills, not every disk: the one
holding Docker's data root (`DISK_DOCKER_DIR`, default `/var/lib/docker`),
the ones holding each slot's work folder (its unit's `WorkingDirectory` plus
the runner's `workFolder`, default `_work`), and any directory in
`DISK_PATHS` (space-separated, `PATH` or `LABEL=PATH`, e.g.
`DISK_PATHS="cache=/srv/build-cache"`). Each filesystem appears once, named by
its mount point and labelled with what is on it (`/ [docker,work]` when
everything shares the root disk). `/boot`, `/efi` and the like only appear
if one of those paths lives on them, and `/` stands in as `/ [root]` when
none of them exists. Every partition is coloured: green below
`DISK_WARN_PCT` (config, default 85), yellow from it, and red from
`DISK_CRIT_PCT` (default 95). `DISK_IGNORE` (an ERE over mount points) leaves
a mount out of the header, `--json` and `health`.

`last 1h:` appears only when the journal holds host trouble in the last
`EVENTS_SEC` seconds (default 3600, `0` turns the search off): kernel OOM
kills that were host-wide (`Out of memory: Killed process`) and `No space
left on device` lines from any unit. A slot's own cgroup-limit OOM (`Memory
cgroup out of memory`) is not counted here — that is the slot's `MemoryMax`
doing its job, and it shows on the slot's row. Needs the same journal access
as `WORKING-ON`; without it nothing is shown, never a zero. Both ride on the
header line rather than a new one, so `fleet status` and `fleet watch` read a
host's table unchanged; on a fleet they appear as a host line above each host's
slots (see `fleet status` below), in `fleet status --json` and in `fleet
health`.

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

`CPU` is the cores the slot's cgroup used over the last sample — `cpu.stat`'s
`usage_usec` read twice, the difference divided by the time between the two
reads: `7.8` is a build keeping almost eight cores busy, `0.0` a slot doing
nothing. `watch` takes the previous tick as the first read, so it costs
nothing there. A one-shot `status` table reads every slot as it collects
them and once more at the end, waiting until at least `CPU_SAMPLE_MS`
(config, default 250) have passed since the last first read — the collecting
itself counts toward that, so a slow host waits for nothing; `0` never waits
and draws `—`. It does not wait when the column is not drawn (`--narrow`)
and no job is `STALLED`. `—` means unknown, never zero: no cgroup, CPU
accounting off, or a counter that went backwards between the two reads (the
unit restarted). `status --json` never waits — it reports the cumulative
counter and leaves the rate to the poller.

On a `STALLED` job the CPU rate is added to the cell: `STALLED (idle CPU,
likely hung)` below a tenth of a core, `STALLED (still computing)` from it —
a job that has run past the threshold at 0 % is wedged, one at 800 % is a
slow build. It is informational only: `--if-stalled`, `health` and `fleet
watch`'s problem view decide on the stall threshold exactly as before, and
act on a stalled job whatever its CPU.

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

`my-app:build` is the job's *id*, and `build` is the job of half the workflows
of any organisation. Where the terminal has columns to spare **beyond the full
table**, a running job is drawn with its workflow and its branch or tag instead
— `my-app:CI / build @main (14m)` — which is what tells two slots on the same
repository apart. The long form is used for a row only when the whole of it
fits, each of the two names is cut to 40 characters, and a job whose
environment names neither reads exactly as before. It is a terminal's cell
only: piped, redirected, or fetched by `fleet status` / `fleet watch` (a remote
draws its table for no terminal), the cell is the short one at any width — the
rest of the run is in [`--json`](#machine-readable-output-status---json) and one
key away in `watch` (`O`, below). The workflow, the ref and the run's other
facts come from the same step environment as the repository, so they have its
access needs (the runner's user or root) and its gap: between two steps, and
for a container job, there is no step process to read them from.

Those values — a branch name, a workflow's name, the repository, the job id —
are text somebody outside the host chose, and any process in the slot can put
what it likes in its own environment. The cell, and the `watch` lines that
quote it, do not draw it as it came: control characters (C0, `DEL`, the C1
range, and the Unicode bidirectional controls) are taken out before the cell
is built, on the host that read them, so a ref carrying an escape sequence
draws as the printable characters between the escapes and cannot move the
cursor, recolour or retitle the terminal. Text that is not well-formed UTF-8
has every non-ASCII byte replaced by `?`.

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

### Removing compose stacks a dead job left behind: `compose-reap`

The slots on a host share one Docker daemon, and a job that dies before its
own teardown runs (a cancelled workflow, `MemoryMax`, a runner restart)
leaves its compose stack **running**. Its images and volumes then count as in
use, so an age-filtered `docker * prune` skips them forever while reporting
success, and the disk fills a few GB a day. `compose-reap` judges every
compose project on the daemon by whether the job that made it is still alive:

| signal | the project is alive while… |
| --- | --- |
| `label` | any of its containers carries `runnerctl.keep=true` (`COMPOSE_REAP_KEEP_LABEL`) — the only opt-out |
| `grace` | its last activity is under `--grace-minutes` (default 10) old: a stack mid-`up` |
| `pid` | its name ends in `-<pid>` (pid ≥ `COMPOSE_REAP_MIN_PID`, 300) and that process exists and is older than the stack, so a recycled pid does not count |
| `slot` | its working dir is under a runner slot's work folder and that slot's `Runner.Worker` exists and is older than the stack |
| `age` | none of the above applies, and it is under `--max-age-hours` (default 3) idle |

```
$ sudo runnerctl compose-reap
reap ci-harness-48211 reason=gone:pid:48211 idle=849m containers=2 networks=2 volumes=2
keep ci-harness-51007 reason=live:pid:51007 idle=4m containers=3 networks=2 volumes=2
keep pg-scratch reason=volume-only idle=781m containers=0 networks=0 volumes=1
compose-reap: mode=dry-run projects=3 reap=1 keep=2 removed=0 failed=0 slots=4 standalone=0 images-removed=0 non-compose-running=0 skipped=0
```

It is a dry run unless `--apply`, and `--apply` refuses on a host with no
runner units, where the age guard would take a developer's own stacks. A
reaped project loses its containers (with their anonymous volumes), then its
networks, then its named volumes — by id, never a prune, because on a shared
daemon a prune reaches other jobs. A project that is only volumes is never
reaped. Running containers without a compose label are counted in the
summary (`non-compose-running`) and, by default, never touched.

A label is text any job with Docker access chose, so it is never trusted to
shape what is read: ids and timestamps come from Docker's own fields, and the
labels come back JSON-encoded. A project with any object whose record does not
parse — a label Docker had to escape (a quote, a backslash, a newline, a
control byte), an id that is not Docker's form, a timestamp that does not
read — is not reaped at all that run: it is printed as
`skip <project> reason=unparseable:<kind>-<why>` and counted in the summary's
`skipped`.

#### Containers with no compose label: `--standalone`

A plain `docker run -d` that a dead job left running pins its image just as
firmly, and has no project or working dir to tie it to a job. With
`--standalone` (or `COMPOSE_REAP_STANDALONE=1` in the config, which the timer
reads) every container without a compose label is judged too: kept for the
keep label or the grace window; kept while **any** slot runs a job that
started before the container (`live:job` — an unlabelled container cannot say
whose it is, so any older running job might own it); otherwise reaped past
`--max-age-hours`. With `--apply`, each reaped container's image is removed by
id once no container uses it, so a shared base image survives. It is opt-in
because a host may run long-lived containers of its own outside CI.

```
keep container keeper reason=young idle=60m image=verify:shared
reap container verify-old reason=age idle=1200m image=verify:1
keep image verify:shared reason=in-use
removed image verify:1
``` Run it as root (the timer does) so it
can read every slot's processes; a slot it cannot read can only look idle.

Nothing inside a job survives its death to clean up after it, so the useful
form is the timer: `runnerctl compose-reap-timer install` writes
`runnerctl-compose-reap.{service,timer}` (hourly, `compose-reap --apply`),
enables it and prints a dry run of the first pass. The unit runs as root and
executes this runnerctl, so `install` refuses unless the file is root-owned
and writable by nobody else — which is what `runnerctl install` leaves at
`/usr/local/bin`. `compose-reap-timer status` says whether the timer is
installed (`timer: installed (enabled, active)` or `timer: not installed`),
then shows it and the last runs' journal; `status --brief` is that first line
alone, which needs no privilege. `remove` takes both units away.

The dry run asks the daemon first, and a user it refuses — one outside the
`docker` group — is an error naming the fix, never `projects=0`: every docker
read otherwise sends its errors to `/dev/null`, so a host the dry run could
not see would read as an empty one. Across hosts, see [`fleet
compose-reap`](#compose-leftovers-across-the-fleet-fleet-compose-reap).

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

> Watching **several** hosts at once? Use
> [`fleet watch`](#a-live-fleet-view-fleet-watch), not `watch runnerctl fleet
> status` — it holds one ssh connection per host open instead of reconnecting
> to every one of them on every tick.

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
| `O` | print the URL of the running job's run on the status line — `https://github.com/<owner>/<repo>/actions/runs/<id>/attempts/<n>` — to copy or click. It is printed, never opened: the node you watch from is usually a terminal with no browser. Says so when no job is running, or when the job's environment could not be read (between steps, a container job, no access to the slot's processes) | nothing |
| `Enter` | show the selected slot in full, in place of the table — [below](#the-slot-in-full-enter) | nothing |
| `?` | list every key `watch` reads, in place of the table, as [`fleet watch`](#a-live-fleet-view-fleet-watch)'s `?` does; ↑ ↓ PgUp PgDn g G scroll it where the terminal cuts it, and any other key closes it, and is spent doing so. The legend under the table names it: `? keys` | nothing |
| `PgUp` / `PgDn` | move the cursor a page (a window less one row, so the row you left is still on screen) | |
| `g` / `G`, `Home` / `End` | the first / last slot | |
| `q` | quit | |

#### The slot in full: `Enter`

A table row has room for a dozen cells, and a slot has more to say than that —
enough that deciding whether it is *stuck* or *starved* used to mean leaving
the view for `status --json`. `Enter` on a row replaces the table with
everything known about that one slot, and its host:

```
build-1-a — slot details
Identity
  host          build-1
  runner        build-1-a
  unit          actions.runner.example-org.build-1-a.service
  profile       ci
  enabled       enabled
  runnerctl     0.19.0
State
  active        active/running
  since         3d 4h
  restarts      3
  result        success
  last restart  oom-kill
Job
  repo          example-org/my-app
  job           test
  running for   12m
  stalled       no
  workflow      CI
  run           #57 · id 1234567890 · attempt 2
  ref           main
  commit        0123456789abcdef0123456789abcdef01234567
  actor         octocat
  event         push
  url           https://github.com/example-org/my-app/actions/runs/1234567890/attempts/2
Memory
  current       1.0G
  peak          25.0G
  high          22.0G
  max           26.0G
  bar           [#+++++++++++++++++++++++++++++++++++++--] 4% of max, peak 96%, high at 85%
  pressure      full avg10 63.2% · avg60 41.0%
  events        high 4 · max 1 · oom_kill 0
Leaks
  leaked        —
Host
  cores         16
  memory        48.0G available of 64.0G
  disk          / [docker,work] 24% (353.9G free)
  events        none in the last 1h

q/Esc/Enter back  h host  jk scroll  K R S T P L O this slot  Ctrl-C quits
```

| key, in the pane | does |
| --- | --- |
| `q` / `Esc` / `Enter` | back to the table, the cursor where it was. **`q` does not quit here** — `Ctrl-C` does, from anywhere |
| `h` | the host's block alone, and back to the slot |
| `↑` `↓` / `j` `k`, `PgUp` / `PgDn`, `g` / `G` | scroll, when the pane is taller than the terminal |
| `K` `R` `S` `T` `P` `L` `O` | as in the table, on this slot, with the same confirm line |

What to know about it:

- **It refreshes like the table**: every `--interval`, and at once on a key. A
  slot that goes away while its pane is up (a `scale` down) puts the table
  back, with a line saying so.
- **`—` means not known**, on any row: a slot that is not running has no memory
  figures, a job between two steps has no run to name, a busy slot has no
  leak count.
- **The bar** is drawn against `MemoryMax` (against `MemoryHigh` where no max
  is set): `#` is what is in use now, `+` reaches the peak since the unit
  started, `-` is free. Plain ASCII, so it reads the same with `--color never`
  and on a terminal that is not in UTF-8 mode. With neither limit set the row
  says there is nothing to draw it against.
- **`Leaks`** names the processes behind the table's `+N leaked`
  (`4242/node, 4243/esbuild`) — the ones `P` would reap.
- **Everything in it that somebody else chose is drawn as text.** A workflow's
  name, a branch, an actor, a leaked process's name: control characters and
  bidi overrides are taken out before a row is drawn, so a job cannot repaint
  your terminal by naming its branch after an escape sequence.
- **No cursor in it.** A pane taller than the terminal is windowed like the
  table, with `↑ N more` / `↓ N more`; the keys move the window itself.

**A table taller than the terminal.** The frame is cut to the terminal's
height instead of scrolling its own top away. The header, the column header,
the legend and the status line stay where they are; between them a window of
the rows follows the cursor, moving only when the cursor crosses its edge,
and a dim line counts what is out of sight and names the keys that page:

```
IDX RUNNER          PROFILE  ACTIVE           SINCE  ENABLED  ...  WORKING-ON
↑ 12 more  PgUp/g
12  org.build-1-m   ci       active/running   3d 4h  enabled  ...  my-app:test (12m)
13  org.build-1-n   ci       active/running   2d 7h  enabled  ...  idle 2h31m (7 jobs)
↓ 7 more  PgDn/G
```

So the slot a key acts on is always one you can see. A line longer than the
terminal is counted as the rows it wraps to — a confirm line usually is two —
and resizing the terminal redraws at once rather than at the next interval.
A terminal too small for the header, the legend and a three-row window, or
one whose height cannot be read (no `tput`, no `TERM`), gets the whole frame
as before.

The redraws keep coming at `--interval` while a confirm line is up, so the
table under it is current when you answer. On a terminal narrower than the
table the `MAX`, `HIGH`, `CPU` and `ENVFILE` columns are dropped, never
`WORKING-ON` — its `idle 2h31m (7 jobs)` is what tells you a slot is safe to
act on. They come back once the full table fits again, with a few columns to
spare, so a terminal near the edge does not flip the table on every redraw.
The width they come back at is measured — the wide table against the narrow
one, at the moment it narrowed — rather than assumed, so a wide `ENVFILE`
path does not make the two decisions contradict each other.
`--narrow` asks for that narrow table outright — `status --narrow` prints it
once, and `watch --narrow` keeps it whatever the width. It is a table shape,
so `status --json --narrow` is refused.

### Machine-readable output: `status --json`

`runnerctl status --json` prints the same facts as one JSON object, for a
host-inventory collector, a dashboard or an alerting cron that would
otherwise have to scrape the table's columns — whose set and widths change
with every new feature. Raw bytes and epoch seconds, not `26.0G` / `3d 4h`;
`null` wherever the table prints `—` (including `infinity` and `[not set]`
memory values); no `jq` needed to produce it, and the table and the JSON are
rendered from one collector, so they cannot disagree on a value:

```json
{"runnerctl":"0.7.0","host":{"name":"build-1","cores":16,"mem_total":64424509440,"mem_available":51539607552,"load":[9.42,7.10,5.03],"disks":[{"mount":"/","device":"/dev/nvme0n1p2","fstype":"ext4","size":500000000000,"used":120000000000,"avail":380000000000,"use_pct":24,"roles":["docker","work"]}],"events":{"window":3600,"oom_kills":0,"cgroup_oom_kills":1,"disk_full":0,"last_oom":null,"last_oom_process":null,"last_disk_full":null,"last_disk_full_source":null}},
 "slots":[
  {"idx":0,"unit":"actions.runner.org.host-1.service","name":"org.host-1",
   "active":"active","sub":"running","enabled":"enabled",
   "memory_max":27917287424,"memory_high":23622320128,"memory_current":3328599552,"memory_peak":26743545600,
   "restart":"always","env_file":null,"since":1757622000,
   "restarts":0,"result":"success","last_restart_reason":null,"profile":"ci",
   "cpu_usage_usec":81234567890,"cpu_usage_at_us":1757707415123456,
   "invocation_id":"0123456789abcdef0123456789abcdef","cpu_pressure":{"some_avg10":3.20,"some_avg60":2.75,"some_total":123456789},
   "job":{"repo":"my-app","name":"test","since":1757707200,"stalled":false,
          "workflow":"CI","run_id":1234567890,"run_attempt":1,"run_number":57,"ref":"main",
          "sha":"0123456789abcdef0123456789abcdef01234567","actor":"octocat","event":"push",
          "url":"https://github.com/example-org/my-app/actions/runs/1234567890/attempts/1"},
   "idle_since":null,"jobs_completed":null,"working_on_access":"ok","leaked_procs":null,
   "memory_events":{"high":4,"max":1,"oom_kill":0},
   "memory_pressure":{"full_avg10":0.41,"full_avg60":0.12,"full_total":9876543}}
]}
```

Keys, per slot: `idx`, `unit`, `name` (the `RUNNER` column), `active`,
`sub`, `enabled` (systemd's `ActiveState` / `SubState` / `UnitFileState`),
`memory_max`, `memory_high`, `memory_current`, `memory_peak` (bytes),
`restart` (the `Restart=` policy), `env_file` (the `EnvironmentFiles` path(s),
without systemd's ` (ignore_errors=…)` rendering), `since` (epoch second the slot entered its current state — what
`SINCE` counts from), `restarts` (`NRestarts`), `result` (the current
invocation's `Result`), `last_restart_reason` (`oom-kill` / `exit-code N` /
`signal NAME`, looked up under the same condition as the table's
`(last: …)`, null otherwise), `profile` (from the drop-in), `job` — `{"repo",
"name", "since", "stalled"}` while a job is in flight (`repo`, `name` and
`since` null when unknown; `stalled` true or false against `STALL_SEC` /
`--stall-after`, null when the runtime is unknown), null when idle or
stopped; after those four the object names the run the job belongs to (the
table below) — `idle_since` and `jobs_completed`
(epoch second of the last completion and the count since the unit started,
0 and the unit's own start when nothing has finished yet; null while busy or
stopped), and `working_on_access`: `"ok"`, `"no-journal"` (only `/proc`
could be read, so `job` may be present but `idle_since` never is) or
`"no-access"` — the note under the table, per slot, and `leaked_procs`: how
many processes a finished job left in an idle slot's cgroup (the table's
`+N leaked`; `0` when none, null while busy or when the cgroup cannot be
read), `cpu_usage_usec` (the cgroup's cumulative CPU time from `cpu.stat`,
microseconds — a poller divides the difference of two payloads by the time
between them for the `CPU` column's rate; null with CPU accounting off, never
0), `cpu_usage_at_us` (when that counter was read, the host's own clock in
epoch microseconds — the "time between them"; null with the counter),
`invocation_id` (systemd's `InvocationID` of the run the counter belongs to:
two payloads with different ones are two runs, and no rate; null when the unit
has none) and `cpu_pressure` (`{"some_avg10","some_avg60","some_total"}` from
`cpu.pressure`, null likewise), `memory_events` (`{"high","max","oom_kill"}` from the cgroup's
`memory.events`, counts since the unit started) and `memory_pressure`
(`{"full_avg10","full_avg60","full_total"}` from `memory.pressure` —
percentages and total stall microseconds; the `PRESS` column is
`full_avg10`), each object null when the file could not be read. `host`
carries `name` (the host's own `hostname`, null when it cannot be read),
`cores`
(`nproc`), `mem_total` / `mem_available` (bytes, from `/proc/meminfo`),
`load` (`[1m, 5m, 15m]` from `/proc/loadavg`, null when it cannot be read),
`disks` (one object per watched filesystem — `mount`, `device`, `fstype`,
`size`, `used`, `avail` in bytes, `use_pct` and `roles`, e.g.
`["docker","work"]` — the filesystems the header's `Disk:`
lists), `events` (the last `EVENTS_SEC` of journal: `window` in seconds,
`oom_kills` host-wide and `cgroup_oom_kills` per-cgroup, `disk_full` lines,
and the epoch second, process and syslog identifier of the last of each;
null when the journal cannot be read or `EVENTS_SEC=0`) and, last,
`sudo_contract` — `"narrow"` or `"full"`, the host's `SUDO_CONTRACT` as read
from its default config (`/etc/runnerctl/config`, world-readable, so no
privilege is asked; no file, or one that fails the trust check, is `"full"`,
as the sudo guard itself reads it), or null when that file exists and the
login cannot read it. A host from before the key has none; `fleet` flags both
under `FLEET_SUDO=1` (see [The narrow sudo contract](#the-narrow-sudo-contract));
`runnerctl` is the version of the script that produced the object, for
inventorying a fleet.
`--json` is one-shot and refuses `--watch`; poll it instead.

**The run a job belongs to.** A `job` object carries, after `stalled`, what
the job's step environment says about its run. Every key is always there, and
`null` when the value could not be read (no step process between two steps or
in a container job; no access to the slot's processes) **or is not what such a
value has to be** — these are strings a job supplied, so they are held to a
shape rather than passed on:

| key | from | reported when |
| --- | --- | --- |
| `workflow` | `GITHUB_WORKFLOW` | any text; cut to 200 bytes on a character boundary |
| `run_id`, `run_attempt`, `run_number` | `GITHUB_RUN_ID`, `GITHUB_RUN_ATTEMPT`, `GITHUB_RUN_NUMBER` | `0`, or up to 15 digits with no leading zero — JSON numbers |
| `ref` | `GITHUB_REF_NAME` (the branch or tag, `main`, not `refs/heads/main`) | any text, cut like `workflow` |
| `sha` | `GITHUB_SHA` | 40 or 64 lowercase hex digits |
| `actor` | `GITHUB_ACTOR` | any text, cut like `workflow` |
| `event` | `GITHUB_EVENT_NAME` | lowercase letters and `_` (`push`, `pull_request`), 64 at most |
| `url` | `GITHUB_SERVER_URL`, `GITHUB_REPOSITORY`, the two ids | `<server>/<owner>/<repo>/actions/runs/<run_id>/attempts/<run_attempt>` — only when the server is `http://` or `https://` plus a host name and optional port and nothing else, the repository is two names of letters, digits, `.`, `_` and `-`, and `run_id` passed; without a valid attempt it ends at the run id |

Free text is JSON-escaped like every other string (a control character is
`\u001b`, never the byte), and made well-formed UTF-8 first — bytes that are
not become `?` — so the object always parses. A `javascript:` "server", a run
id of `12ab` or a repository of `../..` gives `"url":null`, not a link.
`repo` stays the short name it always was; the `url` is where the owner is.

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

#### Both at once: `status --with-json`

`runnerctl status --with-json` prints the table, then one separator line, then
the `--json` object — both rendered from **one** look at the slots, so they
describe the same moment and the host does the work once. It is the form
`fleet status` and `fleet watch` ask every host for: the rows come from the
table, the summary line from the object, in one call per host. It is a
machine form rather than one to read: a program wanting only the facts should
use `--json`.

The separator line starts with the byte `0x1e` (ASCII record separator),
which no table line can start with; split on the first line that begins with
it and ignore the rest of that line. `--with-json` is a table option like
`--color` and `--narrow`, so a host with no runner units dies as the table
does and prints no object. It refuses `--json` and `--watch`.

A one-shot table waits up to `CPU_SAMPLE_MS` for the second CPU sample its
`CPU` column needs. `fleet watch` asks every host for one on every tick, so
from the second tick on it hands each host back the samples of that host's
own previous payload — `status --cpu-prev=INVOCATION:USAGE:AT,…`, built from
each slot's `invocation_id`, `cpu_usage_usec` and `cpu_usage_at_us` — and
the host takes them as the first sample, the way `watch` takes its previous
tick: no wait, one read per slot. A sample of another invocation (the unit
restarted) or younger than `CPU_SAMPLE_MS` is not used, and a counter that
went backwards is `—`. A host too old for the flag refuses it once and waits
as before. `--cpu-prev` refuses `--json` and `--watch`.
### Health checks for cron / uptime monitors: `health`

`runnerctl status` always exits 0, so nothing on the host can notice "slot
2 has been `inactive/dead` since Tuesday" without parsing the table. `health`
closes that: exit 0 with `ok: N slot(s) healthy` when every enabled slot is
`active`/`activating`/`reloading`, no slot has restarted `--max-restarts`
times (default 5) or more since its last manual start, no job has been
running for `--stall-after` seconds (default `STALL_SEC`, 1 h) or more, no
idle slot has leaked processes, no slot is under full memory pressure
of `PRESSURE_CRIT_PCT` (50 %) or more, no watched filesystem is at `DISK_CRIT_PCT`
(95 %) or more, and the journal holds no host-wide OOM kill and no `No space
left on device` line in the last `EVENTS_SEC` (1 h); otherwise one line per
problem on stdout and exit 1:

```
example.slot-2: enabled but inactive/dead since 3d
example.slot-1: 7 restarts since last start (oom-kill)
example.slot-3: stalled — job my-app:build running 1h33m, longer than 1h (--stall-after 3600)
example.slot-4: 2 leaked process(es) left by finished jobs (node, esbuild) — runnerctl reap 3
example.slot-5: under full memory pressure 63.2% (avg10, PRESSURE_CRIT_PCT=50) — throttled at MemoryHigh (4 times so far), see USED vs HIGH
host: /var/lib/docker [docker] is 96% full (37.3G free, DISK_CRIT_PCT=95)
host: the kernel OOM-killed 2 process(es) host-wide in the last 1h (last: cc1plus) — 'journalctl -k -g "Out of memory"' shows them
host: 1 'No space left on device' line(s) in the journal in the last 1h (last from dockerd)
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

`--json` prints the same problems as one object, with the **same exit code**
(0 healthy, 1 with problems), one problem per line:

```json
{"ok":false,"slots":5,"problems":[
  {"host":"build-1","slot":"example.slot-3","kind":"stalled","detail":"stalled — job my-app:build running 1h33m, longer than 1h (--stall-after 3600)"},
  {"host":"build-1","slot":null,"kind":"disk","detail":"/var/lib/docker [docker] is 96% full (37.3G free, DISK_CRIT_PCT=95)"}
]}
```

| key | meaning |
| --- | --- |
| `ok` | true exactly when `problems` is empty — the exit code, as a value. |
| `slots` | how many slots were checked (the `N` of `ok: N slot(s) healthy`). |
| `problems[].host` | this host's own name (`status --json`'s `host.name`), null when it cannot be read. |
| `problems[].slot` | the slot's `RUNNER` name, null for a host-wide problem. |
| `problems[].kind` | `not-running` (enabled, not active), `restarts` (past `--max-restarts`), `stalled`, `leaked`, `pressure` (full memory pressure past `PRESSURE_CRIT_PCT`) for a slot; `disk` (a filesystem past `DISK_CRIT_PCT`), `oom` (a host-wide OOM kill) and `disk-full` (a `No space left on device` line) for the host. |
| `problems[].detail` | the prose line after its `<slot>: ` or `host: ` — so `--restart-stalled`'s `— restarted` is there too. |

`--restart-stalled` works with `--json` and is recorded the same way (see
[history](#who-changed-what-history-and-fleet-history)). `--quiet` cannot be
combined with `--json`: the object is the whole answer.

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

### Who changed what: `history` and `fleet history`

Every command that changes the host leaves **one line in the journal**,
tagged `runnerctl`, when it ends:

```
restart example.slot-2 (--when-idle) by deploy via fleet from alice@central-1 — ok
```

The verb; the slots it acted on (`all` when it was given none); the few flags
that change what it did (`--when-idle`, `--profile NAME`, `--restart`,
`--if-stalled`, …); who ran it — the sudo caller, else the login; for a call
that came through `fleet`, the operator and central node it says it came
from; and how it ended — `ok`, `failed (exit N)`, `interrupted (SIGINT)` /
`interrupted (SIGTERM)`, or a count the command
keeps (`health --restart-stalled`: `restarted 2, 1 failed`; `compose-reap
--apply`: `ok (removed=8 failed=0 images-removed=0)`).

- **The set:** `apply`, `scale`, `env-init`, `start`, `stop`, `restart`,
  `drain`, `enable`, `disable`, `remove-limits`, `reap`, `kill` (with
  `--if-stalled` too), `health --restart-stalled`, `compose-reap --apply`
  (`--standalone` too), `compose-reap-timer install`/`remove`, `upgrade`
  (`--rollback` too), `install`, `migrate`, `provision`, `deprovision`, and
  each confirmed action key of `watch`. Reads record nothing — `status`,
  `watch` without an action, `health`, `logs`, `profiles`, `version`,
  `history`, `upgrade --check`, `compose-reap` without `--apply` — and neither
  does a `--dry-run`.
- **When:** once the command is about to change something. A usage error or
  a refusal before that point records nothing; a failure after it — a
  `--when-idle` wait that gives up after the drop-ins were written, say — is
  recorded as `failed (exit 1)`. The three that run from a timer or cron
  (`health --restart-stalled`, `compose-reap --apply`, `--if-stalled`) record
  only when they act, naming the slots they took, so a quiet hour writes
  nothing.
- **Interrupted:** a command stopped by Ctrl-C or a SIGTERM after that point
  is recorded as `interrupted (SIGINT)` or `interrupted (SIGTERM)`, and still
  ends the way it would have without the record — killed by that signal, or,
  under `watch` and `fleet watch`, through their own Ctrl-C handling. Stopped
  before that point, it records nothing. While a record is armed bash runs
  the signal's handler only once the step in progress has ended, so a
  SIGTERM sent to runnerctl's process alone (rather than its process group,
  as Ctrl-C, systemd and `timeout` signal it) waits for that step — a
  download, or one sleep of a `--when-idle` wait.
- **Never a secret.** The line is built from chosen parts, never the command
  line, so a token or PAT handed to `provision` or `deprovision` — as a flag
  or in the environment — has no way in. Every part is cleaned of control
  bytes and escape sequences, so nothing can end the line early and forge a
  second record.
- **Never in the way.** No `logger`, a `logger` that fails or a journal that
  will not take the line is silence: the command's output and exit status are
  its own.

**The origin is a claim.** Every fleet action reaches a host as the one
shared ssh login, so the central node passes `--origin OPERATOR@HOST` — its
operator (the sudo caller or the login) and its own host name — in front of
the verb, and the record says `via fleet from alice@central-1`. It is exactly
as trustworthy as that ssh login: anyone who holds the login can claim any
name. It is checked against a conservative shape and used for nothing but
the record; one that fails the check is dropped and the record says `via
fleet, origin invalid`, and the command runs either way. A host whose
runnerctl predates the flag refuses it as an unknown command, and the central
node asks it again without, so the action still happens there — unrecorded,
as on any older host.

**Reading it back.** `runnerctl history [-n N]` (default 20) prints the last N
records, oldest first, each led by its UTC time:

```
$ runnerctl history -n 2
2026-10-14T09:00:01.000100Z restart example.slot-2 by deploy via fleet from alice@central-1 — ok
2026-10-14T09:00:09.000500Z stop example.slot-1 by deploy — ok
```

It reads `journalctl -t runnerctl` as the user running it. A record written
under sudo is root's, and a login outside the `systemd-journal` (or `adm`)
group sees only its own — with no record visible it says so on stderr. Any
local user can write a line with the `runnerctl` tag (`logger` needs no
privilege), so this is an account of what the tool did, not a tamper-proof
audit log.

**The central node's own record.** Each fleet command that changes a host,
and each `fleet watch` action key, appends one line to `FLEET_LOG` (config;
default `${XDG_STATE_HOME:-~/.local/state}/runnerctl/fleet.log` of the user
running it — under sudo, root's): UTC time, operator, the command as typed (a
key is written as the command line it stands for), then each host it reached
with that host's exit status, or each slot for a budget walk:

```
2026-10-14T09:12:03Z alice fleet restart --when-idle --host build-1 — build-1=0
2026-10-14T09:14:40Z alice fleet restart --max-unavailable 1 — build-1/0=0 build-1/1=0 build-2/0=0
2026-10-14T09:20:11Z alice fleet restart --host build-2 example.slot-1 (fleet watch) — build-2=0
```

A `fleet watch` key's line is written when its action ends — detached with
`Esc` or not — or, when the watch ends first, with `detached` for the status
this node never learnt (`— build-2=detached`).

The file is created `0600` and its directory `0700`. Reads and refusals
write nothing; a file that cannot be written is silence.

**Across the fleet.** `runnerctl fleet history [-n N] [--host H]...` asks
every host for its `history -n N` (a read: `FLEET_TIMEOUT`, no sudo), merges
the records by time with each host's name after the time, and prints the
last N. A host that does not answer is a line under the list and makes the
exit status 1; one too old for `history` says so.

In `fleet watch`, `H` shows the same records in place of the table: the
cursor's host's, and the whole fleet merged by time on a second press (a third
goes back to the host); `q`, `Esc` or `Enter` return to the table. It is read
in the background on the watch's own budget (`FLEET_WATCH_TIMEOUT`, no sudo),
so the table keeps refreshing. A host too old for `history` says so, and a
login that cannot read other users' records gets the note `history` prints
instead of an empty list.

**Profiles across the fleet.** `runnerctl fleet profiles [--host H]...` asks
every host for its `profiles` (a read: `FLEET_TIMEOUT`, no sudo, in parallel)
and prints each host's lines with the host's name in front. Under them, one
line per profile defined differently on two hosts of those that answered
(`fleet profiles: 'ci' is defined differently on: build-1 | build-2`, the
hosts grouped by the definition they share) and nothing when they agree. A
host that does not answer is a line and makes the exit status 1; one that
does not know the command says so. `--host` narrows it as for `fleet status`.
In `fleet watch`, `:profiles` runs it with no confirm.

### Several hosts from one place: `fleet status`

Everything above is one host. `fleet` runs the same tool from a central node
against every runner host in `FLEET_HOSTS`, over ssh:

```
$ runnerctl fleet status
HOST     IDX RUNNER          PROFILE  ACTIVE           SINCE  ENABLED  ...  WORKING-ON
build-1  v0.21.0 · Disk: / [docker,work] 24% (353.9G free)
build-1  0   org.build-1-a   ci       active/running   3d 4h  enabled  ...  my-app:test (12m)
build-1  1   org.build-1-b   ci       active/running   2d 7h  enabled  ...  idle 2h31m (7 jobs)
build-2  v0.20.0 · Disk: /var/lib/docker [docker] 96% (37.3G free), /srv/runners [work] 41% (602.4G free) — last 1h: 1 OOM kill
build-2  0   org.build-2-a   ci       active/running   6d     enabled  ...  my-app:lint (2m)
build-3  unreachable — ssh: connect to host build-3 port 22: No route to host
note: build-2 runs 0.20.0 (behind) — this node runs 0.21.0; 'runnerctl fleet upgrade --check' shows what would change
2/3 hosts answering · 3 slots: 2 busy, 1 idle · 1 host disk crit · 1 host OOM/disk-full · capacity 1 free of 3 · 2 versions
```

The last line is the **fleet summary**: is anything wrong, and how much
capacity is left, without counting rows. A segment whose count is zero is left
out, so a healthy fleet is a short line:

| segment | counts |
| --- | --- |
| `2/3 hosts answering` | hosts that answered, of those asked. Under `--host` that is the selected hosts, not `FLEET_HOSTS`: `fleet status --host build-1` says `1/1 host answering` however long the fleet is, and its `--json` `summary` counts the same hosts. Unreachable and timed-out hosts are not answering; a host whose `runnerctl` exited non-zero answered. |
| `3 slots: 2 busy, 1 idle, …` | every slot, as exactly one of `busy`, `idle`, `STALLED` (a job past `--stall-after`) while its unit is active, and `down` or `disabled` when it is not. |
| `N leaking` | slots whose finished job left processes behind. |
| `N host(s) disk crit` / `disk warn` | hosts with a partition past this node's `DISK_CRIT_PCT` / `DISK_WARN_PCT`, each host once, at its worst partition. |
| `N host(s) OOM/disk-full` | hosts with an OOM kill or a disk-full line in their event window. |
| `N host(s) overloaded` | hosts whose 1-minute load is this node's `LOAD_CRIT_RATIO` × their cores or more. Only the red level counts: a pool at `LOAD_WARN_RATIO` (every core busy) is a pool doing its job. A host that does not report a load, or reports one that is not a plain decimal, is not counted. |
| `capacity 1 free of 3` | idle slots, of the active ones — what can take a job now. Printed whenever there are slots, `0 free` included. |
| `N versions` | distinct `runnerctl` versions, **this node's included**, when there is more than one — so a fleet level with itself but behind this node counts 2. A version that is not `X.Y.Z` is one more. |

A host that did not answer is in the host count and in nothing else: its
slots are unknown, not down. Each segment takes the colour the table uses for
that state.

The numbers come from each host's `status --json` object — never from the
table beside them. Each host is asked for `status --with-json` (see *Both at once*), so it
sends the table and that object in one answer, from one look at its slots:
the summary costs no extra call, and the rows and the counts describe the
same moment. A host on a runnerctl older than `--with-json` refuses it as an
unknown option; it is asked again without it, as for `--narrow`, and then
once more for `status --json` alone — under `fleet watch` that host is
remembered and sent the plain table call from then on, so it costs two calls
per tick rather than one. A host that did not answer is not dialled again.
`fleet status --json` carries the same numbers as its `summary` object (below),
counted by the same code from the payloads it already has — no second call.

`fleet status --host H` (repeatable, like the mutating commands, and also taken
by `fleet health`) asks only the named hosts: an unknown name dies, naming it,
before anything is dialled. The table, the summary line and `--json` all cover
those hosts alone, so `--host build-1` is how to read one host after a call to
it timed out.

Each host that answered gets a **host line** above its slots: the `runnerctl`
version it runs, then the `load`, `Disk:` and `last 1h:` part of its own
`status` header. The load and each partition on it are green, yellow or red:
`fleet watch` keeps the colours the host painted, and `fleet status` (which
asks hosts for plain output) paints the line itself from the numbers, against
this node's `LOAD_WARN_RATIO` / `LOAD_CRIT_RATIO` and `DISK_WARN_PCT` /
`DISK_CRIT_PCT`. The `fleet watch` cursor never stops on a host line.

A host on a release from before the `CPU` column answers with a table
without it. Its rows come under a column header of their own — the header is
printed again whenever a host's differs from the one above it — so on a
fleet mid-upgrade the table shows two header shapes until every host is
upgraded. A central node older than the `load` fragment, under `fleet status
--color always`, paints a newer host's whole host line red, as it paints
events; the text is right, only its colour is not.

The version is compared with **this node's own**, not only with the other
hosts': a fleet uniformly one release behind the central node is level with
itself and still skewed — and this node forwards flags such hosts may not
know. A version other than this node's is painted yellow, and a note under
the table names those hosts, grouped by version, with the side they are on
(`behind` / `ahead`) and `runnerctl fleet upgrade --check` to see what an
upgrade would change. Versions compare as versions (`0.9.0` is behind
`0.10.0`). What a host reports is held to `X.Y.Z`; anything else — or no
version at all, from a runnerctl too old to print one — is drawn `?` and counts as
skew. A host whose header has no `Disk:` fragment (older than 0.16.0, or
nothing to report) gets a host line of its version alone when that version is
not this node's; a level one gets none.

Set the inventory on the **central node only** — the runner hosts need no
fleet config, just `runnerctl` installed and an ssh login:

```bash
FLEET_HOSTS=(build-1 build-2 build-3)   # ssh aliases, or user@host
```

`runnerctl config-example` prints the whole block, including `FLEET_PARALLEL`
(how many hosts at once, default 8), `FLEET_TIMEOUT` (per-host seconds for a
read-only call, default 30), `FLEET_WATCH_TIMEOUT` (per-host seconds for a
read made by [`fleet watch`](#a-live-fleet-view-fleet-watch), default 10),
`FLEET_MUTATE_TIMEOUT` (per-host seconds for a
call that changes things, default 900 — see [the mutating
fan-out](#changing-things-the-mutating-fan-out)), `FLEET_MUTATE_IDLE` and
`FLEET_MUTATE_MAX` (the silence, default 120 s, and the ceiling, default
7200 s, that replace that total for a host whose runnerctl takes
`--heartbeat` — same section), `FLEET_SSH_OPTS` and
`FLEET_RUNNERCTL` (where the remote command lives, if it is not on the ssh
user's `PATH`).

**"Installed" means installed on the PATH a *non-interactive* ssh gets**, which
is not the PATH you see when you log in. `ssh host runnerctl` runs no login
shell and so reads no `~/.profile` — on Ubuntu and Debian that file is what adds
`~/.local/bin` and `~/bin` — so a runnerctl under your home directory works
perfectly when you ssh in and type it, and the fan-out still reports
`remote exit 127 — runnerctl: command not found`. Check it the way the fan-out
sees it, not the way your login does:

```bash
ssh build-1 'command -v runnerctl || echo "not on the non-interactive PATH"'
```

Either install it system-wide (`/usr/local/bin`, which `sshd`'s default PATH
does include) or set `FLEET_RUNNERCTL` to its absolute path, which moves no
files. A host whose runnerctl already carries the placement healing relocates
itself on the next `runnerctl upgrade` — see [Upgrade heals *where* runnerctl
is](#upgrade-heals-where-runnerctl-is-not-only-which-version-it-is). An older
one has to be bootstrapped by hand once, because the version that would heal it
is precisely the version it does not have yet.

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
| `timed out after Ns` | a read-only call did not answer inside `FLEET_TIMEOUT` (`FLEET_WATCH_TIMEOUT` under `fleet watch`). Nothing is known about it. |
| `timed out after Ns — the command may still be running on that host; …` | a call that **changes things** ran out of its own, larger budget. This is *not* "nothing is known": only the local ssh was stopped. The host's command (`drain`, `stop`, `restart`, `apply`, `scale`, `upgrade`, `compose-reap --apply`, `health --restart-stalled` and the rest — the list is under *What the host does once its caller has gone*) then **runs to the end on its own** — every slot it was asked for, each still waiting for idle under `--when-idle` — and records how it ended, as `… (caller gone, ran to the end)`; `runnerctl fleet history --host H` reads that record once it is done, and `runnerctl fleet status` shows where it has got to meanwhile. Read one of them before re-running anything. (A host on a runnerctl from before this behaviour stops instead at its next line of output, part-way.) |
| `connection lost mid-call — the host may have acted; … — Timeout, server H not responding.` | a call that **changes things** was dropped by ssh's keepalive (see *A host that vanishes is dropped in about a minute*) after the connection was up. This is *not* "nothing is known": the host may have started, or finished, the work. `runnerctl fleet status --host H` shows where it got to and `runnerctl fleet history --host H` what it recorded; read one of them before re-running anything. The same ssh words on a read-only call, and any connect failure, stay `unreachable — …`. |
| `remote exit N — …` | the host answered fine and its `runnerctl` exited non-zero. On a host with no runner units that is its own perfectly good message, not a fleet fault. |
| `remote exit 127 — …` | nothing named `runnerctl` on that host's non-interactive ssh `PATH` — see the PATH note above. Set `FLEET_RUNNERCTL`, or install it system-wide. |
| `remote exit 126 — …` | runnerctl **is** there and the ssh login cannot execute it. Installs from 0.9.0 and 0.10.0 landed `0700`/`0711`; `sudo chmod 755` the path the row names, or re-run the installer (0.10.1 widens it). |

The last two are told apart by the exit code rather than the wording, and they
are different faults: 126 names a full path and needs a `chmod`, 127 names a
bare command and needs a `PATH`. Each row carries its own remedy, so the table
is the summary rather than the lookup.

When the hosts are not all on the same `runnerctl` version, a note says so
under the table — on a fleet that is otherwise invisible until something
behaves differently on one box.

`fleet status --json` gives one object with **each host's payload nested
unchanged**:

```json
{"fleet":[
  {"host_name":"build-1","reachable":true,"exit_code":0,"error":null,
   "status":{"runnerctl":"0.8.1","host":{"name":"build-1",…},"slots":[…]},
   "duration_ms":212,"stale":false,"last_seen":1791882000},
  {"host_name":"build-3","reachable":false,"exit_code":255,
   "error":"unreachable — ssh: connect to host build-3 port 22: No route to host",
   "status":null,"duration_ms":10021,"stale":false,"last_seen":null}
],
 "generated_at":1791882000,"runnerctl":"0.8.1",
 "summary":{"hosts":2,"hosts_answering":1,"slots":3,"busy":1,"idle":1,"stalled":0,"down":0,
            "disabled":1,"leaking":0,"disk_crit_hosts":0,"disk_warn_hosts":0,"event_hosts":0,
            "overloaded_hosts":0,"capacity_free":1,"capacity_total":2,"versions":1}}
```

`host_name` is the alias the central node dialled; `status.host.name` is what
the host calls itself. They are separate on purpose — a disagreement between
them is worth seeing. `reachable` is false only for the two "nothing is known"
cases, so a remote error keeps it true.

Every key added since the first release of this envelope comes **after** the
ones that were there, at its level, so a consumer that read it before reads
it the same way:

| key | meaning |
| --- | --- |
| `fleet[].duration_ms` | how long the host's call took, measured on the central node around the ssh call. A call that timed out reports its budget (`FLEET_TIMEOUT`, or `FLEET_WATCH_TIMEOUT` in the stream); a call still out in the stream is null. |
| `fleet[].stale` | true when `status` is an **earlier** answer, kept by the stream for a host that is not answering now (below). Always false one-shot. |
| `fleet[].last_seen` | epoch seconds of the payload in `status`; null when there is none. |
| `generated_at` | epoch seconds when the envelope was assembled, so a saved payload can be aged. |
| `runnerctl` | this (the central) node's version, to measure skew against each `status.runnerctl`. |
| `summary` | the [summary line](#several-hosts-from-one-place-fleet-status)'s numbers, every one always present (a zero is a zero): `hosts`, `hosts_answering`, `slots` and each state `busy` / `idle` / `stalled` / `down` / `disabled`, `leaking`, `disk_crit_hosts` / `disk_warn_hosts` (this node's thresholds, each host once at its worst partition), `event_hosts` (an OOM kill or a disk-full line), `overloaded_hosts` (this node's `LOAD_CRIT_RATIO`), `capacity_free` of `capacity_total` (idle of active), and `versions` (distinct versions, this node's included — 0 when no host answered). Counted by the same code as the line, over exactly the payloads nested above: a host whose payload is not nested, or is stale, counts towards `hosts` (and `hosts_answering`, if it answered) and nothing else. |

#### A stream for a front end: `fleet status --json --watch`

A UI that polls `fleet status --json` pays a full ssh login to every host on
every poll — the cost [`fleet watch`](#a-live-fleet-view-fleet-watch) exists to
avoid. `fleet status --json --watch [--interval N]` (default 5 s) holds one
connection per host the way `fleet watch` does and writes **one envelope per
tick, each on a line of its own** (newline-delimited JSON), until it is
stopped:

```bash
runnerctl fleet status --json --watch --interval 10 | my-dashboard-feed
```

Each tick asks every host one `status --json` over its held connection, in the
background, as `fleet watch` does, and the envelope is written once every host
has answered or the interval is up. A host whose call is still out then, or
whose call failed, is reported as `fleet watch` draws it: `reachable` false
with its `error`, and — if it answered on an earlier tick — that earlier
payload in `status`, `stale` true and `last_seen` its time; `summary` does not
count it. It exits 0, leaving nothing running behind it, on Ctrl-C, on
SIGTERM, and when its reader goes away (the pipe closes). `--stall-after` is
forwarded as for the one-shot.

The one-host `status` refuses `--json --watch` and says to poll it instead:
polling it locally costs a fork, so a stream would buy nothing. Polling the
fleet costs a login per host, so there the trade goes the other way.

Because each payload is nested rather than re-serialised, fleet mode needs no
JSON parser and `runnerctl` still depends on nothing beyond coreutils, awk,
systemd and curl.

**What the central node relays from a host.** Everything a host sends to be
printed — its table rows, column header, host line and notes, what it wrote on
stderr, the output of an action, the journal `L` pages — is filtered once, as
it arrives, before any table, notice or pager sees it. The colours a host
paints (SGR, in the shape and with the attributes `runnerctl` itself uses) are
kept; every other escape sequence — a screen clear, a window title, cursor
movement, a colour that hides text — is removed whole, and every other control
character, bidi control and malformed byte as for a job's own text. So a host
on an older `runnerctl`, or a login banner or wrapper script on one, cannot
act on the operator's terminal. A `--json` payload carrying a raw control byte
is not nested at all: that host gets an `error` and `"status":null`.

**Fleet mode needs `runnerctl` installed on each host.** Piping the script over
ssh on every call would avoid that and remove version skew, but it pays a
transfer on every command to solve a problem a fleet-wide upgrade solves once,
and it would mean relaxing a deliberate refusal (`runnerctl` only accepts
`install` when read from a pipe). Keep the hosts levelled with `runnerctl
upgrade` instead.

#### A live fleet view: `fleet watch`

`fleet status` is the one-shot. `fleet watch` is the same table redrawn in
place, with colour, over ssh connections that **stay open**:

```
$ runnerctl fleet watch --interval 5
runnerctl fleet watch — 3 host(s) — 14:02:11 — every 5s (q to quit)
2/3 hosts answering · 3 slots: 2 busy, 1 idle · 1 host disk crit · 1 host OOM/disk-full · capacity 1 free of 3
HOST     IDX RUNNER          PROFILE  ACTIVE           SINCE  ENABLED  ...  WORKING-ON
build-1  v0.21.0 · Disk: / [docker,work] 24% (353.9G free)
build-1  0   org.build-1-a   ci       active/running   3d 4h  enabled  ...  my-app:test (12m)
build-1  1   org.build-1-b   ci       active/running   2d 7h  enabled  ...  idle 2h31m (7 jobs)
build-2  v0.21.0 · Disk: /var/lib/docker [docker] 96% (37.3G free), /srv/runners [work] 41% (602.4G free) — last 1h: 1 OOM kill
build-2  0   org.build-2-a   ci       active/running   6d     enabled  ...  my-app:lint (2m)
build-3  no answer for 45s — last seen 14:01:26 — unreachable — ssh: connect to host build-3 port 22: No route to host
build-3  0   org.build-3-a   ci       active/running   1d 2h  enabled  ...  my-app:build (4m)

↑↓/jk select  K kill  R restart  S stop  T start  P reap  L logs  ? keys  q quit
```

**Do not build this out of `watch(1)`.** `watch runnerctl fleet status` works
until it doesn't: a fan-out pays a TCP connect, a key exchange and an
authentication *per host per call*, so six hosts at `watch`'s two-second
default is around **180 full ssh logins a minute**. `sshd` starts refusing at
`MaxStartups`, `fail2ban` reads the pattern as an attack, and rows begin coming
back `unreachable` for reasons that have nothing to do with the hosts.

`fleet watch` opens **one connection per host and holds it** for as long as it
runs (`ControlMaster`, over a socket directory of its own). The first tick pays
the handshake; every later tick is another channel on the same socket. It closes
them on the way out rather than leaving them to expire.

Two differences from `fleet status`, each worth knowing:

- **The remotes paint, not this end.** `fleet status` asks every host for
  `--color never` and colours what it adds locally. A live view wants the
  per-cell colour the local `watch` has, and the only thing that knows a cell is
  `STALLED` or memory-throttled is the host that drew it. `--color never` turns
  it off at both ends together.
- **The default interval is 5 s**, not the local watch's 2 s. Every tick is a
  round trip to every host, and a tick that has not finished before the next one
  starts is not a faster view, it is a queue.

**One slow host does not slow the view.** Each host is fetched in the
background, on its own, and a frame is drawn from whatever each host *last*
returned — so a host that accepts the connection and then stalls holds up
neither the other hosts' rows nor the keyboard: the cursor, `q` and a pending
`y` are read the whole time. What you see for a host depends on what it last
did:

| the host | in the frame |
| --- | --- |
| answered this tick | its rows |
| has not answered yet (the first seconds of a watch) | `waiting for its first answer` |
| stopped answering — unreachable, timed out, or its call from an earlier tick is still running when the next one comes due | its **last rows, dimmed**, under `no answer for 45s — last seen 14:01:26 — <why>` |
| never answered, and its call failed | the error row (`unreachable — …`, `timed out after 10s`) |
| answered, and its `runnerctl` exited non-zero | `remote exit N — …`: that is the host's own account of itself, so no old rows are shown under it |

The age counts from the last time that host returned a table, and is brought up
to date at least once per tick. **Kept rows are for reading only**: a host shown
that way is not answering as far as the summary line and `S`'s capacity floor
are concerned, and neither counts a single slot for it. Its rows can still be
selected — a key on one reads the host's state at that moment, as every action
key does, and says so if the host cannot be read.

Every read the watch makes of a host has `FLEET_WATCH_TIMEOUT` seconds (default
10) rather than `FLEET_TIMEOUT`'s 30: each tick's calls, the read an action key
makes before it decides, and the floor's. A host is never asked twice at once —
one still out when a tick comes due is skipped for that tick — and
`FLEET_PARALLEL` still caps how many are in flight. A one-shot `fleet status`
is not affected by any of this.

A host that is slow to answer says so on its host line, after whatever the line
already carries: `build-2  v0.21.0 · Disk: … — answered in 3.2s`. The time is
how long the host's table call took (the number `fleet status --json` reports
as `duration_ms`), and it only appears from a quarter of the host's
`FLEET_WATCH_TIMEOUT` up — 2.5 s at the default — so a healthy fleet's frame
shows none; it turns yellow from three quarters, where the next slow tick is a
timeout. A host with nothing else on its line gets one for it
(`build-2  v0.21.0 · answered in 3.2s`). Neither limit is configurable, and
`fleet status` without `watch` never shows it.

The [fleet summary](#several-hosts-from-one-place-fleet-status) sits directly
under the header rather than at the bottom, so it stays on screen however long
the table is. It is refreshed with the table, whenever a host's answer comes
in.

**A fleet taller than the terminal** — six hosts of four slots is past thirty
lines — is cut to the terminal's height [the way the local `watch`
is](#live-view-watch): the header, the summary, the column header, the legend
and the status line stay put, and a window of the table follows the cursor,
with `↑ N more` / `↓ N more` counting the lines out of sight (a host's `Disk:`
line and the notes are lines too). A host's `Disk:` line comes into view with
that host's first slot, and the notes under the table with the last row, since
the cursor stops on neither. `PgUp`/`PgDn` and `g`/`G` move by a page and to
the ends, and none of it costs a round trip: scrolling redraws the frame in
hand.

`--stall-after` is forwarded by both — the `STALLED` marker (and, for
`--json`, the `stalled` field) is computed wherever it is drawn, which is
always the remote.

**Narrow terminals.** The `HOST` column makes the fleet table wider than a
local one, and a wrapped row in a redraw loop makes the frame jump. So
`fleet watch` measures the assembled frame — `HOST` included, colour codes
not counted — and when it is wider than the terminal it asks every host for
`status --narrow` on the next tick, dropping `MAX`, `HIGH` and `ENVFILE`
exactly as the local `watch` does, with the same 22-column margin before it
puts them back. `fleet watch --narrow` keeps the narrow table from the first
tick; `fleet status --narrow` is the one-shot form (a one-shot never narrows
itself — it is as likely to be piped as read).

A host on a runnerctl older than `--narrow` refuses the flag as an unknown
option. That host is asked again without it in the same fan-out, so it shows
its full-width rows (under its own column header) rather than a
`remote exit 1` row, and a `fleet watch` remembers it and stops sending it the
flag. `runnerctl upgrade` on that host gives it the narrow table too. The same
holds for `--with-json`, each flag remembered on its own: a host too old for
both refuses one per call, so on its first tick it is asked for its table
three times, and from then on sent neither.

`--host H` (repeatable) narrows the watch to named hosts, validated against
`FLEET_HOSTS` exactly as it is for the mutating commands. A host that does not
answer stays **on screen** in every frame, as its last rows or as a row of its
own — a watch that died when one of six hosts rebooted would take the five that
are fine off the screen with it.

**Action keys.** The local `watch`'s keys work here too, against the slot the
cursor is on — and on a fleet that is a *(host, slot)* pair, because every host
has its own `slot-1`:

| key | does, on the selected slot's host |
| --- | --- |
| `↑` `↓` / `j` `k` | move the cursor, across host boundaries; no round trip |
| `PgUp` / `PgDn` | move the cursor a page; no round trip |
| `g` / `G`, `Home` / `End` | the first / last row of the fleet |
| `K` | kill the running job (`runnerctl kill <slot>` there) |
| `R` / `S` / `T` | restart / stop / start the slot; at the confirm line of `R` and `S`, `y` runs it now and `w` runs it **when idle** (`--when-idle`) |
| `P` | reap processes a finished job leaked |
| `D` / `W` / `E` / `X` | on the **host** of the cursor's row, every slot it has: drain, restart when idle (rolling), enable, disable — below |
| `U` | **upgrade** the host of the cursor's row: `upgrade --check` first, the confirm line names `FROM -> TO`, `y` runs `upgrade` and the version is read back — below |
| `Space` / `*` / `u` | **mark** the cursor's slot row (again: unmark it) / every slot row the view shows / clear every mark; with marks, the action keys act on the marked set — below |
| `L` | page the slot's last 50 journal lines through your `$PAGER` |
| `O` | print the URL of the running job's run on the status line; no round trip |
| `:` | a prompt for **any fleet command** — `scale 3`, `health`, `apply --profile ci` — on the cursor's host, the marked rows' hosts, or with `%` every watched host — below |
| `C` | page the **host's** `compose-reap` dry run through your `$PAGER` — what a full docker disk on the host line is holding, and whether it can go. A read, as the login: no confirm, nothing removed. A host without docker says so on the status line |
| `Enter` | show the selected slot in full, in place of the table; no round trip — below |
| `!` `b` `i` `/` `a` `s` `c` `?` | [view keys](#a-live-fleet-view-fleet-watch): filter, sort, collapse, help — below |
| `Esc` | while an action runs: stop following it — the command carries on, its notice still comes — below |
| `q` | quit |

**The slot in full.** `Enter` on a slot row opens the same pane the local
`watch` has ([the slot in full](#the-slot-in-full-enter)) for that *(host,
slot)* pair, with the same keys — `q` / `Esc` / `Enter` go back, `h` shows the
host's block alone, `K` `R` `S` `T` `P` `L` `O` act on that slot. What is
different on a fleet:

- **It asks no host anything.** The pane is read out of the `status --json`
  payload the last tick already brought from that host — the one the summary
  line counts from — so opening, scrolling and leaving it cost no round trip,
  and it refreshes when the next tick's answer lands. An action key pressed in
  the pane still reads the host afresh before it offers anything, exactly as
  it does from the table.
- **A host that has stopped answering still has a pane**: the facts it last
  sent, with the table's age line (`no answer for 45s — last seen 14:02:10 —
  unreachable — …`) at the top of the `Host` block and the rest of what ssh
  said under it. A host that has sent nothing yet says so.
- **`Enter` goes where the row leads.** On a slot row, the slot. On the one
  row of a host that is not answering, that host's block, with the error in
  full. On a folded host (`c`), it opens the fold, as before. A host's `Disk:`
  line and the age line over kept rows are not rows the cursor stops on, so a
  host's block is reached from any of its slots: `Enter`, then `h`.
- **An older host shows `—` for what it does not report.** A `runnerctl` from
  before a field — the run a job belongs to, the leak count, memory pressure —
  simply has that row empty; nothing fails.
- **The repository is the short name** (`my-app`), as that host's payload
  carries it; the run's URL has the owner. The pids and names behind a leak
  count are not in the payload: `runnerctl reap --dry-run <slot>` on the host
  lists them.
- **A remote's strings are a remote's.** They are decoded from the JSON and
  then stripped of control characters like any other text in the pane, and a
  run URL is shown only if it is a run page's address and nothing else.
- In the pane the view keys do nothing: `!` `b` `i` `/` `a` `s` `c` `?` belong
  to the table.

`O` is the one key here that reads the frame's own facts rather than fresh
ones: it prints the run URL out of the `status --json` payload the last tick
brought from that host, so it is the run of the job the row is showing, it
costs nothing, and it still answers for a host whose rows are only being kept.
A URL is checked again on this side before it is printed — it has to be a run
page's address and nothing else — and a host whose `runnerctl` predates the key
says so (`runnerctl fleet upgrade`). The `WORKING-ON` cells in a fleet table
are always the short `repo:job` form: a remote draws its table for no
terminal, so it never has the width for more.

Each of `K` `R` `S` `T` `P` first reads that host's own `status --json` — one
round trip over the held connection — and decides on *that*, not on the frame,
which may be an interval old: a job that finished since the last redraw is not
offered for killing. The confirm line quotes what the host said and names the
exact remote command (`runs on build-2: runnerctl stop example.slot-1`); `y`
runs it, anything else cancels. `R` and `S` offer a second answer on a line of
their own: `w` runs the same command with `--when-idle`
(`runs on build-2: runnerctl stop example.slot-1 --when-idle`), which waits for
the slot's job to finish instead of killing it. It is not a new top-level key —
`s` is the sort key — and it runs in the background like any action, on the
budget a `--when-idle` call earns (`WAIT_TIMEOUT` plus `FLEET_MUTATE_TIMEOUT`).
On a busy slot the warning says `y` kills the job and `w` waits for it. The
result, or the remote's error with its
remedy (a missing sudoers line, say), is the notice under the next frame, which
is a fresh poll so it shows the effect.

**A confirmed action runs in the background**, over the host's held
connection, so the table keeps refreshing and every key keeps working while it
runs — a `--when-idle` restart or a drain can take as long as its wait. While it
runs, a line under the table shows the latest line the remote has printed
(`example.slot-1 on build-1: restart running — waiting for example.slot-1
(job-a) ... 2m`), at most three of them with the rest counted. When it ends, its
result is the notice, as above. **One action per host**: an action key on a host
that has one running says so and issues nothing; a key on another host starts
that host's own. **`Esc` detaches** — the line goes, the command does not: nothing
is signalled, and its notice still arrives. **`q`** (or Ctrl-C) with an action
still running ends only this node's side of it — the job and its ssh — says
which command was left running and that `runnerctl fleet status --host <host>`
shows where it got to, and records it in the fleet log as `<host>=detached`.
On the host a `drain`, `stop`, `restart`, `apply` or `scale` then runs to the
end on its own (see [the mutating
fan-out](#changing-things-the-mutating-fan-out)), and `runnerctl fleet history
--host <host>` reads how it ended.

`S` has a **capacity floor**. A single-slot key is as bounded a target as
there is, so it needs neither `--host` nor `--all-hosts` — but a cursor walked
down the fleet pressing `S`, `y` on every row reaches zero capacity as surely as
an unguarded `fleet stop`, one explicit confirm at a time. So `S` re-reads every
watched host and refuses a stop that would leave fewer than `--min-available K`
slots active across them (default **1**: the watch never stops the last running
slot it can see; `0` turns the floor off). A host that is not answering counts
as nothing available, and the confirm line says how many it left out. The floor
is checked once, when the confirm line is built, so `w` (stop when idle) passes
it exactly as `y` does; `R`, `w` takes none, since the slot comes back. `R` and
`K` are transient and `T`/`P` take nothing away, so they are not gated — the
same split as the fleet commands below.

**Host keys.** `D` `W` `E` `X` act on a whole host: the host of the row the
cursor is on, from any of its slot rows or its folded line (`c`). A host's
`Disk:` line stays a line the cursor passes over — the rows under it are that
host's, and a host key on any of them acts on it. Each reads the host's own
`status --json` at the keypress and names, on its confirm line, the exact
command and every slot it touches; `y` runs it in the background with the host
as its label, anything else cancels (`w` included):

| key | runs on the host |
| --- | --- |
| `D` | `runnerctl drain <every slot>` — one call; each slot stopped once its job is done, one at a time |
| `W` | `runnerctl restart --when-idle <every slot>` — one call; a rolling restart, each slot once its job is done |
| `E` | `runnerctl enable <slot>`, one call per slot, in turn |
| `X` | `runnerctl disable <slot>`, one call per slot, in turn — the confirm line warns about any job it kills |

`E` and `X` are a call per slot because a host's `enable` / `disable` take one
slot; a call that fails ends the action there, with its error as the notice.
`D` and `X` take a whole host's capacity at once, so their **floor is checked
for the host's active slots together**: each slot alone may pass
`--min-available K` while all of them would cross it, and then the key is
refused (`build-1: not drained — it would leave 2 of 6 slot(s) active …`).
`W` takes no floor, as `R` takes none: the roll puts each slot back before it
takes the next. A drain or a rolling restart runs on a budget of
`WAIT_TIMEOUT` per slot plus `FLEET_MUTATE_TIMEOUT`. On the one row of a host
that is not answering, a host key is refused — there is nothing to decide on —
and a slot key still says there is no slot there. `FLEET_SUDO` and the origin
apply as for the slot keys.

**Upgrading a host: `U`.** Like the host keys it acts on the host of the row the
cursor is on, and it asks the host first: `runnerctl upgrade --check` there, a
read that runs as the login and downloads the release to compare (on the
`FLEET_MUTATE_TIMEOUT` budget). Only a host that says `Update available.` with
two plain `X.Y.Z` versions gets a confirm line, which names the exact command
and the versions:

```
build-1: upgrade 0.15.0 -> 0.17.0? runs on build-1: runnerctl upgrade — …  [y/n]
```

`y` runs plain `runnerctl upgrade` in the background (one action per host, as
for every key that changes a host; `FLEET_SUDO` and the origin apply),
anything else cancels. A host that is already current, ahead of its source, not
answering, or whose `--check` answer is not understood is said so and nothing
is issued. When the upgrade ends the host's `version` is read back, as
`fleet upgrade` does, and the notice reports it: `build-1: upgraded 0.15.0 ->
0.17.0, read back 0.17.0`. It says `upgraded` only when the read-back is the
version the host said it wrote; otherwise the notice says `not confirmed` and
names both versions (or that the read-back did not answer), and the
`fleet.log` line records `unconfirmed`. A version a host sends that is not
`X.Y.Z` is never drawn. `U` offers no `--push`: pushing this node's own copy
is `fleet upgrade --push`.

**Marking rows: `Space`, `*`, `u`.** `Space` marks the slot row the cursor is
on (on a marked row, it unmarks it), `*` marks every slot row the view shows —
so `!` then `*` marks exactly the problem rows, and `/` then `*` every row
matching the text — and `u` clears every mark. A marked row has `*` in a
two-column gutter in front of the table, and the legend counts the marks (`N marked, u clears`); with
none marked the table is drawn exactly as before. A mark is the *(host, slot)*
pair, never a position: a sort, a filter or a refresh that reorders the rows
moves it with its slot, and a row a view hides keeps it. A marked slot its host
stops reporting (scaled away) is dropped from the set, and the notice says so
(`mark dropped: example.slot-3 on build-2 — no longer on that host`); a host
that is not answering keeps its marks, as it keeps its rows. Only slot rows are
marked — not a host's error row or a folded host.

**With rows marked, an action key acts on the marked set** instead of the
cursor's row, after **one** confirm line that lists every target and its exact
command, cut with a count (`… and 2 more`) where the terminal is too narrow:

```
Restart 3 marked slot(s)? runs on build-1: runnerctl restart example.slot-1; on build-1: runnerctl restart example.slot-2; on build-2: runnerctl restart example.slot-1  [y/n]
```

| key | over the marked set |
| --- | --- |
| `K` `R` `S` `T` `P` | each marked slot, decided on that slot's own `status --json`, read afresh at the key; a slot the key does not apply to (`T` on an active slot) is skipped and named on a `skipped:` line. `R` and `S` still offer `w` (each with `--when-idle`) |
| `D` `W` `E` `X` `U` | the **hosts** of the marked rows, each once, every slot of each, as the host keys always act; `U` runs each host's own `upgrade --check` first and skips a host that has nothing to upgrade |
| `L` `O` | the cursor's row only, as without marks |

They run as **one background action per host**, every host's started at once:
a host's marked slots are one call each, in turn, inside its one action, so
each host's result is a notice of its own and a `fleet.log` line of its own. A
marked host that already has an action running refuses the whole set, and
nothing is issued. The **capacity floor is the set's**: `S` (`y` or `w`), `D`
and `X` subtract every target's active slots together, so three slots that each
pass `--min-available` alone are refused when the three would cross it
(`3 marked slot(s): not stopped — it would leave 1 of 6 …`). The marks stay
until `u`. In the slot pane (`Enter`) the keys act on the pane's slot, marks or
not.

**Any fleet command: `:`.** The keys are a fixed set; the fleet commands are
not. `:` opens a one-line prompt at the bottom of the view, and what you type
there is a fleet subcommand with its own flags, run through the same code as
the command line — without leaving the view, and over the ssh connections the
watch already holds:

```
:scale 3                     → runnerctl fleet scale 3 --host <the cursor's host>
:apply --profile ci --restart --when-idle
:%health                     → fleet health on every watched host
:upgrade --check
```

- **The scope is explicit and shown before anything runs**: the host of the
  cursor's row; the hosts of the marked rows while any are marked; every
  watched host with `%` in front of the command. On a watch started with
  `--host`, `%` names each watched host; on one that watches the whole fleet it
  adds nothing, so the command is exactly the one you would type. A `--host` or
  `--all-hosts` you type yourself is the scope as typed. `fleet status` and
  `fleet health` take no `--host`, so they are run on the scope's hosts and the
  line says which: `runnerctl fleet health (on build-1)`.
- **Reads run at once** — `status`, `health`, `history`, `profiles`, `upgrade --check`,
  `reap --dry-run`, `compose-reap` without `--apply`, `compose-reap-timer
  status` — and their output opens in your `$PAGER`, as `L`'s does,
  under a first line naming the command that ran.
- **Everything else asks first**, with the command fully expanded:

  ```
  runs: runnerctl fleet scale 3 --host build-1  [y/n]
  ```

  `y` runs it; anything else cancels. It goes through `fleet`'s own code, so
  the capacity gate, `--min-available` / `--max-unavailable` and the commands
  fleet mode refuses (`env-init`, `provision`, `deprovision`, `logs`) behave
  exactly as they do on the command line — a refusal's own words become the
  notice under the table, and the watch carries on. `:%stop` on an unnarrowed
  watch is the `fleet stop` the gate refuses. It runs in the background, as
  an action key's command does: the table keeps refreshing and the keys keep
  working, the latest line it has written shows under the table, and `Esc`
  stops following it without cancelling it. When it ends its last line is the
  notice, the whole output is paged (unless you detached), and the table is
  fetched again. While it runs it holds **every host it targets**: an action
  key on any of them says `busy` and issues nothing, a host it does not name
  is free, and a second `:` command waits for the first to end.
- **The line is split on blanks, and nothing else** — no quoting, no `$`, no
  globbing: it is never handed to a shell, here or on a host. Each word reaches
  the host's `runnerctl` as the one literal argument it was (the fleet commands
  quote every word they forward for the remote shell).
- `↑` / `↓` in the prompt bring back what you typed earlier in the session, the
  usual line editing works, and `Esc` (or an empty line) cancels. `:watch` is
  refused — you are in it — and so is `:status --json --watch`, a stream that
  never ends.

`:` and `C` are not in the one-line legend under the table, which has no column
to spare at 80; `?` lists them.

The cursor survives the frame changing under it. A host that stops answering
keeps its rows, so the cursor stays on the slot it was on (the age line above
them is never a stop); a host with no rows to keep is one row, where keys act
on nothing, and the cursor is back on its slot when the host answers. A slot
that goes away drops the cursor to that host's first slot. `L` is not a stream: the host's
`logs <slot> -n 50` runs to completion under `FLEET_TIMEOUT` and the result is
paged locally, and so does `C`'s `compose-reap`. The keys that change something (`K` `R` `S` `T` `P`, and the
host keys `D` `W` `E` `X` `U`) run under
`FLEET_MUTATE_TIMEOUT` instead, in the background: a restart that sits out a
wedged job's `TimeoutStopSec` is followed for those minutes rather than
reported `failed` about an action that then completes behind it.
Every remote action needs what the same command needs run by
hand over ssh: passwordless sudo on that host, `L` included (`logs` reads the
journal through it). The facts read is a plain `status --json` and needs none.

**View keys: filter, sort, collapse.** On a healthy fleet almost every row is
noise — you are looking for the two that are wrong. These keys choose what the
frame shows, and **none of them asks a host anything**: like moving the cursor,
they redraw what the last tick brought.

| key | shows |
| --- | --- |
| `!` | **problems only**: slots that are `STALLED`, not active (failed, stopped by hand, between restarts), leaking, at or over `MemoryHigh`, or under memory pressure at `PRESSURE_CRIT_PCT`; hosts that are not answering; hosts with a disk at `DISK_WARN_PCT` or worse, or an OOM / disk-full line; hosts on a `runnerctl` version other than this node's |
| `b` / `i` | busy only (a `STALLED` job is a busy slot) / idle only |
| `/` | rows whose host, runner or `repo:job` contains the text you type, whatever its case; combines with `!` `b` `i` |
| `a` | all: clears `!` `b` `i`, the text and the collapse |
| `s` | cycle the order: config order → longest-running job first → most memory used first |
| `c` | collapse to one line per host (`build-1  4 slots: 3 busy, 1 idle · v0.21.0 · Disk: / 41% (…)`), carrying what its host line says; on a host, `c` or `Enter` opens it and `c` closes it again |
| `?` | every key, in place of the table, until a key closes it (↑ ↓ PgUp PgDn g G scroll it) |

```
$ runnerctl fleet watch --problems
runnerctl fleet watch — 3 host(s) — 14:02:11 — every 5s (q to quit) — view: problems only
3/3 hosts answering · 9 slots: 6 busy, 2 idle, 1 STALLED · 1 host disk crit · capacity 2 free of 9
HOST     IDX RUNNER          PROFILE  ACTIVE           SINCE  ENABLED  ...  WORKING-ON
build-2  v0.21.0 · Disk: /var/lib/docker [docker] 96% (37.3G free), /srv/runners [work] 41% (602.4G free)
build-3  v0.21.0 · Disk: / [docker,work] 24% (353.9G free)
build-3  1   org.build-3-b   ci       active/running   1d 2h  enabled  ...  my-app:build (2h10m) STALLED
```

What to know about them:

- **The header names the view** (`— view: problems only · longest job first`),
  and the **summary line keeps counting the whole fleet** — it is the one line
  that says what a filtered frame is a part of. A view that shows nothing says
  `nothing matches — a shows all` instead of drawing an empty table.
- **A disabled slot is not a problem.** Somebody scaled it away on purpose; the
  summary dims it for the same reason. A slot that is merely not active is.
- **A host's `Disk:` line** shows with any of its slots — and under `!` on its
  own when the trouble is the host's (a full disk over healthy slots, or a
  `runnerctl` version other than this node's).
- **A host that stopped answering** is a problem by definition: `!` keeps its
  age line and *all* its kept rows. `b` and `i` filter its kept rows by the
  state it last reported — they are dimmed and under their age, which already
  says how far to trust them. A host with no rows at all (it never answered, or
  its `runnerctl` exited non-zero) is one row under `!` and none under `b` /
  `i`: nothing is known to be busy or idle there, and the summary still counts
  it missing.
- **A sorted table is a flat list.** `HOST` is on every row, so it reads without
  the grouping; the host lines (`Disk:`, age lines, error rows, collapsed hosts)
  move under the rows, in config order. Ties keep config order, and a slot
  without the fact — no job, no memory accounting — sorts last.
- **`/` filters as you type.** `Enter` keeps the text, `Esc` puts back what was
  there before, `Backspace` and `Ctrl-U` edit it, and an empty text matches
  everything. While it is open every printable key is text, `q` included.
- **Action keys act on the row the cursor is on**, whatever the view did to the
  order: the cursor is the *(host, slot)* pair, not a position. A row that
  leaves the view moves the cursor as a row leaving the fleet does. On a
  collapsed host there is no slot to act on — open it first. With rows marked
  they act on the marks instead, which a view does not unmark.
- `--problems` and `--sort config|job|mem` start a watch in a view, so a wall
  display nobody types at shows the right thing from the first frame.

The one-line legend is the one it always was. When a state is on it gives its
place to that state's hints, still on one 80-column line: `a all` with a view on, `N marked, u clears` with rows marked, `Esc detach` with an action attached, in that order, and always `? keys` last (the rest of the keys are under `?`).

`fleet logs` remains unsupported: it streams one journal, and that only makes
sense against one host. For a slot's recent lines, `L` in `fleet watch`.

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

`fleet health --json` is [`health --json`](#health-checks-for-cron--uptime-monitors-health)
for the fleet, with the prose form's exit code: one object, every host's
problems in it, `host` being the name in `FLEET_HOSTS` and `slots` the slots
checked across the fleet (null when a host cannot say). A host that is not
`healthy` in the usual sense is a problem of its own, `slot` null: `kind`
`unreachable` when it did not answer (ssh failed, or the call timed out) and
`error` when its `runnerctl` answered with nothing to read (a host with no
runner units, say), `detail` the row the prose form prints. Each field a host
sends is decoded and filtered as the table's text is (see [what the central
node relays](#several-hosts-from-one-place-fleet-status)) before it is written
again, never passed on as it came. A host on a `runnerctl` from before
`health --json` refuses the flag; it is asked again without it, and each of
its prose lines becomes one problem of kind **`unclassified`**, `slot` the
word before its first `: `.

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
2 host(s) on 0.8.2
```

`--check` writes nothing; it reports each host's installed and available
version and whether it would change. `--ref <branch|tag>` (and `--sha256 SUM`,
see [Verifying the download](#verifying-the-download)) is passed through,
as it is for the single-host command — to the check, to the write, and to the
check round `--canary` makes. `--host H` (repeatable) narrows any of it to the
hosts you name; a name that is not in `FLEET_HOSTS` is refused before anything
is dialled.

**A host that fails is a reported row, never an abort.** A partly upgraded
fleet is the normal outcome of a flaky network, and which host is still
behind is exactly the thing you must not lose. The exit code is non-zero when
any host failed, so a cron job still notices.

**`upgraded` means the host was asked afterwards.** A host that says it wrote
the new script is then asked for `version` through `FLEET_RUNNERCTL` — the
exact command the fan-out runs — and the row reads `upgraded` only when that
answers the version the host said it wrote. The other answers are failed rows
and a non-zero exit:

```
build-1  0.8.1 -> 0.8.2  wrote 0.8.2 but the fleet path still answers 0.8.1
build-2  0.8.1 -> 0.8.2  wrote 0.8.2 but the read-back did not answer: timed out after 30s
```

The first is a write that landed somewhere the fan-out does not execute — a
copy under a home directory shadowing the system one, or a `FLEET_RUNNERCTL`
pointing at a different file. The second says only that the question was not
answered; the write itself was reported done. The read-back is a read, so it
runs on `FLEET_TIMEOUT`, not on the upgrade's `FLEET_MUTATE_TIMEOUT`. It
compares version numbers, so a `--ref <branch>` whose bytes changed under an
unchanged version number verifies as that number and no further.

**A host that only said `Update available.` is still behind.** On a host where
`upgrade` retired a home copy that shadowed the system one but could not write
the system copy without a password, the row reads `update available`. A write
counts it in its own number, not as upgraded, and the exit code is non-zero,
because someone with sudo still has to finish it:

```
2 host(s): 0 already level, 1 upgraded, 0 unreachable or unclear, 1 still behind
```

`--check` is unchanged: there `update available` is what would change.

The last line names where the fleet ended up: `N host(s) on X` when every
host is known to be on one version, otherwise each version with its hosts,
and `unknown` for the ones that did not say.

##### Staging an upgrade: `--canary`, `--serial`, `--stop-on-failure`

By default every host is upgraded at once, `FLEET_PARALLEL` at a time. Three
flags make that more careful; none of them applies to `--check`.

```
$ runnerctl fleet upgrade --canary
canary build-1: upgraded 0.8.1 -> 0.8.2 and the fleet path answers 0.8.2 — continuing with 2 other host(s)
build-1  0.8.1 -> 0.8.2  upgraded
build-2  0.8.1 -> 0.8.2  upgraded
build-3  0.8.2           up to date
3 host(s): 1 already level, 2 upgraded, 0 unreachable or unclear
3 host(s) on 0.8.2
```

- **`--canary [H]`** upgrades one host first and continues only if it ends
  `upgraded` — written *and* read back. Anything else stops there: no other
  host is asked to write, the rest are listed as `not attempted`, and the exit
  code is non-zero. Without a name, the canary is the first host in
  `FLEET_HOSTS` order that **would actually change**, found with a `--check`
  round first — a host that is already up to date proves nothing about the new
  release. When no host would change, it says so and writes nothing. A named
  canary that would not change is refused, naming the hosts that would.
- **`--serial`** upgrades one host at a time, each one written and read back
  before the next is dialled. Every host is still attempted and every row
  reported.
- **`--stop-on-failure`** is `--serial` that halts at the first failed row, or
  at a host that is still behind (it only said `Update available.`), and lists
  the hosts it did not attempt.

They combine: `--canary --stop-on-failure` is one verified host, then the rest
one at a time until something fails.

##### Rolling the fleet back: `--rollback`

`fleet upgrade --rollback` runs `upgrade --rollback` on each host (see
[Rolling back](#rolling-back-upgrade---rollback)) and reads each one's
`version` back, as an upgrade is read back — against the version that host
said it rolled back to:

```
$ runnerctl fleet upgrade --rollback
build-1  0.21.0 -> 0.20.0  rolled back
build-2  —                 remote exit 1 — runnerctl: no rollback copy at /usr/local/bin/runnerctl.prev — nothing to roll back to …
2 host(s): 1 rolled back, 1 unreachable or unclear
not on one version — 0.20.0: build-1; unknown: build-2
```

A host with nothing to roll back to, one whose rollback the fan-out's path
does not see (`rolled back to X but the fleet path still answers Y`), and one
that answers anything but the rollback sentence (an older runnerctl that does
not know the flag) are failed rows and a non-zero exit. `--host`, `--serial`
and `--stop-on-failure` stage it as they stage an upgrade —
`--rollback --serial --stop-on-failure` is the careful shape. `--check`,
`--canary`, `--ref` and `--sha256` are refused before anything is dialled: a
rollback has no dry run and downloads nothing, and a canary is chosen by what
an *upgrade* would change.

An answer this does not recognise is shown verbatim rather than folded into
"up to date" — quietly reporting a host as level when it said something else
is what sends someone to the wrong box.

##### Sending this node's own copy: `--push`

A plain `fleet upgrade` has each host download the release itself, so every
host needs outbound HTTPS to `UPGRADE_URL`, `latest` is resolved on each host
at a slightly different moment, and a host with no working `runnerctl` cannot
be reached at all. `--push` sends **this node's own installed script** over
the ssh connection instead:

```
$ runnerctl fleet upgrade --push --check
build-1  0.8.1 -> 0.8.2  differs
build-2  0.8.2           same
build-3  none -> 0.8.2   absent
build-4  0.9.0 -> 0.8.2  newer than this node — left alone
4 host(s): 2 up to date, 2 would change, 0 unreachable or unclear

$ runnerctl fleet upgrade --push
build-1  0.8.1 -> 0.8.2  upgraded
build-2  0.8.2           same
build-3  none -> 0.8.2   upgraded
build-4  0.9.0 -> 0.8.2  newer than this node — left alone
4 host(s): 2 already level, 2 upgraded, 0 unreachable or unclear
not on one version — 0.8.2: build-1 build-2 build-3; 0.9.0: build-4
```

For each host it first reads the sha256 and `RUNNERCTL_VERSION` of whatever
`FLEET_RUNNERCTL` resolves to for the ssh login:

- **`same`** — the checksum is this node's. Nothing is sent.
- **`newer than this node — left alone`** — `upgrade`'s `not downgrading`
  rule. Nothing is sent, and there is no flag to override it: push an older
  script from a node that runs it.
- **`differs`** — another version, or the same version with other bytes, or a
  pre-config script with no version. The script is pushed.
- **`absent`** — `FLEET_RUNNERCTL` resolves to nothing (exit 127). The script
  is pushed, which bootstraps the host from the central node in one command.

A pushed host lands the bytes in a fresh `mktemp` file, checks them against
this node's sha256 and refuses on a mismatch, then runs `sudo -n bash <that
file> install` — an ordinary file install, so `install`'s own rules apply:
a pre-config script is migrated first, a newer one is never overwritten. The
temp file is removed on every path. The row says `upgraded` only when the
checksum read back through `FLEET_RUNNERCTL` afterwards is this node's.

`--push --check` writes nothing and sends nothing; its exit code is non-zero
only for a host that could not be read, as for `--check`. `--host`,
`--canary`, `--serial` and `--stop-on-failure` stage a push exactly as they
stage an upgrade. `--ref`, `--sha256` and `--rollback` are refused: a push
downloads nothing and sends what this node runs — to push a different version,
upgrade this node first. The central record (`fleet history`) names the
push and the sha256 that was sent.

A push needs **passwordless `sudo bash` for the ssh login** on each host
(`sudo -n`, so a host without it is a named row, never a hang). That is wider
than either sudoers shape below, `FLEET_SUDO=1` does not change it, and it is
root for that login — use it where the fleet login already has full sudo, or
for bootstrap.

##### The sudo requirement

`upgrade` writes the installed script, which on a normal host needs root, so
**this is the first fan-out that needs passwordless sudo on each runner
host.** [The narrow sudo contract](#the-narrow-sudo-contract) below grants it
with one line naming `runnerctl`; the lines here are the compatible option,
for hosts that cannot change yet. They name the binaries the write uses:

```
# /etc/sudoers.d/runnerctl  (on each runner host)
# `upgrade` stages the new script beside the old one and swaps it in, so the
# write path is cp + chown + chmod + mv. Check the binary paths on your own
# distribution before pasting this — they are not the same everywhere.
%runnerctl ALL=(root) NOPASSWD: /usr/bin/cp, /usr/bin/chown, /usr/bin/chmod, /usr/bin/mv
```

**This line is equivalent to root for that login.** A sudoers entry that
names a binary with no arguments grants it with *any* arguments, and root
`cp`, `chown`, `chmod` or `mv` can each replace any file on the host. Give
the fleet a dedicated login and key, used for nothing else, if you grant it.

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

These differ from the read-only commands in five ways, all deliberate.

**Their own time budget.** `FLEET_TIMEOUT` (30 s) is sized for a status read;
these are slow by design, so each host gets `FLEET_MUTATE_TIMEOUT` instead
(default 900 s — raise it for hosts with many slots, since a plain `restart`
of slots whose jobs ignore SIGTERM sits out `TimeoutStopSec` for each in
turn). `--when-idle` and `drain` wait on top of that, for up to `--timeout`
**per slot**, so their budget is *slots on that host × the wait +
`FLEET_MUTATE_TIMEOUT`*: the host is first asked how many slots it has (one
read-only `status --json`), and three slots under the default 1800 s wait get
6300 s. The wait is the `--timeout` you pass, else the **central node's**
`WAIT_TIMEOUT` — a host whose own config raises `WAIT_TIMEOUT` waits longer
than the central node can know, so pass `--timeout` explicitly there.
`fleet upgrade` and `fleet health --restart-stalled` are on the same budget.

If a host does run out of it, the row says `timed out after Ns — the command
may still be running on that host; 'runnerctl fleet status --host H' shows where
it got to` (with the host's own name for `H`), and it means that: the timeout stops the local ssh, not the remote
`runnerctl`. The fan-out then moves on to the next host, so check before
re-running.

**A host that says it is alive is not held to a total.** Every
call above — the fan-out, a `--max-unavailable` / `--min-available` walk's
slot calls, a `fleet watch` action key and its `:` commands, `fleet upgrade`'s
write (and `--rollback`), `fleet upgrade --push`'s install and `fleet health
--restart-stalled` — also asks the
host for `--heartbeat=N`, with N a quarter of `FLEET_MUTATE_IDLE` (default
120 s, so N = 30). A runnerctl that knows the flag then prints a line at least
every N s of every phase that can block, and at most about 2N apart across two
phases, so for such a host the budget above is replaced by two limits:

- **`FLEET_MUTATE_IDLE`** — the call is cut once the host has printed no line
  for that long. The row says `timed out — no line from it for 120s
  (FLEET_MUTATE_IDLE) — the command may still be running on that host; …`,
  with the same `fleet status --host H` pointer as above.
- **`FLEET_MUTATE_MAX`** (default 7200 s) — a call that keeps printing is cut
  there all the same (`timed out after 7200s, the FLEET_MUTATE_MAX ceiling —
  …`), or at the budget above where that is longer, so a long `--when-idle`
  drain is never held to less than it was.

Half of `FLEET_MUTATE_IDLE` is left for the ssh round trip, which is why it
must be 10 or more (0 turns this off and puts every host back on the total);
`FLEET_MUTATE_MAX` must be more than it. The heartbeat lines themselves are
not shown — they only say the host is alive. A host whose runnerctl predates
the flag refuses it (`unknown command '--heartbeat…'`, nothing done), is asked
again without it — once per run, and once per `fleet watch` session — and
stays on the total above. `fleet upgrade --push` is the exception that has no
older host: the flag rides inside the install command, where the script being
pushed — this node's own — reads it, so every pushed host is on the two limits,
whatever runnerctl it had before. Its silence is counted from the moment the
host says it has received the script, not from the start of the call: the
script goes over ssh's stdin first, and nothing can print while it does, so a
slow link is not cut as silent. That transfer is held to the ceiling alone
(`FLEET_MUTATE_MAX`, or the total above where that is longer), and the install
after it to both limits.
`fleet upgrade --check` is a read and is not asked.

**What the host does once its caller has gone.** The same happens when you
press Ctrl-C on the central node, quit `fleet watch` with an action still
running, or lose the network: only the local side ends. The host's `drain`,
`start`, `stop`, `restart`, `apply`, `scale`, `upgrade` (and `upgrade
--rollback`), `deprovision`, `kill`, `reap`, `enable`, `disable`,
`remove-limits`, `env-init`, `compose-reap --apply`, `health
--restart-stalled`, `provision`, `install` (what `fleet upgrade --push` runs
on each host), `migrate` and `compose-reap-timer install`/`remove` **finish
what they started** rather than stopping part-way. `deprovision` does this
only once its `y/N` question has been answered. Once a command that finishes has begun changing things, a closed
connection does not end it: its output is passed on while there is someone to
read it and dropped after that, and a hangup (SIGHUP) is ignored. It goes on
slot by slot, waiting for idle as it was asked to, and each wait is still
bounded by its `--timeout`. Its record then says so —
`drain all by deploy via fleet from alice@central-1 — ok (caller gone, ran to
the end)` — which `runnerctl fleet history --host H` reads back. The choice
is deliberate: stopping at a slot boundary would still leave the host half
done, with some slots on the new config or out of the pool and nobody left to
finish the job. A deliberate Ctrl-C or SIGTERM **on the host itself** still
stops the command there and is recorded as `interrupted`. A host on a
runnerctl from before this behaviour stops at its next line of output instead,
so upgrade the fleet before relying on it.

**A host that vanishes is dropped in about a minute.** Every fleet ssh call
sends a keepalive (`ServerAliveInterval=15`, `ServerAliveCountMax=4`). A host
that is powered off or cut off mid-call is reported `unreachable` after about
a minute rather than holding its place for the whole budget, while a slow but
live host keeps answering and is waited for. For a mutating call the row
says `connection lost mid-call` instead, because the connection is gone and
the host may have done part of the work. ssh keeps the *first* value it is given for an option, and
runnerctl puts the keepalive after `FLEET_SSH_OPTS`, so setting
`-o ServerAliveInterval=…` there changes it. `BatchMode` and `ConnectTimeout`
come before it and cannot be changed that way.

**One host at a time.** `FLEET_PARALLEL` is ignored for mutating commands.
Combined with the per-host `--when-idle` (one slot at a time *within* a host),
that bounds the blast radius to a single host at any moment. It is slow on a
large fleet; that is the right trade for something that can take CI capacity
down.

**Their lines are shown as they are printed.** Because they run one host at a
time, nothing interleaves, so each line the running host prints appears
straight away, as `host: line` — a drain that waits for a busy slot shows its
`waiting for … ` line every minute rather than nothing until the whole fleet
is done. What the host prints on stderr is shown the same way, on *your*
stderr (so `2>` still separates it). Each line is drawn as safe text, as every
line from a host is: its colours are kept and any other control sequence is
dropped, and a last line the host never finished is shown once its output
ends. Nothing is shown twice: the report that follows is each failed host's
row (its exit status, the first line of its stderr and what to do about it) and
the `fleet <command>: N host(s) ok, M failed` count. With `--max-unavailable`
and `--min-available` each slot's lines carry `host slot N: `. `fleet upgrade`
(and `--push`) show the write the same way, before the table; its hosts run
side by side unless `--serial`, so lines of different hosts may alternate, each
whole and carrying its host. The read-only commands (`status`, `health`,
`history`, `fleet status --json`) stay buffered until every host has answered.

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
passwordless sudo for them — through [the narrow sudo
contract](#the-narrow-sudo-contract) below, or, as the compatible option for
hosts that cannot change yet, a grant of the binaries the fan-out uses:

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
upgrade`. `fleet compose-reap --apply` asks sudo for nothing under this line:
the host's `compose-reap` talks to docker as the login, which needs the
`docker` group there instead (a `docker` group member is root-equivalent on
that host too). `fleet compose-reap-timer install` / `remove` use `tee`, `rm`
and `systemctl`, which the line already grants.

**This line is equivalent to root for that login, too.** Unrestricted root
`tee` or `rm` writes or deletes any file, and unrestricted `systemctl` and
`kill` reach every service and process on the host, not only runner units —
on a CI host that runs code from pull requests. Give the fleet a dedicated
login and key, used for nothing else, if you grant it.

Without it the fan-out **fails fast and names the host**, with the remedy
appended to the row — it never hangs, because ssh runs with `BatchMode=yes`:

```
box-2: remote exit 1 — sudo: a password is required — the ssh login needs
passwordless sudo on that host; see the fleet section of the README for the
exact sudoers line
```

##### The narrow sudo contract

Grant the login **runnerctl itself** rather than the primitives it calls,
**opt the host in**, and set `FLEET_SUDO=1` in the central node's config.
Every call that changes a host then runs as `sudo -n <FLEET_RUNNERCTL> <verb>
…` there, so runnerctl runs as root from the start and asks sudo for nothing
more. On each runner host, both of these:

```
# /etc/sudoers.d/runnerctl  (on each runner host)
# One command, the exact absolute path runnerctl is installed at.
%runnerctl ALL=(root) NOPASSWD: /usr/local/bin/runnerctl
```

```
# /etc/runnerctl/config  (on each runner host — root:root, 0644)
SUDO_CONTRACT="narrow"
```

**The opt-in is part of the contract.** The sudoers line alone, without
`SUDO_CONTRACT="narrow"`, is **still root-equivalent**: `sudo runnerctl
--config <a file the login wrote>` runs that file as root, and `apply
--env-file`, `--save` and the other flags below each widen it again. With the
opt-in, runnerctl refuses all of them under sudo (below). It is read only
from `/etc/runnerctl/config` — never from a `--config` or `RUNNERCTL_CONFIG`,
which can neither set it nor clear it — and a value other than exactly `full`
counts as `narrow`. Without it (`full`, the default) nothing is refused, so
an admin's own `sudo runnerctl …` on a host with a full sudo grant works as
it always has: there the caller is root anyway.

And on the central node:

```
# /etc/runnerctl/config  (on the central node)
FLEET_SUDO="1"
FLEET_RUNNERCTL="/usr/local/bin/runnerctl"   # the path the sudoers line names
```

**What goes through sudo:** the mutating fan-outs (`fleet apply`, `scale`,
`start`, `stop`, `restart`, `drain`, `kill`, `reap`, `remove-limits`,
`enable`, `disable`, with or without a budget), `fleet health
--restart-stalled`, `fleet upgrade` and `fleet upgrade --rollback`, `fleet
compose-reap --apply` and `fleet compose-reap-timer install` / `remove`, and
`fleet watch`'s action keys and `L` (the host's `logs` reads the journal
through sudo). **What does not:** `fleet status`, `fleet health`, `fleet
watch`'s ticks and the reads its keys make first, the summary's `status
--json`, `fleet upgrade --check` and the read-back after an upgrade, `fleet
compose-reap` without `--apply` (and `fleet watch`'s `C`) and `fleet
compose-reap-timer status`. Those still run as the plain login — the dry run
needs the login in the host's `docker` group. On an opted-in host,
`compose-reap --apply --standalone`, `--max-age-hours` and `--grace-minutes`
are refused under sudo (below): that host's row says so.

**What it bounds.** As root, the login can do what runnerctl's verbs do —
units matching `UNIT_GLOB`, the managed drop-in, runnerctl's own file — and
not more, because on an opted-in host runnerctl refuses under sudo
everything that would widen that back to root:

- a config other than `/etc/runnerctl/config` (`--config`, `RUNNERCTL_CONFIG`):
  a config is sourced as bash, and a root-owned file can still hold text the
  caller wrote;
- that config in a directory, or runnerctl itself (and its directory), that
  is not root-owned or is writable by group or others;
- every flag that picks what root runs, sources or installs, where it
  writes, whose account a runner runs as, or what it removes beyond the
  host's own policy — `apply`/`scale --env-file` and `--save`, `env-init
  --env-file`, `upgrade`/`install --prefix`, an `upgrade`/`install --ref`
  that is not a release version, `migrate --from`/`--output`, `provision
  --url`/`--runner-user`/`--runner-root`/`--work`/`--runner-version`/
  `--no-verify-checksum`, `deprovision --url`, `compose-reap
  --standalone`/`--max-age-hours`/`--grace-minutes` — each refused by name;
- `fleet` itself, which would dial out with root's ssh identity.

Taken as given, and validated: the global `--origin OPERATOR@HOST` that
`fleet` puts in front of every verb that changes a host (GHR-88, see [Who
changed what](#who-changed-what-history-and-fleet-history)). It is checked
against a conservative shape — one `@`, and on each side letters, digits,
`.`, `_` and `-` only — written into the host's journal record, and read by
nothing else: no path, config, command or decision depends on it, so it
cannot widen the grant. One that fails the check is dropped and the record
says `origin invalid`.

Taken as given too: the global `--heartbeat N` (GHR-149), whole seconds from
1 to 3600 and refused otherwise. It changes only how often a command that is
already allowed prints a progress line while it blocks — a `heartbeat: …
(Ns)` line beside a systemctl call or a download, and the `waiting for …`
line of a `--when-idle` or `drain` wait at least every min(60, N) s. It
decides nothing else. A host whose runnerctl predates it refuses it as an
unknown command and does nothing, which is how a caller learns that the host
has no heartbeat.

Under any sudo, opted in or not, it also pins `PATH` and `HOME`, drops the
caller's pager and every `RUNNERCTL_*` variable, and runs a pager in secure
mode. Sudo is detected as uid 0 with a non-zero `SUDO_UID`, which a root
shell from `sudo -i` also has: on an opted-in host the refusals apply there
too. To use a refused flag there, run the command without `sudo` (runnerctl
asks sudo for each privileged step itself) or set the value in the config.

**The central node can check one half for you.** It cannot read a host's
sudoers, so it cannot tell the narrow line from a full grant — check that on
each host yourself. It can read the opt-in: every host reports its
`SUDO_CONTRACT` in `status --json` (`host.sudo_contract`), and with
`FLEET_SUDO=1` `fleet status` and `fleet watch` name each host that does not
say `narrow` — on its host line, and in a note:

```
note: FLEET_SUDO=1 runs 'sudo -n runnerctl …' on every host, and without
SUDO_CONTRACT=narrow in the host's /etc/runnerctl/config that grant is
root-equivalent — box-2 reports SUDO_CONTRACT full; box-3 does not report a
SUDO_CONTRACT this node can read; set it there (…)
```

A host that reports `full` is a choice (or a forgotten line); one that
"does not report a `SUDO_CONTRACT` this node can read" is an older runnerctl
(upgrade it first), a config its login cannot read, or a value that is neither
`narrow` nor `full` — all treated alike, since none of them shows an opt-in.
Only a host that answered is judged, and only its answer of the moment (the
rows `fleet watch` keeps for a host that stopped answering are not). Under
`FLEET_SUDO=0` nothing is read or drawn. In `fleet watch`, `!` keeps a flagged
host. A host whose value the central node can read as `narrow` is the opt-in
as that host's config states it; a host that merely lies, or has the sudoers
half wrong, is not something a status call can see.

**What it does not bound.** The verbs themselves: the login can stop,
restart, kill, reap, provision and deprovision runners, roll the script back
to its `.prev`, and upgrade to any published release. (`provision` and
`deprovision` used to run the runner's own `svc.sh` as root from a directory
the runner account can write; since GHR-110 they run nothing from a runner's
directory as root — see [Provisioning runners](#provisioning-runners).) And
it holds only
while sudo keeps its defaults: `env_reset` on, no `SETENV` or `env_keep` for
this command, `NOPASSWD` alone — a grant that lets the caller set the
environment hands `BASH_ENV` to bash before runnerctl's first line runs.

**File ownership is part of the contract.** The path the sudoers line names
must be root-owned and writable by root alone, in a directory only root can
write, or the grant is a grant to rewrite it: `runnerctl install` puts it at
`/usr/local/bin/runnerctl` as `root:root 0755`, and on an opted-in host
runnerctl refuses to run under sudo otherwise. `/etc/runnerctl` and its
`config` the same — that file is also where the opt-in lives.

A sudoers line that names a different path from the one `FLEET_RUNNERCTL`
resolves to answers only `sudo: a password is required`. Under `FLEET_SUDO=1`
the row says what that means:

```
box-2: remote exit 1 — sudo: a password is required — FLEET_SUDO=1 runs
'sudo -n /usr/local/bin/runnerctl …' there and sudo refused it: that host's
sudoers line must grant NOPASSWD the exact absolute path sudo resolves
'/usr/local/bin/runnerctl' to (set FLEET_RUNNERCTL to that path); see 'The
narrow sudo contract' in the README
```

##### Compose leftovers across the fleet: `fleet compose-reap`

The host line's `Disk:` says a host's docker filesystem is filling; the next
question is what holds it and whether it can go — which is
[`compose-reap`](#removing-compose-stacks-a-dead-job-left-behind-compose-reap)'s
dry run, now asked of every host at once:

```
$ runnerctl fleet compose-reap
build-1: reap harness-123456 reason=gone:pid:123456 idle=120m containers=1 networks=1 volumes=0
build-1: keep harness-4242 reason=live:pid:4242 idle=120m containers=1 networks=0 volumes=0
build-1: compose-reap: mode=dry-run projects=2 reap=1 keep=1 removed=0 failed=0 …
box-3: no docker on this host — nothing for compose-reap to inspect (information, not a failure)
fleet compose-reap (dry run, nothing removed): would reap 1 stack(s) — 1 container(s), 1 network(s), 0 volume(s), 0 image(s) — on 1 host(s); 1 host(s) without docker
```

It takes `--host H` (repeatable) and forwards `--standalone`, `--project
NAME`, `--max-age-hours N` and `--grace-minutes N` to each host. The dry run is
a read: in parallel like `fleet status`, as the plain ssh login (never through
`FLEET_SUDO`), and nothing is removed anywhere. Its verdicts are what that
login can see: a slot whose processes it cannot read counts as idle, as for a
dry run by hand. The total counts the stacks each host would reap with their
containers, networks and volumes, plus `--standalone` containers, and the
images those free. Each host asks the daemon, read-only, whether a container it
would not remove still uses a candidate image, and prints `would remove image
X` or `keep image X reason=in-use` for each, so the image count is exact. A
host on an older runnerctl says nothing of images; while one has candidates the
total reads *up to* N, counting that host's candidates unchecked, until
`runnerctl fleet upgrade` brings it up to date.

`--apply` goes through the [mutating fan-out](#changing-things-the-mutating-fan-out)
— one host at a time, streamed, recorded, `FLEET_SUDO` and the origin as for
every command that changes a host:

```
$ runnerctl fleet compose-reap --apply --host build-1
build-1: …
build-1: compose-reap: mode=apply projects=2 reap=1 keep=1 removed=2 failed=0 …
fleet compose-reap: 1 host(s) ok, 0 failed
```

**No capacity gate**, and that is a decision: it removes a dead job's
leftovers and never touches a runner slot, and a running job's stack is kept
because its job is alive. Each host's own `--apply` still refuses where there
are no runner units.

Two rows to know:

- **A host without docker** is a row of information and does **not** make the
  exit code non-zero — a fleet where only some hosts run compose is the normal
  case. `--apply` counts it apart too: `fleet compose-reap: 2 host(s) ok, 0
  failed, 1 without docker`.
- **A login the daemon refuses** is a failed row naming the fix:

  ```
  box-2: remote exit 1 — runnerctl: cannot talk to the docker daemon as ci-fleet:
  permission denied while trying to connect to the docker API at
  unix:///var/run/docker.sock — the ssh login is not in that host's docker
  group: add it there ('sudo usermod -aG docker <login>', effective at its next
  login); a compose-reap --apply under FLEET_SUDO=1 runs as root and needs no
  group
  ```

The hourly timer, per host:

```
$ runnerctl fleet compose-reap-timer status
build-1: installed (enabled, active)
build-2: not installed
gw-1: unreachable — ssh: connect to host gw-1 port 22: No route to host
fleet compose-reap-timer: 1 installed, 1 not installed, 1 unreachable
```

`status` (the default) asks each host for `compose-reap-timer status --brief`,
as the login; it exits 0 when every host answered, installed or not. A host
whose runnerctl predates `--brief` says so, with `fleet upgrade` as the fix.
`install` and `remove` take `--host H` and go through the mutating fan-out;
each host's `install` keeps its own refusal — the runnerctl a root timer runs
must be root-owned and writable by nobody else — and it comes back as that
host's row.

In `fleet watch`, `C` pages the cursor's host's dry run, and the `:` prompt
runs `compose-reap` (without `--apply`) and `compose-reap-timer status` at once,
as reads.

##### What does not fan out

- **`env-init` never will.** It writes an EnvironmentFile of secrets, and
  fanning it out means copying secrets over ssh. Run it on each host.
- **`provision` and `deprovision`** take a GitHub token, so fanning them out
  copies a credential to every host — and a runner name or slot index means a
  different runner on each host. Run them on the host.
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
values for one invocation — add `--save` to keep them
([below](#saving-a-profile-back-into-the-config---save)).

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

### Saving a profile back into the config: `--save`

A flag override is durable in the *drop-in* and not durable as *policy*: the
next `runnerctl apply --profile ci` re-renders `MemoryHigh` from the profile
function in the config, and the override is gone. Keeping it meant hand-editing
the config on every host, which is the step that gets skipped. `--save` writes
the profile **as applied** — the profile function's values with the flags
layered on top — back into the config:

```sh
runnerctl apply --profile ci --high infinity --save
# Applied profile 'ci': … MemoryMax=26G MemoryHigh=infinity MemorySwapMax=0
# Saved profile 'ci' to /etc/runnerctl/config (previous version: /etc/runnerctl/config.bak).
#   verified: /etc/runnerctl/config re-renders the drop-in just applied.
```

Across a fleet, each host saves its own copy — the config is per host, so this
is the only form that makes an override stick everywhere:

```sh
runnerctl fleet apply --profile ci --high infinity --save
```

The config is bash and is sourced, so `--save` rewrites a *block* rather than
parsing the language. It **replaces** `profile_<name>() { … }` where the file
defines one on its own line closed by `}` in column 1, **appends** a block
where the file defines none, **creates** the config (root-owned, `644`) where
there is none, and **refuses** everything else: a one-line body, `function
profile_x {`, two definitions of one name, or a block holding more than the
profile knobs — a computed `MEM_MAX`, a conditional — which a rewrite would
silently flatten. A refusal names the line and leaves the config untouched;
the drop-ins that were applied stay applied either way.

The saved config is proved before it is installed: the candidate is sourced,
the profile loaded back out of it, and the drop-in re-rendered — it must come
out byte-identical to the one just written, or nothing is saved at all. The
previous file is kept at `<config>.bak`. `scale N --save` saves the same way,
and without the flag the config is never written.

Under sudo, the save follows the directory rule `install` does: in a config
directory only root can write, root writes the file as before; in one a single
user owns (a `--config` under a home), every call is made as that user, so a
new config there is theirs, `644`; and a directory anyone else can write — or a
config or `.bak` in it that someone other than its owner holds — is refused
before the first drop-in is written, naming the directory.

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
runnerctl upgrade --check      # report installed vs available, change nothing
runnerctl upgrade              # install the latest tagged release
runnerctl upgrade --ref v0.1.0 # pin a specific release
runnerctl upgrade --ref main   # track main instead of tagged releases
runnerctl upgrade --no-relocate # upgrade exactly where this copy stands
runnerctl upgrade --sha256 SUM # install only bytes with this SHA-256
runnerctl upgrade --rollback   # put back the version the last upgrade replaced
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

#### Verifying the download

Each release publishes `runnerctl.sha256` beside the script — one `sha256sum`
line, written by the release job from the same tagged bytes it attaches. When
the source is a release asset (the default `UPGRADE_URL`, or `--ref vX.Y.Z`),
`upgrade` fetches it and checks the download against it **before anything is
written**:

| what the digest request gets | what `upgrade` does |
| --- | --- |
| a digest that matches | installs, with `verified: sha256 … matches <url>` |
| a digest that does not match | refuses; the installed file is untouched |
| not found (404) — releases published before the digest was | installs, with one `not verified: …` line |
| anything else — a timeout, a 5xx, a body that is not a `sha256sum` line | refuses |

The last row is deliberate. If every failure to read the digest fell back to
installing unverified, anyone able to block that one request would switch
verification off. A source that is not a release asset — a branch `--ref`,
raw.githubusercontent.com, a mirror elsewhere — has no digest and installs
with a `not verified:` line. (A `file://` `UPGRADE_URL` ending in `/runnerctl`
is checked against a `runnerctl.sha256` beside it when there is one, so a
local mirror can carry its own.)

`--sha256 SUM` pins the digest by hand — the same flag and the same 64
lowercase hex characters as `provision --sha256`. It replaces the published
digest, which is then not fetched at all, so a host can install a release
whose digest you obtained some other way. `fleet upgrade --sha256 SUM`
forwards it to every host.

**What this protects against, and what it does not.** The digest comes from
the same place as the script. It catches a corrupted or truncated download
and a tampered mirror or proxy between you and GitHub; it does **not** catch a
compromised release, because whoever can replace the script asset can
replace its digest too. Signing the release is a separate, larger step that
this does not take.

#### Rolling back: `upgrade --rollback`

Every upgrade that replaces a script keeps the one it replaced as
`<path>.prev` — written before the swap, with the script's own owner and mode,
staged and renamed like the script itself. Exactly one is kept: the version
immediately before.

```
$ runnerctl upgrade --rollback
installed: 0.21.0 (/usr/local/bin/runnerctl)
rollback: 0.20.0 (/usr/local/bin/runnerctl.prev)
Rolled back 0.21.0 -> 0.20.0 at /usr/local/bin/runnerctl

runnerctl 0.20.0
```

It renames `.prev` back over the script you are running and runs the result's
`version` as proof. It downloads nothing, so a release that broke its own
download path can still be undone, and it takes no other option. The
rollback **uses up** `.prev`: a second `--rollback` refuses, because there is
nothing left to go back to — going forward again is `upgrade` (or `upgrade
--ref vX.Y.Z`). A fresh install, a relocation onto a new path and a
pre-config script leave no `.prev`. `upgrade --check` says which version a
rollback would restore (`rollback: 0.20.0 (…)` or `rollback: none (…)`).

#### Upgrade heals *where* runnerctl is, not only which version it is

A version-only upgrade cannot fix the most common reason `fleet` cannot reach a
host. `ssh host runnerctl` runs no login shell and so reads no `~/.profile` —
which on Ubuntu and Debian is what adds `~/.local/bin` and `~/bin` — so a
runnerctl under a home directory works perfectly when its owner types it, and
the fan-out reports `remote exit 127` forever. Upgrading it in place healed the
version every time and the reachability never.

So `upgrade` picks a target the way `install` does:

| what it finds | what it does |
| --- | --- |
| a copy outside any home | upgrades it in place — unchanged behaviour |
| a home copy, nothing installed system-wide | moves it to `--prefix` (default `/usr/local/bin`), retiring the old one as `.retired` |
| a home copy **shadowing** a system one | retires the home copy — you were typing one version while `fleet` ran another — and upgrades the system copy |

```
$ runnerctl upgrade
installed: 0.8.1 (/home/jon/.local/bin/runnerctl)
available: 0.10.3 (https://.../runnerctl)
note: this copy is not on the PATH a non-interactive ssh gets, so 'fleet' cannot run it
relocated: /home/jon/.local/bin/runnerctl -> /usr/local/bin/runnerctl
retired: /home/jon/.local/bin/runnerctl.retired
Upgraded 0.8.1 -> 0.10.3 at /usr/local/bin/runnerctl
```

**It only ever acts when the privilege is already free** — the location is
writable, you are root, or `sudo -n` succeeds. Otherwise it upgrades in place
and names the remedy instead. It never prompts for a password: `fleet upgrade`
fans this command out, and one prompt would hang the fan-out on that host,
which is exactly what `BatchMode=yes` prevents on the ssh side.

Two deliberate limits. A shadow is **not** retired when the system copy behind
it is *older* — that would quietly downgrade what you get when you type
`runnerctl`. And when the shadow is retired but the system copy still needs a
privileged write, the last line is `Update available. Run: sudo
/usr/local/bin/runnerctl upgrade`, not `Upgraded`: the command reports work
outstanding rather than work it did not do.

Every command runnerctl tells you to run under `sudo` names an **absolute
path**, deliberately. `sudo` resets `PATH` to `secure_path`, which does not
include `~/.local/bin` — so a bare `sudo runnerctl ...` is exactly the thing
that fails on the hosts these messages are about.

`--no-relocate` keeps a deliberately personal copy where it is.

Under `sudo`, a home copy is the invoking user's, and so is everything
`upgrade` does to it: retiring it as `.retired`, or, with `--no-relocate`,
replacing it in place and keeping `.prev` beside it — each call runs as that
user, never as root, and `upgrade --rollback` renames `.prev` back the same
way. A directory others can write is refused before anything is written. The
rule is the one [`install`](#install) states.

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
slots beyond `N` but never deregisters them from GitHub — that is irreversible,
so it is a separate, explicitly targeted command:
[`deprovision`](#removing-runners-deprovision).

With `--save` it also writes the config itself — one `profile_<name>()` block
in `/etc/runnerctl/config`, the previous version alongside it as
`config.bak`. Nothing else in the file is touched.

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
