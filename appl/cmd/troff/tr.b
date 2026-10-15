#
# tr.c: troff requests
#

tr_nl := 1;		# just read a newline
tr_bm := -1;		# blank line macro
tr_sm := -1;		# leading space macro

# skip everything until the end of the line
jmp_eol()
{
	c: int;
	do
		c = cp_next();
	while(c >= 0 && c != '\n');
}

tr_vs(args: array of string)
{
	vs := nr(R_v0);
	if(len args > 1)
		vs = eval_re(args[1], nr(R_v), 'p');
	nrset(R_v0, nr(R_v));
	nrset(R_v, max(0, vs));
}

tr_ls(args: array of string)
{
	ls := nr(R_L0);
	if(len args > 1)
		ls = eval_re(args[1], nr(R_L), 0);
	nrset(R_L0, nr(R_L));
	nrset(R_L, max(1, ls));
}

tr_pl(args: array of string)
{
	s := "11i";
	if(len args > 1)
		s = args[1];
	n := eval_re(s, nr(R_p), 'v');
	nrset(R_p, max(0, n));
}

tr_nr(args: array of string)
{
	if(len args < 3)
		return;
	id := map(args[1]);
	num_set(id, eval_re(args[2], nr(id), 'u'));
	if(len args > 3)
		num_setinc(id, eval(args[3], 'u'));
}

tr_rr(args: array of string)
{
	for(i := 1; i < len args; i++)
		num_del(map(args[i]));
}

tr_af(args: array of string)
{
	if(len args > 2)
		num_setfmt(map(args[1]), args[2]);
}

tr_ds(args: array of string)
{
	if(len args > 1)
		str_set(map(args[1]), arg(args, 2));
}

tr_as(args: array of string)
{
	reg := map(arg(args, 1));
	str_set(reg, str_get(reg) + arg(args, 2));
}

tr_rm(args: array of string)
{
	for(i := 1; i < len args; i++)
		str_rm(map(args[i]));
}

tr_rn(args: array of string)
{
	if(len args < 3)
		return;
	str_rn(map(args[1]), map(args[2]));
}

tr_po(args: array of string)
{
	po := nr(R_o0);
	if(len args > 1)
		po = eval_re(args[1], nr(R_o), 'm');
	nrset(R_o0, nr(R_o));
	nrset(R_o, max(0, po));
}

# read the string argument of a request; and whether there was one
read_string(): (string, int)
{
	sb := "";
	cp_copymode(1);
	c: int;
	while((c = cp_next()) == ' ')
		;
	empty := c <= 0 || c == '\n';
	if(c == '"')
		c = cp_next();
	while(c > 0 && c != '\n'){
		if(c != c_ni)
			sb[len sb] = c;
		c = cp_next();
	}
	if(c >= 0)
		cp_back(c);
	cp_copymode(0);
	if(empty)
		return (nil, 0);
	return (sb, 1);
}

# read a space-separated request argument; if two, read at most two characters
read_name(two: int): string
{
	sb := "";
	c := cp_next();
	i := 0;
	while(c == ' ' || c == '\t' || c == c_ni)
		c = cp_next();
	while(c > 0 && c != ' ' && c != '\t' && c != '\n' && (!two || i < 2)){
		if(c != c_ni){
			sb[len sb] = c;
			i++;
		}
		c = cp_next();
	}
	if(c >= 0)
		cp_back(c);
	return sb;
}

# read the body of a macro until the end request; keep it if keep
macrobody(keep: int, end: string): string
{
	sb := "";
	first := 1;
	cp_back('\n');
	cp_copymode(1);
	while((c := cp_next()) >= 0){
		if(keep && !first)
			sb[len sb] = c;
		first = 0;
		if(c == '\n'){
			if((c = cp_next()) != c_cc){
				cp_back(c);
				continue;
			}
			req := read_name(nr(R_cp));
			if(end == req){
				in_push(end, nil);
				cp_back(c_cc);
				break;
			}
			if(keep){
				sb[len sb] = c_cc;
				sb += req;
			}
		}
	}
	cp_copymode(0);
	return sb;
}

tr_de(args: array of string)
{
	if(len args < 2)
		return;
	id := map(args[1]);
	sb := "";
	if(at(args[0], 1) == 'a' && at(args[0], 2) == 'm' && str_has(id))
		sb = str_get(id);
	end := ".";
	if(len args > 2)
		end = args[2];
	sb += macrobody(1, end);
	str_set(id, sb);
	if(!nr(R_cp) && len args > 3)	# parse the arguments as request args[3]
		str_dset(id, str_dget(map(args[3])));
}

tr_ig(args: array of string)
{
	end := ".";
	if(len args > 1)
		end = args[1];
	macrobody(0, end);
}

# read until stop; if stop is nil, stop at whitespace; 1 at the end of the line
read_until(stop: string, hasstop: int, src: int): (string, int)
{
	sb := "";
	while((c := next(src)) >= 0){
		if(c == c_ni)
			continue;
		back(src, c);
		if(c == '\n')
			return (sb, 1);
		if(!hasstop && (c == ' ' || c == '\t'))
			return (sb, 0);
		(nil, cs) := charnext(src);
		if(hasstop && stop == cs)
			return (sb, 0);
		sb += charnext_str(cs);
	}
	return (sb, 1);
}

# evaluate .if strcmp ('str'str')
if_strcmp(src: int): int
{
	(nil, delim) := charnext(src);
	(s1, nil) := read_until(delim, 1, src);
	(s2, nil) := read_until(delim, 1, src);
	cp_reqbeg();
	return s1 == s2;
}

