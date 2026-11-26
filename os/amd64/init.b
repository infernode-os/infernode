implement Init;

#
# The kernel's init: the first Limbo program a shell boot runs.
#
# disinit() loads this module and schedules it before anything else.
# Its whole job is to make the console reachable by the name sh looks
# for -- /dev/cons -- and then hand over to /dis/sh.dis.
#
# There is no exec(2) in Inferno: a command IS a Dis module, so running
# the shell means loading it and calling its init().  That call does not
# return while the shell is running.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "sh.m";

Init: module
{
	init:	fn();
};

init()
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return;

	#
	# The console.  disinit already opened #c/cons three times for
	# fd 0/1/2, but sh decides whether it is on a terminal by
	# comparing fstat(fd 0) with stat("/dev/cons"), so the device has
	# to be in the namespace under that name.  The root image carries
	# an empty /dev; MREPL puts #c there.
	#
	if(sys->bind("#c", "/dev", Sys->MREPL|Sys->MCREATE) < 0)
		sys->print("init: bind #c /dev: %r\n");

	#
	# /prog.  sh opens /prog/<pid>/wait to reap the commands it starts;
	# without it the first command fails with "process filesystem not
	# available", and the shell retries and retries.  The root image
	# carries an empty /prog.
	#
	if(sys->bind("#p", "/prog", Sys->MREPL) < 0)
		sys->print("init: bind #p /prog: %r\n");

	#
	# The network.  No interface is configured here; #I is present so
	# that a shell (or a program) can bind loopback or a real medium
	# with the tools it has.  The root image carries an empty /net.
	#
	if(sys->bind("#I", "/net", Sys->MREPL) < 0)
		sys->print("init: bind #I /net: %r\n");
	if(sys->bind("#l", "/net", Sys->MAFTER) < 0)
		sys->print("init: bind #l /net: %r\n");

	#
	# The host's namespace channel, when the loader offers one.  This
	# is a 9P file server reached through #~, not a network device --
	# the point of the ring transport.  QEMU has no ring, and 9vm
	# publishes #~/ns only when it was given a server to relay to, so
	# a loader without one is not an error.
	#
	ns := sys->open("#~/ns", Sys->ORDWR);
	if(ns == nil)
		sys->print("init: no #~ namespace to mount\n");
	else if(sys->mount(ns, nil, "/n/remote", Sys->MREPL, "") < 0)
		sys->print("init: mount #~/ns /n/remote: %r\n");
	else
		sys->print("init: #~/ns mounted at /n/remote\n");

	sys->print("\ninit: the root image is up\n");
	sys->print("init: starting the shell\n\n");

	sh := load Command Command->PATH;
	if(sh == nil){
		sys->print("init: cannot load %s: %r\n", Command->PATH);
		return;
	}
	sh->init(nil, "sh" :: "-l" :: nil);

	sys->print("init: the shell returned\n");
}
