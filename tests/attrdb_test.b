implement AttrdbTest;

#
# attrdb(2) and ipattr(2), the network database's readers (appl/lib/attrdb.b,
# appl/lib/ipattr.b), which ndb/cs, ndb/dns and ndb/registry search.
#
# A file was searched through one shared buffer under a lock, a buffered
# channel, held for the whole scan: a Prog killed in the middle of a scan
# died holding it, and every later search of that file waited for ever.
# ndb/cs kills a query's Prog when its client goes away, so one interrupted
# dial ended name translation.  A file is now read whole when it is opened
# and searched in memory with nothing held.
#
# Also: a file a database names that cannot be read was left out without
# a word (and for good); a file removed went on answering with what it
# had; a read error was "not found"; lines that are not attributes were
# dropped silently; Dbentry.find gave a line's values backwards (so the
# first dns of "dns=A dns=B" was B); parseentry gave an entry's lines
# backwards; a database made from a string answered one search only.
# ipattr: one ipnet entry with a bad address hid every ipnet after it;
# an ipnet written with a host's address in it matched nothing.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
include "attrdb.m";
	attrdb: Attrdb;
	Db, Dbf, Dbentry, Tuples, Attr: import attrdb;
include "ip.m";
	ip: IP;
include "ipattr.m";
	ipattr: IPattr;
include "testing.m";
	testing: Testing;
	T: import testing;

AttrdbTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/attrdb_test.b";
DIR: con "/tmp/attrdb_test";

passed := 0;
failed := 0;
skipped := 0;

