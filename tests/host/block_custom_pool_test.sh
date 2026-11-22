#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

for src in "$root/emu/port/qio.c" "$root/os/port/allocb.c"; do
	body=$(sed -n '/^freeb(Block \*b)/,/^}/p' "$src")
	callback=$(printf '%s\n' "$body" | grep -nF 'b->free(b);' | cut -d: -f1)
	next=$(printf '%s\n' "$body" | grep -nF 'b->next = nil;' | cut -d: -f1)
	list=$(printf '%s\n' "$body" | grep -nF 'b->list = nil;' | cut -d: -f1)
	if [ -z "$callback" ] || [ -z "$next" ] || [ -z "$list" ] ||
	   [ "$next" -ge "$callback" ] || [ "$list" -ge "$callback" ]; then
		echo "FAIL: $src returns linked Block state to a custom pool" >&2
		exit 1
	fi
	dying=$(printf '%s\n' "$body" | grep -E 'b->list = (dead|\(void\*\)0xdeadbabe);' | wc -l | tr -d ' ')
	if [ "$dying" -ne 1 ]; then
		echo "FAIL: $src does not poison Block.list before ordinary free" >&2
		exit 1
	fi
done

echo "PASS: Block free paths clear custom-pool links and poison stale lists"
