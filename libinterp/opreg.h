/*
 * For the files that hold the interpreter's ops and decoders (xec.c,
 * string.c, alt.c, dec.c): on the native kernel each op gets its VM's
 * registers as its argument, Rp, and R means *Rp.
 *
 * R on its own is one load from the core's Mach (interp.h), and in an
 * op that load is the head of a chain -- the op's first operand access
 * waits for it -- which cost the interpreter 38% on jitbench on a Pi 4
 * (#944). xec() holds the registers in a register already and passes
 * them; the JIT passes X20. So an op loads nothing to find R, which is
 * less than the global it replaces did.
 *
 * A function in these files that is not an op says RPDECL to get Rp the
 * ordinary way.
 */
#ifdef VMREGPERMACH
#undef	R
#define	R	(*Rp)
#define	RPDECL	REG *Rp = _vmreg()
#else
#define	RPDECL
#endif
