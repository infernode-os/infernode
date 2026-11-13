#!/bin/sh
#
# profile_nohome_test.sh — the login profile finds the host's home
# directory without $HOME, and says so when the host has none (#737).
#
# /n/local/^`{echo $HOME} was a null list in concatenation when emu was
# started with no $HOME (launchd, a systemd unit, env -i): sh printed
# "null list in concatenation" and the profile went on to make
# ~/.infernode at the top of /n/local. Now the host's password file is
# asked next, and with no home at all the overlay is left out, with a
# message, and the home is the emulator's /usr/$user.
#
# Cases: $HOME set (the overlay there, a home with a blank in it whole),
# $HOME unset (the password file's home), and, run as root with
# setpriv(1), a uid the password file does not have (no home at all).
#
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/sh.dis" ] || { echo "SKIP: dis tree not built"; exit 77; }

H=$(mktemp -d)
OUT=$(mktemp)
chmod 666 "$OUT"
EMUPID=
trap 'rm -rf "$H" "$OUT"; [ -n "$EMUPID" ] && kill "$EMUPID" 2>/dev/null; true' EXIT HUP INT TERM

status=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; status=1; }

# login [prefix...] -- runs sh -l with the prefix command (env, setpriv)
# before emu, and leaves what it printed in $OUT. emu does not exit after
# the profile's services start: wait for the marker, then stop it.
login() {
	: >"$OUT"
	"$@" "$EMU" -c0 -r"$ROOT" /dis/sh.dis -l -c \
		"echo 'home:' \$home; echo '=== NOHOME DONE'" \
		</dev/null >"$OUT" 2>&1 &
	EMUPID=$!
	i=0
	while [ $i -lt 60 ] && ! grep -q '=== NOHOME DONE' "$OUT"; do
		sleep 1
		i=$((i + 1))
	done
	kill "$EMUPID" 2>/dev/null
	wait "$EMUPID" 2>/dev/null
	EMUPID=
	grep -q '=== NOHOME DONE' "$OUT" || { tail -20 "$OUT"; fail "the profile did not finish ($*)"; return 1; }
	if grep -q 'null list' "$OUT"; then
		fail "a null list in concatenation ($*)"
	fi
	return 0
}

# $HOME set: the overlay is made there.
if login env HOME="$H"; then
	if grep -qx "home: /n/local$H" "$OUT" && [ -d "$H/.infernode/usr" ]; then
		pass "\$HOME set: home and ~/.infernode there"
	else
		cat "$OUT"; fail "\$HOME set: home not $H"
	fi
fi

# A home with a blank in it is one word.
mkdir -p "$H/a b"
if login env HOME="$H/a b"; then
	if grep -qx "home: /n/local$H/a b" "$OUT" && [ -d "$H/a b/.infernode/usr" ]; then
		pass "a home with a blank in it kept whole"
	else
		cat "$OUT"; fail "a home with a blank in it"
	fi
fi

# $HOME unset: the password file's home (dscl's on macOS).
case "$EMUHOST" in
MacOSX)	pwhome=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^[^:]*: *//') ;;
*)	pwhome=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6) ;;
esac
if [ -n "$pwhome" ]; then
	if login env -u HOME; then
		if grep -qx "home: /n/local$pwhome" "$OUT"; then
			pass "\$HOME unset: the password file's home ($pwhome)"
		else
			cat "$OUT"; fail "\$HOME unset: home not $pwhome"
		fi
	fi
else
	echo "SKIP: this user has no home in the password file"
fi

# No home at all: a uid the password file does not have.
if [ "$(id -u)" = 0 ] && command -v setpriv >/dev/null 2>&1 && ! getent passwd 4242 >/dev/null 2>&1; then
	if login setpriv --reuid=4242 --regid=4242 --clear-groups env -u HOME; then
		if grep -q 'profile: the host gives no home directory' "$OUT" &&
		   grep -qx 'home: /usr/.*' "$OUT"; then
			pass "no home at all: said so, home in the emulator's /usr"
		else
			cat "$OUT"; fail "no home at all"
		fi
	fi
else
	echo "SKIP: no home at all (needs root, setpriv and uid 4242 unused)"
fi

[ $status -eq 0 ] && echo "profile_nohome_test: PASS"
exit $status
