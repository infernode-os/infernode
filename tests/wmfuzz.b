implement WmFuzz;

#
# Random use of a wm/wm application, to grind out what freezes it,
# takes it down or loses work: wm/editor or wm/shell, clicked and typed
# into through wm/wm's /chan/uitest (guifuzz), while a client changes
# the editor through /edit and the Veltro editor tool's files at once,
# as an agent does.
#
# Run under wm/wm with the application's window the only one; the
# driver, tools/wm-fuzz, starts both.  After the input stops it checks
# the application still answers, and then
#	editor	that its text reads back the same twice, that undo all the
#		way back and redo all the way forward give the same text, and
#		that saveas writes what it holds;
#	shell	that a command typed runs and its output is shown.
# then halts the emulator (unless -n).
#
#	wmfuzz -a editor|shell [-s seed] [-t secs] [-d dir] [-n]
#
# It prints lines beginning "fuzz:"; the outcome lines are RESPONSIVE,
# HUNG, BROKEN (a proc died), EXITED (the application was asked to
# exit, by its menu: not a failure), STUCK (the input threads did not
# finish), DATA (an integrity check failed) and INTEGRITY ok.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "guifuzz.m";
	g: Guifuzz;

WmFuzz: module {
	init: fn(nil: ref Draw->Context, args: list of string);
};

E: con "/edit";
EDITDIR: con "/tmp/veltro/editor";
SHELLBODY: con "/tmp/veltro/shell/body";

app := "editor";
dir := "/tmp/wmfuzz";
seed := 0;
halt := 1;

# typed whole now and then
editwords := array[] of {
	"hello ", "world\n", "\t", "foo bar baz\n", "(paren) [brack] {brace}\n",
	"é漢🚀\n", "a much longer line of text to wrap the window and then some more of it\n",
};
shellwords := array[] of {
	"echo hi\n", "ls\n", "date\n", "pwd\n", "cat /dev/null\n", "sleep 1\n",
	"echo é漢🚀\n", "cat f1\n", "echo a; echo b; echo c\n", "ls -l | wc\n",
	"for i in 1 2 3 4 5 6 7 8 9 {echo $i}\n",
};

# keys: no Ctrl-Q (it quits); for the shell no Esc (hold would freeze
# the output looked for at the end) and no Ctrl-D (EOF ends sh)
editkeys := array[] of {
	'\n', '\b', '\t', 16r1b, 16rFF9F,
	16rFF61, 16rFF57, 16rFF52, 16rFF54, 16rFF51, 16rFF53, 16rFF55, 16rFF56,
	'A'-'@', 'C'-'@', 'F'-'@', 'G'-'@', 'S'-'@', 'V'-'@', 'X'-'@', 'Y'-'@', 'Z'-'@',
	'Z'-'@', 'Z'-'@', 'Y'-'@',
};
shellkeys := array[] of {
	'\n', '\n', '\b', '\t', 16rFF9F,
	16rFF61, 16rFF57, 16rFF52, 16rFF54, 16rFF51, 16rFF53, 16rFF55, 16rFF56,
	'C'-'@', 'L'-'@', 'N'-'@', 'P'-'@', 'U'-'@', 'W'-'@',
};

nclient := 0;

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
	args = tl args;
	while(args != nil){
		a := hd args;
		args = tl args;
		case a {
		"-a" => app = hd args; args = tl args;
		"-s" => seed = int hd args; args = tl args;
		"-t" => secs = int hd args; args = tl args;
		"-d" => dir = hd args; args = tl args;
		"-n" => halt = 0;
		}
	}
	e := g->init(seed, 1);
	if(e != nil){
		sys->print("fuzz: %s\n", e);
		return;
	}
	sys->pctl(Sys->NEWPGRP, nil);
	sys->print("fuzz: %s seed %d secs %d\n", app, seed, secs);
	if(!window()){
		sys->print("fuzz: NO WINDOW\n");
		finish();
		return;
	}
	# the shell's menu ends with exit, which goes at once: not so far
	if(app == "shell")
		g->menureach = 130;
	g->deadline = sys->millisec() + secs*1000;
	done := chan of int;
	n := 2;
	spawn g->mouse(g->rand(1<<30), done);
	if(app == "shell")
		# no brackets or quotes: one left open makes sh read on for its
		# end, which no interrupt ends, and the check at the end is lost
		spawn g->keys(g->rand(1<<30), shellkeys, shellwords, " /.,|<>é漢🚀", done);
	else {
		spawn g->keys(g->rand(1<<30), editkeys, editwords, " /.,()[]{}|<>'\"é漢🚀", done);
		spawn client(done);
		n++;
	}
	if(app == "shell")
		spawn g->watch("Shell");
	else
		spawn g->watch("Editor");
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
	else if(g->exited)
		sys->print("fuzz: EXITED\n");
	else if(app == "shell")
		checkshell();
	else
		checkeditor();
	finish();
}

