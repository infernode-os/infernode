implement Shell;

#
# shell - Draw-based shell terminal with 9P interface
#
# A terminal emulator for the Inferno shell, with a file-based interface
# for read-only access by Veltro agents.  The shell process (/dis/sh.dis)
# communicates via synthetic /dev/cons and /dev/consctl created by file2chan.
#
# Real-file IPC at /tmp/veltro/shell/ for Veltro tool access:
#   /tmp/veltro/shell/body      Current transcript (read-only)
#   /tmp/veltro/shell/input     Current input line
#
# Keyboard:
#   Type to send input to shell
#   Enter        send current line to shell
#   Backspace    delete char before cursor
#   Ctrl-C       send interrupt (DEL) to shell
#   Ctrl-D       send EOF to shell
#   Ctrl-U       clear input line
#   Ctrl-W       delete word before cursor
#   Ctrl-L       clear screen (keep prompt)
#   Up/Down      scroll history
#   Page Up/Down scroll transcript
#   Ctrl-Q       quit
#   ESC          toggle hold mode (freeze output)
#
# Mouse:
#   Button 1     place cursor / select text
#   Button 2     paste (snarf buffer)
#   Button 3     context menu / plumb word
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

include "sh.m";

include "lucitheme.m";

include "arg.m";
	arg: Arg;

include "workdir.m";
	workdir: Workdir;

include "plumbmsg.m";
	plumbmod: Plumbmsg;
	Msg: import plumbmod;

Shell: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

# Colors (fallback defaults; overridden by theme at runtime)
# Same palette as edit — no "terminal green" affectation.
BG:	con int 16rFFFDF6FF;		# warm off-white background
FG:	con int 16r333333FF;		# dark text
CURSORCOL: con int 16r2266CCFF;	# blue cursor
SELCOL:	con int 16rB4D5FEFF;		# light blue selection
PROMPTCOL: con int 16r555555FF;	# prompt (slightly dimmer than body text)
HOLDCOL: con int 16rCC8800FF;		# hold-mode text color
# Dimensions
MARGIN: con 4;
TABSTOP: con 8;

# Key constants (Inferno keyboard codes — canonical defs in Widget)
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
Kdel_char:	con 16r7F;	# DEL character for Ctrl-C
Keof_char:	con 16r04;	# ^D EOF

# Transcript buffer
MAXLINES: con 4000;
TRIMLINES: con 3000;

# History
MAXHIST: con 100;

# Maximum dynamic buttons
MAXBUTTONS: con 20;

# --- Module-level state ---
top: ref Toplevel;
wmctl: chan of string;
actch: chan of string;
display_g: ref Display;
vislines: int;
stderr: ref Sys->FD;
themech: chan of int;
prompting: int;			# unused placeholder (shell has no modal prompt)

# Theme colours resolved to #rrggbbff strings for Tk
c_bg:	string;
c_fg:	string;
c_dim:	string;
c_hold:	string;
c_sel:	string;
c_prompt: string;

SHFONT: con "/fonts/combined/unicode.14.font";

# Transcript buffer of output lines
lines: array of string;
nlines: int;		# number of lines in buffer
topline: int;		# first visible line (scroll position)
atbottom: int;		# auto-scroll to bottom

# Input line (what user is typing, not yet sent)
inputbuf: string;
inputcol: int;		# cursor position within inputbuf

# Global cursor (Plan 9 style — cursor can be anywhere in the buffer)
curline: int;		# cursor line (0..nlines-1)
curcol: int;		# cursor column in that line

# The last partial line from shell output (prompt hint)
promptstr: string;

# Shell I/O
rawon: int;			# written only by rawstateforwarder; reads are word-atomic in Dis
rawlock: chan of int;

# Selection
selactive: int;
selstartline: int;
selstartcol: int;
selendline: int;
selendcol: int;
snarfbuf: string;

# History
history: array of string;
nhist: int;
histpos: int;

# Channels
outputch: chan of string;	# shell output arrives here
sendbyteschan: chan of array of byte;	# keyboard → consserver

# Shell dir for Veltro read-only access
SHELL_DIR: con "/tmp/veltro/shell";
shellstatedirty: int;	# set when transcript changes, cleared after writing state

# Hold mode
holding: int;			# 1 = output frozen
holdqueue: list of string;	# output buffered while holding

# Scroll mode
scrolling: int;			# 1 = auto-scroll on output (default)

# Focus tracking
haskbdfocus: int;		# 1 = window has keyboard focus

# Working directory
cwd: string;

# Plumbing
plumbed: int;			# 1 = plumbing available

# Shell argv (built from command-line flags)
shellargv: list of string;

# Dynamic button bar
Button: adt {
	label: string;
	cmd: string;		# text to send as input
};
buttons: array of ref Button;
nbuttons: int;

# shctl channel
shctlch: chan of string;

