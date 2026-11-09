implement Trtcheck;

#
# trtcheck modeldir picture trtdir name [reps]: trtsrv's engine `name`
# (mounted at trtdir) against the CPU engine, on one picture letterboxed
# as vision(4) does: each head's largest difference, and the time of an
# inference through trtdir, a round trip, over reps (default 20).
#
#	head=0 shape=85x52x52 maxabs=0.0123 maxrel=0.0041
#	place=dla0 reps=20 ms_mean=10.9 ms_min=10.5
#
# Not a _test: tests/host/trtsrv_test.sh runs it, on a Jetson.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "tensor.m";
	tensor: Tensor;
include "visnet.m";
	visnet: Visnet;
	Net, Head: import visnet;

Trtcheck: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

stderr: ref Sys->FD;

fail(s: string)
{
	sys->fprint(stderr, "trtcheck: %s\n", s);
	raise "fail:" + s;
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	math = load Math Math->PATH;
	tensor = load Tensor Tensor->PATH;
	visnet = load Visnet Visnet->PATH;
	if(math == nil || tensor == nil || visnet == nil)
		fail(sys->sprint("load: %r"));
	if((e := visnet->init()) != nil)
		fail(e);
	args = tl args;
	if(len args < 4)
		fail("usage: trtcheck modeldir picture trtdir name [reps]");
	(mdir, pic, tdir, name) := (hd args, hd tl args, hd tl tl args, hd tl tl tl args);
	reps := 20;
	if(len args > 4)
		reps = int hd tl tl tl tl args;

	(n, err) := Net.open(mdir);
	if(n == nil)
		fail(err);
	(pix, w, h, perr) := visnet->readpixels(pic);
	if(pix == nil)
		fail(perr);
	input := array[4*3*n.inw*n.inh] of byte;
	tensor->letterbox(pix, w, h, n.scale(w, h), n.fill, n.order == "bgr", input, n.inw, n.inh);
	(heads, rerr) := n.run(input);
	if(rerr != nil)
		fail(rerr);

	# the engine's outputs, in its order, as trtsrv's ctl says them
	outs := outshapes(rd(tdir + "/ctl"), name);
	if(outs == nil)
		fail("no model " + name + " in " + tdir + "/ctl");
	place := field(rd(tdir + "/ctl"), name, "place");
	half := field(rd(tdir + "/ctl"), name, "type") == "f16";
	es := 4;
	if(half)
		es = 2;
	nout := 0;
	for(l := outs; l != nil; l = tl l)
		nout += es * prod(hd l);
	# what goes over 9P: the input in the engine's type
	tin := input;
	if(half){
		tin = array[len input / 2] of byte;
		tensor->tohalf(input, tin);
	}

	cfd := sys->open(tdir + "/clone", Sys->OREAD);
	if(cfd == nil)
		fail(sys->sprint("clone: %r"));
	b := array[32] of byte;
	k := sys->read(cfd, b, len b);
	if(k <= 0)
		fail("clone read");
	sid := string b[0:k];
	if(sid[len sid-1] == '\n')
		sid = sid[0:len sid-1];
	sdir := tdir + "/" + sid;
	if(wr(sdir + "/ctl", "model " + name) != nil)
		fail(sys->sprint("model %s: %r", name));

	out := array[nout] of byte;
	tot := 0;
	mn := 1000000;
	for(r := 0; r < reps + 1; r++){
		t0 := sys->millisec();
		e := infer(sdir + "/run", tin, out);
		if(e != nil)
			fail(e);
		dt := sys->millisec() - t0;
		if(r == 0)
			continue;	# the first warms the engine
		tot += dt;
		if(dt < mn)
			mn = dt;
	}

	# the outputs as float32, whatever went over 9P
	if(half){
		o32 := array[2 * len out] of byte;
		tensor->fromhalf(out, o32);
		out = o32;
	}
	# each output against the CPU head of its shape
	off := 0;
	i := 0;
	for(l = outs; l != nil; l = tl l){
		d := hd l;
		nb := 4 * prod(d);
		hh := match(heads, d);
		if(hh == nil)
			fail("no CPU head of shape " + shape(d));
		(ma, mr) := diff(out[off:off+nb], hh.t);
		sys->print("head=%d shape=%s maxabs=%.4f maxrel=%.4f\n", i, shape(d), ma, mr);
		off += nb;
		i++;
	}
	# what each engine's heads say was found, by the same decoding
	scale := n.scale(w, h);
	theads := array[len outs] of ref Head;
	off = 0;
	i = 0;
	for(l = outs; l != nil; l = tl l){
		d := hd l;
		nb := 4 * prod(d);
		hh := match(heads, d);
		theads[i++] = ref Head(hh.name, out[off:off+nb], d[0], d[1], d[2], hh.stride);
		off += nb;
	}
	(cdets, nil) := n.fromheads(heads, w, h, scale, 0.3, 0.45);
	(tdets, nil) := n.fromheads(theads, w, h, scale, 0.3, 0.45);
	for(j := 0; j < len cdets || j < len tdets; j++){
		cs := "-";
		ts := "-";
		if(j < len cdets)
			cs = det(n, cdets[j]);
		if(j < len tdets)
			ts = det(n, tdets[j]);
		sys->print("found cpu: %s | %s: %s\n", cs, place, ts);
	}
	sys->print("place=%s reps=%d ms_mean=%.2f ms_min=%d write_ms=%.1f read_ms=%.1f (both per rep, first included) engine: %s",
		place, reps, real tot / real reps, mn, real wms / real (reps+1), real rms / real (reps+1), rd(sdir + "/status"));
}

