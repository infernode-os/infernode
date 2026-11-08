implement Feedrate;

#
# feedrate feed secs: a feed read as a live viewer reads it, for secs
# seconds: from the newest frame, each next one whole at its offset, on
# from the newest when it falls behind ("frame expired"). Prints
#	frames=N secs=S fps=F missed=M mbps=B
# For comparing ways of reaching a feed (direct, camsrv -s, post(1)).
#

include "sys.m";
	sys: Sys;
include "draw.m";

Feedrate: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	if(len args != 2){
		sys->fprint(sys->fildes(2), "usage: feedrate feed secs\n");
		raise "fail:usage";
	}
	feed := hd args;
	secs := int hd tl args;
	(w, h) := fmt(feed);
	fs := w*h + 2*(w/2)*(h/2);
	if(fs <= 0){
		sys->fprint(sys->fildes(2), "feedrate: %s: no fmt\n", feed);
		raise "fail:fmt";
	}
	fd := sys->open(feed + "/frame", Sys->OREAD);
	if(fd == nil){
		sys->fprint(sys->fildes(2), "feedrate: %s/frame: %r\n", feed);
		raise "fail:open";
	}
	buf := array[fs] of byte;
	f := start(feed);
	first := -1;
	frames := 0;
	missed := 0;
	t0 := sys->millisec();
	while(sys->millisec() - t0 < 1000*secs){
		(got, e) := readat(fd, buf, f);
		if(e == "frame expired"){
			g := start(feed);
			missed += g - f;
			f = g;
			continue;
		}
		if(got < fs)
			break;
		if(first < 0)
			first = f;
		frames++;
		f++;
	}
	ms := sys->millisec() - t0;
	if(ms < 1)
		ms = 1;
	sys->print("frames=%d secs=%.1f fps=%.1f missed=%d mbps=%.1f\n", frames, real ms / 1000.0,
		1000.0 * real frames / real ms, missed, real frames * real fs / (1000.0 * real ms));
}

readat(fd: ref Sys->FD, b: array of byte, f: int): (int, string)
{
	got := 0;
	while(got < len b){
		m := sys->pread(fd, b[got:], len b - got, big f * big len b + big got);
		if(m < 0)
			return (got, sys->sprint("%r"));
		if(m == 0)
			break;
		got += m;
	}
	return (got, nil);
}

# the newest frame if still kept, else the next
start(feed: string): int
{
	(frames, first) := (0, 0);
	(nil, t) := sys->tokenize(rd(feed + "/status"), " \t\n");
	for(; t != nil; t = tl t){
		s := hd t;
		if(len s > 7 && s[0:7] == "frames=")
			frames = int s[7:];
		else if(len s > 6 && s[0:6] == "first=")
			first = int s[6:];
	}
	if(frames > first)
		return frames - 1;
	return frames;
}

fmt(feed: string): (int, int)
{
	(nil, t) := sys->tokenize(rd(feed + "/fmt"), " \t\n");
	if(len t < 2)
		return (0, 0);
	return (int hd t, int hd tl t);
}

rd(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}
