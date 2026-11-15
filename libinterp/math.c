#include "lib9.h"
#include "interp.h"
#include "isa.h"
#include "runt.h"
#include "raise.h"
#include "mathi.h"
#include "mathmod.h"

/*
 * Locals of each function that uses one: the native kernel runs a Dis VM
 * a core, and a static would be shared by all of them.
 */
typedef union Bits64 Bits64;
union Bits64
{
	double x;
	uvlong u;
};

typedef union Bits32 Bits32;
union Bits32
{
	float x;
	unsigned int u;
};

/*
 * An array a program passes may be nil.  Hosted, reading through H is a
 * fault the emulator turns into an exception; in the native kernels a
 * fault in the kernel's own C stops the machine.
 */
static void
notnil(Array *a)
{
	if(a == H)
		error(exNilref);
}

void
mathmodinit(void)
{
	builtinmod("$Math", Mathmodtab, Mathmodlen);
	fmtinstall('g', gfltconv);
	fmtinstall('G', gfltconv);
	fmtinstall('e', gfltconv);
	/* fmtinstall('E', gfltconv); */	/* avoid clash with ether address */
	fmtinstall(0x00c9, gfltconv);	/* L'É' */
	fmtinstall('f', gfltconv);
}

void
Math_import_int(void *fp)
{
	F_Math_import_int *f;
	int i, n;
	unsigned int u;
	unsigned char *bp;
	WORD *x;

	f = fp;
	notnil(f->b);
	notnil(f->x);
	n = f->x->len;
	if(f->b->len!=4*n)
		error(exMathia);
	bp = (unsigned char *)(f->b->data);
	x = (WORD*)(f->x->data);	/* an int is a whole word, sign-extended */
	for(i=0; i<n; i++){
		u = *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		x[i] = (int)u;
	}
}

void
Math_import_real32(void *fp)
{
	F_Math_import_int *f;
	int i, n;
	unsigned int u;
	unsigned char *bp;
	double *x;
	Bits32 bits32;

	f = fp;
	notnil(f->b);
	notnil(f->x);
	n = f->x->len;
	if(f->b->len!=4*n)
		error(exMathia);
	bp = (unsigned char *)(f->b->data);
	x = (double*)(f->x->data);
	for(i=0; i<n; i++){
		u = *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		bits32.u = u;
		x[i] = bits32.x;
	}
}

void
Math_import_real(void *fp)
{
	F_Math_import_int *f;
	int i, n;
	uvlong u;
	unsigned char *bp;
	double *x;
	Bits64 bits64;

	f = fp;
	notnil(f->b);
	notnil(f->x);
	n = f->x->len;
	if(f->b->len!=8*n)
		error(exMathia);
	bp = f->b->data;
	x = (double*)(f->x->data);
	for(i=0; i<n; i++){
		u = *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		u = (u<<8) | *bp++;
		bits64.u = u;
		x[i] = bits64.x;
	}
}

void
Math_export_int(void *fp)
{
	F_Math_export_int *f;
	int i, n;
	unsigned int u;
	unsigned char *bp;
	WORD *x;

	f = fp;
	notnil(f->b);
	notnil(f->x);
	n = f->x->len;
	if(f->b->len!=4*n)
		error(exMathia);
	bp = (unsigned char *)(f->b->data);
	x = (WORD*)(f->x->data);
	for(i=0; i<n; i++){
		u = x[i];
		*bp++ = u>>24;
		*bp++ = u>>16;
		*bp++ = u>>8;
		*bp++ = u;
	}
}

void
Math_export_real32(void *fp)
{
	F_Math_export_int *f;
	int i, n;
	unsigned int u;
	unsigned char *bp;
	double *x;
	Bits32 bits32;

	f = fp;
	notnil(f->b);
	notnil(f->x);
	n = f->x->len;
	if(f->b->len!=4*n)
		error(exMathia);
	bp = (unsigned char *)(f->b->data);
	x = (double*)(f->x->data);
	for(i=0; i<n; i++){
		bits32.x = x[i];
		u = bits32.u;
		*bp++ = u>>24;
		*bp++ = u>>16;
		*bp++ = u>>8;
		*bp++ = u;
	}
}

