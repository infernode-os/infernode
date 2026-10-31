implement Gpsfs;

#
# gpsfs - a GPS receiver as files, at /mnt/gps.
#
# A receiver is a byte stream: a serial port ('#t/eia0', a USB puck
# the host enumerates there), a phone's own location service
# ('#g/nmea', location(3)), a network feed (a phone app serving NMEA
# over TCP, gpsd, a marine gateway's UDP), a recorded log.  It speaks
# NMEA 0183, or one of two others gpsfs knows: Garmin's Aviation
# output (garminav(2)) and GDL 90 from an ADS-B receiver (gdl90(2)).
# A fix from those is written as NMEA (nmea->sentences), so there is
# one parser and the nmea file speaks one language whatever the
# receiver.  gpsfs reads one source, assembles its sentences into
# fixes (nmea(2)), and serves what it knows:
#
#   ctl         (rw) write one command:
#                      source [format] <path> [baud]
#                                       a file or serial port; baud is
#                                       written to <path>ctl
#                      source [format] <net!host!port>
#                                       a network connection; with host
#                                       * (udp!*!10110), datagrams sent
#                                       to that port
#                      source gpsd <host[!port]>  gpsd, in its NMEA mode
#                      replay <path>    an NMEA log, paced by its times
#                      stop
#                    format is nmea (the default), garmin or gdl90.  A
#                    source is open (or refused, with the reason) when
#                    the write returns; a read gives the command in use.
#   status      (r)  state=fix|nofix|nosource link=none|open|closed|error
#                    source=... sentences=N bad=N age=S error='...'
#   position    (r)  "lat lon", decimal degrees; "no fix" is an error
#   fix         (r)  the last fix, attr=value: time lat lon alt baroalt
#                    speed course mcourse heading mheading mode q sats
#                    hdop vdop pdop err verr magvar, each there only
#                    when known (see nmea(2) for units)
#   event       (r)  each read waits for the next fix and gives it, as
#                    fix does, or the fixes since the last read; every
#                    open has its own
#   satellites  (r)  one line a satellite in view:
#                    system prn elevation azimuth snr used
#   traffic     (r)  one line a craft heard in the last ten minutes,
#                    nearest first, attr=value: kind (ais adsb flarm) id
#                    lat lon alt speed course heading climb name
#                    callsign cat age
#   nmea        (r)  the sentences, as received (AIS's ! sentences
#                    too), from the open on; each read waits for more
#   feed        (w)  sentences written here are taken as the receiver's
#   time        (r)  the last fix's time beside this host's clock when its
#                    first sentence began to arrive: time= (RFC 3339)
#                    gps= local= offset= (microseconds since the epoch,
#                    and their difference) sync=yes|no.  sync is yes only
#                    for a live receiver speaking NMEA: never for a
#                    recording, a feed, or a format with no time of its
#                    own (garmin, gdl90, whose fixes this host stamps).
#                    timesync(8) sets the clock from it.
#
# A fix from a recording (replay, or a source that is a file with a
# length) says origin=recorded, one written to feed origin=fed; a live
# receiver's says nothing.  A position more than a degree from the last
# is held back as a glitch, up to three in a row (nmea(2)), and counted
# in status as suspect=.
#
# The files are mounted at the mount point and posted as #sgps/fs
# (post9p(2)), so a process whose name space did not see the mount
# (Lucifer's applications, an agent's tools) can mount them:
#	mount -A '#sgps/fs' /mnt/gps
#
# Reading and commanding are separate files so that access is decided by
# what is bound, not by checks here: a process given position, fix,
# event, satellites, traffic and nmea can follow the receiver; only one given
# ctl or feed can change what it says.  feed is how anything without a
# byte stream (a test, a position from elsewhere) supplies sentences;
# it puts a position in, so it is not bound where position is merely
# read.
#
# The server opens sources in the name space it was started in.
#
# Usage:	gpsfs [-S] [-m mountpoint] [-s spec] [command ...]
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

include "daytime.m";
	daytime: Daytime;

include "post9p.m";
	post9p: Post9p;

include "nmea.m";
	nmea: Nmea;
	Fix, Parser, Target: import nmea;

include "gdl90.m";
	gdl90: Gdl90;
	Framer: import gdl90;

include "garminav.m";
	garminav: Garminav;
	Grouper: import garminav;

