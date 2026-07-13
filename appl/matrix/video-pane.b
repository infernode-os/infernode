implement VideoPane;

#
# video-pane - Matrix display module that renders a decoded video feed.
#
# Sources tightly-packed planar I420 frames from a vid9p stream directory
# (see appl/cmd/vid9p.b / docs/H264-9P-BRIDGE.md):
#     <mount>/fmt    -> "<w> <h> i420 <fps>"
#     <mount>/frame  -> the I420 stream; each w*h*3/2 bytes is one frame.
# Frames are wrapped as Mpegio->YCbCr and pushed through the SAME remap24
# (YCbCr->RGB24) path vidplay/vidplay9p use, so there is no new pixel code
# here: the frame is composited natively-sized and centred into the pane,
# clipped to the pane rectangle. Multiplex = one video-pane leaf per feed.
#
# Composition usage (a leaf naming this module + its stream mount):
#     ... video-pane /mnt/video/0
#
# The Matrix runtime drives playback: it calls update() on its refresh
# cadence (one decoded frame is pulled per update) and draw() to composite.
# A canned clip loops; a live feed plays as frames arrive.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect: import drawm;

include "mpegio.m";
	mio: Mpegio;
	Mpegi, YCbCr: import mio;

remap: Remap;

include "lucitheme.m";

include "matrix.m";

VideoPane: module
{
	init:	fn(display: ref Display, font: ref Font, mount: string): string;
	resize:	fn(r: Rect);
	update:	fn(): int;
	draw:	fn(dst: ref Image);
	pointer:	fn(p: ref Draw->Pointer): int;
	key:	fn(k: int): int;
	retheme:	fn(display: ref Display);
	shutdown:	fn();
};

display_g: ref Display;
font_g: ref Font;
mountpath: string;
r_g: Rect;

# stream geometry (0 until fmt has been read)
vw, vh, vrate, framesize: int;

ffd: ref Sys->FD;		# open handle on <mount>/frame
frame: ref Image;		# RGB24 staging image, native video size
buf: array of byte;		# one I420 frame
haveframe: int;			# a frame has been decoded into `frame`

bgcolor: ref Image;
bordercol: ref Image;
dimcol: ref Image;

PAD: con 6;

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	mio = load Mpegio Mpegio->PATH;
	if(mio == nil)
		return sys->sprint("cannot load %s: %r", Mpegio->PATH);
	remap = load Remap Remap->PATH24;
	if(remap == nil)
		return sys->sprint("cannot load %s: %r", Remap->PATH24);
	mio->init();

	display_g = display;
	font_g = font;
	mountpath = mount;
	haveframe = 0;
	loadcolors();

	# fmt/frame may not be ready yet (the feed can start after the pane);
	# ensureopen() retries lazily from update(), so a missing source here
	# is not fatal.
	ensureopen();
	return nil;
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgcolor   = display_g.color(th.bg);
		bordercol = display_g.color(th.border);
		dimcol    = display_g.color(th.dim);
	} else {
		bgcolor   = display_g.color(int 16r000000FF);
		bordercol = display_g.color(int 16r333355FF);
		dimcol    = display_g.color(int 16r888888FF);
	}
}

