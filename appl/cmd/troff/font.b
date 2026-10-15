#
# font.c: fonts, their glyphs, and OpenType substitution and positioning
#
# A font is mounted by reading the header of its description; its
# glyphs and rules are read the first time it is used (font_load()),
# so a document pays only for the fonts it sets in.  Its rules are
# kept in one set of arrays (Rules) and found through per-glyph
# indices built once they are all read (Csr).
#

Glyph: adt {
	id:	string;		# device-dependent glyph identifier
	name:	string;		# the first character mapped to this glyph
	fid:	int;		# the glyph's font, its index in allfonts
	idx:	int;		# its index in its font's gl
	wid:	int;		# character width
	llx, lly, urx, ury:	int;	# bounding box
	typ:	int;		# character type; ascender/descender
};

# flags for patterns
GF_PAT:	con 1;		# a gsub/gpos pattern glyph
GF_REP:	con 2;		# a gsub replacement glyph
GF_CON:	con 4;		# a context glyph
GF_GRP:	con 8;		# a glyph group

# glyph substitution or positioning rules; rule r's patterns are off[r] to off[r+1]
Rules: adt {
	n:	int;		# the number of rules
	off:	array of int;
	sec:	array of int;	# rule section (OFF lookup)
	feat:	array of int;	# the rule's feature, script and language
	scrp:	array of int;
	lang:	array of int;
	npat:	int;		# the number of patterns
	g:	array of int;	# pattern glyph (or group)
	flg:	array of int;	# its GF_* flags
	x, y, xadv, yadv:	array of int;	# gpos data (nil for gsub)
};

# a set of integers for each key, in compressed rows
Csr: adt {
	start:	array of int;	# key k's members are ent[start[k]:start[k+1]]
	ent:	array of int;
};

Font: adt {
	path:		string;
	loaded:		int;		# glyphs and rules read
	id:		int;		# its index in allfonts
	name:		string;
	fontname:	string;
	spacewid:	int;
	special:	int;
	cs, cs_ps, bd, zoom:	int;	# for .cs, .bd and .fzoom
	s1, n1, s2, n2:	int;		# for .tkf
	gl:		array of ref Glyph;	# glyphs present in the font
	gl_n:		int;
	gl_dict:	ref Dict;	# mapping from gl[i].id to i
	ch_dict:	ref Dict;	# charset mapping
	ch_map:		ref Dict;	# characters mapped via font_map()
	fc:		array of int;	# font_findidx()'s, by character
	fpos, fposv:	int;	# dev_fontpos(), when fn_ver was fposv
	lyD:		ref Dict;	# font_layout()'s, by layoutkey()
	ly:		array of ref Layout;
	lyK:		array of int;	# the state they are for
	feat_name:	array of string;	# feature names
	feat_set:	array of int;	# feature enabled
	scrp_name:	array of string;	# script names
	scrp:		int;		# the current script
	lang_name:	array of string;	# language names
	lang:		int;		# the current language
	gsub:		ref Rules;	# glyph substitution rules
	gpos:		ref Rules;	# glyph positioning rules
	fbits:		array of int;	# feat_set as bits
	fliga, frlig, fkern:	int;	# their indices, once looked up (-2 before)
	gsubA:		ref Csr;	# the rules that can match now, by their first glyph
	gposA:		ref Csr;
	gsubK:		array of int;	# the feature state gsubA and gposA are for
	gposK:		array of int;
	ggrp:		ref Iset;	# glyphs of each group
	prl, prr:	array of int;	# protrusion left and right, by gl index (.mtpc), in thousandths of the glyph's width
	ggrp_rev:	ref Csr;	# groups of each glyph
	data:		array of byte;	# the description, its rules read when needed
	blocks:		array of ref Block;	# where its rules are
	nblocks:	int;
	ligs:		list of string;	# its ligatures
	parsed:		array of int;	# the features whose rules have been read, as bits
};

# a run of rules in a font description, read only if its feature is used
Block: adt {
	start, end:	int;	# where it is in the description
	gpos:		int;	# compact rules are gpos rules
	ex:		int;	# it begins with an explicit gsub (1) or gpos (2) rule
	kern:		int;	# a kern line
	sec, feat, scrp, lang:	int;
	nrules, npats:	int;
};

allfonts := array[16] of ref Font;	# every font opened, by Font.id
nallfonts := 0;

# the font of glyph g
gfont(g: ref Glyph): ref Font
{
	return allfonts[g.fid];
}

# convert wid in device unitwidth size to size sz
DEVWID(sz: int, wid: int): int
{
	return (wid * sz + dev_uwid / 2) / dev_uwid;
}

# find a glyph by its name
font_find(fnt: ref Font, name: string): ref Glyph
{
	i := font_findidx(fnt, name);
	if(i >= 0)
		return fnt.gl[i];
	return nil;
}

# where a name is in Font.fc: one character below FCMAX, or two below
# 16r80; -1 if it is not
fc_idx(name: string): int
{
	case len name {
	1 =>
		if(name[0] < FCMAX)
			return name[0];
	2 =>
		if(name[0] < 16r80 && name[1] < 16r80)
			return FCMAX + (name[0] << 7) + name[1];
	}
	return -1;
}

# the glyphs of names of one character below FCMAX (or two below 16r80), by fc_idx():
# 0 if not looked up, else (gl index + 2) << 1 (1 << 1 for none), and 1
# if mapped with font_map(); cleared when ch_map or ch_dict changes
FCMAX:	con 16r2100;

font_findidx(fnt: ref Font, name: string): int
{
	c := fc_idx(name);
	if(c >= 0 && fnt.fc != nil && (v := fnt.fc[c]) != 0)
		return (v >> 1) - 2;
	i := dict_get(fnt.ch_map, name);
	mapped := i != -1;
	if(i == -1)		# -2 means the glyph has been unmapped
		i = dict_get(fnt.ch_dict, name);
	if(i < 0)
		i = -1;
	if(c >= 0){
		if(fnt.fc == nil)
			fnt.fc = array[FCMAX + 128 * 128] of {* => 0};
		fnt.fc[c] = (i + 2) << 1 | mapped;
	}
	return i;
}

# find a glyph by its device-dependent identifier
font_glyph(fnt: ref Font, id: string): ref Glyph
{
	i := dict_get(fnt.gl_dict, id);
	if(i >= 0)
		return fnt.gl[i];
	return nil;
}

