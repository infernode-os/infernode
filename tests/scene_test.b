implement SceneTest;

#
# scene_test - lib/scene (model, record grammar, camera, trails, hit,
# rendering) and anti-aliased paths.
#
# The drawing tests need /dev/draw (any emu: the headless build has a
# memory screen) and skip without it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Font, Image, Path, Point, Rect: import draw;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "scene.m";
	scene: Scene;
	Model, Cam, Trails, Obj: import scene;
include "testing.m";
	testing: Testing;
	T: import testing;

SceneTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/scene_test.b";

passed := 0;
failed := 0;
skipped := 0;
display: ref Display;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>	;
	"fail:skip" =>	;
	* =>	t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

close(a, b, tol: real): int
{
	d := a - b;
	if(d < 0.0) d = -d;
	return d <= tol;
}

needdisplay(t: ref T)
{
	if(display == nil)
		t.skip("no /dev/draw");
}

testStanza(t: ref T)
{
	kv := scene->stanza("# a comment\nx=10\n\nlabel=Relay 2  \nbad line\ny = -3.5\n");
	t.asserteq(len kv, 3, "three attributes, comment and junk dropped");
	(k, v) := hd kv;
	t.assertseq(k, "x", "order kept");
	t.assertseq(v, "10", "value");
	(nil, v) = hd tl kv;
	t.assertseq(v, "Relay 2", "a value keeps its spaces, trimmed");
	(k, v) = hd tl tl kv;
	t.assertseq(k + "=" + v, "y=-3.5", "spaces around = trimmed");
}

testRecords(t: ref T)
{
	m := Model.new();
	t.assertnil(m.apply("meta frame=xy units=m 'title=Test run'"), "meta");
	t.asserteq(m.frame, Scene->XY, "frame=xy");
	t.assertseq(m.title, "Test run", "quoted value");
	t.assertnil(m.apply("time 12.5"), "time");
	t.assert(m.hast && close(m.t, 12.5, 1e-9), "clock set");
	t.assertnil(m.apply("ent r2 x=100 y=-50 'label=Relay 2' shape=triangle course=90"), "ent");
	e := m.find(Scene->ENT, "r2");
	t.assert(e != nil, "entity exists");
	t.assert(e.haspos && close(e.a, 100.0, 1e-9) && close(e.b, -50.0, 1e-9), "xy position");
	t.assertseq(e.label, "Relay 2", "label");
	t.asserteq(e.shape, Scene->STRIANGLE, "shape");
	t.assert(e.hascourse && close(e.course, 90.0, 1e-9), "course");
	t.assertnil(m.apply("feat ao type=polygon 'points=0,0 10,0 10,10' fill=FF000080"), "feat");
	f := m.find(Scene->FEAT, "ao");
	t.asserteq(len f.pts, 3, "three points");
	# (compared as text: an out-of-range int constant does not compare equal)
	t.assert(f.hasfill, "fill set");
	t.assertseq(sys->sprint("%ux", f.fill), "ff000080", "fill colour");
	t.assertnil(m.apply("layer g kind=grid step=250"), "layer");
	t.asserteq(m.count(Scene->LAYER), 1, "one layer");

	# replace, not patch
	m.apply("ent r2 x=1 y=2");
	e = m.find(Scene->ENT, "r2");
	t.assertnil(e.get("label"), "ent replaces the whole stanza");
	t.assertseq(e.label, "r2", "label defaults to the id");

	t.assertnil(m.apply("del ent r2"), "del");
	t.assert(m.find(Scene->ENT, "r2") == nil, "deleted");
	t.assertnotnil(m.apply("del thing x"), "del of an unknown kind is refused");
	t.assertnotnil(m.apply("ent a/b x=1 y=1"), "an id with a slash is refused");
	t.assertnotnil(m.apply("frobnicate"), "unknown record refused");
	t.assertnil(m.apply("# comment"), "comments ignored");
	g := m.gen;
	m.apply("clear");
	t.asserteq(m.count(Scene->FEAT), 0, "clear empties");
	t.assert(m.gen > g, "gen moves on change");
}

