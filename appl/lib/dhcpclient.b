implement Dhcpclient;

#
# The client side of DHCP (RFC 2131) and of the BOOTP it grew out of
# (RFC 951, with the option encoding of RFC 2132).
#
# The interface this satisfies -- module/dhcp.m, documented in
# dhcpclient(2) -- has been in the tree for years with nothing behind
# it: ip/dhcp loaded /dis/lib/dhcpclient.dis and got "module not
# loaded", so a machine with a working link had no way to acquire an
# address. The wire behaviour here follows the exchange in
# os/init/etherusb.b, which has taken addresses from real servers on
# real hardware; what is added is everything a library owes a caller
# that the driver's private copy did not need: the lease and its
# renewal, options the caller asks for rather than a fixed pair,
# configuration applied to an interface the caller names, and errors
# returned instead of printed.
#
# Nothing here writes to the console unless tracing is on. A library
# that prints is unusable inside a boot sequence: the caller decides
# what the console says, and at boot the caller is init.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "dhcp.m";

#
# Deliberately no dependency on the IP module.
#
# It would supply dotted-quad parsing and the UDP header packing, and
# reuse would normally settle it. It cannot here: dhcpclient(2) says a
# caller may fill in a Bootconf -- Bootconf.new, puts, putips -- before
# calling init, and ip/dhcp does exactly that while parsing its
# arguments. A putips that needed a loaded IP module would fault on a
# value built one line before the module was loaded. DHCP is IPv4 only,
# so what is needed is a dotted quad and a fixed 52-byte header, and
# both are a dozen lines.
#

Bootpsize:	con 236;	# fixed part, before the options
Maxmsg:		con 576;	# the least a server must accept: RFC 2131 2.
Udphdrlen:	con 52;		# raddr, laddr, ifcaddr, rport, lport
Ipaddrlen:	con 16;

Serverport:	con 67;
Clientport:	con 68;

Bootrequest:	con 1;
Bootreply:	con 2;
Ethernet:	con 1;		# htype
Eaddrlen:	con 6;		# hlen

# DHCP message types: option Otype
Discover:	con 1;
Offer:		con 2;
Request:	con 3;
Decline:	con 4;
Ack:		con 5;
Nak:		con 6;
Release:	con 7;
Inform:		con 8;

# offsets within the fixed part
Aop:		con 0;
Ahtype:		con 1;
Ahlen:		con 2;
Ahops:		con 3;
Axid:		con 4;
Asecs:		con 8;
Aflags:		con 10;
Aciaddr:	con 12;
Ayiaddr:	con 16;
Asiaddr:	con 20;
Agiaddr:	con 24;
Achaddr:	con 28;
Asname:		con 44;
Asnamelen:	con 64;
Afile:		con 108;
Afilelen:	con 128;

Fbroadcast:	con 16r8000;	# "answer me by broadcast": RFC 2131 4.1

# option overload (RFC 2132 9.3)
Overfile:	con 1;
Oversname:	con 2;

Bcast:		con "255.255.255.255";
Anyaddr:	con "0.0.0.0";

#
# Retransmission. RFC 2131 4.1 asks for a doubling backoff; four tries
# at 2, 4, 8 and 16 seconds bounds a failed attempt at thirty seconds,
# which is short enough that a caller at boot is not left wondering and
# long enough to cross a switch port coming out of learning.
#
Timeout0:	con 2000;	# ms, doubled each try
Ntries:		con 4;
Napmax:		con 600;	# s, longest single sleep in the watchdog
Stopwait:	con 5000;	# ms release() waits for the watchdog to finish
Retrywait:	con 30;		# s between attempts to replace a lost lease

debugflag := 0;

#
# Sessions are registered by watchdog pid, because Lease -- whose shape
# is fixed by module/dhcp.m -- carries only a pid and the notification
# channel, and release must find the rest.
#
Session: adt {
	net:	string;
	ctlifc:	ref Sys->FD;
	cfd:	ref Sys->FD;	# the UDP conversation's control file
	dfd:	ref Sys->FD;	# its data file
	mac:	array of byte;
	xid:	int;
	t0:	int;		# millisec at the start, for the secs field
	rc:	chan of array of byte;
	rpid:	int;		# the reader
	req:	ref Bootconf;	# what the caller asked to be sent
	params:	array of int;	# the parameter request list
	conf:	ref Bootconf;	# what the server said
	lease:	ref Lease;
	halt:	int;
	stop:	chan of int;
	done:	chan of int;
};

sessions: list of ref Session;
lock: chan of int;
ndbtext: string;		# the block applycfg appended to net/ndb

init()
{
	if(sys != nil)
		return;
	sys = load Sys Sys->PATH;
	lock = chan[1] of int;
}

tracing(debug: int)
{
	debugflag = debug;
}

trace(s: string)
{
	if(debugflag && sys != nil)
		sys->fprint(sys->fildes(2), "dhcpclient: %s\n", s);
}

# --- Bootconf ------------------------------------------------------

Bootconf.new(): ref Bootconf
{
	c := ref Bootconf;
	c.options = array[256] of array of byte;
	c.vendor = array[256] of array of byte;
	return c;
}

#
# Which array an option number names, and where in it. The Ovendor bit
# marks an option that travels inside option 43 rather than on its own.
#
slot(c: ref Bootconf, n: int): (array of array of byte, int)
{
	if(n & Ovendor){
		if(c.vendor == nil)
			c.vendor = array[256] of array of byte;
		return (c.vendor, n & 16rFF);
	}
	if(c.options == nil)
		c.options = array[256] of array of byte;
	return (c.options, n & 16rFF);
}