font_glyphput(fnt: ref Font, id, name: string, typ: int): int
{
	if(fnt.gl_n == len fnt.gl){
		gl := array[2 * len fnt.gl] of ref Glyph;
		gl[0:] = fnt.gl;
		fnt.gl = gl;
	}
	if(name == id)
		name = id;	# one string for both
	g := ref Glyph(id, name, fnt.id, fnt.gl_n, 0, 0, 0, 0, 0, typ);
	fnt.gl[fnt.gl_n] = g;
	dict_put(fnt.gl_dict, id, fnt.gl_n);
	return fnt.gl_n++;
}

# map character name to the glyph id; remove the mapping unless hasid
font_map(fnt: ref Font, name: string, id: string, hasid: int): int
{
	gidx := -1;
	if(hasid){
		g := font_glyph(fnt, id);
		if(g != nil)
			gidx = g.idx;
		else
			gidx = -2;
	}
	dict_put(fnt.ch_map, name, gidx);
	fnt.fc = nil;
	return 0;
}

# a glyph's protrusion into the margin (.mtpc): left and right, in
# thousandths of its width
font_setprot(fnt: ref Font, g: ref Glyph, l, r: int)
{
	if(fnt.prl == nil || len fnt.prl < len fnt.gl){
		a := array[len fnt.gl] of {* => 0};
		b := array[len fnt.gl] of {* => 0};
		if(fnt.prl != nil){
			a[0:] = fnt.prl;
			b[0:] = fnt.prr;
		}
		fnt.prl = a;
		fnt.prr = b;
	}
	fnt.prl[g.idx] = l;
	fnt.prr[g.idx] = r;
}

font_prot(fnt: ref Font, g: ref Glyph): (int, int)
{
	if(fnt.prl == nil || g.idx >= len fnt.prl)
		return (0, 0);
	return (fnt.prl[g.idx], fnt.prr[g.idx]);
}

# whether character name has been mapped with font_map()
font_mapped(fnt: ref Font, name: string): int
{
	if((c := fc_idx(name)) >= 0){
		if(fnt.fc == nil || fnt.fc[c] == 0)
			font_findidx(fnt, name);
		return fnt.fc[c] & 1;
	}
	return dict_get(fnt.ch_map, name) != -1;
}

# enable or disable ligatures; the first bit for liga, the second for rlig
font_featlg(fnt: ref Font, val: int): int
{
	if(fnt.fliga == -2){
		fnt.fliga = font_findfeat(fnt, "liga");
		fnt.frlig = font_findfeat(fnt, "rlig");
	}
	ret := 0;
	ret |= font_featidx(fnt, fnt.fliga, val & 1);
	ret |= font_featidx(fnt, fnt.frlig, val & 2) << 1;
	return ret;
}

# enable or disable pairwise kerning
font_featkn(fnt: ref Font, val: int): int
{
	if(fnt.fkern == -2)
		fnt.fkern = font_findfeat(fnt, "kern");
	return font_featidx(fnt, fnt.fkern, val);
}

# glyph index in fnt.gl
font_idx(nil: ref Font, g: ref Glyph): int
{
	if(g != nil)
		return g.idx;
	return -1;
}

# whether glyph g is in group grp
grp_has(fnt: ref Font, g: int, grp: int): int
{
	c := fnt.ggrp_rev;
	if(g < 0 || g + 1 >= len c.start)
		return 0;
	for(i := c.start[g]; i < c.start[g + 1]; i++)
		if(c.ent[i] == grp)
			return 1;
	return 0;
}

# whether rule r matches the glyphs src[soff:soff+slen], after dst[doff-dlen:doff]
font_rulematch(fnt: ref Font, R: ref Rules, r: int,
		src: array of int, soff, slen: int, dst: array of int, doff, dlen: int): int
{
	# enable only the active script if set (and rules of every script's,
	# which mkfn writes with no script: not Neatroff's)
	if(fnt.scrp >= 0 && R.scrp[r] >= 0 && fnt.scrp != R.scrp[r])
		return 0;
	# enable common script features and those in the active language
	if(R.lang[r] >= 0 && fnt.lang != R.lang[r])
		return 0;
	f := R.feat[r];
	if(f < 0 || !fnt.feat_set[f])
		return 0;
	b := R.off[r];
	e := R.off[r + 1];
	flg := R.flg;
	pg := R.g;
	# the number of initial context glyphs
	j := b;
	while(j < e && flg[j] & GF_CON)
		j++;
	ncon := j - b;
	if(dlen < ncon)
		return 0;
	# matching the base pattern
	sidx := 0;
	for(; j < e; j++){
		fl := flg[j];
		if(fl & GF_REP)
			continue;
		if(sidx >= slen)
			return 0;
		g := src[soff + sidx];
		if(fl & GF_GRP){
			if(!grp_has(fnt, g, pg[j]))
				return 0;
		}else if(pg[j] != g)
			return 0;
		sidx++;
	}
	# matching the initial context
	for(j = b; j < e && flg[j] & GF_CON; j++){
		g := dst[doff + j - b - ncon];
		if(flg[j] & GF_GRP){
			if(!grp_has(fnt, g, pg[j]))
				return 0;
		}else if(pg[j] != g)
			return 0;
	}
	return 1;
}

# find a matching rule from its index idx + 1 in the candidates for the
# first glyph; returns the rule and idx (-1 to begin)
font_findrule(fnt: ref Font, gsub: int, pos: int,
		fwd: array of int, foff, fwdlen: int, ctx: array of int, coff, ctxlen: int, idx: int): (int, int)
{
	R := fnt.gpos;
	c := fnt.gposA;
	if(gsub){
		R = fnt.gsub;
		c = fnt.gsubA;
	}
	g := fwd[foff];
	if(g < 0 || g + 1 >= len c.start)
		return (-1, idx);
	lo := c.start[g];
	hi := c.start[g + 1];
	if(idx < 0)
		idx = lo - 1;
	ent := c.ent;
	while(++idx < hi){
		r := ent[idx];
		if(r >= pos && font_rulematch(fnt, R, r, fwd, foff, fwdlen, ctx, coff, ctxlen))
			return (r, idx);
	}
	return (-1, idx);
}

