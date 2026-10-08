implement Charonshot;

#
# charonshot - render one URL with Charon, headlessly, to an image file.
#
#	charonshot [-o] [-d] width[xheight] outimg url
#
# Renders with the new engine (page(2): parse, style, lay out, paint)
# or, with -o, drives the old Charon's -render mode.  -d prints the box
# tree (kind node x y w h) on standard error.  With just a
# width the canvas is up to Maxheight tall and the image is cropped to the
# page, so long pages are captured whole; with widthxheight the viewport is
# exactly that and the whole of it is written, as for conformance
# fixtures.  Extracted page text lands in outimg+".txt".
#
# Host wrapper: tools/charon-shot.sh (decodes the image to PNG).
# When run as emu's initial program it halts the emulator when done,
# since Charon's helper processes would otherwise keep it alive.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "web/dom.m";
	dom: Dom;
	Doc: import dom;
include "web/css.m";
include "web/style.m";
include "outlinefont.m";
include "web/fonts.m";
include "web/layout.m";
include "web/page.m";
	layout: Layout;
	page: Page;
	Pg: import page;

Charonshot: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

CharonMod: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Maxheight: con 12000;
dumpboxes := 0;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr := sys->fildes(2);

	argv = tl argv;
	old := 0;
	while(argv != nil && len hd argv == 2 && (hd argv)[0] == '-') {
		case hd argv {
		"-o" => old = 1;
		"-d" => dumpboxes = 1;
		"-b" => dumpboxes = 2;
		"-c" => dumpboxes = 3;
		}
		argv = tl argv;
	}
	if(len argv != 3) {
		sys->fprint(stderr, "usage: charonshot [-o] width[xheight] outimg url\n");
		halt();
		raise "fail:usage";
	}
	width := hd argv;
	height := string Maxheight;
	crop := "1";
	for(i := 0; i < len width; i++)
		if(width[i] == 'x') {
			height = width[i+1:];
			width = width[0:i];
			crop = "0";
			break;
		}
	outimg := hd tl argv;
	url := hd tl tl argv;

	disp := Display.allocate(nil);
	if(disp == nil) {
		sys->fprint(stderr, "charonshot: no display: %r\n");
		halt();
		raise "fail:display";
	}
	if(!old) {
		err := newengine(disp, int width, int height, crop == "1", outimg, url);
		if(err != nil)
			sys->fprint(stderr, "charonshot: %s\n", err);
		halt();
		return;
	}
	ch := load CharonMod "/dis/charon.dis";
	if(ch == nil) {
		sys->fprint(stderr, "charonshot: cannot load charon: %r\n");
		halt();
		raise "fail:load";
	}
	args := "charon" :: "-render" :: "1"
		:: "-renderout" :: outimg
		:: "-defaultwidth" :: width
		:: "-defaultheight" :: height
		:: "-rendercrop" :: crop
		:: "-doscripts" :: "0"
		:: url :: nil;
	# Charon's render path ends in finish(), which exits the process
	# rather than returning, so wait for the child to go away.
	wfd := sys->open(sys->sprint("/prog/%d/wait", sys->pctl(0, nil)), Sys->OREAD);
	spawn run(ch, ref Draw->Context(disp, nil, nil), args);
	if(wfd != nil) {
		buf := array[256] of byte;
		n := sys->read(wfd, buf, len buf);
		if(n > 0) {
			# "pid module status"; status is empty on a clean exit
			(nil, fl) := sys->tokenize(string buf[0:n], " ");
			if(len fl > 2 && len hd tl tl fl > 2)
				sys->fprint(stderr, "charonshot: %s\n", string buf[0:n]);
		}
	}
	halt();
}

run(ch: CharonMod, ctxt: ref Draw->Context, args: list of string)
{
	sys->pctl(Sys->NEWPGRP, nil);
	ch->init(ctxt, args);
}

Command: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

# http(s) comes through webfs; start one if there isn't one already.
startwebfs(): string
{
	if(webfsup())
		return nil;
	webfs := load Command "/dis/webfs.dis";
	if(webfs == nil)
		return sys->sprint("cannot load webfs: %r");
	spawn webfs->init(nil, "webfs" :: nil);
	for(i := 0; i < 100; i++) {
		if(webfsup())
			return nil;
		sys->sleep(20);
	}
	return "webfs did not start";
}

