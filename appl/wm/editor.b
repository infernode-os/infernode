implement Editor;

#
# wm/editor - Tk text editor with 9P interface
#
# A simple text editor with a Styx (9P) filesystem interface for
# programmatic access by Veltro agents and other tools.
#
# The document is the Tk text widget's text, as the transcript is
# wm/sh's: there is no copy of it to keep in step.  Every change, typed,
# pasted or asked for by a client, goes through ins and del, which keep
# the undo log, so whatever changed it, undo takes it back.
#
# The 9P filesystem is mounted at /mnt/edit and bound to /edit.
# The filesystem layout uses per-document directories to support
# future multi-document/split-view without protocol changes:
#
#   /edit/
#     ctl          Global control (open, new, quit)
#     index        List open documents
#     1/           Per-document directory
#       body       Read/write document text
#       ctl        Document control (save, saveas, goto, find, etc.)
#       event      Blocking read for editor events
#       addr       Cursor position (line col)
#
# The document's ctl takes save, saveas <path>, name <path>, goto <line>,
# find <text>, insert <line> <col> <text>, append <text>,
# delete <line> <col> <line> <col>, replace and replaceall <find>\t<repl>,
# clean and dirty; a newline ending a command is not part of it.
#
# open, new and quit are refused while the document has changes not
# saved: save them, or write clean to the document's ctl to let them go.
#
# Keyboard:
#   Type to insert text at cursor
#   Backspace    delete char before cursor
#   Delete       delete char at cursor
#   Enter        insert newline
#   Arrow keys   move cursor
#   Home/End     start/end of line
#   Ctrl-S       save (prompts for path if unnamed)
#   Ctrl-Q       quit (with changes not saved, asks for a second Ctrl-Q)
#   Ctrl-Z       undo last edit
#   Ctrl-Y       redo last undone edit
#   Ctrl-F       find (prompts in status bar)
#   Ctrl-G       find next
#   Ctrl-X       cut selection
#   Ctrl-C       copy selection
#   Ctrl-V       paste
#   Ctrl-A       select all
#   Page Up/Down scroll by screenful
#
# Mouse:
#   Button 1     place cursor / select text
#   Double-click select word
#   Button 2     drag to scroll
#   Button 3     context menu (undo, redo, save, find, replace, ...)
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

include "string.m";
	str: String;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;

include "lucitheme.m";

# Key codes (formerly imported from widget.m)
Khome:	con 16rFF61;
Kend:	con 16rFF57;
Kup:	con 16rFF52;
Kdown:	con 16rFF54;
Kleft:	con 16rFF51;
Kright:	con 16rFF53;
Kpgup:	con 16rFF55;
Kpgdown:	con 16rFF56;
Kdel:	con 16rFF9F;
Kins:	con 16rFF63;
Kbs:	con 8;
Kesc:	con 27;

Editor: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# Colors (fallback defaults; overridden by theme at runtime)
BG:	con int 16rFFFDF6FF;		# warm off-white background
FG:	con int 16r333333FF;		# dark text
CURSORCOL: con int 16r2266CCFF;	# blue cursor
SELCOL:	con int 16rB4D5FEFF;		# light blue selection
LNCOL:	con int 16rBBBBBBFF;		# line number color
DIRTYCOL: con int 16rCC4444FF;		# dirty indicator

# ---------- The document ----------
# The text is the widget's; Doc holds what is not text.  Today there is
# one Doc; the per-document directory scheme (doc.id) supports future
# multi-doc.

Doc: adt {
	id:		int;
	filepath:	string;
	searchstr:	string;
};

# A change, as undo takes it back: text inserted at ix, or deleted from
# it.  ix is the widget's index (line.char) when the change was made;
# undo and redo take changes back in the order they were made, so the
# text is then as it was and ix names the same place.
Ins, Del: con iota;
Change: adt {
	op:	int;
	ix:	string;
	text:	string;
	seq:	int;		# the action it was part of: undo takes back one at a time
};

MAXUNDO: con 20000;	# changes kept; past it the oldest go

undo, redo: list of ref Change;
nundo := 0;
seq := 0;		# the action changes are part of now
savedseq := 0;	# the action on top of undo when the text was saved (-1: none)
lastkind := 0;	# the kind of key last typed, to make a run of typing one action
Ktyping: con 1;	# lastkind for text typed (Kbs and Kdel for their own)

# ---------- QID encoding ----------
# Path = (docid << 8) | filetype
# docid=0 for global files, docid>=1 for per-document files.

QSHIFT: con 8;

# File types within a document directory
Fdir, Fbody, Fctl, Fevent, Faddr: con iota;

# Global file types (docid=0)
Groot: con 0;		# root dir
Ggctl: con 1;		# global ctl
Gindex: con 2;		# index

mkqpath(docid, ftype: int): big
{
	return big ((docid << QSHIFT) | ftype);
}

qiddoc(path: big): int
{
	return (int path) >> QSHIFT;
}

qidfile(path: big): int
{
	return (int path) & 16rFF;
}

# ---------- 9P ↔ Editor communication ----------

Rgetbody, Rsetbody, Raddbody, Rgetaddr, Rsetaddr, Rdoctl, Rgetindex, Rgctl: con iota;

EditReq: adt {
	op:	int;
	docid:	int;
	data:	string;
	reply:	chan of string;
};

editreq: chan of ref EditReq;
eventch: chan of string;

# ---------- Tk host (global) ----------
top: ref Toplevel;
wmctl: chan of string;
actch: chan of string;
display: ref Display;
doc: ref Doc;
stderr: ref Sys->FD;
themech: chan of int;
statedirty: int;	# set when doc changes, cleared after writing state files
vislines: int;		# visible rows in the text widget (for paging)
prompting: int;		# 1 while the status entry is shown
statusmsg: string;	# shown in the status bar until the next key
exitasked: int;	# an exit was refused for changes not saved: the next one goes
shown: string;		# the title last set

# Theme colours, resolved to #rrggbbff strings for Tk
c_bg:	string;
c_fg:	string;
c_sel:	string;
c_dim:	string;
c_cursor: string;

