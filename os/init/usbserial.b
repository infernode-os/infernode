implement Usbserial;

#
# USB serial adapters as eia(3) ports: /dev/eiaU0, eiaU0ctl, eiaU0status.
#
# A program rather than kernel code, like the other USB class drivers
# here: a serial adapter is two bulk endpoints and a handful of control
# requests, and what differs between makers is only which requests.
# The interface is not new. It is eia(3), which #t serves for the
# board's own UARTs and the hosted emulator serves for the host's
# ports, so a program that talks to /dev/eia0 talks to an adapter
# unchanged; U in the name keeps the numbers clear of the UARTs' and
# says which kind of port it is.
#
# Families, each a few requests behind one front:
#
#	acm	the USB communications class (CDC-ACM): microcontroller
#		boards, GPS receivers, modems. Line coding and the DTR/RTS
#		lines are class requests to the control interface; DCD, DSR
#		and RI arrive on its interrupt endpoint. ACM has no CTS.
#	ftdi	FT232 and its family. Vendor requests; every bulk IN packet
#		begins with two status bytes (the modem lines, then the line
#		errors), which are taken off here.
#	cp210x	Silicon Labs. Vendor requests to the interface; the modem
#		lines are read when the status file is.
#
# The files are made in a #s of their own, #seia, which init binds
# after /dev at boot: every namespace forked after that sees a port
# that is plugged in later, without binding anything itself.
#
# NOT DONE: CH340 and PL2303 (vendor protocols documented only by
# other drivers); exclusive open (file2chan sees reads and writes, not
# opens, and Inferno's own eia does not insist on it either); the same
# name for the same adapter after it is unplugged and plugged back in
# (the first free number is taken); XON/XOFF on anything but FTDI.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Usbserial: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# control requests
Rh2d:		con 16r00;
Rd2h:		con 16r80;
Rstd:		con 16r00;
Rclass:		con 16r20;
Rvendor:	con 16r40;
Rdev:		con 0;
Riface:		con 1;
Rgetdesc:	con 6;
Ddev:		con 1;
Dconf:		con 2;

# CDC-ACM (USB CDC PSTN 1.2)
Asetlinecoding:	con 16r20;
Agetlinecoding:	con 16r21;
Asetlinestate:	con 16r22;
Asendbreak:	con 16r23;
Aserialstate:	con 16r20;	# the notification

# FTDI (the vendor's application notes, and Linux's ftdi_sio)
Freset:		con 0;
Fmodemctrl:	con 1;
Fsetflow:	con 2;
Fsetbaud:	con 3;
Fsetdata:	con 4;
Fsetlatency:	con 9;
Fpurgerx:	con 1;
Fpurgetx:	con 2;

# CP210x (Silicon Labs AN571)
Cifcenable:	con 16r00;
Csetlinectl:	con 16r03;
Csetbreak:	con 16r05;
Csetmhs:	con 16r07;
Cgetmdmsts:	con 16r08;
Cpurge:		con 16r12;
Csetflow:	con 16r13;
Csetbaudrate:	con 16r1E;

Vftdi:		con 16r0403;
Vsilabs:	con 16r10C4;

Acm, Ftdi, Cp210x: con iota;
famname := array[] of {"acm", "ftdi", "cp210x"};

Maxq:	con 256*1024;	# received bytes held for a reader before the oldest are dropped
Maxports:	con 16;

Port: adt {
	fam:	int;
	n:	int;		# eiaU<n>
	iface:	int;		# the interface the bulk endpoints are on (acm: the data one)
	ctliface:	int;	# where the requests go (acm: the control interface)
	index:	int;		# ftdi: the port's wIndex, 0 on a one-port chip
	hchip:	int;		# ftdi: an H chip, which has the 120 MHz clock
	inep, outep, maxpkt:	int;
	intrep, intrmax, intrival:	int;	# acm's notification endpoint, or -1
	bulkin, bulkout:	ref Sys->FD;

	# the line, as eia(3) says it
	baud, bits, stop, dtr, rts, cts, xon:	int;
	parity:	int;		# 'n', 'o', 'e', 'm', 's'
	hupdcd, hupdsr:	int;
	qlim:	int;
	# what the adapter reports
	incts, indsr, indcd, inri:	int;
	ferr, oerr, perr, brk:	int;
	nrx, ntx:	big;
};

dev: string;		# devusb's name for the device: epN.0
ctlfd: ref Sys->FD;
ep0: ref Sys->FD;
vendor, product, bcd: int;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	if(args != nil && hd args == "-t"){
		selftest();
		return;
	}
	if(args == nil){
		sys->print("usbserial: no device given\n");
		return;
	}
	dev = hd args;
	ctlfd = sys->open("/usb/usb/" + dev + "/ctl", Sys->ORDWR);
	ep0 = sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
	if(ctlfd == nil || ep0 == nil){
		sys->print("usbserial: cannot open %s: %r\n", dev);
		return;
	}
	dd := array[18] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Ddev << 8, 0, dd) < len dd){
		sys->print("usbserial: %s: no device descriptor: %r\n", dev);
		return;
	}
	vendor = get2le(dd, 8);
	product = get2le(dd, 10);
	bcd = get2le(dd, 12);
	cfg := config();
	if(cfg == nil){
		sys->print("usbserial: %s: configuration unreadable\n", dev);
		return;
	}
	ports := findports(cfg);
	if(ports == nil){
		sys->print("usbserial: %s %#4.4x:%#4.4x: no serial interface this driver knows\n", dev, vendor, product);
		return;
	}
	for(; ports != nil; ports = tl ports){
		p := hd ports;
		if(openport(p) < 0)
			continue;
		if(setup(p) < 0)
			sys->print("usbserial: %s: setting the line up failed: %r\n", dev);
		if(serve(p) < 0)
			return;
	}
}

