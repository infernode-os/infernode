#!/bin/sh
#
# Two InferNode nodes on one host, each in an emulator of its own with
# a root, a home and keys of its own, driven at their consoles
# (tests/host/twonode/drive.py) as an administrator and a user drive
# them, in default mode and in CNSA mode: on node A a signer set up from
# a fresh tree (createsignerkey, svc/auth, changelogin), a secstored and
# an export; from node B getauthinfo (login(6)), a wrong password
# refused, a mount of A's export read and written (auth(2)), factotum
# unlocking secstore on A, saving a key there and a second factotum
# reading it back, a wrong secstore password given no keys and no
# account made on B's disk, passwd through keysrv on A and the new
# password taken, the old refused.  Passwords are typed the moment
# their prompts are printed, and none may appear on either console.
#
# It found, run by hand on a stock tree (each now its own check):
# keyfs failing to mount (no /mnt/keys) so svc/auth served no login;
# passwd dropped after authenticating (no /mnt/keysrv); the first
# characters of a password typed ahead echoed (every prompt was
# printed before the console's echo was turned off); secstore's
# progress printed at each connection; factotum making a secstore
# account on its own disk after any failed unlock.  The times of each
# step a person waits on are printed.
set -u
. "$(dirname "$0")/common.sh"
[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }
command -v python3 >/dev/null || { echo "SKIP: no python3"; exit 77; }
[ -f "$ROOT/dis/getauthinfo.dis" ] || { echo "SKIP: dis not built"; exit 77; }
# svc/auth announces logind and keysrv on their own ports (6673, 6677)
for p in 6673 6677; do
	if python3 -c "import socket,sys; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(('0.0.0.0', $p))" 2>/dev/null; then :; else
		echo "SKIP: port $p is in use (svc/auth's)"; exit 77
	fi
done
W="$ROOT/tmp/twonode.$$"
mkdir -p "$W"
trap '[ -n "${KEEP:-}" ] || rm -rf "$W"; pkill -f "o.emu.*-r$W" 2>/dev/null' EXIT
rc=0
for mode in default cnsa; do
	echo "--- $mode"
	with_timeout 600 python3 "$(dirname "$0")/twonode/drive.py" "$EMU" "$ROOT" "$W" $mode "$(freeport)" "$(freeport)" || rc=1
done
[ $rc = 0 ] && echo "PASS: two nodes" || { echo "FAIL: two nodes (consoles in $W with KEEP=1)"; exit 1; }
