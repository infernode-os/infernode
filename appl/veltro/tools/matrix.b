implement ToolMatrix;

#
# matrix - Veltro tool for the Matrix compositional module runtime
#
# A thin file-operation wrapper over the Matrix control filesystem
# at /mnt/matrix.  Matrix modules are typed Limbo .dis programs; the
# agent never loads code directly — it reads contracts and writes
# composition text, and the runtime does the rest.
#
# Discovery follows the man-pages-versus-stories convention:
#   index          the whatis-style scan surface (one line per module)
#   man <module>   the module's contract: what it reads and writes
#   library        pinned compositions (crystallised arrangements)
#   story <name>   a pinned composition's text, header comment first
#
# Commands:
#   index                Read the module index
#   man <module>         Read a module's contract page
#   library              List pinned compositions
#   story <name>         Read a pinned composition
#   status               Runtime status and loaded modules
#   composition          Read the live composition
#   compose <text>       Write a new composition (incremental reload)
#   ctl <verb ...>       load <name> | load - | unload | pin <name> | unpin <name>
#   out <module> [file]  List or read a service module's outputs
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "readdir.m";
	readdir: Readdir;

include "../tool.m";

ToolMatrix: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

MATRIX: con "/mnt/matrix";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	readdir = load Readdir Readdir->PATH;
	if(readdir == nil)
		return "cannot load Readdir";
	return nil;
}

name(): string
{
	return "matrix";
}

doc(): string
{
	return "Matrix - compose typed modules over the control filesystem\n\n" +
		"Commands:\n" +
		"  index                Scan the module library (one line per module)\n" +
		"  man <module>         Read a module's contract (READS/WRITES)\n" +
		"  library              List pinned compositions\n" +
		"  story <name>         Read a pinned composition's text\n" +
		"  status               Runtime status and loaded modules\n" +
		"  composition          Read the live composition\n" +
		"  compose <text>       Write a composition; ';' separates lines\n" +
		"  ctl <verb ...>       load <name> | load - | unload | pin <name> | unpin <name>\n" +
		"  out <module> [file]  List or read a service's outputs\n\n" +
		"Workflow: scan the index, open the man page of a candidate,\n" +
		"compose against its contract, consume its out/ files.\n" +
		"Matrix must be running (launch matrix, or wm/matrix -h).\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"matrix\"," +
		"\"description\":\"Compose and control Matrix modules through the /mnt/matrix control filesystem. Discovery: 'index' scans the module library (whatis-style, one line per module); 'man <module>' returns a module's contract (what it reads and writes). Compositions: 'library' lists pinned compositions, 'story <name>' reads one, 'composition' reads the live one, 'compose <text>' writes a new one (';' separates lines), 'ctl load <name>|unload|pin <name>' manages the runtime. 'out <module> [file]' reads a service module's outputs. Matrix must be running.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"One of: index, man, library, story, status, composition, compose, ctl, out.\"}," +
				"\"args\":{\"type\":\"string\",\"description\":\"Command argument: module name for man/out, composition name for story/ctl verbs, composition text for compose (';' separates lines).\"}" +
			"}," +
			"\"required\":[\"command\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil) {
		err := init();
		if(err != nil)
			return "error: " + err;
	}

	args = strip(args);
	if(args == "")
		return "error: no command.\n\n" + doc();

	(cmd, rest) := splitfirst(args);
	cmd = str->tolower(cmd);

	case cmd {
	"index" =>
		return readfile(MATRIX + "/library/index");
	"man" =>
		m := strip(rest);
		if(m == "")
			return "error: man needs a module name (see 'matrix index')";
		if(!safeleaf(m))
			return "error: unsafe module name";
		return readfile(MATRIX + "/library/man/" + m);
	"library" =>
		return lsdir(MATRIX + "/library/compositions");
	"story" =>
		nm := strip(rest);
		if(nm == "")
			return "error: story needs a composition name (see 'matrix library')";
		if(!safeleaf(nm))
			return "error: unsafe composition name";
		return readfile(MATRIX + "/library/compositions/" + nm);
	"status" =>
		return dostatus();
	"composition" =>
		return readfile(MATRIX + "/composition");
	"compose" =>
		return docompose(rest);
	"ctl" =>
		verb := strip(rest);
		if(verb == "")
			return "error: ctl needs a verb: load <name> | load - | unload | pin <name> | unpin <name>";
		err := validctl(verb);
		if(err != nil)
			return "error: " + err;
		return writectl(verb);
	"out" =>
		return doout(rest);
	* =>
		return sys->sprint("error: unknown command '%s'.\n\n%s", cmd, doc());
	}
}

