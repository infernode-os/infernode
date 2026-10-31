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
# SEVERAL LOGICAL UNITS. A card reader with several slots -- SD,
# microSD, CF, MS -- is one device with one unit per slot (GET MAX
# LUN says how many). Each unit with a medium in it is a disk of its
# own: the next free /chan/usbdiskN, its FAT on /n/usbN, exactly as a
# one-unit device's is, so a single-unit disk is named as it always
# was. A slot that is empty is watched (TEST UNIT READY with the idle
# poll) and served when a card goes in; a card taken out makes that
# unit's reads and writes fail, and one put back is read again --
# its size, and its FAT mounted afresh. The units share the one
# transport, so they are served by one process, one command at a
# time.
#
# NOT DONE: UAS (a disk that offers only the UAS transport is not
# driven); taking a removed card's file away (it stays, failing, so
# whatever has it open is told so rather than left with a vanished
# name); more than four FAT volumes mounted at once (the root has
# /n/usb0 to /n/usb3; a fifth disk is served as its block file and
# not mounted); and any queueing: one command at a time, which is
# what a FAT filesystem asks for anyway.
#
# Tested on QEMU's usb-storage behind its xHCI controller (the virt
# machine), at SuperSpeed, and on its usb-bot with three units (two
# disks and an empty slot that a medium is put into, taken out of and
# put back into). The one-unit driver before this ran on the Pi 4
# against the Jetson's gadget disk; this one has not run on a board,
# nor on a real multi-slot reader.
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
Cread16:	con 16r88;	# READ(16) and WRITE(16): a 64-bit block address, for a disk past 2TB
Cwrite16:	con 16r8A;

Maxio:		con 64*1024;	# one command moves at most this much
Maxretry:	con 3;
Readyms:	con 250;	# between TEST UNIT READY attempts
Pollms:		con 2000;	# how often an idle disk is asked if it is still there

Maxlun:		con 15;		# GET MAX LUN's answer is a four-bit number

dev: string;			# devusb's name for the device: epN.0
ctlfd: ref Sys->FD;
ep0: ref Sys->FD;
msiface := 0;	# the mass-storage interface's number, for its class requests
bulkin: ref Sys->FD;
bulkout: ref Sys->FD;
inep, outep, maxpkt: int;
tag := 1;
multi := 0;			# more than one unit: say which in what is printed

#
# One logical unit: a slot of a card reader, or the whole of a stick.
#
Unit: adt {
	lun:	int;
	what:	string;		# vendor and product, from INQUIRY
	blocks:	big;		# how many
	bsize:	int;		# how big each
	name:	string;		# /chan/usbdiskN once served; nil before
	present:	int;	# a medium is in it now
	fio:	ref Sys->FileIO;
	fwd:	int;		# the forwarder's pid, so it can be stopped
};
units: list of ref Unit;

#
# Every unit's file feeds these two, so the one process that owns the
# transport serves them all in turn (see loop).
#
reads: chan of (ref Unit, int, int, Sys->Rread);
writes: chan of (ref Unit, int, array of byte, Sys->Rwrite);
tickpid := 0;

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
	if(inep < 0 || outep < 0){
		sys->print("diskusb: %s: no pair of bulk endpoints\n", dev);
		return;
	}
	if(openbulk() < 0)
		return;

	#
	# GET MAX LUN: the highest unit number, one per slot of a card
	# reader. A device with one unit may STALL this rather than answer
	# 0; either way LUN 0 is there.
	#
	maxlun := 0;
	lb := array[1] of byte;
	if(ctlin(Rd2h|Rclass|Riface, Rgetmaxlun, 0, msiface, lb) == 1)
		maxlun = int lb[0] & Maxlun;
	multi = maxlun > 0;
	if(multi)
		sys->print("diskusb: %s has %d logical units\n", dev, maxlun + 1);

	reads = chan of (ref Unit, int, int, Sys->Rread);
	writes = chan of (ref Unit, int, array of byte, Sys->Rwrite);
	for(l := 0; l <= maxlun; l++){
		u := probe(l);
		if(u == nil)
			continue;
		units = u :: units;
		if(ready(u) < 0){
			sys->print("diskusb: %s (%s): not ready, no medium: %r%s\n", unitname(u), u.what,
				"; watched for one");
			continue;
		}
		bringup(u);
	}
	if(units == nil)
		return;

	tick := chan of int;
	pidc := chan of int;
	spawn ticker(tick, pidc);
	tickpid = <-pidc;
	loop(tick);
	stop();
}

