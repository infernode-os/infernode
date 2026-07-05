implement Coffee;

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Context, Display, Point, Rect, Image, Screen: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include	"tkclient.m";
	tkclient: Tkclient;

Coffee: module
{
	init:	fn(ctxt: ref Context, argv: list of string);
};

display: ref Display;
t: ref Toplevel;

NC: con 6;

task_cfg := array[] of {
	"frame .f",
	"frame .b",
	"button .b.Stop -text Stop -command {send cmd stop}",
	"scale .b.Rate -from 1 -to 10 -orient horizontal"+
		" -showvalue 0 -command {send cmd rate}",
	"scale .b.Jitter -from 0 -to 5 -orient horizontal"+
		" -showvalue 0 -command {send cmd jitter}",
	"scale .b.Skip -from 0 -to 25 -orient horizontal"+
		" -showvalue 0 -command {send cmd skip}",
	".b.Rate set 3",
	".b.Jitter set 2",
	".b.Skip set 5",
	"pack .b.Stop .b.Rate .b.Jitter .b.Skip -side left",
	"pack .b -anchor w",
	"pack .f -side bottom -fill both -expand 1",
};

init(ctxt: ref Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;

	sys->pctl(Sys->NEWPGRP, nil);

	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	display = ctxt.display;

	# Request a generous initial size (bounded by the display) rather than
	# shrink-wrapping to the button row: the presentation zone sizes an app
	# to its content, so a small natural size leaves the cups in a narrow
	# left strip.  Sized large + pack-propagate off (below) the window fills
	# the zone and the animation centres in it.
	dr := ctxt.display.image.r;
	iw := dr.dx() - 40;
	ih := dr.dy() - 40;
	if(iw < 400) iw = 400;
	if(ih < 300) ih = 300;
	menubut: chan of string;
	(t, menubut) = tkclient->toplevel(ctxt, sys->sprint("-width %d -height %d", iw, ih), "Infernal Coffee", 0);

	# Disable geometry propagation BEFORE packing content, so the requested
	# window size survives: otherwise packing the (small) button row shrinks
	# "." to its natural width before onscreen, and the presentation zone
	# then lays us out at that narrow width.
	cmd(t, "pack propagate . 0");

	cmdch := chan of string;
	tk->namechan(t, cmdch, "cmd");

	for (i := 0; i < len task_cfg; i++)
		cmd(t, task_cfg[i]);

	tk->cmd(t, "update");
	tkclient->startinput(t, "ptr"::"kbd"::nil);
	tkclient->onscreen(t, nil);

	ctl := chan of (string, int, int);
	spawn animate(ctl);

	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or
	s = <-t.wreq or
	s = <-menubut =>
		tkclient->wmctl(t, s);
	press := <-cmdch =>
		(nil, word) := sys->tokenize(press, " ");
		case hd word {
		"stop" or "go" =>
			ctl <-= (hd word, 0, 0);
		"rate" or "jitter" or "skip" =>
			ctl <-= (hd word, int hd tl word, 0);
		}
	}

}

