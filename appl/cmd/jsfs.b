implement Jsfs;

#
# jsfs - JavaScript realms as files (docs/JS-ENGINE.md §4.3).
#
#	jsfs [-D] [-m mountpoint]
#
# Mounted at /mnt/js by default:
#
#	clone		read: makes realm N, and gives "N\n"
#	N/ctl		read: "realm N"; write a line:
#				kill		end the realm (its directory goes)
#				stress n	collect after every n allocations (0: as usual)
#				profile ms	sample where it is every ms milliseconds (0: stop)
#	N/status	read: "idle" or "running", the scripts run, and the last error
#	N/console	read: what the realm's scripts printed (print, console.log), a
#			line each, from the read's offset (it grows)
#	N/eval		write a script (the write returns when it has run), then
#			read its value, or "error: ..."; mode 600: it is authority
#			to run code in the realm
#	N/profile	read: where the time went, by function, while profiling
#
# A realm is a module instance of the engine on a process of its own,
# so a script that runs long holds only its own realm: the write of eval
# is answered when the script has run, and kill ends it whatever it is
# doing.  A realm cannot import modules (that would read files in this
# server's namespace); its scripts reach nothing but what they print.
#
# Example:
#	n=`{cat /mnt/js/clone}
#	echo '[1, 2, 3].map(x => x * 2)' > /mnt/js/$n/eval
#	cat /mnt/js/$n/eval		# 2,4,6
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;
include "draw.m";
include "arg.m";
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Fid, Styxserver, Navigator, Navop: import styxservers;
	Enotfound, Eperm, Ebadarg: import styxservers;
include "jslex.m";
	jslex: Jslex;
include "jsparse.m";
	jsparse: Jsparse;
include "web/dom.m";
include "js.m";

Jsfs: module
{
	init:	fn(nil: ref Draw->Context, args: list of string);
};

Qroot, Qclone, Qrealm, Qctl, Qstatus, Qconsole, Qeval, Qprofile: con iota;

Realm: adt {
	id:	int;
	req:	chan of ref Req;
	pid:	int;
	running:	int;
	nrun:	int;
	lasterr:	string;
	console:	array of byte;
	result:	string;	# the last script's value, or "error: ..."
};

Req: adt {
	pick {
	Eval =>
		src:	string;
		tag:	int;
		n:	int;		# bytes written, for the reply
	Ctl =>
		line:	string;
		reply:	chan of string;
	Profile =>
		reply:	chan of string;
	Quit =>
	}
};

stderr: ref Sys->FD;
user: string;
srv: ref Styxserver;
realms: list of ref Realm;
nextid := 1;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	sys->pctl(Sys->FORKFD|Sys->NEWPGRP, nil);
	stderr = sys->fildes(2);
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	jslex = load Jslex Jslex->PATH;
	jsparse = load Jsparse Jsparse->PATH;
	arg := load Arg Arg->PATH;
	if(styx == nil || styxservers == nil || jslex == nil || jsparse == nil || arg == nil) {
		sys->fprint(stderr, "jsfs: cannot load modules: %r\n");
		raise "fail:load";
	}
	styx->init();
	styxservers->init(styx);
	jslex->init();
	jsparse->init();
	arg->init(args);
	mountpt := "/mnt/js";
	while((o := arg->opt()) != 0)
		case o {
		'D' =>
			styxservers->traceset(1);
		'm' =>
			mountpt = arg->earg();
		* =>
			sys->fprint(stderr, "usage: jsfs [-D] [-m mountpoint]\n");
			raise "fail:usage";
		}
	user = readfile("/dev/user");
	if(user == nil)
		user = "inferno";
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0) {
		sys->fprint(stderr, "jsfs: pipe: %r\n");
		raise "fail:pipe";
	}
	navops := chan of ref Navop;
	spawn navigator(navops);
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;
	pidc := chan of int;
	spawn serve(tchan, pidc, navops);
	<-pidc;
	(ok, nil) := sys->stat(mountpt);
	if(ok < 0)
		sys->create(mountpt, Sys->OREAD, Sys->DMDIR|8r755);
	if(sys->mount(fds[1], nil, mountpt, Sys->MREPL|Sys->MCREATE, nil) < 0) {
		sys->fprint(stderr, "jsfs: mount %s: %r\n", mountpt);
		raise "fail:mount";
	}
}

path(id, q: int): big
{
	return big ((id << 8) | q);
}

qtype(p: big): int
{
	return int p & 16rFF;
}