#
# INQUIRY for one unit: what it is, and whether it is a disk at all. A
# unit that says it is not supported (peripheral qualifier 3) or is
# not a block device is left out; nil then.
#
probe(lun: int): ref Unit
{
	u := ref Unit(lun, "", big 0, 0, nil, 0, nil, 0);
	inq := array[36] of byte;
	if(scsi(lun, array[] of {byte Cinquiry, byte 0, byte 0, byte 0, byte len inq, byte 0}, inq, 0) < 0){
		sys->print("diskusb: %s: INQUIRY failed: %r\n", unitname(u));
		return nil;
	}
	if((int inq[0] >> 5) == 3){
		sys->print("diskusb: %s: no such unit\n", unitname(u));
		return nil;
	}
	dtype := int inq[0] & 16r1F;
	if(dtype != 0 && dtype != 5 && dtype != 7 && dtype != 14){
		sys->print("diskusb: %s is not a disk (SCSI device type %d)\n", unitname(u), dtype);
		return nil;
	}
	u.what = trim(string inq[8:16]) + " " + trim(string inq[16:32]);
	return u;
}

# how a unit is named in what this prints: the device, and the LUN when there are several
unitname(u: ref Unit): string
{
	if(multi)
		return sys->sprint("%s LUN %d", dev, u.lun);
	return dev;
}

#
# A unit with a medium in it: its size, its file, its FAT. Called at
# start and again whenever a medium arrives -- the same card put back,
# or another, maybe of another size, so the size is asked every time
# and the file's length set again. A unit served before keeps its
# name: whatever has the file open sees the new medium through it.
#
bringup(u: ref Unit): int
{
	if(capacity(u) < 0){
		sys->print("diskusb: %s (%s): READ CAPACITY failed: %r\n", unitname(u), u.what);
		return -1;
	}
	if(u.bsize < 512 || u.bsize > 4096 || u.bsize % 512 != 0){
		sys->print("diskusb: %s (%s): block size %d is not one this driver serves\n", unitname(u), u.what, u.bsize);
		return -1;
	}
	if(u.name == nil){
		if(serve(u) < 0)
			return -1;
	}else
		setlength(u);
	u.present = 1;
	mb := (u.blocks * big u.bsize) / big (1024*1024);
	sys->print("diskusb: %s %s: %bd blocks of %d bytes (%bd MB), served as %s\n",
		unitname(u), u.what, u.blocks, u.bsize, mb, u.name);
	spawn mountfat(u.name);
	return 0;
}

#
# The files: reads and writes at an offset, served one at a time, and
# between them every unit is asked now and then whether it is still
# there, so that an unplugged device is noticed before anything asks
# for a block, and a card put into an empty slot is noticed at all.
# dossrv holds the file open and does 512-byte sector reads at sector
# offsets; anything else is served too, by reading whole blocks around
# it.
#
# One process, because the units share one transport: a command and
# its status must not be split by another unit's. Each file has a
# forwarder that hands its requests here (forward), so this waits on
# two channels whatever the number of units.
#
loop(tick: chan of int)
{
	for(;;) alt {
	(u, off, n, rc) := <-reads =>
		(data, err) := diskread(u, big off, n);
		rc <-= (data, err);
		if(err != nil && detached(err))
			return;
	(u, off, data, wc) := <-writes =>
		(n, err) := diskwrite(u, big off, data);
		wc <-= (n, err);
		if(err != nil && detached(err))
			return;
	<-tick =>
		for(l := units; l != nil; l = tl l)
			if(poll(hd l) < 0)
				return;
	}
}

