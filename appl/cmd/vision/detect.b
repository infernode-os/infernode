implement Detect;

#
# vision/detect - pictures through vision(4), as records (#1086)
#
#	vision/detect [-m model] [-t thresh] [-c class,...] [-j n] [-v mnt] [file ...]
#
# Each file named, or with none each name read from standard input one
# a line, is written to a session's image; what was found is printed,
# one record a line, the file's name first:
#
#	file=photos/a.jpg class=dog score=0.91 x0=88 y0=140 x1=402 y1=455
#	file=photos/b.jpg					(nothing found)
#
# in the order the files were named. -j runs n sessions at once. -v names
# the server's mount (default /mnt/vision); whichever server is mounted
# there, on this machine or another, does the looking.
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "string.m";
	str: String;
include "visrec.m";
	visrec: Visrec;

Detect: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;
mnt := "/mnt/vision";

Job: adt {
	n:	int;
	file:	string;
};

Done: adt {
	n:	int;
	text:	string;
	err:	string;
};

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	str = load String String->PATH;
	visrec = load Visrec Visrec->PATH;
	if(arg == nil || bufio == nil || str == nil || visrec == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	visrec->init();

	settings := "";
	nj := 1;
	arg->init(argv);
	arg->setusage("vision/detect [-m model] [-t thresh] [-c class,...] [-j n] [-v mnt] [file ...]");
	while((o := arg->opt()) != 0)
		case o {
		'm' =>	settings += "model " + arg->earg() + "\n";
		't' =>	settings += "thresh " + arg->earg() + "\n";
		'c' =>
			(nil, cl) := sys->tokenize(arg->earg(), ",");
			s := "classes";
			for(; cl != nil; cl = tl cl)
				s += " " + hd cl;
			settings += s + "\n";
		'j' =>
			nj = int arg->earg();
			if(nj < 1 || nj > 64)
				arg->usage();
		'v' =>	mnt = arg->earg();
		* =>	arg->usage();
		}
	files := arg->argv();

	jobs := chan of ref Job;
	done := chan of ref Done;
	ready := chan of string;
	for(i := 0; i < nj; i++)
		spawn worker(settings, jobs, done, ready);
	for(i = 0; i < nj; i++)
		if((e := <-ready) != nil)
			fatal(e);

	# the names: fed to the workers as they come, printed in order
	feed := chan of int;
	spawn feeder(files, jobs, nj, feed);
	pending: list of ref Done;
	next := 0;
	total := -1;
	failed := 0;
	while(total < 0 || next < total){
		alt {
		total = <-feed =>
			;
		d := <-done =>
			pending = d :: pending;
			for(;;){
				(found, rest) := take(pending, next);
				if(found == nil)
					break;
				pending = rest;
				if(found.err != nil){
					sys->fprint(stderr, "vision/detect: %s\n", found.err);
					failed++;
				} else
					sys->print("%s", found.text);
				next++;
			}
		}
	}
	if(failed)
		raise sys->sprint("fail:%d not looked at", failed);
}

take(l: list of ref Done, n: int): (ref Done, list of ref Done)
{
	r: list of ref Done;
	found: ref Done;
	for(; l != nil; l = tl l)
		if(found == nil && (hd l).n == n)
			found = hd l;
		else
			r = hd l :: r;
	return (found, r);
}

feeder(files: list of string, jobs: chan of ref Job, nj: int, feed: chan of int)
{
	n := 0;
	if(files != nil){
		for(; files != nil; files = tl files)
			jobs <-= ref Job(n++, hd files);
	} else {
		in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
		while((l := in.gets('\n')) != nil){
			if(l[len l - 1] == '\n')
				l = l[0:len l - 1];
			if(l != nil)
				jobs <-= ref Job(n++, l);
		}
	}
	for(i := 0; i < nj; i++)
		jobs <-= nil;
	feed <-= n;
}

# one session, kept open while there are files: its ctl holds it
worker(settings: string, jobs: chan of ref Job, done: chan of ref Done, ready: chan of string)
{
	cfd := sys->open(mnt + "/clone", Sys->OREAD);
	if(cfd == nil){
		ready <-= sys->sprint("%s/clone: %r", mnt);
		return;
	}
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0){
		ready <-= sys->sprint("%s/clone: %r", mnt);
		return;
	}
	(nil, w) := sys->tokenize(string b[0:n], " \n");
	dir := mnt + "/" + hd w;
	if(settings != nil){
		fd := sys->open(dir + "/ctl", Sys->OWRITE);
		if(fd == nil || sys->write(fd, a := array of byte settings, len a) != len a){
			ready <-= sys->sprint("%s/ctl: %r", dir);
			return;
		}
	}
	ready <-= nil;
	while((j := <-jobs) != nil){
		(text, err) := look(dir, j.file);
		done <-= ref Done(j.n, text, err);
	}
	cfd = nil;
}

look(dir, file: string): (string, string)
{
	(pic, err) := readfile(file);
	if(err != nil)
		return (nil, err);
	fd := sys->open(dir + "/image", Sys->OWRITE);
	if(fd == nil)
		return (nil, sys->sprint("%s/image: %r", dir));
	for(o := 0; o < len pic; o += Sys->ATOMICIO){
		e := o + Sys->ATOMICIO;
		if(e > len pic)
			e = len pic;
		if(sys->write(fd, pic[o:e], e - o) != e - o)
			return (nil, sys->sprint("%s: writing %s/image: %r", file, dir));
	}
	fd = nil;	# closed: looked at
	(found, derr) := readfile(dir + "/detections");
	if(derr != nil)
		return (nil, file + ": " + derr);
	name := visrec->format(("file", file) :: nil);
	text := "";
	(nil, lines) := sys->tokenize(string found, "\n");
	for(; lines != nil; lines = tl lines)
		text += name + " " + hd lines + "\n";
	if(text == nil)
		text = name + "\n";
	return (text, nil);
}

readfile(f: string): (array of byte, string)
{
	fd := sys->open(f, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("%s: %r", f));
	buf := array[0] of byte;
	b := array[Sys->ATOMICIO] of byte;
	for(;;){
		n := sys->read(fd, b, len b);
		if(n < 0)
			return (nil, sys->sprint("%s: %r", f));
		if(n == 0)
			break;
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = b[0:n];
		buf = nb;
	}
	return (buf, nil);
}

fatal(s: string)
{
	sys->fprint(stderr, "vision/detect: %s\n", s);
	raise "fail:" + s;
}
