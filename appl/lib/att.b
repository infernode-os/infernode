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

errtext(code: int): string
{
	case code {
	Einvalidhandle =>	return "invalid handle";
	Ereadnotpermitted =>	return "read not permitted";
	Ewritenotpermitted =>	return "write not permitted";
	Einsufauthn =>		return "insufficient authentication";
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
	return ref Client(Defmtu, 0, 0, nil, 0, nil, nil, 0, nil);
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
		if(len pdu >= 3){
			m := get2(pdu, 1);
			if(m < c.mtu)
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
