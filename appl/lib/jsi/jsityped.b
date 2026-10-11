#
# jsityped.b - ArrayBuffer, the typed arrays and DataView.  The byte
# conversions, Float16 and base64/hex follow appl/lib/js/jstyped.b's.
#
# A buffer is a Limbo byte array (little-endian, as the hosts are); a
# typed array is a view of one: its element type, byte offset, and
# length, or -1 for a length that tracks a resizable buffer.
#

Ty8, Tyu8, Tyu8c, Ty16, Tyu16, Ty32, Tyu32, Tyf16, Tyf32, Tyf64, Tyb64, Tybu64: con iota;

Bufmax: con 1 << 27;
tysize := array[] of {1, 1, 1, 2, 2, 4, 4, 2, 4, 8, 8, 8};
tyname := array[] of {"Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
	"Int32Array", "Uint32Array", "Float16Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"};
tyctor: array of ref Obj;
typroto: array of ref Obj;
typedarrayctor, typedarrayproto, abufproto, abufctor, dviewproto: ref Obj;

NArrayBuffer, NABisview, NABPbytelength, NABPmaxbytelength, NABPresizable, NABPdetached, NABPslice,
NABPresize, NABPtransfer, NABPtransferfixed, NTypedArray, NTAfrom, NTAof, NTAPbuffer, NTAPbytelength,
NTAPbyteoffset, NTAPlength, NTAPtag, NTAPat, NTAPcopywithin, NTAPentries, NTAPevery, NTAPfill,
NTAPfilter, NTAPfind, NTAPfindindex, NTAPfindlast, NTAPfindlastindex, NTAPforeach, NTAPincludes,
NTAPindexof, NTAPjoin, NTAPkeys, NTAPlastindexof, NTAPmap, NTAPreduce, NTAPreduceright, NTAPreverse,
NTAPset, NTAPslice, NTAPsome, NTAPsort, NTAPsubarray, NTAPtolocale, NTAPtoreversed, NTAPtosorted,
NTAPwith, NTAPvalues, NTyped, NDataView, NDVPbuffer, NDVPbytelength, NDVPbyteoffset, NDVPget, NDVPset,
NU8frombase64, NU8fromhex, NU8Ptobase64, NU8Ptohex, NU8Psetfrombase64, NU8Psetfromhex, NABspecies: con Ntypedbase + iota;

typedinit()
{
	abufproto = newobj(Cplain, objproto);
	abufctor = defctor("ArrayBuffer", NArrayBuffer, 1, abufproto);
	defmethod(abufctor, "isView", NABisview, 1);
	defaccessor(abufctor, a_symspecies, "[Symbol.species]", NABspecies, 0);
	p := abufproto;
	defgetter(p, "byteLength", NABPbytelength);
	defgetter(p, "maxByteLength", NABPmaxbytelength);
	defgetter(p, "resizable", NABPresizable);
	defgetter(p, "detached", NABPdetached);
	defmethod(p, "slice", NABPslice, 2);
	defmethod(p, "resize", NABPresize, 1);
	defmethod(p, "transfer", NABPtransfer, 0);
	defmethod(p, "transferToFixedLength", NABPtransferfixed, 0);
	defprop(p, a_symtostringtag, strv("ArrayBuffer"), Aconf);

	typedarrayproto = newobj(Cplain, objproto);
	ta := mknative(NTypedArray, "TypedArray", 0);
	ta.flags |= Fctor;
	typedarrayctor = ta;
	defprop(ta, a_prototype, objv(typedarrayproto), 0);
	defprop(typedarrayproto, a_constructor, objv(ta), Awrite|Aconf);
	defmethod(ta, "from", NTAfrom, 1);
	defmethod(ta, "of", NTAof, 0);
	defaccessor(ta, a_symspecies, "[Symbol.species]", NABspecies, 0);
	p = typedarrayproto;
	defgetter(p, "buffer", NTAPbuffer);
	defgetter(p, "byteLength", NTAPbytelength);
	defgetter(p, "byteOffset", NTAPbyteoffset);
	defaccessor(p, a_length, "length", NTAPlength, 0);
	defaccessor(p, a_symtostringtag, "[Symbol.toStringTag]", NTAPtag, 0);
	names := array[] of {("at", NTAPat, 1), ("copyWithin", NTAPcopywithin, 2), ("entries", NTAPentries, 0),
		("every", NTAPevery, 1), ("fill", NTAPfill, 1), ("filter", NTAPfilter, 1), ("find", NTAPfind, 1),
		("findIndex", NTAPfindindex, 1), ("findLast", NTAPfindlast, 1), ("findLastIndex", NTAPfindlastindex, 1),
		("forEach", NTAPforeach, 1), ("includes", NTAPincludes, 1), ("indexOf", NTAPindexof, 1), ("join", NTAPjoin, 1),
		("keys", NTAPkeys, 0), ("lastIndexOf", NTAPlastindexof, 1), ("map", NTAPmap, 1), ("reduce", NTAPreduce, 1),
		("reduceRight", NTAPreduceright, 1), ("reverse", NTAPreverse, 0), ("set", NTAPset, 1), ("slice", NTAPslice, 2),
		("some", NTAPsome, 1), ("sort", NTAPsort, 1), ("subarray", NTAPsubarray, 2), ("toLocaleString", NTAPtolocale, 0),
		("toReversed", NTAPtoreversed, 0), ("toSorted", NTAPtosorted, 1), ("with", NTAPwith, 2)};
	for(i := 0; i < len names; i++) {
		(nm, id, n) := names[i];
		defmethod(p, nm, id, n);
	}
	vals := defmethod(p, "values", NTAPvalues, 0);
	defprop(p, a_symiterator, objv(vals), Awrite|Aconf);
	defprop(p, a_toString, getv(arrproto, a_toString), Awrite|Aconf);
	tyctor = array[len tyname] of ref Obj;
	typroto = array[len tyname] of ref Obj;
	for(t := 0; t < len tyname; t++) {
		pr := newobj(Cplain, typedarrayproto);
		typroto[t] = pr;
		c := defctor(tyname[t], NTyped, 3, pr);
		c.data = ref Data.Native(intv(t), undef, 0, nil);
		setproto(c, ta);
		tyctor[t] = c;
		defprop(c, intern("BYTES_PER_ELEMENT"), intv(tysize[t]), 0);
		defprop(pr, intern("BYTES_PER_ELEMENT"), intv(tysize[t]), 0);
	}
	defmethod(tyctor[Tyu8], "fromBase64", NU8frombase64, 1);
	defmethod(tyctor[Tyu8], "fromHex", NU8fromhex, 1);
	defmethod(typroto[Tyu8], "toBase64", NU8Ptobase64, 0);
	defmethod(typroto[Tyu8], "toHex", NU8Ptohex, 0);
	defmethod(typroto[Tyu8], "setFromBase64", NU8Psetfrombase64, 1);
	defmethod(typroto[Tyu8], "setFromHex", NU8Psetfromhex, 1);

	dviewproto = newobj(Cplain, objproto);
	defctor("DataView", NDataView, 1, dviewproto);
	p = dviewproto;
	defgetter(p, "buffer", NDVPbuffer);
	defgetter(p, "byteLength", NDVPbytelength);
	defgetter(p, "byteOffset", NDVPbyteoffset);
	dvnames := array[] of {"Int8", "Uint8", "", "Int16", "Uint16", "Int32", "Uint32", "Float16", "Float32", "Float64", "BigInt64", "BigUint64"};
	for(t = 0; t < len dvnames; t++) {
		if(dvnames[t] == "")
			continue;
		g := defmethod(p, "get" + dvnames[t], NDVPget, 1);
		g.data = ref Data.Native(intv(t), undef, 0, nil);
		s := defmethod(p, "set" + dvnames[t], NDVPset, 2);
		s.data = ref Data.Native(intv(t), undef, 0, nil);
	}
	defprop(p, a_symtostringtag, strv("DataView"), Aconf);
}

