implement Wpa;

#
#	WPA2-PSK supplicant.
#
#	The radio associates by itself: the dongle's firmware does the
#	scanning, the authentication and the association, and the kernel
#	driver exposes that as an ethernet interface whose ctl file takes
#	an essid and an RSN information element.  What no fullMAC radio
#	can do for itself is prove it knows the passphrase, because the
#	passphrase is not the radio's to know.  That is this program: the
#	four-way EAPOL handshake, run over an ordinary conversation on
#	the interface, ending in two ctl writes that hand the derived
#	keys to the firmware.
#
#	Written from Plan 9's aux/wpa(8) as the specification.  The
#	cryptography and the handshake itself are in wpakey(2), where
#	tests can reach them without a radio; what is here is the I/O and
#	the policy: which interface, which network, where the passphrase
#	comes from, and what to do when the link drops.
#
#	The passphrase comes from factotum and from nowhere else.  It is
#	never an argument -- arguments are readable in /prog -- and never
#	a file in the tree.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "keyring.m";

include "security.m";
	random: Random;

include "factotum.m";
	factotum: Factotum;

include "wpakey.m";
	wpakey: Wpakey;
	Supp, Action: import wpakey;

Wpa: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Defaultdev:	con "/net/ether1";

# How long to wait for the radio to associate before saying so.
Assocwait:	con 20000;	# ms
Assocpoll:	con 100;	# ms

stderr: ref Sys->FD;
debug := 0;
dev: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		fatal(sys->sprint("cannot load %s: %r", Arg->PATH));
	random = load Random Random->PATH;
	if(random == nil)
		fatal(sys->sprint("cannot load %s: %r", Random->PATH));
	factotum = load Factotum Factotum->PATH;
	if(factotum == nil)
		fatal(sys->sprint("cannot load %s: %r", Factotum->PATH));
	factotum->init();
	wpakey = load Wpakey Wpakey->PATH;
	if(wpakey == nil)
		fatal(sys->sprint("cannot load %s: %r", Wpakey->PATH));
	wpakey->init();

	essid := "";
	arg->init(args);
	arg->setusage("ip/wpa [-d] [-s essid] [interface]");
	while((c := arg->opt()) != 0)
		case c {
		'd' =>	debug = 1;
		's' =>	essid = arg->earg();
		* =>	arg->usage();
		}
	args = arg->argv();
	dev = Defaultdev;
	if(args != nil){
		dev = hd args;
		args = tl args;
	}
	if(args != nil)
		arg->usage();
	arg = nil;

	smac := myaddr();
	if(smac == nil)
		fatal(sys->sprint("%s/addr: %r", dev));

	#
	# The conversation.  netif hands out a ctl file per conversation
	# from the clone file and puts nothing named ctl at the top of the
	# interface, so opening clone is how a writer gets one; the
	# conversation number it reads back names the data file.
	#
	cfd := sys->open(dev + "/clone", Sys->ORDWR);
	if(cfd == nil)
		fatal(sys->sprint("%s/clone: %r", dev));
	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		fatal(sys->sprint("%s/clone: cannot read the conversation number: %r", dev));
	(nf, f) := sys->tokenize(string buf[0:n], " \t\r\n");
	if(nf < 1)
		fatal(sys->sprint("%s/clone: no conversation number", dev));
	conv := hd f;
	if(sys->fprint(cfd, "connect 0x%x", Wpakey->Eapoltype) < 0)
		fatal(sys->sprint("connect 0x%x: %r", Wpakey->Eapoltype));
	dfd := sys->open(dev + "/" + conv + "/data", Sys->ORDWR);
	if(dfd == nil)
		fatal(sys->sprint("%s/%s/data: %r", dev, conv));

	#
	# The network's name is the salt of the key derivation, so it has
	# to be right before anything is derived.  Taking it from the
	# interface when -s was not given is what lets a boot script set
	# the essid once and this program follow it.
	#
	if(essid != ""){
		#
		# Quoted, because the kernel's ctl parser splits on
		# spaces and an unquoted "My Network" would reach the
		# driver as two fields and be refused. Its tokenizer
		# takes rc-style single quotes, which is what %q emits.
		#
		if(sys->fprint(cfd, "essid %q", essid) < 0)
			fatal(sys->sprint("essid %q: %r", essid));
	}else{
		essid = ifstats("essid:");
		if(essid == nil || essid == "")
			fatal("no network name: give -s, or set essid on the interface first");
	}
	report(sys->sprint("%s: network %q", dev, essid));

	pass := passphrase(essid);
	if(pass == nil)
		fatal(sys->sprint("no passphrase for %q in factotum: %r", essid));
	pmk := wpakey->psk(pass, essid);
	pass = nil;
	if(debug)
		report(sys->sprint("pmk %s", wpakey->hex(pmk)));

	rsne := wpakey->rsnie();
	supp := Supp.mk(pmk, smac, rsne);

	frame := array[4096] of byte;
	for(;;){
		#
		# The firmware associates on its own once it has an essid
		# and an authentication mode; all this waits for is the
		# moment it says so.
		#
		associate(cfd, rsne);
		supp.reset();

		for(;;){
			n = sys->read(dfd, frame, len frame);
			if(n < 0)
				fatal(sys->sprint("%s/%s/data: %r", dev, conv));
			if(n == 0){
				#
				# The driver closed the queue: deassociated.
				# The pause is not politeness. A driver that
				# reports an association it cannot carry
				# frames for would otherwise spin this
				# program at full speed; the same interval
				# the association poll uses makes it a loop
				# rather than a spin.
				#
				report("link lost; re-associating");
				sys->sleep(Assocpoll);
				break;
			}
			(acts, err) := supp.recv(frame[0:n], nonce());
			if(err != nil){
				report(err);
				continue;
			}
			for(; acts != nil; acts = tl acts)
				perform(cfd, dfd, hd acts);
		}
	}
}

