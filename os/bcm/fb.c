/*
 * Framebuffer.
 *
 * Nothing here knows what kind of display it is driving.  The firmware
 * detects the panel -- HDMI, or the official 7in DSI panel over its I2C
 * probe -- brings it up, and switches the framebuffer to it.  So the
 * right move is to ASK for the current dimensions rather than hardcode
 * them: on a 7in panel that comes back 800x480, on HDMI whatever the
 * monitor negotiated.  Hardcoding is how you end up with a correct
 * framebuffer displayed at the wrong size.
 *
 * If the firmware reports nothing sensible (no display attached, which
 * is the normal case under QEMU with -display none), fall back to a
 * modest default so the rest of bring-up can still proceed.
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
	Deffbwidth	= 640,
	Deffbheight	= 480,
	Fbdepth		= 32,

	/* Linux's firmware-KMS driver's tags, and what makes a Pi 5 take a mode */
	Tagfbdisplayid	= 0x00040016,
	Tagedidblockdisplay = 0x00030023,
	Tagsettiming	= 0x00048017,
	Tagsetplane	= 0x00048015,
	Imagexrgb8888	= 44,
};

int
fbinit(Fbinfo *fb)
{
	return fbinitdisp(0, fb);
}

/*
 * Bring up one display's framebuffer.
 *
 * The size is asked for rather than chosen: the firmware has already
 * negotiated a mode with whatever is plugged in -- EDID over HDMI, the
 * panel's own timings over DSI -- and it is the only thing that knows
 * the answer. Deffbwidth is a fallback for a display that will not say.
 */
