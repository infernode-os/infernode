/*
 * os/amd64/trap.h -- the frame an interrupt leaves, and the machine's
 * interrupt interface.
 *
 * In 64-bit mode the CPU always pushes a five-qword frame -- SS, RSP,
 * RFLAGS, CS, RIP -- even when it stays in ring 0.  A fault with an error
 * code pushes that too.  trap.S then pushes a dummy error code where the
 * CPU did not, the vector, and every general register.  The resulting
 * frame is what the C handler sees, and handing back a different frame
 * from trap() is how the scheduler switches threads: IRET restores RSP
 * from the frame, so a thread that has never run only needs the frame
 * built for it.
 */

#ifndef _OS_AMD64_TRAP_H_
#define _OS_AMD64_TRAP_H_

#include <stdint.h>

#define KCS	0x08		/* the kernel's 64-bit code selector */
#define KDS	0x10		/* the kernel's data selector */
#define HZ	100		/* the timer's frequency */

typedef struct Trapframe Trapframe;
struct Trapframe
{
	uint64_t	r15, r14, r13, r12, r11, r10, r9, r8;
	uint64_t	rbp, rdi, rsi, rdx, rcx, rbx, rax;
	uint64_t	vector, err;
	uint64_t	rip, cs, rflags, rsp, ss;
};

extern volatile uint64_t ticks;	/* timer interrupts since trapinit */

void	trapinit(void);
Trapframe* trap(Trapframe*);

static inline void
intr_enable(void)
{
	__asm__ volatile("sti" ::: "memory");
}

static inline uint64_t
intr_disable(void)
{
	uint64_t f;

	__asm__ volatile("pushfq; popq %0; cli" : "=r"(f) :: "memory");
	return f;
}

static inline void
intr_restore(uint64_t f)
{
	if(f & 0x200)
		intr_enable();
}

#endif
