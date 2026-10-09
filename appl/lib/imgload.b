implement Imgload;

#
# imgload - read an image file of any format the system decodes
# (see module/imgload.m).
#

include "sys.m";
	sys: Sys;

include "draw.m";
	draw: Draw;
	Display, Image, Rect, Point: import draw;

include "bufio.m";
	bufio: Bufio;
	Iobuf: import bufio;

include "imagefile.m";
	imageremap: Imageremap;

include "imgload.m";

include "pngload.m";
	pngload: Pngload;

display: ref Display;

# Maximum image size for subsampling (shared with pngload)
MAXPIXELS: con 16 * 1024 * 1024;

# Bytes of a file format() looks at: an SVG's <svg can follow an XML
# declaration, a comment and a doctype.
NHEAD: con 512;

Fmt: adt {
	name:	string;
	reader:	string;		# RImagefile, or nil if read here
	exts:	string;		# extensions, each with its dot and a space after
};

fmts := array[] of {
	Fmt("png",	RImagefile->READPNGPATH,	".png "),
	Fmt("jpeg",	RImagefile->READJPGPATH,	".jpg .jpeg .jpe "),
	Fmt("gif",	RImagefile->READGIFPATH,	".gif "),
	Fmt("webp",	RImagefile->READWEBPPATH,	".webp "),
	Fmt("avif",	RImagefile->READAVIFPATH,	".avif "),
	Fmt("svg",	RImagefile->READSVGPATH,	".svg "),
	Fmt("xbm",	RImagefile->READXBMPATH,	".xbm "),
	Fmt("pic",	RImagefile->READPICPATH,	".pic "),
	Fmt("ppm",	nil,	".ppm .pgm "),
	Fmt("bit",	nil,	".bit "),
};

init(d: ref Display)
{
	sys = load Sys Sys->PATH;
	draw = load Draw Draw->PATH;
	bufio = load Bufio Bufio->PATH;
	imageremap = load Imageremap Imageremap->PATH;
	if(imageremap != nil)
		imageremap->init(d);
	pngload = load Pngload Pngload->PATH;
	if(pngload != nil)
		pngload->init(d);
	display = d;
}

format(head: array of byte, name: string): string
{
	n := len head;
	if(n >= 8 && head[0] == byte 137 && string head[1:4] == "PNG" &&
	   head[4] == byte 13 && head[5] == byte 10 && head[6] == byte 26 && head[7] == byte 10)
		return "png";
	if(n >= 3 && head[0] == byte 16rFF && head[1] == byte 16rD8 && head[2] == byte 16rFF)
		return "jpeg";
	if(n >= 4 && string head[0:4] == "GIF8")
		return "gif";
	if(n >= 12 && string head[0:4] == "RIFF" && string head[8:12] == "WEBP")
		return "webp";
	if(n >= 12 && string head[4:8] == "ftyp" && isavif(head))
		return "avif";
	if(n >= 5 && string head[0:5] == "TYPE=")
		return "pic";
	if(n >= 7 && string head[0:7] == "#define")
		return "xbm";
	if(n >= 2 && head[0] == byte 'P' && (head[1] == byte '2' || head[1] == byte '3' ||
	   head[1] == byte '5' || head[1] == byte '6'))
		return "ppm";
	if(n >= 11 && string head[0:11] == "compressed\n")
		return "bit";
	if(hassvg(head))
		return "svg";

	# The data says nothing: text formats, or a name alone.
	return byext(name);
}

# An ISO BMFF file (MP4, HEIC, AVIF) is AVIF if its major brand or one
# of its compatible brands says so.
isavif(head: array of byte): int
{
	boxlen := (int head[0] << 24) | (int head[1] << 16) | (int head[2] << 8) | int head[3];
	if(boxlen > len head)
		boxlen = len head;
	for(i := 8; i + 4 <= boxlen; i += 4) {
		b := string head[i:i+4];
		if(b == "avif" || b == "avis")
			return 1;
	}
	return 0;
}

# An SVG document: <svg is its first element, after any XML
# declaration, comments and doctype.  (An HTML page with an inline
# <svg is not one.)
hassvg(head: array of byte): int
{
	s := string head;
	i := 0;
	if(len s >= 1 && s[0] == 16rFEFF)
		i++;
	for(;;) {
		while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n'))
			i++;
		if(i + 4 <= len s && s[i:i+4] == "<svg")
			return 1;
		end: string;
		if(i + 4 <= len s && s[i:i+4] == "<!--")
			end = "-->";
		else if(i + 2 <= len s && (s[i:i+2] == "<?" || s[i:i+2] == "<!"))
			end = ">";
		else
			return 0;
		j: int;
		for(j = i + 2; j + len end <= len s; j++)
			if(s[j:j+len end] == end)
				break;
		if(j + len end > len s)
			return 0;
		i = j + len end;
	}
}

# A name's extension, lower case, with its dot: "/a/B.PNG" is ".png".
extension(name: string): string
{
	for(i := len name - 1; i >= 0; i--) {
		if(name[i] == '/')
			return nil;
		if(name[i] == '.') {
			ext := name[i:];
			for(j := 1; j < len ext; j++)
				if(ext[j] >= 'A' && ext[j] <= 'Z')
					ext[j] += 'a' - 'A';
			return ext;
		}
	}
	return nil;
}

