#
# otf.c: OpenType and TrueType fonts
#

NGLYPHS: con 1 << 16;
GNLEN: con 64;		# the longest glyph name, and one
GCTXLEN: con 16;	# context coverage arrays

fb: array of byte;	# the font file

glyph_name: array of string;
glyph_code: array of int;
glyph_bbox: array of int;	# four a glyph
glyph_wid: array of int;
glyph_n := 0;
upm := 0;			# units per em
sec := 0;			# the current section (lookup index * 10)

Otf: adt {
	otf:	int;		# the collection's header or the offset table
	off:	int;		# the offset table
	name:	string;		# the font's name
};

U8(o: int): int
{
	return int fb[o];
}

U16(o: int): int
{
	return (int fb[o] << 8) | int fb[o + 1];
}

S16(o: int): int
{
	v := (int fb[o] << 8) | int fb[o + 1];
	if(v >= 16r8000)
		v -= 16r10000;
	return v;
}

U32(o: int): int
{
	return (int fb[o] << 24) | (int fb[o + 1] << 16) | (int fb[o + 2] << 8) | int fb[o + 3];
}

owid(w: int): int
{
	if(w < 0)
		return (w * 1000 - upm / 2) / upm;
	return (w * 1000 + upm / 2) / upm;
}

uwid(w: int): int
{
	dv := 72000 / res;
	if(w < 0)
		return (owid(w) - dv / 20) * 10 / dv;
	return (owid(w) + dv / 20) * 10 / dv;
}

# whether the script is written right to left
otf_r2l(feat: string): int
{
	scrp := feat[strchr(feat, ':') + 1:];
	return scrp == "arab" || scrp == "hebr";
}

# a glyph's name, or its index if the name is long
gname(id: int): string
{
	if(byname || len glyph_name[id] < 4)
		return glyph_name[id];
	return string id;
}

otf_unsupported(sub: string, typ, fmt: int)
{
	if(warn){
		s := sys->sprint("mkfn: unsupported %s lookup %d", sub, typ);
		if(fmt > 0)
			s += sys->sprint(" format %d", fmt);
		sys->fprint(sys->fildes(2), "%s\n", s);
	}
}

tag(o: int): string
{
	return string fb[o:o + 4];
}

# the table of the given name; -1 if there is none
otf_table(otf: ref Otf, name: string): int
{
	nrecs := U16(otf.off + 4);
	for(i := 0; i < nrecs; i++){
		rec := otf.off + 12 + i * 16;
		if(tag(rec) == name)
			return otf.otf + U32(rec + 8);
	}
	return -1;
}

# the font's PostScript name, from the name table
otf_name(otf: ref Otf, tab: int)
{
	str := tab + U16(tab + 4);
	n := U16(tab + 2);
	for(i := 0; i < n; i++){
		rec := tab + 6 + 12 * i;
		if(U16(rec) == 1 && U16(rec + 2) == 0 && U16(rec + 4) == 0 && U16(rec + 6) == 6){
			l := U16(rec + 8);
			o := str + U16(rec + 10);
			if(l > 127)
				l = 127;
			otf.name = cstr(fb[o:o + l]);
		}
	}
}

# bytes as C reads a string in them: to the first NUL
cstr(b: array of byte): string
{
	for(i := 0; i < len b; i++)
		if(b[i] == byte 0)
			return string b[0:i];
	return string b;
}

otf_cmap4(nil: ref Otf, cmap4: int)
{
	nsegs := U16(cmap4 + 6) / 2;
	ends := cmap4 + 14;
	begs := ends + 2 * nsegs + 2;
	deltas := begs + 2 * nsegs;
	offsets := deltas + 2 * nsegs;
	for(i := 0; i < nsegs; i++){
		beg := U16(begs + 2 * i);
		end := U16(ends + 2 * i);
		delta := U16(deltas + 2 * i);
		offset := U16(offsets + 2 * i);
		if(offset){
			for(j := beg; j <= end; j++)
				glyph_code[(U16(offsets + 2 * i + offset + (j - beg) * 2) + delta) & 16rffff] = j;
		}else{
			for(j := beg; j <= end; j++)
				glyph_code[(j + delta) & 16rffff] = j;
		}
	}
}

otf_cmap(otf: ref Otf, cmap: int)
{
	nrecs := U16(cmap + 2);
	for(i := 0; i < nrecs; i++){
		rec := cmap + 4 + i * 8;
		tab := cmap + U32(rec + 4);
		if(U16(rec) == 3 && U16(rec + 2) == 1 && U16(tab) == 4)
			otf_cmap4(otf, tab);
	}
}

otf_post(nil: ref Otf, post: int)
{
	if(U32(post) != 16r20000)
		return;
	post2 := post + 32;
	glyph_n = U16(post2);
	index := post2 + 2;
	names := index + 2 * glyph_n;
	cname := 0;
	for(i := 0; i < glyph_n; i++){
		idx := U16(index + 2 * i);
		if(idx < 258)
			glyph_name[i] = macset[idx];
		else{
			l := U8(names + cname);
			glyph_name[i] = cstr(fb[names + cname + 1:names + cname + 1 + l]);
			cname += l + 1;
		}
	}
}

otf_glyf(otf: ref Otf, glyf: int)
{
	maxp := otf_table(otf, "maxp");
	head := otf_table(otf, "head");
	loca := otf_table(otf, "loca");
	n := U16(maxp + 4);
	fmt := U16(head + 50);
	if(!glyph_n)
		glyph_n = n;
	for(i := 0; i < n; i++){
		gdat, gnext: int;
		if(fmt){
			gdat = glyf + U32(loca + 4 * i);
			gnext = glyf + U32(loca + 4 * (i + 1));
		}else{
			gdat = glyf + U16(loca + 2 * i) * 2;
			gnext = glyf + U16(loca + 2 * (i + 1)) * 2;
		}
		if(gdat < gnext)
			for(j := 0; j < 4; j++)
				glyph_bbox[4 * i + j] = S16(gdat + 2 + 2 * j);
	}
}

otf_hmtx(otf: ref Otf, hmtx: int)
{
	hhea := otf_table(otf, "hhea");
	n := U16(hhea + 34);
	for(i := 0; i < n; i++)
		glyph_wid[i] = U16(hmtx + i * 4);
	for(i = n; i < glyph_n; i++)
		glyph_wid[i] = glyph_wid[n - 1];
}

otf_kern(nil: ref Otf, kern: int)
{
	off := 4;
	n := U16(kern + 2);
	for(i := 0; i < n; i++){
		tab := kern + off;
		cov := U16(tab + 4);
		off += U16(tab + 2);
		if((cov >> 8) == 0 && (cov & 1)){
			npairs := U16(tab + 6);
			for(j := 0; j < npairs; j++){
				c1 := U16(tab + 14 + 6 * j);
				c2 := U16(tab + 14 + 6 * j + 2);
				val := S16(tab + 14 + 6 * j + 4);
				mkfn_kern(glyph_name[c1], glyph_name[c2], uwid(val));
			}
		}
	}
}

