implement Vid9p;

#
# vid9p - present decoded video frames as a 9P service at /mnt/video/<id>/.
#
# Part of the multiplexed-video bridge (Jira INFR-266). Serves I420 frames
# produced by the host `vdec` decode core (tools/vdec) as a synthetic
# filesystem:
#
#   /mnt/video/0/ctl      write "play" / "pause" / "stop" /
#                               "seek <ms>|+<ms>|-<ms>" / "live"
#                               drive the SERVER-side playhead (transport)
#   /mnt/video/0/fmt      read  "<w> <h> i420 <fps>"
#   /mnt/video/0/frame    read  the I420 stream: frame N is the framesize
#                               bytes at offset N*framesize (framesize =
#                               w*h*3/2), offsets GLOBAL and monotonic.
#                               For a LIVE stream a read past the last
#                               decoded frame BLOCKS until the next frame
#                               arrives (or the stream ends); a read below
#                               the retention window errors "frame expired".
#   /mnt/video/0/status   read  one line of key=value state: geometry,
#                               frames=/first= (retained range), eof=,
#                               state=/pos=/t=/follow= (playhead)
#   /mnt/video/0/layer/   empty as served: what is drawn over the frames is
#                         bound here, a file a layer (#1095, layers(2))
#
# TRANSPORT: the playhead (state=/pos=) lives in this server and is paced
# here at the stream's fps, so every consumer renders the same frame and
# anything that can write a file drives playback — a Matrix video-ctl Tk
# button, a video-pane's keys, an agent, or plain sh:
#     echo pause > /mnt/video/0/ctl
#     echo 'seek +5000' > /mnt/video/0/ctl
#
# RETENTION: a live feed keeps the last -w seconds of frames (default 60,
# 0 = unlimited) as its DVR buffer; the window slides and reads below
# first= error.  Static sources are always fully retained.
#
# THE SOURCE is the command line's, and only the command line's: what a
# server plays is the business of whoever starts it.  ctl once took
# "open <file>", "replay <file>" and "play <cmd> [arg...]" too, the last
# of which ran a host command: but ctl is the file every viewer of the
# feed writes to drive the playhead, and the feed is exported to other
# machines (videnc(1)), so a 9P client given a picture ran commands on
# the host as the emulator's user and read any file the server could
# name.  ctl takes the transport verbs and nothing that names a command
# or a path; a source verb is refused, saying so.
#
# Three source modes share one server:
#   - static  (a file): the whole .y4m is read into the frame buffer and
#     served with random access; reads never block (this is the original,
#     canned path).  A file of more than a gigabyte is not held whole:
#     it is refused, and -r replays one of any length.
#   - live    (-c): a host decoder is spawned through the `os` command
#     and its y4m stdout is parsed incrementally; frames are appended as
#     they decode and blocked readers are woken. This is the INFR-266
#     "swap the y4m-file source for a live vdec spawn" step; the decode core
#     stays protocol-agnostic (see docs/H264-9P-BRIDGE.md).
#   - replay  (-r): a .y4m file served as a live feed, paced at its rate
#     and looped (no host decoder: runs on bare metal too).
#
# Usage (in the Inferno shell):
#   mount {vid9p clip.y4m}                        /mnt/video   # static
#   mount {vid9p -c vdec cam.mp4 --y4m -}         /mnt/video   # live
#   mount {vid9p -w 10 -r clip.y4m}               /mnt/video   # a file, live
#   mount {vid9p -w 120 -c vdec rtsp://cam --y4m -} /mnt/video # 2 min DVR
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

Qroot, Qstream, Qctl, Qfmt, Qframe, Qstatus, Qlayer: con iota;

Maxdim: con 8192;	# a frame's width or height: 100 MB a frame
Maxline: con 4096;	# a y4m header or FRAME line
Maxstatic: con 1<<30;	# a file held whole: the most one array is

tc: chan of ref Tmsg;
srv: ref Styxserver;
stderr: ref Sys->FD;
user := "inferno";

# loaded video state
width, height, fps, framesize, nframes: int;
i420: array of byte;	# backing store; only [0:used] is valid data
used := 0;