EDFONT: con "/fonts/combined/unicode.14.font";

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	str = load String String->PATH;
	stderr = sys->fildes(2);

	if(tk == nil || tkclient == nil) {
		sys->fprint(stderr, "edit: cannot load Tk: %r\n");
		raise "fail:cannot load Tk";
	}
	if(str == nil) {
		sys->fprint(stderr, "edit: cannot load String: %r\n");
		raise "fail:cannot load String";
	}

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();

	doc = ref Doc(1, "", "");

	# Parse args
	argv = tl argv;
	if(argv != nil)
		doc.filepath = hd argv;

	# Start 9P server before creating window (so it's available immediately)
	editreq = chan of ref EditReq;
	# events wait here for a reader, not only for one already waiting
	eventch = chan[32] of string;
	spawn startfsys();

	# Create the Tk toplevel
	sys->sleep(100);
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	(top, wmctl) = tkclient->toplevel(ctxt, "-width 640 -height 480", titlestr(), Tkclient->Appl);
	display = top.display;

	loadcolors();

	# Action channel for menu / prompt tokens
	actch = chan[16] of string;
	tk->namechan(top, actch, "act");

	buildui();

	# Load file if specified; one that is not there yet is a new file
	# of that name
	if(doc.filepath != ""){
		e := loadfile(doc.filepath);
		if(e != nil){
			(ok, nil) := sys->stat(doc.filepath);
			if(ok < 0)
				statusmsg = "new file";
			else {
				statusmsg = e;
				doc.filepath = "";
			}
		}
	}

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	refresh(1);

	# Write initial state so Veltro tool can read immediately after launch.
	# Without this, body/addr/index files don't exist until the first user
	# edit or ctl command, causing "editor read" to fail with "is edit running?".
	statedirty = 1;
	writeeditstate();

	# Periodic state writer / ctl-file poll
	ticks := chan of int;
	spawn timer(ticks, 500);

	# Listen for live theme changes
	themech = chan[1] of int;
	spawn themelistener();

	for(;;) alt {
	c := <-wmctl or
	c = <-top.ctxt.ctl or
	# top.wreq carries Tk window requests (menu posts create their
	# window through here); a loop that never drains it leaves every
	# posted menu mapped-and-grabbing but windowless — invisible.
	c = <-top.wreq =>
		# the frame's close and the window manager's Delete: changes
		# not saved are kept, the first time
		if(c == "exit"){
			doexit();
			refresh(0);
			break;
		}
		tkclient->wmctl(top, c);
		if(c != nil && len c > 0 && c[0] == '!')
			refresh(1);
	key := <-top.ctxt.kbd =>
		# keys go to the prompt or to handlekey, never to the text
		# widget: its own bindings would change the text unlogged
		if(prompting){
			if(tk->cmd(top, "focus") != ".prompt")
				tk->cmd(top, "focus .prompt");
			tk->keyboard(top, key);
		} else {
			statusmsg = "";
			if(key != 17)
				exitasked = 0;
			handlekey(key);
			statedirty = 1;
			refresh(1);
		}
	p := <-top.ctxt.ptr =>
		# Tk owns mouse positioning / selection natively
		if(p.buttons != 0)
			lastkind = 0;
		tk->pointer(top, *p);
		# a click in the text ends a prompt: typing is the text's again
		if(prompting && tk->cmd(top, "focus") == ".main.t"){
			endprompt();
			promptkind = PNONE;
		}
		refresh(0);
	a := <-actch =>
		handleaction(a);
		statedirty = 1;
		refresh(1);
	<-ticks =>
		if(checkctlfile()) {
			statedirty = 1;
			refresh(1);
		}
		writeeditstate();
	req := <-editreq =>
		handleeditreq(req);
		statedirty = 1;
		refresh(1);
	<-themech =>
		reloadcolors();
		refresh(0);
	}
}

# ---------- UI construction ----------

buildui()
{
	cmds := array[] of {
		". configure -background " + c_bg,
		"frame .main",
		"scrollbar .main.sb -command {.main.t yview}",
		"text .main.t -wrap none -yscrollcommand {.main.sb set}" +
			" -font " + EDFONT +
			" -background " + c_bg +
			" -foreground " + c_fg +
			" -selectbackground " + c_sel +
			" -selectforeground " + c_bg,
		"pack .main.sb -side left -fill y",
		"pack .main.t -side left -fill both -expand 1",
		"pack .main -side top -fill both -expand 1",
		"label .status -anchor w -background " + c_bg + " -foreground " + c_dim,
		"entry .prompt -background " + c_bg + " -foreground " + c_fg,
		"pack .status -side bottom -fill x",
		"pack propagate . 0",
		# B3 context menu on the text body
		"bind .main.t <Button-3> {send act menu %X %Y}",
		"bind .prompt <Key-\n> {send act promptdone}",
	};
	tkcmds(cmds);
	tk->cmd(top, sys->sprint("bind .prompt <Key-%c> {send act promptcancel}", 16r1b));
	tk->cmd(top, "focus .main.t");
	tk->cmd(top, "update");
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "edit: tk error %s on %s\n", e, cmds[i]);
	}
}

# a command to the text widget
t(c: string): string
{
	return tk->cmd(top, ".main.t " + c);
}

# ---------- Action dispatch (menu items + prompt completion) ----------

handleaction(a: string)
{
	(nil, toks) := sys->tokenize(a, " ");
	if(toks == nil)
		return;
	tok := hd toks;
	lastkind = 0;
	if(tok != "menu" && tok != "exit")
		exitasked = 0;
	case tok {
	"menu" =>
		buildmenu();
		tk->cmd(top, ".ctx post " + menuxyt(toks));
	"promptdone" =>
		val := tk->cmd(top, ".prompt get");
		endprompt();
		finishprompt(val);
	"promptcancel" =>
		endprompt();
		promptkind = PNONE;
	"undo" =>	doundo();
	"redo" =>	doredo();
	"save" =>	dosave();
	"saveas" =>	startsaveas();
	"find" =>	startfind();
	"replace" =>	startreplace();
	"goto" =>	startgoto();
	"selall" =>	selectall();
	"cut" =>	docut();
	"copy" =>	docopy();
	"paste" =>	dopaste();
	"exit" =>	doexit();
	}
}

buildmenu()
{
	tk->cmd(top, "destroy .ctx");
	tk->cmd(top, "menu .ctx");
	mitem("undo", "undo");
	mitem("redo", "redo");
	tk->cmd(top, ".ctx add separator");
	mitem("cut", "cut");
	mitem("copy", "copy");
	mitem("paste", "paste");
	mitem("select all", "selall");
	tk->cmd(top, ".ctx add separator");
	mitem("find", "find");
	mitem("replace", "replace");
	mitem("goto line", "goto");
	tk->cmd(top, ".ctx add separator");
	mitem("save", "save");
	mitem("save as", "saveas");
	mitem("exit", "exit");
}

