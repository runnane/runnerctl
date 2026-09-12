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

runnerctl status
runnerctl apply  [--profile NAME] [--max 26G] [--high 22G] \
                 [--restart-sec N] [--env-file PATH] [--restart]
runnerctl scale N [--profile NAME] [--max 26G] [--high 22G]
runnerctl env-init [--profile NAME] [--env-file PATH]
runnerctl start|stop|restart [<unit|slot-index|name>]
runnerctl enable|disable <unit|slot-index|name>
runnerctl logs [<unit|slot-index|name>]
runnerctl remove-limits
runnerctl profiles
runnerctl config-example
runnerctl migrate [--from PATH] [--output PATH] [--dry-run]
runnerctl install [--prefix DIR] [--ref <branch|tag>] [--no-migrate] [--dry-run]
runnerctl upgrade [--check] [--ref <branch|tag>]
runnerctl version
```

`status` shows each slot's state, memory cap/usage, restart policy, env file
and — when run as the runner's user or root — the repository and job it is
currently working on:

```
IDX RUNNER                 ACTIVE          ENABLED   MAX    HIGH   USED   RESTART  ENVFILE WORKING-ON
0   org.host-1             active/running  enabled   26.0G  22.0G  3.1G   always   —       my-app:test
1   org.host-2             active/running  enabled   26.0G  22.0G  128M   always   —       idle
2   org.host-3             inactive/dead   disabled  —      —      —      always   —       —
```

Slots are addressed by unit name, by the `IDX` column, or by the `RUNNER`
column's short name — an unambiguous prefix or substring of it also works
(e.g. `slot-1` for `example.slot-1`).

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
