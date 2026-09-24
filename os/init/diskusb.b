implement Diskusb;

#
# A USB disk: the mass-storage class, bulk-only transport, SCSI
# transparent command set -- every USB stick, card reader and external
# drive made this century.
#
# What it does: finds the device's pair of bulk endpoints, asks the
# disk what it is (INQUIRY), waits for it to be ready, asks how big it
# is (READ CAPACITY), and then serves the whole disk as ONE file,
# /chan/usbdiskN, whose reads and writes at an offset become READ(10)
# and WRITE(10) commands. dossrv reads the partition table itself, so
# the FAT partition of that file is mounted on /n/usbN by the same
# route the SD card takes. A disk with no FAT on it is still there as
# the block file.
#
# A program rather than kernel code, like the other USB class drivers
# here (kbdusb, mouseusb, etherusb): the transport is three messages
# on two endpoints and the kernel knows nothing of it. Written from the
# specifications (USB Mass Storage Bulk-Only 1.0; SCSI SBC/SPC) with
# 9front's nusb/disk beside them for the quirks that matter --
# a status read that stalls is retried after clearing the halt; a
# status with the wrong tag is read again; a phase error resets the
# transport.
#
# NOT DONE: more than one logical unit (only LUN 0 is served; a card
# reader with several slots shows its first), READ(16) beyond 2TB (the
# capacity is read, the disk is refused), removable media that comes
# and goes while plugged in, and any queueing: one command at a time,
# which is what a FAT filesystem asks for anyway.
#
# Tested on QEMU's usb-storage behind its xHCI controller (the virt
# machine), at SuperSpeed. Never yet on a real disk.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Diskusb: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

# control requests
Rh2d:		con 16r00;
Rd2h:		con 16r80;
Rstd:		con 16r00;
Rclass:		con 16r20;
Rdev:		con 0;
Riface:		con 1;
Rendpt:		con 2;
Rgetdesc:	con 6;
Rclrfeature:	con 1;
Fendpthalt:	con 0;
Dconf:		con 2;

# mass storage class requests
Rmsreset:	con 16rFF;	# bulk-only mass storage reset
Rgetmaxlun:	con 16rFE;

# bulk-only transport
Cbwlen:		con 31;
Cswlen:		con 13;
Cbwdatain:	con 16r80;
Cbwdataout:	con 16r00;
Cswok:		con 0;
Cswfailed:	con 1;
Cswphase:	con 2;

# SCSI commands
Ctestready:	con 16r00;
Crequestsense:	con 16r03;
Cinquiry:	con 16r12;
Cstartstop:	con 16r1B;
Creadcap10:	con 16r25;
Cread10:	con 16r28;
Cwrite10:	con 16r2A;
Creadcap16:	con 16r9E;	# service action in

Maxio:		con 64*1024;	# one command moves at most this much
Maxretry:	con 3;
Readyms:	con 250;	# between TEST UNIT READY attempts
Pollms:		con 2000;	# how often an idle disk is asked if it is still there

dev: string;			# devusb's name for the device: epN.0
ctlfd: ref Sys->FD;
ep0: ref Sys->FD;
bulkin: ref Sys->FD;
bulkout: ref Sys->FD;
inep, outep, maxpkt: int;
tag := 1;
blocks := big 0;		# how many
bsize := 0;			# how big each
name := "";			# /chan/usbdiskN

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	if(args == nil){
		sys->print("diskusb: no device given\n");
		return;
	}
	dev = hd args;

	ctlfd = sys->open("/usb/usb/" + dev + "/ctl", Sys->ORDWR);
	ep0 = sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
	if(ctlfd == nil || ep0 == nil){
		sys->print("diskusb: cannot open %s: %r\n", dev);
		return;
	}

	(inep, outep, maxpkt) = bulkeps();
	if(inep < 0 || outep < 0 || inep == outep){
		sys->print("diskusb: %s: no pair of bulk endpoints\n", dev);
		return;
	}
	if(openbulk() < 0)
		return;

	#
	# GET MAX LUN. A device with one unit may STALL this rather than
	# answer 0; either way LUN 0 is what is served.
	#
	lun := array[1] of byte;
	if(ctlin(Rd2h|Rclass|Riface, Rgetmaxlun, 0, 0, lun) == 1 && int lun[0] > 0)
		sys->print("diskusb: %s has %d logical units; only the first is served\n", dev, int lun[0] + 1);

	inq := array[36] of byte;
	if(scsi(array[] of {byte Cinquiry, byte 0, byte 0, byte 0, byte len inq, byte 0}, inq, 0) < 0){
		sys->print("diskusb: %s: INQUIRY failed: %r\n", dev);
		return;
	}
	dtype := int inq[0] & 16r1F;
	if(dtype != 0 && dtype != 5 && dtype != 7 && dtype != 14){
		sys->print("diskusb: %s is not a disk (SCSI device type %d)\n", dev, dtype);
		return;
	}
	what := trim(string inq[8:16]) + " " + trim(string inq[16:32]);

	if(ready() < 0){
		sys->print("diskusb: %s (%s): not ready, no medium: %r\n", dev, what);
		return;
	}
	if(capacity() < 0){
		sys->print("diskusb: %s (%s): READ CAPACITY failed: %r\n", dev, what);
		return;
	}
	if(bsize < 512 || bsize > 4096 || bsize % 512 != 0){
		sys->print("diskusb: %s (%s): block size %d is not one this driver serves\n", dev, what, bsize);
		return;
	}
	if(blocks > big 16r100000000){
		sys->print("diskusb: %s (%s): %bd blocks is beyond READ(10); not served\n", dev, what, blocks);
		return;
	}

	fio := serve();
	if(fio == nil)
		return;
	mb := (blocks * big bsize) / big (1024*1024);
	sys->print("diskusb: %s %s: %bd blocks of %d bytes (%bd MB), served as %s\n",
		dev, what, blocks, bsize, mb, name);

	spawn mountfat();
	loop(fio);
}

