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
    profile-payments)
      echo "$out" | grep -q 'authority=spends' ||
        fail_profile "$profile" "payments profile lacks spend authority" "$out"
      echo "$out" | grep -q 'authority=spend_ungated' &&
        fail_profile "$profile" "payments profile has unbounded spend" "$out"
      ;;
    *)
      echo "$out" | grep -q 'authority=spends' &&
        fail_profile "$profile" "non-payment profile has spend authority" "$out"
      ;;
  esac

  echo "PASS: $profile"
done

echo "PASS: nsaudit profile invariants hold"
