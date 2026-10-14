#!/usr/bin/env bash
# `runnerctl upgrade` end-to-end, offline, via a file:// UPGRADE_URL (GHR-52):
# the in-place path that has always existed, and the placement healing added
# on top of it — relocating a home copy no non-interactive ssh can reach,
# retiring a home copy that shadows a system one, refusing to escalate, and
# --no-relocate / --check leaving everything alone.
# No systemd, no root, no network.
# Run from the repo root: bash tests/upgrade-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

fail() { echo "upgrade-test: FAIL: $*" >&2; exit 1; }
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

# Nothing under test may escalate. A fake sudo first on PATH turns any attempt
# into a loud failure rather than a root-owned file — and it doubles as the
# "sudo is not free" fixture, because `sudo -n true` through it exits 97.
mkdir -p "$tmp/nosudo"
printf '#!/bin/sh\necho "TEST TRIED TO SUDO: $*" >&2; exit 97\n' >"$tmp/nosudo/sudo"
chmod +x "$tmp/nosudo/sudo"
export PATH="$tmp/nosudo:/usr/bin:/bin"
export HOME="$tmp/home"; mkdir -p "$HOME"; unset SUDO_USER
[ -z "$(command -v runnerctl || true)" ] || fail "a runnerctl is on the pinned PATH: $(command -v runnerctl)"

ver="$(grep -m1 '^RUNNERCTL_VERSION=' runnerctl | cut -d'"' -f2)"
# The source every upgrade downloads: this very checkout, over file://.
cfg="$tmp/up.config"
printf 'UPGRADE_URL="file://%s/runnerctl"\n' "$PWD" >"$cfg"
chmod 644 "$cfg"

# A runnerctl of an arbitrary version, written wherever asked. Note this is
# NOT byte-identical to the source even when the version matches: the sed drops
# the `# x-release-please-version` comment, so a same-version copy made this
# way still reads as changed bytes — which is correct, and is why the
# current-version cases below use same_at instead.
old_at() { # DEST VERSION
  mkdir -p "$(dirname "$1")"
  sed "s/^RUNNERCTL_VERSION=.*/RUNNERCTL_VERSION=\"$2\"/" runnerctl >"$1"
  chmod 755 "$1"
}
# A verbatim copy of the source: same version AND same bytes, which is what
# "already up to date" actually means.
same_at() { # DEST
  mkdir -p "$(dirname "$1")"
  cp runnerctl "$1"
  chmod 755 "$1"
}
# No test may reach the fake sudo except the ones that mean to.
no_sudo() { # FILE CONTEXT
  ! grep -q "TEST TRIED TO SUDO" "$1" || fail "$2 escalated: $(cat "$1")"
}

