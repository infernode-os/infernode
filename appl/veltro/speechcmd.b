implement Speechcmd;

#
# speechcmd -- a speech engine of the host's programs: speech(4)'s
# engine directory on a desktop.
#
#	speechcmd [-m mountpoint] [-t ttscmd] [-r ttsrate] [-s sttcmd] [-M sttmodel]
#
# Serves, at mountpoint (/mnt/speechengine):
#
#	ctl	start, end, cancel, voice v, lang l; read: name cmd,
#		rate, voice, lang, and the commands it runs
#	audio	the utterance's microphone, 16 kHz mono 16-bit,
#		between start and end
#	text	final <words> when an utterance ends (the recogniser is
#		a batch one: no partials), error <reason>; every reader
#		from its first read on
#	tts	write text; read its sound, mono 16-bit at rate, to EOF
#	voices	what the synthesiser lists
#
# Recognition is whisper.cpp's whisper-cli (-s, with -M its model) on
# a WAV of the utterance written to the host's /tmp.  Synthesis is, by
# the host: macOS's say, piper (with -t "piper --model m"), or
# espeak-ng; text goes to the program's standard input, never into a
# shell line, and a voice name is letters, digits, dot, dash and
# underscore only.  The programs are set when it starts, by its
# flags, and not through ctl: whoever holds ctl (an agent may) cannot
# choose what runs on the host.  These were speech9p's engines; speech9p
# now only uses an engine directory, this or another.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";

Speechcmd: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Sttrate: con 16000;

stderr: ref Sys->FD;
platform := "";
ttscmd := "";
ttsraw := 0;		# the synthesiser gives raw PCM, not a WAV
ttsrate := 22050;
sttcmd := "";
sttmodel := "";
voice := "";
lang := "en";

active := 0;
utterance: array of byte;	# the microphone since start
ulen := 0;
sttseq := 0;

Reader: adt {
	fid:	int;
	queue:	list of string;
	rc:	Sys->Rread;
	count:	int;
};
readers: list of ref Reader;

Tts: adt {
	fid:	int;
	pcm:	array of byte;
};
ttsres: list of ref Tts;

postc: chan of string;		# records, from the recogniser's process
ttsdonec: chan of (int, array of byte, string, Sys->Rwrite, int);

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	mnt := "/mnt/speechengine";
	platform = hostos();
	defaults();
	arg := load Arg Arg->PATH;
	if(arg != nil){
		arg->init(args);
		arg->setusage("speechcmd [-m mountpoint] [-t ttscmd] [-r ttsrate] [-s sttcmd] [-M sttmodel]");
		while((o := arg->opt()) != 0)
			case o {
			'm' =>	mnt = arg->earg();
			't' =>	ttscmd = arg->earg();
				ttsraw = prefix("piper", ttscmd);
			'r' =>	ttsrate = int arg->earg();
			's' =>	sttcmd = arg->earg();
			'M' =>	sttmodel = arg->earg();
			* =>	arg->usage();
			}
	}
	if(ttsrate < 8000 || ttsrate > 48000){
		sys->fprint(stderr, "speechcmd: rate 8000 to 48000\n");
		raise "fail:usage";
	}
	if(sys->stat("/cmd/clone").t0 < 0)
		sys->bind("#C", "/", Sys->MBEFORE);
	if(sys->bind("#sspeechcmd", mnt, Sys->MREPL) < 0){
		sys->fprint(stderr, "speechcmd: bind %s: %r\n", mnt);
		raise "fail:bind";
	}
	f := array[5] of ref Sys->FileIO;
	names := array[] of {"ctl", "audio", "text", "tts", "voices"};
	for(i := 0; i < len names; i++)
		if((f[i] = sys->file2chan(mnt, names[i])) == nil){
			sys->fprint(stderr, "speechcmd: file2chan %s: %r\n", names[i]);
			raise "fail:file2chan";
		}
	sys->pctl(Sys->NEWPGRP|Sys->FORKFD, nil);
	postc = chan of string;
	ttsdonec = chan of (int, array of byte, string, Sys->Rwrite, int);
	spawn serve(f);
}

hostos(): string
{
	fd := sys->open("/env/emuhost", Sys->OREAD);
	if(fd == nil)
		return "unknown";
	b := array[64] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "unknown";
	s := lower(string b[0:n]);
	if(prefix("macos", s) || prefix("darwin", s))
		return "macos";
	if(prefix("linux", s))
		return "linux";
	if(prefix("nt", s) || prefix("windows", s))
		return "windows";
	return "unknown";
}

