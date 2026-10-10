#
# jstyped.b - ArrayBuffer, the typed arrays and DataView (ECMAScript
# 2025 §25.1-25.3, §23.2, §10.4.5).  Included by js.b.
#
# A buffer is a Limbo byte array (little-endian, as the hosts are); a
# typed array is a view of one: its element type, byte offset and
# length, or a length that tracks a resizable buffer.
#

Ti8, Tu8, Tu8c, Ti16, Tu16, Ti32, Tu32, Tf16, Tf32, Tf64, Tbi64, Tbu64: con iota;
tysize := array[] of {1, 1, 1, 2, 2, 4, 4, 2, 4, 8, 8, 8};
tyname := array[] of {"Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array",
	"Int32Array", "Uint32Array", "Float16Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array"};
tyctor := array[12] of int;
typroto := array[12] of int;
itypedarray, itypedarrayproto, iabufproto, idataviewproto: int;

typedinit()
{
	iabufproto = keep(newobj(Kord, iobjproto));
	c := ctor("ArrayBuffer", 1, abufctor, iabufproto);
	method(c, "isView", 1, abuf_isview);
	getter(c, asymspecies, "[Symbol.species]", returnthis);
	p := iabufproto;
	getter(p, intern("byteLength"), "byteLength", abufproto_bytelength);
	getter(p, intern("maxByteLength"), "maxByteLength", abufproto_maxbytelength);
	getter(p, intern("resizable"), "resizable", abufproto_resizable);
	getter(p, intern("detached"), "detached", abufproto_detached);
	method(p, "slice", 2, abufproto_slice);
	method(p, "resize", 1, abufproto_resize);
	method(p, "transfer", 0, abufproto_transfer);
	method(p, "transferToFixedLength", 0, abufproto_transferfixed);
	tag(p, "ArrayBuffer");

	# %TypedArray%
	itypedarrayproto = keep(newobj(Kord, iobjproto));
	ta := nativefn("TypedArray", 0, typedarrayctor);
	oflags[ta] |= Octor;
	itypedarray = keep(ta);
	defown(ta, aprototype, 0, objv(itypedarrayproto));
	defown(itypedarrayproto, aconstructor, Awrite|Aconf, objv(ta));
	method(ta, "from", 1, typedarray_from);
	method(ta, "of", 0, typedarray_of);
	getter(ta, asymspecies, "[Symbol.species]", returnthis);
	p = itypedarrayproto;
	getter(p, intern("buffer"), "buffer", taproto_buffer);
	getter(p, intern("byteLength"), "byteLength", taproto_bytelength);
	getter(p, intern("byteOffset"), "byteOffset", taproto_byteoffset);
	getter(p, alength, "length", taproto_length);
	getter(p, asymtostrtag, "[Symbol.toStringTag]", taproto_tostringtag);
	method(p, "at", 1, taproto_at);
	method(p, "copyWithin", 2, taproto_copywithin);
	method(p, "entries", 0, taproto_entries);
	method(p, "every", 1, taproto_every);
	method(p, "fill", 1, taproto_fill);
	method(p, "filter", 1, taproto_filter);
	method(p, "find", 1, taproto_find);
	method(p, "findIndex", 1, taproto_findindex);
	method(p, "findLast", 1, taproto_findlast);
	method(p, "findLastIndex", 1, taproto_findlastindex);
	method(p, "forEach", 1, taproto_foreach);
	method(p, "includes", 1, taproto_includes);
	method(p, "indexOf", 1, taproto_indexof);
	method(p, "join", 1, taproto_join);
	method(p, "keys", 0, taproto_keys);
	method(p, "lastIndexOf", 1, taproto_lastindexof);
	method(p, "map", 1, taproto_map);
	method(p, "reduce", 1, taproto_reduce);
	method(p, "reduceRight", 1, taproto_reduceright);
	method(p, "reverse", 0, taproto_reverse);
	method(p, "set", 1, taproto_set);
	method(p, "slice", 2, taproto_slice);
	method(p, "some", 1, taproto_some);
	method(p, "sort", 1, taproto_sort);
	method(p, "subarray", 2, taproto_subarray);
	method(p, "toLocaleString", 0, taproto_tolocalestring);
	method(p, "toReversed", 0, taproto_toreversed);
	method(p, "toSorted", 1, taproto_tosorted);
	method(p, "with", 2, taproto_with);
	values := method(p, "values", 0, taproto_values);
	defown(p, asymiterator, Awrite|Aconf, objv(values));
	defown(p, atostring, Awrite|Aconf, get(iarrproto, atostring, objv(iarrproto)));
	for(t := 0; t < len tyname; t++) {
		pr := keep(newobj(Kord, itypedarrayproto));
		typroto[t] = pr;
		h := ctor(tyname[t], 3, typedctor, pr);
		oproto[h] = itypedarray;
		tyctor[t] = h;
		defown(h, intern("BYTES_PER_ELEMENT"), 0, num(real tysize[t]));
		defown(pr, intern("BYTES_PER_ELEMENT"), 0, num(real tysize[t]));
	}

	# Uint8Array to and from base64 and hex (ES2026 §23.3)
	method(tyctor[Tu8], "fromBase64", 1, u8_frombase64);
	method(tyctor[Tu8], "fromHex", 1, u8_fromhex);
	method(typroto[Tu8], "toBase64", 0, u8_tobase64);
	method(typroto[Tu8], "toHex", 0, u8_tohex);
	method(typroto[Tu8], "setFromBase64", 1, u8_setfrombase64);
	method(typroto[Tu8], "setFromHex", 1, u8_setfromhex);

	idataviewproto = keep(newobj(Kord, iobjproto));
	ctor("DataView", 1, dataviewctor, idataviewproto);
	p = idataviewproto;
	getter(p, intern("buffer"), "buffer", dvproto_buffer);
	getter(p, intern("byteLength"), "byteLength", dvproto_bytelength);
	getter(p, intern("byteOffset"), "byteOffset", dvproto_byteoffset);
	dvnames := array[] of {"Int8", "Uint8", "", "Int16", "Uint16", "Int32", "Uint32", "Float16", "Float32", "Float64", "BigInt64", "BigUint64"};
	for(t = 0; t < len dvnames; t++) {
		if(dvnames[t] == "")
			continue;
		g := method(p, "get" + dvnames[t], 1, dvproto_get);
		setcap(g, array[] of {num(real t)});
		s := method(p, "set" + dvnames[t], 2, dvproto_set);
		setcap(s, array[] of {num(real t)});
	}
	tag(p, "DataView");
}

# ---- buffers ----

