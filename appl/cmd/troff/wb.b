#
# wb.c: word buffers
#

Wb: adt {
	sbuf:	string;
	f, s, m, cd:	int;		# the last output font, size, colour and direction
	r_f, r_s, r_m, r_cd:	int;	# the current ones; nr(R_f) and so on if -1
	part:	int;		# partial input (\c)
	cost:	int;		# the extra cost of a line break after this word
	els_neg, els_pos:	int;	# extra line spacing
	h, v:	int;		# horizontal and vertical positions
	ct, sb, st:	int;	# \w registers
	llx, lly, urx, ury:	int;	# bounding box
	icleft:	int;		# pending left italic correction
	sub_c:	array of string;	# the collected subword
	sub_n:	int;
	sub_collect:	int;	# collect subwords
	pl, pr:	int;		# protrusion of the first and last glyph (.mtp), in units
	pseen:	int;		# anything put yet (a glyph, a move, a drawing)
	gw:	int;		# the glyphs' advances alone (what expansion scales)
};

BBMAX:	con 1 << 29;
BBMIN:	con -BBMAX;

# the escape character in Neatroff's own strings; -1 (.eo) as C writes it
ecc(): int
{
	if(c_ec >= 0)
		return c_ec;
	return 16rff;
}

ecs(): string
{
	return chr(ecc());
}

# \h'nu', with the escape character
eschs := array[8192] of string;
eschs_ec := -1;

esch(n: int): string
{
	if(n < 0 || n >= len eschs)
		return ecs() + "h'" + string n + "u'";
	if(eschs_ec != ecc()){
		eschs = array[len eschs] of string;
		eschs_ec = ecc();
	}
	if(eschs[n] == nil)
		eschs[n] = ecs() + "h'" + string n + "u'";
	return eschs[n];
}

R_F(wb: ref Wb): int
{
	if(wb.r_f >= 0)
		return wb.r_f;
	return nr(R_f);
}

R_S(wb: ref Wb): int
{
	if(wb.r_s >= 0)
		return wb.r_s;
	return nr(R_s);
}

R_M(wb: ref Wb): int
{
	if(wb.r_m >= 0)
		return wb.r_m;
	return nr(R_m);
}

R_CD(wb: ref Wb): int
{
	if(wb.r_cd >= 0)
		return wb.r_cd;
	return nr(R_cd);
}

glyph_ic(g: ref Glyph): int
{
	return max(0, g.urx - g.wid);
}

glyph_icleft(g: ref Glyph): int
{
	return max(0, -g.llx);
}

wb_new(): ref Wb
{
	wb := ref Wb;
	wb_init(wb);
	return wb;
}

wb_init(wb: ref Wb)
{
	wb.sbuf = "";
	wb.part = 0;
	wb.cost = 0;
	wb.els_neg = 0;
	wb.els_pos = 0;
	wb.h = 0;
	wb.v = 0;
	wb.ct = 0;
	wb.sb = 0;
	wb.st = 0;
	wb.icleft = 0;
	wb.pl = 0;
	wb.pr = 0;
	wb.pseen = 0;
	wb.gw = 0;
	wb.sub_n = 0;	# sub_c made when there is something to collect
	wb.sub_collect = 1;
	wb.f = -1;
	wb.s = -1;
	wb.m = -1;
	wb.cd = -1;
	wb.r_f = -1;
	wb.r_s = -1;
	wb.r_m = -1;
	wb.r_cd = -1;
	wb.llx = BBMAX;
	wb.lly = BBMAX;
	wb.urx = BBMIN;
	wb.ury = BBMIN;
}

# update wb.st and wb.sb
wb_stsb(wb: ref Wb)
{
	wb.st = min(wb.st, wb.v - (wb.s * SC_IN() / 72));
	wb.sb = max(wb.sb, wb.v);
}

# update the bounding box
wb_bbox(wb: ref Wb, llx, lly, urx, ury: int)
{
	wb.llx = min(wb.llx, wb.h + llx);
	wb.lly = min(wb.lly, -wb.v + lly);
	wb.urx = max(wb.urx, wb.h + urx);
	wb.ury = max(wb.ury, -wb.v + ury);
}

# pending font, size or colour changes
wb_pendingfont(wb: ref Wb): int
{
	return wb.f != R_F(wb) || wb.s != R_S(wb) ||
		(!nr(R_cp) && wb.m != R_M(wb));
}

