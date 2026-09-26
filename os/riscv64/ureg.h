/*
 * The register frame vectors.S builds on the stack for every trap.
 *
 * r[i] is xi, so r[1] is ra and r[2] is the stack pointer before the
 * trap; sp repeats it and pc is sepc, the names os/port and the trap
 * code use. UREGSIZE must match the offsets in vectors.S and keep sp
 * 16-byte aligned.
 */

#define UREGSIZE	304

#ifndef __ASSEMBLER__

typedef struct Ureg Ureg;

struct Ureg
{
	u64int	r[32];		/* x0..x31; r[0] holds nothing */
	u64int	pc;		/* sepc: where it trapped */
	u64int	status;		/* sstatus */
	u64int	cause;		/* scause: top bit set for an interrupt */
	u64int	tval;		/* stval: the faulting address or instruction */
	u64int	sp;		/* r[2] again, for code that asks by name */
	u64int	pad;
};

#endif
