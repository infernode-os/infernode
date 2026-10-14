#
# font.c and dev.c: the device and its fonts
#

NFONTS: con 1024;

dev_dir: string;	# the device directory
dev_dev: string;	# and its name
dev_res := 0;		# resolution

# the resolution, which troff's output gives with its device (x T)
# before it draws or sets anything: a zero divide in Neatpost without one
devres(): int
{
	if(dev_res <= 0){
		sys->fprint(sys->fildes(2), "tr2pdf: no device (x T and x res) before the page\n");
		raise "fail:no device";
	}
	return dev_res;
}
dev_uwid := 0;		# unitwidth
dev_hor := 0;
dev_vert := 0;

fn_name := array[NFONTS] of string;	# mounted fonts
fn_font := array[NFONTS] of ref Font;
fn_n := 0;

Glyph: adt {
	id:	string;		# the device's name for it
	name:	string;		# the first character it is
	fnt:	cyclic ref Font;
	idx:	int;		# its index in the font
	wid:	int;
	typ:	int;
	pos:	int;
};

Font: adt {
	name:		string;
	desc:		string;		# the description's path
	fontname:	string;
	fontpath:	string;
	spacewid:	int;
	gl:		array of ref Glyph;
	gl_n:		int;
	gl_dict:	ref Dict;	# by id
	ch_dict:	ref Dict;	# by character
	ch_map:		ref Dict;	# by alias
};

# a dictionary; of the same keys, the last put is got
Dict: adt {
	b:	array of list of (string, int);

	put:	fn(d: self ref Dict, k: string, v: int);
	get:	fn(d: self ref Dict, k: string): int;
};

dict_make(): ref Dict
{
	return ref Dict(array[1024] of list of (string, int));
}

dict_hash(k: string, n: int): int
{
	h := 0;
	for(i := 0; i < len k; i++)
		h = (h * 33 + k[i]) & 16r7fffffff;
	return h % n;
}

Dict.put(d: self ref Dict, k: string, v: int)
{
	h := dict_hash(k, len d.b);
	d.b[h] = (k, v) :: d.b[h];
}

Dict.get(d: self ref Dict, k: string): int
{
	for(l := d.b[dict_hash(k, len d.b)]; l != nil; l = tl l)
		if((hd l).t0 == k)
			return (hd l).t1;
	return -1;
}

# a description file's text, read as fscanf reads it
Scan: adt {
	s:	string;
	i:	int;

	word:	fn(t: self ref Scan, max: int): string;
	num:	fn(t: self ref Scan): (int, int);
	tilleol:	fn(t: self ref Scan): string;
	skipline:	fn(t: self ref Scan);
};

scan_open(path: string): ref Scan
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
	return ref Scan(string b[0:n], 0);
}

# %s, at most max characters; nil at the end
Scan.word(t: self ref Scan, max: int): string
{
	while(t.i < len t.s && isspace(t.s[t.i]))
		t.i++;
	if(t.i >= len t.s)
		return nil;
	b := t.i;
	while(t.i < len t.s && !isspace(t.s[t.i]) && t.i - b < max)
		t.i++;
	return t.s[b:t.i];
}

# %d; and whether there was one
Scan.num(t: self ref Scan): (int, int)
{
	while(t.i < len t.s && isspace(t.s[t.i]))
		t.i++;
	b := t.i;
	if(t.i < len t.s && (t.s[t.i] == '-' || t.s[t.i] == '+'))
		t.i++;
	if(t.i >= len t.s || !isdigit(t.s[t.i])){
		t.i = b;
		return (0, 0);
	}
	while(t.i < len t.s && isdigit(t.s[t.i]))
		t.i++;
	return (atoi(t.s[b:t.i]), 1);
}

Scan.tilleol(t: self ref Scan): string
{
	b := t.i;
	while(t.i < len t.s && t.s[t.i] != '\n')
		t.i++;
	return t.s[b:t.i];
}

Scan.skipline(t: self ref Scan)
{
	while(t.i < len t.s && t.s[t.i] != '\n')
		t.i++;
	if(t.i < len t.s)
		t.i++;
}

GNLEN: con 31;	# a glyph's name, as %31s reads it

font_find(fnt: ref Font, name: string): ref Glyph
{
	i := fnt.ch_dict.get(name);
	if(i < 0)	# an alias, perhaps
		i = fnt.ch_map.get(name);
	if(i >= 0)
		return fnt.gl[i];
	return nil;
}

font_glyph(fnt: ref Font, id: string): ref Glyph
{
	i := fnt.gl_dict.get(id);
	if(i >= 0)
		return fnt.gl[i];
	return nil;
}

font_glyphput(fnt: ref Font, id, name: string, typ: int): int
{
	if(fnt.gl_n == len fnt.gl){
		n := array[len fnt.gl + 1024] of ref Glyph;
		n[0:] = fnt.gl[0:fnt.gl_n];
		fnt.gl = n;
	}
	g := ref Glyph(id, name, fnt, fnt.gl_n, 0, typ, 0);
	fnt.gl[fnt.gl_n] = g;
	fnt.gl_dict.put(id, fnt.gl_n);
	return fnt.gl_n++;
}

