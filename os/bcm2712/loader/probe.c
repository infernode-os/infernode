/*
 * What the firmware left: the Pi 5 serial loader's report.
 *
 * Linked into serialboot built for this board, and run once before it
 * offers to load a kernel. Everything the port would otherwise assume
 * about the machine it finds itself on is asked here instead, with the
 * MMU off and nothing else in the way: the exception level, whether the
 * mailbox still answers and at which address, what state the bridge to
 * RP1 was left in, whether the other cores start through PSCI, whether
 * memory above 4GB is there.
 *
 * Nothing here may hang or kill the loader. Every wait is bounded, and
 * a fault in a probe is reported and stepped over (probevec.S).
 */

typedef unsigned int u32int;
typedef unsigned long long u64int;
typedef unsigned char uchar;

void	puts(char*);
u32int	now(void);
void	setvbar(void);
u64int	smc(u64int, u64int, u64int, u64int);
void	coreentry(void);
void	probe(u64int);
void	excn(u64int, u64int, u64int);
void	probeinit(void);
void	wdstop(void);
void	idle(int);

#define REG(a)		(*(volatile u32int*)(unsigned long)(a))
#define SYSREG(n) ({ u64int v; __asm__ volatile("mrs %0, " n : "=r"(v)); v; })

#ifndef MBOXREGS
#define MBOXREGS	0x107C013880ULL
#endif
#ifndef SYSTIMERREGS
#define SYSTIMERREGS	0x107C003000ULL
#endif
#ifndef GICDREGS
#define GICDREGS	0x107FFF9000ULL
#endif
#ifndef GICCREGS
#define GICCREGS	0x107FFFA000ULL
#endif
#ifndef PCIE2REGS
#define PCIE2REGS	0x1000120000ULL
#endif
#ifndef RP1REGS
#define RP1REGS		0x1C00000000ULL	/* where the firmware leaves it; Linux moves it to 0x1F00000000 */
#endif
#ifndef UART10REGS
#define UART10REGS	0x107D001000ULL
#endif

#ifndef PMREGS
#define PMREGS		0x107D200000ULL
#endif

enum
{
	Pmrstc		= 0x1C,
	Pmwdog		= 0x24,
	Pmpasswd	= 0x5A000000,
	Rstcwrcfgclr	= 0xFFFFFFCF,
	Rstcfullreset	= 0x20,
	Rstcreset	= 0x102,
	Wdogsecs	= 15,		/* the counter holds at most 16 */
	Idlesecs	= 180,		/* no host for this long: go back to the OS */

	Mboxrd		= 0x00,
	Mboxst		= 0x18,
	Mboxwr		= 0x20,
	Mboxfull	= 0x80000000,
	Mboxempty	= 0x40000000,
	Mboxprop	= 8,
	Mboxwaitus	= 500000,

	Tagfwrev	= 0x00000001,
	Tagmodel	= 0x00010001,
	Tagrev		= 0x00010002,
	Tagarmmem	= 0x00010005,
	Tagvcmem	= 0x00010006,
	Tagclock	= 0x00030002,
	Tagtemp		= 0x00030006,

	Psciversion	= 0x84000000,
	Pscicpuoff	= 0x84000002,
	Pscicpuon	= 0xC4000003,

	Ncore		= 4,
	Coreseen	= 0xC0DE,
};

static volatile u32int mbuf[32] __attribute__((aligned(16)));
static u64int busalias = 0xC0000000;
static volatile int faults;	/* the fault handler counts; polled in wait loops */

/* written by each core as it arrives, read here; the MMU is off */
volatile u64int coreflag[Ncore];
volatile u64int coreel[Ncore];

static void
putx(u64int v)
{
	static char hex[] = "0123456789abcdef";
	char b[20];
	int i, n;

	n = 0;
	b[n++] = '0';
	b[n++] = 'x';
	for(i = 60; i > 0 && (v >> i) == 0; i -= 4)
		;
	for(; i >= 0; i -= 4)
		b[n++] = hex[(v >> i) & 0xF];
	b[n] = 0;
	puts(b);
}

static void
putd(u64int v)
{
	char b[24];
	int n;

	n = sizeof b - 1;
	b[n] = 0;
	do{
		b[--n] = '0' + v % 10;
		v /= 10;
	}while(v != 0);
	puts(b + n);
}

static void
kv(char *k, u64int v)
{
	puts("  ");
	puts(k);
	puts(" = ");
	putx(v);
	puts("\r\n");
}

/*
 * The watchdog is what lets the board be left alone. The loader is
 * booted once by tryboot, from a card whose normal boot is an OS, so
 * any reset goes back to that OS: if a probe wedges the bus, or no host
 * turns up, the board comes back by itself rather than wanting someone
 * at the power switch. It runs from the start of the report until
 * the jump to a kernel.
 */
static void
wdfire(u32int ticks)
{
	REG(PMREGS + Pmwdog) = Pmpasswd | ticks;
	REG(PMREGS + Pmrstc) = Pmpasswd | (REG(PMREGS + Pmrstc) & Rstcwrcfgclr) | Rstcfullreset;
}

