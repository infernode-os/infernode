#
# jsiregexp.b - RegExp, over the jsre module's parser and matcher (the
# same one appl/lib/js uses), following appl/lib/js/jsregexp.b.
#

NRegExp, NRescape, NRPcompile, NRPexec, NRPtest, NRPtostring, NRPflags, NRPflag, NRPsource,
NRPmatch, NRPmatchall, NRPreplace, NRPsearch, NRPsplit, NRSInext, NRspecies: con Nregexpbase + iota;

regexpctor: ref Obj;
rxstriterproto: ref Obj;
rxexecfn: ref Obj;

regexpinit()
{
	regexpctor = defctor("RegExp", NRegExp, 2, regexpproto);
	c := regexpctor;
	defaccessor(c, a_symspecies, "[Symbol.species]", NRspecies, 0);
	defmethod(c, "escape", NRescape, 1);
	p := regexpproto;
	defmethod(p, "compile", NRPcompile, 2);
	rxexecfn = defmethod(p, "exec", NRPexec, 1);
	defmethod(p, "test", NRPtest, 1);
	defmethod(p, "toString", NRPtostring, 0);
	defaccessor(p, a_flags, "flags", NRPflags, 0);
	flags := array[] of {
		("hasIndices", 'd'), ("global", 'g'), ("ignoreCase", 'i'), ("multiline", 'm'),
		("dotAll", 's'), ("unicode", 'u'), ("unicodeSets", 'v'), ("sticky", 'y'),
	};
	for(i := 0; i < len flags; i++) {
		(nm, ch) := flags[i];
		g := mknative(NRPflag, "get " + nm, 0);
		g.data = ref Data.Native(intv(ch), undef, 0, nil);
		defineown(p, intern(nm), ref Desc(Dget|Dset|Denum|Dconf, undef, Aconf, g, nil));
	}
	defaccessor(p, a_source, "source", NRPsource, 0);
	defsymmethod(p, a_symmatch, "[Symbol.match]", NRPmatch, 1);
	defsymmethod(p, a_symmatchall, "[Symbol.matchAll]", NRPmatchall, 1);
	defsymmethod(p, a_symreplace, "[Symbol.replace]", NRPreplace, 2);
	defsymmethod(p, a_symsearch, "[Symbol.search]", NRPsearch, 1);
	defsymmethod(p, a_symsplit, "[Symbol.split]", NRPsplit, 2);
	rxstriterproto = newobj(Cplain, iterproto);
	defmethod(rxstriterproto, "next", NRSInext, 0);
	defprop(rxstriterproto, a_symtostringtag, strv("RegExp String Iterator"), Aconf);
}

rxdata(v: V): ref Data.Regexp
{
	if(v.t == Tobj && v.o.cls == Cregexp) {
		pick d := v.o.data {
		Regexp =>
			return d;
		}
	}
	return nil;
}

# RegExpInitialize
rxinit(o: ref Obj, p, f: V): V
{
	ps := "";
	if(p.t != Tundef)
		ps = tostr(p);
	fs := "";
	if(f.t != Tundef)
		fs = tostr(f);
	(fl, ferr) := jsre->parseflags(fs);
	if(ferr != nil)
		throwerr(ESyntax, "Invalid regular expression flags: " + ferr);
	(pat, err) := jsre->parse(ps, fl);
	if(err != nil)
		throwerr(ESyntax, "Invalid regular expression: /" + ps + "/: " + err);
	o.data = ref Data.Regexp(pat, ps, fs);
	setprop(o, a_lastIndex, intv(0), 1);
	return objv(o);
}

rxalloc(nt: ref Obj): ref Obj
{
	o := fromctor(nt, regexpproto, Cregexp);
	o.data = ref Data.Regexp(nil, nil, nil);
	addprop(o, a_lastIndex, Awrite, intv(0));
	return o;
}

# a literal's RegExp: patterns parsed once and kept by their source
rxcache: ref Hmap;

newregexp(pat, flags: string): ref Obj
{
	o := ref Obj;
	o.cls = Cregexp;
	o.sh = emptyshape(regexpproto);
	o.flags = Fext;
	addprop(o, a_lastIndex, Awrite, intv(0));
	if(rxcache == nil)
		rxcache = newhmap();
	key := strv(flags + "/" + pat);
	i := hfind(rxcache, key);
	if(i >= 0) {
		pick d := rxcache.vals[i].o.data {
		Regexp =>
			o.data = ref Data.Regexp(d.pat, pat, flags);
			return o;
		}
	}
	rxinit(o, strv(pat), strv(flags));
	h := ref Obj;
	h.data = o.data;
	hset(rxcache, key, objv(h));
	return o;
}

