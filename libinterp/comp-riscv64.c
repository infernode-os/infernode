/*
 * RISC-V (RV64GC, LP64D) JIT compiler for the Dis Virtual Machine.
 *
 * A port of comp-arm64.c: the same register-cached VM state, the same
 * punt-to-C for everything complicated, the same macros at the end of
 * each module. What is RISC-V's own:
 *
 *   Branch reach. A conditional branch reaches +-4KiB, a JAL +-1MiB,
 *   and big modules (limbo.dis) are several MiB of code. Every branch
 *   whose target is a Dis instruction or a macro is a "site" and is
 *   relaxed: pass 0 sizes every site at its longest form and records
 *   where it is, pass 1 picks the shortest form that the pass-0 layout
 *   proves will reach (pass 1 can only shrink code, so distances only
 *   shrink), and pass 2 emits exactly the forms pass 1 picked.
 *
 *   Constants. There is no load-literal and a 64-bit address takes up
 *   to eight instructions to build, so the addresses of C functions and
 *   data (&R, rdestroy, a module's types) come from a per-module pool
 *   after the code, two instructions away (auipc+ld). Code addresses
 *   (return addresses, the literal pool) are PC-relative (auipc+addi).
 *
 *   Faults. RISC-V never traps on division, so the zero divisor is
 *   tested and raised here. A bounds, nil or zero-divide fault calls
 *   its macro with a jal, whose link register says where in the module
 *   it happened, and the macro stores that as R.PC (and the cached
 *   frame pointer as R.FP) before raising: handler() in exception.c
 *   then finds the right handler for it. Every punt stores R.PC too.
 *
 *   Bounds. Array indexing is always checked, as the interpreter
 *   checks it: this JIT does not consult bflag, which nothing in this
 *   tree sets (emu -b is documented as on by default, but bflag starts
 *   at zero), so honouring it would compile every index unchecked.
 *
 *   Instruction-cache coherence. A hosted build flushes with
 *   segflush(), which asks the kernel to synchronise every hart
 *   (riscv_flush_icache); a native kernel provides cacheiflush().
 *
 * Every instruction emitted is 32 bits (no C extension in JIT code),
 * so compiled PCs are 4-aligned like every other fixed-width target.
 */

#include "lib9.h"
#include "isa.h"
#include "interp.h"
#include "raise.h"

#ifdef INFERNO_NATIVE
extern void	cacheiflush(void*, ulong);
#else
#include <sys/mman.h>
#include <unistd.h>
#endif

#define	RESCHED	1	/* check for interpreter reschedule */

enum
{
	/* integer registers */
	RZERO	= 0,
	RLINK	= 1,	/* ra */
	RSP	= 2,	/* sp */
	RTA	= 5,	/* t0: temp address, long-branch scratch */
	RCON	= 6,	/* t1: constant builder */
	RT2	= 7,	/* t2: maccase's saved table */
	RS0	= 8,	/* s0 */
	RREG	= 9,	/* s1: &R (callee-saved) */
	RA0	= 10,	/* a0: scratch / arg0 / return value */
	RA1	= 11,	/* a1 */
	RA2	= 12,	/* a2 */
	RA3	= 13,	/* a3 */
	RFP	= 18,	/* s2: cached R.FP (callee-saved) */
	RMP	= 19,	/* s3: cached R.MP (callee-saved) */

	/* FP scratch registers */
	FA0	= 0,	/* ft0 */
	FA1	= 1,	/* ft1 */

	/* comparison conditions, abstract; cmpbr() maps them */
	EQ	= 0,
	NE,
	LT,
	LE,
	GT,
	GE,
	LO,	/* unsigned < */
	HS,	/* unsigned >= */
	LS,	/* unsigned <= */
	HI,	/* unsigned > */

	/* branch funct3 */
	FBEQ	= 0,
	FBNE	= 1,
	FBLT	= 4,
	FBGE	= 5,
	FBLTU	= 6,
	FBGEU	= 7,

	/* Memory operation types */
	Lea	= 100,
	Ldw,		/* load 64-bit word */
	Stw,		/* store 64-bit word */
	Ldb,		/* load byte (zero-extend) */
	Stb,		/* store byte */
	Ldw32,		/* load 32-bit word (zero-extend) */
	Stw32,		/* store 32-bit word */
	Ldw32s,		/* load 32-bit word (sign-extend) */
	Ldh,		/* load halfword (zero-extend) */

	/* Punt flags */
	SRCOP	= (1<<0),
	DSTOP	= (1<<1),
	WRTPC	= (1<<2),
	TCHECK	= (1<<3),
	NEWPC	= (1<<4),
	DBRAN	= (1<<5),
	THREOP	= (1<<6),
	MODCHK	= (1<<7),	/* the op may have made R.M an interpreted module (IMCALL) */

	/* Macro indices */
	MacFRP	= 0,
	MacRET,
	MacCASE,
	MacCOLR,
	MacMCAL,
	MacFRAM,
	MacMFRA,
	MacRELQ,
	MacBNDS,
	MacZDIV,
	MacNIL,
	NMACRO,

	/* relaxed branch kinds */
	BrJ	= 0,	/* jump */
	BrCall,		/* jump and link */
	BrCond,		/* conditional jump */
	BrCondCall,	/* conditional jump and link */

	/* relaxed branch forms */
	FShort	= 0,
	FMedium,
	FLong,

	PASSEMIT	= 2,
};

/*
 * Instruction encodings.
 */
#define	OPLOAD	0x03
#define	OPLOADFP	0x07
#define	OPIMM	0x13
#define	OPAUIPC	0x17
#define	OPIMM32	0x1B
#define	OPSTORE	0x23
#define	OPSTOREFP	0x27
#define	OPREG	0x33
#define	OPLUI	0x37
#define	OPREG32	0x3B
#define	OPFP	0x53
#define	OPBRANCH	0x63
#define	OPJALR	0x67
#define	OPJAL	0x6F

#define	RTYPE(f7, rs2, rs1, f3, rd, op) \
	emit(((u32int)(f7)<<25)|((rs2)<<20)|((rs1)<<15)|((f3)<<12)|((rd)<<7)|(op))
#define	ITYPE(imm, rs1, f3, rd, op) \
	emit((((u32int)(imm)&0xFFF)<<20)|((rs1)<<15)|((f3)<<12)|((rd)<<7)|(op))
#define	STYPE(imm, rs2, rs1, f3, op) \
	emit(((((u32int)(imm)>>5)&0x7F)<<25)|((rs2)<<20)|((rs1)<<15)|((f3)<<12)|(((u32int)(imm)&0x1F)<<7)|(op))
#define	UTYPE(imm20, rd, op) \
	emit((((u32int)(imm20)&0xFFFFF)<<12)|((rd)<<7)|(op))

#define	ADD(rd, rs1, rs2)	RTYPE(0x00, rs2, rs1, 0, rd, OPREG)
#define	SUB(rd, rs1, rs2)	RTYPE(0x20, rs2, rs1, 0, rd, OPREG)
#define	SLL(rd, rs1, rs2)	RTYPE(0x00, rs2, rs1, 1, rd, OPREG)
#define	XOR(rd, rs1, rs2)	RTYPE(0x00, rs2, rs1, 4, rd, OPREG)
#define	SRL(rd, rs1, rs2)	RTYPE(0x00, rs2, rs1, 5, rd, OPREG)
#define	SRA(rd, rs1, rs2)	RTYPE(0x20, rs2, rs1, 5, rd, OPREG)
#define	OR(rd, rs1, rs2)	RTYPE(0x00, rs2, rs1, 6, rd, OPREG)
#define	AND(rd, rs1, rs2)	RTYPE(0x00, rs2, rs1, 7, rd, OPREG)
#define	MUL(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 0, rd, OPREG)
#define	DIV(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 4, rd, OPREG)
#define	DIVU(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 5, rd, OPREG)
#define	REM(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 6, rd, OPREG)
#define	REMU(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 7, rd, OPREG)
#define	ADDW(rd, rs1, rs2)	RTYPE(0x00, rs2, rs1, 0, rd, OPREG32)
#define	SUBW(rd, rs1, rs2)	RTYPE(0x20, rs2, rs1, 0, rd, OPREG32)
#define	MULW(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 0, rd, OPREG32)
#define	DIVW(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 4, rd, OPREG32)
#define	REMW(rd, rs1, rs2)	RTYPE(0x01, rs2, rs1, 6, rd, OPREG32)

#define	ADDI(rd, rs1, imm)	ITYPE(imm, rs1, 0, rd, OPIMM)
#define	ANDI(rd, rs1, imm)	ITYPE(imm, rs1, 7, rd, OPIMM)
#define	SLLI(rd, rs1, sh)	ITYPE((sh)&0x3F, rs1, 1, rd, OPIMM)
#define	SRLI(rd, rs1, sh)	ITYPE((sh)&0x3F, rs1, 5, rd, OPIMM)
#define	ADDIW(rd, rs1, imm)	ITYPE(imm, rs1, 0, rd, OPIMM32)
#define	SEXTW(rd, rs)		ADDIW(rd, rs, 0)
#define	MV(rd, rs)		ADDI(rd, rs, 0)
#define	NEG(rd, rs)		SUB(rd, RZERO, rs)
#define	LUI(rd, imm20)		UTYPE(imm20, rd, OPLUI)
#define	AUIPC(rd, imm20)	UTYPE(imm20, rd, OPAUIPC)
#define	JALR(rd, rs1, imm)	ITYPE(imm, rs1, 0, rd, OPJALR)
#define	JR(rs)			JALR(RZERO, rs, 0)
#define	RET()			JALR(RZERO, RLINK, 0)
#define	CALLR(rs)		JALR(RLINK, rs, 0)
#define	NOP()			ADDI(RZERO, RZERO, 0)
#define	EBREAK()		emit(0x00100073)

#define	LD(rd, rs1, imm)	ITYPE(imm, rs1, 3, rd, OPLOAD)
#define	LW(rd, rs1, imm)	ITYPE(imm, rs1, 2, rd, OPLOAD)
#define	LWU(rd, rs1, imm)	ITYPE(imm, rs1, 6, rd, OPLOAD)
#define	LHU(rd, rs1, imm)	ITYPE(imm, rs1, 5, rd, OPLOAD)
#define	LBU(rd, rs1, imm)	ITYPE(imm, rs1, 4, rd, OPLOAD)
#define	SD(rs2, rs1, imm)	STYPE(imm, rs2, rs1, 3, OPSTORE)
#define	SW(rs2, rs1, imm)	STYPE(imm, rs2, rs1, 2, OPSTORE)
#define	SB(rs2, rs1, imm)	STYPE(imm, rs2, rs1, 0, OPSTORE)
#define	FLD(fd, rs1, imm)	ITYPE(imm, rs1, 3, fd, OPLOADFP)
#define	FSD(fs2, rs1, imm)	STYPE(imm, fs2, rs1, 3, OPSTOREFP)

