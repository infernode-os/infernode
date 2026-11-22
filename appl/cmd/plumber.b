implement Plumber;

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;

include "sh.m";

include "regex.m";
	regex: Regex;

include "string.m";
	str: String;

include "plumbing.m";
	plumbing: Plumbing;
	Pattern, Rule: import plumbing;

include "plumbmsg.m";
	plumbmsg: Plumbmsg;
	Msg, Attr: import plumbmsg;

include "arg.m";

Plumber: module
{
	init:	fn(ctxt: ref Draw->Context, argl: list of string);
};

Input: adt
{
	inc:		chan of ref Inmesg;
	resc:		chan of int;
	io:		ref Sys->FileIO;
};

Output: adt
{
	name:	string;
	outc:		chan of string;
	io:		ref Sys->FileIO;
	queue:	list of array of byte;
	started:	int;
	startup:	string;
	waiting:	int;
	since:	int;		# when its reader last took a message, or the queue began
};

Port: adt
{
	name:		string;
	startup:	string;
	alwaysstart:	int;
};

Match: adt
{
	p0, p1:	int;
};

Inmesg: adt
{
	msg:		ref Msg;
	text:		string;	# if kind is text
	p0,p1:	int;
	match:	array of Match;
	port:		int;
	startup:	string;
	args:		list of string;
	attrs:		list of ref Attr;
	clearclick:	int;
	set:		int;
	# $ arguments
	_n:		array of string;
	_dir:		string;
	_file:		string;
};

# Message status after processing
HANDLED: con -1;
UNKNOWN: con -2;
NOTSTARTED: con -3;

output: array of ref Output;

input: ref Input;
rulesio: ref Sys->FileIO;

stderr: ref Sys->FD;
pgrp: int;
rules: list of ref Rule;
titlectl: chan of string;
ports: list of ref Port;
wmstartup := 0;
wmchan := "/chan/wm";
verbose := 0;

context: ref Draw->Context;

usage()
{
	sys->fprint(stderr, "Usage: plumb [-vw] [-c wmchan] [initfile ...]\n");
	raise "fail:usage";
}

init(ctxt: ref Draw->Context, args: list of string)
{
	context = ctxt;

	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	stderr = sys->fildes(2);

	regex = load Regex Regex->PATH;
	plumbing = load Plumbing Plumbing->PATH;
	str = load String String->PATH;

	err: string;
	nogrp := 0;

	arg := load Arg Arg->PATH;
	arg->init(args);
	while ((opt := arg->opt()) != 0) {
		case opt {
		'w' =>
			wmstartup = 1;
		'c' =>
			if ((wmchan = arg->arg()) == nil)
				usage();
		'v' =>
			verbose = 1;
		'n' =>
			nogrp = 1;
		* =>
			usage();
		}
	}
	args = arg->argv();
	arg = nil;

	(rules, err) = plumbing->init(regex, args);
	if(err != nil){
		sys->fprint(stderr, "plumb: %s\n", err);
		raise "fail:init";
	}

	plumbmsg = load Plumbmsg Plumbmsg->PATH;
	plumbmsg->init(0, nil, 0);

	# With -n the group is the caller's, and not the plumber's to kill:
	# shutdown wrote killgrp to it all the same, and a plumber that
	# could not make its files took its caller's shell with it.
	owngrp = !nogrp;
	if(nogrp)
		pgrp = sys->pctl(0, nil);
	else
		pgrp = sys->pctl(sys->NEWPGRP, nil);

	r := rules;
	for(i:=0; i<len rules; i++){
		rule := hd r;
		r = tl r;
		for(j:=0; j<len rule.action; j++)
			if(rule.action[j].pred == "to" || rule.action[j].pred == "alwaysstart"){
				p := findport(rule.action[j].arg);
				if(p == nil){
					p = ref Port(rule.action[j].arg, nil, rule.action[j].pred == "alwaysstart");
					ports = p :: ports;
				}
				for(k:=0; k<len rule.action; k++)
					if(rule.action[k].pred == "start")
						p.startup = rule.action[k].arg;
				break;
			}
	}

	input = ref Input;
	input.io = makefile("plumb.input");
	if(input.io == nil)
		shutdown();
	input.inc = chan of ref Inmesg;
	input.resc = chan of int;
	pidc := chan of int;
	spawn receiver(input, pidc);
	mine = <-pidc :: mine;
	
	rulesio = makefile("plumb.rules");
	if(rulesio == nil)
		shutdown();
	spawn rulesproc(rulesio, pidc);
	mine = <-pidc :: mine;

	output = array[len ports] of ref Output;

	pp := ports;
	for(i=0; i<len output; i++){
		p := hd pp;
		pp = tl pp;
		output[i] = ref Output;
		output[i].name = p.name;
		output[i].io = makefile("plumb."+p.name);
		if(output[i].io == nil)
			shutdown();
		output[i].outc = chan of string;
		output[i].started = 0;
		output[i].startup = p.startup;
		output[i].waiting = 0;
	}

	# spawn so we return without needing to run plumb in background
	spawn sender(input, output);
}