Gpsfs: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qctl, Qstatus, Qposition, Qfix, Qevent, Qsatellites, Qtraffic, Qtime, Qnmea, Qfeed: con big iota;

files := array[] of {
	("ctl", 8r660),
	("status", 8r444),
	("position", 8r444),
	("fix", 8r444),
	("event", 8r444),
	("satellites", 8r444),
	("traffic", 8r444),
	("time", 8r444),
	("nmea", 8r444),
	("feed", 8r220),
};

Maxqueue: con 64*1024;	# what a reader of event or nmea has not read
Maxline: con 1024;

# what a reader proc reports
Iopen, Iline, Iend, Itarget: con iota;
Input: adt {
	gen:	int;
	kind:	int;
	line:	string;
	err:	string;
	target:	ref Target;
	us:	big;	# this host's clock when the line began to arrive, or 0
};

# a request from one of the connections: the mount's, or one made
# through #sgps/fs; m nil when the connection is gone
Req: adt {
	srv:	ref Styxserver;
	m:	ref Tmsg;
};

# an open of event, nmea or feed
Client: adt {
	srv:	ref Styxserver;
	fid:	int;
	path:	big;
	pending:	string;		# event: fixes not read; nmea: sentences not read
	rd:	ref Tmsg.Read;	# a read waiting
	partial:	string;		# feed: a line not ended
};

# what the server knows, apart from its source
State: adt {
	p:	ref Parser;
	clients:	list of ref Client;
	sentences:	int;
	bad:	int;
	lastfix:	int;	# sys->millisec() of the last fix, or -1
	# the arrival of the first sentence of this time and the last
	etime:	string;
	elocal:	big;
	ptime:	string;
	plocal:	big;
	timetext:	string;	# the time file
	origin:	string;		# the last sentence's

	# a sentence: where it came from ("" a live receiver, recorded,
	# fed), whether its times are the receiver's own, when it began
	# to arrive (0 not known)
	take:	fn(st: self ref State, line, origin: string, owntime: int, us: big): string;
	lastorigin:	fn(st: self ref State): string;
	settime:	fn(st: self ref State, f: ref Fix, sync: int);
};

