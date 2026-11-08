implement Visnet;

#
# A vision(4) model, read, checked and run on $Tensor. See module/visnet.m
# and tools/vision/onnx2vis.py, which writes the model directories this
# reads.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "keyring.m";
	keyring: Keyring;
include "math.m";
	math: Math;
include "imagefile.m";
	Rawimage: import RImagefile;
include "imgload.m";
	imgload: Imgload;
include "tensor.m";
	tensor: Tensor;
include "visnet.m";

Oinput, Oconv, Oadd, Oact, Omaxpool, Oup2, Os2d, Oconcat, Ooutput: con iota;

Maxside: con 8192;

init(): string
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	keyring = load Keyring Keyring->PATH;
	math = load Math Math->PATH;
	imgload = load Imgload Imgload->PATH;
	if(imgload != nil)
		imgload->init(nil);	# its decoders need its Bufio, not a display
	tensor = load Tensor Tensor->PATH;
	if(tensor == nil)
		return "no $Tensor in this system";
	if(bufio == nil || str == nil || keyring == nil || math == nil)
		return sys->sprint("cannot load a library: %r");
	return nil;
}

readfile(path: string): (array of byte, string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%s: %r", path));
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return (nil, sys->sprint("%s: %r", path));
	if(d.length > big (1<<30))
		return (nil, path + ": too large");
	buf := array[int d.length] of byte;
	n := 0;
	while(n < len buf){
		m := sys->read(fd, buf[n:], len buf - n);
		if(m < 0)
			return (nil, sys->sprint("%s: %r", path));
		if(m == 0)
			break;
		n += m;
	}
	if(n != len buf)
		return (nil, path + ": short read");
	return (buf, nil);
}

readtext(path: string): (string, string)
{
	(b, err) := readfile(path);
	if(err != nil)
		return (nil, err);
	return (string b, nil);
}

# attr=value fields of a line, after its first word
fields(line: string): (string, list of (string, string))
{
	(nil, ws) := sys->tokenize(line, " \t\r\n");
	if(ws == nil)
		return (nil, nil);
	op := hd ws;
	kv: list of (string, string);
	for(ws = tl ws; ws != nil; ws = tl ws){
		(k, v) := str->splitl(hd ws, "=");
		if(v != nil)
			v = v[1:];
		kv = (k, v) :: kv;
	}
	return (op, kv);
}

get(kv: list of (string, string), k: string): string
{
	for(; kv != nil; kv = tl kv)
		if((hd kv).t0 == k)
			return (hd kv).t1;
	return nil;
}

# a non-negative number, or -1
num(s: string): int
{
	if(s == nil || len s > 9)
		return -1;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return -1;
	return int s;
}

hex(d: array of byte): string
{
	s := "";
	for(i := 0; i < len d; i++)
		s += sys->sprint("%.2ux", int d[i]);
	return s;
}

actcode(s: string): int
{
	case s {
	"none" =>	return Tensor->None;
	"relu" =>	return Tensor->Relu;
	"sigmoid" =>	return Tensor->Sigmoid;
	"silu" =>	return Tensor->Silu;
	}
	return -1;
}

Names: adt {
	names:	array of string;
	n:	int;
	find:	fn(t: self ref Names, s: string): int;
	add:	fn(t: self ref Names, s: string): int;
};

Names.find(t: self ref Names, s: string): int
{
	for(i := 0; i < t.n; i++)
		if(t.names[i] == s)
			return i;
	return -1;
}

Names.add(t: self ref Names, s: string): int
{
	if(t.n == len t.names){
		a := array[2*len t.names + 8] of string;
		a[0:] = t.names[0:t.n];
		t.names = a;
	}
	t.names[t.n] = s;
	return t.n++;
}

