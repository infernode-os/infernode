implement Bthci;

#
#	HCI over H4: framing, decoding, and a host that issues commands.
#	See bthci.m for what each piece is for; docs/BLUETOOTH.md for why
#	this is a library and bt9p(4) is the program.
#

include "sys.m";
	sys: Sys;
include "bthci.m";

init()
{
	sys = load Sys Sys->PATH;
}

#
# Little-endian.
#

get2(a: array of byte, i: int): int
{
	return int a[i] | (int a[i+1] << 8);
}

get4(a: array of byte, i: int): int
{
	return int a[i] | (int a[i+1] << 8) | (int a[i+2] << 16) | (int a[i+3] << 24);
}

put2(a: array of byte, i, v: int)
{
	a[i] = byte v;
	a[i+1] = byte (v >> 8);
}

put4(a: array of byte, i, v: int)
{
	a[i] = byte v;
	a[i+1] = byte (v >> 8);
	a[i+2] = byte (v >> 16);
	a[i+3] = byte (v >> 24);
}

#
# Opcodes.
#

opcode(g, c: int): int
{
	return (g << 10) | (c & 16r3ff);
}

ogf(op: int): int
{
	return op >> 10;
}

ocf(op: int): int
{
	return op & 16r3ff;
}

#
# The wire format.
#

frame(p: ref Pkt): array of byte
{
	b := array[1 + len p.data] of byte;
	b[0] = byte p.kind;
	b[1:] = p.data;
	return b;
}

# header length by indicator, and where in the header the payload length is
hdrlen(kind: int): int
{
	case kind {
	Hcmd =>	return 3;	# opcode 2, plen 1
	Hacl =>	return 4;	# handle 2, len 2
	Hsco =>	return 3;	# handle 2, len 1
	Hevt =>	return 2;	# code 1, plen 1
	Hiso =>	return 4;	# handle 2, len 2 (14 bits)
	}
	return -1;
}

paylen(kind: int, b: array of byte): int
{
	case kind {
	Hcmd =>	return int b[3];
	Hacl =>	return get2(b, 3);
	Hsco =>	return int b[3];
	Hevt =>	return int b[2];
	Hiso =>	return get2(b, 3) & 16r3fff;
	}
	return -1;
}

Deframer.new(): ref Deframer
{
	return ref Deframer(array[4096] of byte, 0, 0);
}

Deframer.feed(d: self ref Deframer, b: array of byte): list of ref Pkt
{
	out: list of ref Pkt;

	if(d.n + len b > len d.buf){
		nb := array[2 * (d.n + len b)] of byte;
		nb[0:] = d.buf[0:d.n];
		d.buf = nb;
	}
	d.buf[d.n:] = b;
	d.n += len b;

	for(;;){
		if(d.n == 0)
			break;
		kind := int d.buf[0];
		hl := hdrlen(kind);
		if(hl < 0){
			# not an indicator: noise, or we joined mid-packet. Drop it and look again.
			d.buf[0:] = d.buf[1:d.n];
			d.n--;
			d.junk++;
			continue;
		}
		if(d.n < 1 + hl)
			break;
		total := 1 + hl + paylen(kind, d.buf);
		if(d.n < total)
			break;
		data := array[total - 1] of byte;
		data[0:] = d.buf[1:total];
		out = ref Pkt(kind, data) :: out;
		d.buf[0:] = d.buf[total:d.n];
		d.n -= total;
	}
	# built newest-first; callers want wire order
	r: list of ref Pkt;
	for(; out != nil; out = tl out)
		r = hd out :: r;
	return r;
}

#
# Events.
#

Event.parse(p: ref Pkt): ref Event
{
	if(p == nil || p.kind != Hevt || len p.data < 2)
		return nil;
	n := int p.data[1];
	if(2 + n > len p.data)
		n = len p.data - 2;
	return ref Event(int p.data[0], p.data[2:2+n]);
}

