#!/usr/bin/env python3
# SLH-DSA-SHAKE-192s and -256s written from FIPS 205 (August 2024): the
# internal functions (Algorithms 2 to 20, with section 11.1's SHAKE
# instantiation) and the pure external interface over them (Algorithms 22
# and 24).  It is the reference tests/host/slhdsa/gen.py makes the known
# answers with, beside OpenSSL's where that can be reached (ossl.py); it
# is written for reading against the standard, not for speed.
#
# Three switches reproduce what libsec/slhdsa*.c did before it was held
# to the standard, so that a signature in the old format can be made
# again as a fixture (it must now be refused):
#   split   'fips': Algorithm 19: byte-aligned fields, each mod 2^bits
#           'old':  the bits from bit k*a on, as one bit string
#   csum    'fips': Algorithm 7: csum << 4, toByte(csum, 2), base_2b(., 4, 3)
#           'old':  the low three nibbles of csum << 4 (the top digit lost,
#                   the last always 0: only csum mod 256 was signed)
#   forskp  'fips': FORS addresses carry the key pair address idx_leaf
#           'old':  the type was set again in fors_sign and fors_pkFromSig,
#                   which clears the key pair address
# and the old code signed the caller's message as it came (the internal
# interface): SLH(par, 'old', 'old', 'old').sign(M, sk).
from hashlib import shake_256

class Par:
    def __init__(s, n, h, d, hp, a, k, m):
        s.n, s.h, s.d, s.hp, s.a, s.k, s.m = n, h, d, hp, a, k, m
        s.len1 = 2*n; s.len2 = 3; s.len = s.len1 + 3
P192 = Par(24, 63, 7, 9, 14, 17, 39)
P256 = Par(32, 64, 8, 8, 14, 22, 47)
WOTS_HASH, WOTS_PK, TREE, FORS_TREE, FORS_ROOTS, WOTS_PRF, FORS_PRF = range(7)

class ADRS:
    def __init__(s, b=None): s.b = bytearray(b if b is not None else 32)
    def copy(s): return ADRS(s.b)
    def setLayer(s, l): s.b[0:4] = l.to_bytes(4, 'big')
    def setTree(s, t): s.b[4:16] = t.to_bytes(12, 'big')
    def setTypeAndClear(s, y): s.b[16:20] = y.to_bytes(4, 'big'); s.b[20:32] = bytes(12)
    def setKeyPair(s, i): s.b[20:24] = i.to_bytes(4, 'big')
    def getKeyPair(s): return int.from_bytes(s.b[20:24], 'big')
    def setChain(s, i): s.b[24:28] = i.to_bytes(4, 'big')
    setTreeHeight = setChain
    def setHash(s, i): s.b[28:32] = i.to_bytes(4, 'big')
    setTreeIndex = setHash
    def getTreeIndex(s): return int.from_bytes(s.b[28:32], 'big')

nhash = 0
def XOF(data, n):
    global nhash; nhash += 1
    return shake_256(data).digest(n)

