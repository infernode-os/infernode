#
# pdf.c: the PDF it writes
#

bout: ref Iobuf;

pdf_title: string;
pdf_author: string;
pdf_width := 0;			# the page's size, in points
pdf_height := 0;
pdf_linewid := 0;		# line width in thousandths of an em
pdf_linecap := 1;		# 0 butt, 1 round, 2 projecting square
pdf_linejoin := 1;		# 0 miter, 1 round, 2 bevel
pdf_pages := 0;			# the pages object
pdf_root := 0;			# the root object
pdf_pos := 0;			# the offset written to
obj_off: array of int;		# the objects' offsets
obj_n := 0;
page_id: array of int;		# the pages' objects
page_n := 0;
pdf_outline := 0;		# the outline
pdf_dests := 0;			# named destinations

pg: string;			# the page's contents
o_f, o_s, o_m: int;		# font, size and colour
o_h, o_v: int;			# the position troff is at
pg_label: array of string;	# each page's number as printed (x X folio)
p_h, p_v: int;			# and the PDF's
o_i := -1;			# troff's font (pfonts' index; none yet)
p_i := 0;			# the PDF's
p_f, p_s, p_m: int;
o_queued := 0;			# a TJ begun
o_iset := array[1024] of {* => byte 0};	# the page's fonts
xobj := array[128] of int;	# the page's XObjects
xobj_n := 0;
ann := array[128] of int;	# and its annotations
ann_n := 0;

# a font in the PDF
Pfont: adt {
	name:	string;		# its PostScript name
	path:	string;		# its file
	desc:	string;		# its description
	gbeg:	int;		# the first glyph used
	gend:	int;		# the last
	sub:	int;		# subfont
	obj:	int;		# the font object
	des:	int;		# its descriptor
	cid:	int;		# CID-keyed
	cff:	int;		# OpenType with CFF outlines
	used:	array of byte;	# the glyphs used, for ToUnicode
};

pfonts: array of ref Pfont;
pfonts_n := 0;

pdfout(s: string)
{
	b := array of byte s;
	bout.write(b, len b);
	pdf_pos += len b;
}

pdfmem(b: array of byte)
{
	bout.write(b, len b);
	pdf_pos += len b;
}

obj_map(): int
{
	if(obj_n == len obj_off)
		obj_off = growint(obj_off, len obj_off + 1024);
	return obj_n++;
}

obj_beg(id: int): int
{
	if(id <= 0)
		id = obj_map();
	obj_off[id] = pdf_pos;
	pdfout(string id + " 0 obj\n");
	return id;
}

obj_end()
{
	pdfout("endobj\n\n");
}

# 't': TrueType or OpenType, '1': Type 1
fonttype(path: string): int
{
	ext := "";
	for(i := len path - 1; i >= 0; i--)
		if(path[i] == '.'){
			ext = path[i:];
			break;
		}
	case ext {
	".ttf" or ".otf" or ".ttc" or ".otc" =>
		return 't';
	}
	return '1';
}

readfile(path: string): array of byte
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	b := array[64 * 1024] of byte;
	n := 0;
	for(;;){
		if(n == len b){
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		m := sys->read(fd, b[n:], len b - n);
		if(m <= 0)
			break;
		n += m;
	}
	return b[0:n];
}

# whether a font file holds an OpenType font with CFF outlines
iscff(path: string): int
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return 0;
	b := array[4] of byte;
	return sys->read(fd, b, 4) == 4 && string b == "OTTO";
}

wid1000(w: int): int
{
	return int (big w * big 100 * big 72 / big devres());
}

pfont_write(ps: ref Pfont)
{
	fnt := dev_fontopen(ps.desc);
	# the encoding
	enc_obj := obj_beg(0);
	s := "<<\n  /Type /Encoding\n  /Differences [ " + string (ps.gbeg % 256);
	for(i := ps.gbeg; i <= ps.gend; i++)
		s += " /" + font_glget(fnt, i).id;
	pdfout(s + " ]\n>>\n");
	obj_end();
	# the font
	obj_beg(ps.obj);
	s = "<<\n  /Type /Font\n";
	if(fonttype(ps.path) == 't')
		s += "  /Subtype /TrueType\n";
	else
		s += "  /Subtype /Type1\n";
	s += "  /BaseFont /" + ps.name + "\n";
	s += "  /FirstChar " + string (ps.gbeg % 256) + "\n";
	s += "  /LastChar " + string (ps.gend % 256) + "\n";
	s += "  /Widths [";
	for(i = ps.gbeg; i <= ps.gend; i++)
		s += " " + string wid1000(font_glget(fnt, i).wid);
	s += " ]\n";
	s += "  /FontDescriptor " + string ps.des + " 0 R\n";
	s += "  /Encoding " + string enc_obj + " 0 R\n";
	pdfout(s + ">>\n");
	obj_end();
}

# data in hexadecimal, as Neatpost writes it
encodehex(b: array of byte): array of byte
{
	hex := "0123456789ABCDEF";
	n := len b;
	d := array[2 * n + n / 40 + 2] of byte;
	k := 0;
	for(i := 0; i < n; i++){
		c := int b[i];
		d[k++] = byte hex[c >> 4];
		d[k++] = byte hex[c & 16r0f];
		if(i % 40 == 39 && i + 1 < n)
			d[k++] = byte '\n';
	}
	d[k++] = byte '>';
	d[k++] = byte '\n';
	return d[0:k];
}

