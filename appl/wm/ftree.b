implement Ftree;

#
# wm/ftree - Draw-based namespace browser and file tree viewer
#
# Browse the Inferno namespace as an expandable tree with live
# namespace metadata.  Shows bind sources, mount points, union
# directory layers, and permission flags inline.  Supports
# interactive namespace manipulation (bind, unmount).
#
# Uses the native widget toolkit — no Tk.
#
# Usage:
#   wm/ftree [-n] [root]
#   -n  start in namespace mode (annotate mount points)
#
# Keyboard:
#   Up/Down      move selection
#   Left         collapse directory / move to parent
#   Right/Enter  expand directory / plumb file
#   Page Up/Down scroll one screenful
#   Home/End     go to top/bottom
#   Ctrl-B       bind prompt
#   Ctrl-G       goto path prompt
#   Ctrl-N       toggle namespace annotations
#   Ctrl-U       unmount selected
#   Ctrl-Q       quit
#   r/R          refresh tree
#
# Mouse:
#   Button 1     select; click indicator to expand/collapse
#   Button 2     plumb selected file
#   Button 3     context menu
#   Scroll wheel scroll up/down
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "wmclient.m";
	wmclient: Wmclient;
	Window: import wmclient;

include "menu.m";
	menumod: Menu;
	Popup: import menumod;

include "readdir.m";
	readdir: Readdir;

include "string.m";
	str: String;

include "lucitheme.m";

include "widget.m";
	widgetmod: Widget;
	Scrollbar, Statusbar, Kbdfilter: import widgetmod;

include "arg.m";
	arg: Arg;

include "plumbmsg.m";
	plumbmod: Plumbmsg;
	Msg: import plumbmod;

Ftree: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# Veltro IPC directory
FTREE_DIR: con "/tmp/veltro/ftree";

# Fallback colours (overridden by theme)
BG:	con int 16rFFFDF6FF;
FG:	con int 16r333333FF;
DIRCOL:	con int 16r1A1A1AFF;
SELCOL:	con int 16rB4D5FEFF;
DIMCOL:	con int 16r999999FF;
MNTCOL:	con int 16r886644FF;	# mount annotation colour
DEVCOL:	con int 16r668844FF;	# device path colour

# Dimensions
MARGIN:		con 6;
INDENT:		con 16;
ICON_W:		con 14;

# Key constants
Khome:		con 16rFF61;
Kend:		con 16rFF57;
Kup:		con 16rFF52;
Kdown:		con 16rFF54;
Kleft:		con 16rFF51;
Kright:		con 16rFF53;
Kpgup:		con 16rFF55;
Kpgdown:	con 16rFF56;
Kdel:		con 16rFF9F;
Kins:		con 16rFF63;
Kbs:		con 8;
Kesc:		con 27;

# ---------- Namespace entry ----------

NsOp: adt {
	cmd:	string;		# "bind" or "mount"
	flags:	string;		# "-b", "-ac", etc. or ""
	src:	string;		# source path / device
	dst:	string;		# mount point (target)
	spec:	string;		# mount spec (or "")
};

# ---------- Tree node ----------

Node: adt {
	path:		string;
	name:		string;
	depth:		int;
	isdir:		int;
	expanded:	int;
	mode:		int;
	length:		big;
	loaded:		int;
	nchildren:	int;
	parent:		int;		# index of parent in nodes[], or -1

	# Namespace metadata
	bindsrc:	string;		# primary bind/mount source (e.g. "#c")
	bindflags:	string;		# flag string (e.g. "-b")
	bindcmd:	string;		# "bind" or "mount"
	nunion:		int;		# number of union layers (0 = not a union)
	unionlayers:	list of ref NsOp;	# union layers if > 1
	isdevice:	int;		# 1 = kernel device (#X path)
};

# ---------- Global state ----------

nodes:		array of ref Node;
nnodes:		int;
visible:	array of int;
nvisible:	int;

topline:	int;
vislines:	int;
selected:	int;

# Namespace state
nsops:		list of ref NsOp;	# parsed /dev/ns entries
nsmode:		int;			# 1 = show namespace annotations
nssnapshot:	string;			# snapshot of /dev/ns for change detection

# Display resources
display:	ref Display;
font:		ref Font;
bfont:		ref Font;
bgcolor:	ref Image;
fgcolor:	ref Image;
dircol:		ref Image;
selcolor:	ref Image;
dimcolor:	ref Image;
mntcolor:	ref Image;
devcolor:	ref Image;
accentcol:	ref Image;

scrollbar:	ref Scrollbar;
statbar:	ref Statusbar;
kbdfilter:	ref Kbdfilter;

w:		ref Window;
stderr:		ref Sys->FD;

rootpath:	string;

# Prompt modes
PROMPT_NONE: con 0;
PROMPT_GOTO: con 1;
PROMPT_BIND_SRC: con 2;
PROMPT_BIND_FLAGS: con 3;
promptmode := 0;
bindsrc_pending := "";		# stash source path during bind flow

