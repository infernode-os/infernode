implement Jsrun;

#
# jsrun - run JavaScript in a fresh realm.
#
#	jsrun [-e source] [file ...]
#
# Each file, then each -e source, runs in turn in the one realm; the
# last completion value is printed with -p.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "jslex.m";
	jslex: Jslex;

include "web/dom.m";
include "js.m";
	js: Js;

Jsrun: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	jslex = load Jslex Jslex->PATH;
	js = load Js Js->PATH;
	if(js == nil) {
		sys->fprint(sys->fildes(2), "jsrun: cannot load %s: %r\n", Js->PATH);
		raise "fail:load";
	}
	jslex->init();
	err := js->init();
	if(err != nil) {
		sys->fprint(sys->fildes(2), "jsrun: %s\n", err);
		raise "fail:init";
	}
	js->test262();
	show := 0;
	failed := 0;
	for(args = tl args; args != nil; args = tl args) {
		src, name: string;
		case hd args {
		"-p" =>
			show = 1;
			continue;
		"-e" =>
			args = tl args;
			src = hd args;
			name = "-e";
		* =>
			name = hd args;
			src = readfile(name);
			if(src == nil) {
				sys->fprint(sys->fildes(2), "jsrun: cannot read %s: %r\n", name);
				failed = 1;
				continue;
			}
		}
		(r, e) := js->evalscript(src, name);
		if(e != nil) {
			sys->print("%s\n", e);
			failed = 1;
		} else if(show)
			sys->print("%s\n", r);
	}
	if(failed)
		raise "fail:errors";
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