findport(name: string): ref Port
{
	for(p:=ports; p!=nil; p=tl p)
		if((hd p).name == name)
			return hd p;
	return nil;
}

makefile(file: string): ref Sys->FileIO
{
	io := sys->file2chan("/chan", file);
	if(io == nil){
		sys->fprint(stderr, "plumb: can't establish /chan/%s: %r\n", file);
		return nil;
	}
	return io;
}

receiver(input: ref Input, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);

	for(;;){
		(nil, msg, nil, wc) := <-input.io.write;
		if(wc == nil)
			;	# not interested in EOF; leave channel open
		else{
			# A message that is none, or a control message the plumber
			# has no name for, is refused: both were answered as sent.
			(in, perr) := parse(msg);
			if(perr != nil){
				wc <-= (0, perr);
				continue;
			}
			input.inc <-= in;
			res := <- input.resc;
			err := "";
			if(res == UNKNOWN)
				err = "no matching plumb rule";
			else if(res == NOTSTARTED)
				err = "no receiver and nothing to start";
			wc <-= (len msg, err);
		}
	}
}

sender(input: ref Input, output: array of ref Output)
{
	outputc := array[len output] of chan of (int, int, int, Sys->Rread);

	for(;;){
		alt{
		in := <-input.inc =>
			if(in == nil){
				input.resc <-= HANDLED;
				break;
			}
			# A fault in handling one message costs that message.  It
			# ended this proc, the one that answers every writer: each
			# write to plumb.input after it waited for ever.
			j := UNKNOWN;
			msg: array of byte;
			{
				(j, msg) = process(in);
			} exception e {
			"*" =>
				sys->fprint(stderr, "plumb: a message raised: %s\n", show(e));
				j = UNKNOWN;
			}
			case j {
			HANDLED =>
				break;
			UNKNOWN =>
				if(in.msg.src != "acme")
					sys->fprint(stderr, "plumb: don't know who message goes to\n");
			NOTSTARTED =>
				sys->fprint(stderr, "plumb: can't start application\n");
			* =>
				# no more than Maxqueue wait for a port's reader: the
				# oldest goes
				if(len output[j].queue >= Maxqueue){
					sys->fprint(stderr, "plumb: %d messages wait for port %s: the oldest is dropped\n", Maxqueue, output[j].name);
					output[j].queue = tl output[j].queue;
				}
				if(output[j].queue == nil)
					output[j].since = sys->millisec();
				output[j].queue = append(output[j].queue, msg);
				outputc[j] = output[j].io.read;
			}
			input.resc <-= j;
		
		(j, tmp) := <-outputc =>
			(nil, nbytes, nil, rc) := tmp;
			if(rc == nil)	# no interest in EOF
				break;
			msg := hd output[j].queue;
			# A message its reader has no room for is gone, with the
			# error.  It was left at the head of the queue, where the
			# next read met it again: every later message to the port
			# waited behind it for good.
			output[j].queue = tl output[j].queue;
			output[j].since = sys->millisec();
			if(output[j].queue == nil)
				outputc[j] = nil;
			if(nbytes < len msg){
				rc <-= (nil, "buffer too short for message");
				break;
			}
			log("sending \n");
			rc <-= (msg, nil);
		}
	}
}

