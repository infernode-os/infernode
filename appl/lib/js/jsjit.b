# jsjit.b - the compiled tier (docs/JS-ENGINE.md §5.3, phase 6).
#
# A function the interpreter has run often enough is translated to a Dis
# module of its own (Dis->writeobj), loaded, and so compiled by the JIT
# like any Limbo code.  The module's run(st, pc) starts at the operation
# at pc and runs the operations it has in line: constants and moves,
# arithmetic and comparisons on numbers, increments, jumps and branches
# on booleans.  It returns at the first one it does not have, or one
# whose operands are not what it has a line for, with that operation's
# pc; the interpreter does that one, and comes back to compiled code at
# the next operation compiled (Code.jitent).  So compiled code never
# throws, allocates, calls or changes frames: those stay the
# interpreter's, and nothing the engine relies on (its handlers, frames,
# collector) has to know about it.
#
# A module is written to /tmp, loaded and removed; where there is no /tmp
# (a page's confined realm) nothing is compiled.

Jittmpl: con "/dis/lib/js/jsjitt.dis";
Disdata: type Dis->Data;	# (the engine has a Data of its own)
jitthreshold := 1000;	# calls and backward jumps before compiling; -1: never
jitsig := 0;		# run's signature, from the template
jitsrt := 0;
jitssize := 0;
jitok := -1;		# 1 ready, 0 cannot, -1 not tried
jitseq := 0;
jitdir: string;
jitst: ref Jitst;
jitlast: ref Code;	# whose arrays jitst has
jitcompiled := 0;	# functions compiled, for -t
jitrejected := 0;	# made and not passed by the verifier
jitdebug := 0;
jitcorrupt: string;

# Js->jit: when to compile (calls and loop iterations), -1 for never
jit(n: int)
{
	jitthreshold = n;
}

jitstats(): (int, int)
{
	return (jitcompiled, jitrejected);
}

jitinit(): int
{
	if(jitok >= 0)
		return jitok;
	jitok = 0;
	if(jitthreshold < 0)
		return 0;
	if(dis == nil)
		dis = load Dis Dis->PATH;
	if(dis == nil)
		return 0;
	dis->init();
	(tm, nil) := dis->loadobj(Jittmpl);
	if(tm == nil || len tm.links != 1)
		return 0;
	jitsig = tm.links[0].sig;
	jitsrt = tm.rt;
	jitssize = tm.ssize;
	(ok, nil) := sys->stat("/tmp");
	if(ok < 0)
		return 0;
	(dbg, nil) := sys->stat("/env/jsjitdebug");
	jitdebug = dbg >= 0;
	# a test's: each module made is spoilt so, for the verifier to refuse
	if((fd := sys->open("/env/jsjitcorrupt", Sys->OREAD)) != nil) {
		b := array[32] of byte;
		k := sys->read(fd, b, len b);
		if(k > 0)
			jitcorrupt = string b[0:k];
	}
	jitdir = sys->sprint("/tmp/.jsjit.%d", sys->pctl(0, nil));
	jitst = ref Jitst(vs, 0, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil);
	jitok = 1;
	return 1;
}

# count toward compiling c; compile it when it is hot
jithot(c: ref Code)
{
	if(c.jitstate != 0 || jitthreshold < 0)
		return;
	if(++c.jitn < jitthreshold)
		return;
	if(jitinit() == 0 || jitcompile(c) == 0)
		c.jitstate = -1;
}

# run compiled code from pc, which jitent says is compiled; the pc to go on from
jitrun(c: ref Code, pc: int, base: int): int
{
	# (each assigned only when it has changed: an assignment counts a
	# reference, a comparison does not)
	st := jitst;
	st.base = base;
	if(jitlast != c) {
		jitlast = c;
		st.consts = c.consts;
		st.ics = c.ics;
		st.icslot = c.icslot;
		st.icgen = c.icgen;
	}
	if(st.vs != vs)
		st.vs = vs;
	if(st.oshape != oshape) {
		st.oshape = oshape;
		st.oslots = oslots;
		st.okind = okind;
		st.onelem = onelem;
		st.oelems = oelems;
		st.oproto = oproto;
	}
	return c.jit->run(st, pc);
}

# ---- generating ----

# frame offsets: run's arguments, then the code's own
Fst: con 64;	# st
Fpc: con 72;	# pc
Fbase: con 80;	# st.base
Fvs: con 88;	# st.vs
Fk: con 96;	# st.consts
Fa: con 104;	# element addresses
Fb: con 112;
Fc: con 120;
Ff1: con 128;	# reals
Ff2: con 136;
Ft: con 144;	# a word
# st's arrays for the inline caches, as words: no reference is counted,
# and none need be, as st holds them and nothing is freed while
# compiled code runs
Fos: con 152;	# oshape
Foslots: con 160;
Fics: con 168;
Ficslot: con 176;
Ficgen: con 184;
Fp1: con 192;	# addresses, and pointers as words
Fp2: con 200;
Fsh: con 208;
Fsh2: con 216;
Ft2: con 224;
Ft3: con 232;
Frow: con 240;
Fokind: con 248;	# st's object arrays, as words too
Fonelem: con 256;
Foelems: con 264;
Foproto: con 272;
Fbp: con 280;	# &vs[base]: register r is at r*Vsize from it
Fsize: con 288;
Shgen: con 48;	# Shape.gen
# where st's fields from oshape on go in the frame
stslot := array[] of {Fos, Foslots, Fics, Ficslot, Ficgen, Fokind, Fonelem, Foelems, Foproto};
Fret: con 32;	# where run's result goes (through)
Vsize: con 24;	# a V: t at 0, x at 8, n at 16

Gen: adt {
	ins:	array of ref Dis->Inst;
	n:	int;
	fix:	list of (int, int);	# (instruction, op pc): its dst is that operation's start
	exits:	list of (int, int);	# (instruction, op pc): its dst is a return of that pc
};

gemit(g: ref Gen, op, smode, src, mmode, mid, dmode, dst: int): int
{
	if(g.n >= len g.ins) {
		a := array[2 * len g.ins] of ref Dis->Inst;
		a[0:] = g.ins[0:g.n];
		g.ins = a;
	}
	g.ins[g.n] = ref Dis->Inst(op, (smode << 3) | dmode | mmode, mid, src, dst);
	return g.n++;
}

