implement Shell;

#
# wm/shell - the Inferno shell in a window
#
# wm/sh's terminal: the shell reads and writes a /dev/cons and
# /dev/consctl of the window's own, served here with file2chan, and
# the window's text is the transcript.  What programs print goes in
# at the mark outpoint; what is typed after it is the input, sent a
# line at a time (cooked) or a key at a time (raw, after "rawon" on
# /dev/consctl).  Usage and behaviour are wm/sh's; to them it adds
# the theme's colours as Xenith's body takes them and the theme's
# font (following a theme switch), a history of the lines sent, the
# caret kept in sight of a soft keyboard, and the transcript served and
# posted as #sshell/fs (appfs(2); tools9p mounts it at /mnt/shell for
# Veltro's shell tool), read from the window as it is now:
#
#	body	the transcript up to outpoint
#	input	what is typed and not yet read
#	event	a read waits for the next change ("changed")
#
# Keyboard, in cooked mode (in raw mode each key goes to the program):
#	Enter	send the line	^D	end of file (sends what is typed)
#	^H	erase a char	^U	erase the line	^W	erase a word
#	^C	discard what is typed and not yet sent
#	^P ^N	the previous, the next line sent
#	^L	clear the transcript above the line being written
#	ESC	hold: nothing typed is sent until ESC again
# and the text's own: arrows, Home, End, Page Up and Down, ^A ^E ^B ^F ^K.
#
# Mouse: button 1 selects; button 2 is the menu (noscroll, cut, paste,
# snarf, send); button 3 plumbs the selection or the word under it.
# Button 1 held, 2 cuts; button 1 held, 3 pastes.
#
# /chan/shctl: "button label text" and "action label text" add a
# button sending text as input or as an event read from shctl;
# "clear" removes them; "cwd dir" sets the directory in the title.
#

include "sys.m";
	sys: Sys;
	FileIO: import sys;

include "draw.m";
	draw: Draw;
	Context: import draw;

include "tk.m";
	tk: Tk;

include "keyboard.m";

include "tkclient.m";
	tkclient: Tkclient;

include	"plumbmsg.m";
	plumbmsg: Plumbmsg;
	Msg: import plumbmsg;

include "workdir.m";

include "string.m";
	str: String;

include "arg.m";

include "sh.m";

include "lucitheme.m";

include "softkbd.m";
include "appfs.m";
	softkbd: Softkbd;

Shell: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

ETX:		con 3;		# ^c discard input
EOT:		con 4;		# ^d end of file
FF:		con 12;		# ^l clear the transcript
SO:		con 14;		# ^n next line sent
DLE:		con 16;		# ^p previous line sent
BSL:		con 21;		# ^u backspace line
BSW:		con 23;		# ^w backspace word
ESC:		con 27;		# hold mode

# XXX line-based limits are inadequate - memory is still
# blown if a client writes a very long line.
HIWAT:	con 2000;	# maximum number of lines in transcript
LOWAT:	con 1500;	# amount to reduce to after high water

MAXHIST:	con 100;	# lines kept for ^p and ^n

Name:	con "Shell";
SHFONT:	con "/fonts/combined/unicode.14.font";

Rdreq: adt
{
	off:	int;
	nbytes:	int;
	fid:	int;
	rc:	chan of (array of byte, string);
};

shwin_cfg := array[] of {
	"menu .m",
	".m add command -text noscroll -command {send edit noscroll}",
	".m add command -text cut -command {send edit cut}",
	".m add command -text paste -command {send edit paste}",
	".m add command -text snarf -command {send edit snarf}",
	".m add command -text send -command {send edit send}",
	"frame .b -bd 1 -relief ridge",
	"frame .ft -bd 0",
	"scrollbar .ft.scroll -command {send scroll t}",
	"text .ft.t -bd 1 -relief flat -yscrollcommand {send scroll s}",
	".ft.t tag configure sel -relief flat",
	"pack .ft.scroll -side left -fill y",
	"pack .ft.t -fill both -expand 1",
	"pack .ft -fill both -expand 1",
	"focus .ft.t",
	"bind .ft.t <Key> {send keys {%A}}",
	"bind .ft.t <Control-d> {send keys {%A}}",
	"bind .ft.t <Control-h> {send keys {%A}}",
	"bind .ft.t <Control-w> {send keys {%A}}",
	"bind .ft.t <Control-u> {send keys {%A}}",
	"bind .ft.t <Control-p> {send keys {%A}}",
	"bind .ft.t <Control-n> {send keys {%A}}",
	"bind .ft.t <Button-1> +{send but1 pressed}",
	"bind .ft.t <Double-Button-1> +{send but1 pressed}",
	"bind .ft.t <ButtonRelease-1> +{send but1 released}",
	"bind .ft.t <ButtonPress-2> {send but2 %X %Y}",
	"bind .ft.t <Motion-Button-2-Button-1> {}",
	"bind .ft.t <Motion-ButtonPress-2> {}",
	"bind .ft.t <ButtonPress-3> {send but3 pressed}",
	"bind .ft.t <ButtonRelease-3> {send but3 released %x %y}",
	"bind .ft.t <Motion-Button-3> {}",
	"bind .ft.t <Motion-Button-3-Button-1> {}",
	"bind .ft.t <Double-Button-3> {}",
	"bind .ft.t <Double-ButtonRelease-3> {}",
};

