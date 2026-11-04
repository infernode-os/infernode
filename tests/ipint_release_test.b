implement IPintReleaseTest;

#
# IPint's long operations leave the Dis VM to other threads while they
# compute (they release() it), so a 2048-bit expmod no longer freezes
# every Limbo thread for its whole length (90 ms on a fast x86, seconds
# on a Raspberry Pi).
#
# A ticker thread sleeps 1 ms at a time and keeps its worst lateness
# while other threads run expmod in a loop; the worst must stay small.
# The results are checked against values computed elsewhere (Python's
# pow) and by identities, while a third thread makes garbage so the
# collector runs while the computation holds no VM.  The errors libmp
# raises (negative exponent, zero modulus, no inverse) are still Limbo
# exceptions, and the VM goes on after them.
#
# tests/host/ipint_release_test.sh runs it under -c0 and -c1.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "ipints.m";
	ipints: IPints;
	IPint: import ipints;

include "testing.m";
	testing: Testing;
	T: import testing;

IPintReleaseTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ipint_release_test.b";

passed := 0;
failed := 0;
skipped := 0;

# The worst lateness of a 1 ms sleep allowed while expmod runs: a quarter
# of the loop of calls, and never less than MAXLATE.  Held, the VM froze
# for the whole loop (a builtin barely counts against a thread's time
# slice), so the ticker was late by all of it, 242 ms of 243 and 520 of
# 520 on an M-series Mac, or by half of it with two threads handing the
# VM to each other (261 ms of 509).  Released, it is late by the host's
# noise, which does not grow with the loop: 1 to 20 ms, and 52 ms of 622
# on a loaded CI runner, where a fixed 50 ms failed.
MAXLATE: con 50;

# 2048-bit modulus, base and exponent, and base^exp mod m (Python's pow)
M2048: con
	"d022e8f4fa56820673ae38cc8820c81662b720857e4fb620c7fcc6e3869e9435" +
	"d24fe2b17f7a0769fcf5088580f8f7388ce84f8151cf034faeb7b9c9c5209c90" +
	"ff0030191c71640436766c7d4a894774b05d2e9149278fa1c720bbf91d878e94" +
	"db602352d033997bd73d8e81d5de0d3a3d43f4d0b4ac871c78a132618c1aca9e" +
	"dcb6124729054a97aee4a7edffc78672de847485fb6db32472c1b47f0741328c" +
	"e0469fa2602985b97518b05112d9d65ff664f742b16dbb7c9e863514f0003e66" +
	"d0b4bf8e9607ab378aa30de8dc842d83a63c88ce01ab036763286ec63a60f30b" +
	"052d78b79761d2b37fafad485eeda1d852ae3f0635840ea8a1bef5d3bd9dd94d";
B2048: con
	"7156c66b8961d40bffda8644b85d453ce5130345be37c5a623e18ce96f1cf302" +
	"fcede8d057d8e10d1b90302b81fc2a7f1ace461b0a3aae48a32f52646ffc3049" +
	"c73e5770edb55d2ca9f47fb5c3e9e02a4f5938ea8d34303738fad75888b1031f" +
	"75b91e27bf93193c86e94a67032cd744c766e390ca076ff18516e6f6fc9d2df2" +
	"cebe60efd949039fa8d8bac7d3e17db03f3e060531a329396ff9f9ab61860048" +
	"7e6efa1059fa75c882f01ab7d0564b58030dfdf6846db25d7e02dd90b8f9c583" +
	"50c7f5878858c561e5d2a665f3f51da1f590c1150948b33dade79a8f3868c784" +
	"9aa74e2c2741705cfae461bc360850a4bf77df2a6a8b0c50bd40fa4a2e73527e";
