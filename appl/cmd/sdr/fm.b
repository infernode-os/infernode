implement Fm;

#
# sdr/fm - FM demodulated: sdrfs(4)'s iq in, audio(3)'s sound out.
#
#	echo freq 98.5M > /mnt/sdr/ctl
#	sdr/fm < /mnt/sdr/iq > /dev/audio
#
# Wide (broadcast) by default; -n narrow (marine VHF, 2 m amateur, NOAA
# weather, the land mobile bands).  The samples are summed to about
# 240k a second; narrow, the channel (8 kHz either side) is filtered out
# of those and they are decimated to about 48k.  The angle between each
# sample and the last is the sound; it is then de-emphasised (wide:
# -d microseconds, 50, or 75 in the Americas; 0 none), wide kept below
# 15 kHz (above are the stereo pilot and subcarriers), and averaged to
# the rate out.  The sound is mono.
#
# -r is the rate in (sdrfs's rate; 2048000, its default), -o the rate
# out (8000, /dev/audio's default) and -c the channels out (2, as
# audio(3); the same sound in each).  -g multiplies the volume.
#
# Usage:	sdr/fm [-nw] [-c chans] [-d µs] [-g gain] [-o rate] [-r rate]
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

Fm: module
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

	narrow := 0;
	chans := 2;
	deemph := -1.0;
	gain := 1.0;
	fout := 8000;
	fin := 2048000;
	arg->init(argv);
	arg->setusage("sdr/fm [-nw] [-c chans] [-d µs] [-g gain] [-o rate] [-r rate]");
	while((o := arg->opt()) != 0)
		case o {
		'n' =>
			narrow = 1;
		'w' =>
			narrow = 0;
		'c' =>
			chans = int arg->earg();
			if(chans < 1 || chans > 8)
				arg->usage();
		'd' =>
			deemph = real arg->earg();
			if(deemph < 0.0)
				arg->usage();
		'g' =>
			gain = real arg->earg();
		'o' =>
			if((fout = dsp->rate(arg->earg())) == 0)
				arg->usage();
		'r' =>
			if((fin = dsp->rate(arg->earg())) == 0)
				arg->usage();
		* =>
			arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	# the deviation at full scale, and the rate it is found at: wide,
	# the samples summed to about 240k; narrow, then the channel (8k
	# either side) filtered out and decimated to about 48k
	dev := 75000.0;
	n1 := fin / 240000;
	if(n1 < 1)
		n1 = 1;
	n := n1;
	fir: ref Fir;
	if(narrow) {
		dev = 5000.0;
		if(deemph < 0.0)
			deemph = 0.0;
		f1 := real fin / real n;
		n2 := int (f1 / 48000.0);	# rounds
		if(n2 < 1)
			n2 = 1;
		if(f1 / real n2 < real fout)
			n2 = int (f1 / real fout - 0.5);
		if(n2 > 1) {
			fir = Fir.new(n2, 8000.0 / f1, 96);
			n *= n2;
		}
	} else if(deemph < 0.0)
		deemph = 50.0;
	if(n < 1 || fin / n < fout)
		fatal(sys->sprint("rate in %d too low for %d out", fin, fout));
	fmid := real fin / real n;

	# wide, the sound has the stereo pilot (19 kHz) and the stereo and
	# RDS subcarriers (23-60 kHz) above it: kept below 15 kHz, and
	# decimated to about 48k, before it is averaged to the rate out
	audio: ref Fir;
	if(!narrow) {
		n3 := int (fmid / 48000.0);	# rounds
		if(n3 < 1)
			n3 = 1;
		while(n3 > 1 && fmid / real n3 < real fout)
			n3--;
		# and below 0.4 of the rate out, so averaging to it folds
		# little back
		cut := 15000.0;
		if(cut > 0.4 * real fout)
			cut = 0.4 * real fout;
		audio = Fir.new(n3, cut / fmid, 128);
	}

	# full deviation at 0.7 of full scale
	gain *= 0.7 * fmid / (2.0 * Math->Pi * dev);
	# de-emphasis: one pole, at the rate it is found
	a := 1.0;
	if(deemph > 0.0)
		a = 1.0 - math->exp(-1.0 / (fmid * deemph * 1e-6));

	d := Decim.new(n1);
	r: ref Resamp;
	if(audio != nil)
		r = Resamp.new(fin, fout * n * audio.n);
	else
		r = Resamp.new(fin, fout * n);
	p := Pcm.new(fout, chans);

	stdin := sys->fildes(0);
	stdout := sys->fildes(1);
	buf := array[Chunk+1] of byte;	# a byte carried, and a chunk
	i := array[Chunk/2] of real;
	q := array[Chunk/2] of real;
	x := array[Chunk/2] of real;
	out := array[Chunk/2 * 2 * chans + 16] of byte;
	have := 0;
	pi := 1.0;
	pq := 0.0;
	y := 0.0;
	rc := chan[Ahead] of (array of byte, string);
	pidc := chan of int;
	spawn readahead(stdin, rc, pidc);
	readerpid = <-pidc;
	for(;;) {
		(b, err) := <-rc;
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

		# the angle turned since the last sample: the frequency
		for(j := 0; j < m; j++) {
			ci := i[j];
			cq := q[j];
			ph := math->atan2(cq*pi - ci*pq, ci*pi + cq*pq);
			pi = ci;
			pq = cq;
			y += a * (ph - y);
			x[j] = y;
		}
		if(audio != nil)
			m = audio.runr(x, m, x);
		m = r.run(x, m, x);
		if(m == 0)
			continue;
		nb := p.run(x, m, gain, out);
		if(sys->write(stdout, out, nb) != nb)
			fatal(sys->sprint("write: %r"));
	}
}

#
# The reads, in a process of their own and a few chunks ahead, so the
# arithmetic never waits on one.  Over a network mount each read waits
# a round trip; fm read, then worked, then read again, and on a Pi 4
# reading another machine's /mnt/sdr at 2.4M it fell 12-22% behind
# sdrfs's stream, which dropped the rest (status's dropped=).  A chunk
# each send, nil at the end, with the error if there was one.
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
	sys->fprint(sys->fildes(2), "sdr/fm: %s\n", s);
	raise "fail:" + s;
}
