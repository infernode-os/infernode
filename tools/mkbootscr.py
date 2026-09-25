#!/usr/bin/env python3
# Wrap a U-Boot script as a boot.scr, as `mkimage -A riscv -O linux
# -T script -C none -d boot.cmd boot.scr' does, for hosts without
# u-boot-tools:
#
#   tools/mkbootscr.py os/riscv64/boot.cmd boot.scr
#
# The format is a legacy uImage: a 64-byte big-endian header (magic,
# header CRC, time, data size, load and entry addresses, data CRC, OS,
# architecture, type, compression, a 32-byte name), then the data. A
# script's data is a table of part lengths ending in zero -- one part
# here -- and the script text. The time is fixed so that the same
# script always makes the same bytes.
import struct, sys, zlib

MAGIC = 0x27051956
OS_LINUX = 5
ARCH_RISCV = 26
TYPE_SCRIPT = 6
COMP_NONE = 0

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: mkbootscr.py boot.cmd boot.scr")
    text = open(sys.argv[1], "rb").read()
    data = struct.pack(">II", len(text), 0) + text
    name = b"InferNode boot script"
    def header(hcrc):
        return struct.pack(">IIIIIIIBBBB32s", MAGIC, hcrc, 0, len(data), 0, 0,
                           zlib.crc32(data) & 0xFFFFFFFF,
                           OS_LINUX, ARCH_RISCV, TYPE_SCRIPT, COMP_NONE, name)
    h = header(0)
    h = header(zlib.crc32(h) & 0xFFFFFFFF)
    with open(sys.argv[2], "wb") as f:
        f.write(h + data)

main()
