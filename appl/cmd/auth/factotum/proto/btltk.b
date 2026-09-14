implement Authproto;

#
#	proto=btltk addr=<remote>
#
#	Hands bt9p(4) the LE long-term key it shares with a peripheral,
#	with the EDIV and Rand the controller must be given to start
#	encryption with it.  Made by LE pairing, so bt9p puts it here --
#
#		key proto=btltk addr=c8:f3:e8:06:55:8b type=1 ediv=4660 rand=0102030405060708 !ltk=0123...cdef
#
#	type is the peer's address type (0 public, 1 random).  As with
#	btlink, the same line goes to the keys file for the next boot,
#	and a read of ctl lists the peripherals the machine is bonded
#	with, key elided.
#

include "sys.m";
	sys: Sys;

include "../authio.m";
	authio:	Authio;
	Attr, IO: import authio;

init(f: Authio): string
{
	sys = load Sys Sys->PATH;
	authio = f;
	return nil;
}

interaction(attrs: list of ref Attr, io: ref Authio->IO): string
{
	(key, err) := io.findkey(attrs, "!ltk?");
	if(key == nil)
		return err;
	k := authio->lookattrval(key.secrets, "!ltk");
	if(k == nil)
		return "no key";
	ediv := authio->lookattrval(key.attrs, "ediv");
	if(ediv == nil)
		ediv = "0";
	rnd := authio->lookattrval(key.attrs, "rand");
	if(rnd == nil)
		rnd = "0000000000000000";
	# what bt9p reads back: the key, the EDIV, the Rand
	a := array of byte (k + " " + ediv + " " + rnd);
	io.write(a, len a);
	return nil;
}

keycheck(k: ref Authio->Key): string
{
	key := authio->lookattrval(k.secrets, "!ltk");
	if(key != nil && len key != 32)
		return "btltk !ltk must be 32 hex digits";
	rnd := authio->lookattrval(k.attrs, "rand");
	if(rnd != nil && len rnd != 16)
		return "btltk rand must be 16 hex digits";
	return nil;
}
