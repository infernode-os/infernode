implement Vid9p;

#
# vid9p - present decoded video frames as a 9P service at /mnt/video/<id>/.
#
# Part of the multiplexed-video bridge (Jira INFR-266). Serves I420 frames
# produced by the host `vdec` decode core (tools/vdec) as a synthetic
# filesystem:
#
#   /mnt/video/0/ctl      write "open <file.y4m>"  load a static .y4m file
#                         write "play <cmd> [arg..]" spawn a host decoder
#                               (via os) and stream its y4m stdout live
#   /mnt/video/0/fmt      read  "<w> <h> i420 <fps>"
#   /mnt/video/0/frame    read  the I420 stream: frame N is the framesize
#                               bytes at offset N*framesize (framesize =
#                               w*h*3/2). A player reads framesize-byte
#                               chunks in sequence. For a LIVE stream a read
#                               past the last decoded frame BLOCKS until the
#                               next frame arrives (or the stream ends).
#   /mnt/video/0/status   read  human-readable state
#
# Two source modes share one server:
#   - static  (`open`): the whole .y4m is read into the frame buffer and
#     served with random access; reads never block (this is the original,
#     canned path).
#   - live    (`play`): a host decoder is spawned through the `os` command
#     and its y4m stdout is parsed incrementally; frames are appended as
#     they decode and blocked readers are woken. This is the INFR-266
#     "swap the y4m-file source for a live vdec spawn" step; the decode core
#     stays protocol-agnostic (see docs/H264-9P-BRIDGE.md).
#
# Usage (in the Inferno shell):
#   mount {vid9p clip.y4m}                    /mnt/video   # static
#   mount {vid9p -c vdec cam.mp4 --y4m /fd/1} /mnt/video   # live
#

include "sys.m";
	sys: Sys;
include "draw.m";
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

Command: module {
	init: fn(ctxt: ref Draw->Context, argv: list of string);
};

Qroot, Qstream, Qctl, Qfmt, Qframe, Qstatus: con iota;

tc: chan of ref Tmsg;
srv: ref Styxserver;
stderr: ref Sys->FD;
user := "inferno";

# loaded video state
width, height, fps, framesize, nframes: int;
i420: array of byte;
eof := 1;			# static sources are complete from the start
streaming := 0;

# live-stream plumbing (nil for a static source)
framec: chan of array of byte;	# feeder -> serve loop: one decoded frame
eofc: chan of int;		# feeder -> serve loop: stream ended
geoc: chan of (int, int, int);	# feeder -> startstream: first-header geometry
parked: list of ref Tmsg.Read;	# frame reads waiting for more data

badmod(path: string)
{
	sys->fprint(sys->fildes(2), "vid9p: cannot load %s: %r\n", path);
	raise "fail:load";
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
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
	# Allocated up front so the serve loop's alt never selects on a nil
	# channel (a nil channel in alt faults). In static mode nothing is
	# ever sent on them.
	framec = chan of array of byte;
	eofc = chan of int;
	geoc = chan of (int, int, int);

	# args: "-c <cmd> [arg...]" for a live decoder, else an optional
	# static .y4m file.
	args = tl args;
	if(args != nil && hd args == "-c") {
		cmd := tl args;
		if(cmd == nil)
			sys->fprint(stderr, "vid9p: -c needs a command\n");
		else
			startstream(cmd);
	} else if(args != nil) {
		e := loadvideo(hd args);
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
	for(;;) alt {
	tmsg := <-tc =>
		if(tmsg == nil)
			break;
		pick tm := tmsg {
		Readerror =>
			break;
		Open =>
			srv.open(tm);
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			} else {
				case int c.path {
				Qroot or Qstream =>
					srv.read(tm);
				Qfmt =>
					srv.reply(styxservers->readstr(tm, fmtstr()));
				Qstatus =>
					srv.reply(styxservers->readstr(tm, statusstr()));
				Qctl =>
					srv.reply(styxservers->readstr(tm, ctlhelp()));
				Qframe =>
					serviceframe(tm);
				* =>
					srv.reply(ref Rmsg.Error(tm.tag, "vid9p: bad path"));
				}
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			} else if(int c.path != Qctl){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			} else {
				doctl(string tm.data);
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			}
		* =>
			srv.default(tmsg);
		}

	fr := <-framec =>
		# A newly decoded frame: first frame fixes geometry.
		if(nframes == 0 && width <= 0)
			; # geometry already set by startstream via geoc
		grow(fr);
		wakeparked();

	<-eofc =>
		eof = 1;
		streaming = 0;
		wakeparked();
	}
	tree.quit();
}

