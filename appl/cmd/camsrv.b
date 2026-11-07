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
#                               for it. A live reader starts at the newest
#                               (status frames= less one) and skips ahead
#                               when it falls behind. Numbers run on across
#                               the sensor going off and on.
#   /mnt/video/0/raw      read  one frame as the sensor gave it, 16 bits a
#                               sample little-endian, w*2 by h*2 pixels
#                               scaled; its format is in status
#   /mnt/video/0/status   read  one line of key=value: frames= (one past
#                               the newest frame) and first= (the oldest
#                               kept), and no pos=: a live feed
#   /mnt/video/0/ctl      write mode W H | fps N | exposure LINES (0 = auto)
#                               gain CODE | focus N | focus auto | flip N
#                               rotate 0|90|180|270
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
# about the Camera Module 3 is here. The bus is shared with the firmware,
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

# the sensor's one mode; smaller frames are merged from it
Sw: con 2304;
Sh: con 1296;
Black: con 64;
Maxsample: con 1023;
Aetarget: con 180;	# above black, of 959: near a grey card's 18%
Aeevery: con 4;		# frames: what is written shows two later

Chip: con 16r0708;
Sensor: con 16r1A;
Lens: con 16r0C;

Sim: con 2;		# the simulated sensor's raw is this much smaller

srv: ref Styxserver;
tc: chan of ref Tmsg;
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
latest: array of byte;
lastraw: array of byte;
err := "";

Fsess: adt {
	fid:	int;
	path:	int;
	seq:	int;		# the last frame this fid took
	fr:	array of byte;	# the frame it is in
};
sess: list of ref Fsess;
parked: list of (ref Tmsg.Read, ref Fsess);
users := 0;
capstop: chan of int;
capdone: chan of int;
framec: chan of array of byte;
rawc: chan of array of byte;
errc: chan of string;
ctlc: chan of string;

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
	fsize = framesize();
	framec = chan of array of byte;
	rawc = chan of array of byte;
	errc = chan[1] of string;
	capdone = chan of int;
	ctlc = chan[8] of string;

	(tree, treeop) := nametree->start();
	tree.create(big Qroot, dir(".", Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot, dir("0", Sys->DMDIR|8r555, Qstream));
	tree.create(big Qstream, dir("ctl", 8r666, Qctl));
	tree.create(big Qstream, dir("fmt", 8r444, Qfmt));
	tree.create(big Qstream, dir("frame", 8r444, Qframe));
	tree.create(big Qstream, dir("raw", 8r444, Qraw));
	tree.create(big Qstream, dir("status", 8r444, Qstatus));
	# empty as served: where the feed's layers are bound (#1095)
	tree.create(big Qstream, dir("layer", Sys->DMDIR|8r555, Qlayer));
	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qroot);
	if(logfile != nil)
		spawn statuslog(logfile);
	serve(tree);
}

dir(name: string, perm, path: int): Sys->Dir
{
	d := sys->zerodir;
	d.name = name;
	d.uid = d.gid = "camsrv";
	d.mode = perm;
	d.qid.path = big path;
	if(perm & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	return d;
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
	tmsg := <-tc =>
		if(tmsg == nil){
			shutdown(tree);
			return;
		}
		pick tm := tmsg {
		Readerror =>
			shutdown(tree);
			return;
		Open =>
			c := srv.getfid(tm.fid);
			path := -1;
			if(c != nil)
				path = int c.path;
			if((path == Qframe || path == Qraw) && err != "" && users == 0)
				err = "";
			if(srv.open(tm) != nil && (path == Qframe || path == Qraw)){
				sess = ref Fsess(tm.fid, path, seq, nil) :: sess;
				if(users++ == 0)
					startcapture();
			}
		Clunk =>
			drop(tm.fid);
			srv.default(tmsg);
		Remove =>
			drop(tm.fid);
			srv.default(tmsg);
		Read =>
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
				break;
			}
			case int c.path {
			Qroot or Qstream or Qlayer =>
				srv.read(tm);
			Qfmt =>
				srv.reply(styxservers->readstr(tm, sys->sprint("%d %d i420 %d\n", fw(), fh(), fps)));
			Qstatus =>
				srv.reply(styxservers->readstr(tm, status()));
			Qctl =>
				srv.reply(styxservers->readstr(tm, settings()));
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
			c := srv.getfid(tm.fid);
			if(c == nil || !c.isopen)
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Ebadfid));
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
	fr := <-framec =>
		latest = fr;
		ring[seq % Ring] = (seq, fr);
		seq++;
		wake();
	r := <-rawc =>
		lastraw = r;
		wake();
	e := <-errc =>
		err = e;
		wake();
	<-capdone =>
		running = 0;
		capstop = nil;
		if(wanted && err == "")
			launch();
	}
}