# ---------- Initialisation ----------

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	wmclient = load Wmclient Wmclient->PATH;
	menumod = load Menu Menu->PATH;
	readdir = load Readdir Readdir->PATH;
	str = load String String->PATH;
	stderr = sys->fildes(2);

	if(wmclient == nil) {
		sys->fprint(stderr, "wm/ftree: cannot load Wmclient: %r\n");
		raise "fail:init";
	}
	if(readdir == nil) {
		sys->fprint(stderr, "wm/ftree: cannot load Readdir: %r\n");
		raise "fail:init";
	}

	widgetmod = load Widget Widget->PATH;
	if(widgetmod == nil) {
		sys->fprint(stderr, "wm/ftree: cannot load Widget: %r\n");
		raise "fail:init";
	}
	kbdfilter = Kbdfilter.new();

	if(ctxt == nil) {
		sys->fprint(stderr, "wm/ftree: no window context\n");
		raise "fail:no context";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	wmclient->init();

	# Parse arguments
	rootpath = "/";
	nsmode = 0;
	arg = load Arg Arg->PATH;
	if(arg != nil) {
		arg->init(argv);
		while((c := arg->opt()))
			case c {
			'n' =>
				nsmode = 1;
			}
		argv = arg->argv();
	} else
		argv = tl argv;
	if(argv != nil)
		rootpath = hd argv;

	# Create window
	w = wmclient->window(ctxt, "ftree", Wmclient->Appl);
	display = w.display;

	# Load fonts
	font = Font.open(display, "/fonts/combined/unicode.sans.14.font");
	if(font == nil)
		font = Font.open(display, "*default*");
	bfont = Font.open(display, "/fonts/combined/unicode.sans.bold.14.font");
	if(bfont == nil)
		bfont = font;

	# Load theme colours
	loadcolors();
	widgetmod->init(display, font);
	scrollbar = Scrollbar.new(Rect((0,0),(0,0)), 1);
	statbar = Statusbar.new(Rect((0,0),(0,0)));

	# Parse namespace
	nsops = nil;
	nssnapshot = "";
	loadnamespace();

	# Initialise tree
	nodes = array[4096] of ref Node;
	nnodes = 0;
	visible = array[4096] of int;
	nvisible = 0;
	topline = 0;
	selected = 0;

	addnode(rootpath, basename(rootpath), 0, 1, -1);
	if(nnodes > 0) {
		nodes[0].expanded = 1;
		loadchildren(0);
		rebuildvisible();
	}

	w.reshape(Rect((0, 0), (480, 560)));
	w.startinput("kbd" :: "ptr" :: nil);
	w.onscreen(nil);

	if(menumod != nil)
		menumod->init(display, bfont);
	menu := menumod->newgen(menugenfn);

	# Veltro IPC
	initftreedir();
	writeftreestate();
	ticks := chan of int;
	spawn timer(ticks, 500);

	# Namespace change watcher
	nsch := chan[1] of int;
	spawn nswatcher(nsch);

	# Theme listener
	themech := chan[1] of int;
	spawn themelistener(themech);

	redraw();

	for(;;) alt {
	<-themech =>
		reloadcolors();
		redraw();
	<-nsch =>
		loadnamespace();
		annotatenodes();
		redraw();
	<-ticks =>
		if(checkctlfile())
			redraw();
	ctl := <-w.ctl or
	ctl = <-w.ctxt.ctl =>
		w.wmctl(ctl);
		if(ctl != nil && ctl[0] == '!')
			redraw();

	rawkey := <-w.ctxt.kbd =>
		key := kbdfilter.filter(rawkey);
		if(key >= 0) {
			if(statbar.prompt != nil) {
				(done, val) := statbar.key(key);
				if(done == 1) {
					statbar.prompt = nil;
					handleprompt(val);
					promptmode = PROMPT_NONE;
				} else if(done < 0) {
					statbar.prompt = nil;
					promptmode = PROMPT_NONE;
				}
				redraw();
			} else
				handlekey(key);
		}

	p := <-w.ctxt.ptr =>
		if(p.buttons == 0 && scrollbar.isactive()) {
			newo := scrollbar.track(p);
			if(newo >= 0) {
				topline = newo;
				redraw();
			}
		} else if(scrollbar.isactive()) {
			newo := scrollbar.track(p);
			if(newo >= 0) {
				topline = newo;
				redraw();
			}
		} else if(p.buttons & 16r18) {
			scrollbar.total = nvisible;
			scrollbar.visible = vislines;
			scrollbar.origin = topline;
			topline = scrollbar.wheel(p.buttons, 3);
			redraw();
		} else if(p.buttons & 4) {
			# Button 3 — context menu
			if(menu != nil) {
				n := menu.show(w.image, p.xy, w.ctxt.ptr);
				handlemenu(n);
			}
		} else if(p.buttons & 2) {
			# Button 2 — plumb
			plumbselected();
		} else if(p.buttons & 1) {
			sr := scrollrect();
			if(sr.contains(p.xy)) {
				scrollbar.total = nvisible;
				scrollbar.visible = vislines;
				scrollbar.origin = topline;
				newo := scrollbar.event(p);
				if(newo >= 0) {
					topline = newo;
					redraw();
				}
			} else {
				clicktree(p.xy);
			}
		} else
			w.pointer(*p);
	}
}

# ---------- Context menu ----------

