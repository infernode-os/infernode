#include "lib9.h"
#include "interp.h"
#include "pool.h"

/*
 * The live objects in this VM's heap, counted by what they are: the
 * Dis type of each, and the module whose type it is.  /dev/memory says
 * the heap pool is filling; this says with what, which is what a leak
 * in a Limbo program needs (ps gives each process's stack, not the heap
 * objects it keeps).  Read through #c/heaptypes, in emu and the native
 * kernel alike; two reads some time apart, diffed, name the leak.
 *
 * Then the collector's counters (gc runs, epochs ...), and one line an
 * object kind, most numerous first:
 *
 *	count bytes kind owner
 *
 * kind is obj, list (a list cell; the type is its element's) or array
 * (the type is its element's); owner is "path type N size S" for a type
 * a module declared (N indexes the module's type section, S is the
 * type's size), a built-in's name (string, byte, channel, Image ...),
 * or "type ADDR size S" for one neither knows (a module unloaded since).
 */

typedef struct Audit Audit;
struct Audit
{
	Type*	t;
	int	kind;
	ulong	n;
	ulong	size;
	Module*	m;		/* the module that declared t, if any */
	int	ti;		/* t's index in m->type */
	Audit*	hash;
};

enum
{
	Kobj,
	Klist,
	Karray,

	Nahash = 1024,
	Ntext = 64*1024,
};

extern Type Trdchan;
extern Type Twrchan;

static struct
{
	char*	name;
	Type*	ptr;
} types[] =
{
	{"array",	&Tarray},
	{"byte",	&Tbyte},
	{"channel",	&Tchannel},
	{"list",	&Tlist},
	{"modlink",	&Tmodlink},
	{"ptr",		&Tptr},
	{"string",	&Tstring},
	{"rdchan",	&Trdchan},
	{"wrchan",	&Twrchan},
	{nil,	nil}
};

extern Type* TDisplay;
extern Type* TFont;
extern Type* TImage;
extern Type* TScreen;
extern Type* TFD;
extern Type* TFileIO;
extern Type* fakeTkTop;

static struct
{
	char*	name;
	Type**	ptr;
} ptypes[] =
{
	{"Display",	&TDisplay},
	{"Font",	&TFont},
	{"Image",	&TImage},
	{"Screen",	&TScreen},
	{"FD",		&TFD},
	{"FileIO",	&TFileIO},
	{"TkTop",	&fakeTkTop},
	{nil,	nil}
};

static char *kindname[] = { "obj", "list", "array" };

static Audit**
auditentry(Audit **ah, Type *t, int kind)
{
	Audit **h, *a;

	for(h = &ah[(((uintptr)t>>3)+kind)%Nahash]; (a = *h) != nil; h = &a->hash)
		if(a->t == t && a->kind == kind)
			break;
	return h;
}

static char*
ownername(Audit *a, char *buf, int n)
{
	int i;

	if(a->m != nil){
		snprint(buf, n, "%s type %d size %d", a->m->path, a->ti, a->t->size);
		return buf;
	}
	if(a->t == nil)
		return "nil";
	for(i = 0; types[i].name != nil; i++)
		if(a->t == types[i].ptr)
			return types[i].name;
	for(i = 0; ptypes[i].name != nil; i++)
		if(*ptypes[i].ptr != nil && a->t == *ptypes[i].ptr)
			return ptypes[i].name;
	snprint(buf, n, "type %#p size %d", a->t, a->t->size);
	return buf;
}

enum { Ngcprop = 16 };	/* gc.c */
extern Type*	gcproptype[Ngcprop];
extern ulong	gcpropn[Ngcprop];
extern ulong	gcproptot, gcpropother;

/* a type by the module that declared it, for the collector's lines */
static char*
typename(Type *t, char *buf, int n)
{
	Module *m;
	Audit a;
	int i;

	memset(&a, 0, sizeof a);
	a.t = t;
	for(m = modules; m != nil && a.m == nil; m = m->link)
		for(i = 0; i < m->ntype; i++)
			if(m->type[i] == t){
				a.m = m;
				a.ti = i;
				break;
			}
	return ownername(&a, buf, n);
}