abufdata(v: V): ref Data.Abuf
{
	if(v.t == Tobj && okind[v.x] == Kabuf)
		pick d := odata[v.x] {
		Abuf =>
			return d;
		}
	return nil;
}

newabuf(n: int, maxlen: int, proto: int): int
{
	if(n < 0 || n > 1 << 30)
		throwerr(RangeError, "array buffer allocation failed");
	h := newobj(Kabuf, proto);
	odata[h] = ref Data.Abuf(array[n] of {* => byte 0}, 0, maxlen);
	return h;
}

abufctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor ArrayBuffer requires 'new'");
	l := toindex(arg(a, n, 0));
	maxlen := -1;
	opts := arg(a, n, 1);
	if(opts.t == Tobj) {
		m := getv(opts, intern("maxByteLength"));
		if(m.t != Tundef) {
			mx := toindex(m);
			if(l > mx)
				throwerr(RangeError, "the length exceeds the maximum length");
			maxlen = int mx;
		}
	}
	proto := protofromctor(nt, iabufproto);
	if(l > real (1 << 30))
		throwerr(RangeError, "array buffer allocation failed");
	return objv(newabuf(int l, maxlen, proto));
}

abuf_isview(nil: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	return bool(v.t == Tobj && (okind[v.x] == Ktyped || okind[v.x] == Kdview));
}

thisabuf(this: V, name: string): ref Data.Abuf
{
	d := abufdata(this);
	if(d == nil)
		typeerr("ArrayBuffer.prototype." + name + " called on incompatible receiver " + show(this));
	return d;
}

abufproto_bytelength(this: V, nil, nil: int, nil: V, nil: int): V
{
	d := thisabuf(this, "byteLength");
	if(d.detached)
		return num(0.0);
	return num(real len d.b);
}

abufproto_maxbytelength(this: V, nil, nil: int, nil: V, nil: int): V
{
	d := thisabuf(this, "maxByteLength");
	if(d.detached)
		return num(0.0);
	if(d.maxlen >= 0)
		return num(real d.maxlen);
	return num(real len d.b);
}

abufproto_resizable(this: V, nil, nil: int, nil: V, nil: int): V
{
	return bool(thisabuf(this, "resizable").maxlen >= 0);
}

abufproto_detached(this: V, nil, nil: int, nil: V, nil: int): V
{
	return bool(thisabuf(this, "detached").detached);
}

abufproto_slice(this: V, a, n: int, nil: V, nil: int): V
{
	d := thisabuf(this, "slice");
	if(d.detached)
		typeerr("cannot perform ArrayBuffer.prototype.slice on a detached ArrayBuffer");
	l := real len d.b;
	first := relidx(arg(a, n, 0), l, 0.0);
	final := relidx(arg(a, n, 1), l, l);
	nl := final - first;
	if(nl < 0.0)
		nl = 0.0;
	c := speciesctor(this, abufctorh());
	r := construct(c, array[] of {num(nl)}, c);
	rd := abufdata(r);
	if(rd == nil)
		typeerr("species constructor did not return an ArrayBuffer");
	if(rd.detached)
		typeerr("species constructor returned a detached ArrayBuffer");
	if(r.x == this.x)
		typeerr("species constructor returned the same ArrayBuffer");
	if(real len rd.b < nl)
		typeerr("species constructor returned a too small ArrayBuffer");
	if(d.detached)
		typeerr("the ArrayBuffer was detached");
	cur := real len d.b;
	if(first < cur) {
		end := final;
		if(end > cur)
			end = cur;
		if(end > first)
			rd.b[0:] = d.b[int first:int end];
	}
	return r;
}

abufctorh(): int
{
	return getv(objv(iabufproto), aconstructor).x;
}

abufproto_resize(this: V, a, n: int, nil: V, nil: int): V
{
	d := thisabuf(this, "resize");
	if(d.maxlen < 0)
		typeerr("method ArrayBuffer.prototype.resize called on incompatible receiver");
	nl := toindex(arg(a, n, 0));
	if(d.detached)
		typeerr("cannot resize a detached ArrayBuffer");
	if(nl > real d.maxlen)
		throwerr(RangeError, "the length exceeds the maximum length");
	nb := array[int nl] of {* => byte 0};
	m := len d.b;
	if(m > len nb)
		m = len nb;
	nb[0:] = d.b[0:m];
	d.b = nb;
	return undef;
}

transfer(this: V, a, n: int, fixlen: int, name: string): V
{
	d := thisabuf(this, name);
	nl := real len d.b;
	if(arg(a, n, 0).t != Tundef)
		nl = toindex(vs[a]);
	if(d.detached)
		typeerr("cannot transfer a detached ArrayBuffer");
	maxlen := -1;
	if(!fixlen && d.maxlen >= 0)
		maxlen = d.maxlen;
	if(maxlen >= 0 && nl > real maxlen)
		throwerr(RangeError, "the length exceeds the maximum length");
	h := newabuf(int nl, maxlen, iabufproto);
	nd := abufdata(objv(h));
	m := len d.b;
	if(m > len nd.b)
		m = len nd.b;
	nd.b[0:] = d.b[0:m];
	d.b = nil;
	d.detached = 1;
	return objv(h);
}

abufproto_transfer(this: V, a, n: int, nil: V, nil: int): V { return transfer(this, a, n, 0, "transfer"); }
abufproto_transferfixed(this: V, a, n: int, nil: V, nil: int): V { return transfer(this, a, n, 1, "transferToFixedLength"); }

# ---- typed arrays: their data and length ----

tadata(h: int): ref Data.Typed
{
	pick d := odata[h] {
	Typed =>
		return d;
	}
	return nil;
}