# pending direction change
wb_pendingdir(wb: ref Wb): int
{
	return wb.cd != R_CD(wb);
}

# append font and size to the buffer if needed
# the last font, size and colour changes written together, by wb_flushfont()
ffs_f, ffs_s, ffs_m, ffs_ec: int;
ffs: string;

wb_flushfont(wb: ref Wb)
{
	f := R_F(wb);
	sz := R_S(wb);
	if(wb.f != f && wb.s != sz && sz < 100 && !nr(R_cp) && wb.m != (m := R_M(wb))){
		if(ffs == nil || ffs_f != f || ffs_s != sz || ffs_m != m || ffs_ec != ecc()){
			ffs = ecs() + "f(" + d2(f) + ecs() + "s(" + d2(sz) + ecs() + "m[" + clr_str(m) + "]";
			(ffs_f, ffs_s, ffs_m, ffs_ec) = (f, sz, m, ecc());
		}
		wb.sbuf += ffs;
		wb.f = f;
		wb.s = sz;
		wb.m = m;
		wb_stsb(wb);
		return;
	}
	if(wb.f != R_F(wb)){
		wb.sbuf += ecs() + "f(" + d2(R_F(wb));
		wb.f = R_F(wb);
	}
	if(wb.s != R_S(wb)){
		if(R_S(wb) < 100)
			wb.sbuf += ecs() + "s(" + d2(R_S(wb));
		else
			wb.sbuf += sys->sprint("%ss[%d]", ecs(), R_S(wb));
		wb.s = R_S(wb);
	}
	if(!nr(R_cp) && wb.m != R_M(wb)){
		wb.sbuf += ecs() + "m[" + clr_str(R_M(wb)) + "]";
		wb.m = R_M(wb);
	}
	wb_stsb(wb);
}

# append the current text direction to the buffer if needed
wb_flushdir(wb: ref Wb)
{
	if(wb.cd != R_CD(wb)){
		wb_flushsub(wb);
		if(dir_do){
			if(R_CD(wb) > 0)
				wb.sbuf += ecs() + "<";
			else
				wb.sbuf += ecs() + ">";
		}
		wb.cd = R_CD(wb);
	}
}

# apply font and size changes and flush the collected subword
wb_flush(wb: ref Wb)
{
	wb_flushsub(wb);
	wb_flushdir(wb);
	wb_flushfont(wb);
}

# .mg: a character no font mounted has, said once (C Neatroff drops it
# without a word)
mg_warn := 0;
mg_dict: ref Dict;

mg_said(c: string)
{
	if(c == nil || c[0] < 16r20)
		return;
	if(mg_dict == nil)
		mg_dict = dict_make(64);
	if(dict_get(mg_dict, c) >= 0)
		return;
	dict_put(mg_dict, c, 1);
	if(len c == 1)
		sys->fprint(stderr, "troff: no font has %s (U+%.4X)\n", c, c[0]);
	else
		sys->fprint(stderr, "troff: no font has \\(%s\n", c);
}

# protrusion: the first glyph's left, the last's right (.mtp, .mtpc)
wb_prot(wb: ref Wb, g: ref Glyph, gw: int)
{
	if(!nr(R_mtp))
		return;
	(l, r) := font_prot(gfont(g), g);
	if(!wb.pseen)
		wb.pl = l * gw / 1000;
	wb.pseen = 1;
	wb.pr = r * gw / 1000;
}

# not a glyph at the word's edge: a move, a tab, a drawing
wb_noprot(wb: ref Wb)
{
	wb.pseen = 1;
	wb.pr = 0;
}

# the inserted hyphen's right protrusion
wb_hyprot(wb: ref Wb): int
{
	if(!nr(R_mtp))
		return 0;
	g := dev_glyph("hy", wb.f);
	if(g == nil)
		return 0;
	(nil, r) := font_prot(gfont(g), g);
	return r * font_gwid(gfont(g), dev_font(R_F(wb)), R_S(wb), g.wid) / 1000;
}

wb_hmov(wb: ref Wb, n: int)
{
	wb_flushsub(wb);
	wb_noprot(wb);
	wb.h += n;
	wb.sbuf += esch(n);
}

wb_vmov(wb: ref Wb, n: int)
{
	wb_flushsub(wb);
	wb.v += n;
	wb.sbuf += sys->sprint("%sv'%du'", ecs(), n);
}

