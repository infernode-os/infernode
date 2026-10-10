#
# jsobj.b - the object internal methods (ECMAScript 2025 §10), errors,
# type conversions (§7.1) and comparisons (§7.2).  Included by js.b.
#

# ---- errors ----

Error, EvalError, RangeError, ReferenceError, SyntaxError, TypeError, URIError, AggregateError: con iota;

# the exception being thrown, while "js:throw" propagates
thrown: V;

throwv(v: V)
{
	thrown = v;
	raise "js:throw";
}

throwerr(kind: int, msg: string)
{
	throwv(objv(newerror(kind, msg)));
}

newerror(kind: int, msg: string): int
{
	h := newobj(Kerror, ierrorprotos[kind]);
	if(msg != nil)
		defown(h, amessage, Awrite | Aconf, strv(msg));
	odata[h] = ref Data.Error(nil);
	return h;
}

typeerr(msg: string)
{
	throwerr(TypeError, msg);
}

# a value, briefly, for messages
show(v: V): string
{
	case v.t {
	Tundef => return "undefined";
	Tnull => return "null";
	Tbool =>
		if(v.x)
			return "true";
		return "false";
	Tnum => return numstr(v.n);
	Tstr =>
		s := str(v.x);
		if(len s > 40)
			s = s[0:40] + "...";
		return "\"" + s + "\"";
	Tsym => return "Symbol(" + atomstr[v.x] + ")";
	Tbig => return str(v.x) + "n";
	Tobj =>
		if(iscallable(v))
			return "function " + fnname(v.x);
		if(okind[v.x] == Karray)
			return "array";
		return "object";
	}
	return "value";
}

fnname(h: int): string
{
	(ok, v, nil) := getownprop(h, aname);
	if(ok && v.t == Tstr)
		return str(v.x);
	return "";
}

# ---- object predicates ----

iscallable(v: V): int
{
	return v.t == Tobj && (oflags[v.x] & Ocallable) != 0;
}

isctor(v: V): int
{
	return v.t == Tobj && (oflags[v.x] & Octor) != 0;
}

isarray(v: V): int
{
	if(v.t != Tobj)
		return 0;
	h := v.x;
	if(okind[h] == Karray)
		return 1;
	if(okind[h] == Kproxy) {
		pick p := odata[h] {
		Proxy =>
			if(p.handler < 0)
				typeerr("proxy has been revoked");
			return isarray(objv(p.target));
		}
	}
	return 0;
}

# ---- [[GetPrototypeOf]], [[SetPrototypeOf]], [[IsExtensible]], [[PreventExtensions]] ----

getproto(h: int): int
{
	if(okind[h] == Kproxy)
		return proxygetproto(h);
	return oproto[h];
}

setproto(h, p: int): int
{
	if(okind[h] == Kproxy)
		return proxysetproto(h, p);
	if(oproto[h] == p)
		return 1;
	if(okind[h] == Kmodns)
		return 0;
	if((oflags[h] & Oext) == 0)
		return 0;
	if(h == iobjproto && 0)
		return 0;
	for(q := p; q >= 0; q = oproto[q]) {
		if(q == h)
			return 0;
		if(okind[q] == Kproxy)
			break;
	}
	oproto[h] = p;
	return 1;
}

isext(h: int): int
{
	if(okind[h] == Kproxy)
		return proxyisext(h);
	return (oflags[h] & Oext) != 0;
}

preventext(h: int): int
{
	if(okind[h] == Kproxy)
		return proxypreventext(h);
	if(okind[h] == Ktyped && typedvariable(h))
		return 0;
	oflags[h] &= ~Oext;
	return 1;
}

# ---- [[GetOwnProperty]] ----

# a property descriptor; fields not present have their bit clear in has
Desc: adt {
	has:	int;
	value:	V;
	get, set:	V;
	attrs:	int;	# Awrite, Aenum, Aconf where present
};

Hvalue, Hwrite, Hget, Hset, Henum, Hconf: con 1 << iota;

