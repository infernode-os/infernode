implement Speechshim9p;

#
# speechshim9p - adapt external host speech helper CLIs to the speech
# provider contract (docs/SPEECH-ARCHITECTURE.md):
#
#   /n/speechshim/
#   ├── ctl      (rw)  kokorobin, whisperstreambin, wakebin, wakeword,
#   │                  wakethreshold, whispermodel, voice, rate,
#   │                  audiodev, capturedev, micmode, capturerate,
#   │                  mic on|off
#   ├── listen   (r)   newline records from the streaming STT helper:
#   │                  "partial [confidence=N] <text>" /
#   │                  "final [confidence=N] <text>" / "error: <reason>"
#   ├── wake     (r)   blocks until the wake-word helper emits an event line
#   ├── say      (rw)  write text: Kokoro synthesizes PCM, played through
#   │                  /dev/audio in chunks; read returns the status
#   ├── cancel   (w)   kills the active TTS helper process and stops playback
#   ├── chime    (w)   local earcons: wake, done, on, off
#   └── voices   (r)   helper voice list
#
# speech9p consumes this mount exactly as it consumes a parakeet export or a
# remote provider — the helper binaries are an implementation detail behind
# the namespace. The helpers themselves are external installs (whisper.cpp
# stream, kokoro-onnx wrapper, openWakeWord wrapper); every path soft-fails
# with an "error: ..." record when a helper is absent.
#
# Host processes run through #C (devcmd). Streaming helpers (listen, wake)
# are started lazily by the first listen/wake read and read incrementally;
# killonclose is armed so they die with the shim. The microphone is thus
# only open while a client is actually reading: nothing runs at boot, and
# `mic off` on ctl tears the mic-side helpers down again (voicemode writes
# it when the user leaves voice mode) — the next read re-arms them. TTS is
# killed on cancel via the devcmd ctl "kill" command, and playback checks
# the cancel flag between chunks, so barge-in silence is bounded by one
# audio chunk rather than the remaining utterance.
#
# Audio routing (docs/SPEECH-REMOTE-AUDIO.md): playback always goes through
# the namespace (`audiodev`, default /dev/audio), so binding an imported
# remote audio device remotes the speakers with no shim changes. Capture has
# two modes:
#   micmode helper  (default) the helper CLI grabs the host microphone
#                   itself — right when the shim runs on the machine the
#                   user talks to.
#   micmode device  the shim reads s16le mono PCM from `capturedev` (falls
#                   back to `audiodev`) at `capturerate` and tees it into
#                   the stdin of the listen/wake helpers. The microphone is
#                   then just a namespace entry — an Android phone's or GUI
#                   terminal's exported /dev/audio works the same as the
#                   local device.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

include "math.m";
	math: Math;

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;

Speechshim9p: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

Qroot, Qctl, Qlisten, Qwake, Qsay, Qcancel, Qvoices, Qchime: con iota;

# Bytes of helper stderr retained for diagnostics (see Hostproc.errtail).
ERRTAIL: con 512;

# Configuration
kokorobin := "kokoro-cli";
whisperstreambin := "whisper-stream";
wakebin := "openwakeword-cli";
wakeword := "hey lucia";
wakethreshold := "0.5";
whispermodel := "";
voice := "af_bella";
audrate := 24000;
audiodev := "/dev/audio";
capturedev := "";		# capture override; empty = audiodev
micmode := "helper";		# helper | device
capturerate := 16000;
duplex := "full";		# full | half
standby := 0;			# mic off: no helper (re)starts until the next listen/wake read
listenoff := 0;			# listen off: the STT helper stays down until the next listen read

stderr: ref Sys->FD;
user: string;
mountpt := "/n/speechshim";
cmdbound := 0;
audiobound := 0;
cancelreq := 0;
playing := 0;

# A host helper process behind #C. ctlfd is the clone fd (kept open —
# killonclose is armed on it); writing "kill" to it terminates the process.
Hostproc: adt {
	ctlfd:  ref Sys->FD;
	datafd: ref Sys->FD;
	dir:    string;
	# Tail of the helper's stderr, kept by a drain proc. A helper that fails
	# to start (missing binary, bad model path) exits immediately and the only
	# account of why is on its stderr — devcmd would otherwise discard it and
	# leave us reporting a bare "helper exited". The drain also keeps the pipe
	# from filling: whisper-stream is chatty on stderr, and a full pipe would
	# block it.
	errtail: string;
	errdone: chan of string;
	outbuf:  string;
};

listenproc: ref Hostproc;
wakeproc: ref Hostproc;
sayproc: ref Hostproc;

