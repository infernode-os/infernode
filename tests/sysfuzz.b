implement Sysfuzz;

#
# sysfuzz - random system calls from many Progs at once, killed at random,
# to grind the C under them: name spaces, channels and devices (#c #p #d
# #e #s #|), the mount driver against a server that lies and the export
# server behind a mount, file2chan servers that misbehave, pipes, and the
# debugger's files. tools/sysfuzz runs it, under emu or the sanitizers'
# emu (tools/sanemu), and watches for what goes wrong.
#
#	sysfuzz [-s seed] [-p procs] [-t secs] [-e epochsecs] [-x ops] [-v]
#
# It makes its own name space first: a fresh root (#/), the devices
# above, and a scratch directory of the host's at /nvfs (#U, under
# $ROOT/tmp/sysfuzz/<seed>), then pctl(NODEVS), so nothing it does can
# reach the rest of the host's files. It never writes /dev/sysctl (halt),
# /dev/user or /dev/hostowner (the driver's halt is then refused), or the
# host's own stdin, stdout and opener, and writes the ctl, dbgctl
# and heap files only of Progs it made.
#
# Each epoch, procs workers run random operations, spawn more, and kill
# each other; at its end all of them are killed (killgrp) and the next
# starts. A line "hb <secs> <ops>" each second shows it alive; at the end,
# with everything killed, it checks the kernel still answers (a file
# made, written, read back and removed; a pipe; a spawn) and prints
# "sysfuzz: done" or "sysfuzz: wedged". Operations failing is expected;
# the kernel failing, faulting or wedging is what is looked for.
#

include "sys.m";
	sys: Sys;
	FD, Dir: import sys;

include "draw.m";

Sysfuzz: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Rng: adt {
	s:	big;
	n:	fn(r: self ref Rng, m: int): int;
	c:	fn(r: self ref Rng, p: int): int;	# p percent
};

Rng.n(r: self ref Rng, m: int): int
{
	r.s = r.s * big 6364136223846793005 + big 1442695040888963407;
	v := int ((r.s >> 33) & big 16r7fffffff);
	if(m <= 0)
		return 0;
	return v % m;
}

Rng.c(r: self ref Rng, p: int): int
{
	return r.n(100) < p;
}

seed := 1;
nprocs := 8;
secs := 20;
epochsecs := 4;
verbose := 0;
skip := array[30] of {* => 0};	# operations left out (-x), to find which a failure needs
ctls := array[] of {"kill", "killgrp", "stop", "start", "exceptions propagate", "restricted", "maxmem 1000"};

ops := 0;		# all workers' operations (a racy count; only for the heartbeat)
scratch := "";
scratchdir := "";	# -d: where scratch is made when there is no #U (the native kernel)
mine: list of int;	# pids this run made
nmine := 0;
epochpids: list of int;	# this epoch's: its group, whoever of it is left

# paths to aim at; refreshed each epoch by walking the name space
paths: array of string;

