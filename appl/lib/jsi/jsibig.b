#
# jsibig.b - BigInt: values whose object holds keyring's IPint.  The
# division, shift and bitwise rules follow appl/lib/js/jsbigint.b's.
#

NBigInt, NBasintn, NBasuintn, NBiPtolocale, NBiPtostring, NBiPvalueof: con Nbigbase + iota;

biginit()
{
	c := defctor("BigInt", NBigInt, 1, bigproto);
	defmethod(c, "asIntN", NBasintn, 2);
	defmethod(c, "asUintN", NBasuintn, 2);
	p := bigproto;
	defmethod(p, "toLocaleString", NBiPtolocale, 0);
	defmethod(p, "toString", NBiPtostring, 0);
	defmethod(p, "valueOf", NBiPvalueof, 0);
	defprop(p, a_symtostringtag, strv("BigInt"), Aconf);
}

kr(): Keyring
{
	if(keyring == nil)
		keyring = load Keyring Keyring->PATH;
	if(keyring == nil)
		throwerr(EError, "BigInt: cannot load keyring");
	return keyring;
}

ipof(o: ref Obj): ref IPint
{
	pick d := o.data {
	Big =>
		return d.b;
	}
	return nil;
}

bigval(i: ref IPint): V
{
	o := ref Obj;
	o.cls = Cbigint;
	o.data = ref Data.Big(i);
	return V(Tbig, 0, 0.0, nil, o);
}

bigfromint(i: int): V
{
	kr();
	return bigval(IPint.inttoip(i));
}

bigfromstr(s: string): V
{
	kr();
	return bigval(IPint.strtoip(s, 10));
}

bigstr(o: ref Obj, radix: int): string
{
	i := ipof(o);
	if(radix == 10) {
		s := i.iptostr(10);
		if(s == "" || s == "-0")
			s = "0";
		return s;
	}
	neg := i.cmp(IPint.inttoip(0)) < 0;
	if(neg)
		i = i.neg();
	s := "";
	r := IPint.inttoip(radix);
	zero := IPint.inttoip(0);
	if(i.cmp(zero) == 0)
		return "0";
	# by chunks of digits a machine int holds
	chunk := 1;
	p := radix;
	while(p * radix < 1000000) {
		p *= radix;
		chunk++;
	}
	rp := IPint.inttoip(p);
	while(i.cmp(zero) > 0) {
		(q, rem) := i.div(rp);
		d := rem.iptoint();
		for(k := 0; k < chunk; k++) {
			s[len s] = digitchars[d % radix];
			d /= radix;
			if(q.cmp(zero) == 0 && d == 0)
				break;
		}
		i = q;
	}
	r = r;
	t := "";
	if(neg)
		t = "-";
	for(k := len s - 1; k >= 0; k--)
		t[len t] = s[k];
	return t;
}

bigzero(o: ref Obj): int
{
	return ipof(o).cmp(IPint.inttoip(0)) == 0;
}

bigcmp(a, b: ref Obj): int
{
	return ipof(a).cmp(ipof(b));
}

# a BigInt literal's digits (0x, 0o, 0b, or decimal; separators gone) as decimal
bigdecstr(digits: string): string
{
	kr();
	d := "";
	for(i := 0; i < len digits; i++)
		if(digits[i] != '_' && digits[i] != 'n')
			d[len d] = digits[i];
	base := 10;
	if(len d > 2 && d[0] == '0') {
		case d[1] {
		'x' or 'X' => base = 16;
		'o' or 'O' => base = 8;
		'b' or 'B' => base = 2;
		}
		if(base != 10)
			d = d[2:];
	}
	if(base == 10)
		return IPint.strtoip(d, 10).iptostr(10);
	return parsebase(d, base).iptostr(10);
}

parsebase(d: string, base: int): ref IPint
{
	r := IPint.inttoip(0);
	b := IPint.inttoip(base);
	for(i := 0; i < len d; i++)
		r = r.mul(b).add(IPint.inttoip(digitval(d[i])));
	return r;
}

bigliteral(digits: string): V
{
	return bigfromstr(digits);
}

