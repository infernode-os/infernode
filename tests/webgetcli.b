implement Webgetcli;

#
# tests/host/webget_https_test.sh's client: a URL fetched through the
# webget service's file (/chan/webget, as web(2) uses it for acme's and
# Xenith's Jwin), its answer printed: the body between marks, or the
# service's error.
#
# usage: webgetcli url
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "webget.m";

Webgetcli: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(len args != 2) {
		sys->print("webgetcli: usage: webgetcli url\n");
		return;
	}
	io := sys->open("/chan/webget", Sys->ORDWR);
	if(io == nil) {
		webget := load Webget Webget->PATH;
		if(webget == nil) {
			sys->print("webgetcli: cannot load %s: %r\n", Webget->PATH);
			return;
		}
		spawn webget->init(nil, nil);
		for(i := 0; io == nil && i < 50; i++) {
			sys->sleep(100);
			io = sys->open("/chan/webget", Sys->ORDWR);
		}
	}
	if(io == nil) {
		sys->print("webgetcli: no /chan/webget: %r\n");
		return;
	}
	req := array of byte ("GET∎0∎id1∎" + hd tl args + "∎text/plain,*/*∎no-cache\n");
	if(sys->write(io, req, len req) != len req) {
		sys->print("webgetcli: write: %r\n");
		return;
	}
	# "OK length id type url\n" and the body, or "ERROR id message\n",
	# in as many reads as they come
	buf := array[8192] of byte;
	have := 0;
	nl := -1;
	while(nl < 0 && have < len buf) {
		n := sys->read(io, buf[have:], len buf - have);
		if(n <= 0)
			break;
		for(i := have; i < have + n; i++)
			if(buf[i] == byte '\n') {
				nl = i;
				break;
			}
		have += n;
	}
	if(nl < 0) {
		sys->print("webgetcli: no answer\n");
		return;
	}
	status := string buf[0:nl];
	(nil, f) := sys->tokenize(status, " ");
	if(f == nil || hd f != "OK" || tl f == nil) {
		sys->print("webgetcli: failed: %s\n", status);
		return;
	}
	clen := int hd tl f;
	body := array[clen] of byte;
	got := have - (nl + 1);
	if(got > clen)
		got = clen;
	body[0:] = buf[nl+1:nl+1+got];
	while(got < clen) {
		n := sys->read(io, body[got:], clen - got);
		if(n <= 0)
			break;
		got += n;
	}
	sys->print("webgetcli: body: %s\n", string body[0:got]);
}
