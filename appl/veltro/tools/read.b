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
MAX_LINE: con 2000;	# a longer line is cut, and says so

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
		"  limit   - Maximum lines to return (default: 2000, max: 5000)\n\n" +
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
		"\"description\":\"Read a file. Returns its lines with line numbers (the numbers are not part of the file: leave them out of an edit). At most 2000 lines or 30000 bytes at a time; a read that stops before the end says the offset to read from next.\"," +
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
	maxbytes := MAX_BYTES;	# a limit asked for is lines, as many as asked

	if(argv != nil) {
		offset = int hd argv;
		argv = tl argv;
		if(offset < 0)
			offset = 0;
	}

	if(argv != nil) {
		maxbytes = -1;
		limit = int hd argv;
		if(limit < 1)
			limit = 1;
		if(limit > MAX_LIMIT)
			limit = MAX_LIMIT;
	}

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

	while((line := f.gets('\n')) != nil) {
		if(lineno >= offset && stopped < 0) {
			if(linesread >= limit || (maxbytes >= 0 && nbytes >= maxbytes))
				stopped = lineno;
			else {
				if(len line > MAX_LINE) {
					line = line[0:MAX_LINE] + sys->sprint("... [line cut: %d characters]\n", len line);
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
	if(stopped >= 0)
		result += sys->sprint("[lines %d-%d of %d.  To read on, read again with offset %d.]",
			offset + 1, stopped, lineno, stopped);
	if(cutlines > 0)
		result += sys->sprint("\n[%d long line(s) cut at %d characters.]", cutlines, MAX_LINE);

	return result;
}
