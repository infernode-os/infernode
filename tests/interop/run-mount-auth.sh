#!/bin/bash
#
# Real production-path node-auth test: exercises the actual CLI + on-disk
# keyfile flow that nodes use, not the in-emu auth->client/server shortcut.
#
# For each signer algorithm it runs, inside one emu over loopback:
#   auth/createsignerkey -a <alg> -f <keyfile>      (writes a signer keyfile)
#   styxlisten -a aes_256_cbc -a sha256 -k <keyfile> tcp!*!PORT export /lib
#                                                   (cert-auth + ssl server)
#   mount -k <keyfile> -C 'aes_256_cbc sha256' tcp!127.0.0.1!PORT /n/remote
#                                                   (cert-auth + ssl client)
# then reads a file through the encrypted mount and cmp's it byte-for-byte.
#
# Also checks enforcement: an anonymous `mount -A` against the cert-requiring
# server must be rejected.
#
# The same path backs `mount -k <keyfile> tcp!host!5640 /mnt/llm` against the
# headless LLM daemon (serve-llm.sh).
#
# Usage:  run-mount-auth.sh [alg ...]      (default: ed25519 mldsa65)
# Exit:   0 = all pass, 1 = a failure, 2 = skipped (no emu)
#
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ALGS=("$@"); [ ${#ALGS[@]} -eq 0 ] && ALGS=(ed25519 mldsa65)

EMU=""
for c in "$ROOT/emu/Linux/o.emu" "$ROOT/emu/MacOSX/o.emu"; do
	[ -x "$c" ] && { EMU="$c"; break; }
done
[ -n "$EMU" ] || { echo "run-mount-auth: no emu binary under $ROOT" >&2; exit 2; }

mkdir -p "$ROOT/tmp" "$ROOT/n"
XFER="/ndb/inferno"          # a stable file present under /lib
SRC="$ROOT/lib$XFER"
rc_run() {                   # $1 = rc text  -> emu stdout (137-at-teardown ignored)
	local rc="$ROOT/tmp/mountauth-$$.rc"
	printf '%s\n' "$1" > "$rc"
	timeout 90 "$EMU" -c1 -r"$ROOT" /dis/sh.dis "/tmp/$(basename "$rc")" 2>&1
	rm -f "$rc"
}

fails=0
port=19650

for alg in "${ALGS[@]}"; do
	port=$((port+1))
	key="/tmp/mauth-$port"
	pulled="/tmp/mauth-pulled-$port"
	mnt="/n/mauth$port"
	mkdir -p "$ROOT$mnt"        # mountpoint must exist in the emu namespace
	out="$(rc_run "load std
if {auth/createsignerkey -a $alg -f $key mauthowner} {echo KEY-OK} {echo KEY-FAIL; raise 'fail:key'}
styxlisten -a aes_256_cbc -a sha256 -k $key tcp!*!$port export /lib &
sleep 2
if {mount -k $key -C 'aes_256_cbc sha256' tcp!127.0.0.1!$port $mnt} {echo MOUNT-OK} {echo MOUNT-FAIL; raise 'fail:mount'}
if {cp $mnt$XFER $pulled} {echo COPY-OK} {echo COPY-FAIL; raise 'fail:copy'}
if {cmp $pulled /lib$XFER} {echo MOUNTAUTH-PASS-$alg} {echo MOUNTAUTH-DIFF-$alg}")"
	if echo "$out" | grep -q "MOUNTAUTH-PASS-$alg"; then
		echo "PASS: mount -k over $alg cert auth + ssl + styx (file verified)"
	else
		echo "FAIL: $alg mount-auth path:"; echo "$out" | grep -vE '^fs:|^$' | sed 's/^/    /'
		fails=$((fails+1))
	fi
done

# enforcement: an anonymous mount against a cert-requiring server is rejected
port=$((port+1))
key="/tmp/mauth-neg-$port"
out="$(rc_run "load std
auth/createsignerkey -a ed25519 -f $key mauthowner
styxlisten -a aes_256_cbc -a sha256 -k $key tcp!*!$port export /lib &
sleep 2
if {mount -A tcp!127.0.0.1!$port /n/manon$port} {echo ANON-ACCEPTED-BAD} {echo ANON-REJECTED-GOOD}")"
if echo "$out" | grep -q "ANON-REJECTED-GOOD"; then
	echo "PASS: anonymous mount against a cert-requiring server is rejected"
else
	echo "FAIL: server did not enforce auth:"; echo "$out" | grep -vE '^fs:|^$' | sed 's/^/    /'
	fails=$((fails+1))
fi

[ "$fails" -eq 0 ] && { echo "ALL MOUNT-AUTH CHECKS PASSED"; exit 0; } || exit 1