# (found, descriptor)
getown(h, k: int): (int, ref Desc)
{
	case okind[h] {
	Kproxy =>
		return proxygetown(h, k);
	Kargs =>
		return argsgetown(h, k);
	Kmodns =>
		return modnsgetown(h, k);
	}
	(ok, v, a) := getownprop(h, k);
	if(!ok)
		return (0, nil);
	if(a & Aacc) {
		g := undef;
		s := undef;
		if(v.x >= 0)
			g = objv(v.x);
		if(v.n >= 0.0)
			s = objv(int v.n);
		return (1, ref Desc(Hget|Hset|Henum|Hconf, undef, g, s, a & (Aenum|Aconf)));
	}
	return (1, ref Desc(Hvalue|Hwrite|Henum|Hconf, v, undef, undef, a & (Awrite|Aenum|Aconf)));
}

isaccdesc(d: ref Desc): int
{
	return (d.has & (Hget|Hset)) != 0;
}

isdatadesc(d: ref Desc): int
{
	return (d.has & (Hvalue|Hwrite)) != 0;
}

# ---- [[DefineOwnProperty]] ----

defineown(h, k: int, d: ref Desc): int
{
	case okind[h] {
	Kproxy =>
		return proxydefine(h, k, d);
	Karray =>
		if(k == alength)
			return arraysetlength(h, d);
		ix := keyindex(k);
		if(ix >= 0.0) {
			if(ix >= oalen[h] && (oflags[h] & Oarrlenro))
				return 0;
			if(!ordinarydefine(h, k, d))
				return 0;
			if(ix >= oalen[h])
				oalen[h] = ix + 1.0;
			return 1;
		}
	Kargs =>
		return argsdefine(h, k, d);
	Kprim =>
		pick p := odata[h] {
		Prim =>
			if(p.v.t == Tstr) {
				ix := keyindex(k);
				if(ix >= 0.0 && ix < real slen[p.v.x] || k == alength) {
					(nil, cur) := getown(h, k);
					return compatible(0, d, cur);
				}
			}
		}
	Ktyped =>
		if(isidx(k) || atomidx[k] >= 0.0)
			return typeddefine(h, k, d);
	Kmodns =>
		return modnsdefine(h, k, d);
	}
	return ordinarydefine(h, k, d);
}

ordinarydefine(h, k: int, d: ref Desc): int
{
	(found, cur) := getown(h, k);
	ext := (oflags[h] & Oext) != 0;
	if(!found) {
		if(!ext)
			return 0;
		if(isaccdesc(d)) {
			a := Aacc;
			if(d.has & Henum)
				a |= d.attrs & Aenum;
			if(d.has & Hconf)
				a |= d.attrs & Aconf;
			defown(h, k, a, accv(d.get, d.set));
		} else {
			a := 0;
			if(d.has & Hwrite)
				a |= d.attrs & Awrite;
			if(d.has & Henum)
				a |= d.attrs & Aenum;
			if(d.has & Hconf)
				a |= d.attrs & Aconf;
			v := undef;
			if(d.has & Hvalue)
				v = d.value;
			defown(h, k, a, v);
		}
		return 1;
	}
	if(!compatible(ext, d, cur))
		return 0;
	# apply
	if(isaccdesc(d) && isdatadesc(cur) || isdatadesc(d) && isaccdesc(cur)) {
		a := cur.attrs & (Aenum|Aconf);
		if(d.has & Henum)
			a = a & ~Aenum | d.attrs & Aenum;
		if(d.has & Hconf)
			a = a & ~Aconf | d.attrs & Aconf;
		if(isaccdesc(d)) {
			g := undef;
			s := undef;
			if(d.has & Hget)
				g = d.get;
			if(d.has & Hset)
				s = d.set;
			defown(h, k, a | Aacc, accv(g, s));
		} else {
			v := undef;
			if(d.has & Hvalue)
				v = d.value;
			if(d.has & Hwrite)
				a |= d.attrs & Awrite;
			defown(h, k, a, v);
		}
		return 1;
	}
	a := cur.attrs;
	if(d.has & Henum)
		a = a & ~Aenum | d.attrs & Aenum;
	if(d.has & Hconf)
		a = a & ~Aconf | d.attrs & Aconf;
	if(isaccdesc(cur)) {
		g := cur.get;
		s := cur.set;
		if(d.has & Hget)
			g = d.get;
		if(d.has & Hset)
			s = d.set;
		defown(h, k, a | Aacc, accv(g, s));
	} else {
		if(d.has & Hwrite)
			a = a & ~Awrite | d.attrs & Awrite;
		v := cur.value;
		if(d.has & Hvalue)
			v = d.value;
		defown(h, k, a, v);
	}
	return 1;
}