/* double-precision arithmetic; rm 7 is the dynamic rounding mode */
#define	FADDD(fd, fs1, fs2)	RTYPE(0x01, fs2, fs1, 7, fd, OPFP)
#define	FSUBD(fd, fs1, fs2)	RTYPE(0x05, fs2, fs1, 7, fd, OPFP)
#define	FMULD(fd, fs1, fs2)	RTYPE(0x09, fs2, fs1, 7, fd, OPFP)
#define	FDIVD(fd, fs1, fs2)	RTYPE(0x0D, fs2, fs1, 7, fd, OPFP)
#define	FNEGD(fd, fs)		RTYPE(0x11, fs, fs, 1, fd, OPFP)	/* fsgnjn.d */
#define	FEQD(rd, fs1, fs2)	RTYPE(0x51, fs2, fs1, 2, rd, OPFP)
#define	FLTD(rd, fs1, fs2)	RTYPE(0x51, fs2, fs1, 1, rd, OPFP)
#define	FLED(rd, fs1, fs2)	RTYPE(0x51, fs2, fs1, 0, rd, OPFP)
#define	FCVTDL(fd, rs)		RTYPE(0x69, 2, rs, 7, fd, OPFP)		/* int64 -> double */
#define	FCVTLD(rd, fs)		RTYPE(0x61, 2, fs, 1, rd, OPFP)		/* double -> int64, toward zero */
#define	FMVDX(fd, rs)		RTYPE(0x79, 0, rs, 0, fd, OPFP)

/* local conditional branch, offset in bytes; |off| < 4KiB */
#define	BRANCH(f3, rs1, rs2, off)	emit(btype(off, rs2, rs1, f3))
#define	BEQZ(rs, off)	BRANCH(FBEQ, rs, RZERO, off)
#define	BNEZ(rs, off)	BRANCH(FBNE, rs, RZERO, off)

/* Patch helpers */
#define	RELPC(pc)	((ulong)(base + (pc)))

/*
 * Static globals
 */
static	u32int*	code;
static	u32int*	codestart;	/* code's buffer: tmp while sizing, base when emitting */
static	u32int*	base;
static	ulong*	patch;
static	ulong*	patch0;		/* pass 0's layout, which pass 1's choices are made against */
static	long	codeoff;
static	int	pass;
static	int	inmod;		/* compiling a module: sites, pools and passes exist */
static	int	incompile;	/* #635 tripwire: compile() is not reentrant */
static	Module*	mod;
static	uchar*	tinit;
static	ulong*	litpool;
static	ulong*	litlimit;
static	int	nlit;
static	ulong	macro[NMACRO];
static	ulong	macro0[NMACRO];
	void	(*comvec)(void);

/* relaxed branch sites */
static	long*	sitepos0;	/* pass 0: where each site is */
static	uchar*	siteform;	/* pass 1: the form it gets */
static	int	nsite;
static	int	maxsite;
static	int	site;

/* address pool: pass 2 dedups into it, passes 0 and 1 count its worst case */
static	uvlong*	cpool;
static	int	ncpool;		/* entries in use */
static	int	ncon;		/* worst case */
static	int*	chash;		/* open-addressed index of cpool, -1 empty */
static	int	nchash;

static	void	macfrp(void);
static	void	macret(void);
static	void	maccase(void);
static	void	maccolr(void);
static	void	macmcal(void);
static	void	macfram(void);
static	void	macmfra(void);
static	void	macrelq(void);
static	void	macbounds(void);
static	void	maczdiv(void);
static	void	macnil(void);
static	void	movmem(Inst*);
static	void	mid(Inst*, int, int);
static	void	mem(int, long, int, int);
extern	void	das(u32int*, int);

#define T(r)	*((void**)(R.r))

static struct
{
	int	idx;
	void	(*gen)(void);
	char*	name;
} mactab[] =
{
	{ MacFRP,	macfrp,		"FRP" },
	{ MacRET,	macret,		"RET" },
	{ MacCASE,	maccase,	"CASE" },
	{ MacCOLR,	maccolr,	"COLR" },
	{ MacMCAL,	macmcal,	"MCAL" },
	{ MacFRAM,	macfram,	"FRAM" },
	{ MacMFRA,	macmfra,	"MFRA" },
	{ MacRELQ,	macrelq,	"RELQ" },
	{ MacBNDS,	macbounds,	"BNDS" },
	{ MacZDIV,	maczdiv,	"ZDIV" },
	{ MacNIL,	macnil,		"NIL" },
};

static void
compiledone(void)
{
	incompile = 0;
	inmod = 0;
}

static void
emit(u32int w)
{
	*code++ = w;
}

/* word index of the next instruction in the module being compiled */
static long
pos(void)
{
	return codeoff + (code - codestart);
}

static u32int
btype(long off, int rs2, int rs1, int f3)
{
	return (((off>>12)&1)<<31) | (((off>>5)&0x3F)<<25) | ((u32int)rs2<<20) |
		((u32int)rs1<<15) | ((u32int)f3<<12) | (((off>>1)&0xF)<<8) |
		(((off>>11)&1)<<7) | OPBRANCH;
}

static u32int
jtype(long off, int rd)
{
	return (((off>>20)&1)<<31) | (((off>>1)&0x3FF)<<21) | (((off>>11)&1)<<20) |
		(((off>>12)&0xFF)<<12) | ((u32int)rd<<7) | OPJAL;
}

/* a local forward branch, patched by patchb() when its target is reached */
static u32int*
bfwd(int f3, int rs1, int rs2)
{
	u32int *p;

	p = code;
	BRANCH(f3, rs1, rs2, 0);
	return p;
}

static u32int*
jfwd(void)
{
	u32int *p;

	p = code;
	emit(jtype(0, RZERO));
	return p;
}

static void
patchb(u32int *p)
{
	long off;

	off = (code - p) * 4;
	if((*p & 0x7F) == OPJAL)
		*p = jtype(off, (*p>>7)&0x1F);
	else
		*p = btype(off, (*p>>20)&0x1F, (*p>>15)&0x1F, (*p>>12)&7);
}

/* local backward jump to an earlier point in the same buffer */
static void
jback(u32int *to)
{
	emit(jtype((to - code) * 4, RZERO));
}

static void
urk(char *s)
{
	print("compile failed: %s\n", s);
	error(exCompile);
}

static void
bounds(void)
{
	error(exBounds);
}

static void
zdiv(void)
{
	error(exZdiv);
}

static void
nilref(void)
{
	error(exNilref);
}

static void
rdestroy(void)
{
	destroy(R.s);
}

static void
rmcall(void)
{
	Frame *f;
	Prog *p;

	if((void*)R.dt == H)
		error(exModule);

	f = (Frame*)R.FP;
	if(f == H)
		error(exModule);

	f->mr = nil;
	((void(*)(Frame*))R.dt)(f);
	R.SP = (uchar*)f;
	R.FP = f->fp;
	if(f->t == nil)
		unextend(f);
	else
		freeptrs(f, f->t);
	p = currun();
	if(p->kill != nil)
		error(p->kill);
}

static void
rmfram(void)
{
	Type *t;
	Frame *f;
	uchar *nsp;

	if(R.d == H)
		error(exModule);
	t = (Type*)R.s;
	if(t == H)
		error(exModule);
	nsp = R.SP + t->size;
	if(nsp >= R.TS) {
		R.s = t;
		extend();
		T(d) = R.s;
		return;
	}
	f = (Frame*)R.SP;
	R.SP = nsp;
	f->t = t;
	f->mr = nil;
	initmem(t, f);
	T(d) = f;
}

/*
 * li -- load a constant whose value is the same in every pass
 * (an immediate, an offset, a size), in as few instructions as it
 * takes: one for 12 bits, two for 32, up to eight for 64.
 */
static void
li(int rd, vlong val)
{
	vlong lo, hi;
	int sh;

	if(val >= -2048 && val < 2048) {
		ADDI(rd, RZERO, val);
		return;
	}
	if(val == (vlong)(int)val) {
		lo = (val << 52) >> 52;
		hi = ((val - lo) >> 12) & 0xFFFFF;
		LUI(rd, hi);
		if(lo != 0)
			ADDIW(rd, rd, lo);
		return;
	}
	lo = (val << 52) >> 52;
	hi = (val - lo) >> 12;
	sh = 12;
	while((hi & 1) == 0) {
		hi >>= 1;
		sh++;
	}
	li(rd, hi);
	SLLI(rd, rd, sh);
	if(lo != 0)
		ADDI(rd, rd, lo);
}

/* split a PC-relative byte offset for auipc + a 12-bit signed low part */
static void
splitrel(long off, long *hi, long *lo)
{
	*lo = ((vlong)off << 52) >> 52;
	*hi = ((off - *lo) >> 12) & 0xFFFFF;
}

/*
 * conpos -- the address of word wpos of the module being compiled,
 * PC-relative, always two instructions.
 */
static void
conpos(long wpos, int rd)
{
	long hi, lo;

	if(pass != PASSEMIT) {
		AUIPC(rd, 0);
		ADDI(rd, rd, 0);
		return;
	}
	splitrel((wpos - pos()) * 4, &hi, &lo);
	AUIPC(rd, hi);
	ADDI(rd, rd, lo);
}

/* conptr -- an address inside the module's own mapping (the literal pool) */
static void
conptr(void *p, int rd)
{
	long hi, lo;

	if(pass != PASSEMIT) {
		AUIPC(rd, 0);
		ADDI(rd, rd, 0);
		return;
	}
	splitrel((uchar*)p - (uchar*)code, &hi, &lo);
	AUIPC(rd, hi);
	ADDI(rd, rd, lo);
}

static uvlong*
cpoolslot(uvlong val)
{
	uint h;
	int k;

	h = (uint)(val ^ (val >> 29) ^ (val >> 47)) * 2654435761U;
	for(k = h % nchash; chash[k] >= 0; k = (k + 1) % nchash)
		if(cpool[chash[k]] == val)
			return &cpool[chash[k]];
	if(ncpool >= ncon)
		urk("constant pool overflow");
	chash[k] = ncpool;
	cpool[ncpool] = val;
	return &cpool[ncpool++];
}

