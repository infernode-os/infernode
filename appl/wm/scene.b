implement WmScene;

#
# wm/scene — show a 2-D scene (docs/scene-design.md) in a window.
#
#	wm/scene [dir]		(default /mnt/scene)
#
# The directory is a scene: entities, features and layers in a geo or
# xy frame, over time.  When it is a scenefs (it has a status file) the
# view is live and shared: it reloads only when status reports a new
# gen, the camera follows the server's view, and this window's own
# pan, zoom and select are written back to its ctl, so every viewer and
# any agent reading view or event sees the same picture.  A plain
# directory works too: it is rescanned when its signature changes and
# the camera is local.
#
# An ordinary window: run it under wm, in a Lucifer activity (where the
# activity's agent can picture it with the window tool), or in a Matrix
# app region:
#	top app /dis/wm/scene.dis /mnt/scene
#
# Input: drag pans; wheel zooms about the pointer; click selects;
# + - zoom; h j k l pan; f fits; button 3 for the menu.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect, Pointer: import draw;
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;
include "menuhit.m";
	menuhit: Menuhit;
	Menu, Mousectl: import menuhit;
include "scene.m";
	scene: Scene;
	Model, Cam, Trails: import scene;

WmScene: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

TICK: con 100;		# ms between looks at the scene

dir: string;
served := 0;		# the directory is a scenefs
m: ref Model;
cam: ref Cam;
trails: ref Trails;
lastgen := -1;
lastscan := "";
lastsub := "";
nextscan := 0;		# when a directory signature may next be taken
lastview := "";
fitseq := 0;		# the last fit request this window answered
pendfit := 0;		# the request the server shows (0: none)
fitted := 0;		# plain directory: fitted once, locally
lastt := 0.0;

# pointer state
dragging := 0;
moved := 0;
lastp, downp: Point;
chipdown := 0;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	menuhit = load Menuhit Menuhit->PATH;
	scene = load Scene Scene->PATH;
	if(scene == nil) {
		sys->fprint(sys->fildes(2), "scene: cannot load %s: %r\n", Scene->PATH);
		raise "fail:load";
	}
	dir = "/mnt/scene";
	if(argv != nil && tl argv != nil)
		dir = hd tl argv;

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	w := wmclient->window(ctxt, "scene " + dir, Wmclient->Appl);
	display := w.display;
	font := Font.open(display, "/fonts/combined/unicode.sans.14.font");
	if(font == nil)
		font = Font.open(display, "*default*");
	scene->init(display, font);
	cam = Cam.new(Rect((0, 0), (0, 0)));
	trails = Trails.new();
	m = Model.new();

	w.reshape(Rect((0, 0), (800, 600)));
	w.startinput("kbd" :: "ptr" :: nil);
	w.onscreen(nil);
	menuhit->init(w);
	menu := ref Menu(array[] of {"fit", "exit"}, nil, 0);

	resize(w);
	update();
	redraw(w);

	tick := chan of int;
	spawn ticker(tick);
	for(;;) alt {
	c := <-w.ctl or
	c = <-w.ctxt.ctl =>
		w.wmctl(c);
		if(c == "retheme") {
			scene->retheme();
			redraw(w);
		}
		if(c != nil && c[0] == '!') {
			resize(w);
			redraw(w);
		}
	k := <-w.ctxt.kbd =>
		if(key(k))
			redraw(w);
	p := <-w.ctxt.ptr =>
		if(w.pointer(*p))
			continue;
		if(p.buttons & 4) {
			mc := ref Mousectl(w.ctxt.ptr, p.buttons, p.xy, p.msec);
			case menuhit->menuhit(p.buttons, mc, menu, nil) {
			0 =>
				dofit(1);
				redraw(w);
			1 =>
				postnote(sys->pctl(0, nil), "killgrp");
				exit;
			}
			continue;
		}
		if(pointer(p))
			redraw(w);
	<-tick =>
		if(update())
			redraw(w);
	}
}

ticker(c: chan of int)
{
	for(;;) {
		sys->sleep(TICK);
		c <-= 1;
	}
}

resize(w: ref Window)
{
	if(w.image == nil)
		return;
	cam.r = w.image.r;
	if(!served && !fitted)
		fitted = dofit(0);
}

redraw(w: ref Window)
{
	if(w.image == nil)
		return;
	scene->render(w.image, m, cam, trails, Scene->RHUD | Scene->RGRID | Scene->RCHIPS, nil);
	w.image.flush(Draw->Flushnow);
}

postnote(pid: int, note: string)
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", note);
}

# ── following the scene ────────────────────────────────────

# A signature reads the directory: over a slow server that costs.  Take
# one no more often than three times what the last one cost, so the
# window never spends most of its time watching.
scanok(): int
{
	return sys->millisec() >= nextscan;
}

scanned(t0: int)
{
	nextscan = sys->millisec() + 3 * (sys->millisec() - t0);
}