# Append one frame's I420 payload to the served buffer.
grow(fr: array of byte)
{
	nb := array[len i420 + len fr] of byte;
	nb[0:] = i420;
	nb[len i420:] = fr;
	i420 = nb;
	if(framesize > 0)
		nframes = len i420 / framesize;
}

# Reply to a frame read now if data (or EOF) allows, else park it until the
# next frame arrives. This unifies both source modes: a static source has
# eof=1 so reads are always answered immediately (past-end -> 0 bytes = EOF);
# a live source parks reads that run ahead of the decoder.
serviceframe(tm: ref Tmsg.Read)
{
	if(int tm.offset < len i420 || eof)
		srv.reply(styxservers->readbytes(tm, i420));
	else
		parked = tm :: parked;
}

wakeparked()
{
	still: list of ref Tmsg.Read;
	for(p := parked; p != nil; p = tl p){
		tm := hd p;
		if(int tm.offset < len i420 || eof)
			srv.reply(styxservers->readbytes(tm, i420));
		else
			still = tm :: still;
	}
	parked = still;
}

fmtstr(): string
{
	return sys->sprint("%d %d i420 %d\n", width, height, fps);
}

statusstr(): string
{
	src := "no source";
	if(streaming)
		src = "streaming";
	else if(nframes > 0)
		src = "ready";
	return sys->sprint("%s w=%d h=%d framesize=%d frames=%d eof=%d\n",
		src, width, height, framesize, nframes, eof);
}

ctlhelp(): string
{
	return "open <file.y4m>\nplay <cmd> [arg...]\n";
}

doctl(s: string)
{
	(nil, toks) := sys->tokenize(s, " \t\r\n");
	if(toks == nil)
		return;
	case hd toks {
	"open" =>
		if(tl toks != nil){
			e := loadvideo(hd tl toks);
			if(e != nil)
				sys->fprint(stderr, "vid9p: open: %s\n", e);
			else
				wakeparked();	# static reload satisfies waiters
		}
	"play" =>
		if(tl toks != nil)
			startstream(tl toks);
	}
}

# ── live stream ─────────────────────────────────────────────

# Spawn a host decoder through `os` and stream its y4m stdout. Blocks until
# the stream's header geometry is known (or the source ends first) so that
# fmt is valid as soon as the mount completes.
startstream(cmd: list of string)
{
	fd := starthost(cmd);
	if(fd == nil){
		sys->fprint(stderr, "vid9p: cannot start decoder\n");
		return;
	}
	# reset served state for the new source
	i420 = array[0] of byte;
	width = height = fps = framesize = nframes = 0;
	eof = 0;
	streaming = 1;
	spawn feeder(fd);
	(w, h, f) := <-geoc;
	if(w <= 0 || h <= 0){
		# stream ended before a usable header
		eof = 1;
		streaming = 0;
		return;
	}
	width = w; height = h; fps = f;
	framesize = w*h + 2*(w/2)*(h/2);
}

# Run "os <cmd...>" with its stdout on a pipe; return the read end.
starthost(cmd: list of string): ref Sys->FD
{
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0){
		sys->fprint(stderr, "vid9p: pipe: %r\n");
		return nil;
	}
	spawn hostrun(fds[1], cmd);
	fds[1] = nil;		# parent keeps only the read end
	return fds[0];
}

hostrun(wfd: ref Sys->FD, cmd: list of string)
{
	# Private fd table so redirecting stdout does not disturb the server.
	sys->pctl(Sys->FORKFD, nil);
	# Detach the child's stdin from the server's fd 0 — when vid9p is a
	# mounted server, fd 0 IS the 9P channel, and letting the host process
	# read it would steal bytes from the mount protocol and wedge it.
	nullfd := sys->open("/dev/null", Sys->OREAD);
	if(nullfd != nil)
		sys->dup(nullfd.fd, 0);
	sys->dup(wfd.fd, 1);
	wfd = nil;
	os := load Command "/dis/os.dis";
	if(os == nil){
		sys->fprint(stderr, "vid9p: load os: %r\n");
		return;
	}
	os->init(nil, "os" :: cmd);
}