rdreq: list of Rdreq;
menuindex := "0";
holding := 0;
plumbed := 0;
rawon := 0;
rawinput := "";
scrolling := 1;
partialread: array of byte;
cwd := "";
width := "640";
height := "480";
font := SHFONT;

events: list of string;
evrdreq: list of Rdreq;
winname: string;

history := array[MAXHIST] of string;
nhist := 0;
histpos := -1;

# the theme's colours, as Tk takes them
c_bg, c_fg, c_hold, c_sel: string;

lastcaret := "";
themepgrp := -1;

badmod(p: string)
{
	sys->fprint(sys->fildes(2), "wm/shell: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

init(ctxt: ref Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;

	tkclient = load Tkclient Tkclient->PATH;
	if (tkclient == nil)
		badmod(Tkclient->PATH);

	str = load String String->PATH;
	if (str == nil)
		badmod(String->PATH);

	arg := load Arg Arg->PATH;
	if (arg == nil)
		badmod(Arg->PATH);
	arg->init(argv);

	plumbmsg = load Plumbmsg Plumbmsg->PATH;

	sys->pctl(Sys->FORKNS | Sys->NEWPGRP | Sys->FORKENV, nil);

	tkclient->init();
	if (ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		sys->fprint(sys->fildes(2), "wm/shell: no window context\n");
		raise "fail:bad context";
	}

	if(plumbmsg != nil && plumbmsg->init(1, nil, 0) >= 0)
		plumbed = 1;
	workdir := load Workdir Workdir->PATH;
	if(workdir != nil)
		cwd = workdir->init();

	softkbd = load Softkbd Softkbd->PATH;
	if(softkbd != nil && softkbd->init() != nil)
		softkbd = nil;

	shargs: list of string;
	while ((opt := arg->opt()) != 0) {
		case opt {
		'w' =>
			width = arg->arg();
		'h' =>
			height = arg->arg();
		'f' =>
			font = arg->arg();
			if (font != nil && font[0] != '/' && (len font == 1 || font[0:2] != "./"))
				font = "/fonts/" + font;
		'c' =>
			a := arg->arg();
			if (a == nil)
				usage();
			shargs = a :: "-c" :: shargs;
		'i' or 'l' or 'x' or 'v' or 'n' =>
			shargs = sys->sprint("-%c", opt) :: shargs;
		* =>
			usage();
		}
	}
	argv = arg->argv();
	for (; shargs != nil; shargs = tl shargs)
		argv = hd shargs :: argv;

	winname = Name + " " + cwd;

	spawn main(ctxt, argv);
}

usage()
{
	sys->fprint(sys->fildes(2), "usage: wm/shell [-ilxvn] [-w width] [-h height] [-f font] [-c command] [file [args...]]\n");
	raise "fail:usage";
}

atend(t: ref Tk->Toplevel, w: string): int
{
	s := cmd(t, w+" yview");
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			break;
	return i == len s - 2 && s[i+1] == '1';
}

main(ctxt: ref Draw->Context, argv: list of string)
{
	(t, titlectl) := tkclient->toplevel(ctxt, "-width " + width + " -height " + height,
		winname, Tkclient->Appl);
	wm := t.ctxt;

	edit := chan of string;
	tk->namechan(t, edit, "edit");

	keys := chan of string;
	tk->namechan(t, keys, "keys");

	butcmd := chan of string;
	tk->namechan(t, butcmd, "button");

	event := chan of string;
	tk->namechan(t, event, "action");

	scroll := chan of string;
	tk->namechan(t, scroll, "scroll");

	but1 := chan of string;
	tk->namechan(t, but1, "but1");
	but2 := chan of string;
	tk->namechan(t, but2, "but2");
	but3 := chan of string;
	tk->namechan(t, but3, "but3");
	button1 := 0;
	button3 := 0;

	for (i := 0; i < len shwin_cfg; i++)
		cmd(t, shwin_cfg[i]);
	(menuw, nil) := itemsize(t, ".m");
	cmd(t, ".ft.t configure -font " + font);
	loadcolors();
	setcols(t);
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "ptr" :: "kbd" :: nil);

	themech := chan of int;
	tpid := chan of int;
	spawn themelistener(themech, tpid);
	themepgrp = <-tpid;
	appreqs := chan of ref Appfs->Req;
	startfs(appreqs);

	ioc := chan of (int, ref FileIO, ref FileIO, string, ref FileIO);
	spawn newsh(ctxt, ioc, argv);

	(nil, file, filectl, consfile, shctl) := <-ioc;
	if(file == nil || filectl == nil || shctl == nil) {
		sys->fprint(sys->fildes(2), "wm/shell: shell cons creation failed\n");
		gone();
	}
	dummyfwrite := chan of (int, array of byte, int, Sys->Rwrite);
	fwrite := file.write;

	rdrpc: Rdreq;

	# outpoint is place in text to insert characters printed by programs
	cmd(t, ".ft.t mark set outpoint 1.0; .ft.t mark gravity outpoint left");

	for(;;) alt {
	c := <-wm.kbd =>
		tk->keyboard(t, c);
	m := <-wm.ptr =>
		tk->pointer(t, *m);
		if(m.buttons)
			reportcaret(t);
	c := <-wm.ctl or
	c = <-t.wreq or
	c = <-titlectl =>
		tkclient->wmctl(t, c);
	<-themech =>
		loadcolors();
		tkclient->wmctl(t, "retheme");
		setcols(t);
		cmd(t, "update");
	r := <-appreqs =>
		shellrequest(t, r);
	ecmd := <-edit =>
		editor(t, ecmd);
		sendinput(t);
		statechanged();

	c := <-keys =>
		char := c[1];
		if(char == '\\')
			char = c[2];
		# a key that is not a character (an arrow, a function key)
		# goes to a program reading raw, and otherwise types nothing
		spec := char >= Keyboard->Spec && char <= Keyboard->Specend;
		if(char != ESC && !spec)
			cut(t, 1);
		if(rawon){
			if(int cmd(t, ".ft.t compare insert >= outpoint")){
				rawinput[len rawinput] = char;
				sendinput(t);
				break;
			}
		}
		if(spec)
			break;
		case char {
		* =>
			cmd(t, ".ft.t insert insert "+c);
		'\n' =>
			addhistory(t);
			cmd(t, ".ft.t insert insert "+c);
			sendinput(t);
		EOT =>
			cmd(t, ".ft.t insert insert "+c);
			sendinput(t);
		'\b' =>
			cmd(t, ".ft.t tkTextDelIns -c");
		BSL =>
			cmd(t, ".ft.t tkTextDelIns -l");
		BSW =>
			cmd(t, ".ft.t tkTextDelIns -w");
		ETX =>
			cmd(t, ".ft.t delete outpoint end; .ft.t mark set insert end");
			histpos = -1;
		FF =>
			cmd(t, ".ft.t delete 1.0 {outpoint linestart}");
		DLE =>
			if(nhist > 0){
				if(histpos < 0)
					histpos = nhist;
				if(histpos > 0)
					setinputline(t, history[--histpos]);
			}
		SO =>
			if(histpos >= 0){
				if(++histpos >= nhist){
					histpos = -1;
					setinputline(t, "");
				}else
					setinputline(t, history[histpos]);
			}
		ESC =>
			setholding(t, !holding);
		}
		cmd(t, ".ft.t see insert;update");
		reportcaret(t);
		statechanged();

	c := <-but1 =>
		button1 = (c == "pressed");
		button3 = 0;	# abort any pending button 3 action

	c := <-but2 =>
		if(button1){
			cut(t, 1);
			cmd(t, "update");
			break;
		}
		(nil, l) := sys->tokenize(c, " ");
		x := int hd l - menuw/2;
		y := int hd tl l - int cmd(t, ".m yposition "+menuindex) - 10;
		cmd(t, ".m activate "+menuindex+"; .m post "+string x+" "+string y+
			"; update");
		button3 = 0;	# abort any pending button 3 action

	c := <-but3 =>
		if(c == "pressed"){
			button3 = 1;
			if(button1){
				paste(t);
				sendinput(t);
				cmd(t, "update");
			}
			break;
		}
		if(plumbed == 0 || button3 == 0 || button1 != 0)
			break;
		button3 = 0;
		# plumb message triggered by release of button 3
		(nil, l) := sys->tokenize(c, " ");
		x := int hd tl l;
		y := int hd tl tl l;
		plumbat(t, ".ft.t index @"+string x+","+string y);
	c := <-butcmd =>
		simulatetype(t, tkunquote(c));
		sendinput(t);
		cmd(t, "update");
	c := <-event =>
		events = str->append(tkunquote(c), events);
		if (evrdreq != nil) {
			rc := (hd evrdreq).rc;
			rc <-= (array of byte hd events, nil);
			evrdreq = tl evrdreq;
			events = tl events;
		}
	rdrpc = <-shctl.read =>
		if(rdrpc.rc == nil)
			continue;
		if (events != nil) {
			rdrpc.rc <-= (array of byte hd events, nil);
			events = tl events;
		} else
			evrdreq = rdrpc :: evrdreq;
	(nil, data, nil, wc) := <-shctl.write =>
		if (wc == nil)
			break;
		if ((err := shctlcmd(t, string data)) != nil)
			wc <-= (0, err);
		else
			wc <-= (len data, nil);
	rdrpc = <-filectl.read =>
		if(rdrpc.rc == nil)
			continue;
		rdrpc.rc <-= (nil, "not allowed");
	(nil, data, nil, wc) := <-filectl.write =>
		if(wc == nil) {
			# consctl closed - revert to cooked mode
			# XXX should revert only on *last* close?
			rawon = 0;
			continue;
		}
		(nc, cmdlst) := sys->tokenize(string data, " \n");
		if(nc == 1) {
			case hd cmdlst {
			"rawon" =>
				rawon = 1;
				rawinput = "";
				# discard previous input
				advance := string (len tk->cmd(t, ".ft.t get outpoint end") +1);
				cmd(t, ".ft.t mark set outpoint outpoint+" + advance + "chars");
				partialread = nil;
			"rawoff" =>
				rawon = 0;
				partialread = nil;
			"holdon" =>
				setholding(t, 1);
				cmd(t, "update");
			"holdoff" =>
				setholding(t, 0);
				cmd(t, "update");
			* =>
				wc <-= (0, "unknown consctl request");
				continue;
			}
			wc <-= (len data, nil);
			continue;
		}
		wc <-= (0, "unknown consctl request");

	rdrpc = <-file.read =>
		if(rdrpc.rc == nil) {
			(ok, nil) := sys->stat(consfile);
			if (ok < 0)
				gone();
			continue;
		}
		append(rdrpc);
		sendinput(t);
		statechanged();

	c := <-scroll =>
		if(c[0] == 't'){
			cmd(t, ".ft.t yview "+c[1:]+";update");
			if(scrolling)
				fwrite = file.write;
			else if(atend(t, ".ft.t"))
				fwrite = file.write;
			else
				fwrite = dummyfwrite;
		}else{
			cmd(t, ".ft.scroll set "+c[1:]+";update");
			if(atend(t, ".ft.t") && fwrite == dummyfwrite)
				fwrite = file.write;
		}
	(nil, data, nil, wc) := <-fwrite =>
		if(wc == nil) {
			(ok, nil) := sys->stat(consfile);
			if (ok < 0)
				gone();
			continue;
		}
		needscroll := atend(t, ".ft.t");
		cdata := cursorcontrol(t, string data);
		ncdata := string len cdata + "chars;";
		cmd(t, ".ft.t insert outpoint '"+ cdata);
		wc <-= (len data, nil);
		data = nil;
		s := ".ft.t mark set outpoint outpoint+" + ncdata;
		if(!atend(t, ".ft.t") && scrolling == 0)
			fwrite = dummyfwrite;
		else if(needscroll)
			s += ".ft.t see outpoint;";
		s += "update";
		cmd(t, s);
		nlines := int cmd(t, ".ft.t index end");
		if(nlines > HIWAT){
			s = ".ft.t delete 1.0 "+ string (nlines-LOWAT) +".0;update";
			cmd(t, s);
		}
		reportcaret(t);
		statechanged();
	}
}

setholding(t: ref Tk->Toplevel, hold: int)
{
	if(hold == holding)
		return;
	holding = hold;
	if(!holding){
		tkclient->settitle(t, winname);
		sendinput(t);
	}else
		tkclient->settitle(t, winname+" (holding)");
	setcols(t);
}

# ---------- Colours ----------

col(v: int): string
{
	return sys->sprint("#%06xff", (v >> 8) & 16rFFFFFF);
}

loadcolors()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme == nil){
		(c_bg, c_fg, c_hold, c_sel) =
			("#FFFDF6FF", "#333333FF", "#000099FF", "#B4D5FEFF");
		return;
	}
	th := lucitheme->gettheme();
	c_bg = col(th.editbg);
	c_fg = col(th.edittext);
	c_hold = col(th.edithold);
	c_sel = col(th.menuhilit);
}

