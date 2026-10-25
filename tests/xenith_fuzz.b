implement XenithFuzz;

#
# Random use of a running Xenith, to grind out what freezes it, takes it
# down or loses work: clicks, drags, chords, the wheel, scroll bars and
# typing through #m/pointer and #c/keyboard, while a client changes its
# windows through /mnt/xenith at the same time, as an agent does.
#
# Run where /mnt/xenith is (Xenith's own commands see it); the driver,
# tools/xenith-fuzz, starts a Xenith that runs it. After the input stops
# it checks that Xenith still answers, that each window's text reads back
# as long as its index says, that Put writes what a window holds, and
# that undo and redo take a window's text back and forth exactly; then it
# halts the emulator (unless -n).
#
#	xenith_fuzz [-s seed] [-t secs] [-w wins] [-d dir] [-R x0 y0 x1 y1]
#		[-m] [-k] [-a] [-n]
#
#	-s	seed (default the time)
#	-t	seconds of input (30)
#	-w	windows made at the start (4)
#	-d	the directory its files are made in (/tmp/xenith-fuzz)
#	-R	the screen rectangle clicked in (default the screen below the
#		row's tag, so its Exit is not)
#	-m -k -a	mouse, keys, client alone (default all three)
#	-n	do not halt the emulator at the end
#
# It prints lines beginning "fuzz:"; the outcome lines are RESPONSIVE,
# HUNG, BROKEN (a Xenith proc died), STUCK (the input threads did not
# finish), DATA (an integrity check failed) and INTEGRITY ok. On HUNG it
# prints every proc's stack (a spinning one's only if the emulator lets
# its dbgctl be opened).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "rand.m";
	rand: Rand;

XenithFuzz: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

X: con "/mnt/xenith";

W, H: int;
X0 := 0;
Y0 := 20;
X1 := -1;
Y1 := -1;
dir := "/tmp/xenith-fuzz";
deadline: int;
stop := 0;
halt := 1;
ptrfd, kbdfd: ref Sys->FD;
nact := array[3] of {* => 0};
words: array of string;

# what is clicked and typed: commands, file names, words to look at
basewords := array[] of {
	"Del", "Zerox", "Undo", "Redo", "Snarf", "Paste", "Cut", "Look", "Get",
	"Put", "New", "Sort", "Newcol", "Delcol", "Send", "Indent", "Tab",
	"Edit ,x/a/c/b/", "Edit ,d", "Edit 1,3p", "|tr a-z A-Z", "<echo hi",
	">wc", "echo hello", "seq 1 40", "date",
	"foo", "bar", "baz", "(paren)", "[brack]", "{brace}",
	"Look foo", "Live", "Render", "Font", "ID", "Lineno", "Incl",
	"Kill date",
};

# in the work directory: its files, some documents
dirwords := array[] of {
	"", "/f1", "/f2", "/f3", "/f1:3", "/fbig", "/fbig:100", "/doc.md",
	"/three.pdf", "/rb.png",
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	rand = load Rand Rand->PATH;
	seed := sys->millisec();
	secs := 30;
	domouse := dokeys := doagent := 1;
	nwin := 4;
	args = tl args;
	only := 0;
	while(args != nil){
		a := hd args;
		args = tl args;
		case a {
		"-s" => seed = int hd args; args = tl args;
		"-t" => secs = int hd args; args = tl args;
		"-w" => nwin = int hd args; args = tl args;
		"-d" => dir = hd args; args = tl args;
		"-n" => halt = 0;
		"-R" =>
			X0 = int hd args; args = tl args;
			Y0 = int hd args; args = tl args;
			X1 = int hd args; args = tl args;
			Y1 = int hd args; args = tl args;
		"-m" or "-k" or "-a" =>
			if(!only){
				domouse = dokeys = doagent = 0;
				only = 1;
			}
			case a {
			"-m" => domouse = 1;
			"-k" => dokeys = 1;
			"-a" => doagent = 1;
			}
		}
	}
	rand->init(seed);
	sys->pctl(Sys->NEWPGRP, nil);	# outlive Xenith killing its commands
	sys->print("fuzz: seed %d secs %d\n", seed, secs);
	words = array[len basewords + len dirwords] of string;
	words[0:] = basewords;
	for(i := 0; i < len dirwords; i++)
		words[len basewords + i] = dir + dirwords[i];
	(W, H) = screensize();
	if(X1 < 0)
		X1 = W;
	if(Y1 < 0)
		Y1 = H;
	ptrfd = sys->open("/dev/pointer", Sys->OWRITE);
	if(ptrfd == nil)
		ptrfd = sys->open("#m/pointer", Sys->OWRITE);
	kbdfd = sys->open("/dev/keyboard", Sys->OWRITE);
	if(kbdfd == nil)
		kbdfd = sys->open("#c/keyboard", Sys->OWRITE);
	if(ptrfd == nil || kbdfd == nil){
		sys->print("fuzz: no pointer or keyboard: %r\n");
		return;
	}
	setup(nwin);
	deadline = sys->millisec() + secs*1000;
	done := chan of int;
	n := 0;
	if(domouse){
		spawn mousefuzz(rand->rand(1<<30), done);
		n++;
	}
	if(dokeys){
		spawn keyfuzz(rand->rand(1<<30), done);
		n++;
	}
	if(doagent){
		spawn agentfuzz(rand->rand(1<<30), done);
		n++;
	}
	spawn watcher();
	while(n > 0){
		alt{
		<-done =>
			n--;
		<-timeout(2000) =>
			if(sys->millisec() > deadline + 4000){
				sys->print("fuzz: STUCK: %d input threads did not finish (mouse %d keys %d client %d)\n",
					n, nact[0], nact[1], nact[2]);
				n = 0;
			}
		}
	}
	stop = 1;
	ptr(W/2, H/2, 0);
	sys->print("fuzz: done mouse %d keys %d client %d\n", nact[0], nact[1], nact[2]);
	sys->sleep(1000);
	if(health())
		integrity();
	if(halt){
		fd := sys->open("#c/sysctl", Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "halt");
	}
}

