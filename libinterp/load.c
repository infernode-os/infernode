#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"
#include <kernel.h>

#define	A(r)	*((Array**)(r))

Module*	modules;
int	dontcompile;

typedef struct ParseState ParseState;
struct ParseState
{
	uchar *end;
	int error;
};

static int
havebytes(ParseState *ps, uchar *p, ulong n)
{
	return p <= ps->end && n <= (ulong)(ps->end-p);
}

static int
aligned(uchar *p, ulong n)
{
	return n == 0 || (uintptr)p%n == 0;
}

static int
pointerslot(Type *t, ulong offset)
{
	ulong word, map;

	if(t == nil || t->size <= 0 || offset%sizeof(WORD) != 0)
		return 0;
	offset %= t->size;
	word = offset/sizeof(WORD);
	map = word/8;
	return map < (ulong)t->np && (t->map[map] & (1 << (7-(word%8)))) != 0;
}

static int
haspointers(Type *t, uchar *base, uchar *p, ulong n)
{
	ulong first, last, offset;

	if(t == nil || t->np == 0 || n == 0)
		return 0;
	first = p-base;
	last = first+n;
	offset = first-(first%sizeof(WORD));
	for(; offset < last; offset += sizeof(WORD))
		if(pointerslot(t, offset))
			return 1;
	return 0;
}

static int
ismanagedpointer(Type *t, uchar *base, uchar *p)
{
	return p >= base && pointerslot(t, p-base);
}

static int
validtypemap(int size, uchar *map, int mapsize)
{
	ulong maxwords, word;
	int bit, i;

	maxwords = (ulong)size/sizeof(WORD);
	if(mapsize != 0 && size%sizeof(WORD) != 0)
		return 0;
	if((ulong)mapsize > (maxwords+7)/8)
		return 0;
	for(i = 0; i < mapsize; i++)
		for(bit = 0; bit < 8; bit++){
			word = (ulong)i*8+bit;
			if((map[i] & (1 << (7-bit))) != 0 && word >= maxwords)
				return 0;
		}
	return 1;
}

static int
validarraysize(int elementsize, int count)
{
	uint maxalloc;

	maxalloc = 128*1024*1024;
	return elementsize >= 0 && count >= 0 &&
		(elementsize == 0 || (uint)count <= (maxalloc-sizeof(Array))/(uint)elementsize);
}

static int
operand(ParseState *ps, uchar **p)
{
	int c;
	u32int v;
	uchar *cp;

	cp = *p;
	if(cp >= ps->end){
		ps->error = 1;
		return -1;
	}
	c = cp[0];
	switch(c & 0xC0) {
	case 0x00:
		*p = cp+1;
		return c;
	case 0x40:
		*p = cp+1;
		return c|~0x7F;
	case 0x80:
		if(!havebytes(ps, cp, 2)){
			ps->error = 1;
			return -1;
		}
		*p = cp+2;
		v = ((u32int)(c&0x3F)<<8)|cp[1];
		if(c & 0x20)
			return (int)((vlong)v-(1LL<<14));
		return (int)v;
	case 0xC0:
		if(!havebytes(ps, cp, 4)){
			ps->error = 1;
			return -1;
		}
		*p = cp+4;
		v = ((u32int)(c&0x3F)<<24)|((u32int)cp[1]<<16)|
			((u32int)cp[2]<<8)|cp[3];
		if(c & 0x20)
			return (int)((vlong)v-(1LL<<30));
		return (int)v;
	}
	return 0;
}

static ulong
disw(ParseState *ps, uchar **p)
{
	ulong v;
	u32int bits;
	uchar *c;

	c = *p;
	if(!havebytes(ps, c, 4)){
		ps->error = 1;
		return 0;
	}
	bits  = (u32int)c[0] << 24;
	bits |= (u32int)c[1] << 16;
	bits |= (u32int)c[2] << 8;
	bits |= c[3];
	*p = c + 4;
	if(bits & (1U<<31))
		v = (ulong)((vlong)bits-(1LL<<32));
	else
		v = bits;
	return v;
}

