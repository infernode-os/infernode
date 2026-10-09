implement Windowm;

include "common.m";

sys : Sys;
utils : Utils;
drawm : Draw;
graph : Graph;
gui : Gui;
dat : Dat;
bufferm : Bufferm;
textm : Textm;
filem : Filem;
look : Look;
scrl : Scroll;
xenith : Xenith;
imgload : Imgload;
render : Render;
asyncio : Asyncio;

include "rlayout.m";
	rlayout : Rlayout;
include "htmldoc.m";
include "keyboard.m";
	htmldoc : Htmldoc;

framem : Framem;

sprint : import sys;
FALSE, TRUE, XXX, Astring : import Dat;
Reffont, reffont, Lock, Ref, button, modbutton, mouse, casync : import dat;
Point, Rect, Image, Display, Font, Chans : import drawm;
min, max, error, warning, stralloc, strfree : import utils;
font, draw : import graph;
black, white, mainwin, display : import gui;
Buffer : import bufferm;
Body, Text, Tag : import textm;
File : import filem;
Xfid : import Xfidm;
scrdraw : import scrl;
tagcols, textcols : import xenith;
BACK, HIGH, BORD, TEXT, HTEXT, NCOL : import Framem;
AsyncMsg : import asyncio;

init(mods : ref Dat->Mods)
{
	sys = mods.sys;
	dat = mods.dat;
	utils = mods.utils;
	drawm = mods.draw;
	graph = mods.graph;
	gui = mods.gui;
	textm = mods.textm;
	filem = mods.filem;
	bufferm = mods.bufferm;
	look = mods.look;
	scrl = mods.scroll;
	xenith = mods.xenith;
	framem = mods.framem;

	# Load image loader module
	imgload = load Imgload Imgload->PATH;
	if(imgload != nil)
		imgload->init(display);

	# Load render registry module
	render = load Render Render->PATH;
	if(render != nil)
		render->init(display);

	# Get async I/O module from mods (already initialized by xenith.b)
	asyncio = mods.asyncio;
}

winid : int;
nullwin : Window;

Window.init(w : self ref Window, clone : ref Window, r : Rect)
{
	r1, br : Rect;
	f : ref File;
	rf : ref Reffont;
	rp : ref Astring;
	nc : int;
	dummy : ref File = nil;

	c := w.col;
	*w = nullwin;
	w.col = c;
	w.nopen = array[Dat->QMAX] of byte;
	for (i := 0; i < Dat->QMAX; i++)
		w.nopen[i] = byte 0;
	w.qlock = Lock.init();
	w.ctllock = Lock.init();
	w.refx = Ref.init();
	w.tag = textm->newtext();
	w.tag.w = w;
	w.taglines = 1;
	w.tagexpand = TRUE;
	w.tagsafe = FALSE;
	w.body = textm->newtext();
	w.body.w = w;
	w.id = ++winid;
	w.refx.inc();
	if(dat->globalincref)
		w.refx.inc();
	w.ctlfid = ~0;
	w.zoomscale = 100;
	w.utflastqid = -1;
	r1 = r;
	
	w.tagtop = r;
	w.tagtop.max.y = r.min.y + font.height;
	
	r1.max.y = r1.min.y + font.height;
	reffont.r.inc();
	f = dummy.addtext(w.tag);
	w.tag.init(f, r1, reffont, tagcols);
	w.tag.what = Tag;
	# tag is a copy of the contents, not a tracked image 
	if(clone != nil){
		w.tag.delete(0, w.tag.file.buf.nc, TRUE);
		nc = clone.tag.file.buf.nc;
		rp = utils->stralloc(nc);
		clone.tag.file.buf.read(0, rp, 0, nc);
		w.tag.insert(0, rp.s, nc, TRUE, 0);
		utils->strfree(rp);
		rp = nil;
		w.tag.file.reset();
		w.tag.setselect(nc, nc);
	}
	r1 = r;
	r1.min.y += w.taglines*font.height + 1;
	if(r1.max.y < r1.min.y)
		r1.max.y = r1.min.y;
	f = nil;
	if(clone != nil){
		f = clone.body.file;
		w.body.org = clone.body.org;
		w.isscratch = clone.isscratch;
		rf = Reffont.get(FALSE, FALSE, FALSE, clone.body.reffont.f.name);
	}else
		rf = Reffont.get(FALSE, FALSE, FALSE, nil);
	f = f.addtext(w.body);
	w.body.what = Body;
	w.body.init(f, r1, rf, textcols);
	r1.min.y -= 1;
	r1.max.y = r1.min.y+1;
	draw(mainwin, r1, tagcols[BORD], nil, (0, 0));
	scrdraw(w.body);
	w.r = r;
	w.r.max.y = w.body.frame.r.max.y;
	br.min = w.tag.scrollr.min;
	br.max.x = br.min.x + button.r.dx();
	br.max.y = br.min.y + button.r.dy();
	draw(mainwin, br, button, nil, button.r.min);
	w.filemenu = TRUE;
	w.maxlines = w.body.frame.maxlines;
	w.autoindent = dat->globalautoindent;
	if(clone != nil){
		w.dirty = clone.dirty;
		w.autoindent = clone.autoindent;
		w.body.setselect(clone.body.q0, clone.body.q1);
		w.settag();
	}
}

taglines(w: ref Window, r: Rect): int
{
	if(!w.tagexpand)
		return 1;
	w.tag.frame.noredraw = 1;
	w.tag.reshape(r, TRUE);
	w.tag.frame.noredraw = 0;

	if(w.tag.frame.nlines >= w.tag.frame.maxlines)
		return w.tag.frame.maxlines;
	rune := ref Astring;
	n := w.tag.frame.nlines;
	if(w.tag.file.buf.nc == 0)
		return 1;
	w.tag.file.buf.read(w.tag.file.buf.nc - 1, rune, 0, 1);
	if(rune.s[0] == '\n')
		n++;
	if(n == 0)
		n = 1;
	return n;
}

Window.reshape(w : self ref Window, r : Rect, safe : int, keepextra: int) : int
{
	r1, br : Rect;
	y, oy : int;
	tagresized, mouseintag : int;
	b : ref Image;
	p : Point;

	w.tagtop = r;
	w.tagtop.max.y = r.min.y+font.height;
	
# TAG If necessary, recompute the number of lines that should
# be in the tag;

	r1 = r;
	r1.max.y = min(r.max.y, r1.min.y + w.taglines*font.height);
	y = r1.max.y;
	mouseintag = mouse.xy.in(w.tag.all);
	if(!safe || !w.tagsafe || ! w.tag.all.eq(r1)){
		w.taglines = taglines(w, r);
		w.tagsafe = TRUE;
	}
# END TAG

	r1 = r;
	r1.max.y = min(r.max.y, r1.min.y + w.taglines*font.height);
	y = r1.max.y;
	tagresized = 0;
	if(1|| !safe || !w.tag.frame.r.eq(r1)){
		tagresized = 1;
		w.tag.reshape(r1, TRUE);
		y = w.tag.frame.r.max.y;
		b = button;
		if(w.body.file.mod && !w.isdir && !w.isscratch)
			b = modbutton;
		br.min = w.tag.scrollr.min;
		br.max.x = br.min.x + b.r.dx();
		br.max.y = br.min.y + b.r.dy();
		draw(mainwin, br, b, nil, b.r.min);
# TAG
		if(mouseintag && !mouse.xy.in(w.tag.all)){
			p = mouse.xy;
			p.y = w.tag.all.max.y-3;
			graph->cursorset(p);
		}
# END TAG
	}
	
	r1 = r;
	r1.min.y = y;
	if(tagresized || !safe || !w.body.frame.r.eq(r1)){
		oy = y;
		if(y+1+w.body.frame.font.height <= r.max.y ){ # no body was > r.max.y
			r1.min.y = y;
			r1.max.y = y + 1;
			draw(mainwin, r1, tagcols[BORD], nil, (0, 0));
			y++;
			r1.min.y = min(y, r.max.y);
			r1.max.y = r.max.y;
		}else{
			r1.min.y = y;
			r1.max.y = y;
		}
		w.r = r;
		w.r.max.y = w.body.reshape(r1, keepextra);
		scrdraw(w.body);
		w.body.all.min.y = oy;
	}
	w.maxlines = min(w.body.frame.nlines, max(w.maxlines, w.body.frame.maxlines));

	# If in image mode, redraw the image
	if(w.imagemode && w.bodyimage != nil)
		w.drawimage();

	return w.r.max.y;
}