# evaluate .if condition letters
if_cond(src: int): int
{
	case next(src) {
	'o' =>
		return nr(R_pg) % 2;
	'e' =>
		return !(nr(R_pg) % 2);
	't' =>
		return 1;
	'n' =>
		return 0;
	}
	return 0;
}

# evaluate an .if expression
if_eval(src: int): int
{
	(s, nil) := read_until(nil, 0, src);
	return eval(s, 0) > 0;
}

eval_if(src: int): int
{
	neg := 0;
	c: int;
	do
		c = next(src);
	while(c == ' ' || c == '\t');
	if(c == '!'){
		neg = 1;
		c = next(src);
	}
	back(src, c);
	ret: int;
	if(c > 0 && strchr("oetn", c) >= 0)
		ret = if_cond(src);
	else if(c == ' ')
		ret = 0;
	else if(!isdigit(c) && !(c > 0 && strchr("-+*/%<=>&:.|()", c) >= 0))
		ret = if_strcmp(src);
	else
		ret = if_eval(src);
	return ret != neg;
}

ie_cond := array[NIES] of {* => 0};	# the .ie condition stack
ie_depth := 0;

tr_if(args: array of string)
{
	c := eval_if(S_CP);
	if(at(args[0], 1) == 'i' && at(args[0], 2) == 'e')	# .ie
		if(ie_depth < NIES)
			ie_cond[ie_depth++] = c;
	cp_blk(!c);
}

tr_el(nil: array of string)
{
	if(ie_depth > 0)
		cp_blk(ie_cond[--ie_depth]);
	else
		cp_blk(1);
}

tr_na(nil: array of string)
{
	nrset(R_na, 1);
}

tr_ad(args: array of string)
{
	nrset(R_na, 0);
	if(len args < 2)
		return;
	s := args[1];
	if(isdigit(at(s, 0)))
		nrset(R_j, atoi(s) & 16rfff);
	else{
		j := 0;
		for(i := 0; i < len s; i++){
			case s[i] {
			'c' =>	j |= AD_C;
			'l' =>	j |= AD_L;
			'r' =>	j |= AD_R;
			'b' =>	j |= AD_B;
			'p' =>	j |= AD_P;
			'q' =>	j |= AD_Q;
			'k' =>	j |= AD_K;
			'L' =>	j |= AD_LN;
			'R' =>	j |= AD_RN;
			'C' =>	j |= AD_CN;
			}
		}
		# if p is specified without l, r and c, assume b
		if(j & AD_P && !(j & AD_X))
			j |= AD_B;
		nrset(R_j, j);
	}
}

tr_tm(args: array of string)
{
	errmsg(arg(args, 1) + "\n");
}

tr_so(args: array of string)
{
	if(len args > 1)
		in_so(args[1]);
}

tr_nx(args: array of string)
{
	in_nx(arg(args, 1));
}

tr_shift(args: array of string)
{
	n := 1;
	if(len args > 1)
		n = atoi(args[1]);
	while(n-- >= 1)
		in_shift();
}

tr_ex(nil: array of string)
{
	in_ex();
}

tr_sy(args: array of string)
{
	errmsg("troff: .sy " + arg(args, 1) + ": not run\n");
}

tr_lt(args: array of string)
{
	lt := nr(R_lt0);
	if(len args > 1)
		lt = eval_re(args[1], nr(R_lt), 'm');
	nrset(R_lt0, nr(R_lt));
	nrset(R_lt, max(0, lt));
}

tr_pc(args: array of string)
{
	t := -1;
	if(len args > 1)
		(t, c_pc, nil) = charread(args[1], 0);
	if(t < 0)
		c_pc = "";
}

tr_tl(nil: array of string)
{
	c: int;
	do
		c = cp_next();
	while(c >= 0 && (c == ' ' || c == '\t'));
	cp_back(c);
	ren_tl(S_CP);
	do
		c = cp_next();
	while(c >= 0 && c != '\n');
}

tr_ec(args: array of string)
{
	c_ec = '\\';
	if(len args > 1 && args[1] != nil)
		c_ec = args[1][0];
}

tr_cc(args: array of string)
{
	c_cc = '.';
	if(len args > 1 && args[1] != nil)
		c_cc = args[1][0];
}

tr_c2(args: array of string)
{
	c_c2 = '\'';
	if(len args > 1 && args[1] != nil)
		c_c2 = args[1][0];
}

tr_eo(nil: array of string)
{
	c_ec = -1;
}

tr_hc(args: array of string)
{
	t := -1;
	if(len args > 1)
		(t, env.hc, nil) = charread(args[1], 0);
	if(t < 0)
		env.hc = "\\%";
}

# sentence-ending characters and the transparent ones after them
eos_sent := array[NCHARS] of string;
eos_sentcnt := 0;
eos_tran := array[NCHARS] of string;
eos_trancnt := 0;

# the characters read from s into a, at most NCHARS - 1
charsread(s: string, a: array of string): int
{
	n := 0;
	i := 0;
	for(;;){
		(t, c, ni) := charread(s, i);
		if(t < 0)
			break;
		i = ni;
		a[n] = c;
		if(n < NCHARS - 1)
			n++;
	}
	return n;
}

tr_eos(args: array of string)
{
	eos_sentcnt = 0;
	eos_trancnt = 0;
	if(len args > 1)
		eos_sentcnt = charsread(args[1], eos_sent);
	if(len args > 2)
		eos_trancnt = charsread(args[2], eos_tran);
}

