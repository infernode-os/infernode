#
# jsstring.b - String, Number, Math and JSON (ECMAScript 2025 §21,
# §22.1, §25.5).  Included by js.b.
#
# Strings are UTF-16 code units, as Limbo's 16-bit characters are.
#

# ---- String ----

stringinit()
{
	istrproto = keep(newobj(Kprim, iobjproto));
	odata[istrproto] = ref Data.Prim(strv(""));
	c := ctor("String", 1, stringctor, istrproto);
	method(c, "fromCharCode", 1, string_fromcharcode);
	method(c, "fromCodePoint", 1, string_fromcodepoint);
	method(c, "raw", 1, string_raw);
	p := istrproto;
	method(p, "at", 1, str_at);
	method(p, "charAt", 1, str_charat);
	method(p, "charCodeAt", 1, str_charcodeat);
	method(p, "codePointAt", 1, str_codepointat);
	method(p, "concat", 1, str_concat);
	method(p, "endsWith", 1, str_endswith);
	method(p, "includes", 1, str_includes);
	method(p, "indexOf", 1, str_indexof);
	method(p, "isWellFormed", 0, str_iswellformed);
	method(p, "lastIndexOf", 1, str_lastindexof);
	method(p, "localeCompare", 1, str_localecompare);
	method(p, "match", 1, str_match);
	method(p, "matchAll", 1, str_matchall);
	method(p, "normalize", 0, str_normalize);
	method(p, "padEnd", 1, str_padend);
	method(p, "padStart", 1, str_padstart);
	method(p, "repeat", 1, str_repeat);
	method(p, "replace", 2, str_replace);
	method(p, "replaceAll", 2, str_replaceall);
	method(p, "search", 1, str_search);
	method(p, "slice", 2, str_slice);
	method(p, "split", 2, str_split);
	method(p, "startsWith", 1, str_startswith);
	method(p, "substring", 2, str_substring);
	method(p, "substr", 2, str_substr);
	method(p, "toLocaleLowerCase", 0, str_tolowercase);
	method(p, "toLocaleUpperCase", 0, str_touppercase);
	method(p, "toLowerCase", 0, str_tolowercase);
	method(p, "toString", 0, str_tostring);
	method(p, "toUpperCase", 0, str_touppercase);
	method(p, "toWellFormed", 0, str_towellformed);
	method(p, "trim", 0, str_trim);
	trimstart := method(p, "trimStart", 0, str_trimstart);
	trimend := method(p, "trimEnd", 0, str_trimend);
	defown(p, intern("trimLeft"), Awrite|Aconf, objv(trimstart));
	defown(p, intern("trimRight"), Awrite|Aconf, objv(trimend));
	method(p, "valueOf", 0, str_tostring);
	symmethod(p, asymiterator, "[Symbol.iterator]", 0, str_iterator);
	# Annex B's HTML methods
	html := array[] of {
		("anchor", "a", "name"), ("big", "big", nil), ("blink", "blink", nil), ("bold", "b", nil),
		("fixed", "tt", nil), ("fontcolor", "font", "color"), ("fontsize", "font", "size"),
		("italics", "i", nil), ("link", "a", "href"), ("small", "small", nil),
		("strike", "strike", nil), ("sub", "sub", nil), ("sup", "sup", nil),
	};
	for(i := 0; i < len html; i++) {
		(nm, t, at) := html[i];
		l := 0;
		if(at != nil)
			l = 1;
		h := method(p, nm, l, str_html);
		setcap(h, array[] of {strv(t), strv(at)});
	}
	istriterproto = istriterproto;
	method(istriterproto, "next", 0, striter_next);
	tag(istriterproto, "String Iterator");
}

stringctor(nil: V, a, n: int, nt: V, nil: int): V
{
	s: V;
	if(n == 0)
		s = strv("");
	else {
		v := vs[a];
		if(nt.t == Tundef && v.t == Tsym)
			return strv("Symbol(" + atomstr[v.x] + ")");
		s = tostrv(v);
	}
	if(nt.t == Tundef)
		return s;
	h := newobj(Kprim, protofromctor(nt, istrproto));
	odata[h] = ref Data.Prim(s);
	return objv(h);
}

string_fromcharcode(nil: V, a, n: int, nil: V, nil: int): V
{
	s := "";
	for(i := 0; i < n; i++)
		s[len s] = int touint32(vs[a+i]) & 16rFFFF;
	return strv(s);
}

string_fromcodepoint(nil: V, a, n: int, nil: V, nil: int): V
{
	s := "";
	for(i := 0; i < n; i++) {
		x := tonumber(vs[a+i]);
		if(x != trunc(x) || x < 0.0 || x > 1114111.0 || isnan(x))
			throwerr(RangeError, "invalid code point " + numstr(x));
		s = jslexputcp(s, int x);
	}
	return strv(s);
}

string_raw(nil: V, a, n: int, nil: V, nil: int): V
{
	cooked := toobject(arg(a, n, 0));
	raw := objv(toobject(getv(objv(cooked), araw)));
	l := lengthof(raw);
	r := "";
	for(i := 0.0; i < l; i += 1.0) {
		r += tostring(getidx(raw, i));
		if(i + 1.0 < l && int i + 1 < n)
			r += tostring(vs[a+int i+1]);
	}
	return strv(r);
}

# the this value, as a string (RequireObjectCoercible, then ToString)
thisstr(this: V, name: string): string
{
	if(this.t == Tundef || this.t == Tnull)
		typeerr("String.prototype." + name + " called on " + show(this));
	return tostring(this);
}

str_at(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "at");
	k := tointorinf(arg(a, n, 0));
	if(k < 0.0)
		k += real len s;
	if(k < 0.0 || k >= real len s)
		return undef;
	return strv(s[int k:int k+1]);
}

str_charat(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "charAt");
	k := tointorinf(arg(a, n, 0));
	if(k < 0.0 || k >= real len s)
		return strv("");
	return strv(s[int k:int k+1]);
}

str_charcodeat(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "charCodeAt");
	k := tointorinf(arg(a, n, 0));
	if(k < 0.0 || k >= real len s)
		return num(nan);
	return num(real s[int k]);
}

str_codepointat(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "codePointAt");
	k := tointorinf(arg(a, n, 0));
	if(k < 0.0 || k >= real len s)
		return undef;
	(c, nil) := cpat(s, int k);
	return num(real c);
}

str_concat(this: V, a, n: int, nil: V, nil: int): V
{
	h := tostrh(V(Tstr, newstr(thisstr(this, "concat")), 0.0));
	for(i := 0; i < n; i++)
		h = concat(h, tostrh(vs[a+i]));
	return V(Tstr, h, 0.0);
}

isregexp(v: V): int
{
	if(v.t != Tobj)
		return 0;
	m := getv(v, asymmatch);
	if(m.t != Tundef)
		return truthy(m);
	return okind[v.x] == Kregexp;
}

