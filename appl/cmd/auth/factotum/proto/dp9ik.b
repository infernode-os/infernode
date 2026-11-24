implement Authproto;

#
# dp9ik on its own (a caller that has done p9any's negotiation itself):
# the client in p9any.dis, which speaks both.
#

include "sys.m";
	sys: Sys;

include "../authio.m";

p9any: Authproto;

init(f: Authio): string
{
	sys = load Sys Sys->PATH;
	p9any = load Authproto "/dis/auth/proto/p9any.dis";
	if(p9any == nil)
		return sys->sprint("cannot load /dis/auth/proto/p9any.dis: %r");
	return p9any->init(f);
}

interaction(attrs: list of ref Authio->Attr, io: ref Authio->IO): string
{
	return p9any->interaction(attrs, io);
}

keycheck(k: ref Authio->Key): string
{
	return p9any->keycheck(k);
}
