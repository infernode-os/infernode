/*
 * os/amd64/thread.h -- kernel threads and the run queue.
 *
 * A thread is a saved trap frame and a stack.  It is switched in on the
 * timer's return path: trap() hands the scheduler the interrupted frame,
 * the scheduler records it and returns another thread's.  A thread that
 * has never run has a frame built by threadcreate() instead, which looks
 * exactly like an interrupt had stopped it at its entry point.
 */

#ifndef _OS_AMD64_THREAD_H_
#define _OS_AMD64_THREAD_H_

#include <stdint.h>
#include "trap.h"

enum
{
	ThrRun	= 1,
	ThrDead,
};

typedef struct Thread Thread;
struct Thread
{
	uint64_t	sp;		/* the saved Trapframe */
	char		*name;
	uint64_t	runs;		/* times scheduled */
	int		state;
};

void	threadsinit(void);
Thread*	threadcreate(char *name, void (*entry)(void));
Trapframe* threadsched(Trapframe*);

#endif
