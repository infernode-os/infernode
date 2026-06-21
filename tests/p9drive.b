implement P9Drive;

#
# In-emu 9P scenario driver for the model-eval suite. Runs each scenario
# through InferNode llmsrv over the mounted /mnt/llm (the model/transport
# is abstracted behind 9P), emitting one JSON record per (scenario,run)
# for tests/model-eval/p9_score.py to grade with runner.py's logic.
#
# A wrapper (tests/p9run.sh) sets up networking and mounts the remote
# /mnt/llm before invoking this. Args:
#   p9drive.dis <model> <scenarios.json> <tools.json> <system.txt> <nruns>
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "json.m";
	json: JSON;
	JValue: import json;
include "wirefmt.m";
	wirefmt: WireFmt;

P9Drive: module { init: fn(nil: ref Draw->Context, args: list of string); };

stderr: ref Sys->FD;
out: ref Iobuf;
MAXTURNS: con 4;
toolsjson: string;
systemprompt: string;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	json = load JSON JSON->PATH;
	json->init(bufio);
	wirefmt = load WireFmt WireFmt->PATH;
	wirefmt->init();
	stderr = sys->fildes(2);
	out = bufio->fopen(sys->fildes(1), Bufio->OWRITE);

	args = tl args;
	model := hd args; args = tl args;
	scenfile := hd args; args = tl args;
	toolfile := hd args; args = tl args;
	sysfile := hd args; args = tl args;
	nruns := int hd args;

	toolsjson = readfile(toolfile);
	systemprompt = readfile(sysfile);
	scenstr := readfile(scenfile);

	sb := bufio->aopen(array of byte scenstr);
	(jv, err) := json->readjson(sb);
	if(jv == nil) { sys->fprint(stderr, "p9drive: parse scenarios: %s\n", err); return; }

	pick a := jv {
	Array =>
		for(i := 0; i < len a.a; i++) {
			s := a.a[i];
			name := jstr(s.get("name"));
			for(r := 1; r <= nruns; r++)
				runscenario(model, name, s, r);
		}
	* =>
		sys->fprint(stderr, "p9drive: scenarios.json not an array\n");
	}
	out.flush();
}

runscenario(model, name: string, s: ref JValue, run: int)
{
	id := strip(readfile("/mnt/llm/new"));
	if(id == "") { emiterror(model, name, run, "no session"); return; }
	base := "/mnt/llm/" + id;
	writefile(base + "/model", model);
	writefile(base + "/system", systemprompt);
	writefile(base + "/tools", toolsjson);

	# Setup turns: advance state, discard their calls.
	turns := s.get("turns");
	if(turns != nil) pick ta := turns {
	Array =>
		for(i := 0; i < len ta.a; i++) {
			t := ta.a[i];
			(nil, nil, nil, serr) := runturns(base, jstr(t.get("prompt")), jint(t.get("fail")));
			if(serr != "") { emiterror(model, name, run, serr); return; }
		}
	}

	# Probe turn: collect calls + content.
	(calls, content, finish, perr) := runturns(base, jstr(s.get("probe")), 0);
	if(perr != "") { emiterror(model, name, run, perr); return; }
	emit(model, name, run, calls, content, finish);
}

# One agent loop driven from `firstprompt`, feeding synthetic tool results
# until the model stops calling tools (or MAXTURNS). Returns the collected
# (name,args) calls, accumulated text content, finish string, and error.
runturns(base, firstprompt: string, fail: int): (list of (string, string), string, string, string)
{
	msg := firstprompt;
	calls: list of (string, string);
	content := "";
	finish := "end_turn";
	for(turn := 0; turn < MAXTURNS; turn++) {
		resp := ask(base, msg);
		if(hasprefix(resp, "Error:"))
			return (nil, "", "", strip(resp));
		(tcalls, text, istool) := parseresp(resp);
		if(text != "") {
			if(content != "")
				content += "\n";
			content += text;
		}
		for(tc := tcalls; tc != nil; tc = tl tc) {
			(nil, tn, targs) := hd tc;
			calls = (tn, targs) :: calls;
		}
		if(!istool) {
			finish = "end_turn";
			break;
		}
		finish = "tool_calls";
		# Feed synthetic results for every call this turn.
		tr := "TOOL_RESULTS\n";
		for(tc2 := tcalls; tc2 != nil; tc2 = tl tc2) {
			(tid, tn, targs) := hd tc2;
			tr += tid + "\n" + fakeresult(tn, targs, fail) + "\n---\n";
		}
		msg = tr;
	}
	return (revcalls(calls), content, finish, "");
}

# Parse an llmsrv response into (toolcalls, text, sawtooluse).
parseresp(resp: string): (list of (string, string, string), string, int)
{
	tcalls: list of (string, string, string);
	textparts: list of string;
	sawtool := 0;
	for(lines := splitlines(resp); lines != nil; lines = tl lines) {
		line := hd lines;
		if(line == "STOP:tool_use") { sawtool = 1; continue; }
		if(line == "STOP:end_turn") continue;
		if(hasprefix(line, "TOOL:")) {
			(tid, tn, targs) := wirefmt->parsetoolline(line[5:]);
			tcalls = (tid, tn, targs) :: tcalls;
			continue;
		}
		if(line != "")
			textparts = line :: textparts;
	}
	# restore order
	rt: list of (string, string, string);
	for(; tcalls != nil; tcalls = tl tcalls)
		rt = hd tcalls :: rt;
	return (rt, joinrev(textparts, "\n"), sawtool);
}

