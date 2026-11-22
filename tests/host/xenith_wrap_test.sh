#!/bin/sh
# Wrap in a headless Xenith: the command, ctl's wrap word and wrap
# char, the global WORD and CHAR, the body and its
# lines unchanged (tests/inferno/xenith_wrap_test.sh, run inside it).
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"
xenith_inside xenith_wrap /tests/inferno/xenith_wrap_test.sh
