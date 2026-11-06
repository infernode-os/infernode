implement Touchgest;

#
# touchgest -- a touch screen's fingers as pointer events (touchgest.m
# says what they mean).  The state machine alone: no files and no
# clock, so a test can drive it.
#

include "sys.m";
	sys: Sys;

include "touchgest.m";

Gest.new(verb: string, slop, step: int): ref Gest
{
	if(sys == nil)
		sys = load Sys Sys->PATH;
	g := ref Gest;
	g.verb = verb;
	g.slop = slop;
	g.step = step;
	return g;
}

Gest.frame(g: self ref Gest, pts: list of (int, int), now: int): list of string
{
	out: list of string;
	nf := len pts;
	if(nf == 0){
		if(g.down)
			out = ev(g, g.x, g.y, 0) :: out;
		g.down = g.armed = g.multi = 0;
		g.nf = 0;
		return rev(out);
	}
	if(nf >= 2 || g.multi){
		if(!g.multi){
			if(g.down)
				out = ev(g, g.x, g.y, 0) :: out;
			g.down = g.armed = 0;
			g.multi = 1;
			g.acc = 0;
		}
		if(nf >= 2){
			(x1, y1) := hd pts;
			(x2, y2) := hd tl pts;
			cy := (y1 + y2) / 2;
			if(nf != g.nf)
				g.sy = cy;	# a finger came or went: the middle jumps
			g.x = (x1 + x2) / 2;
			g.y = cy;
			g.acc += cy - g.sy;
			g.sy = cy;
			# fingers up (y falls): what is below shows, the wheel's down
			for(; g.acc <= -g.step; g.acc += g.step)
				out = ev(g, g.x, g.y, 0) :: ev(g, g.x, g.y, 16) :: out;
			for(; g.acc >= g.step; g.acc -= g.step)
				out = ev(g, g.x, g.y, 0) :: ev(g, g.x, g.y, 8) :: out;
		}
		g.nf = nf;
		return rev(out);
	}
	g.nf = nf;
	(x, y) := hd pts;
	if(!g.down){
		g.down = 1;
		g.btn = 1;
		g.armed = 1;
		g.t0 = now;
		(g.x0, g.y0) = (x, y);
		(g.x, g.y) = (x, y);
		return ev(g, x, y, 1) :: nil;
	}
	dx := x - g.x0;
	dy := y - g.y0;
	if(g.armed && dx*dx + dy*dy > g.slop*g.slop)
		g.armed = 0;
	if(x != g.x || y != g.y){
		(g.x, g.y) = (x, y);
		out = ev(g, x, y, g.btn) :: out;
	}
	for(t := g.tick(now); t != nil; t = tl t)
		out = hd t :: out;	# after the move
	return rev(out);
}

Gest.tick(g: self ref Gest, now: int): list of string
{
	if(g.down && g.armed && g.btn == 1 && now - g.t0 >= Longms){
		g.armed = 0;
		g.btn = 4;
		return ev(g, g.x, g.y, 4) :: nil;	# button 1 up, button 3 down
	}
	return nil;
}

Gest.due(g: self ref Gest): int
{
	if(g.down && g.armed && g.btn == 1)
		return g.t0 + Longms;
	return -1;
}

ev(g: ref Gest, x, y, b: int): string
{
	return sys->sprint("%s %d %d %d", g.verb, x, y, b);
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}