#
# The device's configuration descriptor, whole.
#
config(): array of byte
{
	hdr := array[9] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Dconf << 8, 0, hdr) < len hdr)
		return nil;
	total := get2le(hdr, 2);
	if(total < len hdr || total > 4096)
		return nil;
	cfg := array[total] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Dconf << 8, 0, cfg) < total)
		return nil;
	return cfg;
}

Iface: adt {
	num, class, sub, proto:	int;
	bin, bout, bmax:	int;
	iin, imax, iival:	int;
	union:	int;		# acm: the data interface its union descriptor names, or -1
};

#
# The ports a device has, from its interfaces: one for an ACM control
# interface and the data interface beside it; one for each vendor
# interface with a pair of bulk endpoints on an FTDI or CP210x.
#
findports(cfg: array of byte): list of ref Port
{
	ifs: list of ref Iface;
	cur: ref Iface;
	for(p := 0; p + 2 <= len cfg; ){
		dlen := int cfg[p];
		if(dlen < 2 || p + dlen > len cfg)
			break;
		case int cfg[p+1] {
		4 =>	# interface; alternate settings other than 0 are not used
			if(dlen >= 9 && int cfg[p+3] == 0){
				cur = ref Iface(int cfg[p+2], int cfg[p+5], int cfg[p+6], int cfg[p+7],
					-1, -1, 0, -1, 0, 0, -1);
				ifs = cur :: ifs;
			}else
				cur = nil;
		16r24 =>	# class-specific interface: the CDC union
			if(cur != nil && dlen >= 5 && int cfg[p+2] == 6)
				cur.union = int cfg[p+4];
		5 =>	# endpoint
			if(cur != nil && dlen >= 7){
				addr := int cfg[p+2];
				typ := int cfg[p+3] & 3;
				mx := get2le(cfg, p+4) & 16r7FF;
				if(typ == 2 && (addr & 16r80) && cur.bin < 0){
					cur.bin = addr & 16rF;
					cur.bmax = mx;
				}else if(typ == 2 && (addr & 16r80) == 0 && cur.bout < 0)
					cur.bout = addr & 16rF;
				else if(typ == 3 && (addr & 16r80) && cur.iin < 0){
					cur.iin = addr & 16rF;
					cur.imax = mx;
					cur.iival = int cfg[p+6];
				}
			}
		}
		p += dlen;
	}
	ifs = rev(ifs);

	ports: list of ref Port;
	nvendor := 0;
	for(l := ifs; l != nil; l = tl l)
		if((hd l).class == 255 && (hd l).bin >= 0 && (hd l).bout >= 0)
			nvendor++;
	for(l = ifs; l != nil; l = tl l){
		f := hd l;
		if(isacm(f.class, f.sub, f.proto)){
			d := dataiface(ifs, f);
			if(d == nil)
				continue;
			pt := newport(Acm, d);
			pt.ctliface = f.num;
			pt.intrep = f.iin;
			pt.intrmax = f.imax;
			pt.intrival = f.iival;
			ports = pt :: ports;
		}else if(f.class == 255 && f.bin >= 0 && f.bout >= 0){
			case vendor {
			Vftdi =>
				pt := newport(Ftdi, f);
				if(nvendor > 1)
					pt.index = f.num + 1;
				pt.hchip = bcd == 16r700 || bcd == 16r800 || bcd == 16r900;
				ports = pt :: ports;
			Vsilabs =>
				ports = newport(Cp210x, f) :: ports;
			}
		}
	}
	return rev2(ports);
}

#
# The ACM control interface: communications class, abstract control
# model subclass, any protocol but the vendor one (2.2.255 is RNDIS,
# which is Ethernet and etherusb's).
#
isacm(class, sub, proto: int): int
{
	return class == 2 && sub == 2 && proto != 255;
}

dataiface(ifs: list of ref Iface, c: ref Iface): ref Iface
{
	for(l := ifs; l != nil; l = tl l)
		if((hd l).num == c.union && (hd l).bin >= 0 && (hd l).bout >= 0)
			return hd l;
	# no union descriptor: the data interface follows the control one
	seen := 0;
	for(l = ifs; l != nil; l = tl l){
		if(hd l == c)
			seen = 1;
		else if(seen && (hd l).class == 10 && (hd l).bin >= 0 && (hd l).bout >= 0)
			return hd l;
	}
	return nil;
}

