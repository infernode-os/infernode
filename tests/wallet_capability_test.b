implement WalletCapabilityTest;

include "sys.m";
	sys: Sys;
include "draw.m";
include "nsconstruct.m";
	nsc: NsConstruct;
include "sh.m";

WalletCapabilityTest: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

fail(s: string)
{
	sys->print("WALLETCAP FAIL: %s\n", s);
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

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok >= 0;
}

runsrv()
{
	mod := load Command "/dis/veltro/wallet9p.dis";
	if(mod == nil) {
		sys->fprint(sys->fildes(2), "cannot load wallet9p: %r\n");
		return;
	}
	mod->init(nil, "wallet9p" :: nil);
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	nsc = load NsConstruct NsConstruct->PATH;
	if(nsc == nil) {
		fail("load nsconstruct");
		return;
	}
	nsc->init();

	if(!exists("/n") || !exists("/mnt/factotum/ctl"))
		raise "skip:wallet capability driver requires /n and a running factotum (run tests/inferno/wallet_capability.sh)";

	spawn runsrv();
	sys->sleep(1500);

	if(writefile("/n/wallet/new", "import eth ethereum captest 0000000000000000000000000000000000000000000000000000000000000001") <= 0 &&
	   !exists("/n/wallet/captest/address")) {
		fail("cannot create test wallet account");
		return;
	}
	if(writefile("/n/wallet/new", "eth ethereum bad/name") >= 0) {
		fail("wallet accepted unsafe account name");
		return;
	}
	if(writefile("/n/wallet/new", "eth ethereum extra tokens") >= 0) {
		fail("wallet accepted extra account creation tokens");
		return;
	}
	if(writefile("/n/wallet/ctl", "default bad/name") >= 0) {
		fail("wallet accepted unsafe default account name");
		return;
	}
	writefile("/n/wallet/ctl", "default captest");
	if(writefile("/n/wallet/captest/pay", "1000 0x000000000000000000000000000000000000dEaD") <= 0) {
		fail("trusted setup could not queue wallet payment proposal");
		return;
	}
	if(writefile("/n/wallet/ctl", "deny 1 trailing") >= 0) {
		fail("wallet accepted trailing tokens on pending denial");
		return;
	}
	if(writefile("/n/wallet/ctl", "deny 1") <= 0) {
		fail("wallet rejected exact pending denial");
		return;
	}

	caps := ref NsConstruct->Capabilities("wallet" :: nil, "/n/wallet" :: nil,
		nil, nil, nil, nil, 0, 0, -1, nil, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil) {
		fail("restrictns: " + err);
		return;
	}

	if(!exists("/n/wallet/accounts") || !exists("/n/wallet/default") ||
	   !exists("/n/wallet/network") ||
	   !exists("/n/wallet/captest/address") || !exists("/n/wallet/captest/pay") ||
	   !exists("/n/wallet/captest/authorize") || !exists("/n/wallet/captest/history")) {
		fail("agent wallet proposal/read surface missing");
		return;
	}

	if(exists("/n/wallet/ctl") || exists("/n/wallet/pending") ||
	   exists("/n/wallet/new") || exists("/n/wallet/captest/ctl") ||
	   exists("/n/wallet/captest/sign")) {
		fail("trusted wallet commit/config files visible");
		return;
	}
	if(writefile("/n/wallet/captest/sign",
	    "9c22ff5f21f0b81b113e63f7db6da94fedef11b2119b4088b89664fb9a3cb658") >= 0) {
		fail("wallet grant allowed raw hash signing");
		return;
	}

	# Master's grammar assertions: the wallet must reject a non-decimal
	# amount and an unsafe recipient outright.
	if(writefile("/n/wallet/captest/pay", "abc 0x000000000000000000000000000000000000dEaD") >= 0) {
		fail("wallet accepted non-decimal payment amount");
		return;
	}
	if(writefile("/n/wallet/captest/pay", "1000 not-an-address") >= 0) {
		fail("wallet accepted unsafe payment recipient");
		return;
	}

	# Results are bound to the writing fid (a shared account-level
	# result would hand one agent's txhash or signed authorization to
	# another), so the proposal must be written and read on ONE fd.
	pfd := sys->open("/n/wallet/captest/pay", Sys->ORDWR);
	if(pfd == nil) {
		fail("agent could not open wallet pay file");
		return;
	}
	pcmd := array of byte "1000 0x000000000000000000000000000000000000dEaD";
	if(sys->write(pfd, pcmd, len pcmd) <= 0) {
		fail("agent could not queue wallet payment proposal");
		return;
	}
	pbuf := array[1024] of byte;
	sys->seek(pfd, big 0, Sys->SEEKSTART);
	pn := sys->read(pfd, pbuf, len pbuf);
	pay := "";
	if(pn > 0)
		pay = string pbuf[0:pn];
	if(pay == nil || len pay < 8 || pay[0:8] != "pending:") {
		fail("wallet payment did not become pending proposal");
		return;
	}
	# A reader that did not submit the proposal must see nothing.
	leak := readfile("/n/wallet/captest/pay");
	if(leak != nil && len leak > 0 && leak[0] != '\n') {
		fail("pay result leaked to an unrelated reader");
		return;
	}
	if(exists("/n/wallet/pending") || exists("/n/wallet/ctl")) {
		fail("commit path visible after payment proposal");
		return;
	}

	sys->print("WALLETCAP PASS: wallet grant exposes proposals but hides commit/config/sign authority\n");
}