Bootconf.get(c: self ref Bootconf, n: int): array of byte
{
	(a, i) := slot(c, n);
	v := a[i];
	if(v == nil)
		return nil;
	r := array[len v] of byte;
	r[0:] = v;
	return r;
}

Bootconf.getint(c: self ref Bootconf, n: int): int
{
	v := c.get(n);
	if(v == nil)
		return 0;
	r := 0;
	for(i := 0; i < len v && i < 4; i++)
		r = (r << 8) | int v[i];
	return r;
}

Bootconf.getip(c: self ref Bootconf, n: int): string
{
	v := c.get(n);
	if(v == nil || len v < 4)
		return nil;
	return dotted(v, 0);
}

Bootconf.getips(c: self ref Bootconf, n: int): list of string
{
	v := c.get(n);
	l: list of string;
	if(v == nil)
		return nil;
	for(i := (len v/4)*4 - 4; i >= 0; i -= 4)
		l = dotted(v, i) :: l;
	return l;
}

Bootconf.gets(c: self ref Bootconf, n: int): string
{
	v := c.get(n);
	if(v == nil)
		return nil;
	e := len v;
	while(e > 0 && v[e-1] == byte 0)	# servers pad names with NUL
		e--;
	return string v[0:e];
}

Bootconf.put(c: self ref Bootconf, n: int, a: array of byte)
{
	(s, i) := slot(c, n);
	if(a == nil){
		s[i] = nil;
		return;
	}
	v := array[len a] of byte;
	v[0:] = a;
	s[i] = v;
}

Bootconf.putint(c: self ref Bootconf, n: int, v: int)
{
	a := array[4] of byte;
	a[0] = byte (v >> 24);
	a[1] = byte (v >> 16);
	a[2] = byte (v >> 8);
	a[3] = byte v;
	c.put(n, a);
}

Bootconf.putips(c: self ref Bootconf, n: int, ips: list of string)
{
	a := array[4 * lenl(ips)] of byte;
	o := 0;
	for(; ips != nil; ips = tl ips){
		(ok, q) := parsev4(hd ips);
		if(!ok)
			continue;
		a[o:] = q;
		o += 4;
	}
	if(o == 0){
		c.put(n, nil);
		return;
	}
	c.put(n, a[0:o]);
}

Bootconf.puts(c: self ref Bootconf, n: int, s: string)
{
	if(s == nil){
		c.put(n, nil);
		return;
	}
	c.put(n, array of byte s);
}

lenl(l: list of string): int
{
	n := 0;
	for(; l != nil; l = tl l)
		n++;
	return n;
}

# --- dotted quads --------------------------------------------------

dotted(a: array of byte, o: int): string
{
	return sys->sprint("%d.%d.%d.%d", int a[o], int a[o+1], int a[o+2], int a[o+3]);
}

parsev4(s: string): (int, array of byte)
{
	a := array[4] of byte;
	i := 0;
	for(f := 0; f < 4; f++){
		v := 0;
		d := 0;
		while(i < len s && s[i] >= '0' && s[i] <= '9'){
			v = v*10 + (s[i] - '0');
			if(v > 255)
				return (0, nil);
			i++;
			d++;
		}
		if(d == 0)
			return (0, nil);
		a[f] = byte v;
		if(f < 3){
			if(i >= len s || s[i] != '.')
				return (0, nil);
			i++;
		}
	}
	if(i != len s)
		return (0, nil);
	return (1, a);
}

iszero(a: array of byte, o: int): int
{
	for(i := 0; i < 4; i++)
		if(a[o+i] != byte 0)
			return 0;
	return 1;
}

#
# The mask a server did not send. RFC 2131 lets a reply leave option 1
# out; the class of the address is the only thing left to go on, and it
# beats configuring an interface with no mask at all.
#
classmask(a: string): string
{
	(ok, q) := parsev4(a);
	if(!ok)
		return "255.255.255.0";
	b := int q[0];
	if(b < 128)
		return "255.0.0.0";
	if(b < 192)
		return "255.255.0.0";
	return "255.255.255.0";
}

# --- options -------------------------------------------------------

putopt(p: array of byte, o: int, kind: int, v: array of byte): int
{
	n := len v;
	if(v == nil || n == 0 || n > 255)
		return o;
	if(o + 2 + n + 1 > len p){	# +1: room for Oend
		trace(sys->sprint("option %d does not fit, dropped", kind));
		return o;
	}
	p[o++] = byte kind;
	p[o++] = byte n;
	p[o:] = v;
	return o + n;
}

putopt1(p: array of byte, o: int, kind: int, v: int): int
{
	a := array[1] of byte;
	a[0] = byte v;
	return putopt(p, o, kind, a);
}

putopt2(p: array of byte, o: int, kind: int, v: int): int
{
	a := array[2] of byte;
	a[0] = byte (v >> 8);
	a[1] = byte v;
	return putopt(p, o, kind, a);
}

#
# An option seen twice is one option split in two: RFC 3396. Appending
# rather than replacing is what makes a long option list (a domain
# search, a row of name servers) come back whole.
#
addopt(c: ref Bootconf, kind: int, v: array of byte)
{
	(s, i) := slot(c, kind);
	old := s[i];
	if(old == nil){
		s[i] = v;
		return;
	}
	n := array[len old + len v] of byte;
	n[0:] = old;
	n[len old:] = v;
	s[i] = n;
}