# ---- buffers ----

bufdata(v: V): ref Data.Buf
{
	if(v.t == Tobj && v.o.cls == Cbuf)
		pick d := v.o.data {
		Buf =>
			return d;
		}
	return nil;
}

newbuf(n: int, maxlen: int, proto: ref Obj): ref Obj
{
	if(n < 0 || n > Bufmax)
		throwerr(ERange, "Array buffer allocation failed");
	o := newobj(Cbuf, proto);
	o.data = ref Data.Buf(array[n] of {* => byte 0}, 0, maxlen);
	return o;
}

thisbuf(this: V, name: string): ref Data.Buf
{
	d := bufdata(this);
	if(d == nil)
		throwtype("ArrayBuffer.prototype." + name + " called on incompatible receiver " + showv(this));
	return d;
}

# ---- typed arrays: their data and length ----

tdata(o: ref Obj): ref Data.Typed
{
	if(o.data != nil)
	pick d := o.data {
	Typed =>
		return d;
	}
	return nil;
}

bufof(t: ref Data.Typed): ref Data.Buf
{
	pick d := t.buf.data {
	Buf =>
		return d;
	}
	return nil;
}

# the length, or -1 if out of bounds (or detached)
talength(t: ref Data.Typed): int
{
	b := bufof(t);
	if(b.detached)
		return -1;
	bl := len b.b;
	sz := tysize[t.kind];
	if(t.length < 0) {
		if(t.off > bl)
			return -1;
		return (bl - t.off) / sz;
	}
	if(t.off + t.length * sz > bl)
		return -1;
	return t.length;
}

typedlength(o: ref Obj): int
{
	l := talength(tdata(o));
	if(l < 0)
		return 0;
	return l;
}

typedoutofbounds(o: ref Obj): int
{
	return talength(tdata(o)) < 0;
}

# whether o's length can change (it tracks, or its buffer is resizable)
typedtracks(o: ref Obj): int
{
	t := tdata(o);
	b := bufof(t);
	return t.length < 0 || b.maxlen >= 0 && !b.detached;
}

validta(v: V, name: string): (ref Data.Typed, int)
{
	if(v.t != Tobj || v.o.cls != Ctyped)
		throwtype(name + " called on incompatible receiver " + showv(v));
	t := tdata(v.o);
	l := talength(t);
	if(l < 0)
		throwtype(name + ": the typed array is detached or out of bounds");
	return (t, l);
}

isbigty(ty: int): int
{
	return ty == Tyb64 || ty == Tybu64;
}

rd(b: array of byte, i, n: int): big
{
	v := big 0;
	for(k := n - 1; k >= 0; k--)
		v = (v << 8) | big b[i+k];
	return v;
}

wr(b: array of byte, i, n: int, v: big)
{
	for(k := 0; k < n; k++) {
		b[i+k] = byte v;
		v >>= 8;
	}
}

# the value of element type ty at byte i of b
getraw(b: array of byte, i, ty: int, little: int): V
{
	n := tysize[ty];
	bytes := b;
	if(!little) {
		bytes = array[n] of byte;
		for(k := 0; k < n; k++)
			bytes[k] = b[i+n-1-k];
		i = 0;
	}
	x := rd(bytes, i, n);
	case ty {
	Ty8 =>
		v := int x & 16rFF;
		if(v >= 128)
			v -= 256;
		return numv(real v);
	Tyu8 or Tyu8c =>
		return intv(int x & 16rFF);
	Ty16 =>
		v := int x & 16rFFFF;
		if(v >= 16r8000)
			v -= 16r10000;
		return numv(real v);
	Tyu16 =>
		return intv(int x & 16rFFFF);
	Ty32 =>
		return intv(int x);
	Tyu32 =>
		return numv(real (x & big 16rFFFFFFFF));
	Tyf16 =>
		return numv(f16tor(int x & 16rFFFF));
	Tyf32 =>
		return numv(math->bits32real(int x));
	Tyf64 =>
		return numv(math->bits64real(x));
	Tyb64 =>
		return bigfromstr(string x);
	Tybu64 =>
		if(x >= big 0)
			return bigfromstr(string x);
		# the unsigned value: x + 2^64
		kr();
		return bigval(IPint.strtoip(string x, 10).add(IPint.inttoip(1).shl(64)));
	}
	return undef;
}

uint8clamp(x: real): int
{
	if(isnan(x) || x <= 0.0)
		return 0;
	if(x >= 255.0)
		return 255;
	f := math->floor(x);
	if(f + 0.5 < x)
		return int f + 1;
	if(x < f + 0.5)
		return int f;
	if(int f % 2 != 0)
		return int f + 1;
	return int f;
}

f16tor(h: int): real
{
	s := (h >> 15) & 1;
	e := (h >> 10) & 16r1F;
	f := h & 16r3FF;
	v: real;
	if(e == 0)
		v = math->scalbn(real f, -24);
	else if(e == 31) {
		if(f != 0)
			return nan;
		v = inf;
	} else
		v = math->scalbn(real (f | 16r400), e - 25);
	if(s)
		return -v;
	return v;
}

rtof16(x: real): int
{
	if(isnan(x))
		return 16r7E00;
	s := 0;
	if(x < 0.0 || negzero(x)) {
		s = 16r8000;
		x = -x;
	}
	r := f16round(x);
	if(r == inf)
		return s | 16r7C00;
	if(r == 0.0)
		return s;
	e := math->ilogb(r);
	if(e < -14) {
		# subnormal
		return s | int math->rint(math->scalbn(r, 24));
	}
	m := int math->rint(math->scalbn(r, 10 - e)) - 16r400;
	return s | ((e + 15) << 10) | m;
}


