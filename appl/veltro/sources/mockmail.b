implement MockMail;

#
# mockmail - a canned message source for the eval harness (INFR-364).
#
# Implements the MsgSrc interface with a fixed set of unread "email" messages
# so the delegation harness can exercise an end-to-end "check my email and
# summarize" task without a live IMAP account. status() returns a human-readable
# unread summary (so an agent can summarize from one non-blocking read), and
# watch() pushes the same messages as notifications. Testing-only.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "msgsrc.m";

MockMail: module {
	init:    fn(config: string): string;
	name:    fn(): string;
	capabilities: fn(): int;
	status:  fn(): string;
	close:   fn(): string;
	watch:   fn(updates: chan of ref MsgSrc->Notification, stop: chan of int): string;
	enumerate: fn(channel: string, count: int): (list of ref MsgSrc->Message, string);
	fetch:   fn(id: string): (ref MsgSrc->Message, string);
	search:  fn(query: string): (list of ref MsgSrc->Message, string);
	send:    fn(msg: ref MsgSrc->Message): string;
	reply:   fn(origid, body: string): string;
	setflag: fn(id: string, flag, add: int): string;
};

Message: import MsgSrc;
Notification: import MsgSrc;

init(nil: string): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "email";
}

capabilities(): int
{
	return MsgSrc->CAP_WATCH | MsgSrc->CAP_ENUMERATE | MsgSrc->CAP_FETCH | MsgSrc->CAP_SETFLAG;
}

# Canned unread inbox.
msgs(): list of ref Message
{
	m3 := ref Message("3", "email", "inbox", "newsletter@inferno.news", "you",
		"Weekly digest", "Top stories: Dis VM gains a new JIT; 9P turns 30; community call Thursday.",
		"2026-06-30T07:15:00Z", "", "", MsgSrc->FUNREAD, "");
	m2 := ref Message("2", "email", "inbox", "accounts@vendor.example", "you",
		"Invoice #4471 due", "Your May invoice ($420) is attached and due in 14 days. Reply with any questions.",
		"2026-06-30T08:40:00Z", "", "", MsgSrc->FUNREAD, "");
	m1 := ref Message("1", "email", "inbox", "alice@example.com", "you",
		"Launch date?", "Hi — can we move the launch to Friday? I need your sign-off by end of day.",
		"2026-06-30T09:05:00Z", "", "", MsgSrc->FUNREAD, "");
	return m1 :: m2 :: m3 :: nil;
}

status(): string
{
	s := "3 unread (mock):";
	for(ml := msgs(); ml != nil; ml = tl ml) {
		m := hd ml;
		s += sys->sprint("\n  [%s] %s — %s: %s", m.id, m.sender, m.subject, m.body);
	}
	return s;
}

close(): string
{
	return nil;
}

# Push the canned unread messages once, then idle until stopped.
watch(updates: chan of ref Notification, stop: chan of int): string
{
	for(ml := msgs(); ml != nil; ml = tl ml)
		updates <-= ref Notification("new", hd ml, "");
	<-stop;
	return nil;
}

enumerate(nil: string, count: int): (list of ref Message, string)
{
	if(count <= 0)
		return (msgs(), nil);
	out: list of ref Message;
	n := 0;
	for(ml := msgs(); ml != nil && n < count; ml = tl ml) {
		out = hd ml :: out;
		n++;
	}
	# reverse to preserve order
	rev: list of ref Message;
	for(; out != nil; out = tl out)
		rev = hd out :: rev;
	return (rev, nil);
}

fetch(id: string): (ref Message, string)
{
	for(ml := msgs(); ml != nil; ml = tl ml)
		if((hd ml).id == id)
			return (hd ml, nil);
	return (nil, "no such message: " + id);
}

search(nil: string): (list of ref Message, string)
{
	return (nil, nil);
}

send(nil: ref Message): string
{
	return "mockmail: send not supported";
}

reply(nil, nil: string): string
{
	return "mockmail: reply not supported";
}

setflag(nil: string, nil, nil: int): string
{
	# Mock: marking seen is a no-op.
	return nil;
}
