implement Drawbench;

#
# drawbench - time the draw device on fixed workloads, for A/B tests of
# how it draws (benchmarks/bench-draw.sh runs it on two emulators).
#
#	drawbench [-f frames] [-w workload]...
#
# Each workload draws frames onto a 1600x1000 image in the screen's
# format (x8r8g8b8), waits for the drawing to finish, and prints
#	name  ms-per-frame  checksum
# The checksum is of the final pixels: the same workload must give the
# same checksum whatever draws it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Path, Point, Rect: import draw;
include "math.m";
	math: Math;
include "arg.m";

Drawbench: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

W: con 1600;
H: con 1000;

display: ref Display;
font: ref Font;
frames := 20;

Work: adt {
	name:	string;
	f:	ref fn(img: ref Image, frame: int);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	math = load Math Math->PATH;
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("drawbench [-f frames] [-w workload]...");
	only: list of string;
	while((c := arg->opt()) != 0)
		case c {
		'f' =>	frames = int arg->earg();
		'w' =>	only = arg->earg() :: only;
		* =>	arg->usage();
		}

	display = Display.allocate(nil);
	if(display == nil) {
		sys->fprint(sys->fildes(2), "drawbench: no display: %r\n");
		raise "fail:display";
	}
	font = Font.open(display, "/fonts/combined/unicode.sans.14.font");
	if(font == nil)
		font = Font.open(display, "*default*");

	works := array[] of {
		Work("fill", fills),
		Work("copy", copies),
		Work("alpha", alphas),
		Work("text", texts),
		Work("shapes", shapes),
		Work("lines", lines),
	};
	for(i := 0; i < len works; i++) {
		if(only != nil && !member(works[i].name, only))
			continue;
		run(works[i]);
	}
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

run(w: Work)
{
	img := display.newimage(Rect((0, 0), (W, H)), Draw->XRGB32, 0, int 16r1B2230FF);
	w.f(img, 0);	# warm up: fonts cached, colours allocated
	finish(img);
	img.draw(img.r, display.color(int 16r1B2230FF), nil, (0, 0));
	t0 := sys->millisec();
	for(f := 0; f < frames; f++) {
		w.f(img, f);
		finish(img);
	}
	t := sys->millisec() - t0;
	sys->print("%-8s %6.2f ms %s\n", w.name, real t / real frames, checksum(img));
}

# wait until the image is drawn: reading a pixel waits for the device
finish(img: ref Image)
{
	b := array[4] of byte;
	img.readpixels(Rect((0, 0), (1, 1)), b);
}

checksum(img: ref Image): string
{
	buf := array[W*4] of byte;
	h := big 2166136261;
	for(y := 0; y < H; y++) {
		img.readpixels(Rect((0, y), (W, y+1)), buf);
		for(i := 0; i < len buf; i++)
			h = ((h ^ big buf[i]) * big 16777619) & big 16rFFFFFFFF;
	}
	return sys->sprint("%.8bux", h);
}

colours: array of ref Image;

col(i: int): ref Image
{
	if(colours == nil) {
		v := array[] of {
			int 16rC8452DFF, int 16r2A7AB0FF, int 16r2F7D4FFF, int 16rE8C872FF,
			int 16r5A3FA0FF, int 16rE8ECF2FF, int 16r80404080, int 16r20406080,
		};
		colours = array[len v] of ref Image;
		for(j := 0; j < len v; j++)
			colours[j] = display.newimage(Rect((0, 0), (1, 1)), Draw->RGBA32, 1, v[j]);
	}
	return colours[i % len colours];
}

# large and small opaque and translucent rectangles
fills(img: ref Image, f: int)
{
	for(i := 0; i < 400; i++) {
		x := (i*97 + f*13) % (W - 200);
		y := (i*53 + f*7) % (H - 150);
		s := 10 + (i*31) % 190;
		img.draw(Rect((x, y), (x+s, y+s*2/3)), col(i), nil, (0, 0));
	}
}

# a window-like scroll and blits of image regions
src: ref Image;

copies(img: ref Image, f: int)
{
	if(src == nil) {
		src = display.newimage(Rect((0, 0), (W, H)), Draw->XRGB32, 0, Draw->Black);
		for(i := 0; i < 40; i++)
			src.draw(Rect((i*40, 0), (i*40+20, H)), col(i), nil, (0, 0));
	}
	img.draw(Rect((0, 0), (W, H-8)), img, nil, (0, 8));	# scroll
	for(i := 0; i < 60; i++) {
		x := (i*131 + f*17) % (W - 300);
		y := (i*71) % (H - 200);
		img.draw(Rect((x, y), (x+300, y+200)), src, nil, (i*23 % 500, i*11 % 400));
	}
}

# translucent images over the target: icons and overlays
over: ref Image;

alphas(img: ref Image, f: int)
{
	if(over == nil) {
		over = display.newimage(Rect((0, 0), (128, 128)), Draw->RGBA32, 0, Draw->Transparent);
		over.fillpath(Path.new().ellipse(64.0, 64.0, 60.0, 60.0), ~0, col(6), (0, 0));
		over.strokepath(Path.new().ellipse(64.0, 64.0, 50.0, 30.0), 6.0, Draw->Capbutt, Draw->Joinround, col(7), (0, 0));
	}
	for(i := 0; i < 300; i++) {
		x := (i*89 + f*11) % (W - 128);
		y := (i*37 + f*5) % (H - 128);
		img.draw(Rect((x, y), (x+128, y+128)), over, nil, (0, 0));
	}
}

texts(img: ref Image, f: int)
{
	for(i := 0; i < 60; i++) {
		p := Point(10 + (i*37 + f) % 400, 10 + i*16);
		img.text(p, col(i), (0, 0), font, "The quick brown fox jumps over the lazy dog 0123456789 — scene labels, Tk, Lucifer");
	}
}

# anti-aliased discs, rings, polygons and polylines (lib/scene's shapes)
shapes(img: ref Image, f: int)
{
	for(i := 0; i < 300; i++) {
		cx := real ((i*97 + f*3) % W);
		cy := real ((i*53 + f*2) % H);
		r := 3.0 + real (i % 20);
		img.fillpath(Path.new().ellipse(cx, cy, r, r), ~0, col(i), (0, 0));
		img.strokepath(Path.new().ellipse(cx, cy, r + 2.0, r + 2.0), 1.5, Draw->Capbutt, Draw->Joinround, col(i+1), (0, 0));
	}
	for(i = 0; i < 40; i++) {
		p := Path.new().moveto(real (i*37 % W), real (i*53 % H));
		for(k := 1; k < 20; k++)
			p.lineto(real ((i*37 + k*41 + f) % W), real ((i*53 + k*29) % H));
		img.strokepath(p, 2.0, Draw->Capround, Draw->Joinround, col(i), (0, 0));
	}
}

# Draw's own lines: thin and thick, every angle
lines(img: ref Image, f: int)
{
	c := Point(W/2, H/2);
	for(i := 0; i < 360; i += 2) {
		t := real (i + f) * Math->Pi / 180.0;
		p := c.add((int (450.0*math->cos(t)), int (450.0*math->sin(t))));
		img.line(c, p, Draw->Endsquare, Draw->Endsquare, i % 3, col(i), (0, 0));
	}
}
