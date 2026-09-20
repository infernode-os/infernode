implement Authproto;

#
#	proto=btlink addr=<remote>
#
#	Hands bt9p(4) the link key it shares with a peer, when the peer
#	asks to authenticate.  Link keys are made by pairing, not chosen,
#	so bt9p is also who puts them here -- one per peer, sixteen bytes
#	as thirty-two hex digits, with the key type the controller
#	reported --
#
#		key proto=btlink addr=94:bb:43:44:61:04 type=4 !key=0123...cdef
#
#	and, given a keys file, writes the same line to the card so the
#	next boot loads it as it loads the WiFi keys.  factotum holds it
#	from then on and a read of ctl lists whom the machine is paired
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
	(key, err) := io.findkey(attrs, "!key?");
	if(key == nil)
		return err;
	k := authio->lookattrval(key.secrets, "!key");
	if(k == nil)
		return "no key";
	t := authio->lookattrval(key.attrs, "type");
	if(t == nil)
		t = "0";
	# what bt9p reads back: the key, a space, its type
	a := array of byte (k + " " + t);
	io.write(a, len a);
	return nil;
}

keycheck(k: ref Authio->Key): string
{
	key := authio->lookattrval(k.secrets, "!key");
	if(key != nil && len key != 32)
		return "btlink !key must be 32 hex digits";
	return nil;
}
