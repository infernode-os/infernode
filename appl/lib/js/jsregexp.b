#
# jsregexp.b - RegExp (ECMAScript 2025 §22.2.4-22.2.9).  Included by js.b.
# Patterns are parsed and matched by the jsre module.
#

regexpinit()
{
	c := ctor("RegExp", 2, regexpctor, iregexpproto);
	getter(c, asymspecies, "[Symbol.species]", returnthis);
	method(c, "escape", 1, regexp_escape);
	p := iregexpproto;
	method(p, "compile", 2, rxproto_compile);
	method(p, "exec", 1, rxproto_exec);
	method(p, "test", 1, rxproto_test);
	method(p, "toString", 0, rxproto_tostring);
	getter(p, aflags, "flags", rxproto_flags);
	flaggetters := array[] of {
		("hasIndices", 'd'), ("global", 'g'), ("ignoreCase", 'i'), ("multiline", 'm'),
		("dotAll", 's'), ("unicode", 'u'), ("unicodeSets", 'v'), ("sticky", 'y'),
	};
	for(i := 0; i < len flaggetters; i++) {
		(nm, ch) := flaggetters[i];
		h := getter(p, intern(nm), nm, rxproto_flag);
		setcap(h, array[] of {num(real ch)});
	}
	getter(p, asource, "source", rxproto_source);
	symmethod(p, asymmatch, "[Symbol.match]", 1, rxproto_match);
	symmethod(p, asymmatchall, "[Symbol.matchAll]", 1, rxproto_matchall);
	symmethod(p, asymreplace, "[Symbol.replace]", 2, rxproto_replace);
	symmethod(p, asymsearch, "[Symbol.search]", 1, rxproto_search);
	symmethod(p, asymsplit, "[Symbol.split]", 2, rxproto_split);
	method(iregexpstriterproto, "next", 0, rxiter_next);
	tag(iregexpstriterproto, "RegExp String Iterator");
}

isregexpobj(v: V): int
{
	return v.t == Tobj && okind[v.x] == Kregexp;
}

rxdata(v: V): ref Data.Regexp
{
	if(isregexpobj(v))
		pick d := odata[v.x] {
		Regexp =>
			return d;
		}
	return nil;
}

# RegExpInitialize
rxinit(h: int, p, f: V): V
{
	ps := "";
	if(p.t != Tundef)
		ps = tostring(p);
	fs := "";
	if(f.t != Tundef)
		fs = tostring(f);
	(fl, ferr) := jsre->parseflags(fs);
	if(ferr != nil)
		throwerr(SyntaxError, "invalid regular expression flags: " + ferr);
	(pat, err) := jsre->parse(ps, fl);
	if(err != nil)
		throwerr(SyntaxError, err);
	odata[h] = ref Data.Regexp(pat, ps, fs, nil);
	setv(objv(h), alastindex, num(0.0), 1);
	return objv(h);
}

# RegExpAlloc: a RegExp object without a pattern yet
rxalloc(nt: V): int
{
	h := newobj(Kregexp, protofromctor(nt, iregexpproto));
	odata[h] = ref Data.Regexp(nil, nil, nil, nil);
	defown(h, alastindex, Awrite, num(0.0));
	return h;
}

regexpcreate(pat, flags: string): int
{
	h := rxalloc(objv(iregexpctor()));
	rxinit(h, strv(pat), strv(flags));
	return h;
}

iregexpctor(): int
{
	return getv(objv(iregexpproto), aconstructor).x;
}

regexpctor(nil: V, a, n: int, nt: V, f: int): V
{
	p := arg(a, n, 0);
	fl := arg(a, n, 1);
	pisrx := isregexp(p);
	if(nt.t == Tundef) {
		nt = objv(f);
		if(pisrx && fl.t == Tundef) {
			pc := getv(p, aconstructor);
			if(samevalue(pc, nt))
				return p;
		}
	}
	ps, fs: V;
	if(isregexpobj(p)) {
		d := rxdata(p);
		ps = strv(d.source);
		if(fl.t == Tundef)
			fs = strv(d.flags);
		else
			fs = fl;
	} else if(pisrx) {
		ps = getv(p, asource);
		if(fl.t == Tundef)
			fs = getv(p, aflags);
		else
			fs = fl;
	} else {
		ps = p;
		fs = fl;
	}
	sp0 := sp;
	push(ps);
	push(fs);
	h := rxalloc(nt);
	push(objv(h));
	r := rxinit(h, ps, fs);
	sp = sp0;
	return r;
}

