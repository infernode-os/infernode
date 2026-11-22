#!/bin/sh
#
# listen_plain_test.sh - listen -A serves its connections at once, each
# in a process of its own, as an authenticated listen does: with one
# client's export still open, a second client is served; the command
# sees $net; and when the clients go their exports go with them.
#
# listen -A ran each connection's command in the listener, so a
# connection arriving while one was open was not taken until that one
# ended. A Pi 5 soak's sink (listen -A ... {cat > /dev/null}) left a
# push's data unread for 33 to 57 s behind connections held open by
# another load.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/listen.dis dis/export.dis dis/ps.dis dis/dial.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

P="$ROOT/.listen_plain_test"
trap 'rm -rf "$P".*' EXIT
PORT=$((20000 + $$ % 20000))
ADDR="tcp!127.0.0.1!$PORT"
ADDR2="tcp!127.0.0.1!$((PORT + 1))"

cat > "$P.sh" <<ISH
load std
ndb/cs
mkdir -p /tmp/lpt/d /n/a /n/b
echo served > /tmp/lpt/d/f
listen -A '$ADDR' {export /tmp/lpt/d}
listen -A '$ADDR2' {echo \$net}
sleep 1
mount -A '$ADDR' /n/a
cat /n/a/f > /.listen_plain_test.first
# /n/a's export is still running: the second client must not wait for it
mount -A '$ADDR' /n/b
cat /n/b/f > /.listen_plain_test.second
cat /n/a/f > /.listen_plain_test.still
dial -A '$ADDR2' {cat > /.listen_plain_test.net}
unmount /n/a
unmount /n/b
sleep 2
ps | grep ' Export' > /.listen_plain_test.left
echo done > /.listen_plain_test.done
echo halt > /dev/sysctl
ISH
with_timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.listen_plain_test.sh </dev/null >"$P.log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

[ "$(cat "$P.first" 2>/dev/null)" = served ] || { echo "FAIL: the first client read nothing: $(tail -3 "$P.log")"; exit 1; }
# served one at a time, the second mount waits for the first's export,
# which never ends: the session does not finish
if [ ! -f "$P.done" ]; then
	fail "the session did not finish: a second client was not served while the first's export ran"
else
	[ "$(cat "$P.second" 2>/dev/null)" = served ] && echo "PASS: a second client is served while the first's export runs" ||
		fail "the second client read '$(cat "$P.second" 2>/dev/null)'"
	[ "$(cat "$P.still" 2>/dev/null)" = served ] && echo "PASS: the first client still works beside it" ||
		fail "the first client broke"
	case "$(cat "$P.net" 2>/dev/null)" in
	/net/tcp/[0-9]*) echo "PASS: the command sees \$net, its connection's directory" ;;
	*) fail "\$net in the command was '$(cat "$P.net" 2>/dev/null)'" ;;
	esac
	[ -s "$P.left" ] && fail "exports left behind their clients: $(cat "$P.left")" ||
		echo "PASS: each connection's export ends with its client"
fi

if [ $failed = 0 ]; then echo "listen_plain_test: ALL PASS"; exit 0; fi
exit 1
