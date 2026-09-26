/*
 * SBI: the Supervisor Binary Interface, how an S-mode kernel asks the
 * M-mode firmware beneath it (OpenSBI) for what only M-mode can do --
 * program the timer, interrupt another hart, start a hart, reset.
 *
 * The call is an ecall with the extension id in a7, the function in a6
 * and arguments in a0-a5; the firmware answers an error in a0 and a
 * value in a1. Every extension used here is probed first: SBI v0.2+
 * firmware answers the base extension's probe, and a missing extension
 * is a message and a fallback, not an illegal-instruction trap.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"

enum
{
	Sbibase		= 0x10,
	Sbitime		= 0x54494D45,	/* "TIME" */
	Sbiipi		= 0x735049,	/* "sPI" */
	Sbirfence	= 0x52464E43,	/* "RFNC" */
	Sbihsm		= 0x48534D,	/* "HSM" */
	Sbisrst		= 0x53525354,	/* "SRST" */

	/* legacy (v0.1) extensions: their own ids, no function number */
	Sbilegacytimer	= 0x00,
	Sbilegacyputc	= 0x01,

	Basespecversion	= 0,
	Baseimplid	= 1,
	Baseimplversion	= 2,
	Baseprobe	= 3,
};

static int	hastime, hasipi, hasrfence, hashsm, hassrst;
static int	probed;

vlong
sbicall(int ext, int fn, uvlong a0, uvlong a1, uvlong a2, uvlong a3, vlong *valp)
{
	register uvlong r0 __asm__("a0") = a0;
	register uvlong r1 __asm__("a1") = a1;
	register uvlong r2 __asm__("a2") = a2;
	register uvlong r3 __asm__("a3") = a3;
	register uvlong r6 __asm__("a6") = fn;
	register uvlong r7 __asm__("a7") = ext;

	__asm__ volatile("ecall"
		: "+r"(r0), "+r"(r1)
		: "r"(r2), "r"(r3), "r"(r6), "r"(r7)
		: "memory");
	if(valp != nil)
		*valp = (vlong)r1;
	return (vlong)r0;
}

int
sbiprobe(int ext)
{
	vlong v;

	if(sbicall(Sbibase, Baseprobe, ext, 0, 0, 0, &v) != 0)
		return 0;
	return v != 0;
}

static void
sbiprobeall(void)
{
	if(probed)
		return;
	probed = 1;
	hastime = sbiprobe(Sbitime);
	hasipi = sbiprobe(Sbiipi);
	hasrfence = sbiprobe(Sbirfence);
	hashsm = sbiprobe(Sbihsm);
	hassrst = sbiprobe(Sbisrst);
}

char*
sbidescribe(void)
{
	static char buf[128];
	vlong spec, impl, iv;

	sbiprobeall();
	sbicall(Sbibase, Basespecversion, 0, 0, 0, 0, &spec);
	sbicall(Sbibase, Baseimplid, 0, 0, 0, 0, &impl);
	sbicall(Sbibase, Baseimplversion, 0, 0, 0, 0, &iv);
	snprint(buf, sizeof buf, "SBI v%lld.%lld, %s %llux;%s%s%s%s%s",
		(spec >> 24) & 0x7F, spec & 0xFFFFFF,
		impl == 1 ? "OpenSBI" : "implementation", (uvlong)iv,
		hastime ? " TIME" : "", hasipi ? " IPI" : "", hasrfence ? " RFNC" : "",
		hashsm ? " HSM" : "", hassrst ? " SRST" : "");
	return buf;
}

/* the next timer interrupt for this hart, in time-CSR units */
void
sbisettimer(uvlong when)
{
	sbiprobeall();
	if(hastime)
		sbicall(Sbitime, 0, when, 0, 0, 0, nil);
	else
		sbicall(Sbilegacytimer, 0, when, 0, 0, 0, nil);
}

/* a supervisor software interrupt to each hart in the mask (bit n = hartbase+n) */
void
sbisendipi(ulong hartmask, ulong hartbase)
{
	sbiprobeall();
	if(hasipi)
		sbicall(Sbiipi, 0, hartmask, hartbase, 0, 0, nil);
}

/*
 * Every other hart executes a fence.i: the JIT wrote code that any
 * hart may run, and fence.i reaches only the hart that executes it.
 * A mask base of -1 means all harts.
 */
void
sbiremotefencei(void)
{
	sbiprobeall();
	if(hasrfence)
		sbicall(Sbirfence, 0, 0, (uvlong)-1, 0, 0, nil);
}

int
sbihartstart(ulong hartid, uintptr entry, uintptr opaque)
{
	sbiprobeall();
	if(!hashsm)
		return -1;
	return (int)sbicall(Sbihsm, 0, hartid, entry, opaque, 0, nil);
}

/*
 * A hart's HSM state: 0 started, 1 stopped, 2 start pending, 3 stop
 * pending; -1 if the firmware cannot say.
 */
int
sbihartstatus(ulong hartid)
{
	vlong v;

	sbiprobeall();
	if(!hashsm)
		return -1;
	if(sbicall(Sbihsm, 2, hartid, 0, 0, 0, &v) != 0)
		return -1;
	return (int)v;
}

/* type 0 shutdown, 1 cold reboot */
void
sbireset(int type)
{
	sbiprobeall();
	if(hassrst)
		sbicall(Sbisrst, 0, type, 0, 0, 0, nil);
}

/* the firmware's console, for when there is nothing else */
void
sbiputc(int c)
{
	sbicall(Sbilegacyputc, 0, c, 0, 0, 0, nil);
}

/*
 * The JIT's instruction-cache flush (libinterp/comp-riscv64.c): this
 * hart's fence.i, and every other hart's through the firmware. The
 * range is ignored -- fence.i is all or nothing.
 */
void
cacheiflush(void *a, ulong n)
{
	USED(a);
	USED(n);
	fencei();
	if(conf.nmach > 1)
		sbiremotefencei();
}

void
segflush(void *a, ulong n)
{
	cacheiflush(a, n);
}
