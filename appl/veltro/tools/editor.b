implement ToolEditor;

#
# editor - Veltro tool for controlling the Edit text editor
#
# Provides AI control over the Edit editor via its 9P filesystem,
# posted as #seditor/fs and mounted at /mnt/editor by tools9p for this
# tool alone. Supports reading/writing document body, cursor
# positioning, search, and file operations. A command is carried out
# before its write returns, and one the editor refuses is an error.
# Files are read and written here, in the tool's name space (open,
# save): the editor is given text and a name to show, and opens and
# saves nothing the agent names.
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

EDIT_ROOT: con "/mnt/editor";

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
		"How it works: The Editor app serves its document as files\n" +
		"(posted as #seditor/fs, mounted at /mnt/editor for this tool).\n" +
		"A command is done when it returns; one refused is an error.\n\n" +
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
		"\"description\":\"Remote-control a running Editor app (launch with 'launch editor' first). Its document is served as files; a command is done when it returns.\"," +
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
		(body, err) := readfile(sys->sprint("%s/1/body", EDIT_ROOT));
		if(err != nil)
			return err;
		return body;
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
	# a write of body replaces the text
	return writefile(sys->sprint("%s/1/body", EDIT_ROOT), text);
}

doappend(text: string): string
{
	if(text == "")
		return "error: usage: append <text>";
	(body, err) := readfile(sys->sprint("%s/1/body", EDIT_ROOT));
	if(err != nil)
		return err;
	return writefile(sys->sprint("%s/1/body", EDIT_ROOT), body + text);
}

# The files a document is read from and saved to are opened here, in the
# tool's name space, which is the agent's: the editor is given the text
# (its body file) and told the name to show ("remote"), and reads and
# writes no file of the agent's choosing itself.  The editor is the
# user's program in the user's name space.  It used to be told "open
# <path>" and "save", after checks made here on the path's spelling: but
# there a path is another file (another activity's scratch directory,
# the real file under an overlay), nothing is read-only, and its quit
# saved a changed document under the name it had been given, so open,
# write and close wrote any file the agent could see.

dosave(): string
{
	path := currentpath();
	if(path == "")
		return "error: the document has no name (give it one with: name <path>)";
	err := checkwritable(path);
	if(err != nil)
		return err;
	(body, rerr) := readfile(sys->sprint("%s/1/body", EDIT_ROOT));
	if(rerr != nil)
		return rerr;
	fd := sys->create(path, Sys->OWRITE, 8r664);
	if(fd == nil)
		return sys->sprint("error: cannot create %s: %r", path);
	b := array of byte body;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("error: writing %s: %r", path);
	fd = nil;
	# tell the editor, which marks the document saved if the name is ours
	writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "saved " + path);
	return "ok";
}

doopen(path: string): string
{
	path = strip(path);
	if(path == "")
		return "error: usage: open <path>";
	err := validatepath(path);
	if(err != nil)
		return "error: invalid path: " + err;
	(ok, d) := sys->stat(path);
	if(ok < 0)
		return sys->sprint("error: path is outside the agent namespace: %s", path);
	if(d.mode & Sys->DMDIR)
		return sys->sprint("error: cannot open directory: %s", path);
	if(d.length > big MAXFILE)
		return sys->sprint("error: %s is too large to open in the editor (%bd bytes)", path, d.length);
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r", path);
	text := array[0] of byte;
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return sys->sprint("error: reading %s: %r", path);
		if(n == 0)
			break;
		if(len text + n > MAXFILE)
			return sys->sprint("error: %s is too large to open in the editor", path);
		nt := array[len text + n] of byte;
		nt[0:] = text;
		nt[len text:] = buf[0:n];
		text = nt;
	}
	fd = nil;
	r := writebytes(sys->sprint("%s/1/body", EDIT_ROOT), text);
	if(r != "ok")
		return r;
	r = writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "remote " + path);
	if(r != "ok")
		return r;
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "clean");
}

dogoto(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: usage: goto <line>";
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "goto " + args);
}

dofind(args: string): string
{
	if(args == "")
		return "error: usage: find <string>";
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "find " + args);
}

doreplacecmd(args: string): string
{
	# replace <find> <repl>
	# Split on first space: find term, rest is replacement
	(find, repl) := splitfirst(args);
	if(find == "")
		return "error: usage: replace <find> <replacement>";
	# Use tab separator for ctl command
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "replace " + find + "\t" + repl);
}

doreplaceallcmd(args: string): string
{
	(find, repl) := splitfirst(args);
	if(find == "")
		return "error: usage: replaceall <find> <replacement>";
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "replaceall " + find + "\t" + repl);
}

doaddr(): string
{
	(addr, err) := readfile(sys->sprint("%s/1/addr", EDIT_ROOT));
	if(err != nil)
		return err;
	return addr;
}

doinsert(args: string): string
{
	if(args == "")
		return "error: usage: insert <line> <col> <text>";
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "insert " + args);
}

dodelete(args: string): string
{
	if(args == "")
		return "error: usage: delete <startline> <startcol> <endline> <endcol>";
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "delete " + args);
}

