implement Matrix;

#
# matrix - Matrix compositional module runtime
#
# Loads Limbo modules against mounted 9P namespaces, managing
# their lifecycle and layout.  Supports GUI mode (display modules
# render in Lucifer's presentation zone) and headless mode (service
# modules only, no window).
#
# Usage:
#   matrix [-h] [composition-file]
#   matrix -h /lib/matrix/compositions/tbl4-monitor
#
# Flags:
#   -h    Force headless mode (skip GUI even if display modules present)
#
# See doc/matrix-architecture.md for the full specification.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect, Pointer: import draw;

include "arg.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "lucitheme.m";

include "readdir.m";
	readdir: Readdir;

include "matrix.m";

include "matrixlib.m";
	matrixlib: MatrixLib;

Matrix: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

UPDATE_MS: con 2000;

# ── 9P qid space ───────────────────────────────────────────
#
# 64-bit qid path: bits 0..7 node type; 8..19 module slot (4096);
# 20..43 passthrough slot (16M).  Module slots are append-only and
# never renumbered (mail9p idiom), so a fid opened before a
# composition reload keeps resolving to the same module afterwards.

# Fixed nodes.
Qroot, Qctl, Qcomposition, Qmoddir, Qlibdir,
Qlibcompsdir, Qlibmodsdir, Qnotifications: con iota;

# Per-module nodes (module slot packed into bits 8..19).
Qmoddirent:	con 16;	# modules/<name>/
Qmodctl:	con 17;
Qmodtype:	con 18;
Qmodmount:	con 19;
Qmodout:	con 20;	# modules/<name>/out/ (service modules only)

# Passthrough node backed by a real file or directory; the real
# path lives in passtab (slot packed into bits 20..43).
Qpass:	con 32;

LIBCOMPS: con "/lib/matrix/compositions";
LIBMODS:  con "/dis/matrix";
OUTBASE:  con "/tmp/matrix";

# Stable module registry.  Index == the slot packed into qid paths.
# Slots are appended on first sight of a (name) and revived on
# reload; a slot whose module left the composition goes !live and
# walks/stats on it fail, but the slot is never reused.
ModSlot: adt
{
	name:	string;
	mtype:	string;	# display|service
	mount:	string;
	live:	int;
};
modslots: array of ref ModSlot;
nmodslots: int;

# Passthrough registry: synthetic qid → real path.  Append-only for
# the server lifetime; parentq lets ".." walk back out.
PassEnt: adt
{
	rpath:	string;
	parentq:	big;
};
passtab: array of ref PassEnt;
npass: int;

# notifications file: bounded in-memory ring appended by watch-rule
# notify actions (and anything else runtime-worthy).
NOTIFMAX: con 32*1024;
notifbuf: string;

# ── Globals ─────────────────────────────────────────────────

stderr: ref Sys->FD;
user: string;
vers: int;
comp: ref Composition;
complock: chan of int;	# mutex for comp access

# GUI state
top: ref Toplevel;
wmctl: chan of string;
actch: chan of string;
mtximg: ref Image;	# off-screen composited frame, shown via a Tk label
winr: Rect;		# current composited-frame rectangle
display_g: ref Display;
font_g: ref Font;
bgcolor: ref Image;
bgcolstr: string;	# theme bg as a Tk colour string
divcolor: ref Image;
textcolor: ref Image;
dimcolor: ref Image;
redcolor: ref Image;
greencolor: ref Image;
yellowcolor: ref Image;
guimode: int;
dirty: int;
focusmod: MatrixDisplay;	# module with keyboard focus

# Channels
updatech: chan of int;
reloadch: chan of string;
themech: chan of int;

# Module tracking
allmodules: list of (string, string, string);	# (name, type, mount) for 9P

# Composition source (for the right-click menu's edit/reload affordances)
comppath: string;	# full path passed at startup or set by reload-from-disk
compname: string;	# basename of comppath, or "" for unnamed/empty

# Right-click menu state.  ctxmenuactions is a parallel array to
# the Tk .ctx menu items: action[i] is a verb consumed by domenuitem(i).
ctxmenuactions: array of string;

# Picker state.  When comp.layout is nil and we're in GUI mode, the
# window body is a list of /lib/matrix/compositions/ — one row per
# composition, left-click loads it.  pickerhits is a parallel array
# to pickerrects: a click in rect[i] sends "load <hits[i]>" to ctl.
pickerrects: array of Rect;
pickerhits:  array of string;
# Edge-trigger for button-1 click detection in the picker.
lastbtn1: int;
# 1 while the right-click context menu is posted.  matrix intercepts
# button-1 for its own picker/handleptr, so without this a click on a menu
# item never reaches Tk — the menu could not be invoked or dismissed and
# lingered as a ghost.  While set, pointer events go straight to Tk; it is
# cleared when the menu tears its window down ("delete" on top.wreq).
menuposted: int;

# ── Init ────────────────────────────────────────────────────

init(ctxt: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	styx = load Styx Styx->PATH;
	if(styx == nil)
		nomod(Styx->PATH);
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		nomod(Styxservers->PATH);
	styxservers->init(styx);

	matrixlib = load MatrixLib MatrixLib->PATH;
	if(matrixlib == nil)
		nomod(MatrixLib->PATH);
	matrixlib->init();

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);
	arg->init(args);

	forceheadless := 0;
	while((o := arg->opt()) != 0)
		case o {
		'h' =>	forceheadless = 1;
		* =>	usage();
		}
	args = arg->argv();
	arg = nil;

	user = readfile("/dev/user");
	if(user == nil)
		user = "inferno";

	complock = chan[1] of int;
	complock <-= 1;
	reloadch = chan[1] of string;

	# Parse initial composition
	comptext := "";
	if(args != nil) {
		comppath = hd args;
		comptext = readfile(comppath);
		compname = basename(comppath);
	}
	if(comptext == nil || comptext == "")
		comptext = "# empty\n";

	(c, err) := matrixlib->parsecomposition(comptext);
	if(err != nil) {
		sys->fprint(stderr, "matrix: parse error: %s\n", err);
		raise "fail:parse";
	}
	comp = c;
	syncmodslots();

	# Start 9P server (always, both modes)
	start9p();

	# Determine mode.  Open a GUI window whenever we have a Draw
	# context — the empty/no-layout state is now a clickable picker
	# of /lib/matrix/compositions/, not a silent headless service.
	# -h still forces pure-headless for service-only callers.
	guimode = !forceheadless && ctxt != nil;
	if(!guimode && !forceheadless && ctxt == nil)
		sys->fprint(stderr, "matrix: no display context, falling back to headless\n");

	if(guimode) {
		initgui(ctxt);
		loaddisplaymodules();
		loadservicemodules();
		guiloop();
	} else {
		loadservicemodules();
		headlessloop();
	}
}

