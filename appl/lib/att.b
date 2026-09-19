implement Att;

#
# ATT, and the GATT client discovery a HID device needs; see att.m.
# Little-endian throughout, as ATT is. One request is outstanding at
# a time (3.3.2): others queue on the Client and go as answers come.
#

include "sys.m";
	sys: Sys;
include "bthci.m";
	bthci: Bthci;
include "att.m";

# the Bluetooth base UUID, little-endian as ATT carries it
base := array[] of {
	byte 16rfb, byte 16r34, byte 16r9b, byte 16r5f, byte 16r80, byte 0, byte 0, byte 16r80,
	byte 0, byte 16r10, byte 0, byte 0, byte 0, byte 0, byte 0, byte 0,
};

init(b: Bthci)
{
	sys = load Sys Sys->PATH;
	bthci = b;
}

get2(a: array of byte, i: int): int
{
	return int a[i] | (int a[i+1] << 8);
}

put2(a: array of byte, i, v: int)
{
	a[i] = byte v;
	a[i+1] = byte (v >> 8);
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

uuid16(a: array of byte, i: int, n: int): int
{
	if(n == 2)
		return get2(a, i);
	if(n != 16)
		return -1;
	for(k := 0; k < 12; k++)
		if(a[i+k] != base[k])
			return -1;
	if(a[i+14] != byte 0 || a[i+15] != byte 0)
		return -1;
	return get2(a, i + 12);
}

#
# The server.
#

uuidbytes(u: int): array of byte
{
	a := array[2] of byte;
	put2(a, 0, u);
	return a;
}

parseuuid(str: string): array of byte
{
	h := "";
	for(i := 0; i < len str; i++)
		if(str[i] != '-')
			h[len h] = str[i];
	if(len h != 32)
		return nil;
	a := array[16] of byte;
	for(i = 0; i < 16; i++){
		v := 0;
		for(j := 0; j < 2; j++){
			c := h[2*i + j];
			d := -1;
			if(c >= '0' && c <= '9')
				d = c - '0';
			else if(c >= 'a' && c <= 'f')
				d = c - 'a' + 10;
			else if(c >= 'A' && c <= 'F')
				d = c - 'A' + 10;
			if(d < 0)
				return nil;
			v = v*16 + d;
		}
		a[15 - i] = byte v;	# written most significant first, carried least
	}
	return a;
}

# requests have even opcodes below 0x20 that are not responses; the
# commands are Write Command, Signed Write, and Handle Value Confirmation
isrequest(pdu: array of byte): int
{
	if(len pdu < 1)
		return 0;
	case int pdu[0] {
	Omtureq or Ofindinforeq or Ofindbytypereq or Oreadbytypereq or Oreadreq or Oreadblobreq or
	16r0e or Oreadbygroupreq or Owritereq or 16r16 or 16r18 or Owritecmd or 16rd2 or Oconfirm =>
		return 1;
	}
	return 0;
}

Gattsrv.new(): ref Gattsrv
{
	return ref Gattsrv(Defmtu, nil, 1, 0);
}

addattr(s: ref Gattsrv, a: ref Attr)
{
	r: list of ref Attr;
	for(l := s.attrs; l != nil; l = tl l)
		r = hd l :: r;
	r = a :: r;
	s.attrs = nil;
	for(; r != nil; r = tl r)
		s.attrs = hd r :: s.attrs;
}

# the service declaration the characteristics now being added belong to
lastservice(s: ref Gattsrv): ref Attr
{
	sv: ref Attr;
	for(l := s.attrs; l != nil; l = tl l)
		if(uuid16((hd l).uuid, 0, len (hd l).uuid) == Uprimary)
			sv = hd l;
	return sv;
}

Gattsrv.service(s: self ref Gattsrv, uuid: array of byte): int
{
	h := s.next++;
	addattr(s, ref Attr(h, uuidbytes(Uprimary), uuid, h, 0));
	return h;
}

Gattsrv.characteristic(s: self ref Gattsrv, uuid: array of byte, value: array of byte, needenc: int): int
{
	sv := lastservice(s);
	if(sv == nil)
		return -1;
	dh := s.next++;
	vh := s.next++;
	# the declaration: properties, the value's handle, its UUID
	d := array[3 + len uuid] of byte;
	d[0] = byte Pread;
	put2(d, 1, vh);
	d[3:] = uuid;
	addattr(s, ref Attr(dh, uuidbytes(Ucharacteristic), d, dh, 0));
	addattr(s, ref Attr(vh, uuid, value, vh, needenc));
	sv.end = vh;
	return vh;
}

Gattsrv.set(s: self ref Gattsrv, handle: int, value: array of byte)
{
	for(l := s.attrs; l != nil; l = tl l)
		if((hd l).handle == handle)
			(hd l).value = value;
}

srverr(op, handle, code: int): array of byte
{
	e := array[5] of byte;
	e[0] = byte Oerror;
	e[1] = byte op;
	put2(e, 2, handle);
	e[4] = byte code;
	return e;
}

sameuuid(a, b: array of byte): int
{
	# a 16-bit UUID and its 128-bit form on the base are the same UUID
	if(len a != len b){
		x := uuid16(a, 0, len a);
		return x >= 0 && x == uuid16(b, 0, len b);
	}
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

samebytes(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

# may this attribute be read now? 0, or the error that says why not
readable(s: ref Gattsrv, a: ref Attr): int
{
	if(a.needenc && !s.encrypted)
		return Einsufauthn;
	return 0;
}

Gattsrv.recv(s: self ref Gattsrv, pdu: array of byte): array of byte
{
	if(len pdu < 1)
		return nil;
	op := int pdu[0];
	case op {
	Omtureq =>
		if(len pdu < 3)
			return srverr(op, 0, Einvalidpdu);
		m := get2(pdu, 1);
		if(m < Defmtu)
			m = Defmtu;
		if(m > Srvmtu)
			m = Srvmtu;
		s.mtu = m;
		r := array[3] of byte;
		r[0] = byte Omtursp;
		put2(r, 1, Srvmtu);
		return r;

	Ofindinforeq =>
		if(len pdu < 5)
			return srverr(op, 0, Einvalidpdu);
		(start, end) := (get2(pdu, 1), get2(pdu, 3));
		if(start == 0 || start > end)
			return srverr(op, start, Einvalidhandle);
		# handle and UUID pairs, all of one UUID length
		out := array[2] of byte;
		out[0] = byte Ofindinforsp;
		ulen := 0;
		for(l := s.attrs; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end)
				continue;
			if(ulen == 0)
				ulen = len a.uuid;
			if(len a.uuid != ulen || len out + 2 + ulen > s.mtu)
				break;
			e := array[2 + ulen] of byte;
			put2(e, 0, a.handle);
			e[2:] = a.uuid;
			out = cat(out, e);
		}
		if(ulen == 0)
			return srverr(op, start, Eattrnotfound);
		out[1] = byte 1;
		if(ulen == 16)
			out[1] = byte 2;
		return out;

	Ofindbytypereq =>
		# how a central finds one service by its UUID: type 0x2800, value the UUID
		if(len pdu < 7)
			return srverr(op, 0, Einvalidpdu);
		(start, end) := (get2(pdu, 1), get2(pdu, 3));
		if(start == 0 || start > end)
			return srverr(op, start, Einvalidhandle);
		typ := get2(pdu, 5);
		val := pdu[7:];
		out := array[1] of { byte Ofindbytypersp };
		for(l := s.attrs; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end || uuid16(a.uuid, 0, len a.uuid) != typ)
				continue;
			if(!sameuuid(a.value, val) && !samebytes(a.value, val))
				continue;
			if(len out + 4 > s.mtu)
				break;
			e := array[4] of byte;
			put2(e, 0, a.handle);
			put2(e, 2, a.end);
			out = cat(out, e);
		}
		if(len out == 1)
			return srverr(op, start, Eattrnotfound);
		return out;

	Oreadbytypereq or Oreadbygroupreq =>
		if(len pdu != 7 && len pdu != 21)
			return srverr(op, 0, Einvalidpdu);
		(start, end) := (get2(pdu, 1), get2(pdu, 3));
		if(start == 0 || start > end)
			return srverr(op, start, Einvalidhandle);
		typ := pdu[5:];
		group := op == Oreadbygroupreq;
		if(group && uuid16(typ, 0, len typ) != Uprimary)
			return srverr(op, start, Eunsupportedgroup);
		hdr := 2;
		if(group)
			hdr = 4;
		out := array[2] of byte;
		out[0] = byte (op + 1);
		vlen := -1;
		for(l := s.attrs; l != nil; l = tl l){
			a := hd l;
			if(a.handle < start || a.handle > end || !sameuuid(a.uuid, typ))
				continue;
			if((why := readable(s, a)) != 0){
				if(vlen < 0)
					return srverr(op, a.handle, why);
				break;
			}
			v := a.value;
			if(len v > s.mtu - 2 - hdr)
				v = v[0:s.mtu - 2 - hdr];
			if(len v > 255 - hdr)
				v = v[0:255 - hdr];
			if(vlen < 0)
				vlen = len v;
			if(len v != vlen || len out + hdr + vlen > s.mtu)
				break;
			e := array[hdr + vlen] of byte;
			put2(e, 0, a.handle);
			if(group)
				put2(e, 2, a.end);
			e[hdr:] = v;
			out = cat(out, e);
		}
		if(vlen < 0)
			return srverr(op, start, Eattrnotfound);
		out[1] = byte (hdr + vlen);
		return out;

	Oreadreq or Oreadblobreq =>
		need := 3;
		if(op == Oreadblobreq)
			need = 5;
		if(len pdu < need)
			return srverr(op, 0, Einvalidpdu);
		h := get2(pdu, 1);
		off := 0;
		if(op == Oreadblobreq)
			off = get2(pdu, 3);
		for(l := s.attrs; l != nil; l = tl l){
			a := hd l;
			if(a.handle != h)
				continue;
			if((why := readable(s, a)) != 0)
				return srverr(op, h, why);
			if(off > len a.value)
				return srverr(op, h, Einvalidoffset);
			v := a.value[off:];
			if(len v > s.mtu - 1)
				v = v[0:s.mtu - 1];
			return cat(array[1] of { byte (op + 1) }, v);
		}
		return srverr(op, h, Einvalidhandle);

	Owritereq =>
		h := 0;
		if(len pdu >= 3)
			h = get2(pdu, 1);
		for(l := s.attrs; l != nil; l = tl l)
			if((hd l).handle == h)
				return srverr(op, h, Ewritenotpermitted);
		return srverr(op, h, Einvalidhandle);

	Owritecmd or 16rd2 or Oconfirm =>
		return nil;		# commands are not answered, even to refuse them
	}
	return srverr(op, 0, Enotsupported);
}

errtext(code: int): string
{
	case code {
	Einvalidhandle =>	return "invalid handle";
	Ereadnotpermitted =>	return "read not permitted";
	Ewritenotpermitted =>	return "write not permitted";
	Einvalidpdu =>		return "invalid PDU";
	Einsufauthn =>		return "insufficient authentication";
	Einvalidoffset =>	return "invalid offset";
	Eunsupportedgroup =>	return "unsupported group type";
	Enotsupported =>	return "request not supported";
	Einsufauthz =>		return "insufficient authorization";
	Eattrnotfound =>	return "attribute not found";
	Einsufencrypt =>	return "insufficient encryption";
	}
	return sys->sprint("att error 0x%2.2x", code);
}

Characteristic.cccd(c: self ref Characteristic): int
{
	for(l := c.descs; l != nil; l = tl l){
		(h, u) := hd l;
		if(u == Ucccd)
			return h;
	}
	return -1;
}

Characteristic.reportref(c: self ref Characteristic): int
{
	for(l := c.descs; l != nil; l = tl l){
		(h, u) := hd l;
		if(u == Ureportref)
			return h;
	}
	return -1;
}

Client.new(): ref Client
{
	return ref Client(Defmtu, 0, 0, nil, 0, nil, nil, 0, nil, 0);
}

# a request goes now if the line is free, else it waits
request(c: ref Client, pdu: array of byte): list of ref Ev
{
	if(c.pending != 0){
		c.q = appendb(c.q, pdu);
		return nil;
	}
	c.pending = int pdu[0];
	if(len pdu >= 3)
		c.phandle = get2(pdu, 1);
	else
		c.phandle = 0;
	return ref Ev.Send(pdu) :: nil;
}

# the answer came: send the next request, if one waits
next(c: ref Client): list of ref Ev
{
	c.pending = 0;
	if(c.q == nil)
		return nil;
	pdu := hd c.q;
	c.q = tl c.q;
	return request(c, pdu);
}

Client.exchangemtu(c: self ref Client, mtu: int): list of ref Ev
{
	p := array[3] of byte;
	p[0] = byte Omtureq;
	put2(p, 1, mtu);
	c.offer = mtu;
	return request(c, p);
}

Client.read(c: self ref Client, handle: int): list of ref Ev
{
	p := array[3] of byte;
	p[0] = byte Oreadreq;
	put2(p, 1, handle);
	return request(c, p);
}

Client.write(c: self ref Client, handle: int, value: array of byte): list of ref Ev
{
	p := array[3] of byte;
	p[0] = byte Owritereq;
	put2(p, 1, handle);
	return request(c, cat(p, value));
}

Client.writecmd(nil: self ref Client, handle: int, value: array of byte): list of ref Ev
{
	p := array[3] of byte;
	p[0] = byte Owritecmd;
	put2(p, 1, handle);
	return ref Ev.Send(cat(p, value)) :: nil;	# no answer comes, so it does not take the line
}

Client.subscribe(c: self ref Client, cccd: int, indications: int): list of ref Ev
{
	v := array[2] of byte;
	v[0] = byte 1;
	if(indications)
		v[0] = byte 2;
	v[1] = byte 0;
	return c.write(cccd, v);
}

# discovery: the primary services, then the characteristics of the
# one wanted, then each characteristic's descriptors
Client.discover(c: self ref Client, u: int): list of ref Ev
{
	c.want = u;
	c.svc = nil;
	c.chars = nil;
	c.dchar = nil;
	c.dstart = 1;
	return request(c, groupreq(1));
}

groupreq(start: int): array of byte
{
	p := array[7] of byte;
	p[0] = byte Oreadbygroupreq;
	put2(p, 1, start);
	put2(p, 3, 16rffff);
	put2(p, 5, Uprimary);
	return p;
}

typereq(start, end: int): array of byte
{
	p := array[7] of byte;
	p[0] = byte Oreadbytypereq;
	put2(p, 1, start);
	put2(p, 3, end);
	put2(p, 5, Ucharacteristic);
	return p;
}

inforeq(start, end: int): array of byte
{
	p := array[5] of byte;
	p[0] = byte Ofindinforeq;
	put2(p, 1, start);
	put2(p, 3, end);
	return p;
}

Client.recv(c: self ref Client, pdu: array of byte): list of ref Ev
{
	if(len pdu < 1)
		return nil;
	op := int pdu[0];
	case op {
	Onotify =>
		if(len pdu < 3)
			return nil;
		return ref Ev.Notified(get2(pdu, 1), pdu[3:]) :: nil;
	Oindicate =>
		if(len pdu < 3)
			return nil;
		return ref Ev.Send(array[] of { byte Oconfirm }) :: ref Ev.Notified(get2(pdu, 1), pdu[3:]) :: nil;
	Oerror =>
		if(len pdu < 5)
			return nil;
		return errorrsp(c, int pdu[1], get2(pdu, 2), int pdu[4]);
	}
	# everything else answers the request out
	if(c.pending == 0 || op != c.pending + 1)
		return nil;
	h := c.phandle;
	case op {
	Omtursp =>
		# the MTU is the smaller of the two offers (3.4.2.2), and never
		# under the default. It used to be the smaller of the server's
		# and the DEFAULT, our own offer forgotten, so it never rose
		# above 23 whatever either end could take.
		if(len pdu >= 3){
			m := get2(pdu, 1);
			if(c.offer < m)
				m = c.offer;
			if(m < Defmtu)
				m = Defmtu;
			c.mtu = m;
		}
		return ref Ev.Mtu(c.mtu) :: next(c);
	Oreadrsp =>
		return ref Ev.Value(h, pdu[1:]) :: next(c);
	Owritersp =>
		return ref Ev.Written(h) :: next(c);
	Oreadbygrouprsp =>
		return groups(c, pdu);
	Oreadbytypersp =>
		return chars(c, pdu);
	Ofindinforsp =>
		return infos(c, pdu);
	}
	return next(c);
}

# an Error Response ends a request; during discovery "attribute not
# found" is the normal end of a range, and means "go on to the next
# step" rather than failure
errorrsp(c: ref Client, reqop: int, h: int, code: int): list of ref Ev
{
	if(c.pending == 0 || reqop != c.pending)
		return nil;
	if(code == Eattrnotfound){
		case reqop {
		Oreadbygroupreq =>
			c.pending = 0;
			return ref Ev.Nosuch(c.want) :: next(c);
		Oreadbytypereq =>
			c.pending = 0;
			return descriptors(c);
		Ofindinforeq =>
			# the rest of this characteristic's range is empty
			c.pending = 0;
			if(c.dchar != nil)
				c.dchar = tl c.dchar;
			return descriptors(c);
		}
	}
	e := ref Ev.Failed(reqop, h, code, errtext(code));
	return e :: next(c);
}

groups(c: ref Client, pdu: array of byte): list of ref Ev
{
	if(len pdu < 2)
		return next(c);
	n := int pdu[1];
	if(n < 6)
		return next(c);
	last := 0;
	for(i := 2; i + n <= len pdu; i += n){
		start := get2(pdu, i);
		end := get2(pdu, i+2);
		last = end;
		u := uuid16(pdu, i+4, n-4);
		if(u == c.want){
			s := ref Service(start, end, u, nil);
			if(n - 4 == 16)
				s.uuid128 = pdu[i+4:i+n];
			c.svc = s;
			c.pending = 0;
			c.dstart = start;
			return request(c, typereq(start, end));
		}
	}
	c.pending = 0;
	if(last >= 16rffff)
		return ref Ev.Nosuch(c.want) :: next(c);
	return request(c, groupreq(last + 1));
}

chars(c: ref Client, pdu: array of byte): list of ref Ev
{
	if(len pdu < 2 || c.svc == nil)
		return next(c);
	n := int pdu[1];
	if(n < 7)
		return next(c);
	last := 0;
	for(i := 2; i + n <= len pdu; i += n){
		h := get2(pdu, i);
		last = h;
		ch := ref Characteristic(h, int pdu[i+2], get2(pdu, i+3), uuid16(pdu, i+5, n-5), nil, nil);
		if(n - 5 == 16)
			ch.uuid128 = pdu[i+5:i+n];
		c.chars = appendc(c.chars, ch);
	}
	c.pending = 0;
	if(last >= c.svc.end)
		return descriptors(c);
	return request(c, typereq(last + 1, c.svc.end));
}

# the descriptors of each characteristic lie between its value handle
# and the next declaration (or the service's end)
descriptors(c: ref Client): list of ref Ev
{
	if(c.svc == nil)
		return nil;
	if(c.dstart != -1){
		# the characteristic phase is over: start on descriptors
		c.dchar = c.chars;
		c.dstart = -1;
	}
	while(c.dchar != nil){
		ch := hd c.dchar;
		end := c.svc.end;
		if(tl c.dchar != nil)
			end = (hd tl c.dchar).handle - 1;
		if(ch.value + 1 <= end)
			return request(c, inforeq(ch.value + 1, end));
		c.dchar = tl c.dchar;
	}
	s := c.svc;
	chs := c.chars;
	c.svc = nil;
	c.chars = nil;
	return ref Ev.Found(s, chs) :: nil;
}

infos(c: ref Client, pdu: array of byte): list of ref Ev
{
	if(len pdu < 2 || c.dchar == nil)
		return next(c);
	n := 4;
	if(int pdu[1] == 2)
		n = 18;
	ch := hd c.dchar;
	last := 0;
	for(i := 2; i + n <= len pdu; i += n){
		h := get2(pdu, i);
		last = h;
		ch.descs = appendd(ch.descs, (h, uuid16(pdu, i+2, n-2)));
	}
	end := c.svc.end;
	if(tl c.dchar != nil)
		end = (hd tl c.dchar).handle - 1;
	c.pending = 0;
	if(last < end)
		return request(c, inforeq(last + 1, end));
	c.dchar = tl c.dchar;
	return descriptors(c);
}

appendb(l: list of array of byte, b: array of byte): list of array of byte
{
	if(l == nil)
		return b :: nil;
	return hd l :: appendb(tl l, b);
}

appendc(l: list of ref Characteristic, ch: ref Characteristic): list of ref Characteristic
{
	if(l == nil)
		return ch :: nil;
	return hd l :: appendc(tl l, ch);
}

appendd(l: list of (int, int), d: (int, int)): list of (int, int)
{
	if(l == nil)
		return d :: nil;
	return hd l :: appendd(tl l, d);
}
