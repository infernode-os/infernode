implement Iqhdr;

#
# sdr/iqhdr - the header of samples in sdrfs(4)'s form, as commands:
# each line of it is one sdrfs's ctl takes, so
#
#	sdr/iqhdr < rec > /mnt/sdr/ctl
#
# tunes the radio to what a recording (cat /mnt/sdr/iq > rec) was made
# at.  The lines are given in one write, so ctl does all of them or
# none.  Input with no header, or not 8-bit unsigned I and Q, is
# refused.
#
# Usage:	sdr/iqhdr
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sdrdsp.m";
	dsp: Sdrdsp;

Iqhdr: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	dsp = load Sdrdsp Sdrdsp->PATH;
	if(dsp == nil)
		fatal(sys->sprint("cannot load sdrdsp: %r"));
	dsp->init();
	if(argv != nil && tl argv != nil) {
		sys->fprint(sys->fildes(2), "usage: sdr/iqhdr\n");
		raise "fail:usage";
	}

	stdin := sys->fildes(0);
	b := array[Sdrdsp->Maxheader] of byte;
	n := 0;
	for(;;) {
		if(n == len b)
			fatal("no header: no empty line in its first " + string len b + " bytes");
		k := sys->read(stdin, b[n:], len b - n);
		if(k < 0)
			fatal(sys->sprint("read: %r"));
		if(k == 0) {
			if(n == 0)
				fatal("no header: no input");
			fatal("no header: the input ended in it");
		}
		n += k;
		(hl, h, e) := dsp->header(b, n);
		if(e != nil)
			fatal(e);
		if(hl == 0)
			continue;
		(nil, nil, fe) := dsp->iqformat(h);
		if(fe != nil)
			fatal(fe);
		s := "";
		for(; h != nil; h = tl h) {
			line := "";
			for(w := hd h; w != nil; w = tl w) {
				if(line != "")
					line += " ";
				line += hd w;
			}
			s += line + "\n";
		}
		o := array of byte s;
		if(sys->write(sys->fildes(1), o, len o) != len o)
			fatal(sys->sprint("write: %r"));
		return;
	}
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "sdr/iqhdr: %s\n", s);
	raise "fail:" + s;
}