usage()
{
	sys->fprint(stderr, "Usage: matrix [-h] [composition-file]\n");
	raise "fail:usage";
}

nomod(path: string)
{
	sys->fprint(stderr, "matrix: can't load %s: %r\n", path);
	raise "fail:load";
}

# ── File utilities ──────────────────────────────────────────

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	content := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		content += string buf[0:n];
	}
	if(content == "")
		return nil;
	return content;
}

writefile(path, data: string): string
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	buf := array of byte data;
	n := sys->write(fd, buf, len buf);
	if(n != len buf)
		return sys->sprint("short write to %s", path);
	return nil;
}

ensuredir(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil)
		return;
	for(i := len path - 1; i > 0; i--)
		if(path[i] == '/') {
			ensuredir(path[0:i]);
			break;
		}
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

# ── 9P Server ──────────────────────────────────────────────

start9p()
{
	# The navigator serves real directories (library/, out/) and
	# needs readdir in every mode, not just GUI.
	if(readdir == nil)
		readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		nomod(Readdir->PATH);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "matrix: can't create pipe: %r\n");
		raise "fail:pipe";
	}

	navops := chan of ref Navop;
	spawn matrixnavigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;

	pidc := chan of int;
	spawn matrixserve(tchan, srv, pidc);
	<-pidc;

	ensuredir("/mnt/matrix");
	if(sys->mount(fds[1], nil, "/mnt/matrix", Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "matrix: mount failed: %r\n");
		raise "fail:mount";
	}
}

matrixserve(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWFD, 1::2::srv.fd.fd::nil);

Serve:
	while((gm := <-tchan) != nil) {
		pick m := gm {
		Readerror =>
			break Serve;

		Open =>
			c := srv.getfid(m.fid);
			if(c == nil) {
				srv.open(m);
				break;
			}
			mode := styxservers->openmode(m.mode);
			if(mode < 0) {
				srv.reply(ref Rmsg.Error(m.tag, Ebadarg));
				break;
			}
			c.data = nil;
			qid := Qid(c.path, 0, c.qtype);
			c.open(mode, qid);
			srv.reply(ref Rmsg.Open(m.tag, qid, srv.iounit()));

		Read =>
			(c, err) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}

			case TYPE(c.path) {
			Qctl =>
				status := "idle";
				<-complock;
				if(comp != nil && (comp.layout != nil || comp.services != nil))
					status = "running";
				complock <-= 1;
				srv.reply(styxservers->readbytes(m, array of byte (status + "\n")));

			Qcomposition =>
				<-complock;
				text := "";
				if(comp != nil)
					text = comp.text;
				complock <-= 1;
				srv.reply(styxservers->readbytes(m, array of byte text));

			Qnotifications =>
				srv.reply(styxservers->readbytes(m, array of byte notifbuf));

			Qmodctl =>
				ms := liveslot(c.path);
				if(ms == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte (modstatus(ms.name, ms.mtype) + "\n")));

			Qmodtype =>
				ms := liveslot(c.path);
				if(ms == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte (ms.mtype + "\n")));

			Qmodmount =>
				ms := liveslot(c.path);
				if(ms == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				srv.reply(styxservers->readbytes(m, array of byte (ms.mount + "\n")));

			Qpass =>
				# Raw byte passthrough: .dis binaries and live service
				# outputs must not round-trip through string.
				i := PASSIDX(c.path);
				if(i < 0 || i >= npass) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				fd := sys->open(passtab[i].rpath, Sys->OREAD);
				if(fd == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				buf := array[m.count] of byte;
				nr := sys->pread(fd, buf, len buf, m.offset);
				if(nr < 0) {
					srv.reply(ref Rmsg.Error(m.tag, sys->sprint("%r")));
					break;
				}
				srv.reply(ref Rmsg.Read(m.tag, buf[0:nr]));

			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Write =>
			(c, merr) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, merr));
				break;
			}

			qtype := TYPE(c.path);
			data := string m.data;
			if(len data > 0 && data[len data - 1] == '\n')
				data = data[0:len data - 1];

			case qtype {
			Qctl =>
				ctlerr := handlectl(data);
				if(ctlerr != nil)
					srv.reply(ref Rmsg.Error(m.tag, ctlerr));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));

			Qcomposition =>
				# Write new composition → trigger reload
				alt {
				reloadch <-= string m.data =>
					;
				* =>
					;  # drop if reload already pending
				}
				srv.reply(ref Rmsg.Write(m.tag, len m.data));

			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Clunk =>
			srv.clunk(m);

		Remove =>
			srv.remove(m);

		* =>
			srv.default(gm);
		}
	}
}

