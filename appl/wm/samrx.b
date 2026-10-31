implement Samrx;

#
# Sam's regular expression machine, over a rune string.  A port of
# acme's regx.b (itself Plan 9 sam's regexp.c) with the Text plumbing
# taken out, so the sam engine can search its buffers with sam's own
# semantics.
#

include "sys.m";
	sys: Sys;

include "samrx.m";

Range: adt {
	q0:	int;
	q1:	int;
};

Rangeset: type array of Range;

Inst: adt {
	typex:	int;		# < 16r10000 ==> literal, otherwise action
	subid:	int;
	class:	int;
	right:	cyclic ref Inst;
	next:	cyclic ref Inst;
};

Node: adt {
	first:	ref Inst;
	last:	ref Inst;
};

Ilist: adt {
	inst:	ref Inst;	# instruction of the thread
	se:	Rangeset;
	startp:	int;		# first char of match
};

NPROG:	con 1024;
NLIST:	con 128;
NSTACK:	con 20;
DCLASS:	con 10;

#
# Actions and Tokens
#
#	0x100xx are operators, value == precedence
#	0x200xx are tokens, i.e. operands for operators
#
OPERATOR:	con 16r10000;	# bitmask of all operators
START:	con 16r10000;	# start, used for marker on stack
RBRA:	con 16r10001;	# right bracket, )
LBRA:	con 16r10002;	# left bracket, (
OR:	con 16r10003;	# alternation, |
CAT:	con 16r10004;	# concatenation, implicit operator
STAR:	con 16r10005;	# closure, *
PLUS:	con 16r10006;	# a+ == aa*
QUEST:	con 16r10007;	# a? == a|nothing, i.e. 0 or 1 a's
ANY:	con 16r20000;	# any character but newline, .
NOP:	con 16r20001;	# no operation, internal use only
BOL:	con 16r20002;	# beginning of line, ^
EOL:	con 16r20003;	# end of line, $
CCLASS:	con 16r20004;	# character class, []
NCCLASS:	con 16r20005;	# negated character class, [^]
END:	con 16r20077;	# terminate: match found

ISATOR:	con 16r10000;
QUOTED:	con 16r40000000;	# escaped character inside []

REGERR:	con "regerror";
OVERFLOW:	con "overflow";

program := array[NPROG] of ref Inst;
progp: int;
startinst: ref Inst;		# first inst. of program; might not be program[0]
bstartinst: ref Inst;		# same for backwards machine

thl, nl: array of Ilist;	# this list, next list
listx := array[2] of array of Ilist;
sempty: Rangeset;
sel: Rangeset;

andstack := array[NSTACK] of ref Node;
andp: int;
atorstack := array[NSTACK] of int;
atorp: int;
lastwasand: int;	# last token was operand
cursubid: int;
subidstack := array[NSTACK] of int;
subidp: int;
backwards: int;
nbra: int;
exprs: string;
exprp: int;		# next character in source expression
nclass: int;		# number active
Nclass := 0;		# high water mark
class: array of string;
negateclass: int;
errstr: string;

init()
{
	sys = load Sys Sys->PATH;
	sempty = array[NRange] of Range;
	sel = array[NRange] of Range;
	for(k := 0; k < NPROG; k++)
		program[k] = ref Inst(0, 0, 0, nil, nil);
	for(k = 0; k < NSTACK; k++)
		andstack[k] = ref Node(nil, nil);
	for(k = 0; k < 2; k++){
		listx[k] = array[NLIST] of Ilist;
		for(i := 0; i < NLIST; i++){
			listx[k][i].inst = nil;
			listx[k][i].startp = 0;
			listx[k][i].se = array[NRange] of Range;
		}
	}
}

regerror(e: string)
{
	errstr = e;
	raise REGERR;
}

newinst(t: int): ref Inst
{
	if(progp >= NPROG)
		regerror("expression too long");
	program[progp].typex = t;
	program[progp].next = nil;
	program[progp].right = nil;
	return program[progp++];
}

realcompile(s: string): ref Inst
{
	startlex(s);
	atorp = 0;
	andp = 0;
	subidp = 0;
	cursubid = 0;
	lastwasand = 0;
	# start with a low priority operator to prime parser
	pushator(START-1);
	while((token := lex()) != END){
		if((token&ISATOR) == OPERATOR)
			operator(token);
		else
			operand(token);
	}
	# close with a low priority operator
	evaluntil(START);
	# force END
	operand(END);
	evaluntil(START);
	if(nbra)
		regerror("unmatched `('");
	--andp;	# points to first and only operand
	return andstack[andp].first;
}

