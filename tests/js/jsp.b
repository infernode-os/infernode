implement Jsp;

#
# jsp - parse JavaScript and say whether it parsed.
#
#	jsp [-m] [-s] [-l] [-t] -e source | file...
#
# -l only tokenizes (no regular expression literals); -t says how long it took.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "jslex.m";
	jslex: Jslex;
	Lex: import jslex;

include "jsparse.m";
	jsparse: Jsparse;

Jsp: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	jsparse->init();
	ismod := 0;
	strict := 0;
	lexonly := 0;
	for(args = tl args; args != nil; args = tl args) {
		case hd args {
		"-m" =>
			ismod = 1;
		"-s" =>
			strict = 1;
		"-l" =>
			lexonly = 1;
		"-t" =>
			timing = 1;
		"-e" =>
			args = tl args;
			report("-e", hd args, ismod, strict, lexonly);
		* =>
			report(hd args, readfile(hd args), ismod, strict, lexonly);
		}
	}
}

timing := 0;

report(name, src: string, ismod, strict, lexonly: int)
{
	t0 := sys->millisec();
	err: string;
	if(lexonly) {
		l := Lex.new(src, ismod);
		n := 0;
		re := 1;
		for(;;) {
			t := l.next(re);
			# a regular expression may follow punctuation but ) ] }, and a keyword
			re = t.kind == Jslex->Tpunct && t.s != ")" && t.s != "]" && t.s != "}" ||
				t.kind == Jslex->Tident && jslex->reserved(t.s);
			if(t.kind == Jslex->Teof || l.err != nil)
				break;
			n++;
		}
		err = l.err;
		if(timing)
			sys->print("%s: %d tokens\n", name, n);
	} else
		(nil, err) = jsparse->parse(src, ismod, strict);
	if(timing)
		sys->print("%s: %d ms\n", name, sys->millisec() - t0);
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
	buf := array[65536] of byte;
	n := 0;
	for(;;) {
		if(n == len buf) {
			nb := array[2 * len buf] of byte;
			nb[0:] = buf;
			buf = nb;
		}
		k := sys->read(fd, buf[n:], len buf - n);
		if(k <= 0)
			break;
		n += k;
	}
	buf = buf[0:n];
	return jslex->utf16(buf);
}