readrules(crules: list of ref Rule): string
{
	s: string;
	buf: string;
	
	r := crules;
	for(i:=0; i<len crules; i++){
		rule := hd r;
		r = tl r;
		for (j:=0; j < len rule.pattern; j++){
			p := rule.pattern[j];
			if (p.field == "data" && p.pred == "matches")
				buf = sys->sprint("%s %s '%s'\n",p.field, p.pred, p.arg);
			else
				buf = sys->sprint("%s %s %q\n",p.field, p.pred, p.arg);
			if (buf == nil)
				return nil;
			s = s + buf;
		}
		
		for (k:=0; k< len rule.action; k++){
			a := rule.action[k];
			s += sys->sprint("%s %s %q %s", a.field, a.pred, a.arg, str->quoted(a.extra));
			s += "\n";
		}
		s += "\n";
	}
	return s;
}

updaterules(urules: list of ref Rule): list of ref Rule
{
	r: list of ref Rule;
	while(urules != nil){
		r = hd urules :: r;
		urules = tl urules;
	}
	# reverse the rules
	urules = nil;
	while(r != nil){
		urules = hd r :: urules;
		r = tl r;
	}
	return urules;
}

Maxqueue: con 256;	# messages waiting for one port's reader
Unread: con 5000;	# ms a message waits unread before its port is taken for unattended
Statwait: con 2000;	# ms a file named by a message is waited for
Clickback: con 2048;	# characters before a click a match may begin
Maxrules: con 256*1024;	# bytes of rules

rulesproc(rulesio: ref Sys->FileIO, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	wfid := -1;	# the fid whose writes are being gathered
	wtext: array of byte;
	for(;;){
		alt{
		(off, count, nil, rc) := <- rulesio.read =>
			if (rc == nil){	# no interest in EOF
				break;
			}
			data := readrules(rules);
			if (off > len data){
				rc <-= (nil, "");
				break;
			}			
			if (count < len data - off){
				rc <-= (nil, "buffer to short for message");
				break;
			}
			rc <-= (array of byte data[off:], nil);
			break;
			
		(off, data, fid, wc) := <-rulesio.write =>
			if(wc == nil){
				# its writer has closed it
				if(fid == wfid){
					wfid = -1;
					wtext = nil;
				}
				break;
			}
			# A rule set written in several writes is the writes
			# together.  Each write was a rule set by itself: of a
			# file longer than a write, the first piece became the
			# rules and the second was refused.
			if(fid == wfid && off == len wtext && off > 0){
				n := array[len wtext + len data] of byte;
				n[0:] = wtext;
				n[len wtext:] = data;
				wtext = n;
			}else
				wtext = data;
			wfid = fid;
			if(len wtext > Maxrules){
				wtext = nil;
				wfid = -1;
				wc <-= (0, "rules too long");
				break;
			}
			(urules, err) := plumbing->parse("/chan/plumb.rules", string wtext);
			if(err != nil){
				wc <-= (0, err);
				break;
			}
			rules = updaterules (urules);
			wc <-= (len data, "");
			break;
		}
	}
}

# (the message, nil), (nil, nil) for a control message done, or (nil, why
# it is refused)
parse(a: array of byte): (ref Inmesg, string)
{
	msg := Msg.unpack(a);
	if(msg == nil)
		return (nil, "not a plumb message");
	i := ref Inmesg;
	i.msg = msg;
	if(msg.dst != nil){
		(isctl, cerr) := control(i);
		if(isctl)
			return (nil, cerr);
		toport(i, msg.dst);
	}else
		i.port = -1;
	i.match = array[10] of { * => Match(-1, -1)};
	i._n = array[10] of string;
	i.attrs = plumbmsg->string2attrs(i.msg.attr);
	return (i, nil);
}

append(l: list of array of byte, a: array of byte): list of array of byte
{
	if(l == nil)
		return a :: nil;
	return hd l :: append(tl l, a);
}

owngrp := 1;	# the process group is the plumber's own (no -n)
mine: list of int;	# its procs started before it serves

shutdown()
{
	if(owngrp){
		fname := sys->sprint("#p/%d/ctl", pgrp);
		if((fdesc := sys->open(fname, sys->OWRITE)) != nil)
			sys->write(fdesc, array of byte "killgrp\n", 8);
	}else{
		# only what this plumber started
		for(; mine != nil; mine = tl mine)
			if((fd := sys->open(sys->sprint("#p/%d/ctl", hd mine), Sys->OWRITE)) != nil)
				sys->fprint(fd, "kill");
	}
	raise "fail:error";
}

