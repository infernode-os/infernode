#
# fmt.c: filling and adjusting lines
#
# Words are collected until a line, or a whole paragraph, can be
# set; then the breaks are chosen to minimise the total cost of the
# lines (fmta_fill), the cost of a line growing with the square of
# how far its spaces stretch or shrink, with hyphens and short last
# lines costing extra.
#

Word: adt {
	s:	string;
	wid:	int;		# the word's width
	elsn, elsp:	int;	# els_neg and els_pos
	gap:	int;		# the space before this word
	hy:	int;		# the hyphen width if inserted after this word
	str:	int;		# does the space before it stretch
	cost:	int;		# the extra cost of a line break after this word
	swid:	int;		# the space width after this word (\w' ')
	totwid, totswid, totscnt:	int;	# widths of words up to this one
	lp, rp:	int;		# protrusion of its first and last glyph (.mtp)
	hyrp:	int;		# the hyphen's, if one is inserted after it
	gw, totgw:	int;	# its glyphs' advances, and theirs up to this one (.mte)
};

# what font expansion (.mte) adds to a line's give, as the width of
# spaces that would give as much: its glyphs (gsum) may widen by .mtes or
# narrow by .mtek thousandths; a space shrinks by .ssh percent at most
fmt_excap(gsum: int, shrink: int): int
{
	if(!shrink)
		return int (big gsum * big nr(R_mtes) / big 1000);
	c := int (big gsum * big nr(R_mtek) / big 1000);
	if(nr(R_ssh) > 0)
		return c * 100 / nr(R_ssh);
	return c;
}

Line: adt {
	sbuf:	string;
	wid, li, ll, lI:	int;
	elsn, elsp:	int;
};

Fmt: adt {
	words:	array of ref Word;	# queued words
	words_n:	int;
	lines:	array of ref Line;	# queued lines
	lines_head, lines_tail:	int;
	gap:	int;		# the space before the next word
	nls:	int;		# newlines before the next word
	nls_sup:	int;	# suppressed newlines
	li, ll, lI:	int;	# the current line's indentation and length
	filled:	int;		# filled all words in the last fmt_fill()
	eos:	int;		# the last word ends a sentence
	fillreq:	int;	# fill after the last word (\p)
	tind:	int;		# the line's indent is .ti's: no protrusion at its left
	parpg, parcnt:	int;	# the page the paragraph's last lines went to, and how many (.wo)
	eject:	int;		# end the page before the next line (.wo)
	ejected:	int;	# ended it, and no line set since
	ejpg, ejd:	int;	# where it was ended: until the trap's macro has run, nothing is set
	trpg, trd:	int;	# the page and place of the trap the last fill saw coming
};

# the protrusion at a line's right: its last word's, or its hyphen's
endrp(w: ref Word): int
{
	if(w.hy)
		return w.hyrp;
	return w.rp;
}

FMT_LLEN(f: ref Fmt): int
{
	return max(0, f.ll - f.li - f.lI);
}

FMT_FILL(nil: ref Fmt): int
{
	return !nr(R_ce) && nr(R_u);
}

FMT_BOTH(nil: ref Fmt): int
{
	return nr(R_u) && !nr(R_na) && !nr(R_ce) && (nr(R_j) & AD_B);
}

# .ll, .in and .ti are delayed until the partial line is output
fmt_confupdate(f: ref Fmt)
{
	f.ll = nr(R_l);
	f.tind = nr(R_ti) >= 0;
	if(nr(R_ti) >= 0)
		f.li = nr(R_ti);
	else
		f.li = nr(R_i);
	if(nr(R_tI) >= 0)
		f.lI = nr(R_tI);
	else
		f.lI = nr(R_I);
	nrset(R_ti, -1);
	nrset(R_tI, -1);
}

fmt_confchanged(f: ref Fmt): int
{
	li := nr(R_i);
	if(nr(R_ti) >= 0)
		li = nr(R_ti);
	lI := nr(R_I);
	if(nr(R_tI) >= 0)
		lI = nr(R_tI);
	return f.ll != nr(R_l) || f.li != li || f.lI != lI;
}

# move words from the buffer to l
fmt_wordscopy(f: ref Fmt, end: int, l: ref Line): int
{
	w := 0;
	l.elsn = 0;
	l.elsp = 0;
	s := l.sbuf;
	for(i := 0; i < end; i++){
		wcur := f.words[i];
		if(wcur.gap)
			s += esch(wcur.gap);
		s += wcur.s;
		w += wcur.wid + wcur.gap;
		if(wcur.elsn < l.elsn)
			l.elsn = wcur.elsn;
		if(wcur.elsp > l.elsp)
			l.elsp = wcur.elsp;
	}
	if(end){
		wcur := f.words[end - 1];
		if(wcur.hy)
			s += "\\(hy";
		w += wcur.hy;
	}
	l.sbuf = s;
	f.words_n -= end;
	f.fillreq -= end;
	for(i = 0; i < f.words_n; i++)
		f.words[i] = f.words[i + end];
	for(; i < f.words_n + end; i++)
		f.words[i] = nil;
	return w;
}

