implement Shell;

#
# shell - Tk shell terminal with a file interface for Veltro
#
# A terminal for the Inferno shell, with a file-based interface for
# read-only access by Veltro agents.  The shell process (/dis/sh.dis)
# communicates via synthetic /dev/cons and /dev/consctl created by file2chan.
#
# The transcript is the Tk text widget's text, as wm/sh's is: there is no
# copy of it to keep in step.  The mark outpoint is where output goes:
# what is before it is the transcript, what is after it the input being
# typed.  A line of input is sent when it is ended, and what follows
# it waits its turn, output going in before it.
#
# Real-file IPC at /tmp/veltro/shell/ for Veltro tool access:
#   /tmp/veltro/shell/body      Current transcript (read-only)
#   /tmp/veltro/shell/input     Current input line
#
# Keyboard:
#   Type to send input to shell
#   Enter        send current line to shell (on a line of the transcript:
#                send that line again)
#   Backspace    delete char before cursor
#   Ctrl-C       interrupt: the commands the shell is running are killed
#   Ctrl-D       send EOF to shell
#   Ctrl-U       clear input line
#   Ctrl-W       delete word before cursor
#   Ctrl-L       clear screen (keep prompt)
#   Ctrl-P/N     previous/next line of history
#   Ctrl-Q       quit
#   ESC          toggle hold mode (freeze output)
#
# Mouse:
#   Button 1     place cursor / select text
#   Button 2     drag to scroll
#   Button 3     context menu (cut, snarf, paste, send, plumb, ...)
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
include "softkbd.m";
	softkbd: Softkbd;

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
Keof_char:	con 16r04;	# ^D EOF

# Transcript lines kept
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

# Theme colours resolved to #rrggbbff strings for Tk
c_bg:	string;
c_fg:	string;
c_dim:	string;
c_hold:	string;
c_sel:	string;
c_prompt: string;

SHFONT: con "/fonts/combined/unicode.14.font";

# Shell I/O
rawon: int;			# written only by rawstateforwarder; reads are word-atomic in Dis
rawlock: chan of int;
shpgrp: int;		# the shell's process group: its commands are in it

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
	softkbd = load Softkbd Softkbd->PATH;
	if(softkbd != nil && softkbd->init() != nil)
		softkbd = nil;

	# Get working directory
	workdir = load Workdir Workdir->PATH;
	if(workdir != nil)
		cwd = workdir->init();
	if(cwd == nil || cwd == "")
		cwd = "/";

	# Initialize state
	rawon = 0;
	rawlock = chan[1] of int;
	rawlock <-= 1;
	snarfbuf = "";
	history = array[MAXHIST] of string;
	nhist = 0;
	histpos = -1;
	holding = 0;
	scrolling = 1;
	plumbed = 0;
	buttons = array[MAXBUTTONS] of ref Button;
	nbuttons = 0;
	shctlch = chan[8] of string;

	outputch = chan[32] of string;
	intrch = chan[1] of int;
	restartch = chan[1] of int;
	# keys sent wait here, not for the console server
	sendbyteschan = chan[64] of array of byte;

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

	refresh(1);

	# Periodic state writer
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
		if(c == "exit")
			quit();
		tkclient->wmctl(top, c);
		if(c != nil && len c > 0 && c[0] == '!')
			refresh(1);
	key := <-top.ctxt.kbd =>
		handlekey(key);
		shellstatedirty = 1;
		refresh(1);
	p := <-top.ctxt.ptr =>
		# Tk owns mouse positioning / selection
		tk->pointer(top, *p);
		updatestatus();
	a := <-actch =>
		handleaction(a);
		shellstatedirty = 1;
		refresh(1);
	<-ticks =>
		writeshellstate();
	output := <-outputch =>
		if(holding) {
			holdqueue = output :: holdqueue;
		} else {
			# the end stays in view if it was in it
			seeend := scrolling && endvisible();
			appendoutput(output);
			if(seeend)
				t("see end");
			shellstatedirty = 1;
			refresh(0);
		}
	cmd := <-shctlch =>
		handleshctl(cmd);
		refresh(0);
	<-themech =>
		reloadcolors();
		refresh(0);
	}
}

updatetitle()
{
	title := "Shell " + cwd;
	if(holding)
		title += " (holding)";
	tkclient->settitle(top, title);
}

