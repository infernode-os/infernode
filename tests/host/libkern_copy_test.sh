#!/bin/bash
#
# tests/host/libkern_copy_test.sh
#
# The native kernels' memmove, memcpy and memset (libkern/memmove.c,
# libkern/memset.c), eight bytes at a time in general registers:
#
#   - built on the host under other names with
#     tests/host/libkern_copy/copytest.c, against byte-by-byte references:
#     every alignment of source and destination, lengths 0 to 300 and
#     some past 4096, overlaps either way at every distance up to 40,
#     the bytes either side of the destination untouched; under
#     AddressSanitizer and UndefinedBehaviorSanitizer where the compiler
#     has them
#   - built as each native kernel builds them (arm64 -mgeneral-regs-only,
#     riscv64 rv64gc), where clang can: no FP or SIMD register in the
#     arm64 object (interrupt paths call these), and no call from
#     memmove or memset to memcpy, memmove or memset (a compiler can turn
#     a copy loop into one, and memcpy here is memmove)
#
# No emulator is needed.
#
# Run from project root: ./tests/host/libkern_copy_test.sh
#

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$(dirname "$0")/common.sh"

D="$ROOT/tests/host/libkern_copy"
CC="${CC:-cc}"
command -v "$CC" >/dev/null 2>&1 || { echo "SKIP: no C compiler"; exit 77; }
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fail=0

# The host build: renamed, and with the compiler's own idea of copying
# off, so what runs is libkern's code and not the host's memcpy.
nobuiltin="-fno-builtin"
"$CC" -fno-tree-loop-distribute-patterns -x c -c -o /dev/null /dev/null 2>/dev/null &&
	nobuiltin="$nobuiltin -fno-tree-loop-distribute-patterns"
san=""
"$CC" -fsanitize=address,undefined -x c -o "$T/probe" - <<<'int main(void){return 0;}' 2>/dev/null &&
	san="-fsanitize=address,undefined -fno-sanitize-recover=undefined"
ren="-Dmemmove=kmemmove -Dmemcpy=kmemcpy -Dmemset=kmemset"
for opt in -O0 -O2; do
	"$CC" $opt -g -Wall $nobuiltin $san $ren -I"$D/inc" -c "$ROOT/libkern/memmove.c" -o "$T/memmove.o" &&
	"$CC" $opt -g -Wall $nobuiltin $san $ren -I"$D/inc" -c "$ROOT/libkern/memset.c" -o "$T/memset.o" &&
	"$CC" $opt -g -Wall $san "$D/copytest.c" "$T/memmove.o" "$T/memset.o" -o "$T/copytest" || {
		echo "FAIL: host build ($opt)"; exit 1; }
	if out=$("$T/copytest" 2>&1); then
		echo "PASS: host $opt${san:+ sanitized}: $out"
	else
		echo "FAIL: host $opt: $out"
		fail=1
	fi
done

# The kernels' builds, as tests/host/baremetal_test.sh and
# baremetal_riscv64_test.sh compile libkern.
objcheck() {
	local name="$1" obj="$2" dis regs
	dis=$(llvm-objdump -dr --no-show-raw-insn "$obj" 2>/dev/null) || { echo "SKIP: $name: no llvm-objdump"; return; }
	# a call or a relocation naming a copy, inside memmove or memset:
	# a relocation against one, or a branch to one's first instruction
	# (a branch within the function itself is to <memmove+0x...>)
	if echo "$dis" | awk '/^[0-9a-f]+ <[^>]+>:/ { f = $2; next }
		f ~ /^<(memmove|memset)>:$/ && (/R_[A-Z0-9_]+[ \t]+mem(cpy|move|set)/ || /<mem(cpy|move|set)>/) { print; bad = 1 }
		END { exit bad }'; then
		echo "PASS: $name: $(basename "$obj" .o): no call to a copy"
	else
		echo "FAIL: $name: $(basename "$obj" .o) calls a copy (above)"
		fail=1
	fi
	if [ "$name" = arm64 ]; then
		# the instructions alone, without the addresses (d0: is not a register)
		regs=$(echo "$dis" | grep -E '^ +[0-9a-f]+:' | sed -E 's/^ +[0-9a-f]+:[[:space:]]*//' |
			grep -E '(^|[^a-z0-9_])[qvdsh][0-9]{1,2}([^0-9]|$)')
		if [ -n "$regs" ]; then
			echo "FAIL: arm64: $(basename "$obj" .o) uses FP/SIMD registers:"; echo "$regs" | head -3
			fail=1
		else
			echo "PASS: arm64: $(basename "$obj" .o): general registers only"
		fi
	fi
}
if command -v clang >/dev/null 2>&1; then
	kflags=(-ffreestanding -nostdlib -O2 -fno-omit-frame-pointer -Wall -Wextra -Werror=missing-declarations
		-I"$ROOT/include" -I"$ROOT/libkern")
	if clang --target=aarch64-elf -mgeneral-regs-only "${kflags[@]}" -I"$ROOT/Inferno/arm64/include" \
		-c "$ROOT/libkern/memmove.c" -o "$T/a64-memmove.o" 2>"$T/a64.log" &&
	   clang --target=aarch64-elf -mgeneral-regs-only "${kflags[@]}" -I"$ROOT/Inferno/arm64/include" \
		-c "$ROOT/libkern/memset.c" -o "$T/a64-memset.o" 2>>"$T/a64.log"; then
		objcheck arm64 "$T/a64-memmove.o"
		objcheck arm64 "$T/a64-memset.o"
	else
		echo "SKIP: arm64 kernel build ($(head -1 "$T/a64.log"))"
	fi
	rv=(--target=riscv64-unknown-elf -march=rv64gc -mabi=lp64d -mcmodel=medany -mno-relax)
	if clang "${rv[@]}" "${kflags[@]}" -I"$ROOT/Inferno/riscv64/include" -c "$ROOT/libkern/memmove.c" -o "$T/rv-memmove.o" 2>"$T/rv.log" &&
	   clang "${rv[@]}" "${kflags[@]}" -I"$ROOT/Inferno/riscv64/include" -c "$ROOT/libkern/memset.c" -o "$T/rv-memset.o" 2>>"$T/rv.log"; then
		objcheck riscv64 "$T/rv-memmove.o"
		objcheck riscv64 "$T/rv-memset.o"
	else
		echo "SKIP: riscv64 kernel build ($(head -1 "$T/rv.log"))"
	fi
else
	echo "SKIP: kernel builds (no clang)"
fi

exit $fail
