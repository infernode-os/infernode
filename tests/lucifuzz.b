implement Lucifuzz;

#
# Random use of a zone of Lucifer (tools/lucifer-fuzz): the context
# zone (-a ctx), the agent's namespace, its tools and what it is using.
#
#	lucifuzz -a ctx -R x0 y0 x1 y1 [-s seed] [-t secs] [-n]
#
# Clicks, drags, the wheel and keys in the zone's rectangle (the
# pointer and keyboard devices), while a client changes what the zone
# shows as an agent and tools9p do: the activity's resources, gaps and
# background tasks through /mnt/ui (context/ctl: added, updated,
# removed, with values long, empty, odd and out of range) and the
# namespace manifest tools9p writes.  Then it checks the zone is still
# there (its proc running, none broken), that it takes an event and
# goes back to waiting for the next, and that /mnt/ui answers with
# what was last added.
#
# It prints lines beginning "fuzz:"; the outcome lines are RESPONSIVE,
# INTEGRITY ok, HUNG, GONE (the zone's proc ended), BROKEN (a proc
# died) and STUCK (the input threads did not finish).
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "guifuzz.m";
	g: Guifuzz;

Lucifuzz: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

UI: con "/mnt/ui";
CTXCTL: con "/mnt/ui/activity/0/context/ctl";
MANIFEST: con "/tmp/veltro/.ns/manifest";
AGENTNAME: con "/tmp/veltro/.ns/agentname";

app := "ctx";
seed := 0;
halt := 1;
nclient := 0;

ctxkeys := array[] of {
	'\n', '\b', '\t', 16r1b,
	16rE010, 16rE011, 16rE012, 16rE013, 16rE014, 16rE015, 16rE016, 16rE017,
};
ctxwords := array[] of {"tmp", "lib", "..", "/", "dis\n", "é漢🚀"};

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	g = load Guifuzz Guifuzz->PATH;
	if(g == nil){
		sys->print("fuzz: cannot load %s: %r\n", Guifuzz->PATH);
		return;
	}
	seed = sys->millisec();
	secs := 30;
	(rx0, ry0, rx1, ry1) := (768, 92, 1024, 768);
	args = tl args;
	while(args != nil){
		a := hd args;
		args = tl args;
		case a {
		"-a" => app = hd args; args = tl args;
		"-s" => seed = int hd args; args = tl args;
		"-t" => secs = int hd args; args = tl args;
		"-n" => halt = 0;
		"-R" =>
			rx0 = int hd args; args = tl args;
			ry0 = int hd args; args = tl args;
			rx1 = int hd args; args = tl args;
			ry1 = int hd args; args = tl args;
		}
	}
	e := g->init(seed, 0);
	if(e != nil){
		sys->print("fuzz: %s\n", e);
		finish();
		return;
	}
	sys->pctl(Sys->NEWPGRP, nil);
	(g->x0, g->y0, g->x1, g->y1) = (rx0, ry0, rx1, ry1);
	sys->print("fuzz: %s seed %d secs %d region %d %d %d %d\n", app, seed, secs, rx0, ry0, rx1, ry1);
	ctxpid := g->apppid("LuciCtx");
	if(ctxpid <= 0){
		sys->print("fuzz: GONE: no context zone running\n");
		finish();
		return;
	}
	g->deadline = sys->millisec() + secs*1000;
	done := chan of int;
	spawn g->mouse(g->rand(1<<30), done);
	spawn g->keys(g->rand(1<<30), ctxkeys, ctxwords, " /.,é漢🚀", done);
	spawn client(done);
	spawn g->watch("LuciCtx");
	n := 3;
	while(n > 0){
		alt{
		<-done =>
			n--;
		<-g->timeout(2000) =>
			if(sys->millisec() > g->deadline + 6000){
				sys->print("fuzz: STUCK: %d input threads did not finish (mouse %d keys %d client %d)\n",
					n, g->nmouse, g->nkeys, nclient);
				g->dumpprocs();
				n = 0;
			}
		}
	}
	sys->print("fuzz: done mouse %d keys %d client %d\n", g->nmouse, g->nkeys, nclient);
	sys->sleep(1000);
	if(g->broken())
		;
	else if(g->exited){
		sys->print("fuzz: GONE: the context zone's proc ended\n");
		for(l := g->trail(); l != nil; l = tl l)
			sys->print("	%s\n", hd l);
	}else
		checkctx(ctxpid);
	finish();
}

finish()
{
	if(halt)
		g->halt();
}

# ---------- what the zone shows, changed as an agent does ----------

# values: ordinary, empty, long, not ASCII, with the characters the
# attribute lines are made of, and numbers out of range
texts := array[] of {
	"files", "", "a much longer label than any column of the context zone has room for, and then some more of it",
	"é漢🚀", "key=value", "'quoted'", "a b c", "=", "''", "100", "-5", "150", "x\ty",
};
paths := array[] of {
	"/tmp", "/lib", "/n/local", "/mnt/ui", "/tmp/a b", "/é漢🚀", "/x/y/z", "/",
	"/tmp/very/deep/path/with/many/parts/that/goes/on/and/on",
};
perms := array[] of {"ro", "rw", "cow", "", "xx"};
rels := array[] of {"high", "medium", "low", "", "unknown"};

