#
# ren.c: rendering characters into lines and pages
#

NOPAGE:	con 16r40000000;	# undefined bp_next

# diversions
Div: adt {
	sbuf:	string;		# diversion output
	reg:	int;		# diversion register
	tpos:	int;		# diversion trap position
	treg:	int;		# diversion trap register
	dl:	int;		# diversion width
	prev_d:	int;		# the previous \n(.d
	prev_h:	int;		# the previous \n(.h
	prev_mk:	int;	# the previous .mk internal register
	prev_ns:	int;	# the previous .ns
};

divs := array[NPREV] of ref Div;	# the diversion stack
ndivs := 0;
cdiv: ref Div;			# the current diversion
ren_div := 0;			# rendering a diversion
ren_divvs := 0;			# the amount of .v in diversions
trap_em := -1;			# the end macro

ren_nl := 0;			# just after a newline
ren_partial := 0;		# reading an input line in render_rec()
ren_unbuf := array[64] of {* => 0};	# ren_back() buffer
ren_un := 0;
ren_aborted := 0;		# .ab executed

bp_first := 1;			# before the first page
bp_next := NOPAGE;		# the next page number
bp_ejected := 0;		# the current ejected page
bp_final := 0;			# 1: executing em, 2: the final page, 3: the 2nd final page
ren_level := 0;			# the depth of render_rec() calls

c_fa := "";			# field delimiter
c_fb := "";			# field padding

cfmt(): ref Fmt
{
	return env_fmt();
}

cwb(): ref Wb
{
	return env_wb();
}

# the argument i of a request, or nil
arg(args: array of string, i: int): string
{
	if(i < len args)
		return args[i];
	return nil;
}

ren_next(): int
{
	if(ren_un > 0)
		return ren_unbuf[--ren_un];
	return tr_next();
}

ren_back(c: int)
{
	ren_unbuf[ren_un++] = c;
}

tr_di(args: array of string)
{
	if(len args > 1){
		if(ndivs >= NPREV)
			errdie("troff: diversions nested too deeply\n");
		divs[ndivs++] = cdiv = ref Div;
		cdiv.sbuf = "";
		cdiv.reg = map(args[1]);
		cdiv.treg = -1;
		if(at(args[0], 2) == 'a' && str_has(cdiv.reg))	# .da
			cdiv.sbuf += str_get(cdiv.reg);
		cdiv.sbuf += chr(c_cc) + TR_DIVBEG + "\n";
		cdiv.prev_d = nr(R_d);
		cdiv.prev_h = nr(R_h);
		cdiv.prev_mk = nr(R_mk);
		cdiv.prev_ns = nr(R_ns);
		nrset(R_d, 0);
		nrset(R_h, 0);
		nrset(R_mk, 0);
		nrset(R_ns, 0);
	}else if(cdiv != nil){
		cdiv.sbuf += chr(c_cc) + TR_DIVEND + "\n";
		str_set(cdiv.reg, cdiv.sbuf);
		nrset(R_dl, cdiv.dl);
		nrset(R_dn, nr(R_d));
		nrset(R_d, cdiv.prev_d);
		nrset(R_h, cdiv.prev_h);
		nrset(R_mk, cdiv.prev_mk);
		nrset(R_ns, cdiv.prev_ns);
		divs[--ndivs] = nil;
		if(ndivs > 0)
			cdiv = divs[ndivs - 1];
		else
			cdiv = nil;
	}
}

f_divreg(): int
{
	if(cdiv != nil)
		return cdiv.reg;
	return -1;
}

f_hpos(): int
{
	return fmt_wid(cfmt()) + wb_wid(cwb());
}

tr_divbeg(nil: array of string)
{
	odiv_beg();
	ren_div++;
}

tr_divend(nil: array of string)
{
	if(ren_div <= 0)
		errdie("troff: diversion stack empty\n");
	odiv_end();
	ren_div--;
}

tr_divvs(args: array of string)
{
	ren_divvs = eval(arg(args, 1), 'u');
}

tr_transparent(args: array of string)
{
	if(cdiv != nil)
		cdiv.sbuf += arg(args, 1) + "\n";
	else
		out(arg(args, 1) + "\n");
}

