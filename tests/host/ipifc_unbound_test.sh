#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
src=$root/os/ip/ipifc.c

body=$(sed -n '/^ipifcaddpref6(/,/^}/p' "$src")
snapshot=$(printf '%s\n' "$body" | grep -nF 'm = ifc->m;' | cut -d: -f1)
guard=$(printf '%s\n' "$body" | grep -nF 'if(m == nil || m->pref2addr == nil)' | cut -d: -f1)
call=$(printf '%s\n' "$body" | grep -nF '(*m->pref2addr)(prefix, ifc->mac);' | cut -d: -f1)

if [ -z "$snapshot" ] || [ -z "$guard" ] || [ -z "$call" ] ||
   [ "$snapshot" -ge "$guard" ] || [ "$guard" -ge "$call" ]; then
	echo "FAIL: addpref6 can dereference an absent or changing medium" >&2
	exit 1
fi

echo "PASS: unbound addpref6 rejects before using the medium callback"