cmdcomplete(e: ref Event): (int, int, array of byte)
{
	if(e == nil || e.code != EvCmdComplete || len e.params < 3)
		return (0, -1, nil);
	return (int e.params[0], get2(e.params, 1), e.params[3:]);
}

cmdstatus(e: ref Event): (int, int, int)
{
	if(e == nil || e.code != EvCmdStatus || len e.params < 4)
		return (-1, 0, -1);
	return (int e.params[0], int e.params[1], get2(e.params, 2));
}

command(op: int, params: array of byte): ref Pkt
{
	d := array[3 + len params] of byte;
	put2(d, 0, op);
	d[2] = byte len params;
	d[3:] = params;
	return ref Pkt(Hcmd, d);
}

statusname(s: int): string
{
	case s {
	Sok =>			return "success";
	Sunknowncmd =>		return "unknown HCI command";
	Sunknownconn =>		return "unknown connection";
	Shwfail =>		return "hardware failure";
	Spagetimeout =>		return "page timeout";
	Sauthfail =>		return "authentication failure";
	Snokey =>		return "PIN or key missing";
	Smemory =>		return "memory capacity exceeded";
	Sconntimeout =>		return "connection timeout";
	Scmddisallowed =>	return "command disallowed";
	Sunsupported =>		return "unsupported feature or parameter";
	Sinvalidparams =>	return "invalid HCI command parameters";
	Sremoteterm =>		return "remote user terminated connection";
	Slocalterm =>		return "connection terminated by local host";
	}
	return sys->sprint("status 0x%2.2ux", s);
}

#
# Addresses.
#

bdaddr(a: array of byte, i: int): string
{
	if(a == nil || i + 6 > len a)
		return "?";
	return sys->sprint("%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux:%2.2ux",
		int a[i+5], int a[i+4], int a[i+3], int a[i+2], int a[i+1], int a[i]);
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
}

parsebdaddr(s: string): array of byte
{
	if(len s != 17)
		return nil;
	a := array[6] of byte;
	for(i := 0; i < 6; i++){
		if(i > 0 && s[3*i - 1] != ':')
			return nil;
		hi := hexval(s[3*i]);
		lo := hexval(s[3*i + 1]);
		if(hi < 0 || lo < 0)
			return nil;
		a[5 - i] = byte ((hi << 4) | lo);
	}
	return a;
}

#
# Versions.
#

Version.parse(ret: array of byte): ref Version
{
	if(ret == nil || len ret < 8)
		return nil;
	return ref Version(int ret[0], get2(ret, 1), int ret[3], get2(ret, 4), get2(ret, 6));
}

Version.text(v: self ref Version): string
{
	return sys->sprint("hci %s lmp %s manufacturer %d (%s)",
		vername(v.hci), vername(v.lmp), v.manuf, manufacturer(v.manuf));
}

vername(v: int): string
{
	names := array[] of {
		"1.0b", "1.1", "1.2", "2.0", "2.1", "3.0", "4.0", "4.1",
		"4.2", "5.0", "5.1", "5.2", "5.3", "5.4", "6.0", "6.1",
	};
	if(v >= 0 && v < len names)
		return names[v];
	return sys->sprint("%d", v);
}

manufacturer(m: int): string
{
	case m {
	0 =>	return "Ericsson";
	2 =>	return "Intel";
	10 =>	return "Cambridge Silicon Radio";
	13 =>	return "Texas Instruments";
	15 =>	return "Broadcom";
	29 =>	return "Qualcomm";
	70 =>	return "MediaTek";
	93 =>	return "Realtek";
	305 =>	return "Cypress";
	65535 =>	return "test";
	}
	return sys->sprint("%d", m);
}

#
# Inquiry results. Three event shapes carry them, two of which are
# arrays-of-fields rather than arrays-of-records: n addresses, then n
# scan modes, then n classes... The extended form is one device with
# an EIR block, in which the name may be found.
#