#
#	A fresh nonce for every frame read.  Only message 1 consumes one,
#	but the supplicant is what decides that, and a nonce is cheap.
#	An all-zero answer means there is no entropy source at all, which
#	would silently make every handshake identical: stop instead.
#
nonce(): array of byte
{
	b := random->randombuf(Random->ReallyRandom, Wpakey->Noncelen);
	if(len b != Wpakey->Noncelen)
		fatal("/dev/random gave no nonce");
	for(i := 0; i < len b; i++)
		if(b[i] != byte 0)
			return b;
	fatal("/dev/random gave an all-zero nonce; there is no entropy source");
	return nil;
}

#
#	Wait for the radio, then declare the authentication suite.  The
#	order matters: the driver joins on the essid it already has when
#	the RSN element arrives, so writing the element is what turns an
#	open join into an encrypted one.
#
associate(cfd: ref Sys->FD, rsne: array of byte)
{
	waited := 0;
	while(!connected()){
		if(waited >= Assocwait){
			report("still waiting for the radio to associate");
			waited = 0;
		}
		sys->sleep(Assocpoll);
		waited += Assocpoll;
	}
	report("associated; starting the four-way handshake");
	if(sys->fprint(cfd, "auth %s", wpakey->hex(rsne)) < 0)
		fatal(sys->sprint("auth: %r"));
}

#
#	Anything but a state the driver names as not yet usable counts as
#	associated, so that a driver reporting a state this program has
#	not heard of does not wedge it.
#
connected(): int
{
	s := ifstats("status:");
	if(s == nil)
		return 0;
	case s {
	"unassociated" or "connecting" or "unauthenticated" =>
		return 0;
	}
	return 1;
}

perform(cfd, dfd: ref Sys->FD, a: ref Action)
{
	case a.kind {
	Wpakey->Asend =>
		if(debug)
			report(sys->sprint("send %s", wpakey->hex(a.frame)));
		if(sys->write(dfd, a.frame, len a.frame) != len a.frame)
			report(sys->sprint("cannot send an EAPOL frame: %r"));
	Wpakey->Actl =>
		#
		# The key itself is in this line, so it is never echoed:
		# what is reported is which key went in, not what it is.
		#
		if(sys->fprint(cfd, "%s", a.text) < 0)
			report(sys->sprint("%s: %r", verb(a.text)));
		else
			report(sys->sprint("%s installed", keyname(a.text)));
	Wpakey->Adelay =>
		sys->sleep(a.ms);
	}
}

#
#	The first word of a ctl line, which is all of it that is safe to
#	print.
#
verb(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			return s[0:i];
	return s;
}

keyname(s: string): string
{
	v := verb(s);
	if(v == "txkey")
		return "pairwise transmit key";
	if(v == "rxkey")
		return "pairwise receive key";
	if(len v > 5 && v[0:5] == "rxkey")
		return "group key " + v[5:];
	return v;
}

#
#	Our own ethernet address, as netif prints it: twelve hexadecimal
#	digits.
#
myaddr(): array of byte
{
	fd := sys->open(dev + "/addr", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n < 2*Wpakey->Eaddrlen)
		return nil;
	return wpakey->unhex(string b[0:2*Wpakey->Eaddrlen]);
}

#
#	One value out of the interface's ifstats.  The key includes its
#	colon, and the value is the rest of the line: a network name may
#	contain spaces.
#
ifstats(key: string): string
{
	fd := sys->open(dev + "/ifstats", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[8192] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		l := hd lines;
		for(i := 0; i < len l; i++)
			if(l[i] == ' ' || l[i] == '\t')
				break;
		if(i >= len l || l[0:i] != key)
			continue;
		while(i < len l && (l[i] == ' ' || l[i] == '\t'))
			i++;
		v := l[i:];
		while(len v > 0 && (v[len v - 1] == ' ' || v[len v - 1] == '\r'))
			v = v[0:len v - 1];
		return v;
	}
	return nil;
}

#
#	The passphrase, from factotum's wpapsk protocol.  factotum holds
#	the secret and decides whether to give it out; this program only
#	asks, and holds the answer for as long as it takes to derive the
#	master key.
#
passphrase(essid: string): string
{
	fd := factotum->open();
	if(fd == nil)
		return nil;
	keyspec := sys->sprint("proto=wpapsk role=client essid=%q", essid);
	(o, nil) := factotum->rpc(fd, "start", array of byte keyspec);
	if(o != "ok"){
		sys->werrstr(o);
		return nil;
	}
	(o2, a) := factotum->rpc(fd, "read", nil);
	if(o2 != "ok"){
		sys->werrstr(o2);
		return nil;
	}
	if(a == nil || len a == 0){
		sys->werrstr("factotum returned no passphrase");
		return nil;
	}
	return string a;
}

report(s: string)
{
	sys->fprint(stderr, "wpa: %s\n", s);
}

fatal(s: string)
{
	report(s);
	raise "fail:" + s;
}