# StringToBigInt: (ok, value)
strtobig(s: string): (int, ref Obj)
{
	kr();
	s = trimws(s, 1, 1);
	if(s == "")
		return (1, bigfromint(0).o);
	base := 10;
	neg := 0;
	if(len s > 2 && s[0] == '0') {
		case s[1] {
		'x' or 'X' => base = 16;
		'o' or 'O' => base = 8;
		'b' or 'B' => base = 2;
		}
		if(base != 10)
			s = s[2:];
	}
	if(base == 10 && len s > 0 && (s[0] == '+' || s[0] == '-')) {
		neg = s[0] == '-';
		s = s[1:];
	}
	if(s == "")
		return (0, nil);
	for(i := 0; i < len s; i++) {
		d := digitval(s[i]);
		if(d < 0 || d >= base)
			return (0, nil);
	}
	r := parsebase(s, base);
	if(neg)
		r = r.neg();
	return (1, bigval(r).o);
}

# the exact value of a finite integral real as an IPint
realtoip(x: real): ref IPint
{
	kr();
	neg := x < 0.0;
	if(neg)
		x = -x;
	# the mantissa and exponent from the bits
	bits := math->realbits64(x);
	ex := int ((bits >> 52) & big 16r7FF);
	m := bits & ((big 1 << 52) - big 1);
	e: int;
	if(ex == 0)
		e = -1074;
	else {
		m |= big 1 << 52;
		e = ex - 1075;
	}
	r := IPint.strtoip(string m, 10);
	if(e > 0)
		r = r.shl(e);
	else if(e < 0)
		r = r.shr(0 - e);
	if(neg)
		r = r.neg();
	return r;
}

bigtonum(o: ref Obj): real
{
	return decimal(bigstr(o, 10));
}

# a BigInt == a number
bigeqnum(o: ref Obj, x: real): int
{
	if(isnan(x) || x == inf || x == -inf || trunc(x) != x)
		return 0;
	return ipof(o).cmp(realtoip(x)) == 0;
}

# a BigInt < a number: 1, 0, or -1 (NaN)
bigcmpnum(o: ref Obj, x: real): int
{
	if(isnan(x))
		return -1;
	if(x == inf)
		return 1;
	if(x == -inf)
		return 0;
	f := math->floor(x);
	c := ipof(o).cmp(realtoip(f));
	if(c < 0)
		return 1;
	if(c == 0)
		return f < x;
	return 0;
}

bigneg(o: ref Obj): V
{
	return bigval(ipof(o).neg());
}

bignot(o: ref Obj): V
{
	# ~x == -x - 1
	return bigval(ipof(o).neg().sub(IPint.inttoip(1)));
}

absip(x: ref IPint): ref IPint
{
	if(x.cmp(IPint.inttoip(0)) < 0)
		return x.neg();
	return x;
}

bigop(o: int, a, b: ref Obj): V
{
	kr();
	x := ipof(a);
	y := ipof(b);
	zero := IPint.inttoip(0);
	case o {
	Nadd =>
		return bigval(x.add(y));
	Nsub =>
		return bigval(x.sub(y));
	Nmul =>
		return bigval(x.mul(y));
	Ndiv or Nmod =>
		if(y.cmp(zero) == 0)
			throwerr(ERange, "Division by zero");
		(q, r) := absip(x).div(absip(y));
		if(o == Ndiv) {
			if((x.cmp(zero) < 0) != (y.cmp(zero) < 0))
				q = q.neg();
			return bigval(q);
		}
		if(x.cmp(zero) < 0)
			r = r.neg();
		return bigval(r);
	Nexp =>
		if(y.cmp(zero) < 0)
			throwerr(ERange, "Exponent must be non-negative");
		if(y.bits() > 31)
			throwerr(ERange, "Maximum BigInt size exceeded");
		e := y.iptoint();
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
				throwerr(ERange, "Maximum BigInt size exceeded");
		}
		return bigval(r);
	Nshl or Nshr =>
		n := y;
		left := o == Nshl;
		if(n.cmp(zero) < 0) {
			n = n.neg();
			left = !left;
		}
		if(n.bits() > 30) {
			if(left && x.cmp(zero) != 0)
				throwerr(ERange, "Maximum BigInt size exceeded");
			if(x.cmp(zero) < 0)
				return bigfromint(-1);
			return bigfromint(0);
		}
		k := n.iptoint();
		if(left)
			return bigval(x.mul(IPint.inttoip(1).shl(k)));
		d := IPint.inttoip(1).shl(k);
		(q, r) := absip(x).div(d);
		if(x.cmp(zero) < 0) {
			q = q.neg();
			if(r.cmp(zero) != 0)
				q = q.sub(IPint.inttoip(1));
		}
		return bigval(q);
	Nushr =>
		throwtype("BigInts have no unsigned right shift, use >> instead");
	Nband or Nbor or Nbxor =>
		w := x.bits();
		if(y.bits() > w)
			w = y.bits();
		w += 2;
		m := IPint.inttoip(1).shl(w);
		ux := x;
		if(ux.cmp(zero) < 0)
			ux = ux.add(m);
		uy := y;
		if(uy.cmp(zero) < 0)
			uy = uy.add(m);
		r: ref IPint;
		case o {
		Nband => r = ux.and(uy);
		Nbor => r = ux.ori(uy);
		* => r = ux.xor(uy);
		}
		half := IPint.inttoip(1).shl(w - 1);
		if(r.cmp(half) >= 0)
			r = r.sub(m);
		return bigval(r);
	}
	throwtype("Unsupported BigInt operation");
	return undef;
}