double
canontod(ulong v[2])
{
	union { double d; u32int ul[2]; } a;
	a.d = 1.;
	if(a.ul[0]) {
		a.ul[0] = (u32int)v[0];
		a.ul[1] = (u32int)v[1];
	}
	else {
		a.ul[1] = (u32int)v[0];
		a.ul[0] = (u32int)v[1];
	}
	return a.d;
}

Module*
load(char *path)
{
	return readmod(path, nil, 0);
}

int
brpatch(Inst *ip, Module *m)
{
	switch(ip->op) {
	case ICALL:
	case IJMP:
	case IBEQW:
	case IBNEW:
	case IBLTW:
	case IBLEW:
	case IBGTW:
	case IBGEW:
	case IBEQB:
	case IBNEB:
	case IBLTB:
	case IBLEB:
	case IBGTB:
	case IBGEB:
	case IBEQF:
	case IBNEF:
	case IBLTF:
	case IBLEF:
	case IBGTF:
	case IBGEF:
	case IBEQC:
	case IBNEC:
	case IBLTC:
	case IBLEC:
	case IBGTC:
	case IBGEC:
	case IBEQL:
	case IBNEL:
	case IBLTL:
	case IBLEL:
	case IBGTL:
	case IBGEL:
	case ISPAWN:
		if(ip->d.imm < 0 || ip->d.imm >= m->nprog)
			return 0;
		ip->d.imm = (WORD)&m->prog[ip->d.imm];
		break;
	}
	return 1;
}

