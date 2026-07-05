implement MsgApprovalTest;

include "sys.m";
	sys: Sys;
include "draw.m";

MsgApprovalTest: module {
	init: fn(nil: ref Draw->Context, nil: list of string);
};

fail(s: string)
{
	sys->print("MSGAPPROVAL FAIL: %s\n", s);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[4096] of byte;
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

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	sys->remove("/tmp/veltro/sent/security-test");

	request := "email\nsecurity-test\napproved body";
	if(writefile("/mnt/msg/reply", request) >= 0) {
		fail("request endpoint claimed the message was sent");
		return;
	}
	if(readfile("/tmp/veltro/sent/security-test") != nil) {
		fail("message sent before approval");
		return;
	}
	pending := readfile("/mnt/msg/pending");
	if(pending == nil || len pending < 2 || pending[0:2] != "1 ") {
		fail("pending request ID missing");
		return;
	}
	if(writefile("/mnt/msg/approve", "approve 1") < 0) {
		fail("trusted approval failed");
		return;
	}
	sys->sleep(100);
	if(readfile("/tmp/veltro/sent/security-test") != "approved body") {
		fail("approved immutable body was not sent");
		return;
	}
	if(writefile("/mnt/msg/approve", "approve 1") >= 0) {
		fail("consumed approval replay succeeded");
		return;
	}
	if(readfile("/mnt/msg/pending") != nil) {
		fail("consumed request remains pending");
		return;
	}
	sys->print("MSGAPPROVAL PASS: request, exact approval, consume, replay denial\n");
}
