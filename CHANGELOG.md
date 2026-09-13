# Changelog

## [0.7.0](https://github.com/runnane/runnerctl/compare/v0.6.0...v0.7.0) (2026-09-13)


### Features

* count leaked processes on an idle slot, and `reap` to kill them (GHR-29) ([8d6dad0](https://github.com/runnane/runnerctl/commit/8d6dad036de1df5b7ed6e5b94d25f4ef01b8c599))
* count leaked processes on an idle slot, and reap to kill them (GHR-29) ([b387118](https://github.com/runnane/runnerctl/commit/b387118e630f091993c6ad79c281f98d01316a92))
* OOMPolicy=continue and MemorySwapMax=0 in every drop-in, ci MemoryHigh 25G (GHR-28) ([783737c](https://github.com/runnane/runnerctl/commit/783737c8c054aae621e38a450d3ff11bb8eb6a49))
* OOMPolicy=continue and MemorySwapMax=0 in every drop-in, ci MemoryHigh 25G (GHR-28) ([530432a](https://github.com/runnane/runnerctl/commit/530432ae73743c0087c5059003e9490b6fb53b60))
* PRESS column and memory.events per slot, in --json and health (GHR-31) ([5a57b48](https://github.com/runnane/runnerctl/commit/5a57b48b63e5ce98eec19749c597b65eb283d903))
* PRESS column and memory.events per slot, in --json and health (GHR-31) ([a656c87](https://github.com/runnane/runnerctl/commit/a656c87492b5edd1a733119d3cb1f54c96cdebeb))
* STALLED after 1 h, restart/stop --if-stalled, health --restart-stalled (GHR-30) ([f7c5417](https://github.com/runnane/runnerctl/commit/f7c5417163ae0a43dd3be3c97b38349e236ee9fb))
* STALLED after 1 h, restart/stop --if-stalled, health --restart-stalled (GHR-30) ([1543a0a](https://github.com/runnane/runnerctl/commit/1543a0a06fc39fbf7baabafccb681ffc3ad8d762))
* status header and --json carry the runnerctl version (GHR-32) ([a13b316](https://github.com/runnane/runnerctl/commit/a13b3163692efe8373a78222ca9831642a23d4b9))
* status header and --json carry the runnerctl version (GHR-32) ([487663f](https://github.com/runnane/runnerctl/commit/487663fc4cd55f0e926fc1d5eae66ccf8dcccc3c))

## [0.6.0](https://github.com/runnane/runnerctl/compare/v0.5.0...v0.6.0) (2026-09-13)


### Features

* colour status/watch by meaning and flag stalled jobs (GHR-27) ([aeebbda](https://github.com/runnane/runnerctl/commit/aeebbda3bbb9025a3447aedd4c5981e22566657a))
* colour status/watch by meaning and flag stalled jobs (GHR-27) ([a6b540c](https://github.com/runnane/runnerctl/commit/a6b540cbe0749cd476e25eb4b46b55a43084f4a0))

## [0.5.0](https://github.com/runnane/runnerctl/compare/v0.4.4...v0.5.0) (2026-09-13)


### Features

* --when-idle / drain waits for each slot to go idle before restart, stop, apply --restart and scale (GHR-11) ([b286751](https://github.com/runnane/runnerctl/commit/b286751efe60ce3875a25515dbde8db90acb1671))
* --when-idle and drain for graceful restart/stop (GHR-11) ([b30a0e1](https://github.com/runnane/runnerctl/commit/b30a0e121b889b131b18297f93cd798e3dadffb9))
* accept the short runner name as a target (GHR-9) ([f192ec5](https://github.com/runnane/runnerctl/commit/f192ec5c7fb686e81513dd95a8e9276afc9988be))
* apply/remove-limits take targets; status shows the PROFILE each slot carries (GHR-15) ([9de3e03](https://github.com/runnane/runnerctl/commit/9de3e037b9304f0b990a2cd87461686c75e95eb8))
* apply/remove-limits targets and a PROFILE status column (GHR-15) ([0052ef1](https://github.com/runnane/runnerctl/commit/0052ef15c5e37e75df270949e39368cda7b2d744))
* health command for cron/uptime probes (GHR-14) ([6cb1bec](https://github.com/runnane/runnerctl/commit/6cb1bec9cdf4355d1f11c50a9cae227569a1ac05))
* health exits non-zero when an enabled slot is down or crash-looping (GHR-14) ([807f4d1](https://github.com/runnane/runnerctl/commit/807f4d1a2d299fb80d33b2c64dd1bbaf6c2bb3e2))
* logs -f/-n/--since/-g and all-slots default (GHR-12) ([ae1aa4d](https://github.com/runnane/runnerctl/commit/ae1aa4d34bf057dd22adad85a96738350d3a9f15))
* release-please bumps the version, writes the changelog and cuts releases (GHR-22) ([716e473](https://github.com/runnane/runnerctl/commit/716e47335a0fb4cc62e6d25a7730d568ccd8471a))
* release-please bumps the version, writes the changelog and cuts releases (GHR-22) ([31bc702](https://github.com/runnane/runnerctl/commit/31bc702d0ed6b91dd8c85167c5b35b5b55fa16ca))
* status --json emits the slot facts from the same collector as the table (GHR-16) ([90bad6a](https://github.com/runnane/runnerctl/commit/90bad6a4f695ffe2a9f9b97630f8167e8deb6047))
* status --json for monitoring and inventory tooling (GHR-16) ([04a15c5](https://github.com/runnane/runnerctl/commit/04a15c53b7c80dc7d0f228c858957ecfdb6ec94d))
* status shows idle time and jobs since start (GHR-2) ([be6940b](https://github.com/runnane/runnerctl/commit/be6940bef6a1d158278936b48e4a2138d61739ee))
* status shows idle time and jobs since start in WORKING-ON (GHR-2) ([0ea101d](https://github.com/runnane/runnerctl/commit/0ea101de5f9b95162087af4decac03500cac5617))
* status shows restart count, last exit reason and peak memory (GHR-8) ([24b3846](https://github.com/runnane/runnerctl/commit/24b38464e550f584e7699c7a7d822bb6ebc59ea8))
* status shows restarts, last exit reason and peak memory (GHR-8) ([6732e75](https://github.com/runnane/runnerctl/commit/6732e75a541383f46670da5bea0b2d84a455002a))
* status SINCE column and job runtime (GHR-1) ([85539fb](https://github.com/runnane/runnerctl/commit/85539fb0d2aeaca381bee06c3ceb1d9def4c96e8))
* watch mode — status redrawn in place (GHR-3) ([7770663](https://github.com/runnane/runnerctl/commit/7770663d0c906f59cda80788db9d4e0b9a505353))
* watch mode redraws status in place with a journal cache (GHR-3) ([0bb6f58](https://github.com/runnane/runnerctl/commit/0bb6f5807aad07de8231a7c6c333b4989cf2a1b2))
* WORKING-ON from the journal, (no access) distinct from stopped (GHR-10) ([01910bf](https://github.com/runnane/runnerctl/commit/01910bfcb92f91a62fa5fa13691d04314d01b409))
* WORKING-ON reads the running job from the journal; (no access) is distinct from stopped (GHR-10) ([7822ac0](https://github.com/runnane/runnerctl/commit/7822ac0e527788d0c61edefb08638127daae124f))


### Bug Fixes

* install finds a runnerctl in the sudo user's ~/.local/bin or ~/bin (GHR-20) ([6c7a634](https://github.com/runnane/runnerctl/commit/6c7a634a1c9c3e02fe2a0948c97294b3eb15c375))
* install finds a runnerctl in the sudo user's ~/.local/bin or ~/bin (GHR-20) ([d04de7a](https://github.com/runnane/runnerctl/commit/d04de7a82bccb62fdd71c7e1ea590f28c004d164))
* journal fetch filters with -g instead of a -n 400 window (GHR-26) ([0e25207](https://github.com/runnane/runnerctl/commit/0e252073d6b538574037be26f0afe8dc22f7c922))
* journal_job_lines filters with journalctl -g instead of a -n 400 tail window (GHR-26) ([662e0a4](https://github.com/runnane/runnerctl/commit/662e0a4c45b20338adf39eb597554c0937ec02db))
* option parsing — missing values, --flag=value, value validation (GHR-6) ([aa7f6a6](https://github.com/runnane/runnerctl/commit/aa7f6a64d908f1b7818ad5a89955579a8e20610f))
* out-of-range slot index aborts instead of running an empty unit (GHR-19) ([b672db9](https://github.com/runnane/runnerctl/commit/b672db9702e79b50bd96f29293f1203731a89cdd))
* scale reloads before starting slots and surfaces failures (GHR-5) ([b913431](https://github.com/runnane/runnerctl/commit/b913431f3a64d3558054c8fe128f12036abaf2bb))
* status pads cells by characters so — cells stay aligned (GHR-21) ([ec5ff28](https://github.com/runnane/runnerctl/commit/ec5ff28e64c7049bb8bf5d0dd30f847552c8d7c3))


### Performance

* one systemctl show call per unit in status (GHR-4) ([95727b1](https://github.com/runnane/runnerctl/commit/95727b12d3b71c07ba1e0b709880ed546667e8e2))
