implement Ftree;

#
# wm/ftree - namespace browser and file tree viewer
#
# Browse the Inferno namespace as an expandable tree with live
# namespace metadata.  Shows bind sources, mount points, union
# directory layers, and permission flags inline.  Supports
# interactive namespace manipulation (bind, unmount).
#
# Tk UI: the flattened visible tree is a listbox (one row per node,
# indented with an expand/collapse marker), a scrollbar, and a status
# strip that doubles as the goto/bind prompt.  All non-UI logic (tree
# model, namespace parse, plumb, IPC) is toolkit-independent.
#
# Usage:
#   wm/ftree [-n] [root]
#   -n  start in namespace mode (annotate mount points)
#
# Keyboard:
#   Up/Down      move selection
#   Left         collapse directory / move to parent
#   Right/Enter  expand directory / open file in presentation view
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
#   Button 2     open selected file in presentation view
#   Button 3     context menu
#   Scroll wheel scroll up/down
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font, Image, Point, Rect: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "readdir.m";
	readdir: Readdir;

include "string.m";
	str: String;

include "lucitheme.m";

include "arg.m";
	arg: Arg;

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

# Tk host
top:		ref Toplevel;
wmctl:		chan of string;
actch:		chan of string;
themech:	chan of int;
display:	ref Display;
stderr:		ref Sys->FD;
listfont:	ref Font;		# for indicator-hit measurement (see onindicator)

# Theme colours (resolved to #rrggbbff strings for Tk)
c_bg:		string;
c_fg:		string;
c_dir:		string;
c_accent:	string;
c_dim:		string;
c_mnt:		string;
c_dev:		string;

# Listbox row font (pixels are derived by Tk)
LISTFONT:	con "/fonts/combined/unicode.sans.14.font";

# Status / prompt state
prompting:	int;		# 1 while the status entry is shown
statusmsg:	string;		# transient right-hand status message

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
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	readdir = load Readdir Readdir->PATH;
	str = load String String->PATH;
	stderr = sys->fildes(2);

	if(tk == nil || tkclient == nil) {
		sys->fprint(stderr, "wm/ftree: cannot load Tk: %r\n");
		raise "fail:init";
	}
	if(readdir == nil) {
		sys->fprint(stderr, "wm/ftree: cannot load Readdir: %r\n");
		raise "fail:init";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();

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

	# Create the Tk toplevel
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(top, wmctl) = tkclient->toplevel(ctxt, "-width 480 -height 560", "ftree", Tkclient->Appl);
	display = top.display;

	loadcolors();

	# Action channel: widgets and bindings post tokens here.
	actch = chan[16] of string;
	tk->namechan(top, actch, "act");

	buildui();

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

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	# Veltro IPC
	initftreedir();
	writeftreestate();
	ticks := chan of int;
	spawn timer(ticks, 500);

	# Namespace change watcher
	nsch := chan[1] of int;
	spawn nswatcher(nsch);

	# Theme listener
	themech = chan[1] of int;
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
	c := <-wmctl or
	c = <-top.ctxt.ctl or
	# top.wreq carries Tk window requests (menu posts create their
	# window through here); a loop that never drains it leaves every
	# posted menu mapped-and-grabbing but windowless — invisible.
	c = <-top.wreq =>
		tkclient->wmctl(top, c);
		if(c != nil && len c > 0 && c[0] == '!')
			redraw();
	key := <-top.ctxt.kbd =>
		if(prompting)
			tk->keyboard(top, key);
		else
			handlekey(key);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	a := <-actch =>
		handleaction(a);
	}
}

# ---------- UI construction ----------