inquiryresults(e: ref Event): list of ref Found
{
	r: list of ref Found;

	if(e == nil || len e.params < 1)
		return nil;
	p := e.params;
	case e.code {
	EvInquiryResult =>
		n := int p[0];
		# addr 6n, psrm n, reserved n, reserved n, class 3n, clock 2n
		if(len p < 1 + n*14)
			return nil;
		for(i := n - 1; i >= 0; i--){
			addr := bdaddr(p, 1 + 6*i);
			cls := p[1 + 9*n + 3*i:] ;
			class := int cls[0] | (int cls[1] << 8) | (int cls[2] << 16);
			r = ref Found(addr, class, 0, nil, -1) :: r;
		}
	EvInquiryResultRssi =>
		n := int p[0];
		# addr 6n, psrm n, reserved n, class 3n, clock 2n, rssi n
		if(len p < 1 + n*14)
			return nil;
		for(i := n - 1; i >= 0; i--){
			addr := bdaddr(p, 1 + 6*i);
			cls := p[1 + 8*n + 3*i:];
			class := int cls[0] | (int cls[1] << 8) | (int cls[2] << 16);
			rssi := int p[1 + 13*n + i];
			if(rssi >= 128)
				rssi -= 256;
			r = ref Found(addr, class, rssi, nil, -1) :: r;
		}
	EvExtInquiryResult =>
		# n is always 1: addr 6, psrm 1, reserved 1, class 3, clock 2, rssi 1, EIR 240
		if(len p < 15)
			return nil;
		addr := bdaddr(p, 1);
		class := int p[9] | (int p[10] << 8) | (int p[11] << 16);
		rssi := int p[14];
		if(rssi >= 128)
			rssi -= 256;
		r = ref Found(addr, class, rssi, eirname(p[15:]), -1) :: nil;
	}
	return r;
}

#
# LE Advertising Reports: an LE Meta event, subevent 2, then per
# report -- laid out one report after another, as every controller in
# practice sends them one at a time -- event type, address type,
# address, data length, data, RSSI. The name is in the data, in the
# same AD structures as an EIR.
#
leadvreports(e: ref Event): list of ref Found
{
	r: list of ref Found;

	if(e == nil || e.code != EvLeMeta || len e.params < 2 || int e.params[0] != LeAdvReport)
		return nil;
	p := e.params;
	n := int p[1];
	i := 2;
	for(k := 0; k < n; k++){
		if(i + 9 > len p)
			break;
		letype := int p[i+1];
		addr := bdaddr(p, i+2);
		dlen := int p[i+8];
		if(i + 9 + dlen + 1 > len p)
			break;
		nm := eirname(p[i+9:i+9+dlen]);
		rssi := int p[i+9+dlen];
		if(rssi >= 128)
			rssi -= 256;
		r = ref Found(addr, 0, rssi, nm, letype) :: r;
		i += 10 + dlen;
	}
	l: list of ref Found;
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return l;
}

remotename(e: ref Event): (int, string, string)
{
	if(e == nil || e.code != EvRemoteName || len e.params < 7)
		return (-1, nil, nil);
	p := e.params;
	n := 7;
	while(n < len p && p[n] != byte 0)
		n++;
	return (int p[0], bdaddr(p, 1), string p[7:n]);
}

# the name in an Extended Inquiry Response: type 9 complete, type 8 shortened
eirname(eir: array of byte): string
{
	i := 0;
	short := "";
	while(i < len eir){
		l := int eir[i];
		if(l == 0 || i + 1 + l > len eir)
			break;
		t := int eir[i+1];
		if(t == 16r09)
			return string eir[i+2:i+1+l];
		if(t == 16r08)
			short = string eir[i+2:i+1+l];
		i += 1 + l;
	}
	return short;
}

hex(a: array of byte): string
{
	s := "";
	for(i := 0; i < len a; i++){
		if(i > 0)
			s[len s] = ' ';
		s += sys->sprint("%2.2ux", int a[i]);
	}
	return s;
}

