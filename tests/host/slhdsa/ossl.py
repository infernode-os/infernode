#!/usr/bin/env python3
# SLH-DSA from the OpenSSL that Python's `cryptography` package carries.
#
# cryptography (50) has no SLH-DSA in its API, but the OpenSSL (3.5 or
# later) linked into its extension module has the algorithm, and the
# module keeps its symbol table.  The EVP functions are local symbols, so
# they are found in the module's .symtab and called by address through
# ctypes.  Nothing here is a supported interface of either project: where
# any step fails, available() says why and the callers skip.
#
#   keygen(alg, seed)            seed = SK.seed || SK.prf || PK.seed -> (pk, sk)
#   sign(alg, sk, msg, ctx=b"")  pure SLH-DSA, deterministic (opt_rand = PK.seed)
#   verify(alg, pk, msg, sig, ctx=b"")
# alg is OpenSSL's name: "SLH-DSA-SHAKE-192s", "SLH-DSA-SHAKE-256s".
import ctypes, struct, os

_fn = {}
_why = None

def _symbols(path, want):
	"""addresses of the named symbols from an ELF64 file's .symtab"""
	out = {}
	with open(path, "rb") as f:
		eh = f.read(64)
		if eh[:4] != b"\x7fELF" or eh[4] != 2 or eh[5] != 1:
			raise OSError("not a little-endian ELF64 file")
		shoff, = struct.unpack_from("<Q", eh, 0x28)
		shentsize, shnum = struct.unpack_from("<HH", eh, 0x3a)
		f.seek(shoff)
		sh = [struct.unpack("<IIQQQQIIQQ", f.read(shentsize)[:64]) for i in range(shnum)]
		for s in sh:
			if s[1] != 2:		# SHT_SYMTAB
				continue
			f.seek(sh[s[6]][4]); strtab = f.read(sh[s[6]][5])
			f.seek(s[4]); data = f.read(s[5])
			for o in range(0, len(data), 24):
				name, info, other, shndx, value, size = struct.unpack_from("<IBBHQQ", data, o)
				if shndx == 0 or (info & 15) != 2:	# STT_FUNC
					continue
				e = strtab.find(b"\0", name)
				n = strtab[name:e].decode("latin1")
				if n in want:
					out[n] = value
	return out

def _init():
	global _why
	if _fn or _why:
		return
	try:
		from cryptography.hazmat.bindings import _rust
		path = _rust.__file__
		want = {
			"EVP_PKEY_CTX_new_from_name": (ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]),
			"EVP_PKEY_CTX_new_from_pkey": (ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p]),
			"EVP_PKEY_CTX_free": (None, [ctypes.c_void_p]),
			"EVP_PKEY_free": (None, [ctypes.c_void_p]),
			"EVP_PKEY_fromdata_init": (ctypes.c_int, [ctypes.c_void_p]),
			"EVP_PKEY_fromdata": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]),
			"EVP_PKEY_keygen_init": (ctypes.c_int, [ctypes.c_void_p]),
			"EVP_PKEY_CTX_set_params": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p]),
			"EVP_PKEY_generate": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p]),
			"EVP_PKEY_get_octet_string_param": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p]),
			"EVP_MD_CTX_new": (ctypes.c_void_p, []),
			"EVP_MD_CTX_free": (None, [ctypes.c_void_p]),
			"EVP_DigestSignInit_ex": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]),
			"EVP_DigestSign": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t]),
			"EVP_DigestVerifyInit_ex": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]),
			"EVP_DigestVerify": (ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t]),
		}
		sym = _symbols(path, want)
		miss = [n for n in want if n not in sym]
		if miss:
			raise OSError("no symbol %s in %s" % (miss[0], os.path.basename(path)))
		base = None
		real = os.path.realpath(path)
		with open("/proc/self/maps") as f:
			for l in f:
				p = l.split()
				if len(p) >= 6 and os.path.realpath(p[5]) == real and int(p[2], 16) == 0:
					base = int(p[0].split("-")[0], 16)
					break
		if base is None:
			raise OSError("cannot find where %s is loaded" % os.path.basename(path))
		for n, (res, args) in want.items():
			_fn[n] = ctypes.CFUNCTYPE(res, *args)(base + sym[n])
		# is the algorithm there?
		c = _fn["EVP_PKEY_CTX_new_from_name"](None, b"SLH-DSA-SHAKE-192s", None)
		if not c:
			_fn.clear()
			raise OSError("this OpenSSL has no SLH-DSA")
		_fn["EVP_PKEY_CTX_free"](c)
	except Exception as e:
		_why = "%s: %s" % (type(e).__name__, e)

def available():
	"""None if OpenSSL's SLH-DSA can be called, else the reason"""
	_init()
	return _why

# OSSL_PARAM { const char *key; unsigned data_type; void *data; size_t data_size; size_t return_size; }
class _Param(ctypes.Structure):
	_fields_ = [("key", ctypes.c_char_p), ("type", ctypes.c_uint), ("data", ctypes.c_void_p),
		("size", ctypes.c_size_t), ("ret", ctypes.c_size_t)]
