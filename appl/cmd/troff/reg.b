#
# reg.c: number and string registers, environments
#

Env: adt {
	eregs:		array of int;	# environment-specific number registers
	tabs:		array of int;	# tab stops
	tabs_type:	array of int;	# their types: L, C, R
	fmt:		ref Fmt;	# line formatting buffer
	wb:		ref Wb;		# partial word
	tc:		string;		# tab character (.tc)
	lc:		string;		# leader character (.lc)
	hc:		string;		# hyphenation character (.hc)
	mc:		string;		# margin character (.mc)
};

nregs: array of int;		# global number registers
nregs_inc: array of int;	# their auto-increments
nregs_fmt: array of int;	# their formats
sregs: array of string;		# string registers
sregs_def: array of int;	# defined (Neatroff's non-NULL)
sregs_dat: array of int;	# the built-in request, its index in cmds plus one
envs: array of ref Env;		# environments
env: ref Env;			# the current environment
env_id: int;			# its id
eregs_idx: array of int;	# a register's index in eregs[]

eregs := array[] of {		# environment-specific number registers
	"ln", ".f", ".i", ".j", ".l",
	".L", ".nI", ".nm", ".nM", ".nn",
	".nS", ".m", ".s", ".u", ".v",
	".it", ".itn", ".mc", ".mcn",
	".ce", ".na", ".f0", ".i0", ".l0",
	".hy", ".hycost", ".hycost2", ".hycost3", ".hlm",
	".L0", ".m0", ".n0", ".s0", ".ss", ".ssh", ".sss", ".pmll", ".pmllcost",
	".ti", ".lt", ".lt0", ".v0",
	".I", ".I0", ".tI", ".td", ".cd",
	".mtp", ".mtes", ".mtek", ".mtep", ".wo",
};

nreginit()
{
	nregs = array[NREGS] of {* => 0};
	nregs_inc = array[NREGS] of {* => 0};
	nregs_fmt = array[NREGS] of {* => 0};
	sregs = array[NREGS] of string;
	sregs_def = array[NREGS] of {* => 0};
	sregs_dat = array[NREGS] of {* => 0};
	envs = array[NREGS] of ref Env;
	eregs_idx = array[NREGS] of {* => 0};
}

# the value of a number register
nr(id: int): int
{
	if(eregs_idx[id])
		return env.eregs[eregs_idx[id]];
	return nregs[id];
}

nrset(id: int, val: int)
{
	if(eregs_idx[id])
		env.eregs[eregs_idx[id]] = val;
	else
		nregs[id] = val;
}

directory(path: string): string
{
	for(i := len path - 1; i >= 0; i--)
		if(path[i] == '/'){
			if(i == 0)
				return "/";
			return path[0:i];
		}
	return ".";
}

num_tabs(): string
{
	s := "";
	for(i := 0; i < NTABS && env.tabs_type[i]; i++)
		s += sys->sprint("%du%c ", env.tabs[i], env.tabs_type[i]);
	return s;
}

# the contents of a number register
num_str(id: int): string
{
	s := map_name(id);
	if(!nregs_fmt[id])
		nregs_fmt[id] = '0';
	if(len s == 2 && s[0] == '.'){
		case s[1] {
		'b' =>
			return sys->sprint("%d", font_getbd(dev_font(nr(R_f))));
		'c' =>
			return sys->sprint("%d", in_lnum());
		'k' =>
			return sys->sprint("%d", f_hpos());
		'm' =>
			m := nr(R_m);
			return sys->sprint("#%.2x%.2x%.2x", CLR_R(m), CLR_G(m), CLR_B(m));
		't' =>
			return sys->sprint("%d", f_nexttrap());
		'z' =>
			if(f_divreg() >= 0)
				return map_name(f_divreg());
			return "";
		'F' =>
			return in_filename();
		'D' =>
			return directory(in_filename());
		'$' =>
			return sys->sprint("%d", in_nargs() - 1);
		}
	}
	if(s == ".neat")
		return "1";
	if(s == ".pend")	# the lines the text not yet set will take (not Neatroff's)
		return sys->sprint("%d", fmt_pending(env_fmt()));
	if(s == ".ev")
		return map_name(env_id);
	if(s == "$$")
		return sys->sprint("%d", sys->pctl(0, nil));
	if(s == "yr")
		return sys->sprint("%.2d", nr(id));
	if(s == ".tabs")
		return num_tabs();
	if(nregs_fmt[id]){
		(t, ok) := num_fmt(nr(id), nregs_fmt[id]);
		if(ok)
			return t;
	}
	return sys->sprint("%d", nr(id));
}

num_set(id: int, val: int)
{
	if(!nregs_fmt[id])
		nregs_fmt[id] = '0';
	nrset(id, val);
}

num_setinc(id: int, val: int)
{
	nregs_inc[id] = val;
}

num_inc(id: int, pos: int)
{
	if(pos > 0)
		nrset(id, nr(id) + nregs_inc[id]);
	else
		nrset(id, nr(id) - nregs_inc[id]);
}

