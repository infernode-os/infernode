/*
 * The framebuffer: QEMU's ramfb.
 *
 * On the board a framebuffer is asked of the VideoCore through the
 * mailbox, and comes back as an address in the GPU's memory. ramfb is
 * the same idea with the roles reversed: the GUEST picks some of its
 * own memory, tells QEMU where it is and what shape, and QEMU scans it
 * out -- to a window, to VNC, or to nothing but a QMP screendump, which
 * is all a test needs.
 *
 *	-device ramfb
 *
 * It is the right display for this port because of what it is not. A
 * virtio-gpu is a command queue: every update is a transfer and a
 * flush, and the screen code would need a second shape for it. ramfb
 * is a linear array of pixels that something else reads, which is
 * precisely what screen.c and fbcons.c were written against on the
 * board -- they ask this layer for an Fbinfo and never learn what is
 * behind it.
 *
 * Telling QEMU goes through fw_cfg, the side door QEMU gives firmware:
 * a selector register, a data register, and a DMA register that takes
 * the address of a little descriptor. There is a directory of named
 * "files" behind it; ramfb's is etc/ramfb, and WRITING a 28-byte
 * configuration to that file is what turns the display on. Everything
 * on this interface is big-endian, whatever the guest is, and the
 * structures are packed; both are handled a byte at a time here rather
 * than trusted to a struct.
 *
 * The pixel format is XRGB8888, little-endian -- a 32-bit load reads
 * 0x00RRGGBB -- which is the board's format and libmemdraw's XRGB32,
 * so not one pixel is converted anywhere between a Limbo program and
 * the host's window.
 *
 * No cache maintenance and no special mapping: QEMU reads guest RAM
 * from the host side, coherent by construction. See mmu.c.
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
	/* fw_cfg, memory-mapped */
	Fwdata		= 0x00,		/* a byte at a time */
	Fwsel		= 0x08,		/* 16 bits, big-endian */
	Fwdma		= 0x10,		/* 64 bits, big-endian; the low half triggers */

	Fwsignature	= 0x0000,	/* reads "QEMU" */
	Fwfiledir	= 0x0019,

	Dmaerror	= 1<<0,
	Dmaselect	= 1<<3,
	Dmawrite	= 1<<4,

	Fourccxr24	= 0x34325258,	/* 'X','R','2','4': XRGB8888 */

	Defwidth	= 1280,
	Defheight	= 720,
};

#define FWB(r)	(*(volatile uchar*)((uintptr)FWCFGREGS + (r)))
#define FW16(r)	(*(volatile u16int*)((uintptr)FWCFGREGS + (r)))
#define FW32(r)	(*(volatile u32int*)((uintptr)FWCFGREGS + (r)))

static u16int
swab16(u16int v)
{
	return v<<8 | v>>8;
}

static u32int
swab32(u32int v)
{
	return v<<24 | (v&0xFF00)<<8 | (v>>8 & 0xFF00) | v>>24;
}

static void
put32(uchar *p, u32int v)
{
	p[0] = v>>24; p[1] = v>>16; p[2] = v>>8; p[3] = v;
}

static void
put64(uchar *p, u64int v)
{
	put32(p, v>>32);
	put32(p+4, (u32int)v);
}

static void
fwselect(int sel)
{
	FW16(Fwsel) = swab16(sel);
	coherence();
}

static u32int
fwget32(void)
{
	u32int v;
	int i;

	v = 0;
	for(i = 0; i < 4; i++)
		v = v<<8 | FWB(Fwdata);
	return v;
}

/*
 * Find a file in fw_cfg's directory; returns its selector or -1. An
 * entry is 64 bytes: size and selector big-endian, two reserved, and a
 * 56-byte name.
 */
static int
fwfind(char *name)
{
	char ent[56];
	u32int n, i;
	int j, sel;

	fwselect(Fwfiledir);
	n = fwget32();
	if(n > 512)
		return -1;
	for(i = 0; i < n; i++){
		fwget32();			/* size */
		sel = FWB(Fwdata) << 8;
		sel |= FWB(Fwdata);
		FWB(Fwdata); FWB(Fwdata);	/* reserved */
		for(j = 0; j < 56; j++)
			ent[j] = FWB(Fwdata);
		ent[55] = 0;
		if(strcmp(ent, name) == 0)
			return sel;
	}
	return -1;
}

