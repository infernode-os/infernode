#
# jsbigint.b - BigInt (ECMAScript 2025 §21.2, §6.1.6.2).  Included by js.b.
#
# A BigInt value is its canonical decimal digits (with a leading - when
# negative), in a string row; arithmetic converts to keyring's IPint.
#

bigintinit()
{
	ibigproto = keep(newobj(Kord, iobjproto));
	c := ctor("BigInt", 1, bigintctor, ibigproto);
	method(c, "asIntN", 2, bigint_asintn);
	method(c, "asUintN", 2, bigint_asuintn);
	p := ibigproto;
	method(p, "toLocaleString", 0, bigproto_tolocalestring);
	method(p, "toString", 0, bigproto_tostring);
	method(p, "valueOf", 0, bigproto_valueof);
	tag(p, "BigInt");
}

ip(): Keyring
{
	if(keyring == nil)
		keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		throwerr(Error, "BigInt: cannot load keyring");
	return keyring;
}

toip(v: V): ref IPint
{
	ip();
	return IPint.strtoip(str(v.x), 10);
}

fromip(i: ref IPint): V
{
	s := i.iptostr(10);
	if(s == "" || s == "-0")
		s = "0";
	h := newstr(s);
	return V(Tbig, h, 0.0);
}

bigv(s: string): V
{
	h := newstr(s);
	return V(Tbig, h, 0.0);
}

bigsign(v: V): int
{
	s := str(v.x);
	if(s == "0")
		return 0;
	if(s[0] == '-')
		return -1;
	return 1;
}

# ToBigInt
tobigint(v: V): V
{
	p := toprim(v, 1);
	case p.t {
	Tbig =>
		return p;
	Tbool =>
		return bigfromint(p.x);
	Tstr =>
		(ok, b) := strbig(str(p.x));
		if(!ok)
			throwerr(SyntaxError, "cannot convert " + show(p) + " to a BigInt");
		return b;
	Tundef or Tnull =>
		typeerr("cannot convert " + show(p) + " to a BigInt");
	Tnum =>
		typeerr("cannot convert a Number to a BigInt implicitly");
	Tsym =>
		typeerr("cannot convert a Symbol value to a BigInt");
	}
	typeerr("cannot convert to a BigInt");
	return undef;
}

# NumberToBigInt
numbig(x: real): V
{
	if(isnan(x) || x == inf || x == -inf || trunc(x) != x)
		throwerr(RangeError, "the number " + numstr(x) + " cannot be converted to a BigInt because it is not an integer");
	if(x > -9.2e18 && x < 9.2e18)
		return bigv(string big x);
	# exactly: the double's digits
	return bigv(sys->sprint("%.0f", x));
}

bigintctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t != Tundef)
		typeerr("BigInt is not a constructor");
	v := arg(a, n, 0);
	p := toprim(v, 1);
	if(p.t == Tnum)
		return numbig(p.n);
	return tobigint(p);
}

# BigInt to a Number (for Number(x))
bignum(v: V): real
{
	return decimal(str(v.x));
}

# the low bits of x, as a signed (asintn) or unsigned value
bigwrap(x: V, bits: real, signed: int): V
{
	if(bits == 0.0)
		return bigfromint(0);
	ip();
	i := toip(x);
	m := IPint.inttoip(1).shl(int bits);
	r := i.mod(m);
	if(r.cmp(IPint.inttoip(0)) < 0)
		r = r.add(m);
	if(signed) {
		half := IPint.inttoip(1).shl(int bits - 1);
		if(r.cmp(half) >= 0)
			r = r.sub(m);
	}
	return fromip(r);
}

bigint_asintn(nil: V, a, n: int, nil: V, nil: int): V
{
	bits := toindex(arg(a, n, 0));
	b := tobigint(arg(a, n, 1));
	return bigwrap(b, bits, 1);
}

bigint_asuintn(nil: V, a, n: int, nil: V, nil: int): V
{
	bits := toindex(arg(a, n, 0));
	b := tobigint(arg(a, n, 1));
	return bigwrap(b, bits, 0);
}

thisbig(this: V, name: string): V
{
	return thisprim(this, Tbig, "BigInt.prototype." + name);
}

bigproto_valueof(this: V, nil, nil: int, nil: V, nil: int): V
{
	return thisbig(this, "valueOf");
}

bigproto_tolocalestring(this: V, nil, nil: int, nil: V, nil: int): V
{
	b := thisbig(this, "toLocaleString");
	return V(Tstr, b.x, 0.0);
}

