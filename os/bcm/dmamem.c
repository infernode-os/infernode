/*
 * Memory a device can reach.
 *
 * On a BCM2837 that is all of it: a Raspberry Pi 3 has a gigabyte, the
 * DMA masters address a gigabyte, and a driver may hand any physical
 * address to any of them. The drivers in this directory were written
 * there and do exactly that.
 *
 * A BCM2711 has up to eight gigabytes and DMA masters that have not
 * grown to match. The legacy peripherals -- the DMA engine, the DWC2 USB
 * controller, the VideoCore's mailbox -- see memory through a window
 * onto the FIRST gigabyte only (in Linux's bcm2711.dtsi, the soc bus's
 * dma-ranges). An address above it handed to one of them is not
 * refused: the device truncates or aliases it and reads or writes
 * somewhere else, and the first anybody knows is whatever that
 * somewhere else belonged to.
 *
 * QEMU DOES NOT MODEL THE LIMIT. Its raspi4b lets every master reach
 * all of memory, so a kernel that ignored this would pass every check
 * under emulation and corrupt memory on a 4GB board. That is why the
 * first Pi 4 kernel used the first gigabyte only, and why lifting that
 * had to wait for this file.
 *
 * Two things make it safe to use the rest.
 *
 * busaddr() is the ONLY way an address reaches a device. Every driver
 * here already converted through the BUSADDR macro, because the
 * VideoCore wants its bus alias; the macro is this function now, and it
 * PANICS if the address is beyond DMATOP (the board's mem.h). So the
 * limit QEMU lacks is enforced in software, under emulation as on the
 * board, and a driver that would have scribbled on a 4GB Pi stops with
 * its own name in the message on the first boot of any machine with
 * memory above the line -- which QEMU's 2GB raspi4b is.
 *
 * dmaalloc() is where a driver gets memory that will pass. At boot,
 * while the low bank is the only memory xalloc has, an arena is taken
 * from it; only then is the memory above the line added. xalloc gives
 * out the lowest address that fits, so without that reservation the
 * first gigabyte would simply be the first to fill. On a board with
 * nothing above the line there is no arena and no reservation:
 * dmaalloc is xspanalloc, and nothing about a Pi 3 changes.
 *
 * A driver that does DMA on a buffer it was GIVEN cannot choose where
 * it lives, and has to bounce: usbdwc.c's chanio is the one here.
 */

#include "u.h"
#include "../port/lib.h"
#include "mem.h"
#include "dat.h"
#include "io.h"
#include "fns.h"
#include "board.h"

enum
{
	/*
	 * What is wanted of it today is small -- the audio ring's 32KB,
	 * eight USB bounce buffers -- and what is coming is not: an xHCI
	 * controller's rings and a gigabit MAC's. Thirty-two megabytes of
	 * a board that has at least two thousand.
	 */
	Arenasize	= 32*1024*1024,
	Minalign	= CACHELINESZ,
};

typedef struct Dfree Dfree;
struct Dfree
{
	Dfree	*next;
	ulong	size;
};

static struct
{
	Lock	l;
	uchar	*base;
	uchar	*end;
	Dfree	*free;		/* address order, coalesced */
	ulong	inuse;
	ulong	nalloc;
} arena;

uintptr
busaddr(uintptr pa)
{
	if(pa >= DMATOP){
		uartputstr("\nbusaddr: ");
		uartputx(pa);
		uartputstr(" is beyond what this SoC's DMA masters can reach (");
		uartputx(DMATOP);
		uartputstr(").\n  The buffer has to come from dmaalloc(), or be bounced through one that did.\n");
		panic("busaddr: %#p beyond the DMA limit %#p (called from %#p)",
			pa, (uintptr)DMATOP, getcallerpc(&pa));
	}
	return (pa & ~0xC0000000UL) | 0xC0000000UL;
}

/*
 * Called from boardioprobe, after xinit and before anything else has
 * had the chance to allocate much: reserve the arena, THEN tell xalloc
 * about the memory above the line. In that order, or not at all.
 */
