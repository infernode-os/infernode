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

extern Cursor arrow;			/* Inferno's own, defined below */
void	setcursor(Cursor*);

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

	/*
	 * Give the screen a pointer the moment it becomes a screen.
	 * Waiting for a program to set one means waiting for ever.
	 */
	setcursor(&arrow);

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

/*
 * The cursor.
 *
 * There is no hardware cursor on this SoC's scanout path, so this is a
 * software one: the pixels under it are saved, the cursor is painted
 * over them, and they are put back before anything else touches that
 * part of the screen. Without it the pointer is invisible and the
 * machine is unusable with a mouse even though the mouse works
 * perfectly -- which is exactly how it presented.
 *
 * The shape arrives through drawcursor(), which is the interface
 * include/cursor.h declares and every emu graphics backend implements.
 * Its format is not obvious and is taken from emu/MacOSX/win.c rather
 * than guessed at:
 *
 *	the bounds cover BOTH masks, stacked, so the real height is
 *	(maxy - miny) / 2;
 *	bpl is bytesperline at ONE bit per pixel;
 *	data holds the CLEAR mask for h rows, then the SET mask for h;
 *	a pixel is opaque where clr|set, black where set, white where
 *	clr and not set;
 *	hotx and hoty are NEGATIVE offsets from the pointer to the
 *	top-left of the shape.
 */

enum {
	Dumpcols = 100,			/* the console dump's shape */
	Dumprows = 40,
	Curswid = 32,			/* the most this will render */
	Curshgt = 32,
};

static struct {
	Lock	l;
	int	loaded;			/* a shape has been given */
	int	shown;			/* it is currently on the screen */
	int	w, h;			/* of the shape */
	int	hotx, hoty;
	uchar	clr[Curswid/8 * Curshgt];
	uchar	set[Curswid/8 * Curshgt];
	Point	pos;			/* where the pointer is */
	Point	at;			/* where the saved pixels came from */
	int	sw, sh;			/* how much was saved */
	u32int	save[Curswid * Curshgt];
} swc;

/*
 * Put back what the cursor is covering. Must be called with swc.l held.
 */
static void
swcursoff(void)
{
	u32int *fb;
	int x, y, stride;

	if(!swc.shown || screenfb == nil)
		return;
	stride = screenfb->pitch / sizeof(u32int);
	fb = (u32int*)screenfb->base;
	for(y = 0; y < swc.sh; y++)
		for(x = 0; x < swc.sw; x++)
			fb[(swc.at.y + y) * stride + swc.at.x + x] =
				swc.save[y * Curswid + x];
	swc.shown = 0;
}

/*
 * Save what is there and paint the cursor. Must be called with swc.l
 * held.
 */
static void
swcurson(void)
{
	u32int *fb;
	int x, y, stride, bpl, bit, byte;
	Point p;

	if(swc.shown || !swc.loaded || screenfb == nil)
		return;

	p.x = swc.pos.x + swc.hotx;
	p.y = swc.pos.y + swc.hoty;

	/*
	 * Clip to the screen. A cursor near an edge is drawn in part
	 * rather than not at all, and -- more to the point -- a cursor
	 * PAST an edge must not write outside the framebuffer.
	 */
	if(p.x < 0) p.x = 0;
	if(p.y < 0) p.y = 0;
	swc.sw = swc.w;
	swc.sh = swc.h;
	if(p.x + swc.sw > (int)screenfb->width)
		swc.sw = (int)screenfb->width - p.x;
	if(p.y + swc.sh > (int)screenfb->height)
		swc.sh = (int)screenfb->height - p.y;
	if(swc.sw <= 0 || swc.sh <= 0)
		return;

	stride = screenfb->pitch / sizeof(u32int);
	fb = (u32int*)screenfb->base;
	bpl = (swc.w + 7) / 8;

	for(y = 0; y < swc.sh; y++){
		for(x = 0; x < swc.sw; x++){
			swc.save[y * Curswid + x] =
				fb[(p.y + y) * stride + p.x + x];
			byte = y * bpl + (x >> 3);
			bit = 0x80 >> (x & 7);
			if(swc.set[byte] & bit)
				fb[(p.y + y) * stride + p.x + x] = 0x00000000;
			else if(swc.clr[byte] & bit)
				fb[(p.y + y) * stride + p.x + x] = 0x00FFFFFF;
		}
	}
	swc.at = p;
	swc.shown = 1;
}

