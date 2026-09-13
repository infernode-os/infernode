implement Bt9p;

#
# bt9p - the Bluetooth host, serving /net/bt
#
# One program owns the controller. It opens a transport -- the board's
# /dev/eia0, a socket to a bridge, a pipe with btmock on the far end --
# speaks HCI over it through bthci(2), and puts the controller behind
# files. Everything the specification calls "the host" lives here, in
# Limbo, and nothing in the kernel knows the word Bluetooth
# (docs/BLUETOOTH.md).
#
# The tree, served into /net by default so that it sits beside
# /net/tcp and /net/ether0:
#
#   /net/bt/
#     addr      read  the local BD_ADDR, "b8:27:eb:5a:6b:7c\n"; an error until up
#     status    read  one field per line: up, addr, name, hci/lmp/manufacturer,
#                     transport, scans, events dropped
#     ctl       write up | down | reset | name <s> | class <hex>
#                     discoverable on|off | connectable on|off | scan <secs>
#                     firmware <path> | baud <n>
#     scan      read  runs an inquiry; one device per line as found,
#                     "<addr> <class> <rssi> <name>"; EOF at Inquiry Complete
#     event     read  the HCI event stream as text, "event 0x0e 01 03 0c 00",
#                     one per line, as long as the file is held open. Debugging.
#     hci       read/write raw H4 packets, exclusive. While held, ctl verbs
#                     that would issue commands are refused: the stack has
#                     lent the controller to whoever holds this.
#
# Not here yet: clone and the conversation directories (L2CAP, M5),
# lescan (M4), keys (M6). The ctl verbs for what is not done refuse
# with "not yet", not silence.
#
# The firmware. A Broadcom controller boots from ROM and takes a patch
# over HCI: "firmware <path>" names a .hcd file (on the board,
# /n/dos/firmware/BCM4345C0.hcd, never in the tree -- docs/BLUETOOTH.md)
# and the next "up" uploads it, Download_Minidriver then every record
# then Launch_RAM, then resets and asks the controller who it is now.
# "baud <n>" tells the controller to change rate (Update_UART_Baud_Rate)
# and then changes the transport's own rate through its ctl file, so
# it wants a transport that has one: /dev/eia0 does.
#
# Usage:
#   bt9p -t /dev/eia0                    the board
#   bt9p -t tcp!host!port                a bridge to a real controller, or a mock
#   bt9p -t /chan/btmock -m /net         btmock(4)'s file
#   bt9p -D                              trace every command and event to stderr
#
# Example:
#   ; bt9p -t /dev/eia0
#   ; echo up > /net/bt/ctl
#   ; cat /net/bt/addr
#   b8:27:eb:5a:6b:7c
#   ; cat /net/bt/scan
#   94:bb:43:44:61:04 0x1c010c -61 -
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

include "string.m";
	str: String;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Fid: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

include "bthci.m";
	bthci: Bthci;
	Pkt, Event, Transport, Hci, Version, Found: import bthci;

Bt9p: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

Qroot, Qbt, Qaddr, Qstatus, Qctl, Qscan, Qevent, Qhci: con iota;

Cmdms: con 3000;		# a command that takes longer than this has not been answered

stderr: ref Sys->FD;
debug := 0;
user := "inferno";

# the controller as we know it
hci: ref Hci;
transportname: string;
up := 0;
addr := "";
name := "infernode";
version: ref Version;
class := 0;
discoverable := 0;
connectable := 1;
scansecs := 10;
scans := 0;			# inquiries run
firmware := "";			# a .hcd to upload on up
uploaded := 0;			# records sent by the last up, or -1 if the upload failed
baud := 0;			# what the transport was last told, 0 if never

# a parked read on a streaming file, and what it will get
Sub: adt {
	fid:	int;
	path:	int;
	pending: ref Tmsg.Read;
	lines:	list of string;		# oldest first
	nlines:	int;
	dropped: int;
	started: int;			# the inquiry has been asked for (scan)
	done:	int;			# EOF once lines are drained (scan)
};
subs: list of ref Sub;
Maxlines: con 1000;

