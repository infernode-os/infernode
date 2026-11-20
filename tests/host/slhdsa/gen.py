#!/usr/bin/env python3
# Makes tests/host/slhdsa/vectors.txt, the known answers slhtest.c holds
# libsec/slhdsa*.c to.  Run: python3 gen.py > vectors.txt  (a few minutes)
#
# Two sources, which must agree byte for byte or nothing is written:
#   slh_ref.py   FIPS 205 written out in Python
#   ossl.py      OpenSSL's SLH-DSA (the one inside Python's cryptography
#                package), where it can be reached; the header of the
#                file says whether it was
# slhdsa192s_sign and slhdsa256s_sign make the standard's pure signature
# with an empty context string, hedged: opt_rand is n random bytes.  The
# kat lines are of the deterministic variant (opt_rand = PK.seed), which
# the library makes through slhdsa_sign_internal on M'; the hkat lines
# give the randomness.
#
# Lines:
#   kat SET SEED PK SK MSG SIGSUM
#       key generation from SEED = SK.seed || SK.prf || PK.seed gives PK
#       and SK; the deterministic signature of MSG has SHAKE256-256
#       digest SIGSUM
#   hkat SET SK MSG CTX ADDRND SIGSUM
#       the signature of MSG under the context string CTX with ADDRND as
#       opt_rand has digest SIGSUM
#   sig SET EXPECT WHAT PK MSG SIG
#       verifying SIG on MSG under PK gives EXPECT (1 accepted, 0 refused)
# MSG is hex, "-" for the empty message.
import sys, os, hashlib, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import slh_ref, ossl
from slh_ref import SLH, P192, P256, slh_sign, slh_verify

SETS = ((192, P192, "SLH-DSA-SHAKE-192s"), (256, P256, "SLH-DSA-SHAKE-256s"))
have = ossl.available() is None
rnd = random.Random(205)
hx = lambda b: b.hex() or "-"
shake = lambda b: hashlib.shake_256(b).hexdigest(32)
out = []

def die(s):
	sys.stderr.write("gen.py: " + s + "\n")
	sys.exit(1)

for name, par, alg in SETS:
	n = par.n
	# by the reference, checked against OpenSSL: the empty message and
	# a digest-sized one (what Keyring signs)
	msgs = [b"", rnd.randbytes(32)]
	if not have:
		msgs.append(rnd.randbytes(300))
	for i, msg in enumerate(msgs):
		seed = rnd.randbytes(3 * n)
		pk, sk = SLH(par).keygen(seed[:n], seed[n:2*n], seed[2*n:])
		sig = slh_sign(par, msg, sk)
		if not slh_verify(par, msg, sig, pk):
			die("the reference does not verify its own signature")
		if have:
			if ossl.keygen(alg, seed) != (pk, sk):
				die("%s: OpenSSL's key differs from the reference's" % alg)
			if ossl.sign(alg, sk, msg) != sig:
				die("%s: OpenSSL's signature differs from the reference's" % alg)
			if not ossl.verify(alg, pk, msg, sig):
				die("%s: OpenSSL refuses the reference's signature" % alg)
		out.append("kat %d %s %s %s %s %s" % (name, seed.hex(), pk.hex(), sk.hex(), hx(msg), shake(sig)))
		sys.stderr.write("%s kat %d\n" % (alg, i))
		if i == 1:
			# the whole signature, to be verified
			out.append("sig %d 1 fips %s %s %s" % (name, pk.hex(), hx(msg), sig.hex()))
			# what libsec made before: three differences from the
			# standard, over the message as it came.  Refused now.
			old = SLH(par, 'old', 'old', 'old').sign(msg, sk)
			if SLH(par).verify(msg, old, pk) or slh_verify(par, msg, old, pk):
				die("the old format verifies under FIPS 205")
			out.append("sig %d 0 old-format %s %s %s" % (name, pk.hex(), hx(msg), old.hex()))
			if name == 192:
				# FIPS 205 signatures, but not pure ones with an
				# empty context: the internal interface on the
				# bare message, and a context string
				s = SLH(par).sign(msg, sk)
				out.append("sig %d 0 internal-interface %s %s %s" % (name, pk.hex(), hx(msg), s.hex()))
				s = slh_sign(par, msg, sk, b"ctx")
				if have and not ossl.verify(alg, pk, msg, s, b"ctx"):
					die("OpenSSL refuses the reference's signature with a context")
				out.append("sig %d 0 context-string %s %s %s" % (name, pk.hex(), hx(msg), s.hex()))
	if have:
		# by OpenSSL alone (the reference takes seconds a signature,
		# and so does libsec: few vectors): a message past a SHAKE block
		seed = rnd.randbytes(3 * n)
		msg = rnd.randbytes(300)
		pk, sk = ossl.keygen(alg, seed)
		sig = ossl.sign(alg, sk, msg)
		out.append("kat %d %s %s %s %s %s" % (name, seed.hex(), pk.hex(), sk.hex(), hx(msg), shake(sig)))

# hedged, with and without a context string: the reference's, and
# OpenSSL's given the same randomness (test-entropy)
rnd2 = random.Random(2052)
for name, par, alg in SETS:
	n = par.n
	seed = rnd2.randbytes(3 * n)
	pk, sk = SLH(par).keygen(seed[:n], seed[n:2*n], seed[2*n:])
	for ctx in (b"", b"InferNode"):
		msg = rnd2.randbytes(32)
		addrnd = rnd2.randbytes(n)
		sig = slh_sign(par, msg, sk, ctx, addrnd)
		if not slh_verify(par, msg, sig, pk, ctx):
			die("the reference does not verify its own hedged signature")
		if have:
			if ossl.sign(alg, sk, msg, ctx, params=[(b"test-entropy", addrnd)]) != sig:
				die("%s: OpenSSL's hedged signature differs from the reference's" % alg)
		out.append("hkat %d %s %s %s %s %s" % (name, sk.hex(), hx(msg), hx(ctx), addrnd.hex(), shake(sig)))
		sys.stderr.write("%s hkat\n" % alg)

if len(sys.argv) > 1 and sys.argv[1] == "hkat":
	# the hkat lines alone, to add to a file made before there were any
	for l in out:
		if l.startswith("hkat "):
			print(l)
	sys.exit(0)

print("# SLH-DSA-SHAKE-192s and -256s known answers, made by tests/host/slhdsa/gen.py.")
print("# The first %d kat lines of each set and the sig lines are the FIPS 205" % (2 if have else 3))
print("# reference's (slh_ref.py)" + ("; its keys and pure signatures were equal byte for byte to" if have else "."))
if have:
	from cryptography.hazmat.backends.openssl.backend import backend
	print("# OpenSSL's, and the last kat line of each set is OpenSSL's alone (%s)." % backend.openssl_version_text())
else:
	print("# OpenSSL's SLH-DSA could not be reached when this was made: the reference alone.")
print("#   kat SET SEED PK SK MSG SHAKE256-256(SIG)")
print("#   hkat SET SK MSG CTX ADDRND SHAKE256-256(SIG)")
print("#   sig SET EXPECT WHAT PK MSG SIG")
for l in out:
	print(l)
