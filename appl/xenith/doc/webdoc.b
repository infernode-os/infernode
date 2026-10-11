implement Docengine;

#
# webdoc - HTML for Xenith's document view (docengine(2)): an HTML
# file's text set as a page, and pages browsed.
#
# One flowing sheet: the page laid out by Charon's engine through
# htmldoc, to the style's width, the part in view painted as it
# scrolls. htmldoc, and Charon's engine with it, is loaded with the
# first HTML document, and only for HTML; browser windows and HTML
# files share it.
#
# A page browsed changes by itself (events), takes clicks (links,
# buttons, boxes) and, in a form field it has given the keyboard to,
# keys: text keys and Backspace edit the field, ^U empties it, Return
# submits its form (a newline in a textarea), Tab goes to the next
# field typed into, Esc lets the keyboard go; in a select, Up and Down
# choose the option before and after, a letter the next whose label
# starts with it, a click the next. The field with the keyboard is
# ringed in the style's accent.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "keyboard.m";

include "htmldoc.m";
	htmldoc: Htmldoc;
	Field: import htmldoc;

include "docengine.m";

State: adt {
	data:	array of byte;	# an HTML file's text; nil for a page browsed
	url:	string;
	width:	int;
	height:	int;		# the page's, laid out
	browsing:	int;
	ev:	chan of string;	# a page browsed's events, for the view
	field:	int;		# the form field with the keyboard (its node), or 0
	accent:	ref Image;
};

VIEWH: con 600;

display: ref Display;
docs: array of ref State;

init(d: ref Display): string
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	display = d;
	return nil;
}

loadhtmldoc(): string
{
	if(htmldoc != nil)
		return nil;
	h := load Htmldoc Htmldoc->PATH;
	if(h == nil)
		return sys->sprint("cannot load %s: %r", Htmldoc->PATH);
	if((err := h->init(display)) != nil)
		return err;
	htmldoc = h;
	return nil;
}

isurl(s: string): int
{
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c == ':')
			return i > 1 && i+2 < len s && s[i+1] == '/' && s[i+2] == '/';
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '+' || c == '-' || c == '.'))
			return 0;
	}
	return 0;
}

open(data: array of byte, name: string, st: ref Style): (int, string)
{
	if((err := loadhtmldoc()) != nil)
		return (-1, err);
	width := 800;
	accent: ref Image;
	if(st != nil){
		if(st.width > 0)
			width = st.width;
		accent = st.accent;
		if(accent == nil)
			accent = st.fg;
	}
	if(accent == nil)
		accent = display.color(Draw->Blue);
	s := ref State(data, name, width, 0, 0, nil, 0, accent);
	h := add(s);
	if(data == nil && isurl(name)){
		# browsed: fetched in the background, the events tell
		c: chan of string;
		{
			(c, err) = htmldoc->browse(h, name, width, VIEWH);
		} exception e {
		"*" =>
			err = "html: " + e;
		}
		if(err != nil){
			docs[h] = nil;
			return (-1, err);
		}
		s.browsing = 1;
		s.ev = chan of string;
		spawn relay(h, c, s.ev);
		return (h, nil);
	}
	if(data == nil && (data = readfile(name)) == nil){
		docs[h] = nil;
		return (-1, sys->sprint("cannot read %s: %r", name));
	}
	s.data = data;
	if(len name > 0 && name[0] == '/')
		s.url = "file://" + name;
	ht: int;
	{
		(ht, err) = htmldoc->set(h, data, s.url, width, VIEWH);
	} exception e {
	"*" =>
		err = "html: " + e;
	}
	if(err != nil){
		docs[h] = nil;
		return (-1, "html: " + err);
	}
	s.height = ht;
	return (h, nil);
}

# A page browsed's events, to the view: "done y", y where its last
# navigation asks the view to be; the others as they are
relay(h: int, c, ev: chan of string)
{
	for(;;){
		e := <-c;
		if(e == "gone"){
			alt {
			ev <-= "gone" =>	;
			* =>	;
			}
			return;
		}
		s := get(h);
		if(s == nil)
			continue;
		(verb, nil) := split(e);
		case verb {
		"done" =>
			s.field = 0;
			s.height = htmldoc->height(h);
			e = "done " + string htmldoc->scroll(h);
		"update" =>
			s.height = htmldoc->height(h);
		"loading" or "stopped" =>
			continue;
		}
		ev <-= e;
	}
}

