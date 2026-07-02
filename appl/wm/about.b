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
accentcol: string;	# "#rrggbbff" title accent (from theme)
dimcol:    string;	# "#rrggbbff" URL/footnote colour (from theme)

# (text, dim) pairs — dim=1 lines use the muted colour (URLs).
lines := array[] of {
	("Inferno® Operating System", 0),
	("Originally by Bell Labs (Lucent)", 0),
	("Vita Nuova Holdings", 0),
	("InferNode fork by infernode-os", 0),
	("lucent.com/inferno", 1),
	("infernode.io", 1),
	("github.com/infernode-os", 1),
};

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

	wmctl: chan of string;
	(top, wmctl) = tkclient->toplevel(ctxt,
		sys->sprint("-width %d -height %d", WINW, WINH),
		"About InferNode", Tkclient->Appl);

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

	# Logo (optional — only if the PNG decodes).
	if(loadlogo(display))
		tkcmds(array[] of {"label .c.logo -image about_logo", "pack .c.logo -side top -pady 12"});

	# Title.
	tkcmds(array[] of {
		"label .c.title -text {InferNode} -foreground " + accentcol +
			" -font " + titlef,
		"pack .c.title -side top -pady {6 2}",
	});

	# Version, from the kernel sysctl.
	version := rf("/dev/sysctl");
	if(version != nil)
		tkcmds(array[] of {
			"label .c.ver -text '" + version + " -font " + bodyf,
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
			"label " + w + " -text '" + text + " -font " + bodyf + fg,
			"pack " + w + " -side top",
		});
	}

	tkcmds(array[] of {"pack .c -fill both -expand 1", "pack propagate . 0"});
	tk->cmd(top, "update");
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

# Decode the logo PNG into a Tk image named "about_logo".
# Returns 1 on success.
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
	(logo, nil) := remap->remap(raw, display, 0);
	if(logo == nil)
		return 0;
	if(tk->cmd(top, "image create bitmap about_logo")[0] == '!')
		return 0;
	e := tk->putimage(top, "about_logo", logo, nil);
	return e == nil || e == "";
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
