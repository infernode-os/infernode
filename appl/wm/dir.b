implement WmDir;

#
# wm/dir - a directory's files as icons or as a list
#
# Inferno's file browser (upstream 20060303), restored: the glyphs are
# icon(2)'s, painted in the theme's colours, and a folder opens in the
# same window unless Options asks for a window each.  A file opens
# through the plumber, so in Lucifer it lands in the presentation view;
# with no plumber, a program (.dis) runs, an image shows in wm/view and
# anything else opens in wm/edit.  Button 3 plumbs what it is on.
#

include "sys.m";
	sys: Sys;
	Dir: import sys;

include "draw.m";
	draw: Draw;
	ctxt: ref Draw->Context;

include "tk.m";
	tk: Tk;
	Toplevel: import tk;

include "tkclient.m";
	tkclient: Tkclient;

include "dialog.m";
	dialog: Dialog;

include "readdir.m";
	readdir: Readdir;

include "daytime.m";
	daytime: Daytime;

include "plumbmsg.m";
	plumbmsg: Plumbmsg;
	Msg: import plumbmsg;

include "names.m";
	names: Names;

include "workdir.m";

include "lucitheme.m";

include "icon.m";
	icon: Icon;

WmDir: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

Wm: module
{
	init:	fn(ctxt: ref Draw->Context, argv: list of string);
};

# the glyph sizes, in the icon view and in the list
BIG:	con 32;
SMALL:	con 16;

# an icon's cell: at least this wide, at most that, this tall
CELLMIN:	con 76;
CELLMAX:	con 136;
CELLH:	con 64;
ROWH:	con 22;

# a kind of file: the glyph that shows it and, with no plumber, what
# opens it (nil: the file is a program and runs)
Ft: adt {
	glyph:	string;
	cmd:	string;
};

dirtype := Ft("folder", nil);
uptype := Ft("folder-up", nil);
deftype := Ft("file", "/dis/wm/edit.dis");
progtype := Ft("terminal-2", nil);

# by extension
exttypes := array[] of {
	("b", Ft("file-code", "/dis/wm/edit.dis")),
	("m", Ft("file-code", "/dis/wm/edit.dis")),
	("c", Ft("file-code", "/dis/wm/edit.dis")),
	("h", Ft("file-code", "/dis/wm/edit.dis")),
	("s", Ft("file-code", "/dis/wm/edit.dis")),
	("sh", Ft("file-code", "/dis/wm/edit.dis")),
	("py", Ft("file-code", "/dis/wm/edit.dis")),
	("js", Ft("file-code", "/dis/wm/edit.dis")),
	("go", Ft("file-code", "/dis/wm/edit.dis")),
	("txt", Ft("file-text", "/dis/wm/edit.dis")),
	("md", Ft("markdown", "/dis/wm/edit.dis")),
	("pdf", Ft("file-type-pdf", "/dis/wm/page.dis")),
	("bit", Ft("photo", "/dis/wm/view.dis")),
	("mask", Ft("photo", "/dis/wm/view.dis")),
	("gif", Ft("photo", "/dis/wm/view.dis")),
	("jpg", Ft("photo", "/dis/wm/view.dis")),
	("jpeg", Ft("photo", "/dis/wm/view.dis")),
	("png", Ft("photo", "/dis/wm/view.dis")),
	("webp", Ft("photo", "/dis/wm/view.dis")),
	("svg", Ft("photo", "/dis/wm/view.dis")),
	("ppm", Ft("photo", "/dis/wm/view.dis")),
	("tar", Ft("file-zip", nil)),
	("tgz", Ft("file-zip", nil)),
	("gz", Ft("file-zip", nil)),
	("bz2", Ft("file-zip", nil)),
	("zip", Ft("file-zip", nil)),
	("wav", Ft("file-music", nil)),
	("iaf", Ft("file-music", nil)),
	("mp3", Ft("file-music", nil)),
	("ogg", Ft("file-music", nil)),
	("mp4", Ft("movie", nil)),
	("mpg", Ft("movie", nil)),
	("avi", Ft("movie", nil)),
};

