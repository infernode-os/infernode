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
# Phase 2 implements read-only display of the files named on the command
# line plus a usable (locally-echoed) command window.  Editing and the
# sam command language land in Phase 3 (reusing acme's Edit subsystem).
#

include "sys.m";
	sys: Sys;
	FD: import Sys;

include "draw.m";

include "regex.m";
	regex: Regex;

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
	Hversion, Hnewname, Hmovname, Hcurrent, Hgrow, Hdata, Hgrowdata,
	Hcut, Hsetdot, Hmoveto, Horigin, Hunlock, Hdirty, Hclean, Hexit,
	VERSION, DATASIZE, TBLOCKSIZE: import Samstub;

# A file held by the host: the authoritative text (a rune string) plus
# the tag that identifies it in the terminal's menu and rasp.
File: adt {
	tag:	int;
	name:	string;
	text:	string;		# rune-indexed; len == nrunes
	inmenu:	int;		# listed in the terminal's file menu
	dirty:	int;		# modified since last write
	dot0:	int;		# current selection (dot), rune offsets
	dot1:	int;
};

io:		ref FD;
logfd:		ref FD;

files:		list of ref File;	# command-line / opened files
cmdfile:	ref File;		# the command window's file
curfile:	ref File;		# file that commands apply to (Tworkfile)
nexttag:	int;			# next host-assigned file tag
cmdptr:		int;			# runes of the command file already consumed

# command-line parser state
cs:		string;			# command text being parsed
ci:		int;			# parse cursor
cl:		int;			# len cs
depth:		int;			# command nesting (x/g/v)

filenames:	list of string;		# files named on the command line

LOG:	con "samengine.log";

run(fd: ref FD, args: list of string)
{
	sys = load Sys Sys->PATH;
	regex = load Regex Regex->PATH;

	io = fd;
	nexttag = 1;
	filenames = args;

	logfd = sys->create(LOG, Sys->OWRITE, 8r666);
	if(logfd == nil)
		logfd = sys->fildes(2);
	sys->fprint(logfd, "sam engine started\n");

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
	sys->fprint(logfd, "sam engine: exiting\n");
}

# returns non-zero to stop the engine loop.
dispatch(mtype: int, data: array of byte): int
{
	case mtype {
	Tversion =>
		sys->fprint(logfd, "Tversion -> Hversion %d\n", VERSION);
		sendmsg(Hversion, pshort(VERSION));

	Tstartcmdfile =>
		cmdtag := int gvlong(data, 0);
		sys->fprint(logfd, "Tstartcmdfile tag=%d\n", cmdtag);
		startup(cmdtag);

	Tstartfile =>
		tag := int gvlong(data, 0);
		sys->fprint(logfd, "Tstartfile tag=%d\n", tag);
		openframe(tag);

	Trequest =>
		tag := gshort(data, 0);
		pos := glong(data, 2);
		cnt := gshort(data, 6);
		sys->fprint(logfd, "Trequest tag=%d pos=%d cnt=%d\n", tag, pos, cnt);
		serve(tag, pos, cnt);

	Torigin =>
		tag := gshort(data, 0);
		pos := glong(data, 2);
		lines := glong(data, 6);
		sys->fprint(logfd, "Torigin tag=%d pos=%d lines=%d\n", tag, pos, lines);
		setorigin(tag, pos, lines);

	Texit or Hexit =>
		sys->fprint(logfd, "Texit -> engine exit\n");
		return 1;

	Ttype =>
		# The user typed into a window; keep our authoritative copy in
		# sync with what the terminal already echoed locally.
		tag := gshort(data, 0);
		pos := glong(data, 2);
		s := string data[6:];
		sys->fprint(logfd, "Ttype tag=%d pos=%d n=%d\n", tag, pos, len s);
		insert(findfile(tag), pos, s);
		# Typing in the command window: run any complete command line(s).
		# The terminal locks (setlock) just before delivering the text,
		# so each completed command answers with one Hunlock.
		if(cmdfile != nil && tag == cmdfile.tag)
			runpending();

	Tcut =>
		tag := gshort(data, 0);
		p1 := glong(data, 2);
		p2 := glong(data, 6);
		sys->fprint(logfd, "Tcut tag=%d %d,%d\n", tag, p1, p2);
		delete(findfile(tag), p1, p2);

	Twrite =>
		tag := gshort(data, 0);
		sys->fprint(logfd, "Twrite tag=%d\n", tag);
		writefile(findfile(tag));

	Tworkfile =>
		# Sets which file subsequent commands apply to, and its dot.
		# Sent (when a file is open) just before the command text; the
		# command itself runs when that text arrives via Ttype.
		tag := gshort(data, 0);
		d0 := glong(data, 2);
		d1 := glong(data, 6);
		curfile = findfile(tag);
		if(curfile != nil){
			curfile.dot0 = d0;
			curfile.dot1 = d1;
		}
		sys->fprint(logfd, "Tworkfile tag=%d dot=%d,%d\n", tag, d0, d1);

	Tpaste or Tsnarf or Tclose or
	Tlook or Tsearch or Tsend or Tdclick or Tstartnewfile or
	Tstartsnarf or Tsetsnarf or Tack or Tcheck =>
		# Remaining command-language / clipboard messages: Phase 3b.
		sys->fprint(logfd, "T msg type=%d (phase 3b, ignored)\n", mtype);

	* =>
		sys->fprint(logfd, "T msg type=%d (unknown)\n", mtype);
	}
	return 0;
}

