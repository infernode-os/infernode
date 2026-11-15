implement ToolGrep;

#
# grep - Regex search within files for Veltro agent
#
# Returns matching lines with file:line: content format.
# Operates on a single file or a directory (optionally recursive).
#
# Usage:
#   grep <pattern> <path>          # search file, or non-recursive dir search
#   grep -r <pattern> <path>       # recursive directory search
#   grep -l <pattern> <path>       # list matching files only (no line content)
#   grep -i <pattern> <path>       # case-insensitive match
#   grep -rl <pattern> <path>      # combine flags freely
#
# Examples:
#   grep runagent /appl/veltro/veltro.b
#   grep -r 'include.*sys.m' /appl/veltro
#   grep -rl TODO /appl
#   grep -i error /appl/veltro/tools/memory.b
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "regex.m";
	regex: Regex;
	Re: import regex;

include "string.m";
	str: String;

include "../tool.m";

ToolGrep: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

MAX_MATCHES:  con 200;
MAX_FILES:    con 500;
MAX_DEPTH:    con 20;
MAX_LINE_LEN: con 300;
MAX_SCAN:     con 20000;	# files looked into in one search
MAX_MATCHLINE: con 16384;	# characters of a line that are matched
OPEN_TIMEOUT: con 3000;	# ms — skip directories that block

# What one search has done, and may yet: shared by its calls.
Search: adt {
	scanned:	int;	# files looked into
	stopped:	int;	# the search gave up at MAX_SCAN or MAX_DEPTH
};

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	regex = load Regex Regex->PATH;
	if(regex == nil)
		return "cannot load Regex";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "grep";
}

doc(): string
{
	return "Grep - Regex search within files\n\n" +
		"Usage:\n" +
		"  grep <pattern> <path>          # search file or directory (non-recursive)\n" +
		"  grep -r <pattern> <path>       # recursive directory search\n" +
		"  grep -l <pattern> <path>       # list matching files only\n" +
		"  grep -i <pattern> <path>       # case-insensitive match\n" +
		"  grep -rl <pattern> <path>      # combine flags freely\n\n" +
		"Output: file:line: content  (max " + string MAX_MATCHES + " matches)\n" +
		"A search stops after " + string MAX_SCAN + " files, or " + string MAX_DEPTH + " directories down, and says so.\n\n" +
		"Regex: Plan 9 ERE — supports . * + ? | () [] [^] ^ $\n" +
		"  NO: \\d \\w \\s \\b {n,m} [[:class:]] lookahead/lookbehind\n" +
		"  NOTE: \\d etc are silently treated as literals (d, w, s)\n\n" +
		"Examples:\n" +
		"  grep runagent /appl/veltro/veltro.b\n" +
		"  grep -r 'include.*sys.m' /appl/veltro\n" +
		"  grep -rl TODO /appl\n" +
		"  grep -i error /appl/veltro/tools/memory.b";
}

schema(): string
{
	return "{" +
		"\"name\":\"grep\"," +
		"\"description\":\"Regex search within files. Output format: file:line: content. Plan 9 ERE syntax: . * + ? | () [] ^ $. Backslash classes like \\\\d are silently treated as literals.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"flags\":{\"type\":\"string\",\"description\":\"Optional flag bundle: -r (recursive), -l (list filenames only), -i (case insensitive). Combine freely, e.g. -rl. Omit for default behaviour.\"}," +
				"\"pattern\":{\"type\":\"string\",\"description\":\"Regular expression to match.\"}," +
				"\"path\":{\"type\":\"string\",\"description\":\"File or directory to search.\"}" +
			"}," +
			"\"required\":[\"pattern\",\"path\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	if(regex == nil)
		return "error: cannot load regex module";

	# Parse flags, pattern, and path
	rflag := 0;
	lflag := 0;
	iflag := 0;

	# Consume leading whitespace
	i := 0;
	while(i < len args && (args[i] == ' ' || args[i] == '\t'))
		i++;
	args = args[i:];

	# Collect flag bundles (e.g. -rl, -r, -i)
	while(len args > 0 && args[0] == '-') {
		(flag, rest) := splitarg(args);
		args = skipws(rest);
		if(flag == "-" || flag == "--")
			break;
		for(j := 1; j < len flag; j++) {
			case flag[j] {
			'r' =>	rflag = 1;
			'l' =>	lflag = 1;
			'i' =>	iflag = 1;
			* =>
				return "error: unknown flag -" + string flag[j];
			}
		}
	}

	# Next token is pattern
	(pattern, rest) := splitarg(args);
	if(pattern == "")
		return "error: usage: grep [-r] [-l] [-i] <pattern> <path>";

	# Next token is path
	(path, nil) := splitarg(skipws(rest));
	if(path == "")
		return "error: usage: grep [-r] [-l] [-i] <pattern> <path>";

	# For case-insensitive, lower the pattern and match against lowered lines
	matchpat := pattern;
	if(iflag)
		matchpat = str->tolower(pattern);

	# Compile regex
	(re, err) := regex->compile(matchpat, 0);
	if(re == nil)
		return "error: invalid pattern '" + pattern + "': " + err;

	# What cannot be searched is not "no matches": a path that does not
	# exist, or cannot be read, had the same answer as a file without
	# the pattern in it.
	(isdir, serr) := isdirtimeout(path, OPEN_TIMEOUT);
	if(isdir < 0)
		return "error: cannot search " + path + ": " + serr;

	# Dispatch
	srch := ref Search(0, 0);
	(results, nmatches, nfiles, truncated) := searchpath(re, path, rflag, lflag, iflag, 0, srch);

	if(nmatches == 0 && nfiles == 0) {
		if(srch.stopped)
			return sys->sprint("no matches found in the %d files looked into; the search stopped there, with more not looked into: search a smaller part", srch.scanned);
		return "no matches found";
	}

	# Reverse to restore original order
	rev: list of string;
	for(; results != nil; results = tl results)
		rev = hd results :: rev;

	out := "";
	for(r := rev; r != nil; r = tl r) {
		if(out != "")
			out += "\n";
		out += hd r;
	}

	# (said to be cut at MAX_MATCHES whatever had stopped the search,
	# and however many there were)
	if(srch.stopped)
		out += sys->sprint("\n... (the search stopped after looking into %d files; more were not looked into)", srch.scanned);
	else if(truncated && lflag)
		out += sys->sprint("\n... (stopped at %d files; there may be more)", nfiles);
	else if(truncated)
		out += sys->sprint("\n... (stopped at %d matches; there may be more)", nmatches);

	if(lflag)
		return sys->sprint("%d files:\n%s", nfiles, out);
	return sys->sprint("%d matches:\n%s", nmatches, out);
}