bufof(t: ref Data.Typed): ref Data.Abuf
{
	pick d := odata[t.buf] {
	Abuf =>
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
	sz := tysize[t.ty];
	if(t.tracking) {
		if(t.off > bl)
			return -1;
		return (bl - t.off) / sz;
	}
	if(t.off + t.n * sz > bl)
		return -1;
	return t.n;
}

typedlen(h: int): int
{
	l := talength(tadata(h));
	if(l < 0)
		return 0;
	return l;
}

typedvariable(h: int): int
{
	t := tadata(h);
	b := bufof(t);
	return t.tracking || b.maxlen >= 0 && !b.detached;
}

# ValidateTypedArray: the length, or a TypeError
validta(v: V, name: string): (ref Data.Typed, int)
{
	if(v.t != Tobj || okind[v.x] != Ktyped)
		typeerr(name + " called on incompatible receiver " + show(v));
	t := tadata(v.x);
	l := talength(t);
	if(l < 0)
		typeerr(name + ": the typed array is detached or out of bounds");
	return (t, l);
}

isbigty(ty: int): int
{
	return ty == Tbi64 || ty == Tbu64;
}

# ---- element access ----

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
	Ti8 =>
		v := int x & 16rFF;
		if(v >= 128)
			v -= 256;
		return num(real v);
	Tu8 or Tu8c =>
		return num(real (int x & 16rFF));
	Ti16 =>
		v := int x & 16rFFFF;
		if(v >= 16r8000)
			v -= 16r10000;
		return num(real v);
	Tu16 =>
		return num(real (int x & 16rFFFF));
	Ti32 =>
		return num(real int x);
	Tu32 =>
		return num(real (x & big 16rFFFFFFFF));
	Tf16 =>
		return num(f16tor(int x & 16rFFFF));
	Tf32 =>
		return num(math->bits32real(int x));
	Tf64 =>
		return num(math->bits64real(x));
	Tbi64 =>
		return bigv(string x);
	Tbu64 =>
		if(x >= big 0)
			return bigv(string x);
		# the unsigned value: x + 2^64
		ip();
		return fromip(IPint.strtoip(string x, 10).add(IPint.inttoip(1).shl(64)));
	}
	return undef;
}

