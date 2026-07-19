implement GeoMap;

#
# geo-map — a Matrix display module that renders georeferenced entities
# and drawn features on a projected map.
#
# It reads a generic geo tree (the /mnt/geo contract, docs/geo-map-design.md):
#
#   <mount>/entities/<id>   one ndb stanza per moving/point entity
#   <mount>/features/<id>   one ndb stanza per drawn graphic
#
# and draws, back-to-front: a graticule base, vector features, entity
# glyphs (affiliation-coloured, with course leaders and labels), the
# selection, and a small HUD (projection, zoom, centre, scale bar).
#
# Projection is the Plan 9 libmap idea: geoproj hands back a named pair
# of pure fwd/inv functions; the camera (centre lat/lon + zoom) lives
# here.  Entities carry an abstract affiliation enum and an opaque
# symbol token; the renderer knows no external protocol or symbology
# standard — any feed that writes the geo tree can drive it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	drawm: Draw;
	Display, Font, Image, Point, Rect, Pointer: import drawm;
include "math.m";
	math: Math;
include "lucitheme.m";
include "geoproj.m";
	geoproj: Geoproj;
	Proj: import geoproj;
include "matrix.m";

GeoMap: module
{
	init:	fn(display: ref Display, font: ref Font, mount: string): string;
	resize:	fn(r: Rect);
	update:	fn(): int;
	draw:	fn(dst: ref Image);
	pointer:	fn(p: ref Pointer): int;
	key:	fn(k: int): int;
	retheme:	fn(display: ref Display);
	shutdown:	fn();
};

# ── State ───────────────────────────────────────────────────
display_g:	ref Display;
font_g:		ref Font;
mountpath:	string;
r_g:		Rect;

proj:		ref Proj;
clat, clon:	real;		# camera centre (degrees)
zoom:		real;		# slippy-map zoom level

TILE:		con 256.0;	# world is TILE * 2^zoom pixels wide
EARTHC:		con 40075016.686;	# equatorial circumference, metres

entities:	array of ref Entity;
fitted := 0;		# auto-fit fired (once, on first data)
lblrects: list of Rect;	# labels placed this frame (declutter)
features:	array of ref Feature;
selid:		string;

# change detection over the flat-file tree
last_ec, last_em, last_fc, last_fm: int;

# drag state
dragging:	int;
lastpx, lastpy:	int;
downpx, downpy:	int;
moved:		int;

# colours
bg, grid, gridtext, hud, selcol: ref Image;
afriend, ahostile, aneutral, aunknown, aoutline: ref Image;

Entity: adt
{
	id:	string;
	lat, lon: real;
	affil:	string;
	kind:	string;
	label:	string;
	course:	real;
	hascourse: int;
};

Feature: adt
{
	id:	string;
	typ:	string;
	pts:	array of (real, real);	# lat,lon
	radius:	real;			# metres (circle)
	col, fill: int;			# RRGGBBAA, 0 = none
	width:	int;
	label:	string;
};

init(display: ref Display, font: ref Font, mount: string): string
{
	sys = load Sys Sys->PATH;
	drawm = load Draw Draw->PATH;
	math = load Math Math->PATH;
	geoproj = load Geoproj Geoproj->PATH;
	if(geoproj == nil)
		return "geo-map: cannot load geoproj";
	geoproj->init();
	proj = geoproj->lookup("mercator");
	if(proj == nil)
		return "geo-map: no projection";

	display_g = display;
	font_g = font;
	mountpath = mount;
	clat = 0.0; clon = 0.0; zoom = 2.0;
	fitted = 0;
	loadcolors();
	return nil;
}

