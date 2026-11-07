#
# icon.m — the interface's glyphs, drawn at any size in any colour
#
# The glyphs are SVG files in /icons/ui, one per name, from Tabler Icons
# (icons/ui/LIST says which, tools/update-icons.sh fetches them).  Each
# is drawn by readsvg at the size asked for, so it is sharp at any size
# and on any scale of display, and painted in a colour the caller gives,
# a theme's (lucitheme) as a rule, so a theme switch is a repaint.
#
# A drawn glyph is kept: asking again for a name at a size draws
# nothing.  The module needs the draw device in its name space.
#
Icon: module
{
	PATH:	con "/dis/lib/icon.dis";
	DIR:	con "/icons/ui";

	# d is the display the images are made on (a Toplevel's).
	init:	fn(d: ref Draw->Display): string;

	# The glyph's coverage at size by size pixels: a GREY8 image, 255
	# where the glyph is drawn and 0 where it is not, to draw through.
	mask:	fn(name: string, size: int): (ref Draw->Image, string);

	# The glyph painted in colour (RGBA32, as Draw->Display.color takes
	# it): an image of that colour and the mask to draw it through.
	paint:	fn(name: string, size, colour: int): (ref Draw->Image, ref Draw->Image, string);

	# Tk image tkname in t made the glyph painted in colour; made if t has
	# no image of that name, replaced (and so repainted wherever it is
	# shown) if it has.
	tkimage:	fn(t: ref Tk->Toplevel, tkname, name: string, size, colour: int): string;

	# tkimage for each (tkname, name, size) in set, in the current
	# theme's text colour (lucitheme); called again after a theme
	# switch, it repaints them.  Every image is made, blank where its
	# glyph cannot be drawn; the error is the first such.
	tkglyphs:	fn(t: ref Tk->Toplevel, set: array of (string, string, int)): string;
};
