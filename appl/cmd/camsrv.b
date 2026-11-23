implement Camsrv;

#
# camsrv - a camera, as a live video feed.
#
#   /mnt/video/0/fmt      read  "<w> <h> i420 <fps>"
#   /mnt/video/0/frame    read  I420, numbered as vid9p's are (#1095): frame N
#                               is the framesize bytes at offset N*framesize,
#                               the same for every reader. The last Ring
#                               frames are kept; a read below them errors
#                               "frame expired", one past the newest waits
#                               for it (one further past than the ring is
#                               long is refused too). A live reader starts at the newest
#                               (status frames= less one) and skips ahead
#                               when it falls behind. Numbers run on across
#                               the sensor going off and on. A frame of
#                               another width and height than the reader's
#                               last (rotate, while it reads) is refused
#                               once, "format changed: <w> <h> i420 <fps>",
#                               the format it has: the reader takes it and
#                               reads the frame again. A quarter turn keeps
#                               framesize, so frame N stays where it was.
#   /mnt/video/0/raw      read  one frame as the sensor gave it, 16 bits a
#                               sample little-endian, w*2 by h*2 pixels
#                               scaled; its format is in status
#   /mnt/video/0/status   read  one line of key=value: frames= (one past
#                               the newest frame) and first= (the oldest
#                               kept), and no pos=: a live feed
#   /mnt/video/0/ctl      write mode W H | fps N | exposure LINES (0 = auto)
#                               gain CODE | focus N | focus auto | flip N
#                               rotate 0|90|180|270; all but mode and fps
#                               while it streams
#   /mnt/video/0/layer/   empty as served: what is drawn over the frames is
#                               bound here, a file a layer (#1095, layers(2))
#
# The schema is vid9p's, so everything that shows a vid9p feed shows this.
# The sensor is on only while something has frame or raw open: the last
# close powers it down, which is also what a camera nobody is watching
# should do.
#
# usage: mount {camsrv} /mnt/video
#        mount {camsrv -t} /mnt/video     a simulated sensor, for tests
#        post cam /mnt/video             then from any VM (post(1), vm(1)):
#        mount -A '#scam/fs' /mnt/video
#        mount {camsrv -l file} ...       append the status line to file
#                                         once a minute, for a soak
#        mount {camsrv -r 90} ...         a camera mounted a quarter turn
#                                         anticlockwise: the picture is
#                                         turned clockwise to stand up
#
# How the camera is mounted is the installation's to say, not this
# server's: whoever starts it gives -r, and every reader of the feed
# then gets the picture the right way up, sized as turned (fmt says).
# flip is the sensor's own mirror register, as the module reads out;
# rotate turns what that gives, as it is merged.
#
# The kernel gives raw frames (#V) and an I2C bus (#J); all that is known
# about the cameras is here. Two are known, told apart by which answers
# on the bus when camsrv starts: the Camera Module 3 (Sony IMX708, at
# 0x1A, with a focus lens at 0x0C) and the Camera Module 2 (IMX219, at
# 0x10, fixed focus: focus is refused). Each is read out 2x2 binned,
# RAW10 on two lanes; smaller frames are merged from that. The bus is shared with the firmware,
# which polls a DSI panel's touch controller on it with no way to take
# turns: a transfer can fail and a read or a write can be silently wrong.
# So every write is read back, and the chip's id is asked until it is right.
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
include "bayer.m";
	bayer: Bayer;

Camsrv: module {
	init: fn(ctxt: ref Draw->Context, args: list of string);
};

Qroot, Qstream, Qctl, Qfmt, Qframe, Qraw, Qstatus, Qlayer: con iota;

# the sensor's one mode; smaller frames are merged from it. The IMX708's
# until a probe finds otherwise (sensorprobe), and always for -t.
Imx708, Imx219: con iota;
sensor := Imx708;
Sw := 2304;
Sh := 1296;
Black: con 64;
Clip: con 1000;		# a sample this high is taken to have clipped: left out of white balance
Maxsample: con 1023;
Maxexposure: con 65535;	# lines: the register's sixteen bits
Aetarget: con 180;	# above black, of 959: near a grey card's 18%
Aeevery: con 4;		# frames: what is written shows two later

Chip: con 16r0708;
Sensor: con 16r1A;
Lens: con 16r0C;
Chip219: con 16r0219;
Sensor219: con 16r10;

Sim: con 2;		# the simulated sensor's raw is this much smaller

srv: ref Styxserver;		# the connection of the message being served
user := "camsrv";
reqc: chan of (ref Styxserver, ref Tmsg);
sim := 0;

width := 576;
height := 324;
fps := 30;
exposure := 0;		# lines; 0 is automatic
gain := 512;
flip := 3;		# as the module sits in its usual mount: right way up
rotate := 0;		# degrees clockwise, applied after the sensor
focus := -1;
afrun := 0;

fsize := 0;
seq := 0;		# frames made since camsrv started: the next frame's number
base := 0;		# the first frame since the sensor last came on
Ring: con 8;		# the frames kept, at 30 fps a quarter second
ring := array[Ring] of (int, array of byte);
ringdim := array[Ring] of (int, int);	# each kept frame's width and height, as served
latest: array of byte;
lastraw: array of byte;
err := "";

Fsess: adt {
	srv:	ref Styxserver;	# the connection it is on
	fid:	int;
	path:	int;
	seq:	int;		# the last frame this fid took
	fr:	array of byte;	# the frame it is in
	w, h:	int;		# the format its reader has: fmt's when it opened, or the last "format changed"
};
sess: list of ref Fsess;
parked: list of (ref Tmsg.Read, ref Fsess);
users := 0;
capstop: chan of int;
# A capture's end, with what ended it ("" for a stop).  The error went on
# a channel of its own, buffered, and the end on this: the loop could
# take the end first, find no error yet, and start another capture beside
# the first one's report of why it could not run.
capdone: chan of (int, string);
cappidc: chan of (int, int);	# a capture's generation and pid, as it starts
stuckc: chan of int;		# a generation told to stop Stopwait ago
framec: chan of (array of byte, int, int);
rawc: chan of array of byte;
ctlc: chan of string;
capgen := 0;		# the capture now running, or the last
cappid := -1;
simstall := 0;		# -t: the next frame never comes (ctl stall)

# How long a capture told to stop is waited for.  It looks at its stop
# between frames, and a frame is a read of the receiver: with the link
# dead that read does not return, the capture never went, and nothing
# after it started (nor did the mount's end finish).  Past this it is
# killed and the sensor put off for it.
Stopwait: con 3000;

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	styx = load Styx Styx->PATH;
	styxservers = load Styxservers Styxservers->PATH;
	nametree = load Nametree Nametree->PATH;
	bayer = load Bayer Bayer->PATH;
	if(styx == nil || styxservers == nil || nametree == nil || bayer == nil){
		sys->fprint(sys->fildes(2), "camsrv: cannot load modules: %r\n");
		raise "fail:load";
	}
	styx->init();
	styxservers->init(styx);
	nametree->init();
	# a group of its own, so that one killgrp stops the server and its
	# helpers together: killing the first alone leaves the mount wedged
	sys->pctl(Sys->NEWPGRP, nil);
	logfile := "";
	for(args = tl args; args != nil; args = tl args)
		if(hd args == "-l" && tl args != nil){
			args = tl args;
			logfile = hd args;
		}else if(hd args == "-r" && tl args != nil){
			args = tl args;
			if(!rotation(hd args)){
				sys->fprint(sys->fildes(2), "camsrv: -r 0|90|180|270\n");
				raise "fail:usage";
			}
		}else if(hd args == "-t"){
			sim = 1;
			width = 288;
			height = 162;
		}
	if(!sim)
		sensorprobe();
	fsize = framesize();
	framec = chan of (array of byte, int, int);
	rawc = chan of array of byte;
	capdone = chan of (int, string);
	cappidc = chan of (int, int);
	stuckc = chan[4] of int;
	ctlc = chan[8] of string;

	(tree, treeop) := nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot, dir("0", Sys->DMDIR|8r555, Qstream));
	# ctl is the server's user's to write (the files were "camsrv"'s
	# whoever ran it, and ctl 666 to make up for it)
	if((u := readuser()) != nil)
		user = u;
	tree.create(big Qstream, dir("ctl", 8r664, Qctl));
	tree.create(big Qstream, dir("fmt", 8r444, Qfmt));
	tree.create(big Qstream, dir("frame", 8r444, Qframe));
	tree.create(big Qstream, dir("raw", 8r444, Qraw));
	tree.create(big Qstream, dir("status", 8r444, Qstatus));
	# empty as served: where the feed's layers are bound (#1095)
	tree.create(big Qstream, dir("layer", Sys->DMDIR|8r555, Qlayer));
	reqc = chan of (ref Styxserver, ref Tmsg);
	(tc, s) := Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qroot);
	spawn forward(s, tc);
	if(logfile != nil)
		spawn statuslog(logfile);
	serve(tree);
}

