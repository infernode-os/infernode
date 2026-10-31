#!/bin/sh
#
# profile_legacykey_test.sh — a plaintext API key left in
# ~/.infernode/lib/veltro-keys is imported into factotum by the login
# profile, and is no longer bound into the name space (INFR-347).
#
# The profile used to bind ~/.infernode/lib/veltro-keys over
# /lib/veltro/keys, so every program in the session could read the
# plaintext keys there. Now only the profile reads the file, once a
# login: it puts the key in factotum (which saves it to secstore) and
# says the file can go.
#
# Runs the real login profile (sh -l) with HOME a scratch directory
# holding one key, and no BRAVE_API_KEY in the environment.
#
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/sh.dis" ] || { echo "SKIP: dis tree not built"; exit 77; }

H=$(mktemp -d)
OUT=$(mktemp)
EMUPID=
trap 'rm -rf "$H" "$OUT"; [ -n "$EMUPID" ] && kill "$EMUPID" 2>/dev/null; true' EXIT HUP INT TERM
mkdir -p "$H/.infernode/lib/veltro-keys"
chmod 700 "$H/.infernode" "$H/.infernode/lib/veltro-keys"
printf %s 'legacy-347-key' > "$H/.infernode/lib/veltro-keys/brave"
chmod 600 "$H/.infernode/lib/veltro-keys/brave"

# The checks run as sh -l's command, after the profile: piped on standard
# input they would be read by the profile's own os(1) calls. emu does not
# exit after the profile's services start: wait for the marker, then stop it.
env -u BRAVE_API_KEY HOME="$H" "$EMU" -c0 -r"$ROOT" /dis/sh.dis -l -c \
	"if {ftest -e /lib/veltro/keys/brave} {echo KEYFILE-VISIBLE} {echo KEYFILE-HIDDEN}; if {grep -s 'service=brave' /mnt/factotum/ctl} {echo FACTOTUM-HAS-KEY} {echo FACTOTUM-NO-KEY}; echo '=== LEGACYKEY DONE'" \
	</dev/null >"$OUT" 2>&1 &
EMUPID=$!
i=0
while [ $i -lt 60 ] && ! grep -q '=== LEGACYKEY DONE' "$OUT"; do
	sleep 1
	i=$((i + 1))
done

status=0
if ! grep -q '=== LEGACYKEY DONE' "$OUT"; then
	tail -20 "$OUT"
	echo "FAIL: the profile did not finish"
	exit 1
fi
if grep -q FACTOTUM-HAS-KEY "$OUT"; then
	echo "PASS: the plaintext key is in factotum"
else
	echo "FAIL: the plaintext key did not reach factotum"
	status=1
fi
if grep -q KEYFILE-HIDDEN "$OUT"; then
	echo "PASS: the plaintext key file is not in the name space"
else
	echo "FAIL: /lib/veltro/keys/brave is visible in the session"
	status=1
fi
if grep -q 'brave key imported into factotum from plaintext' "$OUT"; then
	echo "PASS: the import names the plaintext file to delete"
else
	echo "FAIL: no notice of the plaintext import"
	status=1
fi
if grep -q 'legacy-347-key' "$OUT"; then
	echo "FAIL: the key itself was printed"
	status=1
fi
[ $status -eq 0 ] && echo "profile_legacykey_test: PASS"
exit $status