# A remedy we tell a HUMAN to run has to actually run (GHR-53). Matching the
# sentence only proves the sentence is there — `sudo runnerctl install` shipped
# green through 252 tests and died with "command not found" on the first real
# host, because sudo resets PATH to secure_path and ~/.local/bin is not on it.
#
# So: assert the named command is ABSOLUTE (the invariant), and then prove it
# by resolving it in a reconstructed sudo environment (the demonstration). A
# bare name fails the second check even when it passes a grep for the text.
SECURE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
remedy_runs() { # NAMED-COMMAND CONTEXT
  case "$1" in
    /*) ;;
    *) fail "$2: the remedy names '$1', which is not an absolute path — sudo would resolve it against secure_path" ;;
  esac
  env -i "PATH=$SECURE_PATH" sh -c "command -v '$1' >/dev/null 2>&1" \
    || fail "$2: the remedy names '$1', which does not resolve under sudo's secure_path"
}

# 1. A copy outside any home upgrades exactly where it stands, and says
#    nothing new. This is the pre-GHR-52 contract, pinned so the placement
#    work cannot quietly change it.
old_at "$tmp/sys1/runnerctl" 0.0.1
"$tmp/sys1/runnerctl" --config "$cfg" upgrade --prefix "$tmp/sys1" >"$tmp/o1" 2>&1 \
  || fail "plain upgrade exited $? — $(cat "$tmp/o1")"
grep -q "^installed: 0.0.1 ($tmp/sys1/runnerctl)$" "$tmp/o1" || fail "1: installed line changed: $(cat "$tmp/o1")"
grep -q "^Upgraded 0.0.1 -> $ver at $tmp/sys1/runnerctl$" "$tmp/o1" || fail "1: not upgraded in place: $(cat "$tmp/o1")"
grep -q "^note:" "$tmp/o1" && fail "1: a copy outside a home got a placement note: $(cat "$tmp/o1")"
grep -qE "^(relocated|retired):" "$tmp/o1" && fail "1: a copy outside a home moved: $(cat "$tmp/o1")"
cmp -s runnerctl "$tmp/sys1/runnerctl" || fail "1: new bytes did not land"
# GHR-84: the checkout carries no runnerctl.sha256 beside it, which for a
# file:// source is that source's 404 — so this installs, and says it did not
# verify. Exactly one verdict line either way.
grep -q "^not verified: no digest is published beside this release (file://$PWD/runnerctl.sha256 was not found)" "$tmp/o1" \
  || fail "1: no not-verified line for a source with no digest: $(cat "$tmp/o1")"
[ "$(grep -cE '^(not )?verified: ' "$tmp/o1")" = 1 ] || fail "1: want exactly one verification verdict: $(cat "$tmp/o1")"
no_sudo "$tmp/o1" "1"

# 1b. GHR-82: `fleet upgrade` reads two things off a host — the version its
#     `Upgraded` sentence says it wrote, and what `version` answers afterwards
#     — and every sim case feeds those two parsers the STUB's canned lines. So
#     here they read the real ones: the output case 1 just captured, and the
#     `version` of the file it wrote. A reworded sentence or a changed
#     `version` line fails this rather than turning every fleet row into a
#     read-back mismatch on the first real fleet.
wrote="$(RUNNERCTL_NO_MAIN=1 bash -c '. "$0" && fleet_upgrade_wrote "$1"' "$PWD/runnerctl" "$tmp/o1")" \
  || fail "1b: fleet_upgrade_wrote exited $?"
[ "$wrote" = "$ver" ] || fail "1b: fleet_upgrade_wrote read '$wrote' off the real upgrade output, want '$ver': $(cat "$tmp/o1")"
"$tmp/sys1/runnerctl" version >"$tmp/v1" 2>&1 || fail "1b: version exited $? — $(cat "$tmp/v1")"
answer="$(RUNNERCTL_NO_MAIN=1 bash -c '. "$0" && fleet_version_answer "$1"' "$PWD/runnerctl" "$tmp/v1")" \
  || fail "1b: fleet_version_answer exited $?"
[ "$answer" = "$ver" ] || fail "1b: fleet_version_answer read '$answer' off the real version output, want '$ver': $(cat "$tmp/v1")"
# ...and a host that did not write has no such version to compare against.
wrote="$(RUNNERCTL_NO_MAIN=1 bash -c '. "$0" && fleet_upgrade_wrote "$1"' "$PWD/runnerctl" "$tmp/v1")" \
  || fail "1b: fleet_upgrade_wrote exited $? on a file with no Upgraded sentence"
[ -z "$wrote" ] || fail "1b: fleet_upgrade_wrote read '$wrote' off output that never said Upgraded"

# 2. THE CASE THIS ISSUE EXISTS FOR. A home copy with nothing installed
#    system-wide relocates to the prefix and is retired behind it.
old_at "$HOME/.local/bin/runnerctl" 0.0.1
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ulb2" >"$tmp/o2" 2>&1 \
  || fail "relocating upgrade exited $? — $(cat "$tmp/o2")"
grep -q "^note: this copy is not on the PATH a non-interactive ssh gets" "$tmp/o2" || fail "2: no unreachability note: $(cat "$tmp/o2")"
grep -q "^relocated: $HOME/.local/bin/runnerctl -> $tmp/ulb2/runnerctl$" "$tmp/o2" || fail "2: relocation not reported: $(cat "$tmp/o2")"
grep -q "^retired: $HOME/.local/bin/runnerctl.retired$" "$tmp/o2" || fail "2: retirement not reported: $(cat "$tmp/o2")"
grep -q "^Upgraded 0.0.1 -> $ver at $tmp/ulb2/runnerctl$" "$tmp/o2" || fail "2: wrong final line: $(cat "$tmp/o2")"
cmp -s runnerctl "$tmp/ulb2/runnerctl" || fail "2: new bytes did not land at the prefix"
# a+rx, absolutely — `-x` is owner-relative and passes at 0700 (GHR-47).
[ "$(stat -c '%a' "$tmp/ulb2/runnerctl")" = 755 ] || fail "2: relocated mode is $(stat -c '%a' "$tmp/ulb2/runnerctl"), want 755"
[ ! -e "$HOME/.local/bin/runnerctl" ] || fail "2: home copy was left in place"
grep -q '^RUNNERCTL_VERSION="0.0.1"' "$HOME/.local/bin/runnerctl.retired" || fail "2: home copy not retired"
no_sudo "$tmp/o2" "2"
rm -f "$HOME/.local/bin/runnerctl.retired"

# 3. Placement is healed even when the VERSION is already current — the case
#    a version-only upgrade can never fix, and the one a fleet stays broken
#    on indefinitely. The final sentence must still be the parseable one.
same_at "$HOME/.local/bin/runnerctl"
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ulb3" >"$tmp/o3" 2>&1 \
  || fail "current-version relocate exited $? — $(cat "$tmp/o3")"
grep -q "^relocated: " "$tmp/o3" || fail "3: current version was not relocated: $(cat "$tmp/o3")"
grep -q "^Already up to date\.$" "$tmp/o3" || fail "3: final line is not the parseable sentence: $(cat "$tmp/o3")"
[ -x "$tmp/ulb3/runnerctl" ] || fail "3: nothing landed at the prefix"
[ ! -e "$HOME/.local/bin/runnerctl" ] || fail "3: home copy was left in place"
no_sudo "$tmp/o3" "3"
rm -f "$HOME/.local/bin/runnerctl.retired"

# 4. Shadow: a system copy exists and the home copy hides it. The home copy is
#    retired and the system one is upgraded — and nothing claims a relocation,
#    because nothing moved.
old_at "$tmp/ulb4/runnerctl" 0.0.1
old_at "$HOME/.local/bin/runnerctl" 0.5.0
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ulb4" >"$tmp/o4" 2>&1 \
  || fail "shadow upgrade exited $? — $(cat "$tmp/o4")"
grep -q "^note: $tmp/ulb4/runnerctl (runnerctl 0.0.1) is shadowed by this copy" "$tmp/o4" || fail "4: no shadow note: $(cat "$tmp/o4")"
# installed: reports what the FLEET runs, which is the system copy, not $self.
grep -q "^installed: 0.0.1 ($tmp/ulb4/runnerctl)$" "$tmp/o4" || fail "4: installed line names the wrong copy: $(cat "$tmp/o4")"
grep -q "^retired: $HOME/.local/bin/runnerctl.retired$" "$tmp/o4" || fail "4: shadow not retired: $(cat "$tmp/o4")"
grep -q "^relocated: " "$tmp/o4" && fail "4: claimed a relocation when nothing moved: $(cat "$tmp/o4")"
grep -q "^Upgraded 0.0.1 -> $ver at $tmp/ulb4/runnerctl$" "$tmp/o4" || fail "4: system copy not upgraded: $(cat "$tmp/o4")"
cmp -s runnerctl "$tmp/ulb4/runnerctl" || fail "4: system copy bytes not replaced"
[ ! -e "$HOME/.local/bin/runnerctl" ] || fail "4: shadow left in place"
no_sudo "$tmp/o4" "4"
rm -f "$HOME/.local/bin/runnerctl.retired"

# 5. Refusing to escalate. The prefix is unwritable and sudo is not free, so
#    the upgrade happens in place and the remedy is NAMED rather than taken.
mkdir -p "$tmp/ro5"; old_at "$HOME/.local/bin/runnerctl" 0.0.1; chmod 555 "$tmp/ro5"
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ro5" >"$tmp/o5" 2>&1 \
  || fail "no-privilege upgrade exited $? — $(cat "$tmp/o5")"
grep -q "To move it: sudo " "$tmp/o5" || fail "5: remedy not named: $(cat "$tmp/o5")"
# Not "is the sentence present" but "does the command work": the whole point of
# GHR-53. This must be the path of the copy being upgraded, absolute.
r5="$(sed -n "s/.*To move it: sudo \\([^ ]*\\) install.*/\\1/p" "$tmp/o5")"
[ -n "$r5" ] || fail "5: could not read a command out of the remedy: $(cat "$tmp/o5")"
[ "$r5" = "$HOME/.local/bin/runnerctl" ] || fail "5: remedy names '$r5', want this copy's own path"
remedy_runs "$r5" "5"
grep -q "^Upgraded 0.0.1 -> $ver at $HOME/.local/bin/runnerctl$" "$tmp/o5" || fail "5: did not upgrade in place: $(cat "$tmp/o5")"
grep -qE "^(relocated|retired):" "$tmp/o5" && fail "5: moved something without privilege: $(cat "$tmp/o5")"
[ ! -e "$tmp/ro5/runnerctl" ] || fail "5: wrote into an unwritable prefix"
no_sudo "$tmp/o5" "5"
chmod 755 "$tmp/ro5"

# 6. A shadow over an OLDER system copy is NOT retired when it cannot be
#    upgraded: retiring it would silently downgrade what the user gets when
#    they type `runnerctl`. Healing must never leave them worse off.
mkdir -p "$tmp/ro6"; old_at "$tmp/ro6/runnerctl" 0.0.1; chmod 555 "$tmp/ro6"
old_at "$HOME/.local/bin/runnerctl" 0.5.0
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ro6" >"$tmp/o6" 2>&1 \
  || fail "older-shadow upgrade exited $? — $(cat "$tmp/o6")"
grep -q "^retired:" "$tmp/o6" && fail "6: retired a shadow over an older system copy: $(cat "$tmp/o6")"
[ -e "$HOME/.local/bin/runnerctl" ] || fail "6: home copy was removed"
grep -q '^RUNNERCTL_VERSION="0.0.1"' "$tmp/ro6/runnerctl" || fail "6: unwritable system copy changed"
no_sudo "$tmp/o6" "6"
chmod 755 "$tmp/ro6"; rm -f "$HOME/.local/bin/runnerctl"

# 7. A shadow over an equal-or-newer system copy IS retired even with no
#    privilege, because that costs none — the file is the user's own.
same_at "$tmp/ro7/runnerctl"; chmod 555 "$tmp/ro7"
old_at "$HOME/.local/bin/runnerctl" 0.0.1
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ro7" >"$tmp/o7" 2>&1 \
  || fail "retire-only upgrade exited $? — $(cat "$tmp/o7")"
grep -q "run 'sudo $tmp/ro7/runnerctl upgrade' to move it on" "$tmp/o7" || fail "7: did not name the remaining step: $(cat "$tmp/o7")"
r7="$(sed -n "s/.*run 'sudo \\([^ ]*\\) upgrade'.*/\\1/p" "$tmp/o7")"
remedy_runs "$r7" "7"
grep -q "^retired: $HOME/.local/bin/runnerctl.retired$" "$tmp/o7" || fail "7: shadow not retired: $(cat "$tmp/o7")"
[ ! -e "$HOME/.local/bin/runnerctl" ] || fail "7: shadow left in place"
grep -q "^Already up to date\.$" "$tmp/o7" || fail "7: $sys already had these bytes, so this is up to date: $(cat "$tmp/o7")"
no_sudo "$tmp/o7" "7"
chmod 755 "$tmp/ro7"; rm -f "$HOME/.local/bin/runnerctl.retired"

# 8. --no-relocate: a deliberately personal copy is upgraded where it stands.
old_at "$HOME/.local/bin/runnerctl" 0.0.1
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ulb8" --no-relocate >"$tmp/o8" 2>&1 \
  || fail "--no-relocate exited $? — $(cat "$tmp/o8")"
grep -q "^Upgraded 0.0.1 -> $ver at $HOME/.local/bin/runnerctl$" "$tmp/o8" || fail "8: did not upgrade in place: $(cat "$tmp/o8")"
grep -qE "^(note|relocated|retired):" "$tmp/o8" && fail "8: --no-relocate still moved or nagged: $(cat "$tmp/o8")"
[ ! -e "$tmp/ulb8" ] || fail "8: --no-relocate created the prefix"
no_sudo "$tmp/o8" "8"

# 9. --check is read-only: it says what it WOULD do and does none of it, and
#    still ends in the sentence the fan-out parses.
old_at "$HOME/.local/bin/runnerctl" 0.0.1
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ulb9" --check >"$tmp/o9" 2>&1 \
  || fail "--check exited $? — $(cat "$tmp/o9")"
grep -q "^would relocate: $HOME/.local/bin/runnerctl -> $tmp/ulb9/runnerctl$" "$tmp/o9" || fail "9: no would-relocate line: $(cat "$tmp/o9")"
grep -q "^would retire: $HOME/.local/bin/runnerctl.retired$" "$tmp/o9" || fail "9: no would-retire line: $(cat "$tmp/o9")"
grep -q "^Update available\. Run: runnerctl upgrade$" "$tmp/o9" || fail "9: final line is not the parseable sentence: $(cat "$tmp/o9")"
[ ! -e "$tmp/ulb9" ] || fail "9: --check created the prefix"
[ ! -e "$HOME/.local/bin/runnerctl.retired" ] || fail "9: --check retired the home copy"
grep -q '^RUNNERCTL_VERSION="0.0.1"' "$HOME/.local/bin/runnerctl" || fail "9: --check rewrote the home copy"
no_sudo "$tmp/o9" "9"
rm -f "$HOME/.local/bin/runnerctl"

# 10. A home of /home/jon must not swallow /home/jonathan — the prefix test is
#     on path SEGMENTS, and a substring match would relocate a stranger's file.
mkdir -p "$tmp/homes/jon" "$tmp/homes/jonathan/bin"
old_at "$tmp/homes/jonathan/bin/runnerctl" 0.0.1
HOME="$tmp/homes/jon" "$tmp/homes/jonathan/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ulb10" >"$tmp/o10" 2>&1 \
  || fail "sibling-home upgrade exited $? — $(cat "$tmp/o10")"
grep -qE "^(note|relocated|retired):" "$tmp/o10" && fail "10: treated a sibling home as the invoking one: $(cat "$tmp/o10")"
grep -q "^Upgraded 0.0.1 -> $ver at $tmp/homes/jonathan/bin/runnerctl$" "$tmp/o10" || fail "10: not upgraded in place: $(cat "$tmp/o10")"
no_sudo "$tmp/o10" "10"

# 11. Retire-only where $sys is EQUAL to this copy but both are behind the
#     source. The shadow goes, $sys cannot be written without a password, and
#     nothing was upgraded — so the final sentence must report the work still
#     outstanding. Claiming "Upgraded" here would be a false report, and the
#     fan-out would summarise the host as healed when it is not.
old_at "$tmp/ro11/runnerctl" 0.5.0; chmod 555 "$tmp/ro11"
old_at "$HOME/.local/bin/runnerctl" 0.5.0
"$HOME/.local/bin/runnerctl" --config "$cfg" upgrade --prefix "$tmp/ro11" >"$tmp/o11" 2>&1 \
  || fail "outstanding-work upgrade exited $? — $(cat "$tmp/o11")"
grep -q "^retired: $HOME/.local/bin/runnerctl.retired$" "$tmp/o11" || fail "11: shadow not retired: $(cat "$tmp/o11")"
grep -q "^Update available\. Run: sudo $tmp/ro11/runnerctl upgrade$" "$tmp/o11" || fail "11: did not report the remaining work: $(cat "$tmp/o11")"
# The final sentence is a remedy too, and it broke the same way.
rf11="$(sed -n "s/^Update available\. Run: sudo \\([^ ]*\\) upgrade$/\\1/p" "$tmp/o11")"
remedy_runs "$rf11" "11 final line"
grep -q "^Upgraded " "$tmp/o11" && fail "11: claimed an upgrade it never performed: $(cat "$tmp/o11")"
r11="$(sed -n "s/.*run 'sudo \\([^ ]*\\) upgrade'.*/\\1/p" "$tmp/o11")"
[ "$r11" = "$tmp/ro11/runnerctl" ] || fail "11: remedy names '$r11', want the system copy's own path"
remedy_runs "$r11" "11"
grep -q '^RUNNERCTL_VERSION="0.5.0"' "$tmp/ro11/runnerctl" || fail "11: unwritable system copy changed"
no_sudo "$tmp/o11" "11"
chmod 755 "$tmp/ro11"

# --- GHR-84: the digest, .prev and --rollback ----------------------------------
sum() { sha256sum "$1" | awk '{print $1}'; }

# The release job writes the digest with exactly this command, in the checkout
# of the tag, and uploads it beside the script. The cases below generate their
# digests with the same command, so what they verify against is the bytes the
# job would publish — and this pins that the job still runs it, and still
# uploads the result.
digest_cmd='sha256sum runnerctl > runnerctl.sha256'
[ "$(grep -cxF "          $digest_cmd" .github/workflows/ci.yml)" = 1 ] \
  || fail "12: the release job no longer writes the digest with '$digest_cmd'"
grep -qE '^ +gh release upload "\$TAG" runnerctl runnerctl\.sha256 --clobber$' .github/workflows/ci.yml \
  || fail "12: the release job no longer uploads runnerctl.sha256 beside runnerctl"
publish() { # DIR — the script and its digest, as the release job publishes them
  mkdir -p "$1"; cp runnerctl "$1/runnerctl"
  (cd "$1" && eval "$digest_cmd")
}

# 12. Negative control: a matching digest installs, says so — and the script
#     it replaced is kept as .prev with the target's owner and mode. 775, not
#     the 755 a default would give: a .prev that took a default mode, or a
#     `chmod +x` (the umask's), is told apart from one that took the target's.
publish "$tmp/src12"
printf 'UPGRADE_URL="file://%s/runnerctl"\n' "$tmp/src12" >"$tmp/c12"; chmod 644 "$tmp/c12"
old_at "$tmp/sys12/runnerctl" 0.0.1; chmod 775 "$tmp/sys12/runnerctl"
cp "$tmp/sys12/runnerctl" "$tmp/old12"
"$tmp/sys12/runnerctl" --config "$tmp/c12" upgrade >"$tmp/o12" 2>&1 || fail "12: verified upgrade exited $? — $(cat "$tmp/o12")"
grep -qF "verified: sha256 $(sum runnerctl | cut -c1-12)… matches file://$tmp/src12/runnerctl.sha256" "$tmp/o12" \
  || fail "12: no verified line: $(cat "$tmp/o12")"
grep -q "^not verified" "$tmp/o12" && fail "12: a verified download also said not verified: $(cat "$tmp/o12")"
grep -q "^Upgraded 0.0.1 -> $ver at $tmp/sys12/runnerctl$" "$tmp/o12" || fail "12: not upgraded: $(cat "$tmp/o12")"
grep -q "^kept: 0.0.1 as $tmp/sys12/runnerctl.prev " "$tmp/o12" || fail "12: no kept line: $(cat "$tmp/o12")"
cmp -s runnerctl "$tmp/sys12/runnerctl" || fail "12: new bytes did not land"
cmp -s "$tmp/old12" "$tmp/sys12/runnerctl.prev" || fail "12: .prev does not hold the old bytes"
[ "$(stat -c '%a' "$tmp/sys12/runnerctl.prev")" = 775 ] || fail "12: .prev mode is $(stat -c '%a' "$tmp/sys12/runnerctl.prev"), want the target's 775"
[ "$(stat -c '%u:%g' "$tmp/sys12/runnerctl.prev")" = "$(stat -c '%u:%g' "$tmp/old12")" ] || fail "12: .prev owner differs from the target's"
[ "$(find "$tmp/sys12" -mindepth 1 | wc -l)" = 2 ] || fail "12: something besides the script and .prev was left: $(ls -A "$tmp/sys12")"
no_sudo "$tmp/o12" "12"
# --check names the rollback copy, without changing anything
"$tmp/sys12/runnerctl" --config "$tmp/c12" upgrade --check >"$tmp/o12c" 2>&1 || fail "12: --check exited $? — $(cat "$tmp/o12c")"
grep -q "^rollback: 0.0.1 ($tmp/sys12/runnerctl.prev)$" "$tmp/o12c" || fail "12: --check did not name the rollback copy: $(cat "$tmp/o12c")"
grep -q "^Already up to date\.$" "$tmp/o12c" || fail "12: --check's last sentence changed: $(cat "$tmp/o12c")"
[ "$(tail -1 "$tmp/o12c")" = "Already up to date." ] || fail "12: the rollback line displaced the verdict as the last line"

# 13. THE ACCEPTANCE CASE: a digest that does not match is refused, and the
#     installed file is unchanged — checked by checksum, before and after.
#     Every claim is collected before failing, so a mutation shows which of
#     them it broke rather than only the first.
publish "$tmp/src13"
printf '%s  runnerctl\n' "$(printf 'not the release' | sha256sum | awk '{print $1}')" >"$tmp/src13/runnerctl.sha256"
printf 'UPGRADE_URL="file://%s/runnerctl"\n' "$tmp/src13" >"$tmp/c13"; chmod 644 "$tmp/c13"
old_at "$tmp/sys13/runnerctl" 0.0.1
before13="$(sum "$tmp/sys13/runnerctl")"
rc13=0; "$tmp/sys13/runnerctl" --config "$tmp/c13" upgrade >"$tmp/o13" 2>&1 || rc13=$?
after13="$(sum "$tmp/sys13/runnerctl")"
bad13=""
{ [ "$rc13" -ne 0 ] && grep -q "does not match its digest — not installing" "$tmp/o13"; } \
  || bad13+=" [refusal: exit $rc13, want non-zero with 'does not match its digest — not installing']"
[ "$after13" = "$before13" ] || bad13+=" [checksum: the installed file changed, $before13 -> $after13]"
[ ! -e "$tmp/sys13/runnerctl.prev" ] || bad13+=" [a .prev was written for an upgrade that was refused]"
[ "$(find "$tmp/sys13" -mindepth 1 | wc -l)" = 1 ] || bad13+=" [files left behind: $(ls -A "$tmp/sys13")]"
[ -z "$bad13" ] || fail "13:$bad13 — $(cat "$tmp/o13")"
no_sudo "$tmp/o13" "13"

# 14. The rollback: .prev goes back, its version is proven by running it, and
#     .prev is consumed — so a second --rollback refuses and changes nothing.
"$tmp/sys12/runnerctl" --config "$tmp/c12" upgrade --rollback >"$tmp/o14" 2>&1 || fail "14: rollback exited $? — $(cat "$tmp/o14")"
grep -q "^Rolled back $ver -> 0.0.1 at $tmp/sys12/runnerctl$" "$tmp/o14" || fail "14: no rollback sentence: $(cat "$tmp/o14")"
[ "$(tail -1 "$tmp/o14")" = "runnerctl 0.0.1" ] || fail "14: the installed copy was not run afterwards: $(cat "$tmp/o14")"
cmp -s "$tmp/old12" "$tmp/sys12/runnerctl" || fail "14: the old bytes are not back"
[ "$(stat -c '%a' "$tmp/sys12/runnerctl")" = 775 ] || fail "14: rolled-back mode is $(stat -c '%a' "$tmp/sys12/runnerctl"), want 775"
[ ! -e "$tmp/sys12/runnerctl.prev" ] || fail "14: .prev was not consumed"
no_sudo "$tmp/o14" "14"
# what `fleet upgrade --rollback` reads off it is the real sentence's version
rolled="$(RUNNERCTL_NO_MAIN=1 bash -c '. "$0" && fleet_upgrade_rolled "$1"' "$PWD/runnerctl" "$tmp/o14")" \
  || fail "14: fleet_upgrade_rolled exited $?"
[ "$rolled" = "0.0.1" ] || fail "14: fleet_upgrade_rolled read '$rolled' off the real rollback output, want 0.0.1"
before14="$(sum "$tmp/sys12/runnerctl")"
rc14=0; "$tmp/sys12/runnerctl" --config "$tmp/c12" upgrade --rollback >"$tmp/o14b" 2>&1 || rc14=$?
[ "$rc14" -ne 0 ] || fail "14: a second --rollback with no .prev succeeded: $(cat "$tmp/o14b")"
grep -q "no rollback copy at $tmp/sys12/runnerctl.prev — nothing to roll back to" "$tmp/o14b" || fail "14: wrong refusal: $(cat "$tmp/o14b")"
[ "$(sum "$tmp/sys12/runnerctl")" = "$before14" ] || fail "14: a refused rollback changed the file"
"$tmp/sys12/runnerctl" --config "$tmp/c12" upgrade --check >"$tmp/o14c" 2>&1 || fail "14: --check exited $?"
grep -q "^rollback: none (no $tmp/sys12/runnerctl.prev)$" "$tmp/o14c" || fail "14: --check after a rollback: $(cat "$tmp/o14c")"
# --rollback refuses the options that are about a download or a placement
for f in --check "--ref v1.2.3" "--prefix $tmp/x" --no-relocate; do
  # shellcheck disable=SC2086  # $f is one or two words on purpose
  if "$tmp/sys12/runnerctl" --config "$tmp/c12" upgrade --rollback $f >"$tmp/o14d" 2>&1; then
    fail "14: --rollback $f was accepted"
  fi
  grep -q -- "--rollback takes no other option" "$tmp/o14d" || fail "14: --rollback $f: $(cat "$tmp/o14d")"
done
no_sudo "$tmp/o14b" "14"

# 15. Every other way the digest can arrive, over https, through a fake curl:
#     a release asset URL is the rule's real input, and file:// cannot answer
#     a 503 or time out. The fake serves the checkout for any URL ending in
#     /runnerctl, answers the digest URL as FAKE_DIGEST says, and logs every
#     URL it is asked for.
mkdir -p "$tmp/fakecurl"
cat >"$tmp/fakecurl/curl" <<'EOF'
#!/bin/bash
out="" url="" w=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) w="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
echo "$url" >>"$FAKE_LOG"
case "$url" in
  */runnerctl) cp "$FAKE_SRC" "$out"; code=200 ;;
  */runnerctl.sha256)
    case "$FAKE_DIGEST" in
      404)     printf 'Not Found' >"$out"; code=404 ;;
      503)     printf 'Service Unavailable' >"$out"; code=503 ;;
      timeout) echo "curl: (28) Operation timed out" >&2; exit 28 ;;
      file:*)  cp "${FAKE_DIGEST#file:}" "$out"; code=200 ;;
      *)       exit 99 ;;
    esac ;;
  *) echo "curl: (6) Could not resolve host" >&2; exit 6 ;;
