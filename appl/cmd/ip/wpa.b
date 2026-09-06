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

	#
	# The rate limit on anything said about a condition that
	# persists.  See Sparse.due below.
	#
	Sparse: adt {
		elapsed:	int;	# ms this condition has lasted
		gap:		int;	# ms between the last line and the next
		next:		int;	# elapsed at which another line falls due
		said:		int;	# lines said about it so far

		mk:	fn(first: int): ref Sparse;
		due:	fn(s: self ref Sparse, ms: int): int;
	};
};

Defaultdev:	con "/net/ether1";

#
#	How often the interface is asked whether it has associated.  This
#	stays short: the point of the poll is to notice an association
#	the moment the firmware makes one.  What backs off is not the
#	polling, it is the talking.
#
Assocpoll:	con 100;	# ms

#
#	The reporting schedule.  A condition is announced, then not again
#	for Sayfirst, then at twice the previous interval each time, up
#	to Saymax.
#
#	This exists because of what a board did on 2026-09-06.  The
#	supplicant lost its association, re-associated, found the queue
#	closed, and said so -- fifty-odd lines a second, on a machine
#	whose only console is a serial line.  There was no way to type a
#	command to stop it; the board had to be power-cycled.  Retrying
#	was right.  Narrating every retry was not.
#
#	Silence is not the fix either: a person watching a board has to
#	be able to tell a supplicant that is trying from one that is
#	stuck.  So the lines that survive carry how long the trouble has
#	lasted and how many attempts it has taken, and an hour of a link
#	that will not come up costs about a dozen of them.
#
Sayfirst:	con 20000;	# ms
Saymax:		con 600000;	# ms

#
#	And the pause before another association is attempted, which
#	doubles on its own, shorter, schedule: a link that comes back
#	should be picked up within a minute even after an hour of
#	failure, so this is capped far below Saymax.
#
Retryfirst:	con 100;	# ms
Retrymax:	con 60000;	# ms

#
#	An association that lasted less than this and installed no key
#	did not really work, whatever the driver said.  Without the
#	floor, a radio that reports a link and drops it again inside a
#	millisecond would reset the backoff every time and the flood
#	would come straight back.
#
Realassoc:	con 1000;	# ms

stderr: ref Sys->FD;
debug := 0;
dev: string;

#
# The RSN information element for WPA2-PSK with CCMP: element 0x30,
# twenty bytes, version 1, group cipher CCMP, one pairwise cipher
# CCMP, one authentication suite PSK, no capabilities.
#
RSNE: con "30140100000fac040100000fac040100000fac020000";

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
		# The security element FIRST, then the name. Writing the
		# name is what starts the association, and a radio told to
		# associate before it has been told what protection to ask
		# for offers none: the access point refuses and the driver
		# reports "join failed", which is exactly what a board did
		# against a real WPA2 network. The element says WPA2-PSK
		# with CCMP for both the pairwise and the group cipher,
		# which is the only thing this program implements; a
		# driver that published what the access point advertised
		# would let us echo that instead, and ours does not yet.
		#
		if(sys->fprint(cfd, "auth %s", RSNE) < 0)
			fatal(sys->sprint("auth: %r"));
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

	#
	# One association attempt per turn of this loop, for as long as
	# the machine is on the network.
	#
	# Two things are throttled here and they are not the same thing.
	# retry is how long to wait before asking the radio again, and it
	# is kept short so a link that comes back is picked up quickly.
	# say is how often any of it may be mentioned, and it is much
	# slower, because the console is a serial line and a person
	# reading it needs the shape of the trouble, not a transcript.
	#
	frame := array[4096] of byte;
	retry := 0;			# ms waited before this attempt
	tries := 0;			# associations attempted since the last real one
	say := Sparse.mk(0);		# what may be said about a link that will not hold
	announce := 1;			# the next association is worth mentioning
	for(;;){
		tries++;
		if(retry > 0)
			sys->sleep(retry);

		#
		# The firmware associates on its own once it has an essid
		# and an authentication mode; all this waits for is the
		# moment it says so.
		#
		waited := associate(cfd, rsne, announce);
		announce = 0;
		supp.reset();
		began := sys->millisec();
		keyed := 0;

		for(;;){
			n = sys->read(dfd, frame, len frame);
			if(n < 0)
				fatal(sys->sprint("%s/%s/data: %r", dev, conv));
			if(n == 0)
				break;		# the driver closed the queue: deassociated
			(acts, err) := supp.recv(frame[0:n], nonce());
			if(err != nil){
				report(err);
				continue;
			}
			for(; acts != nil; acts = tl acts)
				keyed |= perform(cfd, dfd, hd acts);
		}

		#
		# An association that installed a key and lasted a moment
		# was a real one.  Losing it is ordinary, worth one line,
		# and worth retrying at once -- and it clears the record of
		# whatever went wrong before, because whatever it was has
		# stopped.
		#
		if(keyed && sys->millisec() - began >= Realassoc){
			report("link lost; re-associating");
			retry = Retryfirst;
			tries = 0;
			say = Sparse.mk(0);
			announce = 1;
			continue;
		}

		#
		# And an association that carried nothing is the case that
		# floods.  The driver reports a link, the queue ends at
		# once, and the whole cycle can turn tens of times a
		# second; every line about it is therefore rationed, and
		# the ones that get through say how long this has been
		# going on and how many attempts it has taken.
		#
		if(say.due(retry + waited)){
			if(say.said == 1)
				report("link lost; re-associating");
			else
				#
				# tries, not say.said: the attempts are the
				# thing being rationed away, so the line that
				# survives has to carry how many of them
				# there were.  A reader comparing two of
				# these lines sees both numbers climbing,
				# which is a supplicant still working, or
				# sees them stop, which is not.
				#
				report(sys->sprint(
					"the link will not hold: %d attempts over %s, still trying every %s",
					tries, duration(say.elapsed), duration(retry)));
			announce = 1;
		}
		if(retry < Retryfirst)
			retry = Retryfirst;
		else{
			retry *= 2;
			if(retry > Retrymax || retry <= 0)
				retry = Retrymax;
		}
	}
}