# each connection's messages into the one serve loop, with its server
forward(s: ref Styxserver, tc: chan of ref Tmsg)
{
	for(;;){
		m := <-tc;
		reqc <-= (s, m);
		if(m == nil)
			return;
		pick r := m {
		Readerror =>
			return;
		}
	}
}


# the mount gone: everything with it
connend(tree: ref Tree): int
{
	shutdown(tree);
	return 1;
}

dir(name: string, perm, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = user;
	d.mode = perm;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	return d;
}

# a frame merged at rotation rot, as served
turnedw(rot: int): int
{
	if(rot%180)
		return height;
	return width;
}

turnedh(rot: int): int
{
	if(rot%180)
		return width;
	return height;
}

# the picture as served: turned a quarter, its sides swap
fw(): int
{
	if(rotate%180)
		return height;
	return width;
}

fh(): int
{
	if(rotate%180)
		return width;
	return height;
}

rotation(a: string): int
{
	case a {
	"0" or "90" or "180" or "270" =>
		rotate = int a;
		return 1;
	}
	return 0;
}

framesize(): int
{
	return width*height + 2*(width/2)*(height/2);
}

serve(tree: ref Tree)
{
	for(;;) alt {
	(csrv, tmsg) := <-reqc =>
		# A request that raises costs itself, not the camera.  The loop
		# had no handler: one ctl write or one read (below) broke it,
		# every reader then waited for ever, and the capture went on
		# with the sensor powered and nobody to stop it.
		done := 0;
		{
			done = request(tree, csrv, tmsg);
		} exception e {
		"*" =>
			sys->fprint(sys->fildes(2), "camsrv: a request raised: %s\n", e);
			if(tmsg != nil)
				csrv.reply(ref Rmsg.Error(tmsg.tag, "camsrv: " + e));
		}
		if(done)
			return;
	(fr, fwid, fht) := <-framec =>
		latest = fr;
		ring[seq % Ring] = (seq, fr);
		ringdim[seq % Ring] = (fwid, fht);
		seq++;
		wake();
	r := <-rawc =>
		lastraw = r;
		wake();
	(g, pid) := <-cappidc =>
		if(g == capgen)
			cappid = pid;
	(g, e) := <-capdone =>
		ended(g, e);
	g := <-stuckc =>
		if(running && g == capgen)
			reap();
	}
}

# a capture has gone: generation g, saying e
ended(g: int, e: string)
{
	if(g != capgen)
		return;		# one reaped already
	running = 0;
	capstop = nil;
	cappid = -1;
	if(e != nil){
		err = e;
		wake();
	}
	if(wanted && err == "")
		launch();
}

# The capture told to stop has not gone: it is in a frame that does not
# come.  Kill it and put the sensor off for it; its readers are told.
reap()
{
	if(cappid >= 0){
		fd := sys->open("/prog/" + string cappid + "/ctl", Sys->OWRITE);
		if(fd != nil)
			sys->fprint(fd, "kill");
	}
	if(!sim)
		sensoroff();
	capgen++;	# whatever it still sends is not this capture's
	ended(capgen, "camsrv: the sensor stopped answering");
}

# Wait for a capture on its way out to have gone, the loop's other
# channels served meanwhile; an error if it is still there at the end.
settle(): string
{
	if(!running)
		return nil;
	tc := chan[1] of int;
	spawn timer(tc, Stopwait + 500);
	while(running) alt {
	<-framec =>
		;
	<-rawc =>
		;
	(g, pid) := <-cappidc =>
		if(g == capgen)
			cappid = pid;
	(g, e) := <-capdone =>
		ended(g, e);
	g := <-stuckc =>
		if(g == capgen)
			reap();
	<-tc =>
		return "camsrv: in use";
	}
	return nil;
}

timer(c: chan of int, ms: int)
{
	sys->sleep(ms);
	c <-= 1;
}

# one request; 1 when the mount has gone and the server with it
request(tree: ref Tree, csrv: ref Styxserver, tmsg: ref Tmsg): int
{
	srv = csrv;
	if(tmsg == nil)
		return connend(tree);
	pick tm := tmsg {
	Readerror =>
		return connend(tree);
	Open =>
		c := srv.getfid(tm.fid);
		path := -1;
		if(c != nil)
			path = int c.path;
		if((path == Qframe || path == Qraw) && err != "" && users == 0)
			err = "";
		if(srv.open(tm) != nil && (path == Qframe || path == Qraw)){
			sess = ref Fsess(srv, tm.fid, path, seq, nil, fw(), fh()) :: sess;
			if(users++ == 0)
				startcapture();
		}
	Flush =>
		# The read flushed is forgotten, parked or not: left parked,
		# the next frame answered a tag its client had given up.
		unpark(tm.oldtag);
		srv.default(tmsg);
	Clunk =>
		drop(tm.fid);
		srv.default(tmsg);
	Remove =>
		drop(tm.fid);
		srv.default(tmsg);
	Read =>
		(c, cerr) := srv.canread(tm);
		if(c == nil){
			srv.reply(ref Rmsg.Error(tm.tag, cerr));
			break;
		}
		case int c.path {
		Qroot or Qstream or Qlayer =>
			srv.read(tm);
		Qfmt or Qstatus or Qctl =>
			# One open reads one text, as vid9p's: made at a read at
			# offset 0 and kept with the fid (made at every read and
			# cut at its offset, a status that moved between two
			# reads gave the second the newer one's tail).
			if(tm.offset == big 0 || c.data == nil){
				case int c.path {
				Qfmt =>	c.data = array of byte sys->sprint("%d %d i420 %d\n", fw(), fh(), fps);
				Qstatus =>	c.data = array of byte status();
				Qctl =>	c.data = array of byte settings();
				}
			}
			srv.reply(styxservers->readbytes(tm, c.data));
		Qframe or Qraw =>
			s := find(tm.fid);
			if(s == nil)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
			else if(!reply(tm, s))
				parked = (tm, s) :: parked;
		* =>
			srv.reply(ref Rmsg.Error(tm.tag, "camsrv: bad path"));
		}
	Write =>
		(c, cerr) := srv.canwrite(tm);
		if(c == nil)
			srv.reply(ref Rmsg.Error(tm.tag, cerr));
		else if(int c.path != Qctl)
			srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
		else{
			e := doctl(string tm.data);
			if(e != nil)
				srv.reply(ref Rmsg.Error(tm.tag, e));
			else
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
		}
	* =>
		srv.default(tmsg);
	}
	return 0;
}