# a source command
Source: adt {
	cmd:	string;		# as read back from ctl
	verb:	string;		# file dial listen gpsd replay
	format:	string;		# nmea garmin gdl90
	addr:	string;
	baud:	string;
	origin:	string;		# "" live, or recorded
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
	daytime = load Daytime Daytime->PATH;
	if(arg == nil || styx == nil || styxservers == nil || nmea == nil || daytime == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	styx->init();
	styxservers->init(styx);
	nmea->init();

	mnt := "/mnt/gps";
	spec := "gps";
	arg->init(argv);
	arg->setusage("gpsfs [-S] [-m mountpoint] [-s spec] [command ...]");
	while((o := arg->opt()) != 0)
		case o {
		'm' =>
			mnt = arg->earg();
		's' =>
			spec = arg->earg();
		'S' =>
			spec = nil;
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
	reqc := chan of ref Req;
	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), Qroot);
	fds[0] = nil;
	spawn forward(srv, tchan, reqc);
	pidc := chan of int;
	spawn server(reqc, spec, navops, srv.fd, pidc);
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

# a connection's requests into the server's one channel
forward(srv: ref Styxserver, tchan: chan of ref Tmsg, reqc: chan of ref Req)
{
	for(;;) {
		m := <-tchan;
		if(m != nil && tagof m == tagof Tmsg.Readerror)
			m = nil;
		reqc <-= ref Req(srv, m);
		if(m == nil)
			return;
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
# Requests come from every connection (the mount's, and one for each
# open of #sgps/fs) on reqc; sentences from the reader proc of the
# current source (on inputc, marked with the source's generation, so
# a stopped source's last lines are dropped) and from writes of feed.
#
server(reqc: chan of ref Req, spec: string, navops: chan of ref Navop,
	mfd: ref Sys->FD, pidc: chan of int)
{
	# a name space and fds of its own, made before the mount: the
	# server never finds itself when it opens a source
	pid := sys->pctl(Sys->NEWFD|Sys->FORKNS, mfd.fd :: 2 :: nil);
	stderr = sys->fildes(2);
	# posted from here, so the connections' fds are in this fd group
	conns := chan of ref Sys->FD;
	posted := 0;
	if(spec != nil) {
		post9p = load Post9p Post9p->PATH;
		if(post9p == nil)
			sys->fprint(stderr, "gpsfs: cannot load post9p: %r: not posted\n");
		else {
			post9p->init();
			(nil, perr) := post9p->post(spec, conns);
			if(perr != nil)
				sys->fprint(stderr, "gpsfs: post #s%s: %s\n", spec, perr);
			else
				posted = 1;
		}
	}
	pidc <-= pid;

	st := ref State(Parser.new(), nil, 0, 0, -1, nil, big 0, nil, big 0, nil, nil);
	inputc := chan of ref Input;
	gen := 0;
	readerpid := -1;
	src: ref Source;
	link := "none";
	srcerr := "";
	ctlwait: ref Tmsg.Write;	# a source command waiting for its open
	ctlsrv: ref Styxserver;
	waitsrc: ref Source;
	nconn := 1;	# the mount's

Serve:
	for(;;) alt {
	fd := <-conns =>
		(tc, srv) := Styxserver.new(fd, Navigator.new(navops), Qroot);
		spawn forward(srv, tc, reqc);
		nconn++;

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
					ctlsrv.reply(ref Rmsg.Error(ctlwait.tag, in.err));
			} else {
				link = "open";
				srcerr = "";
				src = waitsrc;
				if(in.line != nil)
					src.origin = in.line;	# what the reader found the source to be
				if(ctlwait != nil)
					ctlsrv.reply(ref Rmsg.Write(ctlwait.tag, len ctlwait.data));
			}
			ctlwait = nil;
			waitsrc = nil;
		Iline =>
			if(len in.line > 0 && (in.line[0] == '$' || in.line[0] == '!') && src != nil)
				st.take(in.line, src.origin, src.format == "nmea", in.us);
		Itarget =>
			st.p.target(in.target);
		Iend =>
			readerpid = -1;
			if(in.err != nil) {
				link = "error";
				srcerr = in.err;
			} else
				link = "closed";
		}

	r := <-reqc =>
		srv := r.srv;
		if(r.m == nil) {
			# a connection gone: its opens with it
			nl: list of ref Client;
			for(l := st.clients; l != nil; l = tl l)
				if((hd l).srv != srv)
					nl = hd l :: nl;
			st.clients = nl;
			if(ctlsrv == srv)
				ctlwait = nil;
			# not posted, the last connection gone: nobody can reach it
			if(--nconn == 0 && !posted)
				break Serve;
			break;
		}
		pick m := r.m {
		Open =>
			f := srv.open(m);
			if(f != nil && (f.path == Qevent || f.path == Qnmea || f.path == Qfeed))
				st.clients = ref Client(srv, m.fid, f.path, nil, nil, nil) :: st.clients;
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
				if(src != nil) {
					s += " source=" + quote(src.addr);
					if(src.origin != nil)
						s += " origin=" + src.origin;
				}
				s += sys->sprint(" sentences=%d bad=%d suspect=%d", st.sentences, st.bad, st.p.suspects);
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
					s = st.p.last.text() + st.lastorigin() + "\n";
				srv.reply(styxservers->readstr(m, s));
			Qsatellites =>
				srv.reply(styxservers->readstr(m, st.p.satellites()));
			Qtraffic =>
				srv.reply(styxservers->readstr(m, st.p.traffic(sys->millisec())));
			Qtime =>
				srv.reply(styxservers->readstr(m, st.timetext));
			Qevent or Qnmea =>
				c := client(st.clients, srv, m.fid);
				if(c == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadfid));
					break;
				}
				if(c.rd != nil) {
					srv.reply(ref Rmsg.Error(m.tag, "a read is already waiting"));
					break;
				}
				c.rd = m;
				streamreply(c);
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
				ctlsrv = srv;
				waitsrc = s;
				rpidc := chan of int;
				spawn reader(gen, s, inputc, rpidc);
				readerpid = <-rpidc;
			Qfeed =>
				c := client(st.clients, srv, m.fid);
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
					if((e := st.take(line, "fed", 0, big 0)) != nil && ferr == "")
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
				if((hd l).srv == srv && (hd l).rd != nil && (hd l).rd.tag == m.oldtag)
					(hd l).rd = nil;
			if(ctlwait != nil && ctlsrv == srv && ctlwait.tag == m.oldtag)
				ctlwait = nil;	# the source still opens; nobody waits for it
			srv.default(r.m);
		Clunk =>
			nl: list of ref Client;
			for(l := st.clients; l != nil; l = tl l) {
				c := hd l;
				if(c.srv != srv || c.fid != m.fid) {
					nl = c :: nl;
					continue;
				}
				# a sentence written without its newline is still a sentence
				if(c.path == Qfeed && c.partial != nil)
					st.take(c.partial, "fed", 0, big 0);
			}
			st.clients = nl;
			srv.clunk(m);
		* =>
			srv.default(r.m);
		}
	}
	if(readerpid >= 0)
		kill(readerpid);
	navops <-= nil;
}

