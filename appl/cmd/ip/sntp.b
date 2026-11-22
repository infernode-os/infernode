implement Sntp;

#
# rfc1361 (simple network time protocol), a client.
#
# A reply is taken only if it answers the request (RFC 4330 section 5).
# The request carries 64 random bits as its transmit timestamp, and a
# reply must give them back as its originate timestamp, come in server
# mode from the address asked (the conversation is dialled, so the
# kernel gives it no other's), be of a version up to 4, and say a time:
# not leap indicator 3 (the server's clock is not set), not stratum 0
# (a kiss-of-death: go away), not a transmit timestamp of zero.  A
# datagram that is none of these is passed over and the next is read,
# until the try's time is up.
#
# The request used to carry the client's own time as its originate
# timestamp and nothing to match, and the reply's was never looked at:
# any datagram with the server's address on it set the clock, to any
# time from 2005 to 2036.  The header's fields were read from the wrong
# bits (the version took the leap indicator's with it, so a server
# saying its clock was unset, or a version 4 server, was "no response";
# mode 6 was read as mode 2), stratum 0 was warned of and then used,
# each refused datagram used up a try, and a clock that could not be
# written was reported as set.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "ip.m";
	ip: IP;
	IPaddr: import ip;

include "dial.m";
	dial: Dial;

include "timers.m";
	timers: Timers;
	Timer: import timers;

include "arg.m";

Sntp: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

debug := 0;

Retries: con 4;
Delay: con 3*1000;	# milliseconds

SNTP: adt {
	li:	int;
	vn:	int;
	mode:	int;
	stratum:	int;	# level of local clock
	poll:	int;	# log2(maximum interval in seconds between successive messages)
	precision:	int;	# log2(seconds precision of local clock) [eg, -6 for mains, -18 for microsec]
	rootdelay:	int;	# round trip delay in seconds to reference (16:16 fraction)
	dispersion:	int;	# maximum error relative to primary reference
	clockid:	string;	# reference clock identifier	
	reftime:	big;	# local time at which clock last set/corrected
	orgtime:	big;	# local time at which client transmitted request
	rcvtime:	big;	# time at which request arrived at server
	xmttime:	big;	# time server transmitted reply
	auth:	array of byte;	# auth field (ignored by this implementation)

	new:	fn(vn, mode: int): ref SNTP;
	pack:	fn(s: self ref SNTP): array of byte;
	unpack:	fn(a: array of byte): ref SNTP;
};
SNTPlen: con 4+3*4+4*8;

Version: con 1;	# accepted by version 2 and version 3 servers
Stratum: con 0;
Poll: con 0;
LI: con 0;
Symmetric: con 2;
ClientMode: con 3;
ServerMode: con 4;
Epoch: con big 86400*big (365*70 + 17);	# seconds between 1 Jan 1900 and 1 Jan 1970

Microsec: con big 1000000;

