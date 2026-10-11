#
# jsistring.b - String, Number, Math and JSON.
#
# The exact decimal conversions (toFixed, toPrecision, toExponential)
# and radix forms follow appl/lib/js/jsstring.b's.
#

NString, NSfromcharcode, NSfromcodepoint, NSraw, NSPat, NSPcharat, NSPcharcodeat, NSPcodepointat,
NSPconcat, NSPendswith, NSPincludes, NSPindexof, NSPiswellformed, NSPlastindexof, NSPlocalecompare,
NSPmatch, NSPmatchall, NSPnormalize, NSPpadend, NSPpadstart, NSPrepeat, NSPreplace, NSPreplaceall,
NSPsearch, NSPslice, NSPsplit, NSPstartswith, NSPsubstring, NSPsubstr, NSPtolocalelower,
NSPtolocaleupper, NSPtolower, NSPtostring, NSPtoupper, NSPtowellformed, NSPtrim, NSPtrimend,
NSPtrimstart, NSPvalueof, NSPiterator, NSInext, NSPhtml: con Nstrbase + iota;

NNumber, NNisfinite, NNisinteger, NNisnan, NNissafe, NNPtoexp, NNPtofixed, NNPtolocale,
NNPtoprec, NNPtostring, NNPvalueof: con Nnumbase + iota;

NMabs, NMacos, NMacosh, NMasin, NMasinh, NMatan, NMatanh, NMatan2, NMcbrt, NMceil, NMclz32, NMcos,
NMcosh, NMexp, NMexpm1, NMfloor, NMfround, NMhypot, NMimul, NMlog, NMlog1p, NMlog10, NMlog2, NMmax,
NMmin, NMpow, NMrandom, NMround, NMsign, NMsin, NMsinh, NMsqrt, NMtan, NMtanh, NMtrunc, NMf16round,
NMsumprecise: con Nmathbase + iota;

NJparse, NJstringify, NJrawjson, NJisrawjson: con Njsonbase + iota;

htmlmethods := array[] of {
	("anchor", "a", "name"), ("big", "big", nil), ("blink", "blink", nil), ("bold", "b", nil),
	("fixed", "tt", nil), ("fontcolor", "font", "color"), ("fontsize", "font", "size"),
	("italics", "i", nil), ("link", "a", "href"), ("small", "small", nil), ("strike", "strike", nil),
	("sub", "sub", nil), ("sup", "sup", nil)
};

striterproto: ref Obj;

stringinit()
{
	c := defctor("String", NString, 1, strproto);
	defmethod(c, "fromCharCode", NSfromcharcode, 1);
	defmethod(c, "fromCodePoint", NSfromcodepoint, 1);
	defmethod(c, "raw", NSraw, 1);
	p := strproto;
	addprop(p, a_length, 0, intv(0));
	defmethod(p, "at", NSPat, 1);
	defmethod(p, "charAt", NSPcharat, 1);
	defmethod(p, "charCodeAt", NSPcharcodeat, 1);
	defmethod(p, "codePointAt", NSPcodepointat, 1);
	defmethod(p, "concat", NSPconcat, 1);
	defmethod(p, "endsWith", NSPendswith, 1);
	defmethod(p, "includes", NSPincludes, 1);
	defmethod(p, "indexOf", NSPindexof, 1);
	defmethod(p, "isWellFormed", NSPiswellformed, 0);
	defmethod(p, "lastIndexOf", NSPlastindexof, 1);
	defmethod(p, "localeCompare", NSPlocalecompare, 1);
	defmethod(p, "match", NSPmatch, 1);
	defmethod(p, "matchAll", NSPmatchall, 1);
	defmethod(p, "normalize", NSPnormalize, 0);
	defmethod(p, "padEnd", NSPpadend, 1);
	defmethod(p, "padStart", NSPpadstart, 1);
	defmethod(p, "repeat", NSPrepeat, 1);
	defmethod(p, "replace", NSPreplace, 2);
	defmethod(p, "replaceAll", NSPreplaceall, 2);
	defmethod(p, "search", NSPsearch, 1);
	defmethod(p, "slice", NSPslice, 2);
	defmethod(p, "split", NSPsplit, 2);
	defmethod(p, "startsWith", NSPstartswith, 1);
	defmethod(p, "substring", NSPsubstring, 2);
	defmethod(p, "substr", NSPsubstr, 2);
	defmethod(p, "toLocaleLowerCase", NSPtolocalelower, 0);
	defmethod(p, "toLocaleUpperCase", NSPtolocaleupper, 0);
	defmethod(p, "toLowerCase", NSPtolower, 0);
	defmethod(p, "toString", NSPtostring, 0);
	defmethod(p, "toUpperCase", NSPtoupper, 0);
	defmethod(p, "toWellFormed", NSPtowellformed, 0);
	defmethod(p, "trim", NSPtrim, 0);
	te := defmethod(p, "trimEnd", NSPtrimend, 0);
	ts := defmethod(p, "trimStart", NSPtrimstart, 0);
	defprop(p, intern("trimLeft"), objv(ts), Awrite|Aconf);
	defprop(p, intern("trimRight"), objv(te), Awrite|Aconf);
	defmethod(p, "valueOf", NSPvalueof, 0);
	defsymmethod(p, a_symiterator, "[Symbol.iterator]", NSPiterator, 0);
	for(i := 0; i < len htmlmethods; i++) {
		(name, nil, attr) := htmlmethods[i];
		nargs := 0;
		if(attr != nil)
			nargs = 1;
		f := defmethod(p, name, NSPhtml, nargs);
		f.data = ref Data.Native(intv(i), undef, 0, nil);
	}
	striterproto = newobj(Cplain, iterproto);
	defmethod(striterproto, "next", NSInext, 0);
	defprop(striterproto, a_symtostringtag, strv("String Iterator"), Aconf);
}

# RequireObjectCoercible(this), then ToString
thisstr(this: V, name: string): string
{
	if(this.t == Tstr)
		return this.s;
	if(this.t == Tundef || this.t == Tnull)
		throwtype("String.prototype." + name + " called on null or undefined");
	return tostr(this);
}

strarg(args: array of V, i: int): string
{
	return tostr(arg(args, i));
}

# a position argument clamped to [0, n]
clamppos(v: V, n: int, dflt: int): int
{
	if(v.t == Tundef)
		return dflt;
	x := tointeger(v);
	if(x < 0.0)
		return 0;
	if(x > real n)
		return n;
	return int x;
}

strindex(s, t: string, from: int): int
{
	n := len t;
	if(n == 0) {
		if(from > len s)
			return len s;
		return from;
	}
	c := t[0];
	for(i := from; i + n <= len s; i++)
		if(s[i] == c && s[i:i+n] == t)
			return i;
	return -1;
}

isregexpv(v: V): int
{
	if(v.t != Tobj)
		return 0;
	m := getv(v.o, a_symmatch);
	if(m.t != Tundef)
		return tobool(m);
	return v.o.cls == Cregexp;
}