# perform every gpos rule that applies to src
font_performgpos(fnt: ref Font, src: array of int, slen: int,
		x, y, xadv, yadv: array of int)
{
	R := fnt.gpos;
	curs_feat := -1;
	if(dir_do)
		curs_feat = font_findfeat(fnt, "curs");
	curs_beg := -1;
	curs_dif := 0;
	for(i := 0; i < slen; i++){
		idx := -1;
		curs_cur := 0;
		lastsec := -1;
		for(;;){
			r: int;
			(r, idx) = font_findrule(fnt, 0, 0, src, i, slen - i, src, i, i, idx);
			if(r < 0)		# no rule found
				break;
			if(R.sec[r] > 0 && R.sec[r] <= lastsec)
				continue;	# perform at most one rule from each lookup
			lastsec = R.sec[r];
			b := R.off[r];
			n := R.off[r + 1] - b;
			for(k := 0; k < n; k++){
				x[i + k] += R.x[b + k];
				y[i + k] += R.y[b + k];
				xadv[i + k] += R.xadv[b + k];
				yadv[i + k] += R.yadv[b + k];
			}
			if(R.feat[r] == curs_feat){
				curs_cur = 1;
				if(curs_beg < 0)
					curs_beg = i;
				for(k = 0; k < n; k++)
					curs_dif += R.yadv[b + k];
			}
		}
		if(curs_beg >= 0 && !curs_cur){
			yadv[curs_beg] -= curs_dif;
			curs_beg = -1;
			curs_dif = 0;
		}
	}
	if(curs_beg >= 0)
		yadv[curs_beg] -= curs_dif;
}

# the first gsub rule from pos that matches any glyph in src
font_firstgsub(fnt: ref Font, pos: int, src: array of int, slen: int): int
{
	best := -1;
	for(i := 0; i < slen; i++){
		(r, nil) := font_findrule(fnt, 1, pos, src, i, slen - i, src, i, i, -1);
		if(r >= 0 && (best < 0 || r < best))
			best = r;
	}
	return best;
}

# apply rule r to all its matches in src
font_gsubapply(fnt: ref Font, r: int, src: array of int, slen: int, smap: array of int,
		dst, dmap: array of int): int
{
	R := fnt.gsub;
	b := R.off[r];
	e := R.off[r + 1];
	dlen := 0;
	for(i := 0; i < slen; i++){
		dmap[dlen] = smap[i];
		if(font_rulematch(fnt, R, r, src, i, slen - i, dst, dlen, dlen)){
			for(j := b; j < e; j++){
				if(R.flg[j] & GF_REP)
					dst[dlen++] = R.g[j];
				if(R.flg[j] & GF_PAT)
					i++;
			}
			i--;
		}else
			dst[dlen++] = src[i];
	}
	src[0:] = dst[0:dlen];
	smap[0:] = dmap[0:dlen];
	return dlen;
}

# perform every gsub rule that applies to src
font_performgsub(fnt: ref Font, src: array of int, slen: int, smap: array of int): int
{
	dst, dmap: array of int;
	i := -1;
	while(++i >= 0){
		if((i = font_firstgsub(fnt, i, src, slen)) < 0)
			break;
		if(dst == nil){
			dst = array[WORDLEN] of {* => 0};
			dmap = array[WORDLEN] of {* => 0};
		}
		slen = font_gsubapply(fnt, i, src, slen, smap, dst, dmap);
	}
	return slen;
}

layout_dst: array of int;

# font_layout()'s results, kept by the glyphs laid out
Layout: adt {
	n:	int;
	dst, dmap, x, y, xadv, yadv:	array of int;
};
LYMAX:	con 8192;

# the key of a layout in fnt's present state, or nil
layoutkey(gsrc: array of ref Glyph, nsrc: int, lg, kn: int): string
{
	k := "";
	f := 1;
	if(lg)
		f |= 2;
	if(kn)
		f |= 4;
	if(dir_do)
		f |= 8;
	k[0] = f;
	for(i := 0; i < nsrc; i++){
		g := 1;
		if(gsrc[i] != nil)
			g = gsrc[i].idx + 2;
		if(g >= 16rd000)
			return nil;
		k[i + 1] = g;
	}
	return k;
}

# lay out the glyphs gsrc; returns their number in gdst
font_layout(fnt: ref Font, gsrc: array of ref Glyph, nsrc: int, sz: int,
		gdst: array of ref Glyph, dmap: array of int,
		x, y, xadv, yadv: array of int, lg, kn: int): int
{
	key := layoutkey(gsrc, nsrc, lg, kn);
	if(key == nil)
		return font_layout1(fnt, gsrc, nsrc, sz, gdst, dmap, x, y, xadv, yadv, lg, kn);
	if(fnt.lyD != nil && !font_samestate(fnt, fnt.lyK))
		fnt.lyD = nil;
	if(fnt.lyD != nil && (i := dict_get(fnt.lyD, key)) >= 0){
		l := fnt.ly[i];
		n := l.n;
		for(j := 0; j < n; j++){
			gdst[j] = fnt.gl[l.dst[j]];
			dmap[j] = l.dmap[j];
			x[j] = l.x[j];
			y[j] = l.y[j];
			xadv[j] = l.xadv[j];
			yadv[j] = l.yadv[j];
		}
		return n;
	}
	k := font_state(fnt);
	n := font_layout1(fnt, gsrc, nsrc, sz, gdst, dmap, x, y, xadv, yadv, lg, kn);
	if(fnt.lyD == nil || fnt.lyD.n > LYMAX){
		fnt.lyD = dict_make(4096);
		fnt.ly = array[LYMAX + 2] of ref Layout;
		fnt.lyK = k;
	}else if(!font_samestate(fnt, fnt.lyK))
		return n;
	l := ref Layout(n, array[n] of int, array[n] of int, array[n] of int, array[n] of int, array[n] of int, array[n] of int);
	l.dmap[0:] = dmap[0:n];
	l.x[0:] = x[0:n];
	l.y[0:] = y[0:n];
	l.xadv[0:] = xadv[0:n];
	l.yadv[0:] = yadv[0:n];
	for(j := 0; j < n; j++)
		l.dst[j] = gdst[j].idx;
	fnt.ly[fnt.lyD.n] = l;
	dict_put(fnt.lyD, key, fnt.lyD.n);
	return n;
}

