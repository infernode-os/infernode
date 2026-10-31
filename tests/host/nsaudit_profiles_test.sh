#!/bin/bash
#
# Lightweight profile checks for nsaudit. These fixtures are executable
# assumptions, not frozen shipping snapshots: ordinary tool/path drift can be
# reviewed later, but hard namespace-security invariants fail now.
#
# Profiles are intentionally additive. profile-minimal-headless is the base:
# no GUI/window/payment authority. Desktop GUI, messaging, and payments are
# explicit overlays. A future remote-admin UI profile should be another overlay,
# not ambient authority in the headless/container profile.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

SH="/dis/sh.dis"
profiles=(
  profile-minimal-headless
  profile-desktop-gui
  profile-messaging
  profile-payments
)

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -f "$ROOT/dis/nsaudit.dis" ]] || { echo "SKIP: nsaudit.dis not found"; exit 77; }

run_nsaudit() {
  local profile="$1"
  timeout 30 "$EMU" -r"$ROOT" "$SH" -c \
    "path=(/dis/veltro /dis/cmd /dis .); nsaudit -m /tests/nsaudit-fixtures/$profile" \
    </dev/null 2>&1 || true
}

fail_profile() {
  local profile="$1"
  local why="$2"
  local out="$3"
  echo "FAIL: $profile: $why" >&2
  echo "$out" >&2
  exit 1
}

for profile in "${profiles[@]}"; do
  out="$(run_nsaudit "$profile")"

  echo "$out" | grep -q 'severity=high' &&
    fail_profile "$profile" "high-severity nsaudit violation" "$out"
  echo "$out" | grep -q 'authority=attaches_device' &&
    fail_profile "$profile" "NODEVS/device attach invariant broken" "$out"
  echo "$out" | grep -q 'authority=privileged_control_path' &&
    fail_profile "$profile" "trusted control path granted" "$out"
  echo "$out" | grep -q 'authority=direct_mail_send' &&
    fail_profile "$profile" "raw mail send surface granted" "$out"
  echo "$out" | grep -q 'authority=reads_secrets_factotum' &&
    fail_profile "$profile" "factotum secrets visible" "$out"

  case "$profile" in
    profile-desktop-gui)
      echo "$out" | grep -q 'authority=sends_ui' ||
        fail_profile "$profile" "desktop GUI profile lacks UI authority" "$out"
      ;;
    *)
      echo "$out" | grep -q 'authority=sends_ui' &&
        fail_profile "$profile" "non-GUI profile has UI authority" "$out"
      ;;
  esac

  case "$profile" in
    profile-messaging)
      echo "$out" | grep -q 'authority=proposes_message' ||
        fail_profile "$profile" "messaging profile lacks proposal authority" "$out"
      echo "$out" | grep -q 'writes_fs=/mnt/msg/draft.*reversibility=proposal' ||
        fail_profile "$profile" "message draft is not classified as a proposal" "$out"
      echo "$out" | grep -q 'authority=writes_fs_durable' &&
        fail_profile "$profile" "message proposal misclassified as durable mutation" "$out"
      ;;
    *)
      echo "$out" | grep -q 'authority=proposes_message' &&
        fail_profile "$profile" "non-messaging profile has proposal authority" "$out"
      ;;
  esac

  case "$profile" in
    profile-payments)
      echo "$out" | grep -q 'authority=proposes_payment' ||
        fail_profile "$profile" "payments profile lacks proposal authority" "$out"
      echo "$out" | grep -q 'authority=spends' &&
        fail_profile "$profile" "payments profile unexpectedly has direct spend authority" "$out"
      ;;
    *)
      echo "$out" | grep -q 'authority=proposes_payment' &&
        fail_profile "$profile" "non-payment profile has payment proposal authority" "$out"
      ;;
  esac

  echo "PASS: $profile"
done

echo "PASS: nsaudit profile invariants hold"

# The fixtures are only worth checking if a live tools9p given the same
# tools and paths audits the same way (INFR-456). Materialize each one, and
# the additive compositions, and compare nsaudit's reports. The scratch
# capability is constructed by tools9p itself, never passed with -p.

fixture_tools() {
  tr '\n' ' ' <"$ROOT/tests/nsaudit-fixtures/$1/tools"
}

fixture_paths() {
  awk '$1 != "/tmp/veltro/scratch" { printf "-p %s:%s ", $1, $2 }' \
    "$ROOT/tests/nsaudit-fixtures/$1/paths"
}

# nsaudit's report less its caps line, which names the directory audited
report() {
  grep -v '^nsaudit=caps' | grep -E '^(authority|reads_fs|writes_fs|violation)=' | sort -u
}

# live_audit "tools9p args": nsaudit -m against a live /tool
live_audit() {
  local args="$1" log pid i
  log="$(mktemp)"
  "$EMU" -r"$ROOT" "$SH" -c "path=(/dis/veltro /dis/cmd /dis .); load std
    tools9p -m /tool $args &
    while {! ftest -e /tool/tools} {sleep 1}
    echo LIVE-BEGIN; nsaudit -m /tool; echo LIVE-END" </dev/null >"$log" 2>&1 &
  pid=$!
  for ((i = 0; i < 120; i++)); do
    grep -q '^LIVE-END' "$log" && break
    sleep 0.5
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if ! grep -q '^LIVE-END' "$log"; then
    echo "FAIL: live tools9p $args: no nsaudit report within 60s" >&2
    cat "$log" >&2
    rm -f "$log"
    exit 1
  fi
  sed -n '/^LIVE-BEGIN/,/^LIVE-END/p' "$log"
  rm -f "$log"
}

live_compare() {
  local name="$1" args="$2" want="$3" live
  live="$(live_audit "$args")"
  echo "$live" | grep -q '^nsaudit=caps.*nodevs=set' ||
    fail_profile "$name" "live tools9p does not report nodevs=set" "$live"
  echo "$live" | grep -q 'severity=high' &&
    fail_profile "$name" "high-severity nsaudit violation in the live profile" "$live"
  if [ "$(echo "$live" | report)" != "$want" ]; then
    fail_profile "$name" "live audit differs from the fixture's" \
      "$(diff <(echo "$want") <(echo "$live" | report))"
  fi
  echo "PASS: $name live"
}

for profile in "${profiles[@]}"; do
  live_compare "$profile" "$(fixture_paths "$profile") $(fixture_tools "$profile")" \
    "$(run_nsaudit "$profile" | report)"
done

# Compositions are additive: their authority is the union of their layers'.
compose() {
  local name="$1" p args="" tools="" want=""
  shift
  for p in "$@"; do
    args="$args $(fixture_paths "$p")"
    tools="$tools $(fixture_tools "$p")"
    want="$want
$(run_nsaudit "$p" | report)"
  done
  tools="$(echo $tools | tr ' ' '\n' | sort -u | tr '\n' ' ')"
  live_compare "$name" "$args $tools" "$(echo "$want" | grep . | sort -u)"
}

compose desktop+messaging profile-desktop-gui profile-messaging
compose messaging+payments profile-messaging profile-payments
compose all profile-minimal-headless profile-desktop-gui profile-messaging profile-payments

echo "PASS: live profiles audit as their fixtures do"
