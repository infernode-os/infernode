implement Guifuzz;

#
# Random use of a GUI through the pointer and keyboard (guifuzz.m).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "rand.m";
	rnd: Rand;
include "guifuzz.m";

uitest: ref Sys->FD;
ptrfd, kbdfd: ref Sys->FD;
isbroken := 0;

init(seed: int, ui: int): string
{
	sys = load Sys Sys->PATH;
	rnd = load Rand Rand->PATH;
	if(rnd == nil)
		return sys->sprint("cannot load %s: %r", Rand->PATH);
	rnd->init(seed);
	menureach = 220;
	if(ui){
		uitest = sys->open("/chan/uitest", Sys->OWRITE);
		if(uitest == nil)
			return sys->sprint("no /chan/uitest: %r");
		return nil;
	}
	ptrfd = sys->open("/dev/pointer", Sys->OWRITE);
	if(ptrfd == nil)
		ptrfd = sys->open("#m/pointer", Sys->OWRITE);
	kbdfd = sys->open("/dev/keyboard", Sys->OWRITE);
	if(kbdfd == nil)
		kbdfd = sys->open("#c/keyboard", Sys->OWRITE);
	if(ptrfd == nil || kbdfd == nil)
		return sys->sprint("no pointer or keyboard: %r");
	return nil;
}

TRAIL: con 40;
trailbuf := array[TRAIL] of string;
ntrail := 0;

note(s: string)
{
	trailbuf[ntrail++ % TRAIL] = sys->sprint("%d %s", sys->millisec(), s);
}

trail(): list of string
{
	l: list of string;
	for(i := ntrail - 1; i >= 0 && i >= ntrail - TRAIL; i--)
		l = trailbuf[i % TRAIL] :: l;
	return l;
}

# With menuguard, button 2 or 3 held (a menu open, chosen from where it
# is let go): never on the menu's last item (exit, in most), so a run
# is not ended by chance.  The menu is a window of wm's other than the
# application's (/chan/uitest lists them).
held := 0;

ptr(x, y, b: int)
{
	if(menuguard && uitest != nil){
		if(held & 6)
			(x, y) = offlast(x, y);
		held = b;
	}
	note(sys->sprint("ptr %d %d %d", x, y, b));
	if(uitest != nil)
		sys->fprint(uitest, "ptr %d %d %d", x, y, b);
	else
		sys->fprint(ptrfd, "m %d %d %d", x, y, b);
}

key(r: int)
{
	# a menu open takes keys too: Up to its last item (exit), Enter
	# to choose it.  One held waits; one left open is closed (Esc)
	for(i := 0; menuguard && (held & 6) && i < 100; i++)
		sys->sleep(10);
	if(menuguard && menuopen()){
		note("key 27 (a menu open)");
		sendkey(16r1b);
		sys->sleep(50);
	}
	note(sys->sprint("key %d", r));
	sendkey(r);
}

sendkey(r: int)
{
	if(uitest != nil){
		sys->fprint(uitest, "key %d", r);
		return;
	}
	s := "";
	s[0] = r;
	b := array of byte s;
	sys->write(kbdfd, b, len b);
}

text(s: string)
{
	for(i := 0; i < len s; i++)
		key(s[i]);
}

rand(n: int): int
{
	if(n <= 0)
		return 0;
	return rnd->rand(n);
}

pause()
{
	case rand(5) {
	0 => ;
	1 => sys->sleep(1);
	2 => sys->sleep(rand(10));
	3 => sys->sleep(rand(50));
	* => sys->sleep(rand(150));
	}
}

# Whether a window of the application's other than its own (a menu) is
# open
menuopen(): int
{
	(nil, lines) := sys->tokenize(readfile("/chan/uitest"), "\n");
	for(; lines != nil; lines = tl lines)
		if(hd lines != appwin)
			return 1;
	return 0;
}