# Fit the camera to the data ONCE, when the first entities arrive: at
# the world-scale default zoom a local scenario collapses into one
# overprinted blob.  Centre on the bbox midpoint and walk the zoom
# down until the bbox fits ~70% of the pane (projection-exact: uses
# geo2scr).  Never re-fires, so user pan/zoom is never fought.
fitview()
{
	if(len entities == 0 || r_g.dx() <= 0)
		return;
	minla := entities[0].lat; maxla := minla;
	minlo := entities[0].lon; maxlo := minlo;
	for(i := 1; i < len entities; i++) {
		e := entities[i];
		if(e.lat < minla) minla = e.lat;
		if(e.lat > maxla) maxla = e.lat;
		if(e.lon < minlo) minlo = e.lon;
		if(e.lon > maxlo) maxlo = e.lon;
	}
	clat = (minla + maxla) / 2.0;
	clon = (minlo + maxlo) / 2.0;
	mw := real r_g.dx() * 0.7;
	mh := real r_g.dy() * 0.7;
	for(zoom = 15.0; zoom > 1.0; zoom -= 0.5) {
		p1 := geo2scr(minla, minlo);
		p2 := geo2scr(maxla, maxlo);
		w := real (p2.x - p1.x); if(w < 0.0) w = -w;
		h := real (p2.y - p1.y); if(h < 0.0) h = -h;
		if(w <= mw && h <= mh)
			break;
	}
	fitted = 1;
}

loadcolors()
{
	# Map chrome follows the theme; affiliation colours are an abstract,
	# fixed palette (friend / hostile / neutral / unknown).
	bgc := int 16r0E1116FF; gridc := int 16r223044FF;
	gtc := int 16r5A6B82FF; hudc := int 16rB8C4D4FF;
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgc = th.bg; gridc = th.border; gtc = th.dim; hudc = th.text;
	}
	bg = display_g.color(bgc);
	grid = display_g.color(gridc);
	gridtext = display_g.color(gtc);
	hud = display_g.color(hudc);
	selcol = display_g.color(int 16rFFFFFFFF);
	afriend  = display_g.color(int 16r35C7FFFF);	# cyan-blue
	ahostile = display_g.color(int 16rFF4D4DFF);	# red
	aneutral = display_g.color(int 16r5BE37AFF);	# green
	aunknown = display_g.color(int 16rF2C14EFF);	# amber
	aoutline = display_g.color(int 16r0A0C10FF);	# near-black edge
}

retheme(display: ref Display)
{
	display_g = display;
	loadcolors();
}

resize(r: Rect)
{
	r_g = r;
}

shutdown()
{
	entities = nil;
	features = nil;
}

# ── Change detection + load ─────────────────────────────────
update(): int
{
	(ec, em) := scan(mountpath + "/entities");
	(fc, fm) := scan(mountpath + "/features");
	if(entities == nil && features == nil ||
	   ec != last_ec || em != last_em || fc != last_fc || fm != last_fm) {
		last_ec = ec; last_em = em; last_fc = fc; last_fm = fm;
		entities = loadentities(mountpath + "/entities");
		features = loadfeatures(mountpath + "/features");
		if(!fitted)
			fitview();
		return 1;
	}
	return 0;
}

scan(dir: string): (int, int)
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return (0, 0);
	cnt := 0; mx := 0;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			cnt++;
			if(d[i].mtime > mx)
				mx = d[i].mtime;
		}
	}
	return (cnt, mx);
}

names(dir: string): list of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(!(d[i].mode & Sys->DMDIR))
				l = d[i].name :: l;
	}
	return l;
}

loadentities(dir: string): array of ref Entity
{
	el: list of ref Entity;
	for(nl := names(dir); nl != nil; nl = tl nl) {
		kv := readstanza(dir + "/" + hd nl);
		lat := getreal(kv, "lat", 9999.0);
		lon := getreal(kv, "lon", 9999.0);
		if(lat > 900.0 || lon > 900.0)
			continue;
		e := ref Entity;
		e.id = getstr(kv, "id", hd nl);
		e.lat = lat; e.lon = lon;
		e.affil = getstr(kv, "affil", "unknown");
		e.kind = getstr(kv, "kind", "");
		e.label = getstr(kv, "label", e.id);
		cs := getstr(kv, "course", "");
		if(cs != "") { e.course = real cs; e.hascourse = 1; }
		el = e :: el;
	}
	return l2a_e(el);
}

