implement Am;

#
# sdr/am - AM demodulated: sdrfs(4)'s iq in, audio(3)'s sound out.
#
#	echo freq 121.5M > /mnt/sdr/ctl
#	sdr/am < /mnt/sdr/iq > /dev/audio
#
# The air band (118-137 MHz) is AM, as are short wave and the medium
# wave broadcasts (through direct sampling, or an upconverter).  The
# samples are summed to about 240k a second, the channel (-b hertz
# either side, 5000) is filtered out and they are decimated to about
# 48k; each one's magnitude
# over the carrier's (its magnitude averaged over a tenth of a second)
# is the sound: the level out does not follow the signal's strength.
#
# -r is the rate in (sdrfs's rate; 2048000, its default), -o the rate
# out (8000, /dev/audio's default) and -c the channels out (2, as
# audio(3); the same sound in each).  -g multiplies the volume.
#
# Usage:	sdr/am [-b hertz] [-c chans] [-g gain] [-o rate] [-r rate]
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
	fin := 2048000;
	arg->init(argv);
	arg->setusage("sdr/am [-b hertz] [-c chans] [-g gain] [-o rate] [-r rate]");
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
		'r' =>
			if((fin = dsp->rate(arg->earg())) == 0)
				arg->usage();
		* =>
			arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

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

	stdin := sys->fildes(0);
	stdout := sys->fildes(1);
	buf := array[Chunk] of byte;
	i := array[Chunk/2] of real;
	q := array[Chunk/2] of real;
	out := array[Chunk/2 * 2 * chans + 16] of byte;
	have := 0;
	carrier := 0.0;
	for(;;) {
		k := sys->read(stdin, buf[have:], len buf - have);
		if(k <= 0) {
			if(k < 0)
				fatal(sys->sprint("read: %r"));
			break;
		}
		k += have;
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

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "sdr/am: %s\n", s);
	raise "fail:" + s;
}
