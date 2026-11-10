implement Ns2mmd;

#
# ns2mmd - the machines a name space spans, from ns(1)'s lines, as a
# Mermaid flowchart (mermaid(2)): one node for this machine, one for
# each machine a mount reaches, an edge for each remote mount.
#
# A filter on a stream: the lines of a name space, a blank line (or
# the end) ending each; for each, a chart, ended by a line holding only
# a form feed, unless it is the one written last.  So
#
#	{while {} {ns; echo; sleep 1}} | ns2mmd | wm/page -s
#
# draws the name space as it changes.  A mount's source is resolved by
# reading files, on the machine ns2mmd runs on: an encrypted one's
# (#D/n/data) through #D/n/lower to its connection, a connection's
# (/net/tcp/n/data) through its remote, the address named by ndb.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "attrdb.m";
	attrdb: Attrdb;
	Db, Dbentry: import attrdb;
include "arg.m";

Ns2mmd: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Remote: adt {
	addr:	string;		# ip!port, as the connection's remote has it, or host!service as dialled
	enc:	int;		# under an encrypted conversation (#D)
	src:	string;		# the source as ns names it, if local
};

db: ref Db;
all := 0;
here := "this machine";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	attrdb = load Attrdb Attrdb->PATH;
	arg := load Arg Arg->PATH;
	if(bufio == nil || str == nil || arg == nil){
		sys->fprint(sys->fildes(2), "ns2mmd: cannot load modules: %r\n");
		raise "fail:load";
	}
	arg->init(args);
	arg->setusage("ns2mmd [-a] [-n name]");
	while((o := arg->opt()) != 0)
		case o {
		'a' =>	all = 1;	# local mounts too
		'n' =>	here = arg->earg();
		* =>	arg->usage();
		}
	if(here == "this machine")
		here = sysname();
	if(attrdb != nil && attrdb->init() == nil){
		for(f := "/lib/ndb/local" :: "/lib/ndb/inferno" :: "/lib/ndb/common" :: nil; f != nil; f = tl f){
			d := Db.open(hd f);
			if(d == nil)
				continue;
			if(db == nil)
				db = d;
			else
				db = db.append(d);
		}
	}

	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	out := bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	last := "";
	snap: list of string;
	for(;;){
		# the end of the input, told apart from a blank line before
		# the newline goes: an empty string is nil in Limbo
		l := in.gets('\n');
		eof := l == nil;
		if(len l > 0 && l[len l - 1] == '\n')
			l = l[0:len l - 1];
		if(eof || l == ""){
			# the end of a name space: its chart, if changed
			if(snap != nil){
				c := chart(rev(snap));
				if(c != last){
					out.puts(c);
					out.puts("\f\n");
					out.flush();
					last = c;
				}
				snap = nil;
			}
			if(eof)
				break;
			continue;
		}
		snap = l :: snap;
	}
}

# the chart of a name space's lines
chart(lines: list of string): string
{
	# machines in the order first met, and the mounts from each
	hosts: list of string;		# keys: an address's host, or a local source
	labels: list of (string, string);	# key, node label
	edges: list of (string, string);	# key, edge label
	for(; lines != nil; lines = tl lines){
		w := str->unquoted(hd lines);
		if(w == nil || hd w != "mount")
			continue;
		w = tl w;
		while(w != nil && len hd w > 0 && (hd w)[0] == '-')
			w = tl w;
		if(w == nil || tl w == nil)
			continue;
		(src, mnt) := (hd w, hd tl w);
		r := resolve(src);
		key, node, edge: string;
		if(r.addr != nil){
			(ip, port) := splitaddr(r.addr);
			if(!isip(ip) && (a := hostip(ip)) != nil)
				ip = a;		# dialled by name: keyed by address, as a connection is
			key = ip;
			node = hostname(ip);
			if(node != ip)
				node += "<br/>" + ip;
			edge = service(port) + " · " + mnt;
			if(r.enc)
				edge += "<br/>encrypted";
		} else if(all){
			key = src;
			node = src;
			edge = mnt;
		} else
			continue;
		if(!member(key, hosts)){
			hosts = key :: hosts;
			labels = (key, node) :: labels;
		}
		edges = (key, edge) :: edges;
	}
	hosts = rev(hosts);
	edges = reve(edges);

	c := "flowchart LR\n";
	c += "    me[\"" + clean(here) + "\"]\n";
	n := 0;
	ids: list of (string, string);
	for(h := hosts; h != nil; h = tl h){
		id := "h" + string n++;
		ids = (hd h, id) :: ids;
		c += "    " + id + "[\"" + clean(lookup(labels, hd h)) + "\"]\n";
	}
	for(e := edges; e != nil; e = tl e){
		(k, lbl) := hd e;
		c += "    " + lookup(ids, k) + " -->|\"" + clean(lbl) + "\"| me\n";
	}
	return c;
}

