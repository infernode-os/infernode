#!/bin/bash
#
# Live namespace manifest invariants.
#
# These checks intentionally avoid pinning the whole manifest. The manifest is
# a UI/audit view of the restricted namespace, so ordinary profile additions may
# add safe paths. The invariants below cover paths that should never appear in a
# minimal/default agent or an attenuated child unless a trusted launcher grants a
# specific stronger capability.

set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

SH="/dis/sh.dis"
PASSED=0
FAILED=0

pass() { echo "PASS: $1"; PASSED=$((PASSED+1)); }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[[ -x "$EMU" ]] || { echo "ERROR: emu not found at $EMU" >&2; exit 1; }
[[ -f "$ROOT/dis/veltro/tools9p.dis" ]] || {
	echo "SKIP: tools9p.dis not found"
	exit 77
}

emu_c() {
	local name="$1" tout="$2" cmd="$3"
	local log="/tmp/.nsmanifest-${name}.log"
	timeout "$tout" "$EMU" -r"$ROOT" "$SH" -c \
		"path=(/dis/veltro /dis/cmd /dis .); $cmd" \
		</dev/null >"$log" 2>&1
	local rc=$?
	OUTPUT=$(cat "$log")
	rm -f "$log"
	emu_timeout_ok "$rc"
}

assert_absent_paths() {
	local output="$1"
	local label="$2"
	local bad=(
		"/tool/ctl"
		"/mnt/toolctl"
		"/mnt/toolctl/ctl"
		"/mnt/ui"
		"/chan"
		"/net"
		"/net.alt"
		"/mnt/msg/draft"
		"/mnt/msg/ctl"
		"/mnt/msg/approve"
		"/mnt/msg/deny"
		"/n/wallet/ctl"
		"/n/wallet/pending"
		"/n/wallet/new"
		"/mnt/llm"
	)
	local found=""
	local p
	for p in "${bad[@]}"; do
		if grep -q "^path=${p}\\([ 	]\\|$\\)" <<<"$output"; then
			found="$found $p"
		fi
	done
	if [[ -n "$found" ]]; then
		fail "$label manifest exposes dangerous paths:$found"
	else
		pass "$label manifest omits dangerous control, network, wallet, message, UI, and LLM paths"
	fi
}

echo "namespace manifest invariant tests"
echo ""

if emu_c "minimal" 14 \
	"rm -f /tmp/veltro/.ns/manifest; tools9p -m /tool read list & sleep 8; echo MANIFEST; cat /tmp/veltro/.ns/manifest"; then
	if grep -q '^path=/tmp/veltro' <<<"$OUTPUT" &&
	   grep -q '^path=/dev/time' <<<"$OUTPUT"; then
		pass "minimal manifest exists and includes baseline workspace/system clock"
	else
		fail "minimal manifest missing baseline entries (output: $OUTPUT)"
	fi
	assert_absent_paths "$OUTPUT" "minimal"
else
	fail "minimal manifest probe failed (output: $OUTPUT)"
fi

if emu_c "child" 18 \
	"rm -f /tmp/veltro/.ns/manifest.21; mkdir -p /tmp/veltro/child; tools9p -m /tool -b diff -p /tmp/veltro:rw read task diff & sleep 3; echo '21 tools=diff paths=/tmp/veltro/child:rw' > /tool/provision; sleep 6; echo MANIFEST; cat /tmp/veltro/.ns/manifest.21; echo TOOLS; cat /tool.21/tools; echo PATHS; cat /mnt/toolctl.21/paths"; then
	if grep -q '^path=/tmp/veltro/child' <<<"$OUTPUT"; then
		pass "child manifest includes exact delegated path"
	else
		fail "child manifest missing exact delegated path (output: $OUTPUT)"
	fi
	if grep -q '^diff$' <<<"$OUTPUT" && ! grep -q '^exec$' <<<"$OUTPUT"; then
		pass "child tool set remains within delegated budget"
	else
		fail "child tool set escaped delegated budget (output: $OUTPUT)"
	fi
	if grep -q '^/tmp/veltro/child rw' <<<"$OUTPUT" &&
	   ! grep -q '^/tmp/veltroevil' <<<"$OUTPUT"; then
		pass "child control view preserves exact delegated path"
	else
		fail "child control view did not preserve exact path semantics (output: $OUTPUT)"
	fi
	assert_absent_paths "$OUTPUT" "child"
else
	fail "child manifest probe failed (output: $OUTPUT)"
fi

echo ""
echo "Total: $PASSED passed, $FAILED failed"
[[ "$FAILED" -eq 0 ]]
