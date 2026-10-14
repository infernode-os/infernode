#
# tok.c: the preprocessor and tokenizer
#

T_SOFTSEP: con "^~{}(),\"\n\t =:|.+-*/\\,()[]<>!";
ESAVE: con "\\E*[.eqnbeg]\\R'" + EQNFN + "0 \\En(.f'\\R'" + EQNSZ + "0 \\En(.s'";
ELOAD: con "\\f[\\En[" + EQNFN + "0]]\\s[\\En[" + EQNSZ + "0]]\\E*[.eqnend]";

kwds := array[] of {
	"fwd", "down", "back", "up",
	"bold", "italic", "roman", "font", "fat", "size", "type",
	"bar", "dot", "dotdot", "dyad", "hat", "under", "vec", "tilde",
	"sub", "sup", "from", "to", "vcenter", "ifdisplay",
	"left", "right", "over", "sqrt",
	"pile", "lpile", "cpile", "rpile", "above",
	"matrix", "col", "ccol", "lcol", "rcol",
	"delim", "define",
	"gfont", "grfont", "gbfont", "gsize", "set", "chartype",
	"mark", "lineup", "bracketsizes", "bracketpieces", "breakcost",
};

tok_eqen := 0;		# within .EQ and .EN
tok_line := 0;		# within an inline equation
tok_part := 0;		# a line with inline equations, in part
tok := "";		# the token
tok_prev := "";		# the one before
tok_curtype := 0;
tok_count := 0;		# the tokens read
tok_cursep := 0;	# its character is a separator
tok_prevsep := 0;	# the one before was
eqn_beg := 0;		# inline equations' delimiters
eqn_end := 0;

# whether the request .ab is next
tok_req(a, b: int): int
{
	eqln: list of int;
	ret := 0;
	c := src_next();
	eqln = c :: eqln;
	if(c == '.'){
		c = src_next();
		eqln = c :: eqln;
		n := 2;
		while(c == ' ' && n < LNLEN - 4){
			c = src_next();
			eqln = c :: eqln;
			n++;
		}
		if(c == a){
			c = src_next();
			eqln = c :: eqln;
			if(c == b)
				ret = 1;
		}
	}
	for(; eqln != nil; eqln = tl eqln)
		src_back(hd eqln);
	return ret;
}

tok_en(): int
{
	return tok_req('E', 'N');
}

# whether the line begins .EQ
tok_eq(s: string): int
{
	if(s == nil || s[0] != '.')
		return 0;
	i := 1;
	while(i < len s && isspace(s[i]))
		i++;
	return i + 1 < len s && s[i] == 'E' && s[i + 1] == 'Q';
}

# an lf request
tok_lf(s: string): int
{
	if(s == nil || s[0] != '.')
		return 0;
	i := 1;
	while(i < len s && isspace(s[i]))
		i++;
	if(i + 1 >= len s || s[i] != 'l' || s[i + 1] != 'f')
		return 0;
	i += 2;
	while(i < len s && isspace(s[i]))
		i++;
	if(i < len s && isdigit(s[i]))
		src_lineset(atoi(s[i:]));
	return 1;
}

tok_next(): int
{
	if(!tok_eqen && !tok_line)
		return 0;
	c := src_next();
	if(tok_eqen && c == '\n' && tok_en())
		tok_eqen = 0;
	if(tok_line && (src_top() && c == eqn_end)){
		tok_line = 0;
		return 0;
	}
	return c;
}

tok_back(c: int)
{
	if(tok_eqen || tok_line)
		src_back(c);
}

# a character, an escape whole: \x, \(xy, \[name]
readchar(): string
{
	c := src_next();
	if(c == '\\'){
		d := "\\";
		c = src_next();
		d[1] = c & 16rff;
		if(c == '('){
			d[2] = src_next() & 16rff;
			d[3] = src_next() & 16rff;
			return d;
		}
		if(c == '['){
			while(c > 0 && c != ']'){
				c = src_next();
				d[len d] = c & 16rff;
			}
			return d;
		}
		return d;
	}
	if(c > 0){
		d := "";
		d[0] = c;
		return d;
	}
	return "";
}

# the next word; if opstop, to an opening parenthesis
tok_preview(opstop: int): string
{
	c := src_next();
	s := "";
	if(c > 0 && def_chopped(c)){
		src_back(c);
		s = readchar();
	}else{
		while(c > 0 && (!def_chopped(c) && (!opstop || c != '(')) &&
				(!tok_line || (!src_top() || c != eqn_end))){
			src_back(c);
			s += readchar();
			c = src_next();
		}
		src_back(c);
	}
	# C's string ends at a NUL in it
	for(i := 0; i < len s; i++)
		if(s[i] == 0)
			return s[0:i];
	return s;
}

