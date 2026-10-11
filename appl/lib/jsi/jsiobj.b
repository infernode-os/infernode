#
# jsiobj.b - the object internal methods (ECMA-262 §10), conversions
# (§7.1), comparisons (§7.2) and errors.
#
# These are the general paths.  The evaluator's inline caches go to an
# own data property's slot directly and come here when they miss.
#

# error kinds, the order of errprotos
EError, EType, ERange, ERef, ESyntax, EEval, EURI, EAggregate: con iota;
errnames := array[] of {"Error", "TypeError", "RangeError", "ReferenceError", "SyntaxError", "EvalError", "URIError", "AggregateError"};

thrown: V;	# the value being thrown, while the Limbo exception "JS" unwinds

throwv(v: V)
{
	thrown = v;
	raise "JS";
}

throwerr(kind: int, msg: string)
{
	thrown = objv(mkerror(kind, msg));
	raise "JS";
}

throwtype(msg: string)
{
	throwerr(EType, msg);
}

mkerror(kind: int, msg: string): ref Obj
{
	p: ref Obj;
	if(errprotos != nil)
		p = errprotos[kind];
	o := newobj(Cerror, p);
	if(msg != nil)
		addprop(o, a_message, Awrite|Aconf, strv(msg));
	return o;
}

# ---- own properties ----

# an array index key's index, or -1
keyidx(k: int): int
{
	return atomidx[k];
}

# [[GetOwnProperty]]: (found, the value or (Aacc) the accessor holder, attributes)
getown(o: ref Obj, k: int): (int, V, int)
{
	case o.cls {
	Cfunc =>
		if(k == a_prototype && (o.flags & Flazyproto))
			mkproto(o);
	Carray =>
		if(k == a_length) {
			at := Awrite;
			if(o.flags & Ffrozenlen)
				at = 0;
			return (1, arrlenv(o), at);
		}
		if((o.flags & Fslow) == 0) {
			i := atomidx[k];
			if(i >= 0) {
				if(i < len o.elems && o.elems[i].t != Thole)
					return (1, o.elems[i], Adefault);
				return (0, undef, 0);
			}
		}
	Cargs =>
		# a mapped argument's value is its parameter's
		s := slotof(o.sh, k);
		if(s < 0)
			return (0, undef, 0);
		at := o.sh.attrs[s];
		i := atomidx[k];
		if(i >= 0 && (at & Aacc) == 0 && argsmapped(o, i))
			return (1, argsget(o, i), at);
		return (1, o.slots[s], at);
	Cstr =>
		i := atomidx[k];
		s := primstr(o);
		if(i >= 0 && i < len s)
			return (1, strv(s[i:i+1]), Aenum);
		if(k == a_length)
			return (1, intv(len s), 0);
	Ctyped =>
		if(!issym(k)) {
			(isnum, x) := canonnum(atomstr[k]);
			if(isnum)
				return typedgetown(o, x);
		}
	Cproxy =>
		return pxgetown(o, k);
	Cns =>
		return nsgetown(o, k);
	}
	s := slotof(o.sh, k);
	if(s < 0)
		return (0, undef, 0);
	return (1, o.slots[s], o.sh.attrs[s]);
}

# a canonical numeric string's value (typed arrays' keys): (1, x) or (0, 0)
canonnum(s: string): (int, real)
{
	if(s == "-0")
		return (1, -0.0);
	if(len s == 0)
		return (0, 0.0);
	c := s[0];
	if(!(c >= '0' && c <= '9' || c == '-' || c == 'I' || c == 'N'))
		return (0, 0.0);
	x := strnum(s);
	if(numstr(x) == s)
		return (1, x);
	return (0, 0.0);
}

arrlenv(o: ref Obj): V
{
	if(o.flags & Fbiglen)
		return V(Tnum, 0, biglen(o), nil, nil);
	return intv(o.alen);
}

arrlen(o: ref Obj): real
{
	if(o.flags & Fbiglen)
		return biglen(o);
	return real o.alen;
}

biglen(o: ref Obj): real
{
	if(o.data != nil)
	pick d := o.data {
	Arr =>
		return d.blen;
	}
	return real o.alen;
}

primstr(o: ref Obj): string
{
	if(o.data != nil)
	pick d := o.data {
	Prim =>
		return flat(d.v);
	}
	return nil;
}

# the parameter map of an arguments object (§10.4.4)
argsmapped(o: ref Obj, i: int): int
{
	if(o.data != nil)
	pick d := o.data {
	Args =>
		return i < len d.map && d.map[i] != -1;
	}
	return 0;
}

argsget(o: ref Obj, i: int): V
{
	pick d := o.data {
	Args =>
		m := d.map[i];
		if(m >= 0)
			return d.fr[m];
		return d.env.v[-m-2];
	}
	return undef;
}

argsset(o: ref Obj, i: int, v: V)
{
	pick d := o.data {
	Args =>
		m := d.map[i];
		if(m >= 0)
			d.fr[m] = v;
		else if(m <= -2)
			d.env.v[-m-2] = v;
	}
}

argsunmap(o: ref Obj, i: int)
{
	if(o.data != nil)
	pick d := o.data {
	Args =>
		if(i < len d.map)
			d.map[i] = -1;
	}
}

# [[DefineOwnProperty]] of an arguments object
argsdefine(o: ref Obj, k: int, d: ref Desc): int
{
	i := atomidx[k];
	mapped := i >= 0 && argsmapped(o, i);
	nd := d;
	if(mapped && (d.has & (Dget|Dset)) == 0 && (d.has & Dvalue) == 0 && (d.has & Dwrite) && (d.attrs & Awrite) == 0) {
		nd = ref Desc(d.has | Dvalue, argsget(o, i), d.attrs, d.get, d.set);
	}
	# the property's own slot keeps the value too
	if(mapped) {
		s := slotof(o.sh, k);
		if(s >= 0)
			o.slots[s] = argsget(o, i);
	}
	if(!ordinarydefine(o, k, nd))
		return 0;
	if(mapped) {
		if(d.has & (Dget|Dset))
			argsunmap(o, i);
		else {
			if(d.has & Dvalue)
				argsset(o, i, d.v);
			if((d.has & Dwrite) && (d.attrs & Awrite) == 0)
				argsunmap(o, i);
		}
	}
	return 1;
}

# ---- [[Get]] ----

