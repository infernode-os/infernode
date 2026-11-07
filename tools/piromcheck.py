#!/usr/bin/env python3
# piromcheck.py -- read a Raspberry Pi card image the way the board's
# boot ROM and firmware do, and say whether the board would boot it.
#
# Usage:
#     tools/piromcheck.py [--firmware DIR] BOARD IMAGE
#
#     BOARD      rpi3bplus or rpi4b
#     IMAGE      a whole-card image (MBR and all), as tools/mkpiimage.sh
#                makes and as it would be written to a card
#     --firmware DIR
#                also require the boot firmware on the card to be,
#                byte for byte, the files of that name in DIR
#
# Everything here was learned on a board, where it cost a serial cable,
# a card swap and a power cycle each time; none of it can be seen under
# QEMU, which loads the kernel itself and runs neither the boot ROM nor
# the GPU firmware. So it is checked on the image instead:
#
#   - The ROM reads only FAT short names. A Pi 3's ROM looks for
#     BOOTCODE.BIN in the first partition's root by its 8.3 name and
#     ignores long-name entries; a card whose bootcode.bin had the short
#     name BOOTCO~1.BIN booted to a steady red LED and nothing else. So
#     the files the ROM and the firmware's first stage look up are found
#     here by short name and read through the FAT, and nothing else is
#     consulted.
#   - The mini-UART console's baud is divided from the VPU core clock,
#     once, at boot. Firmware 1.20260915 reported 250MHz and ran the core
#     at about 400, and the console came out 1.6 times fast and
#     unreadable, with the shell on it unreachable. config.txt must pin
#     the clock: core_freq and core_freq_min, equal.
#   - config.txt's other load-bearing lines: arm_64bit=1 (the kernel is
#     AArch64), enable_uart=1 (the console's pins), max_framebuffers=2
#     (a panel and a monitor together), and a kernel= that names a file
#     that is on the card.
#
# Deliberately not tools/mkcard.py's code: a reader written apart from
# the writer is what can disagree with it. And deliberately small, as
# the ROM's own reader is: MBR, one FAT32 partition, the root directory.
#
# Exit status: 0 the board would find what it needs; 1 it would not;
# 2 usage.
import os, struct, sys

SEC = 512

# What the ROM and the firmware's first stage look up by short name, per
# board, and which of them are firmware (compared with --firmware).
BOOT = {
    # bootcode.bin is the ROM's; start.elf and fixup.dat are what
    # bootcode.bin loads; config.txt is start.elf's first read.
    # After a tryboot reset start.elf reads tryboot.txt instead of
    # config.txt: the firmware cards are made with ignores [tryboot].
    "rpi3bplus": (["bootcode.bin", "start.elf", "fixup.dat"], ["config.txt", "tryboot.txt"]),
    # A Pi 4 boots from its EEPROM, which reads start4.elf, fixup4.dat,
    # config.txt and, after a tryboot reset, tryboot.txt instead.
    "rpi4b": (["start4.elf", "fixup4.dat"], ["config.txt", "tryboot.txt"]),
}

# What the firmware (start.elf, start4.elf) reads by long name: not 8.3,
# so it has only an alias for a short name, and need not have more.
LONG = {
    "rpi3bplus": [],
    # the kernel reads no device tree, but start4.elf will not go on without it
    "rpi4b": ["bcm2711-rpi-4-b.dtb"],
}

problems = []


def bad(msg):
    problems.append(msg)


def short83(name):
    base, _, ext = name.upper().partition(".")
    return (base.ljust(8) + ext.ljust(3)).encode("ascii")


def show83(s):
    base, ext = s[:8].decode("ascii", "replace").rstrip(), s[8:].decode("ascii", "replace").rstrip()
    return base + ("." + ext if ext else "")


