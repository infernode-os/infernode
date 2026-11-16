#!/bin/bash
#
# tests/host/digest_edge_test.sh
#
# libsec's digests and HMACs (md5.c, sha1.c, sha2.c, hmac.c) on the host
# (tests/host/digest_edge/digesttest.c), against Python's hashlib and hmac
# (tests/host/digest_edge/vectors.txt, made by gen.py):
#
#   - with every allocation refused, a digest in one call, an HMAC in
#     one call and an HMAC through a caller's state still write their
#     answers.  The digests malloc'd a state for the one-call form and
#     HMAC one for its outer hash and for the hash of a long key, and
#     nil is both "no memory" and "done": the digest was left unwritten
#     (devssl then compared a record's MAC with what its stack held, and
#     took its AES-GCM key from an unwritten buffer), or a long key was
#     whatever the stack held
#   - SHA-224 and SHA-256 of 2^29 bytes and more: the count of bits was
#     kept in 32 bits, and the digest was another message's
#   - 78 digests and 180 HMACs (keys of 0 to 1000 bytes: before, at and
#     past a block) in one call and in pieces, under ASan and UBSan
#
# No emulator is needed.
#
# Run from project root: ./tests/host/digest_edge_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/digest_edge"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include -I$ROOT/libmp"
# (DIGEST_SRC: a directory with another libsec's sources, to see what they do)
S="${DIGEST_SRC:-$ROOT/libsec}"
SRCS="$S/md5.c $S/md5block.c $S/sha1.c $S/sha1block.c $S/sha2.c $S/sha256block.c $S/sha512block.c $S/sha256arm64.c $S/hmac.c"
[ -f "$S/securezero.c" ] && SRCS="$SRCS $S/securezero.c"

fails=0
build() {	# name flags
	objs=""
	for s in $SRCS; do
		o="$TMP/$1-$(basename "$s" .c).o"
		if ! $CC $2 -Dmalloc=xmalloc -Dfree=xfree $INC -c -o "$o" "$s" 2>"$TMP/cc.log"; then
			cat "$TMP/cc.log"
			echo "FAIL: $s does not compile"
			exit 1
		fi
		objs="$objs $o"
	done
	if ! $CC $2 $INC -o "$TMP/$1" "$D/digesttest.c" $objs 2>"$TMP/cc.log"; then
		cat "$TMP/cc.log"
		echo "FAIL: digesttest does not compile"
		exit 1
	fi
}

# the vectors under the sanitizers (where there are any)
echo 'int main(void){return 0;}' > "$TMP/san.c"
if $CC -fsanitize=address,undefined -o "$TMP/san" "$TMP/san.c" 2>/dev/null && "$TMP/san"; then
	build san "-g -O -fno-strict-aliasing -w -fsanitize=address,undefined -fno-sanitize-recover=undefined"
	if with_timeout 120 "$TMP/san" "$D/vectors.txt" >"$TMP/out" 2>&1; then
		echo "PASS: digests and HMACs under ASan and UBSan, with and without memory: $(tail -1 "$TMP/out")"
	else
		head -30 "$TMP/out"
		echo "FAIL: digesttest under ASan and UBSan"
		fails=$((fails+1))
	fi
else
	echo "SKIP: $CC has no AddressSanitizer here"
fi

# and 2^29 bytes, as the library is built
build plain "-g -O -fno-strict-aliasing -w"
if with_timeout 300 "$TMP/plain" "$D/vectors.txt" big >"$TMP/out" 2>&1; then
	echo "PASS: $(tail -1 "$TMP/out")"
else
	head -30 "$TMP/out"
	echo "FAIL: digesttest"
	fails=$((fails+1))
fi
[ $fails = 0 ]
