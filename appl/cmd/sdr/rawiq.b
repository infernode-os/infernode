implement Rawiq;

#
# sdr/rawiq - a header put on samples that have none, so sdr(1)'s
# demodulators take them: rtl_sdr's recordings, or iq's samples with
# the header cut off.  The samples are 8-bit unsigned I then Q (cu8),
# at -r samples a second, tuned to -f hertz if it is given.
#
#	rtl_sdr -f 99.5M -s 2.4M rec.u8	# on the host
#	sdr/rawiq -r 2.4M -f 99.5M < rec.u8 | sdr/fm -o 44100 | auplay /fd/0
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

	rate := 0;
	freq := big -1;
	arg->init(argv);
	arg->setusage("sdr/rawiq -r rate [-f freq]");
	while((o := arg->opt()) != 0)
		case o {
		'r' =>
			if((rate = dsp->rate(arg->earg())) == 0)
				arg->usage();
		'f' =>
			if((freq = dsp->hertz(arg->earg())) <= big 0)
				arg->usage();
		* =>
			arg->usage();
		}
	if(rate == 0 || arg->argv() != nil)
		arg->usage();

	s := sys->sprint("rate %d\nenc cu8\n", rate);
	if(freq > big 0)
		s += sys->sprint("freq %bd\n", freq);
	h := dsp->header(s);
	stdout := sys->fildes(1);
	if(sys->write(stdout, h, len h) != len h)
		fatal(sys->sprint("write: %r"));
	if(sys->stream(sys->fildes(0), stdout, 64*1024) < 0)
		fatal(sys->sprint("copy: %r"));
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "sdr/rawiq: %s\n", s);
	raise "fail:" + s;
}