pfont_writecid(ps: ref Pfont)
{
	fnt := dev_fontopen(ps.desc);
	tounicode := 0;
	if(!compat)
		tounicode = writetounicode(ps, fnt);
	# the CIDFont
	cid_obj := obj_beg(0);
	s := "<<\n  /Type /Font\n";
	if(ps.cff && !compat)
		s += "  /Subtype /CIDFontType0\n";
	else
		s += "  /Subtype /CIDFontType2\n";
	s += "  /BaseFont /" + ps.name + "\n";
	s += "  /CIDSystemInfo <</Ordering(Identity)/Registry(Adobe)/Supplement 0>>\n";
	s += "  /FontDescriptor " + string ps.des + " 0 R\n";
	s += "  /DW 1000\n";
	s += "  /W [ " + string ps.gbeg + " [";
	for(i := ps.gbeg; i <= ps.gend; i++)
		s += " " + string wid1000(font_glget(fnt, i).wid);
	s += " ] ]\n";
	pdfout(s + ">>\n");
	obj_end();
	# the font
	obj_beg(ps.obj);
	s = "<<\n  /Type /Font\n  /Subtype /Type0\n";
	s += "  /BaseFont /" + ps.name + "\n";
	s += "  /Encoding /Identity-H\n";
	s += "  /DescendantFonts [" + string cid_obj + " 0 R]\n";
	if(tounicode)
		s += "  /ToUnicode " + string tounicode + " 0 R\n";
	pdfout(s + ">>\n");
	obj_end();
}

#
# ToUnicode: the characters each glyph used is, from the names the
# description gives them; a glyph without one (an alternate, as a.sc)
# is the character of the glyph its name is a variant of
#
writetounicode(ps: ref Pfont, fnt: ref Font): int
{
	maps: list of string;
	n := 0;
	for(i := ps.gbeg; i <= ps.gend && i < len ps.used; i++){
		if(ps.used[i] == byte 0)
			continue;
		u := glyphtext(fnt, font_glget(fnt, i));
		if(u == nil)
			continue;
		maps = sys->sprint("<%04x> <%s>\n", i, utf16hex(u)) :: maps;
		n++;
	}
	if(n == 0)
		return 0;
	a := array[n] of string;
	for(i = n - 1; i >= 0; i--){
		a[i] = hd maps;
		maps = tl maps;
	}
	s := "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n" +
		"/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n" +
		"/CMapName /Adobe-Identity-UCS def\n/CMapType 2 def\n" +
		"1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n";
	for(i = 0; i < n; i += 100){
		e := i + 100;
		if(e > n)
			e = n;
		s += string (e - i) + " beginbfchar\n";
		for(k := i; k < e; k++)
			s += a[k];
		s += "endbfchar\n";
	}
	s += "endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n";
	return writestream("", array of byte s);
}

# the characters a glyph is; nil if none
glyphtext(fnt: ref Font, g: ref Glyph): string
{
	if(g == nil)
		return nil;
	if(!unnamed(g.name))
		return troffchar(g.name);
	id := g.id;
	for(i := 0; i < len id; i++)
		if(id[i] == '.'){
			b := font_glyph(fnt, id[0:i]);
			if(b != nil && !unnamed(b.name))
				return troffchar(b.name);
			break;
		}
	return nil;
}

# whether a glyph's name is one the description made up (c0012)
unnamed(s: string): int
{
	if(len s != 5 || s[0] != 'c')
		return 0;
	for(i := 1; i < 5; i++)
		if(!isdigit(s[i]))
			return 0;
	return 1;
}

# the characters for mkfn's names of ` ' ~ ^
troffchar(s: string): string
{
	case s {
	"ga" =>
		return "`";
	"aq" =>
		return "'";
	"ti" =>
		return "~";
	"ha" =>
		return "^";
	}
	return s;
}

utf16hex(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		r += sys->sprint("%04X", s[i]);
	return r;
}

# a stream object, compressed; its dictionary's entries in dict
writestream(dict: string, data: array of byte): int
{
	z := zip(data);
	id := obj_beg(0);
	pdfout("<<\n  /Filter /FlateDecode\n  /Length " + string len z + "\n" + dict + ">>\nstream\n");
	pdfmem(z);
	pdfout("\nendstream\n");
	obj_end();
	return id;
}

# data compressed, with zlib's headers, as FlateDecode reads it
zip(data: array of byte): array of byte
{
	rq := deflate->start("z6");
	out := array[len data / 2 + 1024] of byte;
	n := 0;
	i := 0;
	for(;;){
	pick m := <-rq {
	Start =>
		;
	Fill =>
		k := len data - i;
		if(k > len m.buf)
			k = len m.buf;
		m.buf[0:] = data[i:i + k];
		i += k;
		m.reply <-= k;
	Result =>
		if(n + len m.buf > len out){
			no := array[2 * (n + len m.buf)] of byte;
			no[0:] = out[0:n];
			out = no;
		}
		out[n:] = m.buf;
		n += len m.buf;
		m.reply <-= 0;
	Finished =>
		return out[0:n];
	Info =>
		;
	Error =>
		sys->fprint(sys->fildes(2), "tr2pdf: deflate: %s\n", m.e);
		raise "fail:deflate";
	}
	}
}