choose(a: array of string): string
{
	return a[g->rand(len a)];
}

# An attribute, quoted as tools write them
attr(k, v: string): string
{
	return k + "=" + quote(v);
}

quote(s: string): string
{
	if(s == "")
		return "''";
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\'' || s[i] == '=' || s[i] == '\t')
			break;
	if(i == len s)
		return s;
	q := "'";
	for(i = 0; i < len s; i++){
		if(s[i] == '\'')
			q += "'";
		q[len q] = s[i];
	}
	return q + "'";
}

client(done: chan of int)
{
	while(sys->millisec() < g->deadline){
		nclient++;
		case g->rand(12) {
		0 or 1 =>
			ctl("resource add " + attr("path", choose(paths) + string g->rand(20)) + " " +
				attr("label", choose(texts)) + " " + attr("type", choose(texts)) + " " +
				attr("status", choose(texts)) + " " + attr("via", choose(texts)));
		2 =>
			ctl("resource update " + attr("path", choose(paths) + string g->rand(20)) + " " +
				attr("status", choose(texts)));
		3 =>
			ctl("resource upsert " + attr("path", choose(paths) + string g->rand(20)) + " " +
				attr("label", choose(texts)));
		4 =>
			ctl("resource remove " + attr("path", choose(paths) + string g->rand(20)));
		5 =>
			ctl("resource activity " + choose(paths) + string g->rand(20));
		6 =>
			ctl("gap add " + attr("desc", choose(texts)) + " " + attr("relevance", choose(rels)));
		7 =>
			ctl("gap " + choose(array[] of {"remove ", "resolve ", "upsert "}) + attr("desc", choose(texts)));
		8 =>
			ctl("bg add " + attr("label", choose(texts)) + " " + attr("status", choose(texts)) + " " +
				attr("progress", choose(texts)));
		9 =>
			ctl("bg update " + attr("label", choose(texts)) + " " + attr("progress", choose(texts)));
		10 =>
			manifest();
		11 =>
			g->writefile(AGENTNAME, choose(texts));
		}
		g->pause();
	}
	done <-= 1;
}

ctl(s: string)
{
	g->writefile(CTXCTL, s);	# refused or not: the zone must go on
}

# A namespace manifest, as tools9p writes one: sometimes more entries
# than the zone keeps rectangles for
manifest()
{
	n := g->rand(8);
	if(g->rand(6) == 0)
		n = 60 + g->rand(60);
	m := "";
	for(i := 0; i < n; i++)
		m += attr("path", choose(paths) + string i) + " " + attr("label", choose(texts)) + " " +
			attr("perm", choose(perms)) + "\n";
	g->writefile(MANIFEST, m);
}

# ---------- the checks ----------

# The zone takes an event and goes back to waiting (its proc in alt or
# recv); /mnt/ui answers, with the resource just added.
checkctx(pid: int)
{
	mark := sys->sprint("/fuzz/final%d", seed);
	ctl("resource add " + attr("path", mark) + " " + attr("label", "final"));
	t0 := sys->millisec();
	if(!idle(pid, 60000)){
		sys->print("fuzz: HUNG: the context zone did not go back to waiting in 60s\n");
		g->dumpprocs();
		return;
	}
	sys->print("fuzz: RESPONSIVE (waiting again in %dms)\n", sys->millisec() - t0);
	c := chan of string;
	spawn probe(c);
	alt {
	r := <-c =>
		if(!g->contains(r, mark)){
			sys->print("fuzz: DATA: the resource added is not in /mnt/ui\n");
			return;
		}
	<-g->timeout(10000) =>
		sys->print("fuzz: HUNG: /mnt/ui did not answer in 10s\n");
		g->dumpprocs();
		return;
	}
	sys->print("fuzz: INTEGRITY ok\n");
}

# The resources as /mnt/ui lists them
probe(c: chan of string)
{
	s := "";
	for(i := 0; i < 256; i++){
		r := g->readfile(sys->sprint("%s/activity/0/context/resources/%d", UI, i));
		if(r == nil)
			break;
		s += r + "\n";
	}
	c <-= s;
}

# Whether proc pid is waiting on a channel (alt, recv) within ms
idle(pid, ms: int): int
{
	t0 := sys->millisec();
	while(sys->millisec() - t0 < ms){
		(n, f) := sys->tokenize(g->readfile("/prog/" + string pid + "/status"), " ");
		if(n >= 5){
			st := hd tl tl tl tl f;
			if(st == "alt" || st == "recv")
				return 1;
		}
		sys->sleep(100);
	}
	return 0;
}