# Window geometry (from command-line flags)
initwidth: int;
initheight: int;

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	str = load String String->PATH;
	stderr = sys->fildes(2);
	if(tk == nil || tkclient == nil) {
		sys->fprint(stderr, "shell: cannot load Tk: %r\n");
		raise "fail:cannot load Tk";
	}

	# Parse command-line arguments
	initwidth = 640;
	initheight = 480;
	fontpath := "";
	shellargv = "sh" :: "-i" :: nil;
	arg = load Arg Arg->PATH;
	if(arg != nil) {
		arg->init(argv);
		arg->setusage("shell [-w width] [-h height] [-f font] [-c cmd] [-ilxvn]");
		shflags: list of string;
		shcmd := "";
		while((c := arg->opt()) != 0)
			case c {
			'w' => initwidth = int arg->earg();
			'h' => initheight = int arg->earg();
			'f' => fontpath = arg->earg();
			'c' =>
				shcmd = arg->earg();
			'i' or 'l' or 'x' or 'v' or 'n' =>
				s := "";
				s[0] = c;
				shflags = ("-" + s) :: shflags;
			* => arg->usage();
			}
		if(shcmd != "") {
			shellargv = "sh" :: "-c" :: shcmd :: nil;
		} else {
			shellargv = "sh" :: "-i" :: nil;
			# shflags is reversed from parsing; append each
			# to build correct order via listappend
			for(fl := shflags; fl != nil; fl = tl fl)
				shellargv = listappend(shellargv, hd fl);
			for(ra := arg->argv(); ra != nil; ra = tl ra)
				shellargv = listappend(shellargv, hd ra);
		}
	}

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();

	# Get working directory
	workdir = load Workdir Workdir->PATH;
	if(workdir != nil)
		cwd = workdir->init();
	if(cwd == nil || cwd == "")
		cwd = "/";

	# Initialize state
	lines = array[MAXLINES] of string;
	lines[0] = "";
	nlines = 1;
	topline = 0;
	atbottom = 1;
	inputbuf = "";
	inputcol = 0;
	curline = 0;
	curcol = 0;
	promptstr = "";
	rawon = 0;
	rawlock = chan[1] of int;
	rawlock <-= 1;
	selactive = 0;
	snarfbuf = "";
	history = array[MAXHIST] of string;
	nhist = 0;
	histpos = -1;
	holding = 0;
	scrolling = 1;
	haskbdfocus = 1;
	plumbed = 0;
	buttons = array[MAXBUTTONS] of ref Button;
	nbuttons = 0;
	shctlch = chan[8] of string;

	outputch = chan[32] of string;
	sendbyteschan = chan of array of byte;

	# Start file-based IPC directory
	initshelldirs();

	# Start shell process (uses file2chan, must happen before window)
	spawn startshell(ctxt);

	# Create the Tk toplevel
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	title := "Shell " + cwd;
	(top, wmctl) = tkclient->toplevel(ctxt,
		sys->sprint("-width %d -height %d", initwidth, initheight), title, Tkclient->Appl);
	display_g = top.display;

	loadcolors();

	actch = chan[16] of string;
	tk->namechan(top, actch, "act");

	buildui();

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	# Initialize plumbing
	plumbmod = load Plumbmsg Plumbmsg->PATH;
	if(plumbmod != nil) {
		if(plumbmod->init(0, nil, 0) >= 0)
			plumbed = 1;
	}

	rendertext();

	# Periodic state writer
	ticks := chan of int;
	spawn timer(ticks, 500);

	# Listen for live theme changes
	themech = chan[1] of int;
	spawn themelistener();

	for(;;) alt {
	c := <-wmctl or
	c = <-top.ctxt.ctl =>
		tkclient->wmctl(top, c);
		if(c != nil && len c > 0 && c[0] == '!')
			rendertext();
	key := <-top.ctxt.kbd =>
		handlekey(key);
		shellstatedirty = 1;
		rendertext();
	p := <-top.ctxt.ptr =>
		# Tk owns mouse positioning / selection; mirror it back.
		tk->pointer(top, *p);
		syncfromwidget();
	a := <-actch =>
		handleaction(a);
	<-ticks =>
		writeshellstate();
	output := <-outputch =>
		if(holding) {
			holdqueue = output :: holdqueue;
		} else {
			wasoninput := (curline == nlines - 1);
			appendoutput(output);
			if(wasoninput) {
				curline = nlines - 1;
				curcol = len promptstr + inputcol;
			}
			if(atbottom && scrolling)
				scrolltobottom();
			shellstatedirty = 1;
			rendertext();
		}
	cmd := <-shctlch =>
		handleshctl(cmd);
		rendertext();
	<-themech =>
		reloadcolors();
		rendertext();
	}
}

updatetitle()
{
	title := "Shell " + cwd;
	if(holding)
		title += " (holding)";
	tkclient->settitle(top, title);
}

# ---------- Context menu (B3) ----------

