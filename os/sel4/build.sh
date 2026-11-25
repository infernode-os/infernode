#!/bin/sh
#
# build.sh -- build the seL4 target's system image with the pinned Microkit
# SDK (tools/sel4/fetch.sh), clang and lld.
#
# Usage: os/sel4/build.sh [BOARD [CONFIG]]
#     BOARD   a Microkit board (default qemu_virt_aarch64)
#     CONFIG  debug, release or benchmark (default debug)
# The image is $ROOT/tmp/sel4/build/BOARD-CONFIG/loader.img; its path is
# printed.

set -eu
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BOARD="${1:-qemu_virt_aarch64}"
CONFIG="${2:-debug}"
SDK="$("$ROOT/tools/sel4/fetch.sh")"
BD="$SDK/board/$BOARD/$CONFIG"
[ -d "$BD" ] || { echo "build.sh: no board $BOARD/$CONFIG in $SDK" >&2; exit 2; }
OUT="$ROOT/tmp/sel4/build/$BOARD-$CONFIG"
SRC="$ROOT/os/sel4/hello"
mkdir -p "$OUT"

CC="clang -target aarch64-none-elf"
CFLAGS="-c -nostdlib -ffreestanding -g -O2 -Wall -Werror -mstrict-align -I$BD/include"
$CC $CFLAGS "$SRC/hello.c" -o "$OUT/hello.o"
ld.lld -L"$BD/lib" "$OUT/hello.o" -lmicrokit -Tmicrokit.ld -o "$OUT/hello.elf"
"$SDK/bin/microkit" "$SRC/hello.system" --search-path "$OUT" \
	--board "$BOARD" --config "$CONFIG" \
	-o "$OUT/loader.img" -r "$OUT/report.txt" >"$OUT/microkit.log"
echo "$OUT/loader.img"