buildui()
{
	cmds := array[] of {
		". configure -background " + c_bg,
		"frame .main",
		"scrollbar .main.sb -command {.main.lb yview}",
		"listbox .main.lb -yscrollcommand {.main.sb set} -selectmode browse" +
			" -font " + LISTFONT +
			" -background " + c_bg +
			" -foreground " + c_fg +
			" -selectbackground " + c_accent +
			" -selectforeground " + c_bg,
		"pack .main.sb -side left -fill y",
		"pack .main.lb -side left -fill both -expand 1",
		"pack .main -side top -fill both -expand 1",
		"label .status -anchor w -background " + c_bg + " -foreground " + c_dim,
		"entry .prompt -background " + c_bg + " -foreground " + c_fg,
		"pack .status -side bottom -fill x",
		"pack propagate . 0",
		# selection / activation / context bindings on the listbox
		"bind .main.lb <ButtonRelease-1> {send act sel %x}",
		"bind .main.lb <Double-Button-1> {send act activate}",
		"bind .main.lb <Button-2> {send act plumb}",
		"bind .main.lb <Button-3> {send act menu %X %Y}",
		# prompt entry posts its contents back to us on Return
		"bind .prompt <Key-\n> {send act promptdone}",
	};
	tkcmds(cmds);
	# Escape cancels the prompt; the ESC rune (0x1b) can't be written as a
	# Limbo string escape, so embed it with sprint.
	tk->cmd(top, sys->sprint("bind .prompt <Key-%c> {send act promptcancel}", 16r1b));
	tk->cmd(top, "update");
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "wm/ftree: tk error %s on %s\n", e, cmds[i]);
	}
}

# ---------- Action dispatch ----------

handleaction(a: string)
{
	(nil, toks) := sys->tokenize(a, " ");
	if(toks == nil)
		return;
	tok := hd toks;
	case tok {
	"sel" =>
		syncselection();
		# A click on the expand/collapse indicator (the leading triangle
		# column) toggles the directory, matching the documented behaviour;
		# clicks on the label just select.  toks = "sel <x>".
		if(tl toks != nil && onindicator(int hd tl toks)) {
			activateselected();
			redraw();
		}
		statusmsg = "";
		writeftreestate();
		updatestatus();
	"activate" =>
		syncselection();
		activateselected();
		redraw();
	"plumb" =>
		syncselection();
		plumbselected();
	"menu" =>
		syncselection();
		buildmenu();
		tk->cmd(top, ".ctx post " + menuxyt(toks));
	"promptdone" =>
		val := tk->cmd(top, ".prompt get");
		endprompt();
		handleprompt(val);
		promptmode = PROMPT_NONE;
		redraw();
	"promptcancel" =>
		endprompt();
		promptmode = PROMPT_NONE;
		redraw();
	* =>
		# context-menu items send their verb directly (mopen, mbind, ...)
		if(len tok > 0 && tok[0] == 'm')
			handlemenu(tok);
	}
}

# Pull the listbox's current selection back into `selected`.
syncselection()
{
	s := tk->cmd(top, ".main.lb curselection");
	if(s != nil && len s > 0 && s[0] >= '0' && s[0] <= '9')
		selected = int s;
}

menuxyt(toks: list of string): string
{
	if(toks != nil && tl toks != nil && tl tl toks != nil){
		x := hd tl toks;
		if(x != "" && x[0] >= '0' && x[0] <= '9')
			return x + " " + hd tl tl toks;
	}
	return "40 40";
}

# ---------- Context menu ----------

# Rebuild the B3 context menu for the current selection.  Items carry an
# explicit action verb (-command {send act <verb>}), so there is no
# positional index to keep in sync.
buildmenu()
{
	tk->cmd(top, "destroy .ctx");
	tk->cmd(top, "menu .ctx");
	if(selected >= 0 && selected < nvisible) {
		nd := nodes[visible[selected]];
		if(nd.isdir) {
			mitem("open", "mopen");
			mitem("bind here...", "mbind");
			if(nd.bindsrc != nil)
				mitem("unmount", "munmount");
			mitem("expand all", "mexpandall");
			mitem("collapse all", "mcollapseall");
		} else {
			mitem("open", "mplumb");
			mitem("bind here...", "mbind");
		}
	}
	mitem("refresh", "mrefresh");
	mitem("ns mode " + nsmodetoggle(), "mnsmode");
	mitem("goto", "mgoto");
	tk->cmd(top, ".ctx add separator");
	mitem("exit", "mexit");
}

