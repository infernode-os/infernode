implement Presrender;

#
# wm/presrender - Presentation content renderer for Lucifer
#
# Phase 0 (additive) extraction of the content-rendering half of
# appl/cmd/lucipres.b, minus the tab bar and multi-artifact
# coordination.  presrender is a standard wmclient app launched into
# the presentation zone:
#
#   create id=... type=app dis=/dis/wm/presrender.dis
#
# It renders exactly ONE presentation artifact at a time — the
# currently-centered CONTENT artifact — full-window (no tab strip).
# It follows the current artifact by reading /mnt/ui and watching the
# per-activity event file over 9P, and handles scroll, drag-pan, and
# PDF page navigation.
#
# The render pipeline (markdown, mermaid, images, PDF, code, table,
# diff, etc.) is lifted verbatim from lucipres.b; app/taskboard tabs
# and the context-menu/export path stay in lucipres.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Font, Point, Rect, Image, Display, Screen, Pointer, Wmcontext: import draw;

include "pdf.m";

include "rlayout.m";

include "renderer.m";

include "render.m";

include "lucitheme.m";

include "viewport.m";

include "wmclient.m";
	wmclient: Wmclient;

include "menu.m";
	menumod: Menu;
	Popup: import menumod;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";
	gifwriter: WImagefile;

Presrender: module
{
	PATH: con "/dis/wm/presrender.dis";
	init: fn(ctxt: ref Draw->Context, args: list of string);
	# lucifer (which spawns presrender in-process) pushes presentation
	# events here rather than presrender racing lucifer's nslistener for
	# the shared per-activity 9P event file.
	deliverevent: fn(ev: string);
};

# --- ADTs ---

Artifact: adt {
	id:	string;
	atype:	string;
	label:	string;
	data:	string;
	rendimg: ref Image;
	pdfpage: int;
	numpages: int;
	rendering: int;
	zoom:	int;
	appstatus: string;	# "launching"|"running"|"dead" (type=app only)
	panx:	int;		# horizontal pan offset (pixels)
	pany:	int;		# vertical pan offset (pixels)
};

# Async render result: passed through renderdonech to avoid race conditions.
# The spawned goroutine never writes to the shared Artifact directly;
# the main event loop applies the result in handlerenderdone().
RenderResult: adt {
	artid: string;
	img:   ref Image;
	failed: int;
};

# --- Module state ---

rlay: Rlayout;
DocNode: import rlay;

pdfmod: PDF;
Doc: import pdfmod;

rendermod: Render;

vpmod: Viewport;
View: import vpmod;

stderr: ref Sys->FD;
win: ref Wmclient->Window;
mainwin: ref Image;
backbuf: ref Image;		# off-screen back buffer for double-buffered redraw
display_g: ref Display;
mainfont: ref Font;
monofont_g: ref Font;
mountpt_g: string;
actid_g := -1;
fixedart := "";		# non-"" → render this specific artifact, not "current"
exportseq := 0;		# monotonically increasing id suffix for export apps

# Colors
bgcol: ref Image;
bordercol: ref Image;
headercol: ref Image;
accentcol: ref Image;
textcol: ref Image;
text2col: ref Image;
dimcol: ref Image;
labelcol: ref Image;
codebgcol_g: ref Image;
greencol_g: ref Image;
yellowcol_g: ref Image;
redcol_g: ref Image;

# The single artifact presrender currently renders (nil if none, or if
# the centered artifact is an app/taskboard type presrender doesn't draw).
cur: ref Artifact;

# Render / pan state
artrendw := 0;
maxpresscrollpx := 0;
maxpanx := 0;
pres_viewport_h := 400;
prescontentr: Rect;
mobile := 0;	# set from /env/infmobile in init()

# PDF nav rects (hit-tested in the event loop)
pdfnavprev: Rect;
pdfnavnext: Rect;

renderdonech: chan of ref RenderResult;
eventch: chan of string;	# presentation events, fed by deliverevent()

