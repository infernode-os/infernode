include "tk.m";
include "wmlib.m";

Samterm: module
{

	PATH:		con "/dis/wm/sam.dis";

	Section: adt
	{
		nrunes:	int;
		text:	string;		# if null, we haven't got it
	};

	Range: adt {
		first, last: int;
	};

	# A layer: one window on a file, inside sam's single toplevel.
	# As in Plan 9 sam (flayer.h), layers overlap and the current one
	# is in front.
	Flayer: adt {
		tag:		int;
		t:		ref Tk->Toplevel;	# sam's toplevel; nil once closed
		tkwin:		string;	# file name the layer shows
		scope:		Range;	# part of file in range
		dot:		Range;	# cursor position wrt file, not scope
		width:		int;	# width of its text
		lineheigth:	int;	# height of a single line (for resize)
		lines:		int;	# window height in lines
		scrollbar:	Range;	# current position of scrollbar
		typepoint:	int;	# -1, or pos of first unsent char typed
		id:		int;	# unique; names the layer's widgets and channels
		w:		string;	# .c.f<id>.i; its text is w.t, its scroll bar w.s
		r:		Draw->Rect;	# sam's l->entire, in canvas coordinates
	};

	Text: adt {
		tag:		int;
		lock:		int;
		flayers:	list of ref Flayer;	# hd flayers is t->front
		nrunes:		int;
		sects:		list of ref Section;
		state:		int;
	};

	LDirty:	con 2;		# typed and not yet sent: sam's "modified"
	NL:	con 5;		# windows on one file, as in samterm.h

	Menu: adt {
		tag:		int;
		name:		string;
		text:		ref Text;
		mod:		int;	# ' ' or '\'', from Hdirty and Hclean
	};

	# what the window's pointer is doing (mouse ownership, see samtk pump)
	Normal,		# Tk has it; samtk takes buttons 2 and 3 for menus
	Grab:	con iota;	# the main loop has it: sweeping, or picking a layer

	Context: adt {
		ctxt:		ref Draw->Context;
		tag:		int;	# globally unique tag generator
		lock:		int;	# global lock: sam's hostlock

		keysel:		array of chan of string;	# per layer, as flayers
		buttonsel:	array of chan of string;
		flayers:	array of ref Flayer;

		menus:		array of ref Menu;
		texts:		array of ref Text;

		cmd:		ref Text;	# sam command window
		which:		ref Flayer;	# current flayer (sam or work)
		work:		ref Flayer;	# current work flayer

		pgrp:		int;		# process group
		logfd:		ref FD;

		# sam is one window.  sam.b and samstub.b each load their own
		# Samtk, so what the layers share lives here, not in Samtk.
		top:		ref Tk->Toplevel;	# the window; .c holds the layers
		wmctl:		chan of string;	# window manager, and canvas resizes
		mousec:		chan of string;	# pointer, from samtk's pump
		menu2c:		chan of string;	# menu 2 choices
		menu3c:		chan of string;	# menu 3 choices
		mode:		int;		# Normal or Grab
		mbuttons:	int;		# buttons down, as samtk's pump last saw
		order:		list of ref Flayer;	# front to back: sam's llist
		nextid:		int;		# next Flayer.id
		size:		Draw->Point;	# canvas size the layers were laid out in
		pat:		string;		# last pattern, for menu 2
		hit2:		int;		# each menu's lasthit
		hit2c:		int;
		hit3:		int;
	};

	init:		fn(ctxt: ref Draw->Context, args: list of string);
};