buildmenu()
{
	tk->cmd(top, "destroy .ctx");
	tk->cmd(top, "menu .ctx");
	mitem("cut", "cut");
	mitem("snarf", "snarf");
	mitem("paste", "paste");
	mitem("send", "send");
	if(plumbed)
		mitem("plumb", "plumb");
	if(scrolling)
		mitem("noscroll", "scroll");
	else
		mitem("scroll", "scroll");
	mitem("clear", "clear");
	tk->cmd(top, ".ctx add separator");
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

# Menu items and the dynamic button bar post tokens here.
handleaction(a: string)
{
	(nil, toks) := sys->tokenize(a, " ");
	if(toks == nil)
		return;
	tok := hd toks;
	case tok {
	"menu" =>
		buildmenu();
		tk->cmd(top, ".ctx post " + menuxyt(toks));
	"cut" =>	docut(); rendertext();
	"snarf" =>	dosnarf();
	"paste" =>	dopaste(); rendertext();
	"send" =>	dosend(); rendertext();
	"plumb" =>	doplumb();
	"scroll" =>	scrolling = !scrolling; rendertext();
	"clear" =>	clearscreen(); rendertext();
	"exit" =>
		postnote(1, sys->pctl(0, nil), "kill");
		exit;
	"btn" =>
		if(tl toks != nil){
			i := int hd tl toks;
			if(i >= 0 && i < nbuttons){
				s := buttons[i].cmd;
				if(len s > 0 && s[len s-1] != '\n')
					s += "\n";
				insertinput(s);
				rendertext();
			}
		}
	}
}

# ---------- UI construction ----------

buildui()
{
	cmds := array[] of {
		". configure -background " + c_bg,
		"frame .main",
		"scrollbar .main.sb -command {.main.t yview}",
		"text .main.t -wrap char -yscrollcommand {.main.sb set}" +
			" -font " + SHFONT +
			" -background " + c_bg +
			" -foreground " + c_fg +
			" -selectbackground " + c_sel +
			" -selectforeground " + c_bg,
		"pack .main.sb -side left -fill y",
		"pack .main.t -side left -fill both -expand 1",
		"pack .main -side top -fill both -expand 1",
		"frame .btns -background " + c_bg,
		"label .status -anchor w -background " + c_bg + " -foreground " + c_dim,
		"pack .status -side bottom -fill x",
		"pack propagate . 0",
		".main.t tag configure prompt -foreground " + c_prompt,
		"bind .main.t <Button-3> {send act menu %X %Y}",
	};
	tkcmds(cmds);
	tk->cmd(top, "focus .main.t");
	tk->cmd(top, "update");
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "shell: tk error %s on %s\n", e, cmds[i]);
	}
}

# ---------- Rendering: the text widget is a view of the transcript ----------

# The full visible text is the transcript plus the live input line
# (promptstr + inputbuf) standing in for the empty last buffer line.
displaytext(): string
{
	s := "";
	for(i := 0; i < nlines; i++){
		if(i > 0)
			s += "\n";
		if(i == nlines - 1)
			s += promptstr + inputbuf;
		else
			s += lines[i];
	}
	return s;
}

rendertext()
{
	if(top == nil)
		return;
	tk->cmd(top, ".main.t delete 1.0 end");
	tk->cmd(top, ".main.t insert end " + tk->quote(displaytext()));
	# tag the prompt portion of the input (last) line
	if(promptstr != "")
		tk->cmd(top, sys->sprint(".main.t tag add prompt %d.0 %d.%d",
			nlines, nlines, len promptstr));
	# selection
	tk->cmd(top, ".main.t tag remove sel 1.0 end");
	if(selactive)
		tk->cmd(top, sys->sprint(".main.t tag add sel %d.%d %d.%d",
			selstartline+1, selstartcol, selendline+1, selendcol));
	tk->cmd(top, sys->sprint(".main.t mark set insert %d.%d", curline+1, curcol));
	if(atbottom)
		tk->cmd(top, ".main.t see end");
	else
		tk->cmd(top, ".main.t see insert");
	recalcvis();
	rebuildbuttons();
	updatestatus();
	tk->cmd(top, "update");
}

# After native mouse handling, copy the widget cursor and selection back.
syncfromwidget()
{
	(l, c) := parseindex(tk->cmd(top, ".main.t index insert"));
	if(l >= 0){
		curline = l;
		curcol = c;
	}
	sf := tk->cmd(top, ".main.t index sel.first");
	if(sf != nil && len sf > 0 && sf[0] >= '0' && sf[0] <= '9'){
		(a, b) := parseindex(sf);
		(d, e) := parseindex(tk->cmd(top, ".main.t index sel.last"));
		if(a >= 0 && d >= 0){
			selactive = 1;
			selstartline = a; selstartcol = b;
			selendline = d; selendcol = e;
		}
	} else
		selactive = 0;
	updatestatus();
}

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

# Rebuild the dynamic button bar (shell ctl can add labelled buttons).
nbuttons_drawn := -1;
rebuildbuttons()
{
	if(nbuttons == nbuttons_drawn)
		return;
	nbuttons_drawn = nbuttons;
	tk->cmd(top, "destroy .btns");
	tk->cmd(top, "frame .btns -background " + c_bg);
	if(nbuttons > 0){
		for(i := 0; i < nbuttons; i++)
			tk->cmd(top, sys->sprint("button .btns.b%d -text %s -command {send act btn %d}; pack .btns.b%d -side left -padx 2",
				i, tk->quote(buttons[i].label), i, i));
		tk->cmd(top, "pack .btns -side bottom -fill x -before .status");
	}
}

