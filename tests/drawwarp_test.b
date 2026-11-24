implement DrawwarpTest;

#
# The draw device's 'w' message (9front's affinewarp(2)), spoken to in the
# draw protocol as 9front's libdraw speaks it:
#  - Ninefront: every warp in tests/host/drawwarp/9front-vectors.txt, which
#    9front 11952's libmemdraw made (tests/host/drawwarp/vecgen.c), gives
#    the same pixels here, byte for byte (their SHA-256);
#  - Windows: a warp into a window partly under another, onto a window
#    from itself and from another, gives the pixels a plain image does;
#  - Refused: a short message, an image that is not there, a matrix past
#    what memaffinewarp can do without overflow, each with its error;
#  - Hostile: points and matrices at the ends of their ranges, an upscale
#    flag on a matrix that is no upscale, a destination of 1 bit a pixel:
#    each answered in time and the device still drawing after.
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Chans: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "keyring.m";
	keyring: Keyring;

include "string.m";
	str: String;

include "testing.m";
	testing: Testing;
	T: import testing;

DrawwarpTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/drawwarp_test.b";
VECTORS: con "/tests/host/drawwarp/9front-vectors.txt";

passed := 0;
failed := 0;
skipped := 0;

data: ref Sys->FD;
lastpix: array of byte;	# the destination's pixels after the last warp, for a failure's log

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

# the draw protocol's pieces

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

send(a: array of byte): string
{
	if(sys->write(data, a, len a) != len a)
		return sys->sprint("%r");
	return nil;
}

# 'b' id[4] screenid[4] refresh[1] chan[4] repl[1] R[4*4] clipR[4*4] rrggbbaa[4]
alloc(id, screen: int, ch: int, repl: int, r: Rect, clip: Rect, colour: int): string
{
	a := array[51] of byte;
	a[0] = byte 'b';
	o := pl(a, 1, id);
	o = pl(a, o, screen);
	a[o++] = byte 0;
	o = pl(a, o, ch);
	a[o++] = byte repl;
	o = pr(a, o, r);
	o = pr(a, o, clip);
	pl(a, o, colour);
	return send(a);
}

free(id: int)
{
	a := array[5] of byte;
	a[0] = byte 'f';
	pl(a, 1, id);
	send(a);
}

# 'y' id[4] R[4*4] data[x*1]
loadpix(id: int, r: Rect, pix: array of byte): string
{
	a := array[21+len pix] of byte;
	a[0] = byte 'y';
	o := pl(a, 1, id);
	o = pr(a, o, r);
	a[o:] = pix;
	return send(a);
}

# 'w' dstid[4] P[2*4] R[4*4] srcid[4] P[2*4] mskid[4] P[2*4] M[3*3*4] flags[1]
warp(dst, dpx, dpy: int, r: Rect, src, spx, spy: int, m: array of int, flags, smooth: int): string
{
	a := array[1+4+8+16+4+8+4+8+36+1] of byte;
	a[0] = byte 'w';
	o := pl(a, 1, dst);
	o = pl(a, o, dpx);
	o = pl(a, o, dpy);
	o = pr(a, o, r);
	o = pl(a, o, src);
	o = pl(a, o, spx);
	o = pl(a, o, spy);
	o = pl(a, o, src);	# the mask, which a warp does not use
	o = pl(a, o, 0);
	o = pl(a, o, 0);
	for(i := 0; i < 6; i++)
		o = pl(a, o, m[i]);
	o = pl(a, o, 0);
	o = pl(a, o, 0);
	o = pl(a, o, 1<<13);
	a[o] = byte ((flags<<1) | (smooth&1));
	return send(a);
}

# 'r' id[4] R[4*4], then the pixels read back
unload(id: int, r: Rect, n: int): (array of byte, string)
{
	a := array[21] of byte;
	a[0] = byte 'r';
	o := pl(a, 1, id);
	pr(a, o, r);
	if((e := send(a)) != nil)
		return (nil, e);
	buf := array[n] of byte;
	for(got := 0; got < n; ){
		k := sys->read(data, buf[got:], n-got);
		if(k <= 0)
			return (nil, sys->sprint("read back: %r"));
		got += k;
	}
	return (buf, nil);
}