str_endswith(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "endsWith");
	if(isregexp(arg(a, n, 0)))
		typeerr("first argument to String.prototype.endsWith must not be a regular expression");
	t := tostring(arg(a, n, 0));
	end := real len s;
	if(arg(a, n, 1).t != Tundef) {
		end = tointorinf(vs[a+1]);
		if(end < 0.0)
			end = 0.0;
		if(end > real len s)
			end = real len s;
	}
	st := int end - len t;
	if(st < 0)
		return vfalse;
	return bool(s[st:int end] == t);
}

str_includes(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "includes");
	if(isregexp(arg(a, n, 0)))
		typeerr("first argument to String.prototype.includes must not be a regular expression");
	t := tostring(arg(a, n, 0));
	p := clampint(tointorinf(arg(a, n, 1)), 0, len s);
	return bool(strindex(s, t, p) >= 0);
}

clampint(x: real, lo, hi: int): int
{
	if(x < real lo)
		return lo;
	if(x > real hi)
		return hi;
	return int x;
}

strindex(s, t: string, from: int): int
{
	n := len t;
	for(i := from; i + n <= len s; i++)
		if(s[i:i+n] == t)
			return i;
	return -1;
}

str_indexof(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "indexOf");
	t := tostring(arg(a, n, 0));
	p := clampint(tointorinf(arg(a, n, 1)), 0, len s);
	return num(real strindex(s, t, p));
}

str_iswellformed(this: V, nil, nil: int, nil: V, nil: int): V
{
	s := thisstr(this, "isWellFormed");
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF) {
			i++;
			continue;
		}
		if(c >= 16rD800 && c <= 16rDFFF)
			return vfalse;
	}
	return vtrue;
}

str_towellformed(this: V, nil, nil: int, nil: V, nil: int): V
{
	s := thisstr(this, "toWellFormed");
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF) {
			r[len r] = c;
			r[len r] = s[++i];
			continue;
		}
		if(c >= 16rD800 && c <= 16rDFFF)
			c = 16rFFFD;
		r[len r] = c;
	}
	return strv(r);
}

str_lastindexof(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "lastIndexOf");
	t := tostring(arg(a, n, 0));
	x := tonumber(arg(a, n, 1));
	p := len s;
	if(!isnan(x))
		p = clampint(trunc(x), 0, len s);
	if(p > len s - len t)
		p = len s - len t;
	for(i := p; i >= 0; i--)
		if(s[i:i+len t] == t)
			return num(real i);
	return num(-1.0);
}

str_localecompare(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "localeCompare");
	t := tostring(arg(a, n, 0));
	if(s < t)
		return num(-1.0);
	if(s > t)
		return num(1.0);
	return num(0.0);
}

# match, matchAll, replace, search, split: by the argument's @@ method when it has one
bysymbol(this: V, a, n: int, sym: int, name: string): (int, V)
{
	if(this.t == Tundef || this.t == Tnull)
		typeerr("String.prototype." + name + " called on " + show(this));
	r := arg(a, n, 0);
	if(r.t != Tundef && r.t != Tnull) {
		m := getmethod(r, sym);
		if(m.t != Tundef) {
			args := array[n] of V;
			args[0:] = vs[a:a+n];
			args[0] = this;
			if(n > 1)
				return (1, call(m, r, array[] of {this, vs[a+1]}));
			return (1, call(m, r, array[] of {this}));
		}
	}
	return (0, undef);
}

str_match(this: V, a, n: int, nil: V, nil: int): V
{
	(done, v) := bysymbol(this, a, n, asymmatch, "match");
	if(done)
		return v;
	s := tostrv(this);
	rx := regexpcreatefrom(arg(a, n, 0), undef);
	return invoke(objv(rx), asymmatch, array[] of {s});
}

str_matchall(this: V, a, n: int, nil: V, nil: int): V
{
	r := arg(a, n, 0);
	if(this.t == Tundef || this.t == Tnull)
		typeerr("String.prototype.matchAll called on " + show(this));
	if(r.t != Tundef && r.t != Tnull) {
		if(isregexp(r)) {
			fl := getv(r, aflags);
			if(fl.t == Tundef || fl.t == Tnull)
				typeerr("flags is null or undefined");
			if(strindex(tostring(fl), "g", 0) < 0)
				typeerr("String.prototype.matchAll called with a non-global RegExp argument");
		}
	}
	(done, v) := bysymbol(this, a, n, asymmatchall, "matchAll");
	if(done)
		return v;
	s := tostrv(this);
	rx := regexpcreatefrom(r, strv("g"));
	return invoke(objv(rx), asymmatchall, array[] of {s});
}

str_normalize(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "normalize");
	f := "NFC";
	if(arg(a, n, 0).t != Tundef)
		f = tostring(vs[a]);
	case f {
	"NFC" or "NFD" or "NFKC" or "NFKD" =>
		;
	* =>
		throwerr(RangeError, "the normalization form should be one of NFC, NFD, NFKC, NFKD");
	}
	return strv(normalize(s, f));
}

pad(this: V, a, n: int, start: int, name: string): V
{
	s := thisstr(this, name);
	ml := tolength(arg(a, n, 0));
	if(ml <= real len s)
		return strv(s);
	fill := " ";
	if(arg(a, n, 1).t != Tundef)
		fill = tostring(vs[a+1]);
	if(fill == "")
		return strv(s);
	if(ml > real Strmax)
		throwerr(RangeError, "invalid string length");
	need := int ml - len s;
	f := "";
	while(len f < need)
		f += fill;
	f = f[0:need];
	if(start)
		return strv(f + s);
	return strv(s + f);
}

str_padend(this: V, a, n: int, nil: V, nil: int): V { return pad(this, a, n, 0, "padEnd"); }
str_padstart(this: V, a, n: int, nil: V, nil: int): V { return pad(this, a, n, 1, "padStart"); }

str_repeat(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "repeat");
	c := tointorinf(arg(a, n, 0));
	if(c < 0.0 || c == inf)
		throwerr(RangeError, "invalid count value: " + numstr(c));
	if(c == 0.0 || s == "")
		return strv("");
	if(c * real len s > real Strmax)
		throwerr(RangeError, "invalid string length");
	r := "";
	t := s;
	k := int c;
	while(k > 0) {
		if(k & 1)
			r += t;
		k >>= 1;
		if(k > 0)
			t += t;
	}
	return strv(r);
}

# GetSubstitution (§22.1.3.19.1): replacement's $ patterns
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
			v := getv(groups, strkey(gname));
			if(v.t != Tundef)
				r += tostring(v);
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
				r += tostring(v);
			i += 1 + two;
		* =>
			r[len r] = '$';
		}
	}
	return r;
}

