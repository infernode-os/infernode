implement ToolHear;

#
# hear - what the user says next, for a Veltro agent, through speech(4)
#
#	hear [ms]
#
# The tool asks (/mnt/speech/ask) and waits, up to ms (30000), for the
# user to speak: they press the microphone key, or push to talk, and the
# words of that utterance are the answer.  It does not open the
# microphone: an agent hears only what the user chooses to say once it
# has asked, never what was said before or to something else, unless
# the user has let agents open the microphone themselves (Settings,
# Speech).  While it waits, /mnt/speech/talk reads "off asked", so the
# microphone's indicator can show that something wants an answer.
#
# This tool's grant is ask alone: not listen, talk or ctl.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "../tool.m";

ToolHear: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

SPEECH_ASK: con "/mnt/speech/ask";
Defms: con 30000;
Maxms: con 120000;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "hear";
}

doc(): string
{
	return "Hear - What the user says next (speech-to-text)\n\n" +
		"Usage:\n" +
		"  hear                       Wait up to 30 s for the user to speak\n" +
		"  hear <ms>                  Wait up to ms (at most 120000)\n\n" +
		"The user answers by pressing the microphone key and speaking;\n" +
		"you get the words of what they say. Ask them first (say), since\n" +
		"nothing is heard unless they choose to answer.\n\n" +
		"Requires speech(4) at /mnt/speech.";
}

schema(): string
{
	return "{" +
		"\"name\":\"hear\"," +
		"\"description\":\"Wait for the user to answer aloud: they press the microphone key and speak, and you get their words. Ask them first.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"duration_ms\":{\"type\":\"string\",\"description\":\"How long to wait for them, in milliseconds. Optional; default 30000, max 120000.\"}" +
			"}," +
			"\"required\":[]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	ms := Defms;
	(n, f) := sys->tokenize(args, " \t\n");
	if(n > 0) {
		ms = int hd f;
		if(ms <= 0 || ms > Maxms)
			return sys->sprint("error: wait 1 to %d ms", Maxms);
	}
	fd := sys->open(SPEECH_ASK, Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r", SPEECH_ASK);
	if(sys->fprint(fd, "start %d", ms) < 0)
		return sys->sprint("error: hear: %r");
	result := "";
	buf := array[8192] of byte;
	while((k := sys->read(fd, buf, len buf)) > 0)
		result += string buf[0:k];
	if(k < 0)
		return sys->sprint("error: hear: %r");
	if(result == "")
		return "(the user said nothing)";
	return result;
}
