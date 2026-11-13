implement ExportLimits;

#
# export(2)'s limits on what one connection may hold (exportfs.c's Maxfids
# and Maxreqs), which nothing counted: a peer chose how many Chans, request
# buffers and slave processes an export kept.
#  - fids: attaches past the limit are refused "too many fids", exactly at
#    the limit; a fid clunked makes room for one more
#  - requests: reads of a file that never answers, sent past the limit, are
#    refused "too many requests outstanding" while the first are still
#    waiting; the connection dropped, another serves at once
# Not a _test: it leaves a thousand slave processes in its emulator, so
# tests/host/export_limits_test.sh runs it in an emulator of its own.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "testing.m";
	testing: Testing;
	T: import testing;

ExportLimits: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/export_limits.b";
DIR: con "/tmp/export_limits";
MAXFIDS: con 32768;	# exportfs.c's Maxfids
MAXREQS: con 1024;	# exportfs.c's Maxreqs
OVER: con 60;
BATCH: con 128;

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

# DIR exported on a TCP connection over the loopback; the client's end
exported(t: ref T): ref Sys->FD
{
	(ok, ac) := sys->announce("tcp!127.0.0.1!0");
	if(ok < 0){
		t.fatal(sys->sprint("announce: %r"));
		return nil;
	}
	local := readfile(ac.dir + "/local");
	(nil, f) := sys->tokenize(local, "!\n");
	if(len f < 2){
		t.fatal("no local address: " + local);
		return nil;
	}
	ready := chan of string;
	spawn serve(ac, ready);
	(dok, c) := sys->dial("tcp!127.0.0.1!" + hd tl f, nil);
	if(dok < 0){
		t.fatal(sys->sprint("dial: %r"));
		return nil;
	}
	if((e := <-ready) != nil){
		t.fatal("export: " + e);
		return nil;
	}
	return c.dfd;
}