det(n: ref Net, d: ref Visnet->Det): string
{
	return sys->sprint("%s %.2f %.0f,%.0f,%.0f,%.0f", n.classes[d.class], d.score, d.x0, d.y0, d.x1, d.y1);
}

wms := 0;	# time writing inputs
rms := 0;	# time reading outputs (the inference is in the first read)

# one inference: the input written whole, the outputs read whole, one open
infer(path: string, input, out: array of byte): string
{
	fd := sys->open(path, Sys->ORDWR);
	if(fd == nil)
		return sys->sprint("%s: %r", path);
	t0 := sys->millisec();
	if(sys->write(fd, input, len input) != len input)
		return sys->sprint("write %s: %r", path);
	t1 := sys->millisec();
	wms += t1 - t0;
	got := 0;
	while(got < len out){
		m := sys->read(fd, out[got:], len out - got);
		if(m < 0)
			return sys->sprint("read %s: %r", path);
		if(m == 0)
			break;
		got += m;
	}
	if(got != len out)
		return sys->sprint("%s: %d bytes of %d", path, got, len out);
	rms += sys->millisec() - t1;
	return nil;
}

diff(a, b: array of byte): (real, real)
{
	ra := array[len a / 4] of real;
	rb := array[len b / 4] of real;
	tensor->toreal(a, ra);
	tensor->toreal(b, rb);
	(ma, mr) := (0.0, 0.0);
	for(j := 0; j < len ra && j < len rb; j++){
		d := math->fabs(ra[j] - rb[j]);
		if(d > ma)
			ma = d;
		m := math->fabs(rb[j]);
		if(m > 1.0 && d / m > mr)
			mr = d / m;
	}
	return (ma, mr);
}

match(heads: array of ref Head, d: array of int): ref Head
{
	for(j := 0; j < len heads; j++){
		hh := heads[j];
		if(len d == 3 && hh.c == d[0] && hh.h == d[1] && hh.w == d[2])
			return hh;
	}
	return nil;
}

prod(d: array of int): int
{
	p := 1;
	for(j := 0; j < len d; j++)
		p *= d[j];
	return p;
}

shape(d: array of int): string
{
	s := "";
	for(j := 0; j < len d; j++){
		if(j > 0)
			s += "x";
		s += string d[j];
	}
	return s;
}

# "model NAME ... out=85x52x52,85x26x26 ..." -> the shapes
outshapes(ctl, name: string): list of array of int
{
	v := field(ctl, name, "out");
	if(v == nil)
		return nil;
	(nil, parts) := sys->tokenize(v, ",");
	r: list of array of int;
	for(; parts != nil; parts = tl parts){
		(nd, ds) := sys->tokenize(hd parts, "x");
		a := array[nd] of int;
		for(j := 0; ds != nil; ds = tl ds)
			a[j++] = int hd ds;
		r = a :: r;
	}
	o: list of array of int;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

field(ctl, name, k: string): string
{
	(nil, lines) := sys->tokenize(ctl, "\n");
	for(; lines != nil; lines = tl lines){
		(nil, w) := sys->tokenize(hd lines, " ");
		if(len w < 2 || hd w != "model" || hd tl w != name)
			continue;
		for(; w != nil; w = tl w)
			if(len hd w > len k && (hd w)[0:len k+1] == k + "=")
				return (hd w)[len k+1:];
	}
	return nil;
}

rd(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	s := "";
	b := array[8192] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		s += string b[0:n];
	return s;
}

wr(path, s: string): string
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("%r");
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("%r");
	return nil;
}