forward(u: ref Unit, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;) alt {
	(off, n, nil, rc) := <-u.fio.read =>
		if(rc != nil)
			reads <-= (u, off, n, rc);
	(off, data, nil, wc) := <-u.fio.write =>
		if(wc != nil)
			writes <-= (u, off, data, wc);
	}
}

#
# One unit's turn at the idle poll. -1: the device has gone.
#
# A medium that goes is reported as a unit attention or a NOT READY
# with "medium not present"; either way the unit is marked empty and
# its reads fail until one is back. A unit attention is also how a
# card swapped between two polls is reported -- marking it empty is
# right then too, since the next poll finds it ready and reads its
# size again.
#
poll(u: ref Unit): int
{
	if(scsi(u.lun, array[6] of {* => byte 0}, nil, 0) >= 0){
		if(!u.present)
			bringup(u);
		return 0;
	}
	if(isdetached()){
		sys->print("diskusb: %s detached\n", dev);
		return -1;
	}
	(key, asc, nil) := sense(u.lun);
	if(key < 0 && isdetached()){
		sys->print("diskusb: %s detached\n", dev);
		return -1;
	}
	if(u.present && (key == 2 || key == 6 || nounit(key, asc))){
		u.present = 0;
		if(u.name != nil)
			sys->print("diskusb: %s: medium removed; %s fails until one is back\n", unitname(u), u.name);
	}
	return 0;
}

ticker(c: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		sys->sleep(Pollms);
		c <-= 1;
	}
}

#
# The device has gone: stop the ticker and every forwarder, and let go
# of the files, which go with their last reference. Without this the
# forwarders, waiting on their files for ever, kept the files there
# naming a disk that no longer exists.
#
stop()
{
	kill(tickpid);
	for(l := units; l != nil; l = tl l){
		u := hd l;
		kill(u.fwd);
		if(u.name != nil)
			sys->print("diskusb: %s is gone\n", u.name);
		u.fio = nil;
	}
	units = nil;
}