ren_page(force: int)
{
	if(!force && bp_final >= 2)
		return;
	nrset(R_nl, 0);
	nrset(R_d, 0);
	nrset(R_h, 0);
	if(bp_next != NOPAGE)
		nrset(R_pg, bp_next);
	else
		nrset(R_pg, nr(R_pg) + 1);
	bp_next = NOPAGE;
	nrset(R_PG, nr(R_PG) + 1);
	out(sys->sprint("p%d\n", nr(R_PG)));
	out("V0\n");
	if(trap_pos(-1) == 0)
		trap_exec(trap_reg(-1));
}

ren_first(): int
{
	if(bp_first && cdiv == nil){
		bp_first = 0;
		ren_page(1);
		return 0;
	}
	return 1;
}

# when nodiv, do not append .sp to diversions
ren_sp(n: int, nodiv: int)
{
	linevs := !n;	# the vertical spacing before a line
	ren_first();
	if(!n && ren_div && ren_divvs && !nr(R_u))
		n = ren_divvs;	# .v at the time of diversion
	ren_divvs = 0;
	nrset(R_ns, 0);
	if(n)
		nrset(R_d, nr(R_d) + n);
	else
		nrset(R_d, nr(R_d) + nr(R_v));
	if(nr(R_d) > nr(R_h))
		nrset(R_h, nr(R_d));
	if(cdiv != nil && !nodiv){
		if(linevs)
			cdiv.sbuf += sys->sprint("%c%s %du\n", c_cc, TR_DIVVS, nr(R_v));
		else if(n)
			cdiv.sbuf += sys->sprint("%csp %du\n", c_cc, n);
		else
			cdiv.sbuf += sys->sprint("%csp %du\n", c_cc, nr(R_v));
	}
	if(cdiv == nil)
		nrset(R_nl, nr(R_d));
}

trap_exec(reg: int)
{
	partial := ren_partial && (!ren_un || ren_unbuf[0] != '\n');
	if(reg >= 0 && str_has(reg)){
		cmd := sys->sprint("%c%s %d\n", c_cc, TR_POPREN, ren_level);
		in_push(cmd, nil);
		in_push(str_get(reg), nil);
		if(partial)
			in_push("\n", nil);
		render_rec(++ren_level);
		# executed the trap while in the middle of an input line
		if(partial)
			fmt_suppressnl(cfmt());
	}
}

detect_traps(beg, end: int): int
{
	pos := trap_pos(beg);
	return pos >= 0 && (cdiv != nil || pos < nr(R_p)) && pos <= end;
}

# whether a trap was executed
ren_traps(beg, end: int, dosp: int): int
{
	pos := trap_pos(beg);
	if(detect_traps(beg, end)){
		if(dosp && pos > beg)
			ren_sp(pos - beg, 0);
		trap_exec(trap_reg(beg));
		return 1;
	}
	return 0;
}

detect_pagelimit(ne: int): int
{
	return cdiv == nil && nr(R_nl) + ne >= nr(R_p);
}

# start a new page if needed
ren_pagelimit(ne: int): int
{
	if(detect_pagelimit(ne)){
		ren_page(0);
		return 1;
	}
	return 0;
}

# whether a trap was triggered
down(n: int): int
{
	e := n;
	if(!e)
		e = nr(R_v);
	if(ren_traps(nr(R_d), nr(R_d) + e, 1))
		return 1;
	ren_sp(max(n, -nr(R_d)), 0);
	return ren_pagelimit(0);
}

# line adjustment
ren_ljust(w, ad, li, lI, ll: int): (string, int)
{
	ljust := li;
	llen := ll - lI - li;
	spre := "";
	nrset(R_n, w);
	if((ad & AD_X) == AD_C && llen > w)
		ljust += (llen - w) / 2;
	if((ad & AD_X) == AD_R)
		ljust += llen - w;
	if(ljust)
		spre = sys->sprint("%sh'%du'", ecs(), ljust);
	if(cdiv != nil && cdiv.dl < w + ljust)
		cdiv.dl = w + ljust;
	return (spre, ljust);
}

# append the line to the current diversion or send it to out.b
ren_out(beg, mid, end: string)
{
	if(cdiv != nil){
		cdiv.sbuf += beg;
		cdiv.sbuf += mid;
		cdiv.sbuf += end;
		cdiv.sbuf += "\n";
	}else{
		out(sys->sprint("H%d\n", nr(R_o)));
		out(sys->sprint("V%d\n", nr(R_d)));
		out_line(beg);
		out_line(mid);
		out_line(end);
		out_exset(0);	# a line's expansion is its own
	}
}

