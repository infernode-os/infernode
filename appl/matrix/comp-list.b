implement CompList;

#
# comp-list — the composition picker AS a composition module.
#
# Lists every composition under the mount (normally
# /lib/matrix/compositions) as REAL Tk buttons; each press writes
# "load <name>" to /mnt/matrix/ctl — the same verb sh and agents use.
# The default empty-state picker is just the `picker` crystallisation
# wiring this module, so users and agents can customise or replace the
# picker like any other composition.
#
# Tk widgets on purpose: the engine owns their geometry and routing,
# so the click target IS the tile — no hand-rolled hit-testing to
# drift out of alignment (the hand-drawn first version of this module
# did exactly that).  And, like every Tk widget, they are drivable
# from Inferno sh.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "readdir.m";
	readdir: Readdir;

include "matrixtk.m";

include "matrix.m";

CompList: module
{
	init:		fn(top: ref Toplevel, prefix, mount: string): string;
	resize:		fn(r: Draw->Rect);
	update:		fn(): int;
	retheme:	fn();
	shutdown:	fn();
	interval:	fn(): int;
};

# MatrixTicker probe: the library changes rarely; rescan at 1 Hz.
# Called on a fresh uninitialised instance — must stay a pure constant.
interval(): int
{
	return 1000;
}

top_g:		ref Toplevel;
prefix_g:	string;
mountpath:	string;
evch:		chan of string;
stopch:		chan of int;
names:		array of string;
lastsig:	string;
chname:		string;

init(top: ref Toplevel, prefix, mount: string): string
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		return sys->sprint("cannot load Tk: %r");
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		return sys->sprint("cannot load %s: %r", Readdir->PATH);

	top_g = top;
	prefix_g = prefix;
	mountpath = mount;
	lastsig = "";

	# Channel name derived from the prefix (".r3" → "clr3") so
	# hosted modules never collide on the toplevel's namechan space.
	chname = "cl";
	for(i := 0; i < len prefix; i++)
		if(prefix[i] != '.')
			chname[len chname] = prefix[i];
	evch = chan of string;
	tk->namechan(top, evch, chname);

	# NB pack order is load-bearing: the bottom edit button must be
	# packed BEFORE the expanding list, or the list frame claims the
	# whole remaining area and the button — though drawn on top —
	# loses the hit test to it.
	cmds := array[] of {
		sys->sprint("label %s.title -text {Matrix — click a composition to load}", prefix),
		sys->sprint("label %s.hint -text {(this picker is itself the `picker` crystallisation — press `edit this picker` to change it)}", prefix),
		# The picker edits ITSELF: a real Tk button writing the ctl
		# "edit" verb — the same wire sh and agents use.  (The B3
		# context menu is currently unreliable in hosted windows —
		# the button is the doctrine-pure path regardless.)
		# The button lives in a subframe like video-ctl's buttons:
		# direct children of a canvas-hosted frame have shown hit
		# zones offset from their pixels (parked libtk canvas
		# window-item defect); one level down the geometry behaves.
		sys->sprint("frame %s.bar", prefix),
		sys->sprint("button %s.bar.edit -text {edit this picker} -command {send %s -1}", prefix, chname),
		sys->sprint("frame %s.list", prefix),
		sys->sprint("pack %s.title -side top -anchor w -padx 8 -pady 4", prefix),
		sys->sprint("pack %s.hint -side top -anchor w -padx 8", prefix),
		# The bar sits at the top, in territory whose routing is
		# exercised every day by the tiles right below it.
		sys->sprint("pack %s.bar.edit -side left -padx 8 -pady 2 -ipadx 8 -ipady 5", prefix),
		sys->sprint("pack %s.bar -side top -fill x", prefix),
		sys->sprint("pack %s.list -side top -fill both -expand 1 -padx 8 -pady 6", prefix),
		# Matrix's context menu posts via the toplevel's "act"
		# channel; Inferno Tk does not propagate unhandled events to
		# parent widgets, so every widget that covers picker ground
		# carries the B3 binding itself.
		sys->sprint("bind %s.title <Button-3> {send act menu %%X %%Y}", prefix),
		sys->sprint("bind %s.hint <Button-3> {send act menu %%X %%Y}", prefix),
		sys->sprint("bind %s.list <Button-3> {send act menu %%X %%Y}", prefix),
	};
	for(i = 0; i < len cmds; i++) {
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			return "tk: " + e + " on " + cmds[i];
	}

	stopch = chan[1] of int;
	spawn evloop();
	update();
	return nil;
}

# One button per composition; each press is one ctl write.
evloop()
{
	for(;;) alt {
	<-stopch =>
		return;
	ev := <-evch =>
		# NB numeric payloads only: Tk `send` did not deliver word
		# payloads ("send ch edit" never arrived; "send ch -1" does).
		i := int ev;
		if(i == -1)
			ctlwrite("edit");
		else if(i >= 0 && i < len names)
			ctlwrite("load " + names[i]);
	}
}

ctlwrite(cmd: string)
{
	fd := sys->open("/mnt/matrix/ctl", Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte cmd;
	sys->write(fd, b, len b);
}

rescan(): int
{
	(entries, n) := readdir->init(mountpath, Readdir->NAME);
	sig := "";
	nn := 0;
	tmp := array[n] of string;
	for(i := 0; i < n; i++) {
		nm := entries[i].name;
		if(nm == "" || nm[0] == '.' || nm == "picker")
			continue;	# the picker doesn't list itself
		tmp[nn++] = nm;
		sig += nm + "\n";
	}
	if(sig == lastsig)
		return 0;
	lastsig = sig;
	names = tmp[0:nn];
	return 1;
}

# Rebuild the button column to match the library.
rebuild()
{
	tkc("destroy " + prefix_g + ".list");
	tkc(sys->sprint("frame %s.list", prefix_g));
	for(i := 0; i < len names; i++) {
		tkc(sys->sprint(
			"button %s.list.b%d -text {%s} -anchor w -command {send %s %d}",
			prefix_g, i, names[i], chname, i));
		tkc(sys->sprint(
			"bind %s.list.b%d <Button-3> {send act menu %%X %%Y}",
			prefix_g, i));
		# -ipadx/-ipady grow the buttons themselves — real touch
		# surfaces (44pt/48dp-convention targets), not just spacing.
		tkc(sys->sprint(
			"pack %s.list.b%d -side top -fill x -pady 2 -ipadx 8 -ipady 5",
			prefix_g, i));
	}
	tkc(sys->sprint(
		"pack %s.list -side top -fill both -expand 1 -padx 8 -pady 6", prefix_g));
}

tkc(cmd: string)
{
	e := tk->cmd(top_g, cmd);
	if(e != nil && len e > 0 && e[0] == '!')
		sys->fprint(sys->fildes(2), "comp-list: tk %s on %s\n", e, cmd);
}

resize(nil: Draw->Rect)
{
}

update(): int
{
	if(!rescan())
		return 0;
	rebuild();
	return 1;
}

retheme()
{
}

shutdown()
{
	if(stopch != nil) {
		alt {
		stopch <-= 1 =>
			;
		* =>
			;
		}
	}
	names = nil;
}
