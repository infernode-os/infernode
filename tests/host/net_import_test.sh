#!/bin/sh
#
# net_import_test.sh - the VPN example in docs/DESIGN-PRINCIPLES.md ("Compose
# before you write") does what the document says: another machine's
# /net, exported and mounted, bound over this one's, carries every
# connection dialled after the bind, with no software written.
#
# Two emulators on the loopback, an "office" and a client, the mount
# authenticated and encrypted (listen and mount's AES-256-GCM default):
#  - after the bind a connection the client dials is in the office's
#    /net/tcp, and the client's own stack (kept at /n/localnet) has only
#    the mount;
#  - with the office gone, /net answers nothing and the kept stack still dials;
#  - a second office, mounted over /net again through /n/localnet by
#    address, carries the client's connections once more.
#
# The document's example is the reason for the test: if it stops being
# true, the example is wrong, and agents are told to build it.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/listen.dis dis/export.dis dis/mount.dis dis/ndb/cs.dis dis/auth/createsignerkey.dis dis/auth/mkauthinfo.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

D="$ROOT/.net_import_test.d"
rm -rf "$D"; mkdir -p "$D"
trap 'rm -rf "$D" "$ROOT"/.net_import_test.*.sh' EXIT
EXPORT=$(freeport)
DEST=$(freeport)
[ "$EXPORT" != "$DEST" ] || DEST=$((DEST + 1))

# The office: its /net exported on one port, and on another a listener
# that holds each connection open for a while, for the client to dial.
# Run twice; the first run makes the keys both sides use.
cat > "$ROOT/.net_import_test.office.sh" <<ISH
load std
d=/.net_import_test.d
n=\$1
if {! ftest -e \$d/key} {
	user=\`{cat /dev/user}
	auth/createsignerkey -f \$d/signer nit-signer > /dev/null
	auth/mkauthinfo -k 'key='^\$d/signer \$user \$d/key
}
listen -k \$d/key 'tcp!127.0.0.1!$EXPORT' {export /net}
listen -k \$d/key 'tcp!127.0.0.1!$DEST' {sleep 8}
sleep 1
echo ready > \$d/ready.\$n
while {! ftest -e \$d/dialled.\$n} {sleep 1}
cat /net/tcp/*/remote > \$d/office.\$n
echo halt > /dev/sysctl
ISH

cat > "$ROOT/.net_import_test.client.sh" <<ISH
load std
d=/.net_import_test.d
while {! ftest -e \$d/ready.1} {sleep 1}
mount -k \$d/key 'tcp!127.0.0.1!$EXPORT' /n/office
bind '#I' /n/localnet
bind /n/office /net
ls /net > \$d/net.1
dial -k \$d/key 'tcp!localhost!$DEST' {sleep 6} &
sleep 2
cat /n/localnet/tcp/*/remote > \$d/local.1
echo dialled > \$d/dialled.1

# the office goes; /net goes with it
sleep 3
ls /net/tcp > \$d/hung >[2=1]
while {! ftest -e \$d/ready.2} {sleep 1}
dial -k \$d/key '/n/localnet/tcp!127.0.0.1!$DEST' {echo dialled >[1=2]} >[2] \$d/localdial

# back over /net through the kept stack, by address
mount -k \$d/key '/n/localnet/tcp!127.0.0.1!$EXPORT' /net
dial -k \$d/key 'tcp!localhost!$DEST' {sleep 6} &
sleep 2
cat /n/localnet/tcp/*/remote > \$d/local.2
echo dialled > \$d/dialled.2
sleep 1
echo done > \$d/done
echo halt > /dev/sysctl
ISH

with_timeout 60 "$EMU" -c1 -r"$ROOT" sh -l /.net_import_test.office.sh 1 </dev/null >"$D/office1.log" 2>&1 &
o1=$!
with_timeout 90 "$EMU" -c1 -r"$ROOT" sh -l /.net_import_test.client.sh </dev/null >"$D/client.log" 2>&1 &
c=$!
wait $o1 || true
with_timeout 60 "$EMU" -c1 -r"$ROOT" sh -l /.net_import_test.office.sh 2 </dev/null >"$D/office2.log" 2>&1 &
o2=$!
wait $c || true
wait $o2 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
has() { grep -q "127.0.0.1!$2\$" "$D/$1" 2>/dev/null; }

[ -f "$D/done" ] || fail "the client did not finish: $(tail -3 "$D/client.log" 2>/dev/null)"

grep -q '^/net/cs$' "$D/net.1" 2>/dev/null && echo "PASS: /net after the bind has a connection server" ||
	fail "/net after the bind: $(cat "$D/net.1" 2>/dev/null)"

if has office.1 "$DEST" && ! has local.1 "$DEST"; then
	echo "PASS: a connection dialled after the bind leaves from the office"
else
	fail "the dialled connection: office has [$(tr '\n' ' ' < "$D/office.1" 2>/dev/null)], client's own stack [$(tr '\n' ' ' < "$D/local.1" 2>/dev/null)]"
fi
has local.1 "$EXPORT" && echo "PASS: the client's own stack carries the mount" ||
	fail "the mount's connection is not on the client's own stack: $(tr '\n' ' ' < "$D/local.1" 2>/dev/null)"

# the words depend on how the far end went ("hungup", "inappropriate use
# of fd"); what matters is that /net answers nothing
if grep -q 'clone failed' "$D/hung" 2>/dev/null && ! grep -q '/net/tcp/clone' "$D/hung"; then
	echo "PASS: with the office gone, /net is gone with it"
else
	fail "with the office gone, /net: $(cat "$D/hung" 2>/dev/null)"
fi
grep -q '^dialled$' "$D/localdial" 2>/dev/null && echo "PASS: the stack kept at /n/localnet still dials" ||
	fail "dialling through /n/localnet: $(cat "$D/localdial" 2>/dev/null)"

if has office.2 "$DEST" && ! has local.2 "$DEST"; then
	echo "PASS: mounted over /net again through /n/localnet, the office carries the connections"
else
	fail "after the remount: office has [$(tr '\n' ' ' < "$D/office.2" 2>/dev/null)], client's own stack [$(tr '\n' ' ' < "$D/local.2" 2>/dev/null)]"
fi

if [ $failed = 0 ]; then echo "net_import_test: ALL PASS"; exit 0; fi
exit 1
