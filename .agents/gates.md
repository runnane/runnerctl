# Gates

`make gates` = `lint` + `example-drift` + `smoke`. All three run without
systemd runner units or root, so they are green on any dev box and in CI.

## lint — shellcheck

Needs `shellcheck` on PATH (`pacman -S shellcheck`, `apt install shellcheck`,
or the static tarball from github.com/koalaman/shellcheck/releases). Point the
`SHELLCHECK` make variable at a non-PATH binary:
`make lint SHELLCHECK=/path/to/shellcheck`.

Runs at `-S style`, so info-level findings fail the gate. Fix the code rather
than adding `disable` directives; the one existing directive (SC1090, sourcing
a path only known at runtime) is inherent to the config-file design.

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

## release

`release: none` — bump `RUNNERCTL_VERSION` in the script by hand in the same PR
as the change, and tag `vX.Y.Z` on main afterwards so `runnerctl upgrade --ref
vX.Y.Z` can pin it. `runnerctl upgrade` refuses to install a remote whose
version is lower than the installed one unless `--ref` is given.
