#
# jsiarray.b - Array, its prototype and its iterator.
#
# The methods are the specification's generic algorithms, over any
# array-like, with the dense ordinary array done directly where that is
# common.
#

NArray, NAfrom, NAisarray, NAof, NAfromasync, NAPat, NAPconcat, NAPcopywithin, NAPentries, NAPevery,
NAPfill, NAPfilter, NAPfind, NAPfindindex, NAPfindlast, NAPfindlastindex, NAPflat, NAPflatmap,
NAPforeach, NAPincludes, NAPindexof, NAPjoin, NAPkeys, NAPlastindexof, NAPmap, NAPpop, NAPpush,
NAPreduce, NAPreduceright, NAPreverse, NAPshift, NAPslice, NAPsome, NAPsort, NAPsplice,
NAPtolocale, NAPtoreversed, NAPtosorted, NAPtospliced, NAPtostring, NAPunshift, NAPvalues,
NAPwith, NAInext, NAspecies, NAlast: con 100 + iota;

Ikeys, Ivalues, Ientries: con iota;
# other iterators' kinds (Data.Iter.kind)
Iasyncfromsync: con 10;

arrayinit()
{
	arrayctor = defctor("Array", NArray, 1, arrproto);
	c := arrayctor;
	defmethod(c, "from", NAfrom, 1);
	defmethod(c, "isArray", NAisarray, 1);
	defmethod(c, "of", NAof, 0);
	defmethod(c, "fromAsync", NAfromasync, 1);
	defaccessor(c, a_symspecies, "[Symbol.species]", NAspecies, 0);
	p := arrproto;
	defmethod(p, "at", NAPat, 1);
	defmethod(p, "concat", NAPconcat, 1);
	defmethod(p, "copyWithin", NAPcopywithin, 2);
	defmethod(p, "entries", NAPentries, 0);
	defmethod(p, "every", NAPevery, 1);
	defmethod(p, "fill", NAPfill, 1);
	defmethod(p, "filter", NAPfilter, 1);
	defmethod(p, "find", NAPfind, 1);
	defmethod(p, "findIndex", NAPfindindex, 1);
	defmethod(p, "findLast", NAPfindlast, 1);
	defmethod(p, "findLastIndex", NAPfindlastindex, 1);
	defmethod(p, "flat", NAPflat, 0);
	defmethod(p, "flatMap", NAPflatmap, 1);
	defmethod(p, "forEach", NAPforeach, 1);
	defmethod(p, "includes", NAPincludes, 1);
	defmethod(p, "indexOf", NAPindexof, 1);
	defmethod(p, "join", NAPjoin, 1);
	defmethod(p, "keys", NAPkeys, 0);
	defmethod(p, "lastIndexOf", NAPlastindexof, 1);
	defmethod(p, "map", NAPmap, 1);
	defmethod(p, "pop", NAPpop, 0);
	defmethod(p, "push", NAPpush, 1);
	defmethod(p, "reduce", NAPreduce, 1);
	defmethod(p, "reduceRight", NAPreduceright, 1);
	defmethod(p, "reverse", NAPreverse, 0);
	defmethod(p, "shift", NAPshift, 0);
	defmethod(p, "slice", NAPslice, 2);
	defmethod(p, "some", NAPsome, 1);
	defmethod(p, "sort", NAPsort, 1);
	defmethod(p, "splice", NAPsplice, 2);
	defmethod(p, "toLocaleString", NAPtolocale, 0);
	defmethod(p, "toReversed", NAPtoreversed, 0);
	defmethod(p, "toSorted", NAPtosorted, 1);
	defmethod(p, "toSpliced", NAPtospliced, 2);
	defmethod(p, "toString", NAPtostring, 0);
	defmethod(p, "unshift", NAPunshift, 1);
	vals := defmethod(p, "values", NAPvalues, 0);
	defmethod(p, "with", NAPwith, 2);
	defprop(p, a_symiterator, objv(vals), Awrite|Aconf);
	arrayvalues = vals;
	u := newobj(Cplain, nil);
	for(l := array[] of {"at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast", "findLastIndex",
		"flat", "flatMap", "includes", "keys", "toReversed", "toSorted", "toSpliced", "values"} ; ; ) {
		for(i := 0; i < len l; i++)
			addprop(u, intern(l[i]), Adefault, truev);
		break;
	}
	defprop(p, a_symunscopables, objv(u), Aconf);
	arrayiternextfn = defmethod(arrayiterproto, "next", NAInext, 0);
	defprop(arrayiterproto, a_symtostringtag, strv("Array Iterator"), Aconf);
}

