implement ToolList;

#
# list - List directory contents tool for Veltro agent
#
# Lists files and directories with size and type information.
#
# Usage:
#   List <path>           # List directory contents
#
# Examples:
#   List /appl/veltro
#   List /
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "../tool.m";

ToolList: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "list";
}

doc(): string
{
	return "List - List directory contents\n\n" +
		"Usage:\n" +
		"  List <path>           # List directory contents\n\n" +
		"Arguments:\n" +
		"  path - Directory path to list\n\n" +
		"Examples:\n" +
		"  List /appl/veltro\n" +
		"  List /\n\n" +
		"Returns entries with type (d=directory, f=file), size, and name.";
}

schema(): string
{
	return "{" +
		"\"name\":\"list\"," +
		"\"description\":\"List directory contents. Returns one entry per line with type (d=dir, f=file), size, and name.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"path\":{\"type\":\"string\",\"description\":\"Directory path to list (e.g. /appl/veltro).\"}" +
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
		return "error: usage: List <path>";

	path := hd argv;

	# Open directory
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r", path);

	# Read directory entries
	result := "";
	count := 0;

	for(;;) {
		(nread, dir) := sys->dirread(fd);
		if(nread <= 0)
			break;

		for(i := 0; i < nread; i++) {
			d := dir[i];
			typ := "f";
			if(d.mode & Sys->DMDIR)
				typ = "d";

			# Format size nicely
			size := "";
			if(typ == "d")
				size = "-";
			else if(d.length < big 1024)
				size = sys->sprint("%dB", int d.length);
			else if(d.length < big (1024*1024))
				size = sys->sprint("%dK", int (d.length / big 1024));
			else
				size = sys->sprint("%dM", int (d.length / big (1024*1024)));

			result += sys->sprint("%s %8s %s\n", typ, size, d.name);
			count++;
		}
	}

	if(count == 0)
		return "(empty directory)";

	return sys->sprint("%d entries:\n%s", count, result);
}
