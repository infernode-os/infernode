#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
src=$root/os/port/devuart.c
body=$(sed -n '/^uartopen(/,/^}/p' "$src")

if printf '%s\n' "$body" | grep -q 'opens++ == 0'; then
	echo "FAIL: uartopen increments opens before enable succeeds" >&2
	exit 1
fi

enable=$(printf '%s\n' "$body" | grep -n 'uartenable(p) == nil' | cut -d: -f1)
increment=$(printf '%s\n' "$body" | grep -n 'p->opens++;' | cut -d: -f1)
if [ -z "$enable" ] || [ -z "$increment" ] || [ "$increment" -le "$enable" ]; then
	echo "FAIL: uartopen must increment opens only after successful enable" >&2
	exit 1
fi

echo "PASS: failed UART enable leaves the open count unchanged"