updatestatus()
{
	if(top == nil)
		return;
	<-rawlock;
	israw := rawon;
	rawlock <-= 1;
	mode := "cooked";
	if(israw)
		mode = "raw";
	status := sys->sprint("Shell (%s)  %d lines", mode, nlines);
	if(holding)
		status += "  HOLD";
	if(!scrolling)
		status += "  noscroll";
	fg := c_dim;
	if(holding)
		fg = c_hold;
	tk->cmd(top, ".status configure -foreground " + fg + " -text " + tk->quote(status));
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
		c_dim = col(th.dim >> 8);
		c_hold = col(th.yellow >> 8);
		c_sel = col(th.accent >> 8);
		c_prompt = col(th.dim >> 8);
	} else {
		c_bg = col(BG >> 8);
		c_fg = col(FG >> 8);
		c_dim = col(PROMPTCOL >> 8);
		c_hold = col(HOLDCOL >> 8);
		c_sel = col(SELCOL >> 8);
		c_prompt = col(PROMPTCOL >> 8);
	}
}

# ---------- System clipboard via /chan/snarf ----------

snarfput(s: string)
{
	fd := sys->create("/chan/snarf", Sys->OWRITE, 8r666);
	if(fd == nil)
		fd = sys->open("/chan/snarf", Sys->OWRITE);
	if(fd != nil){
		b := array of byte s;
		sys->write(fd, b, len b);
	}
}

snarfget(): string
{
	fd := sys->open("/chan/snarf", Sys->OREAD);
	if(fd == nil)
		return snarfbuf;
	s := "";
	buf := array[4096] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[:n];
	}
	if(s == "")
		return snarfbuf;
	return s;
}

docut()
{
	dosnarf();
	# Delete selection from transcript (only in transcript, not input line)
	# This is a simplified cut — it snarfs the text and clears the selection
	selactive = 0;
}

dosnarf()
{
	s := getseltext();
	if(s != "") {
		snarfbuf = s;
		snarfput(s);
	}
}

dopaste()
{
	buf := snarfget();
	if(buf != "")
		snarfbuf = buf;
	if(snarfbuf != "")
		insertinput(snarfbuf);
}

doplumb()
{
	# Plumb selected text, or word at last click position
	s := getseltext();
	if(s == "" && selstartline >= 0) {
		line := getlineat(selstartline);
		s = wordatpos(line, selstartcol);
	}
	plumbtext(s);
}

dosend()
{
	# Plan 9 / Inferno convention: "send" sends the selected text
	# as input to the shell (select-and-execute idiom).
	# If there's no selection, fall back to snarf buffer.
	s := getseltext();
	if(s == "") {
		buf := snarfget();
		if(buf != "")
			snarfbuf = buf;
		s = snarfbuf;
	}
	if(s == "")
		return;
	# Ensure it ends with newline so the shell executes it
	if(len s > 0 && s[len s - 1] != '\n')
		s += "\n";
	selactive = 0;
	insertinput(s);
}

# ---------- Plumbing ----------

plumbtext(text: string)
{
	if(!plumbed || text == "")
		return;
	msg := ref Msg(
		"Shell",		# src
		"",			# dst (let plumber decide)
		cwd,			# dir
		"text",			# kind
		"",			# attr
		array of byte text	# data
	);
	msg.send();
}

# Extract word at character position in a line
wordatpos(line: string, col: int): string
{
	if(col >= len line)
		return "";
	# Find word boundaries (non-whitespace run)
	start := col;
	while(start > 0 && !isspace(line[start-1]))
		start--;
	end := col;
	while(end < len line && !isspace(line[end]))
		end++;
	if(start == end)
		return "";
	return line[start:end];
}

isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

# ---------- Shell process ----------

startshell(ctxt: ref Draw->Context)
{
	# Fork namespace so our synthetic /dev/cons doesn't affect parent
	sys->pctl(Sys->FORKNS, nil);

	# Bind #s (srv device) so file2chan works
	if(sys->bind("#s", "/chan", Sys->MBEFORE|Sys->MCREATE) < 0) {
		sys->fprint(stderr, "shell: bind #s: %r\n");
		outputch <-= "shell: cannot bind #s for file2chan\n";
		return;
	}

	# Create synthetic /dev/cons using file2chan
	consio := sys->file2chan("/chan", "cons");
	if(consio == nil) {
		sys->fprint(stderr, "shell: file2chan cons: %r\n");
		outputch <-= "shell: cannot create synthetic cons\n";
		return;
	}

	# Create synthetic /dev/consctl
	consctlio := sys->file2chan("/chan", "consctl");

	# Create synthetic /dev/shctl for dynamic button bar
	shctlio := sys->file2chan("/chan", "shctl");

	# Bind our synthetic cons over /dev/cons
	if(sys->bind("/chan/cons", "/dev/cons", Sys->MREPL) < 0)
		sys->fprint(stderr, "shell: bind cons: %r\n");
	if(consctlio != nil) {
		if(sys->bind("/chan/consctl", "/dev/consctl", Sys->MREPL) < 0)
			sys->fprint(stderr, "shell: bind consctl: %r\n");
	}
	if(shctlio != nil) {
		if(sys->bind("/chan/shctl", "/dev/shctl", Sys->MREPL) < 0)
			sys->fprint(stderr, "shell: bind shctl: %r\n");
	}

	# Fork the fd table so our redirections below do not affect the main
	# shell goroutine (which still needs its original stdin/stdout/stderr).
	sys->pctl(Sys->FORKFD, nil);

	# Redirect stdin, stdout, and stderr to our synthetic /dev/cons.
	newcons := sys->open("/dev/cons", Sys->ORDWR);
	if(newcons != nil) {
		sys->dup(newcons.fd, 0);	# stdin  → synthetic cons
		sys->dup(newcons.fd, 1);	# stdout → synthetic cons
		sys->dup(newcons.fd, 2);	# stderr → synthetic cons (prompts go here)
		newcons = nil;
	}

	# Start the file server for cons reads/writes
	spawn consserver(consio, consctlio);

	# Start the shctl server
	if(shctlio != nil)
		spawn shctlserver(shctlio);

	# Give consserver a moment to start
	sys->sleep(50);

	# Load and run the shell
	sh := load Command "/dis/sh.dis";
	if(sh == nil) {
		err := sys->sprint("%r");
		sys->fprint(stderr, "shell: cannot load /dis/sh.dis: %s\n", err);
		outputch <-= "shell: cannot load /dis/sh.dis: " + err + "\n";
		return;
	}

	# Pass the real Draw context so GUI apps invoked from this shell
	# (wm/matrix, wm/man, wm/clock, etc.) can open their own windows.
	# Previously this was nil, which made every GUI app fall back to
	# headless / refuse to start.
	spawn sh->init(ctxt, shellargv);
}