# whether s is one of a[0:n]; compared by length and first character first
charsin(a: array of string, n: int, s: string): int
{
	l := len s;
	if(l == 0){
		for(i := 0; i < n; i++)
			if(a[i] == s)
				return 1;
		return 0;
	}
	c := s[0];
	for(i := 0; i < n; i++)
		if(len a[i] == l && a[i][0] == c && a[i] == s)
			return 1;
	return 0;
}

c_eossent(s: string): int
{
	return charsin(eos_sent, eos_sentcnt, s);
}

c_eostran(s: string): int
{
	return charsin(eos_tran, eos_trancnt, s);
}

# hyphenation dashes and the hyphenation-inhibiting character
hy_dash := array[NCHARS] of string;
hy_dashcnt := 0;
hy_stop := array[NCHARS] of string;
hy_stopcnt := 0;

chardefaults()
{
	d := array[] of {".", "?", "!"};
	for(i := 0; i < len d; i++)
		eos_sent[i] = d[i];
	eos_sentcnt = len d;
	d = array[] of {"'", "\"", ")", "]", "*"};
	for(i = 0; i < len d; i++)
		eos_tran[i] = d[i];
	eos_trancnt = len d;
	d = array[] of {"\\:", "-", "em", "en", "\\-", "--", "hy"};
	for(i = 0; i < len d; i++)
		hy_dash[i] = d[i];
	hy_dashcnt = len d;
	hy_stop[0] = "\\%";
	hy_stopcnt = 1;
}

tr_nh(nil: array of string)
{
	nrset(R_hy, 0);
}

tr_hy(args: array of string)
{
	n := 1;
	if(len args > 1)
		n = eval_re(args[1], nr(R_hy), 0);
	nrset(R_hy, n);
}

tr_hlm(args: array of string)
{
	n := 0;
	if(len args > 1)
		n = eval_re(args[1], nr(R_hlm), 0);
	nrset(R_hlm, n);
}

tr_hycost(args: array of string)
{
	a := 0;
	b := 0;
	c := 0;
	if(len args > 1)
		a = eval_re(args[1], nr(R_hycost), 0);
	if(len args > 2)
		b = eval_re(args[2], nr(R_hycost2), 0);
	if(len args > 3)
		c = eval_re(args[3], nr(R_hycost3), 0);
	nrset(R_hycost, a);
	nrset(R_hycost2, b);
	nrset(R_hycost3, c);
}

tr_hydash(args: array of string)
{
	hy_dashcnt = 0;
	if(len args > 1)
		hy_dashcnt = charsread(args[1], hy_dash);
}

tr_hystop(args: array of string)
{
	hy_stopcnt = 0;
	if(len args > 1)
		hy_stopcnt = charsread(args[1], hy_stop);
}

c_hydash(s: string): int
{
	return charsin(hy_dash, hy_dashcnt, s);
}

c_hystop(s: string): int
{
	return charsin(hy_stop, hy_stopcnt, s);
}

c_hymark(s: string): int
{
	l := len s;
	return l == len c_bp && s == c_bp || l == len env.hc && s == env.hc;
}

tr_pmll(args: array of string)
{
	a := 0;
	b := 100;
	if(len args > 1)
		a = eval_re(args[1], nr(R_pmll), 0);
	if(len args > 2)
		b = eval_re(args[2], nr(R_pmllcost), 0);
	nrset(R_pmll, a);
	nrset(R_pmllcost, b);
}

tr_lg(args: array of string)
{
	if(len args > 1)
		nrset(R_lg, eval(args[1], 0));
}

tr_kn(args: array of string)
{
	if(len args > 1)
		nrset(R_kn, eval(args[1], 0));
}

tr_cp(args: array of string)
{
	if(len args > 1)
		nrset(R_cp, atoi(args[1]));
}

tr_ss(args: array of string)
{
	if(len args > 1){
		nrset(R_ss, eval_re(args[1], nr(R_ss), 0));
		if(len args > 2)
			nrset(R_sss, eval_re(args[2], nr(R_sss), 0));
		else
			nrset(R_sss, nr(R_ss));
	}
}

tr_ssh(args: array of string)
{
	n := 0;
	if(len args > 1)
		n = eval_re(args[1], nr(R_ssh), 0);
	nrset(R_ssh, n);
}

argfont(args: array of string): ref Font
{
	if(len args > 1)
		return dev_font(dev_pos(args[1]));
	return nil;
}

tr_cs(args: array of string)
{
	fnt := argfont(args);
	if(fnt != nil){
		a := 0;
		b := 0;
		if(len args > 2)
			a = eval(args[2], 0);
		if(len args > 3)
			b = eval(args[3], 0);
		font_setcs(fnt, a, b);
	}
}

tr_fzoom(args: array of string)
{
	fnt := argfont(args);
	if(fnt != nil){
		z := 0;
		if(len args > 2)
			z = eval(args[2], 0);
		font_setzoom(fnt, z);
	}
}

tr_tkf(args: array of string)
{
	fnt := argfont(args);
	if(fnt != nil && len args > 5)
		font_track(fnt, eval(args[2], 0), eval(args[3], 0),
				eval(args[4], 0), eval(args[5], 0));
}

tr_ff(args: array of string)
{
	fnt := argfont(args);
	for(i := 2; i < len args; i++)
		if(fnt != nil && len args[i] >= 2)
			font_feat(fnt, args[i][1:], args[i][0] == '+');
}

# .rules [n]: rules drawn as lines (draw.b)
tr_rules(args: array of string)
{
	n_rules = 1;
	if(len args > 1)
		n_rules = eval(args[1], 0) != 0;
}