# Dispatch to file or directory search based on stat result
searchpath(re: Re, path: string, recursive, listonly, icase, depth: int, srch: ref Search):
	(list of string, int, int, int)
{
	(isdir, nil) := isdirtimeout(path, OPEN_TIMEOUT);
	if(isdir < 0)
		return (nil, 0, 0, 0);

	if(isdir == 0)
		return searchfile(re, path, path, listonly, icase, MAX_MATCHES, srch);

	# Directory — enumerate contents
	return searchdir(re, path, recursive, listonly, icase, depth, srch);
}

# Search a single file; returns (results, nmatches, nfiles, truncated)
# max is how many more matches the search may still report.
searchfile(re: Re, path, display: string, listonly, icase, max: int, srch: ref Search):
	(list of string, int, int, int)
{
	srch.scanned++;
	if(!istext(path))
		return (nil, 0, 0, 0);

	f := bufio->open(path, Sys->OREAD);
	if(f == nil)
		return (nil, 0, 0, 0);

	results: list of string;
	nmatches := 0;
	lineno := 0;
	filematched := 0;

	for(;;) {
		(line, eof) := getline(f);
		if(eof)
			break;
		lineno++;

		matchline := line;
		if(icase)
			matchline = str->tolower(line);

		m := regex->execute(re, matchline);
		if(m != nil) {
			filematched = 1;
			if(listonly) {
				results = display :: nil;
				nmatches = 1;
				break;
			}
			if(nmatches >= max) {
				f.close();
				return (results, nmatches, 1, 1);
			}
			if(len line > MAX_LINE_LEN)
				line = line[0:MAX_LINE_LEN] + "...";
			results = sys->sprint("%s:%d: %s", display, lineno, line) :: results;
			nmatches++;
		}
	}

	f.close();

	nfiles := 0;
	if(filematched)
		nfiles = 1;
	return (results, nmatches, nfiles, 0);
}

# Search a directory; recurse if recursive flag set
searchdir(re: Re, dirpath: string, recursive, listonly, icase, depth: int, srch: ref Search):
	(list of string, int, int, int)
{
	results: list of string;
	nmatches := 0;
	nfiles := 0;
	truncated := 0;

	# (the depth was tested where a search begins, at 0, and nowhere
	# below: a tree of directories without end was followed without end)
	if(depth > MAX_DEPTH) {
		srch.stopped = 1;
		return (nil, 0, 0, 0);
	}

	fd := opentimeout(dirpath, Sys->OREAD, OPEN_TIMEOUT);
	if(fd == nil)
		return (nil, 0, 0, 0);

	for(;;) {
		(nread, dirs) := sys->dirread(fd);
		if(nread <= 0)
			break;

		for(i := 0; i < nread; i++) {
			ent := dirs[i];
			name := ent.name;

			# a name a server gives that is no name of this directory
			if(name == "" || name == "." || name == ".." || hasslash(name))
				continue;

			# Skip hidden entries and known binary dirs
			if(name[0] == '.')
				continue;

			# A search is bounded by what it looks into, not only by
			# what it finds: with nothing to find it had no end.
			if(srch.scanned >= MAX_SCAN) {
				srch.stopped = 1;
				return (results, nmatches, nfiles, 1);
			}

			fullpath := joinpath(dirpath, name);

			if(ent.mode & Sys->DMDIR) {
				if(!recursive)
					continue;
				(sub, sm, sf, st) := searchdir(re, fullpath, recursive, listonly, icase, depth+1, srch);
				for(; sub != nil; sub = tl sub)
					results = hd sub :: results;
				nmatches += sm;
				nfiles += sf;
				if(st)
					truncated = 1;
			} else {
				# each file had MAX_MATCHES of its own, and one that
				# reached them was not counted as cutting the search
				(sub, sm, sf, st) := searchfile(re, fullpath, fullpath, listonly, icase, MAX_MATCHES - nmatches, srch);
				for(; sub != nil; sub = tl sub)
					results = hd sub :: results;
				nmatches += sm;
				nfiles += sf;
				if(st)
					truncated = 1;
			}

			if(nmatches >= MAX_MATCHES || nfiles >= MAX_FILES) {
				truncated = 1;
				return (results, nmatches, nfiles, truncated);
			}
		}
	}

	return (results, nmatches, nfiles, truncated);
}