WORDS := array[] of {
	"kill", "killgrp", "start", "stop", "step", "toret", "cont", "unstop",
	"exceptions propagate", "exceptions notifyleader", "restricted",
	"private", "bpt set 1 2", "bpt del 1 2", "maxmem 100000", "rawon",
	"rawoff", "holdon", "holdoff", "0", "1", "-1", "99999999999", "",
	"/", "..", "é\U0001F680", "pri 7", "fixedpri", "unknown command",
};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	args = tl args;
	while(args != nil){
		a := hd args;
		args = tl args;
		v := 0;
		if(args != nil)
			v = int hd args;
		case a {
		"-s" =>	seed = v; args = tl args;
		"-p" =>	nprocs = v; args = tl args;
		"-t" =>	secs = v; args = tl args;
		"-e" =>	epochsecs = v; args = tl args;
		"-v" =>	verbose = 1;
		"-d" =>	scratchdir = hd args; args = tl args;
		"-K" =>
			# -K kill,stop: only these written to a Prog's ctl
			(nil, kl) := sys->tokenize(hd args, ",");
			ctls = array[len kl] of string;
			for(i := 0; kl != nil; kl = tl kl)
				ctls[i++] = hd kl;
			args = tl args;
		"-x" =>
			# -x 24,25,26: leave those operations out
			for(l := sys->tokenize(hd args, ",").t1; l != nil; l = tl l)
				if(int hd l >= 0 && int hd l < len skip)
					skip[int hd l] = 1;
			args = tl args;
		* =>
			sys->fprint(sys->fildes(2), "usage: sysfuzz [-s seed] [-p procs] [-t secs] [-e epochsecs] [-d scratchdir] [-v] [-x ops] [-K ctls]\n");
			raise "fail:usage";
		}
	}
	if(epochsecs < 1)
		epochsecs = 1;
	sys->print("sysfuzz: seed %d procs %d secs %d\n", seed, nprocs, secs);
	# what ends the run, said: in another VM (vm(1)) no shell does
	{
		run();
	} exception e {
	"*" =>
		sys->print("sysfuzz: died: %s\n", e);
		raise e;
	}
}

run()
{
	setup();

	start := sys->millisec();
	epoch := 0;
	hb := chan of int;
	spawn heartbeat(hb, start);
	while(sys->millisec() - start < secs*1000){
		epoch++;
		walk();
		pidc := chan of int;
		go := chan of int;
		spawn epochleader(pidc, go, seed*1000 + epoch);
		lpid := <-pidc;
		# its ctl opened before its workers start: with -d they can
		# rename the root's prog directory, and a kill by name later
		# found nothing, the epoch's Progs left running (nativefuzz)
		lctl := sys->open(sys->sprint("/prog/%d/ctl", lpid), Sys->OWRITE);
		go <-= 1;
		sys->sleep(epochsecs*1000);
		# the whole epoch's group, wherever it got to; through any of it
		# still there if the leader is not (an exception propagated to
		# it, its workers in calls still running: nativefuzz)
		# By a helper, waited for a while: a kill runs the dead Progs'
		# closes in the killer, and one on a server that never answers
		# does not return (docs/NATIVE-FUZZING.md, Open); the helper is
		# left in it and the run goes on
		kdone := chan[1] of int;	# the helper never waits to say it is done
		spawn epochkill(lctl, epochpids, kdone);
		kt := chan of int;
		spawn timer(kt, 3000);
		alt {
		<-kdone =>
			;
		<-kt =>
			if(verbose)
				sys->print("epoch %d: the kill did not return in 3s\n", epoch);
		}
		lctl = nil;
		epochpids = nil;
		sys->sleep(50);
		if(verbose)
			sys->print("epoch %d over\n", epoch);
	}
	hb <-= 1;
	check();
}

heartbeat(stop: chan of int, start: int)
{
	for(;;) alt {
	<-stop =>
		return;
	* =>
		sys->sleep(1000);
		sys->print("hb %d %d\n", (sys->millisec() - start)/1000, ops);
	}
}

