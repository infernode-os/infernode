#!/bin/sh
#
# xenith_rescue_test.sh — when Xenith goes wrong, what has not been
# saved is kept, and Load brings it back:
#
#	an internal error in a 9P request (a window's ctl "fault", made
#	only with $xenithfaults set): the request answered with it, Xenith
#	going on, a file's changes, an unnamed window's text and typing not
#	yet committed kept in $home/xenith.rescue, the user told where,
#	Dump's own file left as it was;
#	one in a proc that does not recover: Xenith exits, keeping what
#	changed since;
#	a Xenith started on the rescue file: the windows back with their
#	text.
#
# An internal error exited Xenith, every unsaved window lost, and the
# dump it wrote then replaced the one the user had made with Dump.
#
# Runs tests/inferno/xenith_rescue_test.sh inside a headless Xenith
# (xenith_inside.sh), then tests/inferno/xenith_rescue_load.sh in one
# loaded from what it kept. Needs the SDL GUI emulator: SKIP (77) on a
# headless build.

. "$(dirname "$0")/common.sh"
. "$(dirname "$0")/xenith_inside.sh"
cd "$ROOT"

h=tmp/xenith_rescue_home
rm -rf "${ROOT:?}/$h" "$ROOT/tmp/xenith_rescue"
mkdir -p "$ROOT/$h"
trap 'rm -rf "${ROOT:?}/$h" "$ROOT/tmp/xenith_rescue"' EXIT

out=$(XENITH_INSIDE_TIMEOUT=60 XENITH_INSIDE_SH="xenithfaults=1; home=/$h" \
	xenith_inside xenith_rescue /tests/inferno/xenith_rescue_test.sh)
st=$?
printf '%s\n' "$out"
[ $st = 77 ] && exit 77
failed=0
[ $st = 0 ] || failed=1
if printf '%s\n' "$out" | grep -q 'did not exit'; then
	failed=1
fi

# where nothing recovered, Xenith exited: what changed since is kept
r=$ROOT/$h/xenith.rescue
if grep -q 'beta after' "$r" 2>/dev/null; then
	echo "PASS: an internal error where nothing recovers keeps what changed since"
else
	echo "FAIL: an internal error where nothing recovers kept nothing since"
	failed=1
fi

# Load: a Xenith started on the rescue file, its last entry running
# the checks inside it
if [ -f "$r" ]; then
	{
		cat "$r"
		printf 'e%11d %11d %11d %11d %11d \n' 0 0 0 0 0
		echo
		echo /
		echo "sh -c 'sh /tests/inferno/xenith_rescue_load.sh >''#c/cons'' >[2=1]; echo halt >''#c/sysctl'''"
	} > "$ROOT/$h/load.dump"
	o=$(SDL_VIDEODRIVER=dummy with_timeout 60 "$EMU" -c0 -g800x600 -r"$ROOT" /dis/sh.dis -c "
load std
home=/$h
xenith -l /$h/load.dump" 2>&1)
	printf '%s\n' "$o" | grep -E '^(PASS|FAIL)'
	printf '%s\n' "$o" | grep -q '^ALL PASS' || failed=1
	for f in $(ls "$ROOT/tmp" | grep 'xenith$'); do
		[ "$ROOT/tmp/$f" -nt "$ROOT/$h/load.dump" ] && rm -f "$ROOT/tmp/$f"
	done
fi

if [ $failed = 0 ]; then
	echo "xenith_rescue_test: ALL PASS"
	exit 0
fi
echo "xenith_rescue_test: FAILED"
exit 1