# The mount has gone. The capture process may be in the middle of a frame,
# blocked handing it over: take what it sends until it has gone, or it
# waits for ever, with the sensor on and the name tree held.
shutdown(tree: ref Tree)
{
	users = 0;
	stopcapture();
	if(settle() != nil)
		reap();
	tree.quit();
	# the status log (-l) and anything else of the server's group go
	# with it: the log wrote its line a minute for ever
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

# a soak's record: the status line, time first, once a minute, until the
# server goes (the log process is in its group, so killgrp ends it too)
statuslog(file: string)
{
	fd := sys->open(file, Sys->OWRITE);
	if(fd == nil)
		fd = sys->create(file, Sys->OWRITE, 8r666);
	if(fd == nil)
		return;
	sys->seek(fd, big 0, Sys->SEEKEND);
	for(;;){
		sys->fprint(fd, "%d %s", sys->millisec()/1000, status());
		sys->sleep(60*1000);
	}
}

find(fid: int): ref Fsess
{
	for(l := sess; l != nil; l = tl l)
		if((hd l).fid == fid && (hd l).srv == srv)
			return hd l;
	return nil;
}

drop(fid: int)
{
	s := find(fid);
	if(s == nil)
		return;
	n: list of ref Fsess;
	for(l := sess; l != nil; l = tl l)
		if(hd l != s)
			n = hd l :: n;
	sess = n;
	# a read parked on the fid is answered: dropped unanswered, its tag
	# waited for ever
	p: list of (ref Tmsg.Read, ref Fsess);
	for(q := parked; q != nil; q = tl q){
		(tm, ps) := hd q;
		if(ps != s)
			p = (tm, ps) :: p;
		else
			s.srv.reply(ref Rmsg.Error(tm.tag, "camsrv: fid clunked"));
	}
	parked = p;
	if(--users == 0)
		stopcapture();
}

# forget the parked read of a tag on this connection
unpark(tag: int)
{
	p: list of (ref Tmsg.Read, ref Fsess);
	for(q := parked; q != nil; q = tl q){
		(tm, ps) := hd q;
		if(tm.tag != tag || ps.srv != srv)
			p = (tm, ps) :: p;
	}
	parked = p;
}

# 1 if a reply went
reply(tm: ref Tmsg.Read, s: ref Fsess): int
{
	if(err != ""){
		s.srv.reply(ref Rmsg.Error(tm.tag, err));
		return 1;
	}
	fs := fsize;
	if(s.path == Qraw)
		fs = Sw*Sh*2/simdiv();
	if(fs <= 0)
		return 0;
	foff := int (tm.offset % big fs);
	if(s.path == Qraw && tm.offset >= big fs){
		s.srv.reply(ref Rmsg.Read(tm.tag, array[0] of byte));
		return 1;
	}
	if(s.path == Qframe){
		# Frame n, as every reader numbers it; the offset is the
		# reader's, any 63 bits, so n is found in 64.  It was cut to
		# an int: an offset near the frame size times 2^32 gave a
		# negative n, which indexed the ring before its start, and the
		# exception ended the serve loop.  A frame further ahead than
		# the ring is long is not waited for (a reader of one waited
		# for ever, parked): it is refused as one behind is, in the
		# words every reader takes to mean "go to the newest".
		nb := tm.offset / big fs;
		if(nb >= big seq + big Ring){
			s.srv.reply(ref Rmsg.Error(tm.tag, "frame expired"));
			return 1;
		}
		n := int nb;
		if(n >= seq)
			return 0;	# not made yet: wait for it
		(sn, fr) := ring[n % Ring];
		if(sn != n || fr == nil || len fr != fs){
			s.srv.reply(ref Rmsg.Error(tm.tag, "frame expired"));
			return 1;
		}
		(dw, dh) := ringdim[n % Ring];
		if(dw != s.w || dh != s.h){
			# turned since this reader last knew: once, saying how
			s.w = dw;
			s.h = dh;
			s.srv.reply(ref Rmsg.Error(tm.tag, sys->sprint("format changed: %d %d i420 %d", dw, dh, fps)));
			return 1;
		}
		k := tm.count;
		if(foff + k > fs)
			k = fs - foff;
		s.srv.reply(ref Rmsg.Read(tm.tag, fr[foff:foff+k]));
		return 1;
	}
	if(foff == 0 || s.fr == nil){
		if(lastraw == nil)
			return 0;
		s.fr = lastraw;
	}
	n := tm.count;
	if(foff > len s.fr)
		foff = len s.fr;
	if(foff + n > len s.fr)
		n = len s.fr - foff;
	s.srv.reply(ref Rmsg.Read(tm.tag, s.fr[foff:foff+n]));
	return 1;
}

wake()
{
	still: list of (ref Tmsg.Read, ref Fsess);
	for(p := parked; p != nil; p = tl p){
		(tm, s) := hd p;
		if(!reply(tm, s))
			still = (tm, s) :: still;
	}
	parked = still;
}

simdiv(): int
{
	if(sim)
		return Sim*Sim;
	return 1;
}

status(): string
{
	# as the capture is, not as its readers are counted: "on" with
	# readers and a sensor that would not start was not so, nor "off"
	# while the last frame of a stopped stream was still being made
	on := "off";
	if(running && capstop != nil)
		on = "on";
	else if(running)
		on = "stopping";
	first := seq - Ring;
	if(first < base)
		first = base;
	s := sys->sprint("camera w=%d h=%d framesize=%d frames=%d first=%d stream=%s", fw(), fh(), fsize, seq, first, on);
	if(sim)
		s += " sim=1";
	else
		s += " sensor=" + sensorname();
	# the mosaic's order as the sensor now reads it out: flip changes it
	order := "rggb";
	if(!sim)
		order = (array[] of {"rggb", "grbg", "gbrg", "bggr"})[flip & 3];
	s += sys->sprint(" rawformat=%s10:%d:%d", order, Sw/simdivr(), Sh/simdivr());
	if(linkbad)
		s += sys->sprint(" linkbad=%d", linkbad);
	if(regcheck != "")
		s += " regcheck=" + regcheck;
	if(afresult != "")
		s += " autofocus=" + afresult;
	# the gains in use, set or found: red and blue to green, 256 one
	s += sys->sprint(" wbgains=%d:%d", lgr, lgb);
	s += sys->sprint(" writes=%d i2cerrors=%d lostwrites=%d", nwrites, i2cerrs, lostw);
	if(err != "")
		s += " error=" + err;
	return s + "\n";
}

simdivr(): int
{
	if(sim)
		return Sim;
	return 1;
}

settings(): string
{
	wb := "auto";
	if(wbfixed)
		wb = sys->sprint("%d %d", wbr, wbb);
	return sys->sprint("mode %d %d\nfps %d\nexposure %d\ngain %d\nflip %d\nrotate %d\nfocus %d\nwb %s\n",
		fw(), fh(), fps, exposure, gain, flip, rotate, focus, wb);
}

# a ctl argument: a whole number of at most six digits, or -1
arg(s: string): int
{
	if(len s == 0 || len s > 6)
		return -1;
	for(i := 0; i < len s; i++)
		if(s[i] < '0' || s[i] > '9')
			return -1;
	return int s;
}

# One ctl write.  The count of words is looked at before any of them:
# "fps", "gain" and "flip" took the head of their argument first, and
# written with none ("echo fps > ctl") dereferenced nil in the serve
# loop.  An argument is a number or is refused ("exposure abc" set 0,
# which is automatic; "exposure -1" was taken).
doctl(s: string): string
{
	(n, f) := sys->tokenize(s, " \t\n");
	if(n == 0)
		return "camsrv: empty ctl";
	a := -1;
	if(n >= 2)
		a = arg(hd tl f);
	case hd f {
	"mode" =>
		if(n != 3)
			return "camsrv: mode W H";
		if((e := inuse()) != nil)
			return e;
		w := a;
		h := arg(hd tl tl f);
		if(rotate%180)
			(w, h) = (h, w);	# asked as served; merged as the sensor sees
		rw := Sw/simdivr();
		rh := Sh/simdivr();
		if(w <= 0 || h <= 0 || rw%w != 0)
			return "camsrv: no such mode";
		sc := rw/w;
		if(h*sc != rh || sc < 2 || sc&1 || (w|h)&1)
			return "camsrv: no such mode";
		width = w;
		height = h;
		fsize = framesize();
		latest = nil;
	"fps" =>
		if(n != 2 || a < 1 || a > maxfps())
			return sys->sprint("camsrv: fps 1..%d", maxfps());
		if((e := inuse()) != nil)
			return e;
		fps = a;
	"exposure" =>
		if(n != 2 || a < 0 || a > Maxexposure)
			return "camsrv: exposure LINES";
		exposure = a;
		tell("ae");
	"gain" =>
		if(n != 2 || a < 0 || a > Gainmax)
			return sys->sprint("camsrv: gain 0..%d", Gainmax);
		gain = a;
		tell("ae");
	"focus" =>
		if(sensor == Imx219)
			return "camsrv: the Camera Module 2 has a fixed-focus lens";
		if(n != 2)
			return "camsrv: focus N|auto";
		if(hd tl f == "auto"){
			if(users == 0)
				return "camsrv: not running";
			afrun = 1;
		}else{
			if(a < 0 || a > 1023)
				return "camsrv: focus 0..1023";
			focus = a;
			tell("lens");
		}
	"flip" =>
		if(n != 2 || a < 0 || a > 3)
			return "camsrv: flip 0..3";
		flip = a;
		tell("flip");
	"wb" =>
		if(n == 2 && hd tl f == "auto"){
			wbfixed = 0;
			wlr = nil;
		}else{
			if(n != 3)
				return "camsrv: wb auto|RED BLUE";
			r := arg(hd tl f);
			b := arg(hd tl tl f);
			if(r < 128 || r > 8*256 || b < 128 || b > 8*256)
				return "camsrv: wb gains 128..2048 (256 is one)";
			wbr = r;
			wbb = b;
			wbfixed = 1;
		}
	"rotate" =>
		if(n != 2)
			return "camsrv: rotate 0|90|180|270";
		# live: each frame is merged at the rotation then set, and a
		# reader of another width and height told once (reply)
		if(!rotation(hd tl f))
			return "camsrv: rotate 0|90|180|270";
		latest = nil;
	"stall" =>
		# the simulated sensor's next frame never comes, as a real
		# one's does not when its link has died
		if(!sim || n != 1)
			return "camsrv: unknown ctl " + hd f;
		simstall = 1;
	* =>
		return "camsrv: unknown ctl " + hd f;
	}
	return nil;
}

# What the picture is made from (mode, fps, flip, rotate) changes only
# with no capture running.  Readers were counted, not the capture: a
# change between the last close and the capture's end was taken, and the
# frame it was finishing was merged at one size into planes of another
# (an exception in the capture, which then never reported its end, so
# none was started again).  The capture is waited for.
inuse(): string
{
	if(users > 0)
		return "camsrv: in use";
	return settle();
}

readuser(): string
{
	fd := sys->open("/dev/user", Sys->OREAD);
	if(fd == nil)
		return nil;
	buf := array[128] of byte;
	n := sys->read(fd, buf, len buf);
	if(n <= 0)
		return nil;
	return string buf[0:n];
}

# for the capture process, if there is one; it reads the settings when it starts
tell(s: string)
{
	alt {
	ctlc <-= s =>
		;
	* =>
		;
	}
}

# One capture process at a time, ever. Starting the sensor can take a
# while (the bus retries), and a close followed by an open must not start
# a second capture beside one still on its way out: they would share the
# bus and the receiver, and close each other's files. So a start waits
# for the last capture to have gone.
running := 0;		# a capture process exists
wanted := 0;		# one should

startcapture()
{
	wanted = 1;
	if(!running)
		launch();
}

stopcapture()
{
	wanted = 0;
	if(capstop != nil){
		capstop <-= 1;
		capstop = nil;
		spawn stuck(capgen);
	}
}

stuck(g: int)
{
	sys->sleep(Stopwait);
	stuckc <-= g;
}

launch()
{
	# the numbers run on; the frames of before are not kept
	base = seq;
	for(i := 0; i < Ring; i++)
		ring[i] = (-1, nil);
	latest = nil;
	lastraw = nil;
	capstop = chan[1] of int;
	running = 1;
	cappid = -1;
	spawn capwrap(++capgen, capstop);
}

# A capture always says it has gone: one that raised (no room for a
# frame) left the server believing it was still running.
capwrap(g: int, stop: chan of int)
{
	cappidc <-= (g, sys->pctl(0, nil));
	e: string;
	{
		e = capture(stop);
	} exception x {
	"*" =>
		e = "camsrv: capture: " + x;
		if(!sim)
			sensoroff();
	}
	capdone <-= (g, e);
}

# The capture process: everything that touches the sensor, one place.
# What ended it, nil for a stop.
capture(stop: chan of int): string
{
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	if(sim){
		simulate(stop);
		return nil;
	}
	e := sensoron();
	if(e != nil){
		sensoroff();
		return e;
	}
	cerr: string;
	aewait := Aeevery;
	aesum := aen := 0;
	wlines := wgain := -1;
	raw := array[Sw*Sh*2] of byte;
	scale := Sw/width;
	(y, cb, cr) := planes();
	mean := array[6] of int;
	(lr, lg, lb) := tables(256, 256);
	aelines := framelen - Exposureoff;
	aegain := gaintoq(gain);
	af: ref Af;
	# the mirror the frames being merged were read out with: a write of the
	# register shows from the sensor's next frame, so the one being read
	# keeps the old order of colours (as exposure, Aeevery)
	mflip := flip;
	newflip := flip;
	flipwait := 0;
	Loop:
	for(;;){
		alt {
		<-stop =>
			break Loop;
		c := <-ctlc =>
			if(c == "lens" && focus >= 0)
				lens(focus);
			else if(c == "ae"){
				if(exposure != 0){
					aelines = exposure;
					aegain = gaintoq(gain);
				}
				wlines = -1;
			}else if(c == "flip" && flip != newflip){
				newflip = flip;
				# each sensor's own orientation register: this wrote
				# the IMX708's to an IMX219, which then did not turn
				# while its colours were merged as though it had
				if(sensor == Imx219)
					wr8(16r0172, flip);
				else
					wr8(16r0101, flip);
				flipwait = 2;
			}
		* =>
			;
		}
		fd := sys->open("/dev/unicam/frame", Sys->OREAD);
		if(fd == nil){
			cerr = sys->sprint("camsrv: %r");
			break;
		}
		if(!readall(fd, raw)){
			cerr = sys->sprint("camsrv: frame: %r");
			break;
		}
		fd = nil;
		if(++watchn >= Watchevery){
			watchn = 0;
			watchlink();
		}
		if(flipwait > 0 && --flipwait == 0)
			mflip = newflip;
		(y, cb, cr) = planes();
		rot := rotate;
		bayer->merge(raw, Sw, Sh, scale, mflip, rot/90, lr, lg, lb, y, cb, cr, mean, Clip);
		framec <-= (y[0:fsize], turnedw(rot), turnedh(rot));
		if(lastrawwanted())
			rawc <-= rawcopy(raw);
		(lr, lg, lb) = wbal(mean);
		focusing := afrun || (af != nil && af.on);
		if(focusing)
			af = autofocus(af, y);
		# not during a sweep: sharpness is to be compared at one exposure
		aesum += mean[1];
		aen++;
		if(!focusing && exposure == 0 && --aewait <= 0){
			aewait = Aeevery;
			(aelines, aegain) = aestep(aesum/aen, aelines, aegain);
			aesum = aen = 0;
		}
		if(aelines != wlines || aegain != wgain){
			setexposure(aelines, aegain);
			wlines = aelines;
			wgain = aegain;
		}
	}
	sensoroff();
	return cerr;
}

# A frame for /raw's readers, apart from raw: the next frame is read into
# raw while a reader may still be given this one, and it came torn.
rawcopy(raw: array of byte): array of byte
{
	c := array[len raw] of byte;
	c[0:] = raw;
	return c;
}

lastrawwanted(): int
{
	for(l := sess; l != nil; l = tl l)
		if((hd l).path == Qraw)
			return 1;
	return 0;
}

planes(): (array of byte, array of byte, array of byte)
{
	a := array[fsize] of byte;
	yn := width*height;
	cn := (width/2)*(height/2);
	return (a, a[yn:yn+cn], a[yn+cn:yn+2*cn]);
}

readall(fd: ref Sys->FD, b: array of byte): int
{
	n := 0;
	while(n < len b){
		m := sys->read(fd, b[n:], len b - n);
		if(m <= 0)
			return 0;
		n += m;
	}
	return 1;
}

# ---- image policy

# isqrt by Newton; the table is built when the balance moves
isqrt(v: int): int
{
	if(v <= 0)
		return 0;
	x := v;
	y := (x+1)/2;
	while(y < x){
		x = y;
		y = (x + v/x)/2;
	}
	return x;
}

tone(g: int): array of byte
{
	t := array[Maxsample+1] of byte;
	r := Maxsample - Black;
	for(i := 0; i <= Maxsample; i++){
		v := i - Black;
		if(v < 0)
			v = 0;
		v = v*g/256;
		if(v >= r)
			t[i] = byte 255;
		else
			t[i] = byte isqrt(v*65025/r);	# gamma 2
	}
	return t;
}

tables(gr, gb: int): (array of byte, array of byte, array of byte)
{
	lgr = gr;
	lgb = gb;
	return (tone(gr), tone(256), tone(gb));
}

lgr := 0;
lgb := 0;
# wb RED BLUE: fixed gains, 256 a gain of one, green's fixed at one;
# wb auto: grey world (the default)
wbfixed := 0;
wbr := 256;
wbb := 256;
wlr, wlg, wlb: array of byte;

# Grey world, moved a quarter of the way a frame, so that a passing
# colour does not swing the picture.
wbal(mean: array of int): (array of byte, array of byte, array of byte)
{
	if(wbfixed){
		# the gains set: the channels keep their own ratio, as plant
		# health from a NoIR camera needs (grey world takes it away)
		if(wlr == nil || lgr != wbr || lgb != wbb)
			(wlr, wlg, wlb) = tables(wbr, wbb);
		return (wlr, wlg, wlb);
	}
	# the means over cells with nothing clipped, if there are any: a
	# highlight clipped in one colour is that colour at its ceiling,
	# and pulled the balance away from it
	o := 0;
	if(len mean >= 6 && mean[4] > 0)
		o = 3;
	r := mean[o]-Black;
	g := mean[o+1]-Black;
	b := mean[o+2]-Black;
	if(r < 4)
		r = 4;
	if(b < 4)
		b = 4;
	if(g < 4)
		g = 4;
	tr := clamp(g*256/r, 128, 8*256);
	tb := clamp(g*256/b, 128, 8*256);
	# the tables made again while the gains in use are more than 1 in
	# 64 from the picture's, a quarter of the way at a time.  Asked
	# of the step, as it was, the balance stopped once a quarter of
	# what was left was under 1 in 16: a quarter short of the picture
	# (246:271 in daylight on a NoIR camera, whose grey was 218:321)
	if(wlr == nil || abs(tr-lgr)*64 > lgr || abs(tb-lgb)*64 > lgb)
		(wlr, wlg, wlb) = tables(step(lgr, tr), step(lgb, tb));
	return (wlr, wlg, wlb);
}

# a quarter of the way from v to w, and at least one
step(v, w: int): int
{
	d := (w-v)/4;
	if(d == 0 && w != v)
		d = (w-v)/abs(w-v);
	return v+d;
}

clamp(v, lo, hi: int): int
{
	if(v < lo)
		return lo;
	if(v > hi)
		return hi;
	return v;
}

abs(v: int): int
{
	if(v < 0)
		return -v;
	return v;
}

Gain1: con 256;

gaintoq(code: int): int
{
	return Gain1*Gainfull/(Gainfull-code);
}

# One step of auto-exposure, from the green cells' mean over the last
# Aeevery frames. Measured on the bench, a controller that went straight
# to the exposure it computed hunted for ever: what it writes shows two
# frames later, and a screen in view flickers from frame to frame, so it
# overshot, saw that, and went back, 27 register writes a second over a
# shared bus. So: half the way at a time, nothing inside a band of a
# third either side of the target, and nothing written that is not
# a real change.
aestep(green, lines, q: int): (int, int)
{
	v := green - Black;
	if(v < 2)
		v = 2;
	if(v*4 > Aetarget*3 && v*3 < Aetarget*4)
		return (lines, q);
	cur := big lines * big q;
	want := cur * big Aetarget / big v;
	total := (cur + want) / big 2;
	maxl := framelen - Exposureoff;
	l := int (total / big Gain1);
	g := Gain1;
	if(l < 4)
		l = 4;
	if(l > maxl){
		l = maxl;
		g = int (total / big l);
		if(g > gaintoq(Gainmax))
			g = gaintoq(Gainmax);
	}
	# a change of less than an eighth is no change
	nt := big l * big g;
	if(nt*big 8 > cur*big 7 && nt*big 7 < cur*big 8)
		return (lines, q);
	return (l, g);
}

Af: adt {
	on:	int;
	pos:	int;	# where the lens is
	end:	int;
	step:	int;
	best:	int;
	bestat:	int;
	worst:	int;	# the coarse pass's least sharp: what noise looks like here
	fine:	int;	# the second pass, round the first's peak
	tries:	int;
	was:	int;	# focus before, to go back to if this fails
	prev:	array of byte;	# the frame before, to see the picture is still
};

Afcoarse: con 64;
Affine: con 16;
Afsettle: con 3;	# frames: the lens moving, and two of sensor latency
Afmoving: con 6;	# mean difference of a pixel between frames: not a still picture
Aftries: con 3;

# Contrast autofocus, once: a coarse pass over the lens's whole travel,
# since a picture far out of focus has no detail near the right answer
# to climb towards, then a fine one round its peak. Sharpness means
# nothing while the picture changes, so each position is measured over
# two frames that must agree; a picture that will not hold still leaves
# the lens where it was and says so.
autofocus(a: ref Af, y: array of byte): ref Af
{
	if(a == nil || !a.on){
		afrun = 0;
		afresult = "running";
		a = ref Af(1, 0, 1023, Afcoarse, 0, 0, -1, 0, 0, focus, nil);
		lens(0);
		afwait = Afsettle;
		return a;
	}
	if(--afwait > 0)
		return a;
	if(a.prev == nil){
		a.prev = y;
		return a;
	}
	m := moved(a.prev, y);
	a.prev = nil;
	if(m > Afmoving){
		if(++a.tries > Aftries){
			afresult = "failed: the picture is moving";
			focus = a.was;
			if(focus >= 0)
				lens(focus);
			a.on = 0;
			return a;
		}
		afwait = 1;
		return a;
	}
	a.tries = 0;
	s := sharp(y);
	if(s > a.best){
		a.best = s;
		a.bestat = a.pos;
	}
	if(!a.fine && (a.worst < 0 || s < a.worst))
		a.worst = s;
	a.pos += a.step;
	if(a.pos > a.end){
		if(a.fine){
			focus = a.bestat;
			lens(focus);
			afresult = "ok";
			a.on = 0;
			return a;
		}
		# A picture with no detail has no sharpest place: its sharpness
		# is noise, and the peak of noise is anywhere (on the bench, a
		# plain grey screen sent the lens to 0, 288 and 1008, each called
		# a success). A real peak stands well clear of the rest.
		if(a.best < 4*a.worst){
			afresult = "failed: no detail";
			focus = a.was;
			if(focus >= 0)
				lens(focus);
			a.on = 0;
			return a;
		}
		a.fine = 1;
		a.step = Affine;
		a.pos = a.bestat - Afcoarse + Affine;
		if(a.pos < 0)
			a.pos = 0;
		a.end = a.bestat + Afcoarse - Affine;
		if(a.end > 1023)
			a.end = 1023;
	}
	lens(a.pos);
	afwait = Afsettle;
	return a;
}

afwait := 0;
afresult := "";

moved(a, b: array of byte): int
{
	s := n := 0;
	w := fw();
	h := fh();
	for(r := 0; r < h; r += 8)
		for(c := 0; c < w; c += 8){
			s += abs(int a[r*w+c] - int b[r*w+c]);
			n++;
		}
	return s/n;
}

sharp(y: array of byte): int
{
	s := 0;
	w := fw();
	h := fh();
	for(r := h/8; r < 7*h/8; r += 2){
		o := r*w + w/8;
		for(i := 0; i < 3*w/4; i++){
			d := int y[o+i] - int y[o+i+1];
			e := int y[o+i] - int y[o+i+w];
			s += d*d + e*e;
		}
	}
	return s;
}

# ---- the simulated sensor: bars, a band moving down, in RGGB

simulate(stop: chan of int)
{
	w := Sw/Sim;
	h := Sh/Sim;
	raw := array[w*h*2] of byte;
	scale := w/width;
	(y, cb, cr) := planes();
	mean := array[6] of int;
	(lr, lg, lb) := (tone(256), tone(256), tone(256));
	lgr = lgb = 256;
	band := 0;
	for(;;){
		# the stall before the stop: a frame that will not come does
		# not come for a capture told to stop either.  Looked at after
		# it, a stop that came while this was still making the last
		# frame was taken at once, and the stall was left set for the
		# next capture, whose first frame then never came.
		if(simstall){
			simstall = 0;
			<-chan of int;
		}
		alt {
		<-stop =>
			return;
		* =>
			;
		}
		t0 := sys->millisec();
		fill(raw, w, h, band);
		band = (band+4) % h;
		(y, cb, cr) = planes();
		rot := rotate;
		bayer->merge(raw, w, h, scale, 0, rot/90, lr, lg, lb, y, cb, cr, mean, Clip);
		framec <-= (y[0:fsize], turnedw(rot), turnedh(rot));
		if(lastrawwanted())
			rawc <-= rawcopy(raw);
		d := 1000/fps - (sys->millisec()-t0);
		if(d > 0)
			sys->sleep(d);
	}
}

fill(raw: array of byte, w, h, band: int)
{
	Bars: con 8;
	o := 0;
	for(y := 0; y < h; y++)
		for(x := 0; x < w; x++){
			b := x*Bars/w;
			c := (y&1)<<1 | (x&1);
			on := 0;
			case c {
			0 =>	on = (b&2) == 0 || b == 0;		# red
			1 or 2 =>	on = b < 4;				# green
			3 =>	on = (b&1) == 0;				# blue
			}
			v := 64;
			if(on)
				v = Maxsample;
			if(y >= band && y < band+16)
				v = 512;
			raw[o++] = byte v;
			raw[o++] = byte (v>>8);
		}
}

# ---- watching the link
#
# The receiver counts frame starts and frame ends. On a sound link they
# move together, at the frame rate; more starts than ends means it is
# taking noise for packets, and the sensor is no longer sending what it
# was told to. Then every register the mode set is read back, and what
# differs is reported: the bus is shared with the firmware, and a write
# that went astray is the likeliest cause.

Watchevery: con 150;
watchn := 0;
lastst := -1;
lastend := 0;
linkbad := 0;
regcheck := "";

watchlink()
{
	fd := sys->open("/dev/unicam/ctl", Sys->OREAD);
	if(fd == nil)
		return;
	b := array[256] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return;
	st := en := 0;
	(nil, l) := sys->tokenize(string b[0:n], "\n");
	for(; l != nil; l = tl l){
		(nt, t) := sys->tokenize(hd l, " ");
		if(nt == 2 && hd t == "starts")
			st = int hd tl t;
		if(nt == 2 && hd t == "ends")
			en = int hd tl t;
	}
	if(lastst >= 0 && (st-lastst) - (en-lastend) > Watchevery/10){
		linkbad++;
		regcheck = checkregs();
		sys->fprint(sys->fildes(2), "camsrv: link: %d starts for %d ends; %s\n", st-lastst, en-lastend, regcheck);
	}
	lastst = st;
	lastend = en;
}

checkregs(): string
{
	bad := 0;
	s := "";
	for(l := written; l != nil; l = tl l){
		(reg, v) := hd l;
		got := rd8(reg);
		if(got != v){
			bad++;
			if(len s < 120)
				s += sys->sprint(" %.4x=%.2x(want %.2x)", reg, got, v);
		}
	}
	return sys->sprint("%d registers differ%s", bad, s);
}

# ---- the sensor, over I2C

i2cerrs := 0;
lostw := 0;
# The firmware's touch polling holds the bus in bursts: transfers fail,
# reads and all, for longer than a few quick retries cover (measured:
# 8 tries 2 ms apart failed a sensor start one time in two). So a try
# waits twice as long as the one before, about half a second in all.
Tries: con 9;

backoff(i: int)
{
	sys->sleep(1<<i);
}
i2cctl, sensorfd, lensfd: ref Sys->FD;
# The IMX708's timing; sensorprobe sets the IMX219's.
Exposureoff := 48;		# lines: the exposure is at most frame length less this
Linelen := 7824;		# pixel clocks a line, at Pixrate
Pixrate := 585600000;		# the video timing PLL's pixel rate
Vblankmin := 40;		# lines: the least vertical blank a frame needs
framelen := 0;
# the registers auto-exposure writes, which a read-back check leaves out
Regexposure := 16r0202;
Reggain := 16r0204;
Gainbits := 16;
Gainmax := 960;			# the highest gain code
Gainfull := 1024;		# gain = Gainfull/(Gainfull-code)

# The most frames a second the sensor's timing allows: its shortest frame
# (its height and least vertical blank) at its pixel rate. The IMX708's
# is 56, the IMX219's 41; asking more was taken and silently held to it
# while fmt said what was asked.
maxfps(): int
{
	return int (big Pixrate / (big Linelen * big (Sh + Vblankmin)));
}

ctlset(fd: ref Sys->FD, s: string): int
{
	return sys->fprint(fd, "%s", s);
}

# The sensor's bus in #J: the receiver's ctl names it ("i2c i2c4" on a
# Pi 5, a connector's own bus); the Pi 4's says nothing, and its camera
# bus is i2c0.
i2cbus := "i2c0";

sensorbus(): string
{
	fd := sys->open("/dev/unicam/ctl", Sys->OREAD);
	if(fd == nil)
		return "i2c0";
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return "i2c0";
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf == 2 && hd f == "i2c")
			return hd tl f;
	}
	return "i2c0";
}

