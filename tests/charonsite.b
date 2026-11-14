implement Charonsite;

#
# charonsite dir: drive a headless Charon (wm/charon -h) whose files
# are mounted at dir, from commands on standard input, a line each:
#
#	go ctl-command	write it to dir/ctl and wait for the page it
#			starts to be done (or an error, or 30 s); print
#			"GO ms url | title | status"
#	cat file	print dir/file between "BEGIN file" and "END file"
#	ctl command	write it to dir/ctl, wait for nothing
#	field name value	set the form control named name (from
#			dir/forms) to value
#	golink url	go to the first link to url (from dir/links)
#	touch file	make file, for whatever is watching
#	waitfor file	wait for file to be made (30 s at most)
#
# In go and ctl, \n is a newline (a textarea's value).
#
# Not a test itself (the runner takes *_test.dis): tests/host/
# charon_werc_test.sh uses it to time Charon's loads of pages served
# by httpd(8) from wercfs(4) and wikifs.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

Charonsite: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

dir: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	if(len args != 2) {
		sys->fprint(sys->fildes(2), "usage: charonsite dir\n");
		raise "fail:usage";
	}
	dir = hd tl args;
	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	while((l := in.gets('\n')) != nil) {
		if(l[len l - 1] == '\n')
			l = l[0:len l - 1];
		(cmd, rest) := split(l);
		case cmd {
		"go" =>
			go(rest);
		"cat" =>
			cat(rest);
		"ctl" =>
			ctl(rest);
		"field" =>
			field(rest);
		"golink" =>
			golink(rest);
		"touch" =>
			sys->create(rest, Sys->OWRITE, 8r666);
		"waitfor" =>
			waitfor(rest);
		"" =>
			;
		* =>
			sys->print("ERR unknown command %q\n", cmd);
		}
	}
}

# \n in a command is a newline, for a textarea's value
unescape(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '\\' && i+1 < len s && s[i+1] == 'n') {
			t[len t] = '\n';
			i++;
		} else
			t[len t] = s[i];
	return t;
}

split(l: string): (string, string)
{
	for(i := 0; i < len l; i++)
		if(l[i] == ' ')
			return (l[0:i], l[i+1:]);
	return (l, nil);
}

ctl(c: string): int
{
	c = unescape(c);
	fd := sys->open(dir + "/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", c) < 0) {
		sys->print("ERR ctl %q: %r\n", c);
		return -1;
	}
	return 0;
}

go(c: string)
{
	ev := sys->open(dir + "/event", Sys->OREAD);
	if(ev == nil) {
		sys->print("ERR event: %r\n");
		return;
	}
	t0 := sys->millisec();
	if(ctl(c) < 0)
		return;
	done := chan of string;
	spawn waitdone(ev, done);
	timer := chan of int;
	spawn timeout(timer, 30000);
	r: string;
	# done, unless the page goes on to another (a meta refresh)
	for(;;) {
		alt {
		r = <-done =>
			;
		<-timer =>
			r = "timeout";
		}
		if(r == "timeout" || !prefix(read("status"), "loading"))
			break;
		spawn waitdone(ev, done);
	}
	ms := sys->millisec() - t0;
	sys->print("GO %d %s | %s | %s (%s)\n", ms, read("url"), read("title"), read("status"), r);
}

waitdone(ev: ref Sys->FD, done: chan of string)
{
	buf := array[1024] of byte;
	for(;;) {
		n := sys->read(ev, buf, len buf);
		if(n <= 0) {
			done <-= "event ended";
			return;
		}
		e := string buf[0:n];
		if(len e > 0 && e[len e - 1] == '\n')
			e = e[0:len e - 1];
		if(prefix(e, "done") || prefix(e, "error") || e == "stopped") {
			done <-= e;
			return;
		}
	}
}

golink(url: string)
{
	(nil, lines) := sys->tokenize(readall("links"), "\n");
	for(; lines != nil; lines = tl lines) {
		(n, f) := sys->tokenize(hd lines, " ");
		if(n >= 2 && hd tl f == url) {
			go("follow " + hd f);
			return;
		}
	}
	sys->print("ERR no link to %q\n", url);
}

waitfor(f: string)
{
	for(i := 0; i < 300; i++) {
		(ok, nil) := sys->stat(f);
		if(ok >= 0)
			return;
		sys->sleep(100);
	}
	sys->print("ERR %s never made\n", f);
}

# set the control named name, found in forms ("form node kind name
# value" a line), to v
field(a: string)
{
	(name, v) := split(a);
	(nil, lines) := sys->tokenize(readall("forms"), "\n");
	for(; lines != nil; lines = tl lines) {
		(n, f) := sys->tokenize(hd lines, " ");
		if(n >= 4 && hd tl tl tl f == name) {
			ctl("set " + hd tl f + " " + v);
			return;
		}
	}
	sys->print("ERR no field %q\n", name);
}

timeout(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

prefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

read(f: string): string
{
	s := readall(f);
	while(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

readall(f: string): string
{
	fd := sys->open(dir + "/" + f, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("(%r)");
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

cat(f: string)
{
	sys->print("BEGIN %s\n%sEND %s\n", f, readall(f), f);
}
