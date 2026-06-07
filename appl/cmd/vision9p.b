implement Vision9p;

#
# vision9p - present per-frame video detections as a 9P service at
# /mnt/vision/<id>/ (prototype, Jira INFR-277).
#
#   /mnt/vision/0/ctl          write "open <file|url>"
#   /mnt/vision/0/detections   read  the streaming detection log (one text
#                                    record per frame); reads past the live edge
#                                    BLOCK until more arrive; EOF when source ends
#   /mnt/vision/0/status       read  human-readable state
#
# Decode + detection run on the host: vision9p exec's the host `vdet` binary via
# the Inferno cmd device (#C) and streams its stdout (`vdet <src> --quiet`).
# vdet reuses the vdec decode core and emits greppable detection records; this
# shim just relays them as a 9P text stream. Detections flow on into the agent
# the same way other structured events do (msg9p) — see docs/ML-VISION-9P.md.
#
# This is the generic inference *service* (a sibling of vdec/vid9p); which feeds
# to watch and how detections route to CoT/markers is NERVA policy, not here.
#
# Usage (Inferno shell):
#   mount {vision9p -d /host/path/to/vdet} /mnt/vision
#   echo 'open /clip.mp4' > /mnt/vision/0/ctl        # or: open rtsp://host/s
#   tail -f /mnt/vision/0/detections
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "string.m";
	str: String;
include "env.m";
	env: Env;
include "styx.m";
	styx: Styx;
	Tmsg, Rmsg: import Styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Navigator: import styxservers;
	nametree: Nametree;
	Tree: import nametree;

Vision9p: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

Qroot, Qstream, Qctl, Qdets, Qstatus: con iota;

tc: chan of ref Tmsg;
srv: ref Styxserver;
stderr: ref Sys->FD;
user := "inferno";
vdetpath := "vdet";			# host path to vdet (override with -d)

det: array of byte;			# streaming detection log, grows
eof: int;
pend: list of ref Tmsg.Read;		# detection reads parked at the live edge

bytec: chan of array of byte;		# stdout chunks; nil = end of stream
holdfd: ref Sys->FD;			# keeps the cmd-device control conn alive

badmod(path: string)
{
	sys->fprint(sys->fildes(2), "vision9p: cannot load %s: %r\n", path);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	str = load String String->PATH;
	if(str == nil) badmod(String->PATH);
	env = load Env Env->PATH;
	if(env == nil) badmod(Env->PATH);
	styx = load Styx Styx->PATH;
	if(styx == nil) badmod(Styx->PATH);
	styxservers = load Styxservers Styxservers->PATH;
	if(styxservers == nil) badmod(Styxservers->PATH);
	nametree = load Nametree Nametree->PATH;
	if(nametree == nil) badmod(Nametree->PATH);
	styx->init();
	styxservers->init(styx);
	nametree->init();

	det = array[0] of byte;
	bytec = chan[64] of array of byte;

	args = tl args;
	src := "";
	while(args != nil){
		case hd args {
		"-d" =>
			args = tl args;
			if(args != nil) vdetpath = hd args;
		* =>
			src = hd args;
		}
		args = tl args;
	}
	if(src != ""){
		e := loadsource(src);
		if(e != nil)
			sys->fprint(stderr, "vision9p: %s\n", e);
	}

	(tree, treeop) := nametree->start();
	tree.create(big Qroot,   dir(".",          Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot,   dir("0",          Sys->DMDIR|8r555, Qstream));
	tree.create(big Qstream, dir("ctl",        8r666, Qctl));
	tree.create(big Qstream, dir("detections", 8r444, Qdets));
	tree.create(big Qstream, dir("status",     8r444, Qstatus));

	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qroot);
	serve(tree);
}

serve(tree: ref Tree)
{
	done := 0;
	while(!done){
		alt {
		tmsg := <-tc =>
			if(tmsg == nil || handlestyx(tmsg))
				done = 1;
		chunk := <-bytec =>
			if(chunk == nil){
				eof = 1;
				wakepending();
			}else{
				append(chunk);
				wakepending();
			}
		}
	}
	tree.quit();
}