# raw packets for the hci file's holder
hcifid := -1;
hcipending: ref Tmsg.Read;
hciq: list of ref Pkt;

# a ctl write being carried out by a worker
Ctlres: adt {
	tm:	ref Tmsg.Write;
	err:	string;
	scanning: int;			# this was an Inquiry
	# what the worker learned, applied by the serve loop
	setup:	int;			# 1: up; -1: down or reset
	addr:	string;
	name:	string;
	version: ref Version;
	class:	int;			# -1: unchanged
	disc:	int;			# -1: unchanged
	conn:	int;			# -1: unchanged
	uploaded: int;			# records the patch upload sent
	baud:	int;			# rate set, 0 if none
};
ctldone: chan of ref Ctlres;
busy := 0;			# a worker is talking to the controller

dir(nm: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = nm;
	d.uid = user;
	d.gid = user;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

usage()
{
	sys->fprint(stderr, "usage: bt9p [-D] [-m mountpoint] -t transport\n");
	raise "fail:usage";
}

badmod(path: string)
{
	sys->fprint(stderr, "bt9p: cannot load %s: %r\n", path);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		badmod(Arg->PATH);
	str = load String String->PATH;
	if(str == nil)
		badmod(String->PATH);
	styx = load Styx Styx->PATH;
	if(styx == nil)
		badmod(Styx->PATH);
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		badmod(Styxservers->PATH);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil)
		badmod(Nametree->PATH);
	bthci = load Bthci Bthci->PATH;
	if(bthci == nil)
		badmod(Bthci->PATH);

	mountpt := "/net";
	arg->init(args);
	arg->setusage("bt9p [-D] [-m mountpoint] -t transport");
	while((o := arg->opt()) != 0)
		case o {
		'D' =>	debug = 1;
		'm' =>	mountpt = arg->earg();
		't' =>	transportname = arg->earg();
		* =>	usage();
		}
	if(transportname == nil)
		usage();

	u := readfile("/dev/user");
	if(u != nil)
		user = u;

	styx->init();
	styxservers->init(styx);
	nametree->init();
	bthci->init();

	fd := opentransport(transportname);
	if(fd == nil){
		sys->fprint(stderr, "bt9p: %s: %r\n", transportname);
		raise "fail:transport";
	}
	hci = Hci.new(Transport.h4(fd));

	(tree, treeop) := nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot, dir("bt", Sys->DMDIR|8r555, Qbt));
	tree.create(big Qbt, dir("addr", 8r444, Qaddr));
	tree.create(big Qbt, dir("status", 8r444, Qstatus));
	tree.create(big Qbt, dir("ctl", 8r220, Qctl));
	tree.create(big Qbt, dir("scan", 8r440, Qscan));
	tree.create(big Qbt, dir("event", 8r400, Qevent));
	tree.create(big Qbt, dir("hci", Sys->DMEXCL|8r600, Qhci));

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->fprint(stderr, "bt9p: pipe: %r\n");
		raise "fail:pipe";
	}
	(tc, srv) := Styxserver.new(fds[0], Navigator.new(treeop), big Qroot);
	fds[0] = nil;
	ctldone = chan of ref Ctlres;

	pidc := chan of int;
	spawn serve(tc, srv, tree, pidc);
	<-pidc;

	if(sys->mount(fds[1], nil, mountpt, Sys->MAFTER, nil) < 0){
		sys->fprint(stderr, "bt9p: mount %s: %r\n", mountpt);
		raise "fail:mount";
	}
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

#
# The transport is an fd. A dial string -- anything with a '!' in it --
# is dialled; anything else is opened read-write.
#
opentransport(spec: string): ref Sys->FD
{
	for(i := 0; i < len spec; i++)
		if(spec[i] == '!'){
			(ok, c) := sys->dial(spec, nil);
			if(ok < 0)
				return nil;
			return c.dfd;
		}
	return sys->open(spec, Sys->ORDWR);
}

