implement ToolCharon;

#
# charon - Veltro tool for controlling the Charon web browser
#
# Drives the browser the user sees through its session files at
# /mnt/charon (charonfs(2)), which tools9p mounts for this tool only.
# Navigation waits on /mnt/charon/event for the load to finish.
#
# Commands:
#   navigate <url>              Navigate to URL
#   back                        Go back in history
#   forward                     Go forward in history
#   reload                      Reload current page
#   stop                        Stop loading
#   follow <n>                  Follow link number n
#   read [body]                 Read page text
#   read url                    Read current URL
#   read title                  Read page title
#   read links                  Read numbered link index
#   read forms                  Read form fields
#   set <node> <value>          Set a form field (node from read forms)
#   click <node>                Click a link, button, checkbox or radio
#   submit <form> [<node>]      Submit form <form>, optionally as button <node>
#   search <text>               Search in page text
#   status                      Show loading state
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolCharon: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

BROWSER_DIR: con "/mnt/charon";
WAIT: con 30*1000;	# ms a navigation may take

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
	return "charon";
}

doc(): string
{
	return "Charon - AI control for the Charon web browser\n\n" +
		"Commands:\n" +
		"  navigate <url>        Navigate to a URL\n" +
		"  back                  Go back in history\n" +
		"  forward               Go forward in history\n" +
		"  reload                Reload current page\n" +
		"  follow <n>            Follow link number n\n" +
		"  read [body]           Read formatted page text\n" +
		"  read url              Read current URL\n" +
		"  read title            Read page title\n" +
		"  read links            Read numbered link index\n" +
		"  read forms            Read form fields: <form> <node> <kind> <name> <value>\n" +
		"  set <node> <value>    Set a form field\n" +
		"  click <node>          Click a link, button, checkbox or radio button\n" +
		"  submit <form> [node]  Submit a form, optionally as the button <node>\n" +
		"  search <text>         Search in page text\n" +
		"  status                Show loading state\n\n" +
		"The browser must be running for commands to work.\n" +
		"Use 'launch charon' to start it, optionally with a URL:\n" +
		"  launch charon https://example.com\n\n" +
		"Examples:\n" +
		"  charon navigate https://example.com\n" +
		"  charon read                    Read page text\n" +
		"  charon read links              See all links with numbers\n" +
		"  charon follow 3                Follow link #3\n" +
		"  charon back                    Go back\n" +
		"  charon search authentication   Find text on page\n";
}

schema(): string
{
	return "{" +
		"\"name\":\"charon\"," +
		"\"description\":\"Control a running Charon browser. Use 'launch charon' first if Charon is not already running.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"command\":{\"type\":\"string\",\"description\":\"One of: navigate, back, forward, reload, stop, follow, read, set, click, submit, search, status.\"}," +
				"\"args\":{\"type\":\"string\",\"description\":\"Command argument: a URL for navigate; a link number for follow; one of body|url|title|links|forms for read; '<node> <value>' for set; a node number for click; '<form> [<node>]' for submit; the search string for search. Omit for back/forward/reload/status.\"}" +
			"}," +
			"\"required\":[\"command\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	args = strip(args);
	if(args == "")
		return "error: no command. Use: navigate, back, forward, reload, follow, read, search, status";

	(cmd, rest) := splitfirst(args);
	cmd = str->tolower(cmd);

	case cmd {
	"navigate" or "go" =>
		return donavigate(rest);
	"back" =>
		return doctl("back");
	"forward" =>
		return doctl("forward");
	"reload" =>
		return doctl("reload");
	"follow" =>
		return dofollow(rest);
	"read" =>
		return doread(rest);
	"search" =>
		return dosearch(rest);
	"status" =>
		return dostatus();
	"stop" =>
		return doctl("stop");
	"set" =>
		return doset(rest);
	"click" =>
		return doclick(rest);
	"submit" =>
		return dosubmit(rest);
	* =>
		return sys->sprint("error: unknown command '%s'", cmd);
	}
}

donavigate(url: string): string
{
	url = strip(url);
	if(url == "")
		return "error: usage: navigate <url>";
	if(!isallowedurl(url))
		return "error: only http:// and https:// URLs are allowed";
	return navwait("open " + url);
}

dofollow(args: string): string
{
	args = strip(args);
	if(args == "")
		return "error: usage: follow <link-number>";
	if(!validindex(args))
		return "error: invalid link number: " + args;
	return navwait("follow " + args);
}