/*
 * conaddr -- a C address (function, global, type): from the module's
 * address pool when compiling one, two instructions; spelled out with
 * li() otherwise (preamble, type code), where there is no pool.
 */
static void
conaddr(uvlong val, int rd)
{
	long hi, lo;

	if(!inmod) {
		li(rd, val);
		return;
	}
	if(pass == 0)
		ncon++;
	if(pass != PASSEMIT) {
		AUIPC(rd, 0);
		LD(rd, rd, 0);
		return;
	}
	splitrel((uchar*)cpoolslot(val) - (uchar*)code, &hi, &lo);
	AUIPC(rd, hi);
	LD(rd, rd, lo);
}

/*
 * Relaxed branches to Dis instructions and macros. A target is
 * TDIS(pc) or TMAC(idx).
 */
#define	TDIS(pc)	((long)(pc))
#define	TMAC(idx)	(-1 - (long)(idx))

static long
tpos(long t, ulong *ptab, ulong *mtab)
{
	if(t >= 0)
		return ptab[t];
	return mtab[-1 - t];
}

static int
brsize(int kind, int form)
{
	switch(kind) {
	case BrJ:
	case BrCall:
		return form == FShort? 1: 2;
	case BrCond:
		return form == FShort? 1: form == FMedium? 2: 3;
	case BrCondCall:
		return form == FMedium? 2: 3;
	}
	return 0;
}

static int
brform(int kind, long d)
{
	if(d < 0)
		d = -d;
	d += 16;		/* the jump sits up to two words into its site */
	switch(kind) {
	case BrJ:
	case BrCall:
		return d < (1<<20)? FShort: FLong;
	case BrCond:
		if(d < (1<<12))
			return FShort;
		return d < (1<<20)? FMedium: FLong;
	case BrCondCall:
		return d < (1<<20)? FMedium: FLong;
	}
	return FLong;
}

static void
relbr(int kind, int f3, int rs1, int rs2, long target)
{
	int form, k, rd;
	long off, hi, lo;

	if(pass == 0) {
		if(nsite >= maxsite) {
			maxsite = maxsite? 2*maxsite: 1024;
			sitepos0 = realloc(sitepos0, maxsite * sizeof(*sitepos0));
			if(sitepos0 == nil)
				urk("no memory for branch sites");
		}
		sitepos0[nsite++] = pos();
		form = FLong;
	} else if(pass == 1) {
		if(site >= nsite)
			urk("branch site phase error");
		form = brform(kind, (tpos(target, patch0, macro0) - sitepos0[site]) * 4);
		siteform[site++] = form;
	} else {
		if(site >= nsite)
			urk("branch site phase error");
		form = siteform[site++];
	}

	if(pass != PASSEMIT) {
		for(k = brsize(kind, form); k > 0; k--)
			NOP();
		return;
	}

	rd = (kind == BrCall || kind == BrCondCall)? RLINK: RZERO;
	if(kind == BrCond || kind == BrCondCall) {
		if(kind == BrCond && form == FShort) {
			off = (tpos(target, patch, macro) - pos()) * 4;
			BRANCH(f3, rs1, rs2, off);
			return;
		}
		/* inverted condition skips the jump that follows */
		BRANCH(f3 ^ 1, rs1, rs2, brsize(kind, form) * 4);
	}
	off = (tpos(target, patch, macro) - pos()) * 4;
	if(form == FLong) {
		splitrel(off, &hi, &lo);
		k = rd == RLINK? RLINK: RTA;
		AUIPC(k, hi);
		JALR(rd, k, lo);
		return;
	}
	emit(jtype(off, rd));
}

static void
bradis(long dispc)
{
	relbr(BrJ, 0, 0, 0, TDIS(dispc));
}

static void
bramac(int macidx)
{
	relbr(BrJ, 0, 0, 0, TMAC(macidx));
}

static void
blmac(int macidx)
{
	relbr(BrCall, 0, 0, 0, TMAC(macidx));
}

/* the funct3 and operand order that branch if (a cond b) */
static void
cmpop(int cond, int a, int b, int *f3, int *rs1, int *rs2)
{
	*rs1 = a;
	*rs2 = b;
	switch(cond) {
	case EQ:	*f3 = FBEQ; break;
	case NE:	*f3 = FBNE; break;
	case LT:	*f3 = FBLT; break;
	case GE:	*f3 = FBGE; break;
	case LO:	*f3 = FBLTU; break;
	case HS:	*f3 = FBGEU; break;
	case GT:	*f3 = FBLT; *rs1 = b; *rs2 = a; break;
	case LE:	*f3 = FBGE; *rs1 = b; *rs2 = a; break;
	case HI:	*f3 = FBLTU; *rs1 = b; *rs2 = a; break;
	case LS:	*f3 = FBGEU; *rs1 = b; *rs2 = a; break;
	default:	urk("cmpop");
	}
}

/* branch to a Dis instruction if (a cond b) */
static void
cmpbra(int cond, int a, int b, long dispc)
{
	int f3, rs1, rs2;

	cmpop(cond, a, b, &f3, &rs1, &rs2);
	relbr(BrCond, f3, rs1, rs2, TDIS(dispc));
}

/* call a fault macro if (a cond b) */
static void
cmpfault(int cond, int a, int b, int macidx)
{
	int f3, rs1, rs2;

	cmpop(cond, a, b, &f3, &rs1, &rs2);
	relbr(BrCondCall, f3, rs1, rs2, TMAC(macidx));
}

/* fault with macidx if r holds H */
static void
nilcheck(int r, int macidx)
{
	ADDI(RCON, RZERO, -1);
	cmpfault(EQ, r, RCON, macidx);
}

/*
 * big -- RCON = rbase + off, for an offset that does not fit a 12-bit
 * immediate.  off is always the same in every pass.
 */
static void
big(long off, int rbase)
{
	li(RCON, off);
	ADD(RCON, RCON, rbase);
}

/*
 * mem -- load or store at base register + byte offset.
 */
static void
mem(int inst, long off, int rbase, int r)
{
	if(inst == Lea) {
		if(off >= -2048 && off < 2048)
			ADDI(r, rbase, off);
		else {
			li(RCON, off);
			ADD(r, rbase, RCON);
		}
		return;
	}
	if(off < -2048 || off >= 2048) {
		big(off, rbase);
		rbase = RCON;
		off = 0;
	}
	switch(inst) {
	case Ldw:	LD(r, rbase, off); break;
	case Stw:	SD(r, rbase, off); break;
	case Ldb:	LBU(r, rbase, off); break;
	case Stb:	SB(r, rbase, off); break;
	case Ldw32:	LWU(r, rbase, off); break;
	case Ldw32s:	LW(r, rbase, off); break;
	case Stw32:	SW(r, rbase, off); break;
	case Ldh:	LHU(r, rbase, off); break;
	default:	urk("mem");
	}
}

/*
 * Float memory operations -- load/store doubles via f registers.
 */
static void
memfl(int inst, long off, int rbase, int fr)
{
	if(off < -2048 || off >= 2048) {
		big(off, rbase);
		rbase = RCON;
		off = 0;
	}
	switch(inst) {
	case Ldw:	FLD(fr, rbase, off); break;
	case Stw:	FSD(fr, rbase, off); break;
	default:	urk("memfl");
	}
}

/*
 * literal -- store a value in the literal pool and put its address in R.roff.
 * The value is stored only when emitting: in the passes before, the pool
 * does not exist yet and a code address has no value.
 */
static void
literal(uvlong imm, int roff)
{
	nlit++;
	if(pass != PASSEMIT) {
		conptr(nil, RTA);
		mem(Stw, roff, RREG, RTA);
		return;
	}
	if(litpool >= litlimit)
		urk("literal pool overflow");
	*litpool = imm;
	conptr(litpool, RTA);
	mem(Stw, roff, RREG, RTA);
	litpool++;
}

/*
 * opx -- decode Dis addressing mode and perform load/store.
 */
static void
opx(int mode, Adr *a, int mi, int r, int loff)
{
	int ir, rta;

	switch(mode) {
	default:
		urk("opx");
	case AFP:
		mem(mi, a->ind, RFP, r);
		return;
	case AMP:
		mem(mi, a->ind, RMP, r);
		return;
	case AIMM:
		li(r, a->imm);
		if(mi == Lea) {
			mem(Stw, loff, RREG, r);
			mem(Lea, loff, RREG, r);
		}
		return;
	case AIND|AFP:
		ir = RFP;
		break;
	case AIND|AMP:
		ir = RMP;
		break;
	}
	rta = RTA;
	if(mi == Lea)
		rta = r;
	mem(Ldw, a->i.f, ir, rta);
	mem(mi, a->i.s, rta, r);
}

static void
opwld(Inst *i, int op, int r)
{
	opx(USRC(i->add), &i->s, op, r, O(REG, st));
}

static void
opwst(Inst *i, int op, int r)
{
	opx(UDST(i->add), &i->d, op, r, O(REG, dt));
}

static void
opfl(Adr *a, int am, int mi, int fr)
{
	int ir;

	switch(am) {
	default:
		urk("opfl");
	case AFP:
		memfl(mi, a->ind, RFP, fr);
		return;
	case AMP:
		memfl(mi, a->ind, RMP, fr);
		return;
	case AIND|AFP:
		ir = RFP;
		break;
	case AIND|AMP:
		ir = RMP;
		break;
	}
	mem(Ldw, a->i.f, ir, RTA);
	memfl(mi, a->i.s, RTA, fr);
}

static void
opflld(Inst *i, int mi, int fr)
{
	opfl(&i->s, USRC(i->add), mi, fr);
}

static void
opflst(Inst *i, int mi, int fr)
{
	opfl(&i->d, UDST(i->add), mi, fr);
}

/*
 * mid -- decode middle operand.
 */
static void
mid(Inst *i, int mi, int r)
{
	int ir;

	switch(i->add & ARM) {
	default:
		opwst(i, mi, r);
		return;
	case AXIMM:
		if(mi == Lea)
			urk("mid/lea");
		li(r, (short)i->reg);
		return;
	case AXINF:
		ir = RFP;
		break;
	case AXINM:
		ir = RMP;
		break;
	}
	mem(mi, i->reg, ir, r);
}

