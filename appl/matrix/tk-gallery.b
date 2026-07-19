implement TkGallery;

#
# tk-gallery — Matrix Tk-hosted widget review gallery.
#
# One of every core Tk widget class, twice: the left column exactly as
# the engine's defaults render it (raised/sunken bevels, text-tight
# buttons), the right column in the proposed InferNode treatment —
# flat relief (2D brutalist, no bevels) and real touch surfaces
# (pack -ipadx/-ipady grows the widget's actual hit target, per the
# 44pt/48dp minimum-target conventions).  Load it, look at it, decide.
#
# The mount argument is unused (pass /); the gallery is static — it
# reviews the toolkit, not a data source.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "matrixtk.m";

TkGallery: module
{
	init:		fn(top: ref Toplevel, prefix, mount: string): string;
	resize:		fn(r: Draw->Rect);
	update:		fn(): int;
	retheme:	fn();
	shutdown:	fn();
};

top_g:		ref Toplevel;
prefix_g:	string;

# One column of every reviewed widget under parent frame f.
# flat != 0 applies the proposed treatment: -relief flat everywhere a
# bevel is the default, and -ipadx/-ipady on the interactive targets.
column(f: string, title: string, flat: int): string
{
	deco := "";
	if(flat)
		deco = " -relief flat -borderwidth 1";
	ipad := "";
	if(flat)
		ipad = " -ipadx 10 -ipady 6";

	# Fixed natural widths: the region frame is a fixed-size canvas
	# item, so pack -expand games clip; explicit geometry always fits.
	W := 190;
	cmds := array[] of {
		sys->sprint("label %s.title -text {%s}", f, title),
		sys->sprint("button %s.b -text {button}%s", f, deco),
		sys->sprint("checkbutton %s.cb -text {checkbutton}%s", f, deco),
		sys->sprint("radiobutton %s.r1 -text {radio one} -variable %s.v -value 1%s", f, f, deco),
		sys->sprint("radiobutton %s.r2 -text {radio two} -variable %s.v -value 2%s", f, f, deco),
		sys->sprint("entry %s.e -width %d%s", f, W, deco),
		sys->sprint("listbox %s.lb -width %d -height 42%s", f, W, deco),
		sys->sprint("scale %s.sc -orient horizontal -length %d -from 0 -to 100 -showvalue 1%s", f, W, deco),
		sys->sprint("scrollbar %s.sb -orient horizontal -height 16%s", f, deco),
		sys->sprint("text %s.t -width %d -height 40%s", f, W, deco),

		sys->sprint("pack %s.title -side top -anchor w -pady 4", f),
		sys->sprint("pack %s.b %s.cb %s.r1 %s.r2 -side top -anchor w -padx 4 -pady 3%s",
			f, f, f, f, ipad),
		sys->sprint("pack %s.e %s.lb %s.sc %s.sb %s.t -side top -anchor w -padx 4 -pady 3%s",
			f, f, f, f, f, ipad),
	};
	for(i := 0; i < len cmds; i++) {
		e := tk->cmd(top_g, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			return "tk: " + e + " on " + cmds[i];
	}

	# representative content so bevels/insets are visible in use
	tk->cmd(top_g, sys->sprint("%s.e insert 0 {entry text}", f));
	tk->cmd(top_g, sys->sprint("%s.lb insert end {listbox item 1}", f));
	tk->cmd(top_g, sys->sprint("%s.lb insert end {listbox item 2}", f));
	tk->cmd(top_g, sys->sprint("%s.lb insert end {listbox item 3}", f));
	tk->cmd(top_g, sys->sprint("%s.sc set 40", f));
	tk->cmd(top_g, sys->sprint("%s.t insert end {text widget\nsecond line}", f));
	return nil;
}

init(top: ref Toplevel, prefix, nil: string): string
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		return sys->sprint("cannot load Tk: %r");
	top_g = top;
	prefix_g = prefix;

	e := tk->cmd(top, sys->sprint("frame %s.l", prefix));
	if(e != nil && len e > 0 && e[0] == '!')
		return "tk: " + e;
	tk->cmd(top, sys->sprint("frame %s.r", prefix));
	tk->cmd(top, sys->sprint("pack %s.l %s.r -side left -anchor n -padx 8", prefix, prefix));

	if((err := column(prefix + ".l", "engine defaults", 0)) != nil)
		return err;
	if((err = column(prefix + ".r", "flat + padded (proposed)", 1)) != nil)
		return err;
	return nil;
}

resize(nil: Draw->Rect)
{
	# pack reflows; nothing to do.
}

update(): int
{
	return 0;	# static — the gallery reviews the toolkit, not data
}

retheme()
{
	# widgets follow the engine palette; nothing module-set.
}

shutdown()
{
}
