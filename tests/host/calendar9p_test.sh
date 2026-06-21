#!/bin/bash
#
# tests/host/calendar9p_test.sh
#
# Integration tests for calendar9p (INFR-9) — the 9P-shape scaffold.
#
# Covers what the scaffold actually does without CalDAV wiring:
#   - mount /mnt/cal succeeds
#   - root listing contains ctl + accounts
#   - connect <name> <url> adds an account
#   - duplicate connect is rejected
#   - /accounts/<name>/{ctl,calendars} appear
#   - /accounts/<name>/ctl reads "disconnected <url>"
#   - calendars/ is empty (next-pass content)
#   - account-ctl verbs (select / search) accept arguments
#   - disconnect removes the account
#   - unknown ctl verbs are rejected (verified by side-effect since
#     Inferno sh swallows write errors from `echo`)
#
# Run from project root: ./tests/host/calendar9p_test.sh [-v]
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
SH="/dis/sh.dis"
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

pass()  { local msg="$1"; echo -e "${GREEN}PASS${NC}: $msg"; PASSED=$((PASSED+1)); return 0; }
fail()  { local msg="$1"; echo -e "${RED}FAIL${NC}: $msg"; FAILED=$((FAILED+1)); return 0; }
skip()  { local msg="$1"; echo -e "${YELLOW}SKIP${NC}: $msg"; SKIPPED=$((SKIPPED+1)); return 0; }
info()  { local msg="$1"; [[ "$VERBOSE" -eq 1 ]] && echo "  $msg" || true; return 0; }

echo -e "${BOLD}calendar9p integration tests${NC}"
echo ""

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -f "$ROOT/dis/calendar9p.dis" ]] || {
    skip "calendar9p.dis not found — build calendar9p first";
    echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped";
    exit 0; }

emu_c() {
    local name="$1" tout="$2" cmd="$3"
    local log="/tmp/.calendar9p-test-${name}.log"
    timeout "$tout" "$EMU" -r"$ROOT" "$SH" -c "path=(/dis /dis/cmd .); $cmd" \
            </dev/null >"$log" 2>&1
    local rc=$?
    OUTPUT=$(cat "$log")
    if [[ "$rc" -eq 0 ]] || [[ "$rc" -eq 124 ]]; then
        info "[$name] rc=$rc: $OUTPUT"
        return 0
    else
        info "[$name] error rc=$rc: $OUTPUT"
        return 1
    fi
}

# Run the whole exercise in one emu instance — the scaffold's state is
# per-process, so cycling emu per test would lose connects between
# steps. Each test below is a grep on a single combined transcript.
TRANSCRIPT_LOG="/tmp/.calendar9p-test-transcript.log"
emu_c transcript 30 "
mount -ac {mntgen} /mnt
calendar9p &
sleep 1

echo '<<< 01 root-listing >>>'
ls /mnt/cal

echo '<<< 02 ctl-read-empty >>>'
cat /mnt/cal/ctl

echo '<<< 03 connect >>>'
echo connect alice https://caldav.example.com > /mnt/cal/ctl

echo '<<< 04 accounts-after-connect >>>'
ls /mnt/cal/accounts

echo '<<< 05 account-dir >>>'
ls /mnt/cal/accounts/alice

echo '<<< 06 account-ctl-read >>>'
cat /mnt/cal/accounts/alice/ctl

echo '<<< 07 calendars-empty >>>'
ls /mnt/cal/accounts/alice/calendars

echo '<<< 08 connect-duplicate-state >>>'
# Attempt duplicate connect; then read acct ctl to verify the original
# url string still wins (the second connect was rejected so alice
# still points at caldav.example.com, not caldav2.example.com).
echo connect alice https://caldav2.example.com > /mnt/cal/ctl >[2] /dev/null
cat /mnt/cal/accounts/alice/ctl