# server-side transport (INFR-266 §2.3): the playhead is SERVER state,
# so any writer to ctl — a Tk button, `echo pause > ctl` from sh, an
# agent — drives every viewer of the stream identically.  Viewers read
# state/pos from status and render frame `pos`.
tplaying := 1;
follow := 1;		# streaming source: playhead tracks the live edge
pos := 0;		# playhead frame index
lastadv := 0;		# wall-clock pacing origin (sys->millisec)
tickc: chan of int;

# live retention window: a live feed retains the last `wframes` decoded
# frames (the DVR buffer) instead of growing without bound.  Frame
# indices and byte offsets stay GLOBAL and monotonic — fbase is the
# oldest retained frame; reads below it answer "frame expired".  Static
# sources are always fully retained (wframes = 0 = unlimited).
fbase := 0;		# index of the oldest retained frame
wsecs := 60;		# -w: live retention in seconds; 0 = unlimited
wframes := 0;		# retention in frames (from wsecs once fps is known)
eof := 1;			# static sources are complete from the start
streaming := 0;

# live-stream plumbing (nil for a static source)
framec: chan of array of byte;	# feeder -> serve loop: one decoded frame
eofc: chan of int;		# feeder -> serve loop: stream ended
geoc: chan of (int, int, int);	# feeder -> startstream: first-header geometry
parked: list of ref Tmsg.Read;	# frame reads waiting for more data

# Bounded live storage: a ring of wframes preallocated framesize slots.
# The contiguous i420 buffer (below) is kept for static sources and the
# unbounded (-w 0) case, but a bounded live feed must NOT use it: the
# grow/trim cycle repeatedly allocates window-sized arrays interleaved
# with per-frame ones, and the Dis arena fragments until the heap dies
# (INFR-397: at 720p10 that is ~70 s to "arena heap too large").  The
# ring allocates each uniform slot once and recycles it forever.
ring: array of array of byte;

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

	# A group of its own: when the 9P channel ends, the ticker, a feeder
	# and a host decoder go with the server (killgrp, in serve).
	sys->pctl(Sys->NEWPGRP, nil);

	i420 = array[0] of byte;
	# Allocated up front so the serve loop's alt never selects on a nil
	# channel (a nil channel in alt faults). In static mode nothing is
	# ever sent on them.
	framec = chan of array of byte;
	eofc = chan of int;
	geoc = chan of (int, int, int);

	# args: [-w secs] then "-c <cmd> [arg...]" for a live decoder,
	# "-r <file.y4m>" for a file replayed as a live feed, else an
	# optional static .y4m file.  -w bounds a live feed's retention
	# (DVR) window; 0 = unlimited.
	args = tl args;
	if(args != nil && hd args == "-w") {
		args = tl args;
		if(args != nil) {
			wsecs = int hd args;
			args = tl args;
		}
	}
	if(args != nil && hd args == "-c") {
		cmd := tl args;
		if(cmd == nil)
			sys->fprint(stderr, "vid9p: -c needs a command\n");
		else
			startstream(cmd);
	} else if(args != nil && hd args == "-r") {
		if(tl args == nil)
			sys->fprint(stderr, "vid9p: -r needs a file\n");
		else if((e := startreplay(hd tl args)) != nil)
			sys->fprint(stderr, "vid9p: %s\n", e);
	} else if(args != nil) {
		e: string;
		{
			e = loadvideo(hd args);
		} exception x {
		"*" =>
			e = hd args + ": " + x;	# no room for it: served as no source
		}
		if(e != nil)
			sys->fprint(stderr, "vid9p: %s\n", e);
	}

	# The files are the server's user's.  They were "inferno"'s whoever
	# ran the server, and ctl was 666 to make up for it.
	if((u := readuser()) != nil)
		user = u;
	(tree, treeop) := nametree->start();
	tree.create(big Qroot,   dir(".",      Sys->DMDIR|8r555, Qroot));
	tree.create(big Qroot,   dir("0",      Sys->DMDIR|8r555, Qstream));
	tree.create(big Qstream, dir("ctl",    8r664, Qctl));
	tree.create(big Qstream, dir("fmt",    8r444, Qfmt));
	tree.create(big Qstream, dir("frame",  8r444, Qframe));
	tree.create(big Qstream, dir("status", 8r444, Qstatus));
	# empty as served: where a feed's layers are bound (#1095)
	tree.create(big Qstream, dir("layer",  Sys->DMDIR|8r555, Qlayer));

	(tc, srv) = Styxserver.new(sys->fildes(0), Navigator.new(treeop), big Qroot);
	tickc = chan of int;
	spawn ticker();
	serve(tree);
}