# a name space of our own, and nothing of the host's but scratch
setup()
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKNS|Sys->FORKENV, nil);
	top := "/tmp/sysfuzz";
	if(scratchdir != nil)
		top = scratchdir + "/sysfuzz";
	sys->create(top, Sys->OREAD, Sys->DMDIR|8r777);
	scratch = sys->sprint("%s/%d", top, seed);
	sys->create(scratch, Sys->OREAD, Sys->DMDIR|8r777);
	ok := 1;
	if(scratchdir != nil){
		# no #U (the native kernel), and its #/ has neither /nvfs nor
		# /fd: the root is a directory of scratch, with a mount point
		# for each device, and scratch's files are another beside it,
		# each exported from a copy of the name space as it is now
		root := scratch + "/root";
		sys->create(root, Sys->OREAD, Sys->DMDIR|8r777);
		for(d := "dev" :: "prog" :: "fd" :: "env" :: "chan" :: "n" :: "nvfs" :: "tmp" :: nil; d != nil; d = tl d)
			sys->create(root + "/" + hd d, Sys->OREAD, Sys->DMDIR|8r777);
		sys->create(scratch + "/files", Sys->OREAD, Sys->DMDIR|8r777);
		rfd := exportscratch(root);
		vfd := exportscratch(scratch + "/files");
		ok &= rfd != nil && vfd != nil;
		ok &= ok && sys->mount(rfd, nil, "/", Sys->MREPL|Sys->MCREATE, nil) >= 0;
		ok &= ok && sys->mount(vfd, nil, "/nvfs", Sys->MREPL|Sys->MCREATE, nil) >= 0;
	}else{
		ok &= sys->bind("#U"+scratch, "/n", Sys->MREPL|Sys->MCREATE) >= 0;
		ok &= sys->bind("#/", "/", Sys->MREPL) >= 0;
	}
	ok &= sys->bind("#c", "/dev", Sys->MREPL) >= 0;
	ok &= sys->bind("#p", "/prog", Sys->MREPL) >= 0;
	sys->bind("#d", "/fd", Sys->MREPL);	# the native kernel has no #d
	ok &= sys->bind("#e", "/env", Sys->MREPL|Sys->MCREATE) >= 0;
	ok &= sys->bind("#s", "/chan", Sys->MREPL) >= 0;
	# the scratch directory, which the root's #U no longer shows
	if(scratchdir == nil)
		ok &= sys->bind("#U"+scratch, "/nvfs", Sys->MREPL|Sys->MCREATE) >= 0;
	if(!ok){
		sys->print("sysfuzz: cannot build the name space: %r\n");
		raise "fail:setup";
	}
	sys->pctl(Sys->NODEVS, nil);
	(n, nil) := sys->stat("#U/dis");
	if(n >= 0){
		sys->print("sysfuzz: the host's files are still reachable; not running\n");
		raise "fail:setup";
	}
}

exportscratch(dir: string): ref FD
{
	f := array[2] of ref FD;
	if(sys->pipe(f) < 0)
		return nil;
	sync := chan of int;
	spawn scratchexporter(f[0].fd, dir, sync);
	<-sync;
	# the server's end only in the exporter's own fd table: in ours, a
	# worker's dup of a random fd took it, read the requests or wrote
	# junk at the mount, and the run hung on the root it serves
	f[0] = nil;
	return f[1];
}

scratchexporter(fdn: int, dir: string, sync: chan of int)
{
	sys->pctl(Sys->FORKNS|Sys->NEWFD, fdn :: nil);
	fd := sys->fildes(fdn);
	sync <-= 1;
	sys->export(fd, dir, Sys->EXPWAIT);
}

# every path two levels under the trees we have
walk()
{
	l: list of string;
	t := array[] of {"/dev", "/prog", "/fd", "/env", "/chan", "/nvfs", "/"};
	for(i := 0; i < len t; i++){
		l = t[i] :: l;
		for(d := dirs(t[i]); d != nil; d = tl d){
			(p, isdir) := hd d;
			l = p :: l;
			if(isdir && len l < 400)
				for(e := dirs(p); e != nil; e = tl e){
					(q, nil) := hd e;
					l = q :: l;
				}
		}
	}
	l = "/nvfs/a" :: "/nvfs/b/c" :: "/env/fz" :: "/chan/fz" :: "/n/x" :: "" :: "#" :: "#c/../." :: l;
	a := array[len l] of string;
	for(j := 0; l != nil; l = tl l)
		a[j++] = hd l;
	paths = a;
}

# a directory's entries, and which are directories (only those are read:
# a read of /dev/cons or /prog/n/wait waits)
dirs(p: string): list of (string, int)
{
	(ok, dir) := sys->stat(p);
	if(ok < 0 || (dir.mode & Sys->DMDIR) == 0)
		return nil;
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return nil;
	l: list of (string, int);
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n && i < 64; i++){
			q := p + "/" + d[i].name;
			if(p == "/")
				q = "/" + d[i].name;
			l = (q, (d[i].mode & Sys->DMDIR) != 0) :: l;
		}
	}
	return l;
}