# consserver: services reads and writes on synthetic /dev/cons and /dev/consctl.
# Shell writes → outputch → display.
# User keyboard → sendbyteschan → shell reads.
consserver(consio, consctlio: ref Sys->FileIO)
{
	# Pending shell read requests: (nbytes, reply channel) pairs
	rdqueue: list of (int, Sys->Rread);

	# Pending input bytes (user typed, shell hasn't read yet)
	inputqueue: list of array of byte;

	# Channel for rawon state changes (communicated to main goroutine)
	rawch := chan of int;
	spawn rawstateforwarder(rawch);

	if(consctlio != nil) {
		spawn consctlserver(consctlio, rawch);
	}

	for(;;) alt {
	(nil, nbytes, nil, rc) := <-consio.read =>
		if(rc == nil)
			continue;
		# Shell wants to read from cons
		if(inputqueue != nil) {
			data := hd inputqueue;
			inputqueue = tl inputqueue;
			if(len data > nbytes)
				data = data[0:nbytes];
			rc <-= (data, nil);
		} else {
			rdqueue = (nbytes, rc) :: rdqueue;
		}

	(nil, data, nil, wc) := <-consio.write =>
		if(wc == nil)
			continue;
		# Shell wrote output
		s := string data;
		wc <-= (len data, nil);
		outputch <-= s;

	ibytes := <-sendbyteschan =>
		# Try to satisfy pending shell read requests
		if(rdqueue != nil) {
			# Reverse to deliver in FIFO order
			rds: list of (int, Sys->Rread);
			for(rl := rdqueue; rl != nil; rl = tl rl)
				rds = (hd rl) :: rds;
			rdqueue = nil;

			for(; rds != nil && len ibytes > 0; rds = tl rds) {
				(rnb, rq) := hd rds;
				chunk := ibytes;
				if(len chunk > rnb)
					chunk = chunk[0:rnb];
				rq <-= (chunk, nil);
				if(len chunk < len ibytes)
					ibytes = ibytes[len chunk:];
				else
					ibytes = nil;
			}
			# Re-queue unserviced reads
			for(; rds != nil; rds = tl rds)
				rdqueue = (hd rds) :: rdqueue;
		}
		if(ibytes != nil && len ibytes > 0)
			inputqueue = ibytes :: inputqueue;
	}
}

# consctlserver handles /dev/consctl reads and writes in a separate goroutine,
# preventing nil dereference when consctlio is nil and avoiding blocking consserver.
consctlserver(consctlio: ref Sys->FileIO, rawch: chan of int)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-consctlio.read =>
		if(rc == nil)
			continue;
		rc <-= (nil, "permission denied");

	(nil, data, nil, wc) := <-consctlio.write =>
		if(wc == nil)
			continue;
		s := string data;
		if(s == "rawon")
			rawch <-= 1;
		else if(s == "rawoff")
			rawch <-= 0;
		wc <-= (len data, nil);
	}
}

# rawstateforwarder receives rawon state changes and updates the shared variable.
# This serialises access to rawon through a single goroutine.
rawstateforwarder(rawch: chan of int)
{
	for(;;) {
		v := <-rawch;
		<-rawlock;
		rawon = v;
		rawlock <-= 1;
	}
}

# shctlserver handles /dev/shctl reads and writes.
# Commands: button "label" "cmd", cwd /dir, clear
shctlserver(shctlio: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-shctlio.read =>
		if(rc == nil)
			continue;
		rc <-= (nil, "permission denied");

	(nil, data, nil, wc) := <-shctlio.write =>
		if(wc == nil)
			continue;
		s := string data;
		wc <-= (len data, nil);
		shctlch <-= s;
	}
}