Module*
parsemod(char *path, uchar *code, ulong length, Dir *dir)
{
	Heap *h;
	Inst *ip;
	Type *pt, *datatype;
	String *s;
	Module *m;
	Array *ary;
	ulong ul[2];
	WORD lo, hi;
	int lsize, id, v, entry, entryt, tnp, tsz, siglen;
	int de, pc, i, n, nbytes, isize, dsize, hsize, dasp;
	uchar *mod, sm, *istream, **isp, *si, *addr, *addrend, *database;
	uchar *dastack[DADEPTH], *endstack[DADEPTH], *basestack[DADEPTH];
	Type *typestack[DADEPTH];
	Link *l;
	ParseState ps;

	istream = code;
	isp = &istream;
	ps.end = code + length;
	ps.error = 0;

	m = mallocz(sizeof(Module), 1);
	if(m == nil)
		return nil;

	m->dev = dir->dev;
	m->dtype = dir->type;
	m->qid = dir->qid;
	m->mtime = dir->mtime;
	m->origmp = H;
	m->pctab = nil;

	switch(operand(&ps, isp)) {
	default:
		kwerrstr("bad magic");
		goto bad;
	case SMAGIC:
		siglen = operand(&ps, isp);
		n = length-(*isp-code);
		if(siglen < 0 || n < 0 || siglen > n){
			kwerrstr("corrupt signature");
			goto bad;
		}
		if(verifysigner(*isp, siglen, *isp+siglen, n-siglen) == 0) {
			kwerrstr("security violation");
			goto bad;
		}
		*isp += siglen;
		break;		
	case XMAGIC:
		if(mustbesigned(path, code, length, dir)){
			kwerrstr("security violation: not signed");
			goto bad;
		}
		break;
	}

	m->rt = operand(&ps, isp);
	m->ss = operand(&ps, isp);
	isize = operand(&ps, isp);
	dsize = operand(&ps, isp);
	hsize = operand(&ps, isp);
	lsize = operand(&ps, isp);
	entry = operand(&ps, isp);
	entryt = operand(&ps, isp);

	if(ps.error || isize < 0 || dsize < 0 || hsize < 0 || lsize < 0) {
		kwerrstr("implausible Dis file");
		goto bad;
	}
	if(isize > 1024*1024 || dsize > 128*1024*1024 || hsize > 1024*1024 || lsize > 1024*1024) {
		kwerrstr("implausible Dis file");
		goto bad;
	}

	m->nprog = isize;
	m->prog = mallocz(isize*sizeof(Inst), 0);
	if(m->prog == nil) {
		kwerrstr(exNomem);
		goto bad;
	}

	m->ref = 1;

	ip = m->prog;
	for(i = 0; i < isize; i++) {
		if(!havebytes(&ps, istream, 2)) {
			kwerrstr("truncated Dis file");
			goto bad;
		}
		ip->op = *istream++;
		ip->add = *istream++;
		ip->reg = 0;
		ip->s.imm = 0;
		ip->d.imm = 0;
		switch(ip->add & ARM) {
		case AXIMM:
		case AXINF:
		case AXINM:
			ip->reg = operand(&ps, isp);
		 	break;
		}
		switch(UXSRC(ip->add)) {
		case SRC(AFP):
		case SRC(AMP):	
		case SRC(AIMM):
			ip->s.ind = operand(&ps, isp);
			break;
		case SRC(AIND|AFP):
		case SRC(AIND|AMP):
			ip->s.i.f = operand(&ps, isp);
			ip->s.i.s = operand(&ps, isp);
			break;
		}
		switch(UXDST(ip->add)) {
		case DST(AFP):
		case DST(AMP):	
			ip->d.ind = operand(&ps, isp);
			break;
		case DST(AIMM):
			ip->d.ind = operand(&ps, isp);
			if(brpatch(ip, m) == 0) {
				kwerrstr("bad branch addr");
				goto bad;
			}
			break;
		case DST(AIND|AFP):
		case DST(AIND|AMP):
			ip->d.i.f = operand(&ps, isp);
			ip->d.i.s = operand(&ps, isp);
			break;
		}
		ip++;		
	}
	if(ps.error){
		kwerrstr("truncated Dis instruction");
		goto bad;
	}

	m->ntype = hsize;
	m->type = nil;
	if(hsize != 0)
		m->type = mallocz(hsize*sizeof(Type*), 1);
	if(hsize != 0 && m->type == nil) {
		kwerrstr(exNomem);
		goto bad;
	}
	for(i = 0; i < hsize; i++) {
		id = operand(&ps, isp);
		if(ps.error || id < 0 || id >= hsize || m->type[id] != nil) {
			kwerrstr("heap id range");
			goto bad;
		}
		tsz = operand(&ps, isp);
		tnp = operand(&ps, isp);
		if(ps.error || tsz < 0 || tsz > 128*1024*1024 || tnp < 0 || tnp > 128*1024 ||
		   !havebytes(&ps, istream, tnp) || !validtypemap(tsz, istream, tnp)){
			kwerrstr("implausible Dis file");
			goto bad;
		}
		pt = dtype(freeheap, tsz, istream, tnp);
		if(pt == nil) {
			kwerrstr(exNomem);
			goto bad;
		}
		istream += tnp;
		m->type[id] = pt;
	}

	if(dsize != 0) {
		if(hsize == 0 || m->type == nil){
			kwerrstr("missing desc for mp");
			goto bad;
		}
		pt = m->type[0];
		if(pt == 0 || pt->size != dsize) {
			kwerrstr("bad desc for mp");
			goto bad;
		}
		h = heapz(pt);
		m->origmp = H2D(uchar*, h);
	}
	addr = m->origmp;
	addrend = addr == H ? H : addr+dsize;
	database = addr;
	datatype = dsize == 0 ? nil : m->type[0];
	dasp = 0;
	for(;;) {
		if(istream >= ps.end) {
			kwerrstr("truncated Dis file");
			goto bad;
		}
		sm = *istream++;
		if(sm == 0)
			break;
		n = DLEN(sm);
		if(n == 0)
			n = operand(&ps, isp);
		v = operand(&ps, isp);
		if(ps.error || n < 0 || v < 0 || addr == H || v > addrend-addr) {
			kwerrstr("bad data item range");
			goto bad;
		}
		si = addr + v;
		switch(DTYPE(sm)) {
		default:
			kwerrstr("bad data item");
			goto bad;
		case DEFS:
			if(!havebytes(&ps, istream, n) || (ulong)(addrend-si) < sizeof(String*) ||
			   !aligned(si, sizeof(String*)) || !ismanagedpointer(datatype, database, si) || *(String**)si != H){
				kwerrstr("bad string data range");
				goto bad;
			}
			s = c2string((char*)istream, n);
			istream += n;
			*(String**)si = s;
			break;
		case DEFB:
			if(!havebytes(&ps, istream, n) || n > addrend-si || haspointers(datatype, database, si, n)){
				kwerrstr("bad byte data range");
				goto bad;
			}
			for(i = 0; i < n; i++)
				*si++ = *istream++;
			break;
		case DEFW:
			if(n > (addrend-si)/sizeof(WORD) || !havebytes(&ps, istream, (ulong)n*4) ||
			   !aligned(si, sizeof(WORD)) || haspointers(datatype, database, si, (ulong)n*sizeof(WORD))){
				kwerrstr("bad word data range");
				goto bad;
			}
			for(i = 0; i < n; i++) {
				*(WORD*)si = disw(&ps, isp);
				si += sizeof(WORD);
			}
			break;
		case DEFL:
			if(n > (addrend-si)/sizeof(LONG) || !havebytes(&ps, istream, (ulong)n*8) ||
			   !aligned(si, sizeof(LONG)) || haspointers(datatype, database, si, (ulong)n*sizeof(LONG))){
				kwerrstr("bad long data range");
				goto bad;
			}
			for(i = 0; i < n; i++) {
				hi = disw(&ps, isp);
				lo = disw(&ps, isp);
				*(ULONG*)si = ((ULONG)(u32int)hi << 32) | (u32int)lo;
				si += sizeof(LONG);
			}
			break;
		case DEFF:
			if(n > (addrend-si)/sizeof(REAL) || !havebytes(&ps, istream, (ulong)n*8) ||
			   !aligned(si, sizeof(REAL)) || haspointers(datatype, database, si, (ulong)n*sizeof(REAL))){
				kwerrstr("bad real data range");
				goto bad;
			}
			for(i = 0; i < n; i++) {
				ul[0] = disw(&ps, isp);
				ul[1] = disw(&ps, isp);
				*(REAL*)si = canontod(ul);
				si += sizeof(REAL);
			}
			break;
		case DEFA:			/* Array */
			if((ulong)(addrend-si) < sizeof(Array*) || !havebytes(&ps, istream, 8) ||
			   !aligned(si, sizeof(Array*)) || !ismanagedpointer(datatype, database, si) || A(si) != H){
				kwerrstr("bad array data range");
				goto bad;
			}
			v = disw(&ps, isp);
			if(ps.error || v < 0 || v >= m->ntype || m->type[v] == nil) {
				kwerrstr("bad array type");
				goto bad;
			}
			pt = m->type[v];
			v = disw(&ps, isp);
			if(ps.error || !validarraysize(pt->size, v)){
				kwerrstr("bad array size");
				goto bad;
			}
			nbytes = pt->size * v;
			h = nheap(sizeof(Array)+nbytes);
			h->t = &Tarray;
			h->t->ref++;
			ary = H2D(Array*, h);
			ary->t = pt;
			ary->len = v;
			ary->root = H;
			ary->data = (uchar*)ary+sizeof(Array);
			memset((void*)ary->data, 0, nbytes);
			initarray(pt, ary);
			A(si) = ary;
			break;			
		case DIND:			/* Set index */
			if((ulong)(addrend-si) < sizeof(Array*) || !aligned(si, sizeof(Array*)) ||
			   !ismanagedpointer(datatype, database, si)){
				kwerrstr("bad array index data range");
				goto bad;
			}
			ary = A(si);
			if(ary == H || D2H(ary)->t != &Tarray) {
				kwerrstr("ind not array");
				goto bad;
			}
			v = disw(&ps, isp);
			if(ps.error || v < 0 || v > ary->len || dasp >= DADEPTH) {
				kwerrstr("array init range");
				goto bad;
			}
			dastack[dasp++] = addr;
			endstack[dasp-1] = addrend;
			basestack[dasp-1] = database;
			typestack[dasp-1] = datatype;
			addr = ary->data+v*ary->t->size;
			addrend = ary->data+ary->len*ary->t->size;
			database = ary->data;
			datatype = ary->t;
			break;
		case DAPOP:
			if(dasp == 0) {
				kwerrstr("pop range");
				goto bad;
			}
			addr = dastack[--dasp];
			addrend = endstack[dasp];
			database = basestack[dasp];
			datatype = typestack[dasp];
			break;
		}
	}
	if(dasp != 0){
		kwerrstr("unbalanced array data");
		goto bad;
	}
	mod = istream;
	if(istream >= ps.end || memchr(mod, 0, ps.end - istream) == 0) {
		kwerrstr("bad module name");
		goto bad;
	}
	m->name = strdup((char*)mod);
	if(m->name == nil) {
		kwerrstr(exNomem);
		goto bad;
	}
	while(istream < ps.end && *istream != 0)
		istream++;
	if(istream < ps.end)
		istream++;

	l = m->ext = (Link*)malloc((lsize+1)*sizeof(Link));
	if(l == nil){
		kwerrstr(exNomem);
		goto bad;
	}
	memset(l, 0, (lsize+1)*sizeof(Link));
	for(i = 0; i < lsize; i++, l++) {
		pc = operand(&ps, isp);
		de = operand(&ps, isp);
		v  = disw(&ps, isp);
		if(ps.error || pc < 0 || pc >= isize || (de != -1 && (de < 0 || de >= hsize || m->type[de] == nil)) || memchr(istream, 0, ps.end-istream) == nil){
			kwerrstr("bad module link");
			goto bad;
		}
		pt = nil;
		if(de != -1)
			pt = m->type[de];
		mlink(m, l, istream, v, pc, pt);
		while(istream < ps.end && *istream != 0)
			istream++;
		if(istream < ps.end)
			istream++;
	}
	l->name = nil;

	if(m->rt & HASLDT0){
		kwerrstr("obsolete dis");
		goto bad;
	}

	if(m->rt & HASLDT){
		int j, nl;
		Import *i1, **i2;

		nl = operand(&ps, isp);
		if(ps.error || nl < 0 || nl > 1024*1024){
			kwerrstr("bad import table");
			goto bad;
		}
		i2 = m->ldt = (Import**)mallocz((nl+1)*sizeof(Import*), 1);
		if(i2 == nil){
			kwerrstr(exNomem);
			goto bad;
		}
		for(i = 0; i < nl; i++, i2++){
			n = operand(&ps, isp);
			if(ps.error || n < 0 || n > 1024*1024){
				kwerrstr("bad import table");
				goto bad;
			}
			i1 = *i2 = (Import*)mallocz((n+1)*sizeof(Import), 1);
			if(i1 == nil){
				kwerrstr(exNomem);
				goto bad;
			}
			for(j = 0; j < n; j++, i1++){
				i1->sig = disw(&ps, isp);
				if(ps.error || memchr(istream, 0, ps.end - istream) == nil){
					kwerrstr("bad dis import name");
					goto bad;
				}
				i1->name = strdup((char*)istream);
				if(i1->name == nil){
					kwerrstr(exNomem);
					goto bad;
				}
				while(*istream++)
					;
			}
		}
		if(istream >= ps.end || *istream != 0){
			kwerrstr("truncated import table");
			goto bad;
		}
		istream++;
	}

	if(m->rt & HASEXCEPT){
		int j, nh;
		Handler *h;
		Except *e;

		nh = operand(&ps, isp);
		if(ps.error || nh < 0 || nh > 1024*1024){
			kwerrstr("bad exception table");
			goto bad;
		}
		m->htab = mallocz((nh+1)*sizeof(Handler), 1);
		if(m->htab == nil){
			kwerrstr(exNomem);
			goto bad;
		}
		h = m->htab;
		for(i = 0; i < nh; i++, h++){
			h->eoff = operand(&ps, isp);
			h->pc1 = operand(&ps, isp);
			h->pc2 = operand(&ps, isp);
			n = operand(&ps, isp);
			if(ps.error || h->pc1 >= (ulong)isize || h->pc2 > (ulong)isize || h->pc1 > h->pc2 || (n != -1 && (n < 0 || n >= hsize || m->type[n] == nil))){
				kwerrstr("bad exception handler");
				goto bad;
			}
			if(n != -1)
				h->t = m->type[n];
			n = operand(&ps, isp);
			if(ps.error || n < 0){
				kwerrstr("truncated exception table");
				goto bad;
			}
			h->ne = n>>16;
			n &= 0xffff;
			h->etab = mallocz((n+1)*sizeof(Except), 1);
			if(h->etab == nil){
				kwerrstr(exNomem);
				goto bad;
			}
			e = h->etab;
			for(j = 0; j < n; j++, e++){
				if(memchr(istream, 0, ps.end-istream) == nil){
					kwerrstr("bad exception name");
					goto bad;
				}
				e->s = strdup((char*)istream);
				if(e->s == nil){
					kwerrstr(exNomem);
					goto bad;
				}
				while(*istream++)
					;
				e->pc = operand(&ps, isp);
				if(ps.error || e->pc >= (ulong)isize){
					kwerrstr("bad exception pc");
					goto bad;
				}
			}
			e->s = nil;
			e->pc = operand(&ps, isp);
			if(ps.error || (e->pc != (ulong)-1 && e->pc >= (ulong)isize)){
				kwerrstr("bad exception pc");
				goto bad;
			}
		}
		if(istream >= ps.end || *istream != 0){
			kwerrstr("truncated exception table");
			goto bad;
		}
		istream++;
	}

	m->entryt = nil;
	m->entry = m->prog;
	if((ulong)entry < isize && (ulong)entryt < hsize) {
		m->entry = &m->prog[entry];
		m->entryt = m->type[entryt];
	}

	if(cflag) {
		if((m->rt&DONTCOMPILE) == 0 && !dontcompile)
			compile(m, isize, nil);
	}
	else
	if(m->rt & MUSTCOMPILE && !dontcompile) {
		if(compile(m, isize, nil) == 0) {
			kwerrstr("compiler required");
			goto bad;
		}
	}

	m->path = strdup(path);
	if(m->path == nil) {
		kwerrstr(exNomem);
		goto bad;
	}
	m->link = modules;
	modules = m;

	return m;
bad:
	destroy(m->origmp);
	if(m->ext != nil)
		destroylinks(m);
	freemod(m);
	return nil;
}

