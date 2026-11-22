#!/bin/sh
#
# default_budget_test.sh -- the tools a task agent can be given by default
#
# lib/lucifer/boot.sh starts the tool server with a delegation budget
# (-b): the tools activity 0 may hand to a task or a subagent.  A tool
# whose manifest (lib/veltro/nsaudit/authorities/NAME) says its effects are
# not bounded by the call's grants must not be in it: a task given such a
# tool changes the user's files with no grant, no overlay and no promote.
# git is the one such tool (its worker keeps the name space tools9p started
# in), and was in the budget.
#
# Also: every name in the budget is a tool that has a manifest, so that the
# namespace audit can speak for it, and the tools whose calls need the
# user's approval and are never given to a subagent (sms, dial, task) are
# reported if they are there, as a child could not load them.
#
# No emulator needed.
#
set -u
ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
BOOT="$ROOT/lib/lucifer/boot.sh"
AUTH="$ROOT/lib/veltro/nsaudit/authorities"
[ -f "$BOOT" ] && [ -d "$AUTH" ] || { echo "default_budget_test: SKIP (no boot.sh or manifests)"; exit 77; }

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails+1)); }

budget=$(grep -E '^[^#]*tools9p .* -b ' "$BOOT" | sed -E 's/.* -b ([^ ]+).*/\1/' | tr ',' ' ')
n=$(echo "$budget" | wc -w)
if [ "$n" -ge 5 ]; then
	pass "boot.sh starts tools9p with a delegation budget ($n tools)"
else
	fail "no delegation budget found in $BOOT"
fi

bad=
for t in $budget; do
	f="$AUTH/$t"
	[ -f "$f" ] || continue
	if grep -qiE "regardless of caps|UNRESTRICTED namespace|High-trust" "$f"; then
		bad="$bad $t"
	fi
done
if [ -z "$bad" ]; then
	pass "no tool in the budget has effects its manifest puts outside the call's grants"
else
	fail "in the default budget though their manifests say their effects are outside the call's grants:$bad"
fi

case " $budget " in
*" git "*)	fail "git is in the default budget" ;;
*)		pass "git is not in the default budget" ;;
esac

# the check above must be able to fail: git's manifest is one it catches
if grep -qiE "regardless of caps|UNRESTRICTED namespace|High-trust" "$AUTH/git" 2>/dev/null; then
	pass "git's manifest is one the rule catches"
else
	fail "git's manifest no longer says what the rule looks for: if git's writes now go through grants, put it back in the budget and change this test"
fi

nomanifest=
for t in $budget; do
	[ -f "$AUTH/$t" ] || nomanifest="$nomanifest $t"
done
if [ -z "$nomanifest" ]; then
	pass "every tool in the budget has a manifest"
else
	echo "note: in the budget with no manifest in $AUTH:$nomanifest"
fi

[ "$fails" -eq 0 ] && { echo "default_budget_test: PASS"; exit 0; }
echo "default_budget_test: $fails failed"
exit 1
