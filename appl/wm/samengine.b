implement Samengine;

#
# Native Dis sam engine — the "host" half of the sam split, ported to
# run inside Inferno instead of shelling out to a host `sam -R` binary.
#
# It speaks the Plan 9 sam terminal protocol (see samstub.m) to the
# samterm front end over a byte pipe.  Framing, little-endian:
#
#	[mtype:1][mcount:2][mdata:mcount]
#
# The terminal keeps a "rasp": a sparse mirror of each file where runes
# it has been told about are present and everything else is a hole.  The
# host owns the authoritative text and feeds the terminal lazily:
#
#	Hgrow(tag,0,N)   tell the terminal the file is N runes (all hole)
#	Horigin(tag,0)   position the frame; the terminal then asks for the
#	                 visible lines with Trequest(tag,pos,count)
#	Hdata(tag,pos,s) fill a requested chunk (<= TBLOCKSIZE runes)
#
# Locking: every T message after which the terminal calls setlock()
# (Tstartcmdfile, Tstartfile, Trequest, Torigin, Twrite, Tclose, Tlook,
# Tsearch, Tsend, Tdclick and a newline typed at the end of the command
# window) is answered by exactly one of Hunlock, Hdata or Horigin.
#
# The command language is sam's: the parser and address arithmetic
# follow Plan 9 sam's parse.c and address.c.  As in sam, a command's
# changes are logged against the unmodified text and applied together
# when it finishes, so loops like ,x/re/c/text/ address the original
# file and changes must be in sequence.  Each applied command is one
# step of undo.
#

include "sys.m";
	sys: Sys;
	FD: import Sys;

include "draw.m";

include "sh.m";

include "samrx.m";
	rx: Samrx;

include "samengine.m";

# samterm.m declares the Context/Text/Flayer/Section types referenced by
# samstub.m's signatures; the engine only needs them declared so it can
# pull in the shared protocol constants.
include "samterm.m";
	Context, Text, Flayer, Section: import Samterm;

include "samstub.m";
	Tversion, Tstartcmdfile, Tstartfile, Tstartnewfile,
	Trequest, Torigin, Tworkfile, Ttype, Tcut, Tpaste, Tsnarf,
	Twrite, Tclose, Tlook, Tsearch, Tsend, Tdclick, Tcheck,
	Tstartsnarf, Tsetsnarf, Tack, Texit,
	Hversion, Hbindname, Hnewname, Hmovname, Hcurrent, Hgrow, Hcheck,
	Hdata, Hgrowdata, Hcut, Hsetdot, Hmoveto, Horigin, Hunlock,
	Hdirty, Hclean, Hsetpat, Hdelname, Hclose, Hsnarflen, Hexit,
	VERSION, DATASIZE, TBLOCKSIZE: import Samstub;

# One change: replace text[p0:p1] with s.
Edit: adt {
	p0:	int;
	p1:	int;
	s:	string;
};

# One step of undo: edits in ascending order, non-overlapping, in the
# coordinates of the text they apply to.  id names the file state the
# batch produces (redo) or undoes (undo), for clean/dirty tracking.
Batch: adt {
	id:	int;
	edits:	array of ref Edit;
	typing:	int;		# a run of typing; later typing may extend it
};

# A file held by the host: the authoritative text (a rune string) plus
# the tag that identifies it in the terminal's menu and rasp.
File: adt {
	tag:	int;
	name:	string;
	text:	string;		# rune-indexed; len == nrunes
	rasp:	int;		# the terminal has a window (and a rasp) for it
	dirty:	int;		# differs from what was last read or written
	dot0:	int;		# current selection (dot), rune offsets
	dot1:	int;
	mark0:	int;		# k and ' address
	mark1:	int;
	undo:	list of ref Batch;
	redo:	list of ref Batch;
	cleanid:	int;	# undo id of the state last read or written
	closeok:	int;	# warned once about unsaved changes
	log:	list of ref Edit;	# pending changes of the running command
	nlog:	int;
	logend:	int;	# changes must not start before here
	dotedit:	int;	# dot after the command is log edit n; -1: dot0/dot1
	unread:	int;	# not read yet: sam reads a file when it is first used
};

# address: a parse tree as in sam's parse.c
Addr: adt {
	typ:	int;	# # l / ? " . $ + - ' , ; *
	num:	int;
	re:	string;
	left:	cyclic ref Addr;	# , ; left side
	next:	cyclic ref Addr;	# next simple address, or , ; right side
};

Cmd: adt {
	addr:	ref Addr;
	mtaddr:	ref Addr;	# m, t destination
	cmdc:	int;
	re:	string;		# nil: none given (x and X have defaults)
	text:	string;
	num:	int;
	flag:	int;
	sub:	cyclic ref Cmd;	# loop body; first command of a {} block
	next:	cyclic ref Cmd;	# next command in a {} block
};

aNo, aDot, aAll: con iota;

CDCMD: con -2;		# the two-letter command cd

Cmdtab: adt {
	cmdc:	int;
	text:	int;	# takes a/i/c text
	regexp:	int;	# takes a regular expression
	addr:	int;	# takes an address (m, t)
	defcmd:	int;	# default command if none given
	defaddr:	int;
	count:	int;	# takes a number; 2 allows a sign
	token:	string;	# argument runs to one of these characters
};

linex:	con "\n";
wordx:	con " \t\n";

cmdtab := array[] of {
	Cmdtab('\n',	0, 0, 0, 0,	aDot,	0, nil),
	Cmdtab('a',	1, 0, 0, 0,	aDot,	0, nil),
	Cmdtab('b',	0, 0, 0, 0,	aNo,	0, linex),
	Cmdtab('B',	0, 0, 0, 0,	aNo,	0, linex),
	Cmdtab('c',	1, 0, 0, 0,	aDot,	0, nil),
	Cmdtab('d',	0, 0, 0, 0,	aDot,	0, nil),
	Cmdtab('D',	0, 0, 0, 0,	aNo,	0, linex),
	Cmdtab('e',	0, 0, 0, 0,	aNo,	0, wordx),
	Cmdtab('f',	0, 0, 0, 0,	aNo,	0, wordx),
	Cmdtab('g',	0, 1, 0, 'p',	aDot,	0, nil),
	Cmdtab('i',	1, 0, 0, 0,	aDot,	0, nil),
	Cmdtab('k',	0, 0, 0, 0,	aDot,	0, nil),
	Cmdtab('m',	0, 0, 1, 0,	aDot,	0, nil),
	Cmdtab('n',	0, 0, 0, 0,	aNo,	0, nil),
	Cmdtab('p',	0, 0, 0, 0,	aDot,	0, nil),
	Cmdtab('q',	0, 0, 0, 0,	aNo,	0, nil),
	Cmdtab('r',	0, 0, 0, 0,	aDot,	0, wordx),
	Cmdtab('s',	0, 1, 0, 0,	aDot,	1, nil),
	Cmdtab('t',	0, 0, 1, 0,	aDot,	0, nil),
	Cmdtab('u',	0, 0, 0, 0,	aNo,	2, nil),
	Cmdtab('v',	0, 1, 0, 'p',	aDot,	0, nil),
	Cmdtab('w',	0, 0, 0, 0,	aAll,	0, wordx),
	Cmdtab('x',	0, 1, 0, 'p',	aDot,	0, nil),
	Cmdtab('y',	0, 1, 0, 'p',	aDot,	0, nil),
	Cmdtab('X',	0, 1, 0, 'f',	aNo,	0, nil),
	Cmdtab('Y',	0, 1, 0, 'f',	aNo,	0, nil),
	Cmdtab('!',	0, 0, 0, 0,	aNo,	0, linex),
	Cmdtab('>',	0, 0, 0, 0,	aDot,	0, linex),
	Cmdtab('<',	0, 0, 0, 0,	aDot,	0, linex),
	Cmdtab('|',	0, 0, 0, 0,	aDot,	0, linex),
	Cmdtab('=',	0, 0, 0, 0,	aDot,	0, linex),
	Cmdtab(CDCMD,	0, 0, 0, 0,	aNo,	0, wordx),
};

MORE:	con "sam:more";		# command incomplete; wait for more input

io:		ref FD;
logfd:		ref FD;

files:		list of ref File;	# in the order opened
cmdfile:	ref File;		# the command window's file
curfile:	ref File;		# file that commands apply to (Tworkfile)
nexttag:	int;			# next host-assigned file tag
cmdptr:		int;			# runes of the command file already consumed
batchid:	int;			# undo id generator
quitok:		int;			# warned once about q with changes
snarfbuf:	string;			# used when /chan/snarf is absent

