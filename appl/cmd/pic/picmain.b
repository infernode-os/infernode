#
# main.c, input.c, misc.c, symtab.c, for.c
#

stdout: ref Iobuf;
objlist := array[1000] of ref Obj;	# store the elements here
nobj := 0;
attr := array[100] of Attr;	# attributes stored here as collected
nattr := 0;	# number of entries in attr_list
text := array[1000] of Txt;	# text strings stored here as collected
ntext := 0;
ntext1 := 0;	# record ntext here on entry to each figure
curx := 0.0;
cury := 0.0;
hvmode := R_DIR;	# R => join left to right, D => top to bottom, etc.
codegen := 0;	# 1=>output for this picture; 0=>no output
PEstring: string;	# "PS" or "PE" picked up by lexer
deltx := 6.0;	# max x value in output, for scaling
delty := 6.0;	# max y value in output, for scaling
dbg := 0;
synerr := 0;
anyerr := 0;	# becomes 1 if synerr ever 1
cmdname := "pic";
xmin := 30000.0;	# min values found in actual data
ymin := 30000.0;
xmax := -30000.0;	# max
ymax := -30000.0;
version := "version July 5, 1993";

init(nil: ref Draw->Context, args: list of string)
{
	sys = load Sys Sys->PATH;
	bufio = load Bufio Bufio->PATH;
	math = load Math Math->PATH;
	stdout = bufio->fopen(sys->fildes(1), Bufio->OWRITE);
	{
		pic(args);
	} exception e {
	"fail:*" =>
		stdout.flush();
		raise e;
	"*" =>
		# where C would crash (a nil object, say): said, and failed
		stdout.flush();
		errout(cmdname + ": " + e + "\n");
		raise "fail:" + e;
	}
	stdout.flush();
	if(anyerr)
		raise "fail:errors";
}

pic(args: list of string)
{
	if(args != nil)
		args = tl args;
	while(args != nil && at(hd args, 0) == '-'){
		a := hd args;
		case at(a, 1) {
		'd' =>
			dbg = atoi(a[2:]);
			if(dbg == 0)
				dbg = 1;
			errout(version + "\n");
		'V' =>
			errout(version + "\n");
			return;
		}
		args = tl args;
	}
	setdefaults();
	pushsrc(String, "/" + string sys->pctl(0, nil) + "/");
	definition("pid");
	curfile = 0;
	pushsrc(File, nil);
	if(args == nil){
		infile[0] = Infile(bufio->fopen(sys->fildes(0), Bufio->OREAD), "-", 0);
		getdata();
	}else
		for(; args != nil; args = tl args){
			f := bufio->open(hd args, Bufio->OREAD);
			if(f == nil){
				errout(cmdname + ": can't open " + u8(hd args) + "\n");
				raise "fail:open";
			}
			infile[curfile] = Infile(f, u8(hd args), 0);
			getdata();
		}
}

#
# output, a byte a character
#
out(s: string)
{
	b := array[len s] of byte;
	for(i := 0; i < len s; i++)
		b[i] = byte s[i];
	stdout.write(b, len b);
}

outc(c: int)
{
	stdout.putb(byte c);
}

errout(s: string)
{
	b := array[len s] of byte;
	for(i := 0; i < len s; i++)
		b[i] = byte s[i];
	sys->write(sys->fildes(2), b, len b);
}

u8(s: string): string
{
	b := array of byte s;
	r := "";
	for(i := 0; i < len b; i++)
		r[i] = int b[i];
	return r;
}

ch(c: int): string
{
	s := "";
	s[0] = c & 16rffff;
	return s;
}

at(s: string, i: int): int
{
	if(i < 0 || i >= len s)
		return 0;
	return s[i];
}

prefix(p: string, s: string): int
{
	return len s >= len p && s[0:len p] == p;
}

atoi(s: string): int
{
	i := 0;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	neg := 0;
	if(i < len s && (s[i] == '-' || s[i] == '+')){
		neg = s[i] == '-';
		i++;
	}
	n := 0;
	for(; i < len s && s[i] >= '0' && s[i] <= '9'; i++)
		n = n * 10 + s[i] - '0';
	if(neg)
		return -n;
	return n;
}

# C's atof: the longest number at the start of s
atof(s: string): real
{
	(f, nil) := strtod(s, 0);
	return f;
}