# text of a message's, for a diagnostic: what can be shown, and no more
# than a line of it.  It went to the plumber's standard error and log
# as it came, control characters and all, at any length.
show(s: string): string
{
	r := "";
	for(i := 0; i < len s && i < 120; i++){
		c := s[i];
		if(c < ' ' || c == 16r7f || c >= 16r80 && c < 16ra0)
			c = '?';
		r[len r] = c;
	}
	if(i < len s)
		r += "...";
	return r;
}

# Handle control messages: (it was one, why it is refused)
control(in: ref Inmesg): (int, string)
{
	msg := in.msg;
	if(msg.kind!="text" || msg.dst!="plumb")
		return (0, nil);
	text := string msg.data;
	case text {
	"start" =>
		start(msg.src, 1);
	"stop" =>
		start(msg.src, -1);
	* =>
		return (1, "unrecognized control message");
	}
	return (1, nil);
}

start(port: string, startstop: int)
{
	for(i:=0; i<len output; i++)
		if(port == output[i].name){
			output[i].waiting = 0;
			if(startstop == -1){
				output[i].started = 0;
				# if a process stopped we might have to flush
				# the output because there may already be a read
				# waiting. really the read should be flushed, and the
				# file2chan should handle it.
			}else
				output[i].started += startstop;
			return;
		}
	sys->fprint(stderr, "plumb: \"start\" message from unrecognized port %s\n", show(port));
}

startup(dir, prog: string, args: list of string, wait: chan of int)
{
	if(wmstartup){
		# With -w the window manager starts programs, or nothing does.
		# When its file could not be opened the plumber went on to
		# start the program itself, in its own name space and group.
		fd := sys->open(wmchan, Sys->OWRITE);
		if(fd == nil || sys->fprint(fd, "s %s", str->quoted(dir :: prog :: args)) < 0){
			sys->fprint(stderr, "plumb: %s: %r: %s is not started\n", wmchan, show(prog));
			wait <-= 0;
			return;
		}
		wait <-= 1;
		return;
	}

	sys->pctl(Sys->NEWFD|Sys->NEWPGRP|Sys->FORKNS, list of {0, 1, 2});
	# Loaded before the plumber is told it has started.  It was told
	# first: a program that could not be loaded left its port waiting
	# for a start that never came, every later message to it queued
	# for good and nothing ever started for it again.
	mod := load Command prog;
	if(mod == nil){
		sys->fprint(stderr, "plumb: can't load %s: %r\n", show(prog));
		wait <-= 0;
		return;
	}
	wait <-= 1;
	wait = nil;
	sys->chdir(dir);
	mod->init(context, prog :: args);
}

# See if messages should be queued while waiting for program to connect
shouldqueue(out: ref Output): int
{
	p := findport(out.name);
	if(p == nil){
		sys->fprint(stderr, "plumb: can't happen in shouldqueue\n");
		return 0;
	}
	if(p.alwaysstart)
		return 0;
	return out.waiting;	
}

# Determine destination of input message, reformat for output
process(in: ref Inmesg): (int, array of byte)
{
	if(!clarify(in))
		return (UNKNOWN, nil);
	if(in.port < 0)
		return (UNKNOWN, nil);
	a := in.msg.pack();
	j := in.port;
	# A port said to be started, or being started, whose messages
	# nobody reads is not attended.  "start" is the word of whoever
	# writes it, with any port's name as its source: after one, every
	# message to the port was queued as delivered and its program
	# never started (as after a reader that went without "stop", or a
	# program started that never came to read).
	if(a != nil && output[j].queue != nil && sys->millisec() - output[j].since > Unread){
		output[j].started = 0;
		output[j].waiting = 0;
	}
	if(a == nil)
		j = UNKNOWN;
	else if(output[j].started==0 && !shouldqueue(output[j])){
		path: string;
		args: list of string;
		if(in.startup!=nil){
			path = macro(in, in.startup);
			args = expand(in, in.args);
		}else if(output[j].startup != nil){
			path = output[j].startup;
			args = in.text :: nil;
		}else
			return (NOTSTARTED, nil);
		log(sys->sprint("start %s port %s\n", show(path), output[j].name));
		wait := chan of int;
		output[j].waiting = 1;
		spawn startup(in.msg.dir, path, args, wait);
		if(<-wait == 0){
			output[j].waiting = 0;
			return (NOTSTARTED, nil);
		}
		return (HANDLED, nil);
	}else{
		if(in.msg.kind != "text")
			text := sys->sprint("message of type %s", in.msg.kind);
		else{
			text = in.text;
			for(i:=0; i<len text; i++){
				if(text[i]=='\n'){
					text = text[0:i];
					break;
				}
				if(i > 50) {
					text = text[0:i]+"...";
					break;
				}
			}
		}
		log(sys->sprint("send \"%s\" to %s", show(text), output[j].name));
	}
	return (j, a);
}

