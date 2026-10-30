implement MsgApprovalTest;

include "sys.m";
	sys: Sys;
include "draw.m";

MsgApprovalTest: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

fail(s: string)
{
	sys->print("MSGAPPROVAL FAIL: %s\n", s);
	raise "fail:msgapproval";
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

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	# Run directly, it would write a draft into whatever is at
	# /mnt/msg/draft, which with no msg9p there is a file in the host tree.
	if(tl args == nil || hd tl args != "check")
		raise "skip:helper for tests/inferno/msg_approval.sh, which runs it";
	sys->remove("/tmp/veltro/sent/security-test");

	request := "email\nsecurity-test\napproved body";
	if(writefile("/mnt/msg/draft", request) < 0) {
		fail("draft endpoint rejected safe pending reply");
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
	if(pending != "1 email security-test 13 approved body\n") {
		fail("pending view did not show the exact immutable body: " + pending);
		return;
	}
	request2 := "email\nsecurity-test\nchanged-body!";
	if(writefile("/mnt/msg/draft", request2) < 0) {
		fail("second equal-length draft was rejected");
		return;
	}
	pending = readfile("/mnt/msg/pending");
	if(pending == nil || !contains(pending, "2 email security-test 13 changed-body!\n")) {
		fail("equal-length proposals were not distinguishable: " + pending);
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
		pending = readfile("/mnt/msg/pending");
		if(pending == nil || !contains(pending, "2 email security-test 13 changed-body!\n")) {
			fail("approval consumed or changed the other immutable proposal");
			return;
		}
	}
	if(writefile("/mnt/msg/deny", "deny 2") < 0) {
		fail("trusted denial failed");
		return;
	}
	sys->print("MSGAPPROVAL PASS: draft, exact approval, consume, replay denial\n");
}

contains(s, sub: string): int
{
	if(len sub == 0)
		return 1;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}
