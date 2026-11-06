implement Speech9p;

#
# speech9p -- speech, both ways, for the whole system: speech(4).
#
#	speech9p [-m mountpoint] [-E enginedir] [-s settingsfile]
#
#	/mnt/speech/
#		talk	start, stop (push to talk); read: on or off, then
#			asked while a program waits on ask, and a later read
#			on a fid waits until that changes
#		listen	what is heard, as the engine gives it, a line each:
#			partial confidence=N words, final confidence=N
#			words, error reason; every reader gets every line
#			from its first read on
#		say	write text: queued and spoken; read: speaking <text>
#			or idle
#		cancel	any write: stop speaking now, the queue dropped
#		chime	start, stop, done, error: an earcon
#		voices	the engine's voices
#		ctl	engine <dir>, voice <v>, lang <l>, duplex half|full,
#			agentmic off|on; read: the settings, whether the
#			engine answers, talk and speaking
#		hear	the old interface: write start [ms] (5000), read
#			the words of what was said (the next final), then
#			end of file
#		ask	an agent's: write start [ms] (30000), read the words
#			of the next utterance the user begins, then end of
#			file; it never turns talk on unless agentmic is on
#
# Voice, lang, duplex and agentmic are kept in the settings file
# (/usr/<user>/lib/speech) as ctl lines, read when speech9p starts and
# written whenever one changes.
#
# The engine is a directory -- the native one, a desktop's programs
# behind speechcmd(4), a machine elsewhere over 9P -- serving ctl,
# audio, text, tts and voices (speech(4)); speech9p only uses it.  It
# keeps no engine of its own and no setting the engine has.
#
# Sound goes through the shared audio device (audio(3)'s mix): the
# microphone is a stream of its own at 16 kHz, opened only while talk is
# on, and what is said is a stream with the role speech, so a call
# lowers it and it lowers media.  With duplex half (the default) the
# microphone's sound is not given to the engine while speech plays, so
# the system does not hear itself; full is for hardware that cancels
# its own echo.
#
# One process owns every setting and file; the microphone's pump, the
# engine's text, the speaker and the chimes are processes of their own
# that block on the engine and the device, so a read or write of these
# files is never held up behind them.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "math.m";
	math: Math;

Speech9p: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Micrate:	con 16000;
Micchunk:	con Micrate / 50 * 2;	# 20 ms of 16-bit mono
Hearms:		con 5000;
Askms:		con 30000;

stderr: ref Sys->FD;
mountpt := "/mnt/speech";
engine := "/mnt/speechengine";
voice := "";
lang := "";
model := "";		# the recogniser's, for an engine that has models (#W)
duplex := "half";
agentmic := 0;		# may an ask turn talk on itself
settings := "";

talking := 0;
speaking := 0;		# read by the microphone's pump: what duplex half needs
speaktext := "";
micstop: chan of int;
heartalk := 0;		# talk was started by hear (or ask), and stops with it
talkseq := 0;		# talk's starts, counted: the utterance a final is of

# a reader of talk: the state its fid was last told, and a read waiting
Talker: adt {
	fid:	int;
	told:	string;	# nil: nothing yet
	rc:	Sys->Rread;
};
talkers: list of ref Talker;

# a reader of listen
Listener: adt {
	fid:	int;
	queue:	list of string;	# oldest first
	rc:	Sys->Rread;
	count:	int;
};
listeners: list of ref Listener;

# a fid of hear or ask: started, and the words when they come
Hearer: adt {
	fid:	int;
	ask:	int;		# of ask: only an utterance begun after seq
	seq:	int;
	waiting:	int;
	words:	string;
	done:	int;
	rc:	Sys->Rread;
};
hearers: list of ref Hearer;

recc: chan of string;		# records from the engine's text
spkc: chan of (int, string);	# the speaker: speaking or not, and what
hearendc: chan of (int, int);	# a hear's or ask's time is up (fid, ask)
sayc: chan of string;		# what is queued to be said
chimec: chan of string;
speakerpid := -1;
textpid := -1;

