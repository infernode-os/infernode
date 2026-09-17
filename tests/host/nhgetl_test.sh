#!/bin/bash
#
# tests/host/nhgetl_test.sh
#
# Guard the byte-order accessors in emu/port/ipaux.c against LP64
# sign extension.
#
# nhgetl() returns ulong, which is 64 bits on every platform InferNode
# targets. If the per-byte shifts are written without casts, a[0]
# promotes to int, a[0]<<24 sets the int sign bit for any first byte
# >= 0x80, and converting that negative int to a 64-bit ulong sign
# extends it. nhgetl("192.168.1.1") then yields 0xFFFFFFFFC0A80101.
#
# Why this is worth a test rather than a comment: today the bug is
# LATENT. emu has no IP stack of its own -- ipif-posix.c hands everything
# to host sockets -- and the only in-tree consumers compare the result
# against 0, which sign extension does not affect. So nothing visibly
# breaks, and nothing would notice it being reintroduced.
#
# It stops being latent as soon as a real stack is linked in. Upstream
# Inferno's os/ip computes route ranges as (start | ~mask) and compares
# TCP sequence numbers; with sign-extended inputs both silently produce
# WRONG ANSWERS rather than failing. Silent mis-routing is the worst way
# for this to surface, so the guard goes in before the stack does.
#
# The test extracts the real function text from the real source file and
# compiles it, so it tracks what is actually in the tree rather than a
# copy that could drift.
#
# Run from project root: ./tests/host/nhgetl_test.sh [-v]
#

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SRCFILE="$ROOT/emu/port/ipaux.c"
VERBOSE=0

while getopts "v" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        *) echo "Usage: $0 [-v]"; exit 1 ;;
    esac
done

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
    BOLD='\033[1m'; NC='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; NC=''
fi

PASSED=0; FAILED=0; SKIPPED=0
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); return 0; }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); return 0; }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED+1)); return 0; }
info() { [[ "$VERBOSE" -eq 1 ]] && echo "  $1" || true; return 0; }

echo -e "${BOLD}Byte-order accessor tests (LP64 sign extension)${NC}"
echo ""

[[ -f "$SRCFILE" ]] || { echo "ERROR: $SRCFILE not found" >&2; exit 1; }

CC="$(command -v cc 2>/dev/null || command -v clang 2>/dev/null || command -v gcc 2>/dev/null)"
if [[ -z "$CC" ]]; then
    skip "no C compiler available"
    echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 0
fi

BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# Pull the real nhgetl/nhgets/hnputl/hnputs definitions out of ipaux.c.
python3 - "$SRCFILE" "$BUILD/extracted.c" <<'PYEOF'
import re, sys
src, out = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8", errors="replace").read()

wanted = ["nhgetl", "nhgets", "hnputl", "hnputs"]
found = {}
for name in wanted:
    # match "<rettype>\n<name>(args)\n{ ... }" at top level
    m = re.search(r"\n([A-Za-z_][\w \t\*]*)\n" + name + r"\s*\(([^)]*)\)\s*\n\{(.*?)\n\}",
                  text, re.S)
    if m:
        found[name] = "%s\n%s(%s)\n{%s\n}\n" % (m.group(1), name, m.group(2), m.group(3))

if "nhgetl" not in found:
    sys.stderr.write("could not extract nhgetl from %s\n" % src)
    sys.exit(2)

with open(out, "w") as f:
    f.write("typedef unsigned long ulong;\n")
    f.write("typedef unsigned char uchar;\n")
    f.write("typedef unsigned short ushort;\n\n")
    for name in wanted:
        if name in found:
            f.write(found[name] + "\n")
sys.stderr.write("extracted: %s\n" % " ".join(sorted(found)))
PYEOF
rc=$?
if [[ $rc -ne 0 ]]; then
    fail "could not extract byte-order accessors from ipaux.c"
    echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 1
fi
info "extracted: $(python3 -c "pass" 2>/dev/null; true)"

cat > "$BUILD/main.c" <<'EOF'
#include <stdio.h>
typedef unsigned long ulong;
typedef unsigned char uchar;
typedef unsigned short ushort;
ulong nhgetl(void*);
unsigned short nhgets(void*);

static int bad = 0;

static void
chk(const char *what, unsigned char *b, ulong want)
{
	ulong got = nhgetl(b);
	if(got != want){
		printf("  MISMATCH %-24s got=0x%016lx want=0x%016lx\n", what, got, want);
		bad++;
	} else
		printf("  ok       %-24s 0x%016lx\n", what, got);
}

int
main(void)
{
	unsigned char a[4];

	if(sizeof(ulong) != 8){
		printf("  not LP64 (sizeof(ulong)=%zu) -- nothing to prove\n", sizeof(ulong));
		return 0;
	}

	a[0]=10;  a[1]=0;   a[2]=0;   a[3]=1;   chk("10.0.0.1",          a, 0x0A000001UL);
	a[0]=192; a[1]=168; a[2]=1;   a[3]=1;   chk("192.168.1.1",       a, 0xC0A80101UL);
	a[0]=255; a[1]=255; a[2]=255; a[3]=0;   chk("mask 255.255.255.0",a, 0xFFFFFF00UL);
	a[0]=224; a[1]=0;   a[2]=0;   a[3]=1;   chk("multicast 224.0.0.1",a,0xE0000001UL);
	a[0]=0x80;a[1]=0;   a[2]=0;   a[3]=0;   chk("tcp seq 0x80000000",a, 0x80000000UL);
	a[0]=255; a[1]=255; a[2]=255; a[3]=255; chk("255.255.255.255",   a, 0xFFFFFFFFUL);

	/* nhgets returns ushort so it cannot sign extend, but check anyway */
	a[0]=0xFF; a[1]=0xFF;
	if(nhgets(a) != 0xFFFF){
		printf("  MISMATCH nhgets 0xFFFF got=0x%x\n", nhgets(a));
		bad++;
	} else
		printf("  ok       nhgets 0xFFFF\n");

	return bad ? 1 : 0;
}
EOF

if ! "$CC" -O2 -o "$BUILD/t" "$BUILD/extracted.c" "$BUILD/main.c" 2>"$BUILD/cc.log"; then
    fail "extracted accessors did not compile"
    [[ "$VERBOSE" -eq 1 ]] && cat "$BUILD/cc.log"
    echo ""; echo "Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED"; exit 1
fi
pass "byte-order accessors compile"

OUT="$("$BUILD/t")"; rc=$?
info "$OUT"
if [[ $rc -eq 0 ]]; then
    pass "nhgetl does not sign-extend on LP64 (all high-bit cases correct)"
else
    fail "nhgetl sign-extends high-bit values"
    echo "$OUT" | grep MISMATCH
fi

echo ""
echo -e "${BOLD}Passed: $PASSED  Failed: $FAILED  Skipped: $SKIPPED${NC}"
[[ "$FAILED" -eq 0 ]] || exit 1
exit 0
