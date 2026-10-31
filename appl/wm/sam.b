implement Samterm;

include "sys.m";
sys: Sys;
fprint, sprint, FD: import sys;
stderr, logfd: ref FD;

include "draw.m";
draw:	Draw;

include "samterm.m";

include "samtk.m";
samtk: Samtk;

include "samstub.m";
samstub: Samstub;
Samio, Sammsg: import samstub;

samio: ref Samio;

ctxt: ref Context;

init(context: ref draw->Context, argv: list of string)
{
	recvsam: chan of ref Sammsg;

	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr = sys->fildes(2);

	# drop the program name; the rest are files to open.  -d traces
	# the protocol to samterm.log in the current directory.
	if(argv != nil)
		argv = tl argv;
	if(argv != nil && hd argv == "-d") {
		argv = tl argv;
		logfd = sys->create("samterm.log", sys->OWRITE, 8r666);
		if (logfd == nil)
			fprint(stderr, "sam: can't create samterm.log: %r\n");
	}
	if (logfd == nil)
		logfd = sys->open("/dev/null", sys->OWRITE);
	if (logfd == nil)
		logfd = stderr;

	fprint(logfd, "Samterm started\n");
	fprint(logfd, "ctxt: nonnil=%d display=%d wm=%d\n",
		context != nil,
		context != nil && context.display != nil,
		context != nil && context.wm != nil);

	pgrp := sys->pctl(sys->NEWPGRP, nil);

	ctxt = ref Context(
		context,
		1000,		# initial tag
		0,		# lock

		nil,		# keysel
		nil,		# buttonsel
		nil,		# flayers

		nil,		# menus
		nil,		# texts

		nil,		# cmd
		nil,		# which
		nil,		# work
		pgrp,		# pgrp
		logfd,		# logging file descriptor

		nil,		# top
		nil,		# wmctl
		nil,		# mousec
		nil,		# menu2c
		nil,		# menu3c
		Normal,		# mode
		0,		# mbuttons
		nil,		# order
		0,		# nextid
		(0, 0),		# size
		nil,		# pat
		0,		# hit2
		0,		# hit2c
		0		# hit3
	);

	samtk = load Samtk Samtk->PATH;
	if (samtk == nil) {
		fprint(stderr, "Can't load %s\n", Samtk->PATH);
		return;
	}
	samtk->init(ctxt);

	samstub = load Samstub Samstub->PATH;
	if (samstub == nil) {
		fprint(stderr, "Can't load %s\n", Samstub->PATH);
		return;
	}
	samstub->init(ctxt);

	(samio, recvsam) = samstub->start(argv);
	if (samio == nil) {
		fprint(stderr, "couldn't start samstub\n");
		return;
	}
	samstub->outTs(samstub->Tversion, samstub->VERSION);

	samstub->startcmdfile();

	samstub->setlock();

	# samterm's main loop.  Typing waits while the host has the lock;
	# the mouse and the menus do not (they check the lock themselves).
	for(;;) {
		if (ctxt.lock == 0) alt {
		(win, c) := <-ctxt.keysel =>
			key(win, c);
		(win, m1) := <-ctxt.buttonsel =>
			button1(win, m1);
		s := <-ctxt.mousec =>
			mouse(s);
		s := <-ctxt.menu2c =>
			menu2hit(s);
		s := <-ctxt.menu3c =>
			menu3hit(s);
		s := <-ctxt.wmctl =>
			if (wm(s))
				return;
		h := <-recvsam =>
			if (host(h))
				return;
		} else alt {
		(win, m1) := <-ctxt.buttonsel =>
			button1(win, m1);
		s := <-ctxt.mousec =>
			mouse(s);
		s := <-ctxt.menu2c =>
			menu2hit(s);
		s := <-ctxt.menu3c =>
			menu3hit(s);
		s := <-ctxt.wmctl =>
			if (wm(s))
				return;
		h := <-recvsam =>
			if (host(h))
				return;
		}
	}
}

quit()
{
	samstub->outT0(samstub->Texit);
	f := sprint("#p/%d/ctl", ctxt.pgrp);
	if ((fd := sys->open(f, sys->OWRITE)) != nil)
		sys->write(fd, array of byte "killgrp\n", 8);
}

host(h: ref Sammsg): int
{
	if (samstub->inmesg(h)) {
		quit();
		return 1;
	}
	return 0;
}

wm(s: string): int
{
	case s {
	"exit" =>
		quit();
		return 1;
	"resize" =>
		# main.c's resize: flresize, then hcheck every file
		if (samtk->flresize()) {
			for (i := 0; i < len ctxt.flayers; i++)
				samstub->scrollto(ctxt.flayers[i], ctxt.flayers[i].scope.first);
		}
	"task" =>
		spawn samtk->titlectl(s);
	* =>
		samtk->titlectl(s);
	}
	return 0;
}

textof(fl: ref Flayer): ref Text
{
	if (fl == nil || (i := samtk->whichtext(fl.tag)) < 0)
		return nil;
	return ctxt.texts[i];
}

layer(id: int): ref Flayer
{
	for (i := 0; i < len ctxt.flayers; i++)
		if (ctxt.flayers[i].id == id)
			return ctxt.flayers[i];
	return nil;
}

