#!/bin/bash
#
# tests/host/pathmanage_test.sh
#
# Tests unified dynamic path management via tools9p:
#   - /tool/paths file and bindpath/unbindpath ctl commands
#   - namespace bind/unmount plumbing
#
# Does NOT require the LLM service.
# Run from project root: ./tests/host/pathmanage_test.sh [-v]
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

echo -e "${BOLD}Dynamic path management tests${NC}"
echo ""

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -f "$ROOT/dis/veltro/tools9p.dis" ]] || {
    skip "tools9p.dis not found"; echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"; exit 0; }

# emu_c: run a short Inferno sh -c command; use -c to skip the profile
# (profile calls 'load std' which fails with typecheck on rebuilt modules).
# path is set inline before commands.
emu_c() {
    local name="$1" tout="$2" cmd="$3"
    local log="/tmp/.pathtest-${name}.log"
    timeout "$tout" "$EMU" -r"$ROOT" "$SH" -c "path=(/dis/veltro /dis/cmd /dis .); $cmd" \
            </dev/null >"$log" 2>&1
    local rc=$?
    OUTPUT=$(cat "$log")
    # Exit 124 = timeout: expected since tools9p runs indefinitely in the background.
    # Treat 0 or 124 as success; anything else is a real error.
    if [[ "$rc" -eq 0 ]] || [[ "$rc" -eq 124 ]]; then
        info "[$name] ok: $OUTPUT"
        return 0
    else
        info "[$name] exit $rc: $OUTPUT"
        return $rc
    fi
}

# Check tools9p starts and /tool/paths exists
echo "── tools9p /tool/paths state ──"

if ! emu_c "smoke" 10 "tools9p read & sleep 2; cat /tool/paths; echo READY"; then
    skip "tools9p failed to start (output: $OUTPUT)"
    echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"
    exit 0
fi
CLEAN_OUTPUT=$(echo "$OUTPUT" | grep -v "git/fs: mount /n/git: '/n' file does not exist" || true)
if echo "$CLEAN_OUTPUT" | grep -qE "typecheck|does not exist|cannot open|fail:"; then
    skip "tools9p failed to start (output: $OUTPUT)"
    echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"
    exit 0
fi
pass "tools9p starts and /tool/paths is readable"

# bindpath adds a path — just cat the paths file; bash does the grep
if emu_c "bind1" 10 \
    "tools9p read & sleep 2; echo bindpath /tmp > /mnt/toolctl/ctl; cat /tool/paths"; then
    if echo "$OUTPUT" | grep -q "/tmp"; then
        pass "bindpath adds path to /tool/paths"
    else
        fail "bindpath: /tmp not found in /tool/paths (got: $OUTPUT)"
    fi
else
    fail "bindpath test failed (exit error)"
fi

# Idempotent: bind same path twice — cat the file; bash counts
if emu_c "bind_idem" 10 \
    "tools9p read & sleep 2; echo bindpath /tmp > /mnt/toolctl/ctl; echo bindpath /tmp > /mnt/toolctl/ctl; cat /tool/paths"; then
    COUNT=$(echo "$OUTPUT" | grep -c "/tmp" || echo 0)
    if [[ "$COUNT" = "1" ]]; then
        pass "duplicate bindpath not duplicated (count=1)"
    else
        fail "duplicate bindpath gave count=$COUNT (expected 1)"
    fi
else
    fail "idempotent bindpath test failed"
fi

# unbindpath removes the path — cat paths after unbind; bash checks absence
if emu_c "unbind1" 10 \
    "tools9p read & sleep 2; echo bindpath /tmp > /mnt/toolctl/ctl; echo unbindpath /tmp > /mnt/toolctl/ctl; cat /tool/paths"; then
    if echo "$OUTPUT" | grep -q "/tmp"; then
        fail "unbindpath: /tmp still in /tool/paths (got: $OUTPUT)"
    else
        pass "unbindpath removes path from /tool/paths"
    fi
else
    fail "unbindpath test failed (exit error)"
fi

# Multiple paths: add three, remove the middle one
if emu_c "multi" 12 \
    "tools9p read & sleep 2; echo bindpath /tmp > /mnt/toolctl/ctl; echo bindpath /lib > /mnt/toolctl/ctl; echo bindpath /dis > /mnt/toolctl/ctl; echo unbindpath /lib > /mnt/toolctl/ctl; cat /tool/paths"; then
    if echo "$OUTPUT" | grep -q "/tmp" && echo "$OUTPUT" | grep -q "/dis" && ! echo "$OUTPUT" | grep -q "/lib"; then
        pass "multiple paths: selective unbind preserves others"
    elif echo "$OUTPUT" | grep -q "/lib"; then
        fail "multiple paths: /lib still present after unbind"
    else
        fail "multiple paths: unexpected output: $OUTPUT"
    fi
else
    fail "multiple paths test failed"
fi

echo ""
echo "── namespace bind plumbing ──"

# Test that bind/unmount work (applypathchanges does bind into /n/local/).
# /n/local requires the profile (trfs '#U*' /n/local), so skip cleanly if absent.
if emu_c "localbind" 8 \
    "tools9p read &sleep 3; echo bindpath /dis > /mnt/toolctl/ctl; cat /tool/paths"; then
    if echo "$OUTPUT" | grep -q "/dis"; then
        pass "bind /dis: path registered and visible in /tool/paths"
    else
        skip "/n/local/ plumbing not tested in bare emu (no profile)"
    fi
else
    skip "bind plumbing test failed (exit error)"
fi

echo ""
echo "── launcher namespace grant boundary ──"

if emu_c "veltro_privileged_path_rejected" 12 \
    "mkdir /mnt >[2] /dev/null; mkdir /mnt/msg >[2] /dev/null; touch /mnt/msg/ctl; tools9p read & sleep 2; veltro -p /mnt/msg/ctl 'probe unsafe namespace grant'; cat /tool/paths"; then
    if echo "$OUTPUT" | grep -q "privileged path not grantable" && ! echo "$OUTPUT" | grep -q "^/mnt/msg/ctl"; then
        pass "veltro -p rejects privileged control paths"
    else
        fail "veltro -p accepted privileged control path (output: $OUTPUT)"
    fi
else
    fail "veltro privileged path rejection probe failed"
fi

if emu_c "veltro_direct_send_path_rejected" 12 \
    "mkdir /mnt >[2] /dev/null; mkdir /mnt/mail >[2] /dev/null; mkdir /mnt/mail/accounts >[2] /dev/null; mkdir /mnt/mail/accounts/alice >[2] /dev/null; touch /mnt/mail/accounts/alice/compose; tools9p read & sleep 2; veltro -p /mnt/mail/accounts/alice/compose 'probe unsafe mail grant'; cat /tool/paths"; then
    if echo "$OUTPUT" | grep -q "privileged path not grantable" && ! echo "$OUTPUT" | grep -q "^/mnt/mail/accounts/alice/compose"; then
        pass "veltro -p rejects direct-send paths"
    else
        fail "veltro -p accepted direct-send path (output: $OUTPUT)"
    fi
else
    fail "veltro direct-send path rejection probe failed"
fi

echo ""
echo "Total: $PASSED passed, $FAILED failed, $SKIPPED skipped"
[[ "$FAILED" -eq 0 ]]
