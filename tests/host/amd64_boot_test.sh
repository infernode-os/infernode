#!/bin/sh
#
# tests/host/amd64_boot_test.sh
#
# Build the first x86-64 kernel (os/amd64) and its 9vm board (os/9vm),
# and boot it under every Multiboot loader that is available.
#
#   9vm  (https://github.com/kiljoy001/9vm) is a KVM microVM runner for
#        native Harvey, Purgatorio/Inferno and GEFS guests.  It loads the
#        ELF64 image, enters it in 32-bit protected mode with a Multiboot
#        information structure, emulates a 16550 console at 0x3F8, and
#        serves #~ shared-memory 9P rings for the top 2 MiB of RAM.
#        The test exports a small tree, asks the kernel for the ring
#        smoke test, and checks that the host filesystem and the ns
#        channel answer; the ns stub answers eight reads in reverse, so
#        the guest has to match completions by buffer, not by order.
#        A third boot adds -display-shm: the guest draws two frames into
#        the shared display at 0xF8000000, and tests/host/vmdisplay_check.c
#        verifies them pixel by pixel and sends the input that lets the
#        guest finish.
#
#        Two more boots exercise the machine layer: "kerneltest" crosses
#        a breakpoint, waits for timer interrupts and runs two preempted
#        threads; "pftest" faults outside the map and must report the
#        page fault and panic.  A third, "porttest", exercises the
#        os/port foundation: setlabel/gotolabel, _tas and spl masking.
#        A fourth, "proctest", runs os/port's own scheduler: two kernel
#        processes, sleep/wakeup through Rendezes, and a qlock.
#
#   qemu-system-x86_64 loads the flat image (kernel.bin) through its
#        Multiboot option ROM and runs the same "kerneltest".  QEMU refuses an ELF64 image ("give a
#        32bit one") unless the header carries the a.out kludge
#        addresses, and then loads the flat image instead.  It offers no
#        #~ ring; the kernel must still boot and report the map.
#
# Set NINEVM, QEMU or HOSTCC to override the binaries; set NINEVM or QEMU
# to the empty string to skip that loader.  Exits 77 (skip) when the
# toolchain is missing or when neither loader is available.
#
# Run from the project root: ./tests/host/amd64_boot_test.sh
#

set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CC=${CC:-$(command -v clang || true)}
LLD=${LLD:-$(command -v ld.lld || true)}
OBJCOPY=${OBJCOPY-$(command -v llvm-objcopy || command -v objcopy || true)}
HOSTCC=${HOSTCC-$(command -v cc || command -v gcc || command -v clang || true)}
NINEVM=${NINEVM-$ROOT/../9vm/9vm}
QEMU=${QEMU-$(command -v qemu-system-x86_64 || true)}
BUILD=${BAREMETAL_BUILD_DIR:-}

# the pattern file the ring test verifies: byte i is 'a' + i%26
SIZE=300000

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

# os/port's headers carry Plan 9 #pragmas clang does not know; the
# include path is the one the native kernel build uses.
CFLAGS="--target=x86_64-elf -ffreestanding -nostdlib
	-fno-stack-protector -fno-pic -mno-red-zone -mno-sse -mno-mmx
	-mcmodel=small -O2 -Wall -Wextra -Wno-unknown-pragmas
	-ffunction-sections -fdata-sections
	-I$ROOT/Inferno/amd64/include -I$ROOT/os/amd64
	-I$ROOT/os/port -I$ROOT/include -I$ROOT/libinterp -I$BUILD"

# os/port's error strings are generated from error.h, as its portmkfile
# does: each declaration becomes its definition.
sed 's/extern //;s,;.*/\* , = ",;s, \*/,";,' \
	< "$ROOT/os/port/error.h" > "$BUILD/errstr.h"

