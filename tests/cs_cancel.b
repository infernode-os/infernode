implement CsCancel;

#
# ndb/cs with queries cancelled under it; run by tests/host/cs_cancel_test.sh
# in an emulator of its own (it starts a connection server on /net).
#
# cs killed a query's Prog whenever its client went away or wrote again,
# wherever the Prog was: in the middle of a database search it died
# holding attrdb's lock, and no name was translated after that for
# anyone; and a client whose write the Prog was to answer waited for ever.
#
# No name here leaves the machine: addresses are numbers, the names are
# in the test's own database, and the one name that is not is asked only
# of a dns file of the test's own that never answers.
#

include "sys.m";
	sys: Sys;
include "draw.m";

CsCancel: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Cs: module
{
	init:	fn(nil: ref Draw->Context, nil: list of string);
};

DIR: con "/tmp/cs_cancel";
nfail := 0;

pass(s: string)
{
	sys->print("PASS: %s\n", s);
}

fail(s: string)
{
	nfail++;
	sys->print("FAIL: %s\n", s);
}

check(ok: int, s: string)
{
	if(ok)
		pass(s);
	else
		fail(s);
}

query(q: string): string
{
	fd := sys->open("/net/cs", Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("open: %r");
	if(sys->fprint(fd, "%s", q) < 0)
		return sys->sprint("write: %r");
	sys->seek(fd, big 0, 0);
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "nothing";
	return string buf[0:n];
}

tq(q: string, c: chan of string)
{
	c <-= query(q);
}

tmo(c: chan of string, ms: int)
{
	sys->sleep(ms);
	alt{
	c <-= "TIMEOUT" =>
		;
	* =>
		;
	}
}

tquery(q: string, ms: int): string
{
	c := chan[1] of string;
	spawn tq(q, c);
	spawn tmo(c, ms);
	return <-c;
}

kill(pid: int)
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

startcs(db: string, done: chan of string)
{
	cs := load Cs "/dis/ndb/cs.dis";
	if(cs == nil){
		done <-= sys->sprint("cannot load ndb/cs: %r");
		return;
	}
	{
		cs->init(nil, "cs" :: "-f" :: db :: nil);
	}exception e{
	"*" =>
		done <-= "cs: " + e;
		return;
	}
	done <-= nil;
}

# as another user: may ask cs, may not put a file beside it
other(c: chan of (string, string))
{
	ufd := sys->open("/dev/user", Sys->OWRITE);
	if(ufd == nil || sys->fprint(ufd, "csother") < 0){
		c <-= ("cannot become another user", nil);
		return;
	}
	ufd = nil;
	q := query("tcp!127.0.0.1!86");
	plant := "refused";
	if(sys->file2chan("#scs", "planted") != nil)
		plant = "made";
	c <-= (q, plant);
}

modes(what: string)
{
	(ok, d) := sys->stat("/net/cs");
	check(ok >= 0 && (d.mode & 8r777) == 8r666,
		sys->sprint("%s: /net/cs is for every program of the name space (mode %uo)", what, d.mode & 8r777));
	c := chan of (string, string);
	spawn other(c);
	(q, plant) := <-c;
	if(plant == nil){
		fail(what + ": " + q);
		return;
	}
	check(q == "/net/tcp/clone 127.0.0.1!86", what + ": another user's program is answered: " + q);
	check(plant == "refused", what + ": another user's file beside cs in its directory: " + plant);
}

victim(q: string, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWFD, 0::1::2::nil);
	query(q);
}

writer(fd: ref Sys->FD, q: string, done: chan of string)
{
	if(sys->fprint(fd, "%s", q) < 0)
		done <-= sys->sprint("%r");
	else
		done <-= "written";
}

# a dns file that takes a question and never answers it
ndnsclose := 0;
ndnsasked := 0;

