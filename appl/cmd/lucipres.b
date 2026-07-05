implement LuciPres;

#
# lucipres - Presentation zone for Lucifer
#
# Standard wmclient app: gets its window Image from lucifer's wmsrv
# (preswmloop), so it can in future run remotely via 9cpu.
# Usage: lucipres [mountpt [actid]]
# args passed by lucifer: "lucipres" mountpt actid_string
#
# TODO(architecture): Presentation rendering (markdown, mermaid, images,
# PDF, code, etc.) is tightly coupled to this wmclient window.  App tabs
# (editor, shell, fractal) get their own wmclient windows managed via
# z-order in lucifer's preswmloop, but presentation content is drawn
# directly into lucipres's image.  This dual rendering path causes
# z-order races when switching between app and presentation tabs
# (see tab click handler below).
#
# The correct fix is to factor presentation rendering into its own
# wmclient app — a peer to editor/shell/fractal in the z-stack — so
# that ALL tab switches use uniform z-order management.  lucipres would
# become a thin tab-bar + event coordinator.
#
# WARNING: This refactor is non-trivial.  The render registry
# (xenith/render.b), all individual renderers (imgrender, mdrender,
# htmlrender, pdfrender, mermaidrender), the async render pipeline
# (renderdonech, renderartasync), scroll/zoom/pan state, PDF page
# navigation, and the AI agent's use of the presentation space
# (artifact creation, centering, app launching) are all coupled to
# the current architecture.  See docs/TODO-LUCIPRES-ARCHITECTURE.md.
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

include "menu.m";

include "viewport.m";

include "plumbmsg.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";

include "wmclient.m";
	wmclient: Wmclient;