_INT, _OCTET = 1, 5
_UNMOD = ctypes.c_size_t(-1).value

def _params(items):
	keep = []
	a = (_Param * (len(items) + 1))()
	for i, (k, v) in enumerate(items):
		if isinstance(v, int):
			b = ctypes.c_int(v); keep.append(b)
			a[i] = _Param(k, _INT, ctypes.cast(ctypes.pointer(b), ctypes.c_void_p), ctypes.sizeof(b), _UNMOD)
		else:
			b = ctypes.create_string_buffer(bytes(v), max(len(v), 1)); keep.append(b)
			a[i] = _Param(k, _OCTET, ctypes.cast(b, ctypes.c_void_p), len(v), _UNMOD)
	a[len(items)] = _Param(None, 0, None, 0, 0)
	return a, keep

def _need(ok, what):
	if not ok:
		raise RuntimeError("OpenSSL: %s failed" % what)

def _getoctets(pkey, name, n):
	buf = ctypes.create_string_buffer(n)
	got = ctypes.c_size_t(0)
	_need(_fn["EVP_PKEY_get_octet_string_param"](pkey, name, buf, n, ctypes.byref(got)) == 1, "get " + name.decode())
	return buf.raw[:got.value]

def keygen(alg, seed):
	_init(); _need(not _why, "init")
	c = _fn["EVP_PKEY_CTX_new_from_name"](None, alg.encode(), None)
	_need(c, "ctx for " + alg)
	pkey = ctypes.c_void_p()
	try:
		_need(_fn["EVP_PKEY_keygen_init"](c) == 1, "keygen_init")
		p, keep = _params([(b"seed", seed)])
		_need(_fn["EVP_PKEY_CTX_set_params"](c, p) == 1, "set seed")
		_need(_fn["EVP_PKEY_generate"](c, ctypes.byref(pkey)) == 1, "generate")
		n = len(seed) // 3
		return _getoctets(pkey, b"pub", 2 * n), _getoctets(pkey, b"priv", 4 * n)
	finally:
		_fn["EVP_PKEY_CTX_free"](c)
		if pkey:
			_fn["EVP_PKEY_free"](pkey)

def _load(alg, name, key, selection):
	c = _fn["EVP_PKEY_CTX_new_from_name"](None, alg.encode(), None)
	_need(c, "ctx for " + alg)
	pkey = ctypes.c_void_p()
	try:
		_need(_fn["EVP_PKEY_fromdata_init"](c) == 1, "fromdata_init")
		p, keep = _params([(name, key)])
		_need(_fn["EVP_PKEY_fromdata"](c, ctypes.byref(pkey), selection, p) == 1, "fromdata")
	finally:
		_fn["EVP_PKEY_CTX_free"](c)
	return pkey

_PUBLIC, _KEYPAIR = 0x86, 0x87	# EVP_PKEY_PUBLIC_KEY, EVP_PKEY_KEYPAIR

def sign(alg, sk, msg, ctx=b""):
	_init(); _need(not _why, "init")
	pkey = _load(alg, b"priv", sk, _KEYPAIR)
	md = _fn["EVP_MD_CTX_new"]()
	try:
		items = [(b"deterministic", 1)]
		if ctx:
			items.append((b"context-string", ctx))
		p, keep = _params(items)
		_need(_fn["EVP_DigestSignInit_ex"](md, None, None, None, None, pkey, p) == 1, "DigestSignInit")
		n = ctypes.c_size_t(0)
		_need(_fn["EVP_DigestSign"](md, None, ctypes.byref(n), msg, len(msg)) == 1, "DigestSign size")
		buf = ctypes.create_string_buffer(n.value)
		_need(_fn["EVP_DigestSign"](md, buf, ctypes.byref(n), msg, len(msg)) == 1, "DigestSign")
		return buf.raw[:n.value]
	finally:
		_fn["EVP_MD_CTX_free"](md)
		_fn["EVP_PKEY_free"](pkey)

def verify(alg, pk, msg, sig, ctx=b""):
	_init(); _need(not _why, "init")
	pkey = _load(alg, b"pub", pk, _PUBLIC)
	md = _fn["EVP_MD_CTX_new"]()
	try:
		p, keep = _params([(b"context-string", ctx)] if ctx else [])
		_need(_fn["EVP_DigestVerifyInit_ex"](md, None, None, None, None, pkey, p) == 1, "DigestVerifyInit")
		return _fn["EVP_DigestVerify"](md, sig, len(sig), msg, len(msg)) == 1
	finally:
		_fn["EVP_MD_CTX_free"](md)
		_fn["EVP_PKEY_free"](pkey)

if __name__ == "__main__":
	w = available()
	print("OpenSSL SLH-DSA:", "available" if w is None else "not available (%s)" % w)
