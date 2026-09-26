/*
 * Interrupts: the PLIC, and the hart-local ones.
 *
 * A RISC-V hart takes three kinds of interrupt in S-mode, each with its
 * own bit in sie and a cause number in scause:
 *
 *	1  software	an IPI, sent through SBI (idlewake)
 *	5  timer	clock.c
 *	9  external	everything else, through the PLIC
 *
 * The PLIC (platform-level interrupt controller) is the same block on
 * QEMU's virt and on a PolarFire SoC, at the same address: a priority
 * per source, and per "context" (a hart in a privilege mode) an enable
 * bit per source, a threshold, and a claim/complete register. Which
 * context is a hart's S-mode is the board's to say (boardplicctx):
 * 2*hart+1 on virt, where every hart has M and S contexts; on the
 * PolarFire the E51 monitor hart has only an M context, which shifts
 * every other hart's S context down by one.
 *
 * Every device interrupt goes to the boot hart, as every GPU interrupt
 * goes to core 0 on the board (../arm64/main.c, squidboy): the other
 * harts take clock ticks and IPIs and run whatever those make ready.
 *
 * The interface is ../arm64/gic.c's -- intrenable, intrdisable,
 * irqdispatch, intrdump, intrpending -- so drivers are the same.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "ureg.h"
#include "fns.h"

enum
{
	Ssie	= 1<<1,		/* sie: software interrupts */
	Seie	= 1<<9,		/* sie: external interrupts */

	Priority	= 0x000000,	/* + 4*irq */
	Pending		= 0x001000,	/* bit per irq */
	Enable		= 0x002000,	/* + 0x80*ctx, bit per irq */
	Threshold	= 0x200000,	/* + 0x1000*ctx */
	Claim		= 0x200004,	/* + 0x1000*ctx: read claims, write completes */
};

#define PLIC(o)	(*(volatile u32int*)((uintptr)PLICREGS + (o)))

typedef struct Handler Handler;
struct Handler
{
	void	(*f)(Ureg*, void*);
	void	*a;
	char	*name;
	ulong	count;
	Handler	*next;
};

static Handler	*handlers[Nirq];
static Lock	intrlock;
static int	bootctx;		/* the boot hart's S-mode context: every device's */

int irqorphan[MAXMACH];
ulong nspurious;
static ulong nipi;

static void
enablebit(int ctx, int irq, int on)
{
	u32int *p, bit;

	p = (u32int*)((uintptr)PLICREGS + Enable + 0x80*ctx + 4*(irq/32));
	bit = 1 << (irq % 32);
	if(on)
		*(volatile u32int*)p |= bit;
	else
		*(volatile u32int*)p &= ~bit;
}

void
intrinit(void)
{
	int i;

	for(i = 0; i < MAXMACH; i++)
		irqorphan[i] = -1;
	bootctx = boardplicctx(m->hartid);
	for(i = 1; i < Nirq; i++){
		PLIC(Priority + 4*i) = 0;
		enablebit(bootctx, i, 0);
	}
	PLIC(Threshold + 0x1000*bootctx) = 0;
	__asm__ volatile("csrs sie, %0" :: "r"((ulong)(Ssie|Seie)));
}

/*
 * A secondary hart: no device interrupts (its threshold masks them
 * all, whatever the enables say), but IPIs, so an idle hart can be
 * woken to run something core 0's interrupts made ready.
 */
void
intrsecinit(void)
{
	int ctx;

	ctx = boardplicctx(m->hartid);
	if(ctx >= 0)
		PLIC(Threshold + 0x1000*ctx) = 7;
	__asm__ volatile("csrs sie, %0" :: "r"((ulong)Ssie));
}