#
# The file: reads and writes at an offset, served one at a time, and
# between them the disk is asked now and then whether it is still
# there, so that an unplugged one is noticed before anything asks for
# a block. dossrv holds the file open and does 512-byte sector reads
# at sector offsets; anything else is served too, by reading whole
# blocks around it.
#
loop(fio: ref Sys->FileIO)
{
	tick := chan of int;
	spawn ticker(tick);
	for(;;) alt {
	(off, n, nil, rc) := <-fio.read =>
		if(rc == nil)
			break;
		(data, err) := diskread(big off, n);
		rc <-= (data, err);
		if(err != nil && detached(err))
			return;
	(off, data, nil, wc) := <-fio.write =>
		if(wc == nil)
			break;
		(n, err) := diskwrite(big off, data);
		wc <-= (n, err);
		if(err != nil && detached(err))
			return;
	<-tick =>
		if(scsi(array[6] of {* => byte 0}, nil, 0) < 0 && isdetached()){
			sys->print("diskusb: %s detached; %s is gone\n", dev, name);
			return;
		}
	}
}

ticker(c: chan of int)
{
	for(;;){
		sys->sleep(Pollms);
		c <-= 1;
	}
}

detached(err: string): int
{
	for(i := 0; i + 8 <= len err; i++)
		if(err[i:i+8] == "detached"){
			sys->print("diskusb: %s detached; %s is gone\n", dev, name);
			return 1;
		}
	return 0;
}

diskread(off: big, n: int): (array of byte, string)
{
	if(off < big 0 || n <= 0)
		return (nil, nil);
	end := off + big n;
	if(end > blocks * big bsize)
		end = blocks * big bsize;
	if(end <= off)
		return (nil, nil);
	lba := off / big bsize;
	last := (end - big 1) / big bsize;
	nb := int (last - lba) + 1;
	buf := array[nb * bsize] of byte;
	for(done := 0; done < nb; ){
		chunk := nb - done;
		if(chunk * bsize > Maxio)
			chunk = Maxio / bsize;
		if(rw(Cread10, lba + big done, buf[done*bsize:(done+chunk)*bsize], 0) < 0)
			return (nil, sys->sprint("%s: read at %bd: %r", name, off));
		done += chunk;
	}
	skip := int (off - lba * big bsize);
	return (buf[skip:skip + int (end - off)], nil);
}

diskwrite(off: big, data: array of byte): (int, string)
{
	if(off < big 0)
		return (-1, "negative offset");
	n := len data;
	end := off + big n;
	if(end > blocks * big bsize)
		return (-1, "write beyond the end of " + name);
	if(n == 0)
		return (0, nil);
	lba := off / big bsize;
	last := (end - big 1) / big bsize;
	nb := int (last - lba) + 1;
	skip := int (off - lba * big bsize);
	buf := data;
	if(skip != 0 || n % bsize != 0){
		# not whole blocks: read what is there, lay the write over it
		(old, err) := diskread(lba * big bsize, nb * bsize);
		if(err != nil)
			return (-1, err);
		buf = array[nb * bsize] of byte;
		buf[0:] = old;
		buf[skip:] = data;
	}
	for(done := 0; done < nb; ){
		chunk := nb - done;
		if(chunk * bsize > Maxio)
			chunk = Maxio / bsize;
		if(rw(Cwrite10, lba + big done, buf[done*bsize:(done+chunk)*bsize], 1) < 0)
			return (-1, sys->sprint("%s: write at %bd: %r", name, off));
		done += chunk;
	}
	return (n, nil);
}