tr_ffsc(args: array of string)
{
	fnt := argfont(args);
	if(fnt != nil){
		font_scrp(fnt, arg(args, 2), len args > 2);
		font_lang(fnt, arg(args, 3), len args > 3);
	}
}

nm_isnum(s: string): int
{
	if(s == nil || strchr("0123456789+-(", s[0]) < 0)
		return 0;
	for(i := 0; i < len s; i++)
		if(isdigit(s[i]))
			return 1;
	return 0;
}

tr_nm(args: array of string)
{
	if(len args < 2){
		nrset(R_nm, 0);
		return;
	}
	nrset(R_nm, 1);
	if(nm_isnum(args[1]))
		nrset(R_ln, max(0, eval_re(args[1], nr(R_ln), 0)));
	if(len args > 2 && nm_isnum(args[2]))
		nrset(R_nM, max(1, eval(args[2], 0)));
	if(len args > 3 && nm_isnum(args[3]))
		nrset(R_nS, max(0, eval(args[3], 0)));
	if(len args > 4 && nm_isnum(args[4]))
		nrset(R_nI, max(0, eval(args[4], 0)));
}

tr_nn(args: array of string)
{
	n := 1;
	if(len args > 1)
		n = eval(args[1], 0);
	nrset(R_nn, n);
}

tr_bd(args: array of string)
{
	if(len args < 2 || args[1] == "S")
		return;
	fnt := argfont(args);
	if(fnt != nil){
		b := 0;
		if(len args > 2)
			b = eval(args[2], 'u');
		font_setbd(fnt, b);
	}
}

tr_it(args: array of string)
{
	if(len args > 2){
		nrset(R_it, map(args[2]));
		nrset(R_itn, eval(args[1], 0));
	}else
		nrset(R_it, 0);
}

tr_mc(args: array of string)
{
	if(len args > 1){
		(t, c, nil) := charread(args[1], 0);
		if(t >= 0){
			env.mc = c;
			nrset(R_mc, 1);
			if(len args > 2)
				nrset(R_mcn, eval(args[2], 'm'));
			else
				nrset(R_mcn, SC_EM());
			return;
		}
	}
	nrset(R_mc, 0);
}

tr_tc(args: array of string)
{
	t := -1;
	if(len args > 1)
		(t, env.tc, nil) = charread(args[1], 0);
	if(t < 0)
		env.tc = "";
}

tr_lc(args: array of string)
{
	t := -1;
	if(len args > 1)
		(t, env.lc, nil) = charread(args[1], 0);
	if(t < 0)
		env.lc = "";
}

tr_lf(args: array of string)
{
	if(len args > 1)
		in_lf(arg(args, 2), eval(args[1], 0));
}

tr_chop(args: array of string)
{
	id := map(arg(args, 1));
	if(str_has(id)){
		s := str_get(id);
		if(s != nil)
			str_set(id, s[0:len s - 1]);
	}
}

# character translation (.tr)
cmap: ref Dict;
cmap_src := array[NCMAPS] of string;
cmap_dst := array[NCMAPS] of string;
cmap_n := 0;

cmap_add(c1, c2: string)
{
	i := dict_get(cmap, c1);
	if(i >= 0)
		cmap_dst[i] = c2;
	else if(cmap_n < NCMAPS){
		cmap_src[cmap_n] = c1;
		cmap_dst[cmap_n] = c2;
		dict_put(cmap, c1, cmap_n);
		cmap_n++;
	}
}

cmap_map(c: string): string
{
	if(!cmap_n)
		return c;
	i := dict_get(cmap, c);
	if(i >= 0)
		return cmap_dst[i];
	return c;
}

tr_tr(args: array of string)
{
	if(len args < 2)
		return;
	s := args[1];
	i := 0;
	for(;;){
		(t, c1, ni) := charread(s, i);
		if(t < 0)
			break;
		i = ni;
		c2: string;
		(t, c2, ni) = charread(s, i);
		if(t < 0)
			c2 = " ";
		else
			i = ni;
		cmap_add(c1, c2);
	}
}

# character definitions (.char)
cdef_src := array[NCDEFS] of string;	# the character
cdef_dst := array[NCDEFS] of string;	# its definition
cdef_def := array[NCDEFS] of {* => 0};	# defined
cdef_fn := array[NCDEFS] of {* => 0};	# the owning font
cdef_n := 0;
cdef_expanding := 0;			# inside a cdef_expand() call

cdef_find(c: string, fnt: int): int
{
	for(i := 0; i < cdef_n; i++)
		if((!cdef_fn[i] || cdef_fn[i] == fnt) && cdef_src[i] == c)
			return i;
	return -1;
}

# the definition of the character, or nil
cdef_map(c: string, fnt: int): string
{
	if(!cdef_n || cdef_expanding)
		return nil;
	i := cdef_find(c, fnt);
	if(i >= 0 && cdef_def[i]){
		if(cdef_dst[i] == nil)
			return " ";	# defined, but empty (it is still a definition)
		return cdef_dst[i];
	}
	return nil;
}

cdef_expand(wb: ref Wb, s: string, fnt: int): int
{
	if(!cdef_n || cdef_expanding)
		return 1;
	i := cdef_find(s, fnt);
	if(i < 0 || !cdef_def[i])
		return 1;
	cdef_expanding = 1;
	ren_parse(wb, cdef_dst[i]);
	cdef_expanding = 0;
	return 0;
}

cdef_remove(fnt: string, hasfn: int, cs: string)
{
	if(cs == nil)
		return;
	(t, c, nil) := charread(cs, 0);
	if(t < 0)
		return;
	fp := -1;
	if(hasfn)
		fp = dev_pos(fnt);
	for(i := 0; i < cdef_n; i++)
		if(cdef_src[i] == c)
			if(!hasfn || (fp > 0 && cdef_fn[i] == fp)){
				cdef_dst[i] = nil;
				cdef_def[i] = 0;
				cdef_src[i] = "";
			}
}

