#
# jsrx.b - matching (§22.2.2): a pattern's tree compiled to a small
# program run by a backtracking machine.  Included by jsre.b.
#
# The program's state is a position and the capture slots (and loop
# counters and marks, in registers after the slots).  A choice point
# saves the program counter, the position and the height of an undo
# log; every change to a slot or register is logged, so failing back to
# a choice point undoes it.  A loop iteration that consumed nothing
# fails, as the specification has it; captures inside a quantified atom
# are cleared at the start of each iteration.  Lookbehind is compiled
# with the direction reversed: characters are read leftward and a
# sequence's terms run last to first.
#

Xchar, Xany, Xset, Xsplit, Xjmp, Xsave, Xbol, Xeol, Xword, Xnotword, Xback, Xbackname,
Xlook, Xmatch, Xclear, Xsetc, Xcmin, Xcmax, Xmark, Xprog, Xinc, Xfail: con iota;

# flag bits carried by character instructions
Ficase, Fmulti, Fdotall, Fback: con 1 << iota;

C: adt {
	code:	array of int;
	n:	int;
	sets:	list of (int, ref Set);	# (negated, set)
	nset:	int;
	names:	list of array of int;	# groups by name, for \k with duplicate names
	nname:	int;
	nreg:	int;
	u:	int;
	ngroups:	int;
	pnames:	array of string;
};

cemit(c: ref C, x: int): int
{
	if(c.n == len c.code) {
		a := array[2 * len c.code + 32] of int;
		a[0:] = c.code[0:c.n];
		c.code = a;
	}
	c.code[c.n] = x;
	return c.n++;
}

compile(p: ref Pattern): ref Prog
{
	c := ref C(array[64] of int, 0, nil, 0, nil, 0, 0, (p.flags & (Fu|Fv)) != 0, p.ngroups, p.names);
	fl := 0;
	if(p.flags & Fi)
		fl |= Ficase;
	if(p.flags & Fm)
		fl |= Fmulti;
	if(p.flags & Fs)
		fl |= Fdotall;
	cemit(c, Xsave);
	cemit(c, 0);
	gen(c, p.re, fl);
	cemit(c, Xsave);
	cemit(c, 1);
	cemit(c, Xmatch);
	sets := array[c.nset] of (int, ref Set);
	for(l := c.sets; l != nil; l = tl l)
		sets[--c.nset] = hd l;
	names := array[c.nname] of array of int;
	for(nl := c.names; nl != nil; nl = tl nl)
		names[--c.nname] = hd nl;
	nslot := 2 * (p.ngroups + 1);
	return ref Prog(c.code[0:c.n], sets, names, nslot, c.nreg, c.u, p.flags);
}

newreg(c: ref C): int
{
	return c.nreg++;
}

# the groups numbered inside e: (lowest, highest), or (0, -1)
groupspan(e: ref Re): (int, int)
{
	lo := 1 << 30;
	hi := -1;
	pick x := e {
	Group =>
		lo = x.n;
		hi = x.n;
		(l, h) := groupspan(x.e);
		if(h >= 0) {
			if(l < lo)
				lo = l;
			if(h > hi)
				hi = h;
		}
	Seq =>
		for(i := 0; i < len x.items; i++) {
			(l, h) := groupspan(x.items[i]);
			if(h >= 0) {
				if(l < lo)
					lo = l;
				if(h > hi)
					hi = h;
			}
		}
	Alt =>
		for(i := 0; i < len x.alts; i++) {
			(l, h) := groupspan(x.alts[i]);
			if(h >= 0) {
				if(l < lo)
					lo = l;
				if(h > hi)
					hi = h;
			}
		}
	Mod =>
		return groupspan(x.e);
	Look =>
		return groupspan(x.e);
	Repeat =>
		return groupspan(x.e);
	}
	if(hi < 0)
		return (0, -1);
	return (lo, hi);
}

