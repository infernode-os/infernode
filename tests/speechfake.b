implement Speechfake;

#
# speechfake -- a speech engine for tests: an engine directory, as
# speech(4) uses one, whose answers are known.
#
#	speechfake mountpoint [scriptfile]
#
#	ctl	start, end, cancel, voice v, lang l, model m; read: name fake,
#		rate 16000, voice, lang, and what the last utterance
#		brought: heard <ms> of audio, peak <sample>, starts,
#		cancels
#	audio	the utterance's microphone, 16 kHz mono 16-bit
#	text	partial confidence=0.40 <the script line's first word>
#		on an utterance's first audio; on end,
#		final confidence=0.93 <the script line>; each reader
#		from its open on
#	tts	write text, then read it back as sound: a 440 Hz tone,
#		100 ms a word, 16 kHz mono 16-bit, to EOF
#	voices	fake
#
# Each end takes the script's next line (nothing scripted, when there is
# none left).  Not a test; tests/host/speech_test.sh drives it.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "math.m";
	math: Math;

Speechfake: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Rate: con 16000;

Reader: adt {
	fid:	int;
	queue:	list of string;		# records not yet read, oldest last
	rc:	Sys->Rread;		# a read waiting, or nil
	count:	int;
};

readers: list of ref Reader;
script: list of string;
voice := "fake";
lang := "en";
model := "none";
active := 0;
heardbytes := 0;
lastheard := 0;
peak := 0;
lastpeak := 0;
starts := 0;
cancels := 0;
sentpartial := 0;
ttstext: list of (int, string);	# fid, text

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	if(len args < 2){
		sys->fprint(sys->fildes(2), "usage: speechfake mountpoint [scriptfile]\n");
		raise "fail:usage";
	}
	mnt := hd tl args;
	if(tl tl args != nil && (b := bufio->open(hd tl tl args, Bufio->OREAD)) != nil){
		rev: list of string;
		while((l := b.gets('\n')) != nil){
			if(l[len l - 1] == '\n')
				l = l[0:len l - 1];
			rev = l :: rev;
		}
		for(; rev != nil; rev = tl rev)
			script = hd rev :: script;
	}
	if(sys->bind("#sspeechfake", mnt, Sys->MREPL) < 0){
		sys->fprint(sys->fildes(2), "speechfake: bind %s: %r\n", mnt);
		raise "fail:bind";
	}
	ctl := sys->file2chan(mnt, "ctl");
	audio := sys->file2chan(mnt, "audio");
	text := sys->file2chan(mnt, "text");
	tts := sys->file2chan(mnt, "tts");
	voices := sys->file2chan(mnt, "voices");
	if(ctl == nil || audio == nil || text == nil || tts == nil || voices == nil){
		sys->fprint(sys->fildes(2), "speechfake: file2chan: %r\n");
		raise "fail:file2chan";
	}
	sys->pctl(Sys->NEWPGRP, nil);
	spawn serve(ctl, audio, text, tts, voices);
}

serve(ctl, audio, text, tts, voices: ref Sys->FileIO)
{
	for(;;) alt {
	(off, nil, nil, rc) := <-ctl.read =>
		if(rc != nil)
			rc <-= (slice(array of byte sys->sprint(
				"name fake\nrate %d\nvoice %s\nlang %s\nmodel %s\nheard %d\npeak %d\nstarts %d\ncancels %d\n",
				Rate, voice, lang, model, lastheard, lastpeak, starts, cancels), off), nil);
	(nil, data, nil, wc) := <-ctl.write =>
		if(wc != nil)
			wc <-= ctlwrite(string data);
	(nil, data, nil, wc) := <-audio.write =>
		if(wc == nil)
			continue;
		if(active){
			heardbytes += len data;
			for(i := 0; i + 1 < len data; i += 2){
				v := int data[i] | (int data[i+1] << 8);
				if(v >= 32768)
					v -= 65536;
				if(v < 0)
					v = -v;
				if(v > peak)
					peak = v;
			}
			if(!sentpartial){
				sentpartial = 1;
				(nil, w) := sys->tokenize(next(), " ");
				first := "";
				if(w != nil)
					first = hd w;
				post("partial confidence=0.40 " + first);
			}
		}
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
	(nil, data, fid, wc) := <-tts.write =>
		if(wc == nil){
			ttsdrop(fid);
			continue;
		}
		ttsset(fid, string data);
		wc <-= (len data, nil);
	(off, count, fid, rc) := <-tts.read =>
		if(rc == nil)
			continue;
		rc <-= (ttspcm(ttsget(fid), off, count), nil);
	(off, nil, nil, rc) := <-voices.read =>
		if(rc != nil)
			rc <-= (slice(array of byte "fake\n", off), nil);
	(nil, nil, nil, wc) := <-voices.write =>
		if(wc != nil)
			wc <-= (0, "voices is read");
	}
}

ctlwrite(s: string): (int, string)
{
	(nil, f) := sys->tokenize(s, " \t\n");
	if(f == nil)
		return (len s, nil);
	case hd f {
	"start" =>
		active = 1;
		heardbytes = 0;
		peak = 0;
		sentpartial = 0;
		starts++;
	"end" =>
		if(active){
			active = 0;
			lastheard = heardbytes * 1000 / (Rate * 2);
			lastpeak = peak;
			line := next();
			if(script != nil)
				script = tl script;
			post("final confidence=0.93 " + line);
		}
	"cancel" =>
		if(active){
			active = 0;
			lastheard = heardbytes * 1000 / (Rate * 2);
			lastpeak = peak;
		}
		cancels++;
	"voice" =>
		if(tl f == nil)
			return (0, "voice what");
		voice = hd tl f;
	"lang" =>
		if(tl f == nil)
			return (0, "lang what");
		lang = hd tl f;
	"model" =>
		if(tl f == nil)
			return (0, "model what");
		model = hd tl f;
	* =>
		return (0, "unknown ctl " + hd f);
	}
	return (len s, nil);
}

next(): string
{
	if(script == nil)
		return "nothing scripted";
	return hd script;
}

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

post(rec: string)
{
	for(l := readers; l != nil; l = tl l){
		r := hd l;
		r.queue = append(r.queue, rec);
		answer(r);
	}
}

append(l: list of string, s: string): list of string
{
	if(l == nil)
		return s :: nil;
	return hd l :: append(tl l, s);
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

slice(b: array of byte, off: int): array of byte
{
	if(off >= len b)
		return nil;
	return b[off:];
}

ttsset(fid: int, s: string)
{
	ttsdrop(fid);
	ttstext = (fid, s) :: ttstext;
}

ttsdrop(fid: int)
{
	n: list of (int, string);
	for(l := ttstext; l != nil; l = tl l){
		(f, s) := hd l;
		if(f != fid)
			n = (f, s) :: n;
	}
	ttstext = n;
}

ttsget(fid: int): string
{
	for(l := ttstext; l != nil; l = tl l){
		(f, s) := hd l;
		if(f == fid)
			return s;
	}
	return nil;
}

# the sound of s: a 440 Hz tone, 100 ms a word
ttspcm(s: string, off, count: int): array of byte
{
	(nw, nil) := sys->tokenize(s, " \t\n");
	total := nw * Rate / 10 * 2;
	if(off >= total)
		return nil;
	if(off + count > total)
		count = total - off;
	count &= ~1;
	b := array[count] of byte;
	for(i := 0; i < count; i += 2){
		k := (off + i) / 2;
		v := int (8000.0 * math->sin(2.0 * Math->Pi * 440.0 * real k / real Rate));
		b[i] = byte v;
		b[i+1] = byte (v >> 8);
	}
	return b;
}
