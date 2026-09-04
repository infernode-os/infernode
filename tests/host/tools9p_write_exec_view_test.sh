#!/bin/sh
# Regression test for INFR-435: write, list, read and exec must resolve a
# granted writable path to the same backing object.
#
# Each tool invocation forks a namespace and stages every granted writable
# path through a cowfs overlay (nsconstruct.overlaywritepaths). The overlay
# used to be keyed by /tmp/veltro/cow/<actid>-<seq>, where <seq> was the
# position of the path in that invocation's writable-path list. exec stages a
# larger writable set than the in-process tools (execwritepaths adds
# /lib/veltro, /lib/certs, /dis/veltro), so the same granted path landed at a
# different index — and therefore a different, empty overlay — for exec than
# for write/list/read. A file written through write was then invisible to a
# command run through exec, even at the identical absolute path, which blocked
# the source-assisted red-team qualification gate.
#
# The fix keys the overlay by the path itself (a stable hash), so every tool
# granted the same writable path shares one overlay.
#
# This drives the real per-invocation asyncexec/restrictns/cowfs path via
# tools9p -a 1 (an activity-scoped namespace, the same construction a
# delegated child gets), not a host filesystem shortcut.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

fails=0
NS="$ROOT/appl/veltro/nsconstruct.b"
grep -q 'overlaykey(' "$NS" || { echo "FAIL: overlaywritepaths does not key the cow overlay by path"; fails=$((fails+1)); }
if grep -q 'cow/%d-%d", actid, seq' "$NS"; then
	echo "FAIL: cow overlay still keyed by positional seq, not path"; fails=$((fails+1)); fi
[ "$fails" -eq 0 ] && echo "PASS: source contract (cow overlay keyed by path, shared across tools)"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }
[ -f "$ROOT/dis/veltro/tools9p.dis" ] || { echo "SKIP: tools9p.dis not built"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }
[ -f "$ROOT/dis/limbo.dis" ] || { echo "SKIP: limbo.dis not built"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }

DRIVE="$ROOT/tmp/tools9p_write_exec_view_drive.sh"
LOG="$(mktemp)"
trap 'rm -f "$DRIVE" "$LOG"' EXIT HUP INT TERM

cat >"$DRIVE" <<'EOF'
path=(/dis/veltro /dis/cmd /dis .)
rm -r /tmp/veltro/probe-sdk /tmp/veltro/cow >[2] /dev/null
mkdir -p /tmp/veltro/probe-sdk/dis
cp /dis/limbo.dis /tmp/veltro/probe-sdk/dis/limbo.dis
cp -r /module /tmp/veltro/probe-sdk/module
tools9p -a 1 -p /tmp/veltro/probe-sdk:rw write list read exec & sleep 2
echo '/tmp/veltro/probe-sdk/qualification-probe.b
implement Probe;
include "sys.m";
	sys: Sys;
include "draw.m";
Probe: module { init: fn(nil: ref Draw->Context, nil: list of string); };
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->print("INFR434_PROBE_OK");
}' > /tool/write/ctl
cat /tool/write/ctl
echo '@@LIST'
echo '/tmp/veltro/probe-sdk' > /tool/list/ctl
cat /tool/list/ctl
echo '@@COMPILE'
echo '/tmp/veltro/probe-sdk/dis/limbo.dis -I /tmp/veltro/probe-sdk/module -o /tmp/veltro/probe-sdk/qualification-probe.dis /tmp/veltro/probe-sdk/qualification-probe.b' > /tool/exec/ctl
cat /tool/exec/ctl
echo '@@RUN'
echo '/tmp/veltro/probe-sdk/qualification-probe.dis' > /tool/exec/ctl
cat /tool/exec/ctl
echo '@@DRIVEDONE'
EOF

timeout 90 "$EMU" -r"$ROOT" /dis/sh.dis -c "run /tmp/tools9p_write_exec_view_drive.sh" >"$LOG" 2>&1
rc=$?
case "$rc" in 0|124|137) ;; *) echo "FAIL: driver exited with status $rc"; sed -n '1,40p' "$LOG"; exit 1 ;; esac

out="$(grep -vE '^JIT|sdl3_pre|mounted on' "$LOG")"

# list must see the written file
if ! echo "$out" | grep -q 'qualification-probe.b'; then
	echo "FAIL: list tool did not see the written probe"; echo "$out" | sed -n '1,40p'; exit 1; fi

# exec's compiler must OPEN the write-tool file (the bug reported 'file does not exist')
if echo "$out" | grep -q 'qualification-probe.b.*file does not exist'; then
	echo "FAIL: exec cannot see the file written through write (INFR-435 not fixed)"
	echo "$out" | sed -n '1,40p'; exit 1; fi

# and the whole compile+run effect must succeed with the probe marker
if ! echo "$out" | grep -q '^INFR434_PROBE_OK'; then
	echo "FAIL: write->compile->exec did not produce INFR434_PROBE_OK"
	echo "$out" | sed -n '1,40p'; exit 1; fi

echo "PASS: write/list/exec share the granted writable path (compile+run INFR434_PROBE_OK)"
[ "$fails" -eq 0 ] || exit 1
