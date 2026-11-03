#!/bin/sh
# The native kernel's random-number generator (os/port/random.c), on
# the host: ChaCha20 keyed from the hardware generator alone, against a
# generator this test drives. What it checks is in kernrandom_helper.c:
# the construction against a model written from RFC 8439, failing closed
# with no generator, the Dis VM let go while a key waits, reseeding by
# time and by bytes, a dry generator's ten minutes, refused seeds,
# insecurerandom.
#
# random.c is compiled from a copy beside kernrandom_shim.h, which
# stands in for every kernel header it includes; libsec's own ChaCha20
# and SHA-256 are linked with it.

set -eu

ROOT=${ROOT:-.}
. "$(dirname "$0")/common.sh"
TMP=${TMPDIR:-/tmp}/infernode-kernrandom-$$
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
mkdir -p "$TMP/port"

for h in u.h lib.h mem.h dat.h fns.h error.h mp.h libsec.h interp.h; do
	echo '#include "kernrandom_shim.h"' > "$TMP/port/$h"
done
cp "$ROOT/tests/host/kernrandom_shim.h" "$TMP/port/"
cp "$ROOT/os/port/random.c" "$TMP/port/random.c"

LIBSEC="$ROOT/libsec/chacha.c $ROOT/libsec/sha2.c $ROOT/libsec/sha256block.c $ROOT/libsec/sha512block.c"
for f in $LIBSEC; do
	cc -I"$ROOT/$EMUHOST/$OBJTYPE/include" -I"$ROOT/include" -I"$ROOT/libmp" \
		-c "$f" -o "$TMP/$(basename "$f" .c).o"
done
cc -I"$TMP/port" -c "$TMP/port/random.c" -o "$TMP/random.o"
cc -I"$TMP/port" -I"$ROOT/tests/host" -c "$ROOT/tests/host/kernrandom_helper.c" -o "$TMP/helper.o"
cc "$TMP"/*.o -o "$TMP/kernrandom"
"$TMP/kernrandom"