regexp_escape(nil: V, a, n: int, nil: V, nil: int): V
{
	v := arg(a, n, 0);
	if(v.t != Tstr)
		typeerr("RegExp.escape requires a string");
	s := str(v.x);
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(i == 0 && (c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z')) {
			r += sys->sprint("\\x%.2x", c);
			continue;
		}
		if(strchr("^$\\.*+?()[]{}|/", c)) {
			r[len r] = '\\';
			r[len r] = c;
			continue;
		}
		case c {
		'\t' => r += "\\t";
		'\n' => r += "\\n";
		16r0B => r += "\\v";
		16r0C => r += "\\f";
		'\r' => r += "\\r";
		* =>
			if(strchr(",-=<>#&!%:;@~'`\"", c) || isjsws(c) || c >= 16rD800 && c <= 16rDFFF && !pairat(s, i)) {
				if(c < 256)
					r += sys->sprint("\\x%.2x", c);
				else
					r += sys->sprint("\\u%.4x", c);
			} else if(c >= 16rD800 && c <= 16rDBFF && pairat(s, i)) {
				r[len r] = c;
				r[len r] = s[++i];
			} else
				r[len r] = c;
		}
	}
	return strv(r);
}

pairat(s: string, i: int): int
{
	c := s[i];
	if(c >= 16rD800 && c <= 16rDBFF)
		return i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF;
	if(c >= 16rDC00 && c <= 16rDFFF)
		return i > 0 && s[i-1] >= 16rD800 && s[i-1] <= 16rDBFF;
	return 0;
}

rxproto_compile(this: V, a, n: int, nil: V, nil: int): V
{
	d := rxdata(this);
	if(d == nil)
		typeerr("RegExp.prototype.compile called on incompatible receiver");
	p := arg(a, n, 0);
	f := arg(a, n, 1);
	if(isregexpobj(p)) {
		if(f.t != Tundef)
			typeerr("cannot supply flags when constructing one RegExp from another");
		pd := rxdata(p);
		return rxinit(this.x, strv(pd.source), strv(pd.flags));
	}
	return rxinit(this.x, p, f);
}

# RegExpBuiltinExec: the match array, or null
rxbuiltinexec(r: V, sv: V): V
{
	d := rxdata(r);
	if(d == nil || d.pat == nil)
		typeerr("RegExp exec called on incompatible receiver " + show(r));
	s := str(sv.x);
	li := tolength(getv(r, alastindex));
	fl := d.pat.flags;
	global := (fl & Jsre->Fg) != 0;
	sticky := (fl & Jsre->Fy) != 0;
	hasidx := (fl & Jsre->Fd) != 0;
	if(!global && !sticky)
		li = 0.0;
	if(li > real len s) {
		if(global || sticky)
			setv(r, alastindex, num(0.0), 1);
		return null;
	}
	caps: array of int;
	{
		caps = jsre->exec(d.pat, s, int li, sticky);
	} exception e {
	"re:*" =>
		throwerr(RangeError, "regular expression too complex: " + e[3:]);
	}
	if(caps == nil) {
		if(global || sticky)
			setv(r, alastindex, num(0.0), 1);
		return null;
	}
	e := caps[1];
	if(global || sticky)
		setv(r, alastindex, num(real e), 1);
	ng := d.pat.ngroups;
	arr := newarray(0);
	sp0 := sp;
	push(objv(arr));
	addprop(arr, aindex, Adefault, num(real caps[0]));
	addprop(arr, ainput, Adefault, sv);
	for(i := 0; i <= ng; i++) {
		if(caps[2*i] < 0 || caps[2*i+1] < 0)
			arrpush(arr, undef);
		else
			arrpush(arr, strv(s[caps[2*i]:caps[2*i+1]]));
	}
	groups := undef;
	hasnames := 0;
	for(i = 1; i <= ng; i++)
		if(d.pat.names[i] != nil)
			hasnames = 1;
	if(hasnames) {
		g := newobj(Kord, -1);
		groups = objv(g);
		for(i = 1; i <= ng; i++) {
			nm := d.pat.names[i];
			if(nm == nil)
				continue;
			v := oelems[arr][i];
			k := strkey(nm);
			# with duplicate names, the one that took part
			(ok, cur, nil) := getownprop(g, k);
			if(ok && cur.t != Tundef && v.t == Tundef)
				continue;
			defown(g, k, Adefault, v);
		}
	}
	addprop(arr, agroups, Adefault, groups);
	if(hasidx) {
		ia := newarray(0);
		push(objv(ia));
		for(i = 0; i <= ng; i++) {
			if(caps[2*i] < 0 || caps[2*i+1] < 0)
				arrpush(ia, undef);
			else
				arrpush(ia, objv(arrayof(array[] of {num(real caps[2*i]), num(real caps[2*i+1])})));
		}
		ig := undef;
		if(hasnames) {
			g := newobj(Kord, -1);
			ig = objv(g);
			for(i = 1; i <= ng; i++) {
				nm := d.pat.names[i];
				if(nm == nil)
					continue;
				v := oelems[ia][i];
				k := strkey(nm);
				(ok, cur, nil) := getownprop(g, k);
				if(ok && cur.t != Tundef && v.t == Tundef)
					continue;
				defown(g, k, Adefault, v);
			}
		}
		addprop(ia, agroups, Adefault, ig);
		addprop(arr, intern("indices"), Adefault, objv(ia));
	}
	sp = sp0;
	return objv(arr);
}

