implement Jsp;

#
# jsp - parse JavaScript and say whether it parsed.
#
#	jsp [-m] [-s] -e source | file...
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "jsparse.m";
	jsparse: Jsparse;

Jsp: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	jsparse->init();
	ismod := 0;
	strict := 0;
	for(args = tl args; args != nil; args = tl args) {
		case hd args {
		"-m" =>
			ismod = 1;
		"-s" =>
			strict = 1;
		"-e" =>
			args = tl args;
			report("-e", hd args, ismod, strict);
		* =>
			report(hd args, readfile(hd args), ismod, strict);
		}
	}
}

report(name, src: string, ismod, strict: int)
{
	(nil, err) := jsparse->parse(src, ismod, strict);
	if(err != nil)
		sys->print("%s: %s\n", name, err);
	else
		sys->print("%s: ok\n", name);
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
	return string buf;
}
