implement Sheetview;

#
# A document's sheets in a column, on an image (sheetview(2)): the view
# Xenith's windows and wm/page share.  See module/sheetview.m.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;

include "draw.m";
	draw: Draw;
	Point, Rect, Image, Display, Font, Chans: import draw;

include "docengine.m";
include "docreg.m";
	docreg: Docreg;
	Kind: import docreg;

include "sheetview.m";

MAXDIM: con 6000;	# the largest side of a sheet painted
MINSCALE: con 5;
MAXFLOW: con 800;	# the largest scale for a flowing document

gens := 0;

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	docreg = load Docreg Docreg->PATH;
	if(docreg != nil)
		docreg->init(d);
}

new(k: ref Kind, name: string, c: chan of ref Ev): ref View
{
	v := ref View;
	v.kind = k;
	v.name = name;
	v.h = -1;
	v.gen = ++gens;
	v.scale = 100;
	v.fit = Fitnone;
	v.c = c;
	return v;
}

View.flowing(v: self ref View): int
{
	return v.web || (v.kind != nil && v.kind.class == Docreg->Source);
}

# ---- opening ----

View.open(v: self ref View, data: array of byte, name: string)
{
	if(name != nil)
		v.name = name;
	spawn opener(v, v.gen, v.kind, data, v.name, setwidth(v));
}

View.browse(v: self ref View, url: string): string
{
	if(v.h >= 0)
		return v.eng->command(v.h, "browse", url);
	v.web = 1;
	v.open(nil, url);
	return nil;
}

opener(v: ref View, gen: int, k: ref Kind, data: array of byte, name: string, st: ref Docengine->Style)
{
	h := -1;
	eng: Docengine;
	err: string;
	if(docreg == nil)
		err = "no document registry";
	else if(k == nil)
		err = "not a document";
	else {
		(eng, err) = docreg->engine(k);
		if(eng != nil){
			{
				(h, err) = eng->open(data, name, st);
			} exception e {
			"*" =>
				if(err == nil)
					err = e;
			}
		}
	}
	# shown first; a binary document's text (all its pages') after
	v.c <-= ref Ev.Opened(v, gen, eng, h, err);
	if(h >= 0 && k.class == Docreg->Binary){
		text: string;
		{
			text = eng->text(h);
		} exception {
		"*" =>
			;
		}
		v.c <-= ref Ev.Text(v, gen, text);
	}
}

watch(v: ref View, gen: int, c: chan of string)
{
	for(;;){
		e := <-c;
		if(e == "gone")
			return;
		v.c <-= ref Ev.Engine(v, gen, e);
	}
}

View.close(v: self ref View)
{
	if(v.eng != nil && v.h >= 0)
		v.eng->close(v.h);
	v.h = -1;
	v.gen = -1;
	v.cache = nil;
}

View.handle(v: self ref View, e: ref Ev): ref Note
{
	if(e == nil)
		return nil;
	if(e.v != v || e.gen != v.gen){
		pick o := e {
		Opened =>
			if(o.eng != nil && o.h >= 0)
				o.eng->close(o.h);
		}
		return nil;
	}
	pick o := e {
	Opened =>
		if(o.h < 0){
			v.err = o.err;
			return ref Note.Failed(o.err);
		}
		v.eng = o.eng;
		v.h = o.h;
		v.err = nil;
		if((c := v.eng->events(v.h)) != nil)
			spawn watch(v, v.gen, c);
		measure(v);
		if(!v.flowing() && v.fit == Fitnone && v.scale == 100){
			if(v.eng->scalable(v.h))
				v.fit = Fitwidth;
			else
				v.fit = Fitpage;
		}
		v.vw = v.vh = 0;	# set the scale and the layout for r
		v.layout();
		return ref Note.Opened;
	Text =>
		if(v.h < 0 || v.flowing())
			return nil;
		return ref Note.Text(o.text);
	Painted =>
		v.painting = 0;
		if(o.err != nil){
			# not asked again at this scale
			v.cache = ref Painted(o.n, o.scale, nil) :: v.cache;
			return ref Note.Error(sprint("page %d: %s", o.n+1, o.err));
		}
		v.cache = ref Painted(o.n, o.scale, o.im) :: v.cache;
		return ref Note.Redraw;
	Engine =>
		if(v.h < 0)
			return nil;
		(verb, rest) := split(o.e);
		case verb {
		"done" =>
			# a page loaded: its URL names it, its text is the window's
			if((u := v.eng->name(v.h)) != nil)
				v.name = u;
			measure(v);
			v.vw = v.vh = 0;
			v.layout();
			v.org = Point(0, int rest);
			v.word = nil;
			v.found = nil;
			return ref Note.Loaded(v.name, v.eng->text(v.h));
		"update" =>
			measure(v);
			stack(v);
			return ref Note.Redraw;
		"error" =>
			return ref Note.Error(rest);
		}
	}
	return nil;
}