# the font descriptor, as object id (if not 0); its object, or (with
# used, the glyphs a subset is to keep) its subset's tag, nil if whole
writedesc(fnt: ref Font, id: int, used: array of byte): string
{
	tag: string;
	str_obj := -1;
	path := fnt.fontpath;
	fntype := fonttype(path);
	data := readfile(path);
	if(data == nil)
		data = array[0] of byte;
	fm := ref Fmetrics(32, -1000, -1000, 1000, 1000, 0, 100, 100, 100, 100);
	cff := 0;
	if(!compat){
		cff = len data >= 4 && string data[0:4] == "OTTO";
		fm = fmetrics(data, fm);
		if(len data > 0){
			if(fntype == 't' && cff && used != nil){
				# subset to the glyphs used; whole if it cannot be
				if((sub := otfsubset(data, used)) != nil){
					data = sub;
					tag = subsettag(used);
				}
			}
			if(fntype == 't' && !cff && used != nil){
				if((sub := ttfsubset(data, used)) != nil){
					data = sub;
					tag = subsettag(used);
				}
			}
			if(fntype == 't' && cff)
				str_obj = writestream("  /Subtype /OpenType\n", data);
			else if(fntype == 't')
				str_obj = writestream("  /Length1 " + string len data + "\n", data);
			else{
				(e, l1, fixp, nil) := type1lengths(data);
				if(!e && fixp == 0)
					fixp = len data;
				if(!e)
					str_obj = writestream("  /Length1 " + string l1 + "\n  /Length2 " +
						string (fixp - l1) + "\n  /Length3 0\n", data[0:fixp]);
			}
		}
	}else if(fntype == '1' || fntype == 't'){
		l1 := len data;
		l2 := 0;
		l3 := 0;
		if(fntype == '1'){
			e: int;
			(e, l1, l2, l3) = type1lengths(data);
			if(e)
				l1 = 0;
			# without the fixed-content portion
			if(l3 && l1 + l2 < len data)
				data = data[0:l1 + l2];
			l1 -= l3;
			l3 = 0;
		}
		hex := encodehex(data);
		if(l1){
			str_obj = obj_beg(0);
			s := "<<\n  /Filter /ASCIIHexDecode\n";
			s += "  /Length " + string len hex + "\n";
			s += "  /Length1 " + string l1 + "\n";
			if(fntype == '1')
				s += "  /Length2 " + string l2 + "\n  /Length3 " + string l3 + "\n";
			pdfout(s + ">>\nstream\n");
			pdfmem(hex);
			pdfout("endstream\n");
			obj_end();
		}
	}
	# the descriptor
	des_obj := obj_beg(id);
	s := "<<\n  /Type /FontDescriptor\n";
	if(tag != nil)
		s += "  /FontName /" + tag + "+" + font_name(fnt) + "\n";
	else
		s += "  /FontName /" + font_name(fnt) + "\n";
	s += "  /Flags " + string fm.flags + "\n";
	s += sys->sprint("  /FontBBox [%d %d %d %d]\n", fm.x0, fm.y0, fm.x1, fm.y1);
	s += "  /MissingWidth 1000\n";
	s += "  /StemV " + string fm.stemv + "\n";
	s += "  /ItalicAngle " + string fm.italic + "\n";
	s += "  /CapHeight " + string fm.capheight + "\n";
	s += "  /Ascent " + string fm.ascent + "\n";
	s += "  /Descent " + string fm.descent + "\n";
	if(str_obj >= 0){
		ff := "";
		if(fntype == 't')
			ff = "2";
		if(fntype == 't' && cff && !compat)
			ff = "3";
		s += "  /FontFile" + ff + " " + string str_obj + " 0 R\n";
	}
	pdfout(s + ">>\n");
	obj_end();
	if(id == 0)
		return string des_obj;
	return tag;
}

# a subset font's tag: six capitals, from the glyphs it keeps
subsettag(used: array of byte): string
{
	h := 5381;
	for(i := 0; i < len used; i++)
		if(used[i] != byte 0)
			h = (h * 33 + i) & 16r7fffffff;
	t := "";
	for(i = 0; i < 6; i++){
		t[len t] = 'A' + h % 26;
		h /= 26;
	}
	return t;
}

# a Type 1 font's lengths: its clear text, encrypted and fixed parts; and whether it is not one
type1lengths(t1: array of byte): (int, int, int, int)
{
	l := len t1;
	enc := -1;
	i: int;
	for(i = 0; i < l - 5 && enc < 0; i++)
		if(t1[i] == byte 'e' && string t1[i:i + 5] == "eexec")
			enc = i;
	if(enc < 0)
		return (1, 0, 0, 0);
	fixp := -1;
	for(; i < l - 512 && fixp < 0; i++)
		if(t1[i] == byte '0' && string t1[i:i + 5] == "00000")
			fixp = i;
	if(fixp < 0)
		return (0, enc, 0, 0);
	return (0, enc, fixp, l - fixp);
}

# what a font descriptor says of a font
Fmetrics: adt {
	flags:	int;
	x0, y0, x1, y1:	int;
	italic:	int;
	capheight:	int;
	ascent:	int;
	descent:	int;
	stemv:	int;
};