menugenfn(m: ref Popup)
{
	if(selected >= 0 && selected < nvisible) {
		ni := visible[selected];
		n := nodes[ni];
		if(n.isdir) {
			if(n.bindsrc != nil)
				m.items = array[] of {
					"open", "bind here...",
					"unmount", "expand all",
					"collapse all", "refresh",
					"ns mode " + nsmodetoggle(),
					"goto", "exit"};
			else
				m.items = array[] of {
					"open", "bind here...",
					"expand all", "collapse all",
					"refresh",
					"ns mode " + nsmodetoggle(),
					"goto", "exit"};
		} else
			m.items = array[] of {
				"plumb", "bind here...",
				"refresh",
				"ns mode " + nsmodetoggle(),
				"goto", "exit"};
	} else
		m.items = array[] of {
			"refresh",
			"ns mode " + nsmodetoggle(),
			"goto", "exit"};
}

nsmodetoggle(): string
{
	if(nsmode)
		return "off";
	return "on";
}

handlemenu(n: int)
{
	if(n < 0)
		return;
	if(selected < 0 || selected >= nvisible) {
		# No selection — limited menu
		case n {
		0 =>	refreshtree();
		1 =>	togglensmode();
		2 =>	startgoto();
		3 =>	exit;
		}
		return;
	}

	ni := visible[selected];
	nd := nodes[ni];
	if(nd.isdir && nd.bindsrc != nil) {
		case n {
		0 =>	activateselected();
		1 =>	startbind();
		2 =>	dounmount(nd.path);
		3 =>	expandall();
		4 =>	collapseall();
		5 =>	refreshtree();
		6 =>	togglensmode();
		7 =>	startgoto();
		8 =>	exit;
		}
	} else if(nd.isdir) {
		case n {
		0 =>	activateselected();
		1 =>	startbind();
		2 =>	expandall();
		3 =>	collapseall();
		4 =>	refreshtree();
		5 =>	togglensmode();
		6 =>	startgoto();
		7 =>	exit;
		}
	} else {
		case n {
		0 =>	plumbselected();
		1 =>	startbind();
		2 =>	refreshtree();
		3 =>	togglensmode();
		4 =>	startgoto();
		5 =>	exit;
		}
	}
}

# ---------- Keyboard ----------

handlekey(key: int)
{
	case key {
	Kup =>
		if(selected > 0) selected--;
		scrolltoselected();
	Kdown =>
		if(selected < nvisible - 1) selected++;
		scrolltoselected();
	Kpgup =>
		selected -= vislines;
		if(selected < 0) selected = 0;
		scrolltoselected();
	Kpgdown =>
		selected += vislines;
		if(selected >= nvisible) selected = nvisible - 1;
		scrolltoselected();
	Khome =>
		selected = 0;
		topline = 0;
	Kend =>
		selected = nvisible - 1;
		scrolltoselected();
	Kright or '\n' =>
		activateselected();
	Kleft =>
		collapseselected();
	'q' & 16r1f =>
		exit;
	'g' & 16r1f =>
		startgoto();
	'b' & 16r1f =>
		startbind();
	'n' & 16r1f =>
		togglensmode();
	'u' & 16r1f =>
		unmountselected();
	'q' or 'Q' =>
		exit;
	'r' or 'R' =>
		refreshtree();
	'n' =>
		togglensmode();
	* =>
		return;
	}
	redraw();
}

handleprompt(val: string)
{
	case promptmode {
	PROMPT_GOTO =>
		gotopath(val);
	PROMPT_BIND_SRC =>
		if(val != nil && len val > 0) {
			bindsrc_pending = val;
			promptmode = PROMPT_BIND_FLAGS;
			statbar.prompt = "Flags [-b|-a|-bc]: ";
			statbar.buf = "";
		}
	PROMPT_BIND_FLAGS =>
		dobind(bindsrc_pending, val);
		bindsrc_pending = "";
	}
}

togglensmode()
{
	nsmode = 1 - nsmode;
	if(nsmode && nsops == nil)
		loadnamespace();
	annotatenodes();
	redraw();
}

scrolltoselected()
{
	if(selected < 0)
		selected = 0;
	if(selected >= nvisible)
		selected = nvisible - 1;
	if(selected < topline)
		topline = selected;
	else if(selected >= topline + vislines)
		topline = selected - vislines + 1;
	clamptop();
}

activateselected()
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	n := nodes[ni];
	if(n.isdir) {
		if(n.expanded)
			collapse(ni);
		else
			expand(ni);
		rebuildvisible();
	} else
		plumbfile(n.path);
}

collapseselected()
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	n := nodes[ni];
	if(n.isdir && n.expanded) {
		collapse(ni);
		rebuildvisible();
	} else if(n.parent >= 0) {
		pi := n.parent;
		for(i := 0; i < nvisible; i++) {
			if(visible[i] == pi) {
				selected = i;
				break;
			}
		}
		scrolltoselected();
	}
}

# ---------- Mouse ----------

clicktree(p: Point)
{
	tr := textrect();
	if(!tr.contains(p))
		return;
	fh := font.height;
	row := (p.y - tr.min.y) / fh;
	idx := topline + row;
	if(idx < 0 || idx >= nvisible)
		return;
	selected = idx;

	ni := visible[idx];
	n := nodes[ni];
	ix := tr.min.x + n.depth * INDENT;
	if(n.isdir && p.x >= ix && p.x < ix + ICON_W) {
		if(n.expanded)
			collapse(ni);
		else
			expand(ni);
		rebuildvisible();
	}
	redraw();
}

