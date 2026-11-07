implement Sdrfs;

#
# sdrfs - a software-defined radio receiver as files, at /mnt/sdr.
#
# The receiver is an RTL-SDR (an RTL2832U and its tuner) served by the
# host's rtl_tcp (librtlsdr), which sdrfs dials.  It serves the radio,
# not what the radio hears: demodulators are programs that read iq
# (docs/SDR.md).
#
#   ctl     (rw) one setting a line; a read gives every one, in the
#                form written:
#                  source <addr>    rtl_tcp: tcp!host!port, host!port or
#                                   host (port 1234); stop for none
#                  freq <hz>        k, M and G suffixes taken
#                  rate <samples a second>
#                  gain auto | <dB> the nearest the tuner has, once known
#                  ppm <n>          the frequency correction
#                  agc on | off     the RTL2832U's own
#                  direct off | i | q   direct sampling, for HF
#                  biastee off | on 5 V on the antenna
#   status  (r)  attr=value: link=none|idle|opening|open|closed|error
#                source= tuner= gains= readers= bytes= dropped=
#                skipped= error=
#   gains   (r)  the tuner's gains, dB, one a line
#   iq      (r)  the samples from the open on, 8-bit unsigned I then Q;
#                each read waits for more.  The first open dials
#                rtl_tcp if it is not held, and once the last reader
#                and the last setting are -l seconds gone it hangs up,
#                so the radio is read only while something listens or
#                has just.  Every open has its own queue; one that
#                falls behind loses the oldest, counted in status as
#                dropped=.  rtl_tcp answers no command and applies
#                them one at a time, so sdrfs reckons 150ms each; samples
#                arriving before then and -t milliseconds (300) more
#                were tuned before they took, and are dropped, counted
#                as skipped=.  A hang-up waits for them too.  When the radio's
#                stream ends, a read gives what was queued, then end
#                of file.
#
# The settings are sdrfs's, and sent whole each time it dials: what
# ctl says is what the radio is set to.  One radio is one tuner on one
# frequency; every reader of iq hears what it is tuned to, and a
# setting written moves them all.
#
# Tuning (ctl) and listening (iq) are separate files, so what a process
# may do is what is bound in its name space.  The radio cannot transmit.
# rtl_tcp has no authentication: keep it on loopback, and reach a radio
# elsewhere by exporting /mnt/sdr over authenticated 9P.
#
# The files are also posted as #ssdr/fs (post9p(2)).
#
# -w is how long to wait for rtl_tcp's greeting (15 seconds): while
# another client holds it, rtl_tcp answers a dial but does not greet,
# and after one leaves it takes five seconds to take the next.  So the
# connection is held -l seconds (10) after it is last used, and a
# source's dial is held as the stream's: reopening iq within that
# costs nothing.  Hanging up while rtl_tcp is still applying settings
# has crashed it (librtlsdr 2.0.1, macOS); holding avoids that too.
#
# Usage:	sdrfs [-S] [-l seconds] [-m mountpoint] [-s spec] [-t ms] [-w seconds] [command ...]
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

include "post9p.m";
	post9p: Post9p;

