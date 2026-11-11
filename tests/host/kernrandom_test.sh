#!/bin/sh
# The native kernel's random-number generator (os/port/random.c), on
# the host: HMAC_DRBG with SHA-512 (NIST SP 800-90A), seeded from the
# hardware generator alone, against a generator this test drives. What
# it checks is in kernrandom_helper.c: a model written from SP 800-90A
# against NIST's CAVP vectors (kernrandom/hmacdrbg_sha512.txt), the
# kernel's output against the model, failing closed with no generator,
# the Dis VM let go while a key waits, reseeding by time and by bytes,
# a dry generator's ten minutes, SP 800-90B's health tests and the
# other refused seeds, insecurerandom.
#
# random.c is compiled from a copy beside kernrandom_shim.h, which
# stands in for every kernel header it includes; libsec's own SHA-2
# and HMAC are linked with it.

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

LIBSEC="$ROOT/libsec/hmac.c $ROOT/libsec/hmacdrbg.c $ROOT/libsec/md5.c $ROOT/libsec/md5block.c $ROOT/libsec/sha1.c $ROOT/libsec/sha1block.c $ROOT/libsec/sha2.c $ROOT/libsec/sha256block.c $ROOT/libsec/sha256arm64.c $ROOT/libsec/sha512block.c"
for f in $LIBSEC; do
	cc -I"$ROOT/$EMUHOST/$OBJTYPE/include" -I"$ROOT/include" -I"$ROOT/libmp" \
		-c "$f" -o "$TMP/$(basename "$f" .c).o"
done
cc -I"$TMP/port" -c "$TMP/port/random.c" -o "$TMP/random.o"
cc -I"$TMP/port" -I"$ROOT/tests/host" -c "$ROOT/tests/host/kernrandom_helper.c" -o "$TMP/helper.o"
cc "$TMP"/*.o -o "$TMP/kernrandom"
KERNRANDOM_VECTORS="$ROOT/tests/host/kernrandom/hmacdrbg_sha512.txt" "$TMP/kernrandom"
