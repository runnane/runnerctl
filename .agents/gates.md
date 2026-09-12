# Gates

`make gates` = `lint` + `example-drift` + `smoke` + `migrate-test` +
`install-test`. All five run without systemd runner units, root or network,
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

Runs at `-S style`, so info-level findings fail the gate. Fix the code rather
than adding `disable` directives; the existing directives are all SC1090
(sourcing a path only known at runtime) and inherent to the design — the config
file, the legacy script `migrate` reads, and the config `migrate` just wrote.

## example-drift

`config.example` is a checked-in copy of `runnerctl config-example` so it is
browsable on GitHub. The script is the source of truth; after editing
`cmd_config_example`, regenerate with `./runnerctl config-example > config.example`.

## smoke

Only exercises commands that need neither systemd nor sudo (`version`, `help`,
`profiles`, config loading, unknown-command exit code). Anything touching
units (`apply`, `scale`, `env-init`) is verified by hand on a runner host — or
locally by stubbing `run_priv`, `systemctl`, `discover` and `apply_to` in a
throwaway config file, since the config is sourced after those functions are
defined and so can shadow them.

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