# a font's metrics, from its tables, in thousandths of an em
fmetrics(d: array of byte, fm: ref Fmetrics): ref Fmetrics
{
	{
		if(len d < 12)
			return fm;
		t := (int d[0] << 24) | (int d[1] << 16) | (int d[2] << 8) | int d[3];
		if(t != 16r00010000 && t != 16r4F54544F)
			return fm;
		ntab := (int d[4] << 8) | int d[5];
		head, hhea, os2, post: int;
		head = hhea = os2 = post = -1;
		for(i := 0; i < ntab; i++){
			r := 12 + 16 * i;
			o := (int d[r + 8] << 24) | (int d[r + 9] << 16) | (int d[r + 10] << 8) | int d[r + 11];
			case string d[r:r + 4] {
			"head" =>
				head = o;
			"hhea" =>
				hhea = o;
			"OS/2" =>
				os2 = o;
			"post" =>
				post = o;
			}
		}
		if(head < 0)
			return fm;
		upm := u16(d, head + 18);
		if(upm == 0)
			return fm;
		k := 1000.0 / real upm;
		r := ref *fm;
		r.x0 = int (real s16(d, head + 36) * k);
		r.y0 = int (real s16(d, head + 38) * k);
		r.x1 = int (real s16(d, head + 40) * k);
		r.y1 = int (real s16(d, head + 42) * k);
		r.ascent = r.y1;
		r.descent = r.y0;
		if(hhea >= 0){
			r.ascent = int (real s16(d, hhea + 4) * k);
			r.descent = int (real s16(d, hhea + 6) * k);
		}
		r.capheight = r.ascent;
		if(os2 >= 0 && u16(d, os2) >= 2)
			r.capheight = int (real s16(d, os2 + 88) * k);
		r.flags = 32;	# nonsymbolic
		r.stemv = 80;
		if(os2 >= 0 && u16(d, os2 + 4) >= 700)	# bold
			r.stemv = 140;
		if(post >= 0){
			r.italic = s16(d, post + 4);	# its integer part
			if(r.italic != 0)
				r.flags |= 64;
			if(u16(d, post + 12) || u16(d, post + 14))
				r.flags |= 1;
		}
		return r;
	} exception {
	* =>
		return fm;
	}
}

u16(d: array of byte, o: int): int
{
	return (int d[o] << 8) | int d[o + 1];
}

s16(d: array of byte, o: int): int
{
	v := u16(d, o);
	if(v >= 16r8000)
		v -= 16r10000;
	return v;
}

pfont_find(g: ref Glyph): int
{
	fnt := g.fnt;
	name := font_name(fnt);
	fntype := fonttype(fnt.fontpath);
	sub := 0;
	if(fntype == '1')
		sub = g.idx / 256;
	for(i := 0; i < pfonts_n; i++)
		if(pfonts[i].name == name && pfonts[i].sub == sub)
			return i;
	if(pfonts_n == len pfonts){
		n := array[len pfonts + 16] of ref Pfont;
		n[0:] = pfonts[0:pfonts_n];
		pfonts = n;
	}
	ps := ref Pfont(name, fnt.fontpath, fnt.desc, 1 << 20, 0, sub, obj_map(), 0, fntype == 't', 0, nil);
	if(!compat)
		ps.cff = iscff(fnt.fontpath);
	for(i = 0; i < pfonts_n; i++)
		if(pfonts[i].name == ps.name)
			break;
	if(i < pfonts_n)
		ps.des = pfonts[i].des;
	else if(compat)
		ps.des = int writedesc(fnt, 0, nil);
	else{
		# written at the end, when the glyphs it is subset to are known
		ps.des = obj_map();
		pdescs = (fnt, ps.des) :: pdescs;
	}
	pfonts[pfonts_n] = ps;
	return pfonts_n++;
}

pdescs: list of (ref Font, int);	# descriptors to write, with their objects
wholefonts := 0;	# -W: fonts embedded whole

pfont_done()
{
	for(l := pdescs; l != nil; l = tl l){
		(fnt, des) := hd l;
		name := font_name(fnt);
		# the glyphs every font of this name used
		used := array[0] of byte;
		for(i := 0; i < pfonts_n; i++){
			ps := pfonts[i];
			if(ps.name != name || ps.used == nil)
				continue;
			if(len ps.used > len used){
				n := array[len ps.used] of {* => byte 0};
				n[0:] = used;
				used = n;
			}
			for(k := 0; k < len ps.used; k++)
				if(ps.used[k] != byte 0)
					used[k] = byte 1;
		}
		if(wholefonts)
			used = nil;
		tag := writedesc(fnt, des, used);
		if(tag != nil)
			for(i = 0; i < pfonts_n; i++)
				if(pfonts[i].name == name)
					pfonts[i].name = tag + "+" + name;
	}
	pdescs = nil;
	for(i := 0; i < pfonts_n; i++){
		if(pfonts[i].cid)
			pfont_writecid(pfonts[i]);
		else
			pfont_write(pfonts[i]);
	}
}

o_flush()
{
	if(o_queued == 1)
		pg += ">] TJ\n";
	o_queued = 0;
}

o_loadfont(g: ref Glyph): int
{
	f := pfont_find(g);
	o_iset[f] = byte 1;
	return f;
}

