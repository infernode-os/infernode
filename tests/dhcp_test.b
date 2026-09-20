implement DhcpTest;

#
#	The DHCP client: its option encoding against RFC 2132, and a whole
#	DISCOVER/OFFER/REQUEST/ACK exchange against a synthetic server.
#
#	Every byte layout asserted here comes from a document, not from
#	appl/lib/dhcpclient.b:
#
#	  RFC 2131 2., 3.1, 4.1   the fixed part, the magic cookie, the
#	                          broadcast flag, the exchange itself
#	  RFC 2132 3.3, 3.5, 3.8  subnet mask, router list, name servers
#	  RFC 2132 9.1-9.8        requested address, lease time, overload,
#	                          message type, server identifier,
#	                          parameter request list, client identifier
#	  RFC 3396                an option that appears twice is one
#	                          option split in two
#
#	The exchange runs against a UDP conversation this test serves
#	itself: a memfs holds a /net-shaped directory, file2chan supplies
#	the clone and data files, and a process behind them plays the
#	server.  That is a synthetic wire, not a real one -- what it can
#	prove is that the client emits the messages the RFC describes, in
#	the order it describes, and reads back what a server would say.
#	It cannot prove that any DHCP server on any network agrees; only a
#	board on a network can say that, and it says it by having an
#	address.
#
#	Binding port 68 -- which the real path does -- needs privilege on
#	a hosted system, so no test here can put the client on a loopback
#	UDP socket as an ordinary user.  The synthetic conversation is
#	exactly what that would have exercised, minus the host's UDP.
#

include "sys.m";
	sys: Sys;
	FileIO, Rread, Rwrite: import Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "dhcp.m";
	dhcpclient: Dhcpclient;
	Bootconf, Lease: import dhcpclient;

include "memfs.m";
	memfs: MemFS;

DhcpTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/dhcp_test.b";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# --- the wire, written out by hand ---------------------------------

Udphdrlen:	con 52;
Bootpsize:	con 236;

Bootrequest:	con 0;		# no message type option: plain BOOTP
Discover:	con 1;
Offer:		con 2;
Request:	con 3;
Ack:		con 5;
Nak:		con 6;
Release:	con 7;

Server:		con "192.168.7.1";
Ouraddr:	con "192.168.7.42";
Decoyaddr:	con "10.99.99.99";
Mac:		con "021122334455";	# locally administered, not a real card

#
# The test does its own dotted-quad parsing rather than borrow the
# library's: a decoder checked with its own encoder proves nothing.
#
ipb(s: string): array of byte
{
	a := array[4] of byte;
	i := 0;
	for(f := 0; f < 4; f++){
		v := 0;
		while(i < len s && s[i] >= '0' && s[i] <= '9'){
			v = v*10 + (s[i] - '0');
			i++;
		}
		a[f] = byte v;
		if(i < len s && s[i] == '.')
			i++;
	}
	return a;
}

macb(): array of byte
{
	a := array[6] of byte;
	for(i := 0; i < 6; i++)
		a[i] = byte ((hexv(Mac[2*i]) << 4) | hexv(Mac[2*i+1]));
	return a;
}

hexv(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	return c - 'A' + 10;
}

opt(kind: int, v: array of byte): array of byte
{
	a := array[2+len v] of byte;
	a[0] = byte kind;
	a[1] = byte len v;
	a[2:] = v;
	return a;
}

opt1(kind, v: int): array of byte
{
	a := array[1] of byte;
	a[0] = byte v;
	return opt(kind, a);
}

be4(v: int): array of byte
{
	a := array[4] of byte;
	a[0] = byte (v >> 24);
	a[1] = byte (v >> 16);
	a[2] = byte (v >> 8);
	a[3] = byte v;
	return a;
}

cat(l: list of array of byte): array of byte
{
	n := 0;
	for(t := l; t != nil; t = tl t)
		n += len hd t;
	a := array[n] of byte;
	o := 0;
	for(; l != nil; l = tl l){
		a[o:] = hd l;
		o += len hd l;
	}
	return a;
}