mitem(label, verb: string)
{
	tk->cmd(top, sys->sprint(".ctx add command -label {%s} -command {send act %s}", label, verb));
}

nsmodetoggle(): string
{
	if(nsmode)
		return "off";
	return "on";
}

# Context-menu actions arrive on the action channel as bare verbs.
handlemenu(verb: string)
{
	case verb {
	"mopen" =>	activateselected(); redraw();
	"mplumb" =>	plumbselected();
	"mbind" =>	startbind();
	"munmount" =>
		if(selected >= 0 && selected < nvisible)
			dounmount(nodes[visible[selected]].path);
	"mexpandall" =>	expandall();
	"mcollapseall" =>	collapseall();
	"mrefresh" =>	refreshtree();
	"mnsmode" =>	togglensmode();
	"mgoto" =>	startgoto();
	"mexit" =>	exit;
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
			beginprompt("Flags [-b|-a|-bc]:");
		}
	PROMPT_BIND_FLAGS =>
		dobind(bindsrc_pending, val);
		bindsrc_pending = "";
	}
}

# Swap the status label for the prompt entry, label it, and focus it.
beginprompt(label: string)
{
	prompting = 1;
	tk->cmd(top, sys->sprint(".status configure -text {%s}", label));
	tk->cmd(top, ".prompt delete 0 end");
	tk->cmd(top, "pack .prompt -side bottom -fill x");
	tk->cmd(top, "focus .prompt");
	tk->cmd(top, "update");
}

# Hide the prompt entry and return focus to the tree.
endprompt()
{
	prompting = 0;
	tk->cmd(top, "pack forget .prompt");
	tk->cmd(top, "focus .main.lb");
	tk->cmd(top, "update");
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
		openfile(n.path);
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

# ---------- Opening files ----------

UIMOUNT: con "/mnt/ui";

openseq := 0;

plumbselected()
{
	if(selected < 0 || selected >= nvisible)
		return;
	ni := visible[selected];
	n := nodes[ni];
	if(n.isdir)
		activateselected();
	else
		openfile(n.path);
}

# Open a file by presenting it in the Lucifer presentation view.  Media and
# document types (pdf, images, markdown) become content artifacts drawn by
# presrender; everything else opens in the editor, launched as a
# presentation-zone app.  We talk to /mnt/ui directly rather than plumbing:
# the Lucifer session runs no plumber, so a plumb message goes nowhere.
openfile(path: string)
{
	actid := curactid();
	if(actid < 0) {
		setstatus("no presentation activity");
		redraw();
		return;
	}

	name := basename(path);
	ext := str->tolower(fileext(path));

	openseq++;
	id := sys->sprint("ftree-%d", openseq);

	# atype selects the artifact renderer; readcontent=1 means the data
	# field carries the file's contents rather than its path.
	atype := "";
	readcontent := 0;
	case ext {
	"pdf" =>
		atype = "pdf";
	"png" or "jpg" or "jpeg" or "gif" or "bit" or "ppm" =>
		atype = "image";
	"md" or "markdown" =>
		atype = "markdown";
		readcontent = 1;
	* =>
		atype = "app";		# text/source/unknown -> editor
	}

	ctlpath := sys->sprint("%s/activity/%d/presentation/ctl", UIMOUNT, actid);
	if(atype == "app") {
		# The editor launches immediately when the artifact is created,
		# reading its argv from the data field at that instant.  The file
		# path must therefore ride in the create command itself (data= is a
		# terminal attribute, so it goes last); a later data-file write would
		# race the launch and the editor would open empty.
		cmd := sys->sprint("create id=%s type=app label=%s dis=/dis/wm/editor.dis data=%s", id, name, path);
		if(writestr(ctlpath, cmd) < 0) {
			setstatus(sys->sprint("open failed: %r"));
			redraw();
			return;
		}
	} else {
		cmd := sys->sprint("create id=%s type=%s label=%s", id, atype, name);
		if(writestr(ctlpath, cmd) < 0) {
			setstatus(sys->sprint("present failed: %r"));
			redraw();
			return;
		}
		# Content artifacts read their data field when rendered (after
		# center), so a separate data-file write is safe.  It carries the
		# file path (pdf/image) or, for text-rendered types, the contents.
		data := path;
		if(readcontent) {
			c := readfilestr(path);
			if(c != nil)
				data = c;
		}
		datapath := sys->sprint("%s/activity/%d/presentation/%s/data", UIMOUNT, actid, id);
		writestr(datapath, data);
	}

	# Make it the active view; the presentation view opens if not already.
	writestr(ctlpath, "center id=" + id);

	setstatus("opened " + name);
	redraw();
}

# Currently-focused presentation activity id, or -1 if unavailable.
curactid(): int
{
	s := readfilestr(UIMOUNT + "/activity/current");
	if(s == nil)
		return -1;
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' ' || s[len s - 1] == '\t'))
		s = s[0:len s - 1];
	if(s == "")
		return -1;
	(n, nil) := str->toint(s, 10);
	return n;
}