ticker()
{
	for(;;){
		sys->sleep(40);
		tickc <-= 1;
	}
}

# Advance the playhead at the stream's fps against the wall clock.
advance()
{
	if(!tplaying || nframes <= 0){
		lastadv = 0;
		return;
	}
	if(streaming && follow){
		pos = nframes - 1;
		lastadv = 0;
		return;
	}
	f := fps;
	if(f <= 0 || f > 120)
		f = 25;
	now := sys->millisec();
	if(lastadv == 0){
		lastadv = now;
		return;
	}
	steps := (now - lastadv) * f / 1000;
	if(steps <= 0)
		return;
	lastadv += steps * 1000 / f;
	pos += steps;
	if(pos >= nframes){
		if(streaming){
			# replay caught the live edge: follow it again
			pos = nframes - 1;
			follow = 1;
		} else if(eof && nframes > 0)
			pos %= nframes;		# canned clip loops
		else
			pos = nframes - 1;	# ahead of the decoder: hold
	}
	if(pos < fbase)
		pos = fbase;	# the retention window slid past the playhead
}

shutdown(tree: ref Tree)
{
	tree.quit();
	fd := sys->open("/prog/" + string sys->pctl(0, nil) + "/ctl", Sys->OWRITE);
	if(fd != nil)
		sys->fprint(fd, "killgrp");
}

# The serve loop, and what ends with it.  An exception in the loop (the
# heap run out by a frame, a fault a request finds) left the ticker, the
# feeder and a host decoder behind with the frames they held and nobody
# to read them; it ends the server as the channel's end does.
serve(tree: ref Tree)
{
	{
		serve1();
	} exception e {
	"*" =>
		sys->fprint(stderr, "vid9p: %s\n", e);
	}
	shutdown(tree);
}

serve1()
{
	for(;;) alt {
	tmsg := <-tc =>
		# The channel ended (the client hung up, or the mount went):
		# "break" here left only the alt, so vid9p and its ticker went
		# on for ever (and under listen -A, which then ran a
		# connection's command in the listener, no second client was
		# ever served).
		if(tmsg == nil)
			return;
		pick tm := tmsg {
		Readerror =>
			return;
		Open =>
			srv.open(tm);
		Read =>
			# canread holds the count to a message's: a client that is
			# not a mount (listen -A {vid9p ...}) sent a count of
			# ff ff ff ff, and the frame's slice raised.
			(c, err) := srv.canread(tm);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, err));
			} else {
				case int c.path {
				Qroot or Qstream or Qlayer =>
					srv.read(tm);
				Qfmt or Qstatus or Qctl =>
					# One open reads one text: it is made at a read
					# at offset 0 and kept with the fid.  Made at
					# every read and cut at the read's offset, a
					# text that changed between two reads (pos=
					# gaining a digit) gave the second the newer
					# one's tail.
					if(tm.offset == big 0 || c.data == nil){
						case int c.path {
						Qfmt =>	c.data = array of byte fmtstr();
						Qstatus =>	c.data = array of byte statusstr();
						Qctl =>	c.data = array of byte ctlhelp();
						}
					}
					srv.reply(styxservers->readbytes(tm, c.data));
				Qframe =>
					serviceframe(tm);
				* =>
					srv.reply(ref Rmsg.Error(tm.tag, "vid9p: bad path"));
				}
			}
		Write =>
			(c, err) := srv.canwrite(tm);
			if(c == nil){
				srv.reply(ref Rmsg.Error(tm.tag, err));
			} else if(int c.path != Qctl){
				srv.reply(ref Rmsg.Error(tm.tag, Styxservers->Eperm));
			} else if((e := doctl(string tm.data)) != nil){
				# every write was answered as done, the reason for
				# one that was not going to vid9p's standard error
				srv.reply(ref Rmsg.Error(tm.tag, "vid9p: " + e));
			} else {
				srv.reply(ref Rmsg.Write(tm.tag, len tm.data));
			}
		Flush =>
			# The read flushed is forgotten, parked or not.  It stayed
			# parked: the next frame answered a tag its client had
			# given up, and might have used again for another request.
			unpark(tm.oldtag, -1, nil);
			srv.default(tmsg);
		Clunk =>
			unpark(-1, tm.fid, "vid9p: fid clunked");
			srv.default(tmsg);
		Remove =>
			unpark(-1, tm.fid, "vid9p: fid clunked");
			srv.default(tmsg);
		* =>
			srv.default(tmsg);
		}

	fr := <-framec =>
		# A newly decoded frame: first frame fixes geometry.
		if(nframes == 0 && width <= 0)
			; # geometry already set by startstream via geoc
		grow(fr);
		# a playhead following the live edge moves with each frame:
		# left to the ticker (sleep(40), ~46 ms in practice) it
		# stepped ~22 times a second and skipped frames of a 25 fps feed
		advance();
		wakeparked();

	<-eofc =>
		eof = 1;
		streaming = 0;
		wakeparked();

	<-tickc =>
		advance();
	}
}