zwid(): int
{
	g := dev_glyph("0", nr(R_f));
	if(g != nil)
		return font_gwid(gfont(g), dev_font(nr(R_f)), nr(R_s), g.wid);
	return 0;
}

# the line number before an output line
ren_lnum(): string
{
	num := "";
	wb := wb_new();
	if(nr(R_nn) <= 0 && (nr(R_ln) % nr(R_nM)) == 0)
		num = sys->sprint("%d", nr(R_ln));
	wb_hmov(wb, nr(R_nI) * zwid());
	if(len num < 3)
		wb_hmov(wb, (3 - len num) * zwid());
	for(i := 0; i < len num; i++)
		wb_put(wb, num[i:i+1]);
	wb_hmov(wb, nr(R_nS) * zwid());
	if(nr(R_nn) > 0)
		nrset(R_nn, nr(R_nn) - 1);
	else
		nrset(R_ln, nr(R_ln) + 1);
	return wb_buf(wb);
}

# the margin character
ren_mc(w, ljust: int): string
{
	wb := wb_new();
	if(w + ljust < nr(R_l) + nr(R_mcn))
		wb_hmov(wb, nr(R_l) + nr(R_mcn) - w - ljust);
	wb_putexpand(wb, env_mc());
	return wb_buf(wb);
}

# process a line and print it with ren_out()
ren_line(line: string, w, ad, body, li, lI, ll, els_neg, els_pos: int): int
{
	ren_first();
	sbeg := "";
	send := "";
	sbuf := line;
	lspc := max(1, nr(R_L)) * nr(R_v);	# line space, ignoring \x
	prev_d := nr(R_d);
	if(!nr(R_ns) || line != nil || els_neg || els_pos){
		if(els_neg)
			ren_sp(-els_neg, 1);
		ren_sp(0, 0);
		if(line != nil && nr(R_nm) && body)
			sbeg += ren_lnum();
		if(!ren_div && dir_do)
			sbuf = dir_fix(sbuf);
		(pre, ljust) := ren_ljust(w, ad, li, lI, ll);
		sbeg += pre;
		if(line != nil && body && nr(R_mc))
			send += ren_mc(w, ljust);
		ren_out(sbeg, sbuf, send);
		nrset(R_ns, 0);
		if(els_pos)
			ren_sp(els_pos, 1);
	}
	nrset(R_a, els_pos);
	if(detect_traps(prev_d, nr(R_d)) || detect_pagelimit(lspc - nr(R_v))){
		if(!ren_pagelimit(lspc - nr(R_v)))
			ren_traps(prev_d, nr(R_d), 0);
		return 1;
	}
	if(line != nil && lspc - nr(R_v) && down(lspc - nr(R_v)))
		return 1;
	return 0;
}

# read a line from fmt and send it to ren_line()
ren_passline(fmt: ref Fmt): int
{
	ad := nr(R_j);
	ren_first();
	if(!fmt_morewords(fmt))
		return 0;
	l := fmt_nextline(fmt);
	if(!nr(R_u)){
		if(nr(R_na) || nr(R_cp) || !(ad & AD_XN)){
			if(nr(R_td) > 0)
				ad = AD_R;
			else
				ad = AD_L;
		}
		if((ad & AD_XN) == AD_CN)
			ad = AD_C;
		if((ad & AD_XN) == AD_RN)
			ad = AD_R;
	}else{
		if((ad & AD_X) == 0){
			if(nr(R_td) > 0)
				ad = AD_R;
			else
				ad = AD_L;
		}else
			ad = ad & AD_X;
	}
	if(nr(R_ce))
		ad = AD_C;
	if(l == nil)
		return ren_line("", 0, ad, 1, 0, 0, 0, 0, 0);
	return ren_line(l.sbuf, l.wid, ad, 1, l.li, l.lI, l.ll, l.elsn, l.elsp);
}

# output the formatted lines in fmt
ren_fmtpop(fmt: ref Fmt): int
{
	ret := 0;
	while(fmt_morelines(fmt))
		ret = ren_passline(fmt);
	if(fmt.eject){
		# end the page here (.wo): spring the next trap, as .ne would
		fmt.eject = 0;
		n := f_nexttrap() + 1;
		# the trap's macro runs within: nothing set at the trap meanwhile
		fmt_ejected(fmt, nr(R_d) + n - 1);
		if(ren_first())
			if(!ren_traps(nr(R_d), nr(R_d) + n - 1, 1))
				ren_pagelimit(n - 1);
		ret = 1;
	}
	return ret;
}