# store numeric value v (a Number, or a BigInt for the BigInt types)
setraw(b: array of byte, i, ty: int, v: V, little: int)
{
	n := tysize[ty];
	x := big 0;
	case ty {
	Ty8 or Tyu8 or Ty16 or Tyu16 or Ty32 or Tyu32 =>
		x = big touint32(v);
	Tyu8c =>
		x = big uint8clamp(numof(v));
	Tyf16 =>
		x = big rtof16(numof(v));
	Tyf32 =>
		x = big math->realbits32(numof(v));
	Tyf64 =>
		x = math->realbits64(numof(v));
	Tyb64 or Tybu64 =>
		w := bigwrap(ipof(v.o), 64, 1);
		x = big bigstr(w.o, 10);
	}
	if(little)
		wr(b, i, n, x);
	else {
		t := array[n] of byte;
		wr(t, 0, n, x);
		for(k := 0; k < n; k++)
			b[i+k] = t[n-1-k];
	}
}

# the conversion an assignment to an element does
tanum(ty: int, v: V): V
{
	if(isbigty(ty))
		return tobigint(v);
	if(v.t == Tint || v.t == Tnum)
		return v;
	return V(Tnum, 0, tonum(v), nil, nil);
}

taget(t: ref Data.Typed, i: int): V
{
	return getraw(bufof(t).b, t.off + i * tysize[t.kind], t.kind, 1);
}

taset(t: ref Data.Typed, i: int, v: V)
{
	setraw(bufof(t).b, t.off + i * tysize[t.kind], t.kind, v, 1);
}

# ---- the integer-indexed exotic object ----

# IsValidIntegerIndex: the element, or -1
validindex(o: ref Obj, x: real): int
{
	if(isnan(x) || x != trunc(x) || negzero(x))
		return -1;
	l := typedlength(o);
	if(x < 0.0 || x >= real l)
		return -1;
	return int x;
}

typedvalidindex(o: ref Obj, x: real): int
{
	return validindex(o, x) >= 0;
}

typedgetown(o: ref Obj, x: real): (int, V, int)
{
	ix := validindex(o, x);
	if(ix < 0)
		return (0, undef, 0);
	return (1, taget(tdata(o), ix), Adefault);
}

typedget(o: ref Obj, i: int): V
{
	ix := validindex(o, real i);
	if(ix < 0)
		return undef;
	return taget(tdata(o), ix);
}

typedgetnum(o: ref Obj, x: real): V
{
	ix := validindex(o, x);
	if(ix < 0)
		return undef;
	return taget(tdata(o), ix);
}

typedset(o: ref Obj, i: int, v: V)
{
	typedsetnum(o, real i, v);
}

typedsetnum(o: ref Obj, x: real, v: V)
{
	t := tdata(o);
	nv := tanum(t.kind, v);
	ix := validindex(o, x);
	if(ix >= 0)
		taset(t, ix, nv);
}

typeddefine(o: ref Obj, x: real, d: ref Desc): int
{
	ix := validindex(o, x);
	if(ix < 0)
		return 0;
	if((d.has & Dconf) && (d.attrs & Aconf) == 0)
		return 0;
	if((d.has & Denum) && (d.attrs & Aenum) == 0)
		return 0;
	if(d.has & (Dget|Dset))
		return 0;
	if((d.has & Dwrite) && (d.attrs & Awrite) == 0)
		return 0;
	if(d.has & Dvalue)
		typedsetnum(o, x, d.v);
	return 1;
}

# ---- construction ----

# AllocateTypedArray with a new buffer of n elements
newta(ty, n: int, proto: ref Obj): ref Obj
{
	if(real n * real tysize[ty] > real Bufmax)
		throwerr(ERange, "Invalid typed array length: " + string n);
	b := newbuf(n * tysize[ty], -1, abufproto);
	o := newobj(Ctyped, proto);
	o.data = ref Data.Typed(b, ty, 0, n);
	return o;
}

typedctor(f: ref Obj, args: array of V, nt: ref Obj): V
{
	ty := Tyu8;
	pick d := f.data {
	Native =>
		ty = d.v.i;
	}
	if(nt == nil)
		throwtype("Constructor " + tyname[ty] + " requires 'new'");
	proto := protofromctor(nt, typroto[ty]);
	first := arg(args, 0);
	if(first.t != Tobj) {
		l := toindex(first);
		return objv(newta(ty, l, proto));
	}
	o: ref Obj;
	case first.o.cls {
	Ctyped =>
		src := tdata(first.o);
		sl := talength(src);
		if(sl < 0)
			throwtype("source typed array is detached or out of bounds");
		if(isbigty(src.kind) != isbigty(ty))
			throwtype("Cannot mix BigInt and other types, use explicit conversions");
		o = newta(ty, sl, proto);
		t := tdata(o);
		for(i := 0; i < sl; i++)
			taset(t, i, taget(src, i));
	Cbuf =>
		d := bufdata(first);
		sz := tysize[ty];
		off := toindex(arg(args, 1));
		if(off % sz != 0)
			throwerr(ERange, "start offset of " + tyname[ty] + " should be a multiple of " + string sz);
		lenv := arg(args, 2);
		newlen := 0;
		if(lenv.t != Tundef)
			newlen = toindex(lenv);
		if(d.detached)
			throwtype("Cannot construct on a detached ArrayBuffer");
		bl := len d.b;
		nel := 0;
		if(lenv.t == Tundef && d.maxlen >= 0) {
			if(off > bl)
				throwerr(ERange, "Start offset " + string off + " is outside the bounds of the buffer");
			nel = -1;
		} else if(lenv.t == Tundef) {
			if(bl % sz != 0)
				throwerr(ERange, "byte length of " + tyname[ty] + " should be a multiple of " + string sz);
			nb := bl - off;
			if(nb < 0)
				throwerr(ERange, "Start offset " + string off + " is outside the bounds of the buffer");
			nel = nb / sz;
		} else {
			if(real off + real newlen * real sz > real bl)
				throwerr(ERange, "Invalid typed array length: " + string newlen);
			nel = newlen;
		}
		o = newobj(Ctyped, proto);
		o.data = ref Data.Typed(first.o, ty, off, nel);
	* =>
		using := getmethod(first, a_symiterator);
		vals: array of V;
		if(using != nil)
			vals = iterlistm(first, using);
		else {
			ln := lengthof(first.o);
			vals = array[int ln] of V;
			for(i := 0; i < len vals; i++)
				vals[i] = getidx(first.o, i, first);
		}
		o = newta(ty, len vals, proto);
		t := tdata(o);
		for(i := 0; i < len vals; i++) {
			nv := tanum(ty, vals[i]);
			if(i < typedlength(o))
				taset(t, i, nv);
		}
	}
	return objv(o);
}

