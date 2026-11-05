#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

for src in "$root/os/port/qio.c" "$root/emu/port/qio.c"; do
	qb=$(sed -n '/^qbwrite(/,/^}/p' "$src")
	qi=$(sed -n '/^qiwrite(/,/^}/p' "$src")
	case "$qb" in
	*'void (*bypass)(void*, Block*);'*'if((bypass = q->bypass) != nil)'*'(*bypass)(q->arg, b)'*) ;;
	*) echo "FAIL: $src qbwrite does not call a stable bypass pointer" >&2; exit 1 ;;
	esac
	case "$qi" in
	*'void (*bypass)(void*, Block*);'*'if((bypass = q->bypass) != nil)'*'(*bypass)(q->arg, b)'*'continue;'*) ;;
	*) echo "FAIL: $src qiwrite does not honor queue bypass" >&2; exit 1 ;;
	esac
done

echo "PASS: queue writers use a stable bypass callback and qiwrite honors it"
