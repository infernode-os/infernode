implement Tkrender;
#
# tkrender cmdfile imgfile [W H]
#
# Deterministic off-screen Tk renderer for visual regression checks.
# Reads Tk commands (one per line; blank lines and #-comments ignored)
# from cmdfile, builds them on a no-window-manager toplevel sized W x H
# (default 360 x 240), then writes the window image to imgfile in the
# Inferno "compressed" image format (decode with tools/p9img2png.py).
#
# No event loop runs, so there is no dependence on a window manager and
# no busy-wait: the render is a pure function of the command list.
#
include "sys.m"; sys: Sys;
include "draw.m"; draw: Draw;
	Display, Image, Screen, Rect: import draw;
include "bufio.m"; bufio: Bufio;
	Iobuf: import bufio;
include "tk.m"; tk: Tk;
	Toplevel: import tk;
Tkrender: module { init: fn(ctxt: ref Draw->Context, argv: list of string); };

# turn the two-char sequence \n into a real newline
unescape(s: string): string
{
	out := "";
	for(i := 0; i < len s; i++){
		if(i + 1 < len s && s[i] == '\\' && s[i+1] == 'n'){
			out[len out] = '\n';
			i++;
		} else
			out[len out] = s[i];
	}
	return out;
}

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	tk = load Tk Tk->PATH;
	stderr := sys->fildes(2);

	argv = tl argv;
	if(len argv < 2){
		sys->fprint(stderr, "usage: tkrender cmdfile imgfile [W H]\n");
		raise "fail:usage";
	}
	cmdfile := hd argv; argv = tl argv;
	imgfile := hd argv; argv = tl argv;
	w := 360; h := 240;
	if(len argv >= 2){
		w = int hd argv; argv = tl argv;
		h = int hd argv;
	}

	disp := Display.allocate("");
	if(disp == nil){
		sys->fprint(stderr, "tkrender: no display: %r\n");
		raise "fail:display";
	}
	top := tk->toplevel(disp, "");

	iob := bufio->open(cmdfile, Bufio->OREAD);
	if(iob == nil){
		sys->fprint(stderr, "tkrender: cannot open %s: %r\n", cmdfile);
		raise "fail:open";
	}
	for(;;){
		line := iob.gets('\n');
		if(line == nil)
			break;
		# trim trailing newline
		while(len line > 0 && (line[len line-1] == '\n' || line[len line-1] == '\r'))
			line = line[:len line-1];
		if(len line == 0 || line[0] == '#')
			continue;
		# allow \n in the command file to stand for a real newline,
		# so multi-line text content (e.g. a man page) can be tested
		line = unescape(line);
		e := tk->cmd(top, line);
		if(e != nil && len e > 0 && e[0] == '!')
			sys->fprint(stderr, "tkrender: %s -> %s\n", line, e);
	}
	tk->cmd(top, sys->sprint(". configure -width %d -height %d", w, h));
	tk->cmd(top, "update");

	# no-wm: own screen on the display image, give the toplevel an image
	wr: Rect; wr.min = (0, 0); wr.max = (w, h);
	screen := Screen.allocate(disp.image, disp.color(int 16r080808FF), 0);
	winimg := screen.newwindow(wr, Draw->Refbackup, Draw->Nofill);
	tk->putimage(top, ". -1", winimg, nil);
	tk->cmd(top, "update");

	fd := sys->create(imgfile, Sys->OWRITE, 8r666);
	if(fd == nil){
		sys->fprint(stderr, "tkrender: cannot create %s: %r\n", imgfile);
		raise "fail:create";
	}
	disp.writeimage(fd, winimg);
	sys->fprint(stderr, "tkrender: wrote %s (%dx%d)\n", imgfile, w, h);
}