# the glyphs a coverage table covers
coverage(cov: int): array of int
{
	fmt := U16(cov);
	n := U16(cov + 2);
	if(fmt == 1){
		a := array[n] of int;
		for(i := 0; i < n; i++)
			a[i] = U16(cov + 4 + 2 * i);
		return a;
	}
	if(fmt == 2){
		cnt := 0;
		for(i := 0; i < n; i++){
			beg := U16(cov + 4 + 6 * i);
			end := U16(cov + 4 + 6 * i + 2);
			if(end >= beg)
				cnt += end - beg + 1;
		}
		a := array[cnt] of int;
		cnt = 0;
		for(i = 0; i < n; i++){
			beg := U16(cov + 4 + 6 * i);
			end := U16(cov + 4 + 6 * i + 2);
			for(j := beg; j <= end; j++)
				a[cnt++] = j;
		}
		return a;
	}
	return array[0] of int;
}

# the glyphs a class definition table defines and their classes
classdef(tab: int): (array of int, array of int)
{
	fmt := U16(tab);
	if(fmt == 1){
		beg := U16(tab + 2);
		ngl := U16(tab + 4);
		gl := array[ngl] of int;
		cls := array[ngl] of int;
		for(i := 0; i < ngl; i++){
			gl[i] = beg + i;
			cls[i] = U16(tab + 6 + 2 * i);
		}
		return (gl, cls);
	}
	if(fmt == 2){
		n := U16(tab + 2);
		ngl := 0;
		for(i := 0; i < n; i++){
			beg := U16(tab + 4 + 6 * i);
			end := U16(tab + 4 + 6 * i + 2);
			if(end >= beg)
				ngl += end - beg + 1;
		}
		gl := array[ngl] of int;
		cls := array[ngl] of int;
		ngl = 0;
		for(i = 0; i < n; i++){
			beg := U16(tab + 4 + 6 * i);
			end := U16(tab + 4 + 6 * i + 2);
			for(j := beg; j <= end; j++){
				gl[ngl] = j;
				cls[ngl] = U16(tab + 4 + 6 * i + 4);
				ngl++;
			}
		}
		return (gl, cls);
	}
	return (nil, nil);
}

# sort a in place
isort(a: array of int)
{
	n := len a;
	if(n < 2)
		return;
	if(n < 12){
		for(i := 1; i < n; i++){
			v := a[i];
			j := i;
			for(; j > 0 && a[j - 1] > v; j--)
				a[j] = a[j - 1];
			a[j] = v;
		}
		return;
	}
	m := n / 2;
	isort(a[0:m]);
	isort(a[m:]);
	if(a[m - 1] <= a[m])
		return;
	t := array[m] of int;
	t[0:] = a[0:m];
	i := 0;
	j := m;
	k := 0;
	while(i < m && j < n){
		if(a[j] < t[i])
			a[k++] = a[j++];
		else
			a[k++] = t[i++];
	}
	while(i < m)
		a[k++] = t[i++];
}

ggrp_class(src, cls: array of int, id: int): int
{
	n := 0;
	for(i := 0; i < len src; i++)
		if(cls[i] == id)
			n++;
	g := array[n] of int;
	n = 0;
	for(i = 0; i < len src; i++)
		if(cls[i] == id)
			g[n++] = src[i];
	isort(g);
	return ggrp_make(g);
}

# the glyphs of cov in class 0 of the class definition gl, cls
ggrp_class0(cov, gl, cls: array of int): int
{
	g := array[len cov] of int;
	n := 0;
	for(i := 0; i < len cov; i++){
		c := 0;
		for(j := 0; j < len gl; j++)
			if(gl[j] == cov[i]){
				c = cls[j];
				break;
			}
		if(c == 0)
			g[n++] = cov[i];
	}
	g = g[0:n];
	isort(g);
	return ggrp_make(g);
}

ggrp_coverage(g: array of int): int
{
	isort(g);
	return ggrp_make(g);
}

valuerecord_len(fmt: int): int
{
	off := 0;
	for(i := 0; i < 8; i++)
		if(fmt & (1 << i))
			off += 2;
	return off;
}

valuerecord_print(fmt: int, rec: int): string
{
	vals := array[8] of {* => 0};
	off := 0;
	for(i := 0; i < 8; i++){
		if(fmt & (1 << i)){
			vals[i] = uwid(S16(rec + off));
			off += 2;
		}
	}
	if(fmt)
		return ":" + sgn(vals[0]) + sgn(vals[1]) + sgn(vals[2]) + sgn(vals[3]);
	return "";
}

valuerecord_small(fmt: int, rec: int): int
{
	off := 0;
	m := kmin;
	if(m < 1)
		m = 1;
	for(i := 0; i < 8; i++){
		if(fmt & (1 << i)){
			if(abs(uwid(S16(rec + off))) >= m)
				return 0;
			off += 2;
		}
	}
	return 1;
}

# single adjustment positioning
otf_gpostype1(nil: ref Otf, sub: int, nil: string)
{
	fmt := U16(sub);
	vfmt := U16(sub + 4);
	vlen := valuerecord_len(vfmt);
	cov := coverage(sub + U16(sub + 2));
	if(fmt == 1){
		for(i := 0; i < len cov; i++){
			if(valuerecord_small(vfmt, sub + 6))
				continue;
			out("1 " + gname(cov[i]) + valuerecord_print(vfmt, sub + 6) + "\n");
		}
	}
	if(fmt == 2){
		nvals := U16(sub + 6);
		for(i := 0; i < nvals; i++){
			if(valuerecord_small(vfmt, sub + 6))
				continue;
			out("1 " + gname(cov[i]) + valuerecord_print(vfmt, sub + 8 + i * vlen) + "\n");
		}
	}
}

# pair adjustment positioning
otf_gpostype2(nil: ref Otf, sub: int, nil: string)
{
	fmt := U16(sub);
	vfmt1 := U16(sub + 4);
	vfmt2 := U16(sub + 6);
	vrlen := valuerecord_len(vfmt1) + valuerecord_len(vfmt2);
	if(fmt == 1){
		nc1 := U16(sub + 8);
		cov := coverage(sub + U16(sub + 2));
		for(i := 0; i < nc1; i++){
			c2 := sub + U16(sub + 10 + 2 * i);
			nc2 := U16(c2);
			for(j := 0; j < nc2; j++){
				second := U16(c2 + 2 + (2 + vrlen) * j);
				fmtoff1 := 2 + (2 + vrlen) * j + 2;
				fmtoff2 := fmtoff1 + valuerecord_len(vfmt1);
				if(valuerecord_small(vfmt1, c2 + fmtoff1) &&
						valuerecord_small(vfmt2, c2 + fmtoff2))
					continue;
				out("2 " + gname(cov[i]) + valuerecord_print(vfmt1, c2 + fmtoff1) +
					" " + gname(second) + valuerecord_print(vfmt2, c2 + fmtoff2) + "\n");
			}
		}
	}
	if(fmt == 2){
		(gl1, cls1) := classdef(sub + U16(sub + 8));
		(gl2, cls2) := classdef(sub + U16(sub + 10));
		ncls1 := U16(sub + 12);
		ncls2 := U16(sub + 14);
		grp1 := array[ncls1] of int;
		grp2 := array[ncls2] of int;
		for(i := 0; i < ncls1; i++)
			grp1[i] = ggrp_class(gl1, cls1, i);
		# the first glyph's class 0 is every glyph of the coverage the
		# class definition gives no other class (not Neatmkfn's, which
		# gives it those the definition lists as 0: Libertinus kerns D
		# and the like by it)
		if(!compat && ncls1 > 0)
			grp1[0] = ggrp_class0(coverage(sub + U16(sub + 2)), gl1, cls1);
		for(i = 0; i < ncls2; i++)
			grp2[i] = ggrp_class(gl2, cls2, i);
		for(i = 0; i < ncls1; i++){
			for(j := 0; j < ncls2; j++){
				fmtoff1 := 16 + (i * ncls2 + j) * vrlen;
				fmtoff2 := fmtoff1 + valuerecord_len(vfmt1);
				if(valuerecord_small(vfmt1, sub + fmtoff1) &&
						valuerecord_small(vfmt2, sub + fmtoff2))
					continue;
				out("2 @" + string grp1[i] + valuerecord_print(vfmt1, sub + fmtoff1) +
					" @" + string grp2[j] + valuerecord_print(vfmt2, sub + fmtoff2) + "\n");
			}
		}
	}
}

