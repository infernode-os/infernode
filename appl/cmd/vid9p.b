implement Vid9p;

#
# vid9p - present decoded video frames as a 9P service at /mnt/video/<id>/.
#
# Multiplexed-video bridge (Jira INFR-266/271). Sources frames from the host
# `vdec` decode core (tools/vdec) and serves them as a synthetic filesystem:
#
#   /mnt/video/0/ctl      write "open <file|url>"
#   /mnt/video/0/fmt      read  "<w> <h> i420 <fps>"
#   /mnt/video/0/frame    read  the I420 stream: frame N is the framesize bytes
#                               at offset N*framesize (framesize = w*h*3/2).
#                               Reads past the live edge BLOCK until more frames
#                               arrive (continuous streaming); EOF only when the
#                               source ends.
#   /mnt/video/0/status   read  human-readable state
#
# A .y4m argument is read directly; anything else (a video file, or an rtsp://
# URL) is decoded by exec'ing the host vdec via the Inferno cmd device (#C),
# streaming its YUV4MPEG2 stdout (`vdec <src> --y4m - --quiet`). A background
# `reader` proc parses frames and feeds them to the serve loop over a channel,
# so a never-ending RTSP feed streams rather than buffering to EOF.
#
# Known limits (file slice / disposable Limbo shim, see docs/H264-9P-BRIDGE.md):
# the frame buffer grows unbounded for very long live streams, and a single
# logical consumer is assumed. The Rust-native server (INFR-267) addresses both.
#
# Usage (Inferno shell):
#   mount {vid9p -d /host/path/to/vdec} /mnt/video
#   echo 'open /clip.mp4' > /mnt/video/0/ctl          # or: open rtsp://host/s
#   mount {vid9p clip.y4m} /mnt/video                 # pre-decoded stream
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

Vid9p: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

Qroot, Qstream, Qctl, Qfmt, Qframe, Qstatus: con iota;

tc: chan of ref Tmsg;
srv: ref Styxserver;
stderr: ref Sys->FD;
user := "inferno";
vdecpath := "vdec";			# host path to vdec (override with -d)

# loaded video state (owned by the serve proc)
width, height, fps, framesize: int;
i420: array of byte;			# flat I420 stream, grows as frames arrive
eof: int;
pend: list of ref Tmsg.Read;		# frame reads parked at the live edge

# reader -> serve channels
metac: chan of (int, int, int);		# (w,h,fps) or (-1,-1,-1) on failure
framec: chan of array of byte;		# one I420 frame each; nil = end of stream
holdfd: ref Sys->FD;			# keeps the cmd-device control conn alive

# incremental buffered reader over the source fd
Rd: adt {
	fd: ref Sys->FD;
	buf: array of byte;
	n, pos: int;
};

badmod(path: string)
{
	sys->fprint(sys->fildes(2), "vid9p: cannot load %s: %r\n", path);
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

	i420 = array[0] of byte;
	metac = chan of (int, int, int);
	framec = chan[64] of array of byte;

	# args: [-d vdecpath] [source]
	args = tl args;
	src := "";
	while(args != nil){
		case hd args {
		"-d" =>
			args = tl args;
			if(args != nil) vdecpath = hd args;
		* =>
			src = hd args;
		}
		args = tl args;
	}
	if(src != ""){
		e := loadvideo(src);
		if(e != nil)
			sys->fprint(stderr, "vid9p: %s\n", e);
	}

	(tree, treeop) := nametree->start();
	tree.create(big Qroot,   dir(".",      Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot,   dir("0",      Sys->DMDIR|8r555, Qstream));
	tree.create(big Qstream, dir("ctl",    8r666, Qctl));
	tree.create(big Qstream, dir("fmt",    8r444, Qfmt));
	tree.create(big Qstream, dir("frame",  8r444, Qframe));
	tree.create(big Qstream, dir("status", 8r444, Qstatus));

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
		fr := <-framec =>
			if(fr == nil){
				eof = 1;
				wakepending();
			}else{
				appendframe(fr);
				wakepending();
			}
		}
	}
	tree.quit();
}

# returns 1 to stop serving
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
		Qfmt =>
			srv.reply(styxservers->readstr(tm, fmtstr()));
		Qstatus =>
			srv.reply(styxservers->readstr(tm, statusstr()));
		Qctl =>
			srv.reply(styxservers->readstr(tm, "open <file|url>\n"));
		Qframe =>
			if(int tm.offset < len i420 || eof)
				srv.reply(styxservers->readbytes(tm, i420));
			else
				pend = tm :: pend;	# park at the live edge
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, "vid9p: bad path"));
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

appendframe(fr: array of byte)
{
	nb := array[len i420 + len fr] of byte;
	nb[0:] = i420;
	nb[len i420:] = fr;
	i420 = nb;
}

