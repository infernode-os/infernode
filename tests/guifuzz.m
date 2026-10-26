#
# Random use of a GUI through the pointer and keyboard: the part of a
# fuzzer that is not the application's.  An application's fuzzer
# (tests/wmfuzz.b) sets the rectangle and the deadline, starts mouse and
# keys and its own client, and checks the application afterwards.
#
Guifuzz: module
{
	PATH:	con "/dis/tests/guifuzz.dis";

	x0, y0, x1, y1:	int;	# where the pointer goes
	deadline:	int;		# when input stops (sys->millisec)
	nmouse, nkeys:	int;	# actions made
	menureach:	int;	# how far below where a menu opens it is let go

	# input through /chan/uitest (wm/wm's) if uitest, else #m/pointer
	# and #c/keyboard; nil or why not
	init:	fn(seed: int, uitest: int): string;

	ptr:	fn(x, y, b: int);
	key:	fn(r: int);
	text:	fn(s: string);
	pause:	fn();
	rand:	fn(n: int): int;
	rx:	fn(): int;
	ry:	fn(): int;

	# random clicks, drags, chords, the wheel, menus, and a scroll bar
	# down the left edge; done when the deadline passes
	mouse:	fn(seed: int, done: chan of int);
	# random keys: one of special, or a word, or a letter, or one of punct
	keys:	fn(seed: int, special: array of int, words: array of string, punct: string, done: chan of int);

	# BROKEN (a proc died) printed, and the deadline brought in; or,
	# when no proc runs the module modname, the application gone:
	# exited set, and the deadline brought in
	watch:	fn(modname: string);
	exited:	int;
	broken:	fn(): int;
	dumpprocs:	fn();
	timeout:	fn(ms: int): chan of int;

	readfile:	fn(f: string): string;
	writefile:	fn(f, s: string): int;
	contains:	fn(s, t: string): int;
	halt:	fn();
};
