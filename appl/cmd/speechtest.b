implement Speechtest;

#
# speechtest - exercise the /n/speech STT/TTS surface without an LLM.
#
# Reads streaming transcripts from <speech>/listen, prints partials to
# stdout as they arrive, and answers every non-junk final transcript by
# speaking a fixed phrase (or the transcript itself with -e) through
# <speech>/say. No LLM, no GUI, no login, no API key: a self-contained
# microphone -> STT -> TTS loop for validating speech providers, audio
# topologies, and helper installs before paying for a model.
#
# If <speech>/ctl does not exist and -b is given, speechtest bootstraps
# the standard provider stack in its own namespace: it spawns
# speechshim9p at /n/speechshim and speech9p at <speech>, then points
# the provider at the shim and sets duplex half (the same sequence as
# lib/lucifer/boot.sh). -H <bindir> applies the host-helper ctl block
# produced by tools/install-speech-helpers.sh; -c 'key value' appends
# raw ctl lines (repeatable) — that is how remote-audio topologies are
# selected, and -M 'dialaddr mountpt' (repeatable, unauthenticated)
# mounts a remote 9P export first. See docs/SPEECH-REMOTE-AUDIO.md.
#
# Host-side launcher: tools/speech-test.sh.
#
# The listen wire format and the junk-final filter are kept in sync
# with appl/cmd/voicemode.b (newline-delimited "partial <text>" /
# "final <text>" / "error: <reason>" records; bare text is a final).
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "string.m";
	str: String;

Speechtest: module
{
	PATH: con "/dis/speechtest.dis";
	init: fn(nil: ref Draw->Context, args: list of string);
};

Srv: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

SHIMPATH: con "/dis/veltro/speechshim9p.dis";
SPEECH9PPATH: con "/dis/veltro/speech9p.dis";
SHIMMNT: con "/n/speechshim";

stderr: ref Sys->FD;
debug := 0;
speech := "/n/speech";
phrase := "Speech test complete. I heard you.";
echoback := 0;
turns := 0;
bootstrap := 0;
bootstrapped := 0;

LISTEN_EMPTY, LISTEN_PARTIAL, LISTEN_FINAL, LISTEN_ERROR: con iota;

silencefinals := array[] of {
	"thank you",
	"thanks for watching",
	"you",
};

log(msg: string)
{
	if(debug)
		sys->fprint(stderr, "speechtest: %s\n", msg);
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

ispartial(s: string): int
{
	s = strip(s);
	return s != nil && hasprefix(s, "partial ");
}

parselisten(s: string): (int, string)
{
	s = strip(s);
	if(s == nil || s == "")
		return (LISTEN_EMPTY, nil);
	kind := LISTEN_EMPTY;
	text := "";
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
				text = strip(line[8:]);
			}
			continue;
		}
		t := finaltext(line);
		if(t != nil && t != "") {
			kind = LISTEN_FINAL;
			text = t;
		}
	}
	return (kind, text);
}

errline(s: string): string
{
	(nil, lines) := sys->tokenize(s, "\n");
	for(; lines != nil; lines = tl lines) {
		line := strip(hd lines);
		if(hasprefix(line, "error:"))
			return line;
	}
	return "error: unknown listen failure";
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

chime(kind: string)
{
	writefile(speech + "/chime", kind);
}

exists(path: string): int
{
	(ok, nil) := sys->stat(path);
	return ok == 0;
}

waitfile(path: string, ms: int): int
{
	for(waited := 0; waited < ms; waited += 100) {
		if(exists(path))
			return 1;
		sys->sleep(100);
	}
	return exists(path);
}

startsrv(dis: string, argv: list of string, ready: string): string
{
	srv := load Srv dis;
	if(srv == nil)
		return sys->sprint("cannot load %s: %r", dis);
	spawn srv->init(nil, argv);
	if(!waitfile(ready, 5000))
		return sys->sprint("%s did not serve %s within 5s", dis, ready);
	return nil;
}

ctlwrite(line: string)
{
	if(writefile(speech + "/ctl", line) < 0)
		sys->fprint(stderr, "speechtest: ctl write failed: %s: %r\n", line);
	else
		log("ctl: " + line);
}

# The standard host-helper configuration, mirroring the ctl block that
# tools/install-speech-helpers.sh prints (listen + TTS only; wake is not
# used here). bindir is a HOST path — helpers run through devcmd.
helperctl(bindir: string)
{
	modeldir := bindir + "/../models";
	if(len bindir > 4 && bindir[len bindir - 4:] == "/bin")
		modeldir = bindir[:len bindir - 4] + "/models";
	ctlwrite("kokorobin " + bindir + "/kokoro-cli");
	ctlwrite("whisperstreambin " + bindir + "/whisper-stream-cli");
	ctlwrite("whispermodel " + modeldir + "/ggml-base.en.bin");
	ctlwrite("voice af_bella");
}

# Unauthenticated 9P mount for remote-topology tests (a remote provider
# or a remote capture device exported with styxlisten -A on a trusted
# network). spec: "dialaddr mountpt".
domount(spec: string): string
{
	(n, flds) := sys->tokenize(spec, " \t");
	if(n != 2)
		return "usage: -M 'dialaddr mountpt'";
	addr := hd flds;
	mnt := hd tl flds;
	(ok, conn) := sys->dial(addr, nil);
	if(ok < 0)
		return sys->sprint("dial %s: %r", addr);
	sys->create(mnt, Sys->OREAD, Sys->DMDIR | 8r755);
	if(sys->mount(conn.dfd, nil, mnt, Sys->MREPL | Sys->MCREATE, "") < 0)
		return sys->sprint("mount %s on %s: %r", addr, mnt);
	sys->print("speechtest: mounted %s at %s\n", addr, mnt);
	return nil;
}

fatal(msg: string)
{
	sys->fprint(stderr, "speechtest: %s\n", msg);
	raise "fail:" + msg;
}

# Take the servers we spawned (same process group) down with us so a
# bootstrapped headless emu halts instead of idling forever.
killgrp()
{
	pid := sys->pctl(0, nil);
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil) {
		b := array of byte "killgrp";
		sys->write(fd, b, len b);
	}
}

