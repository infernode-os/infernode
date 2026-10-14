#
# picl.lx: the lexical analyser, as lex(1) made it: the longest match,
# the first rule of those as long; a character past a match read, and
# put back, when a longer match was still possible
#

# lex's start conditions
INITIAL, LA, LSTR, LDEF, LSC, LBR, LTHRU, LSH: con iota;

lstate := INITIAL;
yyprevious := '\n';	# the last character of the last match
CBUFLEN: con 500;
cbuf := "";
delim := 0;
ifsw := 0;	# 1 if if statement in progress

kwtab := array[] of {
	("print", 0), ("box", 0), ("circle", 0), ("arc", 0), ("ellipse", 0), ("arrow", 0),
	("spline", 0), ("line", 0), ("move", 0), ("reset", 0), ("sprintf", 0),
	("same", 0), ("between", 0), ("and", 0), ("of", 0), ("the", 0), ("way", 0),
	("height", 0), ("ht", 0), ("width", 0), ("wid", 0), ("radius", 0), ("rad", 0),
	("diameter", 0), ("diam", 0), ("size", 0), ("left", 0), ("right", 0), ("up", 0),
	("down", 0), ("cw", 0), ("clockwise", 0), ("ccw", 0), ("invis", 0),
	("invisible", 0), ("noedge", 0), ("fill", 0), ("solid", 0), ("dot", 0),
	("dotted", 0), ("dash", 0), ("dashed", 0), ("chop", 0), ("spread", 0),
	("ljust", 0), ("rjust", 0), ("above", 0), ("below", 0), ("center", 0),
	("from", 0), ("to", 0), ("at", 0), ("by", 0), ("with", 0), ("last", 0),
	("log", 0), ("exp", 0), ("sin", 0), ("cos", 0), ("atan2", 0), ("sqrt", 0),
	("rand", 0), ("max", 0), ("min", 0), ("int", 0), ("Here", 0), ("for", 0),
	("do", 0), ("copy", 0), ("include", 0), ("until", 0), ("if", 0), ("then", 0),
	("else", 0), ("first", 0),
};

# the corners and components after a dot, and what they are
dotwords := array[] of {
	("e", 0), ("east", 0), ("r", 0), ("right", 0), ("w", 0), ("west", 0),
	("l", 0), ("left", 0), ("n", 0), ("north", 0), ("t", 0), ("top", 0),
	("s", 0), ("south", 0), ("b", 0), ("bot", 0), ("bottom", 0), ("c", 0),
	("center", 0), ("start", 0), ("end", 0), ("ne", 0), ("se", 0), ("nw", 0),
	("sw", 0), ("x", 0), ("y", 0), ("ht", 0), ("height", 0), ("wid", 0),
	("width", 0), ("rad", 0), ("radius", 0),
};

# the words of "word of" (top of, ...)
ofwords := array[] of {
	"top", "north", "bottom", "south", "left", "west", "right", "east",
	"center", "start", "end",
};

isA(c: int): int
{
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '_';
}

isB(c: int): int
{
	return isA(c) || c >= '0' && c <= '9';
}

isD(c: int): int
{
	return c >= '0' && c <= '9';
}

isWS(c: int): int
{
	return c == ' ' || c == '\t';
}

islower(c: int): int
{
	return c >= 'a' && c <= 'z';
}

# the characters read past a match, put back (the last first)
backup(s: string)
{
	for(i := len s - 1; i >= 0; i--)
		unput(s[i]);
}

# read an identifier's characters after its first, and the one after
# them; that one is returned
identrest(s: string): (string, int)
{
	for(;;){
		c := input();
		if(!isB(c))
			return (s, c);
		s[len s] = c;
	}
}

YYLEX.lex(l: self ref YYLEX): int
{
	# witchcraft
	case lstate {
	INITIAL =>
		lstate = LA;
	LSC =>
		lstate = LA;
		return '}';
	LBR =>
		lstate = LA;
		return ']';
	}
	for(;;){
		t := -2;
		case lstate {
		LA =>
			t = lexA(l);
		LSTR =>
			t = lexstr(l);
		LDEF =>
			lexdef();
		LTHRU =>
			t = lexthru(l);
		LSH =>
			lexsh();
		* =>
			lstate = LA;
		}
		if(t != -2){
			if(dbg)
				errout(sys->sprint("lex %d <%s> i=%d\n", t, l.lval.p, l.lval.i));
			return t;
		}
	}
}