E2048: con
	"bc79c409a6706ad5aeed93849b5146e94fcbda0298bb04873390bc02bbdeb868" +
	"68702e1dc73988b91b744f5ac4734fe140f0798c9407786c9e00e0f58ea5bcf2" +
	"a1a396549000b3ee1810c45bcda6254262d615c68a4155919cae765db915fdb3" +
	"1fe6feb287714ee897368832984840c2b09a8ddd174e0442617778dca18a05b0" +
	"388a8fcfc30a882ccd04b8bbaf013077fad9306d4ae14d871a1aa4f12a5d0739" +
	"3906ea0172245f32c32512983d96e4e569e39f6dfdf881baa0e8d7694fb3d533" +
	"e8df39e65e138500e342994ab3cdeb71d6f4101014558aef2a8495ca103f4d9a" +
	"5f0fca36eaa1b8319ce520d24202325ec6ac146cfd617a60d95b8e090140e3e7";
R2048: con
	"1860c605659be826b94f0c9fc33d0fa263834ec642b51787d64fcd0913a2d709" +
	"b4132f1cc01325b00c54c1d4dc3df7983aca013a621bbdeed9ce63c320a6c85f" +
	"faf26644287e83740777556049edd0d961323ad48972f090833b9b8ac3960d8f" +
	"1841a9b46407e1af0b1bc992fc87597923acb17e104dd7b4b3272dda123f10a6" +
	"0f142804260b9b897d8d89215b283133aafaa0dc62987263b1716b039b09cc6d" +
	"f8ba7c067ba34488ee5ccd6d5990bf7bef761583fe77b85b91ae750ae39cb4a6" +
	"7d18cebea5aafaa57fa92d187b963a9be7e2fdca62e96064c70cf9c469e52523" +
	"2c3013887ef8a4d1652f99212524fedd83eb5eb437343eac4e58b9547a7ef87d";
# a 256-bit exponent (secstore3's g^x) and its result
E256: con
	"b891e4d1b9565ae950a3291dbf1acdf13429e6968ab2f0c7a81d508c4d81496c";
R256: con
	"31b1e22ac6141a2cd1c40550b60b88c0172332bb098bb3d0a9ab9dc527932afd" +
	"4265b1c28d1de775c70a9bc29acd2f09086296a9cecaee6f9e80424fa924aea9" +
	"c10bfd5f77d064c5630f6afbdd9e3fd39aecc0253b78227ae5b10315b6815341" +
	"bab5aec95f5cdb99aa14ff8a2954be0e492ac74e1e3d1f499f9a5427fef29bb1" +
	"1cd8125473e4d555e165a239a037e0ff8565cb6faa70b27b5e95aec68069f75a" +
	"b359e305f66783d34324b7a6c699a4dd5e449cc0bc36d386ff12cb3954eb9851" +
	"2a1f46c24810c3d80222accff00fff06cecd3fc8bb5286617bfc637b1dc04bfc" +
	"90958f7a249f7326f109c1dc4b824b65d9784a55da39a6313ccc7b5fdfb36aad";
# b^65537 mod m: an RSA public operation, which keeps the VM
RE17: con
	"c95682959a2c0b0b074ec2075bac3cdfc60810eecbe6a05af9f069447306593d" +
	"b681cd8c8b63f913809878edf80911dc8562673503abadac36abbccd1b5735b6" +
	"470491aea0eb4facd9f7ac1d42bda4983e60349595cd5a049c4dd4762fb00f4e" +
	"9acbe33b080ea15ddb8d6358dab8d3f7514a378602260d91a945e68eeab98552" +
	"6b3a9bed1df4367e15f875e8b796fb0f19a1e5e1205bdc4e0809c6e2a8386f1d" +
	"72427c02323ae935a43bdce9df83f016bbb05b27f4a33a05d4a5137f8b800c3e" +
	"cd201e5c94bb11c0032523181bf3c53cb5a28d05b938208ef93e28a540fa62fd" +
	"71fd4ef33844c5f7a6c44bd7fe0034e03e436c2a03f66d2564f4b238a265118";
