#!/bin/sh
#
# tests/host/cpu_session_test.sh
#
# A cpu(1) session ends when its command ends, or when its caller goes
# away, and takes everything it started with it (#732).
#
# It did neither. cpu node sh -c 'echo hi' printed and never returned,
# because listen held the connection open three ways after the session
# (its per-connection shell waited on the listener's wait file, it dup'd
# the connection into the listener's own fd table, and its auth timer
# kept that table for the whole auth timeout), and anything the session
# left running kept the caller's namespace mounted. A program whose
# caller had gone ran on for nobody.
#
# One emulator is both ends: it listens with rstyxd and dials itself,
# with throwaway keys under a private /usr. Two sessions:
#   1. sh -c 'sleep 1000 & echo ...' must return, leaving no Sleep;
#   2. a session whose caller hangs up must be ended by the node.
#
# Skips (exit 77) when there is no emulator.
#
. "$(dirname "$0")/common.sh"

[ -x "$EMU" ] || { echo "SKIP: no emulator at $EMU"; exit 77; }

PORT=${PORT:-17171}
TIMEOUT=${TIMEOUT:-120}
mkdir -p "$ROOT/tmp"
SCRIPT="$ROOT/tmp/cpu_session_test.sh"

cat > "$SCRIPT" <<EOF
load std
user=\`{cat /dev/user}
mkdir -p /tmp/cpusess/usr/\$user/keyring
bind -b /tmp/cpusess/usr /usr
auth/createsignerkey -f /usr/\$user/keyring/signer \$user-signer
auth/mkauthinfo -k 'key=signer' \$user /usr/\$user/keyring/default
listen -a aes_256_cbc -a sha256 'tcp!*!$PORT' auxi/rstyxd &
sleep 2

cpu 'tcp!127.0.0.1!$PORT' sh -c 'sleep 1000 & echo ONESHOT-RAN'
echo ONESHOT-RETURNED
sleep 2
ps | sed 's/^/AFTER-ONESHOT /'

cpu 'tcp!127.0.0.1!$PORT' sh -c 'sleep 1000' &
sleep 4
ps | sed 's/^/DURING-SECOND /'
# the caller goes away: its end of the connection is hung up
for c in /net/tcp/[0-9]* {
	if {grep -s '!$PORT\$' \$c/remote} {
		echo hangup > \$c/ctl
	}
}
sleep 12
ps | sed 's/^/AFTER-HANGUP /'
echo DONE
echo halt > /dev/sysctl
EOF

out=$(timeout "$TIMEOUT" "$EMU" -c1 -r"$ROOT" /dis/sh.dis /tmp/cpu_session_test.sh 2>&1 < /dev/null)
rc=0
ok() {	# ok name condition-result
	if [ "$2" = yes ]; then
		echo "PASS: $1"
	else
		echo "FAIL: $1"
		rc=1
	fi
}
has() { echo "$out" | grep -q "$1" && echo yes || echo no; }
# $2 is absent, from a listing ($1) that was printed
hasnt() { echo "$out" | grep -q "$1" && ! echo "$out" | grep -q "$2" && echo yes || echo no; }
ok "a one-shot cpu session runs its command" "$(has '^ONESHOT-RAN$')"
ok "a one-shot cpu session returns when its command ends" "$(has '^ONESHOT-RETURNED$')"
ok "what a session started ends with it" "$(hasnt '^AFTER-ONESHOT ' '^AFTER-ONESHOT .*Sleep')"
ok "a long session is running before its caller hangs up" "$(has '^DURING-SECOND .*Sleep')"
ok "a session whose caller hangs up is ended by the node" "$(hasnt '^AFTER-HANGUP ' '^AFTER-HANGUP .*Sleep')"
ok "the test ran to the end" "$(has '^DONE$')"
[ $rc -eq 0 ] || echo "$out" | grep -v sdl3 | tail -30
exit $rc
