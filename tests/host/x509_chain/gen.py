#!/usr/bin/env python3
# Certificates, CRLs and chains for tests/host/x509_chain_test.sh.
#
#	gen.py OUT INEMU
#	gen.py -f DIR
#
# The second writes the certificates and the CRL that
# tests/x509_total_test.b decodes, changes and decodes again (they are
# kept in the tree, in tests/certs/total: that test runs where there is
# no python).  The first writes into the directory OUT (which the
# emulator sees as INEMU):
#	*.der		certificates and CRLs
#	cases		one case a line for tests/x509_chain.b
#	expect		label, ACCEPT or REJECT, and for a REJECT a piece of
#			the reason the verifier must give
#	tls/		certificates, keys and a list of cases for the
#			handshakes (see x509_chain_test.sh and fake_tls12.py)
#
# Every byte of a certificate here is chosen by this file (a small DER
# writer); python-cryptography only makes the keys and signs.  Keys are
# made new each run and nothing is kept: no certificate here is ever a
# trust anchor outside the test's own name space.

import os, sys, time, base64
from cryptography.hazmat.primitives.asymmetric import ec, rsa, utils, padding
from cryptography.hazmat.primitives import hashes, serialization

OUT = INEMU = None

# ---- DER

def length(n):
    if n < 0x80:
        return bytes([n])
    b = n.to_bytes((n.bit_length() + 7) // 8, 'big')
    return bytes([0x80 | len(b)]) + b

def tlv(tag, body): return bytes([tag]) + length(len(body)) + body
def seq(*xs): return tlv(0x30, b''.join(xs))
def set_(*xs): return tlv(0x31, b''.join(xs))
def integer(n):
    if n == 0:
        return b'\x02\x01\x00'
    return tlv(0x02, n.to_bytes((n.bit_length() + 8) // 8, 'big', signed=True))
def oid(s):
    a = [int(x) for x in s.split('.')]
    out = bytes([a[0] * 40 + a[1]])
    for v in a[2:]:
        c = [v & 0x7f]
        v >>= 7
        while v:
            c.append(0x80 | (v & 0x7f))
            v >>= 7
        out += bytes(reversed(c))
    return tlv(0x06, out)
def bitstr(b, unused=0): return tlv(0x03, bytes([unused]) + b)
def octet(b): return tlv(0x04, b)
def utf8(s): return tlv(0x0c, s if isinstance(s, bytes) else s.encode())
def printable(s): return tlv(0x13, s.encode())
def bmp(s): return tlv(0x1e, s.encode('utf-16-be'))
def utctime(t): return tlv(0x17, time.strftime('%y%m%d%H%M%SZ', time.gmtime(t)).encode())
def boolean(v): return tlv(0x01, bytes([0xff if v is True else (0 if v is False else v)]))
def ctx(n, body, constructed=True): return tlv((0xa0 if constructed else 0x80) | n, body)
NULL = b'\x05\x00'

ECDSA256 = seq(oid('1.2.840.10045.4.3.2'))
RSA256 = seq(oid('1.2.840.113549.1.1.11'), NULL)
D = 86400
NOW = int(time.time())
nb, na = NOW - 30 * D, NOW + 365 * D

def dn(*avas):
    """avas: (oid, DER string) pairs, one RDN each"""
    return seq(*[set_(seq(oid(o), v)) for o, v in avas])
O, CN, C, EMAIL = '2.5.4.10', '2.5.4.3', '2.5.4.6', '1.2.840.113549.1.9.1'
def name(cn): return dn((O, utf8('T6 Test')), (CN, utf8(cn)))

def spki(key): return key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
def rsaspki(n, e): return seq(seq(oid('1.2.840.113549.1.1.1'), NULL), bitstr(seq(integer(n), integer(e))))

def ext(o, value, critical=None):
    parts = [oid(o)]
    if critical is not None:
        parts.append(boolean(critical))
    return seq(*parts, octet(value))

BC, KU, SAN, NC, EKU = '2.5.29.19', '2.5.29.15', '2.5.29.17', '2.5.29.30', '2.5.29.37'
CP, PM, PC, IAP, CRLDP, AKI, IDP = '2.5.29.32', '2.5.29.33', '2.5.29.36', '2.5.29.54', '2.5.29.31', '2.5.29.35', '2.5.29.28'
UNKNOWN = '1.3.6.1.4.1.99999.1'
SERVERAUTH, CLIENTAUTH, EMAILPROT, ANYEKU = '1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.2', '1.3.6.1.5.5.7.3.4', '2.5.29.37.0'

def bc(ca=None, pathlen=None, critical=True):
    parts = []
    if ca:
        parts.append(boolean(True))
    if pathlen is not None:
        parts.append(integer(pathlen))
    return ext(BC, seq(*parts), critical)
def ku(bits, critical=True):
    v = 0
    for b in bits:
        v |= 0x80 >> b
    if v == 0:
        return ext(KU, bitstr(b''), critical)
    unused = 0
    while not (v >> unused) & 1:
        unused += 1
    return ext(KU, bitstr(bytes([v]), unused), critical)
def gdns(s): return ctx(2, s.encode(), False)
def gip(b): return ctx(7, bytes(b), False)
def gmail(s): return ctx(1, s.encode(), False)
def gdir(d): return ctx(4, d)
def san(*names, critical=None): return ext(SAN, seq(*[gdns(n) if isinstance(n, str) else n for n in names]), critical)
def eku(*oids, critical=None): return ext(EKU, seq(*[oid(o) for o in oids]), critical)
def nc(permitted=(), excluded=(), critical=True, minimum=None):
    def subtrees(l):
        return b''.join(seq(g, *([ctx(0, bytes([minimum]), False)] if minimum is not None else [])) for g in l)
    parts = []
    if permitted:
        parts.append(ctx(0, subtrees(permitted)))
    if excluded:
        parts.append(ctx(1, subtrees(excluded)))
    return ext(NC, seq(*parts), critical)

def tbs(serial, issuer, subject, pub, exts=None, nb=nb, na=na, sigalg=ECDSA256, version=2):
    parts = []
    if version:
        parts.append(ctx(0, integer(version)))
    parts += [integer(serial), sigalg, issuer, seq(utctime(nb), utctime(na)), subject, pub]
    if exts:
        parts.append(ctx(3, seq(*exts)))
    return seq(*parts)

def sign(key, body):
    """(algorithm, signature bytes) by key over body"""
    if isinstance(key, ec.EllipticCurvePrivateKey):
        r, s = utils.decode_dss_signature(key.sign(body, ec.ECDSA(hashes.SHA256())))
        return ECDSA256, seq(integer(r), integer(s))
    return RSA256, key.sign(body, padding.PKCS1v15(), hashes.SHA256())

def mk(key, body):
    alg, sig = sign(key, body)
    return seq(body, alg, bitstr(sig))

def crl(key, issuer, serials, this, nxt, exts=None):
    parts = [integer(1), ECDSA256, issuer, utctime(this)]
    if nxt is not None:
        parts.append(utctime(nxt))
    if serials:
        parts.append(seq(*[seq(integer(s), utctime(this)) for s in serials]))
    if exts:
        parts.append(ctx(0, seq(*exts)))
    body = seq(*parts)
    alg, sig = sign(key, body)
    return seq(body, alg, bitstr(sig))

def eckey(): return ec.generate_private_key(ec.SECP256R1())
def P(k): return spki(k)


def fixtures(dir):
    """Certificates with one of everything the decoders read, valid from
    2026 to 2049 (UTCTime throughout); tests/x509_total_test.b verifies
    them at a time of its own, not the clock's."""
    os.makedirs(dir, exist_ok=True)
    fnb, fna = 1767225600, 2522102400		# 2026-01-01, 2049-12-03
    kr, ki, kl = eckey(), eckey(), eckey()
    def wr(fn, b):
        with open(os.path.join(dir, fn), 'wb') as fd:
            fd.write(b)
    t6 = dn((O, utf8('T6 Test')))
    rootexts = [bc(True), ku([5, 6]),
        nc(permitted=[gdns('.example'), gdns('example'), gdir(t6)],
           excluded=[gip([10, 0, 0, 0, 255, 0, 0, 0]), gip([0] * 15 + [9] + [255] * 16), gdns('bad.example'),
                     gdir(dn((O, utf8('Evil'))))])]
    root = mk(kr, tbs(1, name('Root'), name('Root'), P(kr), rootexts, nb=fnb, na=fna))
    wr('root.der', root)
    POL = '2.23.140.1.2.1'
    cps = ext(CP, seq(seq(oid(POL), seq(seq(oid('1.3.6.1.5.5.7.2.1'), tlv(0x16, b'http://cps.invalid/')))), seq(oid('1.2.3.4'))), True)
    skid = ext('2.5.29.14', octet(b'\x01\x02\x03\x04'))
    interexts = [bc(True, 0), ku([5, 6]), cps, ext(PM, seq(seq(oid(POL), oid('1.2.3.5'))), True),
        ext(PC, seq(ctx(0, b'\x05', False), ctx(1, b'\x01', False)), True), ext(IAP, integer(2), True),
        ext(AKI, seq(ctx(0, b'\x01\x02\x03\x04', False))), skid]
    wr('inter.der', mk(kr, tbs(2, name('Root'), name('Inter'), P(ki), interexts, nb=fnb, na=fna)))
    leafexts = [bc(), ku([0]), eku(SERVERAUTH, CLIENTAUTH),
        san('a.example', '*.b.example', gip([192, 0, 2, 1]), gip([0x20, 1, 0xd, 0xb8] + [0] * 11 + [1]),
            gmail('a@a.example'), ctx(6, b'https://a.example/', False),
            ctx(0, oid('1.3.6.1.4.1.311.20.2.3') + ctx(0, utf8('u@a.example'))),
            gdir(dn((O, printable('T6 Test')), (CN, utf8('x'))))),
        ext(CP, seq(seq(oid(POL)))),
        ext(AKI, seq(ctx(0, b'\x01\x02\x03\x04', False), ctx(1, gdir(name('Root'))), ctx(2, b'\x02', False))),
        ext(CRLDP, seq(seq(ctx(0, ctx(0, ctx(6, b'http://crl.invalid/x.crl', False)))))),
        ext(UNKNOWN, octet(b'opaque'))]
    wr('leaf.der', mk(ki, tbs(77001, name('Inter'), name('a.example'), P(kl), leafexts, nb=fnb, na=fna)))
    centry = lambda n: seq(integer(n), utctime(fnb), seq(ext('2.5.29.21', tlv(0x0a, b'\x01'))))
    cbody = seq(integer(1), ECDSA256, name('Root'), utctime(fnb), utctime(fna), seq(centry(5001), centry(5002)),
        ctx(0, seq(ext('2.5.29.20', integer(7)), ext(AKI, seq(ctx(0, b'\x01\x02', False))))))
    alg, sig = sign(kr, cbody)
    wr('crl.der', seq(cbody, alg, bitstr(sig)))
    kq = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    rname = name('RSA Root')
    wr('rsaroot.der', mk(kq, tbs(1, rname, rname, P(kq), [bc(True), ku([5, 6])], nb=fnb, na=fna, sigalg=RSA256)))
    wr('rsaleaf.der', mk(kq, tbs(3, rname, name('r.example'), P(kl), [san('r.example')], nb=fnb, na=fna, sigalg=RSA256)))

def chains():
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(OUT + '/tls', exist_ok=True)
    cases, expect = [], []
    serial = [1000]
    def ser():
        serial[0] += 1
        return serial[0]
    def w(fn, b):
        with open(os.path.join(OUT, fn + '.der'), 'wb') as f:
            f.write(b)
        return fn
    def f(fn): return INEMU + '/' + fn + '.der'
    def case(label, want, chain, roots=('root',), crls=(), now=NOW, why=''):
        cases.append('%s roots %d %s %s %s' % (label, now,
            ' '.join('r=' + f(r) for r in roots), ' '.join('c=' + f(c) for c in crls), ' '.join('l=' + f(c) for c in chain)))
        expect.append('%s %s %s' % (label, want, why))
    def storecase(label, want, chain, certs, crls, why=''):
        cases.append('%s store %s/%s %s/%s %s' % (label, INEMU, certs, INEMU, crls, ' '.join('l=' + f(c) for c in chain)))
        expect.append('%s %s %s' % (label, want, why))
    def storedir(d, files):
        os.makedirs(os.path.join(OUT, d), exist_ok=True)
        for fn, b in files.items():
            with open(os.path.join(OUT, d, fn), 'wb') as fd:
                fd.write(b)

    kroot, kint, kleaf, k2 = eckey(), eckey(), eckey(), eckey()
    CAEXT = [bc(True), ku([5, 6])]
    root = mk(kroot, tbs(1, name('Root'), name('Root'), P(kroot), CAEXT, nb=nb - 300 * D, na=na + 3000 * D))
    w('root', root)
    w('inter', mk(kroot, tbs(2, name('Root'), name('Inter'), P(kint), [bc(True, 0), ku([5, 6])])))

    def leaf(cn='leaf.example', exts='def', issuer='Inter', key=None, subject=None, **kw):
        if exts == 'def':
            exts = [bc(), ku([0]), san(cn)]
        return mk(key or kint, tbs(ser(), name(issuer), subject or name(cn), P(kleaf), exts, **kw))

    def under(label, want, caexts, why='', leafexts=None, subject=None, lsubject=None, cn='victim.example', version=2):
        """Root -> X (extensions caexts) -> a leaf signed by X's key"""
        xs = subject or name('X-' + label)
        w('x-' + label, mk(kroot, tbs(ser(), name('Root'), xs, P(k2), caexts, version=version)))
        w('l-' + label, mk(k2, tbs(ser(), xs, lsubject or name(cn), P(kleaf), [san(cn)] if leafexts is None else leafexts)))
        case(label, want, ['l-' + label, 'x-' + label], why=why)

    def onleaf(label, want, exts, why='', **kw):
        w('leaf-' + label, leaf(exts=exts, **kw))
        case(label, want, ['leaf-' + label, 'inter'], why=why)

    # ---- what must go on verifying
    w('leaf', leaf())
    case('good', 'ACCEPT', ['leaf', 'inter'])
    case('good-root-sent', 'ACCEPT', ['leaf', 'inter', 'root'])
    case('missing-inter', 'REJECT', ['leaf'], why='no trusted root')
    under('ca-true', 'ACCEPT', [bc(True), ku([5])])
    under('ca-ku-absent', 'ACCEPT', [bc(True)])
    under('ca-false-der', 'REJECT', [bc(), ku([0, 5])], 'not a CA')
    under('ca-v1', 'REJECT', None, 'not a CA', version=0)
    under('ca-no-keycertsign', 'REJECT', [bc(True), ku([0])], 'keyCertSign')

    # ---- 1. certificates that are not certificates: an error, never an exception
    def malformed(label, der, why='certificate'):
        w('mal-' + label, der)
        case('mal-' + label, 'REJECT', ['mal-' + label, 'inter'], why=why)
    good_tbs = tbs(ser(), name('Inter'), name('leaf.example'), P(kleaf), [san('leaf.example')])
    def with_tbs(body): return mk(kint, body)
    malformed('tbs-empty-seq', with_tbs(seq()))
    malformed('tbs-1-element', with_tbs(seq(integer(5))))
    malformed('tbs-5-elements-noversion', with_tbs(seq(integer(5), ECDSA256, name('Inter'), seq(utctime(nb), utctime(na)), name('x'))))
    malformed('tbs-version-only', with_tbs(seq(ctx(0, integer(2)))))
    malformed('ext-empty-seq', with_tbs(tbs(ser(), name('Inter'), name('x'), P(kleaf), [seq()])))
    malformed('ext-oid-only', with_tbs(tbs(ser(), name('Inter'), name('x'), P(kleaf), [seq(oid(SAN))])))
    malformed('ext-oid-bool-only', with_tbs(tbs(ser(), name('Inter'), name('x'), P(kleaf), [seq(oid(SAN), boolean(True))])))
    # a length of 16r7fffffff: i+length wrapped in asn1's decoder and in x509's own
    huge = b'\x84\x7f\xff\xff\xff'
    malformed('len-wrap-octets', with_tbs(tbs(ser(), name('Inter'), name('x'), P(kleaf), [seq(oid(SAN), b'\x04' + huge)])))
    malformed('len-wrap-integer', with_tbs(seq(ctx(0, integer(2)), b'\x02' + huge)))
    malformed('len-wrap-bits', with_tbs(tbs(ser(), name('Inter'), name('x'), seq(ECDSA256, b'\x03' + huge))))
    malformed('len-wrap-in-name', with_tbs(tbs(ser(), name('Inter'), seq(set_(seq(oid(CN), b'\x0c' + huge))), P(kleaf))))
    malformed('outer-tbs-len-7fffffff', bytes.fromhex('300a30847fffffff00000000'))
    malformed('outer-alg-len-7fffffff', seq(good_tbs, b'\x30' + huge))
    malformed('indefinite-tbs', seq(b'\x30\x80' + good_tbs[2:] + b'\x00\x00', ECDSA256, bitstr(b'\x00')))
    malformed('truncated', root[:len(root) // 2])
    malformed('empty', b'')
    case('mal-root', 'REJECT', ['leaf', 'inter'], roots=('mal-tbs-empty-seq',), why='root')
    w('crl-ext-empty-seq', crl(kroot, name('Root'), [5], NOW - D, NOW + D, [seq()]))
    case('mal-crl-ext-empty-seq', 'REJECT', ['leaf', 'inter'], crls=('crl-ext-empty-seq',), why='CRL')
    w('crl-len-wrap', seq(seq(integer(1), ECDSA256, name('Root'), b'\x17' + huge), ECDSA256, bitstr(b'\x00')))
    case('mal-crl-len-wrap', 'REJECT', ['leaf', 'inter'], crls=('crl-len-wrap',), why='CRL')

    # RSA keys that are not keys, in an issuer (its signature is checked with it)
    krsa = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    nrsa = krsa.public_key().public_numbers().n
    def rsaissuer(label, want, n, e, why, sig=None):
        xs = name('R-' + label)
        w('x-' + label, mk(kroot, tbs(ser(), name('Root'), xs, rsaspki(n, e), CAEXT)))
        body = tbs(ser(), xs, name('victim.example'), P(kleaf), [san('victim.example')], sigalg=RSA256)
        if sig is None:
            sig = krsa.sign(body, padding.PKCS1v15(), hashes.SHA256())
        w('l-' + label, seq(body, RSA256, bitstr(sig)))
        case(label, want, ['l-' + label, 'x-' + label], why=why)
    rsaissuer('rsa-good', 'ACCEPT', nrsa, 65537, '')
    rsaissuer('rsa-modulus-0', 'REJECT', 0, 65537, 'rsa public key', sig=b'\x00')
    rsaissuer('rsa-modulus-1', 'REJECT', 1, 65537, 'rsa public key', sig=b'\x00')
    rsaissuer('rsa-modulus-even', 'REJECT', nrsa + 1, 65537, 'rsa public key')
    rsaissuer('rsa-exponent-even', 'REJECT', nrsa, 65536, 'rsa public key')
    rsaissuer('rsa-exponent-0', 'REJECT', nrsa, 0, 'rsa public key')
    k1024 = rsa.generate_private_key(public_exponent=65537, key_size=1024)
    rsaissuer('rsa-1024-bits', 'REJECT', k1024.public_key().public_numbers().n, 65537, 'under 2048')
    # a public exponent of 1: the "signature" is the padded digest itself, which anyone can write
    xs = name('R-e1')
    w('x-rsa-exponent-1', mk(kroot, tbs(ser(), name('Root'), xs, rsaspki(nrsa, 1), CAEXT)))
    body = tbs(ser(), xs, name('victim.example'), P(kleaf), [san('victim.example')], sigalg=RSA256)
    h = hashes.Hash(hashes.SHA256()); h.update(body)
    di = bytes.fromhex('3031300d060960864801650304020105000420') + h.finalize()
    w('l-rsa-exponent-1', seq(body, RSA256, bitstr(b'\x00\x01' + b'\xff' * (256 - 3 - len(di)) + b'\x00' + di)))
    case('rsa-exponent-1', 'REJECT', ['l-rsa-exponent-1', 'x-rsa-exponent-1'], why='rsa public key')
    # a negative INTEGER (no leading 00): was read as a positive number
    xs = name('R-neg')
    w('x-rsa-negative', mk(kroot, tbs(ser(), name('Root'), xs,
        seq(seq(oid('1.2.840.113549.1.1.1'), NULL), bitstr(seq(tlv(2, nrsa.to_bytes(256, 'big')), integer(65537)))), CAEXT)))
    body = tbs(ser(), xs, name('victim.example'), P(kleaf), [san('victim.example')], sigalg=RSA256)
    w('l-rsa-negative', seq(body, RSA256, bitstr(krsa.sign(body, padding.PKCS1v15(), hashes.SHA256()))))
    case('rsa-modulus-negative', 'REJECT', ['l-rsa-negative', 'x-rsa-negative'], why='subject public key')

    # ---- 2. critical extensions, name constraints (RFC 5280 4.2, 4.2.1.10, 6.1)
    under('issuer-unknown-critical', 'REJECT', CAEXT + [ext(UNKNOWN, octet(b'x'), True)], 'unrecognized critical extension')
    under('issuer-unknown-noncritical', 'ACCEPT', CAEXT + [ext(UNKNOWN, octet(b'x'))])
    onleaf('leaf-unknown-critical', 'REJECT', [san('leaf.example'), ext(UNKNOWN, octet(b'x'), True)], 'unrecognized critical extension')
    onleaf('leaf-unknown-noncritical', 'ACCEPT', [san('leaf.example'), ext(UNKNOWN, octet(b'x'))])
    w('root-unkcrit', mk(kroot, tbs(1, name('Root'), name('Root'), P(kroot), CAEXT + [ext(UNKNOWN, octet(b'x'), True)])))
    case('anchor-unknown-critical', 'REJECT', ['leaf', 'inter'], roots=('root-unkcrit',), why='unrecognized critical extension')
    # FALSE written out (BER): not critical.  It read as critical while every BOOLEAN was the buffer's first byte.
    onleaf('leaf-unknown-critical-false-written', 'ACCEPT', [san('leaf.example', critical=False), ext(UNKNOWN, octet(b'x'), False)])
    onleaf('leaf-critical-01', 'REJECT', [san('leaf.example'), ext(UNKNOWN, octet(b'x'), 1)], 'certificate')
    onleaf('leaf-san-eku-critical', 'ACCEPT', [san('leaf.example', critical=True), eku(SERVERAUTH, critical=True), bc(), ku([0])])
    onleaf('leaf-crldp-critical', 'REJECT', [san('leaf.example'), ext(CRLDP, seq(seq(ctx(0, ctx(0, ctx(6, b'http://crl.invalid/x', False))))), True)], 'unrecognized critical extension')
    onleaf('leaf-aki-critical', 'REJECT', [san('leaf.example'), ext(AKI, seq(ctx(0, b'\x01\x02', False)), True)], 'unrecognized critical extension')
    onleaf('leaf-two-sans', 'REJECT', [san('other.example'), san('leaf.example')], 'twice')
    under('issuer-two-bc-false-then-true', 'REJECT', [bc(), bc(True)], 'twice')
    onleaf('leaf-san-empty', 'REJECT', [ext(SAN, seq())], 'subjectAltName')
    under('issuer-ku-empty', 'REJECT', [bc(True), ku([])], 'keyUsage')

    # policies: nothing here names a policy, so only requireExplicitPolicy can fail a path
    POL = '2.23.140.1.2.1'
    cp = lambda critical=None: ext(CP, seq(seq(oid(POL))), critical)
    onleaf('leaf-policies-critical', 'ACCEPT', [san('leaf.example'), cp(True)])
    onleaf('leaf-policies-with-qualifier', 'ACCEPT', [san('leaf.example'), ext(CP, seq(seq(oid(POL), seq(seq(oid('1.3.6.1.5.5.7.2.1'), tlv(0x16, b'http://cps.invalid/'))))), True)])
    onleaf('leaf-policies-twice-same', 'REJECT', [san('leaf.example'), ext(CP, seq(seq(oid(POL)), seq(oid(POL))))], 'certificatePolicies')
    under('issuer-policies-mappings-inhibit', 'ACCEPT', CAEXT + [cp(True), ext(PM, seq(seq(oid(POL), oid('1.2.3.4'))), True), ext(IAP, integer(0), True)])
    under('issuer-mapping-anypolicy', 'REJECT', CAEXT + [ext(PM, seq(seq(oid('2.5.29.32.0'), oid('1.2.3.4'))), True)], 'policyMappings')
    under('issuer-require-explicit-policy-0', 'REJECT', CAEXT + [ext(PC, seq(ctx(0, b'\x00', False)), True)], 'explicit certificate policy')
    under('issuer-require-explicit-policy-5', 'ACCEPT', CAEXT + [ext(PC, seq(ctx(0, b'\x05', False)), True)])
    under('issuer-inhibit-policy-mapping', 'ACCEPT', CAEXT + [ext(PC, seq(ctx(1, b'\x00', False)), True)])
    under('issuer-policyconstraints-empty', 'REJECT', CAEXT + [ext(PC, seq(), True)], 'policyConstraints')
    onleaf('leaf-require-explicit-policy-0', 'REJECT', [san('leaf.example'), ext(PC, seq(ctx(0, b'\x00', False)), True)], 'explicit certificate policy')

    # name constraints on dNSName
    PERMIT_CORP = CAEXT + [nc(permitted=[gdns('.corp.example')])]
    under('nc-permit-dotcorp-victim', 'REJECT', PERMIT_CORP, 'not in a permitted subtree')
    under('nc-permit-dotcorp-inside', 'ACCEPT', PERMIT_CORP, cn='a.corp.example')
    under('nc-permit-dotcorp-noncritical', 'REJECT', CAEXT + [nc(permitted=[gdns('.corp.example')], critical=None)], 'not in a permitted subtree')
    P2 = CAEXT + [nc(permitted=[gdns('corp.example'), gdns('other.example')])]
    under('nc-permit-corp-itself', 'ACCEPT', P2, cn='corp.example')
    under('nc-permit-corp-below', 'ACCEPT', P2, cn='www.Corp.Example')
    under('nc-permit-corp-second', 'ACCEPT', P2, cn='other.example')
    under('nc-permit-corp-suffix-not-label', 'REJECT', P2, 'not in a permitted subtree', cn='xcorp.example')
    under('nc-permit-corp-one-of-two-names', 'REJECT', P2, 'not in a permitted subtree', leafexts=[san('a.corp.example', 'victim.example')])
    under('nc-permit-corp-wildcard-inside', 'ACCEPT', P2, leafexts=[san('*.corp.example')], cn='x.corp.example')
    under('nc-permit-corp-wildcard-wider', 'REJECT', P2, 'not in a permitted subtree', leafexts=[san('*.example')])
    EXCL = CAEXT + [nc(excluded=[gdns('victim.example')])]
    under('nc-exclude-victim', 'REJECT', EXCL, 'excluded subtree')
    under('nc-exclude-victim-below', 'REJECT', EXCL, 'excluded subtree', cn='www.victim.example')
    under('nc-exclude-victim-case-dot', 'REJECT', EXCL, 'excluded subtree', leafexts=[san('VICTIM.example.')])
    under('nc-exclude-victim-wildcard', 'REJECT', EXCL, 'excluded subtree', leafexts=[san('*.example')])
    under('nc-exclude-victim-other', 'ACCEPT', EXCL, cn='other.example')
    # no subjectAltName: TLS reads the commonName as the host's name
    under('nc-permit-cn-fallback-victim', 'REJECT', PERMIT_CORP, 'not in a permitted subtree', leafexts=[bc()])
    under('nc-permit-cn-fallback-inside', 'ACCEPT', PERMIT_CORP, leafexts=[bc()], cn='a.corp.example')
    # on the trust anchor, and two levels up
    w('root-nc', mk(kroot, tbs(1, name('Root'), name('Root'), P(kroot), PERMIT_CORP)))
    case('nc-anchor-permit-victim', 'REJECT', ['leaf', 'inter'], roots=('root-nc',), why='not in a permitted subtree')
    w('leaf-corp', leaf('a.corp.example'))
    case('nc-anchor-permit-inside', 'ACCEPT', ['leaf-corp', 'inter'], roots=('root-nc',))
    kb = eckey()
    w('x-nc2', mk(kroot, tbs(ser(), name('Root'), name('X-nc2'), P(k2), PERMIT_CORP)))
    w('y-nc2', mk(k2, tbs(ser(), name('X-nc2'), name('Y-nc2'), P(kb), CAEXT)))
    w('l-nc2', mk(kb, tbs(ser(), name('Y-nc2'), name('victim.example'), P(kleaf), [san('victim.example')])))
    case('nc-two-levels-up', 'REJECT', ['l-nc2', 'y-nc2', 'x-nc2'], why='not in a permitted subtree')
    # iPAddress
    IP10 = CAEXT + [nc(permitted=[gip([10, 0, 0, 0, 255, 0, 0, 0])])]
    under('nc-ip-permit-inside', 'ACCEPT', IP10, leafexts=[san(gip([10, 1, 2, 3]))])
    under('nc-ip-permit-outside', 'REJECT', IP10, 'not in a permitted subtree', leafexts=[san(gip([192, 168, 1, 1]))])
    under('nc-ip-permit-dns-untouched', 'ACCEPT', IP10)
    NOIP = CAEXT + [nc(permitted=[gdns('example')], excluded=[gip([0] * 8), gip([0] * 32)])]
    under('nc-ip-exclude-all-v4', 'REJECT', NOIP, 'excluded subtree', leafexts=[san('victim.example', gip([127, 0, 0, 1]))])
    under('nc-ip-exclude-all-v6', 'REJECT', NOIP, 'excluded subtree', leafexts=[san('victim.example', gip([0] * 15 + [1]))])
    under('nc-ip-exclude-all-dns-only', 'ACCEPT', NOIP)
    under('nc-ip-bad-length', 'REJECT', CAEXT + [nc(permitted=[gip([10, 0, 0, 0, 255])])], 'nameConstraints')
    # directoryName
    CORPDN = dn((C, printable('US')), (O, utf8('Corp')))
    def sub(*more): return dn((C, printable('US')), (O, utf8('Corp')), *more)
    DNP = CAEXT + [nc(permitted=[gdir(CORPDN)])]
    under('nc-dir-permit-inside', 'ACCEPT', DNP, subject=sub((CN, utf8('Corp CA'))), lsubject=sub((CN, utf8('victim.example'))))
    under('nc-dir-permit-case-space', 'ACCEPT', DNP, subject=sub((CN, utf8('Corp CA'))),
        lsubject=dn((C, printable('us')), (O, printable(' corp  ')), (CN, utf8('victim.example'))))
    under('nc-dir-permit-outside', 'REJECT', DNP, 'not in a permitted subtree', subject=sub((CN, utf8('Corp CA'))),
        lsubject=dn((C, printable('US')), (O, utf8('Other')), (CN, utf8('victim.example'))))
    under('nc-dir-permit-bmpstring', 'REJECT', DNP, 'not in a permitted subtree', subject=sub((CN, utf8('Corp CA'))),
        lsubject=dn((C, printable('US')), (O, bmp('Corp')), (CN, utf8('victim.example'))))
    DNX = CAEXT + [nc(excluded=[gdir(dn((C, printable('US')), (O, utf8('Evil'))))])]
    under('nc-dir-exclude-inside', 'REJECT', DNX, 'excluded subtree', lsubject=dn((C, printable('US')), (O, utf8('EVIL')), (CN, utf8('victim.example'))))
    under('nc-dir-exclude-bmpstring', 'REJECT', DNX, 'excluded subtree', lsubject=dn((C, printable('US')), (O, bmp('Evil')), (CN, utf8('victim.example'))))
    under('nc-dir-exclude-outside', 'ACCEPT', DNX, lsubject=dn((C, printable('US')), (O, utf8('Good')), (CN, utf8('victim.example'))))
    # a form that is not compared: refused when a name of that form is there
    MAILNC = CAEXT + [nc(permitted=[gmail('corp.example')])]
    under('nc-rfc822-name-present', 'REJECT', MAILNC, 'rfc822Name', leafexts=[san('victim.example', gmail('a@victim.example'))])
    under('nc-rfc822-in-subject', 'REJECT', MAILNC, 'rfc822Name', leafexts=[bc()],
        lsubject=dn((O, utf8('T6 Test')), (EMAIL, tlv(0x16, b'a@victim.example'))))
    under('nc-rfc822-no-such-name', 'ACCEPT', MAILNC)
    # malformed
    under('nc-minimum-1', 'REJECT', CAEXT + [nc(permitted=[gdns('.corp.example')], minimum=1)], 'nameConstraints', cn='a.corp.example')
    under('nc-empty', 'REJECT', CAEXT + [ext(NC, seq(), True)], 'nameConstraints')

    # ---- 3. BOOLEAN: cA FALSE written out was read as TRUE
    under('ca-false-written-out', 'REJECT', [ext(BC, seq(boolean(False)), True)], 'not a CA')
    under('ca-false-written-out-pathlen', 'REJECT', [ext(BC, seq(boolean(False), integer(3)), True)], 'not a CA')
    under('ca-true-as-01', 'REJECT', [ext(BC, seq(boolean(1)), True)], 'basicConstraints')

    # ---- 4. CRLs: a caller's and the store's
    kr = eckey()
    rs = ser()
    rleaf = mk(kroot, tbs(rs, name('Root'), name('revoked.example'), P(kr), [san('revoked.example')]))
    w('rleaf', rleaf)
    okleaf = mk(kroot, tbs(ser(), name('Root'), name('ok.example'), P(kr), [san('ok.example')]))
    w('okleaf', okleaf)
    fresh = crl(kroot, name('Root'), [rs], NOW - D, NOW + D)
    stale = crl(kroot, name('Root'), [rs], NOW - 10 * D, NOW - D)
    idp = crl(kroot, name('Root'), [rs], NOW - D, NOW + D, [ext(IDP, seq(ctx(1, b'\xff', False)), True)])
    w('crl-fresh', fresh); w('crl-stale', stale); w('crl-idp', idp)
    case('crl-roots-revoked', 'REJECT', ['rleaf'], crls=('crl-fresh',), why='revoked')
    case('crl-roots-revoked-stale', 'REJECT', ['rleaf'], crls=('crl-stale',), why='revoked')
    case('crl-roots-not-revoked-stale', 'ACCEPT', ['okleaf'], crls=('crl-stale',))
    case('crl-roots-critical-idp', 'REJECT', ['okleaf'], crls=('crl-idp',), why='unrecognized critical extension')
    storedir('s-roots', {'root.der': root})
    storedir('s-none', {})
    storedir('s-fresh', {'root.der': fresh})
    storedir('s-stale', {'stale.der': stale})
    storedir('s-idp', {'idp.der': idp})
    storedir('s-garbage', {'junk.der': b'this is not a CRL'})
    storecase('crl-store-none', 'ACCEPT', ['rleaf'], 's-roots', 's-none')
    storecase('crl-store-revoked', 'REJECT', ['rleaf'], 's-roots', 's-fresh', 'revoked')
    storecase('crl-store-revoked-stale', 'REJECT', ['rleaf'], 's-roots', 's-stale', 'revoked')
    storecase('crl-store-not-revoked-stale', 'ACCEPT', ['okleaf'], 's-roots', 's-stale')
    storecase('crl-store-critical-idp', 'REJECT', ['rleaf'], 's-roots', 's-idp', 'idp.der')
    storecase('crl-store-critical-idp-other-cert', 'REJECT', ['okleaf'], 's-roots', 's-idp', 'idp.der')
    storecase('crl-store-garbage', 'REJECT', ['okleaf'], 's-roots', 's-garbage', 'junk.der')

    # ---- 6. a trust anchor outside its own dates
    w('root-expired', mk(kroot, tbs(1, name('Root'), name('Root'), P(kroot), CAEXT, nb=NOW - 100 * D, na=NOW - 1)))
    w('root-notyet', mk(kroot, tbs(1, name('Root'), name('Root'), P(kroot), CAEXT, nb=NOW + D, na=NOW + 100 * D)))
    case('anchor-expired', 'REJECT', ['leaf', 'inter'], roots=('root-expired',), why='trust anchor')
    case('anchor-not-yet-valid', 'REJECT', ['leaf', 'inter'], roots=('root-notyet',), why='trust anchor')
    storedir('s-rootexp', {'root.der': mk(kroot, tbs(1, name('Root'), name('Root'), P(kroot), CAEXT, nb=NOW - 100 * D, na=NOW - 1))})
    storecase('anchor-expired-store', 'REJECT', ['okleaf'], 's-rootexp', 's-none', 'trust anchor')

    with open(OUT + '/cases', 'w') as fd:
        fd.write('\n'.join(cases) + '\n')
    with open(OUT + '/expect', 'w') as fd:
        fd.write('\n'.join(expect) + '\n')

    # ---- handshakes
    T = OUT + '/tls'
    def pem(d): return b'-----BEGIN CERTIFICATE-----\n' + base64.encodebytes(d) + b'-----END CERTIFICATE-----\n'
    def keypem(k): return k.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption())
    def tw(fn, b):
        with open(T + '/' + fn, 'wb') as fd:
            fd.write(b)
    os.makedirs(T + '/roots', exist_ok=True)
    tw('roots/root.der', root)
    tw('leaf.key', keypem(kleaf))
    tw('rsa.key', keypem(krsa))
    tls = []
    def served(label, want, why, exts, cn='leaf.example', ask='leaf.example', chain=None, key=None, issuer=('Root', kroot), subject=None):
        """a certificate openssl s_server serves in a whole handshake"""
        c = mk(issuer[1], tbs(ser(), name(issuer[0]), subject or name(cn), P(key or kleaf), exts))
        tw(label + '.pem', pem(c))
        if chain:
            tw(label + '.chain.pem', b''.join(pem(x) for x in chain))
        tls.append('%s server %s %s %s' % (label, ask, want, why))
    served('tls-good', 'OK', '-', [san('leaf.example'), ku([0]), eku(SERVERAUTH)])
    served('tls-no-eku', 'OK', '-', [san('leaf.example')])
    served('tls-eku-any', 'OK', '-', [san('leaf.example'), eku(ANYEKU)])
    served('tls-eku-server-and-client', 'OK', '-', [san('leaf.example'), eku(CLIENTAUTH, SERVERAUTH)])
    served('tls-eku-clientauth-only', 'FAIL', 'extended key usage', [san('leaf.example'), eku(CLIENTAUTH)])
    served('tls-eku-email-cn-only', 'FAIL', 'extended key usage', [eku(EMAILPROT)])
    served('tls-ku-certsign-only', 'FAIL', 'digitalSignature', [san('leaf.example'), ku([5])])
    served('tls-unknown-critical', 'FAIL', 'unrecognized critical extension', [san('leaf.example'), ext(UNKNOWN, octet(b'x'), True)])
    served('tls-san-othername-beside-dns', 'OK', '-', [ext(SAN, seq(ctx(0, oid('1.3.6.1.4.1.311.20.2.3') + ctx(0, utf8('u@x'))), gdns('leaf.example')))])
    kc = eckey()
    cons = mk(kroot, tbs(ser(), name('Root'), name('Constrained'), P(kc), PERMIT_CORP))
    served('tls-nc-outside', 'FAIL', 'not in a permitted subtree', [san('leaf.example')], chain=[cons], issuer=('Constrained', kc))
    served('tls-nc-inside', 'OK', '-', [san('a.corp.example')], cn='a.corp.example', ask='a.corp.example', chain=[cons], issuer=('Constrained', kc))

    def scripted(label, want, why, files, mode, ask='leaf.example'):
        """certificates a scripted TLS 1.2 server sends: mode is what it does after them"""
        for i, b in enumerate(files):
            tw('%s.%d.der' % (label, i), b)
        tls.append('%s %s %s %s %s' % (label, mode, ask, want, why))
    for lab in ('tbs-empty-seq', 'ext-empty-seq', 'len-wrap-octets', 'len-wrap-bits', 'outer-tbs-len-7fffffff'):
        scripted('tls-mal-' + lab, 'FAIL', '-', [open(OUT + '/mal-' + lab + '.der', 'rb').read()], 'ecdsa')
    # a leaf whose RSA key has modulus 0, and a one-byte RSA-PSS signature on the key exchange
    mod0 = mk(kroot, tbs(ser(), name('Root'), name('leaf.example'), rsaspki(0, 65537), [san('leaf.example')]))
    scripted('tls-rsa-modulus-0-pss', 'FAIL', '-', [mod0], 'pss1')
    # RSA key exchange and the leaf's keyUsage
    rsaleaf = lambda exts: mk(kroot, tbs(ser(), name('Root'), name('leaf.example'), P(krsa), exts))
    scripted('tls-rsakex-ku-signature-only', 'FAIL', 'keyEncipherment', [rsaleaf([san('leaf.example'), ku([0])])], 'rsakex')
    scripted('tls-rsakex-ku-encipherment', 'CONTINUES', '-', [rsaleaf([san('leaf.example'), ku([2])])], 'rsakex')
    scripted('tls-ecdhe-good', 'CONTINUES', '-', [mk(kroot, tbs(ser(), name('Root'), name('leaf.example'), P(kleaf), [san('leaf.example'), ku([0])]))], 'ecdsa')
    with open(T + '/cases', 'w') as fd:
        fd.write('\n'.join(tls) + '\n')

if len(sys.argv) == 3 and sys.argv[1] == '-f':
    fixtures(sys.argv[2])
elif len(sys.argv) == 3:
    OUT, INEMU = sys.argv[1], sys.argv[2]
    chains()
else:
    sys.exit('usage: gen.py OUT INEMU | gen.py -f DIR')