#
# The serve loop: 9P requests, controller events and data, and
# finished ctl workers, from one process.
#
serve(tc: chan of ref Tmsg, srv: ref Styxserver, tree: ref Tree, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		alt {
		tmsg := <-tc =>
			if(tmsg == nil)
				break;
			if(!request(tmsg, srv))
				break;
			continue;
		e := <-hci.events =>
			if(e == nil){
				gone(srv);
				continue;
			}
			event(srv, e);
			continue;
		p := <-hci.data =>
			data(srv, p);
			continue;
		r := <-ctldone =>
			finished(srv, r);
			continue;
		}
		break;
	}
	tree.quit();
	if(hci != nil)
		hci.stop();
}

# a 9P request; returns 0 when the connection is done
request(tmsg: ref Tmsg, srv: ref Styxserver): int
{
	pick tm := tmsg {
	Readerror =>
		return 0;
	Flush =>
		cancel(tm.oldtag);
		srv.reply(ref Rmsg.Flush(tm.tag));
	Open =>
		c := srv.getfid(tm.fid);
		if(c != nil && int c.path == Qhci && hcifid >= 0){
			srv.reply(ref Rmsg.Error(tm.tag, "hci file is held"));
			return 1;
		}
		if(c != nil && int c.path == Qscan && (old := findsub(Qscan)) != nil){
			# a finished scan whose reader has not been clunked yet
			# -- a process's fds close after it exits -- is not in
			# the way; a running one is
			if(!old.done){
				srv.reply(ref Rmsg.Error(tm.tag, "inquiry in progress"));
				return 1;
			}
			dropsub(old.fid);
		}
		c = srv.open(tm);
		if(c == nil)
			return 1;
		case int c.path {
		Qhci =>
			hcifid = tm.fid;
			hciq = nil;
			hcipending = nil;
		Qevent or Qscan =>
			subs = ref Sub(tm.fid, int c.path, nil, nil, 0, 0, 0, 0) :: subs;
		}
	Read =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			return 1;
		}
		case int c.path {
		Qroot or Qbt =>
			srv.read(tm);
		Qaddr =>
			if(!up)
				srv.reply(ref Rmsg.Error(tm.tag, "controller not up"));
			else
				srv.reply(styxservers->readstr(tm, addr + "\n"));
		Qstatus =>
			srv.reply(styxservers->readstr(tm, status()));
		Qctl =>
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		Qscan =>
			s := findfid(tm.fid);
			if(s == nil){
				# superseded by a newer scan: it was done, so EOF
				srv.reply(ref Rmsg.Read(tm.tag, nil));
				return 1;
			}
			if(!s.started){
				# the first read starts the inquiry
				if(hcifid >= 0){
					srv.reply(ref Rmsg.Error(tm.tag, "hci file is held"));
					return 1;
				}
				if(busy){
					srv.reply(ref Rmsg.Error(tm.tag, "busy: another ctl is talking to the controller"));
					return 1;
				}
				s.started = 1;
				busy = 1;
				spawn inquire();
			}
			streamread(srv, s, tm);
		Qevent =>
			s := findfid(tm.fid);
			if(s == nil){
				srv.reply(ref Rmsg.Error(tm.tag, "phase error -- no subscription"));
				return 1;
			}
			streamread(srv, s, tm);
		Qhci =>
			if(hciq != nil){
				p := hd hciq;
				hciq = tl hciq;
				srv.reply(styxservers->readbytes(tm, bthci->frame(p)));
			}else if(hcipending != nil)
				srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
			else
				hcipending = tm;
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, "phase error -- bad path"));
		}
	Write =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			return 1;
		}
		case int c.path {
		Qctl =>
			ctl(srv, tm);
		Qhci =>
			if(len tm.data < 1){
				srv.reply(ref Rmsg.Error(tm.tag, "empty packet"));
				return 1;
			}
			p := ref Pkt(int tm.data[0], tm.data[1:]);
			if(hci.send(p) < 0)
				srv.reply(ref Rmsg.Error(tm.tag, sys->sprint("write: %r")));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		}
	Clunk =>
		c := srv.clunk(tm);
		if(c != nil){
			case int c.path {
			Qhci =>
				if(tm.fid == hcifid){
					hcifid = -1;
					hciq = nil;
					hcipending = nil;
				}
			Qscan =>
				s := findfid(tm.fid);
				dropsub(tm.fid);
				if(s != nil && s.started && !s.done)
					spawn cancelinquiry();
			Qevent =>
				dropsub(tm.fid);
			}
		}
	* =>
		srv.default(tmsg);
	}
	return 1;
}