# ---- layout ----

measure(v: ref View)
{
	n := v.eng->nsheets(v.h);
	v.sizes = array[n] of Point;
	for(i := 0; i < n; i++)
		v.sizes[i] = v.eng->sheetsize(v.h, i);
}

maxdim(v: ref View): int
{
	m := 1;
	for(i := 0; i < len v.sizes; i++){
		sz := v.size(i);
		if(sz.x > m)
			m = sz.x;
		if(sz.y > m && !v.flowing())
			m = sz.y;
	}
	return m;
}

clampscale(v: ref View, s: int): int
{
	if(s < MINSCALE)
		s = MINSCALE;
	if(!v.flowing()){
		m := maxdim(v);
		if(m * s / 100 > MAXDIM)
			s = MAXDIM * 100 / m;
	}else if(s > MAXFLOW)
		s = MAXFLOW;
	if(s < 1)
		s = 1;
	return s;
}

# The scale a fit gives, for a view vw by vh
fitscale(v: ref View, vw, vh: int): int
{
	if(len v.sizes == 0)
		return v.scale;
	maxw := 1;
	for(i := 0; i < len v.sizes; i++)
		if(v.size(i).x > maxw)
			maxw = v.size(i).x;
	vw -= 2*GAP;
	vh -= 2*GAP;
	if(vw < 10)
		vw = 10;
	if(vh < 10)
		vh = 10;
	s := vw * 100 / maxw;
	if(v.fit == Fitpage){
		first := v.size(0);
		if(first.y > 0 && vh * 100 / first.y < s)
			s = vh * 100 / first.y;
	}
	return clampscale(v, s);
}

# The sheets' tops in the column, at the scale
stack(v: ref View)
{
	pad := GAP;
	if(v.flowing())
		pad = 0;
	n := len v.sizes;
	v.tops = array[n] of int;
	y := pad;
	w := 0;
	for(i := 0; i < n; i++){
		sz := v.size(i);
		v.tops[i] = y;
		y += sz.y * v.scale / 100 + pad;
		if((sw := sz.x * v.scale / 100) > w)
			w = sw;
	}
	v.colw = w + 2*pad;
	v.colh = y;
}

# The style a flowing document is set in: the caller's, at the width of
# the view at its scale
setwidth(v: ref View): ref Docengine->Style
{
	if(v.style == nil)
		return nil;
	vw := v.r.dx();
	if(v.scale > 0 && v.scale != 100)
		vw = vw * 100 / v.scale;
	if(vw < 50)
		vw = 50;
	st := ref *v.style;
	st.width = vw;
	return st;
}

# Scale and layout for r as it is now: a flowing document set again to
# its width, a fitted one scaled again, keeping its place
View.layout(v: self ref View)
{
	if(v.h < 0)
		return;
	# the place kept, as a fraction of the column; the first layout
	# keeps org as it was set (a document opened again where it was)
	had := v.colh > 0;
	frac := 0;
	if(had)
		frac = v.org.y * 1000 / v.colh;
	if(v.flowing()){
		if(v.vw != v.r.dx() || restyled(v)){
			v.styled = v.style;
			v.eng->restyle(v.h, setwidth(v));
			measure(v);
			v.cache = nil;
		}
	}else if(v.fit != Fitnone){
		s := fitscale(v, v.r.dx(), v.r.dy());
		if(s != v.scale){
			v.scale = s;
			v.word = nil;
		}
	}
	v.vw = v.r.dx();
	v.vh = v.r.dy();
	stack(v);
	if(had && v.colh > 0)
		v.org.y = frac * v.colh / 1000;
}

