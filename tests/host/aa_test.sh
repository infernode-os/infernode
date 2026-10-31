#!/bin/sh
#
# The anti-aliased rasteriser (libmemdraw/aa.c, aapath.c) and the path
# encoding clients use (libdraw/path.c): build libmemdraw/aatest.c
# against the host libraries and run it.  It checks
# exact coverage, fill rules, stroke outlines against a brute-force
# reference, and that drawing in pieces changes no pixel.
#

. "$(dirname "$0")/common.sh"

LIB="$ROOT/$EMUHOST/$OBJTYPE/lib"
for l in libmemdraw libmemlayer libdraw lib9; do
    if [ ! -f "$LIB/$l.a" ]; then
        echo "SKIP: $LIB/$l.a not built"
        exit 77
    fi
done

case "$EMUHOST" in
    MacOSX) DEFS="-DMACOSX_$(echo $OBJTYPE | tr a-z A-Z)" ;;
    Linux)  DEFS="-DLINUX_$(echo $OBJTYPE | tr a-z A-Z) -fcommon" ;;
esac

TMP="${TMPDIR:-/tmp}/aa_test.$$"
trap 'rm -f "$TMP"' EXIT
${CC:-cc} -g -O $DEFS -I"$ROOT/$EMUHOST/$OBJTYPE/include" -I"$ROOT/include" \
    -o "$TMP" "$ROOT/libmemdraw/aatest.c" "$ROOT/libdraw/path.c" \
    "$LIB/libmemdraw.a" "$LIB/libmemlayer.a" "$LIB/libdraw.a" "$LIB/lib9.a" -lm || {
    echo "FAIL: aatest did not build"
    exit 1
}
"$TMP"
