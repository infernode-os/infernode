#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "pool.h"
#include "raise.h"

void	freearray(Heap*, int);
void	freelist(Heap*, int);
void	freemodlink(Heap*, int);
void	freechan(Heap*, int);
Type	Tarray = { 1, freearray, markarray, sizeof(Array) };
Type	Tstring = { 1, freestring, noptrs, sizeof(String) };
Type	Tlist = { 1, freelist, marklist, sizeof(List) };
Type	Tmodlink = { 1, freemodlink, markheap, -1, 1, 0, 0, { 0x80 } };
Type	Tchannel = { 1, freechan, markheap, sizeof(Channel), 1,0,0,{0x80} };
Type	Tptr = { 1, 0, markheap, sizeof(WORD*), 1, 0, 0, { 0x80 } };
Type	Tbyte = { 1, 0, 0, 1 };
Type Tword = { 1, 0, 0, sizeof(WORD) };
Type Tlong = { 1, 0, 0, sizeof(LONG) };
Type Treal = { 1, 0, 0, sizeof(REAL) };

extern	Pool*	heapmem;
extern	int	mutator;

void	(*heapmonitor)(int, void*, ulong);

#define	BIT(bt, nb)	(bt & (1<<nb))

/*
 * Release a Type's compiled initialize/destroy code.
 *
 * Whether that pointer can be freed depends on where this build's
 * typecom() put it, which is a property of the BUILD, not of the
 * architecture -- and the four places that used to do this inline all
 * decided it on the architecture alone.
 *
 * The 64-bit JITs were given a blanket "never free it", with the
 * workaround's own comment saying what it cost: "This leaks type code
 * on module unload." The reason was real for a hosted build, where
 * typecom() maps type code with mmap() and handing that pointer to
 * free() panics the pool.
 *
 * The native kernel has no mmap. typecom() there calls malloc(), so the
 * pointer is ordinary pool memory and the guard was suppressing a free
 * that had been correct all along. It cost the whole pool, slowly:
 * running a command loads a module, compiles its types and unloads it
 * again, and every cycle left its type code behind. Measured on a Pi
 * 3B+ with a loop spawning about twenty processes a second, the main
 * pool grew 2 MB every six minutes, and walking it by allocation site
 * put 7452 of the 7468 blocks gained over four minutes on this one
 * malloc.
 *
 *
 * 52b8f796 made this a no-op as an experiment (INFR-458): the board was
 * calling through garbage function pointers, the theory was compiled
 * code reading a Type's code address after the Type was freed, and the
 * experiment was to put the leak back and see whether the panics
 * stopped. They stopped -- but because of #622 (a proc preempted
 * between clang's copy of x28 and its use, resumed on another core),
 * found and fixed with the leak still in place. The experiment's own
 * note said what to do in that case: the free goes straight back in.
 *
 * What the leak cost while it was in: any loop that loads modules is
 * an out-of-memory in minutes (#641 -- an acceptance battery's leftover
 * shell re-spawning cat 800 times a second took the 123 MB main pool
 * in three and a half; /dev/memtags put 266,716 of 266,717 new blocks
 * on typecom's malloc), and even a clean battery run left ~3 MB
 * behind. If a garbage-pointer panic ever names freed type code again,
 * /dev/memtags and the #622 detectors are both in the kernel to say so.
 *
 * Hosted builds (added when this met the hosted port of the same fix):
 * On hosted 64-bit builds the JIT maps that code rather than mallocs
 * it, so free() must not see it, and for a long time nothing released
 * it at all: "this leaks type code on module unload", this file said,
 * and it did -- about 52 KB for every command run, since a command
 * loads a module, compiles its types and drops them again. Measured on
 * Linux/arm64, 1000 commands in one emulator: resident +52 MB with the
 * JIT, +0 without. Hosted arm64 now unmaps it (freetypejit, in
 * comp-arm64.c, by a length typecom() keeps in front of the code).
 * Hosted amd64 carves its type code from slabs that must stay near the
 * text segment, so it cannot unmap per type; freetypejit in comp-amd64.c
 * puts the block on a free list instead, and the next type compiled
 * reuses it (#649).
 */