# RegExpExec: by the object's exec if it has its own, else the built-in one
rxexec(r: V, sv: V): V
{
	ex := getv(r, intern("exec"));
	if(iscallable(ex) && !(ex.t == Tobj && okind[ex.x] == Knative && isnativefn(ex.x, rxproto_exec))) {
		res := call(ex, r, array[] of {sv});
		if(res.t != Tobj && res.t != Tnull)
			typeerr("exec result must be an object or null");
		return res;
	}
	if(!isregexpobj(r))
		typeerr("RegExp exec called on incompatible receiver " + show(r));
	return rxbuiltinexec(r, sv);
}

isnativefn(h: int, f: Native): int
{
	pick d := odata[h] {
	Native =>
		return d.f == f;
	}
	return 0;
}

rxproto_exec(this: V, a, n: int, nil: V, nil: int): V
{
	if(!isregexpobj(this))
		typeerr("RegExp.prototype.exec called on incompatible receiver " + show(this));
	s := tostrv(arg(a, n, 0));
	sp0 := sp;
	push(s);
	r := rxbuiltinexec(this, s);
	sp = sp0;
	return r;
}

rxproto_test(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype.test called on non-object");
	s := tostrv(arg(a, n, 0));
	sp0 := sp;
	push(s);
	r := rxexec(this, s);
	sp = sp0;
	return bool(r.t != Tnull);
}

rxproto_tostring(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype.toString called on non-object");
	p := tostring(getv(this, asource));
	f := tostring(getv(this, aflags));
	return strv("/" + p + "/" + f);
}

rxproto_flags(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype.flags getter called on non-object");
	r := "";
	names := array[] of {("hasIndices", 'd'), ("global", 'g'), ("ignoreCase", 'i'), ("multiline", 'm'),
		("dotAll", 's'), ("unicode", 'u'), ("unicodeSets", 'v'), ("sticky", 'y')};
	for(i := 0; i < len names; i++) {
		(nm, ch) := names[i];
		if(truthy(getv(this, intern(nm))))
			r[len r] = ch;
	}
	return strv(r);
}

rxproto_flag(this: V, nil, nil: int, nil: V, f: int): V
{
	ch := int capof(f, 0).n;
	d := rxdata(this);
	if(d == nil || d.pat == nil) {
		if(this.t == Tobj && this.x == iregexpproto)
			return undef;
		typeerr("RegExp flag getter called on incompatible receiver " + show(this));
	}
	return bool(strchr(d.flags, ch));
}

rxproto_source(this: V, nil, nil: int, nil: V, nil: int): V
{
	d := rxdata(this);
	if(d == nil || d.pat == nil) {
		if(this.t == Tobj && this.x == iregexpproto)
			return strv("(?:)");
		typeerr("RegExp.prototype.source getter called on incompatible receiver " + show(this));
	}
	return strv(escapesource(d.source));
}

# EscapeRegExpPattern: a source that reads back as the same pattern in a literal
escapesource(s: string): string
{
	if(s == "")
		return "(?:)";
	r := "";
	inclass := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c == '\\' && i + 1 < len s) {
			r[len r] = c;
			r[len r] = s[++i];
			continue;
		}
		if(c == '[')
			inclass = 1;
		else if(c == ']')
			inclass = 0;
		case c {
		'/' =>
			if(inclass)
				r[len r] = c;
			else
				r += "\\/";
		'\n' => r += "\\n";
		'\r' => r += "\\r";
		16r2028 => r += "\\u2028";
		16r2029 => r += "\\u2029";
		* => r[len r] = c;
		}
	}
	return r;
}