echo '<<< 09 connect-missing-url-state >>>'
# echo without url arg; account 'bob' must NOT appear under /accounts.
echo connect bob > /mnt/cal/ctl >[2] /dev/null
ls /mnt/cal/accounts

echo '<<< 10 unknown-verb-state >>>'
# Unknown verb; account list must be unchanged (still just alice).
echo nonsense > /mnt/cal/ctl >[2] /dev/null
ls /mnt/cal/accounts

echo '<<< 11 acctctl-select >>>'
echo select default > /mnt/cal/accounts/alice/ctl

echo '<<< 12 acctctl-search >>>'
echo search 2026-01-01/2026-12-31 > /mnt/cal/accounts/alice/ctl

echo '<<< 13 acctctl-unknown-state >>>'
# Acct-ctl unknown verb; following acct ctl read must still succeed
# (server didn't crash) and report alice's original url.
echo nonsense > /mnt/cal/accounts/alice/ctl >[2] /dev/null
cat /mnt/cal/accounts/alice/ctl

echo '<<< 14 second-account >>>'
echo connect bob https://caldav.bob.com > /mnt/cal/ctl
ls /mnt/cal/accounts

echo '<<< 15 disconnect-first >>>'
echo disconnect alice > /mnt/cal/ctl
ls /mnt/cal/accounts

echo '<<< 16 disconnect-missing-state >>>'
# Disconnect nonexistent; remaining accounts must be unchanged (still bob).
echo disconnect nosuch > /mnt/cal/ctl >[2] /dev/null
ls /mnt/cal/accounts

echo '<<< 17 sync-existing >>>'
echo sync bob > /mnt/cal/ctl

echo '<<< 18 sync-missing-state >>>'
# Sync nonexistent; bob's account must remain readable (server alive).
echo sync nosuch > /mnt/cal/ctl >[2] /dev/null
cat /mnt/cal/accounts/bob/ctl

echo '<<< end >>>'
" || true

cp "/tmp/.calendar9p-test-transcript.log" "$TRANSCRIPT_LOG" 2>/dev/null || true

# Slice the transcript between markers. Markers look like
#   <<< 01 root-listing >>>
# slice 01  returns the lines between that and the next "<<< " line.
slice() {
    awk -v num="$1" '
        $0 ~ ("<<< " num " ") { capture = 1; next }
        capture && /<<< / { exit }
        capture { print }
    ' "$TRANSCRIPT_LOG"
}

# === Test 1: root listing ===
out=$(slice 01)
if echo "$out" | grep -q ctl && echo "$out" | grep -q accounts; then
    pass "01 root listing contains ctl and accounts"
else
    fail "01 root listing missing ctl or accounts"
    info "$out"
fi

# === Test 2: ctl reads as empty (write-only file, read returns 0 bytes) ===
out=$(slice 02)
# The cat itself produces no output; the marker is a single blank line.
nbytes=$(echo -n "$out" | wc -c)
if [[ "$nbytes" -le 1 ]]; then
    pass "02 /ctl reads empty (write-only semantics)"
else
    fail "02 /ctl read returned non-empty: $out"
fi

# === Test 3: connect verb (no error printed in stderr) ===
out=$(slice 03)
if [[ -z "$out" ]]; then
    pass "03 connect alice https://caldav.example.com — no error"
else
    fail "03 connect produced unexpected output: $out"
fi

# === Test 4: accounts dir lists alice ===
out=$(slice 04)
if echo "$out" | grep -q alice; then
    pass "04 account 'alice' visible under /accounts"
else
    fail "04 alice not listed under /accounts: $out"
fi

# === Test 5: account dir contains ctl and calendars ===
out=$(slice 05)
if echo "$out" | grep -q ctl && echo "$out" | grep -q calendars; then
    pass "05 /accounts/alice contains ctl and calendars"
else
    fail "05 /accounts/alice missing ctl or calendars: $out"
fi

# === Test 6: account ctl reads "disconnected <url>" ===
out=$(slice 06)
if echo "$out" | grep -q "disconnected https://caldav.example.com"; then
    pass "06 account ctl reports 'disconnected https://caldav.example.com'"