qid(p: big): int
{
	return (int p >> 8) & 16rFFFFFF;
}

find(id: int): ref Realm
{
	for(l := realms; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

serve(tchan: chan of ref Tmsg, pidc: chan of int, navops: chan of ref Navop)
{
	pidc <-= sys->pctl(Sys->FORKNS|Sys->NEWFD, 1 :: 2 :: srv.fd.fd :: nil);
Serve:
	while((gm := <-tchan) != nil) {
		pick m := gm {
		Readerror =>
			sys->fprint(stderr, "jsfs: read error: %s\n", m.error);
			break Serve;
		Read =>
			(c, err) := srv.canread(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(c.qtype & Sys->QTDIR) {
				srv.read(m);
				break;
			}
			r := find(qid(c.path));
			case qtype(c.path) {
			Qclone =>
				# one realm a read from the start (cat reads again for EOF)
				if(m.offset > big 0) {
					srv.reply(styxservers->readstr(m, ""));
					break;
				}
				r = newrealm();
				srv.reply(styxservers->readstr(m, string r.id + "\n"));
			Qctl =>
				if(r == nil)
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				else
					srv.reply(styxservers->readstr(m, "realm " + string r.id + "\n"));
			Qstatus =>
				if(r == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				st := "idle";
				if(r.running)
					st = "running";
				s := st + "\nscripts " + string r.nrun + "\n";
				if(r.lasterr != nil)
					s += "error " + r.lasterr + "\n";
				srv.reply(styxservers->readstr(m, s));
			Qconsole =>
				if(r == nil)
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				else
					srv.reply(styxservers->readbytes(m, r.console));
			Qeval =>
				if(r == nil)
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				else
					srv.reply(styxservers->readstr(m, r.result));
			Qprofile =>
				if(r == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Enotfound));
					break;
				}
				rc := chan of string;
				r.req <-= ref Req.Profile(rc);
				srv.reply(styxservers->readstr(m, <-rc));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Write =>
			(c, err) := srv.canwrite(m);
			if(c == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			r := find(qid(c.path));
			if(r == nil) {
				srv.reply(ref Rmsg.Error(m.tag, Enotfound));
				break;
			}
			case qtype(c.path) {
			Qeval =>
				# answered by the realm when the script has run
				r.req <-= ref Req.Eval(jslex->utf16(m.data), m.tag, len m.data);
			Qctl =>
				line := string m.data;
				if(len line > 0 && line[len line - 1] == '\n')
					line = line[0:len line - 1];
				(nil, toks) := sys->tokenize(line, " \t");
				if(toks != nil && hd toks == "kill") {
					killrealm(r);
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
					break;
				}
				rc := chan of string;
				r.req <-= ref Req.Ctl(line, rc);
				if((e := <-rc) != nil)
					srv.reply(ref Rmsg.Error(m.tag, e));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Eperm));
			}
		Clunk =>
			srv.clunk(m);
		* =>
			srv.default(gm);
		}
	}
	navops <-= nil;
}

newrealm(): ref Realm
{
	r := ref Realm(nextid++, chan of ref Req, 0, 0, 0, nil, nil, nil);
	pidc := chan of int;
	spawn realm(r, pidc);
	r.pid = <-pidc;
	realms = r :: realms;
	return r;
}

killrealm(r: ref Realm)
{
	fd := sys->open(sys->sprint("/prog/%d/ctl", r.pid), Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
	l: list of ref Realm;
	for(m := realms; m != nil; m = tl m)
		if(hd m != r)
			l = hd m :: l;
	realms = l;
}

realm(r: ref Realm, pidc: chan of int)
{
	pidc <-= sys->pctl(Sys->NEWPGRP, nil);
	js := load Js Js->PATH;
	err: string;
	if(js == nil)
		err = sys->sprint("cannot load %s: %r", Js->PATH);
	else
		err = js->init();
	if(err == nil) {
		js->setoutput(output);
		js->setloader(noload);
	}
	for(;;) {
		q := <-r.req;
		pick rq := q {
		Eval =>
			if(err != nil) {
				r.result = "error: " + err + "\n";
				srv.reply(ref Rmsg.Write(rq.tag, rq.n));
				continue;
			}
			r.running = 1;
			(v, e) := js->evalscript(rq.src, "eval");
			r.running = 0;
			r.nrun++;
			if(e != nil) {
				r.lasterr = e;
				r.result = "error: " + e + "\n";
			} else
				r.result = v + "\n";
			srv.reply(ref Rmsg.Write(rq.tag, rq.n));
		Ctl =>
			(nil, toks) := sys->tokenize(rq.line, " \t");
			if(toks == nil || err != nil) {
				rq.reply <-= "bad ctl";
				continue;
			}
			case hd toks {
			"stress" =>
				if(tl toks == nil) {
					rq.reply <-= "usage: stress n";
					continue;
				}
				js->stress(int hd tl toks);
				rq.reply <-= nil;
			"profile" =>
				if(tl toks == nil) {
					rq.reply <-= "usage: profile ms";
					continue;
				}
				js->profile(int hd tl toks);
				rq.reply <-= nil;
			* =>
				rq.reply <-= "unknown ctl: " + hd toks;
			}
		Profile =>
			if(err != nil)
				rq.reply <-= "";
			else
				rq.reply <-= js->profiled(30);
		Quit =>
			return;
		}
	}
}

# what a realm prints, kept in its console (Limbo has no closures: the
# realm is found by the process printing)
output(s: string)
{
	pid := sys->pctl(0, nil);
	for(l := realms; l != nil; l = tl l) {
		r := hd l;
		if(r.pid == pid) {
			b := array of byte (s + "\n");
			nc := array[len r.console + len b] of byte;
			nc[0:] = r.console;
			nc[len r.console:] = b;
			r.console = nc;
			return;
		}
	}
}

noload(nil, spec: string): (string, string, string)
{
	return (nil, nil, "cannot import " + spec + ": modules are not served here");
}

dir(p: big, name: string, perm: int): ref Sys->Dir
{
	d := ref sys->zerodir;
	t := Sys->QTFILE;
	if(perm & Sys->DMDIR)
		t = Sys->QTDIR;
	d.qid = Qid(p, 0, t);
	d.mode = perm;
	d.name = name;
	d.uid = user;
	d.gid = user;
	return d;
}

dirgen(p: big): (ref Sys->Dir, string)
{
	id := qid(p);
	case qtype(p) {
	Qroot =>	return (dir(p, "/", Sys->DMDIR|8r555), nil);
	Qclone =>	return (dir(p, "clone", 8r444), nil);
	}
	if(find(id) == nil)
		return (nil, Enotfound);
	case qtype(p) {
	Qrealm =>	return (dir(p, string id, Sys->DMDIR|8r555), nil);
	Qctl =>	return (dir(p, "ctl", 8r644), nil);
	Qstatus =>	return (dir(p, "status", 8r444), nil);
	Qconsole =>	return (dir(p, "console", 8r444), nil);
	Qeval =>	return (dir(p, "eval", 8r600), nil);
	Qprofile =>	return (dir(p, "profile", 8r444), nil);
	}
	return (nil, Enotfound);
}

realmfiles := array[] of {Qctl, Qstatus, Qconsole, Qeval, Qprofile};
realmnames := array[] of {"ctl", "status", "console", "eval", "profile"};

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);
		Walk =>
			id := qid(n.path);
			case qtype(n.path) {
			Qroot =>
				if(n.name == "..")
					;
				else if(n.name == "clone")
					n.path = path(0, Qclone);
				else if(find(int n.name) != nil && string int n.name == n.name)
					n.path = path(int n.name, Qrealm);
				else {
					n.reply <-= (nil, Enotfound);
					continue;
				}
			Qrealm =>
				if(n.name == "..")
					n.path = path(0, Qroot);
				else {
					for(i := 0; i < len realmnames; i++)
						if(realmnames[i] == n.name)
							break;
					if(i == len realmnames) {
						n.reply <-= (nil, Enotfound);
						continue;
					}
					n.path = path(id, realmfiles[i]);
				}
			* =>
				n.reply <-= (nil, "not a directory");
				continue;
			}
			n.reply <-= dirgen(n.path);
		Readdir =>
			ents: list of big;
			case qtype(m.path) {
			Qroot =>
				for(l := realms; l != nil; l = tl l)
					ents = path((hd l).id, Qrealm) :: ents;
				ents = path(0, Qclone) :: ents;
			Qrealm =>
				for(i := len realmfiles - 1; i >= 0; i--)
					ents = path(qid(m.path), realmfiles[i]) :: ents;
			}
			i := 0;
			for(; ents != nil; ents = tl ents) {
				if(i >= n.offset && n.count > 0) {
					n.reply <-= dirgen(hd ents);
					n.count--;
				}
				i++;
			}
			n.reply <-= (nil, nil);
		}
	}
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}
