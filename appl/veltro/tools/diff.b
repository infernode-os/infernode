implement ToolDiff;

#
# diff - File comparison tool for Veltro agent
#
# Computes unified diff between two files. Pure Limbo implementation
# with no external dependencies.
#
# Usage:
#   diff <file1> <file2>           # Compare two files
#   diff <file1> <file2> <context> # With context lines (default: 3)
#
# Examples:
#   diff /tmp/old.txt /tmp/new.txt
#   diff /appl/veltro/veltro.b /tmp/modified.b 5
#
# Output format follows unified diff:
#   --- file1
#   +++ file2
#   @@ -start,count +start,count @@
#   -removed line
#   +added line
#    context line
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "../tool.m";

ToolDiff: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

DEFAULT_CONTEXT: con 3;
MAX_CONTEXT: con 20;
MAX_LINES: con 10000;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string
{
	return "diff";
}

doc(): string
{
	return "Diff - Compare two files\n\n" +
		"Usage:\n" +
		"  diff <file1> <file2>           # Compare files (3 lines context)\n" +
		"  diff <file1> <file2> <context> # With custom context lines\n\n" +
		"Arguments:\n" +
		"  file1   - First file path\n" +
		"  file2   - Second file path\n" +
		"  context - Context lines to show (default: 3, max: 20)\n\n" +
		"Examples:\n" +
		"  diff /tmp/old.txt /tmp/new.txt\n" +
		"  diff /appl/veltro/veltro.b /tmp/modified.b 5\n\n" +
		"Returns unified diff format or 'files are identical'.";
}

schema(): string
{
	return "{" +
		"\"name\":\"diff\"," +
		"\"description\":\"Compare two files and return a unified diff, or 'files are identical' when there are no differences.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"file1\":{\"type\":\"string\",\"description\":\"First file path.\"}," +
				"\"file2\":{\"type\":\"string\",\"description\":\"Second file path.\"}," +
				"\"context\":{\"type\":\"string\",\"description\":\"Context lines around each hunk. Optional; default 3, max 20.\"}" +
			"}," +
			"\"required\":[\"file1\",\"file2\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	# Parse arguments
	(n, argv) := sys->tokenize(args, " \t");
	if(n < 2)
		return "error: usage: diff <file1> <file2> [context]";

	file1 := hd argv;
	argv = tl argv;
	file2 := hd argv;
	argv = tl argv;

	context := DEFAULT_CONTEXT;
	if(argv != nil) {
		context = int hd argv;
		if(context < 0)
			context = 0;
		if(context > MAX_CONTEXT)
			context = MAX_CONTEXT;
	}

	# Read both files
	(lines1, err1) := readlines(file1);
	if(err1 != nil)
		return "error: " + err1;

	(lines2, err2) := readlines(file2);
	if(err2 != nil)
		return "error: " + err2;

	# Compute diff using LCS algorithm
	diff := computediff(lines1, lines2, context);
	if(diff == "")
		return "(files are identical)";

	# Format output with headers
	header := "--- " + file1 + "\n+++ " + file2 + "\n";
	return header + diff;
}

# Read file into array of lines
readlines(path: string): (array of string, string)
{
	f := bufio->open(path, Sys->OREAD);
	if(f == nil)
		return (nil, sys->sprint("cannot open %s: %r", path));

	lines: list of string;
	count := 0;

	while((line := f.gets('\n')) != nil && count < MAX_LINES) {
		# Remove trailing newline for comparison
		if(len line > 0 && line[len line - 1] == '\n')
			line = line[:len line - 1];
		lines = line :: lines;
		count++;
	}
	f.close();

	# Reverse to get correct order
	result := array[count] of string;
	for(i := count - 1; i >= 0; i--) {
		result[i] = hd lines;
		lines = tl lines;
	}

	return (result, nil);
}

# Edit operation types
DEL, INS, EQ: con iota;

# Edit operation
Edit: adt {
	op:   int;     # DEL, INS, or EQ
	line: string;  # Line content
	old:  int;     # Line number in old file (1-indexed)
	new:  int;     # Line number in new file (1-indexed)
};

# Compute diff using simplified LCS-based algorithm
computediff(a, b: array of string, context: int): string
{
	n := len a;
	m := len b;

	# Build edit script using simple O(nm) LCS
	edits := lcs(a, b);

	if(edits == nil)
		return "";

	# Check if all edits are EQ (no differences)
	alleq := 1;
	for(e := edits; e != nil; e = tl e) {
		if((hd e).op != EQ) {
			alleq = 0;
			break;
		}
	}
	if(alleq)
		return "";

	# Group edits into hunks with context
	return formathunks(edits, context, n, m);
}

