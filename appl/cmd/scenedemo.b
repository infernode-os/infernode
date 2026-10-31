implement Scenedemo;

#
# scenedemo — drive a scene with a synthetic field survey.
#
#	scenedemo [-n ticks] [-d ms] [-s seed] [scene]
#
# Writes records (docs/scene-design.md §3.2) to <scene>/log (default
# /mnt/scene): six survey rovers mowing lanes across a 2 km plot, a
# relay that shadows the far lanes, a base with its radio range.  A
# rover out of radio reach is shown by its last report, dimmed — what
# the base knows, not where the rover is.  One tick is one second of
# scene time; -d is the wall-clock delay between ticks (0: as fast as
# possible), -n stops after that many ticks (default: forever).
#
# It is a demo and a test load; any program that writes the same
# records is a producer.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "math.m";
	math: Math;
include "arg.m";

Scenedemo: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

W: con 2000.0;		# plot size, m
BASEX: con 1000.0;
BASEY: con -150.0;
RADIO: con 1100.0;	# base radio range, m
RELAYR: con 700.0;	# relay radio range, m
SPEED: con 20.0;		# m/s
LANE: con 80.0;		# lane spacing, m
NROV: con 6;

Rover: adt {
	id:	string;
	x, y:	real;
	lx0, lx1: real;	# the strip this rover mows
	lane:	int;
	dir:	int;	# +1 north, -1 south
	lastx, lasty, lastt: real;	# last report the base has
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	math = load Math Math->PATH;
	arg := load Arg Arg->PATH;
	arg->init(argv);
	arg->setusage("scenedemo [-n ticks] [-d ms] [scene]");
	nticks := -1;
	delay := 200;
	while((c := arg->opt()) != 0)
		case c {
		'n' =>	nticks = int arg->earg();
		'd' =>	delay = int arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	dir := "/mnt/scene";
	if(argv != nil)
		dir = hd argv;
	fd := sys->open(dir + "/log", Sys->OWRITE);
	if(fd == nil) {
		sys->fprint(sys->fildes(2), "scenedemo: cannot open %s/log: %r\n", dir);
		raise "fail:open";
	}

	strip := W / real NROV;
	rovers := array[NROV] of ref Rover;
	for(i := 0; i < NROV; i++) {
		x0 := real i * strip + LANE / 2.0;
		rovers[i] = ref Rover(sys->sprint("rover%d", i + 1), x0, 0.0,
			x0, real (i + 1) * strip - LANE / 2.0, 0, 1, x0, 0.0, 0.0);
	}

	put(fd, "clear\n" +
		"meta frame=xy units=m 'title=Field survey' trail=120 'bounds=0,-300 2000,2000'\n" +
		"layer grid kind=grid step=250\n" +
		"feat plot type=polygon 'points=0,0 2000,0 2000,2000 0,2000' color=5A6B82FF width=1 label=Plot\n" +
		"feat radio type=circle " + sys->sprint("points=%g,%g radius=%g", BASEX, BASEY, RADIO) +
			" color=3DBE8BFF fill=3DBE8B18 dash=1 'label=Base radio'\n" +
		"feat pond type=polygon 'points=1250,1150 1450,1100 1550,1300 1400,1450 1230,1350' " +
			"color=4EA8DEFF fill=4EA8DE40 label=Pond\n" +
		sys->sprint("ent base x=%g y=%g shape=square color=E6EAF0FF size=7 label=Base\n", BASEX, BASEY));

	for(t := 0; nticks < 0 || t < nticks; t++) {
		s := sys->sprint("time %d\n", t);
		# the relay shadows the survey's northern front
		ry := 0.0;
		for(i = 0; i < NROV; i++)
			ry += rovers[i].y;
		ry = ry / real NROV + 300.0;
		if(ry > 1700.0)
			ry = 1700.0;
		rx := BASEX + 300.0 * math->sin(real t / 60.0);
		relayok := dist(rx, ry, BASEX, BASEY) <= RADIO;
		s += sys->sprint("ent relay x=%.1f y=%.1f shape=diamond group=orange label=Relay trail=0\n", rx, ry);
		for(i = 0; i < NROV; i++) {
			r := rovers[i];
			step(r);
			heard := dist(r.x, r.y, BASEX, BASEY) <= RADIO ||
				relayok && dist(r.x, r.y, rx, ry) <= RELAYR;
			if(heard) {
				r.lastx = r.x; r.lasty = r.y; r.lastt = real t;
			}
			course := 0;
			if(r.dir < 0)
				course = 180;
			stale := "";
			if(!heard)
				stale = sys->sprint(" stale=%d", int r.lastt);
			s += sys->sprint("ent %s x=%.1f y=%.1f shape=triangle group=blue course=%d label=%s%s\n",
				r.id, r.lastx, r.lasty, course, r.id, stale);
		}
		put(fd, s);
		if(delay > 0)
			sys->sleep(delay);
	}
}

# Mow: run the lane north or south, then shift one lane over.
step(r: ref Rover)
{
	r.y += real r.dir * SPEED;
	if(r.y > W || r.y < 0.0) {
		if(r.y > W) r.y = W;
		if(r.y < 0.0) r.y = 0.0;
		r.dir = -r.dir;
		r.lane++;
		r.x = r.lx0 + real r.lane * LANE;
		if(r.x > r.lx1) {	# strip done: start over
			r.lane = 0;
			r.x = r.lx0;
		}
	}
}

dist(x0, y0, x1, y1: real): real
{
	return math->sqrt((x1-x0)*(x1-x0) + (y1-y0)*(y1-y0));
}

put(fd: ref Sys->FD, s: string)
{
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b) {
		sys->fprint(sys->fildes(2), "scenedemo: write: %r\n");
		raise "fail:write";
	}
}