accv(g, s: V): V
{
	gx := -1;
	sx := -1.0;
	if(g.t == Tobj)
		gx = g.x;
	if(s.t == Tobj)
		sx = real s.x;
	return V(Tacc, gx, sx);
}

# ValidateAndApplyPropertyDescriptor's checks, for an existing property
compatible(ext: int, d: ref Desc, cur: ref Desc): int
{
	if(cur == nil)
		return ext;
	if(d.has == 0)
		return 1;
	if((cur.attrs & Aconf) == 0) {
		if((d.has & Hconf) && (d.attrs & Aconf))
			return 0;
		if((d.has & Henum) && (d.attrs & Aenum) != (cur.attrs & Aenum))
			return 0;
		if(!isgenericdesc(d) && isaccdesc(d) != isaccdesc(cur))
			return 0;
		if(isaccdesc(cur)) {
			if((d.has & Hget) && !samevalue(d.get, cur.get))
				return 0;
			if((d.has & Hset) && !samevalue(d.set, cur.set))
				return 0;
		} else if((cur.attrs & Awrite) == 0) {
			if((d.has & Hwrite) && (d.attrs & Awrite))
				return 0;
			if((d.has & Hvalue) && !samevalue(d.value, cur.value))
				return 0;
		}
	}
	return 1;
}

isgenericdesc(d: ref Desc): int
{
	return !isaccdesc(d) && !isdatadesc(d);
}

datadesc(v: V, attrs: int): ref Desc
{
	return ref Desc(Hvalue|Hwrite|Henum|Hconf, v, undef, undef, attrs);
}

# array length (§10.4.2.4)
arraysetlength(h: int, d: ref Desc): int
{
	if((d.has & Hvalue) == 0) {
		if((d.has & Hconf) && (d.attrs & Aconf))
			return 0;
		if((d.has & Henum) && (d.attrs & Aenum))
			return 0;
		if(isaccdesc(d))
			return 0;
		if((d.has & Hwrite) && (d.attrs & Awrite) && (oflags[h] & Oarrlenro))
			return 0;
		if((d.has & Hwrite) && (d.attrs & Awrite) == 0)
			oflags[h] |= Oarrlenro;
		return 1;
	}
	newlen := touint32(d.value);
	if(newlen != tonumber(d.value))
		throwerr(RangeError, "invalid array length");
	if((d.has & Hconf) && (d.attrs & Aconf) || (d.has & Henum) && (d.attrs & Aenum) || isaccdesc(d))
		return 0;
	ro := (oflags[h] & Oarrlenro) != 0;
	if(newlen == oalen[h]) {
		if(ro && (d.has & Hwrite) && (d.attrs & Awrite))
			return 0;
		if((d.has & Hwrite) && (d.attrs & Awrite) == 0)
			oflags[h] |= Oarrlenro;
		return 1;
	}
	if(ro)
		return 0;
	ok := truncate(h, newlen);
	if((d.has & Hwrite) && (d.attrs & Awrite) == 0)
		oflags[h] |= Oarrlenro;
	return ok;
}

# shorten array h to n, deleting from the end; stops at a non-configurable element
truncate(h: int, n: real): int
{
	if(n < oalen[h]) {
		if(n < real onelem[h]) {
			ni := int n;
			e := oelems[h];
			for(i := ni; i < onelem[h]; i++)
				e[i] = empty;
			onelem[h] = ni;
		}
		if(oflags[h] & Oidxprops) {
			# the shape's index keys at or above n, highest first
			sh := oshape[h];
			idx: list of (real, int);
			for(i := 0; i < sh.n; i++) {
				ix := keyindex(sh.keys[i]);
				if(ix >= n)
					idx = (ix, sh.keys[i]) :: idx;
			}
			ks := sortidx(idx);
			for(j := len ks - 1; j >= 0; j--) {
				slot := slotof(oshape[h], ks[j]);
				if((oshape[h].attrs[slot] & Aconf) == 0) {
					oalen[h] = keyindex(ks[j]) + 1.0;
					return 0;
				}
				removeown(h, ks[j]);
			}
		}
	}
	oalen[h] = n;
	return 1;
}

