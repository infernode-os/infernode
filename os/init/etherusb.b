implement Command;

#
# etherusb -- the USB Ethernet class driver.
#
# This is a PROGRAM, not kernel code, and deliberately so: see
# "Decision: device protocols live outside the kernel, mechanism
# inside" in os/bcm2837/README.md. The kernel publishes raw endpoints
# as files under #u; everything below is one device's protocol spoken
# on top of them, which is exactly the layer that decision puts out
# here.
#
# It is loaded as a Command because in Inferno a command IS a Dis
# module -- there is no exec(2) -- so osinit hands it the endpoint name
# the bus walk found and calls init().
#
# WHICH PROTOCOL. USB Ethernet is not one thing. Upstream's etherusb.c
# dispatches cdc, asix and smsc through a driver-family table, and the
# same is needed here for a different pair:
#
#   RNDIS    QEMU's usb-net, which is what can be tested before there
#            is hardware. Interface class 2/2/255 -- CDC/ACM with a
#            vendor protocol, which is Microsoft's signature.
#   LAN78xx  the Pi 3B+'s actual LAN7515, which is a hub with an
#            Ethernet function behind it and its own register protocol.
#
# Neither is a superset of the other, so the family is chosen from the
# descriptors rather than assumed.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Fid: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

#
# Control-request shape. Same eight bytes as always; what differs from
# the bus walk in osinit is the recipient -- these go to an INTERFACE,
# not to a device or a hub port.
#
Rh2d:		con 16r00;
Rd2h:		con 16r80;
Rclass:		con 16r20;
Riface:		con 1;		# recipient: interface

Rgetdesc:	con 6;		# GET_DESCRIPTOR
Ddev:		con 1;		# descriptor type: device
Dconf:		con 2;		# descriptor type: configuration
Rsetconf:	con 9;		# SET_CONFIGURATION
Rgetconf:	con 8;		# GET_CONFIGURATION

#
# bConfigurationValue from this device's configuration descriptor.
# Not 1: that is only a convention, and SET_CONFIGURATION for a value
# the device does not have is a stall rather than a diagnosable error.
#
# bConfigurationValue is read from the device, never assumed -- see
# configvalue(). It is only conventionally 1, and the two devices this
# drives disagree about it.

#
# RNDIS rides on two class requests rather than having its own
# endpoint: the host puts a message in SEND_ENCAPSULATED_COMMAND and
# collects the reply with GET_ENCAPSULATED_RESPONSE.
#
Rsendenc:	con 0;
Rgetenc:	con 1;

# RNDIS message types
Rnisinit:	con 16r00000002;
Rnisinitc:	con 16r80000002;
Rnisquery:	con 16r00000004;
Rnisqueryc:	con 16r80000004;
Rnisset:	con 16r00000005;
Rnissetc:	con 16r80000005;

# object identifiers
Oidmac:		con 16r01010101;	# OID_802_3_PERMANENT_ADDRESS
Oidfilter:	con 16r0001010E;	# OID_GEN_CURRENT_PACKET_FILTER

# packet filter bits: directed, multicast, broadcast
Filterdefault:	con 16r0000000D;

Maxctl:		con 1024;

#
# LAN78xx -- the Microchip family behind the Pi 3B+'s LAN7515, which
# is a high-speed hub with an Ethernet function on it.
#
# Registers are read and written with two vendor requests rather than
# any class protocol, and each frame carries a command header: eight
# bytes out, ten bytes in.
#
# THE REGISTER MAP BELOW IS UNVALIDATED. It has never been run against
# the silicon, so setup() checks what it can rather than assuming:
# ID_REV is read back first and an implausible answer refuses the
# device instead of configuring it wrongly. A driver that half-works is
# worse here than one that declines, because a NIC that is misprogrammed
# comes up and silently carries nothing.
#
Rvendor:	con 16r40;		# host to device, vendor, device
Rvendorin:	con 16rC0;		# device to host, vendor, device
Rwritereg:	con 16rA0;
Rreadreg:	con 16rA1;

Lidrev:		con 16r000;
Lhwcfg:		con 16r010;
Lfctrxctl:	con 16r0C0;
Lfcttxctl:	con 16r0C4;
Lmacrx:		con 16r104;
Lmactx:		con 16r108;
Lrxaddrh:	con 16r118;
Lrxaddrl:	con 16r11C;

#
# OTP, where this part keeps its MAC address when there is no EEPROM --
# which is the case on the Pi 3B+, whose RX_ADDR registers consequently
# read back all-ones rather than an address.
#
# The offsets are OTP_BASE_ADDR + 4*n in the vendor's own numbering, so
# they are written that way rather than pre-added: it keeps them
# checkable against lan78xx.h at a glance.
#
Lotpbase:	con 16r1000;
Lotppwrdn:	con Lotpbase + 4*0;
Lotpaddr1:	con Lotpbase + 4*1;
Lotpaddr2:	con Lotpbase + 4*2;
Lotprddata:	con Lotpbase + 4*6;
Lotpfunccmd:	con Lotpbase + 4*8;
Lotpcmdgo:	con Lotpbase + 4*10;
Lotpstatus:	con Lotpbase + 4*12;

Lotppwrdnn:	con 16r01;	# OTP_PWR_DN: awake when this is CLEAR
Lotpread:	con 16r01;	# OTP_FUNC_CMD: read
Lotpgo:		con 16r01;	# OTP_CMD_GO
Lotpbusy:	con 16r01;	# OTP_STATUS
Lotpmacoff:	con 16r01;	# where the address sits in OTP

#
# MDIO, the bus to the internal PHY. MII_ACC carries the address and the
# direction and self-clears when the access completes; MII_DATA is the
# word either way.
#
Lmiiacc:	con 16r120;
Lmiidata:	con 16r124;

Lmiibusy:	con 16r01;
Lmiiwrite:	con 16r02;
Lmiiphyshift:	con 11;
Lmiiregshift:	con 6;
Lphyaddr:	con 1;			# the LAN78xx internal PHY

# Registers every MII PHY has, in the numbering the standard gives them.
Mbmcr:		con 0;			# control
Mbmsr:		con 1;			# status
Mphyid1:	con 2;
Mphyid2:	con 3;

Mbmcrreset:	con 16r8000;		# BMCR: reset, self-clearing
Mbmcrloop:	con 16r4000;		# BMCR: internal loopback
Mbmcr100:	con 16r2000;		# BMCR: 100Mb/s
Mbmcrfull:	con 16r0100;		# BMCR: full duplex
Mbmcraneg:	con 16r1000;		# BMCR: auto-negotiation enable
Mbmcrrestart:	con 16r0200;		# BMCR: restart auto-negotiation
Mbmsrlink:	con 16r0004;		# BMSR: link is up
Mbmsraneg:	con 16r0020;		# BMSR: auto-negotiation complete

Lhwlrst:	con 16r00000002;	# HW_CFG: soft reset
# 1<<31, not 16r80000000: bit 31 does not fit a Limbo int, which
# is signed 32-bit, so the literal would be a big and the argument
# types would not match.
Lfcten:		con 1 << 31;		# FCT_{RX,TX}_CTL: enable
Lrxen:		con 16r00000001;	# MAC_RX: receiver enable
Lmaccr:		con 16r100;		# MAC_CR
Lmacloop:	con 16r00000400;	# MAC_CR: loopback, no PHY involved
Lmacadp:	con 16r00002000;	# MAC_CR: automatic duplex polarity
Lmacautodup:	con 16r00001000;	# MAC_CR: follow the PHY's duplex
Lmacautospd:	con 16r00000800;	# MAC_CR: follow the PHY's speed
Lmacfull:	con 16r00000008;	# MAC_CR: full duplex
Lmacspd100:	con 16r00000002;	# MAC_CR: 100Mb/s
Lmacspdmask:	con 16r00000006;	# MAC_CR: speed field

#
# MAC_RX carries the largest frame the receiver will accept in bits
# 16-29. At reset it is ZERO, so every frame is oversized and dropped.
#
Lrxmaxshift:	con 16;
Lrxfcsstrip:	con 16r00000010;	# MAC_RX: strip the FCS

# which loop lanloopback() should close
Lpby:		con 0;			# inside the PHY
Lmacy:		con 1;			# inside the MAC

#
# The receive filtering engine. At reset it passes nothing, so a device
# whose RFE_CTL is never written receives no frames at all -- which is
# indistinguishable from a dead wire, and was.
#
Lrfectl:	con 16r0B0;
Lintsts:	con 16r00C;		# INT_STS
Lrfebcast:	con 16r00000400;	# accept broadcast
Lrfemcast:	con 16r00000200;	# accept multicast
Lrfeucast:	con 16r00000100;	# accept unicast
Lrfeperfect:	con 16r00000002;	# match against RX_ADDR
Ltxen:		con 16r00000001;	# MAC_TX: transmitter enable

Ltxhdr:		con 8;			# TX_CMD_A and TX_CMD_B
Lrxhdr:		con 10;			# RX_CMD_A, RX_CMD_B, RX_CMD_C
Ltxfcs:		con 16r00400000;	# TX_CMD_A: append FCS
Ltxlen:		con 16r000FFFFF;	# TX_CMD_A: frame length
Lrxlen:		con 16r00003FFF;	# RX_CMD_A: frame length
Lrxerr:		con 16r00400000;	# RX_CMD_A: receive error

#
# The file interface ethermedium dials. Taken from os/port/dial.c
# call() and etherbind() rather than from memory:
#
#	clone		open, then read -> the connection number
#	<n>/ctl		"connect 0x800", then "nonblocking"
#	<n>/data	one read or write is one ETHERNET FRAME, header
#			and all -- ethermedium strips the 14 bytes itself
#	<n>/stats	"addr: <12 hex>" and "mbps: <n>"
#
# ethermedium opens three connections -- 0x800 (IPv4), 0x806 (ARP) and
# 0x86DD (IPv6) -- and expects inbound frames demultiplexed onto them
# by ether type. Four are provided so there is one spare.
#
Nconv:		con 4;
Qdir:		con 0;
Qclone:		con 1;
Qcbase:		con 16;		# per-connection qids start here

# the four files of a connection, in qid order
Qcdir, Qcctl, Qcdata, Qcstats: con iota;

Qmax:		con 16;		# frames buffered per connection
Npend:		con 8;		# reads outstanding per connection
Maxframe:	con 1514;	# an Ethernet frame, header included
Rnisdata:	con 16r00000001;
Rnishdr:	con 44;		# RNDIS_PACKET_MSG, before the frame