Window.lock1(w : self ref Window, owner : int)
{
	w.refx.inc();
	w.qlock.lock();
	w.owner = owner;
}

Window.lock(w : self ref Window, owner : int)
{
	i : int;
	f : ref File;

	f = w.body.file;
	for(i=0; i<f.ntext; i++)
		f.text[i].w.lock1(owner);
}

Window.unlock(w : self ref Window)
{
	f : ref File;
	# subtle: loop runs backwards to avoid tripping over
	# winclose indirectly editing f.text and freeing f
	# on the last iteration of the loop

	f = w.body.file;
	for(i:=f.ntext-1; i>=0; i--){
		w = f.text[i].w;
		w.owner = 0;
		w.qlock.unlock();
		w.close();
	}
}

Window.mousebut(w : self ref Window)
{
	graph->cursorset(w.tag.scrollr.min.add(w.tag.scrollr.max).div(2));
}

Window.dirfree(w : self ref Window)
{
	i : int;
	dl : ref Dat->Dirlist;

	if(w.isdir){
		for(i=0; i<w.ndl; i++){
			dl = w.dlp[i];
			dl.r = nil;
			dl = nil;
		}
	}
	w.dlp = nil;
	w.ndl = 0;
}

Window.close(w : self ref Window)
{
	i : int;

	if(w.refx.dec() == 0){
		# Cancel any pending async operations
		if(w.asyncload != nil) {
			asyncio->asynccancel(w.asyncload);
			w.asyncload = nil;
		}
		if(w.asyncsave != nil) {
			asyncio->asynccancel(w.asyncsave);
			w.asyncsave = nil;
		}
		w.dirfree();
		if(w.dochtml && htmldoc != nil)
			htmldoc->drop(w.id);
		w.tag.close();
		w.body.close();
		if(dat->activewin == w)
			dat->activewin = nil;
		for(i=0; i<w.nincl; i++)
			w.incl[i] = nil;
		w.incl = nil;
		w.events = nil;
		w = nil;
	}
}

Window.delete(w : self ref Window)
{
	x : ref Xfid;

	x = w.eventx;
	if(x != nil){
		w.nevents = 0;
		w.events = nil;
		w.eventx = nil;
		x.c <-= Xfidm->Xnil;
	}
}

Window.undo(w : self ref Window, isundo : int)
{
	body : ref Text;
	i : int;
	f : ref File;
	v : ref Window;

	if(w==nil)
		return;
	w.utflastqid = -1;
	body = w.body;
	(body.q0, body.q1) = body.file.undo(isundo, body.q0, body.q1);
	body.show(body.q0, body.q1);
	f = body.file;
	for(i=0; i<f.ntext; i++){
		v = f.text[i].w;
		v.dirty = (f.seq != v.putseq);
		if(v != w){
			v.body.q0 = v.body.frame.p0+v.body.org;
			v.body.q1 = v.body.frame.p1+v.body.org;
		}
	}
	w.settag();
}

Window.setname(w : self ref Window, name : string, n : int)
{
	t : ref Text;
	v : ref Window;
	i : int;

	t = w.body;
	if(t.file.name == name)
		return;
	w.isscratch = FALSE;
	if(n>=6 && name[n-6:n] == "/guide")
		w.isscratch = TRUE;
	else if(n>=7 && name[n-7:n] == "+Errors")
		w.isscratch = TRUE;
	t.file.setname(name, n);
	for(i=0; i<t.file.ntext; i++){
		v = t.file.text[i].w;
		v.settag();
		v.isscratch = w.isscratch;
	}
}

Window.typex(w : self ref Window, t : ref Text, r : int)
{
	i : int;

	t.typex(r, w.echomode);
	if(t.what == Body)
		for(i=0; i<t.file.ntext; i++)
			scrdraw(t.file.text[i]);
	w.settag();
}

Window.cleartag(w : self ref Window)
{
	i, n : int;
	r : ref Astring;

	# w must be committed 
	n = w.tag.file.buf.nc;
	r = utils->stralloc(n);
	w.tag.file.buf.read(0, r, 0, n);
	for(i=0; i<n; i++)
		if(r.s[i]==' ' || r.s[i]=='\t')
			break;
	for(; i<n; i++)
		if(r.s[i] == '|')
			break;
	if(i == n)
		return;
	i++;
	w.tag.delete(i, n, TRUE);
	utils->strfree(r);
	r = nil;
	w.tag.file.mod = FALSE;
	if(w.tag.q0 > i)
		w.tag.q0 = i;
	if(w.tag.q1 > i)
		w.tag.q1 = i;
	w.tag.setselect(w.tag.q0, w.tag.q1);
}

Window.settag(w : self ref Window)
{
	i : int;
	f : ref File;

	f = w.body.file;
	for(i=0; i<f.ntext; i++){
		v := f.text[i].w;
		if(v.col.safe || v.body.frame.maxlines>0)
			v.settag1();
	}
}

Window.settag1(w : self ref Window)
{
	ii, j, k, n, bar, dirty : int;
	old : ref Astring;
	new : string;
	r : int;
	b : ref Image;
	q0, q1 : int;
	br : Rect;

	if(w.tag.ncache!=0 || w.tag.file.mod)
		w.commit(w.tag);	# check file name; also can now modify tag
	old = utils->stralloc(w.tag.file.buf.nc);
	w.tag.file.buf.read(0, old, 0, w.tag.file.buf.nc);
	for(ii=0; ii<w.tag.file.buf.nc; ii++)
		if(old.s[ii]==' ' || old.s[ii]=='\t')
			break;
	if(old.s[0:ii] != w.body.file.name){
		w.tag.delete(0, ii, TRUE);
		w.tag.insert(0, w.body.file.name, len w.body.file.name, TRUE, 0);
		strfree(old);
		old = nil;
		old = utils->stralloc(w.tag.file.buf.nc);
		w.tag.file.buf.read(0, old, 0, w.tag.file.buf.nc);
	}
	new = w.body.file.name + " Del Snarf";
	if(w.filemenu){
		if(w.body.file.delta.nc>0 || w.body.ncache)
			new += " Undo";
		if(w.body.file.epsilon.nc > 0)
			new += " Redo";
		dirty = w.body.file.name != nil && (w.body.ncache || w.body.file.seq!=w.putseq);
		if(!w.isdir && dirty)
			new += " Put";
	}
	if(w.isdir)
		new += " Get";
	if(w.docweb)
		new += " Back Fwd Reload";
	l := len w.body.file.name;
	if(l >= 2 && w.body.file.name[l-2: ] == ".b")
		new += " Limbo";
	if(w.imagemode && w.contentrenderer != nil){
		cmds := w.contentrenderer->commands();
		for(; cmds != nil; cmds = tl cmds)
			new += " " + (hd cmds).name;
	}
	new += " |";
	r = utils->strchr(old.s, '|');
	if(r >= 0)
		k = r+1;
	else{
		k = w.tag.file.buf.nc;
		if(w.body.file.seq == 0)
			new += " Look ";
	}
	resize := 0;
	if(new != old.s[0:k]){
		resize = 1;
		n = k;
		if(n > len new)
			n = len new;
		for(j=0; j<n; j++)
			if(old.s[j] != new[j])
				break;
		q0 = w.tag.q0;
		q1 = w.tag.q1;
		w.tag.delete(j, k, TRUE);
		w.tag.insert(j, new[j:], len new - j, TRUE, 0);
		# try to preserve user selection 
		r = utils->strchr(old.s, '|');
		if(r >= 0){
			bar = r;
			if(q0 > bar){
				bar = utils->strchr(new, '|')-bar;
				w.tag.q0 = q0+bar;
				w.tag.q1 = q1+bar;
			}
		}
	}
	strfree(old);
	old = nil;
	new = nil;
	w.tag.file.mod = FALSE;
	n = w.tag.file.buf.nc+w.tag.ncache;
	if(w.tag.q0 > n)
		w.tag.q0 = n;
	if(w.tag.q1 > n)
		w.tag.q1 = n;
	w.tag.setselect(w.tag.q0, w.tag.q1);
	b = button;
	if(!w.isdir && !w.isscratch && (w.body.file.mod || w.body.ncache))
		b = modbutton;
	br.min = w.tag.scrollr.min;
	br.max.x = br.min.x + b.r.dx();
	br.max.y = br.min.y + b.r.dy();
	draw(mainwin, br, b, nil, b.r.min);
#	if(resize){
#		w.tagsafe = 0;
#		w.reshape(w.r, TRUE, TRUE);
#	}
}