void
wdstop(void)
{
	REG(PMREGS + Pmrstc) = Pmpasswd | Rstcreset;
}

/* called from every wait for a byte; active says one arrived */
void
idle(int active)
{
	static u32int lastbyte, lastkick;
	u32int t;

	t = now();
	if(lastbyte == 0 || active)
		lastbyte = t;
	if(t - lastbyte > Idlesecs*1000000U){
		puts("\r\nserialboot: no host, resetting\r\n");
		wdfire(1<<12);
		for(;;)
			;
	}
	if(t - lastkick > 1000000){
		lastkick = t;
		wdfire(Wdogsecs<<16);
	}
}

/* probevec.S: a fault in a probe lands here, and execution steps over it */
void
excn(u64int esr, u64int elr, u64int far)
{
	faults++;
	puts("  FAULT esr=");
	putx(esr);
	puts(" elr=");
	putx(elr);
	puts(" far=");
	putx(far);
	puts("\r\n");
}

/*
 * One tag, one round trip. Returns the word count of the answer, or -1.
 */
static int
mbox(u32int tag, u32int a0, int nw)
{
	u64int bus;
	u32int start, v;
	int i;

	mbuf[0] = (6 + nw) * 4;
	mbuf[1] = 0;
	mbuf[2] = tag;
	mbuf[3] = nw * 4;
	mbuf[4] = 0;
	mbuf[5] = a0;
	for(i = 1; i < nw; i++)
		mbuf[5 + i] = 0;
	mbuf[5 + nw] = 0;
	__asm__ volatile("dsb sy");

	bus = ((u64int)(unsigned long)&mbuf[0] & 0x3FFFFFFF) | busalias;

	/* a fault gives up at once: retried, it would bury the report */
	faults = 0;
	start = now();
	while(REG(MBOXREGS + Mboxst) & Mboxfull)
		if(faults != 0 || now() - start > Mboxwaitus)
			return -1;
	if(faults != 0)
		return -1;
	REG(MBOXREGS + Mboxwr) = (u32int)bus | Mboxprop;

	start = now();
	for(;;){
		while(REG(MBOXREGS + Mboxst) & Mboxempty)
			if(faults != 0 || now() - start > Mboxwaitus)
				return -1;
		v = REG(MBOXREGS + Mboxrd);
		if(faults != 0)		/* a load stepped over leaves v stale */
			return -1;
		if((v & 0xF) == Mboxprop)
			break;
	}
	__asm__ volatile("dsb sy");
	if(mbuf[1] != 0x80000000 || (mbuf[4] & 0x80000000) == 0)
		return -1;
	return (mbuf[4] & 0x7FFFFFFF) / 4;
}

static void
kvtag(char *k, u32int tag, u32int a0, int nw)
{
	int i, n;

	n = mbox(tag, a0, nw);
	puts("  ");
	puts(k);
	puts(" =");
	if(n < 0){
		puts(" no answer\r\n");
		return;
	}
	for(i = 0; i < n && i < nw; i++){
		puts(" ");
		putx(mbuf[5 + i]);
	}
	puts("\r\n");
}

static void
mailboxes(void)
{
	static u64int alias[] = { 0xC0000000, 0, 0x40000000 };
	int i;

	puts("mailbox:\r\n");
	for(i = 0; i < 3; i++){
		busalias = alias[i];
		if(mbox(Tagrev, 0, 1) >= 0)
			break;
		if(faults != 0){
			puts("  the mailbox itself faults\r\n");
			return;
		}
		puts("  no answer with bus alias ");
		putx(alias[i]);
		puts("\r\n");
	}
	if(i == 3)
		return;
	kv("bus alias", busalias);
	kvtag("board rev", Tagrev, 0, 1);
	kvtag("board model", Tagmodel, 0, 1);
	kvtag("firmware rev", Tagfwrev, 0, 1);
	kvtag("arm memory (base size)", Tagarmmem, 0, 2);
	kvtag("vc memory (base size)", Tagvcmem, 0, 2);
	kvtag("arm clock (id hz)", Tagclock, 3, 2);
	kvtag("temperature (id mC)", Tagtemp, 0, 2);
}

static void
bridge(void)
{
	static struct { char *n; u32int off; } r[] = {
		{"rc id",		0x0000},
		{"misc_ctrl",		0x4008},
		{"mem_win0_lo",		0x400C},
		{"mem_win0_hi",		0x4010},
		{"rc_bar2_lo",		0x4034},
		{"rc_bar2_hi",		0x4038},
		{"pcie_status",		0x4068},
		{"win0_base_limit",	0x4070},
		{"win0_base_hi",		0x4080},
		{"win0_limit_hi",	0x4084},
		{"hard_debug",		0x4304},
	};
	int i;

	puts("pcie2 (the bridge to RP1):\r\n");
	for(i = 0; i < (int)(sizeof r / sizeof r[0]); i++)
		kv(r[i].n, REG(PCIE2REGS + r[i].off));

	puts("rp1:\r\n");
	kv("sysinfo chip id", REG(RP1REGS + 0x0));
	kv("sysinfo platform", REG(RP1REGS + 0x4));
}