fmt_nlines(f: ref Fmt): int
{
	return f.lines_head - f.lines_tail;
}

# the total width of words in f.words[0:end]
fmt_totwid(f: ref Fmt, end: int): int
{
	if(!end)
		return 0;
	return f.words[end - 1].totwid - f.words[0].totwid +
		f.words[0].wid + f.words[end - 1].hy;
}

# the number of stretchable spaces in f
fmt_scnt(f: ref Fmt, end: int): int
{
	if(end)
		return f.words[end - 1].totscnt - f.words[0].totscnt;
	return 0;
}

# the amount of stretchable spaces in f
fmt_totswid(f: ref Fmt, end: int): int
{
	if(end)
		return f.words[end - 1].totswid - f.words[0].totswid;
	return 0;
}

# the next line in the buffer, or nil
fmt_nextline(f: ref Fmt): ref Line
{
	if(f.lines_head == f.lines_tail)
		return nil;
	l := f.lines[f.lines_tail];
	f.lines[f.lines_tail++] = nil;
	return l;
}

fmt_mkline(f: ref Fmt): ref Line
{
	if(f.lines_head == f.lines_tail){
		f.lines_head = 0;
		f.lines_tail = 0;
	}
	if(f.lines_head == len f.lines){
		a := array[len f.lines + 256] of ref Line;
		a[0:] = f.lines;
		f.lines = a;
	}
	l := ref Line("", 0, f.li, f.ll, f.lI, 0, 0);
	f.lines[f.lines_head++] = l;
	return l;
}

# extract words from f; shrink or stretch spaces if needed
fmt_extractline(f: ref Fmt, end: int, str: int): int
{
	l := fmt_mkline(f);
	llen := FMT_LLEN(f);
	w := fmt_totwid(f, end);
	# protrusion: the line hangs out by its first and last glyphs'
	lp := 0;
	prot := 0;
	if(end > 0){
		if(!f.tind)
			lp = f.words[0].lp;
		prot = lp + endrp(f.words[end - 1]);
	}
	w -= prot;
	if(str && FMT_BOTH(f) && nr(R_j) & AD_K){
		fmt_keshideh(f, end, llen - w);
		w = fmt_totwid(f, end) - prot;
	}
	# font expansion: the line's glyphs take their share of what it
	# lacks or has too much of, as the give of theirs and its spaces'
	# divide it, in steps of .mtep, within .mtes and .mtek
	ex := 0;
	exd := 0;	# what it adds to the line
	if(end > 0 && FMT_BOTH(f) && (llen < w || str) && (nr(R_mtes) || nr(R_mtek))){
		gsum := f.words[end - 1].totgw - f.words[0].totgw + f.words[0].gw + f.words[end - 1].hy;
		d := llen - w;
		sw := fmt_totswid(f, end);
		if(gsum > 0 && d != 0){
			lim := nr(R_mtes);
			sg := sw;
			if(d < 0){
				lim = nr(R_mtek);
				sg = sw * nr(R_ssh) / 100;
			}
			cap := int (big gsum * big lim / big 1000);
			if(cap > 0){
				fd := int (big d * big cap / big (sg + cap));
				ex = int (big fd * big 1000 / big gsum);
				if(ex > lim)
					ex = lim;
				if(ex < -lim)
					ex = -lim;
				ex = ex / max(1, nr(R_mtep)) * max(1, nr(R_mtep));
				# what out.b's scaling makes of the glyphs
				exd = int (big gsum * big (1000 + ex) / big 1000) - gsum;
				w += exd;
			}
		}
	}
	nspc := fmt_scnt(f, end);
	if(nspc && FMT_BOTH(f) && (llen < w || str)){
		fmt_div := (llen - w) / nspc;
		fmt_rem := (llen - w) % nspc;
		if(fmt_rem < 0){
			fmt_div--;
			fmt_rem += nspc;
		}
		for(i := 1; i < end; i++)
			if(f.words[i].str){
				f.words[i].gap += fmt_div;
				if(fmt_rem-- > 0)
					f.words[i].gap++;
			}
	}
	l.wid = fmt_wordscopy(f, end, l) - prot;
	if(lp)
		l.sbuf = sys->sprint("%sh'%du'", ecs(), -lp) + l.sbuf;
	if(ex){
		l.sbuf = sys->sprint("%sX'mtx %d'", ecs(), ex) + l.sbuf;
		l.wid += exd;
	}
	return 0;
}