newport(fam: int, f: ref Iface): ref Port
{
	p := ref Port;
	p.fam = fam;
	p.n = -1;
	p.iface = f.num;
	p.ctliface = f.num;
	p.index = 0;
	p.inep = f.bin;
	p.outep = f.bout;
	p.maxpkt = f.bmax;
	if(p.maxpkt <= 0)
		p.maxpkt = 64;
	p.intrep = -1;
	p.baud = 9600;
	p.bits = 8;
	p.stop = 1;
	p.parity = 'n';
	p.dtr = 1;
	p.rts = 1;
	p.qlim = Maxq;
	p.nrx = p.ntx = big 0;
	return p;
}

#
# The bulk endpoints, and for ACM the notification one. As diskusb
# learned on a Pi 4: each endpoint's packet size is set before it is
# opened, since opening it is what describes it to the controller.
#
openport(p: ref Port): int
{
	if(p.inep == p.outep){
		if(newep(p.inep, "bulk rw", p.maxpkt, 0) < 0)
			return -1;
		p.bulkin = sys->open(epfile(p.inep, "data"), Sys->ORDWR);
		p.bulkout = p.bulkin;
	}else{
		if(newep(p.inep, "bulk r", p.maxpkt, 0) < 0 || newep(p.outep, "bulk w", p.maxpkt, 0) < 0)
			return -1;
		p.bulkin = sys->open(epfile(p.inep, "data"), Sys->OREAD);
		p.bulkout = sys->open(epfile(p.outep, "data"), Sys->OWRITE);
	}
	if(p.bulkin == nil || p.bulkout == nil){
		sys->print("usbserial: %s: cannot open the bulk endpoints: %r\n", dev);
		return -1;
	}
	if(p.intrep >= 0 && newep(p.intrep, "interrupt r", p.intrmax, p.intrival) < 0)
		p.intrep = -1;	# the line still works; DCD, DSR and RI go unreported
	return 0;
}

newep(ep: int, how: string, maxpkt, ival: int): int
{
	if(sys->fprint(ctlfd, "new %d %s", ep, how) < 0 && !errhas("in use")){
		sys->print("usbserial: %s: cannot create endpoint %d (%s): %r\n", dev, ep, how);
		return -1;
	}
	efd := sys->open(epfile(ep, "ctl"), Sys->OWRITE);
	if(efd != nil){
		sys->fprint(efd, "maxpkt %d", maxpkt);
		if(ival > 0)
			sys->fprint(efd, "pollival %d", ival);
	}
	return 0;
}

epfile(ep: int, f: string): string
{
	return "/usb/usb/" + dev[0:len dev - 1] + string ep + "/" + f;	# epN.0 -> epN.<ep>
}

#
# What a port is set to before anything asks: 9600 8N1, DTR and RTS
# up, which is what eia(3) promises and what boards that wait for DTR
# before they send (many microcontroller ACM ports do) need.
#
setup(p: ref Port): int
{
	case p.fam {
	Ftdi =>
		vout(Freset, 0, p.index, nil);
		vout(Fsetlatency, 4, p.index, nil);	# ms an incomplete packet waits; 16 by default
	Cp210x =>
		if(iout(Cifcenable, 1, p.ctliface, nil) < 0)
			return -1;
	}
	if(setline(p) < 0 || setflow(p) < 0 || setlines(p) < 0)
		return -1;
	return 0;
}

setline(p: ref Port): int
{
	case p.fam {
	Acm =>
		return cout(Asetlinecoding, 0, p.ctliface, acmcoding(p.baud, p.bits, p.parity, p.stop));
	Ftdi =>
		(v, i) := ftdibaud(p.baud, p.hchip);
		if(p.hchip || p.index != 0)
			i = (i << 8) | p.index;
		if(vout(Fsetbaud, v, i, nil) < 0)
			return -1;
		return vout(Fsetdata, ftdidata(p.bits, p.parity, p.stop, 0), p.index, nil);
	Cp210x =>
		b := array[4] of byte;
		put4le(b, 0, p.baud);
		if(iout(Csetbaudrate, 0, p.ctliface, b) < 0)
			return -1;
		return iout(Csetlinectl, cplinectl(p.bits, p.parity, p.stop), p.ctliface, nil);
	}
	return -1;
}

setlines(p: ref Port): int
{
	case p.fam {
	Acm =>
		return cout(Asetlinestate, p.dtr | (p.rts << 1), p.ctliface, nil);
	Ftdi =>
		return vout(Fmodemctrl, 16r0300 | p.dtr | (p.rts << 1), p.index, nil);
	Cp210x =>
		return iout(Csetmhs, 16r0300 | p.dtr | (p.rts << 1), p.ctliface, nil);
	}
	return -1;
}

setflow(p: ref Port): int
{
	case p.fam {
	Acm =>
		if(p.cts || p.xon){
			sys->werrstr("an ACM port has no flow control of its own");
			return -1;
		}
		return 0;
	Ftdi =>
		v := 0;
		f := 0;
		if(p.cts)
			f = 1;
		else if(p.xon){
			f = 4;
			v = (16r13 << 8) | 16r11;	# XOFF, XON
		}
		return vout(Fsetflow, v, (f << 8) | p.index, nil);
	Cp210x =>
		if(p.xon){
			sys->werrstr("XON/XOFF is not done for a CP210x");
			return -1;
		}
		return iout(Csetflow, 0, p.ctliface, cpflow(p.cts, p.rts));
	}
	return -1;
}

