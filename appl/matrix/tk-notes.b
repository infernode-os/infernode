implement TkNotes;

#
# tk-notes — Matrix Tk-hosted display module: a shared scratchpad.
#
# The proof module for MatrixTkDisplay: real Tk widgets (entry +
# button + listbox) inside a composed region.  Lines typed into the
# entry are appended to <mount>/notes; the listbox mirrors the file,
# so notes written by anything else (an agent, echo from sh) appear
# on the next update tick.  Widgets inherit the live theme from the
# Tk engine palette and, like all Tk widgets, are drivable from
# Inferno sh.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "matrixtk.m";

TkNotes: module
{
	init:		fn(top: ref Toplevel, prefix, mount: string): string;
	resize:		fn(r: Draw->Rect);
	update:		fn(): int;
	retheme:	fn();
	shutdown:	fn();
};

top_g:		ref Toplevel;
prefix_g:	string;
mountpath:	string;
lastnotes:	string;
evch:		chan of string;
stopch:		chan of int;

init(top: ref Toplevel, prefix, mount: string): string
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		return sys->sprint("cannot load Tk: %r");

	top_g = top;
	prefix_g = prefix;
	mountpath = mount;
	lastnotes = "";
	ensuredir(mount);

	# Channel name derived from the prefix (".r3" → "ntr3") so
	# hosted modules never collide on the toplevel's namechan space.
	nm := "nt";
	for(i := 0; i < len prefix; i++)
		if(prefix[i] != '.')
			nm[len nm] = prefix[i];
	evch = chan of string;
	tk->namechan(top, evch, nm);

	cmds := array[] of {
		sys->sprint("frame %s.bar", prefix),
		sys->sprint("entry %s.bar.e", prefix),
		sys->sprint("button %s.bar.add -text {Add} -command {send %s add}", prefix, nm),
		sys->sprint("listbox %s.lb", prefix),
		sys->sprint("pack %s.bar.add -side right", prefix),
		sys->sprint("pack %s.bar.e -side left -fill x -expand 1", prefix),
		sys->sprint("pack %s.bar -side top -fill x", prefix),
		sys->sprint("pack %s.lb -side top -fill both -expand 1", prefix),
		sys->sprint("bind %s.bar.e <Key-\n> {send %s add}", prefix, nm),
	};
	for(i = 0; i < len cmds; i++) {
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			return "tk: " + e + " on " + cmds[i];
	}

	stopch = chan[1] of int;
	spawn evloop();
	refresh();
	return nil;
}

# Consume the widgets' semantic events.  The module owns this proc;
# shutdown stops it before the runtime destroys the widget subtree.
evloop()
{
	for(;;) alt {
	<-stopch =>
		return;
	ev := <-evch =>
		if(ev == "add") {
			txt := tk->cmd(top_g, prefix_g + ".bar.e get");
			if(txt != "" && (len txt == 0 || txt[0] != '!')) {
				appendnote(txt);
				tk->cmd(top_g, prefix_g + ".bar.e delete 0 end");
				refresh();
				tk->cmd(top_g, "update");
			}
		}
	}
}

resize(nil: Draw->Rect)
{
	# pack reflows the frame's children; nothing to do.
}

update(): int
{
	notes := readfile(mountpath + "/notes");
	if(notes == lastnotes)
		return 0;
	refresh();
	return 1;
}

retheme()
{
	# Widget colours come from the engine palette.
}

shutdown()
{
	alt {
	stopch <-= 1 =>
		;
	* =>
		;
	}
}

# ─── Widgets ⇄ file ────────────────────────────────────────

refresh()
{
	notes := readfile(mountpath + "/notes");
	lastnotes = notes;
	tk->cmd(top_g, prefix_g + ".lb delete 0 end");
	start := 0;
	for(i := 0; i <= len notes; i++) {
		if(i == len notes || notes[i] == '\n') {
			if(i > start)
				tk->cmd(top_g, sys->sprint("%s.lb insert end %s",
					prefix_g, tk->quote(notes[start:i])));
			start = i + 1;
		}
	}
}

appendnote(txt: string)
{
	path := mountpath + "/notes";
	old := readfile(path);
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	data := array of byte (old + txt + "\n");
	sys->write(fd, data, len data);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	out := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		out += string buf[0:n];
	}
	return out;
}

ensuredir(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return;
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/') {
			ensuredir(path[0:i]);
			break;
		}
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}
