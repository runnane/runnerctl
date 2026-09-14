#!/usr/bin/env bash
# `runnerctl install` end-to-end under a temp prefix: fresh, idempotent,
# legacy-with-migrate, dry-run, --no-migrate, migrate-failure abort,
# no-downgrade, refusal to overwrite a foreign file, the piped form (offline,
# via a file:// UPGRADE_URL), and a copy in the invoking user's ~/.local/bin or
# ~/bin that PATH does not reach (getent stubbed, HOME a temp dir), and the
# absolute mode of everything it creates, including under a restrictive umask.
# No systemd, no root, no network.
# Run from the repo root: bash tests/install-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "install-test: FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Nothing under test may escalate: a fake sudo first on PATH turns any attempt
# into a loud failure instead of a root-owned file in the temp dir.
mkdir -p "$tmp/nosudo"; printf '#!/bin/sh\necho "TEST TRIED TO SUDO: $*" >&2; exit 97\n' >"$tmp/nosudo/sudo"; chmod +x "$tmp/nosudo/sudo"
# PATH is pinned to what sudo's secure_path would leave, so `command -v
# runnerctl` is empty whatever this box has installed, and HOME is a temp dir
# so the home-directory lookup (cases 10-13) can never touch a real
# ~/.local/bin/runnerctl. Both are asserted, not assumed.
export PATH="$tmp/nosudo:/usr/bin:/bin"
export HOME="$tmp/home"; mkdir -p "$HOME"; unset SUDO_USER
[ -z "$(command -v runnerctl || true)" ] || fail "a runnerctl is on the pinned PATH: $(command -v runnerctl)"
ver="$(grep -m1 '^RUNNERCTL_VERSION=' runnerctl | cut -d'"' -f2)"
legacy=tests/fixtures/runnerctl-legacy

# 1. Fresh install into a prefix that does not exist yet.
RUNNERCTL_CONFIG="$tmp/etc/config" ./runnerctl install --prefix "$tmp/bin" >"$tmp/out1" 2>&1 \
  || fail "fresh install exited $? — $(cat "$tmp/out1")"
[ -x "$tmp/bin/runnerctl" ] || fail "fresh install did not produce an executable"
# The absolute mode, not `-x`: `-x` is owner-relative and passes at 0700,
# which is the mode GHR-47 shipped. A #! script needs a+r as well as a+x.
[ "$(stat -c '%a' "$tmp/bin/runnerctl")" = 755 ] || fail "fresh install mode is $(stat -c '%a' "$tmp/bin/runnerctl"), want 755"
cmp -s runnerctl "$tmp/bin/runnerctl" || fail "installed file differs from the source"
grep -q "fresh install" "$tmp/out1" || fail "fresh path not reported"
grep -q "^Next:" "$tmp/out1" || fail "next steps not printed on fresh install"
[ "$(tail -1 "$tmp/out1")" = "runnerctl $ver" ] || fail "last line is not the installed file's version: $(tail -1 "$tmp/out1")"
[ -d "$tmp/etc" ] || fail "config directory was not created"

# 2. Idempotent: the same command again changes nothing.
RUNNERCTL_CONFIG="$tmp/etc/config" ./runnerctl install --prefix "$tmp/bin" >"$tmp/out2" 2>&1 \
  || fail "second install exited $?"
grep -q "Already up to date" "$tmp/out2" || fail "rerun did not report up to date: $(cat "$tmp/out2")"

# 3. Legacy install: migrate runs first, then the file is replaced, then the
#    installed file reports its version — in that order.
mkdir -p "$tmp/legacy"; cp "$legacy" "$tmp/legacy/runnerctl"; chmod 755 "$tmp/legacy/runnerctl"
RUNNERCTL_CONFIG="$tmp/legacy/etc/config" ./runnerctl install --prefix "$tmp/legacy" >"$tmp/out3" 2>&1 \
  || fail "legacy install exited $? — $(cat "$tmp/out3")"
