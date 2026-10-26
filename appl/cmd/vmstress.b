implement Vmstress;

#
# vmstress -- work the Dis VMs hard: churn, traffic across them, and
# allocation, with every success and every failure counted (#944).
#
# A soak with a jitbench loop in each VM keeps the cores busy but never
# exercises what is new about VMs: programs started in them, programs
# ending, and the crossings between them. This does. It runs as the
# orchestrator in VM 0 and starts its other roles in VMs 1-3 through
# #V/vm/N/run, the file vm(1) writes:
#
#   vmstress run DIR [secs]	orchestrate, forever or for secs; report
#				one line a minute; stop when DIR/stop exists
#   vmstress pipeecho FILE	echo whatever is written to the pipe end FILE
#   vmstress srvecho DIR NAME	serve DIR/NAME (file2chan): a read returns
#				what that fid last wrote
#   vmstress client FILE OUT	round trips through FILE, payloads checked;
#				counts to the file OUT, rewritten each 5 s
#   vmstress job KIND DONE	a short job; a byte to the pipe DONE at the end
#   vmstress alloc		allocate and drop, forever
#
# The orchestrator starts, in each of VMs 1-3, a pipe echo, a served-file
# echo and an allocation loop; it runs clients in VM 0 against every one,
# and in VM 1 against VM 2's and in VM 3 against VM 1's, so traffic goes
# both ways between VMs other than 0. Then, until stopped: a short job in
# a random VM every CHURNMS, a burst of one in every VM at the same
# instant every BURSTS seconds, and every KILLS seconds a sleeper started
# in a random VM and killed from VM 0 through /prog, its disappearance
# checked. Each minute: the counts, and each VM's progs and heap, so a
# leak shows as a number that climbs.
#

include "sys.m";
	sys: Sys;
include "draw.m";

Vmstress: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

CHURNMS:	con 300;
BURSTS:		con 30;
KILLS:		con 10;
NVM:		con 4;
MYPATH:		con "/dis/vmstress.dis";	# where VMs 1-3 load us from; run copies it

me := MYPATH;
stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	argv = tl argv;
	if(argv == nil)
		usage();
	case hd argv {
	"run" =>
		if(tl argv == nil)
			usage();
		secs := 0;
		if(tl tl argv != nil)
			secs = int hd tl tl argv;
		run(hd tl argv, secs);
	"pipeecho" =>
		if(tl argv == nil)
			usage();
		pipeecho(hd tl argv);
	"srvecho" =>
		if(len argv < 3)
			usage();
		srvecho(hd tl argv, hd tl tl argv);
	"client" =>
		if(len argv < 3)
			usage();
		client(hd tl argv, hd tl tl argv);
	"job" =>
		if(len argv < 3)
			usage();
		job(hd tl argv, hd tl tl argv);
	"alloc" =>
		alloc();
	* =>
		usage();
	}
}

usage()
{
	sys->fprint(stderr, "usage: vmstress run DIR [secs] | pipeecho FILE | srvecho DIR NAME | client FILE OUT | job KIND DONE | alloc\n");
	raise "fail:usage";
}

#
# The orchestrator.
#

Counts: adt {
	starts:		int;	# jobs started
	startfail:	int;	# a run file refused one
	done:		int;	# jobs that reported finishing
	bursts:		int;
	burstfail:	int;
	kills:		int;
	killfail:	int;	# the sleeper outlived its kill
};

cnt: ref Counts;
seed := 1;
owned: list of int;	# the pids of the long-lived roles, killed at the end

rand(n: int): int
{
	seed = seed * 1103515245 + 12345;
	r := (seed >> 16) & 16r7FFF;
	return r % n;
}

# start argv in VM n; its pid, or -1 having counted nothing
vmstart(n: int, args: list of string): int
{
	fd := sys->open(sys->sprint("#V/vm/%d/run", n), Sys->ORDWR);
	if(fd == nil)
		return -1;
	s := "";
	for(; args != nil; args = tl args){
		if(s != "")
			s += " ";
		s += hd args;
	}
	b := array of byte s;
	if(sys->write(fd, b, len b) != len b)
		return -1;
	pb := array[32] of byte;
	r := sys->pread(fd, pb, len pb, big 0);
	if(r <= 0)
		return 0;	# started; no pid said
	return int string pb[0:r];
}

