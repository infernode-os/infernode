#include	"u.h"
#include	"../port/lib.h"
#include	"mem.h"
#include	"dat.h"
#include	"fns.h"
#include	"../port/error.h"

#define	Image	IMAGE
#include	<draw.h>
#include	<memdraw.h>
#include	<memlayer.h>
#include	<cursor.h>
#include	"screen.h"

/*
 * The draw device for the native kernel: the shared source (see
 * port/devdraw.c) with this kernel's sleep and wakeup, a colour map,
 * the software cursor the frame buffer drivers draw (os/fb/screen.c),
 * screen blanking, and this kernel's device table.
 */
#define	COLORMAP
#define	drawsleep	sleep
#define	drawwakeup	wakeup
extern void	swcursorhide(void);
extern void	swcursorshow(void);

#include	"../../port/devdraw.c"

Dev drawdevtab = {
	'i',
	"draw",

	devreset,
	devinit,
	devshutdown,
	drawattach,
	drawwalk,
	drawstat,
	drawopen,
	devcreate,
	drawclose,
	drawread,
	devbread,
	drawwrite,
	devbwrite,
	devremove,
	devwstat,
};

/*
 * On 8 bit displays, load the default color map
 */
void
drawcmap(void)
{
	int r, g, b, cr, cg, cb, v;
	int num, den;
	int i, j;

	drawactive(1);	/* to restore map from backup */
	for(r=0,i=0; r!=4; r++)
	    for(v=0; v!=4; v++,i+=16){
		for(g=0,j=v-r; g!=4; g++)
		    for(b=0;b!=4;b++,j++){
			den = r;
			if(g > den)
				den = g;
			if(b > den)
				den = b;
			if(den == 0)	/* divide check -- pick grey shades */
				cr = cg = cb = v*17;
			else{
				num = 17*(4*den+v);
				cr = r*num/den;
				cg = g*num/den;
				cb = b*num/den;
			}
			setcolor(i+(j&15),
				cr*0x01010101, cg*0x01010101, cb*0x01010101);
		    }
	}
}

void
drawblankscreen(int blank)
{
	int i, nc;
	ulong *p;

	if(blank == sdraw.blanked)
		return;
	if(!canqlock(&sdraw.l))
		return;
	if(!initscreenimage()){
		qunlock(&sdraw.l);
		return;
	}
	p = sdraw.savemap;
	nc = screenimage->depth > 8 ? 256 : 1<<screenimage->depth;

	/*
	 * blankscreen uses the hardware to blank the screen
	 * when possible.  to help in cases when it is not possible,
	 * we set the color map to be all black.
	 */
	if(blank == 0){	/* turn screen on */
		for(i=0; i<nc; i++, p+=3)
			setcolor(i, p[0], p[1], p[2]);
		blankscreen(0);
	}else{	/* turn screen off */
		blankscreen(1);
		for(i=0; i<nc; i++, p+=3){
			getcolor(i, &p[0], &p[1], &p[2]);
			setcolor(i, 0, 0, 0);
		}
	}
	sdraw.blanked = blank;
	qunlock(&sdraw.l);
}

/*
 * record activity on screen, changing blanking as appropriate
 */
void
drawactive(int active)
{
	if(active){
		drawblankscreen(0);
		sdraw.blanktime = 0;
	}else{
		if(blanktime && TK2SEC(sdraw.blanktime)/60 >= blanktime)
			drawblankscreen(1);
		else
			sdraw.blanktime++;
	}
}

int
drawidletime(void)
{
	return TK2SEC(MACHP(0)->ticks - sdraw.blanktime)/60;
}
