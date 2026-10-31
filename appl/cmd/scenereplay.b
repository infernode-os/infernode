implement Scenereplay;

#
# scenereplay — play a scene recording back as records.
#
#	scenereplay [-t start] [-x rate] [recording]
#
# A recording is what scenefs(4)'s changes file reads: records
# (docs/scene-design.md §3.2), stamped by time records.  scenereplay
# writes, on standard output, the scene as it stood at start (default:
# the first time in the recording) as one batch, then each tick's
# records as one write, paced by the recording's clock: -x 2 plays at
# twice its speed, -x 0 as fast as the reader takes it.  So
#
#	cat /mnt/scene/changes > run.scene
#	scenereplay -t 120 run.scene > /mnt/scene/log
#
# records a run and later shows it again from two minutes in.  Standard
# input is read when no recording is named.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "scene.m";
	scene: Scene;
	Model: import scene;

Scenereplay: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

# One tick: a time record and the records up to the next one.
Tick: adt {
	t:	real;
	text:	string;
};

stderr: ref Sys->FD;
stdout: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	stdout = sys->fildes(1);
	bufio = load Bufio Bufio->PATH;
	scene = load Scene Scene->PATH;
	arg := load Arg Arg->PATH;
	if(bufio == nil || scene == nil || arg == nil)
		fail(sys->sprint("cannot load modules: %r"));

	arg->init(argv);
	arg->setusage("scenereplay [-t start] [-x rate] [recording]");
	hasstart := 0;
	start := 0.0;
	rate := 1.0;
	while((c := arg->opt()) != 0)
		case c {
		't' =>
			start = real arg->earg();
			hasstart = 1;
		'x' =>
			rate = real arg->earg();
			if(rate < 0.0)
				arg->usage();
		* =>
			arg->usage();
		}
	argv = arg->argv();
	if(len argv > 1)
		arg->usage();

	f: ref Iobuf;
	if(argv == nil)
		f = bufio->fopen(sys->fildes(0), Bufio->OREAD);
	else
		f = bufio->open(hd argv, Bufio->OREAD);
	if(f == nil)
		fail(sys->sprint("cannot open recording: %r"));

	# Up to start, the records only build the scene that is shown first.
	m := Model.new();
	pending: ref Tick;	# the first tick after start, read but not yet applied
	for(;;) {
		(tk, eof) := readtick(f);
		if(tk != nil && tk.t != Inf && !hasstart) {
			start = tk.t;
			hasstart = 1;
		}
		if(tk != nil && tk.t != Inf && tk.t > start) {
			pending = tk;
			break;
		}
		if(tk != nil)
			apply(m, tk.text);
		if(eof)
			break;
	}
	put(m.dump());

	# Then each tick at its time.  The clock is anchored at the start
	# and again wherever it runs backwards (a new run after a clear).
	t0 := start;
	w0 := sys->millisec();
	while(pending != nil) {
		if(pending.t < t0) {
			t0 = pending.t;
			w0 = sys->millisec();
		}
		if(rate > 0.0) {
			d := w0 + int ((pending.t - t0) * 1000.0 / rate) - sys->millisec();
			if(d > 0)
				sys->sleep(d);
		}
		put(pending.text);
		(pending, nil) = readtick(f);
	}
}

Inf: con 1e308;	# a tick with no time record: the preamble

# Read one tick: a time record and what follows it, up to the next time
# record (which is left unread) or the end.  eof is set at the end.
held: string;
readtick(f: ref Iobuf): (ref Tick, int)
{
	tk: ref Tick;
	if(held != nil) {
		tk = ref Tick(timeof(held), held + "\n");
		held = nil;
	}
	for(;;) {
		s := f.gets('\n');
		if(s == nil)
			return (tk, 1);
		if(s[len s - 1] == '\n')
			s = s[0:len s - 1];
		if(s == "")
			continue;
		if(istime(s)) {
			if(tk != nil) {
				held = s;
				return (tk, 0);
			}
			tk = ref Tick(timeof(s), s + "\n");
			continue;
		}
		if(tk == nil)
			tk = ref Tick(Inf, "");
		tk.text += s + "\n";
	}
}

istime(s: string): int
{
	return len s > 5 && s[0:5] == "time ";
}

timeof(s: string): real
{
	return real s[5:];
}

apply(m: ref Model, text: string)
{
	(nil, lines) := sys->tokenize(text, "\n");
	for(; lines != nil; lines = tl lines)
		if((err := m.apply(hd lines)) != nil)
			fail("bad record: " + err + ": " + hd lines);
}

put(s: string)
{
	b := array of byte s;
	if(len b > 0 && sys->write(stdout, b, len b) != len b)
		fail(sys->sprint("write: %r"));
}

fail(s: string)
{
	sys->fprint(stderr, "scenereplay: %s\n", s);
	raise "fail:" + s;
}
