#
# font.c: fonts, their glyphs, and OpenType substitution and positioning
#

Glyph: adt {
	id:	string;		# device-dependent glyph identifier
	name:	string;		# the first character mapped to this glyph
	font:	cyclic ref Font;	# the glyph's font
	idx:	int;		# its index in font.gl
	wid:	int;		# character width
	llx, lly, urx, ury:	int;	# bounding box
	typ:	int;		# character type; ascender/descender
};

# flags for patterns
GF_PAT:	con 1;		# a gsub/gpos pattern glyph
GF_REP:	con 2;		# a gsub replacement glyph
GF_CON:	con 4;		# a context glyph
GF_GRP:	con 8;		# a glyph group

# a glyph substitution or positioning rule; its patterns as arrays
Grule: adt {
	g:	array of int;	# glyph index (or group)
	flg:	array of int;	# GF_* flags
	x, y, xadv, yadv:	array of int;	# gpos data
	sec:	int;		# rule section (OFF lookup)
	feat, scrp, lang:	int;	# the rule's feature, script and language
};

Font: adt {
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
	feat_name:	array of string;	# feature names
	feat_set:	array of int;	# feature enabled
	scrp_name:	array of string;	# script names
	scrp:		int;		# the current script
	lang_name:	array of string;	# language names
	lang:		int;		# the current language
	gsub:		array of ref Grule;	# glyph substitution rules
	gsub_n:		int;
	gpos:		array of ref Grule;	# glyph positioning rules
	gpos_n:		int;
	gsub0:		ref Iset;	# rules matching a glyph at position 0
	gpos0:		ref Iset;
	ggrp:		ref Iset;	# glyphs of each group
	ggrp_rev:	ref Iset;	# groups of each glyph
};

# convert wid in device unitwidth size to size sz
DEVWID(sz: int, wid: int): int
{
	return (wid * sz + dev_uwid / 2) / dev_uwid;
}

# find a glyph by its name
font_find(fnt: ref Font, name: string): ref Glyph
{
	i := dict_get(fnt.ch_map, name);
	if(i == -1)		# -2 means the glyph has been unmapped
		i = dict_get(fnt.ch_dict, name);
	if(i >= 0)
		return fnt.gl[i];
	return nil;
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
		gl := array[len fnt.gl + 1024] of ref Glyph;
		gl[0:] = fnt.gl;
		fnt.gl = gl;
	}
	g := ref Glyph(id, name, fnt, fnt.gl_n, 0, 0, 0, 0, 0, typ);
	fnt.gl[fnt.gl_n] = g;
	dict_put(fnt.gl_dict, id, fnt.gl_n);
	return fnt.gl_n++;
}

# map character name to the glyph id; remove the mapping if id is nil
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
	return 0;
}

# whether character name has been mapped with font_map()
font_mapped(fnt: ref Font, name: string): int
{
	return dict_get(fnt.ch_map, name) != -1;
}

# enable or disable ligatures; the first bit for liga, the second for rlig
font_featlg(fnt: ref Font, val: int): int
{
	ret := 0;
	ret |= font_feat(fnt, "liga", val & 1);
	ret |= font_feat(fnt, "rlig", val & 2) << 1;
	return ret;
}

# enable or disable pairwise kerning
font_featkn(fnt: ref Font, val: int): int
{
	return font_feat(fnt, "kern", val);
}

# glyph index in fnt.gl
font_idx(nil: ref Font, g: ref Glyph): int
{
	if(g != nil)
		return g.idx;
	return -1;
}

font_gpatmatch(fnt: ref Font, r: ref Grule, j: int, g: int): int
{
	if(!(r.flg[j] & GF_GRP))
		return r.g[j] == g;
	return iset_has(fnt.ggrp_rev, g, r.g[j]);
}