bigproto_tostring(this: V, a, n: int, nil: V, nil: int): V
{
	b := thisbig(this, "toString");
	r := 10;
	if(arg(a, n, 0).t != Tundef) {
		rx := tointorinf(vs[a]);
		if(rx < 2.0 || rx > 36.0)
			throwerr(RangeError, "toString() radix must be between 2 and 36");
		r = int rx;
	}
	if(r == 10)
		return V(Tstr, b.x, 0.0);
	s := str(b.x);
	neg := s[0] == '-';
	if(neg)
		s = s[1:];
	# repeated division of the decimal digits
	out := "";
	ds := s;
	while(ds != "0") {
		(q, rem) := decdivsmall(ds, r);
		out[len out] = digitchars[rem];
		ds = q;
	}
	if(out == "")
		out = "0";
	t := "";
	if(neg)
		t = "-";
	for(i := len out - 1; i >= 0; i--)
		t[len t] = out[i];
	return strv(t);
}

# a non-negative decimal string divided by a small number
decdivsmall(s: string, d: int): (string, int)
{
	q := "";
	rem := 0;
	for(i := 0; i < len s; i++) {
		x := rem * 10 + s[i] - '0';
		q[len q] = '0' + x / d;
		rem = x % d;
	}
	k := 0;
	while(k < len q - 1 && q[k] == '0')
		k++;
	return (q[k:], rem);
}

# the binary operators on two BigInts
bigarith(op: int, a, b: V): V
{
	if(a.t != Tbig || b.t != Tbig)
		typeerr("cannot mix BigInt and other types, use explicit conversions");
	ip();
	x := toip(a);
	y := toip(b);
	zero := IPint.inttoip(0);
	case op {
	Osub =>
		return fromip(x.sub(y));
	Omul =>
		return fromip(x.mul(y));
	Odiv or Omod =>
		if(y.cmp(zero) == 0)
			throwerr(RangeError, "division by zero");
		# truncated toward zero, whatever the library's rounding
		ax := absip(x);
		ay := absip(y);
		(q, r) := ax.div(ay);
		neg := (x.cmp(zero) < 0) != (y.cmp(zero) < 0);
		if(op == Odiv) {
			if(neg)
				q = q.neg();
			return fromip(q);
		}
		if(x.cmp(zero) < 0)
			r = r.neg();
		return fromip(r);
	Oexp =>
		if(y.cmp(zero) < 0)
			throwerr(RangeError, "exponent must be non-negative");
		e := y.iptoint();
		if(y.bits() > 31)
			throwerr(RangeError, "maximum BigInt size exceeded");
		if(x.cmp(zero) == 0 && e != 0)
			return bigfromint(0);
		r := IPint.inttoip(1);
		base := x;
		while(e > 0) {
			if(e & 1)
				r = r.mul(base);
			e >>= 1;
			if(e > 0)
				base = base.mul(base);
			if(r.bits() > 1000000)
				throwerr(RangeError, "maximum BigInt size exceeded");
		}
		return fromip(r);
	Oshl or Oshr =>
		n := y;
		left := op == Oshl;
		if(n.cmp(zero) < 0) {
			n = n.neg();
			left = !left;
		}
		if(n.bits() > 30) {
			if(left)
				throwerr(RangeError, "maximum BigInt size exceeded");
			if(x.cmp(zero) < 0)
				return bigfromint(-1);
			return bigfromint(0);
		}
		k := n.iptoint();
		if(left)
			return fromip(x.mul(IPint.inttoip(1).shl(k)));
		# arithmetic shift right: floor division by 2^k
		d := IPint.inttoip(1).shl(k);
		(q, r) := absip(x).div(d);
		if(x.cmp(zero) < 0) {
			q = q.neg();
			if(r.cmp(zero) != 0)
				q = q.sub(IPint.inttoip(1));
		}
		return fromip(q);
	Oushr =>
		typeerr("BigInts have no unsigned right shift, use >> instead");
	Oband or Obor or Obxor =>
		return fromip(bitwise(op, x, y));
	}
	typeerr("unsupported BigInt operation");
	return undef;
}

absip(x: ref IPint): ref IPint
{
	if(x.cmp(IPint.inttoip(0)) < 0)
		return x.neg();
	return x;
}

# two's complement bitwise operations, on a width that holds both
bitwise(op: int, x, y: ref IPint): ref IPint
{
	w := x.bits();
	if(y.bits() > w)
		w = y.bits();
	w += 2;
	m := IPint.inttoip(1).shl(w);
	zero := IPint.inttoip(0);
	ux := x;
	if(ux.cmp(zero) < 0)
		ux = ux.add(m);
	uy := y;
	if(uy.cmp(zero) < 0)
		uy = uy.add(m);
	r: ref IPint;
	case op {
	Oband => r = ux.and(uy);
	Obor => r = ux.ori(uy);
	* => r = ux.xor(uy);
	}
	half := IPint.inttoip(1).shl(w - 1);
	if(r.cmp(half) >= 0)
		r = r.sub(m);
	return r;
}