/*
 * The text, malloc'd; nil when there is no memory for it.  It walks the
 * heap under the VM's lock (acquire), so the objects stay still.
 */
char*
heapaudittext(void)
{
	Type *t;
	Heap *h;
	Module *m;
	Bhdr *b, *base, *limit;
	Audit **ah, **hash, *a, **v;
	ulong nobj, nbytes;
	int i, j, kind, nv, o;
	char *s, own[256];

	ah = malloc(Nahash*sizeof(Audit*));
	s = malloc(Ntext);
	if(ah == nil || s == nil){
		free(ah);
		free(s);
		return nil;
	}
	nobj = nbytes = 0;
	nv = 0;

	acquire();
	b = poolchain(heapmem);
	base = b;
	limit = b != nil ? B2LIMIT(b) : nil;
	while(b != nil){
		if(b->magic == MAGIC_A){
			h = B2D(b);
			t = h->t;
			kind = Kobj;
			if(t == &Tlist){
				t = H2D(List*, h)->t;
				kind = Klist;
			}else if(t == &Tarray){
				t = H2D(Array*, h)->t;
				kind = Karray;
			}
			hash = auditentry(ah, t, kind);
			if((a = *hash) == nil){
				a = malloc(sizeof(Audit));
				if(a != nil){
					a->t = t;
					a->kind = kind;
					a->hash = nil;
					*hash = a;
					nv++;
				}
			}
			if(a != nil){
				a->n++;
				a->size += b->size;
			}
			nobj++;
			nbytes += b->size;
		}
		b = B2NB(b);
		if(b >= limit){
			base = base->clink;
			if(base == nil)
				break;
			b = base;
			limit = B2LIMIT(base);
		}
	}
	/* name the module types while the modules cannot go */
	for(m = modules; m != nil; m = m->link)
		for(i = 0; i < m->ntype; i++)
			for(kind = Kobj; kind <= Karray; kind++)
				if((a = *auditentry(ah, m->type[i], kind)) != nil && a->m == nil){
					a->m = m;
					a->ti = i;
				}
	/* the names, too: a module may go once the lock is let go */
	v = malloc((nv+1)*sizeof(Audit*));
	o = snprint(s, Ntext, "heap objects %lud bytes %lud kinds %d\n", nobj, nbytes, nv);
	/* whether the collector gets anywhere: a cycle is freed only at an epoch's end */
	o += snprint(s+o, Ntext-o, "gc runs %lud epochs %lud sweeps %lud halted %lud broken %lud destroys %llud inspects %llud\n",
		gcnruns, gcepochs, gcsweeps, gchalted, gcbroken, gcdestroys, gcinspects);
	o += snprint(s+o, Ntext-o, "gc last traversal propagated %lud (%lud of other types)\n", gcproptot, gcpropother);
	for(i = 0; i < Ngcprop && gcproptype[i] != nil; i++)
		o += snprint(s+o, Ntext-o, "gc propagated %8lud %s\n", gcpropn[i], typename(gcproptype[i], own, sizeof own));
	if(v != nil){
		j = 0;
		for(i = 0; i < Nahash; i++)
			for(a = ah[i]; a != nil; a = a->hash)
				v[j++] = a;
		nv = j;
		/* most numerous first: a leak is near the top */
		for(i = 1; i < nv; i++){
			a = v[i];
			for(j = i; j > 0 && v[j-1]->n < a->n; j--)
				v[j] = v[j-1];
			v[j] = a;
		}
		for(i = 0; i < nv && o < Ntext - 128; i++)
			o += snprint(s+o, Ntext-o, "%8lud %10lud %s %s\n",
				v[i]->n, v[i]->size, kindname[v[i]->kind],
				ownername(v[i], own, sizeof own));
		free(v);
	}
	release();

	for(i = 0; i < Nahash; i++)
		while((a = ah[i]) != nil){
			ah[i] = a->hash;
			free(a);
		}
	free(ah);
	return s;
}