# The mount has gone. The capture process may be in the middle of a frame,
# blocked handing it over: take what it sends until it has gone, or it
# waits for ever, with the sensor on and the name tree held.
shutdown(tree: ref Tree)
{
	stopcapture();
	while(running) alt {
	<-framec =>
		;
	<-rawc =>
		;
	<-errc =>
		;
	<-capdone =>
		running = 0;
	}
	tree.quit();
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
		if((hd l).fid == fid)
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
	p: list of (ref Tmsg.Read, ref Fsess);
	for(q := parked; q != nil; q = tl q){
		(tm, ps) := hd q;
		if(ps != s)
			p = (tm, ps) :: p;
	}
	parked = p;
	if(--users == 0)
		stopcapture();
}

# 1 if a reply went
reply(tm: ref Tmsg.Read, s: ref Fsess): int
{
	if(err != ""){
		srv.reply(ref Rmsg.Error(tm.tag, err));
		return 1;
	}
	fs := fsize;
	if(s.path == Qraw)
		fs = Sw*Sh*2/simdiv();
	if(fs <= 0)
		return 0;
	foff := int (tm.offset % big fs);
	if(s.path == Qraw && tm.offset >= big fs){
		srv.reply(ref Rmsg.Read(tm.tag, array[0] of byte));
		return 1;
	}
	if(s.path == Qframe){
		# frame n, as every reader numbers it
		n := int (tm.offset / big fs);
		if(n >= seq)
			return 0;	# not made yet: wait for it
		(sn, fr) := ring[n % Ring];
		if(sn != n || fr == nil || len fr != fs){
			srv.reply(ref Rmsg.Error(tm.tag, "frame expired"));
			return 1;
		}
		k := tm.count;
		if(foff + k > fs)
			k = fs - foff;
		srv.reply(ref Rmsg.Read(tm.tag, fr[foff:foff+k]));
		return 1;
	}
	if(foff == 0 || s.fr == nil){
		if(lastraw == nil)
			return 0;
		s.fr = lastraw;
	}
	n := tm.count;
	if(foff + n > len s.fr)
		n = len s.fr - foff;
	srv.reply(ref Rmsg.Read(tm.tag, s.fr[foff:foff+n]));
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
	on := "off";
	if(users > 0)
		on = "on";
	first := seq - Ring;
	if(first < base)
		first = base;
	s := sys->sprint("camera w=%d h=%d framesize=%d frames=%d first=%d stream=%s", fw(), fh(), fsize, seq, first, on);
	if(sim)
		s += " sim=1";
	s += sys->sprint(" rawformat=rggb10:%d:%d", Sw/simdivr(), Sh/simdivr());
	if(linkbad)
		s += sys->sprint(" linkbad=%d", linkbad);
	if(regcheck != "")
		s += " regcheck=" + regcheck;
	if(afresult != "")
		s += " autofocus=" + afresult;
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
	return sys->sprint("mode %d %d\nfps %d\nexposure %d\ngain %d\nflip %d\nrotate %d\nfocus %d\n",
		fw(), fh(), fps, exposure, gain, flip, rotate, focus);
}

doctl(s: string): string
{
	(n, f) := sys->tokenize(s, " \t\n");
	if(n == 0)
		return "camsrv: empty ctl";
	case hd f {
	"mode" =>
		if(n != 3)
			return "camsrv: mode W H";
		if(users > 0)
			return "camsrv: in use";
		w := int hd tl f;
		h := int hd tl tl f;
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
		v := int hd tl f;
		if(n != 2 || v < 1 || v > 56)
			return "camsrv: fps 1..56";
		if(users > 0)
			return "camsrv: in use";
		fps = v;
	"exposure" =>
		if(n != 2)
			return "camsrv: exposure LINES";
		exposure = int hd tl f;
		tell("ae");
	"gain" =>
		v := int hd tl f;
		if(n != 2 || v < 0 || v > 960)
			return "camsrv: gain 0..960";
		gain = v;
		tell("ae");
	"focus" =>
		if(n != 2)
			return "camsrv: focus N|auto";
		if(hd tl f == "auto"){
			if(users == 0)
				return "camsrv: not running";
			afrun = 1;
		}else{
			v := int hd tl f;
			if(v < 0 || v > 1023)
				return "camsrv: focus 0..1023";
			focus = v;
			tell("lens");
		}
	"flip" =>
		v := int hd tl f;
		if(n != 2 || v < 0 || v > 3)
			return "camsrv: flip 0..3";
		if(users > 0)
			return "camsrv: in use";
		flip = v;
	"rotate" =>
		if(n != 2)
			return "camsrv: rotate 0|90|180|270";
		if(users > 0)
			return "camsrv: in use";
		if(!rotation(hd tl f))
			return "camsrv: rotate 0|90|180|270";
		latest = nil;
	* =>
		return "camsrv: unknown ctl " + hd f;
	}
	return nil;
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
	}
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
	spawn capwrap(capstop);
}

