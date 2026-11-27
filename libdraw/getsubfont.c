#include "lib9.h"
#include "kernel.h"
#include "draw.h"
#include "interp.h"

/*
 * Default version: treat as file name
 */

Subfont*
_getsubfont(Display *d, char *name)
{
	int fd, held;
	Subfont *f;

	fd = libopen(name, OREAD);
		
	if(fd < 0){
		_drawprint(2, "getsubfont: can't open %s: %r\n", name);
		return 0;
	}
	/*
	 * The file is read with the display let go, when this Prog holds it.
	 * Not every caller does: Tk measures text (stringwidth, from a
	 * listbox's insert) without the display, which was harmless while a
	 * local display was not locked at all, and unlocking a lock not held
	 * aborts. readsubfont locks for what it sends.
	 */
	held = libqlowner(d->qlock) == currun();
	if(held)
		unlockdisplay(d);
	f = readsubfont(d, name, fd, 1);
	if(held)
		lockdisplay(d);
	if(f == 0)
		_drawprint(2, "getsubfont: can't read %s: %r\n", name);
	libclose(fd);
	return f;
}
