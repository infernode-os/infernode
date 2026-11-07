#
# softkbd.m — ask for a keyboard on the screen for a text field.
#
# The requests go to InferNode's own keyboard (wm/osk, its files at
# /mnt/osk): show, hide, rect and mode on /mnt/osk/ctl.  With it not
# running they are /dev/consctl's verbs, which do nothing now: the
# system's keyboard (iOS's, Android's) is never shown, whatever asks for
# it (emu/port/draw-sdl3.c, apply_softkbd), so the view is never slid
# above it either.  The verbs remain for the callers that write them:
#
#   "kbd on"           — a field at the bottom has the keyboard
#   "kbd ontop"        — a field filling the screen has it
#   "kbd off"          — none has
#   "kbd rect x y w h" — where the focused field is, screen pixels
#
# Centralised here so every text app/widget uses one wire format.
# softkbd(2).
#

Softkbd: module {
	PATH: con "/dis/lib/softkbd.dis";

	# Modes for show(). Match the encoding setsoftkbd uses in
	# emu/port/draw-sdl3.c: 0 hide, 1 slide, 2 keep-top.
	HIDE:    con 0;
	SLIDE:   con 1;	# bottom input — SDL slides the view up
	KEEPTOP: con 2;	# workspace text app — view top stays pinned

	# Loads sys. Returns nil on success or an error string. Safe to
	# call multiple times.
	init: fn(): string;

	# Show or hide the soft keyboard. Same effect as writing the
	# legacy verbs ("kbd on" / "kbd ontop" / "kbd off") directly.
	# Non-mobile builds are silently no-op.
	show: fn(mode: int);

	# Where the focused field is, in screen pixels: for a keyboard the
	# view must be moved above.  wm/osk is docked, the field already
	# above it, and takes it without acting on it.  w<=0 or h<=0: none.
	set_rect: fn(x, y, w, h: int);

	# Same as set_rect(0,0,0,0).
	clear_rect: fn();

	# What the focused text is: prose (1), whose words a keyboard on
	# the screen may put right and capitalise, or not (0: a shell's
	# commands, code).  Only InferNode's own keyboard (wm/osk) takes
	# it; the system's has no such hint here.
	mode: fn(prose: int);
};