animate(ctl: chan of (string, int, int))
{
	stopped := 0;

	fill := display.open("/icons/bigdelight.bit");
	if (fill == nil) {
		sys->fprint(sys->fildes(2), "coffee: failed to allocate image\n");	
		exit;
	}

	c := array[NC] of ref Image;
	m := array[NC] of ref Image;

	for(i:=0; i<NC; i++){
		c[i] = display.open("/icons/coffee"+string i+".bit");
		m[i] = display.open("/icons/coffee"+string i+".mask");
	if (c[i] == nil || m[i] == nil) {
		sys->fprint(sys->fildes(2), "coffee: failed to allocate image\n");	
		exit;
	}
	}

	# Create and pack the panel; the buffer is (re)sized to the panel's
	# actual extent in the loop below.  The animation centres itself in the
	# buffer (center := buffer.r.max.div(2)); a fixed 400x300 buffer
	# anchored the cup cluster to the top-left of a larger (e.g. presentation
	# zone) panel, and querying the size once here is unreliable because the
	# panel has not yet been resized to the presentation zone.  Matching the
	# buffer to the live panel size centres the cups in whatever window we
	# end up in.
	cmd(t, "panel .f.p -bd 3 -relief flat");
	cmd(t, "pack .f.p -fill both -expand 1");
	# Stop the toplevel shrink-wrapping to the button row so the window
	# keeps the size the wm (e.g. the presentation zone) gives it; otherwise
	# the panel is only as wide as the buttons and the cups sit in a narrow
	# left strip instead of centred in the zone.
	cmd(t, "pack propagate . 0");
	cmd(t, "update");

	buffer: ref Image;
	bufw := 0;
	bufh := 0;

	rate := 3;
	jitter := 2;
	skip := 5;

	i = 0;
	for(k:=0; ; k++){
		sys->sleep(1);
		# Track the live panel size so the cups stay centred after the
		# window (re)sizes — e.g. when the presentation zone lays us out.
		pw := int cmd(t, ".f.p cget -actwidth");
		ph := int cmd(t, ".f.p cget -actheight");
		if(pw < 400) pw = 400;
		if(ph < 300) ph = 300;
		if(buffer == nil || pw != bufw || ph != bufh){
			buffer = display.newimage(Rect((0,0),(pw,ph)), t.image.chans, 0, Draw->Black);
			if(buffer == nil){
				sys->fprint(sys->fildes(2), "coffee: failed to allocate image\n");
				exit;
			}
			bufw = pw;
			bufh = ph;
			tk->putimage(t, ".f.p", buffer, nil);
		}
		if(k%25 > 25-skip)
			i -= rate;
		else
			i += rate;
		center := buffer.r.max.div(2);
		# Clear to black, then draw the backdrop centred behind the cups
		# (the fixed-size fill image no longer covers a full-window buffer,
		# so an un-centred draw left it stranded in the top-left corner).
		buffer.draw(buffer.clipr, display.black, nil, (0, 0));
		fillorg := center.sub(fill.r.max.div(2));
		buffer.draw(fill.r.addpt(fillorg), fill, nil, fill.r.min);
		for(j:=0; j<NC; j++){
			(sin, cos) := sincos(i+j*(360/NC));
			x := (sin*150)/1000 + jitter*(k%5);
			y := (cos*100)/1000 + jitter*(k%5);
			p0 := center.add((x-c[j].r.dx()/2, y-c[j].r.dy()/2));
			buffer.draw(c[j].r.addpt(p0), c[j], m[j], (0,0));
			if(j & 1)	# be nice from time to time
				sys->sleep(0);
		}
		tk->cmd(t, ".f.p dirty; update");
		sys->sleep(5);
		alt{
		(cmd, i0, i1) := <-ctl =>
	Pause:
			for(;;){
				case cmd{
				"go" =>
					if(stopped){
						tk->cmd(t, ".b.Stop configure -text Stop -command {send cmd stop}");
						tk->cmd(t, "update");
						stopped = 0;
					}
					break Pause;
				"stop" =>
					if(!stopped){
						tk->cmd(t, ".b.Stop configure -text { Go } -command {send cmd go}");
						tk->cmd(t, "update");
						stopped = 1;
					}
				"rate" =>
					rate = i0;
					if(stopped == 0)
						break Pause;
				"jitter" =>
					jitter = i0;
					if(stopped == 0)
						break Pause;
				"skip" =>
					skip = i0;
					if(stopped == 0)
						break Pause;
				}
				(cmd, i0, i1) = <-ctl;
			}
		* =>
			;
		}
	}
}

sintab := array[] of {
	0000, 0017, 0035, 0052, 0070, 0087, 0105, 0122, 0139, 0156,
	0174, 0191, 0208, 0225, 0242, 0259, 0276, 0292, 0309, 0326,
	0342, 0358, 0375, 0391, 0407, 0423, 0438, 0454, 0469, 0485,
	0500, 0515, 0530, 0545, 0559, 0574, 0588, 0602, 0616, 0629,
	0643, 0656, 0669, 0682, 0695, 0707, 0719, 0731, 0743, 0755,
	0766, 0777, 0788, 0799, 0809, 0819, 0829, 0839, 0848, 0857,
	0866, 0875, 0883, 0891, 0899, 0906, 0914, 0921, 0927, 0934,
	0940, 0946, 0951, 0956, 0961, 0966, 0970, 0974, 0978, 0982,
	0985, 0988, 0990, 0993, 0995, 0996, 0998, 0999, 0999, 1000,
	1000, };

sincos(a: int): (int, int)
{
	a %= 360;
	if(a < 0)
		a += 360;

	if(a <= 90)
		return (sintab[a], sintab[90-a]);
	if(a <= 180)
		return (sintab[180-a], -sintab[a-90]);
	if(a <= 270)
		return (-sintab[a-180], -sintab[270-a]);
	return (-sintab[360-a], sintab[a-270]);
}

cmd(win: ref Tk->Toplevel, s: string): string
{
	r := tk->cmd(win, s);
	if (len r > 0 && r[0] == '!') {
		sys->print("error executing '%s': %s\n", s, r[1:]);
	}
	return r;
}
