# Gates

`make gates` = `lint` + `example-drift` + `version-drift` + `smoke` +
`migrate-test` + `install-test`. All six run without systemd runner units, root
or network, so they are green on any dev box and in CI.

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

## version-drift

`RUNNERCTL_VERSION` in the script must equal `"."` in
`.release-please-manifest.json`. release-please writes both in the release PR
— the script through the `# x-release-please-version` annotation on that line,
the manifest directly — so a mismatch means the annotation was moved or
removed and the tag would carry the wrong stamp. Fix by restoring the
annotation, never by editing either version by hand.

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

`runnerctl upgrade` fetches `main`, so between a feature merge and the release
PR merge hosts pick up the new behaviour under the old version number; pin
`--ref vX.Y.Z` when that matters.
