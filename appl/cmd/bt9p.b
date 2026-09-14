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
#                     firmware <path> | baud <n> | bdaddr <addr> | iocap none|display|yesno|keyboard
#                     pairable on|off | forget <addr>
#     pair      read  pairing prompts, one per line, while held open:
#                     "confirm <addr> <123456>", "passkey <addr> <123456>",
#                     "passkey? <addr>", "paired <addr>", "failed <addr> <why>";
#                     write "yes <addr>" | "no <addr>" | "passkey <addr> <n>"
#     scan      read  runs an inquiry; one device per line, "<addr> <class>
#                     <rssi> <name>", each written once its name is known
#                     (from the EIR, or a Remote Name Request after the
#                     inquiry; "-" if it will not say); EOF after the last
#     lescan    read  the same for LE: "<addr> public|random <rssi> <name>",
#                     one line per device heard, EOF when the scan time is up
#     event     read  the HCI event stream as text, "event 0x0e 01 03 0c 00",
#                     one per line, as long as the file is held open. Debugging.
#     hci       read/write raw H4 packets, exclusive. While held, ctl verbs
#                     that would issue commands are refused: the stack has
#                     lent the controller to whoever holds this.
#     clone     open  a new conversation N; the open fid is N's ctl and reads "N"
#     N/ctl     write "connect <addr>!<psm>" -- the reply waits until the L2CAP
#                     channel is open, or fails saying why; "announce <psm>";
#                     "hangup"
#     N/data    read  one SDU per read (a whole L2CAP frame); write one SDU
#     N/status  read  Connected | Connecting | Listen | Closed | Hangup <why>
#     N/local   read  "<our addr>!<psm>"
#     N/remote  read  "<peer addr>!<psm>"
#     N/listen  open  on an announced conversation, blocks until a peer connects
#                     to its PSM; reading gives the new conversation's number
#
# Because clone and the conversation directories have /net/tcp's
# shape, dial(2)'s dial("bt!addr!psm"), announce("bt!*!psm") and
# listen() work with no change to dial. Conversations live until their
# last file is closed; a link (an ACL connection to one peer) lives
# while anything on it does.
#
# Keys, the WiFi way (docs/BLUETOOTH.md, M6). factotum is the only
# source of secrets: a peer's Link Key Request is answered from
# "proto=btlink addr=<peer>", a PIN Code Request from "proto=btpin
# addr=<peer>" and then "proto=btpin" alone, and a key the controller
# reports at the end of pairing is written to factotum's ctl -- and,
# with -k, appended to a keys file in the same syntax, so the next
# boot loads it as it loads the WiFi keys. Nothing prompts unless a
# file is being read: with iocap none (the default) Secure Simple
# Pairing is Just Works, and with pairable off (the default) a peer
# cannot start a pairing we did not ask for. iocap yesno turns the
# confirmations into lines on the pair file; nobody reading it means
# no.
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

include "factotum.m";
	factotum: Factotum;

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

include "l2cap.m";
	l2cap: L2cap;
	Link, Chan, Ev: import l2cap;

Bt9p: module
{
	init:	fn(ctxt: ref Draw->Context, args: list of string);
};

Qroot, Qbt, Qaddr, Qstatus, Qctl, Qscan, Qlescan, Qevent, Qhci, Qclone, Qpair: con iota;

# a conversation's files: path is (id+1)<<8 | one of these
Qcdir, Qcctl, Qcdata, Qcstatus, Qclocal, Qcremote, Qclisten: con 1 + iota;
CPATH(id, q: int): int { return ((id + 1) << 8) | q; }
CONVID(path: int): int { return (path >> 8) - 1; }
CTYPE(path: int): int { return path & 16rff; }

#
# Links and conversations. A Lnk is an ACL connection to one peer with
# its L2CAP on top; a Conv is one directory under /net/bt, an L2CAP
# channel or a listener for a PSM.
#
Lconnecting, Lup: con iota;

Lnk: adt {
	addr:	string;
	handle:	int;
	state:	int;
	l2:	ref Link;
	waiting: list of ref Conv;	# to connect once the link is up
	ours:	int;			# we made it, so pairing on it was asked for
};
links: list of ref Lnk;
aclmtu := 27;			# the controller's ACL packet size, from Read_Buffer_Size
aclcredits := 1;		# ACL packets the controller can take now
aclq: list of ref Pkt;		# waiting for a credit
inflight: list of (int, int);	# per handle, packets sent and not yet completed

Conv: adt {
	id:	int;
	state:	string;
	lnk:	ref Lnk;
	ch:	ref Chan;
	psm:	int;
	raddr:	string;
	opens:	int;
	listening: int;
	accepted: int;			# an incoming call, held for a listener
	rq:	list of array of byte;	# SDUs waiting to be read
	rpending: ref Tmsg.Read;
	cpending: ref Tmsg.Write;	# a connect waiting for the channel
	lpending: ref Tmsg.Open;	# a listen waiting for a call
	lq:	list of int;		# calls accepted, not yet handed to a listener
};
convs: list of ref Conv;
nconv := 0;
clonefids: list of (int, int);	# fid -> conversation, for opens of clone and listen
thetree: ref Tree;

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
iocap := Bthci->IOnone;		# what we tell peers we can do about pairing
pairable := 0;			# may a peer start a pairing we did not ask for?
keyfile := "";			# where new link keys are also written, in factotum's syntax
factdir := "/mnt/factotum";
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
	found:	list of ref Found;	# scan: devices whose names are still to be asked for
	naming:	string;			# scan: the address a Remote Name Request is out for
	seen:	list of string;		# lescan: addresses already reported
	nameless: list of ref Found;	# lescan: heard, no name yet; a scan response may bring one
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
	kind:	string;			# nil: a ctl verb; else "name", "lestart", "ledone"
	who:	string;			# the address a name request was for
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
	aclmtu:	int;			# from Read_Buffer_Size on up
	aclnum:	int;
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
	sys->fprint(stderr, "usage: bt9p [-D] [-m mountpoint] [-k keyfile] [-f factotum] -t transport\n");
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
	l2cap = load L2cap L2cap->PATH;
	if(l2cap == nil)
		badmod(L2cap->PATH);
	factotum = load Factotum Factotum->PATH;
	if(factotum == nil)
		badmod(Factotum->PATH);

	mountpt := "/net";
	arg->init(args);
	arg->setusage("bt9p [-D] [-m mountpoint] -t transport");
	while((o := arg->opt()) != 0)
		case o {
		'D' =>	debug = 1;
		'm' =>	mountpt = arg->earg();
		't' =>	transportname = arg->earg();
		'k' =>	keyfile = arg->earg();
		'f' =>	factdir = arg->earg();
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
	l2cap->init(bthci);
	factotum->init();

	fd := opentransport(transportname);
	if(fd == nil){
		sys->fprint(stderr, "bt9p: %s: %r\n", transportname);
		raise "fail:transport";
	}
	hci = Hci.new(Transport.h4(fd));

	if(keyfile != nil)
		loadkeys();

	(tree, treeop) := nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot, dir("bt", Sys->DMDIR|8r555, Qbt));
	tree.create(big Qbt, dir("addr", 8r444, Qaddr));
	tree.create(big Qbt, dir("status", 8r444, Qstatus));
	tree.create(big Qbt, dir("ctl", 8r220, Qctl));
	tree.create(big Qbt, dir("scan", 8r440, Qscan));
	tree.create(big Qbt, dir("lescan", 8r440, Qlescan));
	tree.create(big Qbt, dir("event", 8r400, Qevent));
	tree.create(big Qbt, dir("hci", Sys->DMEXCL|8r600, Qhci));
	tree.create(big Qbt, dir("clone", 8r666, Qclone));
	tree.create(big Qbt, dir("pair", 8r600, Qpair));
	thetree = tree;

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
# A serial port gets hardware flow control turned on, through the ctl
# file eia(3) puts beside it. The Broadcom controller will not
# transmit until its CTS is asserted -- on the Pi 3B+ the first HCI
# Reset times out with the PL011's RTS undriven and answers at once
# with it driven -- and hciattach sets CRTSCTS for bcm43xx for the
# same reason. Nothing else about the port is touched: the rate is
# the controller's default until "baud" says otherwise.
#
# The port is identified before it is touched: eia(3)'s status file
# begins "b<rate> c<n> ...", and only a file that reads that way is
# one whose ctl understands "m1". btmock(4) has a ctl beside its
# file too, and it does not.
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
	fd := sys->open(spec, Sys->ORDWR);
	if(fd == nil)
		return nil;
	if(iseia(spec)){
		ctl := sys->open(spec + "ctl", Sys->OWRITE);
		if(ctl == nil || sys->fprint(ctl, "m1") < 0)
			sys->fprint(stderr, "bt9p: %sctl: m1: %r\n", spec);
	}
	return fd;
}