# stop the run when one of Xenith's procs breaks
watcher()
{
	while(sys->millisec() < deadline && !stop){
		sys->sleep(250);
		(d, n) := readdir("/prog");
		for(i := 0; i < n; i++){
			st := xread("/prog/"+d[i]+"/status");
			if(st != nil && contains(st, "broken")){
				sys->print("fuzz: BROKEN %s\n", st);
				deadline = 0;
			}
		}
	}
}

contains(s, t: string): int
{
	return index(s, t) >= 0;
}

index(s, t: string): int
{
	for(i := 0; i+len t <= len s; i++)
		if(s[i:i+len t] == t)
			return i;
	return -1;
}

readdir(p: string): (array of string, int)
{
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return (nil, 0);
	a := array[1024] of string;
	n := 0;
	for(;;){
		(nd, d) := sys->dirread(fd);
		if(nd <= 0)
			break;
		for(i := 0; i < nd && n < len a; i++)
			a[n++] = d[i].name;
	}
	return (a, n);
}

# Xenith answers a request that needs its row; then its +Errors windows
health(): int
{
	c := chan of string;
	spawn probe(c);
	alt{
	s := <-c =>
		(nw, nil) := sys->tokenize(s, "\n");
		sys->print("fuzz: RESPONSIVE (%d windows)\n", nw);
	<-timeout(5000) =>
		sys->print("fuzz: HUNG: %s/index did not answer in 5s\n", X);
		dumpprocs();
		return 0;
	}
	for(l := windows(); l != nil; l = tl l){
		w := hd l;
		if(contains(w.name, "+Errors")){
			sys->print("fuzz: ERRORS %s:\n", w.name);
			sys->print("%s\n", xread(X+"/"+w.id+"/body"));
		}
	}
	return 1;
}

dumpprocs()
{
	(d, n) := readdir("/prog");
	for(i := 0; i < n; i++){
		st := xread("/prog/"+d[i]+"/status");
		sys->print("PROC %s\n", st);
		if(contains(st, "ready")){
			# a spinning prog's stack can be read only stopped
			dfd := sys->open("/prog/"+d[i]+"/dbgctl", Sys->ORDWR);
			if(dfd != nil && sys->fprint(dfd, "step 1") >= 0)
				sys->print("%s\n", xread("/prog/"+d[i]+"/stack"));
		}else
			sys->print("%s\n", xread("/prog/"+d[i]+"/stack"));
	}
}