#
#	Whether a condition that has now lasted another ms may be spoken
#	about again.
#
#	The first line falls due after first ms -- 0 for a condition that
#	should be announced the moment it appears, Sayfirst for one that
#	is only worth mentioning if it persists.  After that the interval
#	doubles to Saymax and stays there, so an hour of trouble is
#	roughly a dozen lines whose intervals grow: the timestamps
#	themselves are what tell a reader that this is a supplicant
#	still trying rather than one wedged.
#
Sparse.mk(first: int): ref Sparse
{
	return ref Sparse(0, 0, first, 0);
}

Sparse.due(s: self ref Sparse, ms: int): int
{
	s.elapsed += ms;
	if(s.elapsed < s.next)
		return 0;
	if(s.gap == 0)
		s.gap = Sayfirst;
	else{
		s.gap *= 2;
		if(s.gap > Saymax || s.gap <= 0)
			s.gap = Saymax;
	}
	s.next = s.elapsed + s.gap;
	s.said++;
	return 1;
}

#
#	A length of time a person reads at a glance.  Two lines about the
#	same condition differ by this, and that difference is the whole
#	of what distinguishes "trying" from "stuck" once the lines are
#	rationed.
#
duration(ms: int): string
{
	if(ms < 1000)
		return sys->sprint("%dms", ms);
	secs := ms / 1000;
	if(secs < 60)
		return sys->sprint("%ds", secs);
	mins := secs / 60;
	secs %= 60;
	if(mins < 60){
		if(secs == 0)
			return sys->sprint("%dm", mins);
		return sys->sprint("%dm%ds", mins, secs);
	}
	hours := mins / 60;
	mins %= 60;
	if(mins == 0)
		return sys->sprint("%dh", hours);
	return sys->sprint("%dh%dm", hours, mins);
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
#	Returns how long it waited, which is the caller's measure of how
#	long the trouble has lasted.
#
#	Nothing is said for the first Sayfirst of waiting, because a
#	radio takes a second or two to join and saying so every time
#	would be noise.  After that the same doubling schedule as
#	everywhere else applies, and each line carries the elapsed time:
#	"20s", then "1m", then "2m20s" is a radio that has not found the
#	network, and it reads as one at a glance.
#
associate(cfd: ref Sys->FD, rsne: array of byte, announce: int): int
{
	waited := 0;
	say := Sparse.mk(Sayfirst);
	while(!connected()){
		sys->sleep(Assocpoll);
		waited += Assocpoll;
		if(say.due(Assocpoll))
			report(sys->sprint("still waiting for the radio to associate (%s)",
				duration(waited)));
	}
	#
	# Said when the caller asked for it, and whenever the radio kept
	# us waiting long enough to have complained.  A re-association
	# the driver grants instantly says nothing: that is the case that
	# repeats without end, and announcing it is what filled the
	# console.
	#
	if(announce || say.said > 0)
		report("associated; starting the four-way handshake");
	if(sys->fprint(cfd, "auth %s", wpakey->hex(rsne)) < 0)
		fatal(sys->sprint("auth: %r"));
	return waited;
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

#
#	Do one thing the supplicant asked for, and answer whether it was
#	a key going into the radio.  That answer is what tells the loop
#	above the difference between an association that worked and one
#	that only looked like it, and so whether to retry at once or to
#	back off and go quiet.
#
perform(cfd, dfd: ref Sys->FD, a: ref Action): int
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
		else{
			report(sys->sprint("%s installed", keyname(a.text)));
			return 1;
		}
	Wpakey->Adelay =>
		sys->sleep(a.ms);
	}
	return 0;
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