Conv: adt {
	etype:	int;			# ether type, -1 until connected
	q:	array of array of byte;	# frames waiting for a reader
	nq:	int;
	pend:	array of int;		# tags of reads waiting for a frame
	npend:	int;
	drops:	int;
	inpkt:	int;
	outpkt:	int;
};

#
# THE DRIVER FAMILY TABLE.
#
# USB Ethernet is not one protocol. What a device wants said to it
# before it will carry frames, and what it wraps each frame in, differ
# completely between families -- so those two things are per-family and
# everything else in this program is not.
#
#   setup    bring the device to the point of carrying frames, and
#            leave its MAC in mac[]. Returns 0, or -1 having said why.
#   wrap     build the bytes to write for one outbound frame.
#   unwrap   given a buffer, return (bytes consumed, the frame within),
#            or (0, nil) if it does not yet hold a whole message, or
#            (-1, nil) if it never will.
#
# Adding a family is filling in an entry. That is deliberate: the one
# that matters on the actual board -- LAN78xx, for the 3B+'s LAN7515 --
# cannot be written honestly from memory and has to be developed
# against the hardware, so the seam it will need exists first and is
# exercised by the family that can be tested.
#
Family: adt {
	name:	string;
	vid:	int;			# -1 matches any
	pid:	int;
	setup:	ref fn(): int;
	wrap:	ref fn(frame: array of byte): array of byte;
	unwrap:	ref fn(buf: array of byte, n: int): (int, array of byte);
};

families: array of Family;
family: Family;

convs: array of ref Conv;
mac := array[6] of byte;
bulkfd: ref Sys->FD;		# bulk IN
bulkoutfd: ref Sys->FD;		# bulk OUT; the same fd when one endpoint serves both
tc: chan of ref Tmsg;
srv: ref Styxserver;
rxq: chan of (int, array of byte);

dev: string;			# "ep3.0"
ctl: ref Sys->FD;		# #u/usb/<dev>/ctl
ep0: ref Sys->FD;		# #u/usb/<dev>/data -- the control endpoint
reqid := 1;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	if(styx == nil || styxservers == nil || nametree == nil){
		sys->print("etherusb: cannot load the 9P modules: %r\n");
		return;
	}
	styx->init();
	styxservers->init(styx);
	nametree->init();

	argv = tl argv;
	if(argv == nil){
		sys->print("etherusb: no device given\n");
		return;
	}
	dev = hd argv;

	ctl = sys->open("/usb/usb/" + dev + "/ctl", Sys->ORDWR);
	ep0 = sys->open("/usb/usb/" + dev + "/data", Sys->ORDWR);
	if(ctl == nil || ep0 == nil){
		sys->print("etherusb: cannot open %s: %r\n", dev);
		return;
	}

	families = array[] of {
		Family("rndis", 16r0525, 16ra4a2, rndissetup, rndiswrap, rndisunwrap),
		#
		# Microchip. -1 matches any product because the 3B+ carries a
		# LAN7515 while the family covers 7800 and 7850 too, and
		# lansetup() identifies the part from ID_REV anyway -- which
		# is a better check than a number in a table, since it also
		# proves register access works.
		#
		Family("lan78xx", 16r0424, -1, lansetup, lanwrap, lanunwrap),
	};

	#
	# Which family. Chosen from the device's identity rather than
	# assumed, so an unrecognised device is refused with its numbers
	# rather than driven with the wrong protocol -- which on a NIC
	# means a link that comes up and silently carries nothing.
	#
	(vid, pid) := devid();
	found := 0;
	for(i := 0; i < len families; i++)
		if((families[i].vid < 0 || families[i].vid == vid) &&
		   (families[i].pid < 0 || families[i].pid == pid)){
			family = families[i];
			found = 1;
			break;
		}
	if(!found){
		sys->print("etherusb: %s is %#4.4x:%#4.4x, no driver family\n",
			dev, vid, pid);
		return;
	}

	#
	# Ask the device which configuration it has, rather than naming
	# one.
	#
	# This was the constant 2, which is what the RNDIS adapter
	# developed against declares. bConfigurationValue is the device's
	# own choice: the LAN7800 on the Pi 3B+ declares 1, so the
	# constant sent it a SET_CONFIGURATION for a value it does not
	# have. The device kept the configuration it already had and the
	# only symptom was a line saying so.
	#
	cfgval := configvalue();
	if(cfgval < 0)
		return;
	if(ctlout(Rh2d, Rsetconf, cfgval, 0, nil) < 0){
		sys->print("etherusb: set configuration %d failed: %r\n", cfgval);
		return;
	}

	#
	# The bulk endpoints, on the numbers the DEVICE declares.
	#
	# This asked for endpoint 2 read-write, because the RNDIS adapter
	# it was written against puts both directions on 2. The LAN7800
	# does not: bulk IN is endpoint 1 and bulk OUT is endpoint 2. So
	# every write went to the right place and every read was aimed at
	# an IN endpoint that does not exist -- which the controller
	# reports as a transaction error, not as an empty read, and which
	# is why ep4.2 returned intr 00000082 on every attempt including
	# inside PHY loopback where a frame had definitely been sent.
	#
	# When both directions share a number, one "rw" endpoint is still
	# the right answer: devusb keeps a toggle per direction, so that
	# is already a pair of pipes, and asking for two on the same
	# number is rejected as already in use.
	#
	dumpendpoints();
	(inep, outep, mp) := bulkeps();
	if(inep < 0 || outep < 0){
		sys->print("etherusb: no pair of bulk endpoints\n");
		return;
	}

	inname := "";
	outname := "";
	if(inep == outep){
		if(sys->fprint(ctl, "new %d bulk rw", inep) < 0){
			sys->print("etherusb: cannot create the bulk endpoint: %r\n");
			return;
		}
		inname = epname(dev, inep);
		outname = inname;
	}else{
		if(sys->fprint(ctl, "new %d bulk r", inep) < 0 ||
		   sys->fprint(ctl, "new %d bulk w", outep) < 0){
			sys->print("etherusb: cannot create the bulk endpoints: %r\n");
			return;
		}
		inname = epname(dev, inep);
		outname = epname(dev, outep);
	}

	#
	# The new endpoints inherit nothing. devusb's newdevep leaves
	# maxpkt at the 8 that epalloc starts every endpoint with, and
	# "maxpkt 64" on the CONTROL endpoint earlier said nothing about
	# these -- so without this the driver would move bulk data in
	# 8-byte packets and be told, correctly, that everything worked.
	# The size is the device's own answer, from its endpoint
	# descriptor: 512 for high speed, 64 for full.
	#
	if(setmaxpkt(inname, mp) < 0)
		return;
	if(outname != inname && setmaxpkt(outname, mp) < 0)
		return;
	sys->print("etherusb: %s bulk in %s out %s, maxpkt %d\n",
		dev, inname, outname, mp);

	if(family.setup() < 0)
		return;

	sys->print("etherusb: %s %s, MAC %2.2x:%2.2x:%2.2x:%2.2x:%2.2x:%2.2x\n",
		dev, family.name, int mac[0], int mac[1], int mac[2],
		int mac[3], int mac[4], int mac[5]);

	#
	# Open each endpoint for what it is.
	#
	# A separate IN endpoint was created "bulk r" and an OUT endpoint
	# "bulk w", so opening either ORDWR is refused -- correctly, and
	# reported as "permission denied", which reads like a protection
	# problem rather than a mode mismatch. Only the shared case is
	# genuinely read-write.
	#
	inmode := Sys->OREAD;
	outmode := Sys->OWRITE;
	if(outname == inname)
		inmode = outmode = Sys->ORDWR;

	bulkfd = sys->open("/usb/usb/" + inname + "/data", inmode);
	if(bulkfd == nil){
		sys->print("etherusb: cannot open %s: %r\n", inname);
		return;
	}
	if(outname == inname)
		bulkoutfd = bulkfd;
	else {
		bulkoutfd = sys->open("/usb/usb/" + outname + "/data", outmode);
		if(bulkoutfd == nil){
			sys->print("etherusb: cannot open %s: %r\n", outname);
			return;
		}
	}

	#
	# GET_CONFIGURATION, asked rather than assumed.
	#
	# Everything below depends on the device being configured, and
	# the failure mode if it is not is silence: the device answers
	# control requests, accepts the RNDIS handshake, and simply drops
	# every packet it is sent. A line of output here is cheaper than
	# discovering that from a packet capture.
	#
	gc := array[1] of byte;
	if(ctlin(Rd2h, Rgetconf, 0, 0, gc) < 1)
		sys->print("etherusb: GET_CONFIGURATION failed: %r\n");
	else if(int gc[0] != cfgval)
		sys->print("etherusb: device is in configuration %d, wanted %d\n",
			int gc[0], cfgval);

	sys->print("etherusb: %s ready\n", dev);

	#
	# Run the data-path self-test now rather than in setup: loopback
	# needs the bulk endpoint, which does not exist until here.
	#
	if(family.name == "lan78xx")
		lanselftest();
	serve();
}

#
# Say what endpoints this device actually has.
#
# The bulk endpoint number is assumed to be 2 in both directions, which
# is true of the RNDIS adapter this was written against and is an
# assumption nothing has ever checked. A device whose IN endpoint is on a
# different number would be read from an endpoint that does not exist,
# and the host controller reports that as a transaction error rather than
# as an empty read -- which is exactly what ep4.2 returns on this board.
#
dumpendpoints()
{
	hdr := array[9] of byte;

	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, hdr) < len hdr)
		return;
	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 512)
		return;
	cfg := array[total] of byte;
	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, cfg) < total)
		return;

	for(i := 0; i + 2 <= total; ){
		dlen := int cfg[i];
		if(dlen < 2)
			break;
		if(int cfg[i+1] == 5 && i + 6 < total){
			addr := int cfg[i+2];
			attr := int cfg[i+3];
			mp := int cfg[i+4] | (int cfg[i+5] << 8);
			dir := "out";
			if(addr & 16r80)
				dir = "in";
			kind := "control";
			case attr & 3 {
			1 => kind = "iso";
			2 => kind = "bulk";
			3 => kind = "interrupt";
			}
			sys->print("etherusb:   endpoint %d %s %s maxpkt %d\n",
				addr & 16rF, dir, kind, mp);
		}
		i += dlen;
	}
}