defaults()
{
	case platform {
	"macos" =>
		ttscmd = "say";
		sttcmd = "whisper-cli";
		sttmodel = "/opt/homebrew/share/whisper-cpp/models/ggml-base.en.bin";
	"linux" =>
		ttscmd = "espeak-ng";
		sttcmd = "whisper-cli";
	}
}

serve(f: array of ref Sys->FileIO)
{
	ctl := f[0];
	audio := f[1];
	text := f[2];
	tts := f[3];
	voices := f[4];
	for(;;) alt {
	(off, nil, nil, rc) := <-ctl.read =>
		if(rc != nil)
			rc <-= (slice(array of byte status(), off), nil);
	(nil, data, nil, wc) := <-ctl.write =>
		if(wc != nil)
			wc <-= ctlwrite(string data, len data);
	(nil, data, nil, wc) := <-audio.write =>
		if(wc == nil)
			continue;
		if(active)
			keep(data);
		wc <-= (len data, nil);
	(nil, nil, nil, rc) := <-audio.read =>
		if(rc != nil)
			rc <-= (nil, "audio is written");
	(nil, count, fid, rc) := <-text.read =>
		r := reader(fid);
		if(rc == nil){
			dropreader(fid);
			continue;
		}
		r.rc = rc;
		r.count = count;
		answer(r);
	(nil, nil, fid, wc) := <-text.write =>
		if(wc == nil){
			dropreader(fid);
			continue;
		}
		wc <-= (0, "text is read");
	rec := <-postc =>
		for(l := readers; l != nil; l = tl l){
			(hd l).queue = append((hd l).queue, rec);
			answer(hd l);
		}
	(nil, data, fid, wc) := <-tts.write =>
		if(wc == nil){
			droptts(fid);
			continue;
		}
		spawn synth(fid, string data, wc, len data);
	(fid, pcm, e, wc, n) := <-ttsdonec =>
		if(e != nil){
			wc <-= (0, e);
			continue;
		}
		droptts(fid);
		ttsres = ref Tts(fid, pcm) :: ttsres;
		wc <-= (n, nil);
	(off, count, fid, rc) := <-tts.read =>
		if(rc == nil)
			continue;
		pcm: array of byte;
		for(l := ttsres; l != nil; l = tl l)
			if((hd l).fid == fid)
				pcm = (hd l).pcm;
		if(off >= len pcm)
			rc <-= (nil, nil);
		else{
			e := off + count;
			if(e > len pcm)
				e = len pcm;
			rc <-= (pcm[off:e], nil);
		}
	(off, nil, nil, rc) := <-voices.read =>
		if(rc != nil)
			rc <-= (slice(array of byte listvoices(), off), nil);
	(nil, nil, nil, wc) := <-voices.write =>
		if(wc != nil)
			wc <-= (0, "voices is read");
	}
}

status(): string
{
	s := "name cmd\n";
	s += "rate " + string ttsrate + "\n";
	if(voice != nil)
		s += "voice " + voice + "\n";
	s += "lang " + lang + "\n";
	s += "tts " + ttscmd + "\n";
	s += "stt " + sttcmd + "\n";
	if(sttmodel != nil)
		s += "sttmodel " + sttmodel + "\n";
	return s;
}

ctlwrite(s: string, n: int): (int, string)
{
	(nf, f) := sys->tokenize(s, " \t\n");
	if(nf == 0)
		return (n, nil);
	case hd f {
	"start" =>
		active = 1;
		utterance = array[Sttrate * 2 * 10] of byte;
		ulen = 0;
	"end" =>
		if(active){
			active = 0;
			spawn recognise(utterance[0:ulen], ++sttseq);
			utterance = nil;
		}
	"cancel" =>
		active = 0;
		utterance = nil;
	"voice" =>
		if(nf != 2 || !safename(hd tl f))
			return (0, "voice: letters, digits, '.', '-' and '_' only");
		voice = hd tl f;
	"lang" =>
		if(nf != 2 || !safename(hd tl f))
			return (0, "lang: letters, digits, '.', '-' and '_' only");
		lang = hd tl f;
	* =>
		return (0, "speechcmd: ctl is start, end, cancel, voice or lang");
	}
	return (n, nil);
}

# the microphone, kept until end: up to a minute
keep(b: array of byte)
{
	if(ulen + len b > len utterance){
		if(len utterance >= Sttrate * 2 * 60)
			return;
		nu := array[2 * len utterance + len b] of byte;
		nu[0:] = utterance[0:ulen];
		utterance = nu;
	}
	utterance[ulen:] = b;
	ulen += len b;
}

#
# recognition: a WAV on the host, whisper-cli on it
#

