implement Gpsfs;

#
# gpsfs - a GPS receiver as files, at /mnt/gps.
#
# A receiver speaks NMEA 0183 over a byte stream: a serial port
# ('#t/eia0', a USB puck the host enumerates there), a phone's own
# location service ('#g/nmea', location(3)), a network feed (a phone
# app serving NMEA over TCP, gpsd), a recorded log.  gpsfs reads
# one such source, assembles its sentences into fixes (nmea(2)), and
# serves what it knows:
#
#   ctl         (rw) write one command:
#                      source <path> [baud]   a file or serial port;
#                                             baud is written to <path>ctl
#                      source <net!host!port> a network feed of NMEA
#                      source gpsd <host[!port]>  gpsd, in its NMEA mode
#                      replay <path>          a log, paced by its times
#                      stop
#                    a source is open (or refused, with the reason) when
#                    the write returns; a read gives the command in use.
#   status      (r)  state=fix|nofix|nosource link=none|open|closed|error
#                    source=... sentences=N bad=N age=S error='...'
#   position    (r)  "lat lon", decimal degrees; "no fix" is an error
#   fix         (r)  the last fix, attr=value: time lat lon alt speed
#                    course mode q sats hdop vdop pdop err verr, each
#                    there only when known (see nmea(2) for units)
#   event       (r)  each read waits for the next fix and gives it, as
#                    fix does, or the fixes since the last read; every
#                    open has its own
#   satellites  (r)  one line a satellite in view:
#                    system prn elevation azimuth snr used
#   nmea        (r)  the sentences, as received, from the open on;
#                    each read waits for more
#   feed        (w)  sentences written here are taken as the receiver's
#
# Reading and commanding are separate files so that access is decided by
# what is bound, not by checks here: a process given position, fix,
# event, satellites and nmea can follow the receiver; only one given
# ctl or feed can change what it says.  feed is how anything without a
# byte stream (a test, a position from elsewhere) supplies sentences;
# it puts a position in, so it is not bound where position is merely
# read.
#
# The server opens sources in the name space it was started in.
#
# Usage:	gpsfs [-m mountpoint] [command ...]
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "arg.m";

include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import styx;

include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Navop: import styxservers;

include "nmea.m";
	nmea: Nmea;
	Fix, Parser: import nmea;

Gpsfs: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qctl, Qstatus, Qposition, Qfix, Qevent, Qsatellites, Qnmea, Qfeed: con big iota;

files := array[] of {
	("ctl", 8r660),
	("status", 8r444),
	("position", 8r444),
	("fix", 8r444),
	("event", 8r444),
	("satellites", 8r444),
	("nmea", 8r444),
	("feed", 8r220),
};

Maxqueue: con 64*1024;	# what a reader of event or nmea has not read
Maxline: con 1024;

# what a reader proc reports
Iopen, Iline, Iend: con iota;
Input: adt {
	gen:	int;
	kind:	int;
	line:	string;
	err:	string;
};

# an open of event, nmea or feed
Client: adt {
	fid:	int;
	path:	big;
	pending:	string;		# event: fixes not read; nmea: sentences not read
	rd:	ref Tmsg.Read;	# a read waiting
	partial:	string;		# feed: a line not ended
};

# what the server knows, apart from its source
State: adt {
	srv:	ref Styxserver;
	p:	ref Parser;
	clients:	list of ref Client;
	sentences:	int;
	bad:	int;
	lastfix:	int;	# sys->millisec() of the last fix, or -1

	take:	fn(st: self ref State, line: string): string;
};

# a source command
Source: adt {
	cmd:	string;		# as read back from ctl
	verb:	string;		# file dial gpsd replay
	addr:	string;
	baud:	string;
};

