implement ToolVision;

#
# vision - what is in a picture, from vision(4) at /mnt/vision (#1086).
#
# Writes the picture to a session of whatever server is mounted at
# /mnt/vision (this machine's, or another's) and returns what was found,
# one record a line:
#
#	class=dog score=0.86 x0=133 y0=207 x1=326 y1=543
#
# It sends the picture nowhere else: there is no cloud backend and no
# fallback to one. What the tool reaches is what the agent's name space
# has at /mnt/vision, granted to this tool alone (nsconstruct), never a
# camera's frames (/mnt/video).
#
# An agent's grant is the models and one session's image, detections
# and status, the session made for it: no clone, no ctl of the server's
# or the session's.  So the classes and the score asked for are applied
# here, to what comes back; where the whole mount is there (the tool run
# by hand) a session is made and its ctl told the score as well.  One
# picture at a time: a granted session is the only one its holder has.
#
# Usage:
#   vision [-c class,...] [-t thresh] imagepath
#

include "sys.m";
	sys: Sys;

include "draw.m";

include "string.m";
	str: String;

include "../tool.m";

ToolVision: module {
	init:	fn(): string;
	name:	fn(): string;
	doc:	fn(): string;
	exec:	fn(args: string): string;
	schema:	fn(): string;
};

VISION: con "/mnt/vision";
Maximage: con 64*1024*1024;
Usage: con "error: usage: vision [-c class,...] [-t thresh] imagepath";

lock: chan of int;	# one picture at a time

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
	str = load String String->PATH;
	if(str == nil)
		return sys->sprint("cannot load %s: %r", String->PATH);
	if(lock == nil)
		lock = chan[1] of int;
	return nil;
}

name(): string
{
	return "vision";
}

doc(): string
{
	return "Vision - What is in a picture.\n\n" +
		"Usage:\n" +
		"  vision [-c class,...] [-t thresh] imagepath\n\n" +
		"Returns one line for each thing found, best first:\n" +
		"  class=dog score=0.86 x0=133 y0=207 x1=326 y1=543\n" +
		"x0 y0 x1 y1 are its box in the picture's pixels. Nothing found is\n" +
		"said so. -c keeps only the classes named; -t is the lowest score\n" +
		"kept (0 to 1, 0.30 unless given).\n\n" +
		"Examples:\n" +
		"  vision /tmp/photo.jpg\n" +
		"  vision -c person,car /tmp/street.png\n\n" +
		"Requires /mnt/vision (visionfs) with a model loaded.";
}

schema(): string
{
	return "{" +
		"\"name\":\"vision\"," +
		"\"description\":\"What is in a picture: the objects a detector finds, one per line as " +
			"class=NAME score=S x0= y0= x1= y1= (its box in the picture's pixels), best first. " +
			"The picture goes only to the vision service at /mnt/vision.\"," +
		"\"parameters\":{" +
			"\"type\":\"object\"," +
			"\"properties\":{" +
				"\"imagepath\":{\"type\":\"string\",\"description\":\"Path to the picture (JPEG, PNG, GIF, WebP, ...).\"}," +
				"\"classes\":{\"type\":\"string\",\"description\":\"Optional: the classes to keep, comma-separated (e.g. person,car).\"}," +
				"\"thresh\":{\"type\":\"string\",\"description\":\"Optional: the lowest score kept, 0 to 1.\"}" +
			"}," +
			"\"required\":[\"imagepath\"]" +
		"}" +
	"}";
}

exec(args: string): string
{
	if(sys == nil || str == nil || lock == nil){
		e := init();
		if(e != nil)
			return "error: " + e;
	}
	(nil, argv) := sys->tokenize(args, " \t\r\n");
	classes: list of string;
	thresh := 0.3;
	threshset := 0;
	path := "";
	for(; argv != nil; argv = tl argv){
		case hd argv {
		"-c" =>
			argv = tl argv;
			if(argv == nil)
				return Usage;
			(nil, cl) := sys->tokenize(hd argv, ",");
			for(; cl != nil; cl = tl cl)
				classes = hd cl :: classes;
		"-t" =>
			argv = tl argv;
			if(argv == nil)
				return Usage;
			(v, rest) := str->toreal(hd argv, 10);
			if(rest != nil || v < 0.0 || v > 1.0)
				return "error: thresh: a number from 0 to 1";
			thresh = v;
			threshset = 1;
		* =>
			if(path != nil)
				return "error: one picture at a time";
			path = hd argv;
		}
	}
	if(path == nil)
		return Usage;

	(pic, err) := readfile(path, Maximage);
	if(err != nil)
		return "error: " + err;
	lock <-= 1;
	r: string;
	{
		r = look(path, pic, classes, thresh, threshset);
	}exception e{
	"*" =>
		r = "error: " + e;
	}
	<-lock;
	return r;
}