restyled(v: ref View): int
{
	a := v.style;
	b := v.styled;
	if(a == b)
		return 0;
	if(a == nil || b == nil)
		return 1;
	return a.fg != b.fg || a.bg != b.bg || a.accent != b.accent || a.codebg != b.codebg ||
		a.font != b.font || a.codefont != b.codefont;
}

# The sheet at y in the column (the last whose top is at or above it)
View.sheetat(v: self ref View, y: int): int
{
	# the tops rise down the column: halve it (a document of twenty
	# thousand pages is drawn on every scroll)
	lo := 0;
	hi := len v.tops - 1;
	while(lo < hi){
		m := (lo + hi + 1) / 2;
		if(v.tops[m] <= y + GAP)
			lo = m;
		else
			hi = m - 1;
	}
	return lo;
}

# Where sheet n is on dst
View.sheetrect(v: self ref View, n: int): Rect
{
	fr := v.r;
	sz := v.size(n);
	sw := sz.x * v.scale / 100;
	sh := sz.y * v.scale / 100;
	x := (v.colw - sw) / 2;
	if(v.colw < fr.dx())
		x += (fr.dx() - v.colw) / 2;
	else
		x -= v.org.x;
	y := v.tops[n] - v.org.y;
	return Rect((fr.min.x + x, fr.min.y + y), (fr.min.x + x + sw, fr.min.y + y + sh));
}

clamporg(v: ref View)
{
	mx := v.colw - v.r.dx();
	my := v.colh - v.r.dy();
	if(mx < 0)
		mx = 0;
	if(my < 0)
		my = 0;
	if(v.org.x > mx)
		v.org.x = mx;
	if(v.org.y > my)
		v.org.y = my;
	if(v.org.x < 0)
		v.org.x = 0;
	if(v.org.y < 0)
		v.org.y = 0;
}

# ---- drawing ----

View.draw(v: self ref View)
{
	dst := v.dst;
	if(dst == nil)
		return;
	fr := v.r;
	bg := v.bg;
	if(bg == nil)
		bg = dst.display.white;
	if(v.h < 0){
		dst.draw(fr, bg, nil, Point(0, 0));
		msg := "Loading " + v.name;
		if(v.err != nil)
			msg = v.name + ": " + v.err;
		if(v.font != nil)
			dst.text(fr.min.add(Point(10, 10)), fg(v), Point(0, 0), v.font, msg);
		v.colh = 0;
		return;
	}
	if(v.vw != fr.dx() || v.vh != fr.dy() || v.flowing() && restyled(v))
		v.layout();
	clamporg(v);

	oclip := dst.clipr;
	dst.clipr = fr;
	dst.draw(fr, bg, nil, Point(0, 0));
	for(n := v.sheetat(v.org.y); n < len v.sizes; n++){
		sr := v.sheetrect(n);
		if(sr.max.y <= fr.min.y)
			continue;
		if(sr.min.y >= fr.max.y)
			break;
		paintsheet(v, n, sr, fr);
	}
	marks(v);
	dst.clipr = oclip;
	requestpaint(v);
}

fg(v: ref View): ref Image
{
	if(v.style != nil && v.style.fg != nil)
		return v.style.fg;
	return v.dst.display.black;
}

