/*
 * os/port/qlock.c (the bare-metal kernel's QLock and RWlock) on the host,
 * built by tests/host/rwlock_test.sh, under real concurrency: each
 * thread is a Proc, sched() parks it on its own semaphore and ready()
 * wakes it, so qlock really blocks and the locks behave as in the
 * kernel. The structs are portdat.h's own, extracted by the script.
 *
 *   readers	threads taking the lock with canrlock while others take
 *		it with rlock (passing through x): with no writer anywhere,
 *		canrlock must never fail.  It used to, at random, and os/ip
 *		drops a packet when it does.
 *   mixed	readers (rlock and canrlock) and writers at once: a writer
 *		is alone, readers see no writer inside, canrlock fails only
 *		while a writer is counted, and the lock ends idle.
 */
#include <pthread.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

#define nil ((void*)0)

typedef unsigned long ulong;
typedef uintptr_t uintptr;
typedef struct Proc Proc;
typedef struct Lock Lock;
typedef struct QLock QLock;
typedef struct RWlock RWlock;

struct Lock { volatile int key; };
struct Proc { Proc *qnext; uintptr qpc; sem_t sem; };

#include "structs.h"	/* struct QLock, struct RWlock from os/port/portdat.h */

static __thread Proc *thisproc;
#define up thisproc
#define SETSTATE(p, s)
#define getcallerpc(x) 0

static void lock(Lock *l){ while(__atomic_exchange_n(&l->key, 1, __ATOMIC_ACQUIRE)) while(__atomic_load_n(&l->key, __ATOMIC_RELAXED)) ; }
static void unlock(Lock *l){ __atomic_store_n(&l->key, 0, __ATOMIC_RELEASE); }
static int canlock(Lock *l){ return !__atomic_exchange_n(&l->key, 1, __ATOMIC_ACQUIRE); }
static void sched(void){ while(sem_wait(&up->sem) != 0) ; }
static void ready(Proc *p){ sem_post(&p->sem); }

/* os/port/qlock.c, its includes stripped by the script */
#include "qlock_body.c"

static RWlock rw;
static volatile int inwrite, inread;
static volatile int stop;
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
	for(i = 0; i < iters; i++){
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
		if(inwrite)
			__atomic_add_fetch(&badexcl, 1, __ATOMIC_SEQ_CST);
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
		/*
		 * A pause between writes, as the kernel's writers have (an
		 * interface's lock is written on a reconfiguration, not per
		 * packet). With back-to-back writers on many cores some writer
		 * is always counted, canrlock rightly punts every time, and
		 * the progress check below failed on a 12-core host.
		 */
		nanosleep(&(struct timespec){0, 20000}, nil);
	}
	return a;
}

static int
run(int ncan, int nblock, int nwrite)
{
	pthread_t t[64];
	int i, n;

	memset(&rw, 0, sizeof rw);
	stop = 0;
	canfail = canok = writes = badexcl = 0;
	n = 0;
	for(i = 0; i < nblock; i++)
		pthread_create(&t[n++], nil, blockreader, nil);
	for(i = 0; i < nwrite; i++)
		pthread_create(&t[n++], nil, writer, nil);
	for(i = 0; i < ncan; i++)
		pthread_create(&t[n++], nil, canreader, nil);
	for(i = nblock; i < n; i++)
		pthread_join(t[i], nil);
	stop = 1;
	for(i = 0; i < nblock; i++)
		pthread_join(t[i], nil);
	return n;
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
	if(rw.readers != 0 || rw.writers != 0 || rw.x.locked || rw.k.locked){
		printf("FAIL: the lock is not idle at the end (readers %d writers %d)\n", rw.readers, rw.writers);
		fails++;
	}
	printf(fails ? "%d FAILED\n" : "ALL PASS\n", fails);
	return fails != 0;
}