testDump(t: ref T)
{
	m := Model.new();
	m.apply("meta frame=xy 'title=A B'");
	m.apply("time 3");
	m.apply("ent b x=1 y=2 'label=two words'");
	m.apply("ent a x=3 y=4");
	m.apply("feat f type=circle points=0,0 radius=10");
	n := Model.new();
	(nil, lines) := sys->tokenize(m.dump(), "\n");
	for(; lines != nil; lines = tl lines)
		t.assertnil(n.apply(hd lines), "dump record applies: " + hd lines);
	t.assertseq(n.title, "A B", "meta survives");
	t.assert(close(n.t, 3.0, 1e-9), "clock survives");
	ents := n.objs(Scene->ENT);
	t.asserteq(len ents, 2, "entities survive");
	t.assertseq(ents[0].id, "a", "objs sorted by id");
	t.assertseq(n.find(Scene->ENT, "b").text(), m.find(Scene->ENT, "b").text(), "stanza text survives");
}

testFrameReparse(t: ref T)
{
	m := Model.new();
	m.apply("ent g lat=37.5 lon=-122.25");
	m.apply("ent p x=5 y=6");
	t.assert(m.find(Scene->ENT, "g").haspos, "geo entity placed in geo frame");
	t.assert(!m.find(Scene->ENT, "p").haspos, "xy entity unplaced in geo frame");
	m.apply("meta frame=xy");
	t.assert(!m.find(Scene->ENT, "g").haspos, "geo entity unplaced after frame=xy");
	t.assert(m.find(Scene->ENT, "p").haspos, "xy entity placed after frame=xy");
}

testCamera(t: ref T)
{
	r := Rect((0, 0), (800, 600));
	m := Model.new();
	m.apply("meta frame=xy");
	c := Cam.new(r);
	c.ca = 100.0; c.cb = 200.0; c.zoom = 1.0;	# 2 px per unit
	p := c.fwd(m, 100.0, 200.0);
	t.assert(p.eq(Point(400, 300)), "the centre maps to the middle");
	p = c.fwd(m, 110.0, 200.0);
	t.asserteq(p.x, 420, "x grows right at 2 px/unit");
	p = c.fwd(m, 100.0, 210.0);
	t.asserteq(p.y, 280, "y grows up");
	(a, b) := c.inv(m, Point(420, 280));
	t.assert(close(a, 110.0, 1e-9) && close(b, 210.0, 1e-9), "inv undoes fwd");
	c.pan(m, 20, 0);
	t.assert(close(c.ca, 90.0, 1e-9), "panning right moves the centre left");
	(a1, b1) := c.inv(m, Point(600, 300));
	c.zoomat(m, Point(600, 300), 1.0);
	(a2, b2) := c.inv(m, Point(600, 300));
	t.assert(close(a1, a2, 0.5) && close(b1, b2, 0.5), "zoomat keeps the point under the pointer");
	t.assert(close(c.upp(m), 0.25, 1e-9), "units per pixel at zoom 2");

	m.apply("ent a x=0 y=0");
	m.apply("ent b x=1000 y=500");
	c.fit(m);
	pa := c.fwd(m, 0.0, 0.0);
	pb := c.fwd(m, 1000.0, 500.0);
	t.assert(pa.in(r) && pb.in(r), "fit shows the data");
	t.assert(pb.x - pa.x > 500, "fit fills the width");

	c.sel = "a";
	s := c.text(m);
	d := Cam.new(r);
	t.assert(d.parse(s), "parse reports a change");
	t.assert(close(d.ca, c.ca, 1e-6) && close(d.zoom, c.zoom, 1e-6), "view line round-trips");
	t.assertseq(d.sel, "a", "sel round-trips");
	t.assert(d.follow == nil, "- is none");
	t.assert(!d.parse(s), "same view: no change");

	g := Model.new();
	gc := Cam.new(r);
	gc.ca = 37.77; gc.cb = -122.42; gc.zoom = 12.0;
	(la, lo) := gc.inv(g, gc.fwd(g, 37.78, -122.40));
	t.assert(close(la, 37.78, 1e-3) && close(lo, -122.40, 1e-3), "geo round trip");
	t.assert(close(gc.upp(g), 40075016.686 * 0.7907 / (256.0 * 4096.0), 0.2), "geo metres per pixel");
}