rw(op: int, lba: big, buf: array of byte, out: int): int
{
	nb := len buf / bsize;
	cmd := array[10] of byte;
	cmd[0] = byte op;
	cmd[1] = byte 0;
	put4(cmd, 2, int lba);
	cmd[6] = byte 0;
	cmd[7] = byte (nb >> 8);
	cmd[8] = byte nb;
	cmd[9] = byte 0;
	for(try := 0; try < Maxretry; try++){
		n := scsi(cmd, buf, out);
		if(n == len buf)
			return 0;
		if(n >= 0)
			sys->print("diskusb: %s: short %s: %d of %d bytes\n", name, opname(op), n, len buf);
		if(isdetached())
			return -1;
	}
	return -1;
}

opname(op: int): string
{
	if(op == Cread10)
		return "read";
	return "write";
}

#
# The FAT partition, if there is one, by the road the SD card takes:
# dossrv finds the partition in the file's MBR itself. A disk with no
# FAT on it says so and stays a block file.
#
# WHOSE NAMESPACE. This mount lands in init's, which is the namespace
# the network console's shells are forked from -- so over the network
# console a disk is simply there at /n/usbN. The console shell forked
# its namespace when it started (sh -l), before any USB driver ran,
# and init does not hold it back for the USB walk on purpose (osinit.b
# says why); so from THAT shell, or the desktop, the disk is reached
# by mounting it oneself, which is one command on the block file --
# the block file is served through #s and is in every namespace:
#
#	dossrv -f /chan/usbdisk0 -m /n/usb0
#
mountfat()
{
	srv := load Command "/dis/dossrv.dis";
	if(srv == nil){
		sys->print("diskusb: cannot load dossrv: %r\n");
		return;
	}
	mnt := "/n/usb" + name[len "/chan/usbdisk":];
	{
		srv->init(nil, "dossrv" :: "-f" :: name :: "-m" :: mnt :: nil);
		sys->print("diskusb: %s mounted on %s for init and the network console; elsewhere: dossrv -f %s -m %s\n", name, mnt, name, mnt);
	} exception e {
	"*" =>
		sys->print("diskusb: %s: no FAT filesystem mounted: %s\n", name, e);
	}
}

#
# The first free /chan/usbdiskN. A driver that has gone takes its file
# with it, so the numbers are reused.
#
serve(): ref Sys->FileIO
{
	for(i := 0; i < 16; i++){
		n := "usbdisk" + string i;
		(ok, nil) := sys->stat("/chan/" + n);
		if(ok >= 0)
			continue;
		fio := sys->file2chan("/chan", n);
		if(fio == nil){
			sys->print("diskusb: cannot serve /chan/%s: %r\n", n);
			return nil;
		}
		name = "/chan/" + n;
		#
		# Say how big it is: a served file is born with length 0, and
		# dossrv bounds its reads by the device's length when there is
		# one. devsrv takes a wstat of the length alone.
		#
		d := sys->nulldir;
		d.length = blocks * big bsize;
		d.mode = 8r666;		# said outright: devsrv takes nulldir's ~0 for a mode, exclusive-use bit and all
		if(sys->wstat(name, d) < 0)
			sys->print("diskusb: cannot set the length of %s: %r\n", name);
		return fio;
	}
	sys->print("diskusb: sixteen disks are enough\n");
	return nil;
}

#
# TEST UNIT READY until it says so; a unit that is "becoming ready" is
# given its time, one with no medium is not.
#
ready(): int
{
	for(try := 0; try < 8; try++){
		if(scsi(array[6] of {* => byte 0}, nil, 0) >= 0)
			return 0;
		sense := array[18] of byte;
		if(scsi(array[] of {byte Crequestsense, byte 0, byte 0, byte 0, byte len sense, byte 0}, sense, 0) < 0)
			return -1;
		key := int sense[2] & 16rF;
		asc := int sense[12];
		if(key == 2 && asc == 16r3A){	# not ready: medium not present
			sys->werrstr("no medium");
			return -1;
		}
		if(key == 2 && asc == 16r04 && int sense[13] == 2){	# initializing command required
			scsi(array[] of {byte Cstartstop, byte 0, byte 0, byte 0, byte 1, byte 0}, nil, 0);
		}
		sys->sleep(Readyms);
	}
	sys->werrstr("still not ready");
	return -1;
}