epochkill(lctl: ref FD, pids: list of int, done: chan of int)
{
	if(lctl == nil || sys->fprint(lctl, "killgrp") < 0)
		for(; pids != nil; pids = tl pids){
			fd := sys->open(sys->sprint("/prog/%d/ctl", hd pids), Sys->OWRITE);
			if(fd != nil && sys->fprint(fd, "killgrp") >= 0)
				break;
		}
	done <-= 1;
}

epochleader(pidc: chan of int, go: chan of int, s: int)
{
	sys->pctl(Sys->NEWPGRP|Sys->FORKFD|Sys->FORKNS, nil);
	pidc <-= sys->pctl(0, nil);
	<-go;
	for(i := 0; i < nprocs; i++)
		spawn worker(ref Rng(big (s*31 + i)), 0);
	# the leader itself just waits to be killed
	for(;;)
		sys->sleep(1000);
}

Wk: adt {
	r:	ref Rng;
	fds:	array of ref FD;
	kids:	list of int;
	depth:	int;
};

worker(r: ref Rng, depth: int)
{
	# its own copies of the name space and the fd table: what it binds,
	# unmounts and dups over is its own (a dup over fd 1 took the
	# heartbeat's output, which then blocked on a full pipe)
	pid := sys->pctl(Sys->FORKNS|Sys->FORKFD, nil);
	mine = pid :: mine;
	epochpids = pid :: epochpids;
	nmine++;
	w := ref Wk(r, array[24] of ref FD, nil, depth);
	for(;;){
		{
			op(w);
		} exception e {
		"*" =>
			if(verbose)
				sys->print("w%d: %s\n", pid, e);
		}
		ops++;
		if(r.c(3))
			sys->sleep(r.n(4));
	}
}

ismine(pid: int): int
{
	for(l := mine; l != nil; l = tl l)
		if(hd l == pid)
			return 1;
	return 0;
}

# a path through a Prog's directory (/prog/N, or prog/N under an export
# of our name space mounted somewhere, or #p/N): whose is N?
progpid(p: string): int
{
	(nil, el) := sys->tokenize(p, "/");
	for(; el != nil && tl el != nil; el = tl el){
		if(hd el != "prog" && hd el != "#p")
			continue;
		d := hd tl el;
		n := 0;
		for(i := 0; i < len d && d[i] >= '0' && d[i] <= '9'; i++)
			n = n*10 + d[i] - '0';
		if(i > 0)
			return n;
	}
	return -1;
}

# may this path be written?
writable(p: string): int
{
	# by the last element, so no path reaches them: an export of our own
	# name space mounted under /n has a dev/sysctl too. sysctl's halt is
	# the driver's, and on the native kernel its tryboot resets the
	# machine; a new user or owner refuses the driver's halt; what is
	# written to keyboard is typed at the console's shell
	(nil, el) := sys->tokenize(p, "/");
	last := "";
	for(; el != nil; el = tl el)
		last = hd el;
	case last {
	"sysctl" or "hostopen" or "hoststdin" or "hoststdout" or "hoststderr" or
	"user" or "hostowner" or "keyboard" or "scancode" or "reboot" =>
		return 0;
	}
	pid := progpid(p);
	if(pid >= 0)
		return ismine(pid);
	# not the console: its junk would be the driver's output
	for(i := 0; i+4 <= len p; i++)
		if(p[i:i+4] == "cons")
			return 0;
	if(len p >= 4 && p[0:4] == "/fd/")
		return 0;
	return 1;
}

# Open at all? Not kprint, by any path (through an export too): while it
# is open, everything written to /dev/cons, every Prog's output, goes to
# its queue, and the run looks hung (the heartbeat silent).
openable(p: string): int
{
	for(i := 0; i+6 <= len p; i++)
		if(p[i:i+6] == "kprint")
			return 0;
	# a Prog's wait file has one reader, the last to open it: opened,
	# another's children's exits come here, not to it. The operator's
	# shell waited for ever on the next command it ran (nativefuzz)
	pid := progpid(p);
	if(pid >= 0 && !ismine(pid) && len p >= 4 && p[len p - 4:] == "wait")
		return 0;
	return 1;
}