# Write a string to a file (truncating implicitly at offset 0).  Returns -1
# on any failure, 0 on success.
writestr(path, s: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return -1;
	return 0;
}

# Read an entire file into a string, or nil on failure.
readfilestr(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
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
	beginprompt("Bind src (onto " + target + "):");
}

startgoto()
{
	promptmode = PROMPT_GOTO;
	beginprompt("Path:");
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
		setstatus(sys->sprint("bind failed: %r"));
	} else {
		setstatus(sys->sprint("bound %s on %s", src, target));
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
		setstatus("no mount to remove");
		redraw();
		return;
	}
	dounmount(n.path);
}

dounmount(path: string)
{
	rc := sys->unmount(nil, path);
	if(rc < 0) {
		setstatus(sys->sprint("unmount %s: %r", path));
	} else {
		setstatus("unmounted " + path);
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

# True when pixel x (relative to the listbox) falls on the leading
# expand/collapse indicator column of the currently selected directory row.
# The row is `indent (2 spaces/depth) + marker (triangle + space) + name`
# in a proportional font, so measure the indent+marker width with the same
# font.  Non-directories and out-of-range selections never match.
onindicator(x: int): int
{
	if(selected < 0 || selected >= nvisible)
		return 0;
	n := nodes[visible[selected]];
	if(!n.isdir)
		return 0;
	if(listfont == nil && top != nil)
		listfont = Font.open(top.display, LISTFONT);
	if(listfont == nil)
		return 0;
	indent := "";
	for(j := 0; j < n.depth; j++)
		indent += "  ";
	w := listfont.width(indent) + listfont.width(sys->sprint("%c ", 16r25B8));
	# +4px tolerance for the listbox border/inset ahead of the text origin.
	return x <= w + 4;
}

# A tree row rendered as listbox text: depth indent, an expand/collapse
# marker for directories, the name (with a trailing "/" for dirs), and a
# right-padded annotation (namespace source or file size).
rowtext(n: ref Node): string
{
	indent := "";
	for(j := 0; j < n.depth; j++)
		indent += "  ";
	# Filled disclosure triangles (▸ collapsed, ▾ expanded), matching the
	# original tree's drawn arrows — not ASCII '>' / 'V'.  Built via %c so
	# the codepoint is explicit rather than relying on source UTF-8.
	marker := "  ";
	if(n.isdir) {
		if(n.expanded)
			marker = sys->sprint("%c ", 16r25BE);	# ▾
		else
			marker = sys->sprint("%c ", 16r25B8);	# ▸
	}
	name := n.name;
	if(n.isdir)
		name += "/";
	row := indent + marker + name;
	annot := "";
	if(nsmode && n.bindsrc != nil)
		annot = nsannotation(n);
	else if(!n.isdir && n.length >= big 0)
		annot = fmtsize(n.length);
	if(annot != "")
		row += "    " + annot;
	return row;
}

# Recompute vislines (a screenful) from the listbox's pixel height, for
# PgUp/PgDn paging and the IPC state file.
recalcvislines()
{
	ah := int tk->cmd(top, ".main.lb cget -actheight");
	rowpx := 16;		# approximate row height for the 14pt font
	if(ah > 0)
		vislines = ah / rowpx;
	if(vislines < 1)
		vislines = 1;
}

# Rebuild the listbox contents from the visible[] list and reflect the
# current selection and status.  Cheap enough to run on every change.
redraw()
{
	if(top == nil)
		return;
	tk->cmd(top, ".main.lb delete 0 end");
	for(i := 0; i < nvisible; i++)
		tk->cmd(top, sys->sprint(".main.lb insert end {%s}", rowtext(nodes[visible[i]])));
	recalcvislines();
	if(selected >= 0 && selected < nvisible) {
		tk->cmd(top, ".main.lb selection clear 0 end");
		tk->cmd(top, sys->sprint(".main.lb selection set %d", selected));
		tk->cmd(top, sys->sprint(".main.lb see %d", selected));
	}
	updatestatus();
	tk->cmd(top, "update");
}

# Status strip: selected path on the left, item count / bind info / a
# transient message on the right.
updatestatus()
{
	if(prompting)
		return;
	left := rootpath;
	right := sys->sprint("%d items", nvisible);
	if(selected >= 0 && selected < nvisible) {
		nd := nodes[visible[selected]];
		left = nd.path;
		if(nsmode && nd.bindsrc != nil)
			right = nd.bindcmd + " " + nd.bindflags + " " + nd.bindsrc;
	}
	if(statusmsg != "")
		right = statusmsg;
	tk->cmd(top, sys->sprint(".status configure -text {%s    -    %s}", left, right));
}

# Set a transient right-hand status message.
setstatus(s: string)
{
	statusmsg = s;
	updatestatus();
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
		setstatus(path + ": not found");
		return;
	}
	if(!(d.mode & Sys->DMDIR)) {
		openfile(path);
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
	tkclient->settitle(top, "ftree — " + rootpath);
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

col(v: int): string
{
	return sys->sprint("#%06xff", v & 16rFFFFFF);
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil) {
		th := lucitheme->gettheme();
		c_bg = col(th.editbg >> 8);
		c_fg = col(th.edittext >> 8);
		c_dir = col(th.text >> 8);
		c_accent = col(th.accent >> 8);
		c_dim = col(th.dim >> 8);
		c_mnt = col(th.yellow >> 8);
		c_dev = col(th.green >> 8);
	} else {
		# fallback cons are 0xRRGGBBAA; col() wants 0x00RRGGBB
		c_bg = col(BG >> 8);
		c_fg = col(FG >> 8);
		c_dir = col(DIRCOL >> 8);
		c_accent = col(SELCOL >> 8);
		c_dim = col(DIMCOL >> 8);
		c_mnt = col(MNTCOL >> 8);
		c_dev = col(DEVCOL >> 8);
	}
}

# Re-resolve theme colours and re-apply them to the live widgets.
reloadcolors()
{
	loadcolors();
	if(top == nil)
		return;
	tkclient->wmctl(top, "retheme");
	tkcmds(array[] of {
		". configure -background " + c_bg,
		".main.lb configure -background " + c_bg + " -foreground " + c_fg +
			" -selectbackground " + c_accent + " -selectforeground " + c_bg,
		".status configure -background " + c_bg + " -foreground " + c_dim,
		".prompt configure -background " + c_bg + " -foreground " + c_fg,
	});
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
