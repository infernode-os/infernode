implement Fakecs;

#
# fakecs - a connection server that knows only what it is told, for tests
#
#	fakecs name=addr ...
#
# Serves /net/cs in the caller's name space (from a srv instance of its
# own, bound before /net).  "tcp!name!port" is answered with
# "/net/tcp/clone addr!port" for each name given, and nothing else is
# translated: there is no host file, no DNS and no way out.
#
# The agent's fetch tools dial only addresses publicnet takes for
# public, which the loopback is not, so a test of them against a
# loopback server gives a name an address that reads as public and that
# address the loopback's:
#
#	fakecs fetch.test=192.88.99.1 192.88.99.1=127.0.0.1
#
# The check is made on the first answer, the dial asks again with the
# address it was given, and the connection goes to 127.0.0.1.  (The
# stand-in is from 192.88.99.0/24, the retired 6to4 relay prefix, which
# nothing routes: were the second question ever not asked here, the
# dial would go nowhere.)
#

include "sys.m";
	sys: Sys;

include "draw.m";

Fakecs: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

names: list of (string, string);
answers: list of (int, string);	# by fid: what its question was answered with

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	for(args = tl args; args != nil; args = tl args) {
		a := hd args;
		for(i := 0; i < len a; i++)
			if(a[i] == '=')
				break;
		if(i == 0 || i >= len a - 1) {
			sys->fprint(sys->fildes(2), "usage: fakecs name=addr ...\n");
			raise "fail:usage";
		}
		names = (a[0:i], a[i+1:]) :: names;
	}
	if(sys->bind("#sfakecs", "/net", Sys->MBEFORE) < 0) {
		sys->fprint(sys->fildes(2), "fakecs: bind #sfakecs /net: %r\n");
		raise "fail:bind";
	}
	fio := sys->file2chan("/net", "cs");
	if(fio == nil) {
		sys->fprint(sys->fildes(2), "fakecs: file2chan /net/cs: %r\n");
		raise "fail:file2chan";
	}
	spawn serve(fio);
}

serve(fio: ref Sys->FileIO)
{
	for(;;) alt {
	(off, count, fid, rc) := <-fio.read =>
		if(rc == nil) {
			forget(fid);
			continue;
		}
		a := array of byte answer(fid);
		if(off >= len a)
			rc <-= (nil, nil);
		else {
			if(off + count > len a)
				count = len a - off;
			rc <-= (a[off:off+count], nil);
		}
	(nil, data, fid, wc) := <-fio.write =>
		if(wc == nil) {
			forget(fid);
			continue;
		}
		(r, err) := translate(string data);
		forget(fid);
		if(err != nil)
			wc <-= (0, err);
		else {
			answers = (fid, r) :: answers;
			wc <-= (len data, nil);
		}
	}
}

# "tcp!name!port" -> "/net/tcp/clone addr!port"
translate(q: string): (string, string)
{
	(n, f) := sys->tokenize(q, "!");
	if(n != 3 || hd f != "tcp" && hd f != "net")
		return (nil, "cs: can't translate address");
	name := hd tl f;
	port := hd tl tl f;
	for(l := names; l != nil; l = tl l)
		if((hd l).t0 == name)
			return ("/net/tcp/clone " + (hd l).t1 + "!" + port, nil);
	return (nil, "cs: can't translate address");
}

answer(fid: int): string
{
	for(l := answers; l != nil; l = tl l)
		if((hd l).t0 == fid)
			return (hd l).t1;
	return "";
}

forget(fid: int)
{
	r: list of (int, string);
	for(l := answers; l != nil; l = tl l)
		if((hd l).t0 != fid)
			r = hd l :: r;
	answers = r;
}