dirwin_cfg := array[] of {
	# Lay out the screen
	"frame .fc",
	"scrollbar .fc.scroll -command {.fc.c yview}",
	"canvas .fc.c -relief flat -yscrollincrement 25"+
		" -borderwidth 0 -width 480 -height 320"+
		" -yscrollcommand {.fc.scroll set}",
	"frame .mbar",
	"menubutton .mbar.opt -text {Options} -menu .opt",
	"pack .mbar.opt -side left",
	"pack .fc.scroll -side right -fill y",
	"pack .fc.c -fill both -expand 1",
	"pack .mbar -fill x",
	"pack .fc -fill both -expand 1",
	"pack propagate . 0",

	# prepare cursor
	"image create bitmap waiting -file cursor.wait",

	# Build the options menu
	"menu .opt",
	".opt add radiobutton -text {by name}"+
		" -variable sort -value n -command {send opt sort}",
	".opt add radiobutton -text {by access}"+
		" -variable sort -value a -command {send opt sort}",
	".opt add radiobutton -text {by modify}"+
		" -variable sort -value m -command {send opt sort}",
	".opt add radiobutton -text {by size}"+
		" -variable sort -value s -command {send opt sort}",
	".opt add separator",
	".opt add radiobutton -text {use icons}"+
		" -variable show -value i -command {send opt icon}",
	".opt add radiobutton -text {use text}"
		+" -variable show -value t -command {send opt text}",
	".opt add separator",
	".opt add checkbutton -text {A window for each folder} -command {send opt walk}",
};

key := Readdir->NAME;
walk := 1;		# a folder opens in this window
path: string;
usetext: int;
cmdname: string;
sysnam: string;
nde: int;
now: int;
plumbed := 0;
de: array of ref Sys->Dir;
glyphcol := int 16rCCCCCCFF;
glyphs: list of string;		# Tk images made, as "tkname glyph size"
lastw := 0;
lasth := 0;

init(env: ref Draw->Context, argv: list of string)
{
	ctxt = env;

	sys  = load Sys Sys->PATH;
	if (ctxt == nil) {
		sys->fprint(sys->fildes(2), "dir: no window context\n");
		raise "fail:bad context";
	}
	draw = load Draw Draw->PATH;
	tk   = load Tk Tk->PATH;
	tkclient = load Tkclient Tkclient->PATH;
	dialog = load Dialog Dialog->PATH;
	readdir = load Readdir Readdir->PATH;
	names = load Names Names->PATH;
	icon = load Icon Icon->PATH;
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	if(plumbmsg != nil && plumbmsg->init(1, nil, 0) >= 0)
		plumbed = 1;

	# a group of its own: an exit is a killgrp, and the one it was
	# started in may be wm's
	sys->pctl(Sys->NEWPGRP, nil);
	tkclient->init();
	dialog->init();

	cmdname = hd argv;
	sysnam = sysname()+":";

	(t, wmctl) := tkclient->toplevel(ctxt, "-width 480 -height 360", "", Tkclient->Appl);
	if(icon != nil)
		icon->init(t.display);
	glyphcolour();

	tk->cmd(t, "cursor -image waiting");

	filecmd := chan of string;
	tk->namechan(t, filecmd, "fc");
	conf := chan of string;
	tk->namechan(t, conf, "cf");
	opt := chan of string;
	tk->namechan(t, opt, "opt");

	for (c:=0; c<len dirwin_cfg; c++)
		tk->cmd(t, dirwin_cfg[c]);
	argv = tl argv;
	start := "";
	if(argv != nil)
		start = hd argv;
	if(!getdir(t, start))
		exit;
	tk->cmd(t, "update");
	drawdir(t);
	tk->cmd(t, "update; cursor -default");
	tk->cmd(t, "bind . <Configure> {send cf conf}");
	tkclient->onscreen(t, nil);
	tkclient->startinput(t, "kbd"::"ptr"::nil);
	themech := chan[1] of int;
	spawn themelistener(themech);
	# the window manager may have given it another size
	if(int tk->cmd(t, ".fc.c cget -actwidth") != lastw)
		redraw(t);

f:	for(;;) alt {
	s := <-t.ctxt.kbd =>
		tk->keyboard(t, s);
	s := <-t.ctxt.ptr =>
		tk->pointer(t, *s);
	s := <-t.ctxt.ctl or
	s = <-t.wreq or
	s = <-wmctl =>
		tkclient->wmctl(t, s);
		if(s == "retheme"){
			glyphcolour();
			repaint(t);
		}
	<-themech =>
		# a theme switch with no window manager to say so (Lucifer's zone)
		tkclient->wmctl(t, "retheme");
		glyphcolour();
		repaint(t);
	<-conf =>
		# lay the icons out again only if the width changed
		w := int tk->cmd(t, ".fc.c cget -actwidth");
		h := int tk->cmd(t, ".fc.c cget -actheight");
		if(w == lastw && (h == lasth || usetext))
			break;
		redraw(t);
	mopt := <-opt =>
		case mopt {
		"sort" =>
			case tk->cmd(t, "variable sort") {
			"n" => key = readdir->NAME;
			"a" => key = readdir->ATIME;
			"m" => key = readdir->MTIME;
			"s" => key = readdir->SIZE;
			}
			(de, nde) = readdir->sortdir(de, key);
			de = dotdotfirst(de, nde);
		"walk" =>
			walk = !walk;
			continue f;
		"text" =>
			usetext = 1;
		"icon" =>
			usetext = 0;
		}
		redraw(t);
	action := <-filecmd =>
		nd := int action[1:];
		if(nd >= nde)
			break;
		case action[0] {
		'1' =>
			button1(t, de[nd]);
		'3' =>
			button3(t, de[nd]);
		}
	}
}

