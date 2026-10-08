Samtk: module
{

	PATH:		con "/dis/wm/samtk.dis";

	# button 2, as in samterm/menu.c less plumb and exch (see sam(1))
	Cut,
	Paste,
	Snarf,
	Look,
	Search,
	NMENU2: con iota;
	Send: con Search;	# the command window's last item

	# button 3, as in samterm/menu.c; the file names follow these
	New,
	Zerox,
	Resize,
	Close,
	Write,
	NMENU3: con iota;

	init:		fn(ctxt: ref Context);

	# layers: samterm's flayer.c
	newflayer:	fn(tag, tp: int, r: Draw->Rect): ref Flayer;
	flclose:	fn(fl: ref Flayer);
	flwhich:	fn(p: Draw->Point): ref Flayer;
	flupfront:	fn(fl: ref Flayer);
	flborder:	fn(fl: ref Flayer, wide: int);
	flresize:	fn(): int;
	current:	fn(fl: ref Flayer);
	screenr:	fn(): Draw->Rect;

	# the pointer, while the main loop holds it
	getr:		fn(): (int, Draw->Rect);
	getpick:	fn(): (int, Draw->Point);
	buttonsup:	fn();
	setcursor:	fn(name: string);
	lockcursor:	fn();

	menus:		fn();
	hsetpat:	fn(s: string);
	settitle:	fn(t: ref Text, s: string);
	titlectl:	fn(menu: string);

	append:		fn(fls: list of ref Flayer, fl: ref Flayer):
				list of ref Flayer;
	dellist:	fn(fls: list of ref Flayer, fl: ref Flayer):
				list of ref Flayer;
	buttonselect:	fn(fl: ref Flayer, s: string): int;
	coord2pos:	fn(t: ref Text, fl: ref Flayer, s: string): int;
	charofy:	fn(t: ref Text, fl: ref Flayer, y: int): int;
	scrollp0:	fn(t: ref Text, fl: ref Flayer, but, y: int): int;
	flclear:	fn(fl: ref Flayer);
	fldelete:	fn(fl: ref Flayer, l1, l2: int);
	fldelexcess:	fn(fl: ref Flayer);
	flinsert:	fn(fl: ref Flayer, l: int, s: string);
	panic:		fn(s: string);
	resize:		fn(fl: ref Flayer);
	setdot:		fn(fl: ref Flayer, l1, l2: int);
	setscrollbar:	fn(t: ref Text, fl: ref Flayer);
	whichmenu:	fn(tag: int): int;
	whichtext:	fn(tag: int): int;
};
