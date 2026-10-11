#
# jsieval.b - the evaluator: a walk over jsicomp.b's flat tree.
#
# ev(n) leaves node n's value in the registers rt ri rn rs ro, which
# are read according to rt as a V is (only the fields its tag uses are
# set: the others may hold what an earlier value left).  Statements
# leave ctl set for break, continue and return; a thrown value unwinds
# as the Limbo exception "JS" with the value in thrown, and whatever
# catches it puts the interpreter's state back as it was saved there.
#
# The common cases are in ev itself: constants, locals, the arithmetic
# and comparisons on numbers, property reads and writes on an inline
# cache's hit, calls of functions written in JavaScript.  The rest are
# in ev2 and the functions after it, so that ev's frame stays small.
#

# the value register
rt: int;
ri: int;
rn: real;
rs: string;
ro: ref Obj;

# the running function's state
fr: array of V;
env: ref Env;
curfn: ref Obj;
newt: ref Obj;
argc := 0;
depth := 0;
maxdepth := 3000;

# statement completion
Cnone, Cbreak, Ccont, Cret: con iota;
ctl := 0;
ctlid := 0;
cv: V;		# the completion value of script and eval code

# the pattern stack: the value being destructured, or stored by Nacc
vstk: array of V;
vsp := 0;

global: ref Obj;	# the global object
globalthis: V;

regv(): V
{
	return V(rt, ri, rn, rs, ro);
}

setr(v: V)
{
	rt = v.t;
	ri = v.i;
	rn = v.n;
	rs = v.s;
	ro = v.o;
}

push(v: V)
{
	if(vsp == len vstk) {
		a := array[2 * vsp] of V;
		a[0:] = vstk;
		vstk = a;
	}
	vstk[vsp++] = v;
}

pushr()
{
	if(vsp == len vstk) {
		a := array[2 * vsp] of V;
		a[0:] = vstk;
		vstk = a;
	}
	s := vsp++;
	vstk[s].t = rt;
	vstk[s].i = ri;
	vstk[s].n = rn;
	vstk[s].s = rs;
	vstk[s].o = ro;
}

pop()
{
	vsp--;
	vstk[vsp].o = nil;
	vstk[vsp].s = nil;
}

# truthiness of the registers
truthy(): int
{
	case rt {
	Tbool or Tint =>
		return ri != 0;
	Tundef or Tnull =>
		return 0;
	Tnum =>
		return rn != 0.0 && !isnan(rn);
	Tstr =>
		return len rs != 0;
	Tbig =>
		return !bigzero(ro);
	}
	return 1;
}

# ev keeps no pointer in a local: Dis initialises and releases every
# pointer slot of a frame at each call, and ev is called for every node.
# What must hold an object across a recursive call is in a helper.
ev(n: int)
{
	case op[n] {
	Nundef =>
		rt = Tundef;
	Nnull =>
		rt = Tnull;
	Ntrue =>
		rt = Tbool;
		ri = 1;
	Nfalse =>
		rt = Tbool;
		ri = 0;
	Nint =>
		rt = Tint;
		ri = na[n];
	Nnum =>
		rt = Tnum;
		rn = knum[na[n]];
	Nstr =>
		rt = Tstr;
		rs = kstr[na[n]];
	Nlocal =>
		s := na[n];
		t := fr[s].t;
		rt = t;
		if(t <= Tint)
			ri = fr[s].i;
		else if(t == Tnum)
			rn = fr[s].n;
		else if(t == Tstr)
			rs = fr[s].s;
		else {
			ro = fr[s].o;
			ri = fr[s].i;
		}
	Nsetlocal =>
		ev(nb[n]);
		s := na[n];
		t := rt;
		fr[s].t = t;
		if(t <= Tint)
			fr[s].i = ri;
		else if(t == Tnum)
			fr[s].n = rn;
		else if(t == Tstr)
			fr[s].s = rs;
		else {
			fr[s].o = ro;
			fr[s].i = ri;
		}
	Nenv =>
		tenv = env;
		for(d := na[n]; d > 0; d--)
			tenv = tenv.up;
		s := nb[n];
		t := tenv.v[s].t;
		rt = t;
		if(t <= Tint)
			ri = tenv.v[s].i;
		else if(t == Tnum)
			rn = tenv.v[s].n;
		else if(t == Tstr)
			rs = tenv.v[s].s;
		else {
			ro = tenv.v[s].o;
			ri = tenv.v[s].i;
		}
	Nsetenv =>
		ev(nc[n]);
		tenv = env;
		for(d := na[n]; d > 0; d--)
			tenv = tenv.up;
		s := nb[n];
		t := rt;
		tenv.v[s].t = t;
		if(t <= Tint)
			tenv.v[s].i = ri;
		else if(t == Tnum)
			tenv.v[s].n = rn;
		else if(t == Tstr)
			tenv.v[s].s = rs;
		else {
			tenv.v[s].o = ro;
			tenv.v[s].i = ri;
		}
	Nincl =>
		s := na[n];
		if(fr[s].t == Tint) {
			x := fr[s].i;
			y := x + nb[n];
			if((x ^ y) & (nb[n] ^ y) < 0) {
				ev2(n);
				return;
			}
			fr[s].i = y;
			rt = Tint;
			if(nc[n])
				ri = x;
			else
				ri = y;
			return;
		}
		ev2(n);
	Nadd or Nsub or Nmul or Nlt or Ngt or Nle or Nge or Nseq or Nsne or Nband or Nbor or Nbxor or Nshl or Nshr or Nmod =>
		arith(n);
	Nget =>
		ev(na[n]);
		if(rt == Tobj) {
			if(ro.sh == icsh[n]) {
				if(icobj[n] == nil)
					th = ro;
				else if(icep[n] == protoepoch)
					th = icobj[n];
				else {
					getslow(n, ro);
					return;
				}
				s := icslot[n];
				t := th.slots[s].t;
				rt = t;
				if(t <= Tint)
					ri = th.slots[s].i;
				else if(t == Tnum)
					rn = th.slots[s].n;
				else if(t == Tstr)
					rs = th.slots[s].s;
				else {
					ro = th.slots[s].o;
					ri = th.slots[s].i;
				}
				return;
			}
			getslow(n, ro);
			return;
		}
		getprim(n);
	Ngetelem =>
		getelem(n);
	Nset =>
		setnode(n);
	Nsetelem =>
		setelemnode(n);
	Ncall =>
		ev(na[n]);
		if(rt != Tobj || ro.fun == nil) {
			if(nd[n] & Fopt && (rt == Tundef || rt == Tnull))
				raise "JSopt";
			notfunc(na[n]);
		}
		callf(ro, Tundef, nil, nb[n], nc[n], nd[n]);
	Ncallm =>
		callm(n);
	Nseqs =>
		k := na[n];
		e := k + nb[n];
		for(; k < e; k++) {
			ev(kids[k]);
			if(ctl)
				return;
		}
	Nif =>
		ev(na[n]);
		b: int;
		if(rt == Tbool)
			b = ri;
		else
			b = truthy();
		if(b)
			ev(nb[n]);
		else if(nc[n] >= 0)
			ev(nc[n]);
	Ncompl =>
		ev(na[n]);
		cv = regv();
	Nreturn =>
		if(na[n] >= 0)
			ev(na[n]);
		else
			rt = Tundef;
		ctl = Cret;
	Nfor =>
		forloop(n);
	Nwhile =>
		whileloop(n);
	Nand =>
		ev(na[n]);
		b: int;
		if(rt == Tbool)
			b = ri;
		else
			b = truthy();
		if(b)
			ev(nb[n]);
	Nor =>
		ev(na[n]);
		b: int;
		if(rt == Tbool)
			b = ri;
		else
			b = truthy();
		if(!b)
			ev(nb[n]);
	Nnot =>
		ev(na[n]);
		b: int;
		if(rt == Tbool)
			b = ri;
		else
			b = truthy();
		rt = Tbool;
		ri = !b;
	Ncond =>
		ev(na[n]);
		b: int;
		if(rt == Tbool)
			b = ri;
		else
			b = truthy();
		if(b)
			ev(nb[n]);
		else
			ev(nc[n]);
	Nblock =>
		evblock(n);
	Nglobal =>
		if(global.sh == icsh[n] && icep[n] == glexepoch) {
			s := icslot[n];
			t := global.slots[s].t;
			rt = t;
			if(t <= Tint)
				ri = global.slots[s].i;
			else if(t == Tnum)
				rn = global.slots[s].n;
			else if(t == Tstr)
				rs = global.slots[s].s;
			else {
				ro = global.slots[s].o;
				ri = global.slots[s].i;
			}
			return;
		}
		globalget(n);
	* =>
		ev2(n);
	}
}

# scratch for ev, live only between two of its own calls
tenv: ref Env;
th: ref Obj;

setnode(n: int)
{
	ev(na[n]);
	if(rt != Tobj) {
		setprim(n);
		return;
	}
	o := ro;
	ev(nc[n]);
	if(o.sh == icsh[n] && icobj[n] == nil) {
		s := icslot[n];
		t := rt;
		o.slots[s].t = t;
		if(t <= Tint)
			o.slots[s].i = ri;
		else if(t == Tnum)
			o.slots[s].n = rn;
		else if(t == Tstr)
			o.slots[s].s = rs;
		else {
			o.slots[s].o = ro;
			o.slots[s].i = ri;
		}
		return;
	}
	setslow(n, o);
}

# the arithmetic and comparison operators, with their number cases first
arith(n: int)
{
	l := na[n];
	lt, li: int;
	ln: real;
	if(op[l] == Nlocal) {
		s := na[l];
		lt = fr[s].t;
		if(lt == Tint)
			li = fr[s].i;
		else if(lt == Tnum)
			ln = fr[s].n;
		else {
			ev(l);
			lt = rt;
			li = ri;
			ln = rn;
		}
	} else {
		ev(l);
		lt = rt;
		li = ri;
		ln = rn;
	}
	if(lt != Tint && lt != Tnum) {
		arithslow(n, regv());
		return;
	}
	r := nb[n];
	case op[r] {
	Nint =>
		rt = Tint;
		ri = na[r];
	Nlocal =>
		s := na[r];
		t := fr[s].t;
		rt = t;
		if(t <= Tint)
			ri = fr[s].i;
		else if(t == Tnum)
			rn = fr[s].n;
		else if(t == Tstr)
			rs = fr[s].s;
		else {
			ro = fr[s].o;
			ri = fr[s].i;
		}
	* =>
		ev(r);
	}
	if(lt == Tint && rt == Tint) {
		y := ri;
		case op[n] {
		Nadd =>
			v := li + y;
			if(((li ^ v) & (y ^ v)) >= 0) {
				ri = v;
				return;
			}
			rt = Tnum;
			rn = real li + real y;
		Nsub =>
			v := li - y;
			if(((li ^ y) & (li ^ v)) >= 0) {
				ri = v;
				return;
			}
			rt = Tnum;
			rn = real li - real y;
		Nmul =>
			b := big li * big y;
			if(b >= big -2147483648 && b <= big 2147483647 && (b != big 0 || (li >= 0 && y >= 0))) {
				ri = int b;
				return;
			}
			rt = Tnum;
			rn = real li * real y;
		Nlt =>
			rt = Tbool;
			ri = li < y;
		Ngt =>
			rt = Tbool;
			ri = li > y;
		Nle =>
			rt = Tbool;
			ri = li <= y;
		Nge =>
			rt = Tbool;
			ri = li >= y;
		Nseq =>
			rt = Tbool;
			ri = li == y;
		Nsne =>
			rt = Tbool;
			ri = li != y;
		Nband =>
			ri = li & y;
		Nbor =>
			ri = li | y;
		Nbxor =>
			ri = li ^ y;
		Nshl =>
			ri = li << (y & 31);
		Nshr =>
			ri = li >> (y & 31);
		Nmod =>
			if(li >= 0 && y > 0) {
				ri = li % y;
				return;
			}
			if(y != 0 && li < 0 && y != -1) {
				m := li % y;
				if(m != 0) {
					ri = m;
					return;
				}
				# -0
				rt = Tnum;
				rn = -0.0;
				return;
			}
			arithslow(n, intv(li));
		}
		return;
	}
	if(rt == Tnum || rt == Tint) {
		x, y: real;
		if(lt == Tint)
			x = real li;
		else
			x = ln;
		if(rt == Tint)
			y = real ri;
		else
			y = rn;
		case op[n] {
		Nadd =>
			rt = Tnum;
			rn = x + y;
		Nsub =>
			rt = Tnum;
			rn = x - y;
		Nmul =>
			rt = Tnum;
			rn = x * y;
		Nlt =>
			rt = Tbool;
			if(isnan(x) || isnan(y))
				ri = 0;
			else
				ri = x < y;
		Ngt =>
			rt = Tbool;
			if(isnan(x) || isnan(y))
				ri = 0;
			else
				ri = x > y;
		Nle =>
			rt = Tbool;
			if(isnan(x) || isnan(y))
				ri = 0;
			else
				ri = x <= y;
		Nge =>
			rt = Tbool;
			if(isnan(x) || isnan(y))
				ri = 0;
			else
				ri = x >= y;
		Nseq =>
			rt = Tbool;
			if(isnan(x) || isnan(y))
				ri = 0;
			else
				ri = x == y;
		Nsne =>
			rt = Tbool;
			if(isnan(x) || isnan(y))
				ri = 1;
			else
				ri = x != y;
		Nmod =>
			rt = Tnum;
			rn = jsmod(x, y);
		* =>
			# the bitwise operators
			a := toint32(V(Tnum, 0, x, nil, nil));
			b := toint32(V(Tnum, 0, y, nil, nil));
			rt = Tint;
			case op[n] {
			Nband => ri = a & b;
			Nbor => ri = a | b;
			Nbxor => ri = a ^ b;
			Nshl => ri = a << (b & 31);
			Nshr => ri = a >> (b & 31);
			}
		}
		return;
	}
	if(lt == Tint)
		arithslow(n, intv(li));
	else
		arithslow(n, V(Tnum, 0, ln, nil, nil));
}

