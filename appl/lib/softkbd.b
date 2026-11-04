implement Softkbd;

#
# softkbd — wrapper for the /dev/consctl keyboard-avoidance verbs.
#
# See module/softkbd.m for the contract. The devcons-side parser lives
# in emu/port/devcons.c; the SDL3 backend (emu/port/draw-sdl3.c) owns
# the SDL_SetTextInputArea call that does the actual slide on iOS.
#
# A note on testing: the path defaults to /dev/consctl but tests
# override it via SOFTKBD_PATH so they can point at a /tmp file and
# inspect the bytes that would have gone to devcons.
#

include "sys.m";
	sys: Sys;

include "softkbd.m";

# Resolved at init(); tests override via the SOFTKBD_PATH env var.
ctlpath := "/dev/consctl";
OSKCTL: con "/mnt/osk/ctl";

init(): string
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	if(sys == nil)
		return "softkbd: cannot load Sys";

	# Allow tests to redirect to a fixture path without subclassing.
	fd := sys->open("/env/SOFTKBD_PATH", Sys->OREAD);
	if(fd != nil) {
		buf := array[256] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0) {
			s := string buf[:n];
			# strip trailing newlines / NULs
			while(len s > 0 && (s[len s - 1] == '\n' ||
					    s[len s - 1] == '\r' ||
					    s[len s - 1] == 0))
				s = s[:len s - 1];
			if(len s > 0)
				ctlpath = s;
		}
	}
	return nil;
}

# the verb for wm/osk's ctl (osk(4)), or nil for one it has no use for
oskverb(verb: string): string
{
	case verb {
	"kbd on" or "kbd ontop" =>
		return "show";
	"kbd off" =>
		return "hide";
	}
	if(len verb > 9 && verb[0:9] == "kbd rect ")
		return "rect " + verb[9:];
	if(len verb > 5 && verb[0:5] == "mode ")
		return verb;
	return nil;
}

write_verb(verb: string)
{
	if(sys == nil)
		return;
	# InferNode's own keyboard, when it is running, rather than the
	# system's (a test's SOFTKBD_PATH is its own business)
	if(ctlpath == "/dev/consctl" && (ofd := sys->open(OSKCTL, Sys->OWRITE)) != nil){
		if((v := oskverb(verb)) != nil){
			b := array of byte v;
			sys->write(ofd, b, len b);
		}
		return;
	}
	if(len verb > 5 && verb[0:5] == "mode ")
		return;		# the system's keyboard takes no hint
	fd := sys->open(ctlpath, Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte verb;
	sys->write(fd, b, len b);
}

show(mode: int)
{
	case mode {
	HIDE =>
		write_verb("kbd off");
	SLIDE =>
		write_verb("kbd on");
	KEEPTOP =>
		write_verb("kbd ontop");
	* =>
		;	# unknown mode — silently ignore
	}
}

set_rect(x, y, w, h: int)
{
	# w<=0 or h<=0 means "clear the override" — devcons treats
	# anything that doesn't parse as 4 ints the same way, but we
	# emit a canonical (0 0 0 0) so the wire log is predictable.
	if(w <= 0 || h <= 0) {
		write_verb("kbd rect 0 0 0 0");
		return;
	}
	# Negative origin is legitimate when the widget is partially
	# off-screen during a transition — devcons clamps inside the
	# C path. No need to filter here.
	write_verb(sys->sprint("kbd rect %d %d %d %d", x, y, w, h));
}

clear_rect()
{
	write_verb("kbd rect 0 0 0 0");
}

mode(prose: int)
{
	if(prose)
		write_verb("mode text");
	else
		write_verb("mode plain");
}