# Append one frame's I420 payload to the served buffer.  The backing
# array grows by doubling: a per-frame exact-fit reallocate-and-copy is
# O(n^2) in copy volume and its ever-larger allocations fragment the Dis
# arena until even modest streams exhaust the heap.
grow(fr: array of byte)
{
	# Bounded live feed: copy into the ring slot for this frame index.
	# No window-sized allocations ever happen on this path, so the
	# arena stays healthy at any resolution (INFR-397).
	if(streaming && wframes > 0 && framesize > 0 && len fr == framesize){
		if(ring == nil || len ring != wframes)
			ring = array[wframes] of array of byte;
		slot := ring[nframes % wframes];
		if(slot == nil){
			slot = array[framesize] of byte;
			ring[nframes % wframes] = slot;
		}
		slot[0:] = fr;
		nframes++;
		if(nframes - fbase > wframes){
			fbase = nframes - wframes;
			if(pos < fbase)
				pos = fbase;
		}
		used = (nframes - fbase) * framesize;
		return;
	}
	if(used + len fr > len i420){
		ncap := 2 * len i420;
		if(ncap < used + len fr)
			ncap = used + len fr;
		nb := array[ncap] of byte;
		nb[0:] = i420[0:used];
		i420 = nb;
	}
	i420[used:] = fr;
	used += len fr;
	if(framesize > 0)
		nframes = fbase + used / framesize;

	# retention window: drop the oldest frames once the live buffer
	# exceeds it.  Trimmed in quarter-window chunks so the copy cost
	# amortises to a few bytes per byte served.
	if(wframes > 0 && framesize > 0) {
		excess := used/framesize - wframes;
		if(excess >= wframes/4 && excess > 0) {
			nb := array[len i420] of byte;
			nb[0:] = i420[excess*framesize:used];
			i420 = nb;
			used -= excess*framesize;
			fbase += excess;
			if(pos < fbase)
				pos = fbase;
		}
	}
}

# Reply to a frame read now if data (or EOF) allows, else park it until the
# next frame arrives. This unifies both source modes: a static source has
# eof=1 so reads are always answered immediately (past-end -> 0 bytes = EOF);
# a live source parks reads that run ahead of the decoder.
# Answer a frame read if the retained data (or EOF) allows; return 0 to
# park it until the next frame arrives.  Offsets are GLOBAL stream bytes:
# the retained window is [fbase*framesize, fbase*framesize+used); reads
# below it name frames the retention window has dropped.
replyframe(tm: ref Tmsg.Read): int
{
	base := big fbase * big framesize;
	off := tm.offset;
	if(off < base) {
		srv.reply(ref Rmsg.Error(tm.tag, "frame expired"));
		return 1;
	}
	if(off >= base + big used) {
		if(eof) {
			srv.reply(ref Rmsg.Read(tm.tag, array[0] of byte));
			return 1;
		}
		return 0;
	}
	# Ring-backed live feed: serve from the frame's slot, capping the
	# read at the frame boundary (short reads are legal 9P; readers
	# loop).  A slice never spans two ring slots.
	if(ring != nil && framesize > 0) {
		fidx := int (off / big framesize);
		foff := int (off % big framesize);
		fr := ring[fidx % wframes];
		if(fr == nil) {
			srv.reply(ref Rmsg.Error(tm.tag, "vid9p: ring hole"));
			return 1;
		}
		n := tm.count;
		if(foff + n > framesize)
			n = framesize - foff;
		srv.reply(ref Rmsg.Read(tm.tag, fr[foff:foff+n]));
		return 1;
	}
	rel := int (off - base);
	n := tm.count;
	if(rel + n > used)
		n = used - rel;
	srv.reply(ref Rmsg.Read(tm.tag, i420[rel:rel+n]));
	return 1;
}

