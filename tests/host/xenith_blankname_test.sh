#!/bin/sh
# A file name with a blank in it in Xenith's tag: quoted, read back
# whole, Put to the right file (tests/inferno/xenith_blankname_test.sh,
# run inside a headless Xenith).
. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"
xenith_inside xenith_blankname /tests/inferno/xenith_blankname_test.sh