# Sheet n, at sr on dst, the part of it in fr
paintsheet(v: ref View, n: int, sr, fr: Rect)
{
	(vis, ok) := sr.clip(fr);
	if(!ok)
		return;
	dst := v.dst;
	scalable := v.eng->scalable(v.h);
	if(!scalable && v.scale == 100 && v.rot == 0){
		# straight onto dst
		if(v.eng->paint(v.h, n, 100, dst, vis, vis.min.sub(sr.min)) != nil)
			blank(dst, vis);
		return;
	}
	if(!scalable && v.flowing()){
		# zoomed: the part in view, at 100, scaled up
		pr := Rect(vis.min.sub(sr.min).mul(100).div(v.scale), vis.max.sub(sr.min).mul(100).div(v.scale));
		if(pr.dx() <= 0 || pr.dy() <= 0)
			return;
		im := dst.display.newimage(Rect((0, 0), (pr.dx(), pr.dy())), dst.chans, 0, Draw->White);
		if(im == nil || v.eng->paint(v.h, n, 100, im, im.r, pr.min) != nil){
			blank(dst, vis);
			return;
		}
		quickdraw(dst, vis, im, im.r);
		return;
	}
	if((p := cached(v, n, v.scale)) != nil){
		if(p.im != nil)
			dst.draw(vis, p.im, nil, p.im.r.min.add(vis.min.sub(sr.min)));
		else
			blank(dst, vis);
		return;
	}
	# meanwhile: a painting at another scale, scaled; or a blank sheet
	for(l := v.cache; l != nil; l = tl l){
		p = hd l;
		if(p.n == n && p.im != nil){
			sw := sr.dx();
			sh := sr.dy();
			if(sw <= 0 || sh <= 0)
				break;
			pw := p.im.r.dx();
			ph := p.im.r.dy();
			src := Rect(vis.min.sub(sr.min), vis.max.sub(sr.min));
			src = Rect((src.min.x * pw / sw, src.min.y * ph / sh), (src.max.x * pw / sw, src.max.y * ph / sh));
			quickdraw(dst, vis, p.im, src.addpt(p.im.r.min));
			return;
		}
	}
	blank(dst, vis);
}

blank(dst: ref Image, r: Rect)
{
	dst.draw(r, dst.display.white, nil, Point(0, 0));
}

cached(v: ref View, n, scale: int): ref Painted
{
	for(l := v.cache; l != nil; l = tl l)
		if((hd l).n == n && (hd l).scale == scale)
			return hd l;
	return nil;
}

# src of im drawn into r, scaled by nearest neighbour, in a draw a row
# and a draw a column: fast enough to show while the real painting is
# made
quickdraw(dst: ref Image, r: Rect, im: ref Image, src: Rect)
{
	rw := r.dx();
	rh := r.dy();
	sw := src.dx();
	sh := src.dy();
	if(rw <= 0 || rh <= 0 || sw <= 0 || sh <= 0)
		return;
	if(rw == sw && rh == sh){
		dst.draw(r, im, nil, src.min);
		return;
	}
	# rows first, into an image as wide as the source part
	t := dst.display.newimage(Rect((0, 0), (sw, rh)), im.chans, 0, Draw->Nofill);
	if(t == nil)
		return;
	for(y := 0; y < rh; y++)
		t.draw(Rect((0, y), (sw, y+1)), im, nil, Point(src.min.x, src.min.y + y * sh / rh));
	for(x := 0; x < rw; x++)
		dst.draw(Rect((r.min.x + x, r.min.y), (r.min.x + x + 1, r.max.y)), t, nil, Point(x * sw / rw, 0));
}

# The word selected and what a search found, marked on the drawing
marks(v: ref View)
{
	col := v.mark;
	if(col == nil)
		col = fg(v);
	if(v.word != nil){
		(n, r) := v.wordat;
		mark(v, n, r, col);
	}
	if(v.found == nil)
		return;
	# what was found on the sheets in view
	for(n := v.sheetat(v.org.y); n < len v.sizes; n++){
		sr := v.sheetrect(n);
		if(sr.min.y >= v.r.max.y)
			break;
		if(sr.max.y > v.r.min.y && isfound(v, n))
			for(rl := v.foundon(n); rl != nil; rl = tl rl)
				mark(v, n, hd rl, col);
	}
}

isfound(v: ref View, n: int): int
{
	for(l := v.found; l != nil; l = tl l)
		if(hd l == n)
			return 1;
		else if(hd l > n)
			return 0;
	return 0;
}

mark(v: ref View, n: int, r: Rect, col: ref Image)
{
	if(n < 0 || n >= len v.sizes)
		return;
	sr := v.sheetrect(n);
	s := v.scale;
	r = turnrect(v, n, r);
	rr := Rect(r.min.mul(s).div(100), r.max.mul(s).div(100)).addpt(sr.min).inset(-1);
	v.dst.border(rr, 2, col, Point(0, 0));
}