# format and output all lines in fmt
ren_fmtpopall(fmt: ref Fmt)
{
	while(fmt_fill(fmt, 0))
		ren_fmtpop(fmt);
	ren_fmtpop(fmt);
}

# pass the word buffer to the current line buffer
ren_fmtword(wb: ref Wb)
{
	while(fmt_word(cfmt(), wb))
		ren_fmtpop(cfmt());
	wb_reset(wb);
}

# output the current line; whether a trap was triggered
ren_br(): int
{
	ren_first();
	ren_fmtword(cwb());
	while(fmt_fill(cfmt(), 1))
		ren_fmtpop(cfmt());
	return ren_fmtpop(cfmt());
}

tr_br(args: array of string)
{
	if(args[0][0] == c_cc)
		ren_br();
	else
		ren_fmtpopall(cfmt());	# output the completed lines
}

tr_sp(args: array of string)
{
	traps := 0;
	if(args[0][0] == c_cc)
		traps = ren_br();
	n := nr(R_v);
	if(len args > 1)
		n = eval(args[1], 'v');
	if(n && (!nr(R_ns) || ren_div) && !traps)
		down(n);
}

tr_sv(args: array of string)
{
	n := nr(R_v);
	if(len args > 1)
		n = eval(args[1], 'v');
	nrset(R_sv, 0);
	if(n <= f_nexttrap())
		down(n);
	else
		nrset(R_sv, n);
}

tr_ns(nil: array of string)
{
	nrset(R_ns, 1);
}

tr_rs(nil: array of string)
{
	nrset(R_ns, 0);
}

tr_os(nil: array of string)
{
	if(nr(R_sv))
		down(nr(R_sv));
	nrset(R_sv, 0);
}

tr_mk(args: array of string)
{
	if(len args > 1)
		num_set(map(args[1]), nr(R_d));
	else
		nrset(R_mk, nr(R_d));
}

tr_rt(args: array of string)
{
	n := nr(R_mk);
	if(len args > 1)
		n = eval_re(args[1], nr(R_d), 'v');
	if(n >= 0 && n < nr(R_d))
		ren_sp(n - nr(R_d), 0);
}

tr_ne(args: array of string)
{
	n := nr(R_v);
	if(len args > 1)
		n = eval(args[1], 'v');
	if(!ren_first())
		return;
	if(!ren_traps(nr(R_d), nr(R_d) + n - 1, 1))
		ren_pagelimit(n - 1);
}

ren_ejectpage(br: int)
{
	ren_first();
	bp_ejected = nr(R_PG);
	if(br)
		ren_br();
	while(nr(R_PG) == bp_ejected && cdiv == nil){
		if(detect_traps(nr(R_d), nr(R_p)))
			ren_traps(nr(R_d), nr(R_p), 1);
		else{
			bp_ejected = 0;
			ren_page(0);
		}
	}
}

tr_bp(args: array of string)
{
	if(cdiv == nil && (len args > 1 || !nr(R_ns))){
		if(len args > 1)
			bp_next = eval_re(args[1], nr(R_pg), 0);
		ren_ejectpage(args[0][0] == c_cc);
	}
}

tr_pn(args: array of string)
{
	if(len args > 1)
		bp_next = eval_re(args[1], nr(R_pg), 0);
}

ren_ps(s: string)
{
	ps: int;
	if(s == nil || s == "0")
		ps = nr(R_s0) * SC_PT();
	else
		ps = eval_re(s, nr(R_s) * SC_PT(), 'p');
	nrset(R_s0, nr(R_s));
	nrset(R_s, max(1, (ps + SC_PT() / 2) / SC_PT()));
}

tr_ps(args: array of string)
{
	ren_ps(arg(args, 1));
}

tr_ll(args: array of string)
{
	ll := nr(R_l0);
	if(len args > 1)
		ll = eval_re(args[1], nr(R_l), 'm');
	nrset(R_l0, nr(R_l));
	nrset(R_l, max(0, ll));
}

tr_in(args: array of string)
{
	in := nr(R_i0);
	if(len args > 1)
		in = eval_re(args[1], nr(R_i), 'm');
	if(args[0][0] == c_cc)
		ren_br();
	nrset(R_i0, nr(R_i));
	nrset(R_i, max(0, in));
	nrset(R_ti, -1);
}