Window.commit(w : self ref Window, t : ref Text)
{
	r : ref Astring;
	i : int;
	f : ref File;

	t.commit(TRUE);
	f = t.file;
	if(f.ntext > 1)
		for(i=0; i<f.ntext; i++)
			f.text[i].commit(FALSE);	# no-op for t 
	if(t.what == Body)
		return;
	r = utils->stralloc(w.tag.file.buf.nc);
	w.tag.file.buf.read(0, r, 0, w.tag.file.buf.nc);
	for(i=0; i<w.tag.file.buf.nc; i++)
		if(r.s[i]==' ' || r.s[i]=='\t')
			break;
	if(r.s[0:i] != w.body.file.name){
		dat->seq++;
		w.body.file.mark();
		w.body.file.mod = TRUE;
		w.dirty = TRUE;
		w.setname(r.s, i);
		w.settag();
	}
	utils->strfree(r);
	r = nil;
}

Window.addincl(w : self ref Window, r : string, n : int)
{
	{
		(ok, d) := sys->stat(r);
		if(ok < 0){
			if(r[0] == '/')
				raise "e";
			(r, n) = look->dirname(w.body, r, n);
			(ok, d) = sys->stat(r);
			if(ok < 0)
				raise "e";
		}
		if((d.mode&Sys->DMDIR) == 0){
			warning(nil, sprint("%s: not a directory\n", r));
			r = nil;
			return;
		}
		w.nincl++;
		owi := w.incl;
		w.incl = array[w.nincl] of string;
		w.incl[1:] = owi[0:w.nincl-1];
		owi = nil;
		w.incl[0] = r;
		r = nil;
	}
	exception{
		* =>
			warning(nil, sprint("%s: %r\n", r));
			r = nil;
	}
}

Window.clean(w : self ref Window, conservative : int, exiting : int) : int	# as it stands, conservative is always TRUE 
{
	if(w.isscratch || w.isdir)	# don't whine if it's a guide file, error window, etc. 
		return TRUE;
	if((!conservative||exiting) && w.nopen[Dat->QWevent]>byte 0)
		return TRUE;
	if(w.dirty){
		if(w.body.file.name != nil)
			warning(nil, sprint("%s modified\n", w.body.file.name));
		else{
			if(w.body.file.buf.nc < 100)	# don't whine if it's too small 
				return TRUE;
			warning(nil, "unnamed file modified\n");
		}
		w.dirty = FALSE;
		return FALSE;
	}
	return TRUE;
}

Window.ctlprint(w : self ref Window, fonts : int) : string
{
	s := sprint("%11d %11d %11d %11d %11d ", w.id, w.tag.file.buf.nc,
			w.body.file.buf.nc, w.isdir, w.dirty);
	if(fonts)
		return sprint("%s%11d %q %11d ", s, w.body.frame.r.dx(), w.body.reffont.f.name,
			w.body.frame.maxtab);
	return s;
}

Window.event(w : self ref Window, fmt : string)
{
	n : int;
	x : ref Xfid;

	if(w.nopen[Dat->QWevent] == byte 0)
		return;
	if(w.owner == 0)
		error("no window owner");
	n = len fmt;
	w.events[len w.events] = w.owner;
	w.events += fmt;
	w.nevents += n+1;
	x = w.eventx;
	if(x != nil){
		w.eventx = nil;
		x.c <-= Xfidm->Xnil;
	}
}

# Parse a hex color string like "#1E1E2E" into RGB values
# Returns (r, g, b, ok) where ok=1 on success, 0 on failure
parsehexrgb(s: string): (int, int, int, int)
{
	if(len s == 0)
		return (0, 0, 0, 0);
	if(s[0] == '#')
		s = s[1:];
	if(len s != 6)
		return (0, 0, 0, 0);

	r, g, b: int;
	for(i := 0; i < 6; i++){
		c := s[i];
		if(c >= '0' && c <= '9')
			c -= '0';
		else if(c >= 'a' && c <= 'f')
			c = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			c = c - 'A' + 10;
		else
			return (0, 0, 0, 0);
		case i {
		0 => r = int c << 4;
		1 => r |= int c;
		2 => g = int c << 4;
		3 => g |= int c;
		4 => b = int c << 4;
		5 => b |= int c;
		}
	}
	return (r, g, b, 1);
}

# Parse a hex color string into an Image
parsehexcolor(s: string): ref Image
{
	(r, g, b, ok) := parsehexrgb(s);
	if(ok == 0)
		return nil;
	return display.rgb(r, g, b);
}

# Return contrasting text color (black or white) for given background RGB
contrastingtext(r, g, b: int): ref Image
{
	# Luminance formula: (0.299*R + 0.587*G + 0.114*B)
	# Scaled to avoid floats, threshold at 128*1000 = 128000
	lum := 299*r + 587*g + 114*b;
	if(lum > 128000)
		return black;
	return white;
}

# Parse a line like "tagbg #1E1E2E" and return (key, color, rawvalue)
parsecolorline(line: string): (string, ref Image, string)
{
	# Skip leading whitespace
	i := 0;
	while(i < len line && (line[i] == ' ' || line[i] == '\t'))
		i++;
	if(i >= len line)
		return (nil, nil, nil);

	# Find end of key
	j := i;
	while(j < len line && line[j] != ' ' && line[j] != '\t')
		j++;
	if(j >= len line)
		return (nil, nil, nil);

	key := line[i:j];

	# Skip whitespace between key and value
	i = j;
	while(i < len line && (line[i] == ' ' || line[i] == '\t'))
		i++;
	if(i >= len line)
		return (nil, nil, nil);

	# Find end of value (stop at newline or end)
	j = i;
	while(j < len line && line[j] != '\n' && line[j] != ' ' && line[j] != '\t')
		j++;

	value := line[i:j];
	col := parsehexcolor(value);

	return (key, col, value);
}