# Synthetic tool result — mirrors runner.py fake_tool_result.
fakeresult(name, argsjson: string, fail: int): string
{
	if(fail)
		return "error: simulated failure for testing - try a different argument shape";
	inner := getargs(argsjson);
	if(name == "present") {
		if(hasprefix(inner, "create")) return "created artifact";
		if(hasprefix(inner, "write")) return "wrote content to artifact";
		return "ok";
	}
	if(name == "launch")
		return "launched " + firstword(inner) + " app";
	if(name == "editor") {
		if(hasprefix(inner, "read")) {
			rest := strip(inner[4:]);
			if(rest == "" || rest == "body" || rest == "addr")
				return "Hello world";
			return "error: read target must be 'body' or 'addr'";
		}
		return "ok";
	}
	return "ok";
}

# --- llmsrv session I/O ---

ask(base, prompt: string): string
{
	writefile(base + "/ask", prompt);
	return readfile(base + "/ask");
}

# --- record emission (JSON via json module) ---

emit(model, name: string, run: int, calls: list of (string, string), content, finish: string)
{
	ncalls := 0;
	for(cc := calls; cc != nil; cc = tl cc) ncalls++;
	carr := array[ncalls] of ref JValue;
	i := 0;
	for(c := calls; c != nil; c = tl c) {
		(cn, ca) := hd c;
		carr[i++] = json->jvobject(("name", json->jvstring(cn)) :: ("args", json->jvstring(ca)) :: nil);
	}
	rec := json->jvobject(
		("model", json->jvstring(model)) ::
		("scenario", json->jvstring(name)) ::
		("run", json->jvint(run)) ::
		("calls", json->jvarray(carr)) ::
		("content", json->jvstring(content)) ::
		("finish", json->jvstring(finish)) :: nil);
	json->writejson(out, rec);
	out.puts("\n");
	out.flush();
}

emiterror(model, name: string, run: int, err: string)
{
	rec := json->jvobject(
		("model", json->jvstring(model)) ::
		("scenario", json->jvstring(name)) ::
		("run", json->jvint(run)) ::
		("calls", json->jvarray(array[0] of ref JValue)) ::
		("content", json->jvstring("")) ::
		("finish", json->jvstring("error")) ::
		("error", json->jvstring(err)) :: nil);
	json->writejson(out, rec);
	out.puts("\n");
	out.flush();
}

# --- helpers ---

jstr(v: ref JValue): string
{
	if(v == nil) return "";
	pick x := v { String => return x.s; }
	return "";
}

jint(v: ref JValue): int
{
	if(v == nil) return 0;
	pick x := v { Int => return int x.value; }
	return 0;
}

getargs(argsjson: string): string
{
	sb := bufio->aopen(array of byte argsjson);
	(jv, nil) := json->readjson(sb);
	if(jv == nil) return argsjson;
	return jstr(jv.get("args"));
}

firstword(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t')
			return s[0:i];
	return s;
}

readfile(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil) return "";
	s := "";
	buf := array[8192] of byte;
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0) break;
		s += string buf[0:n];
	}
	return s;
}

writefile(path, data: string)
{
	fd := sys->open(path, Sys->OWRITE);
	if(fd == nil) {
		sys->fprint(stderr, "p9drive: cannot open %s for write: %r\n", path);
		return;
	}
	d := array of byte data;
	sys->write(fd, d, len d);
}

splitlines(s: string): list of string
{
	lines: list of string;
	start := 0;
	for(i := 0; i < len s; i++) {
		if(s[i] == '\n') {
			line := s[start:i];
			if(len line > 0 && line[len line-1] == '\r')
				line = line[0:len line-1];
			lines = line :: lines;
			start = i + 1;
		}
	}
	if(start < len s)
		lines = s[start:] :: lines;
	# reverse
	r: list of string;
	for(; lines != nil; lines = tl lines)
		r = hd lines :: r;
	return r;
}

joinrev(parts: list of string, sep: string): string
{
	# parts is in reverse order; join in forward order
	r := "";
	first := 1;
	fwd: list of string;
	for(; parts != nil; parts = tl parts)
		fwd = hd parts :: fwd;
	for(; fwd != nil; fwd = tl fwd) {
		if(first) { r = hd fwd; first = 0; }
		else r += sep + hd fwd;
	}
	return r;
}

revcalls(c: list of (string, string)): list of (string, string)
{
	r: list of (string, string);
	for(; c != nil; c = tl c)
		r = hd c :: r;
	return r;
}

hasprefix(s, p: string): int
{
	return len s >= len p && s[0:len p] == p;
}

strip(s: string): string
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
		i++;
	j := len s;
	while(j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\n' || s[j-1] == '\r'))
		j--;
	if(i >= j) return "";
	return s[i:j];
}