tr_ti(args: array of string)
{
	if(args[0][0] == c_cc)
		ren_br();
	if(len args > 1)
		nrset(R_ti, eval_re(args[1], nr(R_i), 'm'));
}

tr_l2r(args: array of string)
{
	dir_do = 1;
	if(args[0][0] == c_cc)
		ren_br();
	nrset(R_td, 0);
	nrset(R_cd, 0);
}

tr_r2l(args: array of string)
{
	dir_do = 1;
	if(args[0][0] == c_cc)
		ren_br();
	nrset(R_td, 1);
	nrset(R_cd, 1);
}

tr_in2(args: array of string)
{
	I := nr(R_I0);
	if(len args > 1)
		I = eval_re(args[1], nr(R_I), 'm');
	if(args[0][0] == c_cc)
		ren_br();
	nrset(R_I0, nr(R_I));
	nrset(R_I, max(0, I));
	nrset(R_tI, -1);
}

tr_ti2(args: array of string)
{
	if(args[0][0] == c_cc)
		ren_br();
	if(len args > 1)
		nrset(R_tI, eval_re(args[1], nr(R_I), 'm'));
}

ren_ft(s: string)
{
	fnt: int;
	if(s == nil || s == "P")
		fnt = nr(R_f0);
	else
		fnt = dev_pos(s);
	if(fnt < 0)
		errmsg("troff: failed to mount <" + s + ">\n");
	else{
		nrset(R_f0, nr(R_f));
		nrset(R_f, fnt);
	}
}

tr_ft(args: array of string)
{
	ren_ft(arg(args, 1));
}

tr_fp(args: array of string)
{
	if(len args < 3)
		return;
	pos := -1;
	if(isdigit(at(args[1], 0)))
		pos = atoi(args[1]);
	name := args[2];
	if(len args > 3)
		name = args[3];
	if(dev_mnt(pos, args[2], name) < 0)
		errmsg("troff: failed to mount <" + args[2] + ">\n");
}

tr_nf(args: array of string)
{
	if(args[0][0] == c_cc)
		ren_br();
	nrset(R_u, 0);
}

tr_fi(args: array of string)
{
	if(args[0][0] == c_cc)
		ren_br();
	nrset(R_u, 1);
}

tr_ce(args: array of string)
{
	if(args[0][0] == c_cc)
		ren_br();
	if(len args > 1)
		nrset(R_ce, atoi(args[1]));
	else
		nrset(R_ce, 1);
}

tr_fc(args: array of string)
{
	t: int;
	if(len args > 1){
		(t, c_fa, nil) = charread(args[1], 0);
		if(t >= 0){
			if(len args > 2)
				(t, c_fb, nil) = charread(args[2], 0);
			if(len args <= 2 || t < 0)
				c_fb = " ";
			return;
		}
	}
	c_fa = "";
	c_fb = "";
}

ren_cl(s: string)
{
	m := nr(R_m0);
	if(s != nil)
		m = clr_get(s);
	nrset(R_m0, nr(R_m));
	nrset(R_m, m);
}

tr_cl(args: array of string)
{
	ren_cl(arg(args, 1));
}

tr_ab(args: array of string)
{
	errmsg(arg(args, 1) + "\n");
	ren_aborted = 1;
}

ren_cmd(wb: ref Wb, c: int, a: string)
{
	case c {
	' ' =>
		wb_hmov(wb, font_swid(dev_font(nr(R_f)), nr(R_s), nr(R_ss)));
	'b' =>
		ren_bcmd(wb, a);
	'c' =>
		wb_setpart(wb);
	'D' =>
		ren_dcmd(wb, a);
	'd' =>
		wb_vmov(wb, SC_EM() / 2);
	'f' =>
		ren_ft(a);
	'h' =>
		wb_hmov(wb, eval(a, 'm'));
	'j' =>
		wb_setcost(wb, eval(a, 0));
	'k' =>
		if(wb == cwb())
			num_set(map(a), f_hpos() - nr(R_lb));
		else
			num_set(map(a), wb_wid(wb));
	'L' =>
		ren_vlcmd(wb, a);
	'l' =>
		ren_hlcmd(wb, a);
	'm' =>
		ren_cl(a);
	'o' =>
		ren_ocmd(wb, a);
	'p' =>
		if(wb == cwb())
			while(fmt_fillreq(cfmt()))
				ren_fmtpop(cfmt());
	'r' =>
		wb_vmov(wb, -SC_EM());
	's' =>
		ren_ps(a);
	'u' =>
		wb_vmov(wb, -SC_EM() / 2);
	'v' =>
		wb_vmov(wb, eval(a, 'v'));
	'X' =>
		wb_etc(wb, a);
	'x' =>
		wb_els(wb, eval(a, 'v'));
	'Z' =>
		ren_zcmd(wb, a);
	'0' =>
		wb_hmov(wb, zwid());
	'|' =>
		wb_hmov(wb, SC_EM() / 6);
	'&' =>
		wb_hmov(wb, 0);
	'^' =>
		wb_hmov(wb, SC_EM() / 12);
	'/' =>
		wb_italiccorrection(wb);
	',' =>
		wb_italiccorrectionleft(wb);
	'<' or '>' =>
		nrset(R_cd, c == '<');
		wb_flushdir(wb);
	}
}