FP: con Dis->AFP;
IMM: con Dis->AIMM;
XXX: con Dis->AXXX;
IND: con Dis->AIND|Dis->AFP;
MNONE: con Dis->AXNON;
MIMM: con Dis->AXIMM;
MFP: con Dis->AXINF;

# an indirect operand: off from the address in the frame at slot, or,
# for a register's handle (greg), off into that register
ind(slot, off: int): int
{
	if(slot < 0)
		return (Fbp << 16) | ((-slot - 1) * Vsize + off);
	return (slot << 16) | off;
}

# register r's handle for ind(): it is Vsize*r from &vs[base], which the
# prologue puts at Fbp; past the reach of an operand's offset, its address
# is computed into slot
greg(g: ref Gen, r, slot: int): int
{
	if(r < Maxreg)
		return -(r + 1);
	gemit(g, Dis->IADDW, IMM, r, MFP, Fbase, FP, slot);
	gemit(g, Dis->IINDX, FP, Fvs, MFP, slot, FP, slot);
	return slot;
}

Maxreg: con (65536 - Vsize) / Vsize;

# the value at slot = (t, x, 0.0)
gsetv(g: ref Gen, slot, t, x: int)
{
	gemit(g, Dis->IMOVW, IMM, t, MNONE, 0, IND, ind(slot, 0));
	gemit(g, Dis->IMOVW, IMM, x, MNONE, 0, IND, ind(slot, 8));
	gemit(g, Dis->ICVTWF, IMM, 0, MNONE, 0, IND, ind(slot, 16));
}

# the value at slot = the number in the real at fp f
gsetnum(g: ref Gen, slot, f: int)
{
	gemit(g, Dis->IMOVW, IMM, Tnum, MNONE, 0, IND, ind(slot, 0));
	gemit(g, Dis->IMOVW, IMM, 0, MNONE, 0, IND, ind(slot, 8));
	gemit(g, Dis->IMOVF, FP, f, MNONE, 0, IND, ind(slot, 16));
}

# leave to the interpreter at op pc unless the value at slot has tag t
gneedtag(g: ref Gen, slot, t, pc: int)
{
	i := gemit(g, Dis->IBNEW, IND, ind(slot, 0), MIMM, t, IMM, 0);
	g.exits = (i, pc) :: g.exits;
}

# a jump to the operation at pc (patched when all are placed)
gjmp(g: ref Gen, op, smode, src, mmode, mid, pc: int)
{
	i := gemit(g, op, smode, src, mmode, mid, IMM, 0);
	g.fix = (i, pc) :: g.fix;
}

# return pc to the interpreter
gret(g: ref Gen, pc: int)
{
	gemit(g, Dis->IMOVW, IMM, pc, MNONE, 0, IND, ind(Fret, 0));
	gemit(g, Dis->IRET, XXX, 0, MNONE, 0, XXX, 0);
}

# Fp2 = the address of the slot inline cache ic says the property of the
# object (its value at slot a) is in, or leave to the interpreter at pc
gicslot(g: ref Gen, a, ic, pc: int)
{
	gemit(g, Dis->IMOVW, IND, ind(a, 8), MNONE, 0, FP, Ft);	# the object
	gemit(g, Dis->IINDX, FP, Fos, MFP, Fp1, FP, Ft);
	gemit(g, Dis->IMOVW, IND, ind(Fp1, 0), MNONE, 0, FP, Fsh);	# its shape
	gemit(g, Dis->IMOVW, IMM, ic, MNONE, 0, FP, Ft2);
	gemit(g, Dis->IINDX, FP, Fics, MFP, Fp2, FP, Ft2);
	gemit(g, Dis->IMOVW, IND, ind(Fp2, 0), MNONE, 0, FP, Fsh2);	# the one cached
	i := gemit(g, Dis->IBNEW, FP, Fsh, MFP, Fsh2, IMM, 0);
	g.exits = (i, pc) :: g.exits;
	gemit(g, Dis->IINDX, FP, Ficgen, MFP, Fp2, FP, Ft2);
	gemit(g, Dis->IMOVW, IND, ind(Fp2, 0), MNONE, 0, FP, Ft3);	# its gen then
	i = gemit(g, Dis->IBNEW, IND, ind(Fsh, Shgen), MFP, Ft3, IMM, 0);
	g.exits = (i, pc) :: g.exits;
	gemit(g, Dis->IINDX, FP, Ficslot, MFP, Fp2, FP, Ft2);
	gemit(g, Dis->IMOVW, IND, ind(Fp2, 0), MNONE, 0, FP, Ft3);	# the slot
	gemit(g, Dis->IINDX, FP, Foslots, MFP, Fp1, FP, Ft);
	gemit(g, Dis->IMOVW, IND, ind(Fp1, 0), MNONE, 0, FP, Frow);	# the object's slots
	gemit(g, Dis->IINDX, FP, Frow, MFP, Fp2, FP, Ft3);
}

# leave to the interpreter at pc if s op m (one of the branches); for a
# real compared with an immediate, real is set and m is a whole number
# converted to a real in Ff2 first
gexitif(g: ref Gen, op, smode, src, mmode, mid, pc, real0: int)
{
	if(real0) {
		gemit(g, Dis->ICVTWF, IMM, mid, MNONE, 0, FP, Ff2);
		mmode = MFP;
		mid = Ff2;
	}
	i := gemit(g, op, smode, src, mmode, mid, IMM, 0);
	g.exits = (i, pc) :: g.exits;
}

# the word at fp w = the number at slot as a 32-bit integer, or leave to
# the interpreter at pc if it is not one
gint32(g: ref Gen, slot, w, pc: int)
{
	gemit(g, Dis->IMOVF, IND, ind(slot, 16), MNONE, 0, FP, Ff1);
	gemit(g, Dis->ICVTFW, FP, Ff1, MNONE, 0, FP, w);
	gemit(g, Dis->ICVTWF, FP, w, MNONE, 0, FP, Ff2);
	gexitif(g, Dis->IBNEF, FP, Ff2, MFP, Ff1, pc, 0);	# not whole (or NaN, or past a word)
	# within 32 bits: -2^31 <= w < 2^31, tested as w >> 31 being 0 or -1
	gemit(g, Dis->ISHRW, IMM, 31, MFP, w, FP, Ft3);
	gemit(g, Dis->IADDW, IMM, 1, MFP, Ft3, FP, Ft3);
	gexitif(g, Dis->IBLTW, FP, Ft3, MIMM, 0, pc, 0);
	gexitif(g, Dis->IBGTW, FP, Ft3, MIMM, 1, pc, 0);
}

