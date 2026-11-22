implement DialLibTest;

#
# dial(2), the Limbo dial (appl/lib/dial.b), with a connection server and
# a network directory of the test's own: the connection server is whatever
# file is at netdir/cs, and what it answers is not to be trusted further
# than a translation.
#
#  - the clone file it names is netdir/proto/clone and nothing else: an
#    answer with more elements (/x/../t/clone) was opened and written to,
#    anywhere the caller could reach
#  - the address it gives is one word: a second went into the connect
#    request as the local address
#  - an answer that is no translation, or no answer, leaves an error that
#    says so (the error string was emptied)
#  - a clone file's reply is a conversation's number (anything else was
#    conversation 0)
#  - a connection server that never stops answering does not keep dial
#    for ever
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "dial.m";
	dial: Dial;
include "testing.m";
	testing: Testing;
	T: import testing;

DialLibTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/dial_lib_test.b";
DIR: con "/tmp/dial_lib_test";
NET: con DIR + "/fnet";	# the network directory: cs, from #s, before REAL
REAL: con DIR + "/real";	# its protocols, ordinary files

passed := 0;
failed := 0;
skipped := 0;

# what the connection server answers a question with, and how often it was asked
script: list of string;
forever: string;
nasked := 0;
nread := 0;

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

fakecs(f: ref Sys->FileIO)
{
	ans: list of string;
	for(;;) alt{
	(nil, data, nil, wc) := <-f.write =>
		if(wc == nil)
			continue;
		nasked++;
		ans = script;
		wc <-= (len data, nil);
	(nil, nil, nil, rc) := <-f.read =>
		if(rc == nil)
			continue;
		nread++;
		if(forever != nil)
			rc <-= (array of byte forever, nil);
		else if(ans == nil)
			rc <-= (nil, nil);
		else{
			rc <-= (array of byte hd ans, nil);
			ans = tl ans;
		}
	}
}

put(file, s: string)
{
	fd := sys->create(file, Sys->OWRITE, 8r666);
	if(fd == nil)
		raise "fail:cannot create " + file;
	b := array of byte s;
	sys->write(fd, b, len b);
}

get(file: string): string
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("<%r>");
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		return sys->sprint("<%r>");
	return string buf[0:n];
}

mkdir(d: string)
{
	sys->create(d, Sys->OREAD, Sys->DMDIR|8r777);
}

# a protocol whose clone file says conversation 7, which has a data file
proto(name, reply: string)
{
	mkdir(REAL + "/" + name);
	mkdir(REAL + "/" + name + "/7");
	mkdir(REAL + "/" + name + "/0");
	put(REAL + "/" + name + "/clone", reply);
	put(REAL + "/" + name + "/7/data", "");
	put(REAL + "/" + name + "/0/data", "");
}

dialproc(addr: string, c: chan of (int, string))
{
	sys->werrstr("left over from before");
	conn := dial->dial(addr, nil);
	if(conn == nil)
		c <-= (0, sys->sprint("%r"));
	else
		c <-= (1, conn.dir);
}

timer(c: chan of (int, string), ms: int)
{
	for(e := 0; e < ms; e += 100)
		sys->sleep(100);
	alt{
	c <-= (-1, "TIMEOUT") =>
		;
	* =>
		;
	}
}

# (1, the conversation's directory), (0, the error) or (-1, "TIMEOUT")
tdial(addr: string, answers: list of string): (int, string)
{
	script = answers;
	c := chan[1] of (int, string);
	spawn dialproc(addr, c);
	spawn timer(c, 5000);
	return <-c;
}

testTranslation(t: ref T)
{
	proto("tcp", "7\n");
	(ok, s) := tdial(NET + "/tcp!foo!1", "/net/tcp/clone 1.2.3.4!1" :: nil);
	t.asserteq(ok, 1, "a translation is dialled: " + s);
	t.assertseq(s, NET + "/tcp/7", "in the conversation the clone file named");
	t.assertseq(get(NET + "/tcp/clone"), "7\nconnect 1.2.3.4!1", "with the address the connection server gave");

	# a second recipe is tried when the first cannot be
	proto("tcp", "7\n");
	(ok, s) = tdial(NET + "/tcp!foo!1", "/net/nosuch/clone 9.9.9.9!9" :: "/net/tcp/clone 1.2.3.4!2" :: nil);
	t.asserteq(ok, 1, "the second recipe when the first fails: " + s);
	t.assertseq(get(NET + "/tcp/clone"), "7\nconnect 1.2.3.4!2", "with the second's address");
}