server := "$ntp";
stderr: ref Sys->FD;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	ip = load IP IP->PATH;
	timers = load Timers Timers->PATH;
	dial = load Dial Dial->PATH;

	ip->init();
	arg := load Arg Arg->PATH;
	arg->init(args);
	arg->setusage("sntp [-d] [server]");

	doset := 1;
	while((o := arg->opt()) != 0)
		case o {
		'd' => debug++;
		'i' => doset = 0;
		* =>	arg->usage();
		}
	args = arg->argv();
	if(len args > 1)
		arg->usage();
	arg = nil;

	if(args != nil)
		server = hd args;

	sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);
	stderr = sys->fildes(2);
	timers->init(100);

	conn := dial->dial(dial->netmkaddr(server, "udp", "ntp"), nil);
	if(conn == nil){
		sys->fprint(stderr, "sntp: can't dial %s: %r\n", server);
		raise "fail:dial";
	}

	replies := chan of ref SNTP;
	spawn reader(conn.dfd, replies);

	refused := 0;
	lastwhy := "";
	for(i:=0; i<Retries; i++){
		request := SNTP.new(Version, ClientMode);
		request.poll = 6;
		request.xmttime = nonce();
		b := request.pack();
		if(sys->write(conn.dfd, b, len b) != len b){
			sys->fprint(stderr, "sntp: UDP write failed: %r\n");
			continue;
		}
		t := Timer.start(Delay);
	Wait:
		for(;;) alt{
		reply := <-replies =>
			if(reply == nil){
				t.stop();
				quit("read error");
			}
			if(debug){
				sys->fprint(stderr, "LI = %d, version = %d, mode = %d\n", reply.li, reply.vn, reply.mode);
				if(reply.stratum == 1)
					sys->fprint(stderr, "stratum = 1 (%s), ", printable(reply.clockid));
				else
					sys->fprint(stderr, "stratum = %d, ", reply.stratum);
				sys->fprint(stderr, "poll = %d, prec = %d\n", reply.poll, reply.precision);
				sys->fprint(stderr, "rootdelay = %d, dispersion = %d\n", reply.rootdelay, reply.dispersion);
			}
			now := ((reply.xmttime>>32)&16rFFFFFFFF) - Epoch;
			why := refuse(reply, request, now);
			if(why != nil){
				# not an answer: the next datagram may be
				refused++;
				lastwhy = why;
				if(debug)
					sys->fprint(stderr, "sntp: reply passed over: %s\n", why);
				continue Wait;
			}
			t.stop();
			if(debug)
				sys->print("%bd\n", now);
			if(doset){
				e := settime("#r/rtc", now, 0);
				if(e == nil)
					e = settime("/dev/time", now*Microsec, 1);
				if(e != nil){
					sys->fprint(stderr, "sntp: the clock was not set: %s\n", e);
					quit("clock not set");
				}
			}
			quit(nil);
		<-t.timeout =>
			break Wait;
		}
	}
	if(refused > 0){
		sys->fprint(stderr, "sntp: no acceptable reply from server %s: %d passed over, the last: %s\n", server, refused, lastwhy);
		quit("no acceptable reply");
	}
	sys->fprint(stderr, "sntp: no response from server %s\n", server);
	quit("timeout");
}

# why a datagram is not the answer to request, or nil if it is
refuse(reply, request: ref SNTP, now: big): string
{
	# RFC 4330 section 5: the originate timestamp is the request's
	# transmit timestamp, or the reply answers something else (a
	# request of another time, or none: a sender who never saw this one)
	if(reply.orgtime != request.xmttime)
		return "its originate timestamp is not this request's";
	if(reply.mode != ServerMode)
		return sys->sprint("mode %d, not a server's", reply.mode);
	if(reply.vn == 0 || reply.vn > 4)
		return sys->sprint("version %d", reply.vn);
	if(reply.li == 3)
		return "the server's clock is not set (leap indicator 3)";
	if(reply.stratum == 0)
		return "kiss-of-death (stratum 0): " + printable(reply.clockid);
	if(reply.xmttime == big 0)
		return "no transmit timestamp";
	if(now <= big 1120000000)
		return sys->sprint("a time before 2005 (%bd)", now);
	return nil;
}

printable(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] >= ' ' && s[i] <= '~')
			r[len r] = s[i];
		else
			r[len r] = '?';
	return r;
}

# 64 bits nobody else can guess
nonce(): big
{
	fd := sys->open("/dev/random", Sys->OREAD);
	b := array[8] of byte;
	if(fd == nil || sys->read(fd, b, len b) != len b){
		sys->fprint(stderr, "sntp: /dev/random: %r\n");
		quit("no random numbers");
	}
	return get8(b, 0);
}

