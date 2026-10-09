#!/bin/sh
#
# xenith_image_test.sh — Xenith opens every image format imgload reads
# as an image, through a look (B3) at the file's name; formats with no
# decoder are refused with a reason, and text still opens as text.
#
# Runs tests/inferno/xenith_image_test.sh inside a headless Xenith
# (xenith_inside.sh). Needs the SDL GUI emulator: SKIP (77) on a
# headless build.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"

xenith_inside xenith_image /tests/inferno/xenith_image_test.sh