# expand $arguments
expand(in: ref Inmesg, args: list of string): list of string
{
	a: list of string;
	while(args != nil){
		a = macro(in, hd args) :: a;
		args = tl args;
	}
	while(a != nil){
		args = hd a :: args;
		a = tl a;
	}
	return args;
}

# resolve all ambiguities, fill in any missing fields
clarify(in: ref Inmesg): int
{
	in.clearclick = 0;
	in.set = 0;
	msg := in.msg;
	if(msg.kind != "text")
		return 0;
	in.text = string msg.data;
	if(msg.dst != "")
		return 1;
	return dorules(in, rules);
}

dorules(in: ref Inmesg, rules: list of ref Rule): int
{
	if (verbose)
		log("msg: " + inmesg2s(in));
	for(r:=rules; r!=nil; r=tl r) {
		# A rule that does not match leaves the message as it found
		# it.  What its patterns had done before the one that failed
		# stayed: a "data set", a file found by isfile, the pieces of
		# a match, were the next rule's to start from.
		saved := save(in);
		if(matchrule(in, hd r)){
			applyrule(in, hd r);
			if (verbose)
				log("yes");
			return 1;
		} else if (verbose)
			log("no");
		restore(in, saved);
	}
	return 0;
}

Saved: adt {
	src, dst, dir, kind, attr:	string;
	data:	array of byte;
	text:	string;
	set:	int;
	n:	array of string;
	_dir, _file:	string;
};

save(in: ref Inmesg): ref Saved
{
	m := in.msg;
	n := array[len in._n] of string;
	n[0:] = in._n;
	return ref Saved(m.src, m.dst, m.dir, m.kind, m.attr, m.data, in.text, in.set, n, in._dir, in._file);
}

restore(in: ref Inmesg, s: ref Saved)
{
	m := in.msg;
	(m.src, m.dst, m.dir, m.kind, m.attr, m.data) = (s.src, s.dst, s.dir, s.kind, s.attr, s.data);
	in.text = s.text;
	in.set = s.set;
	in._n = s.n;
	in._dir = s._dir;
	in._file = s._file;
}

# A file a message names, asked of whatever serves it, in a proc of its
# own with Statwait to answer.  It was asked by the proc that handles
# every message: a name on a server that does not answer (a mount gone
# quiet, of the sender's choosing) stopped the plumber for good.
statfile(name: string): (int, Sys->Dir)
{
	c := chan[1] of (int, Sys->Dir);
	pidc := chan of int;
	spawn statproc(name, c, pidc);
	pid := <-pidc;
	tc := chan[1] of int;
	spawn timer(tc, Statwait);
	alt {
	r := <-c =>
		return r;
	<-tc =>
		if((fd := sys->open(sys->sprint("#p/%d/ctl", pid), Sys->OWRITE)) != nil)
			sys->fprint(fd, "kill");
		sys->fprint(stderr, "plumb: %s: no answer in %d seconds\n", show(name), Statwait/1000);
	}
	return (-1, sys->zerodir);
}

