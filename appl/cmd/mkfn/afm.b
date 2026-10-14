#
# afm.c: AFM fonts
#

# a field of a character metrics line at s[i:]; and where the next begins
afm_charfield(s: string, i: int): (string, int)
{
	b := i;
	while(i < len s && !isspace(s[i]) && s[i] != ';')
		i++;
	f := s[b:i];
	while(i < len s && (isspace(s[i]) || s[i] == ';'))
		i++;
	return (f, i);
}

afm_uwid(w: int): int
{
	dv := 72000 / res;
	if(w < 0)
		return (w - dv / 20) * 10 / dv;
	return (w + dv / 20) * 10 / dv;
}

# the whitespace-separated words of s
words(s: string): list of string
{
	r: list of string;
	i := 0;
	for(;;){
		while(i < len s && isspace(s[i]))
			i++;
		if(i >= len s)
			break;
		b := i;
		while(i < len s && !isspace(s[i]))
			i++;
		r = s[b:i] :: r;
	}
	l: list of string;
	for(; r != nil; r = tl r)
		l = hd r :: l;
	return l;
}

afm_read(f: ref Iobuf): int
{
	ch := "";
	p := "";
	c1 := "";
	c2 := "";
	wid := "";
	llx := "0";
	lly := "0";
	urx := "0";
	ury := "0";
	fontname := "";
	ln: string;
	while((ln = f.gets('\n')) != nil){
		if(ln[0] == '#')
			continue;
		if(len ln >= 8 && ln[0:8] == "FontName"){
			w := words(ln);
			if(hd w == "FontName" && tl w != nil)
				fontname = hd tl w;
			continue;
		}
		if(len ln >= 16 && ln[0:16] == "StartCharMetrics")
			break;
	}
	while((ln = f.gets('\n')) != nil){
		if(ln[0] == '#')
			continue;
		if(len ln >= 14 && ln[0:14] == "EndCharMetrics")
			break;
		i := 0;
		while(i < len ln){
			field: string;
			(field, i) = afm_charfield(ln, i);
			case field {
			"C" =>
				(p, i) = afm_charfield(ln, i);
				continue;
			"WX" =>
				(wid, i) = afm_charfield(ln, i);
				continue;
			"N" =>
				(ch, i) = afm_charfield(ln, i);
				continue;
			"B" =>
				(llx, i) = afm_charfield(ln, i);
				(lly, i) = afm_charfield(ln, i);
				(urx, i) = afm_charfield(ln, i);
				(ury, i) = afm_charfield(ln, i);
				continue;
			"L" =>
				(c1, i) = afm_charfield(ln, i);
				(c2, i) = afm_charfield(ln, i);
				continue;
			}
			break;
		}
		if(ch != "" && p != "" && wid != "")
			mkfn_char(ch, atoi(p), 0, afm_uwid(atoi(wid)),
				afm_uwid(atoi(llx)), afm_uwid(atoi(lly)),
				afm_uwid(atoi(urx)), afm_uwid(atoi(ury)));
	}
	mkfn_header(fontname);
	while((ln = f.gets('\n')) != nil){
		if(ln[0] == '#')
			continue;
		if(len ln >= 14 && ln[0:14] == "StartKernPairs")
			break;
	}
	while((ln = f.gets('\n')) != nil){
		if(ln[0] == '#')
			continue;
		if(len ln >= 12 && ln[0:12] == "EndKernPairs")
			break;
		if(len ln >= 3 && ln[0:3] == "KPX"){
			w := words(ln[3:]);
			if(len w >= 3)
				mkfn_kern(hd w, hd tl w, afm_uwid(atoi(hd tl tl w)));
		}
	}
	return 0;
}
