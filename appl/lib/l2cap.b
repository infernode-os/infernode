implement L2cap;

#
#	L2CAP basic mode. See l2cap.m; docs/BLUETOOTH.md for why it is a
#	library with no I/O of its own.
#

include "sys.m";
	sys: Sys;
include "bthci.m";
	bthci: Bthci;
	Pkt: import bthci;
include "l2cap.m";

init(b: Bthci)
{
	sys = load Sys Sys->PATH;
	bthci = b;
}

Chan.statename(c: self ref Chan): string
{
	case c.state {
	Closed =>	return "Closed";
	Waitconn =>	return "Connecting";
	Config =>	return "Configuring";
	Open =>		return "Connected";
	Waitdisc =>	return "Hangup";
	}
	return "?";
}

#
# Frames.
#

frame(cid: int, payload: array of byte): array of byte
{
	f := array[4 + len payload] of byte;
	bthci->put2(f, 0, len payload);
	bthci->put2(f, 2, cid);
	f[4:] = payload;
	return f;
}

sigcmd(code, ident: int, data: array of byte): array of byte
{
	c := array[4 + len data] of byte;
	c[0] = byte code;
	c[1] = byte ident;
	bthci->put2(c, 2, len data);
	c[4:] = data;
	return c;
}

sig(code, ident: int, data: array of byte): ref Ev
{
	return ref Ev.Send(frame(Cidsig, sigcmd(code, ident, data)));
}

# the same on a named signalling channel: an LE link's is Cidlesig
sigon(sc, code, ident: int, data: array of byte): ref Ev
{
	return ref Ev.Send(frame(sc, sigcmd(code, ident, data)));
}

Chan.queued(c: self ref Chan): int
{
	return len c.txq;
}

# a fixed channel needs no connection: the frame just goes
Link.sendfixed(nil: self ref Link, cid: int, sdu: array of byte): list of ref Ev
{
	return ref Ev.Send(frame(cid, sdu)) :: nil;
}

# LE signalling (Vol 3 Part A 4.20, 4.21): a peripheral asks for
# connection parameters -- a mouse wants a slower interval to save
# its battery -- and is told yes; the caller then makes it so with
# LE_Connection_Update, since a peer whose request is accepted and
# not acted on may well hang up. Anything else on this channel is
# rejected as not understood.
lesignal(l: ref Link, d: array of byte): list of ref Ev
{
	if(len d < 4)
		return nil;
	code := int d[0];
	id := int d[1];
	n := bthci->get2(d, 2);
	if(4 + n > len d)
		n = len d - 4;
	body := d[4:4+n];
	case code {
	Clecreq =>
		return lecreq(l, id, body);
	Clecrsp =>
		return lecrsp(l, id, body);
	Clecredit =>
		return lecredit(l, body);
	Cdiscreq or Cdiscrsp =>
		return command(l, Cidlesig, code, id, body);
	16r12 =>
		if(len d < 12)
			return nil;
		r := array[2] of byte;
		bthci->put2(r, 0, 0);
		return ref Ev.Send(frame(Cidlesig, sigcmd(16r13, id, r))) ::
			ref Ev.Params(bthci->get2(d, 4), bthci->get2(d, 6), bthci->get2(d, 8), bthci->get2(d, 10)) :: nil;
	16r01 or 16r13 =>
		return nil;
	}
	r := array[2] of byte;
	bthci->put2(r, 0, 0);
	return ref Ev.Send(frame(Cidlesig, sigcmd(Creject, id, r))) :: nil;
}

# ACL header: handle and flags in 2 bytes, then the data length
Pbstart: con 2<<12;
Pbcont: con 1<<12;
Pbmask: con 3<<12;