# a char line; and whether there was none
font_readchar(fnt: ref Font, t: ref Scan, n, gid: int): (int, int, int)
{
	name := t.word(GNLEN);
	tok := t.word(127);
	if(name == nil || tok == nil)
		return (1, n, gid);
	if(name == "---")
		name = sys->sprint("c%04d", n);
	if(tok != "\""){
		(typ, ok) := t.num();
		if(!ok)
			return (1, n, gid);
		id := t.word(GNLEN);
		if(id == nil)
			return (1, n, gid);
		gid = font_glyphput(fnt, id, name, typ);
		g := fnt.gl[gid];
		(w, wok) := (ref Scan(tok, 0)).num();
		if(wok)
			g.wid = w;
		(p, pok) := (ref Scan(t.tilleol(), 0)).num();
		if(pok)
			g.pos = p;
		fnt.ch_dict.put(name, gid);
		n++;
	}else
		fnt.ch_map.put(name, gid);
	return (0, n, gid);
}

font_open(path: string): ref Font
{
	t := scan_open(path);
	if(t == nil)
		return nil;
	fnt := ref Font("", path, "", "", 0, nil, 0, dict_make(), dict_make(), dict_make());
	ch_g := -1;	# the last glyph
	ch_n := 0;	# the glyphs
	while((tok := t.word(127)) != nil){
		case tok {
		"char" =>
			(nil, ch_n, ch_g) = font_readchar(fnt, t, ch_n, ch_g);
		"spacewidth" =>
			(fnt.spacewid, nil) = t.num();
		"name" =>
			fnt.name = t.word(1 << 20);
		"fontname" =>
			fnt.fontname = t.word(1 << 20);
		"fontpath" =>
			while(t.i < len t.s && t.s[t.i] == ' ')
				t.i++;
			fnt.fontpath = t.tilleol();
		"ligatures" =>
			while((tok = t.word(1 << 20)) != nil)
				if(tok == "0")
					break;
		"charset" =>
			for(;;){
				e: int;
				(e, ch_n, ch_g) = font_readchar(fnt, t, ch_n, ch_g);
				if(e)
					break;
			}
			return fnt;
		}
		t.skipline();
	}
	return fnt;
}

font_wid(nil: ref Font, sz: int, w: int): int
{
	return (w * sz + dev_uwid / 2) / dev_uwid;
}

font_swid(fnt: ref Font, sz: int): int
{
	return font_wid(fnt, sz, fnt.spacewid);
}

font_name(fnt: ref Font): string
{
	if(fnt.fontname != "")
		return fnt.fontname;
	return fnt.name;
}

font_glget(fnt: ref Font, id: int): ref Glyph
{
	if(id >= 0 && id < fnt.gl_n)
		return fnt.gl[id];
	return nil;
}

dev_fontopen(name: string): ref Font
{
	if(strchr(name, '/') >= 0)
		return font_open(name);
	return font_open(dev_dir + "/dev" + dev_dev + "/" + name);
}

dev_mnt(pos: int, id, name: string): int
{
	if(pos < 0 || pos >= NFONTS)
		return -1;
	fnt := dev_fontopen(name);
	if(fnt == nil)
		return -1;
	fn_name[pos] = id;
	fn_font[pos] = fnt;
	return pos;
}

dev_open(dir, dev: string): int
{
	dev_dir = dir;
	dev_dev = dev;
	t := scan_open(dir + "/dev" + dev + "/DESC");
	if(t == nil)
		return 1;
	while((tok := t.word(127)) != nil){
		if(tok[0] == '#'){
			t.skipline();
			continue;
		}
		case tok {
		"fonts" =>
			(fn_n, nil) = t.num();
			for(i := 0; i < fn_n && i + 1 < NFONTS; i++)
				fn_name[i + 1] = t.word(1 << 20);
			fn_n++;
			continue;
		"sizes" =>
			while((tok = t.word(127)) != nil)
				if(tok == "0")
					break;
			continue;
		"res" =>
			(dev_res, nil) = t.num();
			continue;
		"unitwidth" =>
			(dev_uwid, nil) = t.num();
			continue;
		"hor" =>
			(dev_hor, nil) = t.num();
			continue;
		"vert" =>
			(dev_vert, nil) = t.num();
			continue;
		"charset" =>
			return 0;
		}
		t.skipline();
	}
	return 0;
}

dev_glyph(c: string, f: int): ref Glyph
{
	if(f < 0 || f >= NFONTS || fn_font[f] == nil)
		return nil;
	if(len c >= 4 && c[0:4] == "GID=")
		return font_glyph(fn_font[f], c[4:]);
	return font_find(fn_font[f], c);
}

dev_font(pos: int): ref Font
{
	if(pos >= 0 && pos < NFONTS)
		return fn_font[pos];
	return nil;
}
