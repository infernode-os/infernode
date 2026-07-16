#!/bin/bash
#
# Cross-surface namespace path policy checks.
#
# The privileged-path policy is enforced by several ingress points:
# nsconstruct (runtime namespace construction), tools9p startup/live path
# grants, and nsaudit's offline review. This test keeps a compact corpus of
# representative paths and verifies tools9p + nsaudit agree. Direct
# nsconstruct coverage lives in /tests/veltro_security_test.dis, run here too.
#
# Does NOT require the LLM service.
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

SH="/dis/sh.dis"

if [[ -t 1 ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'; BOLD='\033[1m'
else
    RED=''; GREEN=''; NC=''; BOLD=''
fi

PASSED=0; FAILED=0
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED+1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED+1)); }

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -f "$ROOT/dis/nsaudit.dis" ]] || { echo "SKIP: nsaudit.dis not found"; exit 77; }
[[ -f "$ROOT/dis/veltro/tools9p.dis" ]] || { echo "SKIP: tools9p.dis not found"; exit 77; }
[[ -f "$ROOT/dis/tests/veltro_security_test.dis" ]] || { echo "SKIP: veltro_security_test.dis not found"; exit 77; }

BAD_PRIV=(
  "/mnt/ui"
  "/mnt/ui/activity/0/presentation"
  "/mnt/msg/ctl"
  "/n/wallet/alice/ctl"
  "/tmp/veltro/ftree"
  "/tmp/veltro/.ns"
  "/tmp/veltro/cow"
  "/tmp/veltro/tasks"
  "/tmp/veltro/browser"
  "/tmp/veltro/editor"
  "/tmp/veltro/shell"
  "/tmp/veltro/fractal"
  "/tmp/veltro/man"
  "/mnt/matrix"
  "/phone"
)

BAD_DIRECT_SEND=(
  "/mnt/mail/accounts/alice/compose"
)

BAD_INVALID=(
  "/"
  "relative/path"
  "/tmp/../lib"
  "/tmp//evil"
  "/tmp/./evil"
)

GOOD=(
  "/tmp"
  "/tmp/veltro/scratch"
  "/mnt/msg"
  "/mnt/msg/draft"
)

emu_c() {
    local name="$1" tout="$2" cmd="$3"
    local log="/tmp/.nspath-policy-${name}.log"
    timeout "$tout" "$EMU" -r"$ROOT" "$SH" -c \
        "path=(/dis/veltro /dis/cmd /dis .); $cmd" \
        </dev/null >"$log" 2>&1
    local rc=$?
    OUTPUT="$(cat "$log")"
    emu_timeout_ok "$rc"
}

nsaudit_one() {
    local path="$1"
    emu_c "nsaudit-$(echo "$path" | tr -c 'A-Za-z0-9' '_')" 30 \
        "rm -rf /tmp/nspolicy; mkdir -p /tmp/nspolicy/meta; echo read > /tmp/nspolicy/tools; echo '$path' > /tmp/nspolicy/paths; echo toplevel > /tmp/nspolicy/meta/role; echo 0 > /tmp/nspolicy/meta/xenith; echo -1 > /tmp/nspolicy/meta/actid; echo set > /tmp/nspolicy/meta/nodevs; nsaudit -m /tmp/nspolicy"
}

echo -e "${BOLD}namespace path policy drift checks${NC}"

for p in "${BAD_PRIV[@]}"; do
    if nsaudit_one "$p" && echo "$OUTPUT" | grep -q "authority=privileged_control_path"; then
        pass "nsaudit flags privileged path $p"
    else
        fail "nsaudit missed privileged path $p (output: $OUTPUT)"
    fi
done

for p in "${BAD_DIRECT_SEND[@]}"; do
    if nsaudit_one "$p" && echo "$OUTPUT" | grep -q "authority=direct_mail_send"; then
        pass "nsaudit flags direct-send path $p"
    else
        fail "nsaudit missed direct-send path $p (output: $OUTPUT)"
    fi
done

for p in "${BAD_INVALID[@]}"; do
    if nsaudit_one "$p" && echo "$OUTPUT" | grep -q "authority=invalid_path_grant"; then
        pass "nsaudit flags invalid path $p"
    else
        fail "nsaudit missed invalid path $p (output: $OUTPUT)"
    fi