Net.open(dir: string): (ref Net, string)
{
	n := ref Net;
	n.dir = dir;

	(info, err) := readtext(dir + "/info");
	if(err != nil)
		return (nil, err);
	(nil, kv) := fields("info " + info);
	n.kind = get(kv, "kind");
	n.decode = get(kv, "decode");
	n.order = get(kv, "order");
	n.fill = num(get(kv, "fill"));
	n.nclass = num(get(kv, "classes"));
	(ws, hs) := str->splitl(get(kv, "input"), "x");
	if(hs != nil)
		hs = hs[1:];
	n.inw = num(ws);
	n.inh = num(hs);
	if(n.kind != "detect" || n.decode != "yolox")
		return (nil, sys->sprint("%s: kind=%s decode=%s: only detect, yolox", dir, n.kind, n.decode));
	if(n.inw < 32 || n.inh < 32 || n.inw > Maxside || n.inh > Maxside || n.nclass < 1 || n.fill < 0 || n.fill > 255 ||
	   (n.order != "rgb" && n.order != "bgr"))
		return (nil, dir + "/info: bad input, classes, order or fill");

	(cls, cerr) := readtext(dir + "/classes");
	if(cerr != nil)
		return (nil, cerr);
	(nc, cl) := sys->tokenize(cls, "\n");
	if(nc != n.nclass)
		return (nil, sys->sprint("%s/classes: %d names, info says %d", dir, nc, n.nclass));
	n.classes = array[nc] of string;
	for(i := 0; cl != nil; cl = tl cl)
		n.classes[i++] = hd cl;

	# the weights, and their hash: what runs is what was meant to run
	(sha, serr) := readtext(dir + "/sha256");
	if(serr != nil)
		return (nil, serr);
	(nil, sl) := sys->tokenize(sha, " \t\n");
	if(sl == nil)
		return (nil, dir + "/sha256: empty");
	n.sha256 = hd sl;
	if(len n.sha256 != 64)
		return (nil, dir + "/sha256: not a sha256");
	(wts, werr) := readfile(dir + "/weights");
	if(werr != nil)
		return (nil, werr);
	if(len wts % 4 != 0)
		return (nil, dir + "/weights: not whole floats");
	digest := array[Keyring->SHA256dlen] of byte;
	keyring->sha256(wts, len wts, digest, nil);
	if(hex(digest) != str->tolower(n.sha256))
		# short: an error string holds about 128 bytes
		return (nil, sys->sprint("weights do not match their sha256 (%s..., want %s...): refused",
			hex(digest)[0:16], str->tolower(n.sha256)[0:16]));
	n.wts = wts;
	n.nweights = len wts / 4;

	(graph, gerr) := readtext(dir + "/graph");
	if(gerr != nil)
		return (nil, gerr);
	(nl, lines) := sys->tokenize(graph, "\n");
	if(lines == nil || hd lines != "vis 1")
		return (nil, dir + "/graph: not a vis 1 graph");
	lines = tl lines;
	names := ref Names(array[64] of string, 0);
	ops := array[nl] of ref Op;
	shapes := array[nl] of (int, int, int);	# a tensor per op at most
	nop := 0;
	for(; lines != nil; lines = tl lines){
		line := hd lines;
		(op, a) := fields(line);
		if(op == nil)
			continue;
		bad := dir + "/graph: " + line;
		o := ref Op(0, -1, nil, nil, nil);
		ins: list of string;
		case op {
		"input" =>	o.op = Oinput;
		"conv" =>	o.op = Oconv; ins = get(a, "in") :: nil;
		"add" =>	o.op = Oadd; ins = get(a, "a") :: get(a, "b") :: nil;
		"act" =>	o.op = Oact; ins = get(a, "in") :: nil;
		"maxpool" =>	o.op = Omaxpool; ins = get(a, "in") :: nil;
		"up2" =>	o.op = Oup2; ins = get(a, "in") :: nil;
		"s2d" =>	o.op = Os2d; ins = get(a, "in") :: nil;
		"concat" =>
			o.op = Oconcat;
			(nil, ins) = sys->tokenize(get(a, "in"), ",");
		"output" =>	o.op = Ooutput; ins = get(a, "in") :: nil;
		* =>
			return (nil, bad + ": no such operation");
		}
		o.ins = array[len ins] of int;
		i = 0;
		for(; ins != nil; ins = tl ins){
			x := names.find(hd ins);
			if(x < 0)
				return (nil, bad + ": " + hd ins + " is not made before it is used");
			o.ins[i++] = x;
		}
		c, h, w: int;
		case o.op {
		Oinput =>
			(c, h, w) = (num(get(a, "c")), num(get(a, "h")), num(get(a, "w")));
			if(c != 3 || h != n.inh || w != n.inw)
				return (nil, bad + ": not info's input");
		Oconv =>
			(ic, ih, iw) := shapes[o.ins[0]];
			oc := num(get(a, "oc"));
			kh := num(get(a, "kh"));
			kw := num(get(a, "kw"));
			s := num(get(a, "stride"));
			p := num(get(a, "pad"));
			g := num(get(a, "group"));
			act := actcode(get(a, "act"));
			wo := num(get(a, "w"));
			bo := num(get(a, "b"));
			if(num(get(a, "ic")) != ic || oc < 1 || kh < 1 || kw < 1 || s < 1 || p < 0 || act < 0 || wo < 0 || bo < 0 ||
			   (g != 1 && (g != ic || oc != ic)) || ih + 2*p < kh || iw + 2*p < kw)
				return (nil, bad + ": bad numbers");
			icg := ic / g;
			if(big wo + big (oc*icg*kh*kw) > big n.nweights || big bo + big oc > big n.nweights)
				return (nil, bad + ": past the weights");
			o.p = array[] of {oc, kh, kw, s, p, g, act, wo, bo};
			(c, h, w) = (oc, (ih + 2*p - kh)/s + 1, (iw + 2*p - kw)/s + 1);
		Oadd =>
			(c, h, w) = shapes[o.ins[0]];
			(c1, h1, w1) := shapes[o.ins[1]];
			if(c1 != c || h1 != h || w1 != w)
				return (nil, bad + ": shapes differ");
		Oact =>
			(c, h, w) = shapes[o.ins[0]];
			act := actcode(get(a, "act"));
			if(act < 0)
				return (nil, bad + ": no such activation");
			o.p = array[] of {act};
		Omaxpool =>
			(ic, ih, iw) := shapes[o.ins[0]];
			k := num(get(a, "k"));
			s := num(get(a, "stride"));
			p := num(get(a, "pad"));
			if(k < 1 || s < 1 || p < 0 || p > k/2 || ih + 2*p < k || iw + 2*p < k)
				return (nil, bad + ": bad numbers");
			o.p = array[] of {k, s, p};
			(c, h, w) = (ic, (ih + 2*p - k)/s + 1, (iw + 2*p - k)/s + 1);
		Oup2 =>
			(c, h, w) = shapes[o.ins[0]];
			(h, w) = (2*h, 2*w);
		Os2d =>
			(c, h, w) = shapes[o.ins[0]];
			if((h|w) & 1)
				return (nil, bad + ": odd rows or columns");
			(c, h, w) = (4*c, h/2, w/2);
		Oconcat =>
			if(len o.ins < 1)
				return (nil, bad + ": nothing to concatenate");
			(nil, h, w) = shapes[o.ins[0]];
			c = 0;
			for(j := 0; j < len o.ins; j++){
				(cj, hj, wj) := shapes[o.ins[j]];
				if(hj != h || wj != w)
					return (nil, bad + ": shapes differ");
				c += cj;
			}
		Ooutput =>
			(c, h, w) = shapes[o.ins[0]];
			s := num(get(a, "stride"));
			if(s < 1 || c != n.nclass + 5)
				return (nil, bad + ": not a head of 5 + classes");
			o.name = get(a, "name");
			o.p = array[] of {s};
		}
		if(o.op != Ooutput){
			name := get(a, "out");
			if(o.op == Oinput)
				name = get(a, "name");
			if(name == nil || names.find(name) >= 0)
				return (nil, bad + ": no name, or one made twice");
			if(c < 1 || h < 1 || w < 1 || big c * big h * big w > big (1<<26))
				return (nil, bad + ": a tensor of no size, or too large");
			o.out = names.add(name);
			shapes[o.out] = (c, h, w);
		}
		ops[nop++] = o;
	}
	n.ops = ops[0:nop];
	n.nops = nop;
	n.shapes = shapes[0:names.n];
	if(nop == 0 || n.ops[0].op != Oinput)
		return (nil, dir + "/graph: no input first");

	# the last op to read each tensor, so it can be let go after it;
	# a head's tensor is kept for the caller
	n.last = array[names.n] of { * => -1 };
	for(i = 0; i < nop; i++)
		for(j := 0; j < len n.ops[i].ins; j++){
			x := n.ops[i].ins[j];
			if(n.ops[i].op == Ooutput)
				n.last[x] = nop;
			else if(n.last[x] < i)
				n.last[x] = i;
		}
	return (n, nil);
}