mitem(label, verb: string)
{
	tk->cmd(top, sys->sprint(".ctx add command -label {%s} -command {send act %s}", label, verb));
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

# Exit, unless there are changes not saved: then say so, and go at
# the next exit asked for.
doexit()
{
	if(isdirty() && !exitasked){
		exitasked = 1;
		lastkind = 0;
		statusmsg = "changes not saved: exit again to discard them";
		return;
	}
	postevent("quit");
	postnote(1, sys->pctl(0, nil), "kill");
	exit;
}

# ---------- The view of the document ----------

# After an event: the cursor in view if see, the status bar and the
# title made current.
refresh(see: int)
{
	if(top == nil)
		return;
	if(see)
		t("see insert");
	recalcvis();
	updatestatus();
	s := titlestr();
	if(s != shown){
		shown = s;
		tkclient->settitle(top, s);
	}
	tk->cmd(top, "update");
}

# "L.C" -> (L-1, C); (-1, 0) if unparseable.
parseindex(s: string): (int, int)
{
	if(s == nil || len s == 0 || s[0] < '0' || s[0] > '9')
		return (-1, 0);
	(ls, cs) := splitdot(s);
	(l, nil) := str->toint(ls, 10);
	(c, nil) := str->toint(cs, 10);
	return (l - 1, c);
}

splitdot(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '.')
			return (s[:i], s[i+1:]);
	return (s, "0");
}

recalcvis()
{
	ah := int tk->cmd(top, ".main.t cget -actheight");
	rowpx := 16;
	if(ah > 0)
		vislines = ah / rowpx;
	if(vislines < 1)
		vislines = 1;
}

updatestatus()
{
	if(prompting || top == nil)
		return;
	name := doc.filepath;
	if(name == "")
		name = "(new)";
	dq := "";
	if(isdirty())
		dq = " *";
	(l, c) := parseindex(t("index insert"));
	s := sys->sprint("%s%s    -    Ln %d, Col %d", name, dq, l+1, c+1);
	if(statusmsg != "")
		s += "    -    " + statusmsg;
	tk->cmd(top, ".status configure -text " + tk->quote(s));
}

# ---------- Status-bar prompt (find / goto / replace / save-as) ----------

PNONE, PFIND, PGOTO, PREPLACEFIND, PREPLACEWITH, PSAVEAS: con iota;
promptkind := PNONE;
preplacefind := "";

beginprompt(kind: int, label: string)
{
	promptkind = kind;
	prompting = 1;
	tk->cmd(top, ".status configure -text " + tk->quote(label));
	tk->cmd(top, ".prompt delete 0 end");
	tk->cmd(top, "pack .prompt -side bottom -fill x");
	tk->cmd(top, "focus .prompt");
	tk->cmd(top, "update");
}

endprompt()
{
	prompting = 0;
	tk->cmd(top, "pack forget .prompt");
	tk->cmd(top, "focus .main.t");
	tk->cmd(top, "update");
}

finishprompt(val: string)
{
	case promptkind {
	PFIND =>
		if(val != ""){
			doc.searchstr = val;
			findnext();
		}
	PGOTO =>
		if(val != ""){
			(ln, nil) := str->toint(val, 10);
			if(ln > 0)
				gotoline(ln);
		}
	PREPLACEFIND =>
		preplacefind = val;
		beginprompt(PREPLACEWITH, "Replace with:");
		return;		# chained — keep prompting
	PREPLACEWITH =>
		doreplace(preplacefind, val);
	PSAVEAS =>
		if(val != "")
			dosaveas(val);
	}
	promptkind = PNONE;
}

# ---------- Colour management ----------

col(v: int): string
{
	return sys->sprint("#%06xff", v & 16rFFFFFF);
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil){
		th := lucitheme->gettheme();
		c_bg = col(th.editbg >> 8);
		c_fg = col(th.edittext >> 8);
		c_sel = col(th.accent >> 8);
		c_dim = col(th.editlineno >> 8);
		c_cursor = col(th.editcursor >> 8);
	} else {
		c_bg = col(BG >> 8);
		c_fg = col(FG >> 8);
		c_sel = col(SELCOL >> 8);
		c_dim = col(LNCOL >> 8);
		c_cursor = col(CURSORCOL >> 8);
	}
}

# ---------- Handle 9P requests on the main thread ----------

handleeditreq(req: ref EditReq)
{
	lastkind = 0;
	case req.op {
	Rgetbody =>
		req.reply <-= getbodytext();
	Rsetbody =>
		newaction();
		setbodytext(req.data);
		postevent("modified");
		req.reply <-= "ok";
	Raddbody =>
		# the rest of a body longer than one 9P message: part of
		# the same action as the write that began it
		ins("end", req.data);
		req.reply <-= "ok";
	Rgetaddr =>
		(l, c) := parseindex(t("index insert"));
		req.reply <-= sys->sprint("%d %d", l + 1, c + 1);
	Rsetaddr =>
		(line, rest) := splitfirst(req.data);
		(col, nil) := splitfirst(rest);
		(ln, nil) := str->toint(line, 10);
		(cn, nil) := str->toint(col, 10);
		(l, c) := parseindex(t("index insert"));
		if(ln > 0)
			l = ln - 1;
		if(cn > 0)
			c = cn - 1;
		setcursor(sys->sprint("%d.%d", l + 1, c));
		req.reply <-= "ok";
	Rdoctl =>
		req.reply <-= handledocctl(req.data);
	Rgetindex =>
		req.reply <-= indexline();
	Rgctl =>
		req.reply <-= handlegctl(req.data);
	}
}

indexline(): string
{
	return sys->sprint("%d %s %d\n", doc.id, doc.filepath, isdirty());
}

getbodytext(): string
{
	return t("get 1.0 end");
}

# Replace the whole text, as one change undo takes back.
setbodytext(text: string)
{
	del("1.0", "end");
	ins("1.0", text);
	setcursor("1.0");
}

