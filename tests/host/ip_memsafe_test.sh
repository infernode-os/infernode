#!/bin/bash
# Focused regressions for IP memory-safety invariants found in the 2026-11-13 review.

set -u

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
IPAUX="$ROOT/os/ip/ipaux.c"
IPIFC="$ROOT/os/ip/ipifc.c"
TCP="$ROOT/os/ip/tcp.c"

PASSED=0
FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1" >&2; FAILED=$((FAILED+1)); }

CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null || true)"
if [[ -z "$CC" ]]; then
	echo "SKIP: no C compiler"
	exit 0
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# Compile the real parseip and v4parseip bodies with canaries around the
# destination.  The old dotted-tail path wrote bytes 16 and 17.
python3 - "$IPAUX" "$BUILD/ipparse.inc" <<'PYEOF'
import re, sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
with open(sys.argv[2], "w") as out:
    for name in ("v4parseip", "parseip"):
        match = re.search(
            r"\n((?:extern\s+)?[A-Za-z_][\w \t*]*)\n" + name +
            r"\s*\(([^)]*)\)\s*\n\{(.*?)\n\}", text, re.S)
        if not match:
            raise SystemExit("could not extract %s" % name)
        out.write("%s\n%s(%s)\n{%s\n}\n\n" %
                  (match.group(1), name, match.group(2), match.group(3)))
PYEOF

cat > "$BUILD/ipparse.c" <<'CEOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char uchar;
typedef unsigned long ulong;
enum { IPaddrlen = 16 };
#define CLASS(p) ((*(uchar*)(p))>>6)

static ulong
nhgetl(void *v)
{
	uchar *p = v;
	return ((ulong)p[0]<<24) | ((ulong)p[1]<<16) |
	       ((ulong)p[2]<<8) | p[3];
}

#include "ipparse.inc"

int
main(void)
{
	struct {
		uchar before[8];
		uchar ip[IPaddrlen];
		uchar after[8];
	} guarded;
	uchar want[4] = {1, 2, 3, 4};
	int bad = 0, i;

	memset(&guarded, 0xa5, sizeof guarded);
	parseip(guarded.ip, "1:2:3:4:5:6:7:8.8.8.8");
	for(i = 0; i < 8; i++)
		if(guarded.before[i] != 0xa5 || guarded.after[i] != 0xa5)
			bad = 1;
	if(bad)
		fprintf(stderr, "parseip overwrote a destination canary\n");

	parseip(guarded.ip, "::ffff:1.2.3.4");
	if(memcmp(guarded.ip+12, want, sizeof want) != 0){
		fprintf(stderr, "parseip rejected a valid dotted tail\n");
		bad = 1;
	}
	return bad;
}
CEOF

if "$CC" -O2 -I"$BUILD" -o "$BUILD/ipparse" "$BUILD/ipparse.c" &&
   "$BUILD/ipparse"; then
	pass "parseip keeps dotted IPv4 tails inside the 16-byte destination"
else
	fail "parseip dotted-tail bounds"
fi

# The deferred-free grace period must free entries whose deadline has passed,
# including across NOW's wrap.  Both lists use the same predicate.
if [[ "$(grep -Fc 'if((long)(now - np->expire) >= 0){' "$IPIFC")" -eq 2 ]]; then
	pass "ipifc deferred-free lists use an expired, wrap-safe deadline test"
else
	fail "ipifc deferred-free deadline predicate"
fi

# pullupblock may replace the first Block.  Each parser must refresh its typed
# header pointer after the second pullup and before deriving tcpopt.
if python3 - "$TCP" <<'PYEOF'
import re, sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
for fn, typ, size in (("ntohtcp4", "Tcp4hdr", "TCP4_PKT"),
                      ("ntohtcp6", "Tcp6hdr", "TCP6_PKT")):
    match = re.search(r"\n%s\([^)]*\)\s*\n\{(.*?)\n\}" % fn, text, re.S)
    if not match:
        raise SystemExit("missing %s" % fn)
    body = match.group(1)
    pull = body.find("pullupblock(*bpp, hdrlen+%s)" % size)
    refresh = body.find("h = (%s *)((*bpp)->rp);" % typ, pull)
    options = body.find("optr = h->tcpopt;", pull)
    if pull < 0 or refresh < 0 or options < 0 or not pull < refresh < options:
        raise SystemExit("%s uses a stale header after pullupblock" % fn)
PYEOF
then
	pass "TCP parsers refresh header pointers after pullupblock"
else
	fail "TCP parser pointer refresh"
fi

echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