handleshctl(cmd: string)
{
	# Strip trailing newline
	if(len cmd > 0 && cmd[len cmd - 1] == '\n')
		cmd = cmd[0:len cmd - 1];
	if(len cmd == 0)
		return;

	# Parse command
	if(len cmd > 7 && cmd[0:7] == "button ") {
		# button "label" "cmd"
		(label, rest) := parseshctlarg(cmd[7:]);
		(bcmd, nil) := parseshctlarg(rest);
		if(label != "" && nbuttons < MAXBUTTONS) {
			buttons[nbuttons] = ref Button(label, bcmd);
			nbuttons++;
		}
	} else if(len cmd > 4 && cmd[0:4] == "cwd ") {
		cwd = cmd[4:];
		updatetitle();
	} else if(cmd == "clear") {
		nbuttons = 0;
	}
}

# Parse a quoted or unquoted argument from shctl command
parseshctlarg(s: string): (string, string)
{
	# Skip whitespace
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	if(i >= len s)
		return ("", "");
	if(s[i] == '"') {
		# Quoted string
		i++;
		start := i;
		while(i < len s && s[i] != '"')
			i++;
		val := s[start:i];
		if(i < len s)
			i++;	# skip closing quote
		return (val, s[i:]);
	}
	# Unquoted: take until whitespace
	start := i;
	while(i < len s && s[i] != ' ' && s[i] != '\t')
		i++;
	return (s[start:i], s[i:]);
}

sendinput(s: string)
{
	b := array of byte s;
	sendbyteschan <-= b;
}

# ---------- Keyboard handling ----------

handlekey(key: int)
{
	ctrl := 0;
	if(key >= 1 && key <= 26 && key != Kbs && key != '\n' && key != '\t')
		ctrl = 1;

	<-rawlock;
	israw := rawon;
	rawlock <-= 1;
	if(israw) {
		# In raw mode, send every keystroke directly to shell
		s := "";
		s[0] = key;
		sendinput(s);
		return;
	}

	if(ctrl) {
		case key {
		3 =>	# Ctrl-C: interrupt
			s := "";
			s[0] = Kdel_char;
			sendinput(s);
			inputbuf = "";
			inputcol = 0;
			appendoutput("^C\n");
			curline = nlines - 1;
			curcol = len promptstr;
		4 =>	# Ctrl-D: EOF
			if(inputbuf == "") {
				s := "";
				s[0] = Keof_char;
				sendinput(s);
			}
		12 =>	# Ctrl-L: clear
			clearscreen();
		17 =>	# Ctrl-Q: quit
			postnote(1, sys->pctl(0, nil), "kill");
			exit;
		21 =>	# Ctrl-U: clear input line
			inputbuf = "";
			inputcol = 0;
			cursortoinput();
		14 =>	# Ctrl-N: next history
			if(histpos >= 0) {
				histpos++;
				if(histpos >= nhist) {
					histpos = -1;
					inputbuf = "";
					inputcol = 0;
				} else {
					inputbuf = history[histpos];
					inputcol = len inputbuf;
				}
				cursortoinput();
			}
		16 =>	# Ctrl-P: previous history
			if(nhist > 0) {
				if(histpos < 0)
					histpos = nhist;
				if(histpos > 0) {
					histpos--;
					inputbuf = history[histpos];
					inputcol = len inputbuf;
					cursortoinput();
				}
			}
		23 =>	# Ctrl-W: delete word before cursor
			if(curline != nlines - 1)
				cursortoinput();
			else
				syncinputcol();
			if(inputcol > 0) {
				j := inputcol;
				# Skip whitespace backwards
				while(j > 0 && isspace(inputbuf[j-1]))
					j--;
				# Skip non-whitespace backwards
				while(j > 0 && !isspace(inputbuf[j-1]))
					j--;
				inputbuf = inputbuf[0:j] + inputbuf[inputcol:];
				inputcol = j;
				curcol = len promptstr + inputcol;
			}
		}
		return;
	}

	case key {
	'\n' =>
		if(curline == nlines - 1) {
			# Cursor on input line: send inputbuf
			line := inputbuf + "\n";
			if(inputbuf != "")
				addhistory(inputbuf);
			histpos = -1;
			appendoutput(inputbuf + "\n");
			inputbuf = "";
			inputcol = 0;
			sendinput(line);
		} else {
			# Cursor on transcript line: send that line (Plan 9 idiom)
			text := lines[curline];
			if(text != "")
				addhistory(text);
			histpos = -1;
			sendinput(text + "\n");
			appendoutput(text + "\n");
			inputbuf = "";
			inputcol = 0;
		}
		curline = nlines - 1;
		curcol = len promptstr;
		if(atbottom)
			scrolltobottom();
		;
	Kbs =>
		if(curline == nlines - 1 && curcol > len promptstr) {
			# On input line past prompt — edit inputbuf
			syncinputcol();
			if(inputcol > 0) {
				inputbuf = inputbuf[0:inputcol-1] + inputbuf[inputcol:];
				inputcol--;
				curcol = len promptstr + inputcol;
			}
		} else if(curline != nlines - 1 && curcol > 0) {
			# In transcript — edit in place
			line := lines[curline];
			lines[curline] = line[0:curcol-1] + line[curcol:];
			curcol--;
		}
	Kdel =>
		if(curline == nlines - 1 && curcol >= len promptstr) {
			# On input line past prompt — edit inputbuf
			syncinputcol();
			if(inputcol < len inputbuf)
				inputbuf = inputbuf[0:inputcol] + inputbuf[inputcol+1:];
		} else if(curline != nlines - 1) {
			# In transcript — edit in place
			line := lines[curline];
			if(curcol < len line)
				lines[curline] = line[0:curcol] + line[curcol+1:];
		}
	Kleft =>
		if(curcol > 0)
			curcol--;
		else if(curline > 0) {
			curline--;
			curcol = len getlineat(curline);
		}
		selactive = 0;
		scrolltocursor();
	Kright =>
		{
			line := getlineat(curline);
			if(curcol < len line)
				curcol++;
			else if(curline < nlines - 1) {
				curline++;
				curcol = 0;
			}
		}
		selactive = 0;
		scrolltocursor();
	Khome =>
		curcol = 0;
		selactive = 0;
	Kend =>
		curcol = len getlineat(curline);
		selactive = 0;
	Kup =>
		if(curline > 0) {
			curline--;
			fixcol();
		}
		selactive = 0;
		scrolltocursor();
	Kdown =>
		if(curline < nlines - 1) {
			curline++;
			fixcol();
		}
		selactive = 0;
		scrolltocursor();
	Kpgup =>
		if(vislines > 0) {
			topline -= vislines;
			if(topline < 0)
				topline = 0;
			atbottom = 0;
			curline -= vislines;
			if(curline < 0) curline = 0;
			fixcol();
		}
	Kpgdown =>
		if(vislines > 0) {
			topline += vislines;
			maxtl := nlines - vislines;
			if(maxtl < 0) maxtl = 0;
			if(topline > maxtl) topline = maxtl;
			if(topline >= nlines - vislines)
				atbottom = 1;
			curline += vislines;
			if(curline >= nlines) curline = nlines - 1;
			fixcol();
		}
	'\t' =>
		if(curline == nlines - 1 && curcol >= len promptstr) {
			syncinputcol();
			insertinput("\t");
			curcol = len promptstr + inputcol;
		} else if(curline != nlines - 1) {
			insertintranscript("\t");
		}
	Kesc =>
		# Toggle hold mode
		holding = !holding;
		if(!holding) {
			# Flush queued output
			flushholdqueue();
		}
		updatetitle();
	* =>
		if(key >= 16r20) {
			if(curline == nlines - 1 && curcol >= len promptstr) {
				# On input line past prompt — edit inputbuf
				syncinputcol();
				s := "";
				s[0] = key;
				insertinput(s);
				curcol = len promptstr + inputcol;
			} else if(curline != nlines - 1) {
				# In transcript — edit in place (Plan 9 style)
				s := "";
				s[0] = key;
				insertintranscript(s);
			}
		}
	}
}