# ToBigInt
tobigint(v: V): V
{
	p := toprim(v, Hnumber);
	case p.t {
	Tbig =>
		return p;
	Tbool =>
		return bigfromint(p.i);
	Tstr or Trope =>
		(ok, b) := strtobig(flat(p));
		if(!ok)
			throwerr(ESyntax, "Cannot convert " + flat(p) + " to a BigInt");
		return V(Tbig, 0, 0.0, nil, b);
	Tundef or Tnull =>
		throwtype("Cannot convert " + tostr(p) + " to a BigInt");
	Tint or Tnum =>
		throwtype("Cannot convert " + tostr(p) + " to a BigInt");
	Tsym =>
		throwtype("Cannot convert a Symbol value to a BigInt");
	}
	throwtype("Cannot convert to a BigInt");
	return undef;
}

numbig(x: real): V
{
	if(isnan(x) || x == inf || x == -inf || trunc(x) != x)
		throwerr(ERange, "The number " + numstr(x) + " cannot be converted to a BigInt because it is not an integer");
	return bigval(realtoip(x));
}

bigwrap(x: ref IPint, bits: int, signed: int): V
{
	if(bits == 0)
		return bigfromint(0);
	m := IPint.inttoip(1).shl(bits);
	r := x.mod(m);
	if(r.cmp(IPint.inttoip(0)) < 0)
		r = r.add(m);
	if(signed) {
		half := IPint.inttoip(1).shl(bits - 1);
		if(r.cmp(half) >= 0)
			r = r.sub(m);
	}
	return bigval(r);
}

natbig(id: int, nil: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	kr();
	case id {
	NBigInt =>
		if(nt != nil)
			throwtype("BigInt is not a constructor");
		p := toprim(arg(args, 0), Hnumber);
		if(isnum(p))
			return numbig(numof(p));
		return tobigint(p);
	NBasintn or NBasuintn =>
		bits := toindex(arg(args, 0));
		b := tobigint(arg(args, 1));
		return bigwrap(ipof(b.o), bits, id == NBasintn);
	NBiPvalueof =>
		return thisprim(this, Cbigint, Tbig, "BigInt.prototype.valueOf");
	NBiPtolocale =>
		b := thisprim(this, Cbigint, Tbig, "BigInt.prototype.toLocaleString");
		return strv(bigstr(b.o, 10));
	NBiPtostring =>
		b := thisprim(this, Cbigint, Tbig, "BigInt.prototype.toString");
		r := 10;
		if(arg(args, 0).t != Tundef) {
			rx := tointeger(args[0]);
			if(rx < 2.0 || rx > 36.0)
				throwerr(ERange, "toString() radix must be between 2 and 36");
			r = int rx;
		}
		return strv(bigstr(b.o, r));
	}
	return undef;
}
