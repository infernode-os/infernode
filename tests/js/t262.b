implement T262;

#
# t262 - test262's syntax tests against the parser.
#
#	t262 [-v] [-r] [-t ms] [-g n] [-L n] [-f failures] dir...
#
# Each test's front matter says what is expected: negative phase parse
# (an early error) means the source must be refused; anything else must
# parse.  With -r the tests are run, each in a realm of its own, with
# test262's harness: they must finish without an exception (or, for a
# negative runtime test, with the one named), and an async test must
# report that it completed.  A test is run as sloppy and as strict code unless its flags
# say otherwise (onlyStrict, noStrict, raw), and as a module if its
# flags say module.  Fixtures (_FIXTURE in the name) are not tests.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "readdir.m";
	readdir: Readdir;

include "jslex.m";
	jslex: Jslex;

include "jsparse.m";
	jsparse: Jsparse;

include "web/dom.m";
include "js.m";

T262: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Stat: adt {
	name:	string;
	pass, fail:	int;
};

stats: list of ref Stat;
featfail: list of ref Stat;
failfd: ref Sys->FD;
verbose := 0;
showpaths := 0;	# each test's path before it runs: which one took the emulator down
runmode := 0;
timeout := 10000;
gcevery := 0;	# -g n: collect after every n objects made
lazymin := -1;	# -L n: compile functions lazily in sources this long
npass := 0;
nfail := 0;
nskip := 0;

# proposals no browser ships: not tests of this parser
skipped := array[] of {
	"decorators",
	"import-defer",
	"source-phase-imports",
	"source-phase-imports-module-source",
	"Temporal",
	"ShadowRealm",
	"joint-iteration",
	"iterator-chunking",
	"iterator-includes",
	"Iterator.prototype.join",
	"import-bytes",
	"await-dictionary",
	"error-stack-accessor",
	"immutable-arraybuffer",
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	readdir = load Readdir Readdir->PATH;
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	if(jsparse == nil) {
		sys->fprint(sys->fildes(2), "t262: cannot load %s: %r\n", Jsparse->PATH);
		raise "fail:load";
	}
	jsparse->init();
	args = tl args;
	for(; args != nil && len hd args > 1 && (hd args)[0] == '-'; args = tl args)
		case hd args {
		"-v" =>
			verbose = 1;
		"-p" =>
			showpaths = 1;
		"-r" =>
			runmode = 1;
		"-t" =>
			args = tl args;
			timeout = int hd args;
		"-g" =>
			args = tl args;
			gcevery = int hd args;
		"-L" =>
			args = tl args;
			lazymin = int hd args;
		"-f" =>
			args = tl args;
			failfd = sys->create(hd args, Sys->OWRITE, 8r644);
		}
	for(; args != nil; args = tl args)
		walk(hd args, hd args);
	for(l := revstats(stats); l != nil; l = tl l) {
		s := hd l;
		sys->print("%-60s %5d %5d  %5.1f%%\n", s.name, s.pass, s.fail, 100.0 * real s.pass / real (s.pass + s.fail));
	}
	if(featfail != nil) {
		sys->print("\nfailures by feature:\n");
		for(l = revstats(featfail); l != nil; l = tl l)
			sys->print("  %-40s %5d\n", (hd l).name, (hd l).fail);
	}
	sys->print("\ntotal %d passed, %d failed (%.1f%%), %d skipped\n", npass, nfail, 100.0 * real npass / real (npass + nfail), nskip);
}

