#
# jsvm.b - the interpreter.  Included by js.b.
#
# One loop runs frames on the value stack (vs).  A call from script to
# script pushes a frame and goes on in the same loop; a call to a
# native function is a Limbo call; a native calling back into script
# runs a nested loop, which stops when the frame it began returns.  A
# thrown value is a Limbo exception ("js:throw", the value in thrown):
# the loop catches it, finds the innermost handler in the frames it
# owns, and goes on there, or lets it propagate to whoever called the
# loop.
#

vs: array of V;
sp := 0;

Frame: adt {
	code:	ref Code;
	base:	int;
	pc:	int;
	dst:	int;		# where the caller wants the result (an absolute vs index), or -1
	construct:	int;	# a [[Construct]]: 1 base, 2 derived
	gen:	ref Genstate;	# a generator's or async function's frame
	entry:	int;		# the frame a nested loop began with: its return leaves the loop
};

frames: array of Frame;
nframe := 0;
Maxframes: con 10000;

# the running frame's state, kept in globals for the loop
pc := 0;
base := 0;
ops: array of int;
code: ref Code;

vminit()
{
	vs = array[65536] of V;
	frames = array[256] of Frame;
}

push(v: V)
{
	if(sp >= len vs)
		growvs(sp + 1);
	vs[sp++] = v;
}

growvs(n: int)
{
	if(n < len vs)
		return;
	m := 2 * len vs;
	while(m < n)
		m *= 2;
	if(m > 64 * 1024 * 1024)
		throwerr(RangeError, "maximum call stack size exceeded");
	a := array[m] of V;
	a[0:] = vs[0:sp];
	vs = a;
}

pushframe(f: Frame)
{
	if(nframe == len frames) {
		if(nframe >= Maxframes)
			throwerr(RangeError, "maximum call stack size exceeded");
		a := array[2 * nframe] of Frame;
		a[0:] = frames[0:nframe];
		frames = a;
	}
	frames[nframe++] = f;
}

# ---- calls from Limbo ----

# call f with this and the arguments; the stack is left as it was
call(f, this: V, args: array of V): V
{
	sp0 := sp;
	a := sp;
	for(i := 0; i < len args; i++)
		push(args[i]);
	r := callv(f, this, a, len args, undef);
	sp = sp0;
	return r;
}

construct(f: V, args: array of V, nt: V): V
{
	sp0 := sp;
	a := sp;
	for(i := 0; i < len args; i++)
		push(args[i]);
	r := callv(f, undef, a, len args, nt);
	sp = sp0;
	return r;
}

# [[Call]] (nt undefined) or [[Construct]] (nt the new.target) of f,
# with n arguments at vs[a]
callv(f, this: V, a, n: int, nt: V): V
{
	if(f.t != Tobj || (oflags[f.x] & Ocallable) == 0)
		typeerr(show(f) + " is not a function");
	h := f.x;
	if(nt.t != Tundef && (oflags[h] & Octor) == 0)
		typeerr(show(f) + " is not a constructor");
	case okind[h] {
	Knative =>
		pick d := odata[h] {
		Native =>
			if(sp < a + n)
				sp = a + n;
			return d.f(this, a, n, nt, h);
		}
	Kbound =>
		pick b := odata[h] {
		Bound =>
			na := sp;
			for(i := 0; i < len b.args; i++)
				push(b.args[i]);
			for(i = 0; i < n; i++)
				push(vs[a+i]);
			if(nt.t != Tundef && nt.x == h)
				nt = objv(b.target);
			return callv(objv(b.target), b.this, na, len b.args + n, nt);
		}
	Kproxy =>
		if(nt.t != Tundef)
			return proxyconstruct(h, a, n, nt);
		return proxycall(h, this, a, n);
	Kfunc =>
		pick d := odata[h] {
		Func =>
			c := d.code;
			if(c.flags & Cctor && nt.t == Tundef)
				typeerr("class constructor " + c.name + " cannot be invoked without 'new'");
			if(c.flags & (Cgen|Casync))
				return startgen(h, d, this, a, n);
			nb := sp;
			if(nb < a + n)
				nb = a + n;
			cons := 0;
			if(nt.t != Tundef) {
				if(c.flags & Cderived) {
					this = empty;
					cons = 2;
				} else {
					this = objv(newobj(Kord, protofromctor(nt, iobjproto)));
					cons = 1;
				}
			}
			setupframe(h, d, c, nb, this, a, n, nt);
			pushframe(Frame(c, nb, 0, -1, cons, nil, 1));
			if(cons == 1 && c.flags & Cclassfields)
				initfields(vs[nb+Rthis], h);
			return run();
		}
	}
	typeerr(show(f) + " is not a function");
	return undef;
}

# a script function's frame at nb: this, the function, new.target, its environment, the arguments
setupframe(h: int, d: ref Data.Func, c: ref Code, nb: int, this: V, a, n: int, nt: V)
{
	need := nb + c.nregs + 8;
	if(need > len vs)
		growvs(need);
	if(sp < need)
		;
	if((c.flags & (Cstrict|Carrow)) == 0 && this.t != Tempty) {
		if(this.t == Tundef || this.t == Tnull)
			this = objv(iglobal);
		else if(this.t != Tobj)
			this = objv(toobject(this));
	}
	np := c.nparams;
	# the arguments first: they may be above nb (a native's frame)
	if(c.allreg >= 0) {
		all := array[n] of V;
		for(i := 0; i < n; i++)
			all[i] = vs[a+i];
		for(i = 0; i < np && i < n; i++)
			vs[nb+Rarg0+i] = all[i];
		for(i = n; i < np; i++)
			vs[nb+Rarg0+i] = undef;
		for(i = Rarg0 + np; i < c.nregs; i++)
			vs[nb+i] = undef;
		vs[nb+c.allreg] = objv(arrayof(all));
	} else {
		i: int;
		if(a != nb + Rarg0)
			for(i = 0; i < np && i < n; i++)
				vs[nb+Rarg0+i] = vs[a+i];
		for(i = n; i < np; i++)
			vs[nb+Rarg0+i] = undef;
		for(i = Rarg0 + np; i < c.nregs; i++)
			vs[nb+i] = undef;
	}
	vs[nb+Rthis] = this;
	vs[nb+Rfn] = objv(h);
	vs[nb+Rnewtarget] = nt;
	if(d.env >= 0)
		vs[nb+Renv] = objv(d.env);
	else
		vs[nb+Renv] = undef;
	sp = nb + c.nregs;
}

# ---- the loop ----

# run the top frame until it, the entry, returns; its result
run(): V
{
	return runfrom(0);
}

# run the top frame; how: 0 from its pc, 1 by throwing thrown there, 2 by returning genretval there
runfrom(how: int): V
{
	spc := pc;
	sbase := base;
	scode := code;
	sops := ops;
	entry := nframe - 1;
	resume();
	if(how) {
		# throw (or return) at the frame's current place, before running
		if(how == 2)
			genreturning = 1;
		pc--;	# the resumption point is past the yield or await: it is what throws
		if(!unwind(entry)) {
			pc = spc; base = sbase; code = scode; ops = sops;
			if(genreturning) {
				genreturning = 0;
				return genretval;
			}
			raise "js:throw";
		}
	}
	for(;;) {
		{
			v := loop(entry);
			pc = spc; base = sbase; code = scode; ops = sops;
			return v;
		} exception e {
		"js:throw" =>
			if(!unwind(entry)) {
				pc = spc; base = sbase; code = scode; ops = sops;
				if(genreturning) {
					# a generator's return, through to its end
					genreturning = 0;
					return genretval;
				}
				raise e;
			}
		}
	}
}

# load the frame on top into the loop's globals
resume()
{
	f := frames[nframe-1];
	code = f.code;
	ops = code.ops;
	base = f.base;
	pc = f.pc;
	sp = base + code.nregs;
}