# ---- [[HasProperty]], [[Get]], [[Set]], [[Delete]] ----

hasprop(h, k: int): int
{
	for(;;) {
		case okind[h] {
		Kproxy =>
			return proxyhas(h, k);
		Ktyped =>
			if(isidx(k) || atomidx[k] >= 0.0)
				return typedhas(h, k);
		}
		(found, nil) := getown(h, k);
		if(found)
			return 1;
		h = getproto(h);
		if(h < 0)
			return 0;
	}
}

hasown(h, k: int): int
{
	(found, nil) := getown(h, k);
	return found;
}

get(h, k: int, recv: V): V
{
	for(;;) {
		case okind[h] {
		Kord or Karray or Kfunc or Knative or Kerror =>
			(ok, v, a) := getownprop(h, k);
			if(ok) {
				if(a & Aacc) {
					if(v.x < 0)
						return undef;
					return call(objv(v.x), recv, nil);
				}
				return v;
			}
			h = oproto[h];
			if(h < 0)
				return undef;
			continue;
		Kproxy =>
			return proxyget(h, k, recv);
		Ktyped =>
			if(isidx(k) || atomidx[k] >= 0.0)
				return typedget(h, k);
		}
		(found, d) := getown(h, k);
		if(found) {
			if(isaccdesc(d)) {
				if(d.get.t != Tobj)
					return undef;
				return call(d.get, recv, nil);
			}
			return d.value;
		}
		h = getproto(h);
		if(h < 0)
			return undef;
	}
}

getv(v: V, k: int): V
{
	if(v.t == Tobj)
		return get(v.x, k, v);
	h := protoof(v);
	if(v.t == Tstr) {
		if(isidx(k)) {
			i := keyidx(k);
			if(i < slen[v.x])
				return strv(str(v.x)[i:i+1]);
		} else if(k == alength)
			return num(real slen[v.x]);
	}
	return get(h, k, v);
}

# the prototype a primitive's properties come from (RequireObjectCoercible first)
protoof(v: V): int
{
	case v.t {
	Tundef or Tnull =>
		typeerr("cannot read properties of " + show(v));
	Tbool => return iboolproto;
	Tnum => return inumproto;
	Tstr => return istrproto;
	Tsym => return isymproto;
	Tbig => return ibigproto;
	}
	return v.x;
}

# [[Set]]: whether it succeeded
set(h, k: int, v: V, recv: V): int
{
	case okind[h] {
	Kproxy =>
		return proxyset(h, k, v, recv);
	Ktyped =>
		if(isidx(k) || atomidx[k] >= 0.0) {
			if(recv.t == Tobj && recv.x == h) {
				typedset(h, k, v);
				return 1;
			}
			if(!typedhas(h, k))
				return 1;
		}
	Kord or Karray =>
		# the common case: an own writable data property
		if(recv.t == Tobj && recv.x == h) {
			if(isidx(k)) {
				i := keyidx(k);
				if(i < onelem[h] && oelems[h][i].t != Tempty) {
					oelems[h][i] = v;
					return 1;
				}
			} else {
				sh := oshape[h];
				slot := slotof(sh, k);
				if(slot >= 0 && (sh.attrs[slot] & (Awrite|Aacc)) == Awrite) {
					oslots[h][slot] = v;
					return 1;
				}
			}
		}
	}
	(found, d) := getown(h, k);
	if(!found) {
		p := getproto(h);
		if(p >= 0)
			return set(p, k, v, recv);
		d = ref Desc(Hvalue|Hwrite|Henum|Hconf, undef, undef, undef, Adefault);
	}
	if(isdatadesc(d)) {
		if((d.attrs & Awrite) == 0)
			return 0;
		if(recv.t != Tobj)
			return 0;
		r := recv.x;
		(rfound, rd) := getown(r, k);
		if(rfound) {
			if(isaccdesc(rd) || (rd.attrs & Awrite) == 0)
				return 0;
			if(okind[r] == Kord && rd.has == (Hvalue|Hwrite|Henum|Hconf)) {
				putown(r, k, v);
				return 1;
			}
			return defineown(r, k, ref Desc(Hvalue, v, undef, undef, 0));
		}
		return createdata(r, k, v);
	}
	if(d.set.t != Tobj)
		return 0;
	call(d.set, recv, array[] of {v});
	return 1;
}