reader(fd: ref Sys->FD, replies: chan of ref SNTP)
{
	for(;;){
		buf := array[512] of byte;
		nb := sys->read(fd, buf, len buf);
		if(nb <= 0)
			break;
		reply := SNTP.unpack(buf[0:nb]);
		if(reply == nil){
			# ignore bad replies
			if(debug)
				sys->fprint(stderr, "sntp: invalid reply (len %d)\n", nb);
			continue;
		}
		replies <-= reply;
	}
	if(debug)
		sys->fprint(stderr, "sntp: UDP read failed: %r\n");
	replies <-= nil;
}

quit(s: string)
{
	pid := sys->pctl(0, nil);
	timers->shutdown();
	fd := sys->open("#p/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	if(s != nil)
		raise "fail:"+s;
	exit;
}

# Set a clock: nil, or why it was not set.  A clock that is not there
# is not an error unless it must be (few machines have #r/rtc).
settime(f: string, t: big, must: int): string
{
	if(!must && sys->stat(f).t0 < 0)
		return nil;
	fd := sys->open(f, Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%bd", t) < 0)
		return sys->sprint("%s: %r", f);
	return nil;
}

get8(a: array of byte, i: int): big
{
	b := big ip->get4(a, i+4) & 16rFFFFFFFF;
	return (big ip->get4(a, i) << 32) | b;
}

put8(a: array of byte, o: int, v: big)
{
	ip->put4(a, o, int (v>>32));
	ip->put4(a, o+4, int v);
}

SNTP.unpack(a: array of byte): ref SNTP
{
	if(len a < SNTPlen)
		return nil;
	s := ref SNTP;
	mode := int a[0];
	s.li = mode>>6;
	s.vn = (mode>>3) & 7;
	s.mode = mode & 7;
	s.stratum = int a[1];
	s.poll = int a[2];
	if(s.poll & 16r80)
		s.poll |= ~0 << 8;
	s.precision = int a[3];
	if(s.precision & 16r80)
		s.precision |= ~0 << 8;
	s.rootdelay = ip->get4(a, 4);
	s.dispersion = ip->get4(a, 8);
	if(s.stratum <= 1){
		for(i := 12; i < 16; i++)
			if(a[i] == byte 0)
				break;
		s.clockid = string a[12:i];
	}else
		s.clockid = sys->sprint("%d.%d.%d.%d", int a[12], int a[13], int a[14], int a[15]);
	s.reftime = get8(a, 16);
	s.orgtime = get8(a, 24);
	s.rcvtime = get8(a, 32);
	s.xmttime = get8(a, 40);
	if(len a > SNTPlen)
		s.auth = a[48:];
	return s;
}

SNTP.pack(s: self ref SNTP): array of byte
{
	a := array[SNTPlen + len s.auth] of byte;
	a[0] = byte ((s.li<<6) | (s.vn<<3) | s.mode);
	a[1] = byte s.stratum;
	a[2] = byte s.poll;
	a[3] = byte s.precision;
	ip->put4(a, 4, s.rootdelay);
	ip->put4(a, 8, s.dispersion);
	ip->put4(a, 12, 0);	# clockid field
	if(s.clockid != nil){
		if(s.stratum <= 1){
			b := array of byte s.clockid;
			for(i := 0; i < len b && i < 4; i++)
				a[12+i] = b[i];
		}else
			a[12:] = IPaddr.parse(s.clockid).t1.v4();
	}
	put8(a, 16, s.reftime);
	put8(a, 24, s.orgtime);
	put8(a, 32, s.rcvtime);
	put8(a, 40, s.xmttime);
	if(s.auth != nil)
		a[48:] = s.auth;
	return a;
}

SNTP.new(vn, mode: int): ref SNTP
{
	s := ref SNTP;
	s.vn = vn;
	s.mode = mode;
	s.li = 0;
	s.stratum = 0;
	s.poll = 0;
	s.precision = 0;
	s.clockid = nil;
	s.reftime = big 0;
	s.orgtime = big 0;
	s.rcvtime = big 0;
	s.xmttime = big 0;
	return s;
}
