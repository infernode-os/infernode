implement Lucitheme;

#
# lucitheme.b — Lucifer theme loader
#
# Reads a colour palette from Plan 9–style flat files.
# /lib/lucifer/theme/current names the active theme;
# /lib/lucifer/theme/<name> defines key-value colour pairs.
# Writing a name to current switches every program that watches it.
#
# File format: one "key RRGGBB" per line, # comments, blank lines ignored.
# Missing keys or unreadable files fall back to Brimstone defaults.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "lucitheme.m";

THEMEDIR: con "/lib/lucifer/theme/";

# Parse a single hex digit.  Returns 0–15 or -1.
hexdig(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

# Parse a 6-digit hex RGB string into an RGBA int (alpha FF).
# Returns (value, 1) on success, (0, 0) on error.
#
# The value is returned alongside an explicit ok flag rather than as a
# sentinel (e.g. -1) on its own: it is an RRGGBBAA pixel packed into a
# 32-bit Limbo int, and any colour whose red channel is >= 0x80 --
# which is most of a light theme's near-white colours, since the alpha
# byte this always appends is 0xFF -- sets the sign bit and comes back
# negative. A caller that read "value < 0" as "parse failed" (as this
# one used to) silently drops every such colour and keeps whatever the
# theme's built-in fallback had there instead. On Halo (bg FFFFEA,
# header EAFFFF, border CCCCBB, ...) that meant the desktop's own
# hand-drawn zones kept Brimstone's dark background and header while
# Halo's accent (2266CC, red channel 0x22) came through fine -- the
# highlight changed, the background didn't.
parsehex(s: string): (int, int)
{
	if(len s != 6)
		return (0, 0);
	v := 0;
	for(i := 0; i < 6; i++) {
		d := hexdig(s[i]);
		if(d < 0)
			return (0, 0);
		v = (v << 4) | d;
	}
	return ((v << 8) | 16rFF, 1);
}

# Read an entire small file as a string.  Returns nil on error.
readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

# Strip leading/trailing whitespace and newlines.
strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	return s[i:j];
}

# Apply a key-value pair to a Theme.
setkey(th: ref Theme, key: string, val: int)
{
	case key {
	"bg" =>		th.bg = val;
	"border" =>	th.border = val;
	"windowborder" => th.windowborder = val;
	"header" =>	th.header = val;
	"accent" =>	th.accent = val;
	"text" =>	th.text = val;
	"text2" =>	th.text2 = val;
	"dim" =>	th.dim = val;
	"label" =>	th.label = val;
	"human" =>	th.human = val;
	"veltro" =>	th.veltro = val;
	"input" =>	th.input = val;
	"cursor" =>	th.cursor = val;
	"red" =>	th.red = val;
	"green" =>	th.green = val;
	"yellow" =>	th.yellow = val;
	"progbg" =>	th.progbg = val;
	"progfg" =>	th.progfg = val;
	"codebg" =>	th.codebg = val;
	"menubg" =>	th.menubg = val;
	"menuborder" =>	th.menuborder = val;
	"menuhilit" =>	th.menuhilit = val;
	"menutext" =>	th.menutext = val;
	"menudim" =>	th.menudim = val;
	"editbg" =>	th.editbg = val;
	"edittext" =>	th.edittext = val;
	"editcursor" =>	th.editcursor = val;
	"editlineno" =>	th.editlineno = val;
	"editstatus" =>	th.editstatus = val;
	"editstattext" => th.editstattext = val;
	"editscroll" =>	th.editscroll = val;
	"editthumb" =>	th.editthumb = val;
	"diagbg" =>	th.diagbg = val;
	"diagnode" =>	th.diagnode = val;
	"diagborder" =>	th.diagborder = val;
	"diagtext" =>	th.diagtext = val;
	"diagtext2" =>	th.diagtext2 = val;
	"diagacc" =>	th.diagacc = val;
	"diaggreen" =>	th.diaggreen = val;
	"diagred" =>	th.diagred = val;
	"diagyellow" =>	th.diagyellow = val;
	"diaggrid" =>	th.diaggrid = val;
	"pie0" =>	th.pie0 = val;
	"pie1" =>	th.pie1 = val;
	"pie2" =>	th.pie2 = val;
	"pie3" =>	th.pie3 = val;
	"pie4" =>	th.pie4 = val;
	"pie5" =>	th.pie5 = val;
	"pie6" =>	th.pie6 = val;
	"pie7" =>	th.pie7 = val;
	}
}