#
# A BOOTREPLY, with the UDP header the "headers" conversation prepends.
#
mkreply(xid: int, chaddr: array of byte, yiaddr: string, opts, file, sname: array of byte): array of byte
{
	body := array[Bootpsize + 4 + len opts] of byte;
	body[0] = byte 2;		# BOOTREPLY
	body[1] = byte 1;		# ethernet
	body[2] = byte 6;
	body[4:] = be4(xid);
	body[16:] = ipb(yiaddr);	# yiaddr
	body[20:] = ipb(Server);	# siaddr
	body[28:] = chaddr;
	if(sname != nil)
		body[44:] = sname;
	if(file != nil)
		body[108:] = file;
	body[Bootpsize] = byte 99;	# the magic cookie, RFC 2132 2.
	body[Bootpsize+1] = byte 130;
	body[Bootpsize+2] = byte 83;
	body[Bootpsize+3] = byte 99;
	body[Bootpsize+4:] = opts;

	p := array[Udphdrlen + len body] of byte;
	p[10] = byte 16rFF;		# raddr: the server, v4 mapped
	p[11] = byte 16rFF;
	p[12:] = ipb(Server);
	p[48] = byte 0;			# rport 67
	p[49] = byte 67;
	p[50] = byte 0;			# lport 68
	p[51] = byte 68;
	p[Udphdrlen:] = body;
	return p;
}

# option blocks the server hands back

ackopts(): array of byte
{
	#
	# An ACK that uses every decode path worth testing: two routers
	# and two name servers in one option, a vendor block with a Plan 9
	# file server inside it, and the option overload that moves the
	# host name into the sname field (RFC 2132 9.3), which also means
	# the file field is options and NOT a boot file name.
	#
	vendor := cat(opt(128, ipb("192.168.7.9")) :: nil);
	return cat(
		opt1(53, Ack) ::
		opt(54, ipb(Server)) ::
		opt(1, ipb("255.255.255.0")) ::
		opt(3, cat(ipb(Server) :: ipb("192.168.7.2") :: nil)) ::
		opt(6, ipb("192.168.7.53")) ::
		opt(6, ipb("192.168.7.54")) ::		# RFC 3396: one option, split
		opt(15, array of byte "example.invalid") ::
		opt(51, be4(3600)) ::
		opt(43, vendor) ::
		opt1(52, 1) ::				# file field holds options
		endopt() :: nil);
}

# the options that live in the overloaded file field
fileopts(): array of byte
{
	return cat(opt(12, array of byte "boardname") :: endopt() :: nil);
}

offeropts(): array of byte
{
	return cat(
		opt1(53, Offer) ::
		opt(54, ipb(Server)) ::
		opt(1, ipb("255.255.255.0")) ::
		opt(51, be4(3600)) ::
		endopt() :: nil);
}

ack2opts(): array of byte
{
	# No overload this time, so the file and sname fields are names.
	return cat(
		opt1(53, Ack) ::
		opt(54, ipb(Server)) ::
		opt(1, ipb("255.255.0.0")) ::
		opt(3, ipb(Server)) ::
		opt(51, be4(7200)) ::
		endopt() :: nil);
}

#
# A lease short enough that its renewal happens while a test is
# running: RFC 2131 4.4.5 puts the first renewal at half the lease.
#
Shortlease: con 4;

ack3opts(): array of byte
{
	return cat(
		opt1(53, Ack) ::
		opt(54, ipb(Server)) ::
		opt(1, ipb("255.255.255.0")) ::
		opt(51, be4(Shortlease)) ::
		endopt() :: nil);
}

#
# A BOOTP reply: the RFC 1497 extensions, and no message type.
#
bootpopts(): array of byte
{
	return cat(
		opt(1, ipb("255.255.255.0")) ::
		opt(3, ipb(Server)) ::
		endopt() :: nil);
}

nakopts(): array of byte
{
	return cat(
		opt1(53, Nak) ::
		opt(54, ipb(Server)) ::
		opt(56, array of byte "address already taken") ::
		endopt() :: nil);
}

endopt(): array of byte
{
	a := array[1] of byte;
	a[0] = byte 255;
	return a;
}

# --- reading what the client sent ----------------------------------

getxid(p: array of byte): int
{
	b := Udphdrlen;
	return (int p[b+4] << 24) | (int p[b+5] << 16) | (int p[b+6] << 8) | int p[b+7];
}

#
# Find an option in a message the client sent. Written independently of
# the library's walker on purpose.
#
findopt(p: array of byte, want: int): array of byte
{
	b := Udphdrlen;
	if(len p < b + Bootpsize + 4)
		return nil;
	o := b + Bootpsize + 4;
	while(o + 1 < len p){
		kind := int p[o];
		if(kind == 255)
			return nil;
		if(kind == 0){
			o++;
			continue;
		}
		n := int p[o+1];
		if(o + 2 + n > len p)
			return nil;
		if(kind == want){
			v := array[n] of byte;
			v[0:] = p[o+2:o+2+n];
			return v;
		}
		o += 2 + n;
	}
	return nil;
}

msgtype(p: array of byte): int
{
	v := findopt(p, 53);
	if(v == nil || len v < 1)
		return 0;
	return int v[0];
}