# x, y moved off the last item of a menu open, if it is on it
offlast(x, y: int): (int, int)
{
	(nil, lines) := sys->tokenize(readfile("/chan/uitest"), "\n");
	for(; lines != nil; lines = tl lines){
		if(hd lines == appwin)
			continue;
		(n, l) := sys->tokenize(hd lines, " ");
		if(n < 5)
			continue;
		l = tl l;
		mx0 := int hd l; l = tl l;
		my0 := int hd l; l = tl l;
		mx1 := int hd l; l = tl l;
		my1 := int hd l;
		# its last item, and below it in its column (dragged there,
		# Tk's menu chooses the last)
		if(x >= mx0 - 20 && x < mx1 + 20 && y >= my1 - 40){
			y = my1 - 60;
			if(y < my0)
				y = my0 - 20;
		}
	}
	return (x, y);
}

rx(): int
{
	return x0 + rand(x1-x0);
}

ry(): int
{
	return y0 + rand(y1-y0);
}

mouse(seed: int, done: chan of int)
{
	rnd->init(seed);
	while(sys->millisec() < deadline){
		nmouse++;
		x := rx();
		y := ry();
		case rand(13) {
		0 =>	# move
			ptr(x, y, 0);
		1 or 2 =>	# click B1
			ptr(x, y, 1); pause(); ptr(x, y, 0);
		3 =>	# double click B1
			ptr(x, y, 1); ptr(x, y, 0); ptr(x, y, 1); pause(); ptr(x, y, 0);
		4 =>	# B1 drag: a selection
			ptr(x, y, 1);
			for(i := rand(6); i >= 0; i--){
				pause();
				ptr(rx(), ry(), 1);
			}
			ptr(rx(), ry(), 0);
		5 =>	# B2: a click, or dragged (or a menu, chosen from where
			# it is let go)
			ptr(x, y, 2); pause();
			if(b2reach > 0){
				ptr(x + rand(60) - 10, y + rand(b2reach) - 20, 2); pause();
				ptr(x + rand(60) - 10, y + rand(b2reach) - 20, 0);
			}else{
				if(rand(2))
					ptr(rx(), ry(), 2);
				ptr(rx(), ry(), 0);
			}
		6 =>	# B3: a menu, chosen from where it is let go
			ptr(x, y, 4); pause();
			ptr(x + rand(60) - 10, y + rand(menureach) - 20, 4); pause();
			ptr(x + rand(60) - 10, y + rand(menureach) - 20, 0);
		7 =>	# a menu, then a click somewhere
			ptr(x, y, 4); ptr(x, y, 0); pause();
			ptr(rx(), ry(), 1); pause(); ptr(rx(), ry(), 0);
		8 =>	# chords
			ptr(x, y, 1); pause();
			c := 2;
			if(rand(2))
				c = 4;
			ptr(x+rand(30), y, 1|c); pause();
			ptr(x+rand(30), y, 1); pause();
			ptr(x+rand(30), y, 0);
		9 =>	# the wheel
			b := 8;
			if(rand(2))
				b = 16;
			for(i := rand(5); i >= 0; i--){
				ptr(x, y, b);
				ptr(x, y, 0);
			}
		10 =>	# a scroll bar down the left edge
			x = x0 + rand(14);
			b := 1 << rand(3);
			ptr(x, y, b);
			for(i := rand(4); i >= 0; i--){
				pause();
				ptr(x, ry(), b);
			}
			ptr(rx(), ry(), 0);
		11 =>	# pressed, let go off the window
			b := 1 << rand(3);
			ptr(x, y, b); pause();
			ptr(x1 + 5, y1 + 5, b);
			ptr(x1 + 5, y1 + 5, 0);
		12 =>	# buttons mashed
			ptr(x, y, 1+rand(7)); pause();
			ptr(x, y, rand(8));
			ptr(x, y, 0);
		}
		pause();
	}
	ptr((x0+x1)/2, (y0+y1)/2, 0);
	done <-= 1;
}