# store numeric value v (already converted: a Number, or a BigInt for the BigInt types)
setraw(b: array of byte, i, ty: int, v: V, little: int)
{
	n := tysize[ty];
	x := big 0;
	case ty {
	Ti8 or Tu8 or Ti16 or Tu16 or Ti32 or Tu32 =>
		x = big touint32(v);
	Tu8c =>
		x = big uint8clamp(v.n);
	Tf16 =>
		x = big rtof16(v.n);
	Tf32 =>
		x = big math->realbits32(v.n);
	Tf64 =>
		x = math->realbits64(v.n);
	Tbi64 or Tbu64 =>
		w := bigwrap(v, 64.0, 1);
		x = big str(w.x);
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
	if(signbit(x)) {
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

# the conversion an assignment to a typed array element does
tanum(ty: int, v: V): V
{
	if(isbigty(ty))
		return tobigint(v);
	return num(tonumber(v));
}

# get / set element i (in bounds, checked by the caller)
taget(t: ref Data.Typed, i: int): V
{
	return getraw(bufof(t).b, t.off + i * tysize[t.ty], t.ty, 1);
}

taset(t: ref Data.Typed, i: int, v: V)
{
	setraw(bufof(t).b, t.off + i * tysize[t.ty], t.ty, v, 1);
}

# ---- the integer-indexed exotic object (§10.4.5) ----

# CanonicalNumericIndexString: (is one, its value)
canonnum(k: int): (int, real)
{
	if(isidx(k))
		return (1, real keyidx(k));
	if(atomsym[k] != byte 0)
		return (0, 0.0);
	if(atomidx[k] >= 0.0)
		return (1, atomidx[k]);
	s := atomstr[k];
	if(s == "-0")
		return (1, -0.0);
	if(s == "")
		return (0, 0.0);
	c := s[0];
	if(!(c >= '0' && c <= '9' || c == '-' || c == 'I' || c == 'N' || c == '.'))
		return (0, 0.0);
	x := strnum(s);
	if(numstr(x) == s)
		return (1, x);
	return (0, 0.0);
}

# IsValidIntegerIndex: the element, or -1
validindex(h: int, x: real): int
{
	if(x != trunc(x) || x == 0.0 && signbit(x) || isnan(x))
		return -1;
	l := typedlen(h);
	if(x < 0.0 || x >= real l)
		return -1;
	return int x;
}

istakey(k: int): int
{
	(isn, nil) := canonnum(k);
	return isn;
}

typedgetown(h, i: int): (int, V, int)
{
	ix := validindex(h, real i);
	if(ix < 0)
		return (0, undef, 0);
	return (1, taget(tadata(h), ix), Adefault);
}

typedgetownk(h, k: int): (int, V, int)
{
	(nil, x) := canonnum(k);
	ix := validindex(h, x);
	if(ix < 0)
		return (0, undef, 0);
	return (1, taget(tadata(h), ix), Adefault);
}

typedhas(h, k: int): int
{
	(nil, x) := canonnum(k);
	return validindex(h, x) >= 0;
}

typedget(h, k: int): V
{
	(nil, x) := canonnum(k);
	ix := validindex(h, x);
	if(ix < 0)
		return undef;
	return taget(tadata(h), ix);
}

typedset(h, k: int, v: V)
{
	(nil, x) := canonnum(k);
	t := tadata(h);
	nv := tanum(t.ty, v);
	ix := validindex(h, x);
	if(ix >= 0)
		taset(t, ix, nv);
}

typeddefine(h, k: int, d: ref Desc): int
{
	(nil, x) := canonnum(k);
	ix := validindex(h, x);
	if(ix < 0)
		return 0;
	if((d.has & Hconf) && (d.attrs & Aconf) == 0)
		return 0;
	if((d.has & Henum) && (d.attrs & Aenum) == 0)
		return 0;
	if(isaccdesc(d))
		return 0;
	if((d.has & Hwrite) && (d.attrs & Awrite) == 0)
		return 0;
	if(d.has & Hvalue)
		typedset(h, k, d.value);
	return 1;
}

# ---- construction ----

typedarrayctor(nil: V, nil, nil: int, nil: V, nil: int): V
{
	typeerr("abstract class TypedArray not directly constructable");
	return undef;
}

tyof(f: int): int
{
	for(t := 0; t < len tyctor; t++)
		if(tyctor[t] == f)
			return t;
	return Tu8;
}

# AllocateTypedArray (with a new buffer of n elements)
newta(ty, n: int, proto: int): int
{
	if(real n * real tysize[ty] > real (1 << 30))
		throwerr(RangeError, "invalid typed array length: " + string n);
	b := newabuf(n * tysize[ty], -1, iabufproto);
	h := newobj(Ktyped, proto);
	odata[h] = ref Data.Typed(ty, b, 0, n, 0);
	return h;
}

typedctor(nil: V, a, n: int, nt: V, f: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor " + tyname[tyof(f)] + " requires 'new'");
	ty := tyof(f);
	proto := protofromctor(nt, typroto[ty]);
	first := arg(a, n, 0);
	if(first.t != Tobj) {
		l := toindex(first);
		return objv(newta(ty, int l, proto));
	}
	sp0 := sp;
	push(first);
	h: int;
	case okind[first.x] {
	Ktyped =>
		src := tadata(first.x);
		sl := talength(src);
		if(sl < 0)
			typeerr("source typed array is detached or out of bounds");
		if(isbigty(src.ty) != isbigty(ty))
			typeerr("cannot mix BigInt and other types");
		h = newta(ty, sl, proto);
		t := tadata(h);
		for(i := 0; i < sl; i++)
			taset(t, i, taget(src, i));
	Kabuf =>
		d := abufdata(first);
		sz := tysize[ty];
		off := toindex(arg(a, n, 1));
		if(math->fmod(off, real sz) != 0.0)
			throwerr(RangeError, "start offset of " + tyname[ty] + " should be a multiple of " + string sz);
		lenv := arg(a, n, 2);
		newlen := 0.0;
		if(lenv.t != Tundef)
			newlen = toindex(lenv);
		if(d.detached)
			typeerr("cannot construct on a detached ArrayBuffer");
		bl := real len d.b;
		tracking := 0;
		nel := 0;
		if(lenv.t == Tundef && d.maxlen >= 0) {
			if(off > bl)
				throwerr(RangeError, "start offset is outside the bounds of the buffer");
			tracking = 1;
		} else if(lenv.t == Tundef) {
			if(math->fmod(bl, real sz) != 0.0)
				throwerr(RangeError, "byte length of " + tyname[ty] + " should be a multiple of " + string sz);
			nb := bl - off;
			if(nb < 0.0)
				throwerr(RangeError, "start offset is outside the bounds of the buffer");
			nel = int (nb / real sz);
		} else {
			if(off + newlen * real sz > bl)
				throwerr(RangeError, "invalid typed array length: " + numstr(newlen));
			nel = int newlen;
		}
		h = newobj(Ktyped, proto);
		odata[h] = ref Data.Typed(ty, first.x, int off, nel, tracking);
	* =>
		# an iterable, or an array-like
		using := getmethod(first, asymiterator);
		vals: array of V;
		if(using.t != Tundef) {
			l: list of V;
			it := call(using, first, nil);
			if(it.t != Tobj)
				typeerr("result of the Symbol.iterator method is not an object");
			next := getv(it, anext);
			push(it);
			cnt := 0;
			for(;;) {
				(v, done) := iterstep(it, next);
				if(done)
					break;
				push(v);
				l = v :: l;
				cnt++;
			}
			vals = array[cnt] of V;
			for(i := cnt - 1; i >= 0; i--) {
				vals[i] = hd l;
				l = tl l;
			}
		} else {
			ln := lengthof(first);
			vals = array[int ln] of V;
			for(i := 0; i < len vals; i++)
				vals[i] = getidx(first, real i);
			keepall(vals);
		}
		h = newta(ty, len vals, proto);
		push(objv(h));
		t := tadata(h);
		for(i := 0; i < len vals; i++) {
			nv := tanum(ty, vals[i]);
			if(i < typedlen(h))
				taset(t, i, nv);
		}
	}
	sp = sp0;
	return objv(h);
}

# TypedArrayCreateFromConstructor, with the length argument(s): the new array, checked
tacreate(c: V, args: array of V, wantlen: int): V
{
	r := construct(c, args, c);
	(nil, l) := validta(r, "TypedArray constructor");
	if(wantlen >= 0 && l < wantlen)
		typeerr("the typed array constructed is too short");
	return r;
}

# TypedArraySpeciesCreate
taspecies(o: V, args: array of V, wantlen: int): V
{
	t := tadata(o.x);
	dflt := tyctor[t.ty];
	c := speciesctor(o, dflt);
	r := tacreate(c, args, wantlen);
	if(isbigty(tadata(r.x).ty) != isbigty(t.ty))
		typeerr("cannot mix BigInt and other types");
	return r;
}

typedarray_from(this: V, a, n: int, nil: V, nil: int): V
{
	if(!isctor(this))
		typeerr(show(this) + " is not a constructor");
	src := arg(a, n, 0);
	mapfn := arg(a, n, 1);
	t := arg(a, n, 2);
	mapping := mapfn.t != Tundef;
	if(mapping && !iscallable(mapfn))
		typeerr(show(mapfn) + " is not a function");
	sp0 := sp;
	vals: array of V;
	using := getmethod(src, asymiterator);
	if(using.t != Tundef) {
		l: list of V;
		it := call(using, src, nil);
		if(it.t != Tobj)
			typeerr("result of the Symbol.iterator method is not an object");
		next := getv(it, anext);
		push(it);
		cnt := 0;
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done)
				break;
			push(v);
			l = v :: l;
			cnt++;
		}
		vals = array[cnt] of V;
		for(i := cnt - 1; i >= 0; i--) {
			vals[i] = hd l;
			l = tl l;
		}
	} else {
		o := objv(toobject(src));
		push(o);
		ln := lengthof(o);
		vals = array[int ln] of V;
		for(i := 0; i < len vals; i++)
			vals[i] = getidx(o, real i);
		keepall(vals);
	}
	r := tacreate(this, array[] of {num(real len vals)}, len vals);
	push(r);
	for(i := 0; i < len vals; i++) {
		v := vals[i];
		if(mapping)
			v = call(mapfn, t, array[] of {v, num(real i)});
		setv(r, idxkey(i), v, 1);
	}
	sp = sp0;
	return r;
}

typedarray_of(this: V, a, n: int, nil: V, nil: int): V
{
	if(!isctor(this))
		typeerr(show(this) + " is not a constructor");
	r := tacreate(this, array[] of {num(real n)}, n);
	sp0 := sp;
	push(r);
	for(i := 0; i < n; i++)
		setv(r, idxkey(i), vs[a+i], 1);
	sp = sp0;
	return r;
}

# ---- %TypedArray%.prototype ----

thista(this: V, name: string): ref Data.Typed
{
	if(this.t != Tobj || okind[this.x] != Ktyped)
		typeerr("%TypedArray%.prototype." + name + " called on incompatible receiver " + show(this));
	return tadata(this.x);
}

taproto_buffer(this: V, nil, nil: int, nil: V, nil: int): V
{
	return objv(thista(this, "buffer").buf);
}

taproto_bytelength(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := thista(this, "byteLength");
	l := talength(t);
	if(l < 0)
		return num(0.0);
	return num(real (l * tysize[t.ty]));
}

taproto_byteoffset(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := thista(this, "byteOffset");
	if(talength(t) < 0)
		return num(0.0);
	return num(real t.off);
}

taproto_length(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := thista(this, "length");
	l := talength(t);
	if(l < 0)
		return num(0.0);
	return num(real l);
}

taproto_tostringtag(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t != Tobj || okind[this.x] != Ktyped)
		return undef;
	return strv(tyname[tadata(this.x).ty]);
}