compile(r: string): string
{
	for(i := 0; i < nclass; i++)
		class[i] = nil;
	nclass = 0;
	progp = 0;
	errstr = nil;
	{
		backwards = 0;
		startinst = realcompile(r);
		optimize(0);
		oprogp := progp;
		backwards = 1;
		bstartinst = realcompile(r);
		optimize(oprogp);
	} exception {
	REGERR =>
		startinst = bstartinst = nil;
		return errstr;
	}
	return nil;
}

operand(t: int)
{
	if(lastwasand)
		operator(CAT);	# catenate is implicit
	i := newinst(t);
	if(t == CCLASS){
		if(negateclass)
			i.typex = NCCLASS;
		i.class = nclass-1;
	}
	pushand(i, i);
	lastwasand = 1;
}

operator(t: int)
{
	if(t == RBRA && --nbra < 0)
		regerror("unmatched `)'");
	if(t == LBRA){
		cursubid++;	# silently ignored past NRange
		nbra++;
		if(lastwasand)
			operator(CAT);
	}else
		evaluntil(t);
	if(t != RBRA)
		pushator(t);
	lastwasand = 0;
	if(t == STAR || t == QUEST || t == PLUS || t == RBRA)
		lastwasand = 1;	# these look like operands
}

pushand(f: ref Inst, l: ref Inst)
{
	if(andp >= NSTACK)
		regerror("operand stack overflow");
	andstack[andp].first = f;
	andstack[andp].last = l;
	andp++;
}

pushator(t: int)
{
	if(atorp >= NSTACK)
		regerror("operator stack overflow");
	atorstack[atorp++] = t;
	if(cursubid >= NRange)
		subidstack[subidp++] = -1;
	else
		subidstack[subidp++] = cursubid;
}

popand(op: int): ref Node
{
	if(andp <= 0){
		if(op)
			regerror(sys->sprint("missing operand for %c", op));
		regerror("malformed regexp");
	}
	return andstack[--andp];
}

popator(): int
{
	if(atorp <= 0)
		regerror("operator stack underflow");
	--subidp;
	return atorstack[--atorp];
}

evaluntil(pri: int)
{
	op1, op2: ref Node;
	inst1, inst2: ref Inst;

	while(pri == RBRA || atorstack[atorp-1] >= pri){
		case popator() {
		LBRA =>
			op1 = popand('(');
			inst2 = newinst(RBRA);
			inst2.subid = subidstack[subidp];
			op1.last.next = inst2;
			inst1 = newinst(LBRA);
			inst1.subid = subidstack[subidp];
			inst1.next = op1.first;
			pushand(inst1, inst2);
			return;		# must have been RBRA
		OR =>
			op2 = popand('|');
			op1 = popand('|');
			inst2 = newinst(NOP);
			op2.last.next = inst2;
			op1.last.next = inst2;
			inst1 = newinst(OR);
			inst1.right = op1.first;
			inst1.next = op2.first;
			pushand(inst1, inst2);
		CAT =>
			op2 = popand(0);
			op1 = popand(0);
			if(backwards && op2.first.typex != END)
				(op1, op2) = (op2, op1);
			op1.last.next = op2.first;
			pushand(op1.first, op2.last);
		STAR =>
			op2 = popand('*');
			inst1 = newinst(OR);
			op2.last.next = inst1;
			inst1.right = op2.first;
			pushand(inst1, inst1);
		PLUS =>
			op2 = popand('+');
			inst1 = newinst(OR);
			op2.last.next = inst1;
			inst1.right = op2.first;
			pushand(op2.first, inst1);
		QUEST =>
			op2 = popand('?');
			inst1 = newinst(OR);
			inst2 = newinst(NOP);
			inst1.next = inst2;
			inst1.right = op2.first;
			op2.last.next = inst2;
			pushand(inst1, inst2);
		* =>
			regerror("unknown regexp operator");
		}
	}
}

optimize(start: int)
{
	for(inst := start; program[inst].typex != END; inst++){
		target := program[inst].next;
		while(target.typex == NOP)
			target = target.next;
		program[inst].next = target;
	}
}

startlex(s: string)
{
	exprs = s;
	exprp = 0;
	nbra = 0;
}

lex(): int
{
	if(exprp == len exprs)
		return END;
	c := exprs[exprp++];
	case c {
	'\\' =>
		if(exprp < len exprs)
			if((c = exprs[exprp++]) == 'n')
				c = '\n';
	'*' =>
		c = STAR;
	'?' =>
		c = QUEST;
	'+' =>
		c = PLUS;
	'|' =>
		c = OR;
	'.' =>
		c = ANY;
	'(' =>
		c = LBRA;
	')' =>
		c = RBRA;
	'^' =>
		c = BOL;
	'$' =>
		c = EOL;
	'[' =>
		c = CCLASS;
		bldcclass();
	}
	return c;
}

