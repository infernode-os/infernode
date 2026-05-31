implement ToolDial;

#
# dial - Place a phone call via /phone/phone (devphone)
#
# Writes "dial <number>" to /phone/phone, which devphone routes to the
# platform bridge:
#   iOS:      UIApplication openURL: tel:<num> (system call-confirmation
#             UI shown; user authorises the call)
#   Android:  TelecomManager.placeCall (planned; lift from Hellaphone)
#   macOS:    logging stub (no cellular radio)
#
# Call state notifications (connected / disconnected) arrive on
# /phone/phone reads — surfaced unified to all agents via /n/msg/notify
# through the phone-events MsgSrc.
#
# Usage:
#   dial <number>
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolDial: module {
	init:   fn(): string;
	name:   fn(): string;
	doc:    fn(): string;
	exec:   fn(args: string): string;
	schema: fn(): string;
};

PHONE_PHONE: con "/phone/phone";

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

name(): string  { return "dial"; }

doc(): string
{
	return "Dial - Place a phone call via /phone/phone\n\n" +
		"Usage:\n" +
		"  dial <number>\n\n" +
		"Arguments:\n" +
		"  number - Phone number to dial (international format preferred, e.g. +1 555 1234)\n\n" +
		"Examples:\n" +
		"  dial 5551234\n" +
		"  dial +442071234567\n\n" +
		"Platform notes:\n" +
		"  iOS:     shows the system call-confirmation UI; the user authorises.\n" +
		"           Cannot dial silently. answer/hangup of cellular calls is not\n" +
		"           permitted (use the system phone UI).\n" +
		"  Android: places the call directly (requires CALL_PHONE grant).\n" +
		"  macOS:   logged only (no cellular radio on a Mac).\n\n" +
		"Requires /phone (bind -a '#f' /phone in the boot profile).";
}

schema(): string
{
	return "{" +
		"\"name\":\"dial\"," +
		"\"description\":\"Place a phone call to a number. On iOS the user must " +
			"confirm the call in the system UI; on Android the call is placed " +
			"directly via the cellular radio.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"number\":{\"type\":\"string\"," +
					"\"description\":\"Phone number to dial (international format preferred, e.g. +1 555 1234)\"}" +
			"}," +
			"\"required\":[\"number\"]" +
		"}" +
		"}";
}

exec(args: string): string
{
	# Single argument: the number. Trim, reject empty.
	s := args;
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	# Trim trailing whitespace too — number must not carry junk.
	while(len s > 0 && (s[len s - 1] == ' ' || s[len s - 1] == '\t' || s[len s - 1] == '\n'))
		s = s[0:len s - 1];
	if(len s == 0)
		return "dial: usage: dial <number>";

	fd := sys->open(PHONE_PHONE, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("dial: cannot open %s: %r (is /phone bound? bind -a '#f' /phone)",
			PHONE_PHONE);

	line := "dial " + s;
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("dial: write to %s failed: %r", PHONE_PHONE);

	return "dial: requested " + s;
}
