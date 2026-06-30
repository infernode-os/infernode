implement ToolEditor;

#
# editor - Veltro tool for controlling the Edit text editor
#
# Provides AI control over the Edit editor via its 9P filesystem
# interface at /edit/. Supports reading/writing document body, cursor
# positioning, search, and file operations.
#
# Commands:
#   read [body|addr]           Read document body or cursor address
#   write <text>               Replace document body
#   append <text>              Append text to body
#   save                       Save current file
#   open <path>                Open file in editor
#   goto <line>                Move cursor to line
#   find <string>              Search for text
#   replace <find> <repl>      Replace next occurrence
#   replaceall <find> <repl>   Replace all occurrences
#   addr                       Get cursor position
#   insert <line> <col> <text> Insert text at position
#   delete <sl> <sc> <el> <ec> Delete range
#   name <path>                Set file path
#   close                      Close editor
#   status                     Show editor status
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolEditor: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

EDIT_ROOT: con "/tmp/veltro/editor";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "editor";
}

doc(): string
{
	return "editor - AI remote control for the Editor app\n\n" +
		"NOTE: This tool does NOT launch the editor. To START the editor,\n" +
		"use the launch tool: 'launch editor'. This tool sends commands\n" +
		"to an editor that is already visible in the presentation zone.\n\n" +
		"How it works: The Editor app exposes its state as files under\n" +
		"/tmp/veltro/editor/. This tool reads and writes those files.\n" +
		"The editor polls for commands every 500ms.\n\n" +
		"Commands (only work after 'launch editor'):\n" +
		"  read [body]              Read document body text\n" +
		"  read addr                Read cursor position\n" +
		"  write <text>             Replace entire document body\n" +
		"  append <text>            Append text to body\n" +
		"  save                     Save current file\n" +
		"  open <path>              Open file in editor\n" +
		"  goto <line>              Move cursor to line\n" +
		"  find <string>            Search for text\n" +
		"  replace <find> <repl>    Replace next match\n" +
		"  replaceall <find> <repl> Replace all matches\n" +
		"  insert <ln> <col> <text> Insert text at position\n" +
		"  delete <sl> <sc> <el> <ec>  Delete range\n" +
		"  close                    Close editor (quit)\n" +
		"  status                   Show document info\n\n" +
		"Typical workflow:\n" +
		"  launch editor                  1. Start the editor app\n" +
		"  editor open /usr/me/file.b     2. Open a file\n" +
		"  editor read                    3. Read the document\n" +
		"  editor write Hello world       4. Replace body\n" +
		"  editor save                    5. Save to disk\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"editor\"," +
		"\"description\":\"Remote-control a running Editor app (launch with 'launch editor' first). Reads and writes /tmp/veltro/editor/ control files at ~500ms polling.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"One of: read, write, append, save, open, goto, find, replace, replaceall, addr, insert, delete, name, close, status.\"}," +
				"\"args\":{\"type\":\"string\",\"description\":\"Command-specific. For read: [body|addr]. For write/append: <text>. For open: <path>. For goto: <line>. For find: <string>. For replace/replaceall: <find> <repl>. For insert: <line> <col> <text>. For delete: <startline> <startcol> <endline> <endcol>. Omit for save/close/status.\"}" +
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
		return "error: no command. Use: read, write, append, save, open, goto, find, replace, replaceall, addr, insert, delete, name, close, status";

	(cmd, rest) := splitfirst(args);
	cmd = str->tolower(cmd);

	case cmd {
	"read" =>
		return doread(rest);
	"write" =>
		return dowrite(rest);
	"append" =>
		return doappend(rest);
	"save" =>
		return dosave();
	"open" =>
		return doopen(rest);
	"goto" =>
		return dogoto(rest);
	"find" =>
		return dofind(rest);
	"replace" =>
		return doreplacecmd(rest);
	"replaceall" =>
		return doreplaceallcmd(rest);
	"addr" =>
		return doaddr();
	"insert" =>
		return doinsert(rest);
	"delete" =>
		return dodelete(rest);
	"name" =>
		return doname(rest);
	"close" =>
		return doclose();
	"status" =>
		return dostatus();
	* =>
		return sys->sprint("error: unknown command '%s'", cmd);
	}
}

doread(args: string): string
{
	target := strip(args);
	if(target == "" || target == "body") {
		return readfile(sys->sprint("%s/1/body", EDIT_ROOT));
	}
	if(target == "addr") {
		return doaddr();
	}
	return sys->sprint("error: read target must be 'body' or 'addr'; got %q. " +
		"To read the document text, use 'read body'. " +
		"To read cursor position, use 'read addr'.", target);
}

dowrite(text: string): string
{
	if(text == "")
		return "error: usage: write <text>";
	# Write to body.in — edit polls this and replaces its buffer
	return writefile(sys->sprint("%s/1/body.in", EDIT_ROOT), text);
}