# 0x123456789abcdef^37, no modulus
NIL37: con
	"769c74dbf5da5b1e4d782b01c41408529cb4afaebae6d488c148db5ead1f3359" +
	"ce7d158d3cfc8025a0e31319f1e3c7f3593017fca989b44b79c8351badf311e9" +
	"a90dbfccc20639223ee9862259a5c57913d0a346e79e28158b387d6cc04f59e7" +
	"7d7e27e09f4c347610e974dd2e59cbd5fae0caf13df8c993dea1139b089fbaed" +
	"7311561478841253882e599ed851658d936f6aaff08448c8b89baf22f02c4260" +
	"3fc2e0696406d5a4c43b8c33186ca9474a6977aae08d74b83fbca9e6cba64d62" +
	"183b0f689abe4667e55d9c05f06c87a406937b281e658b79e316af8f5c4be503" +
	"b52d1e153f9149191a0b74cd8f1d004ecfee40d32ede5f3167a6e0621b466245" +
	"a47909af";

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

hex(s: string): ref IPint
{
	return IPint.strtoip(s, 16);
}

testKnownAnswers(t: ref T)
{
	m := hex(M2048);
	b := hex(B2048);
	t.assert(b.expmod(hex(E2048), m).eq(hex(R2048)), "2048-bit b^e mod m");
	t.assert(b.expmod(hex(E256), m).eq(hex(R256)), "2048-bit b^e mod m, 256-bit e");
	t.assert(b.expmod(IPint.inttoip(65537), m).eq(hex(RE17)), "2048-bit b^65537 mod m");
	t.assert(hex("123456789abcdef").expmod(IPint.inttoip(37), nil).eq(hex(NIL37)), "b^37, no modulus");
	t.assert(b.expmod(IPint.inttoip(0), m).eq(IPint.inttoip(1)), "b^0 is 1");
	t.assert(IPint.inttoip(3).expmod(IPint.inttoip(5), IPint.inttoip(7)).eq(IPint.inttoip(5)), "3^5 mod 7");
}

# a * b, (a*b) / b, a / b and a % b on numbers of 100000 and 90000 bits,
# and an inverse modulo a 40000-bit odd number: by identities
testLargeOperands(t: ref T)
{
	a := IPint.random(100000);
	b := IPint.random(90000);
	p := a.mul(b);
	(q, r) := p.div(b);
	t.assert(q.eq(a), "(a*b)/b is a");
	t.assert(r.eq(IPint.inttoip(0)), "(a*b)%b is 0");
	(q, r) = a.div(b);
	t.assert(q.mul(b).add(r).eq(a), "q*b + r is a");
	t.assert(r.cmp(b) < 0, "r < b");
	t.assert(a.mod(b).eq(r), "mod agrees with div");

	m := IPint.random(40000).shl(1).add(IPint.inttoip(1));	# odd
	x := IPint.inttoip(2).expmod(IPint.inttoip(39999), nil).add(IPint.inttoip(12345));
	if(x.cmp(m) >= 0)
		x = x.mod(m);
	y := x.invert(m);
	t.assert(x.mul(y).mod(m).eq(IPint.inttoip(1)), "x * x^-1 mod m is 1");
}

catches(f: ref fn(), want: string): string
{
	{
		f();
	} exception e {
	"*" =>
		if(want != nil && e != want)
			return "raised " + e + ", not " + want;
		return nil;
	}
	return "nothing raised";
}

negexp()
{
	hex(B2048).expmod(IPint.inttoip(-3), hex(M2048));
}

zeromod()
{
	hex(B2048).expmod(hex(E2048), IPint.inttoip(0));
}

noinverse()
{
	m := hex(M2048).mul(IPint.inttoip(6));
	hex(B2048).mul(IPint.inttoip(3)).invert(m);
}

zeromodinv()
{
	hex(B2048).invert(IPint.inttoip(0));
}

testErrors(t: ref T)
{
	s := catches(negexp, "mpexp: negative exponent");
	t.assert(s == nil, "negative exponent: "+s);
	s = catches(zeromod, "mpdiv: divide by zero");
	t.assert(s == nil, "zero modulus: "+s);
	s = catches(noinverse, "mpinvert: no inverse");
	t.assert(s == nil, "no inverse: "+s);
	s = catches(zeromodinv, nil);
	t.assert(s == nil, "invert, zero modulus: "+s);
	# the VM goes on, and a released expmod still works
	t.assert(hex(B2048).expmod(hex(E2048), hex(M2048)).eq(hex(R2048)), "expmod after the errors");
}

