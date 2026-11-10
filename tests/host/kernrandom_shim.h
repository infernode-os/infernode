/*
 * Just enough of the native kernel for os/port/random.c to compile on
 * the host, for kernrandom_test.sh. Every header random.c includes is
 * this one; kernrandom_helper.c provides the functions, with a
 * generator, a clock and a sleep the test drives.
 */
#ifndef KERNRANDOM_SHIM
#define KERNRANDOM_SHIM
#include <stddef.h>
#include <string.h>

#define	nil	((void*)0)
typedef unsigned char	uchar;
typedef unsigned int	u32int;
typedef unsigned long long	u64int;
typedef unsigned long	ulong;
typedef long long	vlong;
typedef unsigned long long	uvlong;
typedef unsigned long	uintptr;
#define	USED(x)	if(x){}else{}

typedef struct Lock { int x; } Lock;
typedef struct QLock { int x; } QLock;
typedef struct Rendez { int x; } Rendez;
void	qlock(QLock*);
void	qunlock(QLock*);
void	ilock(Lock*);
void	iunlock(Lock*);

enum { Interp = 1 };
typedef struct Proc Proc;
struct Proc
{
	int	type;
	void	*iprog;
	Rendez	sleep;
};
extern Proc *up;

typedef struct Mach { ulong ticks; } Mach;
extern Mach fakemach;
#define	MACHP(n)	(&fakemach)
#define	TK2MS(x)	(x)	/* the test's ticks are milliseconds */

#define	waserror()	0
#define	poperror()
#define	nexterror()
void	release(void);
void	acquire(void);

int	print(char*, ...);
void	panic(char*, ...);
int	islo(void);
void	microdelay(int);
int	return0(void*);
void	tsleep(Rendez*, int (*)(void*), void*, ulong);
uvlong	fastticks(uvlong*);
int	hwrandom(uchar*, int);
char*	boardcmdline(void);

/* libsec, as include/libsec.h has them; the test links libsec's own */
enum { SHA256dlen = 32, SHA384dlen = 48, SHA512dlen = 64, SHA512bsize = 128, Digestbsize = 128 };
typedef struct DigestState DigestState;
struct DigestState
{
	u64int	len;
	u32int	state[5];
	uchar	buf[Digestbsize];
	int	blen;
	u64int	nb128[2];
	u64int	h64[8];
	u32int	h32[8];
	char	malloced;
	char	seeded;
};
typedef struct DigestState SHA512state;
DigestState*	sha256(uchar*, ulong, uchar*, DigestState*);
DigestState*	sha512(uchar*, ulong, uchar*, DigestState*);
DigestState*	hmac_sha512(uchar*, ulong, uchar*, ulong, uchar*, DigestState*);
#define	nelem(x)	(sizeof(x)/sizeof((x)[0]))

void	randominit(void);
ulong	randomread(void*, ulong);
void	genrandom(uchar*, int);
void	prng(uchar*, int);
int	prngtry(uchar*, int);
#endif