# --- init (standard wmclient app interface) ---

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr = sys->fildes(2);

	# Initialize channels FIRST — spawned renders and lucifer's
	# deliverevent() both use these; an alt send on a nil channel is
	# fatal, and lucifer can call deliverevent() before init finishes.
	renderdonech = chan[32] of ref RenderResult;
	eventch = chan[8] of string;

	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil) {
		sys->fprint(sys->fildes(2), "presrender: cannot load wmclient: %r\n");
		return;
	}
	wmclient->init();

	# Context menu (Zoom/Reset/Export) + image export. Non-fatal if absent:
	# the right-click menu just degrades to unavailable.  menumod->init needs
	# the display + font, so it is initialised after those are set up below.
	menumod = load Menu Menu->PATH;
	bufio = load Bufio Bufio->PATH;
	if(bufio != nil)
		gifwriter = load WImagefile WImagefile->WRITEGIFPATH;

	# Parse args: "presrender" mountpt actid [artid]
	# If artid is given we render that specific artifact and follow its
	# updates; otherwise we follow whatever content artifact is centered.
	a := args;
	if(a != nil) a = tl a;	# skip argv[0]
	if(a != nil) { mountpt_g = hd a; a = tl a; }
	else mountpt_g = "/mnt/ui";
	if(a != nil) { actid_g = strtoint(hd a); a = tl a; }
	if(a != nil) { fixedart = hd a; a = tl a; }

	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	display_g = ctxt.display;
	if(display_g == nil) {
		sys->fprint(stderr, "presrender: display is nil\n");
		return;
	}

	# KLUDGE-MOBILE-ACCORDION-INFR-119 — same env var lucifer.b reads.
	(mok, mst) := sys->stat("/env/infmobile");
	if(mok == 0 && mst.length > big 0) {
		mfd := sys->open("/env/infmobile", Sys->OREAD);
		if(mfd != nil) {
			mbuf := array[16] of byte;
			mn := sys->read(mfd, mbuf, len mbuf);
			if(mn > 0 && mbuf[0] == byte '1')
				mobile = 1;
		}
	}

	# Load theme colours
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme == nil) {
		sys->fprint(stderr, "presrender: cannot load lucitheme: %r\n");
		return;
	}
	th := lucitheme->gettheme();

	# Allocate bgcol first — win.onscreen("max") triggers putimage() inside
	# wmclient which fills the zone image with Draw->White.  We need bgcol
	# ready so we can immediately overwrite that White before any flush.
	bgcol = display_g.color(th.bg);

	# Create window via the wmsrv in lucifer (preswmloop)
	# Plain: no border decoration — we're an embedded zone, not a top-level app
	win = wmclient->window(ctxt, "Presentation", Wmclient->Plain);
	if(win == nil) {
		sys->fprint(stderr, "presrender: wmclient->window returned nil\n");
		return;
	}
	wmclient->win.reshape(((0, 0), (100, 100)));
	wmclient->win.onscreen("max");
	# putimage() just filled the pres sub-image with White.  Overwrite now.
	if(win.screen != nil && win.screen.image != nil)
		win.screen.image.draw(win.screen.image.r, bgcol, nil, (0, 0));
	wmclient->win.startinput("ptr" :: nil);
	mainwin = win.image;
	if(mainwin == nil) {
		sys->fprint(stderr, "presrender: win.image is nil after onscreen\n");
		return;
	}

	# Allocate remaining colors from theme
	bordercol = display_g.color(th.border);
	headercol = display_g.color(th.header);
	accentcol = display_g.color(th.accent);
	textcol = display_g.color(th.text);
	text2col = display_g.color(th.text2);
	dimcol = display_g.color(th.dim);
	labelcol = display_g.color(th.label);
	codebgcol_g = display_g.color(th.codebg);
	greencol_g = display_g.color(th.green);
	yellowcol_g = display_g.color(th.yellow);
	redcol_g = display_g.color(th.red);

	# Load fonts
	mainfont = Font.open(display_g, "/fonts/combined/unicode.sans.14.font");
	if(mainfont == nil)
		mainfont = Font.open(display_g, "*default*");
	if(mainfont == nil) {
		sys->fprint(stderr, "presrender: cannot load any font\n");
		return;
	}
	monofont_g = Font.open(display_g, "/fonts/combined/unicode.14.font");
	if(monofont_g == nil)
		monofont_g = mainfont;

	if(menumod != nil)
		menumod->init(display_g, mainfont);

	# Load rlayout
	rlay = load Rlayout Rlayout->PATH;
	if(rlay != nil)
		rlay->init(display_g);

	# Load render registry
	rendermod = load Render Render->PATH;
	if(rendermod != nil)
		rendermod->init(display_g);

	# Load viewport
	vpmod = load Viewport Viewport->PATH;

	# Read the current artifact and draw it.
	loadcurrent();
	redraw();

	# Events arrive on eventch via deliverevent(), called in-process by
	# lucifer's nslistener.  (presrender no longer reads the per-activity
	# 9P event file itself — that would steal events from lucifer.)

	# Event loop
	prevbuttons := 0;
	for(;;) alt {
	p := <-win.ctxt.ptr =>
		if(wmclient->win.pointer(*p) == 0) {
			wasdown := prevbuttons;
			prevbuttons = p.buttons;

			# Scroll wheel
			if(p.buttons & 8) {
				prescroll(-1);
				redraw();
			} else if(p.buttons & 16) {
				prescroll(1);
				redraw();
			}

			# Button-3 (or long-press elsewhere): the viewer context menu —
			# zoom/reset/export.  Lives here because presrender owns the
			# content window; a right-click over the content never reaches
			# lucipres, so the menu had become unreachable.
			if(p.buttons & 4 && wasdown == 0 && cur != nil)
				showcontextmenu(p.xy);

			# Button-1 just pressed
			if(p.buttons == 1 && wasdown == 0 && cur != nil) {
				handled := 0;
				# PDF page navigation
				if(cur.atype == "pdf") {
					if(pdfnavprev.max.x > pdfnavprev.min.x &&
							pdfnavprev.contains(p.xy)) {
						if(cur.pdfpage > 1) {
							cur.pdfpage--;
							cur.rendimg = nil;
							cur.pany = 0;
							cur.panx = 0;
							redraw();
						}
						handled = 1;
					} else if(pdfnavnext.max.x > pdfnavnext.min.x &&
							pdfnavnext.contains(p.xy)) {
						if(cur.numpages == 0 || cur.pdfpage < cur.numpages) {
							cur.pdfpage++;
							cur.rendimg = nil;
							cur.pany = 0;
							cur.panx = 0;
							redraw();
						}
						handled = 1;
					}
				}
				# Drag-pan in the content area
				if(!handled && prescontentr.contains(p.xy)) {
					handledrag(cur, p.xy);
					prevbuttons = 0;
					redraw();
				}
			}
		}
	ev := <-eventch =>
		if(ev == "presentation current") {
			loadcurrent();
			redraw();
		} else if(hasprefix(ev, "theme")) {
			reloadcolors();
			redraw();
		} else if(hasprefix(ev, "presentation ")) {
			# "presentation <id>" (or "presentation update <id>") — a
			# data/label change.  Skip the structural sub-events; a switch
			# of the centered artifact arrives as "presentation current".
			rest := strip(ev[len "presentation ":]);
			if(hasprefix(rest, "update "))
				rest = strip(rest[len "update ":]);
			if(!hasprefix(rest, "new ") && !hasprefix(rest, "delete ") &&
					!hasprefix(rest, "kill ") && !hasprefix(rest, "app ")) {
				if(cur != nil && rest == cur.id) {
					loadcurrent();
					if(cur != nil)
						cur.rendimg = nil;
					redraw();
				}
			}
		}
	r := <-renderdonech =>
		handlerenderdone(r);
		redraw();
	e := <-win.ctl or
	e = <-win.ctxt.ctl =>
		if(e == "exit")
			return;
		wmclient->win.wmctl(e);
		if(win.image != mainwin) {
			mainwin = win.image;
			# putimage() in wmclient fills the zone image with Draw->White.
			# Immediately overwrite with bgcol so no white flash reaches the display.
			if(win.screen != nil && win.screen.image != nil)
				win.screen.image.draw(win.screen.image.r, bgcol, nil, (0,0));
			if(cur != nil)
				cur.rendimg = nil;
			artrendw = 0;
			redraw();
		}
	}
}

