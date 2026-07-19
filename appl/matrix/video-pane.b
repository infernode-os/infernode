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
# The pane is a pure VIEW: vid9p owns the transport (playhead, state)
# server-side, and the pane renders whatever frame `pos` in <mount>/status
# says — so every viewer of a stream shows the same, synchronised frame,
# and anything that can write a file drives playback:
#
#     echo pause > /mnt/video/0/ctl        # sh
#     echo 'seek +5000' > /mnt/video/0/ctl
#
# The video-ctl Tk module is those writes as buttons; compose it beside
# this pane on the same mount (see the video-player crystallisation).
# Keys routed to the focused pane forward down the SAME wire:
# space = play/pause, s = stop, arrows = seek 5s.
#
# The pane exports the optional MatrixTicker interface so the runtime
# drives update() at frame cadence.  A status strip along the pane's
# bottom edge shows state and position.
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

include "keyboard.m";

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
	interval:	fn(): int;
};

# MatrixTicker probe: run update() at frame cadence.  Called on a
# fresh uninitialised instance — must stay a pure constant.
interval(): int
{
	return 40;
}

display_g: ref Display;
font_g: ref Font;
mountpath: string;
r_g: Rect;

# stream geometry (0 until fmt has been read)
vw, vh, vrate, framesize: int;

ffd: ref Sys->FD;		# open handle on <mount>/frame
sfd: ref Sys->FD;		# open handle on <mount>/status
cfd: ref Sys->FD;		# open handle on <mount>/ctl (transport writes)
frame: ref Image;		# RGB24 staging image, native video size
buf: array of byte;		# one I420 frame
haveframe: int;			# a frame has been decoded into `frame`

lastshown := -1;
statestr := "";

bgcolor: ref Image;
bordercol: ref Image;
dimcol: ref Image;

PAD: con 6;
STRIPH: con 14;			# transport status strip height

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
	if(sfd == nil)
		sfd = sys->open(mountpath + "/status", Sys->OREAD);
	return ffd != nil;
}

# Parse <mount>/status: "<src> w= h= framesize= frames= eof= state= pos= t= follow=".
# Returns (streaming, frames, playing, pos, tms, follow); frames <= 0 when unreadable.
readstatus(): (int, int, int, int, int, int)
{
	if(sfd == nil)
		return (0, -1, 0, 0, 0, 0);
	b := array[256] of byte;
	n := sys->pread(sfd, b, len b, big 0);
	if(n <= 0)
		return (0, -1, 0, 0, 0, 0);
	strm := 0;
	nf := -1;
	playing := 0;
	pos := 0;
	tms := 0;
	fol := 0;
	(nil, toks) := sys->tokenize(string b[0:n], " \t\n");
	if(toks != nil && hd toks == "streaming")
		strm = 1;
	for(; toks != nil; toks = tl toks) {
		t := hd toks;
		if(len t > 7 && t[0:7] == "frames=")
			nf = int t[7:];
		else if(len t > 6 && t[0:6] == "state=")
			playing = t[6:] == "playing";
		else if(len t > 4 && t[0:4] == "pos=")
			pos = int t[4:];
		else if(len t > 2 && t[0:2] == "t=")
			tms = int t[2:];
		else if(len t > 7 && t[0:7] == "follow=")
			fol = int t[7:];
	}
	return (strm, nf, playing, pos, tms, fol);
}

# Transport commands go to the server's ctl file — the same wire a
# video-ctl Tk button or `echo ... > ctl` from sh uses.
ctl(cmd: string)
{
	if(cfd == nil)
		cfd = sys->open(mountpath + "/ctl", Sys->OWRITE);
	if(cfd == nil)
		return;
	b := array of byte cmd;
	sys->write(cfd, b, len b);
}

