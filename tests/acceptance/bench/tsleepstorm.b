implement Tsleepstorm;

# Exposure for #681: many Dis threads, each blocking in sys->sleep(ms) over
# and over. Every sleep is a kproc calling tsleep(), which takes talarm.l
# with lock() at ordinary priority and interrupts on -- the preemptible side
# of the race whose other side is usbdwc's chanwait() spinning at splhi.
#   tsleepstorm nthreads ms seconds

include "sys.m";
	sys: Sys;
include "draw.m";

Tsleepstorm: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	n := 32; ms := 1; secs := 600;
	argv = tl argv;
	if(argv != nil){ n = int hd argv; argv = tl argv; }
	if(argv != nil){ ms = int hd argv; argv = tl argv; }
	if(argv != nil){ secs = int hd argv; }
	done := chan of int;
	for(i := 0; i < n; i++)
		spawn sleeper(ms, secs, done);
	total := 0;
	for(i = 0; i < n; i++)
		total += <-done;
	sys->print("tsleepstorm: %d threads, %d sleeps of %d ms in %d s\n", n, total, ms, secs);
}

sleeper(ms, secs: int, done: chan of int)
{
	end := sys->millisec() + secs*1000;
	k := 0;
	while(sys->millisec() < end){
		sys->sleep(ms);
		k++;
	}
	done <-= k;
}
