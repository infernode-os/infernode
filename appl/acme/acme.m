Acme : module {
	PATH : con "/dis/acme.dis";

	RELEASECOPY : con 1;

	M_LBUT : con 1;
	M_MBUT : con 2;
	M_RBUT : con 4;
	M_TBS : con 8;
	M_PLUMB : con 16;
	M_DOUBLE : con 256;
	# Quit, help and resize are sent down the mouse channel with the
	# pointer's own events, so they must not share a bit with any
	# button: the emulator sends 8 and 16 for the wheel, 32 and 64 for
	# scrolling left and right (which a trackpad does with every
	# vertical scroll), and 256 for a double click. M_QUIT was 32, and
	# scrolling quit the editor.
	M_QUIT : con 1<<16;
	M_HELP : con 1<<17;
	M_RESIZE : con 1<<18;

	textcols, tagcols : array of ref Draw->Image;
	but2col, but3col, but2colt, but3colt : ref Draw->Image;
	colbordercol, rowbordercol, modbutcol : ref Draw->Image;

	acmectxt : ref Draw->Context;
	keyboardpid, mousepid, timerpid, fsyspid : int;
	fontnames : array of string;
	wdir : string;

	init : fn(ctxt : ref Draw->Context, argv : list of string);
	timing : fn(s : string);
	frgetmouse : fn();
	get : fn(p, q, r : int, b : string) : ref Dat->Reffont;
	close : fn(r : ref Dat->Reffont);
	acmeexit : fn(err : string);
	getsnarf : fn(); 
	putsnarf : fn();
};