Immmax: con 1 << 29;

# whether the operation at pc is one compiled code has
jitable(ops: array of int, pc: int): int
{
	case ops[pc] {
	Oundef or Onull or Otrue or Ofalse or Oempty or Oconst or Omove or
	Oadd or Osub or Omul or Odiv or Olt or Ole or Ogt or Oge or
	Oinc or Odec or Ojmp or Ojt or Ojf or Otonumeric or Ochktdz or Onot or Oneg or
	Ogetprop or Osetprop or Ogetelem or Osetelem or Ogetenv or Ogetenvc or Osetenv or Osetenvc or
	Oseq or Osne or Omod or Oband or Obor or Obxor or Oshr =>
		return 1;
	Oint =>
		n := ops[pc+2];
		return n > -Immmax && n < Immmax;
	}
	return 0;
}

jitcompile(c: ref Code): int
{
	ops := c.ops;
	if(ops == nil || len ops > 1 << 16 || c.lazy != nil)
		return 0;
	ent := array[len ops] of {* => byte 0};
	start := array[len ops] of {* => -1};
	ncomp := 0;
	for(pc := 0; pc < len ops; pc += oplen(ops[pc]))
		if(jitable(ops, pc)) {
			ent[pc] = byte 1;
			ncomp++;
		}
	if(ncomp == 0)
		return 0;
	g := ref Gen(array[256] of ref Dis->Inst, 0, nil, nil);
	# the prologue: st's fields into the frame, the registers' addresses,
	# then the case on pc
	gemit(g, Dis->IMOVW, IND, ind(Fst, 0), MNONE, 0, FP, Fvs);
	gemit(g, Dis->IMOVW, IND, ind(Fst, 8), MNONE, 0, FP, Fbase);
	gemit(g, Dis->IMOVW, IND, ind(Fst, 16), MNONE, 0, FP, Fk);
	for(f := 0; f < 9; f++)
		gemit(g, Dis->IMOVW, IND, ind(Fst, 24 + 8 * f), MNONE, 0, FP, stslot[f]);
	gemit(g, Dis->IINDX, FP, Fvs, MFP, Fbp, FP, Fbase);
	gemit(g, Dis->ICASE, FP, Fpc, MNONE, 0, Dis->AMP, 0);
	for(pc = 0; pc < len ops; pc += oplen(ops[pc])) {
		start[pc] = g.n;
		if(ent[pc] == byte 0) {
			gret(g, pc);
			continue;
		}
		next := pc + oplen(ops[pc]);
		op := ops[pc];
		case op {
		Oundef or Onull or Otrue or Ofalse or Oempty =>
			a := greg(g, ops[pc+1], Fa);
			case op {
			Oundef => gsetv(g, a, Tundef, 0);
			Onull => gsetv(g, a, Tnull, 0);
			Otrue => gsetv(g, a, Tbool, 1);
			Oempty => gsetv(g, a, Tempty, 0);
			* => gsetv(g, a, Tbool, 0);
			}
		Otonumeric =>
			# a number is its own; anything else is the interpreter's
			b := greg(g, ops[pc+2], Fb);
			gneedtag(g, b, Tnum, pc);
			a := greg(g, ops[pc+1], Fa);
			gemit(g, Dis->IMOVM, IND, ind(b, 0), MIMM, Vsize, IND, ind(a, 0));
		Ochktdz =>
			# uninitialised: the interpreter throws
			a := greg(g, ops[pc+1], Fa);
			i := gemit(g, Dis->IBEQW, IND, ind(a, 0), MIMM, Tempty, IMM, 0);
			g.exits = (i, pc) :: g.exits;
		Onot =>
			# of a boolean
			b := greg(g, ops[pc+2], Fb);
			gneedtag(g, b, Tbool, pc);
			gemit(g, Dis->IMOVW, IND, ind(b, 8), MNONE, 0, FP, Ft);
			gemit(g, Dis->IXORW, IMM, 1, MNONE, 0, FP, Ft);
			a := greg(g, ops[pc+1], Fa);
			gemit(g, Dis->IMOVW, IMM, Tbool, MNONE, 0, IND, ind(a, 0));
			gemit(g, Dis->IMOVW, FP, Ft, MNONE, 0, IND, ind(a, 8));
			gemit(g, Dis->ICVTWF, IMM, 0, MNONE, 0, IND, ind(a, 16));
		Oneg =>
			# of a number
			b := greg(g, ops[pc+2], Fb);
			gneedtag(g, b, Tnum, pc);
			gemit(g, Dis->INEGF, IND, ind(b, 16), MNONE, 0, FP, Ff1);
			a := greg(g, ops[pc+1], Fa);
			gsetnum(g, a, Ff1);
		Oint =>
			a := greg(g, ops[pc+1], Fa);
			gemit(g, Dis->IMOVW, IMM, Tnum, MNONE, 0, IND, ind(a, 0));
			gemit(g, Dis->IMOVW, IMM, 0, MNONE, 0, IND, ind(a, 8));
			gemit(g, Dis->ICVTWF, IMM, ops[pc+2], MNONE, 0, IND, ind(a, 16));
		Oconst =>
			gemit(g, Dis->IMOVW, IMM, ops[pc+2], MNONE, 0, FP, Ft);
			gemit(g, Dis->IINDX, FP, Fk, MFP, Fb, FP, Ft);
			a := greg(g, ops[pc+1], Fa);
			gemit(g, Dis->IMOVM, IND, ind(Fb, 0), MIMM, Vsize, IND, ind(a, 0));
		Omove =>
			b := greg(g, ops[pc+2], Fb);
			a := greg(g, ops[pc+1], Fa);
			gemit(g, Dis->IMOVM, IND, ind(b, 0), MIMM, Vsize, IND, ind(a, 0));
		Oadd or Osub or Omul or Odiv =>
			a := greg(g, ops[pc+2], Fa);
			gneedtag(g, a, Tnum, pc);
			b := greg(g, ops[pc+3], Fb);
			gneedtag(g, b, Tnum, pc);
			gemit(g, Dis->IMOVF, IND, ind(a, 16), MNONE, 0, FP, Ff1);
			fop := Dis->IADDF;
			case op {
			Osub => fop = Dis->ISUBF;
			Omul => fop = Dis->IMULF;
			Odiv => fop = Dis->IDIVF;
			}
			# d = m op s: a op b
			gemit(g, fop, IND, ind(b, 16), MFP, Ff1, FP, Ff1);
			d := greg(g, ops[pc+1], Fc);
			gsetnum(g, d, Ff1);
		Olt or Ole or Ogt or Oge =>
			a := greg(g, ops[pc+2], Fa);
			gneedtag(g, a, Tnum, pc);
			b := greg(g, ops[pc+3], Fb);
			gneedtag(g, b, Tnum, pc);
			gemit(g, Dis->IMOVF, IND, ind(a, 16), MNONE, 0, FP, Ff1);
			gemit(g, Dis->IMOVF, IND, ind(b, 16), MNONE, 0, FP, Ff2);
			# NaN is false whatever the comparison: tested first, as
			# an ordered branch on NaN is not to be relied on
			nan1 := gemit(g, Dis->IBNEF, FP, Ff1, MFP, Ff1, IMM, 0);
			nan2 := gemit(g, Dis->IBNEF, FP, Ff2, MFP, Ff2, IMM, 0);
			bop := Dis->IBLTF;
			case op {
			Ole => bop = Dis->IBLEF;
			Ogt => bop = Dis->IBGTF;
			Oge => bop = Dis->IBGEF;
			}
			# branch if s op m: a op b
			yes := gemit(g, bop, FP, Ff1, MFP, Ff2, IMM, 0);
			no := g.n;
			g.ins[nan1].dst = no;
			g.ins[nan2].dst = no;
			d := greg(g, ops[pc+1], Fc);
			gsetv(g, d, Tbool, 0);
			j := gemit(g, Dis->IJMP, XXX, 0, MNONE, 0, IMM, 0);
			g.ins[yes].dst = g.n;
			d = greg(g, ops[pc+1], Fc);
			gsetv(g, d, Tbool, 1);
			g.ins[j].dst = g.n;
		Oinc or Odec =>
			a := greg(g, ops[pc+2], Fa);
			gneedtag(g, a, Tnum, pc);
			gemit(g, Dis->IMOVF, IND, ind(a, 16), MNONE, 0, FP, Ff1);
			dd := 1;
			if(op == Odec)
				dd = -1;
			gemit(g, Dis->ICVTWF, IMM, dd, MNONE, 0, FP, Ff2);
			gemit(g, Dis->IADDF, FP, Ff2, MFP, Ff1, FP, Ff1);
			d := greg(g, ops[pc+1], Fc);
			gsetnum(g, d, Ff1);
		Ogetprop or Osetprop =>
			# an inline cache's hit: the object's shape is the one
			# cached, at the same gen; the property is in that slot
			oreg := ops[pc+2];
			if(op == Osetprop)
				oreg = ops[pc+1];
			a := greg(g, oreg, Fa);
			gneedtag(g, a, Tobj, pc);
			gicslot(g, a, ops[pc+4], pc);
			if(op == Ogetprop) {
				d := greg(g, ops[pc+1], Fc);
				gemit(g, Dis->IMOVM, IND, ind(Fp2, 0), MIMM, Vsize, IND, ind(d, 0));
			} else {
				v := greg(g, ops[pc+3], Fc);
				gemit(g, Dis->IMOVM, IND, ind(v, 0), MIMM, Vsize, IND, ind(Fp2, 0));
			}
		Ogetelem or Osetelem =>
			# an element in use, by an integer index, not a hole
			oreg := ops[pc+2];
			kreg := ops[pc+3];
			if(op == Osetelem) {
				oreg = ops[pc+1];
				kreg = ops[pc+2];
			}
			a := greg(g, oreg, Fa);
			gneedtag(g, a, Tobj, pc);
			b := greg(g, kreg, Fb);
			gneedtag(g, b, Tnum, pc);
			gemit(g, Dis->IMOVW, IND, ind(a, 8), MNONE, 0, FP, Ft);	# the object
			gexitif(g, Dis->IBLTF, IND, ind(b, 16), MIMM, 0, pc, 1);	# (x < 0: below)
			gemit(g, Dis->IMOVF, IND, ind(b, 16), MNONE, 0, FP, Ff1);
			gemit(g, Dis->ICVTFW, FP, Ff1, MNONE, 0, FP, Ft2);
			gemit(g, Dis->ICVTWF, FP, Ft2, MNONE, 0, FP, Ff2);
			gexitif(g, Dis->IBNEF, FP, Ff2, MFP, Ff1, pc, 0);	# not an integer, or NaN
			gexitif(g, Dis->IBLTW, FP, Ft2, MIMM, 0, pc, 0);
			gemit(g, Dis->IINDX, FP, Fonelem, MFP, Fp1, FP, Ft);
			gemit(g, Dis->IMOVW, IND, ind(Fp1, 0), MNONE, 0, FP, Ft3);
			gexitif(g, Dis->IBGEW, FP, Ft2, MFP, Ft3, pc, 0);	# past the elements in use
			gemit(g, Dis->IINDX, FP, Fokind, MFP, Fp1, FP, Ft);
			gemit(g, Dis->IMOVW, IND, ind(Fp1, 0), MNONE, 0, FP, Ft3);	# its kind
			if(op == Ogetelem)
				gexitif(g, Dis->IBEQW, FP, Ft3, MIMM, Kargs, pc, 0);
			else {
				ok := gemit(g, Dis->IBEQW, FP, Ft3, MIMM, Karray, IMM, 0);
				gexitif(g, Dis->IBNEW, FP, Ft3, MIMM, Kord, pc, 0);
				g.ins[ok].dst = g.n;
			}
			gemit(g, Dis->IINDX, FP, Foelems, MFP, Fp1, FP, Ft);
			gemit(g, Dis->IMOVW, IND, ind(Fp1, 0), MNONE, 0, FP, Frow);	# its elements
			gemit(g, Dis->IINDX, FP, Frow, MFP, Fp2, FP, Ft2);
			gexitif(g, Dis->IBEQW, IND, ind(Fp2, 0), MIMM, Tempty, pc, 0);
			if(op == Ogetelem) {
				d := greg(g, ops[pc+1], Fc);
				gemit(g, Dis->IMOVM, IND, ind(Fp2, 0), MIMM, Vsize, IND, ind(d, 0));
			} else {
				v := greg(g, ops[pc+3], Fc);
				gemit(g, Dis->IMOVM, IND, ind(v, 0), MIMM, Vsize, IND, ind(Fp2, 0));
			}
		Ogetenv or Ogetenvc or Osetenv or Osetenvc =>
			# slot n2 of the environment n1 out
			depth := ops[pc+2];
			slot := ops[pc+3];
			if(op == Osetenv || op == Osetenvc) {
				depth = ops[pc+1];
				slot = ops[pc+2];
			}
			e := greg(g, Renv, Fa);
			gemit(g, Dis->IMOVW, IND, ind(e, 8), MNONE, 0, FP, Ft);
			for(k := 0; k < depth; k++) {
				gemit(g, Dis->IINDX, FP, Foproto, MFP, Fp1, FP, Ft);
				gemit(g, Dis->IMOVW, IND, ind(Fp1, 0), MNONE, 0, FP, Ft);
			}
			gemit(g, Dis->IINDX, FP, Foslots, MFP, Fp1, FP, Ft);
			gemit(g, Dis->IMOVW, IND, ind(Fp1, 0), MNONE, 0, FP, Frow);
			gemit(g, Dis->IMOVW, IMM, slot, MNONE, 0, FP, Ft2);
			gemit(g, Dis->IINDX, FP, Frow, MFP, Fp2, FP, Ft2);
			# an imported binding, or (checked) one not yet initialised
			if(op == Ogetenv || op == Ogetenvc)
				gexitif(g, Dis->IBEQW, IND, ind(Fp2, 0), MIMM, Timport, pc, 0);
			if(op == Ogetenvc || op == Osetenvc)
				gexitif(g, Dis->IBEQW, IND, ind(Fp2, 0), MIMM, Tempty, pc, 0);
			if(op == Ogetenv || op == Ogetenvc) {
				d := greg(g, ops[pc+1], Fc);
				gemit(g, Dis->IMOVM, IND, ind(Fp2, 0), MIMM, Vsize, IND, ind(d, 0));
			} else {
				v := greg(g, ops[pc+3], Fc);
				gemit(g, Dis->IMOVM, IND, ind(v, 0), MIMM, Vsize, IND, ind(Fp2, 0));
			}
		Oseq or Osne =>
			# numbers, or values of one type compared by their word; strings
			# and BigInts are the interpreter's
			a := greg(g, ops[pc+2], Fa);
			b := greg(g, ops[pc+3], Fb);
			gemit(g, Dis->IMOVW, IND, ind(a, 0), MNONE, 0, FP, Ft);
			gemit(g, Dis->IMOVW, IND, ind(b, 0), MNONE, 0, FP, Ft2);
			notnum := gemit(g, Dis->IBNEW, FP, Ft, MIMM, Tnum, IMM, 0);
			bnotnum := gemit(g, Dis->IBNEW, FP, Ft2, MIMM, Tnum, IMM, 0);	# -> false
			gemit(g, Dis->IMOVF, IND, ind(a, 16), MNONE, 0, FP, Ff1);
			gemit(g, Dis->IMOVF, IND, ind(b, 16), MNONE, 0, FP, Ff2);
			nan1 := gemit(g, Dis->IBNEF, FP, Ff1, MFP, Ff1, IMM, 0);	# -> false
			nan2 := gemit(g, Dis->IBNEF, FP, Ff2, MFP, Ff2, IMM, 0);
			numeq := gemit(g, Dis->IBEQF, FP, Ff1, MFP, Ff2, IMM, 0);	# -> true
			jfalse1 := gemit(g, Dis->IJMP, XXX, 0, MNONE, 0, IMM, 0);
			# a not a number
			g.ins[notnum].dst = g.n;
			difft := gemit(g, Dis->IBNEW, FP, Ft, MFP, Ft2, IMM, 0);	# -> false
			gexitif(g, Dis->IBEQW, FP, Ft, MIMM, Tstr, pc, 0);
			gexitif(g, Dis->IBEQW, FP, Ft, MIMM, Tbig, pc, 0);
			gemit(g, Dis->IMOVW, IND, ind(a, 8), MNONE, 0, FP, Ft);
			gemit(g, Dis->IMOVW, IND, ind(b, 8), MNONE, 0, FP, Ft2);
			wordeq := gemit(g, Dis->IBEQW, FP, Ft, MFP, Ft2, IMM, 0);	# -> true
			# false
			falseat := g.n;
			g.ins[bnotnum].dst = falseat;
			g.ins[nan1].dst = falseat;
			g.ins[nan2].dst = falseat;
			g.ins[jfalse1].dst = falseat;
			g.ins[difft].dst = falseat;
			d := greg(g, ops[pc+1], Fc);
			gsetv(g, d, Tbool, op == Osne);
			jend := gemit(g, Dis->IJMP, XXX, 0, MNONE, 0, IMM, 0);
			trueat := g.n;
			g.ins[numeq].dst = trueat;
			g.ins[wordeq].dst = trueat;
			d = greg(g, ops[pc+1], Fc);
			gsetv(g, d, Tbool, op == Oseq);
			g.ins[jend].dst = g.n;
		Omod or Oband or Obor or Obxor or Oshr =>
			# on 32-bit integers (and for %, a whole number by a positive one,
			# where the remainder's sign cannot matter)
			a := greg(g, ops[pc+2], Fa);
			gneedtag(g, a, Tnum, pc);
			b := greg(g, ops[pc+3], Fb);
			gneedtag(g, b, Tnum, pc);
			gint32(g, a, Ft, pc);
			gint32(g, b, Ft2, pc);
			case op {
			Omod =>
				# (a zero dividend may be -0, whose remainder is -0)
				gexitif(g, Dis->IBLEW, FP, Ft, MIMM, 0, pc, 0);
				gexitif(g, Dis->IBLEW, FP, Ft2, MIMM, 0, pc, 0);
				gemit(g, Dis->IMODW, FP, Ft2, MFP, Ft, FP, Ft);	# d = m % s
			Oband =>
				gemit(g, Dis->IANDW, FP, Ft2, MFP, Ft, FP, Ft);
			Obor =>
				gemit(g, Dis->IORW, FP, Ft2, MFP, Ft, FP, Ft);
			Obxor =>
				gemit(g, Dis->IXORW, FP, Ft2, MFP, Ft, FP, Ft);
			Oshr =>
				gemit(g, Dis->IANDW, IMM, 31, MNONE, 0, FP, Ft2);
				gemit(g, Dis->ISHRW, FP, Ft2, MFP, Ft, FP, Ft);	# d = m >> s
			}
			gemit(g, Dis->ICVTWF, FP, Ft, MNONE, 0, FP, Ff1);
			d := greg(g, ops[pc+1], Fc);
			gsetnum(g, d, Ff1);
		Ojmp =>
			gjmp(g, Dis->IJMP, XXX, 0, MNONE, 0, ops[pc+1]);
			continue;
		Ojt or Ojf =>
			a := greg(g, ops[pc+1], Fa);
			gneedtag(g, a, Tbool, pc);
			bop := Dis->IBNEW;	# Ojt: jump if true (x != 0)
			if(op == Ojf)
				bop = Dis->IBEQW;
			gjmp(g, bop, IND, ind(a, 8), MIMM, 0, ops[pc+2]);
		}
		# on to the next operation, compiled or not, unless it is next
		if(next >= len ops)
			gret(g, next);
	}
	# the returns of an operation's pc, for operands not in line
	exitat := array[len ops] of {* => -1};
	for(l := g.exits; l != nil; l = tl l) {
		(i, p) := hd l;
		if(exitat[p] < 0) {
			exitat[p] = g.n;
			gret(g, p);
		}
		g.ins[i].dst = exitat[p];
	}
	for(l = g.fix; l != nil; l = tl l) {
		(i, p) := hd l;
		if(p < 0 || p >= len ops || start[p] < 0)
			return 0;
		g.ins[i].dst = start[p];
	}
	# a pc not compiled: return it as it is
	dflt := g.n;
	gemit(g, Dis->IMOVW, FP, Fpc, MNONE, 0, IND, ind(Fret, 0));
	gemit(g, Dis->IRET, XXX, 0, MNONE, 0, XXX, 0);
	# the case table: (pc, pc+1, start) for each operation compiled
	words := array[1 + 3 * ncomp + 1] of int;
	words[0] = ncomp;
	k := 1;
	for(pc = 0; pc < len ops; pc += oplen(ops[pc]))
		if(ent[pc] != byte 0) {
			words[k++] = pc;
			words[k++] = pc + 1;
			words[k++] = start[pc];
		}
	words[k] = dflt;
	m := ref Dis->Mod;
	m.name = "Jitcode";
	m.srcpath = "js:" + c.name;
	m.magic = Dis->XMAGIC;
	m.rt = jitsrt;
	m.ssize = jitssize;
	m.dsize = 8 * len words;
	m.entry = -1;
	m.entryt = -1;
	m.inst = g.ins[0:g.n];
	# the module data's type, then run's frame: st is its one pointer (the
	# arrays it holds are kept as words)
	m.types = array[] of {ref Dis->Type(m.dsize, 0, nil), ref Dis->Type(Fsize, 2, array[] of {byte 0, byte 16r80})};
	m.data = ref Disdata.Words((Dis->DEFW << 4), len words, 0, words) :: nil;
	m.links = array[] of {ref Dis->Link(0, 1, jitsig, "run")};
	if(jitcorrupt != nil)
		spoil(m, c.nregs, jitcorrupt);
	if((verr := jitverify(m, c.nregs)) != nil) {
		jitrejected++;
		if(jitdebug)
			sys->fprint(sys->fildes(2), "js: compiled %s rejected: %s\n", c.name, verr);
		return 0;
	}
	b := dis->writeobj(m);
	path := sys->sprint("%s.%d.dis", jitdir, jitseq++);
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return 0;
	if(sys->write(fd, b, len b) != len b) {
		sys->remove(path);
		return 0;
	}
	fd = nil;
	jc := load Jitcode path;
	sys->remove(path);
	if(jc == nil)
		return 0;
	c.jit = jc;
	c.jitent = ent;
	c.jitstate = 1;
	jitcompiled++;
	return 1;
}