capacity(): int
{
	cap := array[8] of byte;
	if(scsi(array[10] of {byte Creadcap10, * => byte 0}, cap, 0) < 0)
		return -1;
	last := get4(cap, 0);
	bsize = get4(cap, 4);
	if(last == -1){
		# more than 2^32 blocks: ask with READ CAPACITY(16), to say so
		cap16 := array[32] of byte;
		cmd := array[16] of {* => byte 0};
		cmd[0] = byte Creadcap16;
		cmd[1] = byte 16r10;
		cmd[13] = byte len cap16;
		if(scsi(cmd, cap16, 0) < 0)
			return -1;
		blocks = (big get4(cap16, 0) << 32) | (big get4(cap16, 4) & 16rFFFFFFFF) + big 1;
		bsize = get4(cap16, 8);
		return 0;
	}
	blocks = (big last & 16rFFFFFFFF) + big 1;
	return 0;
}

#
# One command, the bulk-only way: a 31-byte wrapper out, the data in
# or out, a 13-byte status in. Returns how many data bytes moved, or
# -1 with the reason in errstr.
#
scsi(cmd: array of byte, data: array of byte, out: int): int
{
	n := 0;
	if(data != nil)
		n = len data;
	cbw := array[Cbwlen] of {* => byte 0};
	cbw[0:] = array of byte "USBC";
	put4le(cbw, 4, tag);
	put4le(cbw, 8, n);
	if(out)
		cbw[12] = byte Cbwdataout;
	else
		cbw[12] = byte Cbwdatain;
	cbw[13] = byte 0;		# LUN
	cbw[14] = byte len cmd;
	cbw[15:] = cmd;
	mytag := tag++;

	if(sys->write(bulkout, cbw, len cbw) != len cbw){
		if(!isdetached())
			recover();
		return -1;
	}

	moved := 0;
	if(n > 0){
		if(out)
			moved = sys->write(bulkout, data, n);
		else
			moved = sys->read(bulkin, data, n);
		if(moved < 0){
			if(isdetached())
				return -1;
			# a stalled data stage is the device's way of saying "less than that"
			unstall(inep | 16r80);
			if(out)
				unstall(outep);
			moved = 0;
		}
	}

	csw := array[Cswlen] of byte;
	for(try := 0; try < 3; try++){
		m := sys->read(bulkin, csw, len csw);
		if(m < 0){
			if(isdetached())
				return -1;
			unstall(inep | 16r80);
			continue;
		}
		if(m != Cswlen || string csw[0:4] != "USBS"){
			sys->werrstr("bad status wrapper");
			recover();
			return -1;
		}
		if(get4le(csw, 4) != mytag)
			continue;	# a stale status; read the next
		status := int csw[12];
		residue := get4le(csw, 8);
		case status {
		Cswok =>
			if(residue > 0 && residue <= n)
				moved = n - residue;
			return moved;
		Cswfailed =>
			sys->werrstr("command failed (check condition)");
			return -1;
		* =>
			sys->werrstr("phase error");
			recover();
			return -1;
		}
	}
	sys->werrstr("no status");
	recover();
	return -1;
}

#
# The transport's own reset: the class request, then both endpoints'
# halts cleared, on the device and in devusb.
#
recover()
{
	ctlout(Rh2d|Rclass|Riface, Rmsreset, 0, 0, nil);
	sys->sleep(100);
	unstall(inep | 16r80);
	unstall(outep);
}

unstall(addr: int)
{
	ctlout(Rh2d|Rstd|Rendpt, Rclrfeature, Fendpthalt, addr, nil);
	ep := inep;
	if((addr & 16r80) == 0)
		ep = outep;
	efd := sys->open("/usb/usb/" + epname(ep) + "/ctl", Sys->OWRITE);
	if(efd != nil)
		sys->fprint(efd, "clrhalt");
}

epname(ep: int): string
{
	return dev[0:len dev - 1] + string ep;	# epN.0 -> epN.<ep>
}

