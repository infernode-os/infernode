implement ToolMemory;

#
# memory - Agent memory/persistence tool for Veltro agent
#
# Provides persistent key-value storage for agent context.
# Data persists across sessions in /tmp/veltro/memory/{agentid}/
#
# The agent is the activity the tool server serves (/tool/activity), and
# each has a memory of its own: the main agent's (activity 0) is kept
# from one session to the next; a task's lasts as long as the task. There
# was one memory, "default", for every agent and every boot, so a task
# that had read hostile text could leave it where the main agent would
# load it as its own, and could list, read and clear what any other
# agent had kept. Task ids begin again at each boot, so a task's memory
# is emptied when a new tool server first uses it: a task does not
# inherit what an earlier boot's task of its number left.
#
# Usage:
#   memory save <key> <value>     # Store a value
#   memory load <key>             # Retrieve a value
#   memory delete <key>           # Delete a key
#   memory list                   # List all keys
#   memory clear                  # Clear all keys
#
# Examples:
#   memory save project_path /home/user/myproject
#   memory load project_path
#   memory save context "Working on authentication module"
#   memory list
#
# Keys are alphanumeric with underscores. Values are stored as-is.
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

ToolMemory: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

# Memory storage base path
# Agent ID is determined from sandbox path or generated
MEMORY_BASE: con "/tmp/veltro/memory";
DEFAULT_AGENT: con "default";
MAIN_AGENT: con "0";	# the activity whose memory is kept across sessions

# Current agent ID (set at each call: /tool is served to a call, not
# to the tool server that loads this module)
agentid: string;
fresh := 1;	# nothing has been stored or read by this tool server yet

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

	agentid = getagentid();

	return nil;
}

name(): string
{
	return "memory";
}

doc(): string
{
	return "Memory - Persistent key-value storage\n\n" +
		"Usage:\n" +
		"  memory save <key> <value>  # Store a value\n" +
		"  memory load <key>          # Retrieve a value\n" +
		"  memory delete <key>        # Delete a key\n" +
		"  memory list                # List all keys\n" +
		"  memory clear               # Clear all keys\n" +
		"  memory append <key> <val>  # Append to existing value\n\n" +
		"Arguments:\n" +
		"  key   - letters, digits, _ and -, at most 64 characters\n" +
		"  value - Any string value\n\n" +
		"Examples:\n" +
		"  memory save project /home/user/myproject\n" +
		"  memory load project\n" +
		"  memory save notes \"Working on auth\"\n" +
		"  memory append notes \" - added login\"\n" +
		"  memory list\n\n" +
		"Each agent has its own memory. The main agent's persists across\n" +
		"sessions; a task's lasts as long as the task.";
}

schema(): string
{
	return "{" +
		"\"name\":\"memory\"," +
		"\"description\":\"Key-value storage of this agent's own: the main agent's survives across sessions, a task's lasts as long as the task. Keys are letters, digits, underscore and hyphen.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"One of: save, load, delete, list, clear, append.\"}," +
				"\"args\":{\"type\":\"string\",\"description\":\"For save/append: key followed by value. For load/delete: the key. Omit for list/clear.\"}" +
			"}," +
			"\"required\":[\"command\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();
	agentid = getagentid();
	if(fresh) {
		fresh = 0;
		# a task's memory starts empty (see the header)
		if(agentid != MAIN_AGENT && agentid != DEFAULT_AGENT)
			clearall();
	}

	args = strip(args);
	if(args == "")
		return "error: usage: memory <save|load|delete|list|clear|append> [args...]";

	# Parse command
	(cmd, rest) := splitfirst(args);
	cmd = str->tolower(cmd);

	case cmd {
	"save" =>
		return dosave(rest);
	"load" =>
		return doload(rest);
	"delete" =>
		return dodelete(rest);
	"list" =>
		return dolist();
	"clear" =>
		return doclear();
	"append" =>
		return doappend(rest);
	* =>
		return "error: unknown command: " + cmd;
	}
}

# Save a key-value pair
dosave(args: string): string
{
	(key, value) := splitfirst(args);
	if(key == "")
		return "error: usage: memory save <key> <value>";

	if(!validkey(key))
		return "error: invalid key (use alphanumeric and underscore only)";

	value = stripquotes(value);

	# Ensure memory directory exists
	err := ensuredir(memorypath());
	if(err != nil)
		return "error: " + err;

	# Write value to file
	path := keypath(key);
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("error: cannot create %s: %r", path);

	data := array of byte value;
	if(sys->write(fd, data, len data) != len data) {
		fd = nil;
		return sys->sprint("error: write failed: %r");
	}
	fd = nil;

	return sys->sprint("saved '%s' (%d bytes)", key, len data);
}

# Load a value by key
doload(args: string): string
{
	key := strip(args);
	if(key == "")
		return "error: usage: memory load <key>";

	if(!validkey(key))
		return "error: invalid key";

	path := keypath(key);
	(value, err) := readfile(path);
	if(err != nil)
		return "error: key not found: " + key;

	return value;
}

# Delete a key
dodelete(args: string): string
{
	key := strip(args);
	if(key == "")
		return "error: usage: memory delete <key>";

	if(!validkey(key))
		return "error: invalid key";

	path := keypath(key);
	if(sys->remove(path) < 0)
		return "error: key not found: " + key;

	return "deleted '" + key + "'";
}