doclick(args: string): string
{
	args = strip(args);
	if(!validindex(args))
		return "error: usage: click <node>";
	return navwait("click " + args);
}

dosubmit(args: string): string
{
	(form, node) := splitfirst(args);
	if(!validindex(form) || node != "" && !validindex(node))
		return "error: usage: submit <form> [<node>]";
	return navwait(strip("submit " + form + " " + node));
}

doset(args: string): string
{
	(node, value) := splitfirst(args);
	if(!validindex(node))
		return "error: usage: set <node> <value>";
	for(i := 0; i < len value; i++)
		if(value[i] < ' ' && value[i] != '\t')
			return "error: a value is one line";
	err := writefile(BROWSER_DIR + "/ctl", "set " + node + " " + value);
	if(hasprefix(err, "error:"))
		return err;
	return "ok";
}

validindex(s: string): int
{
	if(s == nil || s == "" || len s > 9)
		return 0;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return 1;
}

doctl(cmd: string): string
{
	if(cmd == "back" || cmd == "forward" || cmd == "reload")
		return navwait(cmd);
	err := writefile(BROWSER_DIR + "/ctl", cmd);
	if(hasprefix(err, "error:"))
		return err;
	return dostatus();
}

# Write a command that may start a load, and wait for the load to end.
# The event file is opened first, so the end cannot be missed; a command
# that loads nothing (a click on a checkbox) ends with "update" or not
# at all, and the wait gives up after a moment.
navwait(cmd: string): string
{
	ev := sys->open(BROWSER_DIR + "/event", Sys->OREAD);
	if(ev == nil)
		return sys->sprint("error: cannot open %s/event: %r (is charon running? use 'launch charon <url>')", BROWSER_DIR);
	err := writefile(BROWSER_DIR + "/ctl", cmd);
	if(hasprefix(err, "error:"))
		return err;
	evc := chan of string;
	spawn eventreader(ev, evc);
	timeout := chan of int;
	spawn timer(timeout, WAIT);
	started := 0;
	for(;;) alt {
	e := <-evc =>
		if(e == nil)
			return "error: event file closed";
		if(hasprefix(e, "error"))
			return "error: " + strip(e[len "error":]);
		if(hasprefix(e, "loading"))
			started = 1;
		if(hasprefix(e, "done") || hasprefix(e, "stopped") || !started && hasprefix(e, "update"))
			return dostatus();
	<-timeout =>
		if(!started)
			return dostatus();
		return "error: still loading after 30 seconds\n" + dostatus();
	}
}

eventreader(fd: ref Sys->FD, c: chan of string)
{
	buf := array[1024] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0) {
			c <-= nil;
			return;
		}
		c <-= string buf[0:n];
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

doread(args: string): string
{
	target := strip(args);
	if(target == "" || target == "body")
		return readfile(BROWSER_DIR + "/text");
	if(target == "url")
		return readfile(BROWSER_DIR + "/url");
	if(target == "title")
		return readfile(BROWSER_DIR + "/title");
	if(target == "links")
		return readfile(BROWSER_DIR + "/links");
	if(target == "forms")
		return readfile(BROWSER_DIR + "/forms");
	return "error: read target must be: body, url, title, links, or forms";
}

dosearch(query: string): string
{
	query = strip(query);
	if(query == "")
		return "error: usage: search <text>";
	err := writefile(BROWSER_DIR + "/find", query);
	if(hasprefix(err, "error:"))
		return err;
	r := readfile(BROWSER_DIR + "/find");
	if(r == "")
		return "not found: " + query;
	return r;
}

dostatus(): string
{
	status := strip(readfile(BROWSER_DIR + "/status"));
	title := strip(readfile(BROWSER_DIR + "/title"));
	url := strip(readfile(BROWSER_DIR + "/url"));
	return sys->sprint("Title: %s\nURL: %s\nStatus: %s", title, url, status);
}

# --- I/O helpers ---

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r (is charon running?)", path);

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
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r (is charon running? use 'launch charon <url>')", path);

	b := array of byte data;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("error: %r");
	return "ok";
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

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

isallowedurl(url: string): int
{
	lurl := str->tolower(url);
	for(i := 0; i < len lurl; i++) {
		c := lurl[i];
		if(c <= ' ' || c == 16r7F)
			return 0;
	}
	if(hasprefix(lurl, "http://") || hasprefix(lurl, "https://"))
		return 1;
	return 0;
}