capwrap(stop: chan of int)
{
	capture(stop);
	capdone <-= 1;
}

# The capture process: everything that touches the sensor, one place.
capture(stop: chan of int)
{
	sys->pctl(Sys->NEWFD, 0 :: 1 :: 2 :: nil);
	if(sim){
		simulate(stop);
		return;
	}
	e := sensoron();
	if(e != nil){
		sensoroff();
		errc <-= e;
		return;
	}
	aewait := Aeevery;
	aesum := aen := 0;
	wlines := wgain := -1;
	raw := array[Sw*Sh*2] of byte;
	scale := Sw/width;
	(y, cb, cr) := planes();
	mean := array[3] of int;
	(lr, lg, lb) := tables(256, 256);
	aelines := framelen - Exposureoff;
	aegain := gaintoq(gain);
	af: ref Af;
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
			}
		* =>
			;
		}
		fd := sys->open("/dev/unicam/frame", Sys->OREAD);
		if(fd == nil){
			errc <-= sys->sprint("camsrv: %r");
			break;
		}
		if(!readall(fd, raw)){
			errc <-= sys->sprint("camsrv: frame: %r");
			break;
		}
		fd = nil;
		if(++watchn >= Watchevery){
			watchn = 0;
			watchlink();
		}
		(y, cb, cr) = planes();
		bayer->merge(raw, Sw, Sh, scale, flip, rotate/90, lr, lg, lb, y, cb, cr, mean);
		framec <-= y[0:fsize];
		if(lastrawwanted())
			rawc <-= raw[0:];
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
wlr, wlg, wlb: array of byte;

