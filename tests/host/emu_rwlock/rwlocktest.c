/*
 * emu/port/lock.c (the emulator's Lock, QLock and RWlock) on the host,
 * built by tests/host/emu_rwlock_test.sh, under real concurrency. Each
 * thread is a Proc with a semaphore of its own, as emu's kprocs are:
 * osblock() waits on it and osready() posts it (emu/Linux/os-clone.c,
 * emu/port/kproc-pthreads.c), so qlock really blocks. _tas, osyield and
 * osmillisleep are the host's. The structs are the platform lib9.h's
 * own, extracted by the script, and the code is lock.c itself.
 *
 *   readers	threads taking the lock with canrlock while others take
 *		it with rlock (passing through x): with no writer anywhere,
 *		canrlock must never fail. It used to, at random, and
 *		devcons's kernel print then went to the console rather
 *		than /dev/kprint.
 *   mixed	readers (rlock and canrlock) and writers at once: a writer
 *		is alone, readers see no writer inside, both sides make
 *		progress, and the lock ends idle.
 *   punt	a writer holding the lock, and one waiting for it behind
 *		readers: canrlock refuses in both, and takes it again once
 *		the writers are gone.
 */
#include <pthread.h>
#include <semaphore.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define nil ((void*)0)

typedef unsigned long ulong;
typedef struct Proc Proc;

struct Proc
{
	Proc	*qnext;
	int	nlocks;
	sem_t	sem;
};

#include "structs.h"	/* Lock, QLock, RWLock from the platform's lib9.h */
typedef struct RWLock RWlock;	/* as emu/port/dat.h */

static __thread Proc *thisproc;
#define up thisproc

static int _tas(int *v){ return __atomic_exchange_n(v, 1, __ATOMIC_ACQUIRE); }
static void osyield(void){ sched_yield(); }
static int osmillisleep(ulong ms){ usleep(ms*1000); return 0; }
static void osblock(void){ while(sem_wait(&up->sem) != 0) ; }
static void osready(Proc *p){ sem_post(&p->sem); }

/* emu/port/lock.c, its includes stripped by the script */
#include "lock_body.c"

static RWlock rw;
static volatile int inwrite, inread;
static volatile int stop, wdone;
static long canfail, canok, writes, badexcl;
static int iters = 200000;

static void
procinit(void)
{
	thisproc = calloc(1, sizeof(Proc));
	sem_init(&thisproc->sem, 0, 0);
}

static void*
canreader(void *a)
{
	int i;

	procinit();
	for(i = 0; i < iters || !wdone; i++){	/* past the writers, so some succeed */
		if(canrlock(&rw)){
			__atomic_add_fetch(&inread, 1, __ATOMIC_SEQ_CST);
			if(inwrite)
				__atomic_add_fetch(&badexcl, 1, __ATOMIC_SEQ_CST);
			__atomic_sub_fetch(&inread, 1, __ATOMIC_SEQ_CST);
			runlock(&rw);
			__atomic_add_fetch(&canok, 1, __ATOMIC_RELAXED);
		}else
			__atomic_add_fetch(&canfail, 1, __ATOMIC_RELAXED);
	}
	return a;
}

static void*
blockreader(void *a)
{
	procinit();
	while(!stop){
		rlock(&rw);
		__atomic_add_fetch(&inread, 1, __ATOMIC_SEQ_CST);
		if(inwrite)
			__atomic_add_fetch(&badexcl, 1, __ATOMIC_SEQ_CST);
		__atomic_sub_fetch(&inread, 1, __ATOMIC_SEQ_CST);
		runlock(&rw);
	}
	return a;
}

static void*
writer(void *a)
{
	int i;

	procinit();
	for(i = 0; i < iters/50; i++){
		wlock(&rw);
		if(__atomic_add_fetch(&inwrite, 1, __ATOMIC_SEQ_CST) != 1 || inread)
			__atomic_add_fetch(&badexcl, 1, __ATOMIC_SEQ_CST);
		__atomic_sub_fetch(&inwrite, 1, __ATOMIC_SEQ_CST);
		wunlock(&rw);
		__atomic_add_fetch(&writes, 1, __ATOMIC_RELAXED);
	}
	return a;
}

