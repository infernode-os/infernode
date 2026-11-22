implement FactotumNeedkeyTest;

#
# auth/factotum's needkey file, with an agent of the test's own: a
# protocol asks for a key there is none of, whoever reads needkey is told
# its tag, and answers by writing the tag back.  The list of requests
# waiting for an answer was never shortened (the list without the
# answered one was made and not kept), and the answer was sent to the
# asker without a thought for whether it was still waiting: the same tag
# written twice, or the tag of an asker that had gone, stopped the
# agent's one loop, and every file it serves, for good.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "testing.m";
	testing: Testing;
	T: import testing;

FactotumNeedkeyTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/factotum_needkey_test.b";
MNT: con "/tmp/factotum_needkey_test";

passed := 0;
nk: ref Sys->FD;	# the needkey file, held as the one agent that answers holds it
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

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

startagent(c: chan of string)
{
	sys->pctl(Sys->NEWPGRP, nil);
	mod := load Command "/dis/auth/factotum.dis";
	if(mod == nil){
		c <-= sys->sprint("cannot load factotum: %r");
		return;
	}
	c <-= nil;
	mod->init(nil, "factotum" :: "-m" :: MNT :: "-s" :: "factotum_needkey_test" :: nil);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# a read of fd, sent to c ("" for nothing read)
reader(fd: ref Sys->FD, c: chan of string)
{
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n < 0)
		c <-= sys->sprint("error: %r");
	else
		c <-= string buf[0:n];
}

# a write of s to fd: the count, or the error
writer(fd: ref Sys->FD, s: string, c: chan of string)
{
	b := array of byte s;
	if(sys->write(fd, b, len b) < 0)
		c <-= sys->sprint("error: %r");
	else
		c <-= "ok";
}

# what c gives within ms; nil if nothing
within(c: chan of string, ms: int): string
{
	tc := chan[1] of int;
	spawn timer(tc, ms);
	alt{
	s := <-c =>
		if(s == nil)
			s = "(nothing)";	# an empty string is nil
		return s;
	<-tc =>
		return nil;
	}
}

# a request for a key no one has: an rpc file with a start written to it
ask(t: ref T, service: string): ref Sys->FD
{
	rpc := sys->open(MNT + "/rpc", Sys->ORDWR);
	if(rpc == nil)
		t.fatal(sys->sprint("open rpc: %r"));
	c := chan[1] of string;
	spawn writer(rpc, "start proto=pass role=client service=" + service, c);
	r := within(c, 5000);
	if(r == nil)
		t.fatal("a start written to rpc never returned");
	# each request's answer is read before the next is written
	spawn reader(rpc, c);
	r = within(c, 5000);
	if(r == nil || !contains(r, "ok"))
		t.fatal("start was not taken: " + r);
	return rpc;
}

testAnsweredTwice(t: ref T)
{
	if(nk == nil)
		t.fatal(sys->sprint("open needkey: %r"));
	rc := chan[1] of string;
	spawn reader(nk, rc);
	sys->sleep(200);	# the agent has the read

	rpc := ask(t, "needkeytest1");
	# the protocol's first step asks for the key
	wc := chan[1] of string;
	spawn writer(rpc, "read", wc);

	req := within(rc, 5000);
	if(req == nil)
		t.fatal("no needkey request arrived");
	t.assert(contains(req, "needkey tag=") && contains(req, "needkeytest1"), "the request names its tag and what is asked for: " + req);
	(nil, f) := sys->tokenize(req, " ");
	tag := hd tl f;	# tag=N

	# answered: there is still no such key, so the asker is told so
	t.assertseq(within2(tag), "ok", "the tag written back is taken");
	# and the same tag again is not a request any more
	r := within2(tag);
	if(r == nil)
		t.fatal("the tag written a second time was never answered: the agent has stopped");
	t.assert(contains(r, "tag not found"), "the tag written a second time is not found: " + r);

	alive(t);
}

# the tag written to needkey, given 5 seconds
within2(tag: string): string
{
	c := chan[1] of string;
	spawn writer(nk, tag, c);
	return within(c, 5000);
}

# the agent still serves: its ctl file reads
alive(t: ref T)
{
	ctl := sys->open(MNT + "/ctl", Sys->OREAD);
	if(ctl == nil)
		t.fatal(sys->sprint("open ctl: %r"));
	c := chan[1] of string;
	spawn reader(ctl, c);
	t.assert(within(c, 5000) != nil, "the agent's ctl file still reads");
}