mkdir(d: string)
{
	fd := sys->create(d, Sys->OREAD, Sys->DMDIR | 8r777);
	fd = nil;
}

run(dir: string, secs: int)
{
	seed = sys->millisec() | 1;
	cnt = ref Counts(0, 0, 0, 0, 0, 0, 0);
	mkdir(dir);
	# ourselves where every VM can load us: the namespace is shared
	me = dir + "/vmstress.dis";
	copy(MYPATH, me);

	# the completion pipe jobs write a byte to
	mkdir(dir + "/done");
	if(sys->bind("#|", dir + "/done", Sys->MREPL) < 0)
		fatal("bind #| " + dir + "/done: %r");

	# the served files live under one #s, after DIR/s
	mkdir(dir + "/s");
	if(sys->bind("#s", dir + "/s", Sys->MREPL) < 0)
		fatal("bind #s " + dir + "/s: %r");

	for(k := 1; k < NVM; k++){
		pd := sys->sprint("%s/p%d", dir, k);
		mkdir(pd);
		if(sys->bind("#|", pd, Sys->MREPL) < 0)
			fatal("bind #| " + pd + ": %r");
		own(k, "pipeecho", me :: "pipeecho" :: pd + "/data1" :: nil);
		own(k, "srvecho", me :: "srvecho" :: dir + "/s" :: sys->sprint("e%d", k) :: nil);
		own(k, "alloc", me :: "alloc" :: nil);
	}
	sys->sleep(3000);

	# clients: VM 0 against every VM's echoes, and VM 1 <-> VM 2, VM 3 -> VM 1
	clients: list of string;
	for(k = 1; k < NVM; k++){
		clients = startclient(0, sys->sprint("%s/p%d/data", dir, k), dir, sys->sprint("c0p%d", k)) :: clients;
		clients = startclient(0, sys->sprint("%s/s/e%d", dir, k), dir, sys->sprint("c0s%d", k)) :: clients;
	}
	clients = startclient(1, dir + "/s/e2", dir, "c1s2") :: clients;
	clients = startclient(3, dir + "/s/e1", dir, "c3s1") :: clients;

	# held open here so the pipe stays up between jobs
	donew := sys->open(dir + "/done/data1", Sys->OWRITE);
	if(donew == nil)
		fatal("open " + dir + "/done/data1: %r");
	spawn donecounter(dir + "/done/data");

	t0 := sys->millisec();
	lastburst := t0;
	lastkill := t0;
	lastreport := t0;
	report(dir, clients, t0);
	for(;;){
		if(stopped(dir) || (secs > 0 && sys->millisec() - t0 > secs * 1000))
			break;
		now := sys->millisec();
		# churn: a short job in a random VM
		k = rand(NVM);
		kinds := array[] of {"list", "string", "sh", "sleep"};
		if(vmstart(k, me :: "job" :: kinds[rand(len kinds)] :: dir + "/done/data1" :: nil) < 0){
			cnt.startfail++;
			sys->fprint(stderr, "vmstress: start in VM %d: %r\n", k);
		}else
			cnt.starts++;
		# a burst: one in every VM at the same instant
		if(now - lastburst > BURSTS * 1000){
			lastburst = now;
			burst(dir);
		}
		# a sleeper started elsewhere and killed from here
		if(now - lastkill > KILLS * 1000){
			lastkill = now;
			killone();
		}
		if(now - lastreport > 60 * 1000){
			lastreport = now;
			report(dir, clients, t0);
		}
		sys->sleep(CHURNMS);
	}
	report(dir, clients, t0);
	for(; owned != nil; owned = tl owned)
		kill(hd owned);
	donew = nil;
	sys->print("vmstress: stopped\n");
}

startclient(n: int, file, dir, name: string): string
{
	out := dir + "/" + name;
	if(n == 0){
		pc := chan of int;
		spawn ownedclient(file, out, pc);
		owned = <-pc :: owned;
	}else
		own(n, "client " + name, me :: "client" :: file :: out :: nil);
	return out;
}

