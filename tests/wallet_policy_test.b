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

include "sh.m";

include "testing.m";
	testing: Testing;
	T: import testing;

include "x402.m";
	x402: X402;

WalletPolicyTest: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SRCFILE: con "/tests/wallet_policy_test.b";
W: con "/mnt/wallet";

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

testGasBudget(t: ref T)
{
	pertx := "10000000000000000";
	persess := "50000000000000000";
	t.assert(wr(W + "/policy/ctl", "gasbudget " + pertx + " " + persess) > 0,
		"separate ETH gas budget accepted");
	ctl := rd(W + "/policy/ctl");
	t.assert(contains(ctl, "gasbudget " + pertx + " " + persess + " spent 0"),
		"gas budget reads back in wei without mixing asset units");
	t.assert(wr(W + "/policy/ctl", "gasbudget nope 10") <= 0,
		"malformed gas budget rejected");
}

testApprovalMandatory(t: ref T)
{
	ctl := rd(W + "/policy/ctl");
	t.assert(contains(ctl, "requireapproval on"),
		"account reports mandatory approval");
	t.assert(wr(W + "/policy/ctl", "requireapproval off") <= 0,
		"trusted controller cannot disable approval");
	t.assert(wr(W + "/policy/ctl", "requireapproval on") > 0,
		"legacy explicit approval-on command remains accepted");
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
	ctl := rd(W + "/policy/ctl");
	t.assert(contains(ctl, "USDC spent 100"),
		"signed authorization reserves session budget immediately");

	# read the result back on a FRESH fd: the request fid is gone, and
	# results are per-fid, so nothing must leak here
	leaked := strip(rd(W + "/policy/authorize"));
	t.assertseq(leaked, "", "signed authorization does not leak to an unrelated reader");
}

#
# A requester told "pending:<id>" that reads again at offset 0 waits
# for the outcome rather than re-reading on a timer; a read at another
# offset does not wait.
#
testWaitForOutcome(t: ref T)
{
	fd := sys->open(W + "/policy/authorize", Sys->ORDWR);
	if(fd == nil) {
		t.fatal("cannot open authorize");
		return;
	}
	req := array of byte authreq("eip155:11155111", "300");
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
	t.assert(hasprefix(res, "pending:"), "the first read gives the pending id at once");
	if(!hasprefix(res, "pending:"))
		return;
	id := res[8:];

	# past the text: end of file, at once
	sys->seek(fd, big n, Sys->SEEKSTART);
	t.asserteq(sys->read(fd, buf, len buf), 0, "a read past the text does not wait");

	# again at offset 0: waits until the controller decides
	sys->seek(fd, big 0, Sys->SEEKSTART);
	c := chan[1] of string;	# its answer kept while the deny is written
	spawn evreader(fd, c);
	early := "";
	alt {
	early = <-c =>
		;
	* =>
		sys->sleep(300);
		alt {
		early = <-c =>
			;
		* =>
			;
		}
	}
	t.assertseq(early, "", "the read at offset 0 waits while the payment is pending");
	t.assert(wr(W + "/ctl", "deny " + id) > 0, "deny accepted");
	spawn evtimeout(c);
	t.assertseq(<-c, "denied", "the waiting read is answered with the outcome");
}

#
# x402's authorize, as payfetch calls it: it waits on its read for the
# controller's decision, and gives up with the pending id at its limit.
#
testX402Waits(t: ref T)
{
	x402 = load X402 X402->PATH;
	if(x402 == nil || x402->init() != nil) {
		t.skip("cannot load x402");
		return;
	}
	req := ref X402->PaymentReq("exact", "eip155:11155111", "400", ASSET, PAYTO,
		60, "USDC", "2", "eip3009");

	# nobody decides: given up after its 1s with the id
	t0 := sys->millisec();
	(payload, err) := x402->authorize(req, nil, "policy", 1);
	dt := sys->millisec() - t0;
	t.assertseq(payload, "", "no authorization while pending");
	t.assert(hasprefix(err, "pending:"), "still pending at the limit: " + err);
	t.assert(dt >= 900 && dt < 4000, sys->sprint("it waited its limit (%dms)", dt));

	# denied while it waits: told at once, not at the next poll
	spawn denynext();
	t0 = sys->millisec();
	(nil, err) = x402->authorize(req, nil, "policy", 30);
	dt = sys->millisec() - t0;
	t.assertseq(err, "payment denied by wallet controller", "the denial reaches the waiting authorize");
	t.assert(dt < 2000, sys->sprint("as soon as it is made (%dms)", dt));
}