gen(c: ref C, e: ref Re, fl: int)
{
	pick x := e {
	Empty =>
		;
	Char =>
		cemit(c, Xchar);
		cemit(c, x.c);
		cemit(c, fl);
	Any =>
		cemit(c, Xany);
		cemit(c, fl);
	Seq =>
		n := len x.items;
		for(i := 0; i < n; i++) {
			if(fl & Fback)
				gen(c, x.items[n-1-i], fl);
			else
				gen(c, x.items[i], fl);
		}
	Alt =>
		# split L1, next; L1: a; jmp end; next: split L2, ... last
		ends: list of int;
		for(i := 0; i < len x.alts - 1; i++) {
			cemit(c, Xsplit);
			a1 := cemit(c, 0);
			a2 := cemit(c, 0);
			c.code[a1] = c.n;
			gen(c, x.alts[i], fl);
			cemit(c, Xjmp);
			ends = cemit(c, 0) :: ends;
			c.code[a2] = c.n;
		}
		gen(c, x.alts[len x.alts - 1], fl);
		for(; ends != nil; ends = tl ends)
			c.code[hd ends] = c.n;
	Group =>
		s0 := 2 * x.n;
		s1 := s0 + 1;
		if(fl & Fback)
			(s0, s1) = (s1, s0);
		cemit(c, Xsave);
		cemit(c, s0);
		gen(c, x.e, fl);
		cemit(c, Xsave);
		cemit(c, s1);
	Mod =>
		nf := fl;
		if(x.add & Fi)
			nf |= Ficase;
		if(x.add & Fm)
			nf |= Fmulti;
		if(x.add & Fs)
			nf |= Fdotall;
		if(x.rem & Fi)
			nf &= ~Ficase;
		if(x.rem & Fm)
			nf &= ~Fmulti;
		if(x.rem & Fs)
			nf &= ~Fdotall;
		gen(c, x.e, nf);
	Look =>
		cemit(c, Xlook);
		kind := x.neg;
		at := cemit(c, kind);
		endat := cemit(c, 0);
		sub := fl & ~Fback;
		if(x.behind)
			sub |= Fback;
		gen(c, x.e, sub);
		cemit(c, Xmatch);
		c.code[endat] = c.n;
		at = 0;
	Assert =>
		case x.kind {
		Abol =>
			cemit(c, Xbol);
			cemit(c, fl);
		Aeol =>
			cemit(c, Xeol);
			cemit(c, fl);
		Aword =>
			cemit(c, Xword);
			cemit(c, fl);
		Anotword =>
			cemit(c, Xnotword);
			cemit(c, fl);
		}
	Backref =>
		if(x.name != nil) {
			gs: list of int;
			for(i := len c.pnames - 1; i >= 1; i--)
				if(c.pnames[i] == x.name)
					gs = i :: gs;
			a := array[len gs] of int;
			for(i = 0; gs != nil; gs = tl gs)
				a[i++] = hd gs;
			c.names = a :: c.names;
			cemit(c, Xbackname);
			cemit(c, c.nname++);
			cemit(c, fl);
		} else {
			cemit(c, Xback);
			cemit(c, x.n);
			cemit(c, fl);
		}
	Class =>
		if(hasstrings(x.set) && !x.neg) {
			genstrings(c, x.set, fl);
			return;
		}
		c.sets = (x.neg, x.set) :: c.sets;
		cemit(c, Xset);
		cemit(c, c.nset++);
		cemit(c, fl);
	Repeat =>
		genrepeat(c, x, fl);
	}
}

# a counted loop (any quantifier): count in rc, the iteration's start in rp
#	setc rc
#   L:	cmin rc min Lbody	(fewer than min: an iteration must follow)
#	cmax rc max Lout	(max reached)
#	split Lbody, Lout	(or the other way, lazy)
#   Lbody: mark rp; clear groups; body; prog rp rc min; inc rc; jmp L
#   Lout:
genrepeat(c: ref C, x: ref Re.Repeat, fl: int)
{
	if(x.max == 0)
		return;
	if(x.min == 1 && x.max == 1) {
		gen(c, x.e, fl);
		return;
	}
	rc := newreg(c);
	rp := newreg(c);
	(glo, ghi) := groupspan(x.e);
	cemit(c, Xsetc);
	cemit(c, rc);
	top := c.n;
	cemit(c, Xcmin);
	cemit(c, rc);
	cemit(c, x.min);
	tobody := cemit(c, 0);
	cemit(c, Xcmax);
	cemit(c, rc);
	cemit(c, x.max);
	toout := cemit(c, 0);
	cemit(c, Xsplit);
	s1 := cemit(c, 0);
	s2 := cemit(c, 0);
	body := c.n;
	c.code[tobody] = body;
	cemit(c, Xmark);
	cemit(c, rp);
	if(ghi >= 0) {
		cemit(c, Xclear);
		cemit(c, 2 * glo);
		cemit(c, 2 * ghi + 1);
	}
	gen(c, x.e, fl);
	cemit(c, Xprog);
	cemit(c, rp);
	cemit(c, rc);
	cemit(c, x.min);
	cemit(c, Xinc);
	cemit(c, rc);
	cemit(c, Xjmp);
	cemit(c, top);
	out := c.n;
	c.code[toout] = out;
	if(x.greedy) {
		c.code[s1] = body;
		c.code[s2] = out;
	} else {
		c.code[s1] = out;
		c.code[s2] = body;
	}
}

