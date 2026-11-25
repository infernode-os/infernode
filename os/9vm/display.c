/*
 * display.c -- the 9vm shared display, and its boot test.
 *
 * The guest has no framebuffer hardware here: the "screen" is a region of
 * shared memory.  Two full frames alternate so a viewer can always copy a
 * complete one; the state machine is Free -> Ready (guest) and
 * Ready -> Reading -> Free (viewer), with a serial so a viewer can tell a
 * newer frame from one it has already shown.
 *
 * This stage draws two deterministic frames and waits for one input
 * record.  The host test (tests/host/vmdisplay_check.c) opens the same
 * shared memory, verifies both frames pixel by pixel, and sends the
 * input.  A real framebuffer console arrives with os/port; this is what
 * proves the transport until then.
 */

#include <stddef.h>
#include <string.h>
#include "board.h"
#include "display.h"

#define DISPSPINS	200000000u	/* a bounded wait for the host's input */

/* The host's struct vmdisplay is the authority. */
_Static_assert(offsetof(Vmdisplay, latest_serial) == 16, "latest_serial");
_Static_assert(offsetof(Vmdisplay, slot_serial) == 48, "slot_serial");
_Static_assert(offsetof(Vmdisplay, input) == 72, "input");
_Static_assert(offsetof(Vmdisplay, pixels) == 24648, "pixels");
_Static_assert(offsetof(Vmdisplay, scale) == 24648 +
	Vmdslots * Vmdframebytes, "scale");
_Static_assert(sizeof(Vmdisplay) == 24648 +
	Vmdslots * Vmdframebytes + 8, "size");	/* padded to 8 */

/*
 * The test frame.  Red runs left to right, green top to bottom, blue is a
 * cheap checker of x^y, so a frame copied into the wrong slot, at the
 * wrong stride or partly unwritten fails verification.  Frame two adds a
 * magenta block in the corner, so the two slots are distinguishable.
 */
static uint32_t
testpixel(int x, int y, int frame)
{
	uint32_t p;

	if(frame == 2 && x < 64 && y < 64)
		return 0x00FF00FF;
	p = (uint32_t)(x * 255 / (Vmdwidth - 1)) << 16;
	p |= (uint32_t)(y * 255 / (Vmdheight - 1)) << 8;
	p |= (uint32_t)((x ^ y) & 0xFF);
	return p;
}

static void
drawframe(Vmdisplay *d, int slot, int frame)
{
	uint32_t *p;
	int x, y;

	p = d->pixels[slot];
	for(y = 0; y < (int)Vmdheight; y++)
		for(x = 0; x < (int)Vmdwidth; x++)
			*p++ = testpixel(x, y, frame);
}

/* Publishes a drawn slot.  The release store makes the pixels visible. */
static void
publish(Vmdisplay *d, int slot, int frame)
{
	d->written[slot] = Vmdframebytes;
	d->slot_serial[slot] = (uint64_t)frame;
	__atomic_store_n(&d->state[slot], VmdReady, __ATOMIC_RELEASE);
	d->latest_slot = slot;
	__atomic_store_n(&d->latest_serial, (uint64_t)frame, __ATOMIC_RELEASE);
}

/* Takes one input record; 0 when the ring is empty. */
static int
takeinput(Vmdisplay *d, char *buf, int n)
{
	uint32_t head, tail;
	char *e;
	int i;

	tail = __atomic_load_n(&d->input_tail, __ATOMIC_RELAXED);
	head = __atomic_load_n(&d->input_head, __ATOMIC_ACQUIRE);
	if(tail == head || n < 1)
		return 0;
	e = d->input[tail % Vmdevents];
	for(i = 0; i < (int)Vmdeventbytes - 1 && i < n - 1 && e[i] != 0; i++)
		buf[i] = e[i];
	buf[i] = 0;
	__atomic_store_n(&d->input_tail, tail + 1, __ATOMIC_RELEASE);
	return 1;
}

void
dispselftest(void)
{
	Vmdisplay *d;
	char ev[Vmdeventbytes];
	uint32_t spins, len;
	int frame, slot;

	d = (Vmdisplay*)(uintptr_t)VMD_GUEST_ADDR;
	if(__atomic_load_n(&d->magic, __ATOMIC_ACQUIRE) != VMD_MAGIC ||
	   d->version != VMD_VERSION || d->width != Vmdwidth ||
	   d->height != Vmdheight){
		consprint("infernode/9vm: display: not offered\n");
		consprint("infernode/9vm: display test failed\n");
		return;
	}
	consprint("infernode/9vm: display ");
	consprintdec(d->width);
	consprint("x");
	consprintdec(d->height);
	consprint(" XRGB32 at ");
	consprinthex((uint64_t)(uintptr_t)d);
	consprint("\n");

	d->state[0] = VmdFree;
	d->state[1] = VmdFree;
	d->scale = 100;

	for(frame = 1; frame <= 2; frame++){
		slot = frame - 1;
		drawframe(d, slot, frame);
		publish(d, slot, frame);
	}
	consprint("infernode/9vm: display: 2 frames, serial ");
	consprintdec(d->latest_serial);
	consprint("\n");

	consprint("infernode/9vm: display: waiting for input\n");
	for(spins = 0; spins < DISPSPINS; spins++){
		if(takeinput(d, ev, sizeof(ev)))
			break;
		__asm__ volatile("pause");
	}
	if(spins == DISPSPINS){
		consprint("infernode/9vm: display test failed: no input\n");
		return;
	}
	len = strlen(ev);
	if(len > 0 && ev[len-1] == '\n')
		ev[len-1] = 0;
	consprint("infernode/9vm: display input: ");
	consprint(ev);
	consprint("\n");
	consprint("infernode/9vm: display test passed\n");
}
