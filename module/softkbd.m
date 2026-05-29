#
# softkbd.m — On-screen keyboard avoidance helper.
#
# Wraps the /dev/consctl verbs that the SDL3 iOS backend uses to control
# the soft keyboard and the keyboard-avoidance rect:
#
#   "kbd on"           — show, slide so the bottom input is visible
#                        (legacy default: 56pt strip at the bottom)
#   "kbd ontop"        — show, keep the top pinned (workspace text app)
#   "kbd off"          — hide
#   "kbd rect x y w h" — focused-widget rect, window points. Overrides
#                        the legacy top/bottom heuristic so SDL slides
#                        the *actual* widget above the keyboard — the
#                        INFR-166 fix.
#
# Centralised here so every text app/widget that wants to play nicely
# with the soft keyboard uses the same wire format. The bridge below
# devcons.c parses the verbs; iOS-side SDL_SetTextInputArea does the
# slide. Desktop / Linux SDL3 silently no-ops.
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

	# Tell the GUI backend the focused widget's bounds in window
	# points. On iOS, SDL_SetTextInputArea is updated so the system
	# slides the view to keep this rect above the keyboard. Calling
	# with w<=0 or h<=0 clears the override (the legacy
	# top-or-bottom heuristic comes back).
	set_rect: fn(x, y, w, h: int);

	# Convenience: clear the override. Same as set_rect(0,0,0,0).
	clear_rect: fn();
};
