implement DrawscopeTest;

#
# The draw device's scopes (draw(3)): what a client attached as #i<spec>
# reaches, spoken to in the draw protocol, beside a client attached as #i:
#  - Listing: a scope's top directory has draw and not screen; its draw
#    lists the scope's clients and not others; screen and another
#    client's data cannot be opened through it;
#  - Zero: a scoped client's image 0 is a 1x1 image of its own, not the
#    screen; an unscoped client's is the screen, as before;
#  - Names: a scoped client finds neither an unscoped name nor another
#    scope's, finds an unscoped name beginning "<spec>." and draws on it,
#    its own names stay its scope's (the same name in two scopes, an
#    unscoped client not finding them), and it cannot delete a name not
#    its scope's;
#  - Screens: a scoped client attaches its own scope's public screen and
#    not an unscoped one's;
#  - Machine: a scoped client changes neither the colour map nor the
#    debugging flag.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Chans: import draw;

include "string.m";
	str: String;

include "testing.m";
	testing: Testing;
	T: import testing;

DrawscopeTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/drawscope_test.b";

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

Rect: adt {
	x0, y0, x1, y1: int;
};

# a client of the device: the directory it came by, its id, its files
Conn: adt {
	dir: string;
	id: string;
	ctl: ref Sys->FD;
	data: ref Sys->FD;
	info: array of string;
};

pl(a: array of byte, o: int, v: int): int
{
	a[o] = byte v;
	a[o+1] = byte (v>>8);
	a[o+2] = byte (v>>16);
	a[o+3] = byte (v>>24);
	return o+4;
}

pr(a: array of byte, o: int, r: Rect): int
{
	o = pl(a, o, r.x0);
	o = pl(a, o, r.y0);
	o = pl(a, o, r.x1);
	return pl(a, o, r.y1);
}

connect(dir: string): (ref Conn, string)
{
	ctl := sys->open(dir+"/draw/new", Sys->ORDWR);
	if(ctl == nil)
		return (nil, sys->sprint("%s/draw/new: %r", dir));
	info := array[12*12] of byte;
	n := sys->read(ctl, info, len info);
	if(n < 12*12)
		return (nil, sys->sprint("%s: ctl read %d: %r", dir, n));
	f := array[12] of string;
	for(i := 0; i < 12; i++)
		f[i] = str->drop(string info[i*12:i*12+11], " ");
	data := sys->open(dir+"/draw/"+f[0]+"/data", Sys->ORDWR);
	if(data == nil)
		return (nil, sys->sprint("%s/draw/%s/data: %r", dir, f[0]));
	return (ref Conn(dir, f[0], ctl, data, f), nil);
}

send(c: ref Conn, a: array of byte): string
{
	if(sys->write(c.data, a, len a) != len a)
		return sys->sprint("%r");
	return nil;
}

alloc(c: ref Conn, id, screen, public: int, r: Rect, colour: int): string
{
	a := array[51] of byte;
	a[0] = byte 'b';
	o := pl(a, 1, id);
	o = pl(a, o, screen);
	a[o++] = byte 0;
	o = pl(a, o, Chans.mk("x8r8g8b8").desc);
	a[o++] = byte 0;
	o = pr(a, o, r);
	o = pr(a, o, r);
	pl(a, o, colour);
	e := send(c, a);
	if(e == nil && public >= 0){
		# 'A' id[4] imageid[4] fillid[4] public[1]: a screen on it
		s := array[14] of byte;
		s[0] = byte 'A';
		o = pl(s, 1, public);
		o = pl(s, o, id);
		o = pl(s, o, id);
		s[o] = byte 1;
		e = send(c, s);
	}
	return e;
}

name(c: ref Conn, id: int, nm: string, on: int): string
{
	b := array of byte nm;
	a := array[7+len b] of byte;
	a[0] = byte 'N';
	pl(a, 1, id);
	a[5] = byte on;
	a[6] = byte len b;
	a[7:] = b;
	return send(c, a);
}

importname(c: ref Conn, id: int, nm: string): string
{
	b := array of byte nm;
	a := array[6+len b] of byte;
	a[0] = byte 'n';
	pl(a, 1, id);
	a[5] = byte len b;
	a[6:] = b;
	return send(c, a);
}

attachscreen(c: ref Conn, id: int): string
{
	a := array[9] of byte;
	a[0] = byte 'S';
	pl(a, 1, id);
	pl(a, 5, Chans.mk("x8r8g8b8").desc);
	return send(c, a);
}

