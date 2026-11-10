#!/bin/bash
#
# tests/host/armcrypto_test.sh
#
# libsec's AES and SHA-256 with the ARMv8 Cryptography Extension
# (libsec/aesarm64.c, libsec/sha256arm64.c), built on the host:
#
#   - tests/host/aes/aestest.c: FIPS-197 blocks and NIST SP 800-38A's
#     CBC vectors for AES-128, -192 and -256 through aes.c's tables and
#     through the instructions; 6000 random keys, IVs and lengths
#     encrypted and decrypted by both, the same bytes; speeds
#   - tests/host/sha256/shatest.c: FIPS 180-4's examples (a million
#     "a"s among them) through sha256block.c's C and through the
#     instructions; 3000 random messages fed in random pieces, the same
#     digests; speeds
#
# Where the processor has no such instructions (amd64, or an arm64
# without them) the C paths are checked and the rest skipped.  Each is
# built with gcc and clang where both are here.  No emulator is needed.
#
# Run from project root: ./tests/host/armcrypto_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
# the flags emu's libsec is built with (mkfiles/mkfile-*): -O, not -O2
CFLAGS="-g -O -fno-strict-aliasing -w"
S="$ROOT/libsec"

ccs=""
for c in ${CC:-cc gcc clang}; do
	command -v "$c" >/dev/null 2>&1 || continue
	v="$("$c" --version 2>/dev/null | head -1)"
	case " $seen " in *" $v "*) continue;; esac	# cc is often one of the others
	seen="$seen $v"
	ccs="$ccs $c"
done
[ -n "$ccs" ] || { echo "SKIP: no C compiler"; exit 77; }

fails=0
for c in $ccs; do
	if $c $CFLAGS $INC -o "$TMP/aestest" "$ROOT/tests/host/aes/aestest.c" "$S/aesarm64.c" 2>"$TMP/cc.log"; then
		if "$TMP/aestest" >"$TMP/out" 2>&1; then
			sed "s/^/$c: /" "$TMP/out"
		else
			sed "s/^/$c: /" "$TMP/out"
			echo "FAIL: $c: aestest"
			fails=$((fails+1))
		fi
	else
		cat "$TMP/cc.log"
		echo "FAIL: $c: aestest does not compile"
		fails=$((fails+1))
	fi
	if $c $CFLAGS $INC -o "$TMP/shatest" "$ROOT/tests/host/sha256/shatest.c" \
		"$S/sha2.c" "$S/sha256block.c" "$S/sha512block.c" "$S/sha256arm64.c" 2>"$TMP/cc.log"; then
		if "$TMP/shatest" >"$TMP/out" 2>&1; then
			sed "s/^/$c: /" "$TMP/out"
		else
			sed "s/^/$c: /" "$TMP/out"
			echo "FAIL: $c: shatest"
			fails=$((fails+1))
		fi
	else
		cat "$TMP/cc.log"
		echo "FAIL: $c: shatest does not compile"
		fails=$((fails+1))
	fi
done

if [ $fails -eq 0 ]; then
	echo "PASS: AES and SHA-256, C and ARMv8, agree with the standards and each other"
	exit 0
fi
exit 1