# Apply color overrides from colorstr to a window
Window.applycolors(w: self ref Window)
{
	tc := array[NCOL] of ref Image;
	bc := array[NCOL] of ref Image;

	# Start with global defaults
	for(i := 0; i < NCOL; i++){
		tc[i] = tagcols[i];
		bc[i] = textcols[i];
	}

	# Track what was explicitly set and store RGB for auto-contrast
	tagbg_set := 0;
	tagfg_set := 0;
	bodybg_set := 0;
	bodyfg_set := 0;
	tagbg_r, tagbg_g, tagbg_b: int;
	bodybg_r, bodybg_g, bodybg_b: int;

	# If we have overrides, parse and apply them
	if(w.colorstr != nil){
		s := w.colorstr;
		i := 0;
		while(i < len s){
			# Find end of line
			j := i;
			while(j < len s && s[j] != '\n')
				j++;

			line := s[i:j];
			(key, col, rawval) := parsecolorline(line);

			if(col != nil){
				case key {
				"tagbg" =>
					tc[BACK] = col;
					(tagbg_r, tagbg_g, tagbg_b, tagbg_set) = parsehexrgb(rawval);
				"tagfg" =>
					tc[TEXT] = col;
					tc[HTEXT] = col;
					tagfg_set = 1;
				"taghbg" =>  tc[HIGH] = col;
				"taghfg" =>  tc[HTEXT] = col;
				"tagbord" => tc[BORD] = col;
				"bodybg" =>
					bc[BACK] = col;
					(bodybg_r, bodybg_g, bodybg_b, bodybg_set) = parsehexrgb(rawval);
				"bodyfg" =>
					bc[TEXT] = col;
					bc[HTEXT] = col;
					bodyfg_set = 1;
				"bodyhbg" => bc[HIGH] = col;
				"bodyhfg" => bc[HTEXT] = col;
				"bord" =>    bc[BORD] = col; tc[BORD] = col;
				}
			}

			# Move to next line
			i = j + 1;
		}

		# Auto-apply contrasting text if background set but foreground wasn't
		if(tagbg_set && tagfg_set == 0){
			contrast := contrastingtext(tagbg_r, tagbg_g, tagbg_b);
			tc[TEXT] = contrast;
			tc[HTEXT] = contrast;
		}
		if(bodybg_set && bodyfg_set == 0){
			contrast := contrastingtext(bodybg_r, bodybg_g, bodybg_b);
			bc[TEXT] = contrast;
			bc[HTEXT] = contrast;
		}
	}

	# Apply to tag frame
	for(i = 0; i < NCOL; i++)
		w.tag.frame.cols[i] = tc[i];

	# Apply to body frame
	for(i = 0; i < NCOL; i++)
		w.body.frame.cols[i] = bc[i];

	# Redraw the window
	w.tag.redraw(w.tag.frame.r, w.tag.frame.font, mainwin, -1);
	w.body.redraw(w.body.frame.r, w.body.frame.font, mainwin, -1);
	# Invalidate scrollbar cache to force redraw with new colors
	w.body.lastsr = dat->nullrect;
	scrdraw(w.body);

	# Redraw the button (normal or modified indicator)
	b := button;
	if(!w.isdir && !w.isscratch && (w.body.file.mod || w.body.ncache))
		b = modbutton;
	br := Rect(w.tag.scrollr.min, (w.tag.scrollr.min.x + b.r.dx(), w.tag.scrollr.min.y + b.r.dy()));
	draw(mainwin, br, b, nil, b.r.min);
}

# Load and display an image in the window body (async)
Window.loadimage(w: self ref Window, path: string): string
{
	if(asyncio == nil)
		return "async I/O not available";

	# Show loading indicator
	w.imagepath = path;
	w.imagemode = 1;
	w.imageoffset = Point(0, 0);
	w.bodyimage = nil;
	w.zoomedcache = nil;

	# Draw "Loading..." text with proper theme colors
	r := w.body.frame.r;
	bgcol := w.body.frame.cols[BACK];
	fgcol := w.body.frame.cols[TEXT];
	draw(mainwin, r, bgcol, nil, r.min);
	msg := "Loading...";
	msgpt := r.min.add(Point(10, 10 + font.height));
	mainwin.text(msgpt, fgcol, Point(0, 0), font, msg);

	# Start async file read - result handled in xenith.b mousetask
	asyncio->asyncloadimage(path, w.id);
	return nil;
}

# Load and render content through the renderer pipeline (async)
Window.loadcontent(w: self ref Window, path: string): string
{
	if(asyncio == nil)
		return "async I/O not available";

	# Show loading indicator
	w.imagepath = path;
	w.imagemode = 1;
	w.imageoffset = Point(0, 0);
	w.bodyimage = nil;
	w.zoomedcache = nil;
	w.contentdata = nil;
	w.contentrenderer = nil;

	r := w.body.frame.r;
	bgcol := w.body.frame.cols[BACK];
	fgcol := w.body.frame.cols[TEXT];
	draw(mainwin, r, bgcol, nil, r.min);
	msg := "Loading...";
	msgpt := r.min.add(Point(10, 10 + font.height));
	mainwin.text(msgpt, fgcol, Point(0, 0), font, msg);

	# Start async content load - routed through renderer in xenith.b
	asyncio->asyncloadcontent(path, w.id);
	return nil;
}

# Return to text mode, clearing the image
Window.clearimage(w: self ref Window)
{
	w.imagemode = 0;
	w.bodyimage = nil;
	w.zoomedcache = nil;
	w.imagepath = nil;
	w.contentdata = nil;
	w.contentrenderer = nil;

	# Redraw body text
	w.body.redraw(w.body.frame.r, w.body.frame.font, mainwin, -1);
	scrdraw(w.body);
}

# Return commands available from the active renderer (for context menu)
Window.contentcommands(w: self ref Window): list of ref Renderer->Command
{
	if(w.contentrenderer == nil)
		return nil;
	return w.contentrenderer->commands();
}

# Execute a renderer command on the current content
Window.contentcommand(w: self ref Window, cmd, arg: string): string
{
	if(w.contentrenderer == nil)
		return "no active renderer";
	if(w.contentdata == nil)
		return "no content data";

	bodyw := w.body.all.dx();
	bodyh := w.body.all.dy();
	(im, err) := w.contentrenderer->command(cmd, arg, w.contentdata, w.imagepath, bodyw, bodyh);
	if(err != nil)
		return err;
	if(im != nil) {
		w.bodyimage = im;
		w.zoomedcache = nil;
		w.drawimage();
	}
	return nil;
}

# Async renderer command — serialized: at most one render in flight.
# If already rendering, stores cmd as pending (latest wins).
Window.asynccontentcommand(w: self ref Window, cmd, arg: string)
{
	if(w.contentrenderer == nil || w.contentdata == nil)
		return;
	if(w.rendering){
		w.pendingcmd = cmd;
		return;
	}
	w.rendering = 1;
	w.pendingcmd = nil;
	# Free old images to reduce heap pressure before new render
	w.bodyimage = nil;
	w.zoomedcache = nil;
	spawn asynccmdworker(w.id, w.contentrenderer, cmd, arg,
		w.contentdata, w.imagepath, w.body.all.dx(), w.body.all.dy());
}

asynccmdworker(winid: int, renderer: Renderer, cmd, arg: string,
	data: array of byte, hint: string, bodyw, bodyh: int)
{
	im: ref Image;
	err: string;

	{
		(im, err) = renderer->command(cmd, arg, data, hint, bodyw, bodyh);
	}
	exception {
		* =>
			# Don't call getexc() — can OOM-cascade near heap limit
			err = "render failed";
			im = nil;
	}
	# Free data ref early to reduce heap pressure
	data = nil;

	for(;;) {
		alt {
			casync <-= ref AsyncMsg.ContentDecoded(winid, hint, im, nil, err) => ;
			* =>
				sys->sleep(1);
				continue;
		}
		break;
	}
}