# A ctl command is a line: the newline echo ends it with is not part of
# what it says (a text inserted keeps any newline of its own before it).
chomp(s: string): string
{
	if(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

handledocctl(cmd: string): string
{
	cmd = chomp(cmd);
	(op, rest) := splitfirst(cmd);
	op = str->tolower(op);
	lastkind = 0;
	case op {
	"save" =>
		if(doc.filepath == "")
			return "error: no file name: use saveas";
		return savefile(doc.filepath);
	"goto" =>
		(lns, nil) := str->toint(rest, 10);
		if(lns > 0)
			gotoline(lns);
		return "ok";
	"find" =>
		if(rest != "") {
			doc.searchstr = rest;
			findnext();
		}
		return "ok";
	"saveas" =>
		if(rest == "")
			return "error: usage: saveas <path>";
		return dosaveas(rest);
	"name" =>
		if(rest != "")
			doc.filepath = rest;
		return "ok";
	"clean" =>
		savedseq = topseq();
		exitasked = 0;
		return "ok";
	"dirty" =>
		savedseq = -1;
		return "ok";
	"insert" =>
		# insert <line> <col> <text>
		(ls, r2) := splitfirst(rest);
		(cs, text) := splitfirst(r2);
		(ln, nil) := str->toint(ls, 10);
		(cn, nil) := str->toint(cs, 10);
		if(ln > 0 && cn > 0) {
			newaction();
			setcursor(ins(sys->sprint("%d.%d", ln, cn - 1), text));
			postevent("modified");
		}
		return "ok";
	"append" =>
		# append <text>: at the end of the text as it is now
		newaction();
		setcursor(ins("end", rest));
		postevent("modified");
		return "ok";
	"delete" =>
		# delete <startline> <startcol> <endline> <endcol>
		(sls, r2) := splitfirst(rest);
		(scs, r3) := splitfirst(r2);
		(els, r4) := splitfirst(r3);
		(ecs, nil) := splitfirst(r4);
		(sl, nil) := str->toint(sls, 10);
		(sc, nil) := str->toint(scs, 10);
		(el, nil) := str->toint(els, 10);
		(ec, nil) := str->toint(ecs, 10);
		if(sl > 0 && sc > 0 && el > 0 && ec > 0) {
			newaction();
			a := sys->sprint("%d.%d", sl, sc - 1);
			del(a, sys->sprint("%d.%d", el, ec - 1));
			setcursor(earlier(a, sys->sprint("%d.%d", el, ec - 1)));
			postevent("modified");
		}
		return "ok";
	"replace" =>
		# replace <find> \t <repl>
		# The find and replacement strings are separated by a tab character
		(f, rp) := splittab(rest);
		if(f != "") {
			doreplace(f, rp);
			postevent("modified");
		}
		return "ok";
	"replaceall" =>
		# replaceall <find> \t <repl>
		(f, rp) := splittab(rest);
		if(f != "") {
			n := doreplaceall(f, rp);
			postevent("modified");
			return sys->sprint("ok %d", n);
		}
		return "ok 0";
	* =>
		return "error: unknown ctl command: " + op;
	}
}

UNSAVED: con "error: changes not saved: save them, or write clean to let them go";

handlegctl(cmd: string): string
{
	cmd = chomp(cmd);
	(op, rest) := splitfirst(cmd);
	op = str->tolower(op);
	lastkind = 0;
	case op {
	"open" =>
		if(rest == "")
			return "error: usage: open <path>";
		if(isdirty())
			return UNSAVED;
		e := loadfile(rest);
		if(e != nil){
			(ok, nil) := sys->stat(rest);
			if(ok >= 0)
				return "error: " + e;
			# not there yet: a new file of that name
			newdoc();
		}
		doc.filepath = rest;
		postevent("opened " + doc.filepath);
		return "ok";
	"new" =>
		if(isdirty())
			return UNSAVED;
		newdoc();
		doc.filepath = "";
		postevent("new");
		return "ok";
	"quit" =>
		if(isdirty())
			return UNSAVED;
		postevent("quit");
		postnote(1, sys->pctl(0, nil), "kill");
		exit;
	* =>
		return "error: unknown global ctl: " + op;
	}
}

postevent(msg: string)
{
	# Non-blocking send — if 32 wait unread, drop it
	alt {
	eventch <-= msg =>
		;
	* =>
		;
	}
}

# ---------- 9P File Server ----------

# --- Real-file IPC for Veltro tool access ---
# /tmp/veltro/editor/ is visible to the editor tool through an explicit path
# capability, not as ambient /tmp/veltro state.
# Named "editor" (not "edit") to match the tool name and avoid confusion with the "edit" tool.
EDIT_DIR:  con "/tmp/veltro/editor";
EDIT_INST: con "/tmp/veltro/editor/1";

MNTPT: con "/mnt/edit";
BINDPT: con "/edit";
user: string;

startfsys()
{
	# Initialise real-file state directories first
	initeditdir();
	styx = load Styx Styx->PATH;
	if(styx == nil) {
		sys->fprint(stderr, "edit: can't load Styx: %r\n");
		return;
	}
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) {
		sys->fprint(stderr, "edit: can't load Styxservers: %r\n");
		return;
	}
	styxservers->init(styx);

	user = readf("/dev/user");
	if(user == nil)
		user = "inferno";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "edit: pipe: %r\n");
		return;
	}

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big 0);
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc, navops);
	<-pidc;

	# Ensure mount and bind targets exist
	mkdirq("/mnt");
	mkdirq(MNTPT);
	mkdirq(BINDPT);
	# Mount and bind
	if(sys->mount(fds[1], nil, MNTPT, Sys->MREPL|Sys->MCREATE, nil) < 0)
		sys->fprint(stderr, "edit: mount %s: %r\n", MNTPT);
	else if(sys->bind(MNTPT, BINDPT, Sys->MREPL|Sys->MCREATE) < 0)
		sys->fprint(stderr, "edit: bind %s %s: %r\n", MNTPT, BINDPT);
	else
		sys->fprint(stderr, "edit: 9P ready at %s\n", BINDPT);
}

# Static directory tables for the navigator

PERM_DIR: con 8r755 | Sys->DMDIR;
PERM_RW: con 8r666;
PERM_RO: con 8r444;

# File info for stat/walk
FileInfo: adt {
	name:	string;
	qpath:	big;
	qtype:	int;
	perm:	int;
};

# Root directory entries
# qpath values: mkqpath(docid, ftype) = big ((docid << QSHIFT) | ftype)
# mkqpath(0, Ggctl)=big 1, mkqpath(0, Gindex)=big 2, mkqpath(1, Fdir)=big 256
rootfiles := array[] of {
	FileInfo("ctl",   big 1,   Sys->QTFILE, PERM_RW),
	FileInfo("index", big 2,   Sys->QTFILE, PERM_RO),
	FileInfo("1",     big 256, Sys->QTDIR,  PERM_DIR),
};