void
intrenable(int irq, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	Handler *h;

	USED(tbdf);
	if(irq <= 0 || irq >= Nirq)
		panic("intrenable: irq %d out of range (%s)", irq, name);
	if(f == nil)
		panic("intrenable: nil handler for irq %d (%s)", irq, name);
	h = xalloc(sizeof *h);
	if(h == nil)
		panic("intrenable: no memory");
	h->f = f;
	h->a = a;
	h->name = name;
	ilock(&intrlock);
	h->next = handlers[irq];
	handlers[irq] = h;
	PLIC(Priority + 4*irq) = 1;
	enablebit(bootctx, irq, 1);
	iunlock(&intrlock);
}

void
intrdisable(int irq, void (*f)(Ureg*, void*), void *a, int tbdf, char *name)
{
	Handler **l, *h;

	USED(tbdf);
	USED(name);
	if(irq <= 0 || irq >= Nirq)
		return;
	ilock(&intrlock);
	for(l = &handlers[irq]; (h = *l) != nil; l = &h->next)
		if(h->f == f && h->a == a){
			*l = h->next;
			break;
		}
	if(handlers[irq] == nil){
		enablebit(bootctx, irq, 0);
		PLIC(Priority + 4*irq) = 0;
	}
	iunlock(&intrlock);
}

/*
 * An external interrupt: claim, run the handlers, complete; until the
 * PLIC has nothing more. Returns 0 only for a source that was enabled
 * with no handler to take it, which trap() treats as fatal.
 */
int
irqdispatch(Ureg *u)
{
	Handler *h;
	int ctx, irq, any;
	u32int claim;

	irqorphan[m->machno] = -1;
	ctx = boardplicctx(m->hartid);
	any = 0;
	for(;;){
		claim = PLIC(Claim + 0x1000*ctx);
		if(claim == 0)
			break;
		irq = claim;
		any = 1;
		if(irq >= Nirq || (h = handlers[irq]) == nil){
			irqorphan[m->machno] = irq;
			PLIC(Claim + 0x1000*ctx) = claim;
			return 0;
		}
		for(; h != nil; h = h->next){
			h->count++;
			h->f(u, h->a);
		}
		PLIC(Claim + 0x1000*ctx) = claim;
	}
	if(!any)
		ainc(&nspurious);
	return 1;
}

/* an IPI: take it down. Its job was to end a wfi, which it has. */
int
ipiintr(void)
{
	nipi++;
	__asm__ volatile("csrc sip, %0" :: "r"((ulong)Ssie));
	return 1;
}

void
intrdump(void)
{
	int i;
	Handler *h;

	uartputstr("intr: ");
	for(i = 1; i < Nirq; i++)
		for(h = handlers[i]; h != nil; h = h->next){
			uartputstr(h->name);
			uartputstr("=");
			uartputd(i);
			uartputstr("/");
			uartputd(h->count);
			uartputstr(" ");
		}
	uartputstr("\n  spurious: ");
	uartputd(nspurious);
	uartputstr(" ipis: ");
	uartputd(nipi);
	uartputstr(" orphan: ");
	if(irqorphan[m->machno] < 0)
		uartputstr("none");
	else
		uartputd(irqorphan[m->machno]);
	uartputstr("\n");
}

int
intrpending(void)
{
	int i;

	for(i = 1; i < Nirq; i++)
		if(PLIC(Pending + 4*(i/32)) & (1 << (i%32)))
			return i;
	return -1;
}

void
intrsummary(void)
{
	intrdump();
}

/*
 * Does an interrupt reach a handler? The PLIC cannot be told to raise
 * a source by software, but an IPI to ourselves travels the same trap
 * path: sie, sstatus.SIE, the vector, trap(), and back.
 */
void
plicintrprobe(void)
{
	ulong before;
	int i, s;

	before = nipi;
	s = spllo();
	sbisendipi(1, m->hartid);
	for(i = 0; i < 1000000 && nipi == before; i++)
		;
	splx(s);
	print("intr: self-IPI %s\n", nipi != before ? "taken (trap path OK)" : "NEVER ARRIVED");
}
