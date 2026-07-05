implement ManViewer;

#
# wm/man - manual page viewer (Tk version)
#
# Parses troff -man via Parseman and renders into a Tk text widget,
# styled by the brutalist defaults: accent headings, dim italics, accent
# links, grey body. Scrolling, find and the Veltro IPC at /tmp/veltro/man
# are preserved.
#
# Keys:  Up/Down line, PgUp/PgDn screenful, Home/End, Ctrl-F find,
#        Ctrl-G find next, Escape cancel, Ctrl-Q quit.
# Mouse: B3 context menu (open/back/forward/find/top/bottom/exit).
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Font: import draw;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "man.m";
	parser: Parseman;

include "arg.m";
	arg: Arg;

include "lucitheme.m";
	lucitheme: Lucitheme;
	Theme: import lucitheme;

ManViewer: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

MAN_DIR: con "/tmp/veltro/man";
MARGIN:  con 6;

# Pixel-width callback Parseman uses for layout.
V: adt {
	textwidth: fn(v: self ref V, text: Parseman->Text): int;
};

V.textwidth(nil: self ref V, text: Parseman->Text): int
{
	f := rfont;
	if(text.heading > 0 || text.font == Parseman->FONT_BOLD)
		f = bfont;
	if(f == nil)
		return len text.text;
	return f.width(text.text);
}

# ── State ─────────────────────────────────────────────────────

top:     ref Toplevel;
wmctl:   chan of string;
actch:   chan of string;
themech: chan of int;
ticks:   chan of int;
stderr:  ref Sys->FD;

display: ref Display;
rfont:   ref Font;
bfont:   ref Font;
spacew:  int;		# pixel width of a space in rfont

pagetitle := "man";
searchstr := "";
lastmatch := "";	# last find index in the text widget
findmode  := 0;		# 1 while a status-line prompt is active
promptkind := 0;	# 0 = find, 1 = open-by-name
findbuf   := "";

history:  list of string;
histfwd:  list of string;

# ── Init ──────────────────────────────────────────────────────

init(ctxt: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	tk = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	parser = load Parseman Parseman->PATH;
	lucitheme = load Lucitheme Lucitheme->PATH;
	stderr = sys->fildes(2);
	if(tkclient == nil || parser == nil || bufio == nil){
		sys->fprint(stderr, "wm/man: missing module: %r\n");
		raise "fail:init";
	}
	parser->init();

	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	if(ctxt == nil)
		ctxt = tkclient->makedrawcontext();
	if(ctxt == nil){
		sys->fprint(stderr, "wm/man: no window context\n");
		raise "fail:no context";
	}

	(top, wmctl) = tkclient->toplevel(ctxt, "-width 680 -height 520", "man", Tkclient->Appl);
	display = top.display;

	rfont = openfont("/fonts/combined/unicode.sans.14.font");
	bfont = openfont("/fonts/combined/unicode.sans.bold.14.font");
	if(rfont == nil)
		rfont = bfont;
	spacew = rfont.width(" ");
	if(spacew <= 0)
		spacew = 6;

	actch = chan[4] of string;
	tk->namechan(top, actch, "act");
	themech = chan[1] of int;
	ticks = chan of int;

	buildui();

	# parse the requested page(s)
	files := parseargs(argv);
	if(files != nil)
		loadpage(hd files);
	else
		setstatus("Right-click → open, or Ctrl-F to find");

	tkclient->onscreen(top, nil);
	tkclient->startinput(top, "kbd" :: "ptr" :: nil);

	initmandir();
	spawn themelistener();
	spawn timer();

	for(;;) alt {
	c := <-wmctl or
	c = <-top.ctxt.ctl or
	# top.wreq carries Tk window requests (menu posts create their
	# window through here); a loop that never drains it leaves every
	# posted menu mapped-and-grabbing but windowless — invisible.
	c = <-top.wreq =>
		tkclient->wmctl(top, c);
	k := <-top.ctxt.kbd =>
		handlekey(k);
	p := <-top.ctxt.ptr =>
		tk->pointer(top, *p);
	a := <-actch =>
		handleaction(a);
	<-ticks =>
		checkctlfile();
	<-themech =>
		retheme();
	}
}

openfont(path: string): ref Font
{
	f := Font.open(display, path);
	if(f == nil)
		f = Font.open(display, "*default*");
	return f;
}