# Per-document directory entries
docfiles := array[] of {
	FileInfo("body",  big 0, Sys->QTFILE, PERM_RW),    # qpath filled in per-doc
	FileInfo("ctl",   big 0, Sys->QTFILE, PERM_RW),
	FileInfo("event", big 0, Sys->QTFILE, PERM_RO),
	FileInfo("addr",  big 0, Sys->QTFILE, PERM_RW),
};

mkfilestat(fi: FileInfo, qpath: big): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.name = fi.name;
	d.uid = user;
	d.gid = user;
	d.qid.path = qpath;
	d.qid.vers = 0;
	d.qid.qtype = fi.qtype;
	d.mode = fi.perm;
	return d;
}

mkdirstat(name: string, qpath: big): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = qpath;
	d.qid.vers = 0;
	d.qid.qtype = Sys->QTDIR;
	d.mode = PERM_DIR;
	return d;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dostat(n.path);

		Walk =>
			did := qiddoc(n.path);
			fid := qidfile(n.path);

			if(n.name == "..") {
				if(did > 0)
					n.reply <-= (mkdirstat(".", big Groot), nil);
				else
					n.reply <-= (mkdirstat(".", big Groot), nil);
				continue;
			}

			# Walking from root dir
			if(did == 0 && fid == Groot) {
				found := 0;
				for(i := 0; i < len rootfiles; i++) {
					if(rootfiles[i].name == n.name) {
						n.reply <-= (mkfilestat(rootfiles[i], rootfiles[i].qpath), nil);
						found = 1;
						break;
					}
				}
				if(!found)
					n.reply <-= (nil, Styxservers->Enotfound);
				continue;
			}

			# Walking from a doc dir
			if(did > 0 && fid == Fdir) {
				found := 0;
				for(i := 0; i < len docfiles; i++) {
					if(docfiles[i].name == n.name) {
						# Compute actual qpath for this doc
						ft: int;
						case n.name {
						"body"  => ft = Fbody;
						"ctl"   => ft = Fctl;
						"event" => ft = Fevent;
						"addr"  => ft = Faddr;
						* => ft = 0;
						}
						qp := mkqpath(did, ft);
						fi := FileInfo(n.name, qp, docfiles[i].qtype, docfiles[i].perm);
						n.reply <-= (mkfilestat(fi, qp), nil);
						found = 1;
						break;
					}
				}
				if(!found)
					n.reply <-= (nil, Styxservers->Enotfound);
				continue;
			}

			n.reply <-= (nil, Styxservers->Enotfound);

		Readdir =>
			did := qiddoc(m.path);
			fid := qidfile(m.path);

			if(did == 0 && fid == Groot) {
				# Root directory
				i := n.offset;
				count := n.count;
				for(j := i; j < len rootfiles && count > 0; j++) {
					n.reply <-= (mkfilestat(rootfiles[j], rootfiles[j].qpath), nil);
					count--;
				}
				n.reply <-= (nil, nil);
				continue;
			}

			if(did > 0 && fid == Fdir) {
				# Doc directory
				i := n.offset;
				count := n.count;
				for(j := i; j < len docfiles && count > 0; j++) {
					ft: int;
					case docfiles[j].name {
					"body"  => ft = Fbody;
					"ctl"   => ft = Fctl;
					"event" => ft = Fevent;
					"addr"  => ft = Faddr;
					* => ft = 0;
					}
					qp := mkqpath(did, ft);
					fi := FileInfo(docfiles[j].name, qp, docfiles[j].qtype, docfiles[j].perm);
					n.reply <-= (mkfilestat(fi, qp), nil);
					count--;
				}
				n.reply <-= (nil, nil);
				continue;
			}

			n.reply <-= (nil, "not a directory");
		}
	}
}

dostat(path: big): (ref Sys->Dir, string)
{
	did := qiddoc(path);
	fid := qidfile(path);

	# Root
	if(did == 0 && fid == Groot)
		return (mkdirstat(".", big Groot), nil);

	# Global files
	if(did == 0) {
		for(i := 0; i < len rootfiles; i++)
			if(rootfiles[i].qpath == path)
				return (mkfilestat(rootfiles[i], path), nil);
		return (nil, Styxservers->Enotfound);
	}

	# Doc directory
	if(fid == Fdir)
		return (mkdirstat(string did, mkqpath(did, Fdir)), nil);

	# Doc files
	for(i := 0; i < len docfiles; i++) {
		ft: int;
		case docfiles[i].name {
		"body"  => ft = Fbody;
		"ctl"   => ft = Fctl;
		"event" => ft = Fevent;
		"addr"  => ft = Faddr;
		* => ft = 0;
		}
		if(fid == ft) {
			qp := mkqpath(did, ft);
			fi := FileInfo(docfiles[i].name, qp, docfiles[i].qtype, docfiles[i].perm);
			return (mkfilestat(fi, qp), nil);
		}
	}

	return (nil, Styxservers->Enotfound);
}

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver,
	pidc: chan of int, navops: chan of ref Navop)
{
	pidc <-= sys->pctl(Sys->FORKNS|Sys->NEWFD, 1 :: 2 :: srv.fd.fd :: nil);

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
				srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadarg));
				break;
			}
			qid := Sys->Qid(c.path, 0, c.qtype);
			c.open(mode, qid);
			c.data = nil;
			srv.reply(ref Rmsg.Open(m.tag, qid, srv.iounit()));

		Read =>
			(c, rerr) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, rerr));
				break;
			}
			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}
			handlefsread(srv, m, c);

		Write =>
			(c, werr) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, werr));
				break;
			}
			handlefswrite(srv, m, c);

		Clunk =>
			srv.clunk(m);

		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

ask(op, did: int, data: string): string
{
	reply := chan of string;
	editreq <-= ref EditReq(op, did, data, reply);
	return <-reply;
}

handlefsread(srv: ref Styxserver, m: ref Tmsg.Read, c: ref Fid)
{
	did := qiddoc(c.path);
	fid := qidfile(c.path);

	# Global files
	if(did == 0) {
		case fid {
		Ggctl =>
			srv.reply(styxservers->readstr(m, "edit\n"));
			return;
		Gindex =>
			srv.reply(styxservers->readstr(m, ask(Rgetindex, 0, "")));
			return;
		}
		srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
		return;
	}

	# Per-doc files
	case fid {
	Fbody =>
		# the text as it was at the first read, for the reads after
		# it: a body longer than one read is read whole, as one text
		if(m.offset == big 0 || c.data == nil)
			c.data = array of byte ask(Rgetbody, did, "");
		srv.reply(styxservers->readbytes(m, c.data));
	Fctl =>
		srv.reply(styxservers->readstr(m, ""));
	Fevent =>
		# wait for an event in a proc of its own: the other files
		# are served meanwhile
		spawn eventread(srv, m);
	Faddr =>
		srv.reply(styxservers->readstr(m, ask(Rgetaddr, did, "") + "\n"));
	* =>
		srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
	}
}