# output a line break
fmt_break(f: ref Fmt): int
{
	return fmt_extractline(f, f.words_n, 0);
}

# output all collected words
fmt_flush(f: ref Fmt): int
{
	if(FMT_FILL(f) && fmt_fillwords(f, 1))
		return 1;
	if(!FMT_FILL(f) && fmt_break(f))
		return 1;
	f.filled = 0;
	f.nls_sup = 0;
	f.fillreq = 0;
	return 0;
}

fmt_newline(f: ref Fmt): int
{
	f.gap = 0;
	if(!FMT_FILL(f)){
		f.nls++;
		fmt_flush(f);
		return 0;
	}
	if(f.nls && fmt_flush(f))
		return 1;
	if((f.nls || (!f.filled && !f.words_n)) && fmt_break(f))
		return 1;
	f.nls++;
	return 0;
}

# fill as many lines as possible; if br, put the remaining words in a line
fmt_fill(f: ref Fmt, br: int): int
{
	return fmt_fillwords(f, br);
}

fmt_space(f: ref Fmt)
{
	f.gap += font_swid(dev_font(nr(R_f)), nr(R_s), nr(R_ss));
}

# format the paragraph after the next word (\p)
fmt_fillreq(f: ref Fmt): int
{
	if(f.fillreq > 0)
		if(fmt_fillwords(f, 0))
			return 1;
	f.fillreq = f.words_n + 1;
	return 0;
}

fmt_wb2word(f: ref Fmt, wb: ref Wb, hy, str, gap, cost: int)
{
	if(f.words_n == len f.words){
		a := array[len f.words + 256] of ref Word;
		a[0:] = f.words;
		f.words = a;
	}
	word := ref Word;
	prev: ref Word;
	if(f.words_n > 0)
		prev = f.words[f.words_n - 1];
	f.words[f.words_n++] = word;
	word.s = wb_buf(wb);
	word.wid = wb_wid(wb);
	word.elsn = wb.els_neg;
	word.elsp = wb.els_pos;
	word.hy = 0;
	if(hy)
		word.hy = wb_hywid(wb);
	word.str = str;
	word.gap = gap;
	word.cost = cost;
	word.swid = wb_swid(wb);
	word.gw = wb.gw;
	word.lp = wb.pl;
	word.rp = wb.pr;
	word.hyrp = 0;
	if(hy)
		word.hyrp = wb_hyprot(wb);
	word.totwid = word.wid + word.gap;
	word.totswid = 0;
	if(str)
		word.totswid = gap;
	word.totscnt = str != 0;
	word.totgw = word.gw;
	if(prev != nil){
		word.totgw += prev.totgw;
		word.totwid += prev.totwid;
		word.totswid += prev.totswid;
		word.totscnt += prev.totscnt;
	}
}

# find explicit break positions: dashes, \:, \% and \~
fmt_hyphmarks(word: string, hyidx, hyins, hygap: array of int): int
{
	s := 0;
	c: int;
	d: string;
	ni: int;
	# skip to the first glyph
	for(;;){
		(c, d, ni) = escread(word, s);
		s = ni;
		if(c <= 0)
			break;
	}
	hc := env_hc();
	if(c < 0 || len d == len hc && d == hc)
		return -1;
	n := 0;
	lastchar := 0;
	while(n < NHYPHSWORD){
		(c, d, ni) = escread(word, s);
		if(c < 0)
			break;
		s = ni;
		if(!c){
			if(len d == len hc && d == hc){
				hyins[n] = 1;
				hm_dirty = 1;
				hyidx[n++] = s;
			}
			if(c_hydash(d)){
				hyins[n] = 0;
				hm_dirty = 1;
				hyidx[n++] = s;
			}
			if(len d == len c_nb && d == c_nb){
				hygap[n] = 1;
				hm_dirty = 1;
				hyidx[n++] = s;
			}
			lastchar = s;
		}
	}
	# cannot break the end of a word
	while(n > 0 && hyidx[n - 1] == lastchar)
		n--;
	return n;
}

# fmt_insertword()'s, all zero until fmt_hyphmarks() writes (hm_dirty)
hm_idx := array[NHYPHSWORD + 2] of {* => 0};
hm_ins := array[NHYPHSWORD + 2] of {* => 0};
hm_gap := array[NHYPHSWORD + 2] of {* => 0};
hm_dirty := 0;