get(o: ref Obj, k: int, recv: V): V
{
	for(;;) {
		if(o.cls == Cproxy)
			return pxget(o, k, recv);
		if(o.cls == Ctyped && !issym(k)) {
			# a numeric key is the typed array's own, found or not: never the prototype's
			(isnum, x) := canonnum(atomstr[k]);
			if(isnum)
				return typedgetnum(o, x);
		}
		(found, v, at) := getown(o, k);
		if(found) {
			if(at & Aacc)
				return callgetter(v, recv);
			return v;
		}
		o = o.sh.proto;
		if(o == nil)
			return undef;
	}
}

callgetter(acc: V, recv: V): V
{
	pick d := acc.o.data {
	Acc =>
		if(d.get == nil)
			return undef;
		return call(d.get, recv, nil);
	}
	return undef;
}

getv(o: ref Obj, k: int): V
{
	return get(o, k, objv(o));
}

# o[i], for an index
getidx(o: ref Obj, i: int, recv: V): V
{
	for(;;) {
		case o.cls {
		Carray =>
			if((o.flags & Fslow) == 0 && i < len o.elems && o.elems[i].t != Thole)
				return o.elems[i];
		Cproxy =>
			return pxget(o, idxatom(i), recv);
		}
		if(o.cls == Cplain && o.sh.n == 0 || (o.cls == Carray && (o.flags & Fslow) == 0)) {
			o = o.sh.proto;
			if(o == nil)
				return undef;
			continue;
		}
		return get(o, idxatom(i), recv);
	}
}

# a property of any value: v[k]
getvalue(v: V, k: int): V
{
	case v.t {
	Tobj =>
		return get(v.o, k, v);
	Tstr or Trope =>
		if(k == a_length)
			return intv(strlenv(v));
		i := atomidx[k];
		if(i >= 0) {
			s := flat(v);
			if(i < len s)
				return strv(s[i:i+1]);
		}
		return get(strproto, k, v);
	Tint or Tnum =>
		return get(numproto, k, v);
	Tbool =>
		return get(boolproto, k, v);
	Tsym =>
		return get(symproto, k, v);
	Tbig =>
		return get(bigproto, k, v);
	* =>
		throwtype(sys->sprint("Cannot read properties of %s (reading '%s')", typename(v), keyname(k)));
	}
	return undef;
}

typename(v: V): string
{
	if(v.t == Tnull)
		return "null";
	if(v.t == Tundef)
		return "undefined";
	return typeofv(v);
}

# ---- [[Set]] ----

# OrdinarySet, for the chain from o: 1, or 0 if it could not
put(o: ref Obj, k: int, v: V, recv: V): int
{
	p := o;
	for(;;) {
		if(p.cls == Cproxy)
			return pxset(p, k, v, recv);
		if(p.cls == Cns)
			return 0;	# a namespace's [[Set]] is always false
		if(p.cls == Ctyped && !issym(k)) {
			(isnum, x) := canonnum(atomstr[k]);
			if(isnum) {
				if(recv.t == Tobj && recv.o == p) {
					typedsetnum(p, x, v);
					return 1;
				}
				if(!typedvalidindex(p, x))
					return 1;
			}
		}
		(found, cur, at) := getown(p, k);
		if(found) {
			if(at & Aacc) {
				pick d := cur.o.data {
				Acc =>
					if(d.set == nil)
						return 0;
					call(d.set, recv, array[] of {v});
					return 1;
				}
				return 0;
			}
			if((at & Awrite) == 0)
				return 0;
			break;
		}
		p = p.sh.proto;
		if(p == nil)
			break;
	}
	# a writable data property (or none) up the chain: set it on recv
	if(recv.t != Tobj)
		return 0;
	r := recv.o;
	if(r == o && r.cls == Cplain) {
		s := slotof(r.sh, k);
		if(s >= 0) {
			if((r.sh.attrs[s] & (Awrite|Aacc)) != Awrite)
				return 0;
			r.slots[s] = v;
			return 1;
		}
		if((r.flags & Fext) == 0)
			return 0;
		addprop(r, k, Adefault, v);
		return 1;
	}
	(found, nil, at) := getown(r, k);
	if(found) {
		if(at & Aacc || (at & Awrite) == 0)
			return 0;
		return defineown(r, k, ref Desc(Dvalue, v, 0, nil, nil));
	}
	return defineown(r, k, ref Desc(Dvalue|Dwrite|Denum|Dconf, v, Adefault, nil, nil));
}

# o[k] = v in strict code (a TypeError if it cannot) or sloppy
setprop(o: ref Obj, k: int, v: V, strict: int)
{
	if(!put(o, k, v, objv(o)) && strict)
		throwtype(sys->sprint("Cannot assign to read only property '%s' of object", keyname(k)));
}

# v[k] = x for any value v
setvalue(v: V, k: int, x: V, strict: int)
{
	case v.t {
	Tobj =>
		if(!put(v.o, k, x, v) && strict)
			throwtype(sys->sprint("Cannot assign to read only property '%s' of object", keyname(k)));
	Tundef or Tnull =>
		throwtype(sys->sprint("Cannot set properties of %s (setting '%s')", typename(v), keyname(k)));
	* =>
		p := protoof(v);
		if(!put(p, k, x, v) && strict)
			throwtype(sys->sprint("Cannot create property '%s' on %s", keyname(k), typeofv(v)));
	}
}

protoof(v: V): ref Obj
{
	case v.t {
	Tstr or Trope =>
		return strproto;
	Tint or Tnum =>
		return numproto;
	Tbool =>
		return boolproto;
	Tsym =>
		return symproto;
	Tbig =>
		return bigproto;
	Tobj =>
		return v.o;
	}
	return nil;
}

# a store past the elements by more than a little keeps the array dense while it
# at most doubles it and stays below this: x[2**31-2] = v makes a sparse array,
# not a two gigabyte one (an element is 40 bytes: a jump past a million is sparse)
Maxjump: con 1<<20;

# an index set on an ordinary array, quickly when it can: 1 if done
setelem(o: ref Obj, i: int, v: V): int
{
	if(o.cls != Carray || (o.flags & (Fslow|Ffrozenlen)) != 0 || (o.flags & Fext) == 0)
		return 0;
	if(i < len o.elems) {
		if(o.elems[i].t == Thole) {
			# a hole: a setter or read-only element on the chain would matter
			if(protohasidx(o))
				return 0;
		}
		o.elems[i] = v;
		if(i >= o.alen)
			o.alen = i + 1;
		return 1;
	}
	if(i > len o.elems + 1024 && (i > 2 * len o.elems || i >= Maxjump))
		return 0;
	if(protohasidx(o))
		return 0;
	growelems(o, i + 1);
	o.elems[i] = v;
	if(i >= o.alen)
		o.alen = i + 1;
	return 1;
}