keys(seed: int, special: array of int, words: array of string, punct: string, done: chan of int)
{
	rnd->init(seed);
	while(sys->millisec() < deadline){
		nkeys++;
		case rand(8) {
		0 or 1 =>
			key(special[rand(len special)]);
		2 =>
			text(words[rand(len words)]);
		* =>
			c := 'a' + rand(26);
			if(rand(8) == 0)
				c = punct[rand(len punct)];
			for(i := 0; i < len nokeys; i++)
				if(c == nokeys[i])
					c = ' ';
			key(c);
		}
		if(rand(10) == 0)
			pause();
	}
	done <-= 1;
}

watch(modname: string)
{
	pid := apppid(modname);
	gone := 0;
	while(sys->millisec() < deadline){
		sys->sleep(250);
		if(broken())
			deadline = 0;
		else if(pid > 0 && sys->open("/prog/" + string pid + "/status", Sys->OREAD) != nil)
			gone = 0;
		else if(pid <= 0 && (pid = apppid(modname)) > 0)
			gone = 0;
		else if(++gone >= 2){
			exited = 1;
			deadline = 0;
		}
	}
}

# The application's first proc (the one that ran its init, the
# lowest pid of those running its module): the application is gone
# when it is.  By the module a proc is in now, the last word of its
# status, or a frame of its stack in modname's .dis (it may be in a
# library it calls, as wm/page in sheetview).
apppid(modname: string): int
{
	dis := "/" + lower(modname) + ".dis";
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	low := -1;
	for(;;){
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++){
			pid := int d[i].name;
			if(low > 0 && pid >= low)
				continue;
			p := "/prog/" + d[i].name;
			(nil, l) := sys->tokenize(readfile(p + "/status"), " ");
			for(; l != nil && tl l != nil; l = tl l)
				;
			if(l != nil && (hd l == modname || hd l == modname+"[$Sys]" || hd l == modname+"[$Tk]" || hd l == modname+"[$Draw]")){
				low = pid;
				continue;
			}
			if(contains(readfile(p + "/stack"), dis))
				low = pid;
		}
	}
	return low;
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

broken(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return 0;
	for(;;){
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++){
			st := readfile("/prog/"+d[i].name+"/status");
			if(st != nil && contains(st, "broken")){
				if(!isbroken){
					sys->print("fuzz: BROKEN %s\n", st);
					sys->print("%s\n", readfile("/prog/"+d[i].name+"/stack"));
				}
				isbroken = 1;
			}
		}
	}
	return isbroken;
}

dumpprocs()
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return;
	for(;;){
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd; i++){
			p := "/prog/"+d[i].name;
			st := readfile(p+"/status");
			sys->print("PROC %s\n", st);
			if(contains(st, "ready")){
				# a spinning prog's stack can be read only stopped
				dfd := sys->open(p+"/dbgctl", Sys->ORDWR);
				if(dfd != nil && sys->fprint(dfd, "step 1") >= 0)
					sys->print("%s\n", readfile(p+"/stack"));
			}else
				sys->print("%s\n", readfile(p+"/stack"));
		}
	}
}

timeout(ms: int): chan of int
{
	c := chan of int;
	spawn timer(c, ms);
	return c;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	nb := 0;
	for(;;){
		if(nb == len buf){
			b := array[2 * len buf] of byte;
			b[0:] = buf;
			buf = b;
		}
		n := sys->read(fd, buf[nb:], len buf - nb);
		if(n <= 0)
			break;
		nb += n;
	}
	return string buf[0:nb];
}

writefile(f, s: string): int
{
	fd := sys->open(f, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte s;
	return sys->write(fd, b, len b);
}

contains(s, t: string): int
{
	n := len t;
	for(i := 0; i+n <= len s; i++){
		for(j := 0; j < n && s[i+j] == t[j]; j++)
			;
		if(j == n)
			return 1;
	}
	return 0;
}

halt()
{
	fd := sys->open("#c/sysctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "halt");
}
