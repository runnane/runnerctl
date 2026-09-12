#!/usr/bin/env bash
# `runnerctl migrate` against the legacy fixture, without systemd or root.
# tests/migrate.config points discovery and SYSTEMD_DIR at tests/fixtures/.
# Run from the repo root: bash tests/migrate-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "migrate-test: FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
legacy=tests/fixtures/runnerctl-legacy
cfg=tests/migrate.config

# 1. Dry run: generated config matches the expected file (line 1 carries the
#    date), the live differences are reported, the foreign drop-in is flagged,
#    and every fixture unit verifies.
./runnerctl --config "$cfg" migrate --from "$legacy" --dry-run >"$tmp/out" 2>&1 \
  || fail "dry run exited $? — $(cat "$tmp/out")"
sed -n '/^# runnerctl config/,/^(dry run/p' "$tmp/out" | sed '1d;$d' >"$tmp/generated"
diff -u tests/expected/migrate.config "$tmp/generated" \
  || fail "generated config differs from tests/expected/migrate.config"
grep -q "profile 'ci' MAX: script says '26G', live drop-in says '24G' — taking the live value" "$tmp/out" \
  || fail "live MemoryMax difference not reported"
grep -q "profile 'ci' HIGH: script says '22G', live drop-in says '20G'" "$tmp/out" \
  || fail "live MemoryHigh difference not reported"
grep -q "WARNING: 20-other.conf also sets" "$tmp/out" || fail "foreign drop-in not flagged"
grep -q "^verified: 3 unit(s) render identically" "$tmp/out" || fail "render check did not verify 3 units"
grep -q "nothing written" "$tmp/out" || fail "dry run did not say it wrote nothing"

# 2. Real write: file lands 0644, the new script reads it, and the migrated
#    values (not the built-ins) come back out of `profiles`.
./runnerctl --config "$cfg" migrate --from "$legacy" --output "$tmp/config" >"$tmp/out2" 2>&1 \
  || fail "write run exited $? — $(cat "$tmp/out2")"
[ "$(stat -c %a "$tmp/config")" = 644 ] || fail "config mode is $(stat -c %a "$tmp/config"), want 644"
./runnerctl --config "$tmp/config" profiles >"$tmp/profiles" 2>&1
grep -qE "^ci\*[[:space:]]+config[[:space:]]+24G[[:space:]]+20G[[:space:]]+10[[:space:]]" "$tmp/profiles" \
  || fail "profiles does not show migrated ci (24G/20G): $(cat "$tmp/profiles")"
grep -qE "^deploy[[:space:]]+config[[:space:]]+-[[:space:]]+-[[:space:]]+15[[:space:]]+/etc/example-prod/deploy.env" "$tmp/profiles" \
  || fail "profiles does not show migrated deploy: $(cat "$tmp/profiles")"
grep -q "^DROPIN_NAME='10-example-runner.conf'" "$tmp/config" || fail "DROPIN_NAME not carried over"

# 3. Never overwrite: a second run writes <out>.migrated and shows a diff.
./runnerctl --config "$cfg" migrate --from "$legacy" --output "$tmp/config" >"$tmp/out3" 2>&1 \
  || fail "second write run exited $?"
[ -f "$tmp/config.migrated" ] || fail "second run did not write config.migrated"
grep -q "already exists — not overwriting" "$tmp/out3" || fail "second run did not say it refused to overwrite"

# 4. Refusals: the new script, a non-script, a missing file.
./runnerctl migrate --from runnerctl --dry-run >"$tmp/out4" 2>&1 && fail "migrating the new script should fail"
grep -q "not a pre-config runnerctl" "$tmp/out4" || fail "wrong message for new script: $(cat "$tmp/out4")"
./runnerctl migrate --from README.md --dry-run >"$tmp/out5" 2>&1 && fail "migrating README.md should fail"
grep -q "does not look like a runnerctl script" "$tmp/out5" || fail "README.md was not refused before sourcing: $(cat "$tmp/out5")"
./runnerctl migrate --from "$tmp/none" --dry-run >/dev/null 2>&1 && fail "missing --from should fail"

# 5. The render check is load-bearing: a live drop-in the config cannot
#    reproduce (two units, same profile, different values) fails non-zero.
cp -r tests/fixtures/systemd "$tmp/systemd"
sed -i 's/^RestartSec=10$/RestartSec=11/' "$tmp/systemd/actions.runner.example.slot-2.service.d/10-example-runner.conf"
sed "s|^SYSTEMD_DIR=.*|SYSTEMD_DIR=\"$tmp/systemd\"|" "$cfg" >"$tmp/alt.config"
./runnerctl --config "$tmp/alt.config" migrate --from "$legacy" --dry-run >"$tmp/out6" 2>&1 \
  && fail "conflicting live drop-ins should fail the render check"
grep -q "1 unit(s) differ" "$tmp/out6" || fail "render check did not report the differing unit: $(cat "$tmp/out6")"

echo "migrate-test ok"
