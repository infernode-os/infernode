implement Camtest;

#
# The camera device, #V (os/port/devcam.c), against its simulated
# sensor (os/port/campattern.c): what infernode-os/infernode#1005 says
# the files do.
#
#	the settings in ctl, as written and as refused
#	modes
#	frame: an image(6) header and size; the eight bars' colours after
#	  debayering, at both row and column parities and at both edges;
#	  the grey band, and that it moved between two opens
#	raw: its size and the Bayer samples under three bars
#	pacing: ten opens at 10 fps take nine frame times or more, by #x
#	opens refused once the stream is off
#
# One line a check, "camtest: ok ..." or "camtest: FAIL ...", then
# "camtest: PASS n" or "camtest: FAILED k of n". Leaves the camera
# off and in its boot settings.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Camtest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

CTL: con "/dev/camera/ctl";
W: con 640;
H: con 480;
HDR: con 60;

nok := 0;
nfail := 0;

# what the pattern is, from campattern.c: red, green, blue on or off
bars := array[] of {
	(1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0),
	(1, 0, 1), (1, 0, 0), (0, 0, 1), (0, 0, 0),
};

ok(what: string)
{
	nok++;
	sys->print("camtest: ok %s\n", what);
}

fail(what: string)
{
	nfail++;
	sys->print("camtest: FAIL %s\n", what);
}

check(c: int, what: string)
{
	if(c)
		ok(what);
	else
		fail(what);
}

readall(name: string): (array of byte, string)
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%r"));
	b := array[0] of byte;
	buf := array[Sys->ATOMICIO] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return (nil, sys->sprint("%r"));
		if(n == 0)
			break;
		nb := array[len b + n] of byte;
		nb[0:] = b;
		nb[len b:] = buf[0:n];
		b = nb;
	}
	return (b, nil);
}

ctl(): string
{
	(b, err) := readall(CTL);
	if(b == nil)
		return "error " + err;
	return string b;
}

# write one setting; nil if accepted, the error if not
set(s: string): string
{
	fd := sys->open(CTL, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%r");
	if(sys->fprint(fd, "%s", s) < 0)
		return sys->sprint("%r");
	return nil;
}

has(s, line: string): int
{
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l)
		if(hd l == line)
			return 1;
	return 0;
}

refused(s: string)
{
	err := set(s);
	check(err != nil, sys->sprint("'%s' refused (%s)", s, err));
}

# a pixel of a frame: (r, g, b)
pixel(f: array of byte, x, y: int): (int, int, int)
{
	o := HDR + (y*W + x)*3;
	return (int f[o+2], int f[o+1], int f[o]);
}

# the first row in column x (in the white bar) that is the band's grey
band(f: array of byte): int
{
	for(y := 0; y < H; y++){
		(r, g, b) := pixel(f, 40, y);
		if(r == 128 && g == 128 && b == 128)
			return y;
	}
	return -1;
}