testCloneOutside(t: ref T)
{
	proto("tcp", "7\n");
	mkdir(DIR + "/t");
	mkdir(DIR + "/t/7");
	put(DIR + "/t/7/data", "");
	bad := array[] of {
		"/x/../t/clone 1.2.3.4!1",
		"/net/tcp/../../t/clone 1.2.3.4!1",
		"/net/../t/clone 1.2.3.4!1",
		"../t/clone 1.2.3.4!1",
		"/net/tcp/7/data 1.2.3.4!1",
		"/net/tcp 1.2.3.4!1",
		"/net/./clone 1.2.3.4!1",
	};
	for(i := 0; i < len bad; i++){
		put(DIR + "/t/clone", "7\n");
		(ok, s) := tdial(NET + "/tcp!foo!1", bad[i] :: nil);
		t.asserteq(ok, 0, sys->sprint("%q is not dialled: %s", bad[i], s));
		t.assertseq(get(DIR + "/t/clone"), "7\n", "and the file outside the network directory is not written");
		t.assertseq(get(NET + "/tcp/7/data"), "", "nor a conversation's data file");
	}
	c := dial->announce(NET + "/tcp!*!1");
	script = "/x/../t/clone 1" :: nil;
	c = dial->announce(NET + "/tcp!*!1");
	t.assert(c == nil, "announce refuses such a clone file too");
	t.assertseq(get(DIR + "/t/clone"), "7\n", "and does not write it");
	sys->remove(DIR + "/t/7/data");
	sys->remove(DIR + "/t/7");
	sys->remove(DIR + "/t/clone");
	sys->remove(DIR + "/t");
}

testAddress(t: ref T)
{
	proto("tcp", "7\n");
	(ok, s) := tdial(NET + "/tcp!foo!1", "/net/tcp/clone 1.2.3.4!1 9.9.9.9!44" :: nil);
	t.asserteq(ok, 0, "an address of two words is not dialled: " + s);
	t.assertseq(get(NET + "/tcp/clone"), "7\n", "and nothing is written to the clone file");
	(ok, s) = tdial(NET + "/tcp!foo!1", "/net/tcp/clone 1.2.3.4!1\nhangup" :: nil);
	t.asserteq(ok, 0, "nor one with a new line in it: " + s);
	t.assertseq(get(NET + "/tcp/clone"), "7\n", "and nothing is written");
}

testErrors(t: ref T)
{
	proto("tcp", "7\n");
	(ok, s) := tdial(NET + "/tcp!foo!1", "noblankinthis" :: nil);
	t.asserteq(ok, 0, "an answer with no blank in it is not dialled");
	t.assert(s != nil && s != "left over from before", "and the error says so: " + s);
	(ok, s) = tdial(NET + "/tcp!foo!1", nil);
	t.asserteq(ok, 0, "no answer is not dialled");
	t.assertseq(s, "cs: no translation", "and the error says there was none");
}

testCloneReply(t: ref T)
{
	replies := array[] of {"junk\n", "7 junk\n", "-1\n", "\n", "7x", "99999999999999999999\n"};
	for(i := 0; i < len replies; i++){
		proto("tcp", replies[i]);
		(ok, s) := tdial(NET + "/tcp!foo!1", "/net/tcp/clone 1.2.3.4!1" :: nil);
		t.asserteq(ok, 0, sys->sprint("a clone file that says %q is not dialled: %s", replies[i], s));
	}
	proto("tcp", " 7 \n");
	(ok, s) := tdial(NET + "/tcp!foo!1", "/net/tcp/clone 1.2.3.4!1" :: nil);
	t.assert(ok == 1 && s == NET + "/tcp/7", "a number with blanks round it is: " + s);
}

testForever(t: ref T)
{
	proto("tcp", "7\n");
	forever = "/net/nosuch/clone 1.2.3.4!1";
	nread = 0;
	(ok, s) := tdial(NET + "/tcp!foo!1", nil);
	forever = nil;
	t.asserteq(ok, 0, "a connection server that never stops answering does not keep dial for ever: " + s);
	t.assert(nread > 0 && nread <= 100, sys->sprint("it is asked a bounded number of times (%d)", nread));
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
	dial = load Dial Dial->PATH;
	if(dial == nil){
		sys->fprint(sys->fildes(2), "cannot load dial: %r\n");
		raise "fail:cannot load dial";
	}

	sys->pctl(Sys->FORKNS, nil);
	mkdir(DIR);
	mkdir(NET);
	mkdir(REAL);
	if(sys->bind("#s", NET, Sys->MREPL) < 0 || sys->bind(REAL, NET, Sys->MAFTER) < 0){
		sys->fprint(sys->fildes(2), "cannot bind #s on %s: %r\n", NET);
		raise "fail:setup";
	}
	f := sys->file2chan(NET, "cs");
	if(f == nil){
		sys->fprint(sys->fildes(2), "cannot make %s/cs: %r\n", NET);
		raise "fail:setup";
	}
	spawn fakecs(f);

	run("Translation", testTranslation);
	run("CloneOutside", testCloneOutside);
	run("Address", testAddress);
	run("Errors", testErrors);
	run("CloneReply", testCloneReply);
	run("Forever", testForever);

	sys->unmount(nil, NET);
	names := array[] of {"/tcp/7/data", "/tcp/7", "/tcp/0/data", "/tcp/0", "/tcp/clone", "/tcp", ""};
	for(i := 0; i < len names; i++)
		sys->remove(REAL + names[i]);
	sys->remove(NET);
	sys->remove(DIR);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
