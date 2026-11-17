#!/bin/sh
#
# registry_test.sh - the registry served as svc/registry and registry(4)
# now serve it: styxlisten running ndb/registry, so that each caller has
# an attach of its own in the name it authenticated with.
#
# A service is its registrant's to change or remove, by the user name of
# the attach.  The registry used to be mounted once and that mount
# exported: every caller on the network was then the user who mounted
# it, and any of them could rewrite another's service (the address its
# clients go on to dial) or remove it.
#
# One emu: a signer and three certificates made for the test (the
# listener's and two callers'), styxlisten on the loopback with
# ndb/registry, mounted twice with the two callers' certificates.  The
# first registers a service; the second sees it, owned by the first, and
# can neither write it nor remove it, nor open it to be removed at
# close; the first changes and removes it.  Then the registry mounted
# once and exported by listen, mounted by the second caller: there it
# acts as the mounter, which registry(4) now says.
#
set -e
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
for f in dis/styxlisten.dis dis/listen.dis dis/mount.dis dis/ndb/registry.dis dis/auth/createsignerkey.dis dis/auth/mkauthinfo.dis; do
	[ -f "$ROOT/$f" ] || { echo "SKIP: $f not built"; exit 77; }
done

P="$ROOT/.registry_test"
trap 'rm -f "$P".sh "$P".out; rm -rf "$ROOT/tmp/regh"' EXIT
PORT=$((20000 + $$ % 20000))
PORT2=$((PORT + 1))

cat > "$P.sh" <<ISH
load std
ndb/cs
user=\`{cat /dev/user}
out=/.registry_test.out
mkdir -p /tmp/regh/keys /tmp/regh/a /tmp/regh/b /tmp/regh/m /tmp/regh/x
auth/createsignerkey -f /tmp/regh/keys/signer regh-signer
auth/mkauthinfo -k 'key=/tmp/regh/keys/signer' \$user /tmp/regh/keys/default
auth/mkauthinfo -k 'key=/tmp/regh/keys/signer' regalice /tmp/regh/keys/alice
auth/mkauthinfo -k 'key=/tmp/regh/keys/signer' regbob /tmp/regh/keys/bob
styxlisten -k /tmp/regh/keys/default tcp!127.0.0.1!$PORT ndb/registry
sleep 1
mount -c -k /tmp/regh/keys/alice tcp!127.0.0.1!$PORT /tmp/regh/a
mount -c -k /tmp/regh/keys/bob tcp!127.0.0.1!$PORT /tmp/regh/b
echo R mounted \`{ls /tmp/regh/a >[2=1]} > \$out
echo -n 'tcp!alice!1 persist 1 addr 10.0.0.1' > /tmp/regh/a/new
echo R seen \`{cat /tmp/regh/b/index >[2=1]} >> \$out
echo R owner \`{ls -l '/tmp/regh/b/tcp!alice!1' >[2=1]} >> \$out
sh -c 'echo -n ''addr 6.6.6.6'' > ''/tmp/regh/b/tcp!alice!1''' >[2] /dev/null
echo R bobwrite \`{cat /tmp/regh/b/index >[2=1]} >> \$out
rm '/tmp/regh/b/tcp!alice!1' >[2] /dev/null
echo R bobremove \`{cat /tmp/regh/b/index >[2=1]} >> \$out
echo -n 'addr 10.0.0.2' > '/tmp/regh/a/tcp!alice!1'
echo R alicewrite \`{cat /tmp/regh/b/index >[2=1]} >> \$out
echo -n 'tcp!bob!1 persist 1' > /tmp/regh/b/new
rm '/tmp/regh/a/tcp!bob!1' >[2] /dev/null
rm '/tmp/regh/a/tcp!alice!1'
echo R aliceremove \`{cat /tmp/regh/a/index >[2=1]} >> \$out
# the registry mounted once and that mount exported
mount -A -c {ndb/registry} /tmp/regh/m
echo -n 'tcp!mounter!1 persist 1 addr 10.0.0.1' > /tmp/regh/m/new
listen -k /tmp/regh/keys/default tcp!127.0.0.1!$PORT2 {export /tmp/regh/m&}
sleep 1
mount -c -k /tmp/regh/keys/bob tcp!127.0.0.1!$PORT2 /tmp/regh/x
sh -c 'echo -n ''addr 6.6.6.6'' > ''/tmp/regh/x/tcp!mounter!1''' >[2] /dev/null
echo R exported \`{cat /tmp/regh/m/index >[2=1]} >> \$out
echo R done >> \$out
echo halt > /dev/sysctl
ISH

with_timeout 90 "$EMU" -c1 -r"$ROOT" /dis/sh.dis /.registry_test.sh </dev/null >/dev/null 2>&1 || true

failed=0
fail() { echo "FAIL: $*"; failed=1; }
line() { printf '%s\n' "$out" | sed -n "s/^R $1 *//p"; }
want() {
	got=$(line "$1")
	if [ "$got" = "$2" ]; then echo "PASS: $3"; else fail "$3: got '$got', want '$2'"; fi
}

out=$(cat "$P.out" 2>/dev/null || true)
printf '%s\n' "$out" | grep -q '^R done$' || { echo "FAIL: the script did not finish"; printf '%s\n' "$out"; exit 1; }
case "$(line mounted)" in
*index*new*|*new*index*) echo "PASS: ndb/registry behind styxlisten, mounted with two callers' certificates" ;;
*) fail "the registry did not mount: '$(line mounted)'" ;;
esac
want seen 'tcp!alice!1 addr 10.0.0.1 persist 1' "the second caller sees what the first registered"
case "$(line owner)" in
*" regalice "*) echo "PASS: the service is owned by the name its registrant authenticated with" ;;
*) fail "the service's owner is not the first caller's name: '$(line owner)'" ;;
esac
want bobwrite 'tcp!alice!1 addr 10.0.0.1 persist 1' "the second caller cannot rewrite it"
want bobremove 'tcp!alice!1 addr 10.0.0.1 persist 1' "nor remove it"
want alicewrite 'tcp!alice!1 addr 10.0.0.2 persist 1' "its owner changes it"
want aliceremove 'tcp!bob!1 persist 1' "its owner removes it, and cannot remove the second caller's"
want exported 'tcp!mounter!1 addr 6.6.6.6 persist 1' "through an export of a mount every caller is the mounter (as registry(4) says)"

if [ $failed = 0 ]; then echo "registry_test: ALL PASS"; exit 0; fi
exit 1
