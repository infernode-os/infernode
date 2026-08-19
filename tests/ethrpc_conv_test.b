implement EthrpcConvTest;

#
# ethrpc conversion tests: hex/decimal conversions must be
# arbitrary-precision (mainnet balances exceed 2^63 wei) and strict
# (malformed input returns nil, never a wrong number).
#
# Pure functions only — no network access.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "ethrpc.m";
	ethrpc: Ethrpc;

include "testing.m";
	testing: Testing;
	T: import testing;

EthrpcConvTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/ethrpc_conv_test.b";

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

testHextowei(t: ref T)
{
	t.assertseq(ethrpc->hextowei("0x0"), "0", "0x0 -> 0");
	t.assertseq(ethrpc->hextowei("0x"), "0", "0x -> 0");
	t.assertseq(ethrpc->hextowei("0xde0b6b3a7640000"), "1000000000000000000",
		"1 ETH in wei");
	# 10 ETH in wei = 1e19 > 2^63: must not wrap
	t.assertseq(ethrpc->hextowei("0x8AC7230489E80000"), "10000000000000000000",
		"1e19 wei (exceeds int64)");
	# 32-byte word, all ones = 2^256-1
	t.assertseq(ethrpc->hextowei("0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
		"115792089237316195423570985008687907853269984665640564039457584007913129639935",
		"uint256 max");
	# strict: garbage is an error, not zero
	t.assertnil(ethrpc->hextowei("0xzz"), "non-hex rejected");
	t.assertnil(ethrpc->hextowei(""), "empty rejected");
	t.assertnil(ethrpc->hextowei("0x" + "ff" + "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"),
		"overlong hex rejected");
}

testWeitohex(t: ref T)
{
	t.assertseq(ethrpc->weitohex("0"), "0x0", "0 -> 0x0");
	t.assertseq(ethrpc->weitohex("10000000000000000000"), "0x8ac7230489e80000",
		"1e19 -> hex (exceeds int64)");
	t.assertnil(ethrpc->weitohex("1.5"), "fractional rejected");
	t.assertnil(ethrpc->weitohex("-1"), "negative rejected");
	t.assertnil(ethrpc->weitohex(""), "empty rejected");
}

testWeitotoken(t: ref T)
{
	t.assertseq(ethrpc->weitoeth("1000000000000000000"), "1", "1 ETH");
	t.assertseq(ethrpc->weitoeth("1500000000000000000"), "1.5", "1.5 ETH");
	t.assertseq(ethrpc->weitotoken("20000000", 6), "20", "20 USDC");
	t.assertseq(ethrpc->weitotoken("1500000", 6), "1.5", "1.5 USDC");
	t.assertseq(ethrpc->weitotoken("1", 6), "0.000001", "1 base unit");
	# 1e19 wei = 10 ETH: display path must be arbitrary-precision too
	t.assertseq(ethrpc->weitoeth("10000000000000000000"), "10", "10 ETH display");
	t.assertnil(ethrpc->weitotoken("12a45", 6), "garbage rejected");
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

	ethrpc = load Ethrpc Ethrpc->PATH;
	if(ethrpc == nil) {
		sys->fprint(sys->fildes(2), "cannot load ethrpc: %r\n");
		raise "fail:cannot load ethrpc";
	}
	err := ethrpc->init("https://invalid.example");
	if(err != nil) {
		sys->fprint(sys->fildes(2), "ethrpc init: %s\n", err);
		raise "fail:ethrpc init";
	}

	for(a := args; a != nil; a = tl a) {
		if(hd a == "-v")
			testing->verbose(1);
	}

	run("Conv/Hextowei", testHextowei);
	run("Conv/Weitohex", testWeitohex);
	run("Conv/Weitotoken", testWeitotoken);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