# Answer a read of event with the next event, or an empty line after
# five seconds of none.
eventread(srv: ref Styxserver, m: ref Tmsg.Read)
{
	ev := "";
	timeout := chan of int;
	spawn evtimeout(timeout, 5000);
	alt {
	ev = <-eventch =>
		;
	<-timeout =>
		ev = "";
	}
	srv.reply(styxservers->readstr(m, ev + "\n"));
}

handlefswrite(srv: ref Styxserver, m: ref Tmsg.Write, c: ref Fid)
{
	did := qiddoc(c.path);
	fid := qidfile(c.path);
	data := string m.data;

	# Global ctl
	if(did == 0 && fid == Ggctl) {
		result := ask(Rgctl, 0, data);
		if(len result >= 6 && result[0:6] == "error:")
			srv.reply(ref Rmsg.Error(m.tag, result));
		else
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
		return;
	}

	if(did == 0) {
		srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
		return;
	}

	# Per-doc files
	case fid {
	Fbody =>
		# A write at 0 replaces the text; the writes after it, a
		# body too long for one message, add the rest to it.  A
		# character split between two writes waits for its end.
		op := Raddbody;
		b := m.data;
		if(m.offset == big 0)
			op = Rsetbody;
		else if(c.data != nil){
			nb := array[len c.data + len b] of byte;
			nb[0:] = c.data;
			nb[len c.data:] = b;
			b = nb;
		}
		n := sys->utfbytes(b, len b);
		c.data = b[n:];
		ask(op, did, string b[0:n]);
		srv.reply(ref Rmsg.Write(m.tag, len m.data));
	Fctl =>
		result := ask(Rdoctl, did, data);
		if(len result >= 6 && result[0:6] == "error:")
			srv.reply(ref Rmsg.Error(m.tag, result));
		else
			srv.reply(ref Rmsg.Write(m.tag, len m.data));
	Faddr =>
		ask(Rsetaddr, did, data);
		srv.reply(ref Rmsg.Write(m.tag, len m.data));
	* =>
		srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
	}
}

# ---------- Title ----------

titlestr(): string
{
	s := "Edit";
	if(doc.filepath != "")
		s += " " + doc.filepath;
	else
		s += " (new)";
	if(isdirty())
		s += " *";
	return s;
}

# ---------- Keyboard handling ----------

handlekey(key: int)
{
	ctrl := 0;
	if(key >= 1 && key <= 26 && key != Kbs && key != '\n' && key != '\t')
		ctrl = 1;

	if(ctrl) {
		lastkind = 0;
		case key {
		1 =>	# Ctrl-A: select all
			selectall();
		3 =>	# Ctrl-C: copy
			docopy();
		6 =>	# Ctrl-F: find
			startfind();
		7 =>	# Ctrl-G: find next
			findnext();
		17 =>	# Ctrl-Q: quit
			doexit();
		19 =>	# Ctrl-S: save
			dosave();
		22 =>	# Ctrl-V: paste
			dopaste();
		24 =>	# Ctrl-X: cut
			docut();
		25 =>	# Ctrl-Y: redo
			doredo();
		26 =>	# Ctrl-Z: undo
			doundo();
		}
		return;
	}

	case key {
	Kbs or Kdel =>
		# a run of them is one action; a selection goes by itself
		if(lastkind != key || hassel())
			newaction();
		if(delsel())
			lastkind = 0;
		else {
			if(key == Kbs)
				del("insert-1c", "insert");
			else
				del("insert", "insert+1c");
			lastkind = key;
		}
	Kup =>
		move("insert-1l");
	Kdown =>
		move("insert+1l");
	Kleft =>
		move("insert-1c");
	Kright =>
		move("insert+1c");
	Khome =>
		move("insert linestart");
	Kend =>
		move("insert lineend");
	Kpgup =>
		move("insert-" + string vislines + "l");
	Kpgdown =>
		move("insert+" + string vislines + "l");
	Kesc =>
		t("tag remove sel 1.0 end");
		lastkind = 0;
	* =>
		if(key >= 16r20 || key == '\t' || key == '\n') {
			# a run of typing is one action, to the end of its line
			if(lastkind != Ktyping || hassel())
				newaction();
			delsel();
			s := "";
			s[0] = key;
			t("mark set insert " + ins("insert", s));
			lastkind = Ktyping;
			if(key == '\n')
				lastkind = 0;
		}
	}
}

move(ix: string)
{
	t("mark set insert {" + ix + "}");
	t("tag remove sel 1.0 end");
	lastkind = 0;
}

setcursor(ix: string)
{
	t("mark set insert {" + ix + "}");
	t("tag remove sel 1.0 end");
}

gotoline(ln: int)
{
	setcursor(sys->sprint("%d.0", ln));
}

startgoto()
{
	beginprompt(PGOTO, "Go to line:");
}

startsaveas()
{
	beginprompt(PSAVEAS, "Save as:");
}

# Save under a new name; the name stays the old one if it cannot be.
dosaveas(path: string): string
{
	r := savefile(path);
	if(r == "ok")
		doc.filepath = path;
	return r;
}

# ---------- Changes and undo ----------

# The next change begins a new action.
newaction()
{
	seq++;
}

topseq(): int
{
	if(undo == nil)
		return 0;
	return (hd undo).seq;
}

isdirty(): int
{
	return topseq() != savedseq;
}

push(c: ref Change)
{
	undo = c :: undo;
	if(++nundo > MAXUNDO){
		# keep the newest three quarters
		keep: list of ref Change;
		n := 0;
		for(l := undo; l != nil && n < MAXUNDO*3/4; l = tl l){
			keep = hd l :: keep;
			n++;
		}
		undo = nil;
		for(; keep != nil; keep = tl keep)
			undo = hd keep :: undo;
		nundo = n;
	}
	redo = nil;
}

rawins(ix, s: string)
{
	t("insert " + ix + " " + tk->quote(s));
}

rawdel(ix0, ix1: string)
{
	t("delete " + ix0 + " " + ix1);
}

after(ix: string, n: int): string
{
	return t("index {" + ix + "+" + string n + "c}");
}

earlier(a, b: string): string
{
	if(t("compare " + a + " > " + b) == "1")
		return b;
	return a;
}

