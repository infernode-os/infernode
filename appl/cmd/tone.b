implement Tone;

#
# tone: sine tones to /dev/audio, for hearing whether the jack works.
#
#	tone [-d /dev/audio] [-r rate] [-s secs] left|right|both|sweep|sequence [hz]
#
# left and right play one channel and silence on the other, both plays
# both, sweep runs from 200 Hz to 2 kHz, and sequence plays all four in
# turn and repeats until killed -- the test a listener with earphones
# runs: left is left, right is right, both is louder, the sweep is
# smooth, and between them is silence rather than buzz.
#
# 16-bit signed little-endian stereo PCM, which is what audio(3)
# defaults to on every implementation of /dev/audio in this tree.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "arg.m";

Tone: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

dev := "/dev/audio";
rate := 44100;
secs := 2;
amp := 12000.0;		# of 32767: loud enough to hear, not to clip the filter

usage()
{
	sys->fprint(sys->fildes(2), "usage: tone [-d dev] [-r rate] [-s secs] left|right|both|sweep|sequence [hz]\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	arg := load Arg Arg->PATH;
	arg->init(args);
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	dev = arg->earg();
		'r' =>	rate = int arg->earg();
		's' =>	secs = int arg->earg();
		* =>	usage();
		}
	args = arg->argv();
	if(args == nil)
		usage();
	what := hd args;
	hz := 440.0;
	if(tl args != nil)
		hz = real hd tl args;

	fd := sys->open(dev, Sys->OWRITE);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "tone: %s: %r\n", dev);
		raise "fail:open";
	}
	ctl := sys->open(dev + "ctl", Sys->OWRITE);
	if(ctl != nil)
		sys->fprint(ctl, "rate %d chans 2 bits 16", rate);
	mktab();

	case what {
	"left" =>	play(fd, hz, 0.0, secs);
	"right" =>	play(fd, 0.0, hz, secs);
	"both" =>	play(fd, hz, hz, secs);
	"sweep" =>	sweep(fd, secs);
	"sequence" =>
		for(;;){
			play(fd, hz, 0.0, secs);
			quiet(fd, 1);
			play(fd, 0.0, hz, secs);
			quiet(fd, 1);
			play(fd, hz, hz, secs);
			quiet(fd, 1);
			sweep(fd, 2 * secs);
			quiet(fd, 2);
		}
	* =>	usage();
	}
}

# one buffer of frames: a 16th of a second, written whole
Frames: con 2756;

# One period of the sine, computed once. Real arithmetic per sample is
# what this program did first, and on the bare-metal kernel -- built
# without the FPU's registers, so every real is software -- it made
# 2300 samples a second against the 88200 the jack consumes; the
# driver logged an underrun on two buffers of three. Integer phase into
# a table is how a synthesiser does it anyway.
Tabbits: con 12;
Tabsize: con 1 << Tabbits;
tab: array of int;

mktab()
{
	tab = array[Tabsize] of int;
	for(i := 0; i < Tabsize; i++)
		tab[i] = int (amp * math->sin(2.0 * Math->Pi * real i / real Tabsize));
}

# phase is 32-bit fixed point: the top Tabbits index the table
step(hz: real): int
{
	return int (hz * 4294967296.0 / real rate);
}

put(buf: array of byte, i: int, s: int)
{
	buf[i] = byte s;
	buf[i+1] = byte (s >> 8);
}

play(fd: ref Sys->FD, lhz, rhz: real, s: int)
{
	buf := array[Frames * 4] of byte;
	n := s * rate;
	lp := 0;
	rp := 0;
	ls := step(lhz);
	rs := step(rhz);
	for(t := 0; t < n; t += Frames){
		for(i := 0; i < Frames; i++){
			l := 0;
			r := 0;
			if(lhz > 0.0)
				l = tab[(lp >> (32 - Tabbits)) & (Tabsize - 1)];
			if(rhz > 0.0)
				r = tab[(rp >> (32 - Tabbits)) & (Tabsize - 1)];
			lp += ls;
			rp += rs;
			put(buf, i*4, l);
			put(buf, i*4+2, r);
		}
		if(sys->write(fd, buf, len buf) != len buf){
			sys->fprint(sys->fildes(2), "tone: write: %r\n");
			raise "fail:write";
		}
	}
}

sweep(fd: ref Sys->FD, s: int)
{
	buf := array[Frames * 4] of byte;
	n := s * rate;
	phase := 0;
	# 200 Hz to 2 kHz, a decade over the run: the step is recomputed per
	# buffer (one real multiply per 2756 samples), geometric in between
	for(t := 0; t < n; t += Frames){
		hz := 200.0 * math->pow(10.0, real t / real n);
		st := step(hz);
		for(i := 0; i < Frames; i++){
			v := tab[(phase >> (32 - Tabbits)) & (Tabsize - 1)];
			phase += st;
			put(buf, i*4, v);
			put(buf, i*4+2, v);
		}
		if(sys->write(fd, buf, len buf) != len buf)
			raise "fail:write";
	}
}

quiet(fd: ref Sys->FD, s: int)
{
	buf := array[Frames * 4] of { * => byte 0 };
	for(t := 0; t < s * rate; t += Frames)
		sys->write(fd, buf, len buf);
}