static void
interrupts(void)
{
	puts("gic:\r\n");
	kv("gicd_typer", REG(GICDREGS + 0x004));
	kv("gicd_iidr", REG(GICDREGS + 0x008));
	kv("gicc_iidr", REG(GICCREGS + 0x0FC));
}

/*
 * Is the system timer running, and does it agree with the generic
 * counter? Over 100ms by the counter.
 */
static void
clocks(void)
{
	u32int st0, st1, t0;

	puts("clocks:\r\n");
	st0 = REG(SYSTIMERREGS + 4);
	t0 = now();
	while(now() - t0 < 100000)
		;
	st1 = REG(SYSTIMERREGS + 4);
	kv("cntfrq_el0", SYSREG("cntfrq_el0"));
	puts("  systimer over 100ms of generic counter: ");
	putd(st1 - st0);
	puts("us\r\n");
}

/*
 * Bring the other three up and straight back down: entry is coreentry
 * in probevec.S, which records where it arrived and calls CPU_OFF, so
 * that a kernel loaded after this still finds them off.
 */
static void
cores(void)
{
	u64int v, r;
	u32int t0;
	int i;

	puts("psci:\r\n");
	faults = 0;
	v = smc(Psciversion, 0, 0, 0);
	if(faults != 0){
		puts("  no EL3 answers smc\r\n");
		return;
	}
	kv("version", v);
	for(i = 1; i < Ncore; i++){
		coreflag[i] = 0;
		__asm__ volatile("dsb sy");
		r = smc(Pscicpuon, (u64int)i << 8, (u64int)(unsigned long)coreentry, 0);
		puts("  core ");
		putd(i);
		puts(": cpu_on ");
		putx(r);
		t0 = now();
		while(coreflag[i] == 0 && now() - t0 < 1000000)
			;
		if(coreflag[i] == 0)
			puts(", never arrived\r\n");
		else{
			puts(", mpidr ");
			putx(coreflag[i]);
			puts(" currentel ");
			putx(coreel[i] >> 2);
			puts("\r\n");
		}
	}
}

/*
 * Is memory where the board's size says it is? The pattern is put back:
 * nothing above the first gigabyte belongs to anyone yet, but a report
 * has no business leaving a mark.
 */
static void
memory(void)
{
	static u64int at[] = { 0x40000000, 0x80000000, 0xC0000000, 0x100000000ULL, 0x1C0000000ULL };
	volatile u32int *p;
	u64int size;
	u32int save, got;
	int i, n;

	puts("memory:\r\n");
	n = mbox(Tagrev, 0, 1);
	if(n < 0 || (mbuf[5] & (1<<23)) == 0){
		puts("  size unknown, not tested\r\n");
		return;
	}
	size = 256ULL*1024*1024 << ((mbuf[5] >> 20) & 7);
	puts("  size ");
	putd(size >> 20);
	puts(" MB\r\n");
	for(i = 0; i < (int)(sizeof at / sizeof at[0]); i++){
		if(at[i] >= size)
			break;
		p = (volatile u32int*)(unsigned long)at[i];
		faults = 0;
		save = *p;
		*p = 0xA5C3F00D;
		__asm__ volatile("dsb sy");
		got = *p;
		*p = save;
		puts("  ");
		putx(at[i]);
		puts(faults != 0 ? " FAULTED\r\n" : got == 0xA5C3F00D ? " ok\r\n" : " DID NOT HOLD\r\n");
	}
}

/*
 * Before the first touch of the UART: RP1 is behind PCIe, and a load
 * from a window that is not there hangs the core rather than faulting,
 * which is exactly how the first boot on a board ended.
 */
void
probeinit(void)
{
	if((SYSREG("CurrentEL") >> 2) != 2)
		return;
	setvbar();
	wdfire(Wdogsecs<<16);
}

void
probe(u64int dtb)
{
	u64int el;

	puts("\r\n=== bcm2712 serialboot report ===\r\n");
	el = SYSREG("CurrentEL") >> 2;
	kv("currentel", el);
	kv("x0 (device tree)", dtb);
	kv("midr", SYSREG("midr_el1"));
	kv("mpidr", SYSREG("mpidr_el1"));
	kv("mmfr0", SYSREG("id_aa64mmfr0_el1"));
	kv("ctr", SYSREG("ctr_el0"));
	if(el != 2){
		puts("not at EL2: no fault handler, skipping the probes\r\n");
		return;
	}
	kv("sctlr_el2", SYSREG("sctlr_el2"));
	kv("hcr_el2", SYSREG("hcr_el2"));

	mailboxes();
	bridge();
	interrupts();
	clocks();
	cores();
	wdfire(Wdogsecs<<16);
	memory();

	/* last: the one read that could wedge the bus rather than fault */
	puts("uart10:\r\n");
	kv("cr", REG(UART10REGS + 0x30));
	puts("=== end of report ===\r\n");
}
