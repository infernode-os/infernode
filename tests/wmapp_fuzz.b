implement WmappFuzz;

#
# Random input to one window of wm/wm, through /dev/pointer and
# /dev/keyboard: clicks, drags, button 2 and 3, the wheel and typing.
# tools/wm-fuzz runs it against a program, then asks wm to Delete the
# window: what cannot be deleted has frozen.
#
#	wmapp_fuzz [-s seed] [-t secs] x0 y0 x1 y1
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "rand.m";
	rand: Rand;
include "keyboard.m";

WmappFuzz: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

X0, Y0, X1, Y1: int;
ptr, kbd: ref Sys->FD;

keys := array[] of {'\n', 27, 8, '\t', 127, Keyboard->Up, Keyboard->Down,
	Keyboard->Left, Keyboard->Right, Keyboard->Home, Keyboard->End,
	Keyboard->Pgup, Keyboard->Pgdown};

m(x, y, b: int)
{
	sys->fprint(ptr, "m %d %d %d", x, y, b);
}

px(): int
{
	return X0 + rand->rand(X1 - X0);
}

py(): int
{
	return Y0 + rand->rand(Y1 - Y0);
}

click(x, y, b: int)
{
	m(x, y, b);
	sys->sleep(rand->rand(30));
	m(x, y, 0);
}

step()
{
	x := px();
	y := py();
	r := rand->rand(100);
	if(r < 55){		# what a user mostly does
		click(x, y, 1);
		if(rand->rand(4) == 0)
			click(x, y, 1);
	}else if(r < 65){
		x2 := px();
		y2 := py();
		m(x, y, 1);
		m((x + x2) / 2, (y + y2) / 2, 1);
		m(x2, y2, 1);
		m(x2, y2, 0);
	}else if(r < 72)
		click(x, y, 2);
	else if(r < 80){	# a menu: pressed, moved over it, let go
		m(x, y, 4);
		m(x, y + rand->rand(60), 4);
		m(x, y + rand->rand(60), 0);
	}else if(r < 85)
		click(x, y, 8 << rand->rand(2));
	else if(r < 90){
		c := keys[rand->rand(len keys)];
		sys->fprint(kbd, "%c", c);
	}else{
		n := rand->rand(8);
		for(i := 0; i < n; i++)
			sys->fprint(kbd, "%c", 'a' + rand->rand(26));
	}
	sys->sleep(rand->rand(150));
}

windows(): string
{
	fd := sys->open("/chan/wmwindows", Sys->OREAD);
	if(fd == nil)
		return "?";
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	rand = load Rand Rand->PATH;
	seed := sys->millisec();
	secs := 10;
	args = tl args;
	while(args != nil && (hd args)[0] == '-'){
		case hd args {
		"-s" =>
			args = tl args;
			seed = int hd args;
		"-t" =>
			args = tl args;
			secs = int hd args;
		}
		args = tl args;
	}
	X0 = int hd args + 6; args = tl args;	# inside the frame
	Y0 = int hd args + 24; args = tl args;	# below the title bar
	X1 = int hd args - 6; args = tl args;
	Y1 = int hd args - 6;
	rand->init(seed);
	ptr = sys->open("/dev/pointer", Sys->OWRITE);
	kbd = sys->open("/dev/keyboard", Sys->OWRITE);
	if(ptr == nil || kbd == nil){
		sys->fprint(sys->fildes(2), "wmapp_fuzz: cannot open the input: %r\n");
		raise "fail:input";
	}
	end := sys->millisec() + secs * 1000;
	# stops when the window goes (a program's own Exit, clicked): what
	# came next would land on wm's background and open its menus
	while(sys->millisec() < end && windows() != nil)
		step();
	m(X0 + 1, Y0 + 1, 0);
}