# reply to any parked frame reads that the new data (or EOF) now satisfies
wakepending()
{
	np: list of ref Tmsg.Read;
	for(l := pend; l != nil; l = tl l){
		tm := hd l;
		if(int tm.offset < len i420 || eof)
			srv.reply(styxservers->readbytes(tm, i420));
		else
			np = tm :: np;
	}
	pend = np;
}

fmtstr(): string
{
	return sys->sprint("%d %d i420 %d\n", width, height, fps);
}

statusstr(): string
{
	state := "no source";
	if(eof)
		state = "ended";
	else if(width > 0)
		state = "streaming";
	return sys->sprint("%s w=%d h=%d framesize=%d bytes=%d\n",
		state, width, height, framesize, len i420);
}

doctl(s: string)
{
	(nil, toks) := sys->tokenize(s, " \t\r\n");
	if(toks != nil && hd toks == "open" && tl toks != nil){
		e := loadvideo(hd tl toks);
		if(e != nil)
			sys->fprint(stderr, "vid9p: open: %s\n", e);
	}
}

# Start streaming a source. .y4m is read directly; anything else (video file or
# rtsp:// URL) is decoded by spawning vdec. Blocks only until the header (fmt) is
# known; frames then stream in the background.
loadvideo(path: string): string
{
	fd: ref Sys->FD;
	if(hassuffix(path, ".y4m")){
		fd = sys->open(path, Sys->OREAD);
		if(fd == nil)
			return sys->sprint("open %s: %r", path);
		holdfd = nil;
	}else{
		(dfd, cfd, err) := hostspawn(vdecpath :: hostpath(path) :: "--y4m" :: "-" :: "--quiet" :: nil);
		if(err != nil)
			return sys->sprint("decode %s: %s", path, err);
		fd = dfd;
		holdfd = cfd;
	}

	i420 = array[0] of byte;
	eof = 0;
	pend = nil;
	spawn reader(fd);

	(w, h, f) := <-metac;
	if(w <= 0)
		return sys->sprint("%s: no decodable video", path);
	width = w; height = h; fps = f;
	framesize = w*h + 2*(w/2)*(h/2);
	return nil;
}

# Background: parse the YUV4MPEG2 stream and feed frames to the serve loop.
reader(fd: ref Sys->FD)
{
	r := ref Rd(fd, array[64*1024] of byte, 0, 0);
	hdr := rdline(r);
	(w, h, f) := (-1, -1, 25);
	if(hdr != nil)
		(w, h, f) = parsehdr(hdr);
	metac <-= (w, h, f);
	if(w <= 0)
		return;
	fsz := w*h + 2*(w/2)*(h/2);
	for(;;){
		line := rdline(r);
		if(line == nil)
			break;			# stream ended
		fr := rdn(r, fsz);
		if(fr == nil)
			break;			# truncated final frame
		framec <-= fr;			# backpressure when the buffer is full
	}
	framec <-= nil;				# end-of-stream sentinel
}

parsehdr(hdr: string): (int, int, int)
{
	if(len hdr < 9 || hdr[0:9] != "YUV4MPEG2")
		return (-1, -1, -1);
	w := -1; h := -1; f := 25;
	(nil, toks) := sys->tokenize(hdr, " \t");
	for(; toks != nil; toks = tl toks){
		t := hd toks;
		if(len t < 2)
			continue;
		case t[0] {
		'W' => w = int t[1:];
		'H' => h = int t[1:];
		'F' => f = int t[1:];		# "25:1" -> 25
		}
	}
	return (w, h, f);
}

fill(r: ref Rd): int
{
	m := sys->read(r.fd, r.buf, len r.buf);
	if(m <= 0)
		return 0;
	r.n = m; r.pos = 0;
	return 1;
}

rdbyte(r: ref Rd): int
{
	if(r.pos >= r.n)
		if(!fill(r))
			return -1;
	c := int r.buf[r.pos];
	r.pos++;
	return c;
}

rdline(r: ref Rd): string
{
	tmp := array[256] of byte;
	m := 0;
	for(;;){
		c := rdbyte(r);
		if(c < 0){
			if(m == 0)
				return nil;
			break;
		}
		if(c == '\n')
			break;
		if(m < len tmp){
			tmp[m] = byte c;
			m++;
		}
	}
	return string tmp[0:m];
}

rdn(r: ref Rd, k: int): array of byte
{
	out := array[k] of byte;
	got := 0;
	while(got < k){
		if(r.pos >= r.n)
			if(!fill(r))
				return nil;
		avail := r.n - r.pos;
		take := k - got;
		if(take > avail)
			take = avail;
		out[got:] = r.buf[r.pos:r.pos+take];
		r.pos += take;
		got += take;
	}
	return out;
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

# Map an Inferno absolute path to its host path under $emuroot (emu -r<dir>).
hostpath(p: string): string
{
	if(len p > 0 && p[0] == '/'){
		root := env->getenv("emuroot");
		if(root != nil && root != "/")
			return root + p;
	}
	return p;
}

hassuffix(s, suf: string): int
{
	return len s >= len suf && s[len s - len suf:] == suf;
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
