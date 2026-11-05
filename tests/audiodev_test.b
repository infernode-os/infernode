implement AudiodevTest;

#
# The shared audio device (#A, emu/port/devaudio.c) through its files,
# with the emulator's fake hardware ($INFERNODE_AUDIO_FAKE: what the
# speaker plays read back from #A/fakeout, the microphone written to
# #A/fakein), so what is heard is checked, not only what was written:
#
#	streams from #A/mix/new listed while open and gone when closed;
#	two streams of different formats mixed, each heard at its own
#	frequency and level, not interleaved; two writers of #A/audio
#	mixed the same way; media ducked under speech and back after;
#	the microphone heard whole by two readers in two formats, not
#	split between them; a writer with no queue paced by the speaker,
#	one with a queue never waiting and only its newest kept; what is
#	written before a close played to its end; ctl read back, a bad
#	role or rate refused and changing nothing.
#
# Skips without the fake (tests/host/audiodev_test.sh runs it with it).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "string.m";
	str: String;
include "testing.m";
	testing: Testing;
	T: import testing;

AudiodevTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/audiodev_test.b";
Mixrate: con 48000;

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

# A stream from #A/new: its ctl fid and its number.
newstream(t: ref T): (ref Sys->FD, string)
{
	fd := sys->open("#A/mix/new", Sys->ORDWR);
	if(fd == nil)
		t.fatal(sys->sprint("open #A/mix/new: %r"));
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		t.fatal(sys->sprint("read new: %r"));
	(nil, l) := sys->tokenize(string buf[0:n], " \n");
	return (fd, hd l);
}

ctl(t: ref T, fd: ref Sys->FD, s: string)
{
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("ctl %q: %r", s));
}

# secs of a tone, little-endian 16-bit, chans channels
tone(rate, chans: int, hz, amp, secs: real): array of byte
{
	n := int (real rate * secs);
	b := array[n * chans * 2] of byte;
	for(i := 0; i < n; i++){
		v := int (amp * math->sin(2.0 * Math->Pi * hz * real i / real rate));
		for(c := 0; c < chans; c++){
			k := (i * chans + c) * 2;
			b[k] = byte v;
			b[k+1] = byte (v >> 8);
		}
	}
	return b;
}

# what the speaker has played since the last call, as left-channel samples
heard(): array of real
{
	fd := sys->open("#A/fakeout", Sys->OREAD);
	all := array[0] of byte;
	buf := array[65536] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0){
		nb := array[len all + n] of byte;
		nb[0:] = all;
		nb[len all:] = buf[0:n];
		all = nb;
	}
	return left(all, 2);
}

left(b: array of byte, chans: int): array of real
{
	n := len b / (2 * chans);
	s := array[n] of real;
	for(i := 0; i < n; i++){
		k := i * chans * 2;
		v := int b[k] | (int b[k+1] << 8);
		if(v >= 32768)
			v -= 65536;
		s[i] = real v;
	}
	return s;
}

# the amplitude of hz in s[a:b], by Goertzel
level(s: array of real, a, b, rate: int, hz: real): real
{
	if(b > len s)
		b = len s;
	if(a < 0)
		a = 0;
	n := b - a;
	if(n <= 0)
		return 0.0;
	k := 2.0 * math->cos(2.0 * Math->Pi * hz / real rate);
	s1 := 0.0;
	s2 := 0.0;
	for(i := a; i < b; i++){
		s0 := s[i] + k * s1 - s2;
		s2 = s1;
		s1 = s0;
	}
	p := s1*s1 + s2*s2 - k*s1*s2;
	if(p < 0.0)
		p = 0.0;
	return 2.0 * math->sqrt(p) / real n;
}

# the first sample louder than quiet, or -1
onset(s: array of real, quiet: real): int
{
	for(i := 0; i < len s; i++)
		if(s[i] > quiet || s[i] < -quiet)
			return i;
	return -1;
}