cdef_add(fnt: string, hasfn: int, cs: string, def: string)
{
	(t, c, nil) := charread(cs, 0);
	if(t < 0)
		return;
	fp := -1;
	if(hasfn)
		fp = dev_pos(fnt);
	i := cdef_find(c, fp);
	if(i < 0){
		for(i = 0; i < cdef_n; i++)
			if(!cdef_def[i])
				break;
		if(i == cdef_n && cdef_n < NCDEFS)
			cdef_n++;
	}
	if(i >= 0 && i < cdef_n){
		cdef_src[i] = c;
		cdef_dst[i] = def;
		cdef_def[i] = 1;
		cdef_fn[i] = 0;
		if(hasfn)
			cdef_fn[i] = dev_pos(fnt);
	}
}

tr_rchar(args: array of string)
{
	for(i := 1; i < len args; i++)
		cdef_remove(nil, 0, args[i]);
}

tr_char(args: array of string)
{
	if(len args > 2)
		cdef_add(nil, 0, args[1], args[2]);
	else
		cdef_remove(nil, 0, arg(args, 1));
}

tr_ochar(args: array of string)
{
	if(len args > 3)
		cdef_add(args[1], 1, args[2], args[3]);
	else
		cdef_remove(arg(args, 1), 1, arg(args, 2));
}

# .mtp [n]: protrusion into the margin, on (1) or off (0), in this
# environment: a line's first and last glyphs hang out of it by what
# .mtpc gives them, and the line is filled and adjusted for that
tr_mtp(args: array of string)
{
	n := 1;
	if(len args > 1)
		n = eval(args[1], 0) != 0;
	nrset(R_mtp, n);
}

# .mtpc F l r c...: the characters' protrusion in font F, left and right,
# in thousandths of the glyph's width (as pdfTeX's \lpcode and \rpcode)
tr_mtpc(args: array of string)
{
	fnt := argfont(args);
	if(fnt == nil || len args < 5)
		return;
	l := eval(args[2], 0);
	r := eval(args[3], 0);
	for(k := 4; k < len args; k++){
		a := args[k];
		i := 0;
		while(i < len a){
			(t, c, ni) := charread(a, i);
			if(t < 0 || ni <= i)
				break;
			i = ni;
			g := font_find(fnt, c);
			if(g != nil)
				font_setprot(fnt, g, l, r);
		}
	}
}

# .mte stretch shrink step: font expansion, in thousandths of the
# glyphs' widths: a justified line's glyphs may widen by stretch or
# narrow by shrink, in steps of step, so its spaces stay nearer their
# width (pdfTeX's \pdfadjustspacing); .mte 0 (the default) is off
tr_mte(args: array of string)
{
	st := 0;
	sh := 0;
	sp := 1;
	if(len args > 1)
		st = max(0, eval(args[1], 0));
	sh = st;
	if(len args > 2)
		sh = max(0, eval(args[2], 0));
	if(len args > 3)
		sp = max(1, eval(args[3], 0));
	nrset(R_mtes, st);
	nrset(R_mtek, sh);
	nrset(R_mtep, sp);
}

# .wo n: widows and orphans, in this environment: with n 1, a
# paragraph's first line is not left alone at a page's foot, nor its
# last carried alone to the next page
tr_wo(args: array of string)
{
	n := 1;
	if(len args > 1)
		n = eval(args[1], 0) != 0;
	nrset(R_wo, n);
}

# .mg n: say which characters no font has (1), or not (0, the default)
tr_mg(args: array of string)
{
	mg_warn = 1;
	if(len args > 1)
		mg_warn = eval(args[1], 0) != 0;
}

tr_fmap(args: array of string)
{
	fnt := argfont(args);
	if(fnt != nil && len args > 2)
		font_map(fnt, args[2], arg(args, 3), len args > 3);
}

tr_blm(args: array of string)
{
	tr_bm = -1;
	if(len args > 1)
		tr_bm = map(args[1]);
}

tr_lsm(args: array of string)
{
	tr_sm = -1;
	if(len args > 1)
		tr_sm = map(args[1]);
}

tr_co(args: array of string)
{
	if(len args > 2 && str_has(map(args[1])))
		str_set(map(args[2]), str_get(map(args[1])));
}

tr_coa(args: array of string)
{
	if(len args > 2 && str_has(map(args[1])))
		str_set(map(args[2]), str_get(map(args[2])) + str_get(map(args[1])));
}

tr_coo(args: array of string)
{
	reg := arg(args, 1);
	path := arg(args, 2);
	if(reg == nil || path == nil)
		return;
	fd := sys->create(path, Sys->OWRITE, 8r666);
	if(fd != nil){
		b := array of byte str_get(map(reg));
		sys->write(fd, b, len b);
	}
}

tr_coi(args: array of string)
{
	reg := arg(args, 1);
	path := arg(args, 2);
	if(reg == nil || path == nil)
		return;
	f := bufio->open(path, Bufio->OREAD);
	if(f != nil){
		s := "";
		while((c := f.getc()) >= 0)
			s[len s] = c;
		str_set(map(reg), s);
		f.close();
	}
}

tr_dv(args: array of string)
{
	if(len args > 1)
		out_x(args[1]);
}

