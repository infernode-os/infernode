implement Gefs;

#
# gefs -- 9front's GEFS, "a good enough file system", in Limbo: a
# crash-safe, corruption-detecting, snapshotting disk file system on a
# forest of copy-on-write Bε trees, by Ori Bernstein (MIT licence; see
# the design in 9front's sys/doc/gefs.ms). The disk format is 9front's,
# byte for byte, so a disk made by either is read by the other.
#
#	disk/gefs [-r user] [-cRSAd] [-m cachemb] dev
#
# serves the file system on fd 0, as kfs does:
#
#	mount -c {disk/gefs '#S/nvme0p3'} /n/gefs
#
# -r user	ream (make) a new file system on dev, owned by user, and exit
# -c		check the file system and exit
# -R		read only
# -S		permissive: anyone may attach to adm
# -m mb		block cache size in megabytes (default 64)
#
# The attach name picks a snapshot label: "main" (the default), "adm"
# (the users file and ctl), "dump" (every snapshot, read only). The
# file /adm/ctl takes 9front's commands: sync, halt, check, users,
# snap old new, fork old new, delsnap name, retain snap spec...
#
# What differs from 9front, and why, is said where it differs: one
# serving loop instead of reader, mutator, syncer and sweeper procs
# (blk.b, fs.b); no authentication, as kfs has none, the user being
# named at attach; and a device flush at each commit barrier (devflush).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "daytime.m";
	daytime: Daytime;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

Gefs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

include "dat.b";
include "error.b";
include "hash.b";
include "pack.b";
include "tree.b";
include "blk.b";
include "snap.b";
include "user.b";
include "load.b";
include "fs.b";
include "check.b";

Fs: adt {
	blksz:	int;
	bufspc:	int;
	snap:	ref Tree;
	snapdl:	ref Dlist;	# on disk
	dropdl:	ref Dlist;	# in memory
	narena:	int;
	flag:	big;
	nextqid: big;
	nextgen: big;
	qgen:	big;
	arenabp: array of Bptr;
	sb0:	ref Blk;
	sb1:	ref Blk;
	arenas:	array of ref Arena;
	roundrobin: int;
	fd:	ref Sys->FD;
	dev:	string;
	rdonly:	int;
	users:	array of ref User;
	mounts:	list of ref Mount;
	snapmnt: ref Mount;
	# deadlist cache
	dlcache: array of ref Dlist;
	dlhead:	ref Dlist;
	dltail:	ref Dlist;
	dlcount: int;
	dlcmax:	int;
	# block cache
	bcache:	array of ref Blk;
	chead:	ref Blk;
	ctail:	ref Blk;
	ccount:	int;
	cmax:	int;
	# frees waiting for the end of the request
	pending: ref Pend;
	nread:	int;
	nwritten: int;
	ctl:	ref Sys->FD;	# the device's ctl, for flushes
};

fs: ref Fs;
debug := 0;
permissive := 0;
usereserve := 0;
reamuser := "glenda";
noneid := 0;
nogroupid := -2;
admid := -1;
srvfd: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	daytime = load Daytime Daytime->PATH;
	styx = load Styx Styx->PATH;
	arg := load Arg Arg->PATH;
	if(daytime == nil || styx == nil || arg == nil){
		sys->fprint(sys->fildes(2), "gefs: cannot load a module: %r\n");
		raise "fail:load";
	}
	styx->init();
	ream := 0;
	checkonly := 0;
	rdonly := 0;
	cachemb := 64;
	arg->init(argv);
	arg->setusage("disk/gefs [-r user] [-cRSd] [-m cachemb] dev");
	while((c := arg->opt()) != 0)
		case c {
		'r' =>
			ream = 1;
			reamuser = arg->earg();
		'c' =>	checkonly = 1;
		'R' =>	rdonly = 1;
		'S' =>	permissive = 1;
		'A' =>	;	# no authentication either way
		'd' =>	debug++;
		'm' =>	cachemb = int arg->earg();
		* =>	arg->usage();
		}
	argv = arg->argv();
	if(len argv != 1)
		arg->usage();
	dev := hd argv;
	initfs(cachemb, rdonly, dev);
	{
		if(ream){
			reamfs(dev);
			return;
		}
		loadfs(dev);
		if(checkonly){
			if(!checkfs())
				raise "fail:check";
			return;
		}
		if(!fs.rdonly){
			migrateusers();
			syncfs();
		}
	} exception e {
	"gefs:*" =>
		sys->fprint(sys->fildes(2), "gefs: %s\n", errmsg(e));
		raise "fail:"+errmsg(e);
	}
	srvfd = sys->fildes(0);
	serve();
}