# Insert s at ix, logged; where it ends.  (The widget's insert mark is
# not always moved past text put where it is: the caller moves it.)
ins(ix, s: string): string
{
	if(s == "")
		return t("index {" + ix + "}");
	ix = t("index {" + ix + "}");
	if(seq == 0)
		newaction();
	# typing goes on the change it continues
	c: ref Change;
	if(undo != nil)
		c = hd undo;
	if(c != nil && c.seq == seq && c.op == Ins && after(c.ix, len c.text) == ix)
		c.text += s;
	else
		push(ref Change(Ins, ix, s, seq));
	rawins(ix, s);
	redo = nil;
	return after(ix, len s);
}

# Delete from a to b, logged.
del(a, b: string)
{
	a = t("index {" + a + "}");
	b = t("index {" + b + "}");
	if(t("compare " + a + " > " + b) == "1")
		(a, b) = (b, a);
	s := t("get " + a + " " + b);
	if(s == "")
		return;
	if(seq == 0)
		newaction();
	# a run of backspaces, or of deletes, is one change
	c: ref Change;
	if(undo != nil && (hd undo).seq == seq && (hd undo).op == Del)
		c = hd undo;
	if(c != nil && c.ix == b){
		c.ix = a;
		c.text = s + c.text;
	} else if(c != nil && c.ix == a)
		c.text += s;
	else
		push(ref Change(Del, a, s, seq));
	rawdel(a, b);
	redo = nil;
}

# Take back the last action.
doundo()
{
	if(undo == nil)
		return;
	s := (hd undo).seq;
	at := "";
	while(undo != nil && (hd undo).seq == s){
		c := hd undo;
		undo = tl undo;
		nundo--;
		case c.op {
		Ins =>
			rawdel(c.ix, after(c.ix, len c.text));
			at = c.ix;
		Del =>
			rawins(c.ix, c.text);
			at = after(c.ix, len c.text);
		}
		redo = c :: redo;
	}
	setcursor(at);
	lastkind = 0;
	postevent("modified");
}

# Make again the last action undone.
doredo()
{
	if(redo == nil)
		return;
	s := (hd redo).seq;
	at := "";
	while(redo != nil && (hd redo).seq == s){
		c := hd redo;
		redo = tl redo;
		case c.op {
		Ins =>
			rawins(c.ix, c.text);
			at = after(c.ix, len c.text);
		Del =>
			rawdel(c.ix, after(c.ix, len c.text));
			at = c.ix;
		}
		undo = c :: undo;
		nundo++;
	}
	setcursor(at);
	lastkind = 0;
	postevent("modified");
}

# A new text: no undo, nothing to save.
newdoc()
{
	rawdel("1.0", "end");
	undo = redo = nil;
	nundo = 0;
	savedseq = 0;
	exitasked = 0;
	setcursor("1.0");
}

# ---------- Selection ----------

selrange(): (string, string)
{
	r := t("tag ranges sel");
	(n, l) := sys->tokenize(r, " ");
	if(n < 2)
		return (nil, nil);
	return (hd l, hd tl l);
}

hassel(): int
{
	(a, nil) := selrange();
	return a != nil;
}

getseltext(): string
{
	(a, b) := selrange();
	if(a == nil)
		return "";
	return t("get " + a + " " + b);
}

# Delete the selection, if there is one.
delsel(): int
{
	(a, b) := selrange();
	if(a == nil)
		return 0;
	del(a, b);
	setcursor(a);
	return 1;
}

selectall()
{
	t("tag add sel 1.0 end");
	t("mark set insert end");
}

docopy()
{
	s := getseltext();
	if(s != "")
		tkclient->snarfput(s);
}

docut()
{
	if(!hassel())
		return;
	docopy();
	newaction();
	delsel();
}

dopaste()
{
	s := tkclient->snarfget();
	if(s == "")
		return;
	newaction();
	delsel();
	setcursor(ins("insert", s));
}

# ---------- Find ----------

startfind()
{
	beginprompt(PFIND, "Find:");
}

# Find doc.searchstr after the cursor, from the top again past the end,
# and select it.
findnext()
{
	if(doc.searchstr == "")
		return;
	ix := search(doc.searchstr, "insert+1c");
	if(ix == nil){
		statusmsg = "not found: " + doc.searchstr;
		return;
	}
	setcursor(ix);
	t("tag add sel " + ix + " " + after(ix, len doc.searchstr));
}

# The index of the first pat at or after ix, from the top again past
# the end; nil if there is none.  (Not the widget's search, which
# takes no more than 127 bytes of pattern and cuts the rest off.)
search(pat, ix: string): string
{
	text := getbodytext();
	i := strindex(text, pat, len t("get 1.0 {" + ix + "}"));
	if(i < 0)
		i = strindex(text, pat, 0);
	if(i < 0)
		return nil;
	return after("1.0", i);
}

strindex(s, sub: string, start: int): int
{
	n := len sub;
	if(n == 0)
		return -1;
	for(i := start; i <= len s - n; i++){
		for(j := 0; j < n && s[i+j] == sub[j]; j++)
			;
		if(j == n)
			return i;
	}
	return -1;
}

# ---------- Replace ----------

startreplace()
{
	beginprompt(PREPLACEFIND, "Replace:");
}

# Replace the next find at or after the cursor, from the top again
# past the end.
doreplace(find, repl: string)
{
	if(find == "")
		return;
	ix := search(find, "insert");
	if(ix == nil){
		statusmsg = "not found: " + find;
		return;
	}
	newaction();
	del(ix, after(ix, len find));
	setcursor(ins(ix, repl));
}

doreplaceall(find, repl: string): int
{
	if(find == "")
		return 0;
	text := getbodytext();
	found: list of int;	# the last first
	for(i := strindex(text, find, 0); i >= 0; i = strindex(text, find, i + len find))
		found = i :: found;
	# from the end back, so the places before are where they were
	newaction();
	count := 0;
	for(; found != nil; found = tl found){
		ix := after("1.0", hd found);
		del(ix, after(ix, len find));
		ins(ix, repl);
		count++;
	}
	setcursor("1.0");
	return count;
}

# ---------- File I/O ----------