wb_els(wb: ref Wb, els: int)
{
	wb_flushsub(wb);
	if(els > wb.els_pos)
		wb.els_pos = els;
	if(els < wb.els_neg)
		wb.els_neg = els;
	wb.sbuf += sys->sprint("%sx'%du'", ecs(), els);
}

wb_etc(wb: ref Wb, x: string)
{
	wb_flush(wb);
	wb.sbuf += ecs() + "X\u0002" + x + "\u0002";	# quoted with \002, as Neatroff
}

wb_putbuf(wb: ref Wb, c: string)
{
	c0 := at(c, 0);
	c1 := at(c, 1);
	if(c0 == '\t' || c0 == 1 || (c0 == c_ni && (c1 == '\t' || c1 == 1))){
		wb.sbuf += c;
		wb_noprot(wb);
		return;
	}
	zerowidth := c_hymark(c);
	g: ref Glyph;
	if(!zerowidth)	# else not used
		g = dev_glyph(c, wb.f);
	if(g == nil && c0 == ecc() && !zerowidth){	# an unknown escape
		c = c[1:];
		g = dev_glyph(c, wb.f);
		c0 = at(c, 0);
		c1 = at(c, 1);
	}
	if(g == nil && !zerowidth && mg_warn)
		mg_said(c);
	if(g != nil && !zerowidth && wb.icleft && glyph_icleft(g))
		wb_hmov(wb, font_wid(gfont(g), wb.s, glyph_icleft(g)));
	wb.icleft = 0;
	if(len c <= 1 || c0 == ecc() || c0 == c_ni){
		if(c0 == c_ni && c1 == ecc())
			wb.sbuf += ecs() + ecs();
		else
			wb.sbuf += c;
	}else if(len c == 2 && c0 < 16r80 && c1 < 16r80)
		wb.sbuf += ecs() + "(" + c;
	else
		wb.sbuf += ecs() + "C'" + c + "'";
	if(!zerowidth){
		gf: ref Font;
		if(g != nil)
			gf = gfont(g);
		if(!nr(R_cp) && g != nil){
			if(g.llx || g.lly || g.urx || g.ury){
				llx := font_wid(gf, wb.s, g.llx);
				lly := font_wid(gf, wb.s, g.lly);
				urx := font_wid(gf, wb.s, g.urx);
				ury := font_wid(gf, wb.s, g.ury);
				wb_bbox(wb, llx, lly, urx, ury);
			}else{	# no bounding box information
				ht := wb.s * SC_PT();
				urx := font_wid(gf, wb.s, g.wid);
				lly := 0;
				if(g.typ & 1)
					lly = -ht / 2;
				ury := ht / 2;
				if(g.typ & 2)
					ury = ht;
				wb_bbox(wb, 0, lly, urx, ury);
			}
		}
		if(g != nil){
			gw := font_gwid(gf, dev_font(wb.f), wb.s, g.wid);
			wb.h += gw;
			wb.gw += gw;
			wb.ct |= g.typ;
			wb_prot(wb, g, gw);
		}else
			wb_noprot(wb);
		wb_stsb(wb);
	}
}

# the hyphenation points of src[0:src_n] in src_hyph; nonzero if it cannot be hyphenated
wb_hyph(src: array of string, src_n: int, src_hyph: array of int, flg: int): int
{
	word := "";
	smap := array[src_n] of {* => 0};
	for(i := 0; i < src_n; i++){
		s := src[i];
		smap[i] = len word;
		if(c_hystop(s))
			return 1;
		if(c_hymark(s))
			continue;
		if(len s == 1)
			word[len word] = s[0];
		else
			word += hy_cput(s);
	}
	hyph := array[len word + 1] of {* => 0};
	hyphenate(hyph, word, flg);
	for(i = 0; i < src_n; i++)
		src_hyph[i] = hyph[smap[i]];
	return 0;
}

wb_collect(wb: ref Wb, val: int): int
{
	old := wb.sub_collect;
	wb.sub_collect = val;
	return old;
}

# wb_flushsub()'s buffers
fs_hyph, fs_x, fs_y, fs_xadv, fs_yadv, fs_dmap: array of int;
fs_gsrc, fs_gdst: array of ref Glyph;