# cursive attachment positioning
otf_gpostype3(nil: ref Otf, sub: int, feat: string)
{
	fmt := U16(sub);
	if(fmt != 1)
		return;
	cov := coverage(sub + U16(sub + 2));
	n := U16(sub + 4);
	icnt := 0;
	ocnt := 0;
	for(i := 0; i < n; i++){
		if(U16(sub + 6 + 4 * i))
			ocnt++;
		if(U16(sub + 6 + 4 * i + 2))
			icnt++;
	}
	icov := array[icnt] of int;
	ocov := array[ocnt] of int;
	ocnt = icnt = 0;
	for(i = 0; i < n; i++)
		if(U16(sub + 6 + 4 * i))
			ocov[ocnt++] = cov[i];
	for(i = 0; i < n; i++)
		if(U16(sub + 6 + 4 * i + 2))
			icov[icnt++] = cov[i];
	igrp := ggrp_coverage(icov);
	ogrp := ggrp_coverage(ocov);
	out("gsec " + string sec + " gpos " + feat + "\n");
	for(i = 0; i < n; i++){
		prev := U16(sub + 6 + 4 * i);
		if(prev){
			dx := -uwid(S16(sub + prev + 2));
			dy := -uwid(S16(sub + prev + 4));
			if(otf_r2l(feat))
				dx += uwid(glyph_wid[cov[i]]);
			out("2 @" + string igrp + " " + gname(cov[i]) + ":" +
				sgn(0) + sgn(0) + sgn(dx) + sgn(dy) + "\n");
		}
	}
	out("gsec " + string (sec + 1) + " gpos " + feat + "\n");
	for(i = 0; i < n; i++){
		next := U16(sub + 6 + 4 * i + 2);
		if(next){
			dx := uwid(S16(sub + next + 2)) - uwid(glyph_wid[cov[i]]);
			dy := uwid(S16(sub + next + 4));
			if(otf_r2l(feat))
				dx += uwid(glyph_wid[cov[i]]);
			out("2 " + gname(cov[i]) + " @" + string ogrp + ":" +
				sgn(0) + sgn(0) + sgn(dx) + sgn(dy) + "\n");
		}
	}
}

# a group for each mark class of a mark array
markgroups(marks: int, mcov: array of int, ccnt: int): array of int
{
	cgrp := array[ccnt] of int;
	for(i := 0; i < ccnt; i++){
		cnt := 0;
		for(j := 0; j < len mcov; j++)
			if(U16(marks + 2 + 4 * j) == i)
				cnt++;
		grp := array[cnt] of int;
		cnt = 0;
		for(j = 0; j < len mcov; j++)
			if(U16(marks + 2 + 4 * j) == i)
				grp[cnt++] = mcov[j];
		cgrp[i] = ggrp_coverage(grp);
	}
	return cgrp;
}

# rules for each mark after a base group
markrules(marks: int, mcov: array of int, bgrp: int, feat: string)
{
	for(i := 0; i < len mcov; i++){
		mark := marks + U16(marks + 2 + 4 * i + 2);
		dx := -uwid(S16(mark + 2));
		dy := -uwid(S16(mark + 4));
		if(otf_r2l(feat)){
			dx += uwid(glyph_wid[mcov[i]]);
			dy = -dy;
		}
		out("2 @" + string bgrp + " " + gname(mcov[i]) + ":" +
			sgn(dx) + sgn(dy) + sgn(0) + sgn(0) + "\n");
	}
}

# a base glyph's rule before a mark of a class group
baserule(base: int, g: int, cgrp: int, feat: string)
{
	dx := uwid(S16(base + 2)) - uwid(glyph_wid[g]);
	dy := uwid(S16(base + 4));
	if(otf_r2l(feat)){
		dx += uwid(glyph_wid[g]);
		dy = -dy;
	}
	out("2 " + gname(g) + " @" + string cgrp + ":" +
		sgn(dx) + sgn(dy) + sgn(0) + sgn(0) + "\n");
}

# mark-to-base attachment positioning
otf_gpostype4(nil: ref Otf, sub: int, feat: string)
{
	fmt := U16(sub);
	if(fmt != 1)
		return;
	mcov := coverage(sub + U16(sub + 2));
	bcov := coverage(sub + U16(sub + 4));
	ccnt := U16(sub + 6);
	marks := sub + U16(sub + 8);
	bases := sub + U16(sub + 10);
	bgrp := ggrp_coverage(bcov);
	cgrp := markgroups(marks, mcov, ccnt);
	out("gsec " + string sec + " gpos " + feat + "\n");
	markrules(marks, mcov, bgrp, feat);
	out("gsec " + string (sec + 1) + " gpos " + feat + "\n");
	for(i := 0; i < len bcov; i++)
		for(j := 0; j < ccnt; j++)
			baserule(bases + U16(bases + 2 + ccnt * 2 * i + 2 * j), bcov[i], cgrp[j], feat);
}

# mark-to-ligature attachment positioning; marks at the end of ligatures only
otf_gpostype5(nil: ref Otf, sub: int, feat: string)
{
	fmt := U16(sub);
	if(fmt != 1)
		return;
	mcov := coverage(sub + U16(sub + 2));
	lcov := coverage(sub + U16(sub + 4));
	ccnt := U16(sub + 6);
	marks := sub + U16(sub + 8);
	ligas := sub + U16(sub + 10);
	lgrp := ggrp_coverage(lcov);
	cgrp := markgroups(marks, mcov, ccnt);
	out("gsec " + string sec + " gpos " + feat + "\n");
	markrules(marks, mcov, lgrp, feat);
	out("gsec " + string (sec + 1) + " gpos " + feat + "\n");
	for(i := 0; i < len lcov; i++){
		ligattach := ligas + U16(ligas + 2 + 2 * i);
		comcnt := U16(ligattach);
		k := comcnt - 1;	# the last component only
		if(comcnt == 0)
			continue;
		if(!U16(ligattach + 2 + 2 * ccnt * k))
			continue;
		for(j := 0; j < ccnt; j++)
			baserule(ligattach + U16(ligattach + 2 + 2 * ccnt * k + 2 * j), lcov[i], cgrp[j], feat);
	}
}

