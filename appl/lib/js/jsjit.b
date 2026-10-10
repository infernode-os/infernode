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
jitcompiled := 0;	# functions compiled, for -t

# Js->jit: when to compile (calls and loop iterations), -1 for never
jit(n: int)
{
	jitthreshold = n;
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
	jitdir = sys->sprint("/tmp/.jsjit.%d", sys->pctl(0, nil));
	jitst = ref Jitst(vs, 0, nil, nil, nil, nil, nil, nil);
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
	st := jitst;
	st.vs = vs;
	st.base = base;
	st.consts = c.consts;
	st.oshape = oshape;
	st.oslots = oslots;
	st.ics = c.ics;
	st.icslot = c.icslot;
	st.icgen = c.icgen;
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
Fregs: con 248;	# then each register's address, computed on entry
Shgen: con 48;	# Shape.gen
Fret: con 32;	# where run's result goes (through)
Vsize: con 24;	# a V: t at 0, x at 8, n at 16

Gen: adt {
	ins:	array of ref Dis->Inst;
	n:	int;
	rslot:	array of int;	# by register: the frame slot holding its address, or 0
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

ind(slot, off: int): int
{
	return (slot << 16) | off;
}

# the frame slot holding &vs[base + r] (computed on entry), or slot after
# computing it there
greg(g: ref Gen, r, slot: int): int
{
	if(r < len g.rslot && g.rslot[r] != 0)
		return g.rslot[r];
	gemit(g, Dis->IADDW, IMM, r, MFP, Fbase, FP, slot);
	gemit(g, Dis->IINDX, FP, Fvs, MFP, slot, FP, slot);
	return slot;
}

# the registers an operation compiled reads or writes
opregs(ops: array of int, pc: int): list of int
{
	case ops[pc] {
	Oundef or Onull or Otrue or Ofalse or Oempty or Oint or Oconst or Ojt or Ojf or Ochktdz =>
		return ops[pc+1] :: nil;
	Omove or Oinc or Odec or Otonumeric or Onot or Oneg or Ogetprop =>
		return ops[pc+1] :: ops[pc+2] :: nil;
	Osetprop =>
		return ops[pc+1] :: ops[pc+3] :: nil;
	Oadd or Osub or Omul or Odiv or Olt or Ole or Ogt or Oge =>
		return ops[pc+1] :: ops[pc+2] :: ops[pc+3] :: nil;
	}
	return nil;
}

Maxrslots: con 256;

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

Immmax: con 1 << 29;

# whether the operation at pc is one compiled code has
jitable(ops: array of int, pc: int): int
{
	case ops[pc] {
	Oundef or Onull or Otrue or Ofalse or Oempty or Oconst or Omove or
	Oadd or Osub or Omul or Odiv or Olt or Ole or Ogt or Oge or
	Oinc or Odec or Ojmp or Ojt or Ojf or Otonumeric or Ochktdz or Onot or Oneg or
	Ogetprop or Osetprop =>
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
	# the registers in use get their addresses computed on entry
	maxr := 0;
	for(pc = 0; pc < len ops; pc += oplen(ops[pc]))
		if(ent[pc] != byte 0)
			for(rl := opregs(ops, pc); rl != nil; rl = tl rl)
				if(hd rl + 1 > maxr)
					maxr = hd rl + 1;
	rslot := array[maxr] of {* => 0};
	nslot := 0;
	for(pc = 0; pc < len ops; pc += oplen(ops[pc]))
		if(ent[pc] != byte 0)
			for(rl2 := opregs(ops, pc); rl2 != nil; rl2 = tl rl2)
				if(rslot[hd rl2] == 0 && nslot < Maxrslots)
					rslot[hd rl2] = Fregs + 8 * nslot++;
	g := ref Gen(array[256] of ref Dis->Inst, 0, nil, nil, nil);
	# the prologue: st's fields into the frame, the registers' addresses,
	# then the case on pc
	gemit(g, Dis->IMOVP, IND, ind(Fst, 0), MNONE, 0, FP, Fvs);
	gemit(g, Dis->IMOVW, IND, ind(Fst, 8), MNONE, 0, FP, Fbase);
	gemit(g, Dis->IMOVP, IND, ind(Fst, 16), MNONE, 0, FP, Fk);
	for(f := 0; f < 5; f++)
		gemit(g, Dis->IMOVW, IND, ind(Fst, 24 + 8 * f), MNONE, 0, FP, Fos + 8 * f);
	for(r := 0; r < maxr; r++)
		if(rslot[r] != 0)
			greg(g, r, rslot[r]);
	g.rslot = rslot;
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
	# the module data's type, then run's frame: st, vs and consts are pointers
	m.types = array[] of {ref Dis->Type(m.dsize, 0, nil), ref Dis->Type(Fregs + 8 * nslot, 2, array[] of {byte 0, byte 16r98})};
	m.data = ref Disdata.Words((Dis->DEFW << 4), len words, 0, words) :: nil;
	m.links = array[] of {ref Dis->Link(0, 1, jitsig, "run")};
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