Module*
newmod(char *s)
{
	Module *m;

	m = malloc(sizeof(Module));
	if(m == nil)
		error(exNomem);
	m->ref = 1;
	m->path = s;
	m->origmp = H;
	m->name = strdup(s);
	if(m->name == nil) {
		free(m);
		error(exNomem);
	}
	m->link = modules;
	modules = m;
	m->pctab = nil;
	return m;
}

Module*
lookmod(char *s)
{
	Module *m;

	for(m = modules; m != nil; m = m->link)
		if(strcmp(s, m->path) == 0) {
			m->ref++;
			return m;
		}
	return nil;
}

void
freemod(Module *m)
{
	int i;
	Handler *h;
	Except *e;
	Import *i1, **i2;

	if(m->type != nil) {
		for(i = 0; i < m->ntype; i++)
			freetype(m->type[i]);
		free(m->type);
	}
	free(m->name);
#if defined(__aarch64__) || defined(__x86_64__) || defined(_M_X64)
	if(!m->compiled)
#endif
	free(m->prog);
	free(m->path);
	free(m->pctab);
	if(m->ldt != nil){
		for(i2 = m->ldt; *i2 != nil; i2++){
			for(i1 = *i2; i1->name != nil; i1++)
				free(i1->name);
			free(*i2);
		}
		free(m->ldt);
	}
	if(m->htab != nil){
		for(h = m->htab; h->etab != nil; h++){
			for(e = h->etab; e->s != nil; e++)
				free(e->s);
			free(h->etab);
		}
		free(m->htab);
	}
	free(m);
}

void
unload(Module *m)
{
	Module **last, *mm;

	m->ref--;
	if(m->ref > 0)
		return;
	if(m->ref == -1)
		abort();

	last = &modules;
	for(mm = modules; mm != nil; mm = mm->link) {
		if(mm == m) {
			*last = m->link;
			break;
		}
		last = &mm->link;
	}

	destroy(m->origmp);

	destroylinks(m);

	freemod(m);
}
