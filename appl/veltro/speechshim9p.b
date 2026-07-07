implement Speechshim9p;

#
# speechshim9p - adapt external host speech helper CLIs to the speech
# provider contract (docs/SPEECH-ARCHITECTURE.md):
#
#   /n/speechshim/
#   ├── ctl      (rw)  kokorobin, whisperstreambin, wakebin, wakeword,
#   │                  wakethreshold, whispermodel, voice, rate
#   ├── listen   (r)   newline records from the streaming STT helper:
#   │                  "partial <text>" / "final <text>" / "error: <reason>"
#   ├── wake     (r)   blocks until the wake-word helper emits an event line
#   ├── say      (rw)  write text: Kokoro synthesizes PCM, played through
#   │                  /dev/audio in chunks; read returns the status
#   ├── cancel   (w)   kills the active TTS helper process and stops playback
#   └── voices   (r)   helper voice list
#
# speech9p consumes this mount exactly as it consumes a parakeet export or a
# remote provider — the helper binaries are an implementation detail behind
# the namespace. The helpers themselves are external installs (whisper.cpp
# stream, kokoro-onnx wrapper, openWakeWord wrapper); every path soft-fails
# with an "error: ..." record when a helper is absent.
#
# Host processes run through #C (devcmd). Streaming helpers (listen, wake)
# are started once and read incrementally; killonclose is armed so they die
# with the shim. TTS is killed on cancel via the devcmd ctl "kill" command,
# and playback checks the cancel flag between chunks, so barge-in silence is
# bounded by one audio chunk rather than the remaining utterance.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;

include "draw.m";

include "arg.m";

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

Qroot, Qctl, Qlisten, Qwake, Qsay, Qcancel, Qvoices: con iota;

# Configuration
kokorobin := "kokoro-cli";
whisperstreambin := "whisper-stream";
wakebin := "openwakeword-cli";
wakeword := "hey lucia";
wakethreshold := "0.5";
whispermodel := "";
voice := "af_bella";
audrate := 24000;

stderr: ref Sys->FD;
user: string;
mountpt := "/n/speechshim";
cmdbound := 0;
audiobound := 0;
cancelreq := 0;

# A host helper process behind #C. ctlfd is the clone fd (kept open —
# killonclose is armed on it); writing "kill" to it terminates the process.
Hostproc: adt {
	ctlfd:  ref Sys->FD;
	datafd: ref Sys->FD;
	dir:    string;
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

	return (ref Hostproc(cfd, datafd, dir), nil);
}

killproc(p: ref Hostproc)
{
	if(p != nil && p.ctlfd != nil)
		sys->fprint(p.ctlfd, "kill");
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
	return result;
}

# === Streaming reads (listen / wake) ===

listencmd(): string
{
	return whisperstreambin + " --model " + whispermodel +
		" --rate 16000 --chans 1 2>/dev/null";
}

wakecmd(): string
{
	return wakebin + " --word '" + wakeword + "' --threshold " +
		wakethreshold + " 2>/dev/null";
}

# Read the next chunk of newline records from a streaming helper, starting
# it on first use. Runs in a spawned proc; the globals it resets on EOF are
# also reset by ctl writes, which is benign — the next read restarts the
# helper either way.
readlisten(): string
{
	if(whisperstreambin == "")
		return "error: listen helper not configured";
	# One restart attempt: a stale fd from an exited helper (one-shot
	# helpers exit after each utterance) must not eat a read as an error.
	for(attempt := 0; attempt < 2; attempt++) {
		if(listenproc == nil) {
			(p, err) := startproc(listencmd());
			if(p == nil)
				return err;
			listenproc = p;
		}
		buf := array[8192] of byte;
		n := sys->read(listenproc.datafd, buf, len buf);
		if(n > 0)
			return string buf[0:n];
		listenproc = nil;
	}
	return "error: listen helper exited";
}

readwake(): string
{
	if(wakebin == "")
		return "error: wake helper not configured";
	# One restart attempt, same reason as readlisten: one-shot wake
	# helpers exit after each event and must be restarted transparently.
	for(attempt := 0; attempt < 2; attempt++) {
		if(wakeproc == nil) {
			(p, err) := startproc(wakecmd());
			if(p == nil)
				return err;
			wakeproc = p;
		}
		buf := array[1024] of byte;
		n := sys->read(wakeproc.datafd, buf, len buf);
		if(n > 0)
			return string buf[0:n];
		wakeproc = nil;
	}
	return "error: wake helper exited";
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
		sayproc = nil;
		return sys->sprint("error: cannot open %s/data for write: %r", p.dir);
	}
	b := array of byte (text + "\n");
	sys->write(tofd, b, len b);
	tofd = nil;

	bindaudio();
	ctl := sys->open("/dev/audioctl", Sys->OWRITE);
	if(ctl != nil) {
		writectl(ctl, sys->sprint("out rate %d", audrate));
		writectl(ctl, "out chans 1");
		writectl(ctl, "out bits 16");
		writectl(ctl, "out enc pcm");
		ctl = nil;
	}
	afd := sys->open("/dev/audio", Sys->OWRITE);

	total := 0;
	buf := array[8192] of byte;
	status := "";
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
	sayproc = nil;
	if(status != "")
		return status;
	if(total == 0) {
		if(afd == nil)
			return sys->sprint("error: cannot open /dev/audio: %r");
		return "error: kokoro produced no audio";
	}
	return sys->sprint("ok: played %d bytes", total);
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
	return result;
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
	entries := array[] of {Qctl, Qlisten, Qwake, Qsay, Qcancel, Qvoices};
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
