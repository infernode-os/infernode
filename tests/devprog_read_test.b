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

testFdShortReads(t: ref T)
{
	# fds enough for lines of their own
	keep := array[8] of ref Sys->FD;
	for(i := 0; i < len keep; i++)
		keep[i] = sys->open("/dev/null", Sys->OREAD);
	p := sys->sprint("/prog/%d/fd", sys->pctl(0, nil));
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		t.fatal(sys->sprint("open %s: %r", p));
	# through the same fd as the reads below: another open is another line
	all := "";
	buf := array[65536] of byte;
	for(o := big 0; (m := sys->pread(fd, buf, len buf, o)) > 0; o += big m)
		all += string buf[0:m];
	t.assert(len all > 0, "the fd file reads");
	for(n := 0; n <= 3; n++){
		(r, nil, ok) := guarded(fd, n, big 0);
		t.assert(ok, sys->sprint("a read of %d bytes writes only its buffer", n));
		t.assert(r <= n, sys->sprint("a read of %d bytes gives no more (%d)", n, r));
	}
	# a byte at a time, at each offset, is the file
	s := "";
	for(off := 0; off < len array of byte all + 4; off++){
		(r, b, ok) := guarded(fd, 1, big off);
		if(!ok){
			t.error(sys->sprint("a 1-byte read at %d wrote outside its buffer", off));
			break;
		}
		if(r <= 0)
			break;
		s += string b;
	}
	# less the line of the fd read through: its offset moves as it is read
	t.assertseq(notline(s, p), notline(all, p), "read a byte at a time");
	keep = nil;
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
