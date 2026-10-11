implement Proto3;

include "sys.m";
	sys: Sys;
include "draw.m";

Proto3: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Tundef, Tnum, Tobj, Tint: con iota;

Obj: adt {
	shape:	ref Shape;
	tags:	array of int;
	ints:	array of int;
	nums:	array of real;
	objs:	array of ref Obj;
};
Shape: adt { keys: array of string; };

# node kinds
Nint, Nlocal, Nsetlocal, Nadd, Nmul, Nmod, Nlt, Nget, Nset, Ninc, Nwhile, Nseq: con iota;

# the tree, flattened
op:	array of int;
na:	array of int;
nb:	array of int;
nc:	array of int;
ish:	array of ref Shape;	# inline cache shape
ics:	array of int;	# inline cache slot
keys:	array of string;
nn := 0;

at: int;
ai: int;
an: real;
ao: ref Obj;

ft: array of int;
fi: array of int;
fnu: array of real;
fo: array of ref Obj;

mk(o, a, b, c: int): int
{
	op[nn] = o; na[nn] = a; nb[nn] = b; nc[nn] = c;
	return nn++;
}

# the value of node n in (at, ai, an, ao)
eval(n: int)
{
	case op[n] {
	Nint =>
		at = Tint; ai = na[n];
	Nlocal =>
		s := na[n];
		at = ft[s]; ai = fi[s]; an = fnu[s]; ao = fo[s];
	Nsetlocal =>
		eval(nb[n]);
		s := na[n];
		ft[s] = at; fi[s] = ai; fnu[s] = an; fo[s] = ao;
	Nadd or Nmul or Nmod or Nlt =>
		l := na[n];
		lt, li: int;
		ln: real;
		if(op[l] == Nlocal) {
			s := na[l];
			lt = ft[s]; li = fi[s]; ln = fnu[s];
		} else {
			eval(l);
			lt = at; li = ai; ln = an;
		}
		r := nb[n];
		case op[r] {
		Nint =>
			at = Tint; ai = na[r];
		Nlocal =>
			s := na[r];
			at = ft[s]; ai = fi[s]; an = fnu[s]; ao = fo[s];
		* =>
			eval(r);
		}
		if(lt == Tint && at == Tint) {
			case op[n] {
			Nadd =>
				v := li + ai;
				if(((li ^ v) & (ai ^ v)) >= 0) { ai = v; return; }
				at = Tnum; an = real li + real ai;
			Nmul =>
				b := big li * big ai;
				if(b == big int b) { ai = int b; return; }
				at = Tnum; an = real b;
			Nmod =>
				if(li >= 0 && ai > 0) { ai = li % ai; return; }
				raise "mod";
			Nlt =>
				if(li < ai) ai = 1; else ai = 0;
				at = Tint;
			}
		} else
			raise "slow";
	Nget =>
		eval(na[n]);
		o := ao;
		c := ics[n];
		if(o.shape != ish[n]) {
			k := keys[nb[n]];
			sh := o.shape;
			for(c = 0; c < len sh.keys; c++)
				if(sh.keys[c] == k)
					break;
			ics[n] = c; ish[n] = sh;
		}
		at = o.tags[c]; ai = o.ints[c]; an = o.nums[c]; ao = o.objs[c];
	Nset =>
		eval(na[n]);
		o := ao;
		eval(nc[n]);
		c := ics[n];
		if(o.shape != ish[n]) {
			k := keys[nb[n]];
			sh := o.shape;
			for(c = 0; c < len sh.keys; c++)
				if(sh.keys[c] == k)
					break;
			ics[n] = c; ish[n] = sh;
		}
		o.tags[c] = at; o.ints[c] = ai; o.nums[c] = an; o.objs[c] = ao;
	Ninc =>
		fi[na[n]]++;
	Nwhile =>
		t := na[n];
		b := nb[n];
		for(;;) {
			eval(t);
			if(ai == 0)
				break;
			eval(b);
		}
	Nseq =>
		for(i := na[n]; i < nb[n]; i++)
			eval(nc[i]);
	}
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	N := 100;
	op = array[N] of int; na = array[N] of int; nb = array[N] of int; nc = array[N] of int;
	ish = array[N] of ref Shape; ics = array[N] of int;
	keys = array[] of {"x", "y"};
	ft = array[8] of {* => Tint};
	fi = array[8] of {* => 0};
	fnu = array[8] of {* => 0.0};
	fo = array[8] of ref Obj;
	# s = (s*3 + i) % 1000003; i++  -- seq children stored in nc of slots 50..
	body0 := mk(Nsetlocal, 0, mk(Nmod, mk(Nadd, mk(Nmul, mk(Nlocal, 0, 0, 0), mk(Nint, 3, 0, 0), 0), mk(Nlocal, 1, 0, 0), 0), mk(Nint, 1000003, 0, 0), 0), 0);
	body1 := mk(Ninc, 1, 0, 0);
	nc[50] = body0; nc[51] = body1;
	seq := mk(Nseq, 50, 52, 0);
	prog := mk(Nwhile, mk(Nlt, mk(Nlocal, 1, 0, 0), mk(Nint, 3000000, 0, 0), 0), seq, 0);
	t := sys->millisec();
	eval(prog);
	sys->print("counter %d ms %d\n", sys->millisec()-t, fi[0]);

	o := ref Obj(ref Shape(array[] of {"x", "y"}), array[] of {Tint, Tint}, array[] of {1, 2}, array[2] of {* => 0.0}, array[2] of ref Obj);
	ft[2] = Tobj; fo[2] = o; fi[1] = 0;
	b0 := mk(Nset, mk(Nlocal, 2, 0, 0), 0, mk(Nadd, mk(Nget, mk(Nlocal, 2, 0, 0), 0, 0), mk(Nget, mk(Nlocal, 2, 0, 0), 1, 0), 0));
	nc[60] = b0; nc[61] = mk(Ninc, 1, 0, 0);
	prog = mk(Nwhile, mk(Nlt, mk(Nlocal, 1, 0, 0), mk(Nint, 1000000, 0, 0), 0), mk(Nseq, 60, 62, 0), 0);
	t = sys->millisec();
	eval(prog);
	sys->print("prop %d ms %d\n", sys->millisec()-t, o.ints[0]);
}
