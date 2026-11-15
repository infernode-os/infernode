implement Spawnfake;

#
# spawnfake - what the spawn tool's host tests need beside the real
# tools9p and spawn (tests/host/spawn_life_test.sh,
# tests/host/spawn_provenance_test.sh, tests/host/tools9p_call_test.sh).
#
#	spawnfake llm dir log
#		A model service at dir, in llmsrv's shape: new, and a
#		directory a session (s0, s1, ...) holding ask, tools, system,
#		thinking, model and ctl.  A read of new gives the next
#		session.  What a session's model answers is chosen by a word
#		of its first prompt, SCENARIO:name (see reply).  Every new,
#		ask and close is a line of log, with the time in ms.
#	spawnfake ui log
#		A /mnt/ui/ctl that takes any request, and at each says in
#		log whether the task tool's process (a Prog of module
#		ToolTask) has a restricted name space: a line "restricted" or
#		"unrestricted".
#	spawnfake fds
#		The caller's open descriptors, a line each: "fd N path".
#	spawnfake kill word module
#		Write word (kill, killgrp) to the ctl file of each process
#		whose status names module.
#	spawnfake callkill file ms text
#		Write text to file in a process that is killed ms later: a
#		caller that goes in the middle of its call.
#	spawnfake hold file [text]
#		Open file for writing, wait for a line on standard input,
#		then write text (or the line) to it and print what the file
#		then reads as.  A descriptor held across changes to the tree
#		it was opened in.
#
# Not a test of its own: the runner does not run it.
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "bufio.m";

Spawnfake: module
{
	init: fn(nil: ref Draw->Context, args: list of string);
};

NSESS: con 16;

logfd: ref Sys->FD;
next := 0;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	if(args != nil)
		args = tl args;
	if(args == nil) {
		sys->fprint(sys->fildes(2), "usage: spawnfake llm dir log | ui log | fds | hold file [text]\n");
		raise "fail:usage";
	}
	case hd args {
	"llm" =>
		if(len args != 3)
			raise "fail:usage";
		llm(hd tl args, hd tl tl args);
	"ui" =>
		if(len args != 2)
			raise "fail:usage";
		ui(hd tl args);
	"fds" =>
		fds();
	"kill" =>
		if(len args != 3)
			raise "fail:usage";
		killmod(hd tl args, hd tl tl args);
	"callkill" =>
		if(len args != 4)
			raise "fail:usage";
		callkill(hd tl args, int hd tl tl args, hd tl tl tl args);
	"hold" =>
		text := "";
		if(len args > 2)
			text = hd tl tl args;
		hold(hd tl args, text);
	* =>
		raise "fail:usage";
	}
}

killmod(word, mod: string)
{
	pfd := sys->open("/prog", Sys->OREAD);
	if(pfd == nil)
		return;
	for(;;) {
		(c, d) := sys->dirread(pfd);
		if(c <= 0)
			break;
		for(i := 0; i < c; i++) {
			if(!has(slurp("/prog/" + d[i].name + "/status"), mod))
				continue;
			fd := sys->open("/prog/" + d[i].name + "/ctl", Sys->OWRITE);
			if(fd != nil && sys->fprint(fd, "%s", word) >= 0)
				sys->print("%s %s\n", word, d[i].name);
		}
	}
}

callkill(file: string, ms: int, text: string)
{
	pidc := chan of int;
	spawn caller(file, text, pidc);
	pid := <-pidc;
	sys->sleep(ms);
	fd := sys->open(sys->sprint("/prog/%d/ctl", pid), Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "kill") < 0)
		sys->print("callkill: the caller had gone: %r\n");
	else
		sys->print("callkill: killed\n");
}

caller(file, text: string, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd := sys->open(file, Sys->OWRITE);
	if(fd == nil)
		return;
	b := array of byte text;
	sys->write(fd, b, len b);
}

fds()
{
	for(i := 0; i < 64; i++) {
		(ok, nil) := sys->fstat(ref Sys->FD(i));
		if(ok < 0)
			continue;
		sys->print("fd %d %s\n", i, sys->fd2path(ref Sys->FD(i)));
	}
}

hold(file, text: string)
{
	fd := sys->open(file, Sys->ORDWR);
	if(fd == nil) {
		sys->print("hold: cannot open %s: %r\n", file);
		return;
	}
	sys->print("hold: open\n");
	buf := array[256] of byte;
	n := sys->read(sys->fildes(0), buf, len buf);
	if(text == "" && n > 0)
		text = string buf[0:n];
	b := array of byte text;
	if(sys->write(fd, b, len b) != len b) {
		sys->print("hold: write: %r\n");
		return;
	}
	r := array[8192] of byte;
	n = sys->pread(fd, r, len r, big 0);
	if(n < 0)
		sys->print("hold: read: %r\n");
	else
		sys->print("hold: result: %s\n", string r[0:n]);
}