# kprint by whatever name reached it -- a bind of /dev/kprint over
# another path, opened there -- closed at once: while it is open,
# everything written to the console goes to its queue, and the run's
# output, the operator's too, vanished (nativefuzz: a run "hung" with
# its Progs alive)
notkprint(fd: ref FD): ref FD
{
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok >= 0 && d.dtype == 'c' && d.name == "kprint")
		return nil;
	return fd;
}

anypath(r: ref Rng): string
{
	if(paths == nil || len paths == 0)
		return "/";
	p := paths[r.n(len paths)];
	if(r.c(10))
		p += "/" + junkname(r);
	return p;
}

junkname(r: ref Rng): string
{
	case r.n(6) {
	0 =>	return "..";
	1 =>	return ".";
	2 =>	return "";
	3 =>	return "é\U0001F680" + string r.n(100);
	4 =>
		s := "";
		for(i := r.n(300); i > 0; i--)
			s[len s] = 'a' + r.n(26);
		return s;
	}
	return "f" + string r.n(8);
}

junk(r: ref Rng): array of byte
{
	if(r.c(50))
		return array of byte WORDS[r.n(len WORDS)];
	n := r.n(4);
	case n {
	0 =>	n = 0;
	1 =>	n = 1 + r.n(16);
	2 =>	n = 1 + r.n(9000);
	* =>	n = 1 + r.n(70000);
	}
	b := array[n] of byte;
	for(i := 0; i < n; i++)
		b[i] = byte r.n(256);
	return b;
}

anyfd(w: ref Wk): ref FD
{
	return w.fds[w.r.n(len w.fds)];
}

keep(w: ref Wk, fd: ref FD)
{
	if(fd != nil)
		w.fds[w.r.n(len w.fds)] = fd;
}

modes := array[] of {
	Sys->OREAD, Sys->OWRITE, Sys->ORDWR, Sys->OREAD|Sys->OTRUNC,
	Sys->ORDWR|Sys->ORCLOSE, Sys->OWRITE|Sys->OTRUNC, Sys->OEXCL|Sys->ORDWR, 3, 16r7f,
};