# find a handler for thrown in the frames down to entry; 1 if found
unwind(entry: int): int
{
	frames[nframe-1].pc = pc;
	top := 1;
	while(nframe - 1 >= entry) {
		f := frames[nframe-1];
		c := f.code;
		p := f.pc;
		if(!top)
			p--;	# a caller's pc is past its call: the call is what threw
		top = 0;
		for(i := 0; i < len c.handlers; i++) {
			hh := c.handlers[i];
			if(p >= hh.start && p < hh.end) {
				# a generator's return passes catch handlers by
				if(genreturning && hh.kind == Hcatch)
					continue;
				if(hh.kind == Hclose) {
					if(genreturning) {
						genreturning = 0;
						vs[f.base+hh.reg] = genretval;
						vs[f.base+hh.reg+1] = vtrue;
					} else {
						vs[f.base+hh.reg] = thrown;
						vs[f.base+hh.reg+1] = vfalse;
					}
					frames[nframe-1].pc = hh.target;
					resume();
					return 1;
				}
				if(genreturning) {
					# into the finally block, its completion a return: past its "throw" code
					genreturning = 0;
					vs[f.base+hh.reg] = genretval;
					vs[f.base+hh.reg-1] = num(2.0);
					frames[nframe-1].pc = hh.target + 3;
				} else {
					vs[f.base+hh.reg] = thrown;
					frames[nframe-1].pc = hh.target;
				}
				resume();
				return 1;
			}
		}
		if(nframe - 1 == entry) {
			nframe--;
			if(f.gen != nil)
				f.gen.state = Gdone;
			return 0;
		}
		nframe--;
		if(f.gen != nil)
			f.gen.state = Gdone;
		pc = frames[nframe-1].pc;
		resume();
	}
	return 0;
}

# a finally entered by a generator's return: it must end by returning
pendingreturn(fbase, reg: int)
{
	# the compiled finally tests its completion register (the register before the value)
	vs[fbase+reg-1] = num(2.0);
}

genreturning := 0;
genretval: V;

reg(i: int): V
{
	return vs[base+i];
}