# a match's text: what lex leaves in yyprevious
matched(s: string)
{
	if(len s > 0)
		yyprevious = s[len s - 1];
}

# in A: a token, or -2 for none
lexA(l: ref YYLEX): int
{
	bol := yyprevious == '\n';
	c := input();
	if(c == EOF)
		return 0;
	s := ch(c);
	case c {
	' ' or '\t' =>
		matched(s);
		return -2;
	'\\' =>
		d := input();
		if(d == '\n'){
			matched("\n");
			return -2;
		}
		unput(d);
		matched(s);
		return l.lval.i = c;
	'\n' =>
		matched(s);
		return ST;
	';' =>
		matched(s);
		return ST;
	'}' =>
		matched(s);
		lstate = LSC;
		return ST;
	']' =>
		matched(s);
		lstate = LBR;
		return ST;
	'{' =>
		# "{"{WS}*(#.*)?\n+
		r := "";
		d: int;
		while(isWS(d = input()))
			r[len r] = d;
		if(d == '#'){
			r[len r] = d;
			while((d = input()) != '\n' && d != EOF)
				r[len r] = d;
		}
		if(d == '\n'){
			while((d = input()) == '\n')
				;
			unput(d);
			matched("\n");
		}else{
			unput(d);
			backup(r);
			matched(s);
		}
		return l.lval.i = c;
	'.' =>
		if(bol){
			# ^".PS".*, ^".PE".*, ^".".*
			d: int;
			while((d = input()) != '\n' && d != EOF)
				s[len s] = d;
			unput(d);
			matched(s);
			if(prefix(".PS", s)){
				if(curfile == 0)
					error(".PS found inside .PS/.PE");
				return -2;
			}
			if(prefix(".PE", s)){
				if(curfile == 0){
					l.lval.p = PEstring = s;
					return EOF;
				}
				return -2;
			}
			l.lval.p = s;
			return TROFF;
		}
		d := input();
		if(isD(d)){
			unput(d);
			return number(l, s);
		}
		# the corners and components; lex reads on only while a longer
		# match is possible
		w := "";
		for(;;){
			if(d == EOF || !dotprefix(w + ch(d))){
				if(d != EOF)
					unput(d);
				break;
			}
			w[len w] = d;
			if(!dotextends(w))
				break;
			d = input();
		}
		k := len w;
		while(k > 0 && dotword(w[0:k]) < 0)
			k--;
		backup(w[k:]);
		if(k == 0){
			matched(s);
			return l.lval.i = '.';
		}
		matched(s + w[0:k]);
		return dottoken(l, w[0:k]);
	'<' =>
		d := input();
		if(d == '-'){
			e := input();
			if(e == '>'){
				matched("<->");
				l.lval.i = HEAD12;
				return HEAD;
			}
			unput(e);
			matched("<-");
			l.lval.i = HEAD1;
			return HEAD;
		}
		if(d == '='){
			matched("<=");
			return LE;
		}
		unput(d);
		matched(s);
		return LT;
	'-' =>
		d := input();
		if(d == '>'){
			matched("->");
			l.lval.i = HEAD2;
			return HEAD;
		}
		unput(d);
		matched(s);
		return l.lval.i = c;
	'=' =>
		return two(l, c, '=', EQ, 0);
	'>' =>
		return two(l, c, '=', GE, GT);
	'!' =>
		return two(l, c, '=', NEQ, NOT);
	'&' =>
		return two(l, c, '&', ANDAND, 0);
	'|' =>
		return two(l, c, '|', OROR, 0);
	'[' =>
		d := input();
		if(d == ']'){
			matched("[]");
			return l.lval.i = BLOCK;
		}
		unput(d);
		matched(s);
		return l.lval.i = c;
	'"' =>
		matched(s);
		lstate = LSTR;
		cbuf = "";
		return -2;
	'#' =>
		d: int;
		while((d = input()) != '\n' && d != EOF)
			s[len s] = d;
		unput(d);
		matched(s);
		return -2;
	}
	if(isD(c)){
		unput(c);
		return number(l, "");
	}
	if(isA(c))
		return word(l, bol, s);
	matched(s);
	return l.lval.i = c;
}

