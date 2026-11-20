implement MntUnexpected;

#
# The mount driver's report of a reply nobody is waiting for
# (mountmux in devmnt.c, both kernels), run by
# tests/host/mnt_unexpected_test.sh in an emulator of its own: the
# report is a line on the console, and only the first eight are made.
#
# A 9P server on a pipe sends, before each answer to a stat, an Rerror
# with a tag nobody waits for, its text naming the stat it came before,
# and at once another as long with other bytes in it (two for each of
# four stats: the eight reports).  The driver freed the reply's Block and then
# printed the error string that lies in it: the console had whatever
# message was given the Block next.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

MntUnexpected: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

NSTAT: con 4;
FILL: con 150;

nstat := 0;

rootdir(): Sys->Dir
{
	d := sys->zerodir;
	d.name = "/";
	d.uid = "none";
	d.gid = "none";
	d.muid = "none";
	d.qid = Sys->Qid(big 1, 0, Sys->QTDIR);
	d.mode = Sys->DMDIR | 8r555;
	return d;
}

# what the Rerror before stat n says: FILL bytes
text(n: int): string
{
	s := sys->sprint("stat-%d-", n);
	c := 'a' + n;
	while(len s < FILL)
		s[len s] = c;
	return s;
}

server(fd: ref Sys->FD)
{
	for(;;){
		m := Tmsg.read(fd, 8192);
		if(m == nil)
			break;
		r: ref Rmsg;
		pick x := m {
		Readerror =>
			return;
		Version =>
			r = ref Rmsg.Version(x.tag, 8192, "9P2000");
		Attach =>
			r = ref Rmsg.Attach(x.tag, Sys->Qid(big 1, 0, Sys->QTDIR));
		Walk =>
			if(len x.names == 0)
				r = ref Rmsg.Walk(x.tag, nil);
			else
				r = ref Rmsg.Error(x.tag, "not here");
		Stat =>
			# two replies nobody waits for, the second as long
			# as the first with other bytes
			u := (ref Rmsg.Error(x.tag + 1000, text(nstat))).pack();
			z := "";
			while(len z < FILL)
				z[len z] = 'Z';
			w := (ref Rmsg.Error(x.tag + 3000, z)).pack();
			nstat++;
			sys->write(fd, u, len u);
			sys->write(fd, w, len w);
			r = ref Rmsg.Stat(x.tag, rootdir());
		Clunk =>
			r = ref Rmsg.Clunk(x.tag);
		Flush =>
			r = ref Rmsg.Flush(x.tag);
		* =>
			r = ref Rmsg.Error(x.tag, "not served");
		}
		b := r.pack();
		if(sys->write(fd, b, len b) != len b)
			break;
	}
}

init(nil: ref Draw->Context, nil: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styx->init();
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0){
		sys->print("pipe: %r\n");
		return;
	}
	spawn server(p[0]);
	p[0] = nil;
	if(sys->mount(p[1], nil, "/n/client", Sys->MREPL, nil) < 0){
		sys->print("mount: %r\n");
		return;
	}
	for(i := 0; i < NSTAT; i++){
		(ok, d) := sys->stat("/n/client");
		sys->print("STAT %d %d %s WANT %s\n", i, ok, d.name, text(i));
	}
	sys->unmount(nil, "/n/client");
	sys->print("DONE\n");
}