static void
midfl(Inst *i, int mi, int fr)
{
	int ir;

	switch(i->add & ARM) {
	default:
		opflst(i, mi, fr);
		return;
	case AXIMM:
		urk("midfl/imm");
		return;
	case AXINF:
		ir = RFP;
		break;
	case AXINM:
		ir = RMP;
		break;
	}
	memfl(mi, i->reg, ir, fr);
}

/*
 * schedcheck -- decrement IC at backward branches; reschedule if expired.
 */
static void
schedcheck(Inst *i)
{
	u32int *skip;

	if(!RESCHED || i->d.ins > i)
		return;

	mem(Ldw32s, O(REG, IC), RREG, RA0);
	ADDIW(RA0, RA0, -1);
	mem(Stw32, O(REG, IC), RREG, RA0);
	skip = bfwd(FBLT, RZERO, RA0);	/* IC > 0: continue */

	/*
	 * IC <= 0: reschedule. The call's link is the address of the code
	 * after it (the branch's own comparison), and MacRELQ saves it as
	 * R.PC, so re-entry resumes there, not past the branch.
	 */
	mem(Stw, O(REG, FP), RREG, RFP);
	blmac(MacRELQ);

	patchb(skip);
}

/*
 * punt -- fall back to the C interpreter for an instruction.
 */
static void
punt(Inst *i, int m, void (*fn)(void))
{
	ulong pc;

	if(m & SRCOP) {
		if(UXSRC(i->add) == SRC(AIMM))
			literal(i->s.imm, O(REG, s));
		else {
			opwld(i, Lea, RA0);
			mem(Stw, O(REG, s), RREG, RA0);
		}
	}

	if(m & DSTOP) {
		opwst(i, Lea, RA0);
		mem(Stw, O(REG, d), RREG, RA0);
	}
	if(m & WRTPC) {
		conpos(patch[i - mod->prog + 1], RA0);
		mem(Stw, O(REG, PC), RREG, RA0);
	}
	if(m & DBRAN) {
		pc = patch[i->d.ins - mod->prog];
		literal(RELPC(pc), O(REG, d));
	}

	switch(i->add & ARM) {
	case AXNON:
		/* R.m = R.d (matches dec[] behaviour regardless of THREOP) */
		mem(Ldw, O(REG, d), RREG, RA0);
		mem(Stw, O(REG, m), RREG, RA0);
		break;
	case AXIMM:
		literal((short)i->reg, O(REG, m));
		break;
	case AXINF:
		mem(Lea, i->reg, RFP, RA2);
		mem(Stw, O(REG, m), RREG, RA2);
		break;
	case AXINM:
		mem(Lea, i->reg, RMP, RA2);
		mem(Stw, O(REG, m), RREG, RA2);
		break;
	}

	mem(Stw, O(REG, FP), RREG, RFP);
	conaddr((uvlong)fn, RTA);
	CALLR(RTA);

	if(m & TCHECK) {
		mem(Ldw, O(REG, t), RREG, RA0);
		BEQZ(RA0, 12);
		mem(Ldw, O(REG, xpc), RREG, RTA);
		JR(RTA);
	}

	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);

	if(m & NEWPC) {
		/*
		 * IMCALL is punted, and OP(mcall) leaves R.M the callee and
		 * R.PC its entry. If the callee is not compiled R.PC is a Dis
		 * Inst array, not code: hand it to the interpreter through
		 * xpc (#687), as comp-arm64.c does.
		 */
		if(m & MODCHK) {
			mem(Ldw, O(REG, M), RREG, RA0);
			mem(Ldw32, O(Modlink, compiled), RA0, RA0);
			BNEZ(RA0, 12);
			mem(Ldw, O(REG, xpc), RREG, RTA);
			JR(RTA);
		}
		mem(Ldw, O(REG, PC), RREG, RTA);
		JR(RTA);
	}
}

/*
 * puntop -- punt a real instruction. R.PC is always written, not only
 * for the ops that read it: an op that raises then leaves R.PC inside
 * this instruction, and the exception finds this instruction's handler.
 */
static void
puntop(Inst *i, int m)
{
	punt(i, m|WRTPC, optab[i->op]);
}

/*
 * Branch helpers.
 */
static void
cbra(Inst *i, int cond, int ld)
{
	if(RESCHED)
		schedcheck(i);
	opwld(i, ld, RA0);
	mid(i, ld, RA1);
	cmpbra(cond, RA0, RA1, i->d.ins - mod->prog);
}

static void
cbraf(Inst *i, int cond)
{
	if(RESCHED)
		schedcheck(i);
	opflld(i, Ldw, FA0);
	midfl(i, Ldw, FA1);
	/* a NaN makes every relation false, and so != true, as in C */
	switch(cond) {
	case EQ:	FEQD(RA0, FA0, FA1); cmpbra(NE, RA0, RZERO, i->d.ins - mod->prog); return;
	case NE:	FEQD(RA0, FA0, FA1); cmpbra(EQ, RA0, RZERO, i->d.ins - mod->prog); return;
	case LT:	FLTD(RA0, FA0, FA1); break;
	case LE:	FLED(RA0, FA0, FA1); break;
	case GT:	FLTD(RA0, FA1, FA0); break;
	case GE:	FLED(RA0, FA1, FA0); break;
	default:	urk("cbraf");
	}
	cmpbra(NE, RA0, RZERO, i->d.ins - mod->prog);
}

/*
 * comcase -- binary search case statement.
 */
static void
comcase(Inst *i, int w)
{
	int l;
	WORD *t, *e;

	if(w != 0) {
		opwld(i, Ldw, RA1);
		opwst(i, Lea, RA3);
		bramac(MacCASE);
	}

	t = (WORD*)(mod->origmp + i->d.ind + IBY2WD);
	l = t[-1];

	/* pass 0 marks the table for relocation; only the emit pass relocates */
	if(pass != PASSEMIT) {
		if(pass == 0 && l >= 0)
			t[-1] = -l - 1;
		return;
	}
	if(l >= 0)
		return;
	t[-1] = -l - 1;
	e = t + t[-1] * 3;
	while(t < e) {
		t[2] = RELPC(patch[t[2]]);
		t += 3;
	}
	t[0] = RELPC(patch[t[0]]);
}

static void
comcasel(Inst *i)
{
	int l;
	WORD *t, *e;

	/* casel table: count in a 2*IBY2WD slot, then [lo][hi][pc+pad] (INFR-355) */
	t = (WORD*)(mod->origmp + i->d.ind + 2*IBY2WD);
	l = t[-2];
	if(pass != PASSEMIT) {
		if(pass == 0 && l >= 0)
			t[-2] = -l - 1;
		return;
	}
	if(l >= 0)
		return;
	t[-2] = -l - 1;
	e = t + t[-2] * 4;
	while(t < e) {
		t[2] = RELPC(patch[t[2]]);
		t += 4;
	}
	t[0] = RELPC(patch[t[0]]);
}

static void
comgoto(Inst *i)
{
	WORD *t, *e;

	opwld(i, Ldw, RA1);		/* index */
	opwst(i, Lea, RA0);		/* table base */
	SLLI(RA1, RA1, 3);		/* IBY2WD */
	ADD(RA0, RA0, RA1);
	LD(RTA, RA0, 0);
	JR(RTA);

	if(pass != PASSEMIT)
		return;

	t = (WORD*)(mod->origmp + i->d.ind);
	e = t + t[-1];
	t[-1] = 0;
	while(t < e) {
		t[0] = RELPC(patch[t[0]]);
		t++;
	}
}

/*
 * movmem -- block memory copy for MOVM; source address in RA1.
 */
static void
movmem(Inst *i)
{
	u32int *done, *loop;

	if((i->add & ARM) != AXIMM) {
		mid(i, Ldw, RA3);
		done = bfwd(FBGE, RZERO, RA3);	/* count <= 0 */
		opwst(i, Lea, RA2);
		loop = code;
		LBU(RA0, RA1, 0);
		SB(RA0, RA2, 0);
		ADDI(RA1, RA1, 1);
		ADDI(RA2, RA2, 1);
		ADDI(RA3, RA3, -1);
		BNEZ(RA3, (loop - code) * 4);
		patchb(done);
		return;
	}
	switch(i->reg) {
	case 0:
		break;
	case 8:
		opwst(i, Lea, RA2);
		LD(RA0, RA1, 0);
		SD(RA0, RA2, 0);
		break;
	case 16:
		opwst(i, Lea, RA2);
		LD(RA0, RA1, 0);
		LD(RA3, RA1, 8);
		SD(RA0, RA2, 0);
		SD(RA3, RA2, 8);
		break;
	default:
		if((i->reg & 7) == 0) {
			li(RA3, i->reg >> 3);
			opwst(i, Lea, RA2);
			loop = code;
			LD(RA0, RA1, 0);
			SD(RA0, RA2, 0);
			ADDI(RA1, RA1, 8);
			ADDI(RA2, RA2, 8);
			ADDI(RA3, RA3, -1);
			BNEZ(RA3, (loop - code) * 4);
		} else {
			li(RA3, i->reg);
			opwst(i, Lea, RA2);
			loop = code;
			LBU(RA0, RA1, 0);
			SB(RA0, RA2, 0);
			ADDI(RA1, RA1, 1);
			ADDI(RA2, RA2, 1);
			ADDI(RA3, RA3, -1);
			BNEZ(RA3, (loop - code) * 4);
		}
		break;
	}
}

/*
 * double 0.5, for the rounding conversions
 */
static void
fhalf(int fr)
{
	LUI(RCON, 0x3FE00);
	SLLI(RCON, RCON, 32);
	FMVDX(fr, RCON);
}

/* FA0 = FA0 < 0 ? FA0 - 0.5 : FA0 + 0.5, as OP(cvtfw) and OP(cvtfl) round */
static void
fround(void)
{
	u32int *pos, *join;

	fhalf(FA1);
	FMVDX(2, RZERO);		/* ft2 = 0.0 */
	FLTD(RA1, FA0, 2);
	pos = bfwd(FBEQ, RA1, RZERO);	/* !(FA0 < 0): add */
	FSUBD(FA0, FA0, FA1);
	join = jfwd();
	patchb(pos);
	FADDD(FA0, FA0, FA1);
	patchb(join);
}

/*
 * comp -- compile one Dis instruction to RISC-V.
 */
