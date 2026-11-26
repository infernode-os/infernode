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
#        processes, sleep/wakeup through Rendezes, and a qlock.  A fifth,
#        "preemptest", proves the clock preempts a CPU-bound process and
#        that a timed sleep expires.  A sixth, "clocktest", checks the
#        TSC's rate through todget and the periodic timer queue.  A
#        seventh, "qiotest", moves data between two processes through a
#        Block queue whose limit forces the writer to block too.  An
#        eighth, "chantest", drives the device table and channels end to
#        end with a pipe.  A ninth, "ringdevtest", speaks 9P over the #~
#        device, and a tenth, "mounttest", mounts that connection through
#        devmnt on the root device's /n and reads a file through it.
#        An eleventh, "vmtest", hands the machine to the Dis VM: it
#        interprets /dis/vmtest.dis out of the root image, prints through
#        the Sys module and computes with REALs (SSE).  A kernel process
#        does the same for a second of ticks to prove the scheduler saves
#        the FP state, and halts the machine.
#
#        A twelfth, "shelltest", boots to a prompt with the JIT on:
#        init binds #c at
#        /dev, #p at /prog and #I at /net, mounts #~/ns at /n/remote
#        when the loader offers it, and runs /dis/sh.dis.  The harness
#        types a command and then "echo halt > /dev/sysctl" through a
#        fifo, one line at a time, and requires the shell's answer
#        before it sends the halt.  Under 9vm with the ns stub the
#        command is "cat /n/remote/hello", read through the ring.
#
#        "jittest" and "interptest" run the same module with the code
#        generator on and off; the harness requires the same answers
#        from both, and a "compiled" line from the generator (a compile
#        that fails falls back to the interpreter silently).
#
#        A thirteenth, "nettest", links os/ip and proves it moves data:
#        loopback at 127.0.0.1, an ICMP echo, a TCP echo through the
#        handshake, and the host namespace mounted.  Under QEMU it is
#        given a virtio-net-pci device on a user-network backend, so
#        the same boot also brings ether0 up at 10.0.2.15, pings the
#        slirp gateway, and opens a TCP connection to a host echo
#        server at 10.0.2.2 -- the frames cross the virtio rings in
#        both directions, interrupts and all.  Under 9vm there is no TAP to be had (that needs
#        CAP_NET_ADMIN), so the boot checks that the absence is
#        reported and loopback still works.
#
#   qemu-system-x86_64 loads the flat image (kernel.bin) through its
#        Multiboot option ROM and runs "kerneltest", "vmtest",
#        "shelltest" and "nettest".  The network test gets a
#        virtio-net-pci device (modern transport) on QEMU's user-mode
#        network.  QEMU
#        refuses an ELF64 image ("give a 32bit one") unless the header
#        carries the a.out kludge addresses, and then loads the flat
#        image instead.  It offers no #~ ring; the kernel must still boot
#        and report the map, and the Dis VM needs nothing from the ring.
#
# Set NINEVM, QEMU, HOSTCC, PYTHON or LIMBO to override the tools; set
# NINEVM or QEMU to the empty string to skip that loader.  Exits 77 (skip)
# when the toolchain, python3 (which generates the root image), limbo
# (which generates runt.h/sysmod.h and the test module) or both loaders
# are missing.
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
PYTHON=${PYTHON-$(command -v python3 || true)}
LIMBO=${LIMBO-$(command -v limbo || true)}
[ -n "$LIMBO" ] || [ ! -x "$ROOT/Linux/amd64/bin/limbo" ] || \
	LIMBO="$ROOT/Linux/amd64/bin/limbo"
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
	-I$ROOT/os/port -I$ROOT/include -I$ROOT/libinterp
	-I$ROOT/libmp -I$BUILD"