#
# The bulk endpoint numbers and packet size, from the configuration
# descriptor. Returns (in, out, maxpkt), each -1 if not found.
#
# Walked rather than indexed: a configuration is a run of
# variable-length descriptors packed end to end, each "length, type".
#
bulkeps(): (int, int, int)
{
	hdr := array[9] of byte;

	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, hdr) < len hdr)
		return (-1, -1, -1);
	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 512)
		return (-1, -1, -1);
	cfg := array[total] of byte;
	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, cfg) < total)
		return (-1, -1, -1);

	inep := -1;
	outep := -1;
	mp := -1;
	for(i := 0; i + 2 <= total; ){
		dlen := int cfg[i];
		if(dlen < 2)
			break;
		if(int cfg[i+1] == 5 && i + 6 < total && (int cfg[i+3] & 3) == 2){
			addr := int cfg[i+2];
			sz := int cfg[i+4] | (int cfg[i+5] << 8);
			if(addr & 16r80){
				if(inep < 0){
					inep = addr & 16rF;
					mp = sz;
				}
			}else if(outep < 0)
				outep = addr & 16rF;
		}
		i += dlen;
	}
	return (inep, outep, mp);
}

#
# Tell devusb the packet size for an endpoint it just created.
#
setmaxpkt(name: string, mp: int): int
{
	fd := sys->open("/usb/usb/" + name + "/ctl", Sys->ORDWR);
	if(fd == nil || sys->fprint(fd, "maxpkt %d", mp) < 0){
		sys->print("etherusb: cannot set %s packet size: %r\n", name);
		return -1;
	}
	return 0;
}


#
# wMaxPacketSize of the first bulk endpoint, from the configuration
# descriptor. Returns -1 if it cannot be found.
#
# Walked rather than indexed: the configuration arrives as a run of
# variable-length descriptors packed end to end, each "length, type".
#
bulkmaxpkt(): int
{
	hdr := array[9] of byte;

	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, hdr) < len hdr)
		return -1;
	total := int hdr[2] | (int hdr[3] << 8);
	if(total < len hdr || total > 512)
		return -1;

	cfg := array[total] of byte;
	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, cfg) < total)
		return -1;

	for(i := 0; i + 2 <= total; ){
		dlen := int cfg[i];
		if(dlen < 2)
			break;
		# 5 is an endpoint descriptor; bmAttributes 2 is bulk
		if(int cfg[i+1] == 5 && i + 6 < total && (int cfg[i+3] & 3) == 2)
			return int cfg[i+4] | (int cfg[i+5] << 8);
		i += dlen;
	}
	return -1;
}

#
# The device's own bConfigurationValue, from the first nine bytes of its
# configuration descriptor. Returns -1 if it cannot be read, in which
# case there is nothing safe to select.
#
configvalue(): int
{
	hdr := array[9] of byte;

	if(ctlin(Rd2h, Rgetdesc, Dconf << 8, 0, hdr) < len hdr){
		sys->print("etherusb: config descriptor failed: %r\n");
		return -1;
	}
	return int hdr[5];
}

#
# Serve the netif interface, and mount it where ethermedium will dial
# it.
#
# The mount is visible system-wide because this driver was spawned
# rather than forked into its own namespace: a device that only its own
# driver can see would be of no use to anyone.
#
serve()
{
	convs = array[Nconv] of ref Conv;
	for(i := 0; i < Nconv; i++)
		convs[i] = ref Conv(-1, array[Qmax] of array of byte, 0,
			array[Npend] of int, 0, 0, 0, 0);

	(tree, treeop) := nametree->start();
	tree.create(big Qdir, dir(".", Sys->DMDIR|8r555, Qdir));
	tree.create(big Qdir, dir("clone", 8r666, Qclone));
	for(i = 0; i < Nconv; i++){
		cd := Qcbase + i*4;
		tree.create(big Qdir, dir(string i, Sys->DMDIR|8r555, cd+Qcdir));
		tree.create(big (cd+Qcdir), dir("ctl", 8r666, cd+Qcctl));
		tree.create(big (cd+Qcdir), dir("data", 8r666, cd+Qcdata));
		tree.create(big (cd+Qcdir), dir("stats", 8r444, cd+Qcstats));
	}

	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		sys->print("etherusb: no pipe: %r\n");
		return;
	}
	(tc, srv) = Styxserver.new(p[0], Navigator.new(treeop), big Qdir);

	rxq = chan of (int, array of byte);
	spawn rxproc();

	#
	# The mount happens in ANOTHER process, and that is not a style
	# choice.
	#
	# Styxserver.new starts reading the pipe straight away and hands
	# every request to the channel this process is about to select
	# on. mount() begins by exchanging Tversion and Tattach with the
	# server -- so mounting from here would block sending the first
	# request to a channel that only this process, now stuck inside
	# mount, will ever read from. The server must be answering before
	# anything tries to mount it.
	#
	spawn mountproc(p[1]);

	loop(tree);
}

mountproc(fd: ref Sys->FD)
{
	if(sys->mount(fd, nil, "/net/ether0", Sys->MREPL, "") < 0){
		sys->print("etherusb: cannot mount /net/ether0: %r\n");
		return;
	}
	sys->print("etherusb: serving /net/ether0\n");
	netconfig();
}

#
# Bind an interface to this device and give it an address.
#
# DHCP first, and the hardcoded QEMU pair only if that finds nothing.
#
# The static address was always a stand-in and said so: choosing an
# address is policy, and 10.0.2.15/24 behind 10.0.2.2 is true of exactly
# one network -- QEMU's user-mode NAT, which is where this driver was
# written. On any real network it is meaningless, and the board sat with
# a live autonegotiated link and an address nobody could route to.
#
# Asking is the mechanism that removes the policy: the answer comes from
# the network rather than from this file, and the QEMU pair survives only
# as the fallback for the one network that has no DHCP server.
#
netconfig()
{
	ifc := sys->open("/net/ipifc/clone", Sys->ORDWR);
	if(ifc == nil){
		sys->print("etherusb: cannot clone an interface: %r\n");
		return;
	}

	nbuf := array[32] of byte;
	n := sys->read(ifc, nbuf, len nbuf);
	if(n <= 0){
		sys->print("etherusb: ipifc clone gave no number\n");
		return;
	}
	ifcno := string nbuf[0:n];

	if(sys->fprint(ifc, "bind ether /net/ether0") < 0){
		sys->print("etherusb: bind ether failed: %r\n");
		return;
	}
	#
	# An address is needed before DHCP can be spoken, because the
	# stack will not send from an interface that has none. 0.0.0.0 is
	# what the protocol expects a client to be using at this point.
	#
	if(sys->fprint(ifc, "add 0.0.0.0 0.0.0.0") < 0){
		sys->print("etherusb: add 0.0.0.0 failed: %r\n");
		return;
	}

	(addr, mask, gw) := dhcp();
	if(addr == nil){
		sys->print("etherusb: no DHCP answer; falling back to QEMU's addresses\n");
		addr = "10.0.2.15";
		mask = "255.255.255.0";
		gw = "10.0.2.2";
	}

	sys->fprint(ifc, "remove 0.0.0.0 0.0.0.0");
	if(sys->fprint(ifc, "add %s %s", addr, mask) < 0){
		sys->print("etherusb: add address failed: %r\n");
		return;
	}
	sys->print("etherusb: %s mask %s on ipifc %s\n", addr, mask, ifcno);

	if(gw != ""){
		r := sys->open("/net/iproute", Sys->ORDWR);
		if(r == nil || sys->fprint(r, "add 0.0.0.0 0.0.0.0 %s", gw) < 0)
			sys->print("etherusb: default route failed: %r\n");
		else
			sys->print("etherusb: default route via %s\n", gw);
	}

	#
	# The gateway first, then something beyond it.
	#
	# They fail differently and it is worth knowing which: the gateway
	# answering proves the interface, the address, ARP and the route;
	# an address on the far side of it proves the route actually
	# forwards. A board that can reach its router and nothing else is
	# a board with a working driver and a network problem.
	#
	if(gw != "")
		pingout(gw);
	pingout("8.8.8.8");
}

#
# Send one ICMP echo to the gateway and wait for the reply.
#
# This is the only check that proves the whole path rather than a part
# of it: the request leaves through RNDIS, over the bulk endpoint,
# through the hub, to QEMU's network stack -- and the reply comes back
# the other way, is demultiplexed by ether type onto the IPv4
# connection, and reaches os/ip. Everything up to here could be true
# with a device that quietly discarded every packet.
#
#
# A DHCP client, small enough to live here.
#
# The tree has one already (appl/cmd/ip/dhcp.b) and it is the right thing
# to use once this image can carry its module dependencies. It cannot
# yet, and an address obtained from the network beats an address written
# into a driver by enough that this is worth its own two hundred lines.
#
# Only what is needed: DISCOVER, OFFER, REQUEST, ACK, and the three
# options that make an interface usable -- netmask, router, and the
# server identity the REQUEST has to name. Leases are not renewed. This
# is a machine that has just booted asking what it is called, not a
# long-running client.
#

Bootpsize:	con 236;	# fixed part, before options
Udphdr7:	con 52;		# raddr, laddr, ifcaddr, rport, lport

Dhcpdiscover:	con 1;
Dhcpoffer:	con 2;
Dhcprequest:	con 3;
Dhcpack:	con 5;

Odmask:		con 1;		# subnet mask
Odrouter:	con 3;		# gateway
Odreqaddr:	con 50;		# the address being requested
Odmsgtype:	con 53;
Odserverid:	con 54;
Odparams:	con 55;
Odend:		con 255;

#
# The IPv6-mapped form of an IPv4 address, which is what the stack's
# header format carries even for v4 traffic.
#
v4map(a: array of byte, off: int, b0, b1, b2, b3: int)
{
	for(i := 0; i < 16; i++)
		a[off+i] = byte 0;
	a[off+10] = byte 16rFF;
	a[off+11] = byte 16rFF;
	a[off+12] = byte b0;
	a[off+13] = byte b1;
	a[off+14] = byte b2;
	a[off+15] = byte b3;
}

dotted(a: array of byte, off: int): string
{
	return sys->sprint("%d.%d.%d.%d", int a[off], int a[off+1],
		int a[off+2], int a[off+3]);
}

#
# Build the fixed part of a BOOTP request. Returns the length used.
#
dhcpfixed(p: array of byte, xid: int, mac: array of byte)
{
	for(i := 0; i < Bootpsize; i++)
		p[i] = byte 0;
	p[0] = byte 1;			# BOOTREQUEST
	p[1] = byte 1;			# ethernet
	p[2] = byte 6;			# six bytes of it
	p[4] = byte (xid >> 24);
	p[5] = byte (xid >> 16);
	p[6] = byte (xid >> 8);
	p[7] = byte xid;
	#
	# Ask for the reply by broadcast. We have no address yet, so a
	# server that unicasts to the address it is about to give us is
	# talking to something that cannot hear it.
	#
	p[10] = byte 16r80;
	p[28:] = mac[0:6];		# chaddr
	p[236-1] = byte 0;
}