def settings(text):
    """The name=value lines that apply on every boot: before the first
    [section] filter, or under [all]. (The [tryboot] section is the
    candidate's, and is not this card's normal boot.)"""
    out, live = {}, True
    for line in text.splitlines():
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("["):
            live = line.lower() == "[all]"
            continue
        if live and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def main():
    args = sys.argv[1:]
    fwdir = None
    if len(args) >= 2 and args[0] == "--firmware":
        fwdir, args = args[1], args[2:]
    if len(args) != 2 or args[0] not in BOOT:
        sys.stderr.write("usage: piromcheck.py [--firmware DIR] rpi3bplus|rpi4b IMAGE\n")
        sys.exit(2)
    board, path = args
    img = open(path, "rb").read()

    # The MBR and its first partition: the only one the ROM looks at.
    if len(img) < 2 * SEC or img[510:512] != b"\x55\xaa":
        bad("no MBR boot signature in sector 0")
        return report(board)
    ptype = img[446 + 4]
    lba = struct.unpack_from("<I", img, 446 + 8)[0]
    if ptype not in (0x0B, 0x0C):
        bad("partition 1 is type %#04x, not FAT32 (0x0b or 0x0c)" % ptype)
    if lba == 0 or (lba + 1) * SEC > len(img):
        bad("partition 1 starts at sector %d, outside the image" % lba)
        return report(board)
    part = lba * SEC

    # The FAT32 boot sector.
    bs = img[part:part + SEC]
    bps, spc, resv, nfat = struct.unpack_from("<HBHB", bs, 11)
    fatsz = struct.unpack_from("<I", bs, 36)[0]
    rootclus = struct.unpack_from("<I", bs, 44)[0]
    if bs[510:512] != b"\x55\xaa":
        bad("the partition's boot sector has no 0x55AA signature")
    if bps != SEC:
        bad("%d bytes per sector, not 512" % bps)
    if spc == 0 or spc & (spc - 1):
        bad("%d sectors per cluster is not a power of two" % spc)
    if nfat == 0 or fatsz == 0 or rootclus < 2:
        bad("not a FAT32 boot sector (FATs %d, FAT size %d, root cluster %d)" % (nfat, fatsz, rootclus))
    if problems:
        return report(board)
    fat = img[part + resv * SEC: part + (resv + fatsz) * SEC]
    data = part + (resv + nfat * fatsz) * SEC
    csize = spc * SEC

    def chain(c):
        seen = set()
        while 2 <= c < 0x0FFFFFF8:
            if c in seen or 4 * c + 4 > len(fat):
                bad("a broken cluster chain at cluster %d" % c)
                return
            seen.add(c)
            yield c
            c = struct.unpack_from("<I", fat, 4 * c)[0] & 0x0FFFFFFF

    def read(c, size):
        b = b"".join(img[data + (x - 2) * csize: data + (x - 1) * csize] for x in chain(c))
        if len(b) < size:
            bad("a file's clusters hold %d bytes of its %d" % (len(b), size))
        return b[:size]

    # The root directory, as the ROM sees it: short-name entries only.
    # The long names are collected too, but only for kernel=, which the
    # firmware (start.elf, the EEPROM's) looks up by long name.
    root = b"".join(img[data + (x - 2) * csize: data + (x - 1) * csize] for x in chain(rootclus))
    shorts, longs, lfn = {}, {}, {}
    for o in range(0, len(root), 32):
        e = root[o:o + 32]
        if e[0] == 0:
            break
        if e[0] == 0xE5:
            lfn = {}
            continue
        attr = e[11]
        if attr == 0x0F:
            lfn[e[0] & 0x1F] = e[1:11] + e[14:26] + e[28:32]
            continue
        clus = struct.unpack_from("<H", e, 20)[0] << 16 | struct.unpack_from("<H", e, 26)[0]
        ent = (attr, clus, struct.unpack_from("<I", e, 28)[0])
        if not attr & 0x08:
            shorts[bytes(e[0:11])] = ent
            if lfn:
                u = b"".join(lfn[k] for k in sorted(lfn)).decode("utf-16-le", "replace")
                longs[u.split("\x00")[0]] = ent
        lfn = {}

    firmware, configs = BOOT[board]
    text = {}
    for name in firmware + configs:
        ent = shorts.get(short83(name))
        if ent is None:
            alias = [show83(k) for k in shorts if k[8:] == short83(name)[8:] and b"~" in k]
            bad("%s: no short name %s in the root%s -- the boot ROM finds only that"
                % (name, show83(short83(name)), " (only an alias: %s)" % ", ".join(alias) if alias else ""))
            continue
        attr, clus, size = ent
        if attr & 0x10:
            bad("%s is a directory" % name)
            continue
        if size == 0:
            bad("%s is empty" % name)
            continue
        body = read(clus, size)
        if name in firmware and fwdir is not None:
            want = open(os.path.join(fwdir, name), "rb").read()
            if body != want:
                bad("%s on the card is not %s (%d bytes, want %d)"
                    % (name, os.path.join(fwdir, name), len(body), len(want)))
        if name in configs:
            text[name] = body.decode("utf-8", "replace")

    for name in LONG[board]:
        ent = longs.get(name)
        if ent is None or ent[0] & 0x10 or ent[2] == 0:
            bad("%s is not on the card, or is empty" % name)
        elif fwdir is not None and read(ent[1], ent[2]) != open(os.path.join(fwdir, name), "rb").read():
            bad("%s on the card is not %s" % (name, os.path.join(fwdir, name)))

    for name in configs:
        if name not in text:
            continue
        s = settings(text[name])
        for k, v in (("arm_64bit", "1"), ("enable_uart", "1")):
            if s.get(k) != v:
                bad("%s: %s is %s, not %s" % (name, k, s.get(k, "absent"), v))
        try:
            if int(s.get("max_framebuffers", "1")) < 2:
                raise ValueError
        except ValueError:
            bad("%s: max_framebuffers is %s, not 2: no second display"
                % (name, s.get("max_framebuffers", "absent")))
        fq, fqmin = s.get("core_freq"), s.get("core_freq_min")
        if fq is None or fq != fqmin:
            bad("%s: the core clock is not pinned (core_freq %s, core_freq_min %s): "
                "the mini-UART console's baud would move with it" % (name, fq or "absent", fqmin or "absent"))
        # tryboot.txt names the candidate kernel, which is only on a card
        # while one is being tried; config.txt's must be there.
        k = s.get("kernel")
        if name == "config.txt":
            if k is None:
                bad("config.txt names no kernel")
            elif k not in longs and short83(k) not in shorts:
                bad("config.txt: kernel=%s is not on the card" % k)
            elif (longs.get(k) or shorts[short83(k)])[2] == 0:
                bad("config.txt: kernel=%s is empty" % k)
    return report(board)


def report(board):
    for p in problems:
        print("piromcheck: %s: %s" % (board, p))
    if problems:
        print("piromcheck: %s: the board would not boot this card as it should" % board)
        sys.exit(1)
    print("piromcheck: %s: the boot ROM and firmware find what they need" % board)
    sys.exit(0)


main()