# typing goes to the current layer (main.c's type)
key(win: int, c: string)
{
	if (ctxt.which != ctxt.flayers[win]) {
		samstub->cleanout();
		samtk->current(ctxt.flayers[win]);
	}
	samstub->keypress(c[1:len c -1]);
}

# button 1 in the current layer's text: flselect
button1(win: int, m1: string)
{
	samstub->cleanout();
	fl := ctxt.flayers[win];
	case samtk->buttonselect(fl, m1) {
	1 =>
		samstub->outTsl(samstub->Tdclick, fl.tag, fl.dot.first);
		samstub->setlock();
	0 =>
		if (textof(fl) != ctxt.cmd)
			samstub->outcmd();
	}
}

# what samtk's pump hands on: a layer made current, a scroll bar
mouse(s: string)
{
	(n, l) := sys->tokenize(s, " ");
	if (n < 2)
		return;
	fl := layer(int hd tl l);
	if (fl == nil)
		return;
	case hd l {
	"current" =>
		samstub->cleanout();
		samtk->current(fl);
	"scroll" =>
		samstub->cleanout();
		if (n != 5 || fl != ctxt.which || !int hd tl tl tl tl l)
			return;
		scroll(fl, int hd tl tl l, int hd tl tl tl l);
	}
}

# scroll.c's scroll, on release: button 1 moves back as many lines as
# the pointer is below the top, button 2 jumps to the place in the file,
# button 3 brings the line at the pointer to the top
scroll(fl: ref Flayer, but, y: int)
{
	t := textof(fl);
	if (t == nil)
		return;
	p0 := samtk->scrollp0(t, fl, but, y);
	case but {
	1 =>
		samstub->outTsll(samstub->Torigin, t.tag, fl.scope.first, p0);
		samstub->setlock();
	2 =>
		samstub->outTsll(samstub->Torigin, t.tag, p0, 1);
		samstub->setlock();
	3 =>
		samstub->scrollto(fl, p0);
	}
}

# menu.c's menu2hit: on the current layer, and not while locked
menu2hit(s: string)
{
	(nil, l) := sys->tokenize(s, " ");
	if (len l != 2)
		return;
	fl := ctxt.which;
	if (fl == nil || (t := textof(fl)) == nil)
		return;
	if (t == ctxt.cmd)
		ctxt.hit2c = int hd l;
	else
		ctxt.hit2 = int hd l;
	samstub->cleanout();
	if (ctxt.lock || t.lock)
		return;
	case hd tl l {
	"cut" =>
		# cut(t, w, 1, 1): it saves the text in the snarf buffer
		samstub->snarf(t, fl);
		samstub->cut(t, fl);
	"paste" =>
		samstub->paste(t, fl);
	"snarf" =>
		samstub->snarf(t, fl);
	"look" =>
		samstub->look(t, fl);
	"search" =>
		if (t == ctxt.cmd)
			samstub->send(t, fl);
		else
			samstub->search(t, fl);
	}
}

# menu.c's menu3hit
menu3hit(s: string)
{
	(n, l) := sys->tokenize(s, " ");
	if (n < 2)
		return;
	ctxt.hit3 = int hd l;
	samstub->cleanout();
	case hd tl l {
	"new" =>
		if (!ctxt.lock)
			samstub->sweeptext(1, 0);
	"zerox" or "resize" =>
		if (!ctxt.lock) {
			(b, p) := samtk->getpick();
			fl: ref Flayer;
			if ((b & 4) && (fl = samtk->flwhich(p)) != nil) {
				(ok, r) := samtk->getr();
				if (ok)
					samstub->duplicate(fl, r, hd tl l == "resize");
			}
			samtk->buttonsup();
		}
	"close" =>
		if (!ctxt.lock) {
			(b, p) := samtk->getpick();
			fl: ref Flayer;
			if ((b & 4) && (fl = samtk->flwhich(p)) != nil && !ctxt.lock) {
				t := textof(fl);
				if (len t.flayers > 1)
					samstub->closeup(fl);
				else if (t != ctxt.cmd) {
					samstub->outTs(samstub->Tclose, t.tag);
					samstub->setlock();
				}
			}
			samtk->buttonsup();
		}
	"write" =>
		if (!ctxt.lock) {
			(b, p) := samtk->getpick();
			fl: ref Flayer;
			if ((b & 4) && (fl = samtk->flwhich(p)) != nil) {
				samstub->outTs(samstub->Twrite, textof(fl).tag);
				samstub->setlock();
			}
			samtk->buttonsup();
		}
	"file" =>
		if (n != 3 || (i := samtk->whichmenu(int hd tl tl l)) < 0)
			return;
		t := ctxt.menus[i].text;
		if (t != nil) {
			# its front window, or the next if that one is current
			if (len t.flayers > 1 && ctxt.which == hd t.flayers)
				t.flayers = samtk->append(tl t.flayers, hd t.flayers);
			samtk->current(hd t.flayers);
		} else if (!ctxt.lock)
			samstub->sweeptext(0, ctxt.menus[i].tag);
	}
}