probe(c: chan of string)
{
	c <-= xread(X+"/index");
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

screensize(): (int, int)
{
	fd := sys->open("/dev/draw/new", Sys->OREAD);
	if(fd != nil){
		b := array[12*12] of byte;
		n := sys->read(fd, b, len b);
		if(n >= 12*12){
			(nil, l) := sys->tokenize(string b[0:n], " ");
			a := array[12] of string;
			for(i := 0; i < 12 && l != nil; i++){
				a[i] = hd l;
				l = tl l;
			}
			return (int a[8] - int a[6], int a[9] - int a[7]);
		}
	}
	return (800, 600);
}

xwrite(f, s: string): int
{
	fd := sys->open(f, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte s;
	return sys->write(fd, b, len b);
}

xread(f: string): string
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

copybytes(src, dst: string)
{
	in := sys->open(src, Sys->OREAD);
	out := sys->create(dst, Sys->OWRITE, 8r666);
	if(in == nil || out == nil)
		return;
	b := array[8192] of byte;
	while((n := sys->read(in, b, len b)) > 0)
		sys->write(out, b, n);
}

newwin(): string
{
	fd := sys->open(X+"/new/ctl", Sys->ORDWR);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	(nil, l) := sys->tokenize(string b[0:n], " ");
	if(l == nil)
		return nil;
	return hd l;
}

randtext(r: int): string
{
	s := "";
	for(i := 0; i < r; i++){
		s += words[rand->rand(len words)];
		case rand->rand(4) {
		0 => s += "\n";
		1 => s += "\t";
		* => s += " ";
		}
	}
	return s + "\n";
}

setup(nwin: int)
{
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r777);
	for(i := 1; i <= 3; i++){
		fd := sys->create(dir+"/f"+string i, Sys->OWRITE, 8r666);
		b := array of byte randtext(80);
		if(fd != nil)
			sys->write(fd, b, len b);
	}
	# over 10K: read in the background
	fd := sys->create(dir+"/fbig", Sys->OWRITE, 8r666);
	if(fd != nil){
		b := array of byte randtext(40);
		for(k := 0; k < 300; k++)
			sys->write(fd, b, len b);
		fd = nil;
	}
	fd = sys->create(dir+"/doc.md", Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "# A heading\n\nSome *text*, a [link](%s/f1) and a list:\n\n- one\n- two\n\n```\ncode\n```\n", dir);
	fd = nil;
	copybytes("/tests/page/three.pdf", dir+"/three.pdf");
	copybytes("/tests/imgload/rb.png", dir+"/rb.png");
	for(i = 0; i < nwin; i++){
		id := newwin();
		if(id == nil)
			continue;
		if(i < 3){
			xwrite(X+"/"+id+"/ctl", "name "+dir+"/f"+string (i+1));
			xwrite(X+"/"+id+"/ctl", "get");
		}else{
			xwrite(X+"/"+id+"/ctl", "name "+dir+"/scratch"+string i);
			xwrite(X+"/"+id+"/body", randtext(60));
		}
	}
}

ptr(x, y, b: int)
{
	sys->fprint(ptrfd, "m %d %d %d", x, y, b);
}

key(r: int)
{
	s := "";
	s[0] = r;
	b := array of byte s;
	sys->write(kbdfd, b, len b);
}

pause()
{
	case rand->rand(5) {
	0 => ;
	1 => sys->sleep(1);
	2 => sys->sleep(rand->rand(10));
	3 => sys->sleep(rand->rand(50));
	* => sys->sleep(rand->rand(150));
	}
}

rx(): int
{
	return X0 + rand->rand(X1-X0);
}

ry(): int
{
	return Y0 + rand->rand(Y1-Y0);
}

mousefuzz(seed: int, done: chan of int)
{
	rand->init(seed);
	while(sys->millisec() < deadline){
		nact[0]++;
		x := rx();
		y := ry();
		case rand->rand(14) {
		0 =>	# move
			ptr(x, y, 0);
		1 or 2 =>	# click B1
			ptr(x, y, 1); pause(); ptr(x, y, 0);
		3 =>	# double click B1
			ptr(x, y, 1); ptr(x, y, 0); ptr(x, y, 1); pause(); ptr(x, y, 0);
		4 =>	# B1 drag
			ptr(x, y, 1);
			for(i := rand->rand(6); i >= 0; i--){
				pause();
				ptr(rx(), ry(), 1);
			}
			ptr(rx(), ry(), 0);
		5 =>	# B2: execute
			ptr(x, y, 2); pause(); ptr(x, y, 0);
		6 =>	# B3: look
			ptr(x, y, 4); pause(); ptr(x, y, 0);
		7 =>	# chords: B1 then B2 (cut) or B3 (paste)
			ptr(x, y, 1);
			pause();
			c := 2;
			if(rand->rand(2))
				c = 4;
			ptr(x+rand->rand(30), y, 1|c); pause();
			ptr(x+rand->rand(30), y, 1); pause();
			ptr(x+rand->rand(30), y, 0);
		8 =>	# the wheel
			b := 8;
			if(rand->rand(2))
				b = 16;
			for(i := rand->rand(5); i >= 0; i--){
				ptr(x, y, b);
				ptr(x, y, 0);
			}
		9 =>	# a scroll bar
			x = X0 + rand->rand(12);
			b := 1 << rand->rand(3);
			ptr(x, y, b);
			for(i := rand->rand(4); i >= 0; i--){
				pause();
				ptr(x, ry(), b);
			}
			ptr(rx(), ry(), 0);
		10 =>	# a window's or column's button: drag it
			x = X0 + rand->rand(12);
			b := 1 << rand->rand(3);
			ptr(x, y, b); pause();
			ptr(rx(), ry(), b); pause();
			ptr(rx(), ry(), 0);
		11 =>	# B2 or B3 swept, let go elsewhere
			b := 2;
			if(rand->rand(2))
				b = 4;
			ptr(x, y, b); pause();
			ptr(rx(), ry(), b); pause();
			ptr(rx(), ry(), 0);
		12 =>	# pressed, let go off the text
			b := 1 << rand->rand(3);
			ptr(x, y, b); pause();
			ptr(W-1, H-1, b);
			ptr(W-1, H-1, 0);
		13 =>	# buttons mashed
			ptr(x, y, 1+rand->rand(7)); pause();
			ptr(x, y, rand->rand(8));
			ptr(x, y, 0);
		}
		pause();
	}
	ptr(W/2, H/2, 0);
	done <-= 1;
}

keys := array[] of {
	'\n', '\b', '\t', 16r1b, 16r7f,
	16rE010, 16rE011, 16rE012, 16rE013,	# Home End Up Down
	16rE014, 16rE015, 16rE016, 16rE017,	# Left Right Pgup Pgdown
	'U'-'@', 'W'-'@', 'H'-'@', 'A'-'@', 'E'-'@', 'Z'-'@', 'Y'-'@',
	'C'-'@', 'V'-'@', 'X'-'@', 'S'-'@',
};

keyfuzz(seed: int, done: chan of int)
{
	rand->init(seed);
	while(sys->millisec() < deadline){
		nact[1]++;
		case rand->rand(6) {
		0 =>
			key(keys[rand->rand(len keys)]);
		* =>
			# no capitals: they would spell Exit
			c := 'a' + rand->rand(26);
			if(rand->rand(8) == 0)
				c = "/:.,()[]{} |<>"[rand->rand(14)];
			key(c);
		}
		if(rand->rand(10) == 0)
			pause();
	}
	done <-= 1;
}

Win: adt {
	id:	string;
	bodysize:	int;
	isdir:	int;
	name:	string;
};

windows(): list of ref Win
{
	(nil, lines) := sys->tokenize(xread(X+"/index"), "\n");
	l: list of ref Win;
	for(; lines != nil; lines = tl lines){
		(n, f) := sys->tokenize(hd lines, " ");
		if(n < 5)
			continue;
		w := ref Win;
		w.id = hd f;
		f = tl tl f;
		w.bodysize = int hd f;
		w.isdir = int hd tl f;
		f = tl tl tl f;
		if(f != nil)
			w.name = hd f;
		l = w :: l;
	}
	return l;
}

pick1(l: list of ref Win): ref Win
{
	n := len l;
	if(n == 0)
		return nil;
	for(i := rand->rand(n); i > 0; i--)
		l = tl l;
	return hd l;
}

# a window's events answered as win(1) does: written back
eventer(id: string)
{
	fd := sys->open(X+"/"+id+"/event", Sys->ORDWR);
	if(fd == nil)
		return;
	b := array[8192] of byte;
	while(sys->millisec() < deadline && (n := sys->read(fd, b, len b)) > 0){
		s := string b[0:n];
		if(len s > 2 && (s[1] == 'x' || s[1] == 'X' || s[1] == 'l' || s[1] == 'L')){
			(nil, f) := sys->tokenize(s[2:], " \n");
			if(len f >= 2)
				sys->fprint(fd, "%c%c%s %s\n", s[0], s[1], hd f, hd tl f);
		}
	}
}

agentfuzz(seed: int, done: chan of int)
{
	rand->init(seed);
	while(sys->millisec() < deadline){
		nact[2]++;
		w := pick1(windows());
		if(w == nil){
			newwin();
			continue;
		}
		d := X+"/"+w.id;
		case rand->rand(18) {
		0 or 1 or 2 =>
			xwrite(d+"/body", randtext(1+rand->rand(5)));
		3 =>
			fd := sys->open(d+"/addr", Sys->ORDWR);
			if(fd != nil){
				sys->fprint(fd, "#%d,#%d", rand->rand(40), 40+rand->rand(40));
				xwrite(d+"/data", randtext(1));
			}
		4 =>
			xwrite(d+"/ctl", "dot=addr");
		5 =>
			xwrite(d+"/ctl", "show");
		6 =>
			xwrite(d+"/ctl", "clean");
		7 =>
			xread(d+"/body");
		8 =>
			xread(d+"/tag");
		9 =>
			spawn eventer(w.id);
		10 =>
			if(rand->rand(4) == 0)
				xwrite(d+"/ctl", "del");
		11 =>
			newwin();
		12 =>
			fd := sys->open(d+"/addr", Sys->ORDWR);
			if(fd != nil){
				sys->fprint(fd, ",");
				xwrite(d+"/ctl", "addr=dot");
			}
		13 =>
			xwrite(d+"/edit", ",x/foo/c/FOO/");
		14 =>
			xwrite(d+"/tag", " "+words[rand->rand(len words)]);
		15 =>
			xwrite(d+"/ctl", "dirty");
		16 =>
			xwrite(d+"/ctl", "get");
		17 =>
			if(rand->rand(3) == 0)
				xwrite(d+"/ctl", "put");
		}
		sys->sleep(rand->rand(60));
	}
	done <-= 1;
}

#
# After the input: what a window holds is what is read back and what
# Put writes, and undo and redo take it back and forth exactly
#

ndata := 0;

data(s: string)
{
	sys->print("fuzz: DATA %s\n", s);
	ndata++;
}

integrity()
{
	# every window's text reads back as long as its ctl says: the body
	# first, as reading it commits typing the ctl does not count
	for(l := windows(); l != nil; l = tl l){
		w := hd l;
		if(w.isdir)
			continue;
		b := xread(X+"/"+w.id+"/body");
		(n, f) := sys->tokenize(xread(X+"/"+w.id+"/ctl"), " ");
		if(n < 3 || isdoc(w))
			continue;
		size := int hd tl tl f;
		if(len b != size)
			data(sys->sprint("window %s (%s): its ctl says %d characters, its body reads %d",
				w.id, w.name, size, len b));
	}

	# Put writes what the window holds: each of the work files shown
	for(l = windows(); l != nil; l = tl l){
		w := hd l;
		if(w.isdir || !isworkfile(w.name))
			continue;
		if(xwrite(X+"/"+w.id+"/ctl", "put") < 0)
			continue;	# refused (a document, say)
		body := xread(X+"/"+w.id+"/body");
		# a large file is written in the background
		disk: string;
		for(t := 0; t < 50; t++){
			disk = xread(w.name);
			if(disk == body)
				break;
			sys->sleep(200);
		}
		if(disk != body)
			data(sys->sprint("Put of window %s (%s): the file holds %d characters, the window %d",
				w.id, w.name, len disk, len body));
	}

	# undo and redo: a window's edits undone give back its text before
	# them, redone give back its text after
	id := newwin();
	if(id != nil){
		d := X+"/"+id;
		xwrite(d+"/ctl", "name "+dir+"/undo");
		xwrite(d+"/body", randtext(30));
		before := xread(d+"/body");
		n := 3 + rand->rand(8);
		for(i := 0; i < n; i++){
			fd := sys->open(d+"/addr", Sys->ORDWR);
			b := len before;
			q0 := rand->rand(b/2);
			sys->fprint(fd, "#%d,#%d", q0, q0+rand->rand(10));
			xwrite(d+"/data", randtext(1+rand->rand(3)));	# a change of its own
			fd = nil;
		}
		after := xread(d+"/body");
		xwrite(d+"/edit", "u"+string n+"\n");
		if((s := xread(d+"/body")) != before)
			data(sys->sprint("undo of %d changes: the text is %d characters, %d before them", n, len s, len before));
		xwrite(d+"/edit", "u-"+string n+"\n");
		if((s = xread(d+"/body")) != after)
			data(sys->sprint("redo of %d changes: the text is %d characters, %d after them", n, len s, len after));
		xwrite(d+"/ctl", "clean");
		xwrite(d+"/ctl", "delete");
	}
	if(ndata == 0)
		sys->print("fuzz: INTEGRITY ok\n");
}

isworkfile(name: string): int
{
	for(i := 1; i <= 3; i++)
		if(name == dir+"/f"+string i)
			return 1;
	return name == dir+"/fbig";
}

# a document shown: its body is the document's text, not the file's
isdoc(w: ref Win): int
{
	return xread(X+"/"+w.id+"/doc/ctl") != nil;
}