hcdrecords(hcd: array of byte): (list of (int, array of byte), int)
{
	l: list of (int, array of byte);
	i := 0;
	while(i < len hcd){
		if(i + 3 > len hcd)
			return (nil, i);
		op := get2(hcd, i);
		n := int hcd[i+2];
		if(i + 3 + n > len hcd)
			return (nil, i);
		p := array[n] of byte;
		p[0:] = hcd[i+3:i+3+n];
		l = (op, p) :: l;
		i += 3 + n;
	}
	r: list of (int, array of byte);
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return (r, -1);
}

#
# The transport.
#

Transport.h4(fd: ref Sys->FD): ref Transport
{
	t := ref Transport(fd, chan of ref Pkt, nil, 0);
	pidc := chan of int;
	spawn h4reader(t, pidc);
	t.pid = <-pidc;
	return t;
}

h4reader(t: ref Transport, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	d := Deframer.new();
	buf := array[4096] of byte;
	for(;;){
		n := sys->read(t.fd, buf, len buf);
		if(n < 0){
			t.err = sys->sprint("read: %r");
			break;
		}
		if(n == 0){
			t.err = "eof";
			break;
		}
		for(l := d.feed(buf[0:n]); l != nil; l = tl l)
			t.in <-= hd l;
	}
	t.in <-= nil;
}

Transport.send(t: self ref Transport, p: ref Pkt): int
{
	b := frame(p);
	if(sys->write(t.fd, b, len b) != len b)
		return -1;
	return 0;
}

Transport.stop(t: self ref Transport)
{
	if(t.pid > 0)
		kill(t.pid);
	t.pid = 0;
}

kill(pid: int)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

#
# The host.
#

Hci.new(t: ref Transport): ref Hci
{
	h := ref Hci(t, chan[64] of ref Event, chan[64] of ref Pkt, chan of ref Req, chan of int, 0, 0, 0);
	pidc := chan of int;
	spawn mux(h, pidc);
	h.pid = <-pidc;
	return h;
}

Hci.cmd(h: self ref Hci, op: int, params: array of byte, ms: int): (int, array of byte, string)
{
	if(h.dead)
		return (-1, nil, "controller gone");
	r := ref Req(op, command(op, params), sys->millisec() + ms, chan of (int, array of byte, string));
	h.reqs <-= r;
	return <-r.reply;
}

Hci.send(h: self ref Hci, p: ref Pkt): int
{
	if(h.dead)
		return -1;
	return h.t.send(p);
}

Hci.stop(h: self ref Hci)
{
	if(!h.dead)
		h.ctl <-= 1;
}

Tickms: con 100;
Stuckms: con 2000;	# a credit withheld this long is assumed lost

ticker(c: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		sys->sleep(Tickms);
		c <-= 1;
	}
}