taproto_at(this: V, a, n: int, nil: V, nil: int): V
{
	(t, l) := validta(this, "%TypedArray%.prototype.at");
	k := tointorinf(arg(a, n, 0));
	if(k < 0.0)
		k += real l;
	if(k < 0.0 || k >= real l)
		return undef;
	return typedget(this.x, numkey(k));
	t = nil;
}

taproto_copywithin(this: V, a, n: int, nil: V, nil: int): V
{
	(t, l) := validta(this, "%TypedArray%.prototype.copyWithin");
	rl := real l;
	dst := relidx(arg(a, n, 0), rl, 0.0);
	from := relidx(arg(a, n, 1), rl, 0.0);
	final := relidx(arg(a, n, 2), rl, rl);
	count := final - from;
	if(rl - dst < count)
		count = rl - dst;
	if(count > 0.0) {
		nl := talength(t);
		if(nl < 0)
			typeerr("the typed array is detached or out of bounds");
		sz := tysize[t.ty];
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
}

taproto_entries(this: V, nil, nil: int, nil: V, nil: int): V
{
	validta(this, "%TypedArray%.prototype.entries");
	return arrayiter(this, Ientries);
}

taproto_keys(this: V, nil, nil: int, nil: V, nil: int): V
{
	validta(this, "%TypedArray%.prototype.keys");
	return arrayiter(this, Ikeys);
}

taproto_values(this: V, nil, nil: int, nil: V, nil: int): V
{
	validta(this, "%TypedArray%.prototype.values");
	return arrayiter(this, Ivalues);
}

# every/some/forEach/find...: as the array versions, on the validated length
taiterate(this: V, a, n: int, kind: int, name: string): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype." + name);
	f := arg(a, n, 0);
	callback(f, name);
	t := arg(a, n, 1);
	case kind {
	Afind or Afindindex =>
		for(k := 0; k < l; k++) {
			v := typedget(this.x, idxkey(k));
			if(truthy(call(f, t, array[] of {v, num(real k), this}))) {
				if(kind == Afind)
					return v;
				return num(real k);
			}
		}
		if(kind == Afind)
			return undef;
		return num(-1.0);
	Afindlast or Afindlastindex =>
		for(k := l - 1; k >= 0; k--) {
			v := typedget(this.x, idxkey(k));
			if(truthy(call(f, t, array[] of {v, num(real k), this}))) {
				if(kind == Afindlast)
					return v;
				return num(real k);
			}
		}
		if(kind == Afindlast)
			return undef;
		return num(-1.0);
	}
	for(k := 0; k < l; k++) {
		v := typedget(this.x, idxkey(k));
		r := truthy(call(f, t, array[] of {v, num(real k), this}));
		case kind {
		Aevery =>
			if(!r)
				return vfalse;
		Asome =>
			if(r)
				return vtrue;
		}
	}
	case kind {
	Aevery => return vtrue;
	Asome => return vfalse;
	}
	return undef;
}

taproto_every(this: V, a, n: int, nil: V, nil: int): V { return taiterate(this, a, n, Aevery, "every"); }
taproto_some(this: V, a, n: int, nil: V, nil: int): V { return taiterate(this, a, n, Asome, "some"); }
taproto_foreach(this: V, a, n: int, nil: V, nil: int): V { return taiterate(this, a, n, Aforeach, "forEach"); }
taproto_find(this: V, a, n: int, nil: V, nil: int): V { return taiterate(this, a, n, Afind, "find"); }
taproto_findindex(this: V, a, n: int, nil: V, nil: int): V { return taiterate(this, a, n, Afindindex, "findIndex"); }
taproto_findlast(this: V, a, n: int, nil: V, nil: int): V { return taiterate(this, a, n, Afindlast, "findLast"); }
taproto_findlastindex(this: V, a, n: int, nil: V, nil: int): V { return taiterate(this, a, n, Afindlastindex, "findLastIndex"); }

taproto_fill(this: V, a, n: int, nil: V, nil: int): V
{
	(t, l) := validta(this, "%TypedArray%.prototype.fill");
	v := tanum(t.ty, arg(a, n, 0));
	rl := real l;
	k := relidx(arg(a, n, 1), rl, 0.0);
	final := relidx(arg(a, n, 2), rl, rl);
	nl := talength(t);
	if(nl < 0)
		typeerr("the typed array is detached or out of bounds");
	if(final > real nl)
		final = real nl;
	for(i := int k; i < int final; i++)
		taset(t, i, v);
	return this;
}

taproto_filter(this: V, a, n: int, nil: V, nil: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.filter");
	f := arg(a, n, 0);
	callback(f, "filter");
	th := arg(a, n, 1);
	kept: list of V;
	cnt := 0;
	sp0 := sp;
	for(k := 0; k < l; k++) {
		v := typedget(this.x, idxkey(k));
		if(truthy(call(f, th, array[] of {v, num(real k), this}))) {
			push(v);
			kept = v :: kept;
			cnt++;
		}
	}
	r := taspecies(this, array[] of {num(real cnt)}, cnt);
	push(r);
	for(i := cnt - 1; i >= 0; i--) {
		setv(r, idxkey(i), hd kept, 1);
		kept = tl kept;
	}
	sp = sp0;
	return r;
}

taproto_includes(this: V, a, n: int, nil: V, nil: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.includes");
	if(l == 0)
		return vfalse;
	k := tointorinf(arg(a, n, 1));
	if(k == inf)
		return vfalse;
	if(k < 0.0) {
		k += real l;
		if(k < 0.0)
			k = 0.0;
	}
	x := arg(a, n, 0);
	for(i := int k; i < l; i++)
		if(samevaluezero(typedget(this.x, idxkey(i)), x))
			return vtrue;
	return vfalse;
}

taproto_indexof(this: V, a, n: int, nil: V, nil: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.indexOf");
	if(l == 0)
		return num(-1.0);
	k := tointorinf(arg(a, n, 1));
	if(k == inf)
		return num(-1.0);
	if(k < 0.0) {
		k += real l;
		if(k < 0.0)
			k = 0.0;
	}
	x := arg(a, n, 0);
	for(i := int k; i < l; i++)
		if(typedhas(this.x, idxkey(i)) && strictequal(typedget(this.x, idxkey(i)), x))
			return num(real i);
	return num(-1.0);
}