loop(entry: int): V
{
	for(;;) {
		op := ops[pc];
		case op {
		Oundef =>
			vs[base+ops[pc+1]] = undef;
			pc += 2;
		Onull =>
			vs[base+ops[pc+1]] = null;
			pc += 2;
		Otrue =>
			vs[base+ops[pc+1]] = vtrue;
			pc += 2;
		Ofalse =>
			vs[base+ops[pc+1]] = vfalse;
			pc += 2;
		Oempty =>
			vs[base+ops[pc+1]] = empty;
			pc += 2;
		Oint =>
			vs[base+ops[pc+1]] = V(Tnum, 0, real ops[pc+2]);
			pc += 3;
		Oconst =>
			vs[base+ops[pc+1]] = code.consts[ops[pc+2]];
			pc += 3;
		Omove =>
			vs[base+ops[pc+1]] = vs[base+ops[pc+2]];
			pc += 3;
		Ochktdz =>
			if(vs[base+ops[pc+1]].t == Tempty)
				tdzerr(ops[pc+2]);
			pc += 3;
		Ochkthis =>
			if(vs[base+ops[pc+1]].t == Tempty)
				throwerr(ReferenceError, "must call super constructor before accessing 'this'");
			pc += 2;
		Ogetenv =>
			e := envat(ops[pc+2]);
			v := oslots[e][ops[pc+3]];
			if(v.t == Timport)
				v = oslots[v.x][int v.n];
			vs[base+ops[pc+1]] = v;
			pc += 4;
		Ogetenvc =>
			e := envat(ops[pc+2]);
			v := oslots[e][ops[pc+3]];
			if(v.t == Timport)
				v = oslots[v.x][int v.n];
			if(v.t == Tempty)
				tdzerr(ops[pc+4]);
			vs[base+ops[pc+1]] = v;
			pc += 5;
		Osetenv =>
			e := envat(ops[pc+1]);
			oslots[e][ops[pc+2]] = vs[base+ops[pc+3]];
			pc += 4;
		Osetenvc =>
			e := envat(ops[pc+1]);
			if(oslots[e][ops[pc+2]].t == Tempty)
				tdzerr(ops[pc+4]);
			oslots[e][ops[pc+2]] = vs[base+ops[pc+3]];
			pc += 5;
		Opushenv =>
			vs[base+Renv] = objv(newenv(code.scopes[ops[pc+1]], envreg()));
			pc += 2;
		Opopenv =>
			e := envreg();
			vs[base+Renv] = envv(oproto[e]);
			pc += 1;
		Ocopyenv =>
			e := envreg();
			n := newobj(Kenv, oproto[e]);
			s := oslots[e];
			if(s != nil) {
				ns := array[len s] of V;
				ns[0:] = s;
				oslots[n] = ns;
			}
			oshape[n] = oshape[e];
			odata[n] = odata[e];
			vs[base+Renv] = objv(n);
			pc += 1;
		Ogetglobal =>
			vs[base+ops[pc+1]] = getglobal(ops[pc+2], 0);
			pc += 4;
		Otypeofglobal =>
			vs[base+ops[pc+1]] = getglobal(ops[pc+2], 1);
			pc += 3;
		Osetglobal =>
			setglobal(ops[pc+1], vs[base+ops[pc+2]], code.flags & Cstrict);
			pc += 3;
		Oinitglobal =>
			initglobal(ops[pc+1], vs[base+ops[pc+2]]);
			pc += 3;
		Odelglobal =>
			vs[base+ops[pc+1]] = bool(delglobal(ops[pc+2]));
			pc += 3;
		Oglobalinit =>
			globalinit(code.decls[ops[pc+1]], code);
			pc += 2;
		Ogetname =>
			vs[base+ops[pc+1]] = getdyn(ops[pc+2], 0);
			pc += 3;
		Otypeofname =>
			vs[base+ops[pc+1]] = getdyn(ops[pc+2], 1);
			pc += 3;
		Osetname =>
			setdyn(ops[pc+1], vs[base+ops[pc+2]], code.flags & Cstrict, 0);
			pc += 3;
		Oinitname =>
			setdyn(ops[pc+1], vs[base+ops[pc+2]], code.flags & Cstrict, 1);
			pc += 3;
		Odelname =>
			vs[base+ops[pc+1]] = bool(deldyn(ops[pc+2]));
			pc += 3;
		Ocallname =>
			(f, this) := calldyn(ops[pc+3]);
			vs[base+ops[pc+1]] = f;
			vs[base+ops[pc+2]] = this;
			pc += 4;
		Ogetprop =>
			o := vs[base+ops[pc+2]];
			ic := ops[pc+4];
			if(o.t == Tobj && code.ics[ic] == oshape[o.x])
				vs[base+ops[pc+1]] = oslots[o.x][code.icslot[ic]];
			else
				vs[base+ops[pc+1]] = getpropic(o, ops[pc+3], ic);
			pc += 5;
		Osetprop =>
			o := vs[base+ops[pc+1]];
			ic := ops[pc+4];
			if(o.t == Tobj && code.ics[ic] == oshape[o.x])
				oslots[o.x][code.icslot[ic]] = vs[base+ops[pc+3]];
			else
				setpropic(o, ops[pc+2], vs[base+ops[pc+3]], ic);
			pc += 5;
		Ogetelem =>
			vs[base+ops[pc+1]] = getelem(vs[base+ops[pc+2]], vs[base+ops[pc+3]]);
			pc += 4;
		Osetelem =>
			setelem(vs[base+ops[pc+1]], vs[base+ops[pc+2]], vs[base+ops[pc+3]], code.flags & Cstrict);
			pc += 4;
		Odelprop =>
			vs[base+ops[pc+1]] = bool(delv(vs[base+ops[pc+2]], ops[pc+3]));
			pc += 4;
		Odelelem =>
			o := vs[base+ops[pc+2]];
			if(o.t == Tundef || o.t == Tnull)
				typeerr("cannot delete properties of " + show(o));
			k := tokey(vs[base+ops[pc+3]]);
			vs[base+ops[pc+1]] = bool(delv(o, k));
			pc += 4;
		Oin =>
			o := vs[base+ops[pc+3]];
			if(o.t != Tobj)
				typeerr("cannot use 'in' operator to search for a key in " + show(o));
			vs[base+ops[pc+1]] = bool(hasprop(o.x, tokey(vs[base+ops[pc+2]])));
			pc += 4;
		Oadd =>
			a := vs[base+ops[pc+2]];
			b := vs[base+ops[pc+3]];
			if(a.t == Tnum && b.t == Tnum)
				vs[base+ops[pc+1]] = V(Tnum, 0, a.n + b.n);
			else
				vs[base+ops[pc+1]] = add(a, b);
			pc += 4;
		Osub or Omul or Odiv or Omod or Oexp or Oshl or Oshr or Oushr or Oband or Obor or Obxor =>
			a := vs[base+ops[pc+2]];
			b := vs[base+ops[pc+3]];
			if(a.t == Tnum && b.t == Tnum) {
				x := a.n;
				y := b.n;
				case op {
				Osub => vs[base+ops[pc+1]] = V(Tnum, 0, x - y);
				Omul => vs[base+ops[pc+1]] = V(Tnum, 0, x * y);
				Odiv => vs[base+ops[pc+1]] = V(Tnum, 0, x / y);
				Oband or Obor or Obxor or Oshl or Oshr =>
					# small integers, as they nearly always are
					if(x >= -2147483648.0 && x <= 2147483647.0 && y >= -2147483648.0 && y <= 2147483647.0) {
						xi := int x;
						yi := int y;
						if(real xi == x && real yi == y) {
							r: int;
							case op {
							Oband => r = xi & yi;
							Obor => r = xi | yi;
							Obxor => r = xi ^ yi;
							Oshl => r = xi << (yi & 31);
							* => r = xi >> (yi & 31);
							}
							vs[base+ops[pc+1]] = V(Tnum, 0, real r);
							pc += 4;
							continue;
						}
					}
					vs[base+ops[pc+1]] = arith(op, a, b);
				* => vs[base+ops[pc+1]] = arith(op, a, b);
				}
			} else
				vs[base+ops[pc+1]] = arith(op, a, b);
			pc += 4;
		Oeq =>
			vs[base+ops[pc+1]] = bool(looseequal(vs[base+ops[pc+2]], vs[base+ops[pc+3]]));
			pc += 4;
		One =>
			vs[base+ops[pc+1]] = bool(!looseequal(vs[base+ops[pc+2]], vs[base+ops[pc+3]]));
			pc += 4;
		Oseq =>
			vs[base+ops[pc+1]] = bool(strictequal(vs[base+ops[pc+2]], vs[base+ops[pc+3]]));
			pc += 4;
		Osne =>
			vs[base+ops[pc+1]] = bool(!strictequal(vs[base+ops[pc+2]], vs[base+ops[pc+3]]));
			pc += 4;
		Olt or Ole or Ogt or Oge =>
			a := vs[base+ops[pc+2]];
			b := vs[base+ops[pc+3]];
			r: int;
			if(a.t == Tnum && b.t == Tnum) {
				if(isnan(a.n) || isnan(b.n))
					r = 0;
				else case op {
				Olt => r = a.n < b.n;
				Ole => r = a.n <= b.n;
				Ogt => r = a.n > b.n;
				* => r = a.n >= b.n;
				}
			} else {
				case op {
				Olt => r = lessthan(a, b, 1) == 1;
				Ogt => r = lessthan(b, a, 0) == 1;
				Ole => r = lessthan(b, a, 0) == 0;
				* => r = lessthan(a, b, 1) == 0;
				}
			}
			vs[base+ops[pc+1]] = bool(r);
			pc += 4;
		Oinstof =>
			vs[base+ops[pc+1]] = bool(instanceof(vs[base+ops[pc+2]], vs[base+ops[pc+3]]));
			pc += 4;
		Oneg =>
			a := vs[base+ops[pc+2]];
			if(a.t == Tnum)
				vs[base+ops[pc+1]] = V(Tnum, 0, -a.n);
			else {
				n := tonumeric(a);
				if(n.t == Tbig)
					vs[base+ops[pc+1]] = bigneg(n);
				else
					vs[base+ops[pc+1]] = num(-n.n);
			}
			pc += 3;
		Opos =>
			vs[base+ops[pc+1]] = num(tonumber(vs[base+ops[pc+2]]));
			pc += 3;
		Otonumeric =>
			a := vs[base+ops[pc+2]];
			if(a.t != Tnum)
				a = tonumeric(a);
			vs[base+ops[pc+1]] = a;
			pc += 3;
		Onot =>
			vs[base+ops[pc+1]] = bool(!truthy(vs[base+ops[pc+2]]));
			pc += 3;
		Obnot =>
			a := tonumeric(vs[base+ops[pc+2]]);
			if(a.t == Tbig)
				vs[base+ops[pc+1]] = bignot(a);
			else
				vs[base+ops[pc+1]] = num(real ~toint32(a));
			pc += 3;
		Otypeof =>
			vs[base+ops[pc+1]] = V(Tstr, atomsh[intern(typeofv(vs[base+ops[pc+2]]))], 0.0);
			pc += 3;
		Oinc or Odec =>
			a := vs[base+ops[pc+2]];
			d := 1.0;
			if(op == Odec)
				d = -1.0;
			if(a.t == Tnum)
				vs[base+ops[pc+1]] = V(Tnum, 0, a.n + d);
			else
				vs[base+ops[pc+1]] = bigadd(a, bigfromint(int d));
			pc += 3;
		Ojmp =>
			t := ops[pc+1];
			if(t <= pc && gcwanted)
				safepoint(t);
			pc = t;
		Ojt =>
			cv := vs[base+ops[pc+1]];
			if(cv.t == Tbool && cv.x || cv.t != Tbool && truthy(cv)) {
				t := ops[pc+2];
				if(t <= pc && gcwanted)
					safepoint(t);
				pc = t;
			} else
				pc += 3;
		Ojf =>
			cv := vs[base+ops[pc+1]];
			if(cv.t == Tbool && !cv.x || cv.t != Tbool && !truthy(cv))
				pc = ops[pc+2];
			else
				pc += 3;
		Ojnullish =>
			t := vs[base+ops[pc+1]].t;
			if(t == Tundef || t == Tnull)
				pc = ops[pc+2];
			else
				pc += 3;
		Ojnnullish =>
			t := vs[base+ops[pc+1]].t;
			if(t != Tundef && t != Tnull)
				pc = ops[pc+2];
			else
				pc += 3;
		Ojundef =>
			if(vs[base+ops[pc+1]].t == Tundef)
				pc = ops[pc+2];
			else
				pc += 3;
		Ojnundef =>
			if(vs[base+ops[pc+1]].t != Tundef)
				pc = ops[pc+2];
			else
				pc += 3;
		Ocall =>
			dst := base + ops[pc+1];
			f := vs[base+ops[pc+2]];
			this := vs[base+ops[pc+3]];
			a := base + ops[pc+4];
			n := ops[pc+5];
			if(gcwanted)
				safepoint(pc);
			if(f.t == Tobj && okind[f.x] == Kfunc) {
				pick d := odata[f.x] {
				Func =>
					c := d.code;
					if((c.flags & (Cgen|Casync|Cctor)) == 0) {
						frames[nframe-1].pc = pc + 6;
						nb := base + code.nregs;
						setupframe(f.x, d, c, nb, this, a, n, undef);
						pushframe(Frame(c, nb, 0, dst, 0, nil, 0));
						resume();
						continue;
					}
				}
			}
			v := callv(f, this, a, n, undef);
			vs[dst] = v;
			sp = base + code.nregs;
			pc += 6;
		Ocallspread =>
			dst := base + ops[pc+1];
			f := vs[base+ops[pc+2]];
			this := vs[base+ops[pc+3]];
			arr := vs[base+ops[pc+4]];
			a := sp;
			n := pushspread(arr);
			v := callv(f, this, a, n, undef);
			vs[dst] = v;
			sp = base + code.nregs;
			pc += 5;
		Onew =>
			dst := base + ops[pc+1];
			f := vs[base+ops[pc+2]];
			a := base + ops[pc+3];
			n := ops[pc+4];
			if(gcwanted)
				safepoint(pc);
			if(!isctor(f))
				typeerr(show(f) + " is not a constructor");
			v := callv(f, undef, a, n, f);
			vs[dst] = v;
			sp = base + code.nregs;
			pc += 5;
		Onewspread =>
			dst := base + ops[pc+1];
			f := vs[base+ops[pc+2]];
			arr := vs[base+ops[pc+3]];
			if(!isctor(f))
				typeerr(show(f) + " is not a constructor");
			a := sp;
			n := pushspread(arr);
			v := callv(f, undef, a, n, f);
			vs[dst] = v;
			sp = base + code.nregs;
			pc += 4;
		Osupercall or Osupercallspread =>
			dst := base + ops[pc+1];
			a, n, fr, ntr, next: int;
			if(op == Osupercall) {
				a = base + ops[pc+2];
				n = ops[pc+3];
				fr = ops[pc+4];
				ntr = ops[pc+5];
				next = pc + 6;
			} else {
				arr := vs[base+ops[pc+2]];
				fr = ops[pc+3];
				ntr = ops[pc+4];
				next = pc + 5;
				a = sp;
				n = pushspread(arr);
			}
			ffn := vs[base+fr];
			nt := vs[base+ntr];
			sup := getproto(ffn.x);
			if(sup < 0 || !isctor(objv(sup)))
				typeerr("super constructor is not a constructor");
			v := callv(objv(sup), undef, a, n, nt);
			sp = base + code.nregs;
			# bind this, once
			if(code.flags & Carrow)
				;
			else {
				if(vs[base+Rthis].t != Tempty)
					throwerr(ReferenceError, "super constructor may only be called once");
				vs[base+Rthis] = v;
			}
			vs[dst] = v;
			initfields(v, ffn.x);
			pc = next;
		Oeval =>
			dst := base + ops[pc+1];
			f := vs[base+ops[pc+2]];
			a := base + ops[pc+3];
			n := ops[pc+4];
			flags := ops[pc+5];
			v: V;
			if(f.t == Tobj && f.x == ievalfn)
				v = directeval(a, n, flags);
			else
				v = callv(f, undef, a, n, undef);
			vs[dst] = v;
			sp = base + code.nregs;
			pc += 6;
		Oret =>
			v := vs[base+ops[pc+1]];
			f := frames[nframe-1];
			if(f.construct) {
				if(v.t != Tobj) {
					if(f.construct == 2 && v.t != Tundef)
						typeerr("derived constructors may only return object or undefined");
					v = vs[base+Rthis];
					if(v.t == Tempty)
						throwerr(ReferenceError, "must call super constructor before returning from a derived constructor");
				}
			}
			if(f.gen != nil) {
				f.gen.state = Gdone;
				nframe--;
				f.gen.result = v;
				return v;
			}
			nframe--;
			if(f.entry || nframe - 1 < entry)
				return v;
			resume();
			if(f.dst >= 0)
				vs[f.dst] = v;
		Othrow =>
			throwv(vs[base+ops[pc+1]]);
		Othrowerr =>
			throwerr(ops[pc+1], str(code.consts[ops[pc+2]].x));
		Oclosure =>
			vs[base+ops[pc+1]] = objv(closure(code.funcs[ops[pc+2]], envreg()));
			pc += 3;
		Onewobj =>
			vs[base+ops[pc+1]] = objv(newplain());
			pc += 2;
		Onewarr =>
			vs[base+ops[pc+1]] = objv(newarray(0));
			pc += 2;
		Oarrpush =>
			arrpush(vs[base+ops[pc+1]].x, vs[base+ops[pc+2]]);
			pc += 3;
		Oarrhole =>
			h := vs[base+ops[pc+1]].x;
			oalen[h] += 1.0;
			pc += 2;
		Oarrspread =>
			h := vs[base+ops[pc+1]].x;
			frames[nframe-1].pc = pc;
			spreadinto(h, vs[base+ops[pc+2]]);
			pc += 3;
		Odefdata =>
			o := vs[base+ops[pc+1]];
			createdataorthrow(o.x, tokey(vs[base+ops[pc+2]]), vs[base+ops[pc+3]]);
			pc += 4;
		Odefdataa =>
			o := vs[base+ops[pc+1]];
			createdataorthrow(o.x, ops[pc+2], vs[base+ops[pc+3]]);
			pc += 4;
		Odefacc =>
			o := vs[base+ops[pc+1]];
			k := tokey(vs[base+ops[pc+2]]);
			fv := vs[base+ops[pc+3]];
			kind := ops[pc+4];
			d := ref Desc(Hconf|Henum, undef, undef, undef, Aconf);
			if(kind & 4)
				d.attrs |= Aenum;
			if(kind & 1) {
				d.has |= Hget;
				d.get = fv;
			} else {
				d.has |= Hset;
				d.set = fv;
			}
			defineown(o.x, k, d);
			pc += 5;
		Osetproto =>
			o := vs[base+ops[pc+1]];
			p := vs[base+ops[pc+2]];
			if(p.t == Tobj)
				setproto(o.x, p.x);
			else if(p.t == Tnull)
				setproto(o.x, -1);
			pc += 3;
		Ocopyprops =>
			frames[nframe-1].pc = pc;
			copyprops(vs[base+ops[pc+1]].x, vs[base+ops[pc+2]], vs[base+ops[pc+3]]);
			pc += 4;
		Ospreadobj =>
			frames[nframe-1].pc = pc;
			copyprops(vs[base+ops[pc+1]].x, vs[base+ops[pc+2]], undef);
			pc += 3;
		Osetfnname =>
			setfnname(vs[base+ops[pc+1]], vs[base+ops[pc+2]], ops[pc+3]);
			pc += 4;
		Osethome =>
			pick d := odata[vs[base+ops[pc+1]].x] {
			Func =>
				d.home = vs[base+ops[pc+2]].x;
			}
			pc += 3;
		Otemplate =>
			vs[base+ops[pc+1]] = objv(templateobj(code, ops[pc+2]));
			pc += 3;
		Oregexp =>
			(pat, fl) := code.regexps[ops[pc+2]];
			vs[base+ops[pc+1]] = objv(regexpcreate(pat, fl));
			pc += 3;
		Ogetiter =>
			frames[nframe-1].pc = pc;
			r := ops[pc+1];
			(it, next) := getiterator(vs[base+ops[pc+2]], ops[pc+3]);
			vs[base+r] = it;
			vs[base+r+1] = next;
			pc += 4;
		Oiternext =>
			frames[nframe-1].pc = pc;
			it := ops[pc+3];
			(v, done) := iterstep(vs[base+it], vs[base+it+1]);
			if(done)
				vs[base+it+1] = undef;	# exhausted: not to be closed
			vs[base+ops[pc+1]] = v;
			vs[base+ops[pc+2]] = bool(done);
			pc += 4;
		Oiterclose =>
			frames[nframe-1].pc = pc;
			it := ops[pc+1];
			if(vs[base+it+1].t != Tundef)
				iterclose(vs[base+it]);
			vs[base+it+1] = undef;
			pc += 2;
		Oiterdone =>
			# close on a throw completion: the iterator's errors are dropped
			it := ops[pc+1];
			if(vs[base+it+1].t != Tundef) {
				vs[base+it+1] = undef;
				saved := thrown;
				{
					iterclose(vs[base+it]);
				} exception {
				"js:throw" =>
					;
				}
				thrown = saved;
			}
			pc += 2;
		Oforin =>
			frames[nframe-1].pc = pc;
			vs[base+ops[pc+1]] = objv(forinstart(vs[base+ops[pc+2]]));
			pc += 3;
		Oforinnext =>
			frames[nframe-1].pc = pc;
			(k, ok) := forinnext(vs[base+ops[pc+2]].x);
			if(!ok)
				pc = ops[pc+3];
			else {
				vs[base+ops[pc+1]] = k;
				pc += 4;
			}
		Oargs =>
			vs[base+ops[pc+1]] = objv(argsobject(ops[pc+2]));
			pc += 3;
		Orest =>
			all := vs[base+code.allreg].x;
			n := onelem[all];
			from := ops[pc+2];
			r: array of V;
			if(from < n) {
				r = array[n - from] of V;
				r[0:] = oelems[all][from:n];
			}
			vs[base+ops[pc+1]] = objv(arrayof(r));
			pc += 3;
		Oreqobj =>
			v := vs[base+ops[pc+1]];
			if(v.t == Tundef || v.t == Tnull)
				typeerr("cannot destructure " + show(v));
			pc += 2;
		Otokey =>
			frames[nframe-1].pc = pc;
			vs[base+ops[pc+1]] = keyval(tokey(vs[base+ops[pc+2]]));
			pc += 3;
		Otostr =>
			frames[nframe-1].pc = pc;
			v := vs[base+ops[pc+2]];
			if(v.t == Tsym)
				typeerr("cannot convert a Symbol value to a string");
			vs[base+ops[pc+1]] = tostrv(v);
			pc += 3;
		Oconcat =>
			vs[base+ops[pc+1]] = V(Tstr, concat(vs[base+ops[pc+2]].x, vs[base+ops[pc+3]].x), 0.0);
			pc += 4;
		Oyield or Oawait or Oyieldraw =>
			# suspend: the generator's driver gets what is yielded or awaited
			f := frames[nframe-1];
			g := f.gen;
			if(op == Oyieldraw) {
				g.resumereg = ops[pc+1];
				g.modereg = ops[pc+2];
				g.out = vs[base+ops[pc+3]];
				g.raw = (code.flags & Casync) == 0;
				pc += 4;
			} else {
				g.resumereg = ops[pc+1];
				g.modereg = -1;
				g.out = vs[base+ops[pc+2]];
				g.raw = 0;
				pc += 3;
			}
			g.awaiting = op == Oawait;
			g.pc = pc;
			n := code.nregs;
			if(g.regs == nil || len g.regs < n)
				g.regs = array[n] of V;
			g.regs[0:] = vs[base:base+n];
			g.state = Gsuspended;
			nframe--;
			return g.out;
		Ogenstart =>
			pc += 1;
		Oclass =>
			frames[nframe-1].pc = pc;
			(c, p) := classcreate(vs[base+ops[pc+3]], code.funcs[ops[pc+4]], envreg());
			vs[base+ops[pc+1]] = objv(c);
			vs[base+ops[pc+2]] = objv(p);
			pc += 5;
		Odefmethod =>
			frames[nframe-1].pc = pc;
			defmethod(vs[base+ops[pc+1]], vs[base+ops[pc+2]], vs[base+ops[pc+3]], ops[pc+4]);
			pc += 5;
		Ogetsuper =>
			frames[nframe-1].pc = pc;
			k := tokey(vs[base+ops[pc+2]]);
			home := homeof(vs[base+ops[pc+3]]);
			this := vs[base+ops[pc+4]];
			if(this.t == Tempty)
				throwerr(ReferenceError, "must call super constructor before accessing 'this'");
			if(home < 0)
				typeerr("'super' keyword unexpected here");
			p := getproto(home);
			if(p < 0)
				typeerr("cannot read properties of null (super)");
			vs[base+ops[pc+1]] = get(p, k, this);
			pc += 5;
		Osetsuper =>
			frames[nframe-1].pc = pc;
			this := vs[base+ops[pc+4]];
			if(this.t == Tempty)
				throwerr(ReferenceError, "must call super constructor before accessing 'this'");
			k := tokey(vs[base+ops[pc+1]]);
			home := homeof(vs[base+ops[pc+3]]);
			p := getproto(home);
			if(p < 0)
				typeerr("cannot set properties of null (super)");
			if(!set(p, k, vs[base+ops[pc+2]], this) && (code.flags & Cstrict))
				typeerr("cannot assign to read only property '" + keystr(k) + "'");
			pc += 5;
		Onewprivate =>
			a := newsymbol(atomstr[ops[pc+2]], 1);
			atomsym[a] = byte 2;
			vs[base+ops[pc+1]] = V(Tsym, a, 0.0);
			pc += 3;
		Ogetpriv =>
			vs[base+ops[pc+1]] = privget(vs[base+ops[pc+2]], vs[base+ops[pc+3]].x);
			pc += 4;
		Osetpriv =>
			privset(vs[base+ops[pc+1]], vs[base+ops[pc+2]].x, vs[base+ops[pc+3]]);
			pc += 4;
		Odefpriv =>
			privadd(vs[base+ops[pc+1]], vs[base+ops[pc+2]].x, vs[base+ops[pc+3]], Awrite);
			pc += 4;
		Ohaspriv =>
			o := vs[base+ops[pc+3]];
			if(o.t != Tobj)
				typeerr("cannot use 'in' operator to search for a private field in " + show(o));
			vs[base+ops[pc+1]] = bool(privhas(o.x, vs[base+ops[pc+2]].x));
			pc += 4;
		Oprivmethod =>
			privmethod(vs[base+ops[pc+1]], vs[base+ops[pc+2]], vs[base+ops[pc+3]], ops[pc+4]);
			pc += 5;
		Odebugger or Onop =>
			pc += 1;
		Opushwith =>
			frames[nframe-1].pc = pc;
			o := toobject(vs[base+ops[pc+1]]);
			e := newobj(Kenv, envreg());
			odata[e] = ref Data.Env(nil, o);
			vs[base+Renv] = objv(e);
			pc += 2;
		Oimportmeta =>
			vs[base+ops[pc+1]] = importmeta(code);
			pc += 2;
		Ogenret =>
			genretval = vs[base+ops[pc+1]];
			genreturning = 1;
			raise "js:throw";
		Othisdyn =>
			(found, e, slot, nil) := dynfind(intern("%this"));
			if(found && slot >= 0)
				vs[base+ops[pc+1]] = oslots[e][slot];
			else
				vs[base+ops[pc+1]] = vs[base+Rthis];
			pc += 2;
		Omodinit =>
			# a module's instantiation is done: stop here until it is evaluated
			f := frames[nframe-1];
			g := f.gen;
			pc += 1;
			g.resumereg = -1;
			g.modereg = -1;
			g.out = undef;
			g.raw = 0;
			g.awaiting = 0;
			g.pc = pc;
			n := code.nregs;
			if(g.regs == nil || len g.regs < n)
				g.regs = array[n] of V;
			g.regs[0:] = vs[base:base+n];
			g.state = Gsuspended;
			nframe--;
			return undef;
		Oimport =>
			frames[nframe-1].pc = pc;
			vs[base+ops[pc+1]] = dynimport(vs[base+ops[pc+2]], vs[base+ops[pc+3]]);
			pc += 4;
		Olineno =>
			pc += 2;
		Oitercall =>
			it := ops[pc+2];
			next := vs[base+it+1];
			if(next.t == Tundef)
				typeerr("iterator is exhausted");
			vs[base+ops[pc+1]] = call(next, vs[base+it], nil);
			pc += 3;
		Oiterres =>
			r := vs[base+ops[pc+3]];
			if(r.t != Tobj)
				typeerr("iterator result " + show(r) + " is not an object");
			done := truthy(getv(r, adone));
			if(ops[pc+4] < 0)	# yield*: the value either way
				vs[base+ops[pc+1]] = getv(r, avalue);
			else if(done) {
				vs[base+ops[pc+4]+1] = undef;
				vs[base+ops[pc+1]] = undef;
			} else
				vs[base+ops[pc+1]] = getv(r, avalue);
			vs[base+ops[pc+2]] = bool(done);
			pc += 5;
		Oitreturn =>
			it := ops[pc+2];
			r := empty;
			if(vs[base+it+1].t != Tundef) {
				vs[base+it+1] = undef;
				ret := getmethod(vs[base+it], areturn);
				if(ret.t != Tundef)
					r = call(ret, vs[base+it], nil);
			}
			vs[base+ops[pc+1]] = r;
			pc += 3;
		Ojempty =>
			if(vs[base+ops[pc+1]].t == Tempty)
				pc = ops[pc+2];
			else
				pc += 3;
		Oystep =>
			ystep(ops[pc+1], ops[pc+2], ops[pc+3], vs[base+ops[pc+4]], vs[base+ops[pc+5]], code.flags & Casync);
			pc += 6;
		Onewdisp =>
			vs[base+ops[pc+1]] = objv(newarray(0));
			pc += 2;
		Oaddres =>
			addresource(vs[base+ops[pc+1]].x, vs[base+ops[pc+2]], ops[pc+3]);
			pc += 4;
		Odisnext =>
			h := vs[base+ops[pc+2]].x;
			n := onelem[h];
			if(n == 0)
				pc = ops[pc+3];
			else {
				vs[base+ops[pc+1]] = oelems[h][n-1];
				oelems[h][n-1] = empty;
				onelem[h] = n - 1;
				oalen[h] = real (n - 1);
				pc += 4;
			}
		Odiscall =>
			rec := vs[base+ops[pc+2]].x;
			v := oelems[rec][0];
			m := oelems[rec][1];
			r := undef;
			if(m.t != Tundef)
				r = call(m, v, nil);
			if(oelems[rec][2].t == Tbool && oelems[rec][2].x == 0)
				r = undef;	# a sync method's result is not awaited
			vs[base+ops[pc+1]] = r;
			pc += 3;
		Oaccum =>
			e := vs[base+ops[pc+1]];
			x := vs[base+ops[pc+2]];
			if(e.t == Tempty)
				vs[base+ops[pc+1]] = x;
			else
				vs[base+ops[pc+1]] = objv(suppressed(x, e));
			pc += 3;
		Ochkobj =>
			if(vs[base+ops[pc+1]].t != Tobj)
				typeerr("iterator result is not an object");
			pc += 2;
		* =>
			throwerr(Error, sys->sprint("internal: bad opcode %d at %d", op, pc));
		}
	}
}

