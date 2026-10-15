# Changelog

## [0.25.0](https://github.com/runnane/runnerctl/compare/v0.24.0...v0.25.0) (2026-10-15)


### Features

* fleet watch H shows the cursor's host's recent runnerctl records, or the whole fleet's on a second press (GHR-118) ([#146](https://github.com/runnane/runnerctl/issues/146)) ([2ae71d0](https://github.com/runnane/runnerctl/commit/2ae71d0d7d0715386e1b4cf273e3bd5d98028c06))


### Bug Fixes

* fleet watch hands each host its previous CPU sample back, so a tick no longer waits CPU_SAMPLE_MS on every host (GHR-115) ([#144](https://github.com/runnane/runnerctl/issues/144)) ([2182b30](https://github.com/runnane/runnerctl/commit/2182b30417588bc30014bc836c58eda6170370d2))

## [0.24.0](https://github.com/runnane/runnerctl/compare/v0.23.0...v0.24.0) (2026-10-15)


### Features

* fleet status and fleet health take a repeatable --host, and the timed-out wording names the host (GHR-93) ([#142](https://github.com/runnane/runnerctl/issues/142)) ([8d5bb03](https://github.com/runnane/runnerctl/commit/8d5bb03bb2919589f1661b8a9d8331f144fb1d1f))
* status --with-json prints the table and the JSON from one collection, and fleet status/watch ask for it so the summary costs no second call (GHR-90) ([#140](https://github.com/runnane/runnerctl/issues/140)) ([b02337e](https://github.com/runnane/runnerctl/commit/b02337ee7c57177679d72b03d756ff33e2ccf8ea))

## [0.23.0](https://github.com/runnane/runnerctl/compare/v0.22.0...v0.23.0) (2026-10-15)


### Features

* a host's drain, stop, restart, apply and scale run to the end when their caller goes, and fleet ssh drops a vanished host in about a minute (GHR-91) ([#126](https://github.com/runnane/runnerctl/issues/126)) ([b3b61e7](https://github.com/runnane/runnerctl/commit/b3b61e71d82dbe400fcb89807c4526ce1cfa0757))
* fleet watch has a : prompt that runs any fleet command on the cursor's host, the marked rows' hosts or with % every watched host (GHR-86) ([#138](https://github.com/runnane/runnerctl/issues/138)) ([852ba67](https://github.com/runnane/runnerctl/commit/852ba67344f4d984152fe742c39b7cd4db975df7))
* fleet watch marks rows with space or * (every row the view shows), and an action key then acts on the marked set after one confirm listing every target (GHR-129) ([#125](https://github.com/runnane/runnerctl/issues/125)) ([dc84176](https://github.com/runnane/runnerctl/commit/dc84176d21187c3f330e822409e944fd639b277f))
* fleet watch's legend names ? keys, in a line of its own that fits 80 columns (GHR-98) ([#133](https://github.com/runnane/runnerctl/issues/133)) ([2daec29](https://github.com/runnane/runnerctl/commit/2daec29a68c2b985cc2531c3049dd3bea67655d3))
* fleet watch's U upgrades the cursor's host after an upgrade --check, the confirm names FROM -&gt; TO, and the version is read back before it says upgraded (GHR-128) ([#123](https://github.com/runnane/runnerctl/issues/123)) ([1ba2851](https://github.com/runnane/runnerctl/commit/1ba2851f8fd7b54a740862d9a1d9bd97cf5f5da2))
* watch has a ? key list naming Enter and O, and its legend points to it (GHR-105) ([#135](https://github.com/runnane/runnerctl/issues/135)) ([f5800fa](https://github.com/runnane/runnerctl/commit/f5800faddabb04b6f437049642c9775bf0a27fc1))


### Bug Fixes

* a command ended by SIGHUP or SIGPIPE while its record is armed records interrupted and still dies by the signal, except where caller_guard runs it to the end (GHR-131) ([#132](https://github.com/runnane/runnerctl/issues/132)) ([47e6308](https://github.com/runnane/runnerctl/commit/47e630825572bcfbe67cfb6802724b87cc8b68ab))
* a config or env directory created under sudo gets an explicit mode, so root's umask cannot leave it 0700 (GHR-140) ([#134](https://github.com/runnane/runnerctl/issues/134)) ([7a760b9](https://github.com/runnane/runnerctl/commit/7a760b9aefb7d9906cf17844340e6afefb844cde))
* a journal with no job line yet reads as no jobs, not as no journal access (GHR-65) ([#129](https://github.com/runnane/runnerctl/issues/129)) ([972127d](https://github.com/runnane/runnerctl/commit/972127ddd6e573313172e89cb5bfe712d1ead89f))
* apply and scale --save write the config through write_as, so no run of root calls acts on names a user can swap (GHR-135) ([#128](https://github.com/runnane/runnerctl/issues/128)) ([7b50d13](https://github.com/runnane/runnerctl/commit/7b50d13f1a8e2525995a291f7a379fc34ee3f3a7))
* apply writes a slot's drop-in directory 755 and its file 644, so root's umask cannot hide the profile from an unprivileged status (GHR-142) ([#137](https://github.com/runnane/runnerctl/issues/137)) ([2bbd53b](https://github.com/runnane/runnerctl/commit/2bbd53bdd560d0a620e035fed308b1b107e8ba6d))
* cgroup walks read cgroup.procs in one go, so a process exiting mid-walk can no longer hide a live pid from reap, kill or the GHR-100 case (GHR-120) ([#136](https://github.com/runnane/runnerctl/issues/136)) ([0eb563f](https://github.com/runnane/runnerctl/commit/0eb563f0740939123be1aa31fb971bb2e340a970))
* enable and disable take several targets, resolving all before acting on any (GHR-134) ([#127](https://github.com/runnane/runnerctl/issues/127)) ([35ea0d3](https://github.com/runnane/runnerctl/commit/35ea0d322172956ba20448990ee9b8e250bd89be))
* fleet upgrade counts a host that only said Update available as still behind, not upgraded, and exits non-zero (GHR-97) ([#131](https://github.com/runnane/runnerctl/issues/131)) ([582d31c](https://github.com/runnane/runnerctl/commit/582d31cdbed3a679a1b5a79cc329003d62dd95a0))
* the exit-trap wrapper parses trap exactly, so -p, --, - and '' forms keep the audit record (GHR-123) ([#130](https://github.com/runnane/runnerctl/issues/130)) ([3b71084](https://github.com/runnane/runnerctl/commit/3b7108447274563b84779c57fe64264034214de0))

## [0.22.0](https://github.com/runnane/runnerctl/compare/v0.21.0...v0.22.0) (2026-10-14)


### Features

* fleet mutating fan-outs show each host's lines as they are printed, host-prefixed and relayed safe, and the budget walk shows its slots' lines instead of discarding them (GHR-92) ([#113](https://github.com/runnane/runnerctl/issues/113)) ([1e4cb30](https://github.com/runnane/runnerctl/commit/1e4cb302d5a447feed062128222558283767519f))
* fleet watch runs a confirmed action in the background over the held connection, with a progress line, Esc to detach and a notice when it ends (GHR-125) ([#118](https://github.com/runnane/runnerctl/issues/118)) ([8fe5014](https://github.com/runnane/runnerctl/commit/8fe5014256af139485a91ca26ee05fbe7c079a07))
* fleet watch shows how long a slow host took to answer on its host line, yellow near the budget (GHR-95) ([#116](https://github.com/runnane/runnerctl/issues/116)) ([19be3ca](https://github.com/runnane/runnerctl/commit/19be3caaca5bb085aeb10355ba5aa74342de0f56))
* fleet watch's R and S confirm line takes w to run restart or stop with --when-idle in the background (GHR-126) ([#119](https://github.com/runnane/runnerctl/issues/119)) ([1f1c3d1](https://github.com/runnane/runnerctl/commit/1f1c3d166be1df23f7b4ca755da091640f0059d7))
* status --json reports the host's SUDO_CONTRACT, and under FLEET_SUDO=1 fleet status and fleet watch name every host that does not say narrow, with ! keeping it (GHR-113) ([#117](https://github.com/runnane/runnerctl/issues/117)) ([c9627a0](https://github.com/runnane/runnerctl/commit/c9627a0afe7d54b6e2563365678e6f2ecf0eecdd))
* watch remembers a job's run facts (repository, workflow, run id, url ...) while the same job runs, so they stop vanishing between steps (GHR-102) ([#120](https://github.com/runnane/runnerctl/issues/120)) ([f7225fd](https://github.com/runnane/runnerctl/commit/f7225fd37e2b73153a7fed82a302f5cdf0336dd3))


### Bug Fixes

* a command interrupted by SIGINT or SIGTERM while its record is armed records interrupted (SIGINT|SIGTERM) and still dies by the signal (GHR-119) ([#115](https://github.com/runnane/runnerctl/issues/115)) ([49c633e](https://github.com/runnane/runnerctl/commit/49c633e87638121707ab2b08f74196b39fb01948))
* fleet watch ! keeps a host whose answered payload carries no runnerctl version, as the summary counts it unknown (GHR-112) ([#112](https://github.com/runnane/runnerctl/issues/112)) ([53c97b3](https://github.com/runnane/runnerctl/commit/53c97b307d438e694b9a18bc496209f6ee85d355))

## [0.21.0](https://github.com/runnane/runnerctl/compare/v0.20.0...v0.21.0) (2026-10-14)


### Features

* Enter opens a slot detail pane in watch and fleet watch — identity, state, the job's run, memory with a bar, leaks and the host block, with h for the host alone (GHR-76) ([#92](https://github.com/runnane/runnerctl/issues/92)) ([1455739](https://github.com/runnane/runnerctl/commit/1455739a498c0c87bde0670a3ca325aad8c044a5))
* every host-changing command leaves one journal record, fleet mutations a central log line with --origin from the central node, and history / fleet history read them back (GHR-88) ([#106](https://github.com/runnane/runnerctl/issues/106)) ([9aa407b](https://github.com/runnane/runnerctl/commit/9aa407b048665413188d3c939914ae3e54fe5871))
* fleet host lines carry each host's runnerctl version, and skew is measured against the central node (GHR-77) ([#102](https://github.com/runnane/runnerctl/issues/102)) ([46b3fe9](https://github.com/runnane/runnerctl/commit/46b3fe9c27aa3683cabc804f962b7a3d2bf9fc7c))
* fleet upgrade --push sends this node's own runnerctl over ssh, each host checks its sha256, installs it as a file and is read back by checksum, and --push --check reports same / differs / absent / newer (GHR-83) ([#110](https://github.com/runnane/runnerctl/issues/110)) ([369e01a](https://github.com/runnane/runnerctl/commit/369e01aa27dc712d149c69774f11fa928051f299))
* FLEET_SUDO=1 runs mutating fan-outs as `sudo -n runnerctl <verb>` so one sudoers line naming runnerctl is enough, and a host that opts in with SUDO_CONTRACT=narrow refuses under sudo a caller-chosen config, a writable script and each flag that would widen the grant back to root (GHR-89) ([#101](https://github.com/runnane/runnerctl/issues/101)) ([7a0d0c7](https://github.com/runnane/runnerctl/commit/7a0d0c7f0f0610efb8773ed7d273f1215b254623))
* status shows the host's load against its cores and a CPU column of cores in use per slot, with an informational CPU note on STALLED jobs; --json carries host.load, cpu_usage_usec and cpu_pressure (GHR-79) ([#103](https://github.com/runnane/runnerctl/issues/103)) ([f4e02fa](https://github.com/runnane/runnerctl/commit/f4e02fabba5f17c270430873b8b5c50e876870c8))
* upgrade verifies a release download against its published runnerctl.sha256, keeps the script it replaces as .prev, and upgrade --rollback / fleet upgrade --rollback put it back (GHR-84) ([#100](https://github.com/runnane/runnerctl/issues/100)) ([a82ff4c](https://github.com/runnane/runnerctl/commit/a82ff4c9b924ed163342dab84c597e3afcdf5b86))


### Bug Fixes

* a number a host writes reaches arithmetic only through one guard — a leading zero or an over-long digit string is unknown, not an octal error that ends fleet watch (GHR-104) ([#96](https://github.com/runnane/runnerctl/issues/96)) ([e1b6127](https://github.com/runnane/runnerctl/commit/e1b612716f8e37dd511201f8891b689d845eb6fb))
* compose-reap takes ids and times from docker's own fields and labels as JSON, so no label chooses what --apply removes, and a record that does not parse skips its project (GHR-109) ([#99](https://github.com/runnane/runnerctl/issues/99)) ([fc83a2c](https://github.com/runnane/runnerctl/commit/fc83a2c889015abf0e607d20a3e9ea895d5f5386))
* fleet relays only a host's SGR colours — every other escape sequence and control byte a remote sends is removed whole before it is printed (GHR-101) ([#95](https://github.com/runnane/runnerctl/issues/95)) ([acecfdc](https://github.com/runnane/runnerctl/commit/acecfdcc78640fbaf76d875f59f440afd4c8a025))
* health, --if-stalled, reap, kill and their watch confirm lines draw a job's and a process's text with every escape sequence removed whole, and a comm with a comma keeps its pid (GHR-100) ([#97](https://github.com/runnane/runnerctl/issues/97)) ([4bfad76](https://github.com/runnane/runnerctl/commit/4bfad76fd03bd2b01ad15a39e7cbedd11c118692))
* install and upgrade replace a symlinked .retired/.legacy/.prev destination instead of moving into it, and install_file stages with cp --remove-destination so a planted staging symlink is not written through (GHR-111) ([#105](https://github.com/runnane/runnerctl/issues/105)) ([0ae581c](https://github.com/runnane/runnerctl/commit/0ae581c19138d3b9147d707a794fbe9a66205541))
* provision and deprovision write and remove the runner's systemd unit themselves instead of running the runner's own svc.sh as root from a directory the runner user owns (GHR-110) ([#104](https://github.com/runnane/runnerctl/issues/104)) ([d4a91e0](https://github.com/runnane/runnerctl/commit/d4a91e04a73d7ce7b6c7c8bbc2c31f50a914af5b))
* provision refuses a runner root, or a parent of it, that root does not own or others can write, and deprovision removes a slot under one as its runner user (GHR-121) ([#108](https://github.com/runnane/runnerctl/issues/108)) ([a0d22b0](https://github.com/runnane/runnerctl/commit/a0d22b0050b039d2267a782be966c479deee0404))
* provision unpacks and chowns each slot only inside a root-only staging directory it just created and renames it into place, so --replace never writes through a runner-owned tree (GHR-116) ([#107](https://github.com/runnane/runnerctl/issues/107)) ([cebaa97](https://github.com/runnane/runnerctl/commit/cebaa97755259300d660e44f9744d7fb06c44896))
* the slot pane and fleet watch's job cell draw a job's text with every escape sequence removed whole, as the table does (GHR-108) ([#98](https://github.com/runnane/runnerctl/issues/98)) ([6bcb9ca](https://github.com/runnane/runnerctl/commit/6bcb9ca2474916d7b37f79cded77726eaf9c4766))

## [0.20.0](https://github.com/runnane/runnerctl/compare/v0.19.0...v0.20.0) (2026-10-13)


### Features

* fleet watch view keys — ! problems only, b/i busy/idle, / text filter, s sort, c collapse, ? keys, and --problems/--sort to start in a view (GHR-75) ([#86](https://github.com/runnane/runnerctl/issues/86)) ([9981043](https://github.com/runnane/runnerctl/commit/9981043180b5f9a06e70fe095ad5b5ea7d9ad8e5))
* status --json names a job's run (workflow, ids, ref, sha, actor, url), WORKING-ON shows workflow / job [@ref](https://github.com/ref) where there is room, and O prints the run URL in both watches (GHR-78) ([#91](https://github.com/runnane/runnerctl/issues/91)) ([832b15c](https://github.com/runnane/runnerctl/commit/832b15c13730d7d0c6f454e95b772389aaffa203))

## [0.19.0](https://github.com/runnane/runnerctl/compare/v0.18.0...v0.19.0) (2026-10-13)


### Features

* fleet status/watch print a fleet summary line — hosts answering, slots by state, capacity left (GHR-72) ([#79](https://github.com/runnane/runnerctl/issues/79)) ([f3f9f1c](https://github.com/runnane/runnerctl/commit/f3f9f1cd8907a2979ab1dc5af075331296bcabe3))
* fleet upgrade takes --host, a --canary, --serial and --stop-on-failure, and reads each host's version back before calling it upgraded (GHR-82) ([#84](https://github.com/runnane/runnerctl/issues/84)) ([d0b5eca](https://github.com/runnane/runnerctl/commit/d0b5ecabcf87817b76a1cebce592a0c7e38a0ca4))
* fleet watch fetches each host in the background — a slow host holds up neither the frame nor the keys, and one that stops answering keeps its rows with their age (GHR-74) ([#83](https://github.com/runnane/runnerctl/issues/83)) ([7ea1134](https://github.com/runnane/runnerctl/commit/7ea11346dfe537d4dcf5a994fdfe61ea1010d0d3))
* watch and fleet watch fit the frame to the terminal's height — a window that follows the cursor, PgUp/PgDn and g/G, redraw on resize (GHR-73) ([#82](https://github.com/runnane/runnerctl/issues/82)) ([80c6434](https://github.com/runnane/runnerctl/commit/80c6434d11f514d38c1c8faa3d4d52031532334f))


### Bug Fixes

* fleet mutating commands get their own time budget, and a timeout says the host may still be running (GHR-81) ([#81](https://github.com/runnane/runnerctl/issues/81)) ([13961e1](https://github.com/runnane/runnerctl/commit/13961e127038dde53a82a3d4ef6a5aa3ebdfc8cf))

## [0.18.0](https://github.com/runnane/runnerctl/compare/v0.17.0...v0.18.0) (2026-10-13)


### Features

* Disk: watches only the filesystems holding docker and the runners' work folders, labelled, every partition coloured (GHR-67) ([#76](https://github.com/runnane/runnerctl/issues/76)) ([949db69](https://github.com/runnane/runnerctl/commit/949db69133085baeafb5db064519df53c1b52511))

## [0.17.0](https://github.com/runnane/runnerctl/compare/v0.16.0...v0.17.0) (2026-10-13)


### Features

* fleet status/watch show each host's Disk: / OOM / disk-full line above its slots (GHR-66) ([#74](https://github.com/runnane/runnerctl/issues/74)) ([9299d7a](https://github.com/runnane/runnerctl/commit/9299d7a9e389d14e3bfa2b0c9d98803606b58364))

## [0.16.0](https://github.com/runnane/runnerctl/compare/v0.15.0...v0.16.0) (2026-10-12)


### Features

* status/health show fixed-disk usage and recent host OOM-kill / disk-full journal events (GHR-64) ([#72](https://github.com/runnane/runnerctl/issues/72)) ([e6f84ca](https://github.com/runnane/runnerctl/commit/e6f84ca5f366d2c904355c02633570ed7e07d858))

## [0.15.0](https://github.com/runnane/runnerctl/compare/v0.14.0...v0.15.0) (2026-10-05)


### Features

* compose-reap --standalone — reap unlabelled containers a dead job left running, and the images they pinned ([#71](https://github.com/runnane/runnerctl/issues/71)) ([3e33bd0](https://github.com/runnane/runnerctl/commit/3e33bd09915dc2ff247ea77a1a87e1616fd4183a))
* compose-reap — remove Docker Compose stacks whose CI job is gone, hourly from a root timer ([#69](https://github.com/runnane/runnerctl/issues/69)) ([9667838](https://github.com/runnane/runnerctl/commit/96678389bf6f58d787762d2bdef1511a471034f1))

## [0.14.0](https://github.com/runnane/runnerctl/compare/v0.13.0...v0.14.0) (2026-09-24)


### Features

* deprovision deregisters a runner from GitHub and removes its unit (GHR-46) ([#64](https://github.com/runnane/runnerctl/issues/64)) ([e2a84d6](https://github.com/runnane/runnerctl/commit/e2a84d68ea931673dd58d55b9503a4fd7d338e38))
* fleet watch action keys against the selected (host, slot) (GHR-55) ([#67](https://github.com/runnane/runnerctl/issues/67)) ([fe1191b](https://github.com/runnane/runnerctl/commit/fe1191b795836320a91d7a349f2e6777f0d8d7b4))
* status --narrow, and fleet watch narrows a too-wide table (GHR-56) ([#66](https://github.com/runnane/runnerctl/issues/66)) ([d101a50](https://github.com/runnane/runnerctl/commit/d101a50254b88ecd44a62981a8a3c1c60f44ce99))


### Bug Fixes

* fleet status forwards --stall-after to the remote (GHR-57) ([#63](https://github.com/runnane/runnerctl/issues/63)) ([9eaf986](https://github.com/runnane/runnerctl/commit/9eaf9863aa6c031b19e78c3ed02925f7711529eb))
* the fleet budget walk warns when hosts did not answer (GHR-59) ([#68](https://github.com/runnane/runnerctl/issues/68)) ([f83c348](https://github.com/runnane/runnerctl/commit/f83c3481413f08109daca2f6b00c4ff15ab32f71))

## [0.13.0](https://github.com/runnane/runnerctl/compare/v0.12.0...v0.13.0) (2026-09-17)


### Features

* apply/scale --save writes the applied profile back to the config (GHR-58) ([#61](https://github.com/runnane/runnerctl/issues/61)) ([8e49d41](https://github.com/runnane/runnerctl/commit/8e49d41b36dbda1cec83ab0a0c5e55ed2040eae4))

## [0.12.0](https://github.com/runnane/runnerctl/compare/v0.11.1...v0.12.0) (2026-09-14)


### Features

* fleet watch keeps one ssh connection per host open and polls (GHR-54) ([#59](https://github.com/runnane/runnerctl/issues/59)) ([fa29e8b](https://github.com/runnane/runnerctl/commit/fa29e8bd44947677b74369dbac04c9242db4d3b2))

## [0.11.1](https://github.com/runnane/runnerctl/compare/v0.11.0...v0.11.1) (2026-09-14)


### Bug Fixes

* name an absolute path in every sudo remedy (GHR-53) ([#57](https://github.com/runnane/runnerctl/issues/57)) ([135f13c](https://github.com/runnane/runnerctl/commit/135f13c9dbbc600d952de1b1bec42600b003936f))

## [0.11.0](https://github.com/runnane/runnerctl/compare/v0.10.3...v0.11.0) (2026-09-14)


### Features

* upgrade heals where runnerctl is, not only which version it is (GHR-52) ([#55](https://github.com/runnane/runnerctl/issues/55)) ([92724f6](https://github.com/runnane/runnerctl/commit/92724f66030e2844d8d5976b97452cf8b3813d65))

## [0.10.3](https://github.com/runnane/runnerctl/compare/v0.10.2...v0.10.3) (2026-09-14)


### Bug Fixes

* name the remedy when a fleet host cannot run runnerctl (GHR-50) ([#53](https://github.com/runnane/runnerctl/issues/53)) ([a621c38](https://github.com/runnane/runnerctl/commit/a621c38dcb0d424b27f01dac85e42c406fdb1f3c))

## [0.10.2](https://github.com/runnane/runnerctl/compare/v0.10.1...v0.10.2) (2026-09-14)


### Bug Fixes

* `provision` exits 1 with no output on a host with no runners (GHR-48) ([#51](https://github.com/runnane/runnerctl/issues/51)) ([d90a533](https://github.com/runnane/runnerctl/commit/d90a533a673fa13636bf74937347dae0b1d0fc49))

## [0.10.1](https://github.com/runnane/runnerctl/compare/v0.10.0...v0.10.1) (2026-09-14)


### Bug Fixes

* install the script a+rx, not at whatever the umask leaves (GHR-47) ([#49](https://github.com/runnane/runnerctl/issues/49)) ([6964e28](https://github.com/runnane/runnerctl/commit/6964e285bdf333aa5772e338b9cff418ebe79de7))

## [0.10.0](https://github.com/runnane/runnerctl/compare/v0.9.0...v0.10.0) (2026-09-14)


### Features

* `provision N` installs and registers the runners a host does not have yet (GHR-45) ([#47](https://github.com/runnane/runnerctl/issues/47)) ([4982a11](https://github.com/runnane/runnerctl/commit/4982a116c12d632434209f86215fc9698e72fbdc))

## [0.9.0](https://github.com/runnane/runnerctl/compare/v0.8.1...v0.9.0) (2026-09-14)


### Features

* fleet capacity budgets — a ceiling for rolling restarts, a floor for drains (GHR-44) ([#46](https://github.com/runnane/runnerctl/issues/46)) ([e9f94ad](https://github.com/runnane/runnerctl/commit/e9f94adefb75b0a5f9559bb590aad2766443a936))
* fleet health — one exit code for the whole fleet (GHR-40) ([#43](https://github.com/runnane/runnerctl/issues/43)) ([b67a2a5](https://github.com/runnane/runnerctl/commit/b67a2a59e81e7f84f0605124547557c01ece60c1))
* fleet mutating fan-out — --host, serial hosts, the capacity gate and the sudo contract (GHR-43) ([#45](https://github.com/runnane/runnerctl/issues/45)) ([27fdc11](https://github.com/runnane/runnerctl/commit/27fdc1173967c63df177a6284df79bbf6757d113))
* fleet status — drive several runner hosts from one central node over ssh (GHR-39) ([#42](https://github.com/runnane/runnerctl/issues/42)) ([a289b31](https://github.com/runnane/runnerctl/commit/a289b31e946c21bf2f3942f08dbaed0114cb1d52))
* fleet upgrade — hold every runner host on one version from one place (GHR-41) ([#44](https://github.com/runnane/runnerctl/issues/44)) ([fdd0146](https://github.com/runnane/runnerctl/commit/fdd0146234f1f33d1068327e449e5dc073c2587e))
* status --json carries host.name and no longer dies on a runner-less host (GHR-38) ([#40](https://github.com/runnane/runnerctl/issues/40)) ([e293642](https://github.com/runnane/runnerctl/commit/e29364242160e180ace81e3c0c70289d13cad114))

## [0.8.1](https://github.com/runnane/runnerctl/compare/v0.8.0...v0.8.1) (2026-09-14)


### Bug Fixes

* `kill` SIGKILLs the job, not the runner — `restart` hangs on a stalled step (GHR-36) ([#38](https://github.com/runnane/runnerctl/issues/38)) ([2dbf89d](https://github.com/runnane/runnerctl/commit/2dbf89d418540507afd08b3b766cb7b7c802a179))

## [0.8.0](https://github.com/runnane/runnerctl/compare/v0.7.0...v0.8.0) (2026-09-13)


### Features

* interactive watch — select a slot, kill/restart/stop/start/reap/logs from the screen (GHR-33) ([a9214b5](https://github.com/runnane/runnerctl/commit/a9214b594b795ec7e99f790144b41239f2ae6363))
* interactive watch — select a slot, kill/restart/stop/start/reap/logs from the screen (GHR-33) ([7e543f4](https://github.com/runnane/runnerctl/commit/7e543f41934670b2dc6a51c194f9744c93f12a81))
* UPGRADE_URL defaults to the latest GitHub release asset; --ref vX.Y.Z maps to that release, --ref &lt;branch&gt; to the raw URL (GHR-24) ([c538d64](https://github.com/runnane/runnerctl/commit/c538d64c7609bb7a6212992ce45310666227f905))
* UPGRADE_URL defaults to the latest GitHub release asset; --ref vX.Y.Z maps to that release, --ref &lt;branch&gt; to the raw URL (GHR-24) ([9287d34](https://github.com/runnane/runnerctl/commit/9287d3478b7ad914baa0f4e3f86f884984422b28))


### Bug Fixes

* pin the status header through a stubbable host_line() so the sim's whole-output diff is deterministic (GHR-34) ([041720e](https://github.com/runnane/runnerctl/commit/041720ebf5a6fb432b44cf203b18f18aa24b5f27))
* pin the status header through a stubbable host_line() so the sim's whole-output diff is deterministic (GHR-34) ([864a695](https://github.com/runnane/runnerctl/commit/864a69547ff4a5be8e8da48021d7d4563eac8f27))

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