op(w: ref Wk)
{
	r := w.r;
	k := r.n(30);
	if(skip[k])
		return;
	case k {
	0 or 1 or 2 =>
		p := anypath(r);
		m := modes[r.n(len modes)];
		if(m != Sys->OREAD && !writable(p))
			m = Sys->OREAD;
		if(!openable(p))
			return;
		keep(w, notkprint(sys->open(p, m)));
	3 =>
		d := array[] of {"/nvfs", "/nvfs/a", "/env", "/n", "/chan", "/tmp"};
		p := d[r.n(len d)] + "/" + junkname(r);
		perm := array[] of {8r666, 8r777|Sys->DMDIR, 8r600|Sys->DMAPPEND, 8r644|Sys->DMEXCL, 0, int 16rffffffff, 8r200|Sys->DMTMP};
		keep(w, sys->create(p, modes[r.n(3)], perm[r.n(len perm)]));
	4 or 5 or 6 =>
		fd := anyfd(w);
		if(fd != nil){
			n := array[] of {0, 1, 7, 64, 8192, 9000, 70000};
			b := array[n[r.n(len n)]] of byte;
			sys->read(fd, b, len b);
		}
	7 or 8 =>
		fd := anyfd(w);
		if(fd != nil && fd.fd > 2 && writable(sys->fd2path(fd))){
			b := junk(r);
			sys->write(fd, b, len b);
		}
	9 =>
		fd := anyfd(w);
		if(fd != nil){
			o := array[] of {big 0, big -1, big 1, big 16r7fffffffffffffff, -big 16r7fffffffffffffff - big 1, big 8192, big 16r100000000};
			sys->seek(fd, o[r.n(len o)], r.n(4));
		}
	10 =>
		fd := anyfd(w);
		if(fd != nil){
			o := array[] of {big 0, big -1, big 1, big 16r7fffffffffffffff, big 8191, big 16r100000000};
			b := array[r.n(9000)] of byte;
			if(r.c(50))
				sys->pread(fd, b, len b, o[r.n(len o)]);
			else if(fd.fd > 2 && writable(sys->fd2path(fd)))
				sys->pwrite(fd, b, len b, o[r.n(len o)]);
		}
	11 =>
		p := anypath(r);
		sys->stat(p);
		fd := anyfd(w);
		if(fd != nil){
			sys->fstat(fd);
			sys->iounit(fd);
		}
	12 =>
		# change what is ours to change: scratch and environment
		d := array[] of {"/nvfs", "/env"};
		p := d[r.n(2)] + "/" + junkname(r);
		dir := sys->nulldir;
		case r.n(5) {
		0 =>	dir.name = junkname(r);
		1 =>	dir.length = big r.n(100000);
		2 =>	dir.mode = r.n(8r777) | (r.n(2) << 31);
		3 =>	dir.mtime = r.n(1<<30);
		* =>	dir.length = big -1; dir.name = "";
		}
		sys->wstat(p, dir);
	13 =>
		fd := anyfd(w);
		if(fd != nil)
			sys->dirread(fd);
	14 =>
		n := sys->dup(r.n(30), r.n(40) - 2);
		if(n >= 0)
			keep(w, sys->fildes(n));
	15 =>
		f := array[2] of ref FD;
		if(sys->pipe(f) >= 0){
			keep(w, f[0]);
			keep(w, f[1]);
		}
	16 =>
		name := "fz" + string r.n(6);
		fio := sys->file2chan("/chan", name);
		if(fio != nil)
			spawn quiet(fio, nil, (nil, nil), ref Rng(r.s + big 1));
	17 =>
		# bind and unmount within our own name space
		flags := array[] of {Sys->MREPL, Sys->MBEFORE, Sys->MAFTER, Sys->MBEFORE|Sys->MCREATE, Sys->MAFTER|Sys->MCREATE, Sys->MCACHE, 16r7f};
		if(r.c(70))
			sys->bind(anypath(r), anypath(r), flags[r.n(len flags)]);
		else
			sys->unmount(nil, anypath(r));
	18 =>
		# a mount of a server that answers with junk, or not at all
		f := array[2] of ref FD;
		if(sys->pipe(f) >= 0){
			spawn quiet(nil, f[0], (nil, nil), ref Rng(r.s + big 7));
			sys->mount(f[1], nil, anypath(r), Sys->MREPL|r.n(2)*Sys->MCACHE, "");
		}
	19 =>
		# our own name space, exported and mounted back
		f := array[2] of ref FD;
		if(sys->pipe(f) >= 0){
			ex := array[] of {"/", "/nvfs", "/dev", "/prog", "/env", "/chan"};
			spawn quiet(nil, nil, (f[0], ex[r.n(len ex)]), r);
			on := array[] of {"/n", "/nvfs/a", "/tmp", "/net"};
			if(sys->mount(f[1], nil, on[r.n(len on)], Sys->MREPL|Sys->MCREATE, "") >= 0)
				keep(w, notkprint(sys->open(on[r.n(len on)] + "/" + junkname(r), modes[r.n(3)])));
		}
	20 =>
		sys->chdir(anypath(r));
	21 =>
		# not NEWPGRP: a worker in a group of its own escaped the epoch's
		# kill, and stayed in its reads and mounts after the run, one
		# reading the console taking the operator's next line
		# (nativefuzz). Killing each Prog by pid instead hung the killer:
		# a kill runs the dead Prog's closes in the killer, and a close
		# on a server that never answers does not return
		fl := array[] of {Sys->NEWFD, Sys->FORKFD, Sys->FORKNS, Sys->NEWENV, Sys->FORKENV, 0, Sys->FORKFD|Sys->FORKNS};
		pf := fl[r.n(len fl)];
		if(pf == Sys->NEWFD)
			sys->pctl(pf, 0 :: 1 :: 2 :: nil);
		else
			sys->pctl(pf, nil);
	22 or 23 =>
		if(nmine < 400 && w.depth < 6){
			pidc := chan of int;
			spawn child(pidc, ref Rng(r.s + big 13), w.depth + 1);
			w.kids = <-pidc :: w.kids;
		}
	24 or 25 =>
		# kill something of ours: a child, or a random one we made
		pid := -1;
		if(w.kids != nil && r.c(60)){
			pid = hd w.kids;
			w.kids = tl w.kids;
		}else if(mine != nil){
			n := r.n(nmine);
			for(l := mine; l != nil && n > 0; l = tl l)
				n--;
			if(l != nil)
				pid = hd l;
		}
		if(pid > 0 && pid != sys->pctl(0, nil))
			progctl(pid, ctls[r.n(len ctls)]);
	26 or 27 =>
		# the debugger's and the status files of anyone, written only if ours
		pid := sys->pctl(0, nil);
		if(mine != nil && r.c(70)){
			n := r.n(nmine);
			for(l := mine; l != nil && n > 0; l = tl l)
				n--;
			if(l != nil)
				pid = hd l;
		}
		files := array[] of {"status", "wait", "ns", "nsgrp", "fd", "stack", "exception", "grpwait", "heap", "dbgctl", "ctl", "pgrp", "text"};
		f := files[r.n(len files)];
		p := sys->sprint("/prog/%d/%s", pid, f);
		if(!openable(p))
			return;
		if(r.c(50) && writable(p)){
			fd := sys->open(p, Sys->ORDWR);
			if(fd != nil){
				b := junk(r);
				sys->write(fd, b, len b);
				keep(w, fd);
			}
		}else{
			fd := sys->open(p, Sys->OREAD);
			if(fd != nil){
				if(f == "wait" || f == "grpwait")
					keep(w, fd);	# a read of it blocks: some worker will
				else{
					b := array[1024] of byte;
					sys->read(fd, b, len b);
				}
			}
		}
	28 =>
		fd := anyfd(w);
		if(fd != nil){
			sys->fd2path(fd);
			sys->fauth(fd, junkname(r));
		}
	* =>
		w.fds[r.n(len w.fds)] = nil;	# a close, if it was the last
	}
}

