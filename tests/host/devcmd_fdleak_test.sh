#!/bin/sh
#
# tests/host/devcmd_fdleak_test.sh
#
# The host command device (#C, emu/port/devcmd.c): a command's three
# pipes are closed when its conversation is, whether or not anyone
# opened its data or stderr file. They were closed only at the last
# close of those files, so a command started and never read kept them:
# speech9p's commands and "os -b" do exactly that, and the emulator's
# descriptors ran out.
#
# Thirty commands are started through /cmd/clone with nothing opened on
# them; the emulator's own descriptors are counted before and after from
# /proc, by a host command (whose parent the emulator is).
#
# Skips (exit 77) with no emulator, or where there is no /proc/PID/fd.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -d /proc/$$/fd ] || { echo "SKIP: no /proc/PID/fd on this host"; exit 77; }

SCRIPT="$ROOT/tmp/devcmd_fdleak_test.$$.sh"
mkdir -p "$ROOT/tmp"
trap 'rm -f "$SCRIPT"' EXIT
cat > "$SCRIPT" <<'EOT'
load std
fn count { os sh -c 'ls /proc/$PPID/fd | wc -l' }
bind -a '#C' /
echo BEFORE `{count}
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 {
	echo exec true > /cmd/clone
}
sleep 2
echo AFTER `{count}
x=`{os echo still-runs}
echo RAN $x
echo halt > /dev/sysctl
EOT

rc=0
out=$(with_timeout 120 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tmp/$(basename "$SCRIPT")" 2>&1 < /dev/null)
before=$(echo "$out" | sed -n 's/^BEFORE //p' | head -1)
after=$(echo "$out" | sed -n 's/^AFTER //p' | head -1)
if [ -z "$before" ] || [ -z "$after" ]; then
	echo "FAIL: the counts were not printed:"
	echo "$out" | grep -v sdl3 | tail -8
	exit 1
fi
if [ "$after" -le $((before + 6)) ]; then
	echo "PASS: thirty commands nobody read cost the emulator no descriptors ($before before, $after after)"
else
	echo "FAIL: thirty commands nobody read left $((after - before)) descriptors open ($before before, $after after)"
	rc=1
fi
if echo "$out" | grep -q '^RAN still-runs$'; then
	echo "PASS: a command still runs and is read afterwards"
else
	echo "FAIL: a command run afterwards gave nothing"
	rc=1
fi
exit $rc
