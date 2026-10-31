implement Sdp;

#
# The Service Discovery Protocol as data; see sdp.m. Big-endian
# throughout, unlike HCI and L2CAP, because SDP is.
#

include "sys.m";
	sys: Sys;
include "bthci.m";
	bthci: Bthci;
include "sdp.m";

# element type codes, 3.2
Tnil, Tuint, Tint, Tuuid, Tstr, Tbool, Tseq, Talt, Turl: con iota;

# the Bluetooth base UUID, 00000000-0000-1000-8000-00805F9B34FB
baseuuid := array[] of {
	byte 0, byte 0, byte 0, byte 0, byte 0, byte 0, byte 16r10, byte 0,
	byte 16r80, byte 0, byte 0, byte 16r80, byte 16r5f, byte 16r9b, byte 16r34, byte 16rfb,
};

init(b: Bthci)
{
	sys = load Sys Sys->PATH;
	bthci = b;
}

put2(a: array of byte, i, v: int)
{
	a[i] = byte (v >> 8);
	a[i+1] = byte v;
}

get2(a: array of byte, i: int): int
{
	return (int a[i] << 8) | int a[i+1];
}

put4(a: array of byte, i, v: int)
{
	put2(a, i, v >> 16);
	put2(a, i+2, v);
}

get4(a: array of byte, i: int): int
{
	return (get2(a, i) << 16) | get2(a, i+2);
}

cat(a, b: array of byte): array of byte
{
	r := array[len a + len b] of byte;
	r[0:] = a;
	r[len a:] = b;
	return r;
}

# a header for a payload of n bytes: type and size, the size as the
# smallest of the three length forms that holds it
hdr(t: int, n: int): array of byte
{
	if(n < 256)
		return array[] of { byte (t<<3 | 5), byte n };
	if(n < 65536){
		h := array[3] of byte;
		h[0] = byte (t<<3 | 6);
		put2(h, 1, n);
		return h;
	}
	h := array[5] of byte;
	h[0] = byte (t<<3 | 7);
	put4(h, 1, n);
	return h;
}

# the fixed-size forms: 1, 2, 4, 8, 16 bytes are size indices 0..4
fixedhdr(t: int, size: int): byte
{
	idx := 0;
	case size {
	1 =>	idx = 0;
	2 =>	idx = 1;
	4 =>	idx = 2;
	8 =>	idx = 3;
	16 =>	idx = 4;
	}
	return byte (t<<3 | idx);
}

putbig(a: array of byte, i: int, v: big, size: int)
{
	for(k := size - 1; k >= 0; k--){
		a[i+k] = byte v;
		v >>= 8;
	}
}

getbig(a: array of byte, i: int, size: int): big
{
	v := big 0;
	for(k := 0; k < size; k++)
		v = (v << 8) | big a[i+k];
	return v;
}

Elem.pack(e: self ref Elem): array of byte
{
	pick x := e {
	Nil =>
		return array[] of { byte 0 };
	Uint =>
		a := array[1 + x.size] of byte;
		a[0] = fixedhdr(Tuint, x.size);
		putbig(a, 1, x.v, x.size);
		return a;
	Int =>
		a := array[1 + x.size] of byte;
		a[0] = fixedhdr(Tint, x.size);
		putbig(a, 1, x.v, x.size);
		return a;
	Uuid =>
		a := array[1 + len x.v] of byte;
		a[0] = fixedhdr(Tuuid, len x.v);
		a[1:] = x.v;
		return a;
	Str =>
		b := array of byte x.s;
		return cat(hdr(Tstr, len b), b);
	Url =>
		b := array of byte x.s;
		return cat(hdr(Turl, len b), b);
	Bool =>
		return array[] of { byte (Tbool<<3), byte (x.v != 0) };
	Seq or Alt =>
		t := Tseq;
		l := x.l;
		if(tagof x == tagof Elem.Alt)
			t = Talt;
		body := array[0] of byte;
		for(; l != nil; l = tl l)
			body = cat(body, (hd l).pack());
		return cat(hdr(t, len body), body);
	}
	return nil;
}

