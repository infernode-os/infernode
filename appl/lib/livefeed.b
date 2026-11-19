implement Livefeed;

#
# Reading a live video feed across a network.  See livefeed(2).
#

include "sys.m";
	sys: Sys;
include "livefeed.m";

init()
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
}

status(feed: string): (int, int)
{
	init();
	fd := sys->open(feed + "/status", Sys->OREAD);
	if(fd == nil)
		return (-1, sys->millisec());
	b := array[512] of byte;
	t := sys->millisec();
	k := sys->read(fd, b, len b);
	if(k <= 0)
		return (-1, t);
	(frames, first, have) := (0, 0, 0);
	(nil, l) := sys->tokenize(string b[0:k], " \t\n");
	for(; l != nil; l = tl l){
		s := hd l;
		for(i := 0; i < len s; i++)
			if(s[i] == '=')
				break;
		if(i >= len s)
			continue;
		case s[0:i] {
		"frames" =>
			frames = int s[i+1:];
			have = 1;
		"first" =>
			first = int s[i+1:];
		}
	}
	if(!have)
		return (-1, t);
	if(frames > first)
		return (frames - 1, t);
	return (frames, t);
}

Edge.new(feed: string, fps: int): ref Edge
{
	if(fps <= 0)
		fps = 30;
	(lf, lt) := status(feed);
	if(lf < 0)
		return nil;
	return ref Edge(feed, fps, lf, lt, -1, -1, 0);
}

Edge.newest(e: self ref Edge): int
{
	return e.lf + (sys->millisec() - e.lt) * e.fps / 1000;
}

Edge.due(e: self ref Edge, n: int): int
{
	return e.lt + (n - e.lf) * 1000 / e.fps - sys->millisec();
}

Edge.again(e: self ref Edge): int
{
	(lf, lt) := status(e.feed);
	if(lf < 0)
		return 0;
	e.set(lf, lt);
	return 1;
}

Edge.set(e: self ref Edge, lf, lt: int)
{
	if(lf < 0)
		return;
	e.lf = lf;
	e.lt = lt;
}

Edge.next(e: self ref Edge, f, behind: int): int
{
	lag := e.newest() - f;
	now := sys->millisec();
	if(e.lagt == 0 || e.lagcur < 0){
		(e.lagcur, e.lagprev, e.lagt) = (lag, lag, now);
	}else if(now - e.lagt >= 1000){
		(e.lagprev, e.lagcur, e.lagt) = (e.lagcur, lag, now);
	}else if(lag < e.lagcur)
		e.lagcur = lag;
	usual := e.lagcur;
	if(e.lagprev < usual)
		usual = e.lagprev;
	if(usual < 0)
		usual = 0;
	if(lag - usual > behind)
		return e.newest() - usual;
	return f + 1;
}

pread(fd: ref Sys->FD, b: array of byte, n: int, off: big): int
{
	init();
	r := -1;
	for(tries := 0; tries < GONETRIES; tries++){
		r = sys->pread(fd, b, n, off);
		if(r >= 0)
			return r;
		e := sys->sprint("%r");
		if(e != "reply gone")
			break;
	}
	return r;
}

read(fd: ref Sys->FD, b: array of byte, off: big, ways: int): (int, string)
{
	init();
	if(ways < 1)
		ways = 1;
	if(ways > len b)
		ways = len b;
	if(ways <= 1)
		return piece(fd, b, off);
	size := (len b + ways - 1) / ways;
	done := chan[ways] of (int, int, string);
	n := 0;
	for(s := 0; s < len b; s += size){
		e := s + size;
		if(e > len b)
			e = len b;
		spawn worker(fd, b[s:e], off + big s, n, done);
		n++;
	}
	got := array[n] of int;
	errs := array[n] of string;
	for(i := 0; i < n; i++){
		(k, m, err) := <-done;
		got[k] = m;
		errs[k] = err;
	}
	total := 0;
	for(i = 0; i < n; i++){
		want := size;
		if(i == n-1)
			want = len b - size*(n-1);
		total += got[i];
		if(got[i] < want)
			return (total, errs[i]);
	}
	return (total, nil);
}

worker(fd: ref Sys->FD, b: array of byte, off: big, k: int, done: chan of (int, int, string))
{
	(m, err) := piece(fd, b, off);
	done <-= (k, m, err);
}

piece(fd: ref Sys->FD, b: array of byte, off: big): (int, string)
{
	got := 0;
	while(got < len b){
		m := pread(fd, b[got:], len b - got, off + big got);
		if(m < 0)
			return (got, sys->sprint("%r"));
		if(m == 0)
			break;
		got += m;
	}
	return (got, nil);
}