replace(this: V, a, n: int, all: int, name: string): V
{
	if(this.t == Tundef || this.t == Tnull)
		typeerr("String.prototype." + name + " called on " + show(this));
	sv := arg(a, n, 0);
	rv := arg(a, n, 1);
	if(sv.t != Tundef && sv.t != Tnull) {
		if(all && isregexp(sv)) {
			fl := getv(sv, aflags);
			if(fl.t == Tundef || fl.t == Tnull)
				typeerr("flags is null or undefined");
			if(strindex(tostring(fl), "g", 0) < 0)
				typeerr("replaceAll must be called with a global RegExp");
		}
		m := getmethod(sv, asymreplace);
		if(m.t != Tundef)
			return call(m, sv, array[] of {this, rv});
	}
	s := tostring(this);
	t := tostring(sv);
	fnrepl := iscallable(rv);
	repl := "";
	if(!fnrepl)
		repl = tostring(rv);
	adv := len t;
	if(adv == 0)
		adv = 1;
	positions: list of int;
	p := strindex(s, t, 0);
	while(p >= 0) {
		positions = p :: positions;
		if(!all)
			break;
		p = strindex(s, t, p + adv);
		if(len t == 0 && p > len s)
			break;
	}
	ps := revl(positions);
	r := "";
	end := 0;
	for(; ps != nil; ps = tl ps) {
		pos := hd ps;
		r += s[end:pos];
		if(fnrepl)
			r += tostring(call(rv, undef, array[] of {strv(t), num(real pos), strv(s)}));
		else
			r += substitution(t, s, pos, nil, undef, repl);
		end = pos + len t;
	}
	if(end < len s)
		r += s[end:];
	return strv(r);
}

str_replace(this: V, a, n: int, nil: V, nil: int): V { return replace(this, a, n, 0, "replace"); }
str_replaceall(this: V, a, n: int, nil: V, nil: int): V { return replace(this, a, n, 1, "replaceAll"); }

str_search(this: V, a, n: int, nil: V, nil: int): V
{
	(done, v) := bysymbol(this, a, n, asymsearch, "search");
	if(done)
		return v;
	s := tostrv(this);
	rx := regexpcreatefrom(arg(a, n, 0), undef);
	return invoke(objv(rx), asymsearch, array[] of {s});
}

str_slice(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "slice");
	l := real len s;
	from := relidx(arg(a, n, 0), l, 0.0);
	end := relidx(arg(a, n, 1), l, l);
	if(from >= end)
		return strv("");
	return strv(s[int from:int end]);
}

str_split(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t == Tundef || this.t == Tnull)
		typeerr("String.prototype.split called on " + show(this));
	sepv := arg(a, n, 0);
	limv := arg(a, n, 1);
	if(sepv.t != Tundef && sepv.t != Tnull) {
		m := getmethod(sepv, asymsplit);
		if(m.t != Tundef)
			return call(m, sepv, array[] of {this, limv});
	}
	s := tostring(this);
	lim := 4294967295.0;
	if(limv.t != Tundef)
		lim = touint32(limv);
	sep := tostring(sepv);
	r := newarray(0);
	if(lim == 0.0)
		return objv(r);
	if(sepv.t == Tundef) {
		arrpush(r, strv(s));
		return objv(r);
	}
	if(len s == 0) {
		if(len sep != 0)
			arrpush(r, strv(s));
		return objv(r);
	}
	if(len sep == 0) {
		for(i := 0; i < len s && real i < lim; i++)
			arrpush(r, strv(s[i:i+1]));
		return objv(r);
	}
	p := 0;
	for(q := strindex(s, sep, 0); q >= 0; q = strindex(s, sep, p)) {
		arrpush(r, strv(s[p:q]));
		if(oalen[r] >= lim)
			return objv(r);
		p = q + len sep;
	}
	arrpush(r, strv(s[p:]));
	return objv(r);
}

str_startswith(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "startsWith");
	if(isregexp(arg(a, n, 0)))
		typeerr("first argument to String.prototype.startsWith must not be a regular expression");
	t := tostring(arg(a, n, 0));
	p := clampint(tointorinf(arg(a, n, 1)), 0, len s);
	if(p + len t > len s)
		return vfalse;
	return bool(s[p:p+len t] == t);
}

str_substring(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "substring");
	st := clampint(tointorinf(arg(a, n, 0)), 0, len s);
	end := len s;
	if(arg(a, n, 1).t != Tundef)
		end = clampint(tointorinf(vs[a+1]), 0, len s);
	if(st > end)
		(st, end) = (end, st);
	return strv(s[st:end]);
}

str_substr(this: V, a, n: int, nil: V, nil: int): V
{
	s := thisstr(this, "substr");
	l := real len s;
	st := relidx(arg(a, n, 0), l, 0.0);
	c := l - st;
	if(arg(a, n, 1).t != Tundef) {
		c = tointorinf(vs[a+1]);
		if(c < 0.0)
			c = 0.0;
		if(c > l - st)
			c = l - st;
	}
	if(c <= 0.0)
		return strv("");
	return strv(s[int st:int (st + c)]);
}

str_tolowercase(this: V, nil, nil: int, nil: V, nil: int): V
{
	return strv(jsre->casemap(thisstr(this, "toLowerCase"), 0));
}

str_touppercase(this: V, nil, nil: int, nil: V, nil: int): V
{
	return strv(jsre->casemap(thisstr(this, "toUpperCase"), 1));
}

str_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	return thisprim(this, Tstr, "String.prototype.toString");
}

str_trim(this: V, nil, nil: int, nil: V, nil: int): V { return strv(trimws(thisstr(this, "trim"), 1, 1)); }
str_trimstart(this: V, nil, nil: int, nil: V, nil: int): V { return strv(trimws(thisstr(this, "trimStart"), 1, 0)); }
str_trimend(this: V, nil, nil: int, nil: V, nil: int): V { return strv(trimws(thisstr(this, "trimEnd"), 0, 1)); }

str_html(this: V, a, n: int, nil: V, f: int): V
{
	s := thisstr(this, "html method");
	t := str(capof(f, 0).x);
	at := str(capof(f, 1).x);
	r := "<" + t;
	if(at != "") {
		v := tostring(arg(a, n, 0));
		q := "";
		for(i := 0; i < len v; i++)
			if(v[i] == '"')
				q += "&quot;";
			else
				q[len q] = v[i];
		r += " " + at + "=\"" + q + "\"";
	}
	return strv(r + ">" + s + "</" + t + ">");
}

str_iterator(this: V, nil, nil: int, nil: V, nil: int): V
{
	s := thisstr(this, "[Symbol.iterator]");
	h := newobj(Kiter, istriterproto);
	odata[h] = ref Data.Iter(10, strv(s), 0, 0);
	return objv(h);
}

striter_next(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t != Tobj || okind[this.x] != Kiter)
		typeerr("next method called on incompatible receiver " + show(this));
	pick d := odata[this.x] {
	Iter =>
		if(d.kind != 10)
			typeerr("next method called on incompatible receiver");
		if(d.done)
			return iterresult(undef, 1);
		s := str(d.target.x);
		if(d.i >= len s) {
			d.done = 1;
			return iterresult(undef, 1);
		}
		(nil, w) := cpat(s, d.i);
		r := s[d.i:d.i+w];
		d.i += w;
		return iterresult(strv(r), 0);
	}
	return undef;
}