# the values of an iterable, by a method already got
iterlistm(v: V, m: ref Obj): array of V
{
	it := call(m, v, nil);
	if(it.t != Tobj)
		throwtype("Result of the Symbol.iterator method is not an object");
	next := getvalue(it, a_next);
	l: list of V;
	n := 0;
	for(;;) {
		(x, done) := iterstep(it, next);
		if(done)
			break;
		l = x :: l;
		n++;
	}
	a := array[n] of V;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

# TypedArrayCreateFromConstructor: the new array, checked
tacreate(c: ref Obj, args: array of V, wantlen: int): V
{
	r := construct(c, args, c);
	(nil, l) := validta(r, "TypedArray constructor");
	if(wantlen >= 0 && len args == 1 && l < wantlen)
		throwtype("The typed array constructed is too short");
	return r;
}

# TypedArraySpeciesCreate
taspecies(o: V, args: array of V, wantlen: int): V
{
	t := tdata(o.o);
	c := speciesctor(o.o, tyctor[t.kind]);
	r := tacreate(c, args, wantlen);
	if(isbigty(tdata(r.o).kind) != isbigty(t.kind))
		throwtype("Cannot mix BigInt and other types, use explicit conversions");
	return r;
}

# sort values: by comparefn, or numerically (-0 before +0, NaN last)
tasortvals(vals: array of V, f: V)
{
	n := len vals;
	tmp := array[n] of V;
	for(w := 1; w < n; w *= 2) {
		for(lo := 0; lo < n; lo += 2 * w) {
			mid := lo + w;
			if(mid > n)
				mid = n;
			hi := lo + 2 * w;
			if(hi > n)
				hi = n;
			i := lo;
			j := mid;
			k := lo;
			while(i < mid && j < hi) {
				if(tacompare(vals[j], vals[i], f) < 0)
					tmp[k++] = vals[j++];
				else
					tmp[k++] = vals[i++];
			}
			while(i < mid)
				tmp[k++] = vals[i++];
			while(j < hi)
				tmp[k++] = vals[j++];
		}
		vals[0:] = tmp;
	}
}

tacompare(x, y: V, f: V): int
{
	if(f.t != Tundef) {
		v := tonum(call(f.o, undef, array[] of {x, y}));
		if(isnan(v))
			return 0;
		if(v < 0.0)
			return -1;
		if(v > 0.0)
			return 1;
		return 0;
	}
	if(x.t == Tbig)
		return bigcmp(x.o, y.o);
	a := numof(x);
	b := numof(y);
	if(isnan(a) && isnan(b))
		return 0;
	if(isnan(a))
		return 1;
	if(isnan(b))
		return -1;
	if(a < b)
		return -1;
	if(a > b)
		return 1;
	if(a == 0.0 && b == 0.0) {
		if(negzero(a) && !negzero(b))
			return -1;
		if(!negzero(a) && negzero(b))
			return 1;
	}
	return 0;
}

# ---- DataView ----

dvdata(v: V, name: string): ref Data.Typed
{
	if(v.t == Tobj && v.o.cls == Cview) {
		t := tdata(v.o);
		if(t != nil)
			return t;
	}
	throwtype("DataView.prototype." + name + " called on incompatible receiver " + showv(v));
	return nil;
}

# a DataView's byte length, or -1 if out of bounds
dvlength(t: ref Data.Typed): int
{
	b := bufof(t);
	if(b.detached)
		return -1;
	bl := len b.b;
	if(t.length < 0) {
		if(t.off > bl)
			return -1;
		return bl - t.off;
	}
	if(t.off + t.length > bl)
		return -1;
	return t.length;
}

b64chars := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
b64urlchars := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

# GetOptionsObject
optsobj(v: V): V
{
	if(v.t == Tundef)
		return undef;
	if(v.t != Tobj)
		throwtype("options must be an object");
	return v;
}

optget(o: V, k: string): V
{
	if(o.t == Tundef)
		return undef;
	return getv(o.o, intern(k));
}

b64alphabet(o: V): int
{
	v := optget(o, "alphabet");
	if(v.t == Tundef)
		return 0;
	if(isstr(v))
		case flat(v) {
		"base64" =>
			return 0;
		"base64url" =>
			return 1;
		}
	throwtype("alphabet must be \"base64\" or \"base64url\"");
	return 0;
}

Loose, Strict, Stopbefore: con iota;

lastchunk(o: V): int
{
	v := optget(o, "lastChunkHandling");
	if(v.t == Tundef)
		return Loose;
	if(isstr(v))
		case flat(v) {
		"loose" =>
			return Loose;
		"strict" =>
			return Strict;
		"stop-before-partial" =>
			return Stopbefore;
		}
	throwtype("lastChunkHandling must be \"loose\", \"strict\" or \"stop-before-partial\"");
	return 0;
}

isb64ws(c: int): int
{
	return c == '\t' || c == '\n' || c == '\f' || c == '\r' || c == ' ';
}

skipws(s: string, i: int): int
{
	while(i < len s && isb64ws(s[i]))
		i++;
	return i;
}

b64val(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c - 'A';
	if(c >= 'a' && c <= 'z')
		return c - 'a' + 26;
	if(c >= '0' && c <= '9')
		return c - '0' + 52;
	if(c == '+')
		return 62;
	if(c == '/')
		return 63;
	return -1;
}

# DecodeBase64Chunk: the bytes, or nil if extra bits were set and must not be
decodechunk(chunk: array of int, n, strict: int): (array of byte, int)
{
	for(k := n; k < 4; k++)
		chunk[k] = 0;
	v := (chunk[0] << 18) | (chunk[1] << 12) | (chunk[2] << 6) | chunk[3];
	b := array[] of {byte (v >> 16), byte (v >> 8), byte v};
	case n {
	2 =>
		if(strict && b[1] != byte 0)
			return (nil, 1);
		return (b[0:1], 0);
	3 =>
		if(strict && b[2] != byte 0)
			return (nil, 1);
		return (b[0:2], 0);
	}
	return (b, 0);
}

# FromBase64: (characters read, the bytes, whether it ended in a SyntaxError)
frombase64(s: string, url, last, maxlen: int): (int, array of byte, int)
{
	out := array[len s * 3 / 4 + 3] of byte;
	nout := 0;
	if(maxlen == 0)
		return (0, out[0:0], 0);
	read := 0;
	chunk := array[4] of int;
	nc := 0;
	i := 0;
	for(;;) {
		i = skipws(s, i);
		if(i == len s) {
			if(nc > 0) {
				if(last == Stopbefore)
					return (read, out[0:nout], 0);
				if(last == Strict || nc == 1)
					return (read, out[0:nout], 1);
				(b, nil) := decodechunk(chunk, nc, 0);
				out[nout:] = b;
				nout += len b;
			}
			return (len s, out[0:nout], 0);
		}
		c := s[i++];
		if(c == '=') {
			if(nc < 2)
				return (read, out[0:nout], 1);
			i = skipws(s, i);
			if(nc == 2) {
				if(i == len s) {
					if(last == Stopbefore)
						return (read, out[0:nout], 0);
					return (read, out[0:nout], 1);
				}
				if(s[i] == '=')
					i = skipws(s, i + 1);
			}
			if(i < len s)
				return (read, out[0:nout], 1);
			(b, bad) := decodechunk(chunk, nc, last == Strict);
			if(bad)
				return (read, out[0:nout], 1);
			out[nout:] = b;
			nout += len b;
			return (len s, out[0:nout], 0);
		}
		if(url) {
			if(c == '+' || c == '/')
				return (read, out[0:nout], 1);
			if(c == '-')
				c = '+';
			else if(c == '_')
				c = '/';
		}
		v := b64val(c);
		if(v < 0)
			return (read, out[0:nout], 1);
		rem := maxlen - nout;
		if(rem == 1 && nc == 2 || rem == 2 && nc == 3)
			return (read, out[0:nout], 0);
		chunk[nc++] = v;
		if(nc == 4) {
			(b, nil) := decodechunk(chunk, 4, 0);
			out[nout:] = b;
			nout += 3;
			nc = 0;
			read = i;
			if(nout == maxlen)
				return (read, out[0:nout], 0);
		}
	}
}

# FromHex: (characters read, the bytes, whether it ended in a SyntaxError)
fromhex(s: string, maxlen: int): (int, array of byte, int)
{
	if(len s % 2 != 0)
		return (0, nil, 1);
	out := array[len s / 2] of byte;
	nout := 0;
	read := 0;
	while(read < len s && nout < maxlen) {
		h := hexval(s[read]);
		l := hexval(s[read+1]);
		if(h < 0 || l < 0)
			return (read, out[0:nout], 1);
		read += 2;
		out[nout++] = byte (h * 16 + l);
	}
	return (read, out[0:nout], 0);
}


u8from(b: array of byte): V
{
	o := newta(Tyu8, len b, typroto[Tyu8]);
	bufof(tdata(o)).b[0:] = b;
	return objv(o);
}

validu8(v: V, name: string): ref Data.Typed
{
	if(v.t != Tobj || v.o.cls != Ctyped || tdata(v.o).kind != Tyu8)
		throwtype("Uint8Array.prototype." + name + " called on incompatible receiver " + showv(v));
	return tdata(v.o);
}

# GetUint8ArrayBytes
u8bytes(t: ref Data.Typed, name: string): array of byte
{
	l := talength(t);
	if(l < 0)
		throwtype(name + ": the typed array is detached or out of bounds");
	return bufof(t).b[t.off:t.off+l];
}

readwritten(read, written: int): V
{
	o := plainobj();
	addprop(o, intern("read"), Adefault, intv(read));
	addprop(o, intern("written"), Adefault, intv(written));
	return objv(o);
}

Aevery, Asome, Aforeach, Afind, Afindindex, Afindlast, Afindlastindex: con iota;

nattyped(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NArrayBuffer =>
		if(nt == nil)
			throwtype("Constructor ArrayBuffer requires 'new'");
		# a length too large to allocate fails after the prototype is got
		lr := toindexreal(arg(args, 0));
		maxr := -1.0;
		opts := arg(args, 1);
		if(opts.t == Tobj) {
			m := getv(opts.o, intern("maxByteLength"));
			if(m.t != Tundef) {
				maxr = toindexreal(m);
				if(lr > maxr)
					throwerr(ERange, "Invalid array buffer max length");
			}
		}
		proto := protofromctor(nt, abufproto);
		if(lr > real Bufmax || maxr > real Bufmax)
			throwerr(ERange, "Array buffer allocation failed");
		return objv(newbuf(int lr, int maxr, proto));
	NABspecies =>
		return this;
	NABisview =>
		v := arg(args, 0);
		return boolv(v.t == Tobj && (v.o.cls == Ctyped || v.o.cls == Cview));
	NABPbytelength =>
		d := thisbuf(this, "byteLength");
		if(d.detached)
			return intv(0);
		return intv(len d.b);
	NABPmaxbytelength =>
		d := thisbuf(this, "maxByteLength");
		if(d.detached)
			return intv(0);
		if(d.maxlen >= 0)
			return intv(d.maxlen);
		return intv(len d.b);
	NABPresizable =>
		return boolv(thisbuf(this, "resizable").maxlen >= 0);
	NABPdetached =>
		return boolv(thisbuf(this, "detached").detached);
	NABPslice =>
		d := thisbuf(this, "slice");
		if(d.detached)
			throwtype("Cannot perform ArrayBuffer.prototype.slice on a detached ArrayBuffer");
		l := real len d.b;
		first := relidx(arg(args, 0), l, 0.0);
		final := relidx(arg(args, 1), l, l);
		nl := final - first;
		if(nl < 0.0)
			nl = 0.0;
		c := speciesctor(this.o, abufctor);
		r := construct(c, array[] of {numv(nl)}, c);
		rd := bufdata(r);
		if(rd == nil)
			throwtype("Species constructor did not return an ArrayBuffer");
		if(rd.detached)
			throwtype("Species constructor returned a detached ArrayBuffer");
		if(r.o == this.o)
			throwtype("Species constructor returned the same ArrayBuffer");
		if(real len rd.b < nl)
			throwtype("Species constructor returned a too small ArrayBuffer");
		if(d.detached)
			throwtype("The ArrayBuffer was detached");
		cur := real len d.b;
		if(first < cur) {
			end := final;
			if(end > cur)
				end = cur;
			if(end > first)
				rd.b[0:] = d.b[int first:int end];
		}
		return r;
	NABPresize =>
		d := thisbuf(this, "resize");
		if(d.maxlen < 0)
			throwtype("Method ArrayBuffer.prototype.resize called on incompatible receiver");
		nl := toindex(arg(args, 0));
		if(d.detached)
			throwtype("Cannot resize a detached ArrayBuffer");
		if(nl > d.maxlen)
			throwerr(ERange, "Invalid length parameter");
		nb := array[nl] of {* => byte 0};
		m := len d.b;
		if(m > len nb)
			m = len nb;
		nb[0:] = d.b[0:m];
		d.b = nb;
		return undef;
	NABPtransfer or NABPtransferfixed =>
		d := thisbuf(this, "transfer");
		nl := len d.b;
		if(arg(args, 0).t != Tundef)
			nl = toindex(args[0]);
		if(d.detached)
			throwtype("Cannot transfer a detached ArrayBuffer");
		maxlen := -1;
		if(id == NABPtransfer && d.maxlen >= 0)
			maxlen = d.maxlen;
		if(maxlen >= 0 && nl > maxlen)
			throwerr(ERange, "Invalid length parameter");
		o := newbuf(nl, maxlen, abufproto);
		nd := bufdata(objv(o));
		m := len d.b;
		if(m > len nd.b)
			m = len nd.b;
		nd.b[0:] = d.b[0:m];
		d.b = nil;
		d.detached = 1;
		return objv(o);
	NTypedArray =>
		throwtype("Abstract class TypedArray not directly constructable");
	NTyped =>
		return typedctor(f, args, nt);
	NTAfrom =>
		if(this.t != Tobj || !isctor(this.o))
			throwtype(showv(this) + " is not a constructor");
		src := arg(args, 0);
		mapfn := arg(args, 1);
		th := arg(args, 2);
		mapping := mapfn.t != Tundef;
		if(mapping && !iscallable(mapfn))
			throwtype(showv(mapfn) + " is not a function");
		vals: array of V;
		using := getmethod(src, a_symiterator);
		if(using != nil)
			vals = iterlistm(src, using);
		else {
			o := toobj(src);
			ln := lengthof(o);
			vals = array[int ln] of V;
			for(i := 0; i < len vals; i++)
				vals[i] = getidx(o, i, objv(o));
		}
		r := tacreate(this.o, array[] of {intv(len vals)}, len vals);
		for(i := 0; i < len vals; i++) {
			v := vals[i];
			if(mapping)
				v = call(mapfn.o, th, array[] of {v, intv(i)});
			setprop(r.o, idxatom(i), v, 1);
		}
		return r;
	NTAof =>
		if(this.t != Tobj || !isctor(this.o))
			throwtype(showv(this) + " is not a constructor");
		r := tacreate(this.o, array[] of {intv(len args)}, len args);
		for(i := 0; i < len args; i++)
			setprop(r.o, idxatom(i), args[i], 1);
		return r;
	NTAPbuffer =>
		t := thista(this, "buffer");
		return objv(t.buf);
	NTAPbytelength =>
		t := thista(this, "byteLength");
		l := talength(t);
		if(l < 0)
			return intv(0);
		return intv(l * tysize[t.kind]);
	NTAPbyteoffset =>
		t := thista(this, "byteOffset");
		if(talength(t) < 0)
			return intv(0);
		return intv(t.off);
	NTAPlength =>
		t := thista(this, "length");
		l := talength(t);
		if(l < 0)
			return intv(0);
		return intv(l);
	NTAPtag =>
		if(this.t != Tobj || this.o.cls != Ctyped)
			return undef;
		return strv(tyname[tdata(this.o).kind]);
	NU8frombase64 =>
		sv := arg(args, 0);
		if(!isstr(sv))
			throwtype("Uint8Array.fromBase64: the input must be a string");
		o := optsobj(arg(args, 1));
		url := b64alphabet(o);
		last := lastchunk(o);
		(nil, b, bad) := frombase64(flat(sv), url, last, 16r7FFFFFFF);
		if(bad)
			throwerr(ESyntax, "Uint8Array.fromBase64: the input is not base64");
		return u8from(b);
	NU8fromhex =>
		sv := arg(args, 0);
		if(!isstr(sv))
			throwtype("Uint8Array.fromHex: the input must be a string");
		(nil, b, bad) := fromhex(flat(sv), 16r7FFFFFFF);
		if(bad)
			throwerr(ESyntax, "Uint8Array.fromHex: the input is not hexadecimal");
		return u8from(b);
	NU8Ptobase64 =>
		t := validu8(this, "toBase64");
		o := optsobj(arg(args, 0));
		url := b64alphabet(o);
		omit := tobool(optget(o, "omitPadding"));
		b := u8bytes(t, "Uint8Array.prototype.toBase64");
		alpha := b64chars;
		if(url)
			alpha = b64urlchars;
		r := "";
		for(i := 0; i < len b; i += 3) {
			v := int b[i] << 16;
			if(i + 1 < len b)
				v |= int b[i+1] << 8;
			if(i + 2 < len b)
				v |= int b[i+2];
			r[len r] = alpha[(v >> 18) & 63];
			r[len r] = alpha[(v >> 12) & 63];
			if(i + 1 < len b)
				r[len r] = alpha[(v >> 6) & 63];
			else if(!omit)
				r[len r] = '=';
			if(i + 2 < len b)
				r[len r] = alpha[v & 63];
			else if(!omit)
				r[len r] = '=';
		}
		return strv(r);
	NU8Ptohex =>
		t := validu8(this, "toHex");
		b := u8bytes(t, "Uint8Array.prototype.toHex");
		r := "";
		for(i := 0; i < len b; i++) {
			r[len r] = "0123456789abcdef"[int b[i] >> 4];
			r[len r] = "0123456789abcdef"[int b[i] & 15];
		}
		return strv(r);
	NU8Psetfrombase64 =>
		t := validu8(this, "setFromBase64");
		sv := arg(args, 0);
		if(!isstr(sv))
			throwtype("Uint8Array.prototype.setFromBase64: the input must be a string");
		o := optsobj(arg(args, 1));
		url := b64alphabet(o);
		last := lastchunk(o);
		l := talength(t);
		if(l < 0)
			throwtype("Uint8Array.prototype.setFromBase64: the typed array is detached or out of bounds");
		(read, b, bad) := frombase64(flat(sv), url, last, l);
		bufof(t).b[t.off:] = b;
		if(bad)
			throwerr(ESyntax, "Uint8Array.prototype.setFromBase64: the input is not base64");
		return readwritten(read, len b);
	NU8Psetfromhex =>
		t := validu8(this, "setFromHex");
		sv := arg(args, 0);
		if(!isstr(sv))
			throwtype("Uint8Array.prototype.setFromHex: the input must be a string");
		l := talength(t);
		if(l < 0)
			throwtype("Uint8Array.prototype.setFromHex: the typed array is detached or out of bounds");
		(read, b, bad) := fromhex(flat(sv), l);
		bufof(t).b[t.off:] = b;
		if(bad)
			throwerr(ESyntax, "Uint8Array.prototype.setFromHex: the input is not hexadecimal");
		return readwritten(read, len b);
	NDataView =>
		if(nt == nil)
			throwtype("Constructor DataView requires 'new'");
		bv := arg(args, 0);
		d := bufdata(bv);
		if(d == nil)
			throwtype("First argument to DataView constructor must be an ArrayBuffer");
		off := toindex(arg(args, 1));
		if(d.detached)
			throwtype("Cannot construct a DataView on a detached ArrayBuffer");
		bl := len d.b;
		if(off > bl)
			throwerr(ERange, "Start offset " + string off + " is outside the bounds of the buffer");
		lenv := arg(args, 2);
		vl := 0;
		if(lenv.t == Tundef) {
			if(d.maxlen >= 0)
				vl = -1;
			else
				vl = bl - off;
		} else {
			vl = toindex(lenv);
			if(real off + real vl > real bl)
				throwerr(ERange, "Invalid DataView length " + string vl);
		}
		proto := protofromctor(nt, dviewproto);
		if(d.detached)
			throwtype("The ArrayBuffer was detached");
		bl = len d.b;
		if(off > bl)
			throwerr(ERange, "Start offset is outside the bounds of the buffer");
		if(lenv.t != Tundef && off + vl > bl)
			throwerr(ERange, "Invalid DataView length");
		o := newobj(Cview, proto);
		o.data = ref Data.Typed(bv.o, Tyu8, off, vl);
		return objv(o);
	NDVPbuffer =>
		return objv(dvdata(this, "buffer").buf);
	NDVPbytelength =>
		t := dvdata(this, "byteLength");
		l := dvlength(t);
		if(l < 0)
			throwtype("The DataView is detached or out of bounds");
		return intv(l);
	NDVPbyteoffset =>
		t := dvdata(this, "byteOffset");
		if(dvlength(t) < 0)
			throwtype("The DataView is detached or out of bounds");
		return intv(t.off);
	NDVPget or NDVPset =>
		ty := 0;
		pick nd := f.data {
		Native =>
			ty = nd.v.i;
		}
		t := dvdata(this, "get");
		idx := toindex(arg(args, 0));
		v := undef;
		little := 0;
		if(id == NDVPset) {
			v = tanum(ty, arg(args, 1));
			little = tobool(arg(args, 2));
		} else
			little = tobool(arg(args, 1));
		l := dvlength(t);
		if(l < 0)
			throwtype("The DataView is detached or out of bounds");
		if(real idx + real tysize[ty] > real l)
			throwerr(ERange, "Offset is outside the bounds of the DataView");
		if(id == NDVPget)
			return getraw(bufof(t).b, t.off + idx, ty, little);
		setraw(bufof(t).b, t.off + idx, ty, v, little);
		return undef;
	}
	return taproto(id, this, args);
}

