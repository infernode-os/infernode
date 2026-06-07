implement Vid9p;

#
# vid9p - present decoded video frames as a 9P service at /mnt/video/<id>/.
#
# Phase 1 of the multiplexed-video bridge (Jira INFR-266). Sources frames from
# the host `vdec` decode core (tools/vdec) and serves them as a synthetic
# filesystem:
#
#   /mnt/video/0/ctl      write "open <file>"  (a .y4m is read directly;
#                               any other file is decoded by spawning vdec)
#   /mnt/video/0/fmt      read  "<w> <h> i420 <fps>"
#   /mnt/video/0/frame    read  the I420 stream: frame N is the framesize bytes
#                               at offset N*framesize (framesize = w*h*3/2).
#   /mnt/video/0/status   read  human-readable state
#
# Live decode runs the host vdec binary via the Inferno cmd device (#C),
# capturing its YUV4MPEG2 stdout (`vdec <file> --y4m - --quiet`). The decode
# core is protocol-agnostic and lives on the host; this shim is the
# (deliberately disposable) Limbo 9P front. See docs/H264-9P-BRIDGE.md.
#
# Usage (in the Inferno shell):
#   mount {vid9p -d /host/path/to/vdec} /mnt/video
#   echo 'open /clip.mp4' > /mnt/video/0/ctl
#   # or a pre-decoded stream:
#   mount {vid9p clip.y4m} /mnt/video
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
vdecpath := "vdec";			# host path to the vdec binary (override with -d)

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
				srv.reply(styxservers->readstr(tm, "open <file>\n"));
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

# Dispatch: .y4m is read directly; anything else is decoded by spawning vdec.
loadvideo(path: string): string
{
	if(hassuffix(path, ".y4m")){
		fd := sys->open(path, Sys->OREAD);
		if(fd == nil)
			return sys->sprint("open %s: %r", path);
		return parsey4m(path, readall(fd));
	}
	(out, err) := hostexec(vdecpath :: hostpath(path) :: "--y4m" :: "-" :: "--quiet" :: nil);
	if(err != nil)
		return sys->sprint("decode %s: %s", path, err);
	if(len out == 0)
		return sys->sprint("decode %s: vdec produced no output (is %q correct?)", path, vdecpath);
	return parsey4m(path, out);
}

# Parse a YUV4MPEG2 buffer into the flat I420 frame buffer.
parsey4m(name: string, data: array of byte): string
{
	if(len data < 10 || string data[0:9] != "YUV4MPEG2")
		return sys->sprint("%s: not a YUV4MPEG2 stream", name);

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
		return sys->sprint("%s: bad dimensions %dx%d", name, w, h);
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

# Run a host command via the cmd device (#C) and return its stdout.
hostexec(argv: list of string): (array of byte, string)
{
	if(sys->stat("/cmd/clone").t0 == -1)
		if(sys->bind("#C", "/", Sys->MBEFORE) < 0)
			return (nil, sys->sprint("bind #C: %r"));
	cfd := sys->open("/cmd/clone", Sys->ORDWR);
	if(cfd == nil)
		return (nil, sys->sprint("open /cmd/clone: %r"));
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0)
		return (nil, sys->sprint("read /cmd/clone: %r"));
	dir := "/cmd/" + string b[0:n];
	if(sys->fprint(cfd, "exec %s", str->quoted(argv)) < 0)
		return (nil, sys->sprint("exec: %r"));
	dfd := sys->open(dir + "/data", Sys->OREAD);
	if(dfd == nil)
		return (nil, sys->sprint("open %s/data: %r", dir));
	out := readall(dfd);
	# keep cfd open until the read completes, then let it close (no killonclose)
	cfd = nil;
	return (out, nil);
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