# The terminal has created its command window and told us its tag.  Set
# up the command file, then open every file named on the command line:
# add each to the menu (Hnewname + Hmovname) and open the first one.
startup(cmdtag: int)
{
	cmdfile = ref File(cmdtag, "", "", 0, 0, 0, 0);

	first: ref File;
	for(nl := filenames; nl != nil; nl = tl nl){
		f := openfile(hd nl);
		if(first == nil)
			first = f;
	}

	if(first != nil){
		curfile = first;
		sendmsg(Hcurrent, pshort(first.tag));	# opens its window
	}

	# Release the lock the terminal took after Tstartcmdfile.
	sendmsg(Hunlock, nil);
}

# load a named file into the menu (creating an empty one if it does not
# exist) and return its File.
openfile(name: string): ref File
{
	(text, ok) := loadfile(name);
	if(!ok)
		sys->fprint(logfd, "sam: %s: new file\n", name);
	f := ref File(nexttag++, name, text, 1, 0, 0, 0);
	files = f :: files;
	addtomenu(f);
	return f;
}

byname(name: string): ref File
{
	for(l := files; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

# B files... : add each file to the menu and open the first.
openlist(names: string)
{
	(nil, words) := sys->tokenize(names, " \t");
	first: ref File;
	for(; words != nil; words = tl words){
		f := openfile(hd words);
		if(first == nil)
			first = f;
	}
	if(first != nil){
		curfile = first;
		sendmsg(Hcurrent, pshort(first.tag));
	}
}

# b file : make an already-open file current (opening it if need be).
switchfile(name: string)
{
	if(name == "")
		return;
	f := byname(name);
	if(f == nil)
		f = openfile(name);
	curfile = f;
	sendmsg(Hcurrent, pshort(f.tag));
}

# n : list the open files in the command window.
listfiles()
{
	for(l := files; l != nil; l = tl l){
		f := hd l;
		mark := " ";
		if(f.dirty)
			mark = "'";
		warn(mark + f.name + "\n");
	}
}

addtomenu(f: ref File)
{
	sendmsg(Hnewname, pshort(f.tag));
	b := array[2 + len array of byte f.name] of byte;
	pshortat(b, 0, f.tag);
	b[2:] = array of byte f.name;
	sendmsg(Hmovname, b);
}

# The terminal opened a frame for this file (in response to Hcurrent, or
# a new/menu selection).  Tell it the file's size and set the origin;
# the terminal then requests the visible text with Trequest.
openframe(tag: int)
{
	f := findfile(tag);
	if(f == nil){
		sys->fprint(logfd, "openframe: no file for tag %d\n", tag);
		return;
	}
	n := len f.text;
	grow(tag, 0, n);
	origin(tag, 0);
}

# Answer a Trequest: hand the terminal the runes it asked for.
serve(tag, pos, cnt: int)
{
	f := findfile(tag);
	if(f == nil){
		sys->fprint(logfd, "serve: no file for tag %d\n", tag);
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

# The terminal asks us to reposition the frame (scroll).  Pick an origin
# at the start of the line containing pos and let the terminal re-request.
setorigin(tag, pos, nil: int)
{
	f := findfile(tag);
	if(f == nil)
		return;
	n := len f.text;
	if(pos < 0)
		pos = 0;
	if(pos > n)
		pos = n;
	# back up to the start of the current line
	while(pos > 0 && f.text[pos-1] != '\n')
		pos--;
	origin(tag, pos);
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

# ---- editing (host authoritative copy) ----

insert(f: ref File, pos: int, s: string)
{
	if(f == nil || s == "")
		return;
	n := len f.text;
	if(pos < 0)
		pos = 0;
	if(pos > n)
		pos = n;
	f.text = f.text[0:pos] + s + f.text[pos:];
	markdirty(f);
}

delete(f: ref File, p1, p2: int)
{
	if(f == nil)
		return;
	n := len f.text;
	if(p1 < 0)
		p1 = 0;
	if(p2 > n)
		p2 = n;
	if(p1 >= p2)
		return;
	f.text = f.text[0:p1] + f.text[p2:];
	markdirty(f);
}

markdirty(f: ref File)
{
	if(f == nil || f.dirty)
		return;
	f.dirty = 1;
	if(f.inmenu)
		sendmsg(Hdirty, pshort(f.tag));
}

writefile(f: ref File)
{
	if(f == nil)
		return;
	if(f.name == ""){
		sys->fprint(logfd, "write: no file name\n");
		return;
	}
	fd := sys->create(f.name, Sys->OWRITE, 8r664);
	if(fd == nil){
		sys->fprint(logfd, "write: can't create %s: %r\n", f.name);
		return;
	}
	b := array of byte f.text;
	if(sys->write(fd, b, len b) != len b)
		sys->fprint(logfd, "write: %s: %r\n", f.name);
	f.dirty = 0;
	if(f.inmenu)
		sendmsg(Hclean, pshort(f.tag));
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
	return (string data, 1);
}

# ---- sam command language ----
#
# A command line entered in the command window is parsed as
#	[address] command [args]
# and executed against the current work file, emitting rasp updates
# (Hcut / Hgrowdata / Hsetdot / Hmoveto) so the terminal reflects the
# change.  Supported: addresses . $ #n N N,M , /re/ ; commands
# p d a i c s x g v = w q.  Errors are reported in the command window.

# Execute any complete command line(s) sitting unconsumed in the command
# file, then release the lock the terminal took when the line was entered.
runpending()
{
	if(cmdfile == nil || cmdptr >= len cmdfile.text)
		return;
	pending := cmdfile.text[cmdptr:];
	last := -1;
	for(i := 0; i < len pending; i++)
		if(pending[i] == '\n')
			last = i;
	if(last < 0)
		return;				# command not terminated yet
	line := pending[0:last+1];
	cmdptr += last + 1;
	runcmd(curfile, line);
	cmdptr = len cmdfile.text;		# skip past any output we appended
	sendmsg(Hunlock, nil);
}

runcmd(f: ref File, s: string)
{
	savecs := cs; saveci := ci; savecl := cl;
	cs = s; ci = 0; cl = len s;
	{
		while(ci < cl){
			skipblank();
			if(ci >= cl)
				break;
			if(cs[ci] == '\n'){
				ci++;
				continue;
			}
			docmd(f);
		}
	} exception e {
	"sam:*" =>
		warn(e[len "sam:":] + "\n");
	}
	cs = savecs; ci = saveci; cl = savecl;
}

docmd(f: ref File)
{
	# With no file open yet, only the file-management commands are valid
	# (this is how you open the first document from an empty window).
	if(f == nil){
		skipblank();
		c0 := '\n';
		if(ci < cl)
			c0 = cs[ci];
		case c0 {
		'B' =>	ci++; skipblank(); openlist(readrest());
		'b' =>	ci++; skipblank(); switchfile(readrest());
		'n' =>	ci++; listfiles();
		'q' =>	ci++; sendmsg(Hexit, nil);
		'\n' or ' ' or '\t' =>
			if(ci < cl) ci++;
		* =>	raise "sam:no file — use B file to open one";
		}
		return;
	}

	(have, a0, a1) := address(f, f.dot0, f.dot1);
	skipblank();
	c := '\n';
	if(ci < cl)
		c = cs[ci];

	# helper defaults: fall back to dot when no address given
	if(!have){
		a0 = f.dot0;
		a1 = f.dot1;
	}

	case c {
	'\n' or ' ' or '\t' =>
		if(ci < cl)
			ci++;
		if(have){
			f.dot0 = a0; f.dot1 = a1;
			show(f);
		}
	'p' =>
		ci++;
		f.dot0 = a0; f.dot1 = a1;
		warn(f.text[a0:a1]);
		show(f);
	'd' =>
		ci++;
		edit(f, a0, a1, "");
		show(f);
	'a' =>
		ci++;
		edit(f, a1, a1, readtext());
		show(f);
	'i' =>
		ci++;
		edit(f, a0, a0, readtext());
		show(f);
	'c' =>
		ci++;
		edit(f, a0, a1, readtext());
		show(f);
	's' =>
		ci++;
		subst(f, a0, a1);
		show(f);
	'x' =>
		ci++;
		if(!have){ a0 = 0; a1 = len f.text; }
		loopcmd(f, a0, a1, 1);
	'y' =>
		ci++;
		if(!have){ a0 = 0; a1 = len f.text; }
		loopcmd(f, a0, a1, 0);
	'g' =>
		ci++;
		cond(f, a0, a1, 1);
	'v' =>
		ci++;
		cond(f, a0, a1, 0);
	'=' =>
		ci++;
		eqcmd(f, a0, a1);
	'w' =>
		ci++;
		skipblank();
		nm := readrest();
		if(nm != "")
			f.name = nm;
		writefile(f);
	'B' =>
		ci++;
		skipblank();
		openlist(readrest());
	'b' =>
		ci++;
		skipblank();
		switchfile(readrest());
	'n' =>
		ci++;
		listfiles();
	'q' =>
		ci++;
		sendmsg(Hexit, nil);
	* =>
		raise "sam:unknown command";
	}
}

# ---- address evaluation ----

address(f: ref File, d0, d1: int): (int, int, int)
{
	(has, q0, q1) := simpleaddr(f, d0, d1);
	for(;;){
		skipblank();
		if(ci >= cl)
			break;
		sep := cs[ci];
		if(sep != ',' && sep != ';')
			break;
		ci++;
		lo := q0;
		if(!has)
			lo = 0;
		base := q1;
		(has2, s0, s1) := simpleaddr(f, base, base);
		s0 = s0;		# unused; a2 supplies the high end
		hi := s1;
		if(!has2)
			hi = len f.text;
		q0 = lo; q1 = hi; has = 1;
	}
	return (has, q0, q1);
}

simpleaddr(f: ref File, b0, b1: int): (int, int, int)
{
	skipblank();
	if(ci >= cl)
		return (0, b0, b1);
	c := cs[ci];
	case c {
	'.' =>
		ci++;
		return (1, f.dot0, f.dot1);
	'$' =>
		ci++;
		n := len f.text;
		return (1, n, n);
	'#' =>
		ci++;
		n := number();
		return (1, n, n);
	'/' =>
		ci++;
		re := readdelim('/');
		return search(f, b1, re);
	* =>
		if(c >= '0' && c <= '9')
			return lineaddr(f, number());
		return (0, b0, b1);
	}
}

number(): int
{
	n := 0;
	while(ci < cl && cs[ci] >= '0' && cs[ci] <= '9'){
		n = n*10 + (cs[ci] - '0');
		ci++;
	}
	return n;
}

# line n -> (start of line n, start of line n+1); line 0 -> (0,0)
lineaddr(f: ref File, n: int): (int, int, int)
{
	t := f.text;
	L := len t;
	if(n <= 0)
		return (1, 0, 0);
	i := 0;
	nl := 1;
	while(nl < n && i < L){
		if(t[i] == '\n')
			nl++;
		i++;
	}
	q0 := i;
	while(i < L && t[i] != '\n')
		i++;
	if(i < L)
		i++;
	return (1, q0, i);
}

# forward regexp search from `from`, wrapping to the start.
search(f: ref File, from: int, re: string): (int, int, int)
{
	(prog, err) := regex->compile(re, 0);
	if(err != nil)
		raise "sam:bad regexp";
	L := len f.text;
	m := regex->executese(prog, f.text, (from, L), 1, 1);
	if(len m == 0 || (m[0]).t0 < 0)
		m = regex->executese(prog, f.text, (0, from), 1, 1);
	if(len m == 0 || (m[0]).t0 < 0)
		raise "sam:no match";
	return (1, (m[0]).t0, (m[0]).t1);
}

# ---- editing commands ----

# replace f.text[p0:p1] with s, updating the terminal rasp and dot.
edit(f: ref File, p0, p1: int, s: string)
{
	L := len f.text;
	if(p0 < 0)
		p0 = 0;
	if(p1 > L)
		p1 = L;
	if(p1 < p0)
		p1 = p0;
	f.text = f.text[0:p0] + s + f.text[p1:];
	if(p1 > p0)
		hcut(f.tag, p0, p1 - p0);
	if(s != "")
		hinsert(f.tag, p0, s);
	markdirty(f);
	f.dot0 = p0;
	f.dot1 = p0 + len s;
}

subst(f: ref File, a0, a1: int)
{
	if(ci >= cl)
		raise "sam:missing delimiter";
	delim := cs[ci];
	ci++;
	re := readdelim(delim);
	repl := readdelim(delim);
	global := 0;
	while(ci < cl && cs[ci] == 'g'){
		global = 1;
		ci++;
	}
	(prog, err) := regex->compile(re, 0);
	if(err != nil)
		raise "sam:bad regexp in s";

	# collect matches within [a0,a1] over the current text
	ms := array[64] of (int, int, string);
	nm := 0;
	p := a0;
	while(p <= a1){
		m := regex->executese(prog, f.text, (p, a1), 1, 1);
		if(len m == 0 || (m[0]).t0 < 0)
			break;
		(t0, t1) := ((m[0]).t0, (m[0]).t1);
		if(t0 > a1)
			break;
		rep := expand(repl, f.text, m);
		if(nm >= len ms){
			nn := array[2*len ms] of (int, int, string);
			nn[0:] = ms[0:nm];
			ms = nn;
		}
		ms[nm++] = (t0, t1, rep);
		if(!global)
			break;
		if(t1 == t0)
			p = t1 + 1;
		else
			p = t1;
	}
	if(nm == 0)
		raise "sam:no match";
	# apply right-to-left so earlier offsets stay valid
	for(i := nm - 1; i >= 0; i--){
		(t0, t1, rep) := ms[i];
		edit(f, t0, t1, rep);
	}
}

# expand a substitution template: & = whole match, \1..\9 = submatches,
# \n = newline, \c = literal c.
expand(repl: string, text: string, m: array of (int, int)): string
{
	out := "";
	n := len repl;
	i := 0;
	while(i < n){
		j := i;
		while(j < n && repl[j] != '&' && repl[j] != '\\')
			j++;
		if(j > i)
			out += repl[i:j];
		i = j;
		if(i >= n)
			break;
		c := repl[i];
		i++;
		if(c == '&'){
			out += text[(m[0]).t0:(m[0]).t1];
		} else if(i < n){		# backslash escape
			d := repl[i];
			i++;
			if(d >= '1' && d <= '9'){
				k := d - '0';
				if(k < len m && (m[k]).t0 >= 0)
					out += text[(m[k]).t0:(m[k]).t1];
			} else if(d == 'n')
				out += "\n";
			else
				out += repl[i-1:i];
		}
	}
	return out;
}

# x/y: for each match of re in [a0,a1], set dot and run the rest of the
# line as a command (sense=1 for x, 0 for y = between matches).
loopcmd(f: ref File, a0, a1, sense: int)
{
	if(ci >= cl)
		raise "sam:missing delimiter";
	delim := cs[ci];
	ci++;
	re := readdelim(delim);
	sub := "";
	if(ci < cl)
		sub = cs[ci:];
	ci = cl;
	(prog, err) := regex->compile(re, 0);
	if(err != nil)
		raise "sam:bad regexp in x";

	# collect match ranges over the original text
	ms := array[64] of (int, int);
	nm := 0;
	p := a0;
	while(p <= a1){
		m := regex->executese(prog, f.text, (p, a1), 1, 1);
		if(len m == 0 || (m[0]).t0 < 0)
			break;
		(t0, t1) := ((m[0]).t0, (m[0]).t1);
		if(t0 > a1)
			break;
		if(nm >= len ms){
			nn := array[2*len ms] of (int, int);
			nn[0:] = ms[0:nm];
			ms = nn;
		}
		if(sense)
			ms[nm++] = (t0, t1);
		if(t1 == t0)
			p = t1 + 1;
		else
			p = t1;
	}

	depth++;
	origlen := len f.text;
	for(i := 0; i < nm; i++){
		(t0, t1) := ms[i];
		shift := len f.text - origlen;
		f.dot0 = t0 + shift;
		f.dot1 = t1 + shift;
		runcmd(f, sub);
	}
	depth--;
	show(f);
}

# g/v: run the rest of the line iff [a0,a1] contains (g) / lacks (v) re.
cond(f: ref File, a0, a1, sense: int)
{
	if(ci >= cl)
		raise "sam:missing delimiter";
	delim := cs[ci];
	ci++;
	re := readdelim(delim);
	sub := "";
	if(ci < cl)
		sub = cs[ci:];
	ci = cl;
	(prog, err) := regex->compile(re, 0);
	if(err != nil)
		raise "sam:bad regexp in g";
	m := regex->executese(prog, f.text, (a0, a1), 1, 1);
	matched := len m > 0 && (m[0]).t0 >= 0 && (m[0]).t0 <= a1;
	if((matched && sense) || (!matched && !sense)){
		f.dot0 = a0; f.dot1 = a1;
		depth++;
		runcmd(f, sub);
		depth--;
		show(f);
	}
}

# = : report the line range (or char range) of dot in the command window.
eqcmd(f: ref File, a0, a1: int)
{
	l0 := lineof(f, a0);
	l1 := lineof(f, a1);
	if(l0 == l1)
		warn(sys->sprint("%d\n", l0));
	else
		warn(sys->sprint("%d,%d\n", l0, l1));
}

lineof(f: ref File, pos: int): int
{
	n := 1;
	for(i := 0; i < pos && i < len f.text; i++)
		if(f.text[i] == '\n')
			n++;
	return n;
}

# ---- command-window output ----

warn(s: string)
{
	if(cmdfile == nil || s == "")
		return;
	pos := len cmdfile.text;
	cmdfile.text += s;
	hinsert(cmdfile.tag, pos, s);
	moveto(cmdfile.tag, len cmdfile.text);
}

# reflect dot to the terminal and scroll it into view.
show(f: ref File)
{
	if(depth > 0)
		return;
	setdot(f.tag, f.dot0, f.dot1);
	moveto(f.tag, f.dot0);
}

# ---- parser lexical helpers ----

skipblank()
{
	while(ci < cl && (cs[ci] == ' ' || cs[ci] == '\t'))
		ci++;
}

# read up to (and consume) an unescaped delimiter; \<delim> -> <delim>,
# other backslashes are preserved (they belong to the regexp / template).
readdelim(delim: int): string
{
	out := "";
	while(ci < cl){
		c := cs[ci];
		if(c == delim){
			ci++;
			break;
		}
		if(c == '\n')
			break;
		if(c == '\\' && ci+1 < cl && cs[ci+1] == delim){
			out += cs[ci+1:ci+2];
			ci += 2;
			continue;
		}
		out += cs[ci:ci+1];
		ci++;
	}
	return out;
}

# read the /text/ argument of a/i/c: like readdelim but translating the
# usual C-style escapes into their characters.
readtext(): string
{
	skipblank();
	if(ci >= cl || cs[ci] == '\n')
		return "";
	delim := cs[ci];
	ci++;
	out := "";
	while(ci < cl){
		c := cs[ci];
		if(c == delim){
			ci++;
			break;
		}
		if(c == '\\' && ci+1 < cl){
			d := cs[ci+1];
			ci += 2;
			case d {
			'n' =>	out += "\n";
			't' =>	out += "\t";
			* =>	out += sys->sprint("%c", d);
			}
			continue;
		}
		out += cs[ci:ci+1];
		ci++;
	}
	return out;
}

readrest(): string
{
	s := "";
	while(ci < cl && cs[ci] != '\n'){
		s += cs[ci:ci+1];
		ci++;
	}
	return s;
}

# ---- rasp-update emitters ----

hcut(tag, where, n: int)
{
	b := array[10] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, where);
	plongat(b, 6, n);
	sendmsg(Hcut, b);
}

# insert s at pos in the terminal's rasp: Hgrowdata when it fits in one
# message, otherwise grow a hole and fill it in TBLOCKSIZE chunks.
hinsert(tag, pos: int, s: string)
{
	L := len s;
	if(L == 0)
		return;
	if(L <= TBLOCKSIZE){
		sb := array of byte s;
		b := array[10 + len sb] of byte;
		pshortat(b, 0, tag);
		plongat(b, 2, pos);
		plongat(b, 6, L);
		b[10:] = sb;
		sendmsg(Hgrowdata, b);
		return;
	}
	grow(tag, pos, L);
	off := 0;
	while(off < L){
		cnt := L - off;
		if(cnt > TBLOCKSIZE)
			cnt = TBLOCKSIZE;
		data(tag, pos + off, s[off:off+cnt]);
		off += cnt;
	}
}

setdot(tag, l0, l1: int)
{
	b := array[10] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, l0);
	plongat(b, 6, l1);
	sendmsg(Hsetdot, b);
}

moveto(tag, pos: int)
{
	b := array[6] of byte;
	pshortat(b, 0, tag);
	plongat(b, 2, pos);
	sendmsg(Hmoveto, b);
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
