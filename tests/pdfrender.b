implement Pdfrender;

#
# pdfrender [-n reps] file.pdf page dpi out.img
#
# Page (from 1) of a PDF rendered by pdf(2) at dpi, written as an
# Inferno image, with the time it took: for measuring the renderer
# against a reference (Poppler's pdftoppm) and against itself. With
# -n, rendered reps times and the fastest time given. Prints
#	pages N size WxH ms T
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect: import draw;

include "pdf.m";
	pdf: PDF;
	Doc: import pdf;

Pdfrender: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr := sys->fildes(2);
	args = tl args;
	reps := 1;
	if(args != nil && hd args == "-n" && tl args != nil){
		reps = int hd tl args;
		args = tl tl args;
	}
	if(len args != 4){
		sys->fprint(stderr, "usage: pdfrender [-n reps] file.pdf page dpi out.img\n");
		raise "fail:usage";
	}
	file := hd args;
	page := int hd tl args;
	dpi := int hd tl tl args;
	out := hd tl tl tl args;

	display := Display.allocate(nil);
	if(display == nil){
		sys->fprint(stderr, "pdfrender: no display: %r\n");
		raise "fail:display";
	}
	pdf = load PDF PDF->PATH;
	if(pdf == nil || (err := pdf->init(display)) != nil){
		sys->fprint(stderr, "pdfrender: cannot load pdf: %r %s\n", err);
		raise "fail:pdf";
	}
	data := readfile(file);
	if(data == nil){
		sys->fprint(stderr, "pdfrender: cannot read %s: %r\n", file);
		raise "fail:read";
	}
	(doc, oerr) := pdf->open(data, nil);
	if(doc == nil){
		sys->fprint(stderr, "pdfrender: %s: %s\n", file, oerr);
		raise "fail:open";
	}
	best := -1;
	im: ref Image;
	for(i := 0; i < reps; i++){
		t0 := sys->millisec();
		(r, rerr) := doc.renderpage(page, dpi);
		t := sys->millisec() - t0;
		if(r == nil){
			sys->fprint(stderr, "pdfrender: page %d: %s\n", page, rerr);
			raise "fail:render";
		}
		im = r;
		if(rerr != nil && i == 0)
			sys->fprint(stderr, "pdfrender: page %d: %s\n", page, rerr);
		if(best < 0 || t < best)
			best = t;
	}
	fd := sys->create(out, Sys->OWRITE, 8r644);
	if(fd == nil){
		sys->fprint(stderr, "pdfrender: cannot create %s: %r\n", out);
		raise "fail:create";
	}
	if(display.writeimage(fd, im) < 0){
		sys->fprint(stderr, "pdfrender: writeimage: %r\n");
		raise "fail:write";
	}
	sys->print("pages %d size %dx%d ms %d\n", doc.pagecount(), im.r.dx(), im.r.dy(), best);
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok != 0)
		return nil;
	n := int d.length;
	b := array[n] of byte;
	for(t := 0; t < n; ){
		m := sys->read(fd, b[t:], n - t);
		if(m <= 0)
			return nil;
		t += m;
	}
	return b;
}