# whether any prototype of o could have an index property
protohasidx(o: ref Obj): int
{
	for(p := o.sh.proto; p != nil; p = p.sh.proto) {
		if(p.cls == Cproxy || p.cls == Ctyped || p.cls == Cstr)
			return 1;
		if(p.cls == Carray && (p.elems != nil && p.alen > 0 || (p.flags & Fslow)))
			return 1;
		if(p.sh.n > 0 && hasidxkey(p))
			return 1;
	}
	return 0;
}

hasidxkey(p: ref Obj): int
{
	sh := p.sh;
	for(i := 0; i < sh.n; i++) {
		k := sh.keys[i];
		if(k >= 0 && atomidx[k] != -1)
			return 1;
	}
	return 0;
}

growelems(o: ref Obj, n: int)
{
	if(o.elems != nil && n <= len o.elems)
		return;
	m := 2 * len o.elems;
	if(m < n)
		m = n;
	if(m < 4)
		m = 4;
	a := array[m] of {* => holev};
	if(o.elems != nil)
		a[0:] = o.elems;
	o.elems = a;
}

# an array's elements moved into its properties, for attributes they cannot have, or sparseness
slowarray(o: ref Obj)
{
	if(o.flags & Fslow)
		return;
	e := o.elems;
	o.elems = nil;
	o.flags |= Fslow;
	if(e == nil)
		return;
	n := len e;
	if(o.cls == Carray && o.alen < n)
		n = o.alen;
	# indices go first in key order anyway
	for(i := 0; i < n; i++)
		if(e[i].t != Thole) {
			v := e[i];
			if(o.cls == Cargs) {
				o.elems = e;
				v = argsget(o, i);
				o.elems = nil;
			}
			addprop(o, idxatom(i), Adefault, v);
		}
	if(o.cls == Cargs)
		o.flags &= ~Fmapped;
}

# ---- [[DefineOwnProperty]] ----

defineown(o: ref Obj, k: int, d: ref Desc): int
{
	case o.cls {
	Cfunc =>
		if(k == a_prototype && (o.flags & Flazyproto))
			mkproto(o);
	Carray =>
		if(k == a_length)
			return arraysetlength(o, d);
		i := atomidx[k];
		if(i != -1) {
			idx: real;
			if(i == -2)
				idx = real atomstr[k];
			else
				idx = real i;
			if(idx >= arrlen(o) && (o.flags & Ffrozenlen))
				return 0;
			if((o.flags & Fslow) == 0 && i >= 0) {
				# a plain data element stays an element
				if(isplaindesc(d, i < len o.elems && o.elems[i].t != Thole)) {
					if(i < len o.elems && o.elems[i].t != Thole) {
						if(d.has & Dvalue)
							o.elems[i] = d.v;
						return 1;
					}
					if((o.flags & Fext) == 0)
						return 0;
					if(i <= len o.elems + 1024 || i <= 2 * len o.elems && i < Maxjump) {
						growelems(o, i + 1);
						o.elems[i] = d.v;
						if(d.has & Dvalue)
							;
						else
							o.elems[i] = undef;
						if(i >= o.alen)
							o.alen = i + 1;
						return 1;
					}
				}
				slowarray(o);
			}
			if(!ordinarydefine(o, k, d))
				return 0;
			if(idx >= arrlen(o))
				setarrlen(o, idx + 1.0);
			return 1;
		}
	Cargs =>
		return argsdefine(o, k, d);
	Cstr =>
		i := atomidx[k];
		s := primstr(o);
		if(i >= 0 && i < len s || k == a_length) {
			(nil, cur, at) := getown(o, k);
			return compatible(d, cur, at);
		}
	Ctyped =>
		if(!issym(k)) {
			(isnum, x) := canonnum(atomstr[k]);
			if(isnum)
				return typeddefine(o, x, d);
		}
	Cproxy =>
		return pxdefine(o, k, d);
	Cns =>
		return nsdefine(o, k, d);
	}
	return ordinarydefine(o, k, d);
}

# whether d makes (or keeps) a writable, enumerable, configurable data property
isplaindesc(d: ref Desc, exists: int): int
{
	if(d.has & (Dget|Dset))
		return 0;
	if(exists) {
		if((d.has & Dwrite) && (d.attrs & Awrite) == 0)
			return 0;
		if((d.has & Denum) && (d.attrs & Aenum) == 0)
			return 0;
		if((d.has & Dconf) && (d.attrs & Aconf) == 0)
			return 0;
		return 1;
	}
	return (d.has & (Dwrite|Denum|Dconf)) == (Dwrite|Denum|Dconf) && (d.attrs & Adefault) == Adefault;
}

# whether a property can be "changed" by d without change (for exotic fixed properties)
compatible(d: ref Desc, cur: V, at: int): int
{
	if(d.has & (Dget|Dset))
		return 0;
	if((d.has & Dconf) && (d.attrs & Aconf) != (at & Aconf))
		return 0;
	if((d.has & Denum) && (d.attrs & Aenum) != (at & Aenum))
		return 0;
	if((d.has & Dwrite) && (d.attrs & Awrite) != (at & Awrite))
		return 0;
	if((d.has & Dvalue) && !samevalue(d.v, cur))
		return 0;
	return 1;
}

