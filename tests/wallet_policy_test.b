implement WalletPolicyTest;

#
# wallet9p policy surface: budgets, approval queue, x402 authorization,
# network pinning, and per-fid result isolation.
#
# Everything here is offline — no RPC endpoint is contacted. Payment
# EXECUTION needs a chain, so these tests exercise the paths that must
# reject or queue before any RPC call happens, plus the authorize
# signing path (which is pure local crypto).
#
# Results from pay/authorize are bound to the WRITING fid, so every
# round trip below uses one ORDWR fd (write, seek 0, read). That is the
# contract: a reader that did not submit the request never sees another
# principal's txhash or signed authorization.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "testing.m";
	testing: Testing;
	T: import testing;

WalletPolicyTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

SRCFILE: con "/tests/wallet_policy_test.b";
W: con "/n/wallet";

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

# ── helpers ──────────────────────────────────────────────────

# write to a path, return bytes written (<0 on error)
wr(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

rd(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	return string buf[0:n];
}

# One-fid round trip: write the request, read the result back on the
# same fd. Returns ("", err) if the write itself was refused.
roundtrip(path, data: string): (string, string)
{
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return ("", sys->sprint("open %s: %r", path));
	b := array of byte data;
	if(sys->write(fd, b, len b) <= 0)
		return ("", sys->sprint("%r"));
	buf := array[4096] of byte;
	sys->seek(fd, big 0, Sys->SEEKSTART);
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return ("", "no result");
	return (strip(string buf[0:n]), nil);
}

strip(s: string): string
{
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == '\r' ||
			    s[len s - 1] == ' '))
		s = s[0:len s - 1];
	return s;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

