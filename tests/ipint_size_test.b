implement IPintSizeTest;

#
# How long an IPint may be and how much work one call may be
# (libinterp/ipint.c, libmp).
#
# - Nothing held a number's length but the shifts: bytes, text, a sum or
#   a product made one of any size. libmp counts a number's bits in an
#   int: 256MB of bytes was 2^31 bits, no room was made for them and they
#   were stored all the same, and the longest number plus one, or times
#   three, was written past a block of a hundred bytes through the
#   kernel's pool. A number is at most 2^26 bits (8MB) however it is made.
# - Nothing held the time, and a computation in libmp cannot be
#   interrupted: expmod with a modulus and exponent of 256K bits ran for
#   an hour with a processor of the host's whether or not its Prog had
#   been killed; a product of two numbers of 4MB took a minute, a
#   division of megabytes by megabytes longer. Each is held to an amount
#   of work that ends in seconds, and what is more is refused.
# - Base 32 wrote its padding after the number's bytes (1, 256 and 65536
#   were one text, which read back as 2^32), and read base 64's digits as
#   its own. (Its lengths that are no number are tests/ipint_nomem.b's:
#   they ended the emulator.)
# - "-0" was a zero with a sign: it equalled no zero and printed "-0".
# - A negative modulus gave a remainder below zero (-7 mod -5 was -7).
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

IPintSizeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ipint_size_test.b";

Toolarge: con "IPint: number too large";
Maxbits: con 1<<26;

passed := 0;
failed := 0;
skipped := 0;

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

# 2^n
pow2(n: int): ref IPint
{
	return ip(1).shl(n);
}

# a number of exactly n bits, odd
odd(n: int): ref IPint
{
	return IPint.random(n).ori(pow2(n-1)).ori(ip(1));
}