handlectl(data: string): string
{
	if(len data > 5 && data[0:5] == "load ") {
		name := data[5:];
		text: string;
		if(name == "-") {
			<-complock;
			if(comp != nil)
				text = comp.text;
			complock <-= 1;
		} else {
			path := "/lib/matrix/compositions/" + name;
			text = readfile(path);
			if(text == nil)
				return "composition not found: " + name;
			comppath = path;
			compname = name;
		}
		alt {
		reloadch <-= text =>
			;
		* =>
			;
		}
		return nil;
	}

	if(data == "unload") {
		comppath = "";
		compname = "";
		alt {
		reloadch <-= "# empty\n" =>
			;
		* =>
			;
		}
		return nil;
	}

	if(len data > 4 && data[0:4] == "pin ") {
		name := data[4:];
		<-complock;
		text := "";
		if(comp != nil)
			text = comp.text;
		complock <-= 1;
		if(text == "")
			return "no composition to pin";
		ensuredir("/lib/matrix/compositions");
		werr := writefile("/lib/matrix/compositions/" + name, text);
		if(werr != nil)
			return werr;
		return nil;
	}

	if(len data > 6 && data[0:6] == "unpin ") {
		name := data[6:];
		if(sys->remove("/lib/matrix/compositions/" + name) < 0)
			return sys->sprint("cannot remove: %r");
		return nil;
	}

	return "usage: load <name>|load -|unload|pin <name>|unpin <name>";
}

# ── Qid packing ─────────────────────────────────────────────

TYPE(path: big): int
{
	return int path & 16rFF;
}

MODSLOT(path: big): int
{
	return (int (path >> 8)) & 16rFFF;
}

PASSIDX(path: big): int
{
	return int ((path >> 20) & big 16rFFFFFF);
}

QPATH(t, slot, pass: int): big
{
	return big t | (big slot << 8) | (big pass << 20);
}

# ── Module slot registry ────────────────────────────────────

# Current (name, mtype, mount, running) tuples from the composition.
# Caller holds complock.
collectmods(): list of (string, string, string, int)
{
	mods: list of (string, string, string, int);
	if(comp == nil)
		return nil;
	if(comp.layout != nil)
		mods = collectleaves(comp.layout, mods);
	for(sl := comp.services; sl != nil; sl = tl sl) {
		se := hd sl;
		mods = (se.name, "service", se.mount, se.mod != nil) :: mods;
	}
	return mods;
}

collectleaves(node: ref LayoutNode, acc: list of (string, string, string, int)): list of (string, string, string, int)
{
	pick n := node {
	Split =>
		acc = collectleaves(n.child1, acc);
		acc = collectleaves(n.child2, acc);
	Leaf =>
		if(n.modname != "")
			acc = (n.modname, "display", n.mount, n.mod != nil) :: acc;
	}
	return acc;
}

# Re-sync the slot registry with the live composition.  Existing
# names keep their slot (revived if dead); new names append; names
# absent from the new composition go !live.  Never renumbers.
syncmodslots()
{
	<-complock;
	mods := collectmods();
	complock <-= 1;

	for(i := 0; i < nmodslots; i++)
		modslots[i].live = 0;
	for(ml := mods; ml != nil; ml = tl ml) {
		(name, mtype, mount, nil) := hd ml;
		slot := -1;
		for(i = 0; i < nmodslots; i++)
			if(modslots[i].name == name) {
				slot = i;
				break;
			}
		if(slot < 0) {
			if(modslots == nil || nmodslots == len modslots) {
				grown := array[nmodslots + 16] of ref ModSlot;
				grown[0:] = modslots[0:nmodslots];
				modslots = grown;
			}
			slot = nmodslots++;
			modslots[slot] = ref ModSlot(name, mtype, mount, 1);
		} else {
			modslots[slot].mtype = mtype;
			modslots[slot].mount = mount;
			modslots[slot].live = 1;
		}
	}
}

liveslot(path: big): ref ModSlot
{
	slot := MODSLOT(path);
	if(slot < 0 || slot >= nmodslots)
		return nil;
	ms := modslots[slot];
	if(ms == nil || !ms.live)
		return nil;
	return ms;
}

# Module status computed from the live composition at read time.
modstatus(name, mtype: string): string
{
	status := "stopped";
	<-complock;
	for(ml := collectmods(); ml != nil; ml = tl ml) {
		(mname, mmtype, nil, running) := hd ml;
		if(mname == name && mmtype == mtype) {
			if(running)
				status = "running";
			break;
		}
	}
	complock <-= 1;
	return status;
}

# ── Passthrough registry ────────────────────────────────────

passfor(parentq: big, rpath: string): int
{
	for(i := 0; i < npass; i++)
		if(passtab[i].rpath == rpath)
			return i;
	if(passtab == nil || npass == len passtab) {
		grown := array[npass + 32] of ref PassEnt;
		grown[0:] = passtab[0:npass];
		passtab = grown;
	}
	passtab[npass] = ref PassEnt(rpath, parentq);
	return npass++;
}

# Real directory behind a passthrough-capable dir qid, or nil.
realdirof(path: big): string
{
	case TYPE(path) {
	Qlibcompsdir =>
		return LIBCOMPS;
	Qlibmodsdir =>
		return LIBMODS;
	Qmodout =>
		ms := liveslot(path);
		if(ms == nil || ms.mtype != "service")
			return nil;
		return OUTBASE + "/" + ms.name;
	Qpass =>
		i := PASSIDX(path);
		if(i < 0 || i >= npass)
			return nil;
		return passtab[i].rpath;
	}
	return nil;
}

# ── notifications ───────────────────────────────────────────

notifappend(line: string)
{
	notifbuf += line + "\n";
	# Drop oldest whole lines once over budget.
	for(guard := 0; len notifbuf > NOTIFMAX && guard < 1000; guard++) {
		cut := 0;
		for(i := 0; i < len notifbuf; i++)
			if(notifbuf[i] == '\n') {
				cut = i + 1;
				break;
			}
		if(cut == 0)
			break;
		notifbuf = notifbuf[cut:];
	}
}

dir(qid: Sys->Qid, name: string, length: big, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(qid.qtype & Sys->QTDIR)
		perm |= Sys->DMDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = length;
	return d;
}

