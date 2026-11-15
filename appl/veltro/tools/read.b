implement ToolRead;

#
# read - Read file contents tool for Veltro agent
#
# Reads and returns file contents with optional offset and line limit.
#
# Usage:
#   Read <path>                    # Read entire file (default: 100 lines max)
#   Read <path> <offset>           # Start from line offset
#   Read <path> <offset> <limit>   # Read limit lines from offset
#
# Examples:
#   Read /appl/veltro/veltro.b
#   Read /appl/veltro/veltro.b 10
#   Read /appl/veltro/veltro.b 10 50
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

ToolRead: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

# Defaults and limits.  What one read returns is bounded by lines and by
# bytes, whichever comes first, and says where the next read starts.  At
# 100 lines a read was rarely a whole source file, and its end said only
# "truncated": the model guessed at the offset, or stopped short.
DEFAULT_LIMIT: con 2000;
MAX_LIMIT: con 5000;
MAX_BYTES: con 30000;	# without a limit given: under the harness's inline limit
LIMIT_BYTES: con 4*MAX_BYTES;	# with one: the lines asked for, to this many bytes
MAX_LINE: con 2000;	# a longer line is cut, and says so
MAX_COUNT: con 64*1024*1024;	# bytes read past the last line returned, to count the lines

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
	return "read";
}

doc(): string
{
	return "Read - Read file contents\n\n" +
		"Usage:\n" +
		"  Read <path>                    # Read file (default: 2000 lines or 30000 bytes)\n" +
		"  Read <path> <offset>           # Start from line offset\n" +
		"  Read <path> <offset> <limit>   # Read limit lines from offset\n\n" +
		"Arguments:\n" +
		"  path    - File path to read\n" +
		"  offset  - Starting line number (0-indexed, default: 0)\n" +
		"  limit   - Maximum lines to return (default: 2000, max: 5000;\n" +
		"            with a limit, up to 120000 bytes are returned)\n\n" +
		"Examples:\n" +
		"  Read /appl/veltro/veltro.b\n" +
		"  Read /appl/veltro/veltro.b 10\n" +
		"  Read /appl/veltro/veltro.b 10 50\n\n" +
		"Returns file contents with line numbers, or error message.  A read that\n" +
		"stops before the end says which offset to read from next.";
}

