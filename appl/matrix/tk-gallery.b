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

W: con 190;		# natural width of the field-like widgets
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
		c = sys->sprint("entry %s -width %d", p, W);
	"listbox" =>
		c = sys->sprint("listbox %s -width %d -height 58", p, W);
	"scale" =>
		c = sys->sprint("scale %s -orient horizontal -length %d -from 0 -to 100 -showvalue 1", p, W);
	"scrollbar" =>
		c = sys->sprint("scrollbar %s -orient horizontal", p);
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
		cmd(sys->sprint("%s insert end {listbox item 3}", p));
	"scale" =>
		cmd(sys->sprint("%s set 40", p));
	"scrollbar" =>
		cmd(sys->sprint("%s set 0.2 0.5", p));
	"canvas" =>
		cmd(sys->sprint("%s create rectangle 8 8 60 36 -outline white", p));
		cmd(sys->sprint("%s create oval 70 8 120 36 -fill #cc5940", p));
		cmd(sys->sprint("%s create line 130 36 180 8", p));
	"text" =>
		cmd(sys->sprint("%s insert end {text widget\nsecond line}", p));
	}
	return nil;
}

# Lay one group's rows into grid columns c0 (default) and c0+1
# (proposed), starting at grid row 1.  target rows get IPAD on the
# proposed side.
group(rows: array of (string, string, int), c0: int): string
{
	for(i := 0; i < len rows; i++) {
		(class, sticky, target) := rows[i];
		dp := sys->sprint("%s.d%d_%d", prefix_g, c0, i);
		pp := sys->sprint("%s.p%d_%d", prefix_g, c0, i);
		deco := "";
		if(target)
			deco = TONAL;
		if(class == "checkbutton" || class == "radio1" || class == "radio2")
			deco = "";	# indicators carry the state; pad only
		if((e := mkwidget(class, dp, sys->sprint("d%d", c0), "")) != nil)
			return e;
		if((e = mkwidget(class, pp, sys->sprint("p%d", c0), deco)) != nil)
			return e;
		ipad := "";
		if(target)
			ipad = IPAD;
		if((e = cmd(sys->sprint("grid %s -row %d -column %d -sticky %s -padx 6 -pady 2", dp, i+1, c0, sticky))) != nil)
			return e;
		if((e = cmd(sys->sprint("grid %s -row %d -column %d -sticky %s -padx 6 -pady 2%s", pp, i+1, c0+1, sticky, ipad))) != nil)
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

	# Scrolled-frame safety net (fits without scrolling at any sane
	# region size; degrades to scrolling instead of losing rows).
	cmd(sys->sprint("canvas %s.cv -yscrollcommand {%s.vs set}", prefix, prefix));
	cmd(sys->sprint("scrollbar %s.vs -command {%s.cv yview}", prefix, prefix));
	cmd(sys->sprint("frame %s.cv.body", prefix));
	cmd(sys->sprint("pack %s.vs -side right -fill y", prefix));
	cmd(sys->sprint("pack %s.cv -side left -fill both -expand 1", prefix));
	cmd(sys->sprint("%s.cv create window 0 0 -window %s.cv.body -anchor nw", prefix, prefix));
	prefix_g = prefix + ".cv.body";
	p := prefix_g;

	for(c := 0; c < 4; c += 2) {
		h1 := sys->sprint("%s.hd%d", p, c);
		h2 := sys->sprint("%s.hp%d", p, c);
		cmd(sys->sprint("label %s -text {engine defaults}", h1));
		cmd(sys->sprint("label %s -text {proposed}", h2));
		cmd(sys->sprint("grid %s -row 0 -column %d -sticky w -padx 6 -pady 4", h1, c));
		cmd(sys->sprint("grid %s -row 0 -column %d -sticky w -padx 6 -pady 4", h2, c+1));
	}

	# group A: interactive targets       group B: fields
	targets := array[] of {
		("button",	"w", 1),
		("checkbutton",	"w", 1),
		("radio1",	"w", 1),
		("radio2",	"w", 1),
		("choicebutton","w", 1),
		("menubutton",	"w", 1),
		("label",	"w", 0),
	};
	fields := array[] of {
		("entry",	"we", 0),
		("listbox",	"we", 0),
		("scale",	"we", 0),
		("scrollbar",	"we", 0),
		("canvas",	"w", 0),
		("text",	"we", 0),
	};
	if((e := group(targets, 0)) != nil)
		return e;
	if((e = group(fields, 2)) != nil)
		return e;

	bb := tk->cmd(top_g, "grid bbox " + prefix_g);
	if(len bb > 0 && bb[0] != '!')
		cmd(sys->sprint("%s.cv configure -scrollregion {%s}", root_g, bb));
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