# RegExpCreate for String.prototype.match and its kin
regexpcreate(p: V, isall: int): ref Obj
{
	o := rxalloc(regexpctor);
	f := undef;
	if(isall)
		f = strv("g");
	rxinit(o, p, f);
	return o;
}

natregexp(id: int, f: ref Obj, this: V, args: array of V, nt: ref Obj): V
{
	case id {
	NRegExp =>
		p := arg(args, 0);
		fl := arg(args, 1);
		pisrx := isregexpv(p);
		if(nt == nil) {
			nt = f;
			if(pisrx && fl.t == Tundef) {
				pc := getvalue(p, a_constructor);
				if(pc.t == Tobj && pc.o == nt)
					return p;
			}
		}
		ps, fs: V;
		d := rxdata(p);
		if(d != nil) {
			ps = strv(d.source);
			if(fl.t == Tundef)
				fs = strv(d.flags);
			else
				fs = fl;
		} else if(pisrx) {
			ps = getvalue(p, a_source);
			if(fl.t == Tundef)
				fs = getvalue(p, a_flags);
			else
				fs = fl;
		} else {
			ps = p;
			fs = fl;
		}
		o := rxalloc(nt);
		return rxinit(o, ps, fs);
	NRspecies =>
		return this;
	NRescape =>
		v := arg(args, 0);
		if(!isstr(v))
			throwtype("RegExp.escape requires a string");
		return strv(rxescape(flat(v)));
	NRPcompile =>
		d := rxdata(this);
		if(d == nil)
			throwtype("RegExp.prototype.compile called on incompatible receiver");
		p := arg(args, 0);
		fl := arg(args, 1);
		pd := rxdata(p);
		if(pd != nil) {
			if(fl.t != Tundef)
				throwtype("Cannot supply flags when constructing one RegExp from another");
			return rxinit(this.o, strv(pd.source), strv(pd.flags));
		}
		return rxinit(this.o, p, fl);
	NRPexec =>
		if(rxdata(this) == nil)
			throwtype("RegExp.prototype.exec called on incompatible receiver " + showv(this));
		return rxbuiltinexec(this, tostrv(arg(args, 0)));
	NRPtest =>
		if(this.t != Tobj)
			throwtype("RegExp.prototype.test called on non-object");
		r := rxexec(this, tostrv(arg(args, 0)));
		return boolv(r.t != Tnull);
	NRPtostring =>
		if(this.t != Tobj)
			throwtype("RegExp.prototype.toString called on non-object");
		return strv("/" + tostr(getv(this.o, a_source)) + "/" + tostr(getv(this.o, a_flags)));
	NRPflags =>
		if(this.t != Tobj)
			throwtype("RegExp.prototype.flags getter called on non-object");
		r := "";
		names := array[] of {("hasIndices", 'd'), ("global", 'g'), ("ignoreCase", 'i'), ("multiline", 'm'),
			("dotAll", 's'), ("unicode", 'u'), ("unicodeSets", 'v'), ("sticky", 'y')};
		for(i := 0; i < len names; i++) {
			(nm, ch) := names[i];
			if(tobool(getv(this.o, intern(nm))))
				r[len r] = ch;
		}
		return strv(r);
	NRPflag =>
		ch := 0;
		pick nd := f.data {
		Native =>
			ch = nd.v.i;
		}
		d := rxdata(this);
		if(d == nil || d.pat == nil) {
			if(this.t == Tobj && this.o == regexpproto)
				return undef;
			throwtype("RegExp flag getter called on incompatible receiver " + showv(this));
		}
		return boolv(instr(d.flags, ch));
	NRPsource =>
		d := rxdata(this);
		if(d == nil || d.pat == nil) {
			if(this.t == Tobj && this.o == regexpproto)
				return strv("(?:)");
			throwtype("RegExp.prototype.source getter called on incompatible receiver " + showv(this));
		}
		return strv(escapesource(d.source));
	NRPmatch =>
		return rxmatch(this, args);
	NRPmatchall =>
		return rxmatchall(this, args);
	NRPreplace =>
		return rxreplace(this, args);
	NRPsearch =>
		if(this.t != Tobj)
			throwtype("RegExp.prototype[Symbol.search] called on non-object");
		sv := tostrv(arg(args, 0));
		prev := getv(this.o, a_lastIndex);
		if(!samevalue(prev, intv(0)))
			setprop(this.o, a_lastIndex, intv(0), 1);
		r := rxexec(this, sv);
		cur := getv(this.o, a_lastIndex);
		if(!samevalue(cur, prev))
			setprop(this.o, a_lastIndex, prev, 1);
		if(r.t == Tnull)
			return intv(-1);
		return getvalue(r, a_index);
	NRPsplit =>
		return rxsplit(this, args);
	NRSInext =>
		return rxiternext(this);
	}
	throwerr(EError, "unknown RegExp built-in");
	return undef;
}

