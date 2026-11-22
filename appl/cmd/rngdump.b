implement Rngdump;

#
# rngdump - the hardware generator's own bytes, to a file, for SP
# 800-90B's assessment (docs/ENTROPY-ASSESSMENT.md).
#
#	rngdump [-a] [-n bytes] file	bytes of #c/hwrandom (default 1000000)
#	rngdump -b [-a] file		this boot's first bytes, #c/hwrandomboot
#
# The kernel gives these files only on a boot whose command line says
# rngassess, and only to eve. -a appends (a restart collection keeps
# every boot's first bytes in one file, one boot after another).
#
# It writes exactly the bytes asked for, then says on standard output,
# one key=value line, what a reader can check without the file:
#
#	bytes ms rate	how many, how long, bytes a second
#	sha256		of what was written
#	mcv		the most common byte's count: -log2(mcv/bytes) is
#			90B 6.3.1's estimate before its confidence bound
#	chisq		chi-square of the byte counts, 255 degrees of freedom
#	bit0..bit7	ones in each bit position, per million
#	lag1		bytes equal to the one before, per million
#
# None of these says the source is good. They say quickly when it is
# plainly not; the estimate is NIST's tools' on the host.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "keyring.m";
	kr: Keyring;
include "arg.m";

Rngdump: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Bufsize: con 64*1024;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	arg := load Arg Arg->PATH;
	if(kr == nil || arg == nil)
		fatal(sys->sprint("cannot load modules: %r"));

	arg->init(args);
	arg->setusage("rngdump [-a] [-b] [-n bytes] file");
	boot := 0;
	app := 0;
	want := big 1000000;
	while((c := arg->opt()) != 0)
		case c {
		'a' =>	app = 1;
		'b' =>	boot = 1;
		'n' =>
			want = big arg->earg();
			if(want <= big 0)
				arg->usage();
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args != 1)
		arg->usage();
	out := hd args;

	src := "/dev/hwrandom";
	if(boot){
		src = "/dev/hwrandomboot";
		want = big 1 << 30;	# all it has
	}
	in := sys->open(src, Sys->OREAD);
	if(in == nil)
		fatal(sys->sprint("%s: %r", src));

	fd: ref Sys->FD;
	if(app){
		fd = sys->open(out, Sys->OWRITE);
		if(fd == nil)
			fd = sys->create(out, Sys->OWRITE, 8r600);
		else
			sys->seek(fd, big 0, Sys->SEEKEND);
	}else
		fd = sys->create(out, Sys->OWRITE, 8r600);
	if(fd == nil)
		fatal(sys->sprint("%s: %r", out));

	counts := array[256] of {* => big 0};
	bits := array[8] of {* => big 0};
	lag := big 0;
	prev := -1;
	ds: ref Keyring->DigestState;
	buf := array[Bufsize] of byte;
	got := big 0;
	t0 := sys->millisec();
	while(got < want){
		m := Bufsize;
		if(big m > want - got)
			m = int (want - got);
		n := sys->read(in, buf, m);
		if(n < 0)
			fatal(sys->sprint("%s: %r", src));
		if(n == 0)
			break;
		if(sys->write(fd, buf, n) != n)
			fatal(sys->sprint("%s: %r", out));
		ds = kr->sha256(buf, n, nil, ds);
		for(i := 0; i < n; i++){
			b := int buf[i];
			counts[b]++;
			for(j := 0; j < 8; j++)
				if(b & (1<<j))
					bits[j]++;
			if(b == prev)
				lag++;
			prev = b;
		}
		got += big n;
	}
	ms := sys->millisec() - t0;
	if(got == big 0)
		fatal(src+": no bytes");

	h := array[Keyring->SHA256dlen] of byte;
	kr->sha256(nil, 0, h, ds);

	mcv := big 0;
	chisq := 0.0;
	e := real got / 256.0;
	for(i := 0; i < 256; i++){
		if(counts[i] > mcv)
			mcv = counts[i];
		d := real counts[i] - e;
		chisq += d*d/e;
	}
	rate := big 0;
	if(ms > 0)
		rate = got * big 1000 / big ms;
	s := sys->sprint("src=%s bytes=%bd ms=%d rate=%bd sha256=%s mcv=%bd chisq=%.1f",
		src, got, ms, rate, hex(h), mcv, chisq);
	for(j := 0; j < 8; j++)
		s += sys->sprint(" bit%d=%bd", j, bits[j] * big 1000000 / got);
	s += sys->sprint(" lag1=%bd", lag * big 1000000 / got);
	sys->print("%s\n", s);
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "rngdump: %s\n", s);
	raise "fail:error";
}