serviceframe(tm: ref Tmsg.Read)
{
	if(!replyframe(tm))
		parked = tm :: parked;
}

# Take the parked reads of a tag (flushed: no answer is owed) or of a
# fid (clunked under its read: each is answered with why, so its tag is
# not left waiting for ever) off the list.
unpark(tag, fid: int, why: string)
{
	still: list of ref Tmsg.Read;
	for(p := parked; p != nil; p = tl p){
		tm := hd p;
		if(tm.tag == tag)
			continue;
		if(tm.fid == fid){
			srv.reply(ref Rmsg.Error(tm.tag, why));
			continue;
		}
		still = tm :: still;
	}
	parked = still;
}

wakeparked()
{
	still: list of ref Tmsg.Read;
	for(p := parked; p != nil; p = tl p){
		tm := hd p;
		if(!replyframe(tm))
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
	st := "paused";
	if(tplaying)
		st = "playing";
	t := 0;
	f := fps;
	if(f <= 0 || f > 120)
		f = 25;
	t = pos * 1000 / f;
	return sys->sprint("%s w=%d h=%d framesize=%d frames=%d first=%d eof=%d state=%s pos=%d t=%d follow=%d\n",
		src, width, height, framesize, nframes, fbase, eof, st, pos, t, follow);
}

ctlhelp(): string
{
	return "play\npause\nstop\nseek <ms>|+<ms>|-<ms>\nlive\n";
}

# A whole number of at most nine digits: a seek's milliseconds.
isms(a: string): int
{
	if(len a == 0 || len a > 9)
		return 0;
	for(i := 0; i < len a; i++)
		if(a[i] < '0' || a[i] > '9')
			return 0;
	return 1;
}

# One ctl write: a transport verb, or the reason it is refused.
doctl(s: string): string
{
	(n, toks) := sys->tokenize(s, " \t\r\n");
	if(toks == nil)
		return "empty command";
	case hd toks {
	"open" or "replay" =>
		return "the source is set when vid9p starts";
	"play" =>
		if(n != 1)
			return "the source is set when vid9p starts: play takes no argument";
		tplaying = 1;
		lastadv = 0;
	"pause" =>
		if(n != 1)
			return "pause takes no argument";
		tplaying = 0;
	"stop" =>
		if(n != 1)
			return "stop takes no argument";
		if(streaming){
			# a live feed "stops" back to the live edge
			follow = 1;
			tplaying = 1;
		} else {
			tplaying = 0;
			pos = 0;
		}
		lastadv = 0;
	"live" =>
		if(n != 1)
			return "live takes no argument";
		follow = 1;
		tplaying = 1;
		lastadv = 0;
	"seek" =>
		if(n != 2)
			return "seek <ms>|+<ms>|-<ms>";
		a := hd tl toks;
		rel := 0;
		sign := big 1;
		if(len a > 0 && a[0] == '+'){
			rel = 1;
			a = a[1:];
		} else if(len a > 0 && a[0] == '-'){
			rel = 1;
			sign = big -1;
			a = a[1:];
		}
		if(!isms(a))
			return "seek <ms>|+<ms>|-<ms>";
		f := fps;
		if(f <= 0 || f > 120)
			f = 25;
		# in 64 bits and held to the frames there are: the product
		# wrapped an int for a seek past 2^31/fps ms
		d := sign * big a * big f / big 1000;
		if(rel)
			d += big pos;
		if(d < big fbase)
			d = big fbase;
		if(d > big nframes)
			d = big nframes;
		pos = int d;
		follow = 0;
		if(nframes > 0 && pos >= nframes-1){
			pos = nframes - 1;
			if(streaming)
				follow = 1;
		}
		lastadv = 0;
	* =>
		return "unknown command: " + hd toks;
	}
	return nil;
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
	streamfrom(fd);
}

# Replay a .y4m file as a live feed: its frames at its rate, from the
# first again after the last, numbered on without end.  A camera's
# stand-in where there is no camera and no host decoder (a bare-metal
# board): what reads it sees a live feed, as from camsrv or a decoder.
startreplay(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open %s: %r", path);
	fds := array[2] of ref Sys->FD;
	if(sys->pipe(fds) < 0)
		return sys->sprint("pipe: %r");
	spawn pacer(fd, fds[1]);
	fds[1] = nil;
	streamfrom(fds[0]);
	if(width <= 0)
		return sys->sprint("%s: not a YUV4MPEG2 stream", path);
	return nil;
}

# Copy a y4m file into wfd as one endless stream: the header once, then
# its frames, each when it is due at the header's rate, the first again
# after the last.  Ends when the reader goes or the file has no frame.
pacer(fd, wfd: ref Sys->FD)
{
	(hdr, buf) := readline(fd, array[0] of byte);
	if(hdr == nil)
		return;
	(w, h, f) := parsehdr(hdr);
	if(w <= 0 || h <= 0)
		return;
	if(f <= 0 || f > 120)
		f = 25;
	fsz := w*h + 2*(w/2)*(h/2);
	start := big len hdr + big 1;	# the first frame's offset
	if(writeall(wfd, cat(hdr, array[] of {byte '\n'})) < 0)
		return;
	mark := array of byte "FRAME\n";
	t0 := sys->millisec();
	k := 0;
	for(;;){
		(line, r1) := readline(fd, buf);
		payload: array of byte;
		if(line != nil)
			(payload, buf) = readn(fd, r1, fsz);
		if(payload == nil){
			# the end: the first frame again
			if(k == 0)
				return;
			sys->seek(fd, start, Sys->SEEKSTART);
			buf = array[0] of byte;
			(line, r1) = readline(fd, buf);
			if(line == nil)
				return;
			(payload, buf) = readn(fd, r1, fsz);
			if(payload == nil)
				return;
		}
		due := t0 + k*1000/f;
		if((d := due - sys->millisec()) > 0)
			sys->sleep(d);
		if(writeall(wfd, mark) < 0 || writeall(wfd, payload) < 0)
			return;
		k++;
	}
}

writeall(fd: ref Sys->FD, b: array of byte): int
{
	for(o := 0; o < len b; ){
		n := sys->write(fd, b[o:], len b - o);
		if(n <= 0)
			return -1;
		o += n;
	}
	return len b;
}

# Serve the y4m stream read from fd as a live feed.
streamfrom(fd: ref Sys->FD)
{
	# reset served state for the new source
	i420 = array[0] of byte;
	ring = nil;
	used = 0;
	width = height = fps = framesize = nframes = 0;
	eof = 0;
	streaming = 1;
	tplaying = 1;
	follow = 1;
	pos = 0;
	fbase = 0;
	wframes = 0;
	lastadv = 0;
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
	if(wsecs > 0){
		f2 := fps;
		if(f2 <= 0 || f2 > 120)
			f2 = 25;
		wframes = wsecs * f2;
		if(wframes < 8)
			wframes = 8;
	}
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
	# With no /dev/null the command is not run: it went on with the 9P
	# channel as its standard input.
	nullfd := sys->open("/dev/null", Sys->OREAD);
	if(nullfd == nil || sys->dup(nullfd.fd, 0) < 0){
		sys->fprint(stderr, "vid9p: /dev/null: %r: the decoder is not started\n");
		return;
	}
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
# Whatever ends it, the server is told: an exception here (no room for a
# frame) left startstream waiting for a geometry, or the readers parked
# at the live edge waiting for a frame, for ever.
feeder(fd: ref Sys->FD)
{
	told := array[1] of {0};
	{
		feed(fd, told);
	} exception e {
	"*" =>
		sys->fprint(stderr, "vid9p: source: %s\n", e);
	}
	if(!told[0])
		geoc <-= (0, 0, 0);
	eofc <-= 1;
}

feed(fd: ref Sys->FD, told: array of int)
{
	buf := array[0] of byte;
	# read the header line
	(hdr, rest) := readline(fd, buf);
	if(hdr == nil)
		return;
	(w, h, f) := parsehdr(hdr);
	if(w <= 0 || h <= 0)
		return;
	told[0] = 1;
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
}

# Read up to and including the next '\n' from buf+fd; return (line-without-nl,
# leftover-after-nl). Returns (nil, ...) at EOF with no data.
readline(fd: ref Sys->FD, buf: array of byte): (array of byte, array of byte)
{
	for(;;){
		nl := findnl(buf, 0);
		if(nl < len buf)
			return (buf[0:nl], buf[nl+1:]);
		# a header or FRAME line is tens of bytes: a source with no
		# newline in it was gathered whole, copied again at each read
		if(len buf > Maxline)
			return (nil, nil);
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
# the stream ends first.  The rest of the frame is read straight into its
# own array: growing buf a pipe read at a time copied everything read so
# far on every read, O(n^2) in the frame size (29 MB for a 720p frame).
readn(fd: ref Sys->FD, buf: array of byte, n: int): (array of byte, array of byte)
{
	if(len buf >= n)
		return (buf[0:n], buf[n:]);
	fr := array[n] of byte;
	fr[0:] = buf;
	got := len buf;
	while(got < n){
		m := sys->read(fd, fr[got:], n - got);
		if(m <= 0)
			return (nil, nil);
		got += m;
	}
	return (fr, array[0] of byte);
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
		'W' => w = dim(t[1:]);
		'H' => h = dim(t[1:]);
		'F' => f = dim(t[1:]);	# "25:1" -> 25
		}
	}
	# A size is the source's word (a decoder passes on what its media
	# says).  65536 by 65536 made a frame size of -2^31: a negative
	# index in the static loader, a negative slice in the feeder.
	if(w > Maxdim || h > Maxdim)
		return (0, 0, 0);
	return (w, h, f);
}

# The digits a header field begins with, as a number; 0 if there are
# none or more than a size or rate has.
dim(s: string): int
{
	n := 0;
	for(i := 0; i < len s && s[i] >= '0' && s[i] <= '9'; i++){
		if(i >= 6)
			return 0;
		n = n*10 + (s[i] - '0');
	}
	return n;
}

# ── static source ───────────────────────────────────────────

# Parse a whole YUV4MPEG2 file into the flat I420 frame buffer.
loadvideo(path: string): string
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return sys->sprint("open %s: %r", path);
	# The whole file is held: one past what an array can be is refused
	# by its length (cut to an int, a file past 2GB was a negative size
	# and an exception before the mount was served; past 4GB, its start).
	(ok, d) := sys->fstat(fd);
	if(ok >= 0 && d.length > big Maxstatic)
		return sys->sprint("%s: %bd bytes is more than is held whole (replay it: -r)", path, d.length);
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
	width = w; height = h; fps = f; framesize = fsz; nframes = n;
	i420 = nb; used = len nb;
	tplaying = 1;
	follow = 0;
	pos = 0;
	fbase = 0;
	wframes = 0;	# static sources are always fully retained
	lastadv = 0;
	return nil;
}

# Read a whole file.  Allocate once from the stat length — an append loop
# that reallocates and copies the accumulated buffer per read is O(n^2)
# and fragments the arena on multi-megabyte .y4m files.  The post-stat
# doubling loop only runs if the file grew, or for stat-less sources.
readall(fd: ref Sys->FD): array of byte
{
	size := 0;
	(ok, d) := sys->fstat(fd);
	if(ok >= 0 && d.length > big 0 && d.length <= big Maxstatic)
		size = int d.length;
	buf := array[size] of byte;
	n := 0;
	while(n < size){
		r := sys->read(fd, buf[n:], size-n);
		if(r <= 0)
			return buf[0:n];
		n += r;
	}
	tmp := array[32*1024] of byte;
	for(;;){
		r := sys->read(fd, tmp, len tmp);
		if(r <= 0)
			break;
		nbuf := array[n + r] of byte;
		nbuf[0:] = buf[0:n];
		nbuf[n:] = tmp[0:r];
		buf = nbuf;
		n += r;
	}
	return buf[0:n];
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
