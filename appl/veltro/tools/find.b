implement ToolFind;

#
# find - Find files by glob pattern for Veltro agent
#
# Recursively searches for files matching a glob pattern.
#
# Usage:
#   Find <pattern>              # Search from current directory
#   Find <pattern> <path>       # Search from specified path
#
# Patterns:
#   *     - Match any characters
#   ?     - Match single character
#   [abc] - Match character class
#
# Examples:
#   Find *.b /appl
#   Find mkfile
#   Find *_test.b /tests
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "filepat.m";
	filepat: Filepat;

include "string.m";
	str: String;

include "../tool.m";

ToolFind: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

# Limits
MAX_RESULTS: con 100;
MAX_DEPTH:   con 20;
MAX_DIRS:    con 2000;   # max directories opened per search — safety valve for huge trees
MAX_ENTRIES: con 200000; # max names looked at per search, however few directories hold them

# What a search has done, by index into its counters
NDIRS, NSKIPPED, NENTRIES, NDEEP: con iota;
OPEN_TIMEOUT: con 500;  # ms — skip directories that block longer than this

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	filepat = load Filepat Filepat->PATH;
	if(filepat == nil)
		return "cannot load Filepat";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "find";
}

doc(): string
{
	return "Find - Find files by glob pattern\n\n" +
		"Accepts both native and Unix-style syntax:\n" +
		"  Find <pattern> [path]            # native: pattern first\n" +
		"  Find [path] -name <pattern>      # Unix: path then -name pattern\n\n" +
		"Patterns:\n" +
		"  *     - Match any characters\n" +
		"  ?     - Match single character\n" +
		"  [abc] - Match character class\n\n" +
		"Examples:\n" +
		"  Find *.dis /dis/wm\n" +
		"  Find /dis/wm -name *.dis\n" +
		"  Find / -name *tetris*\n" +
		"  Find *_test.b /tests\n\n" +
		"-iname matches without regard to case.  With no path, the current\n" +
		"directory is searched.\n" +
		"Returns list of matching file paths (max 100 results, max 2000 directories),\n" +
		"and says when the search stopped before it had looked everywhere.";
}

schema(): string
{
	return "{" +
		"\"name\":\"find\"," +
		"\"description\":\"Find files by glob pattern. Returns matching file paths (max 100). Patterns support * ? and [abc] character classes.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern, e.g. *.b or *_test.b.\"}," +
				"\"path\":{\"type\":\"string\",\"description\":\"Search root directory. Optional; defaults to the current directory.\"}" +
			"}," +
			"\"required\":[\"pattern\"]" +
		"}" +
	"}";
}

# True if s looks like an absolute filesystem path (leading /). Used to tell
# the path argument from the pattern argument regardless of their order.
ispathlike(s: string): int
{
	return len s > 0 && s[0] == '/';
}

# True if s contains a glob metacharacter (* ? [). Used to decide whether a
# bare pattern should be treated as a literal substring (wrapped in *...*).
hasglobmeta(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '*' || s[i] == '?' || s[i] == '[')
			return 1;
	return 0;
}