# the element at a[i]: (element, index after it), or (nil, i) if the
# bytes do not describe one
unpack(a: array of byte, i: int): (ref Elem, int)
{
	if(i >= len a)
		return (nil, i);
	t := int a[i] >> 3;
	sz := int a[i] & 7;
	i++;
	n := 0;
	case sz {
	0 =>	n = 1;
	1 =>	n = 2;
	2 =>	n = 4;
	3 =>	n = 8;
	4 =>	n = 16;
	5 =>	if(i + 1 > len a) return (nil, i-1);
		n = int a[i];
		i++;
	6 =>	if(i + 2 > len a) return (nil, i-1);
		n = get2(a, i);
		i += 2;
	7 =>	if(i + 4 > len a) return (nil, i-1);
		n = get4(a, i);
		i += 4;
	}
	if(t == Tnil)
		n = 0;
	if(i + n > len a)
		return (nil, i);
	body := a[i:i+n];
	end := i + n;
	case t {
	Tnil =>
		return (ref Elem.Nil, end);
	Tuint =>
		if(n > 8) return (nil, i);
		return (ref Elem.Uint(getbig(body, 0, n), n), end);
	Tint =>
		if(n > 8) return (nil, i);
		v := getbig(body, 0, n);
		if(n < 8 && (v & (big 1 << (8*n - 1))) != big 0)
			v -= big 1 << (8*n);		# sign-extend
		return (ref Elem.Int(v, n), end);
	Tuuid =>
		if(n != 2 && n != 4 && n != 16) return (nil, i);
		return (ref Elem.Uuid(body), end);
	Tstr =>
		return (ref Elem.Str(string body), end);
	Turl =>
		return (ref Elem.Url(string body), end);
	Tbool =>
		if(n != 1) return (nil, i);
		return (ref Elem.Bool(int body[0]), end);
	Tseq or Talt =>
		l: list of ref Elem;
		for(j := 0; j < n;){
			(e, nj) := unpack(body, j);
			if(e == nil)
				return (nil, i);
			l = e :: l;
			j = nj;
		}
		r: list of ref Elem;
		for(; l != nil; l = tl l)
			r = hd l :: r;
		if(t == Tseq)
			return (ref Elem.Seq(r), end);
		return (ref Elem.Alt(r), end);
	}
	return (nil, i);
}

Elem.text(e: self ref Elem): string
{
	pick x := e {
	Nil =>	return "nil";
	Uint =>	return sys->sprint("0x%bx", x.v);
	Int =>	return sys->sprint("%bd", x.v);
	Uuid =>
		u := e.uuid16();
		if(u >= 0)
			return sys->sprint("uuid 0x%4.4x", u);
		return "uuid " + bthci->hex(x.v);
	Str =>	return sys->sprint("%q", x.s);
	Url =>	return sys->sprint("url %q", x.s);
	Bool =>	return sys->sprint("%d", x.v != 0);
	Seq or Alt =>
		s := "(";
		if(tagof x == tagof Elem.Alt)
			s = "alt(";
		for(l := x.l; l != nil; l = tl l){
			if(l != x.l)
				s += " ";
			s += (hd l).text();
		}
		return s + ")";
	}
	return "?";
}

# every UUID is compared as 128 bits, 2.5.1
uuid128(v: array of byte): array of byte
{
	if(len v == 16)
		return v;
	r := array[16] of byte;
	r[0:] = baseuuid;
	if(len v == 2){
		r[2] = v[0];
		r[3] = v[1];
	}else if(len v == 4)
		r[0:] = v;
	return r;
}

Elem.uuid16(e: self ref Elem): int
{
	pick x := e {
	Uuid =>
		u := uuid128(x.v);
		for(i := 4; i < 16; i++)
			if(u[i] != baseuuid[i])
				return -1;
		if(u[0] != byte 0 || u[1] != byte 0)
			return -1;
		return get2(u, 2);
	}
	return -1;
}

sameuuid(a, b: array of byte): int
{
	x := uuid128(a);
	y := uuid128(b);
	for(i := 0; i < 16; i++)
		if(x[i] != y[i])
			return 0;
	return 1;
}

uuid(u16: int): ref Elem
{
	v := array[2] of byte;
	put2(v, 0, u16);
	return ref Elem.Uuid(v);
}

uint8(v: int): ref Elem
{
	return ref Elem.Uint(big v & big 16rff, 1);
}

uint16(v: int): ref Elem
{
	return ref Elem.Uint(big v & big 16rffff, 2);
}

uint32(v: int): ref Elem
{
	return ref Elem.Uint(big v & big 16rffffffff, 4);
}

seq(l: list of ref Elem): ref Elem
{
	return ref Elem.Seq(l);
}

str(s: string): ref Elem
{
	return ref Elem.Str(s);
}

Record.attr(r: self ref Record, id: int): ref Elem
{
	for(l := r.attrs; l != nil; l = tl l){
		(i, e) := hd l;
		if(i == id)
			return e;
	}
	return nil;
}