loadfeatures(dir: string): array of ref Feature
{
	fl: list of ref Feature;
	for(nl := names(dir); nl != nil; nl = tl nl) {
		kv := readstanza(dir + "/" + hd nl);
		f := ref Feature;
		f.id = getstr(kv, "id", hd nl);
		f.typ = getstr(kv, "type", "polyline");
		f.pts = parsepts(getstr(kv, "points", ""));
		f.radius = getreal(kv, "radius", 0.0);
		f.col = parsecolor(getstr(kv, "color", ""));
		f.fill = parsecolor(getstr(kv, "fill", ""));
		f.width = int getstr(kv, "width", "1");
		if(f.width < 1) f.width = 1;
		f.label = getstr(kv, "label", "");
		if(len f.pts == 0 && f.typ != "circle")
			continue;
		fl = f :: fl;
	}
	return l2a_f(fl);
}

# ── Projection plumbing ─────────────────────────────────────
worldppx(): real
{
	return TILE * math->pow(2.0, zoom);
}

geo2scr(lat, lon: real): Point
{
	w := worldppx();
	(wx, wy) := geoproj->fwd(proj, lat, lon);
	(cwx, cwy) := geoproj->fwd(proj, clat, clon);
	mid := Point((r_g.min.x + r_g.max.x) / 2, (r_g.min.y + r_g.max.y) / 2);
	return Point(mid.x + rnd((wx - cwx) * w), mid.y + rnd((wy - cwy) * w));
}

scr2geo(px, py: int): (real, real)
{
	w := worldppx();
	(cwx, cwy) := geoproj->fwd(proj, clat, clon);
	mid := Point((r_g.min.x + r_g.max.x) / 2, (r_g.min.y + r_g.max.y) / 2);
	wx := cwx + real (px - mid.x) / w;
	wy := cwy + real (py - mid.y) / w;
	return geoproj->inv(proj, wx, wy);
}

# ── Draw ────────────────────────────────────────────────────
draw(dst: ref Image)
{
	dst.draw(r_g, bg, nil, (0, 0));
	drawgraticule(dst);
	for(i := 0; i < len features; i++)
		drawfeature(dst, features[i]);
	lblrects = nil;
	for(i = 0; i < len entities; i++)
		drawentity(dst, entities[i]);
	drawhud(dst);
}

drawgraticule(dst: ref Image)
{
	# Visible lat/lon range from the screen corners, then a "nice" step.
	(t_lat, nil) := scr2geo((r_g.min.x + r_g.max.x) / 2, r_g.min.y);
	(b_lat, nil) := scr2geo((r_g.min.x + r_g.max.x) / 2, r_g.max.y);
	(nil, l_lon) := scr2geo(r_g.min.x, (r_g.min.y + r_g.max.y) / 2);
	(nil, r_lon) := scr2geo(r_g.max.x, (r_g.min.y + r_g.max.y) / 2);

	latstep := nicestep(t_lat - b_lat);
	lonstep := nicestep(r_lon - l_lon);

	# Parallels (constant latitude → horizontal under mercator/equirect).
	la := math->floor(b_lat / latstep) * latstep;
	for(n := 0; la <= t_lat && n < 256; la += latstep) {
		n++;
		p := geo2scr(la, clon);
		if(p.y >= r_g.min.y && p.y < r_g.max.y) {
			dst.line((r_g.min.x, p.y), (r_g.max.x - 1, p.y), 0, 0, 0, grid, (0, 0));
			dst.text((r_g.min.x + 2, p.y + 1), gridtext, (0, 0), font_g, deg(la));
		}
	}
	# Meridians.
	lo := math->floor(l_lon / lonstep) * lonstep;
	for(n = 0; lo <= r_lon && n < 256; lo += lonstep) {
		n++;
		p := geo2scr(clat, lo);
		if(p.x >= r_g.min.x && p.x < r_g.max.x) {
			dst.line((p.x, r_g.min.y), (p.x, r_g.max.y - 1), 0, 0, 0, grid, (0, 0));
			dst.text((p.x + 2, r_g.min.y + 2), gridtext, (0, 0), font_g, deg(lo));
		}
	}
}

