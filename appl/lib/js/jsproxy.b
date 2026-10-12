#
# jsproxy.b - Proxy objects (ECMAScript 2025 §10.5, §28.2), with the
# invariants each trap's result is checked against.  Included by js.b.
#

proxyinit()
{
	c := nativefn("Proxy", 2, proxyctor);
	oflags[c] |= Octor;
	defown(iglobal, intern("Proxy"), Awrite|Aconf, objv(c));
	keep(c);
	method(c, "revocable", 2, proxy_revocable);
}

proxycreate(t, h: V): int
{
	if(t.t != Tobj || h.t != Tobj)
		typeerr("cannot create proxy with a non-object as target or handler");
	p := newobj(Kproxy, -1);
	oflags[p] = oflags[t.x] & (Ocallable|Octor) | Oext;
	odata[p] = ref Data.Proxy(t.x, h.x);
	return p;
}

proxyctor(nil: V, a, n: int, nt: V, nil: int): V
{
	if(nt.t == Tundef)
		typeerr("constructor Proxy requires 'new'");
	return objv(proxycreate(arg(a, n, 0), arg(a, n, 1)));
}

proxy_revocable(nil: V, a, n: int, nil: V, nil: int): V
{
	p := proxycreate(arg(a, n, 0), arg(a, n, 1));
	rv := nativefn("", 0, proxyrevoke);
	setcap(rv, array[] of {objv(p)});
	r := newplain();
	addprop(r, intern("proxy"), Adefault, objv(p));
	addprop(r, intern("revoke"), Adefault, objv(rv));
	return objv(r);
}

proxyrevoke(nil: V, nil, nil: int, nil: V, f: int): V
{
	pv := capof(f, 0);
	if(pv.t == Tobj) {
		pick d := odata[pv.x] {
		Proxy =>
			d.target = -1;
			d.handler = -1;
		}
		setcap(f, array[] of {null});
	}
	return undef;
}

# (target, handler, trap or undefined)
proxytrap(p: int, name: string): (int, int, V)
{
	pick d := odata[p] {
	Proxy =>
		if(d.handler < 0)
			typeerr("cannot perform '" + name + "' on a proxy that has been revoked");
		h := d.handler;
		t := d.target;
		trap := getmethod(objv(h), intern(name));
		return (t, h, trap);
	}
	return (-1, -1, undef);
}

proxygetproto(p: int): int
{
	(t, h, trap) := proxytrap(p, "getPrototypeOf");
	if(trap.t == Tundef)
		return getproto(t);
	r := call(trap, objv(h), array[] of {objv(t)});
	if(r.t != Tobj && r.t != Tnull)
		typeerr("'getPrototypeOf' on proxy: trap returned neither object nor null");
	rp := -1;
	if(r.t == Tobj)
		rp = r.x;
	if(isext(t))
		return rp;
	if(rp != getproto(t))
		typeerr("'getPrototypeOf' on proxy: proxy target is non-extensible but the trap did not return its actual prototype");
	return rp;
}

protov(p: int): V
{
	if(p < 0)
		return null;
	return objv(p);
}

proxysetproto(p, v: int): int
{
	(t, h, trap) := proxytrap(p, "setPrototypeOf");
	if(trap.t == Tundef)
		return setproto(t, v);
	if(!truthy(call(trap, objv(h), array[] of {objv(t), protov(v)})))
		return 0;
	if(isext(t))
		return 1;
	if(getproto(t) != v)
		typeerr("'setPrototypeOf' on proxy: trap returned truish for setting a new prototype on the non-extensible proxy target");
	return 1;
}

proxyisext(p: int): int
{
	(t, h, trap) := proxytrap(p, "isExtensible");
	if(trap.t == Tundef)
		return isext(t);
	r := truthy(call(trap, objv(h), array[] of {objv(t)}));
	if(r != isext(t))
		typeerr("'isExtensible' on proxy: trap result does not reflect extensibility of proxy target");
	return r;
}

proxypreventext(p: int): int
{
	(t, h, trap) := proxytrap(p, "preventExtensions");
	if(trap.t == Tundef)
		return preventext(t);
	r := truthy(call(trap, objv(h), array[] of {objv(t)}));
	if(r && isext(t))
		typeerr("'preventExtensions' on proxy: trap returned truish but the proxy target is extensible");
	return r;
}