#
# Walk a run of type-length-value options, returning the overload byte
# if one was seen. Stops at Oend or at a length that runs off the end,
# so a truncated or hostile reply cannot walk past its own buffer.
#
walkopts(c: ref Bootconf, p: array of byte, o: int, e: int): int
{
	overload := 0;
	while(o < e){
		kind := int p[o];
		if(kind == Oend)
			break;
		if(kind == Opad){
			o++;
			continue;
		}
		if(o + 2 > e)
			break;
		olen := int p[o+1];
		if(o + 2 + olen > e)
			break;
		v := array[olen] of byte;
		v[0:] = p[o+2:o+2+olen];
		if(kind == Ooverload && olen >= 1)
			overload = int v[0];
		addopt(c, kind, v);
		if(kind == Ovendorinfo)
			walkvendor(c, v);
		o += 2 + olen;
	}
	return overload;
}

#
# Option 43 carries a second option list of its own, and Plan 9 puts
# the file server and auth server addresses in it. Those arrive as
# Ovendor|n.
#
walkvendor(c: ref Bootconf, v: array of byte)
{
	o := 0;
	while(o < len v){
		kind := int v[o];
		if(kind == Oend)
			break;
		if(kind == Opad){
			o++;
			continue;
		}
		if(o + 2 > len v)
			break;
		olen := int v[o+1];
		if(o + 2 + olen > len v)
			break;
		a := array[olen] of byte;
		a[0:] = v[o+2:o+2+olen];
		addopt(c, Ovendor|kind, a);
		o += 2 + olen;
	}
}

hascookie(p: array of byte, n: int): int
{
	if(n < Bootpsize + 4)
		return 0;
	return int p[Bootpsize] == 99 && int p[Bootpsize+1] == 130 &&
		int p[Bootpsize+2] == 83 && int p[Bootpsize+3] == 99;
}

msgtype(p: array of byte, n: int): int
{
	if(!hascookie(p, n))
		return 0;
	c := Bootconf.new();
	walkopts(c, p, Bootpsize+4, n);
	v := c.get(Otype);
	if(v == nil || len v < 1)
		return 0;
	return int v[0];
}

#
# Turn a reply into a Bootconf.
#
parsemsg(p: array of byte, n: int): (ref Bootconf, string)
{
	if(n < Bootpsize)
		return (nil, "short reply");
	if(int p[Aop] != Bootreply)
		return (nil, "not a BOOTP reply");
	c := Bootconf.new();
	overload := 0;
	if(hascookie(p, n))
		overload = walkopts(c, p, Bootpsize+4, n);
	#
	# RFC 2132 9.3: a server short of room continues the options in
	# the file and sname fields. Those fields then mean nothing else,
	# which is why bootf and sys are taken from them only when the
	# overload byte says they are still names.
	#
	if((overload & Overfile) && n >= Afile+Afilelen)
		walkopts(c, p, Afile, Afile+Afilelen);
	if((overload & Oversname) && n >= Asname+Asnamelen)
		walkopts(c, p, Asname, Asname+Asnamelen);

	c.ip = dotted(p, Ayiaddr);
	if(iszero(p, Ayiaddr))
		c.ip = nil;
	if(!iszero(p, Asiaddr))
		c.siaddr = dotted(p, Asiaddr);
	c.serverid = c.getip(Oserverid);
	c.dhcpip = c.serverid;
	if(c.dhcpip == nil)
		c.dhcpip = c.siaddr;
	c.ipmask = c.getip(Omask);
	if(c.ipmask == nil && c.ip != nil)
		c.ipmask = classmask(c.ip);
	c.ipgw = c.getip(Orouter);
	if(c.ipgw == nil && !iszero(p, Agiaddr))
		c.ipgw = dotted(p, Agiaddr);
	c.sys = c.gets(Ohostname);
	c.dom = c.gets(Odomainname);
	c.lease = c.getint(Olease);
	c.bootip = c.getip(Otftpserver);
	if(c.bootip == nil)
		c.bootip = c.siaddr;
	c.bootf = c.gets(Obootfile);
	if(c.bootf == nil && (overload & Overfile) == 0 && n >= Afile+Afilelen)
		c.bootf = cstr(p, Afile, Afilelen);
	if(c.sys == nil && (overload & Oversname) == 0 && n >= Asname+Asnamelen)
		c.sys = cstr(p, Asname, Asnamelen);
	return (c, nil);
}

cstr(p: array of byte, o: int, n: int): string
{
	e := o;
	while(e < o+n && p[e] != byte 0)
		e++;
	if(e == o)
		return nil;
	return string p[o:e];
}

#
# The options this client asks a server to send when the caller named
# none. Anything Inferno can act on without a second exchange.
#
defparams(): array of int
{
	return array[] of {
		Omask, Orouter, Odnsserver, Ohostname, Odomainname,
		Ontpserver, Ovendorinfo, Olease, Orenewaltime,
		Orebindingtime,
	};
}

#
# A caller may ask for a vendor option (OP9fs, say). Those are not
# option numbers on the wire: they live inside option 43, so what goes
# in the parameter request list is 43.
#
mkparams(options: array of int): array of int
{
	if(options == nil)
		options = defparams();
	seen := array[256] of int;
	p := array[256] of int;
	n := 0;
	for(i := 0; i < len options; i++){
		o := options[i];
		if(o & Ovendor)
			o = Ovendorinfo;
		o &= 16rFF;
		if(o == Opad || o == Oend || seen[o])
			continue;
		seen[o] = 1;
		p[n++] = o;
	}
	return p[0:n];
}

