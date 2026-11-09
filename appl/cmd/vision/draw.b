implement Visdraw;

#
# vision/draw - records drawn on their pictures (#1086)
#
#	vision/draw [-d dir] [-o bit|png]
#
# Reads records on standard input. Each picture named by file= is drawn
# with its records' boxes and labels (label=, or class= and score=) and
# written to dir (default .) under its own name, as an uncompressed
# image(6) (.bit) or a PNG; the names written are printed. A record
# without a box names a picture to write as it is. It knows nothing of
# models: the records may have come from anywhere.
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
include "visnet.m";
	visnet: Visnet;
include "visrec.m";
	visrec: Visrec;
	Rec: import visrec;

Visdraw: module
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
	str = load String String->PATH;
	visnet = load Visnet Visnet->PATH;
	visrec = load Visrec Visrec->PATH;
	if(arg == nil || bufio == nil || str == nil || visnet == nil || visrec == nil)
		fatal(sys->sprint("cannot load modules: %r"));
	visrec->init();
	visnet->init();	# for its picture decoders; $Tensor is not needed here

	dir := ".";
	fmt := "bit";
	arg->init(argv);
	arg->setusage("vision/draw [-d dir] [-o bit|png]");
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

	# records by picture, in the order the pictures are first named
	files: list of string;
	recs: list of (string, list of ref Rec);
	in := bufio->fopen(sys->fildes(0), Bufio->OREAD);
	while((l := in.gets('\n')) != nil){
		r := visrec->parse(l);
		f := r.get("file");
		if(f == nil)
			continue;
		if(!member(f, files))
			files = f :: files;
		recs = (f, r :: nil) :: recs;
	}
	failed := 0;
	for(fl := rev(files); fl != nil; fl = tl fl){
		f := hd fl;
		(pix, w, h, err) := visnet->readpixels(f);
		if(pix == nil){
			sys->fprint(stderr, "vision/draw: %s\n", err);
			failed++;
			continue;
		}
		for(rl := rec2(recs); rl != nil; rl = tl rl){
			(rf, r) := hd rl;
			if(rf != f)
				continue;
			(x0, y0, x1, y1, ok) := r.box();
			if(ok)
				visrec->drawbox(pix, w, h, x0, y0, x1, y1, r.label());
		}
		out := dir + "/" + base(f) + "." + fmt;
		fd := sys->create(out, Sys->OWRITE, 8r666);
		if(fd == nil){
			sys->fprint(stderr, "vision/draw: %s: %r\n", out);
			failed++;
			continue;
		}
		if(fmt == "png")
			err = visrec->writepng(fd, pix, w, h);
		else
			err = visrec->writeimage(fd, pix, w, h);
		if(err != nil){
			sys->fprint(stderr, "vision/draw: %s: %s\n", out, err);
			failed++;
			continue;
		}
		sys->print("%s\n", out);
	}
	if(failed)
		raise sys->sprint("fail:%d not drawn", failed);
}

# the records, in the order read
rec2(l: list of (string, list of ref Rec)): list of (string, ref Rec)
{
	r: list of (string, ref Rec);
	for(; l != nil; l = tl l)
		r = ((hd l).t0, hd (hd l).t1) :: r;
	return r;
}

rev(l: list of string): list of string
{
	r: list of string;
	for(; l != nil; l = tl l)
		r = hd l :: r;
	return r;
}

member(s: string, l: list of string): int
{
	for(; l != nil; l = tl l)
		if(hd l == s)
			return 1;
	return 0;
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
	sys->fprint(stderr, "vision/draw: %s\n", s);
	raise "fail:" + s;
}