# ── UI ────────────────────────────────────────────────────────

buildui()
{
	th := gettheme();
	cmds := array[] of {
		". configure -background " + col(th.bg >> 8),
		"frame .top",
		"scrollbar .top.sb -command {.top.t yview}",
		"text .top.t -yscrollcommand {.top.sb set} -wrap none -width 640 -height 480 " +
			"-background " + col(th.editbg >> 8) + " -foreground " + col(th.edittext >> 8) + " -font /fonts/combined/unicode.sans.14.font",
		"pack .top.sb -side right -fill y",
		"pack .top.t -side left -fill both -expand 1",
		"label .status -anchor w -background " + col(th.editstatus >> 8) + " -foreground " + col(th.editstattext >> 8),
		"pack .top -side top -fill both -expand 1",
		"pack .status -side bottom -fill x",
		"pack propagate . 0",
		"bind .top.t <Button-3> {send act menu %X %Y}",
		"menu .ctx",
	};
	tkcmds(cmds);
	tk->cmd(top, ".ctx add command -label {Open...} -command {send act open}");
	tk->cmd(top, ".ctx add command -label {Back} -command {send act back}");
	tk->cmd(top, ".ctx add command -label {Forward} -command {send act forward}");
	tk->cmd(top, ".ctx add command -label {Find} -command {send act find}");
	tk->cmd(top, ".ctx add separator");
	tk->cmd(top, ".ctx add command -label {Top} -command {send act top}");
	tk->cmd(top, ".ctx add command -label {Bottom} -command {send act bottom}");
	tk->cmd(top, ".ctx add separator");
	tk->cmd(top, ".ctx add command -label {Quit} -command {send act quit}");
	configtags();
}

configtags()
{
	th := gettheme();
	tk->cmd(top, sys->sprint(".top.t tag configure heading -foreground %s -font /fonts/combined/unicode.sans.bold.14.font", col(th.text >> 8)));
	tk->cmd(top, sys->sprint(".top.t tag configure bold -font /fonts/combined/unicode.sans.bold.14.font"));
	tk->cmd(top, sys->sprint(".top.t tag configure italic -foreground %s", col(th.dim >> 8)));
	tk->cmd(top, sys->sprint(".top.t tag configure link -foreground %s", col(th.accent >> 8)));
	tk->cmd(top, sys->sprint(".top.t tag configure match -background %s -foreground %s", col(th.accent >> 8), col(th.bg >> 8)));
	tk->cmd(top, sys->sprint(".top.t configure -foreground %s", col(th.edittext >> 8)));
}

# ── Page loading / rendering ──────────────────────────────────

loadpage(path: string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		setstatus(sys->sprint("cannot open %s: %r", path));
		return;
	}
	# remember the page name for the title / history
	pagetitle = basename(path);

	# page width in pixels for Parseman layout
	pw := 600;
	aw := int tk->cmd(top, ".top.t cget -actwidth");
	if(aw > 0)
		pw = aw - MARGIN * 2;
	em := rfont.width("m");
	en := rfont.width("n");
	m := Parseman->Metrics(pw, 96, em, en, rfont.height, em * 3, em * 2);

	datachan := chan of list of (int, Parseman->Text);
	spawn parser->parseman(fd, m, 0, ref V, datachan);

	tk->cmd(top, ".top.t delete 1.0 end");
	nlines := 0;
	for(;;){
		line := <-datachan;
		if(line == nil)
			break;
		renderline(line);
		nlines++;
	}
	tk->cmd(top, ".top.t yview moveto 0.0");
	tk->cmd(top, "update");
	settitle();
	writemanstate();
}

# Render one Parseman line (list of (indent, Text)) into the text widget.
renderline(ml: list of (int, Parseman->Text))
{
	col := 0;	# current pixel column on this line
	for(; ml != nil; ml = tl ml){
		(indent, txt) := hd ml;
		if(indent > col){
			# pad to the requested pixel column with spaces
			nsp := (indent - col) / spacew;
			if(nsp > 0)
				inserttext(spaces(nsp), "");
			col = indent;
		}
		tag := "";
		if(txt.heading > 0)
			tag = "heading";
		else if(txt.font == Parseman->FONT_BOLD)
			tag = "bold";
		else if(txt.font == Parseman->FONT_ITALIC)
			tag = "italic";
		if(txt.link != nil && len txt.link > 0)
			tag = "link";
		inserttext(txt.text, tag);
		if(rfont != nil)
			col += rfont.width(txt.text);
	}
	inserttext("\n", "");
}