Net.run(n: self ref Net, input: array of byte): (array of ref Head, string)
{
	if(len input != 4*3*n.inw*n.inh)
		return (nil, "input is not 3 x the model's input");
	t := array[len n.shapes] of array of byte;
	heads: list of ref Head;
	for(i := 0; i < n.nops; i++){
		o := n.ops[i];
		p := o.p;
		pt := big 0;
		if(profon)
			pt = pnow();
		if(o.out >= 0 && o.op != Oinput){
			(c, h, w) := n.shapes[o.out];
			t[o.out] = array[4*c*h*w] of byte;
		}
		if(profon){
			pacc(Palloc, pt);
			pt = pnow();
		}
		{
			case o.op {
			Oinput =>
				t[o.out] = input;
			Oconv =>
				(c, h, w) := n.shapes[o.ins[0]];
				(oc, kh, kw, s, pad, g, act, wo, bo) := (p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8]);
				nw := oc * (c/g) * kh * kw;
				tensor->conv(t[o.ins[0]], c, h, w, n.wts[4*wo:4*(wo+nw)], oc, kh, kw, s, pad, g,
					n.wts[4*bo:4*(bo+oc)], act, t[o.out]);
			Oadd =>
				tensor->add(t[o.ins[0]], t[o.ins[1]], t[o.out]);
			Oact =>
				tensor->act(t[o.ins[0]], t[o.out], p[0]);
			Omaxpool =>
				(c, h, w) := n.shapes[o.ins[0]];
				tensor->maxpool(t[o.ins[0]], c, h, w, p[0], p[1], p[2], t[o.out]);
			Oup2 =>
				(c, h, w) := n.shapes[o.ins[0]];
				tensor->up2(t[o.ins[0]], c, h, w, t[o.out]);
			Os2d =>
				(c, h, w) := n.shapes[o.ins[0]];
				tensor->s2d(t[o.ins[0]], c, h, w, t[o.out]);
			Oconcat =>
				off := 0;
				for(j := 0; j < len o.ins; j++){
					x := t[o.ins[j]];
					t[o.out][off:] = x;
					off += len x;
				}
			Ooutput =>
				(c, h, w) := n.shapes[o.ins[0]];
				heads = ref Head(o.name, t[o.ins[0]], c, h, w, p[0]) :: heads;
			}
		} exception e {
		"*" =>
			return (nil, sys->sprint("operation %d: %s", i, e));
		}
		if(profon)
			pacc(opkind(n, o), pt);
		for(j := 0; j < len o.ins; j++)
			if(n.last[o.ins[j]] == i)
				t[o.ins[j]] = nil;
	}
	a := array[len heads] of ref Head;
	for(i = len a - 1; heads != nil; heads = tl heads)
		a[i--] = hd heads;
	return (a, nil);
}

