implement Post;

#
# post - a directory of this name space, posted for any other to mount
#
#	post spec dir
#
# posts #s<spec>/fs (post9p(2)), refusing a spec whose fs is taken;
# each open of it is a connection of its
# own, served by exporting dir as this name space has it (sys-export(2)).
# So a server mounted here can be mounted from any Dis VM (vm(1)), or by
# any process of the user whatever its name space, with no option of
# its own for it:
#
#	mount {vid9p clip.y4m} /mnt/video
#	post video /mnt/video
#	vm 2 sh -c 'mount -A ''#svideo/fs'' /mnt/video; ...'
#
# It runs until killed, in a process group of its own (kill -g with its
# pid). The connections pass through it (#s relays them, as it does for
# every posted server), so killing it ends them too.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "post9p.m";
	post9p: Post9p;

Post: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr := sys->fildes(2);
	args = tl args;
	if(len args != 2){
		sys->fprint(stderr, "usage: post spec dir\n");
		raise "fail:usage";
	}
	(spec, dir) := (hd args, hd tl args);
	(ok, d) := sys->stat(dir);
	if(ok < 0){
		sys->fprint(stderr, "post: %s: %r\n", dir);
		raise "fail:dir";
	}
	if((d.mode & Sys->DMDIR) == 0){
		sys->fprint(stderr, "post: %s: not a directory\n", dir);
		raise "fail:dir";
	}
	post9p = load Post9p Post9p->PATH;
	if(post9p == nil){
		sys->fprint(stderr, "post: cannot load post9p: %r\n");
		raise "fail:load";
	}
	post9p->init();
	sys->pctl(Sys->NEWPGRP, nil);
	conns := chan of ref Sys->FD;
	# exactly #s<spec>/fs: one already there is another's, refused
	(p, e) := post9p->postas(spec, "fs", conns);
	if(p == nil){
		sys->fprint(stderr, "post: #s%s: %s\n", spec, e);
		raise "fail:post";
	}
	for(;;){
		fd := <-conns;
		if(sys->export(fd, dir, Sys->EXPASYNC) < 0)
			sys->fprint(stderr, "post: export %s: %r\n", dir);
	}
}