esac
[ -z "$w" ] || printf '%s' "$code"
exit 0
EOF
chmod +x "$tmp/fakecurl/curl"
rel="https://github.com/example/runnerctl/releases/latest/download/runnerctl"
printf 'UPGRADE_URL="%s"\n' "$rel" >"$tmp/c15"; chmod 644 "$tmp/c15"
good15="$tmp/src12/runnerctl.sha256"
garbage15="$tmp/garbage.sha256"; printf '<html>moved</html>\n' >"$garbage15"
pin_ok="$(sum runnerctl)"
pin_bad="$(printf 'not the release' | sha256sum | awk '{print $1}')"
up15() { # TAG FAKE_DIGEST UPGRADE-ARGS... — sets rc15, $tmp/o15.TAG, $tmp/u15.TAG
  local tag="$1" d="$2"; shift 2
  old_at "$tmp/sys15$tag/runnerctl" 0.0.1
  : >"$tmp/u15.$tag"; rc15=0
  PATH="$tmp/fakecurl:$PATH" FAKE_SRC="$PWD/runnerctl" FAKE_DIGEST="$d" FAKE_LOG="$tmp/u15.$tag" \
    "$tmp/sys15$tag/runnerctl" --config "$tmp/c15" upgrade "$@" >"$tmp/o15.$tag" 2>&1 || rc15=$?
}
# 15a. a release published before the job wrote digests: 404 installs, saying so
up15 a 404
[ "$rc15" = 0 ] || fail "15a: a 404 on the digest did not install: $(cat "$tmp/o15.a")"
grep -q "^not verified: no digest is published beside this release (${rel}.sha256 was not found)" "$tmp/o15.a" || fail "15a: $(cat "$tmp/o15.a")"
grep -q "^Upgraded 0.0.1 -> $ver at " "$tmp/o15.a" || fail "15a: not upgraded: $(cat "$tmp/o15.a")"
grep -qx "${rel}.sha256" "$tmp/u15.a" || fail "15a: the digest URL was not asked for: $(cat "$tmp/u15.a")"
# 15b/c/d. any other failure to read the digest REFUSES, and writes nothing
for t in b:503:"answered HTTP 503" c:timeout:"(curl exit 28)" d:"file:$garbage15":"is not a sha256sum line for runnerctl"; do
  # TAG:DIGEST:WHY — DIGEST may itself hold a colon (file:PATH), WHY never does
  tag="${t%%:*}"; rest="${t#*:}"; d="${rest%:*}"; why="${rest##*:}"
  up15 "$tag" "$d"
  { [ "$rc15" -ne 0 ] && grep -q "$why — refusing to install unverified bytes" "$tmp/o15.$tag"; } \
    || fail "15$tag: a digest that could not be read ($d) was not refused: exit $rc15 — $(cat "$tmp/o15.$tag")"
  grep -q '^RUNNERCTL_VERSION="0.0.1"' "$tmp/sys15$tag/runnerctl" || fail "15$tag: the installed file changed"
  [ ! -e "$tmp/sys15$tag/runnerctl.prev" ] || fail "15$tag: a refused upgrade wrote .prev"
