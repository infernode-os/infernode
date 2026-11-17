#!/usr/bin/env python3
#
# keyfs(4)'s key file, written from its manual page and not from keyfs.b,
# for tests/host/keyfs_file_test.sh: the test's control. With Python's
# cryptography.
#
# The old format (Plan 9's aescbc): IV[16], then AES-128-CBC of the entries
# and sixteen X's under SHA1("aescbc file" + password)[:16], the last
# len%16 bytes XORed with E(the last ciphertext block).
#
# The new format: "keyfs 2\n", iterations[4] big-endian, salt[16],
# nonce[12], AES-256-GCM(count[4] big-endian + entries) with those 40 bytes
# as associated data, tag[16]; the key the first 32 bytes of
# PBKDF2-HMAC-SHA-384(password, salt, iterations).
#
# An entry: status[1] failed[1] expire[4 little-endian] namelen[1] name
# secretlen[1] secret.
#
import sys, os, hashlib
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"keyfs 2\n"

def oldkey(pwd):
    return hashlib.sha1(b"aescbc file" + pwd).digest()[:16]

def ecb(k):
    return Cipher(algorithms.AES(k), modes.ECB())

def olddec(k, f):
    iv, c = f[:16], f[16:]
    n = len(c) // 16 * 16
    d = ecb(k).decryptor()
    e = ecb(k).encryptor()
    out = bytearray()
    prev = iv
    for i in range(0, n, 16):
        b = c[i:i+16]
        p = d.update(b)
        out += bytes(x ^ y for x, y in zip(p, prev))
        prev = b
    if len(c) > n:
        ks = e.update(prev)
        out += bytes(x ^ y for x, y in zip(c[n:], ks))
    return bytes(out)

def oldenc(k, iv, p):
    n = len(p) // 16 * 16
    e = ecb(k).encryptor()
    out = bytearray()
    prev = iv
    for i in range(0, n, 16):
        b = e.update(bytes(x ^ y for x, y in zip(p[i:i+16], prev)))
        out += b
        prev = b
    if len(p) > n:
        ks = e.update(prev)
        out += bytes(x ^ y for x, y in zip(p[n:], ks))
    return iv + bytes(out)

def recs(p):
    i = 0
    r = []
    while i < len(p):
        st, failed = p[i], p[i+1]
        exp = int.from_bytes(p[i+2:i+6], "little")
        n = p[i+6]
        name = p[i+7:i+7+n]
        j = i + 7 + n
        m = p[j]
        sec = p[j+1:j+1+m]
        r.append((st, failed, exp, name.decode(), sec.hex()))
        i = j + 1 + m
    return r

def pack(st, failed, exp, name, sec):
    return (bytes([st, failed]) + exp.to_bytes(4, "little") +
        bytes([len(name)]) + name + bytes([len(sec)]) + sec)

def packargs(a):
    p = b""
    n = 0
    while a:
        p += pack(int(a[0]), int(a[1]), int(a[2]), a[3].encode(), bytes.fromhex(a[4]))
        a = a[5:]
        n += 1
    return n, p

def newkey(pwd, salt, it):
    return hashlib.pbkdf2_hmac("sha384", pwd, salt, it)[:32]

def newenc(pwd, it, content):
    salt = os.urandom(16)
    nonce = os.urandom(12)
    hdr = MAGIC + it.to_bytes(4, "big") + salt + nonce
    return hdr + AESGCM(newkey(pwd, salt, it)).encrypt(nonce, content, hdr)

def newdec(pwd, f):
    if f[:8] != MAGIC:
        raise ValueError("no magic")
    it = int.from_bytes(f[8:12], "big")
    salt, nonce = f[12:28], f[28:40]
    return it, AESGCM(newkey(pwd, salt, it)).decrypt(nonce, f[40:], f[:40])

def main():
    cmd = sys.argv[1]
    file = sys.argv[2]
    if cmd == "xor":        # no key needed
        f = bytearray(open(file, "rb").read())
        f[int(sys.argv[3])] ^= int(sys.argv[4], 0)
        open(file, "wb").write(f)
        return 0
    pwd = sys.argv[3].encode()
    a = sys.argv[4:]
    if cmd == "make":       # old format: st failed exp name sechex ...
        n, p = packargs(a)
        open(file, "wb").write(oldenc(oldkey(pwd), bytes(range(16)), p + b"X"*16))
    elif cmd == "makeraw":  # old format, the entries' bytes as given
        open(file, "wb").write(oldenc(oldkey(pwd), bytes(range(16)), bytes.fromhex(a[0]) + b"X"*16))
    elif cmd == "many":     # old format, users u0 .. u(N-1)
        p = b"".join(pack(0, 0, 0, b"u%d" % i, b"") for i in range(int(a[0])))
        open(file, "wb").write(oldenc(oldkey(pwd), bytes(range(16)), p + b"X"*16))
    elif cmd == "makenew":  # new format: iterations, then entries as make
        n, p = packargs(a[1:])
        open(file, "wb").write(newenc(pwd, int(a[0]), n.to_bytes(4, "big") + p))
    elif cmd == "makenewraw":   # new format: iterations, count, the entries' bytes
        open(file, "wb").write(newenc(pwd, int(a[0]), int(a[1]).to_bytes(4, "big") + bytes.fromhex(a[2])))
    elif cmd == "dumpold":
        p = olddec(oldkey(pwd), open(file, "rb").read())
        if p[-16:] != b"X"*16:
            print("old recipe: no")
            return 1
        print("old recipe: yes")
        for r in recs(p[:-16]):
            print(*r)
    elif cmd == "dumpnew":
        try:
            it, p = newdec(pwd, open(file, "rb").read())
        except Exception as e:
            print("new recipe: no (%s)" % type(e).__name__)
            return 1
        print("new recipe: yes, %d iterations, %d entries" % (it, int.from_bytes(p[:4], "big")))
        for r in recs(p[4:]):
            print(*r)
    else:
        sys.stderr.write("kf.py: unknown command %s\n" % cmd)
        return 2
    return 0

if __name__ == "__main__":
    sys.exit(main())
