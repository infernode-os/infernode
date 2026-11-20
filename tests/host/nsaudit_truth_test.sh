#!/bin/sh
#
# nsaudit_truth_test.sh — nsaudit does not report what it did not check,
# on capabilities and rules the test makes:
#
#  - with a rules directory that is empty, or holds a file that is not a
#    rule, it fails saying so (it printed "violations (none)" and
#    succeeded: every configuration was clean);
#  - a rule's severity counts whatever its case (High was not high, so
#    its violation did not fail the audit);
#  - a role that is neither toplevel nor child is refused (no rule names
#    another, so "chlid" with no nodevs had no violation at all), and so
#    a role cannot carry a tab and fields of its own into the -m record;
#  - an activity id that is no number is refused (it read as activity 0,
#    whose writable grants are staged, and the durable-write finding
#    went);
#  - a tool's name is a name in the manifest directory, not a path to a
#    manifest elsewhere.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/nsaudit.dis" ] || { echo "SKIP: nsaudit.dis not built"; exit 77; }

T=tmp/nsaudit_truth_test.$$
D="$ROOT/$T"
mkdir -p "$D"
trap '[ -n "${SPAWN_KEEP:-}" ] || rm -rf "$ROOT/$T"' EXIT

# caps NAME ROLE NODEVS ACTID TOOL [PATHLINE]
caps() {
	mkdir -p "$D/$1/meta"
	printf '%s\n' "$5" > "$D/$1/tools"
	printf '%s\n' "${6:-}" > "$D/$1/paths"
	printf '%b\n' "$2" > "$D/$1/meta/role"
	printf '0\n' > "$D/$1/meta/xenith"
	printf '%s\n' "$4" > "$D/$1/meta/actid"
	[ "$3" = MISSING ] || printf '%s\n' "$3" > "$D/$1/meta/nodevs"
}
caps plain toplevel unset 0 read
caps typo chlid MISSING 0 read
caps tabrole 'toplevel\tnodevs=set\tnodevs_status=valid' unset 0 read
caps badactid toplevel set abc write '/n/local/etc rw'
caps toolpath toplevel set 0 "../../../../tmp/nsaudit_truth_test.$$/mine" '/n/local/etc rw'
printf 'tool=mine\n\tauthorities=\n' > "$D/mine"

mkdir -p "$D/norules" "$D/junkrules" "$D/caserules"
cp "$ROOT/lib/veltro/nsaudit/rules/device-gate-bypass" "$D/junkrules/"
printf 'this is not a rule\n' > "$D/junkrules/notes"
sed 's/severity=high/severity=High/' "$ROOT/lib/veltro/nsaudit/rules/device-gate-bypass" > "$D/caserules/device-gate-bypass"
grep -q 'severity=High' "$D/caserules/device-gate-bypass" || { echo "SKIP: the device-gate-bypass rule is not of severity high"; exit 77; }

cd "$ROOT"
R=/lib/veltro/nsaudit/rules
with_timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis -c "
load std
path=(/dis/veltro /dis/cmd /dis .)
cd /$T
fn audit { nsaudit \$* > \$out >[2=1]; echo status \$status >> \$out }
out=o.plain; audit -m plain
out=o.typo; audit -m typo
out=o.tabrole; audit -m tabrole
out=o.badactid; audit -m badactid
out=o.toolpath; audit -m toolpath
bind /$T/norules $R
out=o.norules; audit plain
out=o.norules.m; audit -m plain
bind /$T/junkrules $R
out=o.junkrules; audit -m plain
bind /$T/caserules $R
out=o.caserules; audit -m plain
echo R done
echo halt > '#c/sysctl'" </dev/null >"$D/log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$D/$1" 2>/dev/null || true; }
one() { f "$1" | tr '\n\t' '| ' | cut -c1-400; }
refused() { f "$1" | grep -q '^status [a-z]' && ! f "$1" | grep -q '^nsaudit=caps'; }

grep -q '^R done' "$D/log" || { fail "the driver did not finish"; tail -20 "$D/log"; exit 1; }

if f o.plain | grep -q 'violation=DEVICE_GATE_BYPASS' && f o.plain | grep -q '^status .*high-violations'; then
	pass "with the rules there, a toplevel agent without nodevs is a high violation"
else
	fail "plain: $(one o.plain)"
fi

if refused o.norules && f o.norules | grep -q 'no rules' && ! f o.norules | grep -q '(none)' && refused o.norules.m; then
	pass "with no rules nothing is reported clean"
else
	fail "no rules: $(one o.norules) -m: $(one o.norules.m)"
fi

if f o.junkrules | grep -q '^status [a-z]' && f o.junkrules | grep -q 'is not a rule' && ! f o.junkrules | grep -q '^violation='; then
	pass "a rules directory with a file that is no rule is refused"
else
	fail "junk rule: $(one o.junkrules)"
fi

if f o.caserules | grep -q 'violation=DEVICE_GATE_BYPASS' && f o.caserules | grep -q '^status .*high-violations'; then
	pass "a rule's severity counts in any case"
else
	fail "severity High: $(one o.caserules)"
fi

if refused o.typo && f o.typo | grep -q 'unknown role'; then
	pass "a role that is neither toplevel nor child is refused"
else
	fail "role chlid: $(one o.typo)"
fi

if refused o.tabrole && f o.tabrole | grep -q 'unknown role'; then
	pass "a role carries no fields of its own into the record"
else
	fail "role with tabs: $(one o.tabrole)"
fi

if refused o.badactid && f o.badactid | grep -q 'not a number'; then
	pass "an activity id that is no number is refused"
else
	fail "actid abc: $(one o.badactid)"
fi

if refused o.toolpath && f o.toolpath | grep -q "not a tool's name"; then
	pass "a tool's name is not a path to a manifest"
else
	fail "tool as path: $(one o.toolpath)"
fi

if [ $failed != 0 ]; then
	echo "--- emulator output:"
	tail -20 "$D/log"
	exit 1
fi
echo "nsaudit_truth_test: PASS"
