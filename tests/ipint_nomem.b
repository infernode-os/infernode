implement IPintNomem;

#
# IPint where the old code ended the emulator or lost the kernel's memory
# (tests/host/ipint_nomem_test.sh runs this in an emulator of its own,
# with a small main pool, which it fills).
#
# - A long operation copies its operands and makes its result with the
#   VM let go, and libmp raises when there is no memory for what it is
#   asked: the raise left through the builtin and the copies and the
#   result were lost with it, megabytes of the kernel's pool at a time,
#   for good.
# - strtoip in base 32 of a length base 32 does not have (1, 3 or 6
#   digits past a multiple of 8) gave the decoder's -1 to betomp as a
#   count of bytes: it read 4GB and wrote backwards through the pool.
# - The longest number bytestoip made (2^28-4 bytes) plus one, or times
#   three, was stored past a block of a hundred bytes; 2^29 bytes and
#   more were stored before it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;

IPintNomem: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

MB: con 1024*1024;

# bytes in use in a kernel pool, from /dev/memory
used(pool: string): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf >= 8 && hd tl tl tl tl tl tl tl f == pool)
			return int hd f;
	}
	return -1;
}

fill: list of ref IPint;
small: list of ref IPint;

# numbers of nb bytes until there is no room for another
more(nb: int): list of ref IPint
{
	l: list of ref IPint;
	a := array[nb] of {* => byte 16r5a};
	{
		for(;;)
			l = IPint.bytestoip(a) :: l;
	} exception {
	"*" =>
		;
	}
	return l;
}

# the main pool with 8MB free in one piece and little else
fillmain()
{
	fill = more(8*MB);
	small = more(MB);
	small = more(64*1024);
	fill = tl fill;
}

try(which: string, x, y, m: ref IPint): int
{
	{
		case which {
		"mul" =>	x.mul(y);
		"div" =>	x.div(y);
		"mod" =>	x.mod(y);
		"expmod" =>	x.expmod(y, m);
		}
	} exception {
	"*" =>
		return 1;
	}
	return 0;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	ipints = load IPints IPints->PATH;

	# base 32: lengths that are no number
	nils := 0;
	strs := array[] of {"2", "222", "222222", "A", "22222222222", "2222222222222a"};
	for(i := 0; i < len strs; i++){
		{
			if(IPint.strtoip(strs[i], 32) == nil)
				nils++;
		} exception e {
		"*" =>
			sys->print("B32 %s raised %s\n", strs[i], e);
		}
	}
	sys->print("B32 %d of %d nil\n", nils, len strs);

	# bytes whose bits pass an int, or reach it
	sizes := array[] of {(1<<28)-4, (1<<28)+1, (1<<29)+1};
	nref := 0;
	for(i = 0; i < len sizes; i++){
		a := array[sizes[i]] of {* => byte 16r41};
		{
			x := IPint.bytestoip(a);
			# the old code went on from here
			x.add(IPint.inttoip(1));
			x.mul(IPint.inttoip(3));
		} exception e {
		"IPint: number too large" =>
			nref++;
		"*" =>
			sys->print("BYTES %d raised %s\n", sizes[i], e);
		}
		a = nil;
	}
	sys->print("BYTES %d of %d refused\n", nref, len sizes);

	# operands whose copies fit what is left of the pool, and whose
	# result or working numbers do not
	x := IPint.bytestoip(array[5*MB] of {* => byte 16r33});
	y := IPint.random(100000);
	d := IPint.random(8192).ori(IPint.inttoip(1).shl(8191));
	m := d.ori(IPint.inttoip(1));
	e := IPint.random(64).ori(IPint.inttoip(1).shl(63));
	ops := array[] of {"mul", "div", "mod", "expmod"};
	for(i = 0; i < len ops; i++){
		main0 := used("main");
		raised := 0;
		for(round := 0; round < 3; round++){
			fillmain();
			for(k := 0; k < 3; k++)
				case ops[i] {
				"mul" =>	raised += try("mul", x, y, nil);
				"div" =>	raised += try("div", x, d, nil);
				"mod" =>	raised += try("mod", x, d, nil);
				"expmod" =>	raised += try("expmod", x, e, m);
				}
			fill = nil;
			small = nil;
		}
		sys->print("LOST %s %d raised %d\n", ops[i], used("main") - main0, raised);
	}

	# and with room again they are made
	p := x.mul(d);
	(q, r) := p.div(d);
	sys->print("ROOM %d %d %d\n", q.eq(x), r.eq(IPint.inttoip(0)), x.expmod(e, m).eq(x.mod(m).expmod(e, m)));
	sys->print("DONE\n");
}