# Kill the shell and its commands, then this.
quit()
{
	if(shpgrp > 0)
		postnote(1, shpgrp, "kill");
	postnote(1, sys->pctl(0, nil), "kill");
	exit;
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
	"cut" =>	docut();
	"snarf" =>	dosnarf();
	"paste" =>	dopaste();
	"send" =>	dosend();
	"plumb" =>	doplumb();
	"scroll" =>	scrolling = !scrolling;
	"clear" =>	clearscreen();
	"exit" =>	quit();
	"btn" =>
		if(tl toks != nil){
			i := int hd tl toks;
			if(i >= 0 && i < nbuttons){
				s := buttons[i].cmd;
				if(len s > 0 && s[len s-1] != '\n')
					s += "\n";
				typeinput(s);
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
		# output goes in at outpoint, before what is being typed
		".main.t mark set outpoint 1.0",
		".main.t mark gravity outpoint left",
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

# a command to the text widget
t(c: string): string
{
	return tk->cmd(top, ".main.t " + c);
}

# ---------- The view ----------

# After an event: the cursor in view if see, the button bar and status
# bar made current.
refresh(see: int)
{
	if(top == nil)
		return;
	if(see)
		t("see insert");
	recalcvis();
	rebuildbuttons();
	updatestatus();
	tk->cmd(top, "update");
	reportcaret();
}

# Tell the soft keyboard where the caret is, so a phone slides the
# prompt line above the keyboard: not the whole window (a fresh
# shell's prompt is at the top and slid off-screen), and not nothing
# (a long transcript's prompt is at the bottom, under the keyboard).
# A no-op without a soft keyboard.
reportcaret()
{
	if(softkbd == nil)
		return;
	(n, b) := sys->tokenize(t("bbox insert"), " ");
	if(n != 4)
		return;
	x := int hd b; b = tl b;
	y := int hd b; b = tl b;
	h := int hd tl b;
	x += int tk->cmd(top, ".main cget -actx") + int tk->cmd(top, ".main.t cget -actx");
	y += int tk->cmd(top, ".main cget -acty") + int tk->cmd(top, ".main.t cget -acty");
	o := top.screenr.min;
	w := int tk->cmd(top, ".main.t cget -actwidth");
	softkbd->set_rect(o.x + x, o.y + y, w, h);
}

endvisible(): int
{
	if(t("compare end == 1.0") == "1")
		return 1;
	return t("bbox {end -1c}") != "";
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

nlines(): int
{
	(l, nil) := splitdot(t("index end"));
	return int l;
}

splitdot(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '.')
			return (s[:i], s[i+1:]);
	return (s, "0");
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
	status := sys->sprint("Shell (%s)  %d lines", mode, nlines());
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

# ---------- Selection, snarf and plumbing ----------

selrange(): (string, string)
{
	(n, l) := sys->tokenize(t("tag ranges sel"), " ");
	if(n < 2)
		return (nil, nil);
	return (hd l, hd tl l);
}

getseltext(): string
{
	(a, b) := selrange();
	if(a == nil)
		return "";
	return t("get " + a + " " + b);
}

# Before the input, the transcript: the input is what is from outpoint on.
ininput(ix: string): int
{
	return t("compare " + ix + " >= outpoint") == "1";
}

snarfget(): string
{
	s := tkclient->snarfget();
	if(s != "")
		snarfbuf = s;
	return snarfbuf;
}

# Cut takes a selection out of the input; out of the transcript it is a
# snarf (what was said stays said).
docut()
{
	dosnarf();
	(a, b) := selrange();
	if(a != nil && ininput(a))
		t("delete " + a + " " + b);
	t("tag remove sel 1.0 end");
}

dosnarf()
{
	s := getseltext();
	if(s != "") {
		snarfbuf = s;
		tkclient->snarfput(s);
	}
}

dopaste()
{
	s := snarfget();
	if(s != "")
		typeinput(s);
}

doplumb()
{
	# Plumb selected text, or the word at the cursor
	s := getseltext();
	if(s == "")
		s = wordatpos(t("get {insert linestart} {insert lineend}"),
			int splitdot(t("index insert")).t1);
	plumbtext(s);
}

dosend()
{
	# Plan 9 / Inferno convention: "send" sends the selected text
	# as input to the shell (select-and-execute idiom).
	# If there's no selection, fall back to snarf buffer.
	s := getseltext();
	if(s == "")
		s = snarfget();
	if(s == "")
		return;
	# Ensure it ends with newline so the shell executes it
	if(s[len s - 1] != '\n')
		s += "\n";
	t("tag remove sel 1.0 end");
	t("mark set insert end");
	typeinput(s);
}

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

	# Start the file servers for cons reads and writes, each on its
	# own: output waiting for the window never holds up input
	rawch := chan of int;
	spawn rawstateforwarder(rawch);
	spawn consreader(consio);
	spawn conswriter(consio);
	if(consctlio != nil)
		spawn consctlserver(consctlio, rawch);

	# Start the shctl server
	if(shctlio != nil)
		spawn shctlserver(shctlio);

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
	# here, with the console as its fds, a new shell when one is
	# wanted (restartch)
	pidc := chan of int;
	for(;;){
		spawn runshell(sh, ctxt, pidc);
		shpgrp = <-pidc;
		<-restartch;
		postnote(1, shpgrp, "kill");
	}
}

restartch: chan of int;

# The shell, in a process group of its own, so that an interrupt can
# kill what it runs and a quit all of it, and not this.
runshell(sh: Command, ctxt: ref Draw->Context, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	sh->init(ctxt, shellargv);
}

# The shell, at an interrupt that found nothing to kill and it not
# reading what is typed: between two commands, or stuck (a loop of its
# builtins, or waiting on what will not come), where only a new one
# answers.  (An open quote or brace is not that: sh is reading for its
# end.)  Stuck is so at two such interrupts, the second within STUCKMS
# and a half second after the first at least: sh waiting where it was
# (its stack the same), or computing at both, and at neither its
# output waiting for the window to take it (as in a flood of it, where
# the window is slow).  Between two commands, as when it runs what was
# typed ahead, it is neither, and a new shell would have lost what it
# had (its directory, its variables) for nothing.
Idle: adt {
	ms:	int;	# when
	stack:	string;
	busy:	int;	# computing: its stack not to be read
	output:	int;	# its output waiting
};
idle: ref Idle;
STUCKMS: con 10000;

stuck(a, b: ref Idle): int
{
	t := b.ms - a.ms;
	if(t < 500 || t > STUCKMS || a.output || b.output)
		return 0;
	if(a.busy || b.busy)
		return a.busy && b.busy;
	return b.stack == a.stack;
}

# A process's stack (/prog/n/stack), and whether it is computing: the
# stack of one ready to run is not to be read ("thread must be
# stopped"), so it is tried again while a tenth of a second passes,
# for one that only seemed so.  Nil and not computing: it is gone.
readstack(pid: int): (string, int)
{
	f := "/prog/" + string pid + "/stack";
	buf := array[8192] of byte;
	for(try := 0; try < 20; try++){
		fd := sys->open(f, Sys->OREAD);
		if(fd == nil)
			return (nil, 0);
		s := "";
		while((n := sys->read(fd, buf, len buf)) > 0)
			s += string buf[0:n];
		if(n == 0)
			return (s, 0);
		if(sys->sprint("%r") != "thread must be stopped")
			return (nil, 0);
		sys->sleep(5);
	}
	return (nil, 1);
}

newshell()
{
	idle = nil;
	output("shell: the shell did not answer: a new one is started\n");
	alt {
	restartch <-= 1 =>
		;
	* =>
		;
	}
	# what the old one was asked to read is dead now
	alt {
	intrch <-= 1 =>
		;
	* =>
		;
	}
}

# Interrupt: kill the commands the shell runs (the processes of its group
# running a command's module); it goes on to its next prompt.  Not those
# that are sh's own, running only sh and the libraries it uses: sh waits
# for a process it starts to say it has, and one killed before it does
# leaves sh waiting for ever; they end when the commands they run are
# killed.  (By the module a process is in now, a helper of sh globbing in
# Filepat looked like a command; a command reading in Bufio, like sh.)
# One computing, whose stack is not to be read, is a command: sh's own
# compute only a moment.
interrupt()
{
	if(shpgrp <= 0)
		return;
	alt {
	intrch <-= 1 =>
		;
	* =>
		;
	}
	(shstack, shbusy) := readstack(shpgrp);
	shmp := shdata(shstack);
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return;
	nkilled := 0;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			pid := int d[i].name;
			if(pid == shpgrp || pid <= 0)
				continue;
			(nf, f) := sys->tokenize(readfile("/prog/" + d[i].name + "/status"), " ");
			if(nf < 2 || int hd tl f != shpgrp)
				continue;
			(stack, busy) := readstack(pid);
			if(busy || iscommand(stack, shmp)){
				postnote(0, pid, "kill");
				nkilled++;
			}
		}
	}
	if(nkilled > 0 || reading(shstack)){
		idle = nil;
		return;
	}
	if(shstack == nil && !shbusy){	# gone, or not to be read
		idle = nil;
		return;
	}
	now := ref Idle(sys->millisec(), shstack, shbusy, outputting);
	if(idle != nil && stuck(idle, now))
		newshell();
	else
		idle = now;
}

# A read of /dev/cons waiting: its count, where the bytes go, and
# whether its reader may have been killed since it asked.
Rdreq: adt {
	nbytes:	int;
	rc:	Sys->Rread;
	stale:	int;
};

intrch: chan of int;	# an interrupt was made: the reads waiting may be dead

# sh, and the libraries it uses, in the frames of a process's stack
shmods := array[] of {
	"/dis/lib/bufio.dis", "/dis/lib/string.dis",
	"/dis/lib/filepat.dis", "/dis/lib/readdir.dis", "/dis/lib/env.dis",
};

# Whether a process, by its stack (/prog/n/stack: a frame a line, "fp
# pc mp ... path"), runs a command: has a frame neither the shell's (sh's
# own with its module data shmp: another sh is a command too), nor of a
# library sh uses, nor of sh's builtins (/dis/sh/), nor built in ($Sys).
iscommand(stack, shmp: string): int
{
	(nil, lines) := sys->tokenize(stack, "\n");
	for(; lines != nil; lines = tl lines){
		(n, w) := sys->tokenize(hd lines, " \t");
		if(n < 4)
			continue;
		mp := hd tl tl w;
		for(; tl w != nil; w = tl w)
			;
		path := hd w;
		if(path == "" || path[0] == '$' || len path > 8 && path[0:8] == "/dis/sh/")
			continue;
		if(path == "/dis/sh.dis"){
			if(shmp != nil && mp != shmp)
				return 1;
			continue;
		}
		for(i := 0; i < len shmods && path != shmods[i]; i++)
			;
		if(i == len shmods)
			return 1;
	}
	return 0;
}

# Whether sh, by its stack, is reading what is typed: its frame on top,
# the system's aside, is Bufio's (sh's lexer reads through it).
reading(stack: string): int
{
	(nil, lines) := sys->tokenize(stack, "\n");
	for(; lines != nil; lines = tl lines){
		(n, w) := sys->tokenize(hd lines, " \t");
		if(n < 4)
			continue;
		for(; tl w != nil; w = tl w)
			;
		if(hd w == "" || (hd w)[0] == '$')
			continue;
		return hd w == "/dis/lib/bufio.dis";
	}
	return 0;
}

# The module data of the shell's sh, from its stack: its frames' in
# sh.dis.
shdata(stack: string): string
{
	(nil, lines) := sys->tokenize(stack, "\n");
	for(; lines != nil; lines = tl lines){
		(n, w) := sys->tokenize(hd lines, " \t");
		if(n < 4)
			continue;
		mp := hd tl tl w;
		for(; tl w != nil; w = tl w)
			;
		if(hd w == "/dis/sh.dis")
			return mp;
	}
	return nil;
}

# consreader: services reads of the synthetic /dev/cons: the shell has
# the keyboard's bytes in the order they were sent, a read taking no
# more than it asks for and leaving the rest for the next.
consreader(consio: ref Sys->FileIO)
{
	rdqueue: list of ref Rdreq;	# the oldest first
	pending := array[0] of byte;

	for(;;) alt {
	(nil, nbytes, nil, rc) := <-consio.read =>
		if(rc == nil)
			continue;
		rdqueue = append(rdqueue, ref Rdreq(nbytes, rc, 0));
		pending = satisfy(rdqueue, pending);
		rdqueue = unsatisfied;

	ibytes := <-sendbyteschan =>
		b := array[len pending + len ibytes] of byte;
		b[0:] = pending;
		b[len pending:] = ibytes;
		pending = satisfy(rdqueue, b);
		rdqueue = unsatisfied;

	<-intrch =>
		for(l := rdqueue; l != nil; l = tl l)
			(hd l).stale = 1;
	}
}

unsatisfied: list of ref Rdreq;

# Answer the reads waiting, the oldest first, while there are bytes;
# the bytes left, and the reads left in unsatisfied.  A read whose
# reader was killed (a command reading the console, interrupted) is
# not given what was typed for the next.
satisfy(rds: list of ref Rdreq, b: array of byte): array of byte
{
	for(; rds != nil && len b > 0; rds = tl rds) {
		r := hd rds;
		nb := r.nbytes;
		if(nb > len b)
			nb = len b;
		r.rc <-= (b[0:nb], nil);
		# the reply channel holds one: a reader waiting on it takes
		# the bytes at once and it has room again; a dead one's
		# keeps them
		if(r.stale){
			alt {
			r.rc <-= (nil, nil) =>
				;
			* =>
				continue;
			}
		}
		b = b[nb:];
	}
	unsatisfied = rds;
	return b;
}

append(l: list of ref Rdreq, r: ref Rdreq): list of ref Rdreq
{
	if(l == nil)
		return r :: nil;
	return hd l :: append(tl l, r);
}

# conswriter: services writes of the synthetic /dev/cons, the shell's
# output; a character split between two writes waits for its end.
conswriter(consio: ref Sys->FileIO)
{
	part := array[0] of byte;
	for(;;) {
		(nil, data, nil, wc) := <-consio.write;
		if(wc == nil)
			continue;
		wc <-= (len data, nil);
		if(len part > 0){
			b := array[len part + len data] of byte;
			b[0:] = part;
			b[len part:] = data;
			data = b;
		}
		n := sys->utfbytes(data, len data);
		part = data[n:];
		if(n > 0){
			outputting++;
			outputch <-= string data[0:n];
			outputting--;
		}
	}
}

# output written that the window has yet to take: the next write waits
outputting := 0;

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
	sendbyteschan <-= array of byte s;
}

