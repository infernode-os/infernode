implement SpeechEngine;

# Loadable speech engine that delegates to a namespace provider. This makes
# provider-backed speech usable through the same `.dis` contract as future
# in-process engines while keeping audio transport file-oriented.

include "sys.m";
	sys: Sys;

include "speech.m";

cfg: ref Speech->Config;

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	return nil;
}

name(): string
{
	return "provider";
}

caps(): int
{
	return Speech->CAPTTS | Speech->CAPSTT;
}

configure(c: ref Speech->Config): string
{
	if(c == nil || c.provider == nil || c.provider == "")
		return "provider mount is not configured";
	cfg = c;
	return nil;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	out := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		out += string buf[0:n];
	return out;
}

voices(): list of string
{
	if(cfg == nil)
		return nil;
	s := readfile(cfg.provider + "/voices");
	if(s == nil || s == "")
		return nil;
	(nil, lines) := sys->tokenize(s, "\n");
	out: list of string;
	for(; lines != nil; lines = tl lines)
		if(hd lines != "")
			out = hd lines :: out;
	rev: list of string;
	for(; out != nil; out = tl out)
		rev = hd out :: rev;
	return rev;
}

synthesize(text: string): ref Speech->TTSResult
{
	fmt := ref Speech->AudioFmt(22050, 1, 16, "pcm");
	if(cfg != nil && cfg.outfmt != nil)
		fmt = cfg.outfmt;
	if(cfg == nil)
		return ref Speech->TTSResult(nil, fmt, "engine is not configured");
	fd := sys->open(cfg.provider + "/say", Sys->ORDWR);
	if(fd == nil)
		return ref Speech->TTSResult(nil, fmt, sys->sprint("provider say unavailable: %r"));
	b := array of byte text;
	if(sys->write(fd, b, len b) < 0)
		return ref Speech->TTSResult(nil, fmt, sys->sprint("provider say failed: %r"));
	sys->seek(fd, big 0, Sys->SEEKSTART);
	buf := array[1024] of byte;
	n := sys->read(fd, buf, len buf);
	if(n > 0) {
		status := string buf[0:n];
		if(len status >= 6 && status[0:6] == "error:")
			return ref Speech->TTSResult(nil, fmt, status);
	}
	# The provider has already played the utterance, so no PCM is returned.
	return ref Speech->TTSResult(nil, fmt, nil);
}

recognize(nil: array of byte, nil: ref Speech->AudioFmt): ref Speech->STTResult
{
	if(cfg == nil)
		return ref Speech->STTResult(nil, "engine is not configured");
	text := readfile(cfg.provider + "/listen");
	if(text == nil)
		return ref Speech->STTResult(nil, sys->sprint("provider listen unavailable: %r"));
	return ref Speech->STTResult(text, nil);
}