num_del(id: int)
{
	nrset(id, 0);
	nregs_inc[id] = 0;
	nregs_fmt[id] = 0;
}

str_set(id: int, s: string)
{
	sregs[id] = s;
	sregs_def[id] = 1;
	sregs_dat[id] = 0;
}

# the string register, or nil if it is not defined; see str_has()
str_get(id: int): string
{
	return sregs[id];
}

str_has(id: int): int
{
	return sregs_def[id];
}

str_dget(id: int): int
{
	return sregs_dat[id];
}

str_dset(id: int, d: int)
{
	sregs_dat[id] = d;
}

str_rm(id: int)
{
	sregs[id] = nil;
	sregs_def[id] = 0;
	sregs_dat[id] = 0;
}

str_rn(src, dst: int)
{
	if(!sregs_def[src] && !sregs_dat[src])
		return;
	str_rm(dst);
	sregs[dst] = sregs[src];
	sregs_def[dst] = sregs_def[src];
	sregs_dat[dst] = sregs_dat[src];
	sregs[src] = nil;
	sregs_def[src] = 0;
	sregs_dat[src] = 0;
}

env_alloc(): ref Env
{
	e := ref Env;
	e.eregs = array[len eregs + 1] of {* => 0};
	e.tabs = array[NTABS] of {* => 0};
	e.tabs_type = array[NTABS] of {* => 0};
	e.wb = wb_new();
	e.fmt = fmt_alloc();
	e.tc = "";
	e.lc = "";
	e.hc = "";
	e.mc = "";
	return e;
}

env_set(id: int)
{
	env = envs[id];
	env_id = id;
	if(env == nil){
		envs[id] = env = env_alloc();
		nrset(R_f, 1);
		nrset(R_i, 0);
		nrset(R_I, 0);
		nrset(R_j, AD_B);
		nrset(R_l, SC_IN() * 65 / 10);
		nrset(R_L, 1);
		nrset(R_s, 10);
		nrset(R_u, 1);
		nrset(R_v, 12 * SC_PT());
		nrset(R_s0, nr(R_s));
		nrset(R_v0, nr(R_v));
		nrset(R_f0, nr(R_f));
		nrset(R_l0, nr(R_l));
		nrset(R_L0, nr(R_L));
		nrset(R_na, 0);
		nrset(R_lt, SC_IN() * 65 / 10);
		nrset(R_hy, 1);
		nrset(R_ss, 12);
		nrset(R_sss, 12);
		nrset(R_nM, 1);
		nrset(R_nS, 1);
		env.hc = "\\%";
		env.lc = ".";
		for(i := 0; i < NTABS; i++){
			env.tabs[i] = i * SC_IN() / 2;
			env.tabs_type[i] = 'L';
		}
	}
}

init_time()
{
	if(daytime == nil)
		return;
	tm := daytime->local(daytime->now());
	num_set(map("dw"), tm.wday + 1);
	num_set(map("dy"), tm.mday);
	num_set(map("mo"), tm.mon + 1);
	num_set(map("yr"), tm.year % 100);
	num_set(map(".yr"), 1900 + tm.year);
}

init_globals()
{
	nrset(R_o, SC_IN());
	nrset(R_o0, nr(R_o));
	nrset(R_p, SC_IN() * 11);
	nrset(R_lg, 1);
	nrset(R_kn, 1);
	num_set(map(".H"), 1);
	num_set(map(".V"), 1);
}

env_init()
{
	init_time();
	init_globals();
	for(i := 0; i < len eregs; i++)
		eregs_idx[map(eregs[i])] = i + 1;
	env_set(map("0"));
}

oenv := array[NPREV] of {* => 0};	# environment stack
nenv := 0;

tr_ev(args: array of string)
{
	id := -1;
	if(len args > 1)
		id = map(args[1]);
	else if(nenv)
		id = oenv[--nenv];
	if(id < 0)
		return;
	if(len args > 1 && env != nil && nenv < NPREV)
		oenv[nenv++] = env_id;
	env_set(id);
}

tr_evc(args: array of string)
{
	id := -1;
	if(len args > 1)
		id = map(args[1]);
	if(id < 0 || envs[id] == nil)
		return;
	src := envs[id];
	e := env_alloc();
	e.eregs[0:] = src.eregs;
	e.tabs[0:] = src.tabs;
	e.tabs_type[0:] = src.tabs_type;
	e.tc = src.tc;
	e.lc = src.lc;
	e.hc = src.hc;
	e.mc = src.mc;
	envs[env_id] = env = e;
}

env_fmt(): ref Fmt
{
	return env.fmt;
}

env_wb(): ref Wb
{
	return env.wb;
}

env_hc(): string
{
	return env.hc;
}

env_mc(): string
{
	return env.mc;
}

env_tc(): string
{
	return env.tc;
}

env_lc(): string
{
	return env.lc;
}

# saving and restoring registers around diverted lines
Odiv: adt {
	f, s, m, f0, s0, m0, cd: int;
};

odivs := array[NPREV] of Odiv;
nodivs := 0;