close(h: int)
{
	if(get(h) != nil && htmldoc != nil)
		htmldoc->drop(h);
	if(h >= 0 && h < len docs)
		docs[h] = nil;
}

nsheets(h: int): int
{
	if(get(h) == nil)
		return 0;
	return 1;
}

sheetsize(h: int, n: int): Point
{
	s := get(h);
	if(s == nil || n != 0)
		return Point(0, 0);
	return Point(s.width, s.height);
}

restyle(h: int, st: ref Style): string
{
	s := get(h);
	if(s == nil)
		return "no document";
	if(st != nil && st.accent != nil)
		s.accent = st.accent;
	if(st == nil || st.width <= 0 || st.width == s.width)
		return nil;
	s.width = st.width;
	htmldoc->resize(h, s.width, VIEWH);
	s.height = htmldoc->height(h);
	return nil;
}

scalable(nil: int): int
{
	return 0;
}

# The page from org down, into r of dst, the field with the keyboard
# ringed
paint(h: int, n: int, nil: int, dst: ref Image, r: Rect, org: Point): string
{
	s := get(h);
	if(s == nil || n != 0)
		return "no such sheet";
	im := display.newimage(Rect((0, 0), (r.dx(), r.dy())), dst.chans, 0, Draw->White);
	if(im == nil)
		return sys->sprint("no image: %r");
	htmldoc->paint(h, im, org.y);
	if(s.field != 0 && (f := focused(h, s)) != nil)
		im.border(f.box.subpt(Point(0, org.y)).inset(-2), 2, s.accent, Point(0, 0));
	dst.draw(r, im, nil, Point(org.x, 0));
	return nil;
}

text(h: int): string
{
	if(get(h) == nil)
		return nil;
	return htmldoc->text(h);
}

sheettext(h: int, n: int): string
{
	if(n != 0)
		return nil;
	return text(h);
}

runs(nil: int, nil: int): array of Run
{
	return nil;
}

links(nil: int): array of Link
{
	return nil;
}

linkat(h: int, n: int, p: Point): string
{
	if(get(h) == nil || n != 0)
		return nil;
	return htmldoc->linkat(h, p.x, p.y);
}

lineto(nil: int, nil: int): (int, int)
{
	return (0, 0);
}

lineat(nil: int, nil: int, nil: int): int
{
	return 0;
}

commands(h: int): list of string
{
	s := get(h);
	if(s == nil || !s.browsing)
		return nil;
	return "Back" :: "Fwd" :: "Reload" :: nil;
}

command(h: int, cmd, arg: string): string
{
	s := get(h);
	if(s == nil)
		return "no document";
	if(!s.browsing)
		return "unknown command " + cmd;
	case cmd {
	"Back" =>	return htmldoc->back(h);
	"Fwd" =>	return htmldoc->forward(h);
	"Reload" or "Get" =>	return htmldoc->reload(h);
	"Stop" =>	return htmldoc->stop(h);
	"browse" =>
		(nil, err) := htmldoc->browse(h, arg, s.width, VIEWH);
		return err;
	}
	return "unknown command " + cmd;
}

events(h: int): chan of string
{
	if((s := get(h)) == nil)
		return nil;
	return s.ev;
}

name(h: int): string
{
	s := get(h);
	if(s == nil || !s.browsing)
		return nil;
	return htmldoc->url(h);
}

files(h: int): string
{
	s := get(h);
	if(s == nil || !s.browsing)
		return nil;
	return htmldoc->posted(h);
}

# ---- the mouse and the keyboard on a page browsed ----

click(h: int, n: int, p: Point): string
{
	s := get(h);
	if(s == nil || n != 0 || !s.browsing)
		return nil;
	# a field typed into takes the keyboard; a select clicked again
	# takes its next option
	if((f := fieldat(h, p)) != nil){
		if(f.kind == "select" && s.field == f.node){
			select(h, f, 1);
			s.field = f.node;
			s.height = htmldoc->height(h);
			return "layout";
		}
		s.field = f.node;
		return "paint";
	}
	r := "";
	if(s.field != 0){
		s.field = 0;
		r = "paint";
	}
	(hit, err) := htmldoc->click(h, p.x, p.y);
	if(err != nil)
		return "error " + err;
	if(hit)
		return "paint";	# a box checked shows at once
	if(r == "")
		return nil;
	return r;
}

