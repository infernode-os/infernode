/*
 * Platform functions for the bare-metal RISC-V kernel.
 *
 * The board interface is ../arm64/fns.h's, hook for hook
 * (docs/BAREMETAL-BOARD-INTERFACE.md), so a board directory written for
 * one architecture reads the same as one written for the other. What
 * is RISC-V's own: SBI (the firmware interface below S-mode), the PLIC,
 * and the timer, which is SBI's set_timer against the time CSR.
 *
 * The rule ../arm64/fns.h states holds here too: a new hook is an
 * argument for moving code into os/riscv64, not for widening the
 * interface.
 */

/* the console: board UART, polled */
void	uartinit(void);
void	uartconsole(uintptr, int);
char*	uartdescribe(void);
void	uartputc(int);
int	uartgetc(void);
void	serialrecover(void);
int	hwrandom(uchar*, int);
void	uartputstr(char*);
void	uartlockon(void);
int	uartlock(void);
void	uartunlock(int);
void	uartputx(u64int);
void	uartputd(u64int);

/* the board's hooks, in the order kmain calls them */
char*	boardname(void);
void	boardprobe(void);
void	boardioprobe(void);
void	boardclockcheck(void);
void	boardfbprobe(void);
void	boarddevprobe(void);
void	displaywatch(void*);
void	boardintrprobe(void);
void	boardstartcpus(uintptr);
void	boardlockon(void);
void	boardusblink(void);
uvlong	boardtimebase(void);		/* the time CSR's rate, Hz */
int	boardplicctx(ulong hartid);	/* the PLIC context of a hart's S-mode */

/* arch.S */
void	coherence(void);
void	fpinit(void);
void	fpoff(void);
void	cacheiflush(void*, ulong);
void	cachedwbinvse(void*, int);
void	cachedwbse(void*, int);
void	fencei(void);
void	idlewfi(void);
#define getcallerpc(x)	((ulong)(uintptr)__builtin_return_address(0))
ulong	ainc(ulong*);

/* SBI: sbi.c */
vlong	sbicall(int ext, int fn, uvlong a0, uvlong a1, uvlong a2, uvlong a3, vlong *valp);
int	sbiprobe(int ext);
void	sbisettimer(uvlong);
void	sbisendipi(ulong hartmask, ulong hartbase);
void	sbiremotefencei(void);
int	sbihartstart(ulong hartid, uintptr entry, uintptr opaque);
int	sbihartstatus(ulong hartid);
void	sbireset(int type);
void	sbiputc(int);
char*	sbidescribe(void);

/* ../port/xalloc.c, which this kernel extends */
void	ixsummary(void);
void*	xspanalloc(ulong, int, ulong);
extern uintptr	xallocpref;
void	xhole(uintptr, uintptr);
int	xmerge(void*, void*);

/* the clock: clock.c */
void	clockinit(void);
void	secclockinit(void);
u64int	clockcount(void);
u64int	clockfreq(void);
u64int	clockticks(void);
void	microdelay(int);
int	clockintr(Ureg*);

/* interrupts: plic.c */
int	irqdispatch(Ureg*);
extern int irqorphan[];
void	intrdump(void);
int	intrpending(void);
extern ulong nspurious;
void	intrenable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrdisable(int, void (*)(Ureg*, void*), void*, int, char*);
void	intrinit(void);
void	intrsecinit(void);		/* a secondary hart's PLIC context */
void	intrsummary(void);
void	plicintrprobe(void);

int	getmacaddr(uchar*);
void	mmunormalnc(uintptr, usize);

/* memory: mmu.c */
void	mmuinit(void);
void	mmuenable(void);
int	mmuon(void);
int	mmucaches(void);
uintptr	mmuramtop(void);
uintptr	mmuhightop(void);
uintptr	mmul1(void);
uintptr	mmumapped(void);
extern uintptr	dtbptr;
extern ulong	boothartid;

/* ../virtio/fdt.c: every riscv64 board has a device tree */
int	fdtvalid(void);
uintptr	fdtsize(void);
int	fdtreserved(uintptr*, uintptr*, int);

int	probe32(uintptr, u32int*);
void	trap(Ureg*);
void	dumpureg(Ureg*);
void	trapinit(void);
int	typecheck(void);
void	kmain(void);
void	setpanic(void);
extern void	(*screenputs)(char*, int);

struct Hci;
long	kchanio(void*, void*, int, int);
char*	getconf(char*);
int	isaconfig(char*, int, struct Hci*);
void	clockcheck(void);
void	swcursorat(int, int);
void	idlehands(void);
void	idlewake(void);
void	procsave(Proc*);
void	procrestore(Proc*);
void	confinit(void);
void	kmapinval(void);
void	hzclock(Ureg*);
extern int	rootosinitlen;
void	dumpstack(void);
void	kprocchild(Proc*, void(*)(void*), void*);

/*
 * waserror: see ../arm64/fns.h. errlabcheck() catches an error stack
 * about to overflow before setlabel writes past it.
 */
#define	waserror()	(errlabcheck(), up->nerrlab++, setlabel(&up->errlab[up->nerrlab-1]))

#include "../port/portfns.h"

/* reset, A/B boot and the boot watchdog: may all be empty */
void	boardreboot(void);
void	boardtryboot(void);
void	tryboot(void);
void	booted(void);
void	boardbooted(void);
void	boardbootwatchdog(void);
void	boardwatchdogpoll(void);
void	boardwatchdogtick(void);
int	boardcandidate(void);
char*	boardcmdline(void);