# a substitution's context
Gctx: adt {
	bgrp:	array of int;	# backtrack coverage groups
	igrp:	array of int;	# input
	lgrp:	array of int;	# lookahead
	bn, inn, ln:	int;
	seqidx:	int;		# sequence index
};

gctx_len(ctx: ref Gctx, patlen: int): int
{
	if(ctx == nil)
		return 0;
	return ctx.bn + ctx.inn + ctx.ln - patlen;
}

gctx_backtrack(ctx: ref Gctx): string
{
	if(ctx == nil)
		return "";
	s := "";
	for(i := 0; i < ctx.bn; i++)
		s += " =@" + string ctx.bgrp[i];
	for(i = 0; i < ctx.seqidx; i++)
		s += " =@" + string ctx.igrp[i];
	return s;
}

gctx_lookahead(ctx: ref Gctx, patlen: int): string
{
	if(ctx == nil)
		return "";
	s := "";
	for(i := ctx.seqidx + patlen; i < ctx.inn; i++)
		s += " =@" + string ctx.igrp[i];
	for(i = 0; i < ctx.ln; i++)
		s += " =@" + string ctx.lgrp[i];
	return s;
}

subrule(ctx: ref Gctx, src, dst: int)
{
	out(string (2 + gctx_len(ctx, 1)) + gctx_backtrack(ctx) +
		" -" + gname(src) + " +" + gname(dst) + gctx_lookahead(ctx, 1) + "\n");
}

# single substitution
otf_gsubtype1(nil: ref Otf, sub: int, nil: string, ctx: ref Gctx)
{
	fmt := U16(sub);
	cov := coverage(sub + U16(sub + 2));
	if(fmt == 1){
		for(i := 0; i < len cov; i++){
			dst := cov[i] + S16(sub + 4);
			if(dst >= glyph_n || dst < 0)
				continue;
			subrule(ctx, cov[i], dst);
		}
	}
	if(fmt == 2){
		n := U16(sub + 4);
		for(i := 0; i < n; i++)
			subrule(ctx, cov[i], U16(sub + 6 + 2 * i));
	}
}

# alternate substitution
otf_gsubtype3(nil: ref Otf, sub: int, nil: string, ctx: ref Gctx)
{
	fmt := U16(sub);
	if(fmt != 1)
		return;
	cov := coverage(sub + U16(sub + 2));
	n := U16(sub + 4);
	for(i := 0; i < n; i++){
		a := sub + U16(sub + 6 + 2 * i);
		nalt := U16(a);
		for(j := 0; j < nalt; j++)
			subrule(ctx, cov[i], U16(a + 2 + 2 * j));
	}
}

# ligature substitution
otf_gsubtype4(nil: ref Otf, sub: int, nil: string, ctx: ref Gctx)
{
	fmt := U16(sub);
	if(fmt != 1)
		return;
	cov := coverage(sub + U16(sub + 2));
	n := U16(sub + 4);
	for(i := 0; i < n; i++){
		set := sub + U16(sub + 6 + 2 * i);
		nset := U16(set);
		for(j := 0; j < nset; j++){
			lig := set + U16(set + 2 + 2 * j);
			nlig := U16(lig + 2);
			s := string (nlig + 1 + gctx_len(ctx, nlig)) + gctx_backtrack(ctx);
			s += " -" + gname(cov[i]);
			for(k := 0; k < nlig - 1; k++)
				s += " -" + gname(U16(lig + 4 + 2 * k));
			s += " +" + gname(U16(lig)) + gctx_lookahead(ctx, nlig) + "\n";
			out(s);
		}
	}
}

ctxgroups(sub: int, off: int, n: int): array of int
{
	g := array[max(n, GCTXLEN)] of {* => 0};
	for(i := 0; i < n; i++)
		g[i] = ggrp_coverage(coverage(sub + U16(sub + off + 2 + 2 * i)));
	return g;
}

max(a, b: int): int
{
	if(a > b)
		return a;
	return b;
}

# chaining contextual substitution
otf_gsubtype6(otf: ref Otf, sub: int, feat: string, gsub: int)
{
	lulist := gsub + U16(gsub + 8);
	fmt := U16(sub);
	if(fmt != 3){
		otf_unsupported("GSUB", 6, fmt);
		return;
	}
	ctx := ref Gctx;
	off := 2;
	ctx.bn = U16(sub + off);
	ctx.bgrp = ctxgroups(sub, off, ctx.bn);
	off += 2 + 2 * ctx.bn;
	ctx.inn = U16(sub + off);
	ctx.igrp = ctxgroups(sub, off, ctx.inn);
	off += 2 + 2 * ctx.inn;
	ctx.ln = U16(sub + off);
	ctx.lgrp = ctxgroups(sub, off, ctx.ln);
	off += 2 + 2 * ctx.ln;
	nsub := U16(sub + off);	# more than one is not supported
	for(i := 0; i < nsub && i < 1; i++){
		lidx := U16(sub + off + 2 + 4 * i + 2);
		lookup := lulist + U16(lulist + 2 + 2 * lidx);
		ltype := U16(lookup);
		ntabs := U16(lookup + 4);
		ctx.seqidx = U16(sub + off + 2 + 4 * i);
		for(j := 0; j < ntabs; j++){
			tab := lookup + U16(lookup + 6 + 2 * j);
			typ := ltype;
			if(typ == 7){	# extension substitution
				typ = U16(tab + 2);
				tab = tab + U32(tab + 4);
			}
			case typ {
			1 =>
				otf_gsubtype1(otf, tab, feat, ctx);
			3 =>
				otf_gsubtype3(otf, tab, feat, ctx);
			4 =>
				otf_gsubtype4(otf, tab, feat, ctx);
			}
		}
	}
}

# a GSUB or GPOS lookup
Lookup: adt {
	scrp:	string;
	lang:	string;
	feat:	string;
	lookup:	int;		# its index in the lookup list
};

lookups: array of ref Lookup;
nlookups := 0;

addlookup(l: ref Lookup)
{
	if(nlookups == len lookups){
		n := array[2 * len lookups + 64] of ref Lookup;
		n[0:] = lookups[0:nlookups];
		lookups = n;
	}
	lookups[nlookups++] = l;
}

# a feature table's lookups
otf_featrec(gtab: int, featrec: int, stag, ltag: string)
{
	feats := gtab + U16(gtab + 6);
	feat := feats + U16(featrec + 4);
	ftag := cstr(fb[featrec:featrec + 4]);
	n := U16(feat + 2);
	for(i := 0; i < n; i++){
		lookup := U16(feat + 4 + 2 * i);
		# features common to the script's languages are kept once
		j: int;
		for(j = 0; j < nlookups; j++){
			l := lookups[j];
			if(l.lookup == lookup && l.lang == "" && l.scrp == stag && l.feat == ftag)
				break;
		}
		if(j == nlookups)
			addlookup(ref Lookup(stag, ltag, ftag, lookup));
	}
}

