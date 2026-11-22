implement Crop;

#
# vision/crop - each box a picture of its own (#1086)
#
#	vision/crop [-d dir] [-o bit|png]
#
# Reads records on standard input. Each box (x0 y0 x1 y1) in a picture
# named by file= is cut out and written to dir (default .) as
# NAME.N.bit or .png, N counting that picture's boxes from 0, and the
# name written is printed, one a line: so a second model can be run on
# what the first found,
#
#	vision/detect *.jpg | grep class=dog | vision/crop -d /tmp/dogs | vision/detect -m breeds
#

include "sys.m";
	sys: Sys;
include "draw.m";
include "arg.m";
include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;
include "visnet.m";
	visnet: Visnet;
include "visrec.m";
	visrec: Visrec;
	Rec: import visrec;

Crop: module
{
	init:	fn(nil: ref Draw->Context, argv: list of string);
};

stderr: ref Sys->FD;

init(nil: ref Draw->Context, argv: list of string)
{
	sys = load Sys Sys->PATH;
	stderr = sys->fildes(2);
	arg := load Arg Arg->PATH;
	bufio = load Bufio Bufio->PATH;
	visnet = load Visnet Visnet->PATH;
	visrec = load Visrec Visrec->PATH;
	if(arg == nil || bufio == nil || visnet == nil || visrec == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	visrec->init();
	visnet->init();

	dir := ".";
	fmt := "bit";
	arg->init(argv);
	arg->setusage("vision/crop [-d dir] [-o bit|png]");
	while((o := arg->opt()) != 0)
		case o {
		'd' =>	dir = arg->earg();
		'o' =>
			fmt = arg->earg();
			if(fmt != "bit" && fmt != "png")
				arg->usage();
		* =>	arg->usage();
		}
	if(arg->argv() != nil)
		arg->usage();

	# the picture read last is kept: a detector's records come a picture at a time
	cur: string;
	pix: array of byte;
	(w, h) := (0, 0);
	count := 0;
	failed := 0;
	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	while((l := in.gets('\n')) != nil){
		r := visrec->parse(l);
		f := r.get("file");
		(x0, y0, x1, y1, ok) := r.box();
		if(f == nil || !ok)
			continue;
		if(f != cur){
			err: string;
			(pix, w, h, err) = visnet->readpixels(f);
			cur = f;
			count = 0;
			if(pix == nil){
				sys->fprint(stderr, "vision/crop: %s\n", err);
				failed++;
				continue;
			}
		}
		if(pix == nil)
			continue;
		(c, cw, ch) := visrec->crop(pix, w, h, x0, y0, x1, y1);
		n := count++;
		if(c == nil){
			sys->fprint(stderr, "vision/crop: %s: box %d is outside the picture\n", f, n);
			failed++;
			continue;
		}
		out := sys->sprint("%s/%s.%d.%s", dir, base(f), n, fmt);
		fd := sys->create(out, Sys->OWRITE, 8r666);
		if(fd == nil){
			sys->fprint(stderr, "vision/crop: %s: %r\n", out);
			failed++;
			continue;
		}
		err: string;
		if(fmt == "png")
			err = visrec->writepng(fd, c, cw, ch);
		else
			err = visrec->writeimage(fd, c, cw, ch);
		if(err != nil){
			sys->fprint(stderr, "vision/crop: %s: %s\n", out, err);
			failed++;
			continue;
		}
		sys->print("%s\n", out);
	}
	if(failed)
		raise sys->sprint("fail:%d not cut", failed);
}

base(f: string): string
{
	for(i := len f - 1; i >= 0; i--)
		if(f[i] == '/')
			return f[i+1:];
	return f;
}

fatal(s: string)
{
	sys->fprint(stderr, "vision/crop: %s\n", s);
	raise "fail:" + s;
}