# --- Event-file reader (runs in its own proc) ---

# Blocking-read the per-activity event file over 9P and forward each
# event line to the main loop.  Mirrors lucifer.b's nslistener: one
# long-lived fid, seek-to-0 after each read, exponential reopen backoff.
# lucifer's nslistener calls this in-process for every presentation
# event.  Non-blocking + nil-guarded: deliverevent() may fire before
# init() has created eventch, and must never block lucifer's listener.
deliverevent(ev: string)
{
	if(eventch != nil)
		alt { eventch <-= ev => ; * => ; }
}

# --- Current-artifact loading ---

# Read the centered artifact id from /mnt/ui and populate `cur`.
# App and taskboard types are not rendered here (lucifer shows the app
# window, the taskboard lives in lucipres) — cur becomes nil for those.
loadcurrent()
{
	base := sys->sprint("%s/activity/%d/presentation", mountpt_g, actid_g);
	id: string;
	if(fixedart != "")
		id = fixedart;
	else {
		cs := readfile(base + "/current");
		if(cs == nil) {
			cur = nil;
			return;
		}
		id = strip(cs);
	}
	if(id == "") {
		cur = nil;
		return;
	}
	artbase := base + "/" + id;
	atype := readfile(artbase + "/type");
	if(atype != nil) atype = strip(atype);
	label := readfile(artbase + "/label");
	if(label != nil) label = strip(label);
	data := readfile(artbase + "/data");
	if(atype == nil || atype == "") atype = "text";
	if(label == nil || label == "") label = id;
	if(data == nil) data = "";

	# Types presrender does not render.
	if(atype == "app" || atype == "taskboard") {
		cur = nil;
		return;
	}

	if(cur != nil && cur.id == id) {
		# Same artifact — preserve pan/zoom/pdfpage/rendimg.  Refresh
		# data/label; invalidate the cached render only if data changed.
		if(data != cur.data) {
			cur.data = data;
			cur.rendimg = nil;
			cur.rendering = 0;
		}
		cur.atype = atype;
		cur.label = label;
		return;
	}
	# Different artifact — fresh state (pdfpage starts at 1).
	cur = ref Artifact(id, atype, label, data, nil, 1, 0, 0, 0, "", 0, 0);
}

findartifact(id: string): ref Artifact
{
	if(cur != nil && cur.id == id)
		return cur;
	return nil;
}

reloadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme == nil)
		return;
	th := lucitheme->gettheme();
	bgcol = display_g.color(th.bg);
	bordercol = display_g.color(th.border);
	headercol = display_g.color(th.header);
	accentcol = display_g.color(th.accent);
	textcol = display_g.color(th.text);
	text2col = display_g.color(th.text2);
	dimcol = display_g.color(th.dim);
	labelcol = display_g.color(th.label);
	codebgcol_g = display_g.color(th.codebg);
	greencol_g = display_g.color(th.green);
	yellowcol_g = display_g.color(th.yellow);
	redcol_g = display_g.color(th.red);
	# Invalidate the rendered artifact cache.
	if(cur != nil)
		cur.rendimg = nil;
	artrendw = 0;
}

# --- Drawing ---

# Full-window, double-buffered redraw of the current artifact.
redraw()
{
	if(mainwin == nil || display_g == nil)
		return;
	mr := mainwin.r;
	if(backbuf == nil || backbuf.r.dx() != mr.dx() || backbuf.r.dy() != mr.dy() ||
			backbuf.r.min.x != mr.min.x || backbuf.r.min.y != mr.min.y)
		backbuf = display_g.newimage(mr, mainwin.chans, 0, Draw->Nofill);
	front := mainwin;
	if(backbuf != nil)
		mainwin = backbuf;
	mainwin.draw(mainwin.r, bgcol, nil, (0, 0));
	drawcontent(mainwin.r);
	if(backbuf != nil) {
		mainwin = front;
		mainwin.draw(mainwin.r, backbuf, nil, backbuf.r.min);
	}
	mainwin.flush(Draw->Flushnow);
}

