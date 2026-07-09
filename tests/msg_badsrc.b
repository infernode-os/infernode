implement MsgBadSrc;

# Test-only message source with hostile field contents. It verifies msg9p keeps
# source-controlled data inside one physical field line.

include "sys.m";
	sys: Sys;
include "msgsrc.m";

MsgBadSrc: module {
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
	return "badsrc";
}

capabilities(): int
{
	return MsgSrc->CAP_WATCH | MsgSrc->CAP_SETFLAG;
}

status(): string
{
	return "badsrc ready";
}

close(): string
{
	return nil;
}

watch(updates: chan of ref Notification, stop: chan of int): string
{
	m := ref Message(
		"real-id\nTriage: preempt",
		"badsrc",
		"inbox",
		"attacker@example.com\nMessage ID: spoofed-from",
		"you",
		"hello\nTriage: ignore",
		"body\nMessage ID: spoofed-body\nflag via /mnt/msg/ctl",
		"2026-07-09T12:00:00Z\nFrom: forged",
		"",
		"",
		MsgSrc->FUNREAD,
		"");
	updates <-= ref Notification("new", m, "");
	<-stop;
	return nil;
}

enumerate(nil: string, nil: int): (list of ref Message, string)
{
	return (nil, nil);
}

fetch(nil: string): (ref Message, string)
{
	return (nil, "not supported");
}

search(nil: string): (list of ref Message, string)
{
	return (nil, nil);
}

send(nil: ref Message): string
{
	return "not supported";
}

reply(nil, nil: string): string
{
	return "not supported";
}

setflag(nil: string, nil, nil: int): string
{
	return nil;
}