brk(p: ref Port, ms: int)
{
	case p.fam {
	Acm =>
		cout(Asendbreak, ms, p.ctliface, nil);
	Ftdi =>
		vout(Fsetdata, ftdidata(p.bits, p.parity, p.stop, 1), p.index, nil);
		sys->sleep(ms);
		vout(Fsetdata, ftdidata(p.bits, p.parity, p.stop, 0), p.index, nil);
	Cp210x =>
		iout(Csetbreak, 1, p.ctliface, nil);
		sys->sleep(ms);
		iout(Csetbreak, 0, p.ctliface, nil);
	}
}

flushout(p: ref Port)
{
	case p.fam {
	Ftdi =>
		vout(Freset, Fpurgetx, p.index, nil);
	Cp210x =>
		iout(Cpurge, 16r05, p.ctliface, nil);	# the transmit queue and FIFO
	}
}

#
# The modem lines, for the families that are asked rather than told.
#
pollmodem(p: ref Port)
{
	if(p.fam != Cp210x)
		return;
	b := array[1] of byte;
	if(ctlin(Rd2h|Rvendor|Riface, Cgetmdmsts, 0, p.ctliface, b) == 1){
		s := int b[0];
		p.incts = (s & 16r10) != 0;
		p.indsr = (s & 16r20) != 0;
		p.inri = (s & 16r40) != 0;
		p.indcd = (s & 16r80) != 0;
	}
}

#
# The encodings, which are where drivers like this go wrong, and which
# selftest() checks against known values.
#

# CDC line coding: rate, stop bits (0 1, 1 1.5, 2 2), parity, data bits
acmcoding(baud, bits, parity, stop: int): array of byte
{
	b := array[7] of byte;
	put4le(b, 0, baud);
	b[4] = byte stopcode(stop);
	b[5] = byte paritycode(parity);
	b[6] = byte bits;
	return b;
}

# FTDI SET_DATA: data bits, parity << 8, stop << 11, break << 14
ftdidata(bits, parity, stop, brk: int): int
{
	return bits | (paritycode(parity) << 8) | (stopcode(stop) << 11) | (brk << 14);
}

#
# FTDI baud divisor, as (wValue, high bits for wIndex). The chip
# divides its clock (3 MHz on the BM/R, 12 MHz on an H chip with the
# divide-by-2.5 turned off) by an integer and an eighth-step fraction,
# whose code is not the eighth itself: {0, 3, 2, 4, 1, 5, 6, 7}.
#
ftdibaud(baud, hchip: int): (int, int)
{
	if(baud <= 0)
		baud = 9600;
	frac := array[] of {0, 3, 2, 4, 1, 5, 6, 7};
	d3: int;
	h := hchip && baud >= 1200;
	if(h)
		d3 = (8*120000000/10 + baud/2) / baud;
	else
		d3 = (48000000/2 + baud/2) / baud;
	d := (d3 >> 3) | (frac[d3 & 7] << 14);
	if(d == 1)
		d = 0;		# 1.0: the chip's special case for its top rate
	else if(d == 16r4001)
		d = 1;		# 1.5
	if(h)
		d |= 16r20000;
	return (d & 16rFFFF, d >> 16);
}

# CP210x SET_LINE_CTL: stop bits, parity << 4, data bits << 8
cplinectl(bits, parity, stop: int): int
{
	return stopcode(stop) | (paritycode(parity) << 4) | (bits << 8);
}

# CP210x SET_FLOW: control handshake, flow replace, XON and XOFF limits
cpflow(cts, rts: int): array of byte
{
	b := array[16] of {* => byte 0};
	hs := 16r01;		# DTR held active
	fr := 0;
	if(cts){
		hs |= 16r08;	# transmit only while CTS is up
		fr = 16r80;	# RTS as receive flow control
	}else if(rts)
		fr = 16r40;	# RTS held active
	put4le(b, 0, hs);
	put4le(b, 4, fr);
	put4le(b, 8, 128);
	put4le(b, 12, 128);
	return b;
}

stopcode(stop: int): int
{
	if(stop == 2)
		return 2;
	return 0;
}

paritycode(c: int): int
{
	case c {
	'o' =>	return 1;
	'e' =>	return 2;
	'm' =>	return 3;
	's' =>	return 4;
	}
	return 0;
}

#
# Serving. Three files per port, in #seia; one process holds the line's
# state and answers them, one reads the bulk IN endpoint, one writes
# the OUT one (so that a write held up by flow control does not hold up
# the status file), and for ACM one reads the notifications.
#
Rx: adt {
	data:	array of byte;
	st0, st1:	int;	# ftdi's status bytes, or -1
};