LuciPres: module
{
	PATH: con "/dis/lucipres.dis";
	init: fn(ctxt: ref Draw->Context, args: list of string);
	deliverevent: fn(ev: string);
	# lucifer hands us the current shared presscr (re-sent on resize)
	# so context menus can be drawn on a top-most overlay window above
	# the app windows that cover the presentation content area.
	setpresscr: fn(scr: ref Screen);
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

TabRect: adt {
	r:  Rect;
	id: string;
};

Attr: adt {
	key: string;
	val: string;
};

TaskCard: adt {
	id: int;
	label: string;
	status: string;
	urgency: int;
};

CardHit: adt {
	r: Rect;
	id: int;
};

# --- Module state ---

rlay: Rlayout;
DocNode: import rlay;

pdfmod: PDF;
Doc: import pdfmod;

rendermod: Render;

menumod: Menu;
Popup: import menumod;

vpmod: Viewport;
View: import vpmod;

plumbmod: Plumbmsg;
Msg: import plumbmod;

gifwriter: WImagefile;

stderr: ref Sys->FD;
win: ref Wmclient->Window;
mainwin: ref Image;
backbuf: ref Image;		# off-screen back buffer for double-buffered redraw
display_g: ref Display;
presscr_g: ref Screen;		# shared presscr (from lucifer) for menu overlays
mainfont: ref Font;
monofont_g: ref Font;
mountpt_g: string;
actid_g := -1;
preseventch: chan of string;

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

# Presentation state
artifacts: list of ref Artifact;
nart := 0;
centeredart: string;
artrendw := 0;
maxpresscrollpx := 0;
maxpanx := 0;
mobile := 0;	# set from /env/infmobile in init() (accordion / 44pt tap targets)
pres_viewport_h := 400;

# Long-press → context menu (mobile).  Desktop uses button-3; touch has no
# right-click, so a press-and-hold that doesn't move opens the same menu.
LONGPRESS_MS:  con 500;	# hold duration
LONGPRESS_SLOP: con 20;	# movement (px) that cancels the press
lpch:      chan of int;	# timer fires the press sequence id back here
lpseq      := 0;	# bumped on every new press; stale timers are ignored
lppending  := 0;	# a press is being timed
lppos:     Point;	# where the press started

# Tab state
tablayout: array of ref TabRect;
ntabs := 0;
tabscrolloff := 0;
tabstrip_miny := 0;
tabstrip_maxy := 0;
prescontentr: Rect;

# Dashboard card hit-test
cardhits: array of ref CardHit;
ncardhits := 0;

# PDF nav rects
pdfnavprev: Rect;
pdfnavnext: Rect;

# Pixels per tab for button-2 drag scroll sensitivity
TABDRAGPX: con 60;

# --- init (standard wmclient app interface) ---

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr = sys->fildes(2);

	# Initialize event channels FIRST — lucifer's nslistener can call
	# deliverevent() as soon as lucipres_g is set (before init completes).
	# alt send on a nil channel is a fatal "dereference of nil" in Dis.
	preseventch = chan[8] of string;
	renderdonech = chan[32] of ref RenderResult;

	wmclient = load Wmclient Wmclient->PATH;
	if(wmclient == nil) {
		sys->fprint(sys->fildes(2), "lucipres: cannot load wmclient: %r\n");
		return;
	}
	wmclient->init();

	# Parse args: "lucipres" mountpt actid
	a := args;
	if(a != nil) a = tl a;	# skip "lucipres"
	if(a != nil) { mountpt_g = hd a; a = tl a; }
	else mountpt_g = "/mnt/ui";
	if(a != nil) { actid_g = strtoint(hd a); a = tl a; }

	if(ctxt == nil)
		ctxt = wmclient->makedrawcontext();
	display_g = ctxt.display;
	if(display_g == nil) {
		sys->fprint(stderr, "lucipres: display is nil\n");
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
	lpch = chan of int;	# long-press timer signal

	# Load theme colours
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme == nil) {
		sys->fprint(stderr, "lucipres: cannot load lucitheme: %r\n");
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
		sys->fprint(stderr, "lucipres: wmclient->window returned nil\n");
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
		sys->fprint(stderr, "lucipres: win.image is nil after onscreen\n");
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

	# Load fonts
	mainfont = Font.open(display_g, "/fonts/combined/unicode.sans.14.font");
	if(mainfont == nil)
		mainfont = Font.open(display_g, "*default*");
	if(mainfont == nil) {
		sys->fprint(stderr, "lucipres: cannot load any font\n");
		return;
	}
	monofont_g = Font.open(display_g, "/fonts/combined/unicode.14.font");
	if(monofont_g == nil)
		monofont_g = mainfont;

	# Load rlayout
	rlay = load Rlayout Rlayout->PATH;
	if(rlay != nil)
		rlay->init(display_g);

	# Load render registry
	rendermod = load Render Render->PATH;
	if(rendermod != nil)
		rendermod->init(display_g);

	# Load menu module
	menumod = load Menu Menu->PATH;
	if(menumod == nil)
		sys->fprint(stderr, "lucipres: cannot load menu: %r\n");
	else
		menumod->init(display_g, mainfont);

	# Load viewport
	vpmod = load Viewport Viewport->PATH;

	# Load plumbmsg and open the 'presentation' plumb port.  This is how
	# every picker path — the ftree file tree, the context panel, an
	# agent, or the `plumb` command — opens a file into the presentation
	# view: it sends a plumb message, the stock plumber (started in
	# boot.sh) matches /lib/lucifer/plumbing and forwards it here, and
	# plumbreceiver() turns it into the right artifact.  The plumber comes
	# up before us in the boot, but retry briefly in case it is still
	# starting; if it never appears we simply run without the consumer
	# (ftree falls back to writing /mnt/ui directly).
	plumbmod = load Plumbmsg Plumbmsg->PATH;
	if(plumbmod != nil) {
		tries := 0;
		while(plumbmod->init(1, "presentation", 8192) < 0 && tries < 25) {
			sys->sleep(200);
			tries++;
		}
		if(tries >= 25) {
			sys->fprint(sys->fildes(2), "lucipres: plumb consumer unavailable (no plumber?); pickers use the /mnt/ui fallback\n");
			plumbmod = nil;
		} else {
			sys->fprint(sys->fildes(2), "lucipres: plumb consumer listening on 'presentation'\n");
			spawn plumbreceiver();
		}
	}

	# Load bufio + GIF writer for image export
	bufio = load Bufio Bufio->PATH;
	if(bufio != nil) {
		gifwriter = load WImagefile WImagefile->WRITEGIFPATH;
		if(gifwriter != nil)
			gifwriter->init(bufio);
	}

	if(actid_g >= 0)
		loadpresentation();

	# Auto-create taskboard artifact for meta-agent if none exist
	if(actid_g == 0 && artifacts == nil) {
		pctl := sys->sprint("%s/activity/%d/presentation/ctl", mountpt_g, actid_g);
		pfd := sys->open(pctl, Sys->OWRITE);
		if(pfd != nil) {
			cmd := array of byte "create id=tasks type=taskboard label=Tasks";
			sys->write(pfd, cmd, len cmd);
			pfd = nil;
		}
		loadpresentation();
	}

	# Auto-center on first artifact if nothing is centered
	# (handles external creation, e.g., shell launch scripts)
	if(centeredart == "" && artifacts != nil) {
		centeredart = (hd artifacts).id;
		if(actid_g >= 0)
			writetofile(sys->sprint("%s/activity/%d/presentation/ctl",
				mountpt_g, actid_g), "center id=" + centeredart);
	}

	redrawpres();

	# Event loop
	prevbuttons := 0;
	b2tabdragging := 0;
	b2dragstartx := 0;
	b2dragstartoff := 0;
	# Mobile touch (button-1) tab-strip gesture state: a press in the tab
	# strip becomes a horizontal drag-scroll if it moves, or a tab switch
	# on release if it doesn't (so a swipe never activates the tab under
	# the finger).  Desktop keeps switch-on-press.
	b1tabdragging := 0;
	b1dragstartx := 0;
	b1dragstartoff := 0;
	b1pendid := "";		# artifact id to switch to on release (mobile tap)
	for(;;) alt {
	p := <-win.ctxt.ptr =>
		if(wmclient->win.pointer(*p) == 0) {
			wasdown := prevbuttons;
			prevbuttons = p.buttons;

			# Cancel a pending long-press if the finger lifted or moved.
			if(lppending) {
				dx := p.xy.x - lppos.x;
				if(dx < 0) dx = -dx;
				dy := p.xy.y - lppos.y;
				if(dy < 0) dy = -dy;
				if((p.buttons & 1) == 0 ||
						dx > LONGPRESS_SLOP || dy > LONGPRESS_SLOP)
					lppending = 0;
			}

			# Mobile: a held button-1 drag inside the tab strip scrolls
			# it horizontally.  Once the finger moves past the slop the
			# press is a drag, not a tap, so the deferred switch is
			# suppressed on release (see the button-1 release handler).
			if(mobile && b1pendid != "" && (p.buttons & 1)) {
				ddx := b1dragstartx - p.xy.x;
				addx := ddx;
				if(addx < 0) addx = -addx;
				if(addx > LONGPRESS_SLOP)
					b1tabdragging = 1;
				if(b1tabdragging) {
					noff := b1dragstartoff + ddx / TABDRAGPX;
					if(noff < 0) noff = 0;
					if(noff >= nart) noff = nart - 1;
					if(noff < 0) noff = 0;
					if(noff != tabscrolloff) {
						tabscrolloff = noff;
						redrawpres();
					}
				}
			}

			# Scroll wheel
			if(p.buttons & 8) {
				intabstrip := (tabstrip_maxy > tabstrip_miny &&
					p.xy.y >= tabstrip_miny && p.xy.y < tabstrip_maxy);
				if(intabstrip) {
					if(tabscrolloff > 0)
						tabscrolloff--;
				} else
					prescroll(-1);
				redrawpres();
			} else if(p.buttons & 16) {
				intabstrip := (tabstrip_maxy > tabstrip_miny &&
					p.xy.y >= tabstrip_miny && p.xy.y < tabstrip_maxy);
				if(intabstrip) {
					if(tabscrolloff < nart - 1)
						tabscrolloff++;
				} else
					prescroll(1);
				redrawpres();
			}

			# Button-1 just pressed
			if(p.buttons == 1 && wasdown == 0) {
				# Mobile long-press → context menu is now synthesised in
				# the shared SDL3 touch layer as a real button-3 press
				# (INFR-163), handled by the button-3 branch below — same
				# path as a desktop right-click. No per-zone timer here.
				tabclicked := 0;
				# Tab clicks
				for(ti := 0; ti < ntabs; ti++) {
					if(tablayout[ti].r.contains(p.xy)) {
						if(mobile) {
							# Defer the switch to release: a press
							# that turns into a horizontal drag
							# scrolls the strip instead of switching
							# (see the button-1 move/release handlers).
							b1pendid = tablayout[ti].id;
							b1dragstartx = p.xy.x;
							b1dragstartoff = tabscrolloff;
							b1tabdragging = 0;
							tabclicked = 1;
							break;
						}
						if(tablayout[ti].id != centeredart) {
							oldart := findartifact(centeredart);
							centeredart = tablayout[ti].id;
							if(actid_g >= 0)
								writetofile(
									sys->sprint("%s/activity/%d/presentation/ctl",
										mountpt_g, actid_g),
									"center id=" + centeredart);
							# When switching away from an app tab,
							# skip the immediate redraw.  lucifer
							# must call hideapp() first to move the
							# app window below us in the z-stack;
							# the "presentation current" event will
							# trigger redraw after that completes.
							if(oldart == nil || oldart.atype != "app")
								redrawpres();
						} else
							redrawpres();
						tabclicked = 1;
						break;
					}
				}
				# PDF page navigation
				if(!tabclicked) {
					if(pdfnavprev.max.x > pdfnavprev.min.x &&
							pdfnavprev.contains(p.xy)) {
						pdfart := findartifact(centeredart);
						if(pdfart != nil && pdfart.pdfpage > 1) {
							pdfart.pdfpage--;
							pdfart.rendimg = nil;
							pdfart.pany = 0;
							pdfart.panx = 0;
							redrawpres();
						}
						tabclicked = 1;
					} else if(pdfnavnext.max.x > pdfnavnext.min.x &&
							pdfnavnext.contains(p.xy)) {
						pdfart := findartifact(centeredart);
						if(pdfart != nil && (pdfart.numpages == 0 || pdfart.pdfpage < pdfart.numpages)) {
							pdfart.pdfpage++;
							pdfart.rendimg = nil;
							pdfart.pany = 0;
							pdfart.panx = 0;
							redrawpres();
						}
						tabclicked = 1;
					}
				}
				# Dashboard card click — switch to activity or create new task
				if(!tabclicked && prescontentr.contains(p.xy)) {
					cart := findartifact(centeredart);
					if(cart != nil && cart.atype == "taskboard") {
						for(ci := 0; ci < ncardhits; ci++) {
							if(cardhits[ci].r.contains(p.xy)) {
								if(cardhits[ci].id == -1) {
									# "+" card — request new task
									writetofile(mountpt_g + "/ctl",
										"newtask");
								} else {
									writetofile(mountpt_g + "/activity/current",
										string cardhits[ci].id);
								}
								tabclicked = 1;
								break;
							}
						}
					}
				}
				# Drag in content area
				if(!tabclicked && prescontentr.contains(p.xy)) {
					dart := findartifact(centeredart);
					if(dart != nil && dart.atype != "app") {
						handledrag(dart, p.xy);
						prevbuttons = 0;
					}
				}
			}

			# Button-2 drag in tab strip for horizontal tab scrolling
			intabstrip2 := (tabstrip_maxy > tabstrip_miny &&
				p.xy.y >= tabstrip_miny && p.xy.y < tabstrip_maxy);
			if(p.buttons & 2) {
				if(intabstrip2) {
					if(b2tabdragging == 0) {
						b2tabdragging = 1;
						b2dragstartx = p.xy.x;
						b2dragstartoff = tabscrolloff;
					} else {
						delta := (b2dragstartx - p.xy.x) / TABDRAGPX;
						newoff := b2dragstartoff + delta;
						if(newoff < 0) newoff = 0;
						if(newoff >= nart) newoff = nart - 1;
						if(newoff < 0) newoff = 0;
						if(newoff != tabscrolloff) {
							tabscrolloff = newoff;
							redrawpres();
						}
					}
				}
			} else
				b2tabdragging = 0;

			# Button-3: context menu (desktop right-click, or a touch
			# long-press synthesised as button-3 by the SDL3 layer).
			if((p.buttons & 4) != 0 && (wasdown & 4) == 0) {
				if(menumod != nil) {
					# A touch long-press lands as button-1 down then a
					# transition to button-3; drop the deferred tab tap so
					# the menu doesn't also switch tabs on release.
					b1pendid = "";
					b1tabdragging = 0;
					handlecontextmenu(p);
					prevbuttons = 0;
					redrawpres();
				}
			}

			# Mobile: button-1 released after a tab-strip press.  If the
			# press never became a drag, it was a tap → switch tabs now.
			if(mobile && b1pendid != "" && (p.buttons & 1) == 0) {
				if(!b1tabdragging && b1pendid != centeredart) {
					oldart := findartifact(centeredart);
					centeredart = b1pendid;
					if(actid_g >= 0)
						writetofile(
							sys->sprint("%s/activity/%d/presentation/ctl",
								mountpt_g, actid_g),
							"center id=" + centeredart);
					if(oldart == nil || oldart.atype != "app")
						redrawpres();
				}
				b1pendid = "";
				b1tabdragging = 0;
			}
		}
	seq := <-lpch =>
		# Long-press fired: if that press is still held (not lifted/moved)
		# open the context menu at the press point, mimicking button-3.
		if(mobile && lppending && seq == lpseq) {
			lppending = 0;
			# This press opened a menu, not a tab tap: drop the
			# deferred switch so releasing afterwards is a no-op.
			b1pendid = "";
			b1tabdragging = 0;
			if(menumod != nil) {
				handlecontextmenu(ref Pointer(0, lppos, 0));
				prevbuttons = 0;
				redrawpres();
			}
		}
	ev := <-preseventch =>
		handleevent(ev);
		redrawpres();
	rr := <-renderdonech =>
		handlerenderdone(rr);
		redrawpres();
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
			for(al := artifacts; al != nil; al = tl al)
				(hd al).rendimg = nil;
			artrendw = 0;
			redrawpres();
		}
	}
}