thista(this: V, name: string): ref Data.Typed
{
	if(this.t != Tobj || this.o.cls != Ctyped)
		throwtype("%TypedArray%.prototype." + name + " called on incompatible receiver " + showv(this));
	return tdata(this.o);
}

# %TypedArray%.prototype's methods that work on the elements
taproto(id: int, this: V, args: array of V): V
{
	(t, l) := validta(this, "%TypedArray%.prototype method");
	o := this.o;
	case id {
	NTAPat =>
		k := tointeger(arg(args, 0));
		if(k < 0.0)
			k += real l;
		if(k < 0.0 || k >= real l)
			return undef;
		return typedgetnum(o, k);
	NTAPcopywithin =>
		rl := real l;
		dst := relidx(arg(args, 0), rl, 0.0);
		from := relidx(arg(args, 1), rl, 0.0);
		final := relidx(arg(args, 2), rl, rl);
		count := final - from;
		if(rl - dst < count)
			count = rl - dst;
		if(count > 0.0) {
			nl := talength(t);
			if(nl < 0)
				throwtype("The typed array is detached or out of bounds");
			sz := tysize[t.kind];
			bl := nl * sz;
			toi := int dst * sz + t.off;
			fromi := int from * sz + t.off;
			cnt := int count * sz;
			if(int dst * sz + cnt > bl)
				cnt = bl - int dst * sz;
			if(int from * sz + cnt > bl)
				cnt = bl - int from * sz;
			if(cnt > 0) {
				b := bufof(t).b;
				tmp := array[cnt] of byte;
				tmp[0:] = b[fromi:fromi+cnt];
				b[toi:] = tmp;
			}
		}
		return this;
	NTAPentries =>
		return objv(arrayiter(o, Ientries));
	NTAPkeys =>
		return objv(arrayiter(o, Ikeys));
	NTAPvalues =>
		return objv(arrayiter(o, Ivalues));
	NTAPevery or NTAPsome or NTAPforeach or NTAPfind or NTAPfindindex or NTAPfindlast or NTAPfindlastindex =>
		f := arg(args, 0);
		if(!iscallable(f))
			throwtype(showv(f) + " is not a function");
		th := arg(args, 1);
		last := id == NTAPfindlast || id == NTAPfindlastindex;
		k := 0;
		step := 1;
		if(last) {
			k = l - 1;
			step = -1;
		}
		for(; k >= 0 && k < l; k += step) {
			v := typedget(o, k);
			r := tobool(call(f.o, th, array[] of {v, intv(k), this}));
			case id {
			NTAPevery =>
				if(!r)
					return falsev;
			NTAPsome =>
				if(r)
					return truev;
			NTAPfind or NTAPfindlast =>
				if(r)
					return v;
			NTAPfindindex or NTAPfindlastindex =>
				if(r)
					return intv(k);
			}
		}
		case id {
		NTAPevery =>
			return truev;
		NTAPsome =>
			return falsev;
		NTAPfindindex or NTAPfindlastindex =>
			return intv(-1);
		}
		return undef;
	NTAPfill =>
		v := tanum(t.kind, arg(args, 0));
		rl := real l;
		k := relidx(arg(args, 1), rl, 0.0);
		final := relidx(arg(args, 2), rl, rl);
		nl := talength(t);
		if(nl < 0)
			throwtype("The typed array is detached or out of bounds");
		if(final > real nl)
			final = real nl;
		for(i := int k; i < int final; i++)
			taset(t, i, v);
		return this;
	NTAPfilter =>
		f := arg(args, 0);
		if(!iscallable(f))
			throwtype(showv(f) + " is not a function");
		th := arg(args, 1);
		kept: list of V;
		cnt := 0;
		for(k := 0; k < l; k++) {
			v := typedget(o, k);
			if(tobool(call(f.o, th, array[] of {v, intv(k), this}))) {
				kept = v :: kept;
				cnt++;
			}
		}
		r := taspecies(this, array[] of {intv(cnt)}, cnt);
		for(i := cnt - 1; i >= 0; i--) {
			setprop(r.o, idxatom(i), hd kept, 1);
			kept = tl kept;
		}
		return r;
	NTAPincludes or NTAPindexof =>
		if(l == 0)
			if(id == NTAPincludes)
				return falsev;
			else
				return intv(-1);
		k := tointeger(arg(args, 1));
		if(k == inf)
			if(id == NTAPincludes)
				return falsev;
			else
				return intv(-1);
		if(k < 0.0) {
			k += real l;
			if(k < 0.0)
				k = 0.0;
		}
		x := arg(args, 0);
		for(i := int k; i < l; i++) {
			if(id == NTAPincludes) {
				if(samevaluezero(typedget(o, i), x))
					return truev;
			} else if(validindex(o, real i) >= 0 && stricteq(typedget(o, i), x))
				return intv(i);
		}
		if(id == NTAPincludes)
			return falsev;
		return intv(-1);
	NTAPlastindexof =>
		if(l == 0)
			return intv(-1);
		k := real (l - 1);
		if(len args > 1) {
			k = tointeger(args[1]);
			if(k == -inf)
				return intv(-1);
			if(k >= 0.0) {
				if(k > real (l - 1))
					k = real (l - 1);
			} else
				k += real l;
		}
		x := arg(args, 0);
		for(i := int k; i >= 0; i--)
			if(validindex(o, real i) >= 0 && stricteq(typedget(o, i), x))
				return intv(i);
		return intv(-1);
	NTAPjoin =>
		sep := ",";
		if(arg(args, 0).t != Tundef)
			sep = tostr(args[0]);
		parts := array[l] of string;
		for(k := 0; k < l; k++) {
			v := typedget(o, k);
			if(v.t != Tundef)
				parts[k] = tostr(v);
		}
		return strv(joinsep(parts, sep));
	NTAPmap =>
		f := arg(args, 0);
		if(!iscallable(f))
			throwtype(showv(f) + " is not a function");
		th := arg(args, 1);
		r := taspecies(this, array[] of {intv(l)}, l);
		for(k := 0; k < l; k++) {
			v := call(f.o, th, array[] of {typedget(o, k), intv(k), this});
			setprop(r.o, idxatom(k), v, 1);
		}
		return r;
	NTAPreduce or NTAPreduceright =>
		f := arg(args, 0);
		if(!iscallable(f))
			throwtype(showv(f) + " is not a function");
		k := 0;
		step := 1;
		if(id == NTAPreduceright) {
			k = l - 1;
			step = -1;
		}
		acc: V;
		if(len args > 1)
			acc = args[1];
		else {
			if(l == 0)
				throwtype("Reduce of empty array with no initial value");
			acc = typedget(o, k);
			k += step;
		}
		for(; k >= 0 && k < l; k += step)
			acc = call(f.o, undef, array[] of {acc, typedget(o, k), intv(k), this});
		return acc;
	NTAPreverse =>
		for(lo := 0; lo < l / 2; lo++) {
			hi := l - 1 - lo;
			x := taget(t, lo);
			taset(t, lo, taget(t, hi));
			taset(t, hi, x);
		}
		return this;
	NTAPset =>
		return taset2(this, t, args);
	NTAPslice =>
		rl := real l;
		k := relidx(arg(args, 0), rl, 0.0);
		final := relidx(arg(args, 1), rl, rl);
		count := int (final - k);
		if(count < 0)
			count = 0;
		r := taspecies(this, array[] of {intv(count)}, count);
		if(count > 0) {
			nl := talength(t);
			if(nl < 0)
				throwtype("The typed array is detached or out of bounds");
			if(real nl < final)
				final = real nl;
			rtd := tdata(r.o);
			if(rtd.kind == t.kind) {
				sz := tysize[t.kind];
				b := bufof(t).b;
				rb := bufof(rtd).b;
				src := t.off + int k * sz;
				cnt := (int final - int k) * sz;
				if(cnt > 0) {
					tmp := array[cnt] of byte;
					tmp[0:] = b[src:src+cnt];
					rb[rtd.off:] = tmp;
				}
			} else {
				j := 0;
				for(i := int k; i < int final; i++)
					setprop(r.o, idxatom(j++), taget(t, i), 1);
			}
		}
		return r;
	NTAPsort or NTAPtosorted =>
		f := arg(args, 0);
		vals := array[l] of V;
		for(i := 0; i < l; i++)
			vals[i] = taget(t, i);
		tasortvals(vals, f);
		if(id == NTAPtosorted) {
			n := newta(t.kind, l, typroto[t.kind]);
			nd := tdata(n);
			for(i = 0; i < l; i++)
				taset(nd, i, vals[i]);
			return objv(n);
		}
		nl := talength(t);
		for(i = 0; i < l && i < nl; i++)
			taset(t, i, vals[i]);
		return this;
	NTAPsubarray =>
		return tasubarray(this, t, args);
	NTAPtolocale =>
		parts := array[l] of string;
		for(k := 0; k < l; k++) {
			v := typedget(o, k);
			if(v.t != Tundef && v.t != Tnull)
				parts[k] = tostr(invoke(v, intern("toLocaleString"), nil));
		}
		return strv(joinsep(parts, ","));
	NTAPtoreversed =>
		n := newta(t.kind, l, typroto[t.kind]);
		nd := tdata(n);
		for(i := 0; i < l; i++)
			taset(nd, i, taget(t, l - 1 - i));
		return objv(n);
	NTAPwith =>
		rel := tointeger(arg(args, 0));
		at := rel;
		if(rel < 0.0)
			at = real l + rel;
		v := tanum(t.kind, arg(args, 1));
		if(validindex(o, at) < 0)
			throwerr(ERange, "Invalid typed array index");
		n := newta(t.kind, l, typroto[t.kind]);
		nd := tdata(n);
		cl := talength(t);
		for(i := 0; i < l; i++) {
			if(i == int at)
				taset(nd, i, v);
			else if(i < cl)
				taset(nd, i, taget(t, i));
			else
				taset(nd, i, tanum(t.kind, undef));
		}
		return objv(n);
	}
	throwerr(EError, "unknown typed array built-in");
	return undef;
}

