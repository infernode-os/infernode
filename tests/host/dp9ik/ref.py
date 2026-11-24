#!/usr/bin/env python3
# A reference for 9front's dp9ik pieces, written from 9front's own source
# (libauthsrv: passtokey.c, authpak.c and the .mp files it is made from,
# form1.c, convT2M.c, convA2M.c; factotum's p9sk1.c establish()), and checked
# against the answers 9front itself gives (9front-vectors.txt, made by
# vecgen.c on 9front 11952).
#
#   ref.py check            the vectors, every field, against this reference
#   ref.py vectors FILE     known answers for the Limbo implementation
#
# Only Python's standard library and `cryptography` (ChaCha20-Poly1305).
import hashlib, hmac, os, sys

P = 2**448 - 2**224 - 1
A = 1
D = (-39081) % P
GX = 117812161263436946737282484343310064665180535357016373416879082147939404277809514858788439644911793978499419995990477371552926308078495
GY = 19
SLEN = 56			# PAKSLEN: an ed448 scalar or coordinate
PLEN = 4 * SLEN		# PAKPLEN: a point, X Y Z T

def inv(x): return pow(x % P, P - 2, P)

def legendre(a):
	r = pow(a % P, (P - 1) >> 1, P)
	return -1 if r == P - 1 else r

def msqrt(a):
	a %= P
	if legendre(a) != 1 or a == 0:
		return 0
	return pow(a, (P + 1) >> 2, P)	# p % 4 == 3

def misqrt(a):
	return pow(a % P, (P - 3) >> 2, P)

def nonsquare():
	n = 2
	while legendre(n) != -1:
		n += 1
	return n

def ed_add(p1, p2):
	X1, Y1, Z1, T1 = p1; X2, Y2, Z2, T2 = p2
	a = X1 * X2 % P
	b = Y1 * Y2 % P
	c = D * T1 % P * T2 % P
	d = Z1 * Z2 % P
	e = ((X1 + Y1) * (X2 + Y2) - a - b) % P
	f = (d - c) % P
	g = (d + c) % P
	h = (b - A * a) % P
	return (e * f % P, g * h % P, f * g % P, e * h % P)

def ed_scale(s, pt):
	# as edwards.mp: right to left over as many bits as p has, the point
	# doubled each step and the sum chosen by the scalar's bit
	q2 = pt
	q3 = pt if s % 2 else (0, 1, 1, 0)
	k = s >> 1
	j = P >> 1
	while j != 0:
		q2 = ed_add(q2, q2)
		q4 = ed_add(q2, q3)
		q3 = q4 if k % 2 else q3
		k >>= 1; j >>= 1
	return q3

def decaf_neg(n, r):
	return (-r) % P if n % P > (P - 1) >> 1 else r

def decaf_encode(pt):
	X, Y, Z, T = pt
	r = misqrt((A - D) * (Z + Y) % P * (Z - Y) % P)
	u = (A - D) * r % P
	r = decaf_neg(-2 * u * Z % P, r)
	s = u * ((r * ((A * Z * X - D * Y * T) % P) + Y) % P) % P * inv(A) % P
	return decaf_neg(s, s)

def decaf_decode(s):
	if s > (P - 1) >> 1:
		return None
	ss = s * s % P
	Z = (1 + A * ss) % P
	u = (Z * Z - 4 * D * ss) % P
	v = u * ss % P
	if v != 0:
		ok = msqrt(v)
		if ok == 0:
			return None
		v = inv(ok)
	v = decaf_neg(u * v % P, v)
	w = v * s % P * ((2 - Z) % P) % P
	if s == 0:
		w = (w + 1) % P
	X = 2 * s % P
	return (X, w * Z % P, Z, w * X % P)

def elligator2(n, r0):
	r = n * r0 % P * r0 % P
	Dd = ((D * r + A - D) % P) * ((D * r - A * r - D) % P) % P
	N = (r + 1) * ((A - 2 * D) % P) % P
	ND = N * Dd % P
	if ND == 0:
		c, e = 1, 0
	else:
		e = msqrt(ND)
		if e != 0:
			c, e = 1, inv(e)
		else:
			c, e = -1, n * r0 % P * misqrt(n * ND) % P
	s = c * N * e % P
	t = (-c * N * ((r - 1) % P) % P * pow((A - 2 * D) * e % P, 2, P) - 1) % P
	ass = A * s * s % P
	return (2 * s * t % P, (1 - ass) * (1 + ass) % P, (1 + ass) * t % P, 2 * s * (1 - ass) % P)

def hkdf(salt, info, ikm, n):
	prk = hmac.new(salt, ikm, hashlib.sha256).digest()
	out, t, i = b"", b"", 1
	while len(out) < n:
		t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
		out += t; i += 1
	return out[:n]