# Scale an image using nearest-neighbor interpolation
# Scale a sub-region of a source image to target dimensions using
# area averaging (box filter). Produces smooth anti-aliased output.
scaleregion(src: ref Image, srcr: Rect, dstw, dsth: int): ref Image
{
	if(src == nil || dstw <= 0 || dsth <= 0)
		return nil;

	srcw := srcr.dx();
	srch := srcr.dy();
	if(srcw <= 0 || srch <= 0)
		return nil;

	# Convert indexed/paletted images to RGB24 before scaling.
	# Averaging CMAP8 indices gives wrong colors; we need to average
	# actual RGB channel values.
	if(!src.chans.eq(Draw->RGB24)){
		rgb := display.newimage(src.r, Draw->RGB24, 0, Draw->Black);
		if(rgb != nil){
			draw(rgb, rgb.r, src, nil, src.r.min);
			src = rgb;
		}
	}

	bpp := src.depth / 8;
	if(bpp < 1) bpp = 1;
	if(bpp > 4) bpp = 4;

	dstr := Rect(Point(0, 0), Point(dstw, dsth));
	dst := display.newimage(dstr, src.chans, 0, Draw->Black);
	if(dst == nil)
		return nil;

	fullroww := src.r.dx();
	srcrowbuf := array[fullroww * bpp] of byte;
	dstrowbuf := array[dstw * bpp] of byte;

	# Accumulators for area averaging (per dest pixel, per channel)
	accum := array[dstw * bpp] of int;
	count := array[dstw] of int;

	for(dy := 0; dy < dsth; dy++){
		# Source row range for this destination row
		sy0 := srcr.min.y + (dy * srch) / dsth;
		sy1 := srcr.min.y + ((dy + 1) * srch) / dsth;
		if(sy1 <= sy0)
			sy1 = sy0 + 1;
		if(sy0 >= src.r.max.y)
			sy0 = src.r.max.y - 1;
		if(sy1 > src.r.max.y)
			sy1 = src.r.max.y;

		# Clear accumulators
		for(i := 0; i < dstw * bpp; i++)
			accum[i] = 0;
		for(i = 0; i < dstw; i++)
			count[i] = 0;

		# Accumulate all source rows in range
		for(sy := sy0; sy < sy1; sy++){
			rdr := Rect(Point(0, sy), Point(fullroww, sy + 1));
			src.readpixels(rdr, srcrowbuf);

			for(dx := 0; dx < dstw; dx++){
				# Source column range for this dest pixel
				sx0 := srcr.min.x + (dx * srcw) / dstw;
				sx1 := srcr.min.x + ((dx + 1) * srcw) / dstw;
				if(sx1 <= sx0)
					sx1 = sx0 + 1;
				if(sx0 >= fullroww)
					sx0 = fullroww - 1;
				if(sx1 > fullroww)
					sx1 = fullroww;

				for(sx := sx0; sx < sx1; sx++){
					for(b := 0; b < bpp; b++)
						accum[dx * bpp + b] += int srcrowbuf[sx * bpp + b];
					count[dx]++;
				}
			}
		}

		# Write averaged values to destination row
		for(dx := 0; dx < dstw; dx++){
			c := count[dx];
			if(c < 1) c = 1;
			for(b := 0; b < bpp; b++)
				dstrowbuf[dx * bpp + b] = byte (accum[dx * bpp + b] / c);
		}

		wr := Rect(Point(0, dy), Point(dstw, dy + 1));
		dst.writepixels(wr, dstrowbuf);
	}

	return dst;
}

# Draw the image in the window body area with zoom support.
# zoomscale 100 = fit-to-window, 200 = 2x magnification, etc.
# Caches the scaled full-page image so that pan/scroll only needs
# a fast draw() blit instead of re-running scaleregion().
Window.drawimage(w: self ref Window)
{
	if(w.bodyimage == nil)
		return;
	if(w.docview){
		drawdoc(w);
		return;
	}

	r := w.body.all;
	draw(mainwin, r, w.body.frame.cols[BACK], nil, Point(0, 0));

	imw := w.bodyimage.r.dx();
	imh := w.bodyimage.r.dy();
	bodyw := r.dx();
	bodyh := r.dy();
	if(imw <= 0 || imh <= 0 || bodyw <= 0 || bodyh <= 0)
		return;

	# Compute fit-to-body scale (fixed point, x1000)
	scalex := (bodyw * 1000) / imw;
	scaley := (bodyh * 1000) / imh;
	fitscale := scalex;
	if(scaley < fitscale)
		fitscale = scaley;

	# Apply zoom (zoomscale is percentage: 100 = fit, 200 = 2x)
	zoom := w.zoomscale;
	if(zoom < 100)
		zoom = 100;

	# Virtual display dimensions (how large the image would appear)
	dispw := (imw * fitscale * zoom) / (1000 * 100);
	disph := (imh * fitscale * zoom) / (1000 * 100);
	if(dispw < 1) dispw = 1;
	if(disph < 1) disph = 1;

	# Cap for memory safety (4096×4096×3 = 48MB max)
	if(dispw > 4096) dispw = 4096;
	if(disph > 4096) disph = 4096;

	# Use cached scaled image if dimensions match; recompute on miss
	scaled := w.zoomedcache;
	if(scaled == nil || scaled.r.dx() != dispw || scaled.r.dy() != disph){
		scaled = scaleregion(w.bodyimage,
			Rect(Point(0, 0), Point(imw, imh)), dispw, disph);
		if(scaled == nil)
			return;
		w.zoomedcache = scaled;
	}

	if(dispw <= bodyw && disph <= bodyh){
		# Image fits in body at this zoom — center and blit
		x := r.min.x + (bodyw - dispw) / 2;
		y := r.min.y + (bodyh - disph) / 2;
		dst := Rect(Point(x, y), Point(x + dispw, y + disph));
		draw(mainwin, dst, scaled, nil, scaled.r.min);
	} else {
		# Zoomed in — blit viewport from cached full-page
		# Clamp imageoffset in source coordinates
		vpw := (bodyw * imw) / dispw;
		vph := (bodyh * imh) / disph;
		if(vpw > imw) vpw = imw;
		if(vph > imh) vph = imh;

		maxox := imw - vpw;
		maxoy := imh - vph;
		if(maxox < 0) maxox = 0;
		if(maxoy < 0) maxoy = 0;
		ox := w.imageoffset.x;
		oy := w.imageoffset.y;
		if(ox < 0) ox = 0;
		if(oy < 0) oy = 0;
		if(ox > maxox) ox = maxox;
		if(oy > maxoy) oy = maxoy;
		w.imageoffset = Point(ox, oy);

		# Convert source offset to cache coordinates and blit
		cox := (ox * dispw) / imw;
		coy := (oy * disph) / imh;
		draw(mainwin, r, scaled, nil, Point(scaled.r.min.x + cox, scaled.r.min.y + coy));
	}
}