# ---------- Plumbing ----------

plumbselected()
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	n := nodes[ni];
	if(n.isdir)
		activateselected();
	else
		plumbfile(n.path);
}

plumbfile(path: string)
{
	if(plumbmod == nil) {
		plumbmod = load Plumbmsg Plumbmsg->PATH;
		if(plumbmod != nil)
			plumbmod->init(0, nil, 0);
	}
	if(plumbmod == nil) {
		statbar.right = "no plumber";
		redraw();
		return;
	}

	# Detect file type for smarter plumbing
	kind := "text";
	attrs := "";
	ext := fileext(path);
	case ext {
	"b" or "m" or "sh" =>
		attrs = "action=showfile";
	"dis" =>
		kind = "text";
		attrs = "action=showdata";
	"bit" or "jpg" or "jpeg" or "png" or "gif" =>
		kind = "image";
	"html" or "htm" =>
		kind = "text";
		attrs = "action=showurl";
	* =>
		attrs = "action=showfile";
	}

	msg := ref Plumbmsg->Msg(
		"ftree",
		nil,
		dirof(path),
		kind,
		attrs,
		array of byte path
	);
	if(msg.send() < 0)
		statbar.right = "plumb failed";
	else
		statbar.right = "plumbed " + basename(path);
	redraw();
}

fileext(path: string): string
{
	for(i := len path - 1; i >= 0; i--) {
		if(path[i] == '.')
			return path[i+1:];
		if(path[i] == '/')
			break;
	}
	return "";
}

dirof(path: string): string
{
	for(i := len path - 1; i >= 0; i--) {
		if(path[i] == '/')
			return path[:i+1];
	}
	return "/";
}

# ---------- Namespace parsing ----------

loadnamespace()
{
	pid := sys->pctl(0, nil);
	nspath := sys->sprint("/prog/%d/ns", pid);
	fd := sys->open(nspath, Sys->OREAD);
	if(fd == nil)
		return;

	nsops = nil;
	raw := "";
	buf := array[4096] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		chunk := string buf[0:n];
		raw += chunk;

		# Parse line (one ns entry per read)
		(ntoks, toks) := sys->tokenize(chunk, " \n");
		if(ntoks < 2)
			continue;
		cmd := hd toks;
		toks = tl toks;

		if(cmd == "cd")
			continue;

		if(cmd != "bind" && cmd != "mount")
			continue;

		flags := "";
		if(toks != nil && len hd toks > 0 && (hd toks)[0] == '-') {
			flags = hd toks;
			toks = tl toks;
		}
		if(len toks < 2)
			continue;

		src := hd toks;
		toks = tl toks;
		dst := hd toks;
		toks = tl toks;

		# Clean up kernel decoration
		if(len src >= 2 && src[0:2] == "#/")
			src = src[2:];
		if(dst == "#M")
			dst = "/";
		else if(len dst >= 2 && dst[0:2] == "#M")
			dst = dst[2:];

		spec := "";
		if(toks != nil)
			spec = hd toks;

		op := ref NsOp(cmd, flags, src, dst, spec);
		nsops = op :: nsops;
	}
	nssnapshot = raw;

	# Reverse to preserve order
	rev: list of ref NsOp;
	for(l := nsops; l != nil; l = tl l)
		rev = hd l :: rev;
	nsops = rev;
}

# Annotate existing tree nodes with namespace metadata
annotatenodes()
{
	if(!nsmode) {
		for(i := 0; i < nnodes; i++) {
			nodes[i].bindsrc = nil;
			nodes[i].bindflags = "";
			nodes[i].bindcmd = "";
			nodes[i].nunion = 0;
			nodes[i].unionlayers = nil;
			nodes[i].isdevice = 0;
		}
		return;
	}

	# Build a map: for each destination path, collect all ns ops
	for(i := 0; i < nnodes; i++) {
		n := nodes[i];
		n.bindsrc = nil;
		n.bindflags = "";
		n.bindcmd = "";
		n.nunion = 0;
		n.unionlayers = nil;
		n.isdevice = 0;

		layers: list of ref NsOp;
		nlayers := 0;
		lastop: ref NsOp;

		for(ops := nsops; ops != nil; ops = tl ops) {
			op := hd ops;
			if(pathmatch(op.dst, n.path)) {
				layers = op :: layers;
				nlayers++;
				lastop = op;
			}
		}

		if(nlayers > 0) {
			n.bindcmd = lastop.cmd;
			n.bindsrc = lastop.src;
			n.bindflags = lastop.flags;
			n.nunion = nlayers;
			if(nlayers > 1)
				n.unionlayers = layers;

			# Detect kernel devices (#X paths)
			if(len lastop.src > 0 && lastop.src[0] == '#')
				n.isdevice = 1;
		}
	}
}

pathmatch(a, b: string): int
{
	# Normalise: strip trailing /
	if(len a > 1 && a[len a - 1] == '/')
		a = a[:len a - 1];
	if(len b > 1 && b[len b - 1] == '/')
		b = b[:len b - 1];
	return a == b;
}

# ---------- Namespace operations ----------

startbind()
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	n := nodes[ni];
	target := n.path;
	if(!n.isdir)
		target = dirof(n.path);
	promptmode = PROMPT_BIND_SRC;
	statbar.prompt = "Bind src (onto " + target + "): ";
	statbar.buf = "";
	redraw();
}