# an asker that has gone before its tag is answered
testAskerGone(t: ref T)
{
	if(nk == nil)
		t.fatal(sys->sprint("open needkey: %r"));
	rc := chan[1] of string;
	spawn reader(nk, rc);
	sys->sleep(200);

	rpc := ask(t, "needkeytest2");
	wc := chan[1] of string;
	spawn writer(rpc, "read", wc);
	req := within(rc, 5000);
	if(req == nil)
		t.fatal("no needkey request arrived");
	(nil, f) := sys->tokenize(req, " ");
	tag := hd tl f;

	rpc = nil;	# the asker's file closed: the agent kills its request
	sys->sleep(500);

	r := within2(tag);
	if(r == nil)
		t.fatal("the tag of an asker that had gone was never answered: the agent has stopped");
	t.log("answer to the tag of an asker that had gone: " + r);
	alive(t);
}

# a request and its answer on an rpc file, given 5 seconds each way
rpcreq(rpc: ref Sys->FD, req: array of byte): string
{
	c := chan[1] of string;
	spawn bwriter(rpc, req, c);
	r := within(c, 5000);
	if(r == nil)
		return "TIMEOUT in write";
	spawn reader(rpc, c);
	r = within(c, 5000);
	if(r == nil)
		return "TIMEOUT in read";
	return r;
}

bwriter(fd: ref Sys->FD, b: array of byte, c: chan of string)
{
	if(sys->write(fd, b, len b) < 0)
		c <-= sys->sprint("error: %r");
	else
		c <-= "ok";
}

setkey(t: ref T, s: string)
{
	ctl := sys->open(MNT + "/ctl", Sys->OWRITE);
	if(ctl == nil || sys->fprint(ctl, "%s", s) < 0)
		t.fatal(sys->sprint("ctl %s: %r", s));
}

#
# A protocol that looks for a key under each of several names (p9any,
# the domains a server offers) asked the agent for every one it did not
# find, though the next had a key: findkeys asked as findkey does.  It
# only looks now; the agent is asked once, when no domain has a key,
# for the first.
#
testProbe(t: ref T)
{
	if(nk == nil)
		t.fatal(sys->sprint("open needkey: %r"));
	setkey(t, "key proto=p9sk1 dom=lab user=carol !password=short");
	rc := chan[1] of string;
	spawn reader(nk, rc);
	sys->sleep(200);	# the agent has the read

	rpc := sys->open(MNT + "/rpc", Sys->ORDWR);
	if(rpc == nil)
		t.fatal(sys->sprint("open rpc: %r"));
	t.assert(contains(rpcreq(rpc, array of byte "start proto=p9any role=client"), "ok"), "start p9any");
	offer := array of byte "write p9sk1@nokey1 p9sk1@nokey2 p9sk1@lab\0";
	t.assert(contains(rpcreq(rpc, offer), "ok"), "the server's offer is written");
	r := rpcreq(rpc, array of byte "read");
	t.assert(contains(r, "ok p9sk1 lab"), "of three domains the one with a key is taken: " + r);
	asked := within(rc, 300);
	t.assert(asked == nil, "and the agent is not asked for a key for the others: " + asked);
	rpc = nil;

	# no domain has a key: the agent is asked, once, for the first
	rpc = sys->open(MNT + "/rpc", Sys->ORDWR);
	t.assert(contains(rpcreq(rpc, array of byte "start proto=p9any role=client"), "ok"), "start p9any again");
	offer = array of byte "write p9sk1@nokey1 p9sk1@nokey2\0";
	# the answer to this write waits for the key
	wc := chan[1] of string;
	spawn bwriter(rpc, offer, wc);
	t.assert(within(wc, 5000) != nil, "an offer of two domains with no key");
	ac := chan[1] of string;
	spawn reader(rpc, ac);
	if(asked == nil)
		asked = within(rc, 5000);
	if(asked == nil)
		t.fatal("the agent was not asked for a key when no domain had one");
	t.assert(contains(asked, "nokey1") && !contains(asked, "nokey2"), "the agent is asked for the first domain's key: " + asked);
	(nil, f) := sys->tokenize(asked, " ");
	t.assertseq(within2(hd tl f), "ok", "and its answer is taken");
	ans := within(ac, 5000);
	t.assert(ans != nil && contains(ans, "can't find key"), "the protocol, told there is no key, says so: " + ans);
	spawn reader(nk, rc);
	again := within(rc, 500);
	t.assert(again == nil, "and the agent is not asked again for the second domain: " + again);
	rpc = nil;
	alive(t);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	sys->pctl(Sys->FORKNS, nil);
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r777);
	c := chan of string;
	spawn startagent(c);
	if((e := <-c) != nil){
		sys->fprint(sys->fildes(2), "factotum_needkey_test: %s\n", e);
		raise "fail:setup";
	}
	for(i := 0; i < 50; i++){
		(ok, nil) := sys->stat(MNT + "/needkey");
		if(ok >= 0)
			break;
		sys->sleep(100);
	}

	nk = sys->open(MNT + "/needkey", Sys->ORDWR);

	run("AnsweredTwice", testAnsweredTwice);
	run("AskerGone", testAskerGone);
	run("Probe", testProbe);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
