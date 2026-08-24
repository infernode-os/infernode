#!/bin/sh
# tests/host/escape_lab_evidence_test.sh — outer escape-room evidence privacy.
#
# INFR-412. In RUN-20260824T222058Z-CAMPAIGN the private evidence directory
# was 0700 but QEMU created target-net.pcap and target-console.log as 0644,
# because the launch shell never set a restrictive umask. They were corrected
# while capture was already running. These tests hold the launcher to creating
# evidence private, refusing to start over an exposure, and sealing modes at
# the end.
#
# Run from project root: ./tests/host/escape_lab_evidence_test.sh

set -eu

ROOT="${ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
LAB="$ROOT/tests/agent-harness/escape-lab.sh"

[ -f "$LAB" ] || { echo "FAIL: $LAB missing" >&2; exit 1; }

echo "=== escape-lab evidence privacy tests ==="

WORK="$(mktemp -d "${TMPDIR:-/tmp}/escape-lab-test.XXXXXX")"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok: $*"; }

modeof() {
	if stat -c '%a' "$1" 2>/dev/null; then :; else stat -f '%Lp' "$1"; fi
}

# The whole point is not to depend on the operator's umask, so run every case
# under the permissive one that caused the finding.
umask 022

EVIDENCE="target-net.pcap target-console.log target-command.log manifest.json"

# 1. init creates the tree private, whatever the umask is.
RUN1="$WORK/run1"
sh "$LAB" init "$RUN1" >/dev/null
[ "$(modeof "$RUN1")" = "700" ] || fail "init: rundir is $(modeof "$RUN1"), want 700"
for name in $EVIDENCE; do
	[ -f "$RUN1/$name" ] || fail "init: $name was not pre-created"
	[ "$(modeof "$RUN1/$name")" = "600" ] || \
		fail "init: $name is $(modeof "$RUN1/$name"), want 600"
done
pass "init pre-creates pcap/console/command-log/manifest at 0600"

# 2. check passes on that tree and reports it.
sh "$LAB" check "$RUN1" >/dev/null || fail "check: rejected a clean tree"
pass "check accepts a private tree"

# 3. The preflight aborts on a group/world-accessible file — including one the
#    launcher does not know the name of, which is how QEMU's own output got in.
chmod 0644 "$RUN1/target-net.pcap"
if sh "$LAB" check "$RUN1" >/dev/null 2>&1; then
	fail "check: accepted a 0644 pcap"
fi
chmod 0600 "$RUN1/target-net.pcap"
: > "$RUN1/stray-qemu-output.log"
chmod 0640 "$RUN1/stray-qemu-output.log"
if sh "$LAB" check "$RUN1" >/dev/null 2>&1; then
	fail "check: accepted a 0640 file it did not create"
fi
rm -f "$RUN1/stray-qemu-output.log"
mkdir "$RUN1/sub"
chmod 0755 "$RUN1/sub"
if sh "$LAB" check "$RUN1" >/dev/null 2>&1; then
	fail "check: accepted a 0755 subdirectory"
fi
rmdir "$RUN1/sub"
sh "$LAB" check "$RUN1" >/dev/null || fail "check: still rejecting a repaired tree"
pass "check aborts on any group/world-accessible evidence"

# 4. check refuses a tree that was never initialised, rather than passing it
#    vacuously — a campaign that skips init must not read as private.
if sh "$LAB" check "$WORK/never-made" >/dev/null 2>&1; then
	fail "check: accepted a missing rundir"
fi
mkdir "$WORK/bare"
chmod 0700 "$WORK/bare"
if sh "$LAB" check "$WORK/bare" >/dev/null 2>&1; then
	fail "check: accepted a rundir with no evidence files"
fi
pass "check refuses an uninitialised run directory"

# 5. run executes the child under umask 077, so files nobody pre-created —
#    QEMU's temporaries, the campaign's own output — are private too.
RUN2="$WORK/run2"
sh "$LAB" run "$RUN2" sh -c 'echo capture > "$ESCAPE_LAB_PCAP"; : > "$ESCAPE_LAB_RUNDIR/child.bin"' >/dev/null
[ "$(modeof "$RUN2/child.bin")" = "600" ] || \
	fail "run: child-created file is $(modeof "$RUN2/child.bin"), want 600"
grep -q capture "$RUN2/target-net.pcap" || fail "run: child did not write the pcap"
pass "run gives the child umask 077"

# 6. run logs the command it launched, so the campaign record shows it.
grep -q 'echo capture' "$RUN2/target-command.log" || \
	fail "run: command log does not name the launched command"
pass "run records the launched command"

# 7. run refuses to start over evidence that was ALREADY exposed. Repairing it
#    silently is what happened in the campaign, and by then the pcap had been
#    world-readable for the whole capture.
chmod 0644 "$RUN2/target-console.log"
if sh "$LAB" run "$RUN2" true >/dev/null 2>&1; then
	fail "run: started over evidence that was already group/world accessible"
fi
[ "$(modeof "$RUN2/target-console.log")" = "600" ] || \
	fail "run: refused but left the exposed file exposed"
pass "run aborts on a pre-existing exposure (and closes it)"

# 8. seal re-asserts 0700/0600 across the tree and records what it sealed.
RUN3="$WORK/run3"
sh "$LAB" init "$RUN3" >/dev/null
mkdir -p "$RUN3/audit/payloads"
: > "$RUN3/audit/payloads/payload-x"
chmod 0755 "$RUN3/audit" "$RUN3/audit/payloads"
chmod 0644 "$RUN3/audit/payloads/payload-x" "$RUN3/manifest.json"
sh "$LAB" seal "$RUN3" >/dev/null || fail "seal: failed on a repairable tree"
for d in "$RUN3" "$RUN3/audit" "$RUN3/audit/payloads"; do
	[ "$(modeof "$d")" = "700" ] || fail "seal: $d is $(modeof "$d"), want 700"
done
for f in "$RUN3/manifest.json" "$RUN3/audit/payloads/payload-x"; do
	[ "$(modeof "$f")" = "600" ] || fail "seal: $f is $(modeof "$f"), want 600"
done
[ -f "$RUN3/evidence-modes.txt" ] || fail "seal: no modes record written"
grep -q "600 $RUN3/audit/payloads/payload-x" "$RUN3/evidence-modes.txt" || \
	fail "seal: modes record omits a sealed payload"
[ "$(modeof "$RUN3/evidence-modes.txt")" = "600" ] || \
	fail "seal: the modes record itself is not 0600"
sh "$LAB" check "$RUN3" >/dev/null || fail "seal: sealed tree does not pass check"
pass "seal re-asserts 0700/0600 and records the sealed modes"

echo "escape_lab_evidence_test: PASS"