serve(p: ref Port): int
{
	i: int;
	for(i = 0; i < Maxports; i++){
		(ok, nil) := sys->stat("#seia/eiaU" + string i);
		if(ok < 0)
			break;
	}
	if(i == Maxports){
		sys->print("usbserial: %d ports are enough\n", Maxports);
		return -1;
	}
	p.n = i;
	name := "eiaU" + string i;
	data := sys->file2chan("#seia", name);
	ctl := sys->file2chan("#seia", name + "ctl");
	status := sys->file2chan("#seia", name + "status");
	if(data == nil || ctl == nil || status == nil){
		sys->print("usbserial: cannot serve %s: %r\n", name);
		return -1;
	}
	sys->print("usbserial: %s %#4.4x:%#4.4x (%s) served as /dev/%s\n",
		dev, vendor, product, famname[p.fam], name);
	rx := chan of ref Rx;
	tx := chan[64] of (array of byte, chan of (int, string));
	notes := chan of int;
	spawn reader(p, rx);
	spawn writer(p, tx);
	if(p.intrep >= 0)
		spawn notifier(p, notes);
	spawn port(p, data, ctl, status, rx, tx, notes);
	return 0;
}

Pending: adt {
	n:	int;
	fid:	int;
	rc:	chan of (array of byte, string);
};

port(p: ref Port, data, ctl, status: ref Sys->FileIO,
	rx: chan of ref Rx, tx: chan of (array of byte, chan of (int, string)), notes: chan of int)
{
	q: list of array of byte;	# received, oldest first
	nq := 0;
	waiting: list of ref Pending;
	gone := 0;
	for(;;){
		alt {
		r := <-rx =>
			if(r == nil){
				gone = 1;
				for(; waiting != nil; waiting = tl waiting)
					reply((hd waiting).rc, nil, "hungup");
				sys->print("usbserial: %s detached; /dev/eiaU%d is gone\n", dev, p.n);
				tx <-= (nil, nil);	# the writer's cue to go
				return;
			}
			if(r.st0 >= 0)
				ftdistatus(p, r.st0, r.st1);
			if(len r.data > 0){
				p.nrx += big len r.data;
				q = append(q, r.data);
				nq += len r.data;
				while(nq > p.qlim && q != nil){
					nq -= len hd q;
					p.oerr++;
					q = tl q;
				}
			}
		s := <-notes =>
			acmstate(p, s);
		(nil, n, fid, rc) := <-data.read =>
			if(rc == nil){
				#
				# The file was closed. A reader that was killed in its
				# read closes it, and its read is still in the queue
				# with nobody at the other end of its channel: given
				# data, it would swallow it. (It did, 4096 bytes of a
				# megabyte, on the first transfer on a board.)
				#
				waiting = dropfid(waiting, fid);
				break;
			}
			if(gone){
				reply(rc, nil, "hungup");
				break;
			}
			waiting = append2(waiting, ref Pending(n, fid, rc));
		(nil, d, fid, wc) := <-data.write =>
			if(wc == nil){
				waiting = dropfid(waiting, fid);
				break;
			}
			p.ntx += big len d;
			tx <-= (d, wc);
		(off, n, nil, rc) := <-status.read =>
			if(rc == nil)
				break;
			pollmodem(p);
			reply(rc, readstr(off, n, statustext(p)), nil);
		(nil, nil, nil, wc) := <-status.write =>
			if(wc != nil)
				wreply(wc, 0, "status is read-only");
		(off, n, nil, rc) := <-ctl.read =>
			if(rc == nil)
				break;
			reply(rc, readstr(off, n, statustext(p)), nil);
		(nil, d, nil, wc) := <-ctl.write =>
			if(wc == nil)
				break;
			err := ctlmsg(p, string d);
			if(err == "h"){
				# hang up: the readers get end of file, the queue is emptied
				for(; waiting != nil; waiting = tl waiting)
					reply((hd waiting).rc, array[0] of byte, nil);
				q = nil;
				nq = 0;
				err = nil;
			}
			if(err != nil)
				wreply(wc, 0, err);
			else
				wreply(wc, len d, nil);
		}
		# whatever has arrived goes to whoever is waiting, oldest first
		while(waiting != nil && q != nil){
			w := hd waiting;
			waiting = tl waiting;
			b := hd q;
			if(len b > w.n){
				q = b[w.n:] :: tl q;
				b = b[0:w.n];
			}else
				q = tl q;
			nq -= len b;
			reply(w.rc, b, nil);
		}
	}
}

#
# Replies are offered, not forced: a reader that was interrupted has
# gone, and its reply channel with it.
#
reply(rc: chan of (array of byte, string), b: array of byte, err: string)
{
	alt {
	rc <-= (b, err) =>
		;
	* =>
		;
	}
}

wreply(wc: chan of (int, string), n: int, err: string)
{
	alt {
	wc <-= (n, err) =>
		;
	* =>
		;
	}
}

reader(p: ref Port, rx: chan of ref Rx)
{
	n := p.maxpkt;
	if(p.fam != Ftdi)
		n = 8 * p.maxpkt;
	buf := array[n] of byte;
	nerr := 0;
	for(;;){
		m := sys->read(p.bulkin, buf, len buf);
		if(m < 0){
			if(errhas("detached") || ++nerr > 10){
				rx <-= nil;
				return;
			}
			sys->sleep(100);
			continue;
		}
		nerr = 0;
		if(p.fam == Ftdi){
			# two status bytes at the head of every packet, even an empty one
			for(o := 0; o + 2 <= m; o += p.maxpkt){
				e := o + p.maxpkt;
				if(e > m)
					e = m;
				d := array[e - (o+2)] of byte;
				d[0:] = buf[o+2:e];
				rx <-= ref Rx(d, int buf[o], int buf[o+1]);
			}
			continue;
		}
		if(m > 0){
			d := array[m] of byte;
			d[0:] = buf[0:m];
			rx <-= ref Rx(d, -1, -1);
		}
	}
}