ui(log: string)
{
	logfd = sys->create(log, Sys->OWRITE, 8r644);
	if(sys->bind("#s", "/mnt/ui", Sys->MBEFORE) < 0)
		raise sys->sprint("fail:bind #s: %r");
	fio := sys->file2chan("/mnt/ui", "ctl");
	if(fio == nil)
		raise sys->sprint("fail:file2chan: %r");
	# Activity 7 is there from a create to a delete, as the UI server's
	# list has one: the task tool takes the activity it made to be the
	# one that was not listed before its request.
	present := 0;
	for(;;) alt {
	(off, nil, nil, rc) := <-fio.read =>
		if(rc == nil)
			continue;
		data := array of byte "activities: 0\n";
		if(present)
			data = array of byte "activities: 0 7\n";
		if(off == 0)
			tasktoolns();
		if(off >= len data)
			rc <-= (nil, nil);
		else
			rc <-= (data[off:], nil);
	(nil, data, nil, wc) := <-fio.write =>
		if(wc == nil)
			continue;
		tasktoolns();
		req := string data;
		if(has(req, "activity create"))
			present = 1;
		else if(has(req, "activity delete"))
			present = 0;
		wc <-= (len data, nil);
	}
}

slurp(p: string): string
{
	fd := sys->open(p, Sys->OREAD);
	if(fd == nil)
		return "";
	s := "";
	buf := array[8192] of byte;
	while((n := sys->read(fd, buf, len buf)) > 0)
		s += string buf[0:n];
	return s;
}

has(s, sub: string): int
{
	for(i := 0; i + len sub <= len s; i++)
		if(s[i:i+len sub] == sub)
			return 1;
	return 0;
}

tasktoolns()
{
	pfd := sys->open("/prog", Sys->OREAD);
	if(pfd == nil)
		return;
	for(;;) {
		(c, d) := sys->dirread(pfd);
		if(c <= 0)
			break;
		for(i := 0; i < c; i++) {
			if(!has(slurp("/prog/" + d[i].name + "/status"), "ToolTask"))
				continue;
			if(has(slurp("/prog/" + d[i].name + "/ns"), ".veltro-ns/shadow"))
				sys->fprint(logfd, "restricted\n");
			else
				sys->fprint(logfd, "unrestricted\n");
		}
	}
}

say(s: string)
{
	if(logfd != nil)
		sys->fprint(logfd, "%d %s\n", sys->millisec(), s);
}

mkdir(d: string)
{
	fd := sys->create(d, Sys->OREAD, Sys->DMDIR | 8r755);
	fd = nil;
}

llm(dir, log: string)
{
	logfd = sys->create(log, Sys->OWRITE, 8r644);
	mkdir(dir);
	# new: a file of a #s of its own, bound over a file of the directory
	mkdir(dir + ".srv");
	if(sys->bind("#s", dir + ".srv", Sys->MREPL) < 0)
		raise sys->sprint("fail:bind #s: %r");
	newio := sys->file2chan(dir + ".srv", "new");
	if(newio == nil)
		raise sys->sprint("fail:file2chan new: %r");
	fd := sys->create(dir + "/new", Sys->OWRITE, 8r644);
	fd = nil;
	if(sys->bind(dir + ".srv/new", dir + "/new", Sys->MREPL) < 0)
		raise sys->sprint("fail:bind new: %r");
	for(i := 0; i < NSESS; i++) {
		sd := sys->sprint("%s/s%d", dir, i);
		mkdir(sd);
		if(sys->bind("#s", sd, Sys->MREPL) < 0)
			raise sys->sprint("fail:bind #s: %r");
		ask := sys->file2chan(sd, "ask");
		ctl := sys->file2chan(sd, "ctl");
		tools := sys->file2chan(sd, "tools");
		sysf := sys->file2chan(sd, "system");
		think := sys->file2chan(sd, "thinking");
		model := sys->file2chan(sd, "model");
		if(ask == nil || ctl == nil || tools == nil || sysf == nil || think == nil || model == nil)
			raise sys->sprint("fail:file2chan: %r");
		spawn session(i, ask);
		spawn ctlfile(i, ctl);
		spawn sink(tools);
		spawn sink(sysf);
		spawn sink(think);
		spawn sink(model);
	}
	say("ready");
	for(;;) alt {
	(off, nil, nil, rc) := <-newio.read =>
		if(rc == nil)
			continue;
		if(off != 0 || next >= NSESS) {
			rc <-= (nil, nil);
			continue;
		}
		id := sys->sprint("s%d", next++);
		say("new " + id);
		rc <-= (array of byte id, nil);
	(nil, data, nil, wc) := <-newio.write =>
		if(wc != nil)
			wc <-= (len data, nil);
	}
}

