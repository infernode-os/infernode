#!/usr/bin/env python3
"""Read a Dis file's type digests, or make from it a file whose digests
are missing, cut short, miscounted or changed.

usage: mksigs.py kind in.dis [out.dis] [name]

A module file limbo wrote ends with its source path and then, when
HASSIGS (1<<7) is set in the header's runtime flags, a count and that
many 32-byte digests: one for each entry of the link section, then one
for each entry of each import table (libinterp/load.c's parsemod is the
format's definition).  This reads the whole file to find them, with a
parser of its own.

kinds:
  show     print the flag, and each link and import with its digest
  section  out.dis is the digest section alone, as it is in the file
  strip    no digests and no flag: a module from before there were any
  noflag   the flag cleared, the section left where it was
  nosec    the flag set and the section gone
  trunc    the last byte of the section gone
  over     the count one more than the links and imports, with a
           digest of zeros added for it
  under    the count one less, the bytes as they were
  huge     the count 2^20, the bytes as they were
  flip     one bit changed in the digest of the link called name
"""
import sys

XMAGIC = 819248
HASEXCEPT, HASLDT, HASSIGS = 1 << 5, 1 << 6, 1 << 7
SIGDLEN = 32
DEFB, DEFW, DEFS, DEFF, DEFA, DIND, DAPOP, DEFL = 1, 2, 3, 4, 5, 6, 7, 8


def operand(b, p):
    c = b[p]
    k = c & 0xC0
    if k == 0x00:
        return c, p + 1
    if k == 0x40:
        return c - 0x80, p + 1
    if k == 0x80:
        v = ((c & 0x3F) << 8) | b[p + 1]
        if c & 0x20:
            v -= 1 << 14
        return v, p + 2
    v = ((c & 0x3F) << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]
    if c & 0x20:
        v -= 1 << 30
    return v, p + 4


def enc(v):
    if -64 <= v <= 63:
        return bytes([v & 0x7F])
    if -8192 <= v <= 8191:
        return bytes([0x80 | ((v >> 8) & 0x3F), v & 0xFF])
    return bytes([0xC0 | ((v >> 24) & 0x3F), (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF])


def noperands(mode):
    if mode in (0, 1, 2):   # AMP, AFP, AIMM
        return 1
    if mode in (4, 5):      # AIND|AMP, AIND|AFP
        return 2
    return 0


def cstr(b, p):
    e = b.index(0, p)
    return b[p:e].decode("utf-8", "replace"), e + 1


class Mod:
    pass


def read(b):
    m = Mod()
    p = 0
    magic, p = operand(b, p)
    if magic != XMAGIC:
        sys.exit("mksigs: not an unsigned Dis file")
    m.rtat = p
    m.rt, p = operand(b, p)
    m.rtend = p
    _, p = operand(b, p)                # stack
    isize, p = operand(b, p)
    _, p = operand(b, p)                # data
    hsize, p = operand(b, p)
    lsize, p = operand(b, p)
    _, p = operand(b, p)                # entry
    _, p = operand(b, p)
    for _ in range(isize):
        add = b[p + 1]
        p += 2
        n = (1 if add & 0xC0 else 0) + noperands((add >> 3) & 7) + noperands(add & 7)
        for _ in range(n):
            _, p = operand(b, p)
    for _ in range(hsize):
        _, p = operand(b, p)
        _, p = operand(b, p)
        np, p = operand(b, p)
        p += np
    while True:
        sm = b[p]
        p += 1
        if sm == 0:
            break
        n = sm & 15
        if n == 0:
            n, p = operand(b, p)
        _, p = operand(b, p)
        kind = sm >> 4
        if kind in (DEFB, DEFS):
            p += n
        elif kind == DEFW:
            p += 4 * n
        elif kind in (DEFF, DEFL):
            p += 8 * n
        elif kind == DEFA:
            p += 8
        elif kind == DIND:
            p += 4
        elif kind != DAPOP:
            sys.exit("mksigs: data item of kind %d" % kind)
    m.name, p = cstr(b, p)
    m.links = []
    for _ in range(lsize):
        _, p = operand(b, p)
        _, p = operand(b, p)
        sig = int.from_bytes(b[p:p + 4], "big")
        name, p = cstr(b, p + 4)
        m.links.append([name, sig, None])
    m.imports = []
    if m.rt & HASLDT:
        nl, p = operand(b, p)
        for _ in range(nl):
            n, p = operand(b, p)
            t = []
            for _ in range(n):
                sig = int.from_bytes(b[p:p + 4], "big")
                name, p = cstr(b, p + 4)
                t.append([name, sig, None])
            m.imports.append(t)
        p += 1
    if m.rt & HASEXCEPT:
        nh, p = operand(b, p)
        for _ in range(nh):
            for _ in range(4):
                _, p = operand(b, p)
            n, p = operand(b, p)
            for _ in range(n & 0xFFFF):
                _, p = cstr(b, p)
                _, p = operand(b, p)
            _, p = operand(b, p)
        p += 1
    m.src, p = cstr(b, p)
    m.secat = p             # where the digests are, or would be
    m.count = None
    if m.rt & HASSIGS:
        m.count, p = operand(b, p)
        m.digat = p
        ents = m.links + [e for t in m.imports for e in t]
        if m.count != len(ents) or len(b) - p < SIGDLEN * m.count:
            sys.exit("mksigs: the file's own digest section is not whole")
        for e in ents:
            e[2] = b[p:p + SIGDLEN]
            e.append(p)
            p += SIGDLEN
    m.secend = p
    return m


def setrt(b, m, rt):
    return b[:m.rtat] + enc(rt) + b[m.rtend:]


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    kind = sys.argv[1]
    b = open(sys.argv[2], "rb").read()
    m = read(b)
    if kind == "show":
        print("module %s rt %#x digests %s" % (m.name, m.rt, "none" if m.count is None else m.count))
        for name, sig, dig, *_ in m.links:
            print("link %s %08x %s" % (name, sig, dig.hex() if dig else "-"))
        for i, t in enumerate(m.imports):
            for name, sig, dig, *_ in t:
                print("import %d %s %08x %s" % (i, name, sig, dig.hex() if dig else "-"))
        return
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    if m.count is None:
        sys.exit("mksigs: %s has no type digests" % sys.argv[2])
    head, sec = b[:m.secat], b[m.secat:m.secend]
    digs = b[m.digat:m.secend]
    if kind == "section":
        out = sec
    elif kind == "strip":
        out = setrt(head, m, m.rt & ~HASSIGS)
    elif kind == "noflag":
        out = setrt(head, m, m.rt & ~HASSIGS) + sec
    elif kind == "nosec":
        out = head
    elif kind == "trunc":
        out = head + sec[:-1]
    elif kind == "over":
        out = head + enc(m.count + 1) + digs + bytes(SIGDLEN)
    elif kind == "under":
        out = head + enc(m.count - 1) + digs
    elif kind == "huge":
        out = head + enc(1 << 20) + digs
    elif kind == "flip":
        if len(sys.argv) < 5:
            sys.exit(__doc__)
        at = [e[3] for e in m.links if e[0] == sys.argv[4]]
        if len(at) != 1:
            sys.exit("mksigs: no one link called %s" % sys.argv[4])
        out = b[:at[0]] + bytes([b[at[0]] ^ 1]) + b[at[0] + 1:]
    else:
        sys.exit(__doc__)
    open(sys.argv[3], "wb").write(out)


if __name__ == "__main__":
    main()
