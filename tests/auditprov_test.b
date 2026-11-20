implement AuditProvTest;

#
# auditprov_test - live integration test of the agent-provenance
# content-store path (INFR-355): ventisrv(8) as the venti store,
# auditfs(4) as the chain, auditprov(2) composing the two.
#
# Starts a real ventisrv on a scratch data/index file pair and a real
# auditfs on a scratch backing file, then exercises put/get/dedup,
# the sha256 pin, payload-bearing records, and the content=unstored
# degradation when no store is attached.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "dial.m";
	dial: Dial;

include "venti.m";
	venti: Venti;
	Entry, Session, Score, Dirtype, Entryactive: import venti;

include "auditprov.m";
	ap: AuditProv;

AuditProvTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/auditprov_test.b";
DIR: con "/tmp/auditprovtest";
VADDR: con "tcp!127.0.0.1!17035";

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

mkfile(path: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r644);
	if(fd == nil)
		raise "fail:cannot create " + path;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	buf := array[Sys->ATOMICIO] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		s += string buf[:n];
	}
	return s;
}

lastline(s: string): string
{
	while(len s > 0 && s[len s - 1] == '\n')
		s = s[:len s - 1];
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == '\n')
			return s[i+1:];
	return s;
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

# extract "key=" value from a record line
field(line, key: string): string
{
	pat := " " + key + "=";
	n := len pat;
	for(i := 0; i + n <= len line; i++)
		if(line[i:i+n] == pat) {
			j := i + n;
			for(k := j; k < len line; k++)
				if(line[k] == ' ')
					return line[j:k];
			return line[j:];
		}
	return nil;
}

startventisrv()
{
	mkfile(DIR + "/data");
	mkfile(DIR + "/index");
	cmd := load Command "/dis/ventisrv.dis";
	if(cmd == nil)
		raise "fail:cannot load ventisrv";
	spawn cmd->init(nil, "ventisrv" :: "-d" :: DIR + "/data" :: "-i" :: DIR + "/index" ::
		"-w" :: VADDR :: "33554432" :: "8192" :: nil);
	sys->sleep(500);
}

startauditfs()
{
	sys->create("/mnt/audit", Sys->OREAD, Sys->DMDIR | 8r755);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		raise "fail:pipe";
	spawn auditfsproc(fds[0]);
	fds[0] = nil;
	if(sys->mount(fds[1], nil, "/mnt/audit", Sys->MREPL | Sys->MCREATE, nil) < 0)
		raise "fail:cannot mount auditfs";
}