bulkeps(): (int, int, int)
{
	hdr := array[9] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Dconf << 8, 0, hdr) < len hdr)
		return (-1, -1, -1);
	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 512)
		return (-1, -1, -1);
	cfg := array[total] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Dconf << 8, 0, cfg) < total)
		return (-1, -1, -1);
	i := -1;
	o := -1;
	mp := -1;
	for(p := 0; p + 2 <= total; ){
		dlen := int cfg[p];
		if(dlen < 2)
			break;
		if(int cfg[p+1] == 5 && p + 6 < total && (int cfg[p+3] & 3) == 2){
			addr := int cfg[p+2];
			sz := int cfg[p+4] | (int cfg[p+5] << 8);
			if(addr & 16r80){
				if(i < 0){
					i = addr & 16rF;
					mp = sz;
				}
			}else if(o < 0)
				o = addr & 16rF;
		}
		p += dlen;
	}
	return (i, o, mp);
}

openbulk(): int
{
	if(sys->fprint(ctlfd, "new %d bulk r", inep) < 0 && !inuse()){
		sys->print("diskusb: %s: cannot create bulk in %d: %r\n", dev, inep);
		return -1;
	}
	if(sys->fprint(ctlfd, "new %d bulk w", outep) < 0 && !inuse()){
		sys->print("diskusb: %s: cannot create bulk out %d: %r\n", dev, outep);
		return -1;
	}
	bulkin = sys->open("/usb/usb/" + epname(inep) + "/data", Sys->OREAD);
	bulkout = sys->open("/usb/usb/" + epname(outep) + "/data", Sys->OWRITE);
	if(bulkin == nil || bulkout == nil){
		sys->print("diskusb: %s: cannot open the bulk endpoints: %r\n", dev);
		return -1;
	}
	# a whole command's data in one read: 128 KB is what an xHCI ring here takes
	for(ep := inep; ; ep = outep){
		efd := sys->open("/usb/usb/" + epname(ep) + "/ctl", Sys->OWRITE);
		if(efd != nil)
			sys->fprint(efd, "maxpkt %d", maxpkt);
		if(ep == outep)
			break;
	}
	return 0;
}

ctlin(rtype, req, value, index: int, data: array of byte): int
{
	setup := array[8] of byte;
	setup[0] = byte rtype;
	setup[1] = byte req;
	setup[2] = byte (value & 16rFF);
	setup[3] = byte ((value >> 8) & 16rFF);
	setup[4] = byte (index & 16rFF);
	setup[5] = byte ((index >> 8) & 16rFF);
	setup[6] = byte (len data & 16rFF);
	setup[7] = byte ((len data >> 8) & 16rFF);
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
	buf[2] = byte (value & 16rFF);
	buf[3] = byte ((value >> 8) & 16rFF);
	buf[4] = byte (index & 16rFF);
	buf[5] = byte ((index >> 8) & 16rFF);
	buf[6] = byte (dlen & 16rFF);
	buf[7] = byte ((dlen >> 8) & 16rFF);
	if(dlen > 0)
		buf[8:] = data;
	if(sys->write(ep0, buf, len buf) != len buf)
		return -1;
	rep := array[8] of byte;
	sys->read(ep0, rep, len rep);	# collect the (empty) reply: devusb parks it otherwise
	return 0;
}

isdetached(): int
{
	e := sys->sprint("%r");
	for(i := 0; i + 8 <= len e; i++)
		if(e[i:i+8] == "detached")
			return 1;
	return 0;
}

inuse(): int
{
	e := sys->sprint("%r");
	for(i := 0; i + 6 <= len e; i++)
		if(e[i:i+6] == "in use")
			return 1;
	return 0;
}

trim(s: string): string
{
	while(len s > 0 && s[len s - 1] == ' ')
		s = s[0:len s - 1];
	while(len s > 0 && s[0] == ' ')
		s = s[1:];
	return s;
}

put4(a: array of byte, off, v: int)
{
	a[off] = byte (v >> 24);
	a[off+1] = byte (v >> 16);
	a[off+2] = byte (v >> 8);
	a[off+3] = byte v;
}

get4(a: array of byte, off: int): int
{
	return (int a[off] << 24) | (int a[off+1] << 16) | (int a[off+2] << 8) | int a[off+3];
}

put4le(a: array of byte, off, v: int)
{
	a[off] = byte v;
	a[off+1] = byte (v >> 8);
	a[off+2] = byte (v >> 16);
	a[off+3] = byte (v >> 24);
}

get4le(a: array of byte, off: int): int
{
	return int a[off] | (int a[off+1] << 8) | (int a[off+2] << 16) | (int a[off+3] << 24);
}