# c, or c followed by d: tok2 for the two, tok1 for c alone (or c)
two(l: ref YYLEX, c: int, d: int, tok2: int, tok1: int): int
{
	e := input();
	if(e == d){
		matched(ch(d));
		return tok2;
	}
	unput(e);
	matched(ch(c));
	if(tok1)
		return tok1;
	return l.lval.i = c;
}

dotprefix(s: string): int
{
	for(i := 0; i < len dotwords; i++){
		(w, nil) := dotwords[i];
		if(len w >= len s && w[0:len s] == s)
			return 1;
	}
	return 0;
}

dotword(s: string): int
{
	for(i := 0; i < len dotwords; i++)
		if(dotwords[i].t0 == s)
			return i;
	return -1;
}

# whether a dot-word is the prefix of a longer one (lex read on past it)
dotextends(s: string): int
{
	for(i := 0; i < len dotwords; i++){
		(w, nil) := dotwords[i];
		if(len w > len s && w[0:len s] == s)
			return 1;
	}
	return 0;
}

dottoken(l: ref YYLEX, w: string): int
{
	case w {
	"e" or "east" or "r" or "right" =>
		l.lval.i = EAST;
	"w" or "west" or "l" or "left" =>
		l.lval.i = WEST;
	"n" or "north" or "t" or "top" =>
		l.lval.i = NORTH;
	"s" or "south" or "b" or "bot" or "bottom" =>
		l.lval.i = SOUTH;
	"c" or "center" =>
		l.lval.i = CENTER;
	"start" =>
		l.lval.i = START;
	"end" =>
		l.lval.i = END;
	"ne" =>
		l.lval.i = NE;
	"se" =>
		l.lval.i = SE;
	"nw" =>
		l.lval.i = NW;
	"sw" =>
		l.lval.i = SW;
	"x" =>
		return l.lval.i = DOTX;
	"y" =>
		return l.lval.i = DOTY;
	"ht" or "height" =>
		return l.lval.i = DOTHT;
	"wid" or "width" =>
		return l.lval.i = DOTWID;
	"rad" or "radius" =>
		return l.lval.i = DOTRAD;
	}
	return CORNER;
}

# ({D}+("."?){D}*|"."{D}+)((e|E)("+"|-)?{D}+)?i? and {D}+(th|nd|rd|st);
# pre is "." if one was read
number(l: ref YYLEX, pre: string): int
{
	s := pre;
	c: int;
	while(isD(c = input()))
		s[len s] = c;
	if(pre == ""){
		# {D}+(th|nd|rd|st)
		if(c == 't' || c == 'n' || c == 'r' || c == 's'){
			d := input();
			if(c == 't' && d == 'h' || c == 'n' && d == 'd' || c == 'r' && d == 'd' ||
			    c == 's' && d == 't'){
				matched(ch(d));
				l.lval.i = atoi(s);
				return NTH;
			}
			unput(d);
		}else if(c == '.'){
			s[len s] = c;
			while(isD(c = input()))
				s[len s] = c;
		}
	}
	acc := s;	# what is matched
	if(c == 'e' || c == 'E'){
		t := ch(c);
		d := input();
		if(d == '+' || d == '-'){
			t[len t] = d;
			d = input();
		}
		if(isD(d)){
			while(isD(d)){
				t[len t] = d;
				d = input();
			}
			acc = s + t;
			c = d;
		}else{
			unput(d);
			backup(t[1:]);
			# c is still the e
		}
	}
	if(c == 'i'){
		acc[len acc] = c;
		matched(acc);
	}else{
		unput(c);
		matched(acc);
	}
	l.lval.f = atof(acc);
	return NUMBER;
}