finish()
{
	if(halt)
		g->halt();
}

# Click and type in the application's window, not its frame's title
# bar (its buttons hide and close it) nor wm's background (whose menu
# makes and deletes windows): the topmost window wm lists.
window(): int
{
	for(i := 0; i < 40; i++){
		(n, l) := sys->tokenize(g->readfile("/chan/uitest"), " \n");
		if(n >= 5){
			l = tl l;
			x0 := int hd l; l = tl l;
			y0 := int hd l; l = tl l;
			x1 := int hd l; l = tl l;
			y1 := int hd l;
			g->x0 = x0 + 6;
			g->y0 = y0 + 28;
			g->x1 = x1 - 6;
			g->y1 = y1 - 6;
			sys->print("fuzz: window %d %d %d %d\n", g->x0, g->y0, g->x1, g->y1);
			return 1;
		}
		sys->sleep(250);
	}
	return 0;
}

# ---------- The editor ----------

# A client changing the text as an agent does, through /edit and the
# Veltro tool's files, while the user types.
client(done: chan of int)
{
	files := array[] of {dir+"/f1", dir+"/f2", dir+"/f3", dir+"/fbig"};
	while(sys->millisec() < g->deadline){
		nclient++;
		w := editwords[g->rand(len editwords)];
		ln := 1 + g->rand(40);
		col := 1 + g->rand(30);
		case g->rand(16) {
		0 or 1 =>
			ctl(sys->sprint("insert %d %d %s", ln, col, w));
		2 =>
			ctl(sys->sprint("delete %d %d %d %d", ln, col, ln + g->rand(3), 1 + g->rand(30)));
		3 =>
			ctl("append " + w);
		4 =>
			ctl("replace o\t0");
		5 =>
			ctl("replaceall 0\to");
		6 =>
			ctl(sys->sprint("goto %d", ln));
		7 =>
			ctl("find foo");
		8 =>
			if(g->rand(4) == 0)
				g->writefile(E+"/1/body", bigtext());
			else
				g->writefile(E+"/1/body", w + w + w);
		9 =>
			g->writefile(E+"/1/addr", sys->sprint("%d %d", ln, col));
		10 =>
			g->readfile(E+"/1/body");
			g->readfile(E+"/1/addr");
			g->readfile(E+"/index");
		11 =>
			spawn eventread();
		12 =>
			# the Veltro tool's files, as an agent's write and insert
			if(g->rand(2))
				put(EDITDIR+"/1/body.in", w + w);
			else
				put(EDITDIR+"/1/ctl", sys->sprint("insert %d %d %s", ln, col, w));
		13 =>
			if(g->rand(2))
				ctl("save");
			else
				ctl("saveas " + files[g->rand(len files)]);
		14 =>
			# refused while there are changes not saved
			if(g->rand(2))
				g->writefile(E+"/ctl", "open " + files[g->rand(len files)]);
			else
				g->writefile(E+"/ctl", "new");
		15 =>
			ctl("clean");
		}
		sys->sleep(10 + g->rand(300));
	}
	done <-= 1;
}

ctl(s: string)
{
	g->writefile(E+"/1/ctl", s);
}

eventread()
{
	g->readfile(E+"/1/event");
}

# as the tool does: written under its own name, renamed into place
put(path, s: string)
{
	tmp := path + ".fuzz";
	fd := sys->create(tmp, Sys->OWRITE, 8r666);
	if(fd == nil)
		return;
	b := array of byte s;
	sys->write(fd, b, len b);
	fd = nil;
	d := sys->nulldir;
	for(i := len path - 1; i >= 0 && path[i] != '/'; i--)
		;
	d.name = path[i+1:];
	sys->wstat(tmp, d);
}

bigtext(): string
{
	s := "";
	for(i := 0; i < 400; i++)
		s += sys->sprint("line %d %s", i, editwords[i % len editwords]);
	return s;
}

body(): string
{
	return g->readfile(E+"/1/body");
}

