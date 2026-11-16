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

	perr := prevalidate(cmd, rest);
	if(perr != nil)
		return "error: " + perr;

	# Every command operates on the runtime's control filesystem at /mnt/matrix.
	# If the runtime is not running that filesystem is absent, and each command
	# would otherwise fail with a raw "file does not exist" — which sends the
	# agent thrashing around the namespace hunting for matrix. Detect it once and
	# return a single clear, actionable message instead.
	if(!running())
		return "Matrix is not running: its control filesystem at /mnt/matrix is " +
			"not mounted, so there is nothing to compose against yet. Start the " +
			"runtime first — if you have the 'launch' tool, run:  launch matrix  " +
			"(or wm/matrix -h <composition> for a headless run); otherwise report " +
			"to the user that Matrix must be started before it can be explored. " +
			"Once it is running, retry (start with 'matrix index').";

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

prevalidate(cmd, rest: string): string
{
	case cmd {
	"man" =>
		m := strip(rest);
		if(m != "" && !safeleaf(m))
			return "unsafe module name";
	"story" =>
		nm := strip(rest);
		if(nm != "" && !safeleaf(nm))
			return "unsafe composition name";
	"compose" =>
		cerr := agentcomposepolicy(rest);
		if(cerr != nil)
			return cerr;
	"ctl" =>
		verb := strip(rest);
		if(verb != "") {
			err := validctl(verb);
			if(err != nil)
				return err;
		}
	"out" =>
		(m, file) := splitfirst(rest);
		if(m != "" && !safeleaf(m))
			return "unsafe module name";
		file = strip(file);
		if(file != "" && !saferelpath(file))
			return "unsafe output file name";
	}
	return nil;
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
	text = normalizecompose(text);
	if(len text == 0 || text[len text - 1] != '\n')
		text += "\n";
	cerr := agentcomposepolicy(text);
	if(cerr != nil)
		return "error: " + cerr;
	# The runtime takes a composition as one 9P message.  A longer one
	# was sent as several, and each could be taken for a composition of
	# its own: its lines as checked above were not the lines loaded.
	if(len array of byte text > MAXCOMPOSE)
		return sys->sprint("error: composition too long (%d bytes; the limit is %d)",
			len array of byte text, MAXCOMPOSE);
	if(writestr(MATRIX + "/composition", text) < 0)
		return sys->sprint("error: composition write failed: %r");
	# The runtime loads it after the write returns, and keeps the old
	# one if it does not parse: say which happened.  (It said "reload
	# applied" whatever the runtime did.)
	live := "";
	for(i := 0; i < 50; i++) {
		live = readfile(MATRIX + "/composition");
		if(same(live, text))
			return "composition written; reload applied.\n\n" + live;
		sys->sleep(100);
	}
	return "error: composition written, but the runtime has not loaded it " +
		"(a line it does not accept, or a reload still running); the live composition is:\n\n" + live;
}

MAXCOMPOSE: con 7000;

same(a, b: string): int
{
	return strip(a) == strip(b);
}

# What an agent may compose.  The runtime's grammar (matrixlib) is the
# guide, read as strictly as the runtime reads it: a line is a comment,
# a layout, a split of a region, a display module in a region, a service,
# a watch or one of its arms, and anything else is refused.  (Only lines
# that began "service", "layout" or "watch", in those letters, were
# looked at; the rest was let through, and arms with a blank in them,
# which is most, were refused as display modules.)
#
# A composition is written into Matrix's name space, which is the
# user's, and two kinds of line bring something of it back to the agent:
# a service, whose outputs the agent reads with "out", and a watch,
# whose arms tell it what a file holds.  Both may name only Matrix's own
# data, /tmp/matrix, or be a line the live composition already has: a
# grant the user loaded (ctl load <name>) may be kept, not made.  A
# service was refused the mount / and given any other: /prog, the whole
# process table, /mnt/llm.  Hosting an app is never an agent's line.
agentcomposepolicy(text: string): string
{
	text = normalizecompose(text);
	live := "";
	if(running())
		live = readfile(MATRIX + "/composition");
	inwatch := 0;
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines) {
		line := strip(hd lines);
		if(line == "" || line[0] == '#')
			continue;
		for(ci := 0; ci < len line; ci++)
			if(line[ci] < ' ' && line[ci] != '\t')
				return "control text in a composition line";
		if(inwatch) {
			a := findarrow(line);
			if(a >= 0) {
				if(strip(line[0:a]) == "")
					return "watch arm with no pattern";
				aerr := validaction(strip(line[a+2:]));
				if(aerr != nil)
					return aerr;
				continue;
			}
			inwatch = 0;
		}
		(n, toks) := sys->tokenize(line, " \t");
		first := hd toks;
		rest := tl toks;
		case first {
		"watch" =>
			if(n != 2)
				return "watch needs: path";
			if(!safeabspath(hd rest))
				return "unsafe watch path";
			if(!matrixdata(hd rest) && !haslive(live, line))
				return "an agent's watch reads Matrix's own data (/tmp/matrix/...): " + hd rest;
			inwatch = 1;
		"layout" =>
			if(n != 4 || !orient(hd rest) || !ratio(hd tl rest) || !ratio(hd tl tl rest))
				return "layout needs: hsplit|vsplit ratio ratio";
		"service" =>
			if(n != 3)
				return "service needs: name mount";
			if(!safeleaf(hd rest))
				return "unsafe service module name";
			mount := hd tl rest;
			if(!safeabspath(mount))
				return "unsafe service mount path";
			if(mount == "/" && !haslive(live, line))
				return "service whole-namespace grants are not agent-composeable " +
					"(one the live composition already has may be kept: ctl load <name> first)";
			if(!matrixdata(mount) && !haslive(live, line))
				return "service mount " + mount + " is not agent-composeable: an agent's service " +
					"mounts Matrix's own data (/tmp/matrix/...), or is one the live composition " +
					"already has (load a library composition first: ctl load <name>)";
		* =>
			if(!saferegion(first))
				return "unrecognized line: " + line;
			if(rest != nil && hd rest == "app")
				return "app hosting is not agent-composeable";
			if(n == 4 && orient(hd rest)) {
				if(!ratio(hd tl rest) || !ratio(hd tl tl rest))
					return first + ": split needs: hsplit|vsplit ratio ratio";
			} else if(n == 3) {
				if(!safeleaf(hd rest))
					return "unsafe matrix module name";
				if(!safeabspath(hd tl rest))
					return "unsafe matrix mount path";
			} else
				return "display module needs: region name mount";
		}
	}
	return nil;
}

