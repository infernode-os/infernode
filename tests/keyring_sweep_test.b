implement KeyringSweepTest;

#
# keyring_sweep_test - the collector frees Keyring's keys and
# certificates when only a cycle holds them, and the emulator goes on.
#
# An SK, PK or Certificate refers to its SigAlg; freeing one freed its key
# (or signature) through the SigAlg's functions, found by checking the
# SigAlg. When nothing but a cycle holds them, the sweep frees the object
# and its SigAlg together, in either order, and when the SigAlg went first
# its memory was the allocator's: the check raised "bad signature algorithm"
# inside the collector, where no Prog runs, and emu's vmachine took it for
# a Prog's exception. handler() then read the collector's own Prog (no
# registers, a nil exval) and emu died: "SEGV: addr=fffffffffffffff0",
# "PC in handler+0x60", "SYS: process dis faults: Segmentation violation"
# (macOS ARM64 CI, as authneg_test started, after the suite's earlier
# Keyring tests: what this test does gives the same fault there, on Linux
# amd64, -c0 and -c1). Each now keeps its own algorithm for freeing.
#
# Here many keys of each kind are put in cycles and dropped, each with an
# FD (freeing one lets other Progs run in the middle of the sweep, as the
# suite's earlier tests' FDs did) while another Prog allocates blocks of a
# SigAlg's size, until the collector has closed an ORCLOSE file put in a
# cycle after them; and that is done again. The test passing at all (emu
# still here) is most of it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "testing.m";
	testing: Testing;
	T: import testing;

KeyringSweepTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/keyring_sweep_test.b";

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

# cycles: what is in one goes only when the collector finds it
# (each with an FD: freeing it releases the VM in the middle of the
# sweep, as the FDs the suite's earlier tests left did, and the churn
# Prog allocates in what the sweep has freed so far)
SKLoop: adt {
	sk:	ref Keyring->SK;
	fd:	ref Sys->FD;
	next:	cyclic ref SKLoop;
};

PKLoop: adt {
	pk:	ref Keyring->PK;
	fd:	ref Sys->FD;
	next:	cyclic ref PKLoop;
};

CertLoop: adt {
	c:	ref Keyring->Certificate;
	fd:	ref Sys->FD;
	next:	cyclic ref CertLoop;
};

FDLoop: adt {
	fd:	ref Sys->FD;
	next:	cyclic ref FDLoop;
};

Nkeys: con 64;

# Nkeys of each in cycles of their own, each SK with a SigAlg of its own
# (genSK makes one), the PK and Certificate sharing their SK's; nothing
# outside the cycles is left holding them
dropincycles(alg: string): string
{
	for(i := 0; i < Nkeys; i++){
		sk := kr->genSK(alg, "sweep", 0);
		if(sk == nil)
			return sys->sprint("genSK %s: %r", alg);
		pk := kr->sktopk(sk);
		if(pk == nil)
			return sys->sprint("sktopk %s: %r", alg);
		state := kr->sha256(array of byte "sweep", 5, nil, nil);
		c := kr->sign(sk, 0, state, "sha256");
		if(c == nil)
			return sys->sprint("sign %s: %r", alg);

		l := ref SKLoop(sk, sys->open("/dev/null", Sys->OREAD), nil);
		l.next = l;
		m := ref PKLoop(pk, sys->open("/dev/null", Sys->OREAD), nil);
		m.next = m;
		n := ref CertLoop(c, sys->open("/dev/null", Sys->OREAD), nil);
		n.next = n;
	}
	return nil;
}

# an ORCLOSE file in a cycle, made after the keys: gone once the
# collector has swept past them
sentinel(p: string): int
{
	fd := sys->create(p, Sys->ORDWR|Sys->ORCLOSE, 8r666);
	if(fd == nil)
		return -1;
	l := ref FDLoop(fd, nil);
	l.next = l;
	return 0;
}

# blocks the size of a SigAlg, filled with what is no SigAlgVec,
# allocated for as long as the sweeps go on: a freed SigAlg's memory is
# soon one of these
Junk: adt {
	a, b:	big;
};

churn(stop: chan of int, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	ring := array[4096] of ref Junk;
	for(i := 0;; i++){
		ring[i % len ring] = ref Junk(big 16r4141414141414141, big 16r4242424242424242);
		if(i % 256 == 0){
			alt {
			<-stop =>
				return;
			* =>
				sys->sleep(0);
			}
		}
	}
}

gone(p: string, secs: int): int
{
	for(i := 0; i < secs*10; i++){
		if(sys->stat(p).t0 < 0)
			return 1;
		sys->sleep(100);
	}
	return 0;
}

sweep(t: ref T, alg: string)
{
	sys->pctl(Sys->FORKENV, nil);
	p := "/env/keyringsweep";
	stop := chan of int;
	pidc := chan of int;
	spawn churn(stop, pidc);
	<-pidc;
	for(round := 0; round < 3; round++){
		err := dropincycles(alg);
		if(err != nil)
			t.fatal(err);
		t.asserteq(sentinel(p), 0, "sentinel made");
		# the collector runs when the VM is idle
		t.assert(gone(p, 30), sys->sprint("round %d: the collector swept the cycles", round));
		sys->sleep(200);
	}
	stop <-= 1;
	# and Keyring still works after
	sk := kr->genSK(alg, "after", 0);
	t.assert(sk != nil, "genSK after the sweeps");
	if(sk != nil){
		state := kr->sha256(array of byte "after", 5, nil, nil);
		c := kr->sign(sk, 0, state, "sha256");
		t.assert(c != nil, "sign after the sweeps");
		if(c != nil){
			state = kr->sha256(array of byte "after", 5, nil, nil);
			t.asserteq(kr->verify(kr->sktopk(sk), c, state), 1, "verify after the sweeps");
		}
	}
}

testEd25519(t: ref T)
{
	sweep(t, "ed25519");
}

testMLDSA(t: ref T)
{
	sweep(t, "mldsa65");
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

	kr = load Keyring Keyring->PATH;
	if(kr == nil){
		sys->fprint(sys->fildes(2), "cannot load keyring: %r\n");
		raise "fail:cannot load keyring";
	}

	run("Ed25519", testEd25519);
	run("MLDSA", testMLDSA);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