# ValidateAndApplyPropertyDescriptor on an ordinary object
ordinarydefine(o: ref Obj, k: int, d: ref Desc): int
{
	s := slotof(o.sh, k);
	if(s < 0) {
		if((o.flags & Fext) == 0)
			return 0;
		if(d.has & (Dget|Dset)) {
			acc := newacc(d.get, d.set);
			at := Aacc | (d.attrs & (Aenum|Aconf));
			if((d.has & Denum) == 0)
				at &= ~Aenum;
			if((d.has & Dconf) == 0)
				at &= ~Aconf;
			addprop(o, k, at, objv(acc));
		} else {
			at := d.attrs & Adefault;
			if((d.has & Dwrite) == 0)
				at &= ~Awrite;
			if((d.has & Denum) == 0)
				at &= ~Aenum;
			if((d.has & Dconf) == 0)
				at &= ~Aconf;
			v := undef;
			if(d.has & Dvalue)
				v = d.v;
			addprop(o, k, at, v);
		}
		return 1;
	}
	at := o.sh.attrs[s];
	cur := o.slots[s];
	if((at & Aconf) == 0) {
		if((d.has & Dconf) && (d.attrs & Aconf))
			return 0;
		if((d.has & Denum) && (d.attrs & Aenum) != (at & Aenum))
			return 0;
		isacc := (d.has & (Dget|Dset)) != 0;
		isdata := (d.has & (Dvalue|Dwrite)) != 0;
		if(isacc && (at & Aacc) == 0 || isdata && (at & Aacc))
			return 0;
		if(at & Aacc) {
			pick a := cur.o.data {
			Acc =>
				if((d.has & Dget) && d.get != a.get)
					return 0;
				if((d.has & Dset) && d.set != a.set)
					return 0;
			}
			return 1;
		}
		if((at & Awrite) == 0) {
			if((d.has & Dwrite) && (d.attrs & Awrite))
				return 0;
			if((d.has & Dvalue) && !samevalue(d.v, cur))
				return 0;
			return 1;
		}
	}
	nat := at;
	if(d.has & (Dget|Dset)) {
		if(at & Aacc) {
			pick a := cur.o.data {
			Acc =>
				g := a.get;
				st := a.set;
				if(d.has & Dget)
					g = d.get;
				if(d.has & Dset)
					st = d.set;
				o.slots[s] = objv(newacc(g, st));
			}
		} else {
			o.slots[s] = objv(newacc(d.get, d.set));
			nat = (at & (Aenum|Aconf)) | Aacc;
		}
	} else if(d.has & (Dvalue|Dwrite)) {
		if(at & Aacc) {
			nat = at & (Aenum|Aconf);
			o.slots[s] = undef;
		}
		if(d.has & Dvalue)
			o.slots[s] = d.v;
		if(d.has & Dwrite)
			nat = (nat & ~Awrite) | (d.attrs & Awrite);
	}
	if(d.has & Denum)
		nat = (nat & ~Aenum) | (d.attrs & Aenum);
	if(d.has & Dconf)
		nat = (nat & ~Aconf) | (d.attrs & Aconf);
	setattrs(o, s, nat);
	return 1;
}

newacc(g, s: ref Obj): ref Obj
{
	o := ref Obj;
	gcnew(o);
	o.cls = Cacc;
	o.data = ref Data.Acc(g, s);
	return o;
}

# ArraySetLength
arraysetlength(o: ref Obj, d: ref Desc): int
{
	if((d.has & Dvalue) == 0) {
		if(d.has & (Dget|Dset))
			return 0;
		if((d.has & Dconf) && (d.attrs & Aconf))
			return 0;
		if((d.has & Denum) && (d.attrs & Aenum))
			return 0;
		if((d.has & Dwrite) && (d.attrs & Awrite) == 0)
			o.flags |= Ffrozenlen;
		else if((d.has & Dwrite) && (o.flags & Ffrozenlen))
			return 0;
		return 1;
	}
	n := touint32(d.v);
	if(n != tonum(d.v))
		throwerr(ERange, "Invalid array length");
	if(d.has & (Dget|Dset))
		return 0;
	if((d.has & Dconf) && (d.attrs & Aconf))
		return 0;
	if((d.has & Denum) && (d.attrs & Aenum))
		return 0;
	if(o.flags & Ffrozenlen) {
		if((d.has & Dwrite) && (d.attrs & Awrite))
			return 0;
		return n == arrlen(o);
	}
	ok := setarrlen(o, n);
	if((d.has & Dwrite) && (d.attrs & Awrite) == 0)
		o.flags |= Ffrozenlen;
	return ok;
}

# an array's length set to n, deleting what is past it: 0 if an element would not go
setarrlen(o: ref Obj, n: real): int
{
	old := arrlen(o);
	if(n < old) {
		if(o.flags & Fslow) {
			# delete index properties >= n, from the highest, stopping at one that will not go
			keys := ownkeys(o);
			for(j := len keys - 1; j >= 0; j--) {
				k := keys[j];
				i := atomidx[k];
				if(i == -1)
					continue;
				x: real;
				if(i == -2)
					x = real atomstr[k];
				else
					x = real i;
				if(x < n)
					continue;
				s := slotof(o.sh, k);
				if(s >= 0 && (o.sh.attrs[s] & Aconf) == 0) {
					setlen(o, x + 1.0);
					return 0;
				}
				if(s >= 0)
					removeslot(o, s);
			}
		} else {
			e := len o.elems;
			ni := int n;
			for(i := ni; i < e && i < o.alen; i++)
				o.elems[i] = holev;
			if(ni < e / 4 && e > 16) {
				a := array[ni + 4] of {* => holev};
				a[0:] = o.elems[0:ni];
				o.elems = a;
			}
		}
	}
	setlen(o, n);
	return 1;
}

setlen(o: ref Obj, n: real)
{
	if(n > 2147483647.0) {
		o.flags |= Fbiglen;
		if(o.data == nil)
			o.data = ref Data.Arr(0, n);
		pick d := o.data {
		Arr =>
			d.blen = n;
		}
		o.alen = 16r7FFFFFFF;
		if((o.flags & Fslow) == 0)
			slowarray(o);
	} else {
		o.flags &= ~Fbiglen;
		o.alen = int n;
	}
}

# CreateDataProperty, failing quietly: 1 if made
createdata(o: ref Obj, k: int, v: V): int
{
	if(o.cls == Cplain) {
		s := slotof(o.sh, k);
		if(s < 0 && (o.flags & Fext)) {
			addprop(o, k, Adefault, v);
			return 1;
		}
	}
	return defineown(o, k, ref Desc(Dvalue|Dwrite|Denum|Dconf, v, Adefault, nil, nil));
}

createdatathrow(o: ref Obj, k: int, v: V)
{
	if(!createdata(o, k, v))
		throwtype(sys->sprint("Cannot define property %s", keyname(k)));
}

# DefinePropertyOrThrow
defineorthrow(o: ref Obj, k: int, d: ref Desc)
{
	if(!defineown(o, k, d))
		throwtype(sys->sprint("Cannot redefine property: %s", keyname(k)));
}

# a property the engine makes: data, with given attributes
defprop(o: ref Obj, k: int, v: V, attrs: int)
{
	if(o.cls == Cfunc && k == a_prototype && (o.flags & Flazyproto))
		o.flags &= ~Flazyproto;
	s := slotof(o.sh, k);
	if(s >= 0 && o.cls != Carray && o.cls != Cproxy) {
		o.slots[s] = v;
		setattrs(o, s, attrs);
		return;
	}
	if(s < 0 && (o.cls == Cplain || o.cls == Cfunc || o.cls == Cerror)) {
		addprop(o, k, attrs, v);
		return;
	}
	defineown(o, k, ref Desc(Dvalue|Dwrite|Denum|Dconf, v, attrs, nil, nil));
}

# ---- [[HasProperty]], [[Delete]] ----

hasown(o: ref Obj, k: int): int
{
	(found, nil, nil) := getown(o, k);
	return found;
}