contains(s, sub: string): int
{
	if(len sub > len s)
		return 0;
	for(i := 0; i <= len s - len sub; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

ASSET: con "0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238";	# Sepolia USDC
PAYTO: con "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf";

authreq(network, amount: string): string
{
	return "scheme exact\n" +
		"network " + network + "\n" +
		"asset " + ASSET + "\n" +
		"payto " + PAYTO + "\n" +
		"amount " + amount + "\n" +
		"timeout 60\n" +
		"name USDC\n" +
		"version 2\n";
}

# ── tests ────────────────────────────────────────────────────

testAccountSetup(t: ref T)
{
	# privkey = 1 -> a known address
	wr(W + "/new", "import eth ethereum policy 0000000000000000000000000000000000000000000000000000000000000001");
	addr := strip(rd(W + "/policy/address"));
	t.assertseq(addr, PAYTO, "address derived for privkey=1");

	net := rd(W + "/network");
	t.assert(contains(net, "caip2 eip155:11155111"), "network file reports CAIP-2 id");
}

testRejectBadKeys(t: ref T)
{
	# scalar 0 is not a valid secp256k1 key
	n := wr(W + "/new", "import eth ethereum zerokey 0000000000000000000000000000000000000000000000000000000000000000");
	t.assert(n <= 0, "zero private key rejected");
	# scalar >= n (curve order) is not valid either
	n = wr(W + "/new", "import eth ethereum bigkey fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141");
	t.assert(n <= 0, "key equal to curve order rejected");
}

testStrictAmounts(t: ref T)
{
	t.assert(wr(W + "/policy/pay", "1.5 " + PAYTO) <= 0, "fractional amount rejected");
	t.assert(wr(W + "/policy/pay", "1e18 " + PAYTO) <= 0, "exponent notation rejected");
	t.assert(wr(W + "/policy/pay", "10 USDC " + PAYTO) <= 0, "unit suffix rejected");
	t.assert(wr(W + "/policy/pay", "1000 notanaddress") <= 0, "bad recipient rejected");
}

#
# Budgets are uint256: a wei-denominated ETH limit passes 2^63 at 9.3
# ETH. An int64 budget parser rejected any such limit outright and
# left the account with NO cap — a fail-open configuration surprise.
#
testBudgetUint256(t: ref T)
{
	oneEth := "1000000000000000000";		# 10^18, 19 digits
	fiveEth := "5000000000000000000";
	t.assert(wr(W + "/policy/ctl", "budget " + oneEth + " " + fiveEth + " ETH") > 0,
		"1 ETH / 5 ETH wei budget accepted (19-digit limits)");

	ctl := rd(W + "/policy/ctl");
	t.assert(contains(ctl, "budget " + oneEth + " " + fiveEth + " ETH"),
		"budget reads back at full precision");

	# over the per-tx cap by 1 wei
	t.assert(wr(W + "/policy/pay", "1000000000000000001 " + PAYTO) <= 0,
		"payment 1 wei over the per-tx cap rejected");

	# a 10 ETH payment is over cap and must not be silently allowed
	t.assert(wr(W + "/policy/pay", "10000000000000000000 " + PAYTO) <= 0,
		"10 ETH payment over cap rejected (exceeds int64)");
}

testBudgetCurrencyFailsClosed(t: ref T)
{
	# budget is in ETH; a USDC-denominated x402 request cannot be
	# evaluated against it and must be refused, not waved through
	(nil, err) := roundtrip(W + "/policy/authorize", authreq("eip155:11155111", "100"));
	t.assert(err != nil, "USDC authorization against an ETH budget refused");
}

testNetworkPinning(t: ref T)
{
	wr(W + "/policy/ctl", "budget 500 2000 USDC");
	(nil, err) := roundtrip(W + "/policy/authorize", authreq("eip155:1", "100"));
	t.assert(err != nil, "authorization naming a different chain refused");

	# unparseable network must fail closed too (it used to default to
	# mainnet, which passed the pin check whenever we were on mainnet)
	(nil, err2) := roundtrip(W + "/policy/authorize", authreq("garbage", "100"));
	t.assert(err2 != nil, "authorization with an unparseable network refused");
}

#
# The authorize protocol is line-oriented, and its fields come from a
# remote server's 402 response. A newline smuggled into any field must
# not be able to inject a second payto/amount line: wallet9p rejects
# duplicate keys outright.
#
testInjectionRejected(t: ref T)
{
	evil := "scheme exact\n" +
		"network eip155:11155111\n" +
		"asset " + ASSET + "\n" +
		"payto " + PAYTO + "\n" +
		"amount 100\n" +
		"timeout 60\n" +
		"name USDC\n" +
		"version 2\n" +
		"payto 0x000000000000000000000000000000000000dEaD\n" +
		"amount 999999999\n";
	(nil, err) := roundtrip(W + "/policy/authorize", evil);
	t.assert(err != nil, "duplicate payto/amount lines rejected (no last-wins override)");

	unknown := authreq("eip155:11155111", "100") + "extrafield whatever\n";
	(nil, err2) := roundtrip(W + "/policy/authorize", unknown);
	t.assert(err2 != nil, "unknown field rejected");
}

#
# Approval queue: an authorization is queued, visible to the trusted
# controller, and only signed once approved.
#
testApprovalFlow(t: ref T)
{
	(res, err) := roundtrip(W + "/policy/authorize", authreq("eip155:11155111", "100"));
	t.assert(err == nil, "authorization accepted for queueing");
	t.assert(hasprefix(res, "pending:"), "authorization queued pending approval");
	id := res[8:];

	pend := rd(W + "/pending");
	t.assert(contains(pend, "x402"), "pending list shows the x402 request");
	t.assert(contains(pend, "eip155:11155111"),
		"pending list shows the network being authorized");

	t.assert(wr(W + "/ctl", "approve " + id) > 0, "approve accepted");

	# read the result back on a FRESH fd: the request fid is gone, and
	# results are per-fid, so nothing must leak here
	leaked := strip(rd(W + "/policy/authorize"));
	t.assertseq(leaked, "", "signed authorization does not leak to an unrelated reader");
}

#
# Denial and expiry are reported to the requester on its own fid.
#
testDenial(t: ref T)
{
	fd := sys->open(W + "/policy/authorize", Sys->ORDWR);
	if(fd == nil) {
		t.fatal("cannot open authorize");
		return;
	}
	req := array of byte authreq("eip155:11155111", "200");
	if(sys->write(fd, req, len req) <= 0) {
		t.fatal("authorize write refused");
		return;
	}
	buf := array[4096] of byte;
	sys->seek(fd, big 0, Sys->SEEKSTART);
	n := sys->read(fd, buf, len buf);
	res := "";
	if(n > 0)
		res = strip(string buf[0:n]);
	t.assert(hasprefix(res, "pending:"), "second authorization queued");
	id := res[8:];

	t.assert(wr(W + "/ctl", "deny " + id) > 0, "deny accepted");

	# same fid: the requester learns the outcome
	sys->seek(fd, big 0, Sys->SEEKSTART);
	n = sys->read(fd, buf, len buf);
	out := "";
	if(n > 0)
		out = strip(string buf[0:n]);
	t.assertseq(out, "denied", "denied authorization reports denied on the requesting fid");
}

#
# The raw signing oracle must not exist at all. It signed any 32-byte
# hash with the spend key, bypassing budget and approval entirely.
#
testNoSignOracle(t: ref T)
{
	(ok, nil) := sys->stat(W + "/policy/sign");
	t.assert(ok < 0, "the raw sign file is not served");
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

	# wallet9p must already be mounted at /n/wallet (the host harness
	# starts factotum and the server before running this).
	(ok, nil) := sys->stat(W + "/accounts");
	if(ok < 0) {
		sys->fprint(sys->fildes(2), "wallet9p not mounted at %s\n", W);
		raise "fail:no wallet9p";
	}

	run("Account/Setup", testAccountSetup);
	run("Account/RejectBadKeys", testRejectBadKeys);
	run("Pay/StrictAmounts", testStrictAmounts);
	run("Budget/Uint256", testBudgetUint256);
	run("Budget/CurrencyFailsClosed", testBudgetCurrencyFailsClosed);
	run("Network/Pinning", testNetworkPinning);
	run("Authorize/InjectionRejected", testInjectionRejected);
	run("Authorize/ApprovalFlow", testApprovalFlow);
	run("Authorize/Denial", testDenial);
	run("Sign/OracleRemoved", testNoSignOracle);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