proxygetown(p, k: int): (int, ref Desc)
{
	(t, h, trap) := proxytrap(p, "getOwnPropertyDescriptor");
	if(trap.t == Tundef)
		return getown(t, k);
	r := call(trap, objv(h), array[] of {objv(t), keyval(k)});
	if(r.t != Tobj && r.t != Tundef)
		typeerr("'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined for property '" + keystr(k) + "'");
	(tfound, td) := getown(t, k);
	if(r.t == Tundef) {
		if(!tfound)
			return (0, nil);
		if((td.attrs & Aconf) == 0)
			typeerr("'getOwnPropertyDescriptor' on proxy: trap returned undefined for property '" + keystr(k) + "' which is non-configurable in the proxy target");
		if(!isext(t))
			typeerr("'getOwnPropertyDescriptor' on proxy: trap returned undefined for property '" + keystr(k) + "' which exists in the non-extensible proxy target");
		return (0, nil);
	}
	ext := isext(t);
	d := todesc(r);
	# CompletePropertyDescriptor
	if(!isaccdesc(d)) {
		if((d.has & Hvalue) == 0) {
			d.has |= Hvalue;
			d.value = undef;
		}
		d.has |= Hwrite;
	} else
		d.has |= Hget | Hset;
	d.has |= Henum | Hconf;
	if(!tfound) {
		if(!ext)
			typeerr("'getOwnPropertyDescriptor' on proxy: trap returned descriptor for property '" + keystr(k) + "' that is incompatible with the existing property in the proxy target");
	} else if(!compatible(ext, d, td))
		typeerr("'getOwnPropertyDescriptor' on proxy: trap returned descriptor for property '" + keystr(k) + "' that is incompatible with the existing property in the proxy target");
	if((d.attrs & Aconf) == 0) {
		if(!tfound || (td.attrs & Aconf))
			typeerr("'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for property '" + keystr(k) + "' which is either non-existent or configurable in the proxy target");
		if((d.has & Hwrite) && (d.attrs & Awrite) == 0 && isdatadesc(td) && (td.attrs & Awrite))
			typeerr("'getOwnPropertyDescriptor' on proxy: trap reported non-configurable and writable for property '" + keystr(k) + "' which is non-configurable, non-writable in the proxy target");
	}
	return (1, d);
}

proxydefine(p, k: int, d: ref Desc): int
{
	(t, h, trap) := proxytrap(p, "defineProperty");
	if(trap.t == Tundef)
		return defineown(t, k, d);
	if(!truthy(call(trap, objv(h), array[] of {objv(t), keyval(k), fromdesc(d)})))
		return 0;
	(tfound, td) := getown(t, k);
	ext := isext(t);
	settingnc := (d.has & Hconf) && (d.attrs & Aconf) == 0;
	if(!tfound) {
		if(!ext)
			typeerr("'defineProperty' on proxy: trap returned truish for adding property '" + keystr(k) + "' to the non-extensible proxy target");
		if(settingnc)
			typeerr("'defineProperty' on proxy: trap returned truish for defining non-configurable property '" + keystr(k) + "' which is either non-existent or configurable in the proxy target");
	} else {
		if(!compatible(ext, d, td))
			typeerr("'defineProperty' on proxy: trap returned truish for adding property '" + keystr(k) + "' that is incompatible with the existing property in the proxy target");
		if(settingnc && (td.attrs & Aconf))
			typeerr("'defineProperty' on proxy: trap returned truish for defining non-configurable property '" + keystr(k) + "' which is either non-existent or configurable in the proxy target");
		if(isdatadesc(td) && (td.attrs & Aconf) == 0 && (td.attrs & Awrite) && (d.has & Hwrite) && (d.attrs & Awrite) == 0)
			typeerr("'defineProperty' on proxy: trap returned truish for defining non-configurable property '" + keystr(k) + "' which cannot be non-writable, unless there exists a corresponding non-configurable, non-writable own property of the target object");
	}
	return 1;
}

proxyhas(p, k: int): int
{
	(t, h, trap) := proxytrap(p, "has");
	if(trap.t == Tundef)
		return hasprop(t, k);
	r := truthy(call(trap, objv(h), array[] of {objv(t), keyval(k)}));
	if(!r) {
		(tfound, td) := getown(t, k);
		if(tfound) {
			if((td.attrs & Aconf) == 0)
				typeerr("'has' on proxy: trap returned falsish for property '" + keystr(k) + "' which exists in the proxy target as non-configurable");
			if(!isext(t))
				typeerr("'has' on proxy: trap returned falsish for property '" + keystr(k) + "' but the proxy target is not extensible");
		}
	}
	return r;
}

proxyget(p, k: int, recv: V): V
{
	(t, h, trap) := proxytrap(p, "get");
	if(trap.t == Tundef)
		return get(t, k, recv);
	v := call(trap, objv(h), array[] of {objv(t), keyval(k), recv});
	(tfound, td) := getown(t, k);
	if(tfound && (td.attrs & Aconf) == 0) {
		if(isdatadesc(td) && (td.attrs & Awrite) == 0 && !samevalue(v, td.value))
			typeerr("'get' on proxy: property '" + keystr(k) + "' is a read-only and non-configurable data property on the proxy target but the proxy did not return its actual value");
		if(isaccdesc(td) && td.get.t == Tundef && v.t != Tundef)
			typeerr("'get' on proxy: property '" + keystr(k) + "' is a non-configurable accessor property on the proxy target and does not have a getter function, but the trap did not return 'undefined'");
	}
	return v;
}