natstring(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NString =>
		s: V;
		if(len args == 0)
			s = strv("");
		else if(nt == nil && args[0].t == Tsym)
			return strv(showv(args[0]));
		else
			s = tostrv(args[0]);
		if(nt == nil)
			return s;
		o := fromctor(nt, strproto, Cstr);
		o.data = ref Data.Prim(strv(flat(s)));
		addprop(o, a_length, 0, intv(strlenv(s)));
		return objv(o);
	NSfromcharcode =>
		r := "";
		for(i := 0; i < len args; i++)
			r[len r] = toint32(args[i]) & 16rFFFF;
		return strv(r);
	NSfromcodepoint =>
		r := "";
		for(i := 0; i < len args; i++) {
			x := tonum(args[i]);
			if(isnan(x) || x < 0.0 || x > 1114111.0 || x != trunc(x))
				throwerr(ERange, "Invalid code point " + tostr(args[i]));
			r = addcp(r, int x);
		}
		return strv(r);
	NSraw =>
		cooked := toobj(arg(args, 0));
		raw := toobj(getv(cooked, a_raw));
		n := lengthof(raw);
		if(n <= 0.0)
			return strv("");
		r := "";
		for(i := 0.0; i < n; i += 1.0) {
			r += tostr(gidx(raw, i, objv(raw)));
			if(i + 1.0 < n && int i + 1 < len args)
				r += tostr(args[int i + 1]);
		}
		return strv(r);
	NSInext =>
		if(this.t != Tobj || this.o.cls != Citer)
			throwtype("next called on incompatible receiver");
		pick d := this.o.data {
		Iter =>
			if(d.done)
				return iterresult(undef, 1);
			s := d.v.s;
			i := d.i;
			if(i >= len s) {
				d.done = 1;
				return iterresult(undef, 1);
			}
			c := s[i];
			n := 1;
			if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF)
				n = 2;
			d.i = i + n;
			return iterresult(strv(s[i:i+n]), 0);
		}
		return undef;
	NSPtostring or NSPvalueof =>
		return thisprim(this, Cstr, Tstr, "String");
	NSPhtml =>
		s := thisstr(this, "anchor");
		pick d := f.data {
		Native =>
			(nil, tag, attr) := htmlmethods[d.v.i];
			r := "<" + tag;
			if(attr != nil) {
				v := strarg(args, 0);
				q := "";
				for(i := 0; i < len v; i++)
					if(v[i] == '"')
						q += "&quot;";
					else
						q[len q] = v[i];
				r += " " + attr + "=\"" + q + "\"";
			}
			return strv(r + ">" + s + "</" + tag + ">");
		}
	NSPmatch or NSPmatchall or NSPsearch or NSPreplace or NSPreplaceall or NSPsplit =>
		return strregexpish(id, this, args);
	}
	s := thisstr(this, "method");
	case id {
	NSPat =>
		k := tointeger(arg(args, 0));
		if(k < 0.0)
			k += real len s;
		if(k < 0.0 || k >= real len s)
			return undef;
		i := int k;
		return strv(s[i:i+1]);
	NSPcharat =>
		k := tointeger(arg(args, 0));
		if(k < 0.0 || k >= real len s)
			return strv("");
		i := int k;
		return strv(s[i:i+1]);
	NSPcharcodeat =>
		a := arg(args, 0);
		i: int;
		if(a.t == Tint)
			i = a.i;
		else {
			k := tointeger(a);
			if(k < 0.0 || k >= real len s)
				return V(Tnum, 0, nan, nil, nil);
			i = int k;
		}
		if(i < 0 || i >= len s)
			return V(Tnum, 0, nan, nil, nil);
		return intv(s[i]);
	NSPcodepointat =>
		k := tointeger(arg(args, 0));
		if(k < 0.0 || k >= real len s)
			return undef;
		i := int k;
		c := s[i];
		if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF)
			return intv(16r10000 + ((c - 16rD800) << 10) + (s[i+1] - 16rDC00));
		return intv(c);
	NSPconcat =>
		r := strv(s);
		for(i := 0; i < len args; i++)
			r = concat(r, tostrv(args[i]));
		return r;
	NSPendswith or NSPstartswith or NSPincludes =>
		if(isregexpv(arg(args, 0)))
			throwtype("First argument to String.prototype method must not be a regular expression");
		t := strarg(args, 0);
		case id {
		NSPendswith =>
			end := clamppos(arg(args, 1), len s, len s);
			st := end - len t;
			if(st < 0)
				return falsev;
			return boolv(s[st:end] == t);
		NSPstartswith =>
			st := clamppos(arg(args, 1), len s, 0);
			if(st + len t > len s)
				return falsev;
			return boolv(s[st:st + len t] == t);
		* =>
			st := clamppos(arg(args, 1), len s, 0);
			return boolv(strindex(s, t, st) >= 0);
		}
	NSPindexof =>
		t := strarg(args, 0);
		st := clamppos(arg(args, 1), len s, 0);
		return intv(strindex(s, t, st));
	NSPiswellformed =>
		return boolv(wellformed(s) == s);
	NSPtowellformed =>
		return strv(wellformed(s));
	NSPlastindexof =>
		t := strarg(args, 0);
		x := tonum(arg(args, 1));
		st := len s;
		if(!isnan(x)) {
			x = trunc(x);
			if(x < 0.0)
				st = 0;
			else if(x < real len s)
				st = int x;
		}
		if(st + len t > len s)
			st = len s - len t;
		for(i := st; i >= 0; i--)
			if(s[i:i + len t] == t)
				return intv(i);
		return intv(-1);
	NSPlocalecompare =>
		t := strarg(args, 0);
		if(s < t)
			return intv(-1);
		if(s > t)
			return intv(1);
		return intv(0);
	NSPnormalize =>
		form := "NFC";
		if(arg(args, 0).t != Tundef)
			form = strarg(args, 0);
		if(form != "NFC" && form != "NFD" && form != "NFKC" && form != "NFKD")
			throwerr(ERange, "The normalization form should be one of NFC, NFD, NFKC, NFKD.");
		return strv(normalize(s, form));
	NSPpadend or NSPpadstart =>
		n := tolength(arg(args, 0));
		if(n <= real len s)
			return strv(s);
		fill := " ";
		if(arg(args, 1).t != Tundef)
			fill = strarg(args, 1);
		if(fill == "")
			return strv(s);
		if(n > real Maxstr)
			throwerr(ERange, "Invalid string length");
		need := int n - len s;
		pad := "";
		while(len pad < need)
			pad += fill;
		pad = pad[0:need];
		if(id == NSPpadend)
			return strv(s + pad);
		return strv(pad + s);
	NSPrepeat =>
		n := tointeger(arg(args, 0));
		if(n < 0.0 || n == inf)
			throwerr(ERange, "Invalid count value: " + numstr(n));
		if(len s == 0 || n == 0.0)
			return strv("");
		if(n * real len s > real Maxstr)
			throwerr(ERange, "Invalid string length");
		k := int n;
		r := "";
		p := s;
		while(k > 0) {
			if(k & 1)
				r += p;
			k >>= 1;
			if(k > 0)
				p += p;
		}
		return strv(r);
	NSPslice =>
		n := real len s;
		st := relidx(arg(args, 0), n, 0.0);
		end := relidx(arg(args, 1), n, n);
		if(st >= end)
			return strv("");
		return strv(s[int st:int end]);
	NSPsubstring =>
		st := clamppos(arg(args, 0), len s, 0);
		end := clamppos(arg(args, 1), len s, len s);
		if(st > end)
			(st, end) = (end, st);
		return strv(s[st:end]);
	NSPsubstr =>
		n := real len s;
		st := relidx(arg(args, 0), n, 0.0);
		l := n - st;
		if(arg(args, 1).t != Tundef) {
			l = tointeger(args[1]);
			if(l > n - st)
				l = n - st;
		}
		if(l <= 0.0)
			return strv("");
		return strv(s[int st:int (st + l)]);
	NSPtolower or NSPtolocalelower =>
		if(isascii(s, 1))
			return strv(asciicase(s, 0));
		return strv(jsre->casemap(s, 0));
	NSPtoupper or NSPtolocaleupper =>
		if(isascii(s, 0))
			return strv(asciicase(s, 1));
		return strv(jsre->casemap(s, 1));
	NSPtrim =>
		return strv(trimws(s, 1, 1));
	NSPtrimstart =>
		return strv(trimws(s, 1, 0));
	NSPtrimend =>
		return strv(trimws(s, 0, 1));
	NSPiterator =>
		it := newobj(Citer, striterproto);
		it.data = ref Data.Iter(0, nil, strv(s), 0, 0, nil);
		return objv(it);
	}
	throwerr(EError, "unknown String built-in " + string id);
	return undef;
}