ownedclient(file, out: string, pc: chan of int)
{
	pc <-= sys->pctl(0, nil);
	client(file, out);
}

# start a long-lived role in VM n, to be killed at the end
own(n: int, what: string, args: list of string)
{
	pid := vmstart(n, args);
	if(pid <= 0)
		fatal(sys->sprint("start %s in VM %d: %r", what, n));
	owned = pid :: owned;
}

kill(pid: int): int
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "kill") < 0)
		return -1;
	return 0;
}

burst(dir: string)
{
	c := chan of int;
	for(k := 0; k < NVM; k++)
		spawn burstone(k, dir, c);
	for(k = 0; k < NVM; k++){
		if(<-c < 0)
			cnt.burstfail++;
		else
			cnt.starts++;
	}
	cnt.bursts++;
}

burstone(k: int, dir: string, c: chan of int)
{
	c <-= vmstart(k, me :: "job" :: "list" :: dir + "/done/data1" :: nil);
}

killone()
{
	k := 1 + rand(NVM-1);
	pid := vmstart(k, me :: "job" :: "sleep" :: "/dev/null" :: nil);
	if(pid <= 0){
		cnt.killfail++;
		sys->fprint(stderr, "vmstress: sleeper in VM %d: no pid (%r)\n", k);
		return;
	}
	cnt.starts++;
	sys->sleep(200);
	if(kill(pid) < 0){
		cnt.killfail++;
		sys->fprint(stderr, "vmstress: kill %d in VM %d: %r\n", pid, k);
		return;
	}
	for(i := 0; i < 20; i++){
		(ok, nil) := sys->stat(sys->sprint("/prog/%d", pid));
		if(ok < 0){
			cnt.kills++;
			return;
		}
		sys->sleep(100);
	}
	cnt.killfail++;
	sys->fprint(stderr, "vmstress: %d in VM %d outlived its kill\n", pid, k);
}

donecounter(file: string)
{
	fd := sys->open(file, Sys->OREAD);
	if(fd == nil)
		fatal("open " + file + ": %r");
	b := array[256] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		cnt.done += n;
}

stopped(dir: string): int
{
	(ok, nil) := sys->stat(dir + "/stop");
	return ok >= 0;
}