def be(x, n): return (x % (1 << (8 * n))).to_bytes(n, "big")
def bint(b): return int.from_bytes(b, "big")

def passtoaeskey(pw):
	return hashlib.pbkdf2_hmac("sha1", pw.encode(), b"Plan 9 key derivation", 9001, 16)

def authpak_hash(aes, user):
	salt = hashlib.sha256(user.encode()).digest()
	h = hkdf(salt, b"Plan 9 AuthPAK hash", aes, 2 * SLEN)
	n = nonsquare()
	out = b""
	for part in (h[:SLEN], h[SLEN:]):
		pt = elligator2(n, bint(part) % P)
		out += b"".join(be(c, SLEN) for c in pt)
	return out

def point(b): return tuple(bint(b[i*SLEN:(i+1)*SLEN]) for i in range(4))

def authpak_y(pakhash, x, isclient):
	pm = point(pakhash[0 if isclient else PLEN:][:PLEN])
	g = (GX, GY, 1, GX * GY % P)
	return be(decaf_encode(ed_add(ed_scale(x, g), pm)), SLEN)

def authpak_finish(pakhash, x, ymine, ytheirs, isclient):
	pn = point(pakhash[PLEN if isclient else 0:][:PLEN])
	q = decaf_decode(bint(ytheirs))
	if q is None:
		return None
	q = ed_add(q, ((-pn[0]) % P, pn[1], pn[2], (-pn[3]) % P))
	z = be(decaf_encode(ed_scale(x, q)), SLEN)
	first, second = (ymine, ytheirs) if isclient else (ytheirs, ymine)
	salt = hashlib.sha256(first + second).digest()
	return hkdf(salt, b"Plan 9 AuthPAK key", z, 32)

FORM1 = {3: b"form1 PR", 64: b"form1 Ts", 65: b"form1 Tc", 66: b"form1 As", 67: b"form1 Ac", 68: b"form1 Tp", 69: b"form1 Hr"}

def form1_seal(num, body, key, counter):
	from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
	nonce = FORM1[num] + counter.to_bytes(4, "little")
	return nonce + ChaCha20Poly1305(key).encrypt(nonce, body, None)

def session_secret(rand, tkey):
	return hkdf(rand, b"Plan 9 session secret", tkey, 256)

def readvectors(path):
	cases, cur = [], None
	for ln in open(path):
		ln = ln.rstrip("\n")
		if not ln or ln.startswith("@@"):
			continue
		k, _, v = ln.partition(" ")
		if k == "case":
			cur = {}; cases.append(cur)
		cur[k] = v
	return cases

def check(path):
	bad = 0
	def eq(what, got, want):
		nonlocal bad
		ok = got == want
		print(("ok " if ok else "FAIL ") + what)
		bad += not ok
	counter = 0
	for c in readvectors(path):
		u, pw = c["user"], c["password"]
		aes = passtoaeskey(pw)
		eq(f"{u}: aes key (PBKDF2-HMAC-SHA1, 9001)", aes.hex(), c["aes"])
		ph = authpak_hash(aes, u)
		eq(f"{u}: pakhash (HKDF, Elligator2 on Ed448)", ph.hex(), c["pakhash"])
		xc, xs = bint(bytes.fromhex(c["xc"])), bint(bytes.fromhex(c["xs"]))
		yc, ys = authpak_y(ph, xc, 1), authpak_y(ph, xs, 0)
		eq(f"{u}: client public key", yc.hex(), c["yc"])
		eq(f"{u}: server public key", ys.hex(), c["ys"])
		kc = authpak_finish(ph, xc, yc, ys, 1)
		ks = authpak_finish(ph, xs, ys, yc, 0)
		eq(f"{u}: client pakkey", kc.hex(), c["pakkeyc"])
		eq(f"{u}: server pakkey", ks.hex(), c["pakkeys"])
		body = bytes([65]) + b"c" * 8 + u.encode().ljust(28, b"\0") + u.encode().ljust(28, b"\0") + b"\x5a" * 32
		eq(f"{u}: form1 ticket", form1_seal(65, body[1:], kc, counter).hex(), c["ticket"]); counter += 1
		abody = b"c" * 8 + b"\x33" * 32
		eq(f"{u}: form1 authenticator", form1_seal(67, abody, b"\x5a" * 32, counter).hex(), c["authenticator"]); counter += 1
	print("PASS" if bad == 0 else f"FAIL: {bad}")
	return bad

if __name__ == "__main__":
	if sys.argv[1:2] == ["check"]:
		sys.exit(1 if check(sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(__file__), "9front-vectors.txt")) else 0)
	print(__doc__ if False else "usage: ref.py check [vectors]")
