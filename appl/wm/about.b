implement About;

#
# About InferNode — Tk version.
#
# Shows the InferNode logo, version and project info using the
# reintegrated Tk toolkit (tkclient + Tk widgets) styled by the brutalist
# Brimstone defaults. The accent title colour and the dimmed URL lines
# are read from lucitheme so they track the active theme; everything else
# inherits the engine defaults, so there are no per-widget colours to
# maintain.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "bufio.m";

include "imagefile.m";

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "lucitheme.m";
	lucitheme: Lucitheme;
	Theme: import lucitheme;

About: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# Desktop cap; on a phone-class screen the window fills with margins.
WINW: con 600;
WINH: con 590;

top: ref Toplevel;
logoimg: ref Image;	# decoded colour logo, blitted onto the window
accentcol: string;	# "#rrggbbff" title accent (from theme)
dimcol:    string;	# "#rrggbbff" URL/footnote colour (from theme)

# (text, dim) pairs — dim=1 lines use the muted colour (URLs). This is the
# built-in default; /lib/lucifer/brand/about.txt overrides it if present.
deflines := array[] of {
	("Inferno® Operating System", 0),
	("Originally by Bell Labs (Lucent)", 0),
	("Vita Nuova Holdings", 0),
	("InferNode fork by infernode-os", 0),
	("lucent.com/inferno", 1),
	("infernode.io", 1),
	("github.com/infernode-os", 1),
};
lines: array of (string, int);	# runtime description, from brandabout()
pname: string;			# product name, from brandname()

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(tkclient == nil){
		sys->fprint(sys->fildes(2), "about: cannot load tkclient: %r\n");
		raise "fail:load tkclient";
	}
	lucitheme = load Lucitheme Lucitheme->PATH;

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "about: no window context\n");
		raise "fail:no context";
	}

	loadtheme();
	pname = brandname();
	lines = brandabout();

	wmctl: chan of string;
	(top, wmctl) = tkclient->toplevel(ctxt,
		sys->sprint("-width %d -height %d", WINW, WINH),
		"About " + pname, Tkclient->Appl);

	build(top.display);

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	# Live theme changes (from Settings / the desktop).
	themech := chan[1] of int;
	spawn themelistener(themech);

	for(;;) alt {
	ctl := <-wmctl or
	ctl = <-top.ctxt.ctl =>
		tkclient->wmctl(top, ctl);
		drawlogo();

	key := <-top.ctxt.kbd =>
		# Ctrl-Q / Del quits; everything else is ignored.
		Kdel: con 16rFF9F;
		if(key == 'q' - 16r60 || key == Kdel)
			return;
		tk->keyboard(top, key);

	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);

	<-themech =>
		loadtheme();
		retheme();
		drawlogo();
	}
}

# Read accent + dim colours from the active theme as Tk colour strings.
loadtheme()
{
	th: ref Theme;
	if(lucitheme != nil)
		th = lucitheme->gettheme();
	if(th == nil)
		th = ref Theme;
	accentcol = col(th.accent >> 8);
	dimcol = col(th.dim >> 8);
}

# lucitheme stores 0xRRGGBB ints; Tk wants "#rrggbbff".
col(v: int): string
{
	return sys->sprint("#%06xff", v & 16rFFFFFF);
}

# Responsive face sizes from the window width.  Faces: 12 14 18 24 32 48.
fonts(ww: int): (string, string)
{
	bp, tp: int;
	if(ww >= 1000)     { bp = 32; tp = 48; }
	else if(ww >= 640) { bp = 18; tp = 32; }
	else if(ww >= 380) { bp = 14; tp = 24; }
	else               { bp = 12; tp = 18; }
	return (face("unicode.sans", bp), face("unicode.sans.bold", tp));
}

face(name: string, px: int): string
{
	return sys->sprint("/fonts/combined/%s.%d.font", name, px);
}

build(display: ref Display)
{
	ww := WINW;
	r := tk->rect(top, ".", 0);
	if(r.dx() > 0)
		ww = r.dx();
	(bodyf, titlef) := fonts(ww);

	cmds := array[] of {
		". configure -background #080808",
		"frame .c -borderwidth 0",
	};
	tkcmds(cmds);

	# Logo (optional — only if the PNG decodes). Reserve a blank frame the
	# size of the logo; drawlogo() paints the real colour image over it.
	if(loadlogo(display))
		tkcmds(array[] of {
			sys->sprint("frame .c.logo -width %d -height %d -background #080808",
				logoimg.r.dx(), logoimg.r.dy()),
			"pack .c.logo -side top -pady 12"});

	# Title.
	tkcmds(array[] of {
		"label .c.title -text {" + pname + "} -foreground " + accentcol +
			" -font " + titlef,
		"pack .c.title -side top -pady {6 2}",
	});

	# Version, from the kernel sysctl.
	version := rf("/dev/sysctl");
	if(version != nil)
		tkcmds(array[] of {
			"label .c.ver -text {" + version + "} -font " + bodyf,
			"pack .c.ver -side top",
		});

	# Accent separator.
	tkcmds(array[] of {
		"frame .c.sep -height 1 -background " + accentcol,
		"pack .c.sep -side top -fill x -padx 40 -pady 12",
	});

	# Description / link lines.
	for(i := 0; i < len lines; i++){
		(text, dim) := lines[i];
		fg := "";
		if(dim)
			fg = " -foreground " + dimcol;
		w := sys->sprint(".c.l%d", i);
		tkcmds(array[] of {
			"label " + w + " -text {" + text + "} -font " + bodyf + fg,
			"pack " + w + " -side top",
		});
	}

	tkcmds(array[] of {"pack .c -fill both -expand 1", "pack propagate . 0"});
	tk->cmd(top, "update");
	drawlogo();
}