# Insert text with a tag, quoting for Tk.
inserttext(s, tag: string)
{
	if(tag == "")
		tk->cmd(top, ".top.t insert end " + tk->quote(s));
	else
		tk->cmd(top, ".top.t insert end " + tk->quote(s) + " " + tag);
}

spaces(n: int): string
{
	s := "";
	for(i := 0; i < n; i++)
		s += " ";
	return s;
}

# ── Keyboard ──────────────────────────────────────────────────

Khome:   con 16rFF61;
Kend:    con 16rFF57;
Kup:     con 16rFF52;
Kdown:   con 16rFF54;
Kpgup:   con 16rFF55;
Kpgdown: con 16rFF56;
Kbs:     con 8;

handlekey(k: int)
{
	if(findmode){
		findkey(k);
		return;
	}
	case k {
	'q' - 16r60 =>	# Ctrl-Q
		exit;
	'f' - 16r60 =>	# Ctrl-F
		startfind();
	'g' - 16r60 =>	# Ctrl-G
		findnext();
	Kup =>     tk->cmd(top, ".top.t yview scroll -1 units");
	Kdown =>   tk->cmd(top, ".top.t yview scroll 1 units");
	Kpgup =>   tk->cmd(top, ".top.t yview scroll -1 pages");
	Kpgdown => tk->cmd(top, ".top.t yview scroll 1 pages");
	Khome =>   tk->cmd(top, ".top.t yview moveto 0.0");
	Kend =>    tk->cmd(top, ".top.t yview moveto 1.0");
	}
	writemanstate();
}

# ── Find (status-line prompt) ─────────────────────────────────

startfind()
{
	findmode = 1;
	promptkind = 0;
	findbuf = "";
	setstatus("Find: ");
}

startopen()
{
	findmode = 1;
	promptkind = 1;
	findbuf = "";
	setstatus("Man: ");
}

promptlabel(): string
{
	if(promptkind == 1)
		return "Man: ";
	return "Find: ";
}

findkey(k: int)
{
	case k {
	'\n' or '\r' =>
		findmode = 0;
		if(promptkind == 1)
			openbyname(findbuf);
		else {
			searchstr = findbuf;
			lastmatch = "";
			findnext();
		}
	27 =>	# Escape
		findmode = 0;
		settitle();
	Kbs =>
		if(len findbuf > 0)
			findbuf = findbuf[:len findbuf - 1];
		setstatus(promptlabel() + findbuf);
	* =>
		if(k >= ' ' && k < 16r7F){
			findbuf[len findbuf] = k;
			setstatus(promptlabel() + findbuf);
		}
	}
}

openbyname(name: string)
{
	if(name == "")
		return;
	found := lookupman(nil, name);
	if(found == nil){
		setstatus(name + " not found");
		return;
	}
	loadpage(hd found);
}

findnext()
{
	if(searchstr == ""){
		startfind();
		return;
	}
	tk->cmd(top, ".top.t tag remove match 1.0 end");
	from := "1.0";
	if(lastmatch != "")
		from = lastmatch + "+1c";
	idx := tk->cmd(top, ".top.t search -nocase " + tk->quote(searchstr) + " " + from + " end");
	if(idx == "" || idx[0] == '!'){
		# wrap to top
		idx = tk->cmd(top, ".top.t search -nocase " + tk->quote(searchstr) + " 1.0 end");
		if(idx == "" || idx[0] == '!'){
			setstatus(pagetitle + "    —    not found");
			return;
		}
	}
	lastmatch = idx;
	tk->cmd(top, sys->sprint(".top.t tag add match %s %s+%dc", idx, idx, len searchstr));
	tk->cmd(top, ".top.t see " + idx);
	setstatus(pagetitle + "    —    found: " + searchstr);
	writemanstate();
}

# ── Menu actions ──────────────────────────────────────────────

