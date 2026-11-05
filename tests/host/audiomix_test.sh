#!/bin/sh
#
# audiomix_test.sh — the shared audio device's arithmetic
# (emu/port/audiomix.c) on the host, through tests/host/audiomix/mixtest.c:
# G.711 mu-law and A-law against their known values and their own round
# trip, 16- and 8-bit linear both ways, rate conversion (8, 16, 44.1 and
# 48 kHz: a second in is a second out, a tone keeps its frequency and is
# within linear interpolation's own error of itself, a stream converted
# in pieces is the stream converted whole), the queues (wrapping, the
# oldest dropped or the newest refused) and the mix (summed, ramped,
# clipped).  No emulator needed.
#
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }

case "$(uname -s)" in
Darwin)	sys=MacOSX ;;
*)	sys=Linux ;;
esac
case "$(uname -m)" in
x86_64|amd64)	arch=amd64 ;;
aarch64|arm64)	arch=arm64 ;;
riscv64)	arch=riscv64 ;;
*)		arch=amd64 ;;
esac
INC="$ROOT/$sys/$arch/include"
[ -f "$INC/lib9.h" ] || INC="$ROOT/Linux/amd64/include"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

"$CC" -O1 -I "$INC" -I "$ROOT/emu/port" -o "$TMP/mixtest" \
	"$ROOT/tests/host/audiomix/mixtest.c" "$ROOT/emu/port/audiomix.c" -lm ||
	{ echo "FAIL: audiomix did not compile"; exit 1; }
"$TMP/mixtest"