brimstone(): ref Theme
{
	return ref Theme(
		# Core UI
		int 16r080808FF,	# bg
		int 16r131313FF,	# border
		int 16r0A0A0AFF,	# header
		int 16rE8553AFF,	# accent
		int 16rCCCCCCFF,	# text
		int 16r999999FF,	# text2
		int 16r444444FF,	# dim
		int 16r333333FF,	# label

		# Conversation
		int 16r1E2028FF,	# human
		int 16r0E1418FF,	# veltro
		int 16r101010FF,	# input
		int 16rE8553AFF,	# cursor

		# Status / semantic
		int 16rAA4444FF,	# red
		int 16r44AA44FF,	# green
		int 16rAAAA44FF,	# yellow
		int 16r1A1A1AFF,	# progbg
		int 16r3388CCFF,	# progfg

		# Code blocks
		int 16r1A1A2AFF,	# codebg

		# Menu
		int 16r0D0D0DFF,	# menubg
		int 16r2A2A2AFF,	# menuborder
		int 16r1E1E1EFF,	# menuhilit
		int 16rCCCCCCFF,	# menutext
		int 16r666666FF,	# menudim

		# Editor
		int 16r0D0D0DFF,	# editbg
		int 16rCCCCCCFF,	# edittext
		int 16rE8553AFF,	# editcursor
		int 16r444444FF,	# editlineno
		int 16r0A0A0AFF,	# editstatus
		int 16r999999FF,	# editstattext
		int 16r1A1A1AFF,	# editscroll
		int 16r444444FF,	# editthumb

		# Mermaid diagrams
		int 16r1E1E2EFF,	# diagbg
		int 16r313244FF,	# diagnode
		int 16r89B4FAFF,	# diagborder
		int 16rCDD6F4FF,	# diagtext
		int 16r8B949EFF,	# diagtext2
		int 16r89B4FAFF,	# diagacc
		int 16rA6E3A1FF,	# diaggreen
		int 16rF38BA8FF,	# diagred
		int 16rF9E2AFFF,	# diagyellow
		int 16r45475AFF,	# diaggrid
		int 16r89B4FAFF,	# pie0
		int 16rA6E3A1FF,	# pie1
		int 16rF9E2AFFF,	# pie2
		int 16rF38BA8FF,	# pie3
		int 16rCBA6F7FF,	# pie4
		int 16r94E2D5FF,	# pie5
		int 16rFAB387FF,	# pie6
		int 16r89DCEBFF,	# pie7

		# Window chrome (trailing field — see lucitheme.m)
		int 16r1A1A1AFF		# windowborder — subdued frame around wmclient apps
	);
}

gettheme(): ref Theme
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return brimstone();
	th := loadtheme(current());
	if(th == nil)
		return brimstone();
	return th;
}

loadtheme(name: string): ref Theme
{
	sys = load Sys Sys->PATH;
	if(!validname(name))
		return nil;
	data := readfile(THEMEDIR + name);
	if(data == nil)
		return nil;
	th := brimstone();
	for(l := parse(data); l != nil; l = tl l){
		(key, val) := hd l;
		setkey(th, key, val);
	}
	return th;
}

entries(name: string): list of (string, int)
{
	sys = load Sys Sys->PATH;
	if(!validname(name))
		return nil;
	return parse(readfile(THEMEDIR + name));
}

# "key RRGGBB" lines, in order; comments, blanks and bad colours skipped
parse(data: string): list of (string, int)
{
	r: list of (string, int);
	(nil, lines) := sys->tokenize(data, "\n");
	for(; lines != nil; lines = tl lines) {
		line := strip(hd lines);
		if(len line == 0 || line[0] == '#')
			continue;
		(ntoks, toks) := sys->tokenize(line, " \t");
		if(ntoks < 2)
			continue;
		(val, ok) := parsehex(hd tl toks);
		if(ok)
			r = (hd toks, val) :: r;
	}
	l: list of (string, int);
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return l;
}

current(): string
{
	sys = load Sys Sys->PATH;
	name := strip(readfile(THEMEDIR + "current"));
	if(name == nil)
		return "brimstone";
	return name;
}

# a theme's name is a file in THEMEDIR, not a path and not "current"
validname(name: string): int
{
	if(name == nil || name == "current" || name[0] == '.')
		return 0;
	for(i := 0; i < len name; i++)
		if(name[i] == '/' || name[i] == ' ' || name[i] == '\t' || name[i] == '\n')
			return 0;
	return 1;
}

settheme(name: string): string
{
	sys = load Sys Sys->PATH;
	if(!validname(name))
		return "invalid theme name";
	if(sys->stat(THEMEDIR + name).t0 < 0)
		return "no theme " + name;
	fd := sys->open(THEMEDIR + "current", Sys->OWRITE|Sys->OTRUNC);
	if(fd == nil)
		fd = sys->create(THEMEDIR + "current", Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("cannot write %scurrent: %r", THEMEDIR);
	b := array of byte name;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("cannot write %scurrent: %r", THEMEDIR);
	return nil;
}

# How often a watcher looks at the current file. A switch is seen
# within this; the cost is one small read per watcher per interval.
Pollms: con 1000;

watch(): chan of string
{
	sys = load Sys Sys->PATH;
	c := chan[1] of string;
	spawn watcher(c, current());
	return c;
}

watcher(c: chan of string, last: string)
{
	for(;;){
		sys->sleep(Pollms);
		name := current();
		if(name == last)
			continue;
		last = name;
		# never block on a slow reader: one pending change is enough,
		# since the reader loads whatever is current when it gets to it
		alt {
		c <-= name =>
			;
		* =>
			;
		}
	}
}

# the user's theme directory is bound over the system's: a name can
# appear in both
member(s: string, a: array of string): int
{
	for(i := 0; i < len a; i++)
		if(a[i] == s)
			return 1;
	return 0;
}

themes(): list of string
{
	sys = load Sys Sys->PATH;
	fd := sys->open(THEMEDIR, Sys->OREAD);
	if(fd == nil)
		return nil;
	names: array of string;
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			if(validname(d[i].name) && (d[i].mode & Sys->DMDIR) == 0 && !member(d[i].name, names)){
				a := array[len names + 1] of string;
				a[0:] = names;
				a[len names] = d[i].name;
				names = a;
			}
	}
	# insertion sort: a handful of names
	for(i := 1; i < len names; i++)
		for(j := i; j > 0 && names[j] < names[j-1]; j--)
			(names[j], names[j-1]) = (names[j-1], names[j]);
	l: list of string;
	for(i = len names - 1; i >= 0; i--)
		l = names[i] :: l;
	return l;
}