odiv_beg()
{
	# diverted lines output inside traps nest as deep as the traps; C's
	# stack of NPREV overflows into what follows it
	if(nodivs >= len odivs){
		o := array[2 * len odivs] of Odiv;
		o[0:] = odivs;
		odivs = o;
	}
	odivs[nodivs++] = Odiv(nr(R_f), nr(R_s), nr(R_m),
		nr(R_f0), nr(R_s0), nr(R_m0), nr(R_cd));
}

odiv_end()
{
	o := odivs[--nodivs];
	nrset(R_f, o.f);
	nrset(R_s, o.s);
	nrset(R_m, o.m);
	nrset(R_f0, o.f0);
	nrset(R_s0, o.s0);
	nrset(R_m0, o.m0);
	nrset(R_cd, o.cd);
}

tr_ta(args: array of string)
{
	for(i := 0; i < NTABS; i++){
		if(i + 1 < NARGS && i + 1 < len args){
			a := args[i + 1];
			prev := 0;
			if(i > 0)
				prev = env.tabs[i - 1];
			env.tabs[i] = eval_re(a, prev, 'm');
			c := 0;
			if(a != nil)
				c = a[len a - 1];
			if(hasc("LRC", c))
				env.tabs_type[i] = c;
			else
				env.tabs_type[i] = 'L';
		}else{
			env.tabs[i] = 0;
			env.tabs_type[i] = 0;
		}
	}
}

tab_idx(pos: int): int
{
	for(i := 0; i < NTABS; i++)
		if(env.tabs[i] > pos)
			return i;
	return -1;
}

tab_next(pos: int): int
{
	i := tab_idx(pos);
	if(i >= 0)
		return env.tabs[i];
	return pos;
}

tab_type(pos: int): int
{
	i := tab_idx(pos);
	if(i >= 0 && env.tabs_type[i])
		return env.tabs_type[i];
	return 'L';
}

# number register formats (.af)
NF_LSH:	con 8;		# number format length shift
NF_FMT:	con 16r00ff;	# number format mask

num_getfmt(id: int): string
{
	fmt := nregs_fmt[id] & NF_FMT;
	s := "";
	if(fmt == '0' || fmt == 'x' || fmt == 'X'){
		i := nregs_fmt[id] >> NF_LSH;
		while(i-- > 1)
			s += "0";
		s[len s] = fmt;
	}else if(nregs_fmt[id])
		s[len s] = fmt;
	return s;
}

num_setfmt(id: int, s: string)
{
	i := 0;
	if(s != nil && strchr("iIaA", s[0]) >= 0)
		nregs_fmt[id] = s[0];
	else{
		while(isdigit(at(s, i)))
			i++;
		if(at(s, i) == 'x' || at(s, i) == 'X')
			nregs_fmt[id] = s[i] | ((i + 1) << NF_LSH);
		else
			nregs_fmt[id] = '0' | (i << NF_LSH);
	}
}

# roman numerals, least significant digit first
nf_roman(n: int, I, V: string): string
{
	if(!n)
		return "";
	s := "";
	if(n % 5 == 4){
		if(n % 10 == 9)
			s[len s] = I[1];
		else
			s[len s] = V[0];
		s[len s] = I[0];
	}else{
		for(i := 0; i < n % 5; i++)
			s[len s] = I[0];
		if(n % 10 >= 5)
			s[len s] = V[0];
	}
	if(n < 10)
		return s;
	# V is a letter shorter than I: below 40000 it runs out with n
	return s + nf_roman(n / 10, I[1:], V[1:]);
}

nf_alpha(n: int, a: int): string
{
	s := "";
	while(n){
		s[len s] = a + ((n - 1) % 26);
		n = (n - 1) / 26;
	}
	return s;
}

reverse(s: string): string
{
	r := "";
	for(i := len s - 1; i >= 0; i--)
		r[len r] = s[i];
	return r;
}

# the number n in format fmt, and whether fmt is one
num_fmt(n: int, fmt: int): (string, int)
{
	typ := fmt & NF_FMT;
	sign := "";
	if(n < 0){
		n = -n;
		sign = "-";
	}
	if((typ == 'i' || typ == 'I') && n > 0 && n < 40000){
		if(typ == 'i')
			return (sign + reverse(nf_roman(n, "ixcmz", "vldw")), 1);
		return (sign + reverse(nf_roman(n, "IXCMZ", "VLDW")), 1);
	}
	if((typ == 'a' || typ == 'A') && n > 0)
		return (sign + reverse(nf_alpha(n, typ)), 1);
	if(typ == '0' || typ == 'x' || typ == 'X'){
		w := fmt >> NF_LSH;
		case typ {
		'0' =>
			return (sign + zeropad(string n, w), 1);
		'x' =>
			return (sign + zeropad(sys->sprint("%x", n), w), 1);
		'X' =>
			return (sign + zeropad(sys->sprint("%X", n), w), 1);
		}
	}
	return (nil, 0);
}

zeropad(s: string, w: int): string
{
	while(len s < w)
		s = "0" + s;
	return s;
}