hasstrings(s: ref Set): int
{
	if(s.op != Ounion)
		return 0;
	for(i := 0; i < len s.items; i++)
		pick it := s.items[i] {
		Strs =>
			for(j := 0; j < len it.strs; j++)
				if(len it.strs[j] != 1)
					return 1;
		}
	return 0;
}

# a v-mode class with strings: the strings, longest first, then the single characters
genstrings(c: ref C, s: ref Set, fl: int)
{
	strs: list of string;
	chars: list of ref Item;
	for(i := 0; i < len s.items; i++) {
		pick it := s.items[i] {
		Strs =>
			for(j := 0; j < len it.strs; j++)
				if(len it.strs[j] == 1)
					chars = ref Item.Range(it.strs[j][0], it.strs[j][0]) :: chars;
				else
					strs = it.strs[j] :: strs;
		* =>
			chars = s.items[i] :: chars;
		}
	}
	# sort the strings by length, longest first
	a := array[len strs] of string;
	for(i = 0; strs != nil; strs = tl strs)
		a[i++] = hd strs;
	for(i = 1; i < len a; i++) {
		x := a[i];
		j := i - 1;
		while(j >= 0 && len a[j] < len x) {
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = x;
	}
	alts: list of ref Re;
	for(i = 0; i < len a; i++) {
		items := array[len a[i]] of ref Re;
		k := 0;
		for(p := 0; p < len a[i]; p++) {
			(cp, w) := cpat0(a[i], p, c.u);
			items[k++] = ref Re.Char(cp);
			p += w - 1;
		}
		alts = ref Re.Seq(items[0:k]) :: alts;
	}
	if(chars != nil) {
		ci := array[len chars] of ref Item;
		for(i = len ci - 1; chars != nil; chars = tl chars)
			ci[i--] = hd chars;
		alts = ref Re.Class(0, ref Set(Ounion, ci)) :: alts;
	}
	ra := array[len alts] of ref Re;
	for(i = len ra - 1; alts != nil; alts = tl alts)
		ra[i--] = hd alts;
	if(len ra == 0) {
		cemit(c, Xfail);
		return;
	}
	if(len ra == 1)
		gen(c, ra[0], fl);
	else
		gen(c, ref Re.Alt(ra), fl);
}

cpat0(s: string, i, u: int): (int, int)
{
	c := s[i];
	if(u && c >= 16rD800 && c <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF)
		return (16r10000 + ((c - 16rD800) << 10) + (s[i+1] - 16rDC00), 2);
	return (c, 1);
}

# ---- the machine ----

M: adt {
	p:	ref Prog;
	s:	string;
	slots:	array of int;	# captures, then registers
	stk:	array of int;	# choice points and undo entries
	sp:	int;
	steps:	int;
};

Ychoice, Yundo: con iota;

push3(m: ref M, a, b, c: int)
{
	if(m.sp + 3 > len m.stk) {
		n := array[2 * len m.stk + 64] of int;
		n[0:] = m.stk[0:m.sp];
		m.stk = n;
	}
	m.stk[m.sp++] = a;
	m.stk[m.sp++] = b;
	m.stk[m.sp++] = c;
}

setslot(m: ref M, i, v: int)
{
	push3(m, Yundo, i, m.slots[i]);
	m.slots[i] = v;
}

# exec: a match at start or (unless sticky) after it: the capture positions, or nil
exec(p: ref Pattern, s: string, start: int, sticky: int): array of int
{
	if(p.prog == nil)
		p.prog = compile(p);
	pr := p.prog;
	m := ref M(pr, s, array[pr.nslot + pr.nreg] of int, array[256] of int, 0, 0);
	for(i := start; i <= len s; ) {
		for(k := 0; k < len m.slots; k++)
			m.slots[k] = -1;
		m.sp = 0;
		if(run(m, 0, i, len pr.code)) {
			r := array[pr.nslot] of int;
			r[0:] = m.slots[0:pr.nslot];
			return r;
		}
		if(sticky)
			break;
		# the next position (a whole code point in u mode)
		if(pr.u && i < len s && s[i] >= 16rD800 && s[i] <= 16rDBFF && i + 1 < len s && s[i+1] >= 16rDC00 && s[i+1] <= 16rDFFF)
			i += 2;
		else
			i++;
	}
	return nil;
}

# run the program from pc at pos until Xmatch (1) or failure (0); end: the code's end
run(m: ref M, pc, pos, nil: int): int
{
	code := m.p.code;
	s := m.s;
	base := m.sp;
	for(;;) {
		ok := 1;
		case code[pc] {
		Xchar =>
			c := code[pc+1];
			fl := code[pc+2];
			(ch, npos) := readch(m, pos, fl);
			if(npos < 0)
				ok = 0;
			else if(ch == c || (fl & Ficase) && canon(ch, m.p.u) == canon(c, m.p.u)) {
				pos = npos;
				pc += 3;
			} else
				ok = 0;
		Xany =>
			fl := code[pc+1];
			(ch, npos) := readch(m, pos, fl);
			if(npos < 0 || (fl & Fdotall) == 0 && islt(ch))
				ok = 0;
			else {
				pos = npos;
				pc += 2;
			}
		Xset =>
			fl := code[pc+2];
			(ch, npos) := readch(m, pos, fl);
			if(npos < 0)
				ok = 0;
			else {
				(neg, set) := m.p.sets[code[pc+1]];
				in := setmatch(set, ch, fl, m.p.u, m.p.flags);
				if(neg)
					in = !in;
				if(in) {
					pos = npos;
					pc += 3;
				} else
					ok = 0;
			}
		Xsplit =>
			push3(m, Ychoice, code[pc+2], pos);
			pc = code[pc+1];
		Xjmp =>
			pc = code[pc+1];
		Xsave =>
			setslot(m, code[pc+1], pos);
			pc += 2;
		Xbol =>
			if(pos == 0 || (code[pc+1] & Fmulti) && islt(s[pos-1]))
				pc += 2;
			else
				ok = 0;
		Xeol =>
			if(pos == len s || (code[pc+1] & Fmulti) && islt(s[pos]))
				pc += 2;
			else
				ok = 0;
		Xword or Xnotword =>
			fl := code[pc+1];
			a := pos > 0 && iswordch(s[pos-1], fl, m.p.u);
			b := pos < len s && iswordch(s[pos], fl, m.p.u);
			if((a != b) == (code[pc] == Xword))
				pc += 2;
			else
				ok = 0;
		Xback or Xbackname =>
			n := code[pc+1];
			fl := code[pc+2];
			if(code[pc] == Xbackname) {
				gs := m.p.names[n];
				n = -1;
				for(i := 0; i < len gs; i++)
					if(m.slots[2*gs[i]] >= 0 && m.slots[2*gs[i]+1] >= 0) {
						n = gs[i];
						break;
					}
			}
			if(n < 0 || m.slots[2*n] < 0 || m.slots[2*n+1] < 0) {
				pc += 3;
				break;
			}
			st := m.slots[2*n];
			e := m.slots[2*n+1];
			l := e - st;
			if(fl & Fback) {
				if(pos - l < 0 || !samechars(s, st, pos - l, l, fl, m.p.u))
					ok = 0;
				else {
					pos -= l;
					pc += 3;
				}
			} else {
				if(pos + l > len s || !samechars(s, st, pos, l, fl, m.p.u))
					ok = 0;
				else {
					pos += l;
					pc += 3;
				}
			}
		Xlook =>
			neg := code[pc+1];
			end := code[pc+2];
			saved := array[len m.slots] of int;
			saved[0:] = m.slots;
			sm := ref M(m.p, s, m.slots, array[64] of int, 0, 0);
			found := run(sm, pc + 3, pos, end);
			if(neg) {
				m.slots[0:] = saved;
				if(found)
					ok = 0;
				else
					pc = end;
			} else {
				if(!found) {
					m.slots[0:] = saved;
					ok = 0;
				} else {
					# keep its captures: log them so a later failure undoes them
					now := array[len m.slots] of int;
					now[0:] = m.slots;
					m.slots[0:] = saved;
					for(i := 0; i < len now; i++)
						if(now[i] != saved[i])
							setslot(m, i, now[i]);
					pc = end;
				}
			}
		Xmatch =>
			m.sp = base;
			return 1;
		Xclear =>
			for(i := code[pc+1]; i <= code[pc+2]; i++)
				if(m.slots[i] != -1)
					setslot(m, i, -1);
			pc += 3;
		Xsetc =>
			setslot(m, m.p.nslot + code[pc+1], 0);
			pc += 2;
		Xcmin =>
			if(m.slots[m.p.nslot + code[pc+1]] < code[pc+2])
				pc = code[pc+3];
			else
				pc += 4;
		Xcmax =>
			mx := code[pc+2];
			if(mx >= 0 && m.slots[m.p.nslot + code[pc+1]] >= mx)
				pc = code[pc+3];
			else
				pc += 4;
		Xmark =>
			setslot(m, m.p.nslot + code[pc+1], pos);
			pc += 2;
		Xprog =>
			# an optional iteration that matched nothing fails
			if(m.slots[m.p.nslot + code[pc+2]] >= code[pc+3] && m.slots[m.p.nslot + code[pc+1]] == pos)
				ok = 0;
			else
				pc += 4;
		Xinc =>
			r := m.p.nslot + code[pc+1];
			setslot(m, r, m.slots[r] + 1);
			pc += 2;
		Xfail =>
			ok = 0;
		* =>
			ok = 0;
		}
		if(ok)
			continue;
		# back to the last choice point, undoing as we go
		for(;;) {
			if(m.sp <= base)
				return 0;
			m.sp -= 3;
			kind := m.stk[m.sp];
			if(kind == Yundo) {
				m.slots[m.stk[m.sp+1]] = m.stk[m.sp+2];
				continue;
			}
			pc = m.stk[m.sp+1];
			pos = m.stk[m.sp+2];
			break;
		}
		if(++m.steps > 50000000)
			return 0;
	}
}

# read the character at pos in the direction fl says: (char, new position) or (-1, -1)
readch(m: ref M, pos, fl: int): (int, int)
{
	s := m.s;
	if(fl & Fback) {
		if(pos <= 0)
			return (-1, -1);
		c := s[pos-1];
		if(m.p.u && c >= 16rDC00 && c <= 16rDFFF && pos >= 2 && s[pos-2] >= 16rD800 && s[pos-2] <= 16rDBFF)
			return (16r10000 + ((s[pos-2] - 16rD800) << 10) + (c - 16rDC00), pos - 2);
		return (c, pos - 1);
	}
	if(pos >= len s)
		return (-1, -1);
	c := s[pos];
	if(m.p.u && c >= 16rD800 && c <= 16rDBFF && pos + 1 < len s && s[pos+1] >= 16rDC00 && s[pos+1] <= 16rDFFF)
		return (16r10000 + ((c - 16rD800) << 10) + (s[pos+1] - 16rDC00), pos + 2);
	return (c, pos + 1);
}

islt(c: int): int
{
	return c == '\n' || c == '\r' || c == 16r2028 || c == 16r2029;
}

iswordch(c, fl, u: int): int
{
	if(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_')
		return 1;
	if(u && (fl & Ficase) && (c == 16r17F || c == 16r212A))
		return 1;
	return 0;
}

samechars(s: string, a, b, l, fl, u: int): int
{
	for(i := 0; i < l; i++) {
		x := s[a+i];
		y := s[b+i];
		if(x == y)
			continue;
		if((fl & Ficase) && canon(x, u) == canon(y, u))
			continue;
		return 0;
	}
	return 1;
}

# Canonicalize (§22.2.2.7.3): simple case folding (u, v) or upper case (otherwise)
canon(c, u: int): int
{
	if(u)
		return fold(c);
	if(c < 128) {
		if(c >= 'a' && c <= 'z')
			return c - 32;
		return c;
	}
	up := upper1(c);
	if(up < 128)
		return c;	# a non-ASCII character does not become ASCII
	return up;
}

# simple case folding, for the common scripts
fold(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		return c + 32;
	if(c < 128)
		return c;
	case c {
	16rB5 => return 16r3BC;
	16r17F => return 's';
	16r212A => return 'k';
	16r212B => return 16rE5;
	16r1E9E => return 16rDF;
	16r3C2 => return 16r3C3;
	16r3D0 => return 16r3B2;
	16r3D1 => return 16r3B8;
	16r3D5 => return 16r3C6;
	16r3D6 => return 16r3C0;
	16r3F0 => return 16r3BA;
	16r3F1 => return 16r3C1;
	16r3F5 => return 16r3B5;
	16r1FBE => return 16r3B9;
	16r345 => return 16r3B9;
	}
	l := lower1(c);
	if(l != c)
		return l;
	return c;
}

lower1(c: int): int
{
	if(c >= 16rC0 && c <= 16rDE && c != 16rD7)
		return c + 32;
	if(c >= 16r391 && c <= 16r3AB && c != 16r3A2)
		return c + 32;
	if(c >= 16r410 && c <= 16r42F)
		return c + 32;
	if(c >= 16r400 && c <= 16r40F)
		return c + 80;
	if(c >= 16r100 && c <= 16r17F && (c & 1) == 0 && c != 16r130 && c != 16r138)
		return c + 1;
	if(c >= 16r10400 && c <= 16r10427)
		return c + 40;
	if(c >= 16rFF21 && c <= 16rFF3A)
		return c + 32;
	if(c >= 16r24B6 && c <= 16r24CF)
		return c + 26;
	return c;
}

upper1(c: int): int
{
	if(c >= 'a' && c <= 'z')
		return c - 32;
	if(c >= 16rE0 && c <= 16rFE && c != 16rF7)
		return c - 32;
	if(c == 16rFF)
		return 16r178;
	if(c == 16rB5)
		return 16r39C;
	if(c >= 16r3B1 && c <= 16r3CB && c != 16r3C2)
		return c - 32;
	if(c == 16r3C2)
		return 16r3A3;
	if(c >= 16r430 && c <= 16r44F)
		return c - 32;
	if(c >= 16r450 && c <= 16r45F)
		return c - 80;
	if(c >= 16r100 && c <= 16r17F && (c & 1) == 1 && c != 16r131 && c != 16r149 && c != 16r17F)
		return c - 1;
	if(c == 16r17F)
		return 'S';
	if(c >= 16rFF41 && c <= 16rFF5A)
		return c - 32;
	return c;
}

# whether c is in the set (with fl's case-insensitivity)
setmatch(s: ref Set, c, fl, u, flags: int): int
{
	case s.op {
	Ounion =>
		for(i := 0; i < len s.items; i++)
			if(itemmatch(s.items[i], c, fl, u, flags))
				return 1;
		return 0;
	Ointer =>
		for(i := 0; i < len s.items; i++)
			if(!itemmatch(s.items[i], c, fl, u, flags))
				return 0;
		return len s.items > 0;
	Osub =>
		if(len s.items == 0 || !itemmatch(s.items[0], c, fl, u, flags))
			return 0;
		for(i := 1; i < len s.items; i++)
			if(itemmatch(s.items[i], c, fl, u, flags))
				return 0;
		return 1;
	}
	return 0;
}

itemmatch(it: ref Item, c, fl, u, flags: int): int
{
	pick x := it {
	Range =>
		if(c >= x.lo && c <= x.hi)
			return 1;
		if(fl & Ficase) {
			cc := canon(c, u);
			if(cc >= x.lo && cc <= x.hi && canon(cc, u) == cc)
				return 1;
			# the range's characters that canonicalise as c does
			if(x.hi - x.lo < 512) {
				for(k := x.lo; k <= x.hi; k++)
					if(canon(k, u) == cc)
						return 1;
			} else {
				# a large range: c's case variants
				if(lower1(c) >= x.lo && lower1(c) <= x.hi || upper1(c) >= x.lo && upper1(c) <= x.hi)
					return 1;
			}
		}
		return 0;
	Esc =>
		return escmatch(x.kind, c, fl, u);
	Prop =>
		r := propmatch(x.name, x.value, c);
		if(x.neg)
			return !r;
		return r;
	Nested =>
		r := setmatch(x.set, c, fl, u, flags);
		if(x.neg)
			return !r;
		return r;
	Strs =>
		for(i := 0; i < len x.strs; i++)
			if(len x.strs[i] == 1 && (x.strs[i][0] == c || (fl & Ficase) && canon(x.strs[i][0], u) == canon(c, u)))
				return 1;
		return 0;
	}
	return 0;
}

isspace(c: int): int
{
	case c {
	'\t' or '\n' or 16r0B or 16r0C or '\r' or ' ' or 16rA0 or 16r1680 or 16r2028 or 16r2029 or 16r202F or 16r205F or 16r3000 or 16rFEFF =>
		return 1;
	}
	return c >= 16r2000 && c <= 16r200A;
}

escmatch(kind, c, fl, u: int): int
{
	case kind {
	Cdigit => return c >= '0' && c <= '9';
	Cnotdigit => return !(c >= '0' && c <= '9');
	Cspace => return isspace(c);
	Cnotspace => return !isspace(c);
	Cword => return iswordch(c, fl, u);
	Cnotword => return !iswordch(c, fl, u);
	}
	return 0;
}

# Unicode properties, for the common ones; the full tables are to come
propmatch(name, value: string, c: int): int
{
	if(value != nil) {
		case name {
		"General_Category" or "gc" =>
			return gcmatch(value, c);
		"Script" or "sc" or "Script_Extensions" or "scx" =>
			return scmatch(value, c);
		}
		return 0;
	}
	case name {
	"Any" => return 1;
	"ASCII" => return c < 128;
	"Assigned" => return c < 16r30000;
	"ASCII_Hex_Digit" or "AHex" => return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F';
	"Alphabetic" or "Alpha" => return gcmatch("L", c) || gcmatch("Nl", c);
	"Uppercase" or "Upper" => return gcmatch("Lu", c);
	"Lowercase" or "Lower" => return gcmatch("Ll", c);
	"White_Space" or "space" => return isspace(c) && c != 16rFEFF || c == 16r85;
	"ID_Start" or "IDS" => return jslex->isidstart(c) && c != '$' && c != '_';
	"ID_Continue" or "IDC" => return jslex->isidpart(c) && c != '$';
	}
	return gcmatch(name, c);
}

gcmatch(v: string, c: int): int
{
	case v {
	"L" or "Letter" =>
		return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c > 127 && jslex->isidstart(c) && !gcmatch("Nl", c);
	"Lu" or "Uppercase_Letter" =>
		return c >= 'A' && c <= 'Z' || c > 127 && lower1(c) != c;
	"Ll" or "Lowercase_Letter" =>
		return c >= 'a' && c <= 'z' || c > 127 && upper1(c) != c;
	"N" or "Number" or "Nd" or "Decimal_Number" or "digit" =>
		return c >= '0' && c <= '9' || c >= 16r660 && c <= 16r669 || c >= 16r966 && c <= 16r96F || c >= 16rFF10 && c <= 16rFF19;
	"Nl" or "Letter_Number" =>
		return c >= 16r2160 && c <= 16r2188 || c >= 16r16EE && c <= 16r16F0 || c == 16r3007;
	"P" or "Punctuation" or "punct" =>
		return c < 128 && (c >= '!' && c <= '/' || c >= ':' && c <= '@' || c >= '[' && c <= '`' || c >= '{' && c <= '~') && c != '$' && c != '+' && c != '<' && c != '=' && c != '>' && c != '^' && c != '`' && c != '|' && c != '~';
	"Zs" or "Space_Separator" =>
		return c == ' ' || c == 16rA0 || c == 16r1680 || c >= 16r2000 && c <= 16r200A || c == 16r202F || c == 16r205F || c == 16r3000;
	"Cc" or "Control" or "cntrl" =>
		return c < 32 || c >= 127 && c < 160;
	}
	return 0;
}

scmatch(v: string, c: int): int
{
	case v {
	"Latin" or "Latn" =>
		return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= 16rC0 && c <= 16r24F && c != 16rD7 && c != 16rF7;
	"Greek" or "Grek" =>
		return c >= 16r370 && c <= 16r3FF && c != 16r37E && c != 16r387;
	"Cyrillic" or "Cyrl" =>
		return c >= 16r400 && c <= 16r52F;
	"Han" or "Hani" =>
		return c >= 16r4E00 && c <= 16r9FFF || c >= 16r3400 && c <= 16r4DBF;
	"Arabic" or "Arab" =>
		return c >= 16r600 && c <= 16r6FF && c != 16r60C && c != 16r61B && c != 16r61F && c != 16r640;
	"Hebrew" or "Hebr" =>
		return c >= 16r591 && c <= 16r5F4;
	"Thai" =>
		return c >= 16rE01 && c <= 16rE5B && c != 16rE3F;
	}
	return 0;
}
