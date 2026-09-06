#!/bin/sh
#
# tests/host/wpa_backoff_test.sh
#
# What ip/wpa(8) says to the console while it cannot get a usable link.
#
# On 2026-09-06 a Raspberry Pi 3B+ associated, lost the association,
# re-associated, found the queue closed and said so -- about fifty lines
# a second, for ever, on a machine whose only console is a serial line.
# There was no way to type a command to stop it and the board had to be
# power-cycled.  The supplicant was doing the right thing (retrying) and
# reporting it the wrong way (every time round the loop).
#
# CI did not see it.  tests/host/wpa_join_test.sh runs the supplicant
# against exactly this shape of interface and pipes its log through
# `sort -u`, which turns a hundred thousand identical lines into one.
# So this test counts lines rather than reading them.
#
# Two failure shapes, because they are throttled by different code:
#
#   the queue ends at once   the driver reports a link and the data file
#                            gives end of file immediately, so the whole
#                            associate/read/lose cycle turns as fast as
#                            the machine can print.  This is the one
#                            that took the board out.
#
#   the radio never joins    ifstats stays "unassociated" for ever, and
#                            the supplicant polls it.
#
# In both, three things have to hold at once, and only all three
# together are the bug fixed:
#
#   it must not flood        few lines over the window
#   it must keep trying      the ctl file must show attempt after
#                            attempt while the console stays quiet, so
#                            that "quiet" cannot be a supplicant that
#                            gave up or died
#   it must stay legible     the lines that do come through must carry
#                            how long this has gone on, so a person can
#                            tell "trying" from "stuck"
#
# An interface made of plain files, as in wpa_join_test.sh: a plain file
# is not a queue, so a read returns what is there and then end of file,
# which is precisely the condition being tested.
#
# Skips (exit 77) without an emulator, timeout(1) or a built supplicant.
#
# Run from project root: ./tests/host/wpa_backoff_test.sh
#

. "$(dirname "$0")/common.sh"