grep -q "pre-config runnerctl" "$tmp/out3" || fail "legacy install not detected"
m="$(grep -n -- '--- migrate done ---' "$tmp/out3" | cut -d: -f1)"
i="$(grep -n '^Installed runnerctl' "$tmp/out3" | cut -d: -f1)"
[ -n "$m" ] && [ -n "$i" ] && [ "$m" -lt "$i" ] || fail "migrate did not run before the install: $(cat "$tmp/out3")"
[ "$(tail -1 "$tmp/out3")" = "runnerctl $ver" ] || fail "installed legacy target does not report $ver"
grep -q "^DROPIN_NAME='10-example-runner.conf'" "$tmp/legacy/etc/config" || fail "migrated config lacks DROPIN_NAME"
grep -q "^profile_deploy()" "$tmp/legacy/etc/config" || fail "migrated config lacks profile_deploy"
grep -q '^RUNNERCTL_VERSION=' "$tmp/legacy/runnerctl" || fail "legacy file was not replaced"

# 4. Legacy dry run: nothing changes, no config written.
mkdir -p "$tmp/dry"; cp "$legacy" "$tmp/dry/runnerctl"
RUNNERCTL_CONFIG="$tmp/dry/etc/config" ./runnerctl install --prefix "$tmp/dry" --dry-run >"$tmp/out4" 2>&1 \
  || fail "dry run exited $?"
cmp -s "$legacy" "$tmp/dry/runnerctl" || fail "dry run modified the target"
[ ! -e "$tmp/dry/etc/config" ] || fail "dry run wrote a config"
grep -q "would run: runnerctl migrate" "$tmp/out4" || fail "dry run did not describe the migrate step"

# 5. --no-migrate on a legacy install keeps a copy for a later migrate.
mkdir -p "$tmp/nm"; cp "$legacy" "$tmp/nm/runnerctl"
RUNNERCTL_CONFIG="$tmp/nm/etc/config" ./runnerctl install --prefix "$tmp/nm" --no-migrate >"$tmp/out5" 2>&1 \
  || fail "--no-migrate install exited $?"
cmp -s "$legacy" "$tmp/nm/runnerctl.legacy" || fail "--no-migrate did not keep runnerctl.legacy"
grep -q '^RUNNERCTL_VERSION=' "$tmp/nm/runnerctl" || fail "--no-migrate did not replace the target"
[ ! -e "$tmp/nm/etc/config" ] || fail "--no-migrate wrote a config"

# 6. A migrate that fails its render check aborts the install, old file intact.
mkdir -p "$tmp/abort"; cp "$legacy" "$tmp/abort/runnerctl"
cp -r tests/fixtures/systemd "$tmp/abort/systemd"
sed -i 's/^RestartSec=10$/RestartSec=11/' "$tmp/abort/systemd/actions.runner.example.slot-2.service.d/10-example-runner.conf"
sed "s|^SYSTEMD_DIR=.*|SYSTEMD_DIR=\"$tmp/abort/systemd\"|" tests/migrate.config >"$tmp/abort/config"
RUNNERCTL_CONFIG="$tmp/abort/config" ./runnerctl install --prefix "$tmp/abort" >"$tmp/out6" 2>&1 \
  && fail "install should abort when migrate fails"
grep -q "unit(s) differ" "$tmp/out6" || fail "abort reason not the render check: $(cat "$tmp/out6")"
cmp -s "$legacy" "$tmp/abort/runnerctl" || fail "aborted install still replaced the target"

# 7. Never downgrade without --ref.
mkdir -p "$tmp/newer"; sed 's/^RUNNERCTL_VERSION=.*/RUNNERCTL_VERSION="9.9.9"/' runnerctl >"$tmp/newer/runnerctl"
RUNNERCTL_CONFIG="$tmp/newer/config" ./runnerctl install --prefix "$tmp/newer" >"$tmp/out7" 2>&1 \
  || fail "downgrade attempt exited $?"
grep -q "not downgrading" "$tmp/out7" || fail "downgrade was not refused: $(cat "$tmp/out7")"
grep -q '^RUNNERCTL_VERSION="9.9.9"' "$tmp/newer/runnerctl" || fail "downgrade overwrote the newer file"

# 8. Refuse to overwrite something that is not runnerctl.
mkdir -p "$tmp/other"; echo "#!/bin/sh" >"$tmp/other/runnerctl"
RUNNERCTL_CONFIG="$tmp/other/config" ./runnerctl install --prefix "$tmp/other" >"$tmp/out8" 2>&1 \
  && fail "install overwrote a foreign runnerctl"
grep -q "refusing to overwrite" "$tmp/out8" || fail "wrong refusal message: $(cat "$tmp/out8")"