initfs(cachemb, rdonly: int, dev: string)
{
	fs = ref Fs;
	fs.snap = ref Tree;
	fs.snap.bp = Zb();
	fs.snapdl = ref Dlist;
	fs.snapdl.gen = big -1;
	fs.snapdl.head = Zb();
	fs.snapdl.tail = Zb();
	fs.dropdl = ref Dlist;
	fs.dropdl.gen = big -1;
	fs.dropdl.head = Zb();
	fs.dropdl.tail = Zb();
	fs.rdonly = rdonly;
	fs.dev = dev;
	fs.cmax = cachemb*1024*1024/Blksz;
	if(fs.cmax < 64)
		fs.cmax = 64;
	fs.bcache = array[fs.cmax] of ref Blk;
	fs.dlcmax = fs.cmax/10;
	if(fs.dlcmax < 4)
		fs.dlcmax = 4;
	if(fs.dlcmax > 512)
		fs.dlcmax = 512;
	fs.dlcache = array[fs.dlcmax] of ref Dlist;
	# a disk under #S has a ctl that can flush its write cache
	if(len dev > 3 && dev[0:3] == "#S/")
		fs.ctl = sys->open("#S/sdctl", Sys->OWRITE);
}

#
# The commit barriers: what was written must be on the medium, not in a
# drive's cache. A disk that has nothing to flush (an SD card, a file)
# has nothing to say, and that is not an error.
#
devflush()
{
	if(fs.ctl != nil)
		sys->fprint(fs.ctl, "flush");
}

# the adm tree's ctl and status, on a disk made before they were there
migrateusers()
{
	mnt := getmount("adm");
	m: list of Msg;
	(ok, nil, nil) := walk1(mnt.root, big Qadmroot, "ctl");
	if(!ok){
		x := dir2kv(big Qadmroot, fillxdir(Qctl, "ctl", Sys->QTFILE, 8r664, big 0));
		m = Msg(Oinsert, x.k, x.v) :: m;
	}
	(ok, nil, nil) = walk1(mnt.root, big Qadmroot, "status");
	if(!ok){
		x := dir2kv(big Qadmroot, fillxdir(Qstatus, "status", Sys->QTFILE, 8r664, big 0));
		m = Msg(Oinsert, x.k, x.v) :: m;
	}
	if(m != nil){
		upsert(mnt, l2a(m));
		fs.snap.dirty = 1;
		syncfs();
	}
	clunkmount(mnt);
}

reader(c: chan of ref Tmsg)
{
	for(;;){
		t := Tmsg.read(srvfd, Max9p + Styx->IOHDRSZ);
		c <-= t;
		if(t == nil)
			return;
		pick m := t {
		Readerror =>
			return;
		}
	}
}

ticker(c: chan of int)
{
	for(;;){
		sys->sleep(5000);
		c <-= 1;
	}
}

serve()
{
	tc := chan of ref Tmsg;
	tk := chan of int;
	spawn reader(tc);
	spawn ticker(tk);
	while(!halting){
		alt{
		t := <-tc =>
			if(t == nil)
				halting = 1;
			else{
				pick m := t {
				Readerror =>
					sys->fprint(sys->fildes(2), "gefs: %s\n", m.error);
					halting = 1;
				* =>
					request(t);
				}
			}
		<-tk =>
			{
				tick();
			} exception e {
			"gefs:*" =>
				sys->fprint(sys->fildes(2), "gefs: sync: %s\n", errmsg(e));
			}
		}
	}
	# the last commits, so the disk is clean
	{
		if(!fs.rdonly)
			drainsync();
	} exception e {
	"gefs:*" =>
		sys->fprint(sys->fildes(2), "gefs: halt: %s\n", errmsg(e));
	}
}