startgoto()
{
	promptmode = PROMPT_GOTO;
	statbar.prompt = "Path: ";
	statbar.buf = "";
	redraw();
}

dobind(src, flagstr: string)
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	n := nodes[ni];
	target := n.path;
	if(!n.isdir)
		target = dirof(n.path);

	flags := Sys->MREPL;
	for(i := 0; i < len flagstr; i++) {
		case flagstr[i] {
		'b' =>	flags |= Sys->MBEFORE;
		'a' =>	flags |= Sys->MAFTER;
		'c' =>	flags |= Sys->MCREATE;
		}
	}
	rc := sys->bind(src, target, flags);
	if(rc < 0) {
		statbar.right = sys->sprint("bind failed: %r");
	} else {
		statbar.right = sys->sprint("bound %s on %s", src, target);
		# Refresh namespace and tree
		loadnamespace();
		refreshsubtree(ni);
		annotatenodes();
	}
	redraw();
}

unmountselected()
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	n := nodes[ni];
	if(!n.isdir || n.bindsrc == nil) {
		statbar.right = "no mount to remove";
		redraw();
		return;
	}
	dounmount(n.path);
}

dounmount(path: string)
{
	rc := sys->unmount(nil, path);
	if(rc < 0) {
		statbar.right = sys->sprint("unmount %s: %r", path);
	} else {
		statbar.right = "unmounted " + path;
		loadnamespace();
		refreshtree();
		annotatenodes();
	}
	redraw();
}

# ---------- Tree operations ----------

addnode(path, name: string, depth, isdir, parent: int): int
{
	if(nnodes >= len nodes) {
		newnodes := array[len nodes * 2] of ref Node;
		newnodes[0:] = nodes;
		nodes = newnodes;
	}
	n := ref Node(path, name, depth, isdir, 0, 0, big 0, 0, 0, parent,
		nil, "", "", 0, nil, 0);
	idx := nnodes;
	nodes[idx] = n;
	nnodes++;
	return idx;
}

loadchildren(pi: int)
{
	p := nodes[pi];
	if(p.loaded)
		return;
	p.loaded = 1;

	(dirs, n) := readdir->init(p.path, Readdir->NAME);
	if(n <= 0)
		return;

	insert := pi + 1;
	for(i := pi + 1; i < nnodes; i++) {
		if(nodes[i].depth <= p.depth)
			break;
		insert = i + 1;
	}

	count := n;
	if(nnodes + count > len nodes) {
		newnodes := array[(nnodes + count) * 2] of ref Node;
		newnodes[0:] = nodes[0:nnodes];
		nodes = newnodes;
	}
	if(insert < nnodes) {
		for(i := nnodes - 1; i >= insert; i--)
			nodes[i + count] = nodes[i];
		# Fix parent indices that shifted
		for(i = 0; i < nnodes + count; i++) {
			if(i >= insert && i < insert + count)
				continue;
			if(nodes[i] != nil && nodes[i].parent >= insert)
				nodes[i].parent += count;
		}
	}

	j := insert;
	# Directories first
	for(i = 0; i < n; i++) {
		d := dirs[i];
		if(d.mode & Sys->DMDIR) {
			childpath := joinpath(p.path, d.name);
			nodes[j] = ref Node(childpath, d.name, p.depth + 1,
				1, 0, d.mode, big d.length, 0, 0, pi,
				nil, "", "", 0, nil, 0);
			j++;
		}
	}
	# Then files
	for(i = 0; i < n; i++) {
		d := dirs[i];
		if(!(d.mode & Sys->DMDIR)) {
			childpath := joinpath(p.path, d.name);
			nodes[j] = ref Node(childpath, d.name, p.depth + 1,
				0, 0, d.mode, big d.length, 0, 0, pi,
				nil, "", "", 0, nil, 0);
			j++;
		}
	}
	nnodes += count;
	p.nchildren = count;

	if(nsmode)
		annotatenodes();
}

joinpath(dir, name: string): string
{
	if(dir == "/")
		return "/" + name;
	return dir + "/" + name;
}

expand(ni: int)
{
	n := nodes[ni];
	if(!n.isdir)
		return;
	if(!n.loaded)
		loadchildren(ni);
	n.expanded = 1;
}

collapse(ni: int)
{
	n := nodes[ni];
	if(!n.isdir)
		return;
	for(i := ni + 1; i < nnodes; i++) {
		if(nodes[i].depth <= n.depth)
			break;
		if(nodes[i].isdir)
			nodes[i].expanded = 0;
	}
	n.expanded = 0;
}

expandall()
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	expandsubtree(ni);
	rebuildvisible();
	redraw();
}

expandsubtree(ni: int)
{
	n := nodes[ni];
	if(!n.isdir)
		return;
	expand(ni);
	for(i := ni + 1; i < nnodes; i++) {
		if(nodes[i].depth <= n.depth)
			break;
		if(nodes[i].isdir)
			expand(i);
	}
}

collapseall()
{
	for(i := 0; i < nnodes; i++) {
		if(nodes[i].isdir && i > 0)
			nodes[i].expanded = 0;
	}
	selected = 0;
	topline = 0;
	rebuildvisible();
	redraw();
}

