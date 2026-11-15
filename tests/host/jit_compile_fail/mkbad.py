#!/usr/bin/env python3
"""Make, from a Dis file limbo wrote, one the JIT must refuse.

usage: mkbad.py kind in.dis out.dis

Only the header and the instructions are read (libinterp/load.c's
parsemod is the format's definition); the rest of the file -- types,
data, name, links -- is copied as it is.

kinds:
  op       the last instruction's opcode is 255, which is none
  mode     the first movw's source has address mode 3, which is none
  frame    the first frame instruction's type number is 2^27
  movpc    a movpc of pc 2^27 is added after the last instruction
  branch   a beqw whose destination is not an immediate is added
  casefar  the first case's table is 2^27 bytes into the module data
  gotofar  the first goto's table likewise
  casepc   the table entry for the case label 1000001 has pc 2^27
  must     nothing is wrong: the header says the module must be compiled
"""
import sys

XMAGIC = 819248
MUSTCOMPILE = 1
INOP, IGOTO, IFRAME, ICASE, IMOVW, IBEQW, IMOVPC = 0, 3, 5, 14, 45, 93, 146
AMP, AFP, AIMM, AXXX = 0, 1, 2, 3
FAR = 1 << 27


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
    if mode in (AMP, AFP, AIMM):
        return 1
    if mode in (4, 5):      # AIND|AMP, AIND|AFP
        return 2
    return 0


class Inst:
    def __init__(self, op, add, mid, src, dst):
        self.op, self.add, self.mid, self.src, self.dst = op, add, mid, src, dst

    def smode(self):
        return (self.add >> 3) & 7

    def dmode(self):
        return self.add & 7

    def enc(self):
        b = bytes([self.op, self.add])
        for v in self.mid + self.src + self.dst:
            b += enc(v)
        return b


def read(b):
    p = 0
    magic, p = operand(b, p)
    if magic != XMAGIC:
        sys.exit("mkbad: not an unsigned Dis file")
    hdr = []
    for _ in range(8):      # rt ss isize dsize hsize lsize entry entryt
        v, p = operand(b, p)
        hdr.append(v)
    insts = []
    for _ in range(hdr[2]):
        op, add = b[p], b[p + 1]
        p += 2
        mid, src, dst = [], [], []
        if add & 0xC0:
            v, p = operand(b, p)
            mid.append(v)
        for _ in range(noperands((add >> 3) & 7)):
            v, p = operand(b, p)
            src.append(v)
        for _ in range(noperands(add & 7)):
            v, p = operand(b, p)
            dst.append(v)
        insts.append(Inst(op, add, mid, src, dst))
    return hdr, insts, b[p:]


def write(hdr, insts, rest):
    hdr = list(hdr)
    hdr[2] = len(insts)
    b = enc(XMAGIC)
    for v in hdr:
        b += enc(v)
    for i in insts:
        b += i.enc()
    return b + rest


def first(insts, want):
    for i in insts:
        if want(i):
            return i
    sys.exit("mkbad: the module has no such instruction")


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    kind = sys.argv[1]
    hdr, insts, rest = read(open(sys.argv[2], "rb").read())
    if kind == "op":
        insts[-1].op = 255
    elif kind == "mode":
        i = first(insts, lambda i: i.op == IMOVW and i.smode() in (AMP, AFP))
        i.add = (i.add & ~0x38) | (AXXX << 3)
        i.src = []
    elif kind == "frame":
        i = first(insts, lambda i: i.op == IFRAME and i.smode() == AIMM)
        i.src = [FAR]
    elif kind == "movpc":
        insts.append(Inst(IMOVPC, (AIMM << 3) | AFP, [], [FAR], [64]))
    elif kind == "branch":
        insts.append(Inst(IBEQW, (AFP << 3) | AFP, [], [64], [80]))
    elif kind == "casefar":
        i = first(insts, lambda i: i.op == ICASE and i.dmode() == AMP)
        i.dst = [FAR]
    elif kind == "gotofar":
        i = first(insts, lambda i: i.op == IGOTO and i.dmode() == AMP)
        i.dst = [FAR]
    elif kind == "casepc":
        # a case's entry in the data: the label, the label + 1, the pc, as 32-bit words
        key = (1000001).to_bytes(4, "big") + (1000002).to_bytes(4, "big")
        at = rest.find(key)
        if at < 0 or rest.find(key, at + 1) >= 0:
            sys.exit("mkbad: no one case table with the label 1000001")
        at += len(key)
        rest = rest[:at] + FAR.to_bytes(4, "big") + rest[at + 4:]
    elif kind == "must":
        hdr[0] |= MUSTCOMPILE
    else:
        sys.exit(__doc__)
    open(sys.argv[3], "wb").write(write(hdr, insts, rest))


if __name__ == "__main__":
    main()