# the index i of o (i past 2^31 by its string)
gidx(o: ref Obj, i: real, recv: V): V
{
	if(i < 2147483647.0)
		return getidx(o, int i, recv);
	return get(o, realkey(i), recv);
}

realkey(i: real): int
{
	if(i < 2147483647.0 && i >= 0.0)
		return idxatom(int i);
	return intern(numstr(i));
}

hasidx(o: ref Obj, i: real): int
{
	if(o.cls == Carray && (o.flags & Fslow) == 0 && i < real len o.elems && o.elems[int i].t != Thole)
		return 1;
	return hasprop(o, realkey(i));
}

# Set(o, i, v, true)
sidx(o: ref Obj, i: real, v: V)
{
	if(i < 2147483647.0 && setelem(o, int i, v))
		return;
	k := realkey(i);
	if(!put(o, k, v, objv(o)))
		throwtype("Cannot assign to read only property '" + atomstr[k] + "' of object");
}

# DeletePropertyOrThrow
didx(o: ref Obj, i: real)
{
	k := realkey(i);
	if(!deleteprop(o, k))
		throwtype("Cannot delete property '" + atomstr[k] + "' of object");
}

setlength(o: ref Obj, n: real)
{
	if(o.cls == Carray && (o.flags & Ffrozenlen) == 0 && n <= 2147483647.0) {
		if(n >= real o.alen && (o.flags & Fbiglen) == 0) {
			o.alen = int n;
			return;
		}
		setarrlen(o, n);
		return;
	}
	if(!put(o, a_length, numv(n), objv(o)))
		throwtype("Cannot assign to read only property 'length' of object");
}

# ArraySpeciesCreate
speciescreate(o: ref Obj, n: real): ref Obj
{
	if(n == 0.0)
		n = 0.0;	# the constructor is given +0, never -0
	if(!isarray(objv(o)))
		return arraycreate(n);
	c := getv(o, a_constructor);
	if(c.t == Tobj && isctor(c.o) && c.o != arrayctor) {
		# another realm's Array would count as undefined; there is only one realm
		;
	}
	if(c.t == Tobj) {
		c = getv(c.o, a_symspecies);
		if(c.t == Tnull)
			c = undef;
	}
	if(c.t == Tundef || c.t == Tobj && c.o == arrayctor)
		return arraycreate(n);
	if(c.t != Tobj || !isctor(c.o))
		throwtype("object.constructor[Symbol.species] is not a constructor");
	r := construct(c.o, array[] of {numv(n)}, c.o);
	return r.o;
}

arraycreate(n: real): ref Obj
{
	if(n > 4294967295.0)
		throwerr(ERange, "Invalid array length");
	if(n <= 1000000.0)
		return newarray(int n);
	a := newarray(0);
	setlen(a, n);
	return a;
}

callback(args: array of V): ref Obj
{
	f := arg(args, 0);
	if(!iscallable(f))
		throwtype(showv(f) + " is not a function");
	return f.o;
}

# relative index: (start, from len)
relidx(v: V, n: real, dflt: real): real
{
	if(v.t == Tundef)
		return dflt;
	x := tointeger(v);
	if(x < 0.0) {
		x += n;
		if(x < 0.0)
			x = 0.0;
	} else if(x > n)
		x = n;
	return x;
}

# whether o is a dense ordinary array, its elements all present below its length
dense(o: ref Obj): int
{
	if(o.cls != Carray || (o.flags & (Fslow|Fbiglen)) != 0 || o.alen > len o.elems)
		return 0;
	return 1;
}