done

for p in "${GOOD[@]}"; do
    if nsaudit_one "$p" &&
       ! echo "$OUTPUT" | grep -q "authority=privileged_control_path" &&
       ! echo "$OUTPUT" | grep -q "authority=invalid_path_grant"; then
        pass "nsaudit accepts safe path $p"
    else
        fail "nsaudit rejected safe path $p (output: $OUTPUT)"
    fi
done

mkpaths() {
    echo "mkdir -p /mnt/ui/activity/0/presentation /mnt/msg /n/wallet/alice /tmp/veltro/ftree /tmp/veltro/.ns /tmp/veltro/cow /tmp/veltro/tasks /tmp/veltro/browser /tmp/veltro/editor /tmp/veltro/shell /tmp/veltro/fractal /tmp/veltro/man /mnt/matrix /phone /mnt/mail/accounts/alice /tmp/veltro/scratch; touch /mnt/msg/ctl /n/wallet/alice/ctl /tmp/veltro/ftree/ctl /mnt/matrix/ctl /phone/sms /mnt/mail/accounts/alice/compose"
}

bad_startup=""
for p in "${BAD_PRIV[@]}" "${BAD_DIRECT_SEND[@]}" "${BAD_INVALID[@]}"; do
    bad_startup="$bad_startup -p $p:rw"
done

if emu_c "tools9p-startup-bad" 20 \
    "$(mkpaths); tools9p $bad_startup read; cat /tool/paths >[2] /dev/null"; then
    if echo "$OUTPUT" | grep -q "path not grantable" || echo "$OUTPUT" | grep -q "invalid -p path"; then
        pass "tools9p startup rejects bad corpus"
    else
        fail "tools9p startup accepted bad corpus (output: $OUTPUT)"
    fi
else
    fail "tools9p startup bad corpus probe failed (output: $OUTPUT)"
fi

bindcmds="tools9p read & sleep 2; echo bindpath /tmp > /mnt/toolctl/ctl"
for p in "${BAD_PRIV[@]}" "${BAD_DIRECT_SEND[@]}" "${BAD_INVALID[@]}"; do
    bindcmds="$bindcmds; echo 'bindpath $p:rw' > /mnt/toolctl/ctl"
done
bindcmds="$bindcmds; cat /tool/paths"

if emu_c "tools9p-bindpath-bad" 20 "$(mkpaths); $bindcmds"; then
    bad_seen=0
    for p in "${BAD_PRIV[@]}" "${BAD_DIRECT_SEND[@]}" "${BAD_INVALID[@]}"; do
        if echo "$OUTPUT" | grep -q "^$p "; then
            bad_seen=1
        fi
    done
    if echo "$OUTPUT" | grep -q "^/tmp rw" && [[ "$bad_seen" -eq 0 ]]; then
        pass "tools9p bindpath rejects bad corpus"
    else
        fail "tools9p bindpath accepted a bad path (output: $OUTPUT)"
    fi
else
    fail "tools9p bindpath bad corpus probe failed (output: $OUTPUT)"
fi

good_startup=""
for p in "${GOOD[@]}"; do
    good_startup="$good_startup -p $p:rw"
done

if emu_c "tools9p-startup-good" 20 \
    "$(mkpaths); tools9p $good_startup read & sleep 2; cat /tool/paths"; then
    missing=0
    for p in "${GOOD[@]}"; do
        if ! echo "$OUTPUT" | grep -q "^$p "; then
            missing=1
        fi
    done
    if [[ "$missing" -eq 0 ]]; then
        pass "tools9p startup accepts safe corpus"
    else
        fail "tools9p startup missed a safe path (output: $OUTPUT)"
    fi
else
    fail "tools9p startup safe corpus probe failed (output: $OUTPUT)"
fi

if emu_c "nsconstruct-direct" 30 "/dis/tests/veltro_security_test.dis"; then
    if echo "$OUTPUT" | grep -q "PASS"; then
        pass "nsconstruct direct policy tests pass"
    else
        fail "nsconstruct direct policy test did not report PASS (output: $OUTPUT)"
    fi
else
    fail "nsconstruct direct policy test failed (output: $OUTPUT)"
fi

echo ""
echo "Total: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