# AdvanceStringIndex
advance(s: string, i: real, unicode: int): real
{
	if(!unicode || i + 1.0 >= real len s)
		return i + 1.0;
	ii := int i;
	if(s[ii] >= 16rD800 && s[ii] <= 16rDBFF && s[ii+1] >= 16rDC00 && s[ii+1] <= 16rDFFF)
		return i + 2.0;
	return i + 1.0;
}

flagstr(r: V): string
{
	return tostring(getv(r, aflags));
}

rxproto_match(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype[Symbol.match] called on non-object");
	sv := tostrv(arg(a, n, 0));
	sp0 := sp;
	push(sv);
	fl := flagstr(this);
	if(!strchr(fl, 'g')) {
		r := rxexec(this, sv);
		sp = sp0;
		return r;
	}
	unicode := strchr(fl, 'u') || strchr(fl, 'v');
	setv(this, alastindex, num(0.0), 1);
	arr := newarray(0);
	push(objv(arr));
	s := str(sv.x);
	for(;;) {
		r := rxexec(this, sv);
		if(r.t == Tnull) {
			sp = sp0;
			if(oalen[arr] == 0.0)
				return null;
			return objv(arr);
		}
		ms := tostrv(getv(r, idxkey(0)));
		arrpush(arr, ms);
		if(slen[ms.x] == 0) {
			li := tolength(getv(this, alastindex));
			setv(this, alastindex, num(advance(s, li, unicode)), 1);
		}
	}
}

rxproto_matchall(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype[Symbol.matchAll] called on non-object");
	sv := tostrv(arg(a, n, 0));
	sp0 := sp;
	push(sv);
	c := speciesctor(this, iregexpctor());
	fl := tostrv(getv(this, aflags));
	push(fl);
	m := construct(c, array[] of {this, fl}, c);
	push(m);
	li := tolength(getv(this, alastindex));
	setv(m, alastindex, num(li), 1);
	fs := str(fl.x);
	h := newobj(Kiter, iregexpstriterproto);
	g := 0;
	if(strchr(fs, 'g'))
		g = 1;
	if(strchr(fs, 'u') || strchr(fs, 'v'))
		g |= 2;
	odata[h] = ref Data.Iter(30 + g, m, 0, 0);
	defown(h, intern("%string"), 0, sv);
	sp = sp0;
	return objv(h);
}

rxiter_next(this: V, nil, nil: int, nil: V, nil: int): V
{
	if(this.t != Tobj || okind[this.x] != Kiter)
		typeerr("next method called on incompatible receiver " + show(this));
	pick d := odata[this.x] {
	Iter =>
		if(d.kind < 30 || d.kind > 33)
			typeerr("next method called on incompatible receiver");
		if(d.done)
			return iterresult(undef, 1);
		r := d.target;
		(nil, sv, nil) := getownprop(this.x, intern("%string"));
		m := rxexec(r, sv);
		if(m.t == Tnull) {
			d.done = 1;
			return iterresult(undef, 1);
		}
		if((d.kind & 1) == 0) {
			d.done = 1;
			return iterresult(m, 0);
		}
		ms := tostrv(getv(m, idxkey(0)));
		if(slen[ms.x] == 0) {
			li := tolength(getv(r, alastindex));
			setv(r, alastindex, num(advance(str(sv.x), li, (d.kind & 2) != 0)), 1);
		}
		return iterresult(m, 0);
	}
	return undef;
}

