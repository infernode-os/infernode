#!/bin/sh
#
# tests/host/aescbc_test.sh
#
# auth/aescbc (crypt(1)) on files that were changed, cut, or made by
# someone without the key (tests/host/aescbc/mk.py).
#
#   - The format before the header ("AES CBC SHA1  2\n") has no MAC: an
#     IV, then the file and sixteen X's under CBC, with the same key. It
#     was taken whenever the input did not begin with the header, so a
#     header-less file made, with no key, from a file in the new format
#     and the sixteen bytes its plaintext begins with was decrypted with
#     success to blocks of its maker's choosing. It is now read only with
#     -c; without it such a file is refused and nothing is written.
#   - Plaintext was written as it was decrypted and the MAC compared at
#     the end: a changed or cut file gave its output (all of it, or as far
#     as the cut) and then the error. Nothing is written now until the
#     input has been checked, from a file (read twice) and from a pipe
#     (held in memory).
#   - What worked still works: a file is encrypted and read back, from a
#     file and through a pipe, 10200 bytes and 300000; two encryptions of
#     one file differ; the old format is read with -c.
#
# Skips (exit 77) with no emulator or no python3. The old format's own
# files need Python's cryptography; without it those checks are left out.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/auth/aescbc.dis" ] || { echo "SKIP: dis/auth/aescbc.dis not built"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

MK="$(cd "$(dirname "$0")" && pwd)/aescbc/mk.py"
DIR="$ROOT/tmp/aescbc.$$"
G="/tmp/aescbc.$$"
mkdir -p "$DIR"
trap 'rm -rf "$DIR"' EXIT

rc=0
bad() { echo "FAIL: $1"; rc=1; }
ok() { echo "PASS: $1"; }
emu() {
	{ echo "load std"; echo "cd $G"; cat; echo "echo halt > /dev/sysctl"; } > "$DIR/script.$1"
	with_timeout 90 "$EMU" -r"$ROOT" -c1 sh "$G/script.$1" 2>&1 < /dev/null || true
}
has() { echo "$OUT" | grep -q -e "$1"; }
check() {
	if has "$2"; then ok "$1"; else bad "$1: $(echo "$OUT" | grep -v fsqid | grep -e "$3" | cut -c1-200 | tr '\n' '|')"; fi
}
size() { wc -c < "$DIR/$1" 2>/dev/null | tr -d ' '; }
empty() {
	if [ "$(size "$2")" = 0 ]; then ok "$1"; else bad "$1: $(size "$2") bytes were written"; fi
}

python3 -c "
import sys
sys.stdout.write(''.join('line %05d of the secret file....\n' % i for i in range(300)))" > "$DIR/plain"
python3 -c "
import sys
sys.stdout.write(''.join('%07d of the long secret file..\n' % i for i in range(10000)))" > "$DIR/big"

OUT=$(emu enc <<'INFERNO'
auth/aescbc -e -k pw < plain > enc
echo enc: $status.
auth/aescbc -e -k pw < plain > enc2
auth/aescbc -e -k pw < big > big.enc
echo bigenc: $status.
auth/aescbc -e -c -k pw < plain > enc3 >[2] /dev/null
echo enc-c: $status.
INFERNO
)
check "a file is encrypted" '^enc: \.$' 'enc:'
if has '^enc-c: \.$'; then bad "-c was taken with -e"; else ok "-c is for decrypting only"; fi
cmp -s "$DIR/enc" "$DIR/enc2" && bad "two encryptions of one file are the same" || ok "two encryptions of one file differ"
[ "$(head -c 16 "$DIR/enc")" = "AES CBC SHA1  2" ] && [ "$(size enc)" = 10268 ] &&
	ok "in the format with the header: header, IV, a random block, the file, the MAC" ||
	bad "the encrypted file is $(size enc) bytes and begins $(head -c 16 "$DIR/enc" | tr -d '\n')"

python3 "$MK" "$DIR" || { echo "FAIL: mk.py"; exit 1; }
havelegacy=0
[ -f "$DIR/legacy" ] && havelegacy=1

