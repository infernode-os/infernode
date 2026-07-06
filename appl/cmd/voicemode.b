implement Voicemode;

#
# voicemode - bridge /n/speech wake/listen events into Lucia activity input.
#
# Phase 1 daemon.  It keeps keyboard input paused through /mnt/ui/input-mode and
# injects final speech transcripts through conversation/voiceinput, so
# lucibridge can keep keyboard reads paused while voice-originated turns still
# reach agentturn().
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "string.m";
	str: String;

Voicemode: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;
debug := 0;
running := 1;
ui := "/mnt/ui";
speech := "/n/speech";

usage()
{
	sys->fprint(stderr, "Usage: voicemode [-d] [-u /mnt/ui] [-s /n/speech]\n");
	raise "fail:usage";
}

log(msg: string)
{
	if(debug)
		sys->fprint(stderr, "voicemode: %s\n", msg);
}

writefile(path, data: string): int
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return -1;
	b := array of byte data;
	return sys->write(fd, b, len b);
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[8192] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

strip(s: string): string
{
	if(s == nil)
		return nil;
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r' || s[j-1] == '\n'))
		j--;
	if(i >= j)
		return "";
	return s[i:j];
}

currentactivity(): int
{
	s := strip(readfile(ui + "/activity/current"));
	if(s == nil || s == "")
		return 0;
	return int s;
}

ctxstatus(actid: int, state: string)
{
	path := sys->sprint("%s/activity/%d/context/ctl", ui, actid);
	writefile(path, "resource upsert path=/n/speech label=Voice type=audio status=" +
		state + " via=voice-mode");
}

inputmode(mode: string)
{
	writefile(ui + "/input-mode", mode);
}

voiceinput(actid: int, text: string): int
{
	path := sys->sprint("%s/activity/%d/conversation/voiceinput", ui, actid);
	return writefile(path, text);
}

finaltext(s: string): string
{
	s = strip(s);
	if(s == nil || s == "")
		return nil;
	if(len s >= 6 && s[0:6] == "final ")
		return strip(s[6:]);
	if(len s >= 5 && s[0:5] == "text ")
		return strip(s[5:]);
	if(len s >= 8 && s[0:8] == "partial ")
		return nil;
	if(len s >= 6 && s[0:6] == "error:")
		return nil;
	return s;
}

handlecontrol(actid: int, text: string): int
{
	lower := str->tolower(text);
	if(lower == "stop" || lower == "cancel") {
		writefile(speech + "/cancel", "cancel");
		ctxstatus(actid, "idle");
		return 1;
	}
	if(lower == "keyboard" || lower == "voice mode off") {
		writefile(speech + "/cancel", "cancel");
		inputmode("k");
		ctxstatus(actid, "idle");
		running = 0;
		return 1;
	}
	if(lower == "approve" || lower == "allow" || lower == "yes") {
		voiceinput(actid, "Allow");
		return 1;
	}
	if(lower == "deny" || lower == "no") {
		voiceinput(actid, "Deny");
		return 1;
	}
	return 0;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);

	str = load String String->PATH;
	if(str == nil) {
		sys->fprint(stderr, "voicemode: cannot load string: %r\n");
		raise "fail:load";
	}

	arg := load Arg Arg->PATH;
	if(arg == nil) {
		sys->fprint(stderr, "voicemode: cannot load arg: %r\n");
		raise "fail:load";
	}
	arg->init(args);
	while((o := arg->opt()) != 0)
		case o {
		'd' =>	debug = 1;
		'u' =>	ui = arg->earg();
		's' =>	speech = arg->earg();
		* =>	usage();
		}

	inputmode("v");
	for(; running;) {
		actid := currentactivity();
		ctxstatus(actid, "waiting");
		wake := readfile(speech + "/wake");
		if(wake == nil) {
			log("waiting for speech service");
			sys->sleep(1000);
			continue;
		}

		ctxstatus(actid, "listening");
		listen := readfile(speech + "/listen");
		text := finaltext(listen);
		if(text == nil || text == "") {
			ctxstatus(actid, "error");
			sys->sleep(500);
			continue;
		}
		if(handlecontrol(actid, text))
			continue;

		ctxstatus(actid, "processing");
		if(voiceinput(actid, text) < 0)
			ctxstatus(actid, "error");
		else
			ctxstatus(actid, "speaking");
	}
}