#
# The option block: magic cookie, then type-length-value, then end.
#
dhcpopts(p: array of byte, off: int, kind: int, reqaddr, srvid: array of byte): int
{
	p[off++] = byte 99; p[off++] = byte 130;	# magic cookie
	p[off++] = byte 83; p[off++] = byte 99;

	p[off++] = byte Odmsgtype; p[off++] = byte 1; p[off++] = byte kind;

	if(reqaddr != nil){
		p[off++] = byte Odreqaddr; p[off++] = byte 4;
		p[off:] = reqaddr[0:4];
		off += 4;
	}
	if(srvid != nil){
		p[off++] = byte Odserverid; p[off++] = byte 4;
		p[off:] = srvid[0:4];
		off += 4;
	}

	p[off++] = byte Odparams; p[off++] = byte 2;
	p[off++] = byte Odmask; p[off++] = byte Odrouter;

	p[off++] = byte Odend;
	return off;
}

#
# Find an option in a reply. Returns nil if it is not there.
#
dhcpopt(p: array of byte, n, want: int): array of byte
{
	off := Bootpsize + 4;		# past the fixed part and the cookie
	while(off + 2 <= n){
		kind := int p[off];
		if(kind == Odend)
			break;
		if(kind == 0){		# pad
			off++;
			continue;
		}
		olen := int p[off+1];
		if(off + 2 + olen > n)
			break;
		if(kind == want){
			v := array[olen] of byte;
			v[0:] = p[off+2:off+2+olen];
			return v;
		}
		off += 2 + olen;
	}
	return nil;
}

#
# Ask the network what this machine is called. Returns
# (address, mask, gateway), all nil if nobody answered.
#
dhcp(): (string, string, string)
{
	c := sys->open("/net/udp/clone", Sys->ORDWR);
	if(c == nil){
		sys->print("etherusb: cannot clone udp: %r\n");
		return (nil, nil, nil);
	}
	nbuf := array[32] of byte;
	nn := sys->read(c, nbuf, len nbuf);
	if(nn <= 0)
		return (nil, nil, nil);
	conv := string nbuf[0:nn];

	if(sys->fprint(c, "headers") < 0 ||
	   sys->fprint(c, "announce 68") < 0){
		sys->print("etherusb: udp setup failed: %r\n");
		return (nil, nil, nil);
	}

	d := sys->open("/net/udp/" + conv + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("etherusb: cannot open udp data: %r\n");
		return (nil, nil, nil);
	}

	rc := chan of array of byte;
	spawn dhcpreader(d, rc);

	xid := sys->millisec() | 1;
	pkt := array[Udphdr7 + 576] of byte;

	for(try := 0; try < 3; try++){
		if(dhcpxchg(d, pkt, xid, Dhcpdiscover, nil, nil) < 0)
			continue;
		offer := dhcpwait(rc, xid, Dhcpoffer, 2000);
		if(offer == nil)
			continue;

		yiaddr := array[4] of byte;
		yiaddr[0:] = offer[16:20];
		srvid := dhcpopt(offer, len offer, Odserverid);
		if(srvid == nil || len srvid < 4)
			continue;

		if(dhcpxchg(d, pkt, xid, Dhcprequest, yiaddr, srvid) < 0)
			continue;
		ack := dhcpwait(rc, xid, Dhcpack, 2000);
		if(ack == nil)
			continue;

		addr := dotted(ack, 16);
		mask := "255.255.255.0";
		gw := "";
		m := dhcpopt(ack, len ack, Odmask);
		if(m != nil && len m >= 4)
			mask = dotted(m, 0);
		g := dhcpopt(ack, len ack, Odrouter);
		if(g != nil && len g >= 4)
			gw = dotted(g, 0);
		sys->print("etherusb: DHCP gave %s mask %s\n", addr, mask);
		return (addr, mask, gw);
	}
	sys->print("etherusb: no DHCP reply after 3 tries\n");
	return (nil, nil, nil);
}

#
# Send one DHCP message to the broadcast address.
#
dhcpxchg(d: ref Sys->FD, pkt: array of byte, xid, kind: int,
	reqaddr, srvid: array of byte): int
{
	v4map(pkt, 0, 255, 255, 255, 255);	# raddr
	v4map(pkt, 16, 0, 0, 0, 0);		# laddr
	v4map(pkt, 32, 0, 0, 0, 0);		# ifcaddr
	pkt[48] = byte 0; pkt[49] = byte 67;	# rport
	pkt[50] = byte 0; pkt[51] = byte 68;	# lport

	body := pkt[Udphdr7:];
	dhcpfixed(body, xid, mac);
	n := dhcpopts(body, Bootpsize, kind, reqaddr, srvid);

	if(sys->write(d, pkt, Udphdr7 + n) != Udphdr7 + n){
		sys->print("etherusb: DHCP send failed: %r\n");
		return -1;
	}
	return 0;
}

#
# Read the socket in its own process, because a read on it BLOCKS.
#
# The obvious loop -- read, check, sleep, try again -- cannot time out:
# with no server on the network the first read never returns, the retry
# never happens, and the fallback that exists precisely for a network
# with no DHCP server can never be reached. The boot hangs on the one
# case the fallback was written for.
#
dhcpreader(d: ref Sys->FD, c: chan of array of byte)
{
	for(;;){
		buf := array[Udphdr7 + 576] of byte;
		n := sys->read(d, buf, len buf);
		if(n <= 0)
			break;
		c <-= buf[0:n];
	}
}

dhcptimer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

#
# Wait for a reply of the wanted type carrying our transaction id.
# Returns the body, or nil if none arrived in time.
#
dhcpwait(c: chan of array of byte, xid, want, ms: int): array of byte
{
	t := chan of int;
	spawn dhcptimer(t, ms);

	for(;;){
		alt {
		buf := <-c =>
			if(len buf <= Udphdr7 + Bootpsize)
				continue;
			body := buf[Udphdr7:];
			got := (int body[4] << 24) | (int body[5] << 16) |
				(int body[6] << 8) | int body[7];
			if(got != xid)
				continue;
			ty := dhcpopt(body, len body, Odmsgtype);
			if(ty == nil || len ty < 1 || int ty[0] != want)
				continue;
			return body;
		<-t =>
			return nil;
		}
	}
}

pingout(dest: string)
{
	c := sys->open("/net/icmp/clone", Sys->ORDWR);
	if(c == nil){
		sys->print("etherusb: cannot clone icmp: %r\n");
		return;
	}

	nbuf := array[32] of byte;
	n := sys->read(c, nbuf, len nbuf);
	if(n <= 0){
		sys->print("etherusb: icmp clone gave no number\n");
		return;
	}
	conv := string nbuf[0:n];

	#
	# The gateway DHCP named, not the one this was written against.
	#
	# This said "connect 10.0.2.2!1" while taking the address as an
	# argument and ignoring it -- so on a real network it pinged
	# QEMU's gateway, which is not there, and said nothing at all
	# about it.
	#
	if(sys->fprint(c, "connect %s!1", dest) < 0){
		sys->print("etherusb: icmp connect to %s failed: %r\n", dest);
		return;
	}

	d := sys->open("/net/icmp/" + conv + "/data", Sys->ORDWR);
	if(d == nil){
		sys->print("etherusb: cannot open icmp data: %r\n");
		return;
	}

	# 20 bytes of IP header space, then an 8-byte ICMP header and a
	# little payload. icmp.c fills the header in.
	req := array[20 + 8 + 8] of byte;
	for(i := 0; i < len req; i++)
		req[i] = byte 0;
	req[20] = byte 8;		# type: echo request
	req[20+6] = byte 0;		# sequence
	req[20+7] = byte 1;

	#
	# Send repeatedly rather than once.
	#
	# The first echo request is sent before the gateway's hardware
	# address is known, so os/ip has to hold it pending ARP -- and if
	# that resolution loses the race, the request is dropped and
	# nothing here would ever ask again. Retransmitting is what every
	# ping does, and it is the difference between this answering
	# reliably and answering about one time in three.
	#
	spawn pingsend(d, req);

	#
	# Bounded, for the same reason the DHCP read is: a read on this
	# socket blocks, so a host that does not answer takes the caller
	# with it. This one produced no output at all on the board --
	# neither a reply nor a failure -- which is what a blocked read
	# looks like from outside.
	#
	rc := chan of array of byte;
	spawn pingreader(d, rc);
	tc := chan of int;
	spawn dhcptimer(tc, 3000);

	alt {
	rep := <-rc =>
		sys->print("etherusb: ICMP echo reply from %s (%d bytes, type %d)\n",
			dest, len rep, int rep[20]);
	<-tc =>
		sys->print("etherusb: no echo reply from %s\n", dest);
	}
}

pingreader(d: ref Sys->FD, c: chan of array of byte)
{
	rep := array[128] of byte;
	n := sys->read(d, rep, len rep);
	if(n > 0)
		c <-= rep[0:n];
}

#
# A control transfer with an optional OUT data stage.
#
# devusb takes the setup packet and its data as ONE write -- ctltrans
# computes the data length as (what was written - 8) -- so they cannot
# be sent separately.
#
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

	# The reply must be collected even when there is none to speak
	# of: devusb parks it and hands a stale one to the next request.
	rep := array[8] of byte;
	sys->read(ep0, rep, len rep);
	return 0;
}

#
# A control transfer with an IN data stage.
#
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

#
# Send one RNDIS message and collect its reply.
#
rndis(msg: array of byte, reply: array of byte): int
{
	if(ctlout(Rh2d|Rclass|Riface, Rsendenc, 0, 0, msg) < 0)
		return -1;

	#
	# The device signals a waiting reply on the interrupt endpoint,
	# but the reply itself is fetched with a control request. Since
	# every message here is request/response and nothing else is in
	# flight, fetching it directly is correct and saves opening the
	# interrupt endpoint at all.
	#
	return ctlin(Rd2h|Rclass|Riface, Rgetenc, 0, 0, reply);
}

