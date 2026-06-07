implement Vid9p;

#
# vid9p - present decoded video frames as a 9P service at /mnt/video/<id>/.
#
# Phase 1 of the multiplexed-video bridge (Jira INFR-266). Reads a YUV4MPEG2
# (.y4m) stream produced by the host `vdec` decode core (tools/vdec) and serves
# its frames as a synthetic filesystem:
#
#   /mnt/video/0/ctl      write "open <file.y4m>" to (re)load a source
#   /mnt/video/0/fmt      read  "<w> <h> i420 <fps>"
#   /mnt/video/0/frame    read  the I420 stream: frame N is the framesize bytes
#                               at offset N*framesize (framesize = w*h*3/2).
#                               A player reads framesize-byte chunks in sequence.
#   /mnt/video/0/status   read  human-readable state
#
# The decode core is protocol-agnostic and lives on the host; this shim is the
# (deliberately disposable) Limbo 9P front. See docs/H264-9P-BRIDGE.md. A later
# pass swaps the y4m-file source for a live `vdec` spawn and adds a Rust-native
# 9P server (INFR-267).
#
# Usage (in the Inferno shell):
#   mount {vid9p clip.y4m} /mnt/video
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

Qroot, Qstream, Qctl, Qfmt, Qframe, Qstatus: con iota;

tc: chan of ref Tmsg;
srv: ref Styxserver;
stderr: ref Sys->FD;
user := "inferno";

# loaded video state
width, height, fps, framesize, nframes: int;
i420: array of byte;

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

	# optional source file as the sole argument
	args = tl args;
	if(args != nil){
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
	while((tmsg := <-tc) != nil){
		pick tm := tmsg {
		Readerror =>
			break;
		Open =>
			srv.open(tm);
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			case int c.path {
			Qroot or Qstream =>
				srv.read(tm);
			Qfmt =>
				srv.reply(styxservers->readstr(tm, fmtstr()));
			Qstatus =>
				srv.reply(styxservers->readstr(tm, statusstr()));
			Qctl =>
				srv.reply(styxservers->readstr(tm, "open <file.y4m>\n"));
			Qframe =>
				srv.reply(styxservers->readbytes(tm, i420));
			* =>
				srv.reply(ref Rmsg.Error(tm.tag, "vid9p: bad path"));
			}
		Write =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				continue;
			}
			if(int c.path != Qctl){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
				continue;
			}
			doctl(string tm.data);
			srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		* =>
			srv.default(tmsg);
		}
	}
	tree.quit();
}

fmtstr(): string
{
	return sys->sprint("%d %d i420 %d\n", width, height, fps);
}

statusstr(): string
{
	src := "no source";
	if(nframes > 0)
		src = "ready";
	return sys->sprint("%s w=%d h=%d framesize=%d frames=%d\n",
		src, width, height, framesize, nframes);
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

# Parse a YUV4MPEG2 file into the flat I420 frame buffer.
loadvideo(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open %s: %r", path);
	data := readall(fd);
	if(len data < 10 || string data[0:9] != "YUV4MPEG2")
		return sys->sprint("%s: not a YUV4MPEG2 stream", path);

	nl := findnl(data, 0);
	w := 0; h := 0; f := 25;
	(nil, toks) := sys->tokenize(string data[0:nl], " \t");
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
