#!/usr/bin/env python3
# NIST's ACVP vectors for FIPS 203, 204 and 205, as lines acvptest.c reads.
#
#	python3 -I reduce.py DIR		every case of the groups run
#	python3 -I reduce.py -k DIR		the cases kept in vectors.txt.gz
#
# DIR holds NIST's files as they are published, one directory an
# algorithm and mode, each with its internalProjection.json:
#	github.com/usnistgov/ACVP-Server, gen-val/json-files/
#	ML-KEM-keyGen-FIPS203	ML-KEM-encapDecap-FIPS203
#	ML-DSA-keyGen-FIPS204	ML-DSA-sigGen-FIPS204	ML-DSA-sigVer-FIPS204
#	SLH-DSA-keyGen-FIPS205	SLH-DSA-sigGen-FIPS205	SLH-DSA-sigVer-FIPS205
# They are data: this script reads them as JSON and nothing else (run it
# with -I from outside DIR).  The files are tens of megabytes, so the
# tree keeps a part:
#	python3 -I reduce.py -k -d 2026-11-16 DIR | gzip -9n > vectors.txt.gz
#
# The groups run are those of the parameter sets libsec has (ML-KEM-768
# and -1024, ML-DSA-65 and -87, SLH-DSA-SHAKE-192s and -256s) and the
# interfaces it has: key generation from the seeds; the external
# interface, pure, with a context string, deterministic and hedged; the
# internal interface, with the message or (ML-DSA) with mu given; ML-KEM
# encapsulation with m given, decapsulation and the two key checks.  A
# group not run is listed on standard error with the reason: the
# pre-hash signatures (HashML-DSA, HashSLH-DSA), which libsec does not
# offer, and the other parameter sets.
#
# A value the library must make and nobody reads back (a signature made,
# a key generated, a ciphertext) is given as its SHAKE256-256: "sum".
#
# -k keeps, of each group: every key generation; ten ML-KEM
# encapsulations, and of decapsulation and the key checks two cases for
# each reason NIST gives; of signing, the two cases with the shortest
# messages and the one with the longest context string (SLH-DSA: the
# shortest and the longest context); of verifying, the case with the
# shortest message for each reason NIST gives (valid, modified message,
# each modified part of the signature, too long, too short) in the
# external interface's groups, and for fewer in the others, whose
# signatures are as long and say no more: ML-DSA's internal groups keep
# valid and modified message, SLH-DSA-192s's internal group and
# SLH-DSA-256s's external group valid and modified message, and
# SLH-DSA-256s's internal group valid (a signature is 30K).
#
# Lines:	KIND tg=N tc=N set=N name=hex ... [reason=words-with-dashes]
import sys, os, json, hashlib

keep = False
when = None
args = sys.argv[1:]
while args and args[0].startswith("-"):
	if args[0] == "-k":
		keep = True
		args = args[1:]
	elif args[0] == "-d" and len(args) > 1:
		when = args[1]		# the day the files were fetched, for the header
		args = args[2:]
	else:
		break
if len(args) != 1:
	sys.exit("usage: reduce.py [-k] [-d date] DIR")
DIR = args[0]

SETS = {"ML-KEM-768": 768, "ML-KEM-1024": 1024, "ML-DSA-65": 65, "ML-DSA-87": 87,
	"SLH-DSA-SHAKE-192s": 192, "SLH-DSA-SHAKE-256s": 256}
hx = lambda s: s.lower() if s else "-"
shake = lambda s: hashlib.shake_256(bytes.fromhex(s)).hexdigest(32)
skipped = {}
nout = 0

FILES = ["ML-KEM-keyGen-FIPS203", "ML-KEM-encapDecap-FIPS203",
	"ML-DSA-keyGen-FIPS204", "ML-DSA-sigGen-FIPS204", "ML-DSA-sigVer-FIPS204",
	"SLH-DSA-keyGen-FIPS205", "SLH-DSA-sigGen-FIPS205", "SLH-DSA-sigVer-FIPS205"]