#
# Build one message. Returns the length of the body.
#
mkmsg(s: ref Session, body: array of byte, kind: int, ciaddr, reqaddr, srvid: array of byte): int
{
	for(i := 0; i < Bootpsize; i++)
		body[i] = byte 0;
	body[Aop] = byte Bootrequest;
	body[Ahtype] = byte Ethernet;
	body[Ahlen] = byte Eaddrlen;
	body[Ahops] = byte 0;
	body[Axid] = byte (s.xid >> 24);
	body[Axid+1] = byte (s.xid >> 16);
	body[Axid+2] = byte (s.xid >> 8);
	body[Axid+3] = byte s.xid;
	secs := (sys->millisec() - s.t0) / 1000;
	if(secs < 0 || secs > 16rFFFF)		# millisec wraps; secs must not
		secs = 16rFFFF;
	body[Asecs] = byte (secs >> 8);
	body[Asecs+1] = byte secs;
	if(ciaddr != nil)
		body[Aciaddr:] = ciaddr[0:4];
	else{
		#
		# With no address there is nothing for a unicast reply to
		# be addressed to that this machine could hear, so ask for
		# a broadcast. Renewal, which has an address, does not.
		#
		body[Aflags] = byte (Fbroadcast >> 8);
		body[Aflags+1] = byte Fbroadcast;
	}
	body[Achaddr:] = s.mac;

	o := Bootpsize;
	body[o++] = byte 99;			# the magic cookie, RFC 2132 2.
	body[o++] = byte 130;
	body[o++] = byte 83;
	body[o++] = byte 99;

	if(kind != 0)
		o = putopt1(body, o, Otype, kind);
	if(reqaddr != nil)
		o = putopt(body, o, Oipaddr, reqaddr);
	if(srvid != nil)
		o = putopt(body, o, Oserverid, srvid);

	req := s.req;
	if(req == nil || req.get(Oclientid) == nil){
		id := array[1+Eaddrlen] of byte;
		id[0] = byte Ethernet;
		id[1:] = s.mac;
		o = putopt(body, o, Oclientid, id);
	}
	if(req == nil || req.get(Omaxmsg) == nil)
		o = putopt2(body, o, Omaxmsg, Maxmsg);
	if(req == nil || req.get(Ovendorclass) == nil)
		o = putopt(body, o, Ovendorclass, array of byte "plan9_386");

	#
	# Whatever else the caller put in the Bootconf it handed us: a
	# host name from ip/dhcp -h, a client identifier of its own. The
	# fields this exchange controls are not taken from there.
	#
	if(req != nil && req.options != nil)
		for(k := 0; k < 256; k++){
			case k {
			Opad or Oend or Otype or Oipaddr or Oserverid or Oparams =>
				continue;
			}
			if(req.options[k] != nil)
				o = putopt(body, o, k, req.options[k]);
		}

	if(kind != 0 && kind != Release && kind != Decline && s.params != nil){
		pl := array[len s.params] of byte;
		for(j := 0; j < len s.params; j++)
			pl[j] = byte s.params[j];
		o = putopt(body, o, Oparams, pl);
	}

	body[o++] = byte Oend;
	#
	# RFC 951 clients and servers exchanged 300-byte messages and some
	# equipment still expects at least that; pad to the fixed part
	# plus a short option area rather than send a runt.
	#
	while(o < Bootpsize + 64)
		body[o++] = byte Opad;
	return o;
}

# --- the conversation ----------------------------------------------

newsession(net: string, ctlifc: ref Sys->FD, device: string, req: ref Bootconf): (ref Session, string)
{
	s := ref Session;
	s.net = net;
	s.ctlifc = ctlifc;
	s.req = req;
	s.t0 = sys->millisec();
	s.stop = chan[1] of int;
	s.done = chan[1] of int;
	(mac, e) := readmac(device);
	if(e != nil)
		return (nil, e);
	s.mac = mac;
	if((e = openconv(s)) != nil)
		return (nil, e);
	#
	# Buffered: a reply that lands after this exchange has moved on
	# must not leave the reader blocked for ever on a send nobody
	# will receive, holding the conversation open with it.
	#
	s.rc = chan[8] of array of byte;
	pc := chan of int;
	spawn reader(s.dfd, s.rc, pc);
	s.rpid = <-pc;
	return (s, nil);
}

closesession(s: ref Session)
{
	if(s.rpid != 0){
		killproc(s.rpid);
		s.rpid = 0;
	}
	s.dfd = nil;
	s.cfd = nil;
}