drawfeature(dst: ref Image, f: ref Feature)
{
	col := display_g.color(f.col);
	if(f.col == 0)
		col = hud;
	case f.typ {
	"circle" =>
		if(len f.pts < 1)
			return;
		(clat0, clon0) := f.pts[0];
		c := geo2scr(clat0, clon0);
		# metres → pixels at this latitude.
		mpp := EARTHC * math->cos(clat0 * Math->Degree) / worldppx();
		rad := rnd(f.radius / mpp);
		if(f.fill != 0)
			dst.fillellipse(c, rad, rad, display_g.color(f.fill), (0, 0));
		dst.ellipse(c, rad, rad, f.width, col, (0, 0));
	"polygon" =>
		pa := projpts(f.pts);
		if(f.fill != 0)
			dst.fillpoly(pa, 0, display_g.color(f.fill), (0, 0));
		closed := array[len pa + 1] of Point;
		closed[0:] = pa;
		closed[len pa] = pa[0];
		dst.poly(closed, 0, 0, f.width, col, (0, 0));
	* =>	# polyline / point
		pa := projpts(f.pts);
		if(len pa == 1)
			dst.fillellipse(pa[0], f.width + 1, f.width + 1, col, (0, 0));
		else
			dst.poly(pa, 0, 0, f.width, col, (0, 0));
	}
	if(f.label != "" && len f.pts > 0) {
		(la, lo) := f.pts[0];
		dst.text(geo2scr(la, lo), col, (0, 0), font_g, " " + f.label);
	}
}

drawentity(dst: ref Image, e: ref Entity)
{
	p := geo2scr(e.lat, e.lon);
	if(p.x < r_g.min.x - 20 || p.x > r_g.max.x + 20 ||
	   p.y < r_g.min.y - 20 || p.y > r_g.max.y + 20)
		return;
	col := affilcolor(e.affil);

	# course leader (true bearing: 0=N up, 90=E right)
	if(e.hascourse) {
		L := 18.0;
		a := e.course * Math->Degree;
		tip := Point(p.x + rnd(math->sin(a) * L), p.y - rnd(math->cos(a) * L));
		dst.line(p, tip, 0, 0, 0, col, (0, 0));
	}
	glyph(dst, p, e.kind, col);
	if(e.id == selid) {
		dst.ellipse(p, 11, 11, 1, selcol, (0, 0));
		dst.ellipse(p, 12, 12, 1, selcol, (0, 0));
	}
	if(e.label != "") {
		# declutter: when glyphs stack, one legible label beats a
		# multicolour overprint — skip any label whose rect collides
		# with one already placed this frame (glyphs still draw)
		lp := Point(p.x + 9, p.y - font_g.height / 2);
		lr := Rect(lp, (lp.x + font_g.width(e.label), lp.y + font_g.height));
		for(ll := lblrects; ll != nil; ll = tl ll)
			if(rectXrect(lr, hd ll))
				return;
		lblrects = lr :: lblrects;
		dst.text(lp, col, (0, 0), font_g, e.label);
	}
}

rectXrect(a, b: Rect): int
{
	return a.min.x < b.max.x && b.min.x < a.max.x &&
	       a.min.y < b.max.y && b.min.y < a.max.y;
}

# Abstract glyphs by kind; an opaque renderer, no symbology standard.
glyph(dst: ref Image, p: Point, kind: string, col: ref Image)
{
	case kind {
	"air" =>		# triangle, apex up
		pa := array[] of {Point(p.x, p.y - 6), Point(p.x - 6, p.y + 5), Point(p.x + 6, p.y + 5)};
		dst.fillpoly(pa, 0, col, (0, 0));
		dst.poly(array[] of {pa[0], pa[1], pa[2], pa[0]}, 0, 0, 1, aoutline, (0, 0));
	"sea" or "subsurface" =>	# diamond
		pa := array[] of {Point(p.x, p.y - 6), Point(p.x - 6, p.y), Point(p.x, p.y + 6), Point(p.x + 6, p.y)};
		dst.fillpoly(pa, 0, col, (0, 0));
		dst.poly(array[] of {pa[0], pa[1], pa[2], pa[3], pa[0]}, 0, 0, 1, aoutline, (0, 0));
	"ground" or "installation" =>	# square
		dst.draw(Rect((p.x - 5, p.y - 5), (p.x + 6, p.y + 6)), col, nil, (0, 0));
		dst.line((p.x - 6, p.y - 6), (p.x + 6, p.y - 6), 0, 0, 0, aoutline, (0, 0));
	* =>		# generic: filled dot
		dst.fillellipse(p, 5, 5, col, (0, 0));
		dst.ellipse(p, 6, 6, 1, aoutline, (0, 0));
	}
}

