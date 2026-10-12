#
# jsiter.b - the Iterator constructor and iterator helpers
# (ECMAScript 2025 §27.1.3-27.1.4).  Included by js.b.
#
# A helper (map, filter, take, drop, flatMap) is an object whose next
# steps the underlying iterator; its state lives in the object's slots
# (the iterator, its next method, the function, a counter, and for
# flatMap the inner iterator), so the collector sees them.
#

iiterhelperproto, iwrapforvalidproto, iiteratorctor: int;

# helper kinds
Hmap, Hfilter, Htake, Hdrop, Hflatmap, Hconcat: con iota;

# helper states
Hsstart, Hsrunning, Hssuspended, Hsdone: con iota;

iterhelpersinit()
{
	c := nativefn("Iterator", 0, iteratorctor);
	oflags[c] |= Octor;
	iiteratorctor = keep(c);
	defown(iglobal, intern("Iterator"), Awrite|Aconf, objv(c));
	defown(c, aprototype, 0, objv(iiterproto));
	method(c, "from", 1, iterator_from);
	method(c, "concat", 0, iterator_concat);
	p := iiterproto;
	accessor(p, aconstructor, "constructor", iterproto_getctor, iterproto_setctor);
	accessor(p, asymtostrtag, "[Symbol.toStringTag]", iterproto_gettag, iterproto_settag);
	method(p, "map", 1, iterproto_map);
	method(p, "filter", 1, iterproto_filter);
	method(p, "take", 1, iterproto_take);
	method(p, "drop", 1, iterproto_drop);
	method(p, "flatMap", 1, iterproto_flatmap);
	method(p, "reduce", 1, iterproto_reduce);
	method(p, "toArray", 0, iterproto_toarray);
	method(p, "forEach", 1, iterproto_foreach);
	method(p, "some", 1, iterproto_some);
	method(p, "every", 1, iterproto_every);
	method(p, "find", 1, iterproto_find);
	iiterhelperproto = keep(newobj(Kord, iiterproto));
	method(iiterhelperproto, "next", 0, helper_next);
	method(iiterhelperproto, "return", 0, helper_return);
	tag(iiterhelperproto, "Iterator Helper");
	iwrapforvalidproto = keep(newobj(Kord, iiterproto));
	method(iwrapforvalidproto, "next", 0, wrap_next);
	method(iwrapforvalidproto, "return", 0, wrap_return);
}

iteratorctor(nil: V, nil, nil: int, nt: V, f: int): V
{
	if(nt.t == Tundef || nt.t == Tobj && nt.x == f)
		typeerr("abstract class Iterator not directly constructable");
	return objv(newobj(Kord, protofromctor(nt, iiterproto)));
}

# SetterThatIgnoresPrototypeProperties
ignoreprotoset(this: V, home, k: int, v: V)
{
	if(this.t != Tobj)
		typeerr("setter called on non-object");
	if(this.x == home)
		typeerr("cannot assign to read only property of the prototype");
	(found, nil) := getown(this.x, k);
	if(!found)
		createdataorthrow(this.x, k, v);
	else
		setv(this, k, v, 1);
}

iterproto_getctor(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return objv(iiteratorctor);
}

iterproto_setctor(this: V, a, n: int, nil: V, nil: int): V
{
	ignoreprotoset(this, iiterproto, aconstructor, arg(a, n, 0));
	return undef;
}

iterproto_gettag(nil: V, nil, nil: int, nil: V, nil: int): V
{
	return strv("Iterator");
}

iterproto_settag(this: V, a, n: int, nil: V, nil: int): V
{
	ignoreprotoset(this, iiterproto, asymtostrtag, arg(a, n, 0));
	return undef;
}

# GetIteratorDirect: (iterator, next)
iterdirect(v: V, name: string): (V, V)
{
	if(v.t != Tobj)
		typeerr("Iterator.prototype." + name + " called on non-object");
	return (v, getv(v, anext));
}

# close it, then rethrow the current exception
closethrow(it: V, e: string)
{
	saved := thrown;
	{
		iterclose(it);
	} exception {
	"js:throw" =>
		;
	}
	thrown = saved;
	raise e;
}

# the helper's slots
Sit, Snext, Sfn, Scount, Sinner, Sinnernext, Sstate, Slimit: con iota;