nextrec(): int
{
	if(exprp == len exprs || (exprp == len exprs-1 && exprs[exprp] == '\\'))
		regerror("malformed `[]'");
	if(exprs[exprp] == '\\'){
		exprp++;
		if(exprs[exprp] == 'n'){
			exprp++;
			return '\n';
		}
		return exprs[exprp++] | QUOTED;
	}
	return exprs[exprp++];
}

bldcclass()
{
	classp: string;

	# we have already seen the '['
	if(exprp < len exprs && exprs[exprp] == '^'){
		classp[len classp] = '\n';	# don't match newline in negate case
		negateclass = 1;
		exprp++;
	}else
		negateclass = 0;
	while((c1 := nextrec()) != ']'){
		if(c1 == '-')
			regerror("malformed `[]'");
		if(exprp < len exprs && exprs[exprp] == '-'){
			exprp++;	# eat '-'
			c2 := nextrec();
			if(c2 == ']')
				regerror("malformed `[]'");
			classp[len classp] = 16rFFFF;
			classp[len classp] = c1 & ~QUOTED;
			classp[len classp] = c2 & ~QUOTED;
		}else
			classp[len classp] = c1 & ~QUOTED;
	}
	if(nclass == Nclass){
		Nclass += DCLASS;
		oc := class;
		class = array[Nclass] of string;
		if(oc != nil)
			class[0:] = oc[0:Nclass-DCLASS];
	}
	class[nclass++] = classp;
}

classmatch(classno: int, c: int, negate: int): int
{
	p := class[classno];
	for(i := 0; i < len p; ){
		if(p[i] == 16rFFFF){
			if(p[i+1] <= c && c <= p[i+2])
				return !negate;
			i += 3;
		}else if(p[i++] == c)
			return !negate;
	}
	return negate;
}

#
# Note optimization in addinst:
#	l[0] must be pending when addinst called; if it has been looked
#	at already, the optimization is a bug.
#
addinst(l: array of Ilist, inst: ref Inst, sep: Rangeset)
{
	p: int;

	for(p = 0; l[p].inst != nil; p++){
		if(l[p].inst == inst){
			if(sep[0].q0 < l[p].se[0].q0)
				l[p].se[0:] = sep[0:NRange];
			return;	# it's already there
		}
	}
	l[p].inst = inst;
	l[p].se[0:] = sep[0:NRange];
	l[p+1].inst = nil;
}

result(ok: int): array of (int, int)
{
	if(!ok || sel[0].q0 < 0)
		return nil;
	m := array[NRange] of (int, int);
	for(i := 0; i < NRange; i++)
		m[i] = (sel[i].q0, sel[i].q1);
	return m;
}

