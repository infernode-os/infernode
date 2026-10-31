Wmlib: module
{
	PATH:		con "/dis/lib/wmlib.dis";

	init:		fn();
	makedrawcontext: fn(): ref Draw->Context;
	importdrawcontext: fn(devdraw, mntwm: string): (ref Draw->Context, string);
	connect:	fn(ctxt: ref Draw->Context): ref Draw->Wmcontext;
	reshape:	fn(w: ref Draw->Wmcontext, name: string, r: Draw->Rect, i: ref Draw->Image, how: string): ref Draw->Image;
	startinput:	fn(w: ref Draw->Wmcontext, devs: list of string): string;	# could be part of connect?
	wmctl:	fn(w: ref Draw->Wmcontext, request: string): (string, ref Draw->Image, string);

	# The window frame, the same for every window (tkclient and
	# wmclient alike), as rio's: a Border-wide line in the theme's
	# windowborder, drawn inside the window's edge.  A press on it is
	# the window manager's (wm/wm), rio's way: button 1 or 2 reshapes
	# from the nearest edge or corner, button 3 moves.
	Border:	con 4;
	# Does the window manager frame and place this client's window
	# itself (Lucifer's presentation zone, a Matrix pane)?  Then the
	# client draws no frame.  A wm that does not know the request
	# (wm/wm) leaves framing to the client.
	embedded:	fn(w: ref Draw->Wmcontext): int;
	# Tell the window manager the window's label (its title), as rio's
	# /dev/label: wm/wm shows it in its menu of hidden windows.  A
	# window manager that does not want it may refuse; that is ignored.
	setlabel:	fn(w: ref Draw->Wmcontext, label: string);
#	wmtoken:	fn(w: ref Draw->Wmcontext): string;
	snarfput:	fn(buf: string);
	snarfget:	fn(): string;

	# XXX these don't really belong here, but where should they go?
	splitqword:	fn(s: string, e: int): ((int, int), int);
	qslice:		fn(s: string, r: (int, int)): string;
	qword:		fn(s: string, e: int): (string, int);
	s2r:			fn(s: string, e: int): (Draw->Rect, int);
};
