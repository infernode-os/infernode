#
# cp.c: the copy-mode layer
#

cp_blkdep := 0;		# input block depth (text in \{ and \})
cp_cpmode := 0;		# do not interpret \w and \E
cp_reqdep := 0;		# the block depth of the current request line

# the next character in s, from src
next(src: int): int
{
	case src {
	S_CP =>
		return cp_next();
	S_CPNONI =>
		return cp_noninext();
	S_SSTR =>
		return sstr_next();
	* =>
		return ren_next();
	}
}

back(src: int, c: int)
{
	case src {
	S_CP or S_CPNONI =>
		in_back(c);
	S_SSTR =>
		sstr_back(c);
	* =>
		ren_back(c);
	}
}

cp_back(c: int)
{
	in_back(c);
}

# like cp_next(), but remove c_ni characters
cp_noninext(): int
{
	c := cp_next();
	while(c == c_ni)
		c = cp_next();
	return c;
}

# read the name after \n, \*, \$ or \g; and whether a space ended \*[...]
cparg(): (string, int)
{
	c := cp_noninext();
	d := "";
	if(c == '('){
		d += utf8next(S_CPNONI);
		d += utf8next(S_CPNONI);
	}else if(!nr(R_cp) && c == '['){
		c = cp_noninext();
		while(c >= 0 && c != ']' && c != ' '){
			if(len d + 1 < NMLEN)
				d[len d] = c;
			c = cp_noninext();
		}
		return (d, c == ' ');
	}else{
		cp_back(c);
		d = utf8next(S_CPNONI);
	}
	return (d, 0);
}

regid(): int
{
	(name, nil) := cparg();
	return map(name);
}

# interpolate \n(xy
cp_num()
{
	c := cp_noninext();
	if(c != '-' && c != '+')
		cp_back(c);
	id := regid();
	if(c == '-' || c == '+')
		num_inc(id, c == '+');
	in_push(num_str(id), nil);
}

# interpolate \*(xy
cp_str()
{
	(reg, sp) := cparg();
	args: array of string;
	if(sp){
		args = tr_args(']', S_CPNONI);
		cp_noninext();
	}
	a := array[len args + 1] of string;
	a[0] = reg;
	a[1:] = args;
	if(str_has(map(reg)))
		in_pushargs(str_get(map(reg)), a);
	else if(!nr(R_cp))
		tr_req(map(reg), a);
}

# interpolate \g(xy
cp_numfmt()
{
	in_push(num_getfmt(regid()), nil);
}

# interpolate \$*, \$@ and \$^
cp_args(quote: int, escape: int)
{
	sb := "";
	for(i := 1; i < in_nargs(); i++){
		if(i > 1)
			sb += " ";
		if(quote)
			sb += "\"";
		s := in_arg(i);
		for(j := 0; j < len s; j++){
			if(escape && s[j] == '"')
				sb += "\"";
			sb[len sb] = s[j];
		}
		if(quote)
			sb += "\"";
	}
	in_push(sb, nil);
}

# interpolate \$1
cp_arg()
{
	(argname, nil) := cparg();
	if(argname == "@"){
		cp_args(1, 0);
		return;
	}
	if(argname == "*"){
		cp_args(0, 0);
		return;
	}
	if(argname == "^"){
		cp_args(1, 1);
		return;
	}
	argnum := atoi(argname);
	if(argnum >= 0 && argnum < NARGS)
		in_push(in_arg(argnum), nil);
}

# interpolate \w'xyz'
cp_width()
{
	in_push(sys->sprint("%d", ren_wid(S_CP)), nil);
}

# define a register as \R'xyz expr'
cp_numdef()
{
	arg := quotednext(S_CPNONI);
	i := strchr(arg, ' ');
	if(i < 0)
		return;
	id := map(arg[0:i]);
	num_set(id, eval_re(arg[i+1:], nr(id), 'u'));
}

# conditional interpolation as \?'cond@expr1@expr2@'
cp_cond()
{
	arg := quotednext(S_CPNONI);
	(n, i) := eval_up(arg, 0, 0);
	t: int;
	delim: string;
	(t, delim, i) = charread(arg, i);
	if(t < 0)
		return;
	if(delim == "\\&"){
		(t, delim, i) = charread(arg, i);
		if(t < 0)
			return;
	}
	cs: string;
	s1 := i;
	r := i;
	for(;;){
		(t, cs, i) = charread_delim(arg, i, delim);
		if(t < 0)
			break;
		r = i;
	}
	e1 := r;
	s2 := i;
	r = i;
	for(;;){
		(t, cs, i) = charread_delim(arg, i, delim);
		if(t < 0)
			break;
		r = i;
	}
	e2 := r;
	if(n > 0)
		in_push(arg[s1:e1], nil);
	else
		in_push(arg[s2:e2], nil);
}

cp_raw(): int
{
	if(buf != nil && buf.un && buf.unbuf[buf.un - 1] >= 0)	# in_top() >= 0
		return in_next();
	c: int;
	do
		c = in_next();
	while(c == c_ni);
	if(c == c_ec){
		do
			c = in_next();
		while(c == c_ni);
		if(c == '\n')
			return cp_raw();
		if(c == '.')
			return '.';
		if(c == '\\'){
			in_back('\\');
			return c_ni;
		}
		if(c == 't'){
			in_back('\t');
			return c_ni;
		}
		if(c == 'a'){
			in_back(1);
			return c_ni;
		}
		# replace \{ and \} with a space if not in copy mode
		if(c == '}' && !cp_cpmode){
			cp_blkdep--;
			return ' ';
		}
		if(c == '{' && !cp_cpmode){
			cp_blkdep++;
			return ' ';
		}
		in_back(c);
		return c_ec;
	}
	return c;
}

cp_next(): int
{
	if(buf != nil && buf.un && buf.unbuf[buf.un - 1] >= 0)	# in_top() >= 0
		return in_next();
	c := cp_raw();
	if(c == c_ec){
		c = cp_raw();
		if(c == 'E' && !cp_cpmode)
			c = cp_next();
		if(c == '"'){
			while(c >= 0 && c != '\n')
				c = cp_raw();
		}else if(c == '#'){
			while(c >= 0 && c != '\n')
				c = cp_raw();
			if(c >= 0)
				c = cp_next();
		}else if(c == 'w' && !cp_cpmode){
			cp_width();
			c = cp_next();
		}else if(c == 'n'){
			cp_num();
			c = cp_next();
		}else if(c == '*'){
			cp_str();
			c = cp_next();
		}else if(c == 'g'){
			cp_numfmt();
			c = cp_next();
		}else if(c == '$'){
			cp_arg();
			c = cp_next();
		}else if(c == '?'){
			cp_cond();
			c = cp_next();
		}else if(c == 'R' && !cp_cpmode){
			cp_numdef();
			c = cp_next();
		}else{
			cp_back(c);
			c = c_ec;
		}
	}
	return c;
}

cp_blk(skip: int)
{
	if(skip){
		c := cp_raw();
		while(c >= 0 && (c != '\n' || cp_blkdep > cp_reqdep))
			c = cp_raw();
	}else{
		c := cp_next();
		while(c == ' ')
			c = cp_next();
		# push back if the space is not inserted due to \{ and \}
		if(c != ' ')
			cp_back(c);
	}
}

cp_copymode(mode: int)
{
	cp_cpmode = mode;
}

# the beginning of a request; save the current cp_blkdep
cp_reqbeg()
{
	cp_reqdep = cp_blkdep;
}