handlestyx(tmsg: ref Tmsg): int
{
	pick tm := tmsg {
	Readerror =>
		return 1;
	Open =>
		srv.open(tm);
	Read =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			return 0;
		}
		case int c.path {
		Qroot or Qstream =>
			srv.read(tm);
		Qstatus =>
			srv.reply(styxservers->readstr(tm, statusstr()));
		Qctl =>
			srv.reply(styxservers->readstr(tm, "open <file|url>\n"));
		Qdets =>
			if(int tm.offset < len det || eof)
				srv.reply(styxservers->readbytes(tm, det));
			else
				pend = tm :: pend;	# park at the live edge
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, "vision9p: bad path"));
		}
	Write =>
		c := srv.getfid(tm.fid);
		if(c == nil || !c.isopen){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			return 0;
		}
		if(int c.path != Qctl){
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			return 0;
		}
		doctl(string tm.data);
		srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
	* =>
		srv.default(tmsg);
	}
	return 0;
}

append(chunk: array of byte)
{
	nb := array[len det + len chunk] of byte;
	nb[0:] = det;
	nb[len det:] = chunk;
	det = nb;
}

wakepending()
{
	np: list of ref Tmsg.Read;
	for(l := pend; l != nil; l = tl l){
		tm := hd l;
		if(int tm.offset < len det || eof)
			srv.reply(styxservers->readbytes(tm, det));
		else
			np = tm :: np;
	}
	pend = np;
}

statusstr(): string
{
	state := "no source";
	if(eof)
		state = "ended";
	else if(holdfd != nil)
		state = "detecting";
	return sys->sprint("%s bytes=%d\n", state, len det);
}

doctl(s: string)
{
	(nil, toks) := sys->tokenize(s, " \t\r\n");
	if(toks != nil && hd toks == "open" && tl toks != nil){
		e := loadsource(hd tl toks);
		if(e != nil)
			sys->fprint(stderr, "vision9p: open: %s\n", e);
	}
}

# Spawn vdet on the source and stream its detection records.
loadsource(src: string): string
{
	(dfd, cfd, err) := hostspawn(vdetpath :: hostpath(src) :: "--quiet" :: nil);
	if(err != nil)
		return sys->sprint("detect %s: %s", src, err);
	det = array[0] of byte;
	eof = 0;
	pend = nil;
	holdfd = cfd;
	spawn reader(dfd);
	return nil;
}

# Background: relay vdet stdout to the serve loop in chunks.
reader(fd: ref Sys->FD)
{
	buf := array[32*1024] of byte;
	for(;;){
		n := sys->read(fd, buf, len buf);
		if(n <= 0)
			break;
		chunk := array[n] of byte;
		chunk[0:] = buf[0:n];
		bytec <-= chunk;		# backpressure when full
	}
	bytec <-= nil;				# end-of-stream sentinel
}

# Run a host command via the cmd device (#C); return (stdout-fd, ctl-fd).
hostspawn(argv: list of string): (ref Sys->FD, ref Sys->FD, string)
{
	if(sys->stat("/cmd/clone").t0 == -1)
		if(sys->bind("#C", "/", Sys->MBEFORE) < 0)
			return (nil, nil, sys->sprint("bind #C: %r"));
	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		return (nil, nil, sys->sprint("open /cmd/clone: %r"));
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0)
		return (nil, nil, sys->sprint("read /cmd/clone: %r"));
	dir := "/cmd/" + string b[0:n];
	if(sys->fprint(cfd, "exec %s", str->quoted(argv)) < 0)
		return (nil, nil, sys->sprint("exec: %r"));
	dfd := sys->open(dir + "/data", Sys->OREAD);
	if(dfd == nil)
		return (nil, nil, sys->sprint("open %s/data: %r", dir));
	return (dfd, cfd, nil);
}

hostpath(p: string): string
{
	if(len p > 0 && p[0] == '/'){
		root := env->getenv("emuroot");
		if(root != nil && root != "/")
			return root + p;
	}
	return p;
}

dir(name: string, perm, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = user;
	d.gid = user;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	else
		d.qid.qtype = Sys->QTFILE;
	d.mode = perm;
	return d;
}