tdzerr(a: int)
{
	throwerr(ReferenceError, "cannot access '" + atomstr[a] + "' before initialization");
}

# a collection, with the frame's registers all live
safepoint(next: int)
{
	frames[nframe-1].pc = next;
	sp = base + code.nregs;
	collect();
}

envreg(): int
{
	v := vs[base+Renv];
	if(v.t == Tobj)
		return v.x;
	return -1;
}

envv(h: int): V
{
	if(h < 0)
		return undef;
	return objv(h);
}

# the environment depth out from the current one
envat(depth: int): int
{
	e := vs[base+Renv].x;
	for(; depth > 0; depth--)
		e = oproto[e];
	return e;
}

newenv(s: ref Scope, parent: int): int
{
	e := newobj(Kenv, parent);
	if(s.nslots > 0) {
		sl := array[s.nslots] of V;
		for(i := 0; i < s.nslots; i++)
			if(s.tdz[i])
				sl[i] = empty;
			else
				sl[i] = undef;
		oslots[e] = sl;
	}
	odata[e] = ref Data.Env(s, -1);
	if(s.evalvars)
		pick d := odata[e] {
		Env =>
			# eval's vars: an object for them, its handle in withobj (not a with)
			d.withobj = -2 - newobj(Kord, -1);
		}
	return e;
}

