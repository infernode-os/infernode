implement Btmock;

include "sys.m";
	sys: Sys;
include "bthci.m";
	bthci: Bthci;
	Pkt, Found, Deframer: import bthci;
include "btmock.m";

init(b: Bthci)
{
	sys = load Sys Sys->PATH;
	bthci = b;
}

Ctlr.new(addr: string): ref Ctlr
{
	a := bthci->parsebdaddr(addr);
	if(a == nil)
		a = array[6] of { * => byte 0 };
	return ref Ctlr(a, "btmock", 8, 8, 15, 0, 0, nil, 0, 0, nil, 0, nil, Deframer.new());
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
	or Bthci->LeSetScanParameters or Bthci->LeSetScanEnable =>
		if(op == Bthci->InquiryCancel){
			c.inquiring = nil;
			c.inquirydone = 0;
		}
		return complete(c, op, Bthci->Sok, nil);
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

#
# What happens with time: a withheld credit comes back, and an
# inquiry finds one more device or finishes.
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
	return out;
}