statproc(name: string, c: chan of (int, Sys->Dir), pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	c <-= sys->stat(name);
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

inmesg2s(in: ref Inmesg): string
{
	m := in.msg;
	s := sys->sprint("src=%s; dst=%s; dir=%s; kind=%s; attr='%s'",
			show(m.src), show(m.dst), show(m.dir), show(m.kind), show(m.attr));
	if (m.kind == "text")
		s += "; data='" + show(string m.data) + "'";
	return s;
}

matchrule(in: ref Inmesg, r: ref Rule): int
{
	pats := r.pattern;
	for(i:=0; i<len in.match; i++)
		in.match[i] = (-1,-1);
	# no rules at all implies success, so return if any fail
	for(i=0; i<len pats; i++)
		if(matchpattern(in, pats[i]) == 0)
			return 0;
	return 1;
}

applyrule(in: ref Inmesg, r: ref Rule)
{
	acts := r.action;
	for(i:=0; i<len acts; i++)
		applypattern(in, acts[i]);
	if(in.clearclick){
		al: list of ref Attr;
		for(l:=in.attrs; l!=nil; l=tl l)
			if((hd l).name != "click")
				al = hd l :: al;
		in.attrs = al;
		in.msg.attr = plumbmsg->attrs2string(al);
		if(in.set){
			in.text = macro(in, "$0");
			in.msg.data = array of byte in.text;
		}
	}
}

matchpattern(in: ref Inmesg, p: ref Pattern): int
{
	msg := in.msg;
	text: string;
	case p.field {
	"src" =>	text = msg.src;
	"dst" =>	text = msg.dst;
	"dir" =>	text = msg.dir;
	"kind" =>	text = msg.kind;
	"attr" =>	text = msg.attr;
	"data" =>	text = in.text;
	* =>
		sys->fprint(stderr, "plumb: don't recognize pattern field %s\n", p.field);
		return 0;
	}
	if (verbose)
		log(sys->sprint("'%s' %s '%s'\n", show(text), p.pred, p.arg));
	case p.pred {
	"is" =>
		return text == p.arg;
	"isfile" or "isdir" =>
		text = p.arg;
		if(p.expand)
			text = macro(in, text);
		if(len text == 0)
			return 0;
		if(len in.msg.dir!=0 && text[0] != '/' && text[0]!='#')
			text = in.msg.dir+"/"+text;
		text = cleanname(text);
		(ok, dir) := statfile(text);
		if(ok < 0)
			return 0;
		if(p.pred=="isfile" && (dir.mode&Sys->DMDIR)==0){
			in._file = text;
			return 1;
		}
		if(p.pred=="isdir" && (dir.mode&Sys->DMDIR)!=0){
			in._dir = text;
			return 1;
		}
		return 0;
	"matches" =>
		(clickspecified, val) := plumbmsg->lookup(in.attrs, "click");
		if(p.field != "data")
			clickspecified = 0;
		if(!clickspecified){
			# easy case. must match whole string
			matches := regex->execute(p.regex, text);
			if(matches == nil)
				return 0;
			(p0, p1) := matches[0];
			if(p0!=0 || p1!=len text)
				return 0;
			in.match = matches;
			setvars(in, text);
			return 1;
		}
		matches := clickmatch(p.regex, text, int val);
		if(matches == nil)
			return 0;
		(p0, p1) := matches[0];
		# assumes all matches are in same sequence
		if(in.match[0].p0 != -1)
			return p0==in.match[0].p0 && p1==in.match[0].p1;
		in.match = matches;
		setvars(in, text);
#		in.clearclick = 1;
#		in.set = 1;
		return 1;
	"set" =>
		text = p.arg;
		if(p.expand)
			text = macro(in, text);
		case p.field {
		"src" =>	msg.src = text;
		"dst" =>	msg.dst = text;
		"dir" =>	msg.dir = text;
		"kind" =>	msg.kind = text;
		"attr" =>	msg.attr = text;
		"data" =>	in.text = text;
				msg.data = array of byte text;
				msg.kind = "text";
				in.set = 0;
		}
		return 1;
	* =>
		sys->fprint(stderr, "plumb: don't recognize pattern predicate %s\n", p.pred);
	}
	return 0;
}

applypattern(in: ref Inmesg, p: ref Pattern): int
{
	if(p.field != "plumb"){
		sys->fprint(stderr, "plumb: don't recognize action field %s\n", p.field);
		return 0;
	}
	case p.pred {
	"to" or "alwaysstart" =>
		if(in.port >= 0)	# already specified
			return 1;
		toport(in, p.arg);
	"start" =>
		in.startup = p.arg;
		in.args = p.extra;
	* =>
		sys->fprint(stderr, "plumb: don't recognize action %s\n", p.pred);
	}
	return 1;
}

toport(in: ref Inmesg, name: string): int
{
	for(i:=0; i<len output; i++)
		if(name == output[i].name){
			in.msg.dst = name;
			in.port = i;
			return i;
		}
	in.port = -1;
	sys->fprint(stderr, "plumb: unrecognized port %s\n", show(name));
	return -1;
}

# simple heuristic: look for leftmost match that reaches click position
clickmatch(re: ref Regex->Arena, text: string, click: int): array of Match
{
	# A match that reaches the click begins near it.  Every start from
	# the text's first character was tried, the expression run from
	# each: a long text with a click near its end kept the plumber
	# from everyone for as long as that took.
	i := click - Clickback;
	if(i < 0)
		i = 0;
	for(; i<=click && i < len text; i++){
		matches := regex->executese(re, text, (i, -1), i == 0, 1);
		if(matches == nil)
			continue;
		(p0, p1) := matches[0];
		
		if(p0>=i && p1>=click)
			return matches;
	}
	return nil;
}

setvars(in: ref Inmesg, text: string)
{
	for(i:=0; i<len in.match && in.match[i].p0>=0; i++)
		in._n[i] = text[in.match[i].p0:in.match[i].p1];
	for(; i<len in._n; i++)
		in._n[i] = "";
}

macro(in: ref Inmesg, text: string): string
{
	word := "";
	i := 0;
	j := 0;
	for(;;){
		if(i == len text)
			break;
		if(text[i++] != '$')
			continue;
		if(i == len text)
			break;
		word += text[j:i-1];
		(res, skip) := dollar(in, text[i:]);
		word += res;
		i += skip;
		j = i;
	}
	if(j < len text)
		word += text[j:];
	return word;
}

dollar(in: ref Inmesg, text: string): (string, int)
{
	if(text[0] == '$')
		return ("$", 1);
	if('0'<=text[0] && text[0]<='9')
		return (in._n[text[0]-'0'], 1);
	if(len text < 3)
		return ("$", 0);
	case text[0:3] {
	"src" =>	return (in.msg.src, 3);
	"dst" =>	return (in.msg.dst, 3);
	"dir" =>	return (in._dir, 3);
	}
	if(len text< 4)
		return ("$", 0);
	case text[0:4] {
	"attr" =>	return (in.msg.attr, 4);
	"data" =>	return (in.text, 4);
	"file" =>	return (in._file, 4);
	"kind" =>	return (in.msg.kind, 4);
	}
	return ("$", 0);
}

# compress ../ references and do other cleanups
cleanname(name: string): string
{
	# compress multiple slashes
	n := len name;
	for(i:=0; i<n-1; i++)
		if(name[i]=='/' && name[i+1]=='/'){
			name = name[0:i]+name[i+1:];
			--i;
			n--;
		}
	#  eliminate ./
	for(i=0; i<n-1; i++)
		if(name[i]=='.' && name[i+1]=='/' && (i==0 || name[i-1]=='/')){
			name = name[0:i]+name[i+2:];
			--i;
			n -= 2;
		}
	found: int;
	do{
		# compress xx/..
		found = 0;
		for(i=1; i<=n-3; i++)
			if(name[i:i+3] == "/.."){
				if(i==n-3 || name[i+3]=='/'){
					found = 1;
					break;
				}
			}
		if(found)
			for(j:=i-1; j>=0; --j)
				if(j==0 || name[j-1]=='/'){
					i += 3;		# character beyond ..
					if(i<n && name[i]=='/')
						++i;
					name = name[0:j]+name[i:];
					n -= (i-j);
					break;
				}
	}while(found);
	# eliminate trailing .
	if(n>=2 && name[n-2]=='/' && name[n-1]=='.')
		--n;
	if(n == 0)
		return ".";
	if(n != len name)
		name = name[0:n];
	return name;
}

log(s: string)
{
	if(len s == 0)
		return;
	if(s[len s-1] != '\n')
		s[len s] = '\n';
	sys->print("plumb: %s", s);
}
