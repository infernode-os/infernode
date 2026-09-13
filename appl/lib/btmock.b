implement Btmock;

include "sys.m";
	sys: Sys;
include "bthci.m";
	bthci: Bthci;
	Pkt, Found, Deframer: import bthci;
include "l2cap.m";
	l2cap: L2cap;
	Link, Chan, Ev: import l2cap;
include "btmock.m";

init(b: Bthci, l: L2cap)
{
	sys = load Sys Sys->PATH;
	bthci = b;
	l2cap = l;
}

Aclmtu: con 1021;	# what Read_Buffer_Size promises

Ctlr.new(addr: string): ref Ctlr
{
	a := bthci->parsebdaddr(addr);
	if(a == nil)
		a = array[6] of { * => byte 0 };
	return ref Ctlr(a, "btmock", 8, 8, 15, 0, 0, nil, 0, 0, nil, 0, nil, 0, nil, nil, Deframer.new(), nil, nil, 1, nil, nil, nil, 0);
}

Ctlr.seen(c: self ref Ctlr, op: int): int
{
	n := 0;
	want := sys->sprint("cmd 0x%4.4ux", op);
	for(l := c.log; l != nil; l = tl l)
		if(len hd l >= len want && (hd l)[0:len want] == want)
			n++;
	return n;
}

# an event packet, framed
event(code: int, params: array of byte): array of byte
{
	d := array[2 + len params] of byte;
	d[0] = byte code;
	d[1] = byte len params;
	d[2:] = params;
	return bthci->frame(ref Pkt(Bthci->Hevt, d));
}

# Command Complete for op, with status and return parameters
complete(c: ref Ctlr, op, status: int, ret: array of byte): array of byte
{
	p := array[4 + len ret] of byte;
	p[0] = byte credit(c);
	bthci->put2(p, 1, op);
	p[3] = byte status;
	p[4:] = ret;
	return event(Bthci->EvCmdComplete, p);
}

# Command Status for op
cmdstatus(c: ref Ctlr, op, status: int): array of byte
{
	p := array[4] of byte;
	p[0] = byte status;
	p[1] = byte credit(c);
	bthci->put2(p, 2, op);
	return event(Bthci->EvCmdStatus, p);
}