# Fetch frame idx into `frame` via pread — the frame file is random
# access, which is what makes seek/pause/live-edge all client-side.
showframe(idx: int): int
{
	if(idx < 0)
		return 0;
	off := big idx * big framesize;
	got := 0;
	while(got < framesize) {
		n := sys->pread(ffd, buf[got:], framesize-got, off + big got);
		if(n <= 0)
			return 0;
		got += n;
	}
	wh := vw*vh;
	cw := vw/2; ch := vh/2; csz := cw*ch;
	p := ref YCbCr(buf[0:wh], buf[wh:wh+csz], buf[wh+csz:wh+2*csz]);
	frame.writepixels(Rect((0,0),(vw,vh)), remap->remap(p));
	haveframe = 1;
	lastshown = idx;
	return 1;
}

setstate(strm, nf, playing, tms, fol: int)
{
	p := "";
	if(vrate > 0 && nf >= 0)
		p = sys->sprint("%ds/%ds", tms/1000, nf/vrate);
	mode := "paused";
	if(strm && fol && playing)
		mode = "LIVE";
	else if(strm && fol)
		mode = "live paused";
	else if(strm && playing)
		mode = "replay";
	else if(strm)
		mode = "replay paused";
	else if(playing)
		mode = "playing";
	statestr = mode + " " + p + "   space=pause s=stop arrows=seek";
}

resize(r: Rect)
{
	r_g = r;
}

update(): int
{
	if(!ensureopen())
		return 0;
	(strm, nf, playing, pos, tms, fol) := readstatus();
	if(nf <= 0)
		return 0;
	was := statestr;
	changed := 0;
	if(pos != lastshown && pos < nf && showframe(pos))
		changed = 1;
	setstate(strm, nf, playing, tms, fol);
	return changed || statestr != was;
}

draw(dst: ref Image)
{
	if(dst == nil)
		return;
	dst.draw(r_g, bgcolor, nil, (0,0));

	# video area = pane minus the transport strip along the bottom
	vidr := r_g;
	if(vidr.dy() > 3*STRIPH)
		vidr.max.y -= STRIPH;

	if(font_g != nil && statestr != "") {
		pt := Point(r_g.min.x + PAD, r_g.max.y - STRIPH + 1);
		dst.text(pt, dimcol, (0,0), font_g, fitstr(statestr, r_g.dx() - 2*PAD));
	}

	if(!haveframe || frame == nil) {
		# No frame yet: a quiet placeholder so an empty feed is legible.
		if(font_g != nil) {
			msg := "no video";
			pt := Point(r_g.min.x + PAD, r_g.min.y + PAD);
			dst.text(pt, dimcol, (0,0), font_g, msg);
		}
		return;
	}

	# Centre the native-size frame in the video area, then clip to it
	# so an oversized frame never bleeds into neighbours.
	offx := vidr.min.x + (vidr.dx() - vw)/2;
	offy := vidr.min.y + (vidr.dy() - vh)/2;
	pane := Rect((offx,offy), (offx+vw, offy+vh));
	ir := intersect(pane, vidr);
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

# Truncate s to fit maxw pixels in the pane's font — a narrow pane
# shows the state and position and loses the key legend, not the edge
# of the neighbouring pane.
fitstr(s: string, maxw: int): string
{
	if(font_g == nil || font_g.width(s) <= maxw)
		return s;
	while(len s > 1 && font_g.width(s + "..") > maxw)
		s = s[0:len s - 1];
	return s + "..";
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

# Transport keys, routed by Matrix to the focused pane; each forwards
# down the same ctl wire the video-ctl buttons and sh use.
key(k: int): int
{
	case k {
	' ' =>
		(nil, nil, playing, nil, nil, nil) := readstatus();
		if(playing)
			ctl("pause");
		else
			ctl("play");
	's' =>
		ctl("stop");
	Keyboard->Left =>
		ctl("seek -5000");
	Keyboard->Right =>
		ctl("seek +5000");
	* =>
		return 0;
	}
	return 1;
}

retheme(display: ref Display)
{
	display_g = display;
	loadcolors();
}

shutdown()
{
	ffd = nil;
	sfd = nil;
	cfd = nil;
	frame = nil;
	buf = nil;
	haveframe = 0;
}
