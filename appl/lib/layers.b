implement Layers;

#
# A feed's layers, followed. See module/layers.m.
#

include "sys.m";
	sys: Sys;
include "string.m";
	str: String;
include "layers.m";

Keep: con 64;		# the frames a layer keeps the records of
Listms: con 500;	# how often the directory is listed for binds and unmounts

init(): string
{
	sys = load Sys Sys->PATH;
	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load a library: %r");
	return nil;
}

parse(line: string): (int, ref Mark)
{
	frame := -2;
	kind := -1;
	kv: list of (string, string);
	for(ws := str->unquoted(line); ws != nil; ws = tl ws){
		(k, v) := str->splitl(hd ws, "=");
		if(v == nil){
			case k {
			"box" =>	kind = Box;
			"line" =>	kind = Line;
			"text" =>	kind = Text;
			"point" =>	kind = Point;
			}
			continue;
		}
		v = v[1:];
		if(k == "frame"){
			if(v == "*")
				frame = -1;
			else {
				(n, rest) := str->toint(v, 10);
				if(rest != nil || n < 0)
					return (-2, nil);
				frame = n;
			}
			continue;
		}
		kv = (k, v) :: kv;
	}
	if(frame == -2)
		return (-2, nil);
	# the frame's key alone (with what else a record carries: pts=, ...)
	if(kind < 0 && get(kv, "x0") == nil && get(kv, "x") == nil)
		return (frame, nil);
	m := ref Mark(kind, 0, 0, 0, 0, nil, nil);
	(x0, ok0) := num(kv, "x0");
	(y0, ok1) := num(kv, "y0");
	(x1, ok2) := num(kv, "x1");
	(y1, ok3) := num(kv, "y1");
	(x, okx) := num(kv, "x");
	(y, oky) := num(kv, "y");
	if(m.kind < 0 && ok0 && ok1 && ok2 && ok3)
		m.kind = Box;
	case m.kind {
	Box or Line =>
		if(!(ok0 && ok1 && ok2 && ok3))
			return (-2, nil);
		(m.x0, m.y0, m.x1, m.y1) = (x0, y0, x1, y1);
	Text or Point =>
		if(!(okx && oky))
			return (-2, nil);
		(m.x0, m.y0) = (x, y);
	* =>
		return (-2, nil);
	}
	m.label = get(kv, "label");
	if(m.label == nil && (c := get(kv, "class")) != nil){
		m.label = c;
		if((s := get(kv, "score")) != nil)
			m.label += " " + s;
	}
	m.colour = get(kv, "colour");
	return (frame, m);
}

get(kv: list of (string, string), k: string): string
{
	for(; kv != nil; kv = tl kv)
		if((hd kv).t0 == k)
			return (hd kv).t1;
	return nil;
}

num(kv: list of (string, string), k: string): (int, int)
{
	v := get(kv, k);
	if(v == nil)
		return (0, 0);
	(n, rest) := str->toint(v, 10);
	if(rest != nil)
		return (0, 0);
	return (n, 1);
}

Stack.watch(dir: string): ref Stack
{
	s := ref Stack(dir, array[0] of ref Layer, nil, chan of int);
	spawn watcher(s);
	return s;
}

Stack.stop(s: self ref Stack)
{
	alt {
	s.ctl <-= 0 =>
		;
	* =>
		;
	}
}

Stack.due(s: self ref Stack, frame: int): list of ref Mark
{
	ls := s.layers;
	out: list of ref Mark;
	# built top first, so the list comes out bottom first
	for(i := len ls - 1; i >= 0; i--){
		l := ls[i];
		fs := l.frames;
		best := -1;
		for(j := len fs - 1; j >= 0; j--)
			if(fs[j].t0 <= frame){
				best = j;
				break;
			}
		m: list of ref Mark;
		if(best >= 0)
			for(m = fs[best].t1; m != nil; m = tl m)
				out = hd m :: out;
		for(m = l.all; m != nil; m = tl m)
			out = hd m :: out;
	}
	return out;
}

