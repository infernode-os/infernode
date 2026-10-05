Dat : module {
	PATH : con "/dis/xenith/dat.dis";

	init : fn(mods : ref Mods);

	Mods : adt {
		sys : Sys;
		bufio : Bufio;
		draw : Draw;
		styx : Styx;
		styxaux : Styxaux;
		xenith : Xenith;
		gui : Gui;
		graph : Graph;
		dat : Dat;
		framem : Framem;
		utils : Utils;
		regx : Regx;
		scroll : Scroll;
		textm : Textm;
		filem : Filem;
		windowm : Windowm;
		rowm : Rowm;
		columnm : Columnm;
		bufferm : Bufferm;
		diskm : Diskm;
		exec : Exec;
		look : Look;
		timerm : Timerm;
		fsys : Fsys;
		xfidm : Xfidm;
		plumbmsg : Plumbmsg;
		edit: Edit;
		editlog: Editlog;
		editcmd: Editcmd;
		asyncio: Asyncio;
	};

	SZSHORT : con 2;
	SZINT : con 4;

	FALSE, TRUE, XXX : con iota;

	CHAPPEND : con 16r40000000;

	EM_NORMAL, EM_RAW, EM_MASK : con iota;

	Qdir,Qxenith,Qcons,Qconsctl,Qdraw,Qeditout,Qindex,Qlabel,Qnew,QWaddr,QWbody,QWconsctl,QWctl,QWcolors,QWdata,QWedit,QWeditout,QWevent,QWimage,QWrdsel,QWwrsel,QWtag,QMAX : con iota;

	Blockincr : con 256;
	Maxblock : con 8*1024;
	NRange : con 10;
	Infinity : con 16r7fffffff; 	# huge value for regexp address

	# fbufalloc() guarantees room off end of BUFSIZE
	MAXRPC : con 8192+Styx->IOHDRSZ;
	BUFSIZE : con MAXRPC;
	EVENTSIZE : con 256;
	PLUMBSIZE : con 1024*64;
	Margin : con 4;		# margin around text
	Maxtab : con 4;		# size of a tab, in units of the '0' character
	
	Empty: con 0;
	Null : con '-';
	Delete : con 'd';
	Insert : con 'i';
	Replace: con 'r';
	Filename : con 'f';

	# editing
	Inactive, Inserting, Collecting: con iota;

	# alphabets
	ALPHA_LATIN: con '\0';
	ALPHA_GREEK: con '*';
	ALPHA_CYRILLIC: con '@';
		
	Kscrollup: con 16re050;
	Kscrolldown: con 16re051;

	Astring : adt {
		s : string;
	};

	Lock : adt {
		cnt : int;
		chann : chan of int;

		init : fn() : ref Lock;
		lock : fn(l : self ref Lock);
		unlock : fn(l : self ref Lock);
		locked : fn(l : self ref Lock) : int;
	};

# 	Lockx : adt {
#		sem : ref Lock->Semaphore;
#
#		init : fn() : ref Lockx;
#		lock : fn(l : self ref Lockx);
#		unlock : fn(l : self ref Lockx);
#	};

	Ref : adt {
		l : ref Lock;
		cnt : int;

		init : fn() : ref Ref;
		inc : fn(r : self ref Ref) : int;
		dec : fn(r : self ref Ref) : int;
		refx : fn(r : self ref Ref) : int;
	};

	Runestr : adt {
		r: string;
		nr: int;
	};

	Range : adt {
		q0 : int;
		q1 : int;
	};

	Block : adt {
		addr : int;			# disk address in bytes
		n : int;			# number of used runes in block
		next : cyclic ref Block;	# pointer to next in free list
	};

	Timer : adt {
		dt : int;
		c : chan of int;
		next : cyclic ref Timer;
	};

	# Scroll state for non-blocking scroll (Phase 5b)
	Scrollstate : adt {
		active : int;           # Is scrolling active?
		but : int;              # Button being used (1, 2, or 3)
		t : ref Textm->Text;    # Text being scrolled
		oldp0 : int;            # Last position to avoid redundant updates
		first : int;            # First scroll event (for debounce)
		timer : ref Timer;      # Current throttle timer
	};

	Command : adt {
		pid : int;
		name : string;
		text : string;
		av : list of string;
		iseditcmd: int;
		md : ref Mntdir;
		next : cyclic ref Command;
	};

	Dirtab : adt {
		name : string;
		qtype : int;
		qid : int;
		perm : int;
	};

	Mntdir : adt {
		id : int;
		refs : int;
		dir : string;
		ndir : int;
		next : cyclic ref Mntdir;
		nincl : int;
		incl : array of string;
	};

	# Async console write message — carries Mntdir so warning()
	# can target the correct per-directory +Errors window.
	ConsMsg : adt {
		md : ref Mntdir;
		text : string;
	};

	Fid : adt {
		fid : int;
		busy : int;
		open : int;
		qid : Sys->Qid;
		w : cyclic ref Windowm->Window;
		dir : array of Dirtab;
		next : cyclic ref Fid;
		mntdir : ref Mntdir;
		nrpart : int;
		rpart : array of byte;
	};

	Rangeset : type array of Range;

	Expand : adt {
		q0 : int;
		q1 : int;
		name : string;
		bname : string;
		jump : int;
		at : ref Textm->Text;
		ar : string;
		a0 : int;
		a1 : int;
	};

	Dirlist : adt {
		r : string;
		wid : int;
	};

	Reffont : adt {
		r : ref Ref;
		f : ref Draw->Font;

		get : fn(p : int, q : int, r : int, b : string) : ref Reffont;
		close : fn(r : self ref Reffont);
	};

	Cursor : adt {
		hot : Draw->Point;
		size : Draw->Point;
		bits : array of byte;
	};

	Smsg0 : adt {
		msize : int;
		version : string;
		iounit: int;
		qid : Sys->Qid;
		count : int;
		data : array of byte;
		stat : Sys->Dir;
		qids: array of Sys->Qid;
	};

	# loadfile function ptr

	BUFL, READL: con iota;

	# allwindows pick type

	Looper: adt{
		cp: ref Edit->Cmd;
		XY: int;
		w: array of ref Windowm->Window;
		nw: int;
	};	# only one; X and Y can't nest

	Tofile: adt {
		f: ref Filem->File;
		r: ref Edit->String;
	};

	Filecheck: adt{
		f: ref Filem->File;
		r: string;
		nr: int;
	};

	Allwin: adt{
		pick{
			LP => lp: ref Looper;
			FF => ff: ref Tofile;
			FC => fc: ref Filecheck;
		}
	};

	# in pixels, so times $displayscale (setscale): 12, 4 and 2 at 1x
	Scrollwid : int;	# width of scroll bar
	Scrollgap : int;	# gap right of scroll bar
	Border : int;		#  line between rows, cols, windows
	Mincolwid : int;	# narrowest a column is dragged

	globalincref: int;
	globalautoindent: int;
	seq : int;
	maxtab : int;
	mouse : ref Draw->Pointer;
	reffont : ref Reffont;
	modbutton : ref Draw->Image;
	colbutton : ref Draw->Image;
	button : ref Draw->Image;
	arrowcursor, boxcursor : ref Cursor;
	row : ref Rowm->Row;
	disk : ref Diskm->Disk;
	seltext : ref Textm->Text;
	argtext : ref Textm->Text;
	mousetext : ref Textm->Text; 	# global because Text.close needs to clear it
	typetext : ref Textm->Text;		# ditto
	barttext : ref Textm->Text;		# shared between mousetask and keyboardtask
	bartflag : int;
	activewin : ref Windowm->Window;
	activecol : ref Columnm->Column;
	nullrect : Draw->Rect;
	home : string;
	plumbed : int;

	ckeyboard : chan of int;
	cmouse : chan of ref Draw->Pointer;
	# Buffered channels to prevent spawned commands from blocking
	cwait : chan of string;           # [16] buffer set in xenith.b
	ccommand : chan of ref Command;   # [8] buffer set in xenith.b
	ckill : chan of string;           # [4] buffer set in xenith.b
	cxfidalloc : chan of ref Xfidm->Xfid;  # unbuffered - synchronous
	cxfidfree : chan of ref Xfidm->Xfid;   # [8] buffer set in xenith.b
	cerr : chan of string;            # [32] buffer set in xenith.b
	ccons : chan of ref ConsMsg;      # [64] async console writes from Xfid
	cplumb : chan of ref Plumbmsg->Msg;    # [8] buffer set in xenith.b
	cedit: chan of int;               # [1] buffer set in xenith.b

	# Async I/O results channel - set by asyncio module
	casync: chan of ref Asyncio->AsyncMsg;

	# Global scroll state for non-blocking scroll
	scrollstate: ref Scrollstate;
};