# Pre-render full page at current zoom level for drag panning.
# Returns a scaled image of size dispw x disph (may be larger than body).
# Returns nil if not zoomed in or if image unavailable.
# Uses zoomedcache — the same cache that drawimage() populates.
Window.prerenderzoomed(w: self ref Window): ref Image
{
	if(w.bodyimage == nil)
		return nil;

	imw := w.bodyimage.r.dx();
	imh := w.bodyimage.r.dy();
	bodyw := w.body.all.dx();
	bodyh := w.body.all.dy();
	if(imw <= 0 || imh <= 0 || bodyw <= 0 || bodyh <= 0)
		return nil;

	scalex := (bodyw * 1000) / imw;
	scaley := (bodyh * 1000) / imh;
	fitscale := scalex;
	if(scaley < fitscale)
		fitscale = scaley;
	zoom := w.zoomscale;
	if(zoom < 100)
		zoom = 100;
	dispw := (imw * fitscale * zoom) / (1000 * 100);
	disph := (imh * fitscale * zoom) / (1000 * 100);
	if(dispw < 1) dispw = 1;
	if(disph < 1) disph = 1;

	if(dispw <= bodyw && disph <= bodyh)
		return nil;	# Not zoomed enough to need pan

	# Cap for memory safety (4096×4096×3 = 48MB max)
	if(dispw > 4096) dispw = 4096;
	if(disph > 4096) disph = 4096;

	# Use cached version if available
	if(w.zoomedcache != nil &&
	   w.zoomedcache.r.dx() == dispw && w.zoomedcache.r.dy() == disph)
		return w.zoomedcache;

	scaled := scaleregion(w.bodyimage,
		Rect(Point(0, 0), Point(imw, imh)), dispw, disph);
	w.zoomedcache = scaled;
	return scaled;
}

# ---- Rendered documents ----
#
# Render on a markdown file sets the body's text, unsaved edits and
# all, as a document (rlayout(2): Go and its bold, italic and medium,
# headings larger, tables ruled) in the window's colours and font
# family, and shows it in place of the text: the window's width, one
# pixel to a pixel, scrolled up and down. The text is untouched
# underneath, so Put saves it; Render again, typing, or a write to the
# body goes back to it.

Window.docrender(w: self ref Window): string
{
	if(w.dochtml)
		return htmlrender(w);
	if(rlayout == nil){
		rlayout = load Rlayout Rlayout->PATH;
		if(rlayout == nil)
			return sprint("can't load %s: %r", Rlayout->PATH);
		rlayout->init(display);
	}
	fr := w.body.frame.r;
	width := fr.dx();
	if(width <= 0)
		return "window too narrow";
	prop := Font.open(display, xenith->fontnames[0]);
	if(prop == nil)
		prop = font;
	code := Font.open(display, xenith->fontnames[1]);

	s := "";
	nc := w.body.file.buf.nc;
	if(nc > 0){
		r := stralloc(nc);
		w.body.file.buf.read(0, r, 0, nc);
		s = r.s[0:nc];
		strfree(r);
	}
	entering := !w.docview;

	# code on the tags' colour, links and headings in the theme's accent
	cols := w.body.frame.cols;
	accent := xenith->accentcol;
	if(accent == nil)
		accent = cols[TEXT];
	style := ref Rlayout->Style(width, 4, prop, code,
		cols[TEXT], cols[BACK], accent, tagcols[BACK], 150);
	im : ref Image;
	lines, ys : array of int;
	{
		doc : list of ref Rlayout->DocNode;
		(doc, lines) = rlayout->parsemdlines(s);
		(im, ys) = rlayout->renderat(doc, style);
	} exception e {
	"*" =>
		return "render failed: " + e;
	}
	if(im == nil)
		return sprint("render failed: %r");
	w.doclines = lines;
	w.docys = ys;
	if(entering)	# open on the passage the text was showing
		w.imageoffset = Point(0, linetoy(w, lineof(w.body, w.body.org)));

	# no text cursor drawn over the document (docoff makes it again)
	f := w.body.frame;
	if(f.ticked)
		framem->frtick(f, framem->frptofchar(f, f.p0), 0);
	f.tick = nil;

	w.bodyimage = im;
	w.docheight = im.r.dy();
	w.zoomedcache = nil;
	w.imagemode = 1;
	w.docview = 1;
	w.docwidth = width;
	w.docbg = cols[BACK];
	w.docfg = cols[TEXT];
	w.docaccent = xenith->accentcol;
	w.drawimage();
	return nil;
}

#
# Render on an HTML file sets its text the same way, as a page laid out
# by Charon's engine (htmldoc): style sheets, images and links found
# from the file's directory, the page's own colours, the part in view
# painted as it scrolls. Links are followed with button 3.

loadhtmldoc(): string
{
	if(htmldoc != nil)
		return nil;
	h := load Htmldoc Htmldoc->PATH;
	if(h == nil)
		return sprint("can't load %s: %r", Htmldoc->PATH);
	if((err := h->init(display)) != nil)
		return err;
	htmldoc = h;
	return nil;
}

htmlrender(w: ref Window): string
{
	if(w.docweb)
		return webresize(w);
	if((lerr := loadhtmldoc()) != nil)
		return lerr;
	fr := w.body.frame.r;
	if(fr.dx() <= 0 || fr.dy() <= 0)
		return "window too small";

	s := "";
	nc := w.body.file.buf.nc;
	if(nc > 0){
		r := stralloc(nc);
		w.body.file.buf.read(0, r, 0, nc);
		s = r.s[0:nc];
		strfree(r);
	}
	name := w.body.file.name;
	if(name == nil || name[0] != '/')
		name = xenith->wdir + "/" + name;
	(h, err) := htmldoc->set(w.id, array of byte s, "file://" + name, fr.dx(), fr.dy());
	if(err != nil)
		return "render failed: " + err;
	if(!w.docview)
		w.imageoffset = Point(0, 0);

	# no text cursor drawn over the document (docoff makes it again)
	f := w.body.frame;
	if(f.ticked)
		framem->frtick(f, framem->frptofchar(f, f.p0), 0);
	f.tick = nil;

	w.docpage = nil;
	w.bodyimage = docpage(w);
	if(w.bodyimage == nil)
		return sprint("no image: %r");
	w.docheight = h;
	w.doclines = nil;
	w.docys = nil;
	w.zoomedcache = nil;
	w.imagemode = 1;
	w.docview = 1;
	cols := w.body.frame.cols;
	w.docwidth = fr.dx();
	w.docbg = cols[BACK];
	w.docfg = cols[TEXT];
	w.docaccent = xenith->accentcol;
	w.drawimage();
	return nil;
}

# The image an HTML document's part in view is painted on, the size
# of the body
docpage(w: ref Window): ref Image
{
	fr := w.body.frame.r;
	r := Rect((0, 0), (fr.dx(), fr.dy()));
	if(w.docpage == nil || !w.docpage.r.eq(r))
		w.docpage = display.newimage(r, mainwin.chans, 0, Draw->White);
	return w.docpage;
}

# The URL of the link at p on the screen, in an HTML document
Window.doclink(w: self ref Window, p: Point): string
{
	if(!w.docview || !w.dochtml || htmldoc == nil)
		return nil;
	fr := w.body.frame.r;
	if(!p.in(fr))
		return nil;
	return htmldoc->linkat(w.id, p.x - fr.min.x, p.y - fr.min.y + w.imageoffset.y);
}

Window.docoff(w: self ref Window)
{
	if(!w.docview)
		return;
	# the text from the passage the document was showing
	org := charofline(w.body, ytoline(w, w.imageoffset.y));
	w.body.frame.b = mainwin;
	w.docb = nil;
	w.body.org = org;
	w.docview = 0;
	if(w.dochtml && !w.docweb && htmldoc != nil)
		htmldoc->drop(w.id);
	if(!w.docweb)
		w.dochtml = 0;
	w.docpage = nil;
	w.imagemode = 0;
	w.rendermode = 0;
	w.bodyimage = nil;
	w.zoomedcache = nil;
	w.imageoffset = Point(0, 0);
	w.body.lastsr = Rect((0, 0), (0, 0));
	framem->frinittick(w.body.frame);
	framem->frdelete(w.body.frame, 0, w.body.frame.nchars);
	w.body.redraw(w.body.frame.r, w.body.frame.font, mainwin, -1);
	w.body.fill();
	scrdraw(w.body);
	w.settag();
}