static void
comp(Inst *i)
{
	int r;
	u32int *skip, *skip2, *loop, *done;

	switch(i->op) {
	default:
		puntop(i, SRCOP|DSTOP);
		break;

	/* ---- Punted opcodes ---- */
	case IMCALL:
		puntop(i, SRCOP|DSTOP|THREOP|NEWPC|MODCHK);
		break;
	case ISEND:
	case IRECV:
	case IALT:
	case INBALT:
		puntop(i, SRCOP|DSTOP|TCHECK);
		break;
	case ISPAWN:
		puntop(i, SRCOP|DBRAN);
		break;
	case IBNEC:
	case IBEQC:
	case IBLTC:
	case IBLEC:
	case IBGTC:
	case IBGEC:
		puntop(i, SRCOP|DBRAN|NEWPC);
		break;
	case ICASEC:
		comcase(i, 0);
		puntop(i, SRCOP|DSTOP|NEWPC);
		break;
	case ICASEL:
		comcasel(i);
		puntop(i, SRCOP|DSTOP|NEWPC);
		break;
	case IADDC:
	case IMNEWZ:
	case INEWCM:
	case INEWCMP:
	case IMFRAME:
	case IINDC:
	case IMULX:
	case IDIVX:
	case ICVTXX:
	case IMULX0:
	case IDIVX0:
	case ICVTXX0:
	case IMULX1:
	case IDIVX1:
	case ICVTXX1:
	case ICVTFX:
	case ICVTXF:
	case IEXPW:
	case IEXPL:
	case IEXPF:
		puntop(i, SRCOP|DSTOP|THREOP);
		break;
	case INEWCB:
	case INEWCW:
	case INEWCF:
	case INEWCP:
	case INEWCL:
		puntop(i, DSTOP|THREOP);
		break;
	case IEXIT:
		puntop(i, 0);
		break;
	case IRAISE:
		puntop(i, SRCOP|NEWPC);
		break;
	case ISELF:
		puntop(i, DSTOP);
		break;

	/* ---- Inline case/goto ---- */
	case ICASE:
		comcase(i, 1);
		break;
	case IGOTO:
		comgoto(i);
		break;

	/* ---- Data Movement ---- */
	case IMOVW:
	case IMOVL:
	case IMOVF:
		opwld(i, Ldw, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMOVB:
		opwld(i, Ldb, RA0);
		opwst(i, Stb, RA0);
		break;
	case ILEA:
		opwld(i, Lea, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMOVPC:
		conpos(patch[i->s.imm], RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Arithmetic (word) ---- */
	/*
	 * A Limbo int is 32 bits in a 64-bit slot, held sign-extended (CW()
	 * in xec.c): the W forms of RISC-V's add, sub, mul, div and rem
	 * produce exactly that.
	 */
	case IADDW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ADDW(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISUBW:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		SUBW(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMULW:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		MULW(RA0, RA0, RA1);
		opwst(i, Stw, RA0);
		break;
	case IDIVW:
	case IMODW:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		cmpfault(EQ, RA1, RZERO, MacZDIV);
		if(i->op == IDIVW)
			DIVW(RA0, RA0, RA1);
		else
			REMW(RA0, RA0, RA1);
		opwst(i, Stw, RA0);
		break;

	/* ---- Arithmetic (byte, unsigned) ---- */
	case IADDB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		ADD(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case ISUBB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		SUB(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case IMULB:
		opwld(i, Ldb, RA1);
		mid(i, Ldb, RA0);
		MUL(RA0, RA0, RA1);
		opwst(i, Stb, RA0);
		break;
	case IDIVB:
	case IMODB:
		opwld(i, Ldb, RA1);
		mid(i, Ldb, RA0);
		cmpfault(EQ, RA1, RZERO, MacZDIV);
		if(i->op == IDIVB)
			DIVU(RA0, RA0, RA1);
		else
			REMU(RA0, RA0, RA1);
		opwst(i, Stb, RA0);
		break;

	/* ---- Arithmetic (long) ---- */
	case IADDL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		ADD(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISUBL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		SUB(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case IMULL:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		MUL(RA0, RA0, RA1);
		opwst(i, Stw, RA0);
		break;
	case IDIVL:
	case IMODL:
		opwld(i, Ldw, RA1);
		mid(i, Ldw, RA0);
		cmpfault(EQ, RA1, RZERO, MacZDIV);
		if(i->op == IDIVL)
			DIV(RA0, RA0, RA1);
		else
			REM(RA0, RA0, RA1);
		opwst(i, Stw, RA0);
		break;

	/* ---- Logic ---- */
	case IANDW:
	case IORW:
	case IXORW:
	case IANDL:
	case IORL:
	case IXORL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		switch(i->op) {
		case IANDW: case IANDL:	AND(RA0, RA1, RA0); break;
		case IORW: case IORL:	OR(RA0, RA1, RA0); break;
		default:		XOR(RA0, RA1, RA0); break;
		}
		if(i->op == IANDW || i->op == IORW || i->op == IXORW)
			SEXTW(RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case IANDB:
	case IORB:
	case IXORB:
		mid(i, Ldb, RA1);
		opwld(i, Ldb, RA0);
		switch(i->op) {
		case IANDB:	AND(RA0, RA1, RA0); break;
		case IORB:	OR(RA0, RA1, RA0); break;
		default:	XOR(RA0, RA1, RA0); break;
		}
		opwst(i, Stb, RA0);
		break;

	/* ---- Shifts: amount in RA0 (src), value in RA1 (mid) ---- */
	case ISHLW:	/* CW((u32int)m << (s&63)) */
		mid(i, Ldw32, RA1);
		opwld(i, Ldw, RA0);
		SLL(RA0, RA1, RA0);
		SEXTW(RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISHRW:	/* CW((int)m >> (s&63)) */
		mid(i, Ldw32s, RA1);
		opwld(i, Ldw, RA0);
		SRA(RA0, RA1, RA0);
		SEXTW(RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case ILSRW:	/* CW((u32int)m >> (s&63)) */
		mid(i, Ldw32, RA1);
		opwld(i, Ldw, RA0);
		SRL(RA0, RA1, RA0);
		SEXTW(RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISHLB:
		mid(i, Ldb, RA1);
		opwld(i, Ldw, RA0);
		SLL(RA0, RA1, RA0);
		opwst(i, Stb, RA0);
		break;
	case ISHRB:
		mid(i, Ldb, RA1);
		opwld(i, Ldw, RA0);
		SRL(RA0, RA1, RA0);	/* a byte is unsigned */
		opwst(i, Stb, RA0);
		break;
	case ISHLL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		SLL(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ISHRL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		SRA(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;
	case ILSRL:
		mid(i, Ldw, RA1);
		opwld(i, Ldw, RA0);
		SRL(RA0, RA1, RA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Float arithmetic ---- */
	case IADDF:
	case ISUBF:
	case IMULF:
	case IDIVF:
		opflld(i, Ldw, FA0);
		midfl(i, Ldw, FA1);
		switch(i->op) {
		case IADDF:	FADDD(FA1, FA1, FA0); break;
		case ISUBF:	FSUBD(FA1, FA1, FA0); break;
		case IMULF:	FMULD(FA1, FA1, FA0); break;
		default:	FDIVD(FA1, FA1, FA0); break;
		}
		opflst(i, Stw, FA1);
		break;
	case INEGF:
		opflld(i, Ldw, FA0);
		FNEGD(FA0, FA0);
		opflst(i, Stw, FA0);
		break;

	/* ---- Conversions ---- */
	case ICVTBW:
		opwld(i, Ldb, RA0);
		opwst(i, Stw, RA0);
		break;
	case ICVTWB:
		opwld(i, Ldw, RA0);
		opwst(i, Stb, RA0);
		break;
	case ICVTWL:
		opwld(i, Ldw, RA0);
		opwst(i, Stw, RA0);
		break;
	case ICVTLW:
		opwld(i, Ldw, RA0);
		SEXTW(RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case ICVTWF:
	case ICVTLF:
		opwld(i, Ldw, RA0);
		FCVTDL(FA0, RA0);
		opflst(i, Stw, FA0);
		break;
	case ICVTFW:
		opflld(i, Ldw, FA0);
		fround();
		FCVTLD(RA0, FA0);
		SEXTW(RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case ICVTFL:
		opflld(i, Ldw, FA0);
		fround();
		FCVTLD(RA0, FA0);
		opwst(i, Stw, RA0);
		break;

	/* ---- Branches ---- */
	case IBEQW:	cbra(i, EQ, Ldw);	break;
	case IBNEW:	cbra(i, NE, Ldw);	break;
	case IBLTW:	cbra(i, LT, Ldw);	break;
	case IBLEW:	cbra(i, LE, Ldw);	break;
	case IBGTW:	cbra(i, GT, Ldw);	break;
	case IBGEW:	cbra(i, GE, Ldw);	break;
	case IBEQB:	cbra(i, EQ, Ldb);	break;
	case IBNEB:	cbra(i, NE, Ldb);	break;
	case IBLTB:	cbra(i, LT, Ldb);	break;
	case IBLEB:	cbra(i, LE, Ldb);	break;
	case IBGTB:	cbra(i, GT, Ldb);	break;
	case IBGEB:	cbra(i, GE, Ldb);	break;
	case IBEQL:	cbra(i, EQ, Ldw);	break;
	case IBNEL:	cbra(i, NE, Ldw);	break;
	case IBLTL:	cbra(i, LT, Ldw);	break;
	case IBLEL:	cbra(i, LE, Ldw);	break;
	case IBGTL:	cbra(i, GT, Ldw);	break;
	case IBGEL:	cbra(i, GE, Ldw);	break;
	case IBEQF:	cbraf(i, EQ);	break;
	case IBNEF:	cbraf(i, NE);	break;
	case IBLTF:	cbraf(i, LT);	break;
	case IBLEF:	cbraf(i, LE);	break;
	case IBGTF:	cbraf(i, GT);	break;
	case IBGEF:	cbraf(i, GE);	break;

	/* ---- Control Flow ---- */
	case IJMP:
		if(RESCHED)
			schedcheck(i);
		bradis(i->d.ins - mod->prog);
		break;
	case ICALL:
		opwld(i, Ldw, RA0);
		conpos(patch[i - mod->prog + 1], RA1);
		mem(Stw, O(Frame, lr), RA0, RA1);
		mem(Stw, O(Frame, fp), RA0, RFP);
		MV(RFP, RA0);
		bradis(i->d.ins - mod->prog);
		break;
	case IRET:
		mem(Ldw, O(Frame, t), RFP, RA1);
		bramac(MacRET);
		break;
	case IFRAME:
		if(UXSRC(i->add) != SRC(AIMM)) {
			puntop(i, SRCOP|DSTOP);
			break;
		}
		tinit[i->s.imm] = 1;
		conaddr((uvlong)mod->type[i->s.imm], RA3);
		blmac(MacFRAM);
		opwst(i, Stw, RA2);
		break;

	/* ---- Array Indexing ---- */
	case IINDW:
	case IINDF:
	case IINDL:
	case IINDB:
		opwld(i, Ldw, RA0);
		nilcheck(RA0, MacBNDS);		/* OP(indw): a == H is a bounds error */
		mem(Ldw, O(Array, len), RA0, RA2);
		mem(Ldw, O(Array, data), RA0, RA0);
		r = 0;
		switch(i->op) {
		case IINDL:
		case IINDF:
		case IINDW:
			r = 3;
			break;
		}
		if(UXDST(i->add) == DST(AIMM)) {
			li(RCON, i->d.imm);
			cmpfault(HS, RCON, RA2, MacBNDS);
			mem(Lea, (long)i->d.imm << r, RA0, RA0);
		} else {
			opwst(i, Ldw, RA1);
			SEXTW(RA1, RA1);	/* index is a Dis int */
			cmpfault(HS, RA1, RA2, MacBNDS);
			if(r > 0)
				SLLI(RA1, RA1, r);
			ADD(RA0, RA0, RA1);
		}
		mid(i, Stw, RA0);
		break;
	case IINDX:
		opwld(i, Ldw, RA0);
		nilcheck(RA0, MacBNDS);
		opwst(i, Ldw, RA1);
		SEXTW(RA1, RA1);
		mem(Ldw, O(Array, len), RA0, RA2);
		cmpfault(HS, RA1, RA2, MacBNDS);
		mem(Ldw, O(Array, t), RA0, RA2);
		mem(Ldw, O(Array, data), RA0, RA0);
		mem(Ldw32, O(Type, size), RA2, RA2);
		MUL(RA1, RA1, RA2);
		ADD(RA0, RA0, RA1);
		mid(i, Stw, RA0);
		break;

	/* ---- Pointer Move ---- */
	case ITAIL:
		opwld(i, Ldw, RA0);
		nilcheck(RA0, MacNIL);
		mem(Ldw, O(List, tail), RA0, RA1);
		goto movp;
	case IMOVP:
		opwld(i, Ldw, RA1);
		goto movp;
	case IHEADP:
		opwld(i, Ldw, RA0);
		nilcheck(RA0, MacNIL);
		mem(Ldw, OA(List, data), RA0, RA1);
	movp:
		ADDI(RCON, RZERO, -1);
		skip = bfwd(FBEQ, RA1, RCON);
		blmac(MacCOLR);
		patchb(skip);
		opwst(i, Lea, RA2);
		mem(Ldw, 0, RA2, RA0);
		mem(Stw, 0, RA2, RA1);
		blmac(MacFRP);
		break;

	/* ---- Head (scalar from list) ---- */
	case IHEADW:
	case IHEADL:
	case IHEADF:
		opwld(i, Ldw, RA0);
		nilcheck(RA0, MacNIL);
		mem(Ldw, OA(List, data), RA0, RA0);
		opwst(i, Stw, RA0);
		break;
	case IHEADB:
		opwld(i, Ldw, RA0);
		nilcheck(RA0, MacNIL);
		mem(Ldb, OA(List, data), RA0, RA0);
		opwst(i, Stb, RA0);
		break;

	/* ---- Memory Move ---- */
	case IHEADM:
		opwld(i, Ldw, RA1);
		nilcheck(RA1, MacNIL);
		ADDI(RA1, RA1, OA(List, data));
		movmem(i);
		break;
	case IMOVM:
		opwld(i, Lea, RA1);
		movmem(i);
		break;

	/* ---- Length ---- */
	case ILENA:
		opwld(i, Ldw, RA1);
		MV(RA0, RZERO);
		ADDI(RCON, RZERO, -1);
		skip = bfwd(FBEQ, RA1, RCON);
		mem(Ldw, O(Array, len), RA1, RA0);
		patchb(skip);
		opwst(i, Stw, RA0);
		break;
	case ILENC:
		opwld(i, Ldw, RA1);
		MV(RA0, RZERO);
		ADDI(RCON, RZERO, -1);
		skip = bfwd(FBEQ, RA1, RCON);
		mem(Ldw32s, O(String, len), RA1, RA0);
		skip2 = bfwd(FBGE, RA0, RZERO);	/* len < 0: a Rune string */
		NEG(RA0, RA0);
		patchb(skip2);
		patchb(skip);
		opwst(i, Stw, RA0);
		break;
	case ILENL:
		MV(RA0, RZERO);
		opwld(i, Ldw, RA1);
		ADDI(RCON, RZERO, -1);
		loop = code;
		done = bfwd(FBEQ, RA1, RCON);
		mem(Ldw, O(List, tail), RA1, RA1);
		ADDI(RA0, RA0, 1);
		jback(loop);
		patchb(done);
		opwst(i, Stw, RA0);
		break;

	case INOP:
		break;
	}
}

/*
 * preamble -- comvec entry/exit trampoline (allocated once).
 */
static void
preamble(void)
{
	ulong sz;
	u32int *start, *xpc_loc, *epilogue, *save;
	long hi, lo;

	if(comvec)
		return;

	sz = 64 * sizeof(u32int);
#ifdef INFERNO_NATIVE
	comvec = malloc(sz);
	if(comvec == nil)
		error(exNomem);
#else
	comvec = mmap(0, sz, PROT_READ|PROT_WRITE|PROT_EXEC,
			MAP_PRIVATE|MAP_ANON, -1, 0);
	if(comvec == MAP_FAILED) {
		comvec = nil;
		error(exNomem);
	}
#endif

	code = (u32int*)comvec;
	start = code;

	/* save ra and the callee-saved registers the JIT keeps VM state in */
	ADDI(RSP, RSP, -48);
	SD(RLINK, RSP, 40);
	SD(RREG, RSP, 32);
	SD(RFP, RSP, 24);
	SD(RMP, RSP, 16);
	SD(RS0, RSP, 8);

	li(RREG, (uvlong)&R);

	/* R.xpc = epilogue (PC-relative, patched below) */
	xpc_loc = code;
	AUIPC(RTA, 0);
	ADDI(RTA, RTA, 0);
	mem(Stw, O(REG, xpc), RREG, RTA);

	/* Load VM state */
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	mem(Ldw, O(REG, PC), RREG, RTA);
	JR(RTA);

	/* Epilogue */
	epilogue = code;
	LD(RS0, RSP, 8);
	LD(RMP, RSP, 16);
	LD(RFP, RSP, 24);
	LD(RREG, RSP, 32);
	LD(RLINK, RSP, 40);
	ADDI(RSP, RSP, 48);
	RET();

	if(code - start > 64)
		panic("riscv64 JIT preamble overflow");

	save = code;
	code = xpc_loc;
	splitrel((epilogue - xpc_loc) * 4, &hi, &lo);
	AUIPC(RTA, hi);
	ADDI(RTA, RTA, lo);
	code = save;

#ifdef INFERNO_NATIVE
	cacheiflush(start, sz);
#else
	segflush(start, sz);
#endif

	if(cflag > 3) {
		int k;
		print("preamble at %.8p (%ld words):\n", start, (long)(code - start));
		for(k = 0; k < code - start; k++)
			print("  %.8p  %.8ux\n", &start[k], start[k]);
	}
}

/*
 * Macros.
 */

/*
 * Free-pointer macro: drop one reference to the heap cell in RA0.
 * Tests ref == 1 before any decrement, and does not store on the last
 * reference: destroy() does its own --ref (see comp-arm64.c).
 */
static void
macfrp(void)
{
	u32int *nil_, *lastref;

	ADDI(RCON, RZERO, -1);
	nil_ = bfwd(FBEQ, RA0, RCON);		/* H: nothing to count */

	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA0, RA2);
	ADDI(RCON, RZERO, 1);
	lastref = bfwd(FBEQ, RA2, RCON);

	/* ref > 1: one fewer, and done */
	ADDI(RA2, RA2, -1);
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA0, RA2);
	RET();

	/* ref == 1: save state, let rdestroy take the last one */
	patchb(lastref);
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, s), RREG, RA0);
	mem(Stw, O(REG, st), RREG, RLINK);
	conaddr((uvlong)rdestroy, RTA);
	CALLR(RTA);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);

	patchb(nil_);
	RET();
}

static void
maccolr(void)
{
	u32int *done;

	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA1, RA0);
	ADDI(RA0, RA0, 1);
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA1, RA0);

	mem(Ldw32s, O(Heap, color) - sizeof(Heap), RA1, RA0);
	conaddr((uvlong)&mutator, RA2);
	mem(Ldw32s, 0, RA2, RA2);
	done = bfwd(FBEQ, RA0, RA2);

	li(RA2, propagator);
	mem(Stw32, O(Heap, color) - sizeof(Heap), RA1, RA2);
	conaddr((uvlong)&nprop, RA2);
	ADDI(RA0, RZERO, 1);
	mem(Stw32, 0, RA2, RA0);

	patchb(done);
	RET();
}

static void
macret(void)
{
	u32int *notype, *nodestroy, *nofp, *nomr, *noref, *linterp, *nolr;
	Inst dummy;

	notype = bfwd(FBEQ, RA1, RZERO);

	mem(Ldw, O(Type, destroy), RA1, RA0);
	nodestroy = bfwd(FBEQ, RA0, RZERO);

	mem(Ldw, O(Frame, fp), RFP, RA2);
	nofp = bfwd(FBEQ, RA2, RZERO);

	mem(Ldw, O(Frame, mr), RFP, RA3);
	nomr = bfwd(FBEQ, RA3, RZERO);

	mem(Ldw, O(REG, M), RREG, RA2);
	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA2, RA3);
	ADDI(RA3, RA3, -1);
	noref = bfwd(FBEQ, RA3, RZERO);
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA2, RA3);

	mem(Ldw, O(Frame, mr), RFP, RA1);
	mem(Stw, O(REG, M), RREG, RA1);
	mem(Ldw, O(Modlink, MP), RA1, RMP);
	mem(Stw, O(REG, MP), RREG, RMP);
	mem(Ldw32, O(Modlink, compiled), RA1, RA3);
	linterp = bfwd(FBEQ, RA3, RZERO);

	/* Compiled: call destroy, jump to lr */
	CALLR(RA0);
	mem(Stw, O(REG, SP), RREG, RFP);
	mem(Ldw, O(Frame, lr), RFP, RA1);
	mem(Ldw, O(Frame, fp), RFP, RFP);
	mem(Stw, O(REG, FP), RREG, RFP);
	JR(RA1);

	/* Not compiled: return to interpreter */
	patchb(linterp);
	CALLR(RA0);
	mem(Stw, O(REG, SP), RREG, RFP);
	mem(Ldw, O(Frame, lr), RFP, RA1);
	mem(Ldw, O(Frame, fp), RFP, RFP);
	mem(Stw, O(REG, PC), RREG, RA1);
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, xpc), RREG, RTA);
	JR(RTA);

	/*
	 * No mr: a return within the module (every return of a recursive
	 * function), which is compiled, so lr is native code (#689).
	 */
	patchb(nomr);
	mem(Ldw, O(Frame, lr), RFP, RA1);
	nolr = bfwd(FBEQ, RA1, RZERO);
	CALLR(RA0);
	mem(Stw, O(REG, SP), RREG, RFP);
	mem(Ldw, O(Frame, lr), RFP, RA1);
	mem(Ldw, O(Frame, fp), RFP, RFP);
	mem(Stw, O(REG, FP), RREG, RFP);
	JR(RA1);

	/* Punt fallback */
	patchb(notype);
	patchb(nodestroy);
	patchb(nofp);
	patchb(noref);
	patchb(nolr);
	dummy.add = AXNON;
	punt(&dummy, TCHECK|NEWPC, optab[IRET]);
}

/*
 * maccase -- binary search: RA1 the value, RA3 the table
 * ([count][lo hi pc]...[default pc]).
 */
static void
maccase(void)
{
	u32int *loop, *out, *notlt, *notfound;

	mem(Ldw, 0, RA3, RA2);		/* count */
	MV(RT2, RA3);			/* the table, for the default */

	loop = code;
	out = bfwd(FBGE, RZERO, RA2);	/* n <= 0 */

	SRLI(RA0, RA2, 1);		/* n2 = n >> 1 */
	li(RTA, 3*IBY2WD);
	MUL(RCON, RA0, RTA);
	ADD(RCON, RA3, RCON);		/* pivot = table + n2*3*IBY2WD */

	mem(Ldw, IBY2WD, RCON, RTA);
	notlt = bfwd(FBGE, RA1, RTA);
	MV(RA2, RA0);			/* n = n2 */
	jback(loop);

	patchb(notlt);
	mem(Ldw, 2*IBY2WD, RCON, RTA);
	notfound = bfwd(FBGE, RA1, RTA);
	mem(Ldw, 3*IBY2WD, RCON, RTA);
	JR(RTA);			/* found */

	patchb(notfound);
	ADDI(RA3, RCON, 3*IBY2WD);
	ADDI(RA0, RA0, 1);
	SUB(RA2, RA2, RA0);
	jback(loop);

	/* default */
	patchb(out);
	mem(Ldw, 0, RT2, RA2);
	li(RTA, 3*IBY2WD);
	MUL(RA2, RA2, RTA);
	ADD(RT2, RT2, RA2);
	mem(Ldw, IBY2WD, RT2, RTA);
	JR(RTA);
}

/* RA0 the entry, RA2 the frame, RA3 the modlink */
static void
macmcal(void)
{
	u32int *notnil, *hasprog, *compiled;

	ADDI(RCON, RZERO, -1);
	notnil = bfwd(FBNE, RA0, RCON);

	/* RA0 == H: punt to rmcall, which raises exModule */
	mem(Stw, O(REG, st), RREG, RLINK);
	mem(Stw, O(REG, FP), RREG, RA2);
	mem(Stw, O(REG, dt), RREG, RA0);
	conaddr((uvlong)rmcall, RTA);
	CALLR(RTA);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET();

	patchb(notnil);
	mem(Ldw, O(Modlink, prog), RA3, RA1);
	hasprog = bfwd(FBNE, RA1, RZERO);

	/* prog == nil: same punt */
	mem(Stw, O(REG, st), RREG, RLINK);
	mem(Stw, O(REG, FP), RREG, RA2);
	mem(Stw, O(REG, dt), RREG, RA0);
	conaddr((uvlong)rmcall, RTA);
	CALLR(RTA);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET();

	patchb(hasprog);
	MV(RFP, RA2);
	mem(Stw, O(REG, M), RREG, RA3);
	mem(Ldw, O(Heap, ref) - sizeof(Heap), RA3, RA1);
	ADDI(RA1, RA1, 1);
	mem(Stw, O(Heap, ref) - sizeof(Heap), RA3, RA1);
	mem(Ldw, O(Modlink, MP), RA3, RMP);
	mem(Stw, O(REG, MP), RREG, RMP);
	mem(Ldw32, O(Modlink, compiled), RA3, RA1);
	compiled = bfwd(FBNE, RA1, RZERO);
	/* Not compiled */
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, PC), RREG, RA0);
	mem(Ldw, O(REG, xpc), RREG, RTA);
	JR(RTA);
	/* Compiled */
	patchb(compiled);
	JR(RA0);
}

/* RA3 the frame's type; returns the frame in RA2 */
static void
macfram(void)
{
	u32int *expand;

	mem(Ldw, O(REG, SP), RREG, RA0);
	mem(Ldw32s, O(Type, size), RA3, RA1);
	ADD(RA0, RA0, RA1);
	mem(Ldw, O(REG, TS), RREG, RA1);
	expand = bfwd(FBGEU, RA0, RA1);

	mem(Ldw, O(REG, SP), RREG, RA2);
	mem(Stw, O(REG, SP), RREG, RA0);
	mem(Stw, O(Frame, t), RA2, RA3);
	mem(Stw, O(Frame, mr), RA2, RZERO);
	/* the initializer is compiled type code: it takes the frame in RA2 */
	mem(Stw, O(REG, dt), RREG, RA2);
	mem(Stw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(Type, initialize), RA3, RTA);
	CALLR(RTA);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, dt), RREG, RA2);
	RET();

	patchb(expand);
	mem(Stw, O(REG, s), RREG, RA3);
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, st), RREG, RLINK);
	conaddr((uvlong)extend, RTA);
	CALLR(RTA);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, s), RREG, RA2);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET();
}

