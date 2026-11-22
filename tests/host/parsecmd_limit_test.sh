#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

for src in "$root/emu/port/parse.c" "$root/os/port/parse.c"; do
	guard=$(grep -nF 'if(up != nil && (uint)n > READSTR)' "$src" | cut -d: -f1)
	count=$(grep -nF 'nf = ncmdfield(p, n);' "$src" | cut -d: -f1)
	alloc=$(grep -nF 'sp = smalloc(' "$src" | cut -d: -f1)
	if [ -z "$guard" ] || [ -z "$count" ] || [ -z "$alloc" ] ||
	   [ "$guard" -ge "$count" ] || [ "$guard" -ge "$alloc" ]; then
		echo "FAIL: $src allocates before bounding a control message" >&2
		exit 1
	fi
done

echo "PASS: hosted and native control parsers bound input before allocation"
