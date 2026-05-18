/*
 * lib9.h for ARM64 Linux (Jetson, etc.)
 * Based on MacOSX/arm64/include/lib9.h
 * Adapted for Linux environment with proper 64-bit types
 */

#define	USE_PTHREADS
#ifndef _BSD_SOURCE
#define _BSD_SOURCE
#endif
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE
#endif
#define _XOPEN_SOURCE  500
#define _LARGEFILE_SOURCE	1
#define _LARGEFILE64_SOURCE	1
#define _FILE_OFFSET_BITS 64
#ifdef USE_PTHREADS
#define	_REENTRANT	1
#endif

#include <features.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <stdarg.h>
#define sync __os_sync
#include <unistd.h>
#undef sync
#include <errno.h>
#define __NO_STRING_INLINES
#include <string.h>
#include <fcntl.h>
#include <setjmp.h>
#include <float.h>
#include <time.h>
#include <stdint.h>
#include <ctype.h>
#include <endian.h>
/* #include <math.h>  - commented out to avoid isnan macro conflict with fdlibm */

#ifdef __BIONIC__
/* Bionic does not expose the BSD shorthand types `ushort`/`uint` via
 * <sys/types.h> the way glibc does with _BSD_SOURCE / _DEFAULT_SOURCE.
 * `uchar` and `ulong` are already typedef'd explicitly below, but the
 * 89-odd uses of `ushort`/`uint` across lib9/limbo/libinterp/utils rely
 * on the implicit glibc definitions. Provide them here so Android/Termux
 * builds compile unchanged. Phase 0 hellaphone shim. */
typedef unsigned short ushort;
typedef unsigned int   uint;
#endif

#define nil		((void*)0)

typedef	unsigned char	uchar;
typedef unsigned long	ulong;
typedef	  signed char	schar;
typedef	long long	vlong;
typedef	unsigned long long	uvlong;
typedef ushort		Rune;
typedef uint32_t	u32int;
typedef uvlong u64int;

typedef uint32_t	mpdigit;	/* for /sys/include/mp.h */
typedef uint16_t u16int;
typedef uint8_t u8int;
typedef uintptr_t uintptr;
typedef intptr_t intptr;

typedef int8_t	int8;
typedef uint8_t	uint8;
typedef int16_t	int16;
typedef uint16_t	uint16;
typedef int32_t	int32;
typedef uint32_t	uint32;
typedef int64_t	int64;
typedef uint64_t	uint64;

/* handle conflicts with host os libs */
#define	getwd	infgetwd
#define scalb	infscalb
#define div 	infdiv
#define panic	infpanic
#define rint	infrint
#define	rcmd	infrcmd
#define	pow10	infpow10
/* Bionic's <stdio.h> declares rewind(FILE*) unconditionally, colliding with
 * limbo/typecheck.c's static rewind(Node*) for AST traversal. Rename it
 * the same way the conflicts above are handled. Only 2 call sites
 * (limbo/typecheck.c) and neither uses stdio's rewind. Phase 0 hellaphone. */
#define	rewind	infrewind

#ifndef EMU
typedef struct Proc Proc;
#endif

/*
 * math module dtoa - arm64 is little endian
 * (endian.h already defines __LITTLE_ENDIAN, so we just check it)
 */
#ifndef __LITTLE_ENDIAN
#define __LITTLE_ENDIAN 1234
#endif

/*
 * arm64 has 64-bit long, so we need USE_FPdbleword
 * to correctly access double's 32-bit halves in dtoa.c
 */
#define USE_FPdbleword

typedef union {
	double	x;
	struct {
		u32int	lo;	/* little endian: low word first */
		u32int	hi;
	};
} FPdbleword;

#define	USED(x)		if(x){}else{}
#define	SET(x)

#define nelem(x)	(sizeof(x)/sizeof((x)[0]))
#undef offsetof
#undef assert
#define	offsetof(s, m)	(ulong)(&(((s*)0)->m))
#define	assert(x)	if(x){}else _assert("x")