# command-line parser state
cs:		string;			# command text being parsed
ci:		int;			# parse cursor
cl:		int;			# len cs

lastpat:	string;			# last regular expression
patset:		int;			# lastpat changed by this command
curre:		string;			# regular expression compiled in rx

filenames:	list of string;		# files named on the command line

run(fd: ref FD, args: list of string)
{
	sys = load Sys Sys->PATH;
	rx = load Samrx Samrx->PATH;
	if(rx == nil){
		sys->fprint(sys->fildes(2), "sam: can't load %s: %r\n", Samrx->PATH);
		return;
	}
	rx->init();

	io = fd;
	nexttag = 1;
	filenames = args;

	logfd = sys->fildes(2);

	hdr := array[3] of byte;
	for(;;){
		if(readn(io, hdr, 3) != 3)
			break;
		mtype := int hdr[0];
		mcount := int hdr[1] | (int hdr[2] << 8);
		if(mcount < 0 || mcount > DATASIZE){
			sys->fprint(logfd, "sam engine: bad count %d\n", mcount);
			break;
		}
		data: array of byte;
		if(mcount > 0){
			data = array[mcount] of byte;
			if(readn(io, data, mcount) != mcount)
				break;
		}
		if(dispatch(mtype, data))
			break;
	}
}

# returns non-zero to stop the engine loop.
dispatch(mtype: int, data: array of byte): int
{
	case mtype {
	Tversion =>
		sendmsg(Hversion, pshort(VERSION));

	Tstartcmdfile =>
		startup(int gvlong(data, 0));

	Tstartfile =>
		openframe(gshort(data, 0));

	Tstartnewfile =>
		newfile(int gvlong(data, 0));

	Trequest =>
		serve(gshort(data, 0), glong(data, 2), gshort(data, 6));

	Torigin =>
		setorigin(gshort(data, 0), glong(data, 2), glong(data, 6));

	Tcheck =>
		sendmsg(Hcheck, pshort(gshort(data, 0)));

	Texit =>
		return 1;

	Tworkfile =>
		# Sets which file subsequent commands apply to, and its dot.
		# Sent (when a file is open) just before command text, Tsend
		# and Tsearch.
		f := findfile(gshort(data, 0));
		if(f != nil && f != cmdfile){
			curfile = f;
			setdot(f, glong(data, 2), glong(data, 6));
		}

	Ttype =>
		# The user typed into a window; keep our authoritative copy in
		# sync with what the terminal already echoed locally.
		typed(findfile(gshort(data, 0)), glong(data, 2), string data[6:]);

	Tcut =>
		cut(findfile(gshort(data, 0)), glong(data, 2), glong(data, 6));

	Tpaste =>
		paste(findfile(gshort(data, 0)), glong(data, 2));

	Tsnarf =>
		f := findfile(gshort(data, 0));
		if(f != nil)
			snarfput(substr(f, glong(data, 2), glong(data, 6)));

	Twrite =>
		f := findfile(gshort(data, 0));
		guard(f, "w");
		sendmsg(Hunlock, nil);

	Tclose =>
		guard(findfile(gshort(data, 0)), "D");
		sendmsg(Hunlock, nil);

	Tlook =>
		look(findfile(gshort(data, 0)), glong(data, 2), glong(data, 6));
		sendmsg(Hunlock, nil);

	Tsearch =>
		if(curfile != nil)
			guard(curfile, "//");
		sendmsg(Hunlock, nil);

	Tsend =>
		f := findfile(gshort(data, 0));
		if(f != nil)
			sendtext(substr(f, glong(data, 2), glong(data, 6)));
		sendmsg(Hunlock, nil);

	Tdclick =>
		f := findfile(gshort(data, 0));
		if(f != nil){
			doubleclick(f, glong(data, 2));
			tellsetdot(f);
		}
		sendmsg(Hunlock, nil);

	Tstartsnarf or Tsetsnarf or Tack =>
		# The snarf buffer is /chan/snarf, shared with the rest of the
		# system, so there is nothing to exchange with the terminal.
		;

	* =>
		sys->fprint(logfd, "T msg type=%d (unknown)\n", mtype);
	}
	return 0;
}

# run a command on f as if typed, reporting errors in the command window.
guard(f: ref File, cmd: string)
{
	if(f == nil || f == cmdfile)
		return;
	curfile = f;
	docommand(cmd + "\n");
}

# The terminal has created its command window and told us its tag.  Give
# it a menu entry, then open every file named on the command line.
# The terminal has created its command window and told us its tag:
# sam's Tstartcmdfile.  Files named on the command line go in the menu
# unread; the first is current, but no window is opened for it until a
# command uses it (see execute).
startup(cmdtag: int)
{
	cmdfile = newFile(cmdtag, "~~sam~~");
	cmdfile.rasp = 1;
	sendmsg(Hnewname, pshort(cmdtag));
	bindname(cmdtag, cmdtag);
	sendmsg(Hcurrent, pshort(cmdtag));
	movname(cmdfile);

	first: ref File;
	for(nl := filenames; nl != nil; nl = tl nl){
		f := openfile(hd nl);
		if(first == nil)
			first = f;
	}
	curfile = first;

	# Release the lock the terminal took after Tstartcmdfile.
	sendmsg(Hunlock, nil);
}

newFile(tag: int, name: string): ref File
{
	return ref File(tag, name, "", 0, 0, 0, 0, 0, 0, nil, nil, 0, 0, nil, 0, -1, -1, 0);
}

# The terminal opened a fresh window (menu "new"): an unnamed file.
newfile(termtag: int)
{
	f := newFile(nexttag++, "");
	f.rasp = 1;
	files = appendfile(files, f);
	sendmsg(Hnewname, pshort(f.tag));
	bindname(f.tag, termtag);
	movname(f);
	curfile = f;
	sendmsg(Hcurrent, pshort(f.tag));
}

appendfile(l: list of ref File, f: ref File): list of ref File
{
	if(l == nil)
		return f :: nil;
	return hd l :: appendfile(tl l, f);
}

# load a named file into the menu (creating an empty one if it does not
# exist) and return its File.
# put a named file in the menu, unread, and return its File
openfile(name: string): ref File
{
	f := byname(name);
	if(f != nil)
		return f;
	f = newFile(nexttag++, name);
	f.unread = 1;
	files = appendfile(files, f);
	sendmsg(Hnewname, pshort(f.tag));
	movname(f);
	return f;
}

# sam.c's load: read a file when it is first used, saying so with its
# menu line, as sam's filename does
fload(f: ref File)
{
	if(!f.unread)
		return;
	f.unread = 0;
	warn(menuline(f) + "\n");
	if(f.name == "")
		return;
	(text, ok) := loadfile(f.name);
	if(!ok)
		error(sys->sprint("can't open \"%s\": %r", f.name));
	f.text = text;
	f.dirty = 0;
	f.dot0 = f.dot1 = 0;
}

