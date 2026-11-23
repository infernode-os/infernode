implement Wikifs;

include "sys.m";
	sys: Sys;
include "draw.m";
include "styx.m";
	styx: Styx;
	Rmsg, Tmsg: import styx;
include "styxservers.m";
	styxservers: Styxservers;
	Styxserver, Fid, Navigator, Navop, readbytes: import styxservers;
	Enotdir, Enotfound: import Styxservers;
	nametree: Nametree;
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "wiki.m";
	wiki: Wiki;
	Map, Wpage, Wdoc, Whist, Tpage, Toldpage, Thistory, Tdiff, Tedit, Twerror, Maxpages: import wiki;
include "string.m";
	str: String;
include "arg.m";
	arg: Arg;
include "daytime.m";
	daytime: Daytime;

Wikifs: module {
	init: fn(nil: ref Draw->Context, argv: list of string);
};

badmodule(p: string)
{
	sys->fprint(sys->fildes(2), "wikifs: cannot load %s: %r\n", p);
	raise "fail:bad module";
}

user := "wikifs";
qidseq := 1;
srv: ref Styxserver;

# A request that takes work (a page read, made or stat'ed) is given to
# a worker, which gives its answer back to the serve loop: the serve
# loop alone writes to the connection.  (The workers wrote their own
# replies.  Two of more than 32K at once could mix on a pipe, which
# takes that much whole and no more; and a flush killed the worker it
# named, wherever it was, in the middle of a reply's write as well,
# after which the connection held half a message.)
Worker: adt {
	pid:	int;
	c:	chan of (ref Tmsg, ref Fid);
	tag:	int;	# of the request it has
	flushed:	int;	# that request has been flushed: its answer is not sent
};
idle: list of ref Worker;
nidle: int;
busy: list of ref Worker;
nworkers: int;
workdone: chan of (ref Worker, ref Rmsg);
commitc: chan of (string, chan of (int, string));	# a page written to new, to the committer

filelist := array[] of {
	"index.html",
	"index.txt",
	"current",
	"history.html",
	"history.txt",
	"diff.html",
	"edit.html",
	"werror.html",
	"werror.txt",
};

Qindexhtml,
	Qindextxt,
	Qraw,
	Qhistoryhtml,
	Qhistorytxt,
	Qdiffhtml,
	Qedithtml,
	Qwerrorhtml,
	Qwerrortxt,
	Nfile: con iota;

# qids: <8-bit type><16-bit page number><16-bit page version><8-bit file index>.
Derror, Droot, D1st, D2nd, Fnew, Fmap, F1st, F2nd: con iota;

Maxreqidle: con 3;
Maxworkers: con 64;	# requests being worked on at once (httpd has at most 64 connections)
ENDWAIT: con 10*1000;	# ms the work under way is given to finish when the connection has gone
Maxnew: con 1024*1024;	# bytes of a page written to new

# Each field in its own bits: a page number past 16 bits ran into the
# type, so /262144 was page 0's index.html, a file at the root.
mkqid(typ, num, vers, file: int): big
{
	return  ((big (typ & 16rFF))<< 40) |  ((big (num & 16rFFFF))<<24) | big ((vers & 16rFFFF)<<8) | big (file & 16rFF);
}

qidtype(path: big): int
{
	return int ((path>>40) & big 16rFF);
}

qidnum(path:big): int
{
	return int((path>>24) & big 16rFFFF);
}

qidvers(path:big): int
{
	return int((path>>8) & big 16rFFFF);
}