# a sentence: given to the readers of nmea, and any fix it completes
# to the readers of event and the time file; nil, or why it was refused
State.take(st: self ref State, line, origin: string, owntime: int, us: big): string
{
	if(len line > 0 && line[len line-1] == '\r')
		line = line[0:len line-1];
	# the arrival of each time's first sentence, for the time file
	if(us != big 0 && (t := nmea->timeof(line)) != nil && t != st.etime) {
		(st.ptime, st.plocal) = (st.etime, st.elocal);
		(st.etime, st.elocal) = (t, us);
	}
	(fl, err) := st.p.sentence(line);
	st.sentences++;
	if(err != nil) {
		st.bad++;
		return err;
	}
	for(l := st.clients; l != nil; l = tl l)
		if((hd l).path == Qnmea)
			queue(hd l, line + "\n");
	for(; fl != nil; fl = tl fl) {
		f := hd fl;
		o := "";
		if(origin != nil)
			o = " origin=" + origin;
		if(f.valid && f.haspos) {
			st.lastfix = sys->millisec();
			st.settime(f, origin == nil && owntime);
		}
		s := f.text() + o + "\n";
		for(l = st.clients; l != nil; l = tl l)
			if((hd l).path == Qevent)
				queue(hd l, s);
	}
	st.origin = origin;
	return nil;
}

State.lastorigin(st: self ref State): string
{
	if(st.origin == nil)
		return "";
	return " origin=" + st.origin;
}

# the time file from a fix: its time beside this host's when the
# first sentence of its time began to arrive
State.settime(st: self ref State, f: ref Fix, sync: int)
{
	gps := fixus(f);
	local := big 0;
	if(f.utc == st.etime)
		local = st.elocal;
	else if(f.utc == st.ptime)
		local = st.plocal;
	if(gps == big 0 || local == big 0)
		return;
	ok := "no";
	if(sync)
		ok = "yes";
	st.timetext = sys->sprint("time=%s gps=%bd local=%bd offset=%bd sync=%s\n",
		f.time(), gps, local, gps - local, ok);
}

# a fix's time in microseconds since the epoch, or 0
fixus(f: ref Fix): big
{
	if(f.date == nil || len f.date != 10 || f.utc == nil || len f.utc < 8)
		return big 0;
	tm := ref Daytime->Tm;
	tm.year = int f.date[0:4] - 1900;
	tm.mon = int f.date[5:7] - 1;
	tm.mday = int f.date[8:10];
	tm.hour = int f.utc[0:2];
	tm.min = int f.utc[3:5];
	tm.sec = int f.utc[6:8];
	tm.zone = "GMT";
	us := big daytime->tm2epoch(tm) * big 1000000;
	if(len f.utc > 9) {
		frac := f.utc[9:];
		m := big 0;
		for(i := 0; i < 6; i++) {
			m *= big 10;
			if(i < len frac)
				m += big (frac[i] - '0');
		}
		us += m;
	}
	return us;
}

client(l: list of ref Client, srv: ref Styxserver, fid: int): ref Client
{
	for(; l != nil; l = tl l)
		if((hd l).srv == srv && (hd l).fid == fid)
			return hd l;
	return nil;
}

# lines for a reader of event or nmea; the oldest are dropped if it
# does not keep up
queue(c: ref Client, s: string)
{
	c.pending += s;
	if(len c.pending > Maxqueue)
		c.pending = trimlines(c.pending, Maxqueue);
	streamreply(c);
}

