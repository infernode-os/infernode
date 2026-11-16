#!/bin/sh
#
# wpa_log_test.sh - what a radio peer can make ip/wpa (wpa(8)) write,
# and what it says about keys, with tests/wpadrive.b as the interface:
# its clone, addr, ifstats and data are files of the test's, its frames
# tests/wpa_test.b's synthetic handshake, and wpa's standard error a
# file, as os/init gives it one (/tmp/wpa.log, on 8MB of RAM that every
# /tmp on the board shares).
#
#  - 3000 frames nobody need hold a key to send (a descriptor version
#    not implemented, a frame cut short, a MIC that is wrong) are a line
#    a kind, not a line a frame: each was a line, 110 bytes of the
#    board's /tmp for a frame from anyone in range
#  - the log is held to 64K whatever is written to it: 400 lines of -d's
#    frames, 116K, leave a file begun again and under the bound
#  - the security element's write refused after an association, as the
#    driver refuses it when the link has just gone, is a line and not
#    the end of the supplicant (it exited, and nothing starts one again
#    once its link has keyed); the next association is answered
#  - a handshake says the pairwise receive key was accepted (a write the
#    driver takes and does nothing with; it was "installed"), and the
#    transmit and group keys installed, as os/init looks for them
#  - a transmit key the driver refuses is not "installed"
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/ip/wpa.dis dis/tests/wpadrive.dis dis/auth/factotum.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

N=wpa_log_test.$$
W="$ROOT/tmp/$N"
rm -rf "$W"
mkdir -p "$W"
trap 'rm -rf "$W"' EXIT
E=/tmp/$N

cat > "$W/run.sh" <<ISH
load std
bind /dev/notquiterandom /dev/random
auth/factotum
echo 'key proto=wpapsk role=client essid=infernode !password=InfernodeTest' > /mnt/factotum/ctl
/dis/tests/wpadrive.dis $E/e1 $E/flood.log flood 3000 > $E/flood.out >[2=1]
/dis/tests/wpadrive.dis $E/e2 $E/cap.log cap 400 > $E/cap.out >[2=1]
/dis/tests/wpadrive.dis $E/e3 $E/failauth.log failauth > $E/failauth.out >[2=1]
/dis/tests/wpadrive.dis $E/e4 $E/handshake.log handshake > $E/handshake.out >[2=1]
/dis/tests/wpadrive.dis $E/e5 $E/txrefused.log txrefused > $E/txrefused.out >[2=1]
echo done > $E/done
echo halt > /dev/sysctl
ISH
with_timeout 110 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" </dev/null >"$W/log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
f() { cat "$W/$1" 2>/dev/null || true; }
has() { f "$1" | grep -q -- "$2"; }
size() { wc -c < "$W/$1" 2>/dev/null || echo 0; }
[ -f "$W/done" ] || { fail "the session did not finish: $(tail -5 "$W/log" | tr '\n' ' ')"; exit 1; }

# refused frames
has flood.out "after 3001 frames delivered" || fail "flood: the frames were not all read: $(f flood.out | tail -3)"
n=$(size flood.log)
if has flood.out "^wpa is running" && [ "$n" -lt 2000 ]; then
	pass "3000 refused frames are $n bytes of log ($(f flood.log | grep -c .) lines)"
else
	fail "3000 refused frames: $n bytes of log; $(f flood.out | grep '^wpa ')"
fi
for k in "key descriptor version 1" "truncated\|short" "bad MIC"; do
	c=$(f flood.log | grep -c "$k" || true)
	[ "$c" -ge 1 ] && [ "$c" -le 3 ] && pass "a kind of refusal is said, and not for each frame ($k: $c)" ||
		fail "refusals of a kind ($k): $c lines"
done

# the log's bound
n=$(size cap.log)
has cap.out "after 400 frames delivered" || fail "cap: the frames were not all read: $(f cap.out | tail -3)"
if [ "$n" -le 66000 ] && has cap.log "^wpa: the log is begun again: [0-9]* bytes had been written to it"; then
	pass "the log is held to 64K: $n bytes after 400 lines of 290, begun again once"
else
	fail "the log after 400 lines of 290 bytes: $n bytes; $(f cap.log | head -1 | cut -c1-100)"
fi

# the element's write refused
if has failauth.out "^wpa is running" && has failauth.out "^frame sent" &&
   has failauth.log "^wpa: auth: ether4330: the firmware did not report an association"; then
	pass "the security element refused after an association is a line, and the next association is answered"
else
	fail "the security element refused: $(f failauth.out | grep -v '^ctl' | tr '\n' ';') log: $(f failauth.log | tail -2 | tr '\n' ';')"
fi

# what is said of keys
if has handshake.log "^wpa: pairwise receive key accepted$" && has handshake.log "^wpa: pairwise transmit key installed$" &&
   has handshake.log "^wpa: group key 1 installed$" && ! has handshake.log "receive key installed"; then
	pass "a handshake: the receive key accepted, the transmit and group keys installed"
else
	fail "a handshake's log: $(f handshake.log | tr '\n' ';') $(f handshake.out | tail -3 | tr '\n' ';')"
fi
[ "$(f handshake.out | grep '^ctl write' | sed 's/ctl write: //' | tr '\n' ' ')" = "connect auth essid auth rxkey txkey rxkey1 " ] &&
	pass "and the driver was given the keys in order" || fail "ctl writes: $(f handshake.out | grep '^ctl write' | tr '\n' ' ')"
if has txrefused.log "^wpa: txkey: ether4330: the firmware refused the key" && ! has txrefused.log "transmit key installed" &&
   ! grep -q "ccmp:" "$W"/*.log; then
	pass "a transmit key the driver refuses is not installed, and no key is in any log"
else
	fail "a refused transmit key: $(f txrefused.log | tr '\n' ';')"
fi

[ $failed = 0 ] && echo "wpa_log_test: PASS"
exit $failed