# a language table's features
otf_lang(gtab: int, lang: int, stag, ltag: string)
{
	feats := gtab + U16(gtab + 6);
	featidx := U16(lang + 2);
	nfeat := U16(lang + 4);
	if(featidx != 16rffff)
		otf_featrec(gtab, feats + 2 + 6 * featidx, stag, ltag);
	for(i := 0; i < nfeat; i++)
		otf_featrec(gtab, feats + 2 + 6 * U16(lang + 6 + 2 * i), stag, ltag);
}

# a lookup's tag, as liga:latn:ENG
lookuptag(l: ref Lookup): string
{
	if(l.scrp == "*")	# every script's
		return l.feat;
	s := l.feat + ":";
	if(l.scrp != "")
		s += l.scrp;
	else
		s += "DFLT";
	if(l.lang != "")
		s += ":" + l.lang;
	return s;
}

lookupcmp(l1, l2: ref Lookup): int
{
	if(l1.scrp != l2.scrp){
		if(l1.scrp < l2.scrp)
			return -1;
		return 1;
	}
	r1 := mkfn_featrank(l1.scrp, l1.feat);
	r2 := mkfn_featrank(l1.scrp, l2.feat);
	if(r1 != r2)
		return r1 - r2;
	return l1.lookup - l2.lookup;
}

# sort a stably
lookupsort(a: array of ref Lookup)
{
	n := len a;
	if(n < 2)
		return;
	m := n / 2;
	lookupsort(a[0:m]);
	lookupsort(a[m:]);
	t := array[m] of ref Lookup;
	t[0:] = a[0:m];
	i := 0;
	j := m;
	k := 0;
	while(i < m && j < n){
		if(lookupcmp(a[j], t[i]) < 0)
			a[k++] = a[j++];
		else
			a[k++] = t[i++];
	}
	while(i < m)
		a[k++] = t[i++];
}

# the lookups of the features of a GSUB or GPOS table, in order
otf_gtab(gpos: int): array of ref Lookup
{
	scrs := gpos + U16(gpos + 4);
	lookups = nil;
	nlookups = 0;
	nscripts := U16(scrs);
	for(i := 0; i < nscripts; i++){
		grec := scrs + 2 + 6 * i;
		(ok, stag) := mkfn_script(cstr(fb[grec:grec + 4]), nscripts);
		if(!ok)
			continue;
		script := scrs + U16(grec + 4);
		nlangs := U16(script + 2);
		hasdef := U16(script) != 0;
		if(hasdef && mkfn_lang(nil, nlangs + hasdef).t0)
			otf_lang(gpos, script + U16(script), stag, "");
		for(j := 0; j < nlangs; j++){
			lrec := script + 4 + 6 * j;
			(lok, ltag) := mkfn_lang(cstr(fb[lrec:lrec + 4]), nlangs + hasdef);
			if(lok)
				otf_lang(gpos, script + U16(lrec + 4), stag, ltag);
		}
	}
	a := lookups[0:nlookups];
	lookups = nil;
	lookupsort(a);
	if(!compat){
		a = lookupshare(a);
		lookupsort(a);
	}
	return a;
}

# a lookup two scripts' features share (not a language's own) written
# once, for every script ("*"), not once for each (Neatmkfn's): troff,
# with no script chosen, would perform each copy, kerning a pair as
# many times as the font has scripts that kern it
lookupshare(a: array of ref Lookup): array of ref Lookup
{
	b := array[len a] of ref Lookup;
	n := 0;
	for(i := 0; i < len a; i++){
		l := a[i];
		if(l.lang != ""){
			b[n++] = l;
			continue;
		}
		dup := 0;
		for(j := 0; j < n; j++){
			k := b[j];
			if(k.lang == "" && k.feat == l.feat && k.lookup == l.lookup){
				if(k.scrp != l.scrp)
					k.scrp = "*";
				dup = 1;
				break;
			}
		}
		if(!dup)
			b[n++] = ref Lookup(l.scrp, l.lang, l.feat, l.lookup);
	}
	return b[0:n];
}

otf_gpos(otf: ref Otf, gpos: int)
{
	lookuplist := gpos + U16(gpos + 8);
	lus := otf_gtab(gpos);
	if(dry)
		return;
	for(i := 0; i < len lus; i++){
		lookup := lookuplist + U16(lookuplist + 2 + 2 * lus[i].lookup);
		ltype := U16(lookup);
		ntabs := U16(lookup + 4);
		t := lookuptag(lus[i]);
		sec = (i + 1) * 10;
		out("gsec " + string sec + " gpos " + t + "\n");
		for(j := 0; j < ntabs; j++){
			tab := lookup + U16(lookup + 6 + 2 * j);
			typ := ltype;
			if(typ == 9){	# extension positioning
				typ = U16(tab + 2);
				tab = tab + U32(tab + 4);
			}
			case typ {
			1 =>
				otf_gpostype1(otf, tab, t);
			2 =>
				otf_gpostype2(otf, tab, t);
			3 =>
				otf_gpostype3(otf, tab, t);
			4 =>
				otf_gpostype4(otf, tab, t);
			5 =>
				otf_gpostype5(otf, tab, t);
			* =>
				otf_unsupported("GPOS", typ, 0);
			}
		}
	}
}

otf_gsub(otf: ref Otf, gsub: int)
{
	lookuplist := gsub + U16(gsub + 8);
	lus := otf_gtab(gsub);
	if(dry)
		return;
	for(i := 0; i < len lus; i++){
		lookup := lookuplist + U16(lookuplist + 2 + 2 * lus[i].lookup);
		ltype := U16(lookup);
		ntabs := U16(lookup + 4);
		t := lookuptag(lus[i]);
		sec = (i + 1) * 10;
		out("gsec " + string sec + " gsub " + t + "\n");
		for(j := 0; j < ntabs; j++){
			tab := lookup + U16(lookup + 6 + 2 * j);
			typ := ltype;
			if(typ == 7){	# extension substitution
				typ = U16(tab + 2);
				tab = tab + U32(tab + 4);
			}
			case typ {
			1 =>
				otf_gsubtype1(otf, tab, t, nil);
			3 =>
				otf_gsubtype3(otf, tab, t, nil);
			4 =>
				otf_gsubtype4(otf, tab, t, nil);
			6 =>
				otf_gsubtype6(otf, tab, t, gsub);
			* =>
				otf_unsupported("GSUB", typ, 0);
			}
		}
	}
}

#
# CFF
#

# a CFF offset sz bytes long
cff_int(o: int, sz: int): int
{
	n := 0;
	for(i := 0; i < sz; i++)
		n = n * 256 + U8(o + i);
	return n;
}

