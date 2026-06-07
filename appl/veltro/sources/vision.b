implement VisionSrc;

#
# vision - video-detection message source for msg9p (Jira INFR-286).
#
# Implements the MsgSrc interface: watches a vision9p detections stream
# (e.g. /mnt/vision/0/detections) and emits a structured Notification on each
# object appear/leave TRANSITION (not one per frame), so detections land on the
# same async mailbox as TAK chat and the agent reasons over them. The agent
# never sees pixels or detector internals — only structured Messages.
#
# Generic InferNode: turning a detection into a mailbox event lives here.
# NERVA policy (projecting bbox+pose to a ground coordinate and emitting a CoT
# marker back to TAK) lives in appl/nerva/ — see docs/ML-VISION-9P.md.
#
# Register with msg9p:
#   echo 'register vision /dis/veltro/sources/vision.dis /mnt/vision/0/detections' > /mnt/msg/ctl
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "daytime.m";
	daytime: Daytime;
include "msgsrc.m";

VisionSrc: module {
	init:    fn(config: string): string;
	name:    fn(): string;
	status:  fn(): string;
	close:   fn(): string;
	watch:   fn(updates: chan of ref MsgSrc->Notification, stop: chan of int): string;
	enumerate: fn(channel: string, count: int): (list of ref MsgSrc->Message, string);
	fetch:   fn(id: string): (ref MsgSrc->Message, string);
	search:  fn(query: string): (list of ref MsgSrc->Message, string);
	send:    fn(msg: ref MsgSrc->Message): string;
	reply:   fn(origid, body: string): string;
	setflag: fn(id: string, flag, add: int): string;
};

Message: import MsgSrc;
Notification: import MsgSrc;

detpath: string;
present := 0;			# is an object currently in view?
lastclass := "";
stderr: ref Sys->FD;

init(config: string): string
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	str = load String String->PATH;
	if(str == nil)
		return "cannot load String";
	daytime = load Daytime Daytime->PATH;	# optional (timestamps)

	(nil, toks) := sys->tokenize(config, " \t");
	if(toks != nil)
		detpath = hd toks;
	if(detpath == nil || detpath == "")
		return "config: detections path required (e.g. /mnt/vision/0/detections)";
	return nil;
}

name(): string   { return "vision"; }
status(): string { return sys->sprint("watching %s present=%d", detpath, present); }
close(): string  { return nil; }

# Push interface: stream detection records and emit on appear/leave transitions.
watch(updates: chan of ref Notification, stop: chan of int): string
{
	linec := chan of string;
	spawn linereader(detpath, linec);
	for(;;){
		alt {
		<-stop =>
			return nil;
		line := <-linec =>
			if(line == nil){
				updates <-= ref Notification("update", nil, "vision source ended");
				return nil;
			}
			m := transition(line);
			if(m != nil)
				updates <-= ref Notification("new", m, nil);
		}
	}
}

# Decide whether this detection record is an event worth surfacing.
transition(line: string): ref Message
{
	(det, cls, conf, x, y, w, h, frm, pts) := parseline(line);
	if(det && !present){
		present = 1;
		lastclass = cls;
		return mkmsg(frm, cls, sys->sprint("%s detected", cls),
			sys->sprint("vision: %s appeared (conf %s) at %s,%s %sx%s [frame %s %s]",
				cls, conf, x, y, w, h, frm, pts), line);
	}
	if(!det && present){
		present = 0;
		return mkmsg(frm, lastclass, sys->sprint("%s left", lastclass),
			sys->sprint("vision: %s left view [frame %s %s]", lastclass, frm, pts), line);
	}
	return nil;
}

# "frame N pts=Tms <class> <conf> <x> <y> <w> <h>"  or  "frame N pts=Tms none"
parseline(line: string): (int, string, string, string, string, string, string, string, string)
{
	(n, toks) := sys->tokenize(line, " \t");
	if(n < 4 || hd toks != "frame")
		return (0, "", "", "", "", "", "", "", "");
	t := tl toks;
	frm := hd t; t = tl t;		# N
	pts := hd t; t = tl t;		# pts=Tms
	cls := hd t;			# class or "none"
	if(cls == "none")
		return (0, "", "", "", "", "", "", frm, pts);
	t = tl t;
	conf := nextok(t); t = adv(t);
	x := nextok(t); t = adv(t);
	y := nextok(t); t = adv(t);
	w := nextok(t); t = adv(t);
	h := nextok(t);
	return (1, cls, conf, x, y, w, h, frm, pts);
}

nextok(t: list of string): string { if(t == nil) return ""; return hd t; }
adv(t: list of string): list of string { if(t == nil) return nil; return tl t; }

mkmsg(idn, sender, subject, body, raw: string): ref Message
{
	return ref Message(
		"vision-" + idn,	# id
		"vision",		# source
		"",			# channel
		sender,			# sender (the class)
		"",			# recipient
		subject,		# subject
		body,			# body
		isotime(),		# timestamp
		"",			# threadid
		"",			# replyto
		MsgSrc->FUNREAD,	# flags
		raw);			# headers (raw detection record)
}

isotime(): string
{
	if(daytime == nil)
		return "";
	tm := daytime->gmt(daytime->now());
	return sys->sprint("%04d-%02d-%02dT%02d:%02d:%02d.000Z",
		tm.year + 1900, tm.mon + 1, tm.mday, tm.hour, tm.min, tm.sec);
}

# Stream lines from a (possibly blocking) detections file onto linec; nil = end.
linereader(path: string, linec: chan of string)
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil){
		linec <-= nil;
		return;
	}
	buf := array[8192] of byte;
	tmp := array[1024] of byte;
	n := 0; pos := 0; m := 0;
	for(;;){
		if(pos >= n){
			n = sys->read(fd, buf, len buf);
			if(n <= 0){
				if(m > 0)
					linec <-= string tmp[0:m];
				linec <-= nil;
				return;
			}
			pos = 0;
		}
		c := buf[pos]; pos++;
		if(c == byte '\n'){
			linec <-= string tmp[0:m];
			m = 0;
		}else if(m < len tmp){
			tmp[m] = c;
			m++;
		}
	}
}

# --- pull/send/flag: detections are push-only; stubs ---
enumerate(nil: string, nil: int): (list of ref Message, string) { return (nil, nil); }
fetch(nil: string): (ref Message, string) { return (nil, nil); }
search(nil: string): (list of ref Message, string) { return (nil, nil); }
send(nil: ref Message): string { return "vision: send not supported"; }
reply(nil, nil: string): string { return "vision: reply not supported"; }
setflag(nil: string, nil, nil: int): string { return nil; }