# Per-fid say state (same contract as speech9p's say file)
FidState: adt {
	fid:     int;
	sayresp: array of byte;
	saydone: chan of array of byte;
};
fidstates: list of ref FidState;

# Async read plumbing (same shape as speech9p's Helperdone machinery):
# blocking helper reads run in spawned procs and complete through helperc,
# so the serveloop — and with it ctl and cancel — stays live.
Helperdone: adt {
	kind:   int;                # Qlisten, Qwake, Qsay
	fid:    int;
	m:      ref Tmsg.Read;
	result: array of byte;
};
helperc: chan of ref Helperdone;
asyncpending: list of (int, int);   # (tag, fid)
listenbusy := 0;
wakebusy := 0;

# Capture pump (micmode device): one proc owns the capture device and the
# helper stdin sinks; registration and reset arrive over pumpc so there is
# no shared mutable state between the pump and the 9P side.
SINKLISTEN, SINKWAKE, SINKRESET, SINKQUIT: con iota;
pumpc: chan of (int, ref Sys->FD);
pumprunning := 0;

nomod(s: string)
{
	sys->fprint(stderr, "speechshim9p: can't load %s: %r\n", s);
	raise "fail:load";
}

usage()
{
	sys->fprint(stderr, "Usage: speechshim9p [-D] [-m mountpoint]\n");
	raise "fail:usage";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);

	styx = load Styx Styx->PATH;
	if(styx == nil)
		nomod(Styx->PATH);
	styx->init();

	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil)
		nomod(Styxservers->PATH);
	styxservers->init(styx);

	arg := load Arg Arg->PATH;
	if(arg == nil)
		nomod(Arg->PATH);
	math = load Math Math->PATH;
	if(math == nil)
		nomod(Math->PATH);
	arg->init(args);
	while((o := arg->opt()) != 0)
		case o {
		'D' =>	styxservers->traceset(1);
		'm' =>	mountpt = arg->earg();
		* =>	usage();
		}
	arg = nil;

	sys->pctl(Sys->FORKFD, nil);

	user = rf("/dev/user");
	if(user == nil)
		user = "inferno";

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "speechshim9p: can't create pipe: %r\n");
		raise "fail:pipe";
	}

	helperc = chan of ref Helperdone;
	pumpc = chan[4] of (int, ref Sys->FD);

	navops := chan of ref Navop;
	spawn navigator(navops);

	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;

	pidc := chan of int;
	spawn serveloop(tchan, srv, pidc, navops);
	<-pidc;

	ensuredir(mountpt);

	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "speechshim9p: mount failed: %r\n");
		raise "fail:mount";
	}
}

# === Host process management (devcmd) ===

bindcmd()
{
	if(cmdbound)
		return;
	if(sys->stat("/cmd/clone").t0 == -1)
		sys->bind("#C", "/", Sys->MBEFORE);
	cmdbound = 1;
}

bindaudio()
{
	if(audiobound)
		return;
	if(sys->stat("/dev/audio").t0 == -1)
		sys->bind("#A", "/dev", Sys->MBEFORE);
	audiobound = 1;
}

openaudioout(rate: int): ref Sys->FD
{
	if(audiodev == "/dev/audio")
		bindaudio();
	ctl := sys->open(audiodev + "ctl", Sys->OWRITE);
	if(ctl != nil) {
		writectl(ctl, sys->sprint("out rate %d", rate));
		writectl(ctl, "out chans 1");
		writectl(ctl, "out bits 16");
		writectl(ctl, "out enc pcm");
		ctl = nil;
	}
	return sys->open(audiodev, Sys->OWRITE);
}

# Start a host command; the process dies with the shim (killonclose) or on
# killproc(). Returns (proc, nil) or (nil, error string).
startproc(cmd: string): (ref Hostproc, string)
{
	bindcmd();

	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		return (nil, sys->sprint("error: cannot open /cmd/clone: %r"));

	buf := array[32] of byte;
	n := sys->read(cfd, buf, len buf);
	if(n <= 0)
		return (nil, "error: cannot read cmd number");
	dir := "/cmd/" + string buf[0:n];

	sys->fprint(cfd, "killonclose");
	if(sys->fprint(cfd, "exec /bin/sh -c '%s'", cmd) < 0)
		return (nil, sys->sprint("error: exec failed: %r"));

	datafd := sys->open(dir + "/data", Sys->OREAD);
	if(datafd == nil)
		return (nil, sys->sprint("error: cannot open %s/data: %r", dir));

	p := ref Hostproc(cfd, datafd, dir, "", chan[1] of string, "");
	errfd := sys->open(dir + "/stderr", Sys->OREAD);
	if(errfd != nil)
		spawn drainstderr(p, errfd);

	return (p, nil);
}

