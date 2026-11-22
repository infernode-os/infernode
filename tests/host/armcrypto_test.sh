#!/bin/bash
#
# tests/host/armcrypto_test.sh
#
# libsec's AES, AES-GCM and SHA-256 with the processor's instructions:
# the ARMv8 Cryptography Extension (libsec/aesarm64.c, libsec/ghasharm64.c,
# libsec/sha256arm64.c) and x86-64's AES-NI and PCLMULQDQ
# (libsec/aesamd64.c, libsec/ghashamd64.c), built on the host:
#
#   - tests/host/aes/aestest.c: FIPS-197 blocks and NIST SP 800-38A's
#     CBC vectors for AES-128, -192 and -256 through aes.c's
#     constant-time C (bit planes) and through the instructions; the
#     C's S-box circuit and its inverse on every byte; 3000 random keys,
#     IVs and lengths against a plain reference written from FIPS 197
#     in the test (round keys, CBC both ways, counter mode across its
#     wrap), by the C and again by the instructions (whose key
#     expansion on x86-64 is their own); 6000 keys given the same
#     schedules by both, and encrypted and decrypted by the C and the
#     instructions, the same bytes (CBC, a block, counter mode); speeds;
#     with valgrind (Linux), the C constant time (ctgrind): no branch
#     or address depends on the key, the IV or the data, in the key
#     schedule, CBC either way, a block or the counter mode; and the
#     same of the instructions' code
#   - tests/host/gcm/gcmtest.c: OpenSSL's AES-GCM answers
#     (tests/host/gcm/vectors.txt, from gen.py) for 128-, 192- and 256-bit
#     keys, IVs of 12 bytes and others, every length across the blocks,
#     with GHASH in C and by PMULL or PCLMULQDQ and the counter mode by
#     aes.c and by the instructions; 3000 random cases the same in each,
#     each refused with a byte of its ciphertext, AAD or tag changed;
#     GHASH by the C and by the instructions the same at every number
#     of blocks to 40; speeds; with valgrind (Linux), the C GHASH
#     constant time (ctgrind): no branch or address depends on its key
#     or data; and the same of the instructions' GHASH and a seal
#     through them
#   - tests/host/sha256/shatest.c: FIPS 180-4's examples (a million
#     "a"s among them) through sha256block.c's C and through the
#     instructions; 3000 random messages fed in random pieces, the same
#     digests; speeds
#
# Where the processor has no such instructions (an x86-64 without
# AES-NI, an arm64 without the extension, any other) the C paths are
# checked and the rest skipped.  Each is
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
AESHW="$S/aesarm64.c $S/aesamd64.c"
GHASHHW="$S/ghasharm64.c $S/ghashamd64.c"

# ctgrind what prog [args]: run under valgrind; no report of a branch or
# address that depends on what the program marked secret.  A program
# that exits 2 had no instructions to check.
ctgrind()
{
	what="$1"; shift
	valgrind --error-limit=no --log-file="$TMP/vg" "$@" >/dev/null 2>&1
	st=$?
	if [ $st -eq 2 ]; then
		echo "SKIP: $c: $what: no such instructions on this processor"
		return
	fi
	n=$(grep -c 'depends on uninitialised\|Use of uninitialised' "$TMP/vg")
	if grep -q 'unrecognised instruction\|Illegal instruction' "$TMP/vg"; then
		echo "SKIP: $c: $what: this valgrind does not know the instructions"
	elif [ $st -ne 0 ]; then
		tail -5 "$TMP/vg"
		echo "FAIL: $c: $what: the program failed under valgrind (status $st)"
		fails=$((fails+1))
	elif [ "$n" -eq 0 ]; then
		echo "$c: $what is constant time (valgrind: no branch or address on its key, IV or data)"
	else
		grep -A3 'depends on uninitialised\|Use of uninitialised' "$TMP/vg" | head -20
		echo "FAIL: $c: $what branches or indexes on its key or data ($n reports)"
		fails=$((fails+1))
	fi
}

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
	if $c $CFLAGS $INC -o "$TMP/aestest" "$ROOT/tests/host/aes/aestest.c" $AESHW "$S/securezero.c" 2>"$TMP/cc.log"; then
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
	if command -v valgrind >/dev/null 2>&1 && [ -f /usr/include/valgrind/memcheck.h ]; then
		if $c $CFLAGS -DCTGRIND $INC -o "$TMP/aestest-ct" "$ROOT/tests/host/aes/aestest.c" $AESHW \
			"$S/securezero.c" 2>"$TMP/cc.log"; then
			ctgrind "AES in C" "$TMP/aestest-ct" ct
			ctgrind "AES by the instructions" "$TMP/aestest-ct" ct hw
		else
			cat "$TMP/cc.log"
			echo "FAIL: $c: aestest -DCTGRIND does not compile"
			fails=$((fails+1))
		fi
	elif [ -n "${CI:-}" ] && [ "$(uname)" = Linux ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the AES constant-time check did not run"
		fails=$((fails+1))
	else
		echo "SKIP: $c: AES constant-time check (needs valgrind and its headers)"
	fi
	if $c $CFLAGS $INC -o "$TMP/gcmtest" "$ROOT/tests/host/gcm/gcmtest.c" "$S/aes.c" $AESHW \
		$GHASHHW "$S/securezero.c" 2>"$TMP/cc.log"; then
		if "$TMP/gcmtest" "$ROOT/tests/host/gcm/vectors.txt" >"$TMP/out" 2>&1; then
			sed "s/^/$c: /" "$TMP/out"
		else
			sed "s/^/$c: /" "$TMP/out"
			echo "FAIL: $c: gcmtest"
			fails=$((fails+1))
		fi
	else
		cat "$TMP/cc.log"
		echo "FAIL: $c: gcmtest does not compile"
		fails=$((fails+1))
	fi
	if command -v valgrind >/dev/null 2>&1 && [ -f /usr/include/valgrind/memcheck.h ]; then
		if $c $CFLAGS -DCTGRIND $INC -o "$TMP/gcmtest-ct" "$ROOT/tests/host/gcm/gcmtest.c" "$S/aes.c" \
			$AESHW $GHASHHW "$S/securezero.c" 2>"$TMP/cc.log"; then
			ctgrind "the C GHASH" "$TMP/gcmtest-ct" ct
			ctgrind "GHASH and AES-GCM by the instructions" "$TMP/gcmtest-ct" ct hw
		else
			cat "$TMP/cc.log"
			echo "FAIL: $c: gcmtest -DCTGRIND does not compile"
			fails=$((fails+1))
		fi
	elif [ -n "${CI:-}" ] && [ "$(uname)" = Linux ]; then
		echo "FAIL: CI has no valgrind (and valgrind's memcheck.h): the GHASH constant-time check did not run"
		fails=$((fails+1))
	else
		echo "SKIP: $c: GHASH constant-time check (needs valgrind and its headers)"
	fi
	if $c $CFLAGS $INC -o "$TMP/shatest" "$ROOT/tests/host/sha256/shatest.c" \
		"$S/sha2.c" "$S/sha256block.c" "$S/sha512block.c" "$S/sha256arm64.c" "$S/securezero.c" 2>"$TMP/cc.log"; then
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
	echo "PASS: AES, AES-GCM and SHA-256, the C and the processor's instructions, agree with the standards, OpenSSL and each other"
	exit 0
fi
exit 1
