#!/bin/sh
# The Pi's Wi-Fi radio is a computer of its own, and what its firmware
# sends up is its word.  A control response's command header is where the
# response's own header says only if that much was received; a response is
# a command's answer only if it carries that command's id, which is 16 bits
# on the wire and in the driver; a file named as firmware is uploaded only
# as far as the radio's RAM goes.
#
# rspcmdoff and fwfits are extracted from os/bcm/ether4330.c and run; the
# rest is checked in the source.  No emulator has this radio.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/bcm/ether4330.c
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$SRCFILE" ] || { echo "ERROR: $SRCFILE not found" >&2; exit 1; }
CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

{ echo 'static int'; awk '/^fwfits\(/,/^}/' "$SRCFILE"
  echo 'static int'; awk '/^rspcmdoff\(/,/^}/' "$SRCFILE"; } > "$BUILD/fw.inc"
{ awk '/^struct Sdpcm$/,/^};/' "$SRCFILE"; awk '/^struct Cmd$/,/^};/' "$SRCFILE"; } > "$BUILD/wire.inc"

if grep -q 'fwfits' "$BUILD/fw.inc" && grep -q 'rspcmdoff' "$BUILD/fw.inc"; then
	cat > "$BUILD/test.c" <<'EOF'
#include <stdio.h>
typedef unsigned char uchar;
typedef unsigned int u32int;
typedef unsigned long long uvlong;
typedef struct Sdpcm Sdpcm;
typedef struct Cmd Cmd;
#include "wire.inc"
#include "fw.inc"
int
main(void)
{
	long blen, need;
	int doff, bad = 0, got, want;
	enum { H = sizeof(Sdpcm), C = sizeof(Cmd) };

	if(H != 12 || C != 16){ printf("  wire structures are %d and %d bytes\n", (int)H, (int)C); bad++; }

	/* every block length, every offset a byte can hold, several answers */
	for(blen = 0; blen <= 2048; blen++)
	for(doff = 0; doff <= 255; doff++)
	for(need = 0; need <= 256; need += 127){
		got = rspcmdoff(blen, doff, need);
		want = (doff >= H && blen >= doff + C + need) ? doff : -1;
		if(got != want){ if(bad++ < 5) printf("  block %ld offset %d need %ld: %d\n", blen, doff, need, got); }
		/* whatever it returns, the Cmd and the answer lie inside the block */
		if(got >= 0 && got + C + need > blen){ if(bad++ < 5) printf("  past the block\n"); }
	}
	if(rspcmdoff(2048, 12, -1) != -1){ printf("  negative need accepted\n"); bad++; }

	/* firmware against a 512K dongle */
	{
		u32int ram = 512*1024;
		if(!fwfits(ram, 0, 2048) || !fwfits(ram, ram-2048, 2048) || fwfits(ram, ram-2047, 2048)
		|| fwfits(ram, ram, 4) || !fwfits(ram, ram, 0) || fwfits(ram, -4, 8) || fwfits(ram, 0, -1)
		|| fwfits(ram, 0x7FFFFFFF, 0x7FFFFFFF) || fwfits(0, 0, 4)){
			printf("  fwfits edges\n"); bad++;
		}
	}
	return bad != 0;
}
EOF
	if "$CC" -std=c99 -Wall -Wno-unused-function -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err" &&
	   "$BUILD/test" > "$BUILD/run.out" 2>&1; then
		pass "a response's command header and answer lie inside what was received; an upload inside the RAM"
	else
		fail "rspcmdoff/fwfits: $(cat "$BUILD/cc.err" "$BUILD/run.out" 2>/dev/null | head -4 | tr '\n' ' ')"
	fi
else
	fail "ether4330.c has no rspcmdoff/fwfits: the firmware's offsets and a file's length are taken as given"
fi

awk '/^wlcmd\(/,/^}/' "$SRCFILE" > "$BUILD/wlcmd.c"
awk '/^rproc\(/,/^}/' "$SRCFILE" > "$BUILD/rproc.c"
awk '/^upload\(/,/^}/' "$SRCFILE" > "$BUILD/upload.c"
awk '/^wlreadpkt\(/,/^}/' "$SRCFILE" > "$BUILD/readpkt.c"

# wlcmd checks the answer before it reads status or copies the result.
chk=$(grep -n 'rspcmdoff(BLEN(v.b), p->doffset, write? 0 : rlen)' "$BUILD/wlcmd.c" | head -1 | cut -d: -f1)
st=$(grep -n 'q->status\[0\]' "$BUILD/wlcmd.c" | head -1 | cut -d: -f1)
cp=$(grep -n 'memmove(res, q + 1, rlen)' "$BUILD/wlcmd.c" | head -1 | cut -d: -f1)
idc=$(grep -n '!= id)' "$BUILD/wlcmd.c" | head -1 | cut -d: -f1)
if [ -n "$chk" ] && [ -n "$st" ] && [ -n "$cp" ] && [ -n "$idc" ] && [ "$chk" -lt "$st" ] && [ "$idc" -lt "$cp" ]; then
	pass "wlcmd bounds the answer and matches its id before using it"
else
	fail "wlcmd reads the firmware's answer at an unchecked offset"
fi

# a parked answer is discarded before a command is sent, and replaced under a lock.
snd=$(grep -n 'packetrw(1, v.b->rp, len)' "$BUILD/wlcmd.c" | head -1 | cut -d: -f1)
dis=$(grep -n 'ctl->rsp = nil;' "$BUILD/wlcmd.c" | head -1 | cut -d: -f1)
if [ -n "$snd" ] && [ -n "$dis" ] && [ "$dis" -lt "$snd" ] &&
   grep -q 'lock(&ctl->rsplock)' "$BUILD/rproc.c" && grep -q 'freeb(ob)' "$BUILD/rproc.c"; then
	pass "a late or second answer is never taken for the next command's"
else
	fail "a late answer stays parked for the next command"
fi

# rproc finds the Cmd by the response's own offset, and the id is 16 bits both sides.
if grep -q 'rspcmdoff(BLEN(b), p->doffset, 0)' "$BUILD/rproc.c" &&
   grep -qE '^[[:space:]]*ushort[[:space:]]+reqid;' "$SRCFILE" &&
   ! grep -qE '^[[:space:]]*short[[:space:]]+reqid;' "$SRCFILE"; then
	pass "the request id is unsigned 16 bits, as on the wire"
else
	fail "the request id is a signed short: commands stop matching after 32767"
fi

# the NVRAM buffer has room for what condense appends; firmware is bounded by RAM.
if grep -q 'malloc(isconfig? Cfgmax+8 : Uploadsz)' "$BUILD/upload.c" &&
   [ "$(grep -c 'fwfits(ctl->socramsize, off,' "$BUILD/upload.c")" -eq 2 ]; then
	pass "upload leaves room for the NVRAM's terminators and stops at the end of RAM"
else
	fail "upload writes past its buffer or past the radio's RAM"
fi

# no wait on the radio is unbounded.
if ! grep -qE 'while\(cfgr\(Rfrmcnt(\+1)?\) > 0\)' "$BUILD/readpkt.c" &&
   [ "$(grep -c 'i < Sbpolls && cfgr(Rfrmcnt' "$BUILD/readpkt.c")" -eq 2 ]; then
	pass "wlreadpkt's drains after a bad header are bounded"
else
	fail "wlreadpkt spins without bound after a bad header"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
