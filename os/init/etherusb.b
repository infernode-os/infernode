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

#
# Control-request shape. Same eight bytes as always; what differs from
# the bus walk in osinit is the recipient -- these go to an INTERFACE,
# not to a device or a hub port.
#
Rh2d:		con 16r00;
Rd2h:		con 16r80;
Rclass:		con 16r20;
Riface:		con 1;		# recipient: interface

Rsetconf:	con 9;		# SET_CONFIGURATION

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

dev: string;			# "ep3.0"
ctl: ref Sys->FD;		# #u/usb/<dev>/ctl
ep0: ref Sys->FD;		# #u/usb/<dev>/data -- the control endpoint
reqid := 1;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return;

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

	#
	# Configuration 2, which is what this device's configuration
	# descriptor declares. Not 1: bConfigurationValue is the device's
	# choice and only conventionally 1, and a SET_CONFIGURATION for a
	# value the device does not have is a stall rather than a
	# diagnosable error.
	#
	if(ctlout(Rh2d, Rsetconf, 2, 0, nil) < 0){
		sys->print("etherusb: set configuration failed: %r\n");
		return;
	}

	#
	# The bulk endpoint. One Ep in both directions -- devusb keeps a
	# toggle per direction, so a single "rw" endpoint is a pair of
	# pipes, and asking for two separate ones on the same number is
	# rejected as already in use.
	#
	if(sys->fprint(ctl, "new 2 bulk rw") < 0){
		sys->print("etherusb: cannot create the bulk endpoint: %r\n");
		return;
	}

	#
	# The name is constructed, not read back.
	#
	# "newdev" stashes the new endpoint's name for the next read of
	# the ctl file; "new" does not -- it only calls newdevep -- so
	# reading here returns this endpoint's own status line instead,
	# which looks enough like an answer to be mistaken for one. The
	# name is determined anyway: same device, endpoint 2.
	#
	bulk := epname(dev, 2);
	sys->print("etherusb: %s bulk endpoint is %s\n", dev, bulk);

	if(rndisinit() < 0)
		return;

	mac := array[6] of byte;
	if(rndisquery(Oidmac, mac) < 0){
		sys->print("etherusb: cannot read the MAC address: %r\n");
		return;
	}

	sys->print("etherusb: %s MAC %2.2x:%2.2x:%2.2x:%2.2x:%2.2x:%2.2x\n",
		dev, int mac[0], int mac[1], int mac[2],
		int mac[3], int mac[4], int mac[5]);

	filter := array[4] of byte;
	put4(filter, 0, Filterdefault);
	if(rndisset(Oidfilter, filter) < 0){
		sys->print("etherusb: cannot set the packet filter: %r\n");
		return;
	}
	sys->print("etherusb: %s ready\n", dev);
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