# Keep the helper's stderr drained, retaining only the tail for diagnostics.
drainstderr(p: ref Hostproc, errfd: ref Sys->FD)
{
	buf := array[1024] of byte;
	for(;;) {
		n := sys->read(errfd, buf, len buf);
		if(n <= 0) {
			p.errdone <-= p.errtail;
			return;
		}
		s := p.errtail + string buf[0:n];
		if(len s > ERRTAIL)
			s = s[len s - ERRTAIL:];
		p.errtail = s;
	}
}

# Return one newline-delimited helper record. Host pipe reads may split a
# record arbitrarily, so retain an incomplete tail on the process rather than
# exposing it as a transcript or wake event.
readrecord(p: ref Hostproc): (string, int)
{
	for(;;) {
		for(i := 0; i < len p.outbuf; i++)
			if(p.outbuf[i] == '\n') {
				record := p.outbuf[0:i+1];
				p.outbuf = p.outbuf[i+1:];
				return (record, 1);
			}

		buf := array[8192] of byte;
		n := sys->read(p.datafd, buf, len buf);
		if(n <= 0) {
			if(p.outbuf != "") {
				record := p.outbuf;
				p.outbuf = "";
				return (record, 1);
			}
			return ("", 0);
		}
		p.outbuf += string buf[0:n];
	}
}