byname(name: string): ref File
{
	for(l := files; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

bindname(tag, termtag: int)
{
	b := array[10] of byte;
	pshortat(b, 0, tag);
	pvlongat(b, 2, big termtag);
	sendmsg(Hbindname, b);
}

movname(f: ref File)
{
	nb := array of byte f.name;
	b := array[2 + len nb] of byte;
	pshortat(b, 0, f.tag);
	b[2:] = nb;
	sendmsg(Hmovname, b);
}

# The terminal opened a frame for this file (in response to Hcurrent).
# Tell it the file's size and set the origin; the terminal then requests
# the visible text with Trequest.
# The terminal swept a window for this file (sam's Tstartfile).  As
# sam does: the file becomes current, the terminal is told the window
# is its and that it is current, and the file is read if it has not
# been.  Then the terminal is given its size and origin, and asks for
# the text it shows with Trequest.
openframe(tag: int)
{
	f := findfile(tag);
	if(f == nil){
		sys->fprint(logfd, "openframe: no file for tag %d\n", tag);
		sendmsg(Hunlock, nil);
		return;
	}
	curfile = f;
	bindname(tag, tag);
	sendmsg(Hcurrent, pshort(tag));
	{
		fload(f);
	} exception e {
	"sam:*" =>
		warn("?" + e[len "sam:":] + "\n");
	}
	f.rasp = 1;
	grow(tag, 0, len f.text);
	origin(tag, linestart(f, f.dot0));	# answers the terminal's lock
	if(f.dirty)
		sendmsg(Hdirty, pshort(tag));
	if(f.dot0 != 0 || f.dot1 != 0)
		tellsetdot(f);
}

# Answer a Trequest: hand the terminal the runes it asked for.
serve(tag, pos, cnt: int)
{
	f := findfile(tag);
	if(f == nil){
		sendmsg(Hunlock, nil);
		return;
	}
	n := len f.text;
	if(pos < 0)
		pos = 0;
	end := pos + cnt;
	if(end > n)
		end = n;
	s := "";
	if(end > pos)
		s = f.text[pos:end];
	data(tag, pos, s);
}

# The terminal asks us to reposition the frame: nlines lines back from
# pos (0: the start of pos's line).
# The terminal asks for the window to start ls lines back from p0:
# sam's lookorigin (moveto.c).  With ls 1 that is the start of p0's line.
CHARSHIFT:	con 128;

setorigin(tag, p0, ls: int)
{
	f := findfile(tag);
	if(f == nil){
		sendmsg(Hunlock, nil);
		return;
	}
	n := len f.text;
	if(p0 > n)
		p0 = n;
	if(p0 < 0)
		p0 = 0;
	oldp0 := p0;
	p := p0;
	nl := 0;
	c := 0;
	for(nc := 0; c != -1 && nl < ls && nc < ls*CHARSHIFT; nc++){
		if(--p < 0)
			c = -1;
		else if((c = f.text[p]) == '\n'){
			nl++;
			oldp0 = p0-nc;
		}
	}
	if(c == -1)
		p0 = 0;
	else if(nl == 0){
		if(p0 >= CHARSHIFT/2)
			p0 -= CHARSHIFT/2;
		else
			p0 = 0;
	}else
		p0 = oldp0;
	origin(tag, p0);
}

linestart(f: ref File, p: int): int
{
	if(p > len f.text)
		p = len f.text;
	while(p > 0 && f.text[p-1] != '\n')
		p--;
	return p;
}

# ---- terminal-originated changes ----

typed(f: ref File, pos: int, s: string)
{
	if(f == nil || s == "")
		return;
	if(pos < 0 || pos > len f.text)
		pos = len f.text;
	if(f == cmdfile){
		f.text = f.text[0:pos] + s + f.text[pos:];
		if(pos < cmdptr)
			cmdptr += len s;
		# A newline typed at the end of the command window: the
		# terminal locked, and we run whatever is complete.
		if(s[len s-1] == '\n' && pos+len s == len f.text){
			runpending();
			sendmsg(Hunlock, nil);
		}
		return;
	}
	applybatch(f, array[] of {ref Edit(pos, pos, s)}, 0);
	f.redo = nil;
	# extend the typing run the top of the undo stack describes
	if(f.undo != nil){
		b := hd f.undo;
		e := b.edits[0];
		if(b.typing && len b.edits == 1 && e.s == "" && e.p1 == pos){
			e.p1 += len s;
			b.id = ++batchid;
			setdirty(f);
			return;
		}
	}
	f.undo = ref Batch(++batchid, array[] of {ref Edit(pos, pos+len s, "")}, 1) :: f.undo;
	setdirty(f);
}

cut(f: ref File, p0, p1: int)
{
	if(f == nil)
		return;
	(p0, p1) = clip(f, p0, p1);
	if(p0 == p1)
		return;
	if(f == cmdfile){
		f.text = f.text[0:p0] + f.text[p1:];
		if(p1 <= cmdptr)
			cmdptr -= p1 - p0;
		else if(p0 < cmdptr)
			cmdptr = p0;
		return;
	}
	inv := applybatch(f, array[] of {ref Edit(p0, p1, "")}, 0);
	pushundo(f, inv);
	setdirty(f);
}

paste(f: ref File, p: int)
{
	if(f == nil)
		return;
	s := snarfget();
	(p, nil) = clip(f, p, p);
	if(f == cmdfile){
		# into the command window: typed text, not a command
		if(s != ""){
			f.text = f.text[0:p] + s + f.text[p:];
			if(p < cmdptr)
				cmdptr += len s;
			hinsert(f, p, s);
		}
		setdot(f, p, p+len s);
		tellsetdot(f);
		return;
	}
	if(s != ""){
		inv := applybatch(f, array[] of {ref Edit(p, p, s)}, 1);
		pushundo(f, inv);
		setdirty(f);
	}
	setdot(f, p, p+len s);
	tellsetdot(f);
}

# look: search for the literal text of the selection.
look(f: ref File, p0, p1: int)
{
	if(f == nil)
		return;
	s := substr(f, p0, p1);
	if(s == "")
		return;
	lastpat = quotemeta(s);
	sendsetpat();
	if(f == cmdfile){
		# look for the command window's selection in the file
		f = curfile;
		if(f == nil)
			return;
	}else{
		curfile = f;
		setdot(f, p0, p1);
	}
	docommand("//\n");
}

quotemeta(s: string): string
{
	q := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		case c {
		'\\' or '.' or '*' or '+' or '?' or '(' or ')' or '|' or '[' or ']' or '^' or '$' =>
			q[len q] = '\\';
		'\n' =>
			q += "\\n";
			continue;
		}
		q[len q] = c;
	}
	return q;
}

# send: the selection is typed into the command window and run.
sendtext(s: string)
{
	if(s == "")
		return;
	snarfput(s);
	b := array[4] of byte;
	plongat(b, 0, len s);
	sendmsg(Hsnarflen, b);
	if(s[len s-1] != '\n')
		s[len s] = '\n';
	pos := len cmdfile.text;
	cmdfile.text += s;
	hinsert(cmdfile, pos, s);
	setdot(cmdfile, len cmdfile.text, len cmdfile.text);
	tellsetdot(cmdfile);
	runpending();
}

# Select the word, line or bracketed text around a double click, as
# sam does: brackets and quotes match their partners, a click at the
# start or end of a line selects the line.
lbrack := array[] of {"{[(<«", "\n", "'\"`"};
rbrack := array[] of {"}])>»", "\n", "'\"`"};

doubleclick(f: ref File, p: int)
{
	t := f.text;
	n := len t;
	if(p < 0 || p > n)
		return;
	setdot(f, p, p);
	for(i := 0; i < len lbrack; i++){
		l := lbrack[i];
		r := rbrack[i];
		# try left match
		c := '\n';
		if(p > 0)
			c = t[p-1];
		if((k := strchr(l, c)) >= 0){
			(ok, q) := clickmatch(t, c, r[k], 1, p);
			if(ok){
				e := q;
				if(c != '\n')
					e--;
				setdot(f, p, e);
			}
			return;
		}
		# try right match
		c = '\n';
		if(p < n)
			c = t[p];
		if((k = strchr(r, c)) >= 0){
			(ok, q) := clickmatch(t, c, l[k], -1, p);
			if(ok){
				s := q;
				if(c != '\n' || q != 0 || (n > 0 && t[0] == '\n'))
					s++;
				e := p;
				if(p < n && c == '\n')
					e++;
				setdot(f, s, e);
			}
			return;
		}
	}
	# fill out a word
	q0 := p;
	while(q0 > 0 && isalnum(t[q0-1]))
		q0--;
	q1 := p;
	while(q1 < n && isalnum(t[q1]))
		q1++;
	setdot(f, q0, q1);
}

# scan from p for the partner of cl; returns (found, position): just
# past the partner going forwards, at it going backwards.
clickmatch(t: string, cl, cr, dir, p: int): (int, int)
{
	nest := 1;
	for(;;){
		c: int;
		if(dir > 0){
			if(p >= len t)
				break;
			c = t[p++];
		}else{
			if(p == 0)
				break;
			c = t[--p];
		}
		if(c == cr){
			if(--nest == 0)
				return (1, p);
		}else if(c == cl)
			nest++;
	}
	return (cl == '\n' && nest == 1, p);
}

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

isalnum(c: int): int
{
	return c >= 16rA0 || c == '_' ||
		(c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

# ---- snarf buffer: /chan/snarf, shared with the rest of the system ----

snarfget(): string
{
	fd := sys->open("/chan/snarf", Sys->OREAD);
	if(fd == nil)
		return snarfbuf;
	s := string readall(fd);
	if(s == "")
		return snarfbuf;	# e.g. a host clipboard that isn't there
	return s;
}

snarfput(s: string)
{
	snarfbuf = s;
	fd := sys->open("/chan/snarf", Sys->OWRITE|Sys->OTRUNC);
	if(fd != nil){
		b := array of byte s;
		sys->write(fd, b, len b);
	}
}

# ---- applying changes ----

# Apply edits (ascending, non-overlapping, in f's current coordinates)
# to f, telling the terminal if tell is set and it holds a rasp.
# Returns the inverse batch, in the new coordinates.
applybatch(f: ref File, edits: array of ref Edit, tell: int): array of ref Edit
{
	n := len edits;
	inv := array[n] of ref Edit;
	delta := 0;
	for(k := 0; k < n; k++){
		e := edits[k];
		ns := e.p0 + delta;
		inv[k] = ref Edit(ns, ns + len e.s, f.text[e.p0:e.p1]);
		delta += len e.s - (e.p1 - e.p0);
	}
	grew := 0;
	for(k = n-1; k >= 0; k--){
		e := edits[k];
		f.text = f.text[0:e.p0] + e.s + f.text[e.p1:];
		if(tell && f.rasp){
			if(e.p1 > e.p0)
				hcut(f.tag, e.p0, e.p1 - e.p0);
			if(e.s != "")
				grew |= hinsert(f, e.p0, e.s);
		}
	}
	if(grew)
		sendmsg(Hcheck, pshort(f.tag));
	return inv;
}

pushundo(f: ref File, inv: array of ref Edit)
{
	f.undo = ref Batch(++batchid, inv, 0) :: f.undo;
	f.redo = nil;
}

setdirty(f: ref File)
{
	id := 0;
	if(f.undo != nil)
		id = (hd f.undo).id;
	d := id != f.cleanid;
	if(d){
		f.closeok = 0;
		quitok = 0;
	}
	if(d == f.dirty)
		return;
	f.dirty = d;
	if(f.rasp){
		if(d)
			sendmsg(Hdirty, pshort(f.tag));
		else
			sendmsg(Hclean, pshort(f.tag));
	}
}

markclean(f: ref File)
{
	f.cleanid = 0;
	if(f.undo != nil)
		f.cleanid = (hd f.undo).id;
	setdirty(f);
}

# ---- running commands ----

# Execute the complete commands sitting unconsumed in the command file.
# An incomplete one (a/i/c text not yet ended by ".", an open "{")
# stays pending until more is typed.
runpending()
{
	for(;;){
		if(cmdfile == nil || cmdptr >= len cmdfile.text)
			return;
		pending := cmdfile.text[cmdptr:];
		last := -1;
		for(i := 0; i < len pending; i++)
			if(pending[i] == '\n')
				last = i;
		if(last < 0)
			return;
		cs = pending[0:last+1];
		ci = 0;
		cl = len cs;
		cmd: ref Cmd;
		{
			cmd = parsecmd(0);
		} exception e {
		MORE =>
			return;
		"sam:*" =>
			cmdptr += last+1;
			warn("?" + e[len "sam:":] + "\n");
			continue;
		}
		cmdptr += ci;
		if(cmd != nil)
			execute(cmd);
	}
}

# Run cmdtext (complete lines) as though it had been typed.
docommand(cmdtext: string)
{
	cs = cmdtext;
	ci = 0;
	cl = len cs;
	{
		while(ci < cl){
			cmd := parsecmd(0);
			if(cmd == nil)
				break;
			execute(cmd);
		}
	} exception e {
	"sam:*" =>
		warn("?" + e[len "sam:":] + "\n");
	}
}

# Run one parsed command, then apply its changes to every file it
# touched and show the result.
# Run one parsed command, then apply its changes to every file it
# touched and show the result.  As in sam's cmdloop, the terminal is
# then told the current file (Hcurrent, which brings up or sweeps its
# window) if it changed or was read by the command; after an error,
# as in sam's error, it is told regardless.
execute(cmd: ref Cmd)
{
	savecs := cs;
	saveci := ci;
	ocurfile := curfile;
	loaded := curfile != nil && !curfile.unread;
	for(l := files; l != nil; l = tl l)
		resetlog(hd l);
	failed := 0;
	{
		cmdexec(curfile, cmd);
	} exception e {
	"sam:*" =>
		for(l = files; l != nil; l = tl l)
			resetlog(hd l);
		if(e != MORE){
			warn("?" + e[len "sam:":] + "\n");
			failed = 1;
		}
	}
	for(l = files; l != nil; l = tl l)
		commit(hd l);
	if(patset){
		sendsetpat();
		patset = 0;
	}
	if(curfile != nil)
		tellsetdot(curfile);
	if(curfile != nil && curfile != cmdfile){
		if(failed){
			if(!curfile.unread)
				sendmsg(Hcurrent, pshort(curfile.tag));
		}else if(ocurfile != curfile || (!loaded && !curfile.unread))
			sendmsg(Hcurrent, pshort(curfile.tag));
	}
	cs = savecs;
	ci = saveci;
	cl = len cs;
}

resetlog(f: ref File)
{
	f.log = nil;
	f.nlog = 0;
	f.logend = 0;
	f.dotedit = -1;
}

# record a change for the end of the command.
logedit(f: ref File, p0, p1: int, s: string)
{
	if(p0 < f.logend)
		error("changes not in sequence");
	if(p0 == p1 && s == "")
		return;
	f.log = ref Edit(p0, p1, s) :: f.log;
	f.nlog++;
	f.logend = p1;
	f.dotedit = f.nlog-1;
}

commit(f: ref File)
{
	if(f.log == nil)
		return;
	n := f.nlog;
	edits := array[n] of ref Edit;
	for(l := f.log; l != nil; l = tl l)
		edits[--n] = hd l;
	(d0, d1) := (mappos(edits, f.dot0, 0), mappos(edits, f.dot1, 1));
	(m0, m1) := (mappos(edits, f.mark0, 0), mappos(edits, f.mark1, 1));
	inv := applybatch(f, edits, 1);
	pushundo(f, inv);
	if(f.dotedit >= 0){
		e := inv[f.dotedit];
		(d0, d1) = (e.p0, e.p1);
	}
	resetlog(f);
	f.dot0 = d0;
	f.dot1 = d1;
	f.mark0 = m0;
	f.mark1 = m1;
	setdirty(f);
}

# where position q lands once edits are applied; end chooses whether an
# insertion exactly at q goes before it.
mappos(edits: array of ref Edit, q: int, end: int): int
{
	d := 0;
	for(k := 0; k < len edits; k++){
		e := edits[k];
		if(e.p0 > q || (e.p0 == q && !end))
			break;
		if(e.p1 > q)
			return e.p0 + d;
		d += len e.s - (e.p1 - e.p0);
	}
	return q + d;
}

error(s: string)
{
	raise "sam:" + s;
}

# ---- parser (sam's parse.c) ----

nextc(): int
{
	if(ci >= cl)
		return -1;
	return cs[ci];
}

getch(): int
{
	if(ci >= cl)
		return -1;
	return cs[ci++];
}

skipbl(): int
{
	while(ci < cl && (cs[ci] == ' ' || cs[ci] == '\t'))
		ci++;
	return nextc();
}

atnl()
{
	skipbl();
	c := getch();
	if(c != '\n' && c != -1)
		error("newline expected");
}

lookup(c: int): int
{
	for(i := 0; i < len cmdtab; i++)
		if(cmdtab[i].cmdc == c)
			return i;
	return -1;
}

okdelim(c: int)
{
	if(c == '\\' || c == -1 || (c < 16rA0 && isalnum(c)))
		error("bad delimiter");
}

getnum(signok: int): int
{
	n := 0;
	sign := 1;
	if(signok > 1 && nextc() == '-'){
		sign = -1;
		getch();
	}
	c := nextc();
	if(c < '0' || c > '9')
		return sign;
	while((c = nextc()) >= '0' && c <= '9'){
		n = n*10 + c - '0';
		getch();
	}
	return sign*n;
}

getregexp(delim: int): string
{
	buf := "";
	for(;;){
		c := getch();
		if(c == delim || c < 0)
			break;
		if(c == '\n'){
			ci--;
			break;
		}
		if(c == '\\'){
			if(nextc() == delim)
				c = getch();
			else if(nextc() == '\\'){
				buf[len buf] = c;
				c = getch();
			}
		}
		buf[len buf] = c;
	}
	if(buf != ""){
		patset = 1;
		lastpat = buf;
	}
	if(lastpat == "")
		error("no regular expression defined");
	return lastpat;
}

# right-hand side of s and a/i/c: \n is newline, \delim is delim; s keeps
# its other escapes to interpret itself.
getrhs(delim, cmd: int): string
{
	s := "";
	for(;;){
		c := getch();
		if(c < 0)
			break;
		if(c == delim || c == '\n'){
			ci--;
			break;
		}
		if(c == '\\'){
			if((c = getch()) < 0)
				error("bad right hand side");
			if(c == '\n'){
				ci--;
				c = '\\';
			}else if(c == 'n')
				c = '\n';
			else if(c != delim && (cmd == 's' || c != '\\'))
				s[len s] = '\\';
		}
		s[len s] = c;
	}
	return s;
}

collecttext(): string
{
	s := "";
	if(skipbl() == '\n'){
		getch();
		for(;;){
			begline := len s;
			c: int;
			while((c = getch()) > 0 && c != '\n')
				s[len s] = c;
			if(c < 0)
				raise MORE;
			s[len s] = '\n';
			if(s[begline:] == ".\n")
				break;
		}
		s = s[0:len s-2];
	}else{
		delim := getch();
		okdelim(delim);
		s = getrhs(delim, 'a');
		if(nextc() == delim)
			getch();
		atnl();
	}
	return s;
}

collecttoken(end: string): string
{
	s := "";
	c: int;
	while((c = nextc()) == ' ' || c == '\t'){
		s[len s] = c;
		getch();
	}
	while((c = getch()) > 0 && strchr(end, c) < 0)
		s[len s] = c;
	if(c != '\n')
		atnl();
	return s;
}

simpleaddr(): ref Addr
{
	a: ref Addr;
	c := skipbl();
	case c {
	'#' =>
		getch();
		a = ref Addr('#', getnum(1), nil, nil, nil);
	'0' to '9' =>
		a = ref Addr('l', getnum(1), nil, nil, nil);
	'/' or '?' or '"' =>
		getch();
		a = ref Addr(c, 0, getregexp(c), nil, nil);
	'.' or '$' or '+' or '-' or '\'' =>
		getch();
		a = ref Addr(c, 0, nil, nil, nil);
	* =>
		return nil;
	}
	if((a.next = simpleaddr()) != nil){
		case a.next.typ {
		'.' or '$' or '\'' =>
			if(a.typ != '"')
				error("bad address");
		'"' =>
			error("bad address");
		'l' or '#' =>
			if(a.typ != '"' && a.typ != '+' && a.typ != '-')
				a.next = ref Addr('+', 0, nil, nil, a.next);
		'/' or '?' =>
			if(a.typ != '+' && a.typ != '-')
				a.next = ref Addr('+', 0, nil, nil, a.next);
		}
	}
	return a;
}

compoundaddr(): ref Addr
{
	left := simpleaddr();
	c := skipbl();
	if(c != ',' && c != ';')
		return left;
	getch();
	next := compoundaddr();
	if(next != nil && (next.typ == ',' || next.typ == ';') && next.left == nil)
		error("bad address");
	return ref Addr(c, 0, nil, left, next);
}

newcmd(c: int): ref Cmd
{
	return ref Cmd(nil, nil, c, nil, nil, 0, 0, nil, nil);
}

parsecmd(nest: int): ref Cmd
{
	cmd := newcmd(0);
	cmd.addr = compoundaddr();
	if(skipbl() == -1)
		return nil;
	c := getch();
	cmd.cmdc = c;
	if(c == 'c' && nextc() == 'd'){
		getch();
		cmd.cmdc = CDCMD;
	}
	i := lookup(cmd.cmdc);
	if(i >= 0){
		if(cmd.cmdc == '\n')
			return cmd;	# let nlcmd work it all out
		ct := cmdtab[i];
		if(ct.defaddr == aNo && cmd.addr != nil)
			error("command takes no address");
		if(ct.count)
			cmd.num = getnum(ct.count);
		if(ct.regexp){
			# x without pattern is .*\n, X without pattern is all files
			if((ct.cmdc != 'x' && ct.cmdc != 'X') ||
			   ((c = nextc()) != ' ' && c != '\t' && c != '\n')){
				skipbl();
				c = getch();
				if(c == '\n' || c < 0)
					error("no regular expression");
				okdelim(c);
				cmd.re = getregexp(c);
				if(ct.cmdc == 's'){
					cmd.text = getrhs(c, 's');
					if(nextc() == c){
						getch();
						if(nextc() == 'g')
							cmd.flag = getch();
					}
				}
			}
		}
		if(ct.addr && (cmd.mtaddr = simpleaddr()) == nil)
			error("bad address");
		if(ct.defcmd){
			if(skipbl() == '\n'){
				getch();
				cmd.sub = newcmd(ct.defcmd);
			}else if((cmd.sub = parsecmd(nest)) == nil)
				error("bad command");
		}else if(ct.text)
			cmd.text = collecttext();
		else if(ct.token != nil)
			cmd.text = collecttoken(ct.token);
		else
			atnl();
	}else
		case cmd.cmdc {
		'{' =>
			cp: ref Cmd;
			for(;;){
				if(skipbl() == '\n')
					getch();
				if(skipbl() == -1)
					raise MORE;
				ncp := parsecmd(nest+1);
				if(ncp == nil)
					break;
				if(cp != nil)
					cp.next = ncp;
				else
					cmd.sub = ncp;
				cp = ncp;
			}
		'}' =>
			atnl();
			if(nest == 0)
				error("right brace with no left brace");
			return nil;
		* =>
			error("unknown command");
		}
	return cmd;
}

# ---- addresses (sam's address.c) ----

address(ap: ref Addr, f: ref File, q0, q1, sign: int): (ref File, int, int)
{
	do{
		if(f == nil && ap.typ != '"')
			error("no current file");
		case ap.typ {
		'l' =>
			(q0, q1) = lineaddr(f, ap.num, q0, q1, sign);
		'#' =>
			(q0, q1) = charaddr(f, ap.num, q0, q1, sign);
		'.' =>
			(q0, q1) = (f.dot0, f.dot1);
		'$' =>
			q0 = q1 = len f.text;
		'\'' =>
			(q0, q1) = (f.mark0, f.mark1);
		'?' =>
			sign = -sign;
			if(sign == 0)
				sign = -1;
			p := q0;
			if(sign >= 0)
				p = q1;
			(q0, q1) = nextmatch(f, ap.re, p, sign);
		'/' =>
			p := q0;
			if(sign >= 0)
				p = q1;
			(q0, q1) = nextmatch(f, ap.re, p, sign);
		'"' =>
			f = matchfile(ap.re);
			(q0, q1) = (f.dot0, f.dot1);
		'*' =>
			return (f, 0, len f.text);
		',' or ';' =>
			f1 := f;
			(a0, a1) := (0, 0);
			if(ap.left != nil)
				(f1, a0, a1) = address(ap.left, f, q0, q1, 0);
			if(ap.typ == ';'){
				f = f1;
				(q0, q1) = (a0, a1);
				setdot(f, a0, a1);
			}
			f2 := f;
			(b0, b1) := (0, 0);
			if(f != nil)
				(b0, b1) = (len f.text, len f.text);
			if(ap.next != nil)
				(f2, b0, b1) = address(ap.next, f, q0, q1, 0);
			if(f1 != f2)
				error("addresses in different files");
			if(b1 < a0)
				error("addresses out of order");
			return (f1, a0, b1);
		'+' or '-' =>
			sign = 1;
			if(ap.typ == '-')
				sign = -1;
			if(ap.next == nil || ap.next.typ == '+' || ap.next.typ == '-')
				(q0, q1) = lineaddr(f, 1, q0, q1, sign);
		}
	}while((ap = ap.next) != nil);
	return (f, q0, q1);
}

lineaddr(f: ref File, l: int, q0, q1, sign: int): (int, int)
{
	t := f.text;
	nc := len t;
	a0, a1, p: int;
	if(sign >= 0){
		if(l == 0){
			if(sign == 0 || q1 == 0)
				return (0, 0);
			a0 = q1;
			p = q1-1;
		}else{
			n: int;
			if(sign == 0 || q1 == 0){
				p = 0;
				n = 1;
			}else{
				p = q1-1;
				n = t[p++] == '\n';
			}
			while(n < l){
				if(p >= nc)
					error("address out of range");
				if(t[p++] == '\n')
					n++;
			}
			a0 = p;
		}
		while(p < nc && t[p++] != '\n')
			;
		a1 = p;
	}else{
		p = q0;
		if(l == 0)
			a1 = q0;
		else{
			for(n := 0; n < l; ){	# always runs once
				if(p == 0){
					if(++n != l)
						error("address out of range");
				}else{
					c := t[p-1];
					if(c != '\n' || ++n != l)
						p--;
				}
			}
			a1 = p;
			if(p > 0)
				p--;
		}
		while(p > 0 && t[p-1] != '\n')	# lines start after a newline
			p--;
		a0 = p;
	}
	return (a0, a1);
}

charaddr(f: ref File, l: int, q0, q1, sign: int): (int, int)
{
	if(sign == 0)
		q0 = q1 = l;
	else if(sign < 0)
		q1 = q0 -= l;
	else
		q0 = q1 += l;
	if(q0 < 0 || q1 > len f.text)
		error("address out of range");
	return (q0, q1);
}

compile(re: string)
{
	if(re == curre)
		return;
	curre = nil;
	e := rx->compile(re);
	if(e != nil)
		error("regexp: " + e);
	curre = re;
}

nextmatch(f: ref File, re: string, p, sign: int): (int, int)
{
	compile(re);
	nc := len f.text;
	m: array of (int, int);
	if(sign >= 0){
		m = rx->execute(f.text, p, Samrx->Infinity);
		if(m == nil)
			error("no match for regexp");
		(m0, m1) := m[0];
		if(m0 == m1 && m0 == p){
			if(++p > nc)
				p = 0;
			m = rx->execute(f.text, p, Samrx->Infinity);
			if(m == nil)
				error("no match for regexp");
		}
	}else{
		m = rx->bexecute(f.text, p);
		if(m == nil)
			error("no match for regexp");
		(m0, m1) := m[0];
		if(m0 == m1 && m1 == p){
			if(--p < 0)
				p = nc;
			m = rx->bexecute(f.text, p);
			if(m == nil)
				error("no match for regexp");
		}
	}
	return m[0];
}

# the file whose menu line matches re
matchfile(re: string): ref File
{
	compile(re);
	match: ref File;
	for(l := files; l != nil; l = tl l){
		f := hd l;
		if(filematch(f)){
			if(match != nil)
				error("too many files match");
			match = f;
		}
	}
	if(match == nil)
		error("no file matches");
	return match;
}

filematch(f: ref File): int
{
	s := menuline(f);
	return rx->execute(s, 0, len s) != nil;
}

menuline(f: ref File): string
{
	s := " '"[f.dirty:f.dirty+1];
	s += "-+"[f.rasp:f.rasp+1];
	if(f == curfile)
		s += ".";
	else
		s += " ";
	return s + " " + f.name;
}

# ---- command execution (sam's xec.c) ----

cmdexec(f: ref File, cp: ref Cmd)
{
	if(f == nil && (cp.addr == nil || cp.addr.typ != '"') &&
	   strchr("bBnqXY!", cp.cmdc) < 0 && cp.cmdc != CDCMD &&
	   !(cp.cmdc == 'D' && cp.text != nil))
		error("no current file");
	if(f != nil && f.unread)
		fload(f);
	q0, q1: int;
	i := lookup(cp.cmdc);
	if(i >= 0 && cmdtab[i].defaddr != aNo){
		ap := cp.addr;
		deftyp := '.';
		if(cmdtab[i].defaddr == aAll)
			deftyp = '*';
		if(ap == nil && cp.cmdc != '\n')
			ap = ref Addr(deftyp, 0, nil, nil, nil);
		else if(ap != nil && ap.typ == '"' && ap.next == nil && cp.cmdc != '\n')
			ap = ref Addr('"', 0, ap.re, nil, ref Addr(deftyp, 0, nil, nil, nil));
		if(ap != nil){
			if(f != nil)
				(f, q0, q1) = address(ap, f, f.dot0, f.dot1, 0);
			else
				(f, q0, q1) = address(ap, nil, 0, 0, 0);
		}
	}
	if(f == nil && cp.cmdc == '\n')
		return;		# an empty line before any file is open
	if(f != nil && f.unread)
		fload(f);
	if(f != nil)
		curfile = f;
	case cp.cmdc {
	'{' =>
		(a0, a1) := (f.dot0, f.dot1);
		if(cp.addr != nil)
			(f, a0, a1) = address(cp.addr, f, f.dot0, f.dot1, 0);
		for(c := cp.sub; c != nil; c = c.next){
			setdot(f, a0, a1);
			cmdexec(f, c);
		}
	'\n' =>
		nlcmd(f, cp, q0, q1);
	'a' =>
		logedit(f, q1, q1, cp.text);
	'i' =>
		logedit(f, q0, q0, cp.text);
	'c' =>
		logedit(f, q0, q1, cp.text);
	'd' =>
		logedit(f, q0, q1, "");
	'b' =>
		bcmd(cp.text);
	'B' =>
		Bcmd(cp.text);
	'D' =>
		Dcmd(f, cp.text);
	'e' =>
		ecmd(f, cp.text);
	'f' =>
		fcmd(f, cp.text);
	'g' or 'v' =>
		compile(cp.re);
		m := rx->execute(f.text, q0, q1);
		if((m != nil) ^ (cp.cmdc == 'v')){
			setdot(f, q0, q1);
			cmdexec(f, cp.sub);
		}
	'k' =>
		(f.mark0, f.mark1) = (q0, q1);
	'm' or 't' =>
		mtcmd(f, cp, q0, q1);
	'n' =>
		for(l := files; l != nil; l = tl l)
			warn(menuline(hd l) + "\n");
	'p' =>
		warn(f.text[q0:q1]);
		setdot(f, q0, q1);
	'q' =>
		qcmd();
	'r' =>
		rcmd(f, cp.text, q0, q1);
	's' =>
		scmd(f, cp, q0, q1);
	'u' =>
		ucmd(f, cp.num);
	'w' =>
		wcmd(f, cp.text, q0, q1);
	'x' or 'y' =>
		xcmd(f, cp, q0, q1);
	'X' or 'Y' =>
		Xcmd(cp);
	'!' or '<' or '>' or '|' =>
		shcmd(f, cp.cmdc, cp.text, q0, q1);
	'=' =>
		eqcmd(f, cp.text, q0, q1);
	CDCMD =>
		dir := trim(cp.text);
		if(dir == "")
			dir = "/usr/" + user();
		if(sys->chdir(dir) < 0)
			error(sys->sprint("can't cd to %s: %r", dir));
	* =>
		error("unknown command");
	}
}

setdot(f: ref File, q0, q1: int)
{
	(q0, q1) = clip(f, q0, q1);
	f.dot0 = q0;
	f.dot1 = q1;
	f.dotedit = -1;
}

clip(f: ref File, q0, q1: int): (int, int)
{
	n := len f.text;
	if(q0 < 0)
		q0 = 0;
	if(q1 > n)
		q1 = n;
	if(q0 > q1)
		q0 = q1;
	return (q0, q1);
}

substr(f: ref File, q0, q1: int): string
{
	(q0, q1) = clip(f, q0, q1);
	return f.text[q0:q1];
}

# a newline on its own: with an address, select it; without, select
# the line(s) containing dot, or the next line if they already are.
# sam's nl_cmd.  An address alone selects and brings it into view
# (moveto); an empty command selects the next line and prints it.
nlcmd(f: ref File, cp: ref Cmd, q0, q1: int)
{
	if(cp.addr != nil){
		setdot(f, q0, q1);
		if(f.rasp)
			moveto(f.tag, q0);
		return;
	}
	(a0, nil) := lineaddr(f, 0, f.dot0, f.dot1, -1);
	(nil, b1) := lineaddr(f, 0, f.dot0, f.dot1, 1);
	if(a0 == f.dot0 && b1 == f.dot1)
		(a0, b1) = lineaddr(f, 1, f.dot0, f.dot1, 1);
	setdot(f, a0, b1);
	warn(f.text[a0:b1]);
}

mtcmd(f: ref File, cp: ref Cmd, q0, q1: int)
{
	(f2, nil, p) := address(cp.mtaddr, f, f.dot0, f.dot1, 0);
	if(f2 != f)
		error("m and t work within one file");
	s := f.text[q0:q1];
	if(cp.cmdc == 't'){
		logedit(f, p, p, s);
		return;
	}
	if(q1 <= p){
		logedit(f, q0, q1, "");
		logedit(f, p, p, s);
	}else if(q0 >= p){
		logedit(f, p, p, s);
		dot := f.dotedit;
		logedit(f, q0, q1, "");
		f.dotedit = dot;
	}else
		error("addresses overlap");
}

scmd(f: ref File, cp: ref Cmd, q0, q1: int)
{
	compile(cp.re);
	n := cp.num;
	op := -1;
	didsub := 0;
	for(p := q0; p <= q1; ){
		m := rx->execute(f.text, p, q1);
		if(m == nil)
			break;
		(m0, m1) := m[0];
		if(m0 == m1){	# empty match?
			if(m0 == op){
				p++;
				continue;
			}
			p = m1+1;
		}else
			p = m1;
		op = m1;
		if(--n > 0)
			continue;
		rep := expand(cp.text, f.text, m);
		logedit(f, m0, m1, rep);
		didsub = 1;
		if(!cp.flag)
			break;
	}
	if(!didsub)
		error("no substitution");
	# dot becomes the range, stretched or shrunk by the substitutions
	setdot(f, q0, q1);
}

# expand a substitution template: & = whole match, \1..\9 = submatches,
# \c = literal c.  (\n was made a newline by the parser.)
expand(repl: string, text: string, m: array of (int, int)): string
{
	out := "";
	n := len repl;
	for(i := 0; i < n; i++){
		c := repl[i];
		if(c == '\\' && i < n-1){
			c = repl[++i];
			if(c >= '1' && c <= '9'){
				(s0, s1) := m[c - '0'];
				if(s0 >= 0 && s1 >= s0)
					out += text[s0:s1];
				continue;
			}
		}else if(c == '&'){
			(s0, s1) := m[0];
			out += text[s0:s1];
			continue;
		}
		out[len out] = c;
	}
	return out;
}

# x, y: run the command with dot set to each match (x) or each piece
# between matches (y), all found in the unmodified text.
xcmd(f: ref File, cp: ref Cmd, q0, q1: int)
{
	re := cp.re;
	if(re == nil){
		linelooper(f, cp, q0, q1);
		return;
	}
	compile(re);
	ms: list of (int, int);
	op := q0;
	if(cp.cmdc == 'x')
		op = -1;
	for(p := q0; p <= q1; ){
		m := rx->execute(f.text, p, q1);
		if(m == nil)
			break;
		(m0, m1) := m[0];
		if(m0 == m1){	# empty match?
			if(m0 == op){
				p++;
				continue;
			}
			p = m1+1;
		}else
			p = m1;
		if(cp.cmdc == 'x')
			ms = (m0, m1) :: ms;
		else
			ms = (op, m0) :: ms;
		op = m1;
	}
	if(cp.cmdc == 'y')
		ms = (op, q1) :: ms;
	rs: list of (int, int);
	for(; ms != nil; ms = tl ms)
		rs = hd ms :: rs;
	for(; rs != nil; rs = tl rs){
		(r0, r1) := hd rs;
		setdot(f, r0, r1);
		cmdexec(f, cp.sub);
		# the body may compile another regexp
		compile(re);
	}
}

# x with no regular expression: each line of the range, the last one
# even without a newline.
linelooper(f: ref File, cp: ref Cmd, q0, q1: int)
{
	rs: list of (int, int);
	for(p := q0; p < q1; ){
		e := p;
		while(e < q1 && f.text[e] != '\n')
			e++;
		if(e < q1)
			e++;
		rs = (p, e) :: rs;
		p = e;
	}
	ls: list of (int, int);
	for(; rs != nil; rs = tl rs)
		ls = hd rs :: ls;
	for(; ls != nil; ls = tl ls){
		(r0, r1) := hd ls;
		setdot(f, r0, r1);
		cmdexec(f, cp.sub);
	}
}

# X, Y: run the command in each file whose menu line matches (X) or
# does not (Y).
Xcmd(cp: ref Cmd)
{
	for(l := files; l != nil; l = tl l){
		f := hd l;
		m := 1;
		if(cp.re != nil){
			compile(cp.re);
			m = filematch(f);
		}
		if(m == (cp.cmdc == 'X')){
			if(cp.sub.cmdc == 'f')
				warn(menuline(f) + "\n");
			else
				cmdexec(f, cp.sub);
		}
	}
}

# = : report the line and character address of the range.
eqcmd(f: ref File, arg: string, q0, q1: int)
{
	arg = trim(arg);
	s := "";
	if(arg != "#"){
		if(arg != "")
			error("newline expected");
		l1 := 1 + nlcount(f, 0, q0);
		l2 := l1 + nlcount(f, q0, q1);
		# a range ending in a newline does not reach the next line
		if(q1 > 0 && q1 > q0 && f.text[q1-1] == '\n')
			l2--;
		s = string l1;
		if(l2 != l1)
			s += "," + string l2;
		s += "; ";
	}
	s += "#" + string q0;
	if(q1 != q0)
		s += ",#" + string q1;
	warn(s + "\n");
}

nlcount(f: ref File, q0, q1: int): int
{
	n := 0;
	for(i := q0; i < q1; i++)
		if(f.text[i] == '\n')
			n++;
	return n;
}

# u n: undo the last n changes to f; u -n: redo them.
ucmd(f: ref File, n: int)
{
	for(l := files; l != nil; l = tl l)
		if((hd l).log != nil)
			error("u with changes pending");
	undo := n >= 0;
	if(n < 0)
		n = -n;
	for(; n > 0; n--){
		b: ref Batch;
		if(undo){
			if(f.undo == nil)
				break;
			b = hd f.undo;
			f.undo = tl f.undo;
		}else{
			if(f.redo == nil)
				break;
			b = hd f.redo;
			f.redo = tl f.redo;
		}
		inv := applybatch(f, b.edits, 1);
		nb := ref Batch(b.id, inv, 0);
		if(undo)
			f.redo = nb :: f.redo;
		else
			f.undo = nb :: f.undo;
		if(len inv > 0)
			setdot(f, inv[0].p0, inv[len inv-1].p1);
	}
	setdirty(f);
}

wcmd(f: ref File, arg: string, q0, q1: int)
{
	name := trim(arg);
	if(name == "")
		name = f.name;
	if(name == "")
		error("no file name");
	if(f.name == ""){
		f.name = name;
		movname(f);
	}
	fd := sys->create(name, Sys->OWRITE, 8r664);
	if(fd == nil)
		error(sys->sprint("can't create %s: %r", name));
	b := array of byte f.text[q0:q1];
	if(sys->write(fd, b, len b) != len b)
		error(sys->sprint("write error on %s: %r", name));
	warn(sys->sprint("%s: #%d\n", name, q1 - q0));
	if(name == f.name && q0 == 0 && q1 == len f.text)
		markclean(f);
}

ecmd(f: ref File, arg: string)
{
	name := trim(arg);
	if(name == "")
		name = f.name;
	if(name == "")
		error("no file name");
	if(f.dirty && !f.closeok){
		f.closeok = 1;
		error("changes to " + filename(f));
	}
	(text, ok) := loadfile(name);
	if(!ok)
		error(sys->sprint("can't open %s: %r", name));
	if(name != f.name){
		f.name = name;
		movname(f);
	}
	logedit(f, 0, len f.text, text);
	commit(f);
	markclean(f);
	setdot(f, 0, 0);
	warn(sys->sprint("%s: #%d\n", name, len text));
}

rcmd(f: ref File, arg: string, q0, q1: int)
{
	name := trim(arg);
	if(name == "")
		name = f.name;
	if(name == "")
		error("no file name");
	(text, ok) := loadfile(name);
	if(!ok)
		error(sys->sprint("can't open %s: %r", name));
	logedit(f, q0, q1, text);
}

fcmd(f: ref File, arg: string)
{
	name := trim(arg);
	if(name != "" && name != f.name){
		f.name = name;
		movname(f);
	}
	warn(menuline(f) + "\n");
}

filename(f: ref File): string
{
	if(f.name == "")
		return "(unnamed)";
	return f.name;
}

# b file: make a file current, opening its window.
# b file: make a file current (sam's b_cmd); its window comes up when
# the command is done (execute)
bcmd(arg: string)
{
	(nil, names) := sys->tokenize(arg, " \t");
	if(names == nil){
		error("no file name");
	}
	for(; names != nil; names = tl names){
		f := byname(hd names);
		if(f != nil){
			curfile = f;
			if(f.unread)
				fload(f);
			else
				warn(menuline(f) + "\n");
			return;
		}
	}
	error("not in menu: \"" + arg + "\"");
}

# B files: add each file to the menu and make the first current.
# B files: add each file to the menu and make the first current
Bcmd(arg: string)
{
	(nil, names) := sys->tokenize(arg, " \t");
	if(names == nil)
		error("no file name");
	first: ref File;
	for(; names != nil; names = tl names){
		f := openfile(hd names);
		if(first == nil)
			first = f;
	}
	curfile = first;
	fload(first);
}

# D files: delete files from the menu, warning once about changes.
Dcmd(f: ref File, arg: string)
{
	(nil, names) := sys->tokenize(arg, " \t");
	if(names == nil){
		closefile(f);
		return;
	}
	for(; names != nil; names = tl names){
		g := byname(hd names);
		if(g == nil)
			error("no such file: " + hd names);
		closefile(g);
	}
}

closefile(f: ref File)
{
	if(f.dirty && !f.closeok){
		f.closeok = 1;
		error("changes to " + filename(f));
	}
	nl: list of ref File;
	for(l := files; l != nil; l = tl l)
		if(hd l != f)
			nl = hd l :: nl;
	files = nil;
	for(; nl != nil; nl = tl nl)
		files = hd nl :: files;
	if(f.rasp)
		sendmsg(Hclose, pshort(f.tag));
	sendmsg(Hdelname, pshort(f.tag));
	f.rasp = 0;
	if(curfile == f)
		curfile = nil;
}

qcmd()
{
	if(!quitok){
		for(l := files; l != nil; l = tl l)
			if((hd l).dirty){
				quitok = 1;
				error("changes to files");
			}
	}
	sendmsg(Hexit, nil);
}

# ---- shell commands: ! < > | ----

shcmd(f: ref File, c: int, cmd: string, q0, q1: int)
{
	sh := load Sh Sh->PATH;
	if(sh == nil)
		error(sys->sprint("can't load %s: %r", Sh->PATH));
	input := "";
	if(c == '>' || c == '|')
		input = f.text[q0:q1];
	(out, errs) := runsh(sh, cmd, input, c == '>' || c == '|');
	case c {
	'<' or '|' =>
		logedit(f, q0, q1, out);
	* =>
		warn(out);
	}
	warn(errs);
	warn("!\n");
}

# run cmd under sh with input on its stdin; returns (stdout, stderr).
runsh(sh: Sh, cmd, input: string, hasinput: int): (string, string)
{
	pin := array[2] of ref FD;
	pout := array[2] of ref FD;
	perr := array[2] of ref FD;
	if(sys->pipe(pin) < 0 || sys->pipe(pout) < 0 || sys->pipe(perr) < 0)
		error(sys->sprint("can't make pipe: %r"));
	sync := chan of int;
	spawn shproc(sh, cmd, pin[0], pout[1], perr[1], sync);
	<-sync;
	pin[0] = pout[1] = perr[1] = nil;
	if(hasinput)
		spawn writeall(pin[1], array of byte input);
	pin[1] = nil;
	errc := chan of string;
	spawn readproc(perr[0], errc);
	perr[0] = nil;
	out := string readall(pout[0]);
	return (out, <-errc);
}

shproc(sh: Sh, cmd: string, fin, fout, ferr: ref FD, sync: chan of int)
{
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	sys->dup(fin.fd, 0);
	sys->dup(fout.fd, 1);
	sys->dup(ferr.fd, 2);
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	fin = fout = ferr = nil;
	sync <-= 1;
	e := sh->system(nil, cmd);
	if(e != nil)
		sys->fprint(sys->fildes(2), "%s\n", e);
}

writeall(fd: ref FD, b: array of byte)
{
	sys->write(fd, b, len b);
}

readproc(fd: ref FD, c: chan of string)
{
	c <-= string readall(fd);
}

# ---- command-window output ----

# Output goes before any command still being typed, so it never lands
# in the middle of one.
warn(s: string)
{
	if(cmdfile == nil || s == "")
		return;
	pos := cmdptr;
	cmdfile.text = cmdfile.text[0:pos] + s + cmdfile.text[pos:];
	cmdptr += len s;
	hinsert(cmdfile, pos, s);
	# typing carries on at the end, after the output
	setdot(cmdfile, len cmdfile.text, len cmdfile.text);
	tellsetdot(cmdfile);
}

# sam's telldot: tell the terminal where dot is.  Only moveto (an
# address typed alone, look and search) scrolls it into view.
tellsetdot(f: ref File)
{
	if(!f.rasp)
		return;
	b := array[10] of byte;
	pshortat(b, 0, f.tag);
	plongat(b, 2, f.dot0);
	plongat(b, 6, f.dot1);
	sendmsg(Hsetdot, b);
}

sendsetpat()
{
	sendmsg(Hsetpat, array of byte lastpat);
}

# ---- H message emitters ----

grow(tag, pos, count: int)
{
	b := array[10] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, pos);
	plongat(b, 6, count);
	sendmsg(Hgrow, b);
}

origin(tag, pos: int)
{
	b := array[6] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, pos);
	sendmsg(Horigin, b);
}

data(tag, pos: int, s: string)
{
	sb := array of byte s;
	b := array[6 + len sb] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, pos);
	b[6:] = sb;
	sendmsg(Hdata, b);
}

