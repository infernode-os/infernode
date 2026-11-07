implement Visionfs;

#
# visionfs - recognition as files: vision(4), at /mnt/vision (#1086)
#
#	/mnt/vision/
#		ctl		w  load NAME DIR | unload NAME
#				r  engine cpu / places cpu / each model: model NAME DIR
#		models/NAME/info	kind=detect decode=yolox input=416x416 classes=80 ...
#		models/NAME/classes	one class name a line
#		clone		read: a new session's number, N
#		N/ctl		rw model NAME | thresh R | iou R | classes A B ... | classes all
#				   src FEED | src none | rate FPS
#		N/image		w  one picture (JPEG, PNG, ..., a P6 PPM), in as many
#				   writes as it takes; it is looked at when the file is closed
#		N/detections	r  what was found, one record a line, best first:
#				   class=dog score=0.86 x0=133 y0=207 x1=326 y1=543
#				   a read waits while the picture is looked at.  Following
#				   a feed, each read is one frame's records, each line
#				   beginning frame=N pts=MS, a frame with nothing found
#				   that alone; a read waits for the next frame
#		N/layer/vision.N	the same, as a layer (#1095)
#		N/status	state=idle|running|ready|following|ended|error model=NAME ...
#		N/stats		images= ms= found=, or for a feed in= inferred= skipped= ...
#
# The models are vision(4) model directories (tools/vision/onnx2vis.py),
# run by appl/lib/visnet.b on $Tensor. A session lasts while any of its
# files is open. Each picture, and each feed, is looked at in a proc of
# its own, so one session never holds up another, nor the server.
#
# A feed is a directory of the vid9p schema (fmt, frame, status):
# vid9p(1)'s, camsrv(4)'s, or another machine's mounted. The detector
# never holds the feed back: it takes the newest frame when it is ready
# for one and counts the frames it never saw (skipped=); a clip that has
# ended (eof=1) is looked at frame by frame, every one.
#
#	visionfs [-m mountpoint] [-s spec] [-S] [load NAME DIR]
#
# -s posts the server in #s as spec (default vision), so a VM other than
# the one it runs in can mount it; -S posts nothing.
#

include "sys.m";
	sys: Sys;
	Qid: import Sys;
include "draw.m";
include "arg.m";
include "string.m";
	str: String;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator, Navop: import styxservers;
include "post9p.m";
	post9p: Post9p;
include "visnet.m";
	visnet: Visnet;
	Net, Det: import visnet;

Visionfs: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

Qroot, Qctl, Qclone, Qmodels, Qmodel, Qminfo, Qmclasses,
Qsess, Qsctl, Qsimage, Qsdet, Qsstatus, Qsstats, Qslayer, Qslayerf: con iota;

Maximage: con 64*1024*1024;
Ringsz: con 16;		# a feed's frames whose records are kept for readers behind
Nms: con 64;		# the times kept for stats

stderr: ref Sys->FD;
user := "inferno";

# what the navigator sees: replaced whole by the server at each change,
# so it never sees one half made
Snap: adt {
	models:	list of (int, string);	# id, name
	sessions:	list of int;
};
snap: ref Snap;

Model: adt {
	id:	int;
	name:	string;
	dir:	string;
	net:	ref Net;
};

Session: adt {
	id:	int;
	refs:	int;
	model:	ref Model;
	thresh, iou:	real;
	classes:	list of string;	# nil: all
	state:	string;
	err:	string;

	# a picture
	text:	string;			# the records
	gen:	int;			# which picture's answer is wanted
	reads:	list of (ref Styxserver, ref Tmsg.Read);
	images:	int;
	found:	int;
	ms:	int;

	# a feed
	src:	string;
	rate:	int;			# frames a second at most, 0 as many as it can
	fgen:	int;			# which follower's frames are wanted
	fpid:	int;
	ring:	array of (int, string);	# the last frames' records, by sequence
	nseq:	int;			# the next frame's sequence number
	ended:	int;
	nin, inferred, skipped:	int;
	mss:	array of int;		# the last times taken
	stamps:	array of int;		# when the last frames were done
	nms:	int;
};

# a reader of a session's detections, with its place in a feed
Freader: adt {
	srv:	ref Styxserver;
	fid:	int;
	sess:	int;
	next:	int;
	rd:	ref Tmsg.Read;
};

Openf: adt {
	srv:	ref Styxserver;
	fid:	int;
	sess:	int;			# -1 for none
};

Req: adt {
	srv:	ref Styxserver;
	m:	ref Tmsg;
};

Result: adt {
	sess, gen:	int;
	text, err:	string;
	found, ms:	int;
};

Frameres: adt {
	sess, fgen:	int;
	text, err:	string;
	ms, skipped:	int;
	ended:	int;
};