Window.docscroll(w: self ref Window, dy: int)
{
	if(!w.docview)
		return;
	w.imageoffset.y += dy;
	w.drawimage();
}

#
# A URL opened in Xenith is browsed: the window is a browser window,
# its page a browser(2) session held by htmldoc under the window's id.
# The window is named by the page's URL and its text is the page's
# (for Look, search and selection; Render shows it), the page drawn
# over it as Render draws an HTML file.  Links are followed in the
# window, and Back, Fwd and Reload in its tag go through what it has
# shown.  Loading happens in the background: the page's events come
# back through casync (webwatch) to webevent.

Window.browse(w: self ref Window, url: string): string
{
	if((err := loadhtmldoc()) != nil)
		return err;
	fr := w.body.frame.r;
	if(fr.dx() <= 0 || fr.dy() <= 0)
		return "window too small";
	(c, berr) := htmldoc->browse(w.id, url, fr.dx(), fr.dy());
	if(berr != nil)
		return berr;
	if(c != nil)
		spawn webwatch(w.id, c);
	w.docweb = 1;
	w.dochtml = 1;
	w.filemenu = FALSE;
	if(!w.docview){
		# until the first page arrives
		draw(mainwin, fr, w.body.frame.cols[BACK], nil, Point(0, 0));
		mainwin.text(fr.min.add(Point(10, 10)), w.body.frame.cols[TEXT], Point(0, 0), font, "Loading " + url);
	}
	return nil;
}

# The page's events, to the main loop, until htmldoc drops the page
webwatch(winid: int, c: chan of string)
{
	for(;;){
		e := <-c;
		if(e == "gone")
			return;
		casync <-= ref AsyncMsg.WebEvent(winid, e);
	}
}

Window.webevent(w: self ref Window, e: string)
{
	if(!w.docweb || htmldoc == nil)
		return;
	(verb, rest) := (e, "");
	for(i := 0; i < len e; i++)
		if(e[i] == ' '){
			(verb, rest) = (e[0:i], e[i+1:]);
			break;
		}
	case verb {
	"done" =>
		w.webfield = 0;
		# the page's URL names the window and its text is the window's
		u := htmldoc->url(w.id);
		if(u != nil && u != w.body.file.name)
			w.setname(u, len u);
		t := htmldoc->text(w.id);
		w.nomark = 1;
		w.body.delete(0, w.body.file.buf.nc, TRUE);
		w.body.insert(0, t, len t, TRUE, 0);
		w.nomark = 0;
		w.body.file.mod = FALSE;
		w.dirty = FALSE;
		w.imageoffset = Point(0, htmldoc->scroll(w.id));
		if(w.rendermode || !w.docview)
			w.webview();
		w.settag();
	"error" =>
		warning(nil, sprint("%s: %s\n", w.body.file.name, rest));
	"update" =>
		# a field changed, here or through the page's files
		if(w.docview)
			webfieldchanged(w);
	}
}

# The page over the window's text
Window.webview(w: self ref Window): string
{
	if(htmldoc == nil)
		return "no page";
	fr := w.body.frame.r;
	htmldoc->resize(w.id, fr.dx(), fr.dy());

	# no text cursor drawn over the document (docoff makes it again)
	f := w.body.frame;
	if(f.ticked)
		framem->frtick(f, framem->frptofchar(f, f.p0), 0);
	f.tick = nil;

	w.docpage = nil;
	w.bodyimage = docpage(w);
	if(w.bodyimage == nil)
		return sprint("no image: %r");
	w.docheight = htmldoc->height(w.id);
	w.doclines = nil;
	w.docys = nil;
	w.zoomedcache = nil;
	w.imagemode = 1;
	w.docview = 1;
	w.rendermode = 1;
	cols := w.body.frame.cols;
	w.docwidth = fr.dx();
	w.docbg = cols[BACK];
	w.docfg = cols[TEXT];
	w.docaccent = xenith->accentcol;
	w.drawimage();
	return nil;
}

# The window's width changed: the page laid out again
webresize(w: ref Window): string
{
	fr := w.body.frame.r;
	if(fr.dx() <= 0 || fr.dy() <= 0)
		return "window too small";
	htmldoc->resize(w.id, fr.dx(), fr.dy());
	w.docheight = htmldoc->height(w.id);
	w.docpage = nil;
	return nil;
}

# A click at p on the screen: a link followed, a button pressed, a box
# checked.  0 if nothing there takes one.
Window.webclick(w: self ref Window, p: Point): int
{
	if(!w.docview || !w.docweb || htmldoc == nil)
		return 0;
	fr := w.body.frame.r;
	if(!p.in(fr))
		return 0;
	pp := Point(p.x - fr.min.x, p.y - fr.min.y + w.imageoffset.y);

	# a field typed into takes the keyboard; a select clicked again
	# takes its next option
	if((f := webfieldat(w, pp)) != nil){
		if(f.kind == "select" && w.webfield == f.node)
			webselect(w, f, 1);
		w.webfield = f.node;
		w.drawimage();
		return 1;
	}
	if(w.webfield != 0){
		w.webfield = 0;
		w.drawimage();
	}
	(hit, err) := htmldoc->click(w.id, pp.x, pp.y);
	if(err != nil)
		warning(nil, sprint("%s: %s\n", w.body.file.name, err));
	else if(hit)
		w.drawimage();	# a box checked shows at once
	return hit;
}

# ---- form fields ----
#
# A click on a field typed into (text, password, a textarea, ...) or a
# select gives it the keyboard, shown by a ring around it; the window's
# keys then go to it (Row.typex): text keys and Backspace edit it, ^U
# empties it, Return submits its form (a newline in a textarea), Tab
# goes to the next such field, Esc lets the keyboard go.  In a select,
# Up and Down choose the option before and after, a letter the next
# whose label starts with it, and a click the next.  Each change is the
# page's (htmldoc->setfield), laid out again with it.

typedinto(kind: string): int
{
	case kind {
	"" or "text" or "password" or "search" or "email" or "url" or "tel" or "number" or "textarea" or "select" =>
		return 1;
	}
	return 0;
}

# The field typed into whose box holds p (page coordinates)
webfieldat(w: ref Window, p: Point): ref Htmldoc->Field
{
	f := htmldoc->fields(w.id);
	for(i := 0; i < len f; i++)
		if(typedinto(f[i].kind) && p.in(f[i].box))
			return f[i];
	return nil;
}

webfocused(w: ref Window): ref Htmldoc->Field
{
	f := htmldoc->fields(w.id);
	for(i := 0; i < len f; i++)
		if(f[i].node == w.webfield)
			return f[i];
	return nil;
}

# A ring around the field with the keyboard
webring(w: ref Window, fr: Rect, oy: int)
{
	f := webfocused(w);
	if(f == nil)
		return;
	r := f.box.addpt(Point(fr.min.x, fr.min.y - oy)).inset(-2);
	col := xenith->accentcol;
	if(col == nil)
		col = w.body.frame.cols[TEXT];
	oc := mainwin.clipr;
	mainwin.clipr = fr;
	mainwin.border(r, 2, col, Point(0, 0));
	mainwin.clipr = oc;
}

# A select's option by, or the next whose label starts with c
webselect(w: ref Window, f: ref Htmldoc->Field, by: int)
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
		htmldoc->setfield(w.id, f.node, opts[j].t0);
}

