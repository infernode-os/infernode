implement Road;

#
# road - a moving map of where the GPS receiver says this machine is.
#
# After Plan 9's games/road (2nd edition), which drew the Census
# Bureau's TIGER map and, with -g, followed the end of /tmp/gpslog as
# gps(7) wrote it.  This one follows gpsfs(4)'s event file: each fix
# moves the position and lengthens the track, and while following the
# map keeps the position at its centre.  It draws a grid of latitude
# and longitude, a scale bar, the track, the receiver's accuracy as a
# circle and its heading (or course) as an arrow, the traffic gpsfs
# hears (ships by AIS, aircraft by ADS-B and FLARM) pointing where
# each goes, and the lines and marks of any map files given.  Units
# are metric, or nautical (knots, feet, nautical miles) with -n.
#
# Map files are text: "line [name]" begins a line, each "lat lon" after
# it a point of it; "mark lat lon [name]" is one place.  # begins a
# comment.  Degrees, north and east positive.
#
# Button 1 drags the map (and stops following); the wheel zooms;
# button 2 is the menu: follow, zoom in, zoom out, clear the track.
#
# Its files, for an agent or another program, posted as #sroad/fs
# (appfs(2)):
#
#   view   (r)   center lat lon, width (metres across), follow on|off,
#                units metric|nautical
#   marks  (r)   one line a mark: lat lon name
#   ctl    (rw)  those lines written change them; also mark lat lon
#                name, unmark name, clear (the track), load path (a map
#                file); a read gives the view
#   event  (r)   a line when the view or the marks change
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;

include "tk.m";
	tk: Tk;

include "tkclient.m";
	tkclient: Tkclient;

include "math.m";
	math: Math;

include "string.m";
	str: String;

include "lucitheme.m";

include "appfs.m";
	appfs: Appfs;

Road: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

GPS: con "/mnt/gps/";
M: con 111320.0;	# metres a degree of latitude, near enough
Maxtrack: con 5000;
WIDTH: con 520;
HEIGHT: con 420;

Pt: adt {
	lat, lon: real;
};

Fix: adt {
	valid:	int;
	lat, lon:	real;
	hasalt:	int;
	height:	real;
	hasspeed:	int;
	speed:	real;
	hascourse:	int;
	course:	real;
	err:	real;	# < 0 unknown
	sats:	int;
	time:	string;
	hasheading:	int;
	heading:	real;
	hasmagvar:	int;
	magvar:	real;
	hasbaro:	int;
	baroalt:	real;
};

# another craft, as gpsfs's traffic file gives it
Craft: adt {
	kind:	string;
	id:	string;
	p:	Pt;
	hasalt:	int;
	height:	real;
	hasdir:	int;
	dir:	real;	# heading, or course
	name:	string;
};

Line: adt {
	name:	string;
	pts:	array of Pt;
};

Mark: adt {
	name:	string;
	p:	Pt;
};

top: ref Tk->Toplevel;
stderr: ref Sys->FD;

# the view
centre := Pt(0.0, 0.0);
width := 2000.0;	# metres across the window
follow := 1;
hascentre := 0;

fix: ref Fix;
receiver := "";	# why there is no fix, or nil
track: list of Pt;	# newest first
ntrack := 0;
lines: list of ref Line;
marks: list of ref Mark;
crafts: list of ref Craft;
nautical := 0;

# theme colours, as Tk wants them
bgs, gridcol, gridtext, textcol, trackcol, poscol, markcol, linecol, craftcol, statusbg, statusfg: string;