# the speech stream, the main process's: the speaker writes its data,
# a cancel flushes it through ctl
spkctl, spkdata: ref Sys->FD;
spkrate := 0;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(args);
		arg->setusage("speech9p [-m mountpoint] [-E enginedir] [-s settingsfile]");
		while((o := arg->opt()) != 0)
			case o {
			'm' =>	mountpt = arg->earg();
			'E' =>	engine = arg->earg();
			's' =>	settings = arg->earg();
			'e' =>	arg->earg();	# the old engines are speechcmd(4)'s now
			* =>	arg->usage();
			}
	}
	if(settings == nil)
		settings = "/usr/" + user() + "/lib/speech";
	loadsettings();
	if(sys->bind("#sspeech", mountpt, Sys->MREPL) < 0){
		sys->fprint(stderr, "speech9p: bind %s: %r\n", mountpt);
		raise "fail:bind";
	}
	f := array[9] of ref Sys->FileIO;
	names := array[] of {"ctl", "talk", "listen", "say", "cancel", "chime", "voices", "hear", "ask"};
	for(i := 0; i < len names; i++)
		if((f[i] = sys->file2chan(mountpt, names[i])) == nil){
			sys->fprint(stderr, "speech9p: file2chan %s: %r\n", names[i]);
			raise "fail:file2chan";
		}
	sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);
	recc = chan of string;
	spkc = chan of (int, string);
	hearendc = chan of (int, int);
	sayc = chan[64] of string;
	chimec = chan[8] of string;
	starttext();
	spawn chimeproc();
	startspeaker();
	spawn serve(f);
}

serve(f: array of ref Sys->FileIO)
{
	ctl := f[0];
	talk := f[1];
	listen := f[2];
	say := f[3];
	cancel := f[4];
	chime := f[5];
	voices := f[6];
	hear := f[7];
	ask := f[8];
	for(;;) alt {
	(off, nil, nil, rc) := <-ctl.read =>
		if(rc != nil)
			rc <-= (slice(array of byte ctlstatus(), off), nil);
	(nil, data, nil, wc) := <-ctl.write =>
		if(wc != nil)
			wc <-= reply(len data, ctlwrite(string data));

	(nil, nil, fid, rc) := <-talk.read =>
		t := talker(fid);
		if(rc == nil){
			droptalker(fid);
			continue;
		}
		t.rc = rc;
		telltalker(t);
	(nil, data, fid, wc) := <-talk.write =>
		if(wc == nil){
			droptalker(fid);
			continue;
		}
		e: string;
		case word(string data) {
		"start" =>	e = talkon();
		"stop" =>	talkoff();
		* =>	e = "talk is start or stop";
		}
		heartalk = 0;	# someone else has the switch now
		wc <-= reply(len data, e);

	(nil, count, fid, rc) := <-listen.read =>
		l := listener(fid);
		if(rc == nil){
			droplistener(fid);
			continue;
		}
		l.rc = rc;
		l.count = count;
		answerlistener(l);
	(nil, nil, fid, wc) := <-listen.write =>
		if(wc == nil){
			droplistener(fid);
			continue;
		}
		wc <-= (0, "listen is read");

	(off, nil, nil, rc) := <-say.read =>
		if(rc == nil)
			continue;
		s := "idle\n";
		if(speaking)
			s = "speaking " + speaktext + "\n";
		rc <-= (slice(array of byte s, off), nil);
	(nil, data, nil, wc) := <-say.write =>
		if(wc == nil)
			continue;
		text := string data;
		if(word(text) == nil){
			wc <-= (len data, nil);
			continue;
		}
		alt {
		sayc <-= text =>
			wc <-= (len data, nil);
		* =>
			wc <-= (0, "speech: too much queued to say");
		}

	(nil, nil, nil, rc) := <-cancel.read =>
		if(rc != nil)
			rc <-= (nil, "cancel is written");
	(nil, data, nil, wc) := <-cancel.write =>
		if(wc == nil)
			continue;
		docancel();
		wc <-= (len data, nil);

	(nil, nil, nil, rc) := <-chime.read =>
		if(rc != nil)
			rc <-= (nil, "chime is written");
	(nil, data, nil, wc) := <-chime.write =>
		if(wc == nil)
			continue;
		c := word(string data);
		case c {
		"start" or "stop" or "done" or "error" =>
			alt {
			chimec <-= c =>
				;
			* =>
				;
			}
			wc <-= (len data, nil);
		* =>
			wc <-= (0, "chime is start, stop, done or error");
		}

	(off, nil, nil, rc) := <-voices.read =>
		if(rc == nil)
			continue;
		(v, e) := readfile(engine + "/voices");
		if(e != nil)
			rc <-= (nil, e);
		else
			rc <-= (slice(array of byte v, off), nil);
	(nil, nil, nil, wc) := <-voices.write =>
		if(wc != nil)
			wc <-= (0, "voices is read");

	(nil, nil, fid, rc) := <-hear.read =>
		hearread(fid, 0, rc);
	(nil, data, fid, wc) := <-hear.write =>
		hearwrite(fid, 0, data, wc);
	(nil, nil, fid, rc) := <-ask.read =>
		hearread(fid, 1, rc);
	(nil, data, fid, wc) := <-ask.write =>
		hearwrite(fid, 1, data, wc);
	(fid, isask) := <-hearendc =>
		hearend(fid, isask);

	rec := <-recc =>
		for(l := listeners; l != nil; l = tl l){
			(hd l).queue = append((hd l).queue, rec);
			answerlistener(hd l);
		}
		if(prefix("final ", rec) || prefix("error ", rec)){
			words := finalwords(rec);
			for(hl := hearers; hl != nil; hl = tl hl){
				h := hd hl;
				# an ask hears only what the user began after it
				if(h.waiting && (!h.ask || talkseq > h.seq)){
					h.waiting = 0;
					h.words = words;
					answerhearer(h);
				}
			}
			if(heartalk){
				talkoff();
				heartalk = 0;
			}
			telltalkers();
		}
	(on, text) := <-spkc =>
		speaking = on;
		speaktext = text;
	}
}