ticker(stop: chan of int, res: chan of int)
{
	worst := 0;
	for(;;){
		t0 := sys->millisec();
		sys->sleep(1);
		late := sys->millisec() - t0 - 1;
		if(late > worst)
			worst = late;
		alt{
		<-stop =>
			res <-= worst;
			return;
		* =>
			;
		}
	}
}

worker(n: int, b, e, m, want: ref IPint, done: chan of int)
{
	bad := 0;
	for(i := 0; i < n; i++)
		if(!b.expmod(e, m).eq(want))
			bad++;
	done <-= bad;
}

# garbage, so the collector runs while expmod holds no VM; it sleeps
# between rounds so its own time slices do not dominate the lateness
churn(stop: chan of int)
{
	for(;;){
		x := hex(B2048);
		for(i := 0; i < 10; i++)
			x = x.add(IPint.inttoip(i));
		s := x.iptostr(16);
		s = nil;
		alt{
		<-stop =>
			return;
		* =>
			sys->sleep(1);
		}
	}
}

# the ticker's worst lateness while nw threads each run n expmods
freeze(t: ref T, label: string, nw, n: int, b, e, m, want: ref IPint)
{
	stop := chan of int;
	res := chan of int;
	cstop := chan of int;
	spawn ticker(stop, res);
	spawn churn(cstop);
	sys->sleep(50);
	done := chan of int;
	t0 := sys->millisec();
	for(i := 0; i < nw; i++)
		spawn worker(n, b, e, m, want, done);
	bad := 0;
	for(i = 0; i < nw; i++)
		bad += <-done;
	ms := sys->millisec() - t0;
	stop <-= 1;
	worst := <-res;
	cstop <-= 1;
	t.asserteq(bad, 0, label+": every result right");
	sys->print("%s: %d calls in %d ms (%d ms each), worst ticker lateness %d ms\n",
		label, nw*n, ms, ms/(nw*n), worst);
	limit := ms/4;
	if(limit < MAXLATE)
		limit = MAXLATE;
	t.assert(worst < limit, sys->sprint("worst lateness %d ms of %d, want < %d", worst, ms, limit));
}

# the ticker's lateness with the garbage thread and no expmod: the
# host's and the VM's own noise (reported, not checked)
baseline(): int
{
	stop := chan of int;
	res := chan of int;
	cstop := chan of int;
	spawn churn(cstop);
	spawn ticker(stop, res);
	sys->sleep(1000);
	stop <-= 1;
	worst := <-res;
	cstop <-= 1;
	sys->print("no expmod, garbage thread alone: worst ticker lateness %d ms\n", worst);
	return worst;
}

testFreeze2048(t: ref T)
{
	freeze(t, "2048-bit modulus, 2048-bit exponent", 1, 10,
		hex(B2048), hex(E2048), hex(M2048), hex(R2048));
}

testFreeze256(t: ref T)
{
	freeze(t, "2048-bit modulus, 256-bit exponent", 1, 40,
		hex(B2048), hex(E256), hex(M2048), hex(R256));
}

testFreezeConcurrent(t: ref T)
{
	freeze(t, "two threads, 2048-bit modulus and exponent", 2, 5,
		hex(B2048), hex(E2048), hex(M2048), hex(R2048));
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	ipints = load IPints IPints->PATH;
	testing = load Testing Testing->PATH;
	if(testing == nil){
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(ipints == nil){
		sys->fprint(sys->fildes(2), "cannot load IPints: %r\n");
		raise "fail:cannot load IPints";
	}
	testing->init();
	for(a := args; a != nil; a = tl a)
		if(hd a == "-v")
			testing->verbose(1);

	run("KnownAnswers", testKnownAnswers);
	run("LargeOperands", testLargeOperands);
	run("Errors", testErrors);
	baseline();
	run("Freeze2048", testFreeze2048);
	run("Freeze256", testFreeze256);
	run("FreezeConcurrent", testFreezeConcurrent);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
