implement TkGallery;

#
# tk-gallery — Matrix Tk-hosted widget review gallery.
#
# Every visual Tk widget class, twice, on ONE shared grid so the two
# treatments align row for row: column 0 exactly as the engine's
# defaults render it (raised/sunken bevels, text-tight targets),
# column 1 the proposed InferNode treatment — flat relief (2D, no
# bevels) and real touch surfaces on the interactive widgets (grid
# -ipadx/-ipady grows the hit target, per the 44pt/48dp conventions).
#
# Known engine limits this gallery makes visible (libtk follow-ups if
# the flat treatment is adopted): there is no "solid" relief, so a
# flat button has no outline at all; radiobutton indicators draw as
# squares identical to checkbuttons; entry/label text is top-anchored
# when the widget is taller than the font; the pressed state
# hardcodes a sunken bevel.
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
DECO: con " -relief flat -borderwidth 1";
IPAD: con " -ipadx 8 -ipady 5";

cmd(s: string): string
{
	e := tk->cmd(top_g, s);
	if(e != nil && len e > 0 && e[0] == '!')
		return "tk: " + e + " on " + s;
	return nil;
}

# Create one widget of the row's class at path p; deco != nil applies
# the proposed treatment.  var distinguishes the two columns' radio
# groups and menus.
mkwidget(class, p, var, deco: string): string
{
	c := "";
	case class {
	"button" =>
		c = sys->sprint("button %s -text {button}%s", p, deco);
	"checkbutton" =>
		c = sys->sprint("checkbutton %s -text {checkbutton}%s", p, deco);
	"radio1" =>
		c = sys->sprint("radiobutton %s -text {radio one} -variable %s -value 1%s", p, var, deco);
	"radio2" =>
		c = sys->sprint("radiobutton %s -text {radio two} -variable %s -value 2%s", p, var, deco);
	"choicebutton" =>
		c = sys->sprint("choicebutton %s -values {alpha beta gamma}%s", p, deco);
	"menubutton" =>
		m := prefix_g + ".mnu" + var;
		if((e := cmd(sys->sprint("menu %s%s", m, deco))) != nil)
			return e;
		cmd(sys->sprint("%s add command -label {first item}", m));
		cmd(sys->sprint("%s add command -label {second item}", m));
		c = sys->sprint("menubutton %s -text {menubutton} -menu %s%s", p, m, deco);
	"label" =>
		c = sys->sprint("label %s -text {label}%s", p, deco);
	"entry" =>
		c = sys->sprint("entry %s -width %d%s", p, W, deco);
	"listbox" =>
		c = sys->sprint("listbox %s -width %d -height 52%s", p, W, deco);
	"scale" =>
		c = sys->sprint("scale %s -orient horizontal -length %d -from 0 -to 100 -showvalue 1%s", p, W, deco);
	"scrollbar" =>
		c = sys->sprint("scrollbar %s -orient horizontal%s", p, deco);
	"canvas" =>
		c = sys->sprint("canvas %s -width %d -height 44%s", p, W, deco);
	"text" =>
		c = sys->sprint("text %s -width %d -height 52%s", p, W, deco);
	}
	if((e := cmd(c)) != nil)
		return e;

	# representative content / state so insets and bevels show in use
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

init(top: ref Toplevel, prefix, nil: string): string
{
	sys = load Sys Sys->PATH;
	tk = load Tk Tk->PATH;
	if(tk == nil)
		return sys->sprint("cannot load Tk: %r");
	top_g = top;
	root_g = prefix;

	# Scrolled-frame idiom: the gallery is taller than any likely
	# region, so the grid lives on a frame hosted as a canvas window
	# item, with a scrollbar driving yview.  (Also exercises canvas
	# and scrollbar for real.)
	cmd(sys->sprint("canvas %s.cv -yscrollcommand {%s.vs set}", prefix, prefix));
	cmd(sys->sprint("scrollbar %s.vs -command {%s.cv yview}", prefix, prefix));
	cmd(sys->sprint("frame %s.cv.body", prefix));
	cmd(sys->sprint("pack %s.vs -side right -fill y", prefix));
	cmd(sys->sprint("pack %s.cv -side left -fill both -expand 1", prefix));
	cmd(sys->sprint("%s.cv create window 0 0 -window %s.cv.body -anchor nw", prefix, prefix));
	prefix_g = prefix + ".cv.body";
	prefix = prefix_g;

	cmd(sys->sprint("label %s.hd -text {engine defaults}", prefix));
	cmd(sys->sprint("label %s.hp -text {flat + padded (proposed)}", prefix));
	cmd(sys->sprint("grid %s.hd -row 0 -column 0 -sticky w -padx 6 -pady 4", prefix));
	cmd(sys->sprint("grid %s.hp -row 0 -column 1 -sticky w -padx 6 -pady 4", prefix));

	# (class, sticky, padded-target?)
	rows := array[] of {
		("button",	"w", 1),
		("checkbutton",	"w", 1),
		("radio1",	"w", 1),
		("radio2",	"w", 1),
		("choicebutton","w", 1),
		("menubutton",	"w", 1),
		("label",	"w", 0),
		("entry",	"we", 0),
		("listbox",	"we", 0),
		("scale",	"we", 0),
		("scrollbar",	"we", 0),
		("canvas",	"w", 0),
		("text",	"we", 0),
	};
	for(i := 0; i < len rows; i++) {
		(class, sticky, target) := rows[i];
		dp := sys->sprint("%s.d%d", prefix_g, i);
		pp := sys->sprint("%s.p%d", prefix_g, i);
		if((e := mkwidget(class, dp, "d", "")) != nil)
			return e;
		if((e = mkwidget(class, pp, "p", DECO)) != nil)
			return e;
		ipad := "";
		if(target)
			ipad = IPAD;
		if((e = cmd(sys->sprint("grid %s -row %d -column 0 -sticky %s -padx 6 -pady 2", dp, i+1, sticky))) != nil)
			return e;
		if((e = cmd(sys->sprint("grid %s -row %d -column 1 -sticky %s -padx 6 -pady 2%s", pp, i+1, sticky, ipad))) != nil)
			return e;
	}

	# scroll over the body's full extent
	bb := tk->cmd(top_g, "grid bbox " + prefix_g);
	if(len bb > 0 && bb[0] != '!')
		cmd(sys->sprint("%s.cv configure -scrollregion {%s}", root_g, bb));
	return nil;
}

resize(nil: Draw->Rect)
{
	# grid reflows; nothing to do.
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