handleaction(a: string)
{
	(n, toks) := sys->tokenize(a, " ");
	if(n == 0)
		return;
	case hd toks {
	"menu" =>
		tk->cmd(top, ".ctx post " + menuxy(toks, n));
	"open" =>     startopen();
	"back" =>     goback();
	"forward" =>  goforward();
	"find" =>     startfind();
	"top" =>      tk->cmd(top, ".top.t yview moveto 0.0");
	"bottom" =>   tk->cmd(top, ".top.t yview moveto 1.0");
	"quit" =>     exit;
	}
}

goback()
{
	if(history == nil)
		return;
	path := hd history;
	history = tl history;
	loadpage(path);
}

goforward()
{
	if(histfwd == nil)
		return;
	path := hd histfwd;
	histfwd = tl histfwd;
	loadpage(path);
}

# ── Argument parsing / lookup ─────────────────────────────────

parseargs(argv: list of string): list of string
{
	filemode := 0;
	files: list of string;
	sections: list of string;

	arg = load Arg Arg->PATH;
	if(arg != nil){
		arg->init(argv);
		while((c := arg->opt()))
			case c {
			'f' => filemode = 1;
			}
		argv = arg->argv();
	} else if(argv != nil)
		argv = tl argv;

	if(filemode){
		for(; argv != nil; argv = tl argv)
			files = hd argv :: files;
		return files;
	}
	for(; argv != nil; argv = tl argv){
		a := hd argv;
		if(isdir("/man/" + a))
			sections = a :: sections;
		else {
			found := lookupman(sections, a);
			for(; found != nil; found = tl found)
				files = hd found :: files;
		}
	}
	return files;
}

lookupman(sections: list of string, title: string): list of string
{
	if(sections == nil){
		fd := sys->open("/man", Sys->OREAD);
		if(fd != nil){
			for(;;){
				(n, dirs) := sys->dirread(fd);
				if(n <= 0)
					break;
				for(i := 0; i < n; i++){
					nm := dirs[i].name;
					if(len nm == 1 && nm[0] >= '0' && nm[0] <= '9')
						sections = nm :: sections;
				}
			}
		}
	}
	ltitle := tolower(title);
	found: list of string;
	for(; sections != nil; sections = tl sections){
		sec := hd sections;
		fd := sys->open("/man/" + sec + "/INDEX", Sys->OREAD);
		if(fd == nil)
			continue;
		bio := bufio->fopen(fd, Sys->OREAD);
		if(bio == nil)
			continue;
		for(;;){
			line := bio.gets('\n');
			if(line == nil)
				break;
			(nf, fields) := sys->tokenize(line, " \t\n");
			if(nf < 2)
				continue;
			if(tolower(hd fields) == ltitle)
				found = "/man/" + sec + "/" + hd tl fields :: found;
		}
	}
	return found;
}

# ── Veltro IPC (/tmp/veltro/man) ──────────────────────────────

initmandir()
{
	mkdirq("/tmp/veltro");
	mkdirq(MAN_DIR);
}

writemanstate()
{
	# state: title + scroll fraction
	yv := tk->cmd(top, ".top.t yview");
	state := sys->sprint("page %s\nyview %s\n", pagetitle, yv);
	if(searchstr != "")
		state += "search " + searchstr + "\n";
	writefile(MAN_DIR + "/state", state);

	# view: the currently visible text, for AI context
	t0 := tk->cmd(top, ".top.t index @0,0");
	t1 := tk->cmd(top, ".top.t index @0,100000");
	view := sys->sprint("Man page: %s\n\n", pagetitle);
	if(t0 != "" && t1 != "")
		view += tk->cmd(top, ".top.t get " + t0 + " " + t1);
	writefile(MAN_DIR + "/view", view);
}

