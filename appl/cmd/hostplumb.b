implement Hostplumb;

#
# hostplumb - re-plumb messages from the host's plumber
#
# Reads plumb messages, in the standard format, on standard input:
# typically the output of plan9port's `9p read plumb/port', run on the
# host with os(1). Each message's host paths are placed under root,
# a file address is folded back into the data, and the message is
# plumbed here, where this namespace's rules route it.
#
# A message from another host (attr host=name, sent by tools/rplumb on
# that host) has its paths placed under /n/name instead, where that
# host's file system is mounted (tools/xen does it, before Xenith starts,
# for the hosts named in $XEN_HOSTS), if -h names that host: a message
# says its own host, and one that named any other mount under /n (or
# "local", this machine's own files) was taken at its word.
#
# With -p it reads plain host paths instead, one to a line: files the
# host asked this InferNode to open (the emulator's /dev/hostopen, fed
# by Finder's Open With and files dropped on the window). A Windows
# path on C:, the drive mounted at /n/local, is made a Unix one.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "string.m";
	str: String;

include "plumbmsg.m";
	plumbmsg: Plumbmsg;
	Msg: import plumbmsg;

Hostplumb: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Retries: con 30;
Retrywait: con 500;	# ms; 15s in all
hosts: list of string;	# -h: the hosts whose messages are taken

stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		fail(sys->sprint("cannot load %s: %r", Bufio->PATH));
	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	if(plumbmsg == nil)
		fail(sys->sprint("cannot load %s: %r", Plumbmsg->PATH));
	str = load String String->PATH;
	if(str == nil)
		fail(sys->sprint("cannot load %s: %r", String->PATH));
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load %s: %r", Arg->PATH));

	root := "/n/local";
	plain := 0;
	arg->init(args);
	arg->setusage("hostplumb [-p] [-r root] [-h host,...]");
	while((c := arg->opt()) != 0)
		case c {
		'p' =>
			plain = 1;
		'h' =>
			(nil, hl) := sys->tokenize(arg->earg(), ", ");
			for(; hl != nil; hl = tl hl)
				hosts = hd hl :: hosts;
		'r' =>
			root = arg->earg();
		* =>
			arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	if(root == "/")
		root = "";

	# the plumber may still be starting (tools/xen runs this before
	# lib/xen/boot.sh starts it): retry a while
	for(n := 0; plumbmsg->init(1, nil, 0) < 0; n++){
		if(n == Retries)
			fail(sys->sprint("cannot connect to the plumber: %r"));
		sys->sleep(Retrywait);
	}

	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	if(plain){
		while((s := in.gets('\n')) != nil){
			p := hostpath(s);
			if(p != nil && (m := local(ref Msg("hostopen", nil, "/", "text", nil, array of byte p), root, "hostopen")) != nil)
				send(m);
		}
		return;
	}
	while((m := readmsg(in)) != nil){
		r := root;
		(ok, host) := attr(m.attr, "host");
		if(ok && host != nil){
			if(!validhost(host) || !member(host, hosts)){
				sys->fprint(stderr, "hostplumb: a message from host %q, which is not one of -h's: dropped\n", host);
				continue;
			}
			r = "/n/" + host;
		}
		if((lm := local(m, r, "hostplumb")) != nil)
			send(lm);
	}
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

# The receiver may still be starting (a message can arrive as soon as
# the host's plumber sees this reader): retry a while.  Only that: a
# message no rule takes is refused at once and will be at every try,
# and each such message held the stream for the whole fifteen seconds.
send(m: ref Msg)
{
	for(i := 0; m.send() < 0; i++){
		e := sys->sprint("%r");
		if(i == Retries || !waitable(e)){
			sys->fprint(stderr, "hostplumb: plumb %s: %s\n", string m.data, e);
			return;
		}
		sys->sleep(Retrywait);
	}
}

# whether a refusal may pass: no receiver yet, not no rule
waitable(e: string): int
{
	for(i := 0; i + 4 <= len e; i++)
		if(e[i:i+4] == "rule")
			return 0;
	return 1;
}

# one line of -p: an absolute host path, a Windows one on C: made a
# Unix one; nil for anything else
hostpath(s: string): string
{
	while(s != nil && (s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	if(s == nil)
		return nil;
	if(len s >= 3 && s[1] == ':' && (s[2] == '\\' || s[2] == '/')){
		if(s[0] != 'C' && s[0] != 'c'){
			sys->fprint(stderr, "hostplumb: %s is not on C:, the drive at /n/local\n", s);
			return nil;
		}
		s = s[2:];
		for(i := 0; i < len s; i++)
			if(s[i] == '\\')
				s[i] = '/';
	}
	if(s[0] != '/'){
		sys->fprint(stderr, "hostplumb: %s is not an absolute path\n", s);
		return nil;
	}
	# a whole line is a path here, colons and all
	(nil, el) := sys->tokenize(s, "/");
	for(; el != nil; el = tl el)
		if(hd el == ".."){
			sys->fprint(stderr, "hostplumb: %s goes through ..\n", s);
			return nil;
		}
	return s;
}

# An attribute of a message from plan9port's plumber, whose attributes
# are separated by blanks, a value with blanks in it quoted (not the
# tabs of plumbmsg's string2attrs).
attr(attrs, name: string): (int, string)
{
	for(l := str->unquoted(attrs); l != nil; l = tl l){
		(n, v) := str->splitl(hd l, "=");
		if(n == name && v != nil)
			return (1, v[1:]);
	}
	return (0, nil);
}

# a host name goes into a path: letters, digits, - . _
validhost(h: string): int
{
	if(h == nil || h[0] == '.' || h[0] == '-')
		return 0;
	for(i := 0; i < len h; i++){
		c := h[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		    c == '-' || c == '.' || c == '_'))
			return 0;
	}
	return 1;
}

# whether a path has a ".." element; its address (after a colon) is
# not part of the path
dotdot(p: string): int
{
	st := 0;
	for(i := 0; i <= len p; i++)
		if(i == len p || p[i] == '/' || p[i] == ':'){
			if(p[st:i] == "..")
				return 1;
			if(i < len p && p[i] == ':')
				return 0;
			st = i + 1;
		}
	return 0;
}

Maxdata: con 1024*1024;	# a message's data

# one message: six header lines, then the data
readmsg(in: ref Iobuf): ref Msg
{
	h := array[6] of string;
	for(i := 0; i < len h; i++){
		s := in.gets('\n');
		if(s == nil)
			return nil;
		if(s[len s - 1] == '\n')
			s = s[0:len s - 1];
		h[i] = s;
	}
	n := int h[5];
	if(n < 0 || n > Maxdata)
		return nil;
	data := array[n] of byte;
	for(i = 0; i < n; ){
		r := in.read(data[i:], n - i);
		if(r <= 0)
			return nil;
		i += r;
	}
	return ref Msg(h[0], h[1], h[2], h[3], h[4], data);
}

# host paths to paths under root; the host's rules may already have
# made the data absolute and moved its address into an addr attribute
# (nil for a message that names no place under root: a path through
# "..", which left the root for this machine's own files, or one that
# is not absolute and has no absolute directory to make it so, which
# was passed on as it came and read here as a name of this name space)
# src is the caller's word for where it came from: a message said
# "hostopen" of itself and was plumbed under the rules for files the
# host asked to open, which take any name.
local(m: ref Msg, root: string, src: string): ref Msg
{
	data := string m.data;
	if(m.dir != nil && (m.dir[0] != '/' || dotdot(m.dir))){
		sys->fprint(stderr, "hostplumb: %q is not a directory of the host's: message dropped\n", m.dir);
		return nil;
	}
	if(m.kind == "text" && data != nil){
		if(data[0] != '/' && m.dir != nil)
			data = m.dir + "/" + data;
		if(data[0] != '/' || dotdot(data)){
			sys->fprint(stderr, "hostplumb: %q is not a path of the host's: message dropped\n", data);
			return nil;
		}
		data = root + data;
		(ok, addr) := attr(m.attr, "addr");
		if(ok && addr != nil)
			data += ":" + addr;
	}
	dir := m.dir;
	if(dir != nil && dir[0] == '/')
		dir = root + dir;
	# no destination or attributes: this namespace's rules decide
	return ref Msg(src, nil, dir, m.kind, nil, array of byte data);
}

fail(s: string)
{
	sys->fprint(stderr, "hostplumb: %s\n", s);
	raise "fail:" + s;
}
