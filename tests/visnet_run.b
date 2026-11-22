implement VisnetRun;

#
# visnet_run: a model on pictures, through appl/lib/visnet.b and $Tensor,
# printing what refdetect.py prints, for tests/host/visnet_test.sh.
#
#	visnet_run [-t thresh] [-n reps] modeldir picture ...
#
# One record a line, best first, then with -n a line of times:
#	class=dog score=0.9123 x0=123.4 y0=... x1=... y1=...
#	time reps=10 ms=118.2
#
# With -p as well, after the times, where the reps spent theirs, a line
# a kind of operation (visnet's profile):
#	kind="conv 3x3" n=180 us=812345 pct=41.2
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "visnet.m";
	visnet: Visnet;
	Net, Det: import visnet;

VisnetRun: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr := sys->fildes(2);
	visnet = load Visnet Visnet->PATH;
	if(visnet == nil){
		sys->fprint(stderr, "visnet_run: cannot load visnet: %r\n");
		raise "fail:load";
	}
	err := visnet->init();
	if(err != nil){
		sys->fprint(stderr, "visnet_run: %s\n", err);
		raise "fail:init";
	}
	thresh := 0.3;
	reps := 0;
	prof := 0;
	argv = tl argv;
	while(argv != nil && len hd argv > 1 && (hd argv)[0] == '-'){
		case hd argv {
		"-t" =>
			argv = tl argv;
			thresh = real hd argv;
		"-n" =>
			argv = tl argv;
			reps = int hd argv;
		"-p" =>
			prof = 1;
		* =>
			sys->fprint(stderr, "usage: visnet_run [-p] [-t thresh] [-n reps] modeldir picture ...\n");
			raise "fail:usage";
		}
		argv = tl argv;
	}
	if(len argv < 2){
		sys->fprint(stderr, "usage: visnet_run [-p] [-t thresh] [-n reps] modeldir picture ...\n");
		raise "fail:usage";
	}
	t0 := sys->millisec();
	(n, nerr) := Net.open(hd argv);
	if(n == nil){
		sys->fprint(stderr, "visnet_run: %s\n", nerr);
		raise "fail:model";
	}
	sys->fprint(stderr, "visnet_run: %s opened in %d ms\n", hd argv, sys->millisec() - t0);
	for(argv = tl argv; argv != nil; argv = tl argv){
		(pix, w, h, perr) := visnet->readpixels(hd argv);
		if(pix == nil){
			sys->fprint(stderr, "visnet_run: %s\n", perr);
			raise "fail:picture";
		}
		(dets, derr) := n.detect(pix, w, h, thresh, 0.45);
		if(derr != nil){
			sys->fprint(stderr, "visnet_run: %s: %s\n", hd argv, derr);
			raise "fail:detect";
		}
		for(i := 0; i < len dets; i++){
			d := dets[i];
			sys->print("class=%s score=%.4f x0=%.1f y0=%.1f x1=%.1f y1=%.1f\n",
				n.classes[d.class], d.score, d.x0, d.y0, d.x1, d.y1);
		}
		if(reps > 0){
			t0 = sys->millisec();
			for(r := 0; r < reps; r++)
				n.detect(pix, w, h, thresh, 0.45);
			sys->print("time reps=%d ms=%.1f\n", reps, real (sys->millisec() - t0) / real reps);
			if(prof){
				visnet->profile(1);
				for(r = 0; r < reps; r++)
					n.detect(pix, w, h, thresh, 0.45);
				sys->print("%s", visnet->profiled());
				visnet->profile(0);
			}
		}
	}
}