# Render the current artifact into the whole window (no tab strip).
drawcontent(zone: Rect)
{
	pad := 8;
	pdfnavprev = Rect((0,0),(0,0));
	pdfnavnext = Rect((0,0),(0,0));

	if(cur == nil) {
		drawcentertext(zone, "No content");
		return;
	}

	# The content area is the whole window.
	contentr := zone;
	prescontentr = contentr;
	contentw := contentr.dx() - 2 * pad;

	# Invalidate render cache on width change.
	if(contentw != artrendw) {
		cur.rendimg = nil;
		artrendw = contentw;
	}

	contenty := contentr.min.y + pad;
	pres_viewport_h = contentr.dy() - 2 * pad;

	case cur.atype {
	"text" or "code" =>
		if(cur.atype == "code") {
			codebg2 := codebgcol_g;
			mainwin.draw(contentr, codebg2, nil, (0, 0));
		}
		ls := splitlines(cur.data);
		total_h := listlen(ls) * monofont_g.height;
		newmax2 := total_h - pres_viewport_h;
		if(newmax2 < 0) newmax2 = 0;
		maxpresscrollpx = newmax2;
		if(cur.pany > maxpresscrollpx)
			cur.pany = maxpresscrollpx;
		maxlinew := 0;
		for(wlm := ls; wlm != nil; wlm = tl wlm) {
			lw := monofont_g.width(hd wlm);
			if(lw > maxlinew) maxlinew = lw;
		}
		newmaxx2 := maxlinew - contentw;
		if(newmaxx2 < 0) newmaxx2 = 0;
		maxpanx = newmaxx2;
		if(cur.panx > maxpanx)
			cur.panx = maxpanx;
		y2 := contenty - cur.pany;
		wl: list of string;
		for(wl = ls; wl != nil; wl = tl wl) {
			if(y2 + monofont_g.height > contentr.max.y)
				break;
			if(y2 >= contentr.min.y)
				mainwin.text((contentr.min.x + pad - cur.panx, y2),
					textcol, (0, 0), monofont_g, hd wl);
			y2 += monofont_g.height;
		}
		if(cur.data == "")
			drawcentertext(contentr, "(empty)");
	"pdf" =>
		# PDF needs special nav UI; rendering delegated to registry
		navh := mainfont.height + 8;
		pdfcontent := Rect(contentr.min, (contentr.max.x, contentr.max.y - navh));
		pdfnav := Rect((contentr.min.x, contentr.max.y - navh), contentr.max);
		drawpdfnav(pdfnav, cur);
		pres_viewport_h = pdfcontent.dy() - 2 * pad;
		if(cur.rendimg == nil)
			cur.rendimg = renderart(cur, contentw);
		drawrendimg(cur, pdfcontent, pad, contentw, "cannot render PDF");
	"table" =>
		drawtable(cur, contentr, pad, contentw, contenty);
	"diff" =>
		drawdiff(cur, contentr, pad, contentw, contenty);
	* =>
		# All other renderable types: markdown, doc, image, mermaid, etc.
		if(cur.rendimg == nil && cur.data != "") {
			if(cur.rendering == 0) {
				cur.rendering = 1;
				spawn renderartasync(cur.id, cur.atype, cur.data, contentw);
			}
		}
		if(cur.rendimg != nil) {
			cur.rendering = 0;
			drawrendimg(cur, contentr, pad, contentw, nil);
		} else if(cur.rendering == 1)
			drawcentertext(contentr, "Rendering...");
		else if(cur.rendering == 2) {
			# Render failed — show fallback text
			drawfallbacktext(cur, contentr, pad, contentw, contenty);
		} else if(cur.data == "")
			drawcentertext(contentr, "(empty)");
		else
			drawfallbacktext(cur, contentr, pad, contentw, contenty);
	}
}

drawcentertext(r: Rect, text: string)
{
	tw := mainfont.width(text);
	tx := r.min.x + (r.dx() - tw) / 2;
	ty := r.min.y + (r.dy() - mainfont.height) / 2;
	mainwin.text((tx, ty), dimcol, (0, 0), mainfont, text);
}

# --- Scroll and drag ---

# Scroll the current artifact vertically.
# dir: -1 = up, 1 = down.
# Uses Viewport for boundary detection: when a PDF is at the bottom
# and the user scrolls down, advance to the next page (like Xenith).
prescroll(dir: int)
{
	art := cur;
	if(art == nil)
		return;

	step := mainfont.height * 3;
	if(vpmod != nil) {
		step = vpmod->scrollstep(pres_viewport_h);
		v := ref View(art.panx, art.pany, 0, 0, 0, 0);
		v.contentw = art.panx + 1;  # dummy — not clamping x here
		v.contenth = maxpresscrollpx + pres_viewport_h;
		v.vieww = 1;
		v.viewh = pres_viewport_h;
		boundary := vpmod->scrolly(v, dir, step);
		art.pany = v.pany;

		# Page navigation at boundary (PDFs)
		if(art.atype == "pdf" && boundary != 0) {
			if(boundary > 0 && (art.numpages == 0 || art.pdfpage < art.numpages)) {
				# At bottom — next page
				art.pdfpage++;
				art.rendimg = nil;
				art.pany = 0;
				art.panx = 0;
			} else if(art.pdfpage > 1) {
				# At top — previous page, start at bottom
				art.pdfpage--;
				art.rendimg = nil;
				art.pany = 16r7FFFFFFF;  # clamped during render
				art.panx = 0;
			}
		}
	} else {
		# Fallback without viewport module
		if(dir > 0) {
			art.pany += step;
			if(art.pany > maxpresscrollpx)
				art.pany = maxpresscrollpx;
		} else {
			art.pany -= step;
			if(art.pany < 0)
				art.pany = 0;
		}
	}
}

# Drag the current artifact content by mouse movement.
# Follows the same pattern as Xenith's imagedrag(): track initial
# position, compute delta, clamp via Viewport, redraw each move.
handledrag(art: ref Artifact, startpt: Point)
{
	startpx := art.panx;
	startpy := art.pany;

	for(;;) {
		np := <-win.ctxt.ptr;
		if((np.buttons & 1) == 0)
			break;

		dx := startpt.x - np.xy.x;
		dy := startpt.y - np.xy.y;

		if(vpmod != nil) {
			v := ref View(0, 0, 0, 0, 0, 0);
			v.contentw = maxpanx + prescontentr.dx();
			v.contenth = maxpresscrollpx + pres_viewport_h;
			v.vieww = prescontentr.dx();
			v.viewh = pres_viewport_h;
			vpmod->drag(v, startpx, startpy, dx, dy);
			art.panx = v.panx;
			art.pany = v.pany;
		} else {
			art.panx = startpx + dx;
			art.pany = startpy + dy;
			if(art.panx < 0) art.panx = 0;
			if(art.panx > maxpanx) art.panx = maxpanx;
			if(art.pany < 0) art.pany = 0;
			if(art.pany > maxpresscrollpx) art.pany = maxpresscrollpx;
		}
		redraw();
	}
}

