implement ToolSms;

#
# sms - Send an SMS via /phone/sms (devphone)
#
# Writes "send <number> <body>" to /phone/sms, which devphone routes to
# the platform bridge:
#   iOS:      MFMessageComposeViewController (assisted compose — user
#             one-taps Send; a real cellular SMS goes out)
#   Android:  SmsManager (planned; lift from Plan9-Archive/hellaphone)
#   macOS:    logging stub (dev sandbox)
#
# Inbound SMS — when the platform supports it (Android, gateways) — is
# exposed by the sms MsgSrc on top of /phone/sms reads, surfaced to all
# agents via /n/msg/notify. This tool only owns the send path.
#
# Usage:
#   sms <number> <body...>
#
# Examples:
#   sms 5551234 On my way, ETA 10
#   sms +442071234567 Confirmed for 14:00 tomorrow.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolSms: module {
	init:   fn(): string;
	name:   fn(): string;
	doc:    fn(): string;
	exec:   fn(args: string): string;
	schema: fn(): string;
};

PHONE_SMS: con "/phone/sms";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	return nil;
}

name(): string  { return "sms"; }

doc(): string
{
	return "Sms - Send a text message (SMS) via /phone/sms\n\n" +
		"Usage:\n" +
		"  sms <number> <body...>\n\n" +
		"Arguments:\n" +
		"  number - Recipient phone number (international format preferred, e.g. +1 555 1234)\n" +
		"  body   - The message text (everything after the first space-separated token)\n\n" +
		"Examples:\n" +
		"  sms 5551234 On my way, ETA 10\n" +
		"  sms +442071234567 Confirmed for 14:00 tomorrow.\n\n" +
		"Platform notes:\n" +
		"  iOS:     opens the system compose sheet pre-filled with number and body;\n" +
		"           the user one-taps Send. Cannot send silently.\n" +
		"  Android: sends directly via the cellular radio (requires SEND_SMS grant).\n" +
		"  macOS:   logged only (no cellular radio on a Mac).\n\n" +
		"Requires /phone (bind -a '#f' /phone in the boot profile).";
}

schema(): string
{
	return "{" +
		"\"name\":\"sms\"," +
		"\"description\":\"Send a text message (SMS) to a phone number. " +
			"On iOS the user must one-tap Send in the system compose sheet; " +
			"on Android the message goes out directly.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"number\":{\"type\":\"string\"," +
					"\"description\":\"Recipient phone number (international format preferred, e.g. +1 555 1234)\"}," +
				"\"body\":{\"type\":\"string\"," +
					"\"description\":\"The text of the message.\"}" +
			"}," +
			"\"required\":[\"number\",\"body\"]" +
		"}" +
		"}";
}

exec(args: string): string
{
	# Tools receive a single space-joined string. First token = number,
	# rest = body. Trim leading whitespace; reject empty input.
	s := args;
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	if(len s == 0)
		return "sms: usage: sms <number> <body...>";

	# Split into <number> <body>.
	num := "";
	i := 0;
	for(; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t')
			break;
	num = s[0:i];
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	body := s[i:];
	if(num == "" || body == "")
		return "sms: usage: sms <number> <body...>";

	fd := sys->open(PHONE_SMS, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("sms: cannot open %s: %r (is /phone bound? bind -a '#f' /phone)",
			PHONE_SMS);

	# Wire to devphone: "send <num> <body>"
	line := "send " + num + " " + body;
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("sms: write to %s failed: %r", PHONE_SMS);

	return "sms: queued to " + num;
}