redraw(t: ref Toplevel)
{
	tk->cmd(t, ".fc.c delete all");
	drawdir(t);
	tk->cmd(t, ".fc.c yview moveto 0; update");
}

# Read dir; on an error, say so and keep what was shown.
getdir(t: ref Toplevel, dir: string): int
{
	if(dir == "")
		dir = "/";
	if(dir[0] != '/'){
		wd := load Workdir Workdir->PATH;
		if(wd != nil)
			dir = wd->init() + "/" + dir;
	}
	if(names != nil)
		dir = names->cleanname(dir);
	if (dir[len dir - 1] != '/')
		dir[len dir] = '/';

	(d, n) := readdir->init(dir, key);
	if(n < 0) {
		dialog->prompt(ctxt, t.image, "error -fg red",
				"Read directory",
				sys->sprint("Error reading \"%s\"\n%r", dir),
				0, "Continue"::nil);
		return 0;
	}
	path = dir;
	de = d;
	nde = n;

	if(path != "/") {
		# the parent of the folder shown, not of the working directory
		(ok, pd) := sys->stat(path + "..");
		if(ok >= 0) {
			dot := array[nde+1] of ref Dir;
			dot[0] = ref pd;
			dot[0].name = "..";
			dot[1:] = de;
			de = dot;
			nde++;
		}
	}

	for(i := 0; i < nde; i++) {
		s := de[i].name;
		l := len s;
		if(l > 4 && s[l-4:] == ".dis")
			de[i].mode |= 8r111;
	}
	tkclient->settitle(t, sysnam+path);
	return 1;
}

# .. stays first whatever the order
dotdotfirst(d: array of ref Dir, n: int): array of ref Dir
{
	for(i := 0; i < n; i++)
		if(d[i].name == ".."){
			dd := d[i];
			for(; i > 0; i--)
				d[i] = d[i-1];
			d[0] = dd;
			break;
		}
	return d;
}

defcursor(t: ref Toplevel)
{
	tk->cmd(t, "cursor -default");
}

button1(t: ref Toplevel, item: ref Dir)
{
	tk->cmd(t, "cursor -image waiting");
	npath := path;
	name := item.name + "/";
	if(item.name == "..") {
		i := len path - 2;
		while(i > 0 && path[i] != '/')
			i--;
		npath = path[0:i];
		name = "/";
	}

	exec := npath+name[0:len name-1];
	if(exec == "")
		exec = "/";

	if(item.mode & Sys->DMDIR) {
		if(walk) {
			if(getdir(t, exec))
				redraw(t);
			defcursor(t);
			return;
		}
		mod := load Wm "/dis/wm/dir.dis";
		defcursor(t);
		if(mod == nil) {
			dialog->prompt(ctxt, t.image, "error -fg red", "Load Dir module",
				sys->sprint("Error: %r"),
				0, "Continue"::nil);
			return;
		}
		spawn applinit(mod, ctxt, cmdname :: exec :: nil);
		return;
	}

	ft := filetype(item);
	if(ft.cmd != nil && plumb(exec)) {
		defcursor(t);
		return;
	}
	cmd := ft.cmd;
	if(cmd == nil){
		# a program runs; anything else nothing here opens
		if((item.mode & 8r111) == 0){
			defcursor(t);
			if(!plumb(exec))
				dialog->prompt(ctxt, t.image, "error -fg red", "Open",
					"Nothing opens " + item.name, 0, "Continue"::nil);
			return;
		}
		cmd = exec;
	}

	mod := load Wm cmd;
	defcursor(t);
	if(mod == nil) {
		dialog->prompt(ctxt, t.image, "error -fg red", "Load Module",
			sys->sprint("Trying to load \"%s\"\n%r", cmd),
			0, "Continue"::nil);
		return;
	}
	if(ft.cmd != nil)
		spawn applinit(mod, ctxt, item.name :: exec :: nil);
	else
		spawn applinit(mod, ctxt, item.name :: nil);
}

