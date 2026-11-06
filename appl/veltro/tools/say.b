implement ToolSay;

#
# say - text to speech for a Veltro agent, through speech(4)
#
#	say <text>
#
# The text is written to /mnt/speech/say, queued and spoken.  This tool's
# grant is that file and voices, nothing else of /mnt/speech: the voice,
# the language and the engine are the user's, set in wm/settings.  A
# -v <voice> left by an older prompt is refused if it is not a plain
# name and otherwise ignored, and the answer says so.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "../tool.m";

ToolSay: module {
	init: fn(): string;
	name: fn(): string;
	doc:  fn(): string;
	exec: fn(args: string): string;
	schema: fn(): string;
};

SPEECH_SAY: con "/mnt/speech/say";

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "say";
}

doc(): string
{
	return "Say - Speak text aloud (text-to-speech)\n\n" +
		"Usage:\n" +
		"  say <text>                 Speak the given text\n\n" +
		"Examples:\n" +
		"  say Hello, I am Veltro.\n" +
		"  say The task is complete.\n\n" +
		"The voice and language are the user's, chosen in Settings.\n" +
		"Requires speech(4) at /mnt/speech.";
}

schema(): string
{
	return "{" +
		"\"name\":\"say\"," +
		"\"description\":\"Speak text aloud to the user, in the voice they chose.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"text\":{\"type\":\"string\",\"description\":\"The text to speak.\"}" +
			"}," +
			"\"required\":[\"text\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil)
		init();

	text := strip(args);
	note := "";
	(n, argv) := sys->tokenize(text, " \t");
	if(n >= 2 && hd argv == "-v") {
		v := hd tl argv;
		if(!safename(v))
			return "error: unsafe voice name";
		note = " (the voice is the user's, set in Settings: -v " + v + " ignored)";
		text = "";
		for(argv = tl tl argv; argv != nil; argv = tl argv) {
			if(text != "")
				text += " ";
			text += hd argv;
		}
	}
	if(text == "")
		return "error: usage: say <text>";

	fd := sys->open(SPEECH_SAY, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("error: cannot open %s: %r", SPEECH_SAY);
	b := array of byte text;
	if(sys->write(fd, b, len b) < 0)
		return sys->sprint("error: say: %r");
	return "ok" + note;
}

safename(s: string): int
{
	if(s == nil || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++) {
		c := s[i];
		if((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')
			continue;
		return 0;
	}
	return 1;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n'))
		j--;
	return s[i:j];
}