# ---- the verifier ----
#
# A module made is checked before it is loaded (docs/JS-ENGINE.md §6.3:
# the code generator is the trusted base).  A forward data flow over its
# instructions keeps what each frame slot holds; every instruction must
# be one the generator makes, with operands of the kinds it takes:
# addresses only of an engine array's element (made by INDX, which Dis
# bounds-checks) or of the frame's registers (below its count), read and
# written at a V's fields or as a whole V; st's fields as their types;
# jumps and the case table's targets within the code.  A slot that holds
# different kinds on two ways in is unusable.  Not passing, the function
# is not compiled.

Ktop, Kint, Kreal, Kpst, Kret, Karrv, Karri, Karrs, Karra, Kev, Kei, Kes, Kea, Kshp, Kregs: con iota;

# st's fields at 0, 8, ...: what each is
stkinds := array[] of {Karrv, Kint, Karrv, Karrs, Karra, Karrs, Karri, Karri, Karri, Karri, Karra, Karri};

Vst: adt {
	m:	ref Dis->Mod;
	nregs:	int;
	err:	string;
};

jitverify(m: ref Dis->Mod, nregs: int): string
{
	n := len m.inst;
	nslot := Fsize / 8;
	if(len m.types < 2 || m.types[1].size != Fsize)
		return "frame";
	words: array of int;
	for(dl := m.data; dl != nil; dl = tl dl)
		pick w := hd dl {
		Words =>
			if(w.off == 0)
				words = w.words;
		}
	if(words == nil || len words < 2 || words[0] * 3 + 2 != len words)
		return "case table";
	for(i := 1; i + 2 < len words; i += 3)
		if(words[i+2] < 0 || words[i+2] >= n)
			return "case target";
	if(words[len words - 1] < 0 || words[len words - 1] >= n)
		return "case default";
	v := ref Vst(m, nregs, nil);
	ins := array[n] of array of int;	# the kinds in each slot, coming in
	entry := array[nslot] of {* => Ktop};
	entry[Fst/8] = Kpst;
	entry[Fpc/8] = Kint;
	entry[Fret/8] = Kret;
	ins[0] = entry;
	work := 0 :: nil;
	steps := 0;
	while(work != nil) {
		pc := hd work;
		work = tl work;
		if(++steps > 64 * n + 1024)
			return "no fixed point";
		st := array[nslot] of int;
		st[0:] = ins[pc];
		(succ, err) := vstep(v, m.inst[pc], st, words);
		if(err != nil)
			return sys->sprint("%d: %s", pc, err);
		if(succ == nil && m.inst[pc].op != Dis->IRET && m.inst[pc].op != Dis->IJMP && m.inst[pc].op != Dis->ICASE) {
			if(pc + 1 >= n)
				return sys->sprint("%d: runs off the end", pc);
			succ = pc + 1 :: nil;
		} else if(isbranch(m.inst[pc].op)) {
			if(pc + 1 >= n)
				return sys->sprint("%d: runs off the end", pc);
			succ = pc + 1 :: succ;
		}
		for(; succ != nil; succ = tl succ) {
			t := hd succ;
			if(t < 0 || t >= n)
				return sys->sprint("%d: target %d", pc, t);
			if(ins[t] == nil) {
				ins[t] = array[nslot] of int;
				ins[t][0:] = st;
				work = t :: work;
			} else {
				changed := 0;
				for(k := 0; k < nslot; k++)
					if(ins[t][k] != st[k] && ins[t][k] != Ktop) {
						ins[t][k] = Ktop;
						changed = 1;
					}
				if(changed)
					work = t :: work;
			}
		}
	}
	return nil;
}

