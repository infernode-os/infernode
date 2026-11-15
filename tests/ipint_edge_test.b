implement IPintEdgeTest;

#
# IPint's builtins (libinterp/ipint.c) and the libmp and libsec under
# them, given what a program may pass.
#
# - A zero made from bytes (bytestoip, bebytestoip of bytes all zero) was
#   one digit of zero, which libmp does not know as zero: it equalled no
#   zero, and mpdiv, looking for the top bit of a divisor it took to be a
#   number, shifted that digit left for ever, holding the VM: div, mod,
#   expmod and invert by it stopped every Limbo thread for good.
# - A remainder of nothing after a negative dividend was a zero less than
#   zero, and mpmod added the modulus to it: -6 mod 3 was 3. neg, and
#   and shr made the same zero, which printed "-0".
# - A number's text and bytes were formatted into 1024 bytes on the
#   stack whatever its length: hexadecimal of 4096 bits or more ran on
#   into the stack beyond the buffer, base 32 was what the stack held,
#   decimal the low digits alone, base 64 another number, and the bytes
#   of a number past 1024 an empty array.
# - genprime with a count of none or fewer bits wrote a word before its
#   number (minus a thousand ended the emulator), near the largest int a
#   quarter of a gigabyte away; with one bit it never returned, and nor
#   did probably_prime of 3.
# - expmod with no modulus was computed with the VM held however long
#   the result: two to the 2**30 stopped every Limbo thread for minutes.
# - A string that was no number cost 256 bytes of the kernel's pool, and
#   an operation libmp raised for (a division by zero) the result it had
#   been given.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "ipints.m";
	ipints: IPints;
	IPint: import ipints;
include "testing.m";
	testing: Testing;
	T: import testing;

IPintEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ipint_edge_test.b";

passed := 0;
failed := 0;
skipped := 0;

# the tests named on the command line, or all of them
only: list of string;