checkctlfile()
{
	cmd := readonce(MAN_DIR + "/ctl");
	if(cmd == "")
		return;
	(nil, toks) := sys->tokenize(cmd, " \t\n");
	if(toks == nil)
		return;
	verb := hd toks; toks = tl toks;
	case verb {
	"open" =>
		if(toks == nil)
			return;
		arg0 := hd toks;
		if(len arg0 > 0 && arg0[0] == '/'){
			pushhistory();
			loadpage(arg0);
			return;
		}
		secs: list of string; title := "";
		for(; toks != nil; toks = tl toks){
			t := hd toks;
			if(isdir("/man/" + t))
				secs = t :: secs;
			else
				title = t;
		}
		if(title != ""){
			found := lookupman(secs, title);
			if(found != nil){
				pushhistory();
				loadpage(hd found);
			}
		}
	"scroll" =>
		if(toks == nil)
			return;
		case hd toks {
		"up" =>     tk->cmd(top, ".top.t yview scroll -1 pages");
		"down" =>   tk->cmd(top, ".top.t yview scroll 1 pages");
		"top" =>    tk->cmd(top, ".top.t yview moveto 0.0");
		"bottom" => tk->cmd(top, ".top.t yview moveto 1.0");
		* =>
			(ln, nil) := str->toint(hd toks, 10);
			if(ln > 0)
				tk->cmd(top, sys->sprint(".top.t see %d.0", ln));
		}
		writemanstate();
	"find" =>
		if(toks == nil)
			return;
		searchstr = hd toks;
		for(toks = tl toks; toks != nil; toks = tl toks)
			searchstr += " " + hd toks;
		lastmatch = "";
		findnext();
	}
}

pushhistory()
{
	# called before loading a new page from a known current page
	;
}

# ── Theme ─────────────────────────────────────────────────────

themelistener()
{
	fd := sys->open("/mnt/ui/event", Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[256] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		ev := string buf[0:n];
		sys->seek(fd, big 0, Sys->SEEKSTART);
		if(len ev >= 6 && ev[0:6] == "theme ")
			themech <-= 1;
	}
}

retheme()
{
	th := gettheme();
	# Re-theme env-derived widget colours, then reconfigure the widgets that
	# carry explicit theme colours (toplevel, the text body, the status
	# strip) — these were hardcoded brimstone and stayed dark after a switch.
	tkclient->wmctl(top, "retheme");
	tk->cmd(top, ". configure -background " + col(th.bg >> 8));
	tk->cmd(top, ".top.t configure -background " + col(th.editbg >> 8) + " -foreground " + col(th.edittext >> 8));
	tk->cmd(top, ".status configure -background " + col(th.editstatus >> 8) + " -foreground " + col(th.editstattext >> 8));
	configtags();
}

gettheme(): ref Theme
{
	th: ref Theme;
	if(lucitheme != nil)
		th = lucitheme->gettheme();
	if(th == nil)
		th = ref Theme;
	return th;
}

# ── Helpers ───────────────────────────────────────────────────

timer()
{
	for(;;){
		sys->sleep(500);
		ticks <-= 1;
	}
}

settitle()
{
	setstatus(pagetitle);
	tkclient->settitle(top, "man — " + pagetitle);
}

setstatus(s: string)
{
	tk->cmd(top, ".status configure -text " + tk->quote(s));
}

col(v: int): string
{
	return sys->sprint("#%06xff", v & 16rFFFFFF);
}

menuxy(toks: list of string, n: int): string
{
	if(n >= 3){
		x := hd tl toks; y := hd tl tl toks;
		if(x != "" && x[0] >= '0' && x[0] <= '9')
			return x + " " + y;
	}
	return "40 40";
}

basename(path: string): string
{
	i := len path - 1;
	while(i >= 0 && path[i] != '/')
		i--;
	return path[i+1:];
}

isdir(path: string): int
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return 0;
	return (d.mode & Sys->DMDIR) != 0;
}

mkdirq(path: string)
{
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return;
	fd := sys->create(path, Sys->OREAD, Sys->DMDIR | 8r777);
	fd = nil;
}

writefile(path, data: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd != nil){
		b := array of byte data;
		sys->write(fd, b, len b);
	}
}

readonce(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	s := string buf[0:n];
	# consume the command
	fd = sys->create(path, Sys->OWRITE, 8r666);
	fd = nil;
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' ' || s[len s-1] == '\t'))
		s = s[:len s-1];
	return s;
}

tolower(s: string): string
{
	t := "";
	for(i := 0; i < len s; i++){
		c := s[i];
		if(c >= 'A' && c <= 'Z')
			c += 'a' - 'A';
		t[len t] = c;
	}
	return t;
}

tkcmds(cmds: array of string)
{
	for(i := 0; i < len cmds; i++){
		e := tk->cmd(top, cmds[i]);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "man: tk error %s on %s\n", e, cmds[i]);
	}
}