/*
 * Write n bytes to a fw_cfg file, by DMA -- the only way QEMU accepts a
 * write. The descriptor is control, length, address; QEMU does the
 * transfer during the register write and clears control when it is
 * done, or sets the error bit.
 */
static int
fwwrite(int sel, void *buf, int n)
{
	static uchar acc[16] __attribute__((aligned(16)));
	int i;

	put32(acc, (u32int)sel<<16 | Dmaselect | Dmawrite);
	put32(acc+4, n);
	put64(acc+8, PADDR(buf));
	coherence();

	FW32(Fwdma) = swab32((u64int)PADDR(acc) >> 32);
	FW32(Fwdma+4) = swab32((u32int)PADDR(acc));
	coherence();

	for(i = 0; i < 1000; i++){
		if((acc[0]|acc[1]|acc[2]|acc[3]) == 0)
			return 0;
		if(acc[3] & Dmaerror)
			return -1;
		microdelay(10);
	}
	return -1;
}

/*
 * "fb=1024x768" on the command line (-append) picks a size; anything
 * malformed, or absurd, is the default.
 */
static void
fbsize(u32int *wp, u32int *hp)
{
	char *p;
	u32int w, h;

	*wp = Defwidth;
	*hp = Defheight;
	for(p = boardcmdline(); *p != 0; p++)
		if((p == boardcmdline() || p[-1] == ' ') && strncmp(p, "fb=", 3) == 0)
			break;
	if(*p == 0)
		return;
	p += 3;
	for(w = 0; *p >= '0' && *p <= '9'; p++)
		w = w*10 + (*p - '0');
	if(*p++ != 'x')
		return;
	for(h = 0; *p >= '0' && *p <= '9'; p++)
		h = h*10 + (*p - '0');
	if(w < 320 || w > 4096 || h < 200 || h > 4096)
		return;
	*wp = w;
	*hp = h;
}

/*
 * Make a framebuffer and point QEMU at it. -1 if this QEMU was not
 * given -device ramfb, which is not an error: a machine with no
 * display has a serial console and nothing else, like a board with no
 * monitor plugged in.
 */
int
ramfbinit(Fbinfo *fb)
{
	static uchar cfg[28] __attribute__((aligned(16)));
	u32int w, h;
	uchar *mem;
	int sel;

	fwselect(Fwsignature);
	if(fwget32() != 0x51454D55){		/* "QEMU" */
		uartputstr("fb:   no fw_cfg here\n");
		return -1;
	}
	sel = fwfind("etc/ramfb");
	if(sel < 0){
		uartputstr("fb:   no display (QEMU was not started with -device ramfb)\n");
		return -1;
	}

	fbsize(&w, &h);
	mem = xspanalloc(w*h*4, BY2PG, 0);
	if(mem == nil){
		uartputstr("fb:   no memory for a framebuffer\n");
		return -1;
	}
	memset(mem, 0, w*h*4);

	put64(cfg, PADDR(mem));
	put32(cfg+8, Fourccxr24);
	put32(cfg+12, 0);			/* flags */
	put32(cfg+16, w);
	put32(cfg+20, h);
	put32(cfg+24, w*4);			/* stride */
	if(fwwrite(sel, cfg, sizeof cfg) < 0){
		uartputstr("fb:   QEMU refused the ramfb configuration\n");
		return -1;
	}

	fb->disp = 0;
	fb->base = (uintptr)mem;
	fb->size = w*h*4;
	fb->pitch = w*4;
	fb->width = w;
	fb->height = h;
	fb->depth = 32;
	return 0;
}

/* solid fill; fbcons clears the screen with this */
void
fbfill(Fbinfo *fb, u32int colour)
{
	u32int *p, *e;

	p = (u32int*)fb->base;
	e = p + fb->size/4;
	while(p < e)
		*p++ = colour;
}

/*
 * fbcons.c's two questions. "Select a display": there is one. "Move the
 * scanout window down the buffer", which is how the Pi scrolls for free:
 * ramfb has no such window, the answer is no, and fbcons copies pixels
 * instead, as it already does for a board's second monitor.
 */
int
fbdisplay(u32int disp)
{
	return disp == 0 ? 0 : -1;
}

int
fbvoffset(u32int x, u32int y)
{
	USED(x); USED(y);
	return -1;
}
