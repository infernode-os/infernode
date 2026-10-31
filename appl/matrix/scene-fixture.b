implement SceneFixture;

#
# scene-fixture — a Matrix service that brings up a demo scene.
#
# init() mounts a scenefs at its mount point (unless one is already
# there) and readies scenedemo, the synthetic field survey; run() lets
# it go and waits for shutdown.  scenedemo is a separate program that
# loads modules from /dis as it runs, which run()'s confined namespace
# (the mount alone) does not have, so its process is created in
# init() and only released by run(); it writes nothing but the scene.
# A scene that is already served is left to whoever serves it.
# Composition usage:
#
#	service scene-fixture /mnt/scene
#
# A real composition mounts its own scene and runs its own producer;
# this exists so /lib/matrix/compositions/scene-demo works from the
# picker with nothing else running.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "sh.m";
include "matrix.m";

SceneFixture: module
{
	init:	fn(mount: string, outdir: string): string;
	run:	fn();
	shutdown:	fn();
};

scene: string;
democmd: Command;
pid := -1;
stop: chan of int;
start: chan of int;
ended: chan of int;

init(mount: string, nil: string): string
{
	sys = load Sys Sys->PATH;
	scene = mount;
	stop = chan[1] of int;
	start = chan[1] of int;
	ended = chan of int;
	# a scene someone else serves is theirs to drive: leave it be
	(ok, nil) := sys->stat(scene + "/status");
	if(ok >= 0)
		return nil;
	democmd = load Command "/dis/scenedemo.dis";
	if(democmd == nil)
		return sys->sprint("scene-fixture: cannot load scenedemo: %r");
	pidc := chan of int;
	spawn demo(pidc);
	pid = <-pidc;
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return sys->sprint("scene-fixture: pipe: %r");
	sync := chan of int;
	spawn serve(fds[1], sync);
	<-sync;
	fds[1] = nil;
	(ok, nil) = sys->stat(scene);
	if(ok < 0)
		sys->create(scene, Sys->OREAD, Sys->DMDIR|8r775);
	if(sys->mount(fds[0], nil, scene, Sys->MREPL, nil) < 0)
		return sys->sprint("scene-fixture: mount %s: %r", scene);
	return nil;
}

serve(fd: ref Sys->FD, sync: chan of int)
{
	sys->pctl(Sys->NEWFD, fd.fd :: 2 :: nil);
	sys->dup(fd.fd, 0);
	fd = nil;
	sync <-= 1;
	cmd := load Command "/dis/scenefs.dis";
	if(cmd != nil)
		cmd->init(nil, "scenefs" :: nil);
}

run()
{
	if(pid >= 0)
		start <-= 1;
	alt {
	<-ended =>	;	# the demo ended by itself
	<-stop =>	;
	}
}

demo(pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	<-start;
	{
		democmd->init(nil, "scenedemo" :: "-d" :: "200" :: scene :: nil);
	} exception {
	* =>	;
	}
	alt {
	ended <-= 0 =>	;
	* =>	;
	}
}

shutdown()
{
	if(pid >= 0) {
		fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "kill");
		pid = -1;
	}
	alt {
	stop <-= 1 =>	;
	* =>	;
	}
}