# CreateDataProperty
createdata(h, k: int, v: V): int
{
	if(okind[h] == Kord && (oflags[h] & Oext)) {
		(ok, nil, nil) := getownprop(h, k);
		if(!ok) {
			addprop(h, k, Adefault, v);
			return 1;
		}
	}
	return defineown(h, k, datadesc(v, Adefault));
}

createdataorthrow(h, k: int, v: V)
{
	if(!createdata(h, k, v))
		typeerr("cannot define property " + keystr(k));
}

# set on a value: PutValue for a property reference
setv(o: V, k: int, v: V, strict: int)
{
	ok: int;
	if(o.t == Tobj)
		ok = set(o.x, k, v, o);
	else
		ok = set(protoof(o), k, v, o);
	if(!ok && strict)
		typeerr("cannot assign to read only property '" + keystr(k) + "' of " + show(o));
}

delete(h, k: int): int
{
	case okind[h] {
	Kproxy =>
		return proxydelete(h, k);
	Kargs =>
		return argsdelete(h, k);
	Ktyped =>
		if(isidx(k) || atomidx[k] >= 0.0)
			return !typedhas(h, k);
	Kmodns =>
		return modnsdelete(h, k);
	}
	(found, d) := getown(h, k);
	if(!found)
		return 1;
	if((d.attrs & Aconf) == 0)
		return 0;
	if(okind[h] == Karray && k == alength)
		return 0;
	removeown(h, k);
	return 1;
}

# ---- conversions ----

# ToPrimitive; hint: 0 default, 1 number, 2 string
toprim(v: V, hint: int): V
{
	if(v.t != Tobj)
		return v;
	ex := getv(v, asymtoprim);
	if(ex.t != Tundef && ex.t != Tnull) {
		if(!iscallable(ex))
			typeerr("Symbol.toPrimitive is not a function");
		hs := "default";
		if(hint == 1)
			hs = "number";
		else if(hint == 2)
			hs = "string";
		sp0 := sp;
		push(v);
		r := call(ex, v, array[] of {strv(hs)});
		sp = sp0;
		if(r.t == Tobj)
			typeerr("cannot convert object to primitive value");
		return r;
	}
	first := atostring;
	second := avalueof;
	if(hint != 2) {
		first = avalueof;
		second = atostring;
	}
	sp0 := sp;
	push(v);
	f := getv(v, first);
	if(iscallable(f)) {
		r := call(f, v, nil);
		if(r.t != Tobj) {
			sp = sp0;
			return r;
		}
	}
	f = getv(v, second);
	if(iscallable(f)) {
		r := call(f, v, nil);
		if(r.t != Tobj) {
			sp = sp0;
			return r;
		}
	}
	sp = sp0;
	typeerr("cannot convert object to primitive value");
	return undef;
}

truthy(v: V): int
{
	case v.t {
	Tundef or Tnull => return 0;
	Tbool => return v.x;
	Tnum => return v.n != 0.0 && !isnan(v.n);
	Tstr => return slen[v.x] != 0;
	Tbig => return str(v.x) != "0";
	Tobj => return (oflags[v.x] & Ohtmldda) == 0;
	}
	return 1;
}

tonumber(v: V): real
{
	case v.t {
	Tnum => return v.n;
	Tundef => return nan;
	Tnull => return 0.0;
	Tbool => return real v.x;
	Tstr => return strnum(str(v.x));
	Tsym => typeerr("cannot convert a Symbol value to a number");
	Tbig => typeerr("cannot convert a BigInt value to a number");
	Tobj => return tonumber(toprim(v, 1));
	}
	return nan;
}

