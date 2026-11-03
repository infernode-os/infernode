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
enum { ChachaBsize = 64, SHA256dlen = 32 };
typedef struct ChaChastate ChaChastate;
struct ChaChastate
{
	u32int	state[16];
	uchar	buf[ChachaBsize];
	int	blen;
	int	rounds;
};
void	setupChaChastate(ChaChastate*, uchar*, int, uchar*, int, int);
void	chacha_encrypt(uchar*, int, ChaChastate*);
void	chacha_setctr(ChaChastate*, u32int);
typedef struct DigestState DigestState;
DigestState*	sha256(uchar*, ulong, uchar*, DigestState*);

void	randominit(void);
ulong	randomread(void*, ulong);
void	genrandom(uchar*, int);
void	prng(uchar*, int);
int	prngtry(uchar*, int);
#endif