# an open of i2cNdata keeps the device ctl named when it was opened
opendev(addr, sub: int): ref Sys->FD
{
	if(sys->fprint(i2cctl, "addr %d", addr) < 0 || sys->fprint(i2cctl, "subaddress %d", sub) < 0)
		return nil;
	return sys->open("/dev/" + i2cbus + "data", Sys->ORDWR);
}

rd8(reg: int): int
{
	b := array[1] of byte;
	for(i := 0; i < Tries; i++){
		if(sys->pread(sensorfd, b, 1, big reg) == 1)
			return int b[0];
		i2cerrs++;
		backoff(i);
	}
	return -1;
}

written: list of (int, int);
nwrites := 0;		# register writes since the sensor came on, for status
badreg := "";		# the last register that would not take a write, for errors

wr8(reg, v: int): int
{
	nwrites++;
	if(reg != 16r0100 && reg != Regexposure && reg != Regexposure+1 && reg != Reggain && reg != Reggain+1)
		written = (reg, v&16rff) :: written;
	b := array[1] of byte;
	b[0] = byte v;
	for(i := 0; i < Tries; i++){
		if(sys->pwrite(sensorfd, b, 1, big reg) != 1){
			i2cerrs++;
			backoff(i);
			continue;
		}
		got := rd8(reg);
		if(got == (v&16rff))
			return 0;
		lostw++;
		badreg = sys->sprint("%.4x wrote %.2x read %d", reg, v&16rff, got);
		backoff(i);
	}
	return -1;
}