themech: chan of int;
actch: chan of string;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	math = load Math Math->PATH;
	str = load String String->PATH;
	stderr = sys->fildes(2);
	if(tkclient == nil || math == nil || str == nil) {
		sys->fprint(stderr, "road: cannot load modules: %r\n");
		raise "fail:load";
	}

	argv = tl argv;
	for(; argv != nil && len hd argv > 1 && (hd argv)[0] == '-'; argv = tl argv)
		case hd argv {
		"-w" =>
			argv = tl argv;
			if(argv == nil)
				usage();
			width = real hd argv;
			if(width < 10.0)
				width = 10.0;
		"-n" =>
			nautical = 1;
		* =>
			usage();
		}
	for(; argv != nil; argv = tl argv)
		if((err := loadmap(hd argv)) != nil)
			sys->fprint(stderr, "road: %s\n", err);
	loadmapdir("/lib/road");

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil) {
		sys->fprint(stderr, "road: no window context\n");
		raise "fail:no context";
	}
	wmctl: chan of string;
	(top, wmctl) = tkclient->toplevel(ctxt,
		sys->sprint("-width %d -height %d", WIDTH, HEIGHT), "Road", Tkclient->Appl);

	themecolours();
	actch = chan[16] of string;
	tk->namechan(top, actch, "act");
	tkcmds(array[] of {
		"canvas .c -borderwidth 0 -background " + bgs,
		"label .status -anchor w -background " + statusbg + " -foreground " + statusfg,
		"pack .status -side bottom -fill x",
		"pack .c -side top -fill both -expand 1",
		"pack propagate . 0",
		"bind .c <Button-1> {send act b1down %x %y}",
		"bind .c <Motion-Button-1> {send act b1drag %x %y}",
		"bind .c <ButtonRelease-1> {send act b1up %x %y}",
		"bind .c <Button-2> {send act menu %X %Y}",
		"bind .c <ButtonPress-4> {send act zoomin}",
		"bind .c <ButtonPress-5> {send act zoomout}",
		"bind .c <Configure> {send act resized}",
		"bind . <Key-+> {send act zoomin}",
		"bind . <Key-=> {send act zoomin}",
		"bind . <Key--> {send act zoomout}",
		"bind . <Key-f> {send act follow}",
		"menu .m",
		".m add command -label follow -command {send act follow}",
		".m add command -label {zoom in} -command {send act zoomin}",
		".m add command -label {zoom out} -command {send act zoomout}",
		".m add command -label {clear track} -command {send act clear}",
	});

	gpsc := chan of string;
	spawn gpsreader(gpsc);
	trafficc := chan of string;
	spawn trafficreader(trafficc);
	themech = chan[1] of int;
	spawn themelistener();
	reqs := chan of ref Appfs->Req;
	tether := startfs(reqs);

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);
	redraw();

	drag := 0;
	dragfrom := (0, 0);
	dragcentre := centre;
	for(;;) alt {
	c := <-wmctl or
	c = <-top.ctxt.ctl or
	c = <-top.wreq =>
		if(c != nil) {
			tkclient->wmctl(top, c);
			if(len c > 0 && c[0] == '!')
				redraw();
		}
	k := <-top.ctxt.kbd =>
		tk->keyboard(top, k);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	a := <-actch =>
		(nil, toks) := sys->tokenize(a, " ");
		if(toks == nil)
			break;
		case hd toks {
		"b1down" =>
			drag = 1;
			dragfrom = xy(tl toks);
			dragcentre = centre;
		"b1drag" =>
			if(!drag)
				break;
			(x, y) := xy(tl toks);
			mpp := width / real canvw();
			dx := real (x - dragfrom.t0) * mpp;
			dy := real (y - dragfrom.t1) * mpp;
			centre.lat = dragcentre.lat + dy / M;
			centre.lon = dragcentre.lon - dx / (M * coslat(centre.lat));
			hascentre = 1;
			follow = 0;
			redraw();
		"b1up" =>
			if(drag)
				changed();
			drag = 0;
		"menu" =>
			tk->cmd(top, ".m post " + (hd tl toks) + " " + (hd tl tl toks));
		"zoomin" =>
			setwidth(width / 2.0);
		"zoomout" =>
			setwidth(width * 2.0);
		"follow" =>
			follow = 1;
			if(fix != nil && fix.valid)
				centre = Pt(fix.lat, fix.lon);
			redraw();
			changed();
		"clear" =>
			track = nil;
			ntrack = 0;
			redraw();
		"resized" =>
			redraw();
		}
	s := <-gpsc =>
		gpsline(s);
		redraw();
	s := <-trafficc =>
		crafts = parsetraffic(s);
		redraw();
	r := <-reqs =>
		case r.file {
		"view" =>
			r.reply <-= view();
		"marks" =>
			r.reply <-= marktext();
		"ctl" =>
			if(r.data == nil) {
				r.reply <-= view();
				break;
			}
			# lines before a refused one are done
			r.reply <-= ctl(r.data);
			redraw();
			changed();
		* =>
			r.reply <-= "";
		}
	<-themech =>
		themecolours();
		tk->cmd(top, ".c configure -background " + bgs);
		tk->cmd(top, ".status configure -background " + statusbg + " -foreground " + statusfg);
		tkclient->wmctl(top, "retheme");
		redraw();
	}
	tether = nil;
}