void
flushmemscreen(Rectangle r)
{
	u32int *fb;
	int x, y, px, py, stride;

	/*
	 * NOT a no-op, and the reason is the software cursor.
	 *
	 * attachscreen hands back the real scanout memory, so drawing
	 * goes straight to the panel and nothing needs copying out --
	 * which is why this was empty. But the cursor is painted INTO
	 * that same memory and keeps the pixels it covered in swc.save,
	 * so anything drawn under a displayed cursor makes that save
	 * stale. The next time the cursor moves it puts the stale pixels
	 * back, painting old content over new: rectangles of whatever was
	 * there before, appearing and disappearing as the mouse moves.
	 *
	 * That is the "glitchy drawing" and the ghosting, and it is why
	 * the same wm and wmclient code is clean inside Lucifer on the
	 * hosted emulator -- there the host draws the pointer and nothing
	 * of ours is in the draw buffer.
	 *
	 * devdraw calls this with the rectangle it has just drawn, which
	 * is exactly the information needed: put back the saved pixels
	 * ONLY where the draw did not touch, keep the new content where
	 * it did, then save the lot afresh and repaint the cursor. A
	 * blanket restore would paint the stale pixels back over the new
	 * drawing, and a blanket discard would leave cursor-shaped
	 * residue in the part that was not drawn over.
	 */
	lock(&swc.l);
	if(swc.shown && screenfb != nil){
		stride = screenfb->pitch / sizeof(u32int);
		fb = (u32int*)screenfb->base;
		for(y = 0; y < swc.sh; y++)
			for(x = 0; x < swc.sw; x++){
				px = swc.at.x + x;
				py = swc.at.y + y;
				if(px >= r.min.x && px < r.max.x
				&& py >= r.min.y && py < r.max.y)
					continue;	/* just drawn; leave it */
				fb[py * stride + px] = swc.save[y * Curswid + x];
			}
		swc.shown = 0;
		swcurson();
	}
	unlock(&swc.l);
}

/*
 * Move the cursor. Called from the pointer device on every position
 * change.
 */
void
swcursorat(int x, int y)
{
	lock(&swc.l);
	swcursoff();
	swc.pos.x = x;
	swc.pos.y = y;
	swcurson();
	unlock(&swc.l);
}

/*
 * Take the cursor off the screen for the duration of somebody else's
 * drawing, and put it back afterwards.
 *
 * Coarse on purpose: devdraw calls these around a whole message batch
 * rather than per operation, so drawing never has to know where the
 * cursor is and the cursor never has to know what was drawn.
 */
void
swcursorhide(void)
{
	lock(&swc.l);
	swcursoff();
	unlock(&swc.l);
}

void
swcursorshow(void)
{
	lock(&swc.l);
	swcurson();
	unlock(&swc.l);
}

/*
 * The cursor to start with, and it is Inferno's own.
 *
 * Taken verbatim from upstream os/pc/screen.c, where it has been since
 * long before this port. It is 16x16, two bytes a row, clear mask then
 * set mask -- which is exactly the shape of the Cursor struct
 * screen.h already declares here, CURSWID and CURSHGT both 16.
 *
 * A default is needed at all because nothing supplies one: Inferno's
 * Draw module has no cursor call, and wmlib writes /dev/cursor only
 * when a program wants a DIFFERENT shape. On a hosted system the arrow
 * you see belongs to the host's window system. There is no host here,
 * which is why the mouse worked and the screen showed nothing to say
 * where it was.
 */
Cursor arrow = {
	{ -1, -1 },
	{ 0xFF, 0xFF, 0x80, 0x01, 0x80, 0x02, 0x80, 0x0C, 
	  0x80, 0x10, 0x80, 0x10, 0x80, 0x08, 0x80, 0x04, 
	  0x80, 0x02, 0x80, 0x01, 0x80, 0x02, 0x8C, 0x04, 
	  0x92, 0x08, 0x91, 0x10, 0xA0, 0xA0, 0xC0, 0x40, 
	},
	{ 0x00, 0x00, 0x7F, 0xFE, 0x7F, 0xFC, 0x7F, 0xF0, 
	  0x7F, 0xE0, 0x7F, 0xE0, 0x7F, 0xF0, 0x7F, 0xF8, 
	  0x7F, 0xFC, 0x7F, 0xFE, 0x7F, 0xFC, 0x73, 0xF8, 
	  0x61, 0xF0, 0x60, 0xE0, 0x40, 0x40, 0x00, 0x00, 
	},
};