# 9. Piped: only install works, and it downloads its own bytes (file:// here).
cat runnerctl | bash -s -- status >"$tmp/out9" 2>&1 && fail "piped status should be refused"
grep -q "running from a pipe" "$tmp/out9" || fail "piped status: wrong message: $(cat "$tmp/out9")"
printf 'UPGRADE_URL="file://%s/runnerctl"\n' "$PWD" >"$tmp/piped.config"
cat runnerctl | bash -s -- --config "$tmp/piped.config" install --prefix "$tmp/piped" >"$tmp/out10" 2>&1 \
  || fail "piped install exited $? — $(cat "$tmp/out10")"
grep -q "^source: file://" "$tmp/out10" || fail "piped install did not download its source"
[ "$("$tmp/piped/runnerctl" version)" = "runnerctl $ver" ] || fail "piped install did not land $ver"
# The download is staged through a mktemp, mode 0600, so this is the path
# GHR-47 broke: `chmod +x` on it yielded 0711 under umask 022.
[ "$(stat -c '%a' "$tmp/piped/runnerctl")" = 755 ] || fail "piped install mode is $(stat -c '%a' "$tmp/piped/runnerctl"), want 755"

# 10. Under sudo the invoking user's ~/.local/bin is off PATH: a legacy copy
#     there is found via $SUDO_USER (getent stubbed to a temp home), migrated
#     from, and retired as .legacy after the new file lands at the prefix.
mkdir -p "$tmp/getent" "$tmp/home10/.local/bin"
printf '#!/bin/sh\n[ "$1" = passwd ] && [ "$2" = someone ] && echo "someone:x:1234:1234::%s:/bin/sh"\n' "$tmp/home10" >"$tmp/getent/getent"
chmod +x "$tmp/getent/getent"
cp "$legacy" "$tmp/home10/.local/bin/runnerctl"; chmod 755 "$tmp/home10/.local/bin/runnerctl"
SUDO_USER=someone PATH="$tmp/getent:$PATH" RUNNERCTL_CONFIG="$tmp/home10/etc/config" \
  ./runnerctl install --prefix "$tmp/ulb10" >"$tmp/out11" 2>&1 \
  || fail "sudo-shaped legacy install exited $? — $(cat "$tmp/out11")"
grep -q "existing: pre-config runnerctl (no RUNNERCTL_VERSION) at $tmp/home10/.local/bin/runnerctl (in someone's home via \$SUDO_USER" "$tmp/out11" \
  || fail "home copy not reported as found via SUDO_USER: $(cat "$tmp/out11")"
grep -q "^target: $tmp/ulb10/runnerctl" "$tmp/out11" || fail "home copy moved the target"
m="$(grep -n -- '--- migrate done ---' "$tmp/out11" | cut -d: -f1)"
i="$(grep -n '^Installed runnerctl' "$tmp/out11" | cut -d: -f1)"
[ -n "$m" ] && [ -n "$i" ] && [ "$m" -lt "$i" ] || fail "migrate did not run before the install: $(cat "$tmp/out11")"
grep -q "^DROPIN_NAME='10-example-runner.conf'" "$tmp/home10/etc/config" || fail "migrated config lacks DROPIN_NAME"
cmp -s runnerctl "$tmp/ulb10/runnerctl" || fail "new file did not land at the prefix"
[ ! -e "$tmp/home10/.local/bin/runnerctl" ] || fail "home copy was left in place"
cmp -s "$legacy" "$tmp/home10/.local/bin/runnerctl.legacy" || fail "home copy was not retired as .legacy"
grep -q "^Retired $tmp/home10/.local/bin/runnerctl as $tmp/home10/.local/bin/runnerctl.legacy" "$tmp/out11" || fail "retirement not reported: $(cat "$tmp/out11")"
[ "$(tail -1 "$tmp/out11")" = "runnerctl $ver" ] || fail "installed file does not report $ver"

# 11. Same, dry run: the decision is shown, nothing moves, no config written.
mkdir -p "$tmp/home11/.local/bin"; cp "$legacy" "$tmp/home11/.local/bin/runnerctl"
sed -i "s|$tmp/home10|$tmp/home11|" "$tmp/getent/getent"
SUDO_USER=someone PATH="$tmp/getent:$PATH" RUNNERCTL_CONFIG="$tmp/home11/etc/config" \
  ./runnerctl install --prefix "$tmp/ulb11" --dry-run >"$tmp/out12" 2>&1 \
  || fail "sudo-shaped dry run exited $? — $(cat "$tmp/out12")"