# an identifier, a keyword, or a pattern beginning with one
word(l: ref YYLEX, bol: int, s: string): int
{
	c: int;
	(s, c) = identrest(s);
	# word" "+of
	for(i := 0; i < len ofwords; i++)
		if(s == ofwords[i] && c == ' '){
			r := ch(c);
			d: int;
			while((d = input()) == ' ')
				r[len r] = d;
			e := 0;
			if(d == 'o'){
				e = input();
				if(e == 'f'){
					matched("f");
					l.lval.i = ofcorner(s);
					return CORNER;
				}
				unput(e);
			}
			unput(d);
			backup(r[1:]);
			break;
		}
	if(isWS(c)){
		case s {
		"define" =>
			wsrest();
			lstate = LDEF;
			return -2;
		"thru" or "through" =>
			wsrest();
			lstate = LTHRU;
			return THRU;
		"sh" =>
			wsrest();
			lstate = LSH;
			if((delim = input()) == '{')
				delim = '}';	# no nested {}
			shell_init();
			return -2;
		"undef" or "undefine" =>
			r := ch(c);
			d: int;
			while(isWS(d = input()))
				r[len r] = d;
			if(isA(d)){
				(n, e) := identrest(ch(d));
				unput(e);
				matched(n);
				undefine(s + r + n);
				return -2;
			}
			unput(d);
			backup(r[1:]);
		}
	}
	if(s == "Endfor" && bol && c == '\n'){
		matched("\n");
		endfor();
		return -2;
	}
	unput(c);
	matched(s);
	case s {
	"print" =>	return l.lval.i = PRINT;
	"box" =>	return l.lval.i = BOX;
	"circle" =>	return l.lval.i = CIRCLE;
	"arc" =>	return l.lval.i = ARC;
	"ellipse" =>	return l.lval.i = ELLIPSE;
	"arrow" =>	return l.lval.i = ARROW;
	"spline" =>	return l.lval.i = SPLINE;
	"line" =>	return l.lval.i = LINE;
	"move" =>	return l.lval.i = MOVE;
	"reset" =>	return RESET;
	"sprintf" =>	return SPRINTF;
	"same" =>	return SAME;
	"between" =>	return BETWEEN;
	"and" =>	return AND;
	"of" or "the" or "way" =>
		return -2;
	"height" or "ht" =>
		l.lval.i = HEIGHT;
		return ATTR;
	"width" or "wid" =>
		l.lval.i = WIDTH;
		return ATTR;
	"radius" or "rad" =>
		l.lval.i = RADIUS;
		return ATTR;
	"diameter" or "diam" =>
		l.lval.i = DIAMETER;
		return ATTR;
	"size" =>
		l.lval.i = SIZE;
		return ATTR;
	"left" =>
		l.lval.i = LEFT;
		return DIR;
	"right" =>
		l.lval.i = RIGHT;
		return DIR;
	"up" =>
		l.lval.i = UP;
		return DIR;
	"down" =>
		l.lval.i = DOWN;
		return DIR;
	"cw" or "clockwise" =>
		l.lval.i = CW;
		return ATTR;
	"ccw" =>
		l.lval.i = CCW;
		return ATTR;
	"invis" or "invisible" or "noedge" =>
		l.lval.i = INVIS;
		return ATTR;
	"fill" =>	return l.lval.i = FILL;
	"solid" =>	return -2;
	"dot" or "dotted" =>
		return l.lval.i = DOT;
	"dash" or "dashed" =>
		return l.lval.i = DASH;
	"chop" =>	return l.lval.i = CHOP;
	"spread" =>
		l.lval.i = SPREAD;
		return TEXTATTR;
	"ljust" =>
		l.lval.i = LJUST;
		return TEXTATTR;
	"rjust" =>
		l.lval.i = RJUST;
		return TEXTATTR;
	"above" =>
		l.lval.i = ABOVE;
		return TEXTATTR;
	"below" =>
		l.lval.i = BELOW;
		return TEXTATTR;
	"center" =>
		l.lval.i = CENTER;
		return TEXTATTR;
	"from" =>	return l.lval.i = FROM;
	"to" =>		return l.lval.i = TO;
	"at" =>		return l.lval.i = AT;
	"by" =>		return l.lval.i = BY;
	"with" =>	return l.lval.i = WITH;
	"last" =>	return l.lval.i = LAST;
	"log" =>	return LOG;
	"exp" =>	return EXP;
	"sin" =>	return SIN;
	"cos" =>	return COS;
	"atan2" =>	return ATAN2;
	"sqrt" =>	return SQRT;
	"rand" =>	return RAND;
	"max" =>	return MAX;
	"min" =>	return MIN;
	"int" =>	return INT;
	"Here" =>	return l.lval.i = HERE;
	"for" =>	return FOR;
	"do" =>
		l.lval.p = delimstr("loop body");
		return DOSTR;
	"copy" or "include" =>
		return COPY;
	"until" =>	return UNTIL;
	"if" =>
		ifsw = 1;
		return IF;
	"then" =>
		if(!ifsw){
			l.lval.i = THEN;
			return ATTR;
		}
		l.lval.p = delimstr("then part");
		ifsw = 0;
		return THENSTR;
	"else" =>
		l.lval.p = delimstr("else part");
		return ELSESTR;
	"first" =>
		l.lval.i = 1;
		return NTH;
	}
	p := lookup(s);
	if(p != nil && p.typ == DEFNAME){
		c = input();
		unput(c);
		if(c == '(')	# it's name(...)
			dodef(p);
		else	# no argument list
			pbstr(p.val.p);
		return -2;
	}
	l.lval.p = s;
	if(islower(s[0]))
		return VARNAME;
	return PLACENAME;
}