natarray(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NArray =>
		proto := protofromctor(nt, arrproto);
		a: ref Obj;
		if(len args == 1) {
			l := args[0];
			if(isnum(l)) {
				n := touint32(l);
				if(n != numof(l))
					throwerr(ERange, "Invalid array length");
				a = arraycreate(n);
			} else
				a = mkarray(args);
		} else
			a = mkarray(args);
		if(proto != arrproto)
			setproto(a, proto);
		f = f;
		return objv(a);
	NAfrom =>
		return arrayfrom(this, args);
	NAisarray =>
		return boolv(isarray(arg(args, 0)));
	NAof =>
		a: ref Obj;
		if(this.t == Tobj && isctor(this.o) && this.o != arrayctor)
			a = construct(this.o, array[] of {intv(len args)}, this.o).o;
		else
			a = newarray(0);
		for(i := 0; i < len args; i++)
			createdatathrow(a, idxatom(i), args[i]);
		setlength(a, real len args);
		return objv(a);
	NAfromasync =>
		return arrayfromasync(this, args);
	NAspecies =>
		return this;
	NAInext =>
		return arrayiternext(this);
	}
	o := toobj(this);
	recv := objv(o);
	case id {
	NAPat =>
		n := lengthof(o);
		k := tointeger(arg(args, 0));
		if(k < 0.0)
			k += n;
		if(k < 0.0 || k >= n)
			return undef;
		return gidx(o, k, recv);
	NAPconcat =>
		a := speciescreate(o, 0.0);
		n := 0.0;
		for(i := -1; i < len args; i++) {
			e := recv;
			if(i >= 0)
				e = args[i];
			if(isspreadable(e)) {
				eo := e.o;
				m := lengthof(eo);
				if(n + m > 9007199254740991.0)
					throwtype("Array too long");
				if(dense(eo) && a.cls == Carray && !protohasidx(eo)) {
					for(j := 0; j < int m; j++) {
						if(j < len eo.elems && eo.elems[j].t != Thole)
							createdatathrow(a, idxatom(int n + j), eo.elems[j]);
					}
				} else
					for(j := 0.0; j < m; j += 1.0)
						if(hasidx(eo, j))
							createdatathrow(a, realkey(n + j), gidx(eo, j, e));
				n += m;
			} else {
				if(n >= 9007199254740991.0)
					throwtype("Array too long");
				createdatathrow(a, realkey(n), e);
				n += 1.0;
			}
		}
		setlength(a, n);
		return objv(a);
	NAPcopywithin =>
		n := lengthof(o);
		dst := relidx(arg(args, 0), n, 0.0);
		from := relidx(arg(args, 1), n, 0.0);
		end := relidx(arg(args, 2), n, n);
		count := end - from;
		if(n - dst < count)
			count = n - dst;
		dir := 1.0;
		if(from < dst && dst < from + count) {
			dir = -1.0;
			from += count - 1.0;
			dst += count - 1.0;
		}
		while(count > 0.0) {
			if(hasidx(o, from))
				sidx(o, dst, gidx(o, from, recv));
			else
				didx(o, dst);
			from += dir;
			dst += dir;
			count -= 1.0;
		}
		return recv;
	NAPentries =>
		return objv(arrayiter(o, Ientries));
	NAPkeys =>
		return objv(arrayiter(o, Ikeys));
	NAPvalues =>
		return objv(arrayiter(o, Ivalues));
	NAPevery or NAPsome or NAPforeach or NAPmap or NAPfilter =>
		n := lengthof(o);
		cb := callback(args);
		t := arg(args, 1);
		a: ref Obj;
		if(id == NAPmap)
			a = speciescreate(o, n);
		else if(id == NAPfilter)
			a = speciescreate(o, 0.0);
		dst := 0.0;
		cargs := array[3] of V;
		for(i := 0.0; i < n; i += 1.0) {
			if(!hasidx(o, i))
				continue;
			v := gidx(o, i, recv);
			cargs = array[3] of V;
			cargs[0] = v;
			cargs[1] = numv(i);
			cargs[2] = recv;
			r := call(cb, t, cargs);
			case id {
			NAPevery =>
				if(!tobool(r))
					return falsev;
			NAPsome =>
				if(tobool(r))
					return truev;
			NAPmap =>
				createdatathrow(a, realkey(i), r);
			NAPfilter =>
				if(tobool(r)) {
					createdatathrow(a, realkey(dst), v);
					dst += 1.0;
				}
			}
		}
		case id {
		NAPevery =>
			return truev;
		NAPsome =>
			return falsev;
		NAPmap or NAPfilter =>
			return objv(a);
		}
		return undef;
	NAPfill =>
		n := lengthof(o);
		v := arg(args, 0);
		k := relidx(arg(args, 1), n, 0.0);
		end := relidx(arg(args, 2), n, n);
		for(; k < end; k += 1.0)
			sidx(o, k, v);
		return recv;
	NAPfind or NAPfindindex or NAPfindlast or NAPfindlastindex =>
		n := lengthof(o);
		cb := callback(args);
		t := arg(args, 1);
		last := id == NAPfindlast || id == NAPfindlastindex;
		i := 0.0;
		if(last)
			i = n - 1.0;
		while(last && i >= 0.0 || !last && i < n) {
			v := gidx(o, i, recv);
			if(tobool(call(cb, t, array[] of {v, numv(i), recv}))) {
				if(id == NAPfind || id == NAPfindlast)
					return v;
				return numv(i);
			}
			if(last)
				i -= 1.0;
			else
				i += 1.0;
		}
		if(id == NAPfind || id == NAPfindlast)
			return undef;
		return intv(-1);
	NAPflat =>
		n := lengthof(o);
		d := 1.0;
		if(arg(args, 0).t != Tundef) {
			d = tointeger(args[0]);
			if(d < 0.0)
				d = 0.0;
		}
		a := speciescreate(o, 0.0);
		flatten(a, o, n, 0.0, d, nil, undef);
		return objv(a);
	NAPflatmap =>
		n := lengthof(o);
		cb := callback(args);
		a := speciescreate(o, 0.0);
		flatten(a, o, n, 0.0, 1.0, cb, arg(args, 1));
		return objv(a);
	NAPincludes or NAPindexof =>
		n := lengthof(o);
		if(n == 0.0)
			if(id == NAPincludes)
				return falsev;
			else
				return intv(-1);
		k := tointeger(arg(args, 1));
		if(k == inf)
			if(id == NAPincludes)
				return falsev;
			else
				return intv(-1);
		if(k < 0.0) {
			k += n;
			if(k < 0.0)
				k = 0.0;
		}
		x := arg(args, 0);
		if(dense(o) && !protohasidx(o)) {
			for(i := int k; i < o.alen && i < len o.elems; i++) {
				e := o.elems[i];
				if(e.t == Thole) {
					if(id == NAPincludes && x.t == Tundef)
						return truev;
					continue;
				}
				if(id == NAPincludes && samevaluezero(e, x) || id == NAPindexof && stricteq(e, x)) {
					if(id == NAPincludes)
						return truev;
					return intv(i);
				}
			}
			if(id == NAPincludes)
				return falsev;
			return intv(-1);
		}
		for(i := k; i < n; i += 1.0) {
			if(id == NAPincludes) {
				if(samevaluezero(gidx(o, i, recv), x))
					return truev;
			} else if(hasidx(o, i) && stricteq(gidx(o, i, recv), x))
				return numv(i);
		}
		if(id == NAPincludes)
			return falsev;
		return intv(-1);
	NAPlastindexof =>
		n := lengthof(o);
		if(n == 0.0)
			return intv(-1);
		k := n - 1.0;
		if(len args > 1) {
			k = tointeger(args[1]);
			if(k < 0.0)
				k += n;
			else if(k > n - 1.0)
				k = n - 1.0;
		}
		x := arg(args, 0);
		for(i := k; i >= 0.0; i -= 1.0)
			if(hasidx(o, i) && stricteq(gidx(o, i, recv), x))
				return numv(i + 0.0);	# not -0
		return intv(-1);
	NAPjoin =>
		return strv(arrjoin(o, arg(args, 0)));
	NAPpop =>
		if(dense(o) && (o.flags & Fext) && o.alen > 0 && !protohasidx(o)) {
			i := o.alen - 1;
			v := o.elems[i];
			o.elems[i] = holev;
			o.alen = i;
			if(v.t == Thole)
				return undef;
			return v;
		}
		n := lengthof(o);
		if(n == 0.0) {
			setlength(o, 0.0);
			return undef;
		}
		v := gidx(o, n - 1.0, recv);
		didx(o, n - 1.0);
		setlength(o, n - 1.0);
		return v;
	NAPpush =>
		if(dense(o) && (o.flags & (Fext|Ffrozenlen)) == Fext && !protohasidx(o)) {
			for(i := 0; i < len args; i++)
				apush(o, args[i]);
			return intv(o.alen);
		}
		n := lengthof(o);
		if(n + real len args > 9007199254740991.0)
			throwtype("Pushing elements past 2^53-1");
		for(i := 0; i < len args; i++) {
			sidx(o, n, args[i]);
			n += 1.0;
		}
		setlength(o, n);
		return numv(n);
	NAPreduce or NAPreduceright =>
		n := lengthof(o);
		cb := callback(args);
		right := id == NAPreduceright;
		i := 0.0;
		step := 1.0;
		if(right) {
			i = n - 1.0;
			step = -1.0;
		}
		acc: V;
		if(len args > 1)
			acc = args[1];
		else {
			found := 0;
			while(right && i >= 0.0 || !right && i < n) {
				if(hasidx(o, i)) {
					acc = gidx(o, i, recv);
					found = 1;
					i += step;
					break;
				}
				i += step;
			}
			if(!found)
				throwtype("Reduce of empty array with no initial value");
		}
		while(right && i >= 0.0 || !right && i < n) {
			if(hasidx(o, i))
				acc = call(cb, undef, array[] of {acc, gidx(o, i, recv), numv(i), recv});
			i += step;
		}
		return acc;
	NAPreverse =>
		n := lengthof(o);
		mid := math->floor(n / 2.0);
		for(lo := 0.0; lo < mid; lo += 1.0) {
			up := n - lo - 1.0;
			le := hasidx(o, lo);
			lv := undef;
			if(le)
				lv = gidx(o, lo, recv);
			ue := hasidx(o, up);
			uv := undef;
			if(ue)
				uv = gidx(o, up, recv);
			if(le && ue) {
				sidx(o, lo, uv);
				sidx(o, up, lv);
			} else if(ue) {
				sidx(o, lo, uv);
				didx(o, up);
			} else if(le) {
				didx(o, lo);
				sidx(o, up, lv);
			}
		}
		return recv;
	NAPshift =>
		if(dense(o) && (o.flags & (Fext|Ffrozenlen)) == Fext && o.alen > 0 && !protohasidx(o) && allpresent(o)) {
			v := o.elems[0];
			o.elems[0:] = o.elems[1:o.alen];
			o.elems[o.alen - 1] = holev;
			o.alen--;
			return v;
		}
		n := lengthof(o);
		if(n == 0.0) {
			setlength(o, 0.0);
			return undef;
		}
		first := gidx(o, 0.0, recv);
		for(k := 1.0; k < n; k += 1.0) {
			if(hasidx(o, k))
				sidx(o, k - 1.0, gidx(o, k, recv));
			else
				didx(o, k - 1.0);
		}
		didx(o, n - 1.0);
		setlength(o, n - 1.0);
		return first;
	NAPslice =>
		n := lengthof(o);
		k := relidx(arg(args, 0), n, 0.0);
		end := relidx(arg(args, 1), n, n);
		count := end - k;
		if(count < 0.0)
			count = 0.0;
		if(dense(o) && !protohasidx(o) && o.sh.proto == arrproto && !hasownctor(o)) {
			a := newarray(0);
			c := int count;
			a.elems = array[c + 1] of {* => holev};
			a.elems[0:] = o.elems[int k:int k + c];
			a.alen = c;
			return objv(a);
		}
		a := speciescreate(o, count);
		j := 0.0;
		for(; k < end; k += 1.0) {
			if(hasidx(o, k))
				createdatathrow(a, realkey(j), gidx(o, k, recv));
			j += 1.0;
		}
		setlength(a, j);
		return objv(a);
	NAPsort =>
		cmp := arg(args, 0);
		if(cmp.t != Tundef && !iscallable(cmp))
			throwtype("The comparison function must be either a function or undefined");
		n := lengthof(o);
		items := collect(o, n, 1);
		sortv(items, cmp);
		i := 0;
		for(; i < len items; i++)
			sidx(o, real i, items[i]);
		for(x := real i; x < n; x += 1.0)
			if(hasidx(o, x))
				didx(o, x);
		return recv;
	NAPsplice =>
		n := lengthof(o);
		start := relidx(arg(args, 0), n, 0.0);
		dc := 0.0;
		ni := 0;
		if(len args == 0)
			dc = 0.0;
		else if(len args == 1)
			dc = n - start;
		else {
			dc = tointeger(args[1]);
			if(dc < 0.0)
				dc = 0.0;
			if(dc > n - start)
				dc = n - start;
			ni = len args - 2;
		}
		if(n + real ni - dc > 9007199254740991.0)
			throwtype("Splicing past 2^53-1");
		a := speciescreate(o, dc);
		for(k := 0.0; k < dc; k += 1.0)
			if(hasidx(o, start + k))
				createdatathrow(a, realkey(k), gidx(o, start + k, recv));
		setlength(a, dc);
		items := real ni;
		if(items < dc) {
			for(k = start; k < n - dc; k += 1.0) {
				from := k + dc;
				dst := k + items;
				if(hasidx(o, from))
					sidx(o, dst, gidx(o, from, recv));
				else
					didx(o, dst);
			}
			for(k = n; k > n - dc + items; k -= 1.0)
				didx(o, k - 1.0);
		} else if(items > dc) {
			for(k = n - dc; k > start; k -= 1.0) {
				from := k + dc - 1.0;
				dst := k + items - 1.0;
				if(hasidx(o, from))
					sidx(o, dst, gidx(o, from, recv));
				else
					didx(o, dst);
			}
		}
		for(i := 0; i < ni; i++)
			sidx(o, start + real i, args[i + 2]);
		setlength(o, n - dc + items);
		return objv(a);
	NAPtolocale =>
		n := lengthof(o);
		s := "";
		for(i := 0.0; i < n; i += 1.0) {
			if(i > 0.0)
				s += ",";
			v := gidx(o, i, recv);
			if(v.t != Tundef && v.t != Tnull)
				s += tostr(invoke(v, intern("toLocaleString"), nil));
		}
		return strv(s);
	NAPtoreversed =>
		n := lengthof(o);
		a := arraycreate(n);
		for(i := 0.0; i < n; i += 1.0)
			createdatathrow(a, realkey(i), gidx(o, n - 1.0 - i, recv));
		return objv(a);
	NAPtosorted =>
		cmp := arg(args, 0);
		if(cmp.t != Tundef && !iscallable(cmp))
			throwtype("The comparison function must be either a function or undefined");
		n := lengthof(o);
		a := arraycreate(n);
		items := collect(o, n, 0);
		sortv(items, cmp);
		for(i := 0; i < len items; i++)
			createdatathrow(a, idxatom(i), items[i]);
		return objv(a);
	NAPtospliced =>
		n := lengthof(o);
		start := relidx(arg(args, 0), n, 0.0);
		skip := 0.0;
		ni := 0;
		if(len args == 0)
			skip = 0.0;
		else if(len args == 1)
			skip = n - start;
		else {
			skip = tointeger(args[1]);
			if(skip < 0.0)
				skip = 0.0;
			if(skip > n - start)
				skip = n - start;
			ni = len args - 2;
		}
		nl := n + real ni - skip;
		if(nl > 9007199254740991.0)
			throwtype("Array too long");
		a := arraycreate(nl);
		i := 0.0;
		r := 0.0;
		for(; i < start; i += 1.0)
			createdatathrow(a, realkey(i), gidx(o, i, recv));
		for(j := 0; j < ni; j++) {
			createdatathrow(a, realkey(i), args[j + 2]);
			i += 1.0;
		}
		for(r = start + skip; i < nl; r += 1.0) {
			createdatathrow(a, realkey(i), gidx(o, r, recv));
			i += 1.0;
		}
		return objv(a);
	NAPtostring =>
		j := getv(o, a_join);
		if(iscallable(j))
			return call(j.o, recv, nil);
		return strv(objtostring(recv));
	NAPunshift =>
		n := lengthof(o);
		c := real len args;
		if(c > 0.0) {
			if(n + c > 9007199254740991.0)
				throwtype("Unshifting past 2^53-1");
			for(k := n; k > 0.0; k -= 1.0) {
				from := k - 1.0;
				dst := k + c - 1.0;
				if(hasidx(o, from))
					sidx(o, dst, gidx(o, from, recv));
				else
					didx(o, dst);
			}
			for(i := 0; i < len args; i++)
				sidx(o, real i, args[i]);
		}
		setlength(o, n + c);
		return numv(n + c);
	NAPwith =>
		n := lengthof(o);
		k := tointeger(arg(args, 0));
		if(k < 0.0)
			k += n;
		if(k >= n || k < 0.0)
			throwerr(ERange, "Invalid index : " + numstr(k));
		a := arraycreate(n);
		for(i := 0.0; i < n; i += 1.0) {
			v: V;
			if(i == k)
				v = arg(args, 1);
			else
				v = gidx(o, i, recv);
			createdatathrow(a, realkey(i), v);
		}
		return objv(a);
	}
	throwerr(EError, "unknown Array built-in " + string id);
	return undef;
}