grep -q "would run: runnerctl migrate --from $tmp/home11/.local/bin/runnerctl" "$tmp/out12" || fail "dry run did not name the home copy as the migrate source: $(cat "$tmp/out12")"
grep -q "would then retire $tmp/home11/.local/bin/runnerctl as $tmp/home11/.local/bin/runnerctl.legacy" "$tmp/out12" || fail "dry run did not describe the retirement: $(cat "$tmp/out12")"
cmp -s "$legacy" "$tmp/home11/.local/bin/runnerctl" || fail "dry run touched the home copy"
[ ! -e "$tmp/ulb11" ] || fail "dry run created the prefix"
[ ! -e "$tmp/home11/etc/config" ] || fail "dry run wrote a config"

# 12. --no-migrate with a home legacy copy: still retired as .legacy, with the
#     later-migrate hint pointing at that path, and no config written.
mkdir -p "$tmp/home12/.local/bin"; cp "$legacy" "$tmp/home12/.local/bin/runnerctl"
sed -i "s|$tmp/home11|$tmp/home12|" "$tmp/getent/getent"
SUDO_USER=someone PATH="$tmp/getent:$PATH" RUNNERCTL_CONFIG="$tmp/home12/etc/config" \
  ./runnerctl install --prefix "$tmp/ulb12" --no-migrate >"$tmp/out13" 2>&1 \
  || fail "sudo-shaped --no-migrate exited $? — $(cat "$tmp/out13")"
grep -q "runnerctl migrate --from $tmp/home12/.local/bin/runnerctl.legacy" "$tmp/out13" || fail "--no-migrate hint does not point at the retired copy: $(cat "$tmp/out13")"
cmp -s "$legacy" "$tmp/home12/.local/bin/runnerctl.legacy" || fail "--no-migrate did not retire the home copy as .legacy"
[ ! -e "$tmp/home12/.local/bin/runnerctl" ] || fail "--no-migrate left the home copy in place"
grep -q '^RUNNERCTL_VERSION=' "$tmp/ulb12/runnerctl" || fail "--no-migrate did not install at the prefix"
[ ! -e "$tmp/home12/etc/config" ] || fail "--no-migrate wrote a config"

# 13. Not under sudo, versioned copy in ~/bin (the second directory): found
#     via $HOME, its version is checked, it moves to the prefix and is retired
#     as .retired.
mkdir -p "$HOME/bin"; sed 's/^RUNNERCTL_VERSION=.*/RUNNERCTL_VERSION="0.0.1"/' runnerctl >"$HOME/bin/runnerctl"
RUNNERCTL_CONFIG="$tmp/home/etc/config" ./runnerctl install --prefix "$tmp/ulb13" >"$tmp/out14" 2>&1 \
  || fail "home-versioned install exited $? — $(cat "$tmp/out14")"
grep -q "^existing: runnerctl 0.0.1 at $HOME/bin/runnerctl (in \$HOME, not on PATH)" "$tmp/out14" || fail "versioned home copy not reported: $(cat "$tmp/out14")"
grep -q "^move: 0.0.1 at $HOME/bin/runnerctl -> $ver at $tmp/ulb13/runnerctl" "$tmp/out14" || fail "move not reported: $(cat "$tmp/out14")"
cmp -s runnerctl "$tmp/ulb13/runnerctl" || fail "new file did not land at the prefix"
[ ! -e "$HOME/bin/runnerctl" ] || fail "versioned home copy was left in place"
grep -q '^RUNNERCTL_VERSION="0.0.1"' "$HOME/bin/runnerctl.retired" || fail "versioned home copy was not retired as .retired"
# A newer home copy is not downgraded, and stays where it is.
sed 's/^RUNNERCTL_VERSION=.*/RUNNERCTL_VERSION="9.9.9"/' runnerctl >"$HOME/bin/runnerctl"
RUNNERCTL_CONFIG="$tmp/home/etc/config" ./runnerctl install --prefix "$tmp/ulb13b" >"$tmp/out15" 2>&1 \
  || fail "newer-home-copy install exited $?"