Net.detect(n: self ref Net, pix: array of byte, w, h: int, thresh, iou: real): (array of ref Det, string)
{
	if(w < 1 || h < 1 || len pix < 3*w*h)
		return (nil, "picture smaller than its size");
	scale := n.scale(w, h);
	input := array[4*3*n.inw*n.inh] of byte;
	lt := big 0;
	if(profon)
		lt = pnow();
	{
		tensor->letterbox(pix, w, h, scale, n.fill, n.order == "bgr", input, n.inw, n.inh);
	} exception e {
	"*" =>
		return (nil, "letterbox: " + e);
	}
	if(profon)
		pacc(Pletterbox, lt);
	return n.found(input, w, h, scale, thresh, iou);
}

Net.detecti420(n: self ref Net, y, cb, cr: array of byte, w, h: int, thresh, iou: real): (array of ref Det, string)
{
	if(w < 2 || h < 2 || (w|h) & 1 || len y < w*h || len cb < (w/2)*(h/2) || len cr < (w/2)*(h/2))
		return (nil, "frame smaller than its size, or odd");
	scale := n.scale(w, h);
	input := array[4*3*n.inw*n.inh] of byte;
	lt := big 0;
	if(profon)
		lt = pnow();
	{
		tensor->letterboxi420(y, cb, cr, w, h, scale, n.fill, n.order == "bgr", input, n.inw, n.inh);
	} exception e {
	"*" =>
		return (nil, "letterbox: " + e);
	}
	if(profon)
		pacc(Pletterbox, lt);
	return n.found(input, w, h, scale, thresh, iou);
}