font_layout1(fnt: ref Font, gsrc: array of ref Glyph, nsrc: int, nil: int,
		gdst: array of ref Glyph, dmap: array of int,
		x, y, xadv, yadv: array of int, lg, kn: int): int
{
	if(layout_dst == nil)
		layout_dst = array[WORDLEN] of {* => 0};
	dst := layout_dst;
	ndst := nsrc;
	for(i := 0; i < nsrc; i++)
		dst[i] = font_idx(fnt, gsrc[i]);
	for(i = 0; i < ndst; i++){
		dmap[i] = i;
		x[i] = 0;
		y[i] = 0;
		xadv[i] = 0;
		yadv[i] = 0;
	}
	# substitution rules
	featlg := 0;
	if(lg)
		featlg = font_featlg(fnt, 3);
	if(!font_samestate(fnt, fnt.gsubK)){
		font_needrules(fnt);
		fnt.gsubA = font_active(fnt, fnt.gsub);
		fnt.gsubK = font_state(fnt);
	}
	ndst = font_performgsub(fnt, dst, ndst, dmap);
	if(lg)
		font_featlg(fnt, featlg);
	# positioning rules
	featkn := 0;
	if(kn)
		featkn = font_featkn(fnt, 1);
	if(!font_samestate(fnt, fnt.gposK)){
		font_needrules(fnt);
		fnt.gposA = font_active(fnt, fnt.gpos);
		fnt.gposK = font_state(fnt);
	}
	font_performgpos(fnt, dst, ndst, x, y, xadv, yadv);
	if(kn)
		font_featkn(fnt, featkn);
	for(i = 0; i < ndst; i++)
		gdst[i] = fnt.gl[dst[i]];
	return ndst;
}

font_findfeat(fnt: ref Font, feat: string): int
{
	i: int;
	for(i = 0; i < NFEATS && fnt.feat_name[i] != nil; i++)
		if(feat == fnt.feat_name[i])
			return i;
	if(i < NFEATS){
		fnt.feat_name[i] = feat;
		return i;
	}
	return -1;
}

font_findscrp(fnt: ref Font, scrp: string): int
{
	i: int;
	for(i = 0; i < NSCRPS && fnt.scrp_name[i] != nil; i++)
		if(scrp == fnt.scrp_name[i])
			return i;
	if(i == NSCRPS)
		return -1;
	fnt.scrp_name[i] = scrp;
	return i;
}

font_findlang(fnt: ref Font, lang: string): int
{
	i: int;
	for(i = 0; i < NLANGS && fnt.lang_name[i] != nil; i++)
		if(lang == fnt.lang_name[i])
			return i;
	if(i == NLANGS)
		return -1;
	fnt.lang_name[i] = lang;
	return i;
}

# rules, room for nr of them and np patterns
rules_new(gpos: int, nr, np: int): ref Rules
{
	nr++;
	np++;
	R := ref Rules;
	R.n = 0;
	R.off = array[nr + 1] of {* => 0};
	R.sec = array[nr] of {* => 0};
	R.feat = array[nr] of {* => 0};
	R.scrp = array[nr] of {* => 0};
	R.lang = array[nr] of {* => 0};
	R.npat = 0;
	R.g = array[np] of {* => 0};
	R.flg = array[np] of {* => 0};
	if(gpos){
		R.x = array[np] of {* => 0};
		R.y = array[np] of {* => 0};
		R.xadv = array[np] of {* => 0};
		R.yadv = array[np] of {* => 0};
	}
	return R;
}

growints(a: array of int, n: int): array of int
{
	b := array[n] of {* => 0};
	b[0:] = a;
	return b;
}

# add a rule of n patterns; returns its index
rules_add(R: ref Rules, n: int, sec, feat, scrp, lang: int): int
{
	if(R.n + 1 >= len R.off){
		sz := 2 * len R.off;
		R.off = growints(R.off, sz);
		R.sec = growints(R.sec, sz);
		R.feat = growints(R.feat, sz);
		R.scrp = growints(R.scrp, sz);
		R.lang = growints(R.lang, sz);
	}
	if(R.npat + n > len R.g){
		sz := 2 * len R.g;
		while(sz < R.npat + n)
			sz *= 2;
		R.g = growints(R.g, sz);
		R.flg = growints(R.flg, sz);
		if(R.x != nil){
			R.x = growints(R.x, sz);
			R.y = growints(R.y, sz);
			R.xadv = growints(R.xadv, sz);
			R.yadv = growints(R.yadv, sz);
		}
	}
	r := R.n++;
	R.sec[r] = sec;
	R.feat[r] = feat;
	R.scrp[r] = scrp;
	R.lang[r] = lang;
	R.off[r] = R.npat;
	R.npat += n;
	R.off[r + 1] = R.npat;
	return r;
}

# the bytes of a font description and where reading has reached
Fb: adt {
	b:	array of byte;
	i:	int;
};

fb_open(path: string): ref Fb
{
	fd := sys->open(path, Sys->OREAD);
	if(fd == nil)
		return nil;
	(ok, d) := sys->fstat(fd);
	if(ok < 0)
		return nil;
	n := int d.length;
	b := array[n] of byte;
	t := 0;
	while(t < n){
		m := sys->read(fd, b[t:], n - t);
		if(m <= 0)
			break;
		t += m;
	}
	return ref Fb(b[0:t], 0);
}

fb_isspace(c: int): int
{
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f';
}

# skip white space; whether a token follows
fb_skipws(f: ref Fb): int
{
	b := f.b;
	i := f.i;
	while(i < len b && fb_isspace(int b[i]))
		i++;
	f.i = i;
	return i < len b;
}

# the next token (fscanf("%s")), or nil at the end
fb_tok(f: ref Fb): string
{
	if(!fb_skipws(f))
		return nil;
	b := f.b;
	s := f.i;
	i := s;
	while(i < len b && !fb_isspace(int b[i]))
		i++;
	f.i = i;
	return string b[s:i];
}

# the next token's bounds, without making a string of it
fb_tokpos(f: ref Fb): (int, int)
{
	if(!fb_skipws(f))
		return (-1, -1);
	b := f.b;
	s := f.i;
	i := s;
	while(i < len b && !fb_isspace(int b[i]))
		i++;
	f.i = i;
	return (s, i);
}

# a number token (fscanf("%d")); and whether there was one
fb_num(f: ref Fb): (int, int)
{
	(s, e) := fb_tokpos(f);
	if(s < 0)
		return (0, 0);
	(n, nil, ok) := bnum(f.b, s, e);
	return (n, ok);
}

# skip the rest of the line (skipline())
fb_skipline(f: ref Fb)
{
	b := f.b;
	i := f.i;
	while(i < len b && int b[i] != '\n')
		i++;
	if(i < len b)
		i++;
	f.i = i;
}

