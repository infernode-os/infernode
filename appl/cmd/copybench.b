implement Copybench;

#
# copybench - how fast the system copies memory, as Limbo sees it
#
#	copybench [-t ms]
#
# Copies arrays of bytes with slice assignment (a[i:] = b[j:k]), which
# the Dis VM does with the system's memmove: the host's in an emulator,
# libkern's on the native kernels. For each size, source and
# destination aligned alike and three bytes apart; one line each:
#
#	size=65536 skew=0 reps=4000 mbs=5123.4
#
# mbs is megabytes copied a second. -t is the time spent on each line
# (default 500 ms).
#

include "sys.m";
	sys: Sys;
include "draw.m";

Copybench: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

sizes := array[] of {64, 1024, 16*1024, 256*1024, 4*1024*1024, 64*1024*1024};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	budget := 500;
	argv = tl argv;
	if(argv != nil && hd argv == "-t" && tl argv != nil){
		budget = int hd tl argv;
		argv = tl tl argv;
	}
	if(argv != nil || budget <= 0){
		sys->fprint(sys->fildes(2), "usage: copybench [-t ms]\n");
		raise "fail:usage";
	}
	for(i := 0; i < len sizes; i++){
		n := sizes[i];
		src := array[n+8] of { * => byte 16r5A };
		dst := array[n+8] of byte;
		for(skew := 0; skew <= 3; skew += 3){
			# size the run with a few copies, then time the rest
			reps := 1;
			for(;;){
				t0 := sys->millisec();
				copies(dst, src, n, skew, reps);
				ms := sys->millisec() - t0;
				if(ms >= budget/4 || reps >= 1<<24){
					if(ms < 1)
						ms = 1;
					reps = reps * budget / ms + 1;
					break;
				}
				reps *= 4;
			}
			t0 := sys->millisec();
			copies(dst, src, n, skew, reps);
			ms := sys->millisec() - t0;
			if(ms < 1)
				ms = 1;
			mbs := real n * real reps / (real ms * 1000.0);
			sys->print("size=%d skew=%d reps=%d mbs=%.1f\n", n, skew, reps, mbs);
		}
		src = nil;
		dst = nil;
	}
}

copies(dst, src: array of byte, n, skew, reps: int)
{
	for(r := 0; r < reps; r++)
		dst[0:] = src[skew:skew+n];
}