Record.classes(r: self ref Record): list of int
{
	e := r.attr(Aclassidlist);
	if(e == nil)
		return nil;
	l: list of int;
	pick x := e {
	Seq =>
		for(m := x.l; m != nil; m = tl m){
			u := (hd m).uuid16();
			if(u >= 0)
				l = u :: l;
		}
	}
	return l;
}

# the protocol descriptor list is a sequence of sequences, each a
# protocol UUID and its parameters: ((L2CAP) (RFCOMM chan)) for a
# serial port
Record.rfcommchan(r: self ref Record): int
{
	e := r.attr(Aprotocols);
	if(e == nil)
		return -1;
	pick x := e {
	Seq =>
		for(m := x.l; m != nil; m = tl m){
			pick p := hd m {
			Seq =>
				if(p.l != nil && (hd p.l).uuid16() == Urfcomm && tl p.l != nil){
					pick c := hd tl p.l {
					Uint =>	return int c.v;
					}
				}
			}
		}
	}
	return -1;
}

Record.name(r: self ref Record): string
{
	e := r.attr(Aservicename);
	if(e == nil)
		return nil;
	pick x := e {
	Str =>	return x.s;
	}
	return nil;
}

# does u appear anywhere in e?
contains(e: ref Elem, u: array of byte): int
{
	pick x := e {
	Uuid =>
		return sameuuid(x.v, u);
	Seq or Alt =>
		for(l := x.l; l != nil; l = tl l)
			if(contains(hd l, u))
				return 1;
	}
	return 0;
}

# a record matches a search pattern when every UUID in the pattern is
# somewhere in it, 2.5.2
matches(r: ref Record, pattern: list of array of byte): int
{
	for(; pattern != nil; pattern = tl pattern){
		found := 0;
		for(l := r.attrs; l != nil && !found; l = tl l){
			(nil, e) := hd l;
			found = contains(e, hd pattern);
		}
		if(!found)
			return 0;
	}
	return 1;
}

spprecord(handle: int, channel: int, name: string): ref Record
{
	attrs := (Arecordhandle, uint32(handle)) ::
		(Aclassidlist, seq(uuid(Userialport) :: nil)) ::
		(Aprotocols, seq(seq(uuid(Ul2cap) :: nil) :: seq(uuid(Urfcomm) :: uint8(channel) :: nil) :: nil)) ::
		(Abrowsegroups, seq(uuid(Upublicbrowse) :: nil)) ::
		(Alanguages, seq(uint16(16r656e) :: uint16(16r006a) :: uint16(16r0100) :: nil)) ::
		(Aprofiles, seq(seq(uuid(Userialport) :: uint16(16r0102) :: nil) :: nil)) ::
		(Aservicename, str(name)) :: nil;
	return ref Record(handle, attrs);
}

Server.new(): ref Server
{
	return ref Server(nil, 16r10000);
}

Server.add(s: self ref Server, r: ref Record): int
{
	r.handle = s.nexthandle++;
	# the handle attribute must agree with the handle
	attrs: list of (int, ref Elem);
	for(l := r.attrs; l != nil; l = tl l){
		(id, e) := hd l;
		if(id == Arecordhandle)
			e = uint32(r.handle);
		attrs = (id, e) :: attrs;
	}
	r.attrs = nil;
	for(; attrs != nil; attrs = tl attrs)
		r.attrs = hd attrs :: r.attrs;
	s.recs = appendrec(s.recs, r);
	return r.handle;
}

appendrec(l: list of ref Record, r: ref Record): list of ref Record
{
	if(l == nil)
		return r :: nil;
	return hd l :: appendrec(tl l, r);
}

Server.remove(s: self ref Server, handle: int)
{
	keep: list of ref Record;
	for(l := s.recs; l != nil; l = tl l)
		if((hd l).handle != handle)
			keep = hd l :: keep;
	s.recs = nil;
	for(; keep != nil; keep = tl keep)
		s.recs = hd keep :: s.recs;
}

pduhdr(pdu: array of byte): (int, int, int)
{
	if(len pdu < 5)
		return (-1, 0, 0);
	n := get2(pdu, 3);
	if(5 + n != len pdu)
		return (-1, 0, 0);
	return (int pdu[0], get2(pdu, 1), n);
}

pdu(id: int, tid: int, params: array of byte): array of byte
{
	p := array[5 + len params] of byte;
	p[0] = byte id;
	put2(p, 1, tid);
	put2(p, 3, len params);
	p[5:] = params;
	return p;
}

errpdu(tid: int, code: int): array of byte
{
	e := array[2] of byte;
	put2(e, 0, code);
	return pdu(Perror, tid, e);
}