# a position, its coordinates multiplied by 100
pdfpos00(uh, uv: big): string
{
	h := int (uh * big 72 / big devres());
	v := int (big pdf_height * big 100 - uv * big 72 / big devres());
	return dec2(h) + " " + dec2(v);
}

# n hundredths, as %s%d.%02d
dec2(n: int): string
{
	s := "";
	if(n < 0)
		s = "-";
	n = abs(n);
	return s + string (n / 100) + "." + string ((n % 100) / 10) + string (n % 10);
}

# troff's position as the PDF's
pdfpos(uh, uv: int): string
{
	return pdfpos00(big uh * big 100, big uv * big 100);
}

# a troff length in thousandths of a unit of text space
pdfunit(uh, sz: int): string
{
	h := int (big uh * big 1000 * big 72 / big sz / big devres());
	return string h;
}

# troff's colour as the PDF's
pdfcolor(m: int): string
{
	r := ((m >> 16) & 16rff) * 1000 / 255;
	g := ((m >> 8) & 16rff) * 1000 / 255;
	b := (m & 16rff) * 1000 / 255;
	return dec3(r) + " " + dec3(g) + " " + dec3(b);
}

dec3(n: int): string
{
	return sys->sprint("%d.%03d", n / 1000, n % 1000);
}

o_queue(g: ref Glyph)
{
	if(o_v != p_v){
		o_flush();
		pg += "1 0 0 1 " + pdfpos(o_h, o_v) + " Tm\n";
		p_h = o_h;
		p_v = o_v;
	}
	if(o_tz != p_tz){
		o_flush();
		t := 1000 + o_tz;
		pg += string (t / 10) + "." + string (t % 10) + " Tz\n";
		p_tz = o_tz;
		p_tzacc = 0;
	}
	if(!o_queued)
		pg += "[<";
	o_queued = 1;
	# TJ's numbers are scaled with the glyphs (Tz): troff's are not
	if(o_h != p_h)
		pg += "> " + pdfunit(int (big (p_h - o_h) * big 1000 / big (1000 + p_tz)), o_s) + " <";
	gid := g.idx;
	ps := pfonts[o_i];
	if(ps.cid)
		pg += sys->sprint("%04x", gid);
	else
		pg += sys->sprint("%02x", gid % 256);
	if(gid < ps.gbeg)
		ps.gbeg = gid;
	if(gid > ps.gend)
		ps.gend = gid;
	if(!compat){
		if(gid >= len ps.used){
			n := array[gid + 1024] of {* => byte 0};
			n[0:] = ps.used;
			ps.used = n;
		}
		ps.used[gid] = byte 1;
	}
	if(p_tz){
		t := font_wid(g.fnt, o_s, g.wid) * (1000 + p_tz) + p_tzacc;
		p_tzacc = t % 1000;
		p_h = o_h + t / 1000;
	}else
		p_h = o_h + font_wid(g.fnt, o_s, g.wid);
}

out_fontup()
{
	if(o_m != p_m){
		o_flush();
		pg += pdfcolor(o_m) + " rg\n";
		p_m = o_m;
	}
	if(o_i >= 0 && (o_i != p_i || o_s != p_s)){
		ps := pfonts[o_i];
		o_flush();
		if(ps.cid)
			pg += "/" + ps.name + " " + string o_s + " Tf\n";
		else
			pg += "/" + ps.name + "." + string ps.sub + " " + string o_s + " Tf\n";
		p_i = o_i;
		p_s = o_s;
	}
}

outc(c: string)
{
	g := dev_glyph(c, o_f);
	if(g == nil){
		fnt := dev_font(o_f);
		if(c == " " && fnt != nil)
			outrel(font_swid(fnt, o_s), 0);
		else
			outrel(1, 0);
		return;
	}
	o_i = o_loadfont(g);
	out_fontup();
	o_queue(g);
}

outh(h: int)
{
	o_h = h;
}

outv(v: int)
{
	o_v = v;
}

outrel(h, v: int)
{
	o_h += h;
	o_v += v;
}

outfont(f: int)
{
	if(dev_font(f) != nil)
		o_f = f;
}

outsize(s: int)
{
	if(s > 0)
		o_s = s;
}

outcolor(c: int)
{
	o_m = c;
}

outpdf(path: string, hwid, vwid: int)
{
	data := readfile(path);
	if(data == nil)
		data = array[0] of byte;
	xobj_id := pdfext(data, hwid, vwid);
	o_flush();
	out_fontup();
	if(xobj_id >= 0)
		pg += "ET /FO" + string xobj_id + " Do BT\n";
	p_h = -1;
	p_v = -1;
}

outlink(lnk: string, hwid, vwid: int)
{
	if(ann_n == len ann)
		return;
	o_flush();
	ann[ann_n++] = obj_beg(0);
	s := "<<\n  /Type /Annot\n  /Subtype /Link\n";
	s += "  /Rect [" + pdfpos(o_h, o_v);
	s += " " + pdfpos(o_h + hwid, o_v + vwid) + "]\n";
	if(!compat)
		s += "  /Border [0 0 0]\n";
	if(lnk[0] == '#' && compat)	# within the document
		s += "  /A << /S /GoTo /D (" + lnk[1:] + ") >>\n";
	else if(lnk[0] == '#')	# by its name in the catalogue's Dests
		s += "  /A << /S /GoTo /D /" + pdfname(lnk[1:]) + " >>\n";
	else
		s += "  /A << /S /URI /URI " + pdftext_static(lnk) + " >>\n";
	pdfout(s + ">>\n");
	obj_end();
}