rndisinit(): int
{
	msg := array[24] of byte;
	put4(msg, 0, Rnisinit);
	put4(msg, 4, 24);
	put4(msg, 8, reqid++);
	put4(msg, 12, 1);		# major version
	put4(msg, 16, 0);		# minor version
	put4(msg, 20, 16r4000);		# max transfer size

	reply := array[Maxctl] of byte;
	n := rndis(msg, reply);
	if(n < 16){
		sys->print("etherusb: RNDIS initialise got %d bytes: %r\n", n);
		return -1;
	}
	if(get4(reply, 0) != Rnisinitc){
		sys->print("etherusb: RNDIS initialise replied %8.8bux\n",
			get4(reply, 0));
		return -1;
	}
	if(get4(reply, 12) != big 0){
		sys->print("etherusb: RNDIS initialise status %8.8bux\n",
			get4(reply, 12));
		return -1;
	}

	sys->print("etherusb: RNDIS %bd.%bd, max transfer %bd\n",
		get4(reply, 16), get4(reply, 20), get4(reply, 36));
	return 0;
}

rndisquery(oid: int, out: array of byte): int
{
	msg := array[28] of byte;
	put4(msg, 0, Rnisquery);
	put4(msg, 4, 28);
	put4(msg, 8, reqid++);
	put4(msg, 12, oid);
	put4(msg, 16, 0);		# information buffer length
	put4(msg, 20, 0);		# offset, from byte 8 of the message
	put4(msg, 24, 0);		# device VC handle

	reply := array[Maxctl] of byte;
	n := rndis(msg, reply);
	if(n < 24)
		return -1;
	if(get4(reply, 0) != Rnisqueryc || get4(reply, 12) != big 0)
		return -1;

	#
	# The offset is counted from byte 8 of the message, not from its
	# start -- a detail that silently yields the wrong eight bytes if
	# it is taken as absolute.
	#
	inlen := int get4(reply, 16);
	off := int get4(reply, 20) + 8;
	if(inlen < len out || off + len out > n)
		return -1;

	out[0:] = reply[off:off + len out];
	return 0;
}

rndisset(oid: int, val: array of byte): int
{
	msg := array[28 + len val] of byte;
	put4(msg, 0, Rnisset);
	put4(msg, 4, len msg);
	put4(msg, 8, reqid++);
	put4(msg, 12, oid);
	put4(msg, 16, len val);
	put4(msg, 20, 20);		# offset from byte 8: 28 - 8
	put4(msg, 24, 0);
	msg[28:] = val;

	reply := array[Maxctl] of byte;
	n := rndis(msg, reply);
	if(n < 16)
		return -1;
	if(get4(reply, 0) != Rnissetc || get4(reply, 12) != big 0)
		return -1;
	return 0;
}

#
# RNDIS is little-endian throughout, which is neither the network order
# the rest of this system uses nor something the language does for us.
#
put4(a: array of byte, off, v: int)
{
	a[off] = byte (v & 16rFF);
	a[off+1] = byte ((v >> 8) & 16rFF);
	a[off+2] = byte ((v >> 16) & 16rFF);
	a[off+3] = byte ((v >> 24) & 16rFF);
}

#
# big, not int.
#
# These are unsigned 32-bit values off the wire and Limbo's int is
# SIGNED 32-bit, so every RNDIS completion code -- they all have bit 31
# set, that is what marks them as completions -- is unrepresentable as
# an int. The compiler catches the comparison rather than silently
# sign-extending, which is the good outcome, but the fix is to hold the
# value in a type that can contain it rather than to cast the error
# away.
#
get4(a: array of byte, off: int): big
{
	return big a[off] | (big a[off+1] << 8) |
		(big a[off+2] << 16) | (big a[off+3] << 24);
}

#
# "ep3.0", 2 -> "ep3.2": same device, a different endpoint on it.
#
epname(d: string, nb: int): string
{
	for(i := len d - 1; i >= 0; i--)
		if(d[i] == '.')
			return d[0:i+1] + string nb;
	return d;
}

dir(name: string, perm: int, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = "inferno";
	d.gid = "inferno";
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}

qconv(path: int): int
{
	return (path - Qcbase) / 4;
}

qkind(path: int): int
{
	return (path - Qcbase) % 4;
}

#
# The serve loop handles 9P requests and arriving frames in ONE
# process, which is what makes the pending-read bookkeeping safe: a
# reply is only ever written from here.
#
# A read of <n>/data with no frame waiting cannot be answered yet, so
# its tag is remembered and answered when one arrives. Doing that by
# blocking here instead would stall every other connection, and doing
# it by spawning a process per read would have several of them writing
# replies down the same pipe at once.
#
loop(tree: ref Tree)
{
	done := 0;

	while(done == 0){
		alt {
		tmsg := <-tc =>
			if(tmsg == nil)
				done = 1;
			else
				done = request(tmsg);
		(ci, frame) := <-rxq =>
			deliver(ci, frame);
		}
	}
	tree.quit();
}

request(tmsg: ref Tmsg): int
{
	pick tm := tmsg {
	Readerror =>
		return 1;
	Open =>
		return openreq(tm);
	Read =>
		return readreq(tm);
	Write =>
		return writereq(tm);
	Flush =>
		# Cancel any read waiting on this tag before acknowledging,
		# or a frame arriving later would be replied to a tag the
		# client has already given up on.
		for(i := 0; i < Nconv; i++)
			unpend(convs[i], tm.oldtag);
		srv.reply(ref Rmsg.Flush(tm.tag));
	Clunk =>
		srv.clunk(tm);
	* =>
		srv.default(tmsg);
	}
	return 0;
}

#
# Opening clone allocates a connection AND rebinds the fid to that
# connection's ctl file.
#
# That is not a flourish: os/port/dial.c writes "connect ..." to the
# same descriptor it opened clone with, so the clone fid has to BE the
# new connection's ctl afterwards. A server that returns only a number
# and leaves the fid pointing at clone gets the connect request written
# to the wrong file.
#
openreq(tm: ref Tmsg.Open): int
{
	(c, mode, f, err) := srv.canopen(tm);
	if(c == nil){
		srv.reply(ref Rmsg.Error(tm.tag, err));
		return 0;
	}
	if(int c.path != Qclone){
		c.open(mode, f.qid);
		srv.reply(ref Rmsg.Open(tm.tag, f.qid, srv.iounit()));
		return 0;
	}

	n := -1;
	for(i := 0; i < Nconv; i++)
		if(convs[i].etype < 0){
			n = i;
			break;
		}
	if(n < 0){
		srv.reply(ref Rmsg.Error(tm.tag, "no free connections"));
		return 0;
	}
	convs[n].etype = 0;		# taken, not yet connected

	q := Sys->Qid(big (Qcbase + n*4 + Qcctl), 0, Sys->QTFILE);
	c.open(mode, q);
	srv.reply(ref Rmsg.Open(tm.tag, q, srv.iounit()));
	return 0;
}

readreq(tm: ref Tmsg.Read): int
{
	(c, err) := srv.canread(tm);
	if(c == nil){
		srv.reply(ref Rmsg.Error(tm.tag, err));
		return 0;
	}
	path := int c.path;
	if(path == Qdir){
		srv.read(tm);
		return 0;
	}
	if(path < Qcbase){
		srv.reply(ref Rmsg.Error(tm.tag, "phase error"));
		return 0;
	}

	n := qconv(path);
	case qkind(path) {
	Qcdir =>
		srv.read(tm);
	Qcctl =>
		# The connection number, which is what dial reads back.
		srv.reply(styxservers->readstr(tm, string n));
	Qcstats =>
		srv.reply(styxservers->readstr(tm, stats(n)));
	Qcdata =>
		cv := convs[n];
		#
		# A read of nothing is answered with nothing, at once.
		#
		# It must never be parked waiting for a frame. ethermedium
		# starts its reader processes from inside etherbind(), and
		# ipifcbind() only sets ifc->maxtu AFTER that returns -- so
		# the first read each of them issues asks for
		# ifc->maxtu == 0 bytes. Parking those means the readers
		# never come back to issue a real read, and worse, the
		# first frame to arrive is handed to a zero-length read and
		# truncated away. That is precisely what happened to the
		# ARP reply: delivered, consumed, and reported to arp.c as
		# "0 bytes".
		#
		if(tm.count == 0){
			srv.reply(ref Rmsg.Read(tm.tag, array[0] of byte));
			return 0;
		}
		if(cv.nq > 0){
			frame := cv.q[0];
			for(i := 1; i < cv.nq; i++)
				cv.q[i-1] = cv.q[i];
			cv.nq--;
			srv.reply(ref Rmsg.Read(tm.tag, frame));
		}else if(cv.npend < Npend)
			cv.pend[cv.npend++] = tm.tag;
		else
			srv.reply(ref Rmsg.Error(tm.tag, "too many reads outstanding"));
	* =>
		srv.reply(ref Rmsg.Error(tm.tag, "phase error"));
	}
	return 0;
}

writereq(tm: ref Tmsg.Write): int
{
	(c, err) := srv.canwrite(tm);
	if(c == nil){
		srv.reply(ref Rmsg.Error(tm.tag, err));
		return 0;
	}
	path := int c.path;
	if(path < Qcbase){
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		return 0;
	}

	n := qconv(path);
	case qkind(path) {
	Qcctl =>
		e := ctlwrite(n, string tm.data);
		if(e != nil)
			srv.reply(ref Rmsg.Error(tm.tag, e));
		else
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	Qcdata =>
		if(transmit(tm.data) < 0)
			srv.reply(ref Rmsg.Error(tm.tag, "write failed"));
		else {
			convs[n].outpkt++;
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		}
	* =>
		srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
	}
	return 0;
}

ctlwrite(n: int, s: string): string
{
	(nf, flds) := sys->tokenize(s, " \t\n");
	if(nf < 1)
		return "empty control request";

	case hd flds {
	"connect" =>
		if(nf != 2)
			return "usage: connect <ethertype>";
		convs[n].etype = hexint(hd tl flds);
	"nonblocking" =>
		# Accepted and ignored: every read here is already answered
		# out of a queue or deferred, so nothing blocks the client
		# that this could switch off.
		;
	* =>
		return "unknown control request";
	}
	return nil;
}

stats(n: int): string
{
	cv := convs[n];
	return sys->sprint("in: %d\nlink: 1\nout: %d\ncrc errs: 0\n" +
		"overflows: %d\nsoft overflows: 0\nframing errs: 0\n" +
		"buffer size: %d\nmbps: 100\naddr: %2.2x%2.2x%2.2x%2.2x%2.2x%2.2x\n",
		cv.inpkt, cv.outpkt, cv.drops, Maxframe,
		int mac[0], int mac[1], int mac[2],
		int mac[3], int mac[4], int mac[5]);
}

