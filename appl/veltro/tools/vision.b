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
# Usage:
#   vision [-c class,...] [-t thresh] imagepath
#

include "sys.m";
	sys: Sys;

include "draw.m";

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

init(): string
{
	sys = load Sys Sys->PATH;
	if(sys == nil)
		return "cannot load Sys";
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
	if(sys == nil)
		init();
	(nil, argv) := sys->tokenize(args, " \t\r\n");
	settings := "";
	path := "";
	for(; argv != nil; argv = tl argv){
		case hd argv {
		"-c" =>
			argv = tl argv;
			if(argv == nil)
				return "error: usage: vision [-c class,...] [-t thresh] imagepath";
			(nil, cl) := sys->tokenize(hd argv, ",");
			s := "classes";
			for(; cl != nil; cl = tl cl)
				s += " " + hd cl;
			settings += s + "\n";
		"-t" =>
			argv = tl argv;
			if(argv == nil)
				return "error: usage: vision [-c class,...] [-t thresh] imagepath";
			settings += "thresh " + hd argv + "\n";
		* =>
			if(path != nil)
				return "error: one picture at a time";
			path = hd argv;
		}
	}
	if(path == nil)
		return "error: usage: vision [-c class,...] [-t thresh] imagepath";

	(pic, err) := readfile(path, Maximage);
	if(err != nil)
		return "error: " + err;
	cfd := sys->open(VISION + "/clone", Sys->OREAD);
	if(cfd == nil)
		return sys->sprint("error: no vision service: %s/clone: %r", VISION);
	b := array[32] of byte;
	n := sys->read(cfd, b, len b);
	if(n <= 0)
		return sys->sprint("error: %s/clone: %r", VISION);
	(nil, w) := sys->tokenize(string b[0:n], " \n");
	dir := VISION + "/" + hd w;
	if(settings != nil){
		fd := sys->open(dir + "/ctl", Sys->OWRITE);
		if(fd == nil)
			return sys->sprint("error: %s/ctl: %r", dir);
		d := array of byte settings;
		if(sys->write(fd, d, len d) != len d)
			return sys->sprint("error: %r");
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
	if(len found == 0)
		return "nothing found in " + path;
	return string found;
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