fmt_insertword(f: ref Fmt, wb: ref Wb, gap: int)
{
	src := wb_buf(wb);
	hyidx := hm_idx;	# sub-word boundaries
	hyins := hm_ins;	# insert dash
	hygap := hm_gap;	# stretchable no-break space
	hm_dirty = 0;
	n := fmt_hyphmarks(src, hyidx, hyins, hygap);
	if(hm_dirty){	# these are this word's; clean ones for the next
		hm_idx = array[NHYPHSWORD + 2] of {* => 0};
		hm_ins = array[NHYPHSWORD + 2] of {* => 0};
		hm_gap = array[NHYPHSWORD + 2] of {* => 0};
		hm_dirty = 0;
	}
	if(n <= 0){
		fmt_wb2word(f, wb, 0, 1, gap, wb_cost(wb));
		return;
	}
	# update f.fillreq considering the new sub-words
	if(f.fillreq == f.words_n + 1)
		f.fillreq += n;
	wbc := wb_new();
	# add sub-words
	for(i := 0; i <= n; i++){
		ihy := i < n && hyins[i];		# dash width
		istr := i == 0 || hygap[i - 1];		# stretchable
		beg := 0;
		if(i > 0)
			beg = hyidx[i - 1];
		end := len src;
		if(i < n)
			end = hyidx[i];
		if(i < n && hygap[i])			# remove \~
			end -= len c_nb;
		wb_catstr(wbc, src, beg, end);
		(cf, cs, cm, ccd) := wb_fnszget(wbc);
		icost := wb_cost(wb);			# hyphenation cost
		if(i != n)
			icost = hygap[i] * 10000000;
		igap := gap;				# gap width
		if(i != 0)
			igap = hygap[i - 1] * wb_swid(wbc);
		fmt_wb2word(f, wbc, ihy, istr, igap, icost);
		wb_reset(wbc);
		wb_fnszset(wbc, cf, cs, cm, ccd);	# restoring wbc
	}
}

# the space necessary before the next word
fmt_wordgap(f: ref Fmt): int
{
	nls := f.nls || f.nls_sup;
	swid := font_swid(dev_font(nr(R_f)), nr(R_s), nr(R_ss));
	if(f.eos && f.words_n)
		if((nls && !f.gap) || (!nls && f.gap == 2 * swid))
			return swid + font_swid(dev_font(nr(R_f)), nr(R_s), nr(R_sss));
	if(nls && !f.gap && f.words_n)
		return swid;
	return f.gap;
}

# insert wb into f
fmt_word(f: ref Fmt, wb: ref Wb): int
{
	if(wb_empty(wb))
		return 0;
	if(fmt_confchanged(f))
		if(fmt_fillwords(f, 0))
			return 1;
	if(FMT_FILL(f) && f.nls && f.gap)
		if(fmt_flush(f))
			return 1;
	if(!f.words_n)		# apply the new .l and .i
		fmt_confupdate(f);
	f.gap = fmt_wordgap(f);
	f.eos = wb_eos(wb);
	if(f.filled)
		fmt_insertword(f, wb, 0);
	else
		fmt_insertword(f, wb, f.gap);
	f.filled = 0;
	f.nls = 0;
	f.nls_sup = 0;
	f.gap = 0;
	return 0;
}

# insert keshideh characters
fmt_keshideh(f: ref Fmt, end: int, wid: int)
{
	cnt := 0;
	do{
		cnt = 0;
		for(c := 0; c < 2; c++){
			for(i := end - 1 - c; i >= 0; i -= 2){
				w := f.words[i];
				wb := wb_new();
				kw := wb_keshideh(w.s, wb, wid);
				if(kw > 0){
					w.s = wb_buf(wb);
					w.wid = wb_wid(wb);
					wid -= kw;
					cnt++;
				}
			}
		}
	}while(cnt);
	for(i := 0; i < end; i++){
		f.words[i].totwid = f.words[i].wid + f.words[i].gap;
		if(i > 0)
			f.words[i].totwid += f.words[i - 1].totwid;
	}
}

fmt_alloc(): ref Fmt
{
	f := ref Fmt;
	f.words = array[256] of ref Word;
	f.lines = array[256] of ref Line;
	f.parpg = -1;
	f.trpg = -1;
	return f;
}

fmt_wid(f: ref Fmt): int
{
	return fmt_totwid(f, f.words_n) + fmt_wordgap(f);
}

fmt_morewords(f: ref Fmt): int
{
	return fmt_morelines(f) || f.words_n;
}

fmt_morelines(f: ref Fmt): int
{
	return f.lines_head != f.lines_tail;
}

# suppress the last newline
fmt_suppressnl(f: ref Fmt)
{
	if(f.nls){
		f.nls--;
		f.nls_sup = 1;
	}
}

# the lines the text not yet set will take, were the paragraph to end
# here (.pend): those filled and waiting, and the words' as they fill
fmt_pending(f: ref Fmt): int
{
	n := fmt_nlines(f);
	if(!f.words_n)
		return n;
	if(!FMT_FILL(f))
		return n + 1;
	out := array[4096] of {* => 0};
	if(nr(R_j) & AD_Q)
		return n + fmtb_fill(f.words, f.words_n, out, len out, FMT_LLEN(f), 0, 1, -1);
	return n + fmta_fill(f.words, f.words_n, out, len out, FMT_LLEN(f), 0, 1, -1);
}

