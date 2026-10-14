#
# eval.c: integer expressions
#

SCHAR:	con "icpPvmnu";	# scale indicators

defunit := 0;		# default scale indicator
abspos := 0;		# absolute position like |1i
es: string;		# the expression
ei: int;		# the position in es

readunit(c: int, n: big): big
{
	case c {
	'i' =>
		return n * big SC_IN();
	'c' =>
		return n * big SC_IN() * big 50 / big 127;
	'p' =>
		return n * big SC_IN() / big 72;
	'P' =>
		return n * big SC_IN() / big 6;
	'v' =>
		return n * big nr(R_v);
	'm' =>
		return n * big nr(R_s) * big SC_IN() / big 72;
	'n' =>
		return n * big nr(R_s) * big SC_IN() / big 144;
	'u' =>
		return n;
	}
	return n;
}

evalnum(): big
{
	n := big 0;		# the result
	mag := big 0;		# n should be divided by mag
	while(isdigit(at(es, ei)) || at(es, ei) == '.'){
		if(mag == big MAXFRAC || (mag > big 0 && n > big 200000000)){
			ei++;
			continue;
		}
		if(es[ei] == '.'){
			mag = big 1;
			ei++;
			continue;
		}
		mag *= big 10;
		n = n * big 10 + big (es[ei++] - '0');
	}
	c := at(es, ei);
	if(c != 0 && strchr(SCHAR, c) >= 0)
		ei++;
	else
		c = defunit;
	n = readunit(c, n);
	if(mag > big 0)
		return n / mag;
	return n;
}

evaljmp(c: int): int
{
	if(at(es, ei) == c){
		ei++;
		return 0;
	}
	return 1;
}

evalisnum(): int
{
	return at(es, ei) == '.' || isdigit(at(es, ei));
}

evalatom(): big
{
	if(evalisnum())
		return evalnum();
	if(!evaljmp('-'))
		return -evalatom();
	if(!evaljmp('+'))
		return evalatom();
	if(!evaljmp('|'))
		return big abspos + evalatom();
	if(!evaljmp('(')){
		ret := evalexpr();
		evaljmp(')');
		return ret;
	}
	return big 0;
}

nonzero(n: int): int
{
	if(n == 0)
		errdie("troff: divide by zero\n");
	return n;
}

evalexpr(): big
{
	ret := evalatom();
	while(ei < len es){
		if(!evaljmp('+'))
			ret += evalatom();
		else if(!evaljmp('-'))
			ret -= evalatom();
		else if(!evaljmp('/'))
			ret /= big nonzero(int evalatom());
		else if(!evaljmp('*'))
			ret *= evalatom();
		else if(!evaljmp('%'))
			ret %= big nonzero(int evalatom());
		else if(!evaljmp('<')){
			if(!evaljmp('='))
				ret = big (ret <= evalatom());
			else
				ret = big (ret < evalatom());
		}else if(!evaljmp('>')){
			if(!evaljmp('='))
				ret = big (ret >= evalatom());
			else
				ret = big (ret > evalatom());
		}else if(eq2()){
			ret = big (ret == evalatom());
		}else if(!evaljmp('&')){
			# C's &&: the right operand is not read unless needed
			if(ret > big 0)
				ret = big (evalatom() > big 0);
			else
				ret = big 0;
		}else if(!evaljmp(':')){
			if(ret > big 0)
				ret = big 1;
			else
				ret = big (evalatom() > big 0);
		}else
			break;
	}
	return ret;
}

# one or two equal signs
eq2(): int
{
	a := !evaljmp('=');
	b := !evaljmp('=');
	return a + b;
}

# evaluate s from i; return the value and where it stopped
eval_up(s: string, i: int, unit: int): (int, int)
{
	defunit = unit;
	if(unit == 'v')
		abspos = -nr(R_d) - wb_vpos(env_wb());
	if(unit == 'm')
		abspos = nr(R_lb) - f_hpos();
	oes := es;
	oei := ei;
	es = s;
	ei = i;
	n := int evalexpr();
	i = ei;
	es = oes;
	ei = oei;
	return (n, i);
}

# evaluate s relative to its previous value
eval_re(s: string, orig: int, unit: int): int
{
	rel := 0;		# n should be added to orig
	i := 0;
	if(at(s, 0) == '+' || at(s, 0) == '-'){
		if(s[0] == '+')
			rel = 1;
		else
			rel = -1;
		i++;
	}
	(n, nil) := eval_up(s, i, unit);
	if(rel > 0)
		return orig + n;
	if(rel < 0)
		return orig - n;
	return n;
}

eval(s: string, unit: int): int
{
	(n, nil) := eval_up(s, 0, unit);
	return n;
}