user := "gps";
stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nmea = load Nmea Nmea->PATH;
	if(arg == nil || styx == nil || styxservers == nil || nmea == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	styx->init();
	styxservers->init(styx);
	nmea->init();

	mnt := "/mnt/gps";
	arg->init(argv);
	arg->setusage("gpsfs [-m mountpoint] [command ...]");
	while((o := arg->opt()) != 0)
		case o {
		'm' =>
			mnt = arg->earg();
		* =>
			arg->usage();
		}
	cmd := "";
	for(argv = arg->argv(); argv != nil; argv = tl argv)
		cmd += " " + hd argv;

	if(sys->stat(mnt + "/feed").t0 >= 0)
		fatal(mnt + " is served already");
	if(sys->stat(mnt).t0 < 0)
		sys->create(mnt, Sys->OREAD, Sys->DMDIR|8r775);	# mount says if it fails
	if((u := readfile("/dev/user")) != nil)
		user = u;

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		fatal(sys->sprint("pipe: %r"));
	navops := chan of ref Navop;
	spawn navigator(navops);
	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), Qroot);
	fds[0] = nil;
	pidc := chan of int;
	spawn server(tchan, srv, navops, pidc);
	<-pidc;
	if(sys->mount(fds[1], nil, mnt, Sys->MREPL, nil) < 0)
		fatal(sys->sprint("mount %s: %r", mnt));
	fds[1] = nil;

	if(cmd != nil) {
		fd := sys->open(mnt + "/ctl", Sys->OWRITE);
		if(fd == nil || sys->fprint(fd, "%s", cmd[1:]) < 0)
			fatal(sys->sprint("%s: %r", cmd[1:]));
	}
}