isbranch(op: int): int
{
	return op >= Dis->IBEQB && op <= Dis->IBGEC;
}

isfbranch(op: int): int
{
	return op >= Dis->IBEQF && op <= Dis->IBGEF;
}

# check one instruction against the kinds in st, update st; the targets
# beyond the next instruction
vstep(v: ref Vst, in: ref Dis->Inst, st: array of int, words: array of int): (list of int, string)
{
	sm := (in.addr >> 3) & 7;
	dm := in.addr & 7;
	mm := in.addr & Dis->ARM;
	case in.op {
	Dis->IMOVW =>
		(k, e) := vread(v, st, sm, in.src, 'w');
		if(e != nil)
			return (nil, e);
		return (nil, vwrite(v, st, dm, in.dst, k, 'w'));
	Dis->IMOVF =>
		(nil, e) := vread(v, st, sm, in.src, 'f');
		if(e != nil)
			return (nil, e);
		return (nil, vwrite(v, st, dm, in.dst, Kreal, 'f'));
	Dis->IMOVM =>
		if(mm != Dis->AXIMM || in.mid != Vsize)
			return (nil, "movm of other than a V");
		(nil, e) := vread(v, st, sm, in.src, 'm');
		if(e != nil)
			return (nil, e);
		return (nil, vwrite(v, st, dm, in.dst, Ktop, 'm'));
	Dis->ICVTWF =>
		(k, e) := vread(v, st, sm, in.src, 'w');
		if(e != nil || k != Kint)
			return (nil, "cvtwf of " + kindname(k) + e);
		return (nil, vwrite(v, st, dm, in.dst, Kreal, 'f'));
	Dis->ICVTFW =>
		(nil, e) := vread(v, st, sm, in.src, 'f');
		if(e != nil)
			return (nil, e);
		return (nil, vwrite(v, st, dm, in.dst, Kint, 'w'));
	Dis->IADDW or Dis->ISUBW or Dis->IMULW or Dis->IANDW or Dis->IORW or Dis->IXORW or Dis->ISHRW or Dis->IMODW =>
		(k, e) := vread(v, st, sm, in.src, 'w');
		if(e != nil || k != Kint)
			return (nil, "word arithmetic on " + kindname(k) + e);
		if(mm == Dis->AXINF) {
			if(slotkind(st, in.mid) != Kint)
				return (nil, "word arithmetic on " + kindname(slotkind(st, in.mid)));
		} else if(mm == Dis->AXNON) {
			if(dm != Dis->AFP || slotkind(st, in.dst) != Kint)
				return (nil, "word arithmetic into other than a word");
		} else if(mm != Dis->AXIMM)
			return (nil, "middle operand");
		if(dm != Dis->AFP)
			return (nil, "word arithmetic into memory");
		return (nil, vwrite(v, st, dm, in.dst, Kint, 'w'));
	Dis->IADDF or Dis->ISUBF or Dis->IMULF or Dis->IDIVF or Dis->INEGF =>
		(nil, e) := vread(v, st, sm, in.src, 'f');
		if(e != nil)
			return (nil, e);
		if(in.op != Dis->INEGF) {
			if(mm == Dis->AXINF) {
				if(slotkind(st, in.mid) != Kreal)
					return (nil, "real arithmetic on " + kindname(slotkind(st, in.mid)));
			} else if(mm != Dis->AXNON || dm != Dis->AFP || slotkind(st, in.dst) != Kreal)
				return (nil, "real arithmetic operands");
		}
		return (nil, vwrite(v, st, dm, in.dst, Kreal, 'f'));
	Dis->IINDX =>
		if(sm != Dis->AFP || mm != Dis->AXINF)
			return (nil, "indx operands");
		ak := slotkind(st, in.src);
		ik := Kint;
		if(dm == Dis->AFP)
			ik = slotkind(st, in.dst);
		else if(dm != Dis->AIMM)
			return (nil, "indx index");
		if(ik != Kint)
			return (nil, "indx by " + kindname(ik));
		r: int;
		case ak {
		Karrv =>
			r = Kev;
			if(in.src == Fvs && in.mid == Fbp && dm == Dis->AFP && in.dst == Fbase)
				r = Kregs;	# the frame's registers: &vs[base]
		Karri =>
			r = Kei;
		Karrs =>
			r = Kes;
		Karra =>
			r = Kea;
		* =>
			return (nil, "indx of " + kindname(ak));
		}
		return (nil, vwrite(v, st, Dis->AFP, in.mid, r, 'w'));
	Dis->ICASE =>
		if(sm != Dis->AFP || slotkind(st, in.src) != Kint || dm != Dis->AMP || in.dst != 0)
			return (nil, "case operands");
		l: list of int;
		for(i := 1; i + 2 < len words; i += 3)
			l = words[i+2] :: l;
		return (words[len words - 1] :: l, nil);
	Dis->IJMP =>
		if(dm != Dis->AIMM)
			return (nil, "jmp target");
		return (in.dst :: nil, nil);
	Dis->IRET =>
		return (nil, nil);
	* =>
		if(!isbranch(in.op))
			return (nil, "opcode " + dis->op2s(in.op));
		acc := 'w';
		if(isfbranch(in.op))
			acc = 'f';
		(k1, e) := vread(v, st, sm, in.src, acc);
		if(e != nil)
			return (nil, e);
		k2 := Kint;
		case mm {
		Dis->AXINF =>
			k2 = slotkind(st, in.mid);
			if(acc == 'f' && k2 != Kreal)
				return (nil, "real branch on " + kindname(k2));
		Dis->AXIMM =>
			if(acc == 'f')
				return (nil, "real branch on an immediate");
		* =>
			return (nil, "branch operand");
		}
		if(acc == 'w' && !(k1 == Kint && k2 == Kint || k1 == Kshp && k2 == Kshp))
			return (nil, "branch on " + kindname(k1) + " and " + kindname(k2));
		if(dm != Dis->AIMM)
			return (nil, "branch target");
		return (in.dst :: nil, nil);
	}
}