dirgen(p: big): (ref Sys->Dir, string)
{
	case TYPE(p) {
	Qroot =>
		return (dir(Qid(p, vers, Sys->QTDIR), ".", big 0, 8r755), nil);
	Qctl =>
		return (dir(Qid(p, vers, Sys->QTFILE), "ctl", big 0, 8r644), nil);
	Qcomposition =>
		return (dir(Qid(p, vers, Sys->QTFILE), "composition", big 0, 8r644), nil);
	Qmoddir =>
		return (dir(Qid(p, vers, Sys->QTDIR), "modules", big 0, 8r755), nil);
	Qlibdir =>
		return (dir(Qid(p, vers, Sys->QTDIR), "library", big 0, 8r555), nil);
	Qlibcompsdir =>
		return (dir(Qid(p, vers, Sys->QTDIR), "compositions", big 0, 8r555), nil);
	Qlibmodsdir =>
		return (dir(Qid(p, vers, Sys->QTDIR), "modules", big 0, 8r555), nil);
	Qnotifications =>
		return (dir(Qid(p, vers, Sys->QTFILE), "notifications", big len array of byte notifbuf, 8r444), nil);
	Qmoddirent =>
		ms := liveslot(p);
		if(ms == nil)
			return (nil, Enotfound);
		return (dir(Qid(p, vers, Sys->QTDIR), ms.name, big 0, 8r555), nil);
	Qmodctl =>
		if(liveslot(p) == nil)
			return (nil, Enotfound);
		return (dir(Qid(p, vers, Sys->QTFILE), "ctl", big 0, 8r444), nil);
	Qmodtype =>
		if(liveslot(p) == nil)
			return (nil, Enotfound);
		return (dir(Qid(p, vers, Sys->QTFILE), "type", big 0, 8r444), nil);
	Qmodmount =>
		if(liveslot(p) == nil)
			return (nil, Enotfound);
		return (dir(Qid(p, vers, Sys->QTFILE), "mount", big 0, 8r444), nil);
	Qmodout =>
		rpath := realdirof(p);
		if(rpath == nil)
			return (nil, Enotfound);
		return (dir(Qid(p, vers, Sys->QTDIR), "out", big 0, 8r555), nil);
	Qpass =>
		i := PASSIDX(p);
		if(i < 0 || i >= npass)
			return (nil, Enotfound);
		(ok, sd) := sys->stat(passtab[i].rpath);
		if(ok < 0)
			return (nil, Enotfound);
		d := ref sys->zerodir;
		d.name = sd.name;
		d.uid = user;
		d.gid = user;
		d.length = sd.length;
		d.atime = sd.atime;
		d.mtime = sd.mtime;
		if(sd.mode & Sys->DMDIR) {
			d.qid = Qid(p, vers, Sys->QTDIR);
			d.mode = Sys->DMDIR | 8r555;
		} else {
			d.qid = Qid(p, vers, Sys->QTFILE);
			d.mode = 8r444;
		}
		return (d, nil);
	}

	return (nil, Enotfound);
}

# Emit the fixed children of a static dir for Readdir, honouring
# offset/count.  ents are qid paths in listing order.
replyfixed(n: ref Navop.Readdir, ents: array of big)
{
	i := n.offset;
	count := n.count;
	for(; i < len ents && count > 0; i++) {
		n.reply <-= dirgen(ents[i]);
		count--;
	}
	n.reply <-= (nil, nil);
}

# Readdir a passthrough-backed directory: enumerate the real dir,
# registering each child in passtab so its synthetic qid is stable.
replypassdir(n: ref Navop.Readdir, dirq: big, rpath: string)
{
	(entries, nent) := readdir->init(rpath, Readdir->NAME);
	i := n.offset;
	count := n.count;
	for(; i < nent && count > 0; i++) {
		idx := passfor(dirq, rpath + "/" + entries[i].name);
		n.reply <-= dirgen(QPATH(Qpass, 0, idx));
		count--;
	}
	n.reply <-= (nil, nil);
}

matrixnavigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);

		Walk =>
			qtype := TYPE(n.path);

			case qtype {
			Qroot =>
				case n.name {
				".." =>
					;
				"ctl" =>
					n.path = big Qctl;
				"composition" =>
					n.path = big Qcomposition;
				"modules" =>
					n.path = big Qmoddir;
				"library" =>
					n.path = big Qlibdir;
				"notifications" =>
					n.path = big Qnotifications;
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			Qmoddir =>
				if(n.name == "..") {
					n.path = big Qroot;
					n.reply <-= dirgen(n.path);
					continue;
				}
				found := 0;
				for(slot := 0; slot < nmodslots; slot++) {
					ms := modslots[slot];
					if(ms != nil && ms.live && ms.name == n.name) {
						n.path = QPATH(Qmoddirent, slot, 0);
						n.reply <-= dirgen(n.path);
						found = 1;
						break;
					}
				}
				if(!found)
					n.reply <-= (nil, Enotfound);

			Qmoddirent =>
				slot := MODSLOT(n.path);
				case n.name {
				".." =>
					n.path = big Qmoddir;
				"ctl" =>
					n.path = QPATH(Qmodctl, slot, 0);
				"type" =>
					n.path = QPATH(Qmodtype, slot, 0);
				"mount" =>
					n.path = QPATH(Qmodmount, slot, 0);
				"out" =>
					ms := liveslot(n.path);
					if(ms == nil || ms.mtype != "service") {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = QPATH(Qmodout, slot, 0);
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			Qlibdir =>
				case n.name {
				".." =>
					n.path = big Qroot;
				"compositions" =>
					n.path = big Qlibcompsdir;
				"modules" =>
					n.path = big Qlibmodsdir;
				* =>
					n.reply <-= (nil, Enotfound);
					continue;
				}
				n.reply <-= dirgen(n.path);

			Qlibcompsdir or Qlibmodsdir or Qmodout or Qpass =>
				if(n.name == "..") {
					case qtype {
					Qlibcompsdir or Qlibmodsdir =>
						n.path = big Qlibdir;
					Qmodout =>
						n.path = QPATH(Qmoddirent, MODSLOT(n.path), 0);
					Qpass =>
						i := PASSIDX(n.path);
						if(i < 0 || i >= npass) {
							n.reply <-= (nil, Enotfound);
							continue;
						}
						n.path = passtab[i].parentq;
					}
					n.reply <-= dirgen(n.path);
					continue;
				}
				rpath := realdirof(n.path);
				if(rpath == nil) {
					n.reply <-= (nil, Enotfound);
					continue;
				}
				child := rpath + "/" + n.name;
				(ok, nil) := sys->stat(child);
				if(ok < 0) {
					n.reply <-= (nil, Enotfound);
					continue;
				}
				idx := passfor(n.path, child);
				n.path = QPATH(Qpass, 0, idx);
				n.reply <-= dirgen(n.path);

			* =>
				n.reply <-= (nil, "not a directory");
			}

		Readdir =>
			qtype := TYPE(m.path);
			case qtype {
			Qroot =>
				replyfixed(n, array[] of {
					big Qctl, big Qcomposition, big Qmoddir,
					big Qlibdir, big Qnotifications});

			Qmoddir =>
				i := n.offset;
				count := n.count;
				seen := 0;
				for(slot := 0; slot < nmodslots && count > 0; slot++) {
					ms := modslots[slot];
					if(ms == nil || !ms.live)
						continue;
					if(seen >= i) {
						n.reply <-= dirgen(QPATH(Qmoddirent, slot, 0));
						count--;
					}
					seen++;
				}
				n.reply <-= (nil, nil);

			Qmoddirent =>
				slot := MODSLOT(m.path);
				ms := liveslot(m.path);
				if(ms == nil) {
					n.reply <-= (nil, Enotfound);
					continue;
				}
				if(ms.mtype == "service")
					replyfixed(n, array[] of {
						QPATH(Qmodctl, slot, 0), QPATH(Qmodtype, slot, 0),
						QPATH(Qmodmount, slot, 0), QPATH(Qmodout, slot, 0)});
				else
					replyfixed(n, array[] of {
						QPATH(Qmodctl, slot, 0), QPATH(Qmodtype, slot, 0),
						QPATH(Qmodmount, slot, 0)});

			Qlibdir =>
				replyfixed(n, array[] of {big Qlibcompsdir, big Qlibmodsdir});

			Qlibcompsdir or Qlibmodsdir or Qmodout or Qpass =>
				rpath := realdirof(m.path);
				if(rpath == nil) {
					n.reply <-= (nil, Enotfound);
					continue;
				}
				replypassdir(n, m.path, rpath);

			* =>
				n.reply <-= (nil, "not a directory");
			}
		}
	}
}