# whether rule matches the glyphs src[soff:soff+slen], after dst[doff-dlen:doff]
font_rulematch(fnt: ref Font, rule: ref Grule,
		src: array of int, soff, slen: int, dst: array of int, doff, dlen: int): int
{
	sidx := 0;		# the index of matched glyphs in src
	ncon := 0;		# the number of initial context glyphs
	# enable only the active script if set
	if(fnt.scrp >= 0 && fnt.scrp != rule.scrp)
		return 0;
	# enable common script features and those in the active language
	if(rule.lang >= 0 && fnt.lang != rule.lang)
		return 0;
	if(rule.feat < 0 || !fnt.feat_set[rule.feat])
		return 0;
	n := len rule.g;
	# the number of initial context glyphs
	j: int;
	for(j = 0; j < n && rule.flg[j] & GF_CON; j++)
		ncon++;
	if(dlen < ncon)
		return 0;
	# matching the base pattern
	for(; j < n; j++){
		if(rule.flg[j] & GF_REP)
			continue;
		if(sidx >= slen || !font_gpatmatch(fnt, rule, j, src[soff + sidx]))
			return 0;
		sidx++;
	}
	# matching the initial context
	for(j = 0; j < n && rule.flg[j] & GF_CON; j++)
		if(!font_gpatmatch(fnt, rule, j, dst[doff + j - ncon]))
			return 0;
	return 1;
}

# find a matching gsub or gpos rule from idx + 1; returns it and its idx
font_findrule(fnt: ref Font, gsub: int, pos: int,
		fwd: array of int, foff, fwdlen: int, ctx: array of int, coff, ctxlen: int, idx: int): (int, int)
{
	rules := fnt.gpos;
	set := fnt.gpos0;
	if(gsub){
		rules = fnt.gsub;
		set = fnt.gsub0;
	}
	r1 := iset_get(set, fwd[foff]);
	while(++idx < len r1){
		if(r1[idx] >= pos && font_rulematch(fnt, rules[r1[idx]],
				fwd, foff, fwdlen, ctx, coff, ctxlen))
			return (r1[idx], idx);
	}
	return (-1, idx);
}