extern	char*	strecpy(char*, char*, char*);
extern	char*	strdup(const char*);
extern	int	cistrncmp(char*, char*, int);
extern	int	cistrcmp(char*, char*);
extern	char*	cistrstr(char*, char*);
extern	int	tokenize(char*, char**, int);
extern	vlong	strtoll(const char*, char**, int);
#define	qsort	infqsort
extern	void	qsort(void*, long, long, int (*)(void*, void*));

enum
{
	UTFmax		= 3,
	Runesync	= 0x80,
	Runeself	= 0x80,
	Runeerror	= 0x80
};

extern	int	runetochar(char*, Rune*);
extern	int	chartorune(Rune*, char*);
extern	int	runelen(long);
extern	int	runenlen(Rune*, int);
extern	int	fullrune(char*, int);
extern	int	utflen(char*);
extern	int	utfnlen(char*, long);
extern	char*	utfrune(char*, long);
extern	char*	utfrrune(char*, long);
extern	char*	utfutf(char*, char*);
extern	char*	utfecpy(char*, char*, char*);

extern	Rune*	runestrcat(Rune*, Rune*);
extern	Rune*	runestrchr(Rune*, Rune);
extern	int	runestrcmp(Rune*, Rune*);
extern	Rune*	runestrcpy(Rune*, Rune*);
extern	Rune*	runestrncpy(Rune*, Rune*, long);
extern	Rune*	runestrecpy(Rune*, Rune*, Rune*);
extern	Rune*	runestrdup(Rune*);
extern	Rune*	runestrncat(Rune*, Rune*, long);
extern	int	runestrncmp(Rune*, Rune*, long);
extern	Rune*	runestrrchr(Rune*, Rune);
extern	long	runestrlen(Rune*);
extern	Rune*	runestrstr(Rune*, Rune*);

extern	Rune	tolowerrune(Rune);
extern	Rune	totitlerune(Rune);
extern	Rune	toupperrune(Rune);
extern	int	isalpharune(Rune);
extern	int	islowerrune(Rune);
extern	int	isspacerune(Rune);
extern	int	istitlerune(Rune);
extern	int	isupperrune(Rune);

extern	void*	malloc(size_t);
extern	void*	mallocz(ulong, int);
extern	void	free(void*);
extern	ulong	msize(void*);
extern	void*	calloc(size_t, size_t);
extern	void*	realloc(void*, size_t);
extern	void		setmalloctag(void*, ulong);
extern	void		setrealloctag(void*, ulong);
extern	ulong	getmalloctag(void*);
extern	ulong	getrealloctag(void*);
extern	void*	malloctopoolblock(void*);

typedef struct Fmt	Fmt;
struct Fmt{
	uchar	runes;
	void	*start;
	void	*to;
	void	*stop;
	int	(*flush)(Fmt *);
	void	*farg;
	int	nfmt;
	va_list	args;
	int	r;
	int	width;
	int	prec;
	ulong	flags;
};

enum{
	FmtWidth	= 1,
	FmtLeft		= FmtWidth << 1,
	FmtPrec		= FmtLeft << 1,
	FmtSharp	= FmtPrec << 1,
	FmtSpace	= FmtSharp << 1,
	FmtSign		= FmtSpace << 1,
	FmtZero		= FmtSign << 1,
	FmtUnsigned	= FmtZero << 1,
	FmtShort	= FmtUnsigned << 1,
	FmtLong		= FmtShort << 1,
	FmtVLong	= FmtLong << 1,
	FmtComma	= FmtVLong << 1,
	FmtByte	= FmtComma << 1,
	FmtFlag		= FmtByte << 1
};

extern	int	print(char*, ...);
extern	char*	seprint(char*, char*, char*, ...);
extern	char*	vseprint(char*, char*, char*, va_list);
extern	int	snprint(char*, int, char*, ...);
extern	int	vsnprint(char*, int, char*, va_list);
extern	char*	smprint(char*, ...);
extern	char*	vsmprint(char*, va_list);
extern	int	sprint(char*, char*, ...);
extern	int	fprint(int, char*, ...);
extern	int	vfprint(int, char*, va_list);