isascii(s: string, nil: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 128)
			return 0;
	return 1;
}

asciicase(s: string, upper: int): string
{
	r := s;
	changed := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(upper && c >= 'a' && c <= 'z') {
			if(!changed) {
				r = s[0:i];
				changed = 1;
			}
			r[i] = c - 32;
		} else if(!upper && c >= 'A' && c <= 'Z') {
			if(!changed) {
				r = s[0:i];
				changed = 1;
			}
			r[i] = c + 32;
		} else if(changed)
			r[i] = c;
	}
	return r;
}

addcp(r: string, cp: int): string
{
	if(cp >= 16r10000) {
		cp -= 16r10000;
		r[len r] = 16rD800 + (cp >> 10);
		r[len r] = 16rDC00 + (cp & 16r3FF);
	} else
		r[len r] = cp;
	return r;
}

# lone surrogates replaced by U+FFFD
wellformed(s: string): string
{
	r := s;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 16rD800 && c <= 16rDBFF) {
			if(i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF) {
				i++;
				continue;
			}
			if(r == s)
				r = s[0:];
			r[i] = 16rFFFD;
		} else if(c >= 16rDC00 && c <= 16rDFFF) {
			if(r == s)
				r = s[0:];
			r[i] = 16rFFFD;
		}
	}
	return r;
}

normalize(s: string, nil: string): string
{
	return s;
}

# match, matchAll, replace, replaceAll, search, split: by the argument's symbol method, else as strings
strregexpish(id: int, this: V, args: array of V): V
{
	if(this.t == Tundef || this.t == Tnull)
		throwtype("String.prototype method called on null or undefined");
	rx := arg(args, 0);
	sym := 0;
	case id {
	NSPmatch => sym = a_symmatch;
	NSPmatchall => sym = a_symmatchall;
	NSPsearch => sym = a_symsearch;
	NSPreplace or NSPreplaceall => sym = a_symreplace;
	NSPsplit => sym = a_symsplit;
	}
	if(rx.t != Tundef && rx.t != Tnull) {
		if(id == NSPreplaceall || id == NSPmatchall) {
			if(isregexpv(rx)) {
				fl := getv(rx.o, a_flags);
				if(fl.t == Tundef || fl.t == Tnull)
					throwtype("flags is null or undefined");
				if(!instr(tostr(fl), 'g'))
					throwtype("replaceAll and matchAll must be called with a global RegExp");
			}
		}
		m := getmethod(rx, sym);
		if(m != nil) {
			a := array[len args] of V;
			a[0:] = args;
			if(len a == 0)
				a = array[] of {undef};
			a[0] = this;
			return call(m, rx, a);
		}
	}
	s := tostr(this);
	case id {
	NSPmatch or NSPsearch or NSPmatchall =>
		re := regexpcreate(rx, id == NSPmatchall);
		return invoke(objv(re), sym, array[] of {strv(s)});
	NSPsplit =>
		lim := 4294967295.0;
		if(arg(args, 1).t != Tundef)
			lim = touint32(args[1]);
		sep := tostr(rx);
		r := newarray(0);
		if(lim == 0.0)
			return objv(r);
		if(rx.t == Tundef) {
			apush(r, strv(s));
			return objv(r);
		}
		if(sep == "") {
			for(i := 0; i < len s && real i < lim; i++)
				apush(r, strv(s[i:i+1]));
			return objv(r);
		}
		p := 0;
		for(;;) {
			q := strindex(s, sep, p);
			if(q < 0)
				break;
			apush(r, strv(s[p:q]));
			if(real r.alen >= lim)
				return objv(r);
			p = q + len sep;
		}
		apush(r, strv(s[p:]));
		return objv(r);
	* =>
		# replace and replaceAll with a string pattern
		pat := tostr(rx);
		rv := arg(args, 1);
		fnv := iscallable(rv);
		repl := "";
		if(!fnv)
			repl = tostr(rv);
		all := id == NSPreplaceall;
		adv := len pat;
		if(adv == 0)
			adv = 1;
		pos := strindex(s, pat, 0);
		if(pos < 0)
			return strv(s);
		r := "";
		end := 0;
		while(pos >= 0) {
			r += s[end:pos];
			if(fnv)
				r += tostr(call(rv.o, undef, array[] of {strv(pat), intv(pos), strv(s)}));
			else
				r += substitution(pat, s, pos, nil, undef, repl);
			end = pos + len pat;
			if(!all)
				break;
			pos = strindex(s, pat, pos + adv);
		}
		if(end < len s)
			r += s[end:];
		return strv(r);
	}
}

# GetSubstitution
substitution(matched, s: string, pos: int, caps: array of V, groups: V, repl: string): string
{
	r := "";
	m := len caps;
	tailpos := pos + len matched;
	for(i := 0; i < len repl; i++) {
		c := repl[i];
		if(c != '$' || i + 1 >= len repl) {
			r[len r] = c;
			continue;
		}
		d := repl[i+1];
		case d {
		'$' =>
			r[len r] = '$';
			i++;
		'&' =>
			r += matched;
			i++;
		'`' =>
			r += s[0:pos];
			i++;
		'\'' =>
			if(tailpos < len s)
				r += s[tailpos:];
			i++;
		'<' =>
			if(groups.t == Tundef) {
				r[len r] = '$';
				continue;
			}
			e := strindex(repl, ">", i + 2);
			if(e < 0) {
				r[len r] = '$';
				continue;
			}
			gname := repl[i+2:e];
			v := getvalue(groups, intern(gname));
			if(v.t != Tundef)
				r += tostr(v);
			i = e;
		'0' to '9' =>
			idx := d - '0';
			two := 0;
			if(i + 2 < len repl && repl[i+2] >= '0' && repl[i+2] <= '9') {
				i2 := idx * 10 + repl[i+2] - '0';
				if(i2 >= 1 && i2 <= m) {
					idx = i2;
					two = 1;
				}
			}
			if(idx < 1 || idx > m) {
				r[len r] = '$';
				continue;
			}
			v := caps[idx-1];
			if(v.t != Tundef)
				r += tostr(v);
			i += 1 + two;
		* =>
			r[len r] = '$';
		}
	}
	return r;
}