errorrsp(p: array of byte): int
{
	(id, nil, n) := pduhdr(p);
	if(id != Perror || n < 2)
		return -1;
	return get2(p, 5);
}

# the UUIDs of a service search pattern element
pattern(e: ref Elem): list of array of byte
{
	l: list of array of byte;
	pick x := e {
	Seq =>
		for(m := x.l; m != nil; m = tl m)
			pick u := hd m {
			Uuid =>	l = u.v :: l;
			* =>	return nil;
			}
	* =>
		return nil;
	}
	return l;
}

# an attribute id list: (lo, hi) ranges
idranges(e: ref Elem): list of (int, int)
{
	l: list of (int, int);
	pick x := e {
	Seq =>
		for(m := x.l; m != nil; m = tl m)
			pick u := hd m {
			Uint =>
				if(u.size == 2)
					l = (int u.v, int u.v) :: l;
				else if(u.size == 4)
					l = (int (u.v >> 16), int u.v & 16rffff) :: l;
				else
					return nil;
			* =>	return nil;
			}
	* =>
		return nil;
	}
	return l;
}

wanted(id: int, ranges: list of (int, int)): int
{
	for(; ranges != nil; ranges = tl ranges){
		(lo, hi) := hd ranges;
		if(id >= lo && id <= hi)
			return 1;
	}
	return 0;
}

# a record's attribute list as one sequence element: id, value, id, value...
attrlist(r: ref Record, ranges: list of (int, int)): array of byte
{
	l: list of ref Elem;
	for(a := r.attrs; a != nil; a = tl a){
		(id, e) := hd a;
		if(wanted(id, ranges))
			l = e :: uint16(id) :: l;
	}
	rl: list of ref Elem;
	for(; l != nil; l = tl l)
		rl = hd l :: rl;
	return seq(rl).pack();
}

# continuation state: none, or one byte of length then a 16-bit offset
# into the full response this same request would produce
contstate(a: array of byte, i: int): (int, int)
{
	if(i >= len a)
		return (-1, i);
	n := int a[i];
	if(n == 0)
		return (0, i + 1);
	if(n != 2 || i + 3 > len a)
		return (-1, i);
	return (get2(a, i + 1), i + 3);
}

# the response body cut to what fits: the peer's byte limit, and the
# L2CAP MTU less the header, count and continuation state
chunk(body: array of byte, offset: int, maxbytes: int, mtu: int): (array of byte, array of byte)
{
	room := mtu - 5 - 2 - 3;
	if(room > maxbytes)
		room = maxbytes;
	if(room < 1)
		room = 1;
	if(offset > len body)
		offset = len body;
	rest := len body - offset;
	if(rest <= room)
		return (body[offset:], array[] of { byte 0 });
	c := array[3] of byte;
	c[0] = byte 2;
	put2(c, 1, offset + room);
	return (body[offset:offset+room], c);
}