near(got, want, tol: real): int
{
	return got >= want - tol && got <= want + tol;
}

writeall(t: ref T, fd: ref Sys->FD, b: array of byte)
{
	if(sys->write(fd, b, len b) != len b)
		t.fatal(sys->sprint("write: %r"));
}

# n bytes from fd, or what came before ms passed: a reader the device
# never answers fails its check rather than hanging the test
readall(fd: ref Sys->FD, n: int): array of byte
{
	return readfor(fd, n, 3000);
}

readfor(fd: ref Sys->FD, n, ms: int): array of byte
{
	c := chan of array of byte;
	pidc := chan of int;
	spawn reader(fd, n, c, pidc);
	pid := <-pidc;
	tc := chan of int;
	spawn timer(ms, tc);
	b := array[0] of byte;
	for(;;) alt {
	d := <-c =>
		if(d == nil)
			return b;
		nb := array[len b + len d] of byte;
		nb[0:] = b;
		nb[len b:] = d;
		b = nb;
		if(len b >= n)
			return b;
	<-tc =>
		kill(pid);
		return b;
	}
}

reader(fd: ref Sys->FD, n: int, c: chan of array of byte, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[n] of byte;
	got := 0;
	while(got < n){
		k := sys->read(fd, buf, n - got);
		if(k <= 0)
			break;
		c <-= buf[0:k];
		buf = array[n] of byte;
		got += k;
	}
	alt {
	c <-= nil =>	# no one may be waiting: readfor returns at n bytes
		;
	* =>
		;
	}
}