rxescape(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(i == 0 && (c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z')) {
			r += sys->sprint("\\x%.2x", c);
			continue;
		}
		if(instr("^$\\.*+?()[]{}|/", c)) {
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
			if(instr(",-=<>#&!%:;@~'`\"", c) || isjsws(c) || c >= 16rD800 && c <= 16rDFFF && !pairat(s, i)) {
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
	return r;
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

# RegExpBuiltinExec
rxbuiltinexec(r: V, sv: V): V
{
	d := rxdata(r);
	if(d == nil || d.pat == nil)
		throwtype("RegExp exec called on incompatible receiver " + showv(r));
	o := r.o;
	s := flat(sv);
	li := tolength(getv(o, a_lastIndex));
	fl := d.pat.flags;
	global := (fl & Jsre->Fg) != 0;
	sticky := (fl & Jsre->Fy) != 0;
	hasidx := (fl & Jsre->Fd) != 0;
	if(!global && !sticky)
		li = 0.0;
	if(li > real len s) {
		if(global || sticky)
			setprop(o, a_lastIndex, intv(0), 1);
		return nullv;
	}
	caps: array of int;
	{
		caps = jsre->exec(d.pat, s, int li, sticky);
	} exception e {
	"re:*" =>
		throwerr(ERange, "regular expression too complex: " + e[3:]);
	}
	if(caps == nil) {
		if(global || sticky)
			setprop(o, a_lastIndex, intv(0), 1);
		return nullv;
	}
	e := caps[1];
	if(global || sticky)
		setprop(o, a_lastIndex, intv(e), 1);
	ng := d.pat.ngroups;
	el := array[ng + 1] of V;
	for(i := 0; i <= ng; i++) {
		if(caps[2*i] < 0 || caps[2*i+1] < 0)
			el[i] = undef;
		else
			el[i] = strv(s[caps[2*i]:caps[2*i+1]]);
	}
	arr := mkarray(el);
	addprop(arr, a_index, Adefault, intv(caps[0]));
	addprop(arr, a_input, Adefault, strv(s));
	groups := undef;
	hasnames := 0;
	for(i = 1; i <= ng; i++)
		if(d.pat.names[i] != nil)
			hasnames = 1;
	if(hasnames) {
		g := newobj(Cplain, nil);
		groups = objv(g);
		for(i = 1; i <= ng; i++) {
			nm := d.pat.names[i];
			if(nm == nil)
				continue;
			k := intern(nm);
			s0 := slotof(g.sh, k);
			if(s0 >= 0) {
				if(el[i].t != Tundef)
					g.slots[s0] = el[i];
				continue;
			}
			addprop(g, k, Adefault, el[i]);
		}
	}
	addprop(arr, a_groups, Adefault, groups);
	if(hasidx) {
		il := array[ng + 1] of V;
		for(i = 0; i <= ng; i++) {
			if(caps[2*i] < 0 || caps[2*i+1] < 0)
				il[i] = undef;
			else
				il[i] = objv(mkarray(array[] of {intv(caps[2*i]), intv(caps[2*i+1])}));
		}
		ia := mkarray(il);
		ig := undef;
		if(hasnames) {
			g := newobj(Cplain, nil);
			ig = objv(g);
			for(i = 1; i <= ng; i++) {
				nm := d.pat.names[i];
				if(nm == nil)
					continue;
				k := intern(nm);
				s0 := slotof(g.sh, k);
				if(s0 >= 0) {
					if(il[i].t != Tundef)
						g.slots[s0] = il[i];
					continue;
				}
				addprop(g, k, Adefault, il[i]);
			}
		}
		addprop(ia, a_groups, Adefault, ig);
		addprop(arr, a_indices, Adefault, objv(ia));
	}
	return objv(arr);
}

# RegExpExec: the object's own exec if it has one, else the built-in
rxexec(r: V, sv: V): V
{
	ex := getv(r.o, a_exec);
	if(iscallable(ex) && ex.o != rxexecfn) {
		res := call(ex.o, r, array[] of {sv});
		if(res.t != Tobj && res.t != Tnull)
			throwtype("exec result must be an object or null");
		return res;
	}
	if(rxdata(r) == nil)
		throwtype("RegExp exec called on incompatible receiver " + showv(r));
	return rxbuiltinexec(r, sv);
}

advance(s: string, i: real, unicode: int): real
{
	if(!unicode || i + 1.0 >= real len s)
		return i + 1.0;
	ii := int i;
	if(s[ii] >= 16rD800 && s[ii] <= 16rDBFF && s[ii+1] >= 16rDC00 && s[ii+1] <= 16rDFFF)
		return i + 2.0;
	return i + 1.0;
}

rxmatch(this: V, args: array of V): V
{
	if(this.t != Tobj)
		throwtype("RegExp.prototype[Symbol.match] called on non-object");
	sv := tostrv(arg(args, 0));
	fl := tostr(getv(this.o, a_flags));
	if(!instr(fl, 'g'))
		return rxexec(this, sv);
	unicode := instr(fl, 'u') || instr(fl, 'v');
	setprop(this.o, a_lastIndex, intv(0), 1);
	arr := newarray(0);
	s := flat(sv);
	for(;;) {
		r := rxexec(this, sv);
		if(r.t == Tnull) {
			if(arr.alen == 0)
				return nullv;
			return objv(arr);
		}
		ms := tostrv(getvalue(r, idxatom(0)));
		apush(arr, ms);
		if(strlenv(ms) == 0) {
			li := tolength(getv(this.o, a_lastIndex));
			setprop(this.o, a_lastIndex, numv(advance(s, li, unicode)), 1);
		}
	}
}

rxmatchall(this: V, args: array of V): V
{
	if(this.t != Tobj)
		throwtype("RegExp.prototype[Symbol.matchAll] called on non-object");
	sv := tostrv(arg(args, 0));
	c := speciesctor(this.o, regexpctor);
	fl := tostrv(getv(this.o, a_flags));
	m := construct(c, array[] of {this, fl}, c);
	li := tolength(getv(this.o, a_lastIndex));
	setprop(m.o, a_lastIndex, numv(li), 1);
	fs := flat(fl);
	g := 0;
	if(instr(fs, 'g'))
		g = 1;
	if(instr(fs, 'u') || instr(fs, 'v'))
		g |= 2;
	it := newobj(Citer, rxstriterproto);
	it.data = ref Data.Iter(30 + g, m.o, strv(flat(sv)), 0, 0, nil);
	return objv(it);
}

rxiternext(this: V): V
{
	if(this.t != Tobj || this.o.cls != Citer)
		throwtype("next method called on incompatible receiver " + showv(this));
	pick d := this.o.data {
	Iter =>
		if(d.kind < 30 || d.kind > 33)
			throwtype("next method called on incompatible receiver");
		if(d.done)
			return iterresult(undef, 1);
		r := objv(d.o);
		m := rxexec(r, d.v);
		if(m.t == Tnull) {
			d.done = 1;
			return iterresult(undef, 1);
		}
		if((d.kind & 1) == 0) {
			d.done = 1;
			return iterresult(m, 0);
		}
		ms := tostrv(getvalue(m, idxatom(0)));
		if(strlenv(ms) == 0) {
			li := tolength(getv(d.o, a_lastIndex));
			setprop(d.o, a_lastIndex, numv(advance(d.v.s, li, (d.kind & 2) != 0)), 1);
		}
		return iterresult(m, 0);
	}
	return undef;
}

rxreplace(this: V, args: array of V): V
{
	if(this.t != Tobj)
		throwtype("RegExp.prototype[Symbol.replace] called on non-object");
	sv := tostrv(arg(args, 0));
	s := flat(sv);
	rv := arg(args, 1);
	fnrepl := iscallable(rv);
	repl := "";
	if(!fnrepl)
		repl = tostr(rv);
	fl := tostr(getv(this.o, a_flags));
	global := instr(fl, 'g');
	unicode := instr(fl, 'u') || instr(fl, 'v');
	if(global)
		setprop(this.o, a_lastIndex, intv(0), 1);
	results: list of V;
	nres := 0;
	for(;;) {
		r := rxexec(this, sv);
		if(r.t == Tnull)
			break;
		results = r :: results;
		nres++;
		if(!global)
			break;
		ms := tostrv(getvalue(r, idxatom(0)));
		if(strlenv(ms) == 0) {
			li := tolength(getv(this.o, a_lastIndex));
			setprop(this.o, a_lastIndex, numv(advance(s, li, unicode)), 1);
		}
	}
	ra := array[nres] of V;
	for(i := nres - 1; i >= 0; i--) {
		ra[i] = hd results;
		results = tl results;
	}
	parts: list of string;
	np := 0;
	next := 0;
	for(i = 0; i < nres; i++) {
		r := ra[i];
		nc := lengthof(r.o) - 1.0;
		if(nc < 0.0)
			nc = 0.0;
		matched := tostr(getvalue(r, idxatom(0)));
		pos := tointeger(getvalue(r, a_index));
		if(pos < 0.0)
			pos = 0.0;
		if(pos > real len s)
			pos = real len s;
		caps := array[int nc] of V;
		for(k := 1; k <= int nc; k++) {
			c := getvalue(r, idxatom(k));
			if(c.t != Tundef)
				c = tostrv(c);
			caps[k-1] = c;
		}
		groups := getvalue(r, a_groups);
		rep: string;
		if(fnrepl) {
			extra := 0;
			if(groups.t != Tundef)
				extra = 1;
			a := array[len caps + 3 + extra] of V;
			a[0] = strv(matched);
			a[1:] = caps;
			a[len caps + 1] = numv(pos);
			a[len caps + 2] = sv;
			if(extra)
				a[len caps + 3] = groups;
			rep = tostr(call(rv.o, undef, a));
		} else {
			if(groups.t != Tundef)
				groups = objv(toobj(groups));
			rep = substitution(matched, s, int pos, caps, groups, repl);
		}
		if(int pos >= next) {
			parts = rep :: s[next:int pos] :: parts;
			np += 2;
			next = int pos + len matched;
		}
	}
	if(next < len s) {
		parts = s[next:] :: parts;
		np++;
	}
	pa := array[np] of string;
	for(i = np - 1; i >= 0; i--) {
		pa[i] = hd parts;
		parts = tl parts;
	}
	return strv(joinall(pa));
}

rxsplit(this: V, args: array of V): V
{
	if(this.t != Tobj)
		throwtype("RegExp.prototype[Symbol.split] called on non-object");
	sv := tostrv(arg(args, 0));
	s := flat(sv);
	c := speciesctor(this.o, regexpctor);
	fl := tostr(getv(this.o, a_flags));
	unicode := instr(fl, 'u') || instr(fl, 'v');
	nfl := fl;
	if(!instr(fl, 'y'))
		nfl += "y";
	splitter := construct(c, array[] of {this, strv(nfl)}, c);
	arr := newarray(0);
	lim := 4294967295.0;
	if(arg(args, 1).t != Tundef)
		lim = touint32(args[1]);
	if(lim == 0.0)
		return objv(arr);
	if(len s == 0) {
		z := rxexec(splitter, sv);
		if(z.t == Tnull)
			apush(arr, sv);
		return objv(arr);
	}
	p := 0;
	q := 0.0;
	while(q < real len s) {
		setprop(splitter.o, a_lastIndex, numv(q), 1);
		z := rxexec(splitter, sv);
		if(z.t == Tnull) {
			q = advance(s, q, unicode);
			continue;
		}
		e := tolength(getv(splitter.o, a_lastIndex));
		if(e > real len s)
			e = real len s;
		if(int e == p) {
			q = advance(s, q, unicode);
			continue;
		}
		apush(arr, strv(s[p:int q]));
		if(real arr.alen == lim)
			return objv(arr);
		p = int e;
		nc := lengthof(z.o) - 1.0;
		if(nc < 0.0)
			nc = 0.0;
		for(i := 1; i <= int nc; i++) {
			apush(arr, getvalue(z, idxatom(i)));
			if(real arr.alen == lim)
				return objv(arr);
		}
		q = real p;
	}
	apush(arr, strv(s[p:]));
	return objv(arr);
}
