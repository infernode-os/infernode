/*
 * Exception frame, AArch64.
 *
 * Laid out so the assembler in vectors.S can save and restore it with
 * stp/ldp pairs throughout: x0..x29 occupy fifteen pairs, then x30 with
 * the interrupted stack pointer, then the exception syndrome registers.
 * Keep UREGSIZE and the field order in step with vectors.S -- the two
 * are one data structure written twice, and nothing checks that for us.
 */

#define UREGSIZE	304

#ifndef __ASSEMBLER__

typedef struct Ureg Ureg;

struct Ureg
{
	u64int	r[31];		/* x0..x30 */
	u64int	sp;		/* stack pointer before the exception */
	u64int	pc;		/* ELR_ELx: where it faulted */
	u64int	psr;		/* SPSR_ELx */
	u64int	esr;		/* ESR_EL1: exception syndrome */
	u64int	far;		/* FAR_EL1: faulting address */
	u64int	type;		/* which vector-table slot fired */
	u64int	pad;
};

/* vector slots, matching the order of the table in vectors.S */
enum
{
	Tsync0,	Tirq0,	Tfiq0,	Terr0,		/* current EL, SP_EL0 */
	Tsync,	Tirq,	Tfiq,	Terr,		/* current EL, SP_ELx */
	Tsync64, Tirq64, Tfiq64, Terr64,	/* lower EL, AArch64 */
	Tsync32, Tirq32, Tfiq32, Terr32,	/* lower EL, AArch32 */
};

#endif