child(pidc: chan of int, r: ref Rng, depth: int)
{
	pidc <-= sys->pctl(0, nil);
	if(r.c(30))
		sys->pctl(Sys->FORKFD|Sys->FORKNS, nil);
	if(r.c(20))
		exit;
	worker(r, depth);
}

progctl(pid: int, s: string)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

killgrp(pid: int)
{
	fd := sys->open(sys->sprint("#p/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil)
		fd = sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

# the helpers below, with what they raise (a write on a closed pipe,
# being killed) caught: expected, and not what is looked for
quiet(fio: ref Sys->FileIO, lfd: ref FD, ex: (ref FD, string), r: ref Rng)
{
	{
		if(fio != nil)
			badserver(fio, r);
		else if(lfd != nil)
			liar(lfd, r);
		else{
			(efd, dir) := ex;
			if(efd != nil)
				exporter(efd, dir);
		}
	} exception {
	"*" =>
		;
	}
}

# a file2chan server: answers late, wrong, with errors, or never
badserver(fio: ref Sys->FileIO, r: ref Rng)
{
	for(;;) alt {
	(off, n, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		case r.n(6) {
		0 =>	rc <-= (nil, "no such thing");
		1 =>	;	# never answered
		2 =>
			sys->sleep(r.n(20));
			rc <-= (array[n + r.n(3)] of byte, nil);	# more than asked
		3 =>	rc <-= (array[0] of byte, nil);
		* =>	rc <-= (array of byte sys->sprint("%d %d", off, n), nil);
		}
	(nil, data, nil, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		case r.n(4) {
		0 =>	wc <-= (0, "refused");
		1 =>	wc <-= (len data + 5, nil);	# claims more than was sent
		2 =>	;
		* =>	wc <-= (len data, nil);
		}
	}
}

# a 9P server that lies: whatever it reads, it answers with something
# shaped like a reply, or nothing, or not that
liar(fd: ref FD, r: ref Rng)
{
	b := array[9000] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n <= 0)
			return;
		case r.n(5) {
		0 =>	return;
		1 =>	continue;	# never answered
		}
		# a reply to what was sent: same tag, type+1, and junk after
		m := 7 + r.n(40);
		if(r.c(10))
			m = 4 + r.n(4);	# shorter than a header
		rp := array[m] of byte;
		for(i := 0; i < m; i++)
			rp[i] = byte r.n(256);
		size := m;
		if(r.c(15))
			size = r.n(100000);	# a size that is not the message's
		rp[0] = byte size;
		rp[1] = byte (size>>8);
		rp[2] = byte (size>>16);
		rp[3] = byte (size>>24);
		if(n >= 7 && m >= 7){
			if(r.c(80))
				rp[4] = b[4] + byte 1;	# R for its T
			if(r.c(80)){
				rp[5] = b[5];
				rp[6] = b[6];
			}
		}
		sys->write(fd, rp, len rp);
	}
}

exporter(fd: ref FD, dir: string)
{
	sys->export(fd, dir, Sys->EXPWAIT);
}

# With everything killed, does the kernel still answer? In /env: the
# scratch directory may have been renamed by then (wstat of /nvfs/.).
check()
{
	done := chan of string;
	spawn checker(done);
	t := chan of int;
	spawn timer(t, 20000);
	alt {
	s := <-done =>
		if(s == nil)
			sys->print("sysfuzz: done\n");
		else
			sys->print("sysfuzz: wedged: %s\n", s);
	<-t =>
		sys->print("sysfuzz: wedged: the check did not finish in 20s\n");
	}
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	# no one may be listening: a send would hold this Prog, and with it
	# the name space and the exports it shares, after the run
	alt {
	c <-= 1 =>
		;
	* =>
		;
	}
}

checker(done: chan of string)
{
	p := "/env/sysfuzzcheck";
	fd := sys->create(p, Sys->ORDWR, 8r666);
	if(fd == nil && scratchdir != nil && sys->stat("/env").t0 < 0){
		# with -d the root is scratch, and a worker may have renamed
		# its env directory, the mount point: a name the fuzz changed,
		# not the kernel failing. The pipe and the spawn still tell.
		checkpipe(done);
		return;
	}
	if(fd == nil){
		done <-= sys->sprint("create %s: %r", p);
		return;
	}
	b := array of byte "check";
	if(sys->write(fd, b, len b) != len b){
		done <-= sys->sprint("write: %r");
		return;
	}
	sys->seek(fd, big 0, Sys->SEEKSTART);
	r := array[16] of byte;
	n := sys->read(fd, r, len r);
	if(n != len b || string r[0:n] != "check"){
		done <-= sys->sprint("read back %d bytes", n);
		return;
	}
	fd = nil;
	if(sys->remove(p) < 0){
		done <-= sys->sprint("remove: %r");
		return;
	}
	checkpipe(done);
}

checkpipe(done: chan of string)
{
	b := array of byte "check";
	r := array[16] of byte;
	f := array[2] of ref FD;
	if(sys->pipe(f) < 0){
		done <-= sys->sprint("pipe: %r");
		return;
	}
	sys->write(f[0], b, len b);
	n := sys->read(f[1], r, len r);
	if(n != len b){
		done <-= "pipe read back";
		return;
	}
	c := chan of int;
	spawn spawned(c);
	<-c;
	done <-= nil;
}

spawned(c: chan of int)
{
	c <-= 1;
}