usage()
{
	sys->fprint(stderr, "usage: road [-n] [-w metres] [mapfile ...]\n");
	raise "fail:usage";
}

tkcmds(a: array of string)
{
	for(i := 0; i < len a; i++) {
		e := tk->cmd(top, a[i]);
		if(e != nil && e[0] == '!')
			sys->fprint(stderr, "road: tk: %s: %s\n", a[i], e);
	}
}

xy(l: list of string): (int, int)
{
	if(l == nil || tl l == nil)
		return (0, 0);
	return (int hd l, int hd tl l);
}

coslat(lat: real): real
{
	c := math->cos(lat * Math->Pi / 180.0);
	if(c < 0.01)
		c = 0.01;
	return c;
}

setwidth(w: real)
{
	if(w < 10.0)
		w = 10.0;
	if(w > 40000000.0)
		w = 40000000.0;
	width = w;
	redraw();
	changed();
}

canvw(): int
{
	w := int tk->cmd(top, ".c cget -actwidth");
	if(w <= 0)
		w = WIDTH;
	return w;
}

canvh(): int
{
	h := int tk->cmd(top, ".c cget -actheight");
	if(h <= 0)
		h = HEIGHT;
	return h;
}

#
# The receiver.  The reader opens event and sends each line; when there
# is no receiver it says so, and tries again.
#
gpsreader(c: chan of string)
{
	buf := array[8192] of byte;
	for(;;) {
		fd := sys->open(GPS + "event", Sys->OREAD);
		if(fd == nil) {
			c <-= "!no receiver: " + GPS + " is not served";
			sys->sleep(3000);
			continue;
		}
		# what it knows now, before the next fix
		if((s := readfile(GPS + "fix")) != nil)
			c <-= s;
		else
			c <-= "!waiting for a fix";
		for(;;) {
			n := sys->read(fd, buf, len buf);
			if(n <= 0)
				break;
			(nil, l) := sys->tokenize(string buf[0:n], "\n");
			for(; l != nil; l = tl l)
				c <-= hd l;
		}
		c <-= "!the receiver went";
		sys->sleep(3000);
	}
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	b := array[8192] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		s += string b[0:n];
	return s;
}

# the traffic file, every two seconds, when it changes
trafficreader(c: chan of string)
{
	last := "";
	for(;;) {
		s := readfile(GPS + "traffic");
		# ages change each read: compare what is heard, not when
		k := noages(s);
		if(k != last) {
			last = k;
			c <-= s;
		}
		sys->sleep(2000);
	}
}

noages(s: string): string
{
	r := "";
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l) {
		t := hd l;
		for(i := len t - 5; i > 0; i--)
			if(t[i:i+5] == " age=")
				break;
		if(i > 0)
			t = t[0:i];
		r += t + "\n";
	}
	return r;
}

parsetraffic(s: string): list of ref Craft
{
	cl: list of ref Craft;
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l) {
		c := ref Craft("", "", Pt(0.0, 0.0), 0, 0.0, 0, 0.0, nil);
		haslat := haslon := 0;
		course := -1.0;
		for(f := str->unquoted(hd l); f != nil; f = tl f) {
			(k, v) := attr(hd f);
			case k {
			"kind" =>	c.kind = v;
			"id" =>	c.id = v;
			"lat" =>	c.p.lat = real v; haslat = 1;
			"lon" =>	c.p.lon = real v; haslon = 1;
			"alt" =>	c.height = real v; c.hasalt = 1;
			"heading" =>	c.dir = real v; c.hasdir = 1;
			"course" =>	course = real v;
			"name" =>	c.name = v;
			}
		}
		if(!c.hasdir && course >= 0.0) {
			c.dir = course;
			c.hasdir = 1;
		}
		if(haslat && haslon)
			cl = c :: cl;
	}
	return cl;
}