taproto_lastindexof(this: V, a, n: int, nil: V, nil: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.lastIndexOf");
	if(l == 0)
		return num(-1.0);
	k := real (l - 1);
	if(n > 1) {
		k = tointorinf(vs[a+1]);
		if(k == -inf)
			return num(-1.0);
		if(k >= 0.0) {
			if(k > real (l - 1))
				k = real (l - 1);
		} else
			k += real l;
	}
	x := arg(a, n, 0);
	for(i := int k; i >= 0; i--)
		if(typedhas(this.x, idxkey(i)) && strictequal(typedget(this.x, idxkey(i)), x))
			return num(real i);
	return num(-1.0);
}

taproto_join(this: V, a, n: int, nil: V, nil: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.join");
	sep := ",";
	if(arg(a, n, 0).t != Tundef)
		sep = tostring(vs[a]);
	r := "";
	for(k := 0; k < l; k++) {
		if(k > 0)
			r += sep;
		v := typedget(this.x, idxkey(k));
		if(v.t != Tundef)
			r += tostring(v);
	}
	return strv(r);
}

taproto_map(this: V, a, n: int, nil: V, nil: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.map");
	f := arg(a, n, 0);
	callback(f, "map");
	th := arg(a, n, 1);
	r := taspecies(this, array[] of {num(real l)}, l);
	sp0 := sp;
	push(r);
	for(k := 0; k < l; k++) {
		v := call(f, th, array[] of {typedget(this.x, idxkey(k)), num(real k), this});
		setv(r, idxkey(k), v, 1);
	}
	sp = sp0;
	return r;
}

tareduce(this: V, a, n: int, right: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.reduce");
	f := arg(a, n, 0);
	callback(f, "reduce");
	k := 0;
	step := 1;
	if(right) {
		k = l - 1;
		step = -1;
	}
	acc: V;
	if(n > 1)
		acc = vs[a+1];
	else {
		if(l == 0)
			typeerr("reduce of empty array with no initial value");
		acc = typedget(this.x, idxkey(k));
		k += step;
	}
	for(; k >= 0 && k < l; k += step)
		acc = call(f, undef, array[] of {acc, typedget(this.x, idxkey(k)), num(real k), this});
	return acc;
}

taproto_reduce(this: V, a, n: int, nil: V, nil: int): V { return tareduce(this, a, n, 0); }
taproto_reduceright(this: V, a, n: int, nil: V, nil: int): V { return tareduce(this, a, n, 1); }

taproto_reverse(this: V, nil, nil: int, nil: V, nil: int): V
{
	(t, l) := validta(this, "%TypedArray%.prototype.reverse");
	for(lo := 0; lo < l / 2; lo++) {
		hi := l - 1 - lo;
		x := taget(t, lo);
		taset(t, lo, taget(t, hi));
		taset(t, hi, x);
	}
	return this;
}

taproto_set(this: V, a, n: int, nil: V, nil: int): V
{
	t := thista(this, "set");
	src := arg(a, n, 0);
	off := tointorinf(arg(a, n, 1));
	if(off < 0.0)
		throwerr(RangeError, "offset is out of bounds");
	tl0 := talength(t);
	if(tl0 < 0)
		typeerr("the typed array is detached or out of bounds");
	if(src.t == Tobj && okind[src.x] == Ktyped) {
		s := tadata(src.x);
		sl := talength(s);
		if(sl < 0)
			typeerr("source typed array is detached or out of bounds");
		if(isbigty(s.ty) != isbigty(t.ty))
			typeerr("cannot mix BigInt and other types");
		if(off == inf || real sl + off > real tl0)
			throwerr(RangeError, "offset is out of bounds");
		vals := array[sl] of V;
		for(i := 0; i < sl; i++)
			vals[i] = taget(s, i);
		for(i = 0; i < sl; i++)
			taset(t, int off + i, vals[i]);
		return undef;
	}
	o := objv(toobject(src));
	sp0 := sp;
	push(o);
	sl := lengthof(o);
	if(off == inf || sl + off > real tl0)
		throwerr(RangeError, "offset is out of bounds");
	for(i := 0; i < int sl; i++) {
		v := tanum(t.ty, getidx(o, real i));
		ix := validindex(this.x, off + real i);
		if(ix >= 0)
			taset(t, ix, v);
	}
	sp = sp0;
	return undef;
}

taproto_slice(this: V, a, n: int, nil: V, nil: int): V
{
	(t, l) := validta(this, "%TypedArray%.prototype.slice");
	rl := real l;
	k := relidx(arg(a, n, 0), rl, 0.0);
	final := relidx(arg(a, n, 1), rl, rl);
	count := int (final - k);
	if(count < 0)
		count = 0;
	r := taspecies(this, array[] of {num(real count)}, count);
	if(count > 0) {
		nl := talength(t);
		if(nl < 0)
			typeerr("the typed array is detached or out of bounds");
		if(real nl < final)
			final = real nl;
		rt := tadata(r.x);
		if(rt.ty == t.ty) {
			sz := tysize[t.ty];
			b := bufof(t).b;
			rb := bufof(rt).b;
			src := t.off + int k * sz;
			cnt := (int final - int k) * sz;
			if(cnt > 0) {
				tmp := array[cnt] of byte;
				tmp[0:] = b[src:src+cnt];
				rb[rt.off:] = tmp;
			}
		} else {
			j := 0;
			for(i := int k; i < int final; i++)
				setv(r, idxkey(j++), taget(t, i), 1);
		}
	}
	return r;
}

# sort a typed array's values: by comparefn, or numerically (-0 before +0, NaN last)
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
		v := tonumber(call(f, undef, array[] of {x, y}));
		if(isnan(v))
			return 0;
		if(v < 0.0)
			return -1;
		if(v > 0.0)
			return 1;
		return 0;
	}
	if(x.t == Tbig)
		return bigcmp(x, y);
	if(isnan(x.n) && isnan(y.n))
		return 0;
	if(isnan(x.n))
		return 1;
	if(isnan(y.n))
		return -1;
	if(x.n < y.n)
		return -1;
	if(x.n > y.n)
		return 1;
	if(x.n == 0.0 && y.n == 0.0) {
		if(signbit(x.n) && !signbit(y.n))
			return -1;
		if(!signbit(x.n) && signbit(y.n))
			return 1;
	}
	return 0;
}

taproto_sort(this: V, a, n: int, nil: V, nil: int): V
{
	f := arg(a, n, 0);
	if(f.t != Tundef && !iscallable(f))
		typeerr("the comparison function must be either a function or undefined");
	(t, l) := validta(this, "%TypedArray%.prototype.sort");
	vals := array[l] of V;
	sp0 := sp;
	for(i := 0; i < l; i++) {
		vals[i] = taget(t, i);
		push(vals[i]);	# (BigInts are rows: roots while the comparison runs)
	}
	tasortvals(vals, f);
	nl := talength(t);
	for(i = 0; i < l && i < nl; i++)
		taset(t, i, vals[i]);
	sp = sp0;
	return this;
}