eqb(a, b: array of byte): int
{
	if(a == nil || b == nil)
		return a == nil && b == nil;
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++)
		s += sys->sprint("%.2ux", int a[i]);
	return s;
}

# --- the synthetic server ------------------------------------------

Quit: con -1;

#
# One process behind the data file. It answers what the client sends,
# in the order RFC 2131 4.4 says a client sends it, and hands back
# messages a client must ignore before the ones it must not.
#
server(clone, data: ref FileIO, obs: chan of array of byte, quit: chan of int, pids: chan of int)
{
	pids <-= sys->pctl(0, nil);
	#
	# A server that died quietly would look exactly like a network
	# with nothing on it, and the client would spend its whole retry
	# budget finding that out. Say so instead.
	#
	{
		server1(clone, data, obs, quit);
	} exception e {
	"*" =>
		sys->fprint(sys->fildes(2), "dhcp_test: synthetic server: %s\n", e);
	}
}

server1(clone, data: ref FileIO, obs: chan of array of byte, quit: chan of int)
{
	pending: list of array of byte;
	readers: list of Rread;
	phase := 0;
	mac := macb();
	for(;;)alt{
	<-quit =>
		return;
	(nil, nil, nil, rc) := <-clone.read =>
		if(rc != nil)
			rc <-= (array of byte "1", nil);
	(nil, buf, nil, wc) := <-clone.write =>
		if(wc != nil)
			wc <-= (len buf, nil);
	(nil, nil, nil, rc) := <-data.read =>
		if(rc == nil)		# the client closed the file
			continue;
		if(pending != nil){
			rc <-= (hd pending, nil);
			pending = tl pending;
		}else
			readers = rc :: readers;
	(nil, buf, nil, wc) := <-data.write =>
		if(wc == nil)		# the client closed the file
			continue;
		wc <-= (len buf, nil);
		obs <-= buf;
		xid := getxid(buf);
		ty := msgtype(buf);
		replies: list of array of byte;
		#
		# Answers depend on what arrived, not on how many messages
		# have gone by. A client whose two-second wait expires on a
		# loaded machine retransmits, and a server that had counted
		# messages would then be answering the wrong question for
		# the rest of the run -- which is a flaky test, not a
		# finding about the client.
		#
		case ty {
		Bootrequest =>
			#
			# No message type option at all: RFC 951, whose reply
			# has no message type either and whose file field is
			# a name rather than more options.
			#
			replies = mkreply(xid, mac, Ouraddr, bootpopts(),
				array of byte "/boot/kernel", nil) :: nil;
		Discover =>
			if(phase == 0){
				#
				# Two replies a correct client must throw
				# away -- one with another transaction's id,
				# one addressed to another card -- and then
				# the offer. A client that takes either
				# decoy ends up with Decoyaddr.
				#
				replies =
					mkreply(xid ^ 16r5A5A5A5A, mac, Decoyaddr, offeropts(), nil, nil) ::
					mkreply(xid, ipb(Decoyaddr)[0:4], Decoyaddr, offeropts(), nil, nil) ::
					mkreply(xid, mac, Ouraddr, offeropts(), nil, nil) :: nil;
				phase = 1;
			}else
				replies = mkreply(xid, mac, Ouraddr, offeropts(), nil, nil) :: nil;
		Request =>
			case phase {
			0 or 1 =>
				# the first exchange: an ACK whose options are
				# overloaded into the file field
				replies = mkreply(xid, mac, Ouraddr, ackopts(),
					fileopts(), array of byte "hostfromsname") :: nil;
				phase = 2;
			2 =>
				# the second exchange: refused once
				replies = mkreply(xid, mac, Ouraddr, nakopts(), nil, nil) :: nil;
				phase = 3;
			3 =>
				# and then granted, with no overload, so the
				# file and sname fields are names
				replies = mkreply(xid, mac, Ouraddr, ack2opts(),
					array of byte "/boot/kernel", array of byte "srv1") :: nil;
				phase = 4;
			* =>
				#
				# The third exchange, and every renewal of it:
				# a lease of four seconds, so the renewal the
				# client owes at half of that happens while the
				# test is still watching.
				#
				replies = mkreply(xid, mac, Ouraddr, ack3opts(), nil, nil) :: nil;
				phase = 5;
			}
		}
		for(; replies != nil; replies = tl replies){
			if(readers != nil){
				(hd readers) <-= (hd replies, nil);
				readers = tl readers;
			}else
				pending = append(pending, hd replies);
		}
	}
}

append(l: list of array of byte, a: array of byte): list of array of byte
{
	if(l == nil)
		return a :: nil;
	return hd l :: append(tl l, a);
}

