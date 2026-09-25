#!/bin/bash
#
# Build script for Linux riscv64 (RV64GC, LP64D)
#
# Runs natively on a riscv64 Linux host (BeagleV-Fire, VisionFive 2, any
# RVA20/RVA22/RVA23 board), or cross-compiles from an amd64/arm64 host.
#
# Usage:
#   ./build-linux-riscv64.sh             # headless emu (the only mode today)
#
# Cross-compiling (host is not riscv64):
#   apt-get install gcc-riscv64-linux-gnu libc6-dev-riscv64-cross qemu-user
#   ./build-linux-amd64.sh headless      # once: host mk and limbo, and dis/
#   ./build-linux-riscv64.sh
#   qemu-riscv64 -L /usr/riscv64-linux-gnu emu/Linux/o.emu -r$PWD sh -l
#
# The Dis bytecode in dis/ is portable, so a cross build reuses the one
# the host build made; a native build compiles it itself.
#
# Libraries build their objects in the source directories, so a riscv64
# build and a host build in the same tree clobber each other's .o files
# (not each other's libraries, which live under $ROOT/Linux/$OBJTYPE/lib).
# Every library is cleaned before it is built here for that reason; after
# this script, rebuilding the host means cleaning the same way.
#
# There is no JIT yet: libinterp/comp-riscv64.c declines every module and
# the VM interprets, so -c1 behaves as -c0.
#

set -e

export ROOT="$(cd "$(dirname "$0")" && pwd)"
export SYSHOST=Linux
export SYSTARG=Linux
export OBJTYPE=riscv64
export SHELL=/bin/sh
export SHELLNAME=sh
export AWK=awk

mkdir -p "$ROOT/Linux/riscv64/bin" "$ROOT/Linux/riscv64/lib"

echo "=== InferNode Linux riscv64 Build ==="

case "$(uname -m)" in
riscv64)
	NATIVE=1
	export CROSS=
	TOOLS="$ROOT/Linux/riscv64/bin"
	;;
x86_64)
	NATIVE=0
	HOSTOBJ=amd64
	;;
aarch64|arm64)
	NATIVE=0
	HOSTOBJ=arm64
	;;
*)
	echo "ERROR: unsupported build host $(uname -m)" >&2
	exit 1
	;;
esac

if [[ $NATIVE == 0 ]]; then
	export CROSS=${CROSS:-riscv64-linux-gnu-}
	TOOLS="$ROOT/Linux/$HOSTOBJ/bin"
	if ! command -v "${CROSS}gcc" >/dev/null; then
		echo "ERROR: ${CROSS}gcc not found." >&2
		echo "  sudo apt-get install gcc-riscv64-linux-gnu libc6-dev-riscv64-cross" >&2
		exit 1
	fi
	if [[ ! -x "$TOOLS/mk" || ! -x "$TOOLS/limbo" ]]; then
		echo "ERROR: cross build needs the host's mk and limbo in $TOOLS." >&2
		echo "  Run ./build-linux-$HOSTOBJ.sh headless first." >&2
		exit 1
	fi
	# Find the target's libraries (libfido2), never the build host's.
	export PKG_CONFIG_LIBDIR=/usr/lib/riscv64-linux-gnu/pkgconfig:/usr/share/pkgconfig
	echo "Cross-compiling with ${CROSS}gcc; host tools from $TOOLS"
else
	if ! command -v gcc >/dev/null; then
		echo "ERROR: gcc not found: sudo apt-get install build-essential" >&2
		exit 1
	fi
	if [[ ! -x "$TOOLS/mk" ]]; then
		echo "=== Bootstrapping mk ==="
		(cd "$ROOT" && SYSTARG=Linux OBJTYPE=riscv64 ./makemk.sh)
	fi
fi

export PATH="$TOOLS:$PATH"
MK="$TOOLS/mk"

build_lib() {
	echo "Building $1..."
	cd "$ROOT/$1"
	"$MK" clean >/dev/null 2>&1 || true
	"$MK" install || { echo "ERROR: $1 build failed" >&2; exit 1; }
}

echo ""
echo "=== Building Libraries ==="
for lib in lib9 libbio libmp libsec libmath libmemdraw libmemlayer libdraw libtk; do
	build_lib $lib
done

if [[ $NATIVE == 1 ]]; then
	echo ""
	echo "=== Building Limbo Compiler ==="
	build_lib limbo
	strip "$ROOT/Linux/riscv64/bin/limbo"
fi

echo ""
echo "=== Building Libraries that need Limbo ==="
for lib in libinterp libkeyring; do
	build_lib $lib
done

echo ""
echo "=== Building Emulator (headless) ==="
cd "$ROOT/emu/Linux"
rm -f *.o *.emu emu.root.h emu.root.c emu.root.s 2>/dev/null
"$MK" -f mkfile-g || { echo "ERROR: emulator build failed" >&2; exit 1; }

if [[ $NATIVE == 1 ]]; then
	echo ""
	echo "=== Building Applications (Limbo -> Dis bytecode) ==="
	for d in appl appl/mpeg appl/veltro tests; do
		(cd "$ROOT/$d" && "$MK" install) || echo "WARNING: some modules in $d failed to build"
	done
elif [[ ! -f "$ROOT/dis/emuinit.dis" ]]; then
	echo ""
	echo "WARNING: dis/ is empty; build it with the host (./build-linux-$HOSTOBJ.sh headless)."
fi

echo ""
echo "=== Build Summary ==="
if [[ -x "$ROOT/emu/Linux/o.emu" ]]; then
	echo "SUCCESS: Emulator built at $ROOT/emu/Linux/o.emu"
	file "$ROOT/emu/Linux/o.emu" 2>/dev/null || true
	echo ""
	if [[ $NATIVE == 1 ]]; then
		echo "Run (headless, drops to Inferno shell):"
		echo "  $ROOT/emu/Linux/o.emu -r$ROOT sh -l"
	else
		echo "Run under user-mode emulation (headless, drops to Inferno shell):"
		echo "  qemu-riscv64 -L /usr/riscv64-linux-gnu $ROOT/emu/Linux/o.emu -r$ROOT sh -l"
	fi
else
	echo "ERROR: emulator binary not found" >&2
	exit 1
fi
