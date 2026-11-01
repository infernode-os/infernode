implement WmFrozen;

#
# A wm/wm client that has stopped: its window is up and it reads nothing
# more, as a program stuck in a read does.  With -k it reads its ctl and
# ignores exit, as a program asking its user something does.
# tests/host/wm_ghost_test.sh Deletes both.
#

include "sys.m";
	sys: Sys;
include "draw.m";
	draw: Draw;
	Rect: import draw;
include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

WmFrozen: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();
	w: ref Window = wmclient->window(ctxt, "frozen", Wmclient->Appl);
	w.reshape(Rect((0, 0), (300, 200)));
	w.startinput("kbd" :: "ptr" :: nil);
	w.onscreen(nil);
	if(tl args != nil)
		for(;;)
			<-w.ctxt.ctl;
	<-chan of int;
}