# ---------- Input ----------

# Put s into the input where the cursor is (at its end if the cursor is
# in the transcript), and send the lines it ends.
typeinput(s: string)
{
	if(!ininput("insert"))
		t("mark set insert end");
	typeat(s);
	sendlines();
}

# Send each whole line of the input, the first first, taking it into
# the transcript: output from then on goes in after it.
sendlines()
{
	for(;;){
		input := t("get outpoint end");
		for(i := 0; i < len input && input[i] != '\n'; i++)
			;
		if(i == len input)
			return;
		line := input[0:i];
		if(line != "")
			addhistory(line);
		histpos = -1;
		t(sys->sprint("mark set outpoint {outpoint +%dc}", i + 1));
		sendinput(line + "\n");
	}
}

# The input, all of it, replaced by s.
setinput(s: string)
{
	t("delete outpoint end");
	t("insert end " + tk->quote(s));
	t("mark set insert end");
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
			setinput("");
			output("^C\n");
			interrupt();
		4 =>	# Ctrl-D: EOF
			if(t("get outpoint end") == "") {
				s := "";
				s[0] = Keof_char;
				sendinput(s);
			}
		12 =>	# Ctrl-L: clear
			clearscreen();
		17 =>	# Ctrl-Q: quit
			quit();
		21 =>	# Ctrl-U: clear input line
			setinput("");
		14 =>	# Ctrl-N: next history
			if(histpos >= 0) {
				histpos++;
				if(histpos >= nhist) {
					histpos = -1;
					setinput("");
				} else
					setinput(history[histpos]);
			}
		16 =>	# Ctrl-P: previous history
			if(nhist > 0) {
				if(histpos < 0)
					histpos = nhist;
				if(histpos > 0) {
					histpos--;
					setinput(history[histpos]);
				}
			}
		23 =>	# Ctrl-W: delete word before cursor
			if(!ininput("insert"))
				t("mark set insert end");
			line := t("get outpoint insert");
			j := len line;
			# Skip whitespace backwards
			while(j > 0 && isspace(line[j-1]))
				j--;
			# Skip non-whitespace backwards
			while(j > 0 && !isspace(line[j-1]))
				j--;
			t(sys->sprint("delete {outpoint +%dc} insert", j));
		}
		return;
	}

	case key {
	'\n' =>
		if(!ininput("insert")) {
			# Cursor on transcript line: send that line (Plan 9 idiom)
			setinput(t("get {insert linestart} {insert lineend}"));
		}
		t("mark set insert end");
		typeinput("\n");
	Kbs =>
		# not into the transcript's line before, nor out of the input
		if(ininput("insert")) {
			if(t("compare insert > outpoint") == "1")
				t("delete insert-1c insert");
		} else if(t("compare insert > {insert linestart}") == "1")
			t("delete insert-1c insert");
	Kdel =>
		if(t("compare insert < {insert lineend}") == "1" || ininput("insert"))
			t("delete insert insert+1c");
	Kleft =>
		move("insert-1c");
	Kright =>
		move("insert+1c");
	Khome =>
		if(ininput("insert"))
			move("outpoint");
		else
			move("insert linestart");
	Kend =>
		move("insert lineend");
	Kup =>
		move("insert-1l");
	Kdown =>
		move("insert+1l");
	Kpgup =>
		t("yview scroll -1 page");
	Kpgdown =>
		t("yview scroll 1 page");
	Kesc =>
		# Toggle hold mode
		holding = !holding;
		if(!holding)
			flushholdqueue();
		updatetitle();
	* =>
		if(key >= 16r20 || key == '\t') {
			s := "";
			s[0] = key;
			# in the transcript, edit it in place (Plan 9 style)
			typeat(s);
		}
	}
}