# List all keys
dolist(): string
{
	path := memorypath();
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "(no stored keys)";

	result := "";
	count := 0;

	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			# only what this tool could have stored is a key: a name
			# put there some other way is not echoed to the model
			if(!validkey(name))
				continue;
			if(result != "")
				result += "\n";
			result += name;
			count++;
		}
	}
	fd = nil;

	if(count == 0)
		return "(no stored keys)";

	return sys->sprint("%d keys:\n%s", count, result);
}

# Clear all keys
doclear(): string
{
	(ok, nil) := sys->stat(memorypath());
	if(ok < 0)
		return "(memory already empty)";
	(count, left) := clearall();
	# what is still there is said: it counted every name as cleared,
	# removed or not
	if(left > 0)
		return sys->sprint("error: cleared %d keys, %d could not be removed: %r", count, left);
	return sys->sprint("cleared %d keys", count);
}

# Remove every key of this agent's; returns how many went and how many stayed.
clearall(): (int, int)
{
	path := memorypath();
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (0, 0);

	names: list of string;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			name := dirs[i].name;
			if(name == "." || name == "..")
				continue;
			names = name :: names;
		}
	}
	fd = nil;

	count := 0;
	left := 0;
	for(; names != nil; names = tl names) {
		if(sys->remove(path + "/" + hd names) < 0)
			left++;
		else
			count++;
	}
	return (count, left);
}

# Append to existing value
doappend(args: string): string
{
	(key, value) := splitfirst(args);
	if(key == "")
		return "error: usage: memory append <key> <value>";

	if(!validkey(key))
		return "error: invalid key";

	value = stripquotes(value);

	# Load existing value. One that is there and cannot be read is an
	# error: read as nothing, the append replaced it.
	path := keypath(key);
	(existing, rerr) := readfile(path);
	if(rerr != nil) {
		(xok, nil) := sys->stat(path);
		if(xok >= 0)
			return "error: " + rerr;
	}

	# Append new value
	newvalue := existing + value;

	# Ensure directory exists
	err := ensuredir(memorypath());
	if(err != nil)
		return "error: " + err;

	# Write combined value
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		return sys->sprint("error: cannot create %s: %r", path);

	data := array of byte newvalue;
	if(sys->write(fd, data, len data) != len data) {
		fd = nil;
		return sys->sprint("error: write failed: %r");
	}
	fd = nil;

	return sys->sprint("appended to '%s' (now %d bytes)", key, len data);
}

# The agent is the activity whose tool server this is: tools9p serves
# its number to every call as /tool/activity. Loaded with no tool server
# (a test, a command), the store is "default", which is no activity's.
getagentid(): string
{
	fd := sys->open("/tool/activity", Sys->OREAD);
	if(fd == nil)
		return DEFAULT_AGENT;
	buf := array[32] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return DEFAULT_AGENT;
	id := strip(string buf[0:n]);
	if(id == "" || len id > 9)
		return DEFAULT_AGENT;
	for(i := 0; i < len id; i++)
		if(id[i] < '0' || id[i] > '9')
			return DEFAULT_AGENT;
	return string int id;
}

# Get memory directory path for current agent
memorypath(): string
{
	return MEMORY_BASE + "/" + agentid;
}

# Get path for a specific key
keypath(key: string): string
{
	return memorypath() + "/" + key;
}

# Validate key (alphanumeric + underscore)
validkey(key: string): int
{
	if(key == "")
		return 0;
	if(len key > 64)
		return 0;

	for(i := 0; i < len key; i++) {
		c := key[i];
		if(!((c >= 'a' && c <= 'z') ||
		     (c >= 'A' && c <= 'Z') ||
		     (c >= '0' && c <= '9') ||
		     c == '_' || c == '-'))
			return 0;
	}

	# Don't allow special names
	if(key == "." || key == "..")
		return 0;

	return 1;
}

# Ensure directory exists (creates parents)
ensuredir(path: string): string
{
	# Check if exists
	(ok, nil) := sys->stat(path);
	if(ok >= 0)
		return nil;

	# Create parent first
	parent := "";
	for(i := len path - 1; i > 0; i--) {
		if(path[i] == '/') {
			parent = path[0:i];
			break;
		}
	}
	if(parent != "" && parent != "/") {
		err := ensuredir(parent);
		if(err != nil)
			return err;
	}

	# Create directory
	fd := sys->create(path, Sys->OREAD, 8r700 | Sys->DMDIR);
	if(fd == nil)
		return sys->sprint("cannot create %s: %r", path);
	fd = nil;
	return nil;
}

# Read entire file contents
readfile(path: string): (string, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return ("", sys->sprint("cannot open %s: %r", path));

	content := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		content += string buf[0:n];

	fd = nil;
	return (content, nil);
}

# Strip whitespace
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

# Strip surrounding quotes
stripquotes(s: string): string
{
	s = strip(s);
	if(len s < 2)
		return s;
	if((s[0] == '"' && s[len s - 1] == '"') ||
	   (s[0] == '\'' && s[len s - 1] == '\''))
		return s[1:len s - 1];
	return s;
}

# Split on first whitespace
splitfirst(s: string): (string, string)
{
	for(i := 0; i < len s; i++) {
		if(s[i] == ' ' || s[i] == '\t')
			return (s[0:i], strip(s[i:]));
	}
	return (s, "");
}