serve(ac: Sys->Connection, ready: chan of string)
{
	(ok, c) := sys->listen(ac);
	if(ok < 0){
		ready <-= sys->sprint("listen: %r");
		return;
	}
	dfd := sys->open(c.dir + "/data", Sys->ORDWR);
	if(dfd == nil){
		ready <-= sys->sprint("open data: %r");
		return;
	}
	if(sys->export(dfd, DIR, Sys->EXPASYNC) < 0){
		ready <-= sys->sprint("%r");
		return;
	}
	ready <-= nil;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[128] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

send(t: ref T, fd: ref Sys->FD, ms: array of ref Tmsg)
{
	n := 0;
	for(i := 0; i < len ms; i++)
		n += ms[i].packedsize();
	b := array[n] of byte;
	o := 0;
	for(i = 0; i < len ms; i++){
		p := ms[i].pack();
		b[o:] = p;
		o += len p;
	}
	if(sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("write of %d messages: %r", len ms));
}

# a reply, or a failed test: the server must go on answering
recv(t: ref T, fd: ref Sys->FD, what: string): ref Rmsg
{
	r := Rmsg.read(fd, 1024*1024);
	if(r == nil){
		t.fatal("no reply (connection closed): " + what);
		return nil;
	}
	pick e := r {
	Readerror =>
		t.fatal("reply unreadable: " + what + ": " + e.error);
	}
	return r;
}

rpc(t: ref T, fd: ref Sys->FD, m: ref Tmsg): ref Rmsg
{
	send(t, fd, array[] of {m});
	return recv(t, fd, m.text());
}

ename(r: ref Rmsg): string
{
	pick e := r {
	Error =>
		return e.ename;
	}
	return nil;
}

# the reply must be of this kind
want(t: ref T, r: ref Rmsg, kind: int, what: string)
{
	if(r == nil || tagof r != kind)
		t.fatal(what + ": got " + r.text());
}

refused(t: ref T, r: ref Rmsg, why: string, what: string)
{
	e := ename(r);
	if(e == nil){
		t.error(what + ": not refused: " + r.text());
		return;
	}
	if(!contains(e, why))
		t.error(what + ": refused with \"" + e + "\", want \"" + why + "\"");
}

contains(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}


# n requests made by mk(i), i from first, sent BATCH at a time, each batch's
# replies read before the next is sent; counts of replies by kind
batches(t: ref T, fd: ref Sys->FD, first, n: int, mk: ref fn(i: int): ref Tmsg, why: string): (int, int, int)
{
	ok := 0;
	refusedwhy := 0;
	other := 0;
	for(i := 0; i < n; i += BATCH){
		m := n - i;
		if(m > BATCH)
			m = BATCH;
		ms := array[m] of ref Tmsg;
		for(j := 0; j < m; j++)
			ms[j] = mk(first+i+j);
		send(t, fd, ms);
		for(j = 0; j < m; j++){
			r := recv(t, fd, "a batch");
			e := ename(r);
			if(e == nil)
				ok++;
			else if(contains(e, why))
				refusedwhy++;
			else{
				if(other == 0)
					t.log("refused otherwise: " + e);
				other++;
			}
		}
	}
	return (ok, refusedwhy, other);
}

mkattach(i: int): ref Tmsg
{
	return ref Tmsg.Attach(i & 16r7fff, i, Styx->NOFID, "inferno", "");
}

mkclunk(i: int): ref Tmsg
{
	return ref Tmsg.Clunk(i & 16r7fff, i);
}

testFids(t: ref T)
{
	fd := exported(t);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000")), tagof Rmsg.Version, "version");
	(ok, ref1, other) := batches(t, fd, 1, MAXFIDS+OVER, mkattach, "too many fids");
	t.asserteq(ok, MAXFIDS, "attaches taken");
	t.asserteq(ref1, OVER, "attaches refused as too many");
	t.asserteq(other, 0, "attaches refused otherwise");
	# the fids there are still work
	r := rpc(t, fd, ref Tmsg.Stat(1, MAXFIDS));
	t.assert(tagof r == tagof Rmsg.Stat, "the last fid taken is usable: " + r.text());
	# ten clunked make room for ten, and no more
	(ok, nil, other) = batches(t, fd, 1, 10, mkclunk, "none");
	t.asserteq(ok, 10, "clunks");
	(ok, ref1, other) = batches(t, fd, MAXFIDS+1000, 12, mkattach, "too many fids");
	t.asserteq(ok, 10, "attaches taken after ten clunks");
	t.asserteq(ref1, 2, "attaches refused after ten clunks");
}

# reads of DIR/slow are received and never answered
slowserver(fio: ref Sys->FileIO)
{
	held: list of Sys->Rread;
	for(;;) alt {
	(nil, nil, nil, rc) := <-fio.read =>
		if(rc != nil)
			held = rc :: held;
	(nil, nil, nil, wc) := <-fio.write =>
		if(wc != nil)
			wc <-= (0, "no");
	}
}

mkread(i: int): ref Tmsg
{
	return ref Tmsg.Read(i, 2, big 0, 16);
}

testRequests(t: ref T)
{
	# the file is in a srv(3) of the test's own, inside what is exported
	sys->create(DIR + "/srv", Sys->OREAD, Sys->DMDIR | 8r777);
	if(sys->bind("#s", DIR + "/srv", Sys->MREPL) < 0)
		t.fatal(sys->sprint("bind #s: %r"));
	fio := sys->file2chan(DIR + "/srv", "slow");
	if(fio == nil)
		t.fatal(sys->sprint("file2chan %s/srv/slow: %r", DIR));
	spawn slowserver(fio);
	fd := exported(t);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000")), tagof Rmsg.Version, "version");
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", "")), tagof Rmsg.Attach, "attach");
	want(t, rpc(t, fd, ref Tmsg.Walk(2, 1, 2, array[] of {"srv", "slow"})), tagof Rmsg.Walk, "walk to slow");
	want(t, rpc(t, fd, ref Tmsg.Open(3, 2, Sys->OREAD)), tagof Rmsg.Open, "open slow");

	# MAXREQS reads that will wait: no reply to any
	ms := array[BATCH] of ref Tmsg;
	for(i := 0; i < MAXREQS; i += BATCH){
		for(j := 0; j < BATCH; j++)
			ms[j] = mkread(10+i+j);
		send(t, fd, ms);
	}
	# the next are refused at once, the first still waiting
	(ok, ref1, other) := batches(t, fd, 10+MAXREQS, OVER, mkread, "too many requests outstanding");
	t.asserteq(ok, 0, "reads past the limit answered");
	t.asserteq(ref1, OVER, "reads past the limit refused as too many");
	t.asserteq(other, 0, "reads past the limit refused otherwise");
	# a flush is still taken: it is how a client makes room
	r := rpc(t, fd, ref Tmsg.Flush(5, 10));
	t.assert(tagof r == tagof Rmsg.Flush, "a flush is answered at the limit: " + r.text());
	fd = nil;

	# that connection gone, another serves
	fd = exported(t);
	want(t, rpc(t, fd, ref Tmsg.Version(Styx->NOTAG, 8216, "9P2000")), tagof Rmsg.Version, "version again");
	want(t, rpc(t, fd, ref Tmsg.Attach(1, 1, Styx->NOFID, "inferno", "")), tagof Rmsg.Attach, "attach again");
	want(t, rpc(t, fd, ref Tmsg.Stat(2, 1)), tagof Rmsg.Stat, "stat again");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || styx == nil){
		sys->fprint(sys->fildes(2), "cannot load testing or styx: %r\n");
		raise "fail:load";
	}
	styx->init();
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	sys->create("/tmp", Sys->OREAD, Sys->DMDIR | 8r777);
	sys->create(DIR, Sys->OREAD, Sys->DMDIR | 8r777);

	run("Fids", testFids);
	run("Requests", testRequests);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