tok_unpreview(s: string)
{
	for(n := len s; n > 0; )
		src_back(s[--n]);
}

# a keyword; zero if read
tok_keyword(): int
{
	tok = tok_preview(0);
	for(i := 0; i < len kwds; i++)
		if(kwds[i] == tok)
			return 0;
	tok_unpreview(tok);
	return 1;
}

# a macro call's argument; zero if it ended with ,
tok_readarg(): (string, int)
{
	s := "";
	c := src_next();
	pdepth := 0;
	quotes := 0;
	while(c > 0 && (pdepth || quotes || (c != ',' && c != ')'))){
		s[len s] = c;
		if(!quotes && c == ')')
			pdepth++;
		if(!quotes && c == '(')
			pdepth--;
		if(c == '"')
			quotes = 1 - quotes;
		if(c == '\\'){
			c = src_next();
			s[len s] = c & 16rff;
			if(c == '*' || c == 'n'){
				c = src_next();
				s[len s] = c & 16rff;
			}
			if(c == '('){
				c = src_next();
				s[len s] = c & 16rff;
				c = src_next();
				s[len s] = c & 16rff;
			}else if(c == '['){
				while(c > 0 && c != ']'){
					c = src_next();
					s[len s] = c & 16rff;
				}
			}
		}
		c = src_next();
	}
	return (cstr(s), c != ',');
}

# s to a NUL in it, as C reads it
cstr(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == 0)
			return s[0:i];
	return s;
}

# expand a macro; zero if expanded
tok_expand(): int
{
	args := array[10] of string;
	n := 0;
	tok = tok_preview(1);
	if(src_macro(tok)){
		c := src_next();
		src_back(c);
		if(c == '('){	# its arguments
			src_next();
			while(n <= 9){
				(a, e) := tok_readarg();
				args[n++] = a;
				if(e)
					break;
			}
		}
		# an argument given, if empty, is not nil
		for(i := 0; i < n; i++)
			if(args[i] == nil)
				args[i] = "";
		src_expand(tok, args);
		return 0;
	}
	tok_unpreview(tok);
	return 1;
}

# read to .EQ or an inline equation's delimiter
tok_eqn(): int
{
	tok_cursep = 1;
	ln := "";
	while((c := src_next()) > 0){
		if(c == eqn_beg){
			printf(".eo\n");
			if(tok_part)
				printf(".as " + EQNS + " \"" + cstr(ln) + "\n");
			else
				printf(".ds " + EQNS + " \"" + cstr(ln) + "\n");
			printf(".ec\n");
			tok_part = 1;
			tok_line = 1;
			return 0;
		}
		ln[len ln] = c;
		if(c == '\n' && !tok_part){
			printf(cstr(ln));
			tok_lf(cstr(ln));
			if(tok_eq(cstr(ln)) && !tok_en()){
				tok_eqen = 1;
				return 0;
			}
		}
		if(c == '\n' && tok_part){
			printf(".lf " + string src_lineget() + "\n");
			printf("\\*" + escarg(EQNS) + cstr(ln));
			tok_part = 0;
		}
		if(c == '\n')
			ln = "";
	}
	return 1;
}

# an equation's output
tok_eqnout(s: string)
{
	if(!tok_part){
		printf(".ds " + EQNS + " \"" + ESAVE + s + ELOAD + "\n");
		printf(".lf " + string (src_lineget() - 1) + "\n");
		printf("\\&\\*" + escarg(EQNS) + "\n");
	}else
		printf(".as " + EQNS + " \"" + ESAVE + s + ELOAD + "\n");
}

# the bytes in a UTF-8 character, from its first
utf8len(c: int): int
{
	if(~c & 16r80)
		return c > 0;
	if(~c & 16r40)
		return 1;
	if(~c & 16r20)
		return 2;
	if(~c & 16r10)
		return 3;
	if(~c & 16r08)
		return 4;
	return 1;
}

char_type(s: string): int
{
	c := 0;
	if(s != nil)
		c = s[0];
	if(isdigit(c))
		return T_NUMBER;
	if(c == '"')
		return T_STRING;
	if((t := def_type(s)) >= 0)
		return t;
	if(c == '~' || c == '^')
		return T_GAP;
	if(ispunct(c) && (c != '\\' || len s < 2))
		return T_ORD;
	return T_LETTER;
}

