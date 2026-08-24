/*
 * QEMU virt-only declarations.
 *
 * The counterpart of os/bcm2837/board.h: hardware that exists on this
 * machine and not on the other one. Mostly that is the GIC, which is
 * the substantive difference between the two ports -- BCM2837 routes
 * its timer through a vendor block with no acknowledge cycle, and
 * everything the GIC needs beyond that lives behind these calls.
 *
 * Include after dat.h, like fns.h.
 */

/* gic.c -- GICv2 */
void	gicinit(void);
void	gicenable(int);
void	gicdisable(int);
u32int	gicack(void);
void	giceoi(u32int);
int	gicnirq(void);

/*
 * clock.c -- interrupts the GIC acknowledged that resolved to nothing.
 * Benign individually (an interrupt withdrawn between asserting and
 * being acknowledged), worth watching in aggregate.
 */
u64int	clockspurious(void);

/* mmu.c -- where RAM starts, and whether that came from the device tree */
uintptr	mmurambase(void);
int	mmuramknown(void);
