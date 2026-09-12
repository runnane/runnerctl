# Gates

`make gates` = `lint` + `example-drift` + `smoke` + `sim` + `migrate-test` +
`install-test`. All six run without systemd runner units, root or network,
so they are green on any dev box and in CI.

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
count it without tripping the read-only/leak assertions) and `job_info`;
`systemctl`, `journalctl` and `sudo` are shadowed too as a safety net, and a
case whose log shows one of them was reached directly fails. Cases assert on stdout, stderr, the exit code, the
ordered list of privileged calls and the content `tee`d to each path. Plain
bash, no framework — CI and a fresh worktree have nothing but shellcheck.

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
- `status` calls `nproc` and `free` for real; only the runner rows are asserted.

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
`curl`'s `file://` support. `--ref` is not covered (it needs a
raw.githubusercontent.com URL); verify it by hand.

## release

`release: none` — bump `RUNNERCTL_VERSION` in the script by hand in the same PR
as the change, and tag `vX.Y.Z` on main afterwards so `runnerctl upgrade --ref
vX.Y.Z` can pin it. `runnerctl upgrade` refuses to install a remote whose
version is lower than the installed one unless `--ref` is given.
