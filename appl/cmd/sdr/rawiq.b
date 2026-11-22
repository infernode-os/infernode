implement Rawiq;

#
# sdr/rawiq - a capture with no header given one: sdrfs(4)'s iq's, so
# sdr(1)'s demodulators can take it.  The single place a headerless
# capture's rate is said, as raw2iaf(1) is for sound.
#
#	sdr/rawiq -r 2.4M -f 99.5M < capture.cu8 | sdr/fm -o 44100 | auplay /fd/0
#
# The samples are 8-bit unsigned I then Q, as an RTL-SDR's (rtl_sdr's
# output); -r is their rate and -f, if given, the frequency they were
# tuned to, with k, M and G suffixes.
#
# Usage:	sdr/rawiq -r rate [-f freq]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "sdrdsp.m";
	dsp: Sdrdsp;

Rawiq: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	dsp = load Sdrdsp Sdrdsp->PATH;
	arg := load Arg Arg->PATH;
	if(dsp == nil || arg == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	dsp->init();

	r := 0;
	f := big -1;
	arg->init(argv);
	arg->setusage("sdr/rawiq -r rate [-f freq]");
	while((o := arg->opt()) != 0)
		case o {
		'r' =>
			if((r = dsp->rate(arg->earg())) == 0)
				arg->usage();
		'f' =>
			if((f = hertz(arg->earg())) <= big 0)
				arg->usage();
		* =>
			arg->usage();
		}
	if(arg->argv() != nil || r == 0)
		arg->usage();

	l: list of string;
	if(f > big 0)
		l = "freq " + string f :: nil;
	h := dsp->mkheader("rate " + string r :: "enc cu8" :: l);
	stdout := sys->fildes(1);
	if(sys->write(stdout, h, len h) != len h)
		fatal(sys->sprint("write: %r"));
	if(sys->stream(sys->fildes(0), stdout, 64*1024) < 0)
		fatal(sys->sprint("copy: %r"));
}

# hertz, with k, M or G; 0 if not
hertz(v: string): big
{
	if(v == nil)
		return big 0;
	m := 1.0;
	case v[len v - 1] {
	'k' or 'K' =>
		m = 1e3;
	'M' =>
		m = 1e6;
	'G' =>
		m = 1e9;
	}
	if(m != 1.0)
		v = v[0:len v - 1];
	dot := 0;
	digits := 0;
	for(i := 0; i < len v; i++) {
		if(v[i] == '.' && !dot)
			dot = 1;
		else if(v[i] >= '0' && v[i] <= '9')
			digits++;
		else
			return big 0;
	}
	if(digits == 0)
		return big 0;
	x := real v * m;
	if(x < 1.0 || x > 4294967295.0)
		return big 0;
	return big x;	# rounds
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "sdr/rawiq: %s\n", s);
	raise "fail:" + s;
}
