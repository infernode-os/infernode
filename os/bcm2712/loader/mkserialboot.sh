#!/bin/sh
# Build the Pi 5's serial loader: mkserialboot.sh <output.img> [extra cc flags]
set -e
here=$(dirname "$0")
out=$1; shift
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
F="--target=aarch64-elf -ffreestanding -nostdlib -mgeneral-regs-only -O2 -Wall -DBCM2712 -DPHYSIO=0x107C000000UL -DUARTREGS=0x1C00030000UL"
clang $F "$@" -c "$here/../../bcm2837/serialboot.c" -o "$tmp/c.o"
clang $F "$@" -c "$here/../../bcm2837/serialboot.S" -o "$tmp/s.o"
clang $F "$@" -c "$here/probe.c" -o "$tmp/p.o"
clang $F "$@" -c "$here/probevec.S" -o "$tmp/v.o"
ld.lld -T "$here/../../bcm2837/serialboot.ld" "$tmp/s.o" "$tmp/c.o" "$tmp/p.o" "$tmp/v.o" -o "$tmp/sb.elf"
llvm-objcopy -O binary "$tmp/sb.elf" "$out"