# --- the fake network directory ------------------------------------

Netdir:	con "/n";
Addrfile: con "/n/ether/addr";

#
# A /net-shaped tree the client can walk: memfs holds the directories,
# the srv device holds the two active files, and a bind puts each
# active file where the client will look for it.
#
setupnet(): (ref FileIO, ref FileIO, string)
{
	memfs = load MemFS MemFS->PATH;
	if(memfs == nil)
		return (nil, nil, "cannot load "+MemFS->PATH);
	if((e := memfs->init()) != nil)
		return (nil, nil, "memfs init: "+e);
	fd := memfs->newfs(256*1024);
	if(fd == nil)
		return (nil, nil, sys->sprint("memfs newfs: %r"));
	if(sys->mount(fd, nil, Netdir, Sys->MREPL|Sys->MCREATE, nil) < 0)
		return (nil, nil, sys->sprint("mount memfs on %s: %r", Netdir));
	if(mkdir(Netdir+"/udp") < 0 || mkdir(Netdir+"/udp/1") < 0 || mkdir(Netdir+"/ether") < 0 ||
	   mkdir(Netdir+"/srv") < 0)
		return (nil, nil, sys->sprint("cannot create the fake network directory: %r"));
	if(mkfile(Addrfile, array of byte Mac) < 0)
		return (nil, nil, sys->sprint("cannot write %s: %r", Addrfile));
	if(mkfile(Netdir+"/udp/clone", nil) < 0 || mkfile(Netdir+"/udp/1/data", nil) < 0)
		return (nil, nil, sys->sprint("cannot create the udp files: %r"));
	if(sys->bind("#s", Netdir+"/srv", Sys->MREPL|Sys->MCREATE) < 0)
		return (nil, nil, sys->sprint("cannot bind the srv device: %r"));
	#
	# Names of their own: the srv device is shared by everything in
	# this emu, and "clone" is not a name to claim in it.
	#
	clone := sys->file2chan(Netdir+"/srv", "dhcptestclone");
	data := sys->file2chan(Netdir+"/srv", "dhcptestdata");
	if(clone == nil || data == nil)
		return (nil, nil, sys->sprint("file2chan: %r"));
	if(sys->bind(Netdir+"/srv/dhcptestclone", Netdir+"/udp/clone", Sys->MREPL) < 0 ||
	   sys->bind(Netdir+"/srv/dhcptestdata", Netdir+"/udp/1/data", Sys->MREPL) < 0)
		return (nil, nil, sys->sprint("cannot bind the udp files: %r"));
	return (clone, data, nil);
}

mkdir(p: string): int
{
	fd := sys->create(p, Sys->OREAD, Sys->DMDIR|8r777);
	if(fd == nil)
		return -1;
	return 0;
}

mkfile(p: string, data: array of byte): int
{
	fd := sys->create(p, Sys->OWRITE, 8r666);
	if(fd == nil)
		return -1;
	if(data != nil && sys->write(fd, data, len data) != len data)
		return -1;
	return 0;
}

# --- the exchange, driven in a namespace of its own ----------------

Result: adt {
	ok:	int;
	what:	string;
};

#
# Everything below runs in a process with a forked namespace, because
# it replaces /n with a memfs and binds the srv device into it; the
# runner and every test after this one must not see that.
#
exchange(res: chan of ref Result, done: chan of int, pids: chan of int)
{
	{
		exchange1(res, done, pids);
	} exception e {
	"*" =>
		res <-= ref Result(0, "the exchange raised: "+e);
		done <-= 1;
	}
}