#
# hear and ask
#

hearread(fid, isask: int, rc: Sys->Rread)
{
	h := hearer(fid, isask);
	if(rc == nil){
		drophearer(fid, isask);
		return;
	}
	# the words once, then end of file: whatever the offset, which
	# the write of start has moved (some readers seek back, some not)
	if(h.done){
		rc <-= (nil, nil);
		return;
	}
	if(!h.waiting && h.words == nil){
		rc <-= (nil, "speech: write start first");
		return;
	}
	h.rc = rc;
	answerhearer(h);
}

hearwrite(fid, isask: int, data: array of byte, wc: Sys->Rwrite)
{
	if(wc == nil){
		drophearer(fid, isask);
		return;
	}
	(n, w) := sys->tokenize(string data, " \t\n");
	what := "hear";
	if(isask)
		what = "ask";
	if(n < 1 || hd w != "start"){
		wc <-= (0, what + ": write start [ms]");
		return;
	}
	ms := Hearms;
	max := 60000;
	if(isask){
		ms = Askms;
		max = 120000;
	}
	if(n > 1)
		ms = int hd tl w;
	if(ms <= 0 || ms > max){
		wc <-= (0, sys->sprint("%s: start 1 to %d ms", what, max));
		return;
	}
	h := hearer(fid, isask);
	h.waiting = 1;
	h.words = nil;
	h.done = 0;
	h.seq = talkseq;
	e: string;
	# hear is the user's (a key pressed in the program that wrote it);
	# an ask is an agent's, and opens the microphone only if the user
	# has said agents may
	if(!talking && (!isask || agentmic)){
		e = talkon();
		if(e == nil)
			heartalk = 1;
	}
	if(e == nil)
		spawn hearlimit(fid, isask, ms);
	else
		h.waiting = 0;
	telltalkers();
	wc <-= reply(len data, e);
}

