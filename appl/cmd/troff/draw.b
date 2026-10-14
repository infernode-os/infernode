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

ren_hline(wb: ref Wb, l: int, c: string)
{
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
