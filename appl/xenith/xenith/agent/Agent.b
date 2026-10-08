implement Agent;

#
# Agent - the Veltro agent in a Xenith window
#
# A client of veltrosrv(4), the way Mail and Chat are clients of their
# servers.  The window's body is the session's text file; type at the
# end of it and middle-click Send.  The agent's reply arrives as it is
# generated.  When the agent needs approval for a call, the request
# appears in the body and Allow or Deny answers it.
#
#	Agent [-v] [-p path,...] [-t tool,...] [-x message]
#
# Tag: Send Stop Reset Allow Deny Delete
#
# -x sends a message at once, as if typed and Sent (for scripts and
# tests).
#
# With no /mnt/veltro in the namespace, Agent starts a veltrosrv with
# the grants given (the current directory, when no -p is given), and a
# tools9p with the editing tools when there is no /tool.  Delete ends
# the session, and the server if Agent started it.
#

include "sys.m";
	sys: Sys;
	sprint, fprint, fildes, pread, pctl, OREAD, OWRITE: import sys;
include "draw.m";
include "arg.m";
	arg: Arg;
include "bufio.m";
include "xenithwin.m";
	win: Xenithwin;
	Win, Event: import win;
include "string.m";
	str: String;

Agent: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

# Any command module, for the servers Agent starts itself.
Command: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

VELTROSRV: con "/dis/veltro/veltrosrv.dis";
TOOLS9P: con "/dis/veltro/tools9p.dis";
DEFAULT_TOOLS: con "read,list,find,search,grep,write,edit,diff,exec,git,limbo";

verbose := 0;
stderr: ref Sys->FD;
sess := "";			# the session's directory
srvpid := 0;		# the server's process group, when Agent started it
busy := 0;
pending := "";		# callid of a call awaiting approval

usage()
{
	fprint(fildes(2), "usage: Agent [-v] [-p path,...] [-t tool,...] [-x message]\n");
	exit;
}