fill(c: ref Conn, id: int, r: Rect, colour: int): string
{
	# a 1x1 replicated colour (id 900) drawn over r of id
	alloc1 := array[51] of byte;
	alloc1[0] = byte 'b';
	o := pl(alloc1, 1, 900);
	o = pl(alloc1, o, 0);
	alloc1[o++] = byte 0;
	o = pl(alloc1, o, Chans.mk("r8g8b8a8").desc);	# opaque as its own mask
	alloc1[o++] = byte 1;
	o = pr(alloc1, o, Rect(0, 0, 1, 1));
	o = pr(alloc1, o, Rect(-16r3FFFFFFF, -16r3FFFFFFF, 16r3FFFFFFF, 16r3FFFFFFF));
	pl(alloc1, o, colour);
	if((e := send(c, alloc1)) != nil)
		return e;
	d := array[45] of byte;
	d[0] = byte 'd';
	o = pl(d, 1, id);
	o = pl(d, o, 900);
	o = pl(d, o, 900);
	o = pr(d, o, r);
	o = pl(d, o, 0);
	o = pl(d, o, 0);
	o = pl(d, o, 0);
	pl(d, o, 0);
	e = send(c, d);
	f := array[5] of byte;
	f[0] = byte 'f';
	pl(f, 1, 900);
	send(c, f);
	return e;
}

pixel(c: ref Conn, id, x, y: int): (int, string)
{
	a := array[21] of byte;
	a[0] = byte 'r';
	o := pl(a, 1, id);
	pr(a, o, Rect(x, y, x+1, y+1));
	if((e := send(c, a)) != nil)
		return (0, e);
	b := array[4] of byte;
	if(sys->read(c.data, b, 4) != 4)
		return (0, sys->sprint("read back: %r"));
	return ((int b[2]<<16)|(int b[1]<<8)|int b[0], nil);
}

ls(dir: string): list of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			l = d[i].name :: l;
	}
	return l;
}