look(path: string, pic: array of byte, classes: list of string, thresh: real, threshset: int): string
{
	# a session: made by reading clone where there is one; where there
	# is not, the one this name space was given
	dir: string;
	cfd := sys->open(VISION + "/clone", Sys->OREAD);
	if(cfd != nil){
		b := array[32] of byte;
		n := sys->read(cfd, b, len b);
		if(n <= 0)
			return sys->sprint("error: %s/clone: %r", VISION);
		(nil, w) := sys->tokenize(string b[0:n], " \n");
		if(w == nil)
			return sys->sprint("error: %s/clone gave no session", VISION);
		dir = VISION + "/" + hd w;
		# its own score, where its ctl is there to tell
		if(threshset && (fd := sys->open(dir + "/ctl", Sys->OWRITE)) != nil &&
		   sys->fprint(fd, "thresh %g", thresh) < 0)
			return sys->sprint("error: %r");
	}else{
		dir = granted();
		if(dir == nil)
			return sys->sprint("error: no vision service: no session in %s", VISION);
	}
	fd := sys->open(dir + "/image", Sys->OWRITE);
	if(fd == nil)
		return sys->sprint("error: %s/image: %r", dir);
	for(o := 0; o < len pic; o += Sys->ATOMICIO){
		e := o + Sys->ATOMICIO;
		if(e > len pic)
			e = len pic;
		if(sys->write(fd, pic[o:e], e - o) != e - o)
			return sys->sprint("error: writing the picture: %r");
	}
	fd = nil;	# closed: looked at
	(found, ferr) := readfile(dir + "/detections", 1024*1024);
	cfd = nil;
	if(ferr != nil)
		return "error: " + ferr;
	kept := "";
	(nil, lines) := sys->tokenize(string found, "\n");
	for(; lines != nil; lines = tl lines)
		if(keep(hd lines, classes, thresh))
			kept += hd lines + "\n";
	if(kept == "")
		return "nothing found in " + path;
	return kept;
}

# the session of a name space given one: the only directory with a
# number for a name
granted(): string
{
	fd := sys->open(VISION, Sys->OREAD);
	if(fd == nil)
		return nil;
	dir := "";
	for(;;){
		(n, d) := sys->dirread(fd);
		if(n <= 0)
			break;
		for(i := 0; i < n; i++){
			name := d[i].name;
			for(j := 0; j < len name; j++)
				if(name[j] < '0' || name[j] > '9')
					break;
			if(len name == 0 || j < len name)
				continue;
			if(dir != "")
				return nil;
			dir = VISION + "/" + name;
		}
	}
	return dir;
}

# is a record (class=NAME score=S ..., a name with a blank quoted) one
# of the classes asked for, at the score asked for or better
keep(line: string, classes: list of string, thresh: real): int
{
	class := "";
	score := 1.0;
	for(w := str->unquoted(line); w != nil; w = tl w){
		f := hd w;
		if(len f > 6 && f[0:6] == "class=")
			class = f[6:];
		else if(len f > 6 && f[0:6] == "score=")
			(score, nil) = str->toreal(f[6:], 10);
	}
	if(score < thresh)
		return 0;
	if(classes == nil)
		return 1;
	for(; classes != nil; classes = tl classes)
		if(hd classes == class)
			return 1;
	return 0;
}

readfile(f: string, max: int): (array of byte, string)
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
		if(len buf + n > max)
			return (nil, f + ": too large");
		nb := array[len buf + n] of byte;
		nb[0:] = buf;
		nb[len buf:] = b[0:n];
		buf = nb;
	}
	return (buf, nil);
}
