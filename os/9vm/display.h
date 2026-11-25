/*
 * os/9vm -- the 9vm board's shared display.
 *
 * With -display-shm 9vm maps a display region into the guest at
 * 0xF8000000 and shares it, through POSIX shared memory, with a viewer on
 * the host.  The layout is the host's struct vmdisplay: two 1024x768
 * XRGB32 framebuffer slots, a state/serial handshake, and a ring of text
 * input events.  The guest draws into a free slot, marks it ready and
 * publishes the serial; a viewer claims the slot, copies it, and marks it
 * free.  Input is a ring in the other direction: a viewer writes a record
 * and advances head, the guest reads it and advances tail.
 *
 * boot.S maps the window (32 2 MiB pages from 0xF8000000) so the driver
 * can address the region directly.  Its presence is a magic number: a
 * boot without -display-shm simply does not have one.
 *
 * The host struct is the authority; display.c asserts the layout.
 */

#ifndef _OS_9VM_DISPLAY_H_
#define _OS_9VM_DISPLAY_H_

#include <stdint.h>

enum
{
	Vmdwidth	= 1024,
	Vmdheight	= 768,
	Vmdslots	= 2,
	Vmdevents	= 256,
	Vmdeventbytes	= 96,
	Vmdframebytes	= Vmdwidth * Vmdheight * 4,

	VmdFree		= 0,
	VmdWriting	= 1,
	VmdReady	= 2,
	VmdReading	= 3,

	VmdDeltaWrites	= 0x80000000,	/* written[] sentinel while copying */
};

#define VMD_MAGIC	0x56444c39U
#define VMD_VERSION	1

/* Where 9vm puts it, and how much of the guest's address space it needs. */
#define VMD_GUEST_ADDR	0xF8000000ULL
#define VMD_GUEST_SIZE	6320128ULL	/* sizeof(Vmdisplay), page rounded */

typedef struct Vmdisplay Vmdisplay;
struct Vmdisplay
{
	uint32_t	magic;
	uint32_t	version;
	uint32_t	width;
	uint32_t	height;
	uint64_t	latest_serial;
	uint32_t	latest_slot;
	uint32_t	state[Vmdslots];
	uint32_t	written[Vmdslots];
	uint64_t	slot_serial[Vmdslots];
	uint32_t	input_head;		/* the viewer writes, and advances */
	uint32_t	input_tail;		/* the guest reads, and advances */
	char		input[Vmdevents][Vmdeventbytes];
	uint32_t	pixels[Vmdslots][Vmdwidth * Vmdheight];
	uint32_t	scale;			/* percent, 100 = 1:1 */
};

/* selftest.c */
void	dispselftest(void);

#endif
