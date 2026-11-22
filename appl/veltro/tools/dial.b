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
# /phone/phone reads — surfaced unified to all agents via /mnt/msg/notify
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
	# What a call will do, read by the code that will do it: the number in
	# the one form exec dials, what the user must be asked to allow first,
	# or why it is not a number.  veltrosrv's approval gate loads this
	# module for it.
	effect: fn(args: string): (string, string, string);
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
		"  number - Phone number to dial (international format preferred, e.g. +1 555 1234).\n" +
		"           A plain number only: digits, with + first for an international one.\n\n" +
		"Examples:\n" +
		"  dial 5551234\n" +
		"  dial +442071234567\n\n" +
		"The user is asked to allow each call before it is placed.\n\n" +
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
		"\"description\":\"Place a phone call to a plain phone number. The user is " +
			"asked to allow it first. On iOS the user must " +
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

# A call is an effect outside the machine: it is never placed on the
# model's word alone.  effect says what would be dialled; veltrosrv shows
# the user that and runs the call only once they allow it.  And only a
# plain number is dialled: the string went to the phone as it came, where
# "tel:" takes more than numbers (**21*...# forwards the user's calls,
# *#06# and its kind are commands to the handset, a , or ; sends tones
# after the call connects), and a newline began a second command.
effect(args: string): (string, string, string)
{
	if(sys == nil)
		return (nil, nil, "dial: not initialized");
	s := args;
	while(len s > 0 && (s[0] == ' ' || s[0] == '\t'))
		s = s[1:];
	while(len s > 0 && (s[len s - 1] == ' ' || s[len s - 1] == '\t' || s[len s - 1] == '\n'))
		s = s[0:len s - 1];
	if(len s == 0)
		return (nil, nil, "dial: usage: dial <number>");
	num := plainnumber(s);
	if(num == nil)
		return (nil, nil, "dial: only a plain phone number is dialled: digits, with + first " +
			"for an international one (no *, #, pauses or letters)");
	return (num, "place a phone call to " + num, nil);
}

exec(args: string): string
{
	(num, nil, err) := effect(args);
	if(err != nil)
		return err;

	fd := sys->open(PHONE_PHONE, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("dial: cannot open %s: %r (is /phone bound? bind -a '#f' /phone)",
			PHONE_PHONE);

	line := "dial " + num;
	b := array of byte line;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("dial: write to %s failed: %r", PHONE_PHONE);

	return "dial: requested " + num;
}

# A phone number as digits, with + first for an international one; the
# separators people write (blank - ( ) .) are dropped.  nil for anything
# else, and for what is too short or too long to be a number (E.164: 15).
plainnumber(s: string): string
{
	out := "";
	digits := 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if(c >= '0' && c <= '9') {
			out[len out] = c;
			digits++;
		} else if(c == '+' && out == "")
			out[len out] = c;
		else if(c == ' ' || c == '-' || c == '(' || c == ')' || c == '.')
			;
		else
			return nil;
	}
	if(digits < 2 || digits > 15)
		return nil;
	return out;
}