/*
 * Load a Cursor -- the kernel's own form, as above -- rather than a
 * Drawcursor, which is the form a program writes to /dev/cursor.
 */
void
setcursor(Cursor *c)
{
	lock(&swc.l);
	swcursoff();
	swc.w = CURSWID;
	swc.h = CURSHGT;
	swc.hotx = c->offset.x;
	swc.hoty = c->offset.y;
	memmove(swc.clr, c->clr, sizeof c->clr);
	memmove(swc.set, c->set, sizeof c->set);
	swc.loaded = 1;
	swcurson();
	unlock(&swc.l);
}

void
drawcursor(Drawcursor *c)
{
	int h, bpl, y, n;

	lock(&swc.l);
	swcursoff();

	if(c == nil || c->data == nil || c->minx >= c->maxx){
		/*
		 * BACK TO THE ARROW, not to nothing.
		 *
		 * Clearing the cursor is how a program says "I am done with
		 * mine" -- acme does it from acmeexit through
		 * cursorswitch(nil) -- and it means restore the default,
		 * which is what Plan 9's devmouse does for a zero-length
		 * write to /dev/cursor. Blanking instead leaves the machine
		 * with no pointer at all, and the kernel's arrow is set
		 * once at startup and never set again, so it never comes
		 * back: run acme once and the cursor is gone for the rest
		 * of the session.
		 */
		unlock(&swc.l);
		setcursor(&arrow);
		return;
	}

	h = (c->maxy - c->miny) / 2;	/* the bounds cover both masks */
	bpl = bytesperline(Rect(c->minx, c->miny, c->maxx, c->maxy), 1);
	swc.w = c->maxx - c->minx;
	if(swc.w > Curswid)
		swc.w = Curswid;
	swc.h = h;
	if(swc.h > Curshgt)
		swc.h = Curshgt;
	swc.hotx = c->hotx;
	swc.hoty = c->hoty;

	n = (swc.w + 7) / 8;
	if(n > bpl)
		n = bpl;
	memset(swc.clr, 0, sizeof swc.clr);
	memset(swc.set, 0, sizeof swc.set);
	for(y = 0; y < swc.h; y++){
		memmove(swc.clr + y * ((swc.w + 7) / 8), c->data + y * bpl, n);
		memmove(swc.set + y * ((swc.w + 7) / 8),
			c->data + h * bpl + y * bpl, n);
	}
	swc.loaded = 1;

	swcurson();
	unlock(&swc.l);
}

/*
 * Show the screen on the serial console.
 *
 * Bound to a debug key so that "what is on the display" can be answered
 * from here, over the one wire that always works, without a network, a
 * 9P mount, a filesystem or a command typed at a shell -- every one of
 * which failed at some point while trying to answer exactly that
 * question, and each failure looked like a fault in something else.
 *
 * /dev/screen is the real interface and is the one a program should
 * use; this is for when there is no working way to run a program.
 *
 * It prints characters, not pixels: the framebuffer is 1.5MB and the
 * console is 115200 baud, so a faithful dump would take two minutes and
 * still not be readable as a picture. Each character is one cell of the
 * screen, shaded by the average brightness of the pixels in it, which
 * is enough to tell a blank screen from a desktop, and a desktop from a
 * desktop with a window on it.
 */
