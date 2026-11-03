implement OskFuzz;

#
# oskfuzz [-s seed] [-n actions]: grind wm/osk with random use, through
# /dev/fingers, for tests/host/osk_fuzz_test.sh (not a test itself):
# taps on random keys (letters, symbols, shift, delete, space, enter,
# the layers and layouts), on the suggestions, strokes through random
# letters, two fingers at once, long presses slid to an accent, the
# delete key's stroke, the swipe down and the handle, at random speeds,
# some all at once.  The keys are where /mnt/osk/keys says.  Never the
# more layer's keys (the arrows move the caret, which is the test's
# oracle's business: what osk typed must be what the window holds).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "rand.m";
	rand: Rand;
include "arg.m";

OskFuzz: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Key: adt {
	name:	string;
	x0, y0, x1, y1:	int;
};

fingers: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	rand = load Rand Rand->PATH;
	arg := load Arg Arg->PATH;
	arg->init(args);
	seed := 1;
	n := 400;
	while((c := arg->opt()) != 0)
		case c {
		's' =>	seed = int arg->earg();
		'n' =>	n = int arg->earg();
		* =>	raise "fail:usage: oskfuzz [-s seed] [-n actions]";
		}
	rand->init(seed);
	fingers = sys->open("/dev/fingers", Sys->OWRITE);
	if(fingers == nil)
		raise sys->sprint("fail:/dev/fingers: %r");
	for(i := 0; i < n; i++){
		keys := readkeys();
		if(keys == nil){
			# hidden to its handle (or not yet shown): touch it
			tap(0, 400, 470, 30);
			sys->sleep(300);
			continue;
		}
		if(find(keys, "left") != nil){
			# the more layer: back to the letters
			press(keys, "abc");
			continue;
		}
		r := rand->rand(100);
		if(r < 42)
			press(keys, pickkey(keys));
		else if(r < 50)
			press(keys, "del");
		else if(r < 56)
			press(keys, "space");
		else if(r < 66)
			stroke(keys);
		else if(r < 74)
			rollover(keys);
		else if(r < 79)
			longpress(keys);
		else if(r < 84)
			strip(keys);
		else if(r < 87)
			delstroke(keys);
		else if(r < 89)
			hide(keys);
		else if(r < 92)
			press(keys, "shift");
		else if(r < 94)
			press(keys, "sym");
		else if(r < 96)
			press(keys, "next");
		else if(r < 98)
			press(keys, "enter");
		else
			burst(keys);
	}
	sys->print("oskfuzz: %d actions\n", n);
}

readkeys(): array of Key
{
	fd := sys->open("/mnt/osk/keys", Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	while((m := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:m];
	(nl, lines) := sys->tokenize(s, "\n");
	if(nl == 0)
		return nil;
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
	return a[0:i];
}

find(keys: array of Key, name: string): ref Key
{
	for(i := 0; i < len keys; i++)
		if(keys[i].name == name)
			return ref keys[i];
	return nil;
}

# a key to tap at random: any but the more layer's and the ones that
# move the caret or are not typing (ctrl)
pickkey(keys: array of Key): string
{
	for(;;){
		k := keys[rand->rand(len keys)];
		case k.name {
		"more" or "ctrl" or "esc" or "tab" or "left" or "right" or "up" or "down" or "home" or "end" =>
			continue;
		}
		return k.name;
	}
}

# a key that types and leaves the layer as it is: for the actions of
# several touches aimed from one reading of the keys (a burst, two
# fingers), which a layer changed under them would send elsewhere --
# the more layer's arrows among them
picktyping(keys: array of Key): string
{
	for(;;){
		n := pickkey(keys);
		case n {
		"sym" or "abc" or "next" or "shift" =>
			continue;
		}
		return n;
	}
}

# somewhere in key k, a little off its centre, as a finger lands
inkey(k: ref Key): (int, int)
{
	w := k.x1 - k.x0;
	h := k.y1 - k.y0;
	x := k.x0 + w/2 + (rand->rand(w*6/10+1) - w*3/10);
	y := k.y0 + h/2 + (rand->rand(h*6/10+1) - h*3/10);
	return (x, y);
}

ev(id, x, y, on: int)
{
	sys->fprint(fingers, "f%d %d %d %d", id, x, y, on);
}

tap(id, x, y, ms: int)
{
	ev(id, x, y, 1);
	if(ms > 0)
		sys->sleep(ms);
	ev(id, x, y, 0);
}

pause()
{
	sys->sleep(rand->rand(60));
}

press(keys: array of Key, name: string)
{
	k := find(keys, name);
	if(k == nil)
		return;
	(x, y) := inkey(k);
	tap(0, x, y, rand->rand(40));
	pause();
}

stroke(keys: array of Key)
{
	n := 2 + rand->rand(5);
	pts: list of (int, int);
	for(i := 0; i < n; i++){
		name := "";
		name[0] = 'a' + rand->rand(26);
		k := find(keys, name);
		if(k == nil)
			return;	# not the letters
		pts = inkey(k) :: pts;
	}
	(px, py) := hd pts;
	ev(0, px, py, 1);
	for(pts = tl pts; pts != nil; pts = tl pts){
		(x, y) := hd pts;
		for(j := 1; j <= 6; j++){
			ev(0, px + (x-px)*j/6, py + (y-py)*j/6, 1);
			if(rand->rand(3) == 0)
				sys->sleep(5);
		}
		(px, py) = (x, y);
	}
	ev(0, px, py, 0);
	pause();
}

rollover(keys: array of Key)
{
	a := find(keys, picktyping(keys));
	b := find(keys, picktyping(keys));
	(ax, ay) := inkey(a);
	(bx, by) := inkey(b);
	ev(0, ax, ay, 1);
	ev(1, bx, by, 1);
	if(rand->rand(2))
		ev(0, ax, ay, 0);
	ev(1, bx, by, 0);
	ev(0, ax, ay, 0);	# a second lift of a lifted finger: nothing
	pause();
}

longpress(keys: array of Key)
{
	k := find(keys, "e");
	if(k == nil)
		k = find(keys, picktyping(keys));
	(x, y) := inkey(k);
	ev(0, x, y, 1);
	sys->sleep(600);
	# slide along the accents a little
	ev(0, x + rand->rand(120), y - 40, 1);
	sys->sleep(50);
	ev(0, x + rand->rand(120), y - 40, 0);
	pause();
}

strip(keys: array of Key)
{
	# the suggestions: above the first row
	q := keys[0];
	tap(0, 50 + rand->rand(500), q.y0 - 10, rand->rand(30));
	pause();
}

delstroke(keys: array of Key)
{
	k := find(keys, "del");
	if(k == nil)
		return;
	(x, y) := inkey(k);
	ev(0, x, y, 1);
	for(j := 1; j <= 8; j++)
		ev(0, x - j*25, y, 1);
	ev(0, x - 200, y, 0);
	pause();
}

hide(keys: array of Key)
{
	q := keys[0];
	x := q.x0 + 10;
	y := q.y0 - 8;
	ev(0, x, y, 1);
	ev(0, x, y + 120, 1);
	ev(0, x, y + 120, 0);
	sys->sleep(200);
}

burst(keys: array of Key)
{
	for(i := 0; i < 12; i++){
		k := find(keys, picktyping(keys));
		(x, y) := inkey(k);
		tap(i % 3, x, y, 0);
	}
}