# The same include path with SSE enabled, for libinterp and the two
# kernel files that must see an XMM argument or hold a double.
CFLAGS_VM="--target=x86_64-elf -ffreestanding -nostdlib
	-fno-stack-protector -fno-pic -mno-red-zone -msse2
	-mcmodel=small -O2 -Wall -Wextra -Wno-unknown-pragmas
	-DINFERNO_NATIVE -ffunction-sections -fdata-sections
	-I$ROOT/Inferno/amd64/include -I$ROOT/os/amd64
	-I$ROOT/os/port -I$ROOT/include -I$ROOT/libinterp
	-I$ROOT/libmp -I$BUILD"

# os/port's error strings are generated from error.h, as its portmkfile
# does: each declaration becomes its definition.
sed 's/extern //;s,;.*/\* , = ",;s, \*/,";,' \
	< "$ROOT/os/port/error.h" > "$BUILD/errstr.h"

# runt.h and sysmod.h are GENERATED by the Limbo compiler from
# module/runt.m, exactly as libinterp's mkfile does it: the C view of
# the Dis module interfaces os/port/dis.c, inferno.c and exception.c are
# written against.  Generated rather than committed so the declarations
# cannot drift from the Limbo definitions they describe.
[ -n "$LIMBO" ] || skip "limbo not found (it generates runt.h/sysmod.h and the test module)"
"$LIMBO" -a -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/runt.h" ||
	skip "limbo could not generate runt.h"
"$LIMBO" -t Sys -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/sysmod.h" ||
	skip "limbo could not generate sysmod.h"
"$LIMBO" -t Math -I"$ROOT/module" "$ROOT/module/runt.m" > "$BUILD/mathmod.h" ||
	skip "limbo could not generate mathmod.h"

# The Limbo programs the kernel loads out of its root image: the vmtest
# module, and init, which binds #c at /dev and hands over to the shell.
"$LIMBO" -I"$ROOT/module" -o "$BUILD/vmtest.dis" "$ROOT/os/amd64/vmtest.b" ||
	skip "limbo could not compile os/amd64/vmtest.b"
"$LIMBO" -I"$ROOT/module" -o "$BUILD/init.dis" "$ROOT/os/amd64/init.b" ||
	skip "limbo could not compile os/amd64/init.b"
"$LIMBO" -I"$ROOT/module" -o "$BUILD/nettest.dis" "$ROOT/os/amd64/nettest.b" ||
	skip "limbo could not compile os/amd64/nettest.b"
"$LIMBO" -I"$ROOT/module" -o "$BUILD/jittest.dis" "$ROOT/os/amd64/jittest.b" ||
	skip "limbo could not compile os/amd64/jittest.b"

# The kernel's root filesystem: /n and /m for the mount test, /dev for
# init to bind #c on, the Dis modules for the VM and the shell, and the
# shell's profile.  Generated by the same tool the native kernel uses.
# It is linked into every image, so python3 is a prerequisite of the
# harness rather than something a single boot can do without: an
# ungenerated rootfs.c would otherwise be compiled.
#
# sh's initialise() loads Filepat, String, Bufio, Env and Arg and calls
# badmodule() -- which is fatal -- on any that is missing, and its -l
# profile does "load std".  They are all here, with echo for the shell
# boot to run.
[ -n "$PYTHON" ] || skip "python3 not found (it generates the root image)"
$PYTHON "$ROOT/tools/mkrootfs.py" "$BUILD/rootfs.c" \
	/n= /n/remote= /m= /dev= /prog= /net= /tmp= \
	/init.dis="$BUILD/init.dis" \
	/nettest.dis="$BUILD/nettest.dis" \
	/jittest.dis="$BUILD/jittest.dis" \
	/dis/vmtest.dis="$BUILD/vmtest.dis" \
	/dis/sh.dis="$ROOT/dis/sh.dis" \
	/dis/lib/filepat.dis="$ROOT/dis/lib/filepat.dis" \
	/dis/lib/string.dis="$ROOT/dis/lib/string.dis" \
	/dis/lib/bufio.dis="$ROOT/dis/lib/bufio.dis" \
	/dis/lib/env.dis="$ROOT/dis/lib/env.dis" \
	/dis/lib/arg.dis="$ROOT/dis/lib/arg.dis" \
	/dis/sh/std.dis="$ROOT/dis/sh/std.dis" \
	/dis/echo.dis="$ROOT/dis/echo.dis" \
	/dis/cat.dis="$ROOT/dis/cat.dis" \
	/dis/ls.dis="$ROOT/dis/ls.dis" \
	/dis/cd.dis="$ROOT/dis/cd.dis" \
	/dis/pwd.dis="$ROOT/dis/pwd.dis" \
	/dis/date.dis="$ROOT/dis/date.dis" \
	/dis/ps.dis="$ROOT/dis/ps.dis" \
	/dis/lib/readdir.dis="$ROOT/dis/lib/readdir.dis" \
	/dis/lib/daytime.dis="$ROOT/dis/lib/daytime.dis" \
	/dis/lib/workdir.dis="$ROOT/dis/lib/workdir.dis" \
	/lib/sh/profile="$ROOT/os/amd64/profile" ||
	skip "mkrootfs.py failed"

