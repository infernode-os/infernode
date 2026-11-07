implement KeyboardsTest;

#
# The files a keyboard on the screen is built on, cons(3) and
# pointer(3): /dev/keyboards lists the keyboards attached and which
# kind typed last, its first read at once and each later one waiting
# for a change (an attach, a detach, typing gone from one kind to the
# other) and not woken by typing on the same kind; /dev/kbdin's keys
# are marked a screen keyboard's, /dev/keyboard's the machine's;
# /dev/fingers gives each finger's events to its one reader, and drops
# them while it has none.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

KeyboardsTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyboards_test.b";

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

readall(fd: ref Sys->FD): string
{
	buf := array[4096] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

# a read of fd, sent on c (nil if it failed)
reader(fd: ref Sys->FD, c: chan of string)
{
	c <-= readall(fd);
}

# what arrives on c within ms, or nil
within(c: chan of string, ms: int): (int, string)
{
	t := chan of int;
	spawn sleeper(t, ms);
	alt {
	s := <-c =>
		return (1, s);
	<-t =>
		return (0, nil);
	}
}

sleeper(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt { c <-= 1 => ; * => ; }
}

ctl(t: ref T, s: string)
{
	fd := sys->open("/dev/consctl", Sys->OWRITE);
	if(fd == nil)
		t.fatal(sys->sprint("consctl: %r"));
	if(sys->fprint(fd, "%s", s) < 0)
		t.fatal(sys->sprint("consctl %q: %r", s));
}

has(s, line: string): int
{
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l)
		if(hd l == line)
			return 1;
	return 0;
}

last(s: string): string
{
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l){
		(n, f) := sys->tokenize(hd l, " ");
		if(n == 2 && hd f == "last")
			return hd tl f;
	}
	return nil;
}

testKeyboards(t: ref T)
{
	fd := sys->open("/dev/keyboards", Sys->OREAD);
	if(fd == nil)
		t.skip(sys->sprint("no /dev/keyboards: %r"));
	c := chan of string;
	spawn reader(fd, c);
	(ok, s) := within(c, 2000);
	t.assert(ok && s != nil, "the first read answers at once");
	t.assert(last(s) != nil, "it says which kind typed last: " + s);

	# the next waits, and an attach wakes it
	spawn reader(fd, c);
	(ok, nil) = within(c, 300);
	t.assert(!ok, "the next read waits for a change");
	ctl(t, "kbd attach kt1 Test Keyboard\n");
	(ok, s) = within(c, 2000);
	t.assert(ok, "an attach ends the wait");
	t.assert(has(s, "keyboard kt1 Test Keyboard"), "the keyboard attached is listed: " + s);

	# a screen keyboard's key: last soft
	spawn reader(fd, c);
	kfd := sys->open("/dev/kbdin", Sys->OWRITE);
	if(kfd == nil)
		t.fatal(sys->sprint("kbdin: %r"));
	sys->fprint(kfd, "x");
	(ok, s) = within(c, 2000);
	t.assert(ok && last(s) == "soft", "a key through kbdin is a screen keyboard's: " + s);
	# more of the same kind wakes nobody
	spawn reader(fd, c);
	sys->fprint(kfd, "yz");
	(ok, nil) = within(c, 400);
	t.assert(!ok, "typing on the same kind does not end the wait");
	# a machine's key: last hard
	hfd := sys->open("/dev/keyboard", Sys->OWRITE);
	sys->fprint(hfd, "h");
	(ok, s) = within(c, 2000);
	t.assert(ok && last(s) == "hard", "a key through keyboard is the machine's: " + s);

	# a second attach of an id renames it; a detach takes it out
	spawn reader(fd, c);
	ctl(t, "kbd attach kt1 Renamed\n");
	(ok, s) = within(c, 2000);
	t.assert(ok && has(s, "keyboard kt1 Renamed") && !has(s, "keyboard kt1 Test Keyboard"), "attached again: renamed: " + s);
	spawn reader(fd, c);
	ctl(t, "kbd detach kt1\n");
	(ok, s) = within(c, 2000);
	t.assert(ok && !has(s, "keyboard kt1 Renamed"), "a detach takes it out: " + s);
	cfd := sys->open("/dev/consctl", Sys->OWRITE);
	t.assert(sys->fprint(cfd, "kbd attach \n") < 0, "an attach with no id is refused");
	# drain what was typed, for whatever reads the keyboard next
	fd = nil;
}

testFingers(t: ref T)
{
	r := sys->open("/dev/fingers", Sys->OREAD);
	if(r == nil)
		t.skip(sys->sprint("no /dev/fingers: %r"));
	t.assert(sys->open("/dev/fingers", Sys->OREAD) == nil, "one reader at a time");
	w := sys->open("/dev/fingers", Sys->OWRITE);
	t.assert(w != nil, "a writer beside the reader");
	c := chan of string;
	sys->fprint(w, "f3 10 20 1");
	sys->fprint(w, "f3 15 25 1");
	sys->fprint(w, "f3 15 25 0");
	exp := array[] of {"3 10 20 1", "3 15 25 1", "3 15 25 0"};
	for(i := 0; i < len exp; i++){
		spawn reader(r, c);
		(ok, s) := within(c, 2000);
		(n, f) := sys->tokenize(s, " f");
		got := "";
		for(j := 0; j < 4 && f != nil; j++){
			got += hd f;
			if(j < 3)
				got += " ";
			f = tl f;
		}
		t.assert(ok && n == 5, "an event a read, five fields: " + s);
		t.assertseq(got, exp[i], "the events in the order written");
	}
	t.assert(sys->fprint(w, "x1 2 3 1") < 0, "an event not beginning f is refused");
	# with no reader, an event is dropped, not kept, and a write does not wait
	r = nil;
	for(i = 0; i < 200; i++)
		sys->fprint(w, "f1 1 1 1");
	r = sys->open("/dev/fingers", Sys->OREAD);
	spawn reader(r, c);
	(ok, nil) := within(c, 300);
	t.assert(!ok, "what was written with no reader is gone");
	sys->fprint(w, "f2 5 6 0");
	(ok, nil) = within(c, 2000);
	t.assert(ok, "and the next event is read");
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "keyboards_test: cannot load testing: %r\n");
		raise "fail:cannot load testing";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);
	run("Keyboards", testKeyboards);
	run("Fingers", testFingers);
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