# what an operation raises, or nil
op(which: string, a, b, c: ref IPint): string
{
	{
		case which {
		"add" =>	a.add(b);
		"sub" =>	a.sub(b);
		"mul" =>	a.mul(b);
		"div" =>	a.div(b);
		"mod" =>	a.mod(b);
		"invert" =>	a.invert(b);
		"expmod" =>	a.expmod(b, c);
		"dec" =>	a.iptostr(10);
		"prime" =>	ipints->probably_prime(a, 1);
		}
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

refused(t: ref T, what, which: string, a, b, c: ref IPint)
{
	e := op(which, a, b, c);
	t.assert(e != nil && e == Toolarge, what + ": " + e);
}

allowed(t: ref T, what, which: string, a, b, c: ref IPint)
{
	t0 := sys->millisec();
	e := op(which, a, b, c);
	t.assert(e == nil, what + ": " + e);
	t.log(sys->sprint("%s: %d ms", what, sys->millisec()-t0));
}

frombytes(n: int, be: int): string
{
	a := array[n] of {* => byte 16r41};
	{
		if(be)
			IPint.bebytestoip(a);
		else
			IPint.bytestoip(a);
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

fromtext(n: int, c: int, base: int): string
{
	a := array[n] of {* => byte c};
	s := string a;
	a = nil;
	{
		if(base == 64)
			IPint.b64toip(s);
		else
			IPint.strtoip(s, base);
	} exception e {
	"*" =>
		return e;
	}
	return nil;
}

testLength(t: ref T)
{
	# bytes
	e := frombytes((Maxbits>>3)+1, 0);
	t.assert(e != nil && e == Toolarge, "bytestoip of 8MB and a byte: " + e);
	e = frombytes((Maxbits>>3)+1, 1);
	t.assert(e != nil && e == Toolarge, "bebytestoip of 8MB and a byte: " + e);
	e = frombytes(Maxbits>>3, 0);
	t.assert(e == nil, "bytestoip of 8MB: " + e);

	# text: four, five and six bits a digit
	e = fromtext((Maxbits>>2)+100, 'A', 16);
	t.assert(e != nil && e == Toolarge, "strtoip of 2^24+100 hexadecimal digits: " + e);
	e = fromtext((Maxbits/5)+100, 'a', 32);
	t.assert(e != nil && e == Toolarge, "strtoip of 2^26/5+100 digits of base 32: " + e);
	e = fromtext((Maxbits/6)+100, 'A', 64);
	t.assert(e != nil && e == Toolarge, "b64toip of 2^26/6+100 digits: " + e);
	e = fromtext(Maxbits>>2, 'A', 16);
	t.assert(e == nil, "strtoip of 2^24 hexadecimal digits: " + e);

	# the longest number, and a bit more
	x := IPint.bytestoip(array[Maxbits>>3] of {* => byte 16rff});
	t.asserteq(x.bits(), Maxbits, "8MB of ones has 2^26 bits");
	refused(t, "the longest number plus 1", "add", x, ip(1), nil);
	refused(t, "the longest number minus -1", "sub", x, ip(-1), nil);
	refused(t, "the longest number times 3", "mul", x, ip(3), nil);
	refused(t, "3 times the longest number", "mul", ip(3), x, nil);
	y := pow2(Maxbits-100);
	allowed(t, "2^(2^26-100) times 2^90", "mul", y, pow2(90), nil);
	refused(t, "2^(2^26-100) times 2^101", "mul", y, pow2(101), nil);
	allowed(t, "2^(2^26-100) plus itself", "add", y, y, nil);
	t.assert(y.add(y).eq(pow2(Maxbits-99)), "and the sum is 2^(2^26-99)");
}

testWork(t: ref T)
{
	# expmod: the modulus
	refused(t, "expmod with a modulus of 32769 bits", "expmod", ip(3), ip(5), pow2(32768).add(ip(1)));
	allowed(t, "expmod with a modulus of 32768 bits, exponent 65537", "expmod", ip(3), ip(65537), odd(32768));
	# (modulus bits)^2 x (exponent bits)
	m := odd(16384);
	refused(t, "expmod with 16384 bits of modulus and 16385 of exponent", "expmod", ip(3), pow2(16384), m);
	refused(t, "expmod with 32768 bits of modulus and 4097 of exponent", "expmod", ip(3), pow2(4096), odd(32768));
	# the general path (an even modulus): a sixteenth.  A negative base
	# no longer takes it (libmp reduces the base and keeps the fast path)
	ev := pow2(8191).add(ip(2));
	refused(t, "expmod with an even modulus of 8192 bits and 4097 of exponent", "expmod", ip(3), pow2(4096), ev);
	allowed(t, "expmod of a negative base, 8192 bits of modulus and 4097 of exponent", "expmod", ip(-3), pow2(4096), odd(8192));
	allowed(t, "expmod with an even modulus of 8192 bits and 1024 of exponent", "expmod", ip(3), odd(1024), ev);
	# what the tree does: Diffie-Hellman at 8192 bits
	p := odd(8192);
	allowed(t, "expmod with 8192 bits of modulus and of exponent", "expmod", odd(8000), odd(8192), p);
	# a base far longer than the modulus is divided first
	refused(t, "expmod of a base of 2^25 bits by a modulus of 32768", "expmod", pow2(1<<25), ip(3), odd(32768));

	# with no modulus: the result, counted as the base's bits for each
	# of the exponent
	refused(t, "3^(2^21+1)", "expmod", ip(3), ip((1<<21)+1), nil);
	allowed(t, "3^(2^21)", "expmod", ip(3), ip(1<<21), nil);

	# mul: digits by digits
	a := pow2(1<<25);
	refused(t, "2^(2^25) times a number of 2^25-100 bits", "mul", a, pow2((1<<25)-100), nil);
	refused(t, "a number of 2^22 bits squared", "mul", pow2(1<<22), pow2(1<<22), nil);
	allowed(t, "a number of 2^21 bits squared", "mul", odd(1<<21), odd(1<<21), nil);

	# div and mod: quotient digits by divisor digits
	refused(t, "2^(2^25) divided by a number of 2^20 bits", "div", a, pow2(1<<20), nil);
	refused(t, "2^(2^25) mod a number of 2^20 bits", "mod", a, pow2(1<<20), nil);
	refused(t, "2^(2^26-100) divided by a number of 16385 bits", "div", pow2(Maxbits-100), pow2(16384), nil);
	allowed(t, "2^(2^25) divided by a number of 4096 bits", "div", a, odd(4096), nil);
	allowed(t, "a megabit mod half a megabit", "mod", odd(1<<20), odd(1<<19), nil);
	allowed(t, "a short number mod one of 2^26-100 bits", "mod", ip(12345), pow2(Maxbits-101), nil);

	# invert
	refused(t, "invert mod a number of 65537 bits", "invert", ip(3), pow2(65536).add(ip(1)), nil);
	refused(t, "invert of a number of 65537 bits", "invert", pow2(65536).add(ip(1)), ip(7), nil);
	allowed(t, "invert of 2^65000 mod an odd number of 65536 bits", "invert", pow2(65000), odd(65536), nil);

	# probably_prime: no longer than the generators' primes
	refused(t, "probably_prime of 65537 bits", "prime", pow2(65536), nil, nil);
	allowed(t, "probably_prime of an even number of 65536 bits", "prime", pow2(65535), nil, nil);
}

testDecimal(t: ref T)
{
	refused(t, "2^(2^20+40) in base 10", "dec", pow2((1<<20)+40), nil, nil);
	e := fromtext((1<<20)/3 + 100, '7', 10);
	t.assert(e != nil && e == Toolarge, "strtoip of 2^20/3+100 decimal digits: " + e);

	# the longest that may be: written and read back, in time
	x := odd(1<<20);
	t0 := sys->millisec();
	s := x.iptostr(10);
	t1 := sys->millisec();
	y := IPint.strtoip(s, 10);
	t2 := sys->millisec();
	t.assert(y != nil && y.eq(x), "a number of 2^20 bits written and read in base 10");
	t.log(sys->sprint("2^20 bits in base 10: %d digits, written in %d ms, read in %d ms", len s, t1-t0, t2-t1));
	t.assert(t1-t0 < 60000 && t2-t1 < 60000, sys->sprint("base 10 took %d and %d ms", t1-t0, t2-t1));

	# against the text another way gives: 10^k by multiplication
	ten := ip(10);
	z := ip(1);
	want := "1";
	for(i := 0; i < 3000; i++){
		z = z.mul(ten);
		want += "0";
	}
	t.assertseq(z.iptostr(10), want, "10^3000 in base 10");
	t.assert(IPint.strtoip(want, 10).eq(z), "10^3000 read in base 10");
	nines := z.sub(ip(1)).iptostr(10);
	t.asserteq(len nines, 3000, "10^3000-1 has 3000 digits");
	for(i = 0; i < len nines; i++)
		if(nines[i] != '9')
			break;
	t.asserteq(i, len nines, "all of them 9");
	t.assertseq(z.neg().iptostr(10), "-" + want, "-10^3000 in base 10");
	t.assert(IPint.strtoip("-" + want, 10).eq(z.neg()), "-10^3000 read in base 10");
	t.assertseq(ip(1000000000).iptostr(10), "1000000000", "10^9 in base 10");
	t.assertseq(ip(999999999).iptostr(10), "999999999", "10^9-1 in base 10");
	t.assertseq(IPint.strtoip("000000000000000000000012", 10).iptostr(10), "12", "leading zeros");
}

testBase32(t: ref T)
{
	one := ip(1).iptostr(32);
	t.assertseq(one, "22222223", "1 in base 32");
	t.assertsne(ip(256).iptostr(32), one, "256 in base 32 is not 1's text");
	t.assertsne(ip(65536).iptostr(32), one, "65536 in base 32 is not 1's text");
	for(n := 0; n < 300; n++){
		x := ip(1).shl(n).sub(ip(n));
		s := x.iptostr(32);
		y := IPint.strtoip(s, 32);
		if(y == nil || !y.eq(x)){
			t.error(sys->sprint("2^%d-%d in base 32 (%s) does not read back", n, n, s));
			break;
		}
	}
	# base 64's digits are not base 32's (they were read as zeros)
	t.assert(IPint.strtoip("AAAAAAAA", 32) == nil, "AAAAAAAA is not a number in base 32");
	t.assert(IPint.strtoip("0l1o+/AB", 32) == nil, "0l1o+/AB is not a number in base 32");
	t.assert(IPint.strtoip("2222222Z", 32) == nil, "2222222Z is not a number in base 32");
}

testNegativeZero(t: ref T)
{
	zero := ip(0);
	z := IPint.strtoip("-0", 10);
	t.assert(z != nil && z.eq(zero) && z.cmp(zero) == 0, "-0 in base 10 is zero");
	t.assertseq(z.iptostr(10), "0", "and prints as 0");
	z = IPint.strtoip("-0000", 16);
	t.assert(z != nil && z.eq(zero), "-0000 in base 16 is zero");
	z = IPint.b64toip("-AAAA");
	t.assert(z != nil && z.eq(zero), "-AAAA in base 64 is zero");
	t.assertseq(z.iptostr(10), "0", "and prints as 0");
	t.assert(IPint.strtoip("-5", 10).eq(ip(-5)), "-5 is still -5");
}

testNegativeModulus(t: ref T)
{
	t.assertseq(ip(-7).mod(ip(-5)).iptostr(10), "3", "-7 mod -5");
	t.assertseq(ip(-1).mod(ip(-3)).iptostr(10), "2", "-1 mod -3");
	t.assertseq(ip(5).mod(ip(-3)).iptostr(10), "2", "5 mod -3");
	t.assertseq(ip(-7).mod(ip(5)).iptostr(10), "3", "-7 mod 5");
	t.assertseq(ip(-10).mod(ip(-5)).iptostr(10), "0", "-10 mod -5");
	# and through the released path
	a := pow2(40000).add(ip(7)).neg();
	m := pow2(20000).neg();
	t.assertseq(a.mod(m).sub(pow2(20000)).iptostr(10), "-7", "-(2^40000+7) mod -2^20000");
}

# the operands of a long operation are the caller's still after it
testOperandsKept(t: ref T)
{
	x := odd(40000);
	y := odd(30000);
	x0 := x.copy();
	y0 := y.copy();
	p := x.mul(y);
	(q, r) := p.div(y);
	t.assert(q.eq(x) && r.eq(ip(0)), "(x*y)/y is x");
	t.assert(p.mod(x).eq(ip(0)), "(x*y) mod x is 0");
	sq := x.mul(x);
	(q, r) = sq.div(x);
	t.assert(q.eq(x) && r.eq(ip(0)), "(x*x)/x is x");
	m := odd(2048);
	e := odd(2048);
	a := x.expmod(e, m);
	b := x.mod(m).expmod(e, m);
	t.assert(a.eq(b), "x^e mod m is (x mod m)^e mod m");
	inv := y.invert(m);
	if(inv != nil)
		t.assert(inv.mul(y).mod(m).eq(ip(1)), "y times its inverse is 1 mod m");
	s := x.iptostr(10);
	t.assert(IPint.strtoip(s, 10).eq(x), "x written and read in base 10");
	t.assert(x.eq(x0) && y.eq(y0), "x and y are what they were");
	t.asserteq(x.bits(), 40000, "x has its bits");
}

status(pid: int): string
{
	fd := sys->open(sys->sprint("/prog/%d/status", pid), Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

longexp(pidc: chan of int, b, e, m: ref IPint, done: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	b.expmod(e, m);
	done <-= 1;
}

# the longest expmod there may be ends, and a Prog killed in it is gone
# when it does (it was an hour, for a modulus and exponent a program chose)
testKilled(t: ref T)
{
	m := odd(16384);
	e := odd(16384);
	b := odd(16000);

	t0 := sys->millisec();
	b.expmod(e, m);
	ms := sys->millisec() - t0;
	t.log(sys->sprint("expmod with 16384 bits of modulus and of exponent: %d ms", ms));
	t.assert(ms < 120000, sys->sprint("the longest expmod took %d ms", ms));

	pidc := chan of int;
	done := chan[1] of int;
	spawn longexp(pidc, b, e, m, done);
	pid := <-pidc;
	sys->sleep(100);
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	t.assert(fd != nil, "the Prog's ctl opens");
	if(fd != nil)
		sys->fprint(fd, "kill");
	t0 = sys->millisec();
	while(status(pid) != nil && sys->millisec()-t0 < 120000)
		sys->sleep(50);
	gone := sys->millisec() - t0;
	t.assert(status(pid) == nil, "a Prog killed in the longest expmod is gone: " + status(pid));
	t.log(sys->sprint("gone %d ms after its kill", gone));
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

	run("Length", testLength);
	run("Work", testWork);
	run("Decimal", testDecimal);
	run("Base32", testBase32);
	run("NegativeZero", testNegativeZero);
	run("NegativeModulus", testNegativeModulus);
	run("OperandsKept", testOperandsKept);
	run("Killed", testKilled);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
