implement MsgInject;

# Deterministic test: when a message fires, msgwatch (Lucifer mode) injects the
# message-handling POLICY together with the message into activity 0's
# conversation input (fire-time skill loading, not system-prompt bloat).
# Reads one turn from /mnt/ui/activity/0/conversation/input and checks it
# carries both the policy and the message.

include "sys.m";
	sys: Sys;
include "draw.m";

MsgInject: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

fail(msg: string)
{
	sys->print("MSGINJECT: FAIL %s\n", msg);
	raise "fail:msginject";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	# Run directly, the read below would wait for a turn that never comes.
	if(tl args == nil || hd tl args != "msgreader")
		raise "skip:helper for tests/inferno/msg_inject.sh, which runs it";

	fd := sys->open("/mnt/ui/activity/0/conversation/input", Sys->OREAD);
	if(fd == nil)
		fail(sys->sprint("cannot open activity-0 input: %r"));
	buf := array[16384] of byte;
	n := sys->read(fd, buf, len buf);	# blocks until msgwatch relays a turn
	if(n <= 0)
		fail("empty read");
	s := string buf[0:n];
	haspolicy := contains(s, "Message Policy");
	hasmsg := contains(s, "From:") || contains(s, "unread") || contains(s, "Subject");
	hasnoautosend := contains(s, "NEVER auto-send") || contains(s, "never auto-send");
	sys->print("MSGINJECT: len=%d policy=%d message=%d no-auto-send=%d\n", n, haspolicy, hasmsg, hasnoautosend);
	if(haspolicy && hasmsg && hasnoautosend)
		sys->print("MSGINJECT: PASS policy+message injected as one turn, no-auto-send present\n");
	else
		fail(sys->sprint("(policy=%d message=%d no-auto-send=%d)", haspolicy, hasmsg, hasnoautosend));
}

contains(hay, needle: string): int
{
	nl := len needle;
	for(i := 0; i <= len hay - nl; i++)
		if(hay[i:i+nl] == needle)
			return 1;
	return 0;
}