outname(n: int, desc: array of string, page, off: array of int)
{
	o_flush();
	pdf_dests = obj_beg(0);
	s := "<<\n";
	for(i := 0; i < n; i++)
		if(page[i] > 0 && page[i] - 1 < page_n && compat)
			s += "  /" + desc[i] + " [ " + string page_id[page[i] - 1] + " 0 R /XYZ 0 " +
				string (pdf_height - (off[i] * 72 / devres())) + " 0 ]\n";
		else if(page[i] > 0 && page[i] - 1 < page_n)
			s += "  /" + pdfname(desc[i]) + " [ " + string page_id[page[i] - 1] + " 0 R /XYZ 0 " +
				string (pdf_height - (off[i] * 72 / devres())) + " 0 ]\n";
	pdfout(s + ">>\n");
	obj_end();
}

# a name as PDF writes one: a character not regular in a name as #xx,
# each byte of its UTF-8
pdfname(s: string): string
{
	r := "";
	b := array of byte s;
	for(i := 0; i < len b; i++){
		c := int b[i];
		if(c <= 32 || c >= 127 || c == '#' || c == '/' || c == '%' || c == '(' || c == ')' ||
				c == '<' || c == '>' || c == '[' || c == ']' || c == '{' || c == '}')
			r += sys->sprint("#%.2X", c);
		else
			r[len r] = c;
	}
	return r;
}

outmark(n: int, desc: array of string, page, off, level: array of int)
{
	# the levels made a tree: the first the top, none deeper than one
	# below the one before (not Neatpost's: it nests them as given)
	if(!compat && n > 0){
		lv := array[n] of int;
		lo := level[0];
		for(i := 1; i < n; i++)
			if(level[i] < lo)
				lo = level[i];
		for(i = 0; i < n; i++){
			lv[i] = level[i] - lo;
			if(i == 0)
				lv[i] = 0;
			else if(lv[i] > lv[i - 1] + 1)
				lv[i] = lv[i - 1] + 1;
		}
		level = lv;
	}
	objs := array[n] of int;
	pdf_outline = obj_map();
	for(i := 0; i < n; i++)
		objs[i] = obj_map();
	o_flush();
	# the root
	obj_beg(pdf_outline);
	cnt := 0;
	for(i = 0; i < n; i++)
		if(level[i] == level[0])
			cnt++;
	s := "<<\n  /Count " + string cnt + "\n";
	s += "  /First " + string objs[0] + " 0 R\n";
	for(i = n - 1; i > 0 && level[i] > level[0]; i--)
		;
	s += "  /Last " + string objs[i] + " 0 R\n";
	pdfout(s + ">>\n");
	obj_end();
	# the others
	for(i = 0; i < n; i++){
		c := 0;
		j: int;
		for(j = i + 1; j < n && level[j] > level[i]; j++)
			if(level[j] == level[i] + 1)
				c++;
		obj_beg(objs[i]);
		s = "<<\n  /Title " + pdftext_static(desc[i]) + "\n";
		for(j = i - 1; j >= 0 && level[j] >= level[i]; j--)
			;
		if(j >= 0)
			s += "  /Parent " + string objs[j] + " 0 R\n";
		else
			s += "  /Parent " + string pdf_outline + " 0 R\n";
		for(j = i + 1; j < n && level[j] > level[i]; j++)
			;
		if(j < n && level[j] == level[i])
			s += "  /Next " + string objs[j] + " 0 R\n";
		for(j = i - 1; j >= 0 && level[j] > level[i]; j--)
			;
		if(j >= 0 && level[j] == level[i])
			s += "  /Prev " + string objs[j] + " 0 R\n";
		if(c){
			last := 0;
			s += "  /Count " + string c + "\n";
			s += "  /First " + string objs[i + 1] + " 0 R\n";
			for(j = i + 1; j < n && level[j] > level[i]; j++)
				if(level[j] == level[i] + 1)
					last = j;
			s += "  /Last " + string objs[last] + " 0 R\n";
		}
		if(page[i] > 0 && page[i] - 1 < page_n)
			s += "  /Dest [ " + string page_id[page[i] - 1] + " 0 R /XYZ 0 " +
				string (pdf_height - (off[i] * 72 / devres())) + " 0 ]\n";
		pdfout(s + ">>\n");
		obj_end();
	}
}

outinfo(kwd, val: string)
{
	if(len val > 255)
		val = val[0:255];
	case kwd {
	"Author" =>
		pdf_author = val;
	"Title" =>
		pdf_title = val;
	}
}

outset(var, val: string)
{
	case var {
	"linewidth" =>
		pdf_linewid = atoi(val);
	"linecap" =>
		pdf_linecap = atoi(val);
	"linejoin" =>
		pdf_linejoin = atoi(val);
	}
}

# the page's size, in points, from x X papersize; before the first page is done
outpapersize(w, h: int)
{
	if(page_n == 0 && w > 0 && h > 0){
		pdf_width = w;
		pdf_height = h;
	}
}

# font expansion (troff's .mte, x X mtx): the line's glyphs scaled
# horizontally by (1000 + e) / 1000, as troff scaled their advances
o_tz := 0;
p_tz := 0;
p_tzacc := 0;	# the remainder troff carries from glyph to glyph, carried here too