revstats(l: list of ref Stat): list of ref Stat
{
	r: list of ref Stat;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

walk(path, top: string)
{
	(d, n) := readdir->init(path, Readdir->NAME);
	if(n < 0) {
		if(suffix(path, ".js"))
			test(path, top);
		return;
	}
	for(i := 0; i < n; i++) {
		p := path + "/" + d[i].name;
		if(d[i].mode & Sys->DMDIR)
			walk(p, top);
		else if(suffix(p, ".js") && !contains(d[i].name, "_FIXTURE"))
			test(p, top);
	}
}

suffix(s, x: string): int
{
	return len s >= len x && s[len s - len x:] == x;
}

contains(s, x: string): int
{
	for(i := 0; i + len x <= len s; i++)
		if(s[i:i+len x] == x)
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

# the front matter's text between /*--- and ---*/
frontmatter(src: string): string
{
	for(i := 0; i + 5 <= len src; i++)
		if(src[i:i+5] == "/*---") {
			for(j := i + 5; j + 5 <= len src; j++)
				if(src[j:j+5] == "---*/")
					return src[i+5:j];
			return src[i+5:];
		}
	return nil;
}

lines(s: string): list of string
{
	l: list of string;
	st := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == '\n') {
			l = s[st:i] :: l;
			st = i + 1;
		}
	l = s[st:] :: l;
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r'))
		j--;
	return s[i:j];
}

# the words of a [a, b, c] list, or the - items that follow a key
words(s: string): list of string
{
	s = trim(s);
	if(len s > 0 && s[0] == '[')
		s = s[1:];
	if(len s > 0 && s[len s - 1] == ']')
		s = s[0:len s - 1];
	l: list of string;
	st := 0;
	for(i := 0; i <= len s; i++)
		if(i == len s || s[i] == ',') {
			w := trim(s[st:i]);
			if(w != nil)
				l = w :: l;
			st = i + 1;
		}
	return l;
}

Meta: adt {
	negparse:	int;
	negphase:	string;
	negtype:	string;
	flags:	list of string;
	features:	list of string;
	includes:	list of string;
};

meta(src: string): ref Meta
{
	m := ref Meta(0, nil, nil, nil, nil, nil);
	fm := frontmatter(src);
	key := "";
	innegative := 0;
	for(l := lines(fm); l != nil; l = tl l) {
		ln := hd l;
		t := trim(ln);
		if(t == nil)
			continue;
		indented := ln[0] == ' ' || ln[0] == '\t';
		if(!indented) {
			innegative = 0;
			key = "";
			for(i := 0; i < len t; i++)
				if(t[i] == ':') {
					key = t[0:i];
					v := trim(t[i+1:]);
					case key {
					"negative" =>
						innegative = 1;
					"flags" =>
						m.flags = words(v);
					"features" =>
						m.features = words(v);
					"includes" =>
						m.includes = words(v);
					}
					break;
				}
			continue;
		}
		if(innegative && len t > 6 && t[0:6] == "phase:") {
			m.negphase = trim(t[6:]);
			if(m.negphase == "parse")
				m.negparse = 1;
		}
		if(innegative && len t > 5 && t[0:5] == "type:")
			m.negtype = trim(t[5:]);
		if(len t > 2 && t[0:2] == "- ") {
			if(key == "features")
				m.features = trim(t[2:]) :: m.features;
			else if(key == "flags")
				m.flags = trim(t[2:]) :: m.flags;
			else if(key == "includes")
				m.includes = trim(t[2:]) :: m.includes;
		}
	}
	return m;
}

has(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

test(path, top: string)
{
	src := readfile(path);
	if(src == nil)
		return;
	m := meta(src);
	for(i := 0; i < len skipped; i++)
		if(has(m.features, skipped[i])) {
			nskip++;
			return;
		}
	ismod := has(m.flags, "module");
	ok := 1;
	why := "";
	if(runmode) {
		if(m.negparse || has(m.features, "cross-realm") || has(m.features, "Atomics") || has(m.features, "SharedArrayBuffer") || has(m.flags, "CanBlockIsTrue")) {
			nskip++;
			return;
		}
		(ok, why) = runtest(path, src, m);
	} else
		(ok, why) = parsetest(src, m, ismod);
	group := groupof(path, top);
	st := stat(group);
	if(ok) {
		st.pass++;
		npass++;
	} else {
		st.fail++;
		nfail++;
		for(f := m.features; f != nil; f = tl f)
			feat(hd f).fail++;
		if(failfd != nil)
			sys->fprint(failfd, "%s: %s\n", path, why);
		if(verbose)
			sys->print("FAIL %s: %s\n", path, why);
	}
}

parsetest(src: string, m: ref Meta, ismod: int): (int, string)
{
	ok := 1;
	why := "";
	variants: list of int;	# 0 sloppy, 1 strict
	if(ismod || has(m.flags, "raw") || has(m.flags, "noStrict"))
		variants = 0 :: nil;
	else if(has(m.flags, "onlyStrict"))
		variants = 1 :: nil;
	else
		variants = 0 :: 1 :: nil;
	for(; variants != nil; variants = tl variants) {
		strict := hd variants;
		s := src;
		if(strict)
			s = "\"use strict\";\n" + src;
		err: string;
		{
			(nil, err) = jsparse->parse(s, ismod, 0);
		} exception e {
		"*" =>
			err = "EXCEPTION " + e;
			ok = 0;
			why = err;
		}
		if(len err > 10 && err[0:10] == "EXCEPTION ") {
			why = sprintv(strict) + err;
			ok = 0;
		} else if(m.negparse && err == nil) {
			ok = 0;
			why = sprintv(strict) + "parsed, should not have";
		} else if(!m.negparse && err != nil) {
			ok = 0;
			why = sprintv(strict) + err;
		}
		if(!ok)
			break;
	}
	return (ok, why);
}

# ---- running ----

harness := array[] of {"sta.js", "assert.js"};
harnesscache: list of (string, string);

harnessfile(dir, name: string): string
{
	for(l := harnesscache; l != nil; l = tl l)
		if((hd l).t0 == name)
			return (hd l).t1;
	s := readfile(dir + "/" + name);
	harnesscache = (name, s) :: harnesscache;
	return s;
}

# the harness directory for a test: .../test/x/y.js -> .../harness
harnessdir(path: string): string
{
	for(i := len path - 6; i >= 0; i--)
		if(path[i:i+6] == "/test/")
			return path[0:i] + "/harness";
	return "harness";
}

output: string;

capture(s: string)
{
	output += s + "\n";
}

curpath: string;

runtest(path, src: string, m: ref Meta): (int, string)
{
	curpath = path;
	dir := harnessdir(path);
	pre := "";
	if(!has(m.flags, "raw")) {
		for(i := 0; i < len harness; i++)
			pre += harnessfile(dir, harness[i]) + "\n";
		if(has(m.flags, "async"))
			pre += harnessfile(dir, "doneprintHandle.js") + "\n";
		for(l := m.includes; l != nil; l = tl l)
			pre += harnessfile(dir, hd l) + "\n";
	}
	variants: list of int;
	if(has(m.flags, "raw") || has(m.flags, "noStrict") || has(m.flags, "module"))
		variants = 0 :: nil;
	else if(has(m.flags, "onlyStrict"))
		variants = 1 :: nil;
	else
		variants = 0 :: 1 :: nil;
	for(; variants != nil; variants = tl variants) {
		strict := hd variants;
		s := pre + src;
		if(strict)
			s = "\"use strict\";\n" + s;
		(ok, why) := runone(s, m, path);
		if(!ok)
			return (0, sprintv(strict) + why);
	}
	return (1, nil);
}

# run a script in a fresh realm, in a thread of its own, with a time limit
runone(src: string, m: ref Meta, path: string): (int, string)
{
	if(showpaths)
		sys->fprint(sys->fildes(2), "RUN %s\n", path);
	c := chan of (int, string);
	pidc := chan of int;
	spawn runrealm(src, m, path, c, pidc);
	pid := <-pidc;
	tc := chan of int;
	spawn timer(tc, timeout);
	tpid := <-tc;
	alt {
	r := <-c =>
		kill(tpid);
		return r;
	<-tc =>
		kill(pid);
		js = nil;	# its state is the killed thread's: start a new instance
		return (0, "timed out");
	}
}

timer(c: chan of int, ms: int)
{
	c <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

runrealm(src: string, m: ref Meta, nil: string, c: chan of (int, string), pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	r: (int, string);
	{
		r = runrealm1(src, m);
	} exception e {
	"*" =>
		r = (0, "engine broke: " + e);
	}
	c <-= r;
}

js: Js;

runrealm1(src: string, m: ref Meta): (int, string)
{
	if(js == nil)
		js = load Js Js->PATH;
	if(js == nil)
		return (0, sys->sprint("cannot load %s: %r", Js->PATH));
	err := js->init();
	if(err != nil)
		return (0, err);
	output = "";
	js->setoutput(capture);
	js->test262();
	if(gcevery > 0)
		js->stress(gcevery);
	if(lazymin >= 0)
		js->lazy(lazymin);
	e: string;
	if(has(m.flags, "module"))
		(nil, e) = js->evalmodule(src, curpath);
	else
		(nil, e) = js->evalscript(src, curpath);
	js->shutdown();
	if(m.negphase == "runtime" || m.negphase == "resolution") {
		if(e == nil)
			return (0, "ran, should have thrown " + m.negtype);
		if(len e < len m.negtype || e[0:len m.negtype] != m.negtype)
			return (0, "threw " + e + ", not " + m.negtype);
		return (1, nil);
	}
	if(e != nil)
		return (0, e);
	if(has(m.flags, "async")) {
		if(contains(output, "Test262:AsyncTestComplete"))
			return (1, nil);
		if(contains(output, "Test262:AsyncTestFailure"))
			return (0, oneline(output));
		return (0, "async test did not complete");
	}
	return (1, nil);
}

oneline(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			return s[0:i];
	return s;
}

sprintv(strict: int): string
{
	if(strict)
		return "[strict] ";
	return "";
}

# the directory two below top: language/expressions/class, say
groupof(path, top: string): string
{
	r := path[len top:];
	if(len r > 0 && r[0] == '/')
		r = r[1:];
	n := 0;
	for(i := 0; i < len r; i++)
		if(r[i] == '/') {
			n++;
			if(n == 2)
				return r[0:i];
		}
	for(i = len r - 1; i >= 0; i--)
		if(r[i] == '/')
			return r[0:i];
	return ".";
}

stat(name: string): ref Stat
{
	for(l := stats; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	s := ref Stat(name, 0, 0);
	stats = s :: stats;
	return s;
}

feat(name: string): ref Stat
{
	for(l := featfail; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	s := ref Stat(name, 0, 0);
	featfail = s :: featfail;
	return s;
}