# ── GUI Mode ────────────────────────────────────────────────

initgui(ctxt: ref Draw->Context)
{
	draw = load Draw Draw->PATH;
	if(draw == nil)
		nomod(Draw->PATH);

	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	if(tk == nil || tkclient == nil)
		nomod(Tk->PATH);
	tkclient->init();

	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(top, wmctl) = tkclient->toplevel(ctxt, "-width 800 -height 600", "Matrix", Tkclient->Appl);
	display_g = top.display;

	font_g = Font.open(display_g, "/fonts/combined/unicode.sans.14.font");
	if(font_g == nil)
		font_g = Font.open(display_g, "*default*");

	if(readdir == nil)
		readdir = load Readdir Readdir->PATH;

	loadcolors();

	actch = chan[16] of string;
	tk->namechan(top, actch, "act");

	# The whole composited frame is a single Tk bitmap image in a label.
	tkcmds(array[] of {
		". configure -background " + bgcolstr,
		"image create bitmap mtx",
		"label .l -image mtx -borderwidth 0",
		"pack .l -fill both -expand 1",
		"pack propagate . 0",
		"bind .l <Button-3> {send act menu %X %Y}",
	});
	allocframe(800, 600);

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	updatech = chan of int;
	themech = chan[1] of int;

	if(comp.layout != nil)
		computelayout(comp.layout, winr);

	dirty = 1;
	spawn updatetimer();
	spawn themelistener();
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "matrix: tk error %s on %s\n", e, cmds[i]);
	}
}

# Allocate the off-screen composited frame at the given size.
allocframe(wd, ht: int)
{
	if(wd < 1) wd = 1;
	if(ht < 1) ht = 1;
	winr = Rect((0,0), (wd, ht));
	mtximg = display_g.newimage(winr, display_g.image.chans, 0, Draw->Nofill);
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgcolor   = display_g.color(th.bg);
		bgcolstr  = sys->sprint("#%06xff", (th.bg >> 8) & 16rFFFFFF);
		divcolor  = display_g.color(th.border);
		textcolor = display_g.color(th.text);
		dimcolor  = display_g.color(th.dim);
		redcolor  = display_g.color(th.red);
		greencolor= display_g.color(th.green);
		yellowcolor= display_g.color(th.yellow);
	} else {
		bgcolor   = display_g.color(int 16r1A1A2EFF);
		bgcolstr  = "#1a1a2eff";
		divcolor  = display_g.color(int 16r333355FF);
		textcolor = display_g.color(int 16rDDDDDDFF);
		dimcolor  = display_g.color(int 16r888888FF);
		redcolor  = display_g.color(int 16rFF4444FF);
		greencolor= display_g.color(int 16r44FF44FF);
		yellowcolor= display_g.color(int 16rFFFF44FF);
	}
}

updatetimer()
{
	for(;;) {
		sys->sleep(UPDATE_MS);
		alt {
		updatech <-= 1 =>
			;
		* =>
			;  # skip if main loop is busy
		}
	}
}

themelistener()
{
	# Use the canonical UI event stream (matrix was opening a
	# non-existent /lib/lucifer/theme/event path and silently
	# exiting, so it never received any theme events at all).
	fd := sys->open("/mnt/ui/event", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		ev := string buf[0:n];
		# INFR-28: reset client-side fid offset so the next read on
		# this streaming queue starts at 0 (otherwise the kernel
		# applies the accumulated offset to the server reply and
		# truncates / EOFs on the third read onward).
		sys->seek(fd, big 0, Sys->SEEKSTART);
		if(len ev >= 6 && ev[0:6] == "theme ")
			themech <-= 1;
	}
}