void
Math_export_real(void *fp)
{
	F_Math_export_int *f;
	int i, n;
	uvlong u;
	unsigned char *bp;
	double *x;
	Bits64 bits64;

	f = fp;
	notnil(f->b);
	notnil(f->x);
	n = f->x->len;
	if(f->b->len!=8*n)
		error(exMathia);
	bp = (unsigned char *)(f->b->data);
	x = (double*)(f->x->data);
	for(i=0; i<n; i++){
		bits64.x = x[i];
		u = bits64.u;
		*bp++ = u>>56;
		*bp++ = u>>48;
		*bp++ = u>>40;
		*bp++ = u>>32;
		*bp++ = u>>24;
		*bp++ = u>>16;
		*bp++ = u>>8;
		*bp++ = u;
	}
}


void
Math_bits32real(void *fp)
{
	F_Math_bits32real *f;
	Bits32 bits32;

	f = fp;
	bits32.u = f->b;
	*f->ret = bits32.x;
}

void
Math_bits64real(void *fp)
{
	F_Math_bits64real *f;
	Bits64 bits64;

	f = fp;
	bits64.u = f->b;
	*f->ret = bits64.x;
}

void
Math_realbits32(void *fp)
{
	F_Math_realbits32 *f;
	Bits32 bits32;

	f = fp;
	bits32.x = f->x;
	*f->ret = (int)bits32.u;	/* an int: sign-extended in its word */
}

void
Math_realbits64(void *fp)
{
	F_Math_realbits64 *f;
	Bits64 bits64;

	f = fp;
	bits64.x = f->x;
	*f->ret = bits64.u;
}


void
Math_getFPcontrol(void *fp)
{
	F_Math_getFPcontrol *f;

	f = fp;

	*f->ret = getFPcontrol();
}

void
Math_getFPstatus(void *fp)
{
	F_Math_getFPstatus *f;

	f = fp;

	*f->ret = getFPstatus();
}

void
Math_finite(void *fp)
{
	F_Math_finite *f;

	f = fp;

	*f->ret = finite(f->x);
}

void
Math_ilogb(void *fp)
{
	F_Math_ilogb *f;

	f = fp;

	*f->ret = ilogb(f->x);
}

void
Math_isnan(void *fp)
{
	F_Math_isnan *f;

	f = fp;

	*f->ret = isNaN(f->x);
}

void
Math_acos(void *fp)
{
	F_Math_acos *f;

	f = fp;

	*f->ret = __ieee754_acos(f->x);
}

void
Math_acosh(void *fp)
{
	F_Math_acosh *f;

	f = fp;

	*f->ret = __ieee754_acosh(f->x);
}

void
Math_asin(void *fp)
{
	F_Math_asin *f;

	f = fp;

	*f->ret = __ieee754_asin(f->x);
}

void
Math_asinh(void *fp)
{
	F_Math_asinh *f;

	f = fp;

	*f->ret = asinh(f->x);
}

void
Math_atan(void *fp)
{
	F_Math_atan *f;

	f = fp;

	*f->ret = atan(f->x);
}

void
Math_atanh(void *fp)
{
	F_Math_atanh *f;

	f = fp;

	*f->ret = __ieee754_atanh(f->x);
}

void
Math_cbrt(void *fp)
{
	F_Math_cbrt *f;

	f = fp;

	*f->ret = cbrt(f->x);
}

void
Math_ceil(void *fp)
{
	F_Math_ceil *f;

	f = fp;

	*f->ret = ceil(f->x);
}

void
Math_cos(void *fp)
{
	F_Math_cos *f;

	f = fp;

	*f->ret = cos(f->x);
}