# a number at i of s, and the index past it (i if there is none)
strtod(s: string, i: int): (real, int)
{
	j := i;
	while(j < len s && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n'))
		j++;
	k := j;
	if(k < len s && (s[k] == '+' || s[k] == '-'))
		k++;
	nd := 0;
	while(k < len s && s[k] >= '0' && s[k] <= '9'){
		k++;
		nd++;
	}
	if(k < len s && s[k] == '.'){
		k++;
		while(k < len s && s[k] >= '0' && s[k] <= '9'){
			k++;
			nd++;
		}
	}
	if(nd == 0)
		return (0.0, i);
	if(k < len s && (s[k] == 'e' || s[k] == 'E')){
		e := k + 1;
		if(e < len s && (s[e] == '+' || s[e] == '-'))
			e++;
		if(e < len s && s[e] >= '0' && s[e] <= '9'){
			while(e < len s && s[e] >= '0' && s[e] <= '9')
				e++;
			k = e;
		}
	}
	return (real s[j:k], k);
}

# C's %g, %.3f (Limbo's %g is the shortest exact form, not C's)
g(x: real): string
{
	return cg(x, 6);
}

# C's %.Pg: P significant digits, as %e or %f by the exponent, trailing
# zeros dropped
cg(x: real, p: int): string
{
	if((n := nonfinite(x)) != nil)
		return n;
	if(p == 0)
		p = 1;
	e := sys->sprint("%.*e", p - 1, x);
	k := strchr(e, 'e');
	xp := int e[k + 1:];
	if(xp < -4 || xp >= p)
		return trimz(e[0:k]) + e[k:];
	return trimz(sys->sprint("%.*f", p - 1 - xp, x));
}

# a number's trailing zeros after its point, and the point if they were all
trimz(s: string): string
{
	if(strchr(s, '.') < 0)
		return s;
	n := len s;
	while(n > 0 && s[n - 1] == '0')
		n--;
	if(n > 0 && s[n - 1] == '.')
		n--;
	return s[0:n];
}

f3(x: real): string
{
	if((n := nonfinite(x)) != nil)
		return n;
	return sys->sprint("%.3f", x);
}

# C's NaN and infinities, signed as their bits are
nonfinite(x: real): string
{
	if(math->isnan(x)){
		if(math->realbits64(x) < big 0)
			return "-nan";
		return "nan";
	}
	if(x == math->Infinity)
		return "inf";
	if(x == -math->Infinity)
		return "-inf";
	return nil;
}

setdefaults()	# set default sizes for variables like boxht
{
	for(i := 0; i < len defaults; i++){
		(name, val, nil) := defaults[i];
		v: YYSTYPE;
		v.f = val;
		makevar(name, VARNAME, v);
	}
}

defaults := array[] of {
	("scale", SCALE, 1),
	("lineht", HT, 1),
	("linewid", HT, 1),
	("moveht", HT, 1),
	("movewid", HT, 1),
	("dashwid", HT10, 1),
	("boxht", HT, 1),
	("boxwid", WID, 1),
	("circlerad", HT2, 1),
	("arcrad", HT2, 1),
	("ellipseht", HT, 1),
	("ellipsewid", WID, 1),
	("arrowht", HT5, 1),
	("arrowwid", HT10, 1),
	("arrowhead", 2.0, 0),	# arrowhead style
	("textht", 0.0, 1),	# 6 lines/inch is also a useful value
	("textwid", 0.0, 1),
	("maxpsht", MAXHT, 0),
	("maxpswid", MAXWID, 0),
	("fillval", 0.7, 0),	# gray value for filling boxes
};

resetvar()	# reset variables listed
{
	if(nattr == 0){	# none listed, so do all
		setdefaults();
		return;
	}
	for(i := 0; i < nattr; i++){
		for(j := 0; j < len defaults; j++){
			(name, val, nil) := defaults[j];
			if(name == attr[i].val.p){
				setfval(name, val);
				break;
			}
		}
	}
}

checkscale(s: string)	# if s is "scale", adjust default variables
{
	if(s == "scale"){
		scale := getfval("scale");
		for(i := 1; i < len defaults; i++){
			(name, val, scalable) := defaults[i];
			if(scalable)
				setfval(name, val * scale);
		}
	}
}

# C's fgets, of up to n - 1 bytes
fgets(f: ref Iobuf, n: int): string
{
	s := "";
	while(len s < n - 1){
		c := f.getb();
		if(c == Bufio->EOF)
			break;
		s[len s] = c;
		if(c == '\n')
			break;
	}
	if(s == "")
		return nil;
	return s;
}

cstr(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] == 0)
			return s[0:i];
	return s;
}

getdata()
{
	infile[curfile].lineno = 0;
	printlf(1, infile[curfile].fname);
	while((buf := fgets(infile[curfile].fin, 1000)) != nil){
		infile[curfile].lineno++;
		if(at(buf, 0) == '.' && at(buf, 1) == 'P' && at(buf, 2) == 'S'){
			p := 3;
			while(at(buf, p) == ' ')
				p++;
			if(at(buf, p++) == '<'){
				svfile := infile[curfile];
				buf1 := firstword(buf, p);
				f := bufio->open(buf1, Bufio->OREAD);
				if(f == nil)
					fatal("can't open " + buf1);
				infile[curfile].fin = f;
				infile[curfile].fname = buf1;
				getdata();
				infile[curfile] = svfile;
				printlf(infile[curfile].lineno, infile[curfile].fname);
				continue;
			}
			reset();
			yyparse(ref YYLEX);
			anyerr += synerr;
			deltx = (xmax - xmin) / getfval("scale");
			delty = (ymax - ymin) / getfval("scale");
			if(at(buf, 3) == ' '){	# next things are wid & ht
				(dx, i1) := strtod(buf, 4);
				if(i1 > 4){
					deltx = dx;
					(dy, i2) := strtod(buf, i1);
					if(i2 > i1)
						delty = dy;
					else
						delty = deltx * (ymax-ymin) / (xmax-xmin);
				}else
					delty = deltx * (ymax-ymin) / (xmax-xmin);
			}
			if(codegen && !synerr){
				openpl(cstr(buf[3:]));	# puts out .PS, with ht & wid stuck in
				printlf(infile[curfile].lineno+1, nil);
				print();	# assumes \n at end
				closepl(PEstring);	# does the .PE/F
			}
			printlf(infile[curfile].lineno+1, nil);
		}else if(at(buf, 0) == '.' && at(buf, 1) == 'l' && at(buf, 2) == 'f'){
			(ln, i) := scanint(buf, 3);
			buf1 := firstword(buf, i);
			if(i > 3 && buf1 != nil){
				infile[curfile].lineno = ln;
				infile[curfile].fname = buf1;
				printlf(ln, buf1);
			}else{
				if(i > 3)
					infile[curfile].lineno = ln;
				printlf(infile[curfile].lineno, nil);
			}
		}else
			out(cstr(buf));
	}
}