readfile(path: string): string
{
	fd := sys->open(path, OREAD);
	if(fd == nil)
		return "";
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

writefile(path, data: string): int
{
	fd := sys->open(path, OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

# Run a command module in a process group of its own, sharing this
# namespace, so what it mounts is seen here and it can be stopped later.
# The process stays until Delete, so the group has a member to send
# killgrp to.
cmdstop: chan of int;

runcmd(path: string, args: list of string, started: chan of int)
{
	pid := pctl(Sys->NEWPGRP, nil);
	m := load Command path;
	if(m == nil) {
		fprint(stderr, "Agent: cannot load %s: %r\n", path);
		started <-= -1;
		return;
	}
	{
		m->init(nil, args);
		started <-= pid;
	} exception e {
	"fail:*" =>
		fprint(stderr, "Agent: %s: %s\n", path, e[5:]);
		started <-= -1;
		return;
	}
	<-cmdstop;
}

# A live tool server has a registry; a stale /tool left on disk by an
# earlier run has empty files there.
toolsup(): int
{
	return readfile("/tool/_registry") != "";
}

startservers(paths, tools: string): string
{
	if(!exists("/mnt/llm/new"))
		return "no model at /mnt/llm (start llmsrv first)";
	started := chan of int;
	cmdstop = chan of int;
	if(!toolsup()) {
		if(tools == "")
			tools = DEFAULT_TOOLS;
		(nil, tlist) := sys->tokenize(tools, ",");
		spawn runcmd(TOOLS9P, "tools9p" :: tlist, started);
		if(<-started < 0)
			return "cannot start tools9p";
		# tools9p loads every tool module before it mounts; give it time.
		for(i := 0; i < 300 && !toolsup(); i++)
			sys->sleep(100);
		if(!toolsup())
			return "tools9p did not come up";
	}
	args := "veltrosrv" :: nil;
	if(verbose)
		args = "veltrosrv" :: "-v" :: nil;
	if(paths != "")
		args = "veltrosrv" :: "-p" :: paths :: tl args;
	spawn runcmd(VELTROSRV, args, started);
	srvpid = <-started;
	if(srvpid < 0)
		return "cannot start veltrosrv";
	return nil;
}

stopservers()
{
	sys->unmount(nil, "/mnt/veltro");
	if(srvpid > 0) {
		fd := sys->open("/prog/" + string srvpid + "/ctl", OWRITE);
		if(fd != nil)
			fprint(fd, "killgrp");
	}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	pctl(Sys->NEWPGRP, nil);
	stderr = fildes(2);
	win = load Xenithwin Xenithwin->PATH;
	win->init();
	str = load String String->PATH;
	arg = load Arg Arg->PATH;
	arg->init(args);
	paths := "";
	tools := "";
	first := "";
	while((c := arg->opt()) != 0)
	case c {
	'v' =>	verbose = 1;
	'p' =>	paths = arg->earg();
	't' =>	tools = arg->earg();
	'x' =>	first = arg->earg();
	* =>	usage();
	}
	if(arg->argv() != nil)
		usage();

	w := Win.wnew();
	w.wname("/+Agent");
	w.wtagwrite(" Send Stop Reset Allow Deny Delete");
	w.openbody(OWRITE);

	err: string;
	if(!exists("/mnt/veltro/new")) {
		if(paths == "") {
			# The directory this was run from: the project.
			cwd := sys->open(".", OREAD);
			if(cwd != nil)
				paths = sys->fd2path(cwd);
		}
		err = startservers(paths, tools);
	}
	if(err == nil) {
		sid := readfile("/mnt/veltro/new");
		while(len sid > 0 && (sid[len sid - 1] == '\n' || sid[len sid - 1] == ' '))
			sid = sid[0:len sid - 1];
		if(sid == "")
			err = "cannot start an agent session";
		else
			sess = "/mnt/veltro/" + sid;
	}
	if(err != nil) {
		w.wwritebody("Agent: " + err + "\n");
		w.ctlwrite("clean");
		mainwin(w, 0, "");
		return;
	}
	w.wwritebody("");
	w.ctlwrite("clean");
	mainwin(w, 1, first);
}

# Follow the session's text from offset until the turn is over.
follow(offset: big, out: chan of string)
{
	fd := sys->open(sess + "/text", OREAD);
	if(fd == nil) {
		out <-= nil;
		return;
	}
	buf := array[8192] of byte;
	for(;;) {
		n := pread(fd, buf, len buf, offset);
		if(n <= 0)
			break;
		offset += big n;
		out <-= string buf[0:n];
	}
	out <-= nil;
}

# Wait for a request for approval, until the turn is over.
approvals(out: chan of string)
{
	for(;;) {
		fd := sys->open(sess + "/approve", OREAD);
		if(fd == nil)
			break;
		buf := array[8192] of byte;
		n := sys->read(fd, buf, len buf);
		fd = nil;
		if(n <= 0)
			break;
		out <-= string buf[0:n];
	}
	out <-= nil;
}

mainwin(w: ref Win, live: int, first: string)
{
	c := chan of Event;
	hostpt := 0;		# end of what the host has written; the user types after it
	textc := chan of string;
	approvec := chan of string;
	textoff := big 0;
	followers := 0;

	spawn w.wslave(c);
	if(live && first != "" && writefile(sess + "/input", first) >= 0) {
		busy = 1;
		w.ctlwrite("dirty");
		followers = 2;
		spawn follow(textoff, textc);
		spawn approvals(approvec);
	}
	for(;;) alt {
	t := <-textc =>
		if(t == nil) {
			followers--;
			if(followers == 0) {
				busy = 0;
				w.ctlwrite("clean");
			}
			break;
		}
		textoff += big len array of byte t;
		hostpt = append(w, hostpt, t);
	a := <-approvec =>
		if(a == nil) {
			followers--;
			if(followers == 0) {
				busy = 0;
				w.ctlwrite("clean");
			}
			break;
		}
		(callid, rest) := str->splitl(a, " ");
		pending = callid;
		hostpt = append(w, hostpt, "== approve? (Allow or Deny)\n" + str->drop(rest, " "));
	e := <-c =>
		case e.c1 {
		'M' or 'K' =>
			case e.c2 {
			'I' =>
				if(e.q0 < hostpt)
					hostpt += e.q1 - e.q0;
			'D' =>
				if(e.q0 < hostpt) {
					if(hostpt < e.q1)
						hostpt = e.q0;
					else
						hostpt -= e.q1 - e.q0;
				}
			'x' or 'X' =>
				s: string;
				eq := e;
				if(e.flag & 2)
					eq = <-c;
				if(e.flag & 8) {
					<-c;
					<-c;
				}
				if(eq.q1 > eq.q0 && eq.nb == 0)
					s = w.wread(eq.q0, eq.q1);
				else
					s = string eq.b[0:eq.nb];
				cmd := word(s);
				case cmd {
				"Send" =>
					if(!live || busy)
						break;
					(nil, q1) := bodyend(w);
					input := w.wread(hostpt, q1);
					if(trim(input) == "")
						break;
					w.wreplace(sprint("#%d,#%d", hostpt, q1), "");
					if(writefile(sess + "/input", input) < 0) {
						hostpt = append(w, hostpt, sprint("== note\n(cannot send: %r)\n"));
						break;
					}
					busy = 1;
					w.ctlwrite("dirty");
					followers = 2;
					spawn follow(textoff, textc);
					spawn approvals(approvec);
				"Stop" =>
					if(live)
						writefile(sess + "/ctl", "cancel");
				"Reset" =>
					if(live && !busy)
						writefile(sess + "/ctl", "reset");
				"Allow" or "Deny" =>
					if(pending != "") {
						writefile(sess + "/approve", str->tolower(cmd) + " " + pending);
						pending = "";
					}
				"Del" or "Delete" =>
					if(live) {
						writefile(sess + "/ctl", "cancel");
						writefile(sess + "/ctl", "close");
					}
					stopservers();
					w.wdel(1);
					exit;
				* =>
					w.wwriteevent(ref e);
				}
			'l' or 'L' =>
				w.wwriteevent(ref e);
			}
		}
	}
}

# Insert text at the host point, keeping what the user typed after it.
append(w: ref Win, hostpt: int, t: string): int
{
	if(w.wsetaddr(sprint("#%d", hostpt), 1) == 0) {
		w.wsetaddr("$", 1);
		(nil, hostpt, nil) = readaddr(w);
	}
	w.wreplace(sprint("#%d,#%d", hostpt, hostpt), t);
	return hostpt + len t;
}

bodyend(w: ref Win): (int, int)
{
	w.wsetaddr("$", 1);
	(nil, q0, q1) := readaddr(w);
	return (q0, q1);
}

readaddr(w: ref Win): (int, int, int)
{
	buf := array[24] of byte;
	if(pread(w.addr, buf, 24, big 0) <= 0)
		return (-1, 0, 0);
	(n, nil) := str->toint(string buf[:12], 10);
	(m, nil) := str->toint(string buf[12:], 10);
	return (0, n, m);
}

word(s: string): string
{
	s = trim(s);
	(w, nil) := str->splitl(s, " \t\r\n");
	return w;
}

trim(s: string): string
{
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t' || s[0] == '\n' || s[0] == '\r'))
		s = s[1:];
	while(len s > 0 && (s[len s - 1] == ' ' || s[len s - 1] == '\t' || s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}
