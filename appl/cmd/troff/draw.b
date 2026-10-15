#
# draw.c: lines, drawing commands, \b, \o and \Z
#

cwid(c: string): int
{
	wb := wb_new();
	wb_putexpand(wb, c);
	return wb_wid(wb);
}

hchar(c: string): int
{
	if(at(c, 0) == c_ec)
		return at(c, 1) == '_' || at(c, 1) == '-';
	if(len c == 1)
		return c[0] == '_';
	return c == "ru" || c == "ul" || c == "rn" ||
		(len c > 2 && (c[0:2] == "ru" || c[0:2] == "ul" || c[0:2] == "rn"));
}

vchar(c: string): int
{
	if(len c == 1)
		return c[0] == '|';
	return len c >= 2 && (c[0:2] == "bv" || c[0:2] == "br");
}

# .rules: \l's and \L's of rule characters drawn as lines, as long as
# they are, not as a font's glyphs set side by side (not Neatroff's).
# A rule is drawn where the glyphs' ink would be: a rectangle from the
# bottom of the glyph's box to its top (\(ul, \(ru and \(rn: eqn's
# fractions, bars and radicals, tbl's rules, placed by those boxes), or
# from its left to its right (\(br, \(bv, |); through the character's
# .char where it has one (eqnrc's).  A glyph with no box is drawn as a
# line, at the baseline or the left of the glyph.
n_rules := 0;

hrule(c: string): int
{
	return n_rules && (c == "ul" || c == "_" || c == "ru" || c == "rn");
}

vrule(c: string): int
{
	return n_rules && (c == "br" || c == "bv" || c == "|");
}

# the box of the character as set: its left, bottom, right and top;
# empty, the left the right.  A rule needs no glyph: one missing is not
# said (.mg)
rulebox(c: string): (int, int, int, int)
{
	mg := mg_warn;
	mg_warn = 0;
	bw := wb_new();
	wb_putexpand(bw, c);
	wb_flush(bw);
	mg_warn = mg;
	if(bw.urx <= bw.llx || bw.ury <= bw.lly)
		return (0, 0, 0, 0);
	return (bw.llx, bw.lly, bw.urx, bw.ury);
}

# a filled rectangle w by h, its top left corner dx and dy from here
rulerect(wb: ref Wb, dx, dy, w, h: int)
{
	wb_hmov(wb, dx);
	wb_vmov(wb, dy);
	wb_drawxbeg(wb, 'P');
	wb_drawxdot(wb, w, 0);
	wb_drawxdot(wb, 0, h);
	wb_drawxdot(wb, -w, 0);
	wb_drawxend(wb);
	wb_vmov(wb, -dy - h);
	wb_hmov(wb, -dx);
}

ren_hline(wb: ref Wb, l: int, c: string)
{
	if(hrule(c)){
		if(l < 0){
			wb_hmov(wb, l);
			l = -l;
		}
		(nil, bot, nil, top) := rulebox(c);
		if(top > bot){
			rulerect(wb, 0, -top, l, top - bot);
			wb_hmov(wb, l);
		}else
			wb_drawl(wb, 'l', l, 0);
		return;
	}
	w := cwid(c);
	# negative length; moving backwards
	if(l < 0){
		wb_hmov(wb, l);
		l = -l;
	}
	n := 0;
	rem := l;
	if(w){
		n = l / w;
		rem = l % w;
	}
	# length less than character width
	if(l < w){
		n = 1;
		rem = 0;
		wb_hmov(wb, -(w - l) / 2);
	}
	# the initial gap
	if(rem){
		if(hchar(c)){
			wb_putexpand(wb, c);
			wb_hmov(wb, rem - w);
		}else
			wb_hmov(wb, rem);
	}
	for(i := 0; i < n; i++)
		wb_putexpand(wb, c);
	# moving back
	if(l < w)
		wb_hmov(wb, -(w - l + 1) / 2);
}

ren_vline(wb: ref Wb, l: int, c: string)
{
	if(vrule(c)){
		mg := mg_warn;
		mg_warn = 0;
		hw := cwid(c);
		mg_warn = mg;
		(left, nil, right, nil) := rulebox(c);
		if(right > left){
			if(l < 0)
				rulerect(wb, left, l, right - left, -l);
			else
				rulerect(wb, left, 0, right - left, l);
			wb_vmov(wb, l);
		}else
			wb_drawl(wb, 'l', 0, l);
		wb_hmov(wb, hw);
		return;
	}
	neg := l < 0;
	w := SC_EM();	# character height
	hw := cwid(c);	# character width
	# negative length; moving backwards
	if(l < 0){
		wb_vmov(wb, l);
		l = -l;
	}
	n := 0;
	rem := l;
	if(w){
		n = l / w;
		rem = l % w;
	}
	# length less than character width
	if(l < w){
		n = 1;
		rem = 0;
		wb_vmov(wb, -w + l / 2);
	}
	# the initial gap
	if(rem){
		if(vchar(c)){
			wb_vmov(wb, w);
			wb_putexpand(wb, c);
			wb_hmov(wb, -hw);
			wb_vmov(wb, rem - w);
		}else
			wb_vmov(wb, rem);
	}
	for(i := 0; i < n; i++){
		wb_vmov(wb, w);
		wb_putexpand(wb, c);
		wb_hmov(wb, -hw);
	}
	# moving back
	if(l < w)
		wb_vmov(wb, l / 2);
	if(neg)
		wb_vmov(wb, -l);
	wb_hmov(wb, hw);
}

