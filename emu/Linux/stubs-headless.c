/* Headless emulator stubs for graphics functions */
#include "dat.h"
#include "fns.h"
#include "draw.h"
#include "memdraw.h"
#include "cursor.h"

/* Graphics stubs - do nothing in headless mode */
void setpointer(int x, int y) {
	USED(x);
	USED(y);
}

void setsoftkbd(int on) {
	USED(on);
}

void setsoftkbd_rect(int x, int y, int w, int h) {
	USED(x); USED(y); USED(w); USED(h);
}

/*
 * Memory-backed screen for the headless build.
 *
 * Returning nil here makes /dev/draw/new fail, so no Draw-based code
 * (Tk, the window manager, any widget app) can run without a host
 * display.  Instead we hand devdraw an in-memory framebuffer: drawing
 * happens entirely in software (softscreen=1, so devdraw keeps its own
 * memimage and only "flushes" to this buffer — which we discard).  The
 * pixels are still readable through the Draw API (Display.writeimage),
 * which is what lets the offscreen UI test harness snapshot rendered
 * windows on a headless machine / in CI.
 */
static uchar *headless_screen;

uchar* attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen) {
	int w, h;
	ulong nbytes;

	w = Xsize;
	h = Ysize;
	if(w < 64)
		w = 1024;
	if(h < 48)
		h = 768;

	*r = Rect(0, 0, w, h);
	*chan = XRGB32;
	*d = 32;
	*width = wordsperline(*r, *d);
	*softscreen = 1;

	nbytes = (ulong)*width * sizeof(ulong) * h;
	if(headless_screen == nil)
		headless_screen = malloc(nbytes);
	if(headless_screen == nil)
		return nil;
	memset(headless_screen, 0xFF, nbytes);
	return headless_screen;
}

void flushmemscreen(Rectangle r) {
	/* software screen: nothing to blit to (no host display) */
	USED(r.min.x);
}

void drawcursor(Drawcursor *c) {
	USED(c);
}

char* clipread(void) {
	return nil;
}

int clipwrite(char *buf) {
	USED(buf);
	return 0;
}
