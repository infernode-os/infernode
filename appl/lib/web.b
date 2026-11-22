implement Web;
include "sys.m";
sys:	Sys;
print, sprint: import sys;
include "draw.m";
include "string.m";
stringmod: String;

include "url.m";
urlmod: Url;
ParsedUrl: import urlmod;

include "web.m";
include "webget.m";

webio:	ref Sys->FD;
DEBUG: con 0;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stringmod = load String String->PATH;
	urlmod = load Url Url->PATH;
	urlmod->init();
	webstart();
	url := "http://google.com";
	
	args = tl args;
	if(len args >= 1)
		url = hd args;
	(doctype, nil, clen) := webget(url, url, "text/html,text/plain,image/x-compressed,*/*");
	if(doctype==nil)
		error("no page '"+doctype+"'", url);
	b := webcontents(clen);
	sys->print("%s", string b);
}

init0()
{
	sys = load Sys Sys->PATH;
	stringmod = load String String->PATH;
	urlmod = load Url Url->PATH;
	urlmod->init();
	webstart();
}

readurl(url: string): array of byte
{
	(doctype, nil, clen) := webget(url, url, "text/html,text/plain,image/x-compressed,*/*");
	if(doctype==nil){
		error("no page '"+doctype+"'", url);
		return nil;
	}
	return  webcontents(clen);
}

posturl(url, msg: string): array of byte
{
	(doctype, nil, clen) := webpost(url, url, "text/html,text/plain,image/x-compressed,*/*", msg);
	if(doctype==nil){
		error("no page '"+doctype+"'", url);
		return nil;
	}
	return  webcontents(clen);
}

error(msg, url: string)
{
	if(DEBUG)
		sys->print("ERROR: %s: %s\n", url, msg);
}

webstart(): string
{
	webio = sys->open("/chan/webget", sys->ORDWR);
	if(webio == nil) {
		webget := load Webget Webget->PATH;
		if(webget == nil)
			return ("can't load webget from " + Webget->PATH);
		spawn webget->init(nil, nil);
		ntries := 0;
		while(webio == nil && ntries++ < 10)
			webio = sys->open("/chan/webget", sys->ORDWR);
		if(webio == nil)
			return "error connecting to web";
	}
	return "";
}

# What a read of the status line brought past its newline: the start
# of the body, which webcontents takes first.
pending: array of byte;

# webget's answer begins "OK length id type url\n" or "ERROR id
# message\n", and the body follows.  The line was taken to be exactly
# what one read of 1000 bytes gave: a line longer than that (a long
# URL) was cut and its end read as the body's start, and body bytes
# that came with the line were dropped, so the body was short by them
# and the next answer began in the middle of this one.  The line is
# read to its newline, in as many reads as it takes, and what came
# after it is kept.
MAXSTATUS: con 64*1024;

getstatus(loc: string): (string, string, int)
{
	clen := 0;
	dtype := "";
	nbase := "";
	pending = nil;
	buf := array[1000] of byte;
	have := 0;
	nl := -1;
	while(nl < 0) {
		if(have == len buf) {
			if(len buf >= MAXSTATUS)
				break;
			nb := array[2 * len buf] of byte;
			nb[0:] = buf;
			buf = nb;
		}
		n := sys->read(webio, buf[have:], len buf - have);
		if(n < 0) {
			error(sys->sprint("error reading webget response header: %r"), loc);
			return (dtype, nbase, clen);
		}
		if(n == 0)
			break;
		for(i := have; i < have + n; i++)
			if(buf[i] == byte '\n') {
				nl = i;
				break;
			}
		have += n;
	}
	if(nl < 0) {
		error("unexpected webget response: " + string buf[0:have], loc);
		return (dtype, nbase, clen);
	}
	status := string buf[0:nl];
	if(DEBUG)
		sys->print("webget response: %s\n", status);
	(nf, l) := sys->tokenize(status, " ");
	if(nf < 3)
		error("unexpected webget response: " + status, loc);
	else {
		s := hd l;
		l = tl l;
		if(s == "ERROR") {
			(nil, msg) := stringmod->splitl(status[6:], " ");
			error(msg, loc);
		}
		else if(s == "OK" && nf >= 5) {
			clen = int (hd l);
			l = tl(tl l);
			dtype = hd l;
			l = tl l;
			nbase = hd l;
			if(clen < 0) {
				clen = 0;
				dtype = "";
				error("webget protocol error", loc);
			}
			else if(have > nl + 1)
				pending = buf[nl+1:have];
		}
		else
			error("webget protocol error", loc);
	}
	return (dtype, nbase, clen);
}

webpost(base, url, types, msg: string) : (string, string, int)
{
	u := urlmod->makeurl(url);
	b := urlmod->makeurl(base);
	if(u == nil){
		error("not a URL", url);
		return ("", "", 0);
	}
	u.makeabsolute(b);
	savefrag := u.frag;
	u.frag = "";
	loc := u.tostring();
	u.frag = savefrag;
	clen := 0;
	dtype := "";
	nbase := "";
	s := sys->sprint("POST∎%d∎id1∎%s∎%s∎max-stale=3600\n", len msg, loc, types);
	if(DEBUG)
		sys->print("webget request: %s", s);
	bs := array of byte s;
	n := sys->write(webio, bs, len bs);
	if(n < 0)
		error(sys->sprint("error writing webget request: %r"), loc);
	n = sys->write(webio, array of byte msg, len array of byte msg);
	if(n < 0)
		error(sys->sprint("error writing webget post data: %r"), loc);
	else {
		(dtype, nbase, clen) = getstatus(loc);
	}
	return (dtype, nbase, clen);
}

webget(base, url, types: string) : (string, string, int)
{
	n : int;
	s : string;
	u := urlmod->makeurl(url);
	b := urlmod->makeurl(base);
	if(u == nil){
		error("not a URL", url);
		return ("", "", 0);
	}
	u.makeabsolute(b);
	savefrag := u.frag;
	u.frag = "";
	loc := u.tostring();
	u.frag = savefrag;
	clen := 0;
	dtype := "";
	nbase := "";
	s = "GET∎0∎id1∎" + loc + "∎" + types + "∎max-stale=3600\n";
	if(DEBUG)
		sys->print("webget request: %s", s);
	bs := array of byte s;
	n = sys->write(webio, bs, len bs);
	if(n < 0)
		error(sys->sprint("error writing webget request: %r"), loc);
	else {
		(dtype, nbase, clen) =  getstatus(loc);
	}
	return (dtype, nbase, clen);
}

webcontents(clen: int) : array of byte
{
	contents := array[clen] of byte;
	i := 0;
	n := 0;
	if(pending != nil) {
		i = len pending;
		if(i > clen)
			i = clen;
		contents[0:] = pending[0:i];
		pending = nil;
	}
	while(i < clen) {
		n = sys->read(webio, contents[i:], clen-i);
		# no more is the end of it: a read of nothing was read again,
		# for ever
		if(n <= 0)
			break;
		i += n;
	}
	return contents[0:i];
}