hasprop(o: ref Obj, k: int): int
{
	for(;;) {
		if(o.cls == Cproxy)
			return pxhas(o, k);
		if(o.cls == Cns)
			return nshas(o, k);	# without reading the binding: it may be uninitialised
		if(o.cls == Ctyped && !issym(k)) {
			(isnum, x) := canonnum(atomstr[k]);
			if(isnum)
				return typedvalidindex(o, x);
		}
		if(hasown(o, k))
			return 1;
		o = o.sh.proto;
		if(o == nil)
			return 0;
	}
}

deleteprop(o: ref Obj, k: int): int
{
	case o.cls {
	Cfunc =>
		if(k == a_prototype && (o.flags & Flazyproto))
			mkproto(o);
	Carray =>
		if(k == a_length)
			return 0;
		i := atomidx[k];
		if(i >= 0 && (o.flags & Fslow) == 0) {
			if(i < len o.elems)
				o.elems[i] = holev;
			return 1;
		}
	Cargs =>
		s := slotof(o.sh, k);
		if(s < 0)
			return 1;
		if((o.sh.attrs[s] & Aconf) == 0)
			return 0;
		removeslot(o, s);
		if(atomidx[k] >= 0)
			argsunmap(o, atomidx[k]);
		return 1;
	Cstr =>
		i := atomidx[k];
		if(i >= 0 && i < len primstr(o) || k == a_length)
			return 0;
	Ctyped =>
		if(!issym(k)) {
			(isnum, x) := canonnum(atomstr[k]);
			if(isnum)
				return !typedvalidindex(o, x);
		}
	Cproxy =>
		return pxdelete(o, k);
	Cns =>
		return nsdelete(o, k);
	}
	s := slotof(o.sh, k);
	if(s < 0)
		return 1;
	if((o.sh.attrs[s] & Aconf) == 0)
		return 0;
	if(o.cls == Cargs && atomidx[k] >= 0)
		;
	removeslot(o, s);
	return 1;
}

# ---- [[OwnPropertyKeys]] ----

ownkeys(o: ref Obj): array of int
{
	case o.cls {
	Cfunc =>
		if(o.flags & Flazyproto)
			mkproto(o);
	Cproxy =>
		return pxownkeys(o);
	Cns =>
		return nsownkeys(o);
	}
	idx: list of int;
	nidx := 0;
	case o.cls {
	Carray =>
		if((o.flags & Fslow) == 0 && o.elems != nil) {
			n := len o.elems;
			if(o.cls == Carray && o.alen < n)
				n = o.alen;
			for(i := n - 1; i >= 0; i--)
				if(o.elems[i].t != Thole) {
					idx = idxatom(i) :: idx;
					nidx++;
				}
		}
	Cstr =>
		s := primstr(o);
		for(i := len s - 1; i >= 0; i--) {
			idx = idxatom(i) :: idx;
			nidx++;
		}
	Ctyped =>
		n := typedlength(o);
		for(i := n - 1; i >= 0; i--) {
			idx = idxatom(i) :: idx;
			nidx++;
		}
	}
	sh := o.sh;
	# index keys among the properties, sorted
	pidx: list of (real, int);
	npidx := 0;
	nstr := 0;
	nsym := 0;
	for(i := 0; i < sh.n; i++) {
		k := sh.keys[i];
		if(k < 0)
			continue;
		if(atomidx[k] != -1) {
			x: real;
			if(atomidx[k] == -2)
				x = real atomstr[k];
			else
				x = real atomidx[k];
			pidx = (x, k) :: pidx;
			npidx++;
		} else if(atomsym[k] != nil)
			nsym++;
		else
			nstr++;
	}
	extra := 0;
	if(o.cls == Carray)
		extra = 1;
	else if(o.cls == Cstr)
		extra = 1;
	r := array[nidx + npidx + nstr + nsym + extra] of int;
	j := 0;
	for(; idx != nil; idx = tl idx)
		r[j++] = hd idx;
	if(npidx > 0) {
		sorted := sortidx(pidx, npidx);
		if(nidx > 0) {
			# both: merge
			m := mergeidx(r[0:nidx], sorted);
			r[0:] = m;
			j = len m;
		} else {
			r[j:] = sorted;
			j += len sorted;
		}
	}
	if(extra)
		r[j++] = a_length;
	for(i = 0; i < sh.n; i++) {
		k := sh.keys[i];
		# a String wrapper's length can be in its shape too
		if(k >= 0 && atomidx[k] == -1 && atomsym[k] == nil && !(extra && k == a_length))
			r[j++] = k;
	}
	for(i = 0; i < sh.n; i++) {
		k := sh.keys[i];
		if(k >= 0 && atomsym[k] != nil)
			r[j++] = k;
	}
	return r[0:j];
}

sortidx(l: list of (real, int), n: int): array of int
{
	a := array[n] of (real, int);
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	# insertion sort is fine for the few index properties ordinary objects have; merge for many
	if(n > 32)
		msortpairs(a);
	else
		for(i = 1; i < n; i++) {
			x := a[i];
			(xv, nil) := x;
			j := i - 1;
			for(; j >= 0; j--) {
				(yv, nil) := a[j];
				if(yv <= xv)
					break;
				a[j+1] = a[j];
			}
			a[j+1] = x;
		}
	r := array[n] of int;
	for(i = 0; i < n; i++)
		(nil, r[i]) = a[i];
	return r;
}

msortpairs(a: array of (real, int))
{
	n := len a;
	if(n < 2)
		return;
	m := n / 2;
	l := a[0:m];
	r := a[m:];
	lc := array[m] of (real, int);
	lc[0:] = l;
	rc := array[n - m] of (real, int);
	rc[0:] = r;
	msortpairs(lc);
	msortpairs(rc);
	i := 0;
	j := 0;
	k := 0;
	while(i < len lc && j < len rc) {
		(x, nil) := lc[i];
		(y, nil) := rc[j];
		if(x <= y)
			a[k++] = lc[i++];
		else
			a[k++] = rc[j++];
	}
	while(i < len lc)
		a[k++] = lc[i++];
	while(j < len rc)
		a[k++] = rc[j++];
}

mergeidx(a, b: array of int): array of int
{
	r := array[len a + len b] of int;
	i := 0;
	j := 0;
	k := 0;
	while(i < len a && j < len b) {
		if(atomidx[a[i]] <= atomidx[b[j]] && atomidx[b[j]] != -2)
			r[k++] = a[i++];
		else
			r[k++] = b[j++];
	}
	while(i < len a)
		r[k++] = a[i++];
	while(j < len b)
		r[k++] = b[j++];
	return r;
}