deliverevent(ev: string)
{
	alt {
	preseventch <-= ev =>
		;
	* =>
		;
	}
}

# lucifer calls this at startup and after every resize (handleresize
# reallocates presscr).  Context menus are drawn on a top-most overlay
# window allocated here so they float above the presentation app window.
setpresscr(scr: ref Screen)
{
	presscr_g = scr;
}

handleevent(ev: string)
{
	if(hasprefix(ev, "switchactivity ")) {
		newid := strtoint(ev[len "switchactivity ":]);
		if(newid >= 0) {
			actid_g = newid;
			loadpresentation();
		}
		return;
	}
	if(hasprefix(ev, "activity ")) {
		# Activity created or deleted — redraw taskboard if visible
		return;
	}
	if(ev == "presentation current") {
		s := readfile(sys->sprint("%s/activity/%d/presentation/current",
			mountpt_g, actid_g));
		if(s != nil) {
			centeredart = strip(s);
		}
	} else if(hasprefix(ev, "presentation new ")) {
		id := strip(ev[len "presentation new ":]);
		if(id != "")
			loadartifact(id);
	} else if(hasprefix(ev, "presentation kill ")) {
		# "presentation kill <id>" — app was killed; remove its tab.
		#
		# MUST be handled BEFORE the catch-all "presentation " branch below.
		# Without this case, "presentation kill clock" falls through to:
		#   updateartifact("kill clock") → loadartifact("kill clock")
		# which creates a bogus "kill clock" tab in the tab bar.
		#
		# luciuisrv emits both "presentation kill <id>" and then
		# "presentation delete <id>" when the kill ctl command is processed.
		# Handling kill here is belt-and-suspenders — delete will also fire.
		id := strip(ev[len "presentation kill ":]);
		if(id != "")
			deleteartifact(id);
	} else if(hasprefix(ev, "presentation delete ")) {
		id := strip(ev[len "presentation delete ":]);
		if(id != "")
			deleteartifact(id);
	} else if(hasprefix(ev, "presentation app ")) {
		# "presentation app <id> status=<s>" — update appstatus field
		rest := ev[len "presentation app ":] ;
		# split rest into first word (id) and remainder (attrs)
		sppos := 0;
		for(; sppos < len rest && rest[sppos] != ' ' && rest[sppos] != '	'; sppos++)
			;
		appid := strip(rest[0:sppos]);
		attrs2 := "";
		if(sppos < len rest)
			attrs2 = strip(rest[sppos:]);
		status := "";
		needle := "status=";
		for(si := 0; si + len needle <= len attrs2; si++) {
			if(attrs2[si:si + len needle] == needle) {
				status = strip(attrs2[si + len needle:]);
				break;
			}
		}
		if(appid != "" && status != "") {
			for(aal := artifacts; aal != nil; aal = tl aal) {
				if((hd aal).id == appid) {
					(hd aal).appstatus = status;
					break;
				}
			}
		}
	} else if(hasprefix(ev, "theme ")) {
		reloadcolors();
	} else if(hasprefix(ev, "presentation ")) {
		id := strip(ev[len "presentation ":]);
		if(id != "")
			updateartifact(id);
	}
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
	if(menumod != nil)
		menumod->retheme(display_g);
	# Invalidate rendered artifact caches
	for(al := artifacts; al != nil; al = tl al)
		(hd al).rendimg = nil;
	artrendw = 0;
}

