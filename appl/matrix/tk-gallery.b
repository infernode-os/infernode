implement TkGallery;

#
# tk-gallery — Matrix Tk-hosted widget review gallery.
#
# Every visual Tk widget class, twice, side by side — and ALL of it on
# screen at once: two pair-groups share one grid (interactive targets
# left, field widgets right), so nothing hides behind a scrollbar.
# Column pairs: "engine defaults" beside the proposed treatment.
#
# The engine already renders flat 2D by design: libtk/colrs.c sources
# the palette from the active lucitheme and pins the relief shades to
# one hard border colour, so the default relief IS a crisp 1px frame —
# never a bevel.  The proposal therefore does NOT touch relief (an
# earlier -relief flat cut deleted the border: a black button on a
# black background).  It differs in exactly two ways:
#   - touch surfaces: grid -ipadx/-ipady grows the interactive
#     widgets' real hit target (44pt/48dp conventions);
#   - a tonal button surface: plain buttons get the theme's
#     hover/active shade as their resting background, so a button
#     reads as a button, border AND fill.  (Hardcoded Brimstone
#     clActive here — a review mock; as an adopted default this
#     belongs in libtk drawing from PActive, not in modules.)
#
# Engine fixes reviewed here (in libtk, visible in BOTH columns):
# round radiobutton indicators (vs the checkbutton square), entry text
# vertically centred in tall fields, menubutton border at 1px.
#
# The full class list is button, checkbutton, radiobutton,
# choicebutton, menubutton, menu, label, entry, listbox, scale,
# scrollbar, canvas, text, frame, panel.  Not shown: menu (press the
# menubutton), frame (the invisible container these sit in), panel
# (hosts a Draw image; blank without one).
#
# The mount argument is unused (pass /); the gallery is static.
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
prefix_g:	string;	# the gridded body frame
root_g:		string;	# the region prefix (canvas + scrollbar live here)

W: con 150;		# natural width of the field-like widgets
TONAL: con " -background #1e1e1e";	# Brimstone clActive (see header)
IPAD: con " -ipadx 8 -ipady 5";

cmd(s: string): string
{
	e := tk->cmd(top_g, s);
	if(e != nil && len e > 0 && e[0] == '!')
		return "tk: " + e + " on " + s;
	return nil;
}

# Create one widget of the row's class at path p; deco is the proposed
# treatment's extra options.  var distinguishes the two columns' radio
# groups and menus.
mkwidget(class, p, var, deco: string): string
{
	c := "";
	case class {
	"button" =>
		c = sys->sprint("button %s -text {button}%s", p, deco);
	"checkbutton" =>
		c = sys->sprint("checkbutton %s -text {checkbutton}", p);
	"radio1" =>
		c = sys->sprint("radiobutton %s -text {radio one} -variable %s -value 1", p, var);
	"radio2" =>
		c = sys->sprint("radiobutton %s -text {radio two} -variable %s -value 2", p, var);
	"choicebutton" =>
		c = sys->sprint("choicebutton %s -values {alpha beta gamma}%s", p, deco);
	"menubutton" =>
		m := prefix_g + ".mnu" + var;
		if((e := cmd(sys->sprint("menu %s", m))) != nil)
			return e;
		cmd(sys->sprint("%s add command -label {first item}", m));
		cmd(sys->sprint("%s add command -label {second item}", m));
		c = sys->sprint("menubutton %s -text {menubutton} -menu %s%s", p, m, deco);
	"label" =>
		c = sys->sprint("label %s -text {label}", p);
	"entry" =>
		c = sys->sprint("entry %s -width %d%s", p, W, deco);
	"listbox" =>
		# wired to the scrollbar row below (same group/side)
		c = sys->sprint("listbox %s -width %d -height 58 -xscrollcommand {%s.%s_3 set}",
			p, W, prefix_g, var);
	"scale" =>
		c = sys->sprint("scale %s -orient horizontal -length %d -from 0 -to 100 -showvalue 1", p, W);
	"scrollbar" =>
		# a scrollbar with nothing to scroll is an unidentifiable
		# grey slab: this one really scrolls the listbox above it
		c = sys->sprint("scrollbar %s -orient horizontal -command {%s.%s_1 xview}",
			p, prefix_g, var);
	"canvas" =>
		c = sys->sprint("canvas %s -width %d -height 44", p, W);
	"text" =>
		c = sys->sprint("text %s -width %d -height 58", p, W);
	}
	if((e := cmd(c)) != nil)
		return e;

	# representative content / state so borders and insets show in use
	case class {
	"checkbutton" =>
		cmd(p + " select");
	"radio1" =>
		cmd(p + " select");
	"entry" =>
		cmd(sys->sprint("%s insert 0 {entry text}", p));
	"listbox" =>
		cmd(sys->sprint("%s insert end {listbox item 1}", p));
		cmd(sys->sprint("%s insert end {listbox item 2}", p));
		cmd(sys->sprint("%s insert end {listbox item 3 — long enough that the scrollbar below has something real to do}", p));
	"scale" =>
		cmd(sys->sprint("%s set 40", p));
	"canvas" =>
		# one of each mark, curves included: libdraw has no
		# anti-aliasing, so the oval and diagonal render stepped —
		# shown deliberately, that IS the current rendering truth
		# (AA is a rasteriser-level engine project, on the list)
		cmd(sys->sprint("%s create rectangle 8 8 60 36 -outline white", p));
		cmd(sys->sprint("%s create oval 60 8 100 36 -fill #cc5940", p));
		cmd(sys->sprint("%s create line 108 36 144 8", p));
		cmd(sys->sprint("%s create line 108 22 144 22", p));
	"text" =>
		cmd(sys->sprint("%s insert end {text widget\nsecond line}", p));
	}
	return nil;
}