applinit(mod: Wm, ctxt: ref Draw->Context, args: list of string)
{
	# not a copy of this window's connection to wm: it would keep the
	# window up after this program had gone
	sys->pctl(sys->NEWPGRP|sys->NEWFD, 0 :: 1 :: 2 :: nil);
	spawn mod->init(ctxt, args);
}

# Send the full name of a file to the plumber; 0 if there is none or
# nothing takes it.
plumb(name: string): int
{
	if(!plumbed)
		return 0;
	msg := ref Msg("WmDir", "", path, "text", "", array of byte name);
	return msg.send() >= 0;
}

button3(nil: ref Toplevel, stat: ref Sys->Dir)
{
	if(stat.name == "..")
		return;
	plumb(path + stat.name);
}

filetype(d: ref Dir): Ft
{
	if(d.name == "..")
		return uptype;
	if(d.mode & Sys->DMDIR)
		return dirtype;
	name := d.name;
	suffix := "";
	for(j := len name-1; j > 0; j--) {
		if(name[j] == '.') {
			suffix = name[j+1:];
			break;
		}
	}
	if(suffix == "dis")
		return progtype;
	for(j = 0; j < len suffix; j++)
		if(suffix[j] >= 'A' && suffix[j] <= 'Z')
			suffix[j] += 'a' - 'A';
	for(i := 0; i < len exttypes; i++) {
		(ext, ft) := exttypes[i];
		if(suffix == ext)
			return ft;
	}
	if(d.mode & 8r111)
		return progtype;
	return deftype;
}

# The Tk image showing glyph at size: made the first time.
glyphimage(t: ref Toplevel, glyph: string, size: int): string
{
	tkname := "G_" + tkword(glyph) + "_" + string size;
	for(l := glyphs; l != nil; l = tl l)
		if(hd l == tkname + " " + glyph + " " + string size)
			return tkname;
	if(icon == nil)
		return nil;
	if(icon->tkimage(t, tkname, glyph, size, glyphcol) != nil)
		return nil;
	glyphs = tkname + " " + glyph + " " + string size :: glyphs;
	return tkname;
}

# A theme switch: every glyph painted again in the new colour, where it
# is shown.
repaint(t: ref Toplevel)
{
	if(icon == nil)
		return;
	for(l := glyphs; l != nil; l = tl l){
		(nil, w) := sys->tokenize(hd l, " ");
		icon->tkimage(t, hd w, hd tl w, int hd tl tl w, glyphcol);
	}
	tk->cmd(t, "update");
}

# any write of /lib/lucifer/theme/current (lucitheme->watch)
themelistener(ch: chan of int)
{
	lt := load Lucitheme Lucitheme->PATH;
	if(lt == nil)
		return;
	c := lt->watch();
	for(;;){
		<-c;
		alt {
		ch <-= 1 => ;
		* => ;
		}
	}
}

glyphcolour()
{
	lucitheme := load Lucitheme Lucitheme->PATH;
	if(lucitheme != nil)
		glyphcol = lucitheme->gettheme().text;
}

tkword(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '-')
			s[i] = '_';
	return s;
}

bindfile(t: ref Toplevel, id: string, i: int)
{
	base := ".fc.c bind "+id;
	tk->cmd(t, base+" <Double-Button-1> {send fc %b "+string i+"}");
	tk->cmd(t, base+" <Button-3> {send fc %b "+string i+"}");
	tk->cmd(t, base+" <Motion-Button-3> {}");
}