artzoom(art: ref Artifact): int
{
	if(art.zoom == 0)
		return 100;
	return art.zoom;
}

# --- Context menu (zoom / reset / export / close) ---

# Show the viewer context menu for the current artifact and act on the
# choice.  Ported from lucipres, which lost the ability to service it once
# presrender took over the content window.
showcontextmenu(at: Point)
{
	if(menumod == nil || cur == nil)
		return;
	# Menu items are type-specific (files on disk need no export; rendered
	# diagrams can export source or image; text exports its content).
	items: array of string;
	case cur.atype {
	"pdf" or "image" =>
		items = array[] of {"Close", "Zoom In", "Zoom Out", "Reset View"};
	"mermaid" =>
		items = array[] of {"Close", "Zoom In", "Zoom Out", "Reset View",
			"Export Source", "Export Image"};
	* =>
		items = array[] of {"Close", "Zoom In", "Zoom Out", "Reset View", "Export"};
	}
	pop := menumod->new(items);
	res := popmenu(pop, at);
	case res {
	0 =>
		deleteartifactui(cur.id);
	1 =>
		cur.zoom = artzoom(cur) + 25;
		if(cur.zoom > 400) cur.zoom = 400;
		cur.rendimg = nil;
		redraw();
	2 =>
		cur.zoom = artzoom(cur) - 25;
		if(cur.zoom < 25) cur.zoom = 25;
		cur.rendimg = nil;
		redraw();
	3 =>
		cur.zoom = 0;
		cur.panx = 0;
		cur.pany = 0;
		cur.rendimg = nil;
		redraw();
	4 =>
		exportartifact(cur);
	5 =>
		exportimage(cur);	# only reachable for mermaid
	}
}

popmenu(pop: ref Popup, at: Point): int
{
	if(win != nil && win.screen != nil && win.image != nil)
		return pop.showtop(win.screen, win.image.r, at, win.ctxt.ptr);
	return pop.show(mainwin, at, win.ctxt.ptr);
}

deleteartifactui(id: string)
{
	if(actid_g >= 0)
		writetofile(sys->sprint("%s/activity/%d/presentation/ctl", mountpt_g, actid_g),
			"delete id=" + id);
}

# Export text content to /tmp and open it in editor as a presentation app.
exportartifact(art: ref Artifact)
{
	if(art == nil)
		return;
	ext := ".txt";
	case art.atype {
	"markdown" or "doc" => ext = ".md";
	"mermaid" => ext = ".mmd";
	"code" => ext = ".b";
	"table" => ext = ".tsv";
	}
	fname := safename(art.label);
	if(fname == "")
		fname = "export";
	fname += "-" + string sys->millisec();
	path := "/tmp/" + fname + ext;
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil) {
		sys->fprint(stderr, "presrender: export: cannot create %s: %r\n", path);
		writetosnarf(art.data);
		return;
	}
	b := array of byte art.data;
	sys->write(fd, b, len b);
	fd = nil;
	launchexport(fname + ext, path);
}

# Export the rendered image as a GIF and copy its path to the snarf buffer.
exportimage(art: ref Artifact)
{
	if(art == nil || art.rendimg == nil)
		return;
	if(gifwriter == nil || bufio == nil) {
		sys->fprint(stderr, "presrender: export image: GIF writer not available\n");
		return;
	}
	fname := safename(art.label);
	if(fname == "")
		fname = "export";
	fname += "-" + string sys->millisec();
	path := "/tmp/" + fname + ".gif";
	ofd := bufio->create(path, Bufio->OWRITE, 8r644);
	if(ofd == nil) {
		sys->fprint(stderr, "presrender: export image: cannot create %s: %r\n", path);
		return;
	}
	err := gifwriter->writeimage(ofd, art.rendimg);
	ofd.close();
	if(err != nil) {
		sys->fprint(stderr, "presrender: export image: %s: %s\n", path, err);
		return;
	}
	writetosnarf(path);
}

launchexport(label, filepath: string)
{
	if(actid_g < 0)
		return;
	exportseq++;
	id := sys->sprint("editor-%d", exportseq);
	ctlpath := sys->sprint("%s/activity/%d/presentation/ctl", mountpt_g, actid_g);
	writetofile(ctlpath,
		sys->sprint("create id=%s type=app label=%s dis=/dis/wm/editor.dis", id, label));
	datapath := sys->sprint("%s/activity/%d/presentation/%s/data", mountpt_g, actid_g, id);
	fd := sys->open(datapath, Sys->OWRITE);
	if(fd != nil) {
		b := array of byte filepath;
		sys->write(fd, b, len b);
	}
}

safename(s: string): string
{
	r := "";
	for(i := 0; i < len s && i < 64; i++) {
		c := s[i];
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') || c == '-' || c == '_')
			r += s[i:i+1];
		else if(c == ' ' && len r > 0 && r[len r - 1] != '-')
			r += "-";
	}
	return r;
}

writetosnarf(text: string)
{
	writetofile("/dev/snarf", text);
}

writetofile(path: string, text: string)
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte text;
	sys->write(fd, b, len b);
}

# --- Rendering via registry ---