iseia(spec: string): int
{
	fd := sys->open(spec + "status", Sys->OREAD);
	if(fd == nil)
		return 0;
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 3 || buf[0] != byte 'b')
		return 0;
	for(i := 1; i < n && buf[i] != byte ' '; i++)
		if(buf[i] < byte '0' || buf[i] > byte '9')
			return 0;
	return i > 1 && i < n;
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
		if(c != nil && (int c.path == Qscan || int c.path == Qlescan) && (old := findsub(int c.path)) != nil){
			# a finished scan whose reader has not been clunked yet
			# -- a process's fds close after it exits -- is not in
			# the way; a running one is
			if(!old.done){
				srv.reply(ref Rmsg.Error(tm.tag, "scan in progress"));
				return 1;
			}
			dropsub(old.fid);
		}
		if(c != nil && CONVID(int c.path) >= 0){
			if(!convopen(srv, tm, c))
				return 1;
		}
		if(c != nil && int c.path == Qclone && !up){
			srv.reply(ref Rmsg.Error(tm.tag, "controller not up"));
			return 1;
		}
		c = srv.open(tm);
		if(c == nil)
			return 1;
		case int c.path {
		Qclone =>
			cv := newconv();
			cv.opens++;
			clonefids = (tm.fid, cv.id) :: clonefids;
		Qhci =>
			hcifid = tm.fid;
			hciq = nil;
			hcipending = nil;
		Qevent or Qscan or Qlescan or Qpair =>
			subs = ref Sub(tm.fid, int c.path, nil, nil, 0, 0, 0, 0, nil, nil, nil, nil) :: subs;
		}
	Read =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			return 1;
		}
		if(CONVID(int c.path) >= 0){
			convread(srv, tm, c);
			return 1;
		}
		case int c.path {
		Qroot or Qbt =>
			srv.read(tm);
		Qclone =>
			cv := clonefid(tm.fid);
			if(cv == nil)
				srv.reply(ref Rmsg.Error(tm.tag, "phase error -- no conversation"));
			else
				srv.reply(styxservers->readstr(tm, sys->sprint("%d", cv.id)));
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
		Qlescan =>
			s := findfid(tm.fid);
			if(s == nil){
				srv.reply(ref Rmsg.Read(tm.tag, nil));
				return 1;
			}
			if(!s.started){
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
				spawn lescanwork(scansecs);
			}
			streamread(srv, s, tm);
		Qevent or Qpair =>
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
		if(CONVID(int c.path) >= 0){
			convwrite(srv, tm, c);
			return 1;
		}
		case int c.path {
		Qctl =>
			ctl(srv, tm);
		Qpair =>
			pairwrite(srv, tm);
		Qclone =>
			cv := clonefid(tm.fid);
			if(cv == nil)
				srv.reply(ref Rmsg.Error(tm.tag, "phase error -- no conversation"));
			else
				convctl(srv, tm, cv);
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
			if(CONVID(int c.path) >= 0 || int c.path == Qclone){
				# a walk that was never opened -- a stat -- holds nothing
				if(c.isopen)
					convclunk(srv, tm.fid, c);
				return 1;
			}
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
			Qlescan or Qevent or Qpair =>
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
	for(cl := convs; cl != nil; cl = tl cl){
		cv := hd cl;
		if(cv.rpending != nil && cv.rpending.tag == tag)
			cv.rpending = nil;
		if(cv.cpending != nil && cv.cpending.tag == tag)
			cv.cpending = nil;
		if(cv.lpending != nil && cv.lpending.tag == tag)
			cv.lpending = nil;
	}
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
		if(s == nil || s.done)
			return;
		for(f := bthci->inquiryresults(e); f != nil; f = tl f){
			d := hd f;
			if(knows(s, d.addr))
				continue;
			s.seen = d.addr :: s.seen;
			if(d.name != nil)
				post(srv, s, foundline(d));
			else
				s.found = appendf(s.found, d);
		}
	Bthci->EvInquiryComplete =>
		s := findsub(Qscan);
		if(s != nil && !s.done)
			nextname(srv, s);
	Bthci->EvRemoteName =>
		s := findsub(Qscan);
		if(s == nil || s.done || s.naming == nil)
			return;
		(st, who, nm) := bthci->remotename(e);
		if(who != s.naming)
			return;
		if(s.found != nil){
			d := hd s.found;
			s.found = tl s.found;
			if(st == Bthci->Sok && nm != nil)
				d.name = nm;
			post(srv, s, foundline(d));
		}
		s.naming = nil;
		nextname(srv, s);
	Bthci->EvConnComplete =>
		(st, h, who, nil) := bthci->conncomplete(e);
		linkup(srv, who, h, st);
	Bthci->EvConnRequest =>
		(who, nil, ltype) := bthci->connrequest(e);
		if(ltype != 1)
			return;
		# a peer calls: accept, as a peripheral. The link then completes
		# like one we asked for.
		if(linkbyaddr(who) == nil)
			links = ref Lnk(who, 0, Lconnecting, nil, nil, 0) :: links;
		spawn accept(who);
	Bthci->EvDisconnComplete =>
		(nil, h, reason) := bthci->disconncomplete(e);
		lk := linkbyhandle(h);
		if(lk != nil)
			linkdown(srv, lk, "link lost: " + bthci->statusname(reason));
		# whatever was still in the controller for that handle is
		# gone with it, and so is the room it took (Vol 4 Part E 7.7.5)
		aclcredits += completed(h, -1);
		aclpump();
	Bthci->EvNumCompleted =>
		for(nl := bthci->numcompleted(e); nl != nil; nl = tl nl){
			(h, n) := hd nl;
			aclcredits += completed(h, n);
		}
		aclpump();
	Bthci->EvLinkKeyRequest =>
		who := bthci->evaddr(e);
		if(who != nil)
			spawn linkkey(who);
	Bthci->EvPinRequest =>
		who := bthci->evaddr(e);
		if(who == nil)
			return;
		if(!mayPair(who)){
			pairnote(srv, sys->sprint("failed %s pairing not allowed\n", who));
			spawn fire(Bthci->PinCodeNegative, e.params[0:6]);
		}else
			spawn pincode(who);
	Bthci->EvLinkKeyNotify =>
		(who, key, ktype) := bthci->linkkeynotify(e);
		if(who != nil)
			spawn storekey(who, key, ktype);
	Bthci->EvIoCapRequest =>
		who := bthci->evaddr(e);
		if(who == nil)
			return;
		if(!mayPair(who)){
			pairnote(srv, sys->sprint("failed %s pairing not allowed\n", who));
			r := array[7] of byte;
			r[0:] = e.params[0:6];
			r[6] = byte 16r18;	# pairing not allowed
			spawn fire(Bthci->IoCapabilityNegative, r);
			return;
		}
		r := array[9] of byte;
		r[0:] = e.params[0:6];
		r[6] = byte iocap;
		r[7] = byte 0;		# no out-of-band data
		if(iocap == Bthci->IOnone)
			r[8] = byte Bthci->AUTHbond;
		else
			r[8] = byte Bthci->AUTHbondmitm;
		spawn fire(Bthci->IoCapabilityReply, r);
	Bthci->EvUserConfirmRequest =>
		(who, n) := bthci->usernumber(e);
		if(who == nil)
			return;
		if(iocap == Bthci->IOnone){
			# Just Works: nothing to compare, nobody to ask
			spawn fire(Bthci->UserConfirmReply, e.params[0:6]);
		}else if(findsub(Qpair) != nil){
			pairnote(srv, sys->sprint("confirm %s %6.6d\n", who, n));
		}else{
			# a question with nobody to answer it is a no
			spawn fire(Bthci->UserConfirmNegative, e.params[0:6]);
		}
	Bthci->EvUserPasskeyRequest =>
		who := bthci->evaddr(e);
		if(who == nil)
			return;
		if(findsub(Qpair) != nil)
			pairnote(srv, sys->sprint("passkey? %s\n", who));
		else
			spawn fire(Bthci->UserPasskeyNegative, e.params[0:6]);
	Bthci->EvUserPasskeyNotify =>
		(who, n) := bthci->usernumber(e);
		if(who != nil)
			pairnote(srv, sys->sprint("passkey %s %6.6d\n", who, n));
	Bthci->EvSimplePairingComplete =>
		who := bthci->evaddr(e);
		if(who == nil)
			return;
		if(int e.params[0] == Bthci->Sok)
			pairnote(srv, sys->sprint("paired %s\n", who));
		else
			pairnote(srv, sys->sprint("failed %s %s\n", who, bthci->statusname(int e.params[0])));
	Bthci->EvLeMeta =>
		s := findsub(Qlescan);
		if(s == nil || s.done)
			return;
		# The same rule as scan: a device's line waits for its name.
		# An advertisement rarely carries one; the scan response to
		# our active scan usually does, and it is a separate report.
		# A device still nameless when the scan ends gets its line
		# with "-" then, once, so nothing is ever corrected.
		for(f := bthci->leadvreports(e); f != nil; f = tl f){
			d := hd f;
			if(knows(s, d.addr))
				continue;
			if(d.name == nil){
				if(!nameless(s, d.addr))
					s.nameless = d :: s.nameless;
				continue;
			}
			s.seen = d.addr :: s.seen;
			s.nameless = dropfound(s.nameless, d.addr);
			post(srv, s, foundline(d));
		}
	}
}