qidfile(path:big): int
{
	return int(path & big 16rFF);
}

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	arg = load Arg Arg->PATH;
	daytime = load Daytime Daytime->PATH;
	wiki = load Wiki Wiki->PATH;
	wiki->init(bufio);
	styx = load Styx Styx->PATH;
	if (styx == nil)
		badmodule(Styx->PATH);
	styx->init();
	styxservers = load Styxservers Styxservers->PATH;
	if (styxservers == nil)
		badmodule(Styxservers->PATH);
	styxservers->init(styx);
	arg->init(args);
	while((c := arg->opt()) != 0)
		case c {
		'd' =>
			wiki->setwikidir(arg->earg());
		}
	args = arg->argv();

	# a group of its own: its processes end with its connection (serve)
	sys->pctl(Sys->FORKNS|Sys->NEWPGRP, nil);

	navops := chan of ref Navop;
	spawn navigator(navops);
	tchan: chan of ref Tmsg;
	(tchan, srv) = Styxserver.new(sys->fildes(0), Navigator.new(navops), mkqid(Droot, 0, 0, 0));
	srv.msize = 65536 + Styx->IOHDRSZ;	# a page, its history and diffs in few reads
	spawn serve(tchan, navops);
}

serve(tchan: chan of ref Tmsg, navops: chan of ref Navop)
{
	workdone = chan of (ref Worker, ref Rmsg);
	commitc = chan of (string, chan of (int, string));
	spawn committer();

Serve:
	for(;;)alt{
	gm := <-tchan =>
		if(gm == nil)
			break Serve;
		{
			pick m := gm {
			Readerror =>
				sys->fprint(sys->fildes(2), "wikifs: fatal read error: %s\n", m.error);
				break Serve;
			Read =>
				(fid, err) := srv.canread(m);
				if(err != nil)
					srv.reply(ref Rmsg.Error(m.tag, err));
				else if(fid.qtype & Sys->QTDIR)
					srv.read(m);
				else
					request(m, fid);
			Write =>
				(fid, err) := srv.canwrite(m);
				if(err != nil)
					srv.reply(ref Rmsg.Error(m.tag, err));
				else
					request(m, fid);
			Flush =>
				# The request flushed is answered no more: its worker
				# goes on to the end of what it is doing (a page's
				# cache or its history half made would be the next
				# request's), and what it then says is dropped.  (The
				# worker was killed; and a request handed over but
				# not yet noted was not found, so it was answered
				# after its flush.)
				for(l := busy; l != nil; l = tl l)
					if((hd l).tag == m.oldtag && !(hd l).flushed)
						(hd l).flushed = 1;
				srv.reply(ref Rmsg.Flush(m.tag));
			Stat =>
				# (a stat of a fid not in use was answered and then the
				# loop left: the server gone for one bad message)
				c := srv.getfid(m.fid);
				if(c == nil)
					srv.reply(ref Rmsg.Error(m.tag, "bad fid"));
				else
					request(m, c);
			* =>
				srv.default(gm);
			}
		} exception {
		"*" =>
			# a reply to a connection that has gone (a write on a
			# closed pipe is an exception): its end is on its way
			;
		}
	(w, r) := <-workdone =>
		busy = without(busy, w);
		if(!w.flushed){
			{
				srv.reply(r);
			} exception {
			"*" =>
				;
			}
		}
		w.flushed = 0;
		if(nidle >= Maxreqidle){
			w.c <-= (nil, nil);
			nworkers--;
		}else{
			idle = w :: idle;
			nidle++;
		}
	}
	# The connection has gone, and with it everything that served it,
	# each told to go and none waited for without end: the workers
	# with nothing to do; those with work when it is done (so a page
	# being written is whole), or ten seconds from now; then the
	# committer and the navigator.  Whatever is left after that (a
	# worker that did not finish, the connection's reader) is killed
	# with the group.  (Idle workers, the flush process and the
	# committer stayed for ever; then the committer and the navigator
	# were each waited for with no limit before anything was killed.)
	for(; idle != nil; idle = tl idle)
		(hd idle).c <-= (nil, nil);
	(tick, tpid) := timer(ENDWAIT);
Drain:
	while(busy != nil)
		alt{
		(w, nil) := <-workdone =>
			busy = without(busy, w);
			w.c <-= (nil, nil);
		<-tick =>
			break Drain;
		}
	alt{
	commitc <-= (nil, nil) =>
		;
	<-tick =>
		;
	}
	alt{
	navops <-= nil =>
		;
	* =>
		;
	}
	kill(tpid, "kill");
	kill(sys->pctl(0, nil), "killgrp");
}