taset2(this: V, t: ref Data.Typed, args: array of V): V
{
	src := arg(args, 0);
	off := tointeger(arg(args, 1));
	if(off < 0.0)
		throwerr(ERange, "offset is out of bounds");
	tl0 := talength(t);
	if(tl0 < 0)
		throwtype("The typed array is detached or out of bounds");
	if(src.t == Tobj && src.o.cls == Ctyped) {
		s := tdata(src.o);
		sl := talength(s);
		if(sl < 0)
			throwtype("Source typed array is detached or out of bounds");
		if(isbigty(s.kind) != isbigty(t.kind))
			throwtype("Cannot mix BigInt and other types, use explicit conversions");
		if(off == inf || real sl + off > real tl0)
			throwerr(ERange, "offset is out of bounds");
		vals := array[sl] of V;
		for(i := 0; i < sl; i++)
			vals[i] = taget(s, i);
		for(i = 0; i < sl; i++)
			taset(t, int off + i, vals[i]);
		return undef;
	}
	o := toobj(src);
	sl := lengthof(o);
	if(off == inf || sl + off > real tl0)
		throwerr(ERange, "offset is out of bounds");
	for(i := 0; i < int sl; i++) {
		v := tanum(t.kind, getidx(o, i, objv(o)));
		ix := validindex(this.o, off + real i);
		if(ix >= 0)
			taset(t, ix, v);
	}
	return undef;
}

tasubarray(this: V, t: ref Data.Typed, args: array of V): V
{
	l := talength(t);
	if(l < 0)
		l = 0;
	rl := real l;
	begin := relidx(arg(args, 0), rl, 0.0);
	endv := arg(args, 1);
	sz := tysize[t.kind];
	off := real t.off + begin * real sz;
	a: array of V;
	if(t.length < 0 && endv.t == Tundef)
		a = array[] of {objv(t.buf), numv(off)};
	else {
		final := relidx(endv, rl, rl);
		nl := final - begin;
		if(nl < 0.0)
			nl = 0.0;
		a = array[] of {objv(t.buf), numv(off), numv(nl)};
	}
	c := speciesctor(this.o, tyctor[t.kind]);
	r := tacreate(c, a, -1);
	if(isbigty(tdata(r.o).kind) != isbigty(t.kind))
		throwtype("Cannot mix BigInt and other types, use explicit conversions");
	return r;
}
