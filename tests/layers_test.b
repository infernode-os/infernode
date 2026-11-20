implement LayersTest;

#
# appl/lib/layers.b (module/layers.m): records parsed (box, line, text,
# point, a detection's class= and score= as a box, a frame's key alone,
# frame=*, lines that are none refused), and a Stack following a layer
# directory built by bind: on frame F each layer's records for its newest
# frame up to F, its frame=* records on every frame, a frame's key alone
# clearing it, bottom layer first in the union's order, the order
# following bind -a and -b, a layer unmounted gone; a detection with
# no colour drawn in its class's (one of the theme's eight categorical
# colours, by its name), its own colour= still first.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;
include "testing.m";
	testing: Testing;
	T: import testing;
include "layers.m";
	layers: Layers;
	Mark, Stack: import layers;

LayersTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/layers_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

testParse(t: ref T)
{
	(f, m) := layers->parse("frame=12 box x0=1 y0=2 x1=30 y1=40 label=door colour=accent");
	t.asserteq(f, 12, "box: frame");
	if(m == nil){
		t.fatal("box: no mark");
		return;
	}
	t.asserteq(m.kind, Layers->Box, "box: kind");
	t.asserteq(m.x1, 30, "box: x1");
	t.assertseq(m.label, "door", "box: label");
	t.assertseq(m.colour, "accent", "box: colour");

	(f, m) = layers->parse("frame=3 pts=100 class=dog score=0.86 x0=133 y0=207 x1=326 y1=543");
	t.asserteq(f, 3, "detection: frame");
	t.assert(m != nil && m.kind == Layers->Box, "a detection is a box");
	if(m != nil)
		t.assertseq(m.label, "dog 0.86", "a detection's label is its class and score");

	(f, m) = layers->parse("frame=4 line x0=0 y0=5 x1=9 y1=5");
	t.assert(m != nil && m.kind == Layers->Line && m.y1 == 5, "a line");
	(f, m) = layers->parse("frame=4 text x=10 y=11 label='3 people'");
	t.assert(m != nil && m.kind == Layers->Text && m.label == "3 people", "a text, its label quoted");
	(f, m) = layers->parse("frame=4 point x=1 y=2");
	t.assert(m != nil && m.kind == Layers->Point && m.x0 == 1, "a point");
	(f, m) = layers->parse("frame=* box x0=0 y0=0 x1=1 y1=1");
	t.asserteq(f, -1, "frame=* is every frame");
	(f, m) = layers->parse("frame=9");
	t.asserteq(f, 9, "a key alone: its frame");
	t.assert(m == nil, "a key alone: no mark");
	(f, m) = layers->parse("frame=9 pts=300");
	t.assert(f == 9 && m == nil, "a key with pts alone: no mark");

	(f, nil) = layers->parse("box x0=0 y0=0 x1=1 y1=1");
	t.asserteq(f, -2, "no frame: not a mark");
	(f, nil) = layers->parse("frame=x box x0=0 y0=0 x1=1 y1=1");
	t.asserteq(f, -2, "a frame that is no number: not a mark");
	(f, nil) = layers->parse("frame=2 box x0=0 y0=0");
	t.asserteq(f, -2, "a box without its corners: not a mark");
	(f, nil) = layers->parse("frame=2 text label=hello");
	t.asserteq(f, -2, "a text without its place: not a mark");
	(f, nil) = layers->parse("");
	t.asserteq(f, -2, "an empty line: not a mark");
}

# the colour of the pixel at p, as rrggbbaa
pixel(t: ref T, img: ref Image, p: Point): int
{
	b := array[4] of byte;
	if(img.readpixels(Rect(p, p.add((1, 1))), b) != 4){
		t.error(sys->sprint("readpixels: %r"));
		return 0;
	}
	# XRGB32: b g r x
	return (int b[2] << 24) | (int b[1] << 16) | (int b[0] << 8) | 16rFF;
}

