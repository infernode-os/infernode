implement Snapd;

#
# snapd - daily vac snapshots of /usr into the local venti store.
#
# The dump filesystem's role, recreated for InferNode (docs/
# PERSISTENCE.md): once a day (and on demand with -1) the whole
# durable /usr tree is archived into the snapshot venti as a vac
# tree; the resulting score is one line in /usr/inferno/snapshots/log,
# from which any past state can be mounted read-only with vacfs(4) or
# extracted with vacget(1). Identical content dedupes, so a snapshot
# costs only what changed. Durability of /usr itself does NOT depend
# on this — snapshots add history, not persistence.
#
# Capacity watch: before each snapshot the store's data file is
# checked against the configured maximum; past the warning threshold
# a warning lands in the status file (read by the Settings panel) and,
# when the install audits, in the audit log.
#
# The store must live OUTSIDE /usr (a snapshot must not contain its
# own store); the boot profile keeps it in ~/.infernode/venti and
# exports its in-namespace path as $ventistore.
#

include "sys.m";
	sys: Sys;
	sprint: import sys;

include "draw.m";

include "arg.m";

include "daytime.m";
	daytime: Daytime;

include "audit.m";
	audit: Audit;

Snapd: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

Command: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

VENTIADDR: con "tcp!127.0.0.1!17034";
SNAPDIR: con "/usr/inferno/snapshots";

# Default archive set: the durable /usr plus the ~/.infernode config
# overlays that live OUTSIDE /usr (captured as the namespace sees them
# — the union view, durable side first). The system tree stays out
# (reproducible from releases); the host home stays out (the host's
# own backup domain); the store stays out (outside these trees by
# construction).
DEFTREES: con "/usr /lib/ndb /lib/lucifer/theme /lib/veltro /lib/keyring";
DAYMS: con 24 * 60 * 60 * 1000;
MAXDATA: con big 8589934592;	# keep in sync with the profile's ventisrv args
WARNPCT: con 80;

stderr: ref Sys->FD;
addr := VENTIADDR;
trees: list of string;
maxdata := MAXDATA;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	if(arg == nil)
		fail(sprint("load arg: %r"));
	daytime = load Daytime Daytime->PATH;
	audit = load Audit Audit->PATH;
	if(audit != nil)
		audit->init();

	oneshot := 0;
	arg->init(args);
	arg->setusage("snapd [-1] [-a addr] [-p tree]... [-m maxdatasize]");
	while((c := arg->opt()) != 0)
		case c {
		'1' =>	oneshot = 1;
		'a' =>	addr = arg->earg();
		'p' =>	trees = arg->earg() :: trees;
		'm' =>	maxdata = big arg->earg();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();
	if(trees == nil) {
		(nil, deftrees) := sys->tokenize(DEFTREES, " ");
		trees = deftrees;
	}

	sys->create(SNAPDIR, Sys->OREAD, Sys->DMDIR | 8r755);

	if(oneshot) {
		err := snapshot();
		if(err != nil)
			fail(err);
		return;
	}

	# daemon: first snapshot shortly after boot (give ventisrv time to
	# come up), then daily. A failed attempt retries on a short fuse —
	# a boot race (the store still announcing) must not cost a day of
	# history; the status file reflects each failure meanwhile.
	sys->sleep(15000);
	for(;;) {
		err := snapshot();
		if(err != nil) {
			sys->fprint(stderr, "snapd: %s\n", err);
			sys->sleep(60000);
			continue;
		}
		sys->sleep(DAYMS);
	}
}

snapshot(): string
{
	capacitycheck();
	score := vacput();
	if(score == nil || score == "")
		return status("snapshot failed: vacput produced no score");

	line := sprint("%s %s\n", stamp(), score);
	fd := sys->open(SNAPDIR + "/log", Sys->OWRITE);
	if(fd == nil)
		fd = sys->create(SNAPDIR + "/log", Sys->OWRITE, 8r644);
	if(fd == nil)
		return status(sprint("cannot write snapshot log: %r"));
	sys->seek(fd, big 0, Sys->SEEKEND);
	b := array of byte line;
	sys->write(fd, b, len b);
	fd = nil;

	if(audit != nil)
		audit->log("snapd", "snapshot", "trees=" + jointrees(",") + " score=" + score);
	return status("ok " + stamp() + " " + score);
}