#
# The hardware address, from the device file the caller named --
# /net/ether1/addr and its like, twelve hex digits.
#
readmac(device: string): (array of byte, string)
{
	if(device == nil)
		return (nil, "no network device named");
	fd := sys->open(device, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("cannot open %s: %r", device));
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return (nil, sys->sprint("cannot read %s: %r", device));
	t := string buf[0:n];
	mac := array[Eaddrlen] of byte;
	j := 0;
	for(i := 0; i < len t && j < Eaddrlen; ){
		hi := hexval(t[i]);
		if(hi < 0){
			i++;			# spaces, newlines, colons
			continue;
		}
		if(i+1 >= len t)
			break;
		lo := hexval(t[i+1]);
		if(lo < 0)
			return (nil, sys->sprint("%s: malformed hardware address", device));
		mac[j++] = byte ((hi << 4) | lo);
		i += 2;
	}
	if(j != Eaddrlen)
		return (nil, sys->sprint("%s: hardware address is not %d bytes", device, Eaddrlen));
	return (mac, nil);
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

openconv(s: ref Session): string
{
	cfd := sys->open(s.net+"/udp/clone", Sys->ORDWR);
	if(cfd == nil)
		return sys->sprint("cannot open %s/udp/clone: %r", s.net);
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return sys->sprint("cannot read %s/udp/clone: %r", s.net);
	conv := trim(string buf[0:n]);
	#
	# Headers mode, because every message goes to a different place:
	# broadcast while looking for a server, unicast to the server
	# while renewing. A connected conversation could not do both.
	#
	if(sys->fprint(cfd, "headers") < 0)
		return sys->sprint("cannot set udp headers on %s: %r", s.net);
	if(sys->fprint(cfd, "announce %d", Clientport) < 0)
		return sys->sprint("cannot announce udp port %d: %r", Clientport);
	dfd := sys->open(s.net+"/udp/"+conv+"/data", Sys->ORDWR);
	if(dfd == nil)
		return sys->sprint("cannot open %s/udp/%s/data: %r", s.net, conv);
	s.cfd = cfd;
	s.dfd = dfd;
	return nil;
}

trim(s: string): string
{
	b := 0;
	e := len s;
	while(b < e && (s[b] == ' ' || s[b] == '\t' || s[b] == '\n'))
		b++;
	while(e > b && (s[e-1] == ' ' || s[e-1] == '\t' || s[e-1] == '\n'))
		e--;
	return s[b:e];
}

#
# Read the conversation in its own process, because a read on it
# BLOCKS. The obvious loop -- read, check, sleep, try again -- cannot
# time out: with no server on the network the first read never returns,
# the retry never happens, and a caller that wanted an answer in thirty
# seconds waits for ever.
#
reader(d: ref Sys->FD, c: chan of array of byte, pids: chan of int)
{
	#
	# Only this descriptor. A reader waiting for an answer that never
	# comes would otherwise hold every open file of the process that
	# spawned it, for as long as it waits.
	#
	sys->pctl(Sys->NEWFD, d.fd :: nil);
	pids <-= sys->pctl(0, nil);
	for(;;){
		buf := array[Udphdrlen+Maxmsg] of byte;
		n := sys->read(d, buf, len buf);
		if(n <= 0)
			break;
		c <-= buf[0:n];
	}
}

#
# A timer that can be cancelled, which matters more than it looks.
#
# A timer process left asleep is a process, and a hosted emu does not
# exit while one is running: a lease whose renewal wait was interrupted
# by release() would otherwise hold the whole system open for the rest
# of a sleep measured in minutes. So every wait here hands back the
# sleeper's pid, and every path that leaves the wait early kills it.
#
timerproc(c: chan of int, ms: int, pc: chan of int)
{
	pc <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;			# buffered, so this always returns
}

starttimer(ms: int): (chan of int, int)
{
	c := chan[1] of int;
	pc := chan of int;
	spawn timerproc(c, ms, pc);
	return (c, <-pc);
}

killproc(pid: int)
{
	if(pid == 0)
		return;
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

drain(s: ref Session)
{
	for(;;)
		alt {
		<-s.rc =>
			;
		* =>
			return;
		}
}

#
# Send one message to dst.
#
sendmsg(s: ref Session, dst: string, kind: int, ciaddr, reqaddr, srvid: array of byte): string
{
	(ok, d) := parsev4(dst);
	if(!ok)
		return sys->sprint("bad destination address %s", dst);
	pkt := array[Udphdrlen+Maxmsg] of byte;
	for(i := 0; i < Udphdrlen; i++)
		pkt[i] = byte 0;
	v4map(pkt, 0, d);			# raddr
	pkt[3*Ipaddrlen] = byte (Serverport >> 8);
	pkt[3*Ipaddrlen+1] = byte Serverport;
	pkt[3*Ipaddrlen+2] = byte (Clientport >> 8);
	pkt[3*Ipaddrlen+3] = byte Clientport;
	n := mkmsg(s, pkt[Udphdrlen:], kind, ciaddr, reqaddr, srvid);
	if(sys->write(s.dfd, pkt, Udphdrlen+n) != Udphdrlen+n)
		return sys->sprint("cannot send: %r");
	trace(sys->sprint("sent type %d to %s, %d bytes", kind, dst, n));
	return nil;
}

v4map(a: array of byte, o: int, v: array of byte)
{
	for(i := 0; i < 10; i++)
		a[o+i] = byte 0;
	a[o+10] = byte 16rFF;
	a[o+11] = byte 16rFF;
	a[o+12:] = v;
}

#
# Wait for a reply of one of the wanted types, carrying our transaction
# id and our hardware address. Returns nil if none arrived in time, or
# if release() interrupted the wait.
#
waitreply(s: ref Session, kinds: list of int, ms: int): array of byte
{
	(t, tpid) := starttimer(ms);
	for(;;){
		alt {
		buf := <-s.rc =>
			b := match(s, buf, kinds);
			if(b != nil){
				killproc(tpid);
				return b;
			}
		<-s.stop =>
			s.halt = 1;
			killproc(tpid);
			return nil;
		<-t =>
			return nil;
		}
	}
}

match(s: ref Session, buf: array of byte, kinds: list of int): array of byte
{
	if(len buf <= Udphdrlen + Bootpsize)
		return nil;
	body := buf[Udphdrlen:];
	n := len body;
	if(int body[Aop] != Bootreply)
		return nil;
	xid := (int body[Axid] << 24) | (int body[Axid+1] << 16) |
		(int body[Axid+2] << 8) | int body[Axid+3];
	if(xid != s.xid)
		return nil;
	#
	# Bound to the client port, this conversation also sees the
	# broadcast replies meant for every other client on the wire.
	# The transaction id ought to separate them and the hardware
	# address certainly does.
	#
	for(i := 0; i < Eaddrlen; i++)
		if(body[Achaddr+i] != s.mac[i])
			return nil;
	if(kinds == nil)			# BOOTP: any reply will do
		return body[0:n];
	ty := msgtype(body, n);
	for(l := kinds; l != nil; l = tl l)
		if(hd l == ty)
			return body[0:n];
	return nil;
}

#
# DISCOVER, OFFER, REQUEST, ACK. Returns the acknowledged
# configuration, or a diagnostic saying what the last attempt did.
#
discover(s: ref Session): (ref Bootconf, string)
{
	reqaddr: array of byte;
	if(s.req != nil && s.req.ip != nil){
		(ok, q) := parsev4(s.req.ip);
		if(ok)
			reqaddr = q;		# an address we had before
	}
	last := "no reply from any DHCP server";
	for(try := 0; try < Ntries && !s.halt; try++){
		wait := Timeout0 << try;
		s.xid = mkxid();
		drain(s);
		if((e := sendmsg(s, Bcast, Discover, nil, reqaddr, nil)) != nil){
			last = e;
			continue;
		}
		offer := waitreply(s, Offer :: nil, wait);
		if(offer == nil){
			last = "no DHCPOFFER";
			continue;
		}
		(oc, pe) := parsemsg(offer, len offer);
		if(pe != nil){
			last = pe;
			continue;
		}
		srvid := oc.get(Oserverid);
		if(srvid == nil || len srvid < 4){
			last = "DHCPOFFER without a server identifier";
			continue;
		}
		yiaddr := array[4] of byte;
		yiaddr[0:] = offer[Ayiaddr:Ayiaddr+4];
		if(iszero(yiaddr, 0)){
			last = "DHCPOFFER without an address";
			continue;
		}
		if((e = sendmsg(s, Bcast, Request, nil, yiaddr, srvid)) != nil){
			last = e;
			continue;
		}
		reply := waitreply(s, Ack :: Nak :: nil, wait);
		if(reply == nil){
			last = "no DHCPACK";
			continue;
		}
		if(msgtype(reply, len reply) == Nak){
			(nc, nil) := parsemsg(reply, len reply);
			last = "DHCPNAK";
			if(nc != nil && nc.gets(Omessage) != nil)
				last = "DHCPNAK: " + nc.gets(Omessage);
			reqaddr = nil;		# do not ask for it again
			continue;
		}
		(c, e2) := parsemsg(reply, len reply);
		if(e2 != nil){
			last = e2;
			continue;
		}
		if(c.ip == nil){
			last = "DHCPACK without an address";
			continue;
		}
		return (c, nil);
	}
	if(s.halt)
		return (nil, "released");
	return (nil, last);
}

mkxid(): int
{
	x := (sys->millisec() << 8) ^ sys->pctl(0, nil);
	if(x == 0)
		x = 1;
	return x;
}

# --- the exported operations ---------------------------------------

bootp(net: string, ctlifc: ref Sys->FD, device: string, req: ref Bootconf): (ref Bootconf, string)
{
	if(sys == nil)
		return (nil, "dhcpclient: init() has not been called");
	if(net == nil)
		net = "/net";
	(s, e) := newsession(net, ctlifc, device, req);
	if(e != nil)
		return (nil, e);
	s.params = nil;
	last := "no reply from any BOOTP server";
	for(try := 0; try < 5; try++){
		s.xid = mkxid();
		drain(s);
		if((se := sendmsg(s, Bcast, 0, nil, nil, nil)) != nil){
			last = se;
			continue;
		}
		reply := waitreply(s, nil, Timeout0 << try);
		if(reply == nil){
			last = "no BOOTP reply";
			continue;
		}
		(c, pe) := parsemsg(reply, len reply);
		if(pe != nil){
			last = pe;
			continue;
		}
		closesession(s);
		if(ctlifc != nil && (ae := applycfg(net, ctlifc, c)) != nil)
			return (nil, ae);
		return (c, nil);
	}
	closesession(s);
	return (nil, last);
}

dhcp(net: string, ctlifc: ref Sys->FD, device: string, req: ref Bootconf,
	options: array of int): (ref Bootconf, ref Lease, string)
{
	if(sys == nil)
		return (nil, nil, "dhcpclient: init() has not been called");
	if(net == nil)
		net = "/net";
	(s, e) := newsession(net, ctlifc, device, req);
	if(e != nil)
		return (nil, nil, e);
	s.params = mkparams(options);
	(conf, de) := discover(s);
	if(de != nil){
		closesession(s);
		return (nil, nil, de);
	}
	if(ctlifc != nil && (ae := applycfg(net, ctlifc, conf)) != nil){
		closesession(s);
		return (nil, nil, ae);
	}
	s.conf = conf;
	#
	# Buffered, and drained before each send: dhcpclient(2) promises
	# that a caller which never reads the channel suffers nothing for
	# it.
	#
	l := ref Lease(0, chan[8] of (ref Bootconf, string));
	s.lease = l;
	if(conf.lease > 0){
		pc := chan of int;
		spawn watchdog(s, pc);
		l.pid = <-pc;
		register(s);
	}else
		closesession(s);		# nothing to renew
	return (conf, l, nil);
}

# --- applying a configuration --------------------------------------

applycfg(net: string, ctlifc: ref Sys->FD, conf: ref Bootconf): string
{
	if(sys == nil)
		return "dhcpclient: init() has not been called";
	if(conf == nil)
		return "no configuration to apply";
	if(ctlifc == nil)			# the caller does the configuring
		return nil;
	if(net == nil)
		net = "/net";
	if(conf.ip == nil)
		return "configuration has no address";
	mask := conf.ipmask;
	if(mask == nil)
		mask = classmask(conf.ip);
	#
	# The 0.0.0.0 the interface needed in order to speak DHCP at all
	# is not an address it should keep afterwards.
	#
	sys->fprint(ctlifc, "remove %s %s", Anyaddr, Anyaddr);
	if(sys->fprint(ctlifc, "add %s %s", conf.ip, mask) < 0)
		return sys->sprint("cannot add %s %s to interface: %r", conf.ip, mask);
	if(conf.ipgw != nil){
		r := sys->open(net+"/iproute", Sys->ORDWR);
		if(r == nil)
			return sys->sprint("cannot open %s/iproute: %r", net);
		if(sys->fprint(r, "add %s %s %s", Anyaddr, Anyaddr, conf.ipgw) < 0)
			return sys->sprint("cannot add default route via %s: %r", conf.ipgw);
	}
	writendb(net, conf);
	return nil;
}

removecfg(net: string, ctlifc: ref Sys->FD, conf: ref Bootconf): string
{
	if(sys == nil)
		return "dhcpclient: init() has not been called";
	if(conf == nil || ctlifc == nil)
		return nil;
	if(net == nil)
		net = "/net";
	if(conf.ipgw != nil){
		r := sys->open(net+"/iproute", Sys->ORDWR);
		if(r != nil)
			sys->fprint(r, "delete %s %s", Anyaddr, Anyaddr);
	}
	dropndb(net);
	if(conf.ip == nil)
		return nil;
	mask := conf.ipmask;
	if(mask == nil)
		mask = classmask(conf.ip);
	if(sys->fprint(ctlifc, "remove %s %s", conf.ip, mask) < 0)
		return sys->sprint("cannot remove %s from interface: %r", conf.ip);
	return nil;
}

#
# What the rest of the system reads: net/ndb. Best effort on purpose --
# a machine that has an address and a route is configured, and a boot
# must not fail because a network directory has no ndb to write to.
#
writendb(net: string, conf: ref Bootconf)
{
	s := sys->sprint("ip=%s ipmask=%s", conf.ip, conf.ipmask);
	if(conf.ipgw != nil)
		s += sys->sprint(" ipgw=%s", conf.ipgw);
	s += "\n";
	if(conf.sys != nil)
		s += sys->sprint("\tsys=%s\n", conf.sys);
	if(conf.dom != nil)
		s += sys->sprint("\tdom=%s\n", conf.dom);
	for(l := conf.getips(Odnsserver); l != nil; l = tl l)
		s += sys->sprint("\tdns=%s\n", hd l);
	for(l = conf.getips(Ontpserver); l != nil; l = tl l)
		s += sys->sprint("\tntp=%s\n", hd l);
	for(l = conf.getips(OP9fs); l != nil; l = tl l)
		s += sys->sprint("\tfs=%s\n", hd l);
	for(l = conf.getips(OP9auth); l != nil; l = tl l)
		s += sys->sprint("\tauth=%s\n", hd l);
	old := readfile(net+"/ndb");
	if(ndbtext != nil)
		old = without(old, ndbtext);
	fd := sys->create(net+"/ndb", Sys->OWRITE, 8r664);
	if(fd == nil){
		trace(sys->sprint("cannot write %s/ndb: %r", net));
		return;
	}
	t := old + s;
	b := array of byte t;
	if(sys->write(fd, b, len b) != len b)
		trace(sys->sprint("short write to %s/ndb: %r", net));
	ndbtext = s;
}

dropndb(net: string)
{
	if(ndbtext == nil)
		return;
	old := without(readfile(net+"/ndb"), ndbtext);
	fd := sys->create(net+"/ndb", Sys->OWRITE, 8r664);
	if(fd != nil){
		b := array of byte old;
		sys->write(fd, b, len b);
	}
	ndbtext = nil;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[1024] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[0:n];
	}
	return s;
}

without(s: string, sub: string): string
{
	if(sub == nil || len sub > len s)
		return s;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return s[0:i] + s[i+len sub:];
	return s;
}

# --- the lease -----------------------------------------------------

register(s: ref Session)
{
	lock <-= 1;
	sessions = s :: sessions;
	<-lock;
}

unregister(s: ref Session)
{
	lock <-= 1;
	l: list of ref Session;
	for(t := sessions; t != nil; t = tl t)
		if(hd t != s)
			l = hd t :: l;
	sessions = l;
	<-lock;
}

findsession(pid: int): ref Session
{
	if(pid == 0)
		return nil;
	lock <-= 1;
	s: ref Session;
	for(t := sessions; t != nil; t = tl t)
		if((hd t).lease != nil && (hd t).lease.pid == pid)
			s = hd t;
	<-lock;
	return s;
}

Lease.release(l: self ref Lease)
{
	s := findsession(l.pid);
	if(s == nil)
		return;
	alt {
	s.stop <-= 1 =>
		;
	* =>
		;			# already stopping
	}
	#
	# Bounded. The watchdog answers as soon as it comes out of a wait,
	# and every wait it does is interruptible; if it somehow is not,
	# a caller that asked for its address back does not deserve to
	# block for ever, so it gets killed instead.
	#
	(t, tpid) := starttimer(Stopwait);
	alt {
	<-s.done =>
		killproc(tpid);
	<-t =>
		killproc(l.pid);
		closesession(s);
	}
	unregister(s);
	l.pid = 0;
}

#
# Sleep, in pieces, watching for release. Returns non-zero if the
# sleep was interrupted.
#
napsecs(s: ref Session, secs: int): int
{
	while(secs > 0){
		n := secs;
		if(n > Napmax)
			n = Napmax;
		(t, tpid) := starttimer(n*1000);
		alt {
		<-t =>
			;
		<-s.stop =>
			s.halt = 1;
			killproc(tpid);
			return 1;
		}
		secs -= n;
	}
	return 0;
}

notify(s: ref Session, c: ref Bootconf, e: string)
{
	if(s.lease == nil)
		return;
	drainconfigs(s.lease);
	alt {
	s.lease.configs <-= (c, e) =>
		;
	* =>
		;
	}
}

drainconfigs(l: ref Lease)
{
	for(;;)
		alt {
		<-l.configs =>
			;
		* =>
			return;
		}
}

#
# Renew the lease: a REQUEST with our address in ciaddr and no server
# identifier, unicast to the server while renewing and broadcast once
# rebinding has begun (RFC 2131 4.3.2).
#
renew(s: ref Session, dst: string, tries: int): string
{
	(ok, ci) := parsev4(s.conf.ip);
	if(!ok)
		return "no address to renew";
	last := "no answer to DHCPREQUEST";
	for(try := 0; try < tries && !s.halt; try++){
		s.xid = mkxid();
		drain(s);
		if((e := sendmsg(s, dst, Request, ci, nil, nil)) != nil){
			last = e;
			continue;
		}
		reply := waitreply(s, Ack :: Nak :: nil, Timeout0 << try);
		if(reply == nil)
			continue;
		if(msgtype(reply, len reply) == Nak)
			return "DHCPNAK";
		(c, pe) := parsemsg(reply, len reply);
		if(pe != nil){
			last = pe;
			continue;
		}
		if(c.ip == nil)
			c.ip = s.conf.ip;	# a renewal need not repeat it
		changed := c.ip != s.conf.ip || c.ipmask != s.conf.ipmask ||
			c.ipgw != s.conf.ipgw;
		if(changed && s.ctlifc != nil){
			removecfg(s.net, s.ctlifc, s.conf);
			if((ae := applycfg(s.net, s.ctlifc, c)) != nil)
				return ae;
		}
		old := s.conf;
		s.conf = c;
		if(changed || old.lease != c.lease)
			notify(s, c, nil);
		return nil;
	}
	return last;
}

#
# One process per lease, for as long as the lease lasts. RFC 2131 4.4.5:
# renew at half the lease, rebind at seven eighths, and if both fail,
# give the address up and go looking for another.
#
watchdog(s: ref Session, pc: chan of int)
{
	pc <-= sys->pctl(0, nil);
	while(!s.halt){
		lease := s.conf.lease;
		if(lease <= 0)
			break;
		t1 := lease / 2;
		t2 := (lease * 7) / 8;
		if(napsecs(s, t1))
			break;
		e := "";
		if(s.conf.serverid != nil)
			e = renew(s, s.conf.serverid, 2);
		else
			e = "no server identifier";
		if(e != nil){
			trace("renewal failed: " + e);
			if(napsecs(s, t2 - t1))
				break;
			e = renew(s, Bcast, 2);	# rebinding
		}
		if(e == nil)
			continue;
		#
		# The lease is gone. Take the address off the interface
		# before looking for another: an expired address kept on
		# an interface is an address someone else may now hold.
		#
		trace("lease lost: " + e);
		removecfg(s.net, s.ctlifc, s.conf);
		notify(s, nil, "lease lost: " + e);
		for(;;){
			if(s.halt)
				break;
			(c, de) := discover(s);
			if(de == nil){
				if(s.ctlifc != nil && (ae := applycfg(s.net, s.ctlifc, c)) != nil){
					notify(s, nil, ae);
					break;
				}
				s.conf = c;
				notify(s, c, nil);
				break;
			}
			notify(s, nil, de);
			if(napsecs(s, Retrywait))
				break;
		}
	}
	if(s.halt && s.conf != nil && s.conf.ip != nil){
		#
		# Give the address back. A server told it the lease is over
		# can hand the address to someone else at once instead of
		# holding it until the lease would have run out.
		#
		dst := s.conf.serverid;
		if(dst == nil)
			dst = Bcast;
		(ok, ci) := parsev4(s.conf.ip);
		if(ok){
			s.xid = mkxid();
			sendmsg(s, dst, Release, ci, nil, s.conf.get(Oserverid));
		}
		removecfg(s.net, s.ctlifc, s.conf);
	}
	closesession(s);
	s.done <-= 1;
}