# ---- case mapping (the common scripts; full tables to come) ----

tolower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 'A' && c <= 'Z' || c >= 16rC0 && c <= 16rDE && c != 16rD7)
			c += 32;
		else if(c >= 16r391 && c <= 16r3AB && c != 16r3A2)
			c += 32;
		else if(c >= 16r410 && c <= 16r42F)
			c += 32;
		else if(c >= 16r400 && c <= 16r40F)
			c += 80;
		else if(c >= 16r100 && c <= 16r17F && (c & 1) == 0 && c != 16r130 && c != 16r138)
			c += 1;
		else if(c == 16r130) {
			r += "i̇";
			continue;
		}
		r[len r] = c;
	}
	return r;
}

toupper(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 'a' && c <= 'z' || c >= 16rE0 && c <= 16rFE && c != 16rF7)
			c -= 32;
		else if(c == 16rDF) {
			r += "SS";
			continue;
		} else if(c == 16rFF)
			c = 16r178;
		else if(c == 16rB5)
			c = 16r39C;
		else if(c >= 16r3B1 && c <= 16r3CB && c != 16r3C2)
			c -= 32;
		else if(c == 16r3C2)
			c = 16r3A3;
		else if(c >= 16r430 && c <= 16r44F)
			c -= 32;
		else if(c >= 16r450 && c <= 16r45F)
			c -= 80;
		else if(c >= 16r100 && c <= 16r17F && (c & 1) == 1 && c != 16r131 && c != 16r149 && c != 16r17F)
			c -= 1;
		r[len r] = c;
	}
	return r;
}

normalize(s: string, nil: string): string
{
	return s;
}

# ---- Number ----

numberinit()
{
	inumproto = keep(newobj(Kprim, iobjproto));
	odata[inumproto] = ref Data.Prim(num(0.0));
	c := ctor("Number", 1, numberctor, inumproto);
	defown(c, intern("EPSILON"), 0, num(2.220446049250313e-16));
	defown(c, intern("MAX_SAFE_INTEGER"), 0, num(9007199254740991.0));
	defown(c, intern("MIN_SAFE_INTEGER"), 0, num(-9007199254740991.0));
	defown(c, intern("MAX_VALUE"), 0, num(1.7976931348623157e308));
	defown(c, intern("MIN_VALUE"), 0, num(math->bits64real(big 1)));
	defown(c, intern("NaN"), 0, num(nan));
	defown(c, intern("NEGATIVE_INFINITY"), 0, num(-inf));
	defown(c, intern("POSITIVE_INFINITY"), 0, num(inf));
	method(c, "isFinite", 1, number_isfinite);
	method(c, "isInteger", 1, number_isinteger);
	method(c, "isNaN", 1, number_isnan);
	method(c, "isSafeInteger", 1, number_issafeinteger);
	defown(c, intern("parseFloat"), Awrite|Aconf, get(iglobal, intern("parseFloat"), objv(iglobal)));
	defown(c, intern("parseInt"), Awrite|Aconf, get(iglobal, intern("parseInt"), objv(iglobal)));
	p := inumproto;
	method(p, "toExponential", 1, num_toexponential);
	method(p, "toFixed", 1, num_tofixed);
	method(p, "toLocaleString", 0, num_tolocalestring);
	method(p, "toPrecision", 1, num_toprecision);
	method(p, "toString", 1, num_tostring);
	method(p, "valueOf", 0, num_valueof);
}

numberctor(nil: V, a, n: int, nt: V, nil: int): V
{
	x := 0.0;
	if(n > 0) {
		p := tonumeric(vs[a]);
		if(p.t == Tbig)
			x = bignum(p);
		else
			x = p.n;
	}
	if(nt.t == Tundef)
		return num(x);
	h := newobj(Kprim, protofromctor(nt, inumproto));
	odata[h] = ref Data.Prim(num(x));
	return objv(h);
}

isfinitenum(x: real): int
{
	return !isnan(x) && x != inf && x != -inf;
}

number_isfinite(nil: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	return bool(v.t == Tnum && isfinitenum(v.n));
}

number_isinteger(nil: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	return bool(v.t == Tnum && isfinitenum(v.n) && trunc(v.n) == v.n);
}

number_isnan(nil: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	return bool(v.t == Tnum && isnan(v.n));
}

number_issafeinteger(nil: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	return bool(v.t == Tnum && isfinitenum(v.n) && trunc(v.n) == v.n && v.n <= 9007199254740991.0 && v.n >= -9007199254740991.0);
}

thisnum(this: V, name: string): real
{
	return thisprim(this, Tnum, "Number.prototype." + name).n;
}

num_valueof(this: V, nil, nil: int, nil: V, nil: int): V
{
	return num(thisnum(this, "valueOf"));
}

num_tolocalestring(this: V, nil, nil: int, nil: V, nil: int): V
{
	return strv(numstr(thisnum(this, "toLocaleString")));
}

num_tostring(this: V, a, n: int, nil: V, nil: int): V
{
	x := thisnum(this, "toString");
	r := 10;
	if(arg(a, n, 0).t != Tundef) {
		rx := tointorinf(vs[a]);
		if(rx < 2.0 || rx > 36.0)
			throwerr(RangeError, "toString() radix must be between 2 and 36");
		r = int rx;
	}
	if(r == 10)
		return strv(numstr(x));
	return strv(radixstr(x, r));
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
		# enough digits to tell x apart: 52 bits' worth
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

num_tofixed(this: V, a, n: int, nil: V, nil: int): V
{
	x := thisnum(this, "toFixed");
	fd := tointorinf(arg(a, n, 0));
	if(fd < 0.0 || fd > 100.0 || fd == inf || fd == -inf)
		throwerr(RangeError, "toFixed() digits argument must be between 0 and 100");
	if(isnan(x))
		return strv("NaN");
	if(x >= 1e21 || x <= -1e21)
		return strv(numstr(x));
	f := int fd;
	neg := x < 0.0;
	if(neg)
		x = -x;
	s := roundhalfup(sys->sprint("%.*f", f, x), sys->sprint("%.*f", f + 30, x), f);
	if(neg && x != 0.0 && !allzero(s))
		s = "-" + s;
	return strv(s);
}

allzero(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] != '0' && s[i] != '.')
			return 0;
	return 1;
}

# printf rounds an exact tie to even; JavaScript takes the larger
# value.  short is x to f places, long the same to f+30: if the
# discarded digits are exactly 5 then zeros, round short up.
roundhalfup(short, long: string, f: int): string
{
	p := strindex(long, ".", 0);
	if(p < 0)
		return short;
	rest := long[p+1+f:];
	if(len rest == 0 || rest[0] != '5')
		return short;
	for(i := 1; i < len rest; i++)
		if(rest[i] != '0')
			return short;
	# the long form's digits up to f, plus one in the last place
	head := long[0:p+1+f];
	if(f == 0)
		head = long[0:p];
	if(short != head)
		return short;	# printf rounded up already
	return decinc(head);
}