frame(): (array of byte, string)
{
	return readall("/dev/camera/frame");
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;

	s := ctl();
	check(has(s, "source test") && has(s, "mode 640 480") && has(s, "fps 30")
		&& has(s, "stream off") && has(s, "raw rggb10") && has(s, "frames 0"),
		"ctl at boot: " + flat(s));

	(m, nil) := readall("/dev/camera/modes");
	check(m != nil && has(string m, "test 2304 1296 56 rggb10") && has(string m, "test 1536 864 120 rggb10")
		&& has(string m, "test 640 480 60 rggb10"), "modes: " + flat(string m));

	(f, err) := frame();
	check(f == nil && contains(err, "not streaming"), "frame refused while not streaming (" + err + ")");

	refused("mode 641 480");
	refused("fps 0");
	refused("fps 61");
	refused("source nosuch");
	refused("stream maybe");
	refused("zoom 2");

	check(set("fps 60") == nil && has(ctl(), "fps 60"), "fps 60 at 640x480");
	check(set("mode 2304 1296") == nil && has(ctl(), "mode 2304 1296") && has(ctl(), "fps 56"),
		"mode 2304 1296 lowers fps 60 to the mode's 56");
	check(set("mode 640 480") == nil && set("fps 30") == nil && has(ctl(), "mode 640 480") && has(ctl(), "fps 30"),
		"mode 640 480 and fps 30 again");

	check(set("stream on") == nil && has(ctl(), "stream on"), "stream on");
	refused("mode 1536 864");
	check(set("stream on") == nil, "stream on again is accepted");

	(f, err) = frame();
	if(f == nil){
		fail("frame: " + err);
		finish();
		return;
	}
	check(len f == HDR + W*H*3, sys->sprint("frame is %d bytes, header and 640x480x3", len f));
	(nt, hdr) := sys->tokenize(string f[0:HDR], " ");
	check(nt == 5 && hd hdr == "r8g8b8" && int hd tl hdr == 0 && int hd tl tl hdr == 0
		&& int hd tl tl tl hdr == W && int hd tl tl tl tl hdr == H,
		"frame header: " + string f[0:HDR]);

	b1 := band(f);
	check(b1 >= 0, sys->sprint("the grey band is in the frame (row %d)", b1));
	# a row clear of the band, then its neighbour: both row parities
	y := 400;
	if(b1 > 240)
		y = 100;
	bad := "";
	for(k := 0; k < 8; k++){
		(wr, wg, wb) := bars[k];
		for(dy := 0; dy < 2; dy++)
			for(dx := 0; dx < 2; dx++){
				(r, g, b) := pixel(f, 40 + 80*k + dx, y + dy);
				if(r != 255*wr || g != 255*wg || b != 255*wb)
					bad += sys->sprint(" bar%d(%d,%d)=%d,%d,%d", k, 40+80*k+dx, y+dy, r, g, b);
			}
	}
	check(bad == "", "the eight bars' colours after debayering" + bad);
	(r0, g0, bl0) := pixel(f, 0, y);
	(r1, g1, bl1) := pixel(f, W-1, y+1);
	check(r0 == 255 && g0 == 255 && bl0 == 255 && r1 == 0 && g1 == 0 && bl1 == 0,
		sys->sprint("the left and right edges: %d,%d,%d and %d,%d,%d", r0, g0, bl0, r1, g1, bl1));

	(f, err) = frame();
	if(f == nil)
		fail("second frame: " + err);
	else{
		b2 := band(f);
		check(b2 >= 0 && b2 != b1, sys->sprint("the band moved between two opens (row %d, then %d)", b1, b2));
	}

	(raw, rerr) := readall("/dev/camera/raw");
	if(raw == nil)
		fail("raw: " + rerr);
	else{
		check(len raw == W*H*2, sys->sprint("raw is %d bytes, 640x480x2", len raw));
		# the band again, in raw: a grey sample is 512
		ry := 400;
		for(yy := 0; yy < H; yy++)
			if(rawat(raw, 40, yy) == 512){
				if(yy > 240)
					ry = 100;
				break;
			}
		# R at even row and column, G beside it and below it, B diagonal
		bad = "";
		for(k = 0; k < 8; k += 5){	# white, red
			(wr, wg, wb) := bars[k];
			x := 40 + 80*k;
			if(rawat(raw, x, ry) != 1023*wr || rawat(raw, x+1, ry) != 1023*wg
			|| rawat(raw, x, ry+1) != 1023*wg || rawat(raw, x+1, ry+1) != 1023*wb)
				bad += sys->sprint(" bar%d: %d %d %d %d", k, rawat(raw, x, ry), rawat(raw, x+1, ry),
					rawat(raw, x, ry+1), rawat(raw, x+1, ry+1));
		}
		x := 40 + 80*6;	# blue
		if(rawat(raw, x, ry) != 0 || rawat(raw, x+1, ry+1) != 1023)
			bad += sys->sprint(" bar6: %d %d", rawat(raw, x, ry), rawat(raw, x+1, ry+1));
		check(bad == "", "raw is RGGB, 10 bits in 16, little-endian" + bad);
	}

	# pacing: each open waits for the next frame, so ten at 10 fps
	# take at least nine frame times whatever the machine's speed.
	# Timed by #x/busec, the processor's counter, which is the clock
	# the sensor keeps: sys->millisec counts the scheduler's ticks,
	# and an emulator on a busy host drops them (it read 714 ms here
	# where the counter read a second).
	set("stream off");
	set("fps 10");
	set("stream on");
	t0 := usec();
	n := 0;
	for(i := 0; i < 10; i++){
		fd := sys->open("/dev/camera/raw", Sys->OREAD);
		if(fd != nil)
			n++;
	}
	dt := (usec() - t0) / big 1000;
	check(n == 10 && t0 > big 0 && dt >= big 850, sys->sprint("ten opens at 10 fps took %bd ms (at least 850)", dt));
	s = ctl();
	check(has(s, "fps 10") && !has(s, "frames 0"), "frames counted while streaming: " + flat(s));

	check(set("stream off") == nil && has(ctl(), "stream off"), "stream off");
	(f, err) = frame();
	check(f == nil && contains(err, "not streaming"), "frame refused after stream off (" + err + ")");
	set("fps 30");

	finish();
}

# microseconds by the processor's counter, or -1
usec(): big
{
	(b, nil) := readall("#x/busec");
	if(b == nil)
		return big -1;
	return big string b;
}

rawat(raw: array of byte, x, y: int): int
{
	o := (y*W + x)*2;
	return int raw[o] | int raw[o+1] << 8;
}

finish()
{
	set("stream off");
	if(nfail == 0)
		sys->print("camtest: PASS %d\n", nok);
	else
		sys->print("camtest: FAILED %d of %d\n", nfail, nok + nfail);
}

flat(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			r += "; ";
		else
			r[len r] = s[i];
	return r;
}

contains(s, t: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}