# ToNumeric: a Number or a BigInt
tonumeric(v: V): V
{
	if(v.t == Tnum || v.t == Tbig)
		return v;
	p := toprim(v, 1);
	if(p.t == Tbig)
		return p;
	return num(tonumber(p));
}

tointorinf(v: V): real
{
	x := tonumber(v);
	if(isnan(x) || x == 0.0)
		return 0.0;
	if(x == inf || x == -inf)
		return x;
	return trunc(x);
}

trunc(x: real): real
{
	if(x < 0.0)
		return -math->floor(-x);
	return math->floor(x);
}

tolength(v: V): real
{
	x := tointorinf(v);
	if(x <= 0.0)
		return 0.0;
	if(x > 9007199254740991.0)
		return 9007199254740991.0;
	return x;
}

# ToIndex
toindex(v: V): real
{
	if(v.t == Tundef)
		return 0.0;
	x := tointorinf(v);
	if(x < 0.0 || x > 9007199254740991.0)
		throwerr(RangeError, "invalid index");
	return x;
}

touint32(v: V): real
{
	x := tonumber(v);
	if(isnan(x) || x == inf || x == -inf)
		return 0.0;
	x = trunc(x);
	x = math->fmod(x, 4294967296.0);
	if(x < 0.0)
		x += 4294967296.0;
	return x;
}

toint32(v: V): int
{
	if(v.t == Tnum) {
		x := v.n;
		if(x >= -2147483648.0 && x <= 2147483647.0 && x == real int x)
			return int x;
	}
	return int32(touint32(v));
}

int32(u: real): int
{
	if(u >= 2147483648.0)
		u -= 4294967296.0;
	return int u;
}

tostring(v: V): string
{
	return str(tostrh(v));
}

# ToString, to a string row
tostrh(v: V): int
{
	case v.t {
	Tstr => return v.x;
	Tnum => return newstr(numstr(v.n));
	Tundef => return atomsh[aundefined];
	Tnull => return atomsh[anull];
	Tbool =>
		if(v.x)
			return atomsh[atrue];
		return atomsh[afalse];
	Tsym => typeerr("cannot convert a Symbol value to a string");
	Tbig => return v.x;
	Tobj =>
		p := toprim(v, 2);
		return tostrh(p);
	}
	return atomsh[aundefined];
}

# (a local, so the compiler does not inline it: its inliner writes the
# result into the caller's v = tostrv(v) before reading v for tostrh)
tostrv(v: V): V
{
	if(v.t == Tstr)
		return v;
	h := tostrh(v);
	return V(Tstr, h, 0.0);
}

toobject(v: V): int
{
	case v.t {
	Tobj =>
		return v.x;
	Tundef or Tnull =>
		typeerr("cannot convert " + show(v) + " to object");
	}
	h := newobj(Kprim, protoof(v));
	odata[h] = ref Data.Prim(v);
	return h;
}

# ToPropertyKey
tokey(v: V): int
{
	case v.t {
	Tstr =>
		return strhkey(v.x);
	Tnum =>
		return numkey(v.n);
	Tsym =>
		return v.x;
	Tobj =>
		p := toprim(v, 2);
		if(p.t == Tsym)
			return p.x;
		return strhkey(tostrh(p));
	}
	return strhkey(tostrh(v));
}

# ---- comparisons ----

samevalue(a, b: V): int
{
	if(a.t != b.t)
		return 0;
	if(a.t == Tnum) {
		if(isnan(a.n))
			return isnan(b.n);
		if(a.n == 0.0 && b.n == 0.0)
			return signbit(a.n) == signbit(b.n);
		return a.n == b.n;
	}
	return samenonnum(a, b);
}

samevaluezero(a, b: V): int
{
	if(a.t == Tnum && b.t == Tnum && isnan(a.n))
		return isnan(b.n);
	return strictequal(a, b);
}

signbit(x: real): int
{
	if(x != 0.0)
		return x < 0.0;
	return 1.0 / x < 0.0;
}