# ---- painting, off the caller's thread ----

# The first sheet in or next to the view that has no painting at the
# view's scale, painted: one at a time for a view
requestpaint(v: ref View)
{
	if(v.h < 0 || v.painting)
		return;
	scalable := v.eng->scalable(v.h);
	if(!scalable && (v.scale == 100 && v.rot == 0 || v.flowing()))
		return;
	first := -1;
	last := -1;
	for(n := v.sheetat(v.org.y); n < len v.sizes; n++){
		sr := v.sheetrect(n);
		if(sr.min.y >= v.r.max.y)
			break;
		if(sr.max.y <= v.r.min.y)
			continue;
		if(first < 0)
			first = n;
		last = n;
	}
	if(first < 0)
		return;
	# the sheets in view, then the next the way it is going
	ahead := last + 1;
	if(v.dir < 0)
		ahead = first - 1;
	lo := first;
	hi := last;
	if(ahead < lo)
		lo = ahead;
	if(ahead > hi)
		hi = ahead;
	prune(v, lo, hi);
	for(n = first; n <= last + 1; n++){
		m := n;
		if(n > last)
			m = ahead;
		if(m < 0 || m >= len v.sizes || cached(v, m, v.scale) != nil)
			continue;
		sz := v.size(m);
		sz = Point(sz.x * v.scale / 100, sz.y * v.scale / 100);
		if(sz.x <= 0 || sz.y <= 0 || sz.x > MAXDIM || sz.y > MAXDIM)
			continue;
		v.painting = 1;
		spawn painter(v, v.gen, v.dst.display, v.dst.chans, v.eng, v.h, m, v.scale, scalable, v.sizes[m], v.rot);
		return;
	}
}

# Paintings kept: the view's scale for sheets first..last; one at
# another scale for those, to show until theirs is painted
prune(v: ref View, first, last: int)
{
	keep: list of ref Painted;
	for(l := v.cache; l != nil; l = tl l){
		p := hd l;
		if(p.n < first || p.n > last)
			continue;
		if(p.scale != v.scale && (cached(v, p.n, v.scale) != nil || otherkept(keep, p.n)))
			continue;
		keep = p :: keep;
	}
	v.cache = keep;
}

otherkept(l: list of ref Painted, n: int): int
{
	for(; l != nil; l = tl l)
		if((hd l).n == n)
			return 1;
	return 0;
}

painter(v: ref View, gen: int, disp: ref Display, chans: Draw->Chans, eng: Docengine, h, n, scale, scalable: int, size: Point, rot: int)
{
	err: string;
	sz := Point(size.x * scale / 100, size.y * scale / 100);
	im: ref Image;
	{
		if(scalable){
			# painted at the scale: the engine places and smooths
			# what it draws at the image's resolution
			im = disp.newimage(Rect((0, 0), sz), Draw->RGB24, 0, Draw->White);
			if(im == nil)
				err = sprint("no image: %r");
			else
				err = eng->paint(h, n, scale, im, im.r, Point(0, 0));
		}else{
			full := disp.newimage(Rect((0, 0), size), chans, 0, Draw->White);
			if(full == nil)
				err = sprint("no image: %r");
			else if((err = eng->paint(h, n, 100, full, full.r, Point(0, 0))) == nil)
				im = boxscale(full, sz);
		}
		if(im != nil && err == nil && rot != 0)
			im = turn(im, rot);
	} exception e {
	"*" =>
		err = "paint: " + e;
	}
	if(err != nil)
		im = nil;
	v.c <-= ref Ev.Painted(v, gen, n, scale, im, err);
}