OUT=$(emu dec <<'INFERNO'
auth/aescbc -d -k pw < enc > dec.good
echo good: $status.
cat enc | auth/aescbc -d -k pw > dec.pipe
echo pipe: $status.
auth/aescbc -d -c -k pw < enc > dec.c
echo good-c: $status.
auth/aescbc -d -k pw < big.enc > big.dec
echo big: $status.
cat big.enc | auth/aescbc -d -k pw > big.pipe
echo bigpipe: $status.
auth/aescbc -d -k pw < enc.flip > dec.flip >[2] /dev/null
echo flip: $status.
cat enc.flip | auth/aescbc -d -k pw > dec.flippipe >[2] /dev/null
echo flippipe: $status.
auth/aescbc -d -k pw < enc.trunc > dec.trunc >[2] /dev/null
echo trunc: $status.
auth/aescbc -d -k pw < enc.short > dec.short >[2] /dev/null
echo short: $status.
auth/aescbc -d -k wrongpw < enc > dec.wrongpw >[2] /dev/null
echo wrongpw: $status.
auth/aescbc -d -k pw < forged > dec.forged
echo forged: $status.
cat forged | auth/aescbc -d -k pw > dec.forgedpipe >[2] /dev/null
echo forgedpipe: $status.
if {ftest -f legacy} {
	auth/aescbc -d -k pw < legacy > dec.legacy >[2] /dev/null
	echo legacy: $status.
	auth/aescbc -d -c -k pw < legacy > dec.legacyc
	echo legacy-c: $status.
	cat legacy | auth/aescbc -d -c -k pw > dec.legacypipe
	echo legacypipe-c: $status.
	auth/aescbc -d -c -k pw < legacy.cut > dec.legacycut >[2] /dev/null
	echo legacycut-c: $status.
	auth/aescbc -d -c -k wrongpw < legacy > dec.legacywrong >[2] /dev/null
	echo legacywrong-c: $status.
}
INFERNO
)
check "a file is decrypted" '^good: \.$' 'good:'
cmp -s "$DIR/plain" "$DIR/dec.good" && ok "to what was encrypted" || bad "the decrypted file differs from the plaintext"
check "and through a pipe" '^pipe: \.$' 'pipe:'
cmp -s "$DIR/plain" "$DIR/dec.pipe" && ok "to the same" || bad "decrypted through a pipe, the file differs"
check "and with -c, which does not change the format with the header" '^good-c: \.$' 'good-c:'
cmp -s "$DIR/plain" "$DIR/dec.c" || bad "decrypted with -c, the file differs"
check "300000 bytes are decrypted" '^big: \.$' 'big:'
cmp -s "$DIR/big" "$DIR/big.dec" && ok "to what was encrypted" || bad "the 300000 bytes differ"
check "and through a pipe" '^bigpipe: \.$' 'bigpipe:'
cmp -s "$DIR/big" "$DIR/big.pipe" && ok "to the same" || bad "the 300000 bytes through a pipe differ"

check "a file with one bit changed fails to authenticate" '^flip: .*failed to authenticate\.$' 'flip:'
empty "and nothing of it is written" dec.flip
check "the same through a pipe" '^flippipe: .*failed to authenticate' 'flippipe:'
empty "and nothing of it is written" dec.flippipe
check "a file cut short fails to authenticate" '^trunc: .*failed to authenticate\.$' 'trunc:'
empty "and nothing of it is written" dec.trunc
if has '^short: \.$'; then bad "a file of 40 bytes was decrypted"; else ok "a file of 40 bytes is refused"; fi
empty "and nothing is written" dec.short
check "another key fails to authenticate" '^wrongpw: .*failed to authenticate\.$' 'wrongpw:'
empty "and nothing is written" dec.wrongpw

if has '^forged: \.$'; then
	bad "a header-less file made without the key was decrypted with success: $(tr -c ' -~' '.' < "$DIR/dec.forged" | cut -c1-80)"
else
	ok "a header-less file made without the key from a file with the header is refused"
fi
check "saying that it has no header and that -c reads the old format" 'aescbc: .*header.*-c' 'aescbc:'
empty "and nothing of it is written" dec.forged
if has '^forgedpipe: .*|\.$' || has '^forgedpipe: \.$'; then bad "the same through a pipe was decrypted"; else ok "the same through a pipe"; fi
empty "and nothing of it is written" dec.forgedpipe

if [ $havelegacy = 1 ]; then
	if has '^legacy: \.$'; then bad "a file in the old format was read without -c"; else ok "a file in the old format is refused without -c"; fi
	empty "and nothing of it is written" dec.legacy
	check "and read with -c" '^legacy-c: \.$' 'legacy-c:'
	cmp -s "$DIR/plain.legacy" "$DIR/dec.legacyc" && ok "to what was encrypted" || bad "the old format's file differs decrypted"
	check "and through a pipe" '^legacypipe-c: \.$' 'legacypipe-c:'
	cmp -s "$DIR/plain.legacy" "$DIR/dec.legacypipe" && ok "to the same" || bad "the old format through a pipe differs"
	check "one cut short fails its check" '^legacycut-c: .*failed to authenticate\.$' 'legacycut-c:'
	empty "and nothing of it is written" dec.legacycut
	check "as does another key" '^legacywrong-c: .*failed to authenticate\.$' 'legacywrong-c:'
	empty "and nothing is written" dec.legacywrong
else
	echo "SKIP: no Python cryptography: the old format's own files were not made"
fi

exit $rc
