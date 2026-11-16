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
# The rate in is the samples' own, from their header, as sdr/fm's;
# -o is the rate out (8000, /dev/audio's default) and -c the channels
# out (2, as audio(3); the same sound in each), said in audio(6)'s
# header before the sound, or with -R not.  -g multiplies the volume.
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
	Decim, Fir, Resamp, Pcm: import dsp;

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

	raw := 0;
	chans := 2;
	bw := 5000.0;
	gain := 1.0;
	fout := 8000;
	arg->init(argv);
	arg->setusage("sdr/am [-R] [-b hertz] [-c chans] [-g gain] [-o rate]");
	while((o := arg->opt()) != 0)
		case o {
		'R' =>
			raw = 1;
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
		* =>
			arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	# the rate in is what the samples' header says
	rc := chan[Ahead] of (array of byte, string);
	pidc := chan of int;
	spawn readahead(sys->fildes(0), rc, pidc);
	readerpid = <-pidc;
	(fin, pend) := readheader(rc);

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

	stdout := sys->fildes(1);
	buf := array[Chunk+1] of byte;	# a byte carried, and a chunk
	i := array[Chunk/2] of real;
	q := array[Chunk/2] of real;
	out := array[Chunk/2 * 2 * chans + 16] of byte;
	have := 0;
	carrier := 0.0;
	if(!raw) {
		h := dsp->mkheader("rate " + string fout :: "chans " + string chans :: "bits 16" :: "enc pcm" :: nil);
		if(sys->write(stdout, h, len h) != len h)
			fatal(sys->sprint("write: %r"));
	}
	for(;;) {
		b: array of byte;
		if(len pend > 0) {
			# the samples that came with the header
			b = pend;
			if(len b > Chunk)
				b = b[0:Chunk];
			pend = pend[len b:];
		} else {
			err: string;
			(b, err) = <-rc;
			if(b == nil) {
				readerpid = -1;
				if(err != nil)
					fatal("read: " + err);
				break;
			}
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

# the samples' header, from the reader's first chunks: the rate it
# says, and the samples that came after it in them
readheader(rc: chan of (array of byte, string)): (int, array of byte)
{
	b := array[0] of byte;
	for(;;) {
		(c, err) := <-rc;
		if(c == nil) {
			readerpid = -1;
			if(err != nil)
				fatal("read: " + err);
			if(len b == 0)
				fatal("no header: no input");
			fatal("no header: the input ended in it");
		}
		nb := array[len b + len c] of byte;
		nb[0:] = b;
		nb[len b:] = c;
		b = nb;
		(hl, h, e) := dsp->header(b, len b);
		if(e != nil)
			fatal(e);
		if(hl > 0) {
			(r, nil, fe) := dsp->iqformat(h);
			if(fe != nil)
				fatal(fe);
			return (r, b[hl:]);
		}
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