Loaded: adt {
	srv:	ref Styxserver;
	tag:	int;
	name, dir:	string;
	net:	ref Net;
	err:	string;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	str = load String String->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	visnet = load Visnet Visnet->PATH;
	if(arg == nil || str == nil || styx == nil || styxservers == nil || visnet == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	if((e := visnet->init()) != nil)
		fatal(e);
	styx->init();
	styxservers->init(styx);

	mnt := "/mnt/vision";
	spec := "vision";
	arg->init(argv);
	arg->setusage("visionfs [-m mountpoint] [-s spec] [-S] [load name dir]");
	while((o := arg->opt()) != 0)
		case o {
		'm' =>	mnt = arg->earg();
		's' =>	spec = arg->earg();
		'S' =>	spec = nil;
		* =>	arg->usage();
		}
	cmd := "";
	for(argv = arg->argv(); argv != nil; argv = tl argv)
		cmd += " " + hd argv;

	# served already: a clone there that is a mount, not a file left behind
	(cok, cd) := sys->stat(mnt + "/clone");
	if(cok >= 0 && cd.dtype == 'M')
		fatal(mnt + " is served already");
	if(sys->stat(mnt).t0 < 0)
		sys->create(mnt, Sys->OREAD, Sys->DMDIR|8r775);
	if((u := readfile("/dev/user")) != nil)
		user = u;
	snap = ref Snap(nil, nil);

	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		fatal(sys->sprint("pipe: %r"));
	navops := chan of ref Navop;
	spawn navigator(navops);
	reqc := chan of ref Req;
	(tchan, srv) := Styxserver.new(fds[0], Navigator.new(navops), big Qroot);
	fds[0] = nil;
	spawn forward(srv, tchan, reqc);
	pidc := chan of int;
	spawn server(reqc, spec, navops, srv.fd, pidc);
	<-pidc;
	if(sys->mount(fds[1], nil, mnt, Sys->MREPL, nil) < 0)
		fatal(sys->sprint("mount %s: %r", mnt));
	fds[1] = nil;
	if(cmd != nil){
		fd := sys->open(mnt + "/ctl", Sys->OWRITE);
		if(fd == nil || sys->fprint(fd, "%s", cmd[1:]) < 0)
			fatal(sys->sprint("%s: %r", cmd[1:]));
	}
}

fatal(s: string)
{
	sys->fprint(stderr, "visionfs: %s\n", s);
	raise "fail:" + s;
}

readfile(f: string): string
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[512] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	return string b[0:n];
}

forward(srv: ref Styxserver, tchan: chan of ref Tmsg, reqc: chan of ref Req)
{
	for(;;){
		m := <-tchan;
		if(m != nil && tagof m == tagof Tmsg.Readerror)
			m = nil;
		reqc <-= ref Req(srv, m);
		if(m == nil)
			return;
	}
}

# ---- the server: one proc holds all the state ----

models: list of ref Model;
sessions: list of ref Session;
opens: list of ref Openf;
freaders: list of ref Freader;
nextmodel := 1;
nextsess := 1;
framec: chan of ref Frameres;