credit(c: ref Ctlr): int
{
	if(c.stingy){
		c.owed = 1;
		return 0;
	}
	return 1;
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

Ctlr.feed(c: self ref Ctlr, b: array of byte): array of byte
{
	out := array[0] of byte;
	for(l := c.d.feed(b); l != nil; l = tl l){
		p := hd l;
		if(p.kind == Bthci->Hacl){
			out = cat(out, acl(c, p));
			continue;
		}
		if(p.kind != Bthci->Hcmd || len p.data < 3)
			continue;
		op := bthci->get2(p.data, 0);
		n := int p.data[2];
		if(3 + n > len p.data)
			continue;
		params := p.data[3:3+n];
		c.log = sys->sprint("cmd 0x%4.4ux %s", op, bthci->hex(params)) :: c.log;
		out = cat(out, handle(c, op, params));
	}
	return out;
}

handle(c: ref Ctlr, op: int, params: array of byte): array of byte
{
	case op {
	Bthci->Reset =>
		c.scanenable = 0;
		c.inquiring = nil;
		c.inquirydone = 0;
		return complete(c, op, Bthci->Sok, nil);
	Bthci->ReadBdaddr =>
		return complete(c, op, Bthci->Sok, c.addr);
	Bthci->ReadLocalVersion =>
		r := array[8] of byte;
		r[0] = byte c.hci;
		bthci->put2(r, 1, 16r1234);
		r[3] = byte c.lmp;
		bthci->put2(r, 4, c.manuf);
		bthci->put2(r, 6, 16r0421);
		return complete(c, op, Bthci->Sok, r);
	Bthci->ReadLocalName =>
		r := array[248] of { * => byte 0 };
		nm := array of byte c.name;
		if(len nm > 247)
			nm = nm[0:247];
		r[0:] = nm;
		return complete(c, op, Bthci->Sok, r);
	Bthci->WriteLocalName =>
		n := 0;
		while(n < len params && params[n] != byte 0)
			n++;
		c.name = string params[0:n];
		return complete(c, op, Bthci->Sok, nil);
	Bthci->WriteScanEnable =>
		if(len params < 1 || int params[0] > 3)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		c.scanenable = int params[0];
		return complete(c, op, Bthci->Sok, nil);
	Bthci->ReadScanEnable =>
		return complete(c, op, Bthci->Sok, array[] of { byte c.scanenable });
	Bthci->WriteClassOfDevice =>
		if(len params < 3)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		c.class = int params[0] | (int params[1] << 8) | (int params[2] << 16);
		return complete(c, op, Bthci->Sok, nil);
	Bthci->SetEventMask or Bthci->WriteInquiryMode or Bthci->InquiryCancel
	or Bthci->LeSetScanParameters =>
		if(op == Bthci->InquiryCancel){
			c.inquiring = nil;
			c.inquirydone = 0;
		}
		return complete(c, op, Bthci->Sok, nil);
	Bthci->LeSetScanEnable =>
		if(len params < 2)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		c.lescanning = int params[0];
		if(c.lescanning)
			c.leadv = c.nearby;
		else
			c.leadv = nil;
		return complete(c, op, Bthci->Sok, nil);
	Bthci->RemoteNameRequest =>
		if(len params < 10)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		c.naming = appendn(c.naming, bthci->bdaddr(params, 0));
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->ReadBufferSize =>
		r := array[7] of byte;
		bthci->put2(r, 0, 1021);
		r[2] = byte 64;
		bthci->put2(r, 3, 8);
		bthci->put2(r, 5, 8);
		return complete(c, op, Bthci->Sok, r);
	Bthci->Inquiry =>
		if(len params < 5)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		c.inquiring = c.nearby;
		c.inquirydone = 1;
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->CreateConnection =>
		if(len params < 13)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		addr := bthci->bdaddr(params, 0);
		pr := ref Peer(addr, 0, 0, nil, 0, 0, nil, 0);
		if(lookup(c, addr) != nil)
			pr.handle = c.nexthandle++;
		# unknown devices page out: Connection Complete with page timeout, on the tick
		c.pendconn = appendpeer(c.pendconn, pr);
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->AcceptConnection =>
		if(len params < 7)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		addr := bthci->bdaddr(params, 0);
		pr := findpeer(c, addr);
		if(pr == nil || pr.state != 2)
			return cmdstatus(c, op, Bthci->Sunknownconn);
		pr.handle = c.nexthandle++;
		pr.state = 0;
		c.pendconn = appendpeer(c.pendconn, pr);
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->RejectConnection =>
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->LinkKeyReply =>
		if(len params < 22)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		addr := bthci->bdaddr(params, 0);
		pr := findpeer(c, addr);
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr == nil || pr.state != 3)
			return out;
		k := storedkey(c, addr);
		if(k != nil && sameb(k, params[6:22])){
			pr.state = 7;		# authenticated: the connection completes on the tick
			c.pendconn = appendpeer(c.pendconn, pr);
		}else
			out = cat(out, connfail(c, pr, Bthci->Sauthfail));
		return out;
	Bthci->LinkKeyNegative =>
		if(len params < 6)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		addr := bthci->bdaddr(params, 0);
		pr := findpeer(c, addr);
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr == nil || pr.state != 3)
			return out;
		# no key at the host: pair, the way this device pairs
		kind := authkind(c, addr);
		if(len kind >= 4 && kind[0:4] == "pin="){
			pr.state = 4;
			out = cat(out, event(Bthci->EvPinRequest, params[0:6]));
		}else if(kind == "ssp"){
			pr.state = 5;
			out = cat(out, event(Bthci->EvIoCapRequest, params[0:6]));
		}else
			out = cat(out, connfail(c, pr, Bthci->Sauthfail));
		return out;
	Bthci->PinCodeReply =>
		if(len params < 23)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		addr := bthci->bdaddr(params, 0);
		pr := findpeer(c, addr);
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr == nil || pr.state != 4)
			return out;
		n := int params[6];
		if(n > 16)
			n = 16;
		pin := string params[7:7+n];
		if("pin=" + pin == authkind(c, addr))
			return cat(out, paired(c, pr, Bthci->LKcombination));
		return cat(out, connfail(c, pr, Bthci->Sauthfail));
	Bthci->PinCodeNegative =>
		if(len params < 6)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		pr := findpeer(c, bthci->bdaddr(params, 0));
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr != nil && pr.state == 4)
			out = cat(out, connfail(c, pr, Bthci->Snokey));
		return out;
	Bthci->IoCapabilityReply =>
		if(len params < 9)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		addr := bthci->bdaddr(params, 0);
		pr := findpeer(c, addr);
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr == nil || pr.state != 5)
			return out;
		# our capability: none, no OOB, general bonding; then the number to confirm
		r := array[9] of byte;
		r[0:] = params[0:6];
		r[6] = byte Bthci->IOnone;
		r[7] = byte 0;
		r[8] = byte Bthci->AUTHbond;
		out = cat(out, event(Bthci->EvIoCapResponse, r));
		u := array[10] of byte;
		u[0:] = params[0:6];
		bthci->put4(u, 6, 123456);
		pr.state = 6;
		return cat(out, event(Bthci->EvUserConfirmRequest, u));
	Bthci->IoCapabilityNegative =>
		if(len params < 7)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		pr := findpeer(c, bthci->bdaddr(params, 0));
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr != nil && pr.state == 5)
			out = cat(out, connfail(c, pr, Bthci->Sauthfail));
		return out;
	Bthci->UserConfirmReply =>
		if(len params < 6)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		pr := findpeer(c, bthci->bdaddr(params, 0));
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr != nil && pr.state == 6){
			sp := array[7] of byte;
			sp[0] = byte Bthci->Sok;
			sp[1:] = params[0:6];
			out = cat(out, event(Bthci->EvSimplePairingComplete, sp));
			out = cat(out, paired(c, pr, Bthci->LKunauthenticated));
		}
		return out;
	Bthci->UserConfirmNegative =>
		if(len params < 6)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		pr := findpeer(c, bthci->bdaddr(params, 0));
		out := complete(c, op, Bthci->Sok, params[0:6]);
		if(pr != nil && pr.state == 6){
			sp := array[7] of byte;
			sp[0] = byte Bthci->Sauthfail;
			sp[1:] = params[0:6];
			out = cat(out, event(Bthci->EvSimplePairingComplete, sp));
			out = cat(out, connfail(c, pr, Bthci->Sauthfail));
		}
		return out;
	Bthci->WriteSimplePairingMode =>
		return complete(c, op, Bthci->Sok, nil);
	Bthci->Disconnect =>
		if(len params < 3)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		# the reasons a host may give (Core 5, Vol 4 Part E, 7.1.6);
		# a real controller refuses the rest, so this one does too
		case int params[2] {
		16r05 or 16r13 or 16r14 or 16r15 or 16r1a or 16r29 or 16r3b => ;
		* =>	return cmdstatus(c, op, Bthci->Sinvalidparams);
		}
		h := bthci->get2(params, 0) & 16rfff;
		pr := findhandle(c, h);
		if(pr == nil)
			return cmdstatus(c, op, Bthci->Sunknownconn);
		droppeer(c, pr);
		out := cmdstatus(c, op, Bthci->Sok);
		# what it had not yet acknowledged, it acknowledges now
		if(pr.acks > 0){
			a := array[5] of byte;
			a[0] = byte 1;
			bthci->put2(a, 1, h);
			bthci->put2(a, 3, pr.acks);
			pr.acks = 0;
			out = cat(out, event(Bthci->EvNumCompleted, a));
		}
		# Disconnection Complete: status, handle, reason -- which on the
		# side that asked is always "terminated by local host"
		d := array[4] of byte;
		d[0] = byte 0;
		bthci->put2(d, 1, h);
		d[3] = byte Bthci->Slocalterm;
		return cat(out, event(Bthci->EvDisconnComplete, d));
	Bthci->BcmDownloadMinidriver or Bthci->BcmWriteRam or Bthci->BcmLaunchRam
	or Bthci->BcmUpdateBaudrate =>
		return complete(c, op, Bthci->Sok, nil);
	Bthci->BcmWriteBdaddr =>
		if(len params < 6)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		c.addr = params[0:6];
		return complete(c, op, Bthci->Sok, nil);
	}
	return cmdstatus(c, op, Bthci->Sunknowncmd);
}

