implement AuditCanonTest;

#
# audit_canon_test - auditfs(4) seals, stores and replays one text.
#
# A real auditfs on a scratch file, written to as any holder of `log`
# may write, then read back by the server's own verify, by a second
# server started on the file, and by auditverify.
#
# What was wrong:
#
#   - A record was hashed with its CRs and LFs turned to blanks and
#     replayed with runs of blanks made one, so one write with a CR or LF
#     beside a blank (or at an end of the message, or two together) left
#     a record no replay could verify: "broken at seq n" from then on,
#     for the server and the offline verifier, and nothing after that
#     record was checked again.  A model reached it with a tool's name
#     (sealed in tool=), a peer with a user name.
#   - A source or event kept its control characters: "checkpoint" with a
#     CR after it was not the reserved event, and displayed as it.
#   - A write longer than a 9P message was sealed as several records,
#     the later ones beginning wherever the message's size fell: text
#     from the end of a long field as a source and an event.
#   - A server started on a file that did not verify took the chain's
#     state from before the break and appended at the end of the file:
#     records numbered as ones already there, on a branch no verifier
#     reached, with nothing to say so.
#   - A file ending in part of a line (a write cut short) had the next
#     record written on the same line.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "auditchain.m";
	ac: Auditchain;

AuditCanonTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/audit_canon_test.b";
DIR: con "/tmp/auditcanontest";
MNT: con "/tmp/auditcanontest/mnt";
LOG: con "/tmp/auditcanontest/log";

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

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	all := array[0] of byte;
	buf := array[Sys->ATOMICIO] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		nb := array[len all + n] of byte;
		nb[0:] = all;
		nb[len all:] = buf[0:n];
		all = nb;
	}
	return string all;
}

writefile(path, s: string)
{
	fd := sys->create(path, Sys->OWRITE, 8r600);
	if(fd == nil)
		raise "fail:cannot create " + path;
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		raise "fail:short write " + path;
}

# one write of s to the log, as audit(2) makes it; nil, or the error
wlog(s: string): string
{
	return wfile(MNT + "/log", s);
}