# ---- the frame's register helpers for natives ----

arg(a, n, i: int): V
{
	if(i < n)
		return vs[a+i];
	return undef;
}

# push the values an array (from a spread) holds; their count
pushspread(arr: V): int
{
	h := arr.x;
	n := int oalen[h];
	if(sp + n + 16 > len vs)
		growvs(sp + n + 16);
	for(i := 0; i < n; i++) {
		if(i < onelem[h] && oelems[h][i].t != Tempty)
			vs[sp+i] = oelems[h][i];
		else
			vs[sp+i] = get(h, idxkey(i), arr);
	}
	sp += n;
	return n;
}

# ---- property access from the loop ----

getpropic(o: V, a: int, ic: int): V
{
	if(o.t == Tobj) {
		h := o.x;
		k := okind[h];
		if(k == Kord || k == Kfunc || k == Knative || k == Karray || k == Kerror) {
			sh := oshape[h];
			slot := slotof(sh, a);
			if(slot >= 0 && (sh.attrs[slot] & Aacc) == 0) {
				if(!sh.owned) {
					code.ics[ic] = sh;
					code.icslot[ic] = slot;
				}
				return oslots[h][slot];
			}
		}
		return get(h, a, o);
	}
	return getv(o, a);
}

setpropic(o: V, a: int, v: V, ic: int)
{
	if(o.t == Tobj) {
		h := o.x;
		if(okind[h] == Kord) {
			sh := oshape[h];
			slot := slotof(sh, a);
			if(slot >= 0 && (sh.attrs[slot] & (Awrite|Aacc)) == Awrite) {
				oslots[h][slot] = v;
				if(!sh.owned) {
					code.ics[ic] = sh;
					code.icslot[ic] = slot;
				}
				return;
			}
		}
		if(!set(h, a, v, o) && (code.flags & Cstrict))
			typeerr("cannot assign to read only property '" + keystr(a) + "' of " + show(o));
		return;
	}
	if(o.t == Tundef || o.t == Tnull)
		typeerr("cannot set properties of " + show(o) + " (setting '" + keystr(a) + "')");
	setv(o, a, v, code.flags & Cstrict);
}

