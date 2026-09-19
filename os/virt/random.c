/*
 * Random numbers: hwrandom() and the three names libsec calls.
 *
 * os/port/random.c keeps the kernel's entropy pool and requires the
 * board to fill it -- randominit primes it from hwrandom() so the first
 * TCP connection does not sleep for ever waiting for a port number. On
 * the board that is the BCM2837's generator. A virtual machine has no
 * physics of its own, so the entropy comes from the host, by one of
 * two roads:
 *
 *   RNDR, the architecture's own random-number register (ARMv8.5),
 *   when the emulated CPU has one. -cpu max does; the cortex-a53 this
 *   port normally runs on, matching the board, does not.
 *
 *   virtio-rng, when QEMU was started with -device virtio-rng-device.
 *   This is the normal road. The driver is the smallest a virtio
 *   driver can be -- post a buffer the device writes into, wait, read
 *   it -- and it POLLS: hwrandom is called before interrupts are on,
 *   and from whatever context wants a key, so waiting for an interrupt
 *   is not available to it.
 *
 * With neither there is no entropy to be had, and what this file does
 * then is say so on the console in capitals and hand out a counter
 * stirred with the time, so that the machine still boots and a test
 * that does not care still runs. NOTHING CRYPTOGRAPHIC DONE ON SUCH A
 * BOOT IS WORTH ANYTHING. The harness always gives the device.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"
#include "virtio.h"

enum
{
	Rngbuf		= 64,
	Rngwaitus	= 200000,	/* how long one request may take */
};

static Lock rnglock;
static Vdev *rngdev;
static Vq *rngq;
static uchar *rngbuf;		/* what the device writes into; never the caller's */
static int hasrndr;
static int warned;

/*
 * ID_AA64ISAR0_EL1 bits 63:60 say whether RNDR exists. Reading RNDR on
 * a CPU without it is an undefined instruction, so ask first.
 */
static int
rndrprobe(void)
{
	u64int isar0;

	__asm__ volatile("mrs %0, id_aa64isar0_el1" : "=r"(isar0));
	return (isar0 >> 60) != 0;
}

/* RNDR sets the Z flag when it has nothing to give; 0 is then what it read */
static int
rndr(u64int *vp)
{
	u64int v, nzcv;

	__asm__ volatile("mrs %0, s3_3_c2_c4_0\n\tmrs %1, nzcv" : "=r"(v), "=r"(nzcv));
	*vp = v;
	return (nzcv & (1<<30)) == 0;
}

/*
 * Called from boardioprobe once the transports have been scanned.
 * Before it has run, hwrandom has nothing; nothing asks that early.
 */
void
rnginit(void)
{
	hasrndr = rndrprobe();

	rngdev = virtiofind(Vidrng, 0);
	if(rngdev != nil){
		if(virtiostart(rngdev, 0) < 0
		|| (rngq = virtioqueue(rngdev, 0, 8)) == nil){
			rngdev = nil;
		}else{
			rngbuf = xspanalloc(Rngbuf, CACHELINESZ, 0);
			if(rngbuf == nil)
				panic("rnginit: no memory");
			virtioready(rngdev);
		}
	}
	print("rng:  %s%s%s\n",
		hasrndr ? "RNDR " : "",
		rngdev != nil ? "virtio-rng" : "",
		!hasrndr && rngdev == nil ? "NO ENTROPY SOURCE" : "");
}

static int
virtiorandom(uchar *p, int n)
{
	Vbuf b;
	u32int len;
	int got, i, waited;

	got = 0;
	ilock(&rnglock);
	while(got < n){
		b.p = rngbuf;
		b.len = Rngbuf;
		b.write = 1;
		if(vqsubmit(rngq, &b, 1, nil) < 0)
			break;
		vqkick(rngq);
		len = 0;
		for(waited = 0; vqcollect(rngq, &len, nil) < 0; waited += 50){
			if(waited >= Rngwaitus){
				/*
				 * The buffer is still the device's. Leave it
				 * queued: the next call finds the queue short
				 * of one descriptor, not corrupt.
				 */
				iunlock(&rnglock);
				return got;
			}
			microdelay(50);
		}
		virtiointr(rngdev);	/* nobody takes its interrupt; keep it quiet */
		if(len > Rngbuf)
			len = Rngbuf;
		if(len == 0)
			break;
		for(i = 0; i < (int)len && got < n; i++)
			p[got++] = rngbuf[i];
		memset(rngbuf, 0, Rngbuf);
	}
	iunlock(&rnglock);
	return got;
}

int
hwrandom(uchar *p, int n)
{
	static u64int weak;
	u64int v;
	int got, i;

	got = 0;
	if(rngdev != nil)
		got = virtiorandom(p, n);
	if(got < n && hasrndr){
		while(got < n && rndr(&v))
			for(i = 0; i < 8 && got < n; i++){
				p[got++] = v & 0xFF;
				v >>= 8;
			}
	}
	if(got == n)
		return got;

	if(rngdev != nil || hasrndr)
		return got;		/* a real source that ran dry: say how much */

	/* no source at all; see the top of the file */
	if(!warned){
		warned = 1;
		uartputstr("\nrng:  NO ENTROPY SOURCE. Keys made on this boot are PREDICTABLE.\n"
			"      Start QEMU with: -device virtio-rng-device\n\n");
	}
	while(got < n){
		weak = weak*6364136223846793005ULL + clockcount() + 1442695040888963407ULL;
		p[got++] = weak >> 56;
	}
	return got;
}

/*
 * libsec's names. As on the board these read the generator directly;
 * a short read is filled with zeros there too, which is a decision
 * worth revisiting on both, in one place, when that place exists.
 */
void
genrandom(uchar *p, int n)
{
	int got;

	got = hwrandom(p, n);
	while(got < n)
		p[got++] = 0;
}

void
prng(uchar *p, int n)
{
	genrandom(p, n);
}

int
prngtry(uchar *p, int n)
{
	genrandom(p, n);
	return 0;
}
