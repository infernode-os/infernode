#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ether=$root/os/ip/ethermedium.c
loop=$root/os/ip/loopbackmedium.c
ifc=$root/os/ip/ipifc.c
route=$root/os/ip/iproute.c
tcp=$root/os/ip/tcp.c

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

findbody=$(sed -n '/^findipifc(/,/^}/p' "$ifc")
if ! printf '%s\n' "$findbody" | grep -qF 'rlock(&ifc->rwl);' ||
   ! printf '%s\n' "$findbody" | grep -qF 'canrlock(&x->rwl)' ||
   ! printf '%s\n' "$findbody" | grep -qF 'x->ifcid == xifcid'; then
	echo "FAIL: findipifc does not return a stable read-locked interface" >&2
	exit 1
fi

tcpmtu=$(sed -n '/^tcpmtu(/,/^}/p' "$tcp")
if ! printf '%s\n' "$tcpmtu" | grep -qF 'runlock(&ifc->rwl);'; then
	echo "FAIL: tcpmtu does not release the interface returned by findipifc" >&2
	exit 1
fi

for fn in v4lookup v6lookup; do
	body=$(sed -n "/^$fn(/,/^}/p" "$route")
	if ! printf '%s\n' "$body" | grep -qF 'canrlock(&ifc->rwl)' ||
	   ! printf '%s\n' "$body" | grep -qF 'runlock(&ifc->rwl);'; then
		echo "FAIL: $fn does not validate and release its route interface" >&2
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

bindbody=$(sed -n '/^ipifcbind(/,/^}/p' "$ifc")
mark=$(printf '%s\n' "$bindbody" | grep -nF 'ifc->m = &unboundmedium;' | head -1 | cut -d: -f1)
callback=$(printf '%s\n' "$bindbody" | grep -nF '(*m->bind)(ifc, argc, argv);' | cut -d: -f1)
drop=$(printf '%s\n' "$bindbody" | grep -nF 'wunlock(&ifc->rwl);' | awk -F: -v cb="$callback" '$1 < cb { n=$1 } END { print n }')
relock=$(printf '%s\n' "$bindbody" | grep -nF 'wlock(&ifc->rwl);' | awk -F: -v cb="$callback" '$1 > cb { print $1; exit }')
if [ -z "$mark" ] || [ -z "$drop" ] || [ -z "$callback" ] || [ -z "$relock" ] ||
   [ "$mark" -ge "$callback" ] || [ "$drop" -ge "$callback" ] || [ "$callback" -ge "$relock" ]; then
	echo "FAIL: medium bind callback runs while the interface lock is held" >&2
	exit 1
fi

unbindbody=$(sed -n '/^ipifcunbind(/,/^}/p' "$ifc")
if ! printf '%s\n' "$unbindbody" | grep -qF 'm == &unboundmedium'; then
	echo "FAIL: concurrent unbind can enter a medium transition" >&2
	exit 1
fi
callback=$(printf '%s\n' "$unbindbody" | grep -nF '(*m->unbind)(ifc);' | cut -d: -f1)
drop=$(printf '%s\n' "$unbindbody" | grep -nF 'wunlock(&ifc->rwl);' | awk -F: -v cb="$callback" '$1 < cb { n=$1 } END { print n }')
relock=$(printf '%s\n' "$unbindbody" | grep -nF 'wlock(&ifc->rwl);' | awk -F: -v cb="$callback" '$1 > cb { print $1; exit }')
if [ -z "$drop" ] || [ -z "$callback" ] || [ -z "$relock" ] ||
   [ "$drop" -ge "$callback" ] || [ "$callback" -ge "$relock" ]; then
	echo "FAIL: medium unbind callback runs while the interface lock is held" >&2
	exit 1
fi

echo "PASS: IP media and route lookups serialize interface lifetimes"