# sscanf's %d at i: the number and the index past it
scanint(s: string, i: int): (int, int)
{
	j := i;
	while(j < len s && (s[j] == ' ' || s[j] == '\t' || s[j] == '\n'))
		j++;
	k := j;
	if(k < len s && (s[k] == '-' || s[k] == '+'))
		k++;
	if(k >= len s || s[k] < '0' || s[k] > '9')
		return (0, i);
	while(k < len s && s[k] >= '0' && s[k] <= '9')
		k++;
	return (atoi(s[j:k]), k);
}

# sscanf's %s at i
firstword(s: string, i: int): string
{
	while(i < len s && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n'))
		i++;
	j := i;
	while(j < len s && s[j] != ' ' && s[j] != '\t' && s[j] != '\n' && s[j] != 0)
		j++;
	if(j == i)
		return nil;
	return s[i:j];
}

reset()
{
	nobj = 0;
	nattr = 0;
	ntext = ntext1 = 0;
	codegen = synerr = 0;
	nstack = 0;
	curx = cury = 0.0;
	PEstring = nil;
	hvmode = R_DIR;
	xmin = ymin = 30000.0;
	xmax = ymax = -30000.0;
}

#
# input.c
#
infile := array[10] of Infile;
curfile := 0;
MAXSRC: con 50;
src := array[MAXSRC] of Src;	# input source stack
srcp := 0;

pushsrc(typ: int, s: string)	# new input source
{
	if(++srcp >= MAXSRC)
		fatal("inputs nested too deep");
	src[srcp] = Src(typ, s, 0);
}

popsrc()	# restore an old one
{
	if(srcp <= 0)
		fatal("too many inputs popped");
	srcp--;
}

definition(s: string)	# collect definition for s and install
	# definitions picked up lexically
{
	p := delimstr("definition");
	stp := lookup(s);
	if(stp != nil){	# it's there before
		if(stp.typ != DEFNAME){
			error(s + " used as variable and definition");
			return;
		}
		stp.val.p = p;
	}else{
		u: YYSTYPE;
		u.p = p;
		makevar(s, DEFNAME, u);
	}
}

delimstr(s: string): string	# get body of X ... X
	# message if too big
{
	delim: int;
	while((delim = input()) == ' ' || delim == '\t' || delim == '\n')
		;
	rdelim := baldelim(delim, "{}");	# could be "(){}[]`'"
	deep := 1;
	buf := "";
	for(;;){
		c := input();
		if(c == rdelim)
			if(--deep == 0)
				break;
		if(c == delim)
			deep++;
		if(c == EOF){
			b := buf;
			if(len b > 20)
				b = b[0:20];
			fatal(sys->sprint("end of file in %s %c %s... %c", s, delim, b, delim));
		}
		buf[len buf] = c;
	}
	return buf;
}

baldelim(c: int, s: string): int	# replace c by balancing entry in s
{
	for(i := 0; i + 1 < len s; i += 2)
		if(s[i] == c)
			return s[i + 1];
	return c;
}

undefine(s: string)	# undefine macro
{
	i := 0;
	while(i < len s && s[i] != ' ' && s[i] != '\t')	# skip "undef..."
		i++;
	while(i < len s && (s[i] == ' ' || s[i] == '\t'))
		i++;
	freedef(s[i:]);
}

args := array[10] of Arg;	# argument frames
argfp := 0;	# frame pointer
argcnt := 0;	# number of arguments seen so far

dodef(stp: ref Sym)	# collect args and switch input to defn
{
	ap := argfp + 1;
	if(ap >= len args)
		fatal("arguments too deep");
	argcnt = 0;
	if(input() != '(')
		fatal("disaster in dodef");
	stk := array[MAXARGS] of {* => ""};
	for(;;){
		(a, ok) := getarg();
		if(!ok)
			break;
		if(argcnt < MAXARGS)
			stk[argcnt] = a;
		argcnt++;
		if(input() == ')')
			break;
	}
	args[ap] = Arg(stk);
	argfp = ap;
	pushsrc(Macro, stp.val.p);
}

getarg(): (string, int)	# pick up single argument
{
	p := "";
	npar := 0;
	c: int;
	for(;;){
		c = input();
		if(c == EOF)
			fatal("end of file in getarg");
		if(npar == 0 && (c == ',' || c == ')'))
			break;
		if(c == '"'){	# copy quoted stuff intact
			do{
				p[len p] = c;
			}while((c = input()) != '"' && c != EOF);
		}else if(c == '(')
			npar++;
		else if(c == ')')
			npar--;
		p[len p] = c;
	}
	unput(c);
	return (p, 1);
}

PBSIZE: con 2000;
pbuf := array[PBSIZE] of int;	# pushback buffer
pb := -1;	# next pushed back character
ebuf := array[200] of {* => 0};	# collect input here for error reporting
ep := 0;
begin := 0;

input(): int
{
	if(thru && begin){
		do_thru();
		begin = 0;
	}
	c := nextchar();
	if(ep >= len ebuf)
		ep = 0;
	ebuf[ep++] = c & 16rff;
	return c;
}

nextchar(): int
{
	c: int;
loop:
	for(;;){
		case src[srcp].typ {
		Free =>	# free string
			popsrc();
			continue loop;
		Thru =>	# end of pushed back line
			begin = 1;
			popsrc();
			c = '\n';
		Char =>
			if(pb >= 0){
				c = pbuf[pb--];
				popsrc();
			}else{	# can't happen?
				popsrc();
				continue loop;
			}
		String =>
			sp := src[srcp];
			c = at(sp.s, sp.pos);
			src[srcp].pos++;
			if(c == 0){
				popsrc();
				continue loop;
			}
			if(at(sp.s, sp.pos + 1) == 0)	# empty, so pop
				popsrc();
		Macro =>
			sp := src[srcp];
			c = at(sp.s, sp.pos);
			src[srcp].pos++;
			if(c == 0){
				if(--argfp < 0)
					fatal("argfp underflow");
				popsrc();
				continue loop;
			}else if(c == '$' && isD(at(sp.s, sp.pos + 1))){
				n := 0;
				i := sp.pos + 1;
				while(isD(at(sp.s, i)))
					n = 10 * n + sp.s[i++] - '0';
				src[srcp].pos = i;
				if(n > 0 && n <= MAXARGS)
					pushsrc(String, args[argfp].argstk[n-1]);
				continue loop;
			}
		File =>
			c = infile[curfile].fin.getb();
			if(c == Bufio->EOF){
				c = EOF;
				if(curfile == 0)
					fatal("end of file inside .PS/.PE");
				curfile--;
				printlf(infile[curfile].lineno, infile[curfile].fname);
				popsrc();
				thru = 0;	# chicken out
				thrudef = nil;
				untilstr = nil;
				continue loop;
			}
			if(c == '\n')
				infile[curfile].lineno++;
		}
		break;
	}
	return c;
}

do_thru()	# read one line, make into a macro expansion
{
	ap := argfp + 1;
	if(ap >= len args)
		fatal("arguments too deep");
	stk := array[MAXARGS] of {* => ""};
	argcnt = 0;
	c := nextchar();
	if(thru == 0){	# end of file was seen, so thru is done
		unput(c);
		return;
	}
	while(c != '\n' && c != EOF){
		if(c == ' ' || c == '\t'){
			c = nextchar();
			continue;
		}
		p := "";
		if(c == '"'){
			do{
				p[len p] = c;
				if((c = nextchar()) == '\\'){
					p[len p] = c;
					p[len p] = nextchar();
					c = nextchar();
				}
			}while(c != '"' && c != '\n' && c != EOF);
			p[len p] = '"';
			if(c == '"')
				c = nextchar();
		}else{
			do{
				p[len p] = c;
			}while((c = nextchar()) != ' ' && c != '\t' && c != '\n' && c != ',' && c != EOF);
			if(c == ',')
				c = nextchar();
		}
		if(argcnt < MAXARGS)
			stk[argcnt] = p;
		argcnt++;
	}
	if(c == EOF)
		fatal("unexpected end of file in do_thru");
	if(argcnt == 0){	# ignore blank line
		pushsrc(Thru, nil);
		return;
	}
	if(stk[0] == ".PE"){
		thru = 0;
		thrudef = nil;
		pushsrc(String, "\n.PE\n");
		return;
	}
	if(untilstr != nil && stk[0] == untilstr){
		thru = 0;
		thrudef = nil;
		untilstr = nil;
		return;
	}
	pushsrc(Thru, nil);
	args[ap] = Arg(stk);
	argfp = ap;
	pushsrc(Macro, thrudef.val.p);
}

unput(c: int): int
{
	if(++pb >= PBSIZE)
		fatal("pushback overflow");
	if(--ep < 0)
		ep = len ebuf - 1;
	pbuf[pb] = c;
	pushsrc(Char, nil);
	return c;
}

pbstr(s: string)
{
	pushsrc(String, s);
}

errcheck(x: real, s: string): real
{
	if(s == nil)
		return x;
	if(math->isnan(x)){
		error(s + " argument out of domain");
	}else if(x == math->Infinity || x == -math->Infinity){
		error(s + " result out of range");
	}
	return x;
}

yyerror(s: string)
{
	if(synerr)
		return;
	stdout.flush();
	errout(cmdname + ": " + s);
	errout(" near " + infile[curfile].fname + ":" + string (infile[curfile].lineno+1) + "\n");
	eprint();
	synerr = 1;
}

eprint()	# try to print context around error
{
	p := ep - 1;
	if(p > 0 && ebuf[p] == '\n')
		p--;
	for(; p >= 0 && ebuf[p] != '\n'; p--)
		;
	if(p < 0)
		p = 0;
	while(p < len ebuf && ebuf[p] == '\n')
		p++;
	s := " context is\n\t";
	q: int;
	for(q = ep - 1; q >= p && ebuf[q] != ' ' && ebuf[q] != '\t' && ebuf[q] != '\n'; q--)
		;
	while(p < q)
		s[len s] = ebuf[p++];
	s += " >>> ";
	while(p < ep)
		s[len s] = ebuf[p++];
	s += " <<< ";
	while(pb >= 0)
		s[len s] = pbuf[pb--];
	l := fgets(infile[curfile].fin, len ebuf);
	if(l != nil)
		s += l;
	errout(s);
	pbstr("\n.PE\n");	# safety first
	ep = 0;
}

newfile: string;	# filename for file copy
untilstr: string;	# string that terminates a thru
thru := 0;	# 1 if copying thru macro
thrudef: ref Sym;	# macro being used

copyfile(s: string)	# remember file to start reading from
{
	newfile = s;
}

copydef(p: ref Sym)	# remember macro symtab ptr
{
	thrudef = p;
}

copythru(s: string): ref Sym	# collect the macro name or body for thru
{
	p := lookup(s);
	if(p != nil){
		if(p.typ == DEFNAME){
			p.val.p = addnewline(p.val.p);
			return p;
		}else
			fatal(s + " used as define and name");
	}
	# have to collect the definition
	pbstr(s);	# first char is the delimiter
	q := delimstr("thru body");
	s = "nameless";
	p = lookup(s);
	if(p != nil)
		p.val.p = q;
	else{
		u: YYSTYPE;
		u.p = q;
		p = makevar(s, DEFNAME, u);
	}
	p.val.p = addnewline(p.val.p);
	return p;
}

addnewline(p: string): string	# add newline to end of p
{
	if(len p == 0 || p[len p - 1] != '\n')
		p += "\n";
	return p;
}

copyuntil(s: string)	# string that terminates a thru
{
	untilstr = s;
}

copy()	# begin input from file, etc.
{
	if(newfile != nil){
		f := bufio->open(newfile, Bufio->OREAD);
		if(f == nil)
			fatal("can't open file " + newfile);
		curfile++;
		infile[curfile] = Infile(f, newfile, 0);
		printlf(1, newfile);
		pushsrc(File, nil);
		newfile = nil;
	}
	if(thrudef != nil){
		thru = 1;
		begin = 1;	# wrong place
	}
}

# sh: not run here
shell_init()
{
}

shell_text(nil: string)
{
}

shell_exec()
{
	errout(cmdname + ": sh is not run\n");
}

#
# misc.c
#
setdir(n: int): int	# set direction (hvmode) from LEFT, RIGHT, etc.
{
	case n {
	UP =>	hvmode = U_DIR;
	DOWN =>	hvmode = D_DIR;
	LEFT =>	hvmode = L_DIR;
	RIGHT =>	hvmode = R_DIR;
	}
	return hvmode;
}

curdir(): int	# convert current dir (hvmode) to RIGHT, LEFT, etc.
{
	case hvmode {
	R_DIR =>	return RIGHT;
	L_DIR =>	return LEFT;
	U_DIR =>	return UP;
	D_DIR =>	return DOWN;
	}
	fatal("can't happen curdir");
	return 0;
}

getcomp(p: ref Obj, t: int): real	# return component of a position
{
	if(p == nil)	# a place not found (C crashes): as whatpos
		fatal("null object");
	case t {
	DOTX =>
		return p.x;
	DOTY =>
		return p.y;
	DOTWID =>
		case p.typ {
		BOX or BLOCK or TEXT =>
			return p.val[0];
		CIRCLE or ELLIPSE =>
			return 2.0 * p.val[0];
		LINE or ARROW =>
			return f32(p.val[0] - p.x);
		PLACE =>
			return 0.0;
		}
		return getcomp(p, DOTHT);
	DOTHT =>
		case p.typ {
		BOX or BLOCK or TEXT =>
			return p.val[1];
		CIRCLE or ELLIPSE =>
			return 2.0 * p.val[1];
		LINE or ARROW =>
			return f32(p.val[1] - p.y);
		PLACE =>
			return 0.0;
		}
		return getcomp(p, DOTRAD);
	DOTRAD =>
		case p.typ {
		CIRCLE or ELLIPSE =>
			return p.val[0];
		}
	}
	error("you asked for a weird dimension or position");
	return 0.0;
}

exprlist := array[100] of {* => 0.0};
nexpr := 0;

exprsave(f: real)
{
	exprlist[nexpr++] = f;
}

# C's sprintf of the format, with the expressions saved for it
sprintgen(fmt: string): string
{
	s := "";
	n := 0;
	for(i := 0; i < len fmt; i++){
		c := fmt[i];
		if(c != '%'){
			s[len s] = c;
			continue;
		}
		j := i + 1;
		while(j < len fmt && strchr("-+ #0123456789.lhL", fmt[j]) >= 0)
			j++;
		if(j >= len fmt){
			s += fmt[i:];
			break;
		}
		spec := fmt[i:j];
		v := 0.0;
		if(fmt[j] != '%' && n < 5)
			v = exprlist[n++];
		case fmt[j] {
		'%' =>
			s += "%";
		'e' or 'E' or 'f' or 'g' or 'G' =>
			s += fmtreal(spec, fmt[j], v);
		'd' or 'i' or 'c' or 'x' or 'o' or 'u' or 'X' =>
			# C passes a double where it wants an int: what it prints is
			# undefined; here, the number's integer part
			s += fmtreal(spec, 'd', v);
		's' =>
			;
		* =>
			s += fmt[i:j + 1];
		}
		i = j;
	}
	nexpr = 0;
	return s;
}

# a conversion's flags, width and precision (spec, from its %) applied to v
fmtreal(spec: string, conv: int, v: real): string
{
	i := 1;
	left := 0;
	plus := 0;
	space := 0;
	zero := 0;
	for(; i < len spec; i++){
		case spec[i] {
		'-' =>	left = 1;
		'+' =>	plus = 1;
		' ' =>	space = 1;
		'0' =>	zero = 1;
		'#' =>	;
		* =>	break;
		}
		if(spec[i] != '-' && spec[i] != '+' && spec[i] != ' ' && spec[i] != '0' && spec[i] != '#')
			break;
	}
	wid := 0;
	while(i < len spec && spec[i] >= '0' && spec[i] <= '9')
		wid = wid * 10 + spec[i++] - '0';
	prec := -1;
	if(i < len spec && spec[i] == '.'){
		i++;
		prec = 0;
		while(i < len spec && spec[i] >= '0' && spec[i] <= '9')
			prec = prec * 10 + spec[i++] - '0';
	}
	if(prec < 0)
		prec = 6;
	s: string;
	case conv {
	'f' =>	s = sys->sprint("%.*f", prec, v);
	'e' =>	s = sys->sprint("%.*e", prec, v);
	'E' =>	s = sys->sprint("%.*E", prec, v);
	'g' =>	s = cg(v, prec);
	'G' =>	s = toupper(cg(v, prec));
	* =>	s = string clong(v);
	}
	if(s != "" && s[0] != '-'){
		if(plus)
			s = "+" + s;
		else if(space)
			s = " " + s;
	}
	while(len s < wid){
		if(left)
			s += " ";
		else if(zero){
			k := 0;
			if(s != "" && (s[0] == '-' || s[0] == '+' || s[0] == ' '))
				k = 1;
			s = s[0:k] + "0" + s[k:];
		}else
			s = " " + s;
	}
	return s;
}

toupper(s: string): string
{
	for(i := 0; i < len s; i++)
		if(s[i] >= 'a' && s[i] <= 'z')
			s[i] -= 'a' - 'A';
	return s;
}

stripl(s: string): string
{
	r := "";
	for(i := 0; i < len s; i++)
		if(s[i] != 'l' && s[i] != 'h' && s[i] != 'L')
			r[len r] = s[i];
	return r;
}

strchr(s: string, c: int): int
{
	for(i := 0; i < len s; i++)
		if(s[i] == c)
			return i;
	return -1;
}

makefattr(typ: int, sub: int, f: real)	# double attr
{
	val: YYSTYPE;
	val.f = f;
	makeattr(typ, sub, val);
}

makeoattr(typ: int, o: ref Obj)	# obj* attr
{
	val: YYSTYPE;
	val.o = o;
	makeattr(typ, 0, val);
}

makeiattr(typ: int, i: int)	# int attr
{
	val: YYSTYPE;
	val.i = i;
	makeattr(typ, 0, val);
}

maketattr(sub: int, p: string)	# text attribute: takes two
{
	val: YYSTYPE;
	val.p = p;
	makeattr(TEXTATTR, sub, val);
}

addtattr(sub: int)	# add text attrib to existing item
{
	attr[nattr-1].sub |= sub;
}

makevattr(p: string)	# varname attribute
{
	val: YYSTYPE;
	val.p = p;
	makeattr(VARNAME, 0, val);
}

makeattr(typ: int, sub: int, val: YYSTYPE)	# add attribute type and val
{
	if(typ == 0 && val.i == 0){	# clear table for next stat
		nattr = 0;
		return;
	}
	if(nattr >= len attr){
		a := array[len attr + 100] of Attr;
		a[0:] = attr;
		attr = a;
	}
	attr[nattr].typ = typ;
	attr[nattr].sub = sub;
	attr[nattr].val = val;
	nattr++;
}

printexpr(f: real)	# print expression for debugging
{
	out(g(f) + "\n");
}

printpos(p: ref Obj)	# print position for debugging
{
	out(g(p.x) + ", " + g(p.y) + "\n");
}

makepos(x: real, y: real): ref Obj	# make a position cell
{
	p := makenode(PLACE, 0);
	p.x = f32(x);
	p.y = f32(y);
	return p;
}

makebetween(f: real, p1: ref Obj, p2: ref Obj): ref Obj	# make position between p1 and p2
{
	p := makenode(PLACE, 0);
	# C's float - float is a float
	p.x = f32(p1.x + f * f32(p2.x - p1.x));
	p.y = f32(p1.y + f * f32(p2.y - p1.y));
	return p;
}

getpos(p: ref Obj, corner: int): ref Obj	# find position of point
{
	(x, y) := whatpos(p, corner);
	return makepos(x, y);
}

whatpos(p: ref Obj, corner: int): (real, real)	# what is the position (no side effect)
{
	x1, y1: real;
	if(p == nil)
		fatal("null object");
	x := p.x;
	y := p.y;
	if(p.typ != PLACE && p.typ != MOVE){
		x1 = p.val[0];
		y1 = p.val[1];
	}
	case p.typ {
	PLACE =>
		;
	BOX or BLOCK or TEXT =>
		case corner {
		NORTH =>	y += y1 / 2.0;
		SOUTH =>	y -= y1 / 2.0;
		EAST =>	x += x1 / 2.0;
		WEST =>	x -= x1 / 2.0;
		NE =>	x += x1 / 2.0; y += y1 / 2.0;
		SW =>	x -= x1 / 2.0; y -= y1 / 2.0;
		SE =>	x += x1 / 2.0; y -= y1 / 2.0;
		NW =>	x -= x1 / 2.0; y += y1 / 2.0;
		START =>
			if(p.typ == BLOCK)
				return whatpos(objlist[int p.val[2]], START);
			if(p.typ == BLOCK)
				return whatpos(objlist[int p.val[3]], END);
		END =>
			if(p.typ == BLOCK)
				return whatpos(objlist[int p.val[3]], END);
		}
	ARC or CIRCLE or ELLIPSE =>
		if(p.typ == ARC){
			case corner {
			START =>
				if(p.attr & CW_ARC){
					x = p.val[2]; y = p.val[3];
				}else{
					x = x1; y = y1;
				}
			END =>
				if(p.attr & CW_ARC){
					x = x1; y = y1;
				}else{
					x = p.val[2]; y = p.val[3];
				}
			}
			if(corner == START || corner == END)
				break;
			x1 = y1 = math->sqrt((x1-x)*(x1-x) + (y1-y)*(y1-y));
			# Fall Through!
		}
		case corner {
		NORTH =>	y += y1;
		SOUTH =>	y -= y1;
		EAST =>	x += x1;
		WEST =>	x -= x1;
		NE =>	x += 0.707 * x1; y += 0.707 * y1;
		SE =>	x += 0.707 * x1; y -= 0.707 * y1;
		NW =>	x -= 0.707 * x1; y += 0.707 * y1;
		SW =>	x -= 0.707 * x1; y -= 0.707 * y1;
		}
	LINE or SPLINE or ARROW =>
		case corner {
		START =>	;	# already in place
		END =>	x = x1; y = y1;
		NORTH =>	if(y1 > y){ x = x1; y = y1; }
		SOUTH =>	if(y1 < y){ x = x1; y = y1; }
		EAST =>	if(x1 > x){ x = x1; y = y1; }
		WEST =>	if(x1 < x){ x = x1; y = y1; }
		* =>	# CENTER, and others: change!
			x = (x+x1)/2.0; y = (y+y1)/2.0;
		}
	MOVE =>
		# really ought to be same as line...
		;
	}
	return (x, y);
}

gethere(): ref Obj	# make a place for curx,cury
{
	return makepos(curx, cury);
}

getlast(n: int, t: int): ref Obj	# find n-th previous occurrence of type t
{
	k := n;
	for(i := nobj-1; i >= 0; i--){
		p := objlist[i];
		if(p.typ == BLOCKEND){
			i = cint(p.val[4]);
			continue;
		}
		if(p.typ != t)
			continue;
		if(--k > 0)
			continue;	# not there yet
		return p;
	}
	fatal(sys->sprint("there is no %dth last", n));
	return nil;
}

getfirst(n: int, t: int): ref Obj	# find n-th occurrence of type t
{
	k := n;
	for(i := 0; i < nobj; i++){
		p := objlist[i];
		if(p.typ == BLOCK && t != BLOCK){	# skip whole block
			# one still open (we are in it) has no end yet: C
			# went back to it for ever; look in it instead
			if(p.val[5] >= 0.0)
				i = cint(p.val[5] + 1.0);
			continue;
		}
		if(p.typ != t)
			continue;
		if(--k > 0)
			continue;	# not there yet
		return p;
	}
	fatal(sys->sprint("there is no %dth ", n));
	return nil;
}

getblkvar(p: ref Obj, s: string): real	# find variable s2 in block p
{
	v := getblk(p, s);
	return v.f;
}

getblock(p: ref Obj, s: string): ref Obj	# find variable s in block p
{
	v := getblk(p, s);
	return v.o;
}

bug: YYSTYPE;

getblk(p: ref Obj, s: string): YYSTYPE	# find union type for s in p
{
	if(p.typ != BLOCK){
		error("." + s + " is not in that block");
		return bug;
	}
	for(stp := p.symtab; stp != nil; stp = stp.next)
		if(s == stp.name)
			return stp.val;
	error("there is no ." + s + " in that []");
	return bug;
}

fixpos(p: ref Obj, x: real, y: real): ref Obj
{
	return makepos(p.x + x, p.y + y);
}

addpos(p: ref Obj, q: ref Obj): ref Obj
{
	return makepos(f32(p.x+q.x), f32(p.y+q.y));
}

subpos(p: ref Obj, q: ref Obj): ref Obj
{
	return makepos(f32(p.x-q.x), f32(p.y-q.y));
}

makenode(typ: int, n: int): ref Obj
{
	m := n;
	if(m < 8)
		m = 8;
	p := ref Obj(typ, n, nobj, hvmode, f32(curx), f32(cury), ntext1, ntext,
		0, 0, 0, nil, 0.0, 0.0, array[m] of {* => 0.0});
	ntext1 = ntext;	# ready for next caller
	if(nobj >= len objlist){
		o := array[2 * len objlist] of ref Obj;
		o[0:] = objlist;
		objlist = o;
	}
	objlist[nobj++] = p;
	return p;
}

extreme(x: real, y: real)	# record max and min x and y values
{
	if(x > xmax)
		xmax = x;
	if(y > ymax)
		ymax = y;
	if(x < xmin)
		xmin = x;
	if(y < ymin)
		ymin = y;
}

error(s: string)
{
	if(len s > 199)
		s = s[0:199];
	yyerror(s);
}

fatal(s: string)
{
	if(len s > 199)
		s = s[0:199];
	yyerror(s);
	stdout.flush();
	raise "fail:fatal";
}

#
# symtab.c
#
getvar(s: string): YYSTYPE	# return value of variable s (usually pointer)
{
	p := lookup(s);
	if(p == nil){
		if(islower(at(s, 0)))
			error("no such variable as " + s);
		else
			error("no such place as " + s);
		return bug;
	}
	return p.val;
}

getfval(s: string): real	# return float value of variable s
{
	v := getvar(s);
	return v.f;
}

setfval(s: string, f: real)	# set variable s to f
{
	if((p := lookup(s)) != nil)
		p.val.f = f;
}

makevar(s: string, t: int, v: YYSTYPE): ref Sym	# make variable named s in table
{
	p: ref Sym;
	for(p = stack[nstack].symtab; p != nil; p = p.next)
		if(s == p.name)
			break;
	if(p == nil){	# it's a new one
		p = ref Sym(nil, 0, v, stack[nstack].symtab);
		stack[nstack].symtab = p;	# stick it at front
	}
	p.name = s;
	p.typ = t;
	p.val = v;
	return p;
}

lookup(s: string): ref Sym	# find s in symtab
{
	for(i := nstack; i >= 0; i--)	# look in each active symtab
		for(p := stack[i].symtab; p != nil; p = p.next)
			if(s == p.name)
				return p;
	return nil;
}

freedef(s: string)	# free definition for string s
{
	q: ref Sym;
	for(p := stack[nstack].symtab; p != nil; p = p.next){
		if(s == p.name){	# got it
			if(p.typ != DEFNAME)
				break;
			if(q == nil)	# 1st elem
				stack[nstack].symtab = p.next;
			else
				q.next = p.next;
			return;
		}
		q = p;
	}
}

#
# for.c
#
SLOP: con 1.001;

For: adt {
	var:	string;	# index variable
	tov:	real;	# limit
	by:	real;
	op:	int;	# operator
	str:	string;	# string to push back
};

forstk := array[10] of For;	# stack of for loops
forp := 0;	# pointer to current top

forloop(var: string, from: real, tov: real, op: int, by: real, str: string)	# set up a for loop
{
	if(++forp >= len forstk)
		fatal("for loop nested too deep");
	forstk[forp] = For(var, tov, by, op, str);
	setfval(var, from);
	nextfor();
	unput('\n');
}

nextfor()	# do one iteration of a for loop
{
	# BUG:  this should depend on op and direction
	if(getfval(forstk[forp].var) > SLOP * forstk[forp].tov){	# loop is done
		if(--forp < 0)
			fatal("forstk popped too far");
	}else{	# another iteration
		pushsrc(String, "\nEndfor\n");
		pushsrc(String, forstk[forp].str);
	}
}

endfor()	# end one iteration of for loop
{
	p := lookup(forstk[forp].var);
	case forstk[forp].op {
	'+' or ' ' =>
		p.val.f += forstk[forp].by;
	'-' =>
		p.val.f -= forstk[forp].by;
	'*' =>
		p.val.f *= forstk[forp].by;
	'/' =>
		p.val.f /= forstk[forp].by;
	}
	nextfor();
}

ifstat(expr: real, thenpart: string, elsepart: string): string
{
	if(expr != 0.0){
		unput('\n');
		pushsrc(Free, thenpart);
		pushsrc(String, thenpart);
		unput('\n');
		return thenpart;	# to be freed later
	}else{
		if(elsepart != NULLP){
			unput('\n');
			pushsrc(Free, elsepart);
			pushsrc(String, elsepart);
			unput('\n');
		}
		return elsepart;
	}
}