# --- Drawing ---

redrawpres()
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
	drawpresentation(mainwin.r);
	if(backbuf != nil) {
		mainwin = front;
		mainwin.draw(mainwin.r, backbuf, nil, backbuf.r.min);
	}
	mainwin.flush(Draw->Flushnow);
}

drawpresentation(zone: Rect)
{
	pad := 8;
	pdfnavprev = Rect((0,0),(0,0));
	pdfnavnext = Rect((0,0),(0,0));
	al: list of ref Artifact;
	centart: ref Artifact;

	centart = nil;
	for(al = artifacts; al != nil; al = tl al) {
		if((hd al).id == centeredart) {
			centart = hd al;
			break;
		}
	}
	if(centart == nil && artifacts != nil)
		centart = hd artifacts;

	# Tab strip at top — always drawn so every activity shows its tab
	# display, even one holding no artifacts.  (The task browser / taskboard
	# stays exclusive to activity 0; this only guarantees the strip itself.)
	tabh := mainfont.height + 12;
	if(mobile && tabh < 132)
		tabh = 132;	# 44pt finger tap target for the tab strip
	tabr := Rect((zone.min.x, zone.min.y), (zone.max.x, zone.min.y + tabh));
	mainwin.draw(tabr, headercol, nil, (0, 0));

	tabstrip_miny = tabr.min.y;
	tabstrip_maxy = tabr.max.y;

	tablayout = array[nart + 1] of ref TabRect;
	ntabs = 0;

	tx := zone.min.x + pad;
	tskip := tabscrolloff;
	for(al = artifacts; al != nil; al = tl al) {
		art := hd al;
		if(tskip > 0) { tskip--; continue; }
		tw := mainfont.width(art.label);
		if(tx + tw + pad > zone.max.x)
			break;
		active := 0;
		if(art.id == centart.id)
			active = 1;
		tcol := text2col;
		# Centre the label vertically within the (possibly tall, on mobile)
		# tab strip; the active-tab accent stays a bottom border.
		laby := tabr.min.y + (tabh - mainfont.height) / 2;
		if(active) {
			tcol = textcol;
			mainwin.draw(Rect((tx, tabr.max.y - 3), (tx + tw, tabr.max.y - 1)),
				accentcol, nil, (0, 0));
		}
		mainwin.text((tx, laby), tcol, (0, 0), mainfont, art.label);
		# Status dot for app tabs
		if(art.atype == "app") {
			dotcol: ref Image;
			if(art.appstatus == "running")
				dotcol = greencol_g;
			else
				dotcol = dimcol;
			# Size the running-status dot relative to the font so it
			# stays visible on Retina/mobile (a fixed 5px is microscopic
			# at 3x) while remaining ~5px on desktop.
			dotsz := mainfont.height / 3;
			if(dotsz < 5)
				dotsz = 5;
			dotx := tx + tw + 4;
			doty := tabr.min.y + (tabr.dy() - dotsz) / 2;
			mainwin.draw(Rect((dotx, doty), (dotx + dotsz, doty + dotsz)), dotcol, nil, (0, 0));
		}
		if(ntabs < len tablayout)
			tablayout[ntabs++] = ref TabRect(
				Rect((tx, tabr.min.y), (tx + tw + 20, tabr.max.y)), art.id);
		tx += tw + 20;
	}

	# Separator below tabs
	mainwin.draw(Rect((zone.min.x, tabr.max.y), (zone.max.x, tabr.max.y + 1)),
		bordercol, nil, (0, 0));

	# Content area
	contentr := Rect((zone.min.x, tabr.max.y + 1), (zone.max.x, zone.max.y));
	prescontentr = contentr;
	# No artifacts (e.g. an empty non-zero activity): the tab strip is drawn
	# above; show the placeholder in the body rather than skipping the strip.
	if(centart == nil) {
		drawcentertext(contentr, "No artifacts");
		return;
	}
	contentw := contentr.dx() - 2 * pad;
	contenty := contentr.min.y + pad;
	pres_viewport_h = contentr.dy() - 2 * pad;

	# Invalidate render caches on width change
	if(contentw != artrendw) {
		for(al = artifacts; al != nil; al = tl al)
			(hd al).rendimg = nil;
		artrendw = contentw;
	}

	# Draw the centered artifact's content INLINE, in this same window.
	#
	# Restored from the pre-2026-07-04 design.  The presrender split drew
	# content in a SEPARATE window that lucifer revealed via z-order
	# (top()) but loaded via a droppable non-blocking event — the two
	# desynced on real displays, leaving presrender shown-but-empty ("No
	# content").  Owning the tab strip AND the content in one window makes
	# "shown" and "loaded" the same act, so they can't desync.  The async
	# render path (renderartasync → renderdonech → handlerenderdone) is
	# unchanged; only the draw dispatch below came back.
	case centart.atype {
	"text" or "code" =>
		if(centart.atype == "code")
			mainwin.draw(contentr, codebgcol_g, nil, (0, 0));
		ls := splitlines(centart.data);
		total_h := listlen(ls) * monofont_g.height;
		newmax2 := total_h - pres_viewport_h;
		if(newmax2 < 0) newmax2 = 0;
		maxpresscrollpx = newmax2;
		if(centart.pany > maxpresscrollpx)
			centart.pany = maxpresscrollpx;
		maxlinew := 0;
		for(wlm := ls; wlm != nil; wlm = tl wlm) {
			lw := monofont_g.width(hd wlm);
			if(lw > maxlinew) maxlinew = lw;
		}
		newmaxx2 := maxlinew - contentw;
		if(newmaxx2 < 0) newmaxx2 = 0;
		maxpanx = newmaxx2;
		if(centart.panx > maxpanx)
			centart.panx = maxpanx;
		y2 := contenty - centart.pany;
		wl: list of string;
		for(wl = ls; wl != nil; wl = tl wl) {
			if(y2 + monofont_g.height > contentr.max.y)
				break;
			if(y2 >= contentr.min.y)
				mainwin.text((contentr.min.x + pad - centart.panx, y2),
					textcol, (0, 0), monofont_g, hd wl);
			y2 += monofont_g.height;
		}
		if(centart.data == "")
			drawcentertext(contentr, "(empty)");
	"pdf" =>
		navh := mainfont.height + 8;
		pdfcontent := Rect(contentr.min, (contentr.max.x, contentr.max.y - navh));
		pdfnav := Rect((contentr.min.x, contentr.max.y - navh), contentr.max);
		drawpdfnav(pdfnav, centart);
		pres_viewport_h = pdfcontent.dy() - 2 * pad;
		if(centart.rendimg == nil)
			centart.rendimg = renderart(centart, contentw);
		drawrendimg(centart, pdfcontent, pad, contentw, "cannot render PDF");
	"table" =>
		drawtable(centart, contentr, pad, contentw, contenty);
	"app" =>
		# Only while the app is still starting; a running app's own window
		# owns this area (a placeholder would bleed through partial-paint
		# apps like tetris/matrix).
		if(centart.appstatus != "running")
			drawcentertext(contentr, "Launching " + centart.label + "...");
	"taskboard" =>
		drawtaskboard(contentr, pad);
	"diff" =>
		drawdiff(centart, contentr, pad, contentw, contenty);
	* =>
		# markdown, doc, image, mermaid, … — rendered off the event loop.
		if(centart.rendimg == nil && centart.data != "") {
			if(centart.rendering == 0) {
				centart.rendering = 1;
				spawn renderartasync(centart.id, centart.atype, centart.data, contentw);
			}
		}
		if(centart.rendimg != nil) {
			centart.rendering = 0;
			drawrendimg(centart, contentr, pad, contentw, nil);
		} else if(centart.rendering == 1)
			drawcentertext(contentr, "Rendering...");
		else if(centart.rendering == 2)
			drawfallbacktext(centart, contentr, pad, contentw, contenty);
		else if(centart.data == "")
			drawcentertext(contentr, "(empty)");
		else
			drawfallbacktext(centart, contentr, pad, contentw, contenty);
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
	art := findartifact(centeredart);
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
		redrawpres();
	}
}