ren_hlcmd(wb: ref Wb, a: string)
{
	(l, i) := eval_up(a, 0, 'm');
	if(at(a, i) == c_ec && at(a, i + 1) == '&')	# \& can be used as a separator
		i += 2;
	lc := "ru";
	if(i < len a){
		(t, c, nil) := charread(a, i);
		if(t >= 0)
			lc = c;
	}
	if(l)
		ren_hline(wb, l, lc);
}

ren_vlcmd(wb: ref Wb, a: string)
{
	(l, i) := eval_up(a, 0, 'v');
	if(at(a, i) == c_ec && at(a, i + 1) == '&')	# \& can be used as a separator
		i += 2;
	lc := "br";
	if(i < len a){
		(t, c, nil) := charread(a, i);
		if(t >= 0)
			lc = c;
	}
	if(l)
		ren_vline(wb, l, lc);
}

tok_num(s: string, i: int, scale: int): (int, int)
{
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	return eval_up(s, i, scale);
}

# a number and where it stopped; and whether there was none
tok_numpt(s: string, i: int, scale: int): (int, int, int)
{
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	o := i;
	n: int;
	(n, i) = eval_up(s, i, scale);
	return (n, i, o == i);
}

ren_dcmd(wb: ref Wb, s: string)
{
	h1, h2, v1, v2: int;
	if(s == nil)
		return;
	c := s[0];
	i := 1;
	case tolower(c) {
	'l' =>
		(h1, i) = tok_num(s, i, 'm');
		(v1, i) = tok_num(s, i, 'v');
		wb_drawl(wb, c, h1, v1);
	'c' =>
		(h1, i) = tok_num(s, i, 'm');
		wb_drawc(wb, c, h1);
	'e' =>
		(h1, i) = tok_num(s, i, 'm');
		(v1, i) = tok_num(s, i, 'v');
		wb_drawe(wb, c, h1, v1);
	'a' =>
		(h1, i) = tok_num(s, i, 'm');
		(v1, i) = tok_num(s, i, 'v');
		(h2, i) = tok_num(s, i, 'm');
		(v2, i) = tok_num(s, i, 'v');
		wb_drawa(wb, c, h1, v1, h2, v2);
	'~' or 'p' =>
		wb_drawxbeg(wb, c);
		while(i < len s){
			none: int;
			(h1, i, none) = tok_numpt(s, i, 'm');
			if(!none)
				(v1, i, none) = tok_numpt(s, i, 'v');
			if(none){
				tok := "";
				while(len tok < 63 && i < len s && s[i] != ' ')
					tok[len tok] = s[i++];
				wb_drawxcmd(wb, tok);
			}else
				wb_drawxdot(wb, h1, v1);
		}
		wb_drawxend(wb);
	}
}

ren_bcmd(wb: ref Wb, a: string)
{
	n := 0;
	w := 0;
	sstr_push(a, 0);	# using ren_char()'s interface
	wb2 := wb_new();
	c := sstr_next();
	while(c >= 0){
		sstr_back(c);
		ren_char(wb2, S_SSTR);
		if(wb_wid(wb2) > w)
			w = wb_wid(wb2);
		wb_hmov(wb2, -wb_wid(wb2));
		wb_vmov(wb2, SC_EM());
		n++;
		c = sstr_next();
	}
	sstr_pop();
	center := -(n * SC_EM() + SC_EM()) / 2;
	wb_vmov(wb, center + SC_EM());
	wb_cat(wb, wb2);
	wb_vmov(wb, center);
	wb_hmov(wb, w);
}

ren_ocmd(wb: ref Wb, a: string)
{
	w := 0;
	sstr_push(a, 0);	# using ren_char()'s interface
	wb2 := wb_new();
	wb3 := wb_new();
	c := sstr_next();
	while(c >= 0){
		sstr_back(c);
		ren_char(wb3, S_SSTR);
		wc := wb_wid(wb3);
		if(wc > w)
			w = wc;
		wb_hmov(wb2, -wc / 2);
		wb_cat(wb2, wb3);
		wb_hmov(wb2, -wc / 2);
		c = sstr_next();
	}
	sstr_pop();
	wb_hmov(wb, w / 2);
	wb_cat(wb, wb2);
	wb_hmov(wb, w / 2);
}

ren_zcmd(wb: ref Wb, a: string)
{
	h := wb_hpos(wb);
	v := wb_vpos(wb);
	sstr_push(a, 0);
	while((c := sstr_next()) >= 0){
		sstr_back(c);
		ren_char(wb, S_SSTR);
	}
	sstr_pop();
	wb_hmov(wb, h - wb_hpos(wb));
	wb_vmov(wb, v - wb_vpos(wb));
}
