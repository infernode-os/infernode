implement Scap;

#
# scap - dump the live display screen image to a file in Inferno image
# format (decode on the host with tools/p9img2png.py).  Dev/debug tool
# for driving and screenshotting the GUI headlessly.
#
# Usage: scap [outfile]   (default /scap.img)
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;

Scap: module
{
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;

	out := "/scap.img";
	if(args != nil && tl args != nil)
		out = hd tl args;

	status(sys->sprint("start ctxt=%d", ctxt != nil));

	disp: ref Display;
	if(ctxt != nil && ctxt.display != nil)
		disp = ctxt.display;
	else
		disp = Display.allocate(nil);
	if(disp == nil) {
		status("no display (allocate returned nil)");
		return;
	}
	img := disp.image;
	if(img == nil) {
		status("display.image is nil");
		return;
	}
	status(sys->sprint("display %dx%d, creating %s", img.r.dx(), img.r.dy(), out));
	fd := sys->create(out, Sys->OWRITE, 8r666);
	if(fd == nil) {
		status(sys->sprint("cannot create %s: %r", out));
		return;
	}
	if(disp.writeimage(fd, img) < 0)
		status(sys->sprint("writeimage failed: %r"));
	else
		status(sys->sprint("wrote %s %dx%d", out, img.r.dx(), img.r.dy()));
}

status(msg: string)
{
	sys->fprint(sys->fildes(2), "scap: %s\n", msg);
	fd := sys->create("/scap.status", Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%s\n", msg);
}
