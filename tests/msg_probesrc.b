implement MsgProbeSrc;

# Test-only message source for tests/msg9p_stream_test.b. Its config
# chooses what it notifies of:
#	mode=three	three messages A, B, C at once
#	mode=big	after 600ms a message BIG with a subject of 20000
#			characters, then a message AFTERBIG
#	mode=flood	messages without end, until told to stop

include "sys.m";
	sys: Sys;
include "msgsrc.m";

MsgProbeSrc: module {
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

mode: string;

init(config: string): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	mode = config;
	return nil;
}

name(): string
{
	return "probe";
}

capabilities(): int
{
	return MsgSrc->CAP_WATCH;
}

status(): string
{
	return "probe " + mode;
}

close(): string
{
	return nil;
}

mk(id, subj: string): ref Message
{
	return ref Message(id, "probe", "inbox", "alice@example.com", "me", subj,
		"body of " + id, "2026-01-01T00:00:00Z", "", "", MsgSrc->FUNREAD, "");
}

watch(updates: chan of ref Notification, stop: chan of int): string
{
	case mode {
	"mode=three" =>
		updates <-= ref Notification("new", mk("A", "first"), "");
		updates <-= ref Notification("new", mk("B", "second"), "");
		updates <-= ref Notification("new", mk("C", "third"), "");
	"mode=big" =>
		sys->sleep(600);
		s := "";
		for(i := 0; i < 20000; i++)
			s[len s] = 'S';
		updates <-= ref Notification("new", mk("BIG", s), "");
		updates <-= ref Notification("new", mk("AFTERBIG", "small"), "");
	"mode=flood" =>
		for(i := 0;; i++)
			alt {
			updates <-= ref Notification("new", mk("F" + string i, "flood"), "") =>
				;
			<-stop =>
				return nil;
			}
	}
	<-stop;
	return nil;
}

enumerate(nil: string, nil: int): (list of ref Message, string)
{
	return (nil, nil);
}

fetch(nil: string): (ref Message, string)
{
	return (nil, "probe: no messages kept");
}

search(nil: string): (list of ref Message, string)
{
	return (nil, nil);
}

send(nil: ref Message): string
{
	return "probe: send not supported";
}

reply(nil, nil: string): string
{
	return "probe: reply not supported";
}

setflag(nil: string, nil, nil: int): string
{
	return nil;
}