void
Math_cosh(void *fp)
{
	F_Math_cosh *f;

	f = fp;

	*f->ret = __ieee754_cosh(f->x);
}

void
Math_erf(void *fp)
{
	F_Math_erf *f;

	f = fp;

	*f->ret = erf(f->x);
}

void
Math_erfc(void *fp)
{
	F_Math_erfc *f;

	f = fp;

	*f->ret = erfc(f->x);
}

void
Math_exp(void *fp)
{
	F_Math_exp *f;

	f = fp;

	*f->ret = __ieee754_exp(f->x);
}

void
Math_expm1(void *fp)
{
	F_Math_expm1 *f;

	f = fp;

	*f->ret = expm1(f->x);
}

void
Math_fabs(void *fp)
{
	F_Math_fabs *f;

	f = fp;

	*f->ret = fabs(f->x);
}

void
Math_floor(void *fp)
{
	F_Math_floor *f;

	f = fp;

	*f->ret = floor(f->x);
}

void
Math_j0(void *fp)
{
	F_Math_j0 *f;

	f = fp;

	*f->ret = __ieee754_j0(f->x);
}

void
Math_j1(void *fp)
{
	F_Math_j1 *f;

	f = fp;

	*f->ret = __ieee754_j1(f->x);
}

void
Math_log(void *fp)
{
	F_Math_log *f;

	f = fp;

	*f->ret = __ieee754_log(f->x);
}

void
Math_log10(void *fp)
{
	F_Math_log10 *f;

	f = fp;

	*f->ret = __ieee754_log10(f->x);
}

void
Math_log1p(void *fp)
{
	F_Math_log1p *f;

	f = fp;

	*f->ret = log1p(f->x);
}

void
Math_rint(void *fp)
{
	F_Math_rint *f;

	f = fp;

	*f->ret = rint(f->x);
}

void
Math_sin(void *fp)
{
	F_Math_sin *f;

	f = fp;

	*f->ret = sin(f->x);
}

void
Math_sinh(void *fp)
{
	F_Math_sinh *f;

	f = fp;

	*f->ret = __ieee754_sinh(f->x);
}

void
Math_sqrt(void *fp)
{
	F_Math_sqrt *f;

	f = fp;

	*f->ret = __ieee754_sqrt(f->x);
}

void
Math_tan(void *fp)
{
	F_Math_tan *f;

	f = fp;

	*f->ret = tan(f->x);
}

void
Math_tanh(void *fp)
{
	F_Math_tanh *f;

	f = fp;

	*f->ret = tanh(f->x);
}

void
Math_y0(void *fp)
{
	F_Math_y0 *f;

	f = fp;

	*f->ret = __ieee754_y0(f->x);
}

void
Math_y1(void *fp)
{
	F_Math_y1 *f;

	f = fp;

	*f->ret = __ieee754_y1(f->x);
}

void
Math_fdim(void *fp)
{
	F_Math_fdim *f;

	f = fp;

	*f->ret = fdim(f->x, f->y);
}

void
Math_fmax(void *fp)
{
	F_Math_fmax *f;

	f = fp;

	*f->ret = fmax(f->x, f->y);
}

void
Math_fmin(void *fp)
{
	F_Math_fmin *f;

	f = fp;

	*f->ret = fmin(f->x, f->y);
}

void
Math_fmod(void *fp)
{
	F_Math_fmod *f;

	f = fp;

	*f->ret = __ieee754_fmod(f->x, f->y);
}

void
Math_hypot(void *fp)
{
	F_Math_hypot *f;

	f = fp;

	*f->ret = __ieee754_hypot(f->x, f->y);
}

void
Math_nextafter(void *fp)
{
	F_Math_nextafter *f;

	f = fp;

	*f->ret = nextafter(f->x, f->y);
}

void
Math_pow(void *fp)
{
	F_Math_pow *f;

	f = fp;

	*f->ret = __ieee754_pow(f->x, f->y);
}