static void
run(int ncan, int nblock, int nwrite)
{
	pthread_t t[64];
	int i, n;

	memset(&rw, 0, sizeof rw);
	stop = 0;
	wdone = nwrite == 0;
	canfail = canok = writes = badexcl = 0;
	n = 0;
	for(i = 0; i < nblock; i++)
		pthread_create(&t[n++], nil, blockreader, nil);
	for(i = 0; i < nwrite; i++)
		pthread_create(&t[n++], nil, writer, nil);
	for(i = 0; i < ncan; i++)
		pthread_create(&t[n++], nil, canreader, nil);
	for(i = nblock; i < nblock+nwrite; i++)
		pthread_join(t[i], nil);
	wdone = 1;
	for(; i < n; i++)
		pthread_join(t[i], nil);
	stop = 1;
	for(i = 0; i < nblock; i++)
		pthread_join(t[i], nil);
}

static void*
waitwriter(void *a)
{
	procinit();
	wlock(&rw);
	wunlock(&rw);
	return a;
}

static int
idle(void)
{
	return rw.readers == 0 && rw.writers == 0 && !rw.x.locked && !rw.k.locked;
}

/* the states a writer makes, one at a time */
static int
punt(void)
{
	pthread_t t;
	int fails, i;

	fails = 0;
	memset(&rw, 0, sizeof rw);

	wlock(&rw);
	if(canrlock(&rw)){
		printf("FAIL: canrlock took the lock from a writer holding it\n");
		runlock(&rw);
		fails++;
	}
	wunlock(&rw);

	rlock(&rw);
	pthread_create(&t, nil, waitwriter, nil);
	for(i = 0; i < 5000 && __atomic_load_n(&rw.writers, __ATOMIC_SEQ_CST) == 0; i++)
		usleep(1000);
	usleep(10000);		/* let it reach qlock(&k) */
	if(rw.writers != 1){
		printf("FAIL: a waiting writer is not counted (writers %d)\n", rw.writers);
		fails++;
	}
	if(canrlock(&rw)){
		printf("FAIL: canrlock took the lock ahead of a waiting writer\n");
		runlock(&rw);
		fails++;
	}
	runlock(&rw);
	pthread_join(t, nil);

	if(!canrlock(&rw)){
		printf("FAIL: canrlock refused with the writers gone\n");
		fails++;
	}else
		runlock(&rw);
	if(!idle()){
		printf("FAIL: the lock is not idle after punt (readers %d writers %d)\n", rw.readers, rw.writers);
		fails++;
	}
	if(up->nlocks != 0){
		printf("FAIL: %d spin locks still counted held\n", up->nlocks);
		fails++;
	}
	printf("punt: %s\n", fails ? "failed" : "a holding and a waiting writer refuse canrlock, and only they");
	return fails;
}

int
main(int argc, char **argv)
{
	int fails;

	if(argc > 1)
		iters = atoi(argv[1]);
	procinit();
	fails = 0;

	run(3, 3, 0);
	printf("readers: canrlock %ld succeeded, %ld failed with no writer\n", canok, canfail);
	if(canfail != 0 || canok != 3L*iters){
		printf("FAIL: canrlock failed beside other readers\n");
		fails++;
	}

	run(3, 2, 2);
	printf("mixed: canrlock %ld succeeded, %ld punted; %ld writes; %ld exclusion faults\n",
		canok, canfail, writes, badexcl);
	if(badexcl != 0){
		printf("FAIL: a writer was not alone\n");
		fails++;
	}
	if(writes != 2L*(iters/50) || canok == 0){
		printf("FAIL: a side made no progress\n");
		fails++;
	}
	if(!idle()){
		printf("FAIL: the lock is not idle at the end (readers %d writers %d)\n", rw.readers, rw.writers);
		fails++;
	}

	fails += punt();

	printf(fails ? "%d FAILED\n" : "ALL PASS\n", fails);
	return fails != 0;
}