fatal(s: string)
{
	sys->fprint(stderr, "gpsfs: %s\n", s);
	raise "fail:" + s;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

#
# The server: one proc owns all the state, so nothing is locked.
# Sentences arrive from the reader proc of the current source (on
# inputc, marked with the source's generation, so a stopped source's
# last lines are dropped) and from writes of feed.
#
server(tchan: chan of ref Tmsg, srv: ref Styxserver, navops: chan of ref Navop, pidc: chan of int)
{
	# a name space and fds of its own, made before the mount: the
	# server never finds itself when it opens a source
	pidc <-= sys->pctl(Sys->NEWFD|Sys->FORKNS, srv.fd.fd :: 2 :: nil);
	stderr = sys->fildes(2);

	st := ref State(srv, Parser.new(), nil, 0, 0, -1);
	inputc := chan of ref Input;
	gen := 0;
	readerpid := -1;
	src: ref Source;
	link := "none";
	srcerr := "";
	ctlwait: ref Tmsg.Write;	# a source command waiting for its open
	waitsrc: ref Source;

Serve:
	for(;;) alt {
	in := <-inputc =>
		if(in.gen != gen)
			break;
		case in.kind {
		Iopen =>
			if(in.err != nil) {
				link = "error";
				srcerr = in.err;
				readerpid = -1;
				if(ctlwait != nil)
					srv.reply(ref Rmsg.Error(ctlwait.tag, in.err));
			} else {
				link = "open";
				srcerr = "";
				src = waitsrc;
				if(ctlwait != nil)
					srv.reply(ref Rmsg.Write(ctlwait.tag, len ctlwait.data));
			}
			ctlwait = nil;
			waitsrc = nil;
		Iline =>
			if(len in.line > 0 && in.line[0] == '$')
				st.take(in.line);
		Iend =>
			readerpid = -1;
			if(in.err != nil) {
				link = "error";
				srcerr = in.err;
			} else
				link = "closed";
		}

	gm := <-tchan =>
		if(gm == nil)
			break Serve;
		pick m := gm {
		Readerror =>
			break Serve;
		Open =>
			f := srv.open(m);
			if(f != nil && (f.path == Qevent || f.path == Qnmea || f.path == Qfeed))
				st.clients = ref Client(m.fid, f.path, nil, nil, nil) :: st.clients;
		Read =>
			(f, err) := srv.canread(m);
			if(f == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			case f.path {
			Qctl =>
				s := "";
				if(src != nil)
					s = src.cmd + "\n";
				srv.reply(styxservers->readstr(m, s));
			Qstatus =>
				state := "nofix";
				if(st.p.last != nil && st.p.last.valid && st.p.last.haspos)
					state = "fix";
				else if(src == nil && st.sentences == 0)
					state = "nosource";
				s := "state=" + state + " link=" + link;
				if(src != nil)
					s += " source=" + quote(src.addr);
				s += sys->sprint(" sentences=%d bad=%d", st.sentences, st.bad);
				if(st.lastfix >= 0)
					s += sys->sprint(" age=%.1f", real (sys->millisec() - st.lastfix) / 1000.0);
				if(srcerr != nil)
					s += " error=" + quote(srcerr);
				srv.reply(styxservers->readstr(m, s + "\n"));
			Qposition =>
				pos: string;
				if(st.p.last != nil)
					pos = st.p.last.position();
				if(pos == nil)
					srv.reply(ref Rmsg.Error(m.tag, "no fix"));
				else
					srv.reply(styxservers->readstr(m, pos + "\n"));
			Qfix =>
				s := "";
				if(st.p.last != nil)
					s = st.p.last.text() + "\n";
				srv.reply(styxservers->readstr(m, s));
			Qsatellites =>
				srv.reply(styxservers->readstr(m, st.p.satellites()));
			Qevent or Qnmea =>
				c := client(st.clients, m.fid);
				if(c == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadfid));
					break;
				}
				if(c.rd != nil) {
					srv.reply(ref Rmsg.Error(m.tag, "a read is already waiting"));
					break;
				}
				c.rd = m;
				streamreply(srv, c);
			* =>
				srv.read(m);
			}
		Write =>
			(f, err) := srv.canwrite(m);
			if(f == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			case f.path {
			Qctl =>
				if(ctlwait != nil) {
					srv.reply(ref Rmsg.Error(m.tag, "busy: a source is opening"));
					break;
				}
				(s, perr) := parsecmd(string m.data);
				if(perr != nil) {
					srv.reply(ref Rmsg.Error(m.tag, perr));
					break;
				}
				if(readerpid >= 0)
					kill(readerpid);
				readerpid = -1;
				gen++;
				src = nil;
				link = "none";
				st.p.forget();
				if(s == nil) {
					srcerr = "";
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
					break;
				}
				link = "opening";
				ctlwait = m;
				waitsrc = s;
				rpidc := chan of int;
				spawn reader(gen, s, inputc, rpidc);
				readerpid = <-rpidc;
			Qfeed =>
				c := client(st.clients, m.fid);
				if(c == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadfid));
					break;
				}
				c.partial += string m.data;
				ferr := "";
				for(;;) {
					(line, rest) := splitline(c.partial);
					if(line == nil)
						break;
					c.partial = rest;
					if(line == "" || line == "\r")
						continue;
					if((e := st.take(line)) != nil && ferr == "")
						ferr = e;
				}
				if(len c.partial > Maxline) {
					c.partial = nil;
					if(ferr == "")
						ferr = "sentence too long";
				}
				if(ferr != "")
					srv.reply(ref Rmsg.Error(m.tag, "bad sentence: " + ferr));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
			}
		Flush =>
			for(l := st.clients; l != nil; l = tl l)
				if((hd l).rd != nil && (hd l).rd.tag == m.oldtag)
					(hd l).rd = nil;
			if(ctlwait != nil && ctlwait.tag == m.oldtag)
				ctlwait = nil;	# the source still opens; nobody waits for it
			srv.default(gm);
		Clunk =>
			nl: list of ref Client;
			for(l := st.clients; l != nil; l = tl l) {
				c := hd l;
				if(c.fid != m.fid) {
					nl = c :: nl;
					continue;
				}
				# a sentence written without its newline is still a sentence
				if(c.path == Qfeed && c.partial != nil)
					st.take(c.partial);
			}
			st.clients = nl;
			srv.clunk(m);
		* =>
			srv.default(gm);
		}
	}
	if(readerpid >= 0)
		kill(readerpid);
	navops <-= nil;
}

# a sentence, from the source or feed: given to the readers of nmea,
# and any fix it completes to the readers of event; nil, or why it was
# refused
State.take(st: self ref State, line: string): string
{
	if(len line > 0 && line[len line-1] == '\r')
		line = line[0:len line-1];
	(fl, err) := st.p.sentence(line);
	st.sentences++;
	if(err != nil) {
		st.bad++;
		return err;
	}
	for(l := st.clients; l != nil; l = tl l)
		if((hd l).path == Qnmea)
			queue(st.srv, hd l, line + "\n");
	for(; fl != nil; fl = tl fl) {
		f := hd fl;
		if(f.valid && f.haspos)
			st.lastfix = sys->millisec();
		s := f.text() + "\n";
		for(l = st.clients; l != nil; l = tl l)
			if((hd l).path == Qevent)
				queue(st.srv, hd l, s);
	}
	return nil;
}