# Map artifact type to a renderer hint for Render.find().
artypehint(art: ref Artifact): string
{
	case art.atype {
	"markdown" or "doc" => return ".md";
	"pdf" => return art.data;	# data is the file path
	"image" => return art.data;	# data is the file path
	"mermaid" or "mindmap" or "flowchart" or "sequenceDiagram" or
	"classDiagram" or "stateDiagram" or "stateDiagram-v2" or
	"erDiagram" or "timeline" or "gitGraph" or
	"quadrantChart" or "journey" or "requirementDiagram" or
	"block-beta" or "pie" or "gantt" or "xychart-beta" =>
		return ".mermaid";
	* => return "";
	}
}

# Convert artifact data to bytes for the renderer.
artdata(art: ref Artifact): array of byte
{
	case art.atype {
	"pdf" or "image" =>
		# Data is a file path; read it
		return readfilebytes(art.data);
	* =>
		# Data is raw content
		if(art.data == "")
			return nil;
		return array of byte art.data;
	}
}

# Render an artifact using the Render registry.
# Falls back to the old rlayout path for markdown if registry unavailable.
renderart(art: ref Artifact, contentw: int): ref Image
{
	# PDF special case: uses page/zoom state
	if(art.atype == "pdf") {
		(img, np) := renderpdfpage(art.data, art.pdfpage,
			96 * artzoom(art) / 100);
		if(np > 0)
			art.numpages = np;
		return img;
	}

	hint := artypehint(art);
	if(hint == "")
		return nil;

	# Try registry first
	if(rendermod != nil) {
		data := artdata(art);
		if(data == nil)
			return nil;
		(renderer, nil) := rendermod->find(data, hint);
		if(renderer != nil) {
			# Images: bigger zoom → bigger rendered output (scale up)
			# Text/document renderers: larger zoom → narrower layout (scale font effect)
			w := contentw * 100 / artzoom(art);
			if(art.atype == "image")
				w = contentw * artzoom(art) / 100;
			progress := chan of ref Renderer->RenderProgress;
			# Drain progress (we don't use progressive rendering here)
			spawn drainprogress(progress);
			img: ref Image;
			{
				(img, nil, nil) = renderer->render(data, hint, w, 0, progress);
			} exception e {
			"*" =>
				sys->fprint(stderr, "presrender: render %s: %s\n", art.atype, e);
				return nil;
			}
			return img;
		}
	}

	# Fallback: markdown via rlayout (when registry not loaded)
	if((art.atype == "markdown" || art.atype == "doc") && rlay != nil) {
		codebg := codebgcol_g;
		zw := contentw * 100 / artzoom(art);
		style := ref Rlayout->Style(
			zw, 4,
			mainfont, monofont_g,
			textcol, bgcol, accentcol, codebg,
			100
		);
		(img, nil) := rlay->render(rlay->parsemd(art.data), style);
		return img;
	}

	return nil;
}

# Async rendering for the default branch (mermaid, markdown, image, etc.)
# Passes results through renderdonech; never mutates the Artifact directly.
renderartasync(artid, atype, data: string, contentw: int)
{
	# Build a temporary Artifact with just the fields renderart needs.
	# This avoids reading shared mutable state from the spawned goroutine.
	tmp := ref Artifact(artid, atype, "", data, nil, 1, 0, 0, 0, "", 0, 0);
	img: ref Image;
	{
		img = renderart(tmp, contentw);
	} exception e {
	"*" =>
		sys->fprint(stderr, "presrender: renderartasync %s: %s\n", atype, e);
		alt { renderdonech <-= ref RenderResult(artid, nil, 1) => ; * => ; }
		return;
	}
	failed := 0;
	if(img == nil)
		failed = 1;
	alt { renderdonech <-= ref RenderResult(artid, img, failed) => ; * => ; }
}

handlerenderdone(r: ref RenderResult)
{
	art := findartifact(r.artid);
	if(art == nil)
		return;
	if(r.failed) {
		art.rendering = 2;
	} else {
		art.rendimg = r.img;
		art.rendering = 0;
	}
}

drainprogress(ch: chan of ref Renderer->RenderProgress)
{
	for(;;) {
		p := <-ch;
		if(p == nil)
			return;
	}
}

# Draw a rendered image with viewport pan/scroll clipping.
# Shared by all types that produce a pre-rendered image.
drawrendimg(art: ref Artifact, clipr: Rect, pad: int, contentw: int, errmsg: string)
{
	if(art.rendimg == nil) {
		if(errmsg != nil)
			drawcentertext(clipr, errmsg);
		else
			drawcentertext(clipr, "(empty)");
		return;
	}
	imgh := art.rendimg.r.dy();
	imgw := art.rendimg.r.dx();
	newmax := imgh - pres_viewport_h;
	if(newmax < 0) newmax = 0;
	maxpresscrollpx = newmax;
	if(art.pany > maxpresscrollpx)
		art.pany = maxpresscrollpx;
	newmaxx := imgw - contentw;
	if(newmaxx < 0) newmaxx = 0;
	maxpanx = newmaxx;
	if(art.panx > maxpanx)
		art.panx = maxpanx;
	srcy := art.pany;
	srcx := art.panx;
	dsty := clipr.min.y + pad;
	enddsty := dsty + (imgh - srcy);
	if(enddsty > clipr.max.y) enddsty = clipr.max.y;
	if(dsty < enddsty)
		mainwin.draw(
			Rect((clipr.min.x + pad, dsty),
			     (clipr.min.x + pad + contentw, enddsty)),
			art.rendimg, nil, (srcx, srcy));
}

