#!/usr/bin/env bash
# `runnerctl install` end-to-end under a temp prefix: fresh, idempotent,
# legacy-with-migrate, dry-run, --no-migrate, migrate-failure abort,
# no-downgrade, refusal to overwrite a foreign file, and the piped form
# (offline, via a file:// UPGRADE_URL). No systemd, no root, no network.
# Run from the repo root: bash tests/install-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "install-test: FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Nothing under test may escalate: a fake sudo first on PATH turns any attempt
# into a loud failure instead of a root-owned file in the temp dir.
mkdir -p "$tmp/nosudo"; printf '#!/bin/sh\necho "TEST TRIED TO SUDO: $*" >&2; exit 97\n' >"$tmp/nosudo/sudo"; chmod +x "$tmp/nosudo/sudo"
export PATH="$tmp/nosudo:$PATH"
ver="$(grep -m1 '^RUNNERCTL_VERSION=' runnerctl | cut -d'"' -f2)"
legacy=tests/fixtures/runnerctl-legacy

# 1. Fresh install into a prefix that does not exist yet.
RUNNERCTL_CONFIG="$tmp/etc/config" ./runnerctl install --prefix "$tmp/bin" >"$tmp/out1" 2>&1 \
  || fail "fresh install exited $? — $(cat "$tmp/out1")"
[ -x "$tmp/bin/runnerctl" ] || fail "fresh install did not produce an executable"
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

echo "install-test ok"