# the rest of the line, its newline included (fgets())
fb_rest(f: ref Fb): string
{
	b := f.b;
	s := f.i;
	i := s;
	while(i < len b && int b[i] != '\n')
		i++;
	if(i < len b)
		i++;
	f.i = i;
	return string b[s:i];
}

# a signed number in b[s:e] at s, as strtol reads it; its value, where it stops and whether there was one
bnum(b: array of byte, s, e: int): (int, int, int)
{
	neg := 0;
	if(s < e && (int b[s] == '-' || int b[s] == '+')){
		neg = int b[s] == '-';
		s++;
	}
	if(s >= e || int b[s] < '0' || int b[s] > '9')
		return (0, s, 0);
	n := 0;
	while(s < e && int b[s] >= '0' && int b[s] <= '9')
		n = n * 10 + int b[s++] - '0';
	if(neg)
		n = -n;
	return (n, s, 1);
}

# whether b[s:e] is the word w
beq(b: array of byte, s, e: int, w: string): int
{
	if(e - s != len w)
		return 0;
	for(i := 0; i < len w; i++)
		if(int b[s + i] != w[i])
			return 0;
	return 1;
}

font_readchar(fnt: ref Font, f: ref Fb, n: int, gid: int): (int, int, int)
{
	name := fb_tok(f);
	(ts, te) := fb_tokpos(f);
	if(name == nil || ts < 0)
		return (1, n, gid);
	if(name == "---")
		name = sys->sprint("c%.4d", n);
	b := f.b;
	if(!(te - ts == 1 && int b[ts] == '"')){
		(typ, ok) := fb_num(f);
		id := fb_tok(f);
		if(!ok || id == nil)
			return (1, n, gid);
		gid = font_glyphput(fnt, id, name, typ);
		g := fnt.gl[gid];
		# sscanf(tok, "%hd,%hd,%hd,%hd,%hd")
		v := array[5] of {* => 0};
		i := ts;
		for(k := 0; k < 5; k++){
			if(k > 0){
				if(i >= te || int b[i] != ',')
					break;
				i++;
			}
			m, ok2: int;
			(m, i, ok2) = bnum(b, i, te);
			if(!ok2)
				break;
			v[k] = m;
		}
		g.wid = v[0];
		g.llx = v[1];
		g.lly = v[2];
		g.urx = v[3];
		g.ury = v[4];
		dict_put(fnt.ch_dict, name, gid);
		fnt.fc = nil;
		n++;
	}else
		dict_put(fnt.ch_map, name, gid);
		fnt.fc = nil;
	return (0, n, gid);
}

# split a feature tag, feat:scrp:lang
font_readfeat(fnt: ref Font, tok: string): (int, int, int)
{
	stag, ltag: string;
	hass := 0;
	hasl := 0;
	if((i := strchr(tok, ':')) >= 0){
		stag = tok[i+1:];
		tok = tok[0:i];
		hass = 1;
	}
	if(hass && (i = strchr(stag, ':')) >= 0){
		ltag = stag[i+1:];
		stag = stag[0:i];
		hasl = 1;
	}
	scrp := -1;
	lang := -1;
	if(hass)
		scrp = font_findscrp(fnt, stag);
	if(hasl)
		lang = font_findlang(fnt, ltag);
	return (font_findfeat(fnt, tok), scrp, lang);
}

# read pattern j of R from b[s:e]; whether it is invalid
font_readgpat(fnt: ref Font, R: ref Rules, j: int, b: array of byte, s, e: int): int
{
	g: int;
	if(s < e && int b[s] >= '0' && int b[s] <= '9')
		(g, nil, nil) = bnum(b, s, e);
	else if(s < e && int b[s] == '@'){
		(g, nil, nil) = bnum(b, s + 1, e);
		if(iset_len(fnt.ggrp, g) == 1)
			g = iset_get(fnt.ggrp, g)[0];
		else
			R.flg[j] |= GF_GRP;
	}else
		g = font_idx(fnt, font_glyph(fnt, string b[s:e]));
	R.g[j] = g;
	return g < 0 || g >= fnt.gl_n;
}

font_readgsub(fnt: ref Font, f: ref Fb, n: int, sec, feat, scrp, lang: int): int
{
	R := fnt.gsub;
	r := rules_add(R, n, sec, feat, scrp, lang);
	o := R.off[r];
	b := f.b;
	for(i := 0; i < n; i++){
		(s, e) := fb_tokpos(f);
		if(s < 0)
			return 1;
		case int b[s] {
		'-' =>
			R.flg[o + i] = GF_PAT;
		'=' =>
			R.flg[o + i] = GF_CON;
		'+' =>
			R.flg[o + i] = GF_REP;
		}
		if(font_readgpat(fnt, R, o + i, b, s + 1, e))
			return 0;
	}
	return 0;
}

font_readgpos(fnt: ref Font, f: ref Fb, n: int, sec, feat, scrp, lang: int): int
{
	R := fnt.gpos;
	r := rules_add(R, n, sec, feat, scrp, lang);
	o := R.off[r];
	b := f.b;
	for(i := 0; i < n; i++){
		(s, e) := fb_tokpos(f);
		if(s < 0)
			return 1;
		col := s;
		while(col < e && int b[col] != ':')
			col++;
		R.flg[o + i] = GF_PAT;
		if(col == s || font_readgpat(fnt, R, o + i, b, s, col))
			return 0;
		if(col < e){
			# sscanf("%hd%hd%hd%hd")
			v := array[4] of {* => 0};
			k := col + 1;
			for(m := 0; m < 4; m++){
				while(k < e && fb_isspace(int b[k]))
					k++;
				ok: int;
				(v[m], k, ok) = bnum(b, k, e);
				if(!ok)
					break;
			}
			R.x[o + i] = v[0];
			R.y[o + i] = v[1];
			R.xadv[o + i] = v[2];
			R.yadv[o + i] = v[3];
		}
	}
	return 0;
}

font_readggrp(fnt: ref Font, f: ref Fb, rev: ref Iset): int
{
	(id, ok1) := fb_num(f);
	(n, ok2) := fb_num(f);
	if(!ok1 || !ok2)
		return 1;
	b := f.b;
	for(i := 0; i < n; i++){
		(s, e) := fb_tokpos(f);
		if(s < 0)
			return 1;
		g: int;
		if(int b[s] >= '0' && int b[s] <= '9')
			(g, nil, nil) = bnum(b, s, e);
		else
			g = font_idx(fnt, font_glyph(fnt, string b[s:e]));
		if(g >= 0 && g < fnt.gl_n){
			iset_put(fnt.ggrp, id, g);
			iset_put(rev, g, id);
		}
	}
	return 0;
}

