implement ToolWindow;

#
# window - the pictures of this activity's windows
#
# Reads /mnt/wsys, the window manager's read-only window tree
# (wmsrv(2) wsys: <id>/window, each client's main window in the
# /dev/screen format).  nsconstruct grants this tool only its own
# activity's tree, bound over /mnt/wsys, so other activities' windows
# are not even nameable.  Nothing here draws or needs a display: a
# picture is copied, as a file, into the agent's scratch space, where
# present can show it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "../tool.m";

ToolWindow: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

WSYS: con "/mnt/wsys";
SCRATCH: con "/tmp/veltro/scratch";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "window";
}

doc(): string
{
	return "window - pictures of this activity's windows\n\n" +
		"Usage:\n" +
		"  window list              one line per window: id width height\n" +
		"  window save <id> [name]  save window <id> as an image in scratch;\n" +
		"                           prints the path (show it with present)\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"window\"," +
		"\"description\":\"Pictures of the windows in this activity. 'list' gives each window's id and size; 'save <id> [name]' saves that window's current picture as an image file in scratch and returns its path, which present can show.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"op\":{\"type\":\"string\",\"description\":\"list or save\"}," +
				"\"id\":{\"type\":\"string\",\"description\":\"for save: the window id from list\"}," +
				"\"name\":{\"type\":\"string\",\"description\":\"for save: optional file name (letters, digits, - and _)\"}" +
			"}," +
			"\"required\":[\"op\"]" +
		"}" +
		"}";
}

exec(args: string): string
{
	(nil, toks) := sys->tokenize(args, " \t\n");
	if(toks == nil)
		return "error: usage: window list | window save <id> [name]";
	case hd toks {
	"list" =>
		return listwindows();
	"save" =>
		toks = tl toks;
		if(toks == nil)
			return "error: usage: window save <id> [name]";
		id := hd toks;
		fname := "window-" + id;
		if(tl toks != nil)
			fname = hd tl toks;
		return save(id, fname);
	}
	return "error: unknown operation " + hd toks + " (list, save)";
}

listwindows(): string
{
	fd := sys->open(WSYS, Sys->OREAD);
	if(fd == nil)
		return "error: no windows available to this activity";
	s := "";
	for(;;) {
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			(w, h) := size(WSYS + "/" + d[i].name + "/window");
			if(w >= 0)
				s += sys->sprint("%s %d %d\n", d[i].name, w, h);
		}
	}
	if(s == "")
		return "no windows";
	return s;
}

# The rectangle in an image file's header (5 fields of 12 bytes).
size(path: string): (int, int)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (-1, -1);
	hdr := array[60] of byte;
	if(sys->readn(fd, hdr, len hdr) != len hdr)
		return (-1, -1);
	(n, f) := sys->tokenize(string hdr, " ");
	if(n < 5)
		return (-1, -1);
	f = tl f;
	x0 := int hd f; f = tl f;
	y0 := int hd f; f = tl f;
	x1 := int hd f; f = tl f;
	y1 := int hd f;
	return (x1 - x0, y1 - y0);
}

save(id, fname: string): string
{
	if(!goodname(id) || !goodname(fname))
		return "error: ids and names are letters, digits, - and _";
	in := sys->open(WSYS + "/" + id + "/window", Sys->OREAD);
	if(in == nil)
		return "error: no window " + id;
	path := SCRATCH + "/" + fname + ".bit";
	out := sys->create(path, Sys->OWRITE, 8r644);
	if(out == nil)
		return sys->sprint("error: cannot create %s: %r", path);
	buf := array[Sys->ATOMICIO] of byte;
	for(;;) {
		n := sys->read(in, buf, len buf);
		if(n < 0)
			return sys->sprint("error: reading window %s: %r", id);
		if(n == 0)
			break;
		if(sys->write(out, buf, n) != n)
			return sys->sprint("error: writing %s: %r", path);
	}
	return path;
}

goodname(s: string): int
{
	if(s == "")
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_'))
			return 0;
	}
	return 1;
}