newhelper(kind: int, it, next, f: V, limit: real): V
{
	h := newobj(Kiter, iiterhelperproto);
	odata[h] = ref Data.Iter(100 + kind, it, 0, 0);
	s := array[8] of V;
	s[Sit] = it;
	s[Snext] = next;
	s[Sfn] = f;
	s[Scount] = num(0.0);
	s[Sinner] = undef;
	s[Sinnernext] = undef;
	s[Sstate] = num(real Hsstart);
	s[Slimit] = num(limit);
	defown(h, intern("%helper"), 0, objv(arrayof(s)));
	return objv(h);
}

helperslots(this: V): (int, int)
{
	if(this.t == Tobj && okind[this.x] == Kiter)
		pick d := odata[this.x] {
		Iter =>
			if(d.kind >= 100) {
				(ok, sv, nil) := getownprop(this.x, intern("%helper"));
				if(ok)
					return (d.kind - 100, sv.x);
			}
		}
	typeerr("Iterator Helper method called on incompatible receiver " + show(this));
	return (0, -1);
}

slot(s, i: int): V
{
	return oelems[s][i];
}

setslot(s, i: int, v: V)
{
	oelems[s][i] = v;
}

helper_next(this: V, nil, nil: int, nil: V, nil: int): V
{
	(kind, s) := helperslots(this);
	st := int slot(s, Sstate).n;
	if(st == Hsrunning)
		typeerr("generator is already running");
	if(st == Hsdone)
		return iterresult(undef, 1);
	setslot(s, Sstate, num(real Hsrunning));
	r: V;
	{
		r = helperstep(kind, s);
	} exception e {
	"js:throw" =>
		setslot(s, Sstate, num(real Hsdone));
		raise e;
	}
	if(int slot(s, Sstate).n == Hsrunning)
		setslot(s, Sstate, num(real Hssuspended));
	return r;
}

# one step: the next value, or done (and the state set done)
helperstep(kind, s: int): V
{
	it := slot(s, Sit);
	next := slot(s, Snext);
	f := slot(s, Sfn);
	case kind {
	Hmap or Hfilter =>
		for(;;) {
			(v, done) := iterstep(it, next);
			if(done) {
				setslot(s, Sstate, num(real Hsdone));
				return iterresult(undef, 1);
			}
			c := slot(s, Scount).n;
			setslot(s, Scount, num(c + 1.0));
			r: V;
			{
				r = call(f, undef, array[] of {v, num(c)});
			} exception e {
			"js:throw" =>
				closethrow(it, e);
			}
			if(kind == Hmap)
				return iterresult(r, 0);
			if(truthy(r))
				return iterresult(v, 0);
		}
	Htake =>
		rem := slot(s, Slimit).n;
		if(rem == 0.0) {
			setslot(s, Sstate, num(real Hsdone));
			iterclose(it);
			return iterresult(undef, 1);
		}
		if(rem != inf)
			setslot(s, Slimit, num(rem - 1.0));
		(v, done) := iterstep(it, next);
		if(done) {
			setslot(s, Sstate, num(real Hsdone));
			return iterresult(undef, 1);
		}
		return iterresult(v, 0);
	Hdrop =>
		rem := slot(s, Slimit).n;
		while(rem > 0.0) {
			if(rem != inf)
				rem -= 1.0;
			setslot(s, Slimit, num(rem));
			(nil, done) := iterstep(it, next);
			if(done) {
				setslot(s, Sstate, num(real Hsdone));
				return iterresult(undef, 1);
			}
		}
		(v, done) := iterstep(it, next);
		if(done) {
			setslot(s, Sstate, num(real Hsdone));
			return iterresult(undef, 1);
		}
		return iterresult(v, 0);
	Hflatmap =>
		for(;;) {
			inner := slot(s, Sinner);
			if(inner.t != Tundef) {
				iv: V;
				idone: int;
				{
					(iv, idone) = iterstep(inner, slot(s, Sinnernext));
				} exception e {
				"js:throw" =>
					closethrow(it, e);
				}
				if(!idone)
					return iterresult(iv, 0);
				setslot(s, Sinner, undef);
				continue;
			}
			(v, done) := iterstep(it, next);
			if(done) {
				setslot(s, Sstate, num(real Hsdone));
				return iterresult(undef, 1);
			}
			c := slot(s, Scount).n;
			setslot(s, Scount, num(c + 1.0));
			{
				m := call(f, undef, array[] of {v, num(c)});
				(ii, inext) := getiteratorflattenable(m, 1);
				setslot(s, Sinner, ii);
				setslot(s, Sinnernext, inext);
			} exception e {
			"js:throw" =>
				closethrow(it, e);
			}
		}
	Hconcat =>
		# f is the array of (iterable, method) pairs; count the next one
		for(;;) {
			inner := slot(s, Sinner);
			if(inner.t != Tundef) {
				(iv, idone) := iterstep(inner, slot(s, Sinnernext));
				if(!idone)
					return iterresult(iv, 0);
				setslot(s, Sinner, undef);
				continue;
			}
			c := int slot(s, Scount).n;
			if(c >= onelem[f.x] / 2) {
				setslot(s, Sstate, num(real Hsdone));
				return iterresult(undef, 1);
			}
			setslot(s, Scount, num(real (c + 1)));
			iterable := oelems[f.x][2*c];
			meth := oelems[f.x][2*c+1];
			ii := call(meth, iterable, nil);
			if(ii.t != Tobj)
				typeerr("iterator is not an object");
			setslot(s, Sinner, ii);
			setslot(s, Sinnernext, getv(ii, anext));
		}
	}
	return iterresult(undef, 1);
}