# output the collected characters; only for those present in the wb.f font
wb_flushsub(wb: ref Wb)
{
	if(!wb.sub_n || !wb.sub_collect)
		return;
	wb.sub_collect = 0;
	fnt := dev_font(wb.f);
	if(fs_hyph == nil){
		fs_hyph = array[WORDLEN] of {* => 0};
		fs_gsrc = array[WORDLEN] of ref Glyph;
		fs_gdst = array[WORDLEN] of ref Glyph;
		fs_x = array[WORDLEN] of {* => 0};
		fs_y = array[WORDLEN] of {* => 0};
		fs_xadv = array[WORDLEN] of {* => 0};
		fs_yadv = array[WORDLEN] of {* => 0};
		fs_dmap = array[WORDLEN] of {* => 0};
	}
	src_hyph := fs_hyph;
	for(k := 0; k < wb.sub_n; k++)
		src_hyph[k] = 0;
	if(nr(R_hy) && wb_hyph(wb.sub_c, wb.sub_n, src_hyph, nr(R_hy)))
		for(k = 0; k < wb.sub_n; k++)
			src_hyph[k] = 0;
	gsrc := fs_gsrc;
	gdst := fs_gdst;
	x := fs_x;
	y := fs_y;
	xadv := fs_xadv;
	yadv := fs_yadv;
	dmap := fs_dmap;
	cd := wb.cd;
	if(cd < 0)
		cd = 0;
	# call font_layout() for collected glyphs; skip hyphenation marks
	sidx := 0;
	while(sidx < wb.sub_n){
		beg := sidx;
		for(; sidx < wb.sub_n && !c_hymark(wb.sub_c[sidx]); sidx++)
			gsrc[sidx - beg] = font_find(fnt, wb.sub_c[sidx]);
		dst_n := font_layout(fnt, gsrc, sidx - beg, wb.s,
				gdst, dmap, x, y, xadv, yadv, nr(R_lg), nr(R_kn));
		for(i := 0; i < dst_n; i++){
			xd0 := x[i];
			xd1 := xadv[i] - x[i];
			yd0 := y[i];
			yd1 := yadv[i] - y[i];
			xa := xd0;
			xb := xd1;
			ya := yd0;
			yb := yd1;
			if(cd){
				xa = xd1;
				xb = xd0;
				ya = yd1;
				yb = yd0;
			}
			if(xa)
				wb_hmov(wb, font_wid(fnt, wb.s, xa));
			if(ya)
				wb_vmov(wb, font_wid(fnt, wb.s, ya));
			if(src_hyph[beg + dmap[i]])
				wb_putbuf(wb, env_hc());
			if(gdst[i] == gsrc[dmap[i]])
				wb_putbuf(wb, wb.sub_c[beg + dmap[i]]);
			else
				wb_putbuf(wb, gdst[i].name);
			if(xb)
				wb_hmov(wb, font_wid(fnt, wb.s, xb));
			if(yb)
				wb_vmov(wb, font_wid(fnt, wb.s, yb));
		}
		for(; sidx < wb.sub_n && c_hymark(wb.sub_c[sidx]); sidx++)
			wb_putbuf(wb, wb.sub_c[sidx]);
	}
	wb.sub_n = 0;
	wb.icleft = 0;
	wb.sub_collect = 1;
}

wb_put(wb: ref Wb, c: string)
{
	if(at(c, 0) == '\n'){
		wb.part = 0;
		return;
	}
	if(wb_pendingdir(wb))
		wb_flushdir(wb);
	if(at(c, 0) == ' '){
		wb_flushsub(wb);
		wb_hmov(wb, font_swid(dev_font(R_F(wb)), R_S(wb), nr(R_ss)));
		return;
	}
	if(c == c_nb){
		wb_flushsub(wb);
		wb.sbuf += c;
		wb.h += font_swid(dev_font(R_F(wb)), R_S(wb), nr(R_ss));
		return;
	}
	if(wb_pendingfont(wb) || wb.sub_n == WORDLEN)
		wb_flush(wb);
	if(wb.sub_collect){
		if(font_find(dev_font(wb.f), c) != nil || c_hymark(c)){
			if(wb.sub_c == nil)
				wb.sub_c = array[WORDLEN] of string;
			wb.sub_c[wb.sub_n++] = c;
		}
		else
			wb_putraw(wb, c);
	}else
		wb_putbuf(wb, c);
}

# just like wb_put() but disable subword collection
wb_putraw(wb: ref Wb, c: string)
{
	wb_flushsub(wb);
	collect := wb_collect(wb, 0);
	wb_put(wb, c);
	wb_collect(wb, collect);
}

# just like wb_put(), but call cdef_expand() if c is defined
wb_putexpand(wb: ref Wb, c: string)
{
	if(cdef_expand(wb, c, R_F(wb)))
		wb_put(wb, c);
}