isimage(name: string): int
{
	return byext(name) != nil;
}

extensions(): string
{
	s := "";
	for(i := 0; i < len fmts; i++)
		s += fmts[i].exts;
	return s[0:len s - 1];
}

# The format a name's extension names.
byext(name: string): string
{
	ext := extension(name);
	if(ext == nil)
		return nil;
	ext += " ";
	for(i := 0; i < len fmts; i++) {
		e := fmts[i].exts;
		for(j := 0; j + len ext <= len e; j++)
			if(e[j:j+len ext] == ext && (j == 0 || e[j-1] == ' '))
				return fmts[i].name;
	}
	return nil;
}

# A fresh instance each time: the decoders keep their state in module
# globals, and two programs (or two of Xenith's windows) can decode at
# once.
reader(fmt: string): (RImagefile, string)
{
	for(i := 0; i < len fmts; i++) {
		if(fmts[i].name != fmt)
			continue;
		if(fmts[i].reader == nil)
			return (nil, fmt + " has no decoder module");
		rd := load RImagefile fmts[i].reader;
		if(rd == nil)
			return (nil, sys->sprint("can't load %s: %r", fmts[i].reader));
		rd->init(bufio);
		return (rd, nil);
	}
	return (nil, "unknown image format " + fmt);
}

readimage(path: string): (ref Image, string)
{
	if(display == nil)
		return (nil, "imgload not initialized");

	# Try native Inferno image format first
	im := display.open(path);
	if(im != nil)
		return (im, nil);

	# The first bytes, to detect the format
	f := sys->open(path, Sys->OREAD);
	if(f == nil)
		return (nil, sys->sprint("can't open %s: %r", path));
	head := array[NHEAD] of byte;
	n := 0;
	while(n < len head && (got := sys->read(f, head[n:], len head - n)) > 0)
		n += got;
	f = nil;

	fd := bufio->open(path, Sys->OREAD);
	if(fd == nil)
		return (nil, sys->sprint("can't open %s: %r", path));
	return dispatch(fd, head[0:n], path, nil);
}

# Load image from raw bytes
readimagedata(data: array of byte, hint: string): (ref Image, string)
{
	return readimagedataprogressive(data, hint, nil);
}

# Progressive image decode - sends progress updates during decode
readimagedataprogressive(data: array of byte, hint: string,
                         progress: chan of ref ImgProgress): (ref Image, string)
{
	if(display == nil)
		return (nil, "imgload not initialized");
	if(data == nil || len data < 4)
		return (nil, "image data too small");
	n := len data;
	if(n > NHEAD)
		n = NHEAD;
	return dispatch(bufio->aopen(data), data[0:n], hint, progress);
}

# Read an image of whatever format from fd, which begins with head and
# which dispatch closes.  Only a large PNG reports progress; nil
# progress asks for none.
dispatch(fd: ref Iobuf, head: array of byte, hint: string, progress: chan of ref ImgProgress): (ref Image, string)
{
	fmt := format(head, hint);
	if(fmt == nil) {
		fd.close();
		return (nil, "unrecognized image format");
	}
	case fmt {
	"png" =>
		if(pngload == nil)
			break;
		if(progress != nil)
			return pngload->loadpngprogressive(fd, hint, progress);
		return pngload->loadpng(fd, hint);
	"ppm" =>
		return loadppm(fd, hint);
	"bit" =>
		return loadbit(fd);
	}
	return decode(fd, fmt);
}

decode(fd: ref Iobuf, fmt: string): (ref Image, string)
{
	(rd, err) := reader(fmt);
	if(rd == nil) {
		fd.close();
		return (nil, err);
	}
	raw: ref RImagefile->Rawimage;
	{
		(raw, err) = rd->read(fd);
	} exception e {
	"*" =>
		(raw, err) = (nil, e);
	}
	fd.close();
	uf := upper(fmt);
	if(raw == nil){
		if(err != nil && !(len err > len uf && err[0:len uf+1] == uf + ":"))
			err = uf + ": " + err;
		if(err != nil)
			return (nil, err);
		return (nil, uf + " decode failed");
	}

	if(imageremap == nil)
		return (nil, "imageremap not available");

	(im, err2) := imageremap->remap(raw, display, 1);
	if(im == nil){
		if(err2 != nil)
			return (nil, uf + " remap: " + err2);
		return (nil, uf + " conversion failed");
	}
	return (im, nil);
}

# An Inferno image (image(6)), which the draw device reads from a file
# descriptor: the bytes go to it through a pipe.
loadbit(fd: ref Iobuf): (ref Image, string)
{
	p := array[2] of ref Sys->FD;
	if(sys->pipe(p) < 0) {
		fd.close();
		return (nil, sys->sprint("can't make pipe: %r"));
	}
	spawn copyout(fd, p[1]);
	p[1] = nil;
	im := display.readimage(p[0]);
	if(im == nil)
		return (nil, sys->sprint("Inferno image: %r"));
	return (im, nil);
}