done
# 15e. --ref vX.Y.Z maps to that release's asset, and to ITS digest
up15 e "file:$good15" --ref v1.2.3
[ "$rc15" = 0 ] || fail "15e: $(cat "$tmp/o15.e")"
grep -qF "verified: sha256 ${pin_ok:0:12}… matches https://github.com/example/runnerctl/releases/download/v1.2.3/runnerctl.sha256" "$tmp/o15.e" \
  || fail "15e: --ref's digest URL: $(cat "$tmp/o15.e")"
# 15f. a branch --ref is not a release asset: no digest is asked for at all
up15 f 503 --ref main
[ "$rc15" = 0 ] || fail "15f: $(cat "$tmp/o15.f")"
grep -q "^not verified: https://raw.githubusercontent.com/example/runnerctl/main/runnerctl is not a release asset" "$tmp/o15.f" || fail "15f: $(cat "$tmp/o15.f")"
grep -q 'sha256' "$tmp/u15.f" && fail "15f: a digest was requested for a non-release source: $(cat "$tmp/u15.f")"
# 15g. --sha256 pins it: the published digest is not fetched (a 503 there
#      would refuse), a matching pin installs, and a pin that does not match
#      refuses even where the published digest WOULD match
up15 g 503 --sha256 "$pin_ok"
[ "$rc15" = 0 ] || fail "15g: a matching --sha256 did not install: $(cat "$tmp/o15.g")"
grep -qF "verified: sha256 ${pin_ok:0:12}… matches --sha256" "$tmp/o15.g" || fail "15g: $(cat "$tmp/o15.g")"
grep -q 'sha256' "$tmp/u15.g" && fail "15g: the published digest was fetched despite --sha256: $(cat "$tmp/u15.g")"
up15 h "file:$good15" --sha256 "$pin_bad"
{ [ "$rc15" -ne 0 ] && grep -q "does not match its digest — not installing (sha256 $pin_ok, want $pin_bad from --sha256)" "$tmp/o15.h"; } \
  || fail "15h: a --sha256 that does not match was not refused: exit $rc15 — $(cat "$tmp/o15.h")"
grep -q '^RUNNERCTL_VERSION="0.0.1"' "$tmp/sys15h/runnerctl" || fail "15h: the installed file changed"
up15 i 404 --sha256 NOT-HEX
[ "$rc15" -ne 0 ] || fail "15i: an invalid --sha256 was accepted"
grep -q -- "--sha256 'NOT-HEX' is invalid — want 64 lowercase hex characters" "$tmp/o15.i" || fail "15i: $(cat "$tmp/o15.i")"
[ ! -s "$tmp/u15.i" ] || fail "15i: something was downloaded before the --sha256 was validated: $(cat "$tmp/u15.i")"
for t in a b c d e f g h i; do no_sudo "$tmp/o15.$t" "15$t"; done

echo "upgrade-test ok"