# insert a character, escape sequence, field or the like into wb
ren_put(wb: ref Wb, c: string, src: int)
{
	c0 := at(c, 0);
	if(c0 == ' ' || c0 == '\n'){
		wb_put(wb, c);
		return;
	}
	if(c0 == '\t' || c0 == 1){
		if(c0 == '\t')
			ren_tab(wb, env_tc(), src);
		else
			ren_tab(wb, env_lc(), src);
		return;
	}
	if(c_fa != nil && c_fa == c){
		ren_field(wb, src);
		return;
	}
	if(c0 == c_ec){
		c1 := at(c, 1);
		if(c1 == 'z'){
			w := wb_wid(wb);
			ren_char(wb, src);
			wb_hmov(wb, w - wb_wid(wb));
			return;
		}
		if(inset(esc_ren, c1)){
			a: string;
			if(inset(esc_p, c1))
				a = unquotednext(c1, src);
			if(inset(esc_q, c1))
				a = quotednext(src);
			if(c1 == 'e')
				c = ecs() + ecs();
			else if(c1 == 'N')
				c = "GID=" + a;
			else{
				ren_cmd(wb, c1, a);
				return;
			}
		}
	}
	if(ren_div){
		wb_putraw(wb, c);
		return;
	}
	if(cdef_map(c, nr(R_f)) != nil)		# .char characters
		wb_putexpand(wb, c);
	else
		wb_put(wb, c);
}

# read a character and place it in wb
ren_char(wb: ref Wb, src: int): int
{
	(t, c) := charnext(src);
	if(t < 0)
		return -1;
	ren_put(wb, c, src);
	return 0;
}

# like ren_char(); 1 if d1 was read and 2 if d2 was read
ren_chardel(wb: ref Wb, src: int, d1, d2: string): int
{
	(t, c) := charnext(src);
	if(t < 0)
		return -1;
	if(d1 != nil && d1 == c)
		return 1;
	if(d2 != nil && d2 == c)
		return 2;
	ren_put(wb, c, src);
	return 0;
}

# read the argument of \w and push its width
ren_wid(src: int): int
{
	wb := wb_new();
	(nil, delim) := charnext(src);
	odiv_beg();
	c := next(src);
	while(c >= 0 && c != '\n'){
		back(src, c);
		if(ren_chardel(wb, src, delim, nil))
			break;
		c = next(src);
	}
	odiv_end();
	n := wb_wid(wb);
	wb_wconf(wb);
	return n;
}

# 1 if d1 was read and 2 if d2 was read
ren_until(wb: ref Wb, src: int, d1, d2: string): int
{
	c := next(src);
	while(c >= 0 && c != '\n'){
		back(src, c);
		ret := ren_chardel(wb, src, d1, d2);
		if(ret)
			return ret;
		c = next(src);
	}
	if(c == '\n')
		back(src, c);
	return 0;
}

# like ren_until(); map from to dst
ren_untilmap(wb: ref Wb, src: int, end, from, dst: string): int
{
	while(ren_until(wb, src, from, end) == 1){
		sstr_push(dst, 0);
		ren_until(wb, S_SSTR, end, nil);
		sstr_pop();
	}
	return 0;
}

wb_cpy(dst: ref Wb, src: ref Wb, left: int)
{
	wb_hmov(dst, left - wb_wid(dst));
	wb_cat(dst, src);
}