jsmod(x, y: real): real
{
	if(isnan(x) || isnan(y) || y == 0.0 || x == inf || x == -inf)
		return nan;
	if(y == inf || y == -inf)
		return x;
	if(x == 0.0)
		return x;
	r := math->fmod(x, y);
	if(r == 0.0 && x < 0.0)
		return -0.0;
	return r;
}

# a binary operator whose left operand is a; the right is still to be evaluated unless it is in the registers
arithslow(n: int, a: V)
{
	# the right operand: in the registers if the left was a number (arith evaluated it)
	b: V;
	if(a.t == Tint || a.t == Tnum)
		b = regv();
	else {
		pushv(a);
		ev(nb[n]);
		a = vstk[vsp-1];
		pop();
		b = regv();
	}
	setr(binv(op[n], a, b));
}

pushv(v: V)
{
	push(v);
}

# the value of a binary operator on two values
binv(o: int, a, b: V): V
{
	case o {
	Nadd =>
		if(a.t == Tstr && b.t == Tstr)
			return concat(a, b);
		if(isnum(a) && isnum(b))
			return V(Tnum, 0, numof(a) + numof(b), nil, nil);
		pa := toprim(a, Hnone);
		pb := toprim(b, Hnone);
		if(isstr(pa) || isstr(pb))
			return concat(tostrv(pa), tostrv(pb));
		return numericop(Nadd, pa, pb);
	Nsub or Nmul or Ndiv or Nmod or Nexp or Nshl or Nshr or Nushr or Nband or Nbor or Nbxor =>
		return numericop(o, a, b);
	Neq =>
		return boolv(looseeq(a, b));
	Nne =>
		return boolv(!looseeq(a, b));
	Nseq =>
		return boolv(stricteq(a, b));
	Nsne =>
		return boolv(!stricteq(a, b));
	Nlt =>
		return boolv(lessthan(a, b, 1) == 1);
	Ngt =>
		return boolv(lessthan(b, a, 0) == 1);
	Nle =>
		return boolv(lessthan(b, a, 0) == 0);
	Nge =>
		return boolv(lessthan(a, b, 1) == 0);
	Nin =>
		if(b.t != Tobj)
			throwtype("Cannot use 'in' operator to search for '" + showkey(a) + "' in " + showv(b));
		return boolv(hasprop(b.o, tokey(a)));
	Ninstof =>
		return boolv(instanceof(a, b));
	}
	throwerr(EError, "bad binary operator");
	return undef;
}

showkey(v: V): string
{
	if(v.t == Tsym)
		return showv(v);
	return tostr(v);
}

# the numeric operators, after ToNumeric
numericop(o: int, a, b: V): V
{
	na := tonumeric(a);
	nb := tonumeric(b);
	if(na.t == Tbig || nb.t == Tbig) {
		if(na.t != nb.t)
			throwtype("Cannot mix BigInt and other types, use explicit conversions");
		return bigop(o, na.o, nb.o);
	}
	x := numof(na);
	y := numof(nb);
	case o {
	Nadd =>
		return V(Tnum, 0, x + y, nil, nil);
	Nsub =>
		return V(Tnum, 0, x - y, nil, nil);
	Nmul =>
		return V(Tnum, 0, x * y, nil, nil);
	Ndiv =>
		return V(Tnum, 0, jsdiv(x, y), nil, nil);
	Nmod =>
		return V(Tnum, 0, jsmod(x, y), nil, nil);
	Nexp =>
		return V(Tnum, 0, jspow(x, y), nil, nil);
	Nushr =>
		u := touint32(na);
		s := toint32(nb) & 31;
		r := u / math->pow(2.0, real s);
		return numv(math->floor(r));
	* =>
		ia := toint32(na);
		ib := toint32(nb);
		case o {
		Nshl =>
			return intv(ia << (ib & 31));
		Nshr =>
			return intv(ia >> (ib & 31));
		Nband =>
			return intv(ia & ib);
		Nbor =>
			return intv(ia | ib);
		Nbxor =>
			return intv(ia ^ ib);
		}
	}
	return undef;
}

jsdiv(x, y: real): real
{
	if(isnan(x) || isnan(y))
		return nan;
	if(y == 0.0) {
		if(x == 0.0)
			return nan;
		neg := (x < 0.0) != negzero(y);
		if(neg)
			return -inf;
		return inf;
	}
	return x / y;
}

jspow(x, y: real): real
{
	if(isnan(y))
		return nan;
	if(y == 0.0)
		return 1.0;
	if(isnan(x))
		return nan;
	ax := x;
	if(ax < 0.0)
		ax = -ax;
	if(ax == 1.0 && (y == inf || y == -inf))
		return nan;
	return math->pow(x, y);
}

# ---- statements and the rest of the expressions ----

ev2(n: int)
{
	case op[n] {
	Nacc =>
		s := vsp - 1;
		rt = vstk[s].t;
		ri = vstk[s].i;
		rn = vstk[s].n;
		rs = vstk[s].s;
		ro = vstk[s].o;
	Nbigint =>
		setr(bigliteral(kstr[na[n]]));
	Nnewpriv =>
		o := newsym(kstr[na[n]], 1);
		o.flags |= Fpriv;
		rt = Tsym;
		ro = o;
	Nlocalchk =>
		s := na[n];
		if(fr[s].t == Thole)
			tdzerror(kstr[nb[n]]);
		setr(fr[s]);
	Nsetlocalchk =>
		ev(nb[n]);
		s := na[n];
		if(fr[s].t == Thole)
			tdzerror(kstr[nc[n]]);
		fr[s] = regv();
	Nenvchk =>
		e := envat(na[n]);
		v := e.v[nb[n]];
		if(v.t == Thole)
			tdzerror(kstr[nc[n]]);
		setr(v);
	Nsetenvchk =>
		ev(nc[n]);
		e := envat(na[n]);
		if(e.v[nb[n]].t == Thole)
			tdzerror(kstr[nd[n]]);
		e.v[nb[n]] = regv();
	Nglobal =>
		globalget(n);
	Nsetglobal =>
		ev(nb[n]);
		globalset(n);
	Nglex =>
		s := na[n];
		if(glexstate[s] == 0) {
			# reserved by a script whose declarations did not happen: the global object's
			globalget1(glexnames[s], 0);
			return;
		}
		v := glexv[s];
		if(v.t == Thole)
			tdzerror(kstr[nb[n]]);
		setr(v);
	Nsetglex =>
		ev(nb[n]);
		s := na[n];
		if(glexstate[s] == 0) {
			v := regv();
			setglobalname(glexnames[s], v, 1);
			setr(v);
			return;
		}
		if(nc[n] & 1 && glexv[s].t == Thole)
			tdzerror(atomstr[glexnames[s]]);
		if(nc[n] & 2)
			throwtype("Assignment to constant variable.");
		glexv[s] = regv();
	Ndyn =>
		dynget(na[n], nb[n]);
	Nsetdyn =>
		dynsetnode(n);
	Nconsterr =>
		ev(na[n]);
		throwtype("Assignment to constant variable.");
	Nignore =>
		ev(na[n]);
	Nglobalthis =>
		setr(globalthis);
	Ngetopt =>
		ev(na[n]);
		if(rt == Tundef || rt == Tnull)
			raise "JSopt";
		v := regv();
		setr(getvalue(v, nb[n]));
	Ngetelemopt =>
		ev(na[n]);
		if(rt == Tundef || rt == Tnull)
			raise "JSopt";
		getelem2(n);
	Noptchk =>
		ev(na[n]);
		if(rt == Tundef || rt == Tnull)
			raise "JSopt";
	Nchain =>
		svsp := vsp;
		{
			ev(na[n]);
		} exception {
		"JSopt" =>
			vsp = svsp;
			rt = Tundef;
		}
	Nmemop =>
		memop(n);
	Nelemop =>
		elemop(n);
	Nmemlog or Nelemlog =>
		memlog(n);
	Nupdvar =>
		updvar(n);
	Nincl =>
		s := na[n];
		old := tonumeric(fr[s]);
		nv := incv(old, nb[n]);
		fr[s] = nv;
		if(nc[n])
			setr(old);
		else
			setr(nv);
	Nupdmem or Nupdelem =>
		updmem(n);
	Ndiv or Nexp or Nushr or Neq or Nne or Nin or Ninstof =>
		ev(na[n]);
		pushr();
		ev(nb[n]);
		a := vstk[vsp-1];
		pop();
		setr(binv(op[n], a, regv()));
	Nprivin =>
		ev(na[n]);
		k := symatom(ro);
		ev(nb[n]);
		if(rt != Tobj)
			throwtype("Cannot use 'in' operator to search for a private field in a non-object");
		rt = Tbool;
		ri = privhas(ro, k);
	Nnullish =>
		ev(na[n]);
		if(rt == Tundef || rt == Tnull)
			ev(nb[n]);
	Nneg =>
		ev(na[n]);
		if(rt == Tint && ri != 0 && ri != int 16r80000000) {
			ri = -ri;
			return;
		}
		v := tonumeric(regv());
		if(v.t == Tbig) {
			setr(bigneg(v.o));
			return;
		}
		rt = Tnum;
		rn = -numof(v);
	Npos =>
		ev(na[n]);
		if(rt == Tint || rt == Tnum)
			return;
		x := tonum(regv());
		rt = Tnum;
		rn = x;
	Nbitnot =>
		ev(na[n]);
		v := tonumeric(regv());
		if(v.t == Tbig) {
			setr(bignot(v.o));
			return;
		}
		ri = ~toint32(v);
		rt = Tint;
	Ntypeof =>
		ev(na[n]);
		rs = typeofv(regv());
		rt = Tstr;
	Nvoid =>
		ev(na[n]);
		rt = Tundef;
	Ndelmem =>
		ev(na[n]);
		v := regv();
		o := toobj(v);
		r := deleteprop(o, nb[n]);
		if(!r && nc[n])
			throwtype("Cannot delete property '" + keyname(nb[n]) + "' of " + showv(v));
		rt = Tbool;
		ri = r;
	Ndelelem =>
		ev(na[n]);
		pushr();
		ev(nb[n]);
		v := vstk[vsp-1];
		pop();
		o := toobj(v);
		k := tokey(regv());
		r := deleteprop(o, k);
		if(!r && nc[n])
			throwtype("Cannot delete property '" + keyname(k) + "' of " + showv(v));
		rt = Tbool;
		ri = r;
	Ndelname =>
		rt = Tbool;
		ri = deletename(na[n]);
	Ndeltrue =>
		ev(na[n]);
		rt = Tbool;
		ri = 1;
	Ncomma =>
		k := na[n];
		e := k + nb[n];
		for(; k < e; k++)
			ev(kids[k]);
	Ncalle =>
		callelem(n);
	Ncallp =>
		ev(na[n]);
		if(rt == Tundef || rt == Tnull) {
			if(ne[n] & Fobjopt)
				raise "JSopt";
		}
		pushr();
		ev(nb[n]);
		f := privget(vstk[vsp-1], symatom(ro));
		this := vstk[vsp-1];
		pop();
		callval(f, this, nc[n], nd[n], ne[n]);
	Ncallsm =>
		ev(nb[n]);
		pushr();
		ev(na[n]);
		f := regv();
		this := vstk[vsp-1];
		pop();
		callval(f, this, nc[n], nd[n], ne[n]);
	Ncalldyn =>
		(f, this) := dynref(na[n]);
		callval(f, this, nb[n], nc[n], nd[n]);
	Nsupercall =>
		supercall(n);
	Neval =>
		directeval(n);
	Nnew =>
		ev(na[n]);
		c := regv();
		args := evargs(nb[n], nc[n], nd[n]);
		if(c.t != Tobj || !isctor(c.o))
			throwtype(calleename(na[n]) + " is not a constructor");
		setr(construct(c.o, args, c.o));
	Nfunc =>
		rt = Tobj;
		ro = closure(codes[na[n]], env);
	Nclass =>
		mkclass(n);
	Narray =>
		arraylit(n);
	Nobject =>
		objectlit(n);
	Ntemplate =>
		k := na[n];
		e := k + nb[n];
		r := strv(nil);
		for(; k < e; k++) {
			c := kids[k];
			if(op[c] == Nstr)
				r = concat(r, strv(kstr[na[c]]));
			else {
				push(r);
				ev(c);
				x := regv();
				if(x.t == Tsym)
					throwtype("Cannot convert a Symbol value to a string");
				s := tostrv(x);
				r = concat(vstk[vsp-1], s);
				pop();
			}
		}
		setr(r);
	Ntmplobj =>
		setr(objv(tmplobj(na[n])));
	Nregex =>
		rt = Tobj;
		ro = newregexp(kstr[na[n]], kstr[nb[n]]);
	Nyield =>
		ev(na[n]);
		setr(genyield(regv()));
	Nyieldstar =>
		ev(na[n]);
		setr(genyieldstar(regv()));
	Nawait =>
		ev(na[n]);
		setr(await(regv()));
	Nprivget =>
		ev(na[n]);
		pushr();
		ev(nb[n]);
		v := privget(vstk[vsp-1], symatom(ro));
		pop();
		setr(v);
	Nprivset =>
		ev(na[n]);
		pushr();
		ev(nb[n]);
		k := symatom(ro);
		ev(nc[n]);
		o := vstk[vsp-1];
		pop();
		privset(o, k, regv());
	Nprivop =>
		ev(na[n]);
		pushr();
		ev(nb[n]);
		k := symatom(ro);
		cur := privget(vstk[vsp-1], k);
		push(cur);
		ev(nc[n]);
		cur = vstk[vsp-1];
		pop();
		r := binv(nd[n], cur, regv());
		privset(vstk[vsp-1], k, r);
		pop();
		setr(r);
	Nprivupd =>
		ev(na[n]);
		pushr();
		ev(nb[n]);
		k := symatom(ro);
		old := tonumeric(privget(vstk[vsp-1], k));
		nv := incv(old, nc[n]);
		privset(vstk[vsp-1], k, nv);
		pop();
		if(nd[n])
			setr(old);
		else
			setr(nv);
	Nprivlog =>
		ev(na[n]);
		pushr();
		ev(nb[n]);
		k := symatom(ro);
		cur := privget(vstk[vsp-1], k);
		b := tobool(cur);
		go: int;
		case nd[n] {
		0 => go = b;
		1 => go = !b;
		* => go = cur.t == Tundef || cur.t == Tnull;
		}
		if(!go) {
			pop();
			setr(cur);
			return;
		}
		ev(nc[n]);
		privset(vstk[vsp-1], k, regv());
		pop();
	Nsuperget =>
		superget(n);
	Nsuperset =>
		superset(n);
	Nimportmeta =>
		if(na[n] < 0)
			throwerr(ESyntax, "Cannot use 'import.meta' outside a module");
		setr(importmetanode(n));
	Nimportget =>
		importget(n);
	Nimportcall =>
		ev(na[n]);
		spec := regv();
		opts := undef;
		if(nb[n] >= 0) {
			push(spec);
			ev(nb[n]);
			opts = regv();
			spec = vstk[vsp-1];
			pop();
		}
		setr(dynimport(spec, opts, kstr[nc[n]]));
	Npat =>
		ev(na[n]);
		pushr();
		bindpat(nb[n]);
		setr(vstk[vsp-1]);
		pop();
	Nnewtarget =>
		case na[n] {
		0 =>
			setr(objv(newt));
			if(newt == nil)
				rt = Tundef;
		1 =>
			rt = Tundef;
			if(curfn != nil) {
				if(curfn.data != nil)
				pick d := curfn.data {
				Func =>
					if(d.home != nil) {
						rt = Tobj;
						ro = d.home;
					}
				}
			}
		2 =>
			rt = Tobj;
			ro = curfn;
		}
	Nusing =>
		ev(na[n]);
		usingnode(nb[n]);
	Nusingscope =>
		usingblock(n);

	# statements
	Ndo =>
		doloop(n);
	Nforin =>
		forin(n);
	Nforof =>
		forof(n);
	Nbreak =>
		ctl = Cbreak;
		ctlid = na[n];
	Ncontinue =>
		ctl = Ccont;
		ctlid = na[n];
	Nthrow =>
		ev(na[n]);
		throwv(regv());
	Ntry =>
		evtry(n);
	Nswitch =>
		evswitch(n);
	Nlabeled =>
		ev(nb[n]);
		if(ctl == Cbreak && ctlid == na[n])
			ctl = 0;
	Nwith =>
		ev(na[n]);
		o := toobj(regv());
		senv := env;
		env = ref Env(nil, env, nil, o, 1);
		ev(nb[n]);
		env = senv;
	Nempty =>
		;
	Nmkenv =>
		env = newenv(na[n], scis[nb[n]], env);
	Nframe2env =>
		env.v[na[n]] = fr[nb[n]];
	Nmkargs =>
		setr(objv(mkargs(na[n])));
		pushr();
		ev(nb[n]);
		pop();
	Nmkrest =>
		setr(objv(mkrest(na[n])));
		pushr();
		bindpat(nb[n]);
		pop();
	Nholes =>
		k := na[n];
		e := k + nb[n];
		for(; k < e; k++) {
			fr[kids[k]].t = Thole;
		}
	Nglobalinst =>
		globalinst(n);
	Ndyndeclvar =>
		dyndeclvar(na[n]);
	Ndyndeclfn =>
		ev(nb[n]);
		dyndeclfn(na[n], regv());
	Nvar =>
		throwerr(EError, "internal: unresolved name " + kstr[ne[n]]);
	* =>
		ev(n);
	}
}

