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

ctl=$(sed -n '/^uartctl(/,/^}/p' "$src")
guard=$(printf '%s\n' "$ctl" | grep -nF 'if(n < 0 || n > 1024*1024)' | cut -d: -f1)
limit=$(printf '%s\n' "$ctl" | grep -nF 'qsetlimit(p->iq, n);' | cut -d: -f1)
if [ -z "$guard" ] || [ -z "$limit" ] || [ "$guard" -ge "$limit" ]; then
	echo "FAIL: UART queue limit is not bounded before qsetlimit" >&2
	exit 1
fi

echo "PASS: UART open unwinds failures and queue sizes are bounded"