wfile(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("open: %r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}

verify(): string
{
	s := readfile(MNT + "/verify");
	if(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

lines(s: string): list of string
{
	(nil, l) := sys->tokenize(s, "\n");
	return l;
}

lastline(s: string): string
{
	last := "";
	for(l := lines(s); l != nil; l = tl l)
		last = hd l;
	return last;
}

contains(s, sub: string): int
{
	n := len sub;
	for(i := 0; i + n <= len s; i++)
		if(s[i:i+n] == sub)
			return 1;
	return 0;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

startauditfs()
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		raise "fail:pipe";
	spawn auditfsproc(fds[0]);
	fds[0] = nil;
	if(sys->mount(fds[1], nil, MNT, Sys->MREPL, nil) < 0)
		raise sys->sprint("fail:cannot mount auditfs: %r");
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
	{
		cmd->init(nil, "auditfs" :: "-f" :: LOG :: nil);
	} exception {
	* =>
		;
	}
}

stopauditfs()
{
	sys->unmount(nil, MNT);
	sys->sleep(300);
}

# a server on a new, empty log
fresh()
{
	stopauditfs();
	sys->remove(LOG);
	startauditfs();
}

restart()
{
	stopauditfs();
	startauditfs();
}

# the offline verifier on the file: 0 if it says ok
offline(): int
{
	av := load Command "/dis/auditverify.dis";
	if(av == nil)
		return -999;
	{
		av->init(nil, "auditverify" :: LOG :: nil);
		return 0;
	} exception {
	"fail:*" =>
		return -1;
	}
}

# A stored line's fields, read here and not by the code under test:
# (seq, source, event, message, ok).
rec(line: string): (int, string, string, string, int)
{
	(n, toks) := sys->tokenize(line, " ");
	if(n < 5 || string int hd toks != hd toks || len hd tl tl tl tl toks != 64)
		return (0, "", "", "", 0);
	msg := "";
	for(m := tl tl tl tl tl toks; m != nil; m = tl m) {
		if(msg != "")
			msg += " ";
		msg += hd m;
	}
	return (int hd toks, hd tl tl toks, hd tl tl tl toks, msg, 1);
}

# every line of the file is a record, numbered 1, 2, 3...
wellformed(t: ref T, what: string): int
{
	n := 0;
	for(l := lines(readfile(LOG)); l != nil; l = tl l) {
		(seq, nil, nil, nil, ok) := rec(hd l);
		n++;
		if(!ok) {
			t.error(sys->sprint("%s: line %d is not a record: %q", what, n, hd l));
			return n;
		}
		if(seq != n) {
			t.error(sys->sprint("%s: line %d has seq %d", what, n, seq));
			return n;
		}
	}
	return n;
}

# Writes with CR, LF, tab, NUL and blanks where the two cleanings
# disagreed: each is one record, and the chain verifies after each.
testControlsSealAsRead(t: ref T)
{
	fresh();
	t.assertseq(verify(), "ok 1", "a new log verifies");
	w := array[] of {
		"veltro toolcall agent=1 tool=read\r\n",
		"t e x\r",
		"t e x\n\n",
		"t e a\r\nb",
		"t e \nx",
		"t e  two  blanks ",
		" t e leading",
		"t\te tab\tin\tit",
		"t e nul\u0000in it",
		"t e nbsp and line separator",
		"t e",
		"t e \r\n",
	};
	for(i := 0; i < len w; i++) {
		err := wlog(w[i]);
		t.assertnil(err, sys->sprint("write %d taken", i));
		t.assertseq(verify(), sys->sprint("ok %d", i + 2), sys->sprint("chain verifies after write %d", i));
	}
	n := wellformed(t, "after the writes");
	t.asserteq(n, len w + 1, "one line a write, and the start record");
	data := readfile(LOG);
	for(i = 0; i < len data; i++)
		if(data[i] != '\n' && (data[i] < ' ' || data[i] == 16r7f)) {
			t.error(sys->sprint("control character %d in the file", data[i]));
			break;
		}
	t.assert(contains(data, " veltro toolcall ") && contains(data, " agent=1 tool=read\n"),
		"the message is the words written");
	t.assert(contains(data, " t e ") && contains(data, " tab in it\n"),
		"a tab divides words as a blank does");
	t.asserteq(offline(), 0, "auditverify says ok of the file");

	# and a second server reads the file as the first wrote it
	restart();
	t.assertseq(verify(), sys->sprint("ok %d", len w + 2), "a server started on the file verifies it");
	t.assert(contains(lastline(readfile(LOG)), " auditfs start ") &&
		contains(lastline(readfile(LOG)), "replay=ok"), "its start record says replay=ok");
}

# The reserved event is the word a reader sees.
testReservedEvent(t: ref T)
{
	fresh();
	t.assertnotnil(wlog("x checkpoint head=aa seq=1"), "checkpoint refused");
	t.assertnotnil(wlog("x checkpoint\r head=aa seq=1"), "checkpoint and a CR refused");
	t.assertnotnil(wlog("x checkpoint\thead=aa seq=1"), "checkpoint and a tab refused");
	t.assertnotnil(wlog("x\ncheckpoint\nhead=aa"), "checkpoint on a line of its own refused");
	t.assertnil(wlog("x checkpoint_ head=aa"), "another word is taken");
	t.assertseq(verify(), "ok 2", "one record sealed");
}

# One write is one record, or none.
testLongWriteRefused(t: ref T)
{
	fresh();
	s := "veltro toolcall agent=1 tool=";
	while(len s < 70000)
		s += "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ";
	s += "auditfs start host=elsewhere replay=ok";
	t.assertnotnil(wlog(s), "a write longer than a record is refused");
	t.assertseq(verify(), "ok 1", "nothing of it was sealed");
	t.asserteq(wellformed(t, "after the long write"), 1, "the file has the start record alone");
	t.assertnil(wlog("t e " + s[0:3000]), "a record of 3000 bytes is taken");
	t.assertseq(verify(), "ok 2", "and verifies");
}

# A log the code before wrote still verifies: records as it stored
# them, an empty message's trailing blank, a tab in a message and a CR
# in an event included.
testOldLogVerifies(t: ref T)
{
	stopauditfs();
	prev := ac->genesis();
	s := "";
	recs := array[] of {
		("auditfs", "start", "host=vm replay=ok"),
		("login", "unlock", "user=alice aal=3"),
		("t", "e", ""),
		("t", "e", "tab\tinside"),
		("x", "ev\r", "head=aa seq=1"),
		("veltro", "toolcall", "agent=1 tool=café"),
	};
	for(i := 0; i < len recs; i++) {
		(src, ev, msg) := recs[i];
		h := ac->extend(prev, array of byte ac->canon(i + 1, 1700000000 + i, src, ev, msg));
		s += sys->sprint("%d %d %s %s %s %s\n", i + 1, 1700000000 + i, src, ev, ac->hex(h), msg);
		prev = h;
	}
	writefile(LOG, s);
	t.asserteq(offline(), 0, "auditverify says ok of the old log");
	startauditfs();
	t.assertseq(verify(), sys->sprint("ok %d", len recs + 1), "the server verifies it");
	t.assert(contains(lastline(readfile(LOG)), "replay=ok"), "and starts on it with replay=ok");
}

# A file that does not verify: the server says so in its start record,
# numbers on from the end, and never says ok.
testBrokenFileRestart(t: ref T)
{
	fresh();
	for(i := 0; i < 5; i++)
		t.assertnil(wlog(sys->sprint("t e record=%d", i)), "write");
	t.assertseq(verify(), "ok 6", "six records");
	stopauditfs();

	# record 3 edited in place
	data := readfile(LOG);
	edited := "";
	for(l := lines(data); l != nil; l = tl l) {
		line := hd l;
		if(hasprefix(line, "3 "))
			line = line[0:len line - 1] + "9";
		edited += line + "\n";
	}
	t.assert(edited != data, "the file was edited");
	writefile(LOG, edited);

	startauditfs();
	t.assertseq(verify(), "broken at seq 3", "the server says where the break is");
	start := lastline(readfile(LOG));
	t.assert(hasprefix(start, "7 ") && contains(start, " auditfs start "),
		"the start record takes the next number after the file's last: " + start);
	t.assert(contains(start, "replay=broken@3"), "and says the replay was broken at 3");
	t.assertnil(wlog("t e after"), "a record is still taken");
	t.assert(hasprefix(lastline(readfile(LOG)), "8 "), "numbered 8");
	t.assertseq(verify(), "broken at seq 3", "verify still says broken");
	t.asserteq(wellformed(t, "after the restart"), 8, "no number is in the file twice");
	t.assert(contains(wfile(MNT + "/ctl", "checkpoint"), "broken"),
		"no checkpoint is signed over a broken chain");
	t.asserteq(offline(), -1, "auditverify does not say ok");

	# a second restart: the same break, one more start record
	restart();
	t.assertseq(verify(), "broken at seq 3", "still broken at 3 after another restart");
	t.assert(hasprefix(lastline(readfile(LOG)), "9 "), "the next start record is 9");

	# With the server running, a second break in a file already
	# broken is not the break it started with.
	data = readfile(LOG);
	edited = "";
	for(l = lines(data); l != nil; l = tl l) {
		line := hd l;
		if(hasprefix(line, "8 "))
			line += "x";
		edited += line + "\n";
	}
	writefile(LOG, edited);
	t.assert(hasprefix(verify(), "diverged:"), "an edit behind the server is diverged: " + verify());
}

# A file ending in part of a line.
testTornTail(t: ref T)
{
	fresh();
	t.assertnil(wlog("t e one"), "write");
	stopauditfs();
	data := readfile(LOG);
	writefile(LOG, data + "3 1700000000 t e 0123");
	startauditfs();
	got := readfile(LOG);
	n := 0;
	for(l := lines(got); l != nil; l = tl l)
		n++;
	t.asserteq(n, 4, "the fragment is a line of its own and the start record another");
	start := lastline(got);
	(seq, src, ev, msg, ok) := rec(start);
	t.assert(ok && src == "auditfs" && ev == "start", "the start record is whole: " + start);
	t.asserteq(seq, 3, "numbered after the last whole record");
	t.assert(contains(msg, "replay=broken@3"), "and says the replay was broken");
	t.assertseq(verify(), "broken at seq 3", "verify says where");
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
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	ac = load Auditchain Auditchain->PATH;
	if(ac == nil)
		raise "fail:cannot load auditchain";
	ac->init();

	sys->pctl(Sys->FORKNS, nil);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->create(MNT, Sys->OREAD, Sys->DMDIR | 8r755);
	sys->remove(LOG);
	startauditfs();

	run("ControlsSealAsRead", testControlsSealAsRead);
	run("ReservedEvent", testReservedEvent);
	run("LongWriteRefused", testLongWriteRefused);
	run("OldLogVerifies", testOldLogVerifies);
	run("BrokenFileRestart", testBrokenFileRestart);
	run("TornTail", testTornTail);
	stopauditfs();

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