update(): int
{
	dirty := 0;
	if(!served) {
		# a scenefs may be mounted after we start: keep looking
		(ok, nil) := sys->stat(dir + "/status");
		if(ok >= 0) {
			served = 1;
			lastview = "";
		}
	}
	if(served) {
		gen := parsestatus(readfile(dir + "/status"));
		# the server's gen covers its own objects; scenes its scene
		# layers overlay are other servers, watched by their signatures
		sub := lastsub;
		if(scanok()) {
			t0 := sys->millisec();
			sub = scene->subsignature(m);
			scanned(t0);
		}
		if(gen != lastgen || sub != lastsub) {
			lastgen = gen;
			reload();
			lastsub = sub;
			dirty = 1;
		}
		if(!dragging) {
			v := readfile(dir + "/view");
			if(v != lastview) {
				lastview = v;
				if(cam.parse(v))
					dirty = 1;
				pendfit = int fieldafter(v, "fit");
			}
		}
		# Answer a fit request (a fresh scene makes one) once there is
		# data to fit; a window joining a scene whose camera is already
		# set adopts it instead.
		if(pendfit > 0 && pendfit != fitseq && dofit(1)) {
			fitseq = pendfit;
			dirty = 1;
		}
	} else {
		sc := lastscan;
		if(scanok()) {
			t0 := sys->millisec();
			sc = scene->signature(dir);
			scanned(t0);
		}
		if(sc != lastscan) {
			lastscan = sc;
			reload();
			dirty = 1;
		}
	}
	if(cam.follow != nil && (e := m.find(Scene->ENT, cam.follow)) != nil && e.haspos &&
	   (e.a != cam.ca || e.b != cam.cb)) {
		cam.ca = e.a;
		cam.cb = e.b;
		dirty = 1;
	}
	return dirty;
}

reload()
{
	nm := Model.read(dir);
	if(nm.hast && m.hast && nm.t < lastt)	# time went backwards: a replay or a new run
		trails.reset();
	lastt = nm.t;
	m = nm;
	trails.note(m);
	if(!served && !fitted)
		fitted = dofit(0);
}

# Fit locally (only this window knows its size); with share set, publish
# the result as the scene's view.  0 if there is nothing to fit yet.
dofit(share: int): int
{
	if(cam.r.dx() <= 0 || m == nil)
		return 0;
	(ok, nil, nil, nil, nil) := m.extent();
	if(!ok)
		return 0;
	cam.fit(m);
	if(share)
		sendcam();
	return 1;
}

sendcam()
{
	ctl(sys->sprint("center %s %s\nzoom %s", fmtr(cam.ca), fmtr(cam.cb), fmtr(cam.zoom)));
}

ctl(s: string)
{
	if(!served)
		return;
	fd := sys->open(dir + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return;
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines)
		sys->fprint(fd, "%s", hd lines);
}

parsestatus(s: string): int
{
	g := fieldafter(s, "gen");
	if(g == nil)
		return -1;
	return int g;
}

fieldafter(s, k: string): string
{
	(nil, toks) := sys->tokenize(s, " \t\n");
	for(; toks != nil && tl toks != nil; toks = tl toks)
		if(hd toks == k)
			return hd tl toks;
	return nil;
}

# ── input ──────────────────────────────────────────────────

pointer(p: ref Pointer): int
{
	if(p.buttons & 1 && !dragging && !chipdown) {
		(zin, zout, zfit) := scene->chiprects(cam);
		if(zin.contains(p.xy)) {
			zoom(0.5, cam.r.min.add(cam.r.max).div(2));
			chipdown = 1;
			return 1;
		}
		if(zout.contains(p.xy)) {
			zoom(-0.5, cam.r.min.add(cam.r.max).div(2));
			chipdown = 1;
			return 1;
		}
		if(zfit.contains(p.xy)) {
			dofit(1);
			chipdown = 1;
			return 1;
		}
	}
	if(p.buttons == 0)
		chipdown = 0;
	if(chipdown)
		return 1;
	if(p.buttons & 1) {
		if(!dragging) {
			dragging = 1;
			moved = 0;
			downp = p.xy;
		} else {
			d := p.xy.sub(lastp);
			moved += iabs(d.x) + iabs(d.y);
			if(cam.follow != nil) {	# a drag takes the camera back
				cam.follow = nil;
				ctl("unfollow");
			}
			cam.pan(m, d.x, d.y);
		}
		lastp = p.xy;
		return 1;
	}
	if(dragging) {
		dragging = 0;
		if(moved < 4)
			select(scene->hit(m, cam, downp, 14));
		else
			sendcam();
		return 1;
	}
	if(p.buttons & 8) {
		zoom(0.25, p.xy);
		return 1;
	}
	if(p.buttons & 16) {
		zoom(-0.25, p.xy);
		return 1;
	}
	return 0;
}

zoom(dz: real, at: Point)
{
	cam.zoomat(m, at, dz);
	sendcam();
}

select(id: string)
{
	cam.sel = id;
	if(id == nil)
		ctl("deselect");
	else
		ctl("select " + id);
}

key(k: int): int
{
	case k {
	'+' or '=' =>	zoom(0.5, cam.r.min.add(cam.r.max).div(2));
	'-' or '_' =>	zoom(-0.5, cam.r.min.add(cam.r.max).div(2));
	'h' =>	cam.pan(m, 32, 0); sendcam();
	'l' =>	cam.pan(m, -32, 0); sendcam();
	'k' =>	cam.pan(m, 0, 32); sendcam();
	'j' =>	cam.pan(m, 0, -32); sendcam();
	'f' =>	dofit(1);
	* =>	return 0;
	}
	return 1;
}

# ── helpers ────────────────────────────────────────────────

fmtr(v: real): string
{
	return sys->sprint("%.9g", v);
}

iabs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}