# add one in the last place of a decimal string ("1.99" to "2.00")
decinc(s: string): string
{
	r := s;
	i := len r - 1;
	for(; i >= 0; i--) {
		if(r[i] == '.')
			continue;
		if(r[i] == '9') {
			r[i] = '0';
			continue;
		}
		r[i]++;
		return r;
	}
	return "1" + r;
}

num_toexponential(this: V, a, n: int, nil: V, nil: int): V
{
	x := thisnum(this, "toExponential");
	fv := arg(a, n, 0);
	fd := tointorinf(fv);
	if(!isfinitenum(x))
		return strv(numstr(x));
	if(fd < 0.0 || fd > 100.0)
		throwerr(RangeError, "toExponential() argument must be between 0 and 100");
	neg := x < 0.0;
	if(neg)
		x = -x;
	s: string;
	if(fv.t == Tundef) {
		# as many digits as it takes
		ns := numstr(x);
		(d, e) := digitsexp(x, ns);
		s = d[0:1];
		if(len d > 1)
			s += "." + d[1:];
		s += expsuffix(e);
	} else {
		f := int fd;
		s = sys->sprint("%.*e", f, x);
		s = fixexp(roundexp(s, x, f));
	}
	if(neg)
		s = "-" + s;
	return strv(s);
}

# a number's significant digits and exponent, from its shortest form
digitsexp(x: real, nil: string): (string, int)
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

# C's exponent form ("1.5e+07") to JavaScript's ("1.5e+7")
fixexp(s: string): string
{
	p := strindex(s, "e", 0);
	if(p < 0)
		return s;
	(nil, e) := splitexp(s);
	return s[0:p] + expsuffix(e);
}

# round an exact tie in %.*e upward, as JavaScript does
roundexp(s: string, x: real, f: int): string
{
	long := sys->sprint("%.*e", f + 30, x);
	(ld, le) := splitexp(long);
	(sd, se) := splitexp(s);
	if(le != se)
		return s;
	rest := ld[f+1:];
	if(len rest == 0 || rest[0] != '5')
		return s;
	for(i := 1; i < len rest; i++)
		if(rest[i] != '0')
			return s;
	if(sd != ld[0:f+1])
		return s;
	inc := decinc(sd);
	e := le;
	if(len inc > len sd) {
		inc = inc[0:len sd];
		e++;
	}
	r := inc[0:1];
	if(f > 0)
		r += "." + inc[1:];
	return r + "e" + expsuffix(e)[1:];
}

num_toprecision(this: V, a, n: int, nil: V, nil: int): V
{
	x := thisnum(this, "toPrecision");
	pv := arg(a, n, 0);
	if(pv.t == Tundef)
		return strv(numstr(x));
	p := tointorinf(pv);
	if(!isfinitenum(x))
		return strv(numstr(x));
	if(p < 1.0 || p > 100.0)
		throwerr(RangeError, "toPrecision() argument must be between 1 and 100");
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
		es := roundexp(sys->sprint("%.*e", ip - 1, x), x, ip - 1);
		(d, e) := splitexp(es);
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

# ---- Math ----

mathinit()
{
	m := newplain();
	keep(m);
	defown(iglobal, intern("Math"), Awrite|Aconf, objv(m));
	tag(m, "Math");
	consts := array[] of {
		("E", 2.718281828459045), ("LN10", 2.302585092994046), ("LN2", 0.6931471805599453),
		("LOG10E", 0.4342944819032518), ("LOG2E", 1.4426950408889634), ("PI", 3.141592653589793),
		("SQRT1_2", 0.7071067811865476), ("SQRT2", 1.4142135623730951),
	};
	for(i := 0; i < len consts; i++) {
		(nm, v) := consts[i];
		defown(m, intern(nm), 0, num(v));
	}
	fns := array[] of {
		("abs", 1), ("acos", 1), ("acosh", 1), ("asin", 1), ("asinh", 1), ("atan", 1), ("atanh", 1),
		("cbrt", 1), ("ceil", 1), ("cos", 1), ("cosh", 1), ("exp", 1), ("expm1", 1), ("floor", 1),
		("fround", 1), ("log", 1), ("log1p", 1), ("log10", 1), ("log2", 1), ("round", 1), ("sign", 1),
		("sin", 1), ("sinh", 1), ("sqrt", 1), ("tan", 1), ("tanh", 1), ("trunc", 1), ("clz32", 1),
		("f16round", 1),
	};
	for(i = 0; i < len fns; i++) {
		(nm, l) := fns[i];
		h := method(m, nm, l, math1);
		setcap(h, array[] of {num(real i)});
	}
	method(m, "atan2", 2, math_atan2);
	method(m, "hypot", 2, math_hypot);
	method(m, "imul", 2, math_imul);
	method(m, "max", 2, math_max);
	method(m, "min", 2, math_min);
	method(m, "pow", 2, math_pow);
	method(m, "random", 0, math_random);
	method(m, "sumPrecise", 1, math_sumprecise);
}

math1(nil: V, a, n: int, nil: V, f: int): V
{
	x := tonumber(arg(a, n, 0));
	which := int capof(f, 0).n;
	case which {
	0 => return num(math->fabs(x));
	1 => return num(math->acos(x));
	2 => return num(math->acosh(x));
	3 => return num(math->asin(x));
	4 =>
		if(x == 0.0)
			return num(x);
		return num(math->asinh(x));
	5 => return num(math->atan(x));
	6 =>
		if(x == 0.0)
			return num(x);
		return num(math->atanh(x));
	7 => return num(math->cbrt(x));
	8 => return num(math->ceil(x));
	9 => return num(math->cos(x));
	10 => return num(math->cosh(x));
	11 => return num(math->exp(x));
	12 =>
		if(x == 0.0)
			return num(x);
		return num(math->expm1(x));
	13 => return num(math->floor(x));
	14 =>
		if(isnan(x) || x == 0.0 || !isfinitenum(x))
			return num(x);
		return num(math->bits32real(math->realbits32(x)));
	15 => return num(math->log(x));
	16 =>
		if(x == 0.0)
			return num(x);
		return num(math->log1p(x));
	17 => return num(math->log10(x));
	18 =>
		if(x > 0.0 && isfinitenum(x)) {
			e := math->ilogb(x);
			if(math->scalbn(1.0, e) == x)
				return num(real e);
		}
		return num(math->log(x) / math->log(2.0));
	19 =>
		if(isnan(x) || x == 0.0 || !isfinitenum(x))
			return num(x);
		if(x > 0.0 && x < 0.5)
			return num(0.0);
		if(x < 0.0 && x >= -0.5)
			return num(-0.0);
		fl := math->floor(x);
		if(x - fl >= 0.5)
			return num(fl + 1.0);
		return num(fl);
	20 =>
		if(isnan(x) || x == 0.0)
			return num(x);
		if(x > 0.0)
			return num(1.0);
		return num(-1.0);
	21 => return num(math->sin(x));
	22 =>
		if(x == 0.0)
			return num(x);
		return num(math->sinh(x));
	23 => return num(math->sqrt(x));
	24 => return num(math->tan(x));
	25 =>
		if(x == 0.0)
			return num(x);
		return num(math->tanh(x));
	26 =>
		if(isnan(x) || !isfinitenum(x))
			return num(x);
		t := trunc(x);
		if(t == 0.0 && signbit(x))
			return num(-0.0);
		return num(t);
	27 =>
		u := touint32(num(x));
		if(u == 0.0)
			return num(32.0);
		c := 0;
		while(u < 2147483648.0) {
			u *= 2.0;
			c++;
		}
		return num(real c);
	28 =>
		return num(f16round(x));
	}
	return num(nan);
}

# round to the nearest binary16 value (ties to even), as a double
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
		q := math->scalbn(1.0, e - 10);	# the spacing of binary16 values here
		r = math->rint(x / q) * q;
	}
	if(neg)
		return -r;
	return r;
}

