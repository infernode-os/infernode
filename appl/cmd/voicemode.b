implement Voicemode;

#
# voicemode - bridge /n/speech wake/listen events into Lucia activity input.
#
# Phase 1 resident daemon. Pre-spawned at boot in an idle state; it activates
# when /mnt/ui/input-mode becomes "v" (written by lucibridge's "/voice mode on"
# or by a spoken control intent) and returns to idle on "k" (Esc in lucifer,
# "/voice mode off", or a spoken "keyboard"). While active it runs the Phase 1
# state machine:
#
#   WAITING_WAKE -> LISTENING -> PROCESSING/SPEAKING -> WAITING_WAKE
#
# Wake is re-armed as soon as a transcript is injected, so a wake event that
# arrives while the assistant is speaking acts as barge-in: /n/speech/cancel
# is written (cutting off TTS) and the machine goes straight to LISTENING.
#
# Mode changes are observed through the /mnt/ui/event global stream when it
# exists; otherwise (mock file trees in tests, older servers) the daemon polls
# /mnt/ui/input-mode. Final transcripts are injected through the privileged
# conversation/voiceinput path so lucibridge accepts them while keyboard input
# is paused.
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
ui := "/mnt/ui";
speech := "/n/speech";

# Watcher plumbing. Buffered so a watcher finishing a read after the voice
# loop has exited never deadlocks; stale results are drained on re-entry.
evch: chan of string;		# "input-mode v|k" and other global events
wakech: chan of string;		# one wake read result per request
listench: chan of string;	# one listen read result per request
startwake: chan of int;
startlisten: chan of int;

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

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
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

inputmode(): string
{
	return strip(readfile(ui + "/input-mode"));
}

setinputmode(mode: string)
{
	writefile(ui + "/input-mode", mode);
}

voiceinput(actid: int, text: string): int
{
	path := sys->sprint("%s/activity/%d/conversation/voiceinput", ui, actid);
	return writefile(path, text);
}

cancelspeech()
{
	writefile(speech + "/cancel", "cancel");
}

# Parse a listen-stream record into a final transcript, or nil if the record
# is a partial, an error, or empty. Wire format (see appl/veltro/speech9p.b):
# newline-delimited "partial <text>" / "final <text>" records; bare text from
# batch-style helpers is treated as final.
finaltext(s: string): string
{
	s = strip(s);
	if(s == nil || s == "")
		return nil;
	if(hasprefix(s, "final "))
		return strip(s[6:]);
	if(hasprefix(s, "text "))
		return strip(s[5:]);
	if(hasprefix(s, "partial "))
		return nil;
	if(hasprefix(s, "error:"))
		return nil;
	return s;
}

iserror(s: string): int
{
	return s == nil || strip(s) == "" || hasprefix(strip(s), "error:");
}

# Spoken control intents that act on the session instead of becoming a chat
# turn. Returns 1 when the utterance was consumed.
handlecontrol(actid: int, text: string): int
{
	lower := str->tolower(text);
	if(lower == "stop" || lower == "cancel") {
		cancelspeech();
		ctxstatus(actid, "waiting");
		return 1;
	}
	if(lower == "keyboard" || lower == "voice mode off") {
		cancelspeech();
		# The input-mode change is observed by the event watcher and
		# exits the voice loop; lucifer and lucibridge see the same
		# broadcast.
		setinputmode("k");
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

# Global event watcher. Prefers the /mnt/ui/event broadcast stream (persistent
# fd, blocking reads). When the event file is unavailable — mock file trees in
# tests, or a ui server without it — falls back to polling input-mode and
# synthesizing "input-mode <m>" events on change.
eventwatcher()
{
	last := "";
	for(;;) {
		fd := sys->open(ui + "/event", Sys->OREAD);
		if(fd == nil) {
			m := inputmode();
			if(m != nil && m != "" && m != last) {
				last = m;
				evch <-= "input-mode " + m;
			}
			sys->sleep(300);
			continue;
		}
		buf := array[1024] of byte;
		while((n := sys->read(fd, buf, len buf)) > 0) {
			(nil, lines) := sys->tokenize(string buf[0:n], "\n");
			for(; lines != nil; lines = tl lines) {
				ev := strip(hd lines);
				if(ev != "")
					evch <-= ev;
				if(hasprefix(ev, "input-mode "))
					last = strip(ev[11:]);
			}
		}
		fd = nil;
		# EOF: plain-file mock or server restart; re-open after a beat.
		sys->sleep(300);
	}
}

# One blocking speech read per start request. Gated so the microphone-side
# helpers only run while the voice loop has asked for an event.
speechwatcher(file: string, startch: chan of int, ch: chan of string)
{
	for(;;) {
		<-startch;
		ch <-= readfile(speech + "/" + file);
	}
}

# Non-blocking start request; a no-op if a request is already queued.
request(startch: chan of int)
{
	alt {
	startch <-= 1 =>
		;
	* =>
		;
	}
}

# Drop results left over from a previous voice session.
drainresults()
{
	for(;;) {
		alt {
		<-wakech =>
			;
		<-listench =>
			;
		* =>
			return;
		}
	}
}

WAITING, LISTENING: con iota;

# Active voice session. Runs until input-mode leaves "v".
voiceloop()
{
	log("voice mode on");
	drainresults();
	actid := currentactivity();
	state := WAITING;
	ctxstatus(actid, "waiting");
	request(startwake);
	for(;;) {
		alt {
		ev := <-evch =>
			if(hasprefix(ev, "input-mode ") && strip(ev[11:]) != "v") {
				cancelspeech();
				ctxstatus(actid, "idle");
				log("voice mode off");
				return;
			}
		w := <-wakech =>
			if(state != WAITING)
				continue;
			if(iserror(w)) {
				log("wake: " + strip(w));
				sys->sleep(1000);
				request(startwake);
				continue;
			}
			log("wake: " + strip(w));
			# Barge-in: any active TTS is cut off before listening.
			cancelspeech();
			actid = currentactivity();
			state = LISTENING;
			ctxstatus(actid, "listening");
			request(startlisten);
		r := <-listench =>
			if(state != LISTENING)
				continue;
			state = WAITING;
			text := finaltext(r);
			if(text == nil || text == "") {
				if(iserror(r))
					log("listen: " + strip(r));
				ctxstatus(actid, "waiting");
				sys->sleep(100);
				request(startwake);
				continue;
			}
			log("transcript: " + text);
			if(handlecontrol(actid, text)) {
				ctxstatus(actid, "waiting");
				sys->sleep(100);
				request(startwake);
				continue;
			}
			ctxstatus(actid, "processing");
			if(voiceinput(actid, text) < 0)
				ctxstatus(actid, "error");
			else
				ctxstatus(actid, "speaking");
			# Re-arm immediately: a wake during the spoken response is
			# barge-in. The pacing sleep keeps mock file trees (always-
			# ready reads) from spinning.
			sys->sleep(100);
			request(startwake);
		}
	}
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

	evch = chan[8] of string;
	wakech = chan[2] of string;
	listench = chan[2] of string;
	startwake = chan[1] of int;
	startlisten = chan[1] of int;

	spawn eventwatcher();
	spawn speechwatcher("wake", startwake, wakech);
	spawn speechwatcher("listen", startlisten, listench);

	# Resident loop: idle until input-mode becomes "v". The startup check
	# catches a daemon (re)started while voice mode is already on.
	for(;;) {
		if(inputmode() == "v")
			voiceloop();
		else {
			ev := <-evch;
			if(!(hasprefix(ev, "input-mode ") && strip(ev[11:]) == "v"))
				continue;
		}
	}
}
