#!/bin/bash
#
# tests/host/x25519_test.sh
#
# libsec's X25519 (x25519.c) on the host (tests/host/x25519/x25test.c),
# against OpenSSL's (tests/host/x25519/vectors.txt, made by gen.py with
# Python's cryptography):
#
#   - fcontract, which writes a field element out as 32 bytes, took 19
#     back when the element was below p and added the borrow to the next
#     limb where it must be subtracted: a result whose low 51 bits were
#     within 19 of 2^51 came out as another number.  The first vector is
#     such a result (the scalar is -1 mod the group's order and the
#     point's low limb is 2^51-1, so the result is the point); RFC 7748's
#     vectors never meet it
#   - 63 X25519 results, RFC 7748 6.1's among them
#   - 809 field elements written out, each low limb from 2^51-40 to
#     2^51-1 with limbs of all kinds above it, p-1, p, p+1, 2^255-1, and
#     random ones; and each read back and written again
#
# under ASan and UBSan where the compiler has them.  No emulator is needed.
#
# Run from project root: ./tests/host/x25519_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/x25519"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp -I$ROOT/libsec"
CFLAGS="-g -O -fno-strict-aliasing -w"
echo 'int main(void){return 0;}' > "$TMP/san.c"
if $CC -fsanitize=address,undefined -o "$TMP/san" "$TMP/san.c" 2>/dev/null && "$TMP/san"; then
	CFLAGS="$CFLAGS -fsanitize=address,undefined -fno-sanitize-recover=undefined"
fi
# (X25519_SRC: another x25519.c, to see what it does)
SRC="${X25519_SRC:-$ROOT/libsec/x25519.c}"
sed "s|\"../../../libsec/x25519.c\"|\"$SRC\"|" "$D/x25test.c" > "$TMP/x25test.c"
if ! $CC $CFLAGS $INC -o "$TMP/x25test" "$TMP/x25test.c" "$ROOT/libsec/securezero.c" 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	echo "FAIL: x25test does not compile"
	exit 1
fi
if with_timeout 120 "$TMP/x25test" "$D/vectors.txt" >"$TMP/out" 2>&1; then
	sed 's/^/    /' "$TMP/out"
	echo "PASS: X25519 against OpenSSL, and field elements written as they are"
	exit 0
fi
head -20 "$TMP/out"
echo "FAIL: x25test"
exit 1