has(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

uniq := 0;
scope(): string
{
	return sys->sprint("dstest%d.%d", sys->pctl(0, nil), uniq++);
}

testListing(t: ref T)
{
	sc := scope();
	(plain, e) := connect("#i");
	if(plain == nil)
		t.fatal(e);
	(mine, e2) := connect("#i"+sc);
	if(mine == nil)
		t.fatal(e2);
	top := ls("#i"+sc);
	t.assert(has(top, "draw") && !has(top, "screen"), "a scope's top has draw and not screen");
	t.assert(has(ls("#i"), "screen"), "the device's own top still has screen");
	t.assert(sys->open("#i"+sc+"/screen", Sys->OREAD) == nil, "screen not opened through a scope");
	l := ls("#i"+sc+"/draw");
	t.assert(has(l, mine.id), "the scope lists its client");
	t.assert(!has(l, plain.id), "the scope does not list another client");
	t.assert(has(ls("#i/draw"), plain.id), "the device lists the unscoped client");
	t.assert(!has(ls("#i/draw"), mine.id), "the device does not list a scope's client unscoped");
	fd := sys->open("#i"+sc+"/draw/"+plain.id+"/data", Sys->ORDWR);
	t.assert(fd == nil, "another client's data not opened through a scope");
	other := scope();
	(theirs, nil) := connect("#i"+other);
	t.assert(theirs != nil && !has(ls("#i"+sc+"/draw"), theirs.id), "nor another scope's client listed");
}

testZero(t: ref T)
{
	(plain, e) := connect("#i");
	if(plain == nil)
		t.fatal(e);
	(mine, e2) := connect("#i"+scope());
	if(mine == nil)
		t.fatal(e2);
	# info: id, imageid, chan, repl, r(4), clipr(4)
	t.assert(mine.info[4] == "0" && mine.info[5] == "0" && mine.info[6] == "1" && mine.info[7] == "1",
		sys->sprint("a scoped client's image 0 is 1x1: %s %s %s %s", mine.info[4], mine.info[5], mine.info[6], mine.info[7]));
	t.assert(int plain.info[6] > 1 && int plain.info[7] > 1,
		sys->sprint("an unscoped client's image 0 is the screen: %s %s", plain.info[6], plain.info[7]));
	t.assertnil(fill(mine, 0, Rect(0, 0, 1, 1), int 16rFF0000FF), "a scoped client draws on its image 0");
	(p, pe) := pixel(mine, 0, 0, 0);
	t.assertnil(pe, "and reads it back");
	t.asserteq(p, 16rFF0000, "its own pixel");
}

testNames(t: ref T)
{
	sc := scope();
	(plain, e) := connect("#i");
	if(plain == nil)
		t.fatal(e);
	(mine, e2) := connect("#i"+sc);
	if(mine == nil)
		t.fatal(e2);
	(theirs, e3) := connect("#i"+scope());
	if(theirs == nil)
		t.fatal(e3);
	r := Rect(0, 0, 8, 8);

	# the machine's: a name a scope must not find
	t.assertnil(alloc(plain, 1, 0, -1, r, int 16r00FF00FF), "unscoped image");
	priv := sc+"x-private";
	t.assertnil(name(plain, 1, priv, 1), "unscoped name");
	t.assert(importname(mine, 10, priv) != nil, "a scope does not find an unscoped name");
	t.assert(importname(plain, 10, priv) == nil, "an unscoped client still does");

	# given it: an unscoped name beginning "<scope>."
	t.assertnil(alloc(plain, 2, 0, -1, r, int 16r0000FFFF), "the window");
	win := sc+".win.0";
	t.assertnil(name(plain, 2, win, 1), "the window's name");
	t.assertnil(importname(mine, 11, win), "the scope finds its window");
	t.assert(importname(theirs, 11, win) != nil, "another scope does not");
	t.assertnil(fill(mine, 11, Rect(2, 2, 3, 3), int 16rFF0000FF), "the scope draws on its window");
	(p, pe) := pixel(plain, 2, 2, 2);
	t.assertnil(pe, "read back unscoped");
	t.asserteq(p, 16rFF0000, "the window has what the scope drew");

	# its own names: the scope's
	t.assertnil(alloc(mine, 3, 0, -1, r, int 16rFFFFFFFF), "a scoped image");
	t.assertnil(name(mine, 3, "shared", 1), "a scoped name");
	t.assertnil(alloc(theirs, 3, 0, -1, r, int 16rFFFFFFFF), "another scope's image");
	t.assertnil(name(theirs, 3, "shared", 1), "the same name in another scope");
	t.assert(importname(plain, 12, "shared") != nil, "an unscoped client does not find a scope's name");
	t.assert(name(mine, 3, priv, 1) == nil, "a scope may use a name the machine has, in its own scope");
	t.assert(importname(plain, 13, priv) == nil, "and the machine's is still the machine's");

	# deleting: only its scope's
	t.assert(name(mine, 1, win, 0) != nil, "a scope does not delete the name it was given");
	t.assert(importname(mine, 14, win) == nil, "which is still there");
}

testScreens(t: ref T)
{
	sc := scope();
	(plain, e) := connect("#i");
	if(plain == nil)
		t.fatal(e);
	(mine, e2) := connect("#i"+sc);
	if(mine == nil)
		t.fatal(e2);
	(mine2, e3) := connect("#i"+sc);
	if(mine2 == nil)
		t.fatal(e3);
	base := 1000 + sys->pctl(0, nil)%1000 * 10;
	r := Rect(0, 0, 16, 16);
	t.assertnil(alloc(plain, 1, 0, base, r, int 16r808080FF), "an unscoped public screen");
	t.assert(attachscreen(mine, base) != nil, "a scope does not attach it");
	t.assertnil(attachscreen(plain, base), "the screen is attached unscoped");
	t.assertnil(alloc(mine, 1, 0, base+1, r, int 16r808080FF), "a scope's public screen");
	t.assertnil(attachscreen(mine2, base+1), "the scope's other client attaches it");
	t.assert(attachscreen(plain, base+1) != nil, "an unscoped client does not");
}

testMachine(t: ref T)
{
	(mine, e) := connect("#i"+scope());
	if(mine == nil)
		t.fatal(e);
	a := array[2] of byte;
	a[0] = byte 'D';
	a[1] = byte 1;
	t.assert(send(mine, a) != nil, "a scope does not set the debugging flag");
	fd := sys->open(mine.dir+"/draw/"+mine.id+"/colormap", Sys->OWRITE);
	if(fd != nil){
		b := array of byte "0 0 0 0\n";
		t.assert(sys->write(fd, b, len b) < 0, "nor writes the colour map");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	str = load String String->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	if(sys->stat("#i/draw/new").t0 < 0){
		sys->print("no draw device: %r\n");
		testing->summary(0, 0, 1);
		return;
	}

	run("Listing", testListing);
	run("Zero", testZero);
	run("Names", testNames);
	run("Screens", testScreens);
	run("Machine", testMachine);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
