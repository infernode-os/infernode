implement Random;

include "sys.m";
include "draw.m";
include "keyring.m";
include "security.m";

sys: Sys;

#
# Random bytes, or an exception: never bytes that are not random.
#
# These gave zeros when the device could not be opened, and whatever
# the array held (zeros) past a short or failed read, with no error:
# a salt, a nonce or a blinding pad of zeros looks like any other to
# its caller.  Neither function has a result that can say "no", so
# a failure is raised ("random: ..."), which ends a caller that has
# no handler, with the reason, before it uses anything.
#

devname(which: int): string
{
	case which {
	ReallyRandom =>
		return "/dev/random";
	NotQuiteRandom =>
		return "/dev/notquiterandom";
	}
	raise "random: unknown source";
}

fill(which: int, buf: array of byte)
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	file := devname(which);
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		raise sys->sprint("random: cannot open %s: %r", file);
	for(n := 0; n < len buf; ){
		m := sys->read(fd, buf[n:], len buf - n);
		if(m < 0)
			raise sys->sprint("random: cannot read %s: %r", file);
		if(m == 0)
			raise sys->sprint("random: %s gave %d of %d bytes", file, n, len buf);
		n += m;
	}
}

randomint(which: int): int
{
	buf := array[4] of byte;
	fill(which, buf);
	rand := 0;
	for(i := 0; i < 4; i++)
		rand = (rand<<8) | int buf[i];
	return rand;
}

randombuf(which, n: int): array of byte
{
	if(n < 0)
		raise "random: negative count";
	buf := array[n] of byte;
	fill(which, buf);
	return buf;
}