webselectletter(w: ref Window, f: ref Htmldoc->Field, c: int)
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
	c = lowerrune(c);
	for(k := 1; k <= n; k++){
		o := opts[(cur + k) % n];
		if(len o.t1 > 0 && lowerrune(o.t1[0]) == c){
			htmldoc->setfield(w.id, f.node, o.t0);
			return;
		}
	}
}

lowerrune(c: int): int
{
	if(c >= 'A' && c <= 'Z')
		c += 'a' - 'A';
	return c;
}

Window.webkey(w: self ref Window, r: int)
{
	if(htmldoc == nil)
		return;
	f := webfocused(w);
	if(f == nil){
		w.webfield = 0;
		return;
	}
	case r {
	Keyboard->Esc =>
		w.webfield = 0;
		w.drawimage();
		return;
	'\t' =>
		# the next field typed into, round to the first
		a := htmldoc->fields(w.id);
		first, next: ref Htmldoc->Field;
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
		w.webfield = next.node;
		webshowfield(w, next);
		return;
	'\n' =>
		if(f.kind != "textarea"){
			w.webfield = 0;
			if(f.form == 0)
				w.drawimage();
			else if((err := htmldoc->submit(w.id, f.form)) != nil)
				warning(nil, sprint("%s: %s\n", w.body.file.name, err));
			return;
		}
	}
	if(f.kind == "select"){
		case r {
		Keyboard->Up =>	webselect(w, f, -1);
		Keyboard->Down =>	webselect(w, f, 1);
		* =>
			if(r > ' ' && r < Keyboard->Spec)
				webselectletter(w, f, r);
		}
		webfieldchanged(w);
		return;
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
			return;
	}
	if((err := htmldoc->setfield(w.id, f.node, v)) != nil){
		warning(nil, sprint("%s: %s\n", w.body.file.name, err));
		return;
	}
	webfieldchanged(w);
}

# The page laid out again with a field changed
webfieldchanged(w: ref Window)
{
	w.docheight = htmldoc->height(w.id);
	w.drawimage();
}

# A field brought into view
webshowfield(w: ref Window, f: ref Htmldoc->Field)
{
	h := w.body.frame.r.dy();
	if(f.box.min.y < w.imageoffset.y || f.box.max.y > w.imageoffset.y + h)
		w.imageoffset.y = f.box.min.y - h / 3;
	w.drawimage();
}

# Where the page is posted as files: #sxenith/<id> (see htmldoc.m)
Window.webposted(w: self ref Window): string
{
	if(!w.docweb || htmldoc == nil)
		return nil;
	return htmldoc->posted(w.id);
}

Window.weburl(w: self ref Window): string
{
	if(!w.docweb || htmldoc == nil)
		return nil;
	return htmldoc->url(w.id);
}

# Back, Fwd, Reload and Stop in a browser window's tag; Get is Reload
Window.webcmd(w: self ref Window, cmd: string): string
{
	if(!w.docweb || htmldoc == nil)
		return "not a web page";
	case cmd {
	"Back" =>	return htmldoc->back(w.id);
	"Fwd" =>	return htmldoc->forward(w.id);
	"Reload" or "Get" =>	return htmldoc->reload(w.id);
	"Stop" =>	return htmldoc->stop(w.id);
	}
	return "unknown command " + cmd;
}

# The document from imageoffset.y down, in the body's frame, and the
# scroll bar's thumb where that is in it; set again first if the
# window's width or colours have changed since
drawdoc(w: ref Window)
{
	fr := w.body.frame.r;
	cols := w.body.frame.cols;
	if(fr.dx() != w.docwidth || cols[BACK] != w.docbg || cols[TEXT] != w.docfg || xenith->accentcol != w.docaccent){
		w.docwidth = fr.dx();	# once, even if setting it fails
		w.docbg = cols[BACK];
		w.docfg = cols[TEXT];
		w.docaccent = xenith->accentcol;
		if(w.docrender() == nil)
			return;
	}
	# the text, still kept up to date, draws where it is not seen
	if(w.docb == nil || !w.docb.r.eq(w.body.all))
		w.docb = display.newimage(w.body.all, mainwin.chans, 0, Draw->Nofill);
	if(w.docb != nil)
		w.body.frame.b = w.docb;

	im := w.bodyimage;
	h := fr.dy();
	total := w.docheight;
	oy := w.imageoffset.y;
	if(oy > total - h)
		oy = total - h;
	if(oy < 0)
		oy = 0;
	w.imageoffset = Point(0, oy);

	draw(mainwin, fr, cols[BACK], nil, Point(0, 0));
	if(w.dochtml){
		if((im = docpage(w)) == nil)
			return;
		w.bodyimage = im;
		htmldoc->paint(w.id, im, oy);
		draw(mainwin, fr, im, nil, im.r.min);
		if(w.docweb && w.webfield != 0)
			webring(w, fr, oy);
	}else
		draw(mainwin, fr, im, nil, Point(im.r.min.x, im.r.min.y + oy));

	sr := w.body.scrollr;
	if(sr.dy() > 0 && total > 0){
		y0 := sr.min.y + sr.dy() * oy / total;
		bot := oy + h;
		if(bot > total)
			bot = total;
		y1 := sr.min.y + sr.dy() * bot / total;
		if(y1 < y0 + 2)
			y1 = y0 + 2;
		draw(mainwin, sr, cols[BORD], nil, Point(0, 0));
		draw(mainwin, Rect((sr.min.x, y0), (sr.max.x - 1, y1)), cols[BACK], nil, Point(0, 0));
		draw(mainwin, Rect((sr.max.x - 1, y0), (sr.max.x, y1)), cols[BORD], nil, Point(0, 0));
	}
	w.body.lastsr = Rect((0, 0), (0, 0));	# scrdraw redraws for the text
}

# The line (from 0) holding character q of t
lineof(t: ref Text, q: int): int
{
	n := 0;
	r := stralloc(4096);
	for(p := 0; p < q; ){
		m := min(4096, q - p);
		t.file.buf.read(p, r, 0, m);
		for(i := 0; i < m; i++)
			if(r.s[i] == '\n')
				n++;
		p += m;
	}
	strfree(r);
	return n;
}

# The character that starts line n (from 0) of t
charofline(t: ref Text, n: int): int
{
	if(n <= 0)
		return 0;
	nc := t.file.buf.nc;
	r := stralloc(4096);
	for(p := 0; p < nc; ){
		m := min(4096, nc - p);
		t.file.buf.read(p, r, 0, m);
		for(i := 0; i < m; i++)
			if(r.s[i] == '\n' && --n == 0){
				strfree(r);
				return p + i + 1;
			}
		p += m;
	}
	strfree(r);
	return nc;
}

# Where line n of the text falls in the document: in the block that
# holds it, as far down as the line is through the block's lines
linetoy(w: ref Window, n: int): int
{
	(l, y) := (w.doclines, w.docys);
	if(l == nil || len l == 0 || len y < len l)
		return 0;
	k := 0;
	while(k+1 < len l && l[k+1] <= n)
		k++;
	if(n < l[k])
		return 0;
	if(k+1 < len l && l[k+1] > l[k])
		return y[k] + (n - l[k]) * (y[k+1] - y[k]) / (l[k+1] - l[k]);
	return y[k];
}

# The line of the text at height y of the document: the inverse
ytoline(w: ref Window, y: int): int
{
	(l, ys) := (w.doclines, w.docys);
	if(l == nil || len l == 0 || len ys < len l)
		return 0;
	k := 0;
	while(k+1 < len l && ys[k+1] <= y)
		k++;
	if(y < ys[k])
		return l[k];
	if(k+1 < len l && ys[k+1] > ys[k])
		return l[k] + (y - ys[k]) * (l[k+1] - l[k]) / (ys[k+1] - ys[k]);
	return l[k];
}
