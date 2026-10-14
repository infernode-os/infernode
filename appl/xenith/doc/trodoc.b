implement Docengine;

#
# trodoc - troff for Xenith's document view (docengine(2)).
#
# Two kinds of document: troff's output (troff(6)), shown as it is,
# and troff's input (a .ms or .man file and the like), set by troff(1)
# and shown beside its text. A sheet a page, at scale 100 in points,
# painted by troffpage(2) with the device's outline fonts: sharp at
# any zoom.
#
# Input is set with the macro package its name says (.ms -ms, .man
# -man, .me -me, .mm -m), troff run in the file's directory so that
# .so finds what it names.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "sh.m";

include "troffpage.m";
	troffpage: Troffpage;
	Doc: import troffpage;

include "docengine.m";

MAXREAD: con 64*1024*1024;
TROFF: con "/dis/troff.dis";

State: adt {
	doc:	ref Doc;
	source:	int;		# set from troff's input
	text:	array of string;	# each page's text, once asked for
	runs:	array of array of Run;
	links:	array of array of Link;
};

display: ref Display;
docs: array of ref State;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	display = d;
	return nil;
}

loadpage(): string
{
	if(troffpage != nil)
		return nil;
	t := load Troffpage Troffpage->PATH;
	if(t == nil)
		return sys->sprint("cannot load %s: %r", Troffpage->PATH);
	if((err := t->init(display)) != nil)
		return err;
	troffpage = t;
	return nil;
}

open(data: array of byte, name: string, nil: ref Style): (int, string)
{
	if((err := loadpage()) != nil)
		return (-1, err);
	if(data == nil && (data = readfile(name)) == nil)
		return (-1, sys->sprint("cannot read %s: %r", name));
	source := 0;
	if(!troffpage->istroff(data)){
		source = 1;
		msgs: string;
		(data, msgs) = settroff(data, name);
		if(data == nil || !troffpage->istroff(data)){
			if(msgs == nil)
				msgs = "troff wrote nothing";
			return (-1, "troff: " + msgs);
		}
	}
	(doc, e) := troffpage->open(data, nil);
	if(doc == nil)
		return (-1, "troff: " + e);
	if(doc.npages == 0)
		return (-1, "troff: no pages");
	n := doc.npages;
	return (add(ref State(doc, source, array[n] of string, array[n] of array of Run, array[n] of array of Link)), nil);
}

# the macro package for a file of troff input, by its name
macros(name: string): list of string
{
	ext := "";
	for(i := len name - 1; i >= 0 && name[i] != '/'; i--)
		if(name[i] == '.'){
			ext = name[i:];
			break;
		}
	case ext {
	".ms" =>
		return "-ms" :: nil;
	".man" =>
		return "-man" :: nil;
	".me" =>
		return "-me" :: nil;
	".mm" =>
		return "-m" :: nil;
	}
	return nil;
}

dirname(name: string): string
{
	for(i := len name - 1; i >= 0; i--)
		if(name[i] == '/'){
			if(i == 0)
				return "/";
			return name[0:i];
		}
	return ".";
}

# set troff's input data, named name; its output, and what it said on its standard error
settroff(data: array of byte, name: string): (array of byte, string)
{
	inp := array[2] of ref Sys->FD;
	outp := array[2] of ref Sys->FD;
	errp := array[2] of ref Sys->FD;
	if(sys->pipe(inp) < 0 || sys->pipe(outp) < 0 || sys->pipe(errp) < 0)
		return (nil, sys->sprint("cannot make pipes: %r"));
	args := "troff" :: macros(name);
	sync := chan of int;
	spawn runtroff(args, dirname(name), inp[0], outp[1], errp[1], sync);
	<-sync;
	inp[0] = outp[1] = errp[1] = nil;
	spawn feed(inp[1], data);
	inp[1] = nil;
	errc := chan of string;
	spawn drain(errp[0], errc);
	errp[0] = nil;
	out := readall(outp[0]);
	msgs := <-errc;
	return (out, msgs);
}

runtroff(args: list of string, dir: string, in, out, err: ref Sys->FD, sync: chan of int)
{
	sys->pctl(Sys->NEWFD|Sys->FORKNS, in.fd :: out.fd :: err.fd :: nil);
	sys->dup(in.fd, 0);
	sys->dup(out.fd, 1);
	sys->dup(err.fd, 2);
	in = out = err = nil;
	sys->chdir(dir);
	sync <-= 1;
	t := load Command TROFF;
	if(t == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", TROFF);
		return;
	}
	{
		t->init(nil, args);
	} exception {
	"fail:*" =>
		;
	}
}

feed(fd: ref Sys->FD, data: array of byte)
{
	for(i := 0; i < len data; ){
		n := len data - i;
		if(n > Sys->ATOMICIO)
			n = Sys->ATOMICIO;
		if(sys->write(fd, data[i:i+n], n) != n)
			break;
		i += n;
	}
}