timer(ms: int, c: chan of int)
{
	sys->sleep(ms);
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

dirnames(d: string): list of string
{
	fd := sys->open(d, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of string;
	for(;;){
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++)
			l = dirs[i].name :: l;
	}
	return l;
}

has(l: list of string, s: string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

testFiles(t: ref T)
{
	l := dirnames("#A");
	for(f := "audio" :: "audioctl" :: "mix" :: "fakein" :: "fakeout" :: nil; f != nil; f = tl f)
		t.assert(has(l, hd f), "#A has " + hd f);
	t.assert(!has(l, "new"), "no new beside audio: #A is bound onto /dev");
	t.assert(has(dirnames("#A/mix"), "new"), "#A/mix has new");
	(fd, id) := newstream(t);
	t.assert(has(dirnames("#A/mix"), id), "a stream from new is listed while open: " + id);
	t.assert(!has(dirnames("#A"), id), "and not beside audio");
	l = dirnames("#A/mix/" + id);
	t.assert(has(l, "data") && has(l, "ctl"), "its directory holds data and ctl");
	fd = nil;
	sys->sleep(200);	# freed by the mixer
	t.assert(!has(dirnames("#A/mix"), id), "a closed stream is gone");
}

testCtl(t: ref T)
{
	(fd, id) := newstream(t);
	ctl(t, fd, "out rate 16000 chans 1 bits 16 role speech queue 200");
	c := sys->open("#A/mix/" + id + "/ctl", Sys->OREAD);
	b := array[1024] of byte;
	n := sys->read(c, b, len b);
	s := string b[0:n];
	t.log(s);
	t.assert(str->prefix(id + "\n", s), "ctl begins with the stream's number");
	t.assert(contains(s, "role speech"), "role read back");
	t.assert(contains(s, "out queue 200") && contains(s, "in queue 0"),
		"out before a line's queue applies it to the output only, as to its format");
	ctl(t, fd, "queue 150");
	sys->seek(c, big 0, Sys->SEEKSTART);
	n = sys->read(c, b, len b);
	s = string b[0:n];
	t.assert(contains(s, "out queue 150") && contains(s, "in queue 150"), "queue alone sets both ways");
	t.assert(contains(s, "out rate 16000 chans 1 bits 16 enc pcm"), "out format read back");
	t.assert(sys->write(fd, array of byte "role shouting", 13) < 0, "a role that is none refused");
	t.assert(sys->write(fd, array of byte "out rate 12345", 14) < 0, "a rate that is none refused");
	t.assert(sys->write(fd, array of byte "role call rate 7", 16) < 0, "a line with a bad part refused");
	sys->seek(c, big 0, Sys->SEEKSTART);
	n = sys->read(c, b, len b);
	s = string b[0:n];
	t.assert(contains(s, "role speech") && contains(s, "out rate 16000"), "a refused line changes nothing");
	ctl(t, fd, "in rate 8000 chans 1");
	sys->seek(c, big 0, Sys->SEEKSTART);
	n = sys->read(c, b, len b);
	s = string b[0:n];
	t.assert(contains(s, "in rate 8000 chans 1") && contains(s, "out rate 16000 chans 1"),
		"in before a line's settings applies to all of them, as audioctl's");
}

contains(s, t: string): int
{
	for(i := 0; i + len t <= len s; i++)
		if(s[i:i+len t] == t)
			return 1;
	return 0;
}

# two streams of different formats, written at once: each heard, mixed
testMix(t: ref T)
{
	heard();
	(c1, id1) := newstream(t);
	(c2, id2) := newstream(t);
	ctl(t, c1, "out rate 48000 chans 2 bits 16 role tone");
	ctl(t, c2, "out rate 16000 chans 1 bits 16 role tone");
	d1 := sys->open("#A/mix/" + id1 + "/data", Sys->OWRITE);
	d2 := sys->open("#A/mix/" + id2 + "/data", Sys->OWRITE);
	if(d1 == nil || d2 == nil)
		t.fatal(sys->sprint("open data: %r"));
	done := chan of int;
	spawn writer(d1, tone(48000, 2, 1000.0, 6000.0, 0.5), done);
	spawn writer(d2, tone(16000, 1, 440.0, 6000.0, 0.5), done);
	<-done;
	<-done;
	d1 = d2 = nil;
	sys->sleep(500);
	s := heard();
	a := onset(s, 300.0);
	t.assert(a >= 0, "something was played");
	mid := a + Mixrate / 4;
	l1 := level(s, mid - 2400, mid + 2400, Mixrate, 1000.0);
	l2 := level(s, mid - 2400, mid + 2400, Mixrate, 440.0);
	t.log(sys->sprint("1000 Hz %.0f, 440 Hz %.0f, %d samples", l1, l2, len s));
	t.assert(near(l1, 6000.0, 600.0), sys->sprint("the 48 kHz stereo stream heard at its level: %.0f", l1));
	t.assert(near(l2, 6000.0, 600.0), sys->sprint("the 16 kHz mono stream heard at its level: %.0f", l2));
	played := len s - a;
	t.assert(played >= Mixrate * 45 / 100 && played <= Mixrate * 70 / 100,
		sys->sprint("half a second of each is half a second played, mixed: %d samples", played));
}

writer(fd: ref Sys->FD, b: array of byte, done: chan of int)
{
	sys->write(fd, b, len b);
	done <-= 1;
}

# two opens of #A/audio are two streams, mixed, not interleaved
testLegacy(t: ref T)
{
	heard();
	c := sys->open("#A/audioctl", Sys->OWRITE);
	ctl(t, c, "out rate 8000 chans 1 bits 16 enc pcm");
	a1 := sys->open("#A/audio", Sys->OWRITE);
	a2 := sys->open("#A/audio", Sys->OWRITE);
	if(a1 == nil || a2 == nil)
		t.fatal(sys->sprint("open #A/audio: %r"));
	done := chan of int;
	spawn writer(a1, tone(8000, 1, 300.0, 5000.0, 0.4), done);
	spawn writer(a2, tone(8000, 1, 700.0, 5000.0, 0.4), done);
	<-done;
	<-done;
	a1 = a2 = nil;
	sys->sleep(400);
	s := heard();
	a := onset(s, 300.0);
	mid := a + Mixrate / 5;
	l1 := level(s, mid - 2400, mid + 2400, Mixrate, 300.0);
	l2 := level(s, mid - 2400, mid + 2400, Mixrate, 700.0);
	t.assert(near(l1, 5000.0, 600.0) && near(l2, 5000.0, 600.0),
		sys->sprint("two writers of #A/audio both heard whole: %.0f %.0f", l1, l2));
	played := len s - a;
	t.assert(played <= Mixrate * 55 / 100, sys->sprint("at once, not one after the other: %d samples", played));
	ctl(t, c, "out rate 8000 chans 2 bits 16 enc pcm");
}

# media under speech: a quarter while speech sounds, whole again after
testDuck(t: ref T)
{
	heard();
	(cm, idm) := newstream(t);
	(cs, ids) := newstream(t);
	ctl(t, cm, "out rate 48000 chans 1 role media");
	ctl(t, cs, "out rate 48000 chans 1 role speech");
	dm := sys->open("#A/mix/" + idm + "/data", Sys->OWRITE);
	ds := sys->open("#A/mix/" + ids + "/data", Sys->OWRITE);
	done := chan of int;
	spawn writer(dm, tone(48000, 1, 1000.0, 8000.0, 1.0), done);
	sys->sleep(250);
	spawn writer(ds, tone(48000, 1, 440.0, 8000.0, 0.3), done);
	<-done;
	<-done;
	dm = ds = nil;
	sys->sleep(500);
	s := heard();
	sp := onset440(s);
	t.assert(sp > 0, "the speech was heard");
	during := level(s, sp + 4800, sp + 9600, Mixrate, 1000.0);
	after := level(s, sp + Mixrate*45/100, sp + Mixrate*55/100, Mixrate, 1000.0);
	before := level(s, sp - 7200, sp - 2400, Mixrate, 1000.0);
	t.log(sys->sprint("media before %.0f, during speech %.0f, after %.0f", before, during, after));
	t.assert(near(before, 8000.0, 800.0), "media whole before the speech");
	t.assert(near(during, 2000.0, 400.0), sys->sprint("media at a quarter under speech: %.0f", during));
	t.assert(near(after, 8000.0, 800.0), sys->sprint("media whole again after it: %.0f", after));
	t.assert(near(level(s, sp + 4800, sp + 9600, Mixrate, 440.0), 8000.0, 800.0), "the speech itself not ducked");
}

# where the 440 Hz speech begins: the first 10 ms block where it is loud
onset440(s: array of real): int
{
	for(a := 0; a + 480 <= len s; a += 240)
		if(level(s, a, a + 480, Mixrate, 440.0) > 2000.0)
			return a;
	return -1;
}

# the microphone, whole, to two readers in two formats
testFanout(t: ref T)
{
	(c1, id1) := newstream(t);
	ctl(t, c1, "in rate 16000 chans 1 bits 16");
	r1 := sys->open("#A/mix/" + id1 + "/data", Sys->OREAD);
	ac := sys->open("#A/audioctl", Sys->OWRITE);
	ctl(t, ac, "in rate 8000 chans 2 bits 16 enc pcm");
	r2 := sys->open("#A/audio", Sys->OREAD);
	if(r1 == nil || r2 == nil)
		t.fatal(sys->sprint("open readers: %r"));
	sys->sleep(100);
	mic := sys->open("#A/fakein", Sys->OWRITE);
	writeall(t, mic, tone(48000, 2, 700.0, 7000.0, 0.4));
	b1 := readall(r1, 16000 * 2 * 6 / 10);	# 0.6 s of 16 kHz mono
	b2 := readall(r2, 8000 * 4 * 6 / 10);	# 0.6 s of 8 kHz stereo
	s1 := left(b1, 1);
	s2 := left(b2, 2);
	a1 := onset(s1, 300.0);
	a2 := onset(s2, 300.0);
	t.assert(a1 >= 0 && a2 >= 0, "both readers heard the microphone");
	l1 := level(s1, a1 + 1600, a1 + 4800, 16000, 700.0);
	l2 := level(s2, a2 + 800, a2 + 2400, 8000, 700.0);
	t.log(sys->sprint("16 kHz reader %.0f, 8 kHz reader %.0f", l1, l2));
	t.assert(near(l1, 7000.0, 700.0), sys->sprint("the 16 kHz mono reader heard it whole: %.0f", l1));
	t.assert(near(l2, 7000.0, 700.0), sys->sprint("the 8 kHz stereo reader heard it whole: %.0f", l2));
	# all of it, not shared out: 0.4 s each
	n1 := 0;
	for(i := a1; i < len s1; i++)
		if(s1[i] > 300.0 || s1[i] < -300.0)
			n1 = i;
	t.assert(n1 - a1 >= 16000 * 35 / 100, sys->sprint("the first reader got all 0.4 s: %d samples", n1 - a1));
	ctl(t, ac, "in rate 8000 chans 2 bits 16 enc pcm");
}

# a writer with no queue waits for the speaker; with one it never waits
testPace(t: ref T)
{
	heard();
	(c, id) := newstream(t);
	ctl(t, c, "out rate 48000 chans 2 bits 16");
	d := sys->open("#A/mix/" + id + "/data", Sys->OWRITE);
	b := tone(48000, 2, 500.0, 3000.0, 3.0);
	t0 := sys->millisec();
	writeall(t, d, b);
	took := sys->millisec() - t0;
	t.assert(took >= 700, sys->sprint("3 s with no queue waited for room (2 s held): %d ms", took));
	d = nil;
	sys->sleep(3000);
	heard();

	(cq, idq) := newstream(t);
	ctl(t, cq, "out rate 48000 chans 2 bits 16 queue 100");
	dq := sys->open("#A/mix/" + idq + "/data", Sys->OWRITE);
	t0 = sys->millisec();
	writeall(t, dq, b);
	took = sys->millisec() - t0;
	t.assert(took < 300, sys->sprint("with a queue of 100 ms the write did not wait: %d ms", took));
	dq = nil;
	sys->sleep(600);
	s := heard();
	a := onset(s, 300.0);
	played := len s - a;
	t.assert(a >= 0 && played <= Mixrate * 25 / 100, sys->sprint("only the newest 100 ms were kept: %d samples played", played));
}

# what is written before a close is played to its end
testDrain(t: ref T)
{
	heard();
	(c, id) := newstream(t);
	ctl(t, c, "out rate 48000 chans 2 bits 16");
	d := sys->open("#A/mix/" + id + "/data", Sys->OWRITE);
	writeall(t, d, tone(48000, 2, 600.0, 5000.0, 0.6));
	d = nil;
	c = nil;
	sys->sleep(1200);
	s := heard();
	a := onset(s, 300.0);
	z := 0;
	for(i := 0; i < len s; i++)
		if(s[i] > 300.0 || s[i] < -300.0)
			z = i;
	t.assert(a >= 0 && z - a >= Mixrate * 55 / 100, sys->sprint("0.6 s written and closed at once all played: %d samples", z - a));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	str = load String String->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil || math == nil || str == nil){
		sys->fprint(sys->fildes(2), "cannot load modules: %r\n");
		raise "fail:load";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	(ok, nil) := sys->stat("#A/fakeout");
	if(ok < 0){
		t := testing->newTsrc("Audiodev", SRCFILE);
		{
			t.skip("no fake audio hardware ($INFERNODE_AUDIO_FAKE; tests/host/audiodev_test.sh)");
		} exception {
		* =>
			;
		}
		testing->done(t);
		skipped++;
	}else{
		run("Files", testFiles);
		run("Ctl", testCtl);
		run("Mix", testMix);
		run("Legacy", testLegacy);
		run("Duck", testDuck);
		run("Fanout", testFanout);
		run("Pace", testPace);
		run("Drain", testDrain);
	}
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