void
Math_FPcontrol(void *fp)
{
	F_Math_FPcontrol *f;

	f = fp;

	*f->ret = FPcontrol(f->r, f->mask);
}

void
Math_FPstatus(void *fp)
{
	F_Math_FPstatus *f;

	f = fp;

	*f->ret = FPstatus(f->r, f->mask);
}

void
Math_atan2(void *fp)
{
	F_Math_atan2 *f;

	f = fp;

	*f->ret = __ieee754_atan2(f->y, f->x);
}

void
Math_copysign(void *fp)
{
	F_Math_copysign *f;

	f = fp;

	*f->ret = copysign(f->x, f->s);
}

/*
 * jn and yn are recurrences as long as the order: one of order 2^31 takes
 * a quarter of a minute.  Past an order that takes no time the Dis VM is
 * let go for it, as IPint's long operations do, so that the other Progs
 * run meanwhile.
 */
enum { Longorder = 4096 };

static double
besseln(int y, int n, double x)
{
	double r;
	int let;

	let = n > Longorder || n < -Longorder;
	if(let)
		release();
	if(y)
		r = __ieee754_yn(n, x);
	else
		r = __ieee754_jn(n, x);
	if(let)
		acquire();
	return r;
}

void
Math_jn(void *fp)
{
	F_Math_jn *f;

	f = fp;

	*f->ret = besseln(0, f->n, f->x);
}

void
Math_lgamma(void *fp)
{
	F_Math_lgamma *f;
	int sign;

	f = fp;

	f->ret->t1 = __ieee754_lgamma_r(f->x, &sign);
	f->ret->t0 = sign;
}

void
Math_modf(void *fp)
{
	F_Math_modf *f;
	double ipart;

	f = fp;

	f->ret->t1 = modf(f->x, &ipart);
	f->ret->t0 = ipart;
}

void
Math_pow10(void *fp)
{
	F_Math_pow10 *f;

	f = fp;

	*f->ret = ipow10(f->p);
}

void
Math_remainder(void *fp)
{
	F_Math_remainder *f;

	f = fp;

	*f->ret = __ieee754_remainder(f->x, f->p);
}

void
Math_scalbn(void *fp)
{
	F_Math_scalbn *f;

	f = fp;

	*f->ret = scalbn(f->x, f->n);
}

void
Math_yn(void *fp)
{
	F_Math_yn *f;

	f = fp;

	*f->ret = besseln(1, f->n, f->x);
}


/**** sorting real vectors through permutation vector ****/
/* qsort from coma:/usr/jlb/qsort/qsort.dir/qsort.c on 28 Sep '92
 char* has been changed to uchar*, static internal functions.
 specialized to swapping the permutation's elements, which are Limbo ints:
 a WORD each (they were taken for 32-bit ints, so on a 64-bit host half
 the permutation was sorted and the other half left).
*/

/*
 * A total order: a NaN is after every number and equal to another NaN.
 * (Comparing as C does, a NaN was greater than everything both ways
 * round, and a vector of them split one element at a time.)
 */
static int
cmp(WORD *u, WORD *v, double *x)
{
	double a, b;

	a = x[*u];
	b = x[*v];
	if(a == b)
		return 0;
	if(a < b)
		return -1;
	if(a > b)
		return 1;
	if(a != a)
		return b != b? 0: 1;
	return -1;
}

#define swap(u, v) {WORD t = *(u); *(u) = *(v); *(v) = t;}

#define vecswap(u, v, n) if(n>0){	\
    int i = n;				\
    register WORD *pi = u;		\
    register WORD *pj = v;		\
    do {				\
        register WORD t = *pi;		\
        *pi++ = *pj;			\
        *pj++ = t;			\
    } while (--i > 0);			\
}

#define minimum(x, y) ((x)<=(y) ? (x) : (y))