# Draw the PDF page navigation bar.
drawpdfnav(pdfnav: Rect, art: ref Artifact)
{
	navh := pdfnav.dy();
	mainwin.draw(pdfnav, headercol, nil, (0, 0));
	pagestr := sys->sprint("Page %d", art.pdfpage);
	psw := mainfont.width(pagestr);
	psy := pdfnav.min.y + (navh - mainfont.height) / 2;
	midx := pdfnav.min.x + pdfnav.dx() / 2;
	mainwin.text((midx - psw/2, psy), textcol, (0, 0), mainfont, pagestr);
	prevlabel := " < ";
	plw := mainfont.width(prevlabel);
	plx := midx - psw/2 - plw - 8;
	if(art.pdfpage > 1) {
		mainwin.text((plx, psy), accentcol, (0, 0), mainfont, prevlabel);
		pdfnavprev = Rect((plx, pdfnav.min.y), (plx + plw, pdfnav.max.y));
	} else
		mainwin.text((plx, psy), dimcol, (0, 0), mainfont, prevlabel);
	nextlabel := " > ";
	nlw := mainfont.width(nextlabel);
	nlx := midx + psw/2 + 8;
	hasnext := art.numpages == 0 || art.pdfpage < art.numpages;
	if(hasnext) {
		mainwin.text((nlx, psy), accentcol, (0, 0), mainfont, nextlabel);
		pdfnavnext = Rect((nlx, pdfnav.min.y), (nlx + nlw, pdfnav.max.y));
	} else
		mainwin.text((nlx, psy), dimcol, (0, 0), mainfont, nextlabel);
}

# Draw fallback text when no renderer is available or rendering failed.
drawfallbacktext(art: ref Artifact, contentr: Rect, pad: int, contentw: int, contenty: int)
{
	if(art.data == "") {
		drawcentertext(contentr, "(empty)");
		return;
	}
	hint := artypehint(art);
	if(art.atype != "" && art.atype != "markdown" && art.atype != "doc" &&
			hint != ".mermaid" && art.atype != "image") {
		mainwin.text((contentr.min.x + pad, contenty),
			labelcol, (0, 0), mainfont, "[" + art.atype + "]");
		contenty += mainfont.height + 4;
	}
	ls := wraptext(art.data, contentw);
	for(wl := ls; wl != nil; wl = tl wl) {
		if(contenty + mainfont.height > contentr.max.y)
			break;
		mainwin.text((contentr.min.x + pad, contenty),
			textcol, (0, 0), mainfont, hd wl);
		contenty += mainfont.height;
	}
}

# Draw table content (custom layout, not image-based).
drawtable(art: ref Artifact, contentr: Rect, pad: int, contentw: int, contenty: int)
{
	trows := splitlines(art.data);
	if(art.data == "") {
		drawcentertext(contentr, "(empty table)");
		return;
	}
	ncols := 0;
	for(trl := trows; trl != nil; trl = tl trl) {
		n := tabcountcols(hd trl);
		if(n > ncols) ncols = n;
	}
	if(ncols == 0) {
		drawcentertext(contentr, "(no columns)");
		return;
	}
	colw := array[ncols] of {* => 20};
	for(trl = trows; trl != nil; trl = tl trl) {
		if(tabissep(hd trl)) continue;
		cells := tabparsecells(hd trl);
		ci := 0;
		for(; cells != nil && ci < ncols; cells = tl cells) {
			w := mainfont.width(hd cells) + 12;
			if(w > colw[ci]) colw[ci] = w;
			ci++;
		}
	}
	tabtotalw := 0;
	for(twi := 0; twi < ncols; twi++)
		tabtotalw += colw[twi];
	rowh := mainfont.height + 8;
	nrows := listlen(trows);
	total_h := nrows * rowh;
	newmax := total_h - pres_viewport_h;
	if(newmax < 0) newmax = 0;
	maxpresscrollpx = newmax;
	if(art.pany > maxpresscrollpx)
		art.pany = maxpresscrollpx;
	newmaxx := tabtotalw - contentw;
	if(newmaxx < 0) newmaxx = 0;
	maxpanx = newmaxx;
	if(art.panx > maxpanx)
		art.panx = maxpanx;
	yt := contenty - art.pany;
	isheader := 1;
	for(trl = trows; trl != nil; trl = tl trl) {
		rline := hd trl;
		if(tabissep(rline)) {
			if(yt >= contentr.min.y && yt < contentr.max.y)
				mainwin.draw(
					Rect((contentr.min.x + pad, yt),
					     (contentr.max.x - pad, yt + 1)),
					bordercol, nil, (0, 0));
			yt += 3;
			isheader = 0;
			continue;
		}
		if(yt + rowh > contentr.max.y) break;
		if(yt + rowh > contentr.min.y) {
			if(isheader)
				mainwin.draw(
					Rect((contentr.min.x + pad, yt),
					     (contentr.max.x - pad, yt + rowh)),
					headercol, nil, (0, 0));
			cells := tabparsecells(rline);
			ci := 0;
			xt := contentr.min.x + pad - art.panx;
			celcol: ref Image;
			for(; cells != nil && ci < ncols; cells = tl cells) {
				if(isheader) celcol = labelcol;
				else celcol = textcol;
				if(yt >= contentr.min.y)
					mainwin.text((xt + 4, yt + 4),
						celcol, (0, 0), mainfont, hd cells);
				xt += colw[ci];
				ci++;
			}
		}
		if(isheader) isheader = 0;
		yt += rowh;
	}
}