schema(): string
{
	return "{" +
		"\"name\":\"read\"," +
		"\"description\":\"Read a file. Returns its lines with line numbers (the numbers are not part of the file: leave them out of an edit). At most 2000 lines or 30000 bytes at a time (with a limit given, that many lines, to 120000 bytes); a read that stops before the end says the offset to read from next.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"path\":{\"type\":\"string\",\"description\":\"File path to read (e.g. /appl/veltro/veltro.b).\"}," +
				"\"offset\":{\"type\":\"string\",\"description\":\"Lines to skip first (0 starts at line 1, 40 at line 41). Optional; defaults to 0.\"}," +
				"\"limit\":{\"type\":\"string\",\"description\":\"Maximum lines to return. Optional; default 2000, max 5000.\"}" +
			"}," +
			"\"required\":[\"path\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	# Parse arguments
	(n, argv) := sys->tokenize(args, " \t");
	if(n < 1)
		return "error: usage: Read <path> [offset] [limit]";

	path := hd argv;
	argv = tl argv;

	offset := 0;
	limit := DEFAULT_LIMIT;
	maxbytes := MAX_BYTES;

	# A number that is none was read as 0 and the read made all the
	# same: a path with a blank in it gave its first word's file, or an
	# error about another name.
	if(argv != nil) {
		if(!isnumber(hd argv))
			return "error: the offset must be a number of lines (usage: Read <path> [offset] [limit]; a path with a blank in it cannot be given)";
		offset = int hd argv;
		argv = tl argv;
	}

	if(argv != nil) {
		if(!isnumber(hd argv))
			return "error: the limit must be a number of lines (usage: Read <path> [offset] [limit])";
		# A limit asked for is lines, as many as asked, to a bound of
		# its own: there was none, and 5000 long lines came back whole.
		maxbytes = LIMIT_BYTES;
		limit = int hd argv;
		if(limit < 1)
			limit = 1;
		if(limit > MAX_LIMIT)
			limit = MAX_LIMIT;
		if(tl argv != nil)
			return "error: usage: Read <path> [offset] [limit] (a path with a blank in it cannot be given)";
	}

	# A directory read as a file gave a line of what its entries are
	# stored as.
	(sok, sd) := sys->stat(path);
	if(sok >= 0 && (sd.mode & Sys->DMDIR))
		return "error: " + path + " is a directory: list it, or find in it";

	# Open file
	f := bufio->open(path, Sys->OREAD);
	if(f == nil)
		return sys->sprint("error: cannot open %s: %r", path);

	# Read lines
	result := "";
	lineno := 0;
	linesread := 0;
	stopped := -1;		# the line not returned, where the next read starts
	nbytes := 0;
	cutlines := 0;
	more := 0;		# the count of lines was given up: the file goes on

	for(;;) {
		(line, full, eof) := getline(f);
		if(eof)
			break;
		if(lineno >= offset && stopped < 0) {
			if(linesread >= limit || nbytes >= maxbytes)
				stopped = lineno;
			else {
				if(full > MAX_LINE) {
					if(len line > MAX_LINE)
						line = line[0:MAX_LINE];
					line += sys->sprint("... [line cut: %d characters]\n", full);
					cutlines++;
				}
				# Format with line number
				l := sys->sprint("%5d\t%s", lineno + 1, line);
				result += l;
				nbytes += len l;
				linesread++;
			}
		}
		lineno++;
		if(stopped >= 0)
			break;
	}
	# The rest is read only to say how many lines there are, and only so
	# far: a file with no end (a device, a service's stream) was read
	# for ever.
	if(stopped >= 0) {
		buf := array[8192] of byte;
		scanned := 0;
		last := byte '\n';
		while((n = f.read(buf, len buf)) > 0) {
			for(i := 0; i < n; i++)
				if(buf[i] == byte '\n')
					lineno++;
			last = buf[n-1];
			scanned += n;
			if(scanned >= MAX_COUNT) {
				more = 1;
				break;
			}
		}
		if(last != byte '\n')
			lineno++;
	}

	f.close();

	if(result == "") {
		if(lineno == 0)
			return "(empty file)";
		return sys->sprint("(offset %d is beyond the end: the file has %d lines)", offset, lineno);
	}
	if(stopped >= 0 || cutlines > 0) {
		if(result[len result - 1] != '\n')
			result += "\n";
	}
	if(stopped >= 0) {
		total := sys->sprint("%d", lineno);
		if(more)
			total = sys->sprint("more than %d", lineno);
		result += sys->sprint("[lines %d-%d of %s.  To read on, read again with offset %d.]",
			offset + 1, stopped, total, stopped);
	}
	if(cutlines > 0)
		result += sys->sprint("\n[%d long line(s) cut at %d characters.]", cutlines, MAX_LINE);

	return result;
}

isnumber(s: string): int
{
	if(s == nil || len s > 9)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

# The next line: at most MAX_LINE characters of it (and its newline), how
# many characters it has, and whether the file has ended.  The line was
# read whole whatever its length, so a file with no newline in it was held
# in memory entire to show its first 2000 characters.
getline(f: ref Iobuf): (string, int, int)
{
	c := f.getc();
	if(c == Bufio->EOF || c == Bufio->ERROR)
		return (nil, 0, 1);
	line := "";
	n := 0;
	for(;;) {
		if(n < MAX_LINE || c == '\n')
			line[len line] = c;
		n++;
		if(c == '\n')
			break;
		c = f.getc();
		if(c == Bufio->EOF || c == Bufio->ERROR)
			break;
	}
	return (line, n, 0);
}
