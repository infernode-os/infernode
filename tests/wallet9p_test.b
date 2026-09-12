implement Wallet9pTest;

#
# wallet9p integration test.
# Starts its factotum-backed fixture, creates an account, and reads its address.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

Wallet9pTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
	_marker: fn();	# prevents joiniface() type conflation with Wallet9p
};

passed := 0;
failed := 0;
skipped := 0;

SRCFILE: con "/tests/wallet9p_test.b";
W: con "/tmp/wallet9p-test";

Pinfo: adt {
	pid: string;
	mod: string;
};

# Teardown compares against this snapshot so it cannot kill a service
# that was already present when the fixture started.
baseline: list of ref Pinfo;
factotumowned := 0;
walletstarted := 0;

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

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

include "sh.m";

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
}

procinfo(pid: string): ref Pinfo
{
	fd := sys->open("/prog/" + pid + "/status", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[512] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	(nil, fields) := sys->tokenize(string buf[0:n], " ");
	modname := "";
	for(; fields != nil; fields = tl fields)
		modname = hd fields;
	if(modname == "")
		return nil;
	return ref Pinfo(pid, modname);
}

procs(): list of ref Pinfo
{
	fd := sys->open("/prog", Sys->OREAD);
	if(fd == nil)
		return nil;
	out: list of ref Pinfo;
	for(;;) {
		(n, dirs) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++) {
			p := procinfo(dirs[i].name);
			if(p != nil)
				out = p :: out;
		}
	}
	return out;
}

haspid(pid: string, ps: list of ref Pinfo): int
{
	for(; ps != nil; ps = tl ps)
		if((hd ps).pid == pid)
			return 1;
	return 0;
}

isfixturemodule(mod: string): int
{
	return hasprefix(mod, "Factotum") || hasprefix(mod, "Wallet9p") ||
		hasprefix(mod, "Styx");
}

waitmount(path: string)
{
	for(i := 0; i < 50; i++) {
		(ok, nil) := sys->stat(path);
		if(ok >= 0)
			return;
		sys->sleep(100);
	}
}

runfactotum()
{
	mod := load Command "/dis/auth/factotum.dis";
	if(mod == nil) {
		sys->fprint(sys->fildes(2), "cannot load factotum: %r\n");
		return;
	}
	mod->init(nil, nil);
}

# Start factotum and wallet9p in background.
startserver()
{
	baseline = procs();
	(ok, nil) := sys->stat("/mnt/factotum/ctl");
	if(ok < 0) {
		factotumowned = 1;
		spawn runfactotum();
	}
	waitmount("/mnt/factotum/ctl");
	walletstarted = 1;
	spawn runsrv();
	waitmount(W + "/accounts");
}

killproc(pid: string)
{
	fd := sys->open("/prog/" + pid + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte "kill";
	sys->write(fd, b, len b);
}

stopserver()
{
	# Unmount private fixture paths before stopping only its new service
	# threads; unrelated wallet/factotum services are left untouched.
	if(walletstarted) {
		sys->unmount(nil, W);
		sys->remove(W);
	}
	if(factotumowned)
		sys->unmount(nil, "/mnt/factotum");
	current := procs();
	for(ps := current; ps != nil; ps = tl ps) {
		p := hd ps;
		if(!haspid(p.pid, baseline) && isfixturemodule(p.mod))
			killproc(p.pid);
	}
}

runsrv()
{
	mod := load Command "/dis/veltro/wallet9p.dis";
	if(mod == nil) {
		sys->fprint(sys->fildes(2), "cannot load wallet9p: %r\n");
		return;
	}
	mod->init(nil, "wallet9p" :: "-m" :: W :: nil);
}

#
# Test: mount exists
#
testMount(t: ref T)
{
	(ok, nil) := sys->stat(W + "/accounts");
	t.assert(ok >= 0, "accounts file exists after wallet mount");
	if(ok >= 0) {
		s := readfile(W + "/accounts");
		t.log("accounts: '" + s + "'");
	}
}

#
# Test: import a known key and read the address
#
testImportAndAddress(t: ref T)
{
	# Import private key = 1. Keep the descriptor open: the result is
	# bound to the writing fid and is cleared when that fid is clunked.
	fd := sys->open(W + "/new", Sys->ORDWR);
	if(fd == nil) {
		t.fatal("cannot open new: " + sys->sprint("%r"));
		return;
	}
	data := "import eth ethereum testkey 0000000000000000000000000000000000000000000000000000000000000001";
	b := array of byte data;
	n := sys->write(fd, b, len b);
	t.assert(n == len b, "write to new succeeded");

	# Read back the account name on the same fid.
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[128] of byte;
	n = sys->read(fd, buf, len buf);
	name := "";
	if(n > 0)
		name = string buf[0:n];
	t.assert(name == "testkey\n", "new reports the imported account");
	t.log("new account: '" + name + "'");

	# Read address
	addr := readfile(W + "/testkey/address");
	t.assert(addr != nil && len addr > 1, "address readable");
	t.log("address: " + addr);
}

#
# Test: the removed raw signing oracle is not exercised
#
testSign(t: ref T)
{
	# The raw hash-signing oracle was intentionally removed. The supported
	# authorize flow is covered by wallet_policy_test.
	t.skip("raw sign oracle removed; authorize is covered by wallet policy tests");
}

#
# Test: read chain
#
testChain(t: ref T)
{
	chain := readfile(W + "/testkey/chain");
	t.assert(chain != nil, "chain readable");
	t.log("chain: " + chain);
}

_marker() {}

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

	# Start the factotum-backed wallet fixture.
	startserver();

	run("Mount", testMount);
	run("ImportAndAddress", testImportAndAddress);
	run("SignOracleRemoved", testSign);
	run("Chain", testChain);

	stopserver();
	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