# ---- Number ----

numberinit()
{
	c := defctor("Number", NNumber, 1, numproto);
	defval(c, "EPSILON", V(Tnum, 0, math->pow(2.0, -52.0), nil, nil), 0);
	defval(c, "MAX_SAFE_INTEGER", V(Tnum, 0, 9007199254740991.0, nil, nil), 0);
	defval(c, "MIN_SAFE_INTEGER", V(Tnum, 0, -9007199254740991.0, nil, nil), 0);
	defval(c, "MAX_VALUE", V(Tnum, 0, 1.7976931348623157e308, nil, nil), 0);
	defval(c, "MIN_VALUE", V(Tnum, 0, math->scalbn(1.0, -1074), nil, nil), 0);
	defval(c, "NaN", V(Tnum, 0, nan, nil, nil), 0);
	defval(c, "NEGATIVE_INFINITY", V(Tnum, 0, -inf, nil, nil), 0);
	defval(c, "POSITIVE_INFINITY", V(Tnum, 0, inf, nil, nil), 0);
	defmethod(c, "isFinite", NNisfinite, 1);
	defmethod(c, "isInteger", NNisinteger, 1);
	defmethod(c, "isNaN", NNisnan, 1);
	defmethod(c, "isSafeInteger", NNissafe, 1);
	p := numproto;
	defmethod(p, "toExponential", NNPtoexp, 1);
	defmethod(p, "toFixed", NNPtofixed, 1);
	defmethod(p, "toLocaleString", NNPtolocale, 0);
	defmethod(p, "toPrecision", NNPtoprec, 1);
	defmethod(p, "toString", NNPtostring, 1);
	defmethod(p, "valueOf", NNPvalueof, 0);
}

isfinitenum(x: real): int
{
	return !isnan(x) && x != inf && x != -inf;
}

thisnum(this: V, name: string): real
{
	return numof(thisprim(this, Cnum, Tint, "Number." + name));
}

natnumber(id: int, nil: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NNumber =>
		x := intv(0);
		if(len args > 0) {
			p := tonumeric(args[0]);
			if(p.t == Tbig)
				x = V(Tnum, 0, bigtonum(p.o), nil, nil);
			else
				x = p;
		}
		if(nt == nil)
			return x;
		o := fromctor(nt, numproto, Cnum);
		o.data = ref Data.Prim(x);
		return objv(o);
	NNisfinite =>
		a := arg(args, 0);
		return boolv(isnum(a) && isfinitenum(numof(a)));
	NNisinteger or NNissafe =>
		a := arg(args, 0);
		if(!isnum(a))
			return falsev;
		x := numof(a);
		if(!isfinitenum(x) || trunc(x) != x)
			return falsev;
		if(id == NNissafe && (x > 9007199254740991.0 || x < -9007199254740991.0))
			return falsev;
		return truev;
	NNisnan =>
		a := arg(args, 0);
		return boolv(isnum(a) && isnan(numof(a)));
	NNPvalueof =>
		return thisprim(this, Cnum, Tint, "Number.valueOf");
	NNPtolocale =>
		return strv(numstr(thisnum(this, "toLocaleString")));
	NNPtostring =>
		x := thisnum(this, "toString");
		r := arg(args, 0);
		radix := 10;
		if(r.t != Tundef) {
			rr := tointeger(r);
			if(rr < 2.0 || rr > 36.0)
				throwerr(ERange, "toString() radix must be between 2 and 36");
			radix = int rr;
		}
		if(radix == 10)
			return strv(numstr(x));
		return strv(radixstr(x, radix));
	NNPtofixed =>
		x := thisnum(this, "toFixed");
		fd := tointeger(arg(args, 0));
		if(fd < 0.0 || fd > 100.0)
			throwerr(ERange, "toFixed() digits argument must be between 0 and 100");
		if(isnan(x))
			return strv("NaN");
		if(x >= 1e21 || x <= -1e21)
			return strv(numstr(x));
		f := int fd;
		neg := x < 0.0;
		if(neg)
			x = -x;
		s := fixeddigits(x, f);
		if(neg && x != 0.0 && !allzero(s))
			s = "-" + s;
		return strv(s);
	NNPtoexp =>
		x := thisnum(this, "toExponential");
		fv := arg(args, 0);
		fd := tointeger(fv);
		if(!isfinitenum(x))
			return strv(numstr(x));
		if(fd < 0.0 || fd > 100.0)
			throwerr(ERange, "toExponential() argument must be between 0 and 100");
		neg := x < 0.0;
		if(neg)
			x = -x;
		s: string;
		if(fv.t == Tundef) {
			(d, e) := digitsexp(x);
			s = d[0:1];
			if(len d > 1)
				s += "." + d[1:];
			s += expsuffix(e);
		} else {
			f := int fd;
			(d, e) := precdigits(x, f + 1);
			s = d[0:1];
			if(f > 0)
				s += "." + d[1:];
			s += expsuffix(e);
		}
		if(neg)
			s = "-" + s;
		return strv(s);
	NNPtoprec =>
		x := thisnum(this, "toPrecision");
		pv := arg(args, 0);
		if(pv.t == Tundef)
			return strv(numstr(x));
		p := tointeger(pv);
		if(!isfinitenum(x))
			return strv(numstr(x));
		if(p < 1.0 || p > 100.0)
			throwerr(ERange, "toPrecision() argument must be between 1 and 100");
		ip := int p;
		neg := x < 0.0;
		if(neg)
			x = -x;
		s: string;
		if(x == 0.0) {
			s = "0";
			if(ip > 1) {
				s += ".";
				for(i := 1; i < ip; i++)
					s[len s] = '0';
			}
		} else {
			(d, e) := precdigits(x, ip);
			if(e < -6 || e >= ip) {
				s = d[0:1];
				if(ip > 1)
					s += "." + d[1:];
				s += expsuffix(e);
			} else if(e == ip - 1)
				s = d;
			else if(e >= 0)
				s = d[0:e+1] + "." + d[e+1:];
			else {
				s = "0.";
				for(i := 0; i < -(e + 1); i++)
					s[len s] = '0';
				s += d;
			}
		}
		if(neg)
			s = "-" + s;
		return strv(s);
	}
	throwerr(EError, "unknown Number built-in");
	return undef;
}

digitchars := "0123456789abcdefghijklmnopqrstuvwxyz";

