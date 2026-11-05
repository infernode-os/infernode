implement PhoneFuzz;

#
# phonefuzz [-s seed] [-n actions] [-c every] -w width -h height: grind
# Lucifer's phone layout (boot-mobile.sh) with random use, for
# tests/host/phone_fuzz_test.sh (not a test itself).  Every touch is a
# finger and the pointer's press made from it, as SDL reports one on a
# phone: taps on the accordion's titles and anywhere, the chat's field,
# the keyboard on the screen's keys, strokes through its letters, delete,
# its hide icon and its handle, two fingers at once, drags; a keyboard
# attached and detached.  Every `every' actions it lets the screen
# settle and keeps a checkpoint: the screen in /tmp/cp.N.img, osk's
# status and keys in /tmp/cp.N.status and /tmp/cp.N.keys, a line
# "C N" on its output.  Enter is never pressed: what it sends would be
# a model's business.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "rand.m";
	rand: Rand;
include "arg.m";
include "sh.m";

PhoneFuzz: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Key: adt {
	name:	string;
	x0, y0, x1, y1:	int;
};

fingers, pointer: ref Sys->FD;
W := 0;
H := 0;
HEADER: con 133;	# Lucifer's phone header (MOBILE_HEADERH + 1)
TITLE: con 132;		# an accordion title bar (MOBILE_TITLEBARH)
attached := 0;

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	rand = load Rand Rand->PATH;
	arg := load Arg Arg->PATH;
	arg->init(args);
	seed := 1;
	n := 300;
	every := 30;
	while((c := arg->opt()) != 0)
		case c {
		's' =>	seed = int arg->earg();
		'n' =>	n = int arg->earg();
		'c' =>	every = int arg->earg();
		'w' =>	W = int arg->earg();
		'h' =>	H = int arg->earg();
		* =>	raise "fail:usage: phonefuzz [-s seed] [-n actions] [-c every] -w width -h height";
		}
	if(W <= 0 || H <= 0)
		raise "fail:usage: the screen's -w and -h";
	rand->init(seed);
	fingers = sys->open("/dev/fingers", Sys->OWRITE);
	pointer = sys->open("/dev/pointer", Sys->OWRITE);
	if(fingers == nil || pointer == nil)
		raise sys->sprint("fail:/dev/fingers or /dev/pointer: %r");
	cp := 0;
	for(i := 0; i < n; i++){
		act();
		if((i+1) % every == 0 || i == n-1)
			checkpoint(ctxt, cp++);
	}
	if(attached)
		consctl("kbd detach fz0");
	sys->print("phonefuzz: %d actions, %d checkpoints\n", n, cp);
}

act()
{
	# a keyboard attached is put away again soon: while it is, osk
	# stays hidden and most of the rest has nothing to touch
	if(attached && rand->rand(4) == 0){
		keyboard();
		return;
	}
	keys := readkeys();
	r := rand->rand(100);
	if(r < 10)
		titletap();
	else if(r < 20)
		fieldtap(keys);
	else if(keys == nil){
		if(r < 60)
			fieldtap(keys);
		else if(r < 75)
			tap(rand->rand(W), HEADER + rand->rand(H - HEADER));
		else if(r < 85)
			drag();
		else if(r < 90)
			handletap();
		else
			keyboard();
	}else if(r < 55)
		press(keys, pickletter(keys));
	else if(r < 62)
		press(keys, "space");
	else if(r < 68)
		press(keys, "del");
	else if(r < 76)
		stroke(keys);
	else if(r < 80)
		rollover(keys);
	else if(r < 84)
		hideicon(keys);
	else if(r < 88)
		press(keys, "shift");
	else if(r < 92)
		tap(rand->rand(W), HEADER + rand->rand(H - HEADER));
	else if(r < 95)
		drag();
	else
		keyboard();
	sys->sleep(rand->rand(80));
}

# a touch: the finger, and the pointer's press SDL makes from it
ev(id, x, y, on: int)
{
	sys->fprint(fingers, "f%d %d %d %d", id, x, y, on);
	if(id == 0)
		sys->fprint(pointer, "m %d %d %d", x, y, on);
}

tap(x, y: int)
{
	ev(0, x, y, 1);
	sys->sleep(rand->rand(60));
	ev(0, x, y, 0);
}

# one of the three title bars, wherever the accordion has put them
titletap()
{
	ys := array[] of {
		HEADER + TITLE/2,
		HEADER + TITLE + TITLE/2,
		HEADER + 2*TITLE + TITLE/2,
		H - TITLE/2,
		H - TITLE - TITLE/2,
	};
	tap(W/4 + rand->rand(W/2), ys[rand->rand(len ys)]);
}