slotkind(st: array of int, off: int): int
{
	if(off < 0 || off % 8 != 0 || off / 8 >= len st)
		return Ktop;
	return st[off/8];
}

# what an operand read gives (acc: 'w' a word, 'f' a real, 'm' a whole V)
vread(v: ref Vst, st: array of int, mode, val, acc: int): (int, string)
{
	case mode {
	Dis->AIMM =>
		if(acc != 'w')
			return (Ktop, "immediate");
		return (Kint, nil);
	Dis->AFP =>
		if(acc == 'm')
			return (Ktop, "a whole V from the frame");
		k := slotkind(st, val);
		if(k == Ktop || k == Kret)
			return (Ktop, sys->sprint("slot %d unknown", val));
		if(acc == 'f' && k != Kreal || acc == 'w' && k == Kreal)
			return (Ktop, sys->sprint("slot %d is %s", val, kindname(k)));
		return (k, nil);
	Dis->AIND|Dis->AFP =>
		outer := (val >> 16) & 16rFFFF;
		inner := val & 16rFFFF;
		k := slotkind(st, outer);
		case k {
		Kpst =>
			if(acc != 'w' || inner % 8 != 0 || inner / 8 >= len stkinds)
				return (Ktop, "st field");
			return (stkinds[inner/8], nil);
		Kev or Kregs =>
			f := inner;
			if(k == Kregs) {
				if(inner / Vsize >= v.nregs)
					return (Ktop, sys->sprint("register %d of %d", inner / Vsize, v.nregs));
				f = inner % Vsize;
			} else if(inner >= Vsize)
				return (Ktop, "past a V");
			case acc {
			'w' =>
				if(f != 0 && f != 8)
					return (Ktop, "a V's word");
				return (Kint, nil);
			'f' =>
				if(f != 16)
					return (Ktop, "a V's real");
				return (Kreal, nil);
			* =>
				if(f != 0)
					return (Ktop, "a V not at its start");
				return (Ktop, nil);
			}
		Kei =>
			if(acc != 'w' || inner != 0)
				return (Ktop, "an int element");
			return (Kint, nil);
		Kes =>
			if(acc != 'w' || inner != 0)
				return (Ktop, "a shape element");
			return (Kshp, nil);
		Kea =>
			if(acc != 'w' || inner != 0)
				return (Ktop, "an array element");
			return (Karrv, nil);
		Kshp =>
			if(acc != 'w' || inner != Shgen)
				return (Ktop, "a shape's field");
			return (Kint, nil);
		}
		return (Ktop, "through " + kindname(k));
	}
	return (Ktop, "operand mode");
}