bytesperline(r: Rect, depth: int): int
{
	# rectangles here begin at x >= 0
	return (r.x1*depth+7)/8 - (r.x0*depth)/8;
}

pixels(r: Rect, depth: int, seed: int): array of byte
{
	n := bytesperline(r, depth)*(r.y1-r.y0);
	a := array[n] of byte;
	s := big seed;
	for(i := 0; i < n; i++){
		s = (s*big 1103515245 + big 12345) & big 16rFFFFFFFF;
		a[i] = byte (s>>16);
	}
	return a;
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

hex(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s += sys->sprint("%.2ux", int d[i]);
	return s;
}

sha(a: array of byte): string
{
	d := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(a, len a, d, nil);
	return hex(d);
}

Huge: con 16r3FFFFFFF;
huge := Rect(-Huge, -Huge, Huge, Huge);

# A vector's warp, here: the destination's pixels after it, or an error.
Vec: adt {
	n: int;
	schan: string;
	srepl: int;
	sr: Rect;
	dchan: string;
	dr: Rect;
	fill: int;
	dpx, dpy: int;
	r: Rect;
	spx, spy: int;
	m: array of int;
	flags, smooth: int;
	want: string;
};

parse(line: string): ref Vec
{
	(nf, f) := sys->tokenize(line, " \n");
	if(nf != 31 || hd f != "w")
		return nil;
	a := array[nf] of string;
	for(i := 0; f != nil; f = tl f)
		a[i++] = hd f;
	v := ref Vec;
	v.n = int a[1];
	v.schan = a[2];
	v.srepl = int a[3];
	v.sr = Rect(int a[4], int a[5], int a[6], int a[7]);
	v.dchan = a[8];
	v.dr = Rect(int a[9], int a[10], int a[11], int a[12]);
	(v.fill, nil) = str->toint(a[13], 16);
	v.dpx = int a[14];
	v.dpy = int a[15];
	v.r = Rect(int a[16], int a[17], int a[18], int a[19]);
	v.spx = int a[20];
	v.spy = int a[21];
	v.m = array[6] of int;
	for(i = 0; i < 6; i++)
		v.m[i] = int a[22+i];
	v.flags = int a[28];
	v.smooth = int a[29];
	v.want = a[30];
	return v;
}

# the source as id 1, the destination as dst (on screen scr, 0 for none)
dowarp(v: ref Vec, dst, scr: int): (string, string)
{
	sc := Chans.mk(v.schan);
	dc := Chans.mk(v.dchan);
	clip := v.sr;
	if(v.srepl)
		clip = huge;
	if((e := alloc(1, 0, sc.desc, v.srepl, v.sr, clip, 0)) != nil)
		return (nil, "alloc source: "+e);
	if((e = loadpix(1, v.sr, pixels(v.sr, sc.depth(), v.n))) != nil){
		free(1);
		return (nil, "load source: "+e);
	}
	if(scr == 0 && (e = alloc(dst, 0, dc.desc, 0, v.dr, v.dr, v.fill)) != nil){
		free(1);
		return (nil, "alloc destination: "+e);
	}
	e = warp(dst, v.dpx, v.dpy, v.r, 1, v.spx, v.spy, v.m, v.flags, v.smooth);
	free(1);
	if(e != nil){
		if(scr == 0)
			free(dst);
		return (nil, "warp: "+e);
	}
	(pix, ue) := unload(dst, v.dr, bytesperline(v.dr, dc.depth())*(v.dr.y1-v.dr.y0));
	if(scr == 0)
		free(dst);
	if(ue != nil)
		return (nil, ue);
	lastpix = pix;
	return (sha(pix), nil);
}

vectors(t: ref T): list of ref Vec
{
	b := bufio->open(VECTORS, Bufio->OREAD);
	if(b == nil)
		t.fatal(sys->sprint("%s: %r", VECTORS));
	vl: list of ref Vec;
	while((line := b.gets('\n')) != nil){
		v := parse(line);
		if(v == nil)
			t.fatal("not a vector: "+line);
		vl = v :: vl;
	}
	r: list of ref Vec;
	for(; vl != nil; vl = tl vl)
		r = hd vl :: r;
	return r;
}

alive(t: ref T, what: string)
{
	# the device still allocates, draws and reads back
	r := Rect(0, 0, 4, 4);
	if((e := alloc(99, 0, Chans.mk("x8r8g8b8").desc, 0, r, r, int 16r11223344)) != nil){
		t.fatal(what+": the device no longer allocates: "+e);
		return;
	}
	(pix, ue) := unload(99, r, 64);
	free(99);
	if(ue != nil)
		t.fatal(what+": the device no longer reads back: "+ue);
	else if(int pix[0] != 16r33 || int pix[1] != 16r22 || int pix[2] != 16r11)
		t.fatal(what+": the device no longer fills");
}

testNinefront(t: ref T)
{
	n := 0;
	for(vl := vectors(t); vl != nil; vl = tl vl){
		v := hd vl;
		(got, e) := dowarp(v, 2, 0);
		if(e != nil)
			t.error(sys->sprint("vector %d: %s", v.n, e));
		else if(got != v.want)
			t.error(sys->sprint("vector %d (%s to %s, flags %d smooth %d): pixels %s, 9front's %s",
				v.n, v.schan, v.dchan, v.flags, v.smooth, got, v.want));
		if(got != v.want && lastpix != nil)
			t.log(sys->sprint("vector %d's first bytes: %s", v.n, hex(lastpix[0:min(len lastpix, 128)])));
		n++;
	}
	t.log(sys->sprint("%d of 9front's warps", n));
	t.assert(n >= 37, "every vector read");
}

testWindows(t: ref T)
{
	# a screen over a 64x64 image, a window (20) under another (21)
	big0 := Rect(0, 0, 64, 64);
	one := Rect(0, 0, 1, 1);
	if((e := alloc(10, 0, Chans.mk("x8r8g8b8").desc, 0, big0, big0, int 16r808080FF)) != nil)
		t.fatal("screen image: "+e);
	if((e = alloc(11, 0, Chans.mk("x8r8g8b8").desc, 1, one, huge, int 16r202020FF)) != nil)
		t.fatal("fill: "+e);
	a := array[14] of byte;
	a[0] = byte 'A';
	o := pl(a, 1, 5);
	o = pl(a, o, 10);
	o = pl(a, o, 11);
	a[o] = byte 0;
	if((e = send(a)) != nil)
		t.fatal("screen: "+e);
	checked := 0;
	for(vl := vectors(t); vl != nil; vl = tl vl){
		v := hd vl;
		if(v.dchan != "x8r8g8b8" || v.dr.x0 != 0 || v.dr.y0 != 0)
			continue;
		(want, e1) := dowarp(v, 2, 0);
		if(e1 != nil){
			t.error(sys->sprint("vector %d plain: %s", v.n, e1));
			continue;
		}
		wr := Rect(0, 0, v.dr.x1, v.dr.y1);
		if((e = alloc(20, 5, Chans.mk("x8r8g8b8").desc, 0, wr, wr, v.fill)) != nil)
			t.fatal("window: "+e);
		cover := Rect(v.dr.x1/2, v.dr.y1/2, v.dr.x1/2+30, v.dr.y1/2+30);
		if((e = alloc(21, 5, Chans.mk("x8r8g8b8").desc, 0, cover, cover, int 16rFF0000FF)) != nil)
			t.fatal("covering window: "+e);
		(got, e2) := dowarp(v, 20, 5);
		free(21);
		if(e2 != nil)
			t.error(sys->sprint("vector %d in a window: %s", v.n, e2));
		else if(got != want)
			t.error(sys->sprint("vector %d in a covered window: pixels %s, a plain image's %s", v.n, got, want));
		free(20);
		checked++;
	}
	t.assert(checked >= 10, sys->sprint("%d warps into windows", checked));

	# a window warped onto itself, and from a window over it
	w := Rect(0, 0, 40, 40);
	alloc(20, 5, Chans.mk("x8r8g8b8").desc, 0, w, w, int 16r3366AAFF);
	alloc(21, 5, Chans.mk("x8r8g8b8").desc, 0, Rect(20, 20, 60, 60), Rect(20, 20, 60, 60), int 16rAA3366FF);
	rot := array[] of {7094, -4096, 6*8192, 4096, 7094, -3*8192};
	t.assertnil(warpraw(20, 0, 0, w, 20, 0, 0, rot, 0, 0), "a window onto itself");
	t.assertnil(warpraw(20, 0, 0, w, 21, 20, 20, rot, 0, 1), "from the window over it");
	t.assertnil(warpraw(21, 20, 20, Rect(20, 20, 60, 60), 20, 0, 0, rot, 0, 0), "onto the window over it");
	free(21);
	free(20);
	free(11);
	free(10);
	alive(t, "windows");
}

warpraw(dst, dpx, dpy: int, r: Rect, src, spx, spy: int, m: array of int, flags, smooth: int): string
{
	return warp(dst, dpx, dpy, r, src, spx, spy, m, flags, smooth);
}

testRefused(t: ref T)
{
	r := Rect(0, 0, 8, 8);
	alloc(1, 0, Chans.mk("x8r8g8b8").desc, 0, r, r, int 16rFFFFFFFF);
	alloc(2, 0, Chans.mk("x8r8g8b8").desc, 0, r, r, int 16r000000FF);
	id := array[] of {8192, 0, 0, 0, 8192, 0};

	# a message one byte short
	a := array[1+4+8+16+4+8+4+8+36] of byte;
	a[0] = byte 'w';
	e := send(a);
	t.assert(e != nil && str->prefix("short draw message", e), "short: "+e);

	e = warp(2, 0, 0, r, 77, 0, 0, id, 0, 0);
	t.assert(e != nil, "an unknown source refused: "+e);
	e = warp(77, 0, 0, r, 1, 0, 0, id, 0, 0);
	t.assert(e != nil, "an unknown destination refused: "+e);

	for(i := 0; i < 4; i++){
		m := array[6] of int;
		m[0:] = id;
		k := array[] of {0, 1, 3, 4};
		m[k[i]] = (1<<24) + 1;
		e = warp(2, 0, 0, r, 1, 0, 0, m, 0, 0);
		t.assert(e != nil && str->prefix("warp matrix out of range", e), sys->sprint("matrix entry %d past 2^24: %s", k[i], e));
		m[k[i]] = -(1<<24) - 1;
		e = warp(2, 0, 0, r, 1, 0, 0, m, 0, 0);
		t.assert(e != nil && str->prefix("warp matrix out of range", e), sys->sprint("matrix entry %d below -2^24: %s", k[i], e));
	}
	# the translation may be anything
	m := array[] of {8192, 0, int 16r7FFFFFFF, 0, 8192, int 16r80000000};
	t.assertnil(warp(2, 0, 0, r, 1, 0, 0, m, 0, 0), "a translation at the ends of an int");
	free(1);
	free(2);
	alive(t, "refused");
}

testHostile(t: ref T)
{
	r := Rect(0, 0, 64, 48);
	src := Rect(0, 0, 16, 12);
	alloc(1, 0, Chans.mk("r8g8b8a8").desc, 0, src, src, 0);
	loadpix(1, src, pixels(src, 32, 7));
	alloc(2, 0, Chans.mk("x8r8g8b8").desc, 0, r, r, int 16r336699FF);
	alloc(3, 0, Chans.mk("k1").desc, 0, r, r, int 16rFFFFFFFF);
	alloc(4, 0, Chans.mk("r8g8b8a8").desc, 1, Rect(0, 0, 3, 3), huge, 0);
	loadpix(4, Rect(0, 0, 3, 3), pixels(Rect(0, 0, 3, 3), 32, 9));
	Max: con 1<<24;
	Ext: con int 16r7FFFFFFF;
	Neg: con int 16r80000000;
	ms := array[] of {
		array[] of {Max, Max, Ext, Max, Max, Neg},
		array[] of {-Max, -Max, Neg, -Max, -Max, Ext},
		array[] of {Max, -Max, 0, -Max, Max, 0},
		array[] of {0, 0, 0, 0, 0, 0},
		array[] of {1, 0, 0, 0, 1, 0},
		array[] of {7094, -4096, 0, 4096, 7094, 0},
	};
	pts := array[] of {
		(0, 0), (Ext, Ext), (Neg, Neg), (Ext, Neg), (1<<24, -(1<<24)), (-(1<<24)+1, (1<<24)-1),
	};
	rects := array[] of {
		r, Rect(Neg, Neg, Ext, Ext), Rect(Ext, Ext, Neg, Neg), Rect(10, 10, 10, 30), Rect(-5, -5, 3, 3),
	};
	t0 := sys->millisec();
	n := 0;
	for(mi := 0; mi < len ms; mi++)
	for(pi := 0; pi < len pts; pi++)
	for(ri := 0; ri < len rects; ri++)
	for(si := 0; si < 2; si++){
		(px, py) := pts[pi];
		(qx, qy) := pts[(pi+mi+ri) % len pts];
		for(d := 2; d <= 3; d++){
			# flag 1 claims an upscale whatever the matrix is
			warp(d, px, py, rects[ri], 1, qx, qy, ms[mi], 1, si);
			warp(d, px, py, rects[ri], 4, qx, qy, ms[mi], 0, si);
			n += 2;
		}
	}
	dt := sys->millisec() - t0;
	t.log(sys->sprint("%d hostile warps in %d ms", n, dt));
	t.assert(dt < 60000, sys->sprint("hostile warps answered in time: %d ms", dt));

	# the upscale flag on a matrix that is none draws what the matrix says
	rot := array[] of {7094, -4096, 6*8192, 4096, 7094, -3*8192};
	alloc(5, 0, Chans.mk("x8r8g8b8").desc, 0, r, r, int 16r336699FF);
	alloc(6, 0, Chans.mk("x8r8g8b8").desc, 0, r, r, int 16r336699FF);
	warp(5, 0, 0, r, 1, 0, 0, rot, 1, 0);
	warp(6, 0, 0, r, 1, 0, 0, rot, 0, 0);
	(p5, nil) := unload(5, r, 64*48*4);
	(p6, nil) := unload(6, r, 64*48*4);
	t.assert(p5 != nil && p6 != nil && sha(p5) == sha(p6), "the flag does not change a rotation");
	for(i := 1; i <= 6; i++)
		free(i);
	alive(t, "hostile");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	keyring = load Keyring Keyring->PATH;
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

	sys->pctl(Sys->FORKNS, nil);
	if(sys->bind("#i", "/dev", Sys->MBEFORE) < 0){
		sys->print("no draw device: %r\n");
		testing->summary(0, 0, 1);
		return;
	}
	ctl := sys->open("/dev/draw/new", Sys->ORDWR);
	if(ctl == nil){
		sys->print("no draw device: %r\n");
		testing->summary(0, 0, 1);
		return;
	}
	info := array[12*12] of byte;
	if(sys->read(ctl, info, len info) < 12)
		raise "fail:cannot read /dev/draw/new";
	(nil, f) := sys->tokenize(string info[0:12], " ");
	data = sys->open("/dev/draw/"+hd f+"/data", Sys->ORDWR);
	if(data == nil)
		raise sys->sprint("fail:open data: %r");

	run("Ninefront", testNinefront);
	run("Windows", testWindows);
	run("Refused", testRefused);
	run("Hostile", testHostile);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