run(name: string, testfn: ref fn(t: ref T))
{
	if(only != nil){
		for(l := only; l != nil; l = tl l)
			if(hd l == name)
				break;
		if(l == nil)
			return;
	}
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

ip(i: int): ref IPint
{
	return IPint.inttoip(i);
}

mainpool(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	if(fd == nil)
		return -1;
	b := array[2048] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return -1;
	(nil, l) := sys->tokenize(string b[0:n], "\n");
	for(; l != nil; l = tl l){
		(nf, f) := sys->tokenize(hd l, " ");
		if(nf < 2)
			continue;
		name := "";
		for(g := f; g != nil; g = tl g)
			name = hd g;
		if(name == "main")
			return int hd f;
	}
	return -1;
}

# what an operation on a and b raises, or nil
op(which: string, a, b: ref IPint): string
{
	{
		case which {
		"div" =>	a.div(b);
		"mod" =>	a.mod(b);
		"invert" =>	a.invert(b);
		"expmod" =>	a.expmod(ip(3), b);
		"exp" =>	a.expmod(b, nil);
		}
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

testZeroFromBytes(t: ref T)
{
	zero := ip(0);
	zs := array[] of {
		IPint.bytestoip(array[1] of {* => byte 0}),
		IPint.bytestoip(array[4] of {* => byte 0}),
		IPint.bytestoip(array[9] of {* => byte 0}),
		IPint.bebytestoip(array[1] of {* => byte 0}),
		IPint.bebytestoip(array[40] of {* => byte 0}),
		IPint.bytestoip(array[0] of byte),
	};
	for(i := 0; i < len zs; i++){
		z := zs[i];
		# fatal: the code before never comes back from the divisions below
		if(!z.eq(zero) || z.cmp(zero) != 0)
			t.fatal(sys->sprint("zero number %d made from bytes does not equal zero (cmp %d)", i, z.cmp(zero)));
		t.assertseq(z.iptostr(10), "0", "it prints 0");
		t.assert(ip(7).add(z).eq(ip(7)), "7 plus it is 7");
		t.assert(ip(7).mul(z).eq(zero), "7 times it is 0");

		e := op("div", ip(5), z);
		t.assert(e != nil && e == "mpdiv: divide by zero", "5 div it: " + e);
		e = op("mod", ip(5), z);
		t.assert(e != nil && e == "mpdiv: divide by zero", "5 mod it: " + e);
		e = op("expmod", ip(5), z);
		t.assert(e != nil && e == "mpdiv: divide by zero", "5**3 mod it: " + e);
		e = op("invert", ip(5), z);
		t.assert(e != nil, "5's inverse mod it is refused: " + e);
		t.assert(ip(5).expmod(z, ip(7)).eq(ip(1)), "5 to the power of it, mod 7, is 1");
		t.assert(ip(5).expmod(z, nil).eq(ip(1)), "5 to the power of it is 1");
		t.asserteq(ipints->probably_prime(z, 5), 0, "it is not prime");
	}

	# bytes with zeros before a number are the number
	t.assert(IPint.bytestoip(array[] of {byte 0, byte 0, byte 0, byte 0, byte 0, byte 1, byte 2}).eq(ip(258)),
		"00 00 00 00 00 01 02 is 258");
	(q, r) := ip(1000).div(IPint.bebytestoip(array[] of {byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 7}));
	t.assert(q.eq(ip(142)) && r.eq(ip(6)), "1000 div a 7 with eight zero bytes before it");
}

testNegativeZero(t: ref T)
{
	zero := ip(0);
	z := ip(0).neg();
	t.assert(z.eq(zero) && z.cmp(zero) == 0, "the negative of zero is zero");
	t.assertseq(z.iptostr(10), "0", "and prints 0");
	z = ip(-5).and(ip(0));
	t.assert(z.eq(zero), "-5 and 0 is zero");
	t.assertseq(z.iptostr(10), "0", "and prints 0");
	z = ip(-5).shr(100);
	t.assert(z.eq(zero), "-5 shifted right 100 is zero");
	t.assertseq(z.iptostr(10), "0", "and prints 0");

	# a remainder of nothing
	(q, r) := ip(-6).div(ip(3));
	t.assert(q.eq(ip(-2)), "-6 div 3 is -2: " + q.iptostr(10));
	t.assert(r.eq(zero), "with nothing over: " + r.iptostr(10));
	t.assertseq(ip(-6).mod(ip(3)).iptostr(10), "0", "-6 mod 3");
	t.assertseq(ip(-7).mod(ip(3)).iptostr(10), "2", "-7 mod 3");
	t.assertseq(ip(-6).expmod(ip(1), ip(3)).iptostr(10), "0", "-6**1 mod 3");
	t.assertseq(ip(-2).expmod(ip(3), ip(8)).iptostr(10), "0", "-2**3 mod 8");
	t.assertseq(ip(-3).expmod(ip(3), ip(8)).iptostr(10), "5", "-3**3 mod 8");
	t.assertseq(ip(-1).shl(200).mod(ip(1).shl(100)).iptostr(10), "0", "-2**200 mod 2**100");
}

onlychars(s: string, set: string): int
{
	for(i := 0; i < len s; i++){
		ok := 0;
		for(j := 0; j < len set; j++)
			if(s[i] == set[j])
				ok = 1;
		if(!ok)
			return 0;
	}
	return 1;
}

testLongText(t: ref T)
{
	hexset := "0123456789ABCDEF";
	bits := array[] of {4087, 4091, 4095, 4099, 20000};
	for(i := 0; i < len bits; i++){
		x := ip(1).shl(bits[i]);
		s := x.iptostr(16);
		t.asserteq(len s, bits[i]/4 + 1, sys->sprint("hexadecimal of 2**%d has that many digits", bits[i]));
		t.assert(onlychars(s, hexset), sys->sprint("and nothing but digits (2**%d)", bits[i]));
		y := IPint.strtoip(s, 16);
		t.assert(y != nil && y.eq(x), sys->sprint("and reads back (2**%d)", bits[i]));
		s = x.neg().iptostr(16);
		t.assert(len s == bits[i]/4 + 2 && s[0] == '-', sys->sprint("with a sign (-2**%d)", bits[i]));
	}

	# 2**9000 has 2710 decimal digits
	x := ip(1).shl(9000);
	s := x.iptostr(10);
	t.asserteq(len s, 2710, "decimal of 2**9000");
	t.assert(len s > 4 && s[0:4] == "1861", "its first digits");
	y := IPint.strtoip(s, 10);
	t.assert(y != nil && y.eq(x), "and it reads back");

	bases := array[] of {32, 64};
	for(i = 0; i < len bases; i++){
		for(nb := 5000; nb <= 90000; nb += 17000){
			x = ip(1).shl(nb).sub(ip(12345));
			s = x.iptostr(bases[i]);
			y = IPint.strtoip(s, bases[i]);
			t.assert(y != nil && y.eq(x), sys->sprint("base %d of a number of %d bits reads back", bases[i], nb));
		}
	}

	# long enough for the text to be made with the VM let go
	x = ip(1).shl(40000).sub(ip(1));
	s = x.iptostr(10);
	y = IPint.strtoip(s, 10);
	t.assert(y != nil && y.eq(x), "decimal of 2**40000-1 reads back");
	t.asserteq(len x.iptostr(16), 10000, "its hexadecimal");

	# the short ones as they were
	t.assertseq(ip(255).iptostr(16), "FF", "255 in hexadecimal");
	t.assertseq(ip(-255).iptostr(10), "-255", "-255 in decimal");
	t.assertseq(ip(0).iptostr(10), "0", "0 in decimal");
	t.assertseq(ip(0).iptostr(16), "0", "0 in hexadecimal");
	t.assertseq(ip(1).iptob64(), "AQ==", "1 in base 64");
	t.assertseq(ip(255).iptob64z(), "AP8=", "255 in base 64 with its zero byte");
	t.assertseq(ip(0).iptob64z(), "AA==", "0 in base 64");
}

testLongBytes(t: ref T)
{
	sizes := array[] of {1, 2, 763, 764, 767, 768, 769, 1023, 1024, 1025, 1026, 5000};
	for(i := 0; i < len sizes; i++){
		n := sizes[i];
		a := array[n] of byte;
		for(j := 0; j < n; j++)
			a[j] = byte (j*7 + 1);
		a[0] = byte 16r81;	# a top bit, so that iptob64z writes its zero byte
		x := IPint.bebytestoip(a);
		b := x.iptobebytes();
		ok := len b == n;
		for(j = 0; ok && j < n; j++)
			if(a[j] != b[j])
				ok = 0;
		t.assert(ok, sys->sprint("a number of %d bytes gives its bytes back (%d)", n, len b));
		b = x.iptobytes();
		t.asserteq(len b, n, sys->sprint("iptobytes of %d bytes", n));

		s := x.iptob64z();
		t.asserteq(len s, (n+1+2)/3*4, sys->sprint("iptob64z of %d bytes", n));
		y := IPint.b64toip(s);
		t.assert(y != nil && y.eq(x), sys->sprint("which reads back (%d bytes)", n));
		s = x.iptob64();
		y = IPint.b64toip(s);
		t.assert(y != nil && y.eq(x), sys->sprint("iptob64 of %d bytes reads back", n));
		s = x.iptostr(64);
		y = IPint.strtoip(s, 64);
		t.assert(y != nil && y.eq(x), sys->sprint("iptostr 64 of %d bytes reads back", n));
	}
	t.asserteq(len ip(0).iptobytes(), 1, "zero is one byte");
	t.asserteq(int ip(0).iptobebytes()[0], 0, "of zero");
}

# a call that must come back: run aside, with a time limit
BITSTIME: con 5000;

bitscall(which: string, n: int, c: chan of string)
{
	r: string;
	{
		case which {
		"genprime" =>
			p := ipints->genprime(n, 0);
			r = sys->sprint("%s", p.iptostr(10));
		"genstrongprime" =>
			p := ipints->genstrongprime(n, 0);
			r = sys->sprint("%d bits", p.bits());
		"gensafeprime" =>
			(p, a) := ipints->gensafeprime(n, 0);
			r = sys->sprint("%s %s", p.iptostr(10), a.iptostr(10));
		"random" =>
			p := IPint.random(n);
			r = sys->sprint("%d", p.bits() <= n || n == 0);
		"probably_prime" =>
			r = sys->sprint("%d", ipints->probably_prime(ip(n), 0));
		}
	} exception e {
	"*" =>
		r = "raised " + e;
	}
	c <-= r;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

bitsof(which: string, n: int): string
{
	c := chan[1] of string;
	tc := chan[1] of int;
	spawn bitscall(which, n, c);
	spawn timer(tc, BITSTIME);
	alt{
	r := <-c =>
		return r;
	<-tc =>
		return "never returned";
	}
}

refused(t: ref T, which: string, n: int)
{
	r := bitsof(which, n);
	t.assert(r == "raised IPint: bad bit count", sys->sprint("%s(%d) is refused: %s", which, n, r));
}

testBitCounts(t: ref T)
{
	# the counts that wrote before the number are the harmless ones here:
	# none, and a few fewer (minus a thousand ends the emulator in the code before)
	bad := array[] of {0, -1, -31, -32, -64, -100, 16r7fffffff, -16r7fffffff-1, 1<<30, 1<<17};
	for(i := 0; i < len bad; i++)
		refused(t, "genprime", bad[i]);
	refused(t, "genprime", 1);
	refused(t, "genprime", -1000);

	t.assertseq(bitsof("probably_prime", 3), "1", "3 is prime");
	t.assertseq(bitsof("probably_prime", 2), "1", "2 is prime");
	t.assertseq(bitsof("probably_prime", 1), "0", "1 is not");
	t.assertseq(bitsof("probably_prime", 0), "0", "0 is not");
	t.assertseq(bitsof("probably_prime", 9), "0", "9 is not");
	t.assertseq(bitsof("probably_prime", 5), "1", "5 is prime");
	t.assertseq(bitsof("probably_prime", 104729), "1", "104729 is prime");
	t.assertseq(bitsof("probably_prime", 104731), "0", "104731 is not");
	t.assertseq(bitsof("probably_prime", -7), "raised negative prime candidate", "-7 is refused");

	t.assertseq(bitsof("genprime", 2), "3", "the prime of two bits");
	r := bitsof("genprime", 3);
	t.assert(r == "5" || r == "7", "a prime of three bits: " + r);
	# from 9, 11, 13 or 15, the next prime
	r = bitsof("genprime", 4);
	t.assert(r == "11" || r == "13" || r == "17", "a prime from four bits: " + r);
	r = bitsof("genprime", 64);
	t.assert(len r >= 19 && len r <= 20, "a prime of 64 bits: " + r);

	refused(t, "gensafeprime", 2);
	refused(t, "gensafeprime", 1);
	refused(t, "gensafeprime", 0);
	refused(t, "gensafeprime", -100);
	refused(t, "gensafeprime", 16r7fffffff);
	r = bitsof("gensafeprime", 3);
	t.assert(r == "7 3" || r == "7 5", "the safe prime of three bits, and a generator: " + r);
	r = bitsof("gensafeprime", 4);
	t.assert(len r > 3 && r[0:3] == "11 " && r != "11 0", "the safe prime of four bits, and a generator: " + r);

	refused(t, "genstrongprime", 16r7fffffff);
	refused(t, "genstrongprime", 1<<17);
	# Gordon's algorithm is a bit or two either side of what is asked for
	r = bitsof("genstrongprime", 64);
	t.assert(int r >= 60 && int r <= 68, "a strong prime of 64 bits: " + r);
	r = bitsof("genstrongprime", 0);
	t.assert(int r >= 60 && int r <= 68, "of none is of 64: " + r);
	r = bitsof("genstrongprime", -5);
	t.assert(int r >= 60 && int r <= 68, "and so is of fewer: " + r);

	refused(t, "random", -1);
	refused(t, "random", -100);
	refused(t, "random", 16r7fffffff);
	refused(t, "random", (1<<26)+1);
	t.assertseq(bitsof("random", 0), "1", "random of no bits");
	t.assertseq(bitsof("random", 1), "1", "random of one bit");
	t.assertseq(bitsof("random", 257), "1", "random of 257 bits");
}

testLostNumbers(t: ref T)
{
	m0 := mainpool();
	if(m0 < 0)
		t.skip("no /dev/memory");

	# strings that are no number
	n := 0;
	for(i := 0; i < 10000; i++){
		if(IPint.b64toip("") == nil)
			n++;
		if(IPint.strtoip("zz", 10) == nil)
			n++;
		if(IPint.strtoip("12x", 10) == nil)
			n++;
	}
	t.asserteq(n, 30000, "strings that are no number give nil");
	grew := mainpool() - m0;
	t.log(sys->sprint("30000 failed parses: main pool %d bytes more", grew));
	t.assert(grew < 256*1024, sys->sprint("30000 strings that were no number kept %d bytes of the main pool", grew));

	# operations that are refused
	m0 = mainpool();
	n = 0;
	for(i = 0; i < 2000; i++){
		if(op("div", ip(5), ip(0)) != nil)
			n++;
		if(op("mod", ip(5), ip(0)) != nil)
			n++;
		if(op("invert", ip(4), ip(8)) != nil)
			n++;
		if(op("invert", ip(1), ip(0)) != nil)
			n++;
		if(op("expmod", ip(5), ip(0)) != nil)
			n++;
		if(op("exp", ip(5), ip(-1)) != nil)
			n++;
	}
	t.asserteq(n, 12000, "divisions by zero, inverses there are none of and negative exponents are refused");
	grew = mainpool() - m0;
	t.log(sys->sprint("12000 refused operations: main pool %d bytes more", grew));
	t.assert(grew < 256*1024, sys->sprint("12000 refused operations kept %d bytes of the main pool", grew));

	# and what they raise is what libmp raised
	t.assertseq(op("div", ip(5), ip(0)), "mpdiv: divide by zero", "div by zero");
	t.assertseq(op("mod", ip(5), ip(0)), "mpdiv: divide by zero", "mod zero");
	t.assertseq(op("expmod", ip(5), ip(0)), "mpdiv: divide by zero", "expmod zero");
	t.assertseq(op("invert", ip(4), ip(8)), "mpinvert: no inverse", "no inverse");
	t.assertseq(op("invert", ip(1), ip(0)), "mpdiv: divide by zero", "an inverse mod zero");
	t.assertseq(op("exp", ip(5), ip(-1)), "mpexp: negative exponent", "a negative exponent");
	t.assert(ip(3).invert(ip(7)).eq(ip(5)), "3's inverse mod 7 is 5");
	t.assert(ip(5).expmod(ip(0), ip(0)).eq(ip(1)), "5**0 mod 0 is 1, as it was");
}

ticks := 0;

ticker(stop: chan of int)
{
	for(;;){
		alt{
		<-stop =>
			return;
		* =>
			;
		}
		sys->sleep(10);
		ticks++;
	}
}

testPower(t: ref T)
{
	# small powers, as they were
	t.assert(ip(2).expmod(ip(10), nil).eq(ip(1024)), "2**10");
	t.assert(ip(-3).expmod(ip(3), nil).eq(ip(-27)), "-3**3");
	t.assert(ip(7).expmod(ip(0), nil).eq(ip(1)), "7**0");
	t.assert(ip(0).expmod(ip(5), nil).eq(ip(0)), "0**5");
	x := ip(3).expmod(ip(1000), nil);
	t.asserteq(x.bits(), 1585, "3**1000 has 1585 bits");

	# a result longer than a number may be is refused, at once.  (Last
	# in this file: the code before computes these with the VM held,
	# for minutes.)
	e := op("exp", ip(2), ip(1<<27));
	t.assert(e != nil && e == "IPint: number too large", "2**(2**27): " + e);
	e = op("exp", ip(2), ip(1<<30));
	t.assert(e != nil && e == "IPint: number too large", "2**(2**30): " + e);
	e = op("exp", ip(1).shl(1000), ip(1<<20));
	t.assert(e != nil && e == "IPint: number too large", "(2**1000)**(2**20): " + e);
	e = op("exp", ip(3), ip(1).shl(100));
	t.assert(e != nil && e == "IPint: number too large", "3**(2**100): " + e);

	# 1, -1 and 0 to any power are short
	t.assert(ip(1).expmod(ip(1).shl(100), nil).eq(ip(1)), "1**(2**100)");
	t.assert(ip(-1).expmod(ip(1).shl(100).add(ip(1)), nil).eq(ip(-1)), "-1**(2**100+1)");
	t.assert(ip(0).expmod(ip(1).shl(100), nil).eq(ip(0)), "0**(2**100)");

	# a long one is computed with the VM let go: a ticker runs beside it
	stop := chan[1] of int;
	ticks = 0;
	spawn ticker(stop);
	sys->sleep(50);
	t0 := sys->millisec();
	before := ticks;
	y := ip(3).expmod(ip(1<<21), nil);
	ms := sys->millisec() - t0;
	during := ticks - before;
	stop <-= 1;
	t.asserteq(y.bits(), 3323908, "3**(2**21) has 3323908 bits");
	t.log(sys->sprint("3**(2**21): %d ms, %d ticks of 10 ms meanwhile", ms, during));
	# Held, the VM gives the ticker no turn at all until the power is
	# done.  How many it gets with the VM let go is the host's business
	# (an Intel Mac runner gave a 10 ms sleep 55 ms: 19 turns in 1055 ms),
	# so the test asks for a few, not for a rate.
	if(ms >= 200)
		t.assert(during >= 3, sys->sprint("the ticker ran %d times in the %d ms it took", during, ms));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	ipints = load IPints IPints->PATH;
	if(ipints == nil){
		sys->fprint(sys->fildes(2), "cannot load IPints: %r\n");
		raise "fail:cannot load IPints";
	}
	testing->init();
	if(args != nil)
		args = tl args;
	for(a := args; a != nil; a = tl a){
		if(hd a == "-v")
			testing->verbose(1);
		else
			only = hd a :: only;
	}

	run("NegativeZero", testNegativeZero);
	run("LongText", testLongText);
	run("LongBytes", testLongBytes);
	run("LostNumbers", testLostNumbers);
	run("ZeroFromBytes", testZeroFromBytes);
	run("BitCounts", testBitCounts);
	run("Power", testPower);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