execute(r: string, startp: int, eof: int): array of (int, int)
{
	if(startinst == nil)
		return nil;
	flag := 0;
	p := startp;
	startchar := 0;
	wrapped := 0;
	nnl := 0;
	c: int;
	if(startinst.typex < OPERATOR)
		startchar = startinst.typex;
	listx[0][0].inst = listx[1][0].inst = nil;
	sel[0].q0 = -1;
	nc := len r;
	{
		# execute machine once for each character
		for(;; p++){
			if(p >= eof || p >= nc){
				case wrapped++ {
				0 or 2 =>	# let loop run one more click
					;
				1 =>		# expired; wrap to beginning
					if(sel[0].q0 >= 0 || eof != Infinity)
						return result(1);
					listx[0][0].inst = listx[1][0].inst = nil;
					p = -1;
					continue;
				* =>
					return result(1);
				}
				c = 0;
			}else{
				if(((wrapped && p >= startp) || sel[0].q0 > 0) && nnl == 0)
					break;
				c = r[p];
			}
			# fast check for first char
			if(startchar && nnl == 0 && c != startchar)
				continue;
			thl = listx[flag];
			nl = listx[flag ^= 1];
			nl[0].inst = nil;
			ntl := nnl;
			nnl = 0;
			if(sel[0].q0 < 0 && (!wrapped || p < startp || startp == eof)){
				# add first instruction to this list
				if(++ntl >= NLIST)
					raise OVERFLOW;
				sempty[0].q0 = p;
				addinst(thl, startinst, sempty);
			}
			# execute machine until this list is empty
			tlp := 0;
			inst := thl[0].inst;
			while(inst != nil){
				case inst.typex {
				LBRA =>
					if(inst.subid >= 0)
						thl[tlp].se[inst.subid].q0 = p;
					inst = inst.next;
					continue;
				RBRA =>
					if(inst.subid >= 0)
						thl[tlp].se[inst.subid].q1 = p;
					inst = inst.next;
					continue;
				ANY =>
					if(c != '\n' && c != 0){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				BOL =>
					if(p == 0 || (p <= nc && r[p-1] == '\n')){
						inst = inst.next;
						continue;
					}
				EOL =>
					if(c == '\n' || p >= nc){
						inst = inst.next;
						continue;
					}
				CCLASS =>
					if(c > 0 && classmatch(inst.class, c, 0)){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				NCCLASS =>
					if(c > 0 && classmatch(inst.class, c, 1)){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				OR =>
					# evaluate right choice later
					if(++ntl >= NLIST)
						raise OVERFLOW;
					addinst(thl[tlp:], inst.right, thl[tlp].se);
					# efficiency: advance and re-evaluate
					inst = inst.next;
					continue;
				END =>		# match!
					thl[tlp].se[0].q1 = p;
					newmatch(thl[tlp].se);
				* =>		# regular character
					if(inst.typex == c && c != 0){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				}
				tlp++;
				inst = thl[tlp].inst;
			}
		}
		return result(1);
	} exception {
	OVERFLOW =>
		return nil;
	}
}

newmatch(sp: Rangeset)
{
	if(sel[0].q0 < 0 || sp[0].q0 < sel[0].q0 ||
	   (sp[0].q0 == sel[0].q0 && sp[0].q1 > sel[0].q1))
		sel[0:] = sp[0:NRange];
}

bexecute(r: string, startp: int): array of (int, int)
{
	if(bstartinst == nil)
		return nil;
	flag := 0;
	nnl := 0;
	wrapped := 0;
	p := startp;
	startchar := 0;
	c: int;
	nc := len r;
	if(bstartinst.typex < OPERATOR)
		startchar = bstartinst.typex;
	listx[0][0].inst = listx[1][0].inst = nil;
	sel[0].q0 = -1;
	{
		# execute machine once for each character, including terminal NUL
		for(;; --p){
			if(p <= 0){
				case wrapped++ {
				0 or 2 =>	# let loop run one more click
					;
				1 =>		# expired; wrap to end
					if(sel[0].q0 >= 0)
						return result(1);
					listx[0][0].inst = listx[1][0].inst = nil;
					p = nc+1;
					continue;
				* =>
					return result(1);
				}
				c = 0;
			}else{
				if(((wrapped && p <= startp) || sel[0].q0 > 0) && nnl == 0)
					break;
				if(p-1 < nc)
					c = r[p-1];
				else
					c = 0;
			}
			# fast check for first char
			if(startchar && nnl == 0 && c != startchar)
				continue;
			thl = listx[flag];
			nl = listx[flag ^= 1];
			nl[0].inst = nil;
			ntl := nnl;
			nnl = 0;
			if(sel[0].q0 < 0 && (!wrapped || p > startp)){
				# add first instruction to this list
				if(++ntl >= NLIST)
					raise OVERFLOW;
				# the minus is so the optimizations in addinst work
				sempty[0].q0 = -p;
				addinst(thl, bstartinst, sempty);
			}
			# execute machine until this list is empty
			tlp := 0;
			inst := thl[0].inst;
			while(inst != nil){
				case inst.typex {
				LBRA =>
					if(inst.subid >= 0)
						thl[tlp].se[inst.subid].q0 = p;
					inst = inst.next;
					continue;
				RBRA =>
					if(inst.subid >= 0)
						thl[tlp].se[inst.subid].q1 = p;
					inst = inst.next;
					continue;
				ANY =>
					if(c != '\n' && c != 0){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				BOL =>
					if(c == '\n' || p == 0){
						inst = inst.next;
						continue;
					}
				EOL =>
					if(p >= nc || r[p] == '\n'){
						inst = inst.next;
						continue;
					}
				CCLASS =>
					if(c > 0 && classmatch(inst.class, c, 0)){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				NCCLASS =>
					if(c > 0 && classmatch(inst.class, c, 1)){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				OR =>
					# evaluate right choice later
					if(++ntl >= NLIST)
						raise OVERFLOW;
					addinst(thl[tlp:], inst.right, thl[tlp].se);
					# efficiency: advance and re-evaluate
					inst = inst.next;
					continue;
				END =>		# match!
					thl[tlp].se[0].q0 = -thl[tlp].se[0].q0;	# minus sign
					thl[tlp].se[0].q1 = p;
					bnewmatch(thl[tlp].se);
				* =>		# regular character
					if(inst.typex == c && c != 0){
						if(++nnl >= NLIST)
							raise OVERFLOW;
						addinst(nl, inst.next, thl[tlp].se);
					}
				}
				tlp++;
				inst = thl[tlp].inst;
			}
		}
		return result(1);
	} exception {
	OVERFLOW =>
		return nil;
	}
}

bnewmatch(sp: Rangeset)
{
	if(sel[0].q0 < 0 || sp[0].q0 > sel[0].q1 || (sp[0].q0 == sel[0].q1 && sp[0].q1 < sel[0].q0))
		for(i := 0; i < NRange; i++){	# note the reversal; q0 <= q1
			sel[i].q0 = sp[i].q1;
			sel[i].q1 = sp[i].q0;
		}
}