# --- Context menu ---

# Long-press timer: after LONGPRESS_MS, signal the press sequence back to
# the event loop, which opens the context menu if that press is still held.
lptimer(seq: int)
{
	sys->sleep(LONGPRESS_MS);
	lpch <-= seq;
}

# Show a context menu.  When lucifer has handed us the shared presscr
# (setpresscr), draw on a top-most overlay window so the menu floats
# above the presentation app window — which is stacked above our own
# zone window, and would otherwise occlude a menu drawn on mainwin.
# Falls back to drawing on our own window if presscr isn't available.
popmenu(pop: ref Popup, at: Point): int
{
	if(presscr_g != nil && win != nil && win.image != nil)
		return pop.showtop(presscr_g, win.image.r, at, win.ctxt.ptr);
	return pop.show(mainwin, at, win.ctxt.ptr);
}

handlecontextmenu(p: ref Pointer)
{
	# Dashboard card right-click — "End Task" menu
	if(prescontentr.contains(p.xy)) {
		tbart := findartifact(centeredart);
		if(tbart != nil && tbart.atype == "taskboard") {
			for(ci := 0; ci < ncardhits; ci++) {
				if(cardhits[ci].r.contains(p.xy)) {
					cid := cardhits[ci].id;
					if(cid == -1)
						return;	# "+ New Task" button — no context menu
					mitems := array[] of {"End Task"};
					mpop := menumod->new(mitems);
					mres := popmenu(mpop, p.xy);
					if(mres == 0)
						writetofile(mountpt_g + "/ctl",
							"activity delete " + string cid);
					return;
				}
			}
			return;	# clicked in taskboard area but not on a card
		}
	}

	artid := "";
	for(ti := 0; ti < ntabs; ti++)
		if(tablayout[ti].r.contains(p.xy)) {
			artid = tablayout[ti].id;
			break;
		}
	if(artid == "" && prescontentr.max.x > prescontentr.min.x &&
			prescontentr.contains(p.xy))
		artid = centeredart;

	if(artid == "")
		return;

	art := findartifact(artid);
	# App type: Close menu
	if(art != nil && art.atype == "app") {
		closeitems := array[] of {"Close"};
		closepop := menumod->new(closeitems);
		killresult := popmenu(closepop, p.xy);
		if(killresult == 0 && actid_g >= 0)
			writetofile(
				sys->sprint("%s/activity/%d/presentation/ctl",
					mountpt_g, actid_g),
				"kill id=" + artid);
		return;
	}
	if(art == nil)
		return;
	# Build menu based on artifact type
	items: array of string;
	case art.atype {
	"pdf" or "image" =>
		# Already files on disk — no export needed
		items = array[] of {"Close", "Zoom In", "Zoom Out", "Reset View"};
	"mermaid" =>
		# Rendered diagram — export source or rendered image
		items = array[] of {"Close", "Zoom In", "Zoom Out", "Reset View",
			"Export Source", "Export Image"};
	* =>
		# Text content — export to file
		items = array[] of {"Close", "Zoom In", "Zoom Out", "Reset View", "Export"};
	}
	pop := menumod->new(items);
	result := popmenu(pop, p.xy);
	case result {
	0 =>
		deleteartifactui(artid);
	1 =>
		if(art != nil) {
			art.zoom = artzoom(art) + 25;
			if(art.zoom > 400) art.zoom = 400;
			art.rendimg = nil;
		}
	2 =>
		if(art != nil) {
			art.zoom = artzoom(art) - 25;
			if(art.zoom < 25) art.zoom = 25;
			art.rendimg = nil;
		}
	3 =>
		if(art != nil) {
			art.zoom = 0;
			art.panx = 0;
			art.pany = 0;
			art.rendimg = nil;
		}
	4 =>
		exportartifact(art);
	5 =>
		# Only reachable for mermaid: Export Image
		if(art != nil)
			exportimage(art);
	}
}