# Render diff artifact — monospace with color-coded lines
drawdiff(art: ref Artifact, contentr: Rect, pad: int, contentw: int, contenty: int)
{
	if(art.data == "") {
		drawcentertext(contentr, "(no changes)");
		return;
	}
	# Allocate red color lazily
	if(redcol_g == nil && display_g != nil) {
		lucitheme := load Lucitheme Lucitheme->PATH;
		if(lucitheme != nil) {
			th := lucitheme->gettheme();
			redcol_g = display_g.color(th.red);
		}
	}

	ls := splitlines(art.data);
	total_h := listlen(ls) * monofont_g.height;
	newmax := total_h - pres_viewport_h;
	if(newmax < 0) newmax = 0;
	maxpresscrollpx = newmax;
	if(art.pany > maxpresscrollpx)
		art.pany = maxpresscrollpx;

	y := contenty - art.pany;
	for(wl := ls; wl != nil; wl = tl wl) {
		line := hd wl;
		if(y + monofont_g.height > contentr.max.y)
			break;
		if(y >= contentr.min.y) {
			col := dimcol;
			if(len line > 0) {
				if(line[0] == '+')
					col = greencol_g;
				else if(line[0] == '-') {
					col = dimcol;
					if(redcol_g != nil)
						col = redcol_g;
				}
				else if(line[0] == '@')
					col = accentcol;
				else
					col = textcol;
			}
			mainwin.text((contentr.min.x + pad - art.panx, y),
				col, (0, 0), monofont_g, line);
		}
		y += monofont_g.height;
	}
}

# Render a single PDF page (uses PDF module directly for page/dpi control).
# Returns (image, pagecount); pagecount is 0 on error.
renderpdfpage(path: string, page: int, dpi: int): (ref Image, int)
{
	if(pdfmod == nil) {
		pdfmod = load PDF PDF->PATH;
		if(pdfmod != nil)
			pdfmod->init(display_g);
	}
	if(pdfmod == nil)
		return (nil, 0);
	fdata := readfilebytes(path);
	if(fdata == nil)
		return (nil, 0);
	(doc, err) := pdfmod->open(fdata, "");
	if(doc == nil) {
		sys->fprint(stderr, "presrender: pdf open %s: %s\n", path, err);
		return (nil, 0);
	}
	np := doc.pagecount();
	(img, nil) := doc.renderpage(page, dpi);
	doc.close();
	return (img, np);
}

# --- Table rendering helpers ---

trimcell(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t')) i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n')) j--;
	if(i >= j) return "";
	return s[i:j];
}

tabparsecells(line: string): list of string
{
	cells: list of string;
	i := 0;
	n := len line;
	while(i < n && (line[i] == ' ' || line[i] == '\t')) i++;
	if(i < n && line[i] == '|') i++;
	while(i < n) {
		j := i;
		while(j < n && line[j] != '|') j++;
		cell := trimcell(line[i:j]);
		cells = cell :: cells;
		if(j >= n) break;
		i = j + 1;
	}
	if(cells != nil && hd cells == "")
		cells = tl cells;
	rev: list of string;
	for(; cells != nil; cells = tl cells)
		rev = hd cells :: rev;
	return rev;
}

tabissep(line: string): int
{
	cells := tabparsecells(line);
	if(cells == nil) return 0;
	for(; cells != nil; cells = tl cells) {
		c := hd cells;
		if(len c == 0) return 0;
		for(i := 0; i < len c; i++) {
			ch := c[i];
			if(ch != '-' && ch != ':' && ch != ' ')
				return 0;
		}
	}
	return 1;
}

tabcountcols(line: string): int
{
	n := 0;
	for(cl := tabparsecells(line); cl != nil; cl = tl cl)
		n++;
	return n;
}

# --- Word wrap / split ---

wraptext(text: string, maxw: int): list of string
{
	if(text == nil || text == "")
		return "" :: nil;

	lines: list of string;
	line := "";

	i := 0;
	while(i < len text) {
		while(i < len text && (text[i] == ' ' || text[i] == '\t'))
			i++;
		if(i >= len text)
			break;
		wstart := i;
		while(i < len text && text[i] != ' ' && text[i] != '\t' && text[i] != '\n')
			i++;
		word := text[wstart:i];

		if(i < len text && text[i] == '\n') {
			if(line != "")
				line += " " + word;
			else
				line = word;
			lines = line :: lines;
			line = "";
			i++;
			continue;
		}

		candidate: string;
		if(line != "")
			candidate = line + " " + word;
		else
			candidate = word;

		if(mainfont.width(candidate) > maxw && line != "") {
			lines = line :: lines;
			line = word;
		} else {
			line = candidate;
		}
	}
	if(line != "")
		lines = line :: lines;
	if(lines == nil)
		return "" :: nil;

	rev: list of string;
	for(; lines != nil; lines = tl lines)
		rev = hd lines :: rev;
	return rev;
}

splitlines(text: string): list of string
{
	if(text == nil || text == "")
		return "" :: nil;
	lines: list of string;
	i := 0;
	linestart := 0;
	while(i < len text) {
		if(text[i] == '\n') {
			lines = text[linestart:i] :: lines;
			linestart = i + 1;
		}
		i++;
	}
	if(linestart < len text)
		lines = text[linestart:] :: lines;
	rev: list of string;
	for(; lines != nil; lines = tl lines)
		rev = hd lines :: rev;
	return rev;
}

# --- Helpers ---

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	result := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
	}
	if(result == "")
		return nil;
	return result;
}

readfilebytes(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	data := array[0] of byte;
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		newdata := array[len data + n] of byte;
		newdata[0:] = data;
		newdata[len data:] = buf[0:n];
		data = newdata;
	}
	if(len data == 0)
		return nil;
	return data;
}

strip(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	return s;
}

strtoint(s: string): int
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	if(i >= len s)
		return -1;
	n := 0;
	for(; i < len s; i++) {
		c := s[i];
		if(c < '0' || c > '9')
			return -1;
		if(n > 214748364 || (n == 214748364 && (c - '0') > 7))
			return -1;
		n = n * 10 + (c - '0');
	}
	return n;
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

listlen(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}
