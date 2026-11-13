implement Iqhdr;

#
# sdr/iqhdr - the header of samples sdrfs(4)'s iq gave (or sdr/rawiq
# made), its lines one a line as ctl takes them, without the padding
# and the empty line after them: what they were tuned to, so a
# recording can be played or the radio tuned back to it.
#
#	cat /mnt/sdr/iq > rec		# a recording, header and all
#	sdr/iqhdr < rec			# rate 2400000, enc cu8, freq ...
#	sdr/iqhdr < rec > /mnt/sdr/ctl	# the radio tuned as it was
#
# Only the header is read.  Refused if the input has none.
#
# Usage:	sdr/iqhdr [file]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sdrdsp.m";
	dsp: Sdrdsp;
	Hdr: import dsp;

Iqhdr: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	dsp = load Sdrdsp Sdrdsp->PATH;
	if(dsp == nil)
		fatal(sys->sprint("cannot load %s: %r", Sdrdsp->PATH));
	dsp->init();

	fd := sys->fildes(0);
	if(argv != nil)
		argv = tl argv;
	if(argv != nil) {
		if(tl argv != nil || (hd argv) != nil && (hd argv)[0] == '-') {
			sys->fprint(sys->fildes(2), "usage: sdr/iqhdr [file]\n");
			raise "fail:usage";
		}
		fd = sys->open(hd argv, Sys->OREAD);
		if(fd == nil)
			fatal(sys->sprint("%s: %r", hd argv));
	}

	b := array[Sdrdsp->Maxhdr] of byte;
	n := 0;
	for(;;) {
		(h, k, e) := Hdr.read(b, n);
		if(k < 0)
			fatal(e);
		if(k > 0) {
			# in one write, as ctl takes a setting's lines together
			o := array of byte h.text();
			if(sys->write(sys->fildes(1), o, len o) != len o)
				fatal(sys->sprint("write: %r"));
			return;
		}
		if(n == len b)
			fatal("header too long");
		r := sys->read(fd, b[n:], len b - n);
		if(r < 0)
			fatal(sys->sprint("read: %r"));
		if(r == 0)
			fatal("no header");
		n += r;
	}
}

fatal(s: string)
{
	sys->fprint(sys->fildes(2), "sdr/iqhdr: %s\n", s);
	raise "fail:" + s;
}