# a fix (attr=value, as gpsfs gives), or "!why" there is none
gpsline(s: string)
{
	while(len s > 0 && s[len s-1] == '\n')
		s = s[0:len s-1];
	if(s == nil)
		return;
	if(s[0] == '!') {
		receiver = s[1:];
		if(fix != nil)
			fix.valid = 0;
		return;
	}
	f := ref Fix(0, 0.0, 0.0, 0, 0.0, 0, 0.0, 0, 0.0, -1.0, -1, nil, 0, 0.0, 0, 0.0, 0, 0.0);
	haslat := haslon := 0;
	(nil, l) := sys->tokenize(s, " ");
	for(; l != nil; l = tl l) {
		(k, v) := attr(hd l);
		case k {
		"time" =>
			f.time = v;
		"lat" =>
			f.lat = real v;
			haslat = 1;
		"lon" =>
			f.lon = real v;
			haslon = 1;
		"alt" =>
			f.height = real v;
			f.hasalt = 1;
		"speed" =>
			f.speed = real v;
			f.hasspeed = 1;
		"course" =>
			f.course = real v;
			f.hascourse = 1;
		"err" =>
			f.err = real v;
		"sats" =>
			f.sats = int v;
		"heading" =>
			f.heading = real v;
			f.hasheading = 1;
		"magvar" =>
			f.magvar = real v;
			f.hasmagvar = 1;
		"baroalt" =>
			f.baroalt = real v;
			f.hasbaro = 1;
		}
	}
	f.valid = haslat && haslon;
	fix = f;
	if(!f.valid) {
		receiver = "no fix";
		return;
	}
	receiver = nil;
	p := Pt(f.lat, f.lon);
	if(track == nil || (hd track).lat != p.lat || (hd track).lon != p.lon) {
		track = p :: track;
		if(++ntrack > Maxtrack) {
			# drop the oldest half
			n := 0;
			nl: list of Pt;
			for(t := track; t != nil && n < Maxtrack/2; t = tl t) {
				nl = hd t :: nl;
				n++;
			}
			track = nil;
			for(; nl != nil; nl = tl nl)
				track = hd nl :: track;
			ntrack = n;
		}
	}
	if(follow || !hascentre) {
		centre = p;
		hascentre = 1;
	}
}

attr(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '=')
			return (s[0:i], s[i+1:]);
	return (s, "");
}

#
# Drawing: everything is drawn again on each change, from the view.
#
redraw()
{
	w := canvw();
	h := canvh();
	mpp := width / real w;
	cl := coslat(centre.lat);
	cx := w / 2;
	cy := h / 2;
	proj := ref Proj(centre, mpp, cl, cx, cy);

	tk->cmd(top, ".c delete all");
	grid(proj, w, h);
	for(ll := lines; ll != nil; ll = tl ll)
		drawline(proj, hd ll);
	for(ml := marks; ml != nil; ml = tl ml) {
		(x, y) := proj.xy((hd ml).p);
		tk->cmd(top, sys->sprint(".c create rectangle %d %d %d %d -fill %s -outline %s",
			x-3, y-3, x+3, y+3, markcol, markcol));
		if((hd ml).name != nil)
			tk->cmd(top, sys->sprint(".c create text %d %d -anchor w -fill %s -text '%s",
				x+6, y, markcol, (hd ml).name));
	}
	if(track != nil && tl track != nil) {
		s := "";
		for(t := track; t != nil; t = tl t) {
			(x, y) := proj.xy(hd t);
			s += sys->sprint(" %d %d", x, y);
		}
		tk->cmd(top, ".c create line" + s + " -width 2 -fill " + trackcol);
	}
	if(fix != nil && fix.valid) {
		(x, y) := proj.xy(Pt(fix.lat, fix.lon));
		if(fix.err > 0.0) {
			r := int (fix.err / mpp);
			if(r >= 6)
				tk->cmd(top, sys->sprint(".c create oval %d %d %d %d -outline %s",
					x-r, y-r, x+r, y+r, poscol));
		}
		dir := -1.0;
		if(fix.hasheading)
			dir = fix.heading;
		else if(fix.hascourse && fix.hasspeed && fix.speed > 0.5)
			dir = fix.course;
		if(dir >= 0.0) {
			a := dir * Math->Pi / 180.0;
			ex := x + int (18.0 * math->sin(a));
			ey := y - int (18.0 * math->cos(a));
			tk->cmd(top, sys->sprint(".c create line %d %d %d %d -width 2 -arrow last -fill %s",
				x, y, ex, ey, poscol));
		}
		tk->cmd(top, sys->sprint(".c create oval %d %d %d %d -fill %s -outline %s",
			x-5, y-5, x+5, y+5, poscol, bgs));
	}
	for(cr := crafts; cr != nil; cr = tl cr)
		drawcraft(proj, hd cr);
	scalebar(mpp, h);
	tk->cmd(top, ".status configure -text '" + status());
	tk->cmd(top, "update");
}

