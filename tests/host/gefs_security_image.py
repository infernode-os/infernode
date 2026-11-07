#!/usr/bin/env python3
"""Make checksum-valid hostile GEFS images for gefs_security_test.sh."""

import shutil
import struct
import sys

BLKSZ = 16384
MASK = (1 << 64) - 1


def rotr(v, n):
    return ((v >> n) | (v << (64 - n))) & MASK


def metro64(data, seed=0x6765):
    k0, k1, k2, k3 = 0xC83A91E1, 0x8648DBDB, 0x7BDEC03B, 0x2F5870A5
    p = 0
    h = (((seed + k2) * k0) + len(data)) & MASK
    if len(data) >= 32:
        v0 = v1 = v2 = v3 = h
        while p <= len(data) - 32:
            w = struct.unpack_from("<4Q", data, p)
            v0 = (v0 + w[0] * k0) & MASK
            v0 = (rotr(v0, 29) + v2) & MASK
            v1 = (v1 + w[1] * k1) & MASK
            v1 = (rotr(v1, 29) + v3) & MASK
            v2 = (v2 + w[2] * k2) & MASK
            v2 = (rotr(v2, 29) + v0) & MASK
            v3 = (v3 + w[3] * k3) & MASK
            v3 = (rotr(v3, 29) + v1) & MASK
            p += 32
        v2 ^= (rotr(((v0 + v3) * k0 + v1) & MASK, 33) * k1) & MASK
        v3 ^= (rotr(((v1 + v2) * k1 + v0) & MASK, 33) * k0) & MASK
        v0 ^= (rotr(((v0 + v2) * k0 + v3) & MASK, 33) * k1) & MASK
        v1 ^= (rotr(((v1 + v3) * k1 + v2) & MASK, 33) * k0) & MASK
        h = (h + (v0 ^ v1)) & MASK
    if len(data) - p >= 16:
        a, b = struct.unpack_from("<2Q", data, p)
        p += 16
        v0 = rotr((h + a * k0) & MASK, 33) * k1 & MASK
        v1 = rotr((h + b * k1) & MASK, 33) * k2 & MASK
        v0 ^= (rotr(v0 * k0 & MASK, 35) + v1) & MASK
        v1 ^= (rotr(v1 * k3 & MASK, 35) + v0) & MASK
        h = (h + v1) & MASK
    if len(data) - p >= 8:
        h = (h + struct.unpack_from("<Q", data, p)[0] * k3) & MASK
        p += 8
        h ^= rotr(h, 33) * k1 & MASK
    if len(data) - p >= 4:
        h = (h + (struct.unpack_from("<I", data, p)[0] * k3 & 0xFFFFFFFF)) & MASK
        p += 4
        h ^= rotr(h, 15) * k1 & MASK
    if len(data) - p >= 2:
        v = struct.unpack_from("<H", data, p)[0] * k3 & 0xFFFFFFFF
        h = (h + (v if v < (1 << 31) else v - (1 << 32))) & MASK
        p += 2
        h ^= rotr(h, 13) * k1 & MASK
    if len(data) - p:
        v = data[p] * k3 & 0xFFFFFFFF
        h = (h + (v if v < (1 << 31) else v - (1 << 32))) & MASK
        h ^= rotr(h, 25) * k1 & MASK
    h ^= rotr(h, 33)
    h = h * k0 & MASK
    h ^= rotr(h, 33)
    return h & MASK


def block(f, off):
    f.seek(off)
    b = bytearray(f.read(BLKSZ))
    if len(b) != BLKSZ:
        raise ValueError("short GEFS block")
    return b


def putblock(f, off, b):
    f.seek(off)
    f.write(b)


def leaf_records(b):
    if struct.unpack_from(">H", b, 0)[0] != 2:
        raise ValueError("expected GEFS leaf")
    nval = struct.unpack_from(">H", b, 2)[0]
    for i in range(nval):
        off = struct.unpack_from(">H", b, 6 + 2 * i)[0]
        p = 6 + off
        nk = struct.unpack_from(">H", b, p)[0]
        ks = p + 2
        p = ks + nk
        nv = struct.unpack_from(">H", b, p)[0]
        yield bytes(b[ks:ks + nk]), p + 2, nv


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: gefs_security_image.py source destination mutation")
    src, dst, mutation = sys.argv[1:]
    shutil.copyfile(src, dst)
    with open(dst, "r+b") as f:
        sb = block(f, 0)
        if sb[:8] != b"gefs9.00":
            raise ValueError("not a GEFS image")
        narena = struct.unpack_from(">I", sb, 16)[0]
        if mutation == "tree-count":
            root = struct.unpack_from(">Q", sb, 24)[0]
            b = block(f, root)
            struct.pack_into(">H", b, 2, 0xFFFF)
            putblock(f, root, b)
            struct.pack_into(">Q", sb, 32, metro64(b))
            end = 104 + 16 * narena
            struct.pack_into(">Q", sb, end, metro64(sb[:end]))
            putblock(f, 0, sb)
            return
        if mutation == "negative-length":
            snapaddr = struct.unpack_from(">Q", sb, 24)[0]
            snap = block(f, snapaddr)
            sv = None
            for key, value, nv in leaf_records(snap):
                if len(key) == 9 and key[0] == 4 and struct.unpack_from(">Q", key, 1)[0] == 1:
                    sv = value
                    break
            if sv is None or nv != 72:
                raise ValueError("adm tree not found")
            admaddr = struct.unpack_from(">Q", snap, sv + 48)[0]
            adm = block(f, admaddr)
            changed = False
            for key, value, nv in leaf_records(adm):
                if key[0] == 1 and key[11:-1] == b"users":
                    if nv != 61:
                        raise ValueError("bad users directory value")
                    struct.pack_into(">Q", adm, value + 41, MASK)
                    changed = True
                    break
            if not changed:
                raise ValueError("users directory entry not found")
            putblock(f, admaddr, adm)
            struct.pack_into(">Q", snap, sv + 56, metro64(adm))
            putblock(f, snapaddr, snap)
            struct.pack_into(">Q", sb, 32, metro64(snap))
            end = 104 + 16 * narena
            struct.pack_into(">Q", sb, end, metro64(sb[:end]))
            putblock(f, 0, sb)
            return
        arena = struct.unpack_from(">Q", sb, 104)[0]
        ah = block(f, arena)
        log = struct.unpack_from(">Q", ah, 2)[0]
        b = block(f, log)
        if mutation == "log-length":
            struct.pack_into(">H", b, 2, 0xFFFF)
        elif mutation == "log-cycle":
            struct.pack_into(">H", b, 2, 0)
            struct.pack_into(">Q", b, 4, metro64(b""))
            struct.pack_into(">Q", b, 12, log)
            struct.pack_into(">QQ", b, 20, MASK, MASK)
        elif mutation == "deadlist-cycle":
            dead = log + BLKSZ
            d = bytearray(BLKSZ)
            struct.pack_into(">HHQ", d, 0, 4, 0, metro64(b""))
            struct.pack_into(">QQQ", d, 12, dead, MASK, MASK)
            putblock(f, dead, d)
            struct.pack_into(">QQ", sb, 40, dead, MASK)
            struct.pack_into(">QQ", sb, 56, MASK, MASK)
            end = 104 + 16 * narena
            struct.pack_into(">Q", sb, end, metro64(sb[:end]))
            putblock(f, 0, sb)
            return
        else:
            raise ValueError("unknown mutation: " + mutation)
        putblock(f, log, b)


if __name__ == "__main__":
    main()