unpend(cv: ref Conv, tag: int)
{
	for(i := 0; i < cv.npend; i++)
		if(cv.pend[i] == tag){
			for(j := i+1; j < cv.npend; j++)
				cv.pend[j-1] = cv.pend[j];
			cv.npend--;
			return;
		}
}

#
# A frame has arrived for connection ci. Answer a waiting read if there
# is one, otherwise queue it, otherwise drop it -- which is what a NIC
# does when nobody is collecting, and is counted rather than hidden.
#
deliver(ci: int, frame: array of byte)
{
	cv := convs[ci];
	cv.inpkt++;

	if(cv.npend > 0){
		tag := cv.pend[0];
		for(i := 1; i < cv.npend; i++)
			cv.pend[i-1] = cv.pend[i];
		cv.npend--;
		srv.reply(ref Rmsg.Read(tag, frame));
		return;
	}
	if(cv.nq < Qmax)
		cv.q[cv.nq++] = frame;
	else
		cv.drops++;
}

#
# Wrap an Ethernet frame in an RNDIS packet message and send it.
#
transmit(frame: array of byte): int
{
	buf := family.wrap(frame);

	if(sys->write(bulkoutfd, buf, len buf) != len buf)
		return -1;
	return 0;
}

#
# Read frames off the bulk endpoint for as long as the device lives.
#
# One bulk read can carry several RNDIS messages, so the buffer is
# walked rather than assumed to hold exactly one.
#
rxproc()
{
	#
	# Reassembly, because a read boundary is not a message boundary.
	#
	# The endpoint delivers maxpkt bytes at a time and a read ends at
	# the first short packet, so a message larger than one packet --
	# which every Ethernet frame is -- can arrive split across two
	# reads. Parsing each read on its own throws away the head of
	# every such message and then finds nonsense where the next header
	# should be, which is worse than losing a frame: the stream never
	# resynchronises.
	#
	# So keep what does not yet form a whole message, and prepend it
	# to the next read. What counts as a whole message is the family's
	# business, not this loop's.
	#
	acc := array[2 * (Rnishdr + Maxframe)] of byte;
	nacc := 0;

	for(;;){
		if(nacc >= len acc)			# desynchronised; start over
			nacc = 0;

		n := sys->read(bulkfd, acc[nacc:], len acc - nacc);
		if(n < 0){
			sys->print("etherusb: bulk read failed: %r\n");
			return;
		}
		if(n == 0){
			#
			# Nothing waiting. Pause before asking again: without
			# it this is a busy loop on the bus.
			#
			sys->sleep(20);
			continue;
		}
		nacc += n;

		off := 0;
		while(off < nacc){
			(used, frame) := family.unwrap(acc[off:nacc], nacc - off);
			if(used < 0){		# never going to parse; drop it
				off = nacc;
				break;
			}
			if(used == 0)		# incomplete; wait for more
				break;
			off += used;

			if(frame == nil)
				continue;

			#
			# Ether type is bytes 12 and 13, after the two
			# addresses. It is the only field this driver has to
			# understand: everything above the demultiplex is
			# os/ip's business.
			#
			etype := (int frame[12] << 8) | int frame[13];
			for(i := 0; i < Nconv; i++)
				if(convs[i].etype == etype){
					rxq <-= (i, frame);
					break;
				}
		}

		# Shuffle whatever is left of a partial message to the front.
		if(off > 0 && off < nacc)
			acc[0:] = acc[off:nacc];
		nacc -= off;
	}
}

#
# "0x800" -> 2048. Limbo's string-to-int conversion stops at the 'x',
# and every ether type ethermedium dials is written that way -- so
# taking it as decimal silently binds every connection to type 0 and
# the demultiplex never matches anything.
#
hexint(s: string): int
{
	if(len s > 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s = s[2:];

	v := 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		d := -1;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		if(d < 0)
			break;
		v = v * 16 + d;
	}
	return v;
}

pingsend(d: ref Sys->FD, req: array of byte)
{
	for(i := 0; i < 8; i++){
		if(sys->write(d, req, len req) != len req){
			sys->print("etherusb: icmp write failed: %r\n");
			return;
		}
		sys->sleep(300);
	}
}

#
# The RNDIS family.
#
# What QEMU's usb-net speaks, and what makes this program testable
# before there is hardware. Microsoft's protocol carries its control
# messages inside two class requests rather than on an endpoint of its
# own, and puts a 44-byte header on every frame.
#
rndissetup(): int
{
	if(rndisinit() < 0)
		return -1;

	#
	# No ":=" on mac. It is module-level state because the stats file
	# has to report it long after setup returns, and declaring it
	# again here would make a local that shadows it -- leaving the
	# global zero, the stats file answering "addr: 000000000000", and
	# every frame going out from 00:00:00:00:00:00. Which is exactly
	# what happened: the ARP requests were sent and answered, and the
	# replies were addressed to a MAC no device owned.
	#
	if(rndisquery(Oidmac, mac) < 0){
		sys->print("etherusb: cannot read the MAC address: %r\n");
		return -1;
	}

	filter := array[4] of byte;
	put4(filter, 0, Filterdefault);
	if(rndisset(Oidfilter, filter) < 0){
		sys->print("etherusb: cannot set the packet filter: %r\n");
		return -1;
	}
	return 0;
}

rndiswrap(frame: array of byte): array of byte
{
	buf := array[Rnishdr + len frame] of byte;
	for(i := 0; i < Rnishdr; i++)
		buf[i] = byte 0;

	put4(buf, 0, Rnisdata);
	put4(buf, 4, len buf);
	# DataOffset counts from byte 8 of the message, not from its start
	put4(buf, 8, Rnishdr - 8);
	put4(buf, 12, len frame);
	buf[Rnishdr:] = frame;
	return buf;
}

#
# Returns (bytes consumed, frame), (0, nil) if buf does not yet hold a
# whole message, or (-1, nil) if it never will.
#
rndisunwrap(buf: array of byte, n: int): (int, array of byte)
{
	if(n < Rnishdr)
		return (0, nil);
	if(get4(buf, 0) != big Rnisdata)
		return (-1, nil);

	msglen := int get4(buf, 4);
	if(msglen < Rnishdr)
		return (-1, nil);
	if(msglen > n)
		return (0, nil);

	dataoff := 8 + int get4(buf, 8);
	datalen := int get4(buf, 12);
	if(datalen < 14 || dataoff + datalen > n)
		return (msglen, nil);	# consume it; there is no frame in it

	frame := array[datalen] of byte;
	frame[0:] = buf[dataoff:dataoff+datalen];
	return (msglen, frame);
}

#
# The device's vendor and product, from its descriptor. Asked rather
# than passed down, so this program does not depend on whoever started
# it having got the identity right.
#
devid(): (int, int)
{
	desc := array[18] of byte;

	if(ctlin(Rd2h, Rgetdesc, Ddev << 8, 0, desc) < len desc)
		return (-1, -1);
	return (int desc[8] | (int desc[9] << 8),
		int desc[10] | (int desc[11] << 8));
}

#
# The LAN78xx family.
#
# Registers are 32 bits, little-endian, addressed by wIndex and carried
# in the data stage of a vendor request.
#
lanrd(reg: int): (int, int)
{
	v := array[4] of byte;

	if(ctlin(Rvendorin, Rreadreg, 0, reg, v) < len v)
		return (-1, 0);
	return (0, int get4(v, 0));
}

lanwr(reg, val: int): int
{
	v := array[4] of byte;

	put4(v, 0, val);
	return ctlout(Rvendor, Rwritereg, 0, reg, v);
}

#
# Wait for MII_ACC to self-clear, which is how this part signals that an
# MDIO access has finished.
#
lanmiiwait(): int
{
	for(i := 0; i < 100; i++){
		(e, v) := lanrd(Lmiiacc);
		if(e < 0)
			return -1;
		if((v & Lmiibusy) == 0)
			return 0;
		sys->sleep(1);
	}
	sys->print("etherusb: LAN78xx MDIO stayed busy\n");
	return -1;
}

lanmiird(reg: int): (int, int)
{
	if(lanmiiwait() < 0)
		return (-1, 0);
	acc := (Lphyaddr << Lmiiphyshift) | (reg << Lmiiregshift) | Lmiibusy;
	if(lanwr(Lmiiacc, acc) < 0)
		return (-1, 0);
	if(lanmiiwait() < 0)
		return (-1, 0);
	(e, v) := lanrd(Lmiidata);
	if(e < 0)
		return (-1, 0);
	return (0, v & 16rFFFF);
}

lanmiiwr(reg, val: int): int
{
	if(lanmiiwait() < 0)
		return -1;
	if(lanwr(Lmiidata, val & 16rFFFF) < 0)
		return -1;
	acc := (Lphyaddr << Lmiiphyshift) | (reg << Lmiiregshift) |
		Lmiiwrite | Lmiibusy;
	if(lanwr(Lmiiacc, acc) < 0)
		return -1;
	return lanmiiwait();
}

#
# Bring the PHY up and wait for a link.
#
# Until this ran, the MAC was configured and the wire was dead: every
# bulk IN came back as a transaction error because there was nothing on
# the other side of the receiver to produce a packet. Auto-negotiation
# with a switch takes seconds, not milliseconds, which is why the wait
# here is generous and why it reports rather than failing -- a board on
# a desk with no cable in it is not a broken driver.
#
lanphy(): int
{
	(e1, id1) := lanmiird(Mphyid1);
	(e2, id2) := lanmiird(Mphyid2);
	if(e1 < 0 || e2 < 0){
		sys->print("etherusb: LAN78xx PHY id read failed: %r\n");
		return -1;
	}
	if(id1 == 0 || id1 == 16rFFFF){
		sys->print("etherusb: LAN78xx PHY id reads %4.4ux -- no PHY\n", id1);
		return -1;
	}
	sys->print("etherusb: LAN78xx PHY id %4.4ux%4.4ux\n", id1, id2);

	if(lanmiiwr(Mbmcr, Mbmcrreset) < 0){
		sys->print("etherusb: LAN78xx PHY reset failed: %r\n");
		return -1;
	}
	for(i := 0; i < 100; i++){
		(e, v) := lanmiird(Mbmcr);
		if(e < 0)
			return -1;
		if((v & Mbmcrreset) == 0)
			break;
		sys->sleep(10);
	}

	if(lanmiiwr(Mbmcr, Mbmcraneg | Mbmcrrestart) < 0){
		sys->print("etherusb: LAN78xx autonegotiation failed to start: %r\n");
		return -1;
	}

	for(i = 0; i < 100; i++){
		(e, sr) := lanmiird(Mbmsr);
		if(e < 0)
			return -1;
		#
		# BMSR latches link-down low, so it is read twice: the
		# first read clears a stale drop and the second is the
		# current state. Reading it once reports a link that came
		# up moments ago as still down.
		#
		(e, sr) = lanmiird(Mbmsr);
		if(e < 0)
			return -1;
		if(sr & Mbmsrlink){
			how := "";
			if(sr & Mbmsraneg)
				how = " (autonegotiated)";
			sys->print("etherusb: LAN78xx link up%s\n", how);
			return 0;
		}
		sys->sleep(100);
	}
	sys->print("etherusb: LAN78xx no link (cable unplugged?)\n");
	return 0;
}

