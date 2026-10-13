#!/bin/sh
#
# profile_proxy_test.sh — the login profile copies the host's HTTPS proxy
# settings into Inferno's environment, where llmclient reads them (INFR-307).
#
# Runs the real login profile (sh -l) with the host's HTTPS_PROXY and
# no_proxy set, and checks what a command run after it finds in /env:
# both, unchanged, and nothing for the variables the host did not set.
# llmclient's use of them is tests/llmclient_proxy_test.b.
#
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/sh.dis" ] || { echo "SKIP: dis tree not built"; exit 77; }

H=$(mktemp -d)
OUT=$(mktemp)
EMUPID=
trap 'rm -rf "$H" "$OUT"; [ -n "$EMUPID" ] && kill "$EMUPID" 2>/dev/null; true' EXIT HUP INT TERM

# The checks run as sh -l's command, after the profile. emu does not exit
# after the profile's services start: wait for the marker, then stop it.
env -u https_proxy -u NO_PROXY HOME="$H" \
	HTTPS_PROXY='http://user:pw@proxy.example:3128' no_proxy='localhost, .corp.example' \
	"$EMU" -c0 -r"$ROOT" /dis/sh.dis -l -c \
	"echo 'HTTPS_PROXY:' \`{cat /env/HTTPS_PROXY}; echo 'no_proxy:' \`{cat /env/no_proxy}; if {ftest -e /env/https_proxy} {echo 'https_proxy: set'}; if {ftest -e /env/NO_PROXY} {echo 'NO_PROXY: set'}; echo '=== PROXY DONE'" \
	</dev/null >"$OUT" 2>&1 &
EMUPID=$!
i=0
while [ $i -lt 60 ] && ! grep -q '=== PROXY DONE' "$OUT"; do
	sleep 1
	i=$((i + 1))
done

if ! grep -q '=== PROXY DONE' "$OUT"; then
	tail -20 "$OUT"
	echo "FAIL: the profile did not finish"
	exit 1
fi
status=0
check() {	# check pattern description
	if grep -qx "$1" "$OUT"; then
		echo "PASS: $2"
	else
		echo "FAIL: $2"
		status=1
	fi
}
check 'HTTPS_PROXY: http://user:pw@proxy.example:3128' "HTTPS_PROXY is copied from the host"
check 'no_proxy: localhost, .corp.example' "no_proxy is copied, its blanks kept"
if grep -q 'https_proxy: set\|NO_PROXY: set' "$OUT"; then
	echo "FAIL: a variable the host did not set appeared"
	status=1
else
	echo "PASS: variables the host did not set stay unset"
fi
[ $status -eq 0 ] && echo "profile_proxy_test: PASS"
exit $status
