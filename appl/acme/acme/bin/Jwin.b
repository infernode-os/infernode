implement Jwin;

#
# Jwin - an Acme window run by a script.
#
#	Jwin [-f file|url] [source]
#
# The script sees two objects: System (getline, print, readUrl,
# postUrl) and Acmewin (writebody, read, name, tagwrite, clean,
# setaddr, replace, select, readall).  A command executed in the window
# goes to Acmewin.onexec(cmd, arg), a look to Acmewin.onlook(text);
# either returning anything but false means the script took it.
#

include "sys.m";
	sys: Sys;
	print, fprint, fildes, pctl, open, OWRITE: import sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "arg.m";
	arg: Arg;
include "acmewin.m";
	win: Acmewin;
	Win, Event: import win;
include "string.m";
	str: String;
include "web/dom.m";
include "js.m";
	js: Js;
include "jslex.m";
	jslex: Jslex;
include "jsparse.m";
	jsparse: Jsparse;
include "web.m";
	web: Web;

Jwin: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;
ib, ob: ref Iobuf;
acmewin: ref Win;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	arg = load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	win = load Acmewin Acmewin->PATH;
	win->init();
	str = load String String->PATH;
	web = load Web Web->PATH;
	web->init0();
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	js = load Js Js->PATH;
	stderr = fildes(2);
	if(js == nil || jslex == nil || jsparse == nil) {
		fprint(stderr, "Jwin: cannot load the script engine: %r\n");
		raise "fail:load";
	}
	jslex->init();
	jsparse->init();
	if((err := js->init()) != nil) {
		fprint(stderr, "Jwin: %s\n", err);
		raise "fail:init";
	}
	ib = bufio->fopen(fildes(0), Bufio->OREAD);
	ob = bufio->fopen(fildes(1), Bufio->OWRITE);
	arg->init(args);
	file: string;
	while((c := arg->opt()) != 0)
		case c {
		'f' =>
			file = arg->earg();
		* =>
			fprint(stderr, "usage: Jwin [-f file|url] [source]\n");
			raise "fail:usage";
		}
	args = arg->argv();
	code: string;
	if(file != nil && len file >= 5 && (file[0:5] == "http:" || file[0:5] == "file:"))
		code = string web->readurl(file);
	else if(file != nil)
		code = readfile(file);
	else if(args != nil)
		code = hd args;
	js->deffn("System.getline", sys_getline);
	js->deffn("System.print", sys_print);
	js->deffn("System.readUrl", sys_readurl);
	js->deffn("System.postUrl", sys_posturl);
	js->deffn("Acmewin.writebody", w_writebody);
	js->deffn("Acmewin.read", w_read);
	js->deffn("Acmewin.name", w_name);
	js->deffn("Acmewin.tagwrite", w_tagwrite);
	js->deffn("Acmewin.clean", w_clean);
	js->deffn("Acmewin.setaddr", w_setaddr);
	js->deffn("Acmewin.replace", w_replace);
	js->deffn("Acmewin.select", w_select);
	js->deffn("Acmewin.readall", w_readall);
	{
		acmewin = w := Win.wnew();
		w.wname("Jwin");
		(nil, err) := js->evalscript(jslex->utf16(array of byte code), "Jwin");
		ob.flush();
		if(err != nil)
			fprint(stderr, "Jwin: %s\n", err);
		spawn mainwin(w);
	} exception e {
	"*" =>
		postnote(1, pctl(0, nil), "kill");
		fprint(stderr, "Jwin: %s\n", e);
	}
}

arg0(a: array of string, i: int): string
{
	if(i < len a)
		return a[i];
	return "";
}

cat(a: array of string): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += a[i];
	return s;
}

sys_getline(nil: array of string): string
{
	return ib.gets('\n');
}

sys_print(a: array of string): string
{
	ob.puts(cat(a));
	ob.flush();
	return "";
}

sys_readurl(a: array of string): string
{
	return string web->readurl(cat(a));
}