# a DICT operand or operator: its length and value
cff_op(o: int): (int, int)
{
	b0 := U8(o);
	if(b0 >= 32 && b0 <= 246)
		return (1, b0 - 139);
	if(b0 >= 247 && b0 <= 250)
		return (2, (b0 - 247) * 256 + U8(o + 1) + 108);
	if(b0 >= 251 && b0 <= 254)
		return (2, -(b0 - 251) * 256 - U8(o + 1) - 108);
	if(b0 == 28)
		return (3, (U8(o + 1) << 8) | U8(o + 2));
	if(b0 == 29)
		return (5, (U8(o + 1) << 24) | (U8(o + 2) << 16) | (U8(o + 3) << 8) | U8(o + 4));
	if(b0 == 30){
		i: int;
		for(i = 1; i < 32; i++){
			nib := U8(o + i);
			if((nib & 16r0f) == 16r0f || (nib & 16rf0) == 16rf0)
				break;
		}
		return (i + 1, 0);
	}
	return (1, b0);
}

cffidx_cnt(idx: int): int
{
	return U16(idx);
}

cffidx_get(idx: int, i: int): int
{
	cnt := U16(idx);
	sz := U8(idx + 2);
	return idx + 3 + (cnt + 1) * sz - 1 + cff_int(idx + 3 + i * sz, sz);
}

cffidx_len(idx: int, i: int): int
{
	return cffidx_get(idx, i + 1) - cffidx_get(idx, i);
}

cffidx_end(idx: int): int
{
	return cffidx_get(idx, cffidx_cnt(idx));
}

# the value of key in a DICT
cffdict_get(dict: int, n: int, key: int): int
{
	off := 0;
	op := 0;
	val := 0;
	while(off < n){
		val = op;
		l: int;
		(l, op) = cff_op(dict + off);
		off += l;
		if(op == 12){	# two bytes
			(l, op) = cff_op(dict + off);
			off += l;
			op += 1200;
		}
		if(op == key)
			return val;
	}
	return 0;
}

cff_char(stridx: int, id: int): string
{
	if(id < 391)
		return stdset[id];
	id -= 391;
	l := cffidx_len(stridx, id);
	if(warn && l >= GNLEN)
		sys->fprint(sys->fildes(2), "mkfn: truncating glyph names (GNLEN is too small)\n");
	if(l >= GNLEN)
		l = GNLEN - 1;
	o := cffidx_get(stridx, id);
	return cstr(fb[o:o + l]);
}

otf_cff(otf: ref Otf, cff: int)
{
	if(U8(cff) != 1)
		return;
	nameidx := cff + U8(cff + 2);
	topidx := cffidx_end(nameidx);
	if(cffidx_cnt(nameidx) < 1)
		return;
	stridx := cffidx_end(topidx);
	top := cffidx_get(topidx, 0);
	toplen := cffidx_len(topidx, 0);
	chridx := cff + cffdict_get(top, toplen, 17);
	charset := cff + cffdict_get(top, toplen, 15);
	glyph_n = cffidx_cnt(chridx);
	badcff := cffidx_cnt(chridx) - 391 > cffidx_cnt(stridx);
	glyph_name[0] = ".notdef";
	# the font's name, from the name index
	if(cffidx_cnt(nameidx) > 0){
		o := cffidx_get(nameidx, 0);
		l := cffidx_len(nameidx, 0);
		if(l > 255)
			l = 255;
		name := cstr(fb[o:o + l]);
		if(name != "" && otf.name == ""){
			if(len array of byte name > 127)
				name = string (array of byte name)[0:127];
			otf.name = name;
		}
	}
	# the charset: glyphs' names
	if(!badcff && U8(charset) == 0){
		for(i := 0; i < glyph_n - 1; i++)
			glyph_name[i + 1] = cff_char(stridx, U16(charset + 1 + i * 2));
	}
	if(!badcff && (U8(charset) == 1 || U8(charset) == 2)){
		g := 1;
		sz := 3;
		if(U8(charset) == 2)
			sz = 4;
		for(i := 0; g < glyph_n; i++){
			sid := U16(charset + 1 + i * sz);
			cnt := cff_int(charset + 1 + i * sz + 2, sz - 2);
			for(j := 0; j <= cnt && g < glyph_n; j++){
				glyph_name[g] = cff_char(stridx, sid + j);
				g++;
			}
		}
	}
	if(!compat){
		gsubrs := cffidx_end(stridx);
		if(cffidx_cnt(gsubrs) == 0)
			gsubrs = -1;
		cff_bboxes(cff, top, toplen, chridx, gsubrs);
	}
}

#
# CFF glyphs' bounding boxes, from their Type 2 charstrings (Neatmkfn
# takes them from TrueType's outlines only; without -c, mkfn takes them
# from CFF's too: eqn sizes brackets and places accents by them)
#

# a DICT's operands before key, else nil
cffdict_args(dict: int, n: int, key: int): array of int
{
	args := array[48] of int;
	na := 0;
	off := 0;
	while(off < n){
		b0 := U8(dict + off);
		if(b0 <= 21){
			op := b0;
			off++;
			if(b0 == 12){
				op = 1200 + U8(dict + off);
				off++;
			}
			if(op == key)
				return args[0:na];
			na = 0;
			continue;
		}
		v := 0;
		if(b0 == 28){
			v = S16(dict + off + 1);
			off += 3;
		}else if(b0 == 29){
			v = U32(dict + off + 1);
			off += 5;
		}else if(b0 == 30){
			off++;
			while(off < n && (U8(dict + off) & 16r0f) != 16r0f && (U8(dict + off) & 16rf0) != 16rf0)
				off++;
			off++;
		}else{
			(l, x) := cff_op(dict + off);
			v = x;
			off += l;
		}
		if(na < len args)
			args[na++] = v;
	}
	return nil;
}

# a private DICT's local subroutines (or -1)
cff_subrs(cff: int, top: int, toplen: int): int
{
	p := cffdict_args(top, toplen, 18);
	if(len p < 2)
		return -1;
	s := cffdict_args(cff + p[1], p[0], 19);
	if(len s < 1)
		return -1;
	return cff + p[1] + s[0];
}

cff_bias(idx: int): int
{
	if(idx < 0)
		return 0;
	n := cffidx_cnt(idx);
	if(n < 1240)
		return 107;
	if(n < 33900)
		return 1131;
	return 32768;
}

Cs: adt {
	st:	array of real;
	n:	int;
	x, y:	real;
	stems:	int;
	open:	int;		# no point yet
	bb:	array of real;	# llx lly urx ury
	gsubrs, lsubrs:	int;
	gbias, lbias:	int;
	depth:	int;
	done:	int;
};

cs_pt(c: ref Cs, x, y: real)
{
	if(c.open){
		c.bb[0] = c.bb[2] = x;
		c.bb[1] = c.bb[3] = y;
		c.open = 0;
		return;
	}
	if(x < c.bb[0])
		c.bb[0] = x;
	if(x > c.bb[2])
		c.bb[2] = x;
	if(y < c.bb[1])
		c.bb[1] = y;
	if(y > c.bb[3])
		c.bb[3] = y;
}

cs_line(c: ref Cs, dx, dy: real)
{
	cs_pt(c, c.x, c.y);
	c.x += dx;
	c.y += dy;
	cs_pt(c, c.x, c.y);
}