Proj: adt {
	c:	Pt;
	mpp:	real;
	cl:	real;
	cx, cy:	int;

	xy:	fn(p: self ref Proj, q: Pt): (int, int);
	pt:	fn(p: self ref Proj, x, y: int): Pt;
};

Proj.xy(p: self ref Proj, q: Pt): (int, int)
{
	x := real p.cx + (q.lon - p.c.lon) * M * p.cl / p.mpp;
	y := real p.cy - (q.lat - p.c.lat) * M / p.mpp;
	# keep Tk's coordinates in range far off the window
	if(x > 1.0e6) x = 1.0e6; else if(x < -1.0e6) x = -1.0e6;
	if(y > 1.0e6) y = 1.0e6; else if(y < -1.0e6) y = -1.0e6;
	return (int x, int y);
}

Proj.pt(p: self ref Proj, x, y: int): Pt
{
	return Pt(p.c.lat - real (y - p.cy) * p.mpp / M,
		p.c.lon + real (x - p.cx) * p.mpp / (M * p.cl));
}

steps := array[] of {
	0.00001, 0.00002, 0.00005, 0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005,
	0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 45.0,
};

# lines of latitude and longitude a hundred pixels or so apart
grid(p: ref Proj, w, h: int)
{
	degpx := M / p.mpp;	# pixels a degree of latitude
	step := steps[len steps - 1];
	for(i := 0; i < len steps; i++)
		if(steps[i] * degpx >= 90.0) {
			step = steps[i];
			break;
		}
	nw := p.pt(0, 0);
	se := p.pt(w, h);
	digits := 0;
	for(s := step; s < 1.0 && digits < 6; s *= 10.0)
		digits++;
	# latitude
	for(lat := math->floor(se.lat / step) * step; lat <= nw.lat; lat += step) {
		if(lat < -90.0 || lat > 90.0)
			continue;
		(nil, y) := p.xy(Pt(lat, p.c.lon));
		if(y < 14 || y > h)
			continue;	# its label would be off the window or under the top's
		tk->cmd(top, sys->sprint(".c create line 0 %d %d %d -fill %s", y, w, y, gridcol));
		tk->cmd(top, sys->sprint(".c create text 3 %d -anchor sw -fill %s -text '%.*f",
			y - 1, gridtext, digits, lat));
	}
	# longitude, the same step: its lines are closer by cos(latitude)
	for(lon := math->floor(nw.lon / step) * step; lon <= se.lon; lon += step) {
		(x, nil) := p.xy(Pt(p.c.lat, lon));
		if(x < 0 || x > w - 40)
			continue;
		tk->cmd(top, sys->sprint(".c create line %d 0 %d %d -fill %s", x, x, h, gridcol));
		tk->cmd(top, sys->sprint(".c create text %d 2 -anchor nw -fill %s -text '%.*f",
			x + 2, gridtext, digits, normlon(lon)));
	}
}

normlon(lon: real): real
{
	while(lon > 180.0)
		lon -= 360.0;
	while(lon < -180.0)
		lon += 360.0;
	return lon;
}