fakedns(ready: chan of int)
{
	fio := sys->file2chan("/net", "dns");
	ready <-= fio != nil;
	if(fio == nil)
		return;
	for(;;) alt{
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc != nil)
			rc <-= (nil, "no answer");
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc == nil)
			ndnsclose++;	# the asker has gone
		else
			ndnsasked++;	# and is left waiting
	}
}

# the Progs running ndb/cs: its loop, and the queries it is answering
nprogs(): int
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return -1;
	n := 0;
	for(;;){
		(nr, dirs) := sys->dirread(fd);
		if(nr <= 0)
			break;
		for(i := 0; i < nr; i++){
			sfd := sys->open("/prog/"+dirs[i].name+"/status", Sys->OREAD);
			if(sfd == nil)
				continue;
			buf := array[256] of byte;
			m := sys->read(sfd, buf, len buf);
			if(m <= 0)
				continue;
			(nf, fl) := sys->tokenize(string buf[0:m], " \t\n");
			for(; nf > 1; nf--)
				fl = tl fl;
			if(fl != nil && hd fl == "Cs")
				n++;
		}
	}
	return n;
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r755);
	db := DIR + "/ndb";
	fd := sys->create(db, Sys->OWRITE, 8r644);
	if(fd == nil){
		sys->print("FAIL: cannot create %s: %r\nDONE\n", db);
		halt();
	}
	s := "";
	for(i := 0; i < 1500; i++)
		s += sys->sprint("sys=host%d ip=10.%d.%d.1\n\tmail=m%d\n", i, i/250, i%250, i);
	s += "sys=multi ip=127.0.0.1\n";
	b := array of byte s;
	sys->write(fd, b, len b);
	fd = nil;
	# what ../x named: a directory outside /net with a file called clone
	sys->create(DIR + "/fakenet", Sys->OREAD, Sys->DMDIR|8r755);
	sys->create(DIR + "/fakenet/clone", Sys->OWRITE, 8r644);

	done := chan of string;
	spawn startcs(db, done);
	if((e := <-done) != nil){
		sys->print("FAIL: %s\nDONE\n", e);
		halt();
	}
	modes("first start");

	r := tquery("tcp!127.0.0.1!80", 10000);
	check(r == "/net/tcp/clone 127.0.0.1!80", "a numeric address is translated: " + r);
	r = tquery("tcp!multi!80", 10000);
	check(r == "/net/tcp/clone 127.0.0.1!80", "a name of the database is translated: " + r);
	r = tquery("!nosuchattr=zzz", 10000);
	check(r == "write: no match", "a search of the whole database answers: " + r);

	r = tquery("../tmp/cs_cancel/fakenet!anything!x", 10000);
	check(len r >= 7 && r[0:7] == "write: ", "a network name with a slash in it is no network: " + r);
	r = tquery("tcp/../tcp!127.0.0.1!80", 10000);
	check(len r >= 7 && r[0:7] == "write: ", "nor is tcp/../tcp: " + r);
	r = tquery("..!x", 10000);
	check(len r >= 7 && r[0:7] == "write: ", "nor is ..: " + r);

	before := nprogs();

	# a program killed in the middle of its own query, as a killed dial is
	ok := 1;
	for(round := 0; round < 40 && ok; round++){
		pidc := chan of int;
		spawn victim("!nosuchattr=zzz", pidc);
		pid := <-pidc;
		sys->sleep(1 + round % 5);
		kill(pid);
		r = tquery("tcp!127.0.0.1!81", 10000);
		if(r != "/net/tcp/clone 127.0.0.1!81"){
			fail(sys->sprint("round %d: after a client was killed in its query, a numeric address: %s", round, r));
			ok = 0;
		}
	}
	if(ok)
		pass("40 clients killed in their queries, each followed by a translation that answered");

	# a second write on a descriptor while the first is being answered
	if(ok){
		for(round = 0; round < 40 && ok; round++){
			cfd := sys->open("/net/cs", Sys->ORDWR);
			wdone := chan[1] of string;
			spawn writer(cfd, "!nosuchattr=zzz", wdone);
			sys->sleep(1 + round % 5);
			sys->fprint(cfd, "tcp!127.0.0.1!80");
			cfd = nil;
			tc := chan[1] of string;
			spawn tmo(tc, 10000);
			alt{
			<-wdone =>
				;
			<-tc =>
				fail(sys->sprint("round %d: the first writer was left waiting when a second write cancelled its query", round));
				ok = 0;
			}
			if(ok){
				r = tquery("tcp!127.0.0.1!82", 10000);
				if(r != "/net/tcp/clone 127.0.0.1!82"){
					fail(sys->sprint("round %d: after a second write on a descriptor, a numeric address: %s", round, r));
					ok = 0;
				}
			}
		}
		if(ok)
			pass("40 queries cancelled by a second write: each writer answered, and a translation after each");
	}
	if(ok){
		r = tquery("tcp!multi!83", 10000);
		check(r == "/net/tcp/clone 127.0.0.1!83", "the database is still searched: " + r);
		sys->sleep(500);
		after := nprogs();
		check(before == 1 && after == 1, sys->sprint("the cancelled queries left no Prog of cs behind (%d before, %d after)", before, after));
	}

	# a query waiting for dns, cancelled.  The name is asked only once
	# the dns file here is the test's own, which answers nothing.
	if(ok){
		ready := chan of int;
		spawn fakedns(ready);
		made := <-ready;
		(sok, sd) := sys->stat("/net/dns");
		if(!made || sok < 0 || sd.qid.qtype & Sys->QTDIR)
			fail("cannot make a dns file of the test's own");
		else{
			# killed while cs waits for dns
			pidc := chan of int;
			spawn victim("tcp!waits-for-dns!80", pidc);
			pid := <-pidc;
			for(i = 0; i < 100 && ndnsasked < 1; i++)
				sys->sleep(50);
			check(ndnsasked == 1, "a name not in the database is asked of dns");
			kill(pid);
			for(i = 0; i < 100 && ndnsclose < 1; i++)
				sys->sleep(50);
			check(ndnsclose == 1, "when its client is killed, the question to dns is given up");
			r = tquery("tcp!127.0.0.1!84", 10000);
			check(r == "/net/tcp/clone 127.0.0.1!84", "and cs answers after: " + r);

			# cancelled by a second write: the first writer is answered
			cfd := sys->open("/net/cs", Sys->ORDWR);
			wdone := chan[1] of string;
			spawn writer(cfd, "tcp!waits-for-dns!80", wdone);
			for(i = 0; i < 100 && ndnsasked < 2; i++)
				sys->sleep(50);
			sys->fprint(cfd, "tcp!127.0.0.1!80");
			tc := chan[1] of string;
			spawn tmo(tc, 10000);
			alt{
			w := <-wdone =>
				check(w == "cs: request cancelled", "a writer whose query was cancelled while it waited for dns is told so: " + w);
			<-tc =>
				fail("a writer whose query was cancelled while it waited for dns was left waiting");
			}
			cfd = nil;
			for(i = 0; i < 100 && ndnsclose < 2; i++)
				sys->sleep(50);
			check(ndnsclose == 2, "and that question to dns is given up too");
			sys->remove("/net/dns");
		}
	}

	# started again while the first is still bound
	spawn startcs(db, done);
	if((e = <-done) != nil)
		fail("second start: " + e);
	else{
		modes("started again");
		r = tquery("tcp!127.0.0.1!85", 10000);
		check(r == "/net/tcp/clone 127.0.0.1!85", "the second cs answers: " + r);
	}

	sys->remove(DIR + "/fakenet/clone");
	sys->remove(DIR + "/fakenet");
	sys->remove(db);
	sys->remove(DIR);
	sys->print("FAILED %d\nDONE\n", nfail);
	halt();
}

halt()
{
	fd := sys->open("/dev/sysctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "halt");
	exit;
}
