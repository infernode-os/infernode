implement LimboStaleTest;

#
# Code the compiler generated kept an address inside a heap object
# across something that can free the object, and then read or wrote
# through it: freed memory, or whatever had been allocated there since.
#
# Across a block.  "g.n = <-c" was "recv c, 8(0(mp))": the receive found
# the address of the field when it started and kept it while it waited
# for a sender; another thread dropped g meanwhile, and the value was
# written where the object had been.  A send kept the address of its
# value so ("c <-= g.n"), an alt kept both in its table, a receive from
# an array of channels too, and a load, which lets other threads run
# while it reads the file, the address the module goes to.
#
# In one thread.  The address of an array's element (indx) or of a field
# reached through a temporary was found, then code was run that can free
# the array or the object, then the address was used: "f() - a[i][j]",
# "a[i][f()]", "a[f()] += b[i][j]", "a[i] :: f()", comparisons, string
# indexing, slices and their assignment, "s[i] = f()" on a string in an
# array, "mods[i]->f(g())", "ga = array[] of {f()}", "c[i] <-= f()",
# "case f()[i]" (the array let go before the case read it), and with no
# call at all "a[0] = len (a = b)".  A call through a function reference
# read the function's index before the arguments were made and its
# module after.
#
# Now a receive, a load and a call's result go to the frame and are
# moved from there, a value to send is taken to the frame first, and
# where code that can free memory runs between an address and its use
# the value is taken instead, or that code is run first.
#
# Each case frees the object as the old code needed, allocates objects
# of the same size after it, completes the operation and checks that
# none of them changed and that the result is what the language says.
# The compiler in Limbo (/dis/limbo.dis) has the same changes:
# tests/host/limbo_stale_test.sh runs this compiled by it, too.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

LimboStaleTest: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
	setid:	fn(i: int);
	getid:	fn(x: int): int;
	otherid:	fn(x: int): int;
};

SRCFILE: con "/tests/limbo_stale_test.b";

passed := 0;
failed := 0;
skipped := 0;

only: string;	# -t name: that test alone

