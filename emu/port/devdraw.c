#include	"dat.h"
#include	"fns.h"
#include	"error.h"

#include	<draw.h>
#include	<memdraw.h>
#include	<memlayer.h>
#include	<cursor.h>

/*
 * The draw device for the emulator: the shared source (see
 * port/devdraw.c) with the emulator's Sleep and Wakeup and its device
 * table.  The host window system draws the cursor, never into the
 * frame buffer, so there is none to take off; and there is no colour
 * map.
 */
#define	drawsleep	Sleep
#define	drawwakeup	Wakeup

static void
swcursorhide(void)
{
}

static void
swcursorshow(void)
{
}

#include	"../../port/devdraw.c"

Dev drawdevtab = {
	'i',
	"draw",

	devinit,
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
