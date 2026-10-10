Windowm : module {
	PATH : con "/dis/xenith/wind.dis";

	init : fn(mods : ref Dat->Mods);

	Window : adt {
		qlock : ref Dat->Lock;
		refx : ref Dat->Ref;
		tag : 	cyclic ref Textm->Text;
		body : cyclic ref Textm->Text;
		r : Draw->Rect;
		isdir : int;
		isscratch : int;
		filemenu : int;
		dirty : int;
		autoindent: int;
		id : int;
		addr : Dat->Range;
		limit : Dat->Range;
		nopen : array of byte;
		nomark : int;
		noscroll : int;
		echomode : int;
		wrselrange : Dat->Range;
		rdselrange : Dat->Range;	# saved selection range for Edit pipe commands
		rdselfd : ref Sys->FD;
		col : cyclic ref Columnm->Column;
		eventx : cyclic ref Xfidm->Xfid;
		events : string;
		nevents : int;
		owner : int;
		maxlines :	int;
		dlp : array of ref Dat->Dirlist;
		ndl : int;
		putseq : int;
		nincl : int;
		incl : array of string;
		reffont : ref Dat->Reffont;
		ctllock : ref Dat->Lock;
		ctlfid : int;
		dumpstr : string;
		dumpdir : string;
		dumpid : int;
		colorstr : string;	# per-window color overrides, nil = use global
		rendermode : int;	# 0 = raw text, 1 = formatted view (Render on other text)
		contentdata : array of byte;	# the raw text while formatted
		doc : ref Docview->Doc;	# the window's document (docview(2)), or nil
		utflastqid : int;
		utflastboff : int;
		utflastq : int;
		tagsafe : int;
		tagexpand : int;
		taglines : int;
		tagtop : Draw->Rect;
		creatormnt : int;	# Mount session ID that created this window (0 = user/Xenith)
		asyncload : ref Asyncio->AsyncOp;	# Current async file load operation (nil = none)
		asyncsave : ref Asyncio->AsyncOp;	# Current async file save operation (nil = none)
		savename : string;	# Name being saved to (for async save completion)

		init : fn(w : self ref Window, w0 : ref Window, r : Draw->Rect);
		lock : fn(w : self ref Window, n : int);
		lock1 : fn(w : self ref Window, n : int);
		unlock : fn(w : self ref Window);
		typex : fn(w : self ref Window, t : ref Textm->Text, r : int);
		undo : fn(w : self ref Window, n : int);
		setname : fn(w : self ref Window, r : string, n : int);
		settag : fn(w : self ref Window);
		settag1 : fn(w : self ref Window);
		commit : fn(w : self ref Window, t : ref Textm->Text);
		reshape : fn(w : self ref Window, r : Draw->Rect, n : int, keepextra: int) : int;
		close : fn(w : self ref Window);
		delete : fn(w : self ref Window);
		clean : fn(w : self ref Window, n : int, exiting : int) : int;
		dirfree : fn(w : self ref Window);
		event : fn(w : self ref Window, b : string);
		mousebut : fn(w : self ref Window);
		addincl : fn(w : self ref Window, r : string, n : int);
		cleartag : fn(w : self ref Window);
		ctlprint : fn(w : self ref Window, fonts : int) : string;
		applycolors : fn(w : self ref Window);
	};
};
