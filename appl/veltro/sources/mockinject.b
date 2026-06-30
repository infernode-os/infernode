implement MockInject;

#
# mockinject - an injectable message source for the event-driven message
# evaluation. Reads ONE message from a scenario file and delivers it through the
# real msg9p -> triage -> msgwatch bus, so a harness can drive a specific
# incoming message and observe how the agent triages, delegates, and drafts a
# reply. Testing-only.
#
# Scenario file format (default /tmp/veltro/scenario.txt; override via the
# register config arg):
#   SENDER: alice@example.com
#   SUBJECT: Launch date?
#   FLAGS: 3                 # MsgSrc flag bitmask (FUNREAD|FFLAGGED|FURGENT|FDRAFT)
#   HEADERS: List-Unsubscribe: <...>   # optional, single line
#   BODY:
#   <everything after BODY: is the message body>
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "msgsrc.m";

MockInject: module {
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

scenariofile := "/tmp/veltro/scenario.txt";

init(config: string): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	bufio = load Bufio Bufio->PATH;
	if(bufio == nil)
		return "cannot load Bufio";
	if(config != nil && config != "")
		scenariofile = config;
	return nil;
}

name(): string
{
	return "email";
}

capabilities(): int
{
	return MsgSrc->CAP_WATCH | MsgSrc->CAP_ENUMERATE | MsgSrc->CAP_FETCH;
}

# Parse the scenario file into a single Message.
readscenario(): ref Message
{
	iob := bufio->open(scenariofile, Bufio->OREAD);
	if(iob == nil)
		return nil;
	sender := "";
	subject := "";
	headers := "";
	flags := MsgSrc->FUNREAD;
	body := "";
	inbody := 0;
	for(;;) {
		line := iob.gets('\n');
		if(line == nil)
			break;
		if(inbody) {
			body += line;
			continue;
		}
		# strip trailing newline
		if(len line > 0 && line[len line - 1] == '\n')
			line = line[0:len line - 1];
		(k, v) := splitkv(line);
		case k {
		"SENDER" =>	sender = v;
		"SUBJECT" =>	subject = v;
		"HEADERS" =>	headers = v;
		"FLAGS" =>	flags = int v;
		"BODY" =>	inbody = 1;
		}
	}
	# trim a trailing newline on the body
	while(len body > 0 && (body[len body - 1] == '\n' || body[len body - 1] == '\r'))
		body = body[0:len body - 1];
	if(sender == "" && subject == "" && body == "")
		return nil;
	return ref Message("1", "email", "inbox", sender, "you", subject, body,
		"2026-06-30T09:00:00Z", "", "", flags, headers);
}

splitkv(line: string): (string, string)
{
	for(i := 0; i < len line; i++)
		if(line[i] == ':') {
			k := line[0:i];
			v := line[i+1:];
			# trim one leading space on the value
			if(len v > 0 && v[0] == ' ')
				v = v[1:];
			return (k, v);
		}
	return (line, "");
}

status(): string
{
	m := readscenario();
	if(m == nil)
		return "no scenario";
	return sys->sprint("1 message: %s — %s", m.sender, m.subject);
}

close(): string
{
	return nil;
}

# Deliver the scenario message once, then idle.
watch(updates: chan of ref Notification, stop: chan of int): string
{
	m := readscenario();
	if(m != nil) {
		sys->sleep(1500);
		updates <-= ref Notification("new", m, "");
	}
	<-stop;
	return nil;
}

enumerate(nil: string, nil: int): (list of ref Message, string)
{
	m := readscenario();
	if(m == nil)
		return (nil, nil);
	return (m :: nil, nil);
}

fetch(id: string): (ref Message, string)
{
	m := readscenario();
	if(m != nil && m.id == id)
		return (m, nil);
	return (nil, "no such message: " + id);
}

search(nil: string): (list of ref Message, string)
{
	return (nil, nil);
}

send(nil: ref Message): string
{
	return "mockinject: send not supported";
}

reply(origid, body: string): string
{
	# Capture any outgoing reply to a sink (never-auto-send check).
	dfd := sys->create("/tmp/veltro/sent", Sys->OREAD, 8r700 | Sys->DMDIR);
	if(dfd != nil)
		dfd = nil;
	fd := sys->create("/tmp/veltro/sent/" + origid, Sys->OWRITE, 8r644);
	if(fd == nil)
		return sys->sprint("mockinject: cannot capture reply: %r");
	b := array of byte body;
	sys->write(fd, b, len b);
	fd = nil;
	return nil;
}

setflag(nil: string, nil, nil: int): string
{
	return nil;
}
