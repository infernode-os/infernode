#!/bin/sh
#
# vid9p_ctl_test.sh - what a 9P client of a video feed can do to its
# server.
#
# vid9p's ctl took "play <cmd> [arg...]", which ran a host command, and
# "open <file>" and "replay <file>", which read any file the server
# could name; ctl was mode 666 and is the file every viewer writes to
# drive the playhead, and videnc(1) exports the feed to other machines.
# A client given a picture ran commands on the host as the emulator's
# user.  The source is now the command line's alone.
#
#  - through an export of the mount, as a remote viewer has it: "play
#    <cmd>", "open" and "replay" are refused and the host command is not
#    run; a command that is none, and a seek that is no number, are
#    errors (every write was answered as done); the transport verbs
#    still drive the playhead
#  - ctl is not writable by others
#  - a source from the command line still plays: -c (a host command's
#    y4m output), -r (a file replayed)
#  - a header saying 65536 by 65536 (a frame size of -2^31) is refused,
#    static and replayed, and the server answers
#  - a file past what an array holds (3GB, sparse) is refused by its
#    length and the server answers (the length was cut to an int: a
#    negative size, an exception before the mount was served)
#  - with no /dev/null to give it for standard input, a -c command is
#    not run (it went on with the 9P channel as its input)
#  - a client that is not a mount (listen -A {vid9p ...}) reading with a
#    count of ff ff ff ff is answered with an error, and its server is
#    gone with it (the slice raised in the serve loop, which left the
#    pacer, the feeder and the ticker behind for each connection)
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/vid9p.dis" ] || { echo "SKIP: dis/vid9p.dis not built"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }
PYABS="$(command -v python3)"

N=vid9p_ctl_test.$$
W="$ROOT/tmp/$N"
rm -rf "$W"
mkdir -p "$W"
EMUPID=
trap '[ -n "$EMUPID" ] && kill $EMUPID 2>/dev/null; [ -n "${KEEP:-}" ] || rm -rf "$W"' EXIT
E=/tmp/$N
PORT=$((20000 + $$ % 20000))
PORT2=$((PORT + 1))