wb_part(wb: ref Wb): int
{
	return wb.part;
}

wb_setpart(wb: ref Wb)
{
	wb.part = 1;
}

wb_cost(wb: ref Wb): int
{
	return wb.cost;
}

wb_setcost(wb: ref Wb, cost: int)
{
	wb.cost = cost;
}

wb_drawl(wb: ref Wb, c: int, h, v: int)
{
	wb_flush(wb);
	wb_noprot(wb);
	wb.sbuf += sys->sprint("%sD'%c %du %du'", ecs(), c, h, v);
	wb.h += h;
	wb.v += v;
	wb_stsb(wb);
}

wb_drawc(wb: ref Wb, c: int, r: int)
{
	wb_flush(wb);
	wb_noprot(wb);
	wb.sbuf += sys->sprint("%sD'%c %du'", ecs(), c, r);
	wb.h += r;
}

wb_drawe(wb: ref Wb, c: int, h, v: int)
{
	wb_flush(wb);
	wb_noprot(wb);
	wb.sbuf += sys->sprint("%sD'%c %du %du'", ecs(), c, h, v);
	wb.h += h;
}

wb_drawa(wb: ref Wb, c: int, h1, v1, h2, v2: int)
{
	wb_flush(wb);
	wb_noprot(wb);
	wb.sbuf += sys->sprint("%sD'%c %du %du %du %du'", ecs(), c, h1, v1, h2, v2);
	wb.h += h1 + h2;
	wb.v += v1 + v2;
	wb_stsb(wb);
}

wb_drawxbeg(wb: ref Wb, c: int)
{
	wb_flush(wb);
	wb_noprot(wb);
	wb.sbuf += sys->sprint("%sD'%c", ecs(), c);
}

wb_drawxdot(wb: ref Wb, h, v: int)
{
	wb.sbuf += sys->sprint(" %du %du", h, v);
	wb.h += h;
	wb.v += v;
	wb_stsb(wb);
}

wb_drawxcmd(wb: ref Wb, cmd: string)
{
	wb.sbuf += " " + cmd;
}

wb_drawxend(wb: ref Wb)
{
	wb.sbuf += "'";
}

wb_reset(wb: ref Wb)
{
	wb_init(wb);
}

wb_buf(wb: ref Wb): string
{
	wb_flushsub(wb);
	return wb.sbuf;
}

wb_putc(wb: ref Wb, t: int, s: string)
{
	if(t && t != 'C')
		wb_flushsub(wb);
	case t {
	0 or 'C' =>
		wb_put(wb, s);
	'D' =>
		ren_dcmd(wb, s);
	'f' =>
		wb.r_f = atoi(s);
	'h' =>
		wb_hmov(wb, atoi(s));
	'm' =>
		wb.r_m = clr_get(s);
	's' =>
		wb.r_s = atoi(s);
	'v' =>
		wb_vmov(wb, atoi(s));
	'x' =>
		wb_els(wb, atoi(s));
	'X' =>
		wb_etc(wb, s);
	'<' or '>' =>
		wb.r_cd = t == '<';
		wb_flushdir(wb);
	}
}

wb_cat(wb: ref Wb, src: ref Wb)
{
	wb_flushsub(src);
	wb_flushsub(wb);
	collect := wb_collect(wb, 0);
	s := src.sbuf;
	i := 0;
	for(;;){
		(c, d, ni) := escread(s, i);
		if(c < 0)
			break;
		i = ni;
		wb_putc(wb, c, d);
	}
	part := src.part;
	wb.r_s = -1;
	wb.r_f = -1;
	wb.r_m = -1;
	wb.r_cd = -1;
	wb_reset(src);
	src.part = part;
	wb_collect(wb, collect);
}

wb_wid(wb: ref Wb): int
{
	wb_flushsub(wb);
	return wb.h;
}

wb_hpos(wb: ref Wb): int
{
	wb_flushsub(wb);
	return wb.h;
}

wb_vpos(wb: ref Wb): int
{
	wb_flushsub(wb);
	return wb.v;
}

wb_empty(wb: ref Wb): int
{
	return !wb.sub_n && wb.sbuf == nil;
}

# whether wb ends a sentence (.?!)
wb_eos(wb: ref Wb): int
{
	i := wb.sub_n - 1;
	while(i > 0 && c_eostran(wb.sub_c[i]))
		i--;
	return i >= 0 && c_eossent(wb.sub_c[i]);
}

