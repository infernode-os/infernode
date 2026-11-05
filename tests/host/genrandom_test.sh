#!/bin/sh
# Compile the libsec generator in isolation and verify call-separated output.

set -eu

ROOT=${ROOT:-.}
. "$(dirname "$0")/common.sh"
TMP=${TMPDIR:-/tmp}/infernode-genrandom-$$
trap 'rm -f "$TMP"' EXIT HUP INT TERM

cc -I"$ROOT/$EMUHOST/$OBJTYPE/include" -I"$ROOT/include" -I"$ROOT/libmp" \
	"$ROOT/tests/host/genrandom_helper.c" \
	"$ROOT/libsec/genrandom.c" "$ROOT/libsec/chacha.c" \
	-o "$TMP"
"$TMP"

echo 'PASS: libsec genrandom uses call-separated ChaCha20 output'
