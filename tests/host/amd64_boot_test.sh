#!/bin/sh
#
# tests/host/amd64_boot_test.sh
#
# Build the first x86-64 kernel (os/amd64) and boot it under every
# Multiboot loader that is available.  The kernel is generic; the
# loaders are hosts:
#
#   9vm  (https://github.com/kiljoy001/9vm) is a KVM microVM runner for
#        native Harvey, Purgatorio/Inferno and GEFS guests.  It loads the
#        ELF64 image, enters it in 32-bit protected mode with a Multiboot
#        information structure, and emulates a 16550 console at 0x3F8.
#
#   qemu-system-x86_64 loads the flat image (kernel.bin) through its
#        Multiboot option ROM.  QEMU refuses an ELF64 image ("give a
#        32bit one") unless the header carries the a.out kludge
#        addresses, and then loads the flat image instead.
#
# Set NINEVM or QEMU to override the binaries.  Exits 77 (skip) when the
# toolchain is missing or when neither loader is available.
#
# Run from the project root: ./tests/host/amd64_boot_test.sh
#

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CC=${CC:-$(command -v clang || true)}
LLD=${LLD:-$(command -v ld.lld || true)}
OBJCOPY=${OBJCOPY-$(command -v llvm-objcopy || command -v objcopy || true)}
NINEVM=${NINEVM-$ROOT/../9vm/9vm}
QEMU=${QEMU-$(command -v qemu-system-x86_64 || true)}
BUILD=${BAREMETAL_BUILD_DIR:-}

cleanup=0
if [ -z "$BUILD" ]; then
	BUILD=$(mktemp -d)
	cleanup=1
fi
trap 'if [ "$cleanup" = 1 ]; then rm -rf "$BUILD"; fi' 0

skip() {
	echo "SKIP: $*"
	exit 77
}

[ -n "$CC" ] || skip "clang not found"
[ -n "$LLD" ] || skip "ld.lld not found"

have9vm=0
[ -x "$NINEVM" ] && have9vm=1

haveqemu=0
[ -n "$QEMU" ] && [ -n "$OBJCOPY" ] && haveqemu=1

[ "$have9vm" = 1 ] || [ "$haveqemu" = 1 ] ||
	skip "neither 9vm nor qemu-system-x86_64 found"

CFLAGS="--target=x86_64-elf -ffreestanding -nostdlib
	-fno-stack-protector -fno-pic -mno-red-zone -mno-sse -mno-mmx
	-mcmodel=small -O2 -Wall -Wextra"

echo "== build"
# shellcheck disable=SC2086 # CFLAGS is a list of flags
$CC $CFLAGS -c "$ROOT/os/amd64/boot.S" -o "$BUILD/boot.o"
# shellcheck disable=SC2086
$CC $CFLAGS -c "$ROOT/os/amd64/main.c" -o "$BUILD/main.o"
$LLD -T "$ROOT/os/amd64/kernel.ld" -o "$BUILD/kernel.elf" \
	"$BUILD/boot.o" "$BUILD/main.o"

fails=0

capture() {
	# $1 seconds, $2 output file, then the command.  The kernel ends in
	# a halt loop, so stop the loader as soon as the halt line appears
	# rather than waiting for the timeout.
	_secs=$1
	_out=$2
	shift 2
	: > "$_out"
	"$@" >"$_out" 2>&1 &
	_pid=$!
	_i=0
	while [ "$_i" -lt "$_secs" ]; do
		grep -q "infernode/amd64: halted" "$_out" 2>/dev/null && break
		kill -0 "$_pid" 2>/dev/null || break
		sleep 1
		_i=$((_i + 1))
	done
	kill "$_pid" 2>/dev/null || true
	wait "$_pid" 2>/dev/null || true
	cat "$_out"
}

check() {
	# $1 is the loader name, $2 its console output
	echo "-- $1"
	printf '%s\n' "$2"
	for want in \
		"infernode/amd64: booting (Multiboot)" \
		"infernode/amd64: Multiboot at" \
		"infernode/amd64: memory map" \
		"infernode/amd64: halted"
	do
		case "$2" in
		*"$want"*) ;;
		*)
			echo "MISSING ($1): $want" >&2
			fails=$((fails + 1))
			;;
		esac
	done
}

ran=

if [ "$have9vm" = 1 ]; then
	ran="$ran 9vm"
	check 9vm "$(capture 10 "$BUILD/9vm.out" \
		"$NINEVM" -m 256 -c "amd64 boot test" "$BUILD/kernel.elf")"
fi

if [ "$haveqemu" = 1 ]; then
	ran="$ran qemu"
	$OBJCOPY -O binary "$BUILD/kernel.elf" "$BUILD/kernel.bin"
	check qemu "$(capture 10 "$BUILD/qemu.out" \
		"$QEMU" -m 256 -kernel "$BUILD/kernel.bin" -append "amd64 boot test" \
		-display none -serial stdio -monitor none -no-reboot)"
fi

[ "$fails" = 0 ] || exit 1
echo "PASS: x86-64 boot (${ran# })"