# run vacput with stdout captured to a scratch file; returns
# "vac:<score>" or nil. Completion is signalled on a channel — no
# reliance on pipe-EOF across fd groups (which proved leak-prone).
vacput(): string
{
	cmd := load Command "/dis/vacput.dis";
	if(cmd == nil) {
		status(sprint("cannot load vacput: %r"));
		return nil;
	}
	outpath := SNAPDIR + "/.vacput.out";
	ofd := sys->create(outpath, Sys->OWRITE, 8r600);
	if(ofd == nil) {
		status(sprint("cannot create %s: %r", outpath));
		return nil;
	}
	donec := chan of int;
	spawn vacputproc(cmd, ofd, donec);
	ofd = nil;
	<-donec;

	out := "";
	rfd := sys->open(outpath, Sys->OREAD);
	if(rfd != nil) {
		buf := array[512] of byte;
		for(;;) {
			n := sys->read(rfd, buf, len buf);
			if(n <= 0)
				break;
			out += string buf[:n];
		}
	}
	sys->remove(outpath);
	# vacput prints "vac:<40 hex>" on its last line
	(nil, lines) := sys->tokenize(out, "\n");
	for(; lines != nil; lines = tl lines)
		if(len hd lines > 4 && (hd lines)[0:4] == "vac:")
			return hd lines;
	return nil;
}

vacputproc(cmd: Command, ofd: ref Sys->FD, donec: chan of int)
{
	sys->pctl(Sys->NEWFD, ofd.fd :: 2 :: nil);
	sys->dup(ofd.fd, 1);
	ofd = nil;
	{
		cmd->init(nil, "vacput" :: "-a" :: addr :: revtrees());
	} exception {
	* =>
		;
	}
	donec <-= 1;
}

capacitycheck()
{
	store := getenv("ventistore");
	if(store == "")
		return;
	(ok, d) := sys->stat(store + "/data");
	if(ok < 0)
		return;
	pct := int (d.length * big 100 / maxdata);
	if(pct >= WARNPCT) {
		msg := sprint("store at %d%% of capacity (%bd of %bd bytes)", pct, d.length, maxdata);
		status("warning: " + msg);
		if(audit != nil)
			audit->log("snapd", "capacity", sprint("pct=%d bytes=%bd max=%bd", pct, d.length, maxdata));
		sys->fprint(stderr, "snapd: %s\n", msg);
	}
}

status(s: string): string
{
	fd := sys->create(SNAPDIR + "/status", Sys->OWRITE, 8r644);
	if(fd != nil) {
		b := array of byte (s + "\n");
		sys->write(fd, b, len b);
	}
	if(len s >= 2 && s[0:2] == "ok")
		return nil;
	return s;
}

stamp(): string
{
	if(daytime == nil)
		return "-";
	t := daytime->local(daytime->now());
	return sprint("%04d-%02d%02d %02d:%02d", t.year + 1900, t.mon + 1, t.mday, t.hour, t.min);
}

getenv(name: string): string
{
	fd := sys->open("/env/" + name, Sys->OREAD);
	if(fd == nil)
		return "";
	buf := array[256] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return "";
	s := string buf[:n];
	while(len s > 0 && (s[len s - 1] == '\n' || s[len s - 1] == 0))
		s = s[:len s - 1];
	return s;
}

# trees was built by prepending -p args; restore command-line order
revtrees(): list of string
{
	r: list of string;
	for(l := trees; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

jointrees(sep: string): string
{
	s := "";
	for(l := revtrees(); l != nil; l = tl l) {
		if(s != "")
			s += sep;
		s += hd l;
	}
	return s;
}

fail(s: string)
{
	sys->fprint(stderr, "snapd: %s\n", s);
	raise "fail:" + s;
}
