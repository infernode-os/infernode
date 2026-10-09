implement Wallet9pTest;

#
# wallet9p integration test.
# Starts wallet9p, creates an account, reads address, signs a hash.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "keyring.m";
	kr: Keyring;

include "ethcrypto.m";
	ethcrypto: Ethcrypto;

include "testing.m";
	testing: Testing;
	T: import testing;

Wallet9pTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

passed := 0;
failed := 0;
skipped := 0;

SRCFILE: con "/tests/wallet9p_test.b";

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

hexdecode(s: string): array of byte
{
	if(len s % 2 != 0)
		return nil;
	buf := array[len s / 2] of byte;
	for(i := 0; i < len buf; i++) {
		hi := hexval(s[2*i]);
		lo := hexval(s[2*i+1]);
		if(hi < 0 || lo < 0)
			return nil;
		buf[i] = byte (hi * 16 + lo);
	}
	return buf;
}

hexval(c: int): int
{
	if(c >= '0' && c <= '9')
		return c - '0';
	if(c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if(c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return -1;
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

writefile(path: string, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

include "sh.m";

# Start factotum (wallet9p keeps its keys there) and wallet9p, each in
# this test's own namespace.  Both are started through Sh, not loaded as a
# Command: this module's type is structurally the same as Command (one init
# of the same type), so limbo gives the two one import table, and the test
# functions this module passes by reference (run(name, testfn)) land in it.
# Loading a command as a Command here would demand testChain and the rest
# of it, and fail to link.
startserver(): string
{
	sh := load Sh Sh->PATH;
	if(sh == nil)
		return sys->sprint("cannot load sh: %r");
	(ok, nil) := sys->stat("/mnt/factotum/rpc");
	err: string;
	# A factotum service of its own: #sfactotum is one for the whole
	# emulator, and another test's factotum may still hold it.
	fcmd := "/dis/auth/factotum.dis -s factotum." + string sys->pctl(0, nil);
	if(ok < 0 && (err = sh->system(nil, fcmd)) != nil)
		return "factotum: " + err;
	if((err = sh->system(nil, "/dis/veltro/wallet9p.dis")) != nil)
		return "wallet9p: " + err;
	return nil;
}

# Write then read on one fd: wallet9p's results belong to the fid that
# wrote the request, and another open sees none of them.
transact(path, data: string): (int, string)
{
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return (-1, nil);
	b := array of byte data;
	n := sys->write(fd, b, len b);
	if(n <= 0)
		return (n, nil);
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[8192] of byte;
	r := sys->read(fd, buf, len buf);
	if(r <= 0)
		return (n, "");
	return (n, string buf[0:r]);
}

strip(s: string): string
{
	while(len s > 0 && (s[len s-1] == '\n' || s[len s-1] == ' '))
		s = s[0:len s-1];
	return s;
}

# The address of private key 1
ADDR1: con "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf";

#
# Test: mount exists
#
testMount(t: ref T)
{
	(ok, nil) := sys->stat("/n/wallet/accounts");
	t.assert(ok >= 0, "accounts file served");
}

#
# Test: import a known key and read the address
#
testImportAndAddress(t: ref T)
{
	# Import private key = 1
	(n, name) := transact("/n/wallet/new", "import eth ethereum testkey 0000000000000000000000000000000000000000000000000000000000000001");
	t.assert(n > 0, "write to new succeeded");
	t.log("new account: '" + strip(name) + "'");
	t.assertseq(strip(name), "testkey", "new names the account made");

	addr := strip(readfile("/n/wallet/testkey/address"));
	t.log("address: " + addr);
	t.assertseq(addr, ADDR1, "address derived for private key 1");

	accts := readfile("/n/wallet/accounts");
	t.assert(accts != nil && contains(accts, "testkey"), "accounts lists the account");
}

#
# Test: there is no raw signing oracle.  The sign file, which signed any
# hash written to it, was taken out deliberately: whoever could write it
# could sign anything, bypassing the payment policy.  Payments are
# proposed through pay and authorize instead (tests/wallet_policy_test.b).
#
testSign(t: ref T)
{
	(ok, nil) := sys->stat("/n/wallet/testkey/sign");
	t.assert(ok < 0, "the raw sign file is not served");

	# Hash to sign (keccak256 of "test")
	msg := array of byte "test";
	hash := array[32] of byte;
	kr->keccak256(msg, len msg, hash);
	n := writefile("/n/wallet/testkey/sign", ethcrypto->hexencode(hash));
	t.assert(n < 0, "a hash cannot be signed through the file system");
}

#
# Test: read chain
#
testChain(t: ref T)
{
	chain := strip(readfile("/n/wallet/testkey/chain"));
	t.log("chain: " + chain);
	t.assertseq(chain, "ethereum", "chain is the one the account was made on");
}

contains(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	kr = load Keyring Keyring->PATH;
	ethcrypto = load Ethcrypto "/dis/lib/ethcrypto.dis";
	testing = load Testing Testing->PATH;

	if(testing == nil) {
		sys->fprint(sys->fildes(2), "cannot load testing module: %r\n");
		raise "fail:cannot load testing";
	}
	if(ethcrypto == nil) {
		sys->fprint(sys->fildes(2), "cannot load ethcrypto: %r\n");
		raise "fail:cannot load ethcrypto";
	}

	testing->init();
	ethcrypto->init();

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	# Start factotum and wallet9p
	if((err := startserver()) != nil)
		raise "fail:" + err;

	run("Mount", testMount);
	run("ImportAndAddress", testImportAndAddress);
	run("Sign", testSign);
	run("Chain", testChain);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
