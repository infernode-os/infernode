#!/bin/sh
#
# ssl_killedcall_test.sh - a Prog killed in a 9P call over an encrypted
# mount does not take the mount down with it.  The killed call's flush
# goes out through devssl, and the kill, still pending, interrupted its
# write before a byte of it was sent; devssl hung the connection up for
# any error in a write, so every other user of the mount was refused
# ("inappropriate use of fd") from then on.  vision(4) restarting a
# session's follower (place gpu to dla0) on a feed mounted from another
# machine did exactly this.
#
# One emu: a pipe exported by listen with certificates (a signer and
# its certificate made for the test) and AES/SHA-256, mounted back over
# the loopback; a reader blocked in the pipe is killed; the mount must
# still answer.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/listen.dis dis/export.dis dis/mount.dis dis/auth/createsignerkey.dis dis/auth/mkauthinfo.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

P="$ROOT/.ssl_killedcall_test"
trap 'rm -f "$P".sh "$P".out' EXIT
PORT=$((20000 + $$ % 20000))

cat > "$P.sh" <<ISH
load std
ndb/cs
user=\`{cat /dev/user}
mkdir -p /tmp/sslk/keys /tmp/sslk/pipe
auth/createsignerkey -f /tmp/sslk/keys/signer sslk-signer
auth/mkauthinfo -k 'key=/tmp/sslk/keys/signer' \$user /tmp/sslk/keys/default
bind '#|' /tmp/sslk/pipe
listen -k /tmp/sslk/keys/default -a aes_256_cbc -a sha256 tcp!127.0.0.1!$PORT {export /tmp/sslk/pipe}
sleep 1
mkdir -p /n/sslk
mount -k /tmp/sslk/keys/default -C aes_256_cbc/sha256 tcp!127.0.0.1!$PORT /n/sslk
echo R before \`{ls /n/sslk >[2=1]} > /.ssl_killedcall_test.out
cat /n/sslk/data1 > /dev/null &
pid=\$apid
sleep 1
echo kill > /prog/\$pid/ctl
sleep 1
echo R after \`{ls /n/sslk >[2=1]} >> /.ssl_killedcall_test.out
echo R done >> /.ssl_killedcall_test.out
echo halt > /dev/sysctl
ISH

timeout 60 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.ssl_killedcall_test.sh </dev/null >/dev/null 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }

out=$(cat "$P.out" 2>/dev/null || true)
printf '%s\n' "$out" | grep -q '^R done$' || { echo "FAIL: the script did not finish"; printf '%s\n' "$out"; exit 1; }
before=$(printf '%s\n' "$out" | sed -n 's/^R before //p')
after=$(printf '%s\n' "$out" | sed -n 's/^R after //p')
case "$before" in
*data*) echo "PASS: the pipe mounted over AES/SHA-256 with certificates ($before)" ;;
*) fail "the mount did not come up: '$before'" ;;
esac
[ -n "$after" ] && [ "$after" = "$before" ] && echo "PASS: the mount still answers after a reader in it was killed" ||
	fail "after a reader in it was killed the mount gives '$after', want '$before'"

if [ $failed = 0 ]; then echo "ssl_killedcall_test: ALL PASS"; exit 0; fi
exit 1