# {WS}+ after a word: the rest of the blanks, and the character after
wsrest()
{
	d: int;
	while(isWS(d = input()))
		;
	unput(d);
	yyprevious = ' ';
}

ofcorner(s: string): int
{
	case s {
	"top" or "north" =>
		return NORTH;
	"bottom" or "south" =>
		return SOUTH;
	"left" or "west" =>
		return WEST;
	"right" or "east" =>
		return EAST;
	"center" =>
		return CENTER;
	"start" =>
		return START;
	}
	return END;
}

# in str
lexstr(l: ref YYLEX): int
{
	c := input();
	case c {
	'"' =>
		matched("\"");
		l.lval.p = cbuf;
		lstate = LA;
		return TEXT;
	'\n' =>
		matched("\n");
		error(sys->sprint("missing quote in string \"%s\"", cbuf));
		lstate = LA;
		return ST;
	'\\' =>
		d := input();
		case d {
		'"' =>
			cbuf[len cbuf] = '"';
			matched(ch(d));
			return -2;
		't' =>
			cbuf[len cbuf] = '\t';
			matched(ch(d));
			return -2;
		'\\' =>
			cbuf[len cbuf] = '\\';
			matched(ch(d));
			return -2;
		}
		unput(d);
	EOF =>
		return 0;
	}
	matched(ch(c));
	cadd(c);
	return -2;
}

cadd(c: int)
{
	cbuf[len cbuf] = c;
	if(len cbuf >= CBUFLEN - 1){
		error("string too long");
		lstate = LA;
	}
}

# in def: a name to define; anything else, as lex, written out
lexdef()
{
	c := input();
	if(isA(c)){
		(s, d) := identrest(ch(c));
		unput(d);
		matched(s);
		definition(s);
		lstate = LA;
		return;
	}
	yyprevious = c;
	if(c > 0)
		outc(c);
}

# in thru: a name, or a character
lexthru(l: ref YYLEX): int
{
	c := input();
	s := ch(c);
	if(isA(c)){
		d: int;
		(s, d) = identrest(s);
		unput(d);
	}else if(c == '\n'){
		yyprevious = c;
		outc(c);
		return -2;
	}
	matched(s);
	l.lval.st = copythru(s);
	lstate = LA;
	return DEFNAME;
}

# in sh: the command, to delim (not run here)
lexsh()
{
	c := input();
	if(isA(c)){
		(s, d) := identrest(ch(c));
		unput(d);
		matched(s);
		if(s[0] == delim){
			shell_exec();
			lstate = LA;
		}else{
			p := lookup(s);
			if(p != nil && p.typ == DEFNAME){
				c = input();
				unput(c);
				if(c == '(')
					dodef(p);
				else
					pbstr(p.val.p);
			}else
				shell_text(s);
		}
		return;
	}
	yyprevious = c;
	if(c == delim){
		shell_exec();
		lstate = LA;
	}else
		shell_text(ch(c));
}

YYLEX.error(nil: self ref YYLEX, msg: string)
{
	yyerror(msg);
}