insertinput(s: string)
{
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n') {
			line := inputbuf + "\n";
			if(inputbuf != "")
				addhistory(inputbuf);
			histpos = -1;
			appendoutput(inputbuf + "\n");
			inputbuf = "";
			inputcol = 0;
			sendinput(line);
			curline = nlines - 1;
			curcol = len promptstr;
		} else {
			if(inputcol >= len inputbuf)
				inputbuf += s[i:i+1];
			else
				inputbuf = inputbuf[0:inputcol] + s[i:i+1]
					+ inputbuf[inputcol:];
			inputcol++;
		}
	}
}

# Insert text at cursor position within a transcript line (Plan 9 style editing).
insertintranscript(s: string)
{
	if(curline < 0 || curline >= nlines - 1)
		return;
	line := lines[curline];
	if(curcol > len line)
		curcol = len line;
	lines[curline] = line[0:curcol] + s + line[curcol:];
	curcol += len s;
}

# ---------- Hold mode ----------

flushholdqueue()
{
	# Reverse the queue (it was built in reverse order)
	rev: list of string;
	for(q := holdqueue; q != nil; q = tl q)
		rev = (hd q) :: rev;
	holdqueue = nil;
	for(; rev != nil; rev = tl rev) {
		appendoutput(hd rev);
	}
	if(atbottom && scrolling)
		scrolltobottom();
	shellstatedirty = 1;
}

# ---------- History ----------

addhistory(line: string)
{
	if(nhist >= MAXHIST) {
		for(i := 0; i < MAXHIST - 1; i++)
			history[i] = history[i+1];
		nhist = MAXHIST - 1;
	}
	history[nhist] = line;
	nhist++;
}

# ---------- Output handling ----------

appendoutput(s: string)
{
	for(i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'\n' =>
			nlines++;
			if(nlines >= MAXLINES)
				trimtranscript();
			growlines();
			lines[nlines-1] = "";
		'\r' =>
			# Carriage return — move to start of current line
			lines[nlines-1] = "";
		'\b' =>
			line := lines[nlines-1];
			if(len line > 0)
				lines[nlines-1] = line[0:len line - 1];
		'\t' =>
			line := lines[nlines-1];
			spaces := TABSTOP - (len line % TABSTOP);
			for(j := 0; j < spaces; j++)
				lines[nlines-1] += " ";
		* =>
			if(c == 16r1B) {
				# ANSI escape — skip the sequence
				i++;
				if(i < len s && s[i] == '[') {
					i++;
					while(i < len s &&
					    !((s[i] >= 'A' && s[i] <= 'Z') ||
					      (s[i] >= 'a' && s[i] <= 'z')))
						i++;
				}
			} else if(c == 0) {
				# NUL → replacement character
				lines[nlines-1] += "□";
			} else if(c >= 16r20) {
				lines[nlines-1] += s[i:i+1];
			}
		}
	}

	# Save the last line as prompt hint
	if(nlines > 0)
		promptstr = lines[nlines-1];
}