helper_return(this: V, nil, nil: int, nil: V, nil: int): V
{
	(kind, s) := helperslots(this);
	st := int slot(s, Sstate).n;
	if(st == Hsrunning)
		typeerr("generator is already running");
	if(st == Hsdone)
		return iterresult(undef, 1);
	setslot(s, Sstate, num(real Hsdone));
	if(kind == Hconcat) {
		inner := slot(s, Sinner);
		if(inner.t != Tundef)
			iterclose(inner);
		return iterresult(undef, 1);
	}
	if(kind == Hflatmap && slot(s, Sinner).t != Tundef) {
		{
			iterclose(slot(s, Sinner));
		} exception e {
		"js:throw" =>
			closethrow(slot(s, Sit), e);
		}
	}
	iterclose(slot(s, Sit));
	return iterresult(undef, 1);
}

# GetIteratorFlattenable: an iterator from an iterable or an iterator object; strings only if allowed (rejectstrings 1: not)
getiteratorflattenable(v: V, rejectstrings: int): (V, V)
{
	if(v.t != Tobj) {
		if(rejectstrings || v.t != Tstr)
			typeerr(show(v) + " is not an object");
	}
	m := getmethod(v, asymiterator);
	it: V;
	if(m.t == Tundef)
		it = v;
	else
		it = call(m, v, nil);
	if(it.t != Tobj)
		typeerr("iterator is not an object");
	return (it, getv(it, anext));
}

iterator_from(nil: V, a, n: int, nil: V, nil: int): V
{
	(it, next) := getiteratorflattenable(arg(a, n, 0), 0);
	if(ordinaryhasinstance(objv(iiteratorctor), it))
		return it;
	h := newobj(Kiter, iwrapforvalidproto);
	odata[h] = ref Data.Iter(200, it, 0, 0);
	defown(h, intern("%next"), 0, next);
	return objv(h);
}

wrapped(this: V): (V, V)
{
	if(this.t == Tobj && okind[this.x] == Kiter)
		pick d := odata[this.x] {
		Iter =>
			if(d.kind == 200) {
				(nil, nx, nil) := getownprop(this.x, intern("%next"));
				return (d.target, nx);
			}
		}
	typeerr("method called on incompatible receiver " + show(this));
	return (undef, undef);
}

wrap_next(this: V, nil, nil: int, nil: V, nil: int): V
{
	(it, next) := wrapped(this);
	return call(next, it, nil);
}

wrap_return(this: V, nil, nil: int, nil: V, nil: int): V
{
	(it, nil) := wrapped(this);
	ret := getmethod(it, areturn);
	if(ret.t == Tundef)
		return iterresult(undef, 1);
	return call(ret, it, nil);
}

iterator_concat(nil: V, a, n: int, nil: V, nil: int): V
{
	pairs := newarray(0);
	sp0 := sp;
	push(objv(pairs));
	for(i := 0; i < n; i++) {
		v := vs[a+i];
		if(v.t != Tobj)
			typeerr("Iterator.concat: " + show(v) + " is not an object");
		m := getmethod(v, asymiterator);
		if(m.t == Tundef)
			typeerr("Iterator.concat: " + show(v) + " is not iterable");
		arrpush(pairs, v);
		arrpush(pairs, m);
	}
	h := newhelper(Hconcat, undef, undef, objv(pairs), 0.0);
	sp = sp0;
	return h;
}

helperwith(this: V, a, n: int, kind: int, name: string): V
{
	if(this.t != Tobj)
		typeerr("Iterator.prototype." + name + " called on non-object");
	f := arg(a, n, 0);
	if(!iscallable(f)) {
		closethrowmsg(this, show(f) + " is not a function");
	}
	(it, next) := iterdirect(this, name);
	return newhelper(kind, it, next, f, 0.0);
}