finish(completed: int)
{
	chime("off");
	sys->print("speechtest: %d turn(s) completed\n", completed);
	if(bootstrapped)
		killgrp();
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	str = load String String->PATH;
	arg := load Arg Arg->PATH;
	if(str == nil || arg == nil) {
		sys->fprint(stderr, "speechtest: cannot load modules: %r\n");
		raise "fail:load";
	}

	arg->init(args);
	arg->setusage("speechtest [-bde] [-n turns] [-p phrase] [-s /n/speech] " +
		"[-H helperbindir] [-c 'key value'] [-M 'dialaddr mountpt']");
	ctllines: list of string;
	mounts: list of string;
	helperbin := "";
	while((c := arg->opt()) != 0)
		case c {
		'b' =>	bootstrap = 1;
		'd' =>	debug = 1;
		'e' =>	echoback = 1;
		'n' =>	turns = int arg->earg();
		'p' =>	phrase = arg->earg();
		's' =>	speech = arg->earg();
		'H' =>	helperbin = arg->earg();
		'c' =>	ctllines = arg->earg() :: ctllines;
		'M' =>	mounts = arg->earg() :: mounts;
		* =>	arg->usage();
		}
	ctllines = rev(ctllines);
	mounts = rev(mounts);

	for(m := mounts; m != nil; m = tl m) {
		err := domount(hd m);
		if(err != nil)
			fatal(err);
	}

	if(bootstrap && !exists(speech + "/ctl")) {
		sys->print("speechtest: starting speech stack (speechshim9p + speech9p)\n");
		err := startsrv(SHIMPATH, "speechshim9p" :: "-m" :: SHIMMNT :: nil,
			SHIMMNT + "/ctl");
		if(err == nil)
			err = startsrv(SPEECH9PPATH, "speech9p" :: "-m" :: speech :: nil,
				speech + "/ctl");
		if(err != nil)
			fatal(err);
		bootstrapped = 1;
		ctlwrite("provider " + SHIMMNT);
		ctlwrite("duplex half");
	}

	if(helperbin != "")
		helperctl(helperbin);
	for(; ctllines != nil; ctllines = tl ctllines)
		ctlwrite(hd ctllines);

	saywhat := "\"" + phrase + "\"";
	if(echoback)
		saywhat = "the transcript back";
	sys->print("speechtest: listening on %s — speak; every final transcript answers with %s\n",
		speech, saywhat);
	chime("on");

	completed := 0;
	lastpartial := "";
	lastjunk := "";
	for(;;) {
		rec := readfile(speech + "/listen");
		(kind, text) := parselisten(rec);
		case kind {
		LISTEN_EMPTY =>
			sys->sleep(250);
		LISTEN_ERROR =>
			sys->print("%s\n", errline(rec));
			sys->sleep(1000);
		LISTEN_PARTIAL =>
			if(text != lastpartial) {
				sys->print("partial: %s\n", text);
				lastpartial = text;
			} else
				sys->sleep(100);
		LISTEN_FINAL =>
			lastpartial = "";
			if(junkfinal(text)) {
				if(text != lastjunk) {
					sys->print("final:   %s   (junk — ignored)\n", text);
					lastjunk = text;
				}
				sys->sleep(250);
			} else {
				lastjunk = "";
				completed++;
				sys->print("final:   %s\n", text);
				saytext := phrase;
				if(echoback)
					saytext = text;
				sys->print("say:     %s\n", saytext);
				t0 := sys->millisec();
				if(writefile(speech + "/say", saytext) < 0)
					sys->print("say error: %r\n");
				else
					sys->print("say done (%d ms)\n", sys->millisec() - t0);
				chime("done");
				if(turns > 0 && completed >= turns) {
					finish(completed);
					return;
				}
			}
		}
	}
}