# a cubic's extremes in one axis, at t in (0, 1)
cs_ext(p0, p1, p2, p3: real): list of real
{
	a := -p0 + 3.0 * p1 - 3.0 * p2 + p3;
	b := 2.0 * (p0 - 2.0 * p1 + p2);
	k := p1 - p0;
	ts: list of real;
	if(a > -1e-9 && a < 1e-9){
		if(b != 0.0)
			ts = -k / b :: nil;
	}else{
		d := b * b - 4.0 * a * k;
		if(d >= 0.0){
			r := math->sqrt(d);
			ts = (-b + r) / (2.0 * a) :: (-b - r) / (2.0 * a) :: nil;
		}
	}
	vs: list of real;
	for(; ts != nil; ts = tl ts){
		t := hd ts;
		if(t > 0.0 && t < 1.0){
			u := 1.0 - t;
			vs = u*u*u*p0 + 3.0*u*u*t*p1 + 3.0*u*t*t*p2 + t*t*t*p3 :: vs;
		}
	}
	return vs;
}

cs_curve(c: ref Cs, dx1, dy1, dx2, dy2, dx3, dy3: real)
{
	x0 := c.x;
	y0 := c.y;
	x1 := x0 + dx1;
	y1 := y0 + dy1;
	x2 := x1 + dx2;
	y2 := y1 + dy2;
	x3 := x2 + dx3;
	y3 := y2 + dy3;
	cs_pt(c, x0, y0);
	cs_pt(c, x3, y3);
	for(xs := cs_ext(x0, x1, x2, x3); xs != nil; xs = tl xs)
		cs_pt(c, hd xs, y0);
	for(ys := cs_ext(y0, y1, y2, y3); ys != nil; ys = tl ys)
		cs_pt(c, x0, hd ys);
	c.x = x3;
	c.y = y3;
}

cs_run(c: ref Cs, o: int, end: int)
{
	if(c.depth > 10)
		return;
	c.depth++;
	st := c.st;
	while(o < end && !c.done){
		b0 := U8(o);
		if(b0 >= 32 || b0 == 28){
			v := 0.0;
			if(b0 == 28){
				v = real S16(o + 1);
				o += 3;
			}else if(b0 <= 246){
				v = real (b0 - 139);
				o++;
			}else if(b0 <= 250){
				v = real ((b0 - 247) * 256 + U8(o + 1) + 108);
				o += 2;
			}else if(b0 <= 254){
				v = real (-(b0 - 251) * 256 - U8(o + 1) - 108);
				o += 2;
			}else{
				v = real U32(o + 1) / 65536.0;	# 16.16, signed
				o += 5;
			}
			if(c.n < len st)
				st[c.n++] = v;
			continue;
		}
		o++;
		n := c.n;
		case b0 {
		1 or 3 or 18 or 23 =>	# hstem vstem hstemhm vstemhm
			c.stems += n / 2;
			c.n = 0;
		19 or 20 =>		# hintmask cntrmask
			c.stems += n / 2;
			c.n = 0;
			o += (c.stems + 7) / 8;
		21 =>			# rmoveto
			if(n >= 2){
				c.x += st[n - 2];
				c.y += st[n - 1];
			}
			c.n = 0;
		22 =>			# hmoveto
			if(n >= 1)
				c.x += st[n - 1];
			c.n = 0;
		4 =>			# vmoveto
			if(n >= 1)
				c.y += st[n - 1];
			c.n = 0;
		5 =>			# rlineto
			for(i := 0; i + 1 < n; i += 2)
				cs_line(c, st[i], st[i + 1]);
			c.n = 0;
		6 or 7 =>		# hlineto vlineto
			h := b0 == 6;
			for(i := 0; i < n; i++){
				if(h)
					cs_line(c, st[i], 0.0);
				else
					cs_line(c, 0.0, st[i]);
				h = !h;
			}
			c.n = 0;
		8 =>			# rrcurveto
			for(i := 0; i + 5 < n; i += 6)
				cs_curve(c, st[i], st[i+1], st[i+2], st[i+3], st[i+4], st[i+5]);
			c.n = 0;
		24 =>			# rcurveline
			i := 0;
			for(; i + 5 < n - 2; i += 6)
				cs_curve(c, st[i], st[i+1], st[i+2], st[i+3], st[i+4], st[i+5]);
			if(i + 1 < n)
				cs_line(c, st[i], st[i + 1]);
			c.n = 0;
		25 =>			# rlinecurve
			i := 0;
			for(; i + 1 < n - 6; i += 2)
				cs_line(c, st[i], st[i + 1]);
			if(i + 5 < n)
				cs_curve(c, st[i], st[i+1], st[i+2], st[i+3], st[i+4], st[i+5]);
			c.n = 0;
		26 =>			# vvcurveto
			i := 0;
			dx1 := 0.0;
			if(n % 4 == 1)
				dx1 = st[i++];
			for(; i + 3 < n; i += 4){
				cs_curve(c, dx1, st[i], st[i+1], st[i+2], 0.0, st[i+3]);
				dx1 = 0.0;
			}
			c.n = 0;
		27 =>			# hhcurveto
			i := 0;
			dy1 := 0.0;
			if(n % 4 == 1)
				dy1 = st[i++];
			for(; i + 3 < n; i += 4){
				cs_curve(c, st[i], dy1, st[i+1], st[i+2], st[i+3], 0.0);
				dy1 = 0.0;
			}
			c.n = 0;
		30 or 31 =>		# vhcurveto hvcurveto
			h := b0 == 31;
			for(i := 0; i + 3 < n; i += 4){
				last := 0.0;
				if(i + 5 == n)
					last = st[i + 4];
				if(h)
					cs_curve(c, st[i], 0.0, st[i+1], st[i+2], last, st[i+3]);
				else
					cs_curve(c, 0.0, st[i], st[i+1], st[i+2], st[i+3], last);
				h = !h;
			}
			c.n = 0;
		10 or 29 =>		# callsubr callgsubr
			if(n < 1)
				break;
			c.n--;
			idx := c.lsubrs;
			bias := c.lbias;
			if(b0 == 29){
				idx = c.gsubrs;
				bias = c.gbias;
			}
			k := int st[c.n] + bias;
			if(idx >= 0 && k >= 0 && k < cffidx_cnt(idx))
				cs_run(c, cffidx_get(idx, k), cffidx_get(idx, k + 1));
		11 =>			# return
			c.depth--;
			return;
		14 =>			# endchar
			c.done = 1;
		12 =>
			e := U8(o++);
			case e {
			35 =>		# flex
				if(n >= 12){
					cs_curve(c, st[0], st[1], st[2], st[3], st[4], st[5]);
					cs_curve(c, st[6], st[7], st[8], st[9], st[10], st[11]);
				}
			34 =>		# hflex
				if(n >= 7){
					cs_curve(c, st[0], 0.0, st[1], st[2], st[3], 0.0);
					cs_curve(c, st[4], 0.0, st[5], -st[2], st[6], 0.0);
				}
			36 =>		# hflex1
				if(n >= 9){
					cs_curve(c, st[0], st[1], st[2], st[3], st[4], 0.0);
					cs_curve(c, st[5], 0.0, st[6], st[7], st[8], -(st[1] + st[3] + st[7]));
				}
			37 =>		# flex1
				if(n >= 11){
					dx := st[0] + st[2] + st[4] + st[6] + st[8];
					dy := st[1] + st[3] + st[5] + st[7] + st[9];
					x6 := 0.0;
					y6 := 0.0;
					if(math->fabs(dx) > math->fabs(dy)){
						x6 = st[10];
						y6 = -dy;
					}else{
						x6 = -dx;
						y6 = st[10];
					}
					cs_curve(c, st[0], st[1], st[2], st[3], st[4], st[5]);
					cs_curve(c, st[6], st[7], st[8], st[9], x6, y6);
				}
			}
			c.n = 0;
		* =>
			c.n = 0;
		}
	}
	c.depth--;
}