drawhud(dst: ref Image)
{
	mpp := EARTHC * math->cos(clat * Math->Degree) / worldppx();
	# choose a bar whose label is a round distance
	target := 90.0 * mpp;
	bar := niceround(target);
	barpx := rnd(bar / mpp);
	y := r_g.max.y - 14;
	x0 := r_g.min.x + 8;
	dst.line((x0, y), (x0 + barpx, y), 0, 0, 0, hud, (0, 0));
	dst.line((x0, y - 3), (x0, y + 3), 0, 0, 0, hud, (0, 0));
	dst.line((x0 + barpx, y - 3), (x0 + barpx, y + 3), 0, 0, 0, hud, (0, 0));
	dst.text((x0 + barpx + 6, y - font_g.height / 2), hud, (0, 0), font_g, dist(bar));

	info := sys->sprint("%s  z%2.1f  %2.4f,%2.4f", proj.name, zoom, clat, clon);
	# opaque strip: the HUD must not overprint graticule labels
	dst.draw(Rect((r_g.min.x, r_g.min.y),
		(r_g.min.x + font_g.width(info) + 16, r_g.min.y + font_g.height + 8)),
		bg, nil, (0, 0));
	dst.text((r_g.min.x + 8, r_g.min.y + 4), hud, (0, 0), font_g, info);
}

projpts(g: array of (real, real)): array of Point
{
	pa := array[len g] of Point;
	for(i := 0; i < len g; i++) {
		(la, lo) := g[i];
		pa[i] = geo2scr(la, lo);
	}
	return pa;
}

affilcolor(a: string): ref Image
{
	case a {
	"friend" =>	return afriend;
	"hostile" =>	return ahostile;
	"neutral" =>	return aneutral;
	* =>		return aunknown;
	}
}

# ── Input ───────────────────────────────────────────────────
pointer(p: ref Pointer): int
{
	if(p.buttons & 1) {
		if(!dragging) {
			dragging = 1; moved = 0;
			downpx = p.xy.x; downpy = p.xy.y;
		} else {
			dx := p.xy.x - lastpx;
			dy := p.xy.y - lastpy;
			moved += abs(dx) + abs(dy);
			pan(dx, dy);
		}
		lastpx = p.xy.x; lastpy = p.xy.y;
		return 1;
	}
	if(dragging) {
		dragging = 0;
		if(moved < 4)
			pick_at(downpx, downpy);
		return 1;
	}
	if(p.buttons & 8) { zoomby(0.5); return 1; }	# wheel up
	if(p.buttons & 16) { zoomby(-0.5); return 1; }	# wheel down
	return 0;
}

key(k: int): int
{
	case k {
	'+' or '=' =>	zoomby(0.5);
	'-' or '_' =>	zoomby(-0.5);
	'h' =>	pan(24, 0);
	'l' =>	pan(-24, 0);
	'k' =>	pan(0, 24);
	'j' =>	pan(0, -24);
	'f' =>	centeronsel();
	* =>	return 0;
	}
	return 1;
}

pan(dx, dy: int)
{
	w := worldppx();
	(cwx, cwy) := geoproj->fwd(proj, clat, clon);
	(clat, clon) = geoproj->inv(proj, cwx - real dx / w, cwy - real dy / w);
}

zoomby(dz: real)
{
	zoom += dz;
	if(zoom < 0.0) zoom = 0.0;
	if(zoom > 20.0) zoom = 20.0;
}

pick_at(px, py: int)
{
	best := 14;		# px radius
	selid = "";
	for(i := 0; i < len entities; i++) {
		p := geo2scr(entities[i].lat, entities[i].lon);
		d := abs(p.x - px) + abs(p.y - py);
		if(d < best) { best = d; selid = entities[i].id; }
	}
}