# s typed at the cursor, which goes after it.  (The widget does not
# always move its insert mark past text put where it is.)
typeat(s: string)
{
	ix := t("index insert");
	t("insert " + ix + " " + tk->quote(s));
	t(sys->sprint("mark set insert {%s +%dc}", ix, len s));
}

move(ix: string)
{
	t("mark set insert {" + ix + "}");
	t("tag remove sel 1.0 end");
}

# ---------- Hold mode ----------

flushholdqueue()
{
	# Reverse the queue (it was built in reverse order)
	rev: list of string;
	for(q := holdqueue; q != nil; q = tl q)
		rev = (hd q) :: rev;
	holdqueue = nil;
	for(; rev != nil; rev = tl rev)
		appendoutput(hd rev);
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

# Text into the transcript, at outpoint, before what is being typed.
output(s: string)
{
	if(s == "")
		return;
	# the cursor where the input begins stays there, after the output
	atout := t("compare insert == outpoint") == "1";
	t("insert outpoint " + tk->quote(s));
	t(sys->sprint("mark set outpoint {outpoint +%dc}", len s));
	if(atout)
		t("mark set insert outpoint");
	# a line not ended is a prompt (or a question): dim it
	if(s[len s - 1] != '\n')
		t("tag add prompt {outpoint linestart} outpoint");
}

# The shell's output: what a terminal would do with \r, \b, a tab and
# an escape sequence, done; the rest into the transcript.
appendoutput(s: string)
{
	o := "";
	for(i := 0; i < len s; i++) {
		c := s[i];
		case c {
		'\r' =>
			# Carriage return — the line begins again; \r\n is \n
			if(i + 1 < len s && s[i+1] == '\n')
				continue;
			output(o);
			o = "";
			t("delete {outpoint linestart} outpoint");
		'\b' =>
			if(o != "" && o[len o - 1] != '\n')
				o = o[0:len o - 1];
			else if(o == "") {
				if(t("compare outpoint > {outpoint linestart}") == "1")
					t("delete outpoint-1c outpoint");
			}
		'\t' =>
			col := len o;
			for(j := len o - 1; j >= 0; j--)
				if(o[j] == '\n'){
					col = len o - j - 1;
					break;
				}
			if(j < 0)
				col += len t("get {outpoint linestart} outpoint");
			for(k := TABSTOP - col % TABSTOP; k > 0; k--)
				o[len o] = ' ';
		16r1B =>
			# ANSI escape — skip the sequence
			i++;
			if(i < len s && s[i] == '[') {
				i++;
				while(i < len s &&
				    !((s[i] >= 'A' && s[i] <= 'Z') ||
				      (s[i] >= 'a' && s[i] <= 'z')))
					i++;
			}
		0 =>
			# NUL → replacement character
			o[len o] = '□';
		* =>
			if(c >= 16r20 || c == '\n')
				o[len o] = c;
		}
	}
	output(o);
	trimtranscript();
}

# No more than MAXLINES lines: past it, the oldest go, to TRIMLINES.
trimtranscript()
{
	n := nlines();
	if(n <= MAXLINES)
		return;
	(ol, nil) := splitdot(t("index outpoint"));
	drop := n - TRIMLINES;
	if(drop >= int ol)
		drop = int ol - 1;
	if(drop > 0)
		t(sys->sprint("delete 1.0 %d.0", drop + 1));
}

# The transcript cleared to the prompt, the input kept.
clearscreen()
{
	t("delete 1.0 {outpoint linestart}");
}

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
	writestatefile(SHELL_DIR + "/body", t("get 1.0 outpoint"));
	# Write current input line
	writestatefile(SHELL_DIR + "/input", t("get outpoint end"));
	shellstatedirty = 0;
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

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
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