font_readkern(fnt: ref Font, f: ref Fb): int
{
	c1 := fb_tok(f);
	c2 := fb_tok(f);
	(val, ok) := fb_num(f);
	if(c1 == nil || c2 == nil || !ok)
		return 1;
	R := fnt.gpos;
	r := rules_add(R, 2, 0, font_findfeat(fnt, "kern"), -1, -1);
	o := R.off[r];
	R.g[o] = font_idx(fnt, font_glyph(fnt, c1));
	R.g[o + 1] = font_idx(fnt, font_glyph(fnt, c2));
	R.xadv[o] = val;
	R.flg[o] = GF_PAT;
	R.flg[o + 1] = GF_PAT;
	return 0;
}

font_lig(fnt: ref Font, lig: string)
{
	n := len lig;
	R := fnt.gsub;
	r := rules_add(R, n + 1, 0, font_findfeat(fnt, "liga"), -1, -1);
	o := R.off[r];
	for(j := 0; j < n; j++){
		R.g[o + j] = font_idx(fnt, font_find(fnt, lig[j:j+1]));
		R.flg[o + j] = GF_PAT;
	}
	R.g[o + n] = font_idx(fnt, font_find(fnt, lig));
	R.flg[o + n] = GF_REP;
}

# the first pattern of rule r that is neither a replacement nor context
font_rulefirstpat(R: ref Rules, r: int): int
{
	for(i := R.off[r]; i < R.off[r + 1]; i++)
		if(!(R.flg[i] & (GF_REP | GF_CON)))
			return i;
	return -1;
}

# the state that decides which rules are on: the features, script and language
font_state(fnt: ref Font): array of int
{
	k := array[len fnt.fbits + 2] of int;
	k[0:] = fnt.fbits;
	k[len fnt.fbits] = fnt.scrp;
	k[len fnt.fbits + 1] = fnt.lang;
	return k;
}

font_samestate(fnt: ref Font, k: array of int): int
{
	if(k == nil)
		return 0;
	n := len fnt.fbits;
	for(i := 0; i < n; i++)
		if(k[i] != fnt.fbits[i])
			return 0;
	return k[n] == fnt.scrp && k[n + 1] == fnt.lang;
}

# whether rule r of R can match, given the features, script and language
font_ruleon(fnt: ref Font, R: ref Rules, r: int): int
{
	if(fnt.scrp >= 0 && fnt.scrp != R.scrp[r])
		return 0;
	if(R.lang[r] >= 0 && fnt.lang != R.lang[r])
		return 0;
	f := R.feat[r];
	return f >= 0 && fnt.feat_set[f];
}

# the rules of R that can match now, by the glyphs their first pattern matches, in rule order
font_active(fnt: ref Font, R: ref Rules): ref Csr
{
	nk := fnt.gl_n + 1;
	start := array[nk + 1] of {* => 0};
	first := array[R.n] of {* => -1};
	for(r := 0; r < R.n; r++){
		if(!font_ruleon(fnt, R, r))
			continue;
		j := font_rulefirstpat(R, r);
		if(j < 0)
			continue;
		first[r] = j;
		if(R.flg[j] & GF_GRP){
			gs := iset_get(fnt.ggrp, R.g[j]);
			for(k := 0; k < len gs; k++)
				if(gs[k] >= 0 && gs[k] < nk)
					start[gs[k]]++;
		}else if(R.g[j] >= 0 && R.g[j] < nk)
			start[R.g[j]]++;
	}
	t := 0;
	for(k := 0; k < nk; k++){
		c := start[k];
		start[k] = t;
		t += c;
	}
	start[nk] = t;
	ent := array[t] of {* => 0};
	fill := array[nk] of {* => 0};
	for(r = 0; r < R.n; r++){
		j := first[r];
		if(j < 0)
			continue;
		if(R.flg[j] & GF_GRP){
			gs := iset_get(fnt.ggrp, R.g[j]);
			for(k = 0; k < len gs; k++){
				g := gs[k];
				if(g >= 0 && g < nk)
					ent[start[g] + fill[g]++] = r;
			}
		}else if(R.g[j] >= 0 && R.g[j] < nk){
			g := R.g[j];
			ent[start[g] + fill[g]++] = r;
		}
	}
	return ref Csr(start, ent);
}

# an Iset as a Csr
iset_csr(s: ref Iset, nkeys: int): ref Csr
{
	start := array[nkeys + 1] of {* => 0};
	t := 0;
	for(k := 0; k < nkeys; k++){
		start[k] = t;
		t += iset_len(s, k);
	}
	start[nkeys] = t;
	ent := array[t] of {* => 0};
	for(k = 0; k < nkeys; k++){
		m := iset_get(s, k);
		ent[start[k]:] = m;
	}
	return ref Csr(start, ent);
}

font_new(path: string): ref Font
{
	fnt := ref Font;
	fnt.path = path;
	fnt.feat_name = array[NFEATS] of string;
	fnt.feat_set = array[NFEATS] of {* => 0};
	fnt.fbits = array[(NFEATS + 31) / 32] of {* => 0};
	fnt.scrp_name = array[NSCRPS] of string;
	fnt.lang_name = array[NLANGS] of string;
	fnt.scrp = -1;
	fnt.lang = -1;
	fnt.fliga = fnt.frlig = fnt.fkern = -2;
	if(nallfonts == len allfonts){
		a := array[2 * len allfonts] of ref Font;
		a[0:] = allfonts;
		allfonts = a;
	}
	fnt.id = nallfonts;
	allfonts[nallfonts++] = fnt;
	return fnt;
}

# mount a font: read the header of its description, up to its glyphs
font_open(path: string): ref Font
{
	f := fb_open(path);
	if(f == nil)
		return nil;
	fnt := font_new(path);
	b := f.b;
	for(;;){
		(s, e) := fb_tokpos(f);
		if(s < 0)
			break;
		if(beq(b, s, e, "special"))
			fnt.special = 1;
		else if(beq(b, s, e, "name"))
			fnt.name = fb_tok(f);
		else if(beq(b, s, e, "fontname"))
			fnt.fontname = fb_tok(f);
		else if(beq(b, s, e, "spacewidth"))
			(fnt.spacewid, nil) = fb_num(f);
		else if(beq(b, s, e, "char") || beq(b, s, e, "charset") ||
				beq(b, s, e, "kern") || beq(b, s, e, "gsec") ||
				beq(b, s, e, "ggrp") || beq(b, s, e, "gsub") ||
				beq(b, s, e, "gpos") || beq(b, s, e, "ligatures"))
			break;
		fb_skipline(f);
	}
	return fnt;
}