drain(fd: ref Sys->FD, c: chan of string)
{
	c <-= string readall(fd);
}

readall(fd: ref Sys->FD): array of byte
{
	b := array[64*1024] of byte;
	n := 0;
	for(;;){
		if(n == len b){
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		m := sys->read(fd, b[n:], len b - n);
		if(m <= 0)
			break;
		n += m;
	}
	return b[0:n];
}

close(h: int)
{
	if((s := get(h)) != nil)
		s.doc.close();
	if(h >= 0 && h < len docs)
		docs[h] = nil;
}

nsheets(h: int): int
{
	if((s := get(h)) == nil)
		return 0;
	return s.doc.npages;
}

sheetsize(h: int, n: int): Point
{
	s := get(h);
	if(s == nil || n < 0 || n >= s.doc.npages)
		return Point(0, 0);
	return Point(s.doc.width, s.doc.height);
}

restyle(nil: int, nil: ref Style): string
{
	return nil;
}

scalable(nil: int): int
{
	return 1;
}

paint(h: int, n: int, scale: int, dst: ref Image, r: Rect, org: Point): string
{
	s := get(h);
	if(s == nil || n < 0 || n >= s.doc.npages)
		return "no such page";
	return s.doc.paint(n, real scale / 100.0, dst, r, org);
}

text(h: int): string
{
	s := get(h);
	if(s == nil)
		return nil;
	t := "";
	for(n := 0; n < s.doc.npages; n++){
		if(n > 0)
			t += "\n\n--- Page " + string (n+1) + " ---\n\n";
		t += sheettext(h, n);
	}
	return t;
}

sheettext(h: int, n: int): string
{
	s := get(h);
	if(s == nil || n < 0 || n >= s.doc.npages)
		return nil;
	if(s.text[n] == nil)
		s.text[n] = s.doc.text(n);
	return s.text[n];
}

runs(h: int, n: int): array of Run
{
	s := get(h);
	if(s == nil || n < 0 || n >= s.doc.npages)
		return nil;
	if(s.runs[n] == nil){
		w := s.doc.words(n);
		a := array[len w] of Run;
		for(i := 0; i < len w; i++)
			a[i] = Run(w[i].text, w[i].r);
		s.runs[n] = a;
	}
	return s.runs[n];
}

links(h: int): array of Link
{
	s := get(h);
	if(s == nil)
		return nil;
	l: list of Link;
	k := 0;
	for(n := s.doc.npages - 1; n >= 0; n--){
		a := pagelinks(s, n);
		for(i := len a - 1; i >= 0; i--){
			l = a[i] :: l;
			k++;
		}
	}
	r := array[k] of Link;
	for(i := 0; l != nil; l = tl l)
		r[i++] = hd l;
	return r;
}

linkat(h: int, n: int, p: Point): string
{
	s := get(h);
	if(s == nil || n < 0 || n >= s.doc.npages)
		return nil;
	a := pagelinks(s, n);
	for(i := len a - 1; i >= 0; i--)
		if(p.in(a[i].r))
			return a[i].url;
	return nil;
}

pagelinks(s: ref State, n: int): array of Link
{
	if(s.links[n] == nil){
		l := s.doc.links(n);
		a := array[len l] of Link;
		for(i := 0; i < len l; i++)
			a[i] = Link(n, l[i].r, l[i].url);
		s.links[n] = a;
	}
	return s.links[n];
}

lineto(nil: int, nil: int): (int, int)
{
	return (0, 0);
}

lineat(nil: int, nil: int, nil: int): int
{
	return 0;
}

commands(nil: int): list of string
{
	return nil;
}

command(nil: int, cmd, nil: string): string
{
	return "unknown command " + cmd;
}

events(nil: int): chan of string
{
	return nil;
}

name(nil: int): string
{
	return nil;
}

click(nil: int, nil: int, nil: Point): string
{
	return nil;
}

key(nil: int, nil: int): string
{
	return nil;
}

files(nil: int): string
{
	return nil;
}

add(s: ref State): int
{
	for(i := 0; i < len docs; i++)
		if(docs[i] == nil){
			docs[i] = s;
			return i;
		}
	n := array[len docs + 4] of ref State;
	n[0:] = docs;
	n[len docs] = s;
	h := len docs;
	docs = n;
	return h;
}

get(h: int): ref State
{
	d := docs;
	if(h < 0 || h >= len d)
		return nil;
	return d[h];
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, dir) := sys->fstat(fd);
	if(ok != 0 || dir.length <= big 0 || dir.length > big MAXREAD)
		return nil;
	n := int dir.length;
	b := array[n] of byte;
	for(t := 0; t < n; ){
		m := sys->read(fd, b[t:], n - t);
		if(m <= 0)
			return nil;
		t += m;
	}
	return b;
}