tdzerror(name: string)
{
	if(name == "this")
		throwerr(ERef, "Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
	throwerr(ERef, "Cannot access '" + name + "' before initialization");
}

envat(d: int): ref Env
{
	e := env;
	for(; d > 0; d--)
		e = e.up;
	return e;
}

newenv(n: int, sci: ref Sci, up: ref Env): ref Env
{
	v := array[n] of V;
	if(sci != nil)
		for(i := 0; i < n; i++)
			case sci.kinds[i] {
			Blet or Bconst or Bclass or Bcinner =>
				v[i].t = Thole;
			}
	e := ref Env(v, up, sci, nil, 0);
	if(sci != nil && sci.evalvars)
		e.obj = newobj(Cplain, nil);
	return e;
}

evblock(n: int)
{
	senv := env;
	if(nd[n]) {
		pick s := infos[ne[n]] {
		Scope =>
			env = newenv(s.nenv, s.sci, env);
		}
	}
	if(nc[n] >= 0) {
		ev(nc[n]);
	}
	ev(na[n]);
	env = senv;
}

# ---- loops ----

# whether the loop with Info inf takes a break or continue to label id
haslabel(inf, id: int): int
{
	pick li := infos[inf] {
	Loop =>
		for(l := li.labels; l != nil; l = tl l)
			if(hd l == id)
				return 1;
	}
	return 0;
}

# after a loop body: 1 if the loop goes on, 0 if it stops (ctl left for the outside)
loopctl(inf: int): int
{
	if(ctl == Cbreak) {
		if(ctlid == 0 || haslabel(inf, ctlid))
			ctl = 0;
		return 0;
	}
	if(ctl == Ccont) {
		if(ctlid == 0 || haslabel(inf, ctlid)) {
			ctl = 0;
			return 1;
		}
		return 0;
	}
	return 0;
}

forloop(n: int)
{
	if(na[n] >= 0)
		ev(na[n]);
	test := nb[n];
	upd := nc[n];
	body := nd[n];
	inf := ne[n];
	nper := 0;
	pick li := infos[inf] {
	Loop =>
		nper = li.nper;
	}
	if(nper)
		periter();
	for(;;) {
		if(test >= 0) {
			ev(test);
			if(rt == Tbool) {
				if(ri == 0)
					break;
			} else if(!truthy())
				break;
		}
		ev(body);
		if(ctl && !loopctl(inf))
			break;
		if(nper)
			periter();
		if(upd >= 0)
			ev(upd);
	}
}

# a copy of the loop's env for the next iteration (closures keep the old one)
periter()
{
	v := array[len env.v] of V;
	v[0:] = env.v;
	env = ref Env(v, env.up, env.sci, nil, 0);
}

whileloop(n: int)
{
	test := na[n];
	body := nb[n];
	inf := nc[n];
	for(;;) {
		ev(test);
		if(rt == Tbool) {
			if(ri == 0)
				break;
		} else if(!truthy())
			break;
		ev(body);
		if(ctl && !loopctl(inf))
			break;
	}
}

doloop(n: int)
{
	body := na[n];
	test := nb[n];
	inf := nc[n];
	for(;;) {
		ev(body);
		if(ctl && !loopctl(inf))
			break;
		ev(test);
		if(!truthy())
			break;
	}
}

# a for-in or for-of's iteration binding: a fresh env, then the target bound from the registers
forbind(n: int, inf: ref Info.Loop, benv: ref Env)
{
	if(inf.nper > 0)
		env = newenv(inf.nper, inf.sci, benv);
	pushr();
	bindpat(nb[n]);
	pop();
}

forin(n: int)
{
	ev(na[n]);
	if(rt == Tundef || rt == Tnull)
		return;
	o := toobj(regv());
	inf: ref Info.Loop;
	pick li := infos[nd[n]] {
	Loop =>
		inf = li;
	}
	benv := env;
	# the keys: own enumerable ones, then the prototypes', skipping shadowed and deleted ones
	visited := newhmap();
	for(p := o; p != nil; p = getprotoof(p)) {
		keys := ownkeys(p);
		for(i := 0; i < len keys; i++) {
			k := keys[i];
			if(atomsym[k] != nil)
				continue;
			kv := strv(atomstr[k]);
			if(hfind(visited, kv) >= 0)
				continue;
			hset(visited, kv, truev);
			d := getowndesc(p, k);
			if(d == nil || (d.attrs & Aenum) == 0)
				continue;
			setr(kv);
			forbind(n, inf, benv);
			ev(nc[n]);
			env = benv;
			if(ctl && !loopctl(nd[n]))
				return;
		}
	}
}

forof(n: int)
{
	inf: ref Info.Loop;
	pick li := infos[nd[n]] {
	Loop =>
		inf = li;
	}
	ev(na[n]);
	v := regv();
	benv := env;
	if(inf.await) {
		forawait(n, v, inf, benv);
		return;
	}
	# an ordinary array with the ordinary iterator: by index
	if(v.t == Tobj && v.o.cls == Carray && arrayiterplain(v.o)) {
		o := v.o;
		for(i := 0; i < o.alen; i++) {
			if((o.flags & Fslow) == 0 && i < len o.elems && o.elems[i].t != Thole) {
				e := o.elems[i];
				rt = e.t;
				ri = e.i;
				rn = e.n;
				rs = e.s;
				ro = e.o;
			} else
				setr(getidx(o, i, v));
			{
				forbind(n, inf, benv);
				ev(nc[n]);
			} exception {
			"JS*" =>
				env = benv;
				raise;
			}
			env = benv;
			if(ctl && !loopctl(nd[n]))
				return;
			if(!arrayiterplain(o)) {
				# the iterator was changed: go on with it from here
				it := getiterator(v, 0);
				pick d := it.o.data {
				Iter =>
					d.i = i + 1;
				}
				forofiter(n, it, inf, benv);
				return;
			}
		}
		return;
	}
	it := getiterator(v, 0);
	forofiter(n, it, inf, benv);
}

forofiter(n: int, it: V, inf: ref Info.Loop, benv: ref Env)
{
	next := getvalue(it, a_next);
	for(;;) {
		r := call1(next, it, nil);
		if(r.t != Tobj)
			throwtype("Iterator result " + showv(r) + " is not an object");
		if(tobool(getv(r.o, a_done)))
			return;
		setr(getv(r.o, a_value));
		{
			forbind(n, inf, benv);
			ev(nc[n]);
		} exception {
		"JS" =>
			env = benv;
			ex := thrown;
			iterclose(it, 1);
			throwv(ex);
		"JS*" =>
			env = benv;
			iterclose(it, 0);
			raise;
		}
		env = benv;
		if(ctl) {
			if(!loopctl(nd[n])) {
				iterclose(it, 0);
				return;
			}
		}
	}
}

# ---- switch, try ----

evswitch(n: int)
{
	ev(na[n]);
	d := regv();
	k := nb[n];
	nk := nc[n];
	start := -1;
	dflt := -1;
	push(d);
	for(i := 0; i < nk; i++) {
		c := kids[k + i];
		if(na[c] < 0) {
			dflt = i;
			continue;
		}
		ev(na[c]);
		if(stricteq(vstk[vsp-1], regv())) {
			start = i;
			break;
		}
	}
	pop();
	if(start < 0)
		start = dflt;
	if(start < 0)
		return;
	for(i = start; i < nk; i++) {
		c := kids[k + i];
		ks := nb[c];
		ke := ks + nc[c];
		for(j := ks; j < ke; j++) {
			ev(kids[j]);
			if(ctl) {
				if(ctl == Cbreak && ctlid == 0)
					ctl = 0;
				return;
			}
		}
	}
}

evtry(n: int)
{
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	sdepth := depth;
	svsp := vsp;
	pending := 0;	# 1: a thrown value, 2: another of the engine's own (a generator's return)
	pex: V;
	pexs: string;
	{
		ev(na[n]);
	} exception e {
	"JS" =>
		fr = sfr;
		env = senv;
		curfn = sfn;
		newt = snt;
		argc = sargc;
		depth = sdepth;
		vsp = svsp;
		ctl = 0;
		if(nc[n] >= 0) {
			# the catch clause, which may throw in its turn
			ex := thrown;
			if(nd[n] < 0) {
				catchclause(n, ex, senv);
				return;
			}
			{
				catchclause(n, ex, senv);
			} exception e2 {
			"JS" =>
				fr = sfr;
				env = senv;
				curfn = sfn;
				newt = snt;
				argc = sargc;
				depth = sdepth;
				vsp = svsp;
				ctl = 0;
				pending = 1;
				pex = thrown;
			"JS*" =>
				fr = sfr;
				env = senv;
				curfn = sfn;
				newt = snt;
				argc = sargc;
				depth = sdepth;
				vsp = svsp;
				pending = 2;
				pexs = e2;
			}
		} else {
			pending = 1;
			pex = thrown;
		}
	"JS*" =>
		if(nd[n] < 0)
			raise e;
		fr = sfr;
		env = senv;
		curfn = sfn;
		newt = snt;
		argc = sargc;
		depth = sdepth;
		vsp = svsp;
		pending = 2;
		pexs = e;
	}
	if(nd[n] < 0)
		return;
	# finally: it runs with the completion put aside; its own abrupt completion replaces it
	sctl := ctl;
	sid := ctlid;
	sv := regv();
	ctl = 0;
	ev(nd[n]);
	if(ctl)
		return;
	ctl = sctl;
	ctlid = sid;
	setr(sv);
	case pending {
	1 =>
		throwv(pex);
	2 =>
		raise pexs;
	}
}

catchclause(n: int, ex: V, senv: ref Env)
{
	if(nb[n] >= 0) {
		if(ne[n] >= 0) {
			pick s := infos[ne[n]] {
			Scope =>
				env = newenv(s.nenv, s.sci, env);
			}
		}
		push(ex);
		bindpat(nb[n]);
		pop();
	}
	ev(nc[n]);
	env = senv;
}

# ---- variables found by name ----

globalget(n: int)
{
	g := global;
	if(g.sh == icsh[n] && icep[n] == glexepoch) {
		s := icslot[n];
		v := g.slots[s];
		setr(v);
		return;
	}
	a := na[n];
	# a global lexical declaration made since this was compiled
	(slot, nil) := glexfind(atomstr[a]);
	if(slot >= 0) {
		v := glexv[slot];
		if(v.t == Thole)
			tdzerror(atomstr[a]);
		setr(v);
		return;
	}
	s := slotof(g.sh, a);
	if(s >= 0 && (g.sh.attrs[s] & Aacc) == 0) {
		icsh[n] = g.sh;
		icslot[n] = s;
		icep[n] = glexepoch;
		setr(g.slots[s]);
		return;
	}
	globalget1(a, nb[n]);
}

globalget1(a, istypeof: int)
{
	if(!hasprop(global, a)) {
		if(istypeof) {
			rt = Tundef;
			return;
		}
		throwerr(ERef, atomstr[a] + " is not defined");
	}
	setr(get(global, a, objv(global)));
}

globalset(n: int)
{
	g := global;
	a := na[n];
	if(g.sh == icsh[n] && icep[n] == glexepoch) {
		g.slots[icslot[n]] = regv();
		return;
	}
	(slot, isconst) := glexfind(atomstr[a]);
	if(slot >= 0) {
		if(glexv[slot].t == Thole)
			tdzerror(atomstr[a]);
		if(isconst)
			throwtype("Assignment to constant variable.");
		glexv[slot] = regv();
		return;
	}
	v := regv();
	s := slotof(g.sh, a);
	if(s >= 0 && (g.sh.attrs[s] & (Aacc|Awrite)) == Awrite) {
		g.slots[s] = v;
		icsh[n] = g.sh;
		icslot[n] = s;
		icep[n] = glexepoch;
		return;
	}
	setglobalname(a, v, nc[n]);
	setr(v);
}

# assignment to an unqualified global name
setglobalname(a: int, v: V, strict: int)
{
	if(strict == 2) {
		# initialisation (Annex B's block functions, var at top level)
		put(global, a, v, objv(global));
		return;
	}
	if(!hasprop(global, a)) {
		if(strict)
			throwerr(ERef, atomstr[a] + " is not defined");
		createdata(global, a, v);
		return;
	}
	if(!put(global, a, v, objv(global)) && strict)
		throwtype("Cannot assign to read only property '" + atomstr[a] + "' of object");
}

# a name through the env chain, by name: with objects, eval's variables, then the globals
dynfind(a: int): (ref Env, int, ref Obj)
{
	for(e := env; e != nil; e = e.up) {
		if(e.with) {
			o := e.obj;
			if(hasprop(o, a)) {
				# Symbol.unscopables
				u := getv(o, a_symunscopables);
				if(u.t == Tobj && tobool(getv(u.o, a)))
					continue;
				return (nil, -1, o);
			}
			continue;
		}
		if(e.sci != nil) {
			names := e.sci.names;
			for(i := 0; i < len names; i++)
				if(names[i] == a)
					return (e, i, nil);
		}
		if(e.obj != nil && hasown(e.obj, a))
			return (nil, -1, e.obj);
	}
	return (nil, -1, nil);
}

dynget(a, istypeof: int)
{
	(e, s, o) := dynfind(a);
	if(e != nil) {
		v := e.v[s];
		if(v.t == Thole)
			tdzerror(atomstr[a]);
		setr(v);
		return;
	}
	if(o != nil) {
		if(o.cls != Cproxy && !hasprop(o, a)) {
			# gone since it was found (a getter on the chain removed it)
			if(!e.with)
				;
		}
		setr(get(o, a, objv(o)));
		return;
	}
	(slot, nil) := glexfind(atomstr[a]);
	if(slot >= 0) {
		v := glexv[slot];
		if(v.t == Thole)
			tdzerror(atomstr[a]);
		setr(v);
		return;
	}
	globalget1(a, istypeof);
}

dynset(a: int, v: V, strict: int)
{
	(e, s, o) := dynfind(a);
	if(e != nil) {
		if(e.v[s].t == Thole && strict != 2)
			tdzerror(atomstr[a]);
		k := e.sci.kinds[s];
		if(k == Bconst || k == Bcinner) {
			if(strict != 2)
				throwtype("Assignment to constant variable.");
		}
		if(k == Bfname) {
			if(strict == 1)
				throwtype("Assignment to constant variable.");
			setr(v);
			return;
		}
		e.v[s] = v;
		setr(v);
		return;
	}
	if(o != nil) {
		if(!put(o, a, v, objv(o)) && strict == 1)
			throwtype("Cannot assign to read only property '" + atomstr[a] + "'");
		setr(v);
		return;
	}
	(slot, isconst) := glexfind(atomstr[a]);
	if(slot >= 0) {
		if(glexv[slot].t == Thole)
			tdzerror(atomstr[a]);
		if(isconst)
			throwtype("Assignment to constant variable.");
		glexv[slot] = v;
		setr(v);
		return;
	}
	setglobalname(a, v, strict);
	setr(v);
}

# a = v where a is found by name: the reference first, then the value
dynsetnode(n: int)
{
	a := na[n];
	strict := nc[n];
	(e, s, o) := dynfind(a);
	if(e == nil && o == nil) {
		ev(nb[n]);
		dynset(a, regv(), strict);
		return;
	}
	ev(nb[n]);
	v := regv();
	if(e != nil) {
		if(e.v[s].t == Thole && strict != 2)
			tdzerror(atomstr[a]);
		k := e.sci.kinds[s];
		if((k == Bconst || k == Bcinner) && strict != 2)
			throwtype("Assignment to constant variable.");
		if(k == Bfname) {
			if(strict == 1)
				throwtype("Assignment to constant variable.");
			setr(v);
			return;
		}
		e.v[s] = v;
		setr(v);
		return;
	}
	# a with's object (or eval's variables): it may have lost the property since
	if(strict == 1 && !hasprop(o, a))
		throwerr(ERef, atomstr[a] + " is not defined");
	if(!put(o, a, v, objv(o)) && strict == 1)
		throwtype("Cannot assign to read only property '" + atomstr[a] + "'");
	setr(v);
}

# the function a name calls in a with, and the this it gets
dynref(a: int): (V, V)
{
	(e, s, o) := dynfind(a);
	if(e != nil) {
		v := e.v[s];
		if(v.t == Thole)
			tdzerror(atomstr[a]);
		return (v, undef);
	}
	if(o != nil) {
		this := undef;
		for(x := env; x != nil; x = x.up)
			if(x.with && x.obj == o)
				this = objv(o);
		return (get(o, a, objv(o)), this);
	}
	dynget(a, 0);
	return (regv(), undef);
}

deletename(a: int): int
{
	(e, nil, o) := dynfind(a);
	if(e != nil)
		return 0;
	if(o != nil)
		return deleteprop(o, a);
	(slot, nil) := glexfind(atomstr[a]);
	if(slot >= 0)
		return 0;
	return deleteprop(global, a);
}

# var declared by sloppy direct eval: in the nearest variable scope
dyndeclvar(a: int)
{
	for(e := env; e != nil; e = e.up) {
		if(e.with)
			continue;
		if(e.sci != nil && e.sci.isfunc) {
			names := e.sci.names;
			for(i := 0; i < len names; i++)
				if(names[i] == a)
					return;
			if(e.sci.evalvars) {
				if(!hasown(e.obj, a))
					addprop(e.obj, a, Awrite|Aenum|Aconf, undef);
				return;
			}
		}
		# a let of the same name in between is an error
		if(e.sci != nil && !e.sci.isfunc) {
			names := e.sci.names;
			for(i := 0; i < len names; i++)
				if(names[i] == a && e.sci.kinds[i] != Bvar && e.sci.kinds[i] != Bfunc && e.sci.kinds[i] != Bcatch)
					throwerr(ESyntax, "Identifier '" + atomstr[a] + "' has already been declared");
		}
	}
	(slot, nil) := glexfind(atomstr[a]);
	if(slot >= 0)
		throwerr(ESyntax, "Identifier '" + atomstr[a] + "' has already been declared");
	if(!hasown(global, a)) {
		if(!isextensible(global))
			throwtype("Cannot declare global variable " + atomstr[a]);
		defineown(global, a, ref Desc(Dvalue|Dwrite|Denum|Dconf, undef, Adefault, nil, nil));
	}
}

dyndeclfn(a: int, f: V)
{
	for(e := env; e != nil; e = e.up) {
		if(e.with)
			continue;
		if(e.sci != nil && e.sci.isfunc) {
			names := e.sci.names;
			for(i := 0; i < len names; i++)
				if(names[i] == a) {
					e.v[i] = f;
					return;
				}
			if(e.sci.evalvars) {
				s := slotof(e.obj.sh, a);
				if(s >= 0)
					e.obj.slots[s] = f;
				else
					addprop(e.obj, a, Awrite|Aenum|Aconf, f);
				return;
			}
		}
		if(e.sci != nil && !e.sci.isfunc) {
			names := e.sci.names;
			for(i := 0; i < len names; i++)
				if(names[i] == a && e.sci.kinds[i] != Bvar && e.sci.kinds[i] != Bfunc && e.sci.kinds[i] != Bcatch)
					throwerr(ESyntax, "Identifier '" + atomstr[a] + "' has already been declared");
		}
	}
	(slot, nil) := glexfind(atomstr[a]);
	if(slot >= 0)
		throwerr(ESyntax, "Identifier '" + atomstr[a] + "' has already been declared");
	(found, nil, at) := getown(global, a);
	if(!found || (at & Aconf))
		defineorthrow(global, a, ref Desc(Dvalue|Dwrite|Denum|Dconf, f, Adefault, nil, nil));
	else
		put(global, a, f, objv(global));
}

# GlobalDeclarationInstantiation
globalinst(n: int)
{
	inf: ref Info.Ginst;
	pick g := infos[na[n]] {
	Ginst =>
		inf = g;
	}
	for(l := inf.lexs; l != nil; l = tl l) {
		(name, nil, nil) := hd l;
		a := intern(name);
		(s, nil) := glexfind(name);
		if(s >= 0)
			throwerr(ESyntax, "Identifier '" + name + "' has already been declared");
		# a var of the name (declared by var, not just a property) or a non-configurable property
		(found, nil, at) := getown(global, a);
		if(found && ((at & Aconf) == 0 || isglobalvar(a)))
			throwerr(ESyntax, "Identifier '" + name + "' has already been declared");
	}
	for(vl := inf.vars; vl != nil; vl = tl vl) {
		(s, nil) := glexfind(hd vl);
		if(s >= 0)
			throwerr(ESyntax, "Identifier '" + hd vl + "' has already been declared");
	}
	for(fl := inf.fns; fl != nil; fl = tl fl) {
		(name, nil) := hd fl;
		a := intern(name);
		(found, nil, at) := getown(global, a);
		if(found && (at & Aconf) == 0 && (at & (Awrite|Aenum|Aacc)) != (Awrite|Aenum))
			throwtype("Cannot redefine global function " + name);
		if(!found && !isextensible(global))
			throwtype("Cannot define global function " + name);
	}
	for(vl = inf.vars; vl != nil; vl = tl vl) {
		a := intern(hd vl);
		if(!hasown(global, a) && !isextensible(global))
			throwtype("Cannot declare global variable " + hd vl);
	}
	# now make them
	for(l = inf.lexs; l != nil; l = tl l) {
		(nil, slot, nil) := hd l;
		glexstate[slot] = 1;
		glexv[slot] = holev;
	}
	if(inf.lexs != nil)
		glexepoch++;
	for(fl = inf.fns; fl != nil; fl = tl fl) {
		(name, fnode) := hd fl;
		a := intern(name);
		ev(fnode);
		f := regv();
		(found, nil, at) := getown(global, a);
		if(!found || (at & Aconf))
			defineorthrow(global, a, ref Desc(Dvalue|Dwrite|Denum|Dconf, f, Awrite|Aenum, nil, nil));
		else
			defineorthrow(global, a, ref Desc(Dvalue, f, 0, nil, nil));
		markglobalvar(a);
	}
	for(vl = inf.vars; vl != nil; vl = tl vl) {
		a := intern(hd vl);
		if(!hasown(global, a))
			defineorthrow(global, a, ref Desc(Dvalue|Dwrite|Denum|Dconf, undef, Awrite|Aenum, nil, nil));
		markglobalvar(a);
	}
}

globalvars: list of int;

markglobalvar(a: int)
{
	globalvars = a :: globalvars;
}

isglobalvar(a: int): int
{
	for(l := globalvars; l != nil; l = tl l)
		if(hd l == a)
			return 1;
	return 0;
}

# ---- properties ----

# a property read missing the cache: look it up, and fill the cache for next time
getslow(n: int, o: ref Obj)
{
	k := nb[n];
	if(o.cls == Carray && k == a_length) {
		setr(arrlenv(o));
		return;
	}
	# own data property: cache it
	if(o.cls == Cplain || o.cls == Cfunc || o.cls == Carray && atomidx[k] == -1 || o.cls == Cerror) {
		if(o.cls == Cfunc && k == a_prototype && (o.flags & Flazyproto))
			mkproto(o);
		s := slotof(o.sh, k);
		if(s >= 0) {
			if((o.sh.attrs[s] & Aacc) == 0) {
				icsh[n] = o.sh;
				icslot[n] = s;
				icobj[n] = nil;
				setr(o.slots[s]);
				return;
			}
		} else if(!o.sh.dict && !(o.cls == Carray && atomidx[k] != -1)) {
			# on a prototype: cache the holder while no prototype changes
			for(p := o.sh.proto; p != nil; p = p.sh.proto) {
				if(p.cls != Cplain && p.cls != Cfunc && p.cls != Carray && p.cls != Cerror || p.cls == Carray && k == a_length)
					break;
				if(p.cls == Cfunc && k == a_prototype && (p.flags & Flazyproto))
					break;
				ps := slotof(p.sh, k);
				if(ps >= 0) {
					if((p.sh.attrs[ps] & Aacc) == 0) {
						icsh[n] = o.sh;
						icslot[n] = ps;
						icobj[n] = p;
						icep[n] = protoepoch;
						setr(p.slots[ps]);
						return;
					}
					break;
				}
			}
		}
	}
	setr(get(o, k, objv(o)));
}

getprim(n: int)
{
	v := regv();
	setr(getvalue(v, nb[n]));
}

setprim(n: int)
{
	v := regv();
	push(v);
	ev(nc[n]);
	x := regv();
	setvalue(vstk[vsp-1], nb[n], x, nd[n]);
	pop();
	setr(x);
}

setslow(n: int, o: ref Obj)
{
	k := nb[n];
	v := regv();
	# an add the cache knows
	if(o.sh == icsh[n] && icobj[n] != nil && icep[n] == protoepoch && (o.flags & Fext)) {
		pick d := icobj[n].data {
		Shape =>
			ns := d.sh;
			s := ns.n - 1;
			if(o.slots == nil || s >= len o.slots) {
				m := 2 * s;
				if(m < 4)
					m = 4;
				a := array[m] of V;
				if(o.slots != nil)
					a[0:] = o.slots[0:s];
				o.slots = a;
			}
			o.sh = ns;
			o.slots[s] = v;
			if(o.flags & Fproto)
				protoepoch++;
			return;
		}
	}
	if(o.cls == Cplain || o.cls == Cfunc && k != a_prototype || o.cls == Cerror) {
		s := slotof(o.sh, k);
		if(s >= 0) {
			if((o.sh.attrs[s] & (Aacc|Awrite)) == Awrite) {
				o.slots[s] = v;
				icsh[n] = o.sh;
				icslot[n] = s;
				icobj[n] = nil;
				return;
			}
		} else if(!o.sh.dict && (o.flags & Fext) && !protoblocks(o, k)) {
			old := o.sh;
			addprop(o, k, Adefault, v);
			if(!o.sh.dict && o.sh != old) {
				icsh[n] = old;
				icobj[n] = shapebox(o.sh);
				icep[n] = protoepoch;
			}
			return;
		}
	}
	if(!put(o, k, v, objv(o)) && nd[n])
		throwtype("Cannot assign to read only property '" + keyname(k) + "' of object");
	setr(v);
}

# whether something on o's prototype chain decides an assignment of k (a setter, read-only, an exotic)
protoblocks(o: ref Obj, k: int): int
{
	for(p := o.sh.proto; p != nil; p = p.sh.proto) {
		if(p.cls != Cplain && p.cls != Cfunc && p.cls != Carray && p.cls != Cerror && p.cls != Cbool && p.cls != Cnum && p.cls != Cdate && p.cls != Cregexp && p.cls != Cmap && p.cls != Cset && p.cls != Cpromise)
			return 1;
		if(p.cls == Carray && (k == a_length || atomidx[k] != -1))
			return 1;
		s := slotof(p.sh, k);
		if(s >= 0)
			return (p.sh.attrs[s] & (Aacc|Awrite)) != Awrite;
	}
	return 0;
}

# a shape kept in an Obj, for the cache's slot that holds objects
shapebox(sh: ref Shape): ref Obj
{
	o := ref Obj;
	o.cls = -1;
	o.data = ref Data.Shape(sh);
	return o;
}

getelem(n: int)
{
	ev(na[n]);
	getelem2(n);
}

# the object is in the registers
getelem2(n: int)
{
	if(rt == Tobj) {
		o := ro;
		k := nb[n];
		case op[k] {
		Nint =>
			ri = na[k];
			rt = Tint;
		Nlocal =>
			s := na[k];
			f := fr;
			t := f[s].t;
			rt = t;
			if(t <= Tint)
				ri = f[s].i;
			else if(t == Tnum)
				rn = f[s].n;
			else if(t == Tstr)
				rs = f[s].s;
			else {
				ro = f[s].o;
				ri = f[s].i;
			}
		* =>
			sv := regv();
			push(sv);
			ev(k);
			pop();
		}
		if(rt == Tint && ri >= 0) {
			i := ri;
			if(o.cls == Carray && (o.flags & Fslow) == 0 && i < len o.elems) {
				a := o.elems;
				t := a[i].t;
				if(t != Thole) {
					rt = t;
					if(t <= Tint)
						ri = a[i].i;
					else if(t == Tnum)
						rn = a[i].n;
					else if(t == Tstr)
						rs = a[i].s;
					else {
						ro = a[i].o;
						ri = a[i].i;
					}
					return;
				}
			}
			if(o.cls == Ctyped) {
				setr(typedget(o, i));
				return;
			}
			setr(getidx(o, i, objv(o)));
			return;
		}
		kv := regv();
		if(kv.t == Tnum && o.cls == Ctyped) {
			setr(typedgetnum(o, kv.n));
			return;
		}
		setr(get(o, tokey(kv), objv(o)));
		return;
	}
	# a primitive: strings' characters quickly
	v := regv();
	push(v);
	ev(nb[n]);
	v = vstk[vsp-1];
	pop();
	if(v.t == Tstr && rt == Tint && ri >= 0 && ri < len v.s) {
		i := ri;
		rt = Tstr;
		rs = v.s[i:i+1];
		return;
	}
	if(v.t == Tundef || v.t == Tnull) {
		kv := regv();
		throwtype(sys->sprint("Cannot read properties of %s (reading '%s')", typename(v), showkey(kv)));
	}
	k := tokey(regv());
	setr(getvalue(v, k));
}

setelemnode(n: int)
{
	ev(na[n]);
	if(rt != Tobj) {
		setelemprim(n);
		return;
	}
	o := ro;
	push(regv());
	ev(nb[n]);
	if(rt == Tint && ri >= 0) {
		i := ri;
		ev(nc[n]);
		pop();
		if(o.cls == Carray && (o.flags & Fslow) == 0 && i < len o.elems && o.elems[i].t != Thole) {
			a := o.elems;
			t := rt;
			a[i].t = t;
			if(t <= Tint)
				a[i].i = ri;
			else if(t == Tnum)
				a[i].n = rn;
			else if(t == Tstr)
				a[i].s = rs;
			else {
				a[i].o = ro;
				a[i].i = ri;
			}
			return;
		}
		v := regv();
		if(setelem(o, i, v))
			return;
		if(o.cls == Ctyped) {
			typedset(o, i, v);
			setr(v);
			return;
		}
		if(!put(o, idxatom(i), v, objv(o)) && nd[n])
			throwtype("Cannot assign to read only property '" + string i + "' of object");
		setr(v);
		return;
	}
	kv := regv();
	if(kv.t == Tnum && o.cls == Ctyped) {
		push(kv);
		ev(nc[n]);
		kv = vstk[vsp-1];
		pop();
		pop();
		v := regv();
		typedsetnum(o, kv.n, v);
		setr(v);
		return;
	}
	push(kv);
	ev(nc[n]);
	kv = vstk[vsp-1];
	pop();
	pop();
	v := regv();
	k := tokey(kv);
	if(!put(o, k, v, objv(o)) && nd[n])
		throwtype("Cannot assign to read only property '" + keyname(k) + "' of object");
	setr(v);
}

# a primitive base: the key and the value evaluated before the base is refused or the key converted
setelemprim(n: int)
{
	v := regv();
	push(v);
	ev(nb[n]);
	pushr();
	ev(nc[n]);
	x := regv();
	kv := vstk[vsp-1];
	pop();
	v = vstk[vsp-1];
	pop();
	if(v.t == Tundef || v.t == Tnull)
		throwtype(sys->sprint("Cannot set properties of %s (setting '%s')", typename(v), showkey(kv)));
	k := tokey(kv);
	setvalue(v, k, x, nd[n]);
	setr(x);
}

# o.k op= v
memop(n: int)
{
	ev(na[n]);
	o := regv();
	push(o);
	k := nb[n];
	cur := getvalue(o, k);
	push(cur);
	ev(nc[n]);
	cur = vstk[vsp-1];
	pop();
	r := binv(nd[n] >> 1, cur, regv());
	setvalue(vstk[vsp-1], k, r, nd[n] & 1);
	pop();
	setr(r);
}

elemop(n: int)
{
	ev(na[n]);
	o := regv();
	push(o);
	ev(nb[n]);
	if(o.t == Tundef || o.t == Tnull)
		throwtype(sys->sprint("Cannot read properties of %s", typename(o)));
	k := tokey(regv());
	cur := getvalue(o, k);
	push(cur);
	ev(nc[n]);
	cur = vstk[vsp-1];
	pop();
	r := binv(nd[n] >> 1, cur, regv());
	setvalue(vstk[vsp-1], k, r, nd[n] & 1);
	pop();
	setr(r);
}

memlog(n: int)
{
	ev(na[n]);
	o := regv();
	push(o);
	k: int;
	if(op[n] == Nmemlog)
		k = nb[n];
	else {
		ev(nb[n]);
		if(o.t == Tundef || o.t == Tnull)
			throwtype(sys->sprint("Cannot read properties of %s", typename(o)));
		k = tokey(regv());
	}
	cur := getvalue(o, k);
	go: int;
	case nd[n] >> 1 {
	0 => go = tobool(cur);
	1 => go = !tobool(cur);
	* => go = cur.t == Tundef || cur.t == Tnull;
	}
	if(!go) {
		pop();
		setr(cur);
		return;
	}
	ev(nc[n]);
	r := regv();
	if(r.t == Tobj && r.o.fun != nil && iscompanon(nc[n]))
		setfnname(r.o, k, nil);
	setvalue(vstk[vsp-1], k, r, nd[n] & 1);
	pop();
	setr(r);
}

# whether node n is an anonymous function or class expression (named by what it is assigned to)
iscompanon(n: int): int
{
	if(op[n] == Nfunc)
		return codes[na[n]].name == nil;
	return 0;
}

incv(v: V, delta: int): V
{
	if(v.t == Tint) {
		x := v.i;
		y := x + delta;
		if(((x ^ y) & (delta ^ y)) >= 0)
			return intv(y);
		return V(Tnum, 0, real x + real delta, nil, nil);
	}
	if(v.t == Tbig)
		return bigop(Nadd, v.o, bigfromint(delta).o);
	return V(Tnum, 0, numof(v) + real delta, nil, nil);
}

updvar(n: int)
{
	ev(na[n]);
	old := tonumeric(regv());
	nv := incv(old, nc[n]);
	push(nv);
	ev(nb[n]);
	pop();
	if(nd[n])
		setr(old);
	else
		setr(nv);
}

updmem(n: int)
{
	ev(na[n]);
	o := regv();
	push(o);
	k: int;
	if(op[n] == Nupdmem)
		k = nb[n];
	else {
		ev(nb[n]);
		if(o.t == Tundef || o.t == Tnull)
			throwtype(sys->sprint("Cannot read properties of %s", typename(o)));
		k = tokey(regv());
	}
	old := tonumeric(getvalue(o, k));
	nv := incv(old, nc[n]);
	setvalue(vstk[vsp-1], k, nv, nd[n] >> 1);
	pop();
	if(nd[n] & 1)
		setr(old);
	else
		setr(nv);
}

# ---- calls ----

calleename(n: int): string
{
	case op[n] {
	Nglobal or Ndyn =>
		return atomstr[na[n]];
	Nget or Ngetopt =>
		return calleename(na[n]) + "." + atomstr[nb[n]];
	Nlocal or Nlocalchk or Nenv or Nenvchk or Nglex =>
		return "(local)";
	}
	return "expression";
}

notfunc(n: int)
{
	throwtype(calleename(n) + " is not a function");
}

# o.m(args): the method found through the cache when it can be
callm(n: int)
{
	ev(na[n]);
	if(rt == Tobj) {
		o := ro;
		f: ref Obj;
		if(o.sh == icsh[n]) {
			h := icobj[n];
			if(h == nil)
				h = o;
			else if(icep[n] != protoepoch)
				h = nil;
			if(h != nil) {
				s := icslot[n];
				if(h.slots[s].t == Tobj)
					f = h.slots[s].o;
			}
		}
		if(f == nil) {
			getslow(n, o);
			if(rt != Tobj || ro.fun == nil) {
				if(ne[n] & Fopt && (rt == Tundef || rt == Tnull))
					raise "JSopt";
				throwtype(calleename(na[n]) + "." + atomstr[nb[n]] + " is not a function");
			}
			f = ro;
		}
		if(f.fun == nil)
			throwtype(calleename(na[n]) + "." + atomstr[nb[n]] + " is not a function");
		callf(f, Tobj, o, nc[n], nd[n], ne[n]);
		return;
	}
	if((rt == Tundef || rt == Tnull) && (ne[n] & Fobjopt))
		raise "JSopt";
	this := regv();
	f := getvalue(this, nb[n]);
	if(f.t != Tobj || f.o.fun == nil) {
		if(ne[n] & Fopt && (f.t == Tundef || f.t == Tnull))
			raise "JSopt";
		throwtype(showv(this) + "." + atomstr[nb[n]] + " is not a function");
	}
	callval(f, this, nc[n], nd[n], ne[n]);
}

callelem(n: int)
{
	ev(na[n]);
	if((rt == Tundef || rt == Tnull) && (ne[n] & Fobjopt))
		raise "JSopt";
	this := regv();
	push(this);
	ev(nb[n]);
	if(this.t == Tundef || this.t == Tnull)
		throwtype(sys->sprint("Cannot read properties of %s (reading '%s')", typename(this), showkey(regv())));
	k := tokey(regv());
	f := getvalue(this, k);
	pop();
	if(f.t != Tobj || f.o.fun == nil) {
		if(ne[n] & Fopt && (f.t == Tundef || f.t == Tnull))
			raise "JSopt";
		throwtype(showv(this) + "[" + keyname(k) + "] is not a function");
	}
	callval(f, this, nc[n], nd[n], ne[n]);
}

callval(f, this: V, ks, k, flags: int)
{
	if(f.t != Tobj || f.o.fun == nil) {
		if(flags & Fopt && (f.t == Tundef || f.t == Tnull))
			raise "JSopt";
		throwtype(showv(f) + " is not a function");
	}
	if(this.t == Tobj)
		callf(f.o, Tobj, this.o, ks, k, flags);
	else {
		args := evargs(ks, k, flags);
		setr(callobj(f.o, this, args));
	}
}

# call f with this (an object or undefined) and the arguments the nodes in kids give
callf(f: ref Obj, tt: int, dst: ref Obj, ks, k, flags: int)
{
	c := f.fun.code;
	if(c != nil && (c.flags & (Cgen|Casync|Cclassctor)) == 0 && (flags & Fspr) == 0) {
		npos := c.npos;
		extra := k - npos;
		if(extra < 0)
			extra = 0;
		nfr := array[c.nframe + extra] of V;
		if(tt == Tobj) {
			nfr[0].t = Tobj;
			nfr[0].o = dst;
		}
		for(i := 0; i < k; i++) {
			ev(kids[ks + i]);
			s := 1 + i;
			if(i >= npos)
				s = c.nframe + i - npos;
			t := rt;
			nfr[s].t = t;
			if(t <= Tint)
				nfr[s].i = ri;
			else if(t == Tnum)
				nfr[s].n = rn;
			else if(t == Tstr)
				nfr[s].s = rs;
			else {
				nfr[s].o = ro;
				nfr[s].i = ri;
			}
		}
		runcode(f, c, nfr, k, nil);
		return;
	}
	if(f.fun.native > 0 && (flags & Fspr) == 0) {
		# natives take their arguments as an array
		args := array[k] of V;
		push(V(tt, 0, 0.0, nil, dst));
		for(i := 0; i < k; i++) {
			ev(kids[ks + i]);
			args[i] = regv();
		}
		this := vstk[vsp-1];
		pop();
		setr(callnative(f, this, args, nil));
		return;
	}
	push(V(tt, 0, 0.0, nil, dst));
	args := evargs(ks, k, flags);
	this := vstk[vsp-1];
	pop();
	setr(callobj(f, this, args));
}

# the argument list the nodes give, spreading what is spread
evargs(ks, k, flags: int): array of V
{
	if((flags & Fspr) == 0) {
		args := array[k] of V;
		for(i := 0; i < k; i++) {
			ev(kids[ks + i]);
			args[i] = regv();
		}
		return args;
	}
	l: list of V;
	m := 0;
	for(i := 0; i < k; i++) {
		c := kids[ks + i];
		if(op[c] == Nspread) {
			ev(na[c]);
			vals := iterlist(regv());
			for(j := 0; j < len vals; j++) {
				l = vals[j] :: l;
				m++;
			}
		} else {
			ev(c);
			l = regv() :: l;
			m++;
		}
	}
	args := array[m] of V;
	for(i = m - 1; i >= 0; i--) {
		args[i] = hd l;
		l = tl l;
	}
	return args;
}

# run code c as the function f, its frame made
runcode(f: ref Obj, c: ref Code, nfr: array of V, nargs: int, nt: ref Obj)
{
	if(++depth > maxdepth) {
		depth--;
		throwerr(ERange, "Maximum call stack size exceeded");
	}
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	fr = nfr;
	env = f.env;
	curfn = f;
	newt = nt;
	argc = nargs;
	if((c.flags & (Cstrict|Carrow)) == 0) {
		t := nfr[0].t;
		if(t != Tobj) {
			if(t == Tundef || t == Tnull)
				nfr[0] = globalthis;
			else
				nfr[0] = objv(toobj(nfr[0]));
		}
	}
	if(c.prologue >= 0)
		ev(c.prologue);
	ev(c.body);
	if(ctl == Cret)
		ctl = 0;
	else
		rt = Tundef;
	fr = sfr;
	env = senv;
	curfn = sfn;
	newt = snt;
	argc = sargc;
	depth--;
}

# [[Call]]: f(this, args), the result returned
callobj(f: ref Obj, this: V, args: array of V): V
{
	fnv := f.fun;
	if(fnv == nil) {
		if(f.cls == Cproxy)
			return pxcall(f, this, args);
		throwtype("not a function");
	}
	if(fnv.native > 0)
		return callnative(f, this, args, nil);
	c := fnv.code;
	if(c.flags & Cclassctor)
		throwtype("Class constructor " + c.name + " cannot be invoked without 'new'");
	if(c.flags & (Cgen|Casync))
		return callgen(f, c, this, args);
	nfr := mkframe(c, this, args);
	runcode(f, c, nfr, len args, nil);
	return regv();
}

# call, for the built-ins: f must be callable
call(f: ref Obj, this: V, args: array of V): V
{
	if(args == nil)
		args = array[0] of V;
	return callobj(f, this, args);
}

call1(f: V, this: V, args: array of V): V
{
	if(f.t != Tobj || f.o.fun == nil)
		throwtype(showv(f) + " is not a function");
	return call(f.o, this, args);
}

mkframe(c: ref Code, this: V, args: array of V): array of V
{
	k := len args;
	npos := c.npos;
	extra := k - npos;
	if(extra < 0)
		extra = 0;
	nfr := array[c.nframe + extra] of V;
	nfr[0] = this;
	for(i := 0; i < k; i++) {
		if(i < npos)
			nfr[1 + i] = args[i];
		else
			nfr[c.nframe + i - npos] = args[i];
	}
	return nfr;
}

# the arguments a function was called with, from its frame
argsof(): array of V
{
	c := curfn.fun.code;
	a := array[argc] of V;
	for(i := 0; i < argc; i++)
		if(i < c.npos)
			a[i] = fr[1 + i];
		else
			a[i] = fr[c.nframe + i - c.npos];
	return a;
}

mkargs(mapped: int): ref Obj
{
	o := newobj(Cargs, objproto);
	c := curfn.fun.code;
	a := argsof();
	o.slots = array[len a + 3] of V;
	for(i := 0; i < len a; i++)
		addprop(o, idxatom(i), Adefault, a[i]);
	addprop(o, a_length, Awrite|Aconf, intv(len a));
	addprop(o, a_symiterator, Awrite|Aconf, getv(arrproto, a_values));
	if(mapped) {
		m := array[len a] of {* => -1};
		# the parameters by position, the later of two with one name; a captured one is in the env
		for(i = 0; i < len a && i < c.npos; i++)
			m[i] = 1 + i;
		for(i = 0; i < len a && i < c.npos; i++) {
			s := envslotofparam(c, i);
			if(s >= 0)
				m[i] = -s - 2;
		}
		if(c.dupparams != nil)
			for(i = 0; i < len a && i < len c.dupparams; i++)
				if(c.dupparams[i])
					m[i] = -1;
		o.data = ref Data.Args(fr, env, m);
		o.flags |= Fmapped;
		addprop(o, a_callee, Awrite|Aconf, objv(curfn));
	} else
		addprop(o, a_callee, Aacc, objv(newacc(throwerfn, throwerfn)));
	return o;
}

# where parameter i of the running function lives in its env, or -1
envslotofparam(c: ref Code, i: int): int
{
	if(c.paramenv == nil || i >= len c.paramenv)
		return -1;
	return c.paramenv[i];
}

mkrest(from: int): ref Obj
{
	a := argsof();
	if(from >= len a)
		return newarray(0);
	return mkarray(a[from:]);
}

# ---- construction ----

construct(f: ref Obj, args: array of V, nt: ref Obj): V
{
	if(f.cls == Cproxy)
		return pxconstruct(f, args, nt);
	fnv := f.fun;
	if(fnv.native > 0)
		return callnative(f, undef, args, nt);
	if(f.data != nil)
	pick b := f.data {
	Bound =>
		if(nt == f)
			nt = b.target;
		a := array[len b.args + len args] of V;
		a[0:] = b.args;
		a[len b.args:] = args;
		return construct(b.target, a, nt);
	}
	c := fnv.code;
	if(c.flags & Cderived) {
		if(c.body < 0) {
			# the default constructor: super(...args)
			parent := getprotoof(f);
			if(parent == nil || !isctor(parent))
				throwtype("Super constructor is not a constructor");
			r := construct(parent, args, nt);
			initfields(f, r.o);
			return r;
		}
		nfr := mkframe(c, holev, args);
		runcode2(f, c, nfr, len args, nt);
		if(rt == Tobj)
			return regv();
		if(rt != Tundef)
			throwtype("Derived constructors may only return object or undefined");
		v := lastthis;
		if(v.t == Thole)
			throwerr(ERef, "Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
		return v;
	}
	proto := protofromctor(nt, objproto);
	this := newobj(Cplain, proto);
	if(c.flags & Cclassctor)
		initfields(f, this);
	if(c.body < 0)
		return objv(this);
	nfr := mkframe(c, objv(this), args);
	runcode(f, c, nfr, len args, nt);
	if(rt == Tobj)
		return regv();
	return objv(this);
}

lastthis: V;

# runcode, then (for a derived constructor) read this before the frame goes
runcode2(f: ref Obj, c: ref Code, nfr: array of V, nargs: int, nt: ref Obj)
{
	if(++depth > maxdepth) {
		depth--;
		throwerr(ERange, "Maximum call stack size exceeded");
	}
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	fr = nfr;
	env = f.env;
	curfn = f;
	newt = nt;
	argc = nargs;
	if(c.prologue >= 0)
		ev(c.prologue);
	ev(c.body);
	if(ctl == Cret)
		ctl = 0;
	else
		rt = Tundef;
	r := regv();
	if(r.t != Tobj) {
		ev(c.thisnode);
		lastthis = regv();
	}
	setr(r);
	fr = sfr;
	env = senv;
	curfn = sfn;
	newt = snt;
	argc = sargc;
	depth--;
}

supercall(n: int)
{
	inf: ref Info.Super;
	pick s := infos[nd[n]] {
	Super =>
		inf = s;
	}
	ev(inf.fun);
	f := ro;
	parent := getprotoof(f);
	ev(inf.nt);
	nt := regv();
	args := evargs(na[n], nb[n], nc[n]);
	if(parent == nil || !isctor(parent))
		throwtype("Super constructor " + showv(objv(parent)) + " of anonymous class is not a constructor");
	r := construct(parent, args, nt.o);
	ev(inf.this);
	if(rt != Thole)
		throwerr(ERef, "Super constructor may only be called once");
	push(r);
	ev(inf.thisset);
	pop();
	initfields(f, r.o);
	setr(r);
}

# ---- closures ----

closure(c: ref Code, e: ref Env): ref Obj
{
	o := ref Obj;
	o.cls = Cfunc;
	o.fun = c.fun;
	o.env = e;
	fl := c.flags;
	if(fl & (Cgen|Casync)) {
		if((fl & (Cgen|Casync)) == (Cgen|Casync))
			o.sh = emptyshape(asyncgenfuncproto);
		else if(fl & Cgen)
			o.sh = emptyshape(genfuncproto);
		else
			o.sh = emptyshape(asyncfuncproto);
		o.flags = Fext;
		if(fl & Cgen)
			o.flags |= Flazyproto;
	} else {
		o.sh = emptyshape(funcproto);
		o.flags = Fext;
		if((fl & (Carrow|Cmethod)) == 0) {
			o.flags |= Fctor | Flazyproto;
		}
	}
	o.slots = array[3] of V;
	o.sh = addkey(addkey(o.sh, a_length, Aconf), a_name, Aconf);
	o.slots[0] = intv(c.length);
	if(c.name != nil)
		o.slots[1] = strv(c.name);
	else
		o.slots[1] = strv("");
	return o;
}

# a function's prototype object, made when first wanted
mkproto(f: ref Obj)
{
	f.flags &= ~Flazyproto;
	c := f.fun.code;
	p: ref Obj;
	if(c != nil && (c.flags & Cgen)) {
		if(c.flags & Casync)
			p = newobj(Cplain, asyncgenproto);
		else
			p = newobj(Cplain, genproto);
		addprop(f, a_prototype, Awrite, objv(p));
		return;
	}
	p = plainobj();
	addprop(p, a_constructor, Awrite|Aconf, objv(f));
	addprop(f, a_prototype, Awrite, objv(p));
}

sethome(f: ref Obj, home: ref Obj)
{
	if(f.data != nil)
	pick d := f.data {
	Func =>
		d.home = home;
		return;
	}
	f.data = ref Data.Func(home, nil, nil);
}

# SetFunctionName
setfnname(f: ref Obj, k: int, prefix: string)
{
	name: string;
	if(atomsym[k] != nil) {
		pick d := atomsym[k].data {
		Sym =>
			if(atomsym[k].flags & Fpriv)
				name = d.desc;
			else if(d.hasdesc)
				name = "[" + d.desc + "]";
		}
	} else
		name = atomstr[k];
	if(prefix != nil)
		name = prefix + " " + name;
	s := slotof(f.sh, a_name);
	if(s >= 0 && f.fun != nil && f.fun.code != nil && (f.sh.attrs[s] & Aacc) == 0) {
		cur := f.slots[s];
		if(isstr(cur) && strlenv(cur) == 0 || cur.t == Tundef) {
			f.slots[s] = strv(name);
			return;
		}
		if(isclassctor(f) && f.fun.code.name == nil) {
			f.slots[s] = strv(name);
			return;
		}
		return;
	}
	if(s < 0)
		defprop(f, a_name, strv(name), Aconf);
}

isclassctor(f: ref Obj): int
{
	return f.fun != nil && f.fun.code != nil && (f.fun.code.flags & Cclassctor) != 0;
}

# ---- literals ----

arraylit(n: int)
{
	k := na[n];
	cnt := nb[n];
	if(nc[n] == 0) {
		a := newarray(0);
		push(objv(a));
		el := array[cnt] of V;
		for(i := 0; i < cnt; i++) {
			ev(kids[k + i]);
			el[i] = regv();
		}
		pop();
		if(cnt < 4) {
			a.elems = array[4] of {* => holev};
			a.elems[0:] = el;
		} else
			a.elems = el;
		a.alen = cnt;
		setr(objv(a));
		return;
	}
	a := newarray(0);
	push(objv(a));
	for(i := 0; i < cnt; i++) {
		c := kids[k + i];
		if(c < 0) {
			a.alen++;
			continue;
		}
		if(op[c] == Nspread) {
			ev(na[c]);
			v := regv();
			if(v.t == Tobj && v.o.cls == Carray && arrayiterplain(v.o)) {
				src := v.o;
				for(j := 0; j < src.alen; j++)
					apush(a, getidx(src, j, v));
				continue;
			}
			it := getiterator(v, 0);
			next := getvalue(it, a_next);
			for(;;) {
				r := call1(next, it, nil);
				if(r.t != Tobj)
					throwtype("Iterator result is not an object");
				if(tobool(getv(r.o, a_done)))
					break;
				apush(a, getv(r.o, a_value));
			}
			continue;
		}
		ev(c);
		apush(a, regv());
	}
	pop();
	setr(objv(a));
}

objectlit(n: int)
{
	o := plainobj();
	if(nb[n] > 0)
		o.slots = array[nb[n]] of V;
	push(objv(o));
	k := na[n];
	cnt := nb[n];
	for(i := 0; i < cnt; i++) {
		p := kids[k + i];
		case op[p] {
		Nprop =>
			ev(nb[p]);
			v := regv();
			if(nc[p] & 2)
				sethome(v.o, o);
			a := na[p];
			if(o.sh.dict || slotof(o.sh, a) >= 0 || atomidx[a] != -1)
				createdatathrow(o, a, v);
			else
				addprop(o, a, Adefault, v);
		Npropc =>
			ev(na[p]);
			kv := tokey(regv());
			push(intv(kv));
			ev(nb[p]);
			pop();
			v := regv();
			if(nc[p] & 2)
				sethome(v.o, o);
			if(nc[p] & 1 && v.t == Tobj && v.o.fun != nil)
				setfnname(v.o, kv, nil);
			createdatathrow(o, kv, v);
		Npropget or Npropset =>
			kv := na[p];
			if(kv < 0) {
				ev(nc[p]);
				kv = tokey(regv());
			}
			ev(nb[p]);
			f := ro;
			sethome(f, o);
			if(op[p] == Npropget) {
				setfnname(f, kv, "get");
				defineown(o, kv, ref Desc(Dget|Denum|Dconf, undef, Aenum|Aconf, f, nil));
			} else {
				setfnname(f, kv, "set");
				defineown(o, kv, ref Desc(Dset|Denum|Dconf, undef, Aenum|Aconf, nil, f));
			}
		Npropspread =>
			ev(na[p]);
			copydata(o, regv(), nil);
		Nproto =>
			ev(na[p]);
			if(rt == Tobj)
				setproto(o, ro);
			else if(rt == Tnull)
				setproto(o, nil);
		}
	}
	pop();
	setr(objv(o));
}

# CopyDataProperties: the own enumerable properties of v onto o, but not those excluded
copydata(o: ref Obj, v: V, excluded: list of int)
{
	if(v.t == Tundef || v.t == Tnull)
		return;
	src := toobj(v);
	keys := ownkeys(src);
	for(i := 0; i < len keys; i++) {
		k := keys[i];
		skip := 0;
		for(l := excluded; l != nil; l = tl l)
			if(hd l == k)
				skip = 1;
		if(skip)
			continue;
		d := getowndesc(src, k);
		if(d == nil || (d.attrs & Aenum) == 0)
			continue;
		createdata(o, k, get(src, k, objv(src)));
	}
}

tmplobj(i: int): ref Obj
{
	pick t := infos[i] {
	Tmpl =>
		if(t.obj != nil)
			return t.obj;
		n := len t.raws;
		cooked := newarray(0);
		raw := newarray(0);
		for(j := 0; j < n; j++) {
			if(t.cooked[j] == nil && !iscookedempty(t, j))
				apush(cooked, undef);
			else
				apush(cooked, strv(t.cooked[j]));
			apush(raw, strv(t.raws[j]));
		}
		freeze(raw);
		addprop(cooked, a_raw, 0, objv(raw));
		freeze(cooked);
		t.obj = cooked;
		return cooked;
	}
	return nil;
}

# a cooked string that is nil because it is empty, not because it is invalid
iscookedempty(t: ref Info.Tmpl, j: int): int
{
	return len t.raws[j] == 0 || !hasbadescape(t.raws[j]);
}

hasbadescape(raw: string): int
{
	for(i := 0; i < len raw; i++)
		if(raw[i] == '\\')
			return 1;
	return 0;
}

freeze(o: ref Obj)
{
	if(o.cls == Carray && (o.flags & Fslow) == 0)
		slowarray(o);
	sh := o.sh;
	for(i := 0; i < sh.n; i++) {
		if(sh.keys[i] < 0)
			continue;
		at := sh.attrs[i] & ~Aconf;
		if((at & Aacc) == 0)
			at &= ~Awrite;
		setattrs(o, i, at);
	}
	if(o.cls == Carray)
		o.flags |= Ffrozenlen;
	o.flags &= ~Fext;
}

# ---- destructuring ----

# bind pattern p from the value at the top of the pattern stack
bindpat(p: int)
{
	case op[p] {
	Ppatarr =>
		v := vstk[vsp-1];
		bindarr(p, v);
	Ppatobj =>
		v := vstk[vsp-1];
		if(v.t == Tundef || v.t == Tnull)
			throwtype("Cannot destructure '" + tostr(v) + "' as it is " + typename(v) + ".");
		k := na[p];
		cnt := nb[p];
		used: list of int;
		for(i := 0; i < cnt; i++) {
			c := kids[k + i];
			if(op[c] == Prestobj) {
				r := plainobj();
				copydata(r, v, used);
				push(objv(r));
				bindpat(na[c]);
				pop();
				continue;
			}
			key := na[c];
			if(key < 0) {
				ev(nb[c]);
				key = tokey(regv());
			}
			used = key :: used;
			x := getvalue(v, key);
			push(x);
			bindpat(nc[c]);
			pop();
		}
	Pdefault =>
		v := vstk[vsp-1];
		if(v.t == Tundef) {
			ev(nb[p]);
			d := regv();
			if(d.t == Tobj && d.o.fun != nil && iscompanon(nb[p]))
				;
			push(d);
			bindpat(na[p]);
			pop();
			return;
		}
		bindpat(na[p]);
	Phole =>
		;
	* =>
		# a target: a set node reading the stack's top
		ev(p);
	}
}

bindarr(p: int, v: V)
{
	k := na[p];
	cnt := nb[p];
	# an ordinary array with the ordinary iterator: by index
	if(v.t == Tobj && v.o.cls == Carray && arrayiterplain(v.o)) {
		o := v.o;
		for(i := 0; i < cnt; i++) {
			c := kids[k + i];
			if(op[c] == Prest) {
				r := newarray(0);
				for(j := i; j < o.alen; j++)
					apush(r, getidx(o, j, v));
				push(objv(r));
				bindpat(na[c]);
				pop();
				return;
			}
			x := undef;
			if(i < o.alen)
				x = getidx(o, i, v);
			push(x);
			bindpat(c);
			pop();
			if(!arrayiterplain(o)) {
				# changed while destructuring: the rest by the iterator
				it := getiterator(v, 0);
				pick d := it.o.data {
				Iter =>
					d.i = i + 1;
				}
				bindarriter(p, i + 1, it);
				return;
			}
		}
		return;
	}
	it := getiterator(v, 0);
	bindarriter(p, 0, it);
}

bindarriter(p, from: int, it: V)
{
	k := na[p];
	cnt := nb[p];
	next := getvalue(it, a_next);
	done := 0;
	{
		for(i := from; i < cnt; i++) {
			c := kids[k + i];
			if(op[c] == Prest) {
				r := newarray(0);
				while(!done) {
					x := call1(next, it, nil);
					if(x.t != Tobj) {
						done = 1;
						throwtype("Iterator result is not an object");
					}
					if(tobool(getv(x.o, a_done))) {
						done = 1;
						break;
					}
					apush(r, getv(x.o, a_value));
				}
				push(objv(r));
				bindpat(na[c]);
				pop();
				return;
			}
			x := undef;
			if(!done) {
				r := call1(next, it, nil);
				if(r.t != Tobj) {
					done = 1;
					throwtype("Iterator result is not an object");
				}
				if(tobool(getv(r.o, a_done)))
					done = 1;
				else {
					{
						x = getv(r.o, a_value);
					} exception {
					"JS" =>
						done = 1;
						raise;
					}
				}
			}
			push(x);
			bindpat(c);
			pop();
		}
	} exception {
	"JS" =>
		ex := thrown;
		if(!done)
			iterclose(it, 1);
		throwv(ex);
	}
	if(!done)
		iterclose(it, 0);
}

# ---- classes ----

mkclass(n: int)
{
	inf: ref Info.Class;
	pick c := infos[na[n]] {
	Class =>
		inf = c;
	}
	senv := env;
	if(inf.nenv > 0)
		env = newenv(inf.nenv, inf.sci, env);
	if(inf.entry >= 0)
		ev(inf.entry);
	protoparent := objproto;
	ctorparent := funcproto;
	if(inf.sup >= 0) {
		ev(inf.sup);
		sup := regv();
		if(sup.t == Tnull) {
			protoparent = nil;
		} else {
			if(sup.t != Tobj || !isctor(sup.o))
				throwtype("Class extends value " + showv(sup) + " is not a constructor or null");
			pp := getv(sup.o, a_prototype);
			if(pp.t == Tnull)
				protoparent = nil;
			else if(pp.t == Tobj)
				protoparent = pp.o;
			else
				throwtype("Class extends value does not have valid prototype property");
			ctorparent = sup.o;
		}
	}
	proto := newobj(Cplain, protoparent);
	c := codes[inf.ctor];
	f := closure(c, env);
	f.flags &= ~Flazyproto;
	f.flags |= Fctor;
	setproto(f, ctorparent);
	sethome(f, proto);
	if(inf.name == nil) {
		s := slotof(f.sh, a_name);
		f.slots[s] = strv("");
	}
	addprop(f, a_prototype, 0, objv(proto));
	addprop(proto, a_constructor, Awrite|Aconf, objv(f));
	fields: list of ref Field;
	statics: list of ref Field;
	for(i := 0; i < len inf.members; i++) {
		m := inf.members[i];
		home := proto;
		if(m.static)
			home = f;
		key := m.key;
		privk := -1;
		if(m.priv >= 0) {
			ev(m.priv);
			privk = symatom(ro);
		} else if(m.keynode >= 0) {
			ev(m.keynode);
			key = tokey(regv());
		}
		if(m.isfield) {
			code := codes[m.val];
			fo := closure(code, env);
			sethome(fo, home);
			fld := ref Field(key, undef, privk, 0, env, m.kind == Jsparse->Pblock, 0, fo, nil, nil);
			if(m.kind == Jsparse->Pfield && privk < 0 && key < 0)
				fld.key = -1;
			if(m.static)
				statics = fld :: statics;
			else
				fields = fld :: fields;
			continue;
		}
		ev(m.val);
		mf := ro;
		sethome(mf, home);
		if(privk >= 0) {
			# private methods and accessors
			fld := ref Field(privk, undef, privk, -1, nil, 0, 1, nil, nil, nil);
			pname := atomstr[privk];
			case m.kind {
			Jsparse->Pget =>
				setfnname(mf, privk, "get");
				fld.getter = mf;
			Jsparse->Pset =>
				setfnname(mf, privk, "set");
				fld.setter = mf;
			* =>
				setfnname(mf, privk, nil);
				fld.meth = mf;
			}
			pname = pname;
			if(m.static) {
				addprivmethod(f, fld);
				statics = mergepriv(statics, fld);
			} else
				fields = mergepriv(fields, fld);
			continue;
		}
		case m.kind {
		Jsparse->Pget =>
			setfnname(mf, key, "get");
			defineorthrow(home, key, ref Desc(Dget|Denum|Dconf, undef, Aconf, mf, nil));
		Jsparse->Pset =>
			setfnname(mf, key, "set");
			defineorthrow(home, key, ref Desc(Dset|Denum|Dconf, undef, Aconf, nil, mf));
		* =>
			setfnname(mf, key, nil);
			defineorthrow(home, key, ref Desc(Dvalue|Dwrite|Denum|Dconf, objv(mf), Awrite|Aconf, nil, nil));
		}
	}
	# the instance's fields: private methods first, then the fields in order
	fa := revfields(fields);
	nmeth := 0;
	for(l := fa; l != nil; l = tl l)
		if((hd l).ismethod)
			nmeth++;
	all := array[len fa] of ref Field;
	j := 0;
	for(l = fa; l != nil; l = tl l)
		if((hd l).ismethod)
			all[j++] = hd l;
	for(l = fa; l != nil; l = tl l)
		if(!(hd l).ismethod)
			all[j++] = hd l;
	if(len all > 0) {
		if(f.data != nil)
		pick d := f.data {
		Func =>
			d.fields = all;
		}
	}
	if(inf.nameset >= 0) {
		push(objv(f));
		ev(inf.nameset);
		pop();
	}
	# static fields and blocks, in order, with this the class
	for(l = revfields(statics); l != nil; l = tl l) {
		fld := hd l;
		if(fld.ismethod)
			continue;
		v := call(fld.meth, objv(f), nil);
		if(fld.isblock)
			continue;
		definefield(f, fld, v);
	}
	env = senv;
	setr(objv(f));
}

revfields(l: list of ref Field): list of ref Field
{
	r: list of ref Field;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# a private getter and setter of one name are one field
mergepriv(l: list of ref Field, f: ref Field): list of ref Field
{
	for(x := l; x != nil; x = tl x) {
		g := hd x;
		if(g.ismethod && g.priv == f.priv) {
			if(f.getter != nil)
				g.getter = f.getter;
			if(f.setter != nil)
				g.setter = f.setter;
			return l;
		}
	}
	return f :: l;
}

# the fields of class constructor f defined on o
initfields(f: ref Obj, o: ref Obj)
{
	if(f.data != nil)
	pick d := f.data {
	Func =>
		if(d.fields == nil)
			return;
		for(i := 0; i < len d.fields; i++) {
			fld := d.fields[i];
			if(fld.ismethod) {
				addprivmethod(o, fld);
				continue;
			}
			v := call(fld.meth, objv(o), nil);
			definefield(o, fld, v);
		}
	}
}

definefield(o: ref Obj, fld: ref Field, v: V)
{
	if(fld.priv >= 0) {
		privadd(o, fld.priv, v);
		return;
	}
	if(v.t == Tobj && v.o.fun != nil && fld.meth.fun.code != nil && isanonfield(fld))
		setfnname(v.o, fld.key, nil);
	createdatathrow(o, fld.key, v);
}

isanonfield(nil: ref Field): int
{
	return 0;
}

# ---- private names: properties keyed by a private symbol, out of sight of everything else ----

privget(v: V, k: int): V
{
	if(v.t != Tobj)
		throwtype("Cannot read private member " + atomstr[k] + " from a non-object");
	o := v.o;
	s := slotof(o.sh, k);
	if(s < 0)
		throwtype("Cannot read private member " + atomstr[k] + " from an object whose class did not declare it");
	at := o.sh.attrs[s];
	if(at & Aacc) {
		pick a := o.slots[s].o.data {
		Acc =>
			if(a.get == nil)
				throwtype("'" + atomstr[k] + "' was defined without a getter");
			return call(a.get, v, nil);
		}
	}
	return o.slots[s];
}

privset(v: V, k: int, x: V)
{
	if(v.t != Tobj)
		throwtype("Cannot write private member " + atomstr[k] + " to a non-object");
	o := v.o;
	s := slotof(o.sh, k);
	if(s < 0)
		throwtype("Cannot write private member " + atomstr[k] + " to an object whose class did not declare it");
	at := o.sh.attrs[s];
	if(at & Aacc) {
		pick a := o.slots[s].o.data {
		Acc =>
			if(a.set == nil)
				throwtype("'" + atomstr[k] + "' was defined without a setter");
			call(a.set, v, array[] of {x});
			return;
		}
	}
	if((at & Awrite) == 0)
		throwtype("Private method is not writable");
	o.slots[s] = x;
}

privhas(o: ref Obj, k: int): int
{
	return slotof(o.sh, k) >= 0;
}

privadd(o: ref Obj, k: int, v: V)
{
	if(slotof(o.sh, k) >= 0)
		throwtype("Cannot initialize " + atomstr[k] + " twice on the same object");
	if(o.cls == Cproxy || !privok(o)) {
		;
	}
	privaddslot(o, k, Awrite, v);
}

privok(nil: ref Obj): int
{
	return 1;
}

# a private slot: added even to a non-extensible object
privaddslot(o: ref Obj, k, attrs: int, v: V)
{
	f := o.flags;
	o.flags |= Fext;
	if(o.cls == Cproxy || o.sh == nil)
		;
	addprop(o, k, attrs, v);
	o.flags = f;
}

addprivmethod(o: ref Obj, fld: ref Field)
{
	if(slotof(o.sh, fld.priv) >= 0)
		throwtype("Cannot initialize private methods of class twice on the same object");
	if(fld.meth != nil)
		privaddslot(o, fld.priv, 0, objv(fld.meth));
	else
		privaddslot(o, fld.priv, Aacc, objv(newacc(fld.getter, fld.setter)));
}

# ---- super ----

superbase(inf: ref Info.Super): ref Obj
{
	ev(inf.home);
	if(rt != Tobj)
		throwerr(ESyntax, "'super' keyword unexpected here");
	return getprotoof(ro);
}

superget(n: int)
{
	inf: ref Info.Super;
	pick s := infos[nc[n]] {
	Super =>
		inf = s;
	}
	ev(inf.this);
	this := regv();
	push(this);
	k := na[n];
	if(k < 0) {
		ev(nb[n]);
		kv := regv();
		base := superbase(inf);
		k = tokey(kv);
		pop();
		if(base == nil)
			throwtype("Cannot read properties of null");
		setr(get(base, k, this));
		return;
	}
	base := superbase(inf);
	pop();
	if(base == nil)
		throwtype("Cannot read properties of null (reading '" + atomstr[k] + "')");
	setr(get(base, k, this));
}

superset(n: int)
{
	inf: ref Info.Super;
	pick s := infos[nd[n]] {
	Super =>
		inf = s;
	}
	ev(inf.this);
	this := regv();
	push(this);
	k := na[n];
	kv := undef;
	if(k < 0) {
		ev(nb[n]);
		kv = regv();
	}
	push(kv);
	base := superbase(inf);
	pop();
	if(k < 0)
		k = tokey(kv);
	ev(nc[n]);
	v := regv();
	this = vstk[vsp-1];
	pop();
	if(base == nil)
		throwtype("Cannot set properties of null");
	if(!put(base, k, v, this))
		throwtype("Cannot assign to read only property '" + keyname(k) + "' of object");
	setr(v);
}

# ---- iteration helpers ----

# whether iterating array o by index is what its iterator would do
arrayiterplain(o: ref Obj): int
{
	if(o.sh.proto != arrproto || arrayitermod)
		return 0;
	if(o.sh.n > 0 && slotof(o.sh, a_symiterator) >= 0)
		return 0;
	return 1;
}

arrayitermod := 0;	# Array.prototype[Symbol.iterator] or %ArrayIteratorPrototype%.next were changed

# GetIterator: an iterator object (as a value); async: 1 for an async one
getiterator(v: V, async: int): V
{
	if(async) {
		m := getmethod(v, a_symasynciterator);
		if(m == nil) {
			sm := getmethod(v, a_symiterator);
			if(sm == nil)
				throwtype(showv(v) + " is not async iterable");
			it := call(sm, v, nil);
			if(it.t != Tobj)
				throwtype("Result of the Symbol.iterator method is not an object");
			return objv(asyncfromsync(it));
		}
		it := call(m, v, nil);
		if(it.t != Tobj)
			throwtype("Result of the Symbol.asyncIterator method is not an object");
		return it;
	}
	m := getvalue(v, a_symiterator);
	if(m.t != Tobj || m.o.fun == nil)
		throwtype(showv(v) + " is not iterable");
	it := call(m.o, v, nil);
	if(it.t != Tobj)
		throwtype("Result of the Symbol.iterator method is not an object");
	return it;
}

# IteratorClose: throwing says whether a throw completion is under way (its own errors then lost)
iterclose(it: V, throwing: int)
{
	if(throwing) {
		{
			m := getmethod(it, a_return);
			if(m != nil)
				call(m, it, nil);
		} exception {
		"JS" =>
			;
		}
		return;
	}
	m := getmethod(it, a_return);
	if(m == nil)
		return;
	r := call(m, it, nil);
	if(r.t != Tobj)
		throwtype("Iterator result is not an object");
}

# the values an iterable gives
iterlist(v: V): array of V
{
	if(v.t == Tobj && v.o.cls == Carray && arrayiterplain(v.o)) {
		o := v.o;
		a := array[o.alen] of V;
		for(i := 0; i < o.alen; i++)
			a[i] = getidx(o, i, v);
		return a;
	}
	it := getiterator(v, 0);
	next := getvalue(it, a_next);
	l: list of V;
	n := 0;
	for(;;) {
		r := call1(next, it, nil);
		if(r.t != Tobj)
			throwtype("Iterator result is not an object");
		if(tobool(getv(r.o, a_done)))
			break;
		l = getv(r.o, a_value) :: l;
		n++;
	}
	a := array[n] of V;
	for(i := n - 1; i >= 0; i--) {
		a[i] = hd l;
		l = tl l;
	}
	return a;
}

# ---- running code ----

# run a unit's code (a script, or eval code) with its own frame; this is the global's (or the caller's)
rununit(c: ref Code, this: V, e: ref Env): V
{
	nfr := array[c.nframe] of V;
	nfr[0] = this;
	sfr := fr;
	senv := env;
	sfn := curfn;
	snt := newt;
	sargc := argc;
	scv := cv;
	fr = nfr;
	env = e;
	cv = undef;
	{
		if(c.prologue >= 0)
			ev(c.prologue);
		ev(c.body);
	} exception {
	"JS*" =>
		fr = sfr;
		env = senv;
		curfn = sfn;
		newt = snt;
		argc = sargc;
		cv = scv;
		ctl = 0;
		raise;
	}
	ctl = 0;
	r := cv;
	fr = sfr;
	env = senv;
	curfn = sfn;
	newt = snt;
	argc = sargc;
	cv = scv;
	return r;
}

directeval(n: int)
{
	ev(na[n]);
	f := regv();
	args := evargs(nb[n], nc[n], nd[n]);
	if(f.t != Tobj || f.o != evalfn) {
		# not the eval function: an ordinary call
		if(f.t != Tobj || f.o.fun == nil)
			throwtype("eval is not a function");
		setr(callobj(f.o, undef, args));
		return;
	}
	if(len args == 0 || !isstr(args[0])) {
		if(len args == 0)
			rt = Tundef;
		else
			setr(args[0]);
		return;
	}
	inf: ref Info.Eval;
	pick e := infos[ne[n]] {
	Eval =>
		inf = e;
	}
	src := flat(args[0]);
	privs: list of string;
	for(s := inf.sc; s != nil; s = s.up)
		for(l := s.binds; l != nil; l = tl l)
			if((hd l).kind == Bpriv)
				privs = (hd l).name[1:] :: privs;
	(prog, err) := jsparse->parseeval(src, inf.strict, inf.ctx, privs);
	if(err != nil)
		throwerr(ESyntax, err);
	pick p := prog {
	Program =>
		(pos, msg) := jscheck->checkeval(prog, inf.ctx, privs);
		if(msg != nil)
			throwerr(ESyntax, msg + " at " + string pos);
		(c, cerr) := compilescript(p, src, 1, inf, inf.strict);
		if(cerr != nil)
			throwerr(ESyntax, cerr);
		# the eval code's this is the caller's, found through the scopes
		setr(runevalcode(c));
	}
}

runevalcode(c: ref Code): V
{
	nfr := array[c.nframe] of V;
	sfr := fr;
	senv := env;
	scv := cv;
	fr = nfr;
	cv = undef;
	{
		if(c.prologue >= 0)
			ev(c.prologue);
		ev(c.body);
	} exception {
	"JS*" =>
		fr = sfr;
		env = senv;
		cv = scv;
		raise;
	}
	ctl = 0;
	r := cv;
	fr = sfr;
	env = senv;
	cv = scv;
	return r;
}

# indirect eval, and scripts
evalcode(src: string, iseval: int): V
{
	(prog, err) := jsparse->parse(src, 0, 0);
	if(err != nil)
		throwerr(ESyntax, err);
	pick p := prog {
	Program =>
		(pos, msg) := jscheck->check(prog);
		if(msg != nil)
			throwerr(ESyntax, msg + " at " + string pos);
		(c, cerr) := compilescript(p, src, iseval, nil, 0);
		if(cerr != nil)
			throwerr(ESyntax, cerr);
		return rununit(c, globalthis, nil);
	}
	return undef;
}
