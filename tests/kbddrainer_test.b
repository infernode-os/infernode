implement KbddrainerTest;

#
# Regression test for INFR-101 — every-other-keystroke drop under -c0.
#
# wmclient (appl/lib/wmclient.b) spawns a "kbddrainer" that discards
# keyboard events on a window's ctxt.kbd until the app subscribes with
# startinput("kbd"), which signals the drainer to stop. That signal is a
# NON-BLOCKING send. If the stop channel is UNBUFFERED and the spawned
# drainer has not yet parked in its alt when the signal fires — common
# under -c0, which has no JIT and schedules the new proc later — the send
# hits its default branch and is LOST. The drainer then keeps running and
# splits ctxt.kbd with the real reader, so each gets every OTHER key
# ("two" typed as "w"). The fix: buffer the stop channel (chan[1]) so the
# signal can't be dropped.
#
# This mirrors wmclient.b's kbddrainer + startinput("kbd") path; it can't
# call them directly because that needs a live window manager. Keep the
# drainer model and the buffered-stop expectation in sync with wmclient.b.
#
# To run: emu tests/kbddrainer_test.dis
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

KbddrainerTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/kbddrainer_test.b";

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
	"*" =>
		t.failed = 1;
	}

	if(testing->done(t))
		passed++;
	else if(t.skipped)
		skipped++;
	else
		failed++;
}

# Mirror of wmclient.b's kbddrainer: discard kbd events until stopped.
# The real drainer silently discards; here a consumed key is reported on
# `eaten` so the test can detect a drainer that is still alive (the bug).
mockdrainer(stop: chan of int, kbd: chan of int, done: chan of int, eaten: chan of int)
{
	for(;;) alt {
	<-stop =>
		done <-= 1;
		return;
	c := <-kbd =>
		eaten <-= c;
	}
}

# Deliver one key onto the (unbuffered) ctxt.kbd channel, like the wm.
sender(kbd: chan of int, c: int)
{
	kbd <-= c;
}

# Timeout helper. `ch` is buffered (chan[1]) by the caller so this proc
# always exits even when the test won the race and never reads it — an
# unread blocking send here would keep the proc (and the emu) alive.
after(ms: int, ch: chan of int)
{
	sys->sleep(ms);
	ch <-= 1;
}

testStopNotLostBeforePark(t: ref T)
{
	kbd   := chan of int;		# like ctxt.kbd: unbuffered, wm sends here
	stop  := chan[1] of int;	# THE FIX: buffered so the signal can't be lost
	done  := chan[1] of int;
	eaten := chan[1] of int;

	# Spawn the drainer but do NOT yield first. The non-blocking alt below
	# has a default branch, so this proc never blocks before sending —
	# meaning the drainer has not yet reached its alt (is not parked) when
	# we signal it. That is exactly the -c0 race.
	spawn mockdrainer(stop, kbd, done, eaten);

	sent := 0;
	alt {
	stop <-= 1 =>
		sent = 1;
	* =>
		sent = 0;
	}
	# With a buffered stop this succeeds; with an unbuffered stop (the bug)
	# it would drop to the default and the drainer would survive.
	t.assert(sent, "stop signal accepted though drainer not yet parked (needs buffered chan)");

	# The drainer must now stop on its first alt (it reads the buffered stop).
	tmo := chan[1] of int;
	spawn after(2000, tmo);
	alt {
	<-done =>
		;
	<-tmo =>
		t.fatal("drainer never stopped after the startinput signal");
	}

	# The subscriber now owns ctxt.kbd: a key must reach it, not be eaten
	# by a still-running drainer.
	spawn sender(kbd, 'X');
	tmo2 := chan[1] of int;
	spawn after(2000, tmo2);
	alt {
	c := <-kbd =>
		t.asserteq(c, 'X', "key reaches the subscriber after the drainer stops");
	<-eaten =>
		t.fatal("drainer consumed the key — still running; keyboard would split");
	<-tmo2 =>
		t.fatal("no key delivered to the subscriber");
	}
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

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("StopNotLostBeforePark", testStopNotLostBeforePark);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