static void
freetypecode(Type *t)
{
#if defined(__aarch64__) || (defined(__riscv) && __riscv_xlen == 64)
	freetypejit(t);		/* free() on a native kernel, munmap() hosted: comp-arm64.c and comp-riscv64.c know which */
#elif !defined(INFERNO_NATIVE) && (defined(__x86_64__) || defined(_M_X64))
	freetypejit(t);		/* hosted amd64: back to comp-amd64.c's free list, for the next type */
#else
	free(t->initialize);
#endif
}

void
freeptrs(void *v, Type *t)
{
	int c;
	WORD **w, *x;
	uchar *p, *ep;

	if(t->np == 0)
		return;

	w = (WORD**)v;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		if(c != 0) {
 			if(BIT(c, 0) && (x = w[7]) != H) destroy(x);
			if(BIT(c, 1) && (x = w[6]) != H) destroy(x);
 			if(BIT(c, 2) && (x = w[5]) != H) destroy(x);
			if(BIT(c, 3) && (x = w[4]) != H) destroy(x);
			if(BIT(c, 4) && (x = w[3]) != H) destroy(x);
			if(BIT(c, 5) && (x = w[2]) != H) destroy(x);
			if(BIT(c, 6) && (x = w[1]) != H) destroy(x);
			if(BIT(c, 7) && (x = w[0]) != H) destroy(x);
		}
		p++;
		w += 8;
	}
}

/*
void
nilptrs(void *v, Type *t)
{
	int c, i;
	WORD **w;
	uchar *p, *ep;

	w = (WORD**)v;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		for(i = 0; i < 8; i++){
			if(BIT(c, 7)) *w = H;
			c <<= 1;
			w++;
		}
		p++;
	}
}
*/

void
freechan(Heap *h, int swept)
{
	Channel *c;

	USED(swept);
	c = H2D(Channel*, h);
	if(c->mover == movtmp)
		freetype(c->mid.t);
	killcomm(&c->send);
	killcomm(&c->recv);
	if (!swept && c->buf != H)
		destroy(c->buf);
}

void
freestring(Heap *h, int swept)
{
	String *s;

	USED(swept);
	s = H2D(String*, h);
	if(s->tmp != nil)
		free(s->tmp);
}

void
freearray(Heap *h, int swept)
{
	int i;
	Type *t;
	uchar *v;
	Array *a;

	a = H2D(Array*, h);
	t = a->t;

	if(!swept) {
		if(a->root != H)
			destroy(a->root);
		else
		if(t->np != 0) {
			v = a->data;
			for(i = 0; i < a->len; i++) {
				freeptrs(v, t);
				v += t->size;
			}
		}
	}
	if(t->ref-- == 1) {
		freetypecode(t);
		free(t);
	}
}

void
freelist(Heap *h, int swept)
{
	Type *t;
	List *l;
	Heap *th;

	l = H2D(List*, h);
	t = l->t;

	if(t != nil) {
		if(!swept && t->np)
			freeptrs(l->data, t);
		t->ref--;
		if(t->ref == 0) {
			freetypecode(t);
			free(t);
		}
	}
	if(swept)
		return;
	l = l->tail;
	while(l != (List*)H) {
		t = l->t;
		th = D2H((ulong)l);
		if(th->ref-- != 1)
			break;
		th->t->ref--;	/* should be &Tlist and ref shouldn't go to 0 here nor be 0 already */
		if(t != nil) {
			if (t->np)
				freeptrs(l->data, t);
			t->ref--;
			if(t->ref == 0) {
				freetypecode(t);
				free(t);
			}
		}
		l = l->tail;
		if(heapmonitor != nil)
			heapmonitor(1, th, 0);
		poolfree(heapmem, th);
	}
}

