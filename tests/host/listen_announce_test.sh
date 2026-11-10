#!/bin/sh
#
# listen_announce_test.sh - a connection listen(1) made does not hold the
# address it was made on: with a connection still open, the listen that
# took it killed and another started on the same address is not refused
# ("address in use"), and both connections work.
#
# Each connection's process forked the listener's fd table, the
# announcement's ctl and listen files among it, and kept them for as long
# as it lasted.  A Raspberry Pi serving video to a Jetson that kept its
# mount could not have its listen restarted until the Jetson let go.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/listen.dis dis/export.dis dis/ps.dis dis/auth/createsignerkey.dis dis/auth/mkauthinfo.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

P="$ROOT/.listen_announce_test"
trap 'rm -rf "$P".*' EXIT
PORT=$((20000 + $$ % 20000))
ADDR="tcp!127.0.0.1!$PORT"

cat > "$P.sh" <<ISH
load std
ndb/cs
user=\`{cat /dev/user}
mkdir -p /tmp/lat/keys /tmp/lat/d /n/a /n/b
echo served > /tmp/lat/d/f
auth/createsignerkey -f /tmp/lat/keys/signer lat-signer > /dev/null
auth/mkauthinfo -k 'key=/tmp/lat/keys/signer' \$user /tmp/lat/keys/default
listen -k /tmp/lat/keys/default -a aes_256_cbc -a sha256 '$ADDR' {export /tmp/lat/d}
sleep 1
mount -k /tmp/lat/keys/default -C aes_256_cbc/sha256 '$ADDR' /n/a
cat /n/a/f > /.listen_announce_test.first
# the listener's own processes; the connection's is in Sh and Export
for p in \`{ps | grep ' Listen' | sed 's/^ *([0-9]+) .*/\1/'} { echo kill > /prog/\$p/ctl }
sleep 1
ps | grep ' Listen' > /.listen_announce_test.left
listen -k /tmp/lat/keys/default -a aes_256_cbc -a sha256 '$ADDR' {export /tmp/lat/d} >[2] /.listen_announce_test.again
sleep 1
mount -k /tmp/lat/keys/default -C aes_256_cbc/sha256 '$ADDR' /n/b
cat /n/b/f > /.listen_announce_test.second
cat /n/a/f > /.listen_announce_test.still
echo done > /.listen_announce_test.done
echo halt > /dev/sysctl
ISH
with_timeout 90 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.listen_announce_test.sh </dev/null >"$P.log" 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

# a refused listen leaves the address announced with nothing taking
# its connections: the second mount waits for ever, and the session
# does not finish
[ -f "$P.done" ] || fail "the session did not finish"
[ "$(cat "$P.first" 2>/dev/null)" = served ] || { echo "FAIL: the first connection read nothing: $(tail -3 "$P.log")"; exit 1; }
[ -s "$P.left" ] && fail "the first listen not killed: $(cat "$P.left")"

if [ -s "$P.again" ]; then
	fail "listen started again with a connection open: $(cat "$P.again")"
else
	echo "PASS: listen started again on the address while a connection it made is open"
fi
[ "$(cat "$P.second" 2>/dev/null)" = served ] && echo "PASS: the new listen takes a connection" ||
	fail "no connection through the new listen"
[ "$(cat "$P.still" 2>/dev/null)" = served ] && echo "PASS: the old connection still works" ||
	fail "the old connection broke"

if [ $failed = 0 ]; then echo "listen_announce_test: ALL PASS"; exit 0; fi
exit 1
