implement Memsz;
include "sys.m"; sys: Sys;
include "draw.m";
Memsz: module { init: fn(nil: ref Draw->Context, args: list of string); };
V: adt { t: int; i: int; n: real; s: string; o: ref O; };
O: adt { sh: ref O; slots: array of V; cls: int; flags: int; elems: array of V; alen: int; fun: ref O; env: ref O; data: ref O; kid: ref O; };
O7: adt { sh: ref O; slots: array of V; elems: array of V; fun: ref O; env: ref O; data: ref O; kid: ref O; cls: int; flags: int; alen: int; };
heap(): int
{
	fd := sys->open("/dev/memory", Sys->OREAD);
	b := array[1024] of byte;
	k := sys->read(fd, b, len b);
	(nil, lines) := sys->tokenize(string b[0:k], "\n");
	for(; lines != nil; lines = tl lines) {
		(nil, f) := sys->tokenize(hd lines, " \t");
		if(len f >= 8 && hd tl tl tl tl tl tl tl f == "heap")
			return int hd f;
	}
	return 0;
}
init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	N := 10000;
	a := array[N] of ref O;
	m := heap();
	for(i := 0; i < N; i++) a[i] = ref O;
	sys->print("O %d\n", (heap() - m) / N);
	b := array[N] of ref O7;
	m = heap();
	for(i = 0; i < N; i++) b[i] = ref O7;
	sys->print("O7 %d\n", (heap() - m) / N);
	c := array[N] of array of V;
	for(k := 1; k <= 6; k++) {
		m = heap();
		for(i = 0; i < N; i++) c[i] = array[k] of V;
		sys->print("array[%d] of V: %d\n", k, (heap() - m) / N);
		c = array[N] of array of V;
	}
}
