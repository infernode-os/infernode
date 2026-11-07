#
# touchgest.m -- what a finger on a touch screen means as a pointer
#
# A touch screen has a finger where a mouse has a button, and no other
# buttons and no wheel.  A driver that reads one (the Pi's panel,
# os/init/touch.b; a USB touchscreen, os/init/mouseusb.b) gives each
# frame's fingers to a Gest and writes what comes back to /dev/pointer,
# so a finger means one thing whatever the screen, and the same as on a
# phone, where emu/port/draw-sdl3.c makes it of SDL's touches:
#
#	One finger is button 1, held while it is down, the pointer
#	following it.
#
#	One held still for Longms is button 3: button 1 goes up and
#	button 3 down where the finger is, held until it lifts.  That is
#	every context menu: hold, the menu shows, slide to an item, lift
#	to choose it.  Moving more than slop before then makes it a drag;
#	lifting before then, a tap.
#
#	Two dragged are the wheel: a tick (button 8 or 16 pressed and
#	released, as a USB mouse's wheel is delivered) where the fingers
#	are, for each step they move together; up shows what is below, as
#	a phone scrolls.  Button 1, if the first finger pressed it, goes
#	up first, and the gesture lasts until every finger is up, so the
#	last to lift does not press where it happens to be.
#
# The pointer events are /dev/pointer's text (pointer(3)): "m x y b" in
# the screen's pixels, or "a x y b" in fractions of it (0 to 65535),
# for a driver that does not know how big the screen is; slop and step
# are in the same units.
#
Touchgest: module
{
	PATH:	con "/dis/lib/touchgest.dis";

	Longms:	con 500;	# a finger held this long is button 3

	Gest: adt {
		verb:	string;	# "m" (pixels) or "a" (fractions of the screen)
		slop:	int;	# how far a held finger may wander and still be held
		step:	int;	# how far two fingers move for a wheel tick

		down:	int;	# a button is held: btn
		btn:	int;	# 1, or 4 once a held finger became button 3
		armed:	int;	# the finger may yet be held long enough
		t0:	int;	# when it landed
		x0, y0:	int;	# where
		multi:	int;	# a two-finger drag, until every finger is up
		nf:	int;	# fingers in the last frame
		sy:	int;	# the fingers' y when last counted
		acc:	int;	# distance moved not yet a tick
		x, y:	int;	# where the pointer is

		new:	fn(verb: string, slop, step: int): ref Gest;

		# A frame's fingers, the first the pointer, at now (msec):
		# what to write to /dev/pointer, in order.  nil: none down.
		frame:	fn(g: self ref Gest, pts: list of (int, int), now: int): list of string;

		# Time passing with nothing new from the screen (a finger
		# held still sends nothing): button 3, once it is due.
		tick:	fn(g: self ref Gest, now: int): list of string;

		# When tick should next be called, if nothing comes before:
		# the msec time at which a held finger becomes button 3, or
		# -1 if no finger is waiting to.
		due:	fn(g: self ref Gest): int;
	};
};