else
    fail "06 account ctl unexpected output: $out"
fi

# === Test 7: calendars dir is empty (scaffold doesn't populate yet) ===
out=$(slice 07)
nbytes=$(echo -n "$out" | wc -c)
if [[ "$nbytes" -le 1 ]]; then
    pass "07 /accounts/alice/calendars is empty (next-pass populates)"
else
    fail "07 calendars dir unexpectedly non-empty: $out"
fi

# === Test 8: duplicate connect — original url string preserved ===
out=$(slice 08)
if echo "$out" | grep -q "disconnected https://caldav.example.com" \
        && ! echo "$out" | grep -q "caldav2"; then
    pass "08 duplicate connect rejected (alice still points to original url)"
else
    fail "08 duplicate connect should be rejected; got: $out"
fi

# === Test 9: missing-url connect — bob must not appear ===
out=$(slice 09)
if ! echo "$out" | grep -q bob; then
    pass "09 connect without url arg rejected (no 'bob' account created)"
else
    fail "09 connect without url arg should not create account: $out"
fi

# === Test 10: unknown verb — accounts unchanged (still alice only) ===
out=$(slice 10)
if echo "$out" | grep -q alice && ! echo "$out" | grep -q bob; then
    pass "10 unknown ctl verb rejected (state unchanged)"
else
    fail "10 unknown ctl verb should not change state: $out"
fi

# === Test 11: account-ctl select accepts arg (no error) ===
out=$(slice 11)
if [[ -z "$out" ]]; then
    pass "11 acct ctl 'select default' accepted"
else
    fail "11 acct ctl select produced output: $out"
fi

# === Test 12: account-ctl search accepts arg ===
out=$(slice 12)
if [[ -z "$out" ]]; then
    pass "12 acct ctl 'search <range>' accepted"
else
    fail "12 acct ctl search produced output: $out"
fi

# === Test 13: account-ctl unknown verb — server still responsive ===
out=$(slice 13)
if echo "$out" | grep -q "disconnected https://caldav.example.com"; then
    pass "13 acct ctl unknown verb rejected (server still responsive after)"
else
    fail "13 acct ctl unknown verb broke server: $out"
fi

# === Test 14: second account coexists ===
out=$(slice 14)
if echo "$out" | grep -q alice && echo "$out" | grep -q bob; then
    pass "14 second account 'bob' coexists with alice"
else
    fail "14 expected both alice and bob: $out"
fi

# === Test 15: disconnect removes account ===
out=$(slice 15)
if ! echo "$out" | grep -q alice && echo "$out" | grep -q bob; then
    pass "15 disconnect alice removes only alice, bob remains"
else
    fail "15 disconnect did not remove alice cleanly: $out"
fi

# === Test 16: disconnect of nonexistent account — accounts unchanged ===
out=$(slice 16)
if echo "$out" | grep -q bob && ! echo "$out" | grep -q nosuch; then
    pass "16 disconnect of nonexistent account rejected (bob still present)"
else
    fail "16 disconnect nosuch should not change state: $out"
fi

# === Test 17: sync existing account ok ===
out=$(slice 17)
if [[ -z "$out" ]]; then
    pass "17 sync bob accepted (stub — CalDAV-pass implements)"
else
    fail "17 sync produced unexpected output: $out"
fi

# === Test 18: sync of nonexistent — server alive, bob's ctl readable ===
out=$(slice 18)
if echo "$out" | grep -q "disconnected https://caldav.bob.com"; then
    pass "18 sync of nonexistent account rejected (bob still readable after)"
else
    fail "18 sync nosuch broke server: $out"
fi

echo ""
echo -e "Total: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}, ${YELLOW}$SKIPPED skipped${NC}"

# Clean up
rm -f "$TRANSCRIPT_LOG" /tmp/.calendar9p-test-*.log 2>/dev/null

if [[ "$FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
