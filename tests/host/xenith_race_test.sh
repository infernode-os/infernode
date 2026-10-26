#!/bin/sh
#
# xenith_race_test.sh — Xenith used by a client and its user at once,
# at the places that froze it or took it down:
#
#	a B3 in a scroll bar ends when let go, so the next B3 looks
#	rather than scrolling the window again;
#	a client's get while the body holds typing keeps the typing;
#	a search begun at the end of the file comes round to it;
#	a Put of a file still loading writes all of it, and an edit made
#	while it loads goes where it was made;
#	ctl unlock without a lock, and a second lock, are refused rather
#	than waited for with the row held;
#	commands after del in one ctl write are not run on the deleted
#	window;
#	Edit X with a pipe command locks each file it runs in;
#	text reaching a window hidden under one grown to fill its column
#	does not take Xenith down;
#	a window's text changed while an Edit pipe command runs on it is
#	kept (the Edit refused), not lost with the command's output;
#	a change made while Put writes a large file in the background
#	leaves the window unsaved.
#
# Runs tests/inferno/xenith_race_test.sh (tests/xenith_race_helper.b)
# inside a headless Xenith (xenith_inside.sh). Needs the SDL GUI
# emulator: SKIP (77) on a headless build.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"

XENITH_INSIDE_TIMEOUT=${XENITH_INSIDE_TIMEOUT:-180} \
xenith_inside xenith_race /tests/inferno/xenith_race_test.sh