math_atan2(nil: V, a, n: int, nil: V, nil: int): V
{
	y := tonumber(arg(a, n, 0));
	x := tonumber(arg(a, n, 1));
	return num(math->atan2(y, x));
}

math_hypot(nil: V, a, n: int, nil: V, nil: int): V
{
	xs := array[n] of real;
	for(i := 0; i < n; i++)
		xs[i] = tonumber(vs[a+i]);
	isinf := 0;
	hasnan := 0;
	for(i = 0; i < n; i++) {
		if(xs[i] == inf || xs[i] == -inf)
			isinf = 1;
		if(isnan(xs[i]))
			hasnan = 1;
	}
	if(isinf)
		return num(inf);
	if(hasnan)
		return num(nan);
	m := 0.0;
	for(i = 0; i < n; i++)
		if(math->fabs(xs[i]) > m)
			m = math->fabs(xs[i]);
	if(m == 0.0)
		return num(0.0);
	s := 0.0;
	for(i = 0; i < n; i++) {
		y := xs[i] / m;
		s += y * y;
	}
	return num(m * math->sqrt(s));
}

math_imul(nil: V, a, n: int, nil: V, nil: int): V
{
	x := big toint32(arg(a, n, 0));
	y := big toint32(arg(a, n, 1));
	p := (x * y) & big 16rFFFFFFFF;
	return num(real int32(real p));
}

minmax(a, n: int, ismax: int): V
{
	r := -inf;
	if(!ismax)
		r = inf;
	isnanr := 0;
	for(i := 0; i < n; i++) {
		x := tonumber(vs[a+i]);
		if(isnan(x))
			isnanr = 1;
		if(ismax) {
			if(x > r || x == 0.0 && r == 0.0 && !signbit(x))
				r = x;
		} else {
			if(x < r || x == 0.0 && r == 0.0 && signbit(x))
				r = x;
		}
	}
	if(isnanr)
		return num(nan);
	return num(r);
}

math_max(nil: V, a, n: int, nil: V, nil: int): V { return minmax(a, n, 1); }
math_min(nil: V, a, n: int, nil: V, nil: int): V { return minmax(a, n, 0); }

math_pow(nil: V, a, n: int, nil: V, nil: int): V
{
	return num(jspow(tonumber(arg(a, n, 0)), tonumber(arg(a, n, 1))));
}

rngstate := big 16r2545F4914F6CDD1D;

math_random(nil: V, nil, nil: int, nil: V, nil: int): V
{
	if(rngstate == big 16r2545F4914F6CDD1D)
		rngstate ^= big sys->millisec();
	# xorshift64
	rngstate ^= rngstate << 13;
	rngstate ^= (rngstate >> 7) & big 16r01FFFFFFFFFFFFFF;
	rngstate ^= rngstate << 17;
	v := (rngstate >> 11) & big 16r1FFFFFFFFFFFFF;
	return num(real v / 9007199254740992.0);
}

math_sumprecise(nil: V, a, n: int, nil: V, nil: int): V
{
	items := arg(a, n, 0);
	(it, next) := getiterator(items, 0);
	sp0 := sp;
	push(it);
	push(next);
	vals: list of real;
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		if(v.t != Tnum) {
			saved := thrown;
			{
				iterclose(it);
			} exception {
			"js:throw" =>
				;
			}
			thrown = saved;
			typeerr("Math.sumPrecise requires numbers");
		}
		vals = v.n :: vals;
	}
	sp = sp0;
	# Neumaier's compensated sum (exact for most inputs)
	s := -0.0;
	c := 0.0;
	posinf := 0;
	neginf := 0;
	for(; vals != nil; vals = tl vals) {
		x := hd vals;
		if(isnan(x))
			return num(nan);
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
	if(posinf && neginf)
		return num(nan);
	if(posinf)
		return num(inf);
	if(neginf)
		return num(-inf);
	return num(s + c);
}

# ---- JSON ----

jsoninit()
{
	j := newplain();
	keep(j);
	defown(iglobal, intern("JSON"), Awrite|Aconf, objv(j));
	tag(j, "JSON");
	method(j, "parse", 2, json_parse);
	method(j, "stringify", 3, json_stringify);
	method(j, "rawJSON", 1, json_rawjson);
	method(j, "isRawJSON", 1, json_israwjson);
}

Jp: adt {
	s:	string;
	i:	int;
};

json_parse(nil: V, a, n: int, nil: V, nil: int): V
{
	s := tostring(arg(a, n, 0));
	p := ref Jp(s, 0);
	jsonws(p);
	v := jsonvalue(p);
	jsonws(p);
	if(p.i < len s)
		jsonerr(p);
	rev := arg(a, n, 1);
	if(iscallable(rev)) {
		root := newplain();
		createdata(root, intern(""), v);
		sp0 := sp;
		push(objv(root));
		r := internalize(objv(root), intern(""), rev);
		sp = sp0;
		return r;
	}
	return v;
}

jsonerr(p: ref Jp)
{
	if(p.i >= len p.s)
		throwerr(SyntaxError, "unexpected end of JSON input");
	throwerr(SyntaxError, sys->sprint("unexpected character in JSON at position %d", p.i));
}

jsonws(p: ref Jp)
{
	while(p.i < len p.s) {
		case p.s[p.i] {
		' ' or '\t' or '\n' or '\r' =>
			p.i++;
		* =>
			return;
		}
	}
}