grep -q "not downgrading" "$tmp/out15" || fail "newer home copy was not refused: $(cat "$tmp/out15")"
[ -e "$HOME/bin/runnerctl" ] && [ ! -e "$tmp/ulb13b" ] || fail "refused downgrade still moved something"
rm -f "$HOME/bin/runnerctl"

# 14. Under a restrictive umask everything created still comes out a+rx. This
#     is the regression guard for GHR-47: a symbolic `chmod +x` is masked by
#     the umask, and `cp` masks the copied mode too, so at umask 077 the file
#     landed 0700 and a freshly created prefix or config directory 0700 with
#     it — root could run runnerctl and nobody else could.
(
  umask 077
  RUNNERCTL_CONFIG="$tmp/u77/etc/config" ./runnerctl install --prefix "$tmp/u77/bin" >"$tmp/out16" 2>&1
) || fail "umask 077 install exited $? — $(cat "$tmp/out16")"
[ "$(stat -c '%a' "$tmp/u77/bin/runnerctl")" = 755 ] || fail "umask 077 install mode is $(stat -c '%a' "$tmp/u77/bin/runnerctl"), want 755"
[ "$(stat -c '%a' "$tmp/u77/bin")" = 755 ] || fail "umask 077 prefix mode is $(stat -c '%a' "$tmp/u77/bin"), want 755"
[ "$(stat -c '%a' "$tmp/u77/etc")" = 755 ] || fail "umask 077 config dir mode is $(stat -c '%a' "$tmp/u77/etc"), want 755"
# Same under the piped form, whose bytes come from a 0600 mktemp download.
(
  umask 077
  cat runnerctl | bash -s -- --config "$tmp/piped.config" install --prefix "$tmp/u77b" >"$tmp/out17" 2>&1
) || fail "umask 077 piped install exited $? — $(cat "$tmp/out17")"
[ "$(stat -c '%a' "$tmp/u77b/runnerctl")" = 755 ] || fail "umask 077 piped mode is $(stat -c '%a' "$tmp/u77b/runnerctl"), want 755"

# 15. An existing target: too narrow a mode is widened to a+rx so a host
#     already installed at 0700 heals, and anything wider the admin set is
#     kept rather than flattened to 755.
mkdir -p "$tmp/heal"
sed 's/^RUNNERCTL_VERSION=.*/RUNNERCTL_VERSION="0.0.1"/' runnerctl >"$tmp/heal/runnerctl"; chmod 700 "$tmp/heal/runnerctl"
RUNNERCTL_CONFIG="$tmp/heal/etc/config" ./runnerctl install --prefix "$tmp/heal" >"$tmp/out18" 2>&1 \
  || fail "heal install exited $? — $(cat "$tmp/out18")"
grep -q "^upgrade: 0.0.1 -> $ver" "$tmp/out18" || fail "heal install was not an upgrade: $(cat "$tmp/out18")"
[ "$(stat -c '%a' "$tmp/heal/runnerctl")" = 755 ] || fail "0700 target was not widened: $(stat -c '%a' "$tmp/heal/runnerctl")"
mkdir -p "$tmp/keep"
sed 's/^RUNNERCTL_VERSION=.*/RUNNERCTL_VERSION="0.0.1"/' runnerctl >"$tmp/keep/runnerctl"; chmod 775 "$tmp/keep/runnerctl"
RUNNERCTL_CONFIG="$tmp/keep/etc/config" ./runnerctl install --prefix "$tmp/keep" >"$tmp/out19" 2>&1 \
  || fail "mode-preserving install exited $? — $(cat "$tmp/out19")"
[ "$(stat -c '%a' "$tmp/keep/runnerctl")" = 775 ] || fail "775 target was not preserved: $(stat -c '%a' "$tmp/keep/runnerctl")"
# An existing directory keeps the mode the admin gave it.
mkdir -p "$tmp/dirkeep/bin"; chmod 700 "$tmp/dirkeep/bin"
RUNNERCTL_CONFIG="$tmp/dirkeep/etc/config" ./runnerctl install --prefix "$tmp/dirkeep/bin" >"$tmp/out20" 2>&1 \
  || fail "existing-prefix install exited $? — $(cat "$tmp/out20")"
[ "$(stat -c '%a' "$tmp/dirkeep/bin")" = 700 ] || fail "existing prefix mode was changed: $(stat -c '%a' "$tmp/dirkeep/bin")"

echo "install-test ok"