wr16(reg, v: int): int
{
	if(wr8(reg, v>>8) < 0)
		return -1;
	return wr8(reg+1, v);
}

setexposure(lines, q: int)
{
	code := Gainfull - Gainfull*Gain1/q;
	if(code > Gainmax)
		code = Gainmax;
	if(code < 0)
		code = 0;
	gain = code;
	if(lines > framelen-Exposureoff)
		lines = framelen-Exposureoff;
	r := wr16(Regexposure, lines);
	if(Gainbits == 8)
		r |= wr8(Reggain, code);
	else
		r |= wr16(Reggain, code);
	if(r < 0)
		sys->fprint(sys->fildes(2), "camsrv: exposure: %r\n");
}

lens(pos: int)
{
	if(lensfd == nil)
		return;
	b := array[1] of byte;
	b[0] = byte 0;
	sys->pwrite(lensfd, b, 1, big 2);	# control: on
	b = array[2] of byte;
	b[0] = byte (pos>>8);
	b[1] = byte pos;
	sys->pwrite(lensfd, b, 2, big 3);
}

# The receiver's ctl, held open for writing from sensoron to sensoroff:
# the Pi 5's #V takes one writer, so a second camsrv is refused there
# rather than powering off this one's camera, and its close turns off
# what a killed camsrv left on.
unicamfd: ref Sys->FD;