# --- Namespace loading ---

loadpresentation()
{
	artifacts = nil;
	nart = 0;
	centeredart = "";

	base := sys->sprint("%s/activity/%d/presentation", mountpt_g, actid_g);
	s := readfile(base + "/current");
	if(s != nil)
		centeredart = strip(s);

	fd := sys->open(base, Sys->OREAD);
	if(fd == nil)
		return;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(di := 0; di < n; di++) {
			nm := dirs[di].name;
			if(nm == "ctl" || nm == "current" || nm == ".." || nm == ".")
				continue;
			if(!(dirs[di].mode & Sys->DMDIR))
				continue;
			artbase := base + "/" + nm;
			atype := readfile(artbase + "/type");
			if(atype != nil) atype = strip(atype);
			label := readfile(artbase + "/label");
			if(label != nil) label = strip(label);
			data := readfile(artbase + "/data");
			appstatus := readfile(artbase + "/appstatus");
			if(atype == nil || atype == "") atype = "text";
			if(label == nil || label == "") label = nm;
			if(data == nil) data = "";
			if(appstatus == nil) appstatus = "";
			else appstatus = strip(appstatus);
			art := ref Artifact(nm, atype, label, data, nil, 1, 0, 0, 0, appstatus, 0, 0);
			artifacts = art :: artifacts;
			nart++;
		}
	}
	artifacts = revarts(artifacts);
}

loadartifact(id: string)
{
	# Deduplicate: skip if already loaded
	if(findartifact(id) != nil)
		return;
	base := sys->sprint("%s/activity/%d/presentation/%s", mountpt_g, actid_g, id);
	atype := readfile(base + "/type");
	if(atype != nil) atype = strip(atype);
	label := readfile(base + "/label");
	if(label != nil) label = strip(label);
	data := readfile(base + "/data");
	appstatus2 := readfile(base + "/appstatus");
	if(atype == nil || atype == "") atype = "text";
	if(label == nil || label == "") label = id;
	if(data == nil) data = "";
	if(appstatus2 == nil) appstatus2 = "";
	else appstatus2 = strip(appstatus2);
	art := ref Artifact(id, atype, label, data, nil, 1, 0, 0, 0, appstatus2, 0, 0);
	artifacts = appendart(artifacts, art);
	nart++;
}

updateartifact(id: string)
{
	base := sys->sprint("%s/activity/%d/presentation/%s", mountpt_g, actid_g, id);
	atype := readfile(base + "/type");
	if(atype != nil) atype = strip(atype);
	label := readfile(base + "/label");
	if(label != nil) label = strip(label);
	data := readfile(base + "/data");
	for(al := artifacts; al != nil; al = tl al) {
		art := hd al;
		if(art.id == id) {
			if(atype != nil && atype != "") art.atype = atype;
			if(label != nil && label != "") art.label = label;
			if(data != nil) {
				art.data = data;
				art.rendimg = nil;
				art.rendering = 0;
			}
			return;
		}
	}
	loadartifact(id);
}

deleteartifact(id: string)
{
	nal: list of ref Artifact;
	found := 0;
	for(al := artifacts; al != nil; al = tl al) {
		if((hd al).id != id)
			nal = (hd al) :: nal;
		else
			found = 1;
	}
	if(!found)
		return;	# not present — avoid decrementing nart spuriously
	artifacts = revarts(nal);
	nart--;
	if(centeredart == id) {
		if(artifacts != nil)
			centeredart = (hd artifacts).id;
		else
			centeredart = "";
	}
	if(tabscrolloff >= nart && nart > 0)
		tabscrolloff = nart - 1;
	if(nart == 0)
		tabscrolloff = 0;
}

deleteartifactui(id: string)
{
	if(actid_g >= 0)
		writetofile(
			sys->sprint("%s/activity/%d/presentation/ctl", mountpt_g, actid_g),
			"delete id=" + id);
}

# Export text content: write to /tmp/ file, then open in edit.
# For mermaid this exports the source; for text/code/md/table the content.
# Creates a presentation app artifact to launch edit in the pres zone.
# Falls back to snarf if file creation fails.
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
		sys->fprint(stderr, "lucipres: export: cannot create %s: %r\n", path);
		writetosnarf(art.data);
		return;
	}
	b := array of byte art.data;
	sys->write(fd, b, len b);
	fd = nil;

	sys->fprint(stderr, "lucipres: exported to %s\n", path);

	# Launch edit as a presentation zone app
	launchexport(fname + ext, path);
}

# Export the rendered image of an artifact as a GIF file.
# Used for mermaid diagrams where the user wants the graphic, not the source.
exportimage(art: ref Artifact)
{
	if(art == nil)
		return;
	if(art.rendimg == nil) {
		sys->fprint(stderr, "lucipres: export image: no rendered image\n");
		return;
	}
	if(gifwriter == nil || bufio == nil) {
		sys->fprint(stderr, "lucipres: export image: GIF writer not available\n");
		return;
	}

	fname := safename(art.label);
	if(fname == "")
		fname = "export";
	fname += "-" + string sys->millisec();
	path := "/tmp/" + fname + ".gif";

	ofd := bufio->create(path, Bufio->OWRITE, 8r644);
	if(ofd == nil) {
		sys->fprint(stderr, "lucipres: export image: cannot create %s: %r\n", path);
		return;
	}
	err := gifwriter->writeimage(ofd, art.rendimg);
	ofd.close();
	if(err != nil) {
		sys->fprint(stderr, "lucipres: export image: %s: %s\n", path, err);
		return;
	}

	sys->fprint(stderr, "lucipres: exported image to %s\n", path);

	# Copy path to snarf so user can paste it
	writetosnarf(path);
}

