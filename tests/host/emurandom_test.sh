#!/bin/sh
# The emulator's random-number generator (libsec/genrandom.c: HMAC_DRBG
# with SHA-512, NIST SP 800-90A, over the host's), on the host, its host
# generator scripted by tests/host/emurandom/emurandomtest.c and its
# output checked against a model of HMAC_DRBG written from SP 800-90A.
# What it checks is in emurandomtest.c. No emulator needed.

set -eu

ROOT=${ROOT:-.}
. "$(dirname "$0")/common.sh"
TMP=${TMPDIR:-/tmp}/infernode-emurandom-$$
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
cc -g -O -w $INC -o "$TMP/emurandom" "$ROOT/tests/host/emurandom/emurandomtest.c" \
	"$ROOT/libsec/hmacdrbg.c" "$ROOT/libsec/hmac.c" "$ROOT/libsec/md5.c" "$ROOT/libsec/md5block.c" \
	"$ROOT/libsec/sha1.c" "$ROOT/libsec/sha1block.c" "$ROOT/libsec/sha2.c" "$ROOT/libsec/sha256block.c" \
	"$ROOT/libsec/sha256arm64.c" "$ROOT/libsec/sha512block.c" "$ROOT/libsec/securezero.c"
if "$TMP/emurandom" >"$TMP/out" 2>&1; then
	sed 's/^/emu random: /' "$TMP/out"
else
	sed 's/^/emu random: /' "$TMP/out"
	echo "emu random: FAIL"
	exit 1
fi
