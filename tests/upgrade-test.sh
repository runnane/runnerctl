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
no_sudo "$tmp/o1" "1"

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

echo "upgrade-test ok"
