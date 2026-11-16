#!/bin/sh
# lib9's 9P marshalling at its edges (convM2S.c, convS2M.c, convM2D.c,
# convD2M.c, fcallfmt.c, and libkern's copies of them, which the native
# kernels are built from): tests/host/ninep_conv/convtest.c under ASan
# and UBSan, every message and Fcall in a block exactly its length.
#
# - a 9P string with a NUL in it (a Twalk's name "..", NUL, "ab"; an
#   Rerror's text; a version, a user name, an aname, a name to create)
#   is refused by convM2S, and a stat with one in any of its four
#   strings by statcheck and convM2D: C read the string up to the NUL
#   and a reader that keeps the count read all of it
# - convS2M gives no size to, and does not pack, a Twalk of more than
#   16 names or an Rwalk of more than 16 qids (sizeS2M walked the names
#   before convS2M looked at their number: past the Fcall), an Rread or
#   Twrite whose count wraps the size (count fffffff8 was the size 3,
#   and that many bytes were then copied), or a string of 65536 bytes
#   or more (it went out whole behind its length mod 65536)
# - convD2M does not pack, and sizeD2M gives no size to, a Dir whose
#   strings do not fit a stat's 16-bit size (a name of 65540 bytes was
#   "packed" with a size field of 52 and a name count of 4)
# - %F of a Twstat or Rstat unpacks a stat only where it has room (it
#   had 200 bytes for the Dir and its strings: a stat of 150 bytes or
#   more went past them, on the stack), and says so when the stat is
#   none (it printed four strings from wherever the bytes pointed);
#   bytes past 7f are two hex digits each
# - 300000 random stats and a million random messages: what is taken
#   lies in its bytes, and the string C reads is the string sent
#
# By the source: lib9's and libkern's files are the same; convM2D is
# given no length for the strings it writes, so each caller's room is
# checked here by its shape: nil, the bytes behind a Dir allocated with
# the stat's length, fcallfmt's own, and emu/Nt/devfs.c's fixed array,
# which checks the stat's length first (it did not: a wstat with names
# of more than 1020 bytes went over the Windows emulator's stack; that
# file is not built here).
#
# NINEP_CONV_SRC=dir runs the C half against another lib9 (the code
# before). No emulator needed.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/ninep_conv"
CC="${CC:-cc}"
rc=0
fail() { echo "FAIL: $*"; rc=1; }
pass() { echo "PASS: $*"; }

# ---- by the source
same=1
for f in convM2S convS2M convM2D convD2M fcallfmt; do
	cmp -s "$ROOT/lib9/$f.c" "$ROOT/libkern/$f.c" || { fail "lib9/$f.c and libkern/$f.c differ"; same=0; }
done
[ $same = 1 ] && pass "libkern's copies of the five files are lib9's"

callers=$(cd "$ROOT" && grep -n 'convM2D(' emu/port/*.c emu/*/*.c os/port/*.c os/ip/*.c os/*/*.c lib9/fcallfmt.c libkern/fcallfmt.c libinterp/*.c 2>/dev/null | sort -u)
odd=$(echo "$callers" | grep -v -e ', nil);' \
	-e ', (char\*)&d\[1\])' -e ', (char\*)&dir\[1\])' -e ', (char\*)(d+1))' \
	-e 'sysfile.c:.*convM2D(&buf\[i\], m, \*d + nn, s) != m' \
	-e 'fcallfmt.c:.*convM2D(f->stat, f->nstat, d, st.b+sizeof(Dir)) == 0' \
	-e '^emu/Nt/devfs.c:.*convM2D(buf, n, &dir, strs);')
if [ -n "$odd" ]; then
	fail "a caller of convM2D whose room for the strings has not been looked at: $odd"
else
	pass "$(echo "$callers" | wc -l | tr -d ' ') callers of convM2D give it nil, the bytes behind a Dir, or a checked array"
fi
# the Windows wstat: the length is asked before the strings are copied
nt="$ROOT/emu/Nt/devfs.c"
if [ -f "$nt" ]; then
	if awk '
		/^fswstat\(/ { infn = 1 }
		infn && /if\(n > sizeof\(strs\)\)/ { guard = NR }
		infn && guard && NR == guard+1 && !/error\(Ebadstat\)/ { guard = 0 }
		infn && /convM2D\(buf, n, &dir, strs\)/ { call = NR; exit }
		END { exit !(guard && call && guard < call) }' "$nt"; then
		pass "emu/Nt/devfs.c: fswstat refuses a stat longer than its array before unpacking it"
	else
		fail "emu/Nt/devfs.c: fswstat unpacks a stat's strings into a fixed array without asking its length"
	fi
fi
# fcallfmt: room for the strings is the stat's length at most
for d in lib9 libkern; do
	if grep -q 'b\[sizeof(Dir)+Maxfmtstat\]' "$ROOT/$d/fcallfmt.c" && [ "$(grep -c 'if(f->nstat > Maxfmtstat)' "$ROOT/$d/fcallfmt.c")" = 2 ]; then
		:
	else
		fail "$d/fcallfmt.c: a stat is unpacked into less room than it may need"
	fi
done

# ---- the C half
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM
echo 'int main(void){return 0;}' > "$TMP/san.c"
if ! $CC -fsanitize=address,undefined -o "$TMP/san" "$TMP/san.c" 2>/dev/null || ! "$TMP/san"; then
	echo "SKIP: $CC has no AddressSanitizer here"
	exit $rc
fi
LIB9A="$ROOT/$EMUHOST/$OBJTYPE/lib/lib9.a"
[ -f "$LIB9A" ] || { echo "SKIP: no $LIB9A (the formatter under %F)"; exit $rc; }

SRC="${NINEP_CONV_SRC:-$ROOT/lib9}"
INC="-I$ROOT/$EMUHOST/$OBJTYPE/include -I$ROOT/include"
# (the shift check is on: fcall.h's GBIT32 shifted a byte into an int's sign)
CFLAGS="-g -O -fno-strict-aliasing -w -fsanitize=address,undefined -fno-sanitize-recover=undefined"
if ! $CC $CFLAGS $INC -o "$TMP/convtest" "$D/convtest.c" \
	"$SRC/convM2S.c" "$SRC/convS2M.c" "$SRC/convM2D.c" "$SRC/convD2M.c" "$SRC/fcallfmt.c" \
	"$LIB9A" -lm 2>"$TMP/cc.log"; then
	cat "$TMP/cc.log"
	fail "convtest does not compile"
	exit 1
fi

for c in m2snul m2dnul s2mwalk s2mcount s2mstring d2msize fmtstat random; do
	if ASAN_OPTIONS=detect_leaks=0 with_timeout 300 "$TMP/convtest" $c >"$TMP/out" 2>&1; then
		pass "$(tail -1 "$TMP/out")"
	else
		grep -e 'not so:' -e 'ERROR: AddressSanitizer' -e 'runtime error' -e '^    #[0-4] ' "$TMP/out" | head -8 | cut -c1-200
		fail "$c: $(grep -c 'not so:' "$TMP/out") checks not so$(grep -q 'AddressSanitizer\|runtime error' "$TMP/out" && echo ', and a sanitizer report')"
	fi
done
exit $rc