newengine(disp: ref Display, w, h, crop: int, outimg, url: string): string
{
	page = load Page Page->PATH;
	if(page == nil)
		return sys->sprint("cannot load %s: %r", Page->PATH);
	if((ierr := page->init(disp)) != nil)
		return ierr;
	layout = load Layout Layout->PATH;
	dom = load Dom Dom->PATH;
	layout->init(disp);
	if(len url > 4 && url[0:4] == "http" && (werr := startwebfs()) != nil)
		return werr;
	vh := h;
	if(crop)
		vh = 768;	# a viewport for vh units; the image is the page
	t0 := sys->millisec();
	(p, err) := page->open(url, w, vh);
	if(p == nil)
		return err;
	t1 := sys->millisec();
	if(crop) {
		h = p.pageheight();
		if(h < 1)
			h = 1;
		if(h > Maxheight)
			h = Maxheight;
	}
	img := disp.newimage(Rect((0, 0), (w, h)), Draw->XRGB32, 0, Draw->White);
	if(img == nil)
		return sys->sprint("cannot allocate %dx%d image: %r", w, h);
	scroll := 0;
	if(!crop)
		scroll = fragscroll(p, url);
	p.paint(img, Point(0, scroll));
	if(dumpboxes == 1)
		sys->fprint(sys->fildes(2), "%s", layout->dump(p.root));
	else if(dumpboxes == 2)
		elementboxes(p);
	else if(dumpboxes == 3)
		linkhits(p);
	t2 := sys->millisec();
	fd := sys->create(outimg, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", outimg);
	if(disp.writeimage(fd, img) < 0)
		return sys->sprint("writeimage: %r");
	for(l := p.errors; l != nil; l = tl l)
		sys->fprint(sys->fildes(2), "charonshot: %s\n", hd l);
	if(sys->open("/env/charonshot-timing", Sys->OREAD) != nil)
		sys->fprint(sys->fildes(2), "load+layout %d ms, paint %d ms\n", t1-t0, t2-t1);
	return nil;
}

halt()
{
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "halt");
}

# a webfs is mounted there, not merely a file by that name
webfsup(): int
{
	(ok, d) := sys->stat("/mnt/web/clone");
	return ok >= 0 && d.dtype == 'M';
}

# Each element's border box (the union of its boxes), by its path,
# as tools/ref/boxdiff.py compares with Chromium's:
#	B /html[1]/body[1]/div[2] x y w h
elementboxes(p: ref Pg)
{
	d := p.doc;
	out := sys->fildes(1);
	paths := array[d.n] of string;
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Element)
			continue;
		k := 1;
		for(s := nd.prev; s != 0; s = d.nodes[s].prev)
			if(d.nodes[s].kind == Dom->Element && d.nodes[s].name == nd.name)
				k++;
		pp := "";
		if(nd.parent > 1)
			pp = paths[nd.parent];
		paths[n] = pp + "/" + nd.name + "[" + string k + "]";
		r: Rect;
		got := 0;
		for(l := layout->boxes(p.root, n); l != nil; l = tl l) {
			b := hd l;
			x := 0;
			y := 0;
			for(a := b; a != nil; a = a.parent) {
				x += a.x;
				y += a.y;
			}
			br := Rect((x, y), (x + b.w, y + b.h));
			if(b.kind == Layout->Kinline && b.w == 0 && b.h == 0) {
				(ok, ir) := inlinerect(b);
				if(!ok)
					continue;
				br = ir;
			}
			if(!got)
				r = br;
			else
				r = r.combine(br);
			got = 1;
		}
		if(got)
			sys->fprint(out, "B %s %d %d %d %d\n", paths[n], r.min.x, r.min.y, r.dx(), r.dy());
		else
			sys->fprint(out, "B %s none\n", paths[n]);
	}
}

# -c: would a click on each link find it?  For every a[href], a point
# inside its first piece (its first fragment, if it is inline) is looked
# up with boxat, as the window's click is, and must lead back to a link.
# Prints "links <hit>/<total>" and each miss.
linkhits(p: ref Pg)
{
	d := p.doc;
	out := sys->fildes(1);
	hit := 0;
	total := 0;
	for(n := 1; n < d.n; n++) {
		nd := d.nodes[n];
		if(nd.kind != Dom->Element || nd.ns != Dom->HTML || nd.tag != Dom->Ta || !d.hasattr(n, "href"))
			continue;
		(ok, r) := firstpiece(p, n);
		if(!ok || r.dx() <= 0 || r.dy() <= 0 || hidden(p, n))
			continue;	# not shown: nothing to click
		pt := Point(r.min.x + r.dx()/2, r.min.y + r.dy()/2);
		if(clipped(p, n, pt))
			continue;	# cut off by an ancestor that clips its overflow: not there to click
		total++;
		(m, nil) := layout->boxat(p.root, pt);
		got := 0;
		for(a := m; a > 1; a = d.nodes[a].parent)
			if(d.nodes[a].kind == Dom->Element && d.nodes[a].tag == Dom->Ta && d.hasattr(a, "href")) {
				got = a;
				break;
			}
		if(got == n)
			hit++;
		else {
			what := "nothing";
			if(m > 0) {
				e := m;
				if(d.nodes[e].kind != Dom->Element)
					e = d.nodes[e].parent;
				what = d.nodes[e].name + "." + d.attr(e, "class");
			}
			if(got != 0)
				what += " in another link";
			sys->fprint(out, "miss %d %s at %d,%d -> %s: %s\n", n, d.attr(n, "href"), pt.x, pt.y, what, d.textof(n));
		}
	}
	sys->fprint(out, "links %d/%d\n", hit, total);
}

