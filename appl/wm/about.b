implement About;

#
# About InferNode — native Draw + Widget version
#
# Displays the InferNode logo, system version, and project info
# using Widget->Label for themed text (no Tk dependency).
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "bufio.m";

include "imagefile.m";

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "lucitheme.m";
	lucitheme: Lucitheme;
	Theme: import lucitheme;

include "widget.m";
	widgetmod: Widget;
	Label, CENTER: import widgetmod;

About: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

ZP := Point(0, 0);

# Desktop cap. On phone-class screens the window fills (with margins)
# instead; type and spacing scale to the actual window (see pickfonts).
WINW: con 600;
WINH: con 590;

# Responsive type + spacing, chosen from the real window width in
# pickfonts() rather than fixed desktop pixels (INFR-159).
bodyfont_g:  ref Font;
titlefont_g: ref Font;
PAD: int;	# padding, = body font height
LINEH: int;	# line height for body labels

init(ctxt: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	if(ctxt == nil) {
		sys->fprint(sys->fildes(2), "about: no window context\n");
		raise "fail:bad context";
	}

	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil) {
		sys->fprint(sys->fildes(2), "about: cannot load wmclient: %r\n");
		raise "fail:load wmclient";
	}
	lucitheme = load Lucitheme Lucitheme->PATH;
	widgetmod = load Widget Widget->PATH;
	if(widgetmod == nil) {
		sys->fprint(sys->fildes(2), "about: cannot load widget: %r\n");
		raise "fail:load widget";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();

	w := wmclient->window(ctxt, "About InferNode", Wmclient->Appl);
	display := w.display;

	# Size the window from the screen, not fixed desktop pixels: fill
	# (with margins) on a phone-class screen, cap-and-centre on desktop.
	# (Under the lucifer presentation zone preswmloop dictates the size
	# and ignores this reshape — harmless; layout derives from the real
	# window in redraw() either way.)
	scr := display.image.r;
	sw := scr.dx();
	sh := scr.dy();
	if(ismobile()) {
		m := sw / 24;
		w.reshape(Rect((scr.min.x + m, scr.min.y + m),
			(scr.max.x - m, scr.max.y - m)));
	} else {
		ww := WINW; wh := WINH;
		if(ww > sw) ww = sw;
		if(wh > sh) wh = sh;
		ox := scr.min.x + (sw - ww) / 2;
		oy := scr.min.y + (sh - wh) / 2;
		w.reshape(Rect((ox, oy), (ox + ww, oy + wh)));
	}
	w.startinput("ptr" :: "kbd" :: nil);
	w.onscreen(nil);

	# Pick fonts + spacing from the actual granted window width, then
	# init the widget module with the chosen body font.
	pickfonts(display, w.image.r.dx());
	widgetmod->init(display, bodyfont_g);

	redraw(w, display);

	# Listen for live theme changes
	themech := chan[1] of int;
	spawn themelistener(themech);

	for(;;) alt {
	ctl := <-w.ctl or
	ctl = <-w.ctxt.ctl =>
		w.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw(w, display);

	<-w.ctxt.kbd =>
		;	# ignore keyboard

	p := <-w.ctxt.ptr =>
		w.pointer(*p);

	<-themech =>
		widgetmod->retheme(display);
		wmclient->retheme(w);
		redraw(w, display);
	}
}

