#!/bin/sh
# devip (os/ip/devip.c, and the hosted emulator's emu/port/devip.c):
# who may open the network database to change it, and what a ctl
# message's numbers may be.
#
# wantswrite and ctlnum are extracted from the source and run:
# every open mode that can write or truncate is one that asks to
# change the file (a test of the OWRITE bit missed ORDWR, which then
# wrote all the same); a port is 0 to 65535 and a byte 0 to 255, and
# what is not is refused rather than wrapped into some other number.
# By the order of the source, both kernels ask wantswrite before they
# let anyone but eve open the database, the local and remote port
# setters take a number only in range, and ttl and tos are bytes.

ROOT=${ROOT:-$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)}
SRCFILE=$ROOT/os/ip/devip.c
EMUFILE=$ROOT/emu/port/devip.c
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

if [ ! -f "$SRCFILE" ] || [ ! -f "$EMUFILE" ]; then
	echo "ERROR: $SRCFILE or $EMUFILE not found" >&2
	exit 1
fi
CC=$(command -v cc 2>/dev/null || command -v clang 2>/dev/null)
if [ -z "$CC" ]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT HUP INT TERM

{ echo 'static int'; awk '/^wantswrite\(/,/^}/' "$SRCFILE"; } > "$BUILD/k.inc"
{ echo 'static int'; awk '/^ctlnum\(/,/^}/' "$SRCFILE"; } >> "$BUILD/k.inc"
{ echo 'static int'; awk '/^wantswrite\(/,/^}/' "$EMUFILE" | sed 's/^wantswrite(/emuwantswrite(/'; } > "$BUILD/e.inc"
if ! grep -q '^wantswrite(' "$BUILD/k.inc" || ! grep -q '^ctlnum(' "$BUILD/k.inc" || ! grep -q '^emuwantswrite(' "$BUILD/e.inc"; then
	fail "devip.c has no wantswrite or ctlnum to run (kernel or emulator)"
	echo "Passed: $PASSED  Failed: $FAILED"
	exit 1
fi

cat > "$BUILD/test.c" <<'EOT'
#include <stdio.h>
#include <stdlib.h>
#define nil ((void*)0)
enum { OREAD = 0, OWRITE = 1, ORDWR = 2, OEXEC = 3, OTRUNC = 16, ORCLOSE = 64, OEXCL = 0x1000 };
#include "k.inc"
#include "e.inc"

static int bad;
static void
want(int got, int expect, const char *what, const char *arg)
{
	if(got != expect){
		printf("  %s(%s): got %d, want %d\n", what, arg, got, expect);
		bad++;
	}
}

int
main(void)
{
	static const int extra[] = {0, ORCLOSE, OEXCL, ORCLOSE|OEXCL};
	char name[40];
	int m, i, t, mode, expect;

	for(m = 0; m < 4; m++)
		for(t = 0; t <= OTRUNC; t += OTRUNC)
			for(i = 0; i < 4; i++){
				mode = m | t | extra[i];
				expect = m == OWRITE || m == ORDWR || t != 0;
				snprintf(name, sizeof name, "%#x", mode);
				want(wantswrite(mode), expect, "wantswrite", name);
				want(emuwantswrite(mode), expect, "the emulator's wantswrite", name);
			}

	want(ctlnum("0", 65535), 0, "ctlnum", "0");
	want(ctlnum("80", 65535), 80, "ctlnum", "80");
	want(ctlnum("65535", 65535), 65535, "ctlnum", "65535");
	want(ctlnum("65536", 65535), -1, "ctlnum", "65536");
	want(ctlnum("70000", 65535), -1, "ctlnum", "70000");
	want(ctlnum("-1", 65535), -1, "ctlnum", "-1");
	want(ctlnum("99999999999999999999", 65535), -1, "ctlnum", "a number past a long");
	want(ctlnum("", 65535), -1, "ctlnum", "nothing");
	want(ctlnum("*", 65535), -1, "ctlnum", "*");
	want(ctlnum(nil, 65535), -1, "ctlnum", "nil");
	want(ctlnum("564!r", 65535), 564, "ctlnum", "564!r");
	want(ctlnum("255", 255), 255, "ctlnum", "255");
	want(ctlnum("256", 255), -1, "ctlnum", "256 as a byte");
	return bad != 0;
}
EOT
if "$CC" -std=c99 -Wall -Wno-unused-function -I"$BUILD" -o "$BUILD/test" "$BUILD/test.c" 2> "$BUILD/cc.err" && "$BUILD/test" > "$BUILD/run.out" 2>&1; then
	pass "every open mode that writes or truncates is one that changes the file; ports and bytes are taken only in range"
else
	fail "devip predicates: $(cat "$BUILD/cc.err" "$BUILD/run.out" 2>/dev/null | head -6 | tr '\n' ' ')"
fi

# Both kernels ask before they let anyone but eve open the database to change it.
for f in "$SRCFILE" "$EMUFILE"; do
	awk '/^ipopen\(/,/^}/' "$f" > "$BUILD/open.c"
	if awk '/case Qndb:/,/break;/' "$BUILD/open.c" | grep -q 'if(wantswrite(omode) && !iseve())' &&
	   ! awk '/case Qndb:/,/break;/' "$BUILD/open.c" | grep -q 'omode & (OWRITE|OTRUNC)'; then
		pass "$(basename "$(dirname "$f")")/devip.c: only eve opens the network database to change it"
	else
		fail "$(basename "$(dirname "$f")")/devip.c lets an open for reading and writing past the check on the network database"
	fi
done

# Ports and bytes in ctl messages.
if awk '/^setladdrport\(/,/^}/' "$SRCFILE" | grep -q 'lport = ctlnum(p, 65535)' &&
   awk '/^setraddrport\(/,/^}/' "$SRCFILE" | grep -q 'ctlnum(p, 65535) < 0' &&
   ! awk '/^setladdrport\(/,/^}/;/^setraddrport\(/,/^}/' "$SRCFILE" | grep -q 'atoi('; then
	pass "a port in a connect, announce or bind is a number from 0 to 65535"
else
	fail "a port is read with atoi into 16 bits"
fi
if awk '/^ttlctlmsg\(/,/^}/' "$SRCFILE" | grep -q 'ctlnum(cb->f\[1\], 255) < 1' &&
   awk '/^tosctlmsg\(/,/^}/' "$SRCFILE" | grep -q 'ctlnum(cb->f\[1\], 255) < 0'; then
	pass "ttl is 1 to 255 and tos 0 to 255"
else
	fail "ttl or tos is whatever atoi made of the argument"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[ "$FAILED" -eq 0 ]