auditfsproc(fd: ref Sys->FD)
{
	sys->pctl(Sys->NEWFD, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	cmd := load Command "/dis/auditfs.dis";
	if(cmd == nil) {
		sys->fprint(sys->fildes(2), "cannot load auditfs: %r\n");
		return;
	}
	cmd->init(nil, "auditfs" :: "-f" :: DIR + "/auditlog" :: nil);
}

testSha256(t: ref T)
{
	# FIPS 180 test vector pins the digest and the hex encoding
	t.assertseq(ap->sha256(array of byte "abc"),
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		"sha256(\"abc\") test vector");
}

testPlainLog(t: ref T)
{
	t.asserteq(ap->log("test", "plain", "k=v", nil), 0, "plain record seals");
	line := lastline(readfile("/mnt/audit/chain"));
	t.assert(contains(line, "test plain "), "chain carries the record");
	t.assert(contains(line, "k=v"), "message preserved");
}

testUnstored(t: ref T)
{
	# no store attached yet: the event must still seal, marked unstored
	payload := array of byte "never stored";
	t.asserteq(ap->log("test", "prov", "agent=t0", payload), -2,
		"unstored path returns -2");
	line := lastline(readfile("/mnt/audit/chain"));
	t.assert(contains(line, "content=unstored"), "record marked content=unstored");
	t.assertseq(field(line, "why"), "no-store", "and says why");
	t.assertseq(field(line, "sha256"), ap->sha256(payload),
		"sha256 pin present even when unstored");
	t.assertseq(field(line, "size"), "12", "size recorded");
}

testAttach(t: ref T)
{
	err := ap->attach(VADDR);
	t.assertnil(err, "attach to ventisrv");
	t.asserteq(ap->attached(), 1, "session up");
}

testHandshakeTimeout(t: ref T)
{
	cc := dial->dial(VADDR, nil);
	if(cc == nil) {
		t.fatal("cannot dial stalled Venti client");
		return;
	}
	# The server sends its version first, then waits for the peer version.
	# Withhold it beyond ventisrv's 10-second handshake deadline.
	sys->sleep(11000);
	buf := array[128] of byte;
	n := sys->read(cc.dfd, buf, len buf);
	t.assert(n > 0, "server greeting arrived before timeout");
	n = sys->read(cc.dfd, buf, len buf);
	t.assert(n <= 0, "stalled pre-handshake connection was hung up");
}

testPutGet(t: ref T)
{
	payload := array of byte "agent provenance payload";
	(score, sha, err) := ap->put(payload);
	t.assertnil(err, "put small payload");
	t.assertnotnil(score, "put returns a score");
	t.assertseq(sha, ap->sha256(payload), "put returns the payload sha256");

	(score2, nil, err2) := ap->put(payload);
	t.assertnil(err2, "second put");
	t.assertseq(score2, score, "identical content dedupes to one score");

	(back, gerr) := ap->get(score);
	t.assertnil(gerr, "get by score");
	t.assertseq(string back, string payload, "payload round-trips");
}

testOversizeEntry(t: ref T)
{
	cc := dial->dial(VADDR, nil);
	if(cc == nil) {
		t.fatal("cannot dial Venti for forged entry");
		return;
	}
	s := Session.new(cc.dfd);
	if(s == nil) {
		t.fatal("cannot handshake forged-entry session");
		return;
	}
	ent := ref Entry(0, 8192, 8192, 0, Entryactive,
		big AuditProv->MAXPAYLOAD + big 1, Score.zero());
	(ok, score) := s.write(Dirtype, ent.pack());
	t.assert(ok >= 0, "forged oversized entry stored");
	t.assert(s.sync() >= 0, "forged entry synced");
	(data, err) := ap->get(score.text());
	t.assert(data == nil, "oversized entry returned no allocation");
	t.assert(contains(err, "outside audit limit"), "oversized entry rejected by size cap");
}

testBigPayload(t: ref T)
{
	# spans multiple vac data blocks (3 * Dsize + 7)
	n := 3 * 8192 + 7;
	payload := array[n] of byte;
	for(i := 0; i < n; i++)
		payload[i] = byte (i * 31 + 7);
	(score, nil, err) := ap->put(payload);
	t.assertnil(err, "put multi-block payload");
	(back, gerr) := ap->get(score);
	t.assertnil(gerr, "get multi-block payload");
	t.asserteq(len back, n, "length round-trips");
	ok := 1;
	for(i = 0; i < n; i++)
		if(back[i] != payload[i]) {
			ok = 0;
			break;
		}
	t.assert(ok, "content round-trips byte-exact");
}

testEmptyPayload(t: ref T)
{
	(score, nil, err) := ap->put(array[0] of byte);
	t.assertnil(err, "put empty payload");
	(back, gerr) := ap->get(score);
	t.assertnil(gerr, "get empty payload");
	t.asserteq(len back, 0, "empty round-trips");
}

testProvRecord(t: ref T)
{
	payload := array of byte "what the agent was actually prompted with";
	t.asserteq(ap->log("veltro", "task", "agent=t1", payload), 0,
		"payload-bearing record seals");
	line := lastline(readfile("/mnt/audit/chain"));
	t.assert(contains(line, "veltro task "), "chain carries the record");
	score := field(line, "content");
	t.assertnotnil(score, "record carries content=");
	t.assertseq(field(line, "sha256"), ap->sha256(payload), "record pins sha256");
	t.assertseq(field(line, "size"), string len payload, "record carries size");

	# an auditor can fetch the payload back by the record's score
	(back, gerr) := ap->get(score);
	t.assertnil(gerr, "payload fetchable by record score");
	t.assertseq(string back, string payload, "fetched payload matches record");
}

# the words of a line that begin key=
count(line, key: string): int
{
	n := 0;
	(nil, toks) := sys->tokenize(line, " ");
	for(; toks != nil; toks = tl toks)
		if(len hd toks > len key && (hd toks)[0:len key+1] == key + "=")
			n++;
	return n;
}

chainlines(): int
{
	(n, nil) := sys->tokenize(readfile("/mnt/audit/chain"), "\n");
	return n;
}

# A message's text is not all the caller's: a tool's name is the
# model's.  One naming itself "read status=ok content=0000 sha256=ffff
# size=1" was sealed as those fields, before the emitter's own.
testInjectedFields(t: ref T)
{
	payload := array of byte "what the tool was given";
	name := "read status=ok content=0000 sha256=ffff size=1";
	before := chainlines();
	rc := ap->log("veltro", "toolres", "agent=t2 step=1 tool=" + name + " status=error", payload);
	t.asserteq(rc, 0, "the record seals");
	t.asserteq(chainlines(), before + 1, "as one record");
	line := lastline(readfile("/mnt/audit/chain"));
	t.asserteq(count(line, "content"), 1, "one content= in the record: " + line);
	t.asserteq(count(line, "sha256"), 1, "one sha256=");
	t.asserteq(count(line, "size"), 1, "one size=");
	t.assertseq(field(line, "sha256"), ap->sha256(payload), "the sha256 is the payload's");
	t.assertseq(field(line, "size"), string len payload, "the size is the payload's");
	t.assertsne(field(line, "content"), "0000", "the content is the emitter's");
	t.asserteq(count(line, "status"), 0, "a key the message gives twice is no field");
	t.asserteq(count(line, "agent"), 1, "the fields given once are kept");
	t.assertseq(field(line, "tool"), "read", "tool");

	# the same name as a caller should write it
	rc = ap->log("veltro", "toolres", "agent=t2 step=1 tool=" + ap->value(name) + " status=error", payload);
	t.asserteq(rc, 0, "the record seals");
	line = lastline(readfile("/mnt/audit/chain"));
	t.assertseq(field(line, "tool"), "read%20status%3Dok%20content%3D0000%20sha256%3Dffff%20size%3D1",
		"a value written with value() is one word");
	t.assertseq(field(line, "status"), "error", "the status is the caller's");
	t.asserteq(count(line, "content"), 1, "one content=");

	# with no payload the emitter's keys are still the emitter's
	rc = ap->log("veltro", "agentdone", "agent=t2 stop=end content=0000 sha256=ffff", nil);
	t.asserteq(rc, 0, "a record with no payload seals");
	line = lastline(readfile("/mnt/audit/chain"));
	t.asserteq(count(line, "content") + count(line, "sha256"), 0,
		"it carries no content= or sha256= of the message's: " + line);

	# a name with a line in it is one record
	before = chainlines();
	rc = ap->log("veltro", "toolcall", "agent=t2 step=2 tool=read\r\nauditfs start host=elsewhere", payload);
	t.asserteq(rc, 0, "a name with CR LF in it seals");
	t.asserteq(chainlines(), before + 1, "as one record");
	s := readfile("/mnt/audit/verify");
	t.assert(len s > 2 && s[0:3] == "ok ", "and the chain verifies: " + s);
}

# A message is bounded, so that a record is one write.
testLongMessage(t: ref T)
{
	name := "";
	while(len name < 20000)
		name += "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ";
	before := chainlines();
	rc := ap->log("veltro", "toolcall", "agent=t3 step=1 tool=" + name + "auditfs start host=elsewhere", array of byte "x");
	t.asserteq(rc, 0, "a long message seals");
	t.asserteq(chainlines(), before + 1, "as one record");
	line := lastline(readfile("/mnt/audit/chain"));
	t.assert(contains(line, " veltro toolcall "), "the record is the caller's");
	t.assertseq(field(line, "cut"), string (len "agent=t3 step=1 tool=" + len name + len "auditfs start host=elsewhere"),
		"and says it was cut, and from what length");
	t.asserteq(count(line, "content"), 1, "with its content=");
	s := readfile("/mnt/audit/verify");
	t.assert(len s > 2 && s[0:3] == "ok ", "the chain verifies: " + s);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	dial = load Dial Dial->PATH;
	if(dial == nil) {
		sys->fprint(sys->fildes(2), "cannot load dial: %r\n");
		raise "fail:cannot load dial";
	}
	venti = load Venti Venti->PATH;
	if(venti == nil) {
		sys->fprint(sys->fildes(2), "cannot load venti: %r\n");
		raise "fail:cannot load venti";
	}
	venti->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	ap = load AuditProv AuditProv->PATH;
	if(ap == nil) {
		sys->fprint(sys->fildes(2), "cannot load auditprov: %r\n");
		raise "fail:cannot load auditprov";
	}
	err := ap->init();
	if(err != nil) {
		sys->fprint(sys->fildes(2), "auditprov init: %s\n", err);
		raise "fail:auditprov init";
	}

	sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r755);
	# a log of this run's own: the checks of verify below are of what
	# these tests write, not of what an earlier run left
	sys->remove(DIR + "/auditlog");
	startauditfs();
	startventisrv();

	run("Sha256", testSha256);
	run("PlainLog", testPlainLog);
	run("Unstored", testUnstored);
	run("HandshakeTimeout", testHandshakeTimeout);
	run("Attach", testAttach);
	run("PutGet", testPutGet);
	run("OversizeEntry", testOversizeEntry);
	run("BigPayload", testBigPayload);
	run("EmptyPayload", testEmptyPayload);
	run("ProvRecord", testProvRecord);
	run("InjectedFields", testInjectedFields);
	run("LongMessage", testLongMessage);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