# the glyphs' bounding boxes; fdsel and fdarr are CID-keyed fonts'
cff_bboxes(cff: int, top: int, toplen: int, chridx: int, gsubrs: int)
{
	lsubrs := cff_subrs(cff, top, toplen);
	fds: array of int;	# each font DICT's subrs
	fdsel := -1;
	if((a := cffdict_args(top, toplen, 1236)) != nil && len a > 0){
		fdarr := cff + a[0];
		fds = array[cffidx_cnt(fdarr)] of int;
		for(i := 0; i < len fds; i++)
			fds[i] = cff_subrs(cff, cffidx_get(fdarr, i), cffidx_len(fdarr, i));
		if((s := cffdict_args(top, toplen, 1237)) != nil && len s > 0)
			fdsel = cff + s[0];
	}
	c := ref Cs(array[48] of real, 0, 0.0, 0.0, 0, 1, array[4] of real,
		gsubrs, -1, cff_bias(gsubrs), 0, 0, 0);
	for(g := 0; g < glyph_n && g < NGLYPHS; g++){
		c.lsubrs = lsubrs;
		if(fdsel >= 0){
			fd := cff_fdselect(fdsel, g);
			if(fd >= 0 && fd < len fds)
				c.lsubrs = fds[fd];
		}
		c.lbias = cff_bias(c.lsubrs);
		c.n = 0;
		c.x = c.y = 0.0;
		c.stems = 0;
		c.open = 1;
		c.depth = 0;
		c.done = 0;
		{
			cs_run(c, cffidx_get(chridx, g), cffidx_get(chridx, g + 1));
		} exception {
		"array bounds error" =>
			c.open = 1;
		}
		if(!c.open){
			glyph_bbox[4 * g] = int math->floor(c.bb[0]);
			glyph_bbox[4 * g + 1] = int math->floor(c.bb[1]);
			glyph_bbox[4 * g + 2] = int math->ceil(c.bb[2]);
			glyph_bbox[4 * g + 3] = int math->ceil(c.bb[3]);
		}
	}
}

# a CID-keyed font's font DICT for glyph g
cff_fdselect(fdsel: int, g: int): int
{
	case U8(fdsel) {
	0 =>
		return U8(fdsel + 1 + g);
	3 =>
		n := U16(fdsel + 1);
		for(i := 0; i < n; i++){
			r := fdsel + 3 + 3 * i;
			if(g >= U16(r) && g < U16(r + 3))
				return U8(r + 2);
		}
	}
	return -1;
}

otf_feat(otf: ref Otf)
{
	if((t := otf_table(otf, "GSUB")) >= 0)
		otf_gsub(otf, t);
	if((t = otf_table(otf, "GPOS")) >= 0)
		otf_gpos(otf, t);
}

otf_offsettable(base: int, off: int): int
{
	t := U32(off);
	otf := ref Otf(base, off, "");
	if(t != 16r00010000 && t != 16r4F54544F)
		return 1;
	upm = U16(otf_table(otf, "head") + 18);
	otf_name(otf, otf_table(otf, "name"));
	otf_cmap(otf, otf_table(otf, "cmap"));
	otf_post(otf, otf_table(otf, "post"));
	if((g := otf_table(otf, "glyf")) >= 0)
		otf_glyf(otf, g);
	if((c := otf_table(otf, "CFF ")) >= 0)
		otf_cff(otf, c);
	for(i := 0; i < glyph_n; i++){
		if(glyph_name[i] == ""){
			if(glyph_code[i])
				glyph_name[i] = sys->sprint("uni%04X", glyph_code[i]);
			else
				glyph_name[i] = sys->sprint("gl%05X", i);
		}
	}
	otf_hmtx(otf, otf_table(otf, "hmtx"));
	if(!mkfn_font(otf.name))
		return 0;
	for(i = 0; i < glyph_n; i++){
		code := glyph_code[i];
		if(code == 16rffff)
			code = 0;
		b := 4 * i;
		mkfn_char(glyph_name[i], -1, code, uwid(glyph_wid[i]),
			uwid(glyph_bbox[b]), uwid(glyph_bbox[b + 1]),
			uwid(glyph_bbox[b + 2]), uwid(glyph_bbox[b + 3]));
	}
	mkfn_header(otf.name);
	if((k := otf_table(otf, "kern")) >= 0)
		otf_kern(otf, k);
	otf_feat(otf);
	return 0;
}

otf_read(f: ref Iobuf): int
{
	fb = readall(f);
	glyph_name = array[NGLYPHS] of {* => ""};
	glyph_code = array[NGLYPHS] of {* => 0};
	glyph_bbox = array[4 * NGLYPHS] of {* => 0};
	glyph_wid = array[NGLYPHS] of {* => 0};
	ggrp_init();
	{
		if(len fb < 4)
			return 1;
		t := U32(0);
		if(t == 16r00010000 || t == 16r4F54544F)
			return otf_offsettable(0, 0);
		if(t != 16r74746366)
			return 1;
		# a collection
		n := U32(8);
		for(i := 0; i < n; i++)
			otf_offsettable(0, U32(12 + i * 4));
	} exception {
	* =>
		return 1;
	}
	return 0;
}

readall(f: ref Iobuf): array of byte
{
	b := array[1 << 20] of byte;
	n := 0;
	for(;;){
		if(n == len b){
			nb := array[2 * len b] of byte;
			nb[0:] = b;
			b = nb;
		}
		m := f.read(b[n:], len b - n);
		if(m <= 0)
			break;
		n += m;
	}
	return b[0:n];
}

#
# glyph groups
#

ggrp_tab: array of list of (string, int);
ggrp_n := 0;

ggrp_init()
{
	ggrp_tab = array[1024] of list of (string, int);
	ggrp_n = 0;
}

# the group of the glyphs src, made if there is none
ggrp_make(src: array of int): int
{
	k := string len src;
	for(i := 0; i < len src; i++)
		k += " " + string src[i];
	h := tab_hash(k, len ggrp_tab);
	for(l := ggrp_tab[h]; l != nil; l = tl l)
		if((hd l).t0 == k)
			return (hd l).t1;
	id := ggrp_n++;
	ggrp_tab[h] = (k, id) :: ggrp_tab[h];
	s := "ggrp " + string id + " " + string len src;
	for(i = 0; i < len src; i++)
		s += " " + gname(src[i]);
	out(s + "\n");
	return id;
}