# read a macro argument into a; 1 at the end of the arguments
macroarg(a: array of string, n: int, brk: int, src: int): (int, int)
{
	quoted := 0;
	c := next(src);
	while(c == ' ')
		c = next(src);
	if(c == '\n' || c == brk)
		back(src, c);
	if(c < 0 || c == '\n' || c == brk)
		return (1, n);
	if(c == '"'){
		quoted = 1;
		c = next(src);
	}
	sb := "";
	while(c >= 0 && c != '\n' && (quoted || c != brk)){
		if(!quoted && c == ' ')
			break;
		if(quoted && c == '"'){
			c = next(src);
			if(c != '"')
				break;
		}
		if(c == c_ec){
			sb[len sb] = c;
			c = next(src);
			if(c < 0)
				break;
		}
		sb[len sb] = c;
		c = next(src);
	}
	if(n < len a)
		a[n++] = sb;
	if(c >= 0)
		back(src, c);
	return (0, n);
}

# read the arguments of a macro up to brk
tr_args(brk: int, src: int): array of string
{
	a := array[NARGS] of string;
	n := 0;
	done: int;
	do
		(done, n) = macroarg(a, n, brk, src);
	while(!done);
	return a[0:n];
}

# read the arguments of a macro
mkargs_macro(a: array of string, n: int): int
{
	cp_copymode(1);
	done: int;
	do
		(done, n) = macroarg(a, n, -1, S_CP);
	while(!done);
	jmp_eol();
	cp_copymode(0);
	return n;
}

# read the arguments of a request; trims tabs too
mkargs_req(a: array of string, n: int): int
{
	c := cp_next();
	while(n < len a){
		ok := 0;
		while(c == ' ' || c == '\t')
			c = cp_next();
		sb := "";
		while(c >= 0 && c != '\n' && c != ' ' && c != '\t'){
			if(c != c_ni)
				sb[len sb] = c;
			c = cp_next();
			ok = 1;
		}
		if(ok)
			a[n++] = sb;
		if(c == '\n')
			cp_back(c);
		if(c < 0 || c == '\n')
			break;
	}
	jmp_eol();
	return n;
}

# read the arguments of .ds and .char
mkargs_ds(a: array of string, n: int): int
{
	a[n++] = read_name(nr(R_cp));
	(s, ok) := read_string();
	if(ok)
		a[n++] = s;
	jmp_eol();
	return n;
}

# read the arguments of .ochar
mkargs_ochar(a: array of string, n: int): int
{
	a[n++] = read_name(0);
	return mkargs_ds(a, n);
}

# read the arguments of .nr
mkargs_reg1(a: array of string, n: int): int
{
	a[n++] = read_name(nr(R_cp));
	return mkargs_req(a, n);
}

# read the whole line, for .tm
mkargs_eol(a: array of string, n: int): int
{
	cp_copymode(1);
	c := cp_next();
	while(c == ' ')
		c = cp_next();
	sb := "";
	while(c >= 0 && c != '\n'){
		if(c != c_ni)
			sb[len sb] = c;
		c = cp_next();
	}
	cp_copymode(0);
	if(sb != nil)
		a[n++] = sb;
	return n;
}

# argument readers
A_REQ, A_EOL, A_REG1, A_DS, A_NULL, A_OCHAR: con iota;

# the requests and how their arguments are read
Cmd: adt {
	id:	string;
	args:	int;
};

