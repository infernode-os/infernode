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

enum
{
	Deffbwidth	= 640,
	Deffbheight	= 480,
	Fbdepth		= 32,
};

int
fbinit(Fbinfo *fb)
{
	u32int dim[2];
	u32int w, h;

	w = Deffbwidth;
	h = Deffbheight;

	dim[0] = 0;
	dim[1] = 0;
	if(mboxprop(Tagfbgetdim, dim, 0, 2) == 0 && dim[0] != 0 && dim[1] != 0){
		w = dim[0];
		h = dim[1];
	}

	if(mboxfballoc(w, h, Fbdepth, fb) < 0)
		return -1;

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