# a clip of 8 grey frames, 64x48, and two files whose headers lie
python3 - "$W" <<'PY'
import sys
d = sys.argv[1]
w, h = 64, 48
with open(d + '/c.y4m', 'wb') as f:
    f.write(b'YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n' % (w, h))
    for i in range(8):
        f.write(b'FRAME\n' + bytes([100 + i]) * (w*h) + bytes([128]) * (2*(w//2)*(h//2)))
with open(d + '/big.y4m', 'wb') as f:
    f.write(b'YUV4MPEG2 W65536 H65536 F10:1 Ip A1:1 C420jpeg\n')
    f.write(b'FRAME\n' + bytes(4096))
try:
    with open(d + '/huge.y4m', 'wb') as f:
        f.write(b'YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n' % (w, h))
        f.seek(3 << 30)
        f.write(b'0')
except OSError:
    pass
with open(d + '/src.sh', 'w') as f:
    f.write('touch %s/RAN\ncat %s/c.y4m\n' % (d, d))
PY
mkdir -p "$W/empty"
HUGE='#'
if [ -f "$W/huge.y4m" ] && [ "$(wc -c < "$W/huge.y4m")" -gt 3000000000 ]; then HUGE=; fi

cat > "$W/run.sh" <<ISH
load std
ndb/cs
mkdir -p /n/v /n/x /n/live /n/rep /n/big /n/bigr /n/nonull /n/huge
mount {vid9p $E/c.y4m} /n/v
listen -A tcp!127.0.0.1!$PORT {export /n/v}
sleep 1
mount -A tcp!127.0.0.1!$PORT /n/x
ls -l /n/x/0/ctl > $E/ls
cat /n/x/0/ctl > $E/help
echo 'play touch $W/PWNED' > /n/x/0/ctl >[2] $E/e.play
echo 'open $E/c.y4m' > /n/x/0/ctl >[2] $E/e.open
echo 'replay $E/c.y4m' > /n/x/0/ctl >[2] $E/e.replay
echo bogus > /n/x/0/ctl >[2] $E/e.bogus
echo seek abc > /n/x/0/ctl >[2] $E/e.seek
echo pause > /n/x/0/ctl >[2] $E/e.pause
cat /n/x/0/status > $E/st.pause
echo seek 300 > /n/x/0/ctl >[2] $E/e.seek300
cat /n/x/0/status > $E/st.seek
echo seek 999999999 > /n/x/0/ctl >[2] $E/e.seekfar
cat /n/x/0/status > $E/st.seekfar
echo play > /n/x/0/ctl >[2] $E/e.resume
cat /n/x/0/status > $E/st.play
sleep 1
cat /n/x/0/status > $E/st.after
mount {vid9p -w 2 -c $PYABS $ROOT/tests/host/vision/live.py $W/c.y4m} /n/live
mount {vid9p -w 2 -r $E/c.y4m} /n/rep
sleep 1
cat /n/live/0/status > $E/st.live
cat /n/rep/0/status > $E/st.rep
mount {vid9p $E/big.y4m} /n/big
cat /n/big/0/status > $E/st.big
mount {vid9p -r $E/big.y4m} /n/bigr
cat /n/bigr/0/status > $E/st.bigr
@{pctl forkns; bind $E/empty /dev; mount {vid9p -c /bin/sh $W/src.sh} /n/nonull; cat /n/nonull/0/status > $E/st.nonull}
$HUGE mount {vid9p $E/huge.y4m} /n/huge
$HUGE cat /n/huge/0/status > $E/st.huge
unmount /n/live
unmount /n/rep
unmount /n/big
unmount /n/bigr
listen -A tcp!127.0.0.1!$PORT2 {/dis/vid9p.dis -w 2 -r $E/c.y4m}
sleep 1
ps | grep -i vid9p > $E/ps.before
echo ready > $E/ready
while {! ftest -e $E/go} {sleep 1}
sleep 1
ps | grep -i vid9p > $E/ps.after
echo done > $E/done
echo halt > /dev/sysctl
ISH
with_timeout 90 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "$E/run.sh" </dev/null >"$W/log" 2>&1 &
EMUPID=$!
for i in $(seq 1 60); do [ -f "$W/ready" ] && break; sleep 0.5; done
if [ -f "$W/ready" ]; then
	python3 -I "$ROOT/tests/host/vid9p/raw9p.py" $PORT2 0xffffffff 2 0/frame > "$W/raw" 2>&1 || true
fi
echo go > "$W/go"
wait $EMUPID 2>/dev/null || true
EMUPID=

failed=0
fail() { echo "FAIL: $*"; failed=1; }
pass() { echo "PASS: $*"; }
key() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" "$W/$1" 2>/dev/null; }

if [ ! -f "$W/done" ]; then
	fail "the session did not finish: $(grep -v '^$' "$W/log" | tail -5 | tr '\n' ' ')"
fi

# the source verbs, from a client of the export
if [ -e "$W/PWNED" ]; then
	fail "\"play <cmd>\" written to ctl by a client of the export ran the command on the host"
else
	pass "\"play <cmd>\" runs no host command"
fi
for v in play open replay; do
	if grep -q 'source is set when vid9p starts' "$W/e.$v" 2>/dev/null; then
		pass "$v with a source is refused: $(sed 's/.*vid9p: //' "$W/e.$v" | head -1)"
	else
		fail "$v with a source was not refused: '$(cat "$W/e.$v" 2>/dev/null)'"
	fi
done
grep -q 'unknown command' "$W/e.bogus" 2>/dev/null && pass "a command that is none is an error" ||
	fail "a command that is none was answered as done: '$(cat "$W/e.bogus" 2>/dev/null)'"
[ -s "$W/e.seek" ] && pass "a seek that is no number is an error" ||
	fail "a seek that is no number was answered as done"
case "$(cat "$W/help" 2>/dev/null)" in
*open*|*replay*|*cmd*) fail "ctl's own text still offers a source verb: $(tr '\n' ' ' < "$W/help")" ;;
*seek*) pass "ctl reads back the transport verbs alone" ;;
*) fail "ctl reads back '$(cat "$W/help" 2>/dev/null)'" ;;
esac

# the transport verbs still work
for v in pause seek300 seekfar resume; do
	[ -s "$W/e.$v" ] && fail "transport verb refused ($v): $(cat "$W/e.$v")"