without(l: list of ref Worker, w: ref Worker): list of ref Worker
{
	r: list of ref Worker;
	for(; l != nil; l = tl l)
		if(hd l != w)
			r = hd l :: r;
	return r;
}

timer(ms: int): (chan of int, int)
{
	c := chan[1] of int;
	pidc := chan of int;
	spawn sleeper(ms, c, pidc);
	return (c, <-pidc);
}

sleeper(ms: int, c, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	sys->sleep(ms);
	c <-= 1;
}

# The one process that writes pages.  An edit says which version it was
# made from, and is a conflict if the page is no longer that one: the
# compare and the write are one step only because no other write runs
# between them, and the lock wiki.b takes round them is a file made for
# exclusive use, which the emulator's host file system does not have.
# Not a lock held by the worker: a worker whose request is flushed, or
# whose connection has gone, may never come back for it.  The answer
# waits in the channel for such a worker.
committer()
{
	for(;;){
		(file, rc) := <-commitc;
		if(rc == nil)
			break;
		{
			rc <-= newfile(file);
		} exception e {
		"*" =>
			rc <-= (-1, "wikifs: " + e);
		}
	}
}

commit(file: string): (int, string)
{
	rc := chan[1] of (int, string);
	commitc <-= (file, rc);
	return <-rc;
}

request(m: ref Styx->Tmsg, fid: ref Fid)
{
	w: ref Worker;
	if(idle != nil){
		(w, idle) = (hd idle, tl idle);
		nidle--;
	}else if(nworkers >= Maxworkers){
		srv.reply(ref Rmsg.Error(m.tag, "wikifs: too many requests at once"));
		return;
	}else{
		w = ref Worker(0, chan of (ref Tmsg, ref Fid), 0, 0);
		pidc := chan of int;
		spawn requestproc(w, pidc);
		w.pid = <-pidc;
		nworkers++;
	}
	# noted before it is handed over: a flush that comes next finds it
	w.tag = m.tag;
	w.flushed = 0;
	busy = w :: busy;
	w.c <-= (m, fid);
}

requestproc(w: ref Worker, pidc: chan of int)
{
	pidc <-= sys->pctl(0, nil);
	for(;;){
		(gm, fid) := <-w.c;
		if(gm == nil)
			break;
		r: ref Rmsg;
		{
			r = work(gm, fid);
		} exception e {
		"*" =>
			r = ref Rmsg.Error(gm.tag, "wikifs: " + e);
		}
		workdone <-= (w, r);
	}
}

