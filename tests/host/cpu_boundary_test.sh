#!/bin/sh
#
# An authenticated cpu(1) session receives only the files deliberately
# delegated at the two ends.  The node hides its boot mount and listener
# credential, disables fresh device attachment, and the caller exports only
# /dev unless -e names a wider tree.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }

PORT=${PORT:-17172}
TIMEOUT=${TIMEOUT:-90}
mkdir -p "$ROOT/tmp"
DRIVER="$ROOT/tmp/cpu_boundary_test.sh"
REMOTE="$ROOT/tmp/cpu_boundary_remote.sh"
ROOTREMOTE="$ROOT/tmp/cpu_boundary_root_remote.sh"
DEFAULTPORT=$((PORT + 1))
RCMDREMOTE="$ROOT/tmp/rcmd_boundary_remote.sh"

cat > "$REMOTE" <<'EOF'
load std
user=`{cat /dev/user}
if {ftest -e /n/dos/marker} {echo CARD-EXPOSED} {echo CARD-HIDDEN}
# A path overlay is not attenuation if the child can peel it off.
unmount /usr/$user/keyring/default >[2] /dev/null
key=`{cat /usr/$user/keyring/default}
if {~ $#key 0} {echo KEY-HIDDEN} {echo KEY-EXPOSED}
mkdir -p /usr/$user/keyring >[2] /dev/null
if {touch /usr/$user/keyring/default >[2] /dev/null} {echo KEYMASK-WRITABLE} {echo KEYMASK-SEALED}
unmount /mnt/factotum >[2] /dev/null
unmount /tmp/factotum >[2] /dev/null
if {ftest -e /mnt/factotum/server-key} {echo FACTOTUM-EXPOSED} {
	if {ftest -e /tmp/factotum/server-key} {echo FACTOTUM-EXPOSED} {echo FACTOTUM-HIDDEN}
}
if {touch /mnt/factotum/server-key >[2] /dev/null} {echo FACTOTUMMASK-WRITABLE} {echo FACTOTUMMASK-SEALED}
mkdir /tmp/factotum-rebind >[2] /dev/null
if {bind '#sfactotum' /tmp/factotum-rebind >[2] /dev/null} {echo FACTOTUM-REATTACHED} {echo FACTOTUM-DEVICE-BLOCKED}
if {ftest -e /n/client/tmp/cpu-client-secret} {echo CLIENT-EXPOSED} {echo CLIENT-HIDDEN}
if {cat '#c/sysctl' >[2] /dev/null} {echo DEVICE-ATTACHED} {echo DEVICE-BLOCKED}
if {ftest -e /n/client/dev/cons} {echo DEV-DELEGATED} {echo DEV-MISSING}
EOF

cat > "$ROOTREMOTE" <<'EOF'
# NEWNS makes the current directory the process's new root.  If peeling off
# the restricted export reveals the server instead of that empty root, this
# prints the boot marker.  In the safe case even cat is no longer reachable.
unmount /
cat /n/dos/marker
EOF

cat > "$RCMDREMOTE" <<'EOF'
load std
if {ftest -e /n/client/tmp/cpu-client-secret} {echo RCMD-CLIENT-EXPOSED} {echo RCMD-CLIENT-HIDDEN}
EOF

cat > "$DRIVER" <<EOF
load std
user=\`{cat /dev/user}
mkdir -p /tmp/cpubound/usr/\$user/keyring /tmp/cpubound/card /tmp/cpubound/factotum
bind -b /tmp/cpubound/usr /usr
auth/createsignerkey -f /usr/\$user/keyring/signer \$user-signer
auth/mkauthinfo -k 'key=signer' \$user /usr/\$user/keyring/default
echo BOOT-MARKER > /tmp/cpubound/card/marker
bind /tmp/cpubound/card /n/dos
echo SIGNING-ORACLE > /tmp/cpubound/factotum/server-key
bind /tmp/cpubound/factotum /mnt/factotum
mkdir -p /tmp/factotum
bind /tmp/cpubound/factotum /tmp/factotum
echo CALLER-MARKER > /tmp/cpu-client-secret
# This reaches rstyxd before its namespace mount and must not allocate the
# client-supplied size.  Keep it in this boundary test because the bound is
# part of the authenticated remote-execution protocol, not cpu's UI.
echo 2147483647 | auxi/rstyxd
echo LENGTH-TEST-DONE

# Authenticated dial/listen used to negotiate plaintext by default.  The first
# call explicitly asks for none and must never reach the command; the second
# uses both secure defaults and must deliver its payload.
rm /tmp/default-transport-payload >[2] /dev/null
listen 'tcp!*!$DEFAULTPORT' {cat > /tmp/default-transport-payload} &
sleep 2
dial -a none 'tcp!127.0.0.1!$DEFAULTPORT' echo NONE-PAYLOAD >[2] /dev/null
sleep 2
if {ftest -e /tmp/default-transport-payload} {echo DEFAULT-NONE-ACCEPTED} {echo DEFAULT-NONE-REJECTED}
dial 'tcp!127.0.0.1!$DEFAULTPORT' echo DEFAULT-SECURE-PAYLOAD
sleep 2
cat /tmp/default-transport-payload
listen -a aes_256_cbc -a sha256 'tcp!*!$PORT' auxi/rstyxd &
sleep 2

cpu 'tcp!127.0.0.1!$PORT' sh /tmp/cpu_boundary_remote.sh
# The older rcmd client speaks the same service protocol and must enforce the
# same caller-side capability boundary.
rcmd 'tcp!127.0.0.1!$PORT' sh /tmp/rcmd_boundary_remote.sh
echo RCMD-RETURNED
cpu 'tcp!127.0.0.1!$PORT' sh /tmp/cpu_boundary_root_remote.sh
echo ROOT-TEST-DONE

mkdir -p /tmp/cpubound/export/dev
bind /dev /tmp/cpubound/export/dev
echo EXPLICIT-MARKER > /tmp/cpubound/export/shared
cpu -e /tmp/cpubound/export 'tcp!127.0.0.1!$PORT' cat /n/client/shared
echo DONE
echo halt > /dev/sysctl
EOF

out=$(timeout "$TIMEOUT" "$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/cpu_boundary_test.sh 2>&1 < /dev/null)
rc=0
ok() {
	if echo "$out" | grep -q "^$2$"; then
		echo "PASS: $1"
	else
		echo "FAIL: $1"
		rc=1
	fi
}
notok() {
	if echo "$out" | grep -q "^$2$"; then
		echo "FAIL: $1"
		rc=1
	else
		echo "PASS: $1"
	fi
}
ok "the node's writable boot mount is absent" CARD-HIDDEN
ok "the listener credential is masked after loading" KEY-HIDDEN
ok "the server credential mask cannot be populated" KEYMASK-SEALED
ok "server factotum credential oracles are absent" FACTOTUM-HIDDEN
ok "the factotum mask cannot be populated" FACTOTUMMASK-SEALED
ok "the named factotum service cannot be reattached" FACTOTUM-DEVICE-BLOCKED
ok "the caller's non-device files are absent by default" CLIENT-HIDDEN
ok "rcmd also withholds caller non-device files by default" RCMD-CLIENT-HIDDEN
ok "rcmd returns after its restricted export ends" RCMD-RETURNED
ok "fresh kernel-device attachment is disabled" DEVICE-BLOCKED
ok "the caller's device tree is still delegated" DEV-DELEGATED
ok "an oversized command prefix is rejected before allocation" 'rstyxd: command line exceeds 64 KiB'
ok "the command-length rejection returns to the caller" LENGTH-TEST-DONE
ok "the authenticated listener default rejects plaintext" DEFAULT-NONE-REJECTED
ok "the dial/listen defaults negotiate protected transport" DEFAULT-SECURE-PAYLOAD
ok "the unmount-root probe returns control to the caller" ROOT-TEST-DONE
notok "unmounting the restricted root does not reveal the server" BOOT-MARKER
ok "-e explicitly delegates a wider caller tree" EXPLICIT-MARKER
ok "the test ran to the end" DONE
[ $rc -eq 0 ] || echo "$out" | grep -v sdl3 | tail -40
exit $rc