def load(name):
	with open(os.path.join(DIR, name, "internalProjection.json")) as f:
		return json.load(f)

# where the cases are from: NIST's repository records no version in the
# files, so each file's SHA-256 says which it was
print("# NIST ACVP vectors (github.com/usnistgov/ACVP-Server, gen-val/json-files)" + (", fetched %s," % when if when else ","))
print("# as lines for tests/host/acvp/acvptest.c, made by tests/host/acvp/reduce.py" + (" -k: a part of each group." if keep else ": every case of the groups run."))
for name in FILES:
	with open(os.path.join(DIR, name, "internalProjection.json"), "rb") as f:
		print("#   %s  %s/internalProjection.json" % (hashlib.sha256(f.read()).hexdigest(), name))

def skip(name, g, why):
	k = (name, why)
	skipped.setdefault(k, []).append(str(g["tgId"]))

def out(kind, g, t, **kw):
	global nout
	nout += 1
	f = ["%s tg=%s tc=%s set=%d" % (kind, g["tgId"], t["tcId"], SETS[g["parameterSet"]])]
	for k, v in kw.items():
		f.append("%s=%s" % (k, v))
	print(" ".join(f))

def groups(name):
	j = load(name)
	for g in j["testGroups"]:
		if g.get("parameterSet") not in SETS:
			skip(name, g, "a parameter set libsec does not have (%s)" % g.get("parameterSet"))
			continue
		if g.get("preHash") == "preHash":
			skip(name, g, "pre-hash signatures (HashML-DSA, HashSLH-DSA): libsec has no entry point for them")
			continue
		yield g

def shortest(tests, n, key="message"):
	return sorted(tests, key=lambda t: (len(t.get(key, "")), t["tcId"]))[:n]

def longctx(tests):
	return max(tests, key=lambda t: (len(t.get("context", "")), -t["tcId"]))

def pick(tests, *lists):
	if not keep:
		return tests
	ids = []
	for l in lists:
		for t in l:
			if t["tcId"] not in ids:
				ids.append(t["tcId"])
	return [t for t in tests if t["tcId"] in ids]

def byreason(tests, only=None, n=1):
	seen = {}
	for t in sorted(tests, key=lambda t: (len(t.get("message", "")), t["tcId"])):
		r = t.get("reason", "")
		if only is not None and not any(r.startswith(o) for o in only):
			continue
		if len(seen.setdefault(r, [])) < n:
			seen[r].append(t)
	return [t for l in seen.values() for t in l]

BRIEF = ["valid", "modified message"]

reason = lambda t: (t.get("reason") or "none").replace(" ", "-")
flag = lambda b: "1" if b else "0"

# ---- ML-KEM (FIPS 203) ----
for g in groups("ML-KEM-keyGen-FIPS203"):
	for t in g["tests"]:
		out("mlkem-keygen", g, t, d=hx(t["d"]), z=hx(t["z"]), eksum=shake(t["ek"]), dksum=shake(t["dk"]))
for g in groups("ML-KEM-encapDecap-FIPS203"):
	fn = g["function"]
	ts = g["tests"]
	ts = pick(ts, ts[:10] if fn == "encapsulation" else byreason(ts, None, 2))
	for t in ts:
		if fn == "encapsulation":
			out("mlkem-encap", g, t, ek=hx(t["ek"]), m=hx(t["m"]), csum=shake(t["c"]), k=hx(t["k"]))
		elif fn == "decapsulation":
			out("mlkem-decap", g, t, dk=hx(t["dk"]), c=hx(t["c"]), k=hx(t["k"]), reason=reason(t))
		elif fn == "encapsulationKeyCheck":
			out("mlkem-ekcheck", g, t, ek=hx(t["ek"]), **{"pass": flag(t["testPassed"])}, reason=reason(t))
		elif fn == "decapsulationKeyCheck":
			out("mlkem-dkcheck", g, t, dk=hx(t["dk"]), **{"pass": flag(t["testPassed"])}, reason=reason(t))
		else:
			skip("ML-KEM-encapDecap-FIPS203", g, "an unknown function (%s)" % fn)
			break