wb_wconf(wb: ref Wb)
{
	wb_flushsub(wb);
	nrset(R_ct, wb.ct);
	nrset(R_st, -wb.st);
	nrset(R_sb, -wb.sb);
	if(wb.llx < BBMAX)
		nrset(R_llx, wb.llx);
	else
		nrset(R_llx, 0);
	if(wb.lly < BBMAX)
		nrset(R_lly, -wb.lly);
	else
		nrset(R_lly, 0);
	if(wb.urx > BBMIN)
		nrset(R_urx, wb.urx);
	else
		nrset(R_urx, 0);
	if(wb.ury > BBMIN)
		nrset(R_ury, -wb.ury);
	else
		nrset(R_ury, 0);
}

wb_prevglyph(wb: ref Wb): ref Glyph
{
	if(wb.sub_n)
		return dev_glyph(wb.sub_c[wb.sub_n - 1], wb.f);
	return nil;
}

wb_italiccorrection(wb: ref Wb)
{
	g := wb_prevglyph(wb);
	if(g != nil && glyph_ic(g))
		wb_hmov(wb, font_wid(gfont(g), wb.s, glyph_ic(g)));
}

wb_italiccorrectionleft(wb: ref Wb)
{
	wb_flushsub(wb);
	wb.icleft = 1;
}

wb_fnszget(wb: ref Wb): (int, int, int, int)
{
	wb_flushsub(wb);
	return (wb.r_f, wb.r_s, wb.r_m, wb.r_cd);
}

wb_fnszset(wb: ref Wb, fnt, sz, m, cd: int)
{
	wb.r_f = fnt;
	wb.r_s = sz;
	wb.r_m = m;
	wb.r_cd = cd;
}

# append s[beg:end] to wb
wb_catstr(wb: ref Wb, s: string, beg, end: int)
{
	wb_flushsub(wb);
	collect := wb_collect(wb, 0);
	i := beg;
	while(i < end){
		(c, d, ni) := escread(s, i);
		if(c < 0)
			break;
		i = ni;
		wb_putc(wb, c, d);
	}
	wb_collect(wb, collect);
}

# the width of \(hy if appended to wb
wb_hywid(wb: ref Wb): int
{
	g := dev_glyph("hy", wb.f);
	if(g != nil)
		return font_gwid(gfont(g), dev_font(R_F(wb)), R_S(wb), g.wid);
	return 0;
}

# the width of a space if appended to wb
wb_swid(wb: ref Wb): int
{
	return font_swid(dev_font(R_F(wb)), R_S(wb), nr(R_ss));
}

keshideh_chars := array[] of {
	"ﺒ", "ﺑ", "ﭙ", "ﭘ", "ﺘ", "ﺗ", "ﺜ", "ﺛ", "ﺴ", "ﺳ",
	"ﺸ", "ﺷ", "ﻔ", "ﻓ", "ﻘ", "ﻗ", "ﮑ", "ﮐ", "ﮕ", "ﮔ",
	"ﻤ", "ﻣ", "ﻨ", "ﻧ", "ﻬ", "ﻫ", "ﯿ", "ﯾ",
};

keshideh(c: string): int
{
	for(i := 0; i < len keshideh_chars; i++)
		if(keshideh_chars[i] == c)
			return 1;
	return 0;
}

# insert a keshideh into word, writing it to dst; returns its width
wb_keshideh(word: string, dst: ref Wb, wid: int): int
{
	p := "";
	ins := 0;
	s_prev := -1;
	s_kesh := -1;
	# find the last keshideh position
	s := 0;
	for(;;){
		(c, d, ni) := escread(word, s);
		if(c < 0)
			break;
		s = ni;
		wb_putc(dst, c, d);
		if(!c && keshideh(p)){
			g := dev_glyph("ـ", R_F(dst));
			kw := 0;
			if(g != nil)
				kw = font_gwid(gfont(g), dev_font(R_F(dst)), R_S(dst), g.wid);
			if(g != nil && kw < wid){
				s_kesh = s_prev;
				ins = kw;
			}
		}
		s_prev = s;
		if(c)
			p = "";
		else
			p = d;
	}
	# insert the keshideh at s_kesh
	wb_reset(dst);
	s = 0;
	for(;;){
		(c, d, ni) := escread(word, s);
		if(c < 0)
			break;
		s = ni;
		wb_putc(dst, c, d);
		if(s == s_kesh)
			wb_putc(dst, 0, "ـ");
	}
	return ins;
}
