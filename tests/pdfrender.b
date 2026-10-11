implement Pdfrender;

#
# pdfrender [-n reps] file.pdf page dpi out.img
#
# Page (from 1) of a PDF rendered by pdf(2) at dpi, written as an
# Inferno image, with the time it took: for measuring the renderer
# against a reference (Poppler's pdftoppm) and against itself. With
# -n, rendered reps times: the first time and the fastest given. Prints
#	pages N size WxH ms T first F
# and each memory pool's use afterwards and its high water mark
# (#c/memory: main, heap, image), in kilobytes.
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
	first := -1;
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
		if(first < 0)
			first = t;
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
	sys->print("pages %d size %dx%d ms %d first %d\n", doc.pagecount(), im.r.dx(), im.r.dy(), best, first);
	mem := readfile("#c/memory");
	if(mem != nil){
		(nil, lines) := sys->tokenize(string mem, "\n");
		for(; lines != nil; lines = tl lines){
			(nil, f) := sys->tokenize(hd lines, " \t");
			# cursize maxsize highwater nalloc nfree nbrk ... name
			if(len f >= 8)
				sys->print("pool %s now %d high %d\n", hd tl tl tl tl tl tl tl f,
					int hd f / 1024, int hd tl tl f / 1024);
		}
	}
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[0] of byte;
	buf := array[65536] of byte;
	while((m := sys->read(fd, buf, len buf)) > 0){
		nb := array[len b + m] of byte;
		nb[0:] = b;
		nb[len b:] = buf[0:m];
		b = nb;
	}
	if(len b == 0)
		return nil;
	return b;
}
