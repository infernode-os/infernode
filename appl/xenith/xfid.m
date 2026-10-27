Xfidm : module {
	PATH : con "/dis/xenith/xfid.dis";

	Xnil, Xflush, Xwalk, Xopen, Xclose, Xread, Xwrite : con iota;

	init : fn(mods : ref Dat->Mods);

	newxfid : fn() : ref Xfid;
	xfidkill : fn();

	Xfid : adt {
		tid : int;
		fcall : ref Styx->Tmsg;
		next : cyclic ref Xfid;
		c : chan of int;
		f : cyclic ref Dat->Fid;
		buf : array of byte;
		flushed : int; 
		responded : int;	# its request answered

		ctl : fn(x : self ref Xfid);
		flush: fn(x : self ref Xfid);
		walk: fn(x : self ref Xfid, c: chan of ref Windowm->Window);
		open: fn(x : self ref Xfid);
		close: fn(x : self ref Xfid);
		read: fn(x : self ref Xfid);
		write: fn(x : self ref Xfid);
		ctlwrite: fn(x : self ref Xfid, w : ref Windowm->Window);
		eventread: fn(x : self ref Xfid, w : ref Windowm->Window);
		eventwrite: fn(x : self ref Xfid, w : ref Windowm->Window);
		indexread: fn(x : self ref Xfid);
		utfread: fn(x : self ref Xfid, t : ref Textm->Text, m : int, n : int, qid : int);
		runeread: fn(x : self ref Xfid, t : ref Textm->Text, m : int, n : int) : int;
		colorswrite: fn(x : self ref Xfid, w : ref Windowm->Window);
		imagewrite: fn(x : self ref Xfid, w : ref Windowm->Window);
		recover: fn(x : self ref Xfid, e : string);
	};
};