# The text in the theme's colours, as Xenith's body takes them: its
# text on its background, a selection in menuhilit with the text as
# it was, and no dimming without the keyboard; edithold while holding
# (Xenith has no hold).  The text widget is coloured here, not left to
# Tk's defaults, as Tk keeps colours an app sets through a switch.
setcols(t: ref Tk->Toplevel)
{
	fgcol := c_fg;
	if(holding)
		fgcol = c_hold;
	cmd(t, ". configure -background "+c_bg);
	cmd(t, ".ft.t configure -background "+c_bg+" -foreground "+fgcol+
		" -selectbackground "+c_sel+" -selectforeground "+fgcol);
	# the sel tag is what Tk draws a selection with, and it keeps the
	# colours it was made with (the first theme's accent) otherwise
	cmd(t, ".ft.t tag configure sel -background "+c_sel+" -foreground "+fgcol);
}

# The window is done: the shell has gone, and everything that held its
# /dev/cons.  The theme's watchers go with it.
gone()
{
	fd := sys->open("/prog/"+string themepgrp+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	exit;
}

themelistener(c: chan of int, pid: chan of int)
{
	# a process group of its own, lucitheme's watcher in it too, for gone()
	pid <-= sys->pctl(Sys->NEWPGRP, nil);
	# any write of /lib/lucifer/theme/current, Lucifer or not (lucitheme->watch)
	lt := load Lucitheme Lucitheme->PATH;
	if(lt == nil)
		return;
	w := lt->watch();
	for(;;){
		<-w;
		c <-= 1;
	}
}

# ---------- History ----------

# Keep the line Enter sends: what is typed on the line before the
# caret, from outpoint if the line begins before it.
addhistory(t: ref Tk->Toplevel)
{
	histpos = -1;
	if(rawon || cmd(t, ".ft.t compare insert >= outpoint") != "1")
		return;
	start := "{insert linestart}";
	if(cmd(t, ".ft.t compare outpoint > {insert linestart}") == "1")
		start = "outpoint";
	line := tk->cmd(t, ".ft.t get "+start+" insert");
	if(line == nil || (nhist > 0 && history[nhist-1] == line))
		return;
	if(nhist == MAXHIST){
		history[0:] = history[1:];
		nhist--;
	}
	history[nhist++] = line;
}

# The line being typed (the last, from outpoint if it begins there)
# replaced by s.
setinputline(t: ref Tk->Toplevel, s: string)
{
	start := "{end linestart}";
	if(cmd(t, ".ft.t compare outpoint > {end linestart}") == "1")
		start = "outpoint";
	cmd(t, ".ft.t delete "+start+" end");
	cmd(t, ".ft.t insert end '"+s);
	cmd(t, ".ft.t mark set insert end");
}

# ---------- Soft keyboard and Veltro ----------

# Tell the soft keyboard where the caret is, so a phone slides the
# line being typed above the keyboard: not the whole window (a fresh
# shell's prompt is at the top and slid off-screen), and not nothing
# (a long transcript's prompt is at the bottom, under the keyboard).
# Only when the caret has moved; a no-op without a soft keyboard.
reportcaret(t: ref Tk->Toplevel)
{
	if(softkbd == nil)
		return;
	(n, b) := sys->tokenize(tk->cmd(t, ".ft.t bbox insert"), " ");
	if(n != 4)
		return;
	x := int hd b; b = tl b;
	y := int hd b; b = tl b;
	h := int hd tl b;
	x += int tk->cmd(t, ".ft cget -actx") + int tk->cmd(t, ".ft.t cget -actx");
	y += int tk->cmd(t, ".ft cget -acty") + int tk->cmd(t, ".ft.t cget -acty");
	o := t.screenr.min;
	w := int tk->cmd(t, ".ft.t cget -actwidth");
	caret := sys->sprint("%d %d %d %d", o.x+x, o.y+y, w, h);
	if(caret == lastcaret)
		return;
	lastcaret = caret;
	softkbd->set_rect(o.x + x, o.y + y, w, h);
}

appfs: Appfs;
appfstether: ref Sys->FD;	# the files go with it (appfs(2))

startfs(appreqs: chan of ref Appfs->Req)
{
	appfs = load Appfs Appfs->PATH;
	if(appfs == nil || appfs->init() != nil) {
		appfs = nil;
		return;
	}
	err: string;
	(nil, appfstether, err) = appfs->serve("shell", array[] of {"body", "input"}, appreqs);
	if(err != nil) {
		sys->fprint(sys->fildes(2), "wm/shell: serve: %s\n", err);
		appfs = nil;
	}
}

# The transcript changed: a reader of event is told.
statechanged()
{
	if(appfs != nil)
		appfs->event("changed");
}

# The transcript as it is, read; nothing is written there.
shellrequest(t: ref Tk->Toplevel, r: ref Appfs->Req)
{
	if(r.data != nil) {
		r.reply <-= "read-only";
		return;
	}
	case r.file {
	"body" =>
		r.reply <-= tk->cmd(t, ".ft.t get 1.0 outpoint");
	"input" =>
		r.reply <-= tk->cmd(t, ".ft.t get outpoint end");
	* =>
		r.reply <-= "";
	}
}

# ---------- Plumbing ----------

# Plumb the selection, if the click is in it, or the word around
# the click.
plumbat(t: ref Tk->Toplevel, at: string)
{
	index := cmd(t, at);
	selindex := cmd(t, ".ft.t tag ranges sel");
	insel := 0;
	if(selindex != "")
		insel = cmd(t, ".ft.t compare sel.first <= "+index)=="1" &&
			cmd(t, ".ft.t compare sel.last >= "+index)=="1";
	attr := "";
	text: string;
	if(insel)
		text = tk->cmd(t, ".ft.t get sel.first sel.last");
	else{
		# have line with text in it
		# now extract whitespace-bounded string around click
		(nil, w) := sys->tokenize(index, ".");
		charno := int hd tl w;
		left := cmd(t, ".ft.t index {"+index+" linestart}");
		right := cmd(t, ".ft.t index {"+index+" lineend}");
		line := tk->cmd(t, ".ft.t get "+left+" "+right);
		for(i:=charno; i>0; --i)
			if(line[i-1]==' ' || line[i-1]=='\t')
				break;
		for(j:=charno; j<len line; j++)
			if(line[j]==' ' || line[j]=='\t')
				break;
		text = line[i:j];
		attr = "click="+string (charno-i);
	}
	if(text == nil)
		return;
	msg := ref Msg(
		"WmSh",
		"",
		cwd,
		"text",
		attr,
		array of byte text);
	if(msg.send() < 0)
		sys->fprint(sys->fildes(2), "wm/shell: plumbing write error: %r\n");
}

tkunquote(s: string): string
{
	if (s == nil)
		return nil;
	t: string;
	if (s[0] != '{' || s[len s - 1] != '}')
		return s;
	for (i := 1; i < len s - 1; i++) {
		if (s[i] == '\\')
			i++;
		t[len t] = s[i];
	}
	return t;
}

buttonid := 0;
shctlcmd(win: ref Tk->Toplevel, c: string): string
{
	toks := str->unquoted(c);
	if (toks == nil)
		return "null command";
	n := len toks;
	case hd toks {
	"button" or
	"action"=>
		# (button|action) title sendtext
		if (n != 3)
			return "bad usage";
		id := ".b.b" + string buttonid++;
		cmd(win, "button " + id + " -text " + tk->quote(hd tl toks) +
				" -command 'send " + hd toks + " " + tk->quote(hd tl tl toks));
		cmd(win, "pack " + id + " -side left");
		# the bar is shown only while it has buttons
		if(buttonid == 1)
			cmd(win, "pack .b -side top -anchor w -fill x -before .ft");
	"clear" =>
		for (i := 0; i < buttonid; i++)
			cmd(win, "destroy .b.b" + string i);
		buttonid = 0;
		cmd(win, "pack forget .b");
	"cwd" =>
		if (n != 2)
			return "bad usage";
		cwd = hd tl toks;
		winname = Name + " " + cwd;
		if(holding)
			tkclient->settitle(win, winname+" (holding)");
		else
			tkclient->settitle(win, winname);
	* =>
		return "bad command";
	}
	cmd(win, "update");
	return nil;
}


RPCread: type (int, int, int, chan of (array of byte, string));

append(r: RPCread)
{
	t := r :: nil;
	while(rdreq != nil) {
		t = hd rdreq :: t;
		rdreq = tl rdreq;
	}
	rdreq = t;
}

cursorcontrol(t: ref Tk->Toplevel, s: string): string
{
	l := len s;
	for(i := 0; i < l; i++) {
		case s[i] {
		    '\b' =>
			pre := "";
			rem := "";
			if(i + 1 < l)
				rem = s[i+1:];
			if(i == 0) {	# erase existing character in line
				if(tk->cmd(t, ".ft.t get " +
					"{outpoint linestart} outpoint") != "")
				    cmd(t, ".ft.t delete outpoint-1char");
			} else {
				if(s[i-1] != '\n')	# don't erase newlines
					i--;
				if(i)
					pre = s[:i];
			}
			s = pre + rem;
			l = len s;
			i = len pre - 1;
		    '\r' =>
			s[i] = '\n';
			if(i + 1 < l && s[i+1] == '\n')	# \r\n
				s = s[:i] + s[i+1:];
			else if(i > 0 && s[i-1] == '\n')	# \n\r
				s = s[:i-1] + s[i:];
			l = len s;
		    '\0' =>
			s[i] = Sys->UTFerror;
		}
	}
	return s;
}

editor(t: ref Tk->Toplevel, ecmd: string)
{
	s, snarf: string;

	case ecmd {
	"scroll" =>
		menuindex = "0";
		scrolling = 1;
		cmd(t, ".m entryconfigure 0 -text noscroll -command {send edit noscroll}");
	"noscroll" =>
		menuindex = "0";
		scrolling = 0;
		cmd(t, ".m entryconfigure 0 -text scroll -command {send edit scroll}");
	"cut" =>
		menuindex = "1";
		cut(t, 1);
	"paste" =>
		menuindex = "2";
		paste(t);
	"snarf" =>
		menuindex = "3";
		if(cmd(t, ".ft.t tag ranges sel") == "")
			break;
		snarf = tk->cmd(t, ".ft.t get sel.first sel.last");
		tkclient->snarfput(snarf);
	"send" =>
		menuindex = "4";
		if(cmd(t, ".ft.t tag ranges sel") != ""){
			snarf = tk->cmd(t, ".ft.t get sel.first sel.last");
			tkclient->snarfput(snarf);
		}else{
			snarf = tkclient->snarfget();
		}
		if(snarf != "")
			s = snarf;
		else
			return;
		if(s[len s-1] != '\n' && s[len s-1] != EOT)
			s[len s] = '\n';
		simulatetype(t, s);
	}
	cmd(t, "update");
}

simulatetype(t: ref Tk->Toplevel, s: string)
{
	if(rawon){
		rawinput += s;
	}else{
		cmd(t, ".ft.t see end; .ft.t insert end '"+s);
		cmd(t, ".ft.t mark set insert end");
		tk->cmd(t, ".ft.t tag remove sel sel.first sel.last");
	}
}

cut(t: ref Tk->Toplevel, snarfit: int)
{
	if(cmd(t, ".ft.t tag ranges sel") == "")
		return;
	if(snarfit)
		tkclient->snarfput(tk->cmd(t, ".ft.t get sel.first sel.last"));
	cmd(t, ".ft.t delete sel.first sel.last");
}

paste(t: ref Tk->Toplevel)
{
	snarf := tkclient->snarfget();
	if(snarf == "")
		return;
	cut(t, 0);
	if(rawon && int cmd(t, ".ft.t compare insert >= outpoint")){
		rawinput += snarf;
	}else{
		cmd(t, ".ft.t insert insert '"+snarf);
		cmd(t, ".ft.t tag add sel insert-"+string len snarf+"chars insert");
	}
}

sendinput(t: ref Tk->Toplevel)
{
	input: string;
	if(rawon)
		input = rawinput;
	else
		input = tk->cmd(t, ".ft.t get outpoint end");
	if(rdreq == nil || (input == nil && len partialread == 0))
		return;
	r := hd rdreq;
	(chars, bytes, partial) := triminput(r.nbytes, input, partialread);
	if(bytes == nil)
		return;	# no terminator yet
	rdreq = tl rdreq;

	alt {
	r.rc <-= (bytes, nil) =>
		# check that it really was sent
		alt {
		r.rc <-= (nil, nil) =>
			;
		* =>
			return;
		}
	* =>
		return;	# requester has disappeared; ignore his request and try another
	}
	if(rawon)
		rawinput = rawinput[chars:];
	else
		cmd(t, ".ft.t mark set outpoint outpoint+" + string chars + "chars");
	partialread = partial;
}

# read at most nr bytes from the input string, returning the number of characters
# consumed, the bytes to be read, and any remaining bytes from a partially
# read multibyte UTF character.
triminput(nr: int, input: string, partial: array of byte): (int, array of byte, array of byte)
{
	if(nr <= len partial)
		return (0, partial[0:nr], partial[nr:]);
	if(holding)
		return (0, nil, partial);

	# keep the array bounds within sensible limits
	if(nr > len input*Sys->UTFmax)
		nr = len input*Sys->UTFmax;
	buf := array[nr+Sys->UTFmax] of byte;
	t := len partial;
	buf[0:] = partial;

	hold := !rawon;
	i := 0;
	while(i < len input){
		c := input[i++];
		# special case for ^D - don't read the actual ^D character
		if(!rawon && c == EOT){
			hold = 0;
			break;
		}

		t += sys->char2byte(c, buf, t);
		if(c == '\n' && !rawon){
			hold = 0;
			break;
		}
		if(t >= nr)
			break;
	}
	if(hold){
		for(j := i; j < len input; j++){
			c := input[j];
			if(c == '\n' || c == EOT)
				break;
		}
		if(j == len input)
			return (0, nil, partial);
		# strip ^D when next read would read it, otherwise
		# we'll give premature EOF.
		if(i == j && input[i] == EOT)
			i++;
	}
	partial = nil;
	if(t > nr){
		partial = buf[nr:t];
		t = nr;
	}
	return (i, buf[0:t], partial);
}

# The shell, in a name space of its own (the window's keeps the real
# /dev/cons and /dev/consctl, which the soft keyboard is told through)
# with /dev/cons, /dev/consctl and /chan/shctl served by the window.
# It opens /dev/cons ORCLOSE, so the file goes when the shell and
# everything it started have closed it, and the window with it.
newsh(ctxt: ref Context, ioc: chan of (int, ref FileIO, ref FileIO, string, ref FileIO),
			args: list of string)
{
	pid := sys->pctl(sys->NEWFD, nil);

	sh := load Command "/dis/sh.dis";
	if(sh == nil) {
		ioc <-= (0, nil, nil, nil, nil);
		return;
	}

	tty := "cons."+string pid;

	sys->bind("#s","/chan",sys->MBEFORE);
	fio := sys->file2chan("/chan", tty);
	fioctl := sys->file2chan("/chan", tty + "ctl");
	shctl := sys->file2chan("/chan", "shctl");
	ioc <-= (pid, fio, fioctl, "/chan/"+tty, shctl);
	if(fio == nil || fioctl == nil || shctl == nil)
		return;

	sys->pctl(Sys->FORKNS, nil);
	sys->bind("/chan/"+tty, "/dev/cons", sys->MREPL);
	sys->bind("/chan/"+tty+"ctl", "/dev/consctl", sys->MREPL);

	fd0 := sys->open("/dev/cons", sys->OREAD|sys->ORCLOSE);
	fd1 := sys->open("/dev/cons", sys->OWRITE);
	fd2 := sys->open("/dev/cons", sys->OWRITE);

	{
		sh->init(ctxt, "sh" :: "-n" :: args);
	}exception{
	"fail:*" =>
		exit;
	}
}

cmd(top: ref Tk->Toplevel, c: string): string
{
	s:= tk->cmd(top, c);
	if (s != nil && s[0] == '!')
		sys->fprint(sys->fildes(2), "wm/shell: tk error on '%s': %s\n", c, s);
	return s;
}

itemsize(top: ref Tk->Toplevel, item: string): (int, int)
{
	w := int tk->cmd(top, item + " cget -actwidth");
	h := int tk->cmd(top, item + " cget -actheight");
	b := int tk->cmd(top, item + " cget -borderwidth");
	return (w+b, h+b);
}
