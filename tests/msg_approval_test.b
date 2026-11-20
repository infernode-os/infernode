implement MsgApprovalTest;

#
# A drafted reply is sent only on an exact trusted approval, once, and
# only to the sender of the message it was drafted against.
#
# pending shows whoever approves the reply's body, and under it whose
# message it answers and its subject, as the source said when the draft
# was made (it showed the id alone: no recipient). If the source then
# numbers its messages anew, so that the id names another message (a
# mailbox after an expunge; mockmail with its shift file), the approval
# is refused and nothing is sent: the approved body went to the sender
# of whatever had that number at approve time. A draft against a message
# the source does not have is refused.
#

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
	sys->remove("/tmp/veltro/sent/1");
	sys->remove(SHIFT);

	if(writefile("/mnt/msg/draft", "email\nsecurity-test\nbody") >= 0) {
		fail("a draft against a message the source does not have was queued");
		return;
	}
	request := "email\n1\napproved body";
	if(writefile("/mnt/msg/draft", request) < 0) {
		fail("draft endpoint rejected safe pending reply");
		return;
	}
	if(readfile("/tmp/veltro/sent/1") != nil) {
		fail("message sent before approval");
		return;
	}
	pending := readfile("/mnt/msg/pending");
	if(pending == nil || len pending < 2 || pending[0:2] != "1 ") {
		fail("pending request ID missing");
		return;
	}
	if(!contains(pending, "1 email 1 13 approved body\n")) {
		fail("pending view did not show the exact immutable body: " + pending);
		return;
	}
	if(pending != "1 email 1 13 approved body\n\tTo: alice@example.com\n\tSubject: Launch date?\n") {
		fail("pending view did not show whose message the reply answers: " + pending);
		return;
	}
	request2 := "email\n1\nchanged-body!";
	if(writefile("/mnt/msg/draft", request2) < 0) {
		fail("second equal-length draft was rejected");
		return;
	}
	pending = readfile("/mnt/msg/pending");
	if(pending == nil || !contains(pending, "2 email 1 13 changed-body!\n")) {
		fail("equal-length proposals were not distinguishable: " + pending);
		return;
	}
	if(writefile("/mnt/msg/approve", "approve 1") < 0) {
		fail("trusted approval failed");
		return;
	}
	sys->sleep(100);
	if(readfile("/tmp/veltro/sent/1") != "approved body") {
		fail("approved immutable body was not sent");
		return;
	}
	if(writefile("/mnt/msg/approve", "approve 1") >= 0) {
		fail("consumed approval replay succeeded");
		return;
	}
	if(readfile("/mnt/msg/pending") != nil) {
		pending = readfile("/mnt/msg/pending");
		if(pending == nil || !contains(pending, "2 email 1 13 changed-body!\n")) {
			fail("approval consumed or changed the other immutable proposal");
			return;
		}
	}
	if(writefile("/mnt/msg/deny", "deny 2") < 0) {
		fail("trusted denial failed");
		return;
	}

	# The message the draft answers is no longer the one with its id.
	sys->remove("/tmp/veltro/sent/1");
	if(writefile("/mnt/msg/draft", "email\n1\nfor alice alone") < 0) {
		fail("third draft was rejected");
		return;
	}
	pending = readfile("/mnt/msg/pending");
	if(pending == nil || !contains(pending, "3 email 1 15 for alice alone\n\tTo: alice@example.com\n")) {
		fail("third draft not pending for alice: " + pending);
		return;
	}
	fd := sys->create(SHIFT, Sys->OWRITE, 8r644);
	if(fd == nil) {
		fail(sys->sprint("cannot make %s: %r", SHIFT));
		return;
	}
	fd = nil;
	n := writefile("/mnt/msg/approve", "approve 3");
	err := sys->sprint("%r");
	sys->sleep(100);
	sent := readfile("/tmp/veltro/sent/1");
	sys->remove(SHIFT);
	if(sent != nil) {
		fail("a reply approved for alice was sent to whoever has her message's number now: " + sent);
		return;
	}
	if(n >= 0 || !contains(err, "no longer the one")) {
		fail("the approval of a reply to a message that has moved was not refused saying so: " + err);
		return;
	}
	if(writefile("/mnt/msg/approve", "approve 3") >= 0) {
		fail("the refused approval was not consumed");
		return;
	}
	sys->print("MSGAPPROVAL PASS: draft, exact approval, consume, replay denial, recipient shown and held\n");
}

SHIFT: con "/tmp/veltro/mockmail.shift";

contains(s, sub: string): int
{
	if(len sub == 0)
		return 1;
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}