# im scaled to sz, averaging the pixels each new one covers (smooth, for
# an image made smaller), or repeating them (made larger)
boxscale(im: ref Image, sz: Point): ref Image
{
	iw := im.r.dx();
	ih := im.r.dy();
	if(sz.x <= 0 || sz.y <= 0)
		return nil;
	disp := im.display;
	if(sz.x >= iw && sz.y >= ih){
		out := disp.newimage(Rect((0, 0), sz), im.chans, 0, Draw->Nofill);
		if(out != nil)
			quickdraw(out, out.r, im, im.r);
		return out;
	}
	src := im;
	if(!src.chans.eq(Draw->RGB24)){
		rgb := disp.newimage(src.r, Draw->RGB24, 0, Draw->Black);
		if(rgb != nil){
			rgb.draw(rgb.r, src, nil, src.r.min);
			src = rgb;
		}
	}
	out := disp.newimage(Rect((0, 0), sz), Draw->RGB24, 0, Draw->Black);
	if(out == nil)
		return nil;
	rowbuf := array[iw * 3] of byte;
	outrow := array[sz.x * 3] of byte;
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
			src.readpixels(Rect((src.r.min.x, src.r.min.y + y), (src.r.max.x, src.r.min.y + y + 1)), rowbuf);
			for(ox := 0; ox < sz.x; ox++){
				x0 := ox * iw / sz.x;
				x1 := (ox + 1) * iw / sz.x;
				if(x1 <= x0)
					x1 = x0 + 1;
				for(x := x0; x < x1 && x < iw; x++){
					acc[ox*3] += int rowbuf[x*3];
					acc[ox*3+1] += int rowbuf[x*3+1];
					acc[ox*3+2] += int rowbuf[x*3+2];
					cnt[ox]++;
				}
			}
		}
		for(ox := 0; ox < sz.x; ox++){
			c := cnt[ox];
			if(c < 1)
				c = 1;
			outrow[ox*3] = byte (acc[ox*3] / c);
			outrow[ox*3+1] = byte (acc[ox*3+1] / c);
			outrow[ox*3+2] = byte (acc[ox*3+2] / c);
		}
		out.writepixels(Rect((0, oy), (sz.x, oy + 1)), outrow);
	}
	return out;
}

# im turned q quarter turns clockwise, as RGB24
turn(im: ref Image, q: int): ref Image
{
	disp := im.display;
	src := im;
	if(!src.chans.eq(Draw->RGB24)){
		src = disp.newimage(im.r, Draw->RGB24, 0, Draw->Nofill);
		if(src == nil)
			return im;
		src.draw(src.r, im, nil, im.r.min);
	}
	w := src.r.dx();
	h := src.r.dy();
	ow := w;
	oh := h;
	if(q & 1)
		(ow, oh) = (h, w);
	out := disp.newimage(Rect((0, 0), (ow, oh)), Draw->RGB24, 0, Draw->Nofill);
	if(out == nil)
		return im;
	b := array[w * h * 3] of byte;
	src.readpixels(src.r, b);
	o := array[ow * oh * 3] of byte;
	for(y := 0; y < h; y++){
		for(x := 0; x < w; x++){
			# where (x, y) goes
			tx, ty: int;
			case q {
			1 =>	(tx, ty) = (h - 1 - y, x);
			2 =>	(tx, ty) = (w - 1 - x, h - 1 - y);
			* =>	(tx, ty) = (y, w - 1 - x);
			}
			i := (y*w + x) * 3;
			j := (ty*ow + tx) * 3;
			o[j] = b[i];
			o[j+1] = b[i+1];
			o[j+2] = b[i+2];
		}
	}
	out.writepixels(out.r, o);
	return out;
}

# A point on sheet n, turned (scale 100), as the engine has it, and
# the engine's point (or rectangle) turned
unturn(v: ref View, n: int, p: Point): Point
{
	w := v.sizes[n].x;
	h := v.sizes[n].y;
	case v.rot {
	1 =>	return Point(p.y, h - p.x);
	2 =>	return Point(w - p.x, h - p.y);
	3 =>	return Point(w - p.y, p.x);
	}
	return p;
}

turnpt(v: ref View, n: int, p: Point): Point
{
	w := v.sizes[n].x;
	h := v.sizes[n].y;
	case v.rot {
	1 =>	return Point(h - p.y, p.x);
	2 =>	return Point(w - p.x, h - p.y);
	3 =>	return Point(p.y, w - p.x);
	}
	return p;
}