# Convert a label to a safe filename (alphanumeric, hyphens, underscores)
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

# Launch editor as a presentation zone app to edit an exported file.
# Creates an artifact of type=app with dispath=/dis/wm/editor.dis
# and data=filepath so lucifer passes it as an argument.
exportseq := 0;

launchexport(label, filepath: string)
{
	if(actid_g < 0)
		return;
	exportseq++;
	id := sys->sprint("editor-%d", exportseq);
	ctlpath := sys->sprint("%s/activity/%d/presentation/ctl", mountpt_g, actid_g);
	cmd := sys->sprint("create id=%s type=app label=%s dis=/dis/wm/editor.dis",
		id, label);
	writetofile(ctlpath, cmd);
	# Write the file path into the artifact's data field
	datapath := sys->sprint("%s/activity/%d/presentation/%s/data",
		mountpt_g, actid_g, id);
	fd := sys->open(datapath, Sys->OWRITE);
	if(fd != nil) {
		b := array of byte filepath;
		sys->write(fd, b, len b);
		fd = nil;
	}
}

# --- Plumb consumer: open files into the presentation view ---
#
# Runs in its own proc, blocking on the 'presentation' plumb port.  It
# only writes /mnt/ui (the luciuisrv authority) — it never touches this
# module's own artifact/centeredart state, so there is no race with the
# event loop: luciuisrv's "presentation new/current" events drive the UI
# update the normal way.

plumbseq := 0;

plumbreceiver()
{
	for(;;) {
		m := Msg.recv();
		if(m == nil)
			break;
		if(m.data != nil)
			openintopres(string m.data);
	}
}

# Open a file path into the presentation view, choosing the renderer by
# type: pdf/image/markdown become content artifacts, everything else opens
# in the editor.  Mirrors ftree's direct path so both routes behave the
# same.
openintopres(path: string)
{
	path = strip(path);
	if(path == "" || actid_g < 0)
		return;
	name := plumbbasename(path);
	ext := plumblower(plumbext(path));

	plumbseq++;
	id := sys->sprint("plumb-%d", plumbseq);

	atype := "";
	readcontent := 0;
	case ext {
	"pdf" =>
		atype = "pdf";
	"png" or "jpg" or "jpeg" or "gif" or "bit" or "ppm" =>
		atype = "image";
	"md" or "markdown" =>
		atype = "markdown";
		readcontent = 1;
	* =>
		atype = "app";		# text/source/unknown -> editor
	}

	ctlpath := sys->sprint("%s/activity/%d/presentation/ctl", mountpt_g, actid_g);
	if(atype == "app") {
		# The editor reads its argv from the data field the instant the
		# artifact is created, so the path must ride in the create command
		# (data= is terminal, hence last).
		writetofile(ctlpath, sys->sprint(
			"create id=%s type=app label=%s dis=/dis/wm/editor.dis data=%s",
			id, name, path));
	} else {
		writetofile(ctlpath, sys->sprint("create id=%s type=%s label=%s",
			id, atype, name));
		data := path;
		if(readcontent) {
			c := readfile(path);
			if(c != nil)
				data = c;
		}
		writetofile(sys->sprint("%s/activity/%d/presentation/%s/data",
			mountpt_g, actid_g, id), data);
	}
	writetofile(ctlpath, "center id=" + id);
}

plumbbasename(path: string): string
{
	for(i := len path - 1; i >= 0; i--)
		if(path[i] == '/')
			return path[i+1:];
	return path;
}

plumbext(path: string): string
{
	for(i := len path - 1; i >= 0; i--) {
		if(path[i] == '.')
			return path[i+1:];
		if(path[i] == '/')
			break;
	}
	return "";
}

plumblower(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		r[len r] = c;
	}
	return r;
}

findartifact(id: string): ref Artifact
{
	for(al := artifacts; al != nil; al = tl al)
		if((hd al).id == id)
			return hd al;
	return nil;
}