jsonvalue(p: ref Jp): V
{
	if(p.i >= len p.s)
		jsonerr(p);
	c := p.s[p.i];
	case c {
	'{' =>
		p.i++;
		h := newplain();
		sp0 := sp;
		push(objv(h));
		jsonws(p);
		if(p.i < len p.s && p.s[p.i] == '}') {
			p.i++;
			sp = sp0;
			return objv(h);
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
			jsonws(p);
			v := jsonvalue(p);
			createdata(h, strkey(k), v);
			jsonws(p);
			if(p.i < len p.s && p.s[p.i] == ',') {
				p.i++;
				continue;
			}
			if(p.i < len p.s && p.s[p.i] == '}') {
				p.i++;
				break;
			}
			jsonerr(p);
		}
		sp = sp0;
		return objv(h);
	'[' =>
		p.i++;
		h := newarray(0);
		sp0 := sp;
		push(objv(h));
		jsonws(p);
		if(p.i < len p.s && p.s[p.i] == ']') {
			p.i++;
			sp = sp0;
			return objv(h);
		}
		for(;;) {
			jsonws(p);
			arrpush(h, jsonvalue(p));
			jsonws(p);
			if(p.i < len p.s && p.s[p.i] == ',') {
				p.i++;
				continue;
			}
			if(p.i < len p.s && p.s[p.i] == ']') {
				p.i++;
				break;
			}
			jsonerr(p);
		}
		sp = sp0;
		return objv(h);
	'"' =>
		return strv(jsonstring(p));
	't' =>
		if(p.i + 4 <= len p.s && p.s[p.i:p.i+4] == "true") {
			p.i += 4;
			return vtrue;
		}
	'f' =>
		if(p.i + 5 <= len p.s && p.s[p.i:p.i+5] == "false") {
			p.i += 5;
			return vfalse;
		}
	'n' =>
		if(p.i + 4 <= len p.s && p.s[p.i:p.i+4] == "null") {
			p.i += 4;
			return null;
		}
	'-' or '0' to '9' =>
		return num(jsonnumber(p));
	}
	jsonerr(p);
	return undef;
}

jsonnumber(p: ref Jp): real
{
	s := p.s;
	st := p.i;
	if(s[p.i] == '-')
		p.i++;
	if(p.i >= len s)
		jsonerr(p);
	if(s[p.i] == '0')
		p.i++;
	else if(s[p.i] >= '1' && s[p.i] <= '9')
		while(p.i < len s && s[p.i] >= '0' && s[p.i] <= '9')
			p.i++;
	else
		jsonerr(p);
	if(p.i < len s && s[p.i] == '.') {
		p.i++;
		if(p.i >= len s || s[p.i] < '0' || s[p.i] > '9')
			jsonerr(p);
		while(p.i < len s && s[p.i] >= '0' && s[p.i] <= '9')
			p.i++;
	}
	if(p.i < len s && (s[p.i] == 'e' || s[p.i] == 'E')) {
		p.i++;
		if(p.i < len s && (s[p.i] == '+' || s[p.i] == '-'))
			p.i++;
		if(p.i >= len s || s[p.i] < '0' || s[p.i] > '9')
			jsonerr(p);
		while(p.i < len s && s[p.i] >= '0' && s[p.i] <= '9')
			p.i++;
	}
	return decimal(s[st:p.i]);
}

jsonstring(p: ref Jp): string
{
	s := p.s;
	p.i++;
	r := "";
	for(;;) {
		if(p.i >= len s)
			jsonerr(p);
		c := s[p.i++];
		if(c == '"')
			return r;
		if(c < 16r20) {
			p.i--;
			jsonerr(p);
		}
		if(c != '\\') {
			r[len r] = c;
			continue;
		}
		if(p.i >= len s)
			jsonerr(p);
		e := s[p.i++];
		case e {
		'"' => r[len r] = '"';
		'\\' => r[len r] = '\\';
		'/' => r[len r] = '/';
		'b' => r[len r] = 8;
		'f' => r[len r] = 12;
		'n' => r[len r] = '\n';
		'r' => r[len r] = '\r';
		't' => r[len r] = '\t';
		'u' =>
			if(p.i + 4 > len s)
				jsonerr(p);
			v := 0;
			for(k := 0; k < 4; k++) {
				h := hexv(s[p.i+k]);
				if(h < 0) {
					p.i += k;
					jsonerr(p);
				}
				v = v * 16 + h;
			}
			p.i += 4;
			r[len r] = v;
		* =>
			p.i--;
			jsonerr(p);
		}
	}
}

internalize(holder: V, k: int, rev: V): V
{
	v := get(holder.x, k, holder);
	if(v.t == Tobj) {
		sp0 := sp;
		push(v);
		if(isarray(v)) {
			l := lengthof(v);
			for(i := 0.0; i < l; i += 1.0) {
				nv := internalize(v, idxk(i), rev);
				if(nv.t == Tundef)
					delete(v.x, idxk(i));
				else
					createdata(v.x, idxk(i), nv);
			}
		} else {
			ks := ownkeys(v.x);
			for(i := 0; i < len ks; i++) {
				if(issymkey(ks[i]) || isprivkey(ks[i]))
					continue;
				(found, d) := getown(v.x, ks[i]);
				if(!found || (d.attrs & Aenum) == 0)
					continue;
				nv := internalize(v, ks[i], rev);
				if(nv.t == Tundef)
					delete(v.x, ks[i]);
				else
					createdata(v.x, ks[i], nv);
			}
		}
		sp = sp0;
	}
	return call(rev, holder, array[] of {keyval(k), v});
}

Jstate: adt {
	replacer:	V;
	proplist:	array of int;	# from an array replacer, or nil
	gap:	string;
	indent:	string;
	stack:	list of int;
};

json_stringify(nil: V, a, n: int, nil: V, nil: int): V
{
	st := ref Jstate(undef, nil, "", "", nil);
	rep := arg(a, n, 1);
	sp0 := sp;
	if(iscallable(rep))
		st.replacer = rep;
	else if(isarray(rep)) {
		l := lengthof(rep);
		keys: list of int;
		for(i := 0.0; i < l; i += 1.0) {
			v := getidx(rep, i);
			item := -1;
			case v.t {
			Tstr =>
				item = strhkey(v.x);
			Tnum =>
				item = numkey(v.n);
			Tobj =>
				if(okind[v.x] == Kprim)
					pick d := odata[v.x] {
					Prim =>
						if(d.v.t == Tstr || d.v.t == Tnum)
							item = tokey(objv(tostrh(v)));
					}
			}
			if(item >= 0 || isidx(item)) {
				if(item != -1 && !hasint(keys, item))
					keys = item :: keys;
			}
		}
		pl := array[len keys] of int;
		for(i2 := len pl - 1; i2 >= 0; i2--) {
			pl[i2] = hd keys;
			keys = tl keys;
		}
		st.proplist = pl;
	}
	space := arg(a, n, 2);
	if(space.t == Tobj && okind[space.x] == Kprim)
		pick d := odata[space.x] {
		Prim =>
			if(d.v.t == Tnum)
				space = num(tonumber(space));
			else if(d.v.t == Tstr)
				space = tostrv(space);
		}
	if(space.t == Tnum) {
		k := tointorinf(space);
		if(k > 10.0)
			k = 10.0;
		for(i := 0; i < int k; i++)
			st.gap[len st.gap] = ' ';
	} else if(space.t == Tstr) {
		g := str(space.x);
		if(len g > 10)
			g = g[0:10];
		st.gap = g;
	}
	wrapper := newplain();
	push(objv(wrapper));
	createdata(wrapper, intern(""), arg(a, n, 0));
	(ok, r) := serialize(st, intern(""), objv(wrapper));
	sp = sp0;
	if(!ok)
		return undef;
	return strv(r);
}

