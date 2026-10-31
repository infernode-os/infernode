implement Procstorm;

#
# procstorm - block N Limbo threads in sys->sleep at once, so the
# kernel's Proc table holds N+ concurrent kprocs.
#
# Sys_sleep (os/port/inferno.c) calls release() before tsleep(): a
# genuine kernel block, which os/port/dis.c's release() answers by
# spawning a new "dis" kproc whenever the VM's ready queues are both
# empty. N threads asleep at once is N kprocs held, which is how the
# board exhausted conf.nproc=100 under a handful of GUI apps and their
# readers. This is the harness's way of proving the raised limit
# without waiting for 1000 kprocs to build up.
#
# Usage: procstorm N
#   spawns N threads, each sys->sleep(2000), waits for all N to report
#   back over a channel, then prints "PROCSTORM-OK N" and exits.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Procstorm: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	if(args == nil){
		sys->fprint(sys->fildes(2), "usage: procstorm N\n");
		raise "fail:usage";
	}
	n := int hd args;
	if(n <= 0){
		sys->fprint(sys->fildes(2), "procstorm: N must be positive\n");
		raise "fail:usage";
	}

	done := chan of int;
	for(i := 0; i < n; i++)
		spawn sleeper(i, done);

	got := 0;
	for(i = 0; i < n; i++){
		<-done;
		got++;
	}
	sys->print("PROCSTORM-OK %d\n", got);
}

sleeper(nil: int, done: chan of int)
{
	sys->sleep(2000);
	done <-= 1;
}