unicam(s: string): string
{
	if(unicamfd == nil || sys->fprint(unicamfd, "%s", s) < 0)
		return sys->sprint("camsrv: unicam %s: %r", s);
	return nil;
}

# The receiver's connectors, if it has more than one to choose from (a
# Pi 5's "port" line in its ctl); nil for one (the Pi 4's).
ports(): list of string
{
	fd := sys->open("/dev/unicam/ctl", Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[1024] of byte;
	n := sys->read(fd, b, len b);
	if(n <= 0)
		return nil;
	(nil, lines) := sys->tokenize(string b[0:n], "\n");
	for(; lines != nil; lines = tl lines){
		(nf, f) := sys->tokenize(hd lines, " \t");
		if(nf == 2 && hd f == "port"){
			# the one it is on first: where the camera was found last
			if(hd tl f == "1")
				return "1" :: "0" :: nil;
			return "0" :: "1" :: nil;
		}
	}
	return nil;
}

# Power and find the sensor on a connector: nil, or why not.
sensorfind(): string
{
	e := unicam("power on");
	if(e != nil)
		return e;
	i2cbus = sensorbus();
	i2cctl = sys->open("/dev/" + i2cbus + "ctl", Sys->ORDWR);
	if(i2cctl == nil)
		return sys->sprint("camsrv: i2c: %r");
	if(sensor == Imx219){
		sensorfd = opendev(Sensor219, 2);
		if(sensorfd == nil)
			return sys->sprint("camsrv: i2c: %r");
		id := chipid(16r0000, Chip219);
		if(id < 0)
			return "camsrv: nothing answers at the IMX219's address";
		if(id != Chip219)
			return sys->sprint("camsrv: not an IMX219: %.4x", id);
		return nil;
	}
	sensorfd = opendev(Sensor, 2);
	lensfd = opendev(Lens, 1);
	if(sensorfd == nil || lensfd == nil)
		return sys->sprint("camsrv: i2c: %r");
	id := chipid(16r0016, Chip);
	if(id < 0)
		return "camsrv: nothing answers at the sensor's address";
	if(id != Chip)
		return sys->sprint("camsrv: not an IMX708: %.4x", id);
	return nil;
}

sensoron(): string
{
	unicamfd = sys->open("/dev/unicam/ctl", Sys->OWRITE);
	if(unicamfd == nil)
		return sys->sprint("camsrv: the camera: %r");
	unicam("stream off");		# what a killed server left, if it did
	lastst = -1;
	e := unicam(sys->sprint("format %d %d", Sw, Sh));
	if(e != nil)
		return e;
	pl := ports();
	if(pl == nil)
		e = sensorfind();
	for(; pl != nil; pl = tl pl){
		unicam("power off");
		if((e = unicam("port " + hd pl)) == nil && (e = sensorfind()) == nil)
			break;
	}
	if(e != nil)
		return e;
	r := 0;
	if(sensor == Imx219)
		r = sensormode219();
	else
		r = sensormode();
	if(r < 0)
		return "camsrv: the sensor will not take its settings: " + badreg;
	e = unicam("stream on");
	if(e != nil)
		return e;
	if(wr8(16r0100, 1) < 0)
		return "camsrv: the sensor will not start";
	if(focus >= 0)
		lens(focus);
	return nil;
}

# The mode: the sensor's 2x2 binned readout, 2304x1296 of its 4608x2592,
# RAW10 on two CSI-2 lanes. The registers are MIPI CCS's, named below as
# the standard names them, except 3200 and 3201. Each was tested by
# leaving it out, on the sensor, against the same picture (2026-11-03),
# and those that changed nothing are not written.
#
# The clocks: the video timing PLL makes the pixel rate (Pixrate) the
# line length is counted in, and the output PLL the lanes' rate, 900
# Mbit/s a lane.
# Left at the sensor's own timing the stream drops frames, so both
# stay; frame length is worked out from the line length and the fps.
sensormode(): int
{
	written = nil;
	fl := Pixrate / (Linelen * fps);
	if(fl < Sh + Vblankmin)
		fl = Sh + Vblankmin;
	framelen = fl;
	r := 0;
	r |= wr8(16r0100, 0);			# mode_select: standby
	r |= wr16(16r0136, 24<<8);		# extclk_frequency_mhz: the board's 24 MHz, in 8.8
	r |= wr16(16r0112, 16r0A0A);		# csi_data_format: RAW10 in, RAW10 out
	r |= wr8(16r0114, 1);			# csi_lane_mode: two lanes (lanes - 1)
	# the video timing PLL: 24 MHz / 2 * 122 = 1464 MHz, divided for the
	# pixel path
	r |= wr8(16r0301, 5);			# vt_pix_clk_div
	r |= wr8(16r0303, 2);			# vt_sys_clk_div
	r |= wr8(16r0305, 2);			# pre_pll_clk_div
	r |= wr16(16r0306, 122);		# pll_multiplier
	# the output PLL: 24 MHz / 4 * 300 = 1800 MHz, / 2: 900 Mbit/s a
	# lane, a 450 MHz clock on both edges
	r |= wr8(16r030B, 2);			# op_sys_clk_div
	r |= wr8(16r030D, 4);			# op_pre_pll_clk_div
	r |= wr16(16r030E, 300);		# op_pll_multiplier: 450 MHz, 900 Mbit/s a lane
	r |= wr8(16r0310, 1);			# pll_mode: the two PLLs apart
	r |= wr16(16r0342, Linelen);		# line_length_pck
	r |= wr16(16r0340, fl);			# frame_length_lines: sets the fps
	r |= wr16(16r0344, 0);			# x_addr_start: the whole array
	r |= wr16(16r0346, 0);			# y_addr_start
	r |= wr16(16r0348, 2*Sw-1);		# x_addr_end
	r |= wr16(16r034A, 2*Sh-1);		# y_addr_end
	r |= wr8(16r0900, 1);			# binning_mode: on
	r |= wr8(16r0901, 16r22);		# binning_type: two by two
	r |= wr8(16r0902, 8);			# binning_weighting
	r |= wr8(16r3200, 16r41);		# not CCS: measured, without these
	r |= wr8(16r3201, 16r41);		#   the binned frame has no colour
	r |= wr16(16r0408, 0);			# digital_crop_x_offset: no crop
	r |= wr16(16r040A, 0);			# digital_crop_y_offset
	r |= wr16(16r040C, Sw);			# digital_crop_image_width
	r |= wr16(16r040E, Sh);			# digital_crop_image_height
	r |= wr16(16r034C, Sw);			# x_output_size
	r |= wr16(16r034E, Sh);			# y_output_size
	r |= wr8(16r0101, flip);		# image_orientation: mirror and flip
	l := fl - Exposureoff;
	if(exposure != 0)
		l = exposure;
	r |= wr16(16r0202, l);
	r |= wr16(16r0204, gain);
	return r;
}

# The chip's id, from its two id registers, asked until it is the one
# wanted or Tries have passed (the bus is shared: one read can be
# wrong); -1 if nothing answers.
chipid(reg, want: int): int
{
	id := 0;
	for(i := 0; i < Tries && id != want; i++){
		a := rd8(reg);
		b := rd8(reg+1);
		if(a < 0 || b < 0)
			return -1;
		id = a<<8 | b;
	}
	return id;
}

sensorname(): string
{
	case sensor {
	Imx219 =>
		return "imx219";
	}
	return "imx708";
}

# Which camera is on the connector (on each, where the receiver has
# two): powered for as long as it takes to ask the IMX708's address and
# then the IMX219's, on the bus the receiver names. Nothing answering
# leaves the IMX708, whose errors then say so when a reader starts it.
sensorprobe()
{
	unicamfd = sys->open("/dev/unicam/ctl", Sys->OWRITE);
	if(unicamfd == nil)
		return;
	errs := i2cerrs;	# an address nothing answers at is the probe's answer, not a bus error
	pl := ports();
	if(pl == nil)
		probeone();
	for(; pl != nil; pl = tl pl){
		unicam("power off");
		if(unicam("port " + hd pl) == nil && probeone())
			break;
	}
	unicam("power off");
	unicamfd = nil;
	i2cctl = sensorfd = lensfd = nil;
	i2cerrs = errs;
}

probeone(): int
{
	if(unicam("power on") != nil)
		return 0;
	i2cbus = sensorbus();
	i2cctl = sys->open("/dev/" + i2cbus + "ctl", Sys->ORDWR);
	if(i2cctl == nil)
		return 0;
	sensorfd = opendev(Sensor, 2);
	if(sensorfd != nil && chipid(16r0016, Chip) == Chip)
		return 1;
	sensorfd = opendev(Sensor219, 2);
	if(sensorfd != nil && chipid(16r0000, Chip219) == Chip219){
		imx219();
		return 1;
	}
	return 0;
}

# The IMX219's mode and timing: the Raspberry Pi firmware's mode 4,
# 1640x1232 of its 3280x2464, 2x2 binned, RAW10 on two lanes at 912
# Mbit/s a lane; a 182.4 MHz pixel rate over lines of 3448 clocks.
imx219()
{
	sensor = Imx219;
	Sw = 1640;
	Sh = 1232;
	Exposureoff = 4;
	Linelen = 3448;
	Pixrate = 182400000;
	Vblankmin = 32;
	Regexposure = 16r015A;
	Reggain = 16r0157;
	Gainbits = 8;
	Gainmax = 232;		# analogue gain 256/(256-code): at most 10.7
	Gainfull = 256;
	gain = 0;
	width = Sw/4;
	height = Sh/4;
	fsize = framesize();
}

# a write the sensor does not read back as written: its access
# sequence, and registers whose reading is not what was set
wrraw(reg, v: int): int
{
	nwrites++;
	b := array[1] of byte;
	b[0] = byte v;
	for(i := 0; i < Tries; i++){
		if(sys->pwrite(sensorfd, b, 1, big reg) == 1)
			return 0;
		i2cerrs++;
		backoff(i);
	}
	badreg = sys->sprint("%.4x not written", reg);
	return -1;
}

# The IMX219's registers, as the firmware sets them for mode 4 (and the
# Linux driver after it): the MIPI CCS names below except 3000-5fff, the
# manufacturer's, opened by the sequence on 30eb and not documented.
sensormode219(): int
{
	written = nil;
	fl := Pixrate / (Linelen * fps);
	if(fl < Sh + Vblankmin)
		fl = Sh + Vblankmin;
	framelen = fl;
	r := 0;
	r |= wr8(16r0100, 0);			# mode_select: standby
	r |= wrraw(16r30EB, 16r05);		# the manufacturer's registers, opened
	r |= wrraw(16r30EB, 16r0C);
	r |= wrraw(16r300A, 16rFF);
	r |= wrraw(16r300B, 16rFF);
	r |= wrraw(16r30EB, 16r05);
	r |= wrraw(16r30EB, 16r09);
	r |= wrraw(16r455E, 16r00);		# and set, as the firmware sets them
	r |= wrraw(16r471E, 16r4B);
	r |= wrraw(16r4767, 16r0F);
	r |= wrraw(16r4750, 16r14);
	r |= wrraw(16r4540, 16r00);
	r |= wrraw(16r47B4, 16r14);
	r |= wrraw(16r4713, 16r30);
	r |= wrraw(16r478B, 16r10);
	r |= wrraw(16r478F, 16r10);
	r |= wrraw(16r4793, 16r10);
	r |= wrraw(16r4797, 16r0E);
	r |= wrraw(16r479B, 16r0E);
	r |= wr16(16r0162, Linelen);		# line_length_pck
	r |= wr8(16r0170, 1);			# x_odd_inc
	r |= wr8(16r0171, 1);			# y_odd_inc
	r |= wr8(16r0128, 0);			# dphy_ctrl: automatic timing
	r |= wr16(16r012A, 24<<8);		# exck_freq: the board's 24 MHz, in 8.8
	# the PLLs: 24 MHz / 3 * 57 = 456 MHz, the pixel path over 5;
	# 24 / 3 * 114 = 912 Mbit/s a lane
	r |= wr8(16r0301, 5);			# vtpxck_div
	r |= wr8(16r0303, 1);			# vtsyck_div
	r |= wr8(16r0304, 3);			# prepllck_vt_div
	r |= wr8(16r0305, 3);			# prepllck_op_div
	r |= wr16(16r0306, 57);			# pll_vt_mpy
	r |= wr8(16r030B, 1);			# opsyck_div
	r |= wr16(16r030C, 114);		# pll_op_mpy
	r |= wr8(16r0114, 1);			# csi_lane_mode: two lanes
	r |= wr16(16r0164, 0);			# x_add_sta: the whole array
	r |= wr16(16r0166, 2*Sw-1);		# x_add_end
	r |= wr16(16r0168, 0);			# y_add_sta
	r |= wr16(16r016A, 2*Sh-1);		# y_add_end
	r |= wr16(16r016C, Sw);			# x_output_size
	r |= wr16(16r016E, Sh);			# y_output_size
	r |= wr16(16r0624, Sw);			# tp_window_width
	r |= wr16(16r0626, Sh);			# tp_window_height
	r |= wr16(16r0174, 16r0101);		# binning_mode: two by two, both ways
	r |= wr16(16r018C, 16r0A0A);		# csi_data_format: RAW10
	r |= wr8(16r0309, 10);			# oppxck_div: for ten bits
	r |= wr8(16r0172, flip);		# image_orientation: mirror and flip
	r |= wr16(16r0160, fl);			# frame_length_lines: sets the fps
	l := fl - Exposureoff;
	if(exposure != 0)
		l = exposure;
	r |= wr16(16r015A, l);			# coarse_integration_time
	r |= wr8(16r0157, gain);		# analogue gain
	r |= wr16(16r0158, 16r0100);		# digital gain: 1
	return r;
}

sensoroff()
{
	wr8(16r0100, 0);
	unicam("stream off");
	unicam("power off");
	i2cctl = sensorfd = lensfd = nil;
	unicamfd = nil;
}