outmtx(e: int)
{
	if(e <= -1000)
		e = 0;
	o_tz = e;
}

outpage()
{
	o_tz = 0;
	p_tz = 0;
	o_v = 0;
	o_h = 0;
	p_i = 0;
	p_v = 0;
	p_h = 0;
	p_s = 0;
	p_f = 0;
	p_m = 0;
	o_i = -1;
}

outmnt(f: int)
{
	if(p_f == f)
		p_f = -1;
}

drawbeg()
{
	o_flush();
	out_fontup();
	pg += pdfpos(o_h, o_v) + " m\n";
}

l_page, l_size, l_wid, l_cap, l_join: int;	# the lines drawn with

drawend(close, fill: int)
{
	if(!fill)
		fill = 2;
	if(l_page != page_n || l_size != o_s || l_wid != pdf_linewid ||
			l_cap != pdf_linecap || l_join != pdf_linejoin){
		lwid := pdf_linewid * o_s;
		pg += sys->sprint("%d.%03d w\n", lwid / 1000, lwid % 1000);
		pg += sys->sprint("%d J %d j\n", pdf_linecap, pdf_linejoin);
		l_page = page_n;
		l_size = o_s;
		l_wid = pdf_linewid;
		l_cap = pdf_linecap;
		l_join = pdf_linejoin;
	}
	if(fill & 2)
		pg += pdfcolor(o_m) + " RG\n";
	if(fill & 1){
		if(fill & 2)
			pg += "b\n";
		else
			pg += "f\n";
	}else if(close)
		pg += "s\n";
	else
		pg += "S\n";
	p_v = 0;
	p_h = 0;
}

drawl(h, v: int)
{
	outrel(h, v);
	pg += pdfpos(o_h, o_v) + " l\n";
}

# a quadrant of a circle or ellipse
drawquad(ch, cv: int)
{
	b := big 551915;
	x0 := big o_h * big 1000;
	y0 := big o_v * big 1000;
	x3 := x0 + big ch * big 1000 / big 2;
	y3 := y0 + big cv * big 1000 / big 2;
	x1 := x0;
	y1 := y0 + big cv * b / big 1000 / big 2;
	x2 := x3 - big ch * b / big 1000 / big 2;
	y2 := y3;
	if((ch > 0 && cv < 0) || (ch < 0 && cv > 0)){
		x1 = x0 + big ch * b / big 1000 / big 2;
		y1 = y0;
		x2 = x3;
		y2 = y3 - big cv * b / big 1000 / big 2;
	}
	pg += pdfpos00(x1 / big 10, y1 / big 10) + " ";
	pg += pdfpos00(x2 / big 10, y2 / big 10) + " ";
	pg += pdfpos00(x3 / big 10, y3 / big 10) + " c\n";
	outrel(ch / 2, cv / 2);
}

drawc(c: int)
{
	drawquad(+c, +c);
	drawquad(+c, -c);
	drawquad(-c, -c);
	drawquad(-c, +c);
	outrel(c, 0);
}

drawe(h, v: int)
{
	drawquad(+h, +v);
	drawquad(+h, -v);
	drawquad(-h, -v);
	drawquad(-h, +v);
	outrel(h, 0);
}

drawa(h1, v1, h2, v2: int)
{
	drawl(h1 + h2, v1 + v2);
}

draws(h1, v1, h2, v2: int)
{
	x0 := o_h;
	y0 := o_v;
	x1 := x0 + h1;
	y1 := y0 + v1;
	x2 := x1 + h2;
	y2 := y1 + v2;
	pg += pdfpos((x0 + 5 * x1) / 6, (y0 + 5 * y1) / 6) + " ";
	pg += pdfpos((x2 + 5 * x1) / 6, (y2 + 5 * y1) / 6) + " ";
	pg += pdfpos((x1 + x2) / 2, (y1 + y2) / 2) + " c\n";
	outrel(h1, v1);
}

docheader(title: string, pagewidth, pageheight, linewidth: int)
{
	if(title != nil)
		outinfo("Title", title);
	obj_map();
	pdf_root = obj_map();
	pdf_pages = obj_map();
	pdfout("%PDF-1.6\n\n");
	pdf_width = (pagewidth * 72 + 127) / 254;
	pdf_height = (pageheight * 72 + 127) / 254;
	pdf_linewid = linewidth;
}

# each page's label: its folio; a page without one numbered on from the
# nearest page before with one (or back from the nearest after), roman
# if that is, else its place
pagelabels(): string
{
	s := "";
	for(i := 0; i < page_n; i++){
		l: string;
		if(i < len pg_label)
			l = pg_label[i];
		if(l == nil)
			l = labelnear(i);
		s += " " + string i + " << /P " + pdftext_static(l) + " >>";
	}
	return s;
}

labelnear(i: int): string
{
	for(j := i - 1; j >= 0; j--)
		if(j < len pg_label && pg_label[j] != nil){
			(n, rom) := folionum(pg_label[j]);
			if(n > 0)
				return foliostr(n + i - j, rom);
			break;
		}
	for(j = i + 1; j < page_n && j < len pg_label; j++)
		if(pg_label[j] != nil){
			(n, rom) := folionum(pg_label[j]);
			if(n - (j - i) > 0)
				return foliostr(n - (j - i), rom);
			break;
		}
	return string (i + 1);
}

