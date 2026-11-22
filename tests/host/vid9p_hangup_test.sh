#!/bin/sh
#
# vid9p_hangup_test.sh - vid9p(4) ends with its client: when its 9P
# channel ends (the client hangs up, the mount goes), vid9p exits and its
# ticker with it.  Its serve loop's "break" left only the alt, so vid9p
# served nothing for ever, its ticker beside it (and under listen -A,
# which then ran a connection's command in the listener, no second
# client was served at all; it now serves each connection apart).
#
#  - two clients in turn through listen -A {vid9p clip}: each reads the
#    feed's fmt
#  - with both gone, no Vid9p process is left
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/vid9p.dis" ] || { echo "SKIP: dis/vid9p.dis not built"; exit 77; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 77; }

P="$ROOT/.vid9p_hangup_test"
trap 'rm -rf "$P".*' EXIT
PORT=$((20000 + $$ % 20000))
mkdir -p "$P.d"
# a clip of 8 grey frames, 64x48
python3 - "$P.d/c.y4m" <<'PY'
import sys
w, h = 64, 48
with open(sys.argv[1], 'wb') as f:
    f.write(b'YUV4MPEG2 W%d H%d F10:1 Ip A1:1 C420jpeg\n' % (w, h))
    for i in range(8):
        f.write(b'FRAME\n' + bytes([100 + i]) * (w*h) + bytes([128]) * (2*(w//2)*(h//2)))
PY

cat > "$P.sh" <<ISH
load std
ndb/cs
mkdir -p /n/v1 /n/v2
listen -A tcp!127.0.0.1!$PORT {/dis/vid9p.dis /.vid9p_hangup_test.d/c.y4m}
sleep 1
mount -A tcp!127.0.0.1!$PORT /n/v1
cat /n/v1/0/fmt > /.vid9p_hangup_test.first
unmount /n/v1
sleep 1
mount -A tcp!127.0.0.1!$PORT /n/v2
cat /n/v2/0/fmt > /.vid9p_hangup_test.second
unmount /n/v2
sleep 1
ps | grep -i vid9p > /.vid9p_hangup_test.ps
echo done > /.vid9p_hangup_test.done
echo halt > /dev/sysctl
ISH
with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.vid9p_hangup_test.sh </dev/null >"$P.log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

[ "$(cat "$P.first" 2>/dev/null)" = "64 48 i420 10" ] && echo "PASS: the first client reads the feed" ||
	fail "the first client read '$(cat "$P.first" 2>/dev/null)': $(tail -3 "$P.log")"
if [ ! -f "$P.done" ]; then
	fail "the session did not finish: the second client was never served (vid9p outlived the first)"
else
	[ "$(cat "$P.second" 2>/dev/null)" = "64 48 i420 10" ] && echo "PASS: a second client is served once the first has gone" ||
		fail "the second client read '$(cat "$P.second" 2>/dev/null)'"
	[ -s "$P.ps" ] && fail "vid9p left behind its clients: $(cat "$P.ps")" ||
		echo "PASS: no vid9p process left once its clients have gone"
fi

if [ $failed = 0 ]; then echo "vid9p_hangup_test: ALL PASS"; exit 0; fi
exit 1