radixstr(x: real, r: int): string
{
	if(isnan(x))
		return "NaN";
	if(x == inf)
		return "Infinity";
	if(x == -inf)
		return "-Infinity";
	if(x == 0.0)
		return "0";
	neg := x < 0.0;
	if(neg)
		x = -x;
	ip := math->floor(x);
	fp := x - ip;
	s := "";
	if(ip == 0.0)
		s = "0";
	while(ip > 0.0) {
		d := int math->fmod(ip, real r);
		s[len s] = digitchars[d];
		ip = math->floor(ip / real r);
	}
	t := "";
	for(i := len s - 1; i >= 0; i--)
		t[len t] = s[i];
	if(fp > 0.0) {
		t += ".";
		maxd := int (52.0 / (math->log(real r) / math->log(2.0))) + 1;
		for(k := 0; fp > 0.0 && k < 1100; k++) {
			fp *= real r;
			d := int math->floor(fp);
			fp -= real d;
			t[len t] = digitchars[d];
			if(k >= maxd && r != 2 && r != 4 && r != 8 && r != 16 && r != 32)
				break;
		}
	}
	if(neg)
		return "-" + t;
	return t;
}

allzero(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] != '0' && s[i] != '.')
			return 0;
	return 1;
}

digitsexp(x: real): (string, int)
{
	if(x == 0.0)
		return ("0", 0);
	for(p := 1; p <= 17; p++) {
		s := sys->sprint("%.*e", p - 1, x);
		if(decimal(s) == x || p == 17) {
			(d, e) := splitexp(s);
			while(len d > 1 && d[len d - 1] == '0')
				d = d[0:len d - 1];
			return (d, e);
		}
	}
	return ("0", 0);
}

expsuffix(e: int): string
{
	if(e >= 0)
		return "e+" + string e;
	return "e-" + string -e;
}

ipinit := 0;

# x * 10^k, rounded half up to an integer (x finite, not negative)
scaledround(x: real, k: int): ref IPint
{
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
	num := IPint.strtoip(string m, 10);
	den := IPint.inttoip(1);
	if(e >= 0)
		num = num.shl(e);
	else
		den = den.shl(-e);
	if(k >= 0)
		num = num.mul(pow10ip(k));
	else
		den = den.mul(pow10ip(-k));
	(q, nil) := num.shl(1).add(den).div(den.shl(1));
	return q;
}

pow10ip(k: int): ref IPint
{
	r := IPint.inttoip(1);
	ten := IPint.inttoip(10);
	for(i := 0; i < k; i++)
		r = r.mul(ten);
	return r;
}

fixeddigits(x: real, f: int): string
{
	d := scaledround(x, f).iptostr(10);
	while(len d < f + 1)
		d = "0" + d;
	if(f == 0)
		return d;
	return d[0:len d - f] + "." + d[len d - f:];
}

precdigits(x: real, p: int): (string, int)
{
	if(x == 0.0) {
		d := "";
		for(i := 0; i < p; i++)
			d[len d] = '0';
		return (d, 0);
	}
	e := int math->floor(math->log10(x));
	for(tries := 0; tries < 4; tries++) {
		d := scaledround(x, p - 1 - e).iptostr(10);
		if(len d > p)
			e++;
		else if(len d < p)
			e--;
		else {
			d1 := scaledround(x, p - e).iptostr(10);
			if(len d1 == p)
				return (d1, e - 1);
			return (d, e);
		}
	}
	d := scaledround(x, p - 1 - e).iptostr(10);
	return (d[0:p], e);
}

# ---- Math ----

mathinit()
{
	m := plainobj();
	defval(global, "Math", objv(m), Awrite|Aconf);
	defprop(m, a_symtostringtag, strv("Math"), Aconf);
	defval(m, "E", V(Tnum, 0, math->exp(1.0), nil, nil), 0);
	defval(m, "LN10", V(Tnum, 0, math->log(10.0), nil, nil), 0);
	defval(m, "LN2", V(Tnum, 0, math->log(2.0), nil, nil), 0);
	defval(m, "LOG10E", V(Tnum, 0, 1.0 / math->log(10.0), nil, nil), 0);
	defval(m, "LOG2E", V(Tnum, 0, 1.0 / math->log(2.0), nil, nil), 0);
	defval(m, "PI", V(Tnum, 0, math->Pi, nil, nil), 0);
	defval(m, "SQRT1_2", V(Tnum, 0, math->sqrt(0.5), nil, nil), 0);
	defval(m, "SQRT2", V(Tnum, 0, math->sqrt(2.0), nil, nil), 0);
	names := array[] of {"abs", "acos", "acosh", "asin", "asinh", "atan", "atanh", "atan2", "cbrt", "ceil",
		"clz32", "cos", "cosh", "exp", "expm1", "floor", "fround", "hypot", "imul", "log", "log1p", "log10",
		"log2", "max", "min", "pow", "random", "round", "sign", "sin", "sinh", "sqrt", "tan", "tanh", "trunc",
		"f16round", "sumPrecise"};
	for(i := 0; i < len names; i++) {
		n := 1;
		case names[i] {
		"atan2" or "hypot" or "imul" or "max" or "min" or "pow" =>
			n = 2;
		"random" =>
			n = 0;
		}
		defmethod(m, names[i], Nmathbase + i, n);
	}
	seed = big sys->millisec() * big 2654435761 + big 1;
}

seed: big;