client(l: list of ref Client, fid: int): ref Client
{
	for(; l != nil; l = tl l)
		if((hd l).fid == fid)
			return hd l;
	return nil;
}

# lines for a reader of event or nmea; the oldest are dropped if it
# does not keep up
queue(srv: ref Styxserver, c: ref Client, s: string)
{
	c.pending += s;
	if(len c.pending > Maxqueue)
		c.pending = trimlines(c.pending, Maxqueue);
	streamreply(srv, c);
}

# a waiting read of event or nmea given what has arrived: whole lines
# when they fit.  A stream, not a file: each read is what came next,
# whatever its offset
streamreply(srv: ref Styxserver, c: ref Client)
{
	if(c.rd == nil || c.pending == nil)
		return;
	b := array of byte c.pending;
	n := len b;
	if(n > c.rd.count) {
		n = c.rd.count;
		for(i := n; i > 0; i--)
			if(b[i-1] == byte '\n')
				break;
		if(i > 0)
			n = i;
	}
	srv.reply(ref Rmsg.Read(c.rd.tag, b[0:n]));
	c.pending = string b[n:];
	if(c.pending == "")
		c.pending = nil;
	c.rd = nil;
}

# the newest whole lines of s, no more than max bytes
trimlines(s: string, max: int): string
{
	b := array of byte s;
	i := len b - max;
	while(i < len b && b[i] != byte '\n')
		i++;
	return string b[i+1:];
}

# (the first line, the rest), or (nil, s) if no line is ended
splitline(s: string): (string, string)
{
	for(i := 0; i < len s; i++)
		if(s[i] == '\n')
			return (s[0:i], s[i+1:]);
	return (nil, s);
}

# a command written to ctl: (nil, nil) for stop
parsecmd(s: string): (ref Source, string)
{
	(n, l) := sys->tokenize(s, " \t\r\n");
	if(n == 0)
		return (nil, "no command");
	a := array[n] of string;
	for(i := 0; l != nil; l = tl l)
		a[i++] = hd l;
	case a[0] {
	"stop" =>
		if(n != 1)
			return (nil, "usage: stop");
		return (nil, nil);
	"replay" =>
		if(n != 2)
			return (nil, "usage: replay <path>");
		return (ref Source("replay " + a[1], "replay", a[1], nil), nil);
	"source" =>
		if(n == 3 && a[1] == "gpsd") {
			# host, host!port, net!host, net!host!port
			addr := a[2];
			case count(addr, '!') {
			0 =>
				addr = "tcp!" + addr + "!2947";
			1 =>
				(nil, f) := sys->tokenize(addr, "!");
				case hd f {
				"tcp" or "net" or "udp" =>
					addr += "!2947";
				* =>
					addr = "tcp!" + addr;
				}
			}
			return (ref Source("source gpsd " + a[2], "gpsd", addr, nil), nil);
		}
		if(n == 2 && count(a[1], '!') > 0)
			return (ref Source("source " + a[1], "dial", a[1], nil), nil);
		if(n == 2)
			return (ref Source("source " + a[1], "file", a[1], nil), nil);
		if(n == 3) {
			if(!isdigits(a[2]))
				return (nil, "bad baud rate " + a[2]);
			return (ref Source("source " + a[1] + " " + a[2], "file", a[1], a[2]), nil);
		}
		return (nil, "usage: source <path> [baud] | source <net!host!port> | source gpsd <host>");
	}
	return (nil, "unknown command " + a[0]);
}

count(s: string, c: int): int
{
	n := 0;
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			n++;
	return n;
}

isdigits(s: string): int
{
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return 0;
	return len s > 0;
}

quote(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\t' || s[i] == '\'' || s[i] == '=')
			break;
	if(i == len s && s != "")
		return s;
	q := "'";
	for(i = 0; i < len s; i++) {
		if(s[i] == '\'')
			q += "'";
		q[len q] = s[i];
	}
	return q + "'";
}