# A request's answer
work(gm: ref Tmsg, fid: ref Fid): ref Rmsg
{
	path := fid.path;
	pick m := gm {
	Read =>
		case qidtype(path) {
		Fnew =>
			if(fid.data != nil)
				return readbytes(m, fid.data);
			return ref Rmsg.Error(m.tag, "protocol botch");
		Fmap =>
			return readbytes(m, fid.data);
		F1st or F2nd =>
			if(fid.data == nil)
				fid.data = loadpath(path);
			return readbytes(m, fid.data);
		}
		return ref Rmsg.Error(m.tag, "what was i thinking1?");
	Write =>
		case qidtype(path) {
		Fnew =>
			if(len fid.data + len m.data > Maxnew){
				fid.data = nil;
				return ref Rmsg.Error(m.tag, sys->sprint("page too long: at most %d bytes", Maxnew));
			}
			if(len m.data != 0){
				n := len fid.data;
				fid.data = (array[len fid.data + len m.data] of byte)[0:] = fid.data;
				p := fid.data[n:];
				p[0:] = m.data;
				return ref Rmsg.Write(m.tag, len m.data);
			}
			if(len fid.data != 0) {
				(n, err) := commit(string fid.data);
				if(n < 0){
					# why: a title that names no page, a full wiki
					fid.data = nil;
					if(err == nil)
						err = "newfile failed";
					return ref Rmsg.Error(m.tag, err);
				}
				# as Plan 9's: a write refused (an update
				# conflict) still names the page, so the
				# writer can be shown its werror.html
				name := wiki->numtoname(n);
				for(i:=0;i<len name;i++)
					if(name[i] == ' ')
						name[i] = '_';
				fid.data = array of byte name;
				if(err != nil)
					return ref Rmsg.Error(m.tag, err);
				return ref Rmsg.Write(m.tag, 0);
			}
			return ref Rmsg.Error(m.tag, "protocol botch");
		Fmap =>
			n := wiki->nametonum(string m.data);
			if(n < 0)
				return ref Rmsg.Error(m.tag, "name not found");
			fid.data = m.data;
			return ref Rmsg.Write(m.tag, len m.data);
		}
		return ref Rmsg.Error(m.tag, "what was i thinking2?");
	Stat =>
		# the length is important because it is used by httpd for content-length
		# so we have to read and generate the content and calculate it's length
		# we can then stash it in the fid, or a cache of qid if we wanted.
		# httpd also uses mtime for last-modified
		(d, err) := dirgen(path);
		if(d == nil)
			return ref Rmsg.Error(m.tag, err);
		case qidtype(path) {
		F1st or F2nd =>
			if(fid.data == nil)
				fid.data = loadpath(path);
			d.length = big len fid.data;
		}
		return ref Rmsg.Stat(m.tag, *d);
	}
	return ref Rmsg.Error(gm.tag, "oh dear");
}

# a page written to new: its number, and why its write was refused
# (-1: it names no page, or none could be made, and why)
newfile(file: string): (int, string)
{
	w: ref Whist;
	t, n: int;
	title, author, comment: string;

	fd := bufio->sopen(file);
	if((title = fd.gets('\n')) == nil)
		return (-1, "no title");
	w = ref Whist;
	w.title = chomp(title);
	author = "me";
	t = 0;
	while((s := fd.gets('\n')) != nil && s != "\n"){
		# (a last line of one letter and no newline was sliced [1:0])
		s = chomp(s);
		if(s == nil)
			continue;
		case s[0] {
		'A' =>
			author = s[1:];
		'D' =>
			t = int s[1:];
		'C' =>
			comment = s[1:];
		}
	}
	w.doc = array[1] of ref Wdoc;
	w.doc[0] = ref Wdoc(author, comment, 0, daytime->now(), nil);
	
	w.doc[0].wtxt = wiki->Brdpage(fd, wiki->Srdwline);
	if(w.doc[0].wtxt == nil)
		return (-1, "a page with no text");
	w.ndoc = 1;
	n = wiki->allocnum(w.title, 0);
	if(n < 0)
		return (-1, sys->sprint("%r"));
	s = wiki->doctext(w.doc[0]);
	if(wiki->writepage(n, t, s, w.title) < 0)
		return (n, sys->sprint("%r"));
	return (n, nil);
}

chomp(s: string): string
{
	if(s != nil && s[len s - 1] == '\n')
		return s[0:len s - 1];
	return s;
}

# A page's number as a name: -1 if the name is not digits, -2 if it is
# and names no page a qid can number
pagenum(s: string): int
{
	if(s == nil)
		return -1;
	n := 0;
	for(i := 0; i < len s; i++){
		if(s[i] < '0' || s[i] > '9')
			return -1;
		if(n < Maxpages)
			n = n*10 + s[i] - '0';
	}
	if(n >= Maxpages)
		return -2;
	return n;
}