# lists the directory, starting a reader for each layer bound and
# stopping the reader of each unmounted, in the union's order
watcher(s: ref Stack)
{
	pidc := chan of int;
	for(;;){
		names := listing(s.dir);
		old := s.layers;
		nl := array[len names] of ref Layer;
		for(i := 0; i < len names; i++){
			for(j := 0; j < len old; j++)
				if(old[j] != nil && old[j].name == names[i])
					break;
			if(j < len old)
				nl[i] = old[j];
			else {
				nl[i] = ref Layer(names[i], nil, array[0] of (int, list of ref Mark));
				spawn reader(s.dir + "/" + names[i], nl[i], pidc);
				s.pids = (names[i], <-pidc) :: s.pids;
			}
		}
		# the readers of layers gone
		np: list of (string, int);
		for(p := s.pids; p != nil; p = tl p){
			(n, pid) := hd p;
			found := 0;
			for(i = 0; i < len names; i++)
				if(names[i] == n)
					found = 1;
			if(found)
				np = hd p :: np;
			else
				kill(pid);
		}
		s.pids = np;
		s.layers = nl;
		alt {
		<-s.ctl =>
			for(p = s.pids; p != nil; p = tl p)
				kill((hd p).t1);
			s.pids = nil;
			s.layers = array[0] of ref Layer;
			return;
		* =>
			sys->sleep(Listms);
		}
	}
}

listing(dir: string): array of string
{
	fd := sys->open(dir, Sys->OREAD);
	if(fd == nil)
		return array[0] of string;
	names: list of string;
	n := 0;
	for(;;){
		(k, d) := sys->dirread(fd);
		if(k <= 0)
			break;
		for(i := 0; i < k; i++)
			if((d[i].mode & Sys->DMDIR) == 0 && !member(d[i].name, names)){
				names = d[i].name :: names;
				n++;
			}
	}
	a := array[n] of string;
	for(; names != nil; names = tl names)
		a[--n] = hd names;
	return a;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

# one layer's records, as they come: a file that ends is read once and
# kept; one that waits (a session's, a pipe's) is read as it comes, a
# frame's records a read. A frame is put into the layer at the end of
# each read with all of it so far, so a file's frame split across reads
# is only ever put whole at the last.
reader(path: string, l: ref Layer, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return;
	buf := array[Sys->ATOMICIO] of byte;
	part := "";
	cur := -2;
	marks: list of ref Mark;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		text := part + string buf[0:n];
		part = "";
		for(;;){
			(line, rest) := str->splitl(text, "\n");
			if(rest == nil){
				part = line;	# no newline yet
				break;
			}
			text = rest[1:];
			(f, m) := parse(line);
			if(f == -2)
				continue;
			if(f == -1){
				if(m != nil)
					l.all = append(l.all, m);
				continue;
			}
			if(f != cur){
				if(cur >= 0)
					put(l, cur, marks);
				cur = f;
				marks = nil;
			}
			if(m != nil)
				marks = append(marks, m);
		}
		if(cur >= 0)
			put(l, cur, marks);
	}
	if(part != nil){
		(f, m) := parse(part);
		if(f == -1 && m != nil)
			l.all = append(l.all, m);
		else if(f >= 0){
			if(f != cur){
				if(cur >= 0)
					put(l, cur, marks);
				cur = f;
				marks = nil;
			}
			if(m != nil)
				marks = append(marks, m);
		}
	}
	if(cur >= 0)
		put(l, cur, marks);
}

append(l: list of ref Mark, m: ref Mark): list of ref Mark
{
	r: list of ref Mark;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	r = m :: r;
	o: list of ref Mark;
	for(; r != nil; r = tl r)
		o = hd r :: o;
	return o;
}

# a frame's marks into its layer, replacing its table whole
put(l: ref Layer, frame: int, marks: list of ref Mark)
{
	fs := l.frames;
	n := len fs;
	for(i := 0; i < n; i++)
		if(fs[i].t0 == frame){
			nf := array[n] of (int, list of ref Mark);
			nf[0:] = fs;
			nf[i] = (frame, marks);
			l.frames = nf;
			return;
		}
	# kept in frame order; the oldest dropped past Keep
	k := n + 1;
	if(k > Keep)
		k = Keep;
	nf := array[k] of (int, list of ref Mark);
	j := k - 1;
	i = n - 1;
	placed := 0;
	while(j >= 0){
		if(!placed && (i < 0 || fs[i].t0 < frame)){
			nf[j--] = (frame, marks);
			placed = 1;
		} else if(i >= 0)
			nf[j--] = fs[i--];
		else
			break;
	}
	l.frames = nf[j+1:];
}
