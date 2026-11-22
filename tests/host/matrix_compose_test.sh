#!/bin/sh
#
# matrix_compose_test.sh — what an agent may compose with the matrix
# tool, against a real Matrix runtime (wm/matrix -h) and tools9p.
#
# A composition is loaded into Matrix's name space, which is the user's.
# The tool's policy looked only at lines beginning "service", "layout" or
# "watch" and let every other line through, refused a service the mount
# / and gave it any other (/prog: the whole process table, read back
# with "out"), took any file for a watch, whose arms tell what the file
# holds, and refused most watch arms as display modules.  It said
# "reload applied" whatever the runtime did.  And the runtime took each
# 9P message written to its composition file as a composition: one
# longer than a message was loaded as its beginning and then as its
# end, so a line the policy had read as the tail of a long comment was a
# line of the composition, "left app /dis/wm/shell.dis -c <command>"
# among them, which the policy refuses.
#
# Here: lines that are no composition line are refused; a service and a
# watch name Matrix's own data or are lines the live composition already
# has; an arm with blanks is taken; a composition the runtime does not
# load is reported so; a composition longer than a message is refused by
# the tool, and written to the runtime directly is one composition.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/wm/matrix.dis dis/veltro/tools9p.dis dis/veltro/tools/matrix.dis dis/matrix/sysmon-svc.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

H=$(mktemp -d)
trap 'rm -rf "$H"' EXIT
mkdir -p "$H/tmp"
printf 'service sysmon-svc /\n' > "$H/tmp/comp0"
printf 'load std\necho ran > /tmp/app-ran\n' > "$H/tmp/app.sh"
chmod +x "$H/tmp/app.sh"
# a composition whose second 9P message is one by itself: the app line
# is the end of the first line, a comment
python3 - "$H/tmp" <<'PY'
import sys
d = sys.argv[1]
head = '# '
text = head + 'p' * (8192 - len(head)) + 'left app /dis/wm/shell.dis -c /tmp/app.sh\nlayout hsplit 50 50\n'
open(d + '/long.tool', 'w').write('compose ' + text)
open(d + '/long.direct', 'w').write(text)
PY

run() {	# section, the tool's arguments
	echo "echo '== $1'; echo '$2' > /tool/matrix/run; cat /tool/matrix/run; echo"
}
{
	cat <<'DRV'
load std
path=(/dis/veltro /dis/cmd /dis .)
wm/matrix -h /tmp/comp0 >[2] /tmp/matrix.err &
sleep 4
tools9p matrix >[2] /tmp/tools9p.err &
sleep 4
DRV
	run PROG 'compose service sysmon-svc /prog'
	run DISPLAY 'compose display x /'
	run CASE 'compose Service sysmon-svc /'
	run APP 'compose layout hsplit 50 50;left app /dis/wm/shell.dis -c /tmp/app.sh'
	run WATCHFILE 'compose service sysmon-svc /;watch /lib/veltro/meta.txt;secret -> notify found'
	echo "echo '== LIVE0'; cat /mnt/matrix/composition; echo"
	run KEEP 'compose layout hsplit 50 50;left cpu-gauge /tmp/matrix/sysmon-svc;service sysmon-svc /'
	run WATCH 'compose service sysmon-svc /;watch /tmp/matrix/sysmon-svc/cpu/current;zzz -> notify hello there'
	run BADREGION 'compose layout hsplit 50 50;top cpu-gauge /tmp/matrix/sysmon-svc;service sysmon-svc /'
	echo "echo '== LONG-TOOL'; cat /tmp/long.tool > /tool/matrix/run; cat /tool/matrix/run | sed 5q; echo"
	echo "sleep 2; echo '== LIVE1'; grep '^left' /mnt/matrix/composition; echo"
	echo "echo '== LONG-DIRECT'; cat /tmp/long.direct > /mnt/matrix/composition; sleep 3"
	echo "echo '== LIVE2'; grep '^left' /mnt/matrix/composition; cat /mnt/matrix/composition | wc -c"
	echo "echo '== DONE'"
	echo "echo halt > /dev/sysctl"
} > "$H/tmp/drv.sh"

LOG=$H/log
with_timeout 150 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "bind -c '#U*$H/tmp' /tmp; run /tmp/drv.sh" </dev/null >"$LOG" 2>&1 || true
grep -q '^== DONE' "$LOG" || { echo "FAIL: the driver did not finish"; tail -30 "$LOG"; exit 1; }

sec() {
	sed -n "/^== $1\$/,/^== /p" "$LOG" | sed '1d;/^== /d'
}
FAILED=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }
has() {	# description, section, pattern
	if sec "$2" | grep -q "$3"; then pass "$1"; else fail "$1 ($2: $(sec "$2" | head -3 | cut -c1-150 | tr '\n' ' '))"; fi
}
hasnot() {
	if sec "$2" | grep -q "$3"; then fail "$1 ($2: $(sec "$2" | head -3 | cut -c1-150 | tr '\n' ' '))"; else pass "$1"; fi
}

has "a service on /prog is refused" PROG '^error:.*not agent-composeable'
has "a line that is no composition line is refused" DISPLAY '^error: unrecognized line'
has "so is a keyword in other letters" CASE '^error: unrecognized line'
has "an app is refused" APP '^error: app hosting'
has "a watch on a file of the user's is refused" WATCHFILE "^error: an agent's watch"
has "the live composition is still the user's" LIVE0 '^service sysmon-svc /$'
has "a service the live composition has is kept in a new one" KEEP 'reload applied'
has "a watch on a service's output, its arm with blanks, is taken" WATCH 'reload applied'
has "a composition the runtime does not load is reported so" BADREGION '^error:.*not loaded'
has "a composition longer than a message is refused by the tool" LONG-TOOL '^error: composition too long'
hasnot "and its end is not loaded as one" LIVE1 '^left app'
hasnot "written to the runtime, it is one composition" LIVE2 '^left app'
n=$(sec LIVE2 | tail -1 | tr -d ' \n')
[ "${n:-0}" -gt 8192 ] 2>/dev/null && pass "all of it ($n bytes)" || fail "the long composition was not loaded whole (${n:-none} bytes)"
[ ! -e "$H/tmp/app-ran" ] && pass "no app was started" || fail "the app of the long composition's end ran"

if [ "$FAILED" -ne 0 ]; then
	cat "$LOG"; cat "$H/tmp/matrix.err" 2>/dev/null | tail -20
	echo "matrix_compose_test: $FAILED failed"
	exit 1
fi
echo "matrix_compose_test: PASS"
