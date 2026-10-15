#
# dev.c: the output device
#

dev_dir: string;	# device directory
dev_dev: string;	# output device name
dev_res := 0;		# device resolution
dev_uwid := 0;		# device unitwidth
dev_hor := 0;		# minimum horizontal movement
dev_vert := 0;		# minimum vertical movement

fn_name := array[NFONTS] of string;	# mounted font names
fn_font := array[NFONTS] of ref Font;	# and the fonts
fn_n := 0;				# the number of device fonts

fn_special := array[NFONTS] of array of int;	# .fspecial fonts

dev_prologue()
{
	out("x T " + dev_dev + "\n");
	out(sys->sprint("x res %d %d %d\n", dev_res, dev_hor, dev_vert));
	out("x init\n");
}

# a position for the given font
dev_position(id: string): int
{
	for(i := 1; i < NFONTS; i++)	# already mounted
		if(fn_name[i] == id)
			return i;
	for(i = 1; i < NFONTS; i++)	# the first empty position
		if(fn_font[i] == nil)
			return i;
	return 0;			# no room left
}

dev_mnt(pos: int, id, name: string): int
{
	if(pos >= NFONTS)
		return -1;
	path: string;
	if(strchr(name, '/') >= 0)
		path = name;
	else
		path = dev_dir + "/dev" + dev_dev + "/" + name;
	fnt := font_open(path);
	if(fnt == nil)
		return -1;
	if(pos < 0)
		pos = dev_position(id);
	fn_name[pos] = id;
	fn_font[pos] = fnt;
	fn_ver++;	# dev_fontpos()'s are out of date
	out(sys->sprint("x font %d %s\n", pos, name));
	return pos;
}

# the tokens of a device or font description file
Toks: adt {
	f:	ref Iobuf;
	s:	string;		# the current line
	i:	int;
	eof:	int;

	tok:	fn(t: self ref Toks): string;
	line:	fn(t: self ref Toks): int;
	skip:	fn(t: self ref Toks);
	rest:	fn(t: self ref Toks): string;
	num:	fn(t: self ref Toks): (int, int);
};

toks_open(path: string): ref Toks
{
	f := bufio->open(path, Bufio->OREAD);
	if(f == nil)
		return nil;
	return ref Toks(f, nil, 0, 0);
}

# the next whitespace-separated token, or nil at the end (fscanf("%s"))
Toks.tok(t: self ref Toks): string
{
	for(;;){
		while(t.i < len t.s && isspace(t.s[t.i]))
			t.i++;
		if(t.i < len t.s)
			break;
		if(t.eof || !t.line())
			return nil;
	}
	b := t.i;
	while(t.i < len t.s && !isspace(t.s[t.i]))
		t.i++;
	return t.s[b:t.i];
}

# read the next line
Toks.line(t: self ref Toks): int
{
	t.s = t.f.gets('\n');
	t.i = 0;
	if(t.s == nil){
		t.eof = 1;
		return 0;
	}
	return 1;
}

# skip what is left of the line (skipline())
Toks.skip(t: self ref Toks)
{
	if(t.i < len t.s){
		t.i = len t.s;
		return;
	}
	# at its end the newline has been read already; nothing to skip
}

# the rest of the line, newline included (fgets())
Toks.rest(t: self ref Toks): string
{
	if(t.i >= len t.s && !t.line())
		return nil;
	r := t.s[t.i:];
	t.i = len t.s;
	return r;
}

# a number (fscanf("%d")); and whether there was one
Toks.num(t: self ref Toks): (int, int)
{
	s := t.tok();
	if(s == nil)
		return (0, 0);
	return (atoi(s), 1);
}