run(name: string, testfn: ref fn(t: ref T))
{
	t := testing->newTsrc(name, SRCFILE);
	{
		testfn(t);
	} exception {
	"fail:fatal" =>
		;
	"fail:skip" =>
		;
	* =>
		t.failed = 1;
	}
	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

nfile := 0;

mkfile(s: string): string
{
	f := DIR + "/db" + string nfile++;
	fd := sys->create(f, Sys->OWRITE, 8r644);
	if(fd == nil)
		raise "fail:cannot create " + f;
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		raise "fail:cannot write " + f;
	return f;
}

mk(s: string): ref Db
{
	return Db.open(mkfile(s));
}

kill(pid: int)
{
	fd := sys->open("#p/"+string pid+"/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# search for what is not there, for ever: nearly all its time is inside a scan
scanner(db: ref Db, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;)
		db.findpair(nil, "nosuch", "zzz");
}

finder(db: ref Db, attr, val: string, c: chan of int)
{
	(e, nil) := db.findpair(nil, attr, val);
	c <-= e != nil;
}

# does a search answer in time?  -1 if not
findin(db: ref Db, attr, val: string, ms: int): int
{
	c := chan[1] of int;
	spawn finder(db, attr, val, c);
	tc := chan[1] of int;
	spawn timer(tc, ms);
	alt{
	r := <-c =>
		return r;
	<-tc =>
		return -1;
	}
}

testKilledReader(t: ref T)
{
	s := "";
	for(i := 0; i < 3000; i++)
		s += sys->sprint("sys=host%d ip=10.%d.%d.1\n\tmail=m%d\n", i, i/250, i%250, i);
	s += "sys=last ip=10.99.99.99\n";
	db := mk(s);
	t.assert(db != nil, "the database opens");
	if(db == nil)
		return;
	for(round := 0; round < 8; round++){
		pidc := chan of int;
		spawn scanner(db, pidc);
		pid := <-pidc;
		sys->sleep(15 + round);
		kill(pid);
		r := findin(db, "sys", "last", 10000);
		if(r != 1){
			if(r < 0)
				t.error(sys->sprint("round %d: after a reader was killed in its scan, a search of the file did not answer in 10 s", round));
			else
				t.error(sys->sprint("round %d: the last entry was not found", round));
			return;
		}
	}
	t.log("eight readers killed in their scans, each followed by a search that answered");
}

testOrder(t: ref T)
{
	db := mk("sys=a ip=10.0.0.1 ip=10.0.0.2\n\tip=10.0.0.3 dns=1.1.1.1 dns=2.2.2.2\n");
	(e, nil) := db.find(nil, "sys");
	t.assert(e != nil, "the entry is found");
	if(e == nil)
		return;
	s := "";
	for(l := e.find("ip"); l != nil; l = tl l){
		(nil, al) := hd l;
		for(; al != nil; al = tl al)
			s += " " + (hd al).val;
	}
	t.assertseq(s, " 10.0.0.1 10.0.0.2 10.0.0.3", "Dbentry.find gives the values in the order written");

	ipdb := mk("sys=a ip=10.0.0.1 dns=1.1.1.1 dns=2.2.2.2\n");
	(v, nil) := ipattr->findnetattr(ipdb, "sys", "a", "dns");
	t.assertseq(v, "1.1.1.1", "the first dns of 'dns=1.1.1.1 dns=2.2.2.2'");

	(pe, nil, nil) := attrdb->parseentry("ip=1 x=first\n\tip=2 x=second\n", 1);
	t.assert(pe != nil, "parseentry gives an entry");
	if(pe != nil){
		t.assertseq(pe.findfirst("ip"), "1", "parseentry keeps the lines in order");
		t.asserteq(len pe.lines, 2, "parseentry's lines");
	}
}

testMissingInclude(t: ref T)
{
	a := mkfile("sys=ina ip=10.0.0.1\n");
	gone := DIR + "/notyet";
	sys->remove(gone);
	b := mkfile("sys=inb ip=10.0.0.2\n");
	main := mkfile(sys->sprint("database=\n\tfile=%s\n\tfile=%s\n\tfile=%s\n", a, gone, b));
	db := Db.open(main);
	t.assert(db != nil, "a database with a missing file still opens");
	if(db == nil)
		return;
	# the three it names and the file itself (which it does not name)
	t.asserteq(len db.dbs, 4, "every file the database names has its place");
	said := 0;
	for(dbs := db.dbs; dbs != nil; dbs = tl dbs)
		if((hd dbs).name == gone && (hd dbs).errs != nil)
			said = 1;
	t.assert(said, "the file that could not be read says so");
	t.asserteq(findin(db, "sys", "ina", 5000), 1, "the file before the missing one is searched");
	t.asserteq(findin(db, "sys", "inb", 5000), 1, "the file after the missing one is searched");
	t.asserteq(db.reopen(), -1, "reopen says a file could not be read");

	fd := sys->create(gone, Sys->OWRITE, 8r644);
	sys->fprint(fd, "sys=late ip=10.0.0.3\n");
	fd = nil;
	t.assert(db.changed(), "the file appearing is a change");
	t.asserteq(db.reopen(), 0, "reopen reads it once it is there");
	t.asserteq(findin(db, "sys", "late", 5000), 1, "and its entries are found");
	sys->remove(gone);
}

testRemoved(t: ref T)
{
	f := mkfile("sys=doomed ip=10.0.0.9\n");
	db := Db.open(f);
	t.assert(db != nil, "the database opens");
	if(db == nil)
		return;
	t.asserteq(findin(db, "sys", "doomed", 5000), 1, "found while the file is there");
	t.assert(!db.changed(), "nothing has changed yet");
	sys->remove(f);
	t.assert(db.changed(), "its removal is a change");
	t.asserteq(db.reopen(), -1, "reopen says it could not be read");
	t.asserteq(findin(db, "sys", "doomed", 5000), 0, "a removed file's entries are not found");
	t.assert((hd db.dbs).errs != nil, "and the file says why");
	t.assert(!db.changed(), "still missing is no further change");
}

# a file whose reads fail
badfile(rc: chan of int, stop: chan of int)
{
	sys->bind("#s", DIR + "/srv", Sys->MREPL);
	fio := sys->file2chan(DIR + "/srv", "bad");
	rc <-= fio != nil;
	if(fio == nil)
		return;
	for(;;) alt{
	(nil, nil, nil, r) := <-fio.read =>
		if(r != nil)
			r <-= (nil, "the disc is on fire");
	(nil, nil, nil, w) := <-fio.write =>
		if(w != nil)
			w <-= (0, "no");
	<-stop =>
		return;
	}
}

testReadError(t: ref T)
{
	sys->create(DIR + "/srv", Sys->OREAD, Sys->DMDIR|8r755);
	rc := chan of int;
	stop := chan of int;
	spawn badfile(rc, stop);
	if(!<-rc){
		t.skip("cannot make a file2chan file");
		return;
	}
	db := Db.open(DIR + "/srv/bad");
	err := sys->sprint("%r");
	t.assert(db == nil, "a file that cannot be read is not an empty database");
	if(db == nil)
		t.assert(len err >= 7 && err[len err-7:] == "on fire", "the error is the read's: " + err);
	stop <-= 1;
	sys->unmount(nil, DIR + "/srv");
}

testBadLine(t: ref T)
{
	f := mkfile("sys=x ip=10.0.0.1\n\tauth=secure \"\n\nsys=y ip=10.0.0.2\n");
	db := Db.open(f);
	t.assert(db != nil, "the database opens");
	if(db == nil)
		return;
	errs := (hd db.dbs).errs;
	t.assert(errs != nil, "a line that is not attributes is reported");
	if(errs != nil){
		t.asserteq(len errs, 1, "one line is bad");
		t.assertseq(hd errs, f + ":2: missing quote", "it names the file, the line and the fault");
	}
	t.asserteq(findin(db, "sys", "y", 5000), 1, "the entries after it are found");
	good := mk("sys=x ip=10.0.0.1\n\tauth=\"se cure\"\n");
	t.assert(good != nil && (hd good.dbs).errs == nil, "a file with nothing wrong reports nothing");
}

testString(t: ref T)
{
	db := Db.sopen("sys=a ip=10.0.0.1\n\nsys=b ip=10.0.0.2\n");
	t.assert(db != nil, "a database from a string");
	if(db == nil)
		return;
	(e1, nil) := db.find(nil, "sys");
	(e2, nil) := db.find(nil, "sys");
	t.assert(e1 != nil && e2 != nil, "a second search from the start finds the entry again");
	(v, err) := ipattr->findnetattr(db, "sys", "b", "ip");
	t.assertseq(v, "10.0.0.2", "ipattr on a database from a string: " + err);
	one := Db.sopen("sys=only ip=10.0.0.7\n");
	(e1, nil) = one.find(nil, "sys");
	(e2, nil) = one.find(nil, "sys");
	t.assert(e1 != nil && e2 != nil, "a search that read to the end can be made again");
	t.assert(Db.sopen("") != nil, "an empty string is an empty database");
}

testOffsets(t: ref T)
{
	f := mkfile("sys=one ip=10.0.0.1\n\nsys=two ip=10.0.0.2\n\nsys=three ip=10.0.0.3\n");
	dbf := Dbf.open(f);
	t.assert(dbf != nil, "the file opens");
	if(dbf == nil)
		return;
	(e, m, next) := dbf.readentry(0, nil, nil, 0);
	t.assert(e != nil && m == 1 && e.findfirst("sys") == "one", "the first entry");
	(e, m, next) = dbf.readentry(next, nil, nil, 0);
	t.assert(e != nil && e.findfirst("sys") == "two", "the second from where the first ended");
	# an offset in the middle of a line (one kept across a rewrite):
	# no part of a line is taken for an entry
	(e, m, nil) = dbf.readentry(4, nil, nil, 0);
	t.assert(e != nil && e.findfirst("sys") == "two", "from inside a line, the next whole entry");
	(e, m, nil) = dbf.readentry(100000, nil, nil, 0);
	t.assert(e == nil && m == 0, "an offset past the end finds nothing");
	(e, m, nil) = dbf.readentry(-5, nil, nil, 0);
	t.assert(e == nil && m == 0, "a negative offset finds nothing");
}

testIpnet(t: ref T)
{
	db := mk("ipnet=bad ip=bogus ipmask=255.255.0.0\n\nipnet=good ip=10.0.0.0 ipmask=255.0.0.0 auth=A\n\nsys=h ip=10.1.2.3\n");
	(v, err) := ipattr->findnetattr(db, "ip", "10.1.2.3", "auth");
	t.assertseq(v, "A", "an ipnet with a bad address does not hide the one after it: " + err);
	db = mk("ipnet=bad ip=10.0.0.0 ipmask=notamask\n\nipnet=good ip=10.0.0.0 ipmask=255.0.0.0 auth=A\n\nsys=h ip=10.1.2.3\n");
	(v, err) = ipattr->findnetattr(db, "ip", "10.1.2.3", "auth");
	t.assertseq(v, "A", "nor does one with a bad mask: " + err);

	db = mk("ipnet=n ip=10.1.2.3 ipmask=255.255.0.0 dns=X\n");
	(v, err) = ipattr->findnetattr(db, "ip", "10.1.9.9", "dns");
	t.assertseq(v, "X", "an ipnet written with a host's address in it is its network");
	(v, err) = ipattr->findnetattr(db, "ip", "10.2.9.9", "dns");
	t.assertseq(v, "", "and no other network");
	db = mk("ipnet=n ip=10.1.0.0 ipmask=255.255.0.0 dns=X\n");
	(v, err) = ipattr->findnetattr(db, "ip", "10.1.9.9", "dns");
	t.assertseq(v, "X", "an ipnet written as its network still matches");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	attrdb = load Attrdb Attrdb->PATH;
	ip = load IP IP->PATH;
	ipattr = load IPattr IPattr->PATH;
	if(attrdb == nil || ip == nil || ipattr == nil){
		sys->fprint(sys->fildes(2), "cannot load attrdb, ip or ipattr: %r\n");
		raise "fail:cannot load";
	}
	attrdb->init();
	ip->init();
	ipattr->init(attrdb, ip);
	sys->pctl(Sys->FORKNS, nil);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR|8r755);

	run("KilledReader", testKilledReader);
	run("Order", testOrder);
	run("MissingInclude", testMissingInclude);
	run("Removed", testRemoved);
	run("ReadError", testReadError);
	run("BadLine", testBadLine);
	run("String", testString);
	run("Offsets", testOffsets);
	run("Ipnet", testIpnet);

	for(i := 0; i < nfile; i++)
		sys->remove(DIR + "/db" + string i);
	sys->remove(DIR + "/srv");
	sys->remove(DIR);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