natmath(id: int, nil: V, args: array of V): V
{
	case id {
	NMmax or NMmin =>
		r := -inf;
		if(id == NMmin)
			r = inf;
		isnanr := 0;
		for(i := 0; i < len args; i++) {
			x := tonum(args[i]);
			if(isnan(x)) {
				isnanr = 1;
				continue;
			}
			if(id == NMmax) {
				if(x > r || x == 0.0 && r == 0.0 && !negzero(x))
					r = x;
			} else {
				if(x < r || x == 0.0 && r == 0.0 && negzero(x))
					r = x;
			}
		}
		if(isnanr)
			return V(Tnum, 0, nan, nil, nil);
		return numv(r);
	NMhypot =>
		xs := array[len args] of real;
		for(i := 0; i < len args; i++)
			xs[i] = tonum(args[i]);
		isinf := 0;
		isn := 0;
		mx := 0.0;
		for(i = 0; i < len xs; i++) {
			x := xs[i];
			if(x == inf || x == -inf)
				isinf = 1;
			else if(isnan(x))
				isn = 1;
			else {
				if(x < 0.0)
					x = -x;
				if(x > mx)
					mx = x;
			}
		}
		if(isinf)
			return V(Tnum, 0, inf, nil, nil);
		if(isn)
			return V(Tnum, 0, nan, nil, nil);
		if(mx == 0.0)
			return intv(0);
		s := 0.0;
		c := 0.0;
		for(i = 0; i < len xs; i++) {
			y := xs[i] / mx;
			y = y * y - c;
			t := s + y;
			c = (t - s) - y;
			s = t;
		}
		return V(Tnum, 0, math->sqrt(s) * mx, nil, nil);
	NMimul =>
		a := toint32(arg(args, 0));
		b := toint32(arg(args, 1));
		return intv(int (big a * big b));
	NMatan2 =>
		y := tonum(arg(args, 0));
		x := tonum(arg(args, 1));
		return V(Tnum, 0, math->atan2(y, x), nil, nil);
	NMpow =>
		x := tonum(arg(args, 0));
		y := tonum(arg(args, 1));
		return V(Tnum, 0, jspow(x, y), nil, nil);
	NMrandom =>
		seed = seed * big 6364136223846793005 + big 1442695040888963407;
		b := (seed >> 11) & ((big 1 << 53) - big 1);
		return V(Tnum, 0, real b / 9007199254740992.0, nil, nil);
	NMclz32 =>
		u := touint32(arg(args, 0));
		if(u == 0.0)
			return intv(32);
		n := 0;
		while(u < 2147483648.0) {
			u *= 2.0;
			n++;
		}
		return intv(n);
	NMsumprecise =>
		return sumprecise(arg(args, 0));
	}
	a := arg(args, 0);
	if(a.t == Tint) {
		i := a.i;
		case id {
		NMabs =>
			if(i >= 0)
				return a;
			if(i != int 16r80000000)
				return intv(-i);
		NMfloor or NMceil or NMround or NMtrunc =>
			return a;
		NMsign =>
			if(i > 0)
				return intv(1);
			if(i < 0)
				return intv(-1);
			return intv(0);
		}
	}
	x := tonum(a);
	r: real;
	case id {
	NMabs =>
		r = math->fabs(x);
	NMacos =>
		r = math->acos(x);
	NMacosh =>
		r = math->acosh(x);
	NMasin =>
		r = math->asin(x);
	NMasinh =>
		if(x == 0.0)
			r = x;
		else
			r = math->asinh(x);
	NMatan =>
		r = math->atan(x);
	NMatanh =>
		if(x == 0.0)
			r = x;
		else
			r = math->atanh(x);
	NMcbrt =>
		r = math->cbrt(x);
	NMceil =>
		if(isnan(x) || !isfinitenum(x))
			r = x;
		else {
			r = math->ceil(x);
			if(r == 0.0 && x < 0.0)
				r = -0.0;
		}
	NMcos =>
		r = math->cos(x);
	NMcosh =>
		r = math->cosh(x);
	NMexp =>
		r = math->exp(x);
	NMexpm1 =>
		if(x == 0.0)
			r = x;
		else
			r = math->expm1(x);
	NMfloor =>
		if(isnan(x) || !isfinitenum(x))
			r = x;
		else
			r = math->floor(x);
	NMfround =>
		r = fround(x);
	NMf16round =>
		r = f16round(x);
	NMlog =>
		r = math->log(x);
	NMlog1p =>
		if(x == 0.0)
			r = x;
		else
			r = math->log1p(x);
	NMlog10 =>
		r = math->log10(x);
	NMlog2 =>
		if(x > 0.0) {
			r = math->log(x) / math->log(2.0);
			# exact for powers of two
			e := math->ilogb(x);
			if(math->scalbn(1.0, e) == x)
				r = real e;
		} else
			r = math->log(x) / math->log(2.0);
	NMround =>
		if(isnan(x) || !isfinitenum(x) || x == 0.0)
			r = x;
		else if(x > 0.0 && x < 0.5)
			r = 0.0;
		else if(x < 0.0 && x >= -0.5)
			r = -0.0;
		else {
			f := math->floor(x);
			if(x - f >= 0.5)
				r = f + 1.0;
			else
				r = f;
		}
	NMsign =>
		if(isnan(x) || x == 0.0)
			r = x;
		else if(x > 0.0)
			r = 1.0;
		else
			r = -1.0;
	NMsin =>
		if(x == 0.0)
			r = x;
		else
			r = math->sin(x);
	NMsinh =>
		if(x == 0.0)
			r = x;
		else
			r = math->sinh(x);
	NMsqrt =>
		if(x == 0.0)
			r = x;
		else
			r = math->sqrt(x);
	NMtan =>
		if(x == 0.0)
			r = x;
		else
			r = math->tan(x);
	NMtanh =>
		if(x == 0.0)
			r = x;
		else
			r = math->tanh(x);
	NMtrunc =>
		if(isnan(x) || !isfinitenum(x))
			r = x;
		else
			r = trunc(x);
	* =>
		throwerr(EError, "unknown Math built-in");
	}
	return V(Tnum, 0, r, nil, nil);
}

fround(x: real): real
{
	if(isnan(x) || x == 0.0 || !isfinitenum(x))
		return x;
	b := array[4] of byte;
	math->export_real32(b, array[] of {x});
	r := array[1] of real;
	math->import_real32(b, r);
	return r[0];
}

f16round(x: real): real
{
	if(isnan(x) || x == 0.0 || !isfinitenum(x))
		return x;
	neg := x < 0.0;
	if(neg)
		x = -x;
	r: real;
	if(x >= 65520.0)
		r = inf;
	else {
		e := math->ilogb(x);
		if(e < -14)
			e = -14;
		q := math->scalbn(1.0, e - 10);
		r = math->rint(x / q) * q;
	}
	if(neg)
		return -r;
	return r;
}

sumprecise(items: V): V
{
	it := getiterator(items, 0);
	next := getvalue(it, a_next);
	vals: list of real;
	for(;;) {
		r := call1(next, it, nil);
		if(r.t != Tobj)
			throwtype("Iterator result is not an object");
		if(tobool(getv(r.o, a_done)))
			break;
		v := getv(r.o, a_value);
		if(!isnum(v)) {
			iterclose(it, 1);
			throwtype("Math.sumPrecise requires numbers");
		}
		vals = numof(v) :: vals;
	}
	s := -0.0;
	c := 0.0;
	posinf := 0;
	neginf := 0;
	isn := 0;
	r: list of real;
	for(; vals != nil; vals = tl vals)
		r = hd vals :: r;
	for(; r != nil; r = tl r) {
		x := hd r;
		if(isnan(x)) {
			isn = 1;
			continue;
		}
		if(x == inf) {
			posinf = 1;
			continue;
		}
		if(x == -inf) {
			neginf = 1;
			continue;
		}
		t := s + x;
		if(math->fabs(s) >= math->fabs(x))
			c += (s - t) + x;
		else
			c += (x - t) + s;
		s = t;
	}
	if(isn || posinf && neginf)
		return V(Tnum, 0, nan, nil, nil);
	if(posinf)
		return V(Tnum, 0, inf, nil, nil);
	if(neginf)
		return V(Tnum, 0, -inf, nil, nil);
	if(c == 0.0)
		return V(Tnum, 0, s, nil, nil);	# s + +0 would lose a -0 sum
	return V(Tnum, 0, s + c, nil, nil);
}

# ---- JSON ----

rawjsonproto: ref Obj;

jsoninit()
{
	j := plainobj();
	defval(global, "JSON", objv(j), Awrite|Aconf);
	defmethod(j, "parse", NJparse, 2);
	defmethod(j, "stringify", NJstringify, 3);
	defmethod(j, "rawJSON", NJrawjson, 1);
	defmethod(j, "isRawJSON", NJisrawjson, 1);
	defprop(j, a_symtostringtag, strv("JSON"), Aconf);
}