guiloop()
{
	for(;;) {
		if(dirty) {
			redraw();
			dirty = 0;
		}
		alt {
		c := <-wmctl or
		c = <-top.ctxt.ctl or
		# top.wreq carries Tk window requests (menu posts create their
		# window through here); a loop that never drains it leaves every
		# posted menu mapped-and-grabbing but windowless — invisible.
		c = <-top.wreq =>
			# The context menu tears its window down with "delete <tag>";
			# that is our signal it is gone, so stop intercepting pointer
			# events for it.
			if(len c >= 7 && c[0:7] == "delete ")
				menuposted = 0;
			tkclient->wmctl(top, c);
			if(c != nil && len c > 0 && c[0] == '!') {
				aw := int tk->cmd(top, ". cget -actwidth");
				ah := int tk->cmd(top, ". cget -actheight");
				if(aw > 0 && ah > 0)
					allocframe(aw, ah);
				if(comp.layout != nil)
					computelayout(comp.layout, winr);
				resizedisplaymodules(comp.layout);
				dirty = 1;
			}

		k := <-top.ctxt.kbd =>
			handlekey(k);

		ptr := <-top.ctxt.ptr =>
			if(menuposted) {
				# Context menu is up: route everything to Tk so it can
				# track the pointer, invoke an item, or dismiss.  menuposted
				# clears when the menu tears down (see the wreq arm above).
				tk->pointer(top, *ptr);
			} else if(ptr.buttons & 4) {
				# B3: let the Tk binding fire and post the context menu.
				menuposted = 1;
				tk->pointer(top, *ptr);
				lastbtn1 = 0;
			} else if(comp == nil || comp.layout == nil) {
				# Empty-state picker: edge-triggered button-1 click.
				cur := ptr.buttons & 1;
				if(cur && !lastbtn1)
					pickerclick(ptr.xy);
				lastbtn1 = cur;
			} else {
				lastbtn1 = ptr.buttons & 1;
				handleptr(ptr);
			}

		a := <-actch =>
			handleaction(a);

		<-updatech =>
			if(updatedisplaymodules(comp.layout))
				dirty = 1;

		newcomp := <-reloadch =>
			reloadcomposition(newcomp);
			dirty = 1;

		<-themech =>
			loadcolors();
			tkclient->wmctl(top, "retheme");
			tk->cmd(top, ". configure -background " + bgcolstr);
			rethemedisplaymodules(comp.layout);
			dirty = 1;
		}
	}
}

# Context-menu items (and any future bindings) post tokens here.
handleaction(a: string)
{
	(nil, toks) := sys->tokenize(a, " ");
	if(toks == nil)
		return;
	case hd toks {
	"menu" =>
		rebuildctxmenu();
		x := "40"; y := "40";
		if(tl toks != nil && tl tl toks != nil){
			x = hd tl toks;
			y = hd tl tl toks;
		}
		tk->cmd(top, sys->sprint(".ctx post %s %s", x, y));
	"m" =>
		if(tl toks != nil){
			i := int hd tl toks;
			if(i >= 0 && i < len ctxmenuactions)
				domenuitem(ctxmenuactions[i]);
			dirty = 1;
		}
	}
}

# ── Layout computation ──────────────────────────────────────

computelayout(node: ref LayoutNode, r: Rect)
{
	if(node == nil)
		return;
	pick n := node {
	Split =>
		n.r = r;
		total := n.ratio1 + n.ratio2;
		if(total <= 0)
			total = 2;
		case n.orient {
		HSPLIT =>
			splitx := r.min.x + r.dx() * n.ratio1 / total;
			computelayout(n.child1, Rect(r.min, (splitx - 1, r.max.y)));
			computelayout(n.child2, Rect((splitx + 1, r.min.y), r.max));
		VSPLIT =>
			splity := r.min.y + r.dy() * n.ratio1 / total;
			computelayout(n.child1, Rect(r.min, (r.max.x, splity - 1)));
			computelayout(n.child2, Rect((r.min.x, splity + 1), r.max));
		}
	Leaf =>
		n.r = r;
	}
}

# ── Drawing ─────────────────────────────────────────────────

redraw()
{
	if(top == nil || mtximg == nil)
		return;

	img := mtximg;
	img.draw(img.r, bgcolor, nil, (0, 0));

	if(comp != nil && comp.layout != nil)
		drawlayout(img, comp.layout);
	else
		drawpicker(img);

	# Composite the off-screen frame into the Tk label.
	tk->putimage(top, "mtx", img, nil);
	tk->cmd(top, "update");
}

# drawpicker — empty-state body.  Lists every composition in
# /lib/matrix/compositions/ as a clickable row.  Records the
# row rects + names in pickerrects/pickerhits so the ptr handler
# can map a left-click back to a `load <name>` ctl verb.
drawpicker(dst: ref Image)
{
	pickerrects = nil;
	pickerhits = nil;
	if(font_g == nil)
		return;

	r := dst.r;
	title := "Matrix — click a composition to load";
	hint  := "(long-press / right-click for the full menu)";
	pad := 12;
	rowh := font_g.height + 8;

	# Header.
	dst.text(Point(r.min.x + pad, r.min.y + pad + font_g.ascent),
		textcolor, (0, 0), font_g, title);
	dst.text(Point(r.min.x + pad, r.min.y + pad + font_g.ascent + rowh),
		dimcolor, (0, 0), font_g, hint);

	y := r.min.y + pad + 2 * rowh + rowh / 2;

	if(readdir == nil)
		readdir = load Readdir Readdir->PATH;
	entries: array of ref Sys->Dir;
	n := 0;
	if(readdir != nil)
		(entries, n) = readdir->init("/lib/matrix/compositions",
			Readdir->NAME);

	if(n == 0) {
		msg := "no compositions in /lib/matrix/compositions/";
		dst.text(Point(r.min.x + pad, y + font_g.ascent),
			dimcolor, (0, 0), font_g, msg);
		return;
	}

	hits := array[n] of string;
	rects := array[n] of Rect;
	nhit := 0;
	for(i := 0; i < n; i++) {
		nm := entries[i].name;
		if(nm == "" || nm[0] == '.')
			continue;
		row := Rect((r.min.x + pad, y),
			    (r.max.x - pad, y + rowh));
		# Subtle row background so the click affordance is visible.
		dst.draw(row, divcolor, nil, (0, 0));
		dst.text(Point(row.min.x + pad, y + font_g.ascent + 4),
			textcolor, (0, 0), font_g, nm);
		hits[nhit]  = nm;
		rects[nhit] = row;
		nhit++;
		y += rowh + 4;
		if(y >= r.max.y - rowh)
			break;
	}
	if(nhit < n) {
		pickerhits  = array[nhit] of string;
		pickerrects = array[nhit] of Rect;
		for(i = 0; i < nhit; i++) {
			pickerhits[i]  = hits[i];
			pickerrects[i] = rects[i];
		}
	} else {
		pickerhits  = hits;
		pickerrects = rects;
	}
}