# SerializeJSONProperty: (defined, text)
serialize(st: ref Jstate, k: int, holder: V): (int, string)
{
	v := get(holder.x, k, holder);
	if(v.t == Tobj || v.t == Tbig) {
		tj := getv(v, intern("toJSON"));
		if(iscallable(tj))
			v = call(tj, v, array[] of {keyval(k)});
	}
	if(st.replacer.t != Tundef)
		v = call(st.replacer, holder, array[] of {keyval(k), v});
	if(v.t == Tobj) {
		pt := primtype(v);
		case pt {
		Tnum => v = num(tonumber(v));
		Tstr => v = tostrv(v);
		Tbool or Tbig => v = primof(v);
		* =>
			if(israwjson(v))
				return (1, tostring(getv(v, intern("rawJSON"))));
		}
	}
	case v.t {
	Tnull => return (1, "null");
	Tbool =>
		if(v.x)
			return (1, "true");
		return (1, "false");
	Tstr => return (1, jsonquote(str(v.x)));
	Tnum =>
		if(isfinitenum(v.n))
			return (1, numstr(v.n));
		return (1, "null");
	Tbig => typeerr("do not know how to serialize a BigInt");
	Tobj =>
		if(!iscallable(v)) {
			sp0 := sp;
			push(v);
			r: string;
			if(isarray(v))
				r = serializearray(st, v);
			else
				r = serializeobject(st, v);
			sp = sp0;
			return (1, r);
		}
	}
	return (0, nil);
}

# a wrapper object's primitive type, or -1
primtype(v: V): int
{
	if(v.t == Tobj && okind[v.x] == Kprim)
		pick d := odata[v.x] {
		Prim =>
			return d.v.t;
		}
	return -1;
}

primof(v: V): V
{
	pick d := odata[v.x] {
	Prim =>
		return d.v;
	}
	return undef;
}

jsonquote(s: string): string
{
	r := "\"";
	for(i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'"' => r += "\\\"";
		'\\' => r += "\\\\";
		8 => r += "\\b";
		12 => r += "\\f";
		'\n' => r += "\\n";
		'\r' => r += "\\r";
		'\t' => r += "\\t";
		* =>
			if(c < 16r20)
				r += sys->sprint("\\u%.4x", c);
			else if(c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF) {
				r[len r] = c;
				r[len r] = s[++i];
			} else if(c >= 16rD800 && c <= 16rDFFF)
				r += sys->sprint("\\u%.4x", c);
			else
				r[len r] = c;
		}
	}
	return r + "\"";
}

jsoncycle(st: ref Jstate, h: int)
{
	for(l := st.stack; l != nil; l = tl l)
		if(hd l == h)
			typeerr("converting circular structure to JSON");
}

serializeobject(st: ref Jstate, v: V): string
{
	jsoncycle(st, v.x);
	st.stack = v.x :: st.stack;
	stepback := st.indent;
	st.indent += st.gap;
	keys: array of int;
	if(st.proplist != nil)
		keys = st.proplist;
	else {
		ks := ownkeys(v.x);
		l: list of int;
		for(i := 0; i < len ks; i++) {
			if(issymkey(ks[i]) || isprivkey(ks[i]))
				continue;
			(found, d) := getown(v.x, ks[i]);
			if(found && (d.attrs & Aenum))
				l = ks[i] :: l;
		}
		keys = lista(l);
	}
	parts: list of string;
	for(i := 0; i < len keys; i++) {
		(ok, s) := serialize(st, keys[i], v);
		if(!ok)
			continue;
		m := jsonquote(keystr(keys[i])) + ":";
		if(st.gap != "")
			m += " ";
		parts = (m + s) :: parts;
	}
	r: string;
	if(parts == nil)
		r = "{}";
	else
		r = "{" + joinparts(revs(parts), st, stepback) + "}";
	st.stack = tl st.stack;
	st.indent = stepback;
	return r;
}

serializearray(st: ref Jstate, v: V): string
{
	jsoncycle(st, v.x);
	st.stack = v.x :: st.stack;
	stepback := st.indent;
	st.indent += st.gap;
	l := lengthof(v);
	parts: list of string;
	for(i := 0.0; i < l; i += 1.0) {
		(ok, s) := serialize(st, idxk(i), v);
		if(!ok)
			s = "null";
		parts = s :: parts;
	}
	r: string;
	if(parts == nil)
		r = "[]";
	else
		r = "[" + joinparts(revs(parts), st, stepback) + "]";
	st.stack = tl st.stack;
	st.indent = stepback;
	return r;
}

joinparts(l: list of string, st: ref Jstate, stepback: string): string
{
	r := "";
	if(st.gap == "") {
		for(; l != nil; l = tl l) {
			if(r != "")
				r += ",";
			r += hd l;
		}
		return r;
	}
	sep := ",\n" + st.indent;
	first := 1;
	for(; l != nil; l = tl l) {
		if(!first)
			r += sep;
		first = 0;
		r += hd l;
	}
	return "\n" + st.indent + r + "\n" + stepback;
}

revs(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

israwjson(v: V): int
{
	if(v.t != Tobj)
		return 0;
	(ok, nil, nil) := getownprop(v.x, intern("%rawjson"));
	return ok;
}

json_rawjson(nil: V, a, n: int, nil: V, nil: int): V
{
	s := tostring(arg(a, n, 0));
	if(s == "" || isjsonws(s[0]) || isjsonws(s[len s - 1]))
		throwerr(SyntaxError, "invalid value for JSON.rawJSON");
	p := ref Jp(s, 0);
	c := s[0];
	if(c == '{' || c == '[')
		throwerr(SyntaxError, "invalid value for JSON.rawJSON");
	jsonvalue(p);
	if(p.i < len s)
		jsonerr(p);
	h := newobj(Kord, -1);
	addprop(h, intern("rawJSON"), Aenum, strv(s));
	addprop(h, intern("%rawjson"), 0, vtrue);
	preventext(h);
	freeze(h);
	return objv(h);
}

isjsonws(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

json_israwjson(nil: V, a, n: int, nil: V, nil: int): V
{
	return bool(israwjson(arg(a, n, 0)));
}