hcut(tag, where, n: int)
{
	b := array[10] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, where);
	plongat(b, 6, n);
	sendmsg(Hcut, b);
}

# insert s at pos in the terminal's rasp: Hgrowdata when it fits in one
# message, otherwise a hole the terminal fills with Trequest as it needs
# (Hdata would release a lock the terminal never took).  Returns
# non-zero if it left a hole.
hinsert(f: ref File, pos: int, s: string): int
{
	L := len s;
	if(L == 0 || !f.rasp)
		return 0;
	if(L <= TBLOCKSIZE){
		sb := array of byte s;
		b := array[10 + len sb] of byte;
		pshortat(b, 0, f.tag);
		plongat(b, 2, pos);
		plongat(b, 6, L);
		b[10:] = sb;
		sendmsg(Hgrowdata, b);
		return 0;
	}
	grow(f.tag, pos, L);
	return 1;
}

moveto(tag, pos: int)
{
	b := array[6] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, pos);
	sendmsg(Hmoveto, b);
}

# ---- file helpers ----

findfile(tag: int): ref File
{
	if(cmdfile != nil && cmdfile.tag == tag)
		return cmdfile;
	for(l := files; l != nil; l = tl l)
		if((hd l).tag == tag)
			return hd l;
	return nil;
}

loadfile(name: string): (string, int)
{
	fd := sys->open(name, Sys->OREAD);
	if(fd == nil)
		return ("", 0);
	return (string readall(fd), 1);
}

