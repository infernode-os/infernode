/*
 * os/amd64/qiotest.c -- Block queues across two processes.
 *
 * A reader blocks in qread on an empty queue; a writer qwrites 11 bytes
 * into a queue whose limit is 8, so the write itself must block until
 * the reader consumes.  Both directions of the queue's block/wakeup are
 * exercised, and a watchdog turns a lost wakeup into a reported failure
 * rather than a boot that hangs.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "console.h"
#include "port.h"

static Queue		*q;
static volatile int	done;

static void
qreader(void *a)
{
	char b[32];
	long n;

	USED(a);
	n = qread(q, b, sizeof(b));
	if(n < 0){
		print("qio: read error\n");
		conshalt();
	}
	b[n] = 0;
	print("qio: read %ld \"%s\"\n", n, b);
	if(n != 11 || memcmp(b, "hello world", 11) != 0){
		print("qiotest failed\n");
		conshalt();
	}
	print("qiotest passed\n");
	conshalt();
}

static void
qwriter(void *a)
{
	USED(a);
	if(qwrite(q, "hello world", 11) != 11){
		print("qio: write failed\n");
		conshalt();
	}
	done = 1;
}

static void
qwatch(void *a)
{
	USED(a);
	tsleep(&up->sleep, return0, nil, 1000);
	if(!done){
		print("qiotest failed: lost wakeup\n");
		conshalt();
	}
}

void
qiotest(void)
{
	if(portprocinit() < 0){
		consprint("qiotest: no memory above the kernel\n");
		return;
	}
	q = qopen(8, 0, nil, nil);
	if(q == nil){
		consprint("qiotest: no queue\n");
		return;
	}
	kproc("qread", qreader, nil, 0);
	kproc("qwrite", qwriter, nil, 0);
	kproc("qwatch", qwatch, nil, 0);
	schedinit();
}
