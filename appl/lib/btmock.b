implement Btmock;

include "sys.m";
	sys: Sys;
include "bthci.m";
	bthci: Bthci;
	Pkt, Found, Deframer: import bthci;
include "l2cap.m";
	l2cap: L2cap;
	Link, Chan, Ev: import l2cap;
include "sdp.m";
	sdp: Sdp;
	Server: import sdp;
include "rfcomm.m";
	rfcomm: Rfcomm;
	Mux: import rfcomm;
include "keyring.m";
include "att.m";
include "smp.m";
	smp: Smp;
include "btmock.m";

peersdp: ref Server;	# what every mock peer offers: a serial port on Echochan

init(b: Bthci, l: L2cap)
{
	sys = load Sys Sys->PATH;
	bthci = b;
	l2cap = l;
	sdp = load Sdp Sdp->PATH;
	sdp->init(b);
	rfcomm = load Rfcomm Rfcomm->PATH;
	rfcomm->init(b);
	smp = load Smp Smp->PATH;
	smp->init(b, load Keyring Keyring->PATH);
	peersdp = Server.new();
	peersdp.add(sdp->spprecord(0, Echochan, "Echo Port"));
}

Aclmtu: con 1021;	# what Read_Buffer_Size promises

Ctlr.new(addr: string): ref Ctlr
{
	a := bthci->parsebdaddr(addr);
	if(a == nil)
		a = array[6] of { * => byte 0 };
	return ref Ctlr(a, "btmock", 8, 8, 15, 0, 0, nil, 0, 0, nil, 0, nil, 0, 0, 0, nil, nil, Deframer.new(), nil, nil, 1, nil, nil, nil, nil, 0);
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
	Bthci->SetEventMask =>
		# A controller emits only what the mask lets it. Bit 61 is the
		# LE Meta Event, and this one obeys it: on the board an LE scan
		# with that bit clear succeeded and then reported nothing,
		# while a host beside it heard a dozen advertisers, and nothing
		# here could have shown that while the mask was ignored.
		if(len params < 8)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		c.lemeta = (int params[7] & 16r20) != 0;
		return complete(c, op, Bthci->Sok, nil);
	Bthci->WriteInquiryMode or Bthci->InquiryCancel
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
		# an LE-only device does not answer an inquiry
		rl: list of ref Found;
		for(nl := c.nearby; nl != nil; nl = tl nl)
			if(authkind(c, (hd nl).addr) != "le" && authkind(c, (hd nl).addr) != "lereport")
				rl = hd nl :: rl;
		c.inquiring = nil;
		for(; rl != nil; rl = tl rl)
			c.inquiring = hd rl :: c.inquiring;
		c.inquirydone = 1;
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->LeReadBufferSize =>
		r := array[3] of byte;
		bthci->put2(r, 0, 27);
		r[2] = byte 4;
		return complete(c, op, Bthci->Sok, r);
	Bthci->LeCreateConnection =>
		if(len params < 25)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		addr := bthci->bdaddr(params, 6);
		if(findpeer(c, addr) != nil)
			return cmdstatus(c, op, Bthci->Sconnexists);
		kind := authkind(c, addr);
		pr := ref Peer(addr, 0, 0, nil, 0, 0, nil, 0, nil, nil, 0, 1, hidtable(kind == "lereport"), 0, nil, nil, nil, nil, nil, nil, 0, 0, nil);
		if(lookup(c, addr) != nil && (kind == "le" || kind == "lereport"))
			pr.handle = c.nexthandle++;
		c.pendconn = appendpeer(c.pendconn, pr);
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->LeStartEncryption =>
		if(len params < 28)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		h := bthci->get2(params, 0) & 16rfff;
		pr := findhandle(c, h);
		if(pr == nil || !pr.le)
			return cmdstatus(c, op, Bthci->Sunknownconn);
		key := params[12:28];
		# the STK of a pairing in progress, or the LTK this device gave out
		ok := 0;
		if(pr.sstate == 3 && pr.stk != nil && same(key, pr.stk))
			ok = 1;
		else if(same(key, ltkfor(c, pr.addr)) && bthci->get2(params, 10) == 16r1234)
			ok = 1;
		if(ok)
			pr.penc = 1;
		else
			pr.penc = 1 + Bthci->Snokey;
		return cmdstatus(c, op, Bthci->Sok);
	Bthci->CreateConnection =>
		if(len params < 13)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		addr := bthci->bdaddr(params, 0);
		pr := ref Peer(addr, 0, 0, nil, 0, 0, nil, 0, nil, nil, 0, 0, nil, 0, nil, nil, nil, nil, nil, nil, 0, 0, nil);
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
	Bthci->AuthRequested =>
		# a link is authenticated on request; a real controller would
		# pair first if there were no key, which the devices marked
		# pin= and ssp do at connection time instead
		if(len params < 2)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		h := bthci->get2(params, 0) & 16rfff;
		if(findhandle(c, h) == nil)
			return cmdstatus(c, op, Bthci->Sunknownconn);
		d := array[3] of byte;
		d[0] = byte 0;
		bthci->put2(d, 1, h);
		return cat(cmdstatus(c, op, Bthci->Sok), event(Bthci->EvAuthComplete, d));
	Bthci->SetConnEncryption =>
		if(len params < 3)
			return cmdstatus(c, op, Bthci->Sinvalidparams);
		h := bthci->get2(params, 0) & 16rfff;
		if(findhandle(c, h) == nil)
			return cmdstatus(c, op, Bthci->Sunknownconn);
		d := array[4] of byte;
		d[0] = byte 0;
		bthci->put2(d, 1, h);
		d[3] = params[2];
		return cat(cmdstatus(c, op, Bthci->Sok), event(Bthci->EvEncryptChange, d));
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
	Bthci->WriteLeHostSupported =>
		if(len params < 1)
			return complete(c, op, Bthci->Sinvalidparams, nil);
		c.lehost = int params[0];
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
			if(e.c.psm == L2cap->Psmrfcomm){
				# one multiplexer per link: ours if we opened the
				# channel, the host's otherwise; it echoes on Echochan
				pr.rfch = e.c;
				pr.rf = Mux.new(e.c.initiator, e.c.mtu);
				pr.rf.accept = Echochan :: nil;
				if(e.c.initiator && pr.calling && pr.callchan != 0){
					pr.calling = 0;
					(nil, revs) := pr.rf.connect(pr.callchan);
					out = cat(out, rfevents(c, pr, revs));
				}
			}else if(pr.calling && e.c.psm == pr.callpsm){
				pr.calling = 0;
				out = cat(out, peerevents(c, pr, pr.l2.send(e.c, array of byte pr.calltext)));
			}
		Data =>
			if(e.c.psm == Echopsm || (e.c.le && e.c.psm == Leechopsm))
				out = cat(out, peerevents(c, pr, pr.l2.send(e.c, e.sdu)));
			else if(e.c.psm == L2cap->Psmsdp)
				out = cat(out, peerevents(c, pr, pr.l2.send(e.c, peersdp.request(e.sdu, e.c.mtu))));
			else if(e.c == pr.rfch){
				if(pr.rf != nil)
					out = cat(out, rfevents(c, pr, pr.rf.recv(e.sdu)));
			}else
				c.received = sys->sprint("recv %s 0x%4.4ux %s", pr.addr, e.c.psm, string e.sdu) :: c.received;
		Fixed =>
			case e.cid {
			L2cap->Cidsmp =>
				out = cat(out, peerevents(c, pr, smpresponder(c, pr, e.sdu)));
			L2cap->Cidatt =>
				rsp := gattserve(pr, e.sdu);
				if(rsp != nil)
					out = cat(out, peerevents(c, pr, pr.l2.sendfixed(L2cap->Cidatt, rsp)));
			}
		Closed =>
			if(e.c == pr.rfch){
				pr.rfch = nil;
				pr.rf = nil;
			}
			# a peer that called us hangs its link up once its last
			# channel is gone, as a real one does: the link is the
			# maker's to end, and the host leaves a peer's alone
			if(pr.callpsm != 0 && pr.l2.chans == nil && pr.state == 1){
				droppeer(c, pr);
				d := array[4] of byte;
				d[0] = byte 0;
				bthci->put2(d, 1, pr.handle);
				d[3] = byte Bthci->Sremoteterm;
				out = cat(out, event(Bthci->EvDisconnComplete, d));
			}
		* =>
			;
		}
	}
	return out;
}

