#!/bin/sh
# A write to a Xenith window's ctl longer than one 9P message: a piece
# that fills its message and ends no line is refused, so the end of a
# long line is not run as a command of its own; whole lines still are
# (tests/inferno/xenith_ctlcut_test.sh, run inside a headless Xenith).
# Needs the SDL GUI emulator: SKIP (77) on a headless build.
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"
xenith_inside xenith_ctlcut /tests/inferno/xenith_ctlcut_test.sh