exec(args: string): string
{
	if(sys == nil)
		init();

	if(filepat == nil)
		return "error: cannot load filepat module";

	# Parse arguments — accept two calling conventions:
	#   Tool-native:  Find <pattern> [path]       e.g. Find *tetris* /dis
	#   Unix-compat:  Find [path] -name <pattern>  e.g. Find /dis -name *tetris*
	(n, argv) := sys->tokenize(args, " \t");
	if(n < 1)
		return "error: usage: Find <pattern> [path]";

	pattern := "";
	basepath := ".";

	# Detect Unix-style: scan for -name flag.  Any other option was
	# passed over and its argument taken for the path ("-type f"
	# searched a directory f), and -iname matched case as -name does.
	nameflag := 0;
	icase := 0;
	patharg := "";
	patarg := "";
	for(a := argv; a != nil; a = tl a) {
		tok := hd a;
		if(nameflag) {
			patarg = tok;
			nameflag = 0;
		} else if(tok == "-name" || tok == "-iname") {
			nameflag = 1;
			if(tok == "-iname")
				icase = 1;
		} else if(isoption(tok)) {
			return "error: find does not take " + tok + ": usage: Find <pattern> [path], or Find [path] -name <pattern>";
		} else if(len tok > 0 && tok[0] != '-') {
			patharg = tok;
		}
	}
	if(nameflag)
		return "error: -name needs a pattern after it";
	if(patarg != "") {
		# Unix-style found
		pattern = patarg;
		if(patharg != "")
			basepath = patharg;
	} else {
		# Tool-native: two bare tokens whose order varies — a JSON tool call
		# commonly emits {path, pattern} (path first) while the native form is
		# pattern-first. Disambiguate by shape: the token that looks like an
		# absolute path (leading /) is the path; the other is the pattern. This
		# makes find order-agnostic for either emission. Fall back to
		# pattern-first when neither token looks like a path.
		a0 := hd argv;
		a1 := "";
		if(tl argv != nil)
			a1 = hd (tl argv);
		if(a1 != "" && ispathlike(a0) && !ispathlike(a1)) {
			basepath = a0;
			pattern = a1;
		} else {
			pattern = a0;
			if(a1 != "")
				basepath = a1;
		}
	}

	# Strip shell-style quotes that LLMs sometimes add around patterns.
	# e.g. -name "*.pdf" tokenizes as `"*.pdf"` (with literal quotes).
	if(len pattern >= 2 &&
	   ((pattern[0] == '"' && pattern[len pattern - 1] == '"') ||
	    (pattern[0] == '\'' && pattern[len pattern - 1] == '\'')))
		pattern = pattern[1:len pattern - 1];

	# Substring tolerance: a bare pattern with no glob metacharacters (e.g.
	# "spawn") globs only a file named exactly "spawn", never "spawn.b" — a
	# common LLM mistake that returns "no matches" on an obvious hit. When the
	# pattern has no *, ? or [, treat it as a substring by wrapping in *...*.
	if(pattern != "" && !hasglobmeta(pattern))
		pattern = "*" + pattern + "*";
	if(icase)
		pattern = str->tolower(pattern);

	# With no path the current directory is searched, by its own name:
	# as "." each name was joined to the dot (".lib"), so nothing below
	# the first level was ever opened or found.
	if(basepath == ".") {
		dfd := sys->open(".", Sys->OREAD);
		if(dfd != nil)
			basepath = sys->fd2path(dfd);
		if(basepath == nil || basepath == "")
			basepath = "/";
	}
	# What cannot be searched is not "no matches".
	(bok, bd) := sys->stat(basepath);
	if(bok < 0)
		return sys->sprint("error: cannot search %s: %r", basepath);
	if(!(bd.mode & Sys->DMDIR))
		return "error: " + basepath + " is not a directory: give the directory to search in";

	# dirc counts across the entire recursive search: directories opened,
	# directories that would not open, names looked at, and whether a
	# directory was too deep to enter.  Passed by reference (array) so
	# all recursive calls share the counters.
	dirc := array[4] of {* => 0};

	# Collect results
	results: list of string;
	count := 0;
	truncated := 0;

	# Search recursively
	(results, count, truncated) = searchdir(basepath, pattern, icase, 0, dirc);

	# How the search fell short, if it did.  (It was always "truncated
	# at 100 results", whatever had stopped it; a directory that would
	# not open, or was too deep, was passed over unsaid.)
	short := "";
	if(dirc[NDIRS] >= MAX_DIRS || dirc[NENTRIES] >= MAX_ENTRIES)
		short = sys->sprint("the search stopped after %d directories; the rest were not searched", dirc[NDIRS]);
	if(dirc[NDEEP]) {
		if(short != "")
			short += "; ";
		short += sys->sprint("directories more than %d deep were not entered", MAX_DEPTH);
	}
	if(dirc[NSKIPPED] > 0) {
		if(short != "")
			short += "; ";
		short += sys->sprint("%d directories could not be opened", dirc[NSKIPPED]);
	}

	if(count == 0) {
		if(short != "")
			return "no matches found (" + short + ")";
		return "no matches found";
	}

	# Build result string
	result := "";
	for(r := results; r != nil; r = tl r) {
		if(result != "")
			result += "\n";
		result += hd r;
	}

	if(count >= MAX_RESULTS && truncated)
		result += sys->sprint("\n... (stopped at %d results; there may be more)", count);
	if(short != "")
		result += "\n... (" + short + ")";

	return sys->sprint("%d matches:\n%s", count, result);
}