Server.request(s: self ref Server, p: array of byte, mtu: int): array of byte
{
	(id, tid, nil) := pduhdr(p);
	if(id < 0)
		return errpdu(0, Ebadpdusize);
	i := 5;
	case id {
	Psearchreq =>
		(pe, ni) := unpack(p, i);
		pat := pattern(pe);
		if(pe == nil || pat == nil || ni + 2 > len p)
			return errpdu(tid, Ebadsyntax);
		maxrecs := get2(p, ni);
		(off, nil) := contstate(p, ni + 2);
		if(off < 0)
			return errpdu(tid, Ebadcont);
		handles: list of int;
		total := 0;
		for(l := s.recs; l != nil; l = tl l)
			if(matches(hd l, pat)){
				total++;
				if(total <= maxrecs)
					handles = (hd l).handle :: handles;
			}
		hs := array[4 * len handles] of byte;
		k := len handles;
		for(; handles != nil; handles = tl handles){
			k--;
			put4(hs, 4*k, hd handles);
		}
		r := array[4 + len hs + 1] of byte;
		put2(r, 0, total);
		put2(r, 2, len hs / 4);
		r[4:] = hs;
		r[4 + len hs] = byte 0;
		return pdu(Psearchrsp, tid, r);
	Pattrreq =>
		if(i + 6 > len p)
			return errpdu(tid, Ebadsyntax);
		handle := get4(p, i);
		maxbytes := get2(p, i + 4);
		(ae, ni) := unpack(p, i + 6);
		ranges := idranges(ae);
		if(ae == nil || ranges == nil)
			return errpdu(tid, Ebadsyntax);
		(off, nil) := contstate(p, ni);
		if(off < 0)
			return errpdu(tid, Ebadcont);
		rec: ref Record;
		for(l := s.recs; l != nil; l = tl l)
			if((hd l).handle == handle)
				rec = hd l;
		if(rec == nil)
			return errpdu(tid, Ebadhandle);
		body := attrlist(rec, ranges);
		(part, cont) := chunk(body, off, maxbytes, mtu);
		r := array[2] of byte;
		put2(r, 0, len part);
		return pdu(Pattrrsp, tid, cat(cat(r, part), cont));
	Psearchattrreq =>
		(pe, ni) := unpack(p, i);
		pat := pattern(pe);
		if(pe == nil || pat == nil || ni + 2 > len p)
			return errpdu(tid, Ebadsyntax);
		maxbytes := get2(p, ni);
		(ae, nj) := unpack(p, ni + 2);
		ranges := idranges(ae);
		if(ae == nil || ranges == nil)
			return errpdu(tid, Ebadsyntax);
		(off, nil) := contstate(p, nj);
		if(off < 0)
			return errpdu(tid, Ebadcont);
		lists: list of ref Elem;
		for(l := s.recs; l != nil; l = tl l)
			if(matches(hd l, pat)){
				(e, nil) := unpack(attrlist(hd l, ranges), 0);
				if(e != nil)
					lists = e :: lists;
			}
		rl: list of ref Elem;
		for(; lists != nil; lists = tl lists)
			rl = hd lists :: rl;
		body := seq(rl).pack();
		(part, cont) := chunk(body, off, maxbytes, mtu);
		r := array[2] of byte;
		put2(r, 0, len part);
		return pdu(Psearchattrrsp, tid, cat(cat(r, part), cont));
	}
	return errpdu(tid, Ebadsyntax);
}

searchattrreq(tid: int, uuids: list of int, attrs: list of (int, int), maxbytes: int, cont: array of byte): array of byte
{
	ul: list of ref Elem;
	for(; uuids != nil; uuids = tl uuids)
		ul = uuid(hd uuids) :: ul;
	al: list of ref Elem;
	for(; attrs != nil; attrs = tl attrs){
		(lo, hi) := hd attrs;
		if(lo == hi)
			al = uint16(lo) :: al;
		else
			al = uint32((lo << 16) | hi) :: al;
	}
	mb := array[2] of byte;
	put2(mb, 0, maxbytes);
	if(cont == nil)
		cont = array[] of { byte 0 };
	return pdu(Psearchattrreq, tid, cat(cat(cat(seq(ul).pack(), mb), seq(al).pack()), cont));
}

# a response's piece of the attribute lists and the continuation state
# for the next request, nil when this piece was the last
searchattrrsp(p: array of byte): (array of byte, array of byte, string)
{
	(id, nil, n) := pduhdr(p);
	if(id == Perror)
		return (nil, nil, sys->sprint("sdp error 0x%4.4x", errorrsp(p)));
	if(id != Psearchattrrsp || n < 3)
		return (nil, nil, "not a service search attribute response");
	cnt := get2(p, 5);
	if(7 + cnt > len p)
		return (nil, nil, "short response");
	body := p[7:7+cnt];
	(off, nil) := contstate(p, 7 + cnt);
	if(off < 0)
		return (nil, nil, "bad continuation state");
	if(off > 0)
		return (body, p[7+cnt:], nil);
	return (body, nil, nil);
}

# the attribute lists element -- a sequence of sequences of id, value
# pairs -- as records
records(body: array of byte): list of ref Record
{
	(e, nil) := unpack(body, 0);
	if(e == nil)
		return nil;
	recs: list of ref Record;
	pick x := e {
	Seq =>
		for(l := x.l; l != nil; l = tl l){
			r := ref Record(0, nil);
			pick al := hd l {
			Seq =>
				for(m := al.l; m != nil && tl m != nil; m = tl tl m){
					pick idm := hd m {
					Uint =>
						r.attrs = (int idm.v, hd tl m) :: r.attrs;
						if(int idm.v == Arecordhandle)
							pick hv := hd tl m {
							Uint =>	r.handle = int hv.v;
							}
					}
				}
			}
			a: list of (int, ref Elem);
			for(; r.attrs != nil; r.attrs = tl r.attrs)
				a = hd r.attrs :: a;
			r.attrs = a;
			recs = r :: recs;
		}
	}
	rl: list of ref Record;
	for(; recs != nil; recs = tl recs)
		rl = hd recs :: rl;
	return rl;
}
