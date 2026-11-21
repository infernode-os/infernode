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
#	a file in the tree.  What factotum holds for a network may be the
#	passphrase or the master key already derived from it; wpakey(2)'s
#	pmkfor is where that is decided, not here.
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
		left:		int;	# ms still to go before the next one
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

#
#	How long the radio is left unassociated before the join is asked
#	for again. The firmware's join is one attempt: if the network is
#	not there when it looks -- an access point rebooting, a board
#	that came up first -- nothing in the radio tries again, and a
#	supplicant that only watched ifstats waited for an association
#	that could never come (the Wi-Fi acceptance battery took the AP
#	down for five seconds and the board had not re-joined after two
#	minutes, "still waiting for the radio to associate" every 20 s,
#	#638). So the wait re-issues the join, and this is how often.
#
Rejoin:		con 15000;	# ms

#	The largest int, as a millisecond count: about twenty-five days.
Maxms:		con 16r7FFFFFFF;

#
#	What a peer can make this program say, and how much of it is kept.
#
#	A frame the supplicant refuses is refused before any key is looked
#	at, or because the key is wrong: anyone who can put an EAPOL frame
#	for this station on the air can send them, as many as the radio
#	will pass.  Each was a line.  On the boards the lines go to a file
#	on a RAM file system of 8MB that everything else's /tmp shares
#	(os/init: wparun), so a radio in range with no key could fill it;
#	run by hand they go to the console, which is how a board came to
#	be power-cycled (above).  So what is refused is counted, by kind,
#	and each kind is said on the schedule everything else here is said
#	on: once at once, then with the count since, at widening intervals.
#	The kinds are few (Maxkinds; any more are one kind), so the lines
#	are few whoever sends.
#
#	That bounds the rate, not the total: an access point may rekey as
#	often as it likes and anyone may break the association as often as
#	they like, and each is a few honest lines.  So the log itself is
#	bounded.  Once Maxlog bytes have been written, and standard error
#	is a file that has kept them, it is begun again from its start.
#
Maxkinds:	con 8;
Maxlog:		con 64*1024;	# bytes of log kept

stderr: ref Sys->FD;
debug := 0;
dev: string;

