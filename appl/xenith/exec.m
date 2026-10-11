Exec : module {
	PATH : con "/dis/xenith/exec.dis";

	snarfbuf : ref Bufferm->Buffer;

	init : fn(mods : ref Dat->Mods);

	fontx : fn(et : ref Textm->Text, t : ref Textm->Text, argt : ref Textm->Text, arg : string, narg : int);
	get : fn(et, t, argt : ref Textm->Text, flag1 : int, arg : string, narg : int);
	put : fn(et, argt : ref Textm->Text, arg : string, narg : int);
	cut : fn(et, t : ref Textm->Text, flag1, flag2 : int);
	paste : fn(et, t : ref Textm->Text, flag1 : int, flag2: int);

	getarg : fn(t : ref Textm->Text, m : int, n : int) : (string, string, int);
	execute : fn(t : ref Textm->Text, aq0, aq1, external : int, argt : ref Textm->Text);
	# s executed as a word button 2 chose in t's window: a built-in, a
	# document's command, or a command run (a word on a document's drawing)
	executeword : fn(t : ref Textm->Text, s : string);
	run : fn(w : ref Windowm->Window, s : string, rdir : string, ndir : int, newns : int, argaddr : string, arg : string, ise: int);
	undo: fn(t: ref Textm->Text, flag: int);
	putfile: fn(f: ref Filem->File, q0: int, q1: int, r: string);
};