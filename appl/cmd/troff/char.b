#
# char.c: characters, escape sequences and string streams
#

# read a character from src; "" at the end
utf8next(src: int): string
{
	c := next(src);
	if(c < 0)
		return "";
	return chr(c);
}

# read the quoted argument of an escape sequence (ESC_Q)
quotednext(src: int): string
{
	(nil, delim) := charnext(src);
	sb := "";
	for(;;){
		(t, cs) := charnext_delim(src, delim);
		if(t < 0)
			break;
		sb += charnext_str(cs);
	}
	return sb;
}

# read the unquoted argument of an escape sequence (ESC_P)
unquotednext(cmd: int, src: int): string
{
	c := next(src);
	sb := "";
	if(cmd == 's' && (c == '-' || c == '+')){
		cmd = c;
		sb[len sb] = c;
		c = next(src);
	}
	if(c == '('){
		c = next(src);
		if(c >= 0)
			sb[len sb] = c;
		c = next(src);
		if(c >= 0)
			sb[len sb] = c;
	}else if(!nr(R_cp) && c == '['){
		c = next(src);
		while(c > 0 && c != '\n' && c != ']'){
			sb[len sb] = c;
			c = next(src);
		}
	}else{
		if(c >= 0)
			sb[len sb] = c;
		if(nr(R_cp) && cmd == 's' && c >= '1' && c <= '3'){
			c = next(src);
			if(isdigit(c))
				sb[len sb] = c;
			else
				back(src, c);
		}
	}
	return sb;
}

#
# read the next character or escape sequence (x, \x, \(xy, \[xyz], \C'xyz')
#
# character	returned	the string
# x		0		x
# \4x		c_ni		\4x
# \\x		'\\'		\\x
# \\(xy		'('		xy
# \\[xyz]	'['		xyz
# \\C'xyz'	'C'		xyz
#
charnext(src: int): (int, string)
{
	c := next(src);
	if(c < 0)
		return (-1, "");
	if(c == c_ni){
		return (c_ni, chr(c) + utf8next(src));
	}
	if(c == c_ec){
		c1 := next(src);
		if(c1 == '('){
			s := utf8next(src);
			s += utf8next(src);
			return ('(', s);
		}else if(!nr(R_cp) && c1 == '['){
			s := "";
			l := 0;
			n := next(src);
			while(n >= 0 && n != '\n' && n != ']' && l < GNLEN - 1){
				s[len s] = n;
				l += utf8nbytes(n);
				n = next(src);
			}
			return ('[', s);
		}else if(c1 == 'C'){
			return ('C', quotednext(src));
		}
		if(c1 < 0)
			return ('\\', chr(c));
		return ('\\', chr(c) + chr(c1));
	}
	return (0, chr(c));
}

# like charnext(), but return -1 if delim was read
charnext_delim(src: int, delim: string): (int, string)
{
	(t, c) := charnext(src);
	if(c == delim)
		return (-1, c);
	return (t, c);
}

# convert back a character read with charnext() (xy is \(xy)
charnext_str(c: string): string
{
	if(len c <= 1 || c[0] == c_ec || c[0] == c_ni)
		return c;
	if(len c == 2 && c[0] < 16r80 && c[1] < 16r80)
		return chr(c_ec) + "(" + c;
	return chr(c_ec) + "C'" + c + "'";
}

# like charnext(), from s at i; returns where it stopped
charread(s: string, i: int): (int, string, int)
{
	sstr_push(s, i);
	(t, c) := charnext(S_SSTR);
	i = sstr_pop();
	return (t, c, i);
}

charread_delim(s: string, i: int, delim: string): (int, string, int)
{
	sstr_push(s, i);
	(t, c) := charnext_delim(S_SSTR, delim);
	i = sstr_pop();
	return (t, c, i);
}

# a quoted argument in a Neatroff string
quotedread(s: string, i: int): (string, int)
{
	q := at(s, i++);
	if(i >= len s)
		return ("", i);
	j := i;
	while(j < len s && s[j] != q)
		j++;
	d := s[i:j];
	if(j < len s && s[j] == q)
		j++;
	return (d, j);
}

# an unquoted argument in a Neatroff string
unquotedread(s: string, i: int): (string, int)
{
	d := "";
	if(at(s, i) == '('){
		i++;
		j := i + 2;
		if(j > len s)
			j = len s;
		if(i < j)
			d = s[i:j];
		i = j;
	}else if(!nr(R_cp) && at(s, i) == '['){
		i++;
		j := i;
		while(j < len s && s[j] != ']')
			j++;
		if(i < j)
			d = s[i:j];
		i = j;
		if(i < len s && s[i] == ']')
			i++;
	}else if(i < len s)
		d = chr(s[i++]);
	return (d, i);
}

#
# read a glyph or an escape sequence from s at i
#
# Either an output request (one of those wb.b writes), returning
# its name and argument, or a glyph name, returning 0 and the name;
# -1 at the end of s.
#
esc_arg, esc_p, esc_q, esc_ren: array of byte;

escread(s: string, i: int): (int, string, int)
{
	if(i >= len s)
		return (-1, nil, i);
	c0 := s[i++];
	if(c0 == c_ec){
		c := at(s, i);
		if(i < len s)
			i++;
		if(c == '('){
			j := i + 2;
			if(j > len s)
				j = len s;
			r := "";
			if(i < j)
				r = s[i:j];
			return (0, r, j);
		}else if(!nr(R_cp) && c == '['){
			j := i;
			while(j < len s && s[j] != ']')
				j++;
			r := "";
			if(i < j)
				r = s[i:j];
			if(j < len s && s[j] == ']')
				j++;
			return (0, r, j);
		}else if(inset(esc_arg, c)){
			d := "";
			if(inset(esc_p, c))
				(d, i) = unquotedread(s, i);
			if(inset(esc_q, c))
				(d, i) = quotedread(s, i);
			if(c == 'C')
				return (0, d, i);
			return (c, d, i);
		}
		return (0, s[i - 2:i], i);
	}else if(c0 == c_ni && i < len s){
		i++;
		return (0, s[i - 2:i], i);
	}
	return (0, chr(c0), i);
}

#
# string streams: next()/back() for strings
#
sstr_bufs := array[NSSTR] of string;
sstr_poss := array[NSSTR] of {* => 0};
sstr_n := 0;
sstr_s: string;
sstr_i := 0;

sstr_push(s: string, i: int)
{
	sstr_bufs[sstr_n] = sstr_s;
	sstr_poss[sstr_n] = sstr_i;
	sstr_n++;
	sstr_s = s;
	sstr_i = i;
}

# pop the stream, returning where it was left
sstr_pop(): int
{
	i := sstr_i;
	sstr_n--;
	sstr_s = sstr_bufs[sstr_n];
	sstr_i = sstr_poss[sstr_n];
	return i;
}

sstr_next(): int
{
	if(sstr_i < len sstr_s)
		return sstr_s[sstr_i++];
	return -1;
}

sstr_back(nil: int)
{
	if(sstr_i > 0)
		sstr_i--;
}