void
dmainit(void)
{
	uintptr hightop;

	hightop = mmuhightop();
	if(hightop <= DMATOP){
		print("mem:  every address is within the DMA masters' reach; no arena\n");
		return;
	}

	arena.base = xspanalloc(Arenasize, BY2PG, 0);
	if(arena.base == nil || PADDR(arena.base) + Arenasize > DMATOP)
		panic("dmainit: no %dMB below %#p for a DMA arena", Arenasize>>20, (uintptr)DMATOP);
	arena.end = arena.base + Arenasize;
	arena.free = (Dfree*)arena.base;
	arena.free->next = nil;
	arena.free->size = Arenasize;

	xhole(DMATOP, hightop - DMATOP);
	conf.npage += (hightop - DMATOP) / BY2PG;

	/*
	 * And from now on the kernel's own memory comes from up there
	 * first (../port/xalloc.c): what is below the line is the scarce
	 * kind, and under QEMU this is also what makes busaddr()'s check
	 * worth having -- a Block that really is above the line is one
	 * that really has to be bounced.
	 */
	xallocpref = DMATOP;

	print("mem:  %lludMB above the DMA limit at %#p added; %dMB arena below it at %#p for devices\n",
		(uvlong)(hightop - DMATOP) >> 20, (uintptr)DMATOP, Arenasize>>20, arena.base);
}

/*
 * First fit, address ordered, coalescing on free. Allocations here are
 * few and long-lived -- rings and bounce buffers, made once -- so this
 * is as simple as an allocator can be and still give memory back.
 * Every block is a multiple of Minalign and begins on one, which is
 * also what keeps a device's cache maintenance from touching its
 * neighbour.
 */
void*
dmaalloc(ulong size, int align)
{
	Dfree *f, **l, *rest;
	uchar *p;
	ulong pad;

	if(size == 0)
		return nil;
	if(align < Minalign)
		align = Minalign;
	size = ROUND(size, Minalign);

	if(arena.base == nil){
		p = xspanalloc(size, align, 0);
		if(p != nil)
			memset(p, 0, size);
		return p;
	}

	ilock(&arena.l);
	for(l = &arena.free; (f = *l) != nil; l = &f->next){
		pad = (ulong)(-(uintptr)f & (uintptr)(align-1));
		if(f->size < pad + size)
			continue;
		if(pad != 0){
			/* keep the front as a free block of its own */
			rest = (Dfree*)((uchar*)f + pad);
			rest->next = f->next;
			rest->size = f->size - pad;
			f->next = rest;
			f->size = pad;
			l = &f->next;
			f = rest;
		}
		if(f->size > size){
			rest = (Dfree*)((uchar*)f + size);
			rest->next = f->next;
			rest->size = f->size - size;
			*l = rest;
		}else
			*l = f->next;
		arena.inuse += size;
		arena.nalloc++;
		iunlock(&arena.l);
		memset(f, 0, size);
		return f;
	}
	iunlock(&arena.l);
	print("dmaalloc: no %lud bytes left in the DMA arena (%lud in use)\n", size, arena.inuse);
	return nil;
}

void
dmafree(void *v, ulong size)
{
	Dfree *f, *n, **l;

	if(v == nil)
		return;
	if(arena.base == nil)
		return;		/* xspanalloc's memory is for ever; so were these */
	size = ROUND(size, Minalign);
	if((uchar*)v < arena.base || (uchar*)v + size > arena.end)
		panic("dmafree: %#p is not the arena's", v);

	n = v;
	n->size = size;
	ilock(&arena.l);
	for(l = &arena.free; (f = *l) != nil && f < n; l = &f->next)
		;
	n->next = f;
	*l = n;
	if(f != nil && (uchar*)n + n->size == (uchar*)f){
		n->size += f->size;
		n->next = f->next;
	}
	/* and with the one before, which l still points into */
	if(l != &arena.free){
		f = (Dfree*)((uchar*)l - offsetof(Dfree, next));
		if((uchar*)f + f->size == (uchar*)n){
			f->size += n->size;
			f->next = n->next;
		}
	}
	arena.inuse -= size;
	iunlock(&arena.l);
}

int
dmareachable(void *v, ulong len)
{
	return PADDR(v) + len <= DMATOP;
}