# close this iterator, then throw a TypeError with msg
closethrowmsg(it: V, msg: string)
{
	{
		iterclose(it);
	} exception {
	"js:throw" =>
		;
	}
	typeerr(msg);
}

iterproto_map(this: V, a, n: int, nil: V, nil: int): V { return helperwith(this, a, n, Hmap, "map"); }
iterproto_filter(this: V, a, n: int, nil: V, nil: int): V { return helperwith(this, a, n, Hfilter, "filter"); }
iterproto_flatmap(this: V, a, n: int, nil: V, nil: int): V { return helperwith(this, a, n, Hflatmap, "flatMap"); }

takedrop(this: V, a, n: int, kind: int, name: string): V
{
	if(this.t != Tobj)
		typeerr("Iterator.prototype." + name + " called on non-object");
	lim: real;
	{
		x := tonumber(arg(a, n, 0));
		if(isnan(x))
			throwerr(RangeError, name + " limit must be a number");
		lim = tointorinf(num(x));
		if(lim < 0.0)
			throwerr(RangeError, name + " limit must be non-negative");
	} exception e {
	"js:throw" =>
		closethrow(this, e);
	}
	(it, next) := iterdirect(this, name);
	return newhelper(kind, it, next, undef, lim);
}

iterproto_take(this: V, a, n: int, nil: V, nil: int): V { return takedrop(this, a, n, Htake, "take"); }
iterproto_drop(this: V, a, n: int, nil: V, nil: int): V { return takedrop(this, a, n, Hdrop, "drop"); }

# the eager methods: reduce, toArray, forEach, some, every, find
iterproto_reduce(this: V, a, n: int, nil: V, nil: int): V
{
	if(this.t != Tobj)
		typeerr("Iterator.prototype.reduce called on non-object");
	f := arg(a, n, 0);
	if(!iscallable(f))
		closethrowmsg(this, show(f) + " is not a function");
	(it, next) := iterdirect(this, "reduce");
	acc: V;
	c := 0.0;
	if(n < 2) {
		(v, done) := iterstep(it, next);
		if(done)
			typeerr("reduce of empty iterator with no initial value");
		acc = v;
		c = 1.0;
	} else
		acc = vs[a+1];
	sp0 := sp;
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		{
			acc = call(f, undef, array[] of {acc, v, num(c)});
		} exception e {
		"js:throw" =>
			closethrow(it, e);
		}
		sp = sp0;
		push(acc);
		c += 1.0;
	}
	sp = sp0;
	return acc;
}

iterproto_toarray(this: V, nil, nil: int, nil: V, nil: int): V
{
	(it, next) := iterdirect(this, "toArray");
	r := newarray(0);
	sp0 := sp;
	push(objv(r));
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		arrpush(r, v);
	}
	sp = sp0;
	return objv(r);
}

# kind: 0 forEach, 1 some, 2 every, 3 find
eager(this: V, a, n: int, kind: int, name: string): V
{
	if(this.t != Tobj)
		typeerr("Iterator.prototype." + name + " called on non-object");
	f := arg(a, n, 0);
	if(!iscallable(f))
		closethrowmsg(this, show(f) + " is not a function");
	(it, next) := iterdirect(this, name);
	c := 0.0;
	for(;;) {
		(v, done) := iterstep(it, next);
		if(done)
			break;
		r: V;
		{
			r = call(f, undef, array[] of {v, num(c)});
		} exception e {
		"js:throw" =>
			closethrow(it, e);
		}
		c += 1.0;
		case kind {
		1 =>
			if(truthy(r)) {
				iterclose(it);
				return vtrue;
			}
		2 =>
			if(!truthy(r)) {
				iterclose(it);
				return vfalse;
			}
		3 =>
			if(truthy(r)) {
				iterclose(it);
				return v;
			}
		}
	}
	case kind {
	1 => return vfalse;
	2 => return vtrue;
	}
	return undef;
}

iterproto_foreach(this: V, a, n: int, nil: V, nil: int): V { return eager(this, a, n, 0, "forEach"); }
iterproto_some(this: V, a, n: int, nil: V, nil: int): V { return eager(this, a, n, 1, "some"); }
iterproto_every(this: V, a, n: int, nil: V, nil: int): V { return eager(this, a, n, 2, "every"); }
iterproto_find(this: V, a, n: int, nil: V, nil: int): V { return eager(this, a, n, 3, "find"); }
