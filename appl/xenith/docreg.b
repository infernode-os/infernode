implement Docreg;

#
# The kinds of document, from /lib/xenith/doctypes, and their engines,
# loaded on first use (docs/xenith-documents.md).
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Point, Rect: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "docengine.m";

include "docreg.m";

display: ref Display;
kinds: list of ref Kind;

Loaded: adt {
	path:	string;
	mod:	Docengine;
};
engines: list of ref Loaded;
lock: chan of int;

init(d: ref Draw->Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	display = d;
	lock = chan[1] of int;
	kinds = readtable(TABLE);
}

kind(name: string, head: array of byte): ref Kind
{
	ext := extension(name);
	if(ext != nil)
		for(l := kinds; l != nil; l = tl l)
			for(e := (hd l).exts; e != nil; e = tl e)
				if(hd e == ext)
					return hd l;
	if(head != nil)
		for(l = kinds; l != nil; l = tl l)
			for(m := (hd l).magic; m != nil; m = tl m)
				if(begins(head, hd m))
					return hd l;
	return nil;
}

kindof(name: string): ref Kind
{
	for(l := kinds; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

engine(k: ref Kind): (Docengine, string)
{
	if(k == nil)
		return (nil, "no kind");
	lock <-= 1;
	for(l := engines; l != nil; l = tl l)
		if((hd l).path == k.engine){
			<-lock;
			return ((hd l).mod, nil);
		}
	m := load Docengine k.engine;
	if(m == nil){
		err := sys->sprint("cannot load %s: %r", k.engine);
		<-lock;
		return (nil, err);
	}
	if((err := m->init(display)) != nil){
		<-lock;
		return (nil, err);
	}
	engines = ref Loaded(k.engine, m) :: engines;
	<-lock;
	return (m, nil);
}

loaded(): list of string
{
	r: list of string;
	for(l := engines; l != nil; l = tl l)
		r = (hd l).path :: r;
	return r;
}

picture(name: string, data: array of byte, st: ref Docengine->Style): (ref Image, string)
{
	head := data;
	if(len head > 16)
		head = head[0:16];
	k := kind(name, head);
	if(k == nil)
		return (nil, name + ": not a document");
	(e, err) := engine(k);
	if(e == nil)
		return (nil, err);
	h: int;
	(h, err) = e->open(data, name, st);
	if(h < 0)
		return (nil, err);
	im: ref Image;
	{
		sz := e->sheetsize(h, 0);
		if(sz.x <= 0 || sz.y <= 0)
			err = "empty";
		else if((im = display.newimage(Rect((0, 0), sz), Draw->RGB24, 0, Draw->White)) == nil)
			err = sys->sprint("no image: %r");
		else
			err = e->paint(h, 0, 100, im, im.r, Point(0, 0));
	} exception x {
	"*" =>
		err = x;
	}
	e->close(h);
	if(err != nil)
		return (nil, err);
	# a picture made the width asked for; a flowing document was set to it
	if(k.class == Binary && st != nil && st.width > 0 && st.width != im.r.dx()){
		w := st.width;
		h := im.r.dy() * w / im.r.dx();
		if(h < 1)
			h = 1;
		im = scale(im, Point(w, h));
	}
	return (im, nil);
}

# im scaled to sz: each new pixel the average of those it covers (or
# the one it falls in, made larger)
scale(im: ref Image, sz: Point): ref Image
{
	iw := im.r.dx();
	ih := im.r.dy();
	out := display.newimage(Rect((0, 0), sz), Draw->RGB24, 0, Draw->White);
	if(out == nil)
		return im;
	row := array[iw * 3] of byte;
	orow := array[sz.x * 3] of byte;
	acc := array[sz.x * 3] of int;
	cnt := array[sz.x] of int;
	for(oy := 0; oy < sz.y; oy++){
		y0 := oy * ih / sz.y;
		y1 := (oy + 1) * ih / sz.y;
		if(y1 <= y0)
			y1 = y0 + 1;
		for(i := 0; i < len acc; i++)
			acc[i] = 0;
		for(i = 0; i < len cnt; i++)
			cnt[i] = 0;
		for(y := y0; y < y1 && y < ih; y++){
			im.readpixels(Rect((im.r.min.x, im.r.min.y + y), (im.r.max.x, im.r.min.y + y + 1)), row);
			for(ox := 0; ox < sz.x; ox++){
				x0 := ox * iw / sz.x;
				x1 := (ox + 1) * iw / sz.x;
				if(x1 <= x0)
					x1 = x0 + 1;
				for(x := x0; x < x1 && x < iw; x++){
					acc[ox*3] += int row[x*3];
					acc[ox*3+1] += int row[x*3+1];
					acc[ox*3+2] += int row[x*3+2];
					cnt[ox]++;
				}
			}
		}
		for(ox := 0; ox < sz.x; ox++){
			c := cnt[ox];
			if(c < 1)
				c = 1;
			orow[ox*3] = byte (acc[ox*3] / c);
			orow[ox*3+1] = byte (acc[ox*3+1] / c);
			orow[ox*3+2] = byte (acc[ox*3+2] / c);
		}
		out.writepixels(Rect((0, oy), (sz.x, oy + 1)), orow);
	}
	return out;
}

# The extension of a file name, with its dot, in lower case
extension(name: string): string
{
	for(i := len name - 1; i >= 0; i--){
		c := name[i];
		if(c == '/')
			return nil;
		if(c == '.'){
			e := name[i:];
			for(j := 0; j < len e; j++)
				if(e[j] >= 'A' && e[j] <= 'Z')
					e[j] += 'a' - 'A';
			return e;
		}
	}
	return nil;
}

begins(b, m: array of byte): int
{
	if(len b < len m)
		return 0;
	for(i := 0; i < len m; i++)
		if(b[i] != m[i])
			return 0;
	return 1;
}

readtable(path: string): list of ref Kind
{
	r: list of ref Kind;
	if(bufio == nil)
		return nil;
	f := bufio->open(path, Bufio->OREAD);
	if(f == nil)
		return nil;
	while((s := f.gets('\n')) != nil){
		(n, toks) := sys->tokenize(s, " \t\n");
		if(n < 3 || (hd toks)[0] == '#')
			continue;
		k := ref Kind(hd toks, Binary, nil, nil, nil);
		toks = tl toks;
		case hd toks {
		"source" =>	k.class = Source;
		"binary" =>	k.class = Binary;
		* =>	continue;
		}
		toks = tl toks;
		k.engine = hd toks;
		for(toks = tl toks; toks != nil; toks = tl toks){
			t := hd toks;
			if(t[0] == '.')
				k.exts = t :: k.exts;
			else if(len t > 6 && t[0:6] == "magic=")
				k.magic = unescape(t[6:]) :: k.magic;
		}
		r = k :: r;
	}
	# in the table's order
	o: list of ref Kind;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# \xNN in a magic string is the byte NN
unescape(s: string): array of byte
{
	b := array[len s] of byte;
	n := 0;
	for(i := 0; i < len s; i++){
		if(s[i] == '\\' && i+3 < len s && s[i+1] == 'x'){
			b[n++] = byte (hex(s[i+2])<<4 | hex(s[i+3]));
			i += 3;
		}else
			b[n++] = byte s[i];
	}
	return b[0:n];
}

hex(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}