exchange1(res: chan of ref Result, done: chan of int, pids: chan of int)
{
	sys->pctl(Sys->FORKNS, nil);
	pids <-= sys->pctl(0, nil);
	(clone, data, e) := setupnet();
	if(e != nil){
		res <-= ref Result(0, "setup: "+e);
		done <-= 1;
		return;
	}
	obs := chan[32] of array of byte;
	quit := chan of int;
	spid := chan of int;
	spawn server(clone, data, obs, quit, spid);
	pids <-= <-spid;

	cfg := Bootconf.new();
	cfg.puts(Dhcpclient->Ohostname, "testclient");
	#
	# A server's option, in the Bootconf the caller hands in. It has no
	# business going out in a client's message, and the same Bootconf
	# comes back out of a completed exchange full of options like it.
	#
	cfg.put(Dhcpclient->Omask, ipb("255.255.255.0"));
	(conf, lease, de) := dhcpclient->dhcp(Netdir, nil, Addrfile, cfg, nil);
	res <-= ref Result(de == nil, "first exchange completes: "+nonnil(de));
	if(conf != nil){
		res <-= ref Result(conf.ip == Ouraddr,
			"address from yiaddr: "+conf.ip);
		res <-= ref Result(conf.ipmask == "255.255.255.0",
			"mask from option 1: "+conf.ipmask);
		res <-= ref Result(conf.ipgw == Server,
			"gateway from option 3: "+conf.ipgw);
		res <-= ref Result(iplist(conf.getips(Dhcpclient->Orouter)) == "192.168.7.1 192.168.7.2",
			"both routers decoded: "+iplist(conf.getips(Dhcpclient->Orouter)));
		res <-= ref Result(iplist(conf.getips(Dhcpclient->Odnsserver)) == "192.168.7.53 192.168.7.54",
			"RFC 3396 split option rejoined: "+iplist(conf.getips(Dhcpclient->Odnsserver)));
		res <-= ref Result(conf.dom == "example.invalid",
			"domain from option 15: "+conf.dom);
		res <-= ref Result(conf.lease == 3600,
			sys->sprint("lease from option 51: %d", conf.lease));
		res <-= ref Result(conf.serverid == Server,
			"server identifier from option 54: "+conf.serverid);
		res <-= ref Result(conf.getip(Dhcpclient->OP9fs) == "192.168.7.9",
			"vendor sub-option inside option 43: "+conf.getip(Dhcpclient->OP9fs));
		res <-= ref Result(conf.sys == "boardname",
			"host name taken from the overloaded file field: "+conf.sys);
		res <-= ref Result(conf.bootf == nil,
			"an overloaded file field is not a boot file name: "+conf.bootf);
	}else
		res <-= ref Result(0, "first exchange returned no configuration");
	if(lease != nil)
		lease.release();

	#
	# Again, this time with a DHCPNAK in the middle: the client must
	# start over rather than take the address it was refused.
	#
	cfg2 := Bootconf.new();
	(conf2, lease2, de2) := dhcpclient->dhcp(Netdir, nil, Addrfile, cfg2, nil);
	res <-= ref Result(de2 == nil, "exchange survives a DHCPNAK: "+nonnil(de2));
	if(conf2 != nil){
		res <-= ref Result(conf2.ip == Ouraddr, "address after the NAK: "+conf2.ip);
		res <-= ref Result(conf2.ipmask == "255.255.0.0",
			"the second ACK's mask, not the first: "+conf2.ipmask);
		res <-= ref Result(conf2.lease == 7200,
			sys->sprint("the second ACK's lease: %d", conf2.lease));
		res <-= ref Result(conf2.bootf == "/boot/kernel",
			"boot file from the file field when it is not overloaded: "+conf2.bootf);
		res <-= ref Result(conf2.sys == "srv1",
			"host name from the sname field when it is not overloaded: "+conf2.sys);
	}else
		res <-= ref Result(0, "second exchange returned no configuration");
	if(lease2 != nil)
		lease2.release();

	#
	# A third time, for a lease of four seconds, so that the process
	# dhcp() leaves behind has to renew it while this test is still
	# watching. Nothing else exercises the renewal timer, and it is
	# the part of the client that runs for hours on a live machine.
	#
	cfg4 := Bootconf.new();
	(conf4, lease4, de4) := dhcpclient->dhcp(Netdir, nil, Addrfile, cfg4, nil);
	res <-= ref Result(de4 == nil, "a short lease is granted: "+nonnil(de4));
	if(conf4 != nil)
		res <-= ref Result(conf4.lease == Shortlease,
			sys->sprint("the short lease: %d", conf4.lease));
	else
		res <-= ref Result(0, "the third exchange returned no configuration");
	sys->sleep((Shortlease + 2) * 1000);	# past T1, with room to spare
	if(lease4 != nil)
		lease4.release();

	#
	# And the older protocol underneath, which dhcpclient(2) exports
	# as well: a BOOTREQUEST carries no message type at all, and the
	# reply is a plain BOOTREPLY whose file field is a boot file name.
	#
	cfg3 := Bootconf.new();
	(conf3, be) := dhcpclient->bootp(Netdir, nil, Addrfile, cfg3);
	res <-= ref Result(be == nil, "a BOOTP exchange completes: "+nonnil(be));
	if(conf3 != nil){
		res <-= ref Result(conf3.ip == Ouraddr, "BOOTP address from yiaddr: "+conf3.ip);
		res <-= ref Result(conf3.ipmask == "255.255.255.0",
			"BOOTP mask from option 1: "+conf3.ipmask);
		res <-= ref Result(conf3.siaddr == Server, "BOOTP siaddr: "+conf3.siaddr);
		res <-= ref Result(conf3.bootf == "/boot/kernel",
			"BOOTP boot file from the file field: "+conf3.bootf);
		res <-= ref Result(conf3.lease == 0,
			sys->sprint("a BOOTP reply grants no lease: %d", conf3.lease));
	}else
		res <-= ref Result(0, "the BOOTP exchange returned no configuration");

	# what the client actually put on the wire
	sent: list of array of byte;
	for(;;){
		got := 0;
		alt {
		p := <-obs =>
			sent = append(sent, p);
			got = 1;
		* =>
			;
		}
		if(!got)
			break;
	}
	checksent(res, sent);
	quit <-= 1;
	done <-= 1;
}