key(h: int, r: int): string
{
	s := get(h);
	if(s == nil || s.field == 0)
		return nil;
	f := focused(h, s);
	if(f == nil){
		s.field = 0;
		return nil;
	}
	case r {
	Keyboard->Esc =>
		s.field = 0;
		return "paint";
	'\t' =>
		# the next field typed into, round to the first
		a := htmldoc->fields(h);
		first, next: ref Field;
		seen := 0;
		for(i := 0; i < len a; i++){
			if(!typedinto(a[i].kind))
				continue;
			if(first == nil)
				first = a[i];
			if(seen && next == nil)
				next = a[i];
			if(a[i].node == f.node)
				seen = 1;
		}
		if(next == nil)
			next = first;
		s.field = next.node;
		return sys->sprint("show %d %d", next.box.min.y, next.box.max.y);
	'\n' =>
		if(f.kind != "textarea"){
			s.field = 0;
			if(f.form == 0)
				return "paint";
			if((err := htmldoc->submit(h, f.form)) != nil)
				return "error " + err;
			return "paint";
		}
	}
	if(f.kind == "select"){
		case r {
		Keyboard->Up =>	select(h, f, -1);
		Keyboard->Down =>	select(h, f, 1);
		* =>
			if(r > ' ' && r < Keyboard->Spec)
				selectletter(h, f, r);
		}
		s.height = htmldoc->height(h);
		return "layout";
	}
	v := f.value;
	case r {
	'\b' =>
		if(len v > 0)
			v = v[0:len v - 1];
	16r15 =>	# ^U
		v = "";
	* =>
		if(r == '\n' || (r >= ' ' && r != 16r7F && r < Keyboard->Spec))
			v[len v] = r;
		else
			return "paint";
	}
	if((err := htmldoc->setfield(h, f.node, v)) != nil)
		return "error " + err;
	s.height = htmldoc->height(h);
	return "layout";
}

typedinto(kind: string): int
{
	case kind {
	"" or "text" or "password" or "search" or "email" or "url" or "tel" or "number" or "textarea" or "select" =>
		return 1;
	}
	return 0;
}

# The field typed into whose box holds p
fieldat(h: int, p: Point): ref Field
{
	f := htmldoc->fields(h);
	for(i := 0; i < len f; i++)
		if(typedinto(f[i].kind) && p.in(f[i].box))
			return f[i];
	return nil;
}

focused(h: int, s: ref State): ref Field
{
	f := htmldoc->fields(h);
	for(i := 0; i < len f; i++)
		if(f[i].node == s.field)
			return f[i];
	return nil;
}

# A select's option by, or the next whose label starts with c
select(h: int, f: ref Field, by: int)
{
	n := len f.options;
	if(n == 0)
		return;
	opts := array[n] of (string, string, int);
	cur := 0;
	i := 0;
	for(l := f.options; l != nil; l = tl l){
		opts[i] = hd l;
		if(opts[i].t2)
			cur = i;
		i++;
	}
	j := cur + by;
	if(j < 0)
		j = 0;
	if(j >= n)
		j = n - 1;
	if(by > 0 && cur == n - 1)
		j = 0;	# a click past the last comes round
	if(j != cur)
		htmldoc->setfield(h, f.node, opts[j].t0);
}

selectletter(h: int, f: ref Field, c: int)
{
	n := len f.options;
	opts := array[n] of (string, string, int);
	cur := 0;
	i := 0;
	for(l := f.options; l != nil; l = tl l){
		opts[i] = hd l;
		if(opts[i].t2)
			cur = i;
		i++;
	}
	c = lower(c);
	for(k := 1; k <= n; k++){
		o := opts[(cur + k) % n];
		if(len o.t1 > 0 && lower(o.t1[0]) == c){
			htmldoc->setfield(h, f.node, o.t0);
			return;
		}
	}
}

lower(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		c += 'a' - 'A';
	return c;
}

split(e: string): (string, string)
{
	for(i := 0; i < len e; i++)
		if(e[i] == ' ')
			return (e[0:i], e[i+1:]);
	return (e, "");
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
	b := array[0] of byte;
	buf := array[65536] of byte;
	while((m := sys->read(fd, buf, len buf)) > 0){
		n := array[len b + m] of byte;
		n[0:] = b;
		n[len b:] = buf[0:m];
		b = n;
	}
	return b;
}
