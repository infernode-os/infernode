#!/bin/sh
# Regression test for INFR-436: a command run through the Veltro exec tool
# that makes the shell fork a sub-process (a redirect, pipe, ';' sequence, or
# background job) must not panic the interpreter.
#
# The exec worker applies NODEVS for containment, which hides the process
# filesystem (#p / /prog). sh's waitfd() reopens #p/<pid>/wait on every fork
# (runasync / Context.copy); under NODEVS that open fails, and it used to
# panic() — aborting the whole shell and, because the panic happened in the
# forked sub-shell before it synced with its parent, hanging the exec worker
# until its 5s timeout killed the process group.
#
# Fix: waitfd() raises a catchable "fail:" instead of panic(), and runasync
# performs its context copy inside the guarded block, so the failure is
# reported to the parent as a clean command error. Normal (unrestricted)
# shell forking is unaffected: waitfd() only fails when the process
# filesystem is hidden.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"
set -u

fails=0
SH_SRC="$ROOT/appl/cmd/sh/sh.b"
if grep -q 'panic(sys->sprint("cannot open wait file' "$SH_SRC"; then
	echo "FAIL: waitfd() still panics when it cannot open the wait file"; fails=$((fails+1)); fi
grep -q 'raise "fail:cannot open wait file' "$SH_SRC" || { echo "FAIL: waitfd() does not raise a catchable failure"; fails=$((fails+1)); }
[ "$fails" -eq 0 ] && echo "PASS: source contract (waitfd raises instead of panicking)"

[ -x "$EMU" ] || { echo "SKIP: emu not found at $EMU"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }
[ -f "$ROOT/dis/veltro/tools9p.dis" ] || { echo "SKIP: tools9p.dis not built"; [ "$fails" -eq 0 ] && exit 0 || exit 1; }

DRIVE="$ROOT/tmp/exec_fork_no_panic_drive.sh"
LOG="$(mktemp)"
trap 'rm -f "$DRIVE" "$LOG"' EXIT HUP INT TERM

# 1. exec: a redirect (forks a sub-shell) must not panic.
# 2. normal shell (unrestricted): redirect, pipe and backquote still work.
cat >"$DRIVE" <<'EOF'
path=(/dis/veltro /dis/cmd /dis .)
rm -r /tmp/veltro/probe-sdk >[2] /dev/null
mkdir -p /tmp/veltro/probe-sdk
tools9p -a 1 -p /tmp/veltro/probe-sdk:rw write list exec & sleep 2
echo '@@EXECREDIR'
echo 'echo hi > /tmp/veltro/probe-sdk/out.txt' > /tool/exec/ctl
cat /tool/exec/ctl
echo ''
echo '@@NORMALSHELL'
load std
echo r-`{echo bq} > /tmp/normalshell.txt
cat /tmp/normalshell.txt
echo p-abc | tr a-z A-Z
echo '@@DRIVEDONE'
EOF

timeout 60 "$EMU" -r"$ROOT" /dis/sh.dis -c "run /tmp/exec_fork_no_panic_drive.sh" >"$LOG" 2>&1
rc=$?
case "$rc" in 0|124|137) ;; *) echo "FAIL: driver exited with status $rc"; sed -n '1,40p' "$LOG"; exit 1 ;; esac
out="$(grep -vE '^JIT|sdl3_pre|mounted on' "$LOG")"

# The whole point: no panic, and no interpreter break.
if echo "$out" | grep -qiE 'sh panic:|Broken: .?panic'; then
	echo "FAIL: exec forking command still panics the shell"
	echo "$out" | sed -n '1,40p'; exit 1; fi
if ! echo "$out" | grep -q '@@DRIVEDONE'; then
	echo "FAIL: driver did not run to completion (shell likely crashed)"
	echo "$out" | sed -n '1,40p'; exit 1; fi

# Normal, unrestricted shell forking must still work.
if ! echo "$out" | grep -q 'r-bq'; then
	echo "FAIL: normal shell redirect+backquote regressed"; echo "$out" | sed -n '1,40p'; exit 1; fi
if ! echo "$out" | grep -q 'P-ABC'; then
	echo "FAIL: normal shell pipe regressed"; echo "$out" | sed -n '1,40p'; exit 1; fi

echo "PASS: exec forking command fails cleanly (no panic); normal shell forking intact"
[ "$fails" -eq 0 ] || exit 1
