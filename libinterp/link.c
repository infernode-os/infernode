#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include <kernel.h>

static void
newlink(Link *l, char *fn, int sig, Type *t)
{
	int n;

	n = strlen(fn)+1;
	l->name = malloc(n);
	if(l->name == nil)
		error(exNomem);
	memmove(l->name, fn, n);
	l->sig = sig;
	l->frame = t;
	l->dig = nil;
}

/*
 * dig is the table's own, which is never freed
 */
void
runtime(Module *m, Link *l, char *fn, int sig, uchar *dig, void (*runt)(void*), Type *t)
{
	USED(m);
	newlink(l, fn, sig, t);
	l->dig = dig;
	l->u.runt = runt;
}

void
mlink(Module *m, Link* l, uchar *fn, int sig, int pc, Type *t)
{
	newlink(l, (char*)fn, sig, t);
	l->u.pc = m->prog+pc;
}

static int
linkm(Module *m, Modlink *ml, int i, Import *ldt)
{
	Link *l;
	int sig;
	char e[ERRMAX];

	sig = ldt->sig;
	for(l = m->ext; l->name; l++)
		if(strcmp(ldt->name, l->name) == 0)
			break;

	/* the loop ends on the nil-name terminator, never a nil l */
	if(l->name == nil) {
		snprint(e, sizeof(e), "link failed fn %s->%s() not implemented", m->name, ldt->name);
		goto bad;
	}
	if(l->sig != sig) {
		snprint(e, sizeof(e), "link typecheck %s->%s() %ux/%ux",
							m->name, ldt->name, l->sig, sig);
		goto bad;
	}

	ml->links[i].u = l->u;
	ml->links[i].frame = l->frame;
	return 0;
bad:
	/* the error reaches the caller via errstr; a console print here
	 * turns every intentional load-typecheck probe (e.g. Matrix's
	 * optional-interface discovery) into alarming noise */
	kwerrstr(e);
	return -1;
}

/* H if there is no memory for it */
static Modlink*
mklinkmodok(Module *m, int n)
{
	Heap *h;
	Modlink *ml;

	h = nheapok(sizeof(Modlink)+(n-1)*sizeof(ml->links[0]));
	if(h == nil)
		return H;
	h->t = &Tmodlink;
	Tmodlink.ref++;
	ml = H2D(Modlink*, h);
	ml->nlinks = n;
	ml->m = m;
	ml->prog = m->prog;
	ml->type = m->type;
	ml->compiled = m->compiled;
	ml->MP = H;
	ml->data = nil;

	return ml;
}

Modlink*
mklinkmod(Module *m, int n)
{
	Modlink *ml;

	ml = mklinkmodok(m, n);
	if(ml == H)
		error(exHeap);
	return ml;
}

Modlink*
linkmod(Module *m, Import *ldt, int mkmp)
{
	Type *t;
	Heap *h;
	int i;
	Modlink *ml;
	Import *l;

	if(m == nil)
		return H;

	for(i = 0, l = ldt; l->name != nil; i++, l++)
		;
	/*
	 * The caller's reference to m becomes the Modlink's.  With no
	 * Modlink it is given back here: raised with it kept, a module
	 * just loaded stayed loaded, with nothing to unload it, for each
	 * load made with the heap full.
	 */
	ml = mklinkmodok(m, i);
	if(ml == H){
		unload(m);
		error(exHeap);
	}

	if(mkmp){
		if(mkmp && m->origmp != H && m->ntype > 0) {
			t = m->type[0];
			h = nheap(t->size);
			h->t = t;
			t->ref++;
			ml->MP = H2D(uchar*, h);
			newmp(ml->MP, m->origmp, t);
		}
	}

	for(i = 0, l = ldt; l->name != nil; i++, l++) {
		if(linkm(m, ml, i, l) < 0){
			destroy(ml);
			return H;
		}
	}

	return ml;
}

void
destroylinks(Module *m)
{
	Link *l;

	for(l = m->ext; l->name; l++)
		free(l->name);
	free(m->ext);
}
