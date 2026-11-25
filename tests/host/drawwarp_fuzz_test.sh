#!/bin/sh
#
# tests/host/drawwarp_fuzz_test.sh
#
# The draw device's affine warp (libmemdraw/warp.c, libmemlayer/warp.c),
# which every program that draws can reach and which the native kernels
# run inside the kernel, ground with what a client may send
# (tests/host/drawwarp/fuzz.c) under AddressSanitizer, and the warp's own
# code under UndefinedBehaviorSanitizer: images of every channel format
# at any origin with exact-size pixels (in the emulator they sit in a
# pool, whose blocks ASan cannot see), clips that do and do not meet
# their images, inverted rectangles, matrices in and out of warpok's
# bounds, the upscale flag on any matrix; then the same through windows
# on a screen, covered, saved, warped onto and from one another.
#
# It found, in the code as 9front has it: a destination whose clip does
# not meet it drawn outside its pixels (rectclip's result unread), and
# an inverted rectangle's negative width given to memmove; and undefined
# shifts and multiplies, made defined.
#
# DRAWWARP_FUZZ_N sets the warps a seed (default 100000; layers a tenth),
# DRAWWARP_FUZZ_SEEDS the seeds (default 1 2 3).  Needs clang.
#
set -u
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
command -v clang >/dev/null || { echo "SKIP: no clang"; exit 77; }
case $(uname -s) in
Darwin)	syshost=MacOSX ;;
Linux)	syshost=Linux ;;
*)	echo "SKIP: unsupported host"; exit 77 ;;
esac
case $(uname -m) in
arm64|aarch64)	objtype=arm64 ;;
x86_64|amd64)	objtype=amd64 ;;
*)	echo "SKIP: unsupported architecture"; exit 77 ;;
esac
P=$ROOT/$syshost/$objtype
[ -f "$P/lib/lib9.a" ] && [ -f "$P/lib/libdraw.a" ] && [ -f "$P/lib/libmemdraw.a" ] ||
	{ echo "SKIP: build the host libraries first"; exit 77; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
F="-g -O1 -fno-omit-frame-pointer -I$P/include -I$ROOT/include -I$ROOT/libmemdraw -I$ROOT/libmemlayer"
n=0
for f in libmemdraw/alloc.c libmemdraw/draw.c libmemdraw/cmap.c \
	libmemlayer/draw.c libmemlayer/lalloc.c libmemlayer/layerop.c libmemlayer/ldelete.c \
	libmemlayer/lhide.c libmemlayer/line.c libmemlayer/load.c libmemlayer/lorigin.c \
	libmemlayer/lsetrefresh.c libmemlayer/ltofront.c libmemlayer/ltorear.c libmemlayer/unload.c; do
	# the drawing they share with the warp: ASan only (draw.c's own
	# shifts into the sign bit are not this test's)
	clang -c -fsanitize=address $F "$ROOT/$f" -o "$W/$n.o" || { echo "FAIL: cannot build $f"; exit 1; }
	n=$((n+1))
done
for f in libmemdraw/warp.c libmemlayer/warp.c tests/host/drawwarp/fuzz.c; do
	clang -c -fsanitize=address,undefined -fno-sanitize-recover=undefined $F "$ROOT/$f" -o "$W/$n.o" ||
		{ echo "FAIL: cannot build $f"; exit 1; }
	n=$((n+1))
done
clang -fsanitize=address,undefined "$W"/*.o "$P/lib/libmemdraw.a" "$P/lib/libdraw.a" "$P/lib/lib9.a" -o "$W/fuzz" ||
	{ echo "FAIL: cannot link the fuzzer"; exit 1; }

N=${DRAWWARP_FUZZ_N:-100000}
rc=0
for s in ${DRAWWARP_FUZZ_SEEDS:-1 2 3}; do
	for mode in plain layers; do
		if [ $mode = plain ]; then
			out=$("$W/fuzz" -n "$N" -s "$s" 2>&1)
		else
			out=$("$W/fuzz" -l -n $((N/10)) -s "$s" 2>&1)
		fi
		st=$?
		if [ $st = 0 ] && ! echo "$out" | grep -q 'runtime error\|ERROR: AddressSanitizer'; then
			echo "PASS: seed $s, $mode: $(echo "$out" | tail -1)"
		else
			echo "FAIL: seed $s, $mode:"
			echo "$out" | grep -E 'runtime error|ERROR:|#[0-9] ' | head -12
			rc=1
		fi
	done
done
exit $rc