extern	int	runesprint(Rune*, char*, ...);
extern	int	runesnprint(Rune*, int, char*, ...);
extern	int	runevsnprint(Rune*, int, char*, va_list);
extern	Rune*	runeseprint(Rune*, Rune*, char*, ...);
extern	Rune*	runevseprint(Rune*, Rune*, char*, va_list);
extern	Rune*	runesmprint(char*, ...);
extern	Rune*	runevsmprint(char*, va_list);

extern	int	fmtfdinit(Fmt*, int, char*, int);
extern	int	fmtfdflush(Fmt*);
extern	int	fmtstrinit(Fmt*);
extern	char*	fmtstrflush(Fmt*);
extern	int	runefmtstrinit(Fmt*);
extern	Rune*	runefmtstrflush(Fmt*);

extern	int	fmtinstall(int, int (*)(Fmt*));
extern	int	dofmt(Fmt*, char*);
extern	int	dorfmt(Fmt*, Rune*);
extern	int	fmtprint(Fmt*, char*, ...);
extern	int	fmtvprint(Fmt*, char*, va_list);
extern	int	fmtrune(Fmt*, int);
extern	int	fmtstrcpy(Fmt*, char*);
extern	int	fmtrunestrcpy(Fmt*, Rune*);
extern	int	errfmt(Fmt *f);

extern	char	*unquotestrdup(char*);
extern	Rune	*unquoterunestrdup(Rune*);
extern	char	*quotestrdup(char*);
extern	Rune	*quoterunestrdup(Rune*);
extern	int	quotestrfmt(Fmt*);
extern	int	quoterunestrfmt(Fmt*);
extern	void	quotefmtinstall(void);
extern	int	(*doquote)(int);

extern	int	nrand(int);
extern	ulong	truerand(void);
extern	ulong	ntruerand(ulong);

extern	int	isNaN(double);
extern	int	isInf(double, int);
extern	double	pow(double, double);

typedef struct Tm Tm;
struct Tm {
	int	sec;
	int	min;
	int	hour;
	int	mday;
	int	mon;
	int	year;
	int	wday;
	int	yday;
	char	zone[4];
	int	tzoff;
};
extern	vlong	osnsec(void);
#define	nsec	osnsec

extern	void	_assert(char*);
extern	double	charstod(int(*)(void*), void*);
extern	char*	cleanname(char*);
extern	double	frexp(double, int*);
extern	int	getfields(char*, char**, int, int, char*);
extern	char*	getuser(void);
extern	char*	getwd(char*, int);
extern	double	ipow10(int);
extern	double	ldexp(double, int);
extern	double	modf(double, double*);
extern	void	perror(const char*);
extern	double	pow10(int);
extern	uvlong	strtoull(const char*, char**, int);
extern	void	sysfatal(char*, ...);
extern	int	dec64(uchar*, int, char*, int);
extern	int	enc64(char*, int, uchar*, int);
extern	int	dec32(uchar*, int, char*, int);
extern	int	enc32(char*, int, uchar*, int);
extern	int	dec16(uchar*, int, char*, int);
extern	int	enc16(char*, int, uchar*, int);
extern	int	encodefmt(Fmt*);

/* use builtin for arm64 */
static __inline uintptr getcallerpc(void* dummy) {
	(void)dummy;
	return (uintptr)__builtin_return_address(0);
}

typedef
struct Lock {
	int	val;
	int	pid;
} Lock;

extern int	_tas(int*);

extern	void	lock(Lock*);
extern	void	unlock(Lock*);
extern	int	canlock(Lock*);

typedef struct QLock QLock;
struct QLock
{
	Lock	use;
	Proc	*head;
	Proc	*tail;
	int	locked;
};

extern	void	qlock(QLock*);
extern	void	qunlock(QLock*);
extern	int	canqlock(QLock*);
extern	void	_qlockinit(ulong (*)(ulong, ulong));