# pt is outside some ancestor of n's box that clips its overflow (a
# collapsed dropdown: height 0, overflow hidden)
clipped(p: ref Pg, n: int, pt: Point): int
{
	l := layout->boxes(p.root, n);
	if(l == nil)
		return 0;
	for(b := (hd l).parent; b != nil && b.parent != nil && b.parent.parent != nil; b = b.parent) {
		if(b.st.overflowx == Style->Ovisible && b.st.overflowy == Style->Ovisible)
			continue;
		x := 0;
		y := 0;
		for(a := b; a != nil; a = a.parent) {
			x += a.x;
			y += a.y;
		}
		if(!pt.in(Rect((x, y), (x + b.w, y + b.h))))
			return 1;
	}
	return 0;
}

# invisible, or under an ancestor of no opacity: no browser clicks it
hidden(p: ref Pg, n: int): int
{
	l := layout->boxes(p.root, n);
	if(l == nil)
		return 1;
	b := hd l;
	if(b.st.visibility != Style->Vvisible)
		return 1;
	for(; b != nil; b = b.parent)
		if(b.st.opacity == 0.0)
			return 1;
	return 0;
}

firstpiece(p: ref Pg, n: int): (int, Rect)
{
	# a block's own box is its biggest: its pseudo-elements' boxes
	# carry its node too (a:before { left: -9999px } on python.org)
	best: Rect;
	got := 0;
	for(l := layout->boxes(p.root, n); l != nil; l = tl l) {
		b := hd l;
		x := 0;
		y := 0;
		for(a := b; a != nil; a = a.parent) {
			x += a.x;
			y += a.y;
		}
		if(b.kind != Layout->Kinline) {
			if(!got || b.w * b.h > best.dx() * best.dy())
				best = Rect((x, y), (x + b.w, y + b.h));
			got = 1;
			continue;
		}
		for(a = b.parent; a != nil; a = a.parent) {
			if(a.lines == nil)
				continue;
			ax := 0;
			ay := 0;
			for(c := a; c != nil; c = c.parent) {
				ax += c.x;
				ay += c.y;
			}
			for(i := 0; i < len a.lines; i++) {
				ln := a.lines[i];
				for(j := 0; j < len ln.frags; j++) {
					f := ln.frags[j];
					if(f.box == b && f.w > 0) {
						if(f.h > 0)	# its own height: a superscript is raised above the line's middle
							return (1, Rect((ax + f.x, ay + f.y), (ax + f.x + f.w, ay + f.y + f.h)));
						return (1, Rect((ax + f.x, ay + ln.y), (ax + f.x + f.w, ay + ln.y + ln.h)));
					}
				}
			}
			break;
		}
	}
	return (got, best);
}

# An inline box's extent: its fragments in the lines of the block
# that holds them.
inlinerect(b: ref Layout->Box): (int, Rect)
{
	r: Rect;
	got := 0;
	for(a := b.parent; a != nil; a = a.parent) {
		if(a.lines == nil)
			continue;
		ax := 0;
		ay := 0;
		for(c := a; c != nil; c = c.parent) {
			ax += c.x;
			ay += c.y;
		}
		for(i := 0; i < len a.lines; i++) {
			ln := a.lines[i];
			for(j := 0; j < len ln.frags; j++) {
				f := ln.frags[j];
				if(f.box != b)
					continue;
				fr := Rect((ax + f.x, ay + ln.y + f.y), (ax + f.x + f.w, ay + ln.y + f.y + f.h));
				if(f.h == 0)
					fr.max.y = ay + ln.y + ln.h;
				if(!got)
					r = fr;
				else
					r = r.combine(fr);
				got = 1;
			}
		}
		if(got)
			break;
	}
	return (got, r);
}

# a URL's #fragment scrolls to its target, as in the window
fragscroll(p: ref Pg, url: string): int
{
	for(i := 0; i < len url; i++)
		if(url[i] == '#')
			return p.target(url[i+1:]);
	return 0;
}