getelem(o, kv: V): V
{
	if(o.t == Tobj && kv.t == Tnum) {
		h := o.x;
		x := kv.n;
		if(x >= 0.0 && x < real onelem[h]) {
			i := int x;
			if(real i == x) {
				v := oelems[h][i];
				if(v.t != Tempty && okind[h] != Kargs)
					return v;
			}
		}
	}
	if(o.t == Tundef || o.t == Tnull)
		typeerr("cannot read properties of " + show(o) + " (reading " + show(kv) + ")");
	k := tokey(kv);
	if(o.t == Tobj)
		return get(o.x, k, o);
	return getv(o, k);
}

setelem(o, kv, v: V, strict: int)
{
	if(o.t == Tobj && kv.t == Tnum) {
		h := o.x;
		x := kv.n;
		if(x >= 0.0 && x < real onelem[h] && (okind[h] == Karray || okind[h] == Kord)) {
			i := int x;
			if(real i == x && oelems[h][i].t != Tempty) {
				oelems[h][i] = v;
				return;
			}
		}
		if(okind[h] == Karray && x == oalen[h] && x == real onelem[h] && (oflags[h] & (Oidxprops|Oarrlenro)) == 0 && (oflags[h] & Oext) && x < real Idxmax) {
			arrpush(h, v);
			return;
		}
	}
	if(o.t == Tundef || o.t == Tnull)
		typeerr("cannot set properties of " + show(o));
	k := tokey(kv);
	setv(o, k, v, strict);
}

delv(o: V, k: int): int
{
	if(o.t == Tundef || o.t == Tnull)
		typeerr("cannot delete properties of " + show(o));
	h := toobject(o);
	return delete(h, k);
}

# ---- arithmetic ----

add(a, b: V): V
{
	if(a.t == Tstr && b.t == Tstr)
		return V(Tstr, concat(a.x, b.x), 0.0);
	pa := toprim(a, 0);
	pb := toprim(b, 0);
	if(pa.t == Tstr || pb.t == Tstr)
		return V(Tstr, concat(tostrh(pa), tostrh(pb)), 0.0);
	na := tonumeric(pa);
	nb := tonumeric(pb);
	if(na.t == Tnum && nb.t == Tnum)
		return num(na.n + nb.n);
	if(na.t == Tbig && nb.t == Tbig)
		return bigadd(na, nb);
	typeerr("cannot mix BigInt and other types, use explicit conversions");
	return undef;
}

arith(op: int, a, b: V): V
{
	na := tonumeric(a);
	nb := tonumeric(b);
	if(na.t != nb.t)
		typeerr("cannot mix BigInt and other types, use explicit conversions");
	if(na.t == Tbig)
		return bigarith(op, na, nb);
	x := na.n;
	y := nb.n;
	case op {
	Osub => return num(x - y);
	Omul => return num(x * y);
	Odiv => return num(x / y);
	Omod => return num(jsmod(x, y));
	Oexp => return num(jspow(x, y));
	Oshl => return num(real (toint32(na) << (int touint32(nb) & 31)));
	Oshr => return num(real (toint32(na) >> (int touint32(nb) & 31)));
	Oushr =>
		u := touint32(na);
		s := int touint32(nb) & 31;
		for(; s > 0; s--)
			u = math->floor(u / 2.0);
		return num(u);
	Oband => return num(real (toint32(na) & toint32(nb)));
	Obor => return num(real (toint32(na) | toint32(nb)));
	Obxor => return num(real (toint32(na) ^ toint32(nb)));
	}
	return num(nan);
}