doappend(text: string): string
{
	if(text == "")
		return "error: usage: append <text>";
	# Read current state, append, submit via body.in
	body := readfile(sys->sprint("%s/1/body", EDIT_ROOT));
	if(len body >= 6 && body[0:6] == "error:")
		return body;
	newbody := body + text;
	return writefile(sys->sprint("%s/1/body.in", EDIT_ROOT), newbody);
}

dosave(): string
{
	path := currentpath();
	if(path == "")
		return "error: editor has no current file";
	err := checkwritable(path);
	if(err != nil)
		return err;
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "save");
}

doopen(path: string): string
{
	path = strip(path);
	if(path == "")
		return "error: usage: open <path>";
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return sys->sprint("error: path is outside the agent namespace: %s", path);
	if(d.mode & Sys->DMDIR)
		return sys->sprint("error: cannot open directory: %s", path);
	return writefile(sys->sprint("%s/ctl", EDIT_ROOT), "open " + path);
}

dogoto(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: usage: goto <line>";
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "goto " + args);
}

dofind(args: string): string
{
	if(args == "")
		return "error: usage: find <string>";
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "find " + args);
}

doreplacecmd(args: string): string
{
	# replace <find> <repl>
	# Split on first space: find term, rest is replacement
	(find, repl) := splitfirst(args);
	if(find == "")
		return "error: usage: replace <find> <replacement>";
	# Use tab separator for ctl command
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "replace " + find + "\t" + repl);
}

doreplaceallcmd(args: string): string
{
	(find, repl) := splitfirst(args);
	if(find == "")
		return "error: usage: replaceall <find> <replacement>";
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "replaceall " + find + "\t" + repl);
}

doaddr(): string
{
	return readfile(sys->sprint("%s/1/addr", EDIT_ROOT));
}

doinsert(args: string): string
{
	if(args == "")
		return "error: usage: insert <line> <col> <text>";
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "insert " + args);
}

dodelete(args: string): string
{
	if(args == "")
		return "error: usage: delete <startline> <startcol> <endline> <endcol>";
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "delete " + args);
}

doname(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: usage: name <path>";
	err := checkwritable(args);
	if(err != nil)
		return err;
	return writefile(sys->sprint("%s/1/ctl", EDIT_ROOT), "name " + args);
}

doclose(): string
{
	return writefile(sys->sprint("%s/ctl", EDIT_ROOT), "quit");
}

dostatus(): string
{
	return readfile(sys->sprint("%s/index", EDIT_ROOT));
}

# --- I/O helpers ---

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r (is edit running?)", path);

	result := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		result += string buf[0:n];
	}
	fd = nil;
	return result;
}

writefile(path, data: string): string
{
	# Use create to handle both new files (ctl, body.in) and existing ones
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd == nil)
		return sys->sprint("error: cannot create %s: %r (is edit running?)", path);

	b := array of byte data;
	n := sys->write(fd, b, len b);
	fd = nil;

	if(n != len b)
		return sys->sprint("error: write failed: %r");

	return "ok";
}

currentpath(): string
{
	idx := readfile(sys->sprint("%s/index", EDIT_ROOT));
	if(len idx >= 6 && idx[0:6] == "error:")
		return "";
	(nil, rest) := splitfirst(idx);
	for(i := len rest - 1; i >= 0; i--)
		if(rest[i] == ' ' || rest[i] == '\t' || rest[i] == '\n')
			return strip(rest[0:i]);
	return "";
}

# Mirror write/edit capability enforcement before asking the unrestricted GUI
# process to choose a save target.
checkwritable(path: string): string
{
	tmp := "/tmp/veltro";
	if(len path >= len tmp && path[0:len tmp] == tmp &&
	   (len path == len tmp || path[len tmp] == '/'))
		return nil;

	fd := sys->open("/tool/paths", Sys->OREAD);
	if(fd == nil)
		return "error: cannot verify writable path grants";
	buf := array[65536] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return "error: cannot read writable path grants";
	if(n == len buf)
		return "error: writable path grants exceed limit";
	raw := string buf[0:n];

	bestlen := -1;
	bestperm := "";
	i := 0;
	while(i < len raw) {
		j := i;
		while(j < len raw && raw[j] != '\n')
			j++;
		line := raw[i:j];
		i = j + 1;
		if(line == "")
			continue;
		sp := -1;
		for(k := len line - 1; k > 0; k--)
			if(line[k] == ' ') { sp = k; break; }
		if(sp < 0)
			continue;
		bpath := line[0:sp];
		perm := line[sp+1:];
		if((perm == "ro" || perm == "rw") && len bpath > bestlen &&
		   len path >= len bpath && path[0:len bpath] == bpath &&
		   (len path == len bpath || path[len bpath] == '/')) {
			bestlen = len bpath;
			bestperm = perm;
		}
	}
	if(bestperm == "rw")
		return nil;
	if(bestperm == "ro")
		return sys->sprint("error: %s is read-only", path);
	return sys->sprint("error: %s is not covered by an rw path grant", path);
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