void
freemodlink(Heap *h, int swept)
{
	Modlink *ml;

	ml = H2D(Modlink*, h);
	if(!swept)
		destroy(ml->MP);
	unload(ml->m);
}

int
heapref(void *v)
{
	return D2H(v)->ref;
}

void
freeheap(Heap *h, int swept)
{
	Type *t;

	if(swept)
		return;

	t = h->t;
	if (t->np)
		freeptrs(H2D(void*, h), t);
}

void
destroy(void *v)
{
	Heap *h;
	Type *t;

	if(v == H)
		return;

	h = D2H(v);
	{ Bhdr *b; D2B(b, h); }		/* consistency check */

	if(--h->ref > 0 || gchalt > 64) 	/* Protect 'C' thread stack */
		return;

	if(heapmonitor != nil)
		heapmonitor(1, h, 0);
	t = h->t;
	if(t != nil) {
		gclock();
		t->free(h, 0);
		gcunlock();
		freetype(t);
	}
	poolfree(heapmem, h);
}

Type*
dtype(void (*destroy)(Heap*, int), int size, uchar *map, int mapsize)
{
	Type *t;

	t = malloc(sizeof(Type)+mapsize);
	if(t != nil) {
		t->ref = 1;
		t->free = destroy;
		t->mark = markheap;
		t->size = size;
		t->np = mapsize;
		t->initialize = nil;
		t->destroy = nil;
		memmove(t->map, map, mapsize);
	}
	return t;
}

void*
checktype(void *v, Type *t, char *name, int newref)
{
	Heap *h;

	if(v == H || v == nil)
		error(exNilref);
	h = D2H(v);
	if(t == nil || h->t != t)
		errorf("%s: %s", exType, name);
	if(newref){
		h->ref++;
		Setmark(h);
	}
	return v;
}

void
freetype(Type *t)
{
	if(t == nil || --t->ref > 0)
		return;

	freetypecode(t);
	free(t);
}

void
incmem(void *vw, Type *t)
{
	Heap *h;
	uchar *p;
	int i, c, m;
	WORD **w, **q, *wp;

	w = (WORD**)vw;
	p = t->map;
	for(i = 0; i < t->np; i++) {
		c = *p++;
		if(c != 0) {
			q = w;
			for(m = 0x80; m != 0; m >>= 1) {
				if((c & m) && (wp = *q) != H) {
					h = D2H(wp);
					h->ref++;
					Setmark(h);
				}
				q++;
			}
		}
		w += 8;
	}
}

void
scanptrs(void *vw, Type *t, void (*f)(void*))
{
	uchar *p;
	int i, c, m;
	WORD **w, **q, *wp;

	w = (WORD**)vw;
	p = t->map;
	for(i = 0; i < t->np; i++) {
		c = *p++;
		if(c != 0) {
			q = w;
			for(m = 0x80; m != 0; m >>= 1) {
				if((c & m) && (wp = *q) != H)
					f(D2H(wp));
				q++;
			}
		}
		w += 8;
	}
}

void
initmem(Type *t, void *vw)
{
	int c;
	WORD **w;
	uchar *p, *ep;

	w = (WORD**)vw;
	p = t->map;
	ep = p + t->np;
	while(p < ep) {
		c = *p;
		if(c != 0) {
 			if(BIT(c, 0)) w[7] = H;
			if(BIT(c, 1)) w[6] = H;
			if(BIT(c, 2)) w[5] = H;
			if(BIT(c, 3)) w[4] = H;
			if(BIT(c, 4)) w[3] = H;
			if(BIT(c, 5)) w[2] = H;
			if(BIT(c, 6)) w[1] = H;
			if(BIT(c, 7)) w[0] = H;
		}
		p++;
		w += 8;
	}
}

Heap*
nheap(int n)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+n);
	if(h == nil)
		error(exHeap);

	h->t = nil;
	h->ref = 1;
	h->color = mutator;
	if(heapmonitor != nil)
		heapmonitor(0, h, n);

	return h;
}

