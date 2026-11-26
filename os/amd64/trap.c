/*
 * os/amd64/trap.c -- the IDT, the 8259, the 8254, and the C side of an
 * interrupt.
 *
 * The timer is the only interrupt source this stage enables: the 8254
 * ticks at HZ, the 8259 delivers it on vector 32, and trap() counts it,
 * acknowledges it, and asks the scheduler whether another thread should
 * run.  Every exception reports itself and panics, except the breakpoint,
 * which reports and returns, so the boot test can prove the path without
 * dying.
 */

#include "console.h"
#include "io.h"
#include "port.h"
#include "trap.h"
#include "thread.h"

#define PIC1		0x20
#define PIC1CMD		PIC1
#define PIC1DATA	(PIC1+1)
#define PIC2		0xA0
#define PIC2CMD		PIC2
#define PIC2DATA	(PIC2+1)
#define PICEOI		0x20

#define PIT		0x40
#define PITCMD		0x43

#define PITBASE		1193182		/* the 8254's input clock, Hz */

volatile uint64_t ticks;

/* the machine's tick count, for the boot clock's fallback calibration */
uint64_t
tickcount(void)
{
	return ticks;
}

struct idtentry
{
	uint16_t	off0;
	uint16_t	sel;
	uint8_t		ist;
	uint8_t		type;
	uint16_t	off1;
	uint32_t	off2;
	uint32_t	zero;
} __attribute__((packed));

struct idtptr
{
	uint16_t	limit;
	uint64_t	base;
} __attribute__((packed));

_Static_assert(sizeof(Trapframe) == 176, "trap frame");

static struct idtentry idt[256];
static struct idtptr idtp;

extern void (*isrtable[48])(void);

static const char *exceptname[32] = {
	"divide error",
	"debug",
	"nmi",
	"breakpoint",
	"overflow",
	"bound range",
	"invalid opcode",
	"device not available",
	"double fault",
	"coprocessor segment",
	"invalid tss",
	"segment not present",
	"stack fault",
	"general protection",
	"page fault",
	"reserved",
	"x87",
	"alignment check",
	"machine check",
	"simd",
	"virtualization",
	"control protection",
	"reserved", "reserved", "reserved", "reserved",
	"reserved", "reserved", "reserved", "reserved", "reserved", "reserved",
};

static void
setgate(int v, void (*stub)(void))
{
	uint64_t a;

	a = (uint64_t)(uintptr_t)stub;
	idt[v].off0 = (uint16_t)a;
	idt[v].sel = KCS;
	idt[v].ist = 0;
	idt[v].type = 0x8E;		/* present, DPL0, 64-bit interrupt gate */
	idt[v].off1 = (uint16_t)(a >> 16);
	idt[v].off2 = (uint32_t)(a >> 32);
	idt[v].zero = 0;
}

/*
 * The interrupt registry.
 *
 * Sixteen lines, one handler each.  A PCI device's INTx line is one of
 * these; the handler is expected to quiesce its device (read the
 * status register that clears it) BEFORE the EOI below, because the
 * line is level-triggered: acknowledging first would let the still
 * asserted line interrupt again immediately.
 */
typedef struct Intr Intr;
struct Intr
{
	void	(*fn)(void*);
	void	*arg;
};
static Intr	intrs[16];
static uint8_t	pic1mask = 0xFE;	/* IRQ0: the timer */
static uint8_t	pic2mask = 0xFF;

/*
 * Let a line through.  Anything on the slave 8259 also needs the
 * cascade line (IRQ2) open on the master, or it never arrives.
 */
int
intrenable(int irq, void (*fn)(void*), void *arg, char *name)
{
	(void)name;
	if(irq < 0 || irq > 15 || fn == 0)
		return -1;
	intrs[irq].fn = fn;
	intrs[irq].arg = arg;
	if(irq < 8)
		pic1mask &= ~(1 << irq);
	else{
		pic1mask &= ~(1 << 2);
		pic2mask &= ~(1 << (irq - 8));
	}
	outb(PIC1DATA, pic1mask);
	outb(PIC2DATA, pic2mask);
	return irq;
}