hearend(fid, isask: int)
{
	for(l := hearers; l != nil; l = tl l){
		h := hd l;
		if(h.fid != fid || h.ask != isask || !h.waiting)
			continue;
		if(heartalk){
			# the final, when it comes, answers
			talkoff();
			heartalk = 0;
		}else if(isask && !(talking && talkseq > h.seq)){
			# nothing begun in time: nothing heard
			h.waiting = 0;
			h.words = nil;
			answerhearer(h);
		}
	}
	telltalkers();
}

reply(n: int, e: string): (int, string)
{
	if(e != nil)
		return (0, e);
	return (n, nil);
}

#
# ctl
#

ctlstatus(): string
{
	state := "missing";
	if(sys->stat(engine + "/ctl").t0 >= 0)
		state = "ok";
	s := "engine " + engine + "\n";
	s += "engine " + state + "\n";
	if(voice != nil)
		s += "voice " + voice + "\n";
	if(lang != nil)
		s += "lang " + lang + "\n";
	if(model != nil)
		s += "model " + model + "\n";
	s += "duplex " + duplex + "\n";
	s += "agentmic " + onoff(agentmic) + "\n";
	s += "settings " + settings + "\n";
	s += "talk " + onoff(talking) + "\n";
	s += "asked " + string asking() + "\n";
	s += "speaking " + string speaking + "\n";
	return s;
}

ctlwrite(s: string): string
{
	(n, f) := sys->tokenize(s, " \t\n");
	if(n == 0)
		return nil;
	if(n != 2)
		return "speech: ctl is engine dir, voice v, lang l, model m, duplex half|full or agentmic off|on";
	v := hd tl f;
	case hd f {
	"engine" =>
		if(talking)
			return "speech: not while talk is on";
		engine = v;
		# its text read from now on, not the old engine's
		kill(textpid);
		starttext();
	"voice" =>
		if((e := enginectl("voice " + v)) != nil)
			return e;
		voice = v;
	"lang" =>
		if((e := enginectl("lang " + v)) != nil)
			return e;
		lang = v;
	"model" =>
		if(!safename(v))
			return "speech: a model is a name";
		if((e := enginectl("model " + v)) != nil)
			return e;
		model = v;
	"duplex" =>
		if(v != "half" && v != "full")
			return "speech: duplex is half or full";
		duplex = v;
	"agentmic" =>
		if(v != "on" && v != "off")
			return "speech: agentmic is off or on";
		agentmic = v == "on";
	* =>
		return "speech: no such setting " + hd f;
	}
	if(hd f != "engine")
		return savesettings();
	return nil;
}

# the settings kept, as ctl lines
loadsettings()
{
	(s, e) := readfile(settings);
	if(e != nil)
		return;
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l){
		(n, f) := sys->tokenize(hd l, " \t");
		if(n != 2)
			continue;
		v := hd tl f;
		case hd f {
		"voice" =>
			if(safename(v))
				voice = v;
		"lang" =>
			if(safename(v))
				lang = v;
		"model" =>
			if(safename(v))
				model = v;
		"duplex" =>
			if(v == "half" || v == "full")
				duplex = v;
		"agentmic" =>
			agentmic = v == "on";
		}
	}
}

savesettings(): string
{
	s := "";
	if(voice != nil)
		s += "voice " + voice + "\n";
	if(lang != nil)
		s += "lang " + lang + "\n";
	if(model != nil)
		s += "model " + model + "\n";
	s += "duplex " + duplex + "\n";
	s += "agentmic " + onoff(agentmic) + "\n";
	fd := sys->create(settings, Sys->OWRITE, 8r600);
	if(fd == nil){
		# its directory, once
		for(i := len settings - 1; i > 0 && settings[i] != '/'; i--)
			;
		if(i > 0)
			sys->create(settings[0:i], Sys->OREAD, Sys->DMDIR | 8r700);
		fd = sys->create(settings, Sys->OWRITE, 8r600);
	}
	b := array of byte s;
	if(fd == nil || sys->write(fd, b, len b) != len b)
		return sys->sprint("speech: set, but not kept in %s: %r", settings);
	return nil;
}

