implement ToolMount;

#
# mount - stub: namespace mounting is a user-only operation
#
# Resources are mounted by the user via the [+] button in the
# Lucifer context zone. The agent cannot expand its own namespace.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "../tool.m";

ToolMount: module {
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
	return "mount";
}

doc(): string
{
	return "mount - namespace mounting is a user operation\n\n" +
		"Resources are mounted by the user via the [+] button in the\n" +
		"Lucifer context zone. The agent cannot expand its own namespace.\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"mount\"," +
		"\"description\":\"Mount is a user operation. The agent cannot expand its own namespace; mounts are made by the user via the Lucifer context zone. Calling this tool returns a guidance message.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"args\":{\"type\":\"string\",\"description\":\"Unused. The tool always returns the same guidance text.\"}" +
			"}," +
			"\"required\":[]" +
		"}" +
	"}";
}

exec(nil: string): string
{
	return "error: namespace mounting is a user operation" +
		" — use the [+] button in the Lucifer context zone";
}