# Parse a YUV4MPEG2 stream from fd incrementally: header once (emit geometry
# on geoc), then one FRAME payload at a time onto framec; eofc at end.
feeder(fd: ref Sys->FD)
{
	buf := array[0] of byte;
	# read the header line
	(hdr, rest) := readline(fd, buf);
	if(hdr == nil){
		geoc <-= (0, 0, 0);
		eofc <-= 1;
		return;
	}
	(w, h, f) := parsehdr(hdr);
	if(w <= 0 || h <= 0){
		geoc <-= (0, 0, 0);
		eofc <-= 1;
		return;
	}
	geoc <-= (w, h, f);
	fsz := w*h + 2*(w/2)*(h/2);
	buf = rest;
	for(;;){
		# each frame is "FRAME[ params]\n" then fsz payload bytes
		(line, r1) := readline(fd, buf);
		if(line == nil)
			break;
		buf = r1;
		(payload, r2) := readn(fd, buf, fsz);
		if(payload == nil)
			break;
		buf = r2;
		framec <-= payload;
	}
	eofc <-= 1;
}

# Read up to and including the next '\n' from buf+fd; return (line-without-nl,
# leftover-after-nl). Returns (nil, ...) at EOF with no data.
readline(fd: ref Sys->FD, buf: array of byte): (array of byte, array of byte)
{
	for(;;){
		nl := findnl(buf, 0);
		if(nl < len buf)
			return (buf[0:nl], buf[nl+1:]);
		more := readmore(fd);
		if(more == nil){
			if(len buf > 0)
				return (buf, array[0] of byte);
			return (nil, nil);
		}
		buf = cat(buf, more);
	}
}

# Ensure n bytes are available; return (n-byte array, leftover). (nil,...) if
# the stream ends first.
readn(fd: ref Sys->FD, buf: array of byte, n: int): (array of byte, array of byte)
{
	while(len buf < n){
		more := readmore(fd);
		if(more == nil)
			return (nil, nil);
		buf = cat(buf, more);
	}
	return (buf[0:n], buf[n:]);
}

readmore(fd: ref Sys->FD): array of byte
{
	tmp := array[32*1024] of byte;
	n := sys->read(fd, tmp, len tmp);
	if(n <= 0)
		return nil;
	return tmp[0:n];
}

cat(a, b: array of byte): array of byte
{
	c := array[len a + len b] of byte;
	c[0:] = a;
	c[len a:] = b;
	return c;
}

parsehdr(hdr: array of byte): (int, int, int)
{
	if(len hdr < 9 || string hdr[0:9] != "YUV4MPEG2")
		return (0, 0, 0);
	w := 0; h := 0; f := 25;
	(nil, toks) := sys->tokenize(string hdr, " \t");
	for(; toks != nil; toks = tl toks){
		t := hd toks;
		if(len t < 2)
			continue;
		case t[0] {
		'W' => w = int t[1:];
		'H' => h = int t[1:];
		'F' => f = int t[1:];	# "25:1" -> 25
		}
	}
	return (w, h, f);
}

# ── static source ───────────────────────────────────────────

# Parse a whole YUV4MPEG2 file into the flat I420 frame buffer.
loadvideo(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open %s: %r", path);
	data := readall(fd);
	if(len data < 10 || string data[0:9] != "YUV4MPEG2")
		return sys->sprint("%s: not a YUV4MPEG2 stream", path);

	nl := findnl(data, 0);
	(w, h, f) := parsehdr(data[0:nl]);
	if(w <= 0 || h <= 0)
		return sys->sprint("%s: bad dimensions %dx%d", path, w, h);
	fsz := w*h + 2*(w/2)*(h/2);

	# pass 1: count whole frames present
	p := nl+1; n := 0;
	while(p < len data){
		fl := findnl(data, p);
		if(fl >= len data)
			break;
		ps := fl+1;
		if(ps+fsz > len data)
			break;
		p = ps+fsz; n++;
	}

	# pass 2: copy the I420 payloads contiguously
	nb := array[n*fsz] of byte;
	p = nl+1;
	for(k := 0; k < n; k++){
		fl := findnl(data, p);
		ps := fl+1;
		nb[k*fsz:] = data[ps:ps+fsz];
		p = ps+fsz;
	}

	streaming = 0;
	eof = 1;
	width = w; height = h; fps = f; framesize = fsz; nframes = n; i420 = nb;
	return nil;
}

readall(fd: ref Sys->FD): array of byte
{
	buf := array[0] of byte;
	tmp := array[32*1024] of byte;
	for(;;){
		n := sys->read(fd, tmp, len tmp);
		if(n <= 0)
			break;
		nbuf := array[len buf + n] of byte;
		nbuf[0:] = buf;
		nbuf[len buf:] = tmp[0:n];
		buf = nbuf;
	}
	return buf;
}

findnl(d: array of byte, p: int): int
{
	while(p < len d && d[p] != byte '\n')
		p++;
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