hasownctor(o: ref Obj): int
{
	return o.sh.n > 0 && slotof(o.sh, a_constructor) >= 0;
}

allpresent(o: ref Obj): int
{
	for(i := 0; i < o.alen; i++)
		if(o.elems[i].t == Thole)
			return 0;
	return 1;
}

isspreadable(v: V): int
{
	if(v.t != Tobj)
		return 0;
	s := getv(v.o, a_symisconcatspreadable);
	if(s.t != Tundef)
		return tobool(s);
	return isarray(v);
}

# FlattenIntoArray
flatten(a: ref Obj, src: ref Obj, n: real, start: real, depth: real, mapper: ref Obj, t: V): real
{
	target := start;
	recv := objv(src);
	for(i := 0.0; i < n; i += 1.0) {
		if(!hasidx(src, i))
			continue;
		e := gidx(src, i, recv);
		if(mapper != nil)
			e = call(mapper, t, array[] of {e, numv(i), recv});
		if(depth > 0.0 && isarray(e)) {
			target = flatten(a, e.o, lengthof(e.o), target, depth - 1.0, nil, undef);
			continue;
		}
		if(target >= 9007199254740991.0)
			throwtype("Array too long");
		createdatathrow(a, realkey(target), e);
		target += 1.0;
	}
	return target;
}