# estimated number of lines until a trap or the end of the page
fmt_safelines(): int
{
	lnht := max(1, nr(R_L)) * nr(R_v);
	if(nr(R_v) > 0)
		return (f_nexttrap() + lnht - 1) / lnht;
	return 1000;
}

#
# Fill the collected words.
#
# Returns 0 unless the call must be repeated:
#
# + A line break is necessary (br), but a trap was reached.
# + A line break is necessary (br), but fillreq (\p) was given.
# + More lines can be extracted; stopped at a trap.
#
# It fills at least one line if the distance to the next trap is zero.
#
fmt_fillwords(f: ref Fmt, br: int): int
{
	nohy := -1;		# no hyphenation allowed on this line
	out: array of int;	# the number of words in filled lines
	if(fw_out != nil){	# one, unless called within itself
		out = fw_out;
		fw_out = nil;
		for(k := 0; k < len out; k++)
			out[k] = 0;
	}else
		out = array[64] of {* => 0};
	n := fmt_fillwords1(f, br, nohy, out);
	fw_out = out;
	return n;
}

fw_out := array[64] of {* => 0};

fmt_fillwords1(f: ref Fmt, br: int, nohy: int, out: array of int): int
{
	if(!FMT_FILL(f) || !f.words_n)
		return 0;
	if(f.tind)
		f.words[0].lp = 0;
	# the total length, taking shrinkable spaces into account
	llen := fmt_totwid(f, f.words_n) -
		fmt_totswid(f, f.words_n) * nr(R_ssh) / 100;
	fillreq := -1;
	if(f.fillreq > 0 && f.fillreq <= f.words_n)
		fillreq = f.fillreq;
	# not enough words to fill
	if(!br && fillreq <= 0 && llen <= FMT_LLEN(f))
		return 0;
	# lines until a trap or the end of the page
	nreq := fmt_safelines() - fmt_nlines(f);
	nrem := nreq;
	# enough lines are collected already
	if(nreq <= 0 && fmt_safelines() > 0)
		return 1;
	if(fmt_safelines() == 0)
		nrem = nreq = 1;
	# if line settings are changed, output a single line
	if(fmt_confchanged(f))
		nreq = 1;
	if(nrem > 0 && nr(R_hy) & HY_LAST)
		nohy = nrem;
	# execute the filling algorithm
	nw := f.words_n;
	if(fillreq > 0)
		nw = fillreq;
	out_n: int;
	lim := lenmin(len out, nrem);
	if(nr(R_wo) && nrem > 0)	# two lines past the trap, to see widows coming
		lim = lenmin(len out, nrem + 2);
	if(nr(R_j) & AD_Q)
		out_n = fmtb_fill(f.words, nw, out, lim, FMT_LLEN(f), fillreq > 0, br, nohy);
	else
		out_n = fmta_fill(f.words, nw, out, lim, FMT_LLEN(f), fillreq > 0, br, nohy);
	# extract filled lines
	n := min(1, out_n);
	if(nreq > 0)
		n = min(nreq, out_n);
	room := fmt_safelines() - fmt_nlines(f);
	if(fmt_safelines() == 0)
		room = 1;
	(wn, wait, eject) := fmt_widows(f, n, room, out_n, br, fillreq);
	n = wn;
	i: int;
	for(i = 0; i < n; i++){
		cur := out[i];
		if(fmt_extractline(f, cur, cur != f.words_n || !br || cur == fillreq))
			break;
		if(f.words_n)
			f.words[0].gap = 0;
	}
	if(i > 0){
		if(f.parpg != nr(R_PG)){
			f.parpg = nr(R_PG);
			f.parcnt = 0;
		}
		f.parcnt += i;
		f.ejected = 0;
	}
	if(br && !f.words_n)	# the paragraph is done
		f.parpg = -1;
	if(eject){
		f.eject = 1;
		f.ejected = 1;
		f.ejpg = -1;	# set when the page is ended (fmt_ejected)
		return 1;
	}
	if(wait)
		return 0;
	f.filled = i && !f.words_n;
	if(f.words_n)		# apply the new .l and .i
		fmt_confupdate(f);
	return i < min(out_n, lenmin(len out, nrem)) || fillreq > 0 || (br && f.words_n) ||
		(n == nreq && fmt_totwid(f, f.words_n) > FMT_LLEN(f));
}

# the page ended by .wo: where (the trap reached)
fmt_ejected(f: ref Fmt, d: int)
{
	f.ejpg = nr(R_PG);
	f.ejd = d;
}