server(reqc: chan of ref Req, spec: string, navops: chan of ref Navop, mfd: ref Sys->FD, pidc: chan of int)
{
	pid := sys->pctl(Sys->NEWFD, mfd.fd :: 2 :: nil);
	stderr = sys->fildes(2);
	conns := chan of ref Sys->FD;
	posted := 0;
	if(spec != nil){
		post9p = load Post9p Post9p->PATH;
		if(post9p == nil)
			sys->fprint(stderr, "visionfs: cannot load post9p: %r: not posted\n");
		else {
			post9p->init();
			(nil, perr) := post9p->post(spec, conns);
			if(perr != nil)
				sys->fprint(stderr, "visionfs: post #s%s: %s\n", spec, perr);
			else
				posted = 1;
		}
	}
	pidc <-= pid;
	resc := chan of ref Result;
	loadc := chan of ref Loaded;
	framec = chan of ref Frameres;
	nconn := 1;

Serve:
	for(;;) alt {
	fd := <-conns =>
		(tc, srv) := Styxserver.new(fd, Navigator.new(navops), big Qroot);
		spawn forward(srv, tc, reqc);
		nconn++;

	r := <-resc =>
		s := session(r.sess);
		if(s == nil || s.gen != r.gen)
			break;
		if(r.err != nil){
			s.state = "error";
			s.err = r.err;
		} else {
			s.state = "ready";
			s.err = nil;
			s.text = r.text;
			s.found = r.found;
			s.ms = r.ms;
		}
		for(l := s.reads; l != nil; l = tl l)
			answer(s, (hd l).t0, (hd l).t1);
		s.reads = nil;

	fr := <-framec =>
		s := session(fr.sess);
		if(s == nil || s.fgen != fr.fgen)
			break;
		if(fr.err != nil || fr.ended){
			s.ended = 1;
			s.fpid = -1;
			if(fr.err != nil){
				s.state = "error";
				s.err = fr.err;
			} else
				s.state = "ended";
		} else {
			s.ring[s.nseq % Ringsz] = (s.nseq, fr.text);
			s.nseq++;
			s.inferred++;
			s.nin += 1 + fr.skipped;
			s.skipped += fr.skipped;
			s.mss[s.nms % Nms] = fr.ms;
			s.stamps[s.nms % Nms] = sys->millisec();
			s.nms++;
			s.state = "following";
		}
		for(fl := freaders; fl != nil; fl = tl fl)
			if((hd fl).sess == s.id && (hd fl).rd != nil)
				deliver(s, hd fl);

	l := <-loadc =>
		if(l.err != nil){
			l.srv.reply(ref Rmsg.Error(l.tag, l.err));
			break;
		}
		if(model(l.name) != nil){
			l.srv.reply(ref Rmsg.Error(l.tag, "model " + l.name + " is loaded already"));
			break;
		}
		models = ref Model(nextmodel++, l.name, l.dir, l.net) :: models;
		resnap();
		l.srv.reply(ref Rmsg.Write(l.tag, 0));

	r := <-reqc =>
		srv := r.srv;
		if(r.m == nil){
			# a connection gone: its opens with it
			nl: list of ref Openf;
			for(o := opens; o != nil; o = tl o)
				if((hd o).srv == srv)
					unref((hd o).sess);
				else
					nl = hd o :: nl;
			opens = nl;
			nf: list of ref Freader;
			for(f := freaders; f != nil; f = tl f)
				if((hd f).srv != srv)
					nf = hd f :: nf;
			freaders = nf;
			for(sl := sessions; sl != nil; sl = tl sl){
				rl: list of (ref Styxserver, ref Tmsg.Read);
				for(q := (hd sl).reads; q != nil; q = tl q)
					if((hd q).t0 != srv)
						rl = hd q :: rl;
				(hd sl).reads = rl;
			}
			if(--nconn == 0 && !posted)
				break Serve;
			break;
		}
		pick m := r.m {
		Open =>
			f := srv.open(m);
			if(f == nil)
				break;
			t := int f.path & 16rFF;
			id := int (f.path >> 8);
			case t {
			Qclone =>
				s := newsession();
				s.refs++;
				opens = ref Openf(srv, m.fid, s.id) :: opens;
				f.data = array of byte sys->sprint("%d\n", s.id);
				resnap();
			Qsctl or Qsimage or Qsdet or Qsstatus or Qsstats or Qslayerf =>
				s := session(id);
				if(s == nil)
					break;
				s.refs++;
				opens = ref Openf(srv, m.fid, s.id) :: opens;
				if(t == Qsimage)
					f.data = array[0] of byte;
				if(t == Qsdet || t == Qslayerf)
					freaders = ref Freader(srv, m.fid, s.id, s.nseq, nil) :: freaders;
			}
		Read =>
			(f, err) := srv.canread(m);
			if(f == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			t := int f.path & 16rFF;
			id := int (f.path >> 8);
			case t {
			Qctl =>
				s := "engine cpu\nplaces cpu\n";
				for(ml := lastof(models); ml != nil; ml = tl ml)
					s += "model " + (hd ml).name + " " + (hd ml).dir + "\n";
				srv.reply(styxservers->readstr(m, s));
			Qclone =>
				srv.reply(styxservers->readbytes(m, f.data));
			Qminfo =>
				md := modelid(id);
				if(md == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				n := md.net;
				srv.reply(styxservers->readstr(m, sys->sprint("kind=%s decode=%s input=%dx%d classes=%d order=%s fill=%d places=cpu sha256=%s\n",
					n.kind, n.decode, n.inw, n.inh, n.nclass, n.order, n.fill, n.sha256)));
			Qmclasses =>
				md := modelid(id);
				if(md == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				s := "";
				for(i := 0; i < len md.net.classes; i++)
					s += md.net.classes[i] + "\n";
				srv.reply(styxservers->readstr(m, s));
			Qsctl or Qsstatus or Qsstats =>
				s := session(id);
				if(s == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				case t {
				Qsctl =>	srv.reply(styxservers->readstr(m, settings(s)));
				Qsstatus =>	srv.reply(styxservers->readstr(m, status(s)));
				Qsstats =>	srv.reply(styxservers->readstr(m, stats(s)));
				}
			Qsdet or Qslayerf =>
				s := session(id);
				if(s == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				if(s.src != nil){
					fr := freader(srv, m.fid);
					if(fr == nil){
						srv.reply(ref Rmsg.Error(m.tag, Styxservers->Ebadfid));
						break;
					}
					if(fr.rd != nil){
						srv.reply(ref Rmsg.Error(m.tag, "a read is already waiting"));
						break;
					}
					fr.rd = m;
					deliver(s, fr);
				} else if(s.state == "running")
					s.reads = (srv, m) :: s.reads;
				else
					answer(s, srv, m);
			* =>
				srv.read(m);
			}
		Write =>
			(f, err) := srv.canwrite(m);
			if(f == nil){
				srv.reply(ref Rmsg.Error(m.tag, err));
				break;
			}
			t := int f.path & 16rFF;
			id := int (f.path >> 8);
			case t {
			Qctl =>
				e := rootctl(srv, m, loadc);
				if(e != nil)
					srv.reply(ref Rmsg.Error(m.tag, e));
			Qsctl =>
				s := session(id);
				if(s == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				e := sessctl(s, string m.data);
				if(e != nil)
					srv.reply(ref Rmsg.Error(m.tag, e));
				else
					srv.reply(ref Rmsg.Write(m.tag, len m.data));
			Qsimage =>
				s := session(id);
				if(s != nil && s.src != nil){
					srv.reply(ref Rmsg.Error(m.tag, "following a feed: src none first"));
					break;
				}
				if(m.offset != big len f.data){
					srv.reply(ref Rmsg.Error(m.tag, "write the picture in order, from the start"));
					break;
				}
				if(len f.data + len m.data > Maximage){
					srv.reply(ref Rmsg.Error(m.tag, "picture too large"));
					break;
				}
				nd := array[len f.data + len m.data] of byte;
				nd[0:] = f.data;
				nd[len f.data:] = m.data;
				f.data = nd;
				srv.reply(ref Rmsg.Write(m.tag, len m.data));
			* =>
				srv.reply(ref Rmsg.Error(m.tag, Styxservers->Eperm));
			}
		Flush =>
			for(sl := sessions; sl != nil; sl = tl sl){
				rl: list of (ref Styxserver, ref Tmsg.Read);
				for(q := (hd sl).reads; q != nil; q = tl q)
					if((hd q).t0 != srv || (hd q).t1.tag != m.oldtag)
						rl = hd q :: rl;
				(hd sl).reads = rl;
			}
			for(fl := freaders; fl != nil; fl = tl fl)
				if((hd fl).srv == srv && (hd fl).rd != nil && (hd fl).rd.tag == m.oldtag)
					(hd fl).rd = nil;
			srv.default(r.m);
		Clunk =>
			f := srv.getfid(m.fid);
			if(f != nil && f.isopen && (int f.path & 16rFF) == Qsimage && len f.data > 0){
				s := session(int (f.path >> 8));
				if(s != nil && s.src == nil)
					look(s, f.data, resc);
			}
			nf: list of ref Freader;
			for(fl := freaders; fl != nil; fl = tl fl)
				if((hd fl).srv != srv || (hd fl).fid != m.fid)
					nf = hd fl :: nf;
			freaders = nf;
			nl: list of ref Openf;
			for(o := opens; o != nil; o = tl o)
				if((hd o).srv == srv && (hd o).fid == m.fid)
					unref((hd o).sess);
				else
					nl = hd o :: nl;
			opens = nl;
			srv.clunk(m);
		* =>
			srv.default(r.m);
		}
	}
}

newsession(): ref Session
{
	s := ref Session;
	s.id = nextsess++;
	s.thresh = 0.3;
	s.iou = 0.45;
	s.state = "idle";
	if(models != nil)
		s.model = hd lastof(models);
	s.ring = array[Ringsz] of (int, string);
	s.mss = array[Nms] of int;
	s.stamps = array[Nms] of int;
	s.fpid = -1;
	sessions = s :: sessions;
	return s;
}

lastof(l: list of ref Model): list of ref Model
{
	r: list of ref Model;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

session(id: int): ref Session
{
	for(l := sessions; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

freader(srv: ref Styxserver, fid: int): ref Freader
{
	for(l := freaders; l != nil; l = tl l)
		if((hd l).srv == srv && (hd l).fid == fid)
			return hd l;
	return nil;
}

model(name: string): ref Model
{
	for(l := models; l != nil; l = tl l)
		if((hd l).name == name)
			return hd l;
	return nil;
}

modelid(id: int): ref Model
{
	for(l := models; l != nil; l = tl l)
		if((hd l).id == id)
			return hd l;
	return nil;
}

unref(id: int)
{
	s := session(id);
	if(s == nil || --s.refs > 0)
		return;
	stopfeed(s);
	nl: list of ref Session;
	for(l := sessions; l != nil; l = tl l)
		if(hd l != s)
			nl = hd l :: nl;
	sessions = nl;
	resnap();
}

resnap()
{
	ms: list of (int, string);
	for(l := models; l != nil; l = tl l)
		ms = ((hd l).id, (hd l).name) :: ms;
	ss: list of int;
	for(sl := sessions; sl != nil; sl = tl sl)
		ss = (hd sl).id :: ss;
	snap = ref Snap(ms, ss);
}

answer(s: ref Session, srv: ref Styxserver, m: ref Tmsg.Read)
{
	case s.state {
	"ready" =>
		srv.reply(styxservers->readstr(m, s.text));
	"error" =>
		srv.reply(ref Rmsg.Error(m.tag, s.err));
	* =>
		srv.reply(ref Rmsg.Error(m.tag, "no picture yet: write one to image"));
	}
}

# a feed's reader: the next frame's records, a gap first if it fell
# behind what is kept, end of file once the feed has ended
deliver(s: ref Session, fr: ref Freader)
{
	m := fr.rd;
	if(m == nil)
		return;
	oldest := s.nseq - Ringsz;
	if(oldest < 0)
		oldest = 0;
	text := "";
	if(fr.next < oldest){
		text = sys->sprint("gap n=%d\n", oldest - fr.next);
		fr.next = oldest;
	}
	if(fr.next < s.nseq){
		(nil, t) := s.ring[fr.next % Ringsz];
		text += t;
		fr.next++;
	} else if(!s.ended){
		if(text == nil)
			return;		# waits for the next frame
	} else if(s.state == "error" && text == nil){
		fr.rd = nil;
		fr.srv.reply(ref Rmsg.Error(m.tag, s.err));
		return;
	}
	fr.rd = nil;
	d := array of byte text;
	if(len d > m.count)
		d = d[0:m.count];
	fr.srv.reply(ref Rmsg.Read(m.tag, d));
}

settings(s: ref Session): string
{
	m := "none";
	if(s.model != nil)
		m = s.model.name;
	c := "all";
	if(s.classes != nil){
		c = "";
		for(l := s.classes; l != nil; l = tl l)
			c += " " + hd l;
		c = c[1:];
	}
	src := "none";
	if(s.src != nil)
		src = s.src;
	return sys->sprint("model %s\nplace cpu\nthresh %.2f\niou %.2f\nclasses %s\nsrc %s\nrate %d\n",
		m, s.thresh, s.iou, c, src, s.rate);
}

status(s: ref Session): string
{
	m := "none";
	if(s.model != nil)
		m = s.model.name;
	st := "state=" + s.state + " model=" + m;
	if(s.src != nil)
		st += " src=" + quote(s.src);
	if(s.err != nil)
		st += " reason=" + quote(s.err);
	return st + "\n";
}

stats(s: ref Session): string
{
	if(s.src == nil && s.nms == 0)
		return sys->sprint("images=%d found=%d ms=%d\n", s.images, s.found, s.ms);
	n := s.nms;
	if(n > Nms)
		n = Nms;
	t := array[n] of int;
	t[0:] = s.mss[0:n];
	sort(t);
	(p50, p95) := (0, 0);
	if(n > 0){
		p50 = t[n/2];
		p95 = t[(n*95)/100];
	}
	fps := 0.0;
	if(n > 1){
		newest := s.stamps[(s.nms-1) % Nms];
		oldest := s.stamps[(s.nms-n) % Nms];
		if(newest > oldest)
			fps = real (n-1) * 1000.0 / real (newest - oldest);
	}
	nr := 0;
	for(l := freaders; l != nil; l = tl l)
		if((hd l).sess == s.id)
			nr++;
	return sys->sprint("in=%d inferred=%d skipped=%d fps_infer=%.1f ms_p50=%d ms_p95=%d readers=%d\n",
		s.nin, s.inferred, s.skipped, fps, p50, p95, nr);
}

sort(a: array of int)
{
	for(i := 1; i < len a; i++){
		v := a[i];
		j := i - 1;
		while(j >= 0 && a[j] > v){
			a[j+1] = a[j];
			j--;
		}
		a[j+1] = v;
	}
}

quote(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == ' ' || s[i] == '\'' || s[i] == '=')
			return str->quoted(s :: nil);
	return s;
}

rootctl(srv: ref Styxserver, m: ref Tmsg.Write, loadc: chan of ref Loaded): string
{
	(nil, w) := sys->tokenize(string m.data, " \t\r\n");
	if(w == nil)
		return "empty";
	case hd w {
	"load" =>
		if(len w != 3)
			return "usage: load name dir";
		name := hd tl w;
		if(!goodname(name))
			return "a model's name is letters, digits, . - and _";
		if(model(name) != nil)
			return "model " + name + " is loaded already";
		spawn loader(srv, m.tag, name, hd tl tl w, loadc);
		return nil;
	"unload" =>
		if(len w != 2)
			return "usage: unload name";
		md := model(hd tl w);
		if(md == nil)
			return "no model " + hd tl w;
		for(l := sessions; l != nil; l = tl l)
			if((hd l).model == md)
				return sys->sprint("session %d uses %s", (hd l).id, md.name);
		nl: list of ref Model;
		for(ml := models; ml != nil; ml = tl ml)
			if(hd ml != md)
				nl = hd ml :: nl;
		models = lastof(nl);
		resnap();
		srv.reply(ref Rmsg.Write(m.tag, len m.data));
		return nil;
	}
	return "unknown command " + hd w + ": load, unload";
}

goodname(s: string): int
{
	if(s == nil || len s > 64 || s == "." || s == "..")
		return 0;
	for(i := 0; i < len s; i++){
		c := s[i];
		if(!(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '.' || c == '-' || c == '_'))
			return 0;
	}
	return 1;
}

loader(srv: ref Styxserver, tag: int, name, dir: string, loadc: chan of ref Loaded)
{
	(n, err) := Net.open(dir);
	loadc <-= ref Loaded(srv, tag, name, dir, n, err);
}

# every line checked before any is done; a feed restarted if what it
# is looked at with changed
sessctl(s: ref Session, data: string): string
{
	(nil, lines) := sys->tokenize(data, "\n");
	ns := ref *s;
	srcset := 0;
	for(; lines != nil; lines = tl lines){
		(nil, w) := sys->tokenize(hd lines, " \t\r");
		if(w == nil)
			continue;
		case hd w {
		"model" =>
			if(len w != 2)
				return "usage: model name";
			md := model(hd tl w);
			if(md == nil)
				return "no model " + hd tl w;
			ns.model = md;
		"thresh" or "iou" =>
			if(len w != 2)
				return "usage: " + hd w + " r (0 to 1)";
			(v, rest) := str->toreal(hd tl w, 10);
			if(rest != nil || v < 0.0 || v > 1.0)
				return hd w + ": a number from 0 to 1";
			if(hd w == "thresh")
				ns.thresh = v;
			else
				ns.iou = v;
		"classes" =>
			if(len w < 2)
				return "usage: classes name ... | classes all";
			if(len w == 2 && hd tl w == "all"){
				ns.classes = nil;
				break;
			}
			if(ns.model == nil)
				return "classes: no model to name them";
			cl: list of string;
			for(c := tl w; c != nil; c = tl c){
				if(classindex(ns.model.net, hd c) < 0)
					return "classes: " + ns.model.name + " has no class " + hd c;
				cl = hd c :: cl;
			}
			ns.classes = cl;
		"place" =>
			if(len w != 2 || hd tl w != "cpu")
				return "place: this server has only cpu";
		"src" =>
			if(len w != 2)
				return "usage: src feed | src none";
			if(hd tl w == "none")
				ns.src = nil;
			else {
				(e, nil, nil, nil) := readfmt(hd tl w + "/fmt");
				if(e != nil)
					return "src: " + e;
				ns.src = hd tl w;
			}
			srcset = 1;
		"rate" =>
			if(len w != 2)
				return "usage: rate frames-a-second (0 as fast as it can)";
			(v, rest) := str->toint(hd tl w, 10);
			if(rest != nil || v < 0 || v > 1000)
				return "rate: frames a second, 0 to 1000";
			ns.rate = v;
		* =>
			return "unknown setting " + hd w + ": model, place, thresh, iou, classes, src, rate";
		}
	}
	if(ns.classes != nil && ns.model != s.model)
		for(c := ns.classes; c != nil; c = tl c)
			if(classindex(ns.model.net, hd c) < 0)
				return "classes: " + ns.model.name + " has no class " + hd c;
	if(ns.src != nil && ns.model == nil)
		return "src: no model to look with: load one";
	if(ns.src != nil && s.state == "running")
		return "src: a picture is being looked at";
	restart := ns.src != nil && (srcset || ns.model != s.model || ns.thresh != s.thresh ||
		ns.iou != s.iou || !samelist(ns.classes, s.classes) || ns.rate != s.rate);
	*s = *ns;
	if(srcset && s.src == nil){
		stopfeed(s);
		s.state = "idle";
		s.err = nil;
	}
	if(restart){
		stopfeed(s);
		startfeed(s);
	}
	return nil;
}

samelist(a, b: list of string): int
{
	for(; a != nil && b != nil; (a, b) = (tl a, tl b))
		if(hd a != hd b)
			return 0;
	return a == nil && b == nil;
}

classindex(n: ref Net, name: string): int
{
	for(i := 0; i < len n.classes; i++)
		if(n.classes[i] == name)
			return i;
	return -1;
}

startfeed(s: ref Session)
{
	s.fgen++;
	s.ended = 0;
	# stats are of the feed now followed
	(s.nin, s.inferred, s.skipped, s.nms) = (0, 0, 0, 0);
	s.err = nil;
	s.state = "following";
	pidc := chan of int;
	spawn follower(s.id, s.fgen, s.src, s.model.net, s.thresh, s.iou, s.classes, s.rate, framec, pidc);
	s.fpid = <-pidc;
}

stopfeed(s: ref Session)
{
	s.fgen++;
	if(s.fpid >= 0){
		fd := sys->open("/prog/" + string s.fpid + "/ctl", Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "kill");
	}
	s.fpid = -1;
	s.ended = 1;
	# readers waiting on the old feed are told it ended
	for(fl := freaders; fl != nil; fl = tl fl)
		if((hd fl).sess == s.id && (hd fl).rd != nil)
			deliver(s, hd fl);
}

# a picture written: looked at in a proc of its own
look(s: ref Session, data: array of byte, resc: chan of ref Result)
{
	s.gen++;
	if(s.model == nil){
		s.state = "error";
		s.err = "no model: load one (ctl) and name it (N/ctl)";
		return;
	}
	s.state = "running";
	s.err = nil;
	s.images++;
	spawn detector(s.id, s.gen, s.model.net, data, s.thresh, s.iou, s.classes, resc);
}

records(prefix: string, n: ref Net, dets: array of ref Det, classes: list of string): (string, int)
{
	text := "";
	found := 0;
	for(i := 0; i < len dets; i++){
		d := dets[i];
		name := n.classes[d.class];
		if(classes != nil && !member(name, classes))
			continue;
		text += sys->sprint("%sclass=%s score=%.2f x0=%d y0=%d x1=%d y1=%d\n",
			prefix, name, d.score, round(d.x0), round(d.y0), round(d.x1), round(d.y1));
		found++;
	}
	return (text, found);
}

detector(id, gen: int, n: ref Net, data: array of byte, thresh, iou: real, classes: list of string, resc: chan of ref Result)
{
	t0 := sys->millisec();
	(pix, w, h, err) := visnet->readpixelsdata(data, "image");
	if(pix == nil){
		resc <-= ref Result(id, gen, nil, err, 0, 0);
		return;
	}
	dets: array of ref Det;
	(dets, err) = n.detect(pix, w, h, thresh, iou);
	if(err != nil){
		resc <-= ref Result(id, gen, nil, err, 0, 0);
		return;
	}
	(text, found) := records("", n, dets, classes);
	resc <-= ref Result(id, gen, text, nil, found, sys->millisec() - t0);
}

# a feed's fmt: (error, w, h, fps)
readfmt(f: string): (string, int, int, int)
{
	s := readfile(f);
	if(s == nil)
		return (sys->sprint("%s: %r", f), 0, 0, 0);
	(n, w) := sys->tokenize(s, " \t\n");
	if(n < 4 || hd tl tl w != "i420")
		return (f + ": not a feed's fmt (w h i420 fps)", 0, 0, 0);
	wd := int hd w;
	ht := int hd tl w;
	fps := int hd tl tl tl w;
	if(wd < 2 || ht < 2 || (wd|ht) & 1 || wd > 1<<14 || ht > 1<<14)
		return (f + ": a frame of no size, odd, or too large", 0, 0, 0);
	if(fps < 1)
		fps = 1;
	return (nil, wd, ht, fps);
}

# what a feed's status says of its frames: (has a count, frames, first, eof)
feedcount(src: string): (int, int, int, int)
{
	s := readfile(src + "/status");
	(nil, w) := sys->tokenize(s, " \t\n");
	(has, frames, first, eof) := (0, 0, 0, 0);
	for(; w != nil; w = tl w){
		(k, v) := str->splitl(hd w, "=");
		if(v == nil)
			continue;
		v = v[1:];
		case k {
		"frames" =>	(has, frames) = (1, int v);
		"first" =>	first = int v;
		"eof" =>	eof = int v;
		}
	}
	return (has, frames, first, eof);
}

# a feed, followed: each frame it is ready for looked at, the frames it
# was not ready for counted
follower(id, fgen: int, src: string, n: ref Net, thresh, iou: real, classes: list of string, rate: int,
	framec: chan of ref Frameres, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	(err, w, h, fps) := readfmt(src + "/fmt");
	if(err != nil){
		framec <-= ref Frameres(id, fgen, nil, err, 0, 0, 1);
		return;
	}
	fd := sys->open(src + "/frame", Sys->OREAD);
	if(fd == nil){
		framec <-= ref Frameres(id, fgen, nil, sys->sprint("%s/frame: %r", src), 0, 0, 1);
		return;
	}
	fs := w*h + 2*(w/2)*(h/2);
	buf := array[fs] of byte;
	(counted, frames, first, eof) := feedcount(src);
	next := 0;		# the feed's frame number to look at next
	if(counted){
		next = first;
		if(!eof)
			next = livestart(frames, first);	# live: from now on
	}
	last := 0;
	for(;;){
		if(rate > 0 && last != 0){
			wait := 1000/rate - (sys->millisec() - last);
			if(wait > 0)
				sys->sleep(wait);
		}
		last = sys->millisec();
		if(counted && eof && next >= frames){
			framec <-= ref Frameres(id, fgen, nil, nil, 0, 0, 1);
			return;
		}
		got := 0;
		expired := 0;
		off := big next * big fs;
		while(got < fs){
			k := sys->pread(fd, buf[got:], fs - got, off + big got);
			if(k < 0){
				e := sys->sprint("%r");
				if(e == "frame expired" && counted && !eof){
					expired = 1;	# fallen behind a live feed
					break;
				}
				framec <-= ref Frameres(id, fgen, nil, sys->sprint("%s/frame: %s", src, e), 0, 0, 1);
				return;
			}
			if(k == 0)
				break;
			got += k;
		}
		if(expired){
			# gone before it was read: go on from the newest
			(nil, frames, first, eof) = feedcount(src);
			next = livestart(frames, first);
			continue;
		}
		if(got < fs){
			# the feed has ended
			framec <-= ref Frameres(id, fgen, nil, nil, 0, 0, 1);
			return;
		}
		t0 := sys->millisec();
		(dets, derr) := n.detecti420(buf[0:w*h], buf[w*h:w*h + (w/2)*(h/2)], buf[w*h + (w/2)*(h/2):fs], w, h, thresh, iou);
		if(derr != nil){
			framec <-= ref Frameres(id, fgen, nil, derr, 0, 0, 1);
			return;
		}
		ms := sys->millisec() - t0;
		prefix := sys->sprint("frame=%d pts=%d ", next, int (big next * big 1000 / big fps));
		(text, nil) := records(prefix, n, dets, classes);
		if(text == nil)
			text = prefix[0:len prefix - 1] + "\n";
		skipped := 0;
		if(counted){
			(nil, frames, first, eof) = feedcount(src);
			if(!eof && frames - 1 > next + 1){
				skipped = frames - 1 - (next + 1);
				next = frames - 1;
			} else
				next++;
		} else
			next++;
		framec <-= ref Frameres(id, fgen, text, nil, ms, skipped, 0);
	}
}

# where a live reader starts: the newest frame (frames= less one) if it
# is still kept (not below first=), else the next, which a read waits for
livestart(frames, first: int): int
{
	if(frames > first)
		return frames - 1;
	return frames;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
}

# Limbo's int of a real is the nearest, already
round(v: real): int
{
	return int v;
}

# ---- the tree, from the snapshot ----

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil){
		pick n := m {
		Stat =>
			n.reply <-= dirgen(n.path);
		Walk =>
			n.reply <-= walk(n.path, n.name);
		Readdir =>
			kids := children(n.path);
			for(i := 0; kids != nil; kids = tl kids){
				if(i >= n.offset && i < n.offset + n.count)
					n.reply <-= dirgen(hd kids);
				i++;
			}
			n.reply <-= (nil, nil);
		}
	}
}

qid(t, id: int): big
{
	return big id << 8 | big t;
}

children(p: big): list of big
{
	t := int p & 16rFF;
	id := int (p >> 8);
	sn := snap;
	k: list of big;
	case t {
	Qroot =>
		for(sl := sn.sessions; sl != nil; sl = tl sl)
			k = qid(Qsess, hd sl) :: k;
		k = qid(Qctl, 0) :: qid(Qclone, 0) :: qid(Qmodels, 0) :: k;
	Qmodels =>
		for(ml := sn.models; ml != nil; ml = tl ml)
			k = qid(Qmodel, (hd ml).t0) :: k;
	Qmodel =>
		k = qid(Qminfo, id) :: qid(Qmclasses, id) :: nil;
	Qsess =>
		k = qid(Qsctl, id) :: qid(Qsimage, id) :: qid(Qsdet, id) :: qid(Qsstatus, id) ::
			qid(Qsstats, id) :: qid(Qslayer, id) :: nil;
	Qslayer =>
		k = qid(Qslayerf, id) :: nil;
	}
	return k;
}

walk(p: big, name: string): (ref Sys->Dir, string)
{
	t := int p & 16rFF;
	id := int (p >> 8);
	if(name == ".."){
		case t {
		Qmodel =>	return dirgen(qid(Qmodels, 0));
		Qslayer =>	return dirgen(qid(Qsess, id));
		* =>		return dirgen(qid(Qroot, 0));
		}
	}
	if(t != Qroot && t != Qmodels && t != Qmodel && t != Qsess && t != Qslayer)
		return (nil, Styxservers->Enotdir);
	for(k := children(p); k != nil; k = tl k){
		(d, nil) := dirgen(hd k);
		if(d != nil && d.name == name)
			return (d, nil);
	}
	return (nil, Styxservers->Enotfound);
}

dirgen(p: big): (ref Sys->Dir, string)
{
	t := int p & 16rFF;
	id := int (p >> 8);
	sn := snap;
	d := ref sys->zerodir;
	d.qid.path = p;
	d.uid = d.gid = d.muid = user;
	dir := 0;
	case t {
	Qroot =>	(d.name, dir) = (".", 1);
	Qctl =>		(d.name, d.mode) = ("ctl", 8r666);
	Qclone =>	(d.name, d.mode) = ("clone", 8r444);
	Qmodels =>	(d.name, dir) = ("models", 1);
	Qmodel or Qminfo or Qmclasses =>
		name: string;
		for(ml := sn.models; ml != nil; ml = tl ml)
			if((hd ml).t0 == id)
				name = (hd ml).t1;
		if(name == nil)
			return (nil, Styxservers->Enotfound);
		case t {
		Qmodel =>	(d.name, dir) = (name, 1);
		Qminfo =>	(d.name, d.mode) = ("info", 8r444);
		Qmclasses =>	(d.name, d.mode) = ("classes", 8r444);
		}
	* =>
		if(!memberi(id, sn.sessions))
			return (nil, Styxservers->Enotfound);
		case t {
		Qsess =>	(d.name, dir) = (string id, 1);
		Qsctl =>	(d.name, d.mode) = ("ctl", 8r666);
		Qsimage =>	(d.name, d.mode) = ("image", 8r222);
		Qsdet =>	(d.name, d.mode) = ("detections", 8r444);
		Qsstatus =>	(d.name, d.mode) = ("status", 8r444);
		Qsstats =>	(d.name, d.mode) = ("stats", 8r444);
		Qslayer =>	(d.name, dir) = ("layer", 1);
		Qslayerf =>	(d.name, d.mode) = ("vision." + string id, 8r444);
		* =>		return (nil, Styxservers->Enotfound);
		}
	}
	if(dir){
		d.qid.qtype = Sys->QTDIR;
		d.mode = Sys->DMDIR | 8r555;
	}
	return (d, nil);
}

memberi(x: int, l: list of int): int
{
	for(; l != nil; l = tl l)
		if(hd l == x)
			return 1;
	return 0;
}