# pickerclick — call when comp.layout is nil and the user left-clicks
# in the body.  Maps the click to a `load <name>` ctl verb.
pickerclick(at: Point)
{
	for(i := 0; i < len pickerrects; i++)
		if(pickerrects[i].contains(at)) {
			handlectl("load " + pickerhits[i]);
			return;
		}
}

drawlayout(dst: ref Image, node: ref LayoutNode)
{
	if(node == nil)
		return;
	pick n := node {
	Split =>
		drawlayout(dst, n.child1);
		drawlayout(dst, n.child2);
		# Draw divider
		c1r := noderect(n.child1);
		case n.orient {
		HSPLIT =>
			splitx := c1r.max.x + 1;
			divr := Rect((splitx - 1, n.r.min.y), (splitx, n.r.max.y));
			dst.draw(divr, divcolor, nil, (0, 0));
		VSPLIT =>
			splity := c1r.max.y + 1;
			divr := Rect((n.r.min.x, splity - 1), (n.r.max.x, splity));
			dst.draw(divr, divcolor, nil, (0, 0));
		}
	Leaf =>
		if(n.mod != nil) {
			n.mod->draw(dst);
		} else if(n.modname != "") {
			# Module not loaded — show placeholder
			label := n.modname + " @ " + n.mount;
			pt := Point(n.r.min.x + 8, n.r.min.y + 8 + font_g.height);
			dst.text(pt, dimcolor, (0, 0), font_g, label);
		}
	}
}

# Access rect of any layout node
noderect(node: ref LayoutNode): Rect
{
	pick n := node {
	Split => return n.r;
	Leaf => return n.r;
	}
	return Rect((0,0),(0,0));
}

# ── Module lifecycle ────────────────────────────────────────

loaddisplaymodules()
{
	if(comp == nil || comp.layout == nil)
		return;
	loadleafmodules(comp.layout);
}

loadleafmodules(node: ref LayoutNode)
{
	if(node == nil)
		return;
	pick n := node {
	Split =>
		loadleafmodules(n.child1);
		loadleafmodules(n.child2);
	Leaf =>
		if(n.modname == "" || n.mod != nil)
			return;
		path := "/dis/matrix/" + n.modname + ".dis";
		mod := load MatrixDisplay path;
		if(mod == nil) {
			sys->fprint(stderr, "matrix: cannot load display module %s: %r\n", path);
			return;
		}
		err := mod->init(display_g, font_g, n.mount);
		if(err != nil) {
			sys->fprint(stderr, "matrix: init %s: %s\n", n.modname, err);
			return;
		}
		mod->resize(n.r);
		n.mod = mod;
	}
}

loadservicemodules()
{
	if(comp == nil)
		return;
	for(sl := comp.services; sl != nil; sl = tl sl) {
		se := hd sl;
		if(se.mod != nil)
			continue;
		path := "/dis/matrix/" + se.name + ".dis";
		mod := load MatrixService path;
		if(mod == nil) {
			sys->fprint(stderr, "matrix: cannot load service module %s: %r\n", path);
			continue;
		}
		se.outdir = "/tmp/matrix/" + se.name;
		ensuredir(se.outdir);
		err := mod->init(se.mount, se.outdir);
		if(err != nil) {
			sys->fprint(stderr, "matrix: init %s: %s\n", se.name, err);
			continue;
		}
		se.mod = mod;
		spawn runservice(se);
	}
}

runservice(se: ref ServiceEntry)
{
	se.pid = sys->pctl(0, nil);
	se.mod->run();
	se.pid = 0;
}

# Update all display modules, return 1 if any changed
updatedisplaymodules(node: ref LayoutNode): int
{
	if(node == nil)
		return 0;
	pick n := node {
	Split =>
		c1 := updatedisplaymodules(n.child1);
		c2 := updatedisplaymodules(n.child2);
		return c1 | c2;
	Leaf =>
		if(n.mod != nil)
			return n.mod->update();
	}
	return 0;
}

resizedisplaymodules(node: ref LayoutNode)
{
	if(node == nil)
		return;
	pick n := node {
	Split =>
		resizedisplaymodules(n.child1);
		resizedisplaymodules(n.child2);
	Leaf =>
		if(n.mod != nil)
			n.mod->resize(n.r);
	}
}

rethemedisplaymodules(node: ref LayoutNode)
{
	if(node == nil)
		return;
	pick n := node {
	Split =>
		rethemedisplaymodules(n.child1);
		rethemedisplaymodules(n.child2);
	Leaf =>
		if(n.mod != nil)
			n.mod->retheme(display_g);
	}
}

shutdowndisplaymodules(node: ref LayoutNode)
{
	if(node == nil)
		return;
	pick n := node {
	Split =>
		shutdowndisplaymodules(n.child1);
		shutdowndisplaymodules(n.child2);
	Leaf =>
		if(n.mod != nil) {
			n.mod->shutdown();
			n.mod = nil;
		}
	}
}

shutdownservices(services: list of ref ServiceEntry)
{
	for(sl := services; sl != nil; sl = tl sl) {
		se := hd sl;
		if(se.mod != nil)
			se.mod->shutdown();
		se.mod = nil;
	}
}

