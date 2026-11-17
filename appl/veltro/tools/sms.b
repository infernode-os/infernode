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
# agents via /mnt/msg/notify. This tool only owns the send path.
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
	# What a call will do, read by the code that will do it: the arguments
	# in the one form exec acts on, what the user must be asked to allow
	# first, or why the arguments are no call.  veltrosrv's approval gate
	# loads this module for it.
	effect: fn(args: string): (string, string, string);
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
		"  number - Recipient phone number, written without spaces\n" +
		"           (international format preferred, e.g. +15551234)\n" +
		"  body   - The message text (everything after the first space-separated token)\n\n" +
		"Examples:\n" +
		"  sms 5551234 On my way, ETA 10\n" +
		"  sms +442071234567 Confirmed for 14:00 tomorrow.\n\n" +
		"The user is asked to allow each message before it is sent.\n\n" +
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
			"The user is asked to allow it first. " +
			"On iOS the user must one-tap Send in the system compose sheet; " +
			"on Android the message goes out directly.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"number\":{\"type\":\"string\"," +
					"\"description\":\"Recipient phone number (international format preferred, e.g. +15551234)\"}," +
				"\"body\":{\"type\":\"string\"," +
					"\"description\":\"The text of the message.\"}" +
			"}," +
			"\"required\":[\"number\",\"body\"]" +
		"}" +
		"}";
}

MAXBODY: con 1600;	# ten messages' worth: longer is not a text message

# Sending is an effect outside the machine, and costs money: it is never
# done on the model's word alone.  effect says what a call would send;
# veltrosrv shows the user that and runs the call only once they allow it.
effect(args: string): (string, string, string)
{
	if(sys == nil)
		return (nil, nil, "sms: not initialized");
	# First token = number, rest = body.
	s := args;
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	i := 0;
	for(; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t')
			break;
	num := s[0:i];
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	body := s[i:];
	while(len body > 0 && (body[len body - 1] == ' ' || body[len body - 1] == '\t' ||
	      body[len body - 1] == '\n' || body[len body - 1] == '\r'))
		body = body[0:len body - 1];
	if(num == "" || body == "")
		return (nil, nil, "sms: usage: sms <number> <body...>");
	(cnum, digits) := plainnumber(num);
	if(cnum == nil)
		return (nil, nil, "sms: not a phone number: write it as digits, with + first for an international one");
	# "+1 555 1234 On my way" was sent to +1, and "555 1234 late" to 555:
	# a short number followed by more digits is a number with spaces in it.
	if(digits < 7 && body[0] >= '0' && body[0] <= '9')
		return (nil, nil, "sms: the number seems to have spaces in it: write it without them (as +15551234), then the message");
	if(len body > MAXBODY)
		return (nil, nil, sys->sprint("sms: the message is %d characters; the most is %d", len body, MAXBODY));
	for(i = 0; i < len body; i++) {
		c := body[i];
		if((c < ' ' && c != '\n') || c == 16r7f)
			return (nil, nil, "sms: the message has a control character in it");
	}
	return (cnum + " " + body, "send a text message (SMS) to " + cnum + ": " + body, nil);
}

exec(args: string): string
{
	(cargs, nil, err) := effect(args);
	if(err != nil)
		return err;
	for(i := 0; i < len cargs && cargs[i] != ' '; i++)
		;
	num := cargs[0:i];
	body := cargs[i+1:];

	fd := sys->open(PHONE_SMS, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("sms: cannot open %s: %r (is /phone bound? bind -a '#f' /phone)",
			PHONE_SMS);

	# Wire to devphone: "send <num> <body>"
	line := "send " + num + " " + body;
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("sms: write to %s failed: %r", PHONE_SMS);

	# The phone has it; whether it went out is the phone's to say.
	return "sms: given to the phone to send to " + num;
}

# A phone number as digits, with + first for an international one; the
# separators people write (- ( ) .) are dropped.  nil for anything else.
plainnumber(num: string): (string, int)
{
	out := "";
	digits := 0;
	for(i := 0; i < len num; i++) {
		c := num[i];
		if(c >= '0' && c <= '9') {
			out[len out] = c;
			digits++;
		} else if(c == '+' && i == 0)
			out[len out] = c;
		else if(c == '-' || c == '(' || c == ')' || c == '.')
			;
		else
			return (nil, 0);
	}
	if(digits < 2 || digits > 15)
		return (nil, 0);
	return (out, digits);
}
