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
# for the hosts named in $XEN_HOSTS).
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
	arg->init(args);
	arg->setusage("hostplumb [-r root]");
	while((c := arg->opt()) != 0)
		case c {
		'r' =>
			root = arg->earg();
		* =>
			arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	if(root == "/")
		root = "";

	if(plumbmsg->init(1, nil, 0) < 0)
		fail(sys->sprint("cannot connect to the plumber: %r"));

	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	while((m := readmsg(in)) != nil){
		r := root;
		(ok, host) := attr(m.attr, "host");
		if(ok && host != nil){
			if(!validhost(host)){
				sys->fprint(stderr, "hostplumb: bad host name %q\n", host);
				continue;
			}
			r = "/n/" + host;
		}
		m = local(m, r);
		# the receiver may still be starting (a message can arrive as
		# soon as the host's plumber sees this reader): retry a while
		for(i := 0; m.send() < 0; i++){
			if(i == Retries){
				sys->fprint(stderr, "hostplumb: plumb %s: %r\n", string m.data);
				break;
			}
			sys->sleep(Retrywait);
		}
	}
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
	if(n < 0)
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
local(m: ref Msg, root: string): ref Msg
{
	data := string m.data;
	if(m.kind == "text" && data != nil){
		if(data[0] != '/' && m.dir != nil)
			data = m.dir + "/" + data;
		if(data[0] == '/')
			data = root + data;
		(ok, addr) := attr(m.attr, "addr");
		if(ok && addr != nil)
			data += ":" + addr;
	}
	dir := m.dir;
	if(dir != nil && dir[0] == '/')
		dir = root + dir;
	# no destination or attributes: this namespace's rules decide
	return ref Msg("hostplumb", nil, dir, m.kind, nil, array of byte data);
}

fail(s: string)
{
	sys->fprint(stderr, "hostplumb: %s\n", s);
	raise "fail:" + s;
}