recognise(pcm: array of byte, seq: int)
{
	if(sttcmd == nil){
		postc <-= "error no recogniser here (speechcmd -s)";
		return;
	}
	if(len pcm == 0){
		postc <-= "final ";
		return;
	}
	host := sys->sprint("/tmp/infernode-stt-%d-%d.wav", sys->pctl(0, nil), seq);
	fd := sys->create("#U*" + host, Sys->OWRITE, 8r600);
	if(fd == nil){
		postc <-= sys->sprint("error cannot write %s: %r", host);
		return;
	}
	w := wav(pcm, Sttrate);
	if(sys->write(fd, w, len w) != len w){
		postc <-= sys->sprint("error writing %s: %r", host);
		return;
	}
	fd = nil;
	cmd := sttcmd + " -nt -np";
	if(sttmodel != nil)
		cmd += " -m " + sttmodel;
	cmd += " -f " + host + " 2>/dev/null; rm -f " + host;
	(out, e) := run(cmd, nil);
	if(e != nil){
		postc <-= "error " + e;
		return;
	}
	postc <-= "final " + oneline(strip(string out));
}

wav(pcm: array of byte, rate: int): array of byte
{
	h := array[44] of byte;
	h[0:] = array of byte "RIFF";
	put32(h, 4, 36 + len pcm);
	h[8:] = array of byte "WAVEfmt ";
	put32(h, 16, 16);
	put16(h, 20, 1);
	put16(h, 22, 1);
	put32(h, 24, rate);
	put32(h, 28, rate * 2);
	put16(h, 32, 2);
	put16(h, 34, 16);
	h[36:] = array of byte "data";
	put32(h, 40, len pcm);
	b := array[44 + len pcm] of byte;
	b[0:] = h;
	b[44:] = pcm;
	return b;
}

#
# synthesis: the program's sound, as mono 16-bit at ttsrate
#

synth(fid: int, text: string, wc: Sys->Rwrite, n: int)
{
	if(ttscmd == nil){
		ttsdonec <-= (fid, nil, "speechcmd: no synthesiser here (-t)", wc, n);
		return;
	}
	cmd: string;
	case platform {
	"macos" =>
		f := sys->sprint("/tmp/infernode-tts-%d.wav", sys->pctl(0, nil));
		cmd = ttscmd;
		if(voice != nil)
			cmd += " -v " + voice;
		cmd += sys->sprint(" --data-format=LEI16@%d -o %s && cat %s; rm -f %s", ttsrate, f, f, f);
	* =>
		cmd = ttscmd;
		if(ttsraw)
			cmd += " --output-raw";
		else{
			if(voice != nil)
				cmd += " -v " + voice;
			cmd += " --stdin --stdout";
		}
	}
	(out, e) := run(cmd, array of byte text);
	if(e != nil){
		ttsdonec <-= (fid, nil, "speechcmd: " + e, wc, n);
		return;
	}
	pcm := out;
	if(!ttsraw){
		(p, rate, chans, e2) := wavpcm(out);
		if(e2 != nil){
			ttsdonec <-= (fid, nil, "speechcmd: " + e2, wc, n);
			return;
		}
		if(chans == 2)
			p = tomono(p);
		if(rate != ttsrate)
			ttsrate = rate;	# what the program gave; ctl says so before the read
		pcm = p;
	}
	ttsdonec <-= (fid, pcm, nil, wc, n);
}

# a WAV's 16-bit samples, rate and channels
wavpcm(b: array of byte): (array of byte, int, int, string)
{
	if(len b < 12 || string b[0:4] != "RIFF" || string b[8:12] != "WAVE")
		return (nil, 0, 0, "the synthesiser gave no WAV");
	rate := 0;
	chans := 1;
	bits := 16;
	for(i := 12; i + 8 <= len b;){
		id := string b[i:i+4];
		sz := get32(b, i+4);
		body := i + 8;
		case id {
		"fmt " =>
			if(body + 16 <= len b){
				chans = get16(b, body+2);
				rate = get32(b, body+4);
				bits = get16(b, body+14);
			}
		"data" =>
			if(sz < 0 || sz > len b - body || sz == 16r7FFFFFFF || sz == -1)
				sz = len b - body;	# streamed: the size was not known
			if(bits != 16)
				return (nil, 0, 0, "the synthesiser's WAV is not 16-bit");
			return (b[body:body+sz], rate, chans, nil);
		}
		i = body + sz + (sz & 1);
	}
	return (nil, 0, 0, "the synthesiser's WAV has no data");
}