jsmod(x, y: real): real
{
	if(isnan(x) || isnan(y) || x == inf || x == -inf || y == 0.0)
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

jspow(x, y: real): real
{
	if(isnan(y))
		return nan;
	if(y == 0.0)
		return 1.0;
	if((x == 1.0 || x == -1.0) && (y == inf || y == -inf))
		return nan;
	return math->pow(x, y);
}

# ---- functions ----

closure(c: ref Code, env: int): int
{
	h := newobj(Kfunc, ifuncproto);
	oflags[h] |= Ocallable;
	if(c.flags & Cgen && c.flags & Casync)
		oproto[h] = iasyncgenfuncproto;
	else if(c.flags & Cgen)
		oproto[h] = igenfuncproto;
	else if(c.flags & Casync)
		oproto[h] = iasyncfuncproto;
	odata[h] = ref Data.Func(c, env, -1, -1, nil, undef, 0);
	defown(h, alength, Aconf, num(real c.flen));
	defown(h, aname, Aconf, V(Tstr, atomsh[intern(c.name)], 0.0));
	if(c.flags & Cgen) {
		p := newobj(Kord, igenproto);
		if(c.flags & Casync)
			oproto[p] = iasyncgenproto;
		defown(h, aprototype, Awrite, objv(p));
	} else if((c.flags & (Carrow|Cmethod|Casync)) == 0) {
		oflags[h] |= Octor;
		p := newplain();
		defown(p, aconstructor, Awrite|Aconf, objv(h));
		defown(h, aprototype, Awrite, objv(p));
	}
	return h;
}

# SetFunctionName; n: 0 plain, 1 get, 2 set; 16: a field's key, not a name
setfnname(f, kv: V, n: int)
{
	if(f.t != Tobj)
		return;
	h := f.x;
	if(n & 16) {
		pick d := odata[h] {
		Func =>
			if(n & 1)
				d.isfield = 2;
			else {
				d.fieldkey = kv;
				d.isfield = 1;
			}
		}
		return;
	}
	# a class's own static name method wins
	if(okind[h] == Kfunc) {
		pick d := odata[h] {
		Func =>
			if(d.code.flags & Cctor && d.code.name != nil && n == 0) {
				(ok, nil, nil) := getownprop(h, aname);
				if(ok)
					;
			}
		}
	}
	name: string;
	if(kv.t == Tsym) {
		a := kv.x;
		if(atomsym[a] == byte 2)
			name = atomstr[a];
		else if(atomsh[a] < 0)
			name = "";
		else
			name = "[" + atomstr[a] + "]";
	} else
		name = tostring(kv);
	case n {
	1 => name = "get " + name;
	2 => name = "set " + name;
	}
	(ok, v, a) := getownprop(h, aname);
	if(ok && v.t == Tstr && slen[v.x] > 0 && n == 0 && (a & Aacc) == 0) {
		# a class or function that named itself keeps its name, unless it is a class with a static name
		pick d := odata[h] {
		Func =>
			if(d.code.name != nil)
				return;
		}
	}
	if(ok && (a & Aacc))
		return;	# a static name accessor or method
	if(ok && !(v.t == Tstr) && n == 0)
		return;
	defown(h, aname, Aconf, strv(name));
}

homeof(fv: V): int
{
	if(fv.t != Tobj)
		return -1;
	pick d := odata[fv.x] {
	Func =>
		return d.home;
	}
	return -1;
}

# ---- classes ----

classcreate(sup: V, c: ref Code, env: int): (int, int)
{
	protoparent := iobjproto;
	ctorparent := ifuncproto;
	if(sup.t != Tempty) {
		if(sup.t == Tnull) {
			protoparent = -1;
		} else {
			if(!isctor(sup))
				typeerr("class extends value " + show(sup) + " is not a constructor or null");
			pp := getv(sup, aprototype);
			if(pp.t == Tnull)
				protoparent = -1;
			else if(pp.t == Tobj)
				protoparent = pp.x;
			else
				typeerr("class extends value does not have valid prototype property");
			ctorparent = sup.x;
		}
	}
	p := newobj(Kord, protoparent);
	f := newobj(Kfunc, ctorparent);
	oflags[f] |= Ocallable | Octor | Oclassctor;
	odata[f] = ref Data.Func(c, env, p, -1, nil, undef, 0);
	defown(f, alength, Aconf, num(real c.flen));
	defown(f, aname, Aconf, V(Tstr, atomsh[intern(c.name)], 0.0));
	defown(f, aprototype, 0, objv(p));
	defown(p, aconstructor, Awrite|Aconf, objv(f));
	return (f, p);
}

# a method, accessor, or the class's field initialisers
defmethod(o, kv, fv: V, kind: int)
{
	if(kind & 64) {
		# the constructor runs these
		pick d := odata[o.x] {
		Func =>
			d.fieldfns = kv.x;
			assignfieldkeys(kv.x, fv.x);
		}
		return;
	}
	if(kind & 32) {
		assignfieldkeys(kv.x, fv.x);
		runfields(o, kv.x);
		return;
	}
	k := tokey(kv);
	case kind & 3 {
	0 =>
		d := ref Desc(Hvalue|Hwrite|Henum|Hconf, fv, undef, undef, Awrite|Aconf);
		if(!defineown(o.x, k, d))
			typeerr("cannot redefine property: " + keystr(k));
	1 =>
		if(!defineown(o.x, k, ref Desc(Hget|Henum|Hconf, undef, fv, undef, Aconf)))
			typeerr("cannot redefine property: " + keystr(k));
	2 =>
		if(!defineown(o.x, k, ref Desc(Hset|Henum|Hconf, undef, undef, fv, Aconf)))
			typeerr("cannot redefine property: " + keystr(k));
	}
}

# the computed keys, in order, to the fields that wait for one
assignfieldkeys(fns, keys: int)
{
	j := 0;
	for(i := 0; i < onelem[fns]; i++) {
		f := oelems[fns][i];
		pick d := odata[f.x] {
		Func =>
			if(d.isfield == 2) {
				d.fieldkey = oelems[keys][j++];
				d.isfield = 1;
			}
		}
	}
}

# run field initialisers (and static blocks) on o, in order
runfields(o: V, fns: int)
{
	sp0 := sp;
	push(o);
	push(objv(fns));
	for(i := 0; i < onelem[fns]; i++) {
		f := oelems[fns][i];
		v := callv(f, o, sp, 0, undef);
		pick d := odata[f.x] {
		Func =>
			if(d.isfield) {
				k := d.fieldkey;
				if(k.t == Tsym && atomsym[k.x] == byte 2)
					privadd(o, k.x, v, Awrite);
				else {
					key := tokey(k);
					if(isanon(v))
						setfnname(v, k, 0);
					createdataorthrow(o.x, key, v);
				}
			}
		}
	}
	sp = sp0;
}

isanon(v: V): int
{
	if(v.t != Tobj || okind[v.x] != Kfunc)
		return 0;
	(ok, nv, nil) := getownprop(v.x, aname);
	return ok && nv.t == Tstr && slen[nv.x] == 0;
}

# a constructor's fields, and its private methods, on a new instance
initfields(this: V, f: int)
{
	if(this.t != Tobj)
		return;
	pick d := odata[f] {
	Func =>
		for(l := revpm(d.privmeths); l != nil; l = tl l) {
			(a, fv, kind) := hd l;
			privinstall(this, a, fv, kind);
		}
		if(d.fieldfns >= 0)
			runfields(this, d.fieldfns);
	}
}

revpm(l: list of (int, V, int)): list of (int, V, int)
{
	r: list of (int, V, int);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# ---- private names ----
#
# A private name is an atom marked 2 in atomsym, made new each time its
# class is.  An object's private elements are its own properties under
# those keys, which no key enumeration shows.

isprivkey(k: int): int
{
	return k >= 0 && atomsym[k] == byte 2;
}

privfind(h, a: int): (int, V, int)
{
	if(okind[h] == Kproxy)
		return (0, undef, 0);
	sh := oshape[h];
	slot := slotof(sh, a);
	if(slot < 0)
		return (0, undef, 0);
	return (1, oslots[h][slot], sh.attrs[slot]);
}

privhas(h, a: int): int
{
	(ok, nil, nil) := privfind(h, a);
	return ok;
}

privget(o: V, a: int): V
{
	if(o.t != Tobj)
		typeerr("cannot read private member " + atomstr[a] + " from " + show(o));
	(ok, v, at) := privfind(o.x, a);
	if(!ok)
		typeerr("cannot read private member " + atomstr[a] + " from an object whose class did not declare it");
	if(at & Aacc) {
		if(v.x < 0)
			typeerr("'" + atomstr[a] + "' was defined without a getter");
		return call(objv(v.x), o, nil);
	}
	return v;
}

privset(o: V, a: int, v: V)
{
	if(o.t != Tobj)
		typeerr("cannot write private member " + atomstr[a] + " to " + show(o));
	h := o.x;
	(ok, cur, at) := privfind(h, a);
	if(!ok)
		typeerr("cannot write private member " + atomstr[a] + " to an object whose class did not declare it");
	if(at & Aacc) {
		if(cur.n < 0.0)
			typeerr("'" + atomstr[a] + "' was defined without a setter");
		call(objv(int cur.n), o, array[] of {v});
		return;
	}
	if((at & Awrite) == 0)
		typeerr("private method " + atomstr[a] + " is not writable");
	sh := oshape[h];
	oslots[h][slotof(sh, a)] = v;
}

privadd(o: V, a: int, v: V, attrs: int)
{
	if(o.t != Tobj)
		typeerr("cannot define private member on " + show(o));
	h := o.x;
	if(okind[h] == Kproxy)
		typeerr("cannot define private member on a proxy");
	if(privhas(h, a))
		typeerr("cannot initialize " + atomstr[a] + " twice on the same object");
	sh := addkey(oshape[h], a, attrs);
	oshape[h] = sh;
	slot := sh.n - 1;
	s := oslots[h];
	if(s == nil || slot >= len s) {
		ns := array[2 * slot + 4] of V;
		if(s != nil)
			ns[0:] = s;
		oslots[h] = ns;
		s = ns;
	}
	s[slot] = v;
}

# a private method or accessor: static ones now, instance ones (kind 8) kept for the constructor
privmethod(target, pv: V, fv: V, kind: int)
{
	a := pv.x;
	if(kind & 8) {
		# target is the prototype; its constructor holds the list
		c := get(target.x, aconstructor, target);
		pick d := odata[c.x] {
		Func =>
			d.privmeths = (a, fv, kind & 3) :: d.privmeths;
		}
		return;
	}
	privinstall(target, a, fv, kind & 3);
}

privinstall(o: V, a: int, fv: V, kind: int)
{
	h := o.x;
	case kind {
	0 =>
		privadd(o, a, fv, 0);
	1 or 2 =>
		(ok, cur, at) := privfind(h, a);
		if(ok && (at & Aacc)) {
			sh := ownshape(h);
			slot := slotof(sh, a);
			if(kind == 1)
				oslots[h][slot] = V(Tacc, fv.x, cur.n);
			else
				oslots[h][slot] = V(Tacc, cur.x, real fv.x);
			return;
		}
		if(kind == 1)
			privadd(o, a, V(Tacc, fv.x, -1.0), Aacc);
		else
			privadd(o, a, V(Tacc, -1, real fv.x), Aacc);
	}
}

# ---- the global scope ----

# global lexical bindings: a declarative record shared by the realm's scripts
glex: array of list of (int, ref V);	# hash by atom

glexfind(a: int): ref V
{
	if(glex == nil)
		glex = array[1021] of list of (int, ref V);
	for(l := glex[a % len glex]; l != nil; l = tl l)
		if((hd l).t0 == a)
			return (hd l).t1;
	return nil;
}

glexadd(a: int, v: V): ref V
{
	r := ref v;
	b := a % len glex;
	glex[b] = (a, r) :: glex[b];
	glexconst = (a, 0) :: glexconst;
	return r;
}

glexconst: list of (int, int);

isglexconst(a: int): int
{
	for(l := glexconsts; l != nil; l = tl l)
		if(hd l == a)
			return 1;
	return 0;
}

glexconsts: list of int;

getglobal(a: int, typeofop: int): V
{
	r := glexfind(a);
	if(r != nil) {
		if(r.t == Tempty)
			tdzerr(a);
		return *r;
	}
	g := iglobal;
	if(hasprop(g, a))
		return get(g, a, objv(g));
	if(typeofop)
		return undef;
	throwerr(ReferenceError, atomstr[a] + " is not defined");
	return undef;
}

setglobal(a: int, v: V, strict: int)
{
	r := glexfind(a);
	if(r != nil) {
		if(r.t == Tempty)
			tdzerr(a);
		if(isglexconst(a))
			typeerr("assignment to constant variable '" + atomstr[a] + "'");
		*r = v;
		return;
	}
	g := iglobal;
	if(!hasprop(g, a)) {
		if(strict)
			throwerr(ReferenceError, atomstr[a] + " is not defined");
		createdata(g, a, v);
		return;
	}
	if(!set(g, a, v, objv(g)) && strict)
		typeerr("cannot assign to read only property '" + atomstr[a] + "'");
}

initglobal(a: int, v: V)
{
	r := glexfind(a);
	if(r != nil) {
		*r = v;
		return;
	}
	# a var or function: the global object's property
	set(iglobal, a, v, objv(iglobal));
}

delglobal(a: int): int
{
	if(glexfind(a) != nil)
		return 0;
	return delete(iglobal, a);
}

# GlobalDeclarationInstantiation (§16.1.7)
globalinit(g: ref Gdecl, c: ref Code)
{
	gh := iglobal;
	if(c.flags & Ceval) {
		evalvarinit(g, c);
		return;
	}
	lexnames := catint(g.lets, g.consts);
	for(i := 0; i < len lexnames; i++) {
		a := lexnames[i];
		if(glexfind(a) != nil)
			throwerr(SyntaxError, "identifier '" + atomstr[a] + "' has already been declared");
		(found, d) := getown(gh, a);
		if(found && (d.attrs & Aconf) == 0)
			throwerr(SyntaxError, "identifier '" + atomstr[a] + "' has already been declared");
	}
	for(i = 0; i < len g.vars; i++)
		if(glexfind(g.vars[i]) != nil)
			throwerr(SyntaxError, "identifier '" + atomstr[g.vars[i]] + "' has already been declared");
	for(i = 0; i < len g.funcs; i++) {
		(a, nil) := g.funcs[i];
		if(glexfind(a) != nil)
			throwerr(SyntaxError, "identifier '" + atomstr[a] + "' has already been declared");
		(found, d) := getown(gh, a);
		if(found && (d.attrs & Aconf) == 0 && (isaccdesc(d) || (d.attrs & (Awrite|Aenum)) != (Awrite|Aenum)))
			typeerr("cannot declare global function " + atomstr[a]);
		if(!found && !isext(gh))
			typeerr("cannot declare global function " + atomstr[a]);
	}
	for(i = 0; i < len g.vars; i++) {
		a := g.vars[i];
		if(!hasown(gh, a) && !isext(gh))
			typeerr("cannot declare global variable " + atomstr[a]);
	}
	# Annex B functions: vars, where nothing lexical or unconfigurable is in the way
	for(i = 0; i < len g.annexb; i++) {
		a := g.annexb[i];
		if(glexfind(a) != nil || inlist(lexnames, a))
			continue;
		(found, nil) := getown(gh, a);
		if(!found && isext(gh))
			definevar(gh, a);
	}
	for(i = 0; i < len g.funcs; i++) {
		(a, nil) := g.funcs[i];
		(found, d) := getown(gh, a);
		if(!found || (d.attrs & Aconf))
			defineown(gh, a, datadesc(undef, Awrite|Aenum));
		else
			defineown(gh, a, ref Desc(Hvalue, undef, undef, undef, 0));
	}
	for(i = 0; i < len g.vars; i++) {
		a := g.vars[i];
		if(!hasown(gh, a))
			definevar(gh, a);
	}
	for(i = 0; i < len g.lets; i++)
		glexadd(g.lets[i], empty);
	for(i = 0; i < len g.consts; i++) {
		glexadd(g.consts[i], empty);
		glexconsts = g.consts[i] :: glexconsts;
	}
}

definevar(gh, a: int)
{
	defineown(gh, a, datadesc(undef, Awrite|Aenum));
}

inlist(a: array of int, x: int): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == x)
			return 1;
	return 0;
}