samenonnum(a, b: V): int
{
	case a.t {
	Tundef or Tnull =>
		return 1;
	Tbool or Tsym or Tobj =>
		return a.x == b.x;
	Tstr =>
		return a.x == b.x || slen[a.x] == slen[b.x] && str(a.x) == str(b.x);
	Tbig =>
		return str(a.x) == str(b.x);
	Tnum =>
		return a.n == b.n;
	}
	return 0;
}

strictequal(a, b: V): int
{
	if(a.t != b.t)
		return 0;
	if(a.t == Tnum)
		return a.n == b.n;
	return samenonnum(a, b);
}

looseequal(a, b: V): int
{
	for(;;) {
		if(a.t == b.t)
			return strictequal(a, b);
		if((a.t == Tundef || a.t == Tnull) && (b.t == Tundef || b.t == Tnull))
			return 1;
		if(a.t == Tobj && (oflags[a.x] & Ohtmldda) && (b.t == Tundef || b.t == Tnull))
			return 1;
		if(b.t == Tobj && (oflags[b.x] & Ohtmldda) && (a.t == Tundef || a.t == Tnull))
			return 1;
		case a.t {
		Tnum =>
			if(b.t == Tstr)
				return a.n == tonumber(b);
			if(b.t == Tbig)
				return bigeqnum(b, a.n);
		Tstr =>
			if(b.t == Tnum)
				return tonumber(a) == b.n;
			if(b.t == Tbig) {
				(ok, bv) := strbig(str(a.x));
				return ok && str(bv.x) == str(b.x);
			}
		Tbig =>
			if(b.t == Tnum)
				return bigeqnum(a, b.n);
			if(b.t == Tstr) {
				(ok, bv) := strbig(str(b.x));
				return ok && str(bv.x) == str(a.x);
			}
		Tbool =>
			a = num(real a.x);
			continue;
		}
		if(b.t == Tbool) {
			b = num(real b.x);
			continue;
		}
		if(a.t == Tobj && (b.t == Tnum || b.t == Tstr || b.t == Tbig || b.t == Tsym)) {
			a = toprim(a, 0);
			continue;
		}
		if(b.t == Tobj && (a.t == Tnum || a.t == Tstr || a.t == Tbig || a.t == Tsym)) {
			b = toprim(b, 0);
			continue;
		}
		return 0;
	}
}

# IsLessThan: 1 less, 0 not, -1 undefined (a NaN)
lessthan(a, b: V, leftfirst: int): int
{
	px, py: V;
	if(leftfirst) {
		px = toprim(a, 1);
		py = toprim(b, 1);
	} else {
		py = toprim(b, 1);
		px = toprim(a, 1);
	}
	if(px.t == Tstr && py.t == Tstr)
		return str(px.x) < str(py.x);
	if(px.t == Tbig && py.t == Tstr) {
		(ok, by) := strbig(str(py.x));
		if(!ok)
			return -1;
		return bigcmp(px, by) < 0;
	}
	if(px.t == Tstr && py.t == Tbig) {
		(ok, bx) := strbig(str(px.x));
		if(!ok)
			return -1;
		return bigcmp(bx, py) < 0;
	}
	nx := tonumeric(px);
	ny := tonumeric(py);
	if(nx.t == Tnum && ny.t == Tnum) {
		if(isnan(nx.n) || isnan(ny.n))
			return -1;
		return nx.n < ny.n;
	}
	if(nx.t == Tbig && ny.t == Tbig)
		return bigcmp(nx, ny) < 0;
	# a BigInt and a Number
	if(nx.t == Tbig) {
		if(isnan(ny.n))
			return -1;
		return bigcmpnum(nx, ny.n) < 0;
	}
	if(isnan(nx.n))
		return -1;
	return bigcmpnum(ny, nx.n) > 0;
}

typeofv(v: V): string
{
	case v.t {
	Tundef => return "undefined";
	Tnull => return "object";
	Tbool => return "boolean";
	Tnum => return "number";
	Tstr => return "string";
	Tsym => return "symbol";
	Tbig => return "bigint";
	Tobj =>
		if(oflags[v.x] & Ohtmldda)
			return "undefined";
		if(oflags[v.x] & Ocallable)
			return "function";
		return "object";
	}
	return "undefined";
}