# what speech9p tells an engine of its own accord: the voice and language
# kept, which an engine started after them, or started again, has not had
syncengine()
{
	if(voice != nil)
		enginectl("voice " + voice);
	if(lang != nil)
		enginectl("lang " + lang);
	if(model != nil)
		enginectl("model " + model);
}

safename(s: string): int
{
	if(s == nil || len s > 64)
		return 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		     c == '.' || c == '-' || c == '_'))
			return 0;
	}
	return 1;
}

user(): string
{
	(s, nil) := readfile("/dev/user");
	if(s == nil)
		return "inferno";
	return s;
}

enginectl(s: string): string
{
	fd := sys->open(engine + "/ctl", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("speech: no engine at %s: %r", engine);
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("speech: engine: %r");
	return nil;
}

#
# talk: the microphone, to the engine
#

talkon(): string
{
	if(talking)
		return nil;
	syncengine();
	if((e := enginectl("start")) != nil)
		return e;
	(mic, e2) := openmic();
	if(mic == nil){
		enginectl("cancel");
		return e2;
	}
	afd := sys->open(engine + "/audio", Sys->OWRITE);
	if(afd == nil){
		enginectl("cancel");
		return sys->sprint("speech: engine audio: %r");
	}
	micstop = chan[1] of int;
	spawn micproc(mic, afd, micstop);
	talking = 1;
	talkseq++;
	telltalkers();
	return nil;
}

talkoff()
{
	if(!talking)
		return;
	micstop <-= 1;
	talking = 0;
	enginectl("end");
	telltalkers();
}

# the microphone as a stream of the shared device's at 16 kHz mono
openmic(): (ref Sys->FD, string)
{
	(c, dir) := newstream();
	if(c == nil)
		return (nil, sys->sprint("speech: no audio device: %r"));
	if(sys->fprint(c, "in rate %d chans 1 bits 16 enc pcm", Micrate) < 0)
		return (nil, sys->sprint("speech: microphone format: %r"));
	d := sys->open(dir + "/data", Sys->OREAD);
	if(d == nil)
		return (nil, sys->sprint("speech: microphone: %r"));
	return (d, nil);
}

# a stream of the shared device: its ctl and its directory
newstream(): (ref Sys->FD, string)
{
	for(l := "/dev/mix/" :: "#A/mix/" :: nil; l != nil; l = tl l){
		c := sys->open(hd l + "new", Sys->ORDWR);
		if(c == nil)
			continue;
		b := array[32] of byte;
		n := sys->read(c, b, len b);
		if(n <= 0)
			continue;
		(nil, w) := sys->tokenize(string b[0:n], " \n");
		if(w == nil)
			continue;
		return (c, hd l + hd w);
	}
	return (nil, nil);
}

micproc(mic, afd: ref Sys->FD, stop: chan of int)
{
	buf := array[Micchunk] of byte;
	for(;;){
		alt {
		<-stop =>
			return;
		* =>
			;
		}
		n := sys->read(mic, buf, len buf);
		if(n <= 0)
			return;
		# duplex half: what plays is not heard back
		if(speaking && duplex == "half")
			continue;
		if(sys->write(afd, buf, n) != n)
			return;
	}
}

#
# listen: the engine's text
#

starttext()
{
	pidc := chan of int;
	spawn textproc(pidc);
	textpid = <-pidc;
}

textproc(pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[8192] of byte;
	for(;;){
		fd := sys->open(engine + "/text", Sys->OREAD);
		if(fd == nil){
			sys->sleep(500);
			continue;
		}
		part := "";
		while((n := sys->read(fd, buf, len buf)) > 0){
			part += string buf[0:n];
			for(;;){
				i := 0;
				while(i < len part && part[i] != '\n')
					i++;
				if(i == len part)
					break;
				if(i > 0)
					recc <-= part[0:i];
				part = part[i+1:];
			}
		}
		sys->sleep(500);	# the engine went away, or was changed
	}
}

finalwords(rec: string): string
{
	if(prefix("error ", rec))
		return "error: " + rec[6:];
	# final confidence=N words
	(nil, f) := sys->tokenize(rec, " ");
	s := "";
	for(f = tl f; f != nil; f = tl f){
		if(prefix("confidence=", hd f) && s == "")
			continue;
		if(s != "")
			s += " ";
		s += hd f;
	}
	return s;
}

#
# say: the engine's sound, played as speech
#

startspeaker()
{
	pidc := chan of int;
	spawn speaker(pidc);
	speakerpid = <-pidc;
}

speaker(pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		text := <-sayc;
		spkc <-= (1, oneline(text));
		e := speak(text);
		if(e != nil)
			sys->fprint(stderr, "speech: %s\n", e);
		drained();
		spkc <-= (0, nil);
	}
}

