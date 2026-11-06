#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}/infernode-draw-clip.$$
trap 'rm -f "$tmp"' EXIT HUP INT TERM

case $(uname -s):$(uname -m) in
Darwin:arm64) platform=$ROOT/MacOSX/arm64; deadstrip=-Wl,-dead_strip ;;
Darwin:x86_64) platform=$ROOT/MacOSX/amd64; deadstrip=-Wl,-dead_strip ;;
Linux:aarch64) platform=$ROOT/Linux/arm64; deadstrip=-Wl,--gc-sections ;;
Linux:x86_64) platform=$ROOT/Linux/amd64; deadstrip=-Wl,--gc-sections ;;
*) echo "SKIP: unsupported host for draw clip test"; exit 0 ;;
esac

if [ ! -f "$platform/lib/libmemdraw.a" ]; then
	echo "FAIL: build the host libraries before draw_clip_test.sh" >&2
	exit 1
fi

${CC:-cc} -ffunction-sections -fdata-sections "$deadstrip" -Wno-everything \
	-I"$platform/include" -I"$ROOT/include" \
	"$ROOT/tests/host/draw_clip_helper.c" \
	"$ROOT/libmemdraw/draw.c" "$platform/lib/libdraw.a" \
	"$platform/lib/lib9.a" -lm -lpthread -o "$tmp"
"$tmp"