vwrite(v: ref Vst, st: array of int, mode, val, kind, acc: int): string
{
	case mode {
	Dis->AFP =>
		if(acc == 'm')
			return "a whole V into the frame";
		if(val < Fst || val % 8 != 0 || val / 8 >= len st || val == Fst)
			return sys->sprint("slot %d", val);
		st[val/8] = kind;
		return nil;
	Dis->AIND|Dis->AFP =>
		outer := (val >> 16) & 16rFFFF;
		inner := val & 16rFFFF;
		k := slotkind(st, outer);
		case k {
		Kret =>
			if(acc != 'w' || inner != 0 || kind != Kint)
				return "the result";
			return nil;
		Kev or Kregs =>
			f := inner;
			if(k == Kregs) {
				if(inner / Vsize >= v.nregs)
					return sys->sprint("register %d of %d", inner / Vsize, v.nregs);
				f = inner % Vsize;
			} else if(inner >= Vsize)
				return "past a V";
			case acc {
			'w' =>
				if(f != 0 && f != 8 || kind != Kint)
					return "a V's word";
			'f' =>
				if(f != 16)
					return "a V's real";
			* =>
				if(f != 0)
					return "a V not at its start";
			}
			return nil;
		}
		return "into " + kindname(k);
	}
	return "destination mode";
}