# the kind an operation is counted as, profiling
opkind(n: ref Net, o: ref Op): int
{
	case o.op {
	Oconv =>
		(c, nil, nil) := n.shapes[o.ins[0]];
		(kh, kw, g) := (o.p[1], o.p[2], o.p[5]);
		if(g > 1 && g == c)
			return Pconvdw;
		if(kh == 1 && kw == 1)
			return Pconv1;
		if(kh == 3 && kw == 3)
			return Pconv3;
		return Pconvo;
	Oadd =>	return Padd;
	Oact =>	return Pact;
	Omaxpool =>	return Pmaxpool;
	Oup2 =>	return Pup2;
	Os2d =>	return Ps2d;
	Oconcat =>	return Pconcat;
	}
	return Pconvo;
}

# the scale that fits a w by h picture into the input, aspect kept
Net.scale(n: self ref Net, w, h: int): real
{
	scale := real n.inw / real w;
	if(real n.inh / real h < scale)
		scale = real n.inh / real h;
	return scale;
}

# the network on an input made from a w by h picture by scale: what it found there
Net.found(n: self ref Net, input: array of byte, w, h: int, scale, thresh, iou: real): (array of ref Det, string)
{
	(heads, err) := n.run(input);
	if(err != nil)
		return (nil, err);
	pt := big 0;
	if(profon)
		pt = pnow();
	dets: list of ref Det;
	nd := 0;
	for(k := 0; k < len heads; k++){
		hh := heads[k];
		r := array[len hh.t / 4] of real;
		tensor->toreal(hh.t, r);
		hw := hh.h * hh.w;
		s := real hh.stride;
		for(i := 0; i < hw; i++){
			obj := r[4*hw + i];
			if(obj < thresh)
				continue;
			best := 0;
			bs := r[5*hw + i];
			for(c := 1; c < n.nclass; c++){
				v := r[(5+c)*hw + i];
				if(v > bs){
					bs = v;
					best = c;
				}
			}
			score := obj * bs;
			if(score < thresh)
				continue;
			gx := real (i % hh.w);
			gy := real (i / hh.w);
			cx := (r[i] + gx) * s;
			cy := (r[hw + i] + gy) * s;
			bw := math->exp(r[2*hw + i]) * s;
			bh := math->exp(r[3*hw + i]) * s;
			d := ref Det(best, score,
				clamp((cx - bw/2.0)/scale, real w), clamp((cy - bh/2.0)/scale, real h),
				clamp((cx + bw/2.0)/scale, real w), clamp((cy + bh/2.0)/scale, real h));
			dets = d :: dets;
			nd++;
		}
	}
	found := nms(dets, nd, iou);
	if(profon)
		pacc(Pdecode, pt);
	return (found, nil);
}

clamp(v, max: real): real
{
	if(v < 0.0)
		return 0.0;
	if(v > max)
		return max;
	return v;
}

