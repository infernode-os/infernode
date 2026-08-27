/*
 * The framebuffer, presented to devdraw.
 *
 * This is the whole board-specific half of having a GUI, and it is
 * small because it should be: libmemdraw does every pixel of the
 * compositing, devdraw serves /dev/draw on top of it, and the board's
 * only job is to say where the screen is and what shape it is.
 *
 * OWNERSHIP. The framebuffer console (fbcons.c) draws characters into
 * the same memory. Both cannot own it, and the resolution here is that
 * the console gives way: attaching a screen tells fbcons to stop, and
 * from then on the pixels belong to the draw device. Trying to share it
 * would mean the console scribbling text over a window system's output
 * at unpredictable moments, which is worse than losing the console --
 * and the console is not lost anyway, because the serial one is still
 * there and is where kernel messages have always gone.
 */

#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"io.h"
#include	"../port/error.h"
#include	"board.h"

#define	Image	IMAGE
#include	<draw.h>
#include	<memdraw.h>
#include	<memlayer.h>
#include	<cursor.h>
#include	"screen.h"

static Fbinfo *screenfb;

/*
 * Hand devdraw the screen.
 *
 * The pixel format is not a guess. mailbox.c asks the firmware for
 * order 0, which puts blue at the lowest address, so a little-endian
 * 32-bit load reads 0xXXRRGGBB -- and that is exactly XRGB32 in
 * memdraw's channel notation. Getting this wrong does not fail: it
 * draws, in the wrong colours.
 *
 * width is in 32-bit WORDS per scanline, not bytes, which is what
 * memdraw means by width. The framebuffer's pitch is in bytes and the
 * firmware chooses it, so it is divided rather than computed from the
 * width in pixels -- a padded scanline is normal and assuming
 * otherwise skews every row after the first.
 *
 * softscreen is 0: drawing goes straight into the framebuffer the GPU
 * scans out, so there is no second copy to flush from.
 */
uchar*
attachscreen(Rectangle *r, ulong *chan, int *d, int *width, int *softscreen)
{
	Fbinfo *fb;

	fb = boardfb();
	if(fb == nil || fb->base == 0 || fb->depth != 32)
		return nil;

	screenfb = fb;

	/*
	 * The console stops here.
	 *
	 * Done at attach rather than at boot so that a machine which
	 * never opens /dev/draw keeps its framebuffer console -- which is
	 * every machine, until something actually wants to draw.
	 */
	fbconsstop();

	r->min.x = 0;
	r->min.y = 0;
	r->max.x = fb->width;
	r->max.y = fb->height;

	*chan = XRGB32;
	*d = 32;
	*width = fb->pitch / sizeof(ulong);
	*softscreen = 0;

	return (uchar*)fb->base;
}

/*
 * Nothing to do, and it is worth saying why rather than leaving an
 * empty function.
 *
 * flushmemscreen exists for screens that are drawn into a soft buffer
 * and copied out, or that live behind a bus the CPU cannot write
 * through. Neither applies: attachscreen hands back the actual scanout
 * memory, and mmu.c maps it Normal non-cacheable, so a store is visible
 * to the GPU without any maintenance.
 */
void
flushmemscreen(Rectangle r)
{
	USED(r);
}

/*
 * No palette on a 32-bit direct-colour screen. Returning failure is the
 * honest answer -- devdraw only asks for indexed screens.
 */
void
getcolor(ulong p, ulong *pr, ulong *pg, ulong *pb)
{
	USED(p); USED(pr); USED(pg); USED(pb);
}

int
setcolor(ulong p, ulong r, ulong g, ulong b)
{
	USED(p); USED(r); USED(g); USED(b);
	return 0;
}

/*
 * Blanking is not wired to anything.
 *
 * The firmware can turn the panel's backlight off through the mailbox
 * and HDMI has its own power management, but neither is driven yet.
 * Reporting that rather than silently doing nothing keeps the idle
 * timer honest about what it achieved.
 */
/*
 * blankscreen only. blanktime and drawblankscreen belong to devdraw --
 * they are its side of the contract, not the board's, and defining them
 * here as well is a duplicate symbol.
 */
void
blankscreen(int blank)
{
	USED(blank);
}