refreshtree()
{
	selpath := "";
	if(selected >= 0 && selected < nvisible)
		selpath = nodes[visible[selected]].path;

	nnodes = 0;
	addnode(rootpath, basename(rootpath), 0, 1, -1);
	if(nnodes > 0) {
		nodes[0].expanded = 1;
		nodes[0].loaded = 0;
		loadchildren(0);
		rebuildvisible();
	}

	loadnamespace();
	annotatenodes();

	selected = 0;
	for(i := 0; i < nvisible; i++) {
		if(nodes[visible[i]].path == selpath) {
			selected = i;
			break;
		}
	}
	scrolltoselected();
	redraw();
}

refreshsubtree(ni: int)
{
	n := nodes[ni];
	if(!n.isdir)
		return;
	# Mark as unloaded so next expand re-reads
	n.loaded = 0;
	n.nchildren = 0;
	# Remove children from nodes array
	first := ni + 1;
	last := first;
	for(i := first; i < nnodes; i++) {
		if(nodes[i].depth <= n.depth)
			break;
		last = i + 1;
	}
	count := last - first;
	if(count > 0) {
		for(i := last; i < nnodes; i++) {
			nodes[i - count] = nodes[i];
			if(nodes[i - count].parent >= last)
				nodes[i - count].parent -= count;
		}
		nnodes -= count;
	}
	# Re-expand if it was expanded
	if(n.expanded) {
		n.expanded = 0;
		expand(ni);
	}
	rebuildvisible();
}

rebuildvisible()
{
	if(nnodes > len visible)
		visible = array[nnodes * 2] of int;
	nvisible = 0;
	for(i := 0; i < nnodes; i++) {
		vis := 1;
		pi := nodes[i].parent;
		while(pi >= 0) {
			if(!nodes[pi].expanded) {
				vis = 0;
				break;
			}
			pi = nodes[pi].parent;
		}
		if(vis) {
			if(nvisible >= len visible) {
				newvis := array[len visible * 2] of int;
				newvis[0:] = visible[0:nvisible];
				visible = newvis;
			}
			visible[nvisible] = i;
			nvisible++;
		}
	}
	if(selected >= nvisible)
		selected = nvisible - 1;
	if(selected < 0 && nvisible > 0)
		selected = 0;
}

# ---------- Rendering ----------

textrect(): Rect
{
	r := w.image.r;
	sth := widgetmod->statusheight();
	sw := widgetmod->scrollwidth();
	return Rect((r.min.x + sw + MARGIN, r.min.y + MARGIN),
		    (r.max.x - MARGIN, r.max.y - sth));
}

scrollrect(): Rect
{
	r := w.image.r;
	sth := widgetmod->statusheight();
	return Rect((r.min.x, r.min.y), (r.min.x + widgetmod->scrollwidth(), r.max.y - sth));
}

redraw()
{
	screen := w.image;
	if(screen == nil)
		return;

	r := screen.r;
	ZP := Point(0, 0);

	screen.draw(r, bgcolor, nil, ZP);

	tr := textrect();
	fh := font.height;
	maxvrows := tr.dy() / fh;
	if(maxvrows < 1)
		maxvrows = 1;
	vislines = maxvrows;

	y := tr.min.y;
	for(i := topline; i < nvisible && (y + fh) <= tr.max.y; i++) {
		ni := visible[i];
		n := nodes[ni];

		# Selection highlight
		if(i == selected) {
			hr := Rect((tr.min.x - 2, y), (tr.max.x, y + fh));
			screen.draw(hr, selcolor, nil, ZP);
		}

		x := tr.min.x + n.depth * INDENT;

		# Expand/collapse indicator
		if(n.isdir)
			drawexpander(screen, Point(x, y), fh, n.expanded);
		x += ICON_W;

		# Name
		f := font;
		col := fgcolor;
		if(n.isdir) {
			f = bfont;
			col = dircol;
		}
		if(n.isdevice)
			col = devcolor;

		name := n.name;
		if(n.isdir)
			name += "/";

		# Calculate available width for name + annotation
		rightx := tr.max.x;
		annot := "";
		annotw := 0;
		if(nsmode && n.bindsrc != nil) {
			annot = nsannotation(n);
			annotw = font.width(annot) + 8;
		} else if(!n.isdir && n.length >= big 0) {
			annot = fmtsize(n.length);
			annotw = font.width(annot) + 8;
		}

		maxw := rightx - x - annotw;
		if(maxw > 0) {
			tw := f.width(name);
			if(tw > maxw) {
				for(k := len name; k > 0; k--) {
					if(f.width(name[:k]) <= maxw - font.width("..")) {
						name = name[:k] + "..";
						break;
					}
				}
			}
			screen.text(Point(x, y), col, ZP, f, name);

			# Right-aligned annotation
			if(annotw > 0 && len annot > 0) {
				ax := rightx - font.width(annot);
				acol := dimcolor;
				if(nsmode && n.bindsrc != nil)
					acol = mntcolor;
				screen.text(Point(ax, y), acol, ZP, font, annot);
			}
		}

		y += fh;
	}

	# Scrollbar
	sr := scrollrect();
	scrollbar.resize(sr);
	scrollbar.total = nvisible;
	scrollbar.visible = vislines;
	scrollbar.origin = topline;
	scrollbar.draw(screen);

	# Status bar
	sth := widgetmod->statusheight();
	statbar.resize(Rect((r.min.x, r.max.y - sth), (r.max.x, r.max.y)));
	if(statbar.prompt == nil) {
		if(selected >= 0 && selected < nvisible) {
			nd := nodes[visible[selected]];
			statbar.left = nd.path;
			if(nsmode && nd.bindsrc != nil)
				statbar.right = nd.bindcmd + " " + nd.bindflags + " " + nd.bindsrc;
			else
				statbar.right = sys->sprint("%d items", nvisible);
		} else {
			statbar.left = rootpath;
			statbar.right = sys->sprint("%d items", nvisible);
		}
	}
	statbar.draw(screen);
	# INFR-27: window border is the wmclient frame (th.windowborder).
	# Don't draw widget.contentborder here — it would paint th.accent
	# over the wmclient frame and break border consistency across apps.

	screen.flush(Draw->Flushnow);
}

