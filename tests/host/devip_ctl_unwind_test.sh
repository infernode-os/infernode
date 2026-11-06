#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

native=$root/os/ip/devip.c
hosted=$root/emu/port/devip.c

for fn in connectctlmsg announcectlmsg; do
	body=$(sed -n "/^$fn(/,/^}/p" "$native")
	case "$body" in
	*'c->state = '*ing*'if(p != nil){'*'c->state = Idle;'*) ;;
	*) echo "FAIL: native $fn does not restore Idle after setup failure" >&2; exit 1 ;;
	esac
done

for fn in connectctlmsg announcectlmsg; do
	body=$(sed -n "/^$fn(/,/^}/p" "$hosted")
	case "$body" in
	*'if(waserror()){'*'c->state = Idle;'*'nexterror();'*) ;;
	*) echo "FAIL: hosted $fn does not restore Idle after socket failure" >&2; exit 1 ;;
	esac
	if printf '%s\n' "$body" | grep -q 'state = Connected;.*sic\|state = Announced;.*sic'; then
		echo "FAIL: hosted $fn still marks a failed socket usable" >&2
		exit 1
	fi
done

echo "PASS: failed IP connect and announce operations return conversations to Idle"