# Recursively search directory for matching files.
# dirc is a single-element array used as a shared directory counter.
#
# Files at the current level are matched BEFORE recursing into any
# subdirectory.  This guarantees that a file sitting at /foo/bar.pdf is
# found even when the very first subdirectory of /foo exhausts MAX_DIRS.
# (Previous DFS approach: recurse into subdir immediately → MAX_DIRS hit →
# early return → root-level files never checked.)
searchdir(path, pattern: string, icase, depth: int, dirc: array of int): (list of string, int, int)
{
	results: list of string;
	count := 0;
	truncated := 0;

	if(depth > MAX_DEPTH) {
		dirc[NDEEP] = 1;
		return (nil, 0, 0);
	}

	if(dirc[NDIRS] >= MAX_DIRS || dirc[NENTRIES] >= MAX_ENTRIES)
		return (nil, 0, 1);

	fd := opentimeout(path, Sys->OREAD, OPEN_TIMEOUT);
	if(fd == nil) {
		dirc[NSKIPPED]++;
		return (nil, 0, 0);
	}
	dirc[NDIRS]++;

	# Pass 1: read all entries, match files immediately, collect subdir paths.
	# Subdirs are deferred so ALL files at this level are checked first.
	subdirs: list of string;
	done := 0;
	for(;;) {
		if(done)
			break;
		(nread, dir) := sys->dirread(fd);
		if(nread <= 0)
			break;

		for(i := 0; i < nread && !done; i++) {
			d := dir[i];
			name := d.name;

			# A name is one name of this directory: a server that
			# gives an empty one raised an exception here, and one
			# with a slash in it steered the search elsewhere.
			if(name == "" || name == "." || name == ".." || hasslash(name))
				continue;

			# One directory may hold any number of names.
			if(++dirc[NENTRIES] > MAX_ENTRIES) {
				done = 1;
				truncated = 1;
				continue;
			}

			fullpath := path + "/" + name;
			if(len path > 0 && path[len path - 1] == '/')
				fullpath = path + name;

			# Match all entries (files AND dirs) against pattern
			mname := name;
			if(icase)
				mname = str->tolower(name);
			if(filepat->match(pattern, mname)) {
				if(count >= MAX_RESULTS) {
					done = 1;
					truncated = 1;
					continue;
				}
				results = fullpath :: results;
				count++;
			}

			# Collect non-hidden subdirs for later recursion.
			# Skip hidden dirs (.git, .cache, .npm, etc.) which can be
			# enormous and are rarely where user files live.
			if((d.mode & Sys->DMDIR) && name[0] != '.')
				subdirs = fullpath :: subdirs;
		}
	}

	# Pass 2: recurse into collected subdirs (only after all files matched above)
	for(s := subdirs; s != nil && !truncated; s = tl s) {
		if(dirc[NDIRS] >= MAX_DIRS) {
			truncated = 1;
			break;
		}
		(subresults, subcount, subtrunc) := searchdir(hd s, pattern, icase, depth + 1, dirc);
		for(; subresults != nil; subresults = tl subresults)
			results = hd subresults :: results;
		count += subcount;
		if(subtrunc)
			truncated = 1;
		if(count >= MAX_RESULTS)
			truncated = 1;
	}

	return (results, count, truncated);
}

# Open a file with timeout to skip blocked paths (e.g. macOS TCC).
# IMPORTANT: timeout MUST be chan[1] (buffered) so sleeptimer() can exit
# after sending even when nobody is receiving.  An unbuffered channel
# causes sleeptimer() to block forever — a goroutine leak that accumulates
# one leaked goroutine per directory visited and eventually exhausts memory.
opentimeout(path: string, mode: int, ms: int): ref Sys->FD
{
	result := chan[1] of ref Sys->FD;
	spawn tryopen(path, mode, result);

	timeout := chan[1] of int;  # buffered: sleeptimer exits after send
	spawn sleeptimer(timeout, ms);

	alt {
		fd := <-result =>
			return fd;
		<-timeout =>
			return nil;	# counted by the caller, and said in the answer
	}
}

# -type, -maxdepth, -print: a dash and letters (a pattern may begin with a
# dash, but has something else in it)
isoption(s: string): int
{
	if(len s < 2 || s[0] != '-')
		return 0;
	for(i := 1; i < len s; i++)
		if(!((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z')))
			return 0;
	return 1;
}

hasslash(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == '/')
			return 1;
	return 0;
}

tryopen(path: string, mode: int, result: chan of ref Sys->FD)
{
	fd := sys->open(path, mode);
	result <-= fd;
}

sleeptimer(ch: chan of int, ms: int)
{
	sys->sleep(ms);
	ch <-= 1;
}