# Under Matrix's own data directory, where its services write.
matrixdata(path: string): int
{
	d := "/tmp/matrix";
	return path == d || hasprefix(path, d + "/");
}

# The live composition has this line (its words, whatever the blanks).
haslive(live, line: string): int
{
	(nil, want) := sys->tokenize(line, " \t");
	(nil, lines) := sys->tokenize(live, "\n");
	for(; lines != nil; lines = tl lines) {
		(nil, got) := sys->tokenize(hd lines, " \t");
		w := want;
		for(; got != nil && w != nil && hd got == hd w; got = tl got)
			w = tl w;
		if(got == nil && w == nil)
			return 1;
	}
	return 0;
}

orient(s: string): int
{
	return s == "hsplit" || s == "vsplit";
}

ratio(s: string): int
{
	if(s == "" || len s > 4)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

# left, right, top, bottom, and the halves of a split region: left/top
saferegion(s: string): int
{
	(nil, parts) := sys->tokenize(s, "/");
	if(parts == nil || s[0] == '/' || s[len s - 1] == '/' || contains(s, "//"))
		return 0;
	for(; parts != nil; parts = tl parts)
		case hd parts {
		"left" or "right" or "top" or "bottom" =>
			;
		* =>
			return 0;
		}
	return 1;
}

findarrow(s: string): int
{
	for(i := 0; i + 1 < len s; i++)
		if(s[i] == '-' && s[i+1] == '>')
			return i;
	return -1;
}

# A watch arm's action: what the runtime's ctl takes, and notify.
validaction(act: string): string
{
	(n, toks) := sys->tokenize(act, " \t");
	if(n == 0)
		return "watch arm with no action";
	case hd toks {
	"load" or "pin" =>
		if(n != 2 || !safeleaf(hd tl toks))
			return hd toks + " needs one composition name";
	"unload" =>
		if(n != 1)
			return "unload takes no arguments";
	"notify" =>
		if(n < 2)
			return "notify needs a message";
	* =>
		return "unknown watch action: " + hd toks;
	}
	return nil;
}

normalizecompose(text: string): string
{
	text = strip(text);
	if(contains(text, "\n"))
		return text;
	out := "";
	(nil, parts) := sys->tokenize(text, ";");
	for(; parts != nil; parts = tl parts)
		out += strip(hd parts) + "\n";
	return out;
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

# Is the Matrix runtime up? It serves /mnt/matrix/ctl only while running.
running(): int
{
	(ok, nil) := sys->stat(MATRIX + "/ctl");
	return ok >= 0;
}

# The most of a file that is given to the model: a service's output can
# be of any length, or never end.
MAXREAD: con 256*1024;

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r", path);
	result := "";
	total := 0;
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		total += n;
		if(total > MAXREAD)
			return result + sys->sprint("\n[cut at %d bytes]\n", MAXREAD);
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

safeabspath(s: string): int
{
	if(s == "" || s[0] != '/' || hascontrol(s))
		return 0;
	if(s == "/")
		return 1;
	part := "";
	for(i := 1; i <= len s; i++) {
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
