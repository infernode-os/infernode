#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
tmp=${TMPDIR:-/tmp}/infernode-draw-bounds.$$
trap 'rm -f "$tmp"' EXIT HUP INT TERM

syshost=${SYSHOST:-}
objtype=${OBJTYPE:-}
if [ -z "$syshost" ]; then
	case $(uname -s) in
	Darwin) syshost=MacOSX ;;
	Linux) syshost=Linux ;;
	*) echo "SKIP: unsupported host for draw bounds test"; exit 0 ;;
	esac
fi
if [ -z "$objtype" ]; then
	case $(uname -m) in
	arm64|aarch64) objtype=arm64 ;;
	x86_64|amd64) objtype=amd64 ;;
	*) echo "SKIP: unsupported architecture for draw bounds test"; exit 0 ;;
	esac
fi
platform=$ROOT/$syshost/$objtype
if [ ! -f "$platform/include/lib9.h" ] || [ ! -f "$platform/lib/lib9.a" ]; then
	echo "FAIL: build the host libraries before draw_bounds_test.sh" >&2
	exit 1
fi

${CC:-cc} -I"$platform/include" -I"$ROOT/include" \
	"$ROOT/tests/host/draw_bounds_helper.c" \
	"$ROOT/libdraw/badrect.c" \
	"$ROOT/libdraw/bytesperline.c" \
	"$ROOT/libdraw/computil.c" \
	"$ROOT/libmemdraw/icossin2.c" \
	"$ROOT/libmemdraw/cload.c" \
	"$platform/lib/libdraw.a" \
	"$platform/lib/lib9.a" \
	-o "$tmp"
"$tmp"