# read a font's glyphs, the first time it is used; note where its rules are
font_load(fnt: ref Font)
{
	if(fnt.loaded)
		return;
	fnt.loaded = 1;
	f := fb_open(fnt.path);
	if(f == nil)
		f = ref Fb(array[0] of byte, 0);
	fnt.data = f.b;
	fnt.gl = array[1024] of ref Glyph;
	fnt.gl_dict = dict_make(4096);
	fnt.ch_dict = dict_make(4096);
	fnt.ch_map = dict_make(1024);
	fnt.gsub = rules_new(0, 0, 0);
	fnt.gpos = rules_new(1, 0, 0);
	fnt.ggrp = iset_make();
	fnt.blocks = array[64] of ref Block;
	fnt.parsed = array[len fnt.fbits] of {* => 0};
	rev := iset_make();
	ch_g := -1;		# the last glyph in the charset
	ch_n := 0;		# the number of glyphs in the charset
	sec := 0;
	feat := 0;
	scrp := 0;
	lang := 0;
	sec_gpos := 0;		# 0: gsub, 1: gpos
	err: int;
	cur: ref Block;		# the block the compact rules go in
	b := f.b;
read:	for(;;){
		(s, e) := fb_tokpos(f);
		if(s < 0)
			break;
		c := int b[s];
		if(c >= '0' && c <= '9'){
			# a compact rule, one to a line
			(n, nil, nil) := bnum(b, s, e);
			if(cur == nil)
				cur = font_block(fnt, s, sec_gpos, 0, 0, sec, feat, scrp, lang);
			cur.nrules++;
			cur.npats += n;
			fb_skipline(f);
			cur.end = f.i;
			continue;
		}
		if(beq(b, s, e, "ggrp")){
			font_readggrp(fnt, f, rev);
			fb_skipline(f);
			if(cur != nil)
				cur.end = f.i;
			continue;
		}
		cur = nil;
		if(beq(b, s, e, "char"))
			(nil, ch_n, ch_g) = font_readchar(fnt, f, ch_n, ch_g);
		else if(beq(b, s, e, "gsec")){
			(sec, sec_gpos, feat, scrp, lang) = font_readgsec(fnt, fb_rest(f),
				sec, sec_gpos, feat, scrp, lang);
			continue;
		}else if(beq(b, s, e, "kern")){
			k := font_block(fnt, s, 1, 0, 1, 0, font_findfeat(fnt, "kern"), -1, -1);
			k.nrules = 1;
			k.npats = 2;
			fb_skipline(f);
			k.end = f.i;
			continue;
		}else if(beq(b, s, e, "ligatures")){
			while((tok := fb_tok(f)) != nil){
				if(tok == "0")
					break;
				fnt.ligs = tok :: fnt.ligs;
			}
		}else if(beq(b, s, e, "gsub") || beq(b, s, e, "gpos")){
			ex := 1;
			if(beq(b, s, e, "gpos"))
				ex = 2;
			tok := fb_tok(f);
			(cnt, ok) := fb_num(f);
			if(tok != nil && ok){
				# the explicit rule's feature is the feature of those after it
				(feat, scrp, lang) = font_readfeat(fnt, tok);
				cur = font_block(fnt, s, sec_gpos, ex, 0, sec, feat, scrp, lang);
				cur.nrules = 1;
				cur.npats = cnt;
				fb_skipline(f);
				cur.end = f.i;
				continue;
			}
		}else if(beq(b, s, e, "special"))
			fnt.special = 1;
		else if(beq(b, s, e, "spacewidth"))
			(fnt.spacewid, nil) = fb_num(f);
		else if(beq(b, s, e, "name"))
			fnt.name = fb_tok(f);
		else if(beq(b, s, e, "fontname"))
			fnt.fontname = fb_tok(f);
		else if(beq(b, s, e, "charset")){
			for(;;){
				(err, ch_n, ch_g) = font_readchar(fnt, f, ch_n, ch_g);
				if(err)
					break;
				fb_skipline(f);
			}
			break read;
		}
		fb_skipline(f);
	}
	# the ligatures in the order they were listed
	rl: list of string;
	for(; fnt.ligs != nil; fnt.ligs = tl fnt.ligs)
		rl = hd fnt.ligs :: rl;
	fnt.ligs = rl;
	fnt.ggrp_rev = iset_csr(rev, fnt.gl_n + 1);
}

font_block(fnt: ref Font, start: int, gpos, ex, kern, sec, feat, scrp, lang: int): ref Block
{
	if(fnt.nblocks == len fnt.blocks){
		a := array[2 * len fnt.blocks] of ref Block;
		a[0:] = fnt.blocks;
		fnt.blocks = a;
	}
	k := ref Block(start, start, gpos, ex, kern, sec, feat, scrp, lang, 0, 0);
	fnt.blocks[fnt.nblocks++] = k;
	return k;
}

bit(a: array of int, f: int): int
{
	return f >= 0 && (a[f >> 5] >> (f & 31)) & 1;
}

# read the rules of the features now on that have not been read
font_needrules(fnt: ref Font)
{
	more := 0;
	for(i := 0; i < len fnt.fbits; i++)
		if(fnt.fbits[i] & ~fnt.parsed[i]){
			fnt.parsed[i] |= fnt.fbits[i];
			more = 1;
		}
	if(more)
		font_rules(fnt);
}

