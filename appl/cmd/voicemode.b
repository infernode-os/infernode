implement Voicemode;

#
# voicemode - bridge /n/speech wake/listen events into Lucia activity input.
#
# Phase 1 resident daemon. Pre-spawned at boot in an idle state; it activates
# when /mnt/ui/input-mode becomes "v" (the Voice chip click or Esc-V in
# lucifer, lucibridge's "/voice mode on", or a spoken control intent) and
# returns to idle on "k" (the same chip/key, Esc, "/voice mode off", or a
# spoken "keyboard"). The microphone is only open during a voice session:
# helpers start on the first wake/listen read, and exit writes `mic off` to
# the speech ctl so the provider tears them down again. While active it runs
# the Phase 1 state machine:
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
# Test mode (-p phrase, -e): the LLM-free loop for dogfooding the speech
# stack in the GUI without API cost. Finals never reach voiceinput; the
# transcript is posted to the conversation as a "Heard" dialogue line and
# the canned phrase (-p), or the transcript itself (-e), is spoken via
# /n/speech/say. Wake, live partials, chimes, barge-in and control intents
# behave exactly as in normal mode. tools/speech-test.sh --gui boots this.
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

Listenrec: adt {
	gen: int;
	text: string;
};

# Watcher plumbing. Buffered so a watcher finishing a read after the voice
# loop has exited never deadlocks; stale results are drained on re-entry.
evch: chan of string;		# "input-mode v|k" and other global events
wakech: chan of string;		# one wake read result per request
listench: chan of ref Listenrec;	# one listen read result per request
startwake: chan of int;
startlisten: chan of int;
timerch: chan of int;
listenseq := 0;

listentimeout := 10000;
wakecooldown := 1500;
gracems := 3000;		# grace window before a final is submitted; 0 = immediate
confidencethreshold := 650;	# thousandths; confidence metadata is optional
pendingconfirm := "";
busyqueued := 0;		# at most one voice follow-up while the activity is busy

testmode := 0;
echoback := 0;
testphrase := "Speech test complete. I heard you.";

LISTEN_EMPTY, LISTEN_PARTIAL, LISTEN_FINAL, LISTEN_ERROR: con iota;

silencefinals := array[] of {
	"thank you",
	"thanks for watching",
	"you",
};

usage()
{
	sys->fprint(stderr, "Usage: voicemode [-d] [-e] [-p phrase] [-g grace-ms] [-q confidence-permille] [-t ms] [-w ms] [-u /mnt/ui] [-s /n/speech]\n");
	raise "fail:usage";
}

log(msg: string)
{
	if(debug)
		sys->fprint(stderr, "voicemode: %s\n", msg);
}