romans := array[] of {
	(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"),
	(50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i"),
};

# a folio's number, and whether it is roman (lower case); 0, neither
folionum(f: string): (int, int)
{
	if(f == nil)
		return (0, 0);
	if(f[0] >= '0' && f[0] <= '9'){
		for(i := 0; i < len f; i++)
			if(f[i] < '0' || f[i] > '9')
				return (0, 0);
		return (int f, 0);
	}
	n := 0;
	i := 0;
	for(k := 0; k < len romans && i < len f; ){
		(v, r) := romans[k];
		if(i + len r <= len f && f[i:i + len r] == r){
			n += v;
			i += len r;
		}else
			k++;
	}
	if(i < len f || foliostr(n, 1) != f)
		return (0, 0);
	return (n, 1);
}

foliostr(n: int, rom: int): string
{
	if(!rom)
		return string n;
	s := "";
	for(k := 0; k < len romans; k++){
		(v, r) := romans[k];
		while(n >= v){
			s += r;
			n -= v;
		}
	}
	return s;
}

doctrailer(nil: int)
{
	# the pages
	obj_beg(pdf_pages);
	s := "<<\n  /Type /Pages\n";
	s += "  /MediaBox [ 0 0 " + string pdf_width + " " + string pdf_height + " ]\n";
	s += "  /Count " + string page_n + "\n";
	s += "  /Kids [";
	for(i := 0; i < page_n; i++)
		s += " " + string page_id[i] + " 0 R";
	pdfout(s + " ]\n>>\n");
	obj_end();
	# the root
	obj_beg(pdf_root);
	s = "<<\n  /Type /Catalog\n";
	s += "  /Pages " + string pdf_pages + " 0 R\n";
	if(pdf_dests > 0)
		s += "  /Dests " + string pdf_dests + " 0 R\n";
	if(pdf_outline > 0)
		s += "  /Outlines " + string pdf_outline + " 0 R\n";
	if(pdf_outline > 0 && !compat)
		s += "  /PageMode /UseOutlines\n";
	if(!compat && pg_label != nil)
		s += "  /PageLabels << /Nums [" + pagelabels() + " ] >>\n";
	pdfout(s + ">>\n");
	obj_end();
	pfont_done();
	# the info
	info_id := obj_beg(0);
	s = "<<\n";
	if(pdf_title != "")
		s += "  /Title " + pdftext_static(pdf_title) + "\n";
	if(pdf_author != "")
		s += "  /Author " + pdftext_static(pdf_author) + "\n";
	s += "  /Creator (Neatroff)\n";
	if(compat)
		s += "  /Producer (Neatpost)\n";
	else
		s += "  /Producer (tr2pdf)\n";
	pdfout(s + ">>\n");
	obj_end();
	# the cross-reference table
	xref_off := pdf_pos;
	s = "xref\n0 " + string obj_n + "\n0000000000 65535 f \n";
	for(i = 1; i < obj_n; i++)
		s += sys->sprint("%010d 00000 n \n", obj_off[i]);
	pdfout(s);
	s = "trailer\n<<\n";
	s += "  /Size " + string obj_n + "\n";
	s += "  /Root " + string pdf_root + " 0 R\n";
	s += "  /Info " + string info_id + " 0 R\n";
	s += ">>\nstartxref\n" + string xref_off + "\n%%EOF\n";
	pdfout(s);
}

docpagebeg(nil: int)
{
	pg = "BT\n";
}

docpageend(nil: int)
{
	o_flush();
	pg += "ET\n";
	# the page's contents
	b := array of byte pg;
	cont_id: int;
	if(compat){
		cont_id = obj_beg(0);
		pdfout("<<\n  /Length " + string (len b - 1) + "\n>>\nstream\n");
		pdfmem(b);
		pdfout("endstream\n");
		obj_end();
	}else
		cont_id = writestream("", b);
	# the page
	if(page_n == len page_id)
		page_id = growint(page_id, page_n + 1024);
	page_id[page_n++] = obj_beg(0);
	s := "<<\n  /Type /Page\n";
	s += "  /Parent " + string pdf_pages + " 0 R\n";
	s += "  /Resources <<\n    /Font <<";
	for(i := 0; i < pfonts_n; i++){
		if(o_iset[i] != byte 0){
			ps := pfonts[i];
			if(ps.cid)
				s += " /" + ps.name + " " + string ps.obj + " 0 R";
			else
				s += " /" + ps.name + "." + string ps.sub + " " + string ps.obj + " 0 R";
		}
	}
	s += " >>\n";
	if(xobj_n){
		s += "    /XObject <<";
		for(i = 0; i < xobj_n; i++)
			s += " /FO" + string i + " " + string xobj[i] + " 0 R";
		s += " >>\n";
	}
	s += "  >>\n";
	s += "  /Contents " + string cont_id + " 0 R\n";
	if(ann_n){
		s += "  /Annots [";
		for(i = 0; i < ann_n; i++)
			s += " " + string ann[i] + " 0 R";
		s += " ]\n";
	}
	pdfout(s + ">>\n");
	obj_end();
	pg = nil;
	for(i = 0; i < pfonts_n; i++)
		o_iset[i] = byte 0;
	xobj_n = 0;
	ann_n = 0;
}