# what the peer's RFCOMM asked for: frames onto its channel, the echo
# on Echochan, the text of a call once its channel opens, a record of
# what came back on it
rfevents(c: ref Ctlr, pr: ref Peer, evs: list of ref Rfcomm->Ev): array of byte
{
	out := array[0] of byte;
	for(; evs != nil; evs = tl evs){
		pick e := hd evs {
		Send =>
			if(pr.rfch != nil)
				out = cat(out, peerevents(c, pr, pr.l2.send(pr.rfch, e.sdu)));
		Opened =>
			if(e.d.initiator && e.d.channel == pr.callchan)
				out = cat(out, rfevents(c, pr, pr.rf.send(e.d, array of byte pr.calltext)));
		Data =>
			if(e.d.channel == Echochan && !e.d.initiator)
				out = cat(out, rfevents(c, pr, pr.rf.send(e.d, e.data)));
			else
				c.received = sys->sprint("recv %s rfcomm%d %s", pr.addr, e.d.channel, string e.data) :: c.received;
			out = cat(out, rfevents(c, pr, pr.rf.consumed(e.d)));
		Closed =>
			# a caller whose channel is gone hangs its link up
			if(pr.callchan != 0 && pr.rf != nil && pr.rf.dlcs == nil){
				out = cat(out, rfevents(c, pr, pr.rf.shutdown()));
				if(pr.rfch != nil)
					out = cat(out, peerevents(c, pr, pr.l2.disconnect(pr.rfch)));
			}
		Muxdown =>
			if(pr.rfch != nil && pr.rfch.state == L2cap->Open)
				out = cat(out, peerevents(c, pr, pr.l2.disconnect(pr.rfch)));
			pr.rf = nil;
		}
	}
	return out;
}