loadpath(path: big): array of byte
{
	s : string;
	wh : ref Whist;
	if(qidtype(path) == F2nd)
		wh = wiki->gethistory(qidnum(path));
	else {
		case qidfile(path) {
		Qhistoryhtml or Qhistorytxt or Qdiffhtml =>
			wh = wiki->gethistory(qidnum(path));
		* =>
			wh = wiki->getcurrent(qidnum(path));
		}
	}
	if(wh == nil)
		return nil;
	t := qidtype(path);
	if(t == F1st)
		t = Tpage;
	else
		t = Toldpage;
	n := qidvers(path);
	if(n >= wh.ndoc)
		return nil;	# a history that has lost versions since the walk
	case qidfile(path) {
	Qindexhtml =>
		s = wiki->tohtml(wh, wh.doc[n], t);
	Qindextxt =>
		s = wiki->totext(wh, wh.doc[n], t);
	Qraw =>
		s = wh.title + "\n" + wiki->doctext(wh.doc[n]);
	Qhistoryhtml =>
		s = wiki->tohtml(wh, wh.doc[n], Thistory);
	Qhistorytxt =>
		s = wiki->totext(wh, wh.doc[n], Thistory);
	Qdiffhtml =>
		s = wiki->tohtml(wh, wh.doc[n], Tdiff);
	Qedithtml =>
		s = wiki->tohtml(wh, wh.doc[n], Tedit);
	Qwerrorhtml =>
		s = wiki->tohtml(wh, wh.doc[n], Twerror);
	* =>
		s = "internal error";
	}
	return array of byte s;
}

qid(path: big): Sys->Qid
{
	return dirgen(path).t0.qid;
}

navigator(navops: chan of ref Navop)
{
	while((m := <-navops) != nil){
		# whatever goes wrong with one request is that request's error:
		# every walk and stat waits for this process
		{
			navop(m);
		} exception e {
		"*" =>
			sys->fprint(sys->fildes(2), "wikifs: %s\n", e);
			m.reply <-= (nil, "wikifs: " + e);
		}
	}
}

navop(m: ref Navop)
{
	wiki->currentmap(0);
	path := big 0;
	pick n := m {
	Stat =>
		# stats from here return 0 length 
		# (used by styxservers' attach, canopen, cancreate, walk)
		# but for stat from client the above stat, not this one, is used.
		n.reply <-= dirgen(n.path);
	Walk =>
		name := n.name;
		case qidtype(m.path) {
		Droot =>
			case name {
			".." =>
				path = m.path;
			"new" =>
				path = mkqid(Fnew, 0, 0, 0);
			"map" =>
				path = mkqid(Fmap, 0, 0, 0);
			* =>
				# A number is a page's if there is that page: any
				# integer walked (to an empty page, each taking a
				# place in the cache), and one past 65535 to
				# another page's files.
				num := pagenum(name);
				if(num == -1)
					num = wiki->nametonum(name);
				if(num >= 0 && wiki->numtoname(num) != nil && wiki->getcurrent(num) != nil)
					path = mkqid(D1st, num, 0, 0);
			}
		D1st =>
			case name{
			".." =>
				path = mkqid(Droot, 0, 0, 0);
			* =>
				(num, q) := str->toint(name, 10);
				if(q == nil){
					wh := wiki->gethistory(qidnum(m.path));
					if(wh == nil)
						break;
					for(i:=0;i<wh.ndoc && i < 16r10000;i++)
						if(wh.doc[i].time==num){
							path = mkqid(D2nd, qidnum(m.path), i, 0);
							break;
						}
				}else{
					for(i:=0;i<len filelist; i++)
						if(name == filelist[i]){
							path = mkqid(F1st, qidnum(m.path), 0, i);
							break;
						}
				}
			}
		D2nd =>
			case name {
			".." =>
				path = mkqid(D1st, qidnum(m.path), 0, 0);
			* =>
				for(i:=0;i<=Qraw;i++){
					if(name==filelist[i]){
						path = mkqid(F2nd, qidnum(m.path), qidvers(m.path), i);
						break;
					}
				}
			}
		}
		n.reply <-= dirgen(path);
	Readdir =>
		d: array of big;
		wh: ref Whist;
		case qidtype(m.path){
		Droot =>
			map := wiki->map;
			if(map == nil)
				map = ref Map;
			d = array[2+map.nel] of big;
			d[0] = mkqid(Fnew, 0, 0, 0);
			d[1] = mkqid(Fmap, 0, 0, 0);
			for(i:=0;i<map.nel;i++)
				d[i+2] = mkqid(D1st, map.el[i].n, 0, 0);
		D1st =>
			nfiles := Nfile;
			wh = wiki->gethistory(qidnum(m.path));
			if(wh != nil)
				nfiles += wh.ndoc;
			if(nfiles > Nfile + 16r10000)
				nfiles = Nfile + 16r10000;	# the versions a qid can number
			d = array[nfiles] of big;
			for(i:=0; i<Nfile; i++)
				d[i] = mkqid(F1st, qidnum(m.path), 0, i);
			for(; i<nfiles; i++)
				d[i] = mkqid(D2nd, qidnum(m.path), i - Nfile, 0);
		D2nd =>
			d = array[Qraw+1] of big;
			for(i:=0; i<=Qraw; i++)
				d[i] = mkqid(F2nd, qidnum(m.path), qidvers(m.path), i);
		}
		if(d == nil){
			n.reply <-= (nil, Enotdir);
			break;
		}
		for (i := n.offset; i < len d; i++){
			(dir, nil) := dirgen(d[i]);
			if(dir != nil)	# (a nil one ends the listing)
				n.reply <-= (dir, nil);
		}
		n.reply <-= (nil, nil);
	}
}

