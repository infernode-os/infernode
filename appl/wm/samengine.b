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
	Hversion, Hnewname, Hmovname, Hcurrent, Hgrow, Hdata,
	Horigin, Hunlock, Hexit,
	VERSION, DATASIZE, TBLOCKSIZE: import Samstub;

# A file held by the host: the authoritative text (a rune string) plus
# the tag that identifies it in the terminal's menu and rasp.
File: adt {
	tag:	int;
	name:	string;
	text:	string;		# rune-indexed; len == nrunes
	inmenu:	int;		# listed in the terminal's file menu
};

io:		ref FD;
logfd:		ref FD;

files:		list of ref File;	# command-line / opened files
cmdfile:	ref File;		# the command window's file
nexttag:	int;			# next host-assigned file tag

filenames:	list of string;		# files named on the command line

LOG:	con "samengine.log";

run(fd: ref FD, args: list of string)
{
	sys = load Sys Sys->PATH;

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

	Tworkfile =>
		tag := gshort(data, 0);
		sys->fprint(logfd, "Tworkfile tag=%d (noted)\n", tag);

	Ttype or Tcut or Tpaste or Tsnarf or Twrite or Tclose or
	Tlook or Tsearch or Tsend or Tdclick or Tstartnewfile or
	Tstartsnarf or Tsetsnarf or Tack or Tcheck =>
		# Editing / command-language messages: Phase 3.  Logged so the
		# read loop stays in sync; the terminal echoes typing locally.
		sys->fprint(logfd, "T msg type=%d (phase 3, ignored)\n", mtype);

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
	cmdfile = ref File(cmdtag, "", "", 0);

	first: ref File;
	for(nl := filenames; nl != nil; nl = tl nl){
		name := hd nl;
		(text, ok) := loadfile(name);
		if(!ok)
			sys->fprint(logfd, "sam: %s: new file\n", name);
		f := ref File(nexttag++, name, text, 1);
		files = f :: files;
		addtomenu(f);
		if(first == nil)
			first = f;
	}

	if(first != nil)
		sendmsg(Hcurrent, pshort(first.tag));	# opens its window

	# Release the lock the terminal took after Tstartcmdfile.
	sendmsg(Hunlock, nil);
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
