#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
ether=$root/os/ip/ethermedium.c
loop=$root/os/ip/loopbackmedium.c
ifc=$root/os/ip/ipifc.c

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

echo "PASS: IP media clear wire padding and serialize reader/proxy lifetimes"