readall(fd: ref FD): array of byte
{
	data := array[0] of byte;
	buf := array[8192] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		nd := array[len data + n] of byte;
		nd[0:] = data;
		nd[len data:] = buf[0:n];
		data = nd;
	}
	return data;
}

trim(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}

user(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return "inferno";
	return string readall(fd);
}

# ---- wire I/O ----

# read exactly n bytes (pipes may return short reads); returns the count
# actually read (< n only at EOF/error).
readn(fd: ref FD, buf: array of byte, n: int): int
{
	got := 0;
	while(got < n){
		r := sys->read(fd, buf[got:], n - got);
		if(r <= 0)
			return got;
		got += r;
	}
	return got;
}

sendmsg(mtype: int, data: array of byte)
{
	n := 0;
	if(data != nil)
		n = len data;
	buf := array[3 + n] of byte;
	buf[0] = byte mtype;
	buf[1] = byte n;
	buf[2] = byte (n >> 8);
	if(n > 0)
		buf[3:] = data;
	sys->write(io, buf, len buf);
}

# ---- little-endian pack/unpack ----

pshort(v: int): array of byte
{
	a := array[2] of byte;
	pshortat(a, 0, v);
	return a;
}

pshortat(a: array of byte, off, v: int)
{
	a[off]   = byte v;
	a[off+1] = byte (v >> 8);
}

plongat(a: array of byte, off, v: int)
{
	a[off]   = byte v;
	a[off+1] = byte (v >> 8);
	a[off+2] = byte (v >> 16);
	a[off+3] = byte (v >> 24);
}

pvlongat(a: array of byte, off: int, v: big)
{
	for(i := 0; i < 8; i++)
		a[off+i] = byte (v >> (8*i));
}

gshort(a: array of byte, off: int): int
{
	return (int a[off]) | ((int a[off+1]) << 8);
}

glong(a: array of byte, off: int): int
{
	return (int a[off]) | ((int a[off+1]) << 8) |
		((int a[off+2]) << 16) | ((int a[off+3]) << 24);
}

gvlong(a: array of byte, off: int): big
{
	v := big 0;
	for(i := 7; i >= 0; i--)
		v = (v << 8) | big (int a[off+i] & 16rff);
	return v;
}