# a mount's source: an encrypted conversation's to its connection, a
# connection's to its remote address
resolve(src: string): Remote
{
	r := Remote(nil, 0, src);
	p := src;
	# a dial string, as an unencrypted mount of one shows it
	# (tcp!pi5!video, net!192.168.1.100!17050): host and service
	(n, f) := sys->tokenize(p, "!");
	if(n == 3 && len p > 0 && p[0] != '#' && p[0] != '/'){
		r.addr = hd tl f + "!" + hd tl tl f;
		return r;
	}
	if(len p > 2 && p[0:2] == "#D" && suffix(p, "/data")){
		lower := readfile(p[0:len p - len "/data"] + "/lower");
		if(lower == nil)
			return r;
		r.enc = 1;
		p = lower;
	}
	if(suffix(p, "/data")){
		dir := p[0:len p - len "/data"];
		# .../tcp/3, .../udp/0, .../il/2
		(nil, parts) := sys->tokenize(dir, "/");
		if(len parts >= 2){
			proto := hd tl rev(parts);
			if(proto == "tcp" || proto == "udp" || proto == "il"){
				a := readfile(dir + "/remote");
				if(a != nil)
					r.addr = a;
			}
		}
	}
	return r;
}

splitaddr(a: string): (string, string)
{
	for(i := len a - 1; i >= 0; i--)
		if(a[i] == '!')
			return (a[0:i], a[i+1:]);
	return (a, "");
}

# ndb's name for a machine, or its address
hostname(ip: string): string
{
	if(db == nil)
		return ip;
	(e, nil) := db.findpair(nil, "ip", ip);
	if(e != nil && (s := e.findfirst("sys")) != nil)
		return s;
	return ip;
}

# ndb's address for a machine's name, or nil
hostip(name: string): string
{
	if(db == nil)
		return nil;
	(e, nil) := db.findpair(nil, "sys", name);
	if(e != nil)
		return e.findfirst("ip");
	return nil;
}

isip(s: string): int
{
	if(s == nil)
		return 0;
	for(i := 0; i < len s; i++)
		if(!(s[i] >= '0' && s[i] <= '9' || s[i] == '.' || s[i] == ':' || s[i] >= 'a' && s[i] <= 'f'))
			return 0;
	return 1;
}

# ndb's name for a tcp port (tcp=video port=17050), or the port; a
# service already named is left so
service(port: string): string
{
	if(db == nil || port == "" || !isnum(port))
		return port;
	(e, nil) := db.findpair(nil, "port", port);
	if(e != nil && (s := e.findfirst("tcp")) != nil)
		return s;
	return port;
}

sysname(): string
{
	s := readfile("/dev/sysname");
	if(s == nil)
		return "this machine";
	return s;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	s := string b[0:n];
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

# what may not go in a quoted Mermaid label
clean(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] == '"')
			r[len r] = '\'';
		else
			r[len r] = s[i];
	return r;
}

isnum(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return len s > 0;
}

suffix(s, x: string): int
{
	return len s >= len x && s[len s - len x:] == x;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

lookup(l: list of (string, string), k: string): string
{
	for(; l != nil; l = tl l)
		if((hd l).t0 == k)
			return (hd l).t1;
	return k;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

reve(l: list of (string, string)): list of (string, string)
{
	r: list of (string, string);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