# the own enumerable string keys, for for-in, Object.keys and spreading
enumkeys(o: ref Obj): array of int
{
	keys := ownkeys(o);
	r := array[len keys] of int;
	n := 0;
	for(i := 0; i < len keys; i++) {
		k := keys[i];
		if(atomsym[k] != nil)
			continue;
		if(o.cls == Cproxy) {
			d := pxgetowndesc(o, k);
			if(d == nil || (d.attrs & Aenum) == 0)
				continue;
		} else {
			(found, nil, at) := getown(o, k);
			if(!found || (at & Aenum) == 0)
				continue;
		}
		r[n++] = k;
	}
	return r[0:n];
}

# [[GetPrototypeOf]], [[SetPrototypeOf]], [[IsExtensible]], [[PreventExtensions]]
getprotoof(o: ref Obj): ref Obj
{
	if(o.cls == Cproxy)
		return pxgetproto(o);
	return o.sh.proto;
}

setprotoof(o: ref Obj, p: ref Obj): int
{
	if(o.cls == Cproxy)
		return pxsetproto(o, p);
	if(o.sh.proto == p)
		return 1;
	if((o.flags & Fext) == 0)
		return 0;
	if(o == objproto || o.cls == Cns)
		return 0;	# immutable prototype exotic objects
	for(q := p; q != nil; q = q.sh.proto) {
		if(q == o)
			return 0;
		if(q.cls == Cproxy)
			break;
	}
	setproto(o, p);
	return 1;
}

isextensible(o: ref Obj): int
{
	if(o.cls == Cproxy)
		return pxisext(o);
	return (o.flags & Fext) != 0;
}

preventext(o: ref Obj): int
{
	if(o.cls == Cproxy)
		return pxprevent(o);
	if(o.cls == Ctyped && typedlength(o) >= 0 && typedtracks(o))
		return 0;
	o.flags &= ~Fext;
	return 1;
}

# the own property's descriptor, or nil
getowndesc(o: ref Obj, k: int): ref Desc
{
	if(o.cls == Cproxy)
		return pxgetowndesc(o, k);
	(found, v, at) := getown(o, k);
	if(!found)
		return nil;
	return todesc(v, at);
}

todesc(v: V, at: int): ref Desc
{
	if(at & Aacc) {
		pick a := v.o.data {
		Acc =>
			return ref Desc(Dget|Dset|Denum|Dconf, undef, at & (Aenum|Aconf), a.get, a.set);
		}
	}
	return ref Desc(Dvalue|Dwrite|Denum|Dconf, v, at & Adefault, nil, nil);
}

# ---- conversions ----

typeofv(v: V): string
{
	case v.t {
	Tundef =>
		return "undefined";
	Tnull =>
		return "object";
	Tbool =>
		return "boolean";
	Tint or Tnum =>
		return "number";
	Tstr or Trope =>
		return "string";
	Tsym =>
		return "symbol";
	Tbig =>
		return "bigint";
	Tobj =>
		if(v.o.fun != nil)
			return "function";
		if(v.o.cls == Cproxy) {
			pick d := v.o.data {
			Proxy =>
				if(d.target != nil && d.target.fun != nil)
					return "function";
			}
		}
		return "object";
	}
	return "undefined";
}

tobool(v: V): int
{
	case v.t {
	Tundef or Tnull or Thole =>
		return 0;
	Tbool or Tint =>
		return v.i != 0;
	Tnum =>
		return v.n != 0.0 && !isnan(v.n);
	Tstr =>
		return len v.s != 0;
	Trope =>
		return 1;
	Tbig =>
		return !bigzero(v.o);
	}
	return 1;
}

Hnone, Hnumber, Hstring: con iota;

toprim(v: V, hint: int): V
{
	if(v.t != Tobj)
		return v;
	o := v.o;
	ex := getv(o, a_symtoprim);
	if(ex.t != Tundef && ex.t != Tnull) {
		if(!iscallable(ex))
			throwtype("Symbol.toPrimitive is not a function");
		h := "default";
		if(hint == Hnumber)
			h = "number";
		else if(hint == Hstring)
			h = "string";
		r := call(ex.o, v, array[] of {strv(h)});
		if(r.t == Tobj)
			throwtype("Cannot convert object to primitive value");
		return r;
	}
	a1 := a_valueOf;
	a2 := a_toString;
	if(hint == Hstring) {
		a1 = a_toString;
		a2 = a_valueOf;
	}
	f := getv(o, a1);
	if(iscallable(f)) {
		r := call(f.o, v, nil);
		if(r.t != Tobj)
			return r;
	}
	f = getv(o, a2);
	if(iscallable(f)) {
		r := call(f.o, v, nil);
		if(r.t != Tobj)
			return r;
	}
	throwtype("Cannot convert object to primitive value");
	return undef;
}

tonum(v: V): real
{
	case v.t {
	Tint =>
		return real v.i;
	Tnum =>
		return v.n;
	Tundef =>
		return nan;
	Tnull =>
		return 0.0;
	Tbool =>
		return real v.i;
	Tstr or Trope =>
		return strnum(flat(v));
	Tsym =>
		throwtype("Cannot convert a Symbol value to a number");
	Tbig =>
		throwtype("Cannot convert a BigInt value to a number");
	Tobj =>
		return tonum(toprim(v, Hnumber));
	}
	return nan;
}

# ToNumeric: a number (Tint/Tnum) or a BigInt
tonumeric(v: V): V
{
	if(v.t == Tint || v.t == Tnum || v.t == Tbig)
		return v;
	p := toprim(v, Hnumber);
	if(p.t == Tbig)
		return p;
	return V(Tnum, 0, tonum(p), nil, nil);
}

tostr(v: V): string
{
	case v.t {
	Tstr =>
		return v.s;
	Trope =>
		return flat(v);
	Tint =>
		return string v.i;
	Tnum =>
		return numstr(v.n);
	Tundef =>
		return "undefined";
	Tnull =>
		return "null";
	Tbool =>
		if(v.i)
			return "true";
		return "false";
	Tsym =>
		throwtype("Cannot convert a Symbol value to a string");
	Tbig =>
		return bigstr(v.o, 10);
	Tobj =>
		return tostr(toprim(v, Hstring));
	}
	return nil;
}

# ToString as a string value (keeping a rope)
tostrv(v: V): V
{
	if(v.t == Tstr || v.t == Trope)
		return v;
	return strv(tostr(v));
}

toobj(v: V): ref Obj
{
	case v.t {
	Tobj =>
		return v.o;
	Tundef or Tnull =>
		throwtype("Cannot convert undefined or null to object");
	Tbool =>
		return wrap(Cbool, boolproto, v);
	Tint or Tnum =>
		return wrap(Cnum, numproto, v);
	Tstr or Trope =>
		o := wrap(Cstr, strproto, strv(flat(v)));
		return o;
	Tsym =>
		return wrap(Csym, symproto, v);
	Tbig =>
		return wrap(Cbigint, bigproto, v);
	}
	return nil;
}