ren_tl(src: int)
{
	ren_first();
	pgnum := num_str(R_pg);
	wb := wb_new();
	wb2 := wb_new();
	(nil, delim) := charnext(src);
	if(delim == "\n")
		back(src, '\n');
	# the left-adjusted string
	ren_untilmap(wb2, src, delim, c_pc, pgnum);
	wb_cpy(wb, wb2, 0);
	# the centred string
	ren_untilmap(wb2, src, delim, c_pc, pgnum);
	wb_cpy(wb, wb2, (nr(R_lt) - wb_wid(wb2)) / 2);
	# the right-adjusted string
	ren_untilmap(wb2, src, delim, c_pc, pgnum);
	wb_cpy(wb, wb2, nr(R_lt) - wb_wid(wb2));
	# flushing the line
	ren_line(wb_buf(wb), wb_wid(wb), AD_L, 0,
			0, 0, nr(R_lt), wb.els_neg, wb.els_pos);
}

ren_field(wb: ref Wb, src: int)
{
	wbs := array[NFIELDS] of ref Wb;
	n := 0;
	while(n < NFIELDS){
		wbs[n] = wb_new();
		if(ren_until(wbs[n++], src, c_fb, c_fa) != 1)
			break;
	}
	left := wb_wid(wb);
	if(wb == cwb())
		left = f_hpos() - nr(R_lb);
	right := tab_next(left);
	wid := 0;
	for(i := 0; i < n; i++)
		wid += wb_wid(wbs[i]);
	d := 1;
	if(n > 1)
		d = n - 1;
	pad := (right - left - wid) / d;
	rem := (right - left - wid) % d;
	for(i = 0; i < n; i++){
		cur_left: int;
		if(i == 0)
			cur_left = left;
		else if(i == n - 1)
			cur_left = right - wb_wid(wbs[i]);
		else
			cur_left = wb_wid(wb) + pad + (i + rem >= n);
		wb_cpy(wb, wbs[i], cur_left);
	}
}

ren_tab(wb: ref Wb, tc: string, src: int)
{
	t := wb_new();
	pos := wb_wid(wb);
	if(wb == cwb())
		pos = f_hpos() - nr(R_lb);
	ins := tab_next(pos);	# the insertion position
	typ := tab_type(pos);	# the tab type
	if(typ == 'R' || typ == 'C'){
		c := next(src);
		while(c >= 0 && c != '\n' && c != '\t' && c != 1){
			back(src, c);
			ren_char(t, src);
			c = next(src);
		}
		back(src, c);
	}
	if(typ == 'C')
		ins -= wb_wid(t) / 2;
	if(typ == 'R')
		ins -= wb_wid(t);
	if(tc == nil || ins <= pos)
		wb_hmov(wb, ins - pos);
	else
		ren_hline(wb, ins - pos, tc);
	wb_cat(wb, t);
}

# parse the characters and requests of s and append them to wb
ren_parse(wb: ref Wb, s: string): int
{
	odiv_beg();
	sstr_push(s, 0);
	c := sstr_next();
	while(c >= 0){
		sstr_back(c);
		if(ren_char(wb, S_SSTR))
			break;
		c = sstr_next();
	}
	sstr_pop();
	odiv_end();
	return 0;
}

# make nested render_rec() exit
tr_popren(args: array of string)
{
	ren_level = 0;
	if(len args > 1)
		ren_level = atoi(args[1]);
}

FMT_PAR(): int
{
	return nr(R_u) && !nr(R_na) && !nr(R_ce) && (nr(R_j) & AD_P) == AD_P;
}

# read characters from tr.b and pass the rendered lines to out.b
render_rec(level: int): int
{
	ren_div_saved := ren_div;
	ren_div = 0;
	if(ren_level >= 100)
		errdie("troff: trap recursion depth limit reached\n");
	while(ren_level >= level){
		while(!ren_un && !tr_nextreq())
			if(ren_level < level)
				break;
		if(ren_level < level)
			break;
		if(ren_aborted)
			return 1;
		c := ren_next();
		if(c < 0){
			if(bp_final >= 2)
				break;
			if(bp_final == 0){
				bp_final = 1;
				if(trap_em >= 0)
					trap_exec(trap_em);
			}else{
				bp_final = 2;
				ren_ejectpage(1);
			}
		}
		if(c >= 0)
			ren_partial = c != '\n';
		# add the current word to the current line
		if(c == ' ' || c == '\n'){
			if(!wb_part(cwb())){	# not after a \c
				ren_fmtword(cwb());
				if(c == '\n')
					while(fmt_newline(cfmt()))
						ren_fmtpop(cfmt());
				if(!FMT_PAR())
					ren_fmtpopall(cfmt());
				if(c == ' ')
					fmt_space(cfmt());
			}
		}
		# flush the line if necessary
		if(c == ' ' || c == '\n' || c < 0)
			ren_fmtpop(cfmt());
		if(c == '\n' || ren_nl)	# the end or start of an input line
			nrset(R_lb, f_hpos());
		if(c == '\n' && nr(R_it)){
			nrset(R_itn, nr(R_itn) - 1);
			if(nr(R_itn) == 0)
				trap_exec(nr(R_it));
		}
		if(c == '\n' && !wb_part(cwb()))
			nrset(R_ce, max(0, nr(R_ce) - 1));
		if(c != ' ' && c >= 0){
			ren_back(c);
			ren_char(cwb(), S_REN);
		}
		if(c >= 0)
			ren_nl = c == '\n';
	}
	# restore ren_div after processing traps
	ren_div = ren_div_saved;
	return 0;
}

