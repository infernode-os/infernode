implement Am;

#
# sdr/am - AM demodulated: sdrfs(4)'s iq in, audio(3)'s sound out.
#
#	echo freq 121.5M > /mnt/sdr/ctl
#	sdr/am -o 44100 < /mnt/sdr/iq | auplay /fd/0
#
# The air band (118-137 MHz) is AM, as are short wave and the medium
# wave broadcasts (through direct sampling, or an upconverter).  The
# samples are summed to about 240k a second, the channel (-b hertz
# either side, 5000) is filtered out and they are decimated to about
# 48k; each one's magnitude
# over the carrier's (its magnitude averaged over a tenth of a second)
# is the sound: the level out does not follow the signal's strength.
#
# The rate in is the one iq's header gives (sdr/rawiq puts one on a
# recording without); input with no header, or in an encoding other
# than cu8, is refused.  -o is the rate out (8000, /dev/audio's
# default) and -c the channels out (2, as audio(3); the same sound in
# each).  -g multiplies the volume.  The sound begins with audio(6)'s
# header, so auplay(1) plays it; -R leaves it out.
#
# Usage:	sdr/am [-R] [-b hertz] [-c chans] [-g gain] [-o rate]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "math.m";
	math: Math;

include "sdrdsp.m";
	dsp: Sdrdsp;
	Decim, Fir, Resamp, Pcm, Hdr: import dsp;

Am: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Chunk: con 64*1024;
Ahead: con 4;		# chunks read ahead of the arithmetic (readahead)
readerpid := -1;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	dsp = load Sdrdsp Sdrdsp->PATH;
	arg := load Arg Arg->PATH;
	if(math == nil || dsp == nil || arg == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	dsp->init();

	chans := 2;
	bw := 5000.0;
	gain := 1.0;
	fout := 8000;
	raw := 0;
	arg->init(argv);
	arg->setusage("sdr/am [-R] [-b hertz] [-c chans] [-g gain] [-o rate]");
	while((o := arg->opt()) != 0)
		case o {
		'b' =>
			bw = real arg->earg();
			if(bw < 100.0)
				arg->usage();
		'c' =>
			chans = int arg->earg();
			if(chans < 1 || chans > 8)
				arg->usage();
		'g' =>
			gain = real arg->earg();
		'o' =>
			if((fout = dsp->rate(arg->earg())) == 0)
				arg->usage();
		'R' =>
			raw = 1;
		* =>
			arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	stdin := sys->fildes(0);
	stdout := sys->fildes(1);
	(h, first) := readhdr(stdin);
	fin := h.rate;

	# the samples summed to about 240k a second, then the channel
	# (-b hertz either side) filtered out and decimated to about 48k
	n1 := fin / 240000;
	if(n1 < 1)
		n1 = 1;
	n := n1;
	f1 := real fin / real n1;
	n2 := int (f1 / 48000.0);	# rounds
	if(n2 < 1)
		n2 = 1;
	if(f1 / real n2 < real fout)
		n2 = int (f1 / real fout - 0.5);
	fir: ref Fir;
	if(n2 > 1 || bw * 2.0 < f1) {
		if(n2 < 1)
			n2 = 1;
		fir = Fir.new(n2, bw / f1, 96);
		n *= n2;
	}
	if(fin / n < fout)
		fatal(sys->sprint("rate in %d too low for %d out", fin, fout));
	fmid := real fin / real n;

	# full modulation at 0.7 of full scale
	gain *= 0.7;
	# the carrier: its magnitude averaged over a tenth of a second
	a := 1.0 - math->exp(-1.0 / (fmid * 0.1));

	d := Decim.new(n1);
	r := Resamp.new(fin, fout * n);
	p := Pcm.new(fout, chans);

	if(!raw) {
		b := dsp->header(sys->sprint("rate %d\nchans %d\nbits 16\nenc pcm\n", fout, chans));
		if(sys->write(stdout, b, len b) != len b)
			fatal(sys->sprint("write: %r"));
	}
	buf := array[Chunk+1] of byte;	# a byte carried, and a chunk
	i := array[Chunk/2] of real;
	q := array[Chunk/2] of real;
	out := array[Chunk/2 * 2 * chans + 16] of byte;
	have := 0;
	carrier := 0.0;
	rc := chan[Ahead] of (array of byte, string);
	pidc := chan of int;
	spawn readahead(stdin, rc, pidc);
	readerpid = <-pidc;
	for(;;) {
		b := first;
		err: string;
		if(b != nil)
			first = nil;
		else
			(b, err) = <-rc;
		if(b == nil) {
			readerpid = -1;
			if(err != nil)
				fatal("read: " + err);
			break;
		}
		buf[have:] = b;
		k := have + len b;
		m := d.run(buf, k, i, q);
		if(k & 1) {
			buf[0] = buf[k-1];
			have = 1;
		} else
			have = 0;
		if(fir != nil)
			m = fir.run(i, q, m, i, q);

		for(j := 0; j < m; j++) {
			e := math->sqrt(i[j]*i[j] + q[j]*q[j]);
			if(carrier == 0.0)
				carrier = e;
			else
				carrier += a * (e - carrier);
			if(carrier > 1e-9)
				i[j] = e / carrier - 1.0;
			else
				i[j] = 0.0;
		}
		m = r.run(i, m, i);
		if(m == 0)
			continue;
		nb := p.run(i, m, gain, out);
		if(sys->write(stdout, out, nb) != nb)
			fatal(sys->sprint("write: %r"));
	}
}

#
# The reads, in a process of their own and a few chunks ahead, so the
# arithmetic never waits on one.  Over a network mount each read waits
# a round trip; sdr/fm read, then worked, then read again, and on a Pi 4
# reading another machine's /mnt/sdr at 2.4M it fell 12-22% behind
# sdrfs's stream, which dropped the rest (status's dropped=).  This
# loop was the same.  A chunk each send, nil at the end, with the
# error if there was one.
#
readahead(fd: ref Sys->FD, c: chan of (array of byte, string), pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) {
		b := array[Chunk] of byte;
		n := sys->read(fd, b, len b);
		if(n <= 0) {
			e: string;
			if(n < 0)
				e = sys->sprint("%r");
			c <-= (nil, e);
			return;
		}
		c <-= (b[0:n], nil);
	}
}

# iq's header, refused if there is none or its samples are not cu8;
# with it, what was read after it
readhdr(fd: ref Sys->FD): (ref Hdr, array of byte)
{
	b := array[Sdrdsp->Maxhdr] of byte;
	n := 0;
	for(;;) {
		(h, k, e) := Hdr.read(b, n);
		if(k < 0)
			fatal(e + ": not sdrfs(4)'s iq (sdr/rawiq puts a header on samples)");
		if(k > 0) {
			if(h.enc == nil)
				fatal("no enc in the header: cu8 is all it takes");
			if(h.enc != "cu8")
				fatal("enc " + h.enc + ": cu8 is all it takes");
			if(n == k)
				return (h, nil);
			return (h, b[k:n]);
		}
		if(n == len b)
			fatal("header too long");
		r := sys->read(fd, b[n:], len b - n);
		if(r < 0)
			fatal(sys->sprint("read: %r"));
		if(r == 0)
			fatal("no header: not sdrfs(4)'s iq (sdr/rawiq puts a header on samples)");
		n += r;
	}
}

stopreader()
{
	if(readerpid < 0)
		return;
	fd := sys->open("/prog/" + string readerpid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
	readerpid = -1;
}

fatal(s: string)
{
	stopreader();
	sys->fprint(sys->fildes(2), "sdr/am: %s\n", s);
	raise "fail:" + s;
}