kill(pid: int)
{
	if(pid <= 0)
		return;
	fd := sys->open("#p/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

detached(err: string): int
{
	for(i := 0; i + 8 <= len err; i++)
		if(err[i:i+8] == "detached"){
			sys->print("diskusb: %s detached\n", dev);
			return 1;
		}
	return 0;
}

diskread(u: ref Unit, off: big, n: int): (array of byte, string)
{
	if(!u.present)
		return (nil, u.name + ": no medium");
	if(off < big 0 || n <= 0)
		return (nil, nil);
	end := off + big n;
	if(end > u.blocks * big u.bsize)
		end = u.blocks * big u.bsize;
	if(end <= off)
		return (nil, nil);
	lba := off / big u.bsize;
	last := (end - big 1) / big u.bsize;
	nb := int (last - lba) + 1;
	buf := array[nb * u.bsize] of byte;
	for(done := 0; done < nb; ){
		chunk := nb - done;
		if(chunk * u.bsize > Maxio)
			chunk = Maxio / u.bsize;
		if(rw(u, Cread10, lba + big done, buf[done*u.bsize:(done+chunk)*u.bsize], 0) < 0)
			return (nil, sys->sprint("%s: read at %bd: %r", u.name, off));
		done += chunk;
	}
	skip := int (off - lba * big u.bsize);
	return (buf[skip:skip + int (end - off)], nil);
}

diskwrite(u: ref Unit, off: big, data: array of byte): (int, string)
{
	if(!u.present)
		return (-1, u.name + ": no medium");
	if(off < big 0)
		return (-1, "negative offset");
	n := len data;
	end := off + big n;
	if(end > u.blocks * big u.bsize)
		return (-1, "write beyond the end of " + u.name);
	if(n == 0)
		return (0, nil);
	lba := off / big u.bsize;
	last := (end - big 1) / big u.bsize;
	nb := int (last - lba) + 1;
	skip := int (off - lba * big u.bsize);
	buf := data;
	if(skip != 0 || n % u.bsize != 0){
		# not whole blocks: read what is there, lay the write over it
		(old, err) := diskread(u, lba * big u.bsize, nb * u.bsize);
		if(err != nil)
			return (-1, err);
		buf = array[nb * u.bsize] of byte;
		buf[0:] = old;
		buf[skip:] = data;
	}
	for(done := 0; done < nb; ){
		chunk := nb - done;
		if(chunk * u.bsize > Maxio)
			chunk = Maxio / u.bsize;
		if(rw(u, Cwrite10, lba + big done, buf[done*u.bsize:(done+chunk)*u.bsize], 1) < 0)
			return (-1, sys->sprint("%s: write at %bd: %r", u.name, off));
		done += chunk;
	}
	return (n, nil);
}

rw(u: ref Unit, op: int, lba: big, buf: array of byte, out: int): int
{
	nb := len buf / u.bsize;
	cmd: array of byte;
	if(u.blocks > big 16r100000000){
		#
		# Past 2^32 blocks (2TB of 512-byte ones) READ(10)'s 32-bit
		# address wraps: the 16-byte form carries 64 bits. Only for
		# such a disk, since the 10-byte form is the one every
		# device, however old, understands.
		#
		cmd = array[16] of {* => byte 0};
		if(op == Cread10)
			cmd[0] = byte Cread16;
		else
			cmd[0] = byte Cwrite16;
		put4(cmd, 2, int (lba >> 32));
		put4(cmd, 6, int lba);
		put4(cmd, 10, nb);
	} else {
		cmd = array[10] of byte;
		cmd[0] = byte op;
		cmd[1] = byte 0;
		put4(cmd, 2, int lba);
		cmd[6] = byte 0;
		cmd[7] = byte (nb >> 8);
		cmd[8] = byte nb;
		cmd[9] = byte 0;
	}
	for(try := 0; try < Maxretry; try++){
		n := scsi(u.lun, cmd, buf, out);
		if(n == len buf)
			return 0;
		if(n >= 0)
			sys->print("diskusb: %s: short %s: %d of %d bytes\n", u.name, opname(op), n, len buf);
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
mountfat(name: string)
{
	srv := load Command "/dis/dossrv.dis";
	if(srv == nil){
		sys->print("diskusb: cannot load dossrv: %r\n");
		return;
	}
	mnt := "/n/usb" + name[len "/chan/usbdisk":];
	(ok, nil) := sys->stat(mnt);
	if(ok < 0){
		sys->print("diskusb: %s: no %s to mount its FAT on; it is served as the block file\n", name, mnt);
		return;
	}
	{
		srv->init(nil, "dossrv" :: "-f" :: name :: "-m" :: mnt :: nil);
		sys->print("diskusb: %s mounted on %s for init and the network console; elsewhere: dossrv -f %s -m %s\n", name, mnt, name, mnt);
	} exception e {
	"*" =>
		sys->print("diskusb: %s: no FAT filesystem mounted: %s\n", name, e);
	}
}

#
# The first free /chan/usbdiskN, and a forwarder for it. A driver that
# has gone takes its files with it, so the numbers are reused.
#
serve(u: ref Unit): int
{
	for(i := 0; i < 16; i++){
		n := "usbdisk" + string i;
		(ok, nil) := sys->stat("/chan/" + n);
		if(ok >= 0)
			continue;
		u.fio = sys->file2chan("/chan", n);
		if(u.fio == nil){
			sys->print("diskusb: cannot serve /chan/%s: %r\n", n);
			return -1;
		}
		u.name = "/chan/" + n;
		setlength(u);
		pidc := chan of int;
		spawn forward(u, pidc);
		u.fwd = <-pidc;
		return 0;
	}
	sys->print("diskusb: sixteen disks are enough\n");
	return -1;
}

#
# Say how big it is: a served file is born with length 0, and dossrv
# bounds its reads by the device's length when there is one. devsrv
# takes a wstat of the length alone.
#
setlength(u: ref Unit)
{
	d := sys->nulldir;
	d.length = u.blocks * big u.bsize;
	d.mode = 8r666;		# said outright: devsrv takes nulldir's ~0 for a mode, exclusive-use bit and all
	if(sys->wstat(u.name, d) < 0)
		sys->print("diskusb: cannot set the length of %s: %r\n", u.name);
}

#
# TEST UNIT READY until it says so; a unit that is "becoming ready" is
# given its time, one with no medium is not. A unit attention (the
# medium changed, or the device was reset) is cleared by the REQUEST
# SENSE that reads it, and the unit asked again at once.
#
ready(u: ref Unit): int
{
	(key, asc, ascq) := (-1, 0, 0);
	for(try := 0; try < 8; try++){
		if(scsi(u.lun, array[6] of {* => byte 0}, nil, 0) >= 0)
			return 0;
		(key, asc, ascq) = sense(u.lun);
		if(key < 0)
			return -1;
		if(key == 2 && asc == 16r3A || nounit(key, asc)){	# not ready: medium not present
			sys->werrstr("no medium");
			return -1;
		}
		if(key == 6)
			continue;
		if(key == 2 && asc == 16r04 && ascq == 2){	# initializing command required
			scsi(u.lun, array[] of {byte Cstartstop, byte 0, byte 0, byte 0, byte 1, byte 0}, nil, 0);
		}
		sys->sleep(Readyms);
	}
	sys->werrstr(sys->sprint("still not ready (sense %d/%.2x/%.2x)", key, asc, ascq));
	return -1;
}

#
# ILLEGAL REQUEST, "logical unit not supported", from a unit INQUIRY
# has already answered for. QEMU's usb-bot says this, not "medium not
# present", when an empty slot other than LUN 0 is asked why it is not
# ready (its REQUEST SENSE for a non-zero LUN with sense pending), and a
# unit that exists and is not ready has no medium in any reading of it.
#
nounit(key, asc: int): int
{
	return key == 5 && asc == 16r25;
}

# REQUEST SENSE: (key, asc, ascq), or (-1, 0, 0) if it could not be asked
sense(lun: int): (int, int, int)
{
	sb := array[18] of byte;
	if(scsi(lun, array[] of {byte Crequestsense, byte 0, byte 0, byte 0, byte len sb, byte 0}, sb, 0) < 0)
		return (-1, 0, 0);
	return (int sb[2] & 16rF, int sb[12], int sb[13]);
}

capacity(u: ref Unit): int
{
	cap := array[8] of byte;
	if(scsi(u.lun, array[10] of {byte Creadcap10, * => byte 0}, cap, 0) < 0)
		return -1;
	last := get4(cap, 0);
	u.bsize = get4(cap, 4);
	if(last == -1){
		# more than 2^32 blocks: ask with READ CAPACITY(16), to say so
		cap16 := array[32] of byte;
		cmd := array[16] of {* => byte 0};
		cmd[0] = byte Creadcap16;
		cmd[1] = byte 16r10;
		cmd[13] = byte len cap16;
		if(scsi(u.lun, cmd, cap16, 0) < 0)
			return -1;
		u.blocks = (big get4(cap16, 0) << 32) | (big get4(cap16, 4) & 16rFFFFFFFF) + big 1;
		u.bsize = get4(cap16, 8);
		return 0;
	}
	u.blocks = (big last & 16rFFFFFFFF) + big 1;
	return 0;
}

#
# One command, the bulk-only way, to one unit: a 31-byte wrapper out,
# the data in or out, a 13-byte status in. Returns how many data bytes
# moved, or -1 with the reason in errstr.
#
scsi(lun: int, cmd: array of byte, data: array of byte, out: int): int
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
	cbw[13] = byte (lun & Maxlun);
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
	ctlout(Rh2d|Rclass|Riface, Rmsreset, 0, msiface, nil);
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
	if(total < len hdr || total > 4096)	# a composite device's runs past 512
		return (-1, -1, -1);
	cfg := array[total] of byte;
	if(ctlin(Rd2h|Rstd|Rdev, Rgetdesc, Dconf << 8, 0, cfg) < total)
		return (-1, -1, -1);
	#
	# The endpoints of the MASS-STORAGE interface, not the first bulk
	# pair in the configuration: on a composite device -- the Jetson's
	# own USB gadget is network, serial and disk in one -- the first
	# bulk endpoints are a network interface's.
	#
	i := -1;
	o := -1;
	mp := -1;
	inms := 0;
	for(p := 0; p + 2 <= total; ){
		dlen := int cfg[p];
		if(dlen < 2)
			break;
		if(int cfg[p+1] == 4 && p + 8 < total){	# interface
			inms = int cfg[p+5] == 8 && int cfg[p+7] == 16r50;	# mass storage, bulk-only
			if(inms && i < 0)
				msiface = int cfg[p+2];
		}
		if(inms && int cfg[p+1] == 5 && p + 6 < total && (int cfg[p+3] & 3) == 2){
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
	#
	# One endpoint number both ways -- 0x81 in and 0x01 out, which is
	# how Linux's mass-storage gadget does it -- is one endpoint to
	# devusb, opened for reading and writing. This refused such a disk
	# outright ("no pair of bulk endpoints"); the disks it had met, QEMU's
	# and the Jetson's composite gadget, used two numbers.
	#
	if(inep == outep){
		if(sys->fprint(ctlfd, "new %d bulk rw", inep) < 0 && !inuse()){
			sys->print("diskusb: %s: cannot create bulk %d: %r\n", dev, inep);
			return -1;
		}
		efd := sys->open("/usb/usb/" + epname(inep) + "/ctl", Sys->OWRITE);
		if(efd != nil)
			sys->fprint(efd, "maxpkt %d", maxpkt);
		bulkin = sys->open("/usb/usb/" + epname(inep) + "/data", Sys->ORDWR);
		bulkout = bulkin;
		if(bulkin == nil){
			sys->print("diskusb: %s: cannot open the bulk endpoint: %r\n", dev);
			return -1;
		}
		return 0;
	}
	if(sys->fprint(ctlfd, "new %d bulk r", inep) < 0 && !inuse()){
		sys->print("diskusb: %s: cannot create bulk in %d: %r\n", dev, inep);
		return -1;
	}
	if(sys->fprint(ctlfd, "new %d bulk w", outep) < 0 && !inuse()){
		sys->print("diskusb: %s: cannot create bulk out %d: %r\n", dev, outep);
		return -1;
	}
	#
	# The packet size BEFORE the endpoints are opened. Opening one is
	# what describes it to the controller (usbxhci's epopen builds its
	# endpoint context then), so a size set afterwards never reaches
	# the hardware: the endpoints went to the controller as 8-byte ones.
	# QEMU's xHCI ran a SuperSpeed disk that way; the Pi 4's VL805 failed
	# the first command, a 1024-byte-packet disk's INQUIRY.
	#
	for(ep := inep; ; ep = outep){
		efd := sys->open("/usb/usb/" + epname(ep) + "/ctl", Sys->OWRITE);
		if(efd != nil)
			sys->fprint(efd, "maxpkt %d", maxpkt);
		if(ep == outep)
			break;
	}
	bulkin = sys->open("/usb/usb/" + epname(inep) + "/data", Sys->OREAD);
	bulkout = sys->open("/usb/usb/" + epname(outep) + "/data", Sys->OWRITE);
	if(bulkin == nil || bulkout == nil){
		sys->print("diskusb: %s: cannot open the bulk endpoints: %r\n", dev);
		return -1;
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