# render the input
render(): int
{
	nrset(R_nl, -1);
	while(!tr_nextreq())
		;
	ren_first();			# the transition to the first page
	render_rec(0);
	bp_final = 3;
	if(fmt_morewords(cfmt()))
		ren_page(1);
	ren_br();
	return ren_aborted;
}

# traps

tpos := array[NTRAPS] of {* => 0};	# trap positions
treg := array[NTRAPS] of {* => 0};	# trap registers
ntraps := 0;

tposval(i: int): int
{
	if(tpos[i] < 0)
		return nr(R_p) + tpos[i];
	return tpos[i];
}

trap_first(pos: int): int
{
	best := -1;
	for(i := 0; i < ntraps; i++)
		if(treg[i] >= 0 && tposval(i) > pos)
			if(best < 0 || tposval(i) < tposval(best))
				best = i;
	return best;
}

trap_byreg(reg: int): int
{
	for(i := 0; i < ntraps; i++)
		if(treg[i] == reg)
			return i;
	return -1;
}

trap_bypos(reg, pos: int): int
{
	for(i := 0; i < ntraps; i++)
		if(treg[i] >= 0 && tposval(i) == pos)
			if(reg == -1 || treg[i] == reg)
				return i;
	return -1;
}

tr_wh(args: array of string)
{
	if(len args < 2)
		return;
	pos := eval(args[1], 'v');
	id := trap_bypos(-1, pos);
	if(len args < 3){
		if(id >= 0)
			treg[id] = -1;
		return;
	}
	reg := map(args[2]);
	if(id < 0)		# find an unused position in treg[]
		id = trap_byreg(-1);
	if(id < 0){
		if(ntraps >= NTRAPS)
			return;
		id = ntraps++;
	}
	tpos[id] = pos;
	treg[id] = reg;
}

tr_ch(args: array of string)
{
	if(len args < 2)
		return;
	reg := map(args[1]);
	id := trap_byreg(reg);
	if(id >= 0){
		if(len args > 2)
			tpos[id] = eval(args[2], 'v');
		else
			treg[id] = -1;
	}
}

tr_dt(args: array of string)
{
	if(cdiv == nil)
		return;
	if(len args > 2){
		cdiv.tpos = eval(args[1], 'v');
		cdiv.treg = map(args[2]);
	}else
		cdiv.treg = -1;
}

tr_em(args: array of string)
{
	trap_em = -1;
	if(len args > 1)
		trap_em = map(args[1]);
}

trap_pos(pos: int): int
{
	ret := trap_first(pos);
	if(bp_final >= 3)
		return -1;
	if(cdiv != nil){
		if(cdiv.treg && cdiv.tpos > pos)
			return cdiv.tpos;
		return -1;
	}
	if(ret >= 0)
		return tposval(ret);
	return -1;
}

trap_reg(pos: int): int
{
	ret := trap_first(pos);
	if(cdiv != nil){
		if(cdiv.treg && cdiv.tpos > pos)
			return cdiv.treg;
		return -1;
	}
	if(ret >= 0)
		return treg[ret];
	return -1;
}

f_nexttrap(): int
{
	pos := trap_pos(nr(R_d));
	if(cdiv != nil){
		if(pos >= 0)
			return pos;
		return 16r3fffffff;
	}
	if(pos >= 0 && pos < nr(R_p))
		return pos - nr(R_d);
	return nr(R_p) - nr(R_d);
}
