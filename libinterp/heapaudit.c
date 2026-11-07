#include "lib9.h"
#include "interp.h"
#include "pool.h"


typedef struct Audit Audit;
struct Audit
{
	Type*	t;
	ulong	n;
	ulong	size;
	Audit*	hash;
};
Audit*	ahash[128];
extern void conslog(char*, ...);
#define	conslog	print

typedef struct Typed	Typed;
typedef struct Ptyped	Ptyped;

extern Type Trdchan;
extern Type Twrchan;

struct Typed
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
	{"unspec",	nil},

	0
};

extern Type* TDisplay;
extern Type* TFont;
extern Type* TImage;
extern Type* TScreen;
extern Type* TFD;
extern Type* TFileIO;
extern Type* Tread;
extern Type* Twrite;
extern Type* fakeTkTop;

extern Type* TIPint;

struct Ptyped
{
	char*	name;
	Type**	ptr;
} ptypes[] =
{
	{"Display",	&TDisplay},
	{"Font",	&TFont},
	{"Image",	&TImage},
	{"Screen",	&TScreen},

	{"IPint",	&TIPint},

	{"FD",		&TFD},
	{"FileIO",	&TFileIO},

/*	{"Fioread",	&Tread},	*/
/*	{"Fiowrite",	&Twrite},	*/

	{"TkTop",	&fakeTkTop},

	0
};

static Audit **
auditentry(Type *t)
{
	Audit **h, *a;

	for(h = &ahash[((ulong)t>>2)%nelem(ahash)]; (a = *h) != nil; h = &a->hash)
		if(a->t == t)
			break;
	return h;
}

void
heapaudit(void)
{
	Type *t;
	Heap *h;
	List *l;
	Array *r;
	Module *m;
	int i, ntype, n;
	Bhdr *b, *base, *limit;
	Audit *a, **hash;

	acquire();

	b = poolchain(heapmem);
	base = b;
	limit = B2LIMIT(b);

	while(b != nil) {
		if(b->magic == MAGIC_A) {
			h = B2D(b);
			t = h->t;
			n = 1;
			if(t == &Tlist) {
				l = H2D(List*, h);
				t = l->t;
			} else if(t == &Tarray) {
				r = H2D(Array*, h);
				t = r->t;
				n = r->len;
			}
			hash = auditentry(t);
			if((a = *hash) == nil){
				a = malloc(sizeof(Audit));
				if(a == nil)
					continue;
				a->n = 1;
				a->t = t;
				a->hash = *hash;
				*hash = a;
			}else
				a->n++;
			if(t != nil && t != &Tmodlink && t != &Tstring)
				a->size += (ulong)t->size * (ulong)n;
			else
				a->size += b->size;
		}
		b = B2NB(b);
		if(b >= limit) {
			base = base->clink;
			if(base == nil)
				break;
			b = base;
			limit = B2LIMIT(base);
		}
	}

	for(m = modules; m != nil; m = m->link) {
		for(i = 0; i < m->ntype; i++)
			if((a = *auditentry(m->type[i])) != nil) {
				conslog("%8ld %8lud %3d %s\n", a->n, a->size, i, m->path);
				a->size = 0;
				break;
			}
	}

	for(i = 0; (t = types[i].ptr) != nil; i++)
		if((a = *auditentry(t)) != nil){
			conslog("%8ld %8lud %s\n", a->n, a->size, types[i].name);
			a->size = 0;
			break;
		}

	for(i = 0; ptypes[i].name != nil; i++)
		if((a = *auditentry(*ptypes[i].ptr)) != nil){
			conslog("%8ld %8lud %s\n", a->n, a->size, ptypes[i].name);
			a->size = 0;
			break;
		}

	ntype = 0;
	for(i = 0; i < nelem(ahash); i++)
		while((a = ahash[i]) != nil){
			ahash[i] = a->hash;
			if(a->size != 0)
				conslog("%8ld %8lud %p\n", a->n, a->size, a->t);
			free(a);
			ntype++;
		}

	release();
}