wrap(cls: int, proto: ref Obj, v: V): ref Obj
{
	o := newobj(cls, proto);
	o.data = ref Data.Prim(v);
	return o;
}

# ToPropertyKey
tokey(v: V): int
{
	case v.t {
	Tstr =>
		return intern(v.s);
	Tint =>
		if(v.i >= 0)
			return idxatom(v.i);
		return intern(string v.i);
	Tsym =>
		return symatom(v.o);
	Tobj =>
		p := toprim(v, Hstring);
		if(p.t == Tsym)
			return symatom(p.o);
		return intern(tostr(p));
	}
	return intern(tostr(v));
}

tointeger(v: V): real
{
	if(v.t == Tint)
		return real v.i;
	x := tonum(v);
	if(isnan(x))
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

touint32(v: V): real
{
	x: real;
	if(v.t == Tint) {
		if(v.i >= 0)
			return real v.i;
		return real v.i + 4294967296.0;
	}
	x = tonum(v);
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
	if(v.t == Tint)
		return v.i;
	x: real;
	if(v.t == Tnum)
		x = v.n;
	else
		x = tonum(v);
	if(x >= -2147483648.0 && x <= 2147483647.0 && !isnan(x)) {
		t := trunc(x);
		return int t;
	}
	return int32of(touint32(V(Tnum, 0, x, nil, nil)));
}

int32of(u: real): int
{
	if(u >= 2147483648.0)
		u -= 4294967296.0;
	return int u;
}

# ToLength
tolength(v: V): real
{
	x := tointeger(v);
	if(x <= 0.0)
		return 0.0;
	if(x > 9007199254740991.0)
		return 9007199254740991.0;
	return x;
}

# ToIndex
toindex(v: V): int
{
	if(v.t == Tundef)
		return 0;
	x := tointeger(v);
	if(x < 0.0 || x > 9007199254740991.0)
		throwerr(ERange, "Invalid index");
	if(x > 2147483647.0)
		throwerr(ERange, "Index too large for this engine");
	return int x;
}

# ToIndex, as a real: any safe integer
toindexreal(v: V): real
{
	if(v.t == Tundef)
		return 0.0;
	x := tointeger(v);
	if(x < 0.0 || x > 9007199254740991.0)
		throwerr(ERange, "Invalid index");
	return x;
}

lengthof(o: ref Obj): real
{
	if(o.cls == Carray)
		return arrlen(o);
	return tolength(getv(o, a_length));
}

# ---- comparisons ----

stricteq(a, b: V): int
{
	if(a.t == b.t) {
		case a.t {
		Tundef or Tnull =>
			return 1;
		Tbool or Tint =>
			return a.i == b.i;
		Tnum =>
			if(isnan(a.n) || isnan(b.n))
				return 0;
			return a.n == b.n;
		Tstr =>
			return a.s == b.s;
		Trope =>
			if(a.o == b.o && a.i == b.i)
				return 1;
			return flat(a) == flat(b);
		Tbig =>
			return bigcmp(a.o, b.o) == 0;
		* =>
			return a.o == b.o;
		}
	}
	if(a.t == Tint && b.t == Tnum)
		return !isnan(b.n) && real a.i == b.n;
	if(a.t == Tnum && b.t == Tint)
		return !isnan(a.n) && a.n == real b.i;
	if(isstr(a) && isstr(b))
		return flat(a) == flat(b);
	return 0;
}

samevalue(a, b: V): int
{
	if(isnum(a) && isnum(b)) {
		x := numof(a);
		y := numof(b);
		if(isnan(x))
			return isnan(y);
		if(isnan(y))
			return 0;
		if(x == 0.0 && y == 0.0)
			return negzero(x) == negzero(y);
		return x == y;
	}
	return stricteq(a, b);
}

samevaluezero(a, b: V): int
{
	if(isnum(a) && isnum(b)) {
		x := numof(a);
		y := numof(b);
		if(isnan(x))
			return isnan(y);
		if(isnan(y))
			return 0;
		return x == y;
	}
	return stricteq(a, b);
}

looseeq(a, b: V): int
{
	for(;;) {
		if(a.t == b.t || isnum(a) && isnum(b) || isstr(a) && isstr(b))
			return stricteq(a, b);
		an := a.t == Tundef || a.t == Tnull;
		bn := b.t == Tundef || b.t == Tnull;
		if(an || bn)
			return an && bn;
		if(isnum(a) && isstr(b))
			return numeq(numof(a), strnum(flat(b)));
		if(isstr(a) && isnum(b))
			return numeq(strnum(flat(a)), numof(b));
		if(a.t == Tbig && isstr(b)) {
			(ok, bb) := strtobig(flat(b));
			if(!ok)
				return 0;
			return bigcmp(a.o, bb) == 0;
		}
		if(isstr(a) && b.t == Tbig) {
			(a, b) = (b, a);
			continue;
		}
		if(a.t == Tbool) {
			a = intv(a.i);
			continue;
		}
		if(b.t == Tbool) {
			b = intv(b.i);
			continue;
		}
		if(b.t == Tobj && a.t != Tobj) {
			b = toprim(b, Hnone);
			continue;
		}
		if(a.t == Tobj && b.t != Tobj) {
			a = toprim(a, Hnone);
			continue;
		}
		if(a.t == Tbig && isnum(b))
			return bigeqnum(a.o, numof(b));
		if(isnum(a) && b.t == Tbig)
			return bigeqnum(b.o, numof(a));
		return 0;
	}
}

numeq(x, y: real): int
{
	if(isnan(x) || isnan(y))
		return 0;
	return x == y;
}

# IsLessThan: 1, 0, or -1 for undefined (a NaN)
lessthan(a, b: V, leftfirst: int): int
{
	px, py: V;
	if(leftfirst) {
		px = toprim(a, Hnumber);
		py = toprim(b, Hnumber);
	} else {
		py = toprim(b, Hnumber);
		px = toprim(a, Hnumber);
	}
	if(isstr(px) && isstr(py)) {
		if(flat(px) < flat(py))
			return 1;
		return 0;
	}
	if(px.t == Tbig && isstr(py)) {
		(ok, by) := strtobig(flat(py));
		if(!ok)
			return -1;
		return bigcmp(px.o, by) < 0;
	}
	if(isstr(px) && py.t == Tbig) {
		(ok, bx) := strtobig(flat(px));
		if(!ok)
			return -1;
		return bigcmp(bx, py.o) < 0;
	}
	nx := tonumeric(px);
	ny := tonumeric(py);
	if(nx.t == Tbig && ny.t == Tbig)
		return bigcmp(nx.o, ny.o) < 0;
	if(nx.t == Tbig)
		return bigcmpnum(nx.o, numof(ny));
	if(ny.t == Tbig) {
		r := bigcmpnum(ny.o, numof(nx));
		if(r < 0)
			return -1;
		# x < y iff y > x: bigcmpnum gives y < x
		x := numof(nx);
		if(isnan(x))
			return -1;
		if(bigeqnum(ny.o, x))
			return 0;
		return !r;
	}
	x := numof(nx);
	y := numof(ny);
	if(isnan(x) || isnan(y))
		return -1;
	if(x < y)
		return 1;
	return 0;
}

# instanceof
instanceof(v: V, c: V): int
{
	if(c.t != Tobj)
		throwtype("Right-hand side of 'instanceof' is not an object");
	h := getv(c.o, a_syminstanceof);
	if(h.t != Tundef && h.t != Tnull) {
		if(!iscallable(h))
			throwtype("Symbol.hasInstance is not callable");
		return tobool(call(h.o, c, array[] of {v}));
	}
	if(c.o.fun == nil)
		throwtype("Right-hand side of 'instanceof' is not callable");
	return ordinaryhasinstance(c.o, v);
}

ordinaryhasinstance(c: ref Obj, v: V): int
{
	if(c.fun == nil)
		return 0;
	if(c.data != nil)
	pick d := c.data {
	Bound =>
		return instanceof(v, objv(d.target));
	}
	if(v.t != Tobj)
		return 0;
	p := getv(c, a_prototype);
	if(p.t != Tobj)
		throwtype("Function has non-object prototype in instanceof check");
	for(o := getprotoof(v.o); o != nil; o = getprotoof(o))
		if(o == p.o)
			return 1;
	return 0;
}

# ---- helpers for the built-ins ----

arg(args: array of V, i: int): V
{
	if(i < len args)
		return args[i];
	return undef;
}

newarray(n: int): ref Obj
{
	o := ref Obj;
	gcnew(o);
	o.sh = emptyshape(arrproto);
	o.cls = Carray;
	o.flags = Fext;
	if(n > 0)
		o.elems = array[n] of {* => holev};
	o.alen = n;
	return o;
}

# an array of the values in a
mkarray(a: array of V): ref Obj
{
	o := ref Obj;
	gcnew(o);
	o.sh = emptyshape(arrproto);
	o.cls = Carray;
	o.flags = Fext;
	n := len a;
	if(n < 4)
		o.elems = array[4] of {* => holev};
	else
		o.elems = array[n] of V;
	o.elems[0:] = a;
	o.alen = n;
	return o;
}

# push onto an ordinary array the engine made
apush(o: ref Obj, v: V)
{
	i := o.alen;
	if(o.elems == nil || i >= len o.elems)
		growelems(o, i + 1);
	o.elems[i] = v;
	o.alen = i + 1;
}

# CreateListFromArrayLike
listfrom(v: V): array of V
{
	if(v.t != Tobj)
		throwtype("CreateListFromArrayLike called on non-object");
	o := v.o;
	if(o.cls == Carray && (o.flags & Fslow) == 0 && !protohasidx(o)) {
		n := o.alen;
		a := array[n] of V;
		for(i := 0; i < n; i++) {
			if(i < len o.elems && o.elems[i].t != Thole)
				a[i] = o.elems[i];
			else
				a[i] = undef;
		}
		return a;
	}
	n := lengthof(o);
	if(n > 10000000.0)
		throwerr(ERange, "Too many arguments");
	a := array[int n] of V;
	for(i := 0; i < len a; i++)
		a[i] = getidx(o, i, v);
	return a;
}

# a function property of v, or nil (GetMethod)
getmethod(v: V, k: int): ref Obj
{
	f := getvalue(v, k);
	if(f.t == Tundef || f.t == Tnull)
		return nil;
	if(!iscallable(f))
		throwtype(sys->sprint("%s is not a function", keyname(k)));
	return f.o;
}

# Invoke
invoke(v: V, k: int, args: array of V): V
{
	f := getvalue(v, k);
	if(!iscallable(f))
		throwtype(sys->sprint("%s is not a function", keyname(k)));
	return call(f.o, v, args);
}

# SpeciesConstructor
speciesctor(o: ref Obj, dflt: ref Obj): ref Obj
{
	c := getv(o, a_constructor);
	if(c.t == Tundef)
		return dflt;
	if(c.t != Tobj)
		throwtype("object.constructor is not an object");
	s := getv(c.o, a_symspecies);
	if(s.t == Tundef || s.t == Tnull)
		return dflt;
	if(s.t == Tobj && isctor(s.o))
		return s.o;
	throwtype("object.constructor[Symbol.species] is not a constructor");
	return nil;
}

# GetPrototypeFromConstructor
protofromctor(nt: ref Obj, dflt: ref Obj): ref Obj
{
	if(nt == nil)
		return dflt;
	p := getv(nt, a_prototype);
	if(p.t == Tobj)
		return p.o;
	# the realm of nt (GetFunctionRealm): one realm per engine instance, so ours,
	# unless it is a revoked proxy
	for(f := nt; f != nil && f.cls == Cproxy; ) {
		pick d := f.data {
		Proxy =>
			if(d.handler == nil)
				throwtype("Cannot get the realm of a proxy that has been revoked");
			f = d.target;
		* =>
			f = nil;
		}
	}
	return dflt;
}

# OrdinaryCreateFromConstructor
fromctor(nt: ref Obj, dflt: ref Obj, cls: int): ref Obj
{
	return newobj(cls, protofromctor(nt, dflt));
}

# what a value is shown as in messages
showv(v: V): string
{
	case v.t {
	Tstr or Trope =>
		s := flat(v);
		if(len s > 40)
			s = s[0:40] + "...";
		return "\"" + s + "\"";
	Tsym =>
		return keyname(symatom(v.o));
	Tobj =>
		if(v.o.fun != nil) {
			n := fnname(v.o);
			if(n != nil)
				return "function " + n;
			return "function";
		}
		if(v.o.cls == Carray)
			return "[object Array]";
		return "[object Object]";
	}
	return tostr(v);
}

fnname(o: ref Obj): string
{
	s := slotof(o.sh, a_name);
	if(s >= 0 && (o.sh.attrs[s] & Aacc) == 0 && isstr(o.slots[s]))
		return flat(o.slots[s]);
	return nil;
}