#
# One process, one transport. Commands wait in queue until the
# controller has said it can take one more (credits), go out in order,
# and sit in flight until an event names their opcode or their
# deadline passes. Everything that is not the answer to a command goes
# out on events -- or is counted, if nobody is reading them.
#
mux(h: ref Hci, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	tick := chan of int;
	tpidc := chan of int;
	spawn ticker(tick, tpidc);
	tickpid := <-tpidc;

	credits := 1;
	queue: list of ref Req;		# waiting for a credit, oldest first
	inflight: list of ref Req;	# sent, waiting for an answer
	late: list of ref Req;
	r: ref Req;
	stucksince := 0;

	for(;;){
		alt {
		nr := <-h.reqs =>
			queue = append(queue, nr);
			(queue, inflight, credits) = pump(h, queue, inflight, credits);

		p := <-h.t.in =>
			if(p == nil){
				# the transport died: fail everything, tell the world once
				why := h.t.err;
				if(why == nil)
					why = "transport closed";
				for(; queue != nil; queue = tl queue)
					(hd queue).reply <-= (-1, nil, why);
				for(; inflight != nil; inflight = tl inflight)
					(hd inflight).reply <-= (-1, nil, why);
				h.dead = 1;
				kill(tickpid);
				alt { h.events <-= nil => ; * => ; }
				return;
			}
			if(p.kind != Hevt){
				alt { h.data <-= p => ; * => h.dropped++; }
				continue;
			}
			e := Event.parse(p);
			if(e == nil)
				continue;
			case e.code {
			EvCmdComplete =>
				(ncmd, op, ret) := cmdcomplete(e);
				credits = ncmd;
				(inflight, r) = take(inflight, op);
				if(r != nil){
					if(len ret > 0)
						r.reply <-= (int ret[0], ret[1:], nil);
					else
						r.reply <-= (Sok, nil, nil);
				}else if(op != 0)
					deliver(h, e);
			EvCmdStatus =>
				(status, ncmd, op) := cmdstatus(e);
				credits = ncmd;
				(inflight, r) = take(inflight, op);
				if(r != nil)
					r.reply <-= (status, nil, nil);
				else
					deliver(h, e);
			* =>
				deliver(h, e);
			}
			(queue, inflight, credits) = pump(h, queue, inflight, credits);

		<-tick =>
			now := sys->millisec();
			(inflight, late) = expire(inflight, now);
			for(; late != nil; late = tl late)
				(hd late).reply <-= (-1, nil, "timeout");
			(queue, late) = expire(queue, now);
			for(; late != nil; late = tl late)
				(hd late).reply <-= (-1, nil, "timeout: no command credit");
			# Nothing in flight, work waiting, no credit: the
			# controller took a credit and never gave it back, or a
			# refund was lost. The specification says wait; a
			# controller that is silent for this long is not going
			# to speak, and one credit is what the host starts with.
			# A request with a shorter deadline has already failed
			# above, saying why, which is what a test of the flow
			# control wants to see.
			if(inflight == nil && queue != nil && credits == 0){
				if(stucksince == 0)
					stucksince = now;
				else if(now - stucksince >= Stuckms){
					credits = 1;
					stucksince = 0;
				}
			}else
				stucksince = 0;
			(queue, inflight, credits) = pump(h, queue, inflight, credits);

		<-h.ctl =>
			for(; queue != nil; queue = tl queue)
				(hd queue).reply <-= (-1, nil, "stopped");
			for(; inflight != nil; inflight = tl inflight)
				(hd inflight).reply <-= (-1, nil, "stopped");
			h.dead = 1;
			kill(tickpid);
			h.t.stop();
			alt { h.events <-= nil => ; * => ; }
			return;
		}
	}
}

deliver(h: ref Hci, e: ref Event)
{
	alt {
	h.events <-= e =>	;
	* =>			h.dropped++;
	}
}

pump(h: ref Hci, queue, inflight: list of ref Req, credits: int): (list of ref Req, list of ref Req, int)
{
	while(credits > 0 && queue != nil){
		r := hd queue;
		queue = tl queue;
		if(h.t.send(r.p) < 0){
			r.reply <-= (-1, nil, sys->sprint("write: %r"));
			continue;
		}
		inflight = append(inflight, r);
		credits--;
	}
	return (queue, inflight, credits);
}

append(l: list of ref Req, r: ref Req): list of ref Req
{
	if(l == nil)
		return r :: nil;
	return hd l :: append(tl l, r);
}

# remove and return the oldest request with this opcode
take(l: list of ref Req, op: int): (list of ref Req, ref Req)
{
	if(l == nil)
		return (nil, nil);
	r := hd l;
	if(r.op == op)
		return (tl l, r);
	(rest, found) := take(tl l, op);
	return (r :: rest, found);
}

# split off the requests whose deadline has passed
expire(l: list of ref Req, now: int): (list of ref Req, list of ref Req)
{
	keep, late: list of ref Req;
	for(; l != nil; l = tl l){
		r := hd l;
		if(r.deadline - now <= 0)
			late = r :: late;
		else
			keep = append(keep, r);
	}
	return (keep, late);
}