dostatus(): string
{
	st := readfile(MATRIX + "/ctl");
	if(hasprefix(st, "error:"))
		return st + "\nMatrix is not running; start it with 'launch matrix' or wm/matrix -h <composition>";
	r := "runtime: " + strip(st) + "\n";
	(ents, n) := readdir->init(MATRIX + "/modules", Readdir->NAME);
	for(i := 0; i < n; i++) {
		nm := ents[i].name;
		mtype := strip(readfile(MATRIX + "/modules/" + nm + "/type"));
		mctl := strip(readfile(MATRIX + "/modules/" + nm + "/ctl"));
		mnt := strip(readfile(MATRIX + "/modules/" + nm + "/mount"));
		r += sys->sprint("%s\t%s\t%s\t%s\n", nm, mtype, mctl, mnt);
	}
	if(n == 0)
		r += "(no modules loaded)\n";
	return r;
}

docompose(text: string): string
{
	text = strip(text);
	if(text == "")
		return "error: compose needs composition text (';' separates lines)";
	# The ctl-line transport is single-line; accept ';' as a line
	# separator when the text carries no real newlines.
	if(!contains(text, "\n")) {
		out := "";
		(nil, parts) := sys->tokenize(text, ";");
		for(; parts != nil; parts = tl parts)
			out += strip(hd parts) + "\n";
		text = out;
	}
	if(writestr(MATRIX + "/composition", text) < 0)
		return sys->sprint("error: composition write failed: %r");
	return "composition written; reload applied.\n\n" + readfile(MATRIX + "/composition");
}

writectl(verb: string): string
{
	if(writestr(MATRIX + "/ctl", verb) < 0)
		return sys->sprint("error: ctl write failed: %r");
	return "ok: " + verb;
}

doout(rest: string): string
{
	(m, file) := splitfirst(rest);
	if(m == "")
		return "error: out needs a module name";
	if(!safeleaf(m))
		return "error: unsafe module name";
	base := MATRIX + "/modules/" + m + "/out";
	if(strip(file) == "")
		return lsdir(base);
	file = strip(file);
	if(!saferelpath(file))
		return "error: unsafe output file name";
	return readfile(base + "/" + file);
}

validctl(verb: string): string
{
	if(hascontrol(verb))
		return "ctl verb may not contain control text";
	(cmd, rest) := splitfirst(verb);
	cmd = str->tolower(cmd);
	rest = strip(rest);
	case cmd {
	"unload" =>
		if(rest != "")
			return "unload takes no arguments";
		return nil;
	"load" =>
		if(rest == "")
			return "load needs a composition name";
		if(rest == "-")
			return nil;
		if(!safeleaf(rest))
			return "unsafe composition name";
		return nil;
	"pin" or "unpin" =>
		if(rest == "")
			return cmd + " needs a composition name";
		if(!safeleaf(rest))
			return "unsafe composition name";
		return nil;
	}
	return "unknown ctl verb";
}

# --- I/O helpers ---

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r", path);
	result := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
	}
	return result;
}

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

lsdir(path: string): string
{
	(ents, n) := readdir->init(path, Readdir->NAME);
	if(n < 0)
		return sys->sprint("error: cannot read %s: %r", path);
	r := "";
	for(i := 0; i < n; i++)
		r += ents[i].name + "\n";
	if(r == "")
		r = "(empty)\n";
	return r;
}

# --- String helpers ---

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

splitfirst(s: string): (string, string)
{
	s = strip(s);
	for(i := 0; i < len s; i++) {
		if(s[i] == ' ' || s[i] == '\t')
			return (s[0:i], strip(s[i:]));
	}
	return (s, "");
}

hasprefix(s, pre: string): int
{
	return len s >= len pre && s[0:len pre] == pre;
}

safeleaf(s: string): int
{
	if(s == "" || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.')
			continue;
		return 0;
	}
	return 1;
}

saferelpath(s: string): int
{
	if(s == "" || s[0] == '/' || hascontrol(s))
		return 0;
	part := "";
	for(i := 0; i <= len s; i++) {
		if(i == len s || s[i] == '/') {
			if(!safeleaf(part))
				return 0;
			part = "";
			continue;
		}
		part[len part] = s[i];
	}
	return 1;
}

hascontrol(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || s[i] == '\r' || s[i] == '\t' || s[i] < ' ')
			return 1;
	return 0;
}

contains(s, sub: string): int
{
	if(len sub == 0)
		return 1;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}