drawdir(t: ref Toplevel)
{
	lastw = int tk->cmd(t, ".fc.c cget -actwidth");
	lasth = int tk->cmd(t, ".fc.c cget -actheight");
	if(usetext)
		drawdirtxt(t);
	else
		drawdirico(t);
}

drawdirtxt(t: ref Toplevel)
{
	if(daytime == nil) {
		daytime = load Daytime Daytime->PATH;
		if(daytime == nil) {
			dialog->prompt(ctxt, t.image, "error -fg red", "Load Module",
				sys->sprint("Trying to load \"%s\"\n%r", Daytime->PATH),
				0, "Continue"::nil);
			return;
		}
	}
	now = daytime->now();

	y := ROWH/2 + 4;
	for(i := 0; i < nde; i++) {
		size := sys->sprint("%bd", de[i].length);
		if(de[i].mode & Sys->DMDIR)
			size = "";
		s := sys->sprint("%10s  %s  %s", size, daytime->filet(now, de[i].mtime), de[i].name);
		img := glyphimage(t, filetype(de[i]).glyph, SMALL);
		if(img != nil){
			id := tk->cmd(t, ".fc.c create image 16 "+string y+" -image "+img);
			bindfile(t, id, i);
		}
		id := tk->cmd(t, ".fc.c create text 32 "+string y+
				" -anchor w -text "+tk->quote(s));
		bindfile(t, id, i);
		y += ROWH;
	}

	x := int tk->cmd(t, ".fc.c cget -actwidth");
	tk->cmd(t, ".fc.c configure -scrollregion { 0 0 "+string x+" "+string y+"}");
}

drawdirico(t: ref Toplevel)
{
	w := int tk->cmd(t, ".fc.c cget -actwidth");
	if(w < CELLMIN)
		w = int tk->cmd(t, ".fc.c cget -width");

	# a cell as wide as the longest name, within bounds; a name longer
	# than its cell is cut short
	longest := "";
	for(i := 0; i < nde; i++)
		if(len de[i].name > len longest)
			longest = de[i].name;
	cw := textwidth(t, longest);
	chw := 8;
	if(len longest > 0 && cw > 0)
		chw = (cw + len longest - 1) / len longest;
	cell := cw + 12;
	if(cell < CELLMIN)
		cell = CELLMIN;
	if(cell > CELLMAX)
		cell = CELLMAX;
	ncol := w / cell;
	if(ncol < 1)
		ncol = 1;
	cell = w / ncol;
	maxch := (cell - 8) / chw;

	x := cell/2;
	y := BIG/2 + 8;
	col := 0;
	for(i = 0; i < nde; i++) {
		ft := filetype(de[i]);
		img := glyphimage(t, ft.glyph, BIG);
		label := de[i].name;
		if(len label > maxch && maxch > 1)
			label = label[0:maxch-1] + "…";
		if(img != nil){
			id := tk->cmd(t, ".fc.c create image "+string x+" "+string y+" -image "+img);
			bindfile(t, id, i);
		}
		id := tk->cmd(t, ".fc.c create text "+string x+" "+string (y+BIG/2+10)+
				" -text "+tk->quote(label));
		bindfile(t, id, i);
		if(++col >= ncol) {
			col = 0;
			x = cell/2;
			y += CELLH;
		} else
			x += cell;
	}
	if(col != 0)
		y += CELLH;
	tk->cmd(t, ".fc.c configure -scrollregion { 0 0 "+string w+" "+string y+"}");
}

# the width of s as the canvas shows text
textwidth(t: ref Toplevel, s: string): int
{
	if(s == "")
		return 0;
	id := tk->cmd(t, ".fc.c create text 0 0 -anchor nw -text "+tk->quote(s));
	(n, bb) := sys->tokenize(tk->cmd(t, ".fc.c bbox "+id), " ");
	tk->cmd(t, ".fc.c delete "+id);
	if(n < 4)
		return 0;
	return int hd tl tl bb - int hd bb;
}

sysname(): string
{
	fd := sys->open("#c/sysname", sys->OREAD);
	if(fd == nil)
		return "Anon";
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return "Anon";
	return string buf[0:n];
}