# a bar of a round length, a quarter of the window or less
scalebar(mpp: real, h: int)
{
	most := 120.0 * mpp;
	len_ := 1.0;
	while(len_ * 10.0 <= most)
		len_ *= 10.0;
	if(len_ * 5.0 <= most)
		len_ *= 5.0;
	else if(len_ * 2.0 <= most)
		len_ *= 2.0;
	label := sys->sprint("%d m", int len_);
	if(len_ >= 1000.0)
		label = short(len_ / 1000.0) + " km";
	if(nautical) {
		# the same in nautical miles: 1 2 5 of a power of ten
		nm := 0.001;
		while(nm * 10.0 * 1852.0 <= most)
			nm *= 10.0;
		if(nm * 5.0 * 1852.0 <= most)
			nm *= 5.0;
		else if(nm * 2.0 * 1852.0 <= most)
			nm *= 2.0;
		len_ = nm * 1852.0;
		label = short(nm) + " nm";
	}
	px := int (len_ / mpp);
	y := h - 10;
	tk->cmd(top, sys->sprint(".c create line 10 %d %d %d -width 3 -fill %s", y, 10 + px, y, textcol));
	tk->cmd(top, sys->sprint(".c create line 10 %d 10 %d -width 1 -fill %s", y - 5, y, textcol));
	tk->cmd(top, sys->sprint(".c create line %d %d %d %d -width 1 -fill %s", 10 + px, y - 5, 10 + px, y, textcol));
	tk->cmd(top, sys->sprint(".c create text %d %d -anchor sw -fill %s -text '%s",
		14 + px, y + 3, textcol, label));
}

# another craft: a pointer along its heading or course (a diamond with
# neither), its name or id, an aircraft's altitude
drawcraft(p: ref Proj, c: ref Craft)
{
	(x, y) := p.xy(c.p);
	if(c.hasdir) {
		a := c.dir * Math->Pi / 180.0;
		sa := math->sin(a);
		ca := math->cos(a);
		# nose 9 ahead, tail corners 6 behind and 5 aside
		nx := x + int (9.0*sa);
		ny := y - int (9.0*ca);
		lx := x - int (6.0*sa) - int (5.0*ca);
		ly := y + int (6.0*ca) - int (5.0*sa);
		rx := x - int (6.0*sa) + int (5.0*ca);
		ry := y + int (6.0*ca) + int (5.0*sa);
		tk->cmd(top, sys->sprint(".c create polygon %d %d %d %d %d %d -fill %s -outline %s",
			nx, ny, lx, ly, rx, ry, craftcol, craftcol));
	} else
		tk->cmd(top, sys->sprint(".c create polygon %d %d %d %d %d %d %d %d -fill %s -outline %s",
			x, y-5, x+5, y, x, y+5, x-5, y, craftcol, craftcol));
	label := c.name;
	if(label == nil)
		label = c.id;
	if(c.hasalt && c.kind != "ais")
		label += " " + altitude(c.height);
	tk->cmd(top, sys->sprint(".c create text %d %d -anchor w -fill %s -text '%s",
		x + 9, y + 1, craftcol, label));
}

altitude(m: real): string
{
	if(nautical)
		return sys->sprint("%d ft", int (m / 0.3048));
	return sys->sprint("%d m", int m);
}

# a scale's length: no more figures than it has, a 0 before a point
short(v: real): string
{
	s := sys->sprint("%.3f", v);
	while(s[len s-1] == '0')
		s = s[0:len s-1];
	if(s[len s-1] == '.')
		s = s[0:len s-1];
	return s;
}

drawline(p: ref Proj, l: ref Line)
{
	if(len l.pts == 0)
		return;
	s := "";
	for(i := 0; i < len l.pts; i++) {
		(x, y) := p.xy(l.pts[i]);
		s += sys->sprint(" %d %d", x, y);
	}
	if(len l.pts > 1)
		tk->cmd(top, ".c create line" + s + " -fill " + linecol);
	if(l.name != nil) {
		(x, y) := p.xy(l.pts[0]);
		tk->cmd(top, sys->sprint(".c create text %d %d -anchor sw -fill %s -text '%s",
			x + 3, y - 2, linecol, l.name));
	}
}