# a waiting read of event or nmea given what has arrived: whole lines
# when they fit.  A stream, not a file: each read is what came next,
# whatever its offset
streamreply(c: ref Client)
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
	c.srv.reply(ref Rmsg.Read(c.rd.tag, b[0:n]));
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
		return (ref Source("replay " + a[1], "replay", "nmea", a[1], nil, "recorded"), nil);
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
			return (ref Source("source gpsd " + a[2], "gpsd", "nmea", addr, nil, nil), nil);
		}
		cmd := "source";
		format := "nmea";
		a = a[1:];
		if(len a > 0 && (a[0] == "nmea" || a[0] == "garmin" || a[0] == "gdl90")) {
			format = a[0];
			cmd += " " + a[0];
			a = a[1:];
		}
		if(len a < 1 || len a > 2)
			return (nil, "usage: source [nmea|garmin|gdl90] <path> [baud] | source [nmea|garmin|gdl90] <net!host!port> | source gpsd <host>");
		cmd += " " + a[0];
		baud: string;
		if(len a == 2) {
			if(!isdigits(a[1]))
				return (nil, "bad baud rate " + a[1]);
			baud = a[1];
			cmd += " " + baud;
		}
		verb := "file";
		if(count(a[0], '!') > 0) {
			if(baud != nil)
				return (nil, "a baud rate is for a serial port, not " + a[0]);
			(nil, f) := sys->tokenize(a[0], "!");
			if(len f == 3 && hd tl f == "*") {
				if(hd f != "udp")
					return (nil, "only udp is listened for: " + a[0]);
				verb = "listen";
			} else
				verb = "dial";
		}
		return (ref Source(cmd, verb, format, a[0], baud, nil), nil);
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
# A receiver that does not speak NMEA is decoded here and its fixes
# sent as the sentences a receiver would send for them.
#
reader(gen: int, s: ref Source, inputc: chan of ref Input, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	fd: ref Sys->FD;
	conn: Sys->Connection;	# a listening source's, kept while it is read
	origin: string;		# what the source turns out to be, if not live
	case s.verb {
	"file" or "replay" =>
		fd = sys->open(s.addr, Sys->OREAD);
		if(fd == nil) {
			inputc <-= failed(gen, sys->sprint("%r"));
			return;
		}
		# a file with a length is a recording; a device, a pipe or a
		# serial port, as it arrives, has none
		(ok, d) := sys->fstat(fd);
		if(ok >= 0 && (d.qid.qtype & Sys->QTDIR) == 0 && d.length > big 0)
			origin = "recorded";
		if(s.baud != nil) {
			cfd := sys->open(s.addr + "ctl", Sys->OWRITE);
			if(cfd == nil || sys->fprint(cfd, "b%s", s.baud) < 0) {
				inputc <-= failed(gen, sys->sprint("%sctl: b%s: %r", s.addr, s.baud));
				return;
			}
		}
	"dial" or "gpsd" =>
		(ok, c) := sys->dial(s.addr, nil);
		if(ok < 0) {
			inputc <-= failed(gen, sys->sprint("dial %s: %r", s.addr));
			return;
		}
		fd = c.dfd;
		if(s.verb == "gpsd") {
			# gpsd's own protocol is JSON; asked, it sends NMEA instead
			w := "?WATCH={\"enable\":true,\"nmea\":true}\n";
			if(sys->fprint(fd, "%s", w) < 0) {
				inputc <-= failed(gen, sys->sprint("gpsd %s: %r", s.addr));
				return;
			}
		}
	"listen" =>
		ok: int;
		(ok, conn) = sys->announce(s.addr);
		if(ok < 0) {
			inputc <-= failed(gen, sys->sprint("announce %s: %r", s.addr));
			return;
		}
		# each datagram is read with its sender's address before it
		if(sys->fprint(conn.cfd, "headers") < 0 ||
		   (fd = sys->open(conn.dir + "/data", Sys->ORDWR)) == nil) {
			inputc <-= failed(gen, sys->sprint("%s: %r", s.addr));
			return;
		}
	}
	inputc <-= ref Input(gen, Iopen, origin, nil, nil, big 0);

	garmin: ref Garminav->Grouper;
	gdl: ref Gdl90->Framer;
	case s.format {
	"garmin" =>
		garminav = load Garminav Garminav->PATH;
		if(garminav != nil) {
			garminav->init(nmea);
			garmin = Grouper.new();
		}
	"gdl90" =>
		gdl90 = load Gdl90 Gdl90->PATH;
		if(gdl90 != nil) {
			gdl90->init(nmea);
			gdl = Framer.new();
		}
	}
	if(s.format != "nmea" && garmin == nil && gdl == nil) {
		inputc <-= ref Input(gen, Iend, nil, sys->sprint("cannot load the %s decoder: %r", s.format), nil, big 0);
		return;
	}

	pace := s.verb == "replay";
	listen := s.verb == "listen";
	prev := -1;
	buf := array[8192] of byte;
	part := "";
	partus := big 0;	# when part's first byte arrived
	# how long a byte takes on a serial line: ten bits at its rate
	charus := big 0;
	if(s.baud != nil && int s.baud > 0)
		charus = big (10000000 / int s.baud);
	clock := sys->open("/dev/time", Sys->OREAD);
	for(;;) {
		n := sys->read(fd, buf, len buf);
		now := hostus(clock);
		if(n <= 0) {
			err: string;
			if(n < 0)
				err = sys->sprint("%r");
			inputc <-= ref Input(gen, Iend, nil, err, nil, big 0);
			return;
		}
		b := buf[0:n];
		if(listen) {
			if(len b < Udphdr)
				continue;
			b = b[Udphdr:];
		}
		if(gdl != nil) {
			(fixes, targets) := gdl.feed(b);
			for(; targets != nil; targets = tl targets)
				inputc <-= ref Input(gen, Itarget, nil, nil, hd targets, big 0);
			sendfixes(gen, inputc, fixes);
			continue;
		}
		if(garmin != nil) {
			sendfixes(gen, inputc, garmin.feed(b));
			continue;
		}
		# when a byte of this read arrived: the read's time less the
		# time the bytes after it took on the line (a datagram, or a
		# line of no known rate, all at once)
		chunk := string b;
		if(listen && chunk != "" && chunk[len chunk-1] != '\n')
			chunk += "\n";	# a datagram is whole
		from := len part;
		all := part + chunk;
		if(part == "")
			partus = now - big len chunk * charus;
		pos := 0;
		for(i := 0; i < len all; i++) {
			if(all[i] != '\n')
				continue;
			line := all[pos:i];
			us := partus;
			if(pos >= from)
				us = now - big (len chunk - (pos - from)) * charus;
			pos = i + 1;
			if(pace && (t := daymillis(nmea->timeof(line))) >= 0) {
				if(prev >= 0 && t > prev)
					sys->sleep(min(t - prev, 5000));
				prev = t;
			}
			inputc <-= ref Input(gen, Iline, line, nil, nil, us);
		}
		part = all[pos:];
		if(part != "" && pos >= from)
			partus = now - big (len chunk - (pos - from)) * charus;
		if(len part > Maxline)
			part = "";
	}
}