testClassColour(t: ref T)
{
	(nil, m) := layers->parse("frame=3 class=person score=0.88 x0=10 y0=10 x1=60 y1=90");
	if(m == nil){
		t.fatal("a detection: no mark");
		return;
	}
	t.assertseq(m.class, "person", "a detection keeps its class");
	t.assertnil(m.colour, "a detection has no colour of its own");
	(nil, m2) := layers->parse("frame=3 class=car score=0.80 x0=100 y0=10 x1=150 y1=90");
	(nil, m3) := layers->parse("frame=3 class=car score=0.80 x0=200 y0=10 x1=250 y1=90 colour=red");

	draw = load Draw Draw->PATH;
	display := Display.allocate(nil);
	if(display == nil){
		t.skip(sys->sprint("no display: %r"));
		return;
	}
	img := display.newimage(Rect((0, 0), (300, 100)), Draw->XRGB32, 0, int 16rFFFFFFFF);
	cols := array[] of {
		int 16rFF0000FF, int 16r00FF00FF, int 16r0000FFFF, int 16rFFFF00FF,
		int 16rFF00FFFF, int 16r00FFFFFF, int 16r808080FF, int 16r800000FF,
	};
	l: list of (string, ref Image);
	for(i := len cols - 1; i >= 0; i--)
		l = ("pie" + string i, display.color(cols[i])) :: l;
	l = ("red", display.color(int 16r123456FF)) :: l;
	layers->draw(m :: m2 :: m3 :: nil, img, img.r, 300, 100, nil, display.color(int 16r000000FF), l);
	# the left side of each box, half way down: FNV-1a of person is
	# 0 mod 8, of car 1
	t.asserteq(pixel(t, img, (10, 50)), cols[0], "a person's box is pie0");
	t.asserteq(pixel(t, img, (100, 50)), cols[1], "a car's box is pie1, another colour");
	t.asserteq(pixel(t, img, (200, 50)), int 16r123456FF, "a detection's own colour= is drawn, not its class's");
}

writefile(t: ref T, path, s: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil){
		t.fatal(sys->sprint("create %s: %r", path));
		return;
	}
	b := array of byte s;
	sys->write(fd, b, len b);
}

labels(l: list of ref Mark): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != nil)
			s += " ";
		s += (hd l).label;
	}
	return s;
}

testStack(t: ref T)
{
	sys->pctl(Sys->FORKNS, nil);
	d := sys->sprint("/tmp/layers_test.%d.%d", sys->pctl(0, nil), sys->millisec());
	for(l := d :: (d + "/a") :: (d + "/b") :: (d + "/stack") :: nil; l != nil; l = tl l)
		if(sys->create(hd l, Sys->OREAD, Sys->DMDIR | 8r777) == nil){
			t.fatal(sys->sprint("mkdir %s: %r", hd l));
			return;
		}
	writefile(t, d + "/a/doors", "frame=* box x0=1 y0=1 x1=9 y1=9 label=door\n" +
		"frame=3 box x0=2 y0=2 x1=8 y1=8 label=three\n");
	writefile(t, d + "/b/count", "frame=5 text x=1 y=1 label=five\n" +
		"frame=7\n" +
		"frame=9 text x=1 y=1 label=nine\n");

	if(sys->bind(d + "/a", d + "/stack", Sys->MREPL) < 0 ||
	   sys->bind(d + "/b", d + "/stack", Sys->MAFTER) < 0){
		t.fatal(sys->sprint("bind: %r"));
		return;
	}
	s := Stack.watch(d + "/stack");
	sys->sleep(1200);	# the listing, and the readers
	t.assertseq(labels(s.due(0)), "door", "frame 0: the door, every frame");
	t.assertseq(labels(s.due(3)), "door three", "frame 3: the door, then its own record");
	t.assertseq(labels(s.due(4)), "door three", "frame 4: the newest up to it, frame 3's");
	t.assertseq(labels(s.due(6)), "door three five", "frame 6: the count, layered above");
	t.assertseq(labels(s.due(8)), "door three", "frame 8: frame 7's key alone cleared the count");
	t.assertseq(labels(s.due(100)), "door three nine", "frame 100: each layer's newest");

	# the count underneath instead: bind -b
	sys->unmount(d + "/b", d + "/stack");
	sys->bind(d + "/b", d + "/stack", Sys->MBEFORE);
	sys->sleep(1200);
	t.assertseq(labels(s.due(6)), "five door three", "bind -b: the count underneath");

	# and gone
	sys->unmount(d + "/b", d + "/stack");
	sys->sleep(1200);
	t.assertseq(labels(s.due(6)), "door three", "unmounted: the count gone");

	# a layer file rewritten is read again
	sys->sleep(1100);	# a new modification time
	writefile(t, d + "/a/doors", "frame=* box x0=1 y0=1 x1=9 y1=9 label=gate\n");
	sys->sleep(1200);
	t.assertseq(labels(s.due(6)), "gate", "rewritten: the new records, the old gone");
	s.stop();
	sys->unmount(d + "/a", d + "/stack");
	for(l = (d + "/a/doors") :: (d + "/b/count") :: (d + "/a") :: (d + "/b") :: (d + "/stack") :: d :: nil; l != nil; l = tl l)
		sys->remove(hd l);
}