# widows and orphans (.wo): how many of the n lines planned to set now
# (n is 1 where the next line's settings change); whether to stop and
# wait for more words (the page's last line could leave the paragraph's
# last alone on the next); whether to end the page after them.  room is
# the lines that fit before the trap; out_n the paragraph's filled lines
fmt_widows(f: ref Fmt, n, room, out_n, br, fillreq: int): (int, int, int)
{
	if(!nr(R_wo) || cdiv != nil || fillreq > 0 || room <= 0)
		return (n, 0, 0);
	# the page ended for the paragraph, its foot's macro not yet run:
	# nothing more on this page (at the paragraph's end, go on all the same)
	if(f.ejected && f.ejpg == nr(R_PG) && f.ejd == nr(R_d) && !br)
		return (0, 1, 0);
	# the trap the last fill saw coming passed on this page: its macro is
	# running (and filling lines as it reads its own), nothing more here
	if(f.trpg == nr(R_PG) && nr(R_d) >= f.trd && !br)
		return (0, 1, 0);
	f.trpg = nr(R_PG);
	f.trd = nr(R_d) + f_nexttrap();
	onpg := 0;	# the paragraph's lines on this page already
	if(f.parpg == nr(R_PG))
		onpg = f.parcnt;
	# a paragraph is broken by a page only with two lines on either side
	# of it: of its L lines, b = min(room, L - 2) on this page; fewer than
	# two here, the whole of it goes to the next
	if(br){
		L := out_n;		# all its lines (or room + 2, if more)
		if(L <= room)
			return (n, 0, 0);
		b := min(room, L - 2);
		if(onpg + b < 2 && onpg == 0 && !f.ejected)
			return (0, 0, 1);
		if(b >= room)
			return (n, 0, 0);
		if(n >= b)
			return (b, 0, 1);	# b lines, then the page ends
		return (n, 0, 0);
	}
	# its end not yet read: the known lines (out_n) and the words not yet
	# filled (none, or a line, or more)
	if(out_n + 1 < room)	# they end before the page does
		return (n, 0, 0);
	if(out_n >= room + 2){	# two lines at least go to the next page
		if(onpg + room < 2 && !f.ejected)
			return (0, 0, 1);	# its first line alone at the foot
		return (n, 0, 0);
	}
	# set only what stays on this page however it ends
	safe := min(room, out_n - 2);
	if(safe < 0 || onpg + safe < 2)
		safe = 0;
	if(n < safe)
		return (n, 0, 0);
	return (safe, 1, 0);
}

# C's MIN(LEN(a), n): LEN is unsigned (a size_t), so a negative n, made
# unsigned, is the larger: no lines left before a trap (nrem < 0) fills
# as many as out holds
lenmin(l: int, n: int): int
{
	if(n < 0 || n > l)
		return l;
	return n;
}

# Algorithm A for filling lines

fa_best: array of big;	# fmta_fill()'s
fa_pos, fa_dep: array of int;

# approximately 8 * sqrt(cost)
scaledown(cost: big): big
{
	# only the low 28 bits count, two at a time
	c := int (cost & big 16rfffffff);
	ret := 0;
	for(i := 3; c != 0; i++){
		ret += (c & 3) << i;
		c >>= 2;
	}
	if(ret < 1 << 13)
		return big ret;
	return big (1 << 13);
}

# the cost of putting lwid words in a line of length llen
FMT_COST(llen, lwid, swid, nspc: int): big
{
	# the ratio that the stretchable spaces of the line should be spread
	if(!swid)
		swid = 1;
	if(!nspc)
		nspc = 1;
	d := llen - lwid;
	if(d > -20000000 && d < 20000000){	# in int, as in big
		r := d * 100 / swid;
		if(r < 0)
			r = -r;
		if(r > 4000)
			r = 4000 + int scaledown(big (r - 4000));
		return big (r * r / 100) * big nspc;
	}
	ratio := big d * big 100 / big swid;
	if(ratio < big 0)
		ratio = -ratio;
	# ratio too large; scaling it down
	if(ratio > big 4000)
		ratio = big 4000 + scaledown(ratio - big 4000);
	# assigning a cost of 100 to each space stretching 100 percent
	return ratio * ratio / big 100 * big nspc;
}

# the number of hyphenations in consecutive lines ending at pos
fmt_hydepth(words: array of ref Word, best_pos: array of int, pos: int): int
{
	n := 0;
	while(pos > 0 && words[pos - 1].hy && ++n < 5)
		pos = best_pos[pos];
	return n;
}