report(dir: string, clients: list of string, t0: int)
{
	tok := 0;
	tbad := 0;
	per := "";
	for(l := clients; l != nil; l = tl l){
		s := readfile(hd l);
		(n, f) := sys->tokenize(s, " \n");
		if(n >= 2){
			tok += int hd f;
			tbad += int hd tl f;
		}
		per += sys->sprint(" %s=%s", basename(hd l), oneline(s));
	}
	vms := "";
	for(k := 0; k < NVM; k++)
		vms += " |" + oneline(readfile(sys->sprint("#V/vm/%d/status", k)));
	line := sys->sprint("vmstress: %ds starts %d startfail %d done %d bursts %d burstfail %d kills %d killfail %d traffic ok %d bad %d;%s;%s\n",
		(sys->millisec() - t0) / 1000, cnt.starts, cnt.startfail, cnt.done,
		cnt.bursts, cnt.burstfail, cnt.kills, cnt.killfail, tok, tbad, vms, per);
	sys->print("%s", line);
	fd := sys->create(dir + "/report", Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%s", line);
}

#
# The roles in the other VMs.
#

pipeecho(file: string)
{
	fd := sys->open(file, Sys->ORDWR);
	if(fd == nil)
		fatal("pipeecho: open " + file + ": %r");
	b := array[Sys->ATOMICIO] of byte;
	while((n := sys->read(fd, b, len b)) > 0)
		if(sys->write(fd, b, n) != n)
			break;
}

srvecho(dir, name: string)
{
	io := sys->file2chan(dir, name);
	if(io == nil)
		fatal("srvecho: file2chan " + dir + "/" + name + ": %r");
	last := array[64] of array of byte;	# by fid, folded
	for(;;) alt {
	(nil, data, fid, wc) := <-io.write =>
		if(wc == nil){
			last[fid % len last] = nil;
			break;
		}
		last[fid % len last] = data;
		wc <-= (len data, nil);
	(nil, nil, fid, rc) := <-io.read =>
		if(rc == nil)
			break;
		d := last[fid % len last];
		last[fid % len last] = nil;
		rc <-= (d, nil);
	}
}

# Round trips with a random payload, each checked against what was sent.
# "ok bad" to OUT every 5 s; a bad one is said once on stderr with why.
client(file, out: string)
{
	fd := sys->open(file, Sys->ORDWR);
	if(fd == nil){
		writecount(out, 0, 1);
		sys->fprint(stderr, "vmstress: client: open %s: %r\n", file);
		return;
	}
	seed = sys->millisec() | 1;
	ok := 0;
	bad := 0;
	last := sys->millisec();
	buf := array[512] of byte;
	for(i := 0; ; i++){
		n := 1 + rand(len buf);
		p := array[n] of byte;
		for(j := 0; j < n; j++)
			p[j] = byte (i + j);
		if(sys->write(fd, p, n) != n){
			bad++;
			sys->fprint(stderr, "vmstress: client %s: write: %r\n", file);
			sys->sleep(1000);
			continue;
		}
		got := 0;
		while(got < n){
			r := sys->read(fd, buf[got:], n - got);
			if(r <= 0)
				break;
			got += r;
		}
		if(got != n || !same(buf[0:got], p)){
			bad++;
			if(bad < 5){
				why := "";
				if(got == n)
					why = ", different";
				sys->fprint(stderr, "vmstress: client %s: round trip %d: sent %d, got %d back%s\n",
					file, i, n, got, why);
			}
		}else
			ok++;
		if(sys->millisec() - last > 5000){
			last = sys->millisec();
			writecount(out, ok, bad);
		}
	}
}

same(a, b: array of byte): int
{
	if(len a != len b)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] != b[i])
			return 0;
	return 1;
}

writecount(out: string, ok, bad: int)
{
	fd := sys->create(out, Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%d %d\n", ok, bad);
}

job(kind, done: string)
{
	case kind {
	"list" =>
		l: list of string;
		for(i := 0; i < 2000; i++)
			l = string i :: l;
		n := 0;
		for(; l != nil; l = tl l)
			n += len hd l;
	"string" =>
		s := "";
		for(i := 0; i < 500; i++)
			s += string i;
		t := 0;
		for(i = 0; i < len s; i += 7)
			t += s[i];
	"sh" =>
		sh := load Command "/dis/sh.dis";
		if(sh != nil)
			sh->init(nil, "sh" :: "-c" :: "load std; for(i in 1 2 3) { x=$i }" :: nil);
	"sleep" =>
		sys->sleep(5000);
	}
	fd := sys->open(done, Sys->OWRITE);
	if(fd != nil)
		sys->write(fd, array[1] of {byte 'j'}, 1);
}

Command: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

alloc()
{
	for(;;){
		a := array[200] of string;
		for(i := 0; i < len a; i++)
			a[i] = "item " + string i;
		l: list of array of string;
		for(i = 0; i < 20; i++)
			l = a[0:i*10] :: l;
		a = nil;
		l = nil;
		sys->sleep(5);
	}
}

#
# helpers
#

copy(src, dst: string)
{
	f := sys->open(src, Sys->OREAD);
	if(f == nil)
		fatal("open " + src + ": %r");
	t := sys->create(dst, Sys->OWRITE, 8r755);
	if(t == nil)
		fatal("create " + dst + ": %r");
	b := array[8192] of byte;
	while((n := sys->read(f, b, len b)) > 0)
		sys->write(t, b, n);
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return "?";
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "";
	return string b[0:n];
}

oneline(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			return s[0:i];
	return s;
}

basename(s: string): string
{
	for(i := len s - 1; i >= 0; i--)
		if(s[i] == '/')
			return s[i+1:];
	return s;
}

fatal(s: string)
{
	sys->fprint(stderr, "vmstress: %s\n", s);
	raise "fail:" + s;
}