arrjoin(o: ref Obj, sepv: V): string
{
	n := lengthof(o);
	sep := ",";
	if(sepv.t != Tundef)
		sep = tostr(sepv);
	if(n == 0.0)
		return "";
	# a cycle (an array that contains itself) joins as empty
	for(l := joining; l != nil; l = tl l)
		if(hd l == o)
			return "";
	joining = o :: joining;
	parts := array[int n] of string;
	{
		recv := objv(o);
		for(i := 0; i < len parts; i++) {
			v := gidx(o, real i, recv);
			if(v.t != Tundef && v.t != Tnull)
				parts[i] = tostr(v);
		}
	} exception {
	"JS*" =>
		joining = tl joining;
		raise;
	}
	joining = tl joining;
	return joinsep(parts, sep);
}

joining: list of ref Obj;

joinsep(parts: array of string, sep: string): string
{
	if(len parts == 0)
		return "";
	if(sep == nil)
		return joinall(parts);
	a := array[2 * len parts - 1] of string;
	for(i := 0; i < len parts; i++) {
		a[2 * i] = parts[i];
		if(i > 0)
			a[2 * i - 1] = sep;
	}
	return joinall(a);
}

# the values of o below n: present ones only (holes: 1), or all (undefined for holes)
collect(o: ref Obj, n: real, skipholes: int): array of V
{
	l: list of V;
	c := 0;
	recv := objv(o);
	for(i := 0.0; i < n; i += 1.0) {
		if(skipholes && !hasidx(o, i))
			continue;
		l = gidx(o, i, recv) :: l;
		c++;
	}
	a := array[c] of V;
	for(j := c - 1; j >= 0; j--) {
		a[j] = hd l;
		l = tl l;
	}
	return a;
}