class SLH:
    def __init__(s, par, split='fips', csum='fips', forskp='fips'):
        s.p = par; s.split = split; s.csum = csum; s.forskp = forskp
    def F(s, pkseed, adrs, m): return XOF(pkseed + bytes(adrs.b) + m, s.p.n)
    H = F; T = F
    def PRF(s, pkseed, skseed, adrs): return XOF(pkseed + bytes(adrs.b) + skseed, s.p.n)
    def PRF_msg(s, skprf, optrand, M): return XOF(skprf + optrand + M, s.p.n)
    def H_msg(s, R, pkseed, pkroot, M): return XOF(R + pkseed + pkroot + M, s.p.m)
    # Alg 4
    @staticmethod
    def base_2b(X, b, outlen):
        i = 0; bits = 0; total = 0; out = []
        for _ in range(outlen):
            while bits < b:
                total = (total << 8) + X[i]; i += 1; bits += 8
            bits -= b
            out.append((total >> bits) % (1 << b))
        return out
    # Alg 5
    def chain(s, X, i, steps, pkseed, adrs):
        tmp = X
        for j in range(i, i + steps):
            adrs.setHash(j); tmp = s.F(pkseed, adrs, tmp)
        return tmp
    def wots_msg(s, M):
        msg = s.base_2b(M, 4, s.p.len1)
        csum = sum(15 - x for x in msg)
        if s.csum == 'fips':
            csum <<= 4
            msg += s.base_2b(csum.to_bytes(2, 'big'), 4, 3)
        else:   # what slhdsa_wots.c did
            csum <<= 4
            msg += [(csum >> 8) & 15, (csum >> 4) & 15, csum & 15]
        return msg
    # Alg 6
    def wots_pkGen(s, skseed, pkseed, adrs):
        sk = adrs.copy(); sk.setTypeAndClear(WOTS_PRF); sk.setKeyPair(adrs.getKeyPair())
        tmp = b''
        for i in range(s.p.len):
            sk.setChain(i); x = s.PRF(pkseed, skseed, sk)
            adrs.setChain(i); tmp += s.chain(x, 0, 15, pkseed, adrs)
        pka = adrs.copy(); pka.setTypeAndClear(WOTS_PK); pka.setKeyPair(adrs.getKeyPair())
        return s.T(pkseed, pka, tmp)
    # Alg 7
    def wots_sign(s, M, skseed, pkseed, adrs):
        msg = s.wots_msg(M)
        sk = adrs.copy(); sk.setTypeAndClear(WOTS_PRF); sk.setKeyPair(adrs.getKeyPair())
        sig = b''
        for i in range(s.p.len):
            sk.setChain(i); x = s.PRF(pkseed, skseed, sk)
            adrs.setChain(i); sig += s.chain(x, 0, msg[i], pkseed, adrs)
        return sig
    # Alg 8
    def wots_pkFromSig(s, sig, M, pkseed, adrs):
        n = s.p.n; msg = s.wots_msg(M); tmp = b''
        for i in range(s.p.len):
            adrs.setChain(i); tmp += s.chain(sig[i*n:(i+1)*n], msg[i], 15 - msg[i], pkseed, adrs)
        pka = adrs.copy(); pka.setTypeAndClear(WOTS_PK); pka.setKeyPair(adrs.getKeyPair())
        return s.T(pkseed, pka, tmp)
    # Alg 9, bottom-up over a whole tree: nodes[z][i]
    def xmss_tree(s, skseed, pkseed, adrs):
        lv = []
        for i in range(1 << s.p.hp):
            adrs.setTypeAndClear(WOTS_HASH); adrs.setKeyPair(i)
            lv.append(s.wots_pkGen(skseed, pkseed, adrs))
        nodes = [lv]
        for z in range(1, s.p.hp + 1):
            adrs.setTypeAndClear(TREE); adrs.setTreeHeight(z)
            nx = []
            for i in range(len(lv) // 2):
                adrs.setTreeIndex(i); nx.append(s.H(pkseed, adrs, lv[2*i] + lv[2*i+1]))
            nodes.append(nx); lv = nx
        return nodes
    # Alg 10
    def xmss_sign(s, M, skseed, idx, pkseed, adrs):
        nodes = s.xmss_tree(skseed, pkseed, adrs)
        auth = b''.join(nodes[j][(idx >> j) ^ 1] for j in range(s.p.hp))
        adrs.setTypeAndClear(WOTS_HASH); adrs.setKeyPair(idx)
        return s.wots_sign(M, skseed, pkseed, adrs) + auth
    # Alg 11
    def xmss_pkFromSig(s, idx, sig, M, pkseed, adrs):
        n = s.p.n
        adrs.setTypeAndClear(WOTS_HASH); adrs.setKeyPair(idx)
        node = s.wots_pkFromSig(sig[:s.p.len*n], M, pkseed, adrs)
        auth = sig[s.p.len*n:]
        adrs.setTypeAndClear(TREE); adrs.setTreeIndex(idx)
        for k in range(s.p.hp):
            adrs.setTreeHeight(k + 1)
            a = auth[k*n:(k+1)*n]
            if (idx >> k) % 2 == 0:
                adrs.setTreeIndex(adrs.getTreeIndex() // 2); node = s.H(pkseed, adrs, node + a)
            else:
                adrs.setTreeIndex((adrs.getTreeIndex() - 1) // 2); node = s.H(pkseed, adrs, a + node)
        return node
    # Alg 12
    def ht_sign(s, M, skseed, pkseed, idx_tree, idx_leaf):
        adrs = ADRS(); adrs.setTree(idx_tree)
        t = s.xmss_sign(M, skseed, idx_leaf, pkseed, adrs); sig = t
        root = s.xmss_pkFromSig(idx_leaf, t, M, pkseed, adrs)
        for j in range(1, s.p.d):
            idx_leaf = idx_tree % (1 << s.p.hp); idx_tree >>= s.p.hp
            adrs.setLayer(j); adrs.setTree(idx_tree)
            t = s.xmss_sign(root, skseed, idx_leaf, pkseed, adrs); sig += t
            if j < s.p.d - 1: root = s.xmss_pkFromSig(idx_leaf, t, root, pkseed, adrs)
        return sig
    # Alg 13
    def ht_verify(s, M, sig, pkseed, idx_tree, idx_leaf, pkroot, trace=None):
        xl = (s.p.len + s.p.hp) * s.p.n
        adrs = ADRS(); adrs.setTree(idx_tree)
        node = s.xmss_pkFromSig(idx_leaf, sig[:xl], M, pkseed, adrs)
        if trace is not None: trace.append(node)
        for j in range(1, s.p.d):
            idx_leaf = idx_tree % (1 << s.p.hp); idx_tree >>= s.p.hp
            adrs.setLayer(j); adrs.setTree(idx_tree)
            node = s.xmss_pkFromSig(idx_leaf, sig[j*xl:(j+1)*xl], node, pkseed, adrs)
            if trace is not None: trace.append(node)
        return node == pkroot
    # Alg 14-16
    def fors_adrs(s, adrs):
        if s.forskp == 'old':    # the old code: set_type(adrs, 3) again
            adrs.setTypeAndClear(FORS_TREE)
    def fors_sign(s, md, skseed, pkseed, adrs):
        s.fors_adrs(adrs)
        a, k, n = s.p.a, s.p.k, s.p.n
        ind = s.base_2b(md, a, k); sig = b''
        for i in range(k):
            ska = adrs.copy(); ska.setTypeAndClear(FORS_PRF); ska.setKeyPair(adrs.getKeyPair())
            lv = []
            for j in range(1 << a):
                ska.setTreeIndex((i << a) + j); x = s.PRF(pkseed, skseed, ska)
                if j == ind[i]: sig += x
                adrs.setTreeHeight(0); adrs.setTreeIndex((i << a) + j)
                lv.append(s.F(pkseed, adrs, x))
            for z in range(a):
                sig += lv[(ind[i] >> z) ^ 1]
                adrs.setTreeHeight(z + 1); nx = []
                for q in range(len(lv) // 2):
                    adrs.setTreeIndex((i << (a - z - 1)) + q); nx.append(s.H(pkseed, adrs, lv[2*q] + lv[2*q+1]))
                lv = nx
        return sig
    # Alg 17
    def fors_pkFromSig(s, sig, md, pkseed, adrs):
        s.fors_adrs(adrs)
        a, k, n = s.p.a, s.p.k, s.p.n
        ind = s.base_2b(md, a, k); roots = b''
        for i in range(k):
            o = i * (a + 1) * n
            adrs.setTreeHeight(0); adrs.setTreeIndex((i << a) + ind[i])
            node = s.F(pkseed, adrs, sig[o:o+n])
            for j in range(a):
                au = sig[o + (j+1)*n: o + (j+2)*n]
                adrs.setTreeHeight(j + 1)
                if (ind[i] >> j) % 2 == 0:
                    adrs.setTreeIndex(adrs.getTreeIndex() // 2); node = s.H(pkseed, adrs, node + au)
                else:
                    adrs.setTreeIndex((adrs.getTreeIndex() - 1) // 2); node = s.H(pkseed, adrs, au + node)
            roots += node
        pka = adrs.copy(); pka.setTypeAndClear(FORS_ROOTS); pka.setKeyPair(adrs.getKeyPair())
        return s.T(pkseed, pka, roots)
    def indices(s, digest):
        p = s.p; ka = p.k * p.a
        mdl = (ka + 7) // 8; tl = (p.h - p.hp + 7) // 8; ll = (p.hp + 7) // 8
        md = digest[:mdl]
        if s.split == 'fips':
            it = int.from_bytes(digest[mdl:mdl+tl], 'big') % (1 << (p.h - p.hp))
            il = int.from_bytes(digest[mdl+tl:mdl+tl+ll], 'big') % (1 << p.hp)
        else:   # the old split_digest: the bits from bit k*a on
            allbits = int.from_bytes(digest, 'big'); nb = 8 * len(digest)
            it = (allbits >> (nb - ka - (p.h - p.hp))) % (1 << (p.h - p.hp))
            il = (allbits >> (nb - ka - p.h)) % (1 << p.hp)
        return md, it, il
    # Alg 18
    def keygen(s, skseed, skprf, pkseed):
        adrs = ADRS(); adrs.setLayer(s.p.d - 1)
        root = s.xmss_tree(skseed, pkseed, adrs)[s.p.hp][0]
        return pkseed + root, skseed + skprf + pkseed + root
    # Alg 19, slh_sign_internal: opt_rand is addrnd, or PK.seed (the
    # deterministic variant) with none
    def sign(s, M, sk, addrnd=None):
        n = s.p.n
        skseed, skprf, pkseed, pkroot = sk[:n], sk[n:2*n], sk[2*n:3*n], sk[3*n:]
        R = s.PRF_msg(skprf, pkseed if addrnd is None else addrnd, M)
        md, it, il = s.indices(s.H_msg(R, pkseed, pkroot, M))
        adrs = ADRS(); adrs.setTree(it); adrs.setTypeAndClear(FORS_TREE); adrs.setKeyPair(il)
        fs = s.fors_sign(md, skseed, pkseed, adrs)
        fpk = s.fors_pkFromSig(fs, md, pkseed, adrs)
        return R + fs + s.ht_sign(fpk, skseed, pkseed, it, il)
    # Alg 20, slh_verify_internal
    def verify(s, M, sig, pk, trace=None):
        p = s.p; n = p.n
        if len(sig) != (1 + p.k*(1 + p.a) + p.h + p.d*p.len) * n: return False
        pkseed, pkroot = pk[:n], pk[n:]
        R = sig[:n]; fl = p.k * (1 + p.a) * n
        md, it, il = s.indices(s.H_msg(R, pkseed, pkroot, M))
        adrs = ADRS(); adrs.setTree(it); adrs.setTypeAndClear(FORS_TREE); adrs.setKeyPair(il)
        fpk = s.fors_pkFromSig(sig[n:n+fl], md, pkseed, adrs)
        if trace is not None: trace.append((it, il, fpk))
        return s.ht_verify(fpk, sig[n+fl:], pkseed, it, il, pkroot, trace)

# Algorithms 22 and 24: the pure signature's M' for a context string
def mprime(M, ctx=b""):
    if len(ctx) > 255: raise ValueError("context longer than 255 bytes")
    return bytes([0, len(ctx)]) + ctx + M

def slh_sign(par, M, sk, ctx=b"", addrnd=None):   # Alg 22; deterministic with no addrnd
    return SLH(par).sign(mprime(M, ctx), sk, addrnd)

def slh_verify(par, M, sig, pk, ctx=b""):  # Alg 24
    return SLH(par).verify(mprime(M, ctx), sig, pk)