artzoom(art: ref Artifact): int
{
	if(art.zoom == 0)
		return 100;
	return art.zoom;
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
				sys->fprint(stderr, "lucipres: render %s: %s\n", art.atype, e);
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

# Async render result: passed through renderdonech to avoid race conditions.
# The spawned goroutine never writes to the shared Artifact directly;
# the main event loop applies the result in handlerenderdone().
RenderResult: adt {
	artid: string;
	img:   ref Image;
	failed: int;
};

renderdonech: chan of ref RenderResult;

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
		sys->fprint(stderr, "lucipres: renderartasync %s: %s\n", atype, e);
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

# Render task dashboard — grid of task cards reading from /mnt/ui/
drawtaskboard(contentr: Rect, pad: int)
{
	ncardhits = 0;

	# Always use interactive card grid — reads from /mnt/ui/ directly
	info := readfile(mountpt_g + "/ctl");
	if(info == nil) {
		drawcentertext(contentr, "No tasks");
		return;
	}

	# Parse activity list
	cards: list of ref TaskCard;
	ncards := 0;

	lines := splitlines(strip(info));
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(hasprefix(line, "activities:")) {
			rest := strip(line[len "activities:":]);
			(nil, atoks) := sys->tokenize(rest, " ");
			for(; atoks != nil; atoks = tl atoks) {
				id := strtoint(hd atoks);
				if(id <= 0) continue;	# skip activity 0 (meta) and invalid
				label := readfile(sys->sprint("%s/activity/%d/label", mountpt_g, id));
				status := readfile(sys->sprint("%s/activity/%d/status", mountpt_g, id));
				urgstr := readfile(sys->sprint("%s/activity/%d/urgency", mountpt_g, id));
				if(label != nil) label = strip(label); else label = string id;
				if(status != nil) status = strip(status); else status = "?";
				if(status == "hidden") continue;
				urg := 0;
				if(urgstr != nil) urg = strtoint(strip(urgstr));
				cards = ref TaskCard(id, label, status, urg) :: cards;
				ncards++;
			}
		}
	}

	# Reverse to preserve order
	rev: list of ref TaskCard;
	for(; cards != nil; cards = tl cards)
		rev = hd cards :: rev;
	cards = rev;

	# Layout: cards in a wrapping grid (ncards + 1 for the "+" card)
	totalcards := ncards + 1;
	mincardw := 200;
	cardh := 60;
	if(mobile && cardh < 132)
		cardh = 132;	# 44pt finger tap target for task cards
	gap := 8;
	avail := contentr.dx() - 2 * pad;
	cols := (avail + gap) / (mincardw + gap);
	if(cols < 1) cols = 1;
	if(cols > totalcards) cols = totalcards;
	cardw := (avail - (cols - 1) * gap) / cols;

	cx := contentr.min.x + pad;
	cy := contentr.min.y + pad;
	col := 0;
	cardhits = array[totalcards] of ref CardHit;
	ncardhits = 0;

	for(; cards != nil; cards = tl cards) {
		card := hd cards;
		cr := Rect((cx, cy), (cx + cardw, cy + cardh));
		if(cr.max.y > contentr.max.y)
			break;	# off-screen

		cardhits[ncardhits++] = ref CardHit(cr, card.id);

		# Card background and border
		mainwin.draw(cr, headercol, nil, (0, 0));

		# Status indicator — left accent bar
		indicol := dimcol;
		if(card.status == "working")
			indicol = accentcol;
		else if(card.status == "done" || card.status == "complete")
			indicol = greencol_g;
		else if(card.urgency > 0)
			indicol = yellowcol_g;
		mainwin.draw(Rect((cx, cy), (cx + 3, cy + cardh)), indicol, nil, (0, 0));

		# Border
		mainwin.draw(Rect((cx, cy), (cx + cardw, cy + 1)), bordercol, nil, (0, 0));
		mainwin.draw(Rect((cx, cy + cardh - 1), (cx + cardw, cy + cardh)), bordercol, nil, (0, 0));
		mainwin.draw(Rect((cx, cy), (cx + 1, cy + cardh)), bordercol, nil, (0, 0));
		mainwin.draw(Rect((cx + cardw - 1, cy), (cx + cardw, cy + cardh)), bordercol, nil, (0, 0));

		# Label
		mainwin.text((cx + 8, cy + 4), textcol, (0, 0), mainfont, card.label);

		# Status text (smaller, dimmer)
		stext := "[" + card.status + "]";
		if(card.urgency > 0)
			stext += " !";
		mainwin.text((cx + 8, cy + 4 + mainfont.height + 2), dimcol, (0, 0), mainfont, stext);

		col++;
		if(col >= cols) {
			col = 0;
			cx = contentr.min.x + pad;
			cy += cardh + gap;
		} else {
			cx += cardw + gap;
		}
	}

	# "+" card — new task shortcut (id -1 triggers newtask in click handler)
	cr := Rect((cx, cy), (cx + cardw, cy + cardh));
	if(cr.max.y <= contentr.max.y) {
		cardhits[ncardhits++] = ref CardHit(cr, -1);

		# Dashed-style border (dimmer than real cards)
		mainwin.draw(Rect((cx, cy), (cx + cardw, cy + 1)), dimcol, nil, (0, 0));
		mainwin.draw(Rect((cx, cy + cardh - 1), (cx + cardw, cy + cardh)), dimcol, nil, (0, 0));
		mainwin.draw(Rect((cx, cy), (cx + 1, cy + cardh)), dimcol, nil, (0, 0));
		mainwin.draw(Rect((cx + cardw - 1, cy), (cx + cardw, cy + cardh)), dimcol, nil, (0, 0));

		# Centered "+" label
		pluslabel := "+ New Task";
		tw := mainfont.width(pluslabel);
		tx := cx + (cardw - tw) / 2;
		ty := cy + (cardh - mainfont.height) / 2;
		mainwin.text((tx, ty), dimcol, (0, 0), mainfont, pluslabel);
	}
}

# Render diff artifact — monospace with color-coded lines
redcol_g: ref Image;

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
		sys->fprint(stderr, "lucipres: pdf open %s: %s\n", path, err);
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

# --- Attribute parsing (shared) ---

parseattrs(s: string): list of ref Attr
{
	kstarts := array[32] of int;
	eqposs := array[32] of int;
	nkp := 0;

	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;

	j := i;
	while(j < len s) {
		if(s[j] == '=') {
			kstart := j - 1;
			while(kstart > i && s[kstart - 1] != ' ' && s[kstart - 1] != '\t')
				kstart--;
			if(kstart >= 0 && kstart < j) {
				if(kstart == 0 || kstart == i || s[kstart - 1] == ' ' || s[kstart - 1] == '\t') {
					if(nkp >= len kstarts) {
						nks := array[len kstarts * 2] of int;
						nks[0:] = kstarts[0:nkp];
						kstarts = nks;
						neq := array[len eqposs * 2] of int;
						neq[0:] = eqposs[0:nkp];
						eqposs = neq;
					}
					kstarts[nkp] = kstart;
					eqposs[nkp] = j;
					nkp++;
				}
			}
		}
		j++;
	}

	attrs: list of ref Attr;
	for(k := 0; k < nkp; k++) {
		key := s[kstarts[k]:eqposs[k]];
		vstart := eqposs[k] + 1;
		vend: int;
		if(key != "text" && key != "data" && k + 1 < nkp) {
			vend = kstarts[k + 1];
			while(vend > vstart && (s[vend - 1] == ' ' || s[vend - 1] == '\t'))
				vend--;
		} else
			vend = len s;
		val := "";
		if(vstart < vend)
			val = s[vstart:vend];
		attrs = ref Attr(key, val) :: attrs;
		if(key == "text" || key == "data")
			break;
	}

	rev: list of ref Attr;
	for(; attrs != nil; attrs = tl attrs)
		rev = hd attrs :: rev;
	return rev;
}

getattr(attrs: list of ref Attr, key: string): string
{
	for(; attrs != nil; attrs = tl attrs)
		if((hd attrs).key == key)
			return (hd attrs).val;
	return nil;
}

# --- Helpers ---

writetosnarf(text: string)
{
	fd := sys->open("/dev/snarf", Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte text;
	sys->write(fd, b, len b);
}

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

writetofile(path: string, text: string)
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte text;
	sys->write(fd, b, len b);
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

revarts(l: list of ref Artifact): list of ref Artifact
{
	r: list of ref Artifact;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

appendart(l: list of ref Artifact, a: ref Artifact): list of ref Artifact
{
	if(l == nil)
		return a :: nil;
	r: list of ref Artifact;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	r = a :: r;
	result: list of ref Artifact;
	for(; r != nil; r = tl r)
		result = hd r :: result;
	return result;
}