# best first; a box overlapping a better one of its class by iou or more goes
nms(dets: list of ref Det, nd: int, iou: real): array of ref Det
{
	a := array[nd] of ref Det;
	for(i := 0; dets != nil; dets = tl dets)
		a[i++] = hd dets;
	# insertion sort, by score, then by place so the order is the same every time
	for(i = 1; i < nd; i++){
		d := a[i];
		j := i - 1;
		while(j >= 0 && better(d, a[j])){
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = d;
	}
	keep := array[nd] of ref Det;
	nk := 0;
	for(i = 0; i < nd; i++){
		d := a[i];
		ok := 1;
		for(j := 0; j < nk; j++)
			if(keep[j].class == d.class && overlap(keep[j], d) >= iou){
				ok = 0;
				break;
			}
		if(ok)
			keep[nk++] = d;
	}
	return keep[0:nk];
}

better(a, b: ref Det): int
{
	if(a.score != b.score)
		return a.score > b.score;
	if(a.y0 != b.y0)
		return a.y0 < b.y0;
	return a.x0 < b.x0;
}

overlap(a, b: ref Det): real
{
	ix := min(a.x1, b.x1) - max(a.x0, b.x0);
	iy := min(a.y1, b.y1) - max(a.y0, b.y0);
	if(ix <= 0.0 || iy <= 0.0)
		return 0.0;
	inter := ix * iy;
	u := (a.x1 - a.x0)*(a.y1 - a.y0) + (b.x1 - b.x0)*(b.y1 - b.y0) - inter;
	if(u <= 0.0)
		return 0.0;
	return inter / u;
}

min(a, b: real): real
{
	if(a < b)
		return a;
	return b;
}

max(a, b: real): real
{
	if(a > b)
		return a;
	return b;
}

readpixels(path: string): (array of byte, int, int, string)
{
	(data, err) := readfile(path);
	if(err != nil)
		return (nil, 0, 0, err);
	return readpixelsdata(data, path);
}

# a picture's pixels as Draw->RGB24 keeps them: blue, green, red
readpixelsdata(data: array of byte, hint: string): (array of byte, int, int, string)
{
	if(len data > 2 && data[0] == byte 'P' && data[1] == byte '6')
		return readppm(data, hint);
	if(imgload == nil)
		return (nil, 0, 0, "no image decoders");
	head := data;
	if(len head > 512)
		head = head[0:512];
	fmt := imgload->format(head, hint);
	if(fmt == nil)
		return (nil, 0, 0, hint + ": not a picture this system reads");
	(rd, err) := imgload->reader(fmt);
	if(rd == nil)
		return (nil, 0, 0, hint + ": " + err);
	raw: ref Rawimage;
	{
		(raw, err) = rd->read(bufio->aopen(data));
	} exception e {
	"*" =>
		return (nil, 0, 0, hint + ": " + e);
	}
	if(raw == nil)
		return (nil, 0, 0, hint + ": " + err);
	w := raw.r.max.x - raw.r.min.x;
	h := raw.r.max.y - raw.r.min.y;
	if(w < 1 || h < 1 || w > 1<<14 || h > 1<<14)
		return (nil, 0, 0, hint + ": no size, or too large");
	n := w*h;
	pix := array[3*n] of byte;
	case raw.chandesc {
	RImagefile->CRGB or RImagefile->CRGBA =>
		(r, g, b) := (raw.chans[0], raw.chans[1], raw.chans[2]);
		if(len r < n || len g < n || len b < n)
			return (nil, 0, 0, hint + ": short planes");
		for(i := 0; i < n; i++){
			pix[3*i] = b[i];
			pix[3*i+1] = g[i];
			pix[3*i+2] = r[i];
		}
	RImagefile->CY =>
		y := raw.chans[0];
		if(len y < n)
			return (nil, 0, 0, hint + ": short plane");
		for(i := 0; i < n; i++)
			pix[3*i] = pix[3*i+1] = pix[3*i+2] = y[i];
	RImagefile->CRGB1 =>
		x := raw.chans[0];
		m := raw.cmap;
		if(len x < n)
			return (nil, 0, 0, hint + ": short plane");
		for(i := 0; i < n; i++){
			k := 3*int x[i];
			if(k+2 < len m){
				pix[3*i] = m[k+2];
				pix[3*i+1] = m[k+1];
				pix[3*i+2] = m[k];
			}
		}
	* =>
		return (nil, 0, 0, sys->sprint("%s: channels of kind %d", hint, raw.chandesc));
	}
	return (pix, w, h, nil);
}

# a binary PPM (P6, maxval 255): what a test gives to have exactly the
# pixels another program read
readppm(data: array of byte, hint: string): (array of byte, int, int, string)
{
	# the header: P6, width, height, maxval, each after white space and comments
	v := array[3] of int;
	i := 2;
	for(k := 0; k < 3; k++){
		for(;;){
			while(i < len data && (data[i] == byte ' ' || data[i] == byte '\t' || data[i] == byte '\n' || data[i] == byte '\r'))
				i++;
			if(i < len data && data[i] == byte '#'){
				while(i < len data && data[i] != byte '\n')
					i++;
				continue;
			}
			break;
		}
		n := 0;
		j := i;
		while(i < len data && data[i] >= byte '0' && data[i] <= byte '9' && i - j < 6)
			n = 10*n + int data[i++] - '0';
		if(i == j)
			return (nil, 0, 0, hint + ": a bad PPM header");
		v[k] = n;
	}
	i++;	# the one white space after maxval
	(w, h, maxv) := (v[0], v[1], v[2]);
	if(maxv != 255 || w < 1 || h < 1 || w > 1<<14 || h > 1<<14 || len data - i < 3*w*h)
		return (nil, 0, 0, hint + ": a PPM this does not read (P6, 255, whole)");
	pix := array[3*w*h] of byte;
	for(p := 0; p < w*h; p++){
		pix[3*p] = data[i + 3*p + 2];
		pix[3*p+1] = data[i + 3*p + 1];
		pix[3*p+2] = data[i + 3*p];
	}
	return (pix, w, h, nil);
}

# ---- profiling ----

Pkinds := array[] of {
	"alloc", "conv 1x1", "conv 3x3", "conv depthwise", "conv other", "add", "act",
	"maxpool", "up2", "s2d", "concat", "letterbox", "decode and nms", "timer",
};
Palloc, Pconv1, Pconv3, Pconvdw, Pconvo, Padd, Pact, Pmaxpool, Pup2, Ps2d, Pconcat, Pletterbox, Pdecode, Ptimer: con iota;
profon := 0;
pfd: ref Sys->FD;
pus := array[14] of big;
pn := array[14] of int;
pbuf := array[32] of byte;

profile(on: int)
{
	profon = on;
	if(on && pfd == nil)
		pfd = sys->open("/dev/time", Sys->OREAD);
	if(pfd == nil)
		profon = 0;
	for(i := 0; i < len pus; i++){
		pus[i] = big 0;
		pn[i] = 0;
	}
}

pnow(): big
{
	n := sys->pread(pfd, pbuf, len pbuf, big 0);
	if(n <= 0)
		return big 0;
	return big string pbuf[0:n];
}

pacc(k: int, t0: big)
{
	t1 := pnow();
	pus[k] += t1 - t0;
	pn[k]++;
	# what a reading of the clock costs, counted apart
	t2 := pnow();
	pus[Ptimer] += t2 - t1;
	pn[Ptimer]++;
}

profiled(): string
{
	tot := big 0;
	for(i := 0; i < len pus; i++)
		tot += pus[i];
	s := "";
	for(i = 0; i < len pus; i++)
		if(pn[i] > 0)
			s += sys->sprint("kind=%q n=%d us=%bd pct=%.1f\n", Pkinds[i], pn[i], pus[i],
				100.0 * real pus[i] / real (tot + big 1));
	s += sys->sprint("total us=%bd\n", tot);
	for(i = 0; i < len pus; i++){
		pus[i] = big 0;
		pn[i] = 0;
	}
	return s;
}