# Blit the colour logo onto the window over its reserved frame. Inferno Tk
# only has greyscale images, so — exactly like lucifer's header and the login
# screen — we draw the real colour Draw image straight onto the window. Called
# after every Tk repaint (reshape / expose / theme) so it survives redraws.
drawlogo()
{
	if(logoimg == nil || top == nil || top.image == nil)
		return;
	fr := tk->rect(top, ".c.logo", 0);
	if(fr.dx() <= 0 || fr.dy() <= 0)
		return;
	# tk->rect returns coordinates in the toplevel's on-screen space, but
	# top.image is its own (0,0)-based backing buffer. Convert screen->image
	# by subtracting the root window's origin and re-adding the image origin.
	root := tk->rect(top, ".", 0);
	fx := fr.min.x - root.min.x + top.image.r.min.x;
	fy := fr.min.y - root.min.y + top.image.r.min.y;
	lw := logoimg.r.dx();
	lh := logoimg.r.dy();
	ox := fx + (fr.dx() - lw) / 2;
	oy := fy + (fr.dy() - lh) / 2;
	top.image.draw(Rect((ox, oy), (ox + lw, oy + lh)), logoimg, nil, logoimg.r.min);
	top.image.flush(Draw->Flushnow);
}

# Re-apply theme-dependent colours after a live theme change.
retheme()
{
	tk->cmd(top, ".c.title configure -foreground " + accentcol);
	tk->cmd(top, ".c.sep configure -background " + accentcol);
	for(i := 0; i < len lines; i++){
		(nil, dim) := lines[i];
		if(dim)
			tk->cmd(top, sys->sprint(".c.l%d configure -foreground %s", i, dimcol));
	}
	tk->cmd(top, "update");
}

# Decode the logo PNG into the colour Draw image `logoimg` (blitted onto the
# window by drawlogo(), never handed to Tk). Returns 1 on success.
loadlogo(display: ref Display): int
{
	path := logopath();
	bufio := load Bufio Bufio->PATH;
	if(bufio == nil)
		return 0;
	readpng := load RImagefile RImagefile->READPNGPATH;
	remap := load Imageremap Imageremap->PATH;
	if(readpng == nil || remap == nil)
		return 0;
	readpng->init(bufio);
	remap->init(display);
	fd := bufio->open(path, Bufio->OREAD);
	if(fd == nil)
		return 0;
	(raw, nil) := readpng->read(fd);
	if(raw == nil)
		return 0;
	# Keep the full-colour Draw image. Inferno Tk images are greyscale
	# (libtk/image.c: CHAN2(CAlpha,8,CGrey,8)), so we do NOT hand it to Tk;
	# drawlogo() blits it onto the window directly, as lucifer and logon do.
	(logoimg, nil) = remap->remap(raw, display, 0);
	return logoimg != nil;
}

# The logo file, theme-specific if one exists.
logopath(): string
{
	path := "/lib/lucifer/about-screen.png";
	name := rf("/lib/lucifer/theme/current");
	if(name != nil && name != "brimstone" && name != ""){
		tpath := "/lib/lucifer/logo-" + name + ".png";
		if((fd := sys->open(tpath, Sys->OREAD)) != nil){
			fd = nil;
			path = tpath;
		}
	}
	return path;
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(sys->fildes(2), "about: tk error %s on %s\n", e, cmds[i]);
	}
}

themelistener(ch: chan of int)
{
	fd := sys->open("/mnt/ui/event", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		ev := string buf[0:n];
		sys->seek(fd, big 0, Sys->SEEKSTART);
		if(len ev >= 6 && ev[0:6] == "theme ")
			ch <-= 1;
	}
}

# Product name, from /lib/lucifer/brand/name (default "InferNode").
brandname(): string
{
	n := rf("/lib/lucifer/brand/name");
	if(n == nil)
		return "InferNode";
	return n;
}

# Description/link lines, from /lib/lucifer/brand/about.txt (default deflines).
# One label per line; a line is dimmed (URL style) when it has no spaces and
# contains a dot. Blank lines are skipped.
brandabout(): array of (string, int)
{
	txt := slurp("/lib/lucifer/brand/about.txt");
	if(txt == nil)
		return deflines;
	(nl, ls) := sys->tokenize(txt, "\n");
	if(nl == 0)
		return deflines;
	out := array[nl] of (string, int);
	i := 0;
	for(; ls != nil; ls = tl ls){
		line := hd ls;
		while(len line > 0 && (line[len line-1] == '\r' || line[len line-1] == ' '))
			line = line[:len line-1];
		if(len line == 0)
			continue;
		out[i] = (line, urllike(line));
		i++;
	}
	if(i == 0)
		return deflines;
	return out[0:i];
}

urllike(s: string): int
{
	dot := 0;
	for(i := 0; i < len s; i++){
		if(s[i] == ' ')
			return 0;
		if(s[i] == '.')
			dot = 1;
	}
	return dot;
}

# Read a whole small file (<= 2KB); nil if absent or empty.
slurp(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[2048] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

rf(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return nil;
	while(n > 0 && (buf[n-1] == byte '\n' || buf[n-1] == byte ' ' || buf[n-1] == byte '\t'))
		n--;
	if(n == 0)
		return nil;
	return string buf[0:n];
}