run(name: string, testfn: ref fn(t: ref T))
{
	if(only != nil && only != name)
		return;
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

# where this module's code is, for a second instance of it (-m path)
selfpath: string;

loadsecond(): LimboStaleTest
{
	if(selfpath != nil)
		return load LimboStaleTest selfpath;
	m := load LimboStaleTest "/dis/tests/limbo_stale_test.dis";
	if(m == nil)
		m = load LimboStaleTest "/tests/limbo_stale_test.dis";
	return m;
}

NF: con 64;		# objects allocated after a free, to take its place
FILL: con 99;
PAT: con big 16r5a5a5a5a5a5a5a5a;
VAL: con big 16r4142434445464748;

#
# across a block
#

H: adt {
	pad:	big;	# the allocator's links lie here in a freed block
	n:	big;
};

K: adt {
	a:	big;
	b:	big;
};

Ht: adt {
	pad:	big;
	t:	(int, big);
};

K3: adt {
	a:	big;
	b:	big;
	c:	big;
};

gh: ref H;
ght: ref Ht;
gb: array of big;
ks: array of ref K;
k3s: array of ref K3;
kb: array of array of big;

fillk()
{
	ks = array[NF] of ref K;
	for(i := 0; i < len ks; i++)
		ks[i] = ref K(PAT, PAT);
}

kchanged(): int
{
	n := 0;
	for(i := 0; i < len ks; i++)
		if(ks[i].a != PAT || ks[i].b != PAT)
			n++;
	return n;
}

fillk3()
{
	k3s = array[NF] of ref K3;
	for(i := 0; i < len k3s; i++)
		k3s[i] = ref K3(PAT, PAT, PAT);
}

k3changed(): int
{
	n := 0;
	for(i := 0; i < len k3s; i++)
		if(k3s[i].a != PAT || k3s[i].b != PAT || k3s[i].c != PAT)
			n++;
	return n;
}

fillkb()
{
	kb = array[NF] of array of big;
	for(i := 0; i < len kb; i++)
		kb[i] = array[2] of {* => PAT};
}

kbchanged(): int
{
	n := 0;
	for(i := 0; i < len kb; i++)
		if(kb[i][0] != PAT || kb[i][1] != PAT)
			n++;
	return n;
}

# wait until a thread is blocked as said
blocked(pid: int, state: string): int
{
	for(i := 0; i < 2000; i++){
		fd := sys->open("/prog/" + string pid + "/status", Sys->OREAD);
		if(fd == nil)
			return 0;
		buf := array[256] of byte;
		n := sys->read(fd, buf, len buf);
		if(n > 0){
			(nil, f) := sys->tokenize(string buf[0:n], " ");
			if(len f >= 5 && hd tl tl tl tl f == state)
				return 1;
		}
		sys->sleep(1);
	}
	return 0;
}

# 0: it went on; 1: it raised; -1: it never came back
ended(done: chan of int): int
{
	tmo := chan of int;
	spawn timer(tmo, 5000);
	alt{
	r := <-done =>
		return r;
	<-tmo =>
		return -1;
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

rcvfield(c: chan of big, ready, done: chan of int)
{
	gh = ref H(big 0, big 0);
	ready <-= sys->pctl(0, nil);
	{
		gh.n = <-c;
		done <-= 0;
	} exception {
	"*" =>
		done <-= 1;
	}
}

testRecvField(t: ref T)
{
	c := chan of big;
	ready := chan of int;
	done := chan of int;
	spawn rcvfield(c, ready, done);
	pid := <-ready;
	t.assert(blocked(pid, "recv"), "the receiver waits");
	gh = ref H(big 0, big 0);	# its object is freed
	fillk();
	c <-= VAL;
	t.asserteq(ended(done), 0, "the receive completed");
	t.asserteq(kchanged(), 0, "g.n = <-c: no object allocated since was written");
	t.assert(gh.n == VAL, "g.n = <-c: the value is in the object g names now");

	# and with g nil when the value comes: nothing is written
	spawn rcvfield(c, ready, done);
	pid = <-ready;
	t.assert(blocked(pid, "recv"), "the receiver waits again");
	gh = nil;
	fillk();
	c <-= VAL;
	t.asserteq(ended(done), 1, "g.n = <-c with g nil by then raises");
	t.asserteq(kchanged(), 0, "g nil: no object written");
}

rcvelem(c: chan of big, ready, done: chan of int)
{
	gb = array[2] of {* => big 0};
	ready <-= sys->pctl(0, nil);
	{
		gb[1] = <-c;
		done <-= 0;
	} exception {
	"*" =>
		done <-= 1;
	}
}

testRecvElem(t: ref T)
{
	c := chan of big;
	ready := chan of int;
	done := chan of int;
	spawn rcvelem(c, ready, done);
	pid := <-ready;
	t.assert(blocked(pid, "recv"), "the receiver waits");
	gb = array[2] of {* => big 0};
	fillkb();
	c <-= VAL;
	t.asserteq(ended(done), 0, "the receive completed");
	t.asserteq(kbchanged(), 0, "a[i] = <-c: no array allocated since was written");
	t.assert(gb[1] == VAL, "a[i] = <-c: the value is in the array a names now");
}

sndfield(c: chan of big, ready, done: chan of int)
{
	gh = ref H(big 0, big 7777);
	ready <-= sys->pctl(0, nil);
	c <-= gh.n;
	done <-= 0;
}

sndelem(c: chan of big, ready, done: chan of int)
{
	gb = array[2] of {* => big 7777};
	ready <-= sys->pctl(0, nil);
	c <-= gb[1];
	done <-= 0;
}

testSend(t: ref T)
{
	c := chan of big;
	ready := chan of int;
	done := chan of int;
	spawn sndfield(c, ready, done);
	pid := <-ready;
	t.assert(blocked(pid, "send"), "the sender waits");
	gh = nil;	# what it was sending from is freed
	fillk();
	v := <-c;
	t.asserteq(ended(done), 0, "the send completed");
	t.assert(v == big 7777, sys->sprint("c <-= g.n: the value sent was received (got %bux)", v));

	spawn sndelem(c, ready, done);
	pid = <-ready;
	t.assert(blocked(pid, "send"), "the sender waits");
	gb = nil;
	fillkb();
	v = <-c;
	t.asserteq(ended(done), 0, "the send completed");
	t.assert(v == big 7777, sys->sprint("c <-= a[i]: the value sent was received (got %bux)", v));
}

altrcv(c: chan of big, c2: chan of int, ready, done: chan of int)
{
	gh = ref H(big 0, big 0);
	ready <-= sys->pctl(0, nil);
	{
		alt{
		gh.n = <-c =>
			done <-= 0;
		<-c2 =>
			done <-= 2;
		}
	} exception {
	"*" =>
		done <-= 1;
	}
}

altsnd(c: chan of big, c2: chan of int, ready, done: chan of int)
{
	gh = ref H(big 0, big 7777);
	ready <-= sys->pctl(0, nil);
	alt{
	c <-= gh.n =>
		done <-= 0;
	<-c2 =>
		done <-= 2;
	}
}

testAlt(t: ref T)
{
	c := chan of big;
	c2 := chan of int;
	ready := chan of int;
	done := chan of int;
	spawn altrcv(c, c2, ready, done);
	pid := <-ready;
	t.assert(blocked(pid, "alt"), "the alt waits");
	gh = ref H(big 0, big 0);
	fillk();
	c <-= VAL;
	t.asserteq(ended(done), 0, "the alt received");
	t.asserteq(kchanged(), 0, "alt g.n = <-c: no object allocated since was written");
	t.assert(gh.n == VAL, "alt g.n = <-c: the value is in the object g names now");

	spawn altsnd(c, c2, ready, done);
	pid = <-ready;
	t.assert(blocked(pid, "alt"), "the alt waits");
	gh = nil;
	fillk();
	v := <-c;
	t.asserteq(ended(done), 0, "the alt sent");
	t.assert(v == big 7777, sys->sprint("alt c <-= g.n: the value sent was received (got %bux)", v));
}

rcvarray(ca: array of chan of big, ready, done: chan of int)
{
	ght = ref Ht(big 0, (0, big 0));
	ready <-= sys->pctl(0, nil);
	{
		ght.t = <-ca;
		done <-= 0;
	} exception {
	"*" =>
		done <-= 1;
	}
}

testRecvArray(t: ref T)
{
	ca := array[2] of {* => chan of big};
	ready := chan of int;
	done := chan of int;
	spawn rcvarray(ca, ready, done);
	pid := <-ready;
	t.assert(blocked(pid, "alt"), "the receiver waits");
	ght = ref Ht(big 0, (0, big 0));
	fillk3();
	ca[1] <-= VAL;
	t.asserteq(ended(done), 0, "the receive completed");
	t.asserteq(k3changed(), 0, "g.t = <-chans: no object allocated since was written");
	(i, v) := ght.t;
	t.assert(i == 1 && v == VAL, "g.t = <-chans: the value is in the object g names now");
}

Hm: adt {
	pad:	big;
	m:	LimboStaleTest;
};

Ks: adt {
	a:	big;
	s:	string;
};

ghm: ref Hm;
kss: array of ref Ks;

# the file's server: while the load waits for its read, drop
# the object the module was to go into
loadsrv(fio: ref Sys->FileIO, done: chan of int)
{
	(nil, nil, nil, rc) := <-fio.read;
	ghm = nil;
	kss = array[NF] of ref Ks;
	for(i := 0; i < len kss; i++)
		kss[i] = ref Ks(big 1, "kept" + string i);
	rc <-= (nil, nil);
	done <-= 0;
}

testLoad(t: ref T)
{
	name := "limbostale" + string sys->pctl(0, nil);
	fio := sys->file2chan("/chan", name);
	if(fio == nil){
		sys->bind("#s", "/chan", Sys->MBEFORE);
		fio = sys->file2chan("/chan", name);
	}
	if(fio == nil)
		t.skip(sys->sprint("no file2chan: %r"));
	done := chan of int;
	spawn loadsrv(fio, done);
	ghm = ref Hm(big 0, nil);
	raised := 0;
	{
		ghm.m = load LimboStaleTest "/chan/" + name;
	} exception {
	"*" =>
		raised = 1;
	}
	t.asserteq(ended(done), 0, "the file was read");
	n := 0;
	for(i := 0; i < len kss; i++)
		if(kss[i].a != big 1 || kss[i].s != "kept" + string i)
			n++;
	t.asserteq(n, 0, "g.m = load: no object allocated since was written");
	t.asserteq(raised, 1, "g.m = load with g nil by then raises");
}

#
# in one thread
#

aa: array of array of int;
bb: array of array of int;
ia: array of int;
ib: array of int;
zero: array of int;
one: array of int;
sss: array of array of string;
ss: array of string;
ki: array of array of int;
ko: array of array of array of int;
kstr: array of array of string;
kostr: array of array of array of string;
hold: list of array of int;

# arrays as those dropped, after them, and others between them all
# so that a freed one is not joined to its neighbour
inner(v: int): array of int
{
	hold = array[4] of {* => -1} :: hold;
	a := array[4] of {* => v};
	hold = array[4] of {* => -1} :: hold;
	return a;
}

mkaa(): array of array of int
{
	a := array[2] of array of int;
	a[0] = inner(10);
	a[1] = inner(20);
	return a;
}

fillints()
{
	ki = array[NF] of array of int;
	for(i := 0; i < len ki; i++)
		ki[i] = array[4] of {* => FILL};
	ko = array[NF] of array of array of int;
	for(i = 0; i < len ko; i++)
		ko[i] = array[2] of {* => ki[i]};
}

intschanged(): int
{
	n := 0;
	for(i := 0; i < len ki; i++)
		for(j := 0; j < len ki[i]; j++)
			if(ki[i][j] != FILL)
				n++;
	return n;
}

setup()
{
	hold = nil;
	zero = array[1] of {* => 0};
	one = array[1] of {* => 1};
	aa = mkaa();
	bb = mkaa();
	ki = nil;
	ko = nil;
}

# each drops the arrays and takes their place
dropaa(v: int): int
{
	aa = nil;
	bb = nil;
	fillints();
	return v;
}

# (with no arguments a call is simple enough that the other
# operand's address was found first; with a local it is not put in line)
dropaa5(): int
{
	v := dropaa(5);
	return v;
}

dropaa2(): int
{
	v := dropaa(2);
	return v;
}

dropaa1(): int
{
	v := dropaa(1);
	return v;
}

dropaa20(): int
{
	v := dropaa(20);
	return v;
}

droplist(): list of int
{
	ia = nil;
	fillints();
	return 2 :: nil;
}

dropnewarr(): array of int
{
	aa = nil;
	fillints();
	return array[4] of {* => 7};
}

testBinary(t: ref T)
{
	setup();
	x := dropaa5() - aa[one[0]][zero[0]];
	t.asserteq(x, 5 - 20, "f() - a[i][j]: the element as it was before f");
	t.asserteq(intschanged(), 0, "nothing allocated since was written");
}

testIndex(t: ref T)
{
	setup();
	x := aa[one[0]][dropaa2()];
	t.asserteq(x, 20, "a[i][f()]: the array as it was before f");
}

testOpAssign(t: ref T)
{
	setup();
	ia = array[4] of {* => 1};
	ia[dropaa1()] += bb[one[0]][zero[0]];
	t.asserteq(ia[1], 21, "a[f()] += b[i][j]: the element as it was before f");
}

testCons(t: ref T)
{
	setup();
	ia = inner(30);
	l := ia[1] :: droplist();
	t.asserteq(hd l, 30, "a[i] :: f(): the element as it was before f");
	t.asserteq(hd tl l, 2, "f's list after it");
}

testCompare(t: ref T)
{
	setup();
	r := 0;
	if(aa[one[0]][zero[0]] == dropaa20())
		r = 1;
	t.asserteq(r, 1, "a[i][j] == f(): the element as it was before f");
}

fillstrs()
{
	kstr = array[NF] of array of string;
	for(i := 0; i < len kstr; i++)
		kstr[i] = array[2] of {* => "ZZZZ"};
	kostr = array[NF] of array of array of string;
	for(i = 0; i < len kostr; i++)
		kostr[i] = array[2] of {* => kstr[i]};
}

strschanged(): int
{
	n := 0;
	for(i := 0; i < len kstr; i++)
		for(j := 0; j < len kstr[i]; j++)
			if(kstr[i][j] != "ZZZZ")
				n++;
	return n;
}

mksss(): array of array of string
{
	a := array[2] of array of string;
	for(i := 0; i < len a; i++){
		hold = array[4] of {* => -1} :: hold;
		a[i] = array[2] of {* => "abcd"};
		hold = array[4] of {* => -1} :: hold;
	}
	return a;
}

dropsss(): int
{
	sss = nil;
	fillstrs();
	return 2;
}

testStringIndex(t: ref T)
{
	setup();
	sss = mksss();
	ch := sss[one[0]][zero[0]][dropsss()];
	t.asserteq(ch, 'c', "a[i][j][f()]: the string as it was before f");
}

testSlice(t: ref T)
{
	setup();
	sl := aa[one[0]][dropaa(1):];
	t.asserteq(len sl, 3, "a[i][f():]: its length");
	t.asserteq(sl[0], 20, "a[i][f():]: the array as it was before f");
}

testSliceAssign(t: ref T)
{
	setup();
	aa[one[0]][0:] = dropnewarr();
	t.asserteq(intschanged(), 0, "a[i][0:] = f(): no array allocated since was written");
}

newss(): int
{
	ss = array[2] of {* => "abcd"};
	kstr = array[NF] of array of string;
	for(i := 0; i < len kstr; i++)
		kstr[i] = array[2] of {* => "ZZZZ"};
	return 'X';
}

testStringAssign(t: ref T)
{
	setup();
	hold = array[4] of {* => -1} :: hold;
	ss = array[2] of {* => "abcd"};
	hold = array[4] of {* => -1} :: hold;
	ss[one[0]][0] = newss();
	t.assertseq(ss[1], "Xbcd", "ss[i][0] = f(): the string in the array ss names now");
	t.asserteq(strschanged(), 0, "no array allocated since was written");
}

myid := 1;

setid(i: int)
{
	myid = i;
}

# (not ones the compiler puts in line)
getid(x: int): int
{
	r := myid;
	r += x;
	return r;
}

otherid(x: int): int
{
	r := 1000 + myid;
	r += x;
	return r;
}

mods: array of LimboStaleTest;
kmods: array of array of LimboStaleTest;
second: LimboStaleTest;

dropmods(): int
{
	mods = nil;
	kmods = array[NF] of array of LimboStaleTest;
	for(i := 0; i < len kmods; i++)
		kmods[i] = array[2] of {* => second};
	return 0;
}

testModule(t: ref T)
{
	setup();
	second = loadsecond();
	if(second == nil)
		t.skip(sys->sprint("cannot load a second instance of this module: %r"));
	second->setid(2);
	first := load LimboStaleTest "$self";
	hold = array[4] of {* => -1} :: hold;
	mods = array[2] of {* => first};
	hold = array[4] of {* => -1} :: hold;
	id := mods[one[0]]->getid(dropmods());
	t.asserteq(id, 1, "mods[i]->f(g()): the module as it was before g");
}

gf: ref fn(x: int): int;

newgf(): int
{
	gf = second->otherid;
	return 0;
}

testFnRef(t: ref T)
{
	second = loadsecond();
	if(second == nil)
		t.skip(sys->sprint("cannot load a second instance of this module: %r"));
	second->setid(2);
	gf = getid;
	id := gf(newgf());
	t.asserteq(id, 1, "gf(h()): the function gf named before h, not a mixture");
}

# strings nothing else holds: they go with the array
fresh(v: int): array of string
{
	return array[4] of {* => "v" + string v};
}

testCase(t: ref T)
{
	r := 0;
	for(i := 0; i < 50; i++){
		case fresh(i)[1] {
		"v0" or "v1" or "v2" or "v3" or "v4" or "v5" or "v6" or "v7" or "v8" or "v9" =>
			r++;
		* =>
			if(i >= 10)
				r++;
		}
	}
	t.asserteq(r, 50, "case f()[i]: the element read while the array is held");
}

ga: array of int;

newga(): int
{
	ga = array[2] of {* => 0};
	return 42;
}

testArrayInit(t: ref T)
{
	ga = array[] of {newga(), 2};
	t.asserteq(ga[0], 42, "ga = array[] of {f(), 2}: f's value in the array ga names now");
	t.asserteq(ga[1], 2, "the element after it");
}

chans: array of chan of int;
kchans: array of array of chan of int;

dropchans(): int
{
	chans = nil;
	kchans = array[NF] of array of chan of int;
	for(i := 0; i < len kchans; i++)
		kchans[i] = array[2] of {* => chan[1] of int};
	return 7;
}

testSendChan(t: ref T)
{
	setup();
	c := chan[1] of int;
	hold = array[4] of {* => -1} :: hold;
	chans = array[2] of {* => c};
	hold = array[4] of {* => -1} :: hold;
	chans[one[0]] <-= dropchans();
	v := -1;
	alt{
	v = <-c =>
		;
	* =>
		;
	}
	t.asserteq(v, 7, "c[i] <-= f(): sent on the channel c[i] was before f");
}

testAssignInside(t: ref T)
{
	# no call: the assignment in the right side drops the array
	ia = array[2] of {* => 1};
	ia[0] = len (ia = array[2] of {* => 5});
	t.asserteq(ia[0], 2, "a[0] = len (a = b): stored in the array a names now");
	t.asserteq(ia[1], 5, "the element after it");
}

#
# the same forms where nothing is freed: what they always did
#

W: adt {
	pad:	big;
	n:	int;
	s:	string;
	t:	(int, string);
	a:	array of int;
	m:	LimboStaleTest;
	f:	ref fn(x: int): int;
	c:	chan of int;
};

gw: ref W;
wa: array of ref W;

twice(x: int): int
{
	r := 2 * x;
	return r;
}

sum3(a, b, c: int): int
{
	r := a + b;
	return r + c;
}

testStillWorks(t: ref T)
{
	ci := chan[8] of int;
	cs := chan[8] of string;
	ct := chan[8] of (int, string);
	gw = ref W(big 0, 0, nil, (0, nil), array[4] of {* => 0}, nil, nil, ci);
	wa = array[2] of {* => gw};
	strs := array[2] of {* => "abcd"};
	first := load LimboStaleTest "$self";

	ci <-= 11;
	gw.n = <-ci;
	t.asserteq(gw.n, 11, "g.n = <-c");
	cs <-= "s1";
	gw.s = <-cs;
	t.assertseq(gw.s, "s1", "g.s = <-c");
	ct <-= (3, "three");
	gw.t = <-ct;
	(i, str) := gw.t;
	t.assert(i == 3 && str == "three", "g.t = <-c, a tuple");
	ci <-= 12;
	gw.a[1] = <-ci;
	t.asserteq(gw.a[1], 12, "g.a[i] = <-c");
	ci <-= 13;
	wa[1].n = <-ci;
	t.asserteq(gw.n, 13, "a[i].n = <-c");
	ci <-= 'X';
	strs[1][0] = <-ci;
	t.assertseq(strs[1], "Xbcd", "ss[i][0] = <-c");

	gw.n = 21;
	ci <-= gw.n;
	t.asserteq(<-ci, 21, "c <-= g.n");
	cs <-= gw.s;
	t.assertseq(<-cs, "s1", "c <-= g.s");
	gw.a[2] = 22;
	gw.c <-= gw.a[2];
	t.asserteq(<-ci, 22, "g.c <-= g.a[i]");
	ct <-= gw.t;
	(i, str) = <-ct;
	t.assert(i == 3 && str == "three", "c <-= g.t, a tuple");
	x := ci <-= gw.a[2];
	t.assert(x == 22 && <-ci == 22, "x = c <-= g.a[i]");

	ci <-= 31;
	alt{
	gw.n = <-ci =>
		;
	* =>
		gw.n = -1;
	}
	t.asserteq(gw.n, 31, "alt g.n = <-c");
	gw.n = 32;
	alt{
	ci <-= gw.n =>
		;
	* =>
		;
	}
	t.asserteq(<-ci, 32, "alt c <-= g.n");
	cs <-= "alts";
	alt{
	gw.t = (1, <-cs) =>
		;
	* =>
		;
	}
	(i, str) = gw.t;
	t.assert(i == 1 && str == "alts", "alt g.t = (1, <-c)");

	gw.m = load LimboStaleTest "$self";
	t.assert(gw.m != nil, "g.m = load");
	wa[0].m = nil;
	wa[1].m = load LimboStaleTest "/dis/no/such/module.dis";
	t.assert(gw.m == nil, "a[i].m = load of no module is nil");
	gw.m = first;

	cj := chan[1] of int;
	cj <-= 2;
	ci <-= 40;
	gw.a[<-cj] = <-ci;
	t.asserteq(gw.a[2], 40, "a[<-c] = <-c");
	cj <-= 2;
	gw.a[<-cj] += twice(1);
	t.asserteq(gw.a[2], 42, "a[<-c] += f()");
	gw.a[3] = 1;
	y := twice(4) - wa[1].a[gw.a[3]];
	t.asserteq(y, 8 - 12, "f() - a[i].a[j]");
	l := gw.a[2] :: twice(1) :: nil;
	t.assert(hd l == 42 && hd tl l == 2, "a[i] :: f() :: nil");
	sl := wa[1].a[twice(1):];
	t.assert(len sl == 2 && sl[0] == 42, "a[i].a[f():]");
	wa[1].a[twice(1):] = array[] of {twice(25), 51};
	t.assert(gw.a[2] == 50 && gw.a[3] == 51, "a[i].a[f():] = array[] of {f(), 51}");
	ci <-= 60;
	gw.a = array[] of {<-ci, twice(31), 63};
	t.assert(len gw.a == 3 && gw.a[0] == 60 && gw.a[1] == 62 && gw.a[2] == 63, "g.a = array[] of {<-c, f(), 63}");
	wa[1].a = array[3] of {* => twice(2)};
	t.assert(len gw.a == 3 && gw.a[0] == 4 && gw.a[2] == 4, "a[i].a = array[3] of {* => f()}");
	ci <-= 1;
	cj <-= 2;
	t.asserteq(sum3(<-ci, twice(<-cj), gw.a[0]), 1 + 4 + 4, "f(<-c, g(<-c), g.a[i])");
	# arguments are made in the order they were: one that
	# assigns after the one before it
	li := 1 :: 2 :: nil;
	t.asserteq(sum3(hd li, len (li = tl li), 0), 1 + 1, "f(hd l, len (l = tl l))");
	ci <-= 5;
	t.asserteq(wa[1].m->getid(<-ci), 6, "a[i].m->f(<-c)");
	gw.f = twice;
	ci <-= 7;
	t.asserteq(gw.f(<-ci), 14, "g.f(<-c)");
	gf = twice;
	t.asserteq(gf(8), 16, "gf(x)");
	ci <-= 2;
	case <-ci {
	2 =>
		;
	* =>
		t.error("case <-c");
	}
	case wa[1].a[twice(1)] {
	4 =>
		;
	* =>
		t.error("case a[i].a[f()]");
	}
	r := 0;
	if(wa[1].a[gw.a[0] - 3] == twice(2))
		r = 1;
	t.asserteq(r, 1, "a[i].a[j] == f()");
	strs[0] = "hello";
	t.asserteq(strs[twice(0)][twice(2)], 'o', "ss[f()][g()]");
	v := gw.a;
	u := array[] of {0, 9, 8, 7};
	v = u[v[0] - 3:];
	t.assert(len v == 3 && v[0] == 9, "v = t[v[i]:]");
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
	for(a := args; a != nil; a = tl a){
		if(hd a == "-v")
			testing->verbose(1);
		if(hd a == "-m" && tl a != nil){
			a = tl a;
			selfpath = hd a;
		}else if(hd a == "-t" && tl a != nil){
			a = tl a;
			only = hd a;
		}
	}

	run("RecvField", testRecvField);
	run("RecvElem", testRecvElem);
	run("Send", testSend);
	run("Alt", testAlt);
	run("RecvArray", testRecvArray);
	run("Load", testLoad);
	run("Binary", testBinary);
	run("Index", testIndex);
	run("OpAssign", testOpAssign);
	run("Cons", testCons);
	run("Compare", testCompare);
	run("StringIndex", testStringIndex);
	run("Slice", testSlice);
	run("SliceAssign", testSliceAssign);
	run("StringAssign", testStringAssign);
	run("Module", testModule);
	run("FnRef", testFnRef);
	run("Case", testCase);
	run("ArrayInit", testArrayInit);
	run("SendChan", testSendChan);
	run("AssignInside", testAssignInside);
	run("StillWorks", testStillWorks);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