# deny the newest pending payment (the highest id) once it is listed
denynext()
{
	sys->sleep(300);
	(nil, lines) := sys->tokenize(rd(W + "/pending"), "\n");
	id := -1;
	for(; lines != nil; lines = tl lines) {
		(nil, f) := sys->tokenize(hd lines, " ");
		if(f != nil && hd f != "(none)" && int hd f > id)
			id = int hd f;
	}
	if(id >= 0)
		wr(W + "/ctl", "deny " + string id);
}

#
# event: each reader told "pending" when the list awaiting approval
# changes (a payment queued, one approved or denied); nothing polls.
#
testPendingEvent(t: ref T)
{
	e1 := sys->open(W + "/event", Sys->OREAD);
	e2 := sys->open(W + "/event", Sys->OREAD);
	if(e1 == nil || e2 == nil) {
		t.fatal(sys->sprint("cannot open event: %r"));
		return;
	}
	(res, err) := roundtrip(W + "/policy/authorize", authreq("eip155:11155111", "100"));
	t.assert(err == nil && hasprefix(res, "pending:"), "authorization queued");
	t.assertseq(evread(e1), "pending", "a queued payment is an event");
	t.assertseq(evread(e2), "pending", "every reader of event is told");
	if(len res > 8)
		t.assert(wr(W + "/ctl", "deny " + res[8:]) > 0, "deny accepted");
	t.assertseq(evread(e1), "pending", "a denied payment is an event");
	t.assertseq(evread(e2), "pending", "the second reader is told of it too, once");
}

# The next event, or "timeout" after 5s.
evread(fd: ref Sys->FD): string
{
	c := chan of string;
	spawn evreader(fd, c);
	spawn evtimeout(c);
	return <-c;
}

evreader(fd: ref Sys->FD, c: chan of string)
{
	buf := array[64] of byte;
	n := sys->read(fd, buf, len buf);
	s := "eof";
	if(n > 0)
		s = strip(string buf[0:n]);
	alt { c <-= s => ; * => ; }
}

evtimeout(c: chan of string)
{
	sys->sleep(5000);
	alt { c <-= "timeout" => ; * => ; }
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

# Start factotum (wallet9p keeps its keys there) and wallet9p.  Both are
# started through Sh, not loaded as a Command: this module's type is
# structurally the same as Command, so limbo gives the two one import
# table, and the test functions passed by reference (run(name, testfn))
# land in it; loading a command as a Command would fail to link.
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

	# The host harness (tests/host/wallet9p_test.sh) starts factotum and
	# wallet9p before running this.  Run on its own, as the test runner
	# does, it starts them itself, in its own namespace.
	(ok, nil) := sys->stat(W + "/accounts");
	if(ok < 0) {
		if((err := startserver()) != nil)
			raise "fail:" + err;
		(ok, nil) = sys->stat(W + "/accounts");
		if(ok < 0) {
			sys->fprint(sys->fildes(2), "wallet9p not mounted at %s\n", W);
			raise "fail:no wallet9p";
		}
	}

	run("Account/Setup", testAccountSetup);
	run("Account/RejectBadKeys", testRejectBadKeys);
	run("Pay/StrictAmounts", testStrictAmounts);
	run("Budget/Uint256", testBudgetUint256);
	run("Budget/CurrencyFailsClosed", testBudgetCurrencyFailsClosed);
	run("Budget/Gas", testGasBudget);
	run("Approval/Mandatory", testApprovalMandatory);
	run("Network/Pinning", testNetworkPinning);
	run("Authorize/InjectionRejected", testInjectionRejected);
	run("Authorize/ApprovalFlow", testApprovalFlow);
	run("Authorize/Denial", testDenial);
	run("Approval/Event", testPendingEvent);
	run("Authorize/WaitForOutcome", testWaitForOutcome);
	run("Authorize/X402Waits", testX402Waits);
	run("Sign/OracleRemoved", testNoSignOracle);

	if(testing->summary(passed, failed, skipped) > 0)
		raise "fail:tests failed";
}