# the chat's field, along the bottom (above the keyboard when it shows)
fieldtap(keys: array of Key)
{
	y := H - 50;
	if(keys != nil)
		y = keys[0].y0 - 150;
	tap(W/3, y);
}

handletap()
{
	tap(W/2, H - 10);
}

hideicon(keys: array of Key)
{
	tap(W - 60, keys[0].y0 - 20);
}

drag()
{
	x := rand->rand(W);
	y := HEADER + rand->rand(H - HEADER);
	dx := rand->rand(401) - 200;
	dy := rand->rand(801) - 400;
	ev(0, x, y, 1);
	for(j := 1; j <= 8; j++)
		ev(0, x + dx*j/8, y + dy*j/8, 1);
	ev(0, x + dx, y + dy, 0);
}

keyboard()
{
	if(attached)
		consctl("kbd detach fz0");
	else
		consctl("kbd attach fz0 Fuzz Keyboard");
	attached = !attached;
}

consctl(s: string)
{
	fd := sys->open("/dev/consctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

readkeys(): array of Key
{
	st := readfile("/mnt/osk/status");
	if(st == nil || !hasline(st, "state shown"))
		return nil;
	s := readfile("/mnt/osk/keys");
	(nl, lines) := sys->tokenize(s, "\n");
	a := array[nl] of Key;
	i := 0;
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " ");
		if(nf != 5)
			continue;
		a[i].name = hd f; f = tl f;
		a[i].x0 = int hd f; f = tl f;
		a[i].y0 = int hd f; f = tl f;
		a[i].x1 = int hd f; f = tl f;
		a[i].y1 = int hd f;
		i++;
	}
	if(i == 0)
		return nil;
	return a[0:i];
}

hasline(s, l: string): int
{
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines)
		if(hd lines == l || len hd lines > len l && (hd lines)[0:len l+1] == l + " ")
			return 1;
	return 0;
}

readfile(name: string): string
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((m := sys->read(fd, buf, len buf)) > 0){
		s += string buf[0:m];
		if(len s > 65536)
			break;
	}
	return s;
}

find(keys: array of Key, name: string): ref Key
{
	for(i := 0; i < len keys; i++)
		if(keys[i].name == name)
			return ref keys[i];
	return nil;
}

pickletter(keys: array of Key): string
{
	for(j := 0; j < 20; j++){
		k := keys[rand->rand(len keys)];
		if(len k.name == 1)
			return k.name;
	}
	return "a";
}

inkey(k: ref Key): (int, int)
{
	w := k.x1 - k.x0;
	h := k.y1 - k.y0;
	return (k.x0 + w/2 + (rand->rand(w*6/10+1) - w*3/10),
		k.y0 + h/2 + (rand->rand(h*6/10+1) - h*3/10));
}

press(keys: array of Key, name: string)
{
	k := find(keys, name);
	if(k == nil)
		return;
	(x, y) := inkey(k);
	tap(x, y);
}

stroke(keys: array of Key)
{
	n := 2 + rand->rand(4);
	pts: list of (int, int);
	for(i := 0; i < n; i++){
		k := find(keys, pickletter(keys));
		if(k == nil)
			return;
		pts = inkey(k) :: pts;
	}
	(px, py) := hd pts;
	ev(0, px, py, 1);
	for(pts = tl pts; pts != nil; pts = tl pts){
		(x, y) := hd pts;
		for(j := 1; j <= 6; j++)
			ev(0, px + (x-px)*j/6, py + (y-py)*j/6, 1);
		(px, py) = (x, y);
	}
	ev(0, px, py, 0);
}

rollover(keys: array of Key)
{
	a := find(keys, pickletter(keys));
	b := find(keys, pickletter(keys));
	if(a == nil || b == nil)
		return;
	(ax, ay) := inkey(a);
	(bx, by) := inkey(b);
	ev(0, ax, ay, 1);
	ev(1, bx, by, 1);
	ev(0, ax, ay, 0);
	ev(1, bx, by, 0);
}

# the screen settled, kept with what osk says of itself
checkpoint(ctxt: ref Draw->Context, n: int)
{
	sys->sleep(2500);
	copy("/mnt/osk/status", sys->sprint("/tmp/cp.%d.status", n));
	copy("/mnt/osk/keys", sys->sprint("/tmp/cp.%d.keys", n));
	scap := load Command "/dis/scap.dis";
	if(scap != nil)
		scap->init(ctxt, "scap" :: sys->sprint("/tmp/cp.%d.img", n) :: nil);
	sys->print("C %d\n", n);
}

copy(src, dst: string)
{
	s := readfile(src);
	fd := sys->create(dst, Sys->OWRITE, 8r644);
	if(fd != nil && s != nil)
		sys->fprint(fd, "%s", s);
}
