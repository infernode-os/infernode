#
# osklayout -- the layouts of a keyboard on a screen.
#
# A layout is text (lib/osk/layouts/*; the format is in the header of
# lib/osk/layouts/dvorak): rows of keys, each key what it types (and
# types shifted) or a key of the keyboard's own (shift, del, sym, ...),
# and how wide it is.  This module reads one and places its keys in a
# rectangle; what a key does is wm/osk's.
#
# Include draw.m and kbdecode.m first.
#
Osklayout: module
{
	PATH:	con "/dis/lib/osklayout.dis";

	# what a key is
	Kchar,		# types c (shifted: shifted)
	Kshift,
	Kdel,
	Kenter,
	Kspace,
	Kctrl,		# the next key typed is a control character
	Klayer,		# goes to the layer name: sym, more, abc
	Knext,		# the next letters' layout
	Kspecial:	# types c, a key of keyboard.h's (an arrow, Home) or tab or esc
		con iota;

	Lkey: adt {
		kind:	int;
		c:	int;
		shifted:	int;
		name:	string;		# its word in the layout (shift, sym, ...), or nil
		width:	real;		# in keys
		r:	Draw->Rect;	# where it is, once placed
		row:	int;
	};

	Layout: adt {
		name:	string;
		rows:	array of array of ref Lkey;
		units:	real;		# the widest row, in keys

		# a layout from its text; name is what it is called
		parse:	fn(name, text: string): (ref Layout, string);
		read:	fn(path: string): (ref Layout, string);
		# put the keys in r, the rows its height shared out
		place:	fn(l: self ref Layout, r: Draw->Rect);
		# the key at p, or nil: the nearest in p's row, so the gaps
		# between keys and the ends of a short row belong to a key
		keyat:	fn(l: self ref Layout, p: Draw->Point): ref Lkey;
		# the keys a decoder works on: those typing letters and '
		dkeys:	fn(l: self ref Layout): array of Kbdecode->Key;
	};

	init:	fn();
	# the long-press offers: (key's character, its alternates) from
	# lib/osk/alternates' text
	alternates:	fn(text: string): list of (int, string);
};