int
fbinitdisp(u32int disp, Fbinfo *fb)
{
	u32int dim[2];
	u32int w, h, sel;
#ifdef FWRTC
	int timingid = -1;
#endif

	w = Deffbwidth;
	h = Deffbheight;

	/*
	 * Select before asking. GET_DIM reports the CURRENT display, so
	 * without this every display is asked about display 0 and a
	 * second one is allocated at the first one's size.
	 *
	 * Through a COPY, and that is not a detail. mboxprop writes the
	 * firmware's response back over the buffer it is given, so
	 * passing &disp handed the reply -- 0 -- straight into the
	 * variable naming the display we wanted. Every line after it then
	 * asked for display 0: the allocation went to display 0 at the
	 * size just queried from display 1, which reallocated the panel's
	 * framebuffer at 1024x768 and left HDMI with nothing. The panel
	 * showed a buffer of the wrong shape and the monitor kept the
	 * firmware's rainbow, and it read as "the firmware refuses a
	 * second display" when in fact the second display was never
	 * requested.
	 */
	sel = disp;
	if(disp != 0)
		mboxprop(Tagfbsetdispnum, &sel, 1, 1);

	dim[0] = 0;
	dim[1] = 0;
	if(mboxprop(Tagfbgetdim, dim, 0, 2) == 0 && dim[0] != 0 && dim[1] != 0){
		w = dim[0];
		h = dim[1];
	}

#ifdef FWRTC
	/*
	 * A Pi 5's firmware reports 1920x1080 whatever is attached, and
	 * sends it, so the display's own word is taken instead: the first
	 * detailed timing in its EDID, by the tag that names a display.
	 * A bench monitor that says 1024x768 and is sent 1080p scales it
	 * past its edges. Setting the timing is Linux's firmware-KMS tag.
	 */
	{
		static u32int v[34];
		uchar *e, *d;
		int id, ha, hb, hs, hw, va, vb, vs, vw, r;
		u32int clk;

		memset(v, 0, sizeof v);
		if(mboxprop(Tagfbdisplayid, v, 1, 1) == 0){
			id = v[0];
			memset(v, 0, sizeof v);
			v[1] = id;
			if(mboxprop(Tagedidblockdisplay, v, 2, 34) == 0 && v[1] == 0){
				e = (uchar*)&v[2];
				d = e + 54;
				if(e[1] == 0xFF && (d[0] != 0 || d[1] != 0)){
					clk = (d[0] | d[1]<<8) * 10;		/* kHz */
					ha = d[2] | (d[4] & 0xF0)<<4;
					hb = d[3] | (d[4] & 0x0F)<<8;
					va = d[5] | (d[7] & 0xF0)<<4;
					vb = d[6] | (d[7] & 0x0F)<<8;
					hs = d[8] | (d[11] & 0xC0)<<2;
					hw = d[9] | (d[11] & 0x30)<<4;
					vs = d[10]>>4 | (d[11] & 0x0C)<<2;
					vw = (d[10] & 0xF) | (d[11] & 3)<<4;
					w = ha;
					h = va;
					r = d[17];
					memset(v, 0, sizeof v);
					v[0] = id;
					v[1] = clk;
					v[2] = ha | (ha+hs)<<16;
					v[3] = (ha+hs+hw) | (ha+hb)<<16;
					v[4] = (u32int)va<<16;
					v[5] = (va+vs) | (va+vs+vw)<<16;
					v[6] = va+vb;
					v[7] = clk*1000/((ha+hb)*(va+vb));
					v[8] = ((r>>1) & 1) | ((r>>2) & 1)<<1;
					r = mboxprop(Tagsettiming, v, 9, 9);
					print("fb:   display %d says %dx%d, %ud kHz: set timing %d resp %#ux\n",
						id, ha, va, clk, r, v[0]);
					if(r == 0)
						timingid = id;
				}
			}
		}
	}
#endif
	if(mboxfballoc(disp, w, h, Fbdepth, fb) < 0)
		return -1;
#ifdef FWRTC
	/*
	 * Setting the timing takes the firmware's own plane off the screen
	 * (a lit, black display), so a plane is put back on it, on this
	 * buffer: Linux's firmware-KMS set-plane tag, one layer, no scaling.
	 */
	if(timingid >= 0){
		static u32int v[15];
		int r;

		memset(v, 0, sizeof v);
		v[0] = timingid | Imagexrgb8888<<16;	/* plane 0, layer 0 */
		v[1] = fb->width | fb->height<<16;
		v[2] = fb->pitch;
		v[5] = fb->width<<16;
		v[6] = fb->height<<16;
		v[8] = fb->width | fb->height<<16;
		v[9] = 255 | 1<<8;				/* opaque, one plane */
		v[10] = fb->base | 0xC0000000;
		r = mboxprop(Tagsetplane, v, 15, 15);
		print("fb:   plane on %#ux at %dx%d: %d resp %#ux\n", fb->base, fb->width, fb->height, r, v[0]);
	}
#endif
#ifdef FWRTC
	/*
	 * Whether it gave what was asked: a Pi 5's firmware answers a 32-bit
	 * request with 16 unless config.txt says framebuffer_depth=32, and
	 * says nothing. A screen of the wrong depth is garbage, not an error.
	 */
	if(fb->pitch < fb->width*Fbdepth/8){
		print("fb:   the firmware gave pitch %d for width %d at depth %d: set framebuffer_depth=32 in config.txt\n",
			fb->pitch, fb->width, Fbdepth);
		return -1;
	}
#endif

	/*
	 * Record the display we ASKED for, not the one echoed back.
	 *
	 * The set-display tag does not report reliably here: the board
	 * allocates a 1024x768 buffer at a fresh address when asked for
	 * display 1 -- which is HDMI's negotiated mode and plainly not
	 * the 800x480 panel -- and still answers 0. Believing the echo
	 * meant the second screen was recorded as display 0, so every
	 * later tag meant for it, the scroll offset above all, was
	 * addressed to the first.
	 *
	 * The evidence that the request was honoured is the allocation
	 * itself: a different size at a different base. board.c checks
	 * that, which is a fact about what we got rather than a claim
	 * about what the firmware meant.
	 */
	fb->disp = disp;

	return 0;
}

void
fbfill(Fbinfo *fb, u32int colour)
{
	volatile u32int *p;
	u32int x, y, stride;

	stride = fb->pitch / 4;
	p = (volatile u32int*)fb->base;

	for(y = 0; y < fb->height; y++)
		for(x = 0; x < fb->width; x++)
			p[y*stride + x] = colour;
}

void
fbrect(Fbinfo *fb, int x0, int y0, int w, int h, u32int colour)
{
	volatile u32int *p;
	int x, y, stride;

	stride = (int)(fb->pitch / 4);
	p = (volatile u32int*)fb->base;

	for(y = y0; y < y0 + h; y++){
		if(y < 0 || y >= (int)fb->height)
			continue;
		for(x = x0; x < x0 + w; x++){
			if(x < 0 || x >= (int)fb->width)
				continue;
			p[y*stride + x] = colour;
		}
	}
}

/*
 * What ../fb/fbcons.c asks of whatever is under it, besides an
 * Fbinfo and fbfill: which display the next call is about, and whether
 * the scanout window can be moved down the buffer (which is how this
 * board scrolls without copying a pixel). Here both are mailbox tags.
 * They have names of their own because fbcons serves a second board
 * (os/virt) that has no mailbox; there the answers are "there is one
 * display" and "no".
 */
int
fbdisplay(u32int disp)
{
	return mboxfbdispnum(disp);
}

int
fbvoffset(u32int x, u32int y)
{
	return mboxfbvoff(x, y);
}