centeronsel()
{
	for(i := 0; i < len entities; i++)
		if(entities[i].id == selid) {
			clat = entities[i].lat; clon = entities[i].lon;
			return;
		}
}

# ── ndb stanza + value helpers ──────────────────────────────
readstanza(path: string): list of (string, string)
{
	text := readfile(path);
	kv: list of (string, string);
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines) {
		line := hd lines;
		if(line == "" || line[0] == '#')
			continue;
		eq := -1;
		for(i := 0; i < len line; i++)
			if(line[i] == '=') { eq = i; break; }
		if(eq < 0)
			continue;
		kv = (trim(line[0:eq]), trim(line[eq+1:])) :: kv;
	}
	return kv;
}

getstr(kv: list of (string, string), key, dflt: string): string
{
	for(; kv != nil; kv = tl kv) {
		(k, v) := hd kv;
		if(k == key)
			return v;
	}
	return dflt;
}

getreal(kv: list of (string, string), key: string, dflt: real): real
{
	s := getstr(kv, key, "");
	if(s == "")
		return dflt;
	return real s;
}

parsepts(s: string): array of (real, real)
{
	(n, toks) := sys->tokenize(s, " \t");
	if(n == 0)
		return array[0] of (real, real);
	pa := array[n] of (real, real);
	i := 0;
	for(; toks != nil; toks = tl toks) {
		(nil, ll) := sys->tokenize(hd toks, ",");
		if(len ll >= 2)
			pa[i++] = (real hd ll, real hd tl ll);
	}
	return pa[0:i];
}

parsecolor(s: string): int
{
	if(len s < 6)
		return 0;
	v := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		d := -1;
		if(c >= '0' && c <= '9') d = c - '0';
		else if(c >= 'a' && c <= 'f') d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F') d = c - 'A' + 10;
		if(d < 0)
			break;
		v = v * 16 + d;
	}
	return v;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
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

# ── small numeric/string helpers ────────────────────────────
nicestep(span: real): real
{
	if(span < 0.0) span = -span;
	if(span <= 0.0) return 1.0;
	step := span / 6.0;		# aim for ~6 lines
	# snap to 1/2/5 * 10^k
	p := 1.0;
	while(step >= 10.0) { step /= 10.0; p *= 10.0; }
	while(step < 1.0) { step *= 10.0; p /= 10.0; }
	if(step < 2.0) return 1.0 * p;
	if(step < 5.0) return 2.0 * p;
	return 5.0 * p;
}

niceround(v: real): real
{
	p := 1.0;
	while(v >= 10.0) { v /= 10.0; p *= 10.0; }
	while(v < 1.0 && p > 0.001) { v *= 10.0; p /= 10.0; }
	if(v < 2.0) return 1.0 * p;
	if(v < 5.0) return 2.0 * p;
	return 5.0 * p;
}

deg(v: real): string
{
	# %g leaks binary-float noise ("37.83999999999998") on the
	# fractional graticule steps a fitted zoom produces; fixed
	# decimals, then strip trailing zeros for whole degrees.
	s := sys->sprint("%.2f", v);
	while(len s > 1 && s[len s - 1] == '0')
		s = s[0:len s - 1];
	if(len s > 1 && s[len s - 1] == '.')
		s = s[0:len s - 1];
	return s;
}

dist(m: real): string
{
	if(m >= 1000.0)
		return sys->sprint("%g km", m / 1000.0);
	return sys->sprint("%g m", m);
}

rnd(x: real): int
{
	if(x >= 0.0)
		return int (x + 0.5);
	return -int (-x + 0.5);
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
}

trim(s: string): string
{
	i := 0;
	j := len s;
	while(i < j && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r'))
		i++;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r'))
		j--;
	return s[i:j];
}

l2a_e(l: list of ref Entity): array of ref Entity
{
	a := array[len l] of ref Entity;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}

l2a_f(l: list of ref Feature): array of ref Feature
{
	a := array[len l] of ref Feature;
	i := 0;
	for(; l != nil; l = tl l)
		a[i++] = hd l;
	return a;
}