writer(p: ref Port, tx: chan of (array of byte, chan of (int, string)))
{
	for(;;){
		(d, wc) := <-tx;
		if(wc == nil)
			return;
		n := sys->write(p.bulkout, d, len d);
		if(n < 0)
			wreply(wc, -1, sys->sprint("%r"));
		else
			wreply(wc, n, nil);
	}
}

notifier(p: ref Port, notes: chan of int)
{
	fd := sys->open(epfile(p.intrep, "data"), Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[64] of byte;
	for(;;){
		m := sys->read(fd, buf, len buf);
		if(m < 0)
			return;
		# SERIAL_STATE: an 8-byte request header, then two bytes of state
		if(m >= 10 && int buf[1] == Aserialstate)
			notes <-= get2le(buf, 8);
	}
}

acmstate(p: ref Port, s: int)
{
	odcd := p.indcd;
	odsr := p.indsr;
	p.indcd = (s & 16r01) != 0;
	p.indsr = (s & 16r02) != 0;
	p.inri = (s & 16r08) != 0;
	if(s & 16r04)
		p.brk++;
	if(s & 16r10)
		p.ferr++;
	if(s & 16r20)
		p.perr++;
	if(s & 16r40)
		p.oerr++;
	droplines(p, odcd, odsr);
}

ftdistatus(p: ref Port, s0, s1: int)
{
	odcd := p.indcd;
	odsr := p.indsr;
	p.incts = (s0 & 16r10) != 0;
	p.indsr = (s0 & 16r20) != 0;
	p.inri = (s0 & 16r40) != 0;
	p.indcd = (s0 & 16r80) != 0;
	if(s1 & 16r02)
		p.oerr++;
	if(s1 & 16r04)
		p.perr++;
	if(s1 & 16r08)
		p.ferr++;
	if(s1 & 16r10)
		p.brk++;
	droplines(p, odcd, odsr);
}

#
# eia(3)'s c1 and e1: the remote dropping DCD or DSR hangs the line up,
# which for a USB port means dropping DTR, as a modem expects.
#
droplines(p: ref Port, odcd, odsr: int)
{
	if((p.hupdcd && odcd && !p.indcd) || (p.hupdsr && odsr && !p.indsr)){
		p.dtr = 0;
		setlines(p);
	}
}

#
# eia(3)'s control messages, one or more to a write. Returns nil, an
# error, or "h" for a hangup, which the caller does to the queues.
#
ctlmsg(p: ref Port, s: string): string
{
	hup := 0;
	line := 0;	# the rate or framing changed: set once, after every word is read
	(ob, ol, op, os) := (p.baud, p.bits, p.parity, p.stop);
	(nil, words) := sys->tokenize(s, " \t\n");
	for(; words != nil; words = tl words){
		w := hd words;
		c := w[0];
		arg := w[1:];
		n := int arg;
		if(len arg == 0)
			n = 0;
		err := "";
		case c {
		'b' or 'B' =>
			if(n <= 0)
				return "bad baud rate " + arg;
			p.baud = n;
			line = 1;
		'l' or 'L' =>
			if(n < 5 || n > 8)
				return "bad bits per byte " + arg;
			p.bits = n;
			line = 1;
		'p' or 'P' =>
			pc := 'n';
			if(len arg > 0)
				pc = arg[0];
			case pc {
			'o' or 'e' or 'm' or 's' or 'n' =>
				p.parity = pc;
			* =>
				p.parity = 'n';
			}
			line = 1;
		's' or 'S' =>
			if(n != 1 && n != 2)
				return "bad stop bits " + arg;
			p.stop = n;
			line = 1;
		'd' or 'D' =>
			p.dtr = n != 0;
			if(setlines(p) < 0)
				err = "dtr";
		'r' or 'R' =>
			p.rts = n != 0;
			if(setlines(p) < 0 || (p.fam == Cp210x && setflow(p) < 0))
				err = "rts";
		'm' or 'M' =>
			p.cts = n != 0;
			if(setflow(p) < 0){
				p.cts = 0;
				return sys->sprint("%r");
			}
		'x' or 'X' =>
			p.xon = n != 0;
			if(setflow(p) < 0){
				p.xon = 0;
				return sys->sprint("%r");
			}
		'c' or 'C' =>
			p.hupdcd = n != 0;
		'e' or 'E' =>
			p.hupdsr = n != 0;
		'k' or 'K' =>
			if(n <= 0)
				n = 250;
			brk(p, n);
		'f' or 'F' =>
			flushout(p);
		'h' or 'H' =>
			hup = 1;
		'q' or 'Q' =>
			if(n > 0)
				p.qlim = n;
		'n' or 'N' or 'i' or 'I' =>
			;	# non-blocking output, FIFO depth: nothing to set on an adapter
		* =>
			return "unknown control message " + w;
		}
		if(err != "")
			return sys->sprint("setting %s: %r", err);
	}
	if(line && setline(p) < 0){
		err := sys->sprint("setting the line: %r");
		(p.baud, p.bits, p.parity, p.stop) = (ob, ol, op, os);
		return err;
	}
	if(hup)
		return "h";
	return nil;
}

#
# The status file, as the board's own UARTs and Plan 9's write it: the
# settings, then what the line reports, the input lines by name.
#
statustext(p: ref Port): string
{
	s := sys->sprint("b%d c%d d%d e%d l%d m%d p%c r%d s%d i0\n",
		p.baud, p.hupdcd, p.dtr, p.hupdsr, p.bits, p.cts, p.parity, p.rts, p.stop);
	s += sys->sprint("dev(U%d) type(usb-%s) %#4.4x:%#4.4x framing(%d) overruns(%d) parity(%d) breaks(%d) rx(%bd) tx(%bd)",
		p.n, famname[p.fam], vendor, product, p.ferr, p.oerr, p.perr, p.brk, p.nrx, p.ntx);
	if(p.incts)
		s += " CTS";
	if(p.indsr)
		s += " DSR";
	if(p.indcd)
		s += " DCD";
	if(p.inri)
		s += " RING";
	return s + "\n";
}

readstr(off, n: int, s: string): array of byte
{
	b := array of byte s;
	if(off >= len b)
		return array[0] of byte;
	e := off + n;
	if(e > len b)
		e = len b;
	return b[off:e];
}

#
# Control transfers: to the device (FTDI), to an interface as vendor
# requests (CP210x), to an interface as class requests (ACM).
#
vout(req, value, index: int, data: array of byte): int
{
	return ctlout(Rh2d|Rvendor|Rdev, req, value, index, data);
}

iout(req, value, index: int, data: array of byte): int
{
	return ctlout(Rh2d|Rvendor|Riface, req, value, index, data);
}

cout(req, value, index: int, data: array of byte): int
{
	return ctlout(Rh2d|Rclass|Riface, req, value, index, data);
}

ctlin(rtype, req, value, index: int, data: array of byte): int
{
	setup := array[8] of byte;
	setup[0] = byte rtype;
	setup[1] = byte req;
	put2le(setup, 2, value);
	put2le(setup, 4, index);
	put2le(setup, 6, len data);
	if(sys->write(ep0, setup, len setup) != len setup)
		return -1;
	return sys->read(ep0, data, len data);
}

ctlout(rtype, req, value, index: int, data: array of byte): int
{
	dlen := 0;
	if(data != nil)
		dlen = len data;
	buf := array[8 + dlen] of byte;
	buf[0] = byte rtype;
	buf[1] = byte req;
	put2le(buf, 2, value);
	put2le(buf, 4, index);
	put2le(buf, 6, dlen);
	if(dlen > 0)
		buf[8:] = data;
	if(sys->write(ep0, buf, len buf) != len buf)
		return -1;
	rep := array[8] of byte;
	sys->read(ep0, rep, len rep);	# collect the (empty) reply: devusb parks it otherwise
	return 0;
}

errhas(what: string): int
{
	e := sys->sprint("%r");
	for(i := 0; i + len what <= len e; i++)
		if(e[i:i+len what] == what)
			return 1;
	return 0;
}

get2le(a: array of byte, off: int): int
{
	return int a[off] | (int a[off+1] << 8);
}

put2le(a: array of byte, off, v: int)
{
	a[off] = byte v;
	a[off+1] = byte (v >> 8);
}

put4le(a: array of byte, off, v: int)
{
	a[off] = byte v;
	a[off+1] = byte (v >> 8);
	a[off+2] = byte (v >> 16);
	a[off+3] = byte (v >> 24);
}

append(l: list of array of byte, b: array of byte): list of array of byte
{
	if(l == nil)
		return b :: nil;
	return hd l :: append(tl l, b);
}

dropfid(l: list of ref Pending, fid: int): list of ref Pending
{
	r: list of ref Pending;
	for(; l != nil; l = tl l)
		if((hd l).fid != fid)
			r = hd l :: r;
	k: list of ref Pending;
	for(; r != nil; r = tl r)
		k = hd r :: k;
	return k;
}

append2(l: list of ref Pending, p: ref Pending): list of ref Pending
{
	if(l == nil)
		return p :: nil;
	return hd l :: append2(tl l, p);
}

rev(l: list of ref Iface): list of ref Iface
{
	r: list of ref Iface;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

rev2(l: list of ref Port): list of ref Port
{
	r: list of ref Port;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

#
# The encodings against values known from the chips' documentation and
# from other drivers, and the descriptor walk against a real device's
# descriptors -- the parts an emulator without the adapter cannot reach.
#
selftest()
{
	fails := 0;
	check := array[] of {
		# FTDI BM/R: 9600 -> 0x4138, 115200 -> 0x001A, 3000000 -> 0, 2000000 -> 1, 300 -> 0x2710
		(9600, 0, 16r4138, 0),
		(115200, 0, 16r001A, 0),
		(38400, 0, 16rC04E, 0),
		(3000000, 0, 0, 0),
		(2000000, 0, 1, 0),
		(300, 0, 16r2710, 0),
		# FTDI H chips, 12 MHz: 115200 is 104 1/8 (fraction code 3), with bit 17
		(115200, 1, 16rC068, 2),
		(12000000, 1, 0, 2),
		# an H chip below 1200 baud uses the 3 MHz clock
		(300, 1, 16r2710, 0),
	};
	for(i := 0; i < len check; i++){
		(baud, h, wv, wi) := check[i];
		(v, x) := ftdibaud(baud, h);
		if(v != wv || x != wi){
			sys->print("usbserial: selftest: ftdi %d baud (H %d): %#x %#x, want %#x %#x\n",
				baud, h, v, x, wv, wi);
			fails++;
		}
	}
	if(ftdidata(8, 'n', 1, 0) != 16r0008 || ftdidata(7, 'e', 2, 0) != 16r1207 || ftdidata(8, 'n', 1, 1) != 16r4008){
		sys->print("usbserial: selftest: ftdi line data\n");
		fails++;
	}
	if(cplinectl(8, 'n', 1) != 16r0800 || cplinectl(7, 'o', 2) != 16r0712){
		sys->print("usbserial: selftest: cp210x line control\n");
		fails++;
	}
	c := acmcoding(115200, 8, 'e', 2);
	if(c[0] != byte 0 || c[1] != byte 16rC2 || c[2] != byte 1 || c[3] != byte 0
	|| c[4] != byte 2 || c[5] != byte 2 || c[6] != byte 8){
		sys->print("usbserial: selftest: acm line coding\n");
		fails++;
	}

	# a Raspberry Pi Pico's configuration: an IAD, ACM control (2.2.0,
	# interrupt 0x81) with a union naming interface 1, data (10.0.0,
	# bulk 0x02 out and 0x82 in), then a vendor reset interface
	pico := array[] of {
		byte 9, byte 2, byte 84, byte 0, byte 3, byte 1, byte 0, byte 16r80, byte 125,
		byte 8, byte 11, byte 0, byte 2, byte 2, byte 2, byte 0, byte 0,
		byte 9, byte 4, byte 0, byte 0, byte 1, byte 2, byte 2, byte 0, byte 4,
		byte 5, byte 16r24, byte 0, byte 16r20, byte 1,
		byte 5, byte 16r24, byte 1, byte 0, byte 1,
		byte 4, byte 16r24, byte 2, byte 2,
		byte 5, byte 16r24, byte 6, byte 0, byte 1,
		byte 7, byte 5, byte 16r81, byte 3, byte 8, byte 0, byte 16,
		byte 9, byte 4, byte 1, byte 0, byte 2, byte 10, byte 0, byte 0, byte 0,
		byte 7, byte 5, byte 16r02, byte 2, byte 64, byte 0, byte 0,
		byte 7, byte 5, byte 16r82, byte 2, byte 64, byte 0, byte 0,
		byte 9, byte 4, byte 2, byte 0, byte 0, byte 255, byte 0, byte 1, byte 5,
	};
	vendor = 16r2E8A;
	ps := findports(pico);
	if(len ps != 1 || (hd ps).fam != Acm || (hd ps).ctliface != 0 || (hd ps).iface != 1
	|| (hd ps).inep != 2 || (hd ps).outep != 2 || (hd ps).intrep != 1 || (hd ps).maxpkt != 64){
		sys->print("usbserial: selftest: the Pico's ACM port was not found as it is\n");
		fails++;
	}

	# an RNDIS device (2.2.255 + data) is Ethernet, not a serial port
	rndis := array[len pico] of byte;
	rndis[0:] = pico;
	rndis[24] = byte 255;
	if(findports(rndis) != nil){
		sys->print("usbserial: selftest: RNDIS was taken for a serial port\n");
		fails++;
	}

	# an FT2232: two vendor interfaces, so wIndex 1 and 2
	ft2232 := array[] of {
		byte 9, byte 2, byte 55, byte 0, byte 2, byte 1, byte 0, byte 16r80, byte 45,
		byte 9, byte 4, byte 0, byte 0, byte 2, byte 255, byte 255, byte 255, byte 2,
		byte 7, byte 5, byte 16r81, byte 2, byte 64, byte 0, byte 0,
		byte 7, byte 5, byte 16r02, byte 2, byte 64, byte 0, byte 0,
		byte 9, byte 4, byte 1, byte 0, byte 2, byte 255, byte 255, byte 255, byte 2,
		byte 7, byte 5, byte 16r83, byte 2, byte 64, byte 0, byte 0,
		byte 7, byte 5, byte 16r04, byte 2, byte 64, byte 0, byte 0,
	};
	vendor = Vftdi;
	bcd = 16r500;
	ps = findports(ft2232);
	if(len ps != 2 || (hd ps).index != 1 || (hd tl ps).index != 2 || (hd tl ps).inep != 3 || (hd tl ps).outep != 4){
		sys->print("usbserial: selftest: the FT2232's two ports\n");
		fails++;
	}
	vendor = 16r1234;
	if(findports(ft2232) != nil){
		sys->print("usbserial: selftest: a vendor interface of an unknown maker was taken\n");
		fails++;
	}

	if(fails == 0)
		sys->print("usbserial: selftest OK\n");
	else
		sys->print("usbserial: selftest FAILED (%d)\n", fails);
}