# Read path into the document, with no undo and nothing to save; the
# document is left as it was if path cannot be read.
loadfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("cannot open %s: %r", path);
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return sys->sprint("cannot stat %s: %r", path);
	if(d.mode & Sys->DMDIR)
		return path + " is a directory";

	buf := array[8192] of byte;
	nb := 0;
	for(;;) {
		if(nb == len buf){
			b := array[2 * len buf] of byte;
			b[0:] = buf;
			buf = b;
		}
		n := sys->read(fd, buf[nb:], len buf - nb);
		if(n < 0)
			return sys->sprint("cannot read %s: %r", path);
		if(n == 0)
			break;
		nb += n;
	}
	newdoc();
	rawins("1.0", string buf[0:nb]);
	setcursor("1.0");
	doc.filepath = path;
	return nil;
}

dosave()
{
	if(doc.filepath == "") {
		startsaveas();
		return;
	}
	savefile(doc.filepath);
}

# Write the text to path; "ok", or why not.  A failure is said in the
# status bar too, and the text stays not saved.
savefile(path: string): string
{
	b := array of byte getbodytext();
	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil)
		return saveerr(sys->sprint("cannot create %s: %r", path));
	for(o := 0; o < len b; ){
		n := len b - o;
		if(n > Sys->ATOMICIO)
			n = Sys->ATOMICIO;
		if(sys->write(fd, b[o:], n) != n)
			return saveerr(sys->sprint("cannot write %s: %r", path));
		o += n;
	}
	fd = nil;

	savedseq = topseq();
	exitasked = 0;
	lastkind = 0;
	statusmsg = "saved";
	postevent("save " + path);
	return "ok";
}

saveerr(e: string): string
{
	statusmsg = e;
	return "error: " + e;
}

# ---------- Helpers ----------

themelistener()
{
	# any write of /lib/lucifer/theme/current, Lucifer or not (lucitheme->watch)
	lt := load Lucitheme Lucitheme->PATH;
	if(lt == nil)
		return;
	c := lt->watch();
	for(;;){
		<-c;
		themech <-= 1;
	}
}

reloadcolors()
{
	loadcolors();
	if(top == nil)
		return;
	tkclient->wmctl(top, "retheme");
	tkcmds(array[] of {
		". configure -background " + c_bg,
		".main.t configure -background " + c_bg + " -foreground " + c_fg +
			" -selectbackground " + c_sel + " -selectforeground " + c_bg,
		".status configure -background " + c_bg + " -foreground " + c_dim,
		".prompt configure -background " + c_bg + " -foreground " + c_fg,
	});
}

timer(c: chan of int, ms: int)
{
	for(;;) {
		sys->sleep(ms);
		c <-= 1;
	}
}

evtimeout(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

postnote(t: int, pid: int, note: string): int
{
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return -1;
	if(t == 1)
		note += "grp";
	sys->fprint(fd, "%s", note);
	fd = nil;
	return 0;
}

splittab(s: string): (string, string)
{
	for(i := 0; i < len s; i++) {
		if(s[i] == '\t')
			return (s[0:i], s[i+1:]);
	}
	return (s, "");
}

splitfirst(s: string): (string, string)
{
	# Strip leading whitespace
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	s = s[i:];
	# Find first space
	for(j := 0; j < len s; j++) {
		if(s[j] == ' ' || s[j] == '\t') {
			rest := s[j+1:];
			# Strip leading whitespace from rest
			k := 0;
			while(k < len rest && (rest[k] == ' ' || rest[k] == '\t'))
				k++;
			return (s[0:j], rest[k:]);
		}
	}
	return (s, "");
}

readf(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	s := string buf[0:n];
	# Strip trailing newline
	while(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

# ---------- Real-file IPC helpers ----------
# /tmp/veltro/editor/ is visible to the editor tool through an explicit path
# capability, not as ambient /tmp/veltro state.
# The tick loop polls command files and writes state files so the
# Veltro editor tool can read/write the editor across namespace forks.
# A command file is taken by renaming it before it is read, so one
# written meanwhile is a new file, not lost in a truncation; the outcome
# of each is written to result.

initeditdir()
{
	mkdirq("/tmp/veltro");
	mkdirq(EDIT_DIR);
	mkdirq(EDIT_INST);
	# Pre-create state files so tool reads don't fail before writeeditstate().
	# Empty files are valid — the tool returns "" rather than an error.
	touchfile(EDIT_INST + "/body");
	touchfile(EDIT_INST + "/addr");
	touchfile(EDIT_DIR + "/index");
}

touchfile(path: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	fd = nil;
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

writeeditstate()
{
	if(!statedirty)
		return;
	body := getbodytext();
	writestatefile(EDIT_INST + "/body", body);
	(l, c) := parseindex(t("index insert"));
	writestatefile(EDIT_INST + "/addr", sys->sprint("%d %d", l + 1, c + 1));
	writestatefile(EDIT_DIR + "/index", indexline());
	statedirty = 0;
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
	changed := 0;
	lastkind = 0;

	# Global ctl: open <path>, new, quit
	(gcmd, nil) := takefile(EDIT_DIR, "ctl");
	if(gcmd != nil) {
		# quit does not come back to say so
		if(str->tolower(chomp(gcmd)) == "quit" && !isdirty())
			writestatefile(EDIT_DIR + "/result", "ok");
		writestatefile(EDIT_DIR + "/result", handlegctl(gcmd));
		changed = 1;
	}

	# Per-doc ctl: save, saveas <p>, goto <n>, find <s>, name <p>, insert, delete
	(dcmd, nil) := takefile(EDIT_INST, "ctl");
	if(dcmd != nil) {
		writestatefile(EDIT_DIR + "/result", handledocctl(dcmd));
		changed = 1;
	}

	# body.in: replace document body
	(newbody, there) := takefile(EDIT_INST, "body.in");
	if(there) {
		newaction();
		setbodytext(newbody);
		postevent("modified");
		writestatefile(EDIT_DIR + "/result", "ok");
		changed = 1;
	}

	return changed;
}

# The contents of dir/name, which is removed, and whether it was there.
# It is renamed first, so a writer that comes after makes a new one
# rather than writing into the one being taken.
takefile(dir, name: string): (string, int)
{
	path := dir + "/" + name;
	taken := name + ".taken";
	d := sys->nulldir;
	d.name = taken;
	if(sys->wstat(path, d) >= 0)
		path = dir + "/" + taken;
	# else a file system that cannot rename: read it where it is
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, 0);
	buf := array[8192] of byte;
	nb := 0;
	for(;;){
		if(nb == len buf){
			b := array[2 * len buf] of byte;
			b[0:] = buf;
			buf = b;
		}
		n := sys->read(fd, buf[nb:], len buf - nb);
		if(n <= 0)
			break;
		nb += n;
	}
	fd = nil;
	sys->remove(path);
	return (string buf[0:nb], 1);
}
