#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ether=$root/os/ip/ethermedium.c
loop=$root/os/ip/loopbackmedium.c
ifc=$root/os/ip/ipifc.c
route=$root/os/ip/iproute.c

if ! grep -q 'memset(r, 0, n);' "$ether"; then
	echo "FAIL: ARP reply padding is not cleared" >&2
	exit 1
fi

for spec in \
	"$ether:er->read4p = er->read6p = er->arpp = (void*)-1:er->arpp == (void*)-1" \
	"$loop:lb->readp = (void*)-1:lb->readp == (void*)-1"
do
	file=${spec%%:*}; rest=${spec#*:}; init=${rest%%:*}; wait=${rest#*:}
	start=$(grep -nF "$init" "$file" | head -1 | cut -d: -f1)
	spawn=$(grep -n 'kproc(' "$file" | head -1 | cut -d: -f1)
	stop=$(grep -nF "$wait" "$file" | head -1 | cut -d: -f1)
	free=$(grep -n 'free(.*);' "$file" | tail -1 | cut -d: -f1)
	if [ -z "$start" ] || [ -z "$spawn" ] || [ -z "$stop" ] || [ -z "$free" ] ||
	   [ "$start" -ge "$spawn" ] || [ "$stop" -ge "$free" ]; then
		echo "FAIL: $file does not bracket reader startup before teardown" >&2
		exit 1
	fi
done

if [ "$(grep -c 'nifc == ifc || !canrlock(&nifc->rwl)' "$ifc")" -ne 2 ]; then
	echo "FAIL: proxy registration can block while holding another interface lock" >&2
	exit 1
fi

state=$(sed -n '/^ipifcstate(/,/^}/p' "$ifc")
lock=$(printf '%s\n' "$state" | grep -nF 'rlock(&ifc->rwl);' | cut -d: -f1)
fixed=$(printf '%s\n' "$state" | grep -nF 'm = snprint(state, n, sfixedformat,' | cut -d: -f1)
if [ -z "$lock" ] || [ -z "$fixed" ] || [ "$lock" -ge "$fixed" ]; then
	echo "FAIL: ipifcstate reads interface fields before taking the read lock" >&2
	exit 1
fi

for fn in v4lookup v6lookup; do
	body=$(sed -n "/^$fn(/,/^}/p" "$route")
	lock=$(printf '%s\n' "$body" | grep -nF 'rlock(&routelock);' | cut -d: -f1)
	walk=$(printf '%s\n' "$body" | grep -n "for(p=f->v[46]root" | cut -d: -f1)
	unlock=$(printf '%s\n' "$body" | grep -nF 'runlock(&routelock);' | cut -d: -f1)
	if [ -z "$lock" ] || [ -z "$walk" ] || [ -z "$unlock" ] ||
	   [ "$lock" -ge "$walk" ] || [ "$walk" -ge "$unlock" ]; then
		echo "FAIL: $fn does not hold routelock while walking the route tree" >&2
		exit 1
	fi
done

echo "PASS: IP media clear wire padding and serialize reader/proxy lifetimes"
