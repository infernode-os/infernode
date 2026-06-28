/*
 * Runtime adapter for fuzzing the production Dis parser in libinterp/load.c.
 *
 * This supplies the allocator, heap, link, and kernel services parsemod needs
 * while retaining the production parser and runtime data layouts unchanged.
 */
#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include "kernel.h"

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>

static jmp_buf parseerror;
static int parsing;
#ifdef STANDALONE_FUZZ_TARGET
static int parsedmodule;
#endif

char exNomem[] = "out of memory";
int cflag;
Type Tarray = { 1, nil, nil, sizeof(Array) };

void*
mallocz(ulong n, int clear)
{
	void *p;

	p = malloc(n);
	if(p != nil && clear)
		memset(p, 0, n);
	return p;
}

void
kwerrstr(char *fmt, ...)
{
	USED(fmt);
}

void
error(char *message)
{
	USED(message);
	if(parsing)
		longjmp(parseerror, 1);
	abort();
}

void
errorf(char *fmt, ...)
{
	USED(fmt);
	error("runtime error");
}

void
freeheap(Heap *h, int swept)
{
	USED(h);
	USED(swept);
}

Type*
dtype(void (*destroyfn)(Heap*, int), int size, uchar *map, int mapsize)
{
	Type *t;

	if(size < 0 || mapsize < 0)
		return nil;
	t = malloc(sizeof(Type)+mapsize);
	if(t == nil)
		return nil;
	memset(t, 0, sizeof(Type)+mapsize);
	t->ref = 1;
	t->free = destroyfn;
	t->size = size;
	t->np = mapsize;
	if(mapsize != 0)
		memmove(t->map, map, mapsize);
	return t;
}

void
freetype(Type *t)
{
	if(t != nil && --t->ref == 0)
		free(t);
}

void
initmem(Type *t, void *data)
{
	uchar *map;
	WORD **words;
	int bit, i;

	map = t->map;
	words = data;
	for(i = 0; i < t->np; i++){
		for(bit = 0; bit < 8; bit++)
			if(map[i] & (1 << (7-bit)))
				words[bit] = H;
		words += 8;
	}
}

Heap*
nheap(int n)
{
	Heap *h;

	if(n < 0 || n > 128*1024*1024)
		error("implausible heap allocation");
	h = calloc(1, sizeof(Heap)+(size_t)n);
	if(h == nil)
		error(exNomem);
	h->ref = 1;
	return h;
}

Heap*
heapz(Type *t)
{
	Heap *h;

	h = nheap(t->size);
	h->t = t;
	t->ref++;
	if(t->np != 0)
		initmem(t, H2D(void*, h));
	return h;
}

void
initarray(Type *t, Array *a)
{
	uchar *p;
	int i;

	t->ref++;
	if(t->np == 0)
		return;
	p = a->data;
	for(i = 0; i < a->len; i++){
		initmem(t, p);
		p += t->size;
	}
}

void
destroy(void *data)
{
	Heap *h;
	Array *a;
	Type *t;
	uchar *p;
	WORD **words;
	int bit, i, j;

	if(data == H || data == nil)
		return;
	h = D2H(data);
	if(--h->ref != 0)
		return;
	t = h->t;
	if(t == &Tarray){
		a = data;
		if(a->root != H)
			destroy(a->root);
		else if(a->t->np != 0){
			p = a->data;
			for(i = 0; i < a->len; i++){
				words = (WORD**)p;
				for(j = 0; j < a->t->np; j++){
					for(bit = 0; bit < 8; bit++)
						if((a->t->map[j] & (1 << (7-bit))) && words[bit] != H)
							destroy(words[bit]);
					words += 8;
				}
				p += a->t->size;
			}
		}
		freetype(a->t);
		Tarray.ref--;
	}else if(t != nil){
		words = data;
		for(i = 0; i < t->np; i++){
			for(bit = 0; bit < 8; bit++)
				if((t->map[i] & (1 << (7-bit))) && words[bit] != H)
					destroy(words[bit]);
			words += 8;
		}
		freetype(t);
	}
	free(h);
}

String*
c2string(char *bytes, int len)
{
	Heap *h;
	String *s;

	if(len < 0)
		return H;
	h = nheap(sizeof(String)+(size_t)len+1);
	s = H2D(String*, h);
	s->len = len;
	s->max = len+1;
	memmove(s->Sascii, bytes, len);
	((char*)&s->data)[len] = 0;
	return s;
}

void
acheck(int elementsize, int count)
{
	if(elementsize < 0 || count < 0 ||
	   (elementsize != 0 && (uint)count >
	    ((~0U >> 1)-sizeof(Array)-sizeof(Heap))/(uint)elementsize))
		error("invalid array size");
}

void
mlink(Module *m, Link *l, uchar *name, int sig, int pc, Type *frame)
{
	l->name = strdup((char*)name);
	if(l->name == nil)
		error(exNomem);
	l->sig = sig;
	l->frame = frame;
	l->u.pc = m->prog+pc;
}

void
destroylinks(Module *m)
{
	Link *l;

	for(l = m->ext; l->name != nil; l++)
		free(l->name);
	free(m->ext);
	m->ext = nil;
}

int
verifysigner(uchar *signature, int siglen, uchar *data, ulong datalen)
{
	USED(signature);
	USED(siglen);
	USED(data);
	USED(datalen);
	return 1;
}

int
mustbesigned(char *path, uchar *code, ulong length, Dir *dir)
{
	USED(path);
	USED(code);
	USED(length);
	USED(dir);
	return 0;
}

int
compile(Module *m, int size, Modlink *ml)
{
	USED(m);
	USED(size);
	USED(ml);
	return 1;
}

Module*
readmod(char *path, Module *m, int sync)
{
	USED(path);
	USED(m);
	USED(sync);
	return nil;
}

int
LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	uchar *copy;
	Module *m;
	Dir dir;

	if(size == 0 || size >= 8*1024*1024)
		return 0;
	copy = malloc(size);
	if(copy == nil)
		return 0;
	memmove(copy, data, size);
	memset(&dir, 0, sizeof(dir));

	parsing = 1;
#ifdef STANDALONE_FUZZ_TARGET
	parsedmodule = 0;
#endif
	if(setjmp(parseerror) == 0){
		m = parsemod("/fuzz.dis", copy, size, &dir);
		if(m != nil){
#ifdef STANDALONE_FUZZ_TARGET
			parsedmodule = 1;
#endif
			unload(m);
		}
	}
	parsing = 0;
	free(copy);
	return 0;
}

#ifdef STANDALONE_FUZZ_TARGET
int
main(int argc, char **argv)
{
	FILE *fp;
	uchar *data;
	long size;
	int i;
	int failed;

	failed = 0;
	for(i = 1; i < argc; i++){
		fp = fopen(argv[i], "rb");
		if(fp == nil)
			continue;
		fseek(fp, 0, SEEK_END);
		size = ftell(fp);
		fseek(fp, 0, SEEK_SET);
		data = malloc(size > 0 ? (size_t)size : 1);
		if(size > 0 && fread(data, 1, size, fp) == (size_t)size){
			LLVMFuzzerTestOneInput(data, size);
			if(!parsedmodule){
				fprintf(stderr, "rejected valid module: %s\n", argv[i]);
				failed = 1;
			}
		}
		free(data);
		fclose(fp);
	}
	return failed;
}
#endif