# a stable merge sort with SortCompare: undefined last
sortv(a: array of V, cmp: V)
{
	n := len a;
	# undefined go to the end, not compared
	j := 0;
	nu := 0;
	for(i := 0; i < n; i++) {
		if(a[i].t == Tundef)
			nu++;
		else
			a[j++] = a[i];
	}
	for(i = j; i < n; i++)
		a[i] = undef;
	m := j;
	if(m < 2)
		return;
	b := array[m] of V;
	keys: array of string;
	if(cmp.t == Tundef) {
		keys = array[m] of string;
		for(i = 0; i < m; i++)
			keys[i] = tostr(a[i]);
		msortstr(a[0:m], keys, b, array[m] of string);
		return;
	}
	msortcmp(a[0:m], b, cmp.o);
}

msortstr(a: array of V, k: array of string, b: array of V, kb: array of string)
{
	n := len a;
	if(n < 2)
		return;
	if(n <= 8) {
		for(i := 1; i < n; i++) {
			x := a[i];
			xk := k[i];
			j := i - 1;
			for(; j >= 0 && k[j] > xk; j--) {
				a[j+1] = a[j];
				k[j+1] = k[j];
			}
			a[j+1] = x;
			k[j+1] = xk;
		}
		return;
	}
	m := n / 2;
	msortstr(a[0:m], k[0:m], b[0:m], kb[0:m]);
	msortstr(a[m:], k[m:], b[m:], kb[m:]);
	b[0:] = a;
	kb[0:] = k;
	i := 0;
	j := m;
	o := 0;
	while(i < m && j < n) {
		if(kb[j] < kb[i]) {
			a[o] = b[j];
			k[o++] = kb[j++];
		} else {
			a[o] = b[i];
			k[o++] = kb[i++];
		}
	}
	while(i < m) {
		a[o] = b[i];
		k[o++] = kb[i++];
	}
	while(j < n) {
		a[o] = b[j];
		k[o++] = kb[j++];
	}
}

