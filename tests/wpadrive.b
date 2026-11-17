implement Wpadrive;

#
# ip/wpa against an interface that is files of this program's making,
# for tests/host/wpa_log_test.sh: clone (a ctl that takes its lines, or
# refuses one), addr, ifstats and 0/data (frames from a script), with
# wpa's standard error in a file as os/init's wparun has it.  The frames
# are tests/wpa_test.b's synthetic handshake: passphrase "InfernodeTest"
# on network "infernode".  Not a test.
#
#	wpadrive dir log flood N
#		message 1, then N frames nobody need hold a key to send, of
#		three kinds
#	wpadrive dir log cap N
#		message 1, N times, to a wpa run with -d: a line each
#	wpadrive dir log failauth
#		the write of the security element after the association is
#		refused, as the driver refuses it when the link has just
#		gone; the queue then ends, and the next association is given
#		message 1
#	wpadrive dir log handshake
#		the four-way handshake, the supplicant's nonce the one the
#		synthetic frames were made for
#	wpadrive dir log txrefused
#		the same, the driver refusing the transmit key
#
# It prints what was written to ctl (never a key), what was sent, and
# at the end whether wpa is still running and how long its log is.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "wpakey.m";
	wpakey: Wpakey;

Wpadrive: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Msg1 :=
	"020000000001020000000002888e0203005f02008a0010000000000000000120212223242526"+
	"2728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00000000000000000000000000"+
	"00000000000000000000000000000000000000000000000000000000000000000000000000";
Msg3 :=
	"020000000001020000000002888e020300970213ca0010000000000000000220212223242526"+
	"2728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f00000000000000000000000000"+
	"000000010203040506000000000000000000008f90b88110986fc0357a7686d6e3aad4003815"+
	"84c6e1725d2943eab0c6077a528244284b033e019beca104e441716c3b207839cc93e00b766f"+
	"442636fc7e723153ca1f730f4f2140e99b";
Snonce :=
	"808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f";

mode: string;
count := 0;
nauth := 0;
delivered := 0;
ended := 0;
sent := 0;
done: chan of int;

put(name, s: string)
{
	fd := sys->create(name, Sys->OWRITE, 8r644);
	if(fd == nil){
		sys->print("wpadrive: %s: %r\n", name);
		raise "fail:create";
	}
	sys->fprint(fd, "%s", s);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	wpakey = load Wpakey Wpakey->PATH;
	wpakey->init();
	args = tl args;
	if(len args < 3){
		sys->fprint(sys->fildes(2), "usage: wpadrive dir log mode [n]\n");
		raise "fail:usage";
	}
	dir := hd args; args = tl args;
	log := hd args; args = tl args;
	mode = hd args; args = tl args;
	if(args != nil)
		count = int hd args;

	sys->pctl(Sys->FORKNS, nil);
	sys->create(dir, Sys->OREAD, Sys->DMDIR|8r755);
	sys->create(dir + "/0", Sys->OREAD, Sys->DMDIR|8r755);
	put(dir + "/addr", "020000000001\n");
	put(dir + "/ifstats", "essid: infernode\nstatus: associated\n");
	done = chan of int;
	if(sys->bind("#s", dir, Sys->MBEFORE) < 0 || sys->bind("#s", dir + "/0", Sys->MBEFORE) < 0){
		sys->print("wpadrive: bind #s: %r\n");
		raise "fail:bind";
	}
	cio := sys->file2chan(dir, "clone");
	dio := sys->file2chan(dir + "/0", "data");
	if(cio == nil || dio == nil){
		sys->print("wpadrive: file2chan: %r\n");
		raise "fail:file2chan";
	}
	spawn ctl(cio);
	spawn data(dio);
	if(mode == "handshake" || mode == "txrefused"){
		# the nonce the synthetic message 3 was made for
		rio := sys->file2chan(dir, "random");
		if(rio == nil || sys->bind(dir + "/random", "/dev/random", Sys->MREPL) < 0){
			sys->print("wpadrive: /dev/random: %r\n");
			raise "fail:random";
		}
		spawn rand(rio);
	}

	pidc := chan of int;
	spawn runwpa(dir, log, pidc);
	pid := <-pidc;
	tmo := chan of int;
	spawn timer(tmo, 40000);
	alt{
	<-done =>
		sys->sleep(700);
	<-tmo =>
		sys->print("wpadrive: timed out\n");
	}
	fd := sys->open("/prog/" + string pid + "/status", Sys->OREAD);
	if(fd == nil)
		sys->print("wpa has exited\n");
	else{
		sys->print("wpa is running\n");
		kfd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
		if(kfd != nil)
			sys->fprint(kfd, "killgrp");
	}
	(ok, d) := sys->stat(log);
	if(ok >= 0)
		sys->print("log %bd bytes after %d frames delivered\n", d.length, delivered);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

runwpa(dir, log: string, pidc: chan of int)
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);
	pidc <-= sys->pctl(0, nil);
	fd := sys->create(log, Sys->OWRITE, 8r600);
	if(fd != nil)
		sys->dup(fd.fd, 2);
	wpa := load Command "/dis/ip/wpa.dis";
	if(wpa == nil){
		sys->print("wpadrive: cannot load wpa: %r\n");
		return;
	}
	argv := "-s" :: "infernode" :: dir :: nil;
	if(mode == "cap")
		argv = "-d" :: argv;
	wpa->init(nil, "wpa" :: argv);
}

