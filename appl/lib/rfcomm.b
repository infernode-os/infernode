implement Rfcomm;

#
# RFCOMM as a state machine; see rfcomm.m. Frame layout, TS 07.10 5.2:
#
#	address   EA=1 | C/R<<1 | DLCI<<2
#	control   SABM 2f, UA 63, DM 0f, DISC 43, UIH ef; P/F is bit 4
#	length    EA form, one byte under 128 else two, little-endian
#	[credits] one byte, on a UIH with P/F set, in credit-based flow control
#	data
#	FCS       over address and control, plus length for all but UIH
#
# C/R follows TS 07.10 5.2.1.2: the initiator's commands and the
# responder's responses carry 1, the responder's commands and the
# initiator's responses 0. UIH is always in the command form.
#

include "sys.m";
	sys: Sys;
include "bthci.m";
	bthci: Bthci;
include "rfcomm.m";

# control field values, with and without P/F
SABM: con 16r2f;
UA: con 16r63;
DM: con 16r0f;
DISC: con 16r43;
UIH: con 16ref;
PF: con 16r10;

# multiplexer control message types (the type field, before the shift)
Tpn: con 16r20;
Ttest: con 16r08;
Tfcon: con 16r28;
Tfcoff: con 16r18;
Tmsc: con 16r38;
Tnsc: con 16r04;
Trpn: con 16r24;
Trls: con 16r14;

# PN's convergence layer field: credit-based flow control, request and response
CLcfcreq: con 16rf;
CLcfcrsp: con 16re;

# MSC's V.24 signals
Vea: con 16r01;
Vfc: con 16r02;
Vrtc: con 16r04;
Vrtr: con 16r08;
Vic: con 16r40;
Vdv: con 16r80;

crctab: array of byte;

init(b: Bthci)
{
	sys = load Sys Sys->PATH;
	bthci = b;
	# the TS 07.10 FCS: CRC-8 with the reflected polynomial 16re0
	crctab = array[256] of byte;
	for(i := 0; i < 256; i++){
		c := i;
		for(k := 0; k < 8; k++)
			if(c & 1)
				c = (c >> 1) ^ 16re0;
			else
				c >>= 1;
		crctab[i] = byte c;
	}
}

fcs(a: array of byte, n: int): byte
{
	f := 16rff;
	for(i := 0; i < n; i++)
		f = int crctab[f ^ int a[i]];
	return byte (16rff - f);
}