Heap*
heapz(Type *t)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+t->size);
	if(h == nil)
		error(exHeap);

	h->t = t;
	if(t->ref <= 0 || t->ref > 50000000) panic("heap: Type %#p ref %d in use (size %d np %d) -- freed type?", t, t->ref, t->size, t->np);
	t->ref++;
	h->ref = 1;
	h->color = mutator;
	memset(H2D(void*, h), 0, t->size);
	if(t->np)
		initmem(t, H2D(void*, h));
	if(heapmonitor != nil)
		heapmonitor(0, h, t->size);
	return h;
}

Heap*
heap(Type *t)
{
	Heap *h;

	h = poolalloc(heapmem, sizeof(Heap)+t->size);
	if(h == nil)
		error(exHeap);

	h->t = t;
	if(t->ref <= 0 || t->ref > 50000000) panic("heap: Type %#p ref %d in use (size %d np %d) -- freed type?", t, t->ref, t->size, t->np);
	t->ref++;
	h->ref = 1;
	h->color = mutator;
	if(t->np)
		initmem(t, H2D(void*, h));
	if(heapmonitor != nil)
		heapmonitor(0, h, t->size);
	return h;
}

Heap*
heaparray(Type *t, int sz)
{
	Heap *h;
	Array *a;

	h = nheap(sizeof(Array) + (t->size*sz));
	h->t = &Tarray;
	Tarray.ref++;
	a = H2D(Array*, h);
	a->t = t;
	a->len = sz;
	a->root = H;
	a->data = (uchar*)a + sizeof(Array);
	initarray(t, a);
	return h;
}

int
hmsize(void *v)
{
	return poolmsize(heapmem, v);
}

void
initarray(Type *t, Array *a)
{
	int i;
	uchar *p;

	if(t->ref <= 0 || t->ref > 50000000) panic("heap: Type %#p ref %d in use (size %d np %d) -- freed type?", t, t->ref, t->size, t->np);
	t->ref++;
	if(t->np == 0)
		return;

	p = a->data;
	for(i = 0; i < a->len; i++) {
		initmem(t, p);
		p += t->size;
	}
}

void*
arraycpy(Array *sa)
{
	int i;
	Heap *dh;
	Array *da;
	uchar *elemp;
	void **sp, **dp;

	if(sa == H)
		return H;

	dh = nheap(sizeof(Array) + sa->t->size*sa->len);
	dh->t = &Tarray;
	Tarray.ref++;
	da = H2D(Array*, dh);
	da->t = sa->t;
	if(da->t->ref <= 0 || da->t->ref > 50000000) panic("heap: Type %#p ref %d in use (array) -- freed type?", da->t, da->t->ref);
	da->t->ref++;
	da->len = sa->len;
	da->root = H;
	da->data = (uchar*)da + sizeof(Array);
	if(da->t == &Tarray) {
		dp = (void**)da->data;
		sp = (void**)sa->data;
		/*
		 * Maximum depth of this recursion is set by DADEPTH
		 * in include/isa.h
		 */
		for(i = 0; i < sa->len; i++)
			dp[i] = arraycpy(sp[i]);			
	}
	else {
		memmove(da->data, sa->data, da->len*sa->t->size);
		elemp = da->data;
		for(i = 0; i < sa->len; i++) {
			incmem(elemp, da->t);
			elemp += da->t->size;
		}
	}
	return da;
}

void
newmp(void *dst, void *src, Type *t)
{
	Heap *h;
	int c, i, m;
	void **uld, *wp, **q;

	memmove(dst, src, t->size);
	uld = dst;
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		if(c != 0) {
			m = 0x80;
			q = uld;
			while(m != 0) {
				if((m & c) && (wp = *q) != H) {
					h = D2H(wp);
					if(h->t == &Tarray)
						*q = arraycpy(wp);
					else {
						h->ref++;
						Setmark(h);
					}
				}
				m >>= 1;
				q++;
			}
		}
		uld += 8;
	}
}
