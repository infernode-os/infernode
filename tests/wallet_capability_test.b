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

	spawn runsrv();
	sys->sleep(1500);

	if(writefile("/n/wallet/new", "import eth ethereum captest 0000000000000000000000000000000000000000000000000000000000000001") <= 0 &&
	   !exists("/n/wallet/captest/address")) {
		fail("cannot create test wallet account");
		return;
	}
	writefile("/n/wallet/ctl", "default captest");

	caps := ref NsConstruct->Capabilities("wallet" :: nil, "/n/wallet" :: nil,
		nil, nil, nil, nil, 0, 0, -1, nil, nil);
	sys->pctl(Sys->FORKNS, nil);
	err := nsc->restrictns(caps);
	if(err != nil) {
		fail("restrictns: " + err);
		return;
	}

	if(!exists("/n/wallet/accounts") || !exists("/n/wallet/default") ||
	   !exists("/n/wallet/captest/address") || !exists("/n/wallet/captest/pay") ||
	   !exists("/n/wallet/captest/sign") || !exists("/n/wallet/captest/history")) {
		fail("agent wallet proposal/read surface missing");
		return;
	}

	if(exists("/n/wallet/ctl") || exists("/n/wallet/pending") ||
	   exists("/n/wallet/new") || exists("/n/wallet/captest/ctl")) {
		fail("trusted wallet commit/config files visible");
		return;
	}

	if(writefile("/n/wallet/captest/pay", "1000 0x000000000000000000000000000000000000dEaD") <= 0) {
		fail("agent could not queue wallet payment proposal");
		return;
	}
	pay := readfile("/n/wallet/captest/pay");
	if(pay == nil || len pay < 8 || pay[0:8] != "pending:") {
		fail("wallet payment did not become pending proposal");
		return;
	}
	if(exists("/n/wallet/pending") || exists("/n/wallet/ctl")) {
		fail("commit path visible after payment proposal");
		return;
	}

	sys->print("WALLETCAP PASS: wallet grant exposes proposals but hides commit/config authority\n");
}