speak(text: string): string
{
	syncengine();
	t := sys->open(engine + "/tts", Sys->ORDWR);
	if(t == nil)
		return sys->sprint("no engine at %s: %r", engine);
	b := array of byte text;
	if(sys->write(t, b, len b) != len b)
		return sys->sprint("engine tts: %r");
	rate := enginerate();
	if((e := speechstream(rate)) != nil)
		return e;
	buf := array[8192] of byte;
	off := big 0;
	while((n := sys->pread(t, buf, len buf, off)) > 0){
		off += big n;
		if(sys->write(spkdata, buf, n) != n)
			return sys->sprint("speaking: %r");
	}
	return nil;
}

# the engine's sound's rate, from its ctl
enginerate(): int
{
	(s, nil) := readfile(engine + "/ctl");
	(nil, l) := sys->tokenize(s, "\n");
	for(; l != nil; l = tl l){
		(n, f) := sys->tokenize(hd l, " ");
		if(n == 2 && hd f == "rate")
			return int hd tl f;
	}
	return 16000;
}

# the speech stream, in the engine's format; kept open between utterances
speechstream(rate: int): string
{
	if(spkdata != nil && rate == spkrate)
		return nil;
	if(spkctl == nil){
		(c, dir) := newstream();
		if(c == nil)
			return sys->sprint("no audio device: %r");
		spkdata = sys->open(dir + "/data", Sys->OWRITE);
		if(spkdata == nil)
			return sys->sprint("speech stream: %r");
		spkctl = c;
	}
	if(sys->fprint(spkctl, "out rate %d chans 1 bits 16 enc pcm role speech", rate) < 0)
		return sys->sprint("speech stream format: %r");
	spkrate = rate;
	return nil;
}

# until the speech stream has played what it holds
drained()
{
	if(spkctl == nil)
		return;
	b := array[512] of byte;
	for(i := 0; i < 600; i++){	# a minute at most
		n := sys->pread(spkctl, b, len b, big 0);
		if(n <= 0)
			return;
		(nil, l) := sys->tokenize(string b[0:n], "\n");
		for(; l != nil; l = tl l){
			(k, f) := sys->tokenize(hd l, " ");
			if(k == 2 && hd f == "queued" && int hd tl f == 0)
				return;
		}
		sys->sleep(100);
	}
}

docancel()
{
	# the queue, then what is playing
	for(;;) alt {
	<-sayc =>
		;
	* =>
		kill(speakerpid);
		if(spkctl != nil)
			sys->fprint(spkctl, "out flush");
		speaking = 0;
		speaktext = nil;
		startspeaker();
		return;
	}
}

#
# chime: earcons, synthesised here, as a stream with the role tone
#

chimeproc()
{
	fd: ref Sys->FD;
	ctl: ref Sys->FD;
	for(;;){
		c := <-chimec;
		if(fd == nil){
			dir: string;
			(ctl, dir) = newstream();
			if(ctl == nil)
				continue;
			if(sys->fprint(ctl, "out rate %d chans 1 bits 16 enc pcm role tone", Micrate) < 0)
				continue;
			fd = sys->open(dir + "/data", Sys->OWRITE);
			if(fd == nil)
				continue;
		}
		b: array of byte;
		case c {
		"start" =>	b = cat(beep(660.0, 70), beep(880.0, 90));
		"stop" =>	b = cat(beep(880.0, 70), beep(660.0, 90));
		"done" =>	b = beep(880.0, 120);
		"error" =>	b = cat(beep(330.0, 120), beep(262.0, 180));
		}
		sys->write(fd, b, len b);
	}
}