nameless(s: ref Sub, addr: string): int
{
	for(l := s.nameless; l != nil; l = tl l)
		if((hd l).addr == addr)
			return 1;
	return 0;
}

dropfound(l: list of ref Found, addr: string): list of ref Found
{
	keep: list of ref Found;
	for(; l != nil; l = tl l)
		if((hd l).addr != addr)
			keep = hd l :: keep;
	return keep;
}

knows(s: ref Sub, addr: string): int
{
	for(l := s.seen; l != nil; l = tl l)
		if(hd l == addr)
			return 1;
	return 0;
}

appendf(l: list of ref Found, f: ref Found): list of ref Found
{
	if(l == nil)
		return f :: nil;
	return hd l :: appendf(tl l, f);
}

foundline(d: ref Found): string
{
	nm := d.name;
	if(nm == nil)
		nm = "-";
	if(d.letype < 0)
		return sys->sprint("%s 0x%6.6ux %d %s\n", d.addr, d.class, d.rssi, nm);
	t := "public";
	if(d.letype == 1)
		t = "random";
	return sys->sprint("%s %s %d %s\n", d.addr, t, d.rssi, nm);
}

#
# After the inquiry, the names: one Remote Name Request at a time for
# each device that did not say its own, its line written when the
# answer comes; EOF after the last.
#
nextname(srv: ref Styxserver, s: ref Sub)
{
	if(s.found == nil){
		finish(srv, s);
		return;
	}
	d := hd s.found;
	s.naming = d.addr;
	spawn namework(d.addr);
}

namework(addr: string)
{
	r := ref Ctlres(nil, nil, 0, "name", addr, 0, nil, nil, nil, -1, -1, -1, 0, 0, 0, 0);
	a := bthci->parsebdaddr(addr);
	p := array[10] of { * => byte 0 };
	if(a == nil)
		r.err = "bad address";
	else{
		p[0:] = a;
		p[6] = byte 1;		# page scan repetition mode R1
		(nil, r.err) = must("remote name request", Bthci->RemoteNameRequest, p);
	}
	ctldone <-= r;
}

#
# An LE scan: active, for scansecs, duplicates filtered by the
# controller and again here. The worker enables, reports that it
# has, sleeps, disables, and reports that it is over; the
# advertisements arrive as events between.
#
lescanwork(secs: int)
{
	r := ref Ctlres(nil, nil, 0, "lestart", nil, 0, nil, nil, nil, -1, -1, -1, 0, 0, 0, 0);
	if(!up)
		r.err = "controller not up";
	else{
		# active scan, interval and window 10ms, public own address, no filter
		p := array[7] of byte;
		p[0] = byte 1;
		bthci->put2(p, 1, 16r10);
		bthci->put2(p, 3, 16r10);
		p[5] = byte 0;
		p[6] = byte 0;
		(nil, r.err) = must("le set scan parameters", Bthci->LeSetScanParameters, p);
		if(r.err == nil)
			(nil, r.err) = must("le set scan enable", Bthci->LeSetScanEnable, array[] of { byte 1, byte 1 });
	}
	err := r.err;
	ctldone <-= r;
	if(err != nil)
		return;
	sys->sleep(secs * 1000);
	r = ref Ctlres(nil, nil, 0, "ledone", nil, 0, nil, nil, nil, -1, -1, -1, 0, 0, 0, 0);
	(nil, r.err) = must("le set scan enable", Bthci->LeSetScanEnable, array[] of { byte 0, byte 0 });
	ctldone <-= r;
}

