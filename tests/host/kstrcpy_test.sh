#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}/infernode-kstrcpy.$$
trap 'rm -f "$tmp"' EXIT HUP INT TERM

case $(uname -s):$(uname -m) in
Darwin:arm64) platform=$ROOT/MacOSX/arm64; deadstrip=-Wl,-dead_strip ;;
Darwin:x86_64) platform=$ROOT/MacOSX/amd64; deadstrip=-Wl,-dead_strip ;;
Linux:aarch64) platform=$ROOT/Linux/arm64; deadstrip=-Wl,--gc-sections ;;
Linux:x86_64) platform=$ROOT/Linux/amd64; deadstrip=-Wl,--gc-sections ;;
*) echo "SKIP: unsupported host for kstrcpy test"; exit 0 ;;
esac

if [ ! -f "$platform/include/lib9.h" ] || [ ! -f "$platform/lib/lib9.a" ]; then
	echo "FAIL: build the host libraries before kstrcpy_test.sh" >&2
	exit 1
fi

${CC:-cc} -DEMU -ffunction-sections -fdata-sections "$deadstrip" \
	-Wno-everything -I"$ROOT/emu/port" -I"$platform/include" \
	-I"$ROOT/include" -I"$ROOT/libinterp" \
	"$ROOT/tests/host/kstrcpy_helper.c" "$ROOT/emu/port/chan.c" \
	"$platform/lib/lib9.a" -lm -lpthread -o "$tmp"
"$tmp"
