/*
 * RP1 as a whole: finishing the PCIe link the firmware left up, and its
 * interrupts.
 *
 * The kernel keeps the firmware's bridge setup rather than doing its
 * own (README.md). What the firmware has no need of is done here:
 * bus numbers on the root port, without which RP1's config space reads
 * as all ones; MaxPayload 256 and MaxReadReq 512 on both ends; and MSI.
 *
 * Each of RP1's interrupts is a vector of its own. RP1 raises one by
 * writing its number, by MSI-X, to a PCIe address the bridge sends to
 * the MIP, which makes it GIC_SPI 128 + n, an edge. A level source also
 * waits for an acknowledgement in RP1's MSI-X config before it will
 * send another. From Linux's drivers/mfd/rp1.c, irq-bcm2712-mip.c and
 * pcie-brcmstb.c.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "io.h"
#include "board.h"

#define PCIE(o)		(*(volatile u32int*)(uintptr)(PCIE2REGS + (o)))
#define MIP(o)		(*(volatile u32int*)(uintptr)(0x1000130000ULL + (o)))
#define MSIXCFG(n)	(*(volatile u32int*)(uintptr)(RP1REGS + 0x108000 + (n)))

enum
{
	Extcfg		= 0x8000,	/* the bridge's window on config space */
	Extcfgidx	= 0x9000,

	Msixcap		= 0xB0,
	Rcbar1lo	= 0x402C,
	Rcbar1hi	= 0x4030,
	Ubusbar1lo	= 0x40AC,
	Ubusbar1hi	= 0x40B0,

	Mipcfgl		= 0x20,
	Mipcfgh		= 0x30,
	Mipmaskl	= 0x40,
	Mipmaskh	= 0x50,
	Mipvpul		= 0x60,
	Mipvpuh		= 0x70,
	Msipciaddr	= 0xFFFFF000U,	/* PCIe 0xFF_FFFF_F000 is the MIP */
	Msipcihi	= 0xFF,
	Ibar4k		= 0x1C,		/* a bridge window's size code */

	Regset		= 0x800,
	Cfgenable	= 1<<0,
	Cfgiack		= 1<<2,
	Cfgiacken	= 1<<3,

	IRQmip		= IRQspi + 128,
	Nvec		= 61,
};

typedef struct Vec Vec;
struct Vec
{
	void	(*f)(Ureg*, void*);
	void	*a;
	int	level;
};

static Vec vec[Nvec];
static volatile u32int *table;		/* the MSI-X table */

static void
rp1interrupt(Ureg *u, void *arg)
{
	Vec *v;
	int n;

	v = arg;
	n = v - vec;
	(*v->f)(u, v->a);
	if(v->level)
		MSIXCFG(Regset + 8 + 4*n) = Cfgiack;
}

/*
 * Interrupts for one of RP1's devices: n is its RP1_INT_ number, level
 * says it stays asserted until the device is served.
 */
void
rp1intrenable(int n, void (*f)(Ureg*, void*), void *a, int level, char *name)
{
	Vec *v;

	rp1link();			/* #G's init comes before socdevprobe */
	if(n < 0 || n >= Nvec || table == nil)
		panic("rp1intrenable: %s: vector %d", name, n);
	v = &vec[n];
	v->f = f;
	v->a = a;
	v->level = level;
	gicedge(IRQmip + n);
	intrenable(IRQmip + n, rp1interrupt, v, 0, name);
	table[4*n + 0] = Msipciaddr;
	table[4*n + 1] = Msipcihi;
	table[4*n + 2] = n;
	table[4*n + 3] = 0;		/* unmasked */
	coherence();
	MSIXCFG(Regset + 8 + 4*n) = Cfgenable | (level ? Cfgiacken : 0);
	coherence();
}

void
rp1link(void)
{
	u32int bar, off;

	if(table != nil)
		return;
	PCIE(0x18) = (PCIE(0x18) & 0xFF000000) | 1<<16 | 1<<8;	/* subordinate 1, secondary 1, primary 0 */
	coherence();
	PCIE(Extcfgidx) = 1<<20;		/* bus 1, device 0, function 0: RP1 */
	coherence();
	microdelay(10);
	PCIE(Extcfg + 4) = (PCIE(Extcfg + 4) & 0xFFFF) | 6;
	PCIE(Extcfg + 0x78) = (PCIE(Extcfg + 0x78) & ~(7<<12 | 7<<5)) | 2<<12 | 1<<5;
	PCIE(0xB4) = (PCIE(0xB4) & ~(7<<12 | 7<<5)) | 2<<12 | 1<<5;
	coherence();

	/* the MIP: every vector an edge, to the ARM */
	MIP(Mipmaskl) = 0;
	MIP(Mipmaskh) = 0;
	MIP(Mipvpul) = ~0;
	MIP(Mipvpuh) = ~0;
	MIP(Mipcfgl) = ~0;
	MIP(Mipcfgh) = ~0;

	/* a window from PCIe to it */
	PCIE(Rcbar1lo) = Msipciaddr | Ibar4k;
	PCIE(Rcbar1hi) = Msipcihi;
	PCIE(Ubusbar1lo) = 0x00130000 | 1;
	PCIE(Ubusbar1hi) = 0x10;
	coherence();

	/* RP1's table, in the BAR its capability names, at the firmware's PCIe address for that BAR */
	off = PCIE(Extcfg + Msixcap + 4);
	bar = PCIE(Extcfg + 0x10 + 4*(off & 7)) & ~0xF;
	table = (u32int*)(uintptr)(RP1REGS + (bar - 0x80000000U) + (off & ~7));
	PCIE(Extcfg + Msixcap) = (PCIE(Extcfg + Msixcap) & ~(1<<30)) | 1<<31;
	coherence();
	print("rp1: chip %#ux msi-x table at %#p, %d vectors\n",
		*(u32int*)(uintptr)RP1REGS, table, ((PCIE(Extcfg + Msixcap) >> 16) & 0x7FF) + 1);
}