# OrdinaryHasInstance and instanceof
instanceof(v, c: V): int
{
	if(c.t != Tobj)
		typeerr("right-hand side of 'instanceof' is not an object");
	h := getv(c, asymhasinst);
	if(h.t != Tundef && h.t != Tnull) {
		if(!iscallable(h))
			typeerr("Symbol.hasInstance is not a function");
		return truthy(call(h, c, array[] of {v}));
	}
	if(!iscallable(c))
		typeerr("right-hand side of 'instanceof' is not callable");
	return ordinaryhasinstance(c, v);
}

ordinaryhasinstance(c, v: V): int
{
	if(!iscallable(c))
		return 0;
	if(okind[c.x] == Kbound)
		pick b := odata[c.x] {
		Bound =>
			return instanceof(v, objv(b.target));
		}
	if(v.t != Tobj)
		return 0;
	p := getv(c, aprototype);
	if(p.t != Tobj)
		typeerr("function has non-object prototype in instanceof check");
	for(o := getproto(v.x); o >= 0; o = getproto(o))
		if(o == p.x)
			return 1;
	return 0;
}

# ---- functions as values ----

# the length of an array-like: ToLength(Get(o, "length"))
lengthof(o: V): real
{
	return tolength(getv(o, alength));
}

# Get(o, k), called as a function: GetMethod
getmethod(v: V, k: int): V
{
	f := getv(v, k);
	if(f.t == Tundef || f.t == Tnull)
		return undef;
	if(!iscallable(f))
		typeerr(keystr(k) + " is not a function");
	return f;
}

invoke(v: V, k: int, args: array of V): V
{
	f := getv(v, k);
	if(!iscallable(f))
		typeerr(keystr(k) + " is not a function");
	return call(f, v, args);
}

# SpeciesConstructor
speciesctor(o: V, dflt: int): V
{
	c := getv(o, aconstructor);
	if(c.t == Tundef)
		return objv(dflt);
	if(c.t != Tobj)
		typeerr("constructor is not an object");
	s := getv(c, asymspecies);
	if(s.t == Tundef || s.t == Tnull)
		return objv(dflt);
	if(isctor(s))
		return s;
	typeerr("Symbol.species is not a constructor");
	return undef;
}

# GetPrototypeFromConstructor
protofromctor(nt: V, dflt: int): int
{
	if(nt.t != Tobj)
		return dflt;
	p := getv(nt, aprototype);
	if(p.t == Tobj)
		return p.x;
	return dflt;
}

# ---- arrays ----

newarray(n: int): int
{
	h := newobj(Karray, iarrproto);
	if(n > 0) {
		oelems[h] = array[n] of V;
		for(i := 0; i < n; i++)
			oelems[h][i] = empty;
	}
	return h;
}

# an array of the given values
arrayof(a: array of V): int
{
	h := newobj(Karray, iarrproto);
	e := array[len a + 4] of V;
	e[0:] = a;
	oelems[h] = e;
	onelem[h] = len a;
	oalen[h] = real len a;
	return h;
}

# append v to array h (a fresh dense array)
arrpush(h: int, v: V)
{
	n := int oalen[h];
	if(n == onelem[h] && (oflags[h] & Oidxprops) == 0) {
		e := oelems[h];
		if(e == nil || n == len e) {
			ne := array[2 * n + 8] of V;
			if(e != nil)
				ne[0:] = e[0:n];
			oelems[h] = ne;
			e = ne;
		}
		e[n] = v;
		onelem[h] = n + 1;
		oalen[h] = real (n + 1);
		return;
	}
	createdataorthrow(h, numkey(oalen[h]), v);
}

# the values of a dense array-like, quickly when it is a plain array
listfromarraylike(o: V): array of V
{
	if(o.t != Tobj)
		typeerr("CreateListFromArrayLike called on non-object");
	n := lengthof(o);
	if(n > 1e7)
		throwerr(RangeError, "too many arguments");
	a := array[int n] of V;
	for(i := 0; i < len a; i++)
		a[i] = getv(o, idxkey(i));
	return a;
}