command -v timeout >/dev/null 2>&1 || { echo "SKIP: no timeout(1)"; exit 77; }
[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
[ -f "$ROOT/dis/ip/wpa.dis" ] || { echo "SKIP: dis/ip/wpa.dis not built"; exit 77; }
[ -f "$ROOT/dis/auth/proto/wpapsk.dis" ] || { echo "SKIP: wpapsk proto not built"; exit 77; }

ESSID=infernode
PASS=InfernodeTest
SMAC=020000000001

fail=0
check() {
	if [ "$2" = ok ]; then
		echo "PASS: $1"
	else
		echo "FAIL: $1"
		fail=1
	fi
}

# Run the supplicant against a plain-file interface reporting $1 as its
# status, for $2 seconds.  Leaves the console log in $LOG and the ctl
# writes in $CLONE.
run_supplicant() {
	status=$1
	secs=$2

	DIR="$ROOT/tmp/wpa-backoff-$$"
	IDIR="/tmp/wpa-backoff-$$"
	SCRIPT="$ROOT/tmp/wpa-backoff-$$.sh"
	LOG="$DIR.log"
	CLONE="$DIR/clone"
	rm -rf "$DIR" "$SCRIPT" "$LOG"
	mkdir -p "$DIR/0"

	echo "$SMAC" > "$DIR/addr"
	echo "0" > "$CLONE"
	{ echo "essid: $ESSID"; echo "status: $status"; } > "$DIR/ifstats"
	# An empty data file: every read is an immediate end of file, which
	# is what a driver that has dropped the association looks like.
	: > "$DIR/0/data"

	cat > "$SCRIPT" << INFERNO
load std
auth/factotum &
sleep 2
echo 'key proto=wpapsk role=client essid=$ESSID !password=$PASS' > /mnt/factotum/ctl
ip/wpa -s $ESSID $IDIR &
sleep $secs
INFERNO

	timeout $((secs + 25)) "$EMU" -c1 -r"$ROOT" sh "/tmp/$(basename "$SCRIPT")" \
		> "$LOG" 2>&1
	rc=$?
	rm -f "$SCRIPT"
	emu_timeout_ok "$rc"
}

cleanup() { rm -rf "$ROOT"/tmp/wpa-backoff-$$ "$ROOT"/tmp/wpa-backoff-$$.* ; }
trap cleanup EXIT INT TERM

#
# 1. The queue that ends at once -- the board's failure.
#
WINDOW=30
echo "Driving the supplicant against a link that will not carry frames (${WINDOW}s)..."
if ! run_supplicant associated "$WINDOW"; then
	cat "$LOG"
	echo "FAIL: emu exited $rc"
	exit 1
fi

lines=$(grep -c '^wpa: ' "$LOG" 2>/dev/null || true)
# Every association attempt writes the RSN element to the ctl file, so
# the ctl file counts the attempts the console no longer narrates.
# Counted with -o rather than -c: ctl writes carry no newline, so all of
# them land on one line and grep -c would answer 1 however many there
# were.
attempts=$(grep -o 'auth 3014' "$CLONE" 2>/dev/null | wc -l | tr -d ' ')
[ -n "$attempts" ] || attempts=0

echo "  $lines console lines, $attempts association attempts"
sed 's/^/  emu: /' "$LOG"

# It ran at all.  Without this, a supplicant that died on the first line
# would satisfy every bound below.
check "the supplicant started and named its network" \
	"$(grep -q "wpa: $IDIR: network" "$LOG" && echo ok || echo no)"

# It did not flood.  Before the fix this was about 1600 lines in this
# window; the ceiling is set well above what the fix produces (5) and
# far below what a per-loop report produces.
if [ "$lines" -le 15 ]; then
	check "the console stays quiet: $lines lines in ${WINDOW}s (was ~1600)" ok
else
	check "the console stays quiet: $lines lines in ${WINDOW}s, want at most 15" no
fi

# It kept trying.  Quiet is only correct if the supplicant is still
# working; a supplicant that exited would also be quiet.
if [ "$attempts" -ge 5 ]; then
	check "it keeps re-associating: $attempts attempts on the ctl file" ok
else
	check "it keeps re-associating: only $attempts attempts, want at least 5" no
fi

# And it is retrying more often than it is talking, which is the whole
# distinction between backing off the retry and backing off the report.
if [ "$attempts" -gt "$lines" ]; then
	check "it retries more often than it reports ($attempts > $lines)" ok
else
	check "it retries more often than it reports ($attempts vs $lines)" no
fi

# The information survives the rationing: a line that says how long this
# has been going on and how many attempts it has taken.
check "a surviving line says how long and how many" \
	"$(grep -q 'attempts over' "$LOG" && echo ok || echo no)"

# And the first loss is still announced immediately, so a person does
# not wait twenty seconds to learn the link went.
check "the first loss is announced at once" \
	"$(grep -q 'link lost; re-associating' "$LOG" && echo ok || echo no)"

cleanup

#
# 2. The radio that never joins.
#
# The first line is due after twenty seconds and the interval doubles
# from there, so this window holds two or three of them -- and they must
# differ, because an unchanging line repeated on a fixed interval is
# exactly what could not be told apart from a wedged program.
#
WINDOW=50
echo ""
echo "Driving the supplicant against a radio that never associates (${WINDOW}s)..."
if ! run_supplicant unassociated "$WINDOW"; then
	cat "$LOG"
	echo "FAIL: emu exited $rc"
	exit 1
fi

sed 's/^/  emu: /' "$LOG"
# grep -c prints 0 and exits 1 when nothing matches, so the failure
# has to be swallowed without printing a second count.
waiting=$(grep -c 'still waiting for the radio to associate' "$LOG" 2>/dev/null || true)
marked=$(grep -c 'still waiting for the radio to associate (' "$LOG" 2>/dev/null || true)
distinct=$(grep 'still waiting for the radio to associate' "$LOG" | sort -u | wc -l | tr -d ' ')

check "the supplicant started and named its network" \
	"$(grep -q "wpa: $IDIR: network" "$LOG" && echo ok || echo no)"

# It says something: silence would be a different bug.
if [ "$waiting" -ge 1 ]; then
	check "it reports that it is waiting ($waiting lines in ${WINDOW}s)" ok
else
	check "it reports that it is waiting (got none)" no
fi

# But not once a poll: a hundred-millisecond poll over this window would
# be ~300 lines.
if [ "$waiting" -le 4 ]; then
	check "and not once per poll ($waiting lines, want at most 4)" ok
else
	check "and not once per poll ($waiting lines, want at most 4)" no
fi

# Every one of them carries the elapsed time...
if [ "$marked" = "$waiting" ]; then
	check "every waiting line carries how long it has waited" ok
else
	check "every waiting line carries how long it has waited ($marked of $waiting)" no
fi

# ...and no two are the same line, which is what lets a reader tell a
# supplicant that is still counting from one that has stopped.
if [ "$distinct" = "$waiting" ]; then
	check "no two waiting lines are identical ($distinct distinct)" ok
else
	check "no two waiting lines are identical ($distinct distinct of $waiting)" no
fi

# It must not have given up and claimed an association it never got.
check "it does not claim an association it never made" \
	"$(grep -q 'associated; starting' "$LOG" && echo no || echo ok)"

[ "$fail" = 0 ] || exit 1
echo ""
echo "PASS: ip/wpa backs off its console reporting without giving up"
exit 0