copyout(fd: ref Iobuf, out: ref Sys->FD)
{
	buf := array[Sys->ATOMICIO] of byte;
	while((n := fd.read(buf, len buf)) > 0)
		if(sys->write(out, buf, n) != n)
			break;
	fd.close();
}

upper(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'a' && s[i] <= 'z')
			s[i] -= 'a' - 'A';
	return s;
}

# Calculate subsample factor to fit image within limits
calcsubsample(width, height: int): int
{
	pixels := width * height;
	if(pixels <= MAXPIXELS)
		return 1;

	for(factor := 2; factor <= 16; factor++){
		newpixels := (width / factor) * (height / factor);
		if(newpixels <= MAXPIXELS)
			return factor;
	}
	return 16;
}

loadppm(fd: ref Iobuf, path: string): (ref Image, string)
{
	# Read PPM header: P6\n<width> <height>\n<maxval>\n<data>
	# Or P3 for ASCII RGB; P5 and P2 are the same for grey (PGM)

	magic := fd.gets('\n');
	if(magic == nil){
		fd.close();
		return (nil, "can't read PPM magic");
	}

	# Trim newline
	if(len magic > 0 && magic[len magic - 1] == '\n')
		magic = magic[:len magic - 1];

	binary := (magic == "P6" || magic == "P5");
	nch := 3;
	if(magic == "P5" || magic == "P2")
		nch = 1;

	# Skip comments, read dimensions
	line: string;
	for(;;){
		line = fd.gets('\n');
		if(line == nil){
			fd.close();
			return (nil, "unexpected EOF in PPM header");
		}
		if(len line > 0 && line[0] != '#')
			break;
	}

	# Parse width height
	(n, toks) := sys->tokenize(line, " \t\n");
	if(n < 2){
		fd.close();
		return (nil, "bad PPM dimensions");
	}
	srcwidth := int hd toks;
	srcheight := int hd tl toks;

	if(srcwidth <= 0 || srcheight <= 0){
		fd.close();
		return (nil, "invalid PPM dimensions");
	}

	# Read maxval
	line = fd.gets('\n');
	if(line == nil){
		fd.close();
		return (nil, "can't read PPM maxval");
	}
	maxval := int line;
	if(maxval <= 0 || maxval > 255){
		fd.close();
		return (nil, "unsupported PPM maxval");
	}

	# Calculate subsample factor for large images
	subsample := calcsubsample(srcwidth, srcheight);
	dstwidth := srcwidth / subsample;
	dstheight := srcheight / subsample;
	if(dstwidth < 1) dstwidth = 1;
	if(dstheight < 1) dstheight = 1;

	# Create output image - use RGB24 format
	r := Rect((0, 0), (dstwidth, dstheight));
	im := display.newimage(r, Draw->RGB24, 0, Draw->Black);
	if(im == nil){
		fd.close();
		return (nil, "can't allocate image");
	}

	# Read pixel data with subsampling
	srcbpl := srcwidth * nch;  # Source bytes per line
	dstbpl := dstwidth * 3;  # Dest bytes per line
	srcrowdata := array[srcbpl] of byte;
	dstrowdata := array[dstbpl] of byte;

	dsty := 0;
	for(srcy := 0; srcy < srcheight; srcy++){
		if(binary){
			# Binary mode: read full source row
			nread := 0;
			while(nread < srcbpl){
				got := fd.read(srcrowdata[nread:], srcbpl - nread);
				if(got <= 0){
					fd.close();
					return (nil, "short read in PPM data");
				}
				nread += got;
			}
		} else {
			# ASCII mode: read space-separated values for full row
			for(x := 0; x < srcbpl; x++){
				s := "";
				c: int;
				while((c = fd.getb()) != Bufio->EOF){
					if(c != ' ' && c != '\t' && c != '\n' && c != '\r')
						break;
				}
				if(c == Bufio->EOF){
					fd.close();
					return (nil, "unexpected EOF in PPM data");
				}
				s[0] = c;
				while((c = fd.getb()) != Bufio->EOF && c >= '0' && c <= '9')
					s[len s] = c;
				srcrowdata[x] = byte int s;
			}
		}

		# Only process rows we're keeping (subsample vertically)
		if(srcy % subsample == 0 && dsty < dstheight){
			# Subsample horizontally: copy every Nth pixel
			for(dstx := 0; dstx < dstwidth; dstx++){
				srcx := dstx * subsample * nch;
				# PPM stores RGB; RGB24 needs BGR
				dstrowdata[dstx*3 + 0] = srcrowdata[srcx + nch - 1];
				dstrowdata[dstx*3 + 1] = srcrowdata[srcx + nch/2];
				dstrowdata[dstx*3 + 2] = srcrowdata[srcx];
			}

			# Write subsampled row to image
			rowr := Rect((0, dsty), (dstwidth, dsty + 1));
			im.writepixels(rowr, dstrowdata);
			dsty++;
		}
	}

	fd.close();
	return (im, nil);
}