sortcompare(x, y: V, cmp: ref Obj): real
{
	r := tonum(call(cmp, undef, array[] of {x, y}));
	if(isnan(r))
		return 0.0;
	return r;
}

msortcmp(a, b: array of V, cmp: ref Obj)
{
	n := len a;
	if(n < 2)
		return;
	if(n <= 8) {
		for(i := 1; i < n; i++) {
			x := a[i];
			j := i - 1;
			for(; j >= 0 && sortcompare(a[j], x, cmp) > 0.0; j--)
				a[j+1] = a[j];
			a[j+1] = x;
		}
		return;
	}
	m := n / 2;
	msortcmp(a[0:m], b[0:m], cmp);
	msortcmp(a[m:], b[m:], cmp);
	b[0:] = a;
	i := 0;
	j := m;
	o := 0;
	while(i < m && j < n) {
		if(sortcompare(b[j], b[i], cmp) < 0.0)
			a[o++] = b[j++];
		else
			a[o++] = b[i++];
	}
	while(i < m)
		a[o++] = b[i++];
	while(j < n)
		a[o++] = b[j++];
}

# ---- Array.from ----

arrayfrom(this: V, args: array of V): V
{
	items := arg(args, 0);
	mapfn := arg(args, 1);
	t := arg(args, 2);
	if(mapfn.t != Tundef && !iscallable(mapfn))
		throwtype(showv(mapfn) + " is not a function");
	usector := this.t == Tobj && isctor(this.o) && this.o != arrayctor;
	m := getmethod(items, a_symiterator);
	if(m != nil) {
		a: ref Obj;
		if(usector)
			a = construct(this.o, nil, this.o).o;
		else
			a = newarray(0);
		it := call(m, items, nil);
		if(it.t != Tobj)
			throwtype("Result of the Symbol.iterator method is not an object");
		next := getvalue(it, a_next);
		k := 0.0;
		for(;;) {
			r := call1(next, it, nil);
			if(r.t != Tobj)
				throwtype("Iterator result is not an object");
			if(tobool(getv(r.o, a_done))) {
				setlength(a, k);
				return objv(a);
			}
			v := getv(r.o, a_value);
			{
				if(mapfn.t != Tundef)
					v = call(mapfn.o, t, array[] of {v, numv(k)});
				createdatathrow(a, realkey(k), v);
			} exception {
			"JS" =>
				ex := thrown;
				iterclose(it, 1);
				throwv(ex);
			}
			k += 1.0;
		}
	}
	src := toobj(items);
	n := lengthof(src);
	a: ref Obj;
	if(usector)
		a = construct(this.o, array[] of {numv(n)}, this.o).o;
	else
		a = arraycreate(n);
	for(k := 0.0; k < n; k += 1.0) {
		v := gidx(src, k, objv(src));
		if(mapfn.t != Tundef)
			v = call(mapfn.o, t, array[] of {v, numv(k)});
		createdatathrow(a, realkey(k), v);
	}
	setlength(a, n);
	return objv(a);
}