nsannotation(n: ref Node): string
{
	if(n.bindsrc == nil)
		return "";
	s := "";
	if(n.nunion > 1)
		s += "[+" + string (n.nunion - 1) + "] ";
	# Show source: trim long paths
	src := n.bindsrc;
	if(len src > 20)
		src = ".." + src[len src - 18:];
	flags := "";
	if(n.bindflags != nil && len n.bindflags > 0)
		flags = n.bindflags + " ";
	s += flags + src;
	return s;
}

drawexpander(screen: ref Image, p: Point, fh: int, expanded: int)
{
	ZP := Point(0, 0);
	cx := p.x + ICON_W / 2;
	cy := p.y + fh / 2;
	sz := 4;

	if(expanded) {
		for(i := 0; i <= sz; i++) {
			x0 := cx - sz + i;
			x1 := cx + sz - i;
			screen.line(Point(x0, cy - sz/2 + i), Point(x1, cy - sz/2 + i),
				0, 0, 0, dimcolor, ZP);
		}
	} else {
		for(i := 0; i <= sz; i++) {
			y0 := cy - sz + i;
			y1 := cy + sz - i;
			screen.line(Point(cx - sz/2 + i, y0), Point(cx - sz/2 + i, y1),
				0, 0, 0, dimcolor, ZP);
		}
	}
}

fmtsize(n: big): string
{
	if(n < big 1024)
		return sys->sprint("%bd", n);
	if(n < big 1048576)
		return sys->sprint("%bdK", n / big 1024);
	if(n < big 1073741824)
		return sys->sprint("%bdM", n / big 1048576);
	return sys->sprint("%bdG", n / big 1073741824);
}

# ---------- Navigation ----------

gotopath(path: string)
{
	if(path == nil || len path == 0)
		return;
	(ok, d) := sys->stat(path);
	if(ok < 0) {
		statbar.right = path + ": not found";
		return;
	}
	if(!(d.mode & Sys->DMDIR)) {
		plumbfile(path);
		return;
	}
	rootpath = path;
	nnodes = 0;
	addnode(rootpath, basename(rootpath), 0, 1, -1);
	if(nnodes > 0) {
		nodes[0].expanded = 1;
		loadchildren(0);
		rebuildvisible();
	}
	loadnamespace();
	annotatenodes();
	selected = 0;
	topline = 0;
	w.settitle("ftree — " + rootpath);
}

# ---------- Helpers ----------

clamptop()
{
	max := nvisible - vislines;
	if(max < 0)
		max = 0;
	if(topline > max)
		topline = max;
	if(topline < 0)
		topline = 0;
}

basename(path: string): string
{
	if(path == "/")
		return "/";
	for(i := len path - 1; i >= 0; i--) {
		if(path[i] == '/') {
			if(i < len path - 1)
				return path[i+1:];
		}
	}
	return path;
}

# ---------- Colour management ----------

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		bgcolor = display.color(th.editbg);
		fgcolor = display.color(th.edittext);
		dircol = display.color(th.text);
		selcolor = display.color(th.accent);
		dimcolor = display.color(th.dim);
		mntcolor = display.color(th.yellow);
		devcolor = display.color(th.green);
		accentcol = display.color(th.accent);
	} else {
		bgcolor = display.color(BG);
		fgcolor = display.color(FG);
		dircol = display.color(DIRCOL);
		selcolor = display.color(SELCOL);
		dimcolor = display.color(DIMCOL);
		mntcolor = display.color(MNTCOL);
		devcolor = display.color(DEVCOL);
		accentcol = display.color(SELCOL);
	}
}

reloadcolors()
{
	loadcolors();
	widgetmod->retheme(display);
	wmclient->retheme(w);
	if(menumod != nil)
		menumod->init(display, bfont);
}

# ---------- Namespace change watcher ----------

nswatcher(ch: chan of int)
{
	for(;;) {
		sys->sleep(2000);
		pid := sys->pctl(0, nil);
		nspath := sys->sprint("/prog/%d/ns", pid);
		fd := sys->open(nspath, Sys->OREAD);
		if(fd == nil)
			continue;
		raw := "";
		buf := array[4096] of byte;
		for(;;) {
			n := sys->read(fd, buf, len buf);
			if(n <= 0)
				break;
			raw += string buf[0:n];
		}
		if(raw != nssnapshot)
			alt { ch <-= 1 => ; * => ; }
	}
}

