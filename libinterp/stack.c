#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include <pool.h>

#define T(r)	*((void**)(R.r))

void
newstack(Prog *p)
{
	int l;
	Type *t;
	Frame *f;
	Stkext *ns;

	f = T(s);

	t = f->t;
	if(t == nil)
		t = SEXTYPE(f)->reg.TR;

	f->lr = nil;
	f->mr = nil;
	f->fp = nil;
	l = p->R.M->m->ss;
	/* room for Stkext's record keeping, before the frame: four
	 * pointers, 32 bytes on a 64-bit host (16 was a 32-bit host's) */
	if(l < OA(Stkext, reg.tos.fu)+t->size)
		l = OA(Stkext, reg.tos.fu)+t->size;
	ns = mallocz(l, 0);
	if(ns == nil)
		error(exNomem);

	ns->reg.TR = t;
	ns->reg.SP = nil;
	ns->reg.TS = nil;
	ns->reg.EX = nil;
	p->R.EX = ns->stack;
	p->R.TS = ns->stack + l;
	p->R.SP = ns->reg.tos.fu + t->size;
	p->R.FP = ns->reg.tos.fu;

	memmove(p->R.FP, f, t->size);
	f = (Frame*)p->R.FP;
	f->t = nil;
}

void
extend(void)
{
	int l;
	Type *t;
	Frame *f;
	Stkext *ns;

	t = R.s;
	l = R.M->m->ss;
	/* room for Stkext's record keeping, as in newstack */
	if(l < OA(Stkext, reg.tos.fu)+t->size)
		l = 2*t->size+OA(Stkext, reg.tos.fu);
	ns = mallocz(l, 0);
	if(ns == nil)
		error(exNomem);

	ns->reg.TR = t;
	ns->reg.SP = R.SP;
	ns->reg.TS = R.TS;
	ns->reg.EX = R.EX;
	f = ns->reg.tos.fr;
	f->t  = nil;
	f->mr = nil;
	R.s = f;
	R.EX = ns->stack;
	R.TS = ns->stack + l;
	R.SP = ns->reg.tos.fu + t->size;

	if (t->np)
		initmem(t, f);
}

void
unextend(Frame *f)
{
	Stkext *sx;
	Type *t;

	sx = SEXTYPE(f);
	R.SP = sx->reg.SP;
	R.TS = sx->reg.TS;
	R.EX = sx->reg.EX;
	t = sx->reg.TR;
	if (t->np)
		freeptrs(f, t);
	free(sx);
}

void
unframe(void)
{
	Type *t;
	Frame *f;
	Stkext *sx;

	f = (Frame*)R.FP;
	t = f->t;
	if(t == nil)
		t = SEXTYPE(f)->reg.TR;

	R.SP = R.FP+t->size;

	f = T(s);
	if(f->t == nil) {
		sx = SEXTYPE(f);
		R.TS = sx->reg.TS;
		R.EX = sx->reg.EX;
		free(sx);
	}
}