#
# The RSN information element offered: WPA2-PSK, pairwise CCMP, and a
# group cipher that starts as CCMP and becomes TKIP when the access
# point refuses CCMP's (802.11 status 41, "invalid group cipher", in
# ifstats' assocfail): a network in WPA/WPA2 mixed mode keys its group
# traffic with TKIP. The driver does not publish the access point's
# own element, so its refusal is how this learns.
#
rsne: array of byte;
group := "ccmp";
supp: ref Supp;
Invalidgroup: con "41";

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
		if(rsne == nil)
			rsne = wpakey->rsnie();
		if(sys->fprint(cfd, "auth %s", wpakey->hex(rsne)) < 0)
			fatal(sys->sprint("auth: %r"));
		#
		# Quoted, because the kernel's ctl parser splits on
		# spaces and an unquoted "My Network" would reach the
		# driver as two fields and be refused. Its tokenizer
		# takes rc-style single quotes, which is what %q emits.
		#
		if(sys->fprint(cfd, "essid %q", essid) < 0){
			#
			# Refused for its group cipher: a network in WPA/WPA2
			# mixed mode. The same join once more, offering the other.
			#
			if(ifstats("assocfail:") != Invalidgroup)
				fatal(sys->sprint("essid %q: %r", essid));
			othergroup();
			sys->fprint(cfd, "essid default");
			if(sys->fprint(cfd, "auth %s", wpakey->hex(rsne)) < 0)
				fatal(sys->sprint("auth: %r"));
			if(sys->fprint(cfd, "essid %q", essid) < 0)
				fatal(sys->sprint("essid %q: %r", essid));
		}
	}else{
		essid = ifstats("essid:");
		if(essid == nil || essid == "")
			fatal("no network name: give -s, or set essid on the interface first");
	}
	report(sys->sprint("%s: network %q", dev, essid));

	pass := passphrase(essid);
	if(pass == nil)
		fatal(sys->sprint("no passphrase for %q in factotum: %r", essid));
	#
	# What factotum held may be the passphrase or the key it derives
	# to; pmkfor tells the two apart.  Nothing here needs to know
	# which, and a board that stores the key keeps a secret off its
	# card that a person might have used somewhere else.
	#
	pmk := wpakey->pmkfor(pass, essid);
	pass = nil;
	if(debug)
		report(sys->sprint("pmk %s", wpakey->hex(pmk)));

	if(rsne == nil)
		rsne = wpakey->rsnie();
	supp = Supp.mk(pmk, smac, rsne);

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
	everkeyed := 0;			# in-loop recovery is for a link that once worked
	for(;;){
		tries++;
		if(retry > 0)
			sys->sleep(retry);

		#
		# JOIN AGAIN, THE WAY THE COLD BOOT DOES. The belief that
		# stood here -- that "the firmware associates on its own
		# once it has an essid and an authentication mode" -- is
		# false on this driver: a join is an effect of writing the
		# ctl, and nothing re-issued one. After "link lost" the
		# radio sat unassociated until a reboot.
		#
		# THE LATCH IS THE WHOLE DIFFICULTY. The driver keeps the
		# last essid written, and CMauth joins it if there is one
		# (ether4330.c: "if(ctl->essid[0]) wljoin(...)"). At cold
		# boot nothing is stored, so the auth write is inert and
		# the essid write performs the one join -- and that works.
		# After a drop the old name is still stored, so writing the
		# element FIRES A JOIN BY ITSELF, which blocks inside wljoin
		# and fails with "the firmware did not report an
		# association", and a loop that then skipped the essid
		# write -- as five versions of this one did, each a
		# different way -- left the radio in "connecting" for ever.
		#
		# Proved on the board with the driver's own event trace
		# (debug 1 on the ctl): a fresh supplicant started right
		# after a drop hung exactly so; the same supplicant after
		# "essid default" recovered in seconds, keys and all.
		# Timing, descriptors and process identity were each
		# eliminated first. Clearing the name is what makes the
		# element write inert again, and then the sequence below is
		# byte for byte what the startup path above writes.
		#
		# The essid write blocks for the join and may fail; that is
		# one rationed line and another turn of a loop that already
		# backs off -- never fatal, because a supplicant that exits
		# on the condition it exists to survive is a worse bug than
		# the one being fixed.
		#
		#
		# ONLY FOR A LINK THAT HAS KEYED. The two ways to arrive here
		# disconnected are not the same case. After a drop from a
		# working link this recovery is proved: 41 seconds from
		# "link lost" to "group key installed", on the board, under
		# a natural drop. After a FIRST association that never keyed
		# -- which happens on about half of this board's boots -- the
		# same re-join associates and the handshake then fails again,
		# and two boots in a row ended "did not authenticate" where
		# osinit's kill-and-restart of a passive loop had always
		# succeeded. So the boot flake keeps the behaviour that works
		# for it, and a lost link gets the one that works for that.
		#
		# (Not "tries > 1": the link-lost branch resets tries to zero
		# for its rationing, which made that gate false on exactly the
		# turn this exists for.)
		#
		if(everkeyed && !connected()){
			if(sys->fprint(cfd, "essid default") < 0 && say.due(retry))
				report(sys->sprint("essid default: %r"));
			if(sys->fprint(cfd, "auth %s", wpakey->hex(rsne)) < 0 && say.due(retry))
				report(sys->sprint("auth: %r"));
			if(sys->fprint(cfd, "essid %q", essid) < 0 && say.due(retry))
				report(sys->sprint("essid %q: %r", essid));
		}

		waited := associate(cfd, announce, essid);
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
				refused(err);
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
		if(keyed)
			everkeyed = 1;
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
		#
		# Added, not summed: both terms saturate at Maxms on their
		# own and their sum wraps negative, which Sparse.due's
		# guard (ms > 0) then lets straight through -- so the
		# rationing would have failed open at exactly the moment
		# it had been running longest.
		#
		if(say.due(addms(retry, waited))){
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
	#
	# elapsed is only ever printed, and it is milliseconds in an int,
	# which runs out after about twenty-five days.  Saturate it: a
	# supplicant left failing for a month should say "25d" for ever
	# rather than have the sum go negative.  What must not depend on
	# it is whether to speak at all, which is why the schedule below
	# counts down rather than comparing against a growing total --
	# a wrapped total would have silenced the program permanently at
	# exactly the moment someone wanted to know it was still alive.
	#
	if(ms > 0 && s.elapsed > Maxms - ms)
		s.elapsed = Maxms;
	else
		s.elapsed += ms;

	s.left -= ms;
	if(s.left > 0)
		return 0;
	if(s.gap == 0)
		s.gap = Sayfirst;
	else{
		s.gap *= 2;
		if(s.gap > Saymax || s.gap <= 0)
			s.gap = Saymax;
	}
	s.left = s.gap;
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
	if(secs >= 24*60*60){
		days := secs / (24*60*60);
		hrs := (secs % (24*60*60)) / 3600;
		if(hrs == 0)
			return sys->sprint("%dd", days);
		return sys->sprint("%dd%dh", days, hrs);
	}
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
#	"20s", then "40s", then "1m20s", then "2m40s" is a radio that has
#	not found the network, and it reads as one at a glance.
#
#
# Two millisecond counts, added without wrapping. Every caller of
# Sparse.due passes an interval, and a negative one is not an
# interval.
#
addms(a, b: int): int
{
	if(a < 0 || b < 0)
		return Maxms;
	if(a > Maxms - b)
		return Maxms;
	return a + b;
}

associate(cfd: ref Sys->FD, announce: int, essid: string): int
{
	waited := 0;
	sincejoin := 0;
	say := Sparse.mk(Sayfirst);
	while(!connected()){
		sys->sleep(Assocpoll);
		#
		# Saturating for the same reason Sparse.due is: a radio
		# that never associates would otherwise wrap this after
		# twenty-five days and start reporting negative times.
		#
		if(waited > Maxms - Assocpoll)
			waited = Maxms;
		else
			waited += Assocpoll;
		sincejoin += Assocpoll;
		if(say.due(Assocpoll))
			report(sys->sprint("still waiting for the radio to associate (%s)",
				duration(waited)));
		#
		# Ask again (see Rejoin): the same three writes as the
		# lost-link path, name cleared first so the element write
		# is inert. The essid write blocks for the join and may
		# fail; that is one rationed line and another turn here.
		#
		if(sincejoin >= Rejoin && essid != nil){
			sincejoin = 0;
			if(ifstats("assocfail:") == Invalidgroup)
				othergroup();
			sys->fprint(cfd, "essid default");
			sys->fprint(cfd, "auth %s", wpakey->hex(rsne));
			if(sys->fprint(cfd, "essid %q", essid) < 0 && say.due(Assocpoll))
				report(sys->sprint("essid %q: %r", essid));
		}
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
	#
	# Not fatal.  The write is inert only while the driver is still
	# associated: if the link went between the look at ifstats above
	# and here, the driver takes it as a join, the join fails, and so
	# does the write.  This exited on it, and nothing starts a
	# supplicant again once its link has keyed (os/init watches the
	# log, no more): a moment's loss of the link, which is what this
	# program exists to survive, became no Wi-Fi until a reboot.  It is
	# one rationed line, and the caller's read then finds the queue
	# closed and its loop turns.
	#
	if(sys->fprint(cfd, "auth %s", wpakey->hex(rsne)) < 0)
		rationed("auth", sys->sprint("auth: %r"));
	return waited;
}

#
#	Anything but a state the driver names as not yet usable counts as
#	associated, so that a driver reporting a state this program has
#	not heard of does not wedge it.
#
# The access point refused the group cipher offered: offer the other.
othergroup()
{
	was := group;
	if(group == "ccmp")
		group = "tkip";
	else
		group = "ccmp";
	rsne = wpakey->rsniegroup(group);
	if(supp != nil)
		supp.rsne = rsne;
	report(sys->sprint("the access point refuses group cipher %s; offering %s", was, group));
}

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
			rationed("send", sys->sprint("cannot send an EAPOL frame: %r"));
	Wpakey->Actl =>
		#
		# The key itself is in this line, so it is never echoed:
		# what is reported is which key went in, not what it is.
		#
		v := verb(a.text);
		if(sys->fprint(cfd, "%s", a.text) < 0){
			rationed(v, sys->sprint("%s: %r", v));
			return 0;
		}
		#
		# What the driver said, no more.  txkey and the group keys
		# are answered by the firmware, and a refusal fails the
		# write: those are installed.  The pairwise receive key is
		# a verb the driver takes and does nothing with (the
		# firmware has one pairwise key, set by txkey), so its
		# write returning says only that it was taken: it was
		# reported "installed" and counted as a key in the radio,
		# and an association whose txkey was then refused was held
		# to have keyed.
		#
		if(v == "rxkey"){
			report(sys->sprint("%s accepted", keyname(a.text)));
			return 0;
		}
		report(sys->sprint("%s installed", keyname(a.text)));
		return 1;
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

#
#	The kinds of thing said at a peer's bidding, each with its own
#	schedule: when it was last counted, how many since it was last
#	said, and how many in all.
#
Kind: adt {
	name:	string;
	say:	ref Sparse;
	last:	int;	# sys->millisec() of the last one
	since:	int;	# counted since the last line
	total:	int;
};
kinds: list of ref Kind;

#
#	Say text about a condition a peer (or a driver) can bring about
#	as often as it likes: at once the first time, then no oftener
#	than Sparse allows, with how many there have been.
#
rationed(name, text: string)
{
	k: ref Kind;
	n := 0;
	for(l := kinds; l != nil; l = tl l){
		if((hd l).name == name)
			k = hd l;
		n++;
	}
	if(k == nil){
		if(n >= Maxkinds)
			name = "other";
		for(l = kinds; l != nil; l = tl l)
			if((hd l).name == name)
				k = hd l;
		if(k == nil){
			k = ref Kind(name, Sparse.mk(0), sys->millisec(), 0, 0);
			kinds = k :: kinds;
		}
	}
	now := sys->millisec();
	ms := now - k.last;
	if(ms < 0)
		ms = 0;
	k.last = now;
	k.since++;
	if(k.total < Maxms)
		k.total++;
	if(!k.say.due(ms))
		return;
	if(k.total == 1)
		report(text);
	else
		report(sys->sprint("%s (%d of these since the last was reported, %d in all)", text, k.since, k.total));
	k.since = 0;
}

#
#	A frame the supplicant refused.  Its kind is its reason with the
#	numbers taken out, so that "stale replay counter 7" and "stale
#	replay counter 8" are one kind and not two thousand.
#
refused(err: string)
{
	name := "frame:";
	for(i := 0; i < len err && len name < 48; i++)
		if(err[i] < '0' || err[i] > '9')
			name[len name] = err[i];
	rationed(name, err);
}

logged := 0;	# bytes written since the log was last begun

report(s: string)
{
	b := array of byte ("wpa: " + s + "\n");
	if(logged + len b > Maxlog)
		relog();
	if(sys->write(stderr, b, len b) > 0)
		logged += len b;
}

#
#	Begin the log again, if it is a file that has kept what it was
#	given (a console or a pipe has no length, and keeps nothing).
#	Truncated by opening it again where that can be done; otherwise
#	written over from its start.
#
relog()
{
	n := logged;
	logged = 0;
	(ok, d) := sys->fstat(stderr);
	if(ok < 0 || (d.qid.qtype & Sys->QTDIR) || d.length < big (Maxlog/2))
		return;
	path := sys->fd2path(stderr);
	nfd: ref Sys->FD;
	if(path != nil && path != "")
		nfd = sys->open(path, Sys->OWRITE|Sys->OTRUNC);
	if(nfd != nil && sys->dup(nfd.fd, stderr.fd) >= 0)
		nfd = nil;
	else
		sys->seek(stderr, big 0, Sys->SEEKSTART);
	b := array of byte sys->sprint("wpa: the log is begun again: %d bytes had been written to it\n", n);
	if(sys->write(stderr, b, len b) > 0)
		logged = len b;
}

fatal(s: string)
{
	report(s);
	raise "fail:" + s;
}