findfid(fid: int): ref Sub
{
	for(l := subs; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

findsub(path: int): ref Sub
{
	for(l := subs; l != nil; l = tl l)
		if((hd l).path == path)
			return hd l;
	return nil;
}

dropsub(fid: int)
{
	keep: list of ref Sub;
	for(l := subs; l != nil; l = tl l)
		if((hd l).fid != fid)
			keep = hd l :: keep;
	subs = keep;
}

cancel(tag: int)
{
	for(l := subs; l != nil; l = tl l){
		s := hd l;
		if(s.pending != nil && s.pending.tag == tag)
			s.pending = nil;
	}
	if(hcipending != nil && hcipending.tag == tag)
		hcipending = nil;
}

#
# A streaming read: whatever lines are waiting, now; nothing waiting
# and more to come, park it; nothing waiting and done, EOF.
#
streamread(srv: ref Styxserver, s: ref Sub, tm: ref Tmsg.Read)
{
	if(s.lines == nil){
		if(s.done){
			srv.reply(ref Rmsg.Read(tm.tag, nil));
			return;
		}
		if(s.pending != nil){
			srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
			return;
		}
		s.pending = tm;
		return;
	}
	# as many whole lines as fit
	out := "";
	while(s.lines != nil){
		ln := hd s.lines;
		if(len out > 0 && len array of byte (out + ln) > tm.count)
			break;
		out += ln;
		s.lines = tl s.lines;
		s.nlines--;
	}
	tm.offset = big 0;
	srv.reply(styxservers->readstr(tm, out));
}

# a line for a streaming file: deliver to a parked read or queue it
post(srv: ref Styxserver, s: ref Sub, ln: string)
{
	if(s.pending != nil){
		tm := s.pending;
		s.pending = nil;
		tm.offset = big 0;
		srv.reply(styxservers->readstr(tm, ln));
		return;
	}
	if(s.nlines >= Maxlines){
		s.lines = tl s.lines;
		s.dropped++;
		s.nlines--;
	}
	s.lines = appendl(s.lines, ln);
	s.nlines++;
}

appendl(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: appendl(tl l, s);
}

finish(srv: ref Styxserver, s: ref Sub)
{
	s.done = 1;
	if(s.pending != nil && s.lines == nil){
		tm := s.pending;
		s.pending = nil;
		srv.reply(ref Rmsg.Read(tm.tag, nil));
	}
}

#
# Events from the controller. The hci file's holder, if any, gets the
# raw packet; event subscribers get a line; an inquiry's results go to
# its reader.
#
event(srv: ref Styxserver, e: ref Event)
{
	if(debug)
		sys->fprint(stderr, "bt9p: event 0x%2.2ux %s\n", e.code, bthci->hex(e.params));
	if(hcifid >= 0){
		d := array[2 + len e.params] of byte;
		d[0] = byte e.code;
		d[1] = byte len e.params;
		d[2:] = e.params;
		rawpost(srv, ref Pkt(Bthci->Hevt, d));
	}
	ln := sys->sprint("event 0x%2.2ux %s\n", e.code, bthci->hex(e.params));
	for(l := subs; l != nil; l = tl l)
		if((hd l).path == Qevent)
			post(srv, hd l, ln);

	case e.code {
	Bthci->EvInquiryResult or Bthci->EvInquiryResultRssi or Bthci->EvExtInquiryResult =>
		s := findsub(Qscan);
		if(s == nil)
			return;
		for(f := bthci->inquiryresults(e); f != nil; f = tl f){
			d := hd f;
			nm := d.name;
			if(nm == nil)
				nm = "-";
			post(srv, s, sys->sprint("%s 0x%6.6ux %d %s\n", d.addr, d.class, d.rssi, nm));
		}
	Bthci->EvInquiryComplete =>
		s := findsub(Qscan);
		if(s != nil)
			finish(srv, s);
	}
}

data(srv: ref Styxserver, p: ref Pkt)
{
	if(debug)
		sys->fprint(stderr, "bt9p: data kind %d %d bytes\n", p.kind, len p.data);
	if(hcifid >= 0)
		rawpost(srv, p);
}

rawpost(srv: ref Styxserver, p: ref Pkt)
{
	if(hcipending != nil){
		tm := hcipending;
		hcipending = nil;
		srv.reply(styxservers->readbytes(tm, bthci->frame(p)));
		return;
	}
	hciq = appendp(hciq, p);
}

appendp(l: list of ref Pkt, p: ref Pkt): list of ref Pkt
{
	if(l == nil)
		return p :: nil;
	return hd l :: appendp(tl l, p);
}

# the transport died under us
gone(srv: ref Styxserver)
{
	up = 0;
	why := hci.t.err;
	if(why == nil)
		why = "transport closed";
	sys->fprint(stderr, "bt9p: controller gone: %s\n", why);
	for(l := subs; l != nil; l = tl l)
		finish(srv, hd l);
	if(hcipending != nil){
		srv.reply(ref Rmsg.Error(hcipending.tag, "controller gone: " + why));
		hcipending = nil;
	}
}

status(): string
{
	s := sys->sprint("up %d\n", up);
	if(up){
		s += sys->sprint("addr %s\n", addr);
		s += sys->sprint("name %s\n", name);
		if(version != nil)
			s += version.text() + "\n";
		s += sys->sprint("class 0x%6.6ux\n", class);
		s += sys->sprint("discoverable %d\nconnectable %d\n", discoverable, connectable);
	}
	s += sys->sprint("transport %s\n", transportname);
	if(baud > 0)
		s += sys->sprint("baud %d\n", baud);
	if(firmware != nil){
		if(uploaded > 0)
			s += sys->sprint("firmware %s (uploaded %d records)\n", firmware, uploaded);
		else if(uploaded < 0)
			s += sys->sprint("firmware %s (upload failed)\n", firmware);
		else
			s += sys->sprint("firmware %s (not uploaded yet)\n", firmware);
	}
	if(hci.dead)
		s += "controller gone\n";
	s += sys->sprint("scans %d\n", scans);
	s += sys->sprint("events dropped %d\n", hci.dropped);
	if(hcifid >= 0)
		s += "hci held\n";
	return s;
}

#
# ctl. Verbs that need the controller go to a worker, one at a time,
# and the reply waits for it; the rest answer at once.
#
ctl(srv: ref Styxserver, tm: ref Tmsg.Write)
{
	(nf, f) := sys->tokenize(string tm.data, " \t\r\n");
	if(nf == 0){
		srv.reply(ref Rmsg.Error(tm.tag, "empty ctl"));
		return;
	}
	verb := hd f;
	args := tl f;
	case verb {
	"scan" =>
		if(nf != 2 || (n := int hd args) < 1 || n > 61){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: scan <seconds 1..61>"));
			return;
		}
		scansecs = n;
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		return;
	"firmware" =>
		if(nf != 2){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: firmware <path>"));
			return;
		}
		fd := sys->open(hd args, Sys->OREAD);
		if(fd == nil){
			srv.reply(ref Rmsg.Error(tm.tag, sys->sprint("%s: %r", hd args)));
			return;
		}
		firmware = hd args;
		uploaded = 0;
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		return;
	"up" or "down" or "reset" or "name" or "class" or "discoverable" or "connectable" or "baud" =>
		;
	* =>
		srv.reply(ref Rmsg.Error(tm.tag, "unknown ctl verb: " + verb));
		return;
	}
	# the verbs that talk to the controller
	if(hci.dead){
		srv.reply(ref Rmsg.Error(tm.tag, "controller gone"));
		return;
	}
	if(hcifid >= 0){
		srv.reply(ref Rmsg.Error(tm.tag, "hci file is held"));
		return;
	}
	if(busy){
		srv.reply(ref Rmsg.Error(tm.tag, "busy: another ctl is talking to the controller"));
		return;
	}
	case verb {
	"name" =>
		if(nf < 2){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: name <string>"));
			return;
		}
	"class" =>
		if(nf != 2 || parsehex(hd args) < 0){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: class <hex>"));
			return;
		}
	"discoverable" or "connectable" =>
		if(nf != 2 || (hd args != "on" && hd args != "off")){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: " + verb + " on|off"));
			return;
		}
	"baud" =>
		if(nf != 2 || (n := int hd args) < 9600 || n > 4000000){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: baud <9600..4000000>"));
			return;
		}
		if(sys->open(transportname + "ctl", Sys->OWRITE) == nil){
			srv.reply(ref Rmsg.Error(tm.tag, sys->sprint("transport has no ctl file: %sctl: %r", transportname)));
			return;
		}
	}
	busy = 1;
	spawn ctlwork(tm, verb, args);
}

parsehex(s: string): int
{
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s = s[2:];
	if(len s == 0 || len s > 8)
		return -1;
	(v, rest) := str->toint(s, 16);
	if(rest != nil)
		return -1;
	return v;
}

# one round trip, with the debug trace
cmd(op: int, params: array of byte): (int, array of byte, string)
{
	if(debug)
		sys->fprint(stderr, "bt9p: cmd 0x%4.4ux %s\n", op, bthci->hex(params));
	(st, ret, err) := hci.cmd(op, params, Cmdms);
	if(debug)
		sys->fprint(stderr, "bt9p:   -> %s%s\n", bthci->statusname(st), errsuffix(err));
	return (st, ret, err);
}

errsuffix(err: string): string
{
	if(err == nil)
		return "";
	return " (" + err + ")";
}

# a command that must succeed: nil, or why it did not
must(what: string, op: int, params: array of byte): (array of byte, string)
{
	(st, ret, err) := cmd(op, params);
	if(err != nil)
		return (nil, what + ": " + err);
	if(st != Bthci->Sok)
		return (nil, what + ": " + bthci->statusname(st));
	return (ret, nil);
}

scanenable(): array of byte
{
	v := 0;
	if(discoverable)
		v |= 1;
	if(connectable)
		v |= 2;
	return array[] of { byte v };
}

ctlwork(tm: ref Tmsg.Write, verb: string, args: list of string)
{
	r := ref Ctlres(tm, nil, 0, 0, nil, nil, nil, -1, -1, -1, 0, 0);
	case verb {
	"up" =>
		r.err = bringup(r);
	"baud" =>
		r.err = setbaud(r, int hd args);
	"down" =>
		(nil, r.err) = must("scan enable", Bthci->WriteScanEnable, array[] of { byte 0 });
		r.setup = -1;
	"reset" =>
		(nil, r.err) = must("reset", Bthci->Reset, nil);
		r.setup = -1;
	"name" =>
		nm := "";
		for(; args != nil; args = tl args){
			if(nm != "")
				nm += " ";
			nm += hd args;
		}
		p := array[248] of { * => byte 0 };
		b := array of byte nm;
		if(len b > 247)
			b = b[0:247];
		p[0:] = b;
		(nil, r.err) = must("name", Bthci->WriteLocalName, p);
		if(r.err == nil)
			r.name = nm;
	"class" =>
		v := parsehex(hd args);
		p := array[3] of byte;
		p[0] = byte v;
		p[1] = byte (v >> 8);
		p[2] = byte (v >> 16);
		(nil, r.err) = must("class", Bthci->WriteClassOfDevice, p);
		if(r.err == nil)
			r.class = v;
	"discoverable" or "connectable" =>
		on := hd args == "on";
		v := 0;
		if(verb == "discoverable"){
			if(on) v |= 1;
			if(connectable) v |= 2;
		}else{
			if(discoverable) v |= 1;
			if(on) v |= 2;
		}
		(nil, r.err) = must("scan enable", Bthci->WriteScanEnable, array[] of { byte v });
		if(r.err == nil){
			if(verb == "discoverable")
				r.disc = on;
			else
				r.conn = on;
		}
	}
	ctldone <-= r;
}

#
# up: reset the controller and learn who it is. Nothing here uploads
# firmware; a Broadcom part answers this much from ROM, so addr and
# status work before milestone 3 and are the first thing to see on
# the board.
#
bringup(r: ref Ctlres): string
{
	ret: array of byte;
	(nil, err) := must("reset", Bthci->Reset, nil);
	if(err != nil)
		return "no controller: " + err;
	(ret, err) = must("read local version", Bthci->ReadLocalVersion, nil);
	if(err != nil)
		return err;
	r.version = Version.parse(ret);
	if(firmware != nil){
		(r.uploaded, err) = bcmpatch(firmware);
		if(err != nil){
			r.uploaded = -1;
			return err;
		}
		# the controller has rebooted into the patch: start again
		(nil, err) = must("reset after patch", Bthci->Reset, nil);
		if(err != nil)
			return "no controller after the patch: " + err;
		(ret, err) = must("read local version", Bthci->ReadLocalVersion, nil);
		if(err != nil)
			return err;
		r.version = Version.parse(ret);
	}
	(ret, err) = must("read bd_addr", Bthci->ReadBdaddr, nil);
	if(err != nil)
		return err;
	r.addr = bthci->bdaddr(ret, 0);
	(ret, err) = must("read local name", Bthci->ReadLocalName, nil);
	if(err != nil)
		return err;
	n := 0;
	while(n < len ret && ret[n] != byte 0)
		n++;
	r.name = string ret[0:n];
	# every event the host understands; reserved bits stay clear
	mask := array[8] of { * => byte 16rff };
	mask[5] = byte 16r1f;
	mask[6] = byte 0;
	mask[7] = byte 0;
	(nil, err) = must("set event mask", Bthci->SetEventMask, mask);
	if(err != nil)
		return err;
	# inquiry results with RSSI, if the controller will; not fatal if it will not
	cmd(Bthci->WriteInquiryMode, array[] of { byte 1 });
	(nil, err) = must("scan enable", Bthci->WriteScanEnable, scanenable());
	if(err != nil)
		return err;
	r.setup = 1;
	return nil;
}

#
# The Broadcom patch: Download_Minidriver puts the ROM into its
# loader; the .hcd's records are then sent as the commands they are,
# each answered; Launch_RAM, the last, restarts the controller on the
# patched firmware, which takes a moment and forgets everything,
# including any baud rate change. This is what BlueZ's hciattach
# bcm43xx and Linux's btbcm do, in the order they do it.
#
Bcmsettle: con 50;		# ms after Download_Minidriver, before the first record
Bcmrelaunch: con 250;		# ms after Launch_RAM, before the controller answers again

bcmpatch(path: string): (int, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (0, sys->sprint("firmware %s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0 || d.length <= big 0 || d.length > big (4*1024*1024))
		return (0, sys->sprint("firmware %s: bad size", path));
	hcd := array[int d.length] of byte;
	n := 0;
	while(n < len hcd){
		m := sys->read(fd, hcd[n:], len hcd - n);
		if(m <= 0)
			return (0, sys->sprint("firmware %s: short read: %r", path));
		n += m;
	}
	(recs, bad) := bthci->hcdrecords(hcd);
	if(recs == nil)
		return (0, sys->sprint("firmware %s: malformed record at byte %d", path, bad));

	(nil, err) := must("download minidriver", Bthci->BcmDownloadMinidriver, nil);
	if(err != nil)
		return (0, err);
	sys->sleep(Bcmsettle);
	sent := 0;
	for(; recs != nil; recs = tl recs){
		(op, params) := hd recs;
		(nil, err) = must(sys->sprint("patch record %d (0x%4.4ux)", sent, op), op, params);
		if(err != nil)
			return (sent, err);
		sent++;
	}
	sys->sleep(Bcmrelaunch);
	return (sent, nil);
}

#
# Change rate: the controller first, at the old rate, then our side
# through the transport's ctl file. Update_UART_Baud_Rate takes two
# zero bytes (encoded baud, unused) and the rate little-endian.
#
setbaud(r: ref Ctlres, n: int): string
{
	p := array[6] of byte;
	p[0] = byte 0;
	p[1] = byte 0;
	bthci->put4(p, 2, n);
	(nil, err) := must("update baud rate", Bthci->BcmUpdateBaudrate, p);
	if(err != nil)
		return err;
	fd := sys->open(transportname + "ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%sctl: %r", transportname);
	if(sys->fprint(fd, "b%d", n) < 0)
		return sys->sprint("%sctl: b%d: %r", transportname, n);
	r.baud = n;
	return nil;
}

# the serve loop applies what a worker learned and answers the write
finished(srv: ref Styxserver, r: ref Ctlres)
{
	busy = 0;
	if(r.scanning){
		# the inquiry's Command Status: the read is parked or streaming already
		s := findsub(Qscan);
		if(r.err != nil){
			if(s != nil){
				s.done = 1;
				if(s.pending != nil){
					srv.reply(ref Rmsg.Error(s.pending.tag, r.err));
					s.pending = nil;
				}
			}
			sys->fprint(stderr, "bt9p: inquiry: %s\n", r.err);
		}else
			scans++;
		return;
	}
	if(r.err != nil){
		srv.reply(ref Rmsg.Error(r.tm.tag, r.err));
		return;
	}
	if(r.setup > 0){
		up = 1;
		addr = r.addr;
		name = r.name;
		version = r.version;
		if(firmware != nil)
			uploaded = r.uploaded;
	}else if(r.setup < 0){
		up = 0;
	}else if(r.baud > 0){
		baud = r.baud;
	}else{
		if(r.name != nil)
			name = r.name;
		if(r.class >= 0)
			class = r.class;
		if(r.disc >= 0)
			discoverable = r.disc;
		if(r.conn >= 0)
			connectable = r.conn;
	}
	srv.reply(ref Rmsg.Write(r.tm.tag, len r.tm.data));
}

#
# An inquiry: GIAC, scansecs in units of 1.28s, unlimited responses.
# The Command Status comes back here; the results and the completion
# arrive as events and go to the scan reader.
#
inquire()
{
	r := ref Ctlres(nil, nil, 1, 0, nil, nil, nil, -1, -1, -1, 0, 0);
	if(!up)
		r.err = "controller not up";
	else{
		p := array[5] of byte;
		p[0] = byte 16r33;
		p[1] = byte 16r8b;
		p[2] = byte 16r9e;
		n := (scansecs * 100 + 64) / 128;
		if(n < 1)
			n = 1;
		if(n > 16r30)
			n = 16r30;
		p[3] = byte n;
		p[4] = byte 0;
		(nil, r.err) = must("inquiry", Bthci->Inquiry, p);
	}
	ctldone <-= r;
}

cancelinquiry()
{
	cmd(Bthci->InquiryCancel, nil);
}
