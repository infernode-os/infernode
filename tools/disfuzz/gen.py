#!/usr/bin/env python3
#
# gen.py -- random Limbo programs for disfuzz (tools/disfuzz/disfuzz).
#
#	gen.py [-s seed] [-p selfpath] [-z size]
#
# Writes to standard output one Limbo module, made from the seed alone, that
# the native limbo compiles and that prints the same lines under any correct
# Dis VM: the interpreter (emu -c0), the JIT (-c1), one VM or many. Each line
# is a checkpoint -- a tag and a value -- so where two runs part is where the
# VM went wrong. The last line is "done", so a run that stopped early shows.
#
# What the programs do is what the VM implements, not what Limbo programs
# usually do: arithmetic on int, big, real and byte at their edges (the most
# negative over -1, shifts past the width, NaN, -0, conversions out of
# range); strings with runes past U+FFFF, indexed, sliced, appended to
# themselves; arrays, slices and slice copies; lists; ref adts and nil
# through them; every exception the VM raises (zero divide, bounds, nil,
# negative size) and ones the program raises, caught near and far; deep
# recursion (the stack grown and given back); allocation in loops (the
# collector running under compiled code); spawned procs and channels,
# buffered and not, alt over an array of channels; and the module loading
# a second instance of itself and calling into it (calls between modules,
# their own module data).
#
# Whatever could make a correct VM print differently is left out: procs
# spawned never print or touch module data, results from several come back
# summed (order-free), there is no time, no randomness at run time and no
# alt with a default. Loops are bounded by counters nothing else assigns,
# calls go only to functions defined earlier (and one bounded recursion),
# and a cost estimate keeps each program to well under a second.
#
# Statements are bracketed by "#<" and "#>" lines so the driver can cut a
# failing program down (disfuzz -r) without parsing Limbo.
#
# Kept in, for what they found: real literals and strings among the
# denormals (libmath/dtoa.c's strtod hung on 4.9e-324, the compiler on the
# literal and the VM on the string); functions returning nil, which limbo
# inlines (it inlined them as an untyped nil and failed on len, tl and an
# index of it); x ** 0 for a big x (folded to an int, read by compiled
# code as an address).
#

import argparse
import random
import sys

INTS = ["int", "big", "real", "byte"]
TYPES = INTS + ["string", "aint", "abyte", "lint", "refA"]

LTYPE = {
	"int": "int", "big": "big", "real": "real", "byte": "byte",
	"string": "string", "aint": "array of int", "abyte": "array of byte",
	"lint": "list of int", "refA": "ref A",
}

# Values at the edges of each type, as Limbo source.
EDGE = {
	"int": ["0", "1", "-1", "2", "3", "7", "8", "15", "16", "31", "32", "33",
		"63", "64", "127", "128", "255", "256", "65535", "65536",
		"16r7fffffff", "(-16r7fffffff-1)", "16r40000000", "-2", "-31",
		"1000000007", "'a'", "'\\u00e9'", "'\\U0001F680'"],
	"big": ["big 0", "big 1", "big -1", "big 2", "big 31", "big 32",
		"big 63", "big 64", "big 16r7fffffff", "big (-16r7fffffff-1)",
		"16r7fffffffffffffff", "(-16r7fffffffffffffff-big 1)",
		"16r100000000", "16rffffffff", "big 10", "16r123456789abcdef"],
	"real": ["0.0", "1.0", "-1.0", "0.5", "-0.5", "1.5", "2.5", "-2.5",
		"1e300", "-1e300", "1e-300", "2.2250738585072014e-308", "4.9e-324", "2e-320", "2147483647.0",
		"2147483648.0", "-2147483649.0", "9.2233720368547758e18",
		"3.141592653589793", "1e16", "0.1", "-0.0"],
	"byte": ["byte 0", "byte 1", "byte 127", "byte 128", "byte 255",
		"byte 7", "byte 8"],
	"string": ['""', '"a"', '"abc"', '"hello, world"', '"\\u00e9t\\u00e9"',
		'"\\U0001F680x"', '"\\U00020000\\u00ff"', '"12"', '"-7"',
		'"16rff"', '"1e3"', '"nan"', '" 42 "', '"9999999999"', '"4.9e-324"',
		'"2.4703282292062328e-324"', '"1e-400"', '"1e309"', '"-0"',
		'"0x10"', '"\\u0000z"'],
}

ARITH = {
	"int": ["+", "-", "*", "/", "%", "&", "|", "^", "<<", ">>"],
	"big": ["+", "-", "*", "/", "%", "&", "|", "^"],
	"real": ["+", "-", "*", "/"],
	"byte": ["+", "-", "*", "/", "%", "&", "|", "^"],
}
CMP = ["<", "<=", ">", ">=", "==", "!="]

# element types for lists, arrays and channels (feature())
ELT = ["int", "big", "real", "byte", "string", "refA", "B", "C", "tup"]
LELT = {"int": "int", "big": "big", "real": "real", "byte": "byte",
	"string": "string", "refA": "ref A", "B": "B", "C": "C", "tup": "(int, string, big)"}


class Var:
	def __init__(self, name, t, assignable=True):
		self.name = name
		self.t = t
		self.assignable = assignable


class Func:
	def __init__(self, name, params, ret, pure):
		self.name = name
		self.params = params		# list of Var
		self.ret = ret
		self.pure = pure		# no module data, no output: spawnable
		self.cost = 1
		self.body = None