doname(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: usage: name <path>";
	err := checkwritable(args);
	if(err != nil)
		return err;
	return writectl(sys->sprint("%s/1/ctl", EDIT_ROOT), "remote " + args);
}

doclose(): string
{
	# The editor's quit saves nothing, and refuses with changes unsaved.
	r := writectl(sys->sprint("%s/ctl", EDIT_ROOT), "quit");
	if(contains(r, "hungup"))
		return "ok";	# it went before it answered
	if(contains(r, "unsaved changes"))
		return "error: the document has unsaved changes: save it first " +
			"(save, after name <path> if it has no name), or leave closing it to the user";
	return r;
}

dostatus(): string
{
	(idx, err) := readfile(sys->sprint("%s/index", EDIT_ROOT));
	if(err != nil)
		return err;
	return idx;
}

# --- I/O helpers ---

# A file's text, or why it cannot be had.  (The error used to come back
# as the text, told from it by its first six characters: a document
# beginning "error:" could not be appended to.)
readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, notrunning(path));

	result := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return (nil, sys->sprint("error: reading %s: %r", path));
		if(n == 0)
			break;
		result += string buf[0:n];
	}
	fd = nil;
	return (result, nil);
}

writefile(path, data: string): string
{
	return writebytes(path, array of byte data);
}

writebytes(path: string, b: array of byte): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return notrunning(path);
	n := sys->write(fd, b, len b);
	fd = nil;
	if(n != len b)
		return editorerr();
	return "ok";
}

# One request to one of the editor's ctl files.  A request is one 9P
# message: a longer write is sent as several, and the ones after the
# first begin with whatever of the caller's text falls there, so one that
# does not fit is refused here (the body file takes text of any length).
MAXCTL: con 4096;

writectl(path, req: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return notrunning(path);
	b := array of byte req;
	iou := sys->iounit(fd);
	if(len b > MAXCTL || (iou > 0 && len b >= iou))
		return sys->sprint("error: too long for one editor command (%d bytes; the limit is %d): " +
			"use write or append for text of that size", len b, MAXCTL);
	n := sys->write(fd, b, len b);
	fd = nil;
	if(n != len b)
		return editorerr();
	return "ok";
}

# The editor's refusals already begin "error:".
editorerr(): string
{
	e := sys->sprint("%r");
	if(len e >= 6 && e[0:6] == "error:")
		return e;
	return "error: " + e;
}

# The editor's files are there only while it runs (tools9p mounts its
# posted server for this tool).
notrunning(path: string): string
{
	(ok, nil) := sys->stat(EDIT_ROOT + "/ctl");
	if(ok < 0)
		return "error: the editor is not running (start it with 'launch editor')";
	return sys->sprint("error: cannot open %s: %r", path);
}

currentpath(): string
{
	(idx, err) := readfile(sys->sprint("%s/index", EDIT_ROOT));
	if(err != nil)
		return "";
	(nil, rest) := splitfirst(idx);
	for(i := len rest - 1; i >= 0; i--)
		if(rest[i] == ' ' || rest[i] == '\t' || rest[i] == '\n')
			return strip(rest[0:i]);
	return "";
}

# The largest file open reads into the editor.
MAXFILE: con 4*1024*1024;

# What the write and edit tools ask before they write: the path is in
# the activity's scratch directory or under an rw grant.  The file is
# then created here, in the tool's own name space, where the scratch
# directory is the activity's own and a read-only grant is read-only.
checkwritable(path: string): string
{
	perr := validatepath(path);
	if(perr != nil)
		return "error: invalid path: " + perr;

	tmp := "/tmp/veltro/scratch";
	if(len path >= len tmp && path[0:len tmp] == tmp &&
	   (len path == len tmp || path[len tmp] == '/'))
		return nil;

	fd := sys->open("/tool/paths", Sys->OREAD);
	if(fd == nil)
		return "error: cannot verify writable path grants";
	# all of it: one read gives at most a 9P message, so grants past 8K
	# were not seen, a narrower "ro" among them
	raw := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n < 0)
			return "error: cannot read writable path grants";
		if(n == 0)
			break;
		raw += string buf[0:n];
		if(len raw > 1024*1024)
			return "error: writable path grants exceed limit";
	}

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

# Reject path forms whose lexical spelling can escape a namespace grant.
validatepath(path: string): string
{
	if(path == nil || len path == 0)
		return "empty path";
	if(path[0] != '/')
		return "path must be absolute";
	for(i := 0; i < len path; i++)
		if(path[i] == ' ' || path[i] == '\n' || path[i] == '\r' ||
		   path[i] == '\t' || path[i] == ',' || path[i] == '=')
			return "path contains control delimiter";
	start := 1;
	for(i = 1; i <= len path; i++) {
		if(i == len path || path[i] == '/') {
			comp := path[start:i];
			if(comp == "")
				return "empty path component";
			if(comp == "." || comp == "..")
				return "dot path component";
			start = i + 1;
		}
	}
	return nil;
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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i + len sub] == sub)
			return 1;
	return 0;
}
