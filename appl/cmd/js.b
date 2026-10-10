implement Jscmd;

#
# js - run JavaScript.
#
#	js [-p] [-m] [-e source] [file ...]
#
# Each file (a module with -m), then each -e source, runs in turn in one
# realm.  -p prints each completion value.  With no file and no source,
# js reads and runs what is typed, a statement at a time, printing each
# value: a statement that is not yet complete continues on the next line.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "jslex.m";
	jslex: Jslex;

include "jsparse.m";
	jsparse: Jsparse;

include "web/dom.m";
include "js.m";
	js: Js;

Jscmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	js = load Js Js->PATH;
	if(js == nil || jslex == nil || jsparse == nil || bufio == nil) {
		sys->fprint(stderr, "js: cannot load the engine: %r\n");
		raise "fail:load";
	}
	jslex->init();
	jsparse->init();
	err := js->init();
	if(err != nil) {
		sys->fprint(stderr, "js: %s\n", err);
		raise "fail:init";
	}
	show := 0;
	ismod := 0;
	ran := 0;
	failed := 0;
	for(args = tl args; args != nil; args = tl args) {
		a := hd args;
		case a {
		"-p" =>
			show = 1;
			continue;
		"-m" =>
			ismod = 1;
			continue;
		"-e" =>
			args = tl args;
			if(args == nil)
				usage();
			if(!run(hd args, "-e", ismod, show))
				failed = 1;
			ran = 1;
			continue;
		}
		if(len a > 1 && a[0] == '-')
			usage();
		src := readfile(a);
		if(src == nil) {
			sys->fprint(stderr, "js: cannot read %s: %r\n", a);
			failed = 1;
			continue;
		}
		if(!run(src, a, ismod, show))
			failed = 1;
		ran = 1;
	}
	if(!ran)
		repl();
	if(failed)
		raise "fail:errors";
}

usage()
{
	sys->fprint(stderr, "usage: js [-p] [-m] [-e source] [file ...]\n");
	raise "fail:usage";
}

run(src, name: string, ismod, show: int): int
{
	r, e: string;
	if(ismod)
		(r, e) = js->evalmodule(src, name);
	else
		(r, e) = js->evalscript(src, name);
	if(e != nil) {
		sys->fprint(stderr, "%s\n", e);
		return 0;
	}
	if(show)
		sys->print("%s\n", r);
	return 1;
}

repl()
{
	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if(in == nil)
		return;
	src := "";
	for(;;) {
		if(src == "")
			sys->print("> ");
		else
			sys->print("... ");
		line := in.gets('\n');
		if(line == nil)
			break;
		src += line;
		# a statement not yet complete waits for more
		(nil, perr) := jsparse->parse(src, 0, 0);
		if(perr != nil && incomplete(perr))
			continue;
		(r, e) := js->evalscript(src, "stdin");
		src = "";
		if(e != nil)
			sys->print("%s\n", e);
		else if(r != "undefined")
			sys->print("%s\n", r);
	}
}

incomplete(err: string): int
{
	return contains(err, "end of input") || contains(err, "unterminated template") || contains(err, "unterminated comment");
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[0] of byte;
	b := array[65536] of byte;
	for(;;) {
		n := sys->read(fd, b, len b);
		if(n <= 0)
			break;
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = b[0:n];
		buf = nb;
	}
	return jslex->utf16(buf);
}