kill(pid: int)
{
	fd := sys->open("/prog/" + string pid + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "kill");
}

#
# A source's reader: it opens the source, says whether it could, then
# sends its lines until it ends.  It is killed when the source changes.
#
reader(gen: int, s: ref Source, inputc: chan of ref Input, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd: ref Sys->FD;
	case s.verb {
	"file" or "replay" =>
		fd = sys->open(s.addr, Sys->OREAD);
		if(fd == nil) {
			inputc <-= ref Input(gen, Iopen, nil, sys->sprint("%r"));
			return;
		}
		if(s.baud != nil) {
			cfd := sys->open(s.addr + "ctl", Sys->OWRITE);
			if(cfd == nil || sys->fprint(cfd, "b%s", s.baud) < 0) {
				inputc <-= ref Input(gen, Iopen, nil, sys->sprint("%sctl: b%s: %r", s.addr, s.baud));
				return;
			}
		}
	"dial" or "gpsd" =>
		(ok, c) := sys->dial(s.addr, nil);
		if(ok < 0) {
			inputc <-= ref Input(gen, Iopen, nil, sys->sprint("dial %s: %r", s.addr));
			return;
		}
		fd = c.dfd;
		if(s.verb == "gpsd") {
			# gpsd's own protocol is JSON; asked, it sends NMEA instead
			w := "?WATCH={\"enable\":true,\"nmea\":true}\n";
			if(sys->fprint(fd, "%s", w) < 0) {
				inputc <-= ref Input(gen, Iopen, nil, sys->sprint("gpsd %s: %r", s.addr));
				return;
			}
		}
	}
	inputc <-= ref Input(gen, Iopen, nil, nil);

	pace := s.verb == "replay";
	prev := -1;
	buf := array[8192] of byte;
	part := "";
	for(;;) {
		n := sys->read(fd, buf, len buf);
		if(n <= 0) {
			err: string;
			if(n < 0)
				err = sys->sprint("%r");
			inputc <-= ref Input(gen, Iend, nil, err);
			return;
		}
		part += string buf[0:n];
		for(;;) {
			(line, rest) := splitline(part);
			if(line == nil)
				break;
			part = rest;
			if(pace && (t := daytime(nmea->timeof(line))) >= 0) {
				if(prev >= 0 && t > prev)
					sys->sleep(min(t - prev, 5000));
				prev = t;
			}
			inputc <-= ref Input(gen, Iline, line, nil);
		}
		if(len part > Maxline)
			part = "";
	}
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

# hh:mm:ss[.ss] as milliseconds into the day, or -1
daytime(t: string): int
{
	if(t == nil || len t < 8)
		return -1;
	ms := ((int t[0:2] * 60 + int t[3:5]) * 60 + int t[6:8]) * 1000;
	if(len t > 9)
		ms += int (real ("0" + t[8:]) * 1000.0);
	return ms;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil) {
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);
		Walk =>
			if(n.path != Qroot) {
				n.reply <-= (nil, Styxservers->Enotdir);
				continue;
			}
			if(n.name == "..") {
				n.reply <-= dirgen(Qroot);
				continue;
			}
			for(i := 0; i < len files; i++)
				if(files[i].t0 == n.name)
					break;
			if(i < len files)
				n.reply <-= dirgen(Qctl + big i);
			else
				n.reply <-= (nil, Styxservers->Enotfound);
		Readdir =>
			if(n.path == Qroot)
				for(i := n.offset; i < len files && i < n.offset + n.count; i++)
					n.reply <-= dirgen(Qctl + big i);
			n.reply <-= (nil, nil);
		}
	}
}

dirgen(p: big): (ref Sys->Dir, string)
{
	d := ref sys->zerodir;
	d.qid.path = p;
	d.uid = d.gid = user;
	if(p == Qroot) {
		d.name = ".";
		d.qid.qtype = Sys->QTDIR;
		d.mode = Sys->DMDIR | 8r555;
		return (d, nil);
	}
	i := int (p - Qctl);
	if(i < 0 || i >= len files)
		return (nil, Styxservers->Enotfound);
	(d.name, d.mode) = files[i];
	return (d, nil);
}
