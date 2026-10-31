#!/bin/sh
#
# xenith_event_test.sh — Xenith's event protocol through a window's
# event file: changes reported, events written back carried out, and
# malformed ones refused.
#
# Runs tests/inferno/xenith_event_test.sh inside a headless Xenith
# (xenith_inside.sh). Needs the SDL GUI emulator: SKIP (77) on a
# headless build.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"

xenith_inside xenith_event /tests/inferno/xenith_event_test.sh