dev_open(dir, dev: string): int
{
	dev_dir = dir;
	dev_dev = dev;
	desc := toks_open(dir + "/dev" + dev + "/DESC");
	if(desc == nil)
		return 1;
	for(i := 0; i < NFONTS; i++)
		fn_special[i] = array[NFONTSPCL] of {* => 0};
	while((tok := desc.tok()) != nil){
		if(tok[0] == '#'){
			desc.skip();
			continue;
		}
		case tok {
		"fonts" =>
			(fn_n, nil) = desc.num();
			for(i = 0; i < fn_n && i + 1 < NFONTS; i++)
				fn_name[i + 1] = desc.tok();
			fn_n++;
			continue;
		"sizes" =>
			while((tok = desc.tok()) != nil)
				if(tok == "0")
					break;
			continue;
		"res" =>
			(dev_res, nil) = desc.num();
			continue;
		"unitwidth" =>
			(dev_uwid, nil) = desc.num();
			continue;
		"hor" =>
			(dev_hor, nil) = desc.num();
			continue;
		"vert" =>
			(dev_vert, nil) = desc.num();
			continue;
		}
		if(tok == "charset")
			break;
		desc.skip();
	}
	desc.f.close();
	dev_prologue();
	for(i = 0; i < fn_n && i < NFONTS; i++){
		if(fn_name[i] != nil && dev_mnt(i, fn_name[i], fn_name[i]) < 0){
			errmsg("troff: font " + fn_name[i] + " is missing\n");
			return 1;
		}
	}
	return 0;
}

dev_close()
{
	out("x trailer\n");
	out("x stop\n");
}

# find a glyph by name or by id in fnt, its specials and the special fonts
dev_find(c: string, fnt: int, byid: int): ref Glyph
{
	g: ref Glyph;
	if((f := dev_font(fnt)) != nil){
		if(byid)
			g = font_glyph(f, c);
		else
			g = font_find(f, c);
		if(g != nil)
			return g;
		for(i := 0; i < NFONTSPCL && fn_special[fnt][i] > 0; i++){
			sf := dev_font(fn_special[fnt][i]);
			if(sf == nil)
				continue;
			if(byid)
				g = font_glyph(sf, c);
			else
				g = font_find(sf, c);
			if(g != nil)
				return g;
		}
	}
	for(i := 0; i < NFONTS; i++)
		if(fn_font[i] != nil && font_special(fn_font[i])){
			sf := dev_font(i);
			if(byid)
				g = font_glyph(sf, c);
			else
				g = font_find(sf, c);
			if(g != nil)
				return g;
		}
	return nil;
}

dev_glyph(c: string, fnt: int): ref Glyph
{
	if((at(c, 0) == c_ec || at(c, 0) == c_ni) && at(c, 1) == c_ec)
		c = c[1:];
	if(at(c, 0) == c_ec && at(c, 1) == '(')
		c = c[2:];
	c = cmap_map(c);
	if(len c >= 4 && c[0:4] == "GID=")
		return dev_find(c[4:], fnt, 1);
	return dev_find(c, fnt, 0);
}

# the mounted position of a font
dev_pos(id: string): int
{
	if(isdigit(at(id, 0))){
		num := atoi(id);
		if(num < 0 || num >= NFONTS || fn_font[num] == nil){
			errmsg("troff: bad font position " + id + "\n");
			return -1;
		}
		return num;
	}
	for(i := 1; i < NFONTS; i++)
		if(fn_name[i] == id)
			return i;
	if(fn_name[0] == id)
		return 0;
	return dev_mnt(0, id, id);
}

# the mounted position of a font
fn_ver := 1;	# changed with fn_font

dev_fontpos(fnt: ref Font): int
{
	if(fnt != nil && fnt.fposv == fn_ver)
		return fnt.fpos;
	for(i := 0; i < NFONTS; i++)
		if(fn_font[i] == fnt)
			break;
	if(i == NFONTS)
		i = 0;
	if(fnt != nil){
		fnt.fpos = i;
		fnt.fposv = fn_ver;
	}
	return i;
}

# the font at pos, read if it has not been
dev_font(pos: int): ref Font
{
	if(pos >= 0 && pos < NFONTS){
		f := fn_font[pos];
		if(f != nil && !f.loaded)
			font_load(f);
		return f;
	}
	return nil;
}

tr_fspecial(args: array of string)
{
	fnt := 0;
	if(len args > 1)
		fnt = dev_pos(args[1]);
	if(fnt <= 0)
		return;
	cnt := 0;
	for(i := 2; i < NARGS && i < len args; i++){
		spcl := dev_pos(args[i]);
		if(spcl > 0 && cnt < NFONTSPCL)
			fn_special[fnt][cnt++] = spcl;
	}
	if(cnt < NFONTSPCL)
		fn_special[fnt][cnt] = 0;
}