# The editor answers; its text reads back the same; undo all the way
# and redo all the way give it back; saveas writes it.
checkeditor()
{
	c := chan of string;
	spawn probe(c, E+"/index");
	alt{
	s := <-c =>
		if(s == nil){
			if(!g->broken())
				sys->print("fuzz: EXITED\n");
			return;
		}
		sys->print("fuzz: RESPONSIVE (%s)\n", chomp(s));
	<-g->timeout(5000) =>
		sys->print("fuzz: HUNG: %s/index did not answer in 5s\n", E);
		g->dumpprocs();
		return;
	}
	b0 := body();
	if(body() != b0){
		sys->print("fuzz: DATA: the body read twice is not the same\n");
		return;
	}
	# out of a prompt or a menu, and the keys to the text
	g->key(16r1b);
	g->key(16r1b);
	sys->sleep(300);
	g->ptr(g->x0 + 60, g->y0 + 40, 1);
	g->ptr(g->x0 + 60, g->y0 + 40, 0);
	sys->sleep(300);
	# what the client left in the tool's files is taken (every half
	# second); then a change, which clears what the run left to redo
	sys->sleep(1500);
	g->writefile(E+"/1/ctl", "append .");
	sys->sleep(300);
	b0 = body();
	sys->sleep(600);
	if(body() != b0){
		sys->print("fuzz: DATA: the text changed with nothing changing it\n");
		return;
	}
	# undo to the start, or 400 actions back
	n := 0;
	same := 0;
	last := b0;
	for(; n < 400 && same < 3; n++){
		g->key('Z'-'@');
		sys->sleep(40);
		b := body();
		if(b == last)
			same++;
		else
			same = 0;
		last = b;
	}
	for(i := 0; i < n; i++){
		g->key('Y'-'@');
		sys->sleep(10);
	}
	sys->sleep(1000);
	if((b := body()) != b0){
		sys->print("fuzz: DATA: undo %d and redo %d: %d characters, were %d\n", n, n, len b, len b0);
		save(dir + "/before", b0);
		save(dir + "/after", b);
		return;
	}
	g->writefile(E+"/1/ctl", "saveas " + dir + "/saved");
	if((s := g->readfile(dir + "/saved")) != b0){
		sys->print("fuzz: DATA: saveas wrote %d characters of %d\n", len s, len b0);
		return;
	}
	sys->print("fuzz: INTEGRITY ok (undo %d)\n", n);
}

save(f, s: string)
{
	fd := sys->create(f, Sys->OWRITE, 8r666);
	if(fd != nil)
		sys->fprint(fd, "%s", s);
}

probe(c: chan of string, f: string)
{
	c <-= g->readfile(f);
}

chomp(s: string): string
{
	if(len s > 0 && s[len s - 1] == '\n')
		s = s[0:len s - 1];
	return s;
}

# ---------- The shell ----------

# Echo mark, and whether it is shown within n quarter seconds.
shown(mark: string, n: int): int
{
	g->text("echo " + mark + "\n");
	for(i := 0; i < n; i++){
		sys->sleep(250);
		(nil, l) := sys->tokenize(g->readfile(SHELLBODY), "\n");
		for(; l != nil; l = tl l){
			s := hd l;
			if(len s >= 2 && s[0:2] == "; ")
				s = s[2:];
			if(s == mark){
				sys->print("fuzz: RESPONSIVE\n");
				sys->print("fuzz: INTEGRITY ok\n");
				return 1;
			}
		}
	}
	return 0;
}

# A command typed is run and its output shown.
checkshell()
{
	if(g->readfile(SHELLBODY) == nil){
		sys->print("fuzz: EXITED\n");
		return;
	}
	# out of a menu, the keys to the window; what runs interrupted
	g->ptr(g->x0 + 60, g->y0 + 40, 1);
	g->ptr(g->x0 + 60, g->y0 + 40, 0);
	sys->sleep(300);
	g->key('C'-'@');
	sys->sleep(1000);
	g->key('U'-'@');
	mark := sys->sprint("fuzzalive%d", seed);
	if(shown(mark, 20))
		return;
	# stuck (a loop of builtins, or waiting on what does not come): a
	# second interrupt with nothing to kill starts a new shell
	g->key('C'-'@');
	sys->sleep(1000);
	g->key('C'-'@');
	sys->sleep(2000);
	if(g->contains(g->readfile(SHELLBODY), "a new one is started"))
		sys->print("fuzz: (the shell did not answer: a new one was started)\n");
	mark += "r";
	if(shown(mark, 20))
		return;
	# a quote or a brace left open (by text sent from the transcript):
	# sh reads on for its end, which no interrupt ends.  Close them.
	for(k := 0; k < 3; k++){
		g->text("'\n");
		g->text("}\n");
		sys->sleep(1000);
		mark += "x";
		if(shown(mark, 20)){
			sys->print("fuzz: (a quote or a brace was open)\n");
			return;
		}
	}
	if(g->readfile(SHELLBODY) == nil){
		sys->print("fuzz: EXITED\n");
		return;
	}
	sys->print("fuzz: HUNG: echo %s not shown in 10s; the transcript ends\n", mark);
	t := g->readfile(SHELLBODY);
	if(len t > 600)
		t = t[len t - 600:];
	sys->print("%s\n", t);
	g->dumpprocs();
}