fragment(handle: int, f: array of byte, aclmtu: int): list of ref Pkt
{
	l: list of ref Pkt;
	if(aclmtu < 1)
		aclmtu = 27;
	for(i := 0; i < len f; i += aclmtu){
		n := len f - i;
		if(n > aclmtu)
			n = aclmtu;
		d := array[4 + n] of byte;
		flags := Pbcont;
		if(i == 0)
			flags = Pbstart;
		bthci->put2(d, 0, (handle & 16rfff) | flags);
		bthci->put2(d, 2, n);
		d[4:] = f[i:i+n];
		l = ref Pkt(Bthci->Hacl, d) :: l;
	}
	r: list of ref Pkt;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

#
# Links.
#

Link.new(handle: int): ref Link
{
	return ref Link(handle, nil, nil, Ciddyn, 1, nil, 0, 0, 0, 1);
}

Link.find(l: self ref Link, scid: int): ref Chan
{
	for(cl := l.chans; cl != nil; cl = tl cl)
		if((hd cl).scid == scid)
			return hd cl;
	return nil;
}

findident(l: ref Link, ident: int): ref Chan
{
	for(cl := l.chans; cl != nil; cl = tl cl)
		if((hd cl).ident == ident && (hd cl).state != Closed)
			return hd cl;
	return nil;
}

remove(l: ref Link, c: ref Chan)
{
	keep: list of ref Chan;
	for(cl := l.chans; cl != nil; cl = tl cl)
		if(hd cl != c)
			keep = hd cl :: keep;
	l.chans = keep;
	c.state = Closed;
}

newchan(l: ref Link, psm: int): ref Chan
{
	c := ref Chan(l.nextcid++, 0, psm, Closed, Defmtu, 0, 0, 0, 0, 0,
		0, 0, 0, 0, nil, 0, -1, nil);
	if(l.nextcid > 16rffff)
		l.nextcid = Ciddyn;
	l.chans = c :: l.chans;
	return c;
}

# An LE link has 64 dynamic CIDs, so they are found, not counted up.
newlechan(l: ref Link, psm: int): ref Chan
{
	for(cid := Cidledyn; cid <= Cidlemax; cid++)
		if(l.find(cid) == nil){
			c := ref Chan(cid, 0, psm, Closed, Leminmtu, 0, 0, 0, 0, 0,
				1, Leminmtu, 0, Lecredits, nil, 0, -1, nil);
			l.chans = c :: l.chans;
			return c;
		}
	return nil;
}

# the channel whose far end is dcid: a credit names the sender's own CID
finddcid(l: ref Link, dcid: int): ref Chan
{
	for(cl := l.chans; cl != nil; cl = tl cl)
		if((hd cl).le && (hd cl).dcid == dcid && (hd cl).state != Closed)
			return hd cl;
	return nil;
}

ident(l: ref Link): int
{
	i := l.nextident++;
	if(l.nextident > 255)
		l.nextident = 1;
	return i;
}

accepts(l: ref Link, psm: int): int
{
	for(pl := l.accept; pl != nil; pl = tl pl)
		if(hd pl == psm)
			return 1;
	return 0;
}

Link.connect(l: self ref Link, psm: int): (ref Chan, list of ref Ev)
{
	c := newchan(l, psm);
	c.initiator = 1;
	c.state = Waitconn;
	c.ident = ident(l);
	d := array[4] of byte;
	bthci->put2(d, 0, psm);
	bthci->put2(d, 2, c.scid);
	return (c, sig(Cconnreq, c.ident, d) :: nil);
}

Link.disconnect(l: self ref Link, c: ref Chan): list of ref Ev
{
	if(c.state == Closed)
		return nil;
	if(c.state == Waitconn){
		remove(l, c);
		return ref Ev.Closed(c, "hangup") :: nil;
	}
	c.state = Waitdisc;
	c.ident = ident(l);
	c.txq = nil;
	d := array[4] of byte;
	bthci->put2(d, 0, c.dcid);
	bthci->put2(d, 2, c.scid);
	sc := Cidsig;
	if(c.le)
		sc = Cidlesig;
	return sigon(sc, Cdiscreq, c.ident, d) :: nil;
}

Link.send(l: self ref Link, c: ref Chan, sdu: array of byte): list of ref Ev
{
	if(c.state != Open || len sdu > c.mtu)
		return nil;
	if(c.le)
		return lesend(c, sdu);
	return ref Ev.Send(frame(c.dcid, sdu)) :: nil;
}

#
# LE credit-based channels.
#

Link.leconnect(l: self ref Link, psm: int): (ref Chan, list of ref Ev)
{
	c := newlechan(l, psm);
	if(c == nil)
		return (nil, nil);
	c.initiator = 1;
	c.state = Waitconn;
	c.ident = ident(l);
	d := array[10] of byte;
	bthci->put2(d, 0, psm);
	bthci->put2(d, 2, c.scid);
	bthci->put2(d, 4, Lemtu);
	bthci->put2(d, 6, Lemps);
	bthci->put2(d, 8, Lecredits);
	return (c, sigon(Cidlesig, Clecreq, c.ident, d) :: nil);
}

# An SDU as K-frames (3.4): the first begins with the SDU's length,
# none carries more than the peer's MPS. They join the queue behind
# whatever is already waiting, so SDUs never interleave.
lesend(c: ref Chan, sdu: array of byte): list of ref Ev
{
	first := array[2 + len sdu] of byte;
	bthci->put2(first, 0, len sdu);
	first[2:] = sdu;
	# the queue is kept newest-first; leflush turns it round
	for(i := 0; ; i += c.mps){
		n := len first - i;
		if(n > c.mps)
			n = c.mps;
		c.txq = first[i:i+n] :: c.txq;
		if(i + n >= len first)
			break;
	}
	return leflush(c, 0);
}

# Send what the credits allow. The queue is kept newest-first, so it
# is reversed to send and the unsent remainder reversed back.
leflush(c: ref Chan, note: int): list of ref Ev
{
	if(c.txq == nil)
		return nil;
	fifo: list of array of byte;
	for(q := c.txq; q != nil; q = tl q)
		fifo = hd q :: fifo;
	evs: list of ref Ev;
	while(fifo != nil && c.txcredits > 0){
		evs = ref Ev.Send(frame(c.dcid, hd fifo)) :: evs;
		c.txcredits--;
		fifo = tl fifo;
	}
	c.txq = nil;
	for(; fifo != nil; fifo = tl fifo)
		c.txq = hd fifo :: c.txq;
	if(note && c.txq == nil)
		evs = ref Ev.Sendable(c) :: evs;
	r: list of ref Ev;
	for(; evs != nil; evs = tl evs)
		r = hd evs :: r;
	return r;
}

lecrefuse(id, result: int): list of ref Ev
{
	r := array[10] of { * => byte 0 };
	bthci->put2(r, 8, result);
	return sigon(Cidlesig, Clecrsp, id, r) :: nil;
}

# a peer asks for a channel on a PSM
lecreq(l: ref Link, id: int, d: array of byte): list of ref Ev
{
	if(len d < 10)
		return ref Ev.Send(frame(Cidlesig, sigcmd(Creject, id, array[2] of { * => byte 0 }))) :: nil;
	psm := bthci->get2(d, 0);
	dcid := bthci->get2(d, 2);
	mtu := bthci->get2(d, 4);
	mps := bthci->get2(d, 6);
	credits := bthci->get2(d, 8);
	if(!accepts(l, psm))
		return lecrefuse(id, LRnopsm);
	if(l.needenc && !l.encrypted)
		return lecrefuse(id, LRauthen);
	if(dcid < Cidledyn || dcid > Cidlemax)
		return lecrefuse(id, LRbadscid);
	if(finddcid(l, dcid) != nil)
		return lecrefuse(id, LRscidinuse);
	if(mtu < Leminmtu || mps < Leminmtu || mps > 65533)
		return lecrefuse(id, LRparams);
	c := newlechan(l, psm);
	if(c == nil)
		return lecrefuse(id, LRnoresources);
	c.dcid = dcid;
	c.mtu = mtu;
	c.mps = mps;
	c.txcredits = credits;
	c.state = Open;
	r := array[10] of byte;
	bthci->put2(r, 0, c.scid);
	bthci->put2(r, 2, Lemtu);
	bthci->put2(r, 4, Lemps);
	bthci->put2(r, 6, Lecredits);
	bthci->put2(r, 8, LRok);
	return sigon(Cidlesig, Clecrsp, id, r) :: ref Ev.Incoming(c) :: ref Ev.Opened(c) :: nil;
}

# the answer to ours
lecrsp(l: ref Link, id: int, d: array of byte): list of ref Ev
{
	if(len d < 10)
		return nil;
	c := findident(l, id);
	if(c == nil || !c.le || c.state != Waitconn)
		return nil;
	result := bthci->get2(d, 8);
	if(result != LRok){
		remove(l, c);
		return ref Ev.Closed(c, leresult(result)) :: nil;
	}
	c.dcid = bthci->get2(d, 0);
	c.mtu = bthci->get2(d, 2);
	c.mps = bthci->get2(d, 4);
	c.txcredits = bthci->get2(d, 6);
	if(c.dcid < Cidledyn || c.dcid > Cidlemax || c.mtu < Leminmtu || c.mps < Leminmtu){
		# a channel we cannot use; say so rather than leave it half open
		c.state = Open;
		return l.disconnect(c);
	}
	c.state = Open;
	return ref Ev.Opened(c) :: nil;
}

# the peer will take more
lecredit(l: ref Link, d: array of byte): list of ref Ev
{
	if(len d < 4)
		return nil;
	c := finddcid(l, bthci->get2(d, 0));
	if(c == nil || c.state != Open)
		return nil;
	c.txcredits += bthci->get2(d, 2);
	if(c.txcredits > 65535)
		return l.disconnect(c);		# 10.1: more than can be counted is an error
	return leflush(c, 1);
}

# One K-frame in. A peer that sends without credit, past our MPS, or an
# SDU longer than it said or than we take, is disconnected (10.1, 3.4).
lerecv(l: ref Link, c: ref Chan, p: array of byte): list of ref Ev
{
	if(c.rxcredits <= 0 || len p > Lemps)
		return l.disconnect(c);
	c.rxcredits--;
	if(c.rxwant < 0){
		if(len p < 2)
			return l.disconnect(c);
		c.rxwant = bthci->get2(p, 0);
		if(c.rxwant > Lemtu)
			return l.disconnect(c);
		c.rxsdu = array[c.rxwant] of byte;
		c.rxn = 0;
		p = p[2:];
	}
	if(c.rxn + len p > c.rxwant)
		return l.disconnect(c);
	c.rxsdu[c.rxn:] = p;
	c.rxn += len p;
	evs: list of ref Ev;
	if(c.rxn == c.rxwant){
		evs = ref Ev.Data(c, c.rxsdu) :: nil;
		c.rxsdu = nil;
		c.rxwant = -1;
	}
	if(c.rxcredits <= Lecredits/2){
		r := array[4] of byte;
		bthci->put2(r, 0, c.scid);
		bthci->put2(r, 2, Lecredits - c.rxcredits);
		c.rxcredits = Lecredits;
		evs = append(evs, sigon(Cidlesig, Clecredit, ident(l), r));
	}
	return evs;
}

leresult(r: int): string
{
	case r {
	LRnopsm =>	return "connection refused: PSM not supported";
	LRnoresources =>	return "connection refused: no resources";
	LRauthen =>	return "connection refused: insufficient authentication";
	LRauthor =>	return "connection refused: insufficient authorization";
	LRkeysize =>	return "connection refused: insufficient encryption key size";
	LRencrypt =>	return "connection refused: insufficient encryption";
	LRbadscid =>	return "connection refused: invalid source CID";
	LRscidinuse =>	return "connection refused: source CID already allocated";
	LRparams =>	return "connection refused: unacceptable parameters";
	}
	return sys->sprint("connection refused: result %d", r);
}

Link.down(l: self ref Link, reason: string): list of ref Ev
{
	evs: list of ref Ev;
	for(cl := l.chans; cl != nil; cl = tl cl){
		c := hd cl;
		c.state = Closed;
		evs = ref Ev.Closed(c, reason) :: evs;
	}
	l.chans = nil;
	return evs;
}

# our configuration request: the MTU we accept
confreq(c: ref Chan): array of byte
{
	d := array[8] of byte;
	bthci->put2(d, 0, c.dcid);
	bthci->put2(d, 2, 0);		# flags
	d[4] = byte 1;			# option: MTU
	d[5] = byte 2;
	bthci->put2(d, 6, Ourmtu);
	return d;
}

#
# One ACL packet in. The link's fragments are reassembled here; a
# whole frame is then a signalling command, connectionless data
# (ignored), or data for a channel.
#
Link.recv(l: self ref Link, p: ref Pkt): list of ref Ev
{
	if(p == nil || p.kind != Bthci->Hacl || len p.data < 4)
		return nil;
	hf := bthci->get2(p.data, 0);
	if((hf & 16rfff) != l.handle)
		return nil;
	n := bthci->get2(p.data, 2);
	if(4 + n > len p.data)
		n = len p.data - 4;
	d := p.data[4:4+n];

	if((hf & Pbmask) == Pbstart){
		if(len d < 4)
			return nil;
		want := 4 + bthci->get2(d, 0);
		l.rx = array[want] of byte;
		l.rxwant = want;
		l.rxn = 0;
	}else if(l.rx == nil)
		return nil;		# a continuation with no start: dropped

	if(l.rxn + len d > l.rxwant)
		d = d[0:l.rxwant - l.rxn];
	l.rx[l.rxn:] = d;
	l.rxn += len d;
	if(l.rxn < l.rxwant)
		return nil;
	f := l.rx;
	l.rx = nil;

	cid := bthci->get2(f, 2);
	payload := f[4:];
	case cid {
	Cidsig =>
		return signal(l, payload);
	Cidconnless =>
		return nil;
	Cidatt or Cidsmp =>
		return ref Ev.Fixed(cid, payload) :: nil;
	Cidlesig =>
		return lesignal(l, payload);
	}
	c := l.find(cid);
	if(c == nil || c.state != Open)
		return nil;
	if(c.le)
		return lerecv(l, c, payload);
	return ref Ev.Data(c, payload) :: nil;
}

#
# Signalling: one or more commands in the frame.
#
signal(l: ref Link, d: array of byte): list of ref Ev
{
	evs: list of ref Ev;
	i := 0;
	while(i + 4 <= len d){
		code := int d[i];
		id := int d[i+1];
		n := bthci->get2(d, i+2);
		if(i + 4 + n > len d)
			break;
		body := d[i+4:i+4+n];
		i += 4 + n;
		for(e := command(l, Cidsig, code, id, body); e != nil; e = tl e)
			evs = hd e :: evs;
	}
	r: list of ref Ev;
	for(; evs != nil; evs = tl evs)
		r = hd evs :: r;
	return r;
}

# sc is the signalling channel the command came on, and so the one its
# answer goes back on: an LE link disconnects its channels on Cidlesig
command(l: ref Link, sc, code, id: int, d: array of byte): list of ref Ev
{
	case code {
	Cconnreq =>
		if(len d < 4)
			return reject(id, 0);
		psm := bthci->get2(d, 0);
		dcid := bthci->get2(d, 2);
		r := array[8] of byte;
		bthci->put2(r, 4, 0);
		bthci->put2(r, 6, 0);
		if(!accepts(l, psm) || dcid < Ciddyn){
			bthci->put2(r, 0, 0);
			bthci->put2(r, 2, dcid);
			bthci->put2(r, 4, Rnopsm);
			return sig(Cconnrsp, id, r) :: nil;
		}
		c := newchan(l, psm);
		c.dcid = dcid;
		c.state = Config;
		bthci->put2(r, 0, c.scid);
		bthci->put2(r, 2, dcid);
		bthci->put2(r, 4, Rok);
		c.ident = ident(l);
		c.confsent = 1;
		return sig(Cconnrsp, id, r) :: sig(Cconfreq, c.ident, confreq(c)) :: ref Ev.Incoming(c) :: nil;

	Cconnrsp =>
		if(len d < 8)
			return nil;
		c := findident(l, id);
		if(c == nil || c.state != Waitconn)
			return nil;
		result := bthci->get2(d, 4);
		case result {
		Rok =>
			c.dcid = bthci->get2(d, 0);
			c.state = Config;
			c.ident = ident(l);
			c.confsent = 1;
			return sig(Cconfreq, c.ident, confreq(c)) :: nil;
		Rpending =>
			return nil;
		}
		remove(l, c);
		return ref Ev.Closed(c, connresult(result)) :: nil;

	Cconfreq =>
		if(len d < 4)
			return reject(id, 0);
		c := l.find(bthci->get2(d, 0));
		if(c == nil || (c.state != Config && c.state != Open))
			return reject(id, 2);
		# their options: the MTU is what we may send them; the rest we accept as given
		for(i := 4; i + 2 <= len d; ){
			t := int d[i] & 16r7f;
			n := int d[i+1];
			if(i + 2 + n > len d)
				break;
			if(t == 1 && n == 2)
				c.mtu = bthci->get2(d, i+2);
			i += 2 + n;
		}
		# result success, then their options echoed
		r := array[6 + (len d - 4)] of byte;
		bthci->put2(r, 0, c.dcid);
		bthci->put2(r, 2, 0);
		bthci->put2(r, 4, 0);
		r[6:] = d[4:];
		c.peerconf = 1;
		evs := sig(Cconfrsp, id, r) :: nil;
		if(c.confdone && c.state == Config){
			c.state = Open;
			evs = append(evs, ref Ev.Opened(c));
		}
		return evs;

	Cconfrsp =>
		if(len d < 6)
			return nil;
		c := l.find(bthci->get2(d, 0));
		if(c == nil || c.state != Config)
			return nil;
		result := bthci->get2(d, 4);
		if(result != 0){
			# our configuration refused: nothing to negotiate in basic mode
			evs := l.disconnect(c);
			return evs;
		}
		c.confdone = 1;
		if(c.peerconf){
			c.state = Open;
			return ref Ev.Opened(c) :: nil;
		}
		return nil;

	Cdiscreq =>
		if(len d < 4)
			return reject(id, 0);
		c := l.find(bthci->get2(d, 0));
		r := array[4] of byte;
		r[0:] = d[0:4];
		if(c == nil)
			return sigon(sc, Creject, id, array[2] of { byte 2, byte 0 }) :: nil;
		remove(l, c);
		return sigon(sc, Cdiscrsp, id, r) :: ref Ev.Closed(c, "remote hangup") :: nil;

	Cdiscrsp =>
		if(len d < 4)
			return nil;
		c := l.find(bthci->get2(d, 2));
		if(c == nil || c.state != Waitdisc)
			return nil;
		remove(l, c);
		return ref Ev.Closed(c, "hangup") :: nil;

	Cechoreq =>
		return sig(Cechorsp, id, d) :: nil;

	Cinforeq =>
		if(len d < 2)
			return reject(id, 0);
		t := bthci->get2(d, 0);
		case t {
		2 =>	# extended features: basic mode only
			r := array[8] of byte;
			bthci->put2(r, 0, t);
			bthci->put2(r, 2, 0);
			bthci->put4(r, 4, 0);
			return sig(Cinforsp, id, r) :: nil;
		3 =>	# fixed channels: the signalling channel
			r := array[12] of { * => byte 0 };
			bthci->put2(r, 0, t);
			bthci->put2(r, 2, 0);
			r[4] = byte 2;
			return sig(Cinforsp, id, r) :: nil;
		}
		r := array[4] of byte;
		bthci->put2(r, 0, t);
		bthci->put2(r, 2, 1);		# not supported
		return sig(Cinforsp, id, r) :: nil;

	Cinforsp or Cechorsp or Creject =>
		return nil;
	}
	return reject(id, 0);
}

# Command Reject: reason 0 not understood, 1 MTU exceeded, 2 invalid CID
reject(id, reason: int): list of ref Ev
{
	r := array[2] of byte;
	bthci->put2(r, 0, reason);
	return sig(Creject, id, r) :: nil;
}

connresult(r: int): string
{
	case r {
	Rnopsm =>	return "connection refused: PSM not supported";
	Rsecurity =>	return "connection refused: security block";
	Rnoresources =>	return "connection refused: no resources";
	}
	return sys->sprint("connection refused: result %d", r);
}

append(l: list of ref Ev, e: ref Ev): list of ref Ev
{
	if(l == nil)
		return e :: nil;
	return hd l :: append(tl l, e);
}