cmds := array[] of {
	Cmd(TR_DIVBEG, A_REQ),
	Cmd(TR_DIVEND, A_REQ),
	Cmd(TR_DIVVS, A_REQ),
	Cmd(TR_POPREN, A_REQ),
	Cmd(">>", A_REQ),
	Cmd("<<", A_REQ),
	Cmd("ab", A_EOL),
	Cmd("ad", A_REQ),
	Cmd("af", A_REQ),
	Cmd("am", A_REG1),
	Cmd("as", A_DS),
	Cmd("bd", A_REQ),
	Cmd("blm", A_REQ),
	Cmd("bp", A_REQ),
	Cmd("br", A_REQ),
	Cmd("c2", A_REQ),
	Cmd("cc", A_REQ),
	Cmd("ce", A_REQ),
	Cmd("ch", A_REQ),
	Cmd("char", A_DS),
	Cmd("chop", A_REG1),
	Cmd("cl", A_REQ),
	Cmd("co", A_REQ),
	Cmd("co+", A_REQ),
	Cmd("co<", A_DS),
	Cmd("co>", A_DS),
	Cmd("cp", A_REQ),
	Cmd("cs", A_REQ),
	Cmd("da", A_REQ),
	Cmd("de", A_REG1),
	Cmd("di", A_REQ),
	Cmd("ds", A_DS),
	Cmd("dt", A_REQ),
	Cmd("dv", A_EOL),
	Cmd("ec", A_REQ),
	Cmd("el", A_NULL),
	Cmd("em", A_REQ),
	Cmd("eo", A_REQ),
	Cmd("eos", A_REQ),
	Cmd("ev", A_REQ),
	Cmd("evc", A_REQ),
	Cmd("ex", A_REQ),
	Cmd("fc", A_REQ),
	Cmd("ff", A_REQ),
	Cmd("fi", A_REQ),
	Cmd("fl", A_REQ),
	Cmd("fmap", A_REQ),
	Cmd("fp", A_REQ),
	Cmd("ffsc", A_REQ),
	Cmd("fspecial", A_REQ),
	Cmd("rules", A_REQ),
	Cmd("mtp", A_REQ),
	Cmd("mtpc", A_REQ),
	Cmd("mte", A_REQ),
	Cmd("wo", A_REQ),
	Cmd("mg", A_REQ),
	Cmd("ft", A_REQ),
	Cmd("fzoom", A_REQ),
	Cmd("hc", A_REQ),
	Cmd("hcode", A_REQ),
	Cmd("hlm", A_REQ),
	Cmd("hpf", A_REQ),
	Cmd("hpfa", A_REQ),
	Cmd("hy", A_REQ),
	Cmd("hycost", A_REQ),
	Cmd("hydash", A_REQ),
	Cmd("hystop", A_REQ),
	Cmd("hw", A_REQ),
	Cmd("ie", A_NULL),
	Cmd("if", A_NULL),
	Cmd("ig", A_REQ),
	Cmd("in", A_REQ),
	Cmd("in2", A_REQ),
	Cmd("it", A_REQ),
	Cmd("kn", A_REQ),
	Cmd("lc", A_REQ),
	Cmd("lf", A_REQ),
	Cmd("lg", A_REQ),
	Cmd("ll", A_REQ),
	Cmd("ls", A_REQ),
	Cmd("lsm", A_REQ),
	Cmd("lt", A_REQ),
	Cmd("mc", A_REQ),
	Cmd("mk", A_REQ),
	Cmd("na", A_REQ),
	Cmd("ne", A_REQ),
	Cmd("nf", A_REQ),
	Cmd("nh", A_REQ),
	Cmd("nm", A_REQ),
	Cmd("nn", A_REQ),
	Cmd("nr", A_REG1),
	Cmd("ns", A_REQ),
	Cmd("nx", A_REQ),
	Cmd("ochar", A_OCHAR),
	Cmd("os", A_REQ),
	Cmd("pc", A_REQ),
	Cmd("pl", A_REQ),
	Cmd("pmll", A_REQ),
	Cmd("pn", A_REQ),
	Cmd("po", A_REQ),
	Cmd("ps", A_REQ),
	Cmd("rchar", A_REQ),
	Cmd("rm", A_REQ),
	Cmd("rn", A_REQ),
	Cmd("rr", A_REQ),
	Cmd("rs", A_REQ),
	Cmd("rt", A_REQ),
	Cmd("shift", A_REQ),
	Cmd("so", A_REQ),
	Cmd("sp", A_REQ),
	Cmd("ss", A_REQ),
	Cmd("ssh", A_REQ),
	Cmd("sv", A_REQ),
	Cmd("sy", A_EOL),
	Cmd("ta", A_REQ),
	Cmd("tc", A_REQ),
	Cmd("ti", A_REQ),
	Cmd("ti2", A_REQ),
	Cmd("tkf", A_REQ),
	Cmd("tl", A_NULL),
	Cmd("tm", A_EOL),
	Cmd("tr", A_EOL),
	Cmd("vs", A_REQ),
	Cmd("wh", A_REQ),
};

# run request number i (its index in cmds)
cmd_run(i: int, args: array of string)
{
	case cmds[i].id {
	TR_DIVBEG =>	tr_divbeg(args);
	TR_DIVEND =>	tr_divend(args);
	TR_DIVVS =>	tr_divvs(args);
	TR_POPREN =>	tr_popren(args);
	">>" =>		tr_l2r(args);
	"<<" =>		tr_r2l(args);
	"ab" =>		tr_ab(args);
	"ad" =>		tr_ad(args);
	"af" =>		tr_af(args);
	"am" =>		tr_de(args);
	"as" =>		tr_as(args);
	"bd" =>		tr_bd(args);
	"blm" =>	tr_blm(args);
	"bp" =>		tr_bp(args);
	"br" =>		tr_br(args);
	"c2" =>		tr_c2(args);
	"cc" =>		tr_cc(args);
	"ce" =>		tr_ce(args);
	"ch" =>		tr_ch(args);
	"char" =>	tr_char(args);
	"chop" =>	tr_chop(args);
	"cl" =>		tr_cl(args);
	"co" =>		tr_co(args);
	"co+" =>	tr_coa(args);
	"co<" =>	tr_coi(args);
	"co>" =>	tr_coo(args);
	"cp" =>		tr_cp(args);
	"cs" =>		tr_cs(args);
	"da" =>		tr_di(args);
	"de" =>		tr_de(args);
	"di" =>		tr_di(args);
	"ds" =>		tr_ds(args);
	"dt" =>		tr_dt(args);
	"dv" =>		tr_dv(args);
	"ec" =>		tr_ec(args);
	"el" =>		tr_el(args);
	"em" =>		tr_em(args);
	"eo" =>		tr_eo(args);
	"eos" =>	tr_eos(args);
	"ev" =>		tr_ev(args);
	"evc" =>	tr_evc(args);
	"ex" =>		tr_ex(args);
	"fc" =>		tr_fc(args);
	"ff" =>		tr_ff(args);
	"fi" =>		tr_fi(args);
	"fl" =>		tr_br(args);
	"fmap" =>	tr_fmap(args);
	"fp" =>		tr_fp(args);
	"ffsc" =>	tr_ffsc(args);
	"fspecial" =>	tr_fspecial(args);
	"rules" =>	tr_rules(args);
	"mtp" =>	tr_mtp(args);
	"mtpc" =>	tr_mtpc(args);
	"mte" =>	tr_mte(args);
	"wo" =>	tr_wo(args);
	"mg" =>	tr_mg(args);
	"ft" =>		tr_ft(args);
	"fzoom" =>	tr_fzoom(args);
	"hc" =>		tr_hc(args);
	"hcode" =>	tr_hcode(args);
	"hlm" =>	tr_hlm(args);
	"hpf" =>	tr_hpf(args);
	"hpfa" =>	tr_hpfa(args);
	"hy" =>		tr_hy(args);
	"hycost" =>	tr_hycost(args);
	"hydash" =>	tr_hydash(args);
	"hystop" =>	tr_hystop(args);
	"hw" =>		tr_hw(args);
	"ie" =>		tr_if(args);
	"if" =>		tr_if(args);
	"ig" =>		tr_ig(args);
	"in" =>		tr_in(args);
	"in2" =>	tr_in2(args);
	"it" =>		tr_it(args);
	"kn" =>		tr_kn(args);
	"lc" =>		tr_lc(args);
	"lf" =>		tr_lf(args);
	"lg" =>		tr_lg(args);
	"ll" =>		tr_ll(args);
	"ls" =>		tr_ls(args);
	"lsm" =>	tr_lsm(args);
	"lt" =>		tr_lt(args);
	"mc" =>		tr_mc(args);
	"mk" =>		tr_mk(args);
	"na" =>		tr_na(args);
	"ne" =>		tr_ne(args);
	"nf" =>		tr_nf(args);
	"nh" =>		tr_nh(args);
	"nm" =>		tr_nm(args);
	"nn" =>		tr_nn(args);
	"nr" =>		tr_nr(args);
	"ns" =>		tr_ns(args);
	"nx" =>		tr_nx(args);
	"ochar" =>	tr_ochar(args);
	"os" =>		tr_os(args);
	"pc" =>		tr_pc(args);
	"pl" =>		tr_pl(args);
	"pmll" =>	tr_pmll(args);
	"pn" =>		tr_pn(args);
	"po" =>		tr_po(args);
	"ps" =>		tr_ps(args);
	"rchar" =>	tr_rchar(args);
	"rm" =>		tr_rm(args);
	"rn" =>		tr_rn(args);
	"rr" =>		tr_rr(args);
	"rs" =>		tr_rs(args);
	"rt" =>		tr_rt(args);
	"shift" =>	tr_shift(args);
	"so" =>		tr_so(args);
	"sp" =>		tr_sp(args);
	"ss" =>		tr_ss(args);
	"ssh" =>	tr_ssh(args);
	"sv" =>		tr_sv(args);
	"sy" =>		tr_sy(args);
	"ta" =>		tr_ta(args);
	"tc" =>		tr_tc(args);
	"ti" =>		tr_ti(args);
	"ti2" =>	tr_ti2(args);
	"tkf" =>	tr_tkf(args);
	"tl" =>		tr_tl(args);
	"tm" =>		tr_tm(args);
	"tr" =>		tr_tr(args);
	"vs" =>		tr_vs(args);
	"wh" =>		tr_wh(args);
	}
}