# Read "<w> <h> i420 <fps>" from <mount>/fmt. Returns 1 on success.
readfmt(): int
{
	fd := sys->open(mountpath + "/fmt", Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return 0;
	(nt, toks) := sys->tokenize(string b[0:n], " \t\n");
	if(nt < 4)
		return 0;
	w := int hd toks; toks = tl toks;
	h := int hd toks; toks = tl toks;
	toks = tl toks;			# skip "i420"
	rate := int hd toks;
	if(w <= 0 || h <= 0)
		return 0;
	if(rate <= 0 || rate > 120)
		rate = 25;
	vw = w; vh = h; vrate = rate;
	framesize = w*h + 2*(w/2)*(h/2);
	return 1;
}

# Ensure fmt is known and <mount>/frame is open, allocating the staging
# image and buffer once geometry is known. Idempotent; safe to call every
# update. Returns 1 when a frame can be read.
ensureopen(): int
{
	if(vw <= 0 || vh <= 0) {
		if(!readfmt())
			return 0;
		m := ref Mpegi;
		m.width = vw; m.height = vh;
		remap->init(m);
		frame = display_g.newimage(Rect((0,0),(vw,vh)), drawm->RGB24, 0, drawm->Black);
		buf = array[framesize] of byte;
	}
	if(ffd == nil)
		ffd = sys->open(mountpath + "/frame", Sys->OREAD);
	return ffd != nil;
}

readfull(fd: ref Sys->FD, b: array of byte): int
{
	got := 0;
	while(got < len b) {
		n := sys->read(fd, b[got:], len b - got);
		if(n <= 0)
			return 0;
		got += n;
	}
	return 1;
}

resize(r: Rect)
{
	r_g = r;
}

update(): int
{
	if(!ensureopen())
		return 0;
	if(!readfull(ffd, buf)) {
		# EOF / short read: rewind a canned clip and try once more so
		# looping feeds keep playing. A live feed that has genuinely
		# stopped will just fail the reopen and hold the last frame.
		ffd = sys->open(mountpath + "/frame", Sys->OREAD);
		if(ffd == nil || !readfull(ffd, buf))
			return 0;
	}
	wh := vw*vh;
	cw := vw/2; ch := vh/2; csz := cw*ch;
	p := ref YCbCr(buf[0:wh], buf[wh:wh+csz], buf[wh+csz:wh+2*csz]);
	frame.writepixels(Rect((0,0),(vw,vh)), remap->remap(p));
	haveframe = 1;
	return 1;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;
	dst.draw(r_g, bgcolor, nil, (0,0));

	if(!haveframe || frame == nil) {
		# No frame yet: a quiet placeholder so an empty feed is legible.
		if(font_g != nil) {
			msg := "no video";
			pt := Point(r_g.min.x + PAD, r_g.min.y + PAD);
			dst.text(pt, dimcol, (0,0), font_g, msg);
		}
		return;
	}

	# Centre the native-size frame in the pane, then clip to the pane
	# rectangle so an oversized frame never bleeds into neighbours.
	offx := r_g.min.x + (r_g.dx() - vw)/2;
	offy := r_g.min.y + (r_g.dy() - vh)/2;
	pane := Rect((offx,offy), (offx+vw, offy+vh));
	ir := intersect(pane, r_g);
	if(ir.dx() <= 0 || ir.dy() <= 0)
		return;
	# source point in frame space aligned to ir.min
	sp := Point(ir.min.x - pane.min.x, ir.min.y - pane.min.y);
	dst.draw(ir, frame, nil, sp);

	# thin border so the pane reads as a framed feed
	dst.draw(Rect((r_g.min.x, r_g.min.y), (r_g.max.x, r_g.min.y+1)), bordercol, nil, (0,0));
	dst.draw(Rect((r_g.min.x, r_g.max.y-1), (r_g.max.x, r_g.max.y)), bordercol, nil, (0,0));
	dst.draw(Rect((r_g.min.x, r_g.min.y), (r_g.min.x+1, r_g.max.y)), bordercol, nil, (0,0));
	dst.draw(Rect((r_g.max.x-1, r_g.min.y), (r_g.max.x, r_g.max.y)), bordercol, nil, (0,0));
}

intersect(a, b: Rect): Rect
{
	if(a.min.x < b.min.x) a.min.x = b.min.x;
	if(a.min.y < b.min.y) a.min.y = b.min.y;
	if(a.max.x > b.max.x) a.max.x = b.max.x;
	if(a.max.y > b.max.y) a.max.y = b.max.y;
	return a;
}

pointer(nil: ref Draw->Pointer): int { return 0; }
key(nil: int): int { return 0; }

retheme(display: ref Display)
{
	display_g = display;
	loadcolors();
}

shutdown()
{
	ffd = nil;
	frame = nil;
	buf = nil;
	haveframe = 0;
}