typedef
struct RWLock
{
	Lock	l;
	QLock	x;
	QLock	k;
	int	readers;
} RWLock;

extern	int	canrlock(RWLock*);
extern	int	canwlock(RWLock*);
extern	void	rlock(RWLock*);
extern	void	runlock(RWLock*);
extern	void	wlock(RWLock*);
extern	void	wunlock(RWLock*);

#define NETPATHLEN 40

#define	STATMAX	65535U
#define	DIRMAX	(sizeof(Dir)+STATMAX)
#define	ERRMAX	128

#define	MORDER	0x0003
#define	MREPL	0x0000
#define	MBEFORE	0x0001
#define	MAFTER	0x0002
#define	MCREATE	0x0004
#define	MCACHE	0x0010
#define	MMASK	0x0017

#define	OREAD	0
#define	OWRITE	1
#define	ORDWR	2
#define	OEXEC	3
#define	OTRUNC	16
#define	OCEXEC	32
#define	ORCLOSE	64
#define	OEXCL	0x1000

#define	AEXIST	0
#define	AEXEC	1
#define	AWRITE	2
#define	AREAD	4

#define QTDIR		0x80
#define QTAPPEND	0x40
#define QTEXCL		0x20
#define QTMOUNT		0x10
#define QTAUTH		0x08
#define QTFILE		0x00

#define DMDIR		0x80000000
#define DMAPPEND	0x40000000
#define DMEXCL		0x20000000
#define DMMOUNT		0x10000000
#define DMAUTH		0x08000000
#define DMREAD		0x4
#define DMWRITE		0x2
#define DMEXEC		0x1

typedef
struct Qid
{
	uvlong	path;
	ulong	vers;
	uchar	type;
} Qid;

typedef
struct Dir {
	ushort	type;
	uint	dev;
	Qid	qid;
	ulong	mode;
	ulong	atime;
	ulong	mtime;
	vlong	length;
	char	*name;
	char	*uid;
	char	*gid;
	char	*muid;
} Dir;

extern	Dir*	dirstat(char*);
extern	Dir*	dirfstat(int);
extern	int	dirwstat(char*, Dir*);
extern	int	dirfwstat(int, Dir*);
extern	long	dirread(int, Dir**);
extern	void	nulldir(Dir*);
extern	long	dirreadall(int, Dir**);

typedef
struct Waitmsg
{
	int pid;
	ulong time[3];
	char	*msg;
} Waitmsg;

extern	void	_exits(char*);
extern	void	exits(char*);
extern	int	create(char*, int, int);
extern	int	errstr(char*, uint);
extern	void	perror(const char*);
extern	long	readn(int, void*, long);
extern	int	remove(const char*);
extern	void	rerrstr(char*, uint);
extern	vlong	seek(int, vlong, int);
extern	int	segflush(void*, ulong);
extern	void	werrstr(char*, ...);

extern char *argv0;
#define	ARGBEGIN	for((argv0||(argv0=*argv)),argv++,argc--;\
			    argv[0] && argv[0][0]=='-' && argv[0][1];\
			    argc--, argv++) {\
				char *_args, *_argt;\
				Rune _argc;\
				_args = &argv[0][1];\
				if(_args[0]=='-' && _args[1]==0){\
					argc--; argv++; break;\
				}\
				_argc = 0;\
				while(*_args && (_args += chartorune(&_argc, _args)))\
				switch(_argc)
#define	ARGEND		SET(_argt);USED(_argt);USED(_argc); USED(_args);}USED(argv); USED(argc);
#define	ARGF()		(_argt=_args, _args="",\
			(*_argt? _argt: argv[1]? (argc--, *++argv): 0))
#define	EARGF(x)	(_argt=_args, _args="",\
			(*_argt? _argt: argv[1]? (argc--, *++argv): ((x), abort(), (char*)0)))

#define	ARGC()		_argc

#define	setbinmode()