after(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# One-line summary of why a helper died, for the "error:" record the client
# sees. Falls back to the caller's generic reason when stderr said nothing.
exitreason(p: ref Hostproc, dflt: string): string
{
	if(p == nil)
		return dflt;
	# stdout EOF and stderr EOF are delivered independently by #C. Wait briefly
	# for the drainer's completion signal, but never let diagnostics wedge the
	# voice daemon if a helper closes stdout while retaining stderr.
	p.datafd = nil;
	p.ctlfd = nil;	# killonclose also lets /stderr reach EOF
	if(p.errdone != nil) {
		timeoutc := chan[1] of int;
		spawn after(timeoutc, 250);
		alt {
		tail := <-p.errdone =>
			p.errtail = tail;
		<-timeoutc =>
			;
		}
	}
	# Last non-blank line: host sh puts "not found" style errors there.
	(nil, lines) := sys->tokenize(p.errtail, "\n\r");
	last := "";
	for(; lines != nil; lines = tl lines) {
		l := strip(hd lines);
		if(l != "")
			last = l;
	}
	if(last == "")
		return dflt;
	return dflt + ": " + last;
}

killproc(p: ref Hostproc)
{
	if(p != nil && p.ctlfd != nil)
		sys->fprint(p.ctlfd, "kill");
}

closeproc(p: ref Hostproc)
{
	if(p == nil)
		return;
	p.datafd = nil;
	p.ctlfd = nil;
}

# One-shot host command, full stdout.
runcmd(cmd: string): string
{
	(p, err) := startproc(cmd);
	if(p == nil)
		return err;
	result := "";
	rbuf := array[8192] of byte;
	for(;;) {
		n := sys->read(p.datafd, rbuf, len rbuf);
		if(n <= 0)
			break;
		result += string rbuf[0:n];
	}
	closeproc(p);
	return result;
}

# === Capture pump (micmode device) ===

capdev(): string
{
	if(capturedev != "")
		return capturedev;
	return audiodev;
}

# Register a running helper's stdin as a pump sink.
addsink(kind: int, p: ref Hostproc)
{
	wfd := sys->open(p.dir + "/data", Sys->OWRITE);
	if(wfd == nil)
		return;
	if(!pumprunning) {
		pumprunning = 1;
		spawn audiopump();
	}
	pumpc <-= (kind, wfd);
}

pumpreset()
{
	if(pumprunning)
		pumpc <-= (SINKRESET, nil);
}

opencapture(): ref Sys->FD
{
	dev := capdev();
	if(dev == "/dev/audio")
		bindaudio();
	ctl := sys->open(dev + "ctl", Sys->OWRITE);
	if(ctl != nil) {
		writectl(ctl, sys->sprint("in rate %d", capturerate));
		writectl(ctl, "in chans 1");
		writectl(ctl, "in bits 16");
		writectl(ctl, "in enc pcm");
		ctl = nil;
	}
	return sys->open(dev, Sys->OREAD);
}

# Read s16le mono PCM from the capture device and tee it into the stdin of
# the registered streaming helpers. The device is held open only while a
# sink is registered. On device EOF (an exported file exhausted, an import
# torn down) the sinks are closed so the helpers see stdin EOF and can
# flush a final record.
audiopump()
{
	sinks := array[2] of ref Sys->FD;
	afd: ref Sys->FD;
	for(;;) {
		if(sinks[SINKLISTEN] == nil && sinks[SINKWAKE] == nil) {
			afd = nil;	# release the device while idle
			(k, fd) := <-pumpc;
			if(k == SINKQUIT)
				return;
			if(k != SINKRESET)
				sinks[k] = fd;
			continue;
		}
	Drain:
		for(;;) alt {
		(k, fd) := <-pumpc =>
			if(k == SINKQUIT)
				return;
			if(k == SINKRESET) {
				afd = nil;
				sinks[SINKLISTEN] = nil;
				sinks[SINKWAKE] = nil;
			} else
				sinks[k] = fd;
		* =>
			break Drain;
		}
		if(sinks[SINKLISTEN] == nil && sinks[SINKWAKE] == nil)
			continue;
		if(afd == nil) {
			afd = opencapture();
			if(afd == nil) {
				sinks[SINKLISTEN] = nil;
				sinks[SINKWAKE] = nil;
				continue;
			}
		}
		chunk := capturerate / 10 * 2;	# 100ms of s16 mono
		if(chunk < 512)
			chunk = 512;
		buf := array[chunk] of byte;
		n := sys->read(afd, buf, len buf);
		if(n <= 0) {
			afd = nil;
			sinks[SINKLISTEN] = nil;
			sinks[SINKWAKE] = nil;
			continue;
		}
		if(duplex == "half" && playing)
			continue;
		for(k := 0; k < 2; k++)
			if(sinks[k] != nil && sys->write(sinks[k], buf[0:n], n) < 0)
				sinks[k] = nil;	# helper died; drop the sink
	}
}

# === Streaming reads (listen / wake) ===

listencmd(): string
{
	if(micmode == "device")
		return whisperstreambin + " --stdin --model " + whispermodel +
			" --rate " + string capturerate + " --chans 1";
	return whisperstreambin + " --model " + whispermodel +
		" --rate 16000 --chans 1";
}

wakecmd(): string
{
	if(micmode == "device")
		return wakebin + " --stdin --word \"" + wakeword + "\" --threshold " +
			wakethreshold + " --rate " + string capturerate;
	# startproc wraps the complete host command in single quotes for #C.
	# Use double quotes here so a multiword phrase remains one host-shell arg
	# without terminating that outer command string.
	return wakebin + " --word \"" + wakeword + "\" --threshold " +
		wakethreshold;
}

# Read the next chunk of newline records from a streaming helper, starting
# it on first use. Runs in a spawned proc; the globals it resets on EOF are
# also reset by ctl writes, which is benign — the next read restarts the
# helper either way.
readlisten(): string
{
	if(whisperstreambin == "")
		return "error: listen helper not configured";
	standby = 0;		# an active reader arms the microphone
	listenoff = 0;		# a new listen turn re-arms the STT helper
	last: ref Hostproc;	# last helper to die, for its stderr
	# One restart attempt: a stale fd from an exited helper (one-shot
	# helpers exit after each utterance) must not eat a read as an error.
	for(attempt := 0; attempt < 2; attempt++) {
		if(listenproc == nil) {
			(p, err) := startproc(listencmd());
			if(p == nil)
				return err;
			listenproc = p;
			if(micmode == "device")
				addsink(SINKLISTEN, p);
			if(standby || listenoff) {
				# `mic off`/`listen off` raced the start; honor it.
				killproc(p);
				listenproc = nil;
				return "error: mic off";
			}
		}
		(record, ok) := readrecord(listenproc);
		if(ok)
			return record;
		dead := listenproc;
		listenproc = nil;
		# `mic off`/`listen off` while blocked in the read above kills
		# the helper; return instead of restarting it.
		if(standby)
			return "error: mic off";
		if(listenoff)
			return "error: listen off";
		last = dead;
	}
	return exitreason(last, "error: listen helper exited");
}

readwake(): string
{
	if(wakebin == "")
		return "error: wake helper not configured";
	standby = 0;		# an active reader arms the microphone
	last: ref Hostproc;	# last helper to die, for its stderr
	# One restart attempt, same reason as readlisten: one-shot wake
	# helpers exit after each event and must be restarted transparently.
	attempt := 0;
	for(;;) {
		# `mic off` while blocked in the read below kills the helper;
		# return instead of restarting it.
		if(standby)
			return "error: mic off";
		if(wakeproc == nil) {
			(p, err) := startproc(wakecmd());
			if(p == nil)
				return err;
			wakeproc = p;
			if(micmode == "device")
				addsink(SINKWAKE, p);
			if(standby) {
				# `mic off` raced the start; honor it.
				killproc(p);
				wakeproc = nil;
				return "error: mic off";
			}
		}
		(record, ok) := readrecord(wakeproc);
		if(ok) {
			if(duplex == "half" && playing) {
				killproc(wakeproc);
				closeproc(wakeproc);
				wakeproc = nil;
				sys->sleep(100);
				continue;
			}
			return record;
		}
		last = wakeproc;
		wakeproc = nil;
		attempt++;
		if(attempt >= 2) {
			if(!(duplex == "half" && playing))
				break;
			# A dead helper (exits with no output — e.g. not
			# installed) must not spawn-storm while playback pins
			# us in the suppression loop.
			sys->sleep(100);
		}
	}
	return exitreason(last, "error: wake helper exited");
}

# === TTS (say) ===

# Kokoro contract: text on stdin, s16le mono PCM at the requested rate on
# stdout. Playback is chunked so a cancel takes effect within one chunk.
dosay(text: string): string
{
	if(kokorobin == "")
		return "error: kokoro helper not configured";
	text = strip(text);
	if(text == "")
		return "error: no speakable text";
	cancelreq = 0;

	cmd := kokorobin + " --voice " + voice + " --format pcm --rate " + string audrate;
	(p, err) := startproc(cmd);
	if(p == nil)
		return err;
	sayproc = p;

	# Feed text on stdin, close to signal EOF.
	tofd := sys->open(p.dir + "/data", Sys->OWRITE);
	if(tofd == nil) {
		killproc(p);
		closeproc(p);
		sayproc = nil;
		return sys->sprint("error: cannot open %s/data for write: %r", p.dir);
	}
	b := array of byte (text + "\n");
	sys->write(tofd, b, len b);
	tofd = nil;

	afd := openaudioout(audrate);

	total := 0;
	buf := array[8192] of byte;
	status := "";
	playing = 1;
	for(;;) {
		n := sys->read(p.datafd, buf, len buf);
		if(n <= 0)
			break;
		if(cancelreq) {
			killproc(p);
			status = "error: speech canceled";
			break;
		}
		if(afd == nil)
			continue;	# drain helper; no audio device
		if(sys->write(afd, buf[0:n], n) < 0) {
			status = sys->sprint("error: audio write failed: %r");
			killproc(p);
			break;
		}
		total += n;
	}
	playing = 0;
	closeproc(p);
	sayproc = nil;
	if(status != "")
		return status;
	if(total == 0) {
		if(afd == nil)
			return sys->sprint("error: cannot open %s: %r", audiodev);
		return "error: kokoro produced no audio";
	}
	return sys->sprint("ok: played %d bytes", total);
}

put16le(buf: array of byte, off, val: int)
{
	buf[off] = byte (val & 16rFF);
	buf[off+1] = byte ((val >> 8) & 16rFF);
}

playnote(fd: ref Sys->FD, freq, ms: int)
{
	nsamp := audrate * ms / 1000;
	if(nsamp <= 0)
		return;
	buf := array[nsamp * 2] of byte;
	for(i := 0; i < nsamp; i++) {
		v := int (12000.0 * math->sin(2.0 * Math->Pi *
			real freq * real i / real audrate));
		put16le(buf, i * 2, v);
	}
	sys->write(fd, buf, len buf);
}

playchime(kind: string)
{
	afd := openaudioout(audrate);
	if(afd != nil) {
		case kind {
		"wake" =>
			playnote(afd, 660, 120);
			playnote(afd, 880, 120);
		"done" =>
			playnote(afd, 440, 140);
		"on" =>
			playnote(afd, 523, 90);
			playnote(afd, 659, 90);
			playnote(afd, 784, 120);
		"off" =>
			playnote(afd, 784, 90);
			playnote(afd, 659, 90);
			playnote(afd, 523, 120);
		}
	}
	playing = 0;
}

startchime(kind: string)
{
	kind = strip(kind);
	case kind {
	"wake" or "done" or "on" or "off" =>
		playing = 1;
		spawn playchime(kind);
	* =>
		sys->fprint(stderr, "speechshim9p: unknown chime: %s\n", kind);
	}
}

asyncsay(donech: chan of array of byte, text: string)
{
	donech <-= array of byte dosay(text);
}

# === Async read completion (same pattern as speech9p) ===

addasync(tag, fid: int)
{
	asyncpending = (tag, fid) :: asyncpending;
}

isasync(tag: int): int
{
	for(l := asyncpending; l != nil; l = tl l) {
		(t, nil) := hd l;
		if(t == tag)
			return 1;
	}
	return 0;
}

cancelasynctag(tag: int)
{
	newlist: list of (int, int);
	for(l := asyncpending; l != nil; l = tl l) {
		(t, nil) := hd l;
		if(t != tag)
			newlist = hd l :: newlist;
	}
	asyncpending = newlist;
}

cancelasyncfid(fid: int)
{
	newlist: list of (int, int);
	for(l := asyncpending; l != nil; l = tl l) {
		(nil, f) := hd l;
		if(f != fid)
			newlist = hd l :: newlist;
	}
	asyncpending = newlist;
}

asynclisten(donec: chan of ref Helperdone, m: ref Tmsg.Read)
{
	donec <-= ref Helperdone(Qlisten, m.fid, m, array of byte readlisten());
}

asyncwake(donec: chan of ref Helperdone, m: ref Tmsg.Read)
{
	donec <-= ref Helperdone(Qwake, m.fid, m, array of byte readwake());
}

saywait(donec: chan of ref Helperdone, m: ref Tmsg.Read, ch: chan of array of byte)
{
	donec <-= ref Helperdone(Qsay, m.fid, m, <-ch);
}

asyncdone(srv: ref Styxserver, h: ref Helperdone)
{
	case h.kind {
	Qlisten =>	listenbusy = 0;
	Qwake =>	wakebusy = 0;
	}
	if(!isasync(h.m.tag))
		return;
	cancelasynctag(h.m.tag);
	if(h.kind == Qsay) {
		fs := getfidstate(h.fid);
		fs.sayresp = h.result;
		srv.reply(styxservers->readbytes(h.m, h.result));
		return;
	}
	# Streaming replies (listen/wake) must ignore the fid's read offset:
	# consumers hold one fd across many reads, and offset-sliced replies
	# would EOF the stream after the first read (INFR-28). Reply with the
	# raw record bytes, clamped to the requested count.
	srv.reply(ref Rmsg.Read(h.m.tag, clampcount(h.m, h.result)));
}

clampcount(m: ref Tmsg.Read, data: array of byte): array of byte
{
	if(len data > m.count)
		return data[0:m.count];
	return data;
}

# === Configuration ===

readconfig(): string
{
	result := "kokorobin " + kokorobin + "\n";
	result += "whisperstreambin " + whisperstreambin + "\n";
	result += "wakebin " + wakebin + "\n";
	result += "wakeword " + wakeword + "\n";
	result += "wakethreshold " + wakethreshold + "\n";
	result += "whispermodel " + whispermodel + "\n";
	result += "voice " + voice + "\n";
	result += "rate " + string audrate + "\n";
	result += "audiodev " + audiodev + "\n";
	result += "capturedev " + capturedev + "\n";
	result += "micmode " + micmode + "\n";
	result += "capturerate " + string capturerate + "\n";
	result += "duplex " + duplex + "\n";
	if(standby)
		result += "mic off\n";
	else
		result += "mic on\n";
	if(listenoff)
		result += "listen off\n";
	else
		result += "listen on\n";
	return result;
}

# Capture-path config changed: restart the streaming helpers so they come
# back up against the new device/mode, and make the pump drop its device fd
# and stale sinks.
resetcapture()
{
	killproc(listenproc);
	listenproc = nil;
	killproc(wakeproc);
	wakeproc = nil;
	pumpreset();
}

applyconfig(cmd: string): string
{
	(n, argv) := sys->tokenize(cmd, " \t\n");
	if(n < 2)
		return "error: usage: <key> <value>";
	key := hd argv;
	argv = tl argv;
	val := "";
	for(; argv != nil; argv = tl argv) {
		if(val != "")
			val += " ";
		val += hd argv;
	}

	case key {
	"kokorobin" =>
		kokorobin = val;
	"whisperstreambin" =>
		# Restart the stream with the new helper on next read.
		killproc(listenproc);
		listenproc = nil;
		whisperstreambin = val;
	"wakebin" =>
		killproc(wakeproc);
		wakeproc = nil;
		wakebin = val;
	"wakeword" =>
		killproc(wakeproc);
		wakeproc = nil;
		wakeword = val;
	"wakethreshold" =>
		killproc(wakeproc);
		wakeproc = nil;
		wakethreshold = val;
	"whispermodel" or "sttmodel" =>
		killproc(listenproc);
		listenproc = nil;
		whispermodel = val;
	"voice" =>
		voice = val;
	"rate" =>
		r := int val;
		if(r < 8000 || r > 48000)
			return "error: rate must be 8000-48000";
		audrate = r;
	"audiodev" =>
		audiodev = val;
		resetcapture();
	"capturedev" =>
		if(val == "default")
			val = "";
		capturedev = val;
		resetcapture();
	"micmode" =>
		if(val != "helper" && val != "device")
			return "error: micmode must be helper or device";
		micmode = val;
		resetcapture();
	"capturerate" =>
		r := int val;
		if(r < 8000 || r > 48000)
			return "error: capturerate must be 8000-48000";
		capturerate = r;
		resetcapture();
	"duplex" =>
		if(val != "full" && val != "half")
			return "error: duplex must be full or half";
		duplex = val;
	"mic" =>
		# Voice-mode teardown: `mic off` kills the mic-side helpers
		# (and the capture pump's device fd) so the microphone is not
		# held open outside a voice session. The next listen/wake read
		# re-arms it; `mic on` is accepted for symmetry.
		case val {
		"off" =>
			standby = 1;
			resetcapture();
		"on" =>
			standby = 0;
		* =>
			return "error: mic must be on or off";
		}
	"listen" =>
		# Turn-end teardown from voicemode: `listen off` stops only
		# the STT helper, so speech between voice turns (ambient talk,
		# the assistant's own TTS) cannot queue as stale records that
		# replay into the next turn. Wake stays armed; the next listen
		# read restarts the STT helper.
		case val {
		"off" =>
			listenoff = 1;
			killproc(listenproc);
			listenproc = nil;
		"on" =>
			listenoff = 0;
		* =>
			return "error: listen must be on or off";
		}
	* =>
		return "error: unknown config key: " + key;
	}
	return "ok";
}

listvoices(): string
{
	if(kokorobin == "")
		return "(kokoro helper not configured)\n";
	result := runcmd(kokorobin + " --list-voices 2>/dev/null");
	if(result == "" || hasprefix(result, "error:"))
		return "af_bella\n(default; helper unavailable or does not list voices)\n";
	return result;
}

# === Per-fid state ===

getfidstate(fid: int): ref FidState
{
	for(l := fidstates; l != nil; l = tl l) {
		if((hd l).fid == fid)
			return hd l;
	}
	fs := ref FidState(fid, nil, nil);
	fidstates = fs :: fidstates;
	return fs;
}

delfidstate(fid: int)
{
	newlist: list of ref FidState;
	for(l := fidstates; l != nil; l = tl l) {
		if((hd l).fid != fid)
			newlist = hd l :: newlist;
	}
	fidstates = newlist;
}

# === 9P plumbing ===

navigator(navops: chan of ref Navop)
{
	for(;;) {
		navop := <-navops;
		if(navop == nil)
			return;
		pick n := navop {
		Stat =>
			(d, err) := dirgen(int n.path);
			n.reply <-= (d, err);
		Walk =>
			walkto(n);
		Readdir =>
			readdir(n, int n.path);
		}
	}
}

walkto(n: ref Navop.Walk)
{
	if(int n.path != Qroot) {
		n.reply <-= (nil, Enotfound);
		return;
	}
	case n.name {
	".." or "." =>
		n.path = big Qroot;
	"ctl" =>
		n.path = big Qctl;
	"listen" =>
		n.path = big Qlisten;
	"wake" =>
		n.path = big Qwake;
	"say" =>
		n.path = big Qsay;
	"cancel" =>
		n.path = big Qcancel;
	"chime" =>
		n.path = big Qchime;
	"voices" =>
		n.path = big Qvoices;
	* =>
		n.reply <-= (nil, Enotfound);
		return;
	}
	(d, err) := dirgen(int n.path);
	n.reply <-= (d, err);
}

dirgen(path: int): (ref Sys->Dir, string)
{
	name: string;
	perm: int;
	case path {
	Qroot =>
		return (dir(Qid(big Qroot, 0, Sys->QTDIR), ".", big 0, 8r555|Sys->DMDIR), nil);
	Qctl =>
		name = "ctl";
		perm = 8r666;
	Qlisten =>
		name = "listen";
		perm = 8r444;
	Qwake =>
		name = "wake";
		perm = 8r444;
	Qsay =>
		name = "say";
		perm = 8r666;
	Qcancel =>
		name = "cancel";
		perm = 8r222;
	Qchime =>
		name = "chime";
		perm = 8r222;
	Qvoices =>
		name = "voices";
		perm = 8r444;
	* =>
		return (nil, Enotfound);
	}
	return (dir(Qid(big path, 0, Sys->QTFILE), name, big 0, perm), nil);
}

dir(qid: Sys->Qid, name: string, length: big, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	d.qid = qid;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.length = length;
	return d;
}

readdir(n: ref Navop.Readdir, path: int)
{
	if(path != Qroot) {
		n.reply <-= (nil, Enotfound);
		return;
	}
	entries := array[] of {Qctl, Qlisten, Qwake, Qsay, Qcancel, Qchime, Qvoices};
	for(i := n.offset; i < len entries && i < n.offset + n.count; i++) {
		(d, err) := dirgen(entries[i]);
		if(err != nil) {
			n.reply <-= (nil, err);
			return;
		}
		n.reply <-= (d, nil);
	}
	n.reply <-= (nil, nil);
}

serveloop(tchan: chan of ref Tmsg, srv: ref Styxserver, pidc: chan of int, navops: chan of ref Navop)
{
	pidc <-= sys->pctl(0, nil);

Serve:
	for(;;) {
		gm: ref Tmsg;
		alt {
		gm = <-tchan =>
			;
		h := <-helperc =>
			asyncdone(srv, h);
			continue;
		}
		if(gm == nil)
			break Serve;

		pick m := gm {
		Readerror =>
			break Serve;

		Flush =>
			cancelasynctag(m.oldtag);
			srv.reply(ref Rmsg.Flush(m.tag));

		Read =>
			fid := srv.getfid(m.fid);
			if(fid == nil) {
				srv.reply(ref Rmsg.Error(m.tag, "bad fid"));
				continue;
			}
			path := int fid.path;
			case path {
			Qctl =>
				srv.reply(styxservers->readstr(m, readconfig()));
			Qvoices =>
				srv.reply(styxservers->readstr(m, listvoices()));
			Qlisten =>
				if(listenbusy)
					srv.reply(styxservers->readstr(m, "error: listen busy"));
				else {
					listenbusy = 1;
					addasync(m.tag, m.fid);
					spawn asynclisten(helperc, m);
				}
			Qwake =>
				if(wakebusy)
					srv.reply(styxservers->readstr(m, "error: wake busy"));
				else {
					wakebusy = 1;
					addasync(m.tag, m.fid);
					spawn asyncwake(helperc, m);
				}
			Qsay =>
				fs := getfidstate(m.fid);
				if(fs.sayresp == nil && fs.saydone != nil) {
					ch := fs.saydone;
					fs.saydone = nil;
					addasync(m.tag, m.fid);
					spawn saywait(helperc, m, ch);
				} else if(fs.sayresp != nil)
					srv.reply(styxservers->readbytes(m, fs.sayresp));
				else
					srv.reply(styxservers->readstr(m, ""));
			Qcancel =>
				srv.reply(styxservers->readstr(m, ""));
			* =>
				srv.default(gm);
			}

		Write =>
			fid := srv.getfid(m.fid);
			if(fid == nil) {
				srv.reply(ref Rmsg.Error(m.tag, "bad fid"));
				continue;
			}
			path := int fid.path;
			case path {
			Qctl =>
				result := applyconfig(string m.data);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
				if(hasprefix(result, "error:"))
					sys->fprint(stderr, "speechshim9p: %s\n", result);
			Qsay =>
				fs := getfidstate(m.fid);
				fs.sayresp = nil;
				fs.saydone = chan of array of byte;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
				spawn asyncsay(fs.saydone, string m.data);
			Qcancel =>
				# Hard cancel: kill the synthesizing helper and let
				# the playback loop notice within one chunk.
				cancelreq = 1;
				killproc(sayproc);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qchime =>
				startchime(string m.data);
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}

		Clunk =>
			fid := srv.getfid(m.fid);
			if(fid != nil) {
				cancelasyncfid(m.fid);
				delfidstate(m.fid);
			}
			srv.default(gm);

		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
	if(pumprunning)
		pumpc <-= (SINKQUIT, nil);	# don't outlive the mount
}

writectl(fd: ref Sys->FD, cmd: string)
{
	data := array of byte cmd;
	sys->write(fd, data, len data);
}

# === Small helpers ===

rf(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

ensuredir(path: string)
{
	sys->create(path, Sys->OREAD, Sys->DMDIR | 8r755);
}

hasprefix(s, prefix: string): int
{
	return len s >= len prefix && s[0:len prefix] == prefix;
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
