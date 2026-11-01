#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}/infernode-freesubfont.$$
obj=$tmp.o
trap 'rm -f "$tmp" "$obj"' EXIT HUP INT TERM

case $(uname -s):$(uname -m) in
Darwin:arm64) platform=$ROOT/MacOSX/arm64 ;;
Darwin:x86_64) platform=$ROOT/MacOSX/amd64 ;;
Linux:aarch64) platform=$ROOT/Linux/arm64 ;;
Linux:x86_64) platform=$ROOT/Linux/amd64 ;;
*) echo "SKIP: unsupported host for freesubfont test"; exit 0 ;;
esac

if [ ! -f "$platform/include/lib9.h" ] || [ ! -f "$platform/lib/lib9.a" ]; then
	echo "FAIL: build the host libraries before freesubfont_test.sh" >&2
	exit 1
fi

${CC:-cc} -I"$platform/include" -I"$ROOT/include" \
	-Dfree=testfree -Dfreesubfont=freesubfont_under_test \
	-c "$ROOT/libdraw/freesubfont.c" -o "$obj"
${CC:-cc} -I"$platform/include" -I"$ROOT/include" \
	"$ROOT/tests/host/freesubfont_helper.c" \
	"$obj" "$platform/lib/lib9.a" -o "$tmp"
"$tmp"