Sdrfs: module
{
	init: fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qctl, Qstatus, Qgains, Qiq: con big iota;

files := array[] of {
	("ctl", 8r660),
	("status", 8r444),
	("gains", 8r444),
	("iq", 8r444),
};

Port: con "1234";
Chunk: con 64*1024;		# a read of the stream
Maxqueue: con 8*1024*1024;	# what a reader of iq has not read: 1.7s at 2.4 MS/s
Greeting: con 12;		# "RTL0", the tuner type, the number of gains

# rtl_tcp's commands: a byte, then a big-endian 32-bit value
Cfreq: con 1;
Crate: con 2;
Cgainmode: con 3;
Cgain: con 4;
Cppm: con 5;
Cagc: con 8;
Cdirect: con 9;
Cbiastee: con 14;

# librtlsdr's tuner types, as rtl_tcp's greeting gives them, and their
# gains in tenths of a dB
tuners := array[] of {"unknown", "E4000", "FC0012", "FC0013", "FC2580", "R820T", "R828D"};
e4kgains := array[] of {-10, 15, 40, 65, 90, 115, 140, 165, 190, 215, 240, 290, 340, 420};
fc12gains := array[] of {-99, -40, 71, 179, 192};
fc13gains := array[] of {-99, -73, -65, -63, -60, -58, -54, 58, 61, 63, 65, 67, 68, 70, 71, 179, 181, 182, 184, 186, 188, 191, 197};
fc2580gains := array[] of {0};
r82xgains := array[] of {0, 9, 14, 27, 37, 77, 87, 125, 144, 157, 166, 197, 207, 229, 254, 280, 297, 328, 338, 364, 372, 386, 402, 421, 434, 439, 445, 480, 496};

# what the dialler and the stream's reader send the server
Dopen, Ddata, Dend: con iota;
Event: adt {
	gen:	int;
	kind:	int;
	conn:	ref Sys->Connection;	# Dopen: nil when the dial failed
	tuner:	int;
	ngains:	int;
	data:	array of byte;	# Ddata
	err:	string;
};

# a request from one of the connections; m nil when the connection is gone
Req: adt {
	srv:	ref Styxserver;
	m:	ref Tmsg;
};

# an open of iq
Client: adt {
	srv:	ref Styxserver;
	fid:	int;
	front:	list of array of byte;	# the queue: front, then back reversed
	back:	list of array of byte;
	off:	int;			# into hd front
	n:	int;			# bytes queued
	rd:	ref Tmsg.Read;		# a read waiting
	ended:	int;			# the stream it was reading is gone
	err:	string;			# why, if not an end of file

	put:	fn(c: self ref Client, b: array of byte): int;
	end:	fn(c: self ref Client, err: string);
	reply:	fn(c: self ref Client);
};

Settings: adt {
	freq:	big;
	rate:	int;
	gain:	int;	# tenths of a dB, or Auto
	ppm:	int;
	agc:	int;
	direct:	int;	# 0 off, 1 i, 2 q
	biastee:	int;
};
Auto: con 16r7fffffff;
directs := array[] of {"off", "i", "q"};

user := "sdr";
greetwait := 15*1000;	# rtl_tcp takes 5s to take a new client after the last
lingerms := 10*1000;	# the connection held after its last reader or setting
settlems := 300;	# samples dropped after rtl_tcp has applied a setting
Cmdms: con 150;		# rtl_tcp applies a command in 25-120ms, one at a time
given := big 0;		# bytes the readers of iq were given
ncmds := 0;		# commands sent to rtl_tcp
stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	if(arg == nil || styx == nil || styxservers == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	styx->init();
	styxservers->init(styx);

	mnt := "/mnt/sdr";
	spec := "sdr";
	arg->init(argv);
	arg->setusage("sdrfs [-S] [-l seconds] [-m mountpoint] [-s spec] [-t ms] [-w seconds] [command ...]");
	while((o := arg->opt()) != 0)
		case o {
		'm' =>
			mnt = arg->earg();
		's' =>
			spec = arg->earg();
		'S' =>
			spec = nil;
		'l' =>
			lingerms = int arg->earg() * 1000;
			if(lingerms < 0)
				arg->usage();
		't' =>
			settlems = int arg->earg();
			if(settlems < 0)
				arg->usage();
		'w' =>
			greetwait = int arg->earg() * 1000;
			if(greetwait <= 0)
				arg->usage();
		* =>
			arg->usage();
		}
	cmd := "";
	for(argv = arg->argv(); argv != nil; argv = tl argv)
		cmd += " " + hd argv;

	if(sys->stat(mnt + "/iq").t0 >= 0)
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
	sys->fprint(stderr, "sdrfs: %s\n", s);
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
# The server: one proc owns all the state.  Requests come from every
# connection on reqc; the dialler and the stream's reader report on
# evc, marked with the generation of the dial, so a stream hung up
# on says nothing more.
#
server(reqc: chan of ref Req, spec: string, navops: chan of ref Navop,
	mfd: ref Sys->FD, pidc: chan of int)
{
	pid := sys->pctl(Sys->NEWFD|Sys->FORKNS, mfd.fd :: 2 :: nil);
	stderr = sys->fildes(2);
	conns := chan of ref Sys->FD;
	posted := 0;
	if(spec != nil) {
		post9p = load Post9p Post9p->PATH;
		if(post9p == nil)
			sys->fprint(stderr, "sdrfs: cannot load post9p: %r: not posted\n");
		else {
			post9p->init();
			(nil, perr) := post9p->post(spec, conns);
			if(perr != nil)
				sys->fprint(stderr, "sdrfs: post #s%s: %s\n", spec, perr);
			else
				posted = 1;
		}
	}
	pidc <-= pid;

	set := ref Settings(big 100000000, 2048000, Auto, 0, 0, 0, 0);
	source := "";		# rtl_tcp's address, "" none
	tuner := -1;		# from its greeting, once dialled
	ngains := 0;
	link := "none";
	srcerr := "";
	dropped := big 0;
	skipped := big 0;
	settleuntil := sys->millisec();	# samples before this were tuned before a setting took
	busyuntil := settleuntil;	# rtl_tcp still applying commands until about this
	n0 := 0;
	lingerc := chan of int;
	ltok := 0;		# the linger timer that counts; a later one replaces it
	clients: list of ref Client;

	evc := chan of ref Event;
	gen := 0;
	conn: ref Sys->Connection;	# the stream's, while it is open
	readerpid := -1;
	dialling := 0;
	ctlwait: ref Tmsg.Write;	# a source command waiting for its dial
	ctlsrv: ref Styxserver;
	waitsrc := "";
	nconn := 1;

Serve:
	for(;;) alt {
	fd := <-conns =>
		(tc, srv) := Styxserver.new(fd, Navigator.new(navops), Qroot);
		spawn forward(srv, tc, reqc);
		nconn++;

	ev := <-evc =>
		if(ev.gen != gen)
			break;
		case ev.kind {
		Dopen =>
			dialling = 0;
			if(ev.conn == nil) {
				link = "error";
				srcerr = ev.err;
				if(ctlwait != nil) {
					ctlsrv.reply(ref Rmsg.Error(ctlwait.tag, ev.err));
					ctlwait = nil;
					source = "";
					link = "none";
				}
				for(l := clients; l != nil; l = tl l)
					(hd l).end(ev.err);
				break;
			}
			if(ctlwait != nil) {
				source = waitsrc;
				ctlsrv.reply(ref Rmsg.Write(ctlwait.tag, len ctlwait.data));
				ctlwait = nil;
			}
			srcerr = "";
			tuner = ev.tuner;
			ngains = ev.ngains;
			set.gain = nearest(tuner, set.gain);
			# kept as the stream's, even for a source command's
			# dial with nobody listening: rtl_tcp takes 5s to
			# take the next client
			conn = ev.conn;
			link = "open";
			n0 = ncmds;
			e := sendall(conn.dfd, set);
			(busyuntil, settleuntil) = sent(ncmds - n0, busyuntil);
			if(e != nil) {
				hangup(conn, readerpid, settleuntil);
				conn = nil;
				link = "error";
				srcerr = e;
				gen++;
				for(l := clients; l != nil; l = tl l)
					(hd l).end(e);
				break;
			}
			rpidc := chan of int;
			spawn reader(gen, conn.dfd, evc, rpidc);
			readerpid = <-rpidc;
			if(listening(clients) == 0)
				spawn lingertimer(++ltok, lingerms, lingerc);
		Ddata =>
			if(sys->millisec() - settleuntil < 0) {
				skipped += big len ev.data;
				break;
			}
			for(l := clients; l != nil; l = tl l)
				dropped += big (hd l).put(ev.data);
		Dend =>
			readerpid = -1;
			conn = nil;
			gen++;
			if(ev.err != nil) {
				link = "error";
				srcerr = ev.err;
			} else
				link = "closed";
			for(l := clients; l != nil; l = tl l)
				(hd l).end(ev.err);
		}

	t := <-lingerc =>
		# held long enough with nothing listening: hang up
		if(t != ltok || conn == nil || listening(clients) > 0)
			break;
		hangup(conn, readerpid, settleuntil);
		conn = nil;
		readerpid = -1;
		gen++;
		link = "idle";

	r := <-reqc =>
		srv := r.srv;
		if(r.m == nil) {
			nl: list of ref Client;
			for(l := clients; l != nil; l = tl l)
				if((hd l).srv != srv)
					nl = hd l :: nl;
			clients = nl;
			if(ctlsrv == srv)
				ctlwait = nil;
			if(listening(clients) == 0 && conn != nil)
				spawn lingertimer(++ltok, lingerms, lingerc);
			if(--nconn == 0 && !posted)
				break Serve;
			break;
		}
		pick m := r.m {
		Open =>
			f := srv.open(m);
			if(f == nil || f.path != Qiq)
				break;
			clients = ref Client(srv, m.fid, nil, nil, 0, 0, nil, 0, nil) :: clients;
			if(conn != nil || dialling)
				break;
			if(source == "") {
				(hd clients).end("no source");
				break;
			}
			# the first listener: dial
			gen++;
			dialling = 1;
			link = "opening";
			spawn dial(gen, source, evc);
		Read =>
			(f, err) := srv.canread(m);
			if(f == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			case f.path {
			Qctl =>
				s := "";
				if(source != "")
					s = "source " + source + "\n";
				s += settings(set);
				srv.reply(styxservers->readstr(m, s));
			Qstatus =>
				s := "link=" + link;
				if(source != "")
					s += " source=" + quote(source);
				if(tuner >= 0)
					s += sys->sprint(" tuner=%s gains=%d", tunername(tuner), ngains);
				s += sys->sprint(" readers=%d bytes=%bd dropped=%bd skipped=%bd", listening(clients), given, dropped, skipped);
				if(srcerr != nil)
					s += " error=" + quote(srcerr);
				srv.reply(styxservers->readstr(m, s + "\n"));
			Qgains =>
				s := "";
				g := gaintable(tuner);
				for(i := 0; i < len g; i++)
					s += tenths(g[i]) + "\n";
				srv.reply(styxservers->readstr(m, s));
			Qiq =>
				c := client(clients, srv, m.fid);
				if(c == nil) {
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadfid));
					break;
				}
				if(c.rd != nil) {
					srv.reply(ref Rmsg.Error(m.tag, "a read is already waiting"));
					break;
				}
				c.rd = m;
				c.reply();
			* =>
				srv.read(m);
			}
		Write =>
			(f, err) := srv.canwrite(m);
			if(f == nil) {
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			if(f.path != Qctl) {
				srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
				break;
			}
			if(ctlwait != nil) {
				srv.reply(ref Rmsg.Error(m.tag, "busy: a source is being dialled"));
				break;
			}
			# every line checked before any is done
			(nil, lines) := sys->tokenize(string m.data, "\n");
			nset := ref *set;
			nsrc := "";
			stop := 0;
			perr := "";
			changed: list of int;
			for(; lines != nil && perr == ""; lines = tl lines) {
				(nil, w) := sys->tokenize(hd lines, " \t\r");
				if(w == nil)
					continue;
				case hd w {
				"source" =>
					if(len w != 2)
						perr = "usage: source tcp!host!port";
					else {
						nsrc = dialaddr(hd tl w);
						stop = 0;
					}
				"stop" =>
					if(len w != 1)
						perr = "usage: stop";
					else {
						stop = 1;
						nsrc = "";
					}
				* =>
					(c, e) := setting(nset, w, tuner);
					if(e != nil)
						perr = e;
					else
						changed = c :: changed;
				}
			}
			if(perr != "") {
				srv.reply(ref Rmsg.Error(m.tag, perr));
				break;
			}
			*set = *nset;
			if(conn != nil) {
				# the gain last, and again after direct or agc,
				# which lose it (sendall)
				e: string;
				regain := 0;
				n0 = ncmds;
				for(l := rev(changed); l != nil && e == nil; l = tl l) {
					case hd l {
					Cgainmode or Cdirect or Cagc =>
						regain = 1;
					}
					if(hd l != Cgainmode)
						e = sendone(conn.dfd, set, hd l);
				}
				if(regain && e == nil)
					e = sendone(conn.dfd, set, Cgainmode);
				(busyuntil, settleuntil) = sent(ncmds - n0, busyuntil);
				if(e != nil) {
					srv.reply(ref Rmsg.Error(m.tag, e));
					break;
				}
				if(changed != nil && listening(clients) == 0)
					spawn lingertimer(++ltok, lingerms, lingerc);
			}
			if(!stop && nsrc == "") {
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
				break;
			}
			# a new source, or none: hang up the old
			if(conn != nil)
				hangup(conn, readerpid, settleuntil);
			conn = nil;
			readerpid = -1;
			dialling = 0;
			gen++;
			source = "";
			tuner = -1;
			ngains = 0;
			srcerr = "";
			link = "none";
			for(l := clients; l != nil; l = tl l)
				(hd l).end("source changed");
			if(stop) {
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
				break;
			}
			# dialled now, to say whether it is rtl_tcp; kept if
			# anything is listening
			link = "opening";
			ctlwait = m;
			ctlsrv = srv;
			waitsrc = nsrc;
			dialling = 1;
			spawn dial(gen, nsrc, evc);
		Flush =>
			for(l := clients; l != nil; l = tl l)
				if((hd l).srv == srv && (hd l).rd != nil && (hd l).rd.tag == m.oldtag)
					(hd l).rd = nil;
			if(ctlwait != nil && ctlsrv == srv && ctlwait.tag == m.oldtag)
				ctlwait = nil;
			srv.default(r.m);
		Clunk =>
			nl: list of ref Client;
			for(l := clients; l != nil; l = tl l)
				if((hd l).srv != srv || (hd l).fid != m.fid)
					nl = hd l :: nl;
			clients = nl;
			srv.clunk(m);
			# the last listener gone: hang up once it has been
			# gone a while
			if(listening(clients) == 0 && conn != nil)
				spawn lingertimer(++ltok, lingerms, lingerc);
		* =>
			srv.default(r.m);
		}
	}
}

client(l: list of ref Client, srv: ref Styxserver, fid: int): ref Client
{
	for(; l != nil; l = tl l)
		if((hd l).srv == srv && (hd l).fid == fid)
			return hd l;
	return nil;
}

# the opens of iq still reading a stream
listening(l: list of ref Client): int
{
	n := 0;
	for(; l != nil; l = tl l)
		if(!(hd l).ended)
			n++;
	return n;
}

rev(l: list of int): list of int
{
	r: list of int;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

# samples queued for a reader; the oldest dropped if it is too far
# behind.  Every chunk is a whole number of samples, so dropping whole
# chunks keeps I and Q in step.  The bytes dropped.
Client.put(c: self ref Client, b: array of byte): int
{
	if(c.ended)
		return 0;
	c.back = b :: c.back;
	c.n += len b;
	lost := 0;
	while(c.n > Maxqueue) {
		if(c.front == nil) {
			for(; c.back != nil; c.back = tl c.back)
				c.front = hd c.back :: c.front;
		}
		k := len hd c.front - c.off;
		c.n -= k;
		lost += k;
		c.front = tl c.front;
		c.off = 0;
	}
	c.reply();
	return lost;
}

Client.end(c: self ref Client, err: string)
{
	if(c.ended)
		return;
	c.ended = 1;
	c.err = err;
	c.reply();
}

# a waiting read given what is queued, up to its count and from as
# many chunks as that takes, a whole number of samples when it can be;
# a stream, not a file, so the offset is not looked at
Client.reply(c: self ref Client)
{
	if(c.rd == nil)
		return;
	if(c.n == 0) {
		if(!c.ended)
			return;
		if(c.err != nil)
			c.srv.reply(ref Rmsg.Error(c.rd.tag, c.err));
		else
			c.srv.reply(ref Rmsg.Read(c.rd.tag, nil));
		c.rd = nil;
		return;
	}
	if(c.front == nil) {
		for(; c.back != nil; c.back = tl c.back)
			c.front = hd c.back :: c.front;
	}
	want := c.rd.count;
	if(want > c.n)
		want = c.n;
	if(want > 1)
		want &= ~1;
	b := hd c.front;
	out: array of byte;
	if(len b - c.off >= want) {
		out = b[c.off:c.off+want];	# within one chunk: no copy
		c.off += want;
		if(c.off == len b) {
			c.front = tl c.front;
			c.off = 0;
		}
	} else {
		out = array[want] of byte;
		for(o := 0; o < want; ) {
			if(c.front == nil) {
				for(; c.back != nil; c.back = tl c.back)
					c.front = hd c.back :: c.front;
			}
			b = hd c.front;
			k := len b - c.off;
			if(k > want - o)
				k = want - o;
			out[o:] = b[c.off:c.off+k];
			o += k;
			c.off += k;
			if(c.off == len b) {
				c.front = tl c.front;
				c.off = 0;
			}
		}
	}
	c.srv.reply(ref Rmsg.Read(c.rd.tag, out));
	c.rd = nil;
	c.n -= want;
	given += big want;
}

#
# rtl_tcp
#

# localhost is dialled as 127.0.0.1, where rtl_tcp should listen: with
# no connection server (sh without -l) the name is not resolved
dialaddr(a: string): string
{
	a = canon(a);
	(n, f) := sys->tokenize(a, "!");
	if(n == 3 && hd tl f == "localhost")
		return hd f + "!127.0.0.1!" + hd tl tl f;
	return a;
}

canon(a: string): string
{
	n := 0;
	for(i := 0; i < len a; i++)
		if(a[i] == '!')
			n++;
	case n {
	0 =>
		return "tcp!" + a + "!" + Port;
	1 =>
		return "tcp!" + a;
	}
	return a;
}

# dial rtl_tcp and read its greeting
dial(gen: int, addr: string, evc: chan of ref Event)
{
	(ok, c) := sys->dial(addr, nil);
	if(ok < 0) {
		evc <-= ref Event(gen, Dopen, nil, 0, 0, nil, sys->sprint("dial %s: %r", addr));
		return;
	}
	# rtl_tcp serves one client at a time: while another holds it, a
	# dial is answered but not greeted
	gc := chan[1] of (array of byte, string);
	spawn greeting(c.dfd, gc);
	tc := chan[1] of int;
	spawn timer(greetwait, tc);
	b: array of byte;
	e: string;
	alt {
	(b, e) = <-gc =>
		;
	<-tc =>
		if(c.cfd != nil)
			sys->fprint(c.cfd, "hangup");
		evc <-= ref Event(gen, Dopen, nil, 0, 0, nil,
			sys->sprint("%s: not greeted in %d seconds: rtl_tcp busy with another client?", addr, greetwait/1000));
		return;
	}
	if(e != nil) {
		evc <-= ref Event(gen, Dopen, nil, 0, 0, nil, sys->sprint("%s: no greeting: %s", addr, e));
		return;
	}
	if(string b[0:4] != "RTL0") {
		evc <-= ref Event(gen, Dopen, nil, 0, 0, nil, addr + ": not rtl_tcp: no RTL0 greeting");
		return;
	}
	evc <-= ref Event(gen, Dopen, ref c, get32(b, 4), get32(b, 8), nil, nil);
}

greeting(fd: ref Sys->FD, gc: chan of (array of byte, string))
{
	b := array[Greeting] of byte;
	for(n := 0; n < Greeting; ) {
		k := sys->read(fd, b[n:], Greeting - n);
		if(k <= 0) {
			e := "hung up";
			if(k < 0)
				e = sys->sprint("%r");
			gc <-= (nil, e);
			return;
		}
		n += k;
	}
	gc <-= (b, nil);
}

lingertimer(tok: int, ms: int, lc: chan of int)
{
	sys->sleep(ms);
	lc <-= tok;
}

timer(ms: int, tc: chan of int)
{
	sys->sleep(ms);
	tc <-= 1;
}

# the stream, in chunks of whole samples
reader(gen: int, fd: ref Sys->FD, evc: chan of ref Event, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	buf := array[Chunk+1] of byte;
	have := 0;	# a byte carried over: half a sample
	for(;;) {
		n := sys->read(fd, buf[have:], Chunk);
		if(n <= 0) {
			e: string;
			if(n < 0)
				e = sys->sprint("%r");
			evc <-= ref Event(gen, Dend, nil, 0, 0, nil, e);
			return;
		}
		n += have;
		k := n & ~1;
		if(k > 0) {
			d := array[k] of byte;
			d[0:] = buf[0:k];
			evc <-= ref Event(gen, Ddata, nil, 0, 0, d, nil);
		}
		have = n - k;
		if(have)
			buf[0] = buf[k];
	}
}

# the reader stopped now; the connection hung up once settings sent
# before until have been applied: rtl_tcp (librtlsdr 2.0.1) has crashed
# hung up on while still applying them
hangup(c: ref Sys->Connection, readerpid: int, until: int)
{
	if(readerpid >= 0) {
		fd := sys->open("/prog/" + string readerpid + "/ctl", Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "kill");
	}
	if(c.cfd == nil)
		return;
	if((d := until - sys->millisec()) > 0)
		spawn latehangup(c.cfd, d);
	else
		sys->fprint(c.cfd, "hangup");
}

latehangup(cfd: ref Sys->FD, ms: int)
{
	sys->sleep(ms);
	sys->fprint(cfd, "hangup");
}

get32(b: array of byte, i: int): int
{
	return (int b[i] << 24) | (int b[i+1] << 16) | (int b[i+2] << 8) | int b[i+3];
}

# n commands just sent: when rtl_tcp should be done with them, and
# when samples are tuned as they say
sent(n: int, busy: int): (int, int)
{
	now := sys->millisec();
	if(busy - now < 0)
		busy = now;
	busy += n * Cmdms;
	return (busy, busy + settlems);
}

command(fd: ref Sys->FD, code: int, v: int): string
{
	ncmds++;
	b := array[5] of byte;
	b[0] = byte code;
	b[1] = byte (v >> 24);
	b[2] = byte (v >> 16);
	b[3] = byte (v >> 8);
	b[4] = byte v;
	if(sys->write(fd, b, len b) != len b)
		return sys->sprint("rtl_tcp: %r");
	return nil;
}

# every setting, the gain last.  On an RTL-SDR Blog V4 (R828D) through
# librtlsdr 2.0, direct sampling set (even off, as it was) leaves the
# tuner's gain at its least, about 45 dB down, and the RTL2832U's AGC
# turned on and off can leave it stuck high; the gain set after them
# puts it right.  rtl_tcp keeps a dongle's settings from one client to
# the next, so all are sent.
sendall(fd: ref Sys->FD, s: ref Settings): string
{
	for(l := Crate :: Cfreq :: Cppm :: Cbiastee :: Cagc :: Cdirect :: Cgainmode :: nil; l != nil; l = tl l)
		if((e := sendone(fd, s, hd l)) != nil)
			return e;
	return nil;
}

sendone(fd: ref Sys->FD, s: ref Settings, what: int): string
{
	case what {
	Cfreq =>
		return command(fd, Cfreq, int s.freq);
	Crate =>
		return command(fd, Crate, s.rate);
	Cgainmode =>
		if(s.gain == Auto)
			return command(fd, Cgainmode, 0);
		if((e := command(fd, Cgainmode, 1)) != nil)
			return e;
		return command(fd, Cgain, s.gain);
	Cppm =>
		return command(fd, Cppm, s.ppm);
	Cagc =>
		return command(fd, Cagc, s.agc);
	Cdirect =>
		return command(fd, Cdirect, s.direct);
	Cbiastee =>
		return command(fd, Cbiastee, s.biastee);
	}
	return nil;
}

#
# settings
#

settings(s: ref Settings): string
{
	g := "auto";
	if(s.gain != Auto)
		g = tenths(s.gain);
	return sys->sprint("freq %bd\nrate %d\ngain %s\nppm %d\nagc %s\ndirect %s\nbiastee %s\n",
		s.freq, s.rate, g, s.ppm, onoff(s.agc), directs[s.direct], onoff(s.biastee));
}

onoff(v: int): string
{
	if(v)
		return "on";
	return "off";
}

# one setting into s: which it was, or why not
setting(s: ref Settings, w: list of string, tuner: int): (int, string)
{
	verb := hd w;
	if(len w != 2)
		return (0, "usage: " + verb + " value");
	v := hd tl w;
	case verb {
	"freq" =>
		(f, ok) := hertz(v);
		if(!ok || f <= big 0 || f > big 16rffffffff)
			return (0, "bad frequency " + v);
		s.freq = f;
		return (Cfreq, nil);
	"rate" =>
		(f, ok) := hertz(v);
		# what librtlsdr takes
		if(!ok || f <= big 225000 || f > big 3200000 || (f > big 300000 && f <= big 900000))
			return (0, "bad rate " + v + ": 225001-300000 or 900001-3200000 samples a second");
		s.rate = int f;
		return (Crate, nil);
	"gain" =>
		if(v == "auto") {
			s.gain = Auto;
			return (Cgainmode, nil);
		}
		(t, ok) := decitenths(v);
		if(!ok)
			return (0, "bad gain " + v);
		s.gain = nearest(tuner, t);
		return (Cgainmode, nil);
	"ppm" =>
		(n, ok) := integer(v);
		if(!ok || n < -1000 || n > 1000)
			return (0, "bad ppm " + v);
		s.ppm = n;
		return (Cppm, nil);
	"agc" or "biastee" =>
		b: int;
		case v {
		"on" =>
			b = 1;
		"off" =>
			b = 0;
		* =>
			return (0, verb + ": on or off");
		}
		if(verb == "agc") {
			s.agc = b;
			return (Cagc, nil);
		}
		s.biastee = b;
		return (Cbiastee, nil);
	"direct" =>
		case v {
		"off" =>
			s.direct = 0;
		"i" =>
			s.direct = 1;
		"q" =>
			s.direct = 2;
		* =>
			return (0, "direct: off, i or q");
		}
		return (Cdirect, nil);
	}
	return (0, "unknown command " + verb);
}

# a number of hertz, with k, M or G
hertz(v: string): (big, int)
{
	if(v == nil)
		return (big 0, 0);
	m := 1.0;
	case v[len v - 1] {
	'k' or 'K' =>
		m = 1e3;
	'M' =>
		m = 1e6;
	'G' =>
		m = 1e9;
	}
	if(m != 1.0)
		v = v[0:len v - 1];
	if(!isdecimal(v))
		return (big 0, 0);
	if(m == 1.0) {
		for(i := 0; i < len v; i++)
			if(v[i] == '.')
				return (big 0, 0);
		return (big v, 1);
	}
	return (big (real v * m), 1);
}

isdecimal(v: string): int
{
	dot := 0;
	digits := 0;
	for(i := 0; i < len v; i++) {
		if(v[i] == '.' && !dot)
			dot = 1;
		else if(v[i] >= '0' && v[i] <= '9')
			digits++;
		else
			return 0;
	}
	return digits > 0;
}

integer(v: string): (int, int)
{
	s := v;
	if(s != nil && (s[0] == '-' || s[0] == '+'))
		s = s[1:];
	if(s == nil)
		return (0, 0);
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return (0, 0);
	if(len s > 9)
		return (0, 0);
	return (int v, 1);
}

# dB to tenths
decitenths(v: string): (int, int)
{
	s := v;
	neg := 0;
	if(s != nil && s[0] == '-') {
		neg = 1;
		s = s[1:];
	}
	if(!isdecimal(s) || len s > 8)
		return (0, 0);
	t := int (real s * 10.0);
	if(neg)
		t = -t;
	return (t, 1);
}

tenths(t: int): string
{
	sign := "";
	if(t < 0) {
		sign = "-";
		t = -t;
	}
	return sys->sprint("%s%d.%d", sign, t / 10, t % 10);
}

tunername(t: int): string
{
	if(t >= 0 && t < len tuners)
		return tuners[t];
	return string t;
}

gaintable(t: int): array of int
{
	case t {
	1 =>
		return e4kgains;
	2 =>
		return fc12gains;
	3 =>
		return fc13gains;
	4 =>
		return fc2580gains;
	5 or 6 =>
		return r82xgains;
	}
	return nil;
}

# the tuner's gain nearest g, or g if its gains are not known
nearest(tuner: int, g: int): int
{
	if(g == Auto)
		return g;
	tab := gaintable(tuner);
	if(tab == nil)
		return g;
	best := tab[0];
	for(i := 1; i < len tab; i++)
		if(abs(tab[i] - g) < abs(best - g))
			best = tab[i];
	return best;
}

abs(x: int): int
{
	if(x < 0)
		return -x;
	return x;
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
