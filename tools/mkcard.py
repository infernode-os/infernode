#!/usr/bin/env python3
# Build a card image for the bare-metal kernel: an MBR, one FAT32
# partition, and whatever trees the command line names.
#
#   tools/mkcard.py card.img 192 /dis=dis /lib=lib /fonts=fonts /icons=icons /usr= /skiplogon=/dev/null
#
# Arguments after the size (in MB) are mkrootfs.py's manifest syntax:
# /dest=src copies a file or, recursively, a directory; /dest= makes an
# empty directory. The result is what a Raspberry Pi's card looks like
# to os/init/osinit.b -- partition at sector 2048, dis/ lib/ fonts/
# icons/ usr/ in its root -- and boots the board, QEMU's raspi3b
# (-drive if=sd) and QEMU's virt (-device virtio-blk-device) alike.
#
# Why not mkfs.vfat and mcopy: mtools is not everywhere this runs, a
# loop mount needs root, and the image should be the same bytes every
# time it is built from the same tree, which neither promises. This
# writes the filesystem directly: fixed timestamps, files laid out
# contiguously in the order the tree is walked (sorted), no free-space
# games. It is a writer only, and only of FAT32.
#
# Long names are always written for anything that is not already an
# upper-case 8.3 name, which in an Inferno tree is everything: dossrv
# reads the long entry, and the generated short alias (NAME~1.EXT) is
# there because the format requires one.
import os, struct, sys

SEC = 512
PSTART = 2048                   # first sector of the partition
RESV = 32                       # reserved sectors: boot, FSInfo, backup
NFAT = 2
FDATE = ((2026 - 1980) << 9) | (1 << 5) | 1     # 2026-01-01
FTIME = 0

class Node:
    def __init__(self, name, isdir, data=b""):
        self.name, self.isdir, self.data = name, isdir, data
        self.kids = {}
        self.clus = 0
        self.nclus = 0

def die(msg):
    sys.stderr.write("mkcard: %s\n" % msg)
    sys.exit(1)

def walkto(root, path):
    n = root
    for part in [p for p in path.split("/") if p]:
        if part not in n.kids:
            n.kids[part] = Node(part, True)
        n = n.kids[part]
        if not n.isdir:
            die("%s: %s is a file" % (path, part))
    return n

def addtree(root, dest, src):
    parts = [p for p in dest.split("/") if p]
    if not parts:
        die("cannot replace the root: %s" % dest)
    parent = walkto(root, "/".join(parts[:-1]))
    name = parts[-1]
    if src == "":
        parent.kids.setdefault(name, Node(name, True))
        return
    if os.path.isdir(src):
        d = parent.kids.setdefault(name, Node(name, True))
        for ent in sorted(os.listdir(src)):
            p = os.path.join(src, ent)
            if os.path.islink(p) and not os.path.exists(p):
                continue
            addtree(root, dest.rstrip("/") + "/" + ent, p)
        return
    try:
        data = open(src, "rb").read()
    except OSError as e:
        die("%s: %s" % (src, e))
    parent.kids[name] = Node(name, False, data)

SHORTOK = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-$~!#%&@^(){}'`")

def is83(name):
    if name in (".", ".."):
        return True
    base, dot, ext = name.partition(".")
    if "." in ext or not base or len(base) > 8 or len(ext) > 3:
        return False
    return all(c in SHORTOK for c in base + ext)

def pack83(base, ext):
    return (base.ljust(8) + ext.ljust(3)).encode("ascii")

def shortname(name, taken):
    """The 11-byte short name, unique in its directory, and whether long entries are needed."""
    if is83(name):
        base, _, ext = name.partition(".")
        s = pack83(base, ext)
        if s not in taken:
            taken.add(s)
            return s, False
    stem, dot, ext = name.rpartition(".")
    if not dot or not stem:
        stem, ext = name, ""
    clean = lambda t: "".join(c for c in t.upper() if c in SHORTOK and c != "~")
    b, e = clean(stem) or "X", clean(ext)[:3]
    n = 1
    while True:
        tail = "~%d" % n
        s = pack83(b[:8 - len(tail)] + tail, e)
        if s not in taken:
            taken.add(s)
            return s, True
        n += 1

def lfnsum(short):
    s = 0
    for c in short:
        s = (((s & 1) << 7) + (s >> 1) + c) & 0xFF
    return s

def direntries(node, parentclus, isroot):
    """The directory's contents as bytes. Children must have their clusters assigned."""
    out = bytearray()
    def entry(short, attr, clus, size):
        e = bytearray(32)
        e[0:11] = short
        e[11] = attr
        struct.pack_into("<HHH", e, 14, FTIME, FDATE, FDATE)
        struct.pack_into("<H", e, 20, clus >> 16)
        struct.pack_into("<HH", e, 22, FTIME, FDATE)
        struct.pack_into("<H", e, 26, clus & 0xFFFF)
        struct.pack_into("<I", e, 28, size)
        return e
    if not isroot:
        out += entry(b".          ", 0x10, node.clus, 0)
        out += entry(b"..         ", 0x10, parentclus, 0)     # 0 means the root
    taken = set()
    for name in sorted(node.kids):
        k = node.kids[name]
        short, needlfn = shortname(name, taken)
        if needlfn:
            u = name.encode("utf-16-le")
            units = [u[i:i+2] for i in range(0, len(u), 2)]
            if len(units) > 255:
                die("name too long: %s" % name)
            if len(units) % 13:
                units.append(b"\x00\x00")
                while len(units) % 13:
                    units.append(b"\xFF\xFF")
            nent = len(units) // 13
            ck = lfnsum(short)
            for i in range(nent, 0, -1):
                chunk = b"".join(units[(i-1)*13 : i*13])
                e = bytearray(32)
                e[0] = i | (0x40 if i == nent else 0)
                e[1:11] = chunk[0:10]
                e[11] = 0x0F
                e[13] = ck
                e[14:26] = chunk[10:22]
                e[28:32] = chunk[22:26]
                out += e
        out += entry(short, 0x10 if k.isdir else 0x20, k.clus, 0 if k.isdir else len(k.data))
    return out

