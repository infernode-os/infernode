#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
src=$root/os/ip/devip.c

allocs=$(sed -n '/^ipread(/,/^}/p' "$src" | grep -c 'buf = smalloc(Statelen);')
handlers=$(sed -n '/^ipread(/,/^}/p' "$src" | grep -c 'if(waserror()){')

if [ "$allocs" -ne 4 ]; then
	echo "FAIL: expected four temporary devip read buffers, found $allocs" >&2
	exit 1
fi
if [ "$handlers" -ne "$allocs" ]; then
	echo "FAIL: every temporary devip read buffer needs an error cleanup" >&2
	exit 1
fi

awk '
	/buf = smalloc\(Statelen\);/ { allocated++; protected = 0; next }
	allocated && /if\(waserror\(\)\)\{/ { protected = 1; next }
	allocated && /\(\*x->(remote|local|state|stats)\)|readstr\(offset, p, n, buf\)/ {
		if(!protected){
			print "FAIL: devip buffer used before cleanup was installed" > "/dev/stderr"
			exit 1
		}
	}
	allocated && /goto Readstr;|return rv;/ { allocated = 0; protected = 0 }
' "$src"

if ! sed -n '/Readstr:/,/return rv;/p' "$src" | grep -q 'poperror();'; then
	echo "FAIL: successful devip reads do not pop their cleanup" >&2
	exit 1
fi

echo "PASS: devip temporary read buffers are cleaned on error"