# LCS-based diff algorithm
# Returns list of Edit operations
lcs(a, b: array of string): list of ref Edit
{
	n := len a;
	m := len b;
	i, j: int;

	# Build LCS length table
	# c[i][j] = LCS length of a[0:i] and b[0:j]
	c := array[n+1] of array of int;
	for(i = 0; i <= n; i++)
		c[i] = array[m+1] of int;

	for(i = 0; i <= n; i++)
		c[i][0] = 0;
	for(j = 0; j <= m; j++)
		c[0][j] = 0;

	for(i = 1; i <= n; i++) {
		for(j = 1; j <= m; j++) {
			if(a[i-1] == b[j-1])
				c[i][j] = c[i-1][j-1] + 1;
			else if(c[i-1][j] >= c[i][j-1])
				c[i][j] = c[i-1][j];
			else
				c[i][j] = c[i][j-1];
		}
	}

	# Backtrack to build edit script
	edits: list of ref Edit;
	i = n;
	j = m;

	while(i > 0 || j > 0) {
		if(i > 0 && j > 0 && a[i-1] == b[j-1]) {
			# Match - equal line
			edits = ref Edit(EQ, a[i-1], i, j) :: edits;
			i--;
			j--;
		} else if(j > 0 && (i == 0 || c[i][j-1] >= c[i-1][j])) {
			# Insertion in b
			edits = ref Edit(INS, b[j-1], i, j) :: edits;
			j--;
		} else if(i > 0) {
			# Deletion from a
			edits = ref Edit(DEL, a[i-1], i, j) :: edits;
			i--;
		}
	}

	return edits;
}

# Format edits into unified diff hunks
formathunks(edits: list of ref Edit, context, oldlen, newlen: int): string
{
	result := "";

	# Convert list to array for easier indexing
	editarr := array[listlen(edits)] of ref Edit;
	i := 0;
	for(e := edits; e != nil; e = tl e) {
		editarr[i] = hd e;
		i++;
	}

	# Find hunks (groups of changes with context)
	hunkstart := -1;
	hunkend := -1;
	lastchange := -1;

	for(i = 0; i < len editarr; i++) {
		if(editarr[i].op != EQ) {
			# This is a change
			if(hunkstart < 0) {
				# Start new hunk with context before
				hunkstart = i - context;
				if(hunkstart < 0)
					hunkstart = 0;
			}
			lastchange = i;
			hunkend = i + context + 1;
			if(hunkend > len editarr)
				hunkend = len editarr;
		} else if(hunkstart >= 0 && i >= hunkend) {
			# End of hunk - format it
			result += formathunk(editarr, hunkstart, hunkend);
			hunkstart = -1;
			hunkend = -1;
		}
	}

	# Format final hunk if any
	if(hunkstart >= 0) {
		if(hunkend > len editarr)
			hunkend = len editarr;
		result += formathunk(editarr, hunkstart, hunkend);
	}

	return result;
}

# Format a single hunk
formathunk(edits: array of ref Edit, start, end: int): string
{
	# Calculate line ranges
	oldstart := 0;
	oldcount := 0;
	newstart := 0;
	newcount := 0;
	i: int;
	e: ref Edit;

	for(i = start; i < end; i++) {
		e = edits[i];
		if(i == start) {
			oldstart = e.old;
			newstart = e.new;
			if(e.op == INS)
				oldstart = e.old + 1;  # Insert after this line
			if(e.op == DEL)
				newstart = e.new + 1;
		}

		case e.op {
		DEL =>
			oldcount++;
		INS =>
			newcount++;
		EQ =>
			oldcount++;
			newcount++;
		}
	}

	# Adjust for 0-indexed
	if(oldstart == 0) oldstart = 1;
	if(newstart == 0) newstart = 1;

	# Format hunk header
	result := sys->sprint("@@ -%d,%d +%d,%d @@\n", oldstart, oldcount, newstart, newcount);

	# Format lines
	for(i = start; i < end; i++) {
		e = edits[i];
		case e.op {
		DEL =>
			result += "-" + e.line + "\n";
		INS =>
			result += "+" + e.line + "\n";
		EQ =>
			result += " " + e.line + "\n";
		}
	}

	return result;
}

# Count list length
listlen(l: list of ref Edit): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}