# Read /env/infmobile (set on iOS/Android) — phone-class layout.
ismobile(): int
{
	(ok, st) := sys->stat("/env/infmobile");
	if(ok != 0 || st.length == big 0)
		return 0;
	fd := sys->open("/env/infmobile", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[8] of byte;
	n := sys->read(fd, buf, len buf);
	return n > 0 && buf[0] == byte '1';
}

# Open a unicode.sans face at the given pixel size, falling back to
# smaller faces, then the built-in default.
openface(display: ref Display, px: int): ref Font
{
	f := Font.open(display, sys->sprint("/fonts/combined/unicode.sans.%d.font", px));
	if(f == nil)
		f = Font.open(display, "/fonts/combined/unicode.sans.14.font");
	if(f == nil)
		f = Font.open(display, "*default*");
	return f;
}

# Choose body/title faces and derived spacing from the window width.
# Available faces: 12 14 18 24 32 48.
pickfonts(display: ref Display, ww: int)
{
	bp, tp: int;
	if(ww >= 1000)     { bp = 32; tp = 48; }
	else if(ww >= 640) { bp = 18; tp = 32; }
	else if(ww >= 380) { bp = 14; tp = 24; }
	else               { bp = 12; tp = 18; }
	bodyfont_g  = openface(display, bp);
	titlefont_g = openface(display, tp);
	if(bodyfont_g == nil)		# *default* failed too — last resort
		bodyfont_g = titlefont_g;
	PAD = bodyfont_g.height;
	LINEH = bodyfont_g.height + bodyfont_g.height / 3;
}

redraw(w: ref Window, display: ref Display)
{
	screen := w.image;
	if(screen == nil)
		return;
	if(bodyfont_g == nil)		# defensive: ensure fonts exist
		pickfonts(display, screen.r.dx());

	# Load theme
	theme: ref Theme;
	if(lucitheme != nil)
		theme = lucitheme->gettheme();
	if(theme == nil)
		theme = ref Theme;

	bg := display.color(theme.bg | 16rFF);
	accent := display.color(theme.accent | 16rFF);
	dimcol := display.color(theme.dim | 16rFF);

	# Clear background
	screen.draw(screen.r, bg, nil, ZP);

	titlefont := titlefont_g;	# responsive title face (see pickfonts)

	r := screen.r;
	cx := (r.min.x + r.max.x) / 2;
	y := r.min.y + PAD;

	# Load and draw logo via PNG decoder (display.open only handles Plan 9 format)
	logopath := "/lib/lucifer/about-screen.png";
	themename := rf("/lib/lucifer/theme/current");
	if(themename != nil) {
		while(len themename > 0 && (themename[len themename - 1] == '\n' || themename[len themename - 1] == ' '))
			themename = themename[:len themename - 1];
		if(themename != "brimstone" && themename != "") {
			tpath := "/lib/lucifer/logo-" + themename + ".png";
			tfd := sys->open(tpath, Sys->OREAD);
			if(tfd != nil)
				logopath = tpath;
		}
	}
	logo: ref Image;
	{
		bufio := load Bufio Bufio->PATH;
		if(bufio != nil) {
			readpng := load RImagefile RImagefile->READPNGPATH;
			remap := load Imageremap Imageremap->PATH;
			if(readpng != nil && remap != nil) {
				readpng->init(bufio);
				remap->init(display);
				fd := bufio->open(logopath, Bufio->OREAD);
				if(fd != nil) {
					(raw, nil) := readpng->read(fd);
					if(raw != nil)
						(logo, nil) = remap->remap(raw, display, 0);
				}
			}
		}
	}
	if(logo != nil) {
		lw := logo.r.dx();
		lh := logo.r.dy();
		if(lw < 48) {
			# Scale a small source logo up proportionally to the
			# window so it isn't a tiny mark on a phone screen.
			scale := 2 + screen.r.dx() / 300;
			if(scale > 8) scale = 8;
			sw := lw * scale;
			sh := lh * scale;
			dst := Rect((cx - sw/2, y), (cx + sw/2, y + sh));
			scaled := display.newimage(dst, screen.chans, 0, Draw->Nofill);
			if(scaled != nil) {
				scaleblit(scaled, logo, scale);
				screen.draw(dst, scaled, nil, dst.min);
			}
			y += sh + PAD * 2;
		} else {
			lx := cx - lw/2;
			dst := Rect((lx, y), (lx + lw, y + lh));
			screen.draw(dst, logo, nil, logo.r.min);
			y += lh + PAD * 2;
		}
	} else
		y += PAD;

	# Title — uses larger font, drawn manually
	title := "InferNode";
	tw := titlefont.width(title);
	screen.text(Point(cx - tw/2, y), accent, ZP, titlefont, title);
	y += titlefont.height + 4;

	# Version from sysctl — Widget Label
	version := rf("/dev/sysctl");
	if(version != nil) {
		vl := Label.mk(Rect((r.min.x, y), (r.max.x, y + LINEH)), version, 0, CENTER);
		vl.draw(screen);
		y += LINEH;
	}

	# Separator line
	y += 8;
	screen.line(Point(r.min.x + PAD*2, y), Point(r.max.x - PAD*2, y),
		0, 0, 0, dimcol, ZP);
	y += 12;

	# Description lines — Widget Labels
	# (text, dim) pairs: dim=1 for URLs
	lines := array[] of {
		("Inferno\u00AE Operating System", 0),
		("", 0),
		("Originally by Bell Labs (Lucent)", 0),
		("Vita Nuova Holdings", 0),
		("", 0),
		("InferNode fork by", 0),
		("infernode-os", 0),
		("", 0),
		("lucent.com/inferno", 1),
		("infernode.io", 1),
		("github.com/infernode-os", 1),
	};

	for(i := 0; i < len lines; i++) {
		(text, dim) := lines[i];
		if(text == nil || len text == 0) {
			y += LINEH / 2;
			continue;
		}
		l := Label.mk(Rect((r.min.x, y), (r.max.x, y + LINEH)), text, dim, CENTER);
		l.draw(screen);
		y += LINEH;
	}

	screen.flush(Draw->Flushnow);
}

# Nearest-neighbor scale: blit src into dst at integer scale factor
scaleblit(dst, src: ref Image, scale: int)
{
	sw := src.r.dx();
	sh := src.r.dy();
	bpp := src.depth / 8;
	if(bpp < 1)
		bpp = 1;
	srcbuf := array[sw * sh * bpp] of byte;
	src.readpixels(src.r, srcbuf);

	dw := sw * scale;
	rowbuf := array[dw * bpp] of byte;
	for(sy := 0; sy < sh; sy++) {
		for(sx := 0; sx < sw; sx++) {
			for(k := 0; k < bpp; k++) {
				v := srcbuf[(sy * sw + sx) * bpp + k];
				for(dx := 0; dx < scale; dx++)
					rowbuf[((sx * scale + dx) * bpp) + k] = v;
			}
		}
		for(dy := 0; dy < scale; dy++) {
			ry := dst.r.min.y + sy * scale + dy;
			lr := Rect((dst.r.min.x, ry), (dst.r.min.x + dw, ry + 1));
			dst.writepixels(lr, rowbuf);
		}
	}
}

themelistener(ch: chan of int)
{
	fd := sys->open("/n/ui/event", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		ev := string buf[0:n];
		# INFR-28: reset client-side fid offset so the next read on
		# this streaming queue starts at 0 (otherwise the kernel
		# applies the accumulated offset to the server reply and
		# truncates / EOFs on the third read onward).
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