taproto_subarray(this: V, a, n: int, nil: V, nil: int): V
{
	t := thista(this, "subarray");
	l := talength(t);
	if(l < 0)
		l = 0;
	rl := real l;
	begin := relidx(arg(a, n, 0), rl, 0.0);
	endv := arg(a, n, 1);
	sz := tysize[t.ty];
	off := real t.off + begin * real sz;
	args: array of V;
	if(t.tracking && endv.t == Tundef)
		args = array[] of {objv(t.buf), num(off)};
	else {
		final := relidx(endv, rl, rl);
		nl := final - begin;
		if(nl < 0.0)
			nl = 0.0;
		args = array[] of {objv(t.buf), num(off), num(nl)};
	}
	c := speciesctor(this, tyctor[t.ty]);
	r := tacreate(c, args, -1);
	if(isbigty(tadata(r.x).ty) != isbigty(t.ty))
		typeerr("cannot mix BigInt and other types");
	return r;
}

taproto_tolocalestring(this: V, nil, nil: int, nil: V, nil: int): V
{
	(nil, l) := validta(this, "%TypedArray%.prototype.toLocaleString");
	r := "";
	for(k := 0; k < l; k++) {
		if(k > 0)
			r += ",";
		v := typedget(this.x, idxkey(k));
		if(v.t != Tundef && v.t != Tnull)
			r += tostring(invoke(v, intern("toLocaleString"), nil));
	}
	return strv(r);
}

taproto_toreversed(this: V, nil, nil: int, nil: V, nil: int): V
{
	(t, l) := validta(this, "%TypedArray%.prototype.toReversed");
	h := newta(t.ty, l, typroto[t.ty]);
	nt := tadata(h);
	for(i := 0; i < l; i++)
		taset(nt, i, taget(t, l - 1 - i));
	return objv(h);
}

taproto_tosorted(this: V, a, n: int, nil: V, nil: int): V
{
	f := arg(a, n, 0);
	if(f.t != Tundef && !iscallable(f))
		typeerr("the comparison function must be either a function or undefined");
	(t, l) := validta(this, "%TypedArray%.prototype.toSorted");
	h := newta(t.ty, l, typroto[t.ty]);
	sp0 := sp;
	push(objv(h));
	vals := array[l] of V;
	for(i := 0; i < l; i++) {
		vals[i] = taget(t, i);
		push(vals[i]);
	}
	tasortvals(vals, f);
	nt := tadata(h);
	for(i = 0; i < l; i++)
		taset(nt, i, vals[i]);
	sp = sp0;
	return objv(h);
}

taproto_with(this: V, a, n: int, nil: V, nil: int): V
{
	(t, l) := validta(this, "%TypedArray%.prototype.with");
	rel := tointorinf(arg(a, n, 0));
	at := rel;
	if(rel < 0.0)
		at = real l + rel;
	v := tanum(t.ty, arg(a, n, 1));
	if(validindex(this.x, at) < 0)
		throwerr(RangeError, "invalid typed array index");
	h := newta(t.ty, l, typroto[t.ty]);
	sp0 := sp;
	push(objv(h));
	nt := tadata(h);
	cl := talength(t);	# a coercion may have shrunk the buffer: what is gone reads as undefined
	for(i := 0; i < l; i++) {
		if(i == int at)
			taset(nt, i, v);
		else if(i < cl)
			taset(nt, i, taget(t, i));
		else
			taset(nt, i, tanum(t.ty, undef));
	}
	sp = sp0;
	return objv(h);
}

# ---- DataView ----

dvdata(v: V, name: string): ref Data.Typed
{
	if(v.t == Tobj && okind[v.x] == Kdview)
		pick d := odata[v.x] {
		Typed =>
			return d;
		}
	typeerr("DataView.prototype." + name + " called on incompatible receiver " + show(v));
	return nil;
}

# a DataView's byte length, or -1 if out of bounds (ty unused: byte views)
dvlength(t: ref Data.Typed): int
{
	b := bufof(t);
	if(b.detached)
		return -1;
	bl := len b.b;
	if(t.tracking) {
		if(t.off > bl)
			return -1;
		return bl - t.off;
	}
	if(t.off + t.n > bl)
		return -1;
	return t.n;
}

dataviewctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor DataView requires 'new'");
	bv := arg(a, n, 0);
	d := abufdata(bv);
	if(d == nil)
		typeerr("first argument to DataView constructor must be an ArrayBuffer");
	off := toindex(arg(a, n, 1));
	if(d.detached)
		typeerr("cannot construct a DataView on a detached ArrayBuffer");
	bl := real len d.b;
	if(off > bl)
		throwerr(RangeError, "start offset is outside the bounds of the buffer");
	lenv := arg(a, n, 2);
	tracking := 0;
	vl := 0.0;
	if(lenv.t == Tundef) {
		if(d.maxlen >= 0)
			tracking = 1;
		else
			vl = bl - off;
	} else {
		vl = toindex(lenv);
		if(off + vl > bl)
			throwerr(RangeError, "invalid DataView length");
	}
	proto := protofromctor(nt, idataviewproto);
	if(d.detached)
		typeerr("the ArrayBuffer was detached");
	bl = real len d.b;
	if(off > bl)
		throwerr(RangeError, "start offset is outside the bounds of the buffer");
	if(lenv.t != Tundef && off + vl > bl)
		throwerr(RangeError, "invalid DataView length");
	h := newobj(Kdview, proto);
	odata[h] = ref Data.Typed(Tu8, bv.x, int off, int vl, tracking);
	return objv(h);
}

dvproto_buffer(this: V, nil, nil: int, nil: V, nil: int): V
{
	return objv(dvdata(this, "buffer").buf);
}

dvproto_bytelength(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := dvdata(this, "byteLength");
	l := dvlength(t);
	if(l < 0)
		typeerr("the DataView is detached or out of bounds");
	return num(real l);
}

dvproto_byteoffset(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := dvdata(this, "byteOffset");
	if(dvlength(t) < 0)
		typeerr("the DataView is detached or out of bounds");
	return num(real t.off);
}

dvproto_get(this: V, a, n: int, nil: V, f: int): V
{
	ty := int capof(f, 0).n;
	t := dvdata(this, "get");
	idx := toindex(arg(a, n, 0));
	little := truthy(arg(a, n, 1));
	l := dvlength(t);
	if(l < 0)
		typeerr("the DataView is detached or out of bounds");
	if(idx + real tysize[ty] > real l)
		throwerr(RangeError, "offset is outside the bounds of the DataView");
	return getraw(bufof(t).b, t.off + int idx, ty, little);
}

