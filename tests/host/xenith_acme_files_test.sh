#!/bin/sh
#
# xenith_acme_files_test.sh — the window files and ctl messages Xenith
# takes from canonical Acme: xdata, errors, ctl dirty, ctl menu/nomenu.
#
# Runs tests/inferno/xenith_acme_files_test.sh inside a headless Xenith
# (xenith_inside.sh). Needs the SDL GUI emulator: SKIP (77) on a
# headless build.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"

xenith_inside xenith_acme_files /tests/inferno/xenith_acme_files_test.sh