# Lay one group's rows into grid columns c0 (class name), c0+1
# (default), c0+2 (proposed), starting at grid row 1.  target rows get
# IPAD on the proposed side.  The name column answers "what is this
# widget" for every row — a control with no label reads as nothing.
group(rows: array of (string, string, string, int), c0: int): string
{
	for(i := 0; i < len rows; i++) {
		(class, name, sticky, target) := rows[i];
		nm := sys->sprint("%s.n%d_%d", prefix_g, c0, i);
		dp := sys->sprint("%s.d%d_%d", prefix_g, c0, i);
		pp := sys->sprint("%s.p%d_%d", prefix_g, c0, i);
		deco := "";
		if(target)
			deco = TONAL;
		if(class == "checkbutton" || class == "radio1" || class == "radio2"
		|| class == "entry")
			deco = "";	# indicator/field carries the look; pad only
		if((e := cmd(sys->sprint("label %s -text {%s}", nm, name))) != nil)
			return e;
		if((e = mkwidget(class, dp, sys->sprint("d%d", c0), "")) != nil)
			return e;
		if((e = mkwidget(class, pp, sys->sprint("p%d", c0), deco)) != nil)
			return e;
		ipad := "";
		if(target)
			ipad = IPAD;
		if((e = cmd(sys->sprint("grid %s -row %d -column %d -sticky e -padx 4 -pady 2", nm, i+1, c0))) != nil)
			return e;
		if((e = cmd(sys->sprint("grid %s -row %d -column %d -sticky %s -padx 4 -pady 2", dp, i+1, c0+1, sticky))) != nil)
			return e;
		if((e = cmd(sys->sprint("grid %s -row %d -column %d -sticky %s -padx 4 -pady 2%s", pp, i+1, c0+2, sticky, ipad))) != nil)
			return e;
	}
	return nil;
}

init(top: ref Toplevel, prefix, nil: string): string
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		return sys->sprint("cannot load Tk: %r");
	top_g = top;
	root_g = prefix;

	# Widgets grid DIRECTLY into the region frame, exactly like
	# tk-notes: the engine routes events through one canvas window
	# item (the region), but NOT through a second nested one — a
	# scrolled-frame wrapper here left every widget unclickable
	# (dead slider, no selection, no entry cursor).  Engine defect
	# noted; until it is fixed, hosted modules must not nest canvas
	# window items.
	prefix_g = prefix;
	p := prefix_g;

	for(c := 0; c < 6; c += 3) {
		h1 := sys->sprint("%s.hd%d", p, c);
		h2 := sys->sprint("%s.hp%d", p, c);
		cmd(sys->sprint("label %s -text {engine defaults}", h1));
		cmd(sys->sprint("label %s -text {proposed}", h2));
		cmd(sys->sprint("grid %s -row 0 -column %d -sticky w -padx 6 -pady 4", h1, c+1));
		cmd(sys->sprint("grid %s -row 0 -column %d -sticky w -padx 6 -pady 4", h2, c+2));
	}

	# group A: interactive targets       group B: fields
	targets := array[] of {
		("button",	"button",	"w", 1),
		("checkbutton",	"checkbutton",	"w", 1),
		("radio1",	"radiobutton",	"w", 1),
		("radio2",	"",		"w", 1),
		("choicebutton","choicebutton",	"w", 1),
		("menubutton",	"menubutton",	"w", 1),
		("label",	"label",	"w", 0),
	};
	fields := array[] of {
		("entry",	"entry",	"we", 1),
		("listbox",	"listbox",	"we", 0),
		("scale",	"scale",	"we", 0),
		("scrollbar",	"scrollbar",	"we", 0),
		("canvas",	"canvas",	"w", 0),
		("text",	"text",	"we", 0),
	};
	if((e := group(targets, 0)) != nil)
		return e;
	if((e = group(fields, 3)) != nil)
		return e;
	# focus the proposed entry so its insertion cursor is visible on
	# load — a text field with no cursor anywhere reads as dead
	cmd(sys->sprint("focus %s.p3_0", prefix_g));
	return nil;
}

resize(nil: Draw->Rect)
{
	# pack/grid reflow; nothing to do.
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