class Gen:
	def __init__(self, seed, selfpath, size):
		self.r = random.Random(seed)
		self.seed = seed
		self.selfpath = selfpath
		self.size = size
		self.nvar = 0
		self.ntag = 0
		self.funcs = []
		self.globals = []
		self.scopes = []
		self.cur = None		# function being generated
		self.lines = []
		self.ind = 1
		self.loopdepth = 0
		self.mult = 1		# how many times the current statement runs
		self.costacc = 0
		self.senders = set()	# send<T> helpers feature() used

	# ---- helpers ----
	def chance(self, p):
		return self.r.random() < p

	def pick(self, xs):
		return self.r.choice(xs)

	def newname(self, prefix="v"):
		self.nvar += 1
		return "%s%d" % (prefix, self.nvar)

	def tag(self):
		self.ntag += 1
		return self.ntag

	def emit(self, s):
		self.lines.append("\t" * self.ind + s)

	def open_chunk(self):
		self.lines.append("#<")

	def close_chunk(self):
		self.lines.append("#>")

	def vars_of(self, t, assignable=False):
		out = []
		for sc in self.scopes:
			for v in sc:
				if v.t == t and (v.assignable or not assignable):
					out.append(v)
		if self.cur is None or not self.cur.pure:
			for v in self.globals:
				if v.t == t:
					out.append(v)
		return out

	def declare(self, t, assignable=True):
		v = Var(self.newname(), t, assignable)
		self.scopes[-1].append(v)
		return v

	def callable_funcs(self, ret):
		out = []
		for f in self.funcs:
			if f.body is None or f.ret != ret:
				continue
			if self.cur is not None and self.cur.pure and not f.pure:
				continue
			if f.cost * self.mult > 4000:
				continue
			out.append(f)
		return out

	# ---- expressions ----
	def lit(self, t):
		if t in EDGE and self.chance(0.6):
			return self.pick(EDGE[t])
		r = self.r
		if t == "int":
			return str(r.randint(-1000, 1000)) if r.random() < 0.7 else "16r%x" % r.randint(0, 0x7fffffff)
		if t == "big":
			return "big %d" % r.randint(-100000, 100000) if r.random() < 0.6 else "16r%x" % r.randint(1 << 32, (1 << 63) - 1)
		if t == "real":
			return repr(round(r.uniform(-1e6, 1e6), r.randint(0, 6))) if r.random() < 0.7 else "%re%d" % (r.uniform(1, 9), r.randint(-330, 310))
		if t == "byte":
			return "byte %d" % r.randint(0, 255)
		if t == "string":
			n = r.randint(0, 8)
			cs = []
			for _ in range(n):
				k = r.random()
				if k < 0.7:
					cs.append(chr(r.randint(0x61, 0x7a)))
				elif k < 0.85:
					cs.append("\\u%04x" % r.randint(0xa0, 0xd7ff))
				else:
					cs.append("\\U%08x" % r.randint(0x10000, 0x10ffff))
			return '"' + "".join(cs) + '"'
		raise ValueError(t)

	def smallint(self, d):
		# an int usually in a small range: an index, a count, a shift
		k = self.r.random()
		if k < 0.4:
			return str(self.r.randint(0, 9))
		if k < 0.85:
			return "((%s) & %d)" % (self.expr("int", d + 1), self.pick([3, 7, 15, 31, 63]))
		return self.expr("int", d + 1)	# anything: bounds, sizes, shifts past width

	def divisor(self, t, d):
		# mostly not zero; sometimes whatever it is, which may be
		e = self.expr(t, d + 1)
		if self.chance(0.75):
			one = {"int": "1", "big": "big 1", "real": "1.0", "byte": "byte 1"}[t]
			if t == "real":
				return e
			return "((%s) | %s)" % (e, one)
		# may be zero: through zn (always 0), which the compiler cannot
		# fold, so a constant zero is not refused at compile time
		zero = {"int": "zn", "big": "big zn", "real": "real zn", "byte": "byte zn"}[t]
		return "(%s + %s)" % (e, zero)

	def expr(self, t, d=0):
		r = self.r
		if d > 4 or (d > 1 and r.random() < 0.3):
			return self.leaf(t)
		meth = getattr(self, "e_" + t)
		return meth(d)

	def leaf(self, t):
		vs = self.vars_of(t)
		if vs and self.chance(0.65):
			return self.pick(vs).name
		if t in EDGE or t in ("int", "big", "real", "byte", "string"):
			return self.lit(t)
		return self.e_new(t, 4)

	def call(self, ret, d):
		fs = self.callable_funcs(ret)
		if not fs:
			return None
		f = self.pick(fs)
		self.costacc += f.cost * self.mult
		args = [self.expr(p.t, d + 2) for p in f.params]
		return "%s(%s)" % (f.name, ", ".join(args))

	def e_int(self, d):
		r = self.r
		k = r.randint(0, 22)
		if k <= 6:
			op = self.pick(ARITH["int"])
			if op in ("/", "%"):
				return "(%s %s %s)" % (self.expr("int", d + 1), op, self.divisor("int", d))
			if op in ("<<", ">>"):
				return "(%s %s %s)" % (self.expr("int", d + 1), op, self.smallint(d))
			return "(%s %s %s)" % (self.expr("int", d + 1), op, self.expr("int", d + 1))
		if k == 7:
			return "(%s %s)" % (self.pick(["-", "~", "!"]), self.expr("int", d + 1))
		if k == 8:
			t = self.pick(["int", "big", "real", "byte", "string"])
			return "(%s %s %s)" % (self.expr(t, d + 1), self.pick(CMP), self.expr(t, d + 1))
		if k == 9:
			return "(%s %s %s)" % (self.expr("int", d + 1), self.pick(["&&", "||"]), self.expr("int", d + 1))
		if k == 10:
			return "int %s" % self.paren(self.expr(self.pick(["big", "real", "byte"]), d + 1))
		if k == 11:
			return "int sid(%s)" % self.expr("string", d + 1)
		if k == 12:
			return "len %s" % self.paren(self.expr(self.pick(["string", "aint", "abyte", "lint"]), d + 1))
		if k == 13:
			return "%s[%s]" % (self.paren(self.expr("string", d + 1)), self.smallint(d))
		if k == 14:
			return "%s[%s]" % (self.paren(self.expr("aint", d + 1)), self.smallint(d))
		if k == 15:
			return "hd %s" % self.paren(self.expr("lint", d + 1))
		if k == 16:
			return "%s.i" % self.paren(self.expr("refA", d + 1))
		if k == 17:
			return "(%s ** %s)" % (self.expr("int", d + 1), self.pick(["0", "1", "2", "3", "31", "(-1+zn)", "(%s + zn)" % self.smallint(d)]))
		if k == 18:
			c = self.call("int", d)
			if c:
				return c
		if k == 19:
			return "(%s == nil)" % self.paren(self.expr(self.pick(["aint", "lint", "refA", "string"]), d + 1))
		if k == 20:
			return "int %s[%s]" % (self.paren(self.expr("abyte", d + 1)), self.smallint(d))
		return self.leaf("int")

	def e_big(self, d):
		k = self.r.randint(0, 12)
		if k <= 5:
			op = self.pick(ARITH["big"] + ["<<", ">>"])
			if op in ("/", "%"):
				return "(%s %s %s)" % (self.expr("big", d + 1), op, self.divisor("big", d))
			if op in ("<<", ">>"):
				return "(%s %s %s)" % (self.expr("big", d + 1), op, self.smallint(d))
			return "(%s %s %s)" % (self.expr("big", d + 1), op, self.expr("big", d + 1))
		if k == 6:
			return "(%s %s)" % (self.pick(["-", "~"]), self.expr("big", d + 1))
		if k == 7:
			t = self.pick(["int", "real", "byte", "string"])
			return ("big sid(%s)" if t == "string" else "big (%s)") % self.expr(t, d + 1)
		if k == 8:
			return "%s.b" % self.paren(self.expr("refA", d + 1))
		if k == 9:
			return "(%s ** %s)" % (self.expr("big", d + 1), self.pick(["0", "1", "2", "63", "64", "(%s + zn)" % self.smallint(d)]))
		if k == 10:
			c = self.call("big", d)
			if c:
				return c
		return self.leaf("big")

	def e_real(self, d):
		k = self.r.randint(0, 10)
		if k <= 4:
			op = self.pick(ARITH["real"])
			return "(%s %s %s)" % (self.expr("real", d + 1), op, self.expr("real", d + 1))
		if k == 5:
			return "(- %s)" % self.expr("real", d + 1)
		if k == 6:
			t = self.pick(["int", "big", "byte", "string"])
			return ("real sid(%s)" if t == "string" else "real (%s)") % self.expr(t, d + 1)
		if k == 7:
			return "%s.r" % self.paren(self.expr("refA", d + 1))
		if k == 8:
			return "(%s ** %s)" % (self.expr("real", d + 1), self.pick(["0", "1", "2", "(-1+zn)", "(-2+zn)", "1000", "(%s + zn)" % self.smallint(d)]))
		if k == 9:
			c = self.call("real", d)
			if c:
				return c
		return self.leaf("real")

	def e_byte(self, d):
		k = self.r.randint(0, 8)
		if k <= 3:
			op = self.pick(ARITH["byte"] + ["<<", ">>"])
			if op in ("/", "%"):
				return "(%s %s %s)" % (self.expr("byte", d + 1), op, self.divisor("byte", d))
			if op in ("<<", ">>"):
				return "(%s %s %s)" % (self.expr("byte", d + 1), op, self.smallint(d))
			return "(%s %s %s)" % (self.expr("byte", d + 1), op, self.expr("byte", d + 1))
		if k == 4:
			return "byte %s" % self.paren(self.expr(self.pick(["int", "big", "real"]), d + 1))
		if k == 5:
			return "%s[%s]" % (self.paren(self.expr("abyte", d + 1)), self.smallint(d))
		if k == 6:
			return "(~ %s)" % self.expr("byte", d + 1)
		if k == 7:
			c = self.call("byte", d)
			if c:
				return c
		return self.leaf("byte")

	def e_string(self, d):
		k = self.r.randint(0, 11)
		if k <= 2:
			return "(%s + %s)" % (self.expr("string", d + 1), self.expr("string", d + 1))
		if k == 3:
			i = self.smallint(d)
			if self.chance(0.5):
				return "%s[%s:]" % (self.paren(self.expr("string", d + 1)), i)
			return "%s[%s:%s]" % (self.paren(self.expr("string", d + 1)), i, self.smallint(d))
		if k == 4:
			return "string %s" % self.paren(self.expr(self.pick(["int", "big", "real"]), d + 1))
		if k == 5:
			return "string %s" % self.paren(self.expr("abyte", d + 1))
		if k == 6:
			return "%s.s" % self.paren(self.expr("refA", d + 1))
		if k == 7:
			c = self.call("string", d)
			if c:
				return c
		if k == 8:
			return "rs(%s)" % self.expr("int", d + 1)
		return self.leaf("string")

	def e_aint(self, d):
		k = self.r.randint(0, 6)
		if k == 0 or k == 1:
			return self.e_new("aint", d)
		if k == 2:
			i = self.smallint(d)
			if self.chance(0.5):
				return "%s[%s:]" % (self.paren(self.expr("aint", d + 1)), i)
			return "%s[%s:%s]" % (self.paren(self.expr("aint", d + 1)), i, self.smallint(d))
		if k == 3:
			return "%s.a" % self.paren(self.expr("refA", d + 1))
		if k == 4:
			c = self.call("aint", d)
			if c:
				return c
		return self.leaf("aint")

	def e_abyte(self, d):
		k = self.r.randint(0, 5)
		if k <= 1:
			return "array of byte %s" % self.paren(self.expr("string", d + 1))
		if k == 2:
			return self.e_new("abyte", d)
		if k == 3:
			return "%s[%s:]" % (self.paren(self.expr("abyte", d + 1)), self.smallint(d))
		return self.leaf("abyte")

	def e_lint(self, d):
		k = self.r.randint(0, 5)
		if k <= 1:
			return "(%s :: %s)" % (self.expr("int", d + 1), self.expr("lint", d + 1))
		if k == 2:
			return "tl %s" % self.paren(self.expr("lint", d + 1))
		if k == 3:
			return "%s.l" % self.paren(self.expr("refA", d + 1))
		if k == 4:
			return "zl" if self.chance(0.7) else "nl()"
		return self.leaf("lint")

	def e_refA(self, d):
		k = self.r.randint(0, 5)
		if k <= 1:
			return self.e_new("refA", d)
		if k == 2:
			return "%s.n" % self.paren(self.expr("refA", d + 1))
		if k == 3:
			c = self.call("refA", d)
			if c:
				return c
		return self.leaf("refA")

	def e_new(self, t, d):
		r = self.r
		if t == "aint":
			k = r.randint(0, 4)
			if k == 0:
				return "array[%s] of int" % self.smallint(d)
			if k == 1:
				n = r.randint(0, 5)
				return "array[] of {%s}" % ", ".join(self.expr("int", d + 2) for _ in range(n)) if n else "array[0] of int"
			if k == 2:
				return "array[%s] of {* => %s}" % (self.smallint(d), self.expr("int", d + 2))
			if k == 3:
				return "array[%d] of {0 => %s, %d => %s}" % (r.randint(3, 9), self.expr("int", d + 2), r.randint(1, 2), self.expr("int", d + 2))
			return "zai" if self.chance(0.7) else "nai()"
		if t == "abyte":
			return "array[%s] of {* => %s}" % (self.smallint(d), self.expr("byte", d + 2))
		if t == "refA":
			if r.random() < 0.15:
				return "zA" if self.chance(0.7) else "nA()"
			n = "nil" if r.random() < 0.6 else self.expr("refA", d + 2)
			return "ref A(%s, %s, %s, %s, %s, %s, %s)" % (
				self.expr("int", d + 2), self.expr("big", d + 2), self.expr("real", d + 2),
				self.expr("string", d + 2), self.expr("aint", d + 3), self.expr("lint", d + 3), n)
		if t == "lint":
			return "zl" if self.chance(0.7) else "nl()"
		return self.lit(t)

	def paren(self, e):
		return e if e.startswith("(") and e.endswith(")") else "(%s)" % e

	def show(self, t, e):
		# a string for the value, the same under any correct VM
		if t in ("int", "big", "real"):
			return "string %s" % self.paren(e)
		if t == "byte":
			return "string int %s" % self.paren(e)
		if t == "string":
			return "qs(%s)" % e
		if t == "aint":
			return "as(%s)" % e
		if t == "abyte":
			return "bs(%s)" % e
		if t == "lint":
			return "ls(%s)" % e
		if t == "refA":
			return "As(%s, 3)" % e
		raise ValueError(t)

	# ---- statements ----
	def stmts(self, n, d):
		for _ in range(n):
			self.stmt(d)

	def stmt(self, d):
		self.open_chunk()
		self._stmt(d)
		self.close_chunk()

	def _stmt(self, d):
		r = self.r
		pure = self.cur is not None and self.cur.pure
		k = r.randint(0, 30)
		self.costacc += self.mult
		if k <= 6:
			t = self.pick(TYPES)
			v = self.declare(t)
			# declared after its expression, so it cannot use itself
			self.scopes[-1].remove(v)
			e = self.expr(t)
			self.scopes[-1].append(v)
			self.emit("%s := %s;" % (v.name, e))
			return
		if k <= 9:
			t = self.pick(TYPES)
			vs = self.vars_of(t, assignable=True)
			if vs:
				v = self.pick(vs)
				if t in ARITH and t != "real" and self.chance(0.4):
					op = self.pick(ARITH[t])
					rhs = self.divisor(t, 1) if op in "/%" else self.expr(t, 1)
					if op in ("<<", ">>"):
						rhs = self.smallint(1)
					self.emit("%s %s= %s;" % (v.name, op, rhs))
				elif t == "string" and self.chance(0.3):
					self.emit("%s += %s;" % (v.name, self.pick([v.name, self.expr("string", 1)])))
				else:
					self.emit("%s = %s;" % (v.name, self.expr(t, 1)))
				return
		if k <= 11 and not pure:
			t = self.pick(TYPES)
			self.emit("out(%d, %s);" % (self.tag(), self.show(t, self.expr(t))))
			return
		if k == 12:
			# element assignment: arrays, strings (s[len s] appends), adt fields
			c = r.randint(0, 3)
			if c == 0:
				vs = self.vars_of("aint", True)
				if vs:
					self.emit("%s[%s] = %s;" % (self.pick(vs).name, self.smallint(1), self.expr("int", 1)))
					return
			if c == 1:
				vs = self.vars_of("string", True)
				if vs:
					v = self.pick(vs).name
					i = "len %s" % v if self.chance(0.5) else self.smallint(1)
					self.emit("%s[%s] = %s;" % (v, i, self.pick(["'z'", "'\\u00e9'", "'\\U0001F680'", "16r10FFFF", self.expr("int", 2)])))
					return
			if c == 2:
				vs = self.vars_of("refA", True)
				if vs:
					f, t = self.pick([("i", "int"), ("b", "big"), ("r", "real"), ("s", "string"), ("a", "aint"), ("l", "lint"), ("n", "refA")])
					self.emit("%s.%s = %s;" % (self.pick(vs).name, f, self.expr(t, 1)))
					return
			if c == 3:
				vs = self.vars_of("aint", True)
				if vs:
					# slice copy: a[i:] = b
					self.emit("%s[%s:] = %s;" % (self.pick(vs).name, self.smallint(1), self.expr("aint", 1)))
					return
		if k == 13 and d < 3:
			self.emit("if(%s) {" % self.expr("int", 1))
			self.block(r.randint(1, 4), d)
			if self.chance(0.5):
				self.emit("} else {")
				self.block(r.randint(1, 3), d)
			self.emit("}")
			return
		if k in (14, 15) and d < 3 and self.loopdepth < 2:
			self.loop(d)
			return
		if k == 16 and d < 3:
			self.guarded(d)
			return
		if k == 17 and d < 3:
			self.casestmt(d)
			return
		if k == 18:
			ts = [t for t in TYPES if self.callable_funcs(t)]
			if ts:
				t = self.pick(ts)
				c = self.call(t, 0)
				if pure:
					self.emit("%s;" % c)
				else:
					self.emit("out(%d, %s);" % (self.tag(), self.show(t, c)))
				return
		if k == 19:
			self.emit("raise \"user:%s\";" % self.pick(["a", "b", "zero", "bounds", "x y"]) if self.chance(0.3)
				else "if(%s) raise \"user:\" + string %s;" % (self.expr("int", 2), self.expr("int", 2)))
			return
		if k == 20 and not pure and d < 2 and self.loopdepth == 0:
			self.spawnstmt()
			return
		if k == 21 and not pure and self.loopdepth == 0:
			self.churn()
			return
		if k in (23, 24) and not pure and self.loopdepth == 0 and d < 2:
			self.feature()
			return
		if k == 22 and self.loopdepth == 0:
			n = self.pick([1, 10, 100, 1000, 5000])
			if pure:
				self.emit("deep(%d, %s);" % (n, self.expr("int", 2)))
			else:
				self.emit("out(%d, string deep(%d, %s));" % (self.tag(), n, self.expr("int", 2)))
			return
		# declare something, and say it
		t = self.pick(TYPES)
		e = self.expr(t)
		v = self.declare(t)
		self.emit("%s := %s;" % (v.name, e))
		if not pure:
			self.emit("out(%d, %s);" % (self.tag(), self.show(t, v.name)))

	def block(self, n, d):
		self.ind += 1
		self.scopes.append([])
		self.stmts(n, d + 1)
		self.scopes.pop()
		self.ind -= 1

	def loop(self, d):
		r = self.r
		n = self.pick([0, 1, 2, 3, 5, 8, 17]) if self.loopdepth else self.pick([1, 2, 3, 7, 16, 33, 100])
		iv = self.newname("i")
		k = r.randint(0, 2)
		self.loopdepth += 1
		old = self.mult
		self.mult *= max(n, 1)
		if k == 0:
			self.emit("for(%s := 0; %s < %d; %s++) {" % (iv, iv, n, iv))
		elif k == 1:
			self.emit("%s := %d;" % (iv, n))
			self.emit("while(%s-- > 0) {" % iv)
		else:
			self.emit("%s := 0;" % iv)
			self.emit("do {")
		self.ind += 1
		self.scopes.append([Var(iv, "int", assignable=False)])
		self.stmts(r.randint(1, 4), d + 1)
		if self.chance(0.2):
			self.emit("if(%s) %s;" % (self.expr("int", 2), self.pick(["break", "continue"]) if k != 2 else "break"))
		self.scopes.pop()
		self.ind -= 1
		if k == 2:
			self.emit("} while(++%s < %d);" % (iv, n))
		else:
			self.emit("}")
		self.mult = old
		self.loopdepth -= 1

	def guarded(self, d):
		self.emit("{")
		self.block(self.r.randint(1, 4), d)
		ev = self.newname("e")
		pats = self.r.sample(['"zero*"', '"array bounds*"', '"dereference*"', '"user:*"', '"negative*"', '"*"'],
			self.r.randint(1, 3))
		self.emit("} exception %s {" % ev)
		for p in pats:
			if self.cur is not None and self.cur.pure:
				self.emit("%s =>\n%s;" % (p, "\t" * (self.ind + 1) + "x := 0; x++"))
			else:
				self.emit("%s =>" % p)
				self.emit("\tout(%d, \"exc \" + %s);" % (self.tag(), ev))
		self.emit("}")

	def casestmt(self, d):
		r = self.r
		if self.chance(0.6):
			self.emit("case %s {" % self.expr("int", 1))
			used = set()
			for _ in range(r.randint(1, 4)):
				a = r.randint(-5, 40)
				if r.random() < 0.3:
					b = a + r.randint(1, 10)
					lab = "%d to %d" % (a, b)
					rng = set(range(a, b + 1))
				else:
					lab = str(a)
					rng = {a}
				if rng & used:
					continue
				used |= rng
				self.emit("%s =>" % lab)
				self.block(r.randint(1, 2), d)
		else:
			self.emit("case %s {" % self.expr("string", 1))
			used = set()
			for _ in range(r.randint(1, 3)):
				s = self.pick(['""', '"a"', '"abc"', '"12"', '"\\u00e9t\\u00e9"', '"zz"'])
				if s in used:
					continue
				used.add(s)
				self.emit("%s =>" % s)
				self.block(r.randint(1, 2), d)
		if self.chance(0.6):
			self.emit("* =>")
			self.block(1, d)
		self.emit("}")

	def spawnstmt(self):
		# k procs, each computing a pure function of its argument, sent back
		# on one channel or an array of them; the results summed (order-free)
		r = self.r
		pf = [f for f in self.funcs if f.body is not None and f.pure and f.ret == "int"
			and len(f.params) >= 1 and f.params[0].t == "int" and f.cost < 2000]
		if not pf:
			return
		f = self.pick(pf)
		k = r.randint(1, 6)
		sv = self.newname("s")
		cv = self.newname("c")
		buf = self.pick(["", "[1]", "[%d]" % k])
		args = ", ".join(self.expr(p.t, 3) for p in f.params[1:])
		args = ", " + args if args else ""
		self.emit("%s := 0;" % sv)
		if self.chance(0.5):
			self.emit("%s := chan%s of int;" % (cv, buf))
			for j in range(k):
				self.emit("spawn w%s(%s, %d%s);" % (f.name, cv, j, args))
			jv = self.newname("j")
			self.emit("for(%s := 0; %s < %d; %s++)" % (jv, jv, k, jv))
			self.emit("\t%s += <-%s;" % (sv, cv))
		else:
			self.emit("%s := array[%d] of chan of int;" % (cv, k))
			jv = self.newname("j")
			self.emit("for(%s := 0; %s < %d; %s++) {" % (jv, jv, k, jv))
			self.emit("\t%s[%s] = chan%s of int;" % (cv, jv, buf))
			self.emit("\tspawn w%s(%s[%s], %s%s);" % (f.name, cv, jv, jv, args))
			self.emit("}")
			jv = self.newname("j")
			self.emit("for(%s := 0; %s < %d; %s++) alt {" % (jv, jv, k, jv))
			xv = self.newname("x")
			yv = self.newname("y")
			self.emit("(%s, %s) := <-%s =>" % (xv, yv, cv))
			self.emit("\t%s += %s * 0 + %s;" % (sv, xv, yv))
			self.emit("}")
		f.spawned = True
		self.emit("out(%d, string %s);" % (self.tag(), sv))

	# ---- the rest of the instruction set ----
	# Lists, arrays and channels of every element type, a value adt and a
	# tuple among them; alt with a default (on a channel whose state is
	# known, so it is deterministic); pick adts; functions returning
	# tuples; ref fn, nil among them; the module loaded as $self (sharing
	# its module data); a spawned Prog that exits. Each says what it saw.
	def eexpr(self, t, d=2):
		if t == "B":
			return "B(%s, %s)" % (self.expr("int", d), self.expr("string", d))
		if t == "C":
			return "C(%s, %s)" % (self.expr("int", d), self.expr("real", d))
		if t == "tup":
			return "(%s, %s, %s)" % (self.expr("int", d), self.expr("string", d), self.expr("big", d))
		return self.expr(t, d)

	def eshow(self, t, e):
		if t == "B":
			return "Bs(%s)" % e
		if t == "C":
			return "Cs(%s)" % e
		if t == "tup":
			return "Ts(%s)" % e
		return self.show(t, e)

	def feature(self):
		r = self.r
		t = self.pick(ELT)
		lt = LELT[t]
		k = r.randint(0, 9)
		tag = self.tag()
		v = self.newname("q")
		x = self.newname("x")
		if k == 0:
			n = r.randint(1, 4)
			self.emit("%s: list of %s;" % (v, lt))
			for _ in range(n):
				self.emit("%s = %s :: %s;" % (v, self.eexpr(t), v))
			self.emit("out(%d, string len %s);" % (tag, v))
			self.emit("for(%s := %s; %s != nil; %s = tl %s)" % (x, v, x, x, x))
			self.emit("\tout(%d, %s);" % (tag, self.eshow(t, "hd " + x)))
		elif k == 1:
			n = r.randint(0, 5)
			self.emit("%s := array[%d] of %s;" % (v, n, lt))
			for _ in range(r.randint(0, 3)):
				self.emit("%s[%s] = %s;" % (v, self.smallint(2), self.eexpr(t)))
			self.emit("for(%s := 0; %s < len %s; %s++)" % (x, x, v, x))
			self.emit("\tout(%d, %s);" % (tag, self.eshow(t, "%s[%s]" % (v, x))))
			self.emit("out(%d, string len %s[%s:]);" % (tag, v, self.smallint(2)))
		elif k == 2:
			n = r.randint(1, 4)
			self.emit("%s := array[] of {%s};" % (v, ", ".join(self.eexpr(t) for _ in range(n))))
			self.emit("out(%d, %s);" % (tag, self.eshow(t, "%s[%s]" % (v, self.smallint(2)))))
		elif k == 3:
			# buffered: every send fits, so one Prog does it all
			n = r.randint(1, 4)
			self.emit("%s := chan[%d] of %s;" % (v, n, lt))
			for _ in range(n):
				self.emit("%s <-= %s;" % (v, self.eexpr(t)))
			self.emit("for(%s := 0; %s < %d; %s++) {" % (x, x, n, x))
			y = self.newname("y")
			self.emit("\t%s := <-%s;" % (y, v))
			self.emit("\tout(%d, %s);" % (tag, self.eshow(t, y)))
			self.emit("}")
		elif k == 4:
			# from another Prog, unbuffered
			n = r.randint(1, 3)
			self.senders.add(t)
			self.emit("%s := chan of %s;" % (v, lt))
			self.emit("spawn send%s(%s, %s, %d);" % (t, v, self.eexpr(t), n))
			self.emit("for(%s := 0; %s < %d; %s++)" % (x, x, n, x))
			self.emit("\tout(%d, %s);" % (tag, self.eshow(t, "<-" + v)))
		elif k == 5:
			# alt with a default, the channel full or empty as decided here
			self.emit("%s := chan[1] of %s;" % (v, lt))
			self.emit("if(%s)" % self.expr("int", 2))
			self.emit("\t%s <-= %s;" % (v, self.eexpr(t)))
			for _ in range(r.randint(1, 2)):
				y = self.newname("y")
				self.emit("alt {")
				self.emit("%s := <-%s =>" % (y, v))
				self.emit("\tout(%d, %s);" % (tag, self.eshow(t, y)))
				self.emit("* =>")
				self.emit("\tout(%d, \"empty\");" % tag)
				self.emit("}")
		elif k == 6:
			self.emit("%s: ref P;" % v)
			c = self.expr("int", 2)
			self.emit("case (%s) & 3 {" % c)
			self.emit("0 => %s = ref P.I(%s);" % (v, self.expr("int", 2)))
			self.emit("1 => %s = ref P.S(%s);" % (v, self.expr("string", 2)))
			self.emit("2 => %s = ref P.R(%s);" % (v, self.expr("real", 2)))
			self.emit("}")
			self.emit("if(%s == nil)" % v)
			self.emit("\tout(%d, \"nil P\");" % tag)
			self.emit("else pick %s := %s {" % (x, v))
			self.emit("I => out(%d, \"I \" + string %s.i);" % (tag, x))
			self.emit("S => out(%d, \"S \" + qs(%s.s));" % (tag, x))
			self.emit("R => out(%d, \"R \" + string %s.r);" % (tag, x))
			self.emit("}")
		elif k == 7:
			a, b, c = self.newname("t"), self.newname("t"), self.newname("t")
			if self.chance(0.5):
				self.emit("(%s, %s, %s) := tf(%s);" % (a, b, c, self.expr("int", 2)))
				self.emit("out(%d, string %s + \" \" + qs(%s) + \" \" + string %s);" % (tag, a, b, c))
			else:
				self.emit("(%s, nil, %s) := tf(%s);" % (a, c, self.expr("int", 2)))
				self.emit("out(%d, string %s + \" \" + string %s);" % (tag, a, c))
		elif k == 8:
			self.emit("%s: ref fn(x: int): int;" % v)
			w = r.randint(0, 2)
			if w == 0:
				self.emit("%s = rf1;" % v)
			elif w == 1:
				self.emit("if(%s) %s = rf2; else %s = rf1;" % (self.expr("int", 2), v, v))
			# else nil: calling it raises
			self.emit("out(%d, string %s(%s));" % (tag, v, self.expr("int", 2)))
		else:
			c = self.newname("c")
			self.emit("%s := chan of int;" % c)
			m = self.newname("me")
			self.emit("%s := load Fz \"$self\";" % m)
			if self.chance(0.5):
				# through the module: mspawn
				self.emit("if(%s != nil) spawn %s->exiter(%s, %s); else spawn exiter(%s, %s);"
					% (m, m, c, self.expr("int", 2), c, self.expr("int", 2)))
			else:
				self.emit("spawn exiter(%s, %s);" % (c, self.expr("int", 2)))
			self.emit("out(%d, \"exit \" + string <-%s);" % (tag, c))
			fs = [f for f in self.funcs if f.body is not None and self.cur is not None and f is not self.cur and f.cost * self.mult < 2000]
			if fs and self.chance(0.6):
				# $self: this instance, its module data shared
				f = self.pick(fs)
				self.emit("if(%s != nil)" % m)
				self.emit("\tout(%d, %s);" % (tag, self.show(f.ret, "%s->%s(%s)" % (m, f.name, ", ".join(self.expr(p.t, 3) for p in f.params)))))
		self.costacc += 50

	def churn(self):
		# allocate in a loop, keeping some: the collector runs under compiled code
		r = self.r
		n = self.pick([100, 1000, 3000])
		lv = self.newname("k")
		iv = self.newname("i")
		hv = self.newname("h")
		self.emit("%s: list of ref A;" % lv)
		self.emit("%s := 0;" % hv)
		self.emit("for(%s := 0; %s < %d; %s++) {" % (iv, iv, n, iv))
		self.emit("\tt := ref A(%s, big %s, real %s, string %s + \"\\u00e9\", array[%s & 15] of {* => %s}, %s :: nil, nil);"
			% (iv, iv, iv, iv, iv, iv, iv))
		self.emit("\tif(%s %% %d == 0) %s = t :: %s;" % (iv, r.randint(1, 50), lv, lv))
		self.emit("\tif(%s != nil) t.n = hd %s;" % (lv, lv))
		self.emit("\ts := string t.b + t.s;")
		self.emit("\t%s += len s + len t.a;" % hv)
		self.emit("}")
		self.emit("for(; %s != nil; %s = tl %s) %s += (hd %s).i;" % (lv, lv, lv, hv, lv))
		self.emit("out(%d, string %s);" % (self.tag(), hv))
		self.costacc += n * 20

	# ---- functions and the module ----
	def function(self, f):
		self.cur = f
		self.lines = []
		self.ind = 1
		self.mult = 1
		self.costacc = 0
		self.scopes = [list(f.params)]
		self.stmts(self.r.randint(2, self.size), 0)
		ret = f.ret
		self.emit("return %s;" % self.expr(ret, 1))
		f.body = self.lines
		f.cost = max(1, self.costacc)
		self.cur = None

	def sig(self, f):
		return "%s(%s): %s" % (f.name, ", ".join("%s: %s" % (p.name, LTYPE[p.t]) for p in f.params), LTYPE[f.ret])

	def module(self):
		r = self.r
		nf = r.randint(3, 3 + self.size // 3)
		for i in range(nf):
			np = r.randint(0, 3)
			params = [Var(self.newname("p"), self.pick(TYPES)) for _ in range(np)]
			ret = self.pick(TYPES)
			pure = r.random() < 0.4
			if pure and r.random() < 0.6:
				params = [Var(self.newname("p"), "int")] + params
				ret = "int"
			f = Func("f%d" % i, params, ret, pure)
			f.spawned = False
			self.funcs.append(f)
		for t in TYPES:
			for _ in range(r.randint(0, 2)):
				self.globals.append(Var(self.newname("g"), t))
		for f in self.funcs:
			self.function(f)
		# the main body: a function of its own, so its exceptions are caught
		m = Func("main0", [], "int", False)
		self.function(m)
		self.mainf = m

		# init: say each global, call each impure function, load ourselves
		self.cur = None
		self.lines = []
		self.ind = 1
		self.mult = 1
		self.scopes = [[]]
		self.emit("sys = load Sys Sys->PATH;")
		for g in self.globals:
			self.emit("{ %s = %s; } exception { \"*\" => ; }" % (g.name, self.lit(g.t) if g.t in EDGE else self.e_new(g.t, 3)))
		for f in self.funcs:
			self.open_chunk()
			self.emit("{")
			self.emit("\tout(%d, %s);" % (self.tag(), self.show(f.ret, "%s(%s)" % (f.name, ", ".join(self.expr(p.t, 2) for p in f.params)))))
			self.emit("} exception e {")
			self.emit("\"*\" => out(%d, \"exc \" + e);" % self.tag())
			self.emit("}")
			self.close_chunk()
		self.emit("{ out(%d, string main0()); } exception e { \"*\" => out(%d, \"exc \" + e); }" % (self.tag(), self.tag()))
		if self.chance(0.7):
			self.open_chunk()
			self.emit("me := load Fz FZSELF;")
			self.emit("if(me == nil) out(%d, \"noload\"); else {" % self.tag())
			for f in self.r.sample(self.funcs, min(len(self.funcs), 3)):
				self.emit("\t{ out(%d, %s); } exception e { \"*\" => out(%d, \"exc \" + e); }"
					% (self.tag(), self.show(f.ret, "me->%s(%s)" % (f.name, ", ".join(self.expr(p.t, 3) for p in f.params))), self.tag()))
			if self.chance(0.5):
				self.emit("\tme = nil;")
			self.emit("}")
			self.close_chunk()
		initbody = self.lines

		o = []
		o.append("implement Fz;")
		o.append("")
		o.append("# disfuzz seed %d" % self.seed)
		o.append("include \"sys.m\";\n\tsys: Sys;")
		o.append("include \"draw.m\";")
		o.append("")
		o.append("Fz: module\n{")
		o.append("\tinit: fn(nil: ref Draw->Context, nil: list of string);")
		o.append("\texiter: fn(c: chan of int, v: int);")
		for f in self.funcs:
			a, b = self.sig(f).split("(", 1)
			o.append("\t%s: fn(%s;" % (a, b))
		o.append("};")
		o.append("")
		o.append("FZSELF: con \"%s\";" % self.selfpath)
		o.append("")
		o.append("A: adt {\n\ti: int;\n\tb: big;\n\tr: real;\n\ts: string;\n\ta: array of int;\n\tl: list of int;\n\tn: ref A;\n};")
		o.append("")
		for g in self.globals:
			o.append("%s: %s;" % (g.name, LTYPE[g.t]))
		o.append("B: adt {\n\ti: int;\n\ts: string;\n};")
		o.append("C: adt {\n\ti: int;\n\tr: real;\n};	# no pointers: consm, headm, newcm")
		o.append("P: adt {\n\tpick {\n\tI => i: int;\n\tS => s: string;\n\tR => r: real;\n\t}\n};")
		o.append(HELPERS)
		for t in sorted(self.senders):
			o.append("send%s(c: chan of %s, v: %s, n: int)\n{\n\tfor(i := 0; i < n; i++)\n\t\tc <-= v;\n}\n" % (t, LELT[t], LELT[t]))
		for f in self.funcs:
			o.append(self.sig(f))
			o.append("{")
			o.extend(f.body)
			o.append("}")
			o.append("")
			if getattr(f, "spawned", False):
				o.append("w%s(c: chan of int, %s)" % (f.name, ", ".join("%s: %s" % (p.name, LTYPE[p.t]) for p in f.params)))
				o.append("{")
				o.append("\tv := -1;")
				o.append("\t{ v = %s(%s); } exception { \"*\" => v = -2; }" % (f.name, ", ".join(p.name for p in f.params)))
				o.append("\tc <-= v;")
				o.append("}")
				o.append("")
		o.append("main0(): int")
		o.append("{")
		o.extend(self.mainf.body)
		o.append("}")
		o.append("")
		o.append("init(nil: ref Draw->Context, nil: list of string)")
		o.append("{")
		o.extend(initbody)
		o.append("\tout(0, \"done\");")
		o.append("}")
		return "\n".join(o) + "\n"


HELPERS = r'''
# a string the compiler cannot fold: it refuses int "12x" at compile time,
# which the VM makes 12
sid(s: string): string
{
	if(zs != nil)
		return zs;
	return s;
}

# nil, typed: globals never assigned, and functions returning it, which
# limbo inlines (it once inlined them as an untyped nil and failed on
# len, tl and an index of it)
nA(): ref A { return nil; }
nai(): array of int { return nil; }
nl(): list of int { return nil; }
zA: ref A;
zs: string;
zn: int;
zai: array of int;
zl: list of int;
out(tag: int, s: string)
{
	sys->print("%d %s\n", tag, s);
}

# a string, quoted, with what is not printable ASCII as its code
qs(s: string): string
{
	if(s == nil)
		return "nil";
	r := "\"";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 16r20 && c < 16r7f && c != '"' && c != '\\')
			r[len r] = c;
		else
			r += sys->sprint("\\%ux", c);
	}
	return r + "\"";
}

as(a: array of int): string
{
	if(a == nil)
		return "nil";
	r := sys->sprint("[%d]", len a);
	for(i := 0; i < len a && i < 16; i++)
		r += " " + string a[i];
	return r;
}

bs(a: array of byte): string
{
	if(a == nil)
		return "nil";
	r := sys->sprint("[%d]", len a);
	for(i := 0; i < len a && i < 16; i++)
		r += " " + string int a[i];
	return r;
}

ls(l: list of int): string
{
	r := "(";
	for(n := 0; l != nil && n < 16; l = tl l){
		r += " " + string hd l;
		n++;
	}
	return r + " )";
}

As(a: ref A, depth: int): string
{
	if(a == nil)
		return "nil";
	if(depth == 0)
		return "...";
	return sys->sprint("A(%d %bd %s %s %s %s %s)", a.i, a.b, string a.r, qs(a.s), as(a.a), ls(a.l), As(a.n, depth-1));
}

# a string of n runes from a few planes
rs(n: int): string
{
	n &= 63;
	s := "";
	for(i := 0; i < n; i++)
		case i % 4 {
		0 => s[len s] = 'a' + i;
		1 => s[len s] = 16r00e0 + i;
		2 => s[len s] = 16r4e00 + i;
		* => s[len s] = 16r1F600 + i;
		}
	return s;
}

Bs(b: B): string
{
	return sys->sprint("B(%d %s)", b.i, qs(b.s));
}

Cs(c: C): string
{
	return sys->sprint("C(%d %s)", c.i, string c.r);
}

Ts(t: (int, string, big)): string
{
	(a, b, c) := t;
	return sys->sprint("T(%d %s %bd)", a, qs(b), c);
}

tf(x: int): (int, string, big)
{
	return (x, string x, big x * big 3);
}

rf1(x: int): int
{
	return x + 1;
}

rf2(x: int): int
{
	return x * 2;
}

# a Prog that sends, then exits
exiter(c: chan of int, v: int)
{
	c <-= v;
	exit;
}

# recursion n deep: the stack grown, then given back
deep(n: int, x: int): int
{
	if(n <= 0)
		return x;
	a := array[2] of {* => x};
	return deep(n-1, x + 1) + a[1] - x;
}
'''


def main():
	ap = argparse.ArgumentParser(description="random Limbo programs for disfuzz")
	ap.add_argument("-s", "--seed", type=int, default=1)
	ap.add_argument("-p", "--selfpath", default="/tmp/disfuzz/fz.dis")
	ap.add_argument("-z", "--size", type=int, default=12)
	a = ap.parse_args()
	sys.stdout.write(Gen(a.seed, a.selfpath, a.size).module())


if __name__ == "__main__":
	main()
