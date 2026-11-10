/*
 * IMPORTED from upstream Inferno (inferno-os/inferno-os), os/ip/loopbackmedium.c.
 * The NOTICE at that tree's root states "The bulk of the tree is
 * covered by the permissive MIT licence"; this tree's LICENSE already
 * credits Vita Nuova's revisions.
 *
 * Being ported to 64-bit. No upstream os/ port has ever been LP64, and
 * os/ip is where that matters most quietly: the wire formats are all
 * uchar arrays so sizeof is exact and alignment is 1, but anything
 * holding an ADDRESS or a SEQUENCE NUMBER in a ulong is 32 bits of
 * meaning in a 64-bit word, and the arithmetic on those silently
 * changes answers rather than failing. See tests/host/iproute_test.sh.
 */
#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "fns.h"
#include "../port/error.h"

#include "ip.h"

enum
{
	Maxtu=	16*1024,
};

typedef struct LB LB;
struct LB
{
	Proc	*readp;
	Queue	*q;
	Fs	*f;
};

static void loopbackread(void *a);

static void
loopbackbind(Ipifc *ifc, int, char**)
{
	LB *lb;

	lb = smalloc(sizeof(*lb));
	lb->readp = (void*)-1;
	lb->f = ifc->conv->p->f;
	/*
	 *  Both directions of every loopback conversation share this queue,
	 *  ACKs included, and qpass drops what does not fit.  At 128K, under
	 *  TCP's scaled 512K windows, a Pi 4's loopback dropped 95% of what
	 *  it was given (/net/ipifc/0's errout): every bulk transfer lost
	 *  segments and their ACKs, sat at one segment of window
	 *  retransmitting what had arrived, and ran at 9-30 MB/s.  Four
	 *  windows' worth; blocks take memory only while they are queued.
	 */
	lb->q = qopen(2*1024*1024, Qmsg, nil, nil);
	ifc->arg = lb;
	ifc->mbps = 1000;

	kproc("loopbackread", loopbackread, ifc, 0);

}

static void
loopbackunbind(Ipifc *ifc)
{
	LB *lb = ifc->arg;

	/* Do not free the shared rock before the new reader publishes up. */
	while(lb->readp == (void*)-1)
		tsleep(&up->sleep, return0, 0, 300);

	if(lb->readp)
		postnote(lb->readp, 1, "unbind", 0);

	/* wait for reader to die */
	while(lb->readp != 0)
		tsleep(&up->sleep, return0, 0, 300);

	/* clean up */
	qfree(lb->q);
	free(lb);
}

static void
loopbackbwrite(Ipifc *ifc, Block *bp, int, uchar*)
{
	LB *lb;

	lb = ifc->arg;
	if(qpass(lb->q, bp) < 0)
		ifc->outerr++;
	ifc->out++;
}

static void
loopbackread(void *a)
{
	Ipifc *ifc;
	Block *bp;
	LB *lb;

	ifc = a;
	lb = ifc->arg;
	lb->readp = up;	/* hide identity under a rock for unbind */
	if(waserror()){
		lb->readp = 0;
		pexit("hangup", 1);
	}
	for(;;){
		bp = qbread(lb->q, Maxtu);
		if(bp == nil)
			continue;
		ifc->in++;
		if(!canrlock(&ifc->rwl)){
			freeb(bp);
			continue;
		}
		if(waserror()){
			runlock(&ifc->rwl);
			nexterror();
		}
		if(ifc->lifc == nil)
			freeb(bp);
		else
			ipiput4(lb->f, ifc, bp);
		runlock(&ifc->rwl);
		poperror();
	}
}

Medium loopbackmedium =
{
.hsize=		0,
.mintu=		0,
.maxtu=		Maxtu,
.maclen=	0,
.name=		"loopback",
.bind=		loopbackbind,
.unbind=	loopbackunbind,
.bwrite=	loopbackbwrite,
};

void
loopbackmediumlink(void)
{
	addipmedium(&loopbackmedium);
}
