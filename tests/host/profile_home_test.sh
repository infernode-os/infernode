#!/bin/sh
#
# profile_home_test.sh — the login profile finds the host's home however the
# host gives it, and goes on when there is none (#737).
#
# The profile built the hosted home as /n/local/^`{echo $HOME}: with no HOME
# in emu's environment (a launchd or systemd service, env -i, some CI
# runners) that was a null list in concatenation, the profile stopped there,
# and the login had no overlay, no factotum and none of its services. A home
# with a blank in it became two names.
#
# Each case runs the real profile (sh -l) and a command after it, which
# reports $home and whether the profile got as far as factotum:
#   HOME set               /n/local/$HOME, ~/.infernode made
#   HOME with a blank      one name, ~/.infernode made in it
#   no HOME                the passwd entry's home
#   no home at all         /usr/$user, said once, no concatenation error
#
. "$(dirname "$0")/common.sh"
set -u

[ -x "$EMU" ] || { echo "SKIP: emulator not found at $EMU"; exit 77; }
[ -f "$ROOT/dis/sh.dis" ] || { echo "SKIP: dis tree not built"; exit 77; }

T=$(mktemp -d)
EMUPID=
trap 'rm -rf "$T"; [ -n "$EMUPID" ] && kill "$EMUPID" 2>/dev/null; true' EXIT HUP INT TERM

status=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; status=1; }

# runprofile out env-args... — the checks run as sh -l's command. emu does
# not exit after the profile's services start: wait for the marker, then
# stop it.
runprofile() {
	out=$1
	shift
	env "$@" "$EMU" -c0 -r"$ROOT" /dis/sh.dis -l -c \
		"echo 'home:' \$home; if {ftest -e /mnt/factotum/ctl} {echo 'factotum: up'}; echo '=== HOME DONE'" \
		</dev/null >"$out" 2>&1 &
	EMUPID=$!
	i=0
	while [ $i -lt 60 ] && ! grep -q '=== HOME DONE' "$out"; do
		sleep 1
		i=$((i + 1))
	done
	kill "$EMUPID" 2>/dev/null
	wait "$EMUPID" 2>/dev/null
	EMUPID=
}

# check out name want-home
check() {
	out=$1
	name=$2
	want=$3
	if ! grep -q '=== HOME DONE' "$out"; then
		tail -20 "$out"
		fail "$name: the profile did not finish"
		return
	fi
	if grep -q 'null list in concatenation' "$out"; then
		fail "$name: null list in concatenation"
	else
		pass "$name: no concatenation error"
	fi
	if grep -qxF "home: $want" "$out"; then
		pass "$name: home is $want"
	else
		grep '^home:' "$out"
		fail "$name: home is not $want"
	fi
	if grep -qx 'factotum: up' "$out"; then
		pass "$name: the profile ran on to factotum"
	else
		fail "$name: the profile stopped before factotum"
	fi
}

H="$T/home"
mkdir -p "$H"
runprofile "$T/set.out" HOME="$H"
check "$T/set.out" "HOME set" "/n/local$H"
[ -d "$H/.infernode/usr" ] && pass "HOME set: ~/.infernode made" || fail "HOME set: no ~/.infernode"

B="$T/my home"
mkdir -p "$B"
runprofile "$T/blank.out" HOME="$B"
check "$T/blank.out" "HOME with a blank" "/n/local$B"
[ -d "$B/.infernode/usr" ] && pass "HOME with a blank: ~/.infernode made in it" || fail "HOME with a blank: no ~/.infernode in it"

pw=$(sh -c 'eval echo ~$(id -un)' 2>/dev/null)
case $pw in
/*)
	runprofile "$T/nohome.out" -u HOME
	check "$T/nohome.out" "no HOME" "/n/local$pw"
	;;
*)
	echo "SKIP: no HOME: this host has no passwd home for $(id -un)"
	;;
esac

# No HOME, and no shell for the passwd lookup to run in: no home at all.
runprofile "$T/none.out" -u HOME PATH=/nonexistent
user=$(sed -n 's/^home: \/usr\///p' "$T/none.out")
check "$T/none.out" "no home at all" "/usr/${user:-?}"
if grep -q 'gives no home directory' "$T/none.out"; then
	pass "no home at all: the profile says so"
else
	fail "no home at all: nothing said"
fi

[ $status -eq 0 ] && echo "profile_home_test: PASS"
exit $status
