#!/bin/sh
# A 9P directory entry's encoded size must fit inside the bytes returned by
# the device before statcheck reads any fixed or variable field.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

TMP="$ROOT/tmp/statcheck-bounds-test"
BIN="$TMP/statcheck-bounds-test"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

CC=${CC:-cc}
if ! "$CC" -fsanitize=address,undefined -fno-omit-frame-pointer \
	-I"$ROOT/$EMUHOST/$OBJTYPE/include" -I"$ROOT/include" \
	"$ROOT/tests/host/statcheck_bounds_test.c" \
	"$ROOT/lib9/convM2D.c" -o "$BIN"; then
	echo "FAIL: could not build the sanitized stat bounds regression"
	exit 1
fi

if ! "$BIN"; then
	rc=$?
	echo "FAIL: stat buffer bounds regression returned $rc"
	exit 1
fi

echo "PASS: 9P stat entries are bounded by the available directory data"