testTrails(t: ref T)
{
	m := Model.new();
	m.apply("meta frame=xy trail=3");
	tr := Trails.new();
	m.apply("ent a x=0 y=0");
	m.apply("ent b x=0 y=0 trail=0");
	tr.note(m);
	tr.note(m);	# stationary: nothing new
	t.asserteq(len tr.get("a"), 1, "stationary entity adds one point");
	t.assert(tr.get("b") == nil, "trail=0 keeps nothing");
	for(i := 1; i <= 5; i++) {
		m.apply(sys->sprint("ent a x=%d y=0", i));
		tr.note(m);
	}
	p := tr.get("a");
	t.asserteq(len p, 3, "ring holds trail= points");
	(x, nil) := p[2];
	t.assert(close(x, 5.0, 1e-9), "newest last");
	(x, nil) = p[0];
	t.assert(close(x, 3.0, 1e-9), "oldest dropped");
}

testHit(t: ref T)
{
	m := Model.new();
	m.apply("meta frame=xy");
	m.apply("ent a x=0 y=0");
	m.apply("ent b x=100 y=0");
	c := Cam.new(Rect((0, 0), (400, 400)));
	c.zoom = 0.0;
	t.assertseq(scene->hit(m, c, Point(203, 199), 14), "a", "nearest within radius");
	t.assertseq(scene->hit(m, c, Point(298, 202), 14), "b", "the other one");
	t.assert(scene->hit(m, c, Point(250, 200), 14) == nil, "nothing close");
}

testRender(t: ref T)
{
	needdisplay(t);
	m := Model.new();
	m.apply("meta frame=xy");
	m.apply("ent a x=0 y=0 color=FF0000 size=8");
	r := Rect((0, 0), (200, 200));
	img := display.newimage(r, Draw->RGB24, 0, Draw->Black);
	scene->init(display, nil);
	c := Cam.new(r);
	c.zoom = 0.0;
	scene->render(img, m, c, nil, 0, nil);
	px := array[3] of byte;
	img.readpixels(Rect((100, 100), (101, 101)), px);
	t.assert(int px[2] > 200 && int px[1] < 60 && int px[0] < 60, "entity centre is its colour");
	img.readpixels(Rect((150, 30), (151, 31)), px);
	t.assert(int px[2] < 60, "far away is background");
}

testAA(t: ref T)
{
	needdisplay(t);
	img := display.newimage(Rect((0, 0), (300, 300)), Draw->GREY8, 0, Draw->Black);
	img.fillpath(Path.new().ellipse(150.5, 150.5, 100.0, 100.0), ~0, display.white, (0, 0));
	px := array[1] of byte;
	img.readpixels(Rect((150, 150), (151, 151)), px);
	t.asserteq(int px[0], 255, "disc centre is solid");
	img.readpixels(Rect((150, 110), (151, 111)), px);
	t.asserteq(int px[0], 255, "disc interior is solid");
	img.readpixels(Rect((150, 45), (151, 46)), px);
	t.asserteq(int px[0], 0, "outside is empty");
	# a pixel the edge crosses is partly covered: at 45 degrees the
	# circle passes between pixel centres
	partial := 0;
	for(x := 215; x <= 225; x++) {
		img.readpixels(Rect((x, x), (x+1, x+1)), px);
		if(int px[0] > 0 && int px[0] < 255)
			partial = 1;
	}
	t.assert(partial, "the rim is anti-aliased");

	img.draw(img.r, display.black, nil, (0, 0));
	img.fillpath(Path.new().moveto(20.0, 20.0).lineto(280.0, 20.0).lineto(280.0, 280.0).lineto(20.0, 280.0).close(),
		1, display.white, (0, 0));
	img.readpixels(Rect((150, 150), (151, 151)), px);
	t.asserteq(int px[0], 255, "polygon interior is solid");
	img.readpixels(Rect((10, 150), (11, 151)), px);
	t.asserteq(int px[0], 0, "outside the polygon is empty");
}