# ── Right-click composition menu ────────────────────────────
#
# Items are rebuilt on every show so the menu reflects the current
# state of /lib/matrix/compositions/.  Each item has a parallel
# action string in ctxmenuactions[] consumed by domenuitem().
# Action verbs: "load <name>", "edit", "unload".

rebuildctxmenu()
{
	labels: list of string;
	actions: list of string;
	# "Load ..." entries, one per pinned composition.
	if(readdir != nil) {
		(entries, n) := readdir->init("/lib/matrix/compositions",
			Readdir->NAME);
		# Append in directory order so list reverse yields alphabetical.
		for(i := n - 1; i >= 0; i--) {
			nm := entries[i].name;
			if(nm == "" || nm[0] == '.')
				continue;
			labels = ("Load " + nm) :: labels;
			actions = ("load " + nm) :: actions;
		}
	}
	# Edit the currently-loaded composition (if any) in wm/editor.
	if(comppath != "") {
		labels = ("Edit " + compname) :: labels;
		actions = "edit" :: actions;
	}
	# Always-on: unload to the empty composition.
	labels = "Unload" :: labels;
	actions = "unload" :: actions;
	# Convert to arrays.
	nl := 0;
	for(p := labels; p != nil; p = tl p) nl++;
	aarr := array[nl] of string;
	larr := array[nl] of string;
	i := 0;
	for(p = labels; p != nil; p = tl p) { larr[i] = hd p; i++; }
	i = 0;
	for(p = actions; p != nil; p = tl p) { aarr[i] = hd p; i++; }
	ctxmenuactions = aarr;
	# Build the Tk menu: item i posts "act m i".
	tk->cmd(top, "destroy .ctx");
	tk->cmd(top, "menu .ctx");
	for(i = 0; i < nl; i++)
		tk->cmd(top, sys->sprint(".ctx add command -label %s -command {send act m %d}",
			tk->quote(larr[i]), i));
}

domenuitem(action: string)
{
	if(len action > 5 && action[0:5] == "load ") {
		handlectl(action);
		return;
	}
	if(action == "unload") {
		handlectl(action);
		return;
	}
	if(action == "edit") {
		if(comppath == "")
			return;
		# Route through luciuisrv's artifact ctl rather than spawning
		# wm/editor in matrix's own slot.  Each Lucifer app slot has a
		# single-shot appwm (lucifer.b:appwmrelay reads exactly once);
		# matrix already consumed its slot for its own window, so
		# `load Command "/dis/wm/editor.dis"; spawn ed->init(...)` would
		# leave editor's wmclient->window blocked with no reader.
		# Letting luciuisrv launch editor gives it its own slot + ctxt.
		s := readfile("/mnt/ui/activity/current");
		if(s == nil)
			s = "0";
		# Trim trailing whitespace from the activity id read.
		for(i := len s - 1; i >= 0; i--)
			if(s[i] != ' ' && s[i] != '\t' &&
			   s[i] != '\n' && s[i] != '\r') {
				s = s[0:i+1];
				break;
			}
		pctl := "/mnt/ui/activity/" + s + "/presentation/ctl";
		cmd := "create id=editor type=app dis=/dis/wm/editor.dis " +
			"label=Edit data=" + comppath;
		fd := sys->open(pctl, Sys->OWRITE);
		if(fd == nil) {
			sys->fprint(stderr, "matrix: cannot open %s: %r\n", pctl);
			return;
		}
		b := array of byte cmd;
		sys->write(fd, b, len b);
		fd = nil;
		# Surface the new editor tab.
		fd = sys->open(pctl, Sys->OWRITE);
		if(fd != nil) {
			cb := array of byte "center id=editor";
			sys->write(fd, cb, len cb);
		}
	}
}

basename(p: string): string
{
	for(i := len p - 1; i >= 0; i--)
		if(p[i] == '/')
			return p[i+1:];
	return p;
}

# ── Event routing ───────────────────────────────────────────

handleptr(p: ref Pointer)
{
	if(comp == nil || comp.layout == nil)
		return;
	routeptr(comp.layout, p);
	dirty = 1;
}

routeptr(node: ref LayoutNode, p: ref Pointer): int
{
	if(node == nil)
		return 0;
	pick n := node {
	Split =>
		if(routeptr(n.child1, p))
			return 1;
		return routeptr(n.child2, p);
	Leaf =>
		if(n.mod != nil && n.r.contains(p.xy)) {
			focusmod = n.mod;
			return n.mod->pointer(p);
		}
	}
	return 0;
}

handlekey(k: int)
{
	if(k < 0)
		return;
	if(focusmod != nil)
		focusmod->key(k);
}

# ── Composition reload ──────────────────────────────────────

reloadcomposition(text: string)
{
	(newcomp, err) := matrixlib->parsecomposition(text);
	if(err != nil) {
		sys->fprint(stderr, "matrix: reload parse error: %s\n", err);
		return;
	}

	# Incremental: entries unchanged between old and new keep their
	# live module instance (and, for services, their running proc).
	# transplant moves those handles into newcomp and nils them in
	# old; whatever old still holds is what actually shuts down.
	<-complock;
	old := comp;
	matrixlib->transplant(old, newcomp);
	comp = newcomp;
	complock <-= 1;

	# The focused module may just have been shut down; don't route
	# keys into a dead instance.
	focusmod = nil;

	if(old != nil) {
		shutdowndisplaymodules(old.layout);
		shutdownservices(old.services);
	}

	if(guimode && comp.layout != nil) {
		computelayout(comp.layout, winr);
		resizedisplaymodules(comp.layout);	# kept modules get new rects
		loaddisplaymodules();			# fills only empty leaves
	}
	loadservicemodules();				# starts only new services
	syncmodslots();
	vers++;
}

# ── Headless mode ───────────────────────────────────────────

headlessloop()
{
	for(;;) {
		alt {
		newcomp := <-reloadch =>
			reloadcomposition(newcomp);
		}
	}
}