nonnil(s: string): string
{
	if(s == nil)
		return "no error";
	return s;
}

iplist(l: list of string): string
{
	s := "";
	for(; l != nil; l = tl l){
		if(s != nil)
			s += " ";
		s += hd l;
	}
	return s;
}

#
# The messages the client sent, checked against RFC 2131 4.4.1 and
# 4.4.6 and the option definitions of RFC 2132.
#
checksent(res: chan of ref Result, sent: list of array of byte)
{
	types := "";
	n := ndiscover := nrequest := nrelease := nbootp := nother := 0;
	prev := -1;
	pairs := 1;			# every new REQUEST follows a DISCOVER
	first, request, rel, boot, renewal: array of byte;
	for(l := sent; l != nil; l = tl l){
		p := hd l;
		ty := msgtype(p);
		types += string ty + " ";
		case ty {
		Bootrequest =>
			nbootp++;
			if(boot == nil)
				boot = p;
		Discover =>
			ndiscover++;
		Request =>
			nrequest++;
			#
			# A renewal is a REQUEST with the address already in
			# ciaddr, and it does not follow a DISCOVER: it is
			# the client keeping what it has (RFC 2131 4.3.2).
			#
			if(!iszero(p, Udphdrlen+12)){
				if(renewal == nil)
					renewal = p;
			}else if(prev != Discover)
				pairs = 0;
		Release =>
			nrelease++;
		* =>
			nother++;
		}
		if(n == 0)
			first = p;
		if(request == nil && ty == Request)
			request = p;
		if(ty == Release && rel == nil)
			rel = p;
		prev = ty;
		n++;
	}
	#
	# Not an exact string: a client whose wait expires on a loaded
	# machine retransmits, and that is correct behaviour. What must
	# hold is the shape. Three DISCOVERs is the point -- one for the
	# first exchange, two for the second, because the DHCPNAK sends
	# the client back to the beginning rather than on to an address it
	# was refused.
	#
	res <-= ref Result(nother == 0,
		"nothing but DISCOVER, REQUEST, RELEASE and one BOOTREQUEST went out: "+types);
	res <-= ref Result(nbootp == 1, "one message carried no message type at all: "+types);
	if(boot != nil)
		res <-= ref Result(findopt(boot, 53) == nil && findopt(boot, 55) == nil,
			"a BOOTP request carries neither a message type nor a parameter request list");
	res <-= ref Result(msgtype(first) == Discover, "the first message is a DHCPDISCOVER: "+types);
	res <-= ref Result(pairs, "every DHCPREQUEST follows a DHCPDISCOVER: "+types);
	res <-= ref Result(ndiscover >= 3, "the DHCPNAK sent the client back to DISCOVER: "+types);
	res <-= ref Result(nrequest >= 3, "three DHCPREQUESTs, one of them refused: "+types);
	res <-= ref Result(nrelease == 3, "every lease was given back: "+types);
	#
	# The renewal, which nothing else here would notice: half a
	# four-second lease later, unicast to the server that granted it,
	# carrying the address in ciaddr and neither a requested address
	# nor a server identifier (RFC 2131 4.3.2 and table 4).
	#
	if(renewal != nil){
		b := Udphdrlen;
		res <-= ref Result(eqb(renewal[b+12:b+16], ipb(Ouraddr)),
			"the renewal carries its address in ciaddr");
		res <-= ref Result(findopt(renewal, 50) == nil && findopt(renewal, 54) == nil,
			"a renewal asks for no address and names no server");
		res <-= ref Result(int renewal[12] == 192 && int renewal[13] == 168 &&
			int renewal[14] == 7 && int renewal[15] == 1,
			"a renewal is unicast to the server, not broadcast");
		res <-= ref Result((int renewal[b+10] & 16r80) == 0,
			"a client that has an address does not ask to be answered by broadcast");
	}else
		res <-= ref Result(0, "the lease was never renewed: "+types);
	if(first != nil){
		b := Udphdrlen;
		res <-= ref Result(int first[b] == 1 && int first[b+1] == 1 && int first[b+2] == 6,
			"BOOTREQUEST over ethernet, six-byte hardware address");
		res <-= ref Result((int first[b+10] & 16r80) != 0,
			"the broadcast flag is set when there is no address to answer");
		res <-= ref Result(eqb(first[b+28:b+34], macb()),
			"chaddr is the interface's address: "+hex(first[b+28:b+34]));
		res <-= ref Result(int first[b+236] == 99 && int first[b+237] == 130 &&
			int first[b+238] == 83 && int first[b+239] == 99,
			"the magic cookie 99.130.83.99 precedes the options");
		cid := findopt(first, 61);
		res <-= ref Result(cid != nil && len cid == 7 && int cid[0] == 1 &&
			eqb(cid[1:], macb()),
			"client identifier is the hardware type and address (RFC 2132 9.14)");
		params := findopt(first, 55);
		res <-= ref Result(has(params, 1) && has(params, 3) && has(params, 6),
			"the parameter request list asks for mask, router and DNS");
		res <-= ref Result(findopt(first, 12) != nil,
			"a host name the caller supplied is sent");
		res <-= ref Result(findopt(first, 1) == nil,
			"a subnet mask the caller supplied is not sent back at the server");
		res <-= ref Result(iszero(first, b+12),
			"ciaddr is zero in a DISCOVER");
		res <-= ref Result(int first[10] == 16rFF && int first[11] == 16rFF &&
			int first[12] == 255 && int first[15] == 255,
			"a DISCOVER is addressed to 255.255.255.255");
	}
	if(request != nil){
		res <-= ref Result(msgtype(request) == Request, "the second message is a DHCPREQUEST");
		res <-= ref Result(eqb(findopt(request, 50), ipb(Ouraddr)),
			"option 50 asks for the address that was offered");
		res <-= ref Result(eqb(findopt(request, 54), ipb(Server)),
			"option 54 names the server whose offer was taken");
	}
	if(rel != nil)
		res <-= ref Result(int rel[12] == 192 && int rel[13] == 168 &&
			int rel[14] == 7 && int rel[15] == 1,
			"a DHCPRELEASE is unicast to the server, not broadcast");
	else
		res <-= ref Result(0, "no DHCPRELEASE was sent");
}