# the Layers procs in this test's process group: its stacks' watchers
# (and readers, while they read)
watchers(): int
{
	grp := field(readall("/prog/" + string sys->pctl(0, nil) + "/status"), 1);
	n := 0;
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	for(;;){
		(k, d) := sys->dirread(fd);
		if(k <= 0)
			break;
		for(i := 0; i < k; i++){
			st := readall("/prog/" + d[i].name + "/status");
			m := field(st, 6);
			if(field(st, 1) == grp && len m >= 6 && m[0:6] == "Layers")
				n++;
		}
	}
	return n;
}

field(s: string, i: int): string
{
	(nil, l) := sys->tokenize(s, " \t\n");
	for(; l != nil && i > 0; l = tl l)
		i--;
	if(l == nil)
		return nil;
	return hd l;
}

readall(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

emptydir(t: ref T): string
{
	d := sys->sprint("/tmp/layers_test.%d.%d", sys->pctl(0, nil), sys->millisec());
	if(sys->create(d, Sys->OREAD, Sys->DMDIR | 8r777) == nil)
		t.fatal(sys->sprint("mkdir %s: %r", d));
	return d;
}

# stop while the watcher sleeps between listings, where it nearly always
# is: it stops. The stop was sent on an unbuffered channel, without
# waiting, and dropped unless the watcher was in its alt at that moment.
testStopAsleep(t: ref T)
{
	if(watchers() < 0)
		t.skip("no /prog");
	d := emptydir(t);
	sys->sleep(1200);	# an earlier test's stacks settled (a stop takes a listing)
	n0 := watchers();
	s := Stack.watch(d);
	sys->sleep(200);	# listed, and asleep
	t.asserteq(watchers(), n0 + 1, "a watcher while it is watched");
	s.stop();
	sys->sleep(1200);	# past the next listing
	t.asserteq(watchers(), n0, "stopped: no watcher left");
	sys->remove(d);
}

# The proc that started the watching gone, never having said stop (a
# window died of an exception): the watcher goes too, at its next look.
testOwnerGone(t: ref T)
{
	if(watchers() < 0)
		t.skip("no /prog");
	d := emptydir(t);
	sys->sleep(1200);	# an earlier test's stacks settled (a stop takes a listing)
	n0 := watchers();
	done := chan of ref Stack;
	spawn owner(d, done);
	s := <-done;
	sys->sleep(200);
	t.assert(s != nil, "watched");
	t.asserteq(watchers(), n0 + 1, "a watcher while its owner lives");
	sys->sleep(1200);	# the owner has returned: the next listing sees it gone
	t.asserteq(watchers(), n0, "owner gone: no watcher left");
	sys->remove(d);
}

owner(d: string, done: chan of ref Stack)
{
	s := Stack.watch(d);
	done <-= s;
	sys->sleep(100);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	layers = load Layers Layers->PATH;
	if(layers == nil){
		sys->fprint(sys->fildes(2), "cannot load layers: %r\n");
		raise "fail:load";
	}
	if((e := layers->init()) != nil){
		sys->fprint(sys->fildes(2), "layers: %s\n", e);
		raise "fail:init";
	}
	run("Parse", testParse);
	run("Stack", testStack);
	run("StopAsleep", testStopAsleep);
	run("OwnerGone", testOwnerGone);
	run("ClassColour", testClassColour);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