trimtranscript()
{
	keep := TRIMLINES;
	if(keep >= nlines)
		return;
	drop := nlines - keep;
	for(i := 0; i < keep; i++)
		lines[i] = lines[i + drop];
	for(i = keep; i < nlines; i++)
		lines[i] = "";
	nlines = keep;
	topline -= drop;
	if(topline < 0)
		topline = 0;
	if(selactive) {
		selstartline -= drop;
		selendline -= drop;
		if(selstartline < 0 || selendline < 0)
			selactive = 0;
	}
	curline -= drop;
	if(curline < 0) {
		curline = 0;
		curcol = 0;
	}
}

# growlines is a safety net: trimtranscript keeps nlines < len lines,
# but this prevents a crash if the trim logic is ever changed.
growlines()
{
	if(nlines >= len lines) {
		newlines := array[len lines * 2] of string;
		newlines[0:] = lines;
		lines = newlines;
	}
}

clearscreen()
{
	lines[0] = promptstr;
	for(i := 1; i < nlines; i++)
		lines[i] = "";
	nlines = 1;
	topline = 0;
	atbottom = 1;
	curline = 0;
	curcol = len promptstr;
}

# The Tk text widget owns scrolling; rendertext() does ".main.t see end"
# whenever atbottom is set, so this just records the intent.
scrolltobottom()
{
	atbottom = 1;
}

scrolltocursor()
{
	if(vislines <= 0)
		return;
	if(curline < topline)
		topline = curline;
	else if(curline >= topline + vislines)
		topline = curline - vislines + 1;
	if(topline < 0)
		topline = 0;
}

fixcol()
{
	line := getlineat(curline);
	if(curcol > len line)
		curcol = len line;
}

# Sync inputcol from the global cursor when on the input line.
syncinputcol()
{
	if(curline != nlines - 1)
		return;
	inputcol = curcol - len promptstr;
	if(inputcol < 0)
		inputcol = 0;
	if(inputcol > len inputbuf)
		inputcol = len inputbuf;
}

# Move cursor to end of input line (for typing when cursor is in transcript).
cursortoinput()
{
	curline = nlines - 1;
	inputcol = len inputbuf;
	curcol = len promptstr + inputcol;
}

# ---------- Selection ----------

getlineat(row: int): string
{
	if(row < nlines - 1)
		return lines[row];
	return promptstr + inputbuf;
}

getsel(): (int, int, int, int)
{
	if(!selactive)
		return (0, 0, 0, 0);
	sl := selstartline;
	sc := selstartcol;
	el := selendline;
	ec := selendcol;
	if(sl > el || (sl == el && sc > ec)) {
		(sl, el) = (el, sl);
		(sc, ec) = (ec, sc);
	}
	return (sl, sc, el, ec);
}

getseltext(): string
{
	(sl, sc, el, ec) := getsel();
	if(!selactive)
		return "";
	total := nlines;
	if(sl == el) {
		line := getlineat(sl);
		if(sc > len line) sc = len line;
		if(ec > len line) ec = len line;
		return line[sc:ec];
	}
	line := getlineat(sl);
	if(sc > len line) sc = len line;
	s := line[sc:];
	for(i := sl + 1; i < el && i < total; i++)
		s += "\n" + getlineat(i);
	line = getlineat(el);
	if(ec > len line) ec = len line;
	s += "\n" + line[0:ec];
	return s;
}

# ---------- Drawing ----------

# Draw selection highlight for one wrapped chunk of a logical line.
# chunkstart..chunkend is the character range of this visual chunk.
# Draw a prompt chunk with the ';' character in accent color.
# ---------- Real-file IPC ----------

initshelldirs()
{
	mkdirq("/tmp/veltro");
	mkdirq(SHELL_DIR);
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

writeshellstate()
{
	if(!shellstatedirty)
		return;
	# Write transcript body (read-only for Veltro)
	body := getbodytext();
	writestatefile(SHELL_DIR + "/body", body);
	# Write current input line
	writestatefile(SHELL_DIR + "/input", inputbuf);
	shellstatedirty = 0;
}

getbodytext(): string
{
	s := "";
	for(i := 0; i < nlines; i++) {
		if(i > 0)
			s += "\n";
		s += lines[i];
	}
	return s;
}

writestatefile(path, data: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		return;
	b := array of byte data;
	sys->write(fd, b, len b);
	fd = nil;
}

# ---------- Text wrapping ----------

# ---------- Helpers ----------

themelistener()
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
		".main.t tag configure prompt -foreground " + c_prompt,
		".status configure -background " + c_bg,
	});
}

timer(c: chan of int, ms: int)
{
	for(;;) {
		sys->sleep(ms);
		c <-= 1;
	}
}

listappend(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return (hd l) :: listappend(tl l, s);
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
