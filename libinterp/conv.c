#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "mathi.h"

enum
{
	TOKI0,
	TOKI1,
	TOKI2,
	TOKI3,
	TOKSB,
	TOKFP
};
#include "tab.h"

typedef struct Addr	Addr;
struct Addr
{
	uchar	mode;
	Adr	a;
};

#pragma	varargck	type	"a"	Addr*

char*	opnam[256];
int	iconv(Fmt*);
int	aconv(Fmt*);

int
aconv(Fmt *f)
{
	Addr *a;
	char buf[64];

	a = va_arg(f->args, Addr*);
	if(a == nil)
		return fmtstrcpy(f, "AZ");
	switch(a->mode & AMASK) {
	case AFP:	snprint(buf, sizeof buf, "%d(fp)", (int)a->a.ind);	break;
	case AMP:	snprint(buf, sizeof buf, "%d(mp)", (int)a->a.ind);	break;
	case AIMM:	snprint(buf, sizeof buf, "$%d", (int)a->a.imm);		break;
	case AIND|AFP:	snprint(buf, sizeof buf, "%d(%d(fp))", a->a.i.s, a->a.i.f); break;
	case AIND|AMP:	snprint(buf, sizeof buf, "%d(%d(mp))", a->a.i.s, a->a.i.f); break;
	default:
		/* a mode that is none (3, 6, 7): buf was copied as the stack had left it */
		snprint(buf, sizeof buf, "mode%d", a->mode & AMASK);
		break;
	}
	return fmtstrcpy(f, buf);
}

/*
 * An instruction as text, whatever its bytes are: the code generators
 * name one they refuse, which is any byte of a file, and a debugger
 * reads them through /prog at an address of its choosing.  The opcode
 * indexed keywds and opnam unchecked (keywds has MAXDIS entries, an
 * opcode 256 values), and an opcode or address mode with no arm below
 * left buf as the stack had it, which went into the string.
 */
int
Dconv(Fmt *f)
{
	int j;
	Inst *i;
	Addr s, d;
	char *name;
	char buf[128];
	static int init;

	if(init == 0) {
		for(j = 0; keywds[j].name != nil; j++)
			opnam[keywds[j].op] = keywds[j].name;

		fmtinstall('a', aconv);
		init = 1;
	}

	i = va_arg(f->args, Inst*);
	if(i == nil)
		return fmtstrcpy(f, "IZ");

	if(i->op >= nelem(keywds)-1 || keywds[i->op].op != i->op || (name = opnam[i->op]) == nil) {
		snprint(buf, sizeof buf, "op%d", i->op);
		return fmtstrcpy(f, buf);
	}

	switch(keywds[i->op].terminal) {
	default:
		snprint(buf, sizeof buf, "%s", name);
		break;
	case TOKI0:
		snprint(buf, sizeof buf, "%s", name);
		break;
	case TOKI1:
		d.a = i->d;
		d.mode = UDST(i->add);
		snprint(buf, sizeof buf, "%s\t%a", name, &d);
		break;
	case TOKI3:
		d.a = i->d;
		d.mode = UDST(i->add);
		s.a = i->s;
		s.mode = USRC(i->add);
		switch(i->add&ARM) {
		default:
			snprint(buf, sizeof buf, "%s\t%a, %a", name, &s, &d);
			break;
		case AXIMM:
			snprint(buf, sizeof buf, "%s\t%a, $%d, %a", name, &s, i->reg, &d);
			break;
		case AXINF:
			snprint(buf, sizeof buf, "%s\t%a, %d(fp), %a", name, &s, i->reg, &d);
			break;
		case AXINM:
			snprint(buf, sizeof buf, "%s\t%a, %d(mp), %a", name, &s, i->reg, &d);
			break;
		}
		break;
	case TOKI2:
		d.a = i->d;
		d.mode = UDST(i->add);
		s.a = i->s;
		s.mode = USRC(i->add);
		snprint(buf, sizeof buf, "%s\t%a, %a", name, &s, &d);
		break;
	}

	return fmtstrcpy(f, buf);
}