void
intrdisable(int irq)
{
	if(irq < 0 || irq > 15)
		return;
	intrs[irq].fn = 0;
	intrs[irq].arg = 0;
	if(irq < 8)
		pic1mask |= 1 << irq;
	else
		pic2mask |= 1 << (irq - 8);
	outb(PIC1DATA, pic1mask);
	outb(PIC2DATA, pic2mask);
}

static void
picdispatch(Trapframe *f)
{
	int irq;

	irq = (int)f->vector - 32;
	if(irq < 0 || irq > 15)
		return;
	if(intrs[irq].fn != 0)
		(*intrs[irq].fn)(intrs[irq].arg);
	if(irq >= 8)
		outb(PIC2CMD, PICEOI);
	outb(PIC1CMD, PICEOI);
}

/* the 8259s: remap to 0x20/0x28 and enable only the timer */
static void
picinit(void)
{
	outb(PIC1CMD, 0x11);	io_wait();	/* ICW1: ICW4, cascade */
	outb(PIC2CMD, 0x11);	io_wait();
	outb(PIC1DATA, 0x20);	io_wait();	/* ICW2: vectors */
	outb(PIC2DATA, 0x28);	io_wait();
	outb(PIC1DATA, 0x04);	io_wait();	/* ICW3: slave on IRQ2 */
	outb(PIC2DATA, 0x02);	io_wait();
	outb(PIC1DATA, 0x01);	io_wait();	/* ICW4: 8086 mode */
	outb(PIC2DATA, 0x01);	io_wait();
	outb(PIC1DATA, 0xFE);			/* IRQ0 only */
	outb(PIC2DATA, 0xFF);
}

/* channel 0 in mode 2 (rate generator) */
static void
pitinit(void)
{
	uint16_t div;

	div = (PITBASE + HZ/2) / HZ;
	outb(PITCMD, 0x34);			/* channel 0, lo/hi, mode 2 */
	outb(PIT, (uint8_t)div);
	outb(PIT, (uint8_t)(div >> 8));
}

void
trapinit(void)
{
	int i;

	for(i = 0; i < 48; i++)
		setgate(i, isrtable[i]);
	idtp.limit = sizeof(idt) - 1;
	idtp.base = (uint64_t)(uintptr_t)idt;
	__asm__ volatile("lidt %0" : : "m"(idtp));
	picinit();
	pitinit();
	threadsinit();
	consprint("infernode/amd64: traps and timer at ");
	consprintdec(HZ);
	consprint(" Hz\n");
}

static void
panic(void)
{
	consprint("infernode/amd64: panic\n");
	consprint("infernode/amd64: halted\n");
	for(;;)
		__asm__ volatile("cli; hlt");
}

static void
excep(Trapframe *f)
{
	uint64_t cr2;

	consprint("infernode/amd64: trap ");
	consprintdec(f->vector);
	consprint(" ");
	consprint(exceptname[(int)f->vector]);
	consprint(" err ");
	consprinthex(f->err);
	consprint(" rip ");
	consprinthex(f->rip);
	consprint(" rsp ");
	consprinthex(f->rsp);
	if(f->vector == 14){
		__asm__ volatile("mov %%cr2, %0" : "=r"(cr2));
		consprint(" cr2 ");
		consprinthex(cr2);
	}
	consprint("\n");
	if(f->vector == 3)
		return;			/* breakpoint: return to the next insn */
	panic();
}

Trapframe*
trap(Trapframe *f)
{
	if(f->vector < 32){
		excep(f);
		return f;
	}
	if(f->vector == 32){
		ticks++;
		outb(PIC1CMD, PICEOI);
		/*
		 * os/port's clock first: it counts m->ticks, runs due
		 * sleeps and may preempt, in which case it returns only
		 * when this process is scheduled again.  The mini
		 * kernel's thread scheduler runs only when no os/port
		 * process exists (the kerneltest boots).
		 */
		portclocktick(f->rip);
		if(portactive())
			return f;
		return threadsched(f);
	}
	picdispatch(f);
	return f;
}