done
[ "$(key st.pause state)" = paused ] && pass "pause pauses" || fail "after pause: $(cat "$W/st.pause" 2>/dev/null)"
[ "$(key st.seek pos)" = 3 ] && pass "seek 300 is frame 3 at 10 a second" || fail "after seek 300: $(cat "$W/st.seek" 2>/dev/null)"
[ "$(key st.seekfar pos)" = 7 ] && pass "a seek past the end is the last frame" || fail "after seek 999999999: $(cat "$W/st.seekfar" 2>/dev/null)"
[ "$(key st.play state)" = playing ] && pass "play resumes" || fail "after play: $(cat "$W/st.play" 2>/dev/null)"
case "$(cat "$W/st.after" 2>/dev/null)" in
ready*w=64*h=48*frames=8*) pass "the feed is the one the server was started on" ;;
*) fail "the feed after the refused verbs: $(cat "$W/st.after" 2>/dev/null)" ;;
esac

# ctl's mode
case "$(cat "$W/ls" 2>/dev/null)" in
--rw-rw-r--*) pass "ctl is not writable by others ($(cut -d' ' -f1 "$W/ls"))" ;;
*) fail "ctl's mode: $(cat "$W/ls" 2>/dev/null)" ;;
esac

# sources from the command line
n=$(key st.live frames)
case "$(cat "$W/st.live" 2>/dev/null)" in
streaming*eof=0*) [ -n "$n" ] && [ "$n" -ge 5 ] && pass "-c: a host command's output is a live feed ($n frames)" ||
	fail "-c: frames=$n after a second" ;;
*) fail "-c: $(cat "$W/st.live" 2>/dev/null)" ;;
esac
n=$(key st.rep frames)
case "$(cat "$W/st.rep" 2>/dev/null)" in
streaming*eof=0*) [ -n "$n" ] && [ "$n" -ge 5 ] && pass "-r: a file replayed is a live feed ($n frames)" ||
	fail "-r: frames=$n after a second" ;;
*) fail "-r: $(cat "$W/st.rep" 2>/dev/null)" ;;
esac

# a header that lies
for f in big bigr; do
	case "$(cat "$W/st.$f" 2>/dev/null)" in
	"no source"*frames=0*) pass "a 65536 by 65536 header is no source ($f) and the server answers" ;;
	*) fail "a 65536 by 65536 header ($f): status '$(cat "$W/st.$f" 2>/dev/null)'" ;;
	esac
done

# a file too long to hold
if [ -z "$HUGE" ]; then
	case "$(cat "$W/st.huge" 2>/dev/null)" in
	"no source"*frames=0*) pass "a 3GB file is refused by its length and the server answers" ;;
	*) fail "a 3GB file: status '$(cat "$W/st.huge" 2>/dev/null)' $(grep -i 'broken\|vid9p:' "$W/log" | tail -2 | tr '\n' ' ')" ;;
	esac
else
	echo "SKIP: no sparse 3GB file here"
fi

# no /dev/null for a host command's input
if [ -e "$W/RAN" ]; then
	fail "with no /dev/null a -c command was run, the 9P channel its standard input"
else
	case "$(cat "$W/st.nonull" 2>/dev/null)" in
	"no source"*) pass "with no /dev/null a -c command is not run, and the server answers" ;;
	*) fail "with no /dev/null: status '$(cat "$W/st.nonull" 2>/dev/null)'" ;;
	esac
fi

# a client that is not a mount
if [ ! -f "$W/raw" ]; then
	fail "the raw client did not run"
else
	if [ "$(grep -c '^error' "$W/raw")" = 2 ]; then
		pass "a read with a count of ff ff ff ff is an error: $(head -1 "$W/raw")"
	else
		fail "a read with a count of ff ff ff ff: $(tr '\n' ';' < "$W/raw")"
	fi
	if [ -f "$W/done" ]; then
		b=$(wc -l < "$W/ps.before"); a=$(wc -l < "$W/ps.after")
		[ "$a" -le "$b" ] && pass "its servers went with their clients ($b vid9p processes before, $a after)" ||
			fail "vid9p processes left by the raw clients: $b before, $a after: $(tr '\n' ';' < "$W/ps.after" | cut -c1-300)"
	fi
fi

if [ $failed = 0 ]; then echo "vid9p_ctl_test: ALL PASS"; exit 0; fi
exit 1
