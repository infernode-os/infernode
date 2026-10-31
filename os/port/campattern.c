/*
 * The simulated sensor: #V's "test" source (camera.h).
 *
 * No emulator has a Pi camera. QEMU's raspi machines do not model
 * Unicam, the SoC's camera receiver, and its USB webcam is an unmerged
 * patch series. So this makes what the real sensor will make -- raw
 * Bayer samples, 10 bits in 16, red at the top left as the IMX708
 * (Camera Module 3) gives them, one frame every 1/fps seconds -- and
 * everything above it, devcam.c's debayering included, is the code a
 * real camera will go through.
 *
 * THE PATTERN. Eight bars across the frame, white, yellow, cyan,
 * green, magenta, red, blue and black, each channel at full scale or
 * zero; and a grey band (half scale) Barh rows high that moves down
 * four rows a frame and wraps. Every colour is flat over a region much
 * wider than the debayer's 3x3 window, so away from the edges a
 * correct debayer gives the colour back exactly: a test can check
 * pixels, and that the band moved between two frames.
 *
 * THE MODES are the IMX708's two binned ones, at their frame rates,
 * and a small one the IMX708 does not have, cheap enough for a test
 * under emulation.
 *
 * THE CLOCK. Frame n is complete at n/fps seconds after on. next()
 * waits for the next whole frame and draws it then -- never one it
 * has returned before -- and frames nobody asked for are counted
 * (count) but never drawn.
 */
#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"
#include	"../port/camera.h"

enum {
	Bits	= 10,
	Full	= (1<<Bits)-1,
	Grey	= 1<<(Bits-1),
	Barh	= 16,
	Barstep	= 4,	/* rows the band moves a frame */
};

static Cammode modes[] = {
	{ 2304, 1296,  56 },
	{ 1536,  864, 120 },
	{  640,  480,  60 },
};

/* the bars, left to right: red, green, blue, each on or off */
static uchar bars[8][3] = {
	{1, 1, 1},
	{1, 1, 0},
	{0, 1, 1},
	{0, 1, 0},
	{1, 0, 1},
	{1, 0, 0},
	{0, 0, 1},
	{0, 0, 0},
};

static struct {
	Cammode	*m;
	int	fps;
	uvlong	t0;		/* ns at on */
	ulong	last;		/* the last frame next() returned */
	Rendez	r;		/* only ever slept on for a time */
} pat;

static uvlong
nsnow(void)
{
	return fastticks2ns(fastticks(nil));
}

static void
paton(Camsrc *s, Cammode *m, int fps)
{
	USED(s);
	pat.m = m;
	pat.fps = fps;
	pat.t0 = nsnow();
	pat.last = 0;
}

static void
patoff(Camsrc *s)
{
	USED(s);
	pat.m = nil;
}

static ulong
patcount(Camsrc *s)
{
	USED(s);
	if(pat.m == nil)
		return 0;
	return (nsnow() - pat.t0) * pat.fps / 1000000000ULL;
}

/*
 * Frame n of the pattern, as the sensor's colour filter sees it: at
 * each pixel only the channel its filter passes. RGGB, so even rows
 * alternate R G, odd rows G B.
 */
static void
draw(ushort *raw, int w, int h, ulong n)
{
	int x, y, band, col;
	ushort row[2][8][2], *p;	/* per row parity, bar, column parity: the sample */
	int b, py, px, ch;

	for(b = 0; b < 8; b++)
		for(py = 0; py < 2; py++)
			for(px = 0; px < 2; px++){
				ch = py + px;	/* R at (0,0), G at (0,1) and (1,0), B at (1,1) */
				row[py][b][px] = bars[b][ch]? Full: 0;
			}
	band = (n * Barstep) % (h - Barh);
	p = raw;
	for(y = 0; y < h; y++){
		if(y >= band && y < band + Barh){
			for(x = 0; x < w; x++)
				*p++ = Grey;
			continue;
		}
		py = y & 1;
		for(x = 0; x < w; x++){
			col = x * 8 / w;
			*p++ = row[py][col][x & 1];
		}
	}
}

static ulong
patnext(Camsrc *s, ushort *raw)
{
	uvlong now, due;
	ulong n;

	USED(s);
	if(pat.m == nil)
		error("camera: not streaming");
	n = (nsnow() - pat.t0) * pat.fps / 1000000000ULL + 1;
	if(n <= pat.last)
		n = pat.last + 1;
	due = pat.t0 + (uvlong)n * 1000000000ULL / pat.fps;
	/*
	 * Until it is due, not for as long as it was: a sleep is counted
	 * in clock ticks and can end a little before, and a frame drawn
	 * early is the same frame the next open would be given again.
	 */
	while((now = nsnow()) < due)
		tsleep(&pat.r, return0, nil, (due - now + 999999) / 1000000);
	draw(raw, pat.m->w, pat.m->h, n);
	pat.last = n;
	return n;
}

Camsrc campattern = {
	"test",
	"rggb",
	Bits,
	modes,
	nelem(modes),
	2,		/* 640x480 */
	paton,
	patoff,
	patnext,
	patcount,
};