static WORD *
med3(WORD *a, WORD *b, WORD *c, double *x)
{	return cmp(a, b, x) < 0 ?
		  (cmp(b, c, x) < 0 ? b : (cmp(a, c, x) < 0 ? c : a ) )
		: (cmp(b, c, x) > 0 ? b : (cmp(a, c, x) < 0 ? a : c ) );
}

/* heap sort: what rqsort falls back to when its partitions are bad */
static void
sift(WORD *a, int i, int n, double *x)
{
	int c;

	for(;;){
		c = 2*i+1;
		if(c >= n)
			break;
		if(c+1 < n && cmp(a+c, a+c+1, x) < 0)
			c++;
		if(cmp(a+i, a+c, x) >= 0)
			break;
		swap(a+i, a+c);
		i = c;
	}
}

static void
rhsort(WORD *a, int n, double *x)
{
	int i;

	for(i = n/2-1; i >= 0; i--)
		sift(a, i, n, x);
	for(i = n-1; i > 0; i--){
		swap(a, a+i);
		sift(a, 0, i, x);
	}
}

/*
 * It recursed on both parts, on a Dis process's C stack (some 300 of its
 * frames hosted, fewer in the native kernels): a vector chosen to split
 * badly, or simply 400 NaNs, ran off the end of it.  The smaller part is
 * recursed on and the larger looped on, so the depth is at most log2 n;
 * and after lim partitions that did not halve, what is left is heap
 * sorted, so the time is n log n whatever the vector.
 */
static void
rqsort(WORD *a, int n, double *x, int lim)
{
	WORD *pa, *pb, *pc, *pd, *pl, *pm, *pn;
	int  d, r;

again:
	if (n < 7) { /* Insertion sort on small arrays */
		for (pm = a + 1; pm < a + n; pm++)
			for (pl = pm; pl > a && cmp(pl-1, pl, x) > 0; pl--)
				swap(pl, pl-1);
		return;
	}
	if (lim-- <= 0) {
		rhsort(a, n, x);
		return;
	}
	pm = a + (n/2);
	if (n > 7) {
		pl = a;
		pn = a + (n-1);
		if (n > 40) { /* On big arrays, pseudomedian of 9 */
			d = (n/8);
			pl = med3(pl, pl+d, pl+2*d, x);
			pm = med3(pm-d, pm, pm+d, x);
			pn = med3(pn-2*d, pn-d, pn, x);
		}
		pm = med3(pl, pm, pn, x); /* On mid arrays, med of 3 */
	}
	swap(a, pm); /* On tiny arrays, partition around middle */
	pa = pb = a + 1;
	pc = pd = a + (n-1);
	for (;;) {
		while (pb <= pc && (r = cmp(pb, a, x)) <= 0) {
			if (r == 0) { swap(pa, pb); pa++; }
			pb++;
		}
		while (pb <= pc && (r = cmp(pc, a, x)) >= 0) {
			if (r == 0) { swap(pc, pd); pd--; }
			pc--;
		}
		if (pb > pc) break;
		swap(pb, pc);
		pb++;
		pc--;
	}
	pn = a + n;
	r = minimum(pa-a,  pb-pa);   vecswap(a,  pb-r, r);
	r = minimum(pd-pc, pn-pd-1); vecswap(pb, pn-r, r);
	r = pb-pa;	/* the part less than the pivot, at a */
	d = pd-pc;	/* the part greater, at pn-d */
	if (r < d) {
		if (r > 1) rqsort(a, r, x, lim);
		a = pn-d;
		n = d;
	} else {
		if (d > 1) rqsort(pn-d, d, x, lim);
		n = r;
	}
	if (n > 1)
		goto again;
}

void
Math_sort(void*fp)
{
	F_Math_sort *f;
	int	i, pilen, xlen, lim;
	WORD	*p;

	f = fp;
	notnil(f->x);
	notnil(f->pi);

	/* check that permutation contents are in [0,n-1] !!! */
	p = (WORD*) (f->pi->data);
	pilen = f->pi->len;
	xlen = f->x->len - 1;

	for(i = 0; i < pilen; i++) {
		if((*p < 0) || (xlen < *p))
			error(exMathia);
		p++;
	}

	/* twice log2 of the length, and a few */
	lim = 8;
	for(i = pilen; i > 1; i >>= 1)
		lim += 2;
	rqsort( (WORD*)(f->pi->data), pilen, (double*)(f->x->data), lim);
}


