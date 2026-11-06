implement Dictate;

#
# dictate -- what is said, typed where the keyboard types: dictate(1).
#
#	dictate [-w] [-m speechdir] [-o file]
#
# Turns speech(4)'s talk on (with -w, waits for it to be turned on), waits
# for it to be turned off -- by the user: a key, a tap, push to talk --
# and types the words of that utterance's final into file (/dev/keyboard,
# cons(3), so they go to whatever has the keyboard), followed by a space.
# An error from the engine is printed, and nothing typed.
#
# It opens nothing but the speech files and the file it types into, and
# hears one utterance: the one it began.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Dictate: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Finalms: con 60000;	# how long the engine may take, once talk is off

stderr: ref Sys->FD;
listenpid := -1;	# its reader, which would otherwise keep a queue in speech9p

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	speech := "/mnt/speech";
	out := "/dev/keyboard";
	wait := 0;
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sys->sprint("cannot load arg: %r"));
	arg->init(args);
	arg->setusage("dictate [-w] [-m speechdir] [-o file]");
	while((o := arg->opt()) != 0)
		case o {
		'm' =>	speech = arg->earg();
		'o' =>	out = arg->earg();
		'w' =>	wait = 1;
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	talk := sys->open(speech + "/talk", Sys->OREAD);
	if(talk == nil)
		fail(sys->sprint("%s/talk: %r", speech));
	state := readstate(talk);
	if(state == nil)
		fail(sys->sprint("%s/talk: %r", speech));

	# listen's records come to a reader from its first read on: the
	# reader is reading before talk is turned on
	recs := chan[16] of string;
	ready := chan of int;
	spawn listener(speech + "/listen", recs, ready);
	if((listenpid = <-ready) < 0)
		fail(sys->sprint("%s/listen: %r", speech));

	if(!wait){
		if(on(state))
			fail("talk is on already");
		ctl := sys->open(speech + "/talk", Sys->OWRITE);
		if(ctl == nil || sys->fprint(ctl, "start") < 0)
			fail(sys->sprint("talk start: %r"));
		state = "on";
	}
	# until it is on (-w), then until it is off
	while(!on(state))
		if((state = readstate(talk)) == nil)
			fail(sys->sprint("talk: %r"));
	while(on(state))
		if((state = readstate(talk)) == nil)
			fail(sys->sprint("talk: %r"));

	# the utterance's final: the engine gives it at the end
	tick := chan of int;
	spawn timer(tick, Finalms);
	for(;;) alt {
	r := <-recs =>
		if(r == nil)
			fail("listen ended");
		if(prefix("error ", r))
			fail("the engine: " + r[6:]);
		if(prefix("final ", r)){
			kill(listenpid);
			w := words(r);
			if(w == nil)
				return;
			fd := sys->open(out, Sys->OWRITE);
			if(fd == nil)
				fd = sys->create(out, Sys->OWRITE, 8r666);
			if(fd == nil)
				fail(sys->sprint("%s: %r", out));
			b := array of byte (w + " ");
			if(sys->write(fd, b, len b) != len b)
				fail(sys->sprint("%s: %r", out));
			return;
		}
	<-tick =>
		fail("no words from the engine");
	}
}

listener(f: string, recs: chan of string, ready: chan of int)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil){
		ready <-= -1;
		return;
	}
	ready <-= sys->pctl(0, nil);
	buf := array[8192] of byte;
	part := "";
	while((n := sys->read(fd, buf, len buf)) > 0){
		part += string buf[0:n];
		for(;;){
			i := 0;
			while(i < len part && part[i] != '\n')
				i++;
			if(i == len part)
				break;
			recs <-= part[0:i];
			part = part[i+1:];
		}
	}
	recs <-= nil;
}

# talk's state: on or off, then asked while an agent waits
readstate(fd: ref Sys->FD): string
{
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

on(state: string): int
{
	return prefix("on", state);
}

# final confidence=N words: the words
words(r: string): string
{
	(nil, f) := sys->tokenize(r, " ");
	s := "";
	for(f = tl f; f != nil; f = tl f){
		if(s == "" && prefix("confidence=", hd f))
			continue;
		if(s != "")
			s += " ";
		s += hd f;
	}
	return s;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>	;
	* =>	;
	}
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

kill(pid: int)
{
	if(pid < 0)
		return;
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

fail(s: string)
{
	kill(listenpid);
	sys->fprint(stderr, "dictate: %s\n", s);
	raise "fail:" + s;
}