#
# Called once the endpoint is open, which loopback needs and lanphy()
# runs too early to have.
#
lanselftest()
{
	(e, sr) := lanmiird(Mbmsr);
	if(e < 0)
		return;
	(e, sr) = lanmiird(Mbmsr);
	if(e < 0 || (sr & Mbmsrlink))
		return;		# a real link is a better test than this one
	sys->print("etherusb: no link -- testing the data path in loopback\n");
	if(lanloopback(Lpby) == 0)
		return;
	sys->print("etherusb: PHY loopback did not return a frame; trying the MAC\n");
	if(lanloopback(Lmacy) == 0)
		return;
	sys->print("etherusb: loopback: nothing came back either way\n");
}

#
# Do these two addresses match?
#
# Written out because Limbo's == on arrays compares REFERENCES, not
# contents: "frame[0:6] == mac[0:6]" compiles, is always false, and was
# the entire reason this test reported failure while the chip was doing
# exactly what it was asked. The frame came back with RX_CMD_A 00008040
# -- 64 bytes, unicast address matched -- and was thrown away by the
# comparison meant to recognise it.
#
sameaddr(a, b: array of byte): int
{
	if(len a < 6 || len b < 6)
		return 0;
	for(i := 0; i < 6; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

#
# Write MAC_CR with the MAC stopped, which is the only time it listens.
#
# The board proved this rather than a datasheet: MAC_CR was written with
# the auto bits cleared and full duplex set, and read back 00001802 --
# ADP had cleared, AUTO_DUPLEX and AUTO_SPEED had not, and FULL_DUPLEX
# had not set. A register that accepts some of a write and ignores the
# rest is a register being written at the wrong time, and it is why the
# loopback bit never took either.
#
# Stopping the receiver and transmitter around it costs nothing here and
# explains a whole evening of settings that appeared to apply.
#
lanmaccr(val: int): int
{
	(e1, rx) := lanrd(Lmacrx);
	(e2, tx) := lanrd(Lmactx);
	if(e1 < 0 || e2 < 0)
		return -1;

	if(lanwr(Lmacrx, rx & ~Lrxen) < 0 || lanwr(Lmactx, tx & ~Ltxen) < 0)
		return -1;
	if(lanwr(Lmaccr, val) < 0)
		return -1;
	if(lanwr(Lmactx, tx) < 0 || lanwr(Lmacrx, rx) < 0)
		return -1;

	(e3, v) := lanrd(Lmaccr);
	if(e3 < 0)
		return -1;
	#
	# Ignore speed and duplex when checking the readback.
	#
	# With AUTO_SPEED and AUTO_DUPLEX set the hardware maintains those
	# fields itself, so they are status as much as control: MAC_CR
	# comes back 00003802 for a write of 00003800 because the chip
	# filled in 100Mb/s, which is correct and not a failed write. The
	# check exists to catch a register that ignored us, and it should
	# not report the one case where the register is doing its job.
	#
	if((v & ~(Lmacspdmask|Lmacfull)) != (val & ~(Lmacspdmask|Lmacfull)))
		sys->print("etherusb: MAC_CR wanted %8.8ux got %8.8ux\n", val, v);
	return 0;
}

#
# What every register in the data path says right now.
#
# Not called on a good path. It is kept because it is what identified
# the MAC that would not start -- mac_rx, mac_tx and both FIFOs all
# correct while INT_STS read 00000000 -- and the next fault in this
# chip will want exactly the same photograph.
#
lanstate(when: string)
{
	(e1, cr) := lanrd(Lmaccr);
	(e2, rx) := lanrd(Lmacrx);
	(e3, tx) := lanrd(Lmactx);
	(e4, fr) := lanrd(Lfctrxctl);
	(e5, ft) := lanrd(Lfcttxctl);
	(e6, rf) := lanrd(Lrfectl);
	(e7, is) := lanrd(Lintsts);
	if(e1 < 0 || e2 < 0 || e3 < 0 || e4 < 0 || e5 < 0 || e6 < 0 || e7 < 0){
		sys->print("etherusb: %s: register read failed: %r\n", when);
		return;
	}
	sys->print("etherusb: %s mac_cr %8.8ux mac_rx %8.8ux mac_tx %8.8ux\n",
		when, cr, rx, tx);
	sys->print("etherusb: %s fct_rx %8.8ux fct_tx %8.8ux rfe %8.8ux int %8.8ux\n",
		when, fr, ft, rf, is);
}

#
# Undo whichever loopback was set, and put the PHY back to negotiating.
#
lanunloop(cr: int)
{
	lanmaccr(cr);
	lanmiiwr(Mbmcr, Mbmcraneg | Mbmcrrestart);
}

#
# Send a frame to ourselves through the PHY's internal loopback.
#
# This exists because a link needs something at the other end of the
# cable, and the whole data path below the link does not. Loopback ties
# the PHY's transmitter to its own receiver inside the chip, so a frame
# goes out through the TX header, the MAC and the transmit FIFO, comes
# back through the receive FIFO and the RX header, and arrives on the
# bulk endpoint -- every line of this driver that carries data, with no
# cable and no switch involved.
#
# Auto-negotiation cannot run against nothing, so the speed and duplex
# are forced: that is what loopback requires, not a shortcut.
#
lanloopback(mode: int): int
{
	#
	# Two places to loop, and they fail for different reasons.
	#
	# PHY internal loopback is the standard test with no cable: the
	# PHY generates its own clocking, so it works with no link
	# partner. MAC loopback ties transmitter to receiver above the
	# PHY, which is tidier but still depends on the PHY supplying a
	# clock -- and a PHY with no link may not be.
	#
	# I tried MAC loopback first on the strength of a PHY-loopback
	# run that reported nothing. That run was reading from an
	# endpoint that did not exist, so it was not evidence of
	# anything. Try both, say which was used, and let the board
	# decide rather than repeating the same mistake in the other
	# direction.
	#
	(e0, cr) := lanrd(Lmaccr);
	if(e0 < 0)
		return -1;

	if(mode == Lpby){
		#
		# Force the MAC to the speed the PHY is being forced to.
		# Left on automatic it follows a PHY that, in loopback with
		# no link partner, has nothing to report -- so the two ends
		# of the same chip disagree about the clock and no data
		# moves.
		#
		if(lanmaccr((cr & ~(Lmacadp|Lmacautodup|Lmacautospd|Lmacspdmask))
				| Lmacspd100 | Lmacfull) < 0){
			sys->print("etherusb: cannot force MAC speed: %r\n");
			return -1;
		}
		if(lanmiiwr(Mbmcr, Mbmcrloop | Mbmcr100 | Mbmcrfull) < 0){
			sys->print("etherusb: cannot enter PHY loopback: %r\n");
			return -1;
		}
		(e, bc) := lanmiird(Mbmcr);
		if(e < 0 || (bc & Mbmcrloop) == 0){
			sys->print("etherusb: PHY loopback bit did not take (bmcr %4.4ux)\n", bc);
			return -1;
		}
	}else{
		if(lanmaccr((cr & ~(Lmacadp|Lmacautodup|Lmacautospd|Lmacspdmask))
				| Lmacloop | Lmacspd100 | Lmacfull) < 0){
			sys->print("etherusb: cannot enter MAC loopback: %r\n");
			return -1;
		}
		(e, v) := lanrd(Lmaccr);
		if(e < 0 || (v & Lmacloop) == 0){
			sys->print("etherusb: MAC loopback bit did not take (mac_cr %8.8ux)\n", v);
			return -1;
		}
	}
	sys->sleep(100);

	#
	# A frame addressed to ourselves. Broadcast would also come back,
	# but our own address exercises the receiver's address filter --
	# which is the part that silently drops everything if RX_ADDR was
	# never programmed.
	#
	tx := array[64] of byte;
	for(i := 0; i < len tx; i++)
		tx[i] = byte 0;
	tx[0:] = mac;			# destination: us
	tx[6:] = mac;			# source: us
	tx[12] = byte 16r08;		# a plausible ethertype
	tx[13] = byte 16r00;
	for(i = 14; i < len tx; i++)
		tx[i] = byte (i & 16rFF);

	#
	# Photograph the data path either side of the transmit.
	#
	# Everything so far has been inferred from a frame not coming
	# back, which is the least informative symptom this chip has: it
	# is equally consistent with the MAC never transmitting, the loop
	# not closing, the receive filter dropping it, the FIFO being
	# disabled, and the endpoint being read too early. Reading the
	# registers says which.
	#

	if(transmit(tx) < 0){
		sys->print("etherusb: loopback transmit failed: %r\n");
		lanunloop(cr);
		return -1;
	}

	sys->sleep(50);

	buf := array[Maxframe + 64] of byte;
	ok := -1;
	for(try := 0; try < 20; try++){
		n := sys->read(bulkfd, buf, len buf);
		if(n <= 0){
			sys->sleep(50);
			continue;
		}
		(nil, frame) := family.unwrap(buf, n);
		if(frame == nil)
			continue;
		if(len frame >= 14 && sameaddr(frame, mac)){
			sys->print("etherusb: loopback OK -- %d bytes returned\n",
				len frame);
			ok = 0;
			break;
		}
	}
	# Put it back the way it was, whatever happened.
	lanunloop(cr);
	return ok;
}

#
# The board's Ethernet address, as the kernel found it.
#
# This part cannot report its own: no EEPROM, unprogrammed OTP. On this
# board the address belongs to the BOARD rather than to the chip -- the
# firmware derives it from the serial number -- so the kernel asks and
# publishes it, and this reads what was published. Nothing here knows
# that it came from a VideoCore mailbox, which is the point.
#
envmac(m: array of byte): int
{
	fd := sys->open("/env/ethermac", Sys->OREAD);
	if(fd == nil)
		return -1;
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return -1;

	(nf, fields) := sys->tokenize(string buf[0:n], ":\n");
	if(nf < 6)
		return -1;
	for(i := 0; i < 6; i++){
		v := hexbyte(hd fields);
		if(v < 0)
			return -1;
		m[i] = byte v;
		fields = tl fields;
	}
	return 0;
}

#
# Two hex digits. Written out rather than loading String for it: this
# module has no other use for that module, and a parser that accepts
# only what it should is three lines.
#
hexbyte(t: string): int
{
	if(len t == 0 || len t > 2)
		return -1;
	v := 0;
	for(i := 0; i < len t; i++){
		c := t[i];
		d := -1;
		if(c >= '0' && c <= '9')
			d = c - '0';
		else if(c >= 'a' && c <= 'f')
			d = c - 'a' + 10;
		else if(c >= 'A' && c <= 'F')
			d = c - 'A' + 10;
		if(d < 0)
			return -1;
		v = v * 16 + d;
	}
	return v;
}

#
# Wait for the OTP block to finish whatever it was told to do.
#
lanotpwait(): int
{
	for(i := 0; i < 100; i++){
		(e, st) := lanrd(Lotpstatus);
		if(e < 0)
			return -1;
		if((st & Lotpbusy) == 0)
			return 0;
		sys->sleep(1);
	}
	sys->print("etherusb: LAN78xx OTP stayed busy\n");
	return -1;
}

#
# Read len buf bytes out of OTP starting at off.
#
# One byte per command: address high, address low, "read", "go", wait,
# collect. There is no burst form, which is why this is a loop and not a
# single transfer.
#
lanotp(off: int, buf: array of byte): int
{
	#
	# Power the block up first. PWRDN_N is inverted -- the OTP is
	# awake when the bit is CLEAR -- and reading it while powered
	# down returns nothing useful rather than failing.
	#
	(e, pd) := lanrd(Lotppwrdn);
	if(e < 0)
		return -1;
	if(pd & Lotppwrdnn){
		if(lanwr(Lotppwrdn, 0) < 0)
			return -1;
		if(lanotpwait() < 0)
			return -1;
	}

	for(i := 0; i < len buf; i++){
		a := off + i;
		if(lanwr(Lotpaddr1, (a >> 8) & 16r1F) < 0 ||
		   lanwr(Lotpaddr2, a & 16rFF) < 0 ||
		   lanwr(Lotpfunccmd, Lotpread) < 0 ||
		   lanwr(Lotpcmdgo, Lotpgo) < 0)
			return -1;
		if(lanotpwait() < 0)
			return -1;
		(e2, v) := lanrd(Lotprddata);
		if(e2 < 0)
			return -1;
		buf[i] = byte (v & 16rFF);
	}
	return 0;
}

#
# Is this a MAC address a station may actually use?
#
# All-zeroes and all-ones are what unprogrammed registers read as, and
# the low bit of the first byte is the multicast flag -- a station
# address with it set is not one. Checking replaces the OTP signature
# check Linux does: a byte that fails this is not an address whatever
# the signature said.
#
macusable(m: array of byte): int
{
	zero := 1;
	ones := 1;
	for(i := 0; i < len m; i++){
		if(int m[i] != 0)
			zero = 0;
		if(int m[i] != 16rFF)
			ones = 0;
	}
	if(zero || ones)
		return 0;
	return (int m[0] & 1) == 0;
}

lansetup(): int
{
	#
	# Identify before configuring.
	#
	# This register map has never been run against the silicon, so
	# the first thing to establish is whether the device answers at
	# all in the way the map assumes. All-zeroes or all-ones means
	# the read did not reach a register, and there is nothing to be
	# gained by writing to the rest of them on that basis.
	#
	(err, idrev) := lanrd(Lidrev);
	if(err < 0){
		sys->print("etherusb: LAN78xx ID_REV read failed: %r\n");
		return -1;
	}
	if(idrev == 0 || idrev == -1){		# -1 is 0xFFFFFFFF as an int
		sys->print("etherusb: LAN78xx ID_REV reads %8.8ux -- refusing\n",
			idrev);
		return -1;
	}
	sys->print("etherusb: LAN78xx ID_REV %8.8ux\n", idrev);

	#
	# Soft reset, then wait for the bit to clear itself.
	#
	if(lanwr(Lhwcfg, Lhwlrst) < 0){
		sys->print("etherusb: LAN78xx reset failed: %r\n");
		return -1;
	}
	for(i := 0; i < 100; i++){
		(e, hw) := lanrd(Lhwcfg);
		if(e < 0)
			return -1;
		if((hw & Lhwlrst) == 0)
			break;
		sys->sleep(10);
	}
	if(i >= 100){
		sys->print("etherusb: LAN78xx reset never completed\n");
		return -1;
	}

	#
	# The MAC address, which the device holds in two registers -- the
	# low four bytes and the high two. It is the device's own, from
	# its OTP or EEPROM, and reading it is also a second check that
	# register access works: an address of all zeroes or all ones is
	# not one.
	#
	(e1, lo) := lanrd(Lrxaddrl);
	(e2, hi) := lanrd(Lrxaddrh);
	if(e1 < 0 || e2 < 0){
		sys->print("etherusb: LAN78xx cannot read its MAC: %r\n");
		return -1;
	}
	mac[0] = byte (lo & 16rFF);
	mac[1] = byte ((lo >> 8) & 16rFF);
	mac[2] = byte ((lo >> 16) & 16rFF);
	mac[3] = byte ((lo >> 24) & 16rFF);
	mac[4] = byte (hi & 16rFF);
	mac[5] = byte ((hi >> 8) & 16rFF);

	#
	# Fall back to OTP, which is where this board actually keeps it.
	#
	# RX_ADDR is loaded from EEPROM at reset, and the Pi 3B+ has no
	# EEPROM on this part -- so those registers read back all-ones and
	# the driver reported a MAC of ff:ff:ff:ff:ff:ff. The address is in
	# OTP instead, which has to be asked for a byte at a time.
	#
	if(!macusable(mac)){
		if(lanotp(Lotpmacoff, mac) < 0){
			sys->print("etherusb: LAN78xx OTP read failed: %r\n");
			return -1;
		}
		if(!macusable(mac) && envmac(mac) == 0)
			sys->print("etherusb: MAC from /env/ethermac\n");
		else if(macusable(mac))
			sys->print("etherusb: LAN78xx MAC from OTP\n");

		if(!macusable(mac)){
			sys->print("etherusb: no usable MAC in RX_ADDR, OTP or /env\n");
			return -1;
		}

		#
		# Put it where the receiver looks. RX_ADDR is what the MAC
		# filters incoming frames against, so an address that only
		# exists in this driver's memory would be advertised in
		# every packet sent and matched by none received.
		#
		lo = (int mac[0]) | (int mac[1] << 8) |
			(int mac[2] << 16) | (int mac[3] << 24);
		hi = (int mac[4]) | (int mac[5] << 8);
		if(lanwr(Lrxaddrl, lo) < 0 || lanwr(Lrxaddrh, hi) < 0){
			sys->print("etherusb: LAN78xx cannot set its MAC: %r\n");
			return -1;
		}
	}

	#
	# Turn on the FIFOs and then the MAC, in that order: enabling the
	# receiver before the FIFO that feeds it has somewhere to put
	# what arrives is how a device ends up dropping its first frames.
	#
	if(lanwr(Lfctrxctl, Lfcten) < 0 || lanwr(Lfcttxctl, Lfcten) < 0){
		sys->print("etherusb: LAN78xx FIFO enable failed: %r\n");
		return -1;
	}
	#
	# Tell the receive filter what to accept, BEFORE enabling the
	# receiver.
	#
	# RFE_CTL was never written, and at reset it passes nothing: no
	# unicast, no broadcast, no multicast. A MAC configured this way
	# is fully enabled and receives not one frame, which looks exactly
	# like an unplugged cable from every vantage point this driver
	# has -- and did, including inside a loopback test where the frame
	# had definitely been sent.
	#
	if(lanwr(Lrfectl, Lrfebcast|Lrfemcast|Lrfeucast|Lrfeperfect) < 0){
		sys->print("etherusb: LAN78xx receive filter setup failed: %r\n");
		return -1;
	}

	#
	# Tell the receiver how large a frame may be, and let the MAC
	# follow the PHY's speed.
	#
	# MAC_RX's max-size field is zero at reset, which means every
	# frame that arrives is oversized and discarded -- a receiver
	# enabled and configured to accept nothing. And MAC_CR came up
	# 00003000: automatic duplex, but automatic SPEED clear and the
	# speed field zero, which is 10Mb/s. A MAC clocked for 10 against
	# a PHY doing anything else moves no data and reports nothing
	# about why.
	#
	# Both were missing, and either alone is enough to produce a link
	# that looks fine and a receiver that never delivers a frame.
	#
	(ec, cr) := lanrd(Lmaccr);
	if(ec < 0)
		return -1;
	if(lanmaccr(cr | Lmacadp | Lmacautodup | Lmacautospd) < 0){
		sys->print("etherusb: LAN78xx MAC_CR setup failed: %r\n");
		return -1;
	}

	if(lanwr(Lmactx, Ltxen) < 0 ||
	   lanwr(Lmacrx, (Maxframe << Lrxmaxshift) | Lrxfcsstrip | Lrxen) < 0){
		sys->print("etherusb: LAN78xx MAC enable failed: %r\n");
		return -1;
	}

	if(lanphy() < 0)
		return -1;
	return 0;
}

#
# TX_CMD_A carries the length and asks the device to append the FCS;
# TX_CMD_B is unused for a plain frame.
#
lanwrap(frame: array of byte): array of byte
{
	buf := array[Ltxhdr + len frame] of byte;

	put4(buf, 0, (len frame & Ltxlen) | Ltxfcs);
	put4(buf, 4, 0);
	buf[Ltxhdr:] = frame;
	return buf;
}

#
# RX_CMD_A holds the length in its low bits and an error flag higher
# up. A frame flagged in error is consumed and discarded rather than
# passed on: it is the device saying the bytes are not trustworthy.
#
lanunwrap(buf: array of byte, n: int): (int, array of byte)
{
	if(n < Lrxhdr)
		return (0, nil);

	cmda := int get4(buf, 0);
	datalen := cmda & Lrxlen;
	if(datalen < 14 || datalen > Maxframe)
		return (-1, nil);
	if(Lrxhdr + datalen > n)
		return (0, nil);

	if(cmda & Lrxerr)
		return (Lrxhdr + datalen, nil);

	frame := array[datalen] of byte;
	frame[0:] = buf[Lrxhdr:Lrxhdr+datalen];
	return (Lrxhdr + datalen, frame);
}