/*
 * The census as text, for a file (the native kernel's #c/heapaudit):
 * every live object in the reader's VM's heap, counted by its type, a
 * line for each type that has any. A module's types are named by the
 * module and the type's index in it; the interpreter's own by name.
 * Bytes are what the type says an object holds (an array's elements
 * counted), or the block for a string or a module link. The table is
 * built afresh for each call and freed after, so readings compare.
 *
 *	   count    bytes type module|name
 */
enum { Auditext = 256*1024 };
static char *auditext;

static int
auditline(char *p, char *e, Audit *a, int idx, char *what)
{
	if(idx >= 0)
		return snprint(p, e-p, "%8lud %9lud %3d %s\n", a->n, a->size, idx, what);
	return snprint(p, e-p, "%8lud %9lud   - %s\n", a->n, a->size, what);
}

long
heapauditread(void *va, long count, ulong offset)
{
	Type *t;
	Heap *h;
	List *l;
	Array *r;
	Module *m;
	int i, n, nlive, ntype, lost;
	Bhdr *b, *base, *limit;
	Audit *a, **hash;
	char *p, *e;

	if(auditext == nil){
		auditext = malloc(Auditext);
		if(auditext == nil)
			return 0;
	}
	nlive = ntype = lost = 0;
	acquire();
	b = poolchain(heapmem);
	base = b;
	limit = B2LIMIT(b);
	while(b != nil) {
		if(b->magic == MAGIC_A) {
			h = B2D(b);
			t = h->t;
			n = 1;
			if(t == &Tlist) {
				l = H2D(List*, h);
				t = l->t;
			} else if(t == &Tarray) {
				r = H2D(Array*, h);
				t = r->t;
				n = r->len;
			}
			nlive++;
			hash = auditentry(t);
			if((a = *hash) == nil){
				a = malloc(sizeof(Audit));
				if(a == nil)
					lost++;	/* counted, not by type; the walk goes on */
				else{
					a->t = t;
					a->hash = *hash;
					*hash = a;
					ntype++;
				}
			}
			if(a != nil){
				a->n++;
				if(t != nil && t != &Tmodlink && t != &Tstring)
					a->size += (ulong)t->size * (ulong)n;
				else
					a->size += b->size;
			}
		}
		b = B2NB(b);
		if(b >= limit) {
			base = base->clink;
			if(base == nil)
				break;
			b = base;
			limit = B2LIMIT(base);
		}
	}

	p = auditext;
	e = auditext + Auditext - 128;
	p += snprint(p, e-p, "heap live %d types %d untyped %d\n", nlive, ntype, lost);
	/* a type is printed once: its count is cleared as it is */
	for(m = modules; m != nil; m = m->link)
		for(i = 0; i < m->ntype && p < e; i++)
			if((a = *auditentry(m->type[i])) != nil && a->n != 0){
				p += auditline(p, e, a, i, m->path);
				a->n = 0;
			}
	for(i = 0; (t = types[i].ptr) != nil && p < e; i++)
		if((a = *auditentry(t)) != nil && a->n != 0){
			p += auditline(p, e, a, -1, types[i].name);
			a->n = 0;
		}
	for(i = 0; ptypes[i].name != nil && p < e; i++)
		if(*ptypes[i].ptr != nil && (a = *auditentry(*ptypes[i].ptr)) != nil && a->n != 0){
			p += auditline(p, e, a, -1, ptypes[i].name);
			a->n = 0;
		}
	for(i = 0; i < nelem(ahash); i++)
		while((a = ahash[i]) != nil){
			ahash[i] = a->hash;
			if(a->n != 0 && p < e)
				p += snprint(p, e-p, "%8lud %9lud   - type %p\n", a->n, a->size, a->t);
			free(a);
		}
	release();
	*p = 0;
	return readstr(offset, va, count, auditext);
}