fcsok(a: array of byte, n: int, got: byte): int
{
	f := 16rff;
	for(i := 0; i < n; i++)
		f = int crctab[f ^ int a[i]];
	return crctab[f ^ int got] == byte 16rcf;
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

Mux.new(initiator: int, mtu: int): ref Mux
{
	if(mtu <= 0)
		mtu = 672;
	return ref Mux(initiator, 0, 0, nil, nil, nil, mtu);
}

Mux.find(m: self ref Mux, dlci: int): ref Dlc
{
	for(l := m.dlcs; l != nil; l = tl l)
		if((hd l).dlci == dlci)
			return hd l;
	return nil;
}

Mux.bychannel(m: self ref Mux, channel: int): ref Dlc
{
	for(l := m.dlcs; l != nil; l = tl l)
		if((hd l).channel == channel)
			return hd l;
	return nil;
}

# the address byte for a command (cmd=1) or response from our side
addr(m: ref Mux, dlci: int, cmd: int): byte
{
	cr := m.initiator;
	if(!cmd)
		cr = !m.initiator;
	return byte (1 | (cr << 1) | (dlci << 2));
}

# a frame with no data: SABM, UA, DM, DISC
ctlframe(m: ref Mux, dlci: int, ctl: int, cmd: int): ref Ev
{
	f := array[4] of byte;
	f[0] = addr(m, dlci, cmd);
	f[1] = byte (ctl | PF);
	f[2] = byte 1;		# length 0, EA
	f[3] = fcs(f, 3);
	return ref Ev.Send(f);
}

# a UIH frame, with a credit byte when credits >= 0
uih(m: ref Mux, dlci: int, credits: int, data: array of byte): ref Ev
{
	n := len data;
	hl := 3;
	if(n >= 128)
		hl = 4;
	if(credits >= 0)
		hl++;
	f := array[hl + n + 1] of byte;
	f[0] = addr(m, dlci, 1);
	i := 2;
	if(credits >= 0)
		f[1] = byte (UIH | PF);
	else
		f[1] = byte UIH;
	if(n < 128)
		f[i++] = byte ((n << 1) | 1);
	else{
		f[i++] = byte ((n & 16r7f) << 1);
		f[i++] = byte (n >> 7);
	}
	if(credits >= 0)
		f[i++] = byte credits;
	f[i:] = data;
	f[hl + n] = fcs(f, 2);
	return ref Ev.Send(f);
}

# a multiplexer control message on DLCI 0
mcc(m: ref Mux, t: int, cmd: int, v: array of byte): ref Ev
{
	h := array[2] of byte;
	h[0] = byte ((t << 2) | (cmd << 1) | 1);
	h[1] = byte ((len v << 1) | 1);
	return uih(m, 0, -1, cat(h, v));
}

# our DLCI for the peer's server channel: the direction bit is the
# responder's, TS 07.10 5.6 -- so ours is 0 if we opened the session
ourdlci(m: ref Mux, channel: int): int
{
	return (channel << 1) | !m.initiator;
}

pnbody(dlci: int, cl: int, framesize: int, credits: int): array of byte
{
	v := array[8] of { * => byte 0 };
	v[0] = byte dlci;
	v[1] = byte (cl << 4);
	v[2] = byte 7;			# priority: TS 07.10's default for the lowest DLCIs
	v[3] = byte 0;			# T1, unused with RFCOMM
	v[4] = byte framesize;
	v[5] = byte (framesize >> 8);
	v[6] = byte 0;			# N2, unused
	v[7] = byte credits;
	return v;
}

Mux.start(m: self ref Mux): list of ref Ev
{
	if(m.up || m.starting)
		return nil;
	m.starting = 1;
	return ctlframe(m, 0, SABM, 1) :: nil;
}

Mux.connect(m: self ref Mux, channel: int): (ref Dlc, list of ref Ev)
{
	if(channel < 1 || channel > 30)
		return (nil, nil);
	dlci := ourdlci(m, channel);
	if(m.find(dlci) != nil)
		return (nil, nil);
	d := ref Dlc(dlci, channel, Waitpn, Defframe, 0, Initcredits, 1, 0, 0, nil);
	m.dlcs = d :: m.dlcs;
	if(!m.up){
		m.pending = d :: m.pending;
		return (d, m.start());
	}
	return (d, pn(m, d));
}

# our PN command for a DLC: ask for credit-based flow control, offer
# the frame size the L2CAP channel allows, grant the initial credits
pn(m: ref Mux, d: ref Dlc): list of ref Ev
{
	fs := m.mtu - 6;
	if(fs > Maxframe)
		fs = Maxframe;
	d.framesize = fs;
	d.state = Waitpn;
	return mcc(m, Tpn, 1, pnbody(d.dlci, CLcfcreq, fs, Initcredits)) :: nil;
}

Mux.recv(m: self ref Mux, sdu: array of byte): list of ref Ev
{
	if(len sdu < 4)
		return nil;
	dlci := int sdu[0] >> 2;
	ctl := int sdu[1] & ~PF;
	pf := (int sdu[1] & PF) != 0;
	i := 2;
	n := int sdu[i] >> 1;
	if((int sdu[i] & 1) == 0){
		if(len sdu < 5)
			return nil;
		n |= int sdu[i+1] << 7;
		i++;
	}
	i++;
	hl := i;
	if(ctl == UIH){
		if(!fcsok(sdu, 2, sdu[len sdu - 1]))
			return nil;
	}else if(!fcsok(sdu, hl, sdu[len sdu - 1]))
		return nil;
	credits := -1;
	if(ctl == UIH && pf && dlci != 0){
		if(i >= len sdu - 1)
			return nil;
		credits = int sdu[i++];
	}
	if(i + n > len sdu - 1)
		return nil;
	data := sdu[i:i+n];

	case ctl {
	SABM =>
		return sabm(m, dlci);
	UA =>
		return ua(m, dlci);
	DM =>
		return dm(m, dlci);
	DISC =>
		return disc(m, dlci);
	UIH =>
		if(dlci == 0)
			return control(m, data);
		d := m.find(dlci);
		if(d == nil)
			return ctlframe(m, dlci, DM, 0) :: nil;
		evs: list of ref Ev;
		if(credits > 0){
			d.txcredits += credits;
			evs = flush(m, d);
		}
		if(len data > 0){
			if(d.rxcredits > 0)
				d.rxcredits--;
			evs = appendev(evs, ref Ev.Data(d, data));
		}
		return evs;
	}
	return nil;
}

sabm(m: ref Mux, dlci: int): list of ref Ev
{
	if(dlci == 0){
		# the peer brings the multiplexer up; we are the responder
		m.up = 1;
		m.starting = 0;
		return ctlframe(m, 0, UA, 0) :: nil;
	}
	if(!m.up)
		return ctlframe(m, dlci, DM, 0) :: nil;
	channel := dlci >> 1;
	d := m.find(dlci);
	if(d == nil){
		if(!accepts(m, channel))
			return ctlframe(m, dlci, DM, 0) :: nil;
		# no PN first: TS 07.10 defaults, credits as the spec says (RFCOMM 6.5.2)
		d = ref Dlc(dlci, channel, Waitua, Defframe, 0, Initcredits, 0, 0, 0, nil);
		m.dlcs = d :: m.dlcs;
	}
	if(d.initiator)
		return ctlframe(m, dlci, DM, 0) :: nil;	# a collision on our own DLCI; refuse
	d.state = Open;
	# UA, then our MSC command: the port is open at our end
	evs := ctlframe(m, dlci, UA, 0) :: mcc(m, Tmsc, 1, mscbody(d.dlci)) :: nil;
	return appendev(appendev(evs, ref Ev.Incoming(d)), ref Ev.Opened(d));
}

accepts(m: ref Mux, channel: int): int
{
	for(l := m.accept; l != nil; l = tl l)
		if(hd l == channel)
			return 1;
	return 0;
}

ua(m: ref Mux, dlci: int): list of ref Ev
{
	if(dlci == 0){
		if(m.starting){
			m.starting = 0;
			m.up = 1;
			# the connects that waited for this
			evs: list of ref Ev;
			for(l := m.pending; l != nil; l = tl l)
				evs = appendevs(evs, pn(m, hd l));
			m.pending = nil;
			return evs;
		}
		if(m.dlcs == nil && !m.up)
			return ref Ev.Muxdown("closed") :: nil;	# our DISC on DLCI 0 was answered
		return nil;
	}
	d := m.find(dlci);
	if(d == nil)
		return nil;
	case d.state {
	Waitua =>
		d.state = Open;
		return mcc(m, Tmsc, 1, mscbody(d.dlci)) :: ref Ev.Opened(d) :: nil;
	Waitdisc =>
		drop(m, d);
		return ref Ev.Closed(d, "closed") :: nil;
	}
	return nil;
}

dm(m: ref Mux, dlci: int): list of ref Ev
{
	if(dlci == 0){
		m.starting = 0;
		evs: list of ref Ev;
		for(l := m.dlcs; l != nil; l = tl l)
			evs = appendev(evs, ref Ev.Closed(hd l, "refused"));
		m.dlcs = nil;
		m.pending = nil;
		return appendev(evs, ref Ev.Muxdown("refused"));
	}
	d := m.find(dlci);
	if(d == nil)
		return nil;
	drop(m, d);
	return ref Ev.Closed(d, "refused") :: nil;
}

disc(m: ref Mux, dlci: int): list of ref Ev
{
	if(dlci == 0){
		evs := ctlframe(m, 0, UA, 0) :: nil;
		for(l := m.dlcs; l != nil; l = tl l)
			evs = appendev(evs, ref Ev.Closed(hd l, "hangup"));
		m.dlcs = nil;
		m.pending = nil;
		m.up = 0;
		return appendev(evs, ref Ev.Muxdown("hangup"));
	}
	d := m.find(dlci);
	if(d == nil)
		return ctlframe(m, dlci, DM, 0) :: nil;
	drop(m, d);
	return ctlframe(m, dlci, UA, 0) :: ref Ev.Closed(d, "hangup") :: nil;
}

drop(m: ref Mux, d: ref Dlc)
{
	keep: list of ref Dlc;
	for(l := m.dlcs; l != nil; l = tl l)
		if(hd l != d)
			keep = hd l :: keep;
	m.dlcs = keep;
}

mscbody(dlci: int): array of byte
{
	v := array[2] of byte;
	v[0] = byte ((dlci << 2) | 3);
	v[1] = byte (Vea | Vrtc | Vrtr | Vdv);
	return v;
}

# a multiplexer control message arrived on DLCI 0
control(m: ref Mux, data: array of byte): list of ref Ev
{
	if(len data < 2)
		return nil;
	t := int data[0] >> 2;
	cmd := (int data[0] >> 1) & 1;
	n := int data[1] >> 1;
	i := 2;
	if((int data[1] & 1) == 0){
		if(len data < 3)
			return nil;
		n |= int data[2] << 7;
		i = 3;
	}
	if(i + n > len data)
		return nil;
	v := data[i:i+n];
	case t {
	Tpn =>
		if(n < 8)
			return nil;
		dlci := int v[0] & 16r3f;
		cl := int v[1] >> 4;
		fs := int v[4] | (int v[5] << 8);
		k := int v[7] & 7;
		d := m.find(dlci);
		if(cmd){
			# the peer proposes; we answer with what we will do. A frame
			# size we cannot take is answered with ours, the smaller.
			if(d == nil){
				if(!accepts(m, dlci >> 1))
					return ctlframe(m, dlci, DM, 0) :: nil;
				d = ref Dlc(dlci, dlci >> 1, Waitua, Defframe, 0, Initcredits, 0, 0, 0, nil);
				m.dlcs = d :: m.dlcs;
			}
			ours := m.mtu - 6;
			if(ours > Maxframe)
				ours = Maxframe;
			if(fs > 0 && fs < ours)
				ours = fs;
			d.framesize = ours;
			rcl := 0;
			if(cl == CLcfcreq){
				rcl = CLcfcrsp;
				d.txcredits = k;
			}
			d.rxcredits = Initcredits;
			return mcc(m, Tpn, 0, pnbody(dlci, rcl, ours, Initcredits)) :: nil;
		}
		# the peer's answer to our proposal
		if(d == nil || d.state != Waitpn)
			return nil;
		if(fs > 0 && fs < d.framesize)
			d.framesize = fs;
		if(cl == CLcfcrsp)
			d.txcredits = k;
		d.state = Waitua;
		return ctlframe(m, d.dlci, SABM, 1) :: nil;
	Tmsc =>
		if(n < 2)
			return nil;
		dlci := int v[0] >> 2;
		d := m.find(dlci);
		if(cmd){
			evs := mcc(m, Tmsc, 0, v) :: nil;
			if(d != nil)
				d.peermsc = 1;
			return evs;
		}
		if(d != nil)
			d.msc = 1;
		return nil;
	Ttest =>
		if(cmd)
			return mcc(m, Ttest, 0, v) :: nil;
		return nil;
	Tfcon or Tfcoff or Trpn or Trls =>
		# acknowledged, not acted on: credits do the flow control, and
		# the port settings of a serial port that is bytes over radio
		# mean nothing here
		if(cmd)
			return mcc(m, t, 0, v) :: nil;
		return nil;
	}
	if(cmd){
		# not supported: say so, with the type we did not understand
		return mcc(m, Tnsc, 0, array[] of { data[0] }) :: nil;
	}
	return nil;
}

# send what credits allow; the rest waits on the Dlc for more
Mux.send(m: self ref Mux, d: ref Dlc, data: array of byte): list of ref Ev
{
	if(d.state != Open)
		return nil;
	d.txq = cat(d.txq, data);
	return flush(m, d);
}

flush(m: ref Mux, d: ref Dlc): list of ref Ev
{
	evs: list of ref Ev;
	while(len d.txq > 0 && d.txcredits > 0){
		n := len d.txq;
		if(n > d.framesize)
			n = d.framesize;
		# a credit byte rides along when the peer is owed some
		grant := -1;
		if(d.rxcredits < Initcredits){
			grant = Initcredits - d.rxcredits;
			d.rxcredits = Initcredits;
		}
		evs = appendev(evs, uih(m, d.dlci, grant, d.txq[0:n]));
		d.txq = d.txq[n:];
		d.txcredits--;
	}
	return evs;
}

# the reader has taken what arrived: give the peer its credits back,
# in an empty frame if nothing is waiting to carry them
Mux.consumed(m: self ref Mux, d: ref Dlc): list of ref Ev
{
	if(d.state != Open || d.rxcredits >= Initcredits)
		return nil;
	if(len d.txq > 0 && d.txcredits > 0)
		return flush(m, d);
	grant := Initcredits - d.rxcredits;
	d.rxcredits = Initcredits;
	return uih(m, d.dlci, grant, array[0] of byte) :: nil;
}

Mux.disconnect(m: self ref Mux, d: ref Dlc): list of ref Ev
{
	case d.state {
	Open or Waitua =>
		d.state = Waitdisc;
		return ctlframe(m, d.dlci, DISC, 1) :: nil;
	Waitpn =>
		drop(m, d);
		return ref Ev.Closed(d, "closed") :: nil;
	}
	return nil;
}

Mux.shutdown(m: self ref Mux): list of ref Ev
{
	if(!m.up)
		return nil;
	m.up = 0;
	m.dlcs = nil;
	m.pending = nil;
	return ctlframe(m, 0, DISC, 1) :: nil;
}

appendev(l: list of ref Ev, e: ref Ev): list of ref Ev
{
	if(l == nil)
		return e :: nil;
	return hd l :: appendev(tl l, e);
}

appendevs(l: list of ref Ev, more: list of ref Ev): list of ref Ev
{
	for(; more != nil; more = tl more)
		l = appendev(l, hd more);
	return l;
}