static void
macmfra(void)
{
	mem(Stw, O(REG, s), RREG, RA3);
	mem(Stw, O(REG, d), RREG, RA0);
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, st), RREG, RLINK);
	conaddr((uvlong)rmfram, RTA);
	CALLR(RTA);
	mem(Ldw, O(REG, st), RREG, RLINK);
	mem(Ldw, O(REG, FP), RREG, RFP);
	mem(Ldw, O(REG, MP), RREG, RMP);
	RET();
}

static void
macrelq(void)
{
	/* R.PC = the link: the code after the call in schedcheck */
	mem(Stw, O(REG, PC), RREG, RLINK);
	mem(Stw, O(REG, MP), RREG, RMP);
	mem(Ldw, O(REG, xpc), RREG, RTA);
	JR(RTA);
}

/*
 * The fault macros. Reached by a jal from inside the faulting
 * instruction, so the link is a PC in that instruction (or the start
 * of the next): handler() subtracts one and lands inside it.
 */
static void
macfault(void (*fn)(void))
{
	mem(Stw, O(REG, FP), RREG, RFP);
	mem(Stw, O(REG, PC), RREG, RLINK);
	conaddr((uvlong)fn, RTA);
	CALLR(RTA);
	EBREAK();		/* fn raises; it does not return */
}

