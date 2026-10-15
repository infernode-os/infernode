#
# out.c: writing troff's device-independent output
#

out_nl := 1;

# output troff code; newlines may appear only at the end of s
out_out(s: string)
{
	out_nl = strchr(s, '\n') >= 0;
	bout.puts(s);
}

# output troff code; no preceding newline is necessary
outnn(s: string)
{
	out_out(s);
}

# output a troff command; it should appear after a newline
out(s: string)
{
	if(!out_nl)
		outnn("\n");
	out_out(s);
}

o_s := 10;
o_f := 1;
o_m := 0;

out_ps(n: int)
{
	if(o_s != n){
		o_s = n;
		out(sys->sprint("s%d\n", o_s));
	}
}

out_ft(n: int)
{
	if(n >= 0 && o_f != n){
		o_f = n;
		out(sys->sprint("f%d\n", o_f));
	}
}

out_clr(n: int)
{
	if(n >= 0 && o_m != n){
		o_m = n;
		out("m" + clr_str(o_m) + "\n");
	}
}

out_draw(s: string)
{
	c := s[0];
	i := 1;
	n: int;
	out("D" + chr(c));
	case tolower(c) {
	'l' =>
		(n, i) = tok_num(s, i, 'm');
		outnn(sys->sprint(" %d", n));
		(n, i) = tok_num(s, i, 'v');
		outnn(sys->sprint(" %d", n));
		outnn(" .");			# dpost requires this
	'c' =>
		(n, i) = tok_num(s, i, 'm');
		outnn(sys->sprint(" %d", n));
	'e' =>
		(n, i) = tok_num(s, i, 'm');
		outnn(sys->sprint(" %d", n));
		(n, i) = tok_num(s, i, 'v');
		outnn(sys->sprint(" %d", n));
	'a' =>
		(n, i) = tok_num(s, i, 'm');
		outnn(sys->sprint(" %d", n));
		(n, i) = tok_num(s, i, 'v');
		outnn(sys->sprint(" %d", n));
		(n, i) = tok_num(s, i, 'm');
		outnn(sys->sprint(" %d", n));
		(n, i) = tok_num(s, i, 'v');
		outnn(sys->sprint(" %d", n));
	'~' or 'p' =>
		while(i < len s){
			h, v, none: int;
			(h, i, none) = tok_numpt(s, i, 'm');
			if(!none)
				(v, i, none) = tok_numpt(s, i, 'v');
			if(none){
				outnn(" ");
				while(i < len s && s[i] != ' ')
					outnn(chr(s[i++]));
			}else{
				outnn(sys->sprint(" %d", h));
				outnn(sys->sprint(" %d", v));
			}
		}
	}
	outnn("\n");
}

outg(c: string, fnt: int, sz: int)
{
	ofn := o_f;
	osz := o_s;
	out_ft(fnt);
	out_ps(sz);
	if(len c == 1){
		# a newline after it unless it is a single byte in UTF-8
		if(c[0] < 16r80)
			outnn("c" + c);
		else{
			outnn("c" + c + "\n");
			out_nl = 0;	# Neatroff looks for the newline in "c%s%s"; there is none
		}
	}else if(at(c, 0) == ecc() && at(c, 1) == '(')
		out("C" + c[2:] + "\n");
	else
		out("C" + c + "\n");
	out_ft(ofn);
	out_ps(osz);
}

# font expansion (.mte): a line's glyphs' advances scaled by
# (1000 + out_ex) / 1000, the remainder carried so that the line's
# total is what fmt counted; tr2pdf scales their shapes (x X mtx)
out_ex := 0;
out_exacc := 0;

out_exset(e: int)
{
	if(e == out_ex)
		return;
	out_ex = e;
	out_exacc = 0;
	out("x X mtx " + string e + "\n");
}

outc(c: string)
{
	g := dev_glyph(c, o_f);
	fnt := dev_font(o_f);
	if(g == nil)
		return;
	gf := gfont(g);
	cwid := font_gwid(gf, fnt, o_s, g.wid);
	if(font_mapped(gf, c))
		c = g.name;
	if(!font_getcs(fnt) && !font_getbd(fnt) && !out_ex && len c == 1 && c[0] < 16r80 &&
			font_zoom(gf, o_s) == o_s && ((fp := dev_fontpos(gf)) < 0 || fp == o_f)){
		# what follows, in one: no change of font or size, and no newline after
		if(out_cs[c[0]] == nil)
			out_cs[c[0]] = "c" + c;
		bout.puts(out_cs[c[0]] + hnum(cwid));
		out_nl = 0;
		return;
	}
	bwid := font_wid(gf, o_s, g.wid);
	if(font_getcs(fnt))
		outnn(sys->sprint("h%d", (cwid - bwid) / 2));
	outg(c, dev_fontpos(gfont(g)), font_zoom(gfont(g), o_s));
	if(font_getbd(fnt)){
		outnn(sys->sprint("h%d", font_getbd(fnt) - 1));
		outg(c, dev_fontpos(gfont(g)), font_zoom(gfont(g), o_s));
		outnn(sys->sprint("h%d", -font_getbd(fnt) + 1));
	}
	if(font_getcs(fnt))
		outnn(sys->sprint("h%d", -(cwid - bwid) / 2));
	if(out_ex){
		t := cwid * (1000 + out_ex) + out_exacc;
		out_exacc = t % 1000;
		cwid = t / 1000;
	}
	outnn(hnum(cwid));
}

out_cs := array[16r80] of string;	# "c" and a character
out_hs := array[8192] of string;	# "h" and a number

hnum(n: int): string
{
	if(n < 0 || n >= len out_hs)
		return "h" + string n;
	if(out_hs[n] == nil)
		out_hs[n] = "h" + string n;
	return out_hs[n];
}

out_x(s: string)
{
	if(len s > 4 && s[0:4] == "mtx "){
		out_exset(int s[4:]);
		return;
	}
	# \X'nr name value': the register set as the line goes out, nothing
	# written (not Neatroff's): what is set on a page, known there
	if(len s > 3 && s[0:3] == "nr "){
		(nil, w) := sys->tokenize(s[3:], " ");
		if(w != nil && tl w != nil)
			nrset(map(hd w), int hd tl w);
		return;
	}
	out("x X " + s + "\n");
}

out_line(s: string)
{
	i := 0;
	for(;;){
		(t, c, ni) := escread(s, i);
		if(t < 0)
			break;
		i = ni;
		if(!t){
			if(at(c, 0) == c_ni || (at(c, 0) == '\\' && at(c, 1) == '\\')){
				if(len c >= 2)
					c = c[1:2];
				else
					c = "";
			}
			if(at(c, 0) == '\t' || at(c, 0) == 1 || c_hymark(c))
				continue;
			outc(cmap_map(c));
			continue;
		}
		case t {
		'D' =>
			out_draw(c);
		'f' =>
			out_ft(dev_pos(c));
		'h' =>
			outnn(hnum(eval(c, 'm')));
		'm' =>
			if(!nr(R_cp))
				out_clr(clr_get(c));
		's' =>
			out_ps(eval(c, 0));
		'v' =>
			outnn(sys->sprint("v%d", eval(c, 'v')));
		'X' =>
			out_x(c);
		}
	}
}