# Array.fromAsync: not yet
arrayfromasync(this: V, args: array of V): V
{
	return asyncnative(Xfromasync, this, args);
}

# ---- the array iterator ----

arrayiter(o: ref Obj, kind: int): ref Obj
{
	it := newobj(Citer, arrayiterproto);
	it.data = ref Data.Iter(kind, o, undef, 0, 0, nil);
	return it;
}

arrayiternext(this: V): V
{
	if(this.t != Tobj || this.o.cls != Citer || this.o.sh.proto == nil)
		throwtype("next method called on incompatible receiver " + showv(this));
	pick d := this.o.data {
	Iter =>
		if(d.kind > Ientries)
			break;
		if(d.done || d.o == nil)
			return iterresult(undef, 1);
		o := d.o;
		n: int;
		if(o.cls == Ctyped) {
			if(typedoutofbounds(o))
				throwtype("Cannot iterate a detached or out of bounds typed array");
			n = typedlength(o);
		} else if(o.cls == Carray)
			n = o.alen;
		else {
			x := lengthof(o);
			if(x > 2147483647.0)
				n = 16r7FFFFFFF;
			else
				n = int x;
		}
		i := d.i;
		if(i >= n) {
			d.done = 1;
			d.o = nil;
			return iterresult(undef, 1);
		}
		d.i = i + 1;
		case d.kind {
		Ikeys =>
			return iterresult(intv(i), 0);
		Ivalues =>
			return iterresult(getidx(o, i, objv(o)), 0);
		* =>
			return iterresult(objv(mkarray(array[] of {intv(i), getidx(o, i, objv(o))})), 0);
		}
	}
	throwtype("next method called on incompatible receiver " + showv(this));
	return undef;
}