# Grey world, moved a quarter of the way a frame, so that a passing
# colour does not swing the picture.
wbal(mean: array of int): (array of byte, array of byte, array of byte)
{
	r := mean[0]-Black;
	g := mean[1]-Black;
	b := mean[2]-Black;
	if(r < 4)
		r = 4;
	if(b < 4)
		b = 4;
	if(g < 4)
		g = 4;
	gr := clamp(g*256/r, 128, 8*256);
	gb := clamp(g*256/b, 128, 8*256);
	gr = lgr + (gr-lgr)/4;
	gb = lgb + (gb-lgb)/4;
	if(wlr == nil || abs(gr-lgr)*16 > lgr || abs(gb-lgb)*16 > lgb){
		(wlr, wlg, wlb) = tables(gr, gb);
	}
	return (wlr, wlg, wlb);
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
Gainmaxq: con 16*Gain1;

gaintoq(code: int): int
{
	return Gain1*1024/(1024-code);
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
		if(g > Gainmaxq)
			g = Gainmaxq;
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
	mean := array[3] of int;
	(lr, lg, lb) := (tone(256), tone(256), tone(256));
	lgr = lgb = 256;
	band := 0;
	for(;;){
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
		bayer->merge(raw, w, h, scale, 0, rotate/90, lr, lg, lb, y, cb, cr, mean);
		framec <-= y[0:fsize];
		if(lastrawwanted())
			rawc <-= raw[0:];
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
Exposureoff: con 48;
Linelen: con 7824;
Pixrate: con 585600000;
Vblankmin: con 40;
framelen := 0;

ctlset(fd: ref Sys->FD, s: string): int
{
	return sys->fprint(fd, "%s", s);
}

# an open of i2c0data keeps the device ctl named when it was opened
opendev(addr, sub: int): ref Sys->FD
{
	if(sys->fprint(i2cctl, "addr %d", addr) < 0 || sys->fprint(i2cctl, "subaddress %d", sub) < 0)
		return nil;
	return sys->open("/dev/i2c0data", Sys->ORDWR);
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
	if(reg != 16r0100 && reg != 16r0202 && reg != 16r0203 && reg != 16r0204 && reg != 16r0205)
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
	code := 1024 - 1024*Gain1/q;
	if(code > 960)
		code = 960;
	gain = code;
	if(lines > framelen-Exposureoff)
		lines = framelen-Exposureoff;
	if(wr16(16r0202, lines) < 0 || wr16(16r0204, code) < 0)
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

unicam(s: string): string
{
	fd := sys->open("/dev/unicam/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", s) < 0)
		return sys->sprint("camsrv: unicam %s: %r", s);
	return nil;
}

sensoron(): string
{
	unicam("stream off");		# what a killed server left, if it did
	lastst = -1;
	e := unicam(sys->sprint("format %d %d", Sw, Sh));
	if(e == nil)
		e = unicam("power on");
	if(e != nil)
		return e;
	i2cctl = sys->open("/dev/i2c0ctl", Sys->ORDWR);
	if(i2cctl == nil)
		return sys->sprint("camsrv: i2c: %r");
	sensorfd = opendev(Sensor, 2);
	lensfd = opendev(Lens, 1);
	if(sensorfd == nil || lensfd == nil)
		return sys->sprint("camsrv: i2c: %r");
	id := 0;
	for(i := 0; i < Tries && id != Chip; i++){
		a := rd8(16r0016);
		b := rd8(16r0017);
		if(a < 0 || b < 0)
			return "camsrv: nothing answers at the sensor's address";
		id = a<<8 | b;
	}
	if(id != Chip)
		return sys->sprint("camsrv: not an IMX708: %.4x", id);
	if(sensormode() < 0)
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

# The mode, as CCS registers. Each was tested by leaving it out, on the
# sensor, against the same picture (2026-11-03), and those that changed
# nothing are not written. Of the rest, the registers' meanings are the
# standard's, but these VALUES were read from the Linux imx708 driver,
# which is GPL, and are not yet derived independently:
#	the PLLs (0301 0303 0305 0306, 030B 030D 030E), the line length
#	(0342, so Linelen and Pixrate), and 3200/3201, which are not CCS:
#	without them the binned frame has no colour.
# Left at the sensor's own timing the stream drops frames, so the PLLs
# and line length stay; frame length is worked out from them.
sensormode(): int
{
	written = nil;
	fl := Pixrate / (Linelen * fps);
	if(fl < Sh + Vblankmin)
		fl = Sh + Vblankmin;
	framelen = fl;
	r := 0;
	r |= wr8(16r0100, 0);
	r |= wr16(16r0136, 24<<8);		# external clock, 24 MHz in 8.8
	r |= wr16(16r0112, 16r0A0A);		# RAW10
	r |= wr8(16r0114, 1);			# two lanes
	# 24 MHz / 2 * 122 = 1464 MHz, / 5 / 2 per lane pixel path
	r |= wr8(16r0301, 5);
	r |= wr8(16r0303, 2);
	r |= wr8(16r0305, 2);
	r |= wr16(16r0306, 122);
	r |= wr8(16r030B, 2);
	r |= wr8(16r030D, 4);
	r |= wr16(16r030E, 300);		# 450 MHz: 900 Mbit/s a lane
	r |= wr8(16r0310, 1);
	r |= wr16(16r0342, Linelen);
	r |= wr16(16r0340, fl);
	r |= wr16(16r0344, 0);
	r |= wr16(16r0346, 0);
	r |= wr16(16r0348, 2*Sw-1);
	r |= wr16(16r034A, 2*Sh-1);
	r |= wr8(16r0900, 1);			# binning
	r |= wr8(16r0901, 16r22);		# two by two
	r |= wr8(16r0902, 8);
	r |= wr8(16r3200, 16r41);		# not CCS: without these no colour
	r |= wr8(16r3201, 16r41);
	r |= wr16(16r0408, 0);
	r |= wr16(16r040A, 0);
	r |= wr16(16r040C, Sw);
	r |= wr16(16r040E, Sh);
	r |= wr16(16r034C, Sw);
	r |= wr16(16r034E, Sh);
	r |= wr8(16r0101, flip);
	l := fl - Exposureoff;
	if(exposure != 0)
		l = exposure;
	r |= wr16(16r0202, l);
	r |= wr16(16r0204, gain);
	return r;
}

sensoroff()
{
	wr8(16r0100, 0);
	unicam("stream off");
	unicam("power off");
	i2cctl = sensorfd = lensfd = nil;
}
