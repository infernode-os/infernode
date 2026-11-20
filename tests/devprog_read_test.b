implement DevprogReadTest;

#
# devprog_read_test - a Prog's fd and ns files read with short buffers
# and at offsets give what one read of the whole gives, and nothing is
# written outside the reader's buffer.
#
# fd and ns were made in the reader's buffer, adding up snprint's
# counts; with no room left snprint gives -1, so a read too short for a
# line moved the count back and the next line was written before the
# buffer: over the heap in emu, a nil write and the native kernel's
# panic (tools/nativefuzz, sysfuzz reading /prog with buffers of 0 and 1
# byte).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

DevprogReadTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/devprog_read_test.b";

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

Guard: con 64;

# a read of n bytes into the middle of a guarded array: what it read,
# and whether the guards are as they were
guarded(fd: ref Sys->FD, n: int, off: big): (int, array of byte, int)
{
	a := array[Guard + n + Guard] of {* => byte 16rA5};
	r := sys->pread(fd, a[Guard:Guard+n], n, off);
	ok := 1;
	for(i := 0; i < Guard; i++)
		if(a[i] != byte 16rA5 || a[Guard+n+i] != byte 16rA5)
			ok = 0;
	if(r < 0)
		return (r, nil, ok);
	return (r, a[Guard:Guard+r], ok);
}

whole(p: string): string
{
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	b := array[65536] of byte;
	off := big 0;
	while((n := sys->pread(fd, b, len b, off)) > 0){
		s += string b[0:n];
		off += big n;
	}
	return s;
}

# What a child with an fd table of its own read of its fd file: the
# whole file in one read, the same a byte at a time, and the faults seen.
Fdread: adt {
	all:	string;
	bytes:	string;
	p:	string;
	errs:	list of string;
};

# The fd table is the child's alone (NEWFD with nothing kept): the
# runner's table is shared with the tests running beside this one, whose
# files' offsets moved between the two reads (macOS ARM64 CI, a TCP
# connection's and the console's).
fdreader(c: chan of ref Fdread)
{
	r := ref Fdread(nil, nil, nil, nil);
	sys->pctl(Sys->NEWFD, nil);
	# fds enough for lines of their own
	keep := array[8] of ref Sys->FD;
	for(i := 0; i < len keep; i++)
		keep[i] = sys->open("/dev/null", Sys->OREAD);
	r.p = sys->sprint("/prog/%d/fd", sys->pctl(0, nil));
	fd := sys->open(r.p, Sys->OREAD);
	if(fd == nil){
		r.errs = sys->sprint("open %s: %r", r.p) :: nil;
		c <-= r;
		return;
	}
	# through the same fd as the reads below: another open is another line
	buf := array[65536] of byte;
	for(o := big 0; (m := sys->pread(fd, buf, len buf, o)) > 0; o += big m)
		r.all += string buf[0:m];
	for(n := 0; n <= 3; n++){
		(k, nil, ok) := guarded(fd, n, big 0);
		if(!ok)
			r.errs = sys->sprint("a read of %d bytes wrote outside its buffer", n) :: r.errs;
		if(k > n)
			r.errs = sys->sprint("a read of %d bytes gave %d", n, k) :: r.errs;
	}
	# a byte at a time, at each offset, is the file
	for(off := 0; off < len array of byte r.all + 4; off++){
		(k, b, ok) := guarded(fd, 1, big off);
		if(!ok){
			r.errs = sys->sprint("a 1-byte read at %d wrote outside its buffer", off) :: r.errs;
			break;
		}
		if(k <= 0)
			break;
		r.bytes += string b;
	}
	keep = nil;
	c <-= r;
}

testFdShortReads(t: ref T)
{
	c := chan of ref Fdread;
	spawn fdreader(c);
	r := <-c;
	for(e := r.errs; e != nil; e = tl e)
		t.error(hd e);
	if(r.all == nil)
		t.fatal("the fd file read nothing");
	# less the line of the fd read through: its offset moves as it is read
	t.assertseq(notline(r.bytes, r.p), notline(r.all, r.p), "read a byte at a time");
}

notline(s, p: string): string
{
	r := "";
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l){
		x := hd l;
		if(len x >= len p && x[len x - len p:] == p)
			continue;
		r += x + "\n";
	}
	return r;
}

testNsShortReads(t: ref T)
{
	p := sys->sprint("/prog/%d/ns", sys->pctl(0, nil));
	for(n := 0; n <= 4; n++){
		fd := sys->open(p, Sys->OREAD);
		if(fd == nil)
			t.fatal(sys->sprint("open %s: %r", p));
		for(k := 0; k < 400; k++){
			(r, nil, ok) := guarded(fd, n, big 0);
			if(!ok){
				t.error(sys->sprint("a read of %d bytes of ns wrote outside its buffer", n));
				break;
			}
			if(r > n){
				t.error(sys->sprint("a read of %d bytes of ns gave %d", n, r));
				break;
			}
			if(r <= 0 && n > 0)
				break;
		}
	}
	# and whole, it ends in its cd line
	all := whole(p);
	t.assert(len all > 3, "ns reads");
	(nil, l) := sys->tokenize(all, "\n");
	last := "";
	for(; l != nil; l = tl l)
		last = hd l;
	t.assert(len last >= 3 && last[0:3] == "cd ", "ns ends with cd: " + last);
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

	run("FdShortReads", testFdShortReads);
	run("NsShortReads", testNsShortReads);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