def lfncount(name):
    """How many long-name entries a name takes: 13 UTF-16 units each, NUL-terminated unless it fits exactly."""
    n = len(name.encode("utf-16-le")) // 2
    if n % 13:
        n += 1
    return (n + 12) // 13

def nentries(node, isroot):
    n = 0 if isroot else 2
    taken = set()
    for name in sorted(node.kids):
        _, needlfn = shortname(name, taken)
        n += 1 + (lfncount(name) if needlfn else 0)
    return n

def main():
    if len(sys.argv) < 3:
        die("usage: mkcard.py out.img size-in-MB [/dest=src | /dir=] ...")
    out, mb = sys.argv[1], int(sys.argv[2])
    total = mb * 1024 * 1024 // SEC
    psecs = total - PSTART

    # cluster size: the largest of 8,4,2,1 sectors that still leaves the
    # 65525 clusters that MAKE a volume FAT32 -- the type is decided by
    # the count, not by anything written in the boot sector
    for spc in (8, 4, 2, 1):
        fatsz = 1
        while True:
            nclus = (psecs - RESV - NFAT*fatsz) // spc
            need = ((nclus + 2) * 4 + SEC - 1) // SEC
            if need <= fatsz:
                break
            fatsz = need
        if nclus >= 65525 + 16:
            break
    else:
        die("%dMB is too small to be FAT32; 40 is about the least" % mb)
    csize = spc * SEC
    datastart = RESV + NFAT * fatsz             # sectors into the partition

    root = Node("", True)
    for spec in sys.argv[3:]:
        dest, eq, src = spec.partition("=")
        if not eq or not dest.startswith("/"):
            die("bad spec %r: want /dest=src or /dir=" % spec)
        addtree(root, dest, src)

    # assign clusters, depth first, every file and directory contiguous
    nextclus = [2]
    def assign(node, isroot):
        if node.isdir:
            node.nclus = max(1, (nentries(node, isroot) * 32 + csize - 1) // csize)
        else:
            node.nclus = (len(node.data) + csize - 1) // csize
        if node.nclus:
            node.clus = nextclus[0]
            nextclus[0] += node.nclus
        for name in sorted(node.kids):
            assign(node.kids[name], False)
    assign(root, True)
    used = nextclus[0] - 2
    if used > nclus:
        die("the trees need %dMB of clusters and the volume has %dMB" %
            (used * csize >> 20, nclus * csize >> 20))

    img = bytearray(total * SEC)
    pbase = PSTART * SEC
    fat = bytearray(fatsz * SEC)
    struct.pack_into("<III", fat, 0, 0x0FFFFFF8, 0x0FFFFFFF, 0)

    nfiles = [0, 0]
    def emit(node, parentclus, isroot):
        if node.isdir:
            data = direntries(node, parentclus, isroot)
            assert len(data) <= node.nclus * csize, node.name
            nfiles[1] += 1
        else:
            data = node.data
            nfiles[0] += 1
        if node.nclus:
            off = pbase + (datastart + (node.clus - 2) * spc) * SEC
            img[off:off+len(data)] = data
            for c in range(node.clus, node.clus + node.nclus):
                struct.pack_into("<I", fat, 4*c,
                    0x0FFFFFFF if c == node.clus + node.nclus - 1 else c + 1)
        for name in sorted(node.kids):
            emit(node.kids[name], 0 if isroot else node.clus, False)
    emit(root, 0, True)

    for i in range(NFAT):
        off = pbase + (RESV + i*fatsz) * SEC
        img[off:off+len(fat)] = fat

    bs = bytearray(SEC)
    bs[0:3] = b"\xEB\x58\x90"
    bs[3:11] = b"INFRNODE"
    struct.pack_into("<HBHBHHBHHHII", bs, 11,
        SEC, spc, RESV, NFAT, 0, 0, 0xF8, 0, 32, 64, PSTART, psecs)
    struct.pack_into("<IHHIHH", bs, 36, fatsz, 0, 0, 2, 1, 6)
    bs[64] = 0x80
    bs[66] = 0x29
    struct.pack_into("<I", bs, 67, 0x1F0D0E01)
    bs[71:82] = b"NO NAME    "             # no label entry in the root, so none claimed here
    bs[82:90] = b"FAT32   "
    bs[510:512] = b"\x55\xAA"
    fsinfo = bytearray(SEC)
    struct.pack_into("<I", fsinfo, 0, 0x41615252)
    struct.pack_into("<III", fsinfo, 484, 0x61417272, nclus - used, nextclus[0])
    fsinfo[510:512] = b"\x55\xAA"
    for base in (0, 6):                         # and the backup copies
        img[pbase + base*SEC : pbase + (base+1)*SEC] = bs
        img[pbase + (base+1)*SEC : pbase + (base+2)*SEC] = fsinfo

    e = bytearray(16)
    e[0] = 0x80
    e[4] = 0x0C                                 # FAT32, LBA
    struct.pack_into("<II", e, 8, PSTART, psecs)
    img[446:462] = e
    img[510:512] = b"\x55\xAA"

    open(out, "wb").write(img)
    print("mkcard: %s: %dMB, FAT32, %d-byte clusters, %d files in %d directories, %dMB used" %
        (out, mb, csize, nfiles[0], nfiles[1], used * csize >> 20))

main()