status(): string
{
	if(fix == nil || !fix.valid) {
		if(receiver != nil)
			return receiver;
		return "no fix";
	}
	s := sys->sprint("%.6f %.6f", fix.lat, fix.lon);
	if(fix.hasalt)
		s += "   " + altitude(fix.height);
	if(fix.hasbaro)
		s += "   pressure " + altitude(fix.baroalt);
	if(fix.hasspeed) {
		if(nautical)
			s += sys->sprint("   %.1f kt", fix.speed * 3600.0 / 1852.0);
		else
			s += sys->sprint("   %.1f km/h", fix.speed * 3.6);
		if(fix.hascourse && fix.speed > 0.5)
			s += "  " + bearing("trk", fix.course);
	}
	if(fix.hasheading)
		s += "  " + bearing("hdg", fix.heading);
	if(fix.err > 0.0)
		s += "   ±" + distance(fix.err);
	if(fix.sats >= 0)
		s += sys->sprint("   %d sats", fix.sats);
	if(!follow)
		s += "   (not following)";
	return s;
}

# a direction, true, and magnetic too when the variation is known
bearing(what: string, t: real): string
{
	s := sys->sprint("%s %03d°T", what, int t % 360);
	if(fix.hasmagvar) {
		m := t - fix.magvar;
		while(m < 0.0)
			m += 360.0;
		s += sys->sprint(" %03d°M", int m % 360);
	}
	return s;
}

distance(m: real): string
{
	if(nautical)
		return sys->sprint("%d ft", int (m / 0.3048));
	return sys->sprint("%d m", int m);
}

#
# Map files
#
loadmapdir(dir: string)
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return;
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if((d[i].mode & Sys->DMDIR) == 0)
				if((err := loadmap(dir + "/" + d[i].name)) != nil)
					sys->fprint(stderr, "road: %s\n", err);
	}
}

loadmap(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("%s: %r", path);
	text := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		text += string buf[0:n];
	cur: ref Line;
	pts: list of Pt;
	lno := 0;
	(nil, ls) := sys->tokenize(text, "\n");
	for(; ls != nil; ls = tl ls) {
		lno++;
		s := hd ls;
		for(i := 0; i < len s; i++)
			if(s[i] == '#')
				break;
		s = s[0:i];
		(nf, f) := sys->tokenize(s, " \t\r");
		if(nf == 0)
			continue;
		case hd f {
		"line" =>
			endline(cur, pts);
			pts = nil;
			cur = ref Line(join(tl f), nil);
		"mark" =>
			if(nf < 3 || !isnum(hd tl f) || !isnum(hd tl tl f))
				return sys->sprint("%s:%d: usage: mark lat lon [name]", path, lno);
			marks = ref Mark(join(tl tl tl f), Pt(real hd tl f, real hd tl tl f)) :: marks;
		* =>
			if(nf != 2 || !isnum(hd f) || !isnum(hd tl f))
				return sys->sprint("%s:%d: not lat lon: %s", path, lno, s);
			if(cur == nil)
				return sys->sprint("%s:%d: a point before a line", path, lno);
			pts = Pt(real hd f, real hd tl f) :: pts;
		}
	}
	endline(cur, pts);
	return nil;
}

endline(l: ref Line, pts: list of Pt)
{
	if(l == nil)
		return;
	n := 0;
	for(p := pts; p != nil; p = tl p)
		n++;
	l.pts = array[n] of Pt;
	for(; pts != nil; pts = tl pts)
		l.pts[--n] = hd pts;
	lines = l :: lines;
}

join(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l) {
		if(s != "")
			s += " ";
		s += hd l;
	}
	return s;
}

isnum(s: string): int
{
	if(s == nil)
		return 0;
	i := 0;
	if(s[0] == '-' || s[0] == '+')
		i++;
	d := 0;
	dot := 0;
	for(; i < len s; i++)
		if(s[i] >= '0' && s[i] <= '9')
			d++;
		else if(s[i] == '.' && !dot)
			dot = 1;
		else
			return 0;
	return d > 0;
}

#
# The files
#
startfs(reqs: chan of ref Appfs->Req): ref Sys->FD
{
	appfs = load Appfs Appfs->PATH;
	if(appfs == nil || appfs->init() != nil) {
		appfs = nil;
		return nil;
	}
	(nil, tether, err) := appfs->serve("road", array[] of {"ctl", "view", "marks"}, reqs);
	if(err != nil) {
		sys->fprint(stderr, "road: serve: %s\n", err);
		appfs = nil;
	}
	return tether;
}

changed()
{
	if(appfs != nil)
		appfs->event("changed");
}