#
# The LE peripheral: a mouse. Legacy Just Works pairing as the
# responder, an LTK it gives out and remembers, and a GATT table with
# a HID service in boot protocol whose boot mouse report notifies
# when the host has subscribed and notify() has something to say.
#

zero16 := array[16] of { * => byte 0 };
mockltk := array[] of {
	byte 16r0f, byte 16r0e, byte 16r0d, byte 16r0c, byte 16r0b, byte 16r0a, byte 16r09, byte 16r08,
	byte 16r07, byte 16r06, byte 16r05, byte 16r04, byte 16r03, byte 16r02, byte 16r01, byte 16r00,
};

same(a, b: array of byte): int
{
	if(a == nil || b == nil || len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

ltkfor(c: ref Ctlr, addr: string): array of byte
{
	for(l := c.lekeys; l != nil; l = tl l){
		(a, k) := hd l;
		if(a == addr)
			return k;
	}
	return nil;
}

# the responder's half of smp(2)'s exchange, with the same functions
smpresponder(c: ref Ctlr, pr: ref Peer, pdu: array of byte): list of ref Ev
{
	if(len pdu < 1)
		return nil;
	code := int pdu[0];
	ia := c.addr;				# the host's address, as the mock knows it: ours is the controller's
	ra := bthci->parsebdaddr(pr.addr);
	case code {
	Smp->Cpairreq =>
		if(len pdu < 7)
			return nil;
		pr.preq = pdu[0:7];
		rsp := array[] of { byte Smp->Cpairrsp, byte Smp->IOnone, byte 0, byte Smp->Abonding, byte 16, byte 0, byte (Smp->Kenc | Smp->Kid) };
		pr.pres = rsp;
		pr.sstate = 1;
		return pr.l2.sendfixed(L2cap->Cidsmp, rsp);
	Smp->Cconfirm =>
		if(len pdu < 17 || pr.sstate != 1)
			return nil;
		pr.mconfirm = pdu[1:17];
		pr.srand = array[16] of byte;
		for(i := 0; i < 16; i++)
			pr.srand[i] = byte (16r40 + i);
		sconf := smp->c1(zero16, pr.srand, pr.preq, pr.pres, 0, ia, 1, ra);
		pr.sstate = 2;
		return pr.l2.sendfixed(L2cap->Cidsmp, withcode(Smp->Cconfirm, sconf));
	Smp->Crandom =>
		if(len pdu < 17 || pr.sstate != 2)
			return nil;
		pr.mrand = pdu[1:17];
		want := smp->c1(zero16, pr.mrand, pr.preq, pr.pres, 0, ia, 1, ra);
		if(!same(want, pr.mconfirm)){
			pr.sstate = 0;
			return pr.l2.sendfixed(L2cap->Cidsmp, array[] of { byte Smp->Cfailed, byte Smp->Fconfirmfailed });
		}
		pr.stk = smp->s1(zero16, pr.srand, pr.mrand);
		pr.sstate = 3;
		return pr.l2.sendfixed(L2cap->Cidsmp, withcode(Smp->Crandom, pr.srand));
	}
	return nil;
}

# encrypted with the STK: the keys, as the response promised
distribute(c: ref Ctlr, pr: ref Peer): array of byte
{
	pr.sstate = 4;
	c.lekeys = (pr.addr, mockltk) :: c.lekeys;
	out := peerevents(c, pr, pr.l2.sendfixed(L2cap->Cidsmp, withcode(Smp->Cencinfo, mockltk)));
	mid := array[11] of byte;
	mid[0] = byte Smp->Cmasterid;
	bthci->put2(mid, 1, 16r1234);
	for(i := 3; i < 11; i++)
		mid[i] = byte i;
	out = cat(out, peerevents(c, pr, pr.l2.sendfixed(L2cap->Cidsmp, mid)));
	irk := array[16] of { * => byte 16raa };
	out = cat(out, peerevents(c, pr, pr.l2.sendfixed(L2cap->Cidsmp, withcode(Smp->Cidinfo, irk))));
	ida := array[8] of byte;
	ida[0] = byte Smp->Cidaddr;
	ida[1] = byte 1;
	ida[2:] = bthci->parsebdaddr(pr.addr);
	return cat(out, peerevents(c, pr, pr.l2.sendfixed(L2cap->Cidsmp, ida)));
}

withcode(code: int, v: array of byte): array of byte
{
	r := array[1 + len v] of byte;
	r[0] = byte code;
	r[1:] = v;
	return r;
}

# a mouse's attribute table: GAP, then HID with protocol mode, the
# boot mouse input report with its CCCD, a report map, and a report
# with a Report Reference; then battery
# reportonly: no boot report, as a modern mouse; its input Report is
# id 26 with the layout of hid_test's "modern mouse" map
hidtable(reportonly: int): list of ref Attr
{
	l: list of ref Attr;
	l = ref Attr(1, Att->Uprimary, u16(16r1800)) :: l;
	l = ref Attr(2, Att->Ucharacteristic, chardecl(Att->Pread, 3, 16r2a00)) :: l;
	l = ref Attr(3, 16r2a00, array of byte "Mock Mouse") :: l;
	l = ref Attr(16r10, Att->Uprimary, u16(Att->Uhidservice)) :: l;
	l = ref Attr(16r11, Att->Ucharacteristic, chardecl(Att->Pread|Att->Pwritenorsp, 16r12, Att->Uprotocolmode)) :: l;
	l = ref Attr(16r12, Att->Uprotocolmode, array[] of { byte 1 }) :: l;
	if(!reportonly){
		l = ref Attr(16r13, Att->Ucharacteristic, chardecl(Att->Pread|Att->Pnotify, Hidreport, Att->Ubootmousein)) :: l;
		l = ref Attr(Hidreport, Att->Ubootmousein, array[] of { byte 0, byte 0, byte 0 }) :: l;
		l = ref Attr(Hidcccd, Att->Ucccd, u16(0)) :: l;
	}
	l = ref Attr(16r16, Att->Ucharacteristic, chardecl(Att->Pread, 16r17, Att->Ureportmap)) :: l;
	l = ref Attr(16r17, Att->Ureportmap, modernmap) :: l;
	l = ref Attr(16r18, Att->Ucharacteristic, chardecl(Att->Pread|Att->Pnotify, Reporth, Att->Ureport)) :: l;
	l = ref Attr(Reporth, Att->Ureport, array[] of { byte 0 }) :: l;
	l = ref Attr(Reportcccd, Att->Ucccd, u16(0)) :: l;
	l = ref Attr(16r1b, Att->Ureportref, array[] of { byte 26, byte 1 }) :: l;
	l = ref Attr(16r20, Att->Uprimary, u16(16r180f)) :: l;
	l = ref Attr(16r21, Att->Ucharacteristic, chardecl(Att->Pread, 16r22, 16r2a19)) :: l;
	l = ref Attr(16r22, 16r2a19, array[] of { byte 99 }) :: l;
	r: list of ref Attr;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

Reporth: con 16r19;
Reportcccd: con 16r1a;

# the report map of hid_test's "modern mouse": id 26, five buttons,
# 12-bit X and Y, a wheel byte
modernmap := array[] of {
	byte 16r05, byte 16r01, byte 16r09, byte 16r02, byte 16rA1, byte 16r01, byte 16r85, byte 16r1A,
	byte 16r09, byte 16r01, byte 16rA1, byte 16r00, byte 16r05, byte 16r09, byte 16r19, byte 16r01,
	byte 16r29, byte 16r05, byte 16r15, byte 16r00, byte 16r25, byte 16r01, byte 16r75, byte 16r01,
	byte 16r95, byte 16r05, byte 16r81, byte 16r02, byte 16r75, byte 16r03, byte 16r95, byte 16r01,
	byte 16r81, byte 16r01, byte 16r05, byte 16r01, byte 16r09, byte 16r30, byte 16r09, byte 16r31,
	byte 16r16, byte 16r01, byte 16rF8, byte 16r26, byte 16rFF, byte 16r07, byte 16r75, byte 16r0C,
	byte 16r95, byte 16r02, byte 16r81, byte 16r06, byte 16r09, byte 16r38, byte 16r15, byte 16r81,
	byte 16r25, byte 16r7F, byte 16r75, byte 16r08, byte 16r95, byte 16r01, byte 16r81, byte 16r06,
	byte 16rC0, byte 16rC0,
};

u16(v: int): array of byte
{
	a := array[2] of byte;
	bthci->put2(a, 0, v);
	return a;
}

chardecl(props, value, uuid: int): array of byte
{
	a := array[5] of byte;
	a[0] = byte props;
	bthci->put2(a, 1, value);
	bthci->put2(a, 3, uuid);
	return a;
}

# the value handle of the subscribed input report, 0 if none
cccdon(pr: ref Peer): int
{
	for(l := pr.attrs; l != nil; l = tl l){
		if((hd l).handle == Hidcccd && (int (hd l).value[0] & 1))
			return Hidreport;
		if((hd l).handle == Reportcccd && (int (hd l).value[0] & 1))
			return Reporth;
	}
	return 0;
}

groupend(tab: list of ref Attr, start: int): int
{
	end := 16rffff;
	for(; tab != nil; tab = tl tab)
		if((hd tab).uuid == Att->Uprimary && (hd tab).handle > start && (hd tab).handle - 1 < end)
			end = (hd tab).handle - 1;
	return end;
}

atterr(op, h, code: int): array of byte
{
	a := array[5] of byte;
	a[0] = byte Att->Oerror;
	a[1] = byte op;
	bthci->put2(a, 2, h);
	a[4] = byte code;
	return a;
}

# the GATT server, within the default MTU; reads and writes need the
# link encrypted, as a real HID device requires
gattserve(pr: ref Peer, req: array of byte): array of byte
{
	mtu := Att->Defmtu;
	if(len req < 1)
		return nil;
	op := int req[0];
	tab := pr.attrs;
	case op {
	Att->Omtureq =>
		a := array[3] of byte;
		a[0] = byte Att->Omtursp;
		bthci->put2(a, 1, 23);
		return a;
	Att->Oreadbygroupreq =>
		start := bthci->get2(req, 1);
		end := bthci->get2(req, 3);
		u := bthci->get2(req, 5);
		out := array[] of { byte Att->Oreadbygrouprsp, byte 6 };
		for(l := tab; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end || a.uuid != u)
				continue;
			if(len out + 6 > mtu)
				break;
			e := array[6] of byte;
			bthci->put2(e, 0, a.handle);
			bthci->put2(e, 2, groupend(tab, a.handle));
			e[4:] = a.value;
			out = cat(out, e);
		}
		if(len out == 2)
			return atterr(op, start, Att->Eattrnotfound);
		return out;
	Att->Oreadbytypereq =>
		start := bthci->get2(req, 1);
		end := bthci->get2(req, 3);
		u := bthci->get2(req, 5);
		out := array[] of { byte Att->Oreadbytypersp, byte 7 };
		for(l := tab; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end || a.uuid != u)
				continue;
			if(len out + 7 > mtu)
				break;
			e := array[7] of byte;
			bthci->put2(e, 0, a.handle);
			e[2:] = a.value;
			out = cat(out, e);
		}
		if(len out == 2)
			return atterr(op, start, Att->Eattrnotfound);
		return out;
	Att->Ofindinforeq =>
		start := bthci->get2(req, 1);
		end := bthci->get2(req, 3);
		out := array[] of { byte Att->Ofindinforsp, byte 1 };
		for(l := tab; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end)
				continue;
			if(len out + 4 > mtu)
				break;
			e := array[4] of byte;
			bthci->put2(e, 0, a.handle);
			bthci->put2(e, 2, a.uuid);
			out = cat(out, e);
		}
		if(len out == 2)
			return atterr(op, start, Att->Eattrnotfound);
		return out;
	Att->Oreadreq =>
		h := bthci->get2(req, 1);
		if(!pr.encrypted)
			return atterr(op, h, Att->Einsufencrypt);
		for(l := tab; l != nil; l = tl l)
			if((hd l).handle == h)
				return cat(array[] of { byte Att->Oreadrsp }, (hd l).value);
		return atterr(op, h, Att->Einvalidhandle);
	Att->Owritereq or Att->Owritecmd =>
		h := bthci->get2(req, 1);
		if(!pr.encrypted)
			return atterr(op, h, Att->Einsufencrypt);
		for(l := tab; l != nil; l = tl l)
			if((hd l).handle == h){
				(hd l).value = req[3:];
				if(op == Att->Owritecmd)
					return nil;
				return array[] of { byte Att->Owritersp };
			}
		return atterr(op, h, Att->Einvalidhandle);
	Att->Oconfirm =>
		return nil;
	}
	return atterr(op, 0, Att->Enotsupported);
}