# the next token; non-zero at the end
tok_read(): int
{
	tok_count++;
	e := LNLEN - 2;
	tok = "";
	c := tok_next();
	if(c <= 0)
		return 1;
	tok_prevsep = tok_cursep;
	tok_cursep = def_chopped(c);
	if(tok_cursep)
		tok_prevsep = 1;
	if(c == ' ' || c == '\n'){
		while(c > 0 && (c == ' ' || c == '\n'))
			c = tok_next();
		tok_back(c);
		tok = " ";
		tok_curtype = T_SPACE;
		return 0;
	}
	if(c == '\t'){
		tok = "\t";
		tok_curtype = T_TAB;
		return 0;
	}
	if(tok_prevsep){
		if(c == '$'){
			c2 := tok_next();
			if(c2 >= '1' && c2 <= '9' && !src_arg(c2 - '0')){
				tok_cursep = 1;
				return tok_read();
			}
			tok_back(c2);
		}
		tok_back(c);
		if(!tok_keyword()){
			tok_curtype = T_KEYWORD;
			tok_cursep = 1;
			return 0;
		}
		if(!tok_expand()){
			tok_cursep = 1;
			return tok_read();
		}
		c = tok_next();
	}
	s := "";
	if(strchr(T_SOFTSEP, c)){
		s[len s] = c & 16rff;
		if(c == '\\'){
			c = tok_next();
			if(c == '('){
				s[len s] = c;
				s[len s] = tok_next() & 16rff;
				s[len s] = tok_next() & 16rff;
			}else if(c == '['){
				# to the end of the input too, where Neateqn loops for ever
				while(c > 0 && c != ']'){
					if(len s < e)
						s[len s] = c & 16rff;
					c = tok_next();
				}
				s[len s] = ']';
			}
		}else if(c == '"'){
			c = tok_next();
			while(c > 0 && c != '"'){
				if(c == '\\'){
					c2 := tok_next();
					if(c2 == '"')
						c = '"';
					else
						tok_back(c2);
				}
				if(len s < e)
					s[len s] = c & 16rff;
				c = tok_next();
			}
			s[len s] = '"';
		}else{
			# two-character operators
			c2 := tok_next();
			case (c << 8) | c2 {
			('<' << 8) | '=' or ('>' << 8) | '=' or ('=' << 8) | '=' or
			('!' << 8) | '=' or ('>' << 8) | '>' or ('<' << 8) | '<' or
			(':' << 8) | '=' or ('-' << 8) | '>' or ('<' << 8) | '-' or
			('-' << 8) | '+' =>
				s[len s] = c2;
			* =>
				tok_back(c2);
			}
		}
		tok = cstr(s);
		tok_curtype = char_type(tok);
		return 0;
	}
	s[len s] = c & 16rff;
	i := utf8len(c);
	while(--i > 0 && len s < e)
		s[len s] = tok_next() & 16rff;
	tok = cstr(s);
	tok_curtype = char_type(tok);
	return 0;
}

tok_get(): string
{
	if(tok == "")
		return nil;
	return tok;
}

tok_type(): int
{
	if(tok == "")
		return 0;
	return tok_curtype;
}

# whether the token chops the equation
tok_chops(soft: int): int
{
	if(tok_get() == nil || tok_curtype == T_KEYWORD)
		return 1;
	if(soft)
		return strchr(T_SOFTSEP, tok[0]);
	return def_chopped(tok[0]);
}

# read a token; the one before
tok_pop(): string
{
	tok_prev = tok;
	tok_read();
	if(tok_prev == "")
		return nil;
	return tok_prev;
}

# tok_pop, past blanks; if sep, to a chopping token
tok_poptext(sep: int): string
{
	while(tok_type() == T_SPACE)
		tok_read();
	tok_prev = "";
	do{
		tok_prev += tok;
		tok_read();
	}while(tok != "" && !tok_chops(!sep));
	if(tok_prev == "")
		return nil;
	return tok_prev;
}

tok_blanks()
{
	while(tok_type() == T_SPACE)
		tok_pop();
}

# zero, and past it, if the next token is s
tok_jmp(s: string): int
{
	tok_blanks();
	if(tok_get() != nil && len s == 1 && strchr("{}~^\t", s[0]) && s == tok_get()){
		tok_pop();
		return 0;
	}
	if(tok_type() != T_KEYWORD || tok_get() == nil || s != tok_get())
		return 1;
	tok_pop();
	return 0;
}

tok_delim()
{
	delim := tok_preview(0);
	if(delim == "off"){
		eqn_beg = 0;
		eqn_end = 0;
	}else{
		eqn_beg = eqn_end = 0;
		if(len delim > 0)
			eqn_beg = delim[0];
		if(len delim > 1)
			eqn_end = delim[1];
	}
}

tok_macrodef(): string
{
	def := "";
	c := src_next();
	while(c > 0 && isspace(c))
		c = src_next();
	delim := c;
	c = src_next();
	while(c > 0 && c != delim){
		def[len def] = c;
		c = src_next();
	}
	return cstr(def);
}

tok_macro()
{
	name := tok_preview(0);
	src_define(name, tok_macrodef());
}

tok_inline(): int
{
	return tok_line;
}