sys_posturl(a: array of string): string
{
	return string web->posturl(arg0(a, 0), arg0(a, 1));
}

w_writebody(a: array of string): string
{
	acmewin.wwritebody(cat(a));
	return "";
}

w_read(a: array of string): string
{
	return acmewin.wread(int arg0(a, 0), int arg0(a, 1));
}

w_name(a: array of string): string
{
	acmewin.wname(arg0(a, 0));
	return "";
}

w_tagwrite(a: array of string): string
{
	acmewin.wtagwrite(arg0(a, 0));
	return "";
}

w_clean(nil: array of string): string
{
	acmewin.wclean();
	return "";
}

w_setaddr(a: array of string): string
{
	return string acmewin.wsetaddr(arg0(a, 0), 1);
}

w_replace(a: array of string): string
{
	acmewin.wreplace(arg0(a, 0), arg0(a, 1));
	return "";
}

w_select(a: array of string): string
{
	acmewin.wselect(arg0(a, 0));
	return "";
}

w_readall(nil: array of string): string
{
	return acmewin.wreadall();
}

postnote(t: int, pid: int, note: string): int
{
	fd := open("#p/" + string pid + "/ctl", OWRITE);
	if(fd == nil)
		return -1;
	if(t == 1)
		note += "grp";
	fprint(fd, "%s", note);
	return 0;
}

# what the script's handler said: anything but false takes the event
taken(r: string, err: string): int
{
	if(err != nil) {
		fprint(stderr, "Jwin: %s\n", err);
		return 0;
	}
	return r != nil && r != "false";
}

doexec(cmd: string): int
{
	cmd = skip(cmd, "");
	a: string;
	(cmd, a) = str->splitl(cmd, " \t\r\n");
	if(a != nil)
		a = skip(a, "");
	case cmd {
	"Del" or "Delete" =>
		return -1;
	}
	(r, err) := js->callfn("Acmewin.onexec", array[] of {cmd, a});
	return taken(r, err);
}

dolook(s: string): int
{
	(r, err) := js->callfn("Acmewin.onlook", array[] of {s});
	return taken(r, err);
}

skip(s, cmd: string): string
{
	s = s[len cmd:];
	while(s != nil && (s[0] == ' ' || s[0] == '\t' || s[0] == '\n'))
		s = s[1:];
	return s;
}

mainwin(w: ref Win)
{
	c := chan of Event;
	na: int;
	ea: Event;
	s: string;
	{
		spawn w.wslave(c);
	loop:	for(;;) {
			e := <-c;
			if(e.c1 != 'M')
				continue;
			case e.c2 {
			'x' or 'X' =>
				eq := e;
				if(e.flag & 2)
					eq = <-c;
				if(e.flag & 8) {
					ea = <-c;
					na = ea.nb;
					<-c;	# toss
				} else
					na = 0;
				if(eq.q1 > eq.q0 && eq.nb == 0)
					s = w.wread(eq.q0, eq.q1);
				else
					s = string eq.b[0:eq.nb];
				if(na)
					s += " " + string ea.b[0:ea.nb];
				n := doexec(s);
				if(n == 0)
					w.wwriteevent(ref e);
				else if(n < 0)
					break loop;
			'l' or 'L' =>
				eq := e;
				if(e.flag & 2)
					eq = <-c;
				s = string eq.b[0:eq.nb];
				if(eq.q1 > eq.q0 && eq.nb == 0)
					s = w.wread(eq.q0, eq.q1);
				if(dolook(s) == 0)
					w.wwriteevent(ref e);
			}
		}
		postnote(1, pctl(0, nil), "kill");
		w.wdel(1);
		exit;
	} exception e {
	"*" =>
		postnote(1, pctl(0, nil), "kill");
		w.wdel(1);
		fprint(stderr, "Jwin: %s\n", e);
	}
}

readfile(f: string): string
{
	fd := bufio->open(f, Bufio->OREAD);
	if(fd == nil)
		return nil;
	r: string;
	while((s := fd.gets('\n')) != nil)
		r += s;
	return r;
}