data(srv: ref Styxserver, p: ref Pkt)
{
	if(debug)
		sys->fprint(stderr, "bt9p: data kind %d %d bytes\n", p.kind, len p.data);
	if(hcifid >= 0){
		rawpost(srv, p);
		return;
	}
	if(p.kind != Bthci->Hacl)
		return;
	(h, nil) := bthci->aclheader(p);
	lk := linkbyhandle(h);
	if(lk == nil || lk.l2 == nil)
		return;
	l2events(srv, lk, lk.l2.recv(p));
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
	s += sys->sprint("iocap %s\npairable %d\n", iocapname(iocap), pairable);
	if(keyfile != nil)
		s += sys->sprint("keyfile %s\n", keyfile);
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
	nl := 0;
	for(ll := links; ll != nil; ll = tl ll)
		nl++;
	nc := 0;
	for(cl := convs; cl != nil; cl = tl cl)
		nc++;
	s += sys->sprint("links %d\nconversations %d\nacl mtu %d credits %d\n", nl, nc, aclmtu, aclcredits);
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
	"iocap" =>
		v := -1;
		if(nf == 2)
			case hd args {
			"none" =>	v = Bthci->IOnone;
			"display" =>	v = Bthci->IOdisplayonly;
			"yesno" =>	v = Bthci->IOdisplayyesno;
			"keyboard" =>	v = Bthci->IOkeyboardonly;
			}
		if(v < 0){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: iocap none|display|yesno|keyboard"));
			return;
		}
		iocap = v;
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		return;
	"pairable" =>
		if(nf != 2 || (hd args != "on" && hd args != "off")){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: pairable on|off"));
			return;
		}
		pairable = hd args == "on";
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		return;
	"forget" =>
		if(nf != 2 || bthci->parsebdaddr(hd args) == nil){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: forget <addr>"));
			return;
		}
		err := forget(hd args);
		if(err != nil)
			srv.reply(ref Rmsg.Error(tm.tag, err));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		return;
	"up" or "down" or "reset" or "name" or "class" or "discoverable" or "connectable" or "baud" or "bdaddr" =>
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
	"bdaddr" =>
		if(nf != 2 || bthci->parsebdaddr(hd args) == nil){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: bdaddr <xx:xx:xx:xx:xx:xx>"));
			return;
		}
		if(!up || version == nil){
			srv.reply(ref Rmsg.Error(tm.tag, "controller not up"));
			return;
		}
		# 0xfc01 is Write_BD_ADDR on a Broadcom or Cypress part and
		# something else on anyone else's; nothing is sent to a
		# controller that would take it for something else
		if(version.manuf != 15 && version.manuf != 305){
			srv.reply(ref Rmsg.Error(tm.tag, "bdaddr: not a Broadcom controller: " + version.text()));
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
	r := ref Ctlres(tm, nil, 0, nil, nil, 0, nil, nil, nil, -1, -1, -1, 0, 0, 0, 0);
	case verb {
	"up" =>
		r.err = bringup(r);
	"baud" =>
		r.err = setbaud(r, int hd args);
	"bdaddr" =>
		# Broadcom's Write_BD_ADDR takes effect at once, and the
		# address the controller then reports is what we record
		(nil, r.err) = must("write bd_addr", Bthci->BcmWriteBdaddr, bthci->parsebdaddr(hd args));
		if(r.err == nil){
			ret: array of byte;
			(ret, r.err) = must("read bd_addr", Bthci->ReadBdaddr, nil);
			if(r.err == nil)
				r.addr = bthci->bdaddr(ret, 0);
		}
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
	mask[6] = byte 16rbf;	# IO capability, confirmation, passkey, pairing complete
	# bit 61 (0x20 here) is the LE Meta Event, and every LE event --
	# every advertising report a scan exists to hear -- arrives inside
	# one. Without it the controller answers LE_Set_Scan_Enable with
	# success and then says nothing, which is what the board did while
	# a Linux host beside it heard a dozen advertisers. The mock never
	# consulted the mask, so nothing below the radio could have shown
	# this.
	mask[7] = byte 16r3d;	# LE meta, passkey notification, remote host features
	(nil, err) = must("set event mask", Bthci->SetEventMask, mask);
	if(err != nil)
		return err;
	# A dual-mode controller starts with its LE half invisible to the
	# host; BlueZ sets this for the same reason. Not fatal: a
	# classic-only controller refuses it and loses nothing.
	cmd(Bthci->WriteLeHostSupported, array[] of { byte 1, byte 0 });
	# how big an ACL packet the controller takes, and how many at once
	(ret, err) = must("read buffer size", Bthci->ReadBufferSize, nil);
	if(err != nil)
		return err;
	if(len ret >= 7){
		r.aclmtu = bthci->get2(ret, 0);
		r.aclnum = bthci->get2(ret, 3);
	}
	# inquiry results with RSSI, if the controller will; not fatal if it will not
	cmd(Bthci->WriteInquiryMode, array[] of { byte 1 });
	# Secure Simple Pairing, if the controller has it; a 2.0 part refuses and pairs with PINs
	cmd(Bthci->WriteSimplePairingMode, array[] of { byte 1 });
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
	case r.kind {
	"conntimeout" =>
		cv := conv(int r.who);
		if(cv != nil && cv.state == "Connecting" && !cv.accepted)
			hangup(srv, cv, "connection timed out");
		return;
	"linkfail" =>
		lk := linkbyaddr(r.who);
		if(lk != nil && lk.state == Lconnecting)
			linkdown(srv, lk, "connection failed: " + r.err);
		return;
	"name" =>
		# a Remote Name Request refused outright: the device goes out nameless
		if(r.err != nil){
			s := findsub(Qscan);
			if(s != nil && !s.done && s.naming == r.who){
				if(s.found != nil){
					post(srv, s, foundline(hd s.found));
					s.found = tl s.found;
				}
				s.naming = nil;
				nextname(srv, s);
			}
		}
		return;
	"lestart" =>
		busy = 0;
		s := findsub(Qlescan);
		if(r.err != nil && s != nil){
			s.done = 1;
			if(s.pending != nil){
				srv.reply(ref Rmsg.Error(s.pending.tag, r.err));
				s.pending = nil;
			}
		}
		return;
	"ledone" =>
		s := findsub(Qlescan);
		if(s != nil){
			# the devices that never said their name, oldest first
			rest: list of ref Found;
			for(l := s.nameless; l != nil; l = tl l)
				rest = hd l :: rest;
			for(; rest != nil; rest = tl rest){
				s.seen = (hd rest).addr :: s.seen;
				post(srv, s, foundline(hd rest));
			}
			s.nameless = nil;
			finish(srv, s);
		}
		scans++;
		return;
	}
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
		if(r.aclmtu > 0){
			aclmtu = r.aclmtu;
			aclcredits = r.aclnum;
		}
		if(firmware != nil)
			uploaded = r.uploaded;
	}else if(r.setup < 0){
		up = 0;
		for(ll := links; ll != nil; ll = tl ll)
			linkdown(srv, hd ll, "controller down");
	}else if(r.baud > 0){
		baud = r.baud;
	}else{
		if(r.addr != nil)
			addr = r.addr;
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
	r := ref Ctlres(nil, nil, 1, nil, nil, 0, nil, nil, nil, -1, -1, -1, 0, 0, 0, 0);
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

#
# Conversations.
#

newconv(): ref Conv
{
	cv := ref Conv(nconv++, "Closed", nil, nil, 0, nil, 0, 0, 0, nil, nil, nil, nil, nil);
	convs = cv :: convs;
	id := cv.id;
	nm := sys->sprint("%d", id);
	thetree.create(big Qbt, dir(nm, Sys->DMDIR|8r555, CPATH(id, Qcdir)));
	thetree.create(big CPATH(id, Qcdir), dir("ctl", 8r666, CPATH(id, Qcctl)));
	thetree.create(big CPATH(id, Qcdir), dir("data", 8r666, CPATH(id, Qcdata)));
	thetree.create(big CPATH(id, Qcdir), dir("status", 8r444, CPATH(id, Qcstatus)));
	thetree.create(big CPATH(id, Qcdir), dir("local", 8r444, CPATH(id, Qclocal)));
	thetree.create(big CPATH(id, Qcdir), dir("remote", 8r444, CPATH(id, Qcremote)));
	thetree.create(big CPATH(id, Qcdir), dir("listen", 8r444, CPATH(id, Qclisten)));
	return cv;
}

freeconv(cv: ref Conv)
{
	keep: list of ref Conv;
	for(cl := convs; cl != nil; cl = tl cl)
		if(hd cl != cv)
			keep = hd cl :: keep;
	convs = keep;
	id := cv.id;
	thetree.remove(big CPATH(id, Qcctl));
	thetree.remove(big CPATH(id, Qcdata));
	thetree.remove(big CPATH(id, Qcstatus));
	thetree.remove(big CPATH(id, Qclocal));
	thetree.remove(big CPATH(id, Qcremote));
	thetree.remove(big CPATH(id, Qclisten));
	thetree.remove(big CPATH(id, Qcdir));
}

conv(id: int): ref Conv
{
	for(cl := convs; cl != nil; cl = tl cl)
		if((hd cl).id == id)
			return hd cl;
	return nil;
}

clonefid(fid: int): ref Conv
{
	for(l := clonefids; l != nil; l = tl l){
		(f, id) := hd l;
		if(f == fid)
			return conv(id);
	}
	return nil;
}

dropclonefid(fid: int)
{
	keep: list of (int, int);
	for(l := clonefids; l != nil; l = tl l){
		(f, nil) := hd l;
		if(f != fid)
			keep = hd l :: keep;
	}
	clonefids = keep;
}

# listeners announced for a PSM
listener(psm: int): ref Conv
{
	for(cl := convs; cl != nil; cl = tl cl)
		if((hd cl).listening && (hd cl).psm == psm)
			return hd cl;
	return nil;
}

announced(): list of int
{
	l: list of int;
	for(cl := convs; cl != nil; cl = tl cl)
		if((hd cl).listening)
			l = (hd cl).psm :: l;
	return l;
}

# an Open on a conversation's file; returns 0 if it has been answered
convopen(srv: ref Styxserver, tm: ref Tmsg.Open, c: ref Fid): int
{
	cv := conv(CONVID(int c.path));
	if(cv == nil){
		srv.reply(ref Rmsg.Error(tm.tag, "conversation gone"));
		return 0;
	}
	case CTYPE(int c.path) {
	Qclisten =>
		if(!cv.listening){
			srv.reply(ref Rmsg.Error(tm.tag, "not announced"));
			return 0;
		}
		if(cv.lpending != nil){
			srv.reply(ref Rmsg.Error(tm.tag, "listen already pending"));
			return 0;
		}
		if(cv.lq == nil){
			# nobody has called yet: the open waits
			cv.lpending = tm;
			cv.opens++;
			return 0;
		}
		nc := srv.open(tm);
		if(nc == nil)
			return 0;
		clonefids = (tm.fid, hd cv.lq) :: clonefids;
		cv.lq = tl cv.lq;
		cv.opens++;
		return 0;
	Qcctl or Qcdata =>
		nc := srv.open(tm);
		if(nc != nil)
			cv.opens++;
		return 0;
	}
	srv.open(tm);
	return 0;
}

# a listen that was waiting: a call has come in
listenwake(srv: ref Styxserver, cv: ref Conv)
{
	if(cv.lpending == nil || cv.lq == nil)
		return;
	tm := cv.lpending;
	cv.lpending = nil;
	c := srv.getfid(tm.fid);
	if(c == nil)
		return;
	clonefids = (tm.fid, hd cv.lq) :: clonefids;
	cv.lq = tl cv.lq;
	c.open(Styx->OREAD, Sys->Qid(big CPATH(cv.id, Qclisten), 0, Sys->QTFILE));
	srv.reply(ref Rmsg.Open(tm.tag, Sys->Qid(big CPATH(cv.id, Qclisten), 0, Sys->QTFILE), srv.iounit()));
}

convread(srv: ref Styxserver, tm: ref Tmsg.Read, c: ref Fid)
{
	cv := conv(CONVID(int c.path));
	if(cv == nil){
		srv.reply(ref Rmsg.Error(tm.tag, "conversation gone"));
		return;
	}
	case CTYPE(int c.path) {
	Qcdir =>
		srv.read(tm);
	Qcctl =>
		srv.reply(styxservers->readstr(tm, sys->sprint("%d", cv.id)));
	Qcstatus =>
		srv.reply(styxservers->readstr(tm, cv.state + "\n"));
	Qclocal =>
		srv.reply(styxservers->readstr(tm, sys->sprint("%s!%d\n", addr, cv.psm)));
	Qcremote =>
		if(cv.raddr == nil)
			srv.reply(styxservers->readstr(tm, "\n"));
		else
			srv.reply(styxservers->readstr(tm, sys->sprint("%s!%d\n", cv.raddr, cv.psm)));
	Qclisten =>
		# the accepted conversation's number, as dial(2) reads it
		acc := clonefid(tm.fid);
		if(acc == nil)
			srv.reply(ref Rmsg.Error(tm.tag, "phase error -- no call"));
		else
			srv.reply(styxservers->readstr(tm, sys->sprint("%d", acc.id)));
	Qcdata =>
		if(cv.rq != nil){
			sdu := hd cv.rq;
			cv.rq = tl cv.rq;
			tm.offset = big 0;
			srv.reply(styxservers->readbytes(tm, sdu));
		}else if(cv.state != "Connected" && cv.state != "Connecting")
			srv.reply(ref Rmsg.Read(tm.tag, nil));	# EOF: hung up
		else if(cv.rpending != nil)
			srv.reply(ref Rmsg.Error(tm.tag, "read already pending"));
		else
			cv.rpending = tm;
	* =>
		srv.reply(ref Rmsg.Error(tm.tag, "phase error -- bad path"));
	}
}

convwrite(srv: ref Styxserver, tm: ref Tmsg.Write, c: ref Fid)
{
	cv := conv(CONVID(int c.path));
	if(cv == nil){
		srv.reply(ref Rmsg.Error(tm.tag, "conversation gone"));
		return;
	}
	case CTYPE(int c.path) {
	Qcctl =>
		convctl(srv, tm, cv);
	Qcdata =>
		if(cv.state != "Connected" || cv.lnk == nil || cv.ch == nil){
			srv.reply(ref Rmsg.Error(tm.tag, "not connected"));
			return;
		}
		if(len tm.data > cv.ch.mtu){
			srv.reply(ref Rmsg.Error(tm.tag, sys->sprint("SDU too large: peer MTU is %d", cv.ch.mtu)));
			return;
		}
		l2events(srv, cv.lnk, cv.lnk.l2.send(cv.ch, tm.data));
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	* =>
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
	}
}

convctl(srv: ref Styxserver, tm: ref Tmsg.Write, cv: ref Conv)
{
	(nf, f) := sys->tokenize(string tm.data, " \t\r\n");
	if(nf == 0){
		srv.reply(ref Rmsg.Error(tm.tag, "empty ctl"));
		return;
	}
	case hd f {
	"connect" =>
		if(nf != 2){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: connect <addr>!<psm>"));
			return;
		}
		(na, parts) := sys->tokenize(hd tl f, "!");
		if(na != 2 || bthci->parsebdaddr(hd parts) == nil || (psm := parsepsm(hd tl parts)) <= 0){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: connect <addr>!<psm>"));
			return;
		}
		if(cv.state != "Closed"){
			srv.reply(ref Rmsg.Error(tm.tag, "conversation in use: " + cv.state));
			return;
		}
		if(!up){
			srv.reply(ref Rmsg.Error(tm.tag, "controller not up"));
			return;
		}
		if(hcifid >= 0){
			srv.reply(ref Rmsg.Error(tm.tag, "hci file is held"));
			return;
		}
		cv.raddr = hd parts;
		cv.psm = psm;
		cv.state = "Connecting";
		cv.cpending = tm;
		connect(srv, cv);
		spawn conntimer(cv.id);
	"announce" =>
		if(nf != 2 || (psm := parsepsm(hd tl f)) <= 0){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: announce <psm>"));
			return;
		}
		if(cv.state != "Closed"){
			srv.reply(ref Rmsg.Error(tm.tag, "conversation in use: " + cv.state));
			return;
		}
		if(listener(psm) != nil){
			srv.reply(ref Rmsg.Error(tm.tag, "PSM already announced"));
			return;
		}
		cv.psm = psm;
		cv.listening = 1;
		cv.state = "Listen";
		for(ll := links; ll != nil; ll = tl ll)
			if((hd ll).l2 != nil)
				(hd ll).l2.accept = announced();
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	"hangup" =>
		hangup(srv, cv, "hangup");
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	* =>
		srv.reply(ref Rmsg.Error(tm.tag, "unknown ctl verb: " + hd f));
	}
}

# a PSM: decimal, or 0x hex; odd, as the specification requires
parsepsm(s: string): int
{
	v := -1;
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		v = parsehex(s);
	else{
		(n, rest) := str->toint(s, 10);
		if(rest == nil)
			v = n;
	}
	if(v <= 0 || v > 16rffff || (v & 1) == 0)
		return -1;
	return v;
}

convclunk(srv: ref Styxserver, fid: int, c: ref Fid)
{
	cv: ref Conv;
	if(int c.path == Qclone || CTYPE(int c.path) == Qclisten){
		# the clone fid was a conversation's ctl; a listen fid holds
		# the accepted conversation, and the listener's count too
		acc := clonefid(fid);
		dropclonefid(fid);
		if(CTYPE(int c.path) == Qclisten){
			# the listener's count, and the accepted conversation's
			# hold, which the listen fid carried
			ls := conv(CONVID(int c.path));
			if(ls != nil)
				release(srv, ls);
			if(acc != nil)
				release(srv, acc);
			return;
		}
		cv = acc;
	}else
		cv = conv(CONVID(int c.path));
	if(cv == nil)
		return;
	case CTYPE(int c.path) {
	Qcctl or Qcdata =>
		release(srv, cv);
	* =>
		if(int c.path == Qclone)
			release(srv, cv);
	}
}

release(srv: ref Styxserver, cv: ref Conv)
{
	if(--cv.opens > 0)
		return;
	cv.opens = 0;
	if(cv.lpending != nil){
		srv.reply(ref Rmsg.Error(cv.lpending.tag, "listener closed"));
		cv.lpending = nil;
	}
	if(cv.state == "Connected" || cv.state == "Connecting")
		hangup(srv, cv, "closed");
	if(cv.listening){
		cv.listening = 0;
		for(ll := links; ll != nil; ll = tl ll)
			if((hd ll).l2 != nil)
				(hd ll).l2.accept = announced();
		# calls accepted that no listen ever read
		for(q := cv.lq; q != nil; q = tl q){
			acc := conv(hd q);
			if(acc != nil)
				release(srv, acc);
		}
		cv.lq = nil;
	}
	freeconv(cv);
	idlelinks();
}

# a link we made that nobody uses goes down; it is forgotten now
# rather than at its Disconnection Complete, so a new connect to the
# same peer makes a new link instead of using one on its way out. A
# channel still waiting for its Disconnection Response keeps the link
# until it comes.
#
# A link the peer made is the peer's to end. A phone pairing with us
# connects, asks about L2CAP features, and only then starts
# authentication; hanging up the moment it had no channel -- which
# this did, on the board, and the phone said "couldn't connect" --
# ends the pairing before it begins. The peer that made the link
# drops it when it is done, and the controller's supervision timeout
# covers a peer that vanishes.
idlelinks()
{
	for(ll := links; ll != nil; ll = tl ll){
		lk := hd ll;
		if(lk.ours && lk.state == Lup && lk.l2 != nil && lk.l2.chans == nil && lk.waiting == nil && !linkwanted(lk)){
			forgetlink(lk);
			spawn disconnect(lk.handle);
		}
	}
}

forgetlink(lk: ref Lnk)
{
	keep: list of ref Lnk;
	for(ll := links; ll != nil; ll = tl ll)
		if(hd ll != lk)
			keep = hd ll :: keep;
	links = keep;
}

linkwanted(lk: ref Lnk): int
{
	for(cl := convs; cl != nil; cl = tl cl)
		if((hd cl).lnk == lk)
			return 1;
	return 0;
}

hangup(srv: ref Styxserver, cv: ref Conv, why: string)
{
	if(cv.lnk != nil && cv.ch != nil && cv.lnk.l2 != nil && cv.state == "Connected")
		l2events(srv, cv.lnk, cv.lnk.l2.disconnect(cv.ch));
	if(cv.state == "Connecting" && cv.lnk != nil)
		cv.lnk.waiting = without(cv.lnk.waiting, cv);
	closed(srv, cv, why);
}

# the conversation is over, one way or another
closed(srv: ref Styxserver, cv: ref Conv, why: string)
{
	if(why == "hangup" || why == "closed")
		cv.state = "Closed";
	else
		cv.state = "Hangup " + why;
	cv.ch = nil;
	if(cv.cpending != nil){
		srv.reply(ref Rmsg.Error(cv.cpending.tag, why));
		cv.cpending = nil;
	}
	if(cv.rpending != nil){
		srv.reply(ref Rmsg.Read(cv.rpending.tag, nil));
		cv.rpending = nil;
	}
	cv.lnk = nil;
}

without(l: list of ref Conv, cv: ref Conv): list of ref Conv
{
	keep: list of ref Conv;
	for(; l != nil; l = tl l)
		if(hd l != cv)
			keep = hd l :: keep;
	return keep;
}

#
# Links.
#

linkbyaddr(a: string): ref Lnk
{
	for(ll := links; ll != nil; ll = tl ll)
		if((hd ll).addr == a)
			return hd ll;
	return nil;
}

linkbyhandle(h: int): ref Lnk
{
	for(ll := links; ll != nil; ll = tl ll)
		if((hd ll).state == Lup && (hd ll).handle == h)
			return hd ll;
	return nil;
}

# connect a conversation: over the link to its peer, made if need be
connect(srv: ref Styxserver, cv: ref Conv)
{
	lk := linkbyaddr(cv.raddr);
	if(lk == nil){
		lk = ref Lnk(cv.raddr, 0, Lconnecting, nil, nil, 1);
		links = lk :: links;
		spawn createconn(cv.raddr);
	}
	cv.lnk = lk;
	if(lk.state != Lup){
		lk.waiting = cv :: lk.waiting;
		return;
	}
	l2connect(srv, lk, cv);
}

l2connect(srv: ref Styxserver, lk: ref Lnk, cv: ref Conv)
{
	(ch, evs) := lk.l2.connect(cv.psm);
	cv.ch = ch;
	l2events(srv, lk, evs);
}

# a Connection Complete: the link is up, or it is not
linkup(srv: ref Styxserver, who: string, h, st: int)
{
	lk := linkbyaddr(who);
	if(lk == nil)
		return;
	if(st != Bthci->Sok){
		linkdown(srv, lk, "connection failed: " + bthci->statusname(st));
		return;
	}
	lk.handle = h;
	lk.state = Lup;
	lk.l2 = Link.new(h);
	lk.l2.accept = announced();
	w := lk.waiting;
	lk.waiting = nil;
	for(; w != nil; w = tl w)
		l2connect(srv, lk, hd w);
}

linkdown(srv: ref Styxserver, lk: ref Lnk, why: string)
{
	forgetlink(lk);
	for(w := lk.waiting; w != nil; w = tl w)
		closed(srv, hd w, why);
	lk.waiting = nil;
	if(lk.l2 != nil)
		l2events(srv, lk, lk.l2.down(why));
	for(cl := convs; cl != nil; cl = tl cl)
		if((hd cl).lnk == lk)
			closed(srv, hd cl, why);
}

# what L2CAP asked for: frames out, channels up and down, data in
l2events(srv: ref Styxserver, lk: ref Lnk, evs: list of ref Ev)
{
	for(; evs != nil; evs = tl evs){
		pick e := hd evs {
		Send =>
			for(pl := l2cap->fragment(lk.handle, e.frame, aclmtu); pl != nil; pl = tl pl)
				aclq = appendp(aclq, hd pl);
			aclpump();
		Opened =>
			cv := convbychan(lk, e.c);
			if(cv == nil)
				continue;
			cv.state = "Connected";
			if(cv.cpending != nil){
				srv.reply(ref Rmsg.Write(cv.cpending.tag, len cv.cpending.data));
				cv.cpending = nil;
			}
			# an accepted call, now open: hand it to the listener
			if(cv.accepted){
				ls := listener(cv.psm);
				if(ls == nil)
					release(srv, cv);
				else{
					ls.lq = appendi(ls.lq, cv.id);
					listenwake(srv, ls);
				}
			}
		Incoming =>
			ls := listener(e.c.psm);
			if(ls == nil)
				continue;
			nc := newconv();
			nc.lnk = lk;
			nc.ch = e.c;
			nc.psm = e.c.psm;
			nc.raddr = lk.addr;
			nc.state = "Connecting";
			nc.accepted = 1;
			nc.opens = 1;		# held for the listener until a listen takes it
		Closed =>
			cv := convbychan(lk, e.c);
			if(cv != nil){
				held := cv.accepted && cv.state == "Connecting";
				closed(srv, cv, e.reason);
				if(held)
					release(srv, cv);	# a call that died before any listen saw it
			}
		Data =>
			cv := convbychan(lk, e.c);
			if(cv == nil)
				continue;
			if(cv.rpending != nil){
				tm := cv.rpending;
				cv.rpending = nil;
				tm.offset = big 0;
				srv.reply(styxservers->readbytes(tm, e.sdu));
			}else
				cv.rq = appendb(cv.rq, e.sdu);
		}
	}
	idlelinks();
}

convbychan(lk: ref Lnk, ch: ref Chan): ref Conv
{
	for(cl := convs; cl != nil; cl = tl cl)
		if((hd cl).lnk == lk && (hd cl).ch == ch)
			return hd cl;
	return nil;
}

appendi(l: list of int, i: int): list of int
{
	if(l == nil)
		return i :: nil;
	return hd l :: appendi(tl l, i);
}

appendb(l: list of array of byte, b: array of byte): list of array of byte
{
	if(l == nil)
		return b :: nil;
	return hd l :: appendb(tl l, b);
}

# ACL packets go out as the controller has room, Read_Buffer_Size's
# count at a time, Number Of Completed Packets giving room back
aclpump()
{
	while(aclcredits > 0 && aclq != nil){
		p := hd aclq;
		aclq = tl aclq;
		if(hci.send(p) < 0)
			continue;
		aclcredits--;
		(h, nil) := bthci->aclheader(p);
		sent(h);
	}
}

sent(h: int)
{
	l: list of (int, int);
	found := 0;
	for(il := inflight; il != nil; il = tl il){
		(ih, n) := hd il;
		if(ih == h){
			n++;
			found = 1;
		}
		l = (ih, n) :: l;
	}
	if(!found)
		l = (h, 1) :: l;
	inflight = l;
}

# n packets on handle h completed, or all of them if n < 0; returns
# how many credits that gives back
completed(h, n: int): int
{
	l: list of (int, int);
	back := 0;
	for(il := inflight; il != nil; il = tl il){
		(ih, m) := hd il;
		if(ih == h){
			if(n < 0 || n > m)
				n = m;
			back = n;
			m -= n;
		}
		if(m > 0)
			l = (ih, m) :: l;
	}
	inflight = l;
	return back;
}

#
# The HCI commands a link needs, from workers: their events do the
# rest, so nothing waits for them here.
#
createconn(who: string)
{
	a := bthci->parsebdaddr(who);
	p := array[13] of { * => byte 0 };
	p[0:] = a;
	bthci->put2(p, 6, 16rcc18);	# DM1 DH1 DM3 DH3 DM5 DH5
	p[8] = byte 1;			# page scan repetition mode R1
	p[12] = byte 1;			# allow role switch
	(st, nil, err) := cmd(Bthci->CreateConnection, p);
	if(err != nil || st != Bthci->Sok){
		# no Connection Complete will come: say so through one
		r := ref Ctlres(nil, nil, 0, "linkfail", who, 0, nil, nil, nil, -1, -1, -1, 0, 0, 0, 0);
		if(err != nil)
			r.err = err;
		else
			r.err = bthci->statusname(st);
		ctldone <-= r;
	}
}

accept(who: string)
{
	a := bthci->parsebdaddr(who);
	p := array[7] of { * => byte 0 };
	p[0:] = a;
	p[6] = byte 1;			# remain peripheral
	cmd(Bthci->AcceptConnection, p);
}

#
# The reason is what the OTHER end will be told, and the command
# admits only a few: "remote user terminated" (16r13) is the one for
# an ordinary hangup. 16r16, "terminated by local host", is what our
# own Disconnection Complete then says; sent as the reason it is a
# parameter error -- the mock let it pass, a Realtek controller did not.
#
disconnect(h: int)
{
	p := array[3] of byte;
	bthci->put2(p, 0, h);
	p[2] = byte Bthci->Sremoteterm;
	cmd(Bthci->Disconnect, p);
}

fire(op: int, params: array of byte)
{
	cmd(op, params);
}

#
# A connect that neither completes nor fails -- a peer that never
# answers the L2CAP request, a link that pages for ever -- is failed
# from here, so a write to ctl always returns.
#
Connms: con 15000;

conntimer(id: int)
{
	sys->sleep(Connms);
	r := ref Ctlres(nil, nil, 0, "conntimeout", sys->sprint("%d", id), 0, nil, nil, nil, -1, -1, -1, 0, 0, 0, 0);
	ctldone <-= r;
}

#
# Pairing. factotum holds every key; these workers ask it and answer
# the controller. The protocol modules are auth/proto/btlink and
# auth/proto/btpin; the rpc is the one ip/wpa makes for its passphrase.
#

iocapname(v: int): string
{
	case v {
	Bthci->IOnone =>	return "none";
	Bthci->IOdisplayonly =>	return "display";
	Bthci->IOdisplayyesno =>	return "yesno";
	Bthci->IOkeyboardonly =>	return "keyboard";
	}
	return "?";
}

# may this peer start a pairing? yes if we called it, or if pairable is on
mayPair(who: string): int
{
	lk := linkbyaddr(who);
	if(lk != nil && lk.ours)
		return 1;
	return pairable;
}

# a line for whoever holds the pair file open
pairnote(srv: ref Styxserver, ln: string)
{
	if(debug)
		sys->fprint(stderr, "bt9p: pair: %s", ln);
	for(l := subs; l != nil; l = tl l)
		if((hd l).path == Qpair)
			post(srv, hd l, ln);
}

pairwrite(srv: ref Styxserver, tm: ref Tmsg.Write)
{
	(nf, f) := sys->tokenize(string tm.data, " \t\r\n");
	if(nf < 2 || (a := bthci->parsebdaddr(hd tl f)) == nil){
		srv.reply(ref Rmsg.Error(tm.tag, "usage: yes|no <addr> | passkey <addr> <digits>"));
		return;
	}
	case hd f {
	"yes" =>
		spawn fire(Bthci->UserConfirmReply, a);
	"no" =>
		spawn fire(Bthci->UserConfirmNegative, a);
	"passkey" =>
		if(nf != 3){
			srv.reply(ref Rmsg.Error(tm.tag, "usage: passkey <addr> <digits>"));
			return;
		}
		(n, rest) := str->toint(hd tl tl f, 10);
		if(rest != nil || n < 0 || n > 999999){
			srv.reply(ref Rmsg.Error(tm.tag, "passkey is six digits"));
			return;
		}
		p := array[10] of byte;
		p[0:] = a;
		bthci->put4(p, 6, n);
		spawn fire(Bthci->UserPasskeyReply, p);
	* =>
		srv.reply(ref Rmsg.Error(tm.tag, "usage: yes|no <addr> | passkey <addr> <digits>"));
		return;
	}
	srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
}

# one secret from factotum, or nil with the reason in errstr
secret(keyspec: string): string
{
	fd := sys->open(factdir + "/rpc", Sys->ORDWR);
	if(fd == nil)
		return nil;
	(o, nil) := factotum->rpc(fd, "start", array of byte keyspec);
	if(o != "ok"){
		sys->werrstr(o);
		return nil;
	}
	(o2, a) := factotum->rpc(fd, "read", nil);
	if(o2 != "ok"){
		sys->werrstr(o2);
		return nil;
	}
	if(a == nil || len a == 0){
		sys->werrstr("factotum returned nothing");
		return nil;
	}
	return string a;
}

linkkey(who: string)
{
	a := bthci->parsebdaddr(who);
	k := secret(sys->sprint("proto=btlink addr=%q", who));
	if(k != nil){
		(nf, f) := sys->tokenize(k, " ");
		key := bthci->parsekey(hd f);
		if(nf >= 1 && key != nil){
			p := array[22] of byte;
			p[0:] = a;
			p[6:] = key;
			cmd(Bthci->LinkKeyReply, p);
			return;
		}
	}
	if(debug)
		sys->fprint(stderr, "bt9p: no link key for %s: %r\n", who);
	cmd(Bthci->LinkKeyNegative, a);
}

pincode(who: string)
{
	a := bthci->parsebdaddr(who);
	pin := secret(sys->sprint("proto=btpin addr=%q", who));
	if(pin == nil)
		pin = secret("proto=btpin");
	if(pin == nil || len pin < 1 || len pin > 16){
		if(debug)
			sys->fprint(stderr, "bt9p: no PIN for %s: %r\n", who);
		cmd(Bthci->PinCodeNegative, a);
		return;
	}
	p := array[23] of { * => byte 0 };
	p[0:] = a;
	p[6] = byte len pin;
	p[7:] = array of byte pin;
	cmd(Bthci->PinCodeReply, p);
}

#
# The keys file is the card's copy of what factotum should hold, in
# factotum's own syntax, one key a line; comments and blank lines are
# factotum's to ignore. At start every key line goes to factotum's
# ctl, one write each -- multiline writes are refused by design, so a
# bad line is named -- as osinit loads the WiFi keys. A file that is
# not there yet is not an error: it is written when the first pairing
# makes a key.
#
loadkeys()
{
	kf := sys->open(keyfile, Sys->OREAD);
	if(kf == nil)
		return;
	(ok, d) := sys->fstat(kf);
	if(ok < 0 || d.length > big (1024*1024)){
		sys->fprint(stderr, "bt9p: %s: not a keys file\n", keyfile);
		return;
	}
	buf := array[int d.length] of byte;
	n := 0;
	while(n < len buf){
		m := sys->read(kf, buf[n:], len buf - n);
		if(m <= 0)
			break;
		n += m;
	}
	fd := sys->open(factdir + "/ctl", Sys->OWRITE);
	if(fd == nil){
		sys->fprint(stderr, "bt9p: %s: %s/ctl: %r\n", keyfile, factdir);
		return;
	}
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	loaded := 0;
	for(; lines != nil; lines = tl lines){
		ln := hd lines;
		if(len ln < 4 || ln[0:4] != "key ")
			continue;
		if(sys->fprint(fd, "%s", ln) < 0){
			sys->fprint(stderr, "bt9p: %s: factotum refused a key: %r\n", keyfile);
			continue;
		}
		loaded++;
	}
	if(debug)
		sys->fprint(stderr, "bt9p: %d key(s) from %s\n", loaded, keyfile);
}

# a key the controller made: into factotum now, and onto the card for next time
storekey(who: string, key: array of byte, ktype: int)
{
	line := sys->sprint("key proto=btlink addr=%q type=%d !key=%s", who, ktype, bthci->keytext(key));
	fd := sys->open(factdir + "/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", line) < 0){
		sys->fprint(stderr, "bt9p: factotum refused the link key for %s: %r\n", who);
		return;
	}
	if(keyfile != nil){
		kf := sys->open(keyfile, Sys->OWRITE);
		if(kf == nil)
			kf = sys->create(keyfile, Sys->OWRITE, 8r600);
		if(kf == nil || sys->seek(kf, big 0, Sys->SEEKEND) < big 0 || sys->fprint(kf, "%s\n", line) < 0)
			sys->fprint(stderr, "bt9p: cannot write %s: %r\n", keyfile);
	}
}

# forget a peer: its key out of factotum, and out of the keys file
forget(who: string): string
{
	fd := sys->open(factdir + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%s/ctl: %r", factdir);
	if(sys->fprint(fd, "delkey proto=btlink addr=%q", who) < 0)
		return sys->sprint("factotum: %r");
	if(keyfile == nil)
		return nil;
	kf := sys->open(keyfile, Sys->OREAD);
	if(kf == nil)
		return nil;
	(ok, d) := sys->fstat(kf);
	if(ok < 0 || d.length > big (1024*1024))
		return nil;
	buf := array[int d.length] of byte;
	n := 0;
	while(n < len buf){
		m := sys->read(kf, buf[n:], len buf - n);
		if(m <= 0)
			break;
		n += m;
	}
	(nil, lines) := sys->tokenize(string buf[0:n], "\n");
	out := "";
	want := sys->sprint("addr=%q", who);
	for(; lines != nil; lines = tl lines){
		ln := hd lines;
		if(contains(ln, "proto=btlink") && contains(ln, want))
			continue;
		out += ln + "\n";
	}
	kf = sys->create(keyfile, Sys->OWRITE|Sys->OTRUNC, 8r600);
	if(kf == nil)
		return sys->sprint("%s: %r", keyfile);
	b := array of byte out;
	if(sys->write(kf, b, len b) != len b)
		return sys->sprint("%s: %r", keyfile);
	return nil;
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}
