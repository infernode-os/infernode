#include "lib9.h"
#include "draw.h"

Image*
allocimagemix(Display *d, ulong color1, ulong color3)
{
	Image *t, *b, *qmask;

	/*
	 * The mask was a static, allocated on the first Display ever to
	 * ask and used with every Display after it. With one screen for
	 * the life of the machine that was a cache; with displays that come
	 * and go -- a remote /dev/draw per cpu(1) session -- it outlives the
	 * display it belongs to and is drawn with on another. It is one
	 * pixel; make it where it is used.
	 */
	if(d->depth <= 8){	/* create a 2×2 texture */
		t = allocimage(d, Rect(0,0,1,1), d->chan, 0, color1);
		if(t == nil)
			return nil;

		b = allocimage(d, Rect(0,0,2,2), d->chan, 1, color3);
		if(b == nil){
			freeimage(t);
			return nil;
		}

		draw(b, Rect(0,0,1,1), t, nil, ZP);
		freeimage(t);
		return b;
	}else{	/* use a solid color, blended using alpha */
		t = allocimage(d, Rect(0,0,1,1), d->chan, 1, color1);
		if(t == nil)
			return nil;

		b = allocimage(d, Rect(0,0,1,1), d->chan, 1, color3);
		if(b == nil){
			freeimage(t);
			return nil;
		}

		qmask = allocimage(d, Rect(0,0,1,1), GREY8, 1, 0x3F3F3FFF);
		if(qmask == nil){
			freeimage(t);
			freeimage(b);
			return nil;
		}
		draw(b, b->r, t, qmask, ZP);
		freeimage(qmask);
		freeimage(t);
		return b;
	}
}
