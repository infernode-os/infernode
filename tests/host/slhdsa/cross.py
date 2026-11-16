#!/usr/bin/env python3
# libsec's SLH-DSA against OpenSSL's, live: random keys and messages, each
# way.  Run by tests/host/slhdsa_test.sh where OpenSSL's SLH-DSA can be
# reached (ossl.py); exit 77 where it cannot.
#   cross.py SLHTEST [ROUNDS]
import sys, os, subprocess, random
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ossl

why = ossl.available()
if why is not None:
	print("SKIP: OpenSSL's SLH-DSA cannot be reached (%s)" % why)
	sys.exit(77)
rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 3
proc = subprocess.Popen([sys.argv[1], "cli"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def cmd(*a, lines=1):
	proc.stdin.write(" ".join(a) + "\n"); proc.stdin.flush()
	d = {}
	for i in range(lines):
		l = proc.stdout.readline()
		if not l:
			print("FAIL: slhtest cli ended"); sys.exit(1)
		k, v = l.rstrip("\n").split(" ", 1); d[k] = v
	return d
hx = lambda b: b.hex() or "-"
fails = 0
def check(ok, what):
	global fails
	if not ok:
		fails += 1
		print("FAIL: " + what)
rnd = random.Random(int.from_bytes(os.urandom(4), "big"))
for p, n, alg in ((192, 24, "SLH-DSA-SHAKE-192s"), (256, 32, "SLH-DSA-SHAKE-256s")):
	for i in range(rounds):
		seed = os.urandom(3 * n)
		msg = os.urandom(rnd.choice((0, 1, 32, 48, 64, 200, 2000)))
		opk, osk = ossl.keygen(alg, seed)
		r = cmd("keygen", str(p), seed.hex(), lines=3)
		check(r["rc"] == "0" and bytes.fromhex(r["pk"]) == opk and bytes.fromhex(r["sk"]) == osk, alg + ": key from a seed differs from OpenSSL's")
		osig = ossl.sign(alg, osk, msg)
		r = cmd("sign", str(p), osk.hex(), hx(msg), lines=2)
		lsig = bytes.fromhex(r["sig"])
		check(r["rc"] == "0" and lsig == osig, alg + ": signature differs from OpenSSL's (deterministic, pure, empty context)")
		check(ossl.verify(alg, opk, msg, lsig), alg + ": OpenSSL refuses libsec's signature")
		check(cmd("verify", str(p), opk.hex(), hx(msg), osig.hex())["ok"] == "1", alg + ": libsec refuses OpenSSL's signature")
		csig = ossl.sign(alg, osk, msg, b"a context")
		check(cmd("verify", str(p), opk.hex(), hx(msg), csig.hex())["ok"] == "0", alg + ": libsec accepts a signature made with a context string")
		bad = bytearray(osig); bad[rnd.randrange(len(bad))] ^= 1 << rnd.randrange(8)
		check(cmd("verify", str(p), opk.hex(), hx(msg), bytes(bad).hex())["ok"] == "0", alg + ": a changed signature accepted")
proc.stdin.close(); proc.wait()
if fails:
	sys.exit(1)
print("%d key%s and signature%s of each set equal OpenSSL's, each verifying the other's" % (rounds, "s"[:rounds != 1], "s"[:rounds != 1]))