# ---------- Theme listener ----------

themelistener(ch: chan of int)
{
	fd := sys->open("/n/ui/event", Sys->OREAD);
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
			ch <-= 1;
	}
}

# ---------- Timer ----------

timer(c: chan of int, ms: int)
{
	for(;;) {
		sys->sleep(ms);
		c <-= 1;
	}
}

# ---------- Veltro real-file IPC ----------

initftreedir()
{
	mkdirq("/tmp/veltro");
	mkdirq(FTREE_DIR);
}

mkdirq(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd != nil) {
		fd = nil;
		return;
	}
	fd = sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
	fd = nil;
}

writeftreestate()
{
	state := sys->sprint("root %s\n", rootpath);
	state += sys->sprint("nsmode %d\n", nsmode);
	if(selected >= 0 && selected < nvisible) {
		nd := nodes[visible[selected]];
		state += sys->sprint("selected %s\n", nd.path);
		if(nsmode && nd.bindsrc != nil)
			state += sys->sprint("bindsrc %s\n", nd.bindsrc);
	}
	state += sys->sprint("items %d\n", nvisible);
	state += sys->sprint("topline %d\n", topline);
	state += sys->sprint("visible %d\n", vislines);

	# Plain text listing for AI context
	view := sys->sprint("File tree: %s", rootpath);
	if(nsmode)
		view += " [ns mode]";
	view += "\n";
	view += sys->sprint("Items %d-%d of %d\n\n", topline + 1,
		min(topline + vislines, nvisible), nvisible);
	end := topline + vislines;
	if(end > nvisible)
		end = nvisible;
	for(i := topline; i < end; i++) {
		ni := visible[i];
		n := nodes[ni];
		indent := "";
		for(j := 0; j < n.depth; j++)
			indent += "  ";
		marker := "";
		if(n.isdir) {
			if(n.expanded)
				marker = "v ";
			else
				marker = "> ";
		} else
			marker = "  ";
		sel := "";
		if(i == selected)
			sel = "* ";
		view += sel + indent + marker + n.name;
		if(n.isdir)
			view += "/";
		if(nsmode && n.bindsrc != nil) {
			view += "  <- " + n.bindsrc;
			if(n.nunion > 1)
				view += " [+" + string (n.nunion - 1) + "]";
			if(n.bindflags != nil && len n.bindflags > 0)
				view += " " + n.bindflags;
		} else if(!n.isdir && n.length >= big 0) {
			view += "  " + fmtsize(n.length);
		}
		view += "\n";
	}

	writestatefile(FTREE_DIR + "/state", state);
	writestatefile(FTREE_DIR + "/view", view);
}

writestatefile(path, data: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return;
	b := array of byte data;
	sys->write(fd, b, len b);
	fd = nil;
}

checkctlfile(): int
{
	cmd := readrmfile(FTREE_DIR + "/ctl");
	if(cmd == nil || cmd == "")
		return 0;

	(nil, toks) := sys->tokenize(cmd, " \t\n");
	if(toks == nil)
		return 0;

	verb := hd toks;
	toks = tl toks;

	case verb {
	"cd" or "goto" =>
		if(toks == nil)
			return 0;
		gotopath(hd toks);
		return 1;
	"select" =>
		if(toks == nil)
			return 0;
		path := hd toks;
		for(i := 0; i < nvisible; i++) {
			if(nodes[visible[i]].path == path) {
				selected = i;
				scrolltoselected();
				return 1;
			}
		}
	"expand" =>
		if(selected >= 0 && selected < nvisible) {
			ni := visible[selected];
			if(nodes[ni].isdir) {
				expand(ni);
				rebuildvisible();
				return 1;
			}
		}
	"collapse" =>
		if(selected >= 0 && selected < nvisible) {
			ni := visible[selected];
			if(nodes[ni].isdir) {
				collapse(ni);
				rebuildvisible();
				return 1;
			}
		}
	"refresh" =>
		refreshtree();
		return 1;
	"nsmode" =>
		togglensmode();
		return 1;
	"bind" =>
		if(len toks < 2)
			return 0;
		src := hd toks;
		toks = tl toks;
		target := hd toks;
		flagstr := "";
		if(toks != nil) {
			toks = tl toks;
			if(toks != nil)
				flagstr = hd toks;
		}
		# Find or select target
		for(i := 0; i < nvisible; i++) {
			if(nodes[visible[i]].path == target) {
				selected = i;
				break;
			}
		}
		bindsrc_pending = src;
		dobind(src, flagstr);
		return 1;
	"unmount" =>
		if(toks == nil)
			return 0;
		dounmount(hd toks);
		return 1;
	"scroll" =>
		if(toks == nil)
			return 0;
		case hd toks {
		"up" =>
			topline -= vislines;
			clamptop();
		"down" =>
			topline += vislines;
			clamptop();
		"top" =>
			topline = 0;
			selected = 0;
		"bottom" =>
			topline = nvisible - vislines;
			clamptop();
			selected = nvisible - 1;
		}
		return 1;
	}
	return 0;
}

readrmfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	fd = sys->create(path, Sys->OWRITE, 8r666);
	fd = nil;
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[:len s - 1];
	return s;
}

min(a, b: int): int
{
	if(a < b) return a;
	return b;
}