# Failures are always logged, not just under -d. The daemon is started by
# boot.sh without flags, so a debug-gated error path means a silent stack: no
# log, and nothing to explain why voice mode did nothing.
logerr(msg: string)
{
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

ctxqueued(actid: int, full: int)
{
	label := "Voice: queued";
	if(full)
		label = "Voice: busy; one turn queued";
	path := sys->sprint("%s/activity/%d/context/ctl", ui, actid);
	writefile(path, "resource upsert path=/n/speech label=" + label +
		" type=audio status=queued via=voice-mode");
}

partiallabel(text: string): string
{
	text = strip(text);
	if(text == nil || text == "")
		return "Voice";
	for(i := 0; i < len text; i++)
		if(text[i] == '=' || text[i] == '\n' || text[i] == '\r' || text[i] == '\t')
			text[i] = ' ';
	if(len text > 40)
		text = text[len text - 40:];
	return "Voice: " + strip(text);
}

ctxpartial(actid: int, text: string)
{
	path := sys->sprint("%s/activity/%d/context/ctl", ui, actid);
	writefile(path, "resource upsert path=/n/speech label=" + partiallabel(text) +
		" type=audio status=listening via=voice-mode");
}

# Grace window: the heard transcript is on the chip (and in the compose
# draft) while the send timer runs, with a visible countdown so "say
# cancel to stop it" has both something to judge and a deadline.
ctxsending(actid: int, text: string, remainms: int)
{
	secs := (remainms + 999) / 1000;
	text = strip(text);
	for(i := 0; i < len text; i++)
		if(text[i] == '=' || text[i] == '\n' || text[i] == '\r' || text[i] == '\t')
			text[i] = ' ';
	if(len text > 30)
		text = text[len text - 30:];
	path := sys->sprint("%s/activity/%d/context/ctl", ui, actid);
	writefile(path, "resource upsert path=/n/speech label=Voice: sending in " +
		string secs + "s: " + strip(text) + " type=audio status=sending via=voice-mode");
}

# Put the failure reason on the Voice chip itself. The conversation notice is
# easy to miss and is not where the user is looking after clicking the chip —
# the chip is, and a bare red "error" does not say what to fix.
ctxerror(actid: int, reason: string)
{
	reason = strip(reason);
	if(hasprefix(reason, "error:"))
		reason = strip(reason[6:]);
	if(reason == nil || reason == "")
		reason = "speech helper unavailable";
	for(i := 0; i < len reason; i++)
		if(reason[i] == '=' || reason[i] == '\n' ||
				reason[i] == '\r' || reason[i] == '\t')
			reason[i] = ' ';
	if(len reason > 48)
		reason = reason[0:48];
	path := sys->sprint("%s/activity/%d/context/ctl", ui, actid);
	writefile(path, "resource upsert path=/n/speech label=Voice: " + reason +
		" type=audio status=error via=voice-mode");
}

# Timeout is non-fatal but must be visible: the chip returns to waiting
# with a note saying nothing was heard, so a broken STT path does not
# masquerade as a successful empty utterance. The next wake overwrites it.
ctxtimeout(actid: int)
{
	path := sys->sprint("%s/activity/%d/context/ctl", ui, actid);
	writefile(path, "resource upsert path=/n/speech label=Voice: no speech heard" +
		" type=audio status=waiting via=voice-mode");
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

draftinput(actid: int, text: string): int
{
	path := sys->sprint("%s/activity/%d/conversation/draft", ui, actid);
	fd := sys->open(path, Sys->OWRITE | Sys->OTRUNC);
	if(fd == nil)
		return -1;
	b := array of byte text;
	return sys->write(fd, b, len b);
}

cancelspeech()
{
	writefile(speech + "/cancel", "cancel");
}

# Release the microphone on voice-mode exit: the provider kills its
# mic-side helpers, and the next wake/listen read (the next session)
# re-arms them.
micoff()
{
	writefile(speech + "/ctl", "mic off");
}

# Stop the STT helper between turns: anything it hears while no turn is
# active (ambient speech, our own TTS) would queue as a stale record and
# replay into the next turn. The next listen read restarts it.
listenoff()
{
	writefile(speech + "/ctl", "listen off");
}

chime(kind: string)
{
	writefile(speech + "/chime", kind);
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
		return recordtext(s[6:]);
	if(hasprefix(s, "text "))
		return strip(s[5:]);
	if(hasprefix(s, "partial "))
		return nil;
	if(hasprefix(s, "error:"))
		return nil;
	return s;
}

recordtext(s: string): string
{
	s = strip(s);
	if(!hasprefix(s, "confidence="))
		return s;
	for(i := 0; i < len s; i++)
		if(s[i] == ' ')
			return strip(s[i+1:]);
	return nil;
}

recordconfidence(s: string): int
{
	s = strip(s);
	if(!hasprefix(s, "confidence="))
		return -1;
	i := len "confidence=";
	whole := 0;
	while(i < len s && s[i] >= '0' && s[i] <= '9') {
		whole = whole * 10 + s[i] - '0';
		i++;
	}
	if(whole >= 1)
		return 1000;
	if(i >= len s || s[i] != '.')
		return 0;
	i++;
	frac := 0;
	n := 0;
	while(i < len s && n < 3 && s[i] >= '0' && s[i] <= '9') {
		frac = frac * 10 + s[i] - '0';
		i++;
		n++;
	}
	while(n++ < 3)
		frac *= 10;
	return frac;
}

ispartial(s: string): int
{
	s = strip(s);
	return s != nil && hasprefix(s, "partial ");
}

parselisten(s: string): (int, string, int)
{
	s = strip(s);
	if(s == nil || s == "")
		return (LISTEN_EMPTY, nil, -1);
	kind := LISTEN_EMPTY;
	text := "";
	confidence := -1;
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines) {
		line := strip(hd lines);
		if(line == "")
			continue;
		if(hasprefix(line, "error:")) {
			if(kind != LISTEN_FINAL)
				kind = LISTEN_ERROR;
			continue;
		}
		if(ispartial(line)) {
			if(kind != LISTEN_FINAL) {
				kind = LISTEN_PARTIAL;
				confidence = recordconfidence(line[8:]);
				text = recordtext(line[8:]);
			}
			continue;
		}
		t := finaltext(line);
		if(t != nil && t != "") {
			kind = LISTEN_FINAL;
			if(hasprefix(line, "final "))
				confidence = recordconfidence(line[6:]);
			text = t;
		}
	}
	return (kind, text, confidence);
}

iserror(s: string): int
{
	return s == nil || strip(s) == "" || hasprefix(strip(s), "error:");
}

ispunct(c: int): int
{
	return c == '.' || c == ',' || c == '!' || c == '?' || c == ';' || c == ':';
}

normalize(text: string): string
{
	text = strip(str->tolower(text));
	if(text == nil || text == "")
		return text;
	i := 0;
	j := len text;
	while(i < j && ispunct(text[i]))
		i++;
	while(j > i && ispunct(text[j-1]))
		j--;
	if(i >= j)
		return "";
	return strip(text[i:j]);
}

stripbrackets(text: string): string
{
	out := "";
	for(i := 0; i < len text; i++) {
		c := text[i];
		if(c == '[' || c == '(') {
			close := ']';
			if(c == '(')
				close = ')';
			for(j := i + 1; j < len text && text[j] != close; j++)
				;
			if(j < len text) {
				i = j;
				out += " ";
				continue;
			}
		}
		out[len out] = c;
	}
	return strip(out);
}

junkfinal(text: string): int
{
	text = strip(text);
	if(text == nil || text == "")
		return 1;
	text = stripbrackets(text);
	if(text == "")
		return 1;
	n := normalize(text);
	for(i := 0; i < len silencefinals; i++)
		if(n == silencefinals[i])
			return 1;
	return 0;
}

# Words that discard the pending transcript during the send grace window.
gracecancel(text: string): int
{
	n := normalize(text);
	return n == "cancel" || n == "no" || n == "stop" || n == "wrong" ||
		n == "never mind" || n == "nevermind" || n == "discard" ||
		n == "scratch that";
}

approvalpending(actid: int): int
{
	path := sys->sprint("%s/activity/%d/status", ui, actid);
	return strip(readfile(path)) == "blocked";
}

controlinput(actid: int, ctl: string): int
{
	path := sys->sprint("%s/activity/%d/conversation/control", ui, actid);
	n := writefile(path, ctl);
	if(n < 0)
		logerr("cannot write active-turn control " + ctl + " to " + path + ": " + sys->sprint("%r"));
	return n;
}

activitystatus(actid: int): string
{
	return strip(readfile(sys->sprint("%s/activity/%d/status", ui, actid)));
}

agentbusy(actid: int): int
{
	s := activitystatus(actid);
	return s != nil && s != "" && s != "idle" && s != "active" && s != "complete";
}

# The say write blocks for the TTS duration on real providers, so test
# mode runs it spawned; barge-in still works because a wake event writes
# /n/speech/cancel, which kills the in-flight synthesis.
saytts(text: string)
{
	writefile(speech + "/say", text);
}

# Test mode: surface the recognized transcript in the conversation view
# without submitting it as an LLM turn.
noticeheard(actid: int, text: string)
{
	for(i := 0; i < len text; i++)
		if(text[i] == '\n' || text[i] == '\r' || text[i] == '\t')
			text[i] = ' ';
	path := sys->sprint("%s/activity/%d/conversation/ctl", ui, actid);
	writefile(path, "role=veltro dtype=dialogue title=Heard text=" + text);
}

noticeconfirm(actid: int, text: string)
{
	for(i := 0; i < len text; i++)
		if(text[i] == '\n' || text[i] == '\r' || text[i] == '\t')
			text[i] = ' ';
	path := sys->sprint("%s/activity/%d/conversation/ctl", ui, actid);
	writefile(path, "role=veltro dtype=dialogue title=Confirm speech text=I heard: " +
		text + ". Say yes to continue, or say the correction.");
}

noticevoiceerror(actid: int, reason: string)
{
	reason = strip(reason);
	if(reason == nil || reason == "")
		reason = "speech helper unavailable";
	for(i := 0; i < len reason; i++)
		if(reason[i] == '\n' || reason[i] == '\r' || reason[i] == '\t')
			reason[i] = ' ';
	path := sys->sprint("%s/activity/%d/conversation/ctl", ui, actid);
	writefile(path, "role=veltro dtype=dialogue title=Voice text=" + reason);
}

# Spoken control intents that act on the session instead of becoming a chat
# turn. Returns 1 when the utterance was consumed.
handlecontrol(actid: int, text: string): int
{
	lower := normalize(text);
	if(lower == "stop" || lower == "cancel") {
		cancelspeech();
		controlinput(actid, "cancel");
		ctxstatus(actid, "waiting");
		return 1;
	}
	if(lower == "pause") {
		controlinput(actid, "pause");
		ctxstatus(actid, "paused");
		return 1;
	}
	if(lower == "resume" || (lower == "continue" && activitystatus(actid) == "paused")) {
		controlinput(actid, "resume");
		ctxstatus(actid, "waiting");
		return 1;
	}
	if(lower == "status" || lower == "repeat status" || lower == "what is happening") {
		s := activitystatus(actid);
		if(s == nil || s == "")
			s = "idle";
		spawn saytts("Current activity is " + s + ".");
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
	if(lower == "approve" || lower == "allow" ||
	   (lower == "yes" && approvalpending(actid))) {
		voiceinput(actid, "Allow");
		return 1;
	}
	if(lower == "deny" || (lower == "no" && approvalpending(actid))) {
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

listenwatcher()
{
	for(;;) {
		gen := <-startlisten;
		listench <-= ref Listenrec(gen, readfile(speech + "/listen"));
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

requestlisten(gen: int)
{
	alt {
	startlisten <-= gen =>
		;
	* =>
		;
	}
}

timer(ch: chan of int, ms: int, gen: int)
{
	sys->sleep(ms);
	alt {
	ch <-= gen =>
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
		<-timerch =>
			;
		* =>
			return;
		}
	}
}

WAITING, LISTENING, SENDING: con iota;

# Submit a completed utterance as the turn (test mode: canned reply, no LLM).
submitfinal(actid: int, text: string)
{
	if(testmode) {
		ctxstatus(actid, "processing");
		noticeheard(actid, text);
		saytext := testphrase;
		if(echoback)
			saytext = text;
		ctxstatus(actid, "speaking");
		spawn saytts(saytext);
	} else {
		busy := agentbusy(actid);
		if(!busy)
			busyqueued = 0;
		if(busy && busyqueued) {
			log("busy: discarding additional queued voice turn: " + text);
			ctxqueued(actid, 1);
			chime("done");
			return;
		}
		ctxstatus(actid, "processing");
		# A follow-up against a busy activity takes conversational
		# control at the next safe model/tool boundary, then remains
		# queued on voiceinput as the next turn in the same session.
		if(busy && !approvalpending(actid))
			controlinput(actid, "refine");
		if(voiceinput(actid, text) < 0) {
			ctxstatus(actid, "error");
			return;
		}
		if(busy) {
			busyqueued = 1;
			ctxqueued(actid, 0);
		}
	}
}

# Active voice session. Runs until input-mode leaves "v".
voiceloop()
{
	log("voice mode on");
	pendingconfirm = "";
	busyqueued = 0;
	pendingsend := "";
	drainresults();
	actid := currentactivity();
	state := WAITING;
	listengen := 0;
	# Grace-window bookkeeping. One timer per SENDING entry (identified by
	# sendgen); appended speech only moves senddeadline, and the timer
	# re-arms itself for the remainder when it fires early. Spawning a new
	# timer per append instead would flood timerch's small buffer with
	# stale ticks and the live one gets dropped (timer() sends
	# non-blocking so an exited session never leaks a blocked proc).
	sendgen := 0;
	senddeadline := 0;
	lastappend := "";
	lastwake := -wakecooldown;
	errorshown := 0;
	draftinput(actid, "");
	ctxstatus(actid, "waiting");
	chime("on");
	request(startwake);
	for(;;) {
		alt {
		ev := <-evch =>
			if(hasprefix(ev, "input-mode ") && strip(ev[11:]) != "v") {
				listenseq++;
				listengen = listenseq;
				draftinput(actid, "");
				cancelspeech();
				chime("off");
				micoff();
				busyqueued = 0;
				ctxstatus(actid, "idle");
				log("voice mode off");
				return;
			}
		w := <-wakech =>
			if(state != WAITING)
				continue;
			if(iserror(w)) {
				logerr("wake: " + strip(w));
				# Report the first failure, not the third: a wake
				# helper that cannot start fails identically every
				# time, and three silent seconds read as "the button
				# did nothing". errorshown keeps it to one notice.
				if(!errorshown) {
					ctxerror(actid, strip(w));
					noticevoiceerror(actid, strip(w));
					errorshown = 1;
				}
				sys->sleep(1000);
				request(startwake);
				continue;
			}
			errorshown = 0;
			now := sys->millisec();
			if(now - lastwake < wakecooldown) {
				log("wake debounce: " + strip(w));
				sys->sleep(100);
				request(startwake);
				continue;
			}
			lastwake = now;
			log("wake: " + strip(w));
			chime("wake");
			# Barge-in: any active TTS is cut off before listening.
			cancelspeech();
			actid = currentactivity();
			draftinput(actid, "");
			state = LISTENING;
			listenseq++;
			listengen = listenseq;
			ctxstatus(actid, "listening");
			spawn timer(timerch, listentimeout, listengen);
			requestlisten(listengen);
		rec := <-listench =>
			if(state == SENDING) {
				if(rec.gen != listengen)
					continue;
				(gkind, gtext, nil) := parselisten(rec.text);
				if(gkind == LISTEN_EMPTY || junkfinal(gtext) && gkind == LISTEN_FINAL) {
					sys->sleep(100);
					requestlisten(listengen);
					continue;
				}
				if(gkind == LISTEN_PARTIAL) {
					draftinput(actid, pendingsend + " " + gtext);
					sys->sleep(100);
					requestlisten(listengen);
					continue;
				}
				if(gkind == LISTEN_ERROR) {
					# The pending text still sends when the grace
					# timer fires; only the barge-in ear is lost.
					logerr("listen during grace: " + strip(rec.text));
					continue;
				}
				if(gracecancel(gtext)) {
					log("grace cancel: " + gtext);
					pendingsend = "";
					listenseq++;
					listengen = listenseq;
					state = WAITING;
					listenoff();
					draftinput(actid, "");
					ctxstatus(actid, "waiting");
					spawn saytts("Cancelled.");
					chime("done");
					sys->sleep(100);
					request(startwake);
					continue;
				}
				# The whisper wrapper's sliding window re-emits the
				# same utterance after a pause; appending it would
				# turn one sentence into three. (Parakeet emits each
				# final once, so this only guards the fallback.)
				if(normalize(gtext) == lastappend) {
					sys->sleep(100);
					requestlisten(listengen);
					continue;
				}
				# More speech: the turn was not over. Append and
				# push the deadline out; the running tick timer
				# covers the remainder.
				log("grace append: " + gtext);
				pendingsend += " " + gtext;
				lastappend = normalize(gtext);
				listenseq++;
				listengen = listenseq;
				senddeadline = sys->millisec() + gracems;
				draftinput(actid, pendingsend);
				ctxsending(actid, pendingsend, gracems);
				requestlisten(listengen);
				continue;
			}
			if(state != LISTENING)
				continue;
			if(rec.gen != listengen)
				continue;
			(kind, text, confidence) := parselisten(rec.text);
			if(kind == LISTEN_EMPTY || kind == LISTEN_PARTIAL) {
				errorshown = 0;
				if(kind == LISTEN_PARTIAL) {
					ctxpartial(actid, text);
					draftinput(actid, text);
				}
				sys->sleep(100);
				requestlisten(listengen);
				continue;
			}
			if(kind == LISTEN_ERROR) {
				logerr("listen: " + strip(rec.text));
				listenseq++;
				listengen = listenseq;
				state = WAITING;
				listenoff();
				draftinput(actid, "");
				if(!errorshown) {
					ctxerror(actid, strip(rec.text));
					noticevoiceerror(actid, strip(rec.text));
					errorshown = 1;
				} else
					ctxstatus(actid, "waiting");
				sys->sleep(100);
				request(startwake);
				continue;
			}
			listenseq++;
			listengen = listenseq;
			errorshown = 0;
			if(junkfinal(text)) {
				state = WAITING;
				listenoff();
				draftinput(actid, "");
				log("listen junk: " + text);
				ctxstatus(actid, "waiting");
				chime("done");
				sys->sleep(100);
				request(startwake);
				continue;
			}
			log("transcript: " + text);
			if(handlecontrol(actid, text)) {
				state = WAITING;
				listenoff();
				draftinput(actid, "");
				pendingconfirm = "";
				ctxstatus(actid, "waiting");
				chime("done");
				sys->sleep(100);
				request(startwake);
				continue;
			}
			confirmed := 0;
			if(pendingconfirm != "") {
				answer := normalize(text);
				if(answer == "yes" || answer == "confirm" || answer == "correct" ||
				   answer == "do it") {
					text = pendingconfirm;
					pendingconfirm = "";
					confidence = 1000;
					# An explicit yes skips the grace window: the
					# user already vetted this exact text.
					confirmed = 1;
				} else if(answer == "no" || answer == "wrong" || answer == "cancel") {
					pendingconfirm = "";
					state = WAITING;
					listenoff();
					draftinput(actid, "");
					ctxstatus(actid, "waiting");
					spawn saytts("Okay. Please say it again.");
					chime("done");
					sys->sleep(100);
					request(startwake);
					continue;
				} else {
					# Treat any other answer as a spoken correction and apply its
					# own confidence rather than submitting the old interpretation.
					pendingconfirm = "";
				}
			}
			if(confidence >= 0 && confidence < confidencethreshold) {
				state = WAITING;
				listenoff();
				draftinput(actid, "");
				pendingconfirm = text;
				ctxstatus(actid, "confirming");
				noticeconfirm(actid, text);
				spawn saytts("I heard " + text + ". Is that right?");
				chime("done");
				sys->sleep(100);
				request(startwake);
				continue;
			}
			if(gracems > 0 && !confirmed) {
				# Grace window: show the transcript (chip + compose
				# draft) and keep listening. "cancel" discards it,
				# more speech appends to it, the timer submits it.
				# The listen helper stays armed so no restart
				# latency lands inside the window.
				pendingsend = text;
				lastappend = normalize(text);
				state = SENDING;
				sendgen = listengen;
				senddeadline = sys->millisec() + gracems;
				draftinput(actid, pendingsend);
				ctxsending(actid, pendingsend, gracems);
				chime("done");
				# Tick timer: fires every ≤500ms to refresh the
				# countdown, re-arming until the deadline (which
				# appended speech may keep moving) passes.
				tick := gracems;
				if(tick > 500)
					tick = 500;
				spawn timer(timerch, tick, sendgen);
				requestlisten(listengen);
				continue;
			}
			state = WAITING;
			listenoff();
			draftinput(actid, "");
			submitfinal(actid, text);
			# Re-arm immediately: a wake during the spoken response is
			# barge-in. The pacing sleep keeps mock file trees (always-
			# ready reads) from spinning.
			sys->sleep(100);
			request(startwake);
		gen := <-timerch =>
			if(state == LISTENING && gen == listengen) {
				# Always logged: a timeout with no transcript is the
				# signature of a broken STT path, and must not be
				# indistinguishable from a completed empty turn.
				logerr("listen timeout: no transcript received");
				listenseq++;
				listengen = listenseq;
				state = WAITING;
				listenoff();
				draftinput(actid, "");
				ctxtimeout(actid);
				chime("done");
				request(startwake);
			} else if(state == SENDING && gen == sendgen) {
				now := sys->millisec();
				if(now < senddeadline) {
					# Deadline not reached (or moved by appended
					# speech): refresh the countdown and re-arm.
					wait := senddeadline - now;
					if(wait > 500)
						wait = 500;
					ctxsending(actid, pendingsend, senddeadline - now);
					spawn timer(timerch, wait, sendgen);
					continue;
				}
				# Grace window elapsed with no cancel: submit.
				sendtext := pendingsend;
				pendingsend = "";
				listenseq++;
				listengen = listenseq;
				state = WAITING;
				listenoff();
				draftinput(actid, "");
				submitfinal(actid, sendtext);
				sys->sleep(100);
				request(startwake);
			}
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
		'e' =>	echoback = 1;
			testmode = 1;
		'p' =>	testphrase = arg->earg();
			testmode = 1;
		'g' =>	gracems = int arg->earg();
		'q' =>	confidencethreshold = int arg->earg();
		't' =>	listentimeout = int arg->earg();
		'w' =>	wakecooldown = int arg->earg();
		'u' =>	ui = arg->earg();
		's' =>	speech = arg->earg();
		* =>	usage();
		}
	if(confidencethreshold < 0 || confidencethreshold > 1000)
		usage();
	if(gracems < 0)
		usage();

	evch = chan[8] of string;
	wakech = chan[2] of string;
	listench = chan[2] of ref Listenrec;
	startwake = chan[1] of int;
	startlisten = chan[1] of int;
	timerch = chan[2] of int;

	spawn eventwatcher();
	spawn speechwatcher("wake", startwake, wakech);
	spawn listenwatcher();

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