# Two sets of flags.
#
# CFLAGS builds the kernel core with SSE off: no interrupt path may
# touch floating point state that is not being saved.  VFLAGS builds
# libinterp, the Dis REAL machinery and the two files that must see an
# SSE argument (os/port/printfp.c formats a double, and fpwork.c is the
# process that proves the scheduler preserves one).
VFLAGS="$CFLAGS_VM"

echo "== build"
objs=
for f in "$ROOT"/os/amd64/*.S "$ROOT"/os/amd64/*.c "$ROOT"/os/9vm/*.c \
	"$ROOT"/os/port/proc.c "$ROOT"/os/port/qlock.c \
	"$ROOT"/os/port/taslock.c "$ROOT"/os/port/alloc.c \
	"$ROOT"/os/port/xalloc.c "$ROOT"/os/port/alarm.c \
	"$ROOT"/os/port/portclock.c "$ROOT"/os/port/tod.c \
	"$ROOT"/os/port/mul64fract.c "$ROOT"/os/port/qio.c \
	"$ROOT"/os/port/allocb.c "$ROOT"/os/port/dev.c \
	"$ROOT"/os/port/chan.c "$ROOT"/os/port/devpipe.c \
	"$ROOT"/os/port/pgrp.c "$ROOT"/os/port/sysfile.c \
	"$ROOT"/os/port/devenv.c "$ROOT"/os/port/dial.c \
	"$ROOT"/os/port/devsrv.c "$ROOT"/os/port/exportfs.c \
	"$ROOT"/os/port/devprog.c "$ROOT"/os/port/discall.c \
	"$ROOT"/libkern/vseprint.c "$ROOT"/libkern/dofmt.c \
	"$ROOT"/libkern/fmt.c "$ROOT"/libkern/fmtprint.c \
	"$ROOT"/libkern/fmtquote.c "$ROOT"/libkern/fmtstr.c \
	"$ROOT"/libkern/fmtvprint.c "$ROOT"/libkern/seprint.c \
	"$ROOT"/libkern/vsnprint.c "$ROOT"/libkern/smprint.c \
	"$ROOT"/libkern/vsmprint.c "$ROOT"/libkern/rune.c \
	"$ROOT"/libkern/cleanname.c "$ROOT"/libkern/convD2M.c \
	"$ROOT"/libkern/convM2D.c "$ROOT"/libkern/memchr.c \
	"$ROOT"/libkern/strchr.c "$ROOT"/libkern/strncpy.c \
	"$ROOT"/libkern/utflen.c "$ROOT"/libkern/utfnlen.c \
	"$ROOT"/libkern/utfrune.c "$ROOT"/libkern/atol.c \
	"$ROOT"/libkern/strncmp.c "$ROOT"/libkern/strtoll.c \
	"$ROOT"/libkern/tokenize.c \
	"$ROOT"/os/port/devcons.c "$ROOT"/os/port/parse.c \
	"$ROOT"/os/port/latin1.c "$ROOT"/os/port/devroot.c \
	"$ROOT"/os/port/devmnt.c "$ROOT"/os/port/nocache.c \
	"$ROOT"/libkern/convS2M.c "$ROOT"/libkern/convM2S.c \
	"$ROOT"/libkern/fcallfmt.c "$ROOT"/libkern/strecpy.c \
	"$ROOT"/libkern/memccpy.c "$ROOT"/libkern/getfields.c \
	"$ROOT"/os/port/devether.c "$ROOT"/os/port/netif.c \
	"$ROOT"/os/port/netaux.c "$ROOT"/os/ip/*.c \
	"$ROOT"/libsec/sha2.c "$ROOT"/libsec/hmac.c \
	"$ROOT"/libsec/sha256block.c "$ROOT"/libsec/sha512block.c \
	"$ROOT"/libsec/securezero.c "$BUILD"/rootfs.c; do
	# fpwork.c is built with VFLAGS below: it is the SSE user.
	case "$(basename "$f")" in fpwork.c) continue;; esac
	base=$(basename "$f")
	o="$BUILD/${base%.*}_${base##*.}.o"
	# os/ip is imported wholesale: warnings suppressed, except the two
	# that mark Plan 9 C dialect, which are errors for the same reason
	# the os/port files are.
	case "$f" in
	"$ROOT"/os/ip/*) wf="-Wno-everything -Werror=incompatible-pointer-types -Werror=implicit-function-declaration";;
	*) wf=;;
	esac
	# shellcheck disable=SC2086
	$CC $CFLAGS $wf -c "$f" -o "$o"
	objs="$objs $o"
done

# os/port/printfp.c holds snprint and sprint, the two variadic entry
# points a Dis REAL is formatted through.  They are part of the
# floating point path (their callers pass a double through va_arg), so
# they are built with the VM's flags and libkern's own copies of the two
# are left out above.
# shellcheck disable=SC2086
$CC $VFLAGS -c "$ROOT/os/port/printfp.c" -o "$BUILD/printfp.o"
objs="$objs $BUILD/printfp.o"

# fpwork.c, the process that computes with doubles while the Dis VM
# does the same: without procsave/procrestore the two would corrupt each
# other's XMM registers.
# shellcheck disable=SC2086
$CC $VFLAGS -c "$ROOT/os/amd64/fpwork.c" -o "$BUILD/fpwork.o"
objs="$objs $BUILD/fpwork.o"

# libinterp -- the Dis VM.
#
# EXACTLY ONE code generator may be linked: libinterp ships ten comp-*.c
# and each defines compile(), preamble() and comvec.  None is linked
# here; os/amd64/nocomp.c provides the symbols and says a module is
# interpreted.  comp-amd64.c needs mmap() for the code window it writes,
# which arrives with the JIT stage.
#
# Excluded too: the optional modules (draw, tk, math's neighbours,
# keyring, ipint, i420, tensor, bayer), each of which needs its own
# generated header and, for keyring, the whole crypto stack.  $Math IS
# included -- libinterp/math.c and fdlibm -- because $g/%f formatting
# and a real the test computes are the point.
for f in "$ROOT"/libinterp/*.c; do
	case "$(basename "$f")" in
	comp-amd64.c|das-amd64.c) ;;	# the one generator and its disassembler
	comp-*.c|das-*.c|draw.c|tk.c|decgen.c|i420.c|tensor.c|bayer.c|keyring.c) continue;;
	esac
	o="$BUILD/libinterp-$(basename "$f").o"
	# shellcheck disable=SC2086
	$CC $VFLAGS -I"$BUILD" -Wno-everything -c "$f" -o "$o"
	objs="$objs $o"
done

# os/port's half of the VM: the scheduler (dis.c), the Dis exception
# machinery, and the Sys module's system calls.
for f in dis.c exception.c inferno.c; do
	# shellcheck disable=SC2086
	$CC $VFLAGS -I"$BUILD" -Wno-everything -c "$ROOT/os/port/$f" -o "$BUILD/vm-$f.o"
	objs="$objs $BUILD/vm-$f.o"
done

# libmath: fdlibm for $Math, and the double-to-digits code behind %g.
# FPcontrol-Inferno.c is this kernel's own FPcontrol (the other
# seventeen are per host and define the same three symbols).
# libkernfp carries charstod and the power-of-ten table dtoa needs;
# its strtod.c is left out because libmath/dtoa.c defines strtod.
for f in "$ROOT"/libmath/fdlibm/*.c "$ROOT"/libmath/fdim.c \
	"$ROOT"/libmath/blas.c "$ROOT"/libmath/gemm.c \
	"$ROOT"/libmath/dtoa.c "$ROOT"/libmath/g_fmt.c \
	"$ROOT"/libmath/gfltconv.c "$ROOT"/libmath/FPcontrol-Inferno.c \
	"$ROOT"/libkernfp/*.c; do
	case "$(basename "$f")" in strtod.c) continue;; esac
	o="$BUILD/vmlib-$(basename "$f").o"
	# shellcheck disable=SC2086
	$CC $VFLAGS -I"$ROOT/libmath/fdlibm" -I"$BUILD" -Wno-everything -c "$f" -o "$o"
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

shellboot() {
	# Boot to a shell and type at it.
	#
	# Input goes through a fifo, written in step with the output: the
	# 16550's receive FIFO is sixteen bytes on QEMU, and the shell is
	# not reading when the loader starts. The first line is sent only
	# once init says the shell is starting; halt is sent only once the
	# shell has answered it, so the halt cannot overtake the echo.
	#
	# $1 label, $2 output file, $3 the line to type, $4 what it must
	# print, then the loader command.
	_label=$1
	_out=$2
	_cmd=$3
	_expect=$4
	shift 4
	rm -f "$BUILD/shellin"
	mkfifo "$BUILD/shellin"
	: > "$_out"
	(
		exec 3>"$BUILD/shellin"
		i=0
		while [ "$i" -lt 60 ]; do
			grep -q "init: starting the shell" "$_out" 2>/dev/null && break
			sleep 1
			i=$((i + 1))
		done
		printf '%s\n' "$_cmd" >&3 || exit 0
		i=0
		while [ "$i" -lt 30 ]; do
			grep -q "$_expect" "$_out" 2>/dev/null && break
			sleep 1
			i=$((i + 1))
		done
		printf 'echo halt > /dev/sysctl\n' >&3 || exit 0
	) &
	_feed=$!
	"$@" < "$BUILD/shellin" > "$_out" 2>&1 &
	_pid=$!
	i=0
	while [ "$i" -lt 60 ]; do
		grep -q "infernode/amd64: halted" "$_out" 2>/dev/null && break
		kill -0 "$_pid" 2>/dev/null || break
		sleep 1
		i=$((i + 1))
	done
	kill "$_pid" 2>/dev/null || true
	wait "$_pid" 2>/dev/null || true
	kill "$_feed" 2>/dev/null || true
	wait "$_feed" 2>/dev/null || true
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

	ran="$ran preempt"
	out=$(capture 30 "$BUILD/preempt.out" "$NINEVM" -m 256 \
		-c "amd64 boot test preemptest" "$BUILD/kernel.elf")
	check preempt "$out"
	require preempt "$out" "preempt: hog advanced"
	require preempt "$out" "preemptest passed"

	ran="$ran clock"
	out=$(capture 30 "$BUILD/clock.out" "$NINEVM" -m 256 \
		-c "amd64 boot test clocktest" "$BUILD/kernel.elf")
	check clock "$out"
	require clock "$out" "clock: slept"
	require clock "$out" "clocktest passed"

	ran="$ran qio"
	out=$(capture 30 "$BUILD/qio.out" "$NINEVM" -m 256 \
		-c "amd64 boot test qiotest" "$BUILD/kernel.elf")
	check qio "$out"
	require qio "$out" "qio: read 11 \"hello world\""
	require qio "$out" "qiotest passed"

	ran="$ran fmt"
	out=$(capture 30 "$BUILD/fmt.out" "$NINEVM" -m 256 \
		-c "amd64 boot test fmttest" "$BUILD/kernel.elf")
	check fmt "$out"
	require fmt "$out" "fmttest passed"

	ran="$ran chan"
	out=$(capture 30 "$BUILD/chan.out" "$NINEVM" -m 256 \
		-c "amd64 boot test chantest" "$BUILD/kernel.elf")
	check chan "$out"
	require chan "$out" "chantest: read 5 \"hello\""
	require chan "$out" "chantest passed"
	require chan "$out" "console from #c/cons"

	ran="$ran ringdev"
	out=$(capture 30 "$BUILD/ringdev.out" "$NINEVM" -m 256 \
		-r "$BUILD/root" -c "amd64 boot test ringdevtest" \
		"$BUILD/kernel.elf")
	check ringdev "$out"
	require ringdev "$out" "ringdev: 9P2000 msize 32768"
	require ringdev "$out" "ringdev: a second open of the channel is refused"
	require ringdev "$out" "ringdev: the channel reopens after a clean close"
	require ringdev "$out" "ringdev: read 15 \"hello from 9vm"
	require ringdev "$out" "ringdevtest passed"

	ran="$ran mount"
	if [ -x "$BUILD/ns9p" ]; then
		"$BUILD/ns9p" "$BUILD/nsmount.sock" &
		nsmpid=$!
		i=0
		while [ "$i" -lt 10 ]; do
			[ -S "$BUILD/nsmount.sock" ] && break
			sleep 1
			i=$((i + 1))
		done
		out=$(capture 30 "$BUILD/mount.out" "$NINEVM" -m 256 \
			-r "$BUILD/root" -ns "unix!$BUILD/nsmount.sock" \
			-c "amd64 boot test mounttest" "$BUILD/kernel.elf")
		kill "$nsmpid" 2>/dev/null || true
		wait "$nsmpid" 2>/dev/null || true
		check mount "$out"
		require mount "$out" "mounttest: #~/ns mounted on /m"
		require mount "$out" "mounttest: ns read 14"
	else
		out=$(capture 30 "$BUILD/mount.out" "$NINEVM" -m 256 \
			-r "$BUILD/root" -c "amd64 boot test mounttest" \
			"$BUILD/kernel.elf")
		check mount "$out"
	fi
	require mount "$out" "mounttest: #~/host mounted on /n"
	require mount "$out" "mounttest: read 15"
	require mount "$out" "mounttest passed"

	ran="$ran vm"
	out=$(capture 30 "$BUILD/vm.out" "$NINEVM" -m 256 \
		-c "amd64 boot test vmtest" "$BUILD/kernel.elf")
	check vm "$out"
	require vm "$out" "Initial Dis: \"/dis/vmtest.dis\""
	require vm "$out" "vmtest: the Dis VM is running in the kernel"
	require vm "$out" "vmtest: 6*7=42"
	require vm "$out" "vmtest: 1.5*2.0=3, 1.5+2.0=3.5"
	require vm "$out" "vmtest: string \"kernel\" array[3]=42"
	require vm "$out" "vmtest: fp worker ok"
	require vm "$out" "vmtest passed"

	ran="$ran shell"
	if [ -x "$BUILD/ns9p" ]; then
		"$BUILD/ns9p" "$BUILD/nsshell.sock" &
		nsspid=$!
		i=0
		while [ "$i" -lt 10 ]; do
			[ -S "$BUILD/nsshell.sock" ] && break
			sleep 1
			i=$((i + 1))
		done
		out=$(shellboot shell "$BUILD/shell9.out" \
			"cd /dis; ls; cat /n/remote/hello" "hello from ns" \
			"$NINEVM" -m 256 -ns "unix!$BUILD/nsshell.sock" \
			-c "amd64 boot test shelltest" "$BUILD/kernel.elf")
		kill "$nsspid" 2>/dev/null || true
		wait "$nsspid" 2>/dev/null || true
		check shell "$out"
		require shell "$out" "init: #~/ns mounted at /n/remote"
		require shell "$out" "jit: Sh compiled"
		require shell "$out" "jit: Cat compiled"
		require shell "$out" "jit: Ls compiled"
		require shell "$out" "sh.dis"
		require shell "$out" "hello from ns"
	else
		out=$(shellboot shell "$BUILD/shell9.out" \
			"cd /dis; ls; echo hello from the shell" "hello from the shell" \
			"$NINEVM" -m 256 \
			-c "amd64 boot test shelltest" "$BUILD/kernel.elf")
		check shell "$out"
		require shell "$out" "jit: Sh compiled"
		require shell "$out" "sh.dis"
		require shell "$out" "hello from the shell"
	fi
	require shell "$out" "init: starting the shell"

	ran="$ran net"
	if [ -x "$BUILD/ns9p" ]; then
		"$BUILD/ns9p" "$BUILD/nsnet.sock" &
		nsnpid=$!
		i=0
		while [ "$i" -lt 10 ]; do
			[ -S "$BUILD/nsnet.sock" ] && break
			sleep 1
			i=$((i + 1))
		done
		out=$(capture 40 "$BUILD/net.out" "$NINEVM" -m 256 \
			-r "$BUILD/root" -ns "unix!$BUILD/nsnet.sock" \
			-c "amd64 boot test nettest" "$BUILD/kernel.elf")
		kill "$nsnpid" 2>/dev/null || true
		wait "$nsnpid" 2>/dev/null || true
	else
		out=$(capture 40 "$BUILD/net.out" "$NINEVM" -m 256 \
			-r "$BUILD/root" -c "amd64 boot test nettest" \
			"$BUILD/kernel.elf")
	fi
	check net "$out"
	require net "$out" "jit: Nettest compiled"
	require net "$out" "nettest: #I bound at /net"
	require net "$out" "nettest: 127.0.0.1/8 on ipifc"
	require net "$out" "nettest: no ethernet device"
	require net "$out" "nettest: icmp echo reply"
	require net "$out" "nettest: tcp echo over loopback"
	if [ -x "$BUILD/ns9p" ]; then
		require net "$out" "nettest: #~/ns mounted at /n/remote"
		require net "$out" "nettest: ns read 14"
	else
		require net "$out" "nettest: no #~ namespace on this loader"
	fi
	require net "$out" "nettest passed"

	# The JIT, and the interpreter it must agree with: the same module,
	# the same answers.  A compile that fails falls back silently, so
	# the "compiled" line is what says the generator ran.
	for _gen in 1 0; do
		if [ "$_gen" = 1 ]; then
			_gname=jit
			_gword=jittest
			_gexpect="jittest: cflag 1 (compiling Dis to amd64)"
		else
			_gname=interp
			_gword=interptest
			_gexpect="jittest: cflag 0 (interpreter only)"
		fi
		ran="$ran $_gname"
		out=$(capture 30 "$BUILD/$_gname.out" "$NINEVM" -m 256 \
			-c "amd64 boot test $_gword" "$BUILD/kernel.elf")
		check "$_gname" "$out"
		require "$_gname" "$out" "$_gexpect"
		if [ "$_gen" = 1 ]; then
			require "$_gname" "$out" "jit: Jittest compiled"
		fi
		require "$_gname" "$out" "jittest: sum=499500"
		require "$_gname" "$out" "jittest: real=3"
		require "$_gname" "$out" "jittest: fact=720"
		require "$_gname" "$out" "jittest: caught fail:deliberate"
		require "$_gname" "$out" "jittest: spawn=7"
		require "$_gname" "$out" "jittest passed"
	done

	# The PCI bus as the loader presents it. 9vm always has the
	# virtio-9p host device at 0:1.0; finding it is what the
	# networking driver's scan depends on.
	ran="$ran pci"
	out=$(capture 30 "$BUILD/pci.out" "$NINEVM" -m 256 \
		-c "amd64 boot test pcitest" "$BUILD/kernel.elf")
	check pci "$out"
	require pci "$out" "pci 0:1.0 1af4:1049"
	require pci "$out" "pcitest passed"
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

	# The Dis VM needs nothing the ring provides -- the root image and
	# the console are enough -- so the QEMU loader runs it too.
	ran="$ran qemu-vm"
	out=$(capture 30 "$BUILD/qemu-vm.out" \
		"$QEMU" -m 256 -kernel "$BUILD/kernel.bin" \
		-append "amd64 boot test vmtest" \
		-display none -serial stdio -monitor none -no-reboot)
	check qemu-vm "$out"
	require qemu-vm "$out" "vmtest: the Dis VM is running in the kernel"
	require qemu-vm "$out" "vmtest: fp worker ok"
	require qemu-vm "$out" "vmtest passed"

	ran="$ran qemu-shell"
	out=$(shellboot qemu-shell "$BUILD/shellq.out" \
		"cd /dis; ls; echo hello from the shell" "hello from the shell" \
		"$QEMU" -m 256 -kernel "$BUILD/kernel.bin" \
		-append "amd64 boot test shelltest" \
		-display none -serial stdio -monitor none -no-reboot)
	check qemu-shell "$out"
	require qemu-shell "$out" "jit: Sh compiled"
	require qemu-shell "$out" "init: starting the shell"
	require qemu-shell "$out" "init: no #~ namespace to mount"
	require qemu-shell "$out" "sh.dis"
	require qemu-shell "$out" "hello from the shell"

	# Loopback needs no hardware, so the network test runs here too;
	# with a virtio card on QEMU's user network, the guest also reaches
	# the host: 10.0.2.2 is the gateway and the host's loopback, and
	# nettest connects to the echo server below through it.
	ran="$ran qemu-net"
	cat > "$BUILD/nicecho.py" <<'PY'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", 45999))
except OSError as e:
    print("nicecho: bind: %s" % e, file=sys.stderr)
    raise SystemExit(1)
s.listen(1)
c, _ = s.accept()
d = c.recv(128)
c.sendall(d)
c.close()
s.close()
PY
	"$PYTHON" -u "$BUILD/nicecho.py" &
	nicechopid=$!
	sleep 1
	out=$(capture 40 "$BUILD/qemu-net.out" \
		"$QEMU" -m 256 -kernel "$BUILD/kernel.bin" \
		-netdev user,id=n0 -device virtio-net-pci,netdev=n0,disable-legacy=on \
		-append "amd64 boot test nettest" \
		-display none -serial stdio -monitor none -no-reboot)
	kill "$nicechopid" 2>/dev/null || true
	wait "$nicechopid" 2>/dev/null || true
	check qemu-net "$out"
	require qemu-net "$out" "jit: Nettest compiled"
	require qemu-net "$out" "ether: virtio-net"
	require qemu-net "$out" "ether: virtio-net interrupt-driven (irq 11)"
	require qemu-net "$out" "nettest: 127.0.0.1/8 on ipifc"
	require qemu-net "$out" "nettest: ether0 up at 10.0.2.15/24"
	require qemu-net "$out" "nettest: icmp echo reply from 10.0.2.2"
	require qemu-net "$out" "nettest: tcp echo over loopback"
	require qemu-net "$out" "nettest: tcp echo over ether0"
	require qemu-net "$out" "nettest: no #~ namespace on this loader"
	require qemu-net "$out" "nettest passed"

	# The same module, compiled by the generator, on the emulated CPU.
	ran="$ran qemu-jit"
	out=$(capture 30 "$BUILD/qemu-jit.out" \
		"$QEMU" -m 256 -kernel "$BUILD/kernel.bin" \
		-append "amd64 boot test jittest" \
		-display none -serial stdio -monitor none -no-reboot)
	check qemu-jit "$out"
	require qemu-jit "$out" "jit: Jittest compiled"
	require qemu-jit "$out" "jittest: real=3"
	require qemu-jit "$out" "jittest: caught fail:deliberate"
	require qemu-jit "$out" "jittest: spawn=7"
	require qemu-jit "$out" "jittest passed"
fi

[ "$fails" = 0 ] || exit 1
echo "PASS: x86-64 boot (${ran# })"