# the first word of the last filled line
fmta_last(words: array of ref Word, words_n: int, llen: int, br: int,
		nil: int, best: array of big, nil: array of int, nil: array of int): int
{
	last := -1;
	last_cost := big 0;
	lwid := 0;		# the current line length
	swid := 0;		# the amount of stretchable spaces
	pos := words_n;
	i := pos - 1;
	if(words[i].hy)	# the last word is hyphenated
		lwid += words[i].hy;
	while(i >= 0){
		lwid += words[i].wid;
		if(i + 1 < pos)
			lwid += words[i + 1].gap;
		if(i + 1 < pos && words[i + 1].str)
			swid += words[i + 1].gap;
		pw := lwid - words[i].lp - endrp(words[pos - 1]);
		if(pw > llen + swid * nr(R_ssh) / 100)
			break;
		cost := best[i];
		# the cost of formatting short lines; should prevent widows
		if(br && nr(R_pmll) && pw < llen * nr(R_pmll) / 100){
			pmll := llen * nr(R_pmll) / 100;
			cost += big nr(R_pmllcost) * big (pmll - pw) / big pmll;
		}
		if(last < 0 || cost < last_cost){
			last = i;
			last_cost = cost;
		}
		i--;
	}
	if(last >= 0)
		return last;
	return pos - 1;
}

# the last filled word
fmta_break(best_pos: array of int, pos: int, out: array of int, nreq: int): int
{
	beg := 0;
	if(pos > 0)
		beg = best_pos[pos];
	idx := 0;
	if(beg > 0)
		idx = fmta_break(best_pos, beg, out, nreq);
	if(idx < nreq)
		out[idx] = pos - beg;
	if(pos > 0)
		return idx + 1;
	return 0;
}

#
# Fill the given words; returns the number of filled lines.
#
# + out_n: the most lines to return (the size of out).
# + all: put all words in filled lines.
# + br: the last line is not filled.
# + nohy: the index of the line that must not be hyphenated.
# + out: the number of words in each of the filled lines.
#
fmta_fill(words: array of ref Word, words_n: int, out: array of int, out_n: int,
		llen: int, all: int, br: int, nohy: int): int
{
	ssh0 := nr(R_ssh);
	hlm0 := nr(R_hlm);
	hycost := array[] of {
		nr(R_hycost),
		nr(R_hycost) + nr(R_hycost2),
		nr(R_hycost) + nr(R_hycost2) + nr(R_hycost3),
	};
	# every entry is set before it is read, but best_pos (below)
	if(fa_best == nil || len fa_best < words_n + 1){
		fa_best = array[words_n + 64] of big;
		fa_pos = array[words_n + 64] of int;
		fa_dep = array[words_n + 64] of int;
	}
	best := fa_best;
	best_pos := fa_pos;
	best_dep := fa_dep;
	fa_best = nil;	# taken, should this be called within itself

	last := words_n;	# the beginning of the last line
	best_pos[0] = 0;
	best_dep[0] = 0;
	best[0] = big 0;
	for(i := 1; i < words_n + 1; i++)
		best_pos[i] = -1;
	mtek := nr(R_mtek);
	mte := mtek || nr(R_mtes);
	for(pos := 1; pos <= words_n; pos++){
		swid := 0;		# the amount of stretchable spaces
		nspc := 0;		# the number of stretchable spaces
		dwid := 0;		# equal to swid, unless swid is zero
		erp := endrp(words[pos - 1]);
		wcost := big words[pos - 1].cost;
		hyphenated := words[pos - 1].hy != 0;
		lwid := words[pos - 1].hy;	# non-zero if the last word is hyphenated
		gsum := words[pos - 1].hy;	# the glyphs' advances (.mte)
		i = pos - 1;
		while(i >= 0){
			lwid += words[i].wid;
			gsum += words[i].gw;
			if(i + 1 < pos)
				lwid += words[i + 1].gap;
			if(i + 1 < pos && words[i + 1].str){
				swid += words[i + 1].gap;
				nspc++;
			}
			pw := lwid - words[i].lp - erp;
			xk := 0;
			if(mtek)
				xk = int (big gsum * big mtek / big 1000);
			if(pw > llen + swid * ssh0 / 100 + xk && i + 1 < pos)
				break;
			dwid = swid;
			if(!dwid && i > 0)	# no stretchable spaces
				dwid = words[i - 1].swid;
			if(mte)
				dwid += fmt_excap(gsum, pw > llen);
			# FMT_COST(llen, pw, dwid, nspc), here where it is hot
			cost: big;
			d := llen - pw;
			if(d > -20000000 && d < 20000000){
				cw := dwid;
				if(!cw)
					cw = 1;
				r := d * 100 / cw;
				if(r < 0)
					r = -r;
				if(r > 4000)
					r = 4000 + int scaledown(big (r - 4000));
				cost = big (r * r / 100);
				if(nspc > 1)
					cost *= big nspc;
			}else
				cost = FMT_COST(llen, pw, dwid, nspc);
			cur := best[i] + cost;
			if(hyphenated && best_dep[i] + 1 == nohy)
				cur += big 10000000;
			if(hyphenated){
				dep := fmt_hydepth(words, best_pos, i);
				if(hlm0 <= 0 || dep < hlm0)
					cur += big hycost[lenmin(len hycost - 1, dep)];
				else
					cur += big 10000000;
			}
			cur += wcost;
			if(best_pos[pos] < 0 || cur < best[pos]){
				best_pos[pos] = i;
				best_dep[pos] = best_dep[i] + 1;
				best[pos] = cur;
			}
			i--;
		}
	}
	if(!all)
		last = fmta_last(words, words_n, llen, br, nohy, best, best_pos, best_dep);
	cnt := fmta_break(best_pos, last, out, out_n);
	if(!all && cnt < out_n && br && last < words_n)
		out[cnt++] = words_n - last;
	(fa_best, fa_pos, fa_dep) = (best, best_pos, best_dep);
	return min(out_n, cnt);
}