static void
macbounds(void)
{
	macfault(bounds);
}

static void
maczdiv(void)
{
	macfault(zdiv);
}

static void
macnil(void)
{
	macfault(nilref);
}

/*
 * comi / comd -- type initializer and destroyer, a mapping of their own.
 * comi takes the cell in RA2; comd takes it in RFP (macret's frame).
 */
static void
comi(Type *t)
{
	int i, j, m, c;

	ADDI(RA0, RZERO, -1);		/* H */
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		j = i * 8 * (int)sizeof(WORD*);
		for(m = 0x80; m != 0; m >>= 1) {
			if(c & m)
				mem(Stw, j, RA2, RA0);
			j += sizeof(WORD*);
		}
	}
	RET();
}

static void
comd(Type *t)
{
	int i, j, m, c;
	uvlong macfrp_addr;

	/* the type code is far from the module: call MacFRP by absolute address */
	macfrp_addr = RELPC(macro[MacFRP]);

	mem(Stw, O(REG, dt), RREG, RLINK);
	for(i = 0; i < t->np; i++) {
		c = t->map[i];
		j = i * 8 * (int)sizeof(WORD*);
		for(m = 0x80; m != 0; m >>= 1) {
			if(c & m) {
				mem(Ldw, j, RFP, RA0);
				li(RTA, macfrp_addr);
				CALLR(RTA);
			}
			j += sizeof(WORD*);
		}
	}
	mem(Ldw, O(REG, dt), RREG, RLINK);
	RET();
}

/*
 * Worst-case instructions comi() + comd() emit per pointer slot: a mem()
 * whose offset needs building (4), a 64-bit li() (8) and a jalr.
 */
#define TYPECOM_FIXED	64
#define TYPECOM_PERPTR	24
#define TYPECOM_SLACK	1024

#define Typejithdr	16	/* the mapping's length, in front of a type's code */