catint(a, b: array of int): array of int
{
	r := array[len a + len b] of int;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# ---- names at run time (with, eval) ----

# the environment chain from the current one: find a; (found, env, slot)
#   slot >= 0: a binding; -1: a with or eval-var object holds it (in obj)
dynfind(a: int): (int, int, int, int)
{
	for(e := envreg(); e >= 0; e = oproto[e]) {
		pick d := odata[e] {
		Env =>
			if(d.withobj >= 0) {
				o := d.withobj;
				if(hasprop(o, a) && !unscopable(o, a))
					return (1, e, -1, o);
				continue;
			}
			s := d.scope;
			if(s != nil && s.names != nil) {
				for(i := 0; i < len s.names; i++)
					if(s.names[i] == a)
						return (1, e, i, -1);
			}
			if(d.withobj <= -2) {
				o := -2 - d.withobj;
				if(hasown(o, a))
					return (1, e, -1, o);
			}
		}
	}
	return (0, -1, -1, -1);
}

unscopable(o, a: int): int
{
	u := get(o, asymunscopables, objv(o));
	if(u.t != Tobj)
		return 0;
	return truthy(get(u.x, a, u));
}

getdyn(a: int, typeofop: int): V
{
	(found, e, slot, o) := dynfind(a);
	if(found) {
		if(slot >= 0) {
			v := oslots[e][slot];
			if(v.t == Timport)
				v = oslots[v.x][int v.n];
			if(v.t == Tempty)
				tdzerr(a);
			return v;
		}
		if(!hasprop(o, a)) {
			if(code.flags & Cstrict)
				throwerr(ReferenceError, atomstr[a] + " is not defined");
			return undef;
		}
		return get(o, a, objv(o));
	}
	return getglobal(a, typeofop);
}

setdyn(a: int, v: V, strict: int, init: int)
{
	(found, e, slot, o) := dynfind(a);
	if(found) {
		if(slot >= 0) {
			pick d := odata[e] {
			Env =>
				s := d.scope;
				if(!init && s.tdz[slot] && oslots[e][slot].t == Tempty)
					tdzerr(a);
				if(!init && s.kinds[slot] == Bconst)
					typeerr("assignment to constant variable '" + atomstr[a] + "'");
				if(!init && s.kinds[slot] == Bfnself) {
					if(strict)
						typeerr("assignment to constant variable '" + atomstr[a] + "'");
					return;
				}
			}
			oslots[e][slot] = v;
			return;
		}
		stillthere := hasprop(o, a);
		if(!stillthere && strict)
			throwerr(ReferenceError, atomstr[a] + " is not defined");
		if(!set(o, a, v, objv(o)) && strict)
			typeerr("cannot assign to read only property '" + atomstr[a] + "'");
		return;
	}
	if(init) {
		initglobal(a, v);
		return;
	}
	setglobal(a, v, strict);
}

deldyn(a: int): int
{
	(found, nil, slot, o) := dynfind(a);
	if(found) {
		if(slot >= 0)
			return 0;
		return delete(o, a);
	}
	return delglobal(a);
}

calldyn(a: int): (V, V)
{
	(found, e, slot, o) := dynfind(a);
	if(found) {
		if(slot >= 0) {
			v := oslots[e][slot];
			if(v.t == Tempty)
				tdzerr(a);
			return (v, undef);
		}
		pick d := odata[e] {
		Env =>
			if(d.withobj >= 0)
				return (get(o, a, objv(o)), objv(o));
		}
		return (get(o, a, objv(o)), undef);
	}
	return (getglobal(a, 0), undef);
}