has(a: array of byte, v: int): int
{
	if(a == nil)
		return 0;
	for(i := 0; i < len a; i++)
		if(int a[i] == v)
			return 1;
	return 0;
}

iszero(a: array of byte, o: int): int
{
	for(i := 0; i < 4; i++)
		if(a[o+i] != byte 0)
			return 0;
	return 1;
}

# --- tests ---------------------------------------------------------

#
# Bootconf's accessors, against the encodings of RFC 2132.
#
testOptions(t: ref T)
{
	c := Bootconf.new();
	#
	# dhcpclient(2) promises a new Bootconf is nil and zero throughout.
	# In Limbo that is a promise about every scalar field by name: a
	# ref allocated without an initialiser holds what the memory held
	# before, and lease is an integer.
	#
	t.asserteq(c.lease, 0, "a new Bootconf has no lease");
	t.assertnil(c.ip, "a new Bootconf has no address");
	t.assertnil(c.ipmask, "a new Bootconf has no mask");
	t.assertnil(c.ipgw, "a new Bootconf has no gateway");
	t.assertnil(c.serverid, "a new Bootconf names no server");
	t.assertnil(c.bootf, "a new Bootconf names no boot file");
	t.asserteq(c.getint(Dhcpclient->Olease), 0, "an option nobody set reads as zero");
	t.assertnil(c.getip(Dhcpclient->Omask), "an option nobody set has no address");
	t.assert(c.get(Dhcpclient->Orouter) == nil, "an option nobody set has no bytes");

	# RFC 2132 9.2: lease time is four octets, most significant first
	c.putint(Dhcpclient->Olease, 3600);
	t.assertseq(hex(c.get(Dhcpclient->Olease)), "00000e10", "lease time encodes as a 32-bit big-endian value");
	t.asserteq(c.getint(Dhcpclient->Olease), 3600, "and decodes back");

	# RFC 2132 3.3: the subnet mask is four octets
	c.put(Dhcpclient->Omask, ipb("255.255.255.0"));
	t.assertseq(c.getip(Dhcpclient->Omask), "255.255.255.0", "a four-octet option reads as a dotted quad");

	# RFC 2132 3.5: routers, in order of preference
	c.putips(Dhcpclient->Orouter, "192.168.7.1" :: "192.168.7.2" :: nil);
	t.assertseq(hex(c.get(Dhcpclient->Orouter)), "c0a80701c0a80702", "an address list encodes as consecutive quads");
	t.assertseq(iplist(c.getips(Dhcpclient->Orouter)), "192.168.7.1 192.168.7.2", "and decodes in the order it was sent");
	t.assertseq(c.getip(Dhcpclient->Orouter), "192.168.7.1", "getip takes the first of a list");

	# RFC 2132 3.14: the host name is a string, and servers pad it
	c.puts(Dhcpclient->Ohostname, "board");
	t.assertseq(hex(c.get(Dhcpclient->Ohostname)), "626f617264", "a string option is its bytes");
	padded := array[8] of byte;
	padded[0:] = array of byte "board";
	c.put(Dhcpclient->Ohostname, padded);
	t.assertseq(c.gets(Dhcpclient->Ohostname), "board", "trailing NUL padding is not part of the name");

	# a lease of 0xffffffff is Infinite (RFC 2131 3.3)
	inf := array[4] of byte;
	for(i := 0; i < 4; i++)
		inf[i] = byte 16rFF;
	c.put(Dhcpclient->Olease, inf);
	t.asserteq(c.getint(Dhcpclient->Olease), Dhcpclient->Infinite, "an all-ones lease is Infinite");

	# put(n, nil) removes
	c.put(Dhcpclient->Omask, nil);
	t.assert(c.get(Dhcpclient->Omask) == nil, "put with nil removes the option");

	# the vendor bit selects a different table (RFC 2132 8.4 encapsulation)
	c.put(Dhcpclient->OP9fs, ipb("192.168.7.9"));
	t.assertseq(c.getip(Dhcpclient->OP9fs), "192.168.7.9", "a vendor option round trips");
	t.assert(c.get(Dhcpclient->OP9fs & 16rFF) == nil, "a vendor option is not the plain option of the same number");

	# get hands back a copy: a caller cannot corrupt the configuration
	v := c.get(Dhcpclient->OP9fs);
	v[0] = byte 0;
	t.assertseq(c.getip(Dhcpclient->OP9fs), "192.168.7.9", "get returns a copy, not the stored array");

	# a list with nothing usable in it leaves no option behind
	c.putips(Dhcpclient->Odnsserver, "not.an.address.at.all" :: nil);
	t.assert(c.get(Dhcpclient->Odnsserver) == nil, "addresses that will not parse are not encoded");
}

