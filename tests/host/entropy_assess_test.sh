#!/bin/bash
#
# tests/host/entropy_assess_test.sh - tools/entropy/assess.py, the SP
# 800-90B assessment of a board's generator (docs/ENTROPY-ASSESSMENT.md),
# told sources it must pass from ones it must fail: the host's generator
# passes (non-IID, IID and restart tests); a source of three random bits
# a byte, a thousand boots that begin alike, and one stream given as two
# boards, and a short sample each FAIL with their reason. The board's
# records of power and heat (rngboot.log, rngdump's lines) are reported
# clean when clean, and one boot's under-voltage beside the verdict. An
# assessment that cannot fail a bad source says nothing of a good one.
#
# Builds NIST's tools (tools/entropy/build-nist.sh) or takes NIST_EA_DIR;
# skips when they cannot be had. No emulator needed. About five minutes.
#
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
PASSED=0; FAILED=0
pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

NIST="${NIST_EA_DIR:-}"
if [[ -z "$NIST" ]]; then
    NIST="$(ROOT="$ROOT" "$ROOT/tools/entropy/build-nist.sh" 2>/dev/null | tail -1)"
fi
if [[ -z "$NIST" || ! -x "$NIST/ea_non_iid" ]]; then
    echo "SKIP: NIST's SP 800-90B tools cannot be built here (see tools/entropy/build-nist.sh)"
    exit 0
fi

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
python3 - "$T" <<'PY'
import os, sys
t = sys.argv[1]
open(t+"/good.bin", "wb").write(os.urandom(1000000))
open(t+"/good2.bin", "wb").write(os.urandom(1000000))
open(t+"/boots.bin", "wb").write(os.urandom(4096*1000))
open(t+"/biased.bin", "wb").write(bytes(b & 7 for b in os.urandom(1000000)))
b = os.urandom(4096)
open(t+"/sameboots.bin", "wb").write(b*1000)
for i in range(1, 1001):
    open(t+"/clean.log", "a").write("boot %d throttled=0x00000 ok cputemp=50.%d\n" % (i, i % 10))
    w = "0x10000 under-voltage-since-boot" if i == 500 else "0x00000 ok"
    open(t+"/sag.log", "a").write("boot %d throttled=%s cputemp=55.0\n" % (i, w))
open(t+"/dumps.txt", "w").write("src=/dev/hwrandom bytes=1000000 throttled0=0x00000 cputemp0=48.1 throttled1=0x00000 cputemp1=49.0\n" * 2)
PY
cp "$T/good.bin" "$T/copy.bin"
head -c 500000 "$T/good.bin" > "$T/short.bin"

A="python3 $ROOT/tools/entropy/assess.py -n $NIST"

out="$($A -b "$T/boots.bin" -l "$T/clean.log" -d "$T/dumps.txt" "$T/good.bin" "$T/good2.bin" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "^VERDICT: PASS" <<<"$out" && grep -q "restart test at H_I .*: passed" <<<"$out" \
   && grep -q "IID tests: passed" <<<"$out"; then
    pass "the host's generator passes: non-IID, IID and restart, two files apart"
else
    fail "the host's generator did not pass (exit $rc)"; echo "$out" | tail -20
fi

expectfail() {	# expectfail <what> <reason in the output> <args>
    local what="$1" why="$2"; shift 2
    out="$($A "$@" 2>&1)"; rc=$?
    if [[ $rc -eq 1 ]] && grep -q "^VERDICT: FAIL" <<<"$out" && grep -qF -- "$why" <<<"$out"; then
        pass "$what fails: $why"
    else
        fail "$what did not fail with '$why' (exit $rc)"; echo "$out" | tail -20
    fi
}
if grep -q "^CONDITIONS: clean" <<<"$out" && grep -q "conditions (boots): 1000 records, no under-voltage" <<<"$out"; then
    pass "a clean board's records of power and heat are reported clean"
else
    fail "clean conditions not reported"; grep -i condition <<<"$out"
fi

out="$($A -b "$T/boots.bin" -l "$T/sag.log" "$T/good.bin" 2>&1)"; rc=$?
if [[ $rc -eq 0 ]] && grep -q "^CONDITIONS: .*under-voltage in 1 of 1000" <<<"$out" && grep -q "captures: no record" <<<"$out"; then
    pass "one boot's under-voltage is reported beside a verdict on the bytes, and an unrecorded capture said"
else
    fail "under-voltage not reported (exit $rc)"; grep -i "condition\|verdict" <<<"$out"
fi

expectfail "three random bits a byte" "less than the 4.0 the kernel assumes" "$T/biased.bin"
expectfail "a thousand boots alike" "SP 800-90B's restart test failed" -b "$T/sameboots.bin" "$T/good.bin"
expectfail "a thousand boots alike" "boots begin with another boot's first 32 bytes" -b "$T/sameboots.bin" "$T/good.bin"
expectfail "one stream as two boards" "a 32-byte block of one file is in another" "$T/good.bin" "$T/copy.bin"
expectfail "a short sample" "90B asks for at least 1000000" "$T/short.bin"

echo ""
echo "Passed: $PASSED  Failed: $FAILED"
[[ $FAILED -eq 0 ]]