hasslash(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '/')
			return 1;
	return 0;
}

# The next line without its newline, to MAX_MATCHLINE characters (the rest
# of a longer one is read and left out), and whether the file has ended.
# A line was read whole whatever its length: a file with no newline in it
# was held in memory entire.
getline(f: ref Iobuf): (string, int)
{
	c := f.getc();
	if(c == Bufio->EOF || c == Bufio->ERROR)
		return (nil, 1);
	line := "";
	while(c != '\n' && c != Bufio->EOF && c != Bufio->ERROR) {
		if(len line < MAX_MATCHLINE)
			line[len line] = c;
		c = f.getc();
	}
	return (line, 0);
}

# Split off one whitespace- or quote-delimited token from s
splitarg(s: string): (string, string)
{
	if(len s == 0)
		return ("", "");

	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;

	if(i >= len s)
		return ("", "");

	if(s[i] == '"' || s[i] == '\'') {
		q := s[i];
		i++;
		start := i;
		while(i < len s && s[i] != q)
			i++;
		tok := s[start:i];
		if(i < len s)
			i++;
		return (tok, s[i:]);
	}

	start := i;
	while(i < len s && s[i] != ' ' && s[i] != '\t')
		i++;
	return (s[start:i], s[i:]);
}

skipws(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	return s[i:];
}

joinpath(dir, name: string): string
{
	if(len dir > 0 && dir[len dir - 1] == '/')
		return dir + name;
	return dir + "/" + name;
}

# Check if a path is likely a text file worth searching
istext(path: string): int
{
	# Skip .dis (bytecode) files
	if(len path > 4 && path[len path - 4:] == ".dis")
		return 0;

	# Known text extensions
	if(len path >= 2) {
		ext2 := path[len path - 2:];
		if(ext2 == ".b" || ext2 == ".m" || ext2 == ".c" || ext2 == ".h")
			return 1;
	}
	if(len path >= 4) {
		ext4 := path[len path - 4:];
		if(ext4 == ".txt" || ext4 == ".sh" || ext4 == ".go" || ext4 == "file")
			return 1;
	}
	if(len path >= 3) {
		ext3 := path[len path - 3:];
		if(ext3 == ".md" || ext3 == ".rc" || ext3 == ".py" || ext3 == ".js")
			return 1;
	}

	# Known text filenames (no extension)
	base := path;
	for(i := len path - 1; i >= 0; i--) {
		if(path[i] == '/') {
			base = path[i+1:];
			break;
		}
	}
	if(base == "mkfile" || base == "README" || base == "LICENSE" ||
	   base == "CLAUDE" || base == "Makefile")
		return 1;

	# Peek at first bytes: skip if any null bytes found
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	fd = nil;
	if(n <= 0)
		return 0;
	for(j := 0; j < n; j++) {
		if(int buf[j] == 0)
			return 0;
	}
	return 1;
}

# Check if path is a directory (with timeout), returns 1=dir, 0=file,
# -1=error and why
isdirtimeout(path: string, ms: int): (int, string)
{
	rc := chan[1] of (int, string);
	spawn statcheck(path, rc);
	tc := chan[1] of int;
	spawn sleeptimer(tc, ms);
	alt {
		v := <-rc =>
			return v;
		<-tc =>
			return (-1, sys->sprint("it did not answer in %d seconds", ms / 1000));
	}
}

statcheck(path: string, rc: chan of (int, string))
{
	(ok, d) := sys->stat(path);
	if(ok < 0)
		rc <-= (-1, sys->sprint("%r"));
	else if(d.mode & Sys->DMDIR)
		rc <-= (1, nil);
	else
		rc <-= (0, nil);
}

opentimeout(path: string, mode: int, ms: int): ref Sys->FD
{
	rc := chan[1] of ref Sys->FD;
	spawn tryopen(path, mode, rc);
	tc := chan[1] of int;
	spawn sleeptimer(tc, ms);
	alt {
		fd := <-rc =>
			return fd;
		<-tc =>
			return nil;
	}
}

tryopen(path: string, mode: int, rc: chan of ref Sys->FD)
{
	rc <-= sys->open(path, mode);
}

sleeptimer(tc: chan of int, ms: int)
{
	sys->sleep(ms);
	tc <-= 1;
}
