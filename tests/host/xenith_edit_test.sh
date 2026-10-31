#!/bin/sh
#
# xenith_edit_test.sh — Xenith's addresses, regular expressions and sam
# command language, end to end through a window's addr, xdata and edit
# files.
#
# Runs tests/inferno/xenith_edit_test.sh inside a headless Xenith
# (xenith_inside.sh). Needs the SDL GUI emulator: SKIP (77) on a
# headless build.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"

xenith_inside xenith_edit /tests/inferno/xenith_edit_test.sh