sink(f: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-f.read =>
		if(rc != nil)
			rc <-= (nil, nil);
	(nil, data, nil, wc) := <-f.write =>
		if(wc != nil)
			wc <-= (len data, nil);
	}
}

# A session's ctl, in a process of its own: its ask file may be in the
# middle of an answer that takes its time.
ctlfile(i: int, ctl: ref Sys->FileIO)
{
	for(;;) alt {
	(nil, nil, nil, rc) := <-ctl.read =>
		if(rc != nil)
			rc <-= (nil, nil);
	(nil, data, nil, wc) := <-ctl.write =>
		if(wc == nil)
			continue;
		say(sys->sprint("ctl s%d %s", i, string data));
		wc <-= (len data, nil);
	}
}

session(i: int, ask: ref Sys->FileIO)
{
	id := sys->sprint("s%d", i);
	scenario := "";
	step := 0;
	prompt := "";
	hist := "";
	answer: array of byte;
	for(;;) alt {
	(off, count, nil, rc) := <-ask.read =>
		if(rc == nil)
			continue;
		if(off == 0) {
			answer = array of byte reply(scenario, step, prompt, hist);
			say(sys->sprint("answer %s %d", id, step));
		}
		if(off >= len answer) {
			rc <-= (nil, nil);
			continue;
		}
		e := off + count;
		if(e > len answer)
			e = len answer;
		rc <-= (answer[off:e], nil);
	(nil, data, nil, wc) := <-ask.write =>
		if(wc == nil)
			continue;
		prompt = string data;
		if(scenario == "")
			scenario = word(prompt, "SCENARIO:");
		step++;
		if(step > 1)
			hist += prompt + "\n";
		say(sys->sprint("ask %s %d %s %s", id, step, scenario, resline(prompt)));
		wc <-= (len data, nil);
	}
}

# A tool result's first line of content, for the log: "res=..." or "".
resline(prompt: string): string
{
	key := "TOOL_RESULTS\n";
	if(len prompt < len key || prompt[0:len key] != key)
		return "";
	nl := 0;
	for(i := len key; i < len prompt; i++)
		if(prompt[i] == '\n') {
			nl++;
			if(nl == 1) {
				for(j := i + 1; j < len prompt && prompt[j] != '\n'; j++)
					;
				return "res=" + prompt[i+1:j];
			}
		}
	return "";
}

# The word after key in s, up to a blank.
word(s, key: string): string
{
	for(i := 0; i + len key <= len s; i++)
		if(s[i:i+len key] == key) {
			j := i + len key;
			for(k := j; k < len s && s[k] != ' ' && s[k] != '\n' && s[k] != '\t'; k++)
				;
			return s[j:k];
		}
	return "none";
}

tool(n: int, name, args: string): string
{
	return sys->sprint("STOP:tool_use\nTOOL:c%d:%s:%s\n", n, name, args);
}

# What the model says at its step'th request, in llmsrv's wire format: a
# tool call, or its last words.  The scenarios:
#	text	answers at once
#	slow	takes 30 seconds to answer
#	chatty	calls a tool every second and a half, for ever
#	tick	answers at once (a scheduled subagent's run)
#	ticktool	lists its scratch, then answers, at each run
#	probe	looks at /tool, /mnt and the model service with read and
#		list, then says what each call returned
#	big	answers with 3 MB
reply(scenario: string, step: int, prompt, hist: string): string
{
	case scenario {
	"slow" =>
		sys->sleep(30000);
		return "STOP:end_turn\nlate\n";
	"chatty" =>
		sys->sleep(1500);
		return tool(step, "list", "/tmp/veltro");
	"probe" =>
		calls := array[] of {
			("list", "/tool"),
			("read", "/tool/read/ctl"),
			("read", "/tool/paths"),
			("read", "/tool/tools"),
			("list", "/mnt"),
			("read", "/mnt/llm/new"),
			("list", "/prog"),
			("read", "/tool/meta/audit"),
		};
		if(step <= len calls) {
			(name, args) := calls[step - 1];
			return tool(step, name, args);
		}
		return "STOP:end_turn\nPROBE\n" + hist + "\nPROBE DONE\n";
	"ticktool" =>
		if(step % 2 == 1)
			return tool(step, "list", "/tmp/veltro/scratch");
		return "STOP:end_turn\ntick\n";
	"echo" =>
		if(step == 1)
			return tool(step, "read", word(prompt, "FILE:"));
		return "STOP:end_turn\nECHO " + prompt + "\n";
	"big" =>
		b := array[3*1024*1024] of {* => byte 'x'};
		return "STOP:end_turn\n" + string b + "\n";
	}
	return "STOP:end_turn\nanswer of " + scenario + "\n";
}