rxproto_replace(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype[Symbol.replace] called on non-object");
	sv := tostrv(arg(a, n, 0));
	sp0 := sp;
	push(sv);
	s := str(sv.x);
	rv := arg(a, n, 1);
	fnrepl := iscallable(rv);
	repl := "";
	if(!fnrepl) {
		rs := tostrv(rv);
		push(rs);
		repl = str(rs.x);
	}
	fl := flagstr(this);
	global := strchr(fl, 'g');
	unicode := strchr(fl, 'u') || strchr(fl, 'v');
	if(global)
		setv(this, alastindex, num(0.0), 1);
	results := newarray(0);
	push(objv(results));
	for(;;) {
		r := rxexec(this, sv);
		if(r.t == Tnull)
			break;
		arrpush(results, r);
		if(!global)
			break;
		ms := tostrv(getv(r, idxkey(0)));
		if(slen[ms.x] == 0) {
			li := tolength(getv(this, alastindex));
			setv(this, alastindex, num(advance(s, li, unicode)), 1);
		}
	}
	acc := "";
	next := 0;
	for(i := 0; i < onelem[results]; i++) {
		r := oelems[results][i];
		nc := lengthof(r) - 1.0;
		if(nc < 0.0)
			nc = 0.0;
		matched := tostring(getv(r, idxkey(0)));
		pos := tointorinf(getv(r, aindex));
		if(pos < 0.0)
			pos = 0.0;
		if(pos > real len s)
			pos = real len s;
		caps := array[int nc] of V;
		for(k := 1; k <= int nc; k++) {
			c := getv(r, idxkey(k));
			if(c.t != Tundef)
				c = tostrv(c);
			caps[k-1] = c;
		}
		groups := getv(r, agroups);
		rep: string;
		if(fnrepl) {
			args := array[len caps + 3 + (groups.t != Tundef)] of V;
			args[0] = strv(matched);
			args[1:] = caps;
			args[len caps + 1] = num(pos);
			args[len caps + 2] = sv;
			if(groups.t != Tundef)
				args[len caps + 3] = groups;
			rep = tostring(call(rv, undef, args));
		} else {
			if(groups.t != Tundef)
				groups = objv(toobject(groups));
			rep = substitution(matched, s, int pos, caps, groups, repl);
		}
		if(int pos >= next) {
			acc += s[next:int pos] + rep;
			next = int pos + len matched;
		}
	}
	if(next < len s)
		acc += s[next:];
	sp = sp0;
	return strv(acc);
}

rxproto_search(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype[Symbol.search] called on non-object");
	sv := tostrv(arg(a, n, 0));
	sp0 := sp;
	push(sv);
	prev := getv(this, alastindex);
	if(!samevalue(prev, num(0.0)))
		setv(this, alastindex, num(0.0), 1);
	r := rxexec(this, sv);
	cur := getv(this, alastindex);
	if(!samevalue(cur, prev))
		setv(this, alastindex, prev, 1);
	sp = sp0;
	if(r.t == Tnull)
		return num(-1.0);
	return getv(r, aindex);
}

rxproto_split(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("RegExp.prototype[Symbol.split] called on non-object");
	sv := tostrv(arg(a, n, 0));
	sp0 := sp;
	push(sv);
	s := str(sv.x);
	c := speciesctor(this, iregexpctor());
	fl := flagstr(this);
	unicode := strchr(fl, 'u') || strchr(fl, 'v');
	nfl := fl;
	if(!strchr(fl, 'y'))
		nfl += "y";
	splitter := construct(c, array[] of {this, strv(nfl)}, c);
	push(splitter);
	arr := newarray(0);
	push(objv(arr));
	lim := 4294967295.0;
	if(arg(a, n, 1).t != Tundef)
		lim = touint32(vs[a+1]);
	if(lim == 0.0) {
		sp = sp0;
		return objv(arr);
	}
	if(len s == 0) {
		z := rxexec(splitter, sv);
		if(z.t == Tnull)
			arrpush(arr, sv);
		sp = sp0;
		return objv(arr);
	}
	p := 0;
	q := 0.0;
	for(; q < real len s; ) {
		setv(splitter, alastindex, num(q), 1);
		z := rxexec(splitter, sv);
		if(z.t == Tnull) {
			q = advance(s, q, unicode);
			continue;
		}
		e := tolength(getv(splitter, alastindex));
		if(e > real len s)
			e = real len s;
		if(int e == p) {
			q = advance(s, q, unicode);
			continue;
		}
		arrpush(arr, strv(s[p:int q]));
		if(oalen[arr] == lim) {
			sp = sp0;
			return objv(arr);
		}
		p = int e;
		nc := lengthof(z) - 1.0;
		if(nc < 0.0)
			nc = 0.0;
		for(i := 1; i <= int nc; i++) {
			arrpush(arr, getv(z, idxkey(i)));
			if(oalen[arr] == lim) {
				sp = sp0;
				return objv(arr);
			}
		}
		q = real p;
	}
	arrpush(arr, strv(s[p:]));
	sp = sp0;
	return objv(arr);
}