natjson(id: int, nil: ref Obj, nil: V, args: array of V, nil: ref Obj): V
{
	case id {
	NJparse =>
		s := strarg(args, 0);
		p := ref Jp(s, 0);
		jsonws(p);
		v := jsonvalue(p);
		jsonws(p);
		if(p.i < len s)
			jsonerr(p);
		rev := arg(args, 1);
		if(iscallable(rev)) {
			root := plainobj();
			createdata(root, intern(""), v);
			return internalize(root, intern(""), rev.o);
		}
		return v;
	NJstringify =>
		return jsonstringify(arg(args, 0), arg(args, 1), arg(args, 2));
	NJrawjson =>
		s := strarg(args, 0);
		if(s == "" || isjsonws(s[0]) || isjsonws(s[len s - 1]))
			throwerr(ESyntax, "Invalid value for JSON.rawJSON");
		p := ref Jp(s, 0);
		v := jsonvalue(p);
		if(p.i < len s || v.t == Tobj)
			throwerr(ESyntax, "Invalid value for JSON.rawJSON");
		o := newobj(Cplain, nil);
		addprop(o, intern("rawJSON"), Aenum, strv(s));
		o.flags |= Fnew;	# marks a raw JSON object
		preventext(o);
		o.flags &= ~Fext;
		return objv(o);
	NJisrawjson =>
		v := arg(args, 0);
		return boolv(v.t == Tobj && (v.o.flags & Fnew) != 0 && v.o.cls == Cplain);
	}
	return undef;
}

isjsonws(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

Jp: adt {
	s:	string;
	i:	int;
};

jsonerr(p: ref Jp)
{
	if(p.i >= len p.s)
		throwerr(ESyntax, "Unexpected end of JSON input");
	throwerr(ESyntax, sys->sprint("Unexpected token in JSON at position %d", p.i));
}

jsonws(p: ref Jp)
{
	while(p.i < len p.s && isjsonws(p.s[p.i]))
		p.i++;
}

jsonvalue(p: ref Jp): V
{
	jsonws(p);
	if(p.i >= len p.s)
		jsonerr(p);
	c := p.s[p.i];
	case c {
	'{' =>
		p.i++;
		o := plainobj();
		jsonws(p);
		if(p.i < len p.s && p.s[p.i] == '}') {
			p.i++;
			return objv(o);
		}
		for(;;) {
			jsonws(p);
			if(p.i >= len p.s || p.s[p.i] != '"')
				jsonerr(p);
			k := jsonstring(p);
			jsonws(p);
			if(p.i >= len p.s || p.s[p.i] != ':')
				jsonerr(p);
			p.i++;
			v := jsonvalue(p);
			a := intern(k);
			if(atomidx[a] == -1 && !o.sh.dict && slotof(o.sh, a) < 0)
				addprop(o, a, Adefault, v);
			else
				createdata(o, a, v);
			jsonws(p);
			if(p.i >= len p.s)
				jsonerr(p);
			if(p.s[p.i] == ',') {
				p.i++;
				continue;
			}
			if(p.s[p.i] == '}') {
				p.i++;
				return objv(o);
			}
			jsonerr(p);
		}
	'[' =>
		p.i++;
		a := newarray(0);
		jsonws(p);
		if(p.i < len p.s && p.s[p.i] == ']') {
			p.i++;
			return objv(a);
		}
		for(;;) {
			apush(a, jsonvalue(p));
			jsonws(p);
			if(p.i >= len p.s)
				jsonerr(p);
			if(p.s[p.i] == ',') {
				p.i++;
				continue;
			}
			if(p.s[p.i] == ']') {
				p.i++;
				return objv(a);
			}
			jsonerr(p);
		}
	'"' =>
		return strv(jsonstring(p));
	't' =>
		if(p.i + 4 <= len p.s && p.s[p.i:p.i+4] == "true") {
			p.i += 4;
			return truev;
		}
	'f' =>
		if(p.i + 5 <= len p.s && p.s[p.i:p.i+5] == "false") {
			p.i += 5;
			return falsev;
		}
	'n' =>
		if(p.i + 4 <= len p.s && p.s[p.i:p.i+4] == "null") {
			p.i += 4;
			return nullv;
		}
	* =>
		if(c == '-' || c >= '0' && c <= '9')
			return jsonnumber(p);
	}
	jsonerr(p);
	return undef;
}

jsonnumber(p: ref Jp): V
{
	s := p.s;
	st := p.i;
	if(p.i < len s && s[p.i] == '-')
		p.i++;
	if(p.i >= len s)
		jsonerr(p);
	if(s[p.i] == '0')
		p.i++;
	else if(s[p.i] >= '1' && s[p.i] <= '9') {
		while(p.i < len s && s[p.i] >= '0' && s[p.i] <= '9')
			p.i++;
	} else
		jsonerr(p);
	isint := 1;
	if(p.i < len s && s[p.i] == '.') {
		isint = 0;
		p.i++;
		d := p.i;
		while(p.i < len s && s[p.i] >= '0' && s[p.i] <= '9')
			p.i++;
		if(p.i == d)
			jsonerr(p);
	}
	if(p.i < len s && (s[p.i] == 'e' || s[p.i] == 'E')) {
		isint = 0;
		p.i++;
		if(p.i < len s && (s[p.i] == '+' || s[p.i] == '-'))
			p.i++;
		d := p.i;
		while(p.i < len s && s[p.i] >= '0' && s[p.i] <= '9')
			p.i++;
		if(p.i == d)
			jsonerr(p);
	}
	t := s[st:p.i];
	if(isint && len t < 10 && t != "-0")
		return numv(real int t);
	x := decimal(t);
	if(x == 0.0 && t[0] == '-')
		return V(Tnum, 0, -0.0, nil, nil);
	return numv(x);
}

jsonstring(p: ref Jp): string
{
	s := p.s;
	p.i++;
	st := p.i;
	# the common case: no escapes
	for(i := p.i; i < len s; i++) {
		c := s[i];
		if(c == '"') {
			p.i = i + 1;
			return s[st:i];
		}
		if(c == '\\' || c < 16r20)
			break;
	}
	r := s[st:i];
	p.i = i;
	for(;;) {
		if(p.i >= len s)
			jsonerr(p);
		c := s[p.i];
		if(c == '"') {
			p.i++;
			return r;
		}
		if(c < 16r20)
			jsonerr(p);
		if(c != '\\') {
			r[len r] = c;
			p.i++;
			continue;
		}
		p.i++;
		if(p.i >= len s)
			jsonerr(p);
		e := s[p.i++];
		case e {
		'"' or '\\' or '/' =>
			r[len r] = e;
		'b' =>
			r[len r] = '\b';
		'f' =>
			r[len r] = '\u000c';
		'n' =>
			r[len r] = '\n';
		'r' =>
			r[len r] = '\r';
		't' =>
			r[len r] = '\t';
		'u' =>
			if(p.i + 4 > len s)
				jsonerr(p);
			x := 0;
			for(k := 0; k < 4; k++) {
				h := hexval(s[p.i + k]);
				if(h < 0) {
					p.i += k;
					jsonerr(p);
				}
				x = x << 4 | h;
			}
			p.i += 4;
			r[len r] = x;
		* =>
			p.i--;
			jsonerr(p);
		}
	}
}

internalize(holder: ref Obj, k: int, rev: ref Obj): V
{
	v := get(holder, k, objv(holder));
	if(v.t == Tobj) {
		o := v.o;
		if(isarray(v)) {
			n := lengthof(o);
			for(i := 0.0; i < n; i += 1.0) {
				kk := realkey(i);
				nv := internalize(o, kk, rev);
				if(nv.t == Tundef)
					deleteprop(o, kk);
				else
					createdata(o, kk, nv);
			}
		} else {
			keys := enumkeys(o);
			for(i := 0; i < len keys; i++) {
				nv := internalize(o, keys[i], rev);
				if(nv.t == Tundef)
					deleteprop(o, keys[i]);
				else
					createdata(o, keys[i], nv);
			}
		}
	}
	return call(rev, objv(holder), array[] of {keyv(k), v});
}

Jst: adt {
	replacer:	ref Obj;
	plist:	array of int;	# the property list replacer's, or nil
	gap:	string;
	indent:	string;
	stack:	list of ref Obj;
};

jsonstringify(v, replacer, space: V): V
{
	st := ref Jst(nil, nil, "", "", nil);
	if(replacer.t == Tobj) {
		if(replacer.o.fun != nil)
			st.replacer = replacer.o;
		else if(isarray(replacer)) {
			seen := newhmap();
			l: list of int;
			n := 0;
			ro := replacer.o;
			m := lengthof(ro);
			for(i := 0.0; i < m; i += 1.0) {
				e := gidx(ro, i, replacer);
				item: V;
				if(isstr(e))
					item = strv(flat(e));
				else if(isnum(e))
					item = strv(tostr(e));
				else if(e.t == Tobj && (e.o.cls == Cstr || e.o.cls == Cnum))
					item = strv(tostr(e));
				else
					continue;
				if(hfind(seen, item) >= 0)
					continue;
				hset(seen, item, truev);
				l = intern(item.s) :: l;
				n++;
			}
			st.plist = array[n] of int;
			for(i2 := n - 1; i2 >= 0; i2--) {
				st.plist[i2] = hd l;
				l = tl l;
			}
		}
	}
	if(space.t == Tobj) {
		if(space.o.cls == Cnum)
			space = V(Tnum, 0, tonum(space), nil, nil);
		else if(space.o.cls == Cstr)
			space = strv(tostr(space));
	}
	if(isnum(space)) {
		k := tointeger(space);
		if(k > 10.0)
			k = 10.0;
		for(i := 0; i < int k; i++)
			st.gap[len st.gap] = ' ';
	} else if(isstr(space)) {
		g := flat(space);
		if(len g > 10)
			g = g[0:10];
		st.gap = g;
	}
	w := plainobj();
	createdata(w, intern(""), v);
	(ok, s) := serialize(st, intern(""), objv(w));
	if(!ok)
		return undef;
	return strv(s);
}

serialize(st: ref Jst, k: int, holder: V): (int, string)
{
	v := get(holder.o, k, holder);
	if(v.t == Tobj || v.t == Tbig) {
		tj := getvalue(v, a_toJSON);
		if(iscallable(tj))
			v = call(tj.o, v, array[] of {keyv(k)});
	}
	if(st.replacer != nil)
		v = call(st.replacer, holder, array[] of {keyv(k), v});
	if(v.t == Tobj) {
		case v.o.cls {
		Cnum =>
			v = V(Tnum, 0, tonum(v), nil, nil);
		Cstr =>
			v = strv(tostr(v));
		Cbool =>
			pick d := v.o.data {
			Prim =>
				v = d.v;
			}
		Cbigint =>
			pick d := v.o.data {
			Prim =>
				v = d.v;
			}
		}
	}
	case v.t {
	Tnull =>
		return (1, "null");
	Tbool =>
		if(v.i)
			return (1, "true");
		return (1, "false");
	Tstr or Trope =>
		return (1, jsonquote(flat(v)));
	Tint or Tnum =>
		x := numof(v);
		if(!isfinitenum(x))
			return (1, "null");
		return (1, tostr(v));
	Tbig =>
		throwtype("Do not know how to serialize a BigInt");
	Tobj =>
		if(v.o.fun != nil)
			return (0, nil);
		if((v.o.flags & Fnew) && v.o.cls == Cplain && v.o.sh.proto == nil)
			return (1, tostr(getv(v.o, intern("rawJSON"))));
		for(l := st.stack; l != nil; l = tl l)
			if(hd l == v.o)
				throwtype("Converting circular structure to JSON");
		if(isarray(v))
			return (1, serializearray(st, v));
		return (1, serializeobject(st, v));
	}
	return (0, nil);
}

jsonquote(s: string): string
{
	r := "\"";
	for(i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'"' =>
			r += "\\\"";
		'\\' =>
			r += "\\\\";
		'\b' =>
			r += "\\b";
		'\u000c' =>
			r += "\\f";
		'\n' =>
			r += "\\n";
		'\r' =>
			r += "\\r";
		'\t' =>
			r += "\\t";
		* =>
			if(c < 16r20 || c >= 16rD800 && c <= 16rDFFF && !pairedsurrogate(s, i)) {
				r += sys->sprint("\\u%04x", c);
			} else if(c >= 16rD800 && c <= 16rDBFF) {
				r[len r] = c;
				r[len r] = s[++i];
			} else
				r[len r] = c;
		}
	}
	return r + "\"";
}