echo "== build"
objs=
for f in "$ROOT"/os/amd64/*.S "$ROOT"/os/amd64/*.c "$ROOT"/os/9vm/*.c \
	"$ROOT"/os/port/proc.c "$ROOT"/os/port/qlock.c \
	"$ROOT"/os/port/taslock.c "$ROOT"/os/port/alloc.c \
	"$ROOT"/os/port/xalloc.c "$ROOT"/os/port/alarm.c; do
	base=$(basename "$f")
	o="$BUILD/${base%.*}_${base##*.}.o"
	# shellcheck disable=SC2086
	$CC $CFLAGS -c "$f" -o "$o"
	objs="$objs $o"
done
# shellcheck disable=SC2086
$LLD -T "$ROOT/os/amd64/kernel.ld" --gc-sections \
	-o "$BUILD/kernel.elf" $objs

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

require() {
	# $1 loader name, $2 output, $3 line expected
	case "$2" in
	*"$3"*) ;;
	*)
		echo "MISSING ($1): $3" >&2
		fails=$((fails + 1))
		;;
	esac
}

check() {
	# the lines every loader must produce
	echo "-- $1"
	printf '%s\n' "$2"
	require "$1" "$2" "infernode/amd64: booting (Multiboot)"
	require "$1" "$2" "infernode/amd64: Multiboot at"
	require "$1" "$2" "infernode/amd64: memory map"
	require "$1" "$2" "infernode/amd64: halted"
}

ran=

if [ "$have9vm" = 1 ]; then
	mkdir -p "$BUILD/root/sub"
	printf 'hello from 9vm\n' > "$BUILD/root/sub/hello.txt"
	LC_ALL=C awk -v n="$SIZE" \
		'BEGIN { for (i = 0; i < n; i++) printf "%c", 97 + i % 26 }' \
		> "$BUILD/root/pattern.bin"
	have=$(wc -c < "$BUILD/root/pattern.bin")
	[ "$have" -eq "$SIZE" ] ||
		skip "awk did not write the $SIZE-byte test file"

	ran="$ran 9vm"
	out=$(capture 30 "$BUILD/9vm.out" "$NINEVM" -m 256 -r "$BUILD/root" \
		-c "amd64 boot test ringtest" "$BUILD/kernel.elf")
	check 9vm "$out"
	require 9vm "$out" "infernode/9vm: ring test passed"
	require 9vm "$out" "infernode/9vm: #~/0 host: 8 concurrent reads"
	require 9vm "$out" "$SIZE bytes verified"
fi

# The ns channel: 9vm relays #~/ns to a 9P server named with -ns.  The
# stub answers Tversion and Tattach, which is all the boot test asks.
if [ "$have9vm" = 1 ] && [ -n "$HOSTCC" ]; then
	if $HOSTCC -O2 -o "$BUILD/ns9p" "$ROOT/tests/host/ns9p_stub.c" \
		2>"$BUILD/ns9p.build"; then
		"$BUILD/ns9p" "$BUILD/ns.sock" &
		nspid=$!
		i=0
		while [ "$i" -lt 10 ]; do
			[ -S "$BUILD/ns.sock" ] && break
			sleep 1
			i=$((i + 1))
		done
		ran="$ran ns"
		out=$(capture 30 "$BUILD/ns.out" "$NINEVM" -m 256 \
			-r "$BUILD/root" -ns "unix!$BUILD/ns.sock" \
			-c "amd64 boot test ringtest" "$BUILD/kernel.elf")
		kill "$nspid" 2>/dev/null || true
		wait "$nspid" 2>/dev/null || true
		check ns "$out"
		require ns "$out" "infernode/9vm: ring test passed"
		require ns "$out" "infernode/9vm: #~/1 ns: 9P2000 msize"
		require ns "$out" "infernode/9vm: #~/1 ns: walked . while"
		require ns "$out" "infernode/9vm: #~/1 ns: 8 concurrent reads of 100 bytes, replies out of order"
	else
		echo "SKIP: ns channel: the stub did not build" >&2
		cat "$BUILD/ns9p.build" >&2
	fi
else
	echo "SKIP: ns channel: no host C compiler" >&2
fi

# The shared display: 9vm -display-shm maps it at 0xF8000000.  The guest
# draws two frames and waits for one input record; the checker verifies
# both slots and sends it.
if [ "$have9vm" = 1 ] && [ -n "$HOSTCC" ]; then
	if $HOSTCC -O2 -o "$BUILD/vmdisplay_check" \
		"$ROOT/tests/host/vmdisplay_check.c" 2>"$BUILD/disp.build"; then
		dname="/infernode-disp-$$"
		"$BUILD/vmdisplay_check" "$dname" \
			>"$BUILD/dispchk.out" 2>&1 &
		chkpid=$!
		ran="$ran display"
		out=$(capture 40 "$BUILD/disp.out" "$NINEVM" -m 256 \
			-display-shm "$dname" -c "amd64 boot test disptest" \
			"$BUILD/kernel.elf")
		check display "$out"
		chkstatus=0
		wait "$chkpid" || chkstatus=$?
		cat "$BUILD/dispchk.out"
		if [ "$chkstatus" -ne 0 ]; then
			echo "MISSING (display): the host checker failed ($chkstatus)" >&2
			fails=$((fails + 1))
		fi
		require display "$out" "infernode/9vm: display 1024x768"
		require display "$out" "infernode/9vm: display input: key 113 0"
		require display "$out" "infernode/9vm: display test passed"
	else
		echo "SKIP: display: the checker did not build" >&2
		cat "$BUILD/disp.build" >&2
	fi
else
	echo "SKIP: display: no host C compiler" >&2
fi

# The machine layer: traps, the timer and preemptive threads.
if [ "$have9vm" = 1 ]; then
	ran="$ran trap"
	out=$(capture 30 "$BUILD/trap.out" "$NINEVM" -m 256 \
		-c "amd64 boot test kerneltest" "$BUILD/kernel.elf")
	check trap "$out"
	require trap "$out" "infernode/amd64: trap 3 breakpoint"
	require trap "$out" "infernode/amd64: timer advanced"
	require trap "$out" "infernode/amd64: threads a"
	require trap "$out" "infernode/amd64: kerneltest passed"

	ran="$ran fault"
	out=$(capture 30 "$BUILD/fault.out" "$NINEVM" -m 256 \
		-c "amd64 boot test pftest" "$BUILD/kernel.elf")
	check fault "$out"
	require fault "$out" \
		"infernode/amd64: trap 14 page fault err 0x0000000000000002"
	require fault "$out" "cr2 0x00000000dead0000"
	require fault "$out" "infernode/amd64: panic"

	ran="$ran port"
	out=$(capture 30 "$BUILD/port.out" "$NINEVM" -m 256 \
		-c "amd64 boot test porttest" "$BUILD/kernel.elf")
	check port "$out"
	require port "$out" "infernode/amd64: port: labels ok"
	require port "$out" "infernode/amd64: port: tas ok"
	require port "$out" "infernode/amd64: port: spl ok"
	require port "$out" "infernode/amd64: porttest passed"

	ran="$ran proc"
	out=$(capture 30 "$BUILD/proc.out" "$NINEVM" -m 256 \
		-c "amd64 boot test proctest" "$BUILD/kernel.elf")
	check proc "$out"
	require proc "$out" "proctest: A has qlock"
	require proc "$out" "proctest: B has qlock"
	require proc "$out" "proctest: A woke"
	require proc "$out" "proctest: proctest passed"
fi

if [ "$haveqemu" = 1 ]; then
	ran="$ran qemu"
	$OBJCOPY -O binary "$BUILD/kernel.elf" "$BUILD/kernel.bin"
	out=$(capture 30 "$BUILD/qemu.out" \
		"$QEMU" -m 256 -kernel "$BUILD/kernel.bin" \
		-append "amd64 boot test kerneltest" \
		-display none -serial stdio -monitor none -no-reboot)
	check qemu "$out"
	require qemu "$out" "infernode/amd64: kerneltest passed"
fi

[ "$fails" = 0 ] || exit 1
echo "PASS: x86-64 boot (${ran# })"