# Algorithm B for filling lines

fmtb_cost(words: array of ref Word, nil: int, llen: int, br: int, nohy: int, end: array of int, cnt: int): big
{
	hycost := array[] of {
		nr(R_hycost),
		nr(R_hycost) + nr(R_hycost2),
		nr(R_hycost) + nr(R_hycost2) + nr(R_hycost3),
	};
	cost := big 0;
	pos := 0;
	hydep := 0;
	for(i := 0; i < cnt; i++){
		w := words[end[i] - 1];
		lwid := words[end[i] - 1].totwid - words[pos].totwid + words[pos].wid;
		lwid -= words[pos].lp + endrp(words[end[i] - 1]);
		gsum := words[end[i] - 1].totgw - words[pos].totgw + words[pos].gw + words[end[i] - 1].hy;
		swid := words[end[i] - 1].totswid - words[pos].totswid;
		scnt := words[end[i] - 1].totscnt - words[pos].totscnt;
		cur := big 0;
		if(br && i == cnt - 1){
			pmll := llen * nr(R_pmll) / 100;
			if(nr(R_pmll) && lwid < llen * nr(R_pmll) / 100)
				cur += big nr(R_pmllcost) * big (pmll - lwid) / big pmll;
		}else{
			if(!swid)
				swid = 1;
			cur += FMT_COST(llen, lwid, swid + fmt_excap(gsum, lwid > llen), scnt);
			cur += big w.cost;
			if(w.hy)
				hydep++;
			else
				hydep = 0;
			if(w.hy && i + 1 == nohy)
				cur += big 10000000;
			if(w.hy){
				if(nr(R_hlm) <= 0 || hydep < nr(R_hlm))
					cur += big hycost[lenmin(len hycost - 1, hydep)];
				else
					cur += big 10000000;
			}
		}
		cost += cur;
		pos = end[i];
	}
	return cost;
}

fmtb_fill(words: array of ref Word, words_n: int, out: array of int, out_n: int,
		llen: int, all: int, br: int, nohy: int): int
{
	end := array[128] of {* => 0};	# line end index
	cnt := 0;		# the number of lines
	pos := 0;		# the current word
	i, j: int;
	# filling lines
	while(pos < words_n && cnt < len end){
		best := pos + 1;
		for(i = pos + 1; i <= words_n; i++){
			lwid := words[i - 1].totwid - words[pos].totwid + words[pos].wid;
			swid := words[i - 1].totswid - words[pos].totswid;
			lwid += words[i - 1].hy;
			lwid -= words[pos].lp + endrp(words[i - 1]);
			gsum := words[i - 1].totgw - words[pos].totgw + words[pos].gw + words[i - 1].hy;
			if(lwid > llen + swid * nr(R_ssh) / 100 + int (big gsum * big nr(R_mtek) / big 1000))
				break;
			best = i;
		}
		if(i > words_n && !br && !all)
			break;
		end[cnt++] = best;
		pos = best;
	}
	# reducing the cost
	while(cnt > 0){
		cost := fmtb_cost(words, words_n, llen, br, nohy, end, cnt);
		for(i = 0; i < cnt; i++){
			wcnt := end[i];
			if(i)
				wcnt = end[i] - end[i - 1];
			best_cost := cost;
			best := -1;
			for(j = 1; j < wcnt; j++){
				end[i] -= j;
				cost2 := fmtb_cost(words, words_n, llen, br, nohy, end, cnt);
				if(cost2 < best_cost){
					best = j;
					best_cost = cost2;
				}
				end[i] += j;
				# stop at a non-hyphenated word
				if(!words[end[i] - j - 1].hy)
					break;
			}
			if(best >= 0){
				end[i] -= best;
				break;
			}
		}
		if(i == cnt)
			break;
	}
	out_n = min(cnt, out_n);
	for(i = 0; i < out_n; i++){
		out[i] = end[i];
		if(i > 0)
			out[i] = end[i] - end[i - 1];
	}
	return out_n;
}