# read the arguments of request i into a after n
cmd_args(i: int, a: array of string, n: int): int
{
	case cmds[i].args {
	A_EOL =>	return mkargs_eol(a, n);
	A_REG1 =>	return mkargs_reg1(a, n);
	A_DS =>		return mkargs_ds(a, n);
	A_NULL =>	return n;
	A_OCHAR =>	return mkargs_ochar(a, n);
	}
	return mkargs_req(a, n);
}

# execute a built-in request
tr_req(reg: int, args: array of string)
{
	req := str_dget(reg);
	if(req)
		cmd_run(req - 1, args);
}

# interpolate a macro for tr_nextreq()
tr_nextreq_exec(mac: string, arg0: string, readargs: int)
{
	a := array[NARGS + 3] of string;
	a[0] = arg0;
	n := 1;
	id := map(mac);
	req := str_dget(id);
	if(readargs){
		if(req)
			n = cmd_args(req - 1, a, n);
		else
			n = mkargs_macro(a[0:NARGS], n);
	}
	args := a[0:n];
	if(str_has(id))
		in_pushargs(str_get(id), args);
	else if(req)
		cmd_run(req - 1, args);
}

# read the next troff request; 0 if a request was executed
tr_nextreq(): int
{
	if(!tr_nl)
		return 1;
	c := cp_next();
	# transparent line indicator
	if(c == c_ec){
		c2 := cp_next();
		if(c2 == '!'){
			a := array[NARGS + 3] of string;
			a[0] = "\\!";
			cp_copymode(1);
			n := mkargs_eol(a, 1);
			cp_copymode(0);
			tr_transparent(a[0:n]);
			return 0;
		}
		cp_back(c2);
	}
	# not a request, a blank line or a line with leading spaces
	if(c < 0 || (c != c_cc && c != c_c2 &&
			(c != '\n' || tr_bm < 0) &&
			(c != ' ' || tr_sm < 0))){
		cp_back(c);
		return 1;
	}
	cp_reqbeg();
	if(c == '\n'){			# blank line macro
		mac := map_name(tr_bm);
		tr_nextreq_exec(mac, "." + mac, 0);
	}else if(c == ' '){		# leading space macro
		mac := map_name(tr_sm);
		i: int;
		for(i = 0; c == ' '; i++)
			c = cp_next();
		cp_back(c);
		nrset(R_lsn, i);
		tr_nextreq_exec(mac, "." + mac, 0);
	}else{
		mac := read_name(nr(R_cp));
		tr_nextreq_exec(mac, chr(c) + mac, 1);
	}
	return 0;
}

tr_next(): int
{
	while(tr_nl && !tr_nextreq())	# tr_nextreq() is 1 unless tr_nl
		;
	c := cp_next();
	tr_nl = c == '\n' || c < 0;
	return c;
}

tr_init()
{
	for(i := 0; i < len cmds; i++)
		str_dset(map(cmds[i].id), i + 1);
	cmap = dict_make(1024);
	chardefaults();
}