void
typecom(Type *t)
{
	int n, saveinmod;
	u32int *tmp, *start, *savecode;
	ulong sz, need;

	if(t == nil || t->initialize != 0)
		return;

	if(t->np < 0 || (uvlong)t->np * 8 * TYPECOM_PERPTR > 16*1024*1024)
		error(exNomem);
	need = TYPECOM_FIXED + (ulong)t->np * 8 * TYPECOM_PERPTR;

	tmp = mallocz((need + TYPECOM_SLACK) * sizeof(u32int), 0);
	if(tmp == nil)
		error(exNomem);

	/* type code is not module code: no sites, no pool */
	saveinmod = inmod;
	inmod = 0;
	savecode = code;

	code = tmp;
	comi(t);
	n = code - tmp;
	code = tmp;
	comd(t);
	n += code - tmp;

	if((ulong)n > need) {
		free(tmp);
		inmod = saveinmod;
		code = savecode;
		print("typecom: emitted %d > bound %lud for np=%d\n", n, need, t->np);
		error(exCompile);
	}
	free(tmp);

	sz = n * sizeof(u32int) + Typejithdr;

#ifdef INFERNO_NATIVE
	start = malloc(sz);
	if(start == nil) {
		inmod = saveinmod;
		code = savecode;
		return;
	}
#else
	start = mmap(0, sz, PROT_READ|PROT_WRITE|PROT_EXEC,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if(start == MAP_FAILED) {
		inmod = saveinmod;
		code = savecode;
		return;
	}
#endif

	*(ulong*)start = sz;
	code = (u32int*)((uchar*)start + Typejithdr);
	t->initialize = code;
	comi(t);
	t->destroy = code;
	comd(t);

#ifdef INFERNO_NATIVE
	cacheiflush(start, sz);
#else
	segflush(start, sz);
#endif

	if(cflag > 3)
		print("typ= %.8p %4d i %.8p d %.8p asm=%lud\n",
			t, t->size, t->initialize, t->destroy, sz);

	inmod = saveinmod;
	code = savecode;
}

static void
patchex(Module *m, ulong *p)
{
	Handler *h;
	Except *e;

	if((h = m->htab) == nil)
		return;
	for( ; h->etab != nil; h++) {
		h->pc1 = p[h->pc1] * sizeof(u32int);
		h->pc2 = p[h->pc2] * sizeof(u32int);
		for(e = h->etab; e->s != nil; e++)
			if(e->pc != (ulong)-1)
				e->pc = p[e->pc] * sizeof(u32int);
		if(e->pc != (ulong)-1)
			e->pc = p[e->pc] * sizeof(u32int);
	}
}

/*
 * Release a type's compiled initialize/destroy code: a mapping, with
 * its length in the header typecom() put in front of it.
 */
void
freetypejit(Type *t)
{
	uchar *b;

	if(t == nil || t->initialize == nil)
		return;
	b = (uchar*)t->initialize - Typejithdr;
#ifdef INFERNO_NATIVE
	free(b);
#else
	munmap(b, *(ulong*)b);
#endif
	t->initialize = nil;
	t->destroy = nil;
}

/*
 * Release a compiled module's executable text (INFR-421).
 */
void
freejitcode(void *p, ulong size)
{
	if(p == nil || size == 0)
		return;
#ifdef INFERNO_NATIVE
	USED(size);
	free(p);
#else
	munmap(p, size);
#endif
}

/*
 * One sizing or emitting pass over the module and its macros.
 * Returns the number of words, or -1 if an instruction overflowed tmp.
 */
static long
compass(Module *m, int size, u32int *tmp, ulong tmpsize)
{
	long n;
	int i;
	u32int *s;

	n = 0;
	nlit = 0;
	site = 0;
	for(i = 0; i < size; i++) {
		if(pass == PASSEMIT) {
			s = code;
			comp(&m->prog[i]);
			if(patch[i] != n) {
				print("%3d %D\n", i, &m->prog[i]);
				print("%lud != %ld\n", patch[i], n);
				urk("phase error");
			}
			n += code - s;
			if(cflag > 4) {
				print("%3d %D\n", i, &m->prog[i]);
				das(s, code - s);
			}
			continue;
		}
		codeoff = n;
		code = codestart = tmp;
		comp(&m->prog[i]);
		if(code - tmp >= (long)tmpsize) {
			print("JIT: instruction %d overflowed tmp buffer (%lud >= %lud)\n",
				i, (ulong)(code - tmp), tmpsize);
			return -1;
		}
		patch[i] = n;
		n += code - tmp;
		if(n > 16*1024*1024) {
			print("JIT: module too large for compilation (%ld words)\n", n);
			return -1;
		}
	}
	if(pass != PASSEMIT)
		patch[size] = n;	/* sentinel: one past last Dis instruction */

	/* trap: catch a fall-through from the last instruction into the macros */
	if(pass == PASSEMIT)
		EBREAK();
	n++;

	for(i = 0; i < nelem(mactab); i++) {
		if(pass == PASSEMIT) {
			s = code;
			mactab[i].gen();
			if(macro[mactab[i].idx] != n) {
				print("mac phase err: %lud != %ld\n", macro[mactab[i].idx], n);
				urk("phase error");
			}
			n += code - s;
			if(cflag > 4) {
				print("%s:\n", mactab[i].name);
				das(s, code - s);
			}
			continue;
		}
		codeoff = n;
		code = codestart = tmp;
		mactab[i].gen();
		macro[mactab[i].idx] = n;
		n += code - tmp;
	}
	return n;
}

int
compile(Module *m, int size, Modlink *ml)
{
	Link *l;
	Modl *e;
	int i;
	long n, n0;
	u32int *tmp;
	ulong codesize, tmpsize, poolbytes;

	if(incompile)
		panic("compile: re-entered while compiling %s (this: %s)", mod? mod->name : "?", m->name);
	incompile = 1;
	inmod = 1;
	base = nil;
	tmp = nil;
	codesize = 0;
	patch0 = nil;
	siteform = nil;
	sitepos0 = nil;
	chash = nil;
	nsite = maxsite = 0;
	ncon = ncpool = 0;
	patch = mallocz((size + 1) * sizeof(*patch), 0);
	tinit = malloc(m->ntype * sizeof(*tinit));
	/* each Dis instruction expands to at most a few hundred words (case, movm) */
	if(size > 0 && (ulong)size > ((ulong)-1) / 64)
		goto bad;
	tmpsize = size * 64;
	if(tmpsize < 8192)
		tmpsize = 8192;
	tmp = malloc(tmpsize * sizeof(u32int));
	if(tinit == nil || patch == nil || tmp == nil)
		goto bad;

	preamble();

	mod = m;

	/* pass 0: every site at its longest; where each is */
	pass = 0;
	n0 = compass(m, size, tmp, tmpsize);
	if(n0 < 0)
		goto bad;
	patch0 = malloc((size + 1) * sizeof(*patch0));
	siteform = malloc(nsite + 1);
	if(patch0 == nil || siteform == nil)
		goto bad;
	memmove(patch0, patch, (size + 1) * sizeof(*patch0));
	memmove(macro0, macro, sizeof(macro0));

	/* pass 1: the shortest form each site provably reaches with */
	pass = 1;
	n = compass(m, size, tmp, tmpsize);
	if(n < 0)
		goto bad;
	if(site != nsite)
		urk("branch site count changed between passes");

	/* the address pool after the code, then the literal pool */
	poolbytes = ((n * sizeof(u32int) + 7) & ~7) - n * sizeof(u32int);
	codesize = n * sizeof(u32int) + poolbytes + (ncon + 1) * sizeof(uvlong) +
		(nlit + nlit/4 + 16) * sizeof(ulong);
	{
		ulong pagesz = 65536;	/* covers 4K and 64K page kernels */
		codesize = (codesize + pagesz - 1) & ~(pagesz - 1);
		codesize += pagesz;	/* guard */
	}
	nchash = 2 * ncon + 1;
	chash = malloc(nchash * sizeof(*chash));
	if(chash == nil)
		goto bad;
	for(i = 0; i < nchash; i++)
		chash[i] = -1;

#ifdef INFERNO_NATIVE
	base = malloc(codesize);
	if(base == nil)
		goto bad;
#else
	base = mmap(0, codesize, PROT_READ|PROT_WRITE|PROT_EXEC,
			MAP_PRIVATE|MAP_ANONYMOUS, -1, 0);
	if(base == MAP_FAILED) {
		base = nil;
		goto bad;
	}
#endif

	cpool = (uvlong*)((uchar*)base + n * sizeof(u32int) + poolbytes);
	litpool = (ulong*)(cpool + ncon + 1);
	litlimit = (ulong*)((uchar*)base + codesize);

	if(cflag > 3)
		print("dis=%5d riscv64=%5ld (pass 0 %ld) sites=%d con=%d lit=%d mmap=%5lud base=%.8p: %s\n",
			size, n, n0, nsite, ncon, nlit, codesize, (void*)base, m->name);

	/* pass 2: emit */
	pass = PASSEMIT;
	code = codestart = base;
	codeoff = 0;
	if(compass(m, size, tmp, tmpsize) != n)
		urk("emitted size differs from pass 1");

	for(l = m->ext; l->name; l++) {
		if(l->u.pc - m->prog == -1){
			l->u.pc = (Inst*)-1;
			typecom(l->frame);
			continue;
		}
		if(l->u.pc - m->prog < 0 || l->u.pc - m->prog > size)
			panic("compile %s: export %s pc index %ld outside 0..%d (already relocated?)",
				m->name, l->name, (long)(l->u.pc - m->prog), size);
		l->u.pc = (Inst*)RELPC(patch[l->u.pc - m->prog]);
		typecom(l->frame);
	}
	if(ml != nil) {
		e = &ml->links[0];
		for(i = 0; i < ml->nlinks; i++) {
			if(e->u.pc - m->prog == -1){
				e->u.pc = (Inst*)-1;
				typecom(e->frame);
				e++;
				continue;
			}
			if(e->u.pc - m->prog < 0 || e->u.pc - m->prog > size)
				panic("compile %s: link %d pc index %ld outside 0..%d (already relocated?)",
					m->name, i, (long)(e->u.pc - m->prog), size);
			e->u.pc = (Inst*)RELPC(patch[e->u.pc - m->prog]);
			typecom(e->frame);
			e++;
		}
	}
	for(i = 0; i < m->ntype; i++) {
		if(tinit[i] != 0)
			typecom(m->type[i]);
	}

	patchex(m, patch);
	m->entry = (Inst*)RELPC(patch[mod->entry - mod->prog]);
	m->pctab = patch;

#ifdef INFERNO_NATIVE
	/*
	 * Load-bearing on silicon and invisible under QEMU, whose TCG does
	 * not model split instruction and data caches: validate any change
	 * here on the board.
	 */
	cacheiflush(base, codesize);
#else
	segflush(base, codesize);
#endif

	free(m->prog);
	m->prog = (Inst*)base;
	m->jitsize = codesize;
	m->compiled = 1;
	free(tinit);
	free(tmp);
	free(patch0);
	free(siteform);
	free(sitepos0);
	free(chash);
	sitepos0 = nil;
	compiledone();
	return 1;
bad:
	compiledone();
	free(patch);
	free(patch0);
	free(siteform);
	free(sitepos0);
	free(chash);
	sitepos0 = nil;
	free(tinit);
	free(tmp);
	if(base != nil && codesize != 0)
#ifdef INFERNO_NATIVE
		free(base);
#else
		munmap(base, codesize);
#endif
	base = nil;
	return 0;
}