Udphdr: con 52;	# a datagram's addresses, in headers mode (ip(3))

failed(gen: int, err: string): ref Input
{
	return ref Input(gen, Iopen, nil, err, nil, big 0);
}

# this host's clock, microseconds since the epoch (cons(3)), or 0
hostus(fd: ref Sys->FD): big
{
	if(fd == nil)
		return big 0;
	b := array[32] of byte;
	n := sys->pread(fd, b, len b, big 0);
	if(n <= 0)
		return big 0;
	return big string b[0:n];
}

# fixes from a receiver that gives no time stamped with this host's,
# each distinct, and sent as sentences
laststamp := -1;
stampn := 0;
sendfixes(gen: int, inputc: chan of ref Input, fixes: list of ref Fix)
{
	for(; fixes != nil; fixes = tl fixes) {
		f := hd fixes;
		now := daytime->now();
		if(now == laststamp)
			stampn++;
		else
			stampn = 0;
		laststamp = now;
		tm := daytime->gmt(now);
		f.date = sys->sprint("%.4d-%.2d-%.2d", tm.year + 1900, tm.mon + 1, tm.mday);
		f.utc = sys->sprint("%.2d:%.2d:%.2d", tm.hour, tm.min, tm.sec);
		if(stampn > 0 && stampn < 100)
			f.utc += sys->sprint(".%.2d", stampn);
		(nil, l) := sys->tokenize(nmea->sentences(f), "\r\n");
		for(; l != nil; l = tl l)
			inputc <-= ref Input(gen, Iline, hd l, nil, nil, big 0);
	}
}

min(a, b: int): int
{
	if(a < b)
		return a;
	return b;
}

# hh:mm:ss[.ss] as milliseconds into the day, or -1
daymillis(t: string): int
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