view(): string
{
	f := "on";
	if(!follow)
		f = "off";
	u := "metric";
	if(nautical)
		u = "nautical";
	return sys->sprint("center %.6f %.6f\nwidth %.0f\nfollow %s\nunits %s\n", centre.lat, centre.lon, width, f, u);
}

marktext(): string
{
	s := "";
	for(l := marks; l != nil; l = tl l)
		s = sys->sprint("%.6f %.6f %s\n", (hd l).p.lat, (hd l).p.lon, (hd l).name) + s;
	return s;
}

# one command or more, a line each; nil, or why one was refused
ctl(text: string): string
{
	(nil, ls) := sys->tokenize(text, "\n");
	for(; ls != nil; ls = tl ls) {
		(n, f) := sys->tokenize(hd ls, " \t\r");
		if(n == 0)
			continue;
		case hd f {
		"center" or "centre" =>
			if(n != 3 || !isnum(hd tl f) || !isnum(hd tl tl f))
				return "usage: center lat lon";
			lat := real hd tl f;
			lon := real hd tl tl f;
			if(lat < -90.0 || lat > 90.0 || lon < -180.0 || lon > 180.0)
				return "no such place";
			centre = Pt(lat, lon);
			hascentre = 1;
			follow = 0;
		"width" =>
			if(n != 2 || !isnum(hd tl f) || real hd tl f < 10.0)
				return "usage: width metres (10 or more)";
			width = real hd tl f;
		"units" =>
			if(n != 2 || hd tl f != "metric" && hd tl f != "nautical")
				return "usage: units metric|nautical";
			nautical = hd tl f == "nautical";
		"follow" =>
			if(n != 2 || hd tl f != "on" && hd tl f != "off")
				return "usage: follow on|off";
			follow = hd tl f == "on";
			if(follow && fix != nil && fix.valid)
				centre = Pt(fix.lat, fix.lon);
		"mark" =>
			if(n < 3 || !isnum(hd tl f) || !isnum(hd tl tl f))
				return "usage: mark lat lon [name]";
			marks = ref Mark(join(tl tl tl f), Pt(real hd tl f, real hd tl tl f)) :: marks;
		"unmark" =>
			if(n < 2)
				return "usage: unmark name";
			name := join(tl f);
			nl: list of ref Mark;
			found := 0;
			for(l := marks; l != nil; l = tl l)
				if((hd l).name == name)
					found = 1;
				else
					nl = hd l :: nl;
			if(!found)
				return "no mark " + name;
			marks = nil;
			for(; nl != nil; nl = tl nl)
				marks = hd nl :: marks;
		"clear" =>
			if(n != 1)
				return "usage: clear";
			track = nil;
			ntrack = 0;
		"load" =>
			if(n != 2)
				return "usage: load path";
			if((err := loadmap(hd tl f)) != nil)
				return err;
		* =>
			return "unknown command " + hd f;
		}
	}
	return nil;
}

#
# The theme
#
themecolours()
{
	lt := load Lucitheme Lucitheme->PATH;
	if(lt == nil) {
		bgs = "#ffffffff"; gridcol = "#ddddddff"; gridtext = "#999999ff";
		textcol = "#000000ff"; trackcol = "#3366ccff"; poscol = "#cc3333ff";
		markcol = "#cc9900ff"; linecol = "#555555ff"; craftcol = "#339933ff";
		statusbg = "#eeeeeeff"; statusfg = "#000000ff";
		return;
	}
	th := lt->gettheme();
	bgs = col(th.bg);
	gridcol = col(th.border);
	gridtext = col(th.dim);
	textcol = col(th.text);
	linecol = col(th.text2);
	trackcol = col(th.accent);
	poscol = col(th.red);
	markcol = col(th.yellow);
	craftcol = col(th.green);
	statusbg = col(th.editstatus);
	statusfg = col(th.editstattext);
}

# 0xRRGGBBAA as Tk's #rrggbbff
col(c: int): string
{
	return sys->sprint("#%06xff", (c >> 8) & 16rFFFFFF);
}

themelistener()
{
	lt := load Lucitheme Lucitheme->PATH;
	if(lt == nil)
		return;
	c := lt->watch();
	for(;;) {
		<-c;
		themech <-= 1;
	}
}