# ---- ML-DSA (FIPS 204) ----
for g in groups("ML-DSA-keyGen-FIPS204"):
	for t in g["tests"]:
		out("mldsa-keygen", g, t, seed=hx(t["seed"]), pksum=shake(t["pk"]), sksum=shake(t["sk"]))
for g in groups("ML-DSA-sigGen-FIPS204"):
	ext = g["signatureInterface"] == "external"
	mu = bool(g.get("externalMu"))
	ts = g["tests"]
	ts = pick(ts, shortest(ts, 2, "mu" if mu else "message"), [longctx(ts)] if ext else [])
	for t in ts:
		# deterministic: rnd is 32 zero bytes (FIPS 204 Algorithm 2 line 5's other variant)
		rnd = "00"*32 if g["deterministic"] else t["rnd"]
		out("mldsa-siggen", g, t, iface="ext" if ext else "int", sk=hx(t["sk"]),
			msg=hx(t.get("mu") if mu else t.get("message")), ismu=flag(mu),
			ctx=hx(t.get("context", "")) if ext else "-", rnd=hx(rnd), sigsum=shake(t["signature"]))
for g in groups("ML-DSA-sigVer-FIPS204"):
	ext = g["signatureInterface"] == "external"
	mu = bool(g.get("externalMu"))
	ts = pick(g["tests"], byreason(g["tests"], None if ext else BRIEF))
	for t in ts:
		out("mldsa-sigver", g, t, iface="ext" if ext else "int", pk=hx(t["pk"]),
			msg=hx(t.get("mu") if mu else t.get("message")), ismu=flag(mu),
			ctx=hx(t.get("context", "")) if ext else "-", sig=hx(t["signature"]),
			**{"pass": flag(t["testPassed"])}, reason=reason(t))

# ---- SLH-DSA (FIPS 205) ----
for g in groups("SLH-DSA-keyGen-FIPS205"):
	for t in g["tests"]:
		out("slh-keygen", g, t, skseed=hx(t["skSeed"]), skprf=hx(t["skPrf"]), pkseed=hx(t["pkSeed"]),
			pk=hx(t["pk"]), sk=hx(t["sk"]))
for g in groups("SLH-DSA-sigGen-FIPS205"):
	ext = g["signatureInterface"] == "external"
	ts = g["tests"]
	ts = pick(ts, shortest(ts, 1), [longctx(ts)] if ext else shortest(ts, 2))
	for t in ts:
		# deterministic: opt_rand is PK.seed (FIPS 205 Algorithm 19 line 2); "-" says so
		out("slh-siggen", g, t, iface="ext" if ext else "int", sk=hx(t["sk"]), msg=hx(t["message"]),
			ctx=hx(t.get("context", "")) if ext else "-",
			addrnd="-" if g["deterministic"] else hx(t["additionalRandomness"]), sigsum=shake(t["signature"]))
for g in groups("SLH-DSA-sigVer-FIPS205"):
	ext = g["signatureInterface"] == "external"
	only = None
	if g["parameterSet"] == "SLH-DSA-SHAKE-256s":
		only = BRIEF if ext else ["valid"]
	elif not ext:
		only = BRIEF
	ts = pick(g["tests"], byreason(g["tests"], only))
	for t in ts:
		out("slh-sigver", g, t, iface="ext" if ext else "int", pk=hx(t["pk"]), msg=hx(t["message"]),
			ctx=hx(t.get("context", "")) if ext else "-", sig=hx(t["signature"]),
			**{"pass": flag(t["testPassed"])}, reason=reason(t))

for (name, why), ids in sorted(skipped.items()):
	sys.stderr.write("not run: %s groups %s: %s\n" % (name, ",".join(ids), why))
sys.stderr.write("%d cases\n" % nout)