# read the rules of the features in fnt.parsed, in the order they are in the description
font_rules(fnt: ref Font)
{
	fnt.lyD = nil;
	liga := font_findfeat(fnt, "liga");
	nr := array[2] of {* => 0};
	np := array[2] of {* => 0};
	for(i := 0; i < fnt.nblocks; i++){
		k := fnt.blocks[i];
		if(!bit(fnt.parsed, k.feat))
			continue;
		t := k.gpos;
		if(k.ex)
			t = k.ex - 1;
		nr[t] += k.nrules;
		np[t] += k.npats;
	}
	l: list of string;
	if(bit(fnt.parsed, liga))
		for(l = fnt.ligs; l != nil; l = tl l){
			nr[0]++;
			np[0] += len hd l + 1;
		}
	fnt.gsub = rules_new(0, nr[0], np[0]);
	fnt.gpos = rules_new(1, nr[1], np[1]);
	f := ref Fb(fnt.data, 0);
	b := f.b;
	for(i = 0; i < fnt.nblocks; i++){
		k := fnt.blocks[i];
		if(!bit(fnt.parsed, k.feat))
			continue;
		f.i = k.start;
		if(k.kern){
			fb_tokpos(f);
			font_readkern(fnt, f);
			continue;
		}
		if(k.ex){
			fb_tokpos(f);
			fb_tokpos(f);
			(cnt, nil) := fb_num(f);
			if(k.ex == 2)
				font_readgpos(fnt, f, cnt, k.sec, k.feat, k.scrp, k.lang);
			else
				font_readgsub(fnt, f, cnt, k.sec, k.feat, k.scrp, k.lang);
			fb_skipline(f);
		}
		while(f.i < k.end){
			(s, e) := fb_tokpos(f);
			if(s < 0 || s >= k.end)
				break;
			c := int b[s];
			if(c >= '0' && c <= '9'){
				(n, nil, nil) := bnum(b, s, e);
				if(k.gpos)
					font_readgpos(fnt, f, n, k.sec, k.feat, k.scrp, k.lang);
				else
					font_readgsub(fnt, f, n, k.sec, k.feat, k.scrp, k.lang);
			}
			fb_skipline(f);
		}
	}
	if(bit(fnt.parsed, liga))
		for(l = fnt.ligs; l != nil; l = tl l)
			font_lig(fnt, hd l);
	fnt.gsubK = nil;
	fnt.gposK = nil;
}

# a gsec line: its section, gsub or gpos, and its feature
font_readgsec(fnt: ref Font, ln: string, sec, gpos, feat, scrp, lang: int): (int, int, int, int, int)
{
	f := ref Fb(array of byte ln, 0);
	(s, ok) := fb_num(f);
	if(ok)
		sec = s;
	cmd := fb_tok(f);
	if(ok && cmd != nil){
		gpos = cmd == "gpos";
		tok := fb_tok(f);
		if(tok != nil)
			(feat, scrp, lang) = font_readfeat(fnt, tok);
	}
	return (sec, gpos, feat, scrp, lang);
}

font_special(fnt: ref Font): int
{
	return fnt.special;
}

# width w for the given font and size
font_wid(fnt: ref Font, sz: int, w: int): int
{
	if(fnt.zoom)
		sz = (sz * fnt.zoom + 500) / 1000;
	if(w >= 0)
		return (w * sz + dev_uwid / 2) / dev_uwid;
	return -((-w * sz + dev_uwid / 2) / dev_uwid);
}

# track kerning width for the given size
font_twid(fnt: ref Font, sz: int): int
{
	if(fnt.s1 >= 0 && sz <= fnt.s1)
		return fnt.n1 * SC_PT();
	if(fnt.s2 >= 0 && sz >= fnt.s2)
		return fnt.n2 * SC_PT();
	if(sz > fnt.s1 && sz < fnt.s2)
		return int (big ((fnt.s2 - sz) * fnt.n1 + (sz - fnt.s1) * fnt.n2) *
				big SC_PT() / big (fnt.s2 - fnt.s1));
	return 0;
}

# glyph width, where cfnt is the current font and fnt the glyph's
font_gwid(fnt: ref Font, cfnt: ref Font, sz: int, w: int): int
{
	xfnt := cfnt;
	if(xfnt == nil)
		xfnt = fnt;
	if(xfnt.cs){
		s := sz;
		if(xfnt.cs_ps)
			s = xfnt.cs_ps;
		return xfnt.cs * (font_zoom(fnt, s) * SC_IN() / 72) / 36;
	}
	z := sz;
	if(fnt.zoom)
		z = (sz * fnt.zoom + 500) / 1000;
	r: int;
	if(w >= 0)
		r = (w * z + dev_uwid / 2) / dev_uwid;
	else
		r = -((-w * z + dev_uwid / 2) / dev_uwid);
	if(cfnt != nil && (fnt.n1 || fnt.n2))	# else font_twid() is 0
		r += font_twid(fnt, sz);
	if(xfnt.bd)
		r += xfnt.bd - 1;
	return r;
}

# the width of a word or sentence space
font_swid(fnt: ref Font, sz: int, ss: int): int
{
	return font_gwid(fnt, nil, sz, (fnt.spacewid * ss + 6) / 12);
}

font_getcs(fnt: ref Font): int
{
	return fnt.cs;
}

font_setcs(fnt: ref Font, cs: int, ps: int)
{
	fnt.cs = cs;
	fnt.cs_ps = ps;
}

font_getbd(fnt: ref Font): int
{
	return fnt.bd;
}

font_setbd(fnt: ref Font, bd: int)
{
	fnt.bd = bd;
}

font_track(fnt: ref Font, s1, n1, s2, n2: int)
{
	fnt.s1 = s1;
	fnt.n1 = n1;
	fnt.s2 = s2;
	fnt.n2 = n2;
}

font_zoom(fnt: ref Font, sz: int): int
{
	if(fnt.zoom)
		return (sz * fnt.zoom + 500) / 1000;
	return sz;
}

font_setzoom(fnt: ref Font, zoom: int)
{
	fnt.zoom = zoom;
}

# enable or disable a font feature; returns its previous value
font_feat(fnt: ref Font, name: string, val: int): int
{
	return font_featidx(fnt, font_findfeat(fnt, name), val);
}

font_featidx(fnt: ref Font, idx: int, val: int): int
{
	old := 0;
	if(idx >= 0){
		old = fnt.feat_set[idx];
		fnt.feat_set[idx] = val != 0;
		if(val)
			fnt.fbits[idx >> 5] |= 1 << (idx & 31);
		else
			fnt.fbits[idx >> 5] &= ~(1 << (idx & 31));
	}
	return old;
}

font_scrp(fnt: ref Font, name: string, has: int)
{
	if(has)
		fnt.scrp = font_findscrp(fnt, name);
	else
		fnt.scrp = -1;
}

font_lang(fnt: ref Font, name: string, has: int)
{
	if(has)
		fnt.lang = font_findlang(fnt, name);
	else
		fnt.lang = -1;
}