tomono(b: array of byte): array of byte
{
	m := array[len b / 2] of byte;
	for(i := 0; i + 3 < len b; i += 4){
		l := s16(b, i);
		r := s16(b, i+2);
		v := (l + r) / 2;
		m[i/2] = byte v;
		m[i/2+1] = byte (v >> 8);
	}
	return m;
}

listvoices(): string
{
	cmd: string;
	case platform {
	"macos" =>
		cmd = "say -v \\?";	# no quote: the line is inside run's single quotes
	* =>
		if(ttsraw)
			return "the model's own\n";
		cmd = ttscmd + " --voices";
	}
	(out, e) := run(cmd, nil);
	if(e != nil)
		return "(" + e + ")\n";
	return string out;
}

#
# a host program, through #C: its output, with input on its standard input
#

run(cmd: string, input: array of byte): (array of byte, string)
{
	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		return (nil, sys->sprint("no host programs: /cmd/clone: %r"));
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0)
		return (nil, "/cmd/clone gave no number");
	dir := "/cmd/" + string b[0:n];
	if(sys->fprint(cfd, "exec /bin/sh -c '%s'", cmd) < 0)
		return (nil, sys->sprint("exec: %r"));
	waitfd := sys->open(dir + "/wait", Sys->OREAD);	# before it can exit (devcmd keeps no status for a late reader)
	if(input != nil){
		tofd := sys->open(dir + "/data", Sys->OWRITE);
		if(tofd == nil)
			return (nil, sys->sprint("%s/data: %r", dir));
		sys->write(tofd, input, len input);
		tofd = nil;
	}
	from := sys->open(dir + "/data", Sys->OREAD);
	if(from == nil)
		return (nil, sys->sprint("%s/data: %r", dir));
	out := array[0] of byte;
	buf := array[65536] of byte;
	while((n = sys->read(from, buf, len buf)) > 0){
		no := array[len out + n] of byte;
		no[0:] = out;
		no[len out:] = buf[0:n];
		out = no;
	}
	if(waitfd != nil){
		w := array[256] of byte;
		k := sys->read(waitfd, w, len w);
		if(k > 0){
			(nf, fl) := sys->tokenize(string w[0:k], " ");
			# pid time time time status: a status that is not empty is a failure
			if(nf >= 5){
				for(i := 0; i < 4; i++)
					fl = tl fl;
				st := strip(hd fl);
				if(st != nil && st != "''" && len out == 0)
					return (nil, cmd + ": " + st);
			}
		}
	}
	return (out, nil);
}

#
# readers of text
#

reader(fid: int): ref Reader
{
	for(l := readers; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	r := ref Reader(fid, nil, nil, 0);
	readers = r :: readers;
	return r;
}

dropreader(fid: int)
{
	n: list of ref Reader;
	for(l := readers; l != nil; l = tl l)
		if((hd l).fid != fid)
			n = hd l :: n;
	readers = n;
}

answer(r: ref Reader)
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

droptts(fid: int)
{
	n: list of ref Tts;
	for(l := ttsres; l != nil; l = tl l)
		if((hd l).fid != fid)
			n = hd l :: n;
	ttsres = n;
}

#
# odds and ends
#

safename(s: string): int
{
	if(s == nil || len s > 64)
		return 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_'))
			return 0;
	}
	return 1;
}

prefix(p, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

lower(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'A' && s[i] <= 'Z')
			s[i] += 'a' - 'A';
	return s;
}

strip(s: string): string
{
	while(s != nil && (s[0] == ' ' || s[0] == '\t' || s[0] == '\n' || s[0] == '\r'))
		s = s[1:];
	while(s != nil && (s[len s - 1] == ' ' || s[len s - 1] == '\t' || s[len s - 1] == '\n' || s[len s - 1] == '\r'))
		s = s[0:len s - 1];
	return s;
}

oneline(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n' || s[i] == '\r')
			s[i] = ' ';
	return s;
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

s16(b: array of byte, i: int): int
{
	v := int b[i] | (int b[i+1] << 8);
	if(v >= 32768)
		v -= 65536;
	return v;
}

get16(b: array of byte, i: int): int
{
	return int b[i] | (int b[i+1] << 8);
}

get32(b: array of byte, i: int): int
{
	return int b[i] | (int b[i+1] << 8) | (int b[i+2] << 16) | (int b[i+3] << 24);
}

put16(b: array of byte, i, v: int)
{
	b[i] = byte v;
	b[i+1] = byte (v >> 8);
}

put32(b: array of byte, i, v: int)
{
	b[i] = byte v;
	b[i+1] = byte (v >> 8);
	b[i+2] = byte (v >> 16);
	b[i+3] = byte (v >> 24);
}