dvproto_set(this: V, a, n: int, nil: V, f: int): V
{
	ty := int capof(f, 0).n;
	t := dvdata(this, "set");
	idx := toindex(arg(a, n, 0));
	v := tanum(ty, arg(a, n, 1));
	little := truthy(arg(a, n, 2));
	l := dvlength(t);
	if(l < 0)
		typeerr("the DataView is detached or out of bounds");
	if(idx + real tysize[ty] > real l)
		throwerr(RangeError, "offset is outside the bounds of the DataView");
	setraw(bufof(t).b, t.off + int idx, ty, v, little);
	return undef;
}

# ---- Uint8Array and base64, hex (ES2026 §23.3) ----

b64chars := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
b64urlchars := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

# ValidateUint8Array
validu8(v: V, name: string): ref Data.Typed
{
	if(v.t != Tobj || okind[v.x] != Ktyped || tadata(v.x).ty != Tu8)
		typeerr("Uint8Array.prototype." + name + " called on incompatible receiver " + show(v));
	return tadata(v.x);
}

# GetUint8ArrayBytes
u8bytes(t: ref Data.Typed, name: string): array of byte
{
	l := talength(t);
	if(l < 0)
		typeerr(name + ": the typed array is detached or out of bounds");
	return bufof(t).b[t.off:t.off+l];
}

# GetOptionsObject
optsobj(v: V): V
{
	if(v.t == Tundef)
		return undef;
	if(v.t != Tobj)
		typeerr("options must be an object");
	return v;
}

optget(o: V, k: string): V
{
	if(o.t == Tundef)
		return undef;
	return getv(o, intern(k));
}

b64alphabet(o: V): int
{
	v := optget(o, "alphabet");
	if(v.t == Tundef)
		return 0;
	if(v.t == Tstr)
		case str(v.x) {
		"base64" =>
			return 0;
		"base64url" =>
			return 1;
		}
	typeerr("alphabet must be \"base64\" or \"base64url\"");
	return 0;
}

Loose, Strict, Stopbefore: con iota;

lastchunk(o: V): int
{
	v := optget(o, "lastChunkHandling");
	if(v.t == Tundef)
		return Loose;
	if(v.t == Tstr)
		case str(v.x) {
		"loose" =>
			return Loose;
		"strict" =>
			return Strict;
		"stop-before-partial" =>
			return Stopbefore;
		}
	typeerr("lastChunkHandling must be \"loose\", \"strict\" or \"stop-before-partial\"");
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
		h := hexv(s[read]);
		l := hexv(s[read+1]);
		if(h < 0 || l < 0)
			return (read, out[0:nout], 1);
		read += 2;
		out[nout++] = byte (h * 16 + l);
	}
	return (read, out[0:nout], 0);
}

u8from(b: array of byte): V
{
	h := newta(Tu8, len b, typroto[Tu8]);
	bufof(tadata(h)).b[0:] = b;
	return objv(h);
}

u8_frombase64(nil: V, a, n: int, nil: V, nil: int): V
{
	sv := arg(a, n, 0);
	if(sv.t != Tstr)
		typeerr("Uint8Array.fromBase64: the input must be a string");
	o := optsobj(arg(a, n, 1));
	url := b64alphabet(o);
	last := lastchunk(o);
	(nil, b, bad) := frombase64(str(sv.x), url, last, 16r7FFFFFFF);
	if(bad)
		throwerr(SyntaxError, "Uint8Array.fromBase64: the input is not base64");
	return u8from(b);
}

u8_fromhex(nil: V, a, n: int, nil: V, nil: int): V
{
	sv := arg(a, n, 0);
	if(sv.t != Tstr)
		typeerr("Uint8Array.fromHex: the input must be a string");
	(nil, b, bad) := fromhex(str(sv.x), 16r7FFFFFFF);
	if(bad)
		throwerr(SyntaxError, "Uint8Array.fromHex: the input is not hexadecimal");
	return u8from(b);
}

u8_tobase64(this: V, a, n: int, nil: V, nil: int): V
{
	t := validu8(this, "toBase64");
	o := optsobj(arg(a, n, 0));
	url := b64alphabet(o);
	omit := truthy(optget(o, "omitPadding"));
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
}

u8_tohex(this: V, nil, nil: int, nil: V, nil: int): V
{
	t := validu8(this, "toHex");
	b := u8bytes(t, "Uint8Array.prototype.toHex");
	r := "";
	for(i := 0; i < len b; i++) {
		r[len r] = "0123456789abcdef"[int b[i] >> 4];
		r[len r] = "0123456789abcdef"[int b[i] & 15];
	}
	return strv(r);
}

readwritten(read, written: int): V
{
	o := newplain();
	defown(o, intern("read"), Awrite|Aenum|Aconf, num(real read));
	defown(o, intern("written"), Awrite|Aenum|Aconf, num(real written));
	return objv(o);
}

u8_setfrombase64(this: V, a, n: int, nil: V, nil: int): V
{
	t := validu8(this, "setFromBase64");
	sv := arg(a, n, 0);
	if(sv.t != Tstr)
		typeerr("Uint8Array.prototype.setFromBase64: the input must be a string");
	o := optsobj(arg(a, n, 1));
	url := b64alphabet(o);
	last := lastchunk(o);
	l := talength(t);
	if(l < 0)
		typeerr("Uint8Array.prototype.setFromBase64: the typed array is detached or out of bounds");
	(read, b, bad) := frombase64(str(sv.x), url, last, l);
	bufof(t).b[t.off:] = b;
	if(bad)
		throwerr(SyntaxError, "Uint8Array.prototype.setFromBase64: the input is not base64");
	return readwritten(read, len b);
}

u8_setfromhex(this: V, a, n: int, nil: V, nil: int): V
{
	t := validu8(this, "setFromHex");
	sv := arg(a, n, 0);
	if(sv.t != Tstr)
		typeerr("Uint8Array.prototype.setFromHex: the input must be a string");
	l := talength(t);
	if(l < 0)
		typeerr("Uint8Array.prototype.setFromHex: the typed array is detached or out of bounds");
	(read, b, bad) := fromhex(str(sv.x), l);
	bufof(t).b[t.off:] = b;
	if(bad)
		throwerr(SyntaxError, "Uint8Array.prototype.setFromHex: the input is not hexadecimal");
	return readwritten(read, len b);
}