#
# The whole exchange, against the synthetic server.
#
testExchange(t: ref T)
{
	#
	# Buffered past the number of checks the run can make, so that a
	# result sent after this process has given up waiting cannot leave
	# the exchange blocked for ever on a send nobody will receive.
	#
	res := chan[64] of ref Result;
	done := chan of int;
	pids := chan[4] of int;
	spawn exchange(res, done, pids);
	#
	# Bounded, because a test that can hang is worse than one that
	# fails: the client's own retries end well inside this.
	#
	late := chan[1] of int;
	pc := chan of int;
	spawn deadline(late, pc, 90*1000);
	lpid := <-pc;
	n := 0;
	for(;;)alt{
	r := <-res =>
		t.assert(r.ok, r.what);
		n++;
	<-late =>
		#
		# And reap what it left behind. A process blocked in an alt
		# is still a process, and a hosted emu does not exit while
		# one is running: without this the deadline would turn a
		# failing run into a hung one, which is the thing it exists
		# to prevent.
		#
		reap(pids);
		t.fatal(sys->sprint("the exchange never finished; %d checks made", n));
		return;
	<-done =>
		#
		# A run that produced no checks is not a run that passed.
		#
		t.assert(n >= 20, sys->sprint("the exchange produced %d checks", n));
		killproc(lpid);
		return;
	}
}

#
# The clock this test runs against. It reports its own pid so that a
# run which finishes early can kill it: a process left asleep is a
# process, and a hosted emu does not exit while one is running.
#
deadline(c: chan of int, pc: chan of int, ms: int)
{
	pc <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

killproc(pid: int)
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

reap(pids: chan of int)
{
	for(;;)
		alt {
		pid := <-pids =>
			killproc(pid);
		* =>
			return;
		}
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	dhcpclient = load Dhcpclient Dhcpclient->PATH;
	if(dhcpclient == nil){
		sys->fprint(sys->fildes(2), "cannot load %s: %r\n", Dhcpclient->PATH);
		raise "fail:cannot load dhcpclient";
	}
	dhcpclient->init();

	run("Options", testOptions);
	run("Exchange", testExchange);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