kindname(k: int): string
{
	names := array[] of {"unknown", "word", "real", "st", "result", "V array", "int array", "shape array",
		"array array", "V", "int", "shape slot", "array slot", "shape", "registers"};
	if(k < 0 || k >= len names)
		return "?";
	return names[k];
}

# spoil m as a test asks (/env/jsjitcorrupt), at the first place it can
spoil(m: ref Dis->Mod, nregs: int, how: string)
{
	for(i := 0; i < len m.inst; i++) {
		in := m.inst[i];
		case how {
		"reg" =>
			# a register past the frame's
			if((in.addr & 7) == (Dis->AIND|Dis->AFP) && ((in.dst >> 16) & 16rFFFF) == Fbp) {
				in.dst = (Fbp << 16) | (nregs * Vsize);
				return;
			}
		"op" =>
			if(in.op == Dis->IMOVM) {
				in.op = Dis->IMOVP;
				return;
			}
		"jump" =>
			if(in.op == Dis->IJMP) {
				in.dst = len m.inst + 5;
				return;
			}
		"deref" =>
			# through a word as though an address
			if(in.op == Dis->IMOVM && ((in.addr >> 3) & 7) == (Dis->AIND|Dis->AFP)) {
				in.src = (Ft << 16) | 0;
				return;
			}
		}
	}
}
