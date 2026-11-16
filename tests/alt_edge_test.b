implement AltEdgeTest;

#
# alt, and the queues of Progs a channel keeps (libinterp/alt.c, xec.c).
#
# An alt queues its Prog on every channel it names and takes it off them
# all when it is done.  A channel named twice had the Prog twice on its
# queue, and taking it off freed the whole queue: the alt's own next look
# at the channel went through nil, the exception left the Prog queued on
# the alt's other channels, and a value sent on one of those later was
# stored wherever the Prog was then receiving: a big where a pointer
# belongs.  An alt that sent and received on one channel, behind another
# receiver, received from itself.  And a channel whose last reference was
# dropped while a Prog waited on it in an alt faulted inside the
# collector's lock.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "testing.m";
	testing: Testing;
	T: import testing;

AltEdgeTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/alt_edge_test.b";

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

# a channel that works, and that nobody is left waiting on.  With no
# buffer a send or receive that does not block finds nobody; with one, a
# value goes in and comes out and nothing more does.
works(c: chan of int): string
{
	return works1(c, 0);
}

worksbuf(c: chan of int): string
{
	return works1(c, 1);
}

works1(c: chan of int, buffered: int): string
{
	{
		alt {
		c <-= 41 =>
			if(!buffered)
				return "somebody was waiting to receive";
		* =>
			if(buffered)
				return "no room in its buffer";
		}
		alt {
		v := <-c =>
			if(!buffered)
				return "somebody was waiting to send";
			if(v != 41)
				return "another value in its buffer";
		* =>
			if(buffered)
				return "the value sent is not there";
		}
		if(buffered)
			alt {
			<-c =>
				return "more in its buffer";
			* =>
				;
			}
	} exception e {
	"*" =>
		return "raised: " + e;
	}
	return "";
}

twice(c: chan of int, block: int): string
{
	{
		if(block)
			alt {
			x := <-c =>
				return "first " + string x;
			y := <-c =>
				return "second " + string y;
			}
		else
			alt {
			x := <-c =>
				return "first " + string x;
			y := <-c =>
				return "second " + string y;
			* =>
				return "none";
			}
	} exception e {
	"*" =>
		return "raised: " + e;
	}
	return "?";
}

blocker(c: chan of int, res: chan of string)
{
	res <-= twice(c, 1);
}

sendtwice(c: chan of int): string
{
	{
		alt {
		c <-= 1 =>
			return "first";
		c <-= 2 =>
			return "second";
		}
	} exception e {
	"*" =>
		return "raised: " + e;
	}
	return "?";
}

testSameChannelTwice(t: ref T)
{
	# ready
	c := chan[1] of int;
	c <-= 7;
	r := twice(c, 1);
	t.assert(r == "first 7" || r == "second 7", "two receives on a channel with a value: " + r);
	t.assertseq(worksbuf(c), "", "the channel after");

	# nothing ready, not blocking
	u := chan of int;
	t.assertseq(twice(u, 0), "none", "two receives on a channel with nothing, not blocking");
	t.assertseq(works(u), "", "the channel after");

	# as an array
	c <-= 9;
	e := "";
	{
		(i, v) := <-array[2] of {c, c};
		t.assert((i == 0 || i == 1) && v == 9, sys->sprint("an array holding the channel twice: %d from %d", v, i));
	} exception ex {
	"*" =>
		e = ex;
	}
	t.assertseq(e, "", "raised nothing");
	t.assertseq(worksbuf(c), "", "the channel after");

	# two sends
	r = sendtwice(c);
	t.assert(r == "first" || r == "second", "two sends on a channel with room: " + r);
	v := <-c;
	t.assert(v == 1 || v == 2, "and the value sent is there");
	t.assertseq(worksbuf(c), "", "the channel after");

	# blocked, then woken
	res := chan[1] of string;
	spawn blocker(u, res);
	sys->sleep(100);
	u <-= 5;
	r = <-res;
	t.assert(r == "first 5" || r == "second 5", "two receives, blocked and then sent to: " + r);
	t.assertseq(works(u), "", "the channel after");
}

victim(d: chan of big, e: chan of array of byte, ready: chan of string, res: chan of string)
{
	c := chan of int;
	r := "returned";
	{
		alt {
		<-c =>
			;
		<-c =>
			;
		<-d =>
			;
		* =>
			;
		}
	} exception ex {
	"*" =>
		r = "raised: " + ex;
	}
	ready <-= r;
	a := <-e;
	{
		res <-= sys->sprint("received %d bytes", len a);
	} exception ex {
	"*" =>
		res <-= "len raised: " + ex;
	}
}