proxyset(p, k: int, v, recv: V): int
{
	(t, h, trap) := proxytrap(p, "set");
	if(trap.t == Tundef)
		return set(t, k, v, recv);
	if(!truthy(call(trap, objv(h), array[] of {objv(t), keyval(k), v, recv})))
		return 0;
	(tfound, td) := getown(t, k);
	if(tfound && (td.attrs & Aconf) == 0) {
		if(isdatadesc(td) && (td.attrs & Awrite) == 0 && !samevalue(v, td.value))
			typeerr("'set' on proxy: trap returned truish for property '" + keystr(k) + "' which exists in the proxy target as a non-configurable and non-writable data property with a different value");
		if(isaccdesc(td) && td.set.t == Tundef)
			typeerr("'set' on proxy: trap returned truish for property '" + keystr(k) + "' which exists in the proxy target as a non-configurable and non-writable accessor property without a setter");
	}
	return 1;
}

proxydelete(p, k: int): int
{
	(t, h, trap) := proxytrap(p, "deleteProperty");
	if(trap.t == Tundef)
		return delete(t, k);
	if(!truthy(call(trap, objv(h), array[] of {objv(t), keyval(k)})))
		return 0;
	(tfound, td) := getown(t, k);
	if(tfound) {
		if((td.attrs & Aconf) == 0)
			typeerr("'deleteProperty' on proxy: trap returned truish for property '" + keystr(k) + "' which is non-configurable in the proxy target");
		if(!isext(t))
			typeerr("'deleteProperty' on proxy: trap returned truish for property '" + keystr(k) + "' but the proxy target is non-extensible");
	}
	return 1;
}

proxyownkeys(p: int): array of int
{
	(t, h, trap) := proxytrap(p, "ownKeys");
	if(trap.t == Tundef)
		return ownkeys(t);
	r := call(trap, objv(h), array[] of {objv(t)});
	if(r.t != Tobj)
		typeerr("CreateListFromArrayLike called on non-object");
	n := lengthof(r);
	keys: list of int;
	for(i := 0.0; i < n; i += 1.0) {
		e := getv(r, numkey(i));
		if(e.t != Tstr && e.t != Tsym)
			typeerr(show(e) + " is not a valid property name");
		k := tokey(e);
		if(hasint(keys, k))
			typeerr("'ownKeys' on proxy: trap returned duplicate entries");
		keys = k :: keys;
	}
	ext := isext(t);
	tkeys := ownkeys(t);
	nc: list of int;
	conf: list of int;
	for(i2 := 0; i2 < len tkeys; i2++) {
		(found, d) := getown(t, tkeys[i2]);
		if(found && (d.attrs & Aconf) == 0)
			nc = tkeys[i2] :: nc;
		else
			conf = tkeys[i2] :: conf;
	}
	if(ext && nc == nil)
		return revkeys(keys);
	unchecked := keys;
	for(l := nc; l != nil; l = tl l) {
		if(!hasint(unchecked, hd l))
			typeerr("'ownKeys' on proxy: trap result did not include '" + keystr(hd l) + "'");
		unchecked = removeint(unchecked, hd l);
	}
	if(ext)
		return revkeys(keys);
	for(l = conf; l != nil; l = tl l) {
		if(!hasint(unchecked, hd l))
			typeerr("'ownKeys' on proxy: trap result did not include '" + keystr(hd l) + "'");
		unchecked = removeint(unchecked, hd l);
	}
	if(unchecked != nil)
		typeerr("'ownKeys' on proxy: trap returned extra keys but proxy target is non-extensible");
	return revkeys(keys);
}

removeint(l: list of int, x: int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		if(hd l != x)
			r = hd l :: r;
	return r;
}

revkeys(l: list of int): array of int
{
	a := array[len l] of int;
	for(i := len a - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

proxycall(p: int, this: V, a, n: int): V
{
	(t, h, trap) := proxytrap(p, "apply");
	args := array[n] of V;
	args[0:] = vs[a:a+n];
	if(trap.t == Tundef)
		return call(objv(t), this, args);
	arr := arrayof(args);
	return call(trap, objv(h), array[] of {objv(t), this, objv(arr)});
}

proxyconstruct(p, a, n: int, nt: V): V
{
	(t, h, trap) := proxytrap(p, "construct");
	args := array[n] of V;
	args[0:] = vs[a:a+n];
	if(nt.t == Tobj && nt.x == p)
		;
	if(trap.t == Tundef)
		return construct(objv(t), args, nt);
	arr := arrayof(args);
	r := call(trap, objv(h), array[] of {objv(t), objv(arr), nt});
	if(r.t != Tobj)
		typeerr("proxy [[Construct]] must return an object");
	return r;
}