beep(hz: real, ms: int): array of byte
{
	n := Micrate * ms / 1000;
	b := array[2*n] of byte;
	fade := Micrate * 8 / 1000;
	for(i := 0; i < n; i++){
		g := 1.0;
		if(i < fade)
			g = real i / real fade;
		else if(n - i < fade)
			g = real (n - i) / real fade;
		v := int (6000.0 * g * math->sin(2.0 * Math->Pi * hz * real i / real Micrate));
		b[2*i] = byte v;
		b[2*i+1] = byte (v >> 8);
	}
	return b;
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

#
# the readers
#

talker(fid: int): ref Talker
{
	for(l := talkers; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	t := ref Talker(fid, nil, nil);
	talkers = t :: talkers;
	return t;
}

droptalker(fid: int)
{
	n: list of ref Talker;
	for(l := talkers; l != nil; l = tl l)
		if((hd l).fid != fid)
			n = hd l :: n;
	talkers = n;
}

telltalker(t: ref Talker)
{
	st := talkstate();
	if(t.rc == nil || t.told == st)
		return;
	t.told = st;
	t.rc <-= (array of byte (st + "\n"), nil);
	t.rc = nil;
}

# on or off, and asked while an agent waits to hear the user: what a
# microphone indicator shows
talkstate(): string
{
	s := onoff(talking);
	if(asking())
		s += " asked";
	return s;
}

asking(): int
{
	n := 0;
	for(l := hearers; l != nil; l = tl l)
		if((hd l).ask && (hd l).waiting)
			n++;
	return n;
}

telltalkers()
{
	for(l := talkers; l != nil; l = tl l)
		telltalker(hd l);
}

listener(fid: int): ref Listener
{
	for(l := listeners; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	r := ref Listener(fid, nil, nil, 0);
	listeners = r :: listeners;
	return r;
}

droplistener(fid: int)
{
	n: list of ref Listener;
	for(l := listeners; l != nil; l = tl l)
		if((hd l).fid != fid)
			n = hd l :: n;
	listeners = n;
}

answerlistener(r: ref Listener)
{
	if(r.rc == nil || r.queue == nil)
		return;
	b := array of byte (hd r.queue + "\n");
	r.queue = tl r.queue;
	if(len b > r.count)
		b = b[0:r.count];
	r.rc <-= (b, nil);
	r.rc = nil;
}

hearer(fid, isask: int): ref Hearer
{
	for(l := hearers; l != nil; l = tl l)
		if((hd l).fid == fid && (hd l).ask == isask)
			return hd l;
	h := ref Hearer(fid, isask, 0, 0, nil, 0, nil);
	hearers = h :: hearers;
	return h;
}

drophearer(fid, isask: int)
{
	n: list of ref Hearer;
	for(l := hearers; l != nil; l = tl l)
		if((hd l).fid != fid || (hd l).ask != isask)
			n = hd l :: n;
	hearers = n;
	if(heartalk && n == nil){
		talkoff();
		heartalk = 0;
	}
	telltalkers();
}

answerhearer(h: ref Hearer)
{
	if(h.rc == nil || h.waiting)
		return;
	h.rc <-= (array of byte h.words, nil);
	h.rc = nil;
	h.done = 1;
}

hearlimit(fid, isask, ms: int)
{
	sys->sleep(ms);
	hearendc <-= (fid, isask);
}

#
# odds and ends
#

word(s: string): string
{
	(nil, f) := sys->tokenize(s, " \t\n");
	if(f == nil)
		return nil;
	return hd f;
}

oneline(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			s[i] = ' ';
	return s;
}

onoff(b: int): string
{
	if(b)
		return "on";
	return "off";
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

append(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: append(tl l, s);
}

slice(b: array of byte, off: int): array of byte
{
	if(off >= len b)
		return nil;
	return b[off:];
}

readfile(f: string): (string, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%s: %r", f));
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return (s, nil);
}

kill(pid: int)
{
	if(pid < 0)
		return;
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}