writefile(path, text: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return;
	b := array of byte text;
	sys->write(fd, b, len b);
}

mkscene(dir, meta: string)
{
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	for(l := "entities" :: "features" :: "layers" :: nil; l != nil; l = tl l)
		sys->create(dir + "/" + hd l, Sys->OREAD, Sys->DMDIR|8r777);
	writefile(dir + "/meta", meta);
}

pixel(img: ref Image, p: Point): (int, int, int)
{
	px := array[3] of byte;
	img.readpixels(Rect(p, p.add((1, 1))), px);
	return (int px[2], int px[1], int px[0]);
}

testLayers(t: ref T)
{
	B := "/tmp/scene_test_base";
	O := "/tmp/scene_test_over";
	mkscene(B, "frame=xy\n");
	mkscene(O, "frame=xy\n");
	writefile(O + "/entities/e", "x=0\ny=0\ncolor=FF0000\nsize=8\nlabel=\n");
	writefile(B + "/layers/over", "kind=scene\ndir=" + O + "\n");
	m := Model.read(B);
	l := m.find(Scene->LAYER, "over");
	t.assert(l != nil && l.sub != nil, "a scene layer reads its scene");
	t.assert(l.sub.find(Scene->ENT, "e") != nil, "with its entities");

	# a scene that layers itself stops at the depth limit
	writefile(B + "/layers/self", "kind=scene\ndir=" + B + "\n");
	m = Model.read(B);
	d := 0;
	for(x := m; x != nil && (sl := x.find(Scene->LAYER, "self")) != nil; x = sl.sub)
		d++;
	t.assert(d > 0 && d <= 5, "self-layering is bounded");
	sys->remove(B + "/layers/self");

	sig := scene->signature(B);
	writefile(O + "/entities/e", "x=0\ny=0\ncolor=FF0000\nsize=9\nlabel=\n");
	t.assert(scene->signature(B) != sig, "the signature sees a change in an overlaid scene");

	if(display != nil) {
		scene->init(display, nil);
		r := Rect((0, 0), (100, 100));
		img := display.newimage(r, Draw->RGB24, 0, Draw->Black);
		c := Cam.new(r);
		c.zoom = 0.0;
		m = Model.read(B);
		scene->render(img, m, c, nil, 0, nil);
		(red, nil, nil) := pixel(img, Point(50, 50));
		t.assert(red > 200, "the layer's entity is drawn");

		writefile(B + "/layers/over", "kind=scene\ndir=" + O + "\nopacity=128\n");
		m = Model.read(B);
		scene->render(img, m, c, nil, 0, nil);
		(red, nil, nil) = pixel(img, Point(50, 50));
		t.assert(red > 80 && red < 180, sys->sprint("opacity=128 is about half: %d", red));

		writefile(B + "/layers/over", "kind=scene\ndir=" + O + "\nhide=1\n");
		m = Model.read(B);
		scene->render(img, m, c, nil, 0, nil);
		(red, nil, nil) = pixel(img, Point(50, 50));
		t.assert(red < 60, "hide=1 hides it");

		writefile(B + "/meta", "frame=geo\n");
		writefile(B + "/layers/over", "kind=scene\ndir=" + O + "\n");
		m = Model.read(B);
		scene->render(img, m, c, nil, 0, nil);
		(red, nil, nil) = pixel(img, Point(50, 50));
		t.assert(red < 60, "a scene in another frame is not drawn");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	scene = load Scene Scene->PATH;
	if(scene == nil) {
		sys->fprint(sys->fildes(2), "cannot load scene module: %r\n");
		raise "fail:cannot load scene";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	display = Display.allocate(nil);

	run("Stanza", testStanza);
	run("Records", testRecords);
	run("Dump", testDump);
	run("FrameReparse", testFrameReparse);
	run("Camera", testCamera);
	run("Trails", testTrails);
	run("Hit", testHit);
	run("Render", testRender);
	run("AA", testAA);
	run("Layers", testLayers);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