turnrect(v: ref View, n: int, r: Rect): Rect
{
	if(v.rot == 0)
		return r;
	a := turnpt(v, n, r.min);
	b := turnpt(v, n, r.max);
	return Rect((min(a.x, b.x), min(a.y, b.y)), (max(a.x, b.x), max(a.y, b.y)));
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

# Sheet n's size at scale 100, turned
View.size(v: self ref View, n: int): Point
{
	sz := v.sizes[n];
	if(v.rot & 1)
		return Point(sz.y, sz.x);
	return sz;
}

View.rotate(v: self ref View, q: int)
{
	if(v.flowing())
		return;
	v.rot = (v.rot + q) & 3;
	v.cache = nil;
	v.word = nil;
	v.vw = v.vh = 0;	# laid out again, where it was
}

# ---- moving about ----

View.scroll(v: self ref View, dy: int)
{
	v.pan(Point(v.org.x, v.org.y + dy));
}

View.pan(v: self ref View, org: Point)
{
	if(org.y > v.org.y)
		v.dir = 1;
	else if(org.y < v.org.y)
		v.dir = -1;
	v.org = org;
}

View.zoom(v: self ref View, s: int)
{
	if(v.h < 0)
		return;
	s = clampscale(v, s);
	if(s == v.scale)
		return;
	# the point at the top of the view, in the middle, stays
	cx := v.org.x + v.r.dx() / 2;
	cy := v.org.y;
	old := v.scale;
	v.scale = s;
	v.fit = Fitnone;
	v.word = nil;
	if(v.flowing()){
		frac := 0;
		if(v.colh > 0)
			frac = cy * 1000 / v.colh;
		v.eng->restyle(v.h, setwidth(v));
		measure(v);
		stack(v);
		v.org = Point(0, frac * v.colh / 1000);
	}else{
		stack(v);
		v.org = Point(cx * s / old - v.r.dx() / 2, cy * s / old);
	}
}

View.setfit(v: self ref View, fit: int)
{
	v.fit = fit;
	v.vw = v.vh = 0;
	v.word = nil;
}

View.gotosheet(v: self ref View, n: int)
{
	if(n >= len v.tops)
		n = len v.tops - 1;
	if(n < 0)
		return;
	v.pan(Point(v.org.x, v.tops[n] - GAP));
}

# The sheet and the point on it (scale 100) under p on dst
View.at(v: self ref View, p: Point): (int, Point)
{
	if(v.h < 0)
		return (-1, Point(0, 0));
	for(n := v.sheetat(v.org.y + p.y - v.r.min.y); n >= 0 && n < len v.sizes; n--){
		sr := v.sheetrect(n);
		if(p.in(sr))
			return (n, unturn(v, n, p.sub(sr.min).mul(100).div(v.scale)));
		if(sr.max.y < p.y)
			break;
	}
	return (-1, Point(0, 0));
}

# What an engine's click or key asks for
View.result(v: self ref View, res: string): ref Note
{
	(verb, rest) := split(res);
	case verb {
	"layout" =>
		measure(v);
		stack(v);
	"show" =>
		(nil, l) := sys->tokenize(rest, " ");
		if(l != nil && tl l != nil){
			y0 := int hd l * v.scale / 100;
			y1 := int hd tl l * v.scale / 100;
			h := v.r.dy();
			if(len v.tops > 0)
				(y0, y1) = (y0 + v.tops[0], y1 + v.tops[0]);
			if(y0 < v.org.y || y1 > v.org.y + h)
				v.org.y = y0 - h / 3;
		}
	"error" =>
		return ref Note.Error(rest);
	}
	return ref Note.Redraw;
}

# ---- the words drawn ----

# The word at p on sheet n, where it is, and which of the sheet's words
# it is, from the engine's runs
View.wordof(v: self ref View, n: int, p: Point): (string, Rect, int)
{
	if(v.h < 0)
		return (nil, Rect((0, 0), (0, 0)), -1);
	runs := v.eng->runs(v.h, n);
	for(i := 0; i < len runs; i++)
		if(p.in(runs[i].r))
			return (runs[i].text, runs[i].r, i);
	return (nil, Rect((0, 0), (0, 0)), -1);
}

View.select(v: self ref View, n: int, word: string, r: Rect)
{
	v.word = word;
	v.wordat = (n, r);
}

# s found: the sheets whose text has it (where on a sheet is worked out
# as it is drawn: a document's words are many, its text is at hand), the
# first in view; nil, or why not
View.find(v: self ref View, s: string): string
{
	if(v.h < 0)
		return "no document";
	v.found = nil;
	v.findstr = nil;
	if(s == nil)
		return nil;
	ls := lower(s);
	f: list of int;
	for(n := len v.sizes - 1; n >= 0; n--){
		t := v.eng->sheettext(v.h, n);
		if(t == nil){
			# an engine without a sheet's text: its words
			runs := v.eng->runs(v.h, n);
			for(i := 0; i < len runs; i++)
				t += runs[i].text + " ";
		}
		if(contains(lower(t), ls))
			f = n :: f;
	}
	if(f == nil)
		return "not found";
	v.found = f;
	v.findstr = ls;
	n = hd f;
	y := v.tops[n];
	if((rl := v.foundon(n)) != nil)
		y += turnrect(v, n, hd rl).min.y * v.scale / 100;
	h := v.r.dy();
	if(y < v.org.y || y > v.org.y + h)
		v.org.y = y - h / 3;
	return nil;
}

# Where on sheet n the search's string is: the words that have it (or a
# phrase's first word), at scale 100
View.foundon(v: self ref View, n: int): list of Rect
{
	if(v.h < 0 || v.findstr == nil)
		return nil;
	runs := v.eng->runs(v.h, n);
	r: list of Rect;
	for(i := len runs - 1; i >= 0; i--)
		if(contains(lower(runs[i].text), v.findstr))
			r = runs[i].r :: r;
	if(r == nil){
		(nil, f) := sys->tokenize(v.findstr, " \t");
		if(f != nil)
			for(i = len runs - 1; i >= 0; i--)
				if(contains(lower(runs[i].text), hd f))
					r = runs[i].r :: r;
	}
	return r;
}

# ---- commands ----

View.command(v: self ref View, cmd, arg: string): (int, string)
{
	if(v.h < 0)
		return (1, "not loaded yet");
	case cmd {
	"Zoom+" =>
		v.zoom(v.scale * 5 / 4 + 1);
	"Zoom-" =>
		v.zoom(v.scale * 4 / 5);
	"Zoom" =>
		if(arg == nil)
			return (1, "Zoom: percent?");
		v.zoom(int arg);
	"Fit" =>
		if(v.flowing()){
			v.zoom(100);
			return (1, nil);
		}
		if(arg == "page")
			v.setfit(Fitpage);
		else
			v.setfit(Fitwidth);
	"Page" =>
		if(arg == nil)
			return (1, "Page: which?");
		v.gotosheet(int arg - 1);
	"NextPage" =>
		v.gotosheet(v.sheetat(v.org.y) + 1);
	"PrevPage" =>
		v.gotosheet(v.sheetat(v.org.y) - 1);
	* =>
		for(l := v.eng->commands(v.h); l != nil; l = tl l)
			if(hd l == cmd)
				return (1, v.eng->command(v.h, cmd, arg));
		return (0, nil);
	}
	return (1, nil);
}

# The view's commands and the engine's (a page browsed: the engine's)
View.commands(v: self ref View): list of string
{
	l: list of string;
	if(v.h >= 0)
		l = v.eng->commands(v.h);
	if(v.web)
		return l;
	own := "Zoom+" :: "Zoom-" :: "Fit" :: nil;
	if(len v.sizes > 1)
		own = "Zoom+" :: "Zoom-" :: "Fit" :: "PrevPage" :: "NextPage" :: nil;
	r: list of string;
	for(; own != nil; own = tl own)
		r = hd own :: r;
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return l;
}

# ---- little things ----

split(e: string): (string, string)
{
	for(i := 0; i < len e; i++)
		if(e[i] == ' ')
			return (e[0:i], e[i+1:]);
	return (e, "");
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

contains(s, t: string): int
{
	if(len t == 0)
		return 1;
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}
