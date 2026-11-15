#!/bin/sh
#
# exec_fd_test.sh — what a command run by the agent's exec tool is given,
# and what the tool says of a command it does not run as written.
#
# tests/exec_fd_probe.dis, run through exec, lists its file descriptors:
#
#   - 0 is /dev/null, 1 and 2 are the call's pipe, and the only other is
#     the command's own wait file.  Every call of a tool server shares one
#     descriptor group, and the command was given that group's 0, 1 and 2:
#     alone, the console (0); beside other calls, whatever one of them had
#     open there (a directory it was reading, a pipe of its copy-on-write
#     mount, a process control file).  The same holds with six other calls
#     in flight, ten times.
#   - three commands still printing at their time limit leave no process
#     of the tool behind (each left its output reader blocked in a send,
#     with the pipe).
#   - "a ; b", "$x", a pipe and a second line are refused and nothing is
#     run (the ; was taken out and "a b" run, saying nothing); "-t 0 cmd"
#     is an error (it ran "-t 0 cmd").
#
set -eu
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/veltro/tools9p.dis dis/veltro/tools/exec.dis dis/tests/tool9call.dis dis/tests/exec_fd_probe.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

# exec sees its activity's scratch directory and little else
SCR="$ROOT/tmp/veltro/scratch/0"
P="efp$$.dis"
OUT="$ROOT/tmp/exec-fd-test.$$.out"
SCRIPT="$ROOT/tmp/exec-fd-test.$$.sh"
trap 'rm -f "$SCR/$P" "$OUT" "$SCRIPT"' EXIT HUP INT TERM
mkdir -p "$SCR"
cp "$ROOT/dis/tests/exec_fd_probe.dis" "$SCR/$P"

cat > "$SCRIPT" <<EOF2
load std
path=(/dis/veltro /dis/cmd /dis .)
tools9p -m /tool read find exec >[2] /dev/null &
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 { if {! ftest -f /tool/exec/ctl} { sleep 1 } }
p=/tmp/veltro/scratch/$P
echo '== alone'
/dis/tests/tool9call.dis exec -t 3 \$p
echo '== beside'
for i in 1 2 3 4 5 6 7 8 9 10 {
	/dis/tests/tool9call.dis exec -t 3 \$p &
	for j in 1 2 3 { /dis/tests/tool9call.dis find '*' /lib/veltro > /dev/null & }
	for j in 1 2 3 { /dis/tests/tool9call.dis read /lib/veltro/system.txt > /dev/null & }
	sleep 1
}
sleep 3
echo '== chatty'
for i in 1 2 3 { /dis/tests/tool9call.dis exec -t 2 \$p spam | sed 1q }
# (each call's timer lives out its time: 3 seconds at most here)
sleep 4
echo '== threads'
ps | grep ToolExec
echo '== refused'
echo SEMI; /dis/tests/tool9call.dis exec \$p ';' /tmp/veltro/scratch/nosuch.dis
echo VAR; /dis/tests/tool9call.dis exec \$p '\$home'
echo PIPE; /dis/tests/tool9call.dis exec \$p '|' \$p
echo TZERO; /dis/tests/tool9call.dis exec -t 0 \$p
echo PLAIN; /dis/tests/tool9call.dis exec -t 5 \$p
echo EXEC_FD_DONE
EOF2

with_timeout 110 "$EMU" -c1 -r"$ROOT" /dis/sh.dis -c "sh /tmp/exec-fd-test.$$.sh; echo halt > /dev/sysctl" \
	</dev/null >"$OUT" 2>&1 || true
grep -q '^EXEC_FD_DONE$' "$OUT" || { echo "FAIL: the run did not finish"; cat "$OUT"; exit 1; }

status=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; status=1; }
section() { awk -v a="== $1" '$0 == a { on = 1; next } on && /^== / { exit } on { print }' "$OUT"; }
after() { awk -v a="$1" '$0 == a { on = 1; next } on && /^[A-Z_]+$/ { exit } on { print }' "$OUT"; }

# every listing: 0 is /dev/null, 1 and 2 one pipe, one other descriptor, the wait file
check_fds() {	# check_fds SECTION WANT-LISTINGS WHAT
	section "$1" > "$OUT.s"
	n=$(grep -c '^FDS-END$' "$OUT.s" || true)
	wrong=$(grep '^fd 0: ' "$OUT.s" | grep -cv '^fd 0: \(/dev/null\|#c/null\)$' || true)
	nulls=$(grep -c '^fd 0: ' "$OUT.s" || true)
	other=$(grep '^fd ' "$OUT.s" | grep -v '^fd [012]: ' | grep -cv '/wait$' || true)
	if [ "$n" -eq "$2" ] && [ "$nulls" -eq "$2" ] && [ "$wrong" -eq 0 ] && [ "$other" -eq 0 ]; then
		ok "$3"
	else
		bad "$3 ($n listings, $nulls with a descriptor 0, $wrong of them not /dev/null, $other descriptors that are neither 0-2 nor the wait file)"
		sort "$OUT.s" | uniq -c | sed 's/^/    /' | head -20
	fi
	rm -f "$OUT.s"
}
check_fds alone 1 "a command's descriptors are /dev/null, its pipe and its wait file"
check_fds beside 10 "the same with six other calls in flight, ten times"

if [ "$(section chatty | grep -c '^line 0 ')" -eq 3 ]; then
	ok "three commands that print for ever are each cut off at their time"
else
	bad "three commands that print for ever are each cut off at their time"
fi
left=$(section threads | grep -c ToolExec || true)
if [ "$left" -eq 0 ]; then
	ok "and leave no process of the tool behind"
else
	bad "and leave no process of the tool behind ($left left)"
	section threads | sed 's/^/    /'
fi

for c in SEMI VAR PIPE; do
	if after $c | grep -q '^error: exec runs one command' && ! after $c | grep -q 'FDS-END'; then
		ok "$c: refused, and nothing run"
	else
		bad "$c: refused, and nothing run"
		after $c | sed 's/^/    /' | head -5
	fi
done
if after TZERO | grep -q '^error: -t takes'; then
	ok "-t 0 is an error"
else
	bad "-t 0 is an error"
	after TZERO | sed 's/^/    /' | head -5
fi
after PLAIN | grep -q '^FDS-END$' && ok "-t 5 and a command still runs it" || bad "-t 5 and a command still runs it"

[ $status -eq 0 ] && echo "exec_fd_test: PASS" || { echo "--- output"; cat "$OUT"; }
exit $status