appendn(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: appendn(tl l, s);
}

lookup(c: ref Ctlr, addr: string): ref Found
{
	for(l := c.nearby; l != nil; l = tl l)
		if((hd l).addr == addr)
			return hd l;
	return nil;
}

sameb(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

authkind(c: ref Ctlr, addr: string): string
{
	for(l := c.auth; l != nil; l = tl l){
		(a, k) := hd l;
		if(a == addr)
			return k;
	}
	return nil;
}

storedkey(c: ref Ctlr, addr: string): array of byte
{
	for(l := c.keys; l != nil; l = tl l){
		(a, k) := hd l;
		if(a == addr)
			return k;
	}
	return nil;
}

# pairing succeeded: a new key, told to the host, and the connection goes on
paired(c: ref Ctlr, pr: ref Peer, ktype: int): array of byte
{
	k := array[16] of byte;
	for(i := 0; i < 16; i++)
		k[i] = byte (i * 17 + c.pairings + 1);
	c.pairings++;
	keep: list of (string, array of byte);
	for(l := c.keys; l != nil; l = tl l){
		(a, nil) := hd l;
		if(a != pr.addr)
			keep = hd l :: keep;
	}
	c.keys = (pr.addr, k) :: keep;
	n := array[23] of byte;
	a := bthci->parsebdaddr(pr.addr);
	if(a != nil)
		n[0:] = a;
	n[6:] = k;
	n[22] = byte ktype;
	pr.state = 7;
	c.pendconn = appendpeer(c.pendconn, pr);
	return event(Bthci->EvLinkKeyNotify, n);
}

# pairing failed: the connection completes with the reason
connfail(c: ref Ctlr, pr: ref Peer, status: int): array of byte
{
	droppeer(c, pr);
	d := array[11] of byte;
	d[0] = byte status;
	bthci->put2(d, 1, 0);
	a := bthci->parsebdaddr(pr.addr);
	if(a != nil)
		d[3:] = a;
	d[9] = byte 1;
	d[10] = byte 0;
	return event(Bthci->EvConnComplete, d);
}

appendpeer(l: list of ref Peer, p: ref Peer): list of ref Peer
{
	if(l == nil)
		return p :: nil;
	return hd l :: appendpeer(tl l, p);
}

findpeer(c: ref Ctlr, addr: string): ref Peer
{
	for(l := c.links; l != nil; l = tl l)
		if((hd l).addr == addr)
			return hd l;
	for(l = c.pendconn; l != nil; l = tl l)
		if((hd l).addr == addr)
			return hd l;
	return nil;
}

findhandle(c: ref Ctlr, h: int): ref Peer
{
	for(l := c.links; l != nil; l = tl l)
		if((hd l).handle == h)
			return hd l;
	return nil;
}

droppeer(c: ref Ctlr, p: ref Peer)
{
	keep: list of ref Peer;
	for(l := c.links; l != nil; l = tl l)
		if(hd l != p)
			keep = hd l :: keep;
	c.links = keep;
}

#
# ACL data from the host, for one of our peers: run it through the
# peer's L2CAP and do what the peer would -- answer, echo, record.
#
acl(c: ref Ctlr, p: ref Pkt): array of byte
{
	(h, nil) := bthci->aclheader(p);
	pr := findhandle(c, h);
	if(pr == nil || pr.l2 == nil)
		return array[0] of byte;
	pr.acks++;
	return peerevents(c, pr, pr.l2.recv(p));
}

peerevents(c: ref Ctlr, pr: ref Peer, evs: list of ref Ev): array of byte
{
	out := array[0] of byte;
	for(; evs != nil; evs = tl evs){
		pick e := hd evs {
		Send =>
			for(pl := l2cap->fragment(pr.handle, e.frame, Aclmtu); pl != nil; pl = tl pl)
				out = cat(out, bthci->frame(hd pl));
		Opened =>
			if(pr.calling && e.c.psm == pr.callpsm){
				pr.calling = 0;
				out = cat(out, peerevents(c, pr, pr.l2.send(e.c, array of byte pr.calltext)));
			}
		Data =>
			if(e.c.psm == Echopsm)
				out = cat(out, peerevents(c, pr, pr.l2.send(e.c, e.sdu)));
			else
				c.received = sys->sprint("recv %s 0x%4.4ux %s", pr.addr, e.c.psm, string e.sdu) :: c.received;
		* =>
			;
		}
	}
	return out;
}

Ctlr.call(c: self ref Ctlr, addr: string, psm: int, text: string): string
{
	if(lookup(c, addr) == nil)
		return "no such device nearby: " + addr;
	if(findpeer(c, addr) != nil)
		return "already connected: " + addr;
	pr := ref Peer(addr, 0, 2, nil, 1, psm, text, 0);
	c.pendconn = appendpeer(c.pendconn, pr);
	return nil;
}

#
# What happens with time: a withheld credit comes back, an inquiry
# finds one more device or finishes, a name request is answered, an
# LE scan hears one more advertisement, a connection completes, a
# peer that was asked to call does.
#
Ctlr.tick(c: self ref Ctlr): array of byte
{
	out := array[0] of byte;
	if(c.owed){
		c.owed = 0;
		p := array[3] of byte;
		p[0] = byte 1;
		bthci->put2(p, 1, 0);
		out = cat(out, event(Bthci->EvCmdComplete, p));
	}
	if(c.inquiring != nil){
		f := hd c.inquiring;
		c.inquiring = tl c.inquiring;
		# Inquiry Result with RSSI, one device: n, addr, psrm, reserved, class 3, clock 2, rssi
		p := array[15] of byte;
		p[0] = byte 1;
		a := bthci->parsebdaddr(f.addr);
		if(a == nil)
			a = array[6] of { * => byte 0 };
		p[1:] = a;
		p[7] = byte 1;
		p[8] = byte 0;
		p[9] = byte f.class;
		p[10] = byte (f.class >> 8);
		p[11] = byte (f.class >> 16);
		p[12] = byte 0;
		p[13] = byte 0;
		p[14] = byte f.rssi;
		out = cat(out, event(Bthci->EvInquiryResultRssi, p));
	}else if(c.inquirydone){
		c.inquirydone = 0;
		out = cat(out, event(Bthci->EvInquiryComplete, array[] of { byte Bthci->Sok }));
	}
	if(c.naming != nil){
		# Remote Name Request Complete: status, addr, name[248]; a
		# device with no name to give is a page timeout, as one that
		# is out of range would be
		addr := hd c.naming;
		c.naming = tl c.naming;
		p := array[255] of { * => byte 0 };
		f := lookup(c, addr);
		if(f == nil || f.name == nil)
			p[0] = byte Bthci->Spagetimeout;
		else{
			nm := array of byte f.name;
			if(len nm > 247)
				nm = nm[0:247];
			p[7:] = nm;
		}
		a := bthci->parsebdaddr(addr);
		if(a != nil)
			p[1:] = a;
		out = cat(out, event(Bthci->EvRemoteName, p));
	}
	if(c.pendconn != nil){
		pr := hd c.pendconn;
		c.pendconn = tl c.pendconn;
		a := bthci->parsebdaddr(pr.addr);
		if(a == nil)
			a = array[6] of { * => byte 0 };
		if(pr.state == 2){
			# an incoming call: Connection Request (addr, class, ACL); the
			# host must Accept, which moves the peer to state 0 below
			d := array[10] of byte;
			d[0:] = a;
			f := lookup(c, pr.addr);
			cls := 0;
			if(f != nil)
				cls = f.class;
			d[6] = byte cls;
			d[7] = byte (cls >> 8);
			d[8] = byte (cls >> 16);
			d[9] = byte 1;
			c.links = pr :: c.links;
			out = cat(out, event(Bthci->EvConnRequest, d));
		}else if(pr.handle != 0 && pr.state == 0 && authkind(c, pr.addr) != nil && pr.l2 == nil){
			# this device pairs before it connects: Link Key Request
			# first; the host's answer decides what follows
			pr.state = 3;
			c.links = pr :: c.links;
			out = cat(out, event(Bthci->EvLinkKeyRequest, a));
		}else{
			# Connection Complete: status, handle, addr, link type ACL, no encryption
			d := array[11] of byte;
			if(pr.handle == 0)
				d[0] = byte Bthci->Spagetimeout;
			else
				d[0] = byte Bthci->Sok;
			bthci->put2(d, 1, pr.handle);
			d[3:] = a;
			d[9] = byte 1;
			d[10] = byte 0;
			if(pr.handle != 0){
				pr.state = 1;
				pr.l2 = Link.new(pr.handle);
				pr.l2.accept = Echopsm :: nil;
				droppeer(c, pr);
				c.links = pr :: c.links;
			}
			out = cat(out, event(Bthci->EvConnComplete, d));
			if(pr.state == 1 && pr.calling){
				(nil, evs) := pr.l2.connect(pr.callpsm);
				out = cat(out, peerevents(c, pr, evs));
			}
		}
	}
	# Number Of Completed Packets for what the host sent us
	for(pl := c.links; pl != nil; pl = tl pl){
		pr := hd pl;
		if(pr.acks > 0){
			d := array[5] of byte;
			d[0] = byte 1;
			bthci->put2(d, 1, pr.handle);
			bthci->put2(d, 3, pr.acks);
			pr.acks = 0;
			out = cat(out, event(Bthci->EvNumCompleted, d));
		}
	}
	if(c.lescanning && c.leadv != nil){
		# LE Advertising Report, one device: subevent, n, type, addrtype, addr, dlen, data, rssi
		f := hd c.leadv;
		c.leadv = tl c.leadv;
		data := array[0] of byte;
		if(f.name != nil){
			nm := array of byte f.name;
			data = array[2 + len nm] of byte;
			data[0] = byte (1 + len nm);
			data[1] = byte 16r09;
			data[2:] = nm;
		}
		p := array[11 + len data + 1] of byte;
		p[0] = byte Bthci->LeAdvReport;
		p[1] = byte 1;
		p[2] = byte 0;			# ADV_IND
		p[3] = byte 0;			# public
		a := bthci->parsebdaddr(f.addr);
		if(a == nil)
			a = array[6] of { * => byte 0 };
		p[4:] = a;
		p[10] = byte len data;
		p[11:] = data;
		p[11 + len data] = byte f.rssi;
		out = cat(out, event(Bthci->EvLeMeta, p));
	}
	return out;
}