pairedsurrogate(s: string, i: int): int
{
	c := s[i];
	if(c >= 16rD800 && c <= 16rDBFF)
		return i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF;
	return 0;
}

serializeobject(st: ref Jst, v: V): string
{
	st.stack = v.o :: st.stack;
	stepback := st.indent;
	st.indent += st.gap;
	keys: array of int;
	if(st.plist != nil)
		keys = st.plist;
	else
		keys = enumkeys(v.o);
	parts: list of string;
	n := 0;
	for(i := 0; i < len keys; i++) {
		(ok, s) := serialize(st, keys[i], v);
		if(!ok)
			continue;
		m := jsonquote(atomstr[keys[i]]) + ":";
		if(st.gap != "")
			m += " ";
		parts = (m + s) :: parts;
		n++;
	}
	r: string;
	if(n == 0)
		r = "{}";
	else
		r = "{" + joinparts(parts, n, st, stepback) + "}";
	st.stack = tl st.stack;
	st.indent = stepback;
	return r;
}

serializearray(st: ref Jst, v: V): string
{
	st.stack = v.o :: st.stack;
	stepback := st.indent;
	st.indent += st.gap;
	n := lengthof(v.o);
	parts: list of string;
	c := 0;
	for(i := 0.0; i < n; i += 1.0) {
		(ok, s) := serialize(st, realkey(i), v);
		if(!ok)
			s = "null";
		parts = s :: parts;
		c++;
	}
	r: string;
	if(c == 0)
		r = "[]";
	else
		r = "[" + joinparts(parts, c, st, stepback) + "]";
	st.stack = tl st.stack;
	st.indent = stepback;
	return r;
}

joinparts(l: list of string, n: int, st: ref Jst, stepback: string): string
{
	a := array[n] of string;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	if(st.gap == "")
		return joinsep(a, ",");
	sep := ",\n" + st.indent;
	return "\n" + st.indent + joinsep(a, sep) + "\n" + stepback;
}