# perform every gpos rule that applies to src
font_performgpos(fnt: ref Font, src: array of int, slen: int,
		x, y, xadv, yadv: array of int)
{
	gpos := fnt.gpos;
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
			rule := gpos[r];
			if(rule.sec > 0 && rule.sec <= lastsec)
				continue;	# perform at most one rule from each lookup
			lastsec = rule.sec;
			for(k := 0; k < len rule.g; k++){
				x[i + k] += rule.x[k];
				y[i + k] += rule.y[k];
				xadv[i + k] += rule.xadv[k];
				yadv[i + k] += rule.yadv[k];
			}
			if(rule.feat == curs_feat){
				curs_cur = 1;
				if(curs_beg < 0)
					curs_beg = i;
				for(k = 0; k < len rule.g; k++)
					curs_dif += rule.yadv[k];
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

# apply rule to all its matches in src
font_gsubapply(fnt: ref Font, rule: ref Grule, src: array of int, slen: int, smap: array of int): int
{
	dst := array[WORDLEN] of {* => 0};
	dmap := array[WORDLEN] of {* => 0};
	dlen := 0;
	for(i := 0; i < slen; i++){
		dmap[dlen] = smap[i];
		if(font_rulematch(fnt, rule, src, i, slen - i, dst, dlen, dlen)){
			for(j := 0; j < len rule.g; j++){
				if(rule.flg[j] & GF_REP)
					dst[dlen++] = rule.g[j];
				if(rule.flg[j] & GF_PAT)
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
	i := -1;
	while(++i >= 0){
		if((i = font_firstgsub(fnt, i, src, slen)) < 0)
			break;
		slen = font_gsubapply(fnt, fnt.gsub[i], src, slen, smap);
	}
	return slen;
}

# lay out the glyphs gsrc; returns their number in gdst
font_layout(fnt: ref Font, gsrc: array of ref Glyph, nsrc: int, nil: int,
		gdst: array of ref Glyph, dmap: array of int,
		x, y, xadv, yadv: array of int, lg, kn: int): int
{
	dst := array[WORDLEN] of {* => 0};
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
	ndst = font_performgsub(fnt, dst, ndst, dmap);
	if(lg)
		font_featlg(fnt, featlg);
	# positioning rules
	featkn := 0;
	if(kn)
		featkn = font_featkn(fnt, 1);
	font_performgpos(fnt, dst, ndst, x, y, xadv, yadv);
	if(kn)
		font_featkn(fnt, featkn);
	for(i = 0; i < ndst; i++)
		gdst[i] = fnt.gl[dst[i]];
	return ndst;
}

font_readchar(fnt: ref Font, fin: ref Toks, n: int, gid: int): (int, int, int)
{
	name := fin.tok();
	tok := fin.tok();
	if(name == nil || tok == nil)
		return (1, n, gid);
	if(name == "---")
		name = sys->sprint("c%.4d", n);
	if(tok != "\""){
		(typ, ok) := fin.num();
		id := fin.tok();
		if(!ok || id == nil)
			return (1, n, gid);
		gid = font_glyphput(fnt, id, name, typ);
		g := fnt.gl[gid];
		# sscanf(tok, "%hd,%hd,%hd,%hd,%hd")
		v := array[5] of {* => 0};
		i := 0;
		for(k := 0; k < 5; k++){
			if(k > 0){
				if(i >= len tok || tok[i] != ',')
					break;
				i++;
			}
			neg := 0;
			if(i < len tok && (tok[i] == '-' || tok[i] == '+')){
				neg = tok[i] == '-';
				i++;
			}
			if(i >= len tok || !isdigit(tok[i]))
				break;
			m := 0;
			while(i < len tok && isdigit(tok[i]))
				m = m * 10 + tok[i++] - '0';
			if(neg)
				m = -m;
			v[k] = m;
		}
		g.wid = v[0];
		g.llx = v[1];
		g.lly = v[2];
		g.urx = v[3];
		g.ury = v[4];
		dict_put(fnt.ch_dict, name, gid);
		n++;
	}else
		dict_put(fnt.ch_map, name, gid);
	return (0, n, gid);
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

newrule(n: int, sec, feat, scrp, lang: int): ref Grule
{
	return ref Grule(array[n] of {* => 0}, array[n] of {* => 0},
		array[n] of {* => 0}, array[n] of {* => 0},
		array[n] of {* => 0}, array[n] of {* => 0},
		sec, feat, scrp, lang);
}

font_gsub(fnt: ref Font, n: int, sec, feat, scrp, lang: int): ref Grule
{
	if(fnt.gsub_n == len fnt.gsub){
		a := array[len fnt.gsub + 1024] of ref Grule;
		a[0:] = fnt.gsub;
		fnt.gsub = a;
	}
	r := newrule(n, sec, feat, scrp, lang);
	fnt.gsub[fnt.gsub_n++] = r;
	return r;
}

font_gpos(fnt: ref Font, n: int, sec, feat, scrp, lang: int): ref Grule
{
	if(fnt.gpos_n == len fnt.gpos){
		a := array[len fnt.gpos + 1024] of ref Grule;
		a[0:] = fnt.gpos;
		fnt.gpos = a;
	}
	r := newrule(n, sec, feat, scrp, lang);
	fnt.gpos[fnt.gpos_n++] = r;
	return r;
}

# read pattern j of r from s; whether it is invalid
font_readgpat(fnt: ref Font, r: ref Grule, j: int, s: string): int
{
	if(isdigit(at(s, 0)))
		r.g[j] = atoi(s);
	else if(at(s, 0) == '@'){
		r.g[j] = atoi(s[1:]);
		if(iset_len(fnt.ggrp, r.g[j]) == 1)
			r.g[j] = iset_get(fnt.ggrp, r.g[j])[0];
		else
			r.flg[j] |= GF_GRP;
	}else
		r.g[j] = font_idx(fnt, font_glyph(fnt, s));
	return r.g[j] < 0 || r.g[j] >= fnt.gl_n;
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

font_readgsub(fnt: ref Font, fin: ref Toks, n: int, sec, feat, scrp, lang: int): int
{
	rule := font_gsub(fnt, n, sec, feat, scrp, lang);
	for(i := 0; i < n; i++){
		tok := fin.tok();
		if(tok == nil)
			return 1;
		case tok[0] {
		'-' =>
			rule.flg[i] = GF_PAT;
		'=' =>
			rule.flg[i] = GF_CON;
		'+' =>
			rule.flg[i] = GF_REP;
		}
		if(font_readgpat(fnt, rule, i, tok[1:]))
			return 0;
	}
	return 0;
}

font_readgpos(fnt: ref Font, fin: ref Toks, n: int, sec, feat, scrp, lang: int): int
{
	rule := font_gpos(fnt, n, sec, feat, scrp, lang);
	for(i := 0; i < n; i++){
		tok := fin.tok();
		if(tok == nil)
			return 1;
		col := strchr(tok, ':');
		pos: string;
		if(col >= 0){
			pos = tok[col+1:];
			tok = tok[0:col];
		}
		rule.flg[i] = GF_PAT;
		if(tok == nil || font_readgpat(fnt, rule, i, tok))
			return 0;
		if(col >= 0){
			v := scannums(pos, 4);
			rule.x[i] = v[0];
			rule.y[i] = v[1];
			rule.xadv[i] = v[2];
			rule.yadv[i] = v[3];
		}
	}
	return 0;
}

# up to n signed numbers in s, as sscanf("%hd%hd%hd%hd") reads them
scannums(s: string, n: int): array of int
{
	v := array[n] of {* => 0};
	i := 0;
	for(k := 0; k < n; k++){
		while(i < len s && isspace(s[i]))
			i++;
		neg := 0;
		if(i < len s && (s[i] == '-' || s[i] == '+')){
			neg = s[i] == '-';
			i++;
		}
		if(i >= len s || !isdigit(s[i]))
			break;
		m := 0;
		while(i < len s && isdigit(s[i]))
			m = m * 10 + s[i++] - '0';
		if(neg)
			m = -m;
		v[k] = m;
	}
	return v;
}

font_readggrp(fnt: ref Font, fin: ref Toks): int
{
	(id, ok1) := fin.num();
	(n, ok2) := fin.num();
	if(!ok1 || !ok2)
		return 1;
	for(i := 0; i < n; i++){
		tok := fin.tok();
		if(tok == nil)
			return 1;
		g: int;
		if(isdigit(tok[0]))
			g = atoi(tok);
		else
			g = font_idx(fnt, font_glyph(fnt, tok));
		if(g >= 0 && g < fnt.gl_n){
			iset_put(fnt.ggrp, id, g);
			iset_put(fnt.ggrp_rev, g, id);
		}
	}
	return 0;
}

font_readkern(fnt: ref Font, fin: ref Toks): int
{
	c1 := fin.tok();
	c2 := fin.tok();
	(val, ok) := fin.num();
	if(c1 == nil || c2 == nil || !ok)
		return 1;
	rule := font_gpos(fnt, 2, 0, font_findfeat(fnt, "kern"), -1, -1);
	rule.g[0] = font_idx(fnt, font_glyph(fnt, c1));
	rule.g[1] = font_idx(fnt, font_glyph(fnt, c2));
	rule.xadv[0] = val;
	rule.flg[0] = GF_PAT;
	rule.flg[1] = GF_PAT;
	return 0;
}

font_lig(fnt: ref Font, lig: string)
{
	n := len lig;
	rule := font_gsub(fnt, n + 1, 0, font_findfeat(fnt, "liga"), -1, -1);
	for(j := 0; j < n; j++){
		rule.g[j] = font_idx(fnt, font_find(fnt, lig[j:j+1]));
		rule.flg[j] = GF_PAT;
	}
	rule.g[n] = font_idx(fnt, font_find(fnt, lig));
	rule.flg[n] = GF_REP;
}

# the first pattern of a rule that is neither a replacement nor context
font_rulefirstpat(r: ref Grule): int
{
	for(i := 0; i < len r.g; i++)
		if(!(r.flg[i] & (GF_REP | GF_CON)))
			return i;
	return -1;
}

font_isetinsert(fnt: ref Font, iset: ref Iset, rule: int, r: ref Grule, j: int)
{
	if(j < 0)
		return;
	if(r.flg[j] & GF_GRP){
		gs := iset_get(fnt.ggrp, r.g[j]);
		for(k := 0; k < len gs; k++)
			iset_put(iset, gs[k], rule);
	}else if(r.g[j] >= 0)
		iset_put(iset, r.g[j], rule);
}

font_open(path: string): ref Font
{
	fin := toks_open(path);
	if(fin == nil)
		return nil;
	fnt := ref Font;
	fnt.gl = array[1024] of ref Glyph;
	fnt.gl_dict = dict_make(1024);
	fnt.ch_dict = dict_make(1024);
	fnt.ch_map = dict_make(1024);
	fnt.feat_name = array[NFEATS] of string;
	fnt.feat_set = array[NFEATS] of {* => 0};
	fnt.scrp_name = array[NSCRPS] of string;
	fnt.lang_name = array[NLANGS] of string;
	fnt.gsub = array[1024] of ref Grule;
	fnt.gpos = array[1024] of ref Grule;
	fnt.ggrp = iset_make();
	fnt.ggrp_rev = iset_make();
	ch_g := -1;		# the last glyph in the charset
	ch_n := 0;		# the number of glyphs in the charset
	ligs: list of string;
	sec := 0;
	feat := 0;
	scrp := 0;
	lang := 0;
	sec_gpos := 0;		# 0: gsub, 1: gpos
	err: int;
read:	while((tok := fin.tok()) != nil){
		case tok {
		"char" =>
			(nil, ch_n, ch_g) = font_readchar(fnt, fin, ch_n, ch_g);
		"kern" =>
			font_readkern(fnt, fin);
		"ligatures" =>
			while((tok = fin.tok()) != nil){
				if(tok == "0")
					break;
				ligs = tok :: ligs;
			}
		"gsec" =>
			(sec, sec_gpos, feat, scrp, lang) = font_readgsec(fnt, fin.rest(),
				sec, sec_gpos, feat, scrp, lang);
			continue;
		"gsub" =>
			tok = fin.tok();
			(cnt, ok) := fin.num();
			if(tok != nil && ok){
				(feat, scrp, lang) = font_readfeat(fnt, tok);
				font_readgsub(fnt, fin, cnt, sec, feat, scrp, lang);
			}
		"gpos" =>
			tok = fin.tok();
			(cnt, ok) := fin.num();
			if(tok != nil && ok){
				(feat, scrp, lang) = font_readfeat(fnt, tok);
				font_readgpos(fnt, fin, cnt, sec, feat, scrp, lang);
			}
		"ggrp" =>
			font_readggrp(fnt, fin);
		"spacewidth" =>
			(fnt.spacewid, nil) = fin.num();
		"special" =>
			fnt.special = 1;
		"name" =>
			fnt.name = fin.tok();
		"fontname" =>
			fnt.fontname = fin.tok();
		"charset" =>
			for(;;){
				(err, ch_n, ch_g) = font_readchar(fnt, fin, ch_n, ch_g);
				if(err)
					break;
				fin.skip();
			}
			break read;
		* =>
			if(isdigit(tok[0])){
				if(sec_gpos)	# a compact gpos rule
					font_readgpos(fnt, fin, atoi(tok), sec, feat, scrp, lang);
				else		# a compact gsub rule
					font_readgsub(fnt, fin, atoi(tok), sec, feat, scrp, lang);
			}
		}
		fin.skip();
	}
	# the ligatures in the order they were listed
	rl: list of string;
	for(; ligs != nil; ligs = tl ligs)
		rl = hd ligs :: rl;
	for(; rl != nil; rl = tl rl)
		font_lig(fnt, hd rl);
	fin.f.close();
	fnt.gsub0 = iset_make();
	fnt.gpos0 = iset_make();
	for(i := 0; i < fnt.gsub_n; i++)
		font_isetinsert(fnt, fnt.gsub0, i, fnt.gsub[i], font_rulefirstpat(fnt.gsub[i]));
	for(i = 0; i < fnt.gpos_n; i++)
		font_isetinsert(fnt, fnt.gpos0, i, fnt.gpos[i], font_rulefirstpat(fnt.gpos[i]));
	fnt.scrp = -1;
	fnt.lang = -1;
	return fnt;
}

# a gsec line: its section, gsub or gpos, and its feature
font_readgsec(fnt: ref Font, ln: string, sec, gpos, feat, scrp, lang: int): (int, int, int, int, int)
{
	t := ref Toks(nil, ln, 0, 1);
	(s, ok) := t.num();
	if(ok)
		sec = s;
	cmd := t.tok();
	if(ok && cmd != nil){
		gpos = cmd == "gpos";
		tok := t.tok();
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
	sz = font_zoom(fnt, sz);
	if(w >= 0)
		return DEVWID(sz, w);
	return -DEVWID(sz, -w);
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

# glyph width, where cfn is the current font and fnt the glyph's
font_gwid(fnt: ref Font, cfn: ref Font, sz: int, w: int): int
{
	xfn := cfn;
	if(xfn == nil)
		xfn = fnt;
	if(xfn.cs){
		s := sz;
		if(xfn.cs_ps)
			s = xfn.cs_ps;
		return xfn.cs * (font_zoom(fnt, s) * SC_IN() / 72) / 36;
	}
	r := font_wid(fnt, sz, w);
	if(cfn != nil)
		r += font_twid(fnt, sz);
	if(font_getbd(xfn))
		r += font_getbd(xfn) - 1;
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
	idx := font_findfeat(fnt, name);
	old := 0;
	if(idx >= 0){
		old = fnt.feat_set[idx];
		fnt.feat_set[idx] = val != 0;
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
