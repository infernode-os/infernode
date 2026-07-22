implement VideoCtl;

#
# video-ctl — Matrix Tk-hosted transport controls for a vid9p stream.
#
# Real Tk buttons in a composed region — like every Tk widget, drivable
# from Inferno sh — whose commands write transport strings to
# <mount>/ctl, which is exactly the wire sh and agents use:
#
#     echo pause > /mnt/video/0/ctl
#     echo 'seek +5000' > /mnt/video/0/ctl
#
# The playhead lives in the vid9p SERVER (see appl/cmd/vid9p.b), so
# these buttons, a video-pane's keys, sh, and an agent all drive the
# same state and every viewer stays in sync.  A label mirrors
# <mount>/status.  Compose beside a video-pane on the same mount —
# see the video-player / video-live crystallisations.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "matrixtk.m";

include "matrix.m";

VideoCtl: module
{
	init:		fn(top: ref Toplevel, prefix, mount: string): string;
	resize:		fn(r: Draw->Rect);
	update:		fn(): int;
	retheme:	fn();
	shutdown:	fn();
	interval:	fn(): int;
};

# MatrixTicker probe: refresh the position label twice a second.
# Called on a fresh uninitialised instance — must stay a pure constant.
interval(): int
{
	return 500;
}

top_g:		ref Toplevel;
prefix_g:	string;
mountpath:	string;
evch:		chan of string;
stopch:		chan of int;
cfd:		ref Sys->FD;
laststate:	string;
vrate := 25;

init(top: ref Toplevel, prefix, mount: string): string
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		return sys->sprint("cannot load Tk: %r");

	top_g = top;
	prefix_g = prefix;
	mountpath = mount;
	laststate = "";

	# Channel name derived from the prefix (".r3" → "vcr3") so
	# hosted modules never collide on the toplevel's namechan space.
	nm := "vc";
	for(i := 0; i < len prefix; i++)
		if(prefix[i] != '.')
			nm[len nm] = prefix[i];
	evch = chan of string;
	tk->namechan(top, evch, nm);

	cmds := array[] of {
		sys->sprint("frame %s.b", prefix),
		sys->sprint("button %s.b.play -text { play } -command {send %s play}", prefix, nm),
		sys->sprint("button %s.b.pause -text { pause } -command {send %s pause}", prefix, nm),
		sys->sprint("button %s.b.stop -text { stop } -command {send %s stop}", prefix, nm),
		sys->sprint("button %s.b.back -text { -5s } -command {send %s back}", prefix, nm),
		sys->sprint("button %s.b.fwd -text { +5s } -command {send %s fwd}", prefix, nm),
		sys->sprint("label %s.b.pos -text {--}", prefix),
		# -ipadx/-ipady grow the widgets themselves — a real touch
		# surface (44pt/48dp-convention targets), not just spacing.
		sys->sprint("pack %s.b.play %s.b.pause %s.b.stop %s.b.back %s.b.fwd -side left -padx 2 -ipadx 8 -ipady 5",
			prefix, prefix, prefix, prefix, prefix),
		sys->sprint("pack %s.b.pos -side right -padx 4", prefix),
		sys->sprint("pack %s.b -side top -fill x", prefix),
	};
	for(i = 0; i < len cmds; i++) {
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			return "tk: " + e + " on " + cmds[i];
	}

	readfmt();
	stopch = chan[1] of int;
	spawn evloop();
	update();
	return nil;
}

# Consume the buttons' semantic events; each is one ctl write.
evloop()
{
	for(;;) alt {
	<-stopch =>
		return;
	ev := <-evch =>
		case ev {
		"play" =>	ctl("play");
		"pause" =>	ctl("pause");
		"stop" =>	ctl("stop");
		"back" =>	ctl("seek -5000");
		"fwd" =>	ctl("seek +5000");
		}
		if(update())
			tk->cmd(top_g, "update");
	}
}

ctl(cmd: string)
{
	if(cfd == nil)
		cfd = sys->open(mountpath + "/ctl", Sys->OWRITE);
	if(cfd == nil)
		return;
	b := array of byte cmd;
	sys->write(cfd, b, len b);
}

readfmt()
{
	fd := sys->open(mountpath + "/fmt", Sys->OREAD);
	if(fd == nil)
		return;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return;
	(nt, toks) := sys->tokenize(string b[0:n], " \t\n");
	if(nt >= 4) {
		r := int hd tl tl tl toks;
		if(r > 0 && r <= 120)
			vrate = r;
	}
}

# Mirror <mount>/status into the position label.
update(): int
{
	fd := sys->open(mountpath + "/status", Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return 0;
	strm := 0;
	nf := 0;
	playing := 0;
	fol := 0;
	tms := 0;
	(nil, toks) := sys->tokenize(string b[0:n], " \t\n");
	if(toks != nil && hd toks == "streaming")
		strm = 1;
	for(; toks != nil; toks = tl toks) {
		t := hd toks;
		if(len t > 7 && t[0:7] == "frames=")
			nf = int t[7:];
		else if(len t > 6 && t[0:6] == "state=")
			playing = t[6:] == "playing";
		else if(len t > 2 && t[0:2] == "t=")
			tms = int t[2:];
		else if(len t > 7 && t[0:7] == "follow=")
			fol = int t[7:];
	}
	# Compact: the buttons already say what pressing them does, so the
	# label carries only what they don't — mode (when not plain
	# playback) and position — and survives narrow regions.
	s: string;
	if(strm && fol && playing)
		s = sys->sprint("LIVE %ds", tms/1000);
	else if(strm)
		s = sys->sprint("replay %ds/%ds", tms/1000, nf/vrate);
	else if(playing)
		s = sys->sprint("%ds/%ds", tms/1000, nf/vrate);
	else
		s = sys->sprint("%ds/%ds paused", tms/1000, nf/vrate);
	if(s == laststate)
		return 0;
	laststate = s;
	tk->cmd(top_g, sys->sprint("%s.b.pos configure -text {%s}", prefix_g, s));
	return 1;
}

resize(nil: Draw->Rect)
{
	# pack reflows the frame's children; nothing to do.
}

retheme()
{
	# widgets follow the engine palette; nothing module-set.
}

shutdown()
{
	alt {
	stopch <-= 1 =>
		;
	* =>
		;
	}
	cfd = nil;
}
