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
#		N/image		w  one picture (JPEG, PNG, ..., a P6 PPM), in as many
#				   writes as it takes; it is looked at when the file is closed
#		N/detections	r  what was found, one record a line, best first:
#				   class=dog score=0.86 x0=133 y0=207 x1=326 y1=543
#				   a read waits while the picture is looked at
#		N/layer/vision.N	the same, as a layer (#1095)
#		N/status	state=idle|running|ready|error model=NAME [reason=...]
#		N/stats		images= ms= found=
#
# The models are vision(4) model directories (tools/vision/onnx2vis.py),
# run by appl/lib/visnet.b on $Tensor. A session lasts while any of its
# files is open. Each picture is looked at in a proc of its own, so one
# session's picture never holds up another's, nor the server.
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
	text:	string;			# the records
	gen:	int;			# which picture's answer is wanted
	reads:	list of (ref Styxserver, ref Tmsg.Read);
	images:	int;
	found:	int;
	ms:	int;
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

	if(sys->stat(mnt + "/clone").t0 >= 0)
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
	b := array[256] of byte;
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
nextmodel := 1;
nextsess := 1;

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
				s := ref Session(nextsess++, 0, nil, 0.3, 0.45, nil, "idle", nil, nil, 0, nil, 0, 0, 0);
				if(models != nil)
					s.model = hd lastof(models);
				sessions = s :: sessions;
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
			Qsctl =>
				s := session(id);
				if(s == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, settings(s)));
			Qsstatus =>
				s := session(id);
				if(s == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, status(s)));
			Qsstats =>
				s := session(id);
				if(s == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				srv.reply(styxservers->readstr(m, sys->sprint("images=%d found=%d ms=%d\n", s.images, s.found, s.ms)));
			Qsdet or Qslayerf =>
				s := session(id);
				if(s == nil){
					srv.reply(ref Rmsg.Error(m.tag, Styxservers->Enotfound));
					break;
				}
				if(s.state == "running")
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
			srv.default(r.m);
		Clunk =>
			f := srv.getfid(m.fid);
			if(f != nil && f.isopen && (int f.path & 16rFF) == Qsimage && len f.data > 0){
				s := session(int (f.path >> 8));
				if(s != nil)
					look(s, f.data, resc);
			}
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
	return sys->sprint("model %s\nplace cpu\nthresh %.2f\niou %.2f\nclasses %s\n", m, s.thresh, s.iou, c);
}

status(s: ref Session): string
{
	m := "none";
	if(s.model != nil)
		m = s.model.name;
	st := "state=" + s.state + " model=" + m;
	if(s.err != nil)
		st += " reason=" + quote(s.err);
	return st + "\n";
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

# every line checked before any is done
sessctl(s: ref Session, data: string): string
{
	(nil, lines) := sys->tokenize(data, "\n");
	ns := ref *s;
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
		"src" or "rate" =>
			return hd w + ": following a feed is not served yet (#1086 step 3)";
		* =>
			return "unknown setting " + hd w + ": model, place, thresh, iou, classes";
		}
	}
	if(ns.classes != nil && ns.model != s.model)
		for(c := ns.classes; c != nil; c = tl c)
			if(classindex(ns.model.net, hd c) < 0)
				return "classes: " + ns.model.name + " has no class " + hd c;
	*s = *ns;
	return nil;
}

classindex(n: ref Net, name: string): int
{
	for(i := 0; i < len n.classes; i++)
		if(n.classes[i] == name)
			return i;
	return -1;
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
	text := "";
	found := 0;
	for(i := 0; i < len dets; i++){
		d := dets[i];
		name := n.classes[d.class];
		if(classes != nil && !member(name, classes))
			continue;
		text += sys->sprint("class=%s score=%.2f x0=%d y0=%d x1=%d y1=%d\n",
			name, d.score, round(d.x0), round(d.y0), round(d.x1), round(d.y1));
		found++;
	}
	resc <-= ref Result(id, gen, text, nil, found, sys->millisec() - t0);
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