static void
screendump(void)
{
	static char shade[] = " .:-=+*#%@";
	u32int *fb;
	int cx, cy, x, y, stride, cw, ch, sum, n, i;
	char line[Dumpcols+2];

	if(screenfb == nil || screenfb->base == 0){
		uartputstr("screen: no framebuffer\n");
		return;
	}

	stride = screenfb->pitch / sizeof(u32int);
	fb = (u32int*)screenfb->base;
	/*
	 * Start where the PANEL is looking, not at the top of the
	 * buffer: the console scrolls by moving the scanout window, and
	 * dumping from the top reported a blank screen while the console
	 * was full of text.
	 */
	fb += (ulong)fbconsvoff() * stride;
	cw = screenfb->width / Dumpcols;
	ch = screenfb->height / Dumprows;
	if(cw < 1) cw = 1;
	if(ch < 1) ch = 1;

	uartputstr("screen: ");
	uartputd(screenfb->width);
	uartputstr("x");
	uartputd(screenfb->height);
	uartputstr(", one character per ");
	uartputd(cw);
	uartputstr("x");
	uartputd(ch);
	uartputstr(" pixels, base ");
	uartputx((ulong)screenfb->base);
	uartputstr(" stride ");
	uartputd(stride);
	uartputstr(" voff ");
	uartputd(fbconsvoff());
	uartputstr(" px(5,5)=");
	uartputx(fb[5*stride + 5]);
	uartputstr(" px(320,240)=");
	uartputx(fb[240*stride + 320]);
	uartputstr("\n");

	for(cy = 0; cy < Dumprows; cy++){
		for(cx = 0; cx < Dumpcols; cx++){
			sum = 0;
			n = 0;
			/*
			 * Sample rather than average every pixel: four
			 * points a cell is plenty to shade by and keeps
			 * this from taking longer than the thing it is
			 * meant to diagnose.
			 */
			for(y = cy*ch; y < (cy+1)*ch; y += (ch+1)/2){
				for(x = cx*cw; x < (cx+1)*cw; x += (cw+1)/2){
					if(x >= (int)screenfb->width
					|| y >= (int)screenfb->height)
						continue;
					i = fb[y*stride + x];
					/* rough luminance, integer only */
					sum += ((i>>16 & 0xFF)*77
						+ (i>>8 & 0xFF)*151
						+ (i & 0xFF)*28) >> 8;
					n++;
				}
			}
			if(n == 0)
				n = 1;
			i = (sum/n) * (nelem(shade)-1) / 255;
			if(i < 0) i = 0;
			if(i > nelem(shade)-2) i = nelem(shade)-2;
			line[cx] = shade[i];
		}
		line[Dumpcols] = '\n';
		line[Dumpcols+1] = 0;
		uartputstr(line);
	}
}

void
screendumpkey(void)
{
	screendump();
}

/*
 * The screen as an actual picture, over the console, in hex.
 *
 * The shaded-character dump above answers "is anything there". This
 * answers "what is it", which sometimes only a picture can. It is here
 * because the alternatives are not dependable on this board: the 9P
 * mount that carries /dev/screen drops the connection part way through
 * a transfer, and typing the commands to start one cannot be done once
 * a window system is running -- /dev/cons and /dev/keyboard are the
 * same queue in devcons, so the shell and the window system split the
 * keystrokes between them. A debug key needs neither.
 *
 * Every fourth pixel in each direction. That is 200x120 for this panel,
 * about 150KB of hex, thirteen seconds at 115200 -- where the whole
 * screen would be 1.5MB and two minutes. Enough to see a desktop, a
 * window, a menu and a cursor.
 */
static void
screenhex(void)
{
	static char hex[] = "0123456789abcdef";
	u32int *fb;
	int x, y, stride, w, h;
	ulong v;
	char line[7];

	if(screenfb == nil || screenfb->base == 0){
		uartputstr("IMG none\n");
		return;
	}
	stride = screenfb->pitch / sizeof(u32int);
	fb = (u32int*)screenfb->base + (ulong)fbconsvoff() * stride;
	w = screenfb->width / 4;
	h = screenfb->height / 4;

	uartputstr("IMG ");
	uartputd(w);
	uartputstr(" ");
	uartputd(h);
	uartputstr("\n");

	line[6] = 0;
	for(y = 0; y < h; y++){
		for(x = 0; x < w; x++){
			v = fb[(y*4)*stride + x*4];
			line[0] = hex[(v>>20) & 0xF];
			line[1] = hex[(v>>16) & 0xF];
			line[2] = hex[(v>>12) & 0xF];
			line[3] = hex[(v>>8) & 0xF];
			line[4] = hex[(v>>4) & 0xF];
			line[5] = hex[v & 0xF];
			uartputstr(line);
		}
		uartputstr("\n");
	}
	uartputstr("IMGEND\n");
}

void
screenhexkey(void)
{
	screenhex();
}