testNothingLeftQueued(t: ref T)
{
	d := chan of big;
	e := chan of array of byte;
	ready := chan of string;
	res := chan[1] of string;
	spawn victim(d, e, ready, res);
	t.assertseq(<-ready, "returned", "an alt naming a channel twice, and another, with nothing ready");
	sys->sleep(100);
	# the Prog is now receiving on e; it is not on d's queue
	taken := 0;
	alt {
	d <-= big 16r41410000 =>
		taken = 1;
	* =>
		;
	}
	t.assert(!taken, "a send on the alt's other channel finds nobody waiting");
	if(taken){
		sys->sleep(200);
		alt {
		s := <-res =>
			t.log("the Prog receiving on another channel: " + s);
		* =>
			;
		}
		return;
	}
	e <-= array[3] of byte;
	t.assertseq(<-res, "received 3 bytes", "and it receives what is sent to it");
}

waitrecv(c: chan of int, got: chan of int)
{
	got <-= <-c;
}

testSendAndReceive(t: ref T)
{
	nexc := nother := 0;
	why := "";
	for(i := 0; i < 50; i++){
		c := chan of int;
		d := chan[1] of int;
		got := chan[1] of int;
		d <-= 5;
		spawn waitrecv(c, got);
		sys->sleep(5);
		{
			alt {
			c <-= 1 =>
				nother++;
			<-c =>
				nother++;
			<-d =>
				nother++;
			}
		} exception e {
		"*" =>
			if(e == "alt send/recv on same chan")
				nexc++;
			else{
				nother++;
				why = e;
			}
		}
		# the receiver is still there and still served; d has its value
		c <-= 2;
		if(<-got != 2){
			t.error("the receiver behind the alt got something else");
			break;
		}
		w := works(c);
		if(w != ""){
			t.error("the channel after: " + w);
			break;
		}
		alt {
		v := <-d =>
			if(v != 5)
				t.error("d's value changed");
		* =>
			t.error("d's value is gone");
		}
	}
	if(why != "")
		t.log("raised: " + why);
	t.asserteq(nexc, 50, "an alt sending and receiving on one channel, behind another receiver, is refused each time");
	t.asserteq(nother, 0, "and does nothing else");
}

gc: chan of int;
gd: chan of int;

hangwaiter(done: chan of string)
{
	{
		alt {
		x := <-gc =>
			done <-= sys->sprint("got %d on gc", x);
		y := <-gd =>
			done <-= sys->sprint("got %d on gd", y);
		}
	} exception e {
	"*" =>
		done <-= "raised: " + e;
	}
}

testChannelFreedUnderAlt(t: ref T)
{
	gc = chan of int;
	gd = chan of int;
	done := chan[1] of string;
	spawn hangwaiter(done);
	sys->sleep(100);
	e := "";
	{
		gc = nil;	# the last reference: the alt's table counts none
	} exception ex {
	"*" =>
		e = ex;
	}
	t.assertseq(e, "", "dropping a channel a Prog waits on in an alt raises nothing");
	sys->sleep(100);
	s := "still blocked";
	alt {
	s = <-done =>
		;
	* =>
		;
	}
	t.assertseq(s, "raised: alt channel hungup", "the Prog waiting is told");
	t.assertseq(works(gd), "", "and is not left on the alt's other channel");
	gd = nil;

	# and the collector still runs: blocks only it frees come back
	for(round := 0; round < 3; round++){
		c1 := chan of int;
		c2 := chan of int;
		gc = c1;
		gd = c2;
		spawn hangwaiter(done);
		sys->sleep(20);
		c1 = nil;
		gc = nil;
		sys->sleep(20);
		alt {
		s = <-done =>
			;
		* =>
			s = "still blocked";
		}
		if(s != "raised: alt channel hungup"){
			t.error(sys->sprint("round %d: %s", round, s));
			break;
		}
		gd = nil;
	}
}

manyrecv(a: array of chan of int, res: chan of string)
{
	{
		(i, v) := <-a;
		res <-= sys->sprint("%d %d", i >= 0 && i < len a, v);
	} exception e {
	"*" =>
		res <-= "raised: " + e;
	}
}

testManyOfOne(t: ref T)
{
	N: con 200000;
	c := chan of int;
	a := array[N] of {* => c};
	res := chan[1] of string;
	t0 := sys->millisec();
	spawn manyrecv(a, res);
	sys->sleep(50);
	c <-= 3;
	t.assertseq(<-res, "1 3", sys->sprint("a receive on an array holding one channel %d times", N));
	dt := sys->millisec() - t0;
	t.log(sys->sprint("%d ms", dt));
	t.assert(dt < 5000, "in time (it was the square of the length, holding the VM)");
	t.assertseq(works(c), "", "the channel after");
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

	run("SameChannelTwice", testSameChannelTwice);
	run("NothingLeftQueued", testNothingLeftQueued);
	run("SendAndReceive", testSendAndReceive);
	run("ChannelFreedUnderAlt", testChannelFreedUnderAlt);
	run("ManyOfOne", testManyOfOne);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
