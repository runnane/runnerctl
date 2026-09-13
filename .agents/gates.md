# Gates

`make gates` = `lint` + `example-drift` + `version-drift` + `smoke` + `sim` +
`migrate-test` + `install-test`. All seven run without systemd runner units,
root or network, so they are green on any dev box and in CI.

**No test may escalate.** `migrate-test` and `install-test` put a fake `sudo`
first on `PATH` that exits 97, so a code path that reaches for `run_priv` under
a caller-owned temp prefix fails the test instead of leaving a root-owned file
behind (which happened once, and needed a real `sudo rm` to clean up). Keep
that tripwire in any new test that exercises a writing command.

## lint — shellcheck

Needs `shellcheck` on PATH (`pacman -S shellcheck`, `apt install shellcheck`,
or the static tarball from github.com/koalaman/shellcheck/releases). Point the
`SHELLCHECK` make variable at a non-PATH binary:
`make lint SHELLCHECK=/path/to/shellcheck`.

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
- The `status --json` case (GHR-16) asserts the parsed JSON through
  `python3` (`expect_json`): where python3 is absent the case keeps its
  exit-code, shape and read-only assertions, prints a `skip` notice for the
  rest and still passes — it is not an xfail and never counts as a failure.
  ubuntu-latest has python3, so CI runs the full case.

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
  `runnerctl` file to it after asserting `runnerctl version` prints the tag;
- `bootstrap-sha` in the config is the commit carrying 0.3.1, the last
  hand-stamped version, so the first release PR only lists what came after
  it. It is inert once a `vX.Y.Z` tag from release-please exists.

Two things the automation cannot do for you:

- With the default `GITHUB_TOKEN`, GitHub suppresses workflow runs on the PRs
  it creates, so the release PR shows no checks and the bumped script is
  gated only by the `push` run on `main` after the merge (where a red `gates`
  also blocks the tag: `release` needs `gates`). A `RELEASE_PLEASE_TOKEN`
  repository secret (PAT, contents + pull-requests write) lifts that.
- The repository setting *Settings → Actions → General → Workflow permissions
  → Allow GitHub Actions to create and approve pull requests* must be on, or
  the action fails with `GitHub Actions is not permitted to create or approve
  pull requests`.

`runnerctl upgrade` defaults to the latest tagged GitHub release, so hosts
only ever pick up released behaviour under its correct version stamp.
`--ref vX.Y.Z` pins a specific release; `--ref <branch>` (e.g. `main`) falls
back to fetching that ref's raw file for a host that wants to track main
ahead of a release, accepting that its version number then lags its bytes
between a feature merge and the release PR merge.