rand(io: ref Sys->FileIO)
{
	b := wpakey->unhex(Snonce);
	for(;;) alt{
	(nil, n, nil, rc) := <-io.read =>
		if(rc == nil)
			continue;
		if(n > len b)
			n = len b;
		rc <-= (b[0:n], nil);
	(nil, nil, nil, wc) := <-io.write =>
		if(wc != nil)
			wc <-= (0, "read only");
	}
}

ctl(io: ref Sys->FileIO)
{
	for(;;) alt{
	(off, nil, nil, rc) := <-io.read =>
		if(rc == nil)
			continue;
		if(off > 0)
			rc <-= (nil, nil);
		else
			rc <-= (array of byte "0", nil);
	(nil, d, nil, wc) := <-io.write =>
		if(wc == nil)
			continue;
		s := string d;
		v := verb(s);
		sys->print("ctl write: %s\n", v);
		if(v == "auth"){
			nauth++;
			if(mode == "failauth" && nauth == 2){
				# what the driver's auth answers when the link went
				# between the supplicant's look at ifstats and this
				# write
				wc <-= (0, "ether4330: the firmware did not report an association");
				continue;
			}
		}
		if(mode == "txrefused" && v == "txkey"){
			wc <-= (0, "ether4330: the firmware refused the key");
			done <-= 1;
			continue;
		}
		wc <-= (len d, nil);
		if(mode == "handshake" && v == "rxkey1")
			done <-= 1;
	}
}

# the first word of a ctl line: the rest may be a key
verb(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			return s[0:i];
	return s;
}

data(io: ref Sys->FileIO)
{
	m1 := wpakey->unhex(Msg1);
	# key descriptor version 1: refused before any key is looked at
	v1 := wpakey->unhex(Msg1);
	v1[20] = byte 16r89;
	# cut short
	short := m1[0:40];
	# the MIC bit set, and no MIC that could be right
	mic := wpakey->unhex(Msg3);
	mic[18+77] ^= byte 16rff;
	mic[18+12] ^= byte 1;
	for(;;) alt{
	(nil, nil, nil, rc) := <-io.read =>
		if(rc == nil)
			continue;
		case mode {
		"flood" =>
			if(delivered == 0)
				rc <-= (m1, nil);
			else if(delivered <= count)
				case delivered % 3 {
				0 =>	rc <-= (v1, nil);
				1 =>	rc <-= (short, nil);
				2 =>	rc <-= (mic, nil);
				}
			else{
				if(delivered == count + 1)
					done <-= 1;
				continue;	# leave it reading
			}
		"cap" =>
			if(delivered < count)
				rc <-= (m1, nil);
			else{
				if(delivered == count)
					done <-= 1;
				continue;
			}
		"failauth" =>
			if(nauth == 2 && !ended){
				# the driver closes the queue of a link that has gone
				ended = 1;
				rc <-= (nil, nil);
				continue;
			}
			if(nauth < 3 || delivered > 0)
				continue;
			rc <-= (m1, nil);
		"handshake" or "txrefused" =>
			if(delivered == 0)
				rc <-= (m1, nil);
			else if(delivered == 1)
				rc <-= (wpakey->unhex(Msg3), nil);
			else
				continue;
		* =>
			continue;
		}
		delivered++;
	(nil, d, nil, wc) := <-io.write =>
		if(wc == nil)
			continue;
		sent++;
		if(mode != "cap" && mode != "flood")
			sys->print("frame sent: %d bytes\n", len d);
		wc <-= (len d, nil);
		if(mode == "failauth" && nauth >= 3)
			done <-= 1;
	}
}