# dirgen has all the info needed to generate the correct info
# using gethistory or getcurrent.
dirgen(path: big): (ref Sys->Dir, string)
{
	d := ref sys->zerodir;
	d.qid.path = path;
	wh : ref Whist;

	vers := qidvers(path);
	case qidtype(path) {
	Droot =>
		d.name = ".";
		d.mode = 8r555|Sys->DMDIR;
	D1st =>
		d.name = wiki->numtoname(qidnum(path));
		for(i:=0;i<len d.name;i++)
			if(d.name[i] == ' ')
				d.name[i] = '_';
		d.mode = 8r555|Sys->DMDIR;
		wh = wiki->getcurrent(qidnum(path));
	D2nd =>
		wh = wiki->gethistory(qidnum(path));
		if(wh == nil || vers >= wh.ndoc)
			return (nil, Enotfound);
		d.name = sys->sprint("%ud", wh.doc[vers].time);
		d.mode = 8r555|Sys->DMDIR;
	Fmap =>
		d.name = "map";
		d.mode = 8r666;
	Fnew =>
		d.name = "new";
		d.mode = 8r666;
	F1st =>
		d.name = filelist[qidfile(path)];
		d.mode = 8r444;
		wh = wiki->getcurrent(qidnum(path));
	F2nd =>
		d.name = filelist[qidfile(path)];
		d.mode = 8r444;
		wh = wiki->gethistory(qidnum(path));
	* =>
		return (nil, Enotfound);
	}
	if(d.mode & Sys->DMDIR)
		d.qid.qtype = Sys->QTDIR;
	d.uid = user;
	d.gid = user;
	# (a file of a title and nothing else was a history of no versions,
	# indexed here: the navigator ended, and the wiki with it)
	if(wh != nil && vers < wh.ndoc)
		d.mtime = d.atime = wh.doc[vers].time;
	else
		d.mtime = d.atime = daytime->now();
	d.qid.vers = d.mtime;
	if(qidfile(path) == Qedithtml)
		d.mtime = daytime->now();
	return (d, nil);
}

kill(pid: int, note: string): int
{
	fd := sys->open("/prog/"+string pid+"/ctl", Sys->OWRITE);
	if(fd == nil || sys->fprint(fd, "%s", note) < 0)
		return -1;
	return 0;
}