Ctlr.notify(c: self ref Ctlr, addr: string, report: array of byte): string
{
	pr := findpeer(c, addr);
	if(pr == nil || !pr.le)
		return "not connected as an LE device: " + addr;
	pr.notifyq = appendb(pr.notifyq, report);
	return nil;
}

appendb(l: list of array of byte, b: array of byte): list of array of byte
{
	if(l == nil)
		return b :: nil;
	return hd l :: appendb(tl l, b);
}

Ctlr.call(c: self ref Ctlr, addr: string, psm: int, text: string): string
{
	if(lookup(c, addr) == nil)
		return "no such device nearby: " + addr;
	if(findpeer(c, addr) != nil)
		return "already connected: " + addr;
	pr := ref Peer(addr, 0, 2, nil, 1, psm, text, 0, nil, nil, 0, 0, nil, 0, nil, nil, nil, nil, nil, nil, 0, 0, nil);
	c.pendconn = appendpeer(c.pendconn, pr);
	return nil;
}

# a call on an RFCOMM channel: the peer opens PSM 3, brings the
# multiplexer up, opens the channel and sends the text
Ctlr.callrf(c: self ref Ctlr, addr: string, channel: int, text: string): string
{
	if(lookup(c, addr) == nil)
		return "no such device nearby: " + addr;
	if(findpeer(c, addr) != nil)
		return "already connected: " + addr;
	pr := ref Peer(addr, 0, 2, nil, 1, L2cap->Psmrfcomm, text, 0, nil, nil, channel, 0, nil, 0, nil, nil, nil, nil, nil, nil, 0, 0, nil);
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
		}else if(pr.handle != 0 && pr.state == 0 && !pr.le && authkind(c, pr.addr) != nil && pr.l2 == nil){
			# this device pairs before it connects: Link Key Request
			# first; the host's answer decides what follows
			pr.state = 3;
			c.links = pr :: c.links;
			out = cat(out, event(Bthci->EvLinkKeyRequest, a));
		}else if(pr.le){
			# LE Connection Complete: subevent, status, handle, role, peer type, peer, interval, latency, timeout, mca
			d := array[19] of { * => byte 0 };
			d[0] = byte Bthci->LeConnComplete;
			if(pr.handle == 0)
				d[1] = byte Bthci->Sconntimeout;
			bthci->put2(d, 2, pr.handle);
			d[4] = byte 0;			# we are the peripheral; the host is central
			d[5] = byte 1;			# random
			d[6:] = a;
			bthci->put2(d, 12, 16r18);
			bthci->put2(d, 16, 16r190);
			if(pr.handle != 0){
				pr.state = 1;
				pr.l2 = Link.new(pr.handle);
				pr.l2.accept = Leechopsm :: nil;
				droppeer(c, pr);
				c.links = pr :: c.links;
			}
			out = cat(out, event(Bthci->EvLeMeta, d));
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
				pr.l2.accept = Echopsm :: L2cap->Psmsdp :: L2cap->Psmrfcomm :: nil;
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
	# LE: encryption changes asked for, and boot reports to notify
	for(ll := c.links; ll != nil; ll = tl ll){
		pr := hd ll;
		if(!pr.le)
			continue;
		if(pr.penc != 0){
			st := pr.penc - 1;
			pr.penc = 0;
			d := array[4] of byte;
			d[0] = byte st;
			bthci->put2(d, 1, pr.handle);
			d[3] = byte (st == 0);
			out = cat(out, event(Bthci->EvEncryptChange, d));
			if(st == 0){
				pr.encrypted = 1;
				if(pr.l2 != nil)
					pr.l2.encrypted = 1;
				if(pr.sstate == 3)
					out = cat(out, distribute(c, pr));
			}
		}
		if(pr.encrypted && pr.notifyq != nil && cccdon(pr) != 0){
			for(; pr.notifyq != nil; pr.notifyq = tl pr.notifyq){
				n := array[3] of byte;
				n[0] = byte Att->Onotify;
				bthci->put2(n, 1, cccdon(pr));
				out = cat(out, peerevents(c, pr, pr.l2.sendfixed(L2cap->Cidatt, cat(n, hd pr.notifyq))));
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
	if(c.lescanning && c.lemeta && c.leadv != nil){
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
		if(authkind(c, f.addr) == "le" || authkind(c, f.addr) == "lereport")
			p[3] = byte 1;		# an LE device here has a random static address
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