/************ BLAS ***************/

void
Math_dot(void *fp)
{
	F_Math_dot *f;

	f = fp;
	notnil(f->x);
	notnil(f->y);
	if(f->x->len!=f->y->len)
		error(exMathia);	/* incompatible lengths */
	*f->ret = dot(f->x->len, (double*)(f->x->data), (double*)(f->y->data));
}

void
Math_iamax(void *fp)
{
	F_Math_iamax *f;

	f = fp;
	notnil(f->x);

	*f->ret = iamax(f->x->len, (double*)(f->x->data));
}

void
Math_norm2(void *fp)
{
	F_Math_norm2 *f;

	f = fp;
	notnil(f->x);

	*f->ret = norm2(f->x->len, (double*)(f->x->data));
}

void
Math_norm1(void *fp)
{
	F_Math_norm1 *f;

	f = fp;
	notnil(f->x);

	*f->ret = norm1(f->x->len, (double*)(f->x->data));
}

/*
 * Does a column-major matrix of nrow rows and ncol columns, with leading
 * dimension ld, lie inside the array a?  Its last element is at
 * ld*(ncol-1) + nrow-1.  (The test was ld*(ncol-1) > len, in an int: it
 * left the rows out, so a matrix of one column was not looked at at all,
 * and the product wrapped.)  A matrix with no elements is not touched,
 * and may be nil.
 */
static int
ldok(Array *a, int ld, int nrow, int ncol)
{
	if(nrow == 0 || ncol == 0)
		return 1;
	if(a == H || ld < nrow)
		return 0;
	return (vlong)ld*(ncol-1) + nrow <= a->len;
}

void
Math_gemm(void *fp)
{
	F_Math_gemm *f = fp;
	int nrowa, ncola, nrowb, ncolb, m, n, k;
	double *adata = 0, *bdata = 0, *cdata = 0;
	int nota = f->transa=='N';
	int notb = f->transb=='N';

	m = f->m;
	n = f->n;
	k = f->k;
	if(     (!nota && f->transa!='C' && f->transa!='T') ||
		(!notb && f->transb!='C' && f->transb!='T') ||
		(m < 0 || n < 0 || k < 0) ){
		error(exMathia);
	}
	/* the shapes gemm() reads, which follow its own cases */
	if(m == 0 || n == 0 || f->alpha == 0.){
		/* a and b are not read */
		nrowa = ncola = nrowb = ncolb = 0;
	}else if(f->a == H){
		/* C := alpha*B + beta*C, or B': B is m by n, k plays no part */
		nrowa = ncola = 0;
		if(notb){
			nrowb = m;
			ncolb = n;
		}else{
			nrowb = n;
			ncolb = m;
		}
		if(f->b == H)
			error(exNilref);
	}else{
		if(nota){
			nrowa = m;
			ncola = k;
		}else{
			nrowa = k;
			ncola = m;
		}
		if(notb){
			nrowb = k;
			ncolb = n;
		}else{
			nrowb = n;
			ncolb = k;
		}
	}
	if(!ldok(f->a, f->lda, nrowa, ncola)
	|| !ldok(f->b, f->ldb, nrowb, ncolb)
	|| !ldok(f->c, f->ldc, m, n))
		error(exBounds);
	if(f->a != H)
		adata = (double*)(f->a->data);
	if(f->b != H)
		bdata = (double*)(f->b->data);
	if(f->c != H)
		cdata = (double*)(f->c->data);

	gemm(f->transa, f->transb, m, n, k, f->alpha,
		adata, f->lda, bdata, f->ldb, f->beta, cdata, f->ldc);
}